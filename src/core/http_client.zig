const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── Response Types ──────────────────────────────────────────────────────

pub const Timing = struct {
    dns_ms: f64 = 0,
    connect_ms: f64 = 0,
    tls_ms: f64 = 0,
    ttfb_ms: f64 = 0,
    transfer_ms: f64 = 0,
    total_ms: f64 = 0,
};

pub const Response = struct {
    status_code: u16 = 0,
    status_text: []const u8 = "",
    headers: std.ArrayList(VoltFile.Header),
    body: std.ArrayList(u8),
    timing: Timing = .{},
    size_bytes: usize = 0,
    redirect_count: u16 = 0,
    truncated: bool = false,
    total_size: usize = 0,

    pub fn init(allocator: Allocator) Response {
        return .{
            .headers = std.ArrayList(VoltFile.Header).init(allocator),
            .body = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.body.deinit();
    }

    pub fn bodySlice(self: *const Response) []const u8 {
        return self.body.items;
    }

    pub fn getHeader(self: *const Response, name: []const u8) ?[]const u8 {
        for (self.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
        }
        return null;
    }
};

// ── HTTP Version ────────────────────────────────────────────────────────

pub const HttpVersion = enum {
    http1_1,
    http2,
    http3,

    pub fn toString(self: HttpVersion) []const u8 {
        return switch (self) {
            .http1_1 => "HTTP/1.1",
            .http2 => "HTTP/2",
            .http3 => "HTTP/3",
        };
    }
};

// ── HTTP Client ─────────────────────────────────────────────────────────

pub const ClientConfig = struct {
    timeout_ms: u32 = 30_000,
    max_redirects: u8 = 10,
    follow_redirects: bool = true,
    verify_ssl: bool = true,
    proxy_url: ?[]const u8 = null,
    client_cert_path: ?[]const u8 = null,
    client_key_path: ?[]const u8 = null,
    ca_cert_path: ?[]const u8 = null,
    max_response_size: usize = 50 * 1024 * 1024,
    stream_threshold: usize = 5 * 1024 * 1024,
    http_version: HttpVersion = .http1_1,
};

pub const RequestError = error{
    ConnectionFailed,
    Timeout,
    InvalidUrl,
    TlsError,
    ResponseTooLarge,
    OutOfMemory,
    HttpError,
    InvalidContentLength,
    UnsupportedUrlScheme,
    UnexpectedCharacter,
    InvalidTrailer,
    CompressionError,
    UriMissingHost,
    ConnectionRefused,
    NetworkUnreachable,
    TlsFailure,
    CertificateBundleError,
};

/// Execute an HTTP request from a VoltRequest definition.
pub fn execute(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    config: ClientConfig,
) RequestError!Response {
    var response = Response.init(allocator);
    errdefer response.deinit();

    const uri = std.Uri.parse(request.url) catch return RequestError.InvalidUrl;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build headers
    var headers_buf: [32]std.http.Header = undefined;
    var header_count: usize = 0;

    // Add request headers
    for (request.headers.items) |h| {
        if (header_count >= headers_buf.len) break;
        headers_buf[header_count] = .{
            .name = h.name,
            .value = h.value,
        };
        header_count += 1;
    }

    // Add auth headers
    if (request.auth.type == .bearer) {
        if (request.auth.token) |token| {
            if (header_count < headers_buf.len) {
                var auth_buf: [512]u8 = undefined;
                const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch "Bearer ";
                headers_buf[header_count] = .{
                    .name = "Authorization",
                    .value = auth_value,
                };
                header_count += 1;
            }
        }
    } else if (request.auth.type == .basic) {
        if (request.auth.username != null and request.auth.password != null) {
            // Basic auth - Base64 encode username:password
            if (header_count < headers_buf.len) {
                var cred_buf: [256]u8 = undefined;
                const cred_str = std.fmt.bufPrint(&cred_buf, "{s}:{s}", .{ request.auth.username.?, request.auth.password.? }) catch "invalid";
                var b64_buf: [512]u8 = undefined;
                const encoded = std.base64.standard.Encoder.encode(&b64_buf, cred_str);
                var auth_header_buf: [600]u8 = undefined;
                const auth_value = std.fmt.bufPrint(&auth_header_buf, "Basic {s}", .{encoded}) catch "Basic ";
                headers_buf[header_count] = .{
                    .name = "Authorization",
                    .value = auth_value,
                };
                header_count += 1;
            }
        }
    } else if (request.auth.type == .api_key) {
        if (request.auth.key_name != null and request.auth.key_value != null) {
            const location = request.auth.key_location orelse "header";
            if (mem.eql(u8, location, "header")) {
                if (header_count < headers_buf.len) {
                    headers_buf[header_count] = .{
                        .name = request.auth.key_name.?,
                        .value = request.auth.key_value.?,
                    };
                    header_count += 1;
                }
            }
        }
    } else if (request.auth.type == .digest) {
        if (request.auth.username != null and request.auth.password != null) {
            if (header_count < headers_buf.len) {
                headers_buf[header_count] = .{
                    .name = "Authorization",
                    .value = "Digest (credentials)",
                };
                header_count += 1;
            }
        }
    }

    const extra_headers = headers_buf[0..header_count];

    // Map VoltFile.Method to std.http.Method
    const http_method: std.http.Method = switch (request.method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .HEAD => .HEAD,
        .OPTIONS => .OPTIONS,
    };

    // Start timing
    const start_time = std.time.nanoTimestamp();

    // Open the request
    var server_header_buf: [16384]u8 = undefined;
    var req = client.open(http_method, uri, .{
        .server_header_buffer = &server_header_buf,
        .extra_headers = extra_headers,
        .redirect_behavior = if (config.follow_redirects)
            @enumFromInt(config.max_redirects)
        else
            .unhandled,
    }) catch return RequestError.ConnectionFailed;
    defer req.deinit();

    // Send body if present
    if (request.body) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return RequestError.ConnectionFailed;
        req.writer().writeAll(body) catch return RequestError.ConnectionFailed;
        req.finish() catch return RequestError.ConnectionFailed;
    } else {
        req.send() catch return RequestError.ConnectionFailed;
        req.finish() catch return RequestError.ConnectionFailed;
    }

    // Wait for response
    req.wait() catch return RequestError.ConnectionFailed;

    const ttfb_time = std.time.nanoTimestamp();
    response.timing.ttfb_ms = @as(f64, @floatFromInt(ttfb_time - start_time)) / 1_000_000.0;

    // Read status
    response.status_code = @intFromEnum(req.response.status);

    // Read response headers
    var header_iter = req.response.iterateHeaders();
    while (header_iter.next()) |h| {
        response.headers.append(.{
            .name = h.name,
            .value = h.value,
        }) catch return RequestError.OutOfMemory;
    }

    // Read body with large response handling
    const body_data = req.reader().readAllAlloc(allocator, config.max_response_size) catch
        return RequestError.ResponseTooLarge;
    const actual_size = body_data.len;

    if (actual_size > config.stream_threshold) {
        // Large response: keep the data but mark as truncated for callers
        response.truncated = true;
        response.total_size = actual_size;
    }

    response.body.appendSlice(body_data) catch return RequestError.OutOfMemory;
    allocator.free(body_data);

    const end_time = std.time.nanoTimestamp();
    response.timing.transfer_ms = @as(f64, @floatFromInt(end_time - ttfb_time)) / 1_000_000.0;
    response.timing.total_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    response.size_bytes = response.body.items.len;
    if (response.total_size == 0) response.total_size = response.size_bytes;
    response.redirect_count = if (config.follow_redirects) @intCast(@min(@as(u16, config.max_redirects), 10)) else 0;

    return response;
}

/// Format response for display
pub fn formatResponse(response: *const Response, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Status line
    try writer.print("HTTP {d} {s}\n", .{ response.status_code, httpStatusText(response.status_code) });
    try writer.print("Time: {d:.1}ms | Size: {s}\n", .{ response.timing.total_ms, formatBytes(response.size_bytes) });
    try writer.writeAll("\n");

    // Headers
    for (response.headers.items) |h| {
        try writer.print("{s}: {s}\n", .{ h.name, h.value });
    }
    try writer.writeAll("\n");

    // Body
    const body = response.bodySlice();
    if (body.len > 0) {
        try writer.writeAll(body);
        if (body.len > 0 and body[body.len - 1] != '\n') {
            try writer.writeAll("\n");
        }
    }

    return buf.toOwnedSlice();
}

fn formatBytes(bytes: usize) []const u8 {
    if (bytes < 1024) return "< 1 KB";
    if (bytes < 1024 * 1024) return "KB";
    return "MB";
}

pub fn httpStatusText(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        410 => "Gone",
        413 => "Payload Too Large",
        415 => "Unsupported Media Type",
        418 => "I'm a Teapot",
        422 => "Unprocessable Entity",
        429 => "Too Many Requests",
        451 => "Unavailable For Legal Reasons",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };
}

/// Check if a response contains binary content based on Content-Type header
/// or by inspecting the first bytes for binary patterns.
pub fn isBinaryResponse(response: *const Response) bool {
    // Check Content-Type header
    if (response.getHeader("Content-Type")) |ct| {
        const ct_lower = ct; // headers are typically already lowercase or we compare case-insensitively
        if (startsWithIgnoreCase(ct_lower, "image/")) return true;
        if (containsIgnoreCase(ct_lower, "application/octet-stream")) return true;
        if (containsIgnoreCase(ct_lower, "application/pdf")) return true;
        if (containsIgnoreCase(ct_lower, "application/zip")) return true;
        if (containsIgnoreCase(ct_lower, "application/gzip")) return true;
        if (containsIgnoreCase(ct_lower, "application/x-tar")) return true;
        if (containsIgnoreCase(ct_lower, "application/x-7z-compressed")) return true;
        if (containsIgnoreCase(ct_lower, "application/x-rar-compressed")) return true;
        if (containsIgnoreCase(ct_lower, "application/wasm")) return true;
        if (containsIgnoreCase(ct_lower, "audio/")) return true;
        if (containsIgnoreCase(ct_lower, "video/")) return true;
    }

    // Check first bytes for binary patterns (null bytes, non-UTF8)
    const body = response.bodySlice();
    if (body.len == 0) return false;

    const check_len = @min(body.len, 512);
    var null_count: usize = 0;
    var non_text_count: usize = 0;
    for (body[0..check_len]) |b| {
        if (b == 0) null_count += 1;
        // Control characters that aren't common text chars (tab, newline, carriage return)
        if (b < 0x08 or (b > 0x0D and b < 0x20 and b != 0x1B)) non_text_count += 1;
    }

    // If more than 10% is non-text or any null bytes, likely binary
    if (null_count > 0) return true;
    if (check_len > 0 and non_text_count * 10 > check_len) return true;

    return false;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "response init and deinit" {
    var resp = Response.init(std.testing.allocator);
    defer resp.deinit();
    try resp.headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try resp.body.appendSlice("{\"ok\":true}");
    try std.testing.expectEqualStrings("{\"ok\":true}", resp.bodySlice());
    try std.testing.expectEqualStrings("application/json", resp.getHeader("Content-Type").?);
}

test "http status text" {
    try std.testing.expectEqualStrings("OK", httpStatusText(200));
    try std.testing.expectEqualStrings("Not Found", httpStatusText(404));
    try std.testing.expectEqualStrings("Internal Server Error", httpStatusText(500));
}

test "http status text extended codes" {
    try std.testing.expectEqualStrings("Continue", httpStatusText(100));
    try std.testing.expectEqualStrings("Switching Protocols", httpStatusText(101));
    try std.testing.expectEqualStrings("Accepted", httpStatusText(202));
    try std.testing.expectEqualStrings("Non-Authoritative Information", httpStatusText(203));
    try std.testing.expectEqualStrings("Partial Content", httpStatusText(206));
    try std.testing.expectEqualStrings("Temporary Redirect", httpStatusText(307));
    try std.testing.expectEqualStrings("Permanent Redirect", httpStatusText(308));
    try std.testing.expectEqualStrings("Gone", httpStatusText(410));
    try std.testing.expectEqualStrings("Payload Too Large", httpStatusText(413));
    try std.testing.expectEqualStrings("Unsupported Media Type", httpStatusText(415));
    try std.testing.expectEqualStrings("I'm a Teapot", httpStatusText(418));
    try std.testing.expectEqualStrings("Unavailable For Legal Reasons", httpStatusText(451));
    try std.testing.expectEqualStrings("Gateway Timeout", httpStatusText(504));
}

test "isBinaryResponse detects binary content-type" {
    var resp = Response.init(std.testing.allocator);
    defer resp.deinit();

    try resp.headers.append(.{ .name = "Content-Type", .value = "image/png" });
    try resp.body.appendSlice("fake image data");

    try std.testing.expect(isBinaryResponse(&resp));
}

test "isBinaryResponse detects application/pdf" {
    var resp = Response.init(std.testing.allocator);
    defer resp.deinit();

    try resp.headers.append(.{ .name = "Content-Type", .value = "application/pdf" });
    try resp.body.appendSlice("%PDF-1.4");

    try std.testing.expect(isBinaryResponse(&resp));
}

test "isBinaryResponse false for json" {
    var resp = Response.init(std.testing.allocator);
    defer resp.deinit();

    try resp.headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try resp.body.appendSlice("{\"ok\":true}");

    try std.testing.expect(!isBinaryResponse(&resp));
}

test "isBinaryResponse detects null bytes" {
    var resp = Response.init(std.testing.allocator);
    defer resp.deinit();

    try resp.headers.append(.{ .name = "Content-Type", .value = "application/octet-stream" });
    try resp.body.appendSlice(&[_]u8{ 0x00, 0x01, 0x02, 0xFF });

    try std.testing.expect(isBinaryResponse(&resp));
}

test "isBinaryResponse false for empty body" {
    var resp = Response.init(std.testing.allocator);
    defer resp.deinit();

    try std.testing.expect(!isBinaryResponse(&resp));
}

test "response truncated fields default to false and zero" {
    var resp = Response.init(std.testing.allocator);
    defer resp.deinit();

    try std.testing.expect(!resp.truncated);
    try std.testing.expectEqual(@as(usize, 0), resp.total_size);
}

test "http version toString" {
    try std.testing.expectEqualStrings("HTTP/1.1", HttpVersion.http1_1.toString());
    try std.testing.expectEqualStrings("HTTP/2", HttpVersion.http2.toString());
    try std.testing.expectEqualStrings("HTTP/3", HttpVersion.http3.toString());
}

test "client config defaults" {
    const config = ClientConfig{};
    try std.testing.expectEqual(@as(usize, 50 * 1024 * 1024), config.max_response_size);
    try std.testing.expectEqual(@as(usize, 5 * 1024 * 1024), config.stream_threshold);
    try std.testing.expect(config.http_version == .http1_1);
}
