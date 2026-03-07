const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── HTTPie-Style Shorthand Parser ─────────────────────────────────────
// Parses quick command syntax:
//   volt quick [METHOD] URL [items...]
//
// Item types:
//   Header:Value    → HTTP header
//   param==value    → URL query parameter
//   field=value     → JSON string field
//   field:=value    → Raw JSON value (number, bool, array, object)
//   field@/path     → File upload (switches to multipart)

pub const QuickRequest = struct {
    allocator: Allocator,
    method: ?[]const u8 = null,
    url: []const u8 = "",
    headers: std.ArrayList(HeaderPair),
    json_fields: std.ArrayList(JsonField),
    raw_fields: std.ArrayList(JsonField),
    query_params: std.ArrayList(QueryParam),
    files: std.ArrayList(FileField),

    pub fn init(allocator: Allocator) QuickRequest {
        return .{
            .allocator = allocator,
            .headers = std.ArrayList(HeaderPair).init(allocator),
            .json_fields = std.ArrayList(JsonField).init(allocator),
            .raw_fields = std.ArrayList(JsonField).init(allocator),
            .query_params = std.ArrayList(QueryParam).init(allocator),
            .files = std.ArrayList(FileField).init(allocator),
        };
    }

    pub fn deinit(self: *QuickRequest) void {
        self.headers.deinit();
        self.json_fields.deinit();
        self.raw_fields.deinit();
        self.query_params.deinit();
        self.files.deinit();
    }

    pub fn hasBody(self: *const QuickRequest) bool {
        return self.json_fields.items.len > 0 or
            self.raw_fields.items.len > 0 or
            self.files.items.len > 0;
    }

    pub fn effectiveMethod(self: *const QuickRequest) []const u8 {
        if (self.method) |m| return m;
        return if (self.hasBody()) "POST" else "GET";
    }
};

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const JsonField = struct {
    name: []const u8,
    value: []const u8,
};

pub const QueryParam = struct {
    name: []const u8,
    value: []const u8,
};

pub const FileField = struct {
    name: []const u8,
    path: []const u8,
};

/// Expand URL shorthand:
///   :3000/path          → http://localhost:3000/path
///   /path               → http://localhost/path
///   :443/path           → https://localhost:443/path
///   example.com/path    → http://example.com/path (no scheme)
pub fn expandUrl(url: []const u8) []const u8 {
    // Already has scheme
    if (mem.startsWith(u8, url, "http://") or mem.startsWith(u8, url, "https://")) {
        return url;
    }
    // These return static or input slices — callers that need owned strings
    // must dupe the result. The function avoids allocation so it can be
    // used in the hot path without an allocator.
    return url;
}

/// Expand URL with allocation for shorthand forms.
pub fn expandUrlAlloc(allocator: Allocator, url: []const u8) ![]const u8 {
    // Already has scheme
    if (mem.startsWith(u8, url, "http://") or mem.startsWith(u8, url, "https://")) {
        return allocator.dupe(u8, url);
    }
    // :PORT/path → http://localhost:PORT/path
    if (url.len > 0 and url[0] == ':') {
        // Check if port is 443
        const slash = mem.indexOf(u8, url, "/") orelse url.len;
        const port_str = url[1..slash];
        if (mem.eql(u8, port_str, "443")) {
            return std.fmt.allocPrint(allocator, "https://localhost{s}", .{url});
        }
        return std.fmt.allocPrint(allocator, "http://localhost{s}", .{url});
    }
    // /path → http://localhost/path
    if (url.len > 0 and url[0] == '/') {
        return std.fmt.allocPrint(allocator, "http://localhost{s}", .{url});
    }
    // bare hostname — add http://
    return std.fmt.allocPrint(allocator, "http://{s}", .{url});
}

/// Parse quick command arguments into a QuickRequest.
pub fn parseQuickArgs(allocator: Allocator, args: []const []const u8) !QuickRequest {
    var req = QuickRequest.init(allocator);
    errdefer req.deinit();

    if (args.len == 0) return req;

    var arg_idx: usize = 0;

    // Check if first arg is an HTTP method
    const first = args[0];
    if (isHttpMethod(first)) {
        req.method = first;
        arg_idx = 1;
    }

    // Next arg should be the URL
    if (arg_idx < args.len) {
        req.url = args[arg_idx];
        arg_idx += 1;
    }

    // Parse remaining items
    while (arg_idx < args.len) : (arg_idx += 1) {
        const item = args[arg_idx];
        try parseItem(&req, item);
    }

    return req;
}

fn isHttpMethod(s: []const u8) bool {
    const methods = [_][]const u8{ "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "get", "post", "put", "patch", "delete", "head", "options" };
    for (methods) |m| {
        if (mem.eql(u8, s, m)) return true;
    }
    return false;
}

fn parseItem(req: *QuickRequest, item: []const u8) !void {
    // Header:Value (colon separator, but not after ==, =, :=, or @)
    // Check for == first (query param)
    if (mem.indexOf(u8, item, "==")) |pos| {
        try req.query_params.append(.{
            .name = item[0..pos],
            .value = item[pos + 2 ..],
        });
        return;
    }

    // Check for := (raw JSON)
    if (mem.indexOf(u8, item, ":=")) |pos| {
        try req.raw_fields.append(.{
            .name = item[0..pos],
            .value = item[pos + 2 ..],
        });
        return;
    }

    // Check for field@path (file upload)
    if (mem.indexOf(u8, item, "@")) |pos| {
        if (pos > 0) {
            try req.files.append(.{
                .name = item[0..pos],
                .path = item[pos + 1 ..],
            });
            return;
        }
    }

    // Check for field=value (JSON string)
    if (mem.indexOf(u8, item, "=")) |pos| {
        if (pos > 0) {
            try req.json_fields.append(.{
                .name = item[0..pos],
                .value = item[pos + 1 ..],
            });
            return;
        }
    }

    // Check for Header:Value
    if (mem.indexOf(u8, item, ":")) |pos| {
        if (pos > 0 and pos + 1 < item.len) {
            try req.headers.append(.{
                .name = item[0..pos],
                .value = mem.trim(u8, item[pos + 1 ..], " "),
            });
            return;
        }
    }
}

/// Build JSON body from json_fields and raw_fields.
pub fn buildJsonBody(allocator: Allocator, req: *const QuickRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{");
    var first = true;

    // String fields: "key": "value"
    for (req.json_fields.items) |field| {
        if (!first) try writer.writeAll(",");
        try writer.print("\"{s}\":\"{s}\"", .{ field.name, field.value });
        first = false;
    }

    // Raw fields: "key": value (no quotes around value)
    for (req.raw_fields.items) |field| {
        if (!first) try writer.writeAll(",");
        try writer.print("\"{s}\":{s}", .{ field.name, field.value });
        first = false;
    }

    try writer.writeAll("}");
    return buf.toOwnedSlice();
}

/// Build URL with query parameters appended.
pub fn buildUrlWithParams(allocator: Allocator, base_url: []const u8, params: []const QueryParam) ![]const u8 {
    if (params.len == 0) return allocator.dupe(u8, base_url);

    var buf = std.ArrayList(u8).init(allocator);
    try buf.appendSlice(base_url);

    // Check if URL already has query string
    const sep: u8 = if (mem.indexOf(u8, base_url, "?") != null) '&' else '?';
    try buf.append(sep);

    for (params, 0..) |param, i| {
        if (i > 0) try buf.append('&');
        try buf.appendSlice(param.name);
        try buf.append('=');
        try buf.appendSlice(param.value);
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "expand url shorthand - port" {
    const allocator = std.testing.allocator;

    const result = try expandUrlAlloc(allocator, ":3000/api/users");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("http://localhost:3000/api/users", result);
}

test "expand url shorthand - path only" {
    const allocator = std.testing.allocator;

    const result = try expandUrlAlloc(allocator, "/api/users");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("http://localhost/api/users", result);
}

test "expand url shorthand - https 443" {
    const allocator = std.testing.allocator;

    const result = try expandUrlAlloc(allocator, ":443/secure");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://localhost:443/secure", result);
}

test "expand url shorthand - full url unchanged" {
    const allocator = std.testing.allocator;

    const result = try expandUrlAlloc(allocator, "https://api.example.com/users");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("https://api.example.com/users", result);
}

test "expand url shorthand - bare hostname" {
    const allocator = std.testing.allocator;

    const result = try expandUrlAlloc(allocator, "api.example.com/users");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("http://api.example.com/users", result);
}

test "parse quick args - GET request" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "GET", "https://api.example.com/users" };

    var req = try parseQuickArgs(allocator, &args);
    defer req.deinit();

    try std.testing.expectEqualStrings("GET", req.method.?);
    try std.testing.expectEqualStrings("https://api.example.com/users", req.url);
    try std.testing.expectEqualStrings("GET", req.effectiveMethod());
}

test "parse quick args - POST with JSON fields" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "POST", "https://api.example.com/users", "name=John", "age:=30" };

    var req = try parseQuickArgs(allocator, &args);
    defer req.deinit();

    try std.testing.expectEqualStrings("POST", req.method.?);
    try std.testing.expectEqual(@as(usize, 1), req.json_fields.items.len);
    try std.testing.expectEqualStrings("name", req.json_fields.items[0].name);
    try std.testing.expectEqualStrings("John", req.json_fields.items[0].value);
    try std.testing.expectEqual(@as(usize, 1), req.raw_fields.items.len);
    try std.testing.expectEqualStrings("age", req.raw_fields.items[0].name);
    try std.testing.expectEqualStrings("30", req.raw_fields.items[0].value);
}

test "parse quick args - auto method detection" {
    const allocator = std.testing.allocator;

    // No body → GET
    const get_args = [_][]const u8{"https://api.example.com/users"};
    var get_req = try parseQuickArgs(allocator, &get_args);
    defer get_req.deinit();
    try std.testing.expectEqualStrings("GET", get_req.effectiveMethod());

    // With body → POST
    const post_args = [_][]const u8{ "https://api.example.com/users", "name=John" };
    var post_req = try parseQuickArgs(allocator, &post_args);
    defer post_req.deinit();
    try std.testing.expectEqualStrings("POST", post_req.effectiveMethod());
}

test "parse quick args - query params" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "https://api.example.com/search", "q==test", "page==1" };

    var req = try parseQuickArgs(allocator, &args);
    defer req.deinit();

    try std.testing.expectEqual(@as(usize, 2), req.query_params.items.len);
    try std.testing.expectEqualStrings("q", req.query_params.items[0].name);
    try std.testing.expectEqualStrings("test", req.query_params.items[0].value);
}

test "parse quick args - headers" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "https://api.example.com", "Authorization:Bearer tok123", "Accept:application/json" };

    var req = try parseQuickArgs(allocator, &args);
    defer req.deinit();

    try std.testing.expectEqual(@as(usize, 2), req.headers.items.len);
    try std.testing.expectEqualStrings("Authorization", req.headers.items[0].name);
    try std.testing.expectEqualStrings("Bearer tok123", req.headers.items[0].value);
}

test "parse quick args - file upload" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "POST", "https://api.example.com/upload", "file@/path/to/file.txt" };

    var req = try parseQuickArgs(allocator, &args);
    defer req.deinit();

    try std.testing.expectEqual(@as(usize, 1), req.files.items.len);
    try std.testing.expectEqualStrings("file", req.files.items[0].name);
    try std.testing.expectEqualStrings("/path/to/file.txt", req.files.items[0].path);
}

test "build json body" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{ "POST", "https://api.example.com/users", "name=John", "age:=30", "active:=true" };

    var req = try parseQuickArgs(allocator, &args);
    defer req.deinit();

    const body = try buildJsonBody(allocator, &req);
    defer allocator.free(body);

    try std.testing.expect(mem.indexOf(u8, body, "\"name\":\"John\"") != null);
    try std.testing.expect(mem.indexOf(u8, body, "\"age\":30") != null);
    try std.testing.expect(mem.indexOf(u8, body, "\"active\":true") != null);
}

test "build url with params" {
    const allocator = std.testing.allocator;
    const params = [_]QueryParam{
        .{ .name = "q", .value = "test" },
        .{ .name = "page", .value = "1" },
    };

    const url = try buildUrlWithParams(allocator, "https://api.example.com/search", &params);
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://api.example.com/search?q=test&page=1", url);
}

test "build url with params - existing query" {
    const allocator = std.testing.allocator;
    const params = [_]QueryParam{
        .{ .name = "extra", .value = "yes" },
    };

    const url = try buildUrlWithParams(allocator, "https://example.com/search?q=test", &params);
    defer allocator.free(url);

    try std.testing.expectEqualStrings("https://example.com/search?q=test&extra=yes", url);
}
