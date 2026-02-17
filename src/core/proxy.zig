const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── HTTP Proxy for Traffic Capture ──────────────────────────────────────
//
// Captures HTTP requests and converts them to .volt files.
// Useful for recording API traffic and auto-generating test suites
// from real-world request/response pairs.

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const ProxyConfig = struct {
    port: u16 = 8080,
    output_dir: []const u8 = "captured",
    filter_hosts: ?std.ArrayList([]const u8) = null,
    max_captures: usize = 1000,

    pub fn deinit(self: *ProxyConfig) void {
        if (self.filter_hosts) |*hosts| {
            hosts.deinit();
        }
    }
};

pub const CapturedRequest = struct {
    method: []const u8,
    url: []const u8,
    headers: std.ArrayList(Header),
    body: ?[]const u8,
    timestamp: i64,
    response_status: ?u16,

    pub fn init(allocator: Allocator) CapturedRequest {
        return .{
            .method = "GET",
            .url = "/",
            .headers = std.ArrayList(Header).init(allocator),
            .body = null,
            .timestamp = 0,
            .response_status = null,
        };
    }

    pub fn deinit(self: *CapturedRequest) void {
        self.headers.deinit();
    }
};

pub const ProxyServer = struct {
    config: ProxyConfig,
    captures: std.ArrayList(CapturedRequest),
    running: bool,
    capture_count: usize,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: ProxyConfig) ProxyServer {
        return .{
            .config = config,
            .captures = std.ArrayList(CapturedRequest).init(allocator),
            .running = false,
            .capture_count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProxyServer) void {
        for (self.captures.items) |*cap| {
            cap.deinit();
        }
        self.captures.deinit();
    }
};

/// Convert a CapturedRequest to .volt file content.
/// Uses the standard .volt file format:
///   name: captured-{timestamp}
///   method: {method}
///   url: {url}
///   headers:
///     - {name}: {value}
///   body:
///     type: raw
///     content: {body}
pub fn captureToVoltFile(allocator: Allocator, capture: CapturedRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("name: captured-{d}\n", .{capture.timestamp});
    try writer.print("method: {s}\n", .{capture.method});
    try writer.print("url: {s}\n", .{capture.url});

    if (capture.headers.items.len > 0) {
        try writer.writeAll("headers:\n");
        for (capture.headers.items) |header| {
            try writer.print("  - {s}: {s}\n", .{ header.name, header.value });
        }
    }

    if (capture.body) |body| {
        if (body.len > 0) {
            try writer.writeAll("body:\n");
            try writer.writeAll("  type: raw\n");
            try writer.print("  content: {s}\n", .{body});
        }
    }

    return buf.toOwnedSlice();
}

/// Parse a raw HTTP request text into a CapturedRequest.
/// Format: method SP url SP version CRLF headers CRLF CRLF body
pub fn parseProxyRequest(allocator: Allocator, raw_request: []const u8) ?CapturedRequest {
    if (raw_request.len == 0) return null;

    var capture = CapturedRequest.init(allocator);

    // Split into header section and body
    var header_section: []const u8 = raw_request;
    var body: ?[]const u8 = null;

    if (mem.indexOf(u8, raw_request, "\r\n\r\n")) |body_start| {
        header_section = raw_request[0..body_start];
        const body_content = raw_request[body_start + 4 ..];
        if (body_content.len > 0) {
            body = body_content;
        }
    } else if (mem.indexOf(u8, raw_request, "\n\n")) |body_start| {
        header_section = raw_request[0..body_start];
        const body_content = raw_request[body_start + 2 ..];
        if (body_content.len > 0) {
            body = body_content;
        }
    }

    // Parse request line (first line)
    var lines = mem.splitSequence(u8, header_section, "\n");
    const request_line = lines.next() orelse return null;
    const trimmed_request_line = mem.trimRight(u8, request_line, "\r");

    // Split request line: METHOD SP URL SP HTTP/version
    var parts = mem.splitScalar(u8, trimmed_request_line, ' ');
    const method = parts.next() orelse return null;
    const url = parts.next() orelse return null;
    // Skip the HTTP version

    capture.method = method;
    capture.url = url;
    capture.body = body;
    capture.timestamp = std.time.timestamp();

    // Parse headers
    while (lines.next()) |raw_line| {
        const line = mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0) continue;

        if (mem.indexOf(u8, line, ": ")) |colon_pos| {
            capture.headers.append(.{
                .name = line[0..colon_pos],
                .value = line[colon_pos + 2 ..],
            }) catch return null;
        }
    }

    return capture;
}

/// Check if a URL should be captured based on filter_hosts.
/// If no filter is configured, captures everything.
pub fn shouldCapture(config: ProxyConfig, url: []const u8) bool {
    const hosts = config.filter_hosts orelse return true;
    if (hosts.items.len == 0) return true;

    for (hosts.items) |host| {
        if (mem.indexOf(u8, url, host) != null) return true;
    }
    return false;
}

/// Save a captured request as a .volt file to the output directory.
pub fn saveCapture(allocator: Allocator, config: ProxyConfig, capture: CapturedRequest) !void {
    const volt_content = try captureToVoltFile(allocator, capture);
    defer allocator.free(volt_content);

    const filename = try std.fmt.allocPrint(allocator, "{s}/captured-{d}.volt", .{ config.output_dir, capture.timestamp });
    defer allocator.free(filename);

    // Ensure output directory exists
    std.fs.cwd().makePath(config.output_dir) catch {};

    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    try file.writeAll(volt_content);
}

/// Format a captured request for terminal display.
/// Format: "[timestamp] METHOD url -> status"
pub fn formatCaptureLog(allocator: Allocator, capture: CapturedRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("[{d}] \x1b[36m{s}\x1b[0m {s}", .{ capture.timestamp, capture.method, capture.url });

    if (capture.response_status) |status| {
        if (status >= 200 and status < 300) {
            try writer.print(" -> \x1b[32m{d}\x1b[0m", .{status});
        } else if (status >= 300 and status < 400) {
            try writer.print(" -> \x1b[33m{d}\x1b[0m", .{status});
        } else if (status >= 400) {
            try writer.print(" -> \x1b[31m{d}\x1b[0m", .{status});
        } else {
            try writer.print(" -> {d}", .{status});
        }
    }

    return buf.toOwnedSlice();
}

/// Auto-generate basic test assertions from captured request/response pairs.
/// Generates .volt-style test blocks with status and body assertions.
pub fn generateTestsFromCaptures(allocator: Allocator, captures: []const CapturedRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("# Auto-generated tests from captured traffic\n\n");

    for (captures, 0..) |capture, i| {
        try writer.print("# Test {d}: {s} {s}\n", .{ i + 1, capture.method, capture.url });
        try writer.print("name: test-capture-{d}\n", .{i + 1});
        try writer.print("method: {s}\n", .{capture.method});
        try writer.print("url: {s}\n", .{capture.url});

        if (capture.headers.items.len > 0) {
            try writer.writeAll("headers:\n");
            for (capture.headers.items) |header| {
                try writer.print("  - {s}: {s}\n", .{ header.name, header.value });
            }
        }

        if (capture.body) |body| {
            if (body.len > 0) {
                try writer.writeAll("body:\n");
                try writer.writeAll("  type: raw\n");
                try writer.print("  content: {s}\n", .{body});
            }
        }

        // Generate assertions
        try writer.writeAll("assert:\n");
        if (capture.response_status) |status| {
            try writer.print("  - status: {d}\n", .{status});
        }
        try writer.writeAll("  - body_contains: \"\"\n");

        try writer.writeAll("\n---\n\n");
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "capture to volt file" {
    var capture = CapturedRequest.init(std.testing.allocator);
    defer capture.deinit();

    capture.method = "POST";
    capture.url = "https://api.example.com/users";
    capture.timestamp = 1700000000;
    capture.body = "{\"name\": \"alice\"}";

    try capture.headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try capture.headers.append(.{ .name = "Authorization", .value = "Bearer token123" });

    const volt_content = try captureToVoltFile(std.testing.allocator, capture);
    defer std.testing.allocator.free(volt_content);

    try std.testing.expect(mem.indexOf(u8, volt_content, "name: captured-1700000000") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "method: POST") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "url: https://api.example.com/users") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "Content-Type: application/json") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "Authorization: Bearer token123") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "type: raw") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "alice") != null);
}

test "capture to volt file without body" {
    var capture = CapturedRequest.init(std.testing.allocator);
    defer capture.deinit();

    capture.method = "GET";
    capture.url = "https://api.example.com/health";
    capture.timestamp = 1700000001;

    const volt_content = try captureToVoltFile(std.testing.allocator, capture);
    defer std.testing.allocator.free(volt_content);

    try std.testing.expect(mem.indexOf(u8, volt_content, "method: GET") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "body:") == null);
}

test "parse proxy request" {
    const raw =
        "POST /api/users HTTP/1.1\r\n" ++
        "Host: api.example.com\r\n" ++
        "Content-Type: application/json\r\n" ++
        "\r\n" ++
        "{\"name\": \"bob\"}";

    var capture = parseProxyRequest(std.testing.allocator, raw).?;
    defer capture.deinit();

    try std.testing.expectEqualStrings("POST", capture.method);
    try std.testing.expectEqualStrings("/api/users", capture.url);
    try std.testing.expectEqual(@as(usize, 2), capture.headers.items.len);
    try std.testing.expectEqualStrings("Host", capture.headers.items[0].name);
    try std.testing.expectEqualStrings("api.example.com", capture.headers.items[0].value);
    try std.testing.expectEqualStrings("Content-Type", capture.headers.items[1].name);
    try std.testing.expectEqualStrings("{\"name\": \"bob\"}", capture.body.?);
}

test "parse proxy request without body" {
    const raw =
        "GET /health HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "\r\n";

    var capture = parseProxyRequest(std.testing.allocator, raw).?;
    defer capture.deinit();

    try std.testing.expectEqualStrings("GET", capture.method);
    try std.testing.expectEqualStrings("/health", capture.url);
    try std.testing.expect(capture.body == null);
}

test "parse proxy request rejects empty" {
    try std.testing.expect(parseProxyRequest(std.testing.allocator, "") == null);
}

test "should capture with no filter" {
    const config = ProxyConfig{};
    try std.testing.expect(shouldCapture(config, "https://api.example.com/users"));
    try std.testing.expect(shouldCapture(config, "https://other.com/health"));
}

test "should capture with filter" {
    var hosts = std.ArrayList([]const u8).init(std.testing.allocator);
    defer hosts.deinit();

    try hosts.append("api.example.com");
    try hosts.append("staging.example.com");

    const config = ProxyConfig{
        .filter_hosts = hosts,
    };

    try std.testing.expect(shouldCapture(config, "https://api.example.com/users"));
    try std.testing.expect(shouldCapture(config, "https://staging.example.com/health"));
    try std.testing.expect(!shouldCapture(config, "https://other.com/data"));
}

test "format capture log" {
    var capture = CapturedRequest.init(std.testing.allocator);
    defer capture.deinit();

    capture.method = "GET";
    capture.url = "https://api.example.com/users";
    capture.timestamp = 1700000000;
    capture.response_status = 200;

    const log = try formatCaptureLog(std.testing.allocator, capture);
    defer std.testing.allocator.free(log);

    try std.testing.expect(mem.indexOf(u8, log, "1700000000") != null);
    try std.testing.expect(mem.indexOf(u8, log, "GET") != null);
    try std.testing.expect(mem.indexOf(u8, log, "api.example.com/users") != null);
    try std.testing.expect(mem.indexOf(u8, log, "200") != null);
    // Should use green color for 2xx
    try std.testing.expect(mem.indexOf(u8, log, "\x1b[32m") != null);
}

test "format capture log with error status" {
    var capture = CapturedRequest.init(std.testing.allocator);
    defer capture.deinit();

    capture.method = "POST";
    capture.url = "/api/broken";
    capture.timestamp = 1700000001;
    capture.response_status = 500;

    const log = try formatCaptureLog(std.testing.allocator, capture);
    defer std.testing.allocator.free(log);

    try std.testing.expect(mem.indexOf(u8, log, "500") != null);
    // Should use red color for 5xx
    try std.testing.expect(mem.indexOf(u8, log, "\x1b[31m") != null);
}

test "generate tests from captures" {
    var capture1 = CapturedRequest.init(std.testing.allocator);
    defer capture1.deinit();
    capture1.method = "GET";
    capture1.url = "/api/users";
    capture1.timestamp = 1700000000;
    capture1.response_status = 200;

    var capture2 = CapturedRequest.init(std.testing.allocator);
    defer capture2.deinit();
    capture2.method = "POST";
    capture2.url = "/api/users";
    capture2.timestamp = 1700000001;
    capture2.response_status = 201;
    capture2.body = "{\"name\": \"alice\"}";

    const captures = [_]CapturedRequest{ capture1, capture2 };
    const tests = try generateTestsFromCaptures(std.testing.allocator, &captures);
    defer std.testing.allocator.free(tests);

    try std.testing.expect(mem.indexOf(u8, tests, "test-capture-1") != null);
    try std.testing.expect(mem.indexOf(u8, tests, "test-capture-2") != null);
    try std.testing.expect(mem.indexOf(u8, tests, "method: GET") != null);
    try std.testing.expect(mem.indexOf(u8, tests, "method: POST") != null);
    try std.testing.expect(mem.indexOf(u8, tests, "status: 200") != null);
    try std.testing.expect(mem.indexOf(u8, tests, "status: 201") != null);
}
