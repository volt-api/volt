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
    /// The HTTP version used for this request/response.
    http_version: HttpVersion = .http1_1,
    /// H3 frame bytes for the request (populated when http_version == .http3).
    h3_frame_bytes: usize = 0,
    /// Set by execute()/executeStreaming() when header strings are heap-allocated.
    _owns_header_strings: bool = false,

    pub fn init(allocator: Allocator) Response {
        return .{
            .headers = std.ArrayList(VoltFile.Header).init(allocator),
            .body = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Response) void {
        if (self._owns_header_strings) {
            const alloc = self.headers.allocator;
            for (self.headers.items) |h| {
                alloc.free(h.name);
                alloc.free(h.value);
            }
        }
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

const Config = @import("config.zig");
pub const SslVersion = Config.SslVersion;

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
    // TLS configurability
    ssl_version: ?SslVersion = null,
    ciphers: ?[]const u8 = null,
    // Chunked transfer and compression
    chunked: bool = false,
    compress: bool = false,
    // Streaming output
    streaming: bool = false,
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

    // Track the HTTP version used for this request
    response.http_version = config.http_version;

    // HTTP/3 over QUIC: send the request via real QUIC/UDP transport
    // using the quic module for TLS 1.3 + AEAD packet protection.
    if (config.http_version == .http3) {
        const H3 = @import("h3.zig");
        const QuicClient = @import("quic/client.zig");

        // Build H3 request headers
        var h3_headers = std.ArrayList(H3.Header).init(allocator);
        defer h3_headers.deinit();
        for (request.headers.items) |h| {
            h3_headers.append(.{ .name = h.name, .value = h.value }) catch {};
        }

        // Parse authority and port from URL
        var authority: []const u8 = "localhost";
        var h3_port: u16 = 443;
        if (mem.indexOf(u8, request.url, "://")) |se| {
            const after = request.url[se + 3 ..];
            const slash = mem.indexOf(u8, after, "/") orelse after.len;
            authority = after[0..slash];
            // Check for explicit port
            if (mem.indexOf(u8, authority, ":")) |colon| {
                h3_port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch 443;
                authority = authority[0..colon];
            }
        }

        // Parse path from URL
        var path: []const u8 = "/";
        if (mem.indexOf(u8, request.url, "://")) |se| {
            const after = request.url[se + 3 ..];
            if (mem.indexOf(u8, after, "/")) |slash| {
                path = after[slash..];
            }
        }

        // Send HTTP/3 request over QUIC
        const h3_response = QuicClient.sendRequest(
            authority,
            h3_port,
            request.method.toString(),
            path,
            h3_headers.items,
            request.body,
            allocator,
        ) catch {
            // Fall through to HTTP/1.1 if QUIC fails
            response.http_version = .http1_1;
            return execute(allocator, request, ClientConfig{
                .timeout_ms = config.timeout_ms,
                .max_redirects = config.max_redirects,
                .follow_redirects = config.follow_redirects,
                .verify_ssl = config.verify_ssl,
                .http_version = .http1_1,
            });
        };

        // Map H3 response to our Response struct
        var h3_resp = h3_response;
        defer h3_resp.deinit();
        response.status_code = h3_resp.status_code;
        response.http_version = .http3;
        for (h3_resp.headers.items) |h| {
            response.headers.append(.{ .name = h.name, .value = h.value }) catch {};
        }
        response.body.appendSlice(h3_resp.body.items) catch {};
        response.size_bytes = response.body.items.len;
        response.total_size = response.size_bytes;
        return response;
    }

    const uri = std.Uri.parse(request.url) catch return RequestError.InvalidUrl;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build headers
    var headers_buf: [32]std.http.Header = undefined;
    var header_count: usize = 0;
    // Track heap-allocated auth headers for cleanup after request completes
    var hawk_auth_alloc: ?[]const u8 = null;
    defer if (hawk_auth_alloc) |v| allocator.free(v);
    // AWS auth headers are duped; track them for cleanup
    var aws_auth_allocs: [8][2][]const u8 = undefined;
    var aws_auth_count: usize = 0;
    defer for (aws_auth_allocs[0..aws_auth_count]) |a| {
        allocator.free(a[0]);
        allocator.free(a[1]);
    };

    // Auth buffers at function scope so they remain valid until request completes
    var bearer_buf: [512]u8 = undefined;
    var cred_buf: [256]u8 = undefined;
    var b64_buf: [512]u8 = undefined;
    var basic_buf: [600]u8 = undefined;

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
                const auth_value = std.fmt.bufPrint(&bearer_buf, "Bearer {s}", .{token}) catch "Bearer ";
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
                const cred_str = std.fmt.bufPrint(&cred_buf, "{s}:{s}", .{ request.auth.username.?, request.auth.password.? }) catch "invalid";
                const encoded = std.base64.standard.Encoder.encode(&b64_buf, cred_str);
                const auth_value = std.fmt.bufPrint(&basic_buf, "Basic {s}", .{encoded}) catch "Basic ";
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
    } else if (request.auth.type == .aws) {
        // AWS SigV4 — generate Authorization header via aws_auth module
        if (request.auth.access_key != null and request.auth.secret_key != null) {
            const AwsAuth = @import("aws_auth.zig");
            const aws_config = AwsAuth.AwsAuthConfig{
                .access_key = request.auth.access_key.?,
                .secret_key = request.auth.secret_key.?,
                .region = request.auth.region orelse "us-east-1",
                .service = request.auth.service orelse "execute-api",
                .session_token = request.auth.session_token,
            };
            var signed = AwsAuth.signRequest(
                allocator,
                aws_config,
                request.method.toString(),
                request.url,
                &[_][2][]const u8{},
                request.body,
            ) catch null;
            if (signed) |*s| {
                defer s.deinit();
                for (s.headers.items) |h| {
                    if (header_count < headers_buf.len) {
                        // Dupe the header values since signed will be deinit'd
                        const name_d = allocator.dupe(u8, h[0]) catch continue;
                        const value_d = allocator.dupe(u8, h[1]) catch {
                            allocator.free(name_d);
                            continue;
                        };
                        headers_buf[header_count] = .{ .name = name_d, .value = value_d };
                        if (aws_auth_count < aws_auth_allocs.len) {
                            aws_auth_allocs[aws_auth_count] = .{ name_d, value_d };
                            aws_auth_count += 1;
                        }
                        header_count += 1;
                    }
                }
            }
        }
    } else if (request.auth.type == .hawk) {
        // Hawk Authentication — generate Authorization header
        if (request.auth.hawk_id != null and request.auth.hawk_key != null) {
            const HawkAuth = @import("hawk_auth.zig");
            const hawk_config = HawkAuth.HawkConfig{
                .id = request.auth.hawk_id.?,
                .key = request.auth.hawk_key.?,
                .algorithm = if (request.auth.hawk_algorithm) |a| HawkAuth.HawkConfig.Algorithm.fromString(a) else .sha256,
                .ext = request.auth.hawk_ext,
            };
            const content_type = for (request.headers.items) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "content-type")) break h.value;
            } else null;
            const hawk_header = HawkAuth.generateHeader(
                allocator,
                hawk_config,
                request.method.toString(),
                request.url,
                request.body,
                content_type,
            ) catch null;
            if (hawk_header) |hh| {
                if (header_count < headers_buf.len) {
                    headers_buf[header_count] = .{ .name = "Authorization", .value = hh };
                    header_count += 1;
                    hawk_auth_alloc = hh;
                } else {
                    allocator.free(hh);
                }
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

    // Read response headers — dupe strings since they point into stack buffer
    var header_iter = req.response.iterateHeaders();
    while (header_iter.next()) |h| {
        const name_copy = allocator.dupe(u8, h.name) catch return RequestError.OutOfMemory;
        const value_copy = allocator.dupe(u8, h.value) catch {
            allocator.free(name_copy);
            return RequestError.OutOfMemory;
        };
        response.headers.append(.{
            .name = name_copy,
            .value = value_copy,
        }) catch return RequestError.OutOfMemory;
    }
    response._owns_header_strings = true;

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
    response.redirect_count = 0; // actual count not tracked by std.http.Client

    return response;
}

/// Format response for display
pub fn formatResponse(response: *const Response, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Status line
    try writer.print("{s} {d} {s}\n", .{ response.http_version.toString(), response.status_code, httpStatusText(response.status_code) });
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
    if (bytes == 0) return "0 B";
    if (bytes < 1024) return "< 1 KB";
    if (bytes < 10 * 1024) return "< 10 KB";
    if (bytes < 100 * 1024) return "< 100 KB";
    if (bytes < 1024 * 1024) return "< 1 MB";
    if (bytes < 10 * 1024 * 1024) return "< 10 MB";
    if (bytes < 100 * 1024 * 1024) return "< 100 MB";
    return "> 100 MB";
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

// ── Streaming Execution ─────────────────────────────────────────────────

/// Execute a request and stream body chunks directly to the provided writer.
/// Returns Response with empty body (since it was streamed to writer).
pub fn executeStreaming(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    config: ClientConfig,
    writer: anytype,
) RequestError!Response {
    var response = Response.init(allocator);
    errdefer response.deinit();

    response.http_version = config.http_version;

    // HTTP/3 over QUIC for streaming requests
    if (config.http_version == .http3) {
        const H3 = @import("h3.zig");
        const QuicClient = @import("quic/client.zig");

        var h3_headers = std.ArrayList(H3.Header).init(allocator);
        defer h3_headers.deinit();
        for (request.headers.items) |h| {
            h3_headers.append(.{ .name = h.name, .value = h.value }) catch {};
        }

        var authority: []const u8 = "localhost";
        var h3_port: u16 = 443;
        if (mem.indexOf(u8, request.url, "://")) |se| {
            const after = request.url[se + 3 ..];
            const slash = mem.indexOf(u8, after, "/") orelse after.len;
            authority = after[0..slash];
            if (mem.indexOf(u8, authority, ":")) |colon| {
                h3_port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch 443;
                authority = authority[0..colon];
            }
        }

        var path: []const u8 = "/";
        if (mem.indexOf(u8, request.url, "://")) |se| {
            const after = request.url[se + 3 ..];
            if (mem.indexOf(u8, after, "/")) |slash| {
                path = after[slash..];
            }
        }

        const h3_response = QuicClient.sendRequest(
            authority,
            h3_port,
            request.method.toString(),
            path,
            h3_headers.items,
            request.body,
            allocator,
        ) catch {
            response.http_version = .http1_1;
            return executeStreaming(allocator, request, ClientConfig{
                .timeout_ms = config.timeout_ms,
                .http_version = .http1_1,
            }, writer);
        };

        var h3_resp = h3_response;
        defer h3_resp.deinit();
        response.status_code = h3_resp.status_code;
        response.http_version = .http3;
        for (h3_resp.headers.items) |h| {
            response.headers.append(.{ .name = h.name, .value = h.value }) catch {};
        }
        // Stream body to writer
        if (h3_resp.body.items.len > 0) {
            writer.writeAll(h3_resp.body.items) catch {};
            response.size_bytes = h3_resp.body.items.len;
        }
        return response;
    }

    const uri = std.Uri.parse(request.url) catch return RequestError.InvalidUrl;

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build headers (same as execute)
    var headers_buf: [32]std.http.Header = undefined;
    var header_count: usize = 0;
    // Auth buffer at function scope so it remains valid until request completes
    var auth_buf: [512]u8 = undefined;

    for (request.headers.items) |h| {
        if (header_count >= headers_buf.len) break;
        headers_buf[header_count] = .{ .name = h.name, .value = h.value };
        header_count += 1;
    }

    if (request.auth.type == .bearer) {
        if (request.auth.token) |token| {
            if (header_count < headers_buf.len) {
                const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token}) catch "Bearer ";
                headers_buf[header_count] = .{ .name = "Authorization", .value = auth_value };
                header_count += 1;
            }
        }
    }

    const extra_headers = headers_buf[0..header_count];

    const http_method: std.http.Method = switch (request.method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .HEAD => .HEAD,
        .OPTIONS => .OPTIONS,
    };

    const start_time = std.time.nanoTimestamp();

    var server_header_buf_stream: [16384]u8 = undefined;
    var req = client.open(http_method, uri, .{
        .server_header_buffer = &server_header_buf_stream,
        .extra_headers = extra_headers,
        .redirect_behavior = if (config.follow_redirects) @enumFromInt(config.max_redirects) else .unhandled,
    }) catch return RequestError.ConnectionFailed;
    defer req.deinit();

    if (request.body) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
        req.send() catch return RequestError.ConnectionFailed;
        req.writer().writeAll(body) catch return RequestError.ConnectionFailed;
        req.finish() catch return RequestError.ConnectionFailed;
    } else {
        req.send() catch return RequestError.ConnectionFailed;
        req.finish() catch return RequestError.ConnectionFailed;
    }

    req.wait() catch return RequestError.ConnectionFailed;

    response.status_code = @intFromEnum(req.response.status);

    // Read response headers — dupe strings since they point into stack buffer
    var header_iter = req.response.iterateHeaders();
    while (header_iter.next()) |h| {
        const name_copy = allocator.dupe(u8, h.name) catch return RequestError.OutOfMemory;
        const value_copy = allocator.dupe(u8, h.value) catch {
            allocator.free(name_copy);
            return RequestError.OutOfMemory;
        };
        response.headers.append(.{ .name = name_copy, .value = value_copy }) catch return RequestError.OutOfMemory;
    }
    response._owns_header_strings = true;

    // Stream body in chunks
    var buf: [8192]u8 = undefined;
    var total_streamed: usize = 0;
    while (true) {
        const n = req.reader().read(&buf) catch break;
        if (n == 0) break;
        writer.writeAll(buf[0..n]) catch break;
        total_streamed += n;
    }

    const end_time = std.time.nanoTimestamp();
    response.timing.total_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;
    response.size_bytes = total_streamed;

    return response;
}

// ── SOCKS5 Protocol ────────────────────────────────────────────────────

pub const SocksConfig = struct {
    host: []const u8,
    port: u16,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

/// Parse a SOCKS5 proxy URL: socks5://[user:pass@]host:port
pub fn parseSocksUrl(url: []const u8) ?SocksConfig {
    const prefix = "socks5://";
    if (!mem.startsWith(u8, url, prefix)) return null;
    var rest = url[prefix.len..];

    var username: ?[]const u8 = null;
    var password: ?[]const u8 = null;

    // Check for user:pass@
    if (mem.indexOf(u8, rest, "@")) |at_pos| {
        const auth = rest[0..at_pos];
        if (mem.indexOf(u8, auth, ":")) |colon| {
            username = auth[0..colon];
            password = auth[colon + 1 ..];
        }
        rest = rest[at_pos + 1 ..];
    }

    // Parse host:port
    if (mem.lastIndexOf(u8, rest, ":")) |colon| {
        const host = rest[0..colon];
        const port = std.fmt.parseInt(u16, rest[colon + 1 ..], 10) catch return null;
        return SocksConfig{
            .host = host,
            .port = port,
            .username = username,
            .password = password,
        };
    }

    return null;
}

/// Perform SOCKS5 handshake over a connected stream.
/// Returns true on success. The stream is then tunneled to target_host:target_port.
pub fn socks5Handshake(
    stream_writer: anytype,
    stream_reader: anytype,
    config: *const SocksConfig,
    target_host: []const u8,
    target_port: u16,
) !bool {
    // 1. Greeting: offer auth methods based on whether credentials are provided
    if (config.username != null and config.password != null) {
        // Offer no-auth (0x00) and username/password (0x02)
        try stream_writer.writeAll(&[_]u8{ 0x05, 0x02, 0x00, 0x02 });
    } else {
        // Offer no-auth only
        try stream_writer.writeAll(&[_]u8{ 0x05, 0x01, 0x00 });
    }

    // 2. Server response: version + chosen method
    var greeting_resp: [2]u8 = undefined;
    const read_n = try stream_reader.read(&greeting_resp);
    if (read_n < 2 or greeting_resp[0] != 0x05) return false;

    // Handle username/password auth if server selected method 0x02
    if (greeting_resp[1] == 0x02) {
        const user = config.username orelse return false;
        const pass = config.password orelse return false;
        // Sub-negotiation: version=1, ulen, username, plen, password
        try stream_writer.writeByte(0x01);
        try stream_writer.writeByte(@intCast(user.len));
        try stream_writer.writeAll(user);
        try stream_writer.writeByte(@intCast(pass.len));
        try stream_writer.writeAll(pass);
        // Read auth response
        var auth_resp: [2]u8 = undefined;
        const auth_n = try stream_reader.read(&auth_resp);
        if (auth_n < 2 or auth_resp[1] != 0x00) return false;
    } else if (greeting_resp[1] != 0x00) {
        return false; // No acceptable auth method
    }

    // 3. CONNECT request
    // Version=5, CMD=CONNECT(1), RSV=0, ATYP=DOMAINNAME(3)
    try stream_writer.writeAll(&[_]u8{ 0x05, 0x01, 0x00, 0x03 });
    // Domain length + domain
    try stream_writer.writeByte(@intCast(target_host.len));
    try stream_writer.writeAll(target_host);
    // Port (big endian)
    try stream_writer.writeByte(@intCast(target_port >> 8));
    try stream_writer.writeByte(@intCast(target_port & 0xFF));

    // 4. Read CONNECT response (at least 10 bytes for IPv4)
    var connect_resp: [10]u8 = undefined;
    const resp_n = try stream_reader.read(&connect_resp);
    if (resp_n < 4 or connect_resp[0] != 0x05 or connect_resp[1] != 0x00) return false;

    return true;
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
    try std.testing.expect(config.ssl_version == null);
    try std.testing.expect(config.ciphers == null);
    try std.testing.expect(!config.chunked);
    try std.testing.expect(!config.compress);
    try std.testing.expect(!config.streaming);
}

test "parse socks5 url" {
    const config = parseSocksUrl("socks5://proxy.example.com:1080").?;
    try std.testing.expectEqualStrings("proxy.example.com", config.host);
    try std.testing.expectEqual(@as(u16, 1080), config.port);
    try std.testing.expect(config.username == null);
}

test "parse socks5 url with auth" {
    const config = parseSocksUrl("socks5://user:pass@proxy.example.com:1080").?;
    try std.testing.expectEqualStrings("proxy.example.com", config.host);
    try std.testing.expectEqual(@as(u16, 1080), config.port);
    try std.testing.expectEqualStrings("user", config.username.?);
    try std.testing.expectEqualStrings("pass", config.password.?);
}

test "parse socks5 url invalid" {
    try std.testing.expect(parseSocksUrl("http://proxy.example.com:1080") == null);
    try std.testing.expect(parseSocksUrl("socks5://noport") == null);
}

test "ssl version enum" {
    try std.testing.expect(SslVersion.tls1_2 != SslVersion.tls1_3);
}
