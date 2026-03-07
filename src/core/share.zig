const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── One-Command Sharing ───────────────────────────────────────────────
// Generate shareable request strings in various formats.
// Supports cURL commands, base64-encoded .volt content, and URL-encoded queries.

pub const ShareFormat = enum {
    curl,
    base64,
    url,

    pub fn fromString(s: []const u8) ShareFormat {
        if (mem.eql(u8, s, "curl")) return .curl;
        if (mem.eql(u8, s, "base64")) return .base64;
        if (mem.eql(u8, s, "url")) return .url;
        return .base64;
    }

    pub fn toString(self: ShareFormat) []const u8 {
        return switch (self) {
            .curl => "curl",
            .base64 => "base64",
            .url => "url",
        };
    }
};

// ── Share Functions ───────────────────────────────────────────────────

/// Generate a shareable string from a request in the specified format.
pub fn shareRequest(allocator: Allocator, request: *const VoltFile.VoltRequest, format: ShareFormat) ![]const u8 {
    return switch (format) {
        .curl => try shareCurl(allocator, request),
        .base64 => try shareBase64(allocator, request),
        .url => try shareUrl(allocator, request),
    };
}

/// Generate a cURL command from a request.
fn shareCurl(allocator: Allocator, request: *const VoltFile.VoltRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("curl");

    // Method (omit for GET as it's the default)
    if (request.method != .GET) {
        try writer.print(" -X {s}", .{request.method.toString()});
    }

    // URL
    try writer.print(" '{s}'", .{request.url});

    // Headers
    for (request.headers.items) |h| {
        try writer.print(" \\\n  -H '{s}: {s}'", .{ h.name, h.value });
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print(" \\\n  -H 'Authorization: Bearer {s}'", .{token});
            }
        },
        .basic => {
            if (request.auth.username) |user| {
                if (request.auth.password) |pass| {
                    try writer.print(" \\\n  -u '{s}:{s}'", .{ user, pass });
                }
            }
        },
        .api_key => {
            if (request.auth.key_name) |name| {
                if (request.auth.key_value) |value| {
                    const location = request.auth.key_location orelse "header";
                    if (mem.eql(u8, location, "header")) {
                        try writer.print(" \\\n  -H '{s}: {s}'", .{ name, value });
                    }
                }
            }
        },
        .digest => {
            if (request.auth.username) |user| {
                if (request.auth.password) |pass| {
                    try writer.print(" \\\n  --digest -u '{s}:{s}'", .{ user, pass });
                }
            }
        },
        .aws, .hawk, .oauth_cc, .oauth_password, .oauth_implicit => {},
        .none => {},
    }

    // Body
    if (request.body) |body| {
        try writer.writeAll(" \\\n  -d '");
        for (body) |c| {
            if (c == '\'') {
                try writer.writeAll("'\\''");
            } else {
                try writer.writeByte(c);
            }
        }
        try writer.writeByte('\'');
    }

    return buf.toOwnedSlice();
}

/// Serialize a request as .volt content, then base64-encode it.
/// Output format: volt import base64 '<base64string>'
fn shareBase64(allocator: Allocator, request: *const VoltFile.VoltRequest) ![]const u8 {
    // Serialize to .volt format
    const volt_content = try serializeRequest(allocator, request);
    defer allocator.free(volt_content);

    // Base64 encode
    const encoded = try encodeBase64(allocator, volt_content);
    defer allocator.free(encoded);

    return std.fmt.allocPrint(allocator, "volt import base64 '{s}'", .{encoded});
}

/// Percent-encode minimal request info into a query string format.
fn shareUrl(allocator: Allocator, request: *const VoltFile.VoltRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("volt://request?method=");
    try writer.writeAll(request.method.toString());
    try writer.writeAll("&url=");
    try percentEncode(writer, request.url);

    if (request.body) |body| {
        try writer.writeAll("&body=");
        try percentEncode(writer, body);
    }

    // Include headers
    for (request.headers.items) |h| {
        try writer.writeAll("&header=");
        try percentEncode(writer, h.name);
        try writer.writeAll(":");
        try percentEncode(writer, h.value);
    }

    return buf.toOwnedSlice();
}

// ── Base64 Helpers ────────────────────────────────────────────────────

/// Base64 encode data.
pub fn encodeBase64(allocator: Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard;
    const encoded_len = encoder.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = encoder.Encoder.encode(buf, data);
    return buf;
}

/// Base64 decode data.
pub fn decodeBase64(allocator: Allocator, encoded: []const u8) ![]const u8 {
    const decoder = std.base64.standard;
    const decoded_len = decoder.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const buf = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(buf);
    decoder.Decoder.decode(buf, encoded) catch return error.InvalidBase64;
    return buf;
}

/// Import a request from a base64-encoded string.
/// The returned VoltRequest holds slices into the decoded buffer.
/// Caller must keep the returned content_buf alive for the lifetime of the VoltRequest.
pub const ImportedRequest = struct {
    request: VoltFile.VoltRequest,
    content_buf: []const u8,

    pub fn deinit(self: *ImportedRequest, allocator: Allocator) void {
        self.request.deinit();
        allocator.free(self.content_buf);
    }
};

pub fn importFromBase64(allocator: Allocator, encoded: []const u8) !ImportedRequest {
    const decoded = try decodeBase64(allocator, encoded);
    errdefer allocator.free(decoded);

    const request = VoltFile.parse(allocator, decoded) catch {
        // decoded failed to parse; return default request but keep decoded
        // alive so deinit() can safely free it
        return .{
            .request = VoltFile.VoltRequest.init(allocator),
            .content_buf = decoded,
        };
    };

    return .{
        .request = request,
        .content_buf = decoded,
    };
}

/// Generate the default share string (base64 format with volt:// prefix).
pub fn generateShareString(allocator: Allocator, request: *const VoltFile.VoltRequest) ![]const u8 {
    const volt_content = try serializeRequest(allocator, request);
    defer allocator.free(volt_content);

    const encoded = try encodeBase64(allocator, volt_content);
    defer allocator.free(encoded);

    return std.fmt.allocPrint(allocator, "volt://import?data={s}", .{encoded});
}

// ── Serialization Helpers ─────────────────────────────────────────────

/// Serialize a VoltRequest back into .volt file format.
fn serializeRequest(allocator: Allocator, request: *const VoltFile.VoltRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    // Name
    if (request.name) |name| {
        try writer.print("name: {s}\n", .{name});
    }

    // Method and URL
    try writer.print("method: {s}\n", .{request.method.toString()});
    try writer.print("url: {s}\n", .{request.url});

    // Headers
    if (request.headers.items.len > 0) {
        try writer.writeAll("headers:\n");
        for (request.headers.items) |h| {
            try writer.print("  - {s}: {s}\n", .{ h.name, h.value });
        }
    }

    // Auth
    if (request.auth.type != .none) {
        try writer.writeAll("auth:\n");
        try writer.print("  type: {s}\n", .{request.auth.type.toString()});
        if (request.auth.token) |token| {
            try writer.print("  token: {s}\n", .{token});
        }
        if (request.auth.username) |user| {
            try writer.print("  username: {s}\n", .{user});
        }
        if (request.auth.password) |pass| {
            try writer.print("  password: {s}\n", .{pass});
        }
    }

    // Body
    if (request.body) |body| {
        try writer.print("body_type: {s}\n", .{request.body_type.toString()});
        try writer.writeAll("body: |\n");
        var body_lines = mem.splitSequence(u8, body, "\n");
        while (body_lines.next()) |bline| {
            try writer.print("  {s}\n", .{bline});
        }
    }

    return buf.toOwnedSlice();
}

/// Percent-encode a string for URL safety.
fn percentEncode(writer: anytype, input: []const u8) !void {
    const unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~";
    const hex_chars = "0123456789ABCDEF";

    for (input) |c| {
        if (mem.indexOf(u8, unreserved, &[_]u8{c}) != null) {
            try writer.writeByte(c);
        } else {
            try writer.writeByte('%');
            try writer.writeByte(hex_chars[@as(usize, c >> 4)]);
            try writer.writeByte(hex_chars[@as(usize, c & 0x0F)]);
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "encode and decode base64 roundtrip" {
    const allocator = std.testing.allocator;
    const original = "Hello, Volt API Client!";

    const encoded = try encodeBase64(allocator, original);
    defer allocator.free(encoded);

    // Encoded should be different from original
    try std.testing.expect(!mem.eql(u8, original, encoded));

    const decoded = try decodeBase64(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings(original, decoded);
}

test "encode base64 empty string" {
    const allocator = std.testing.allocator;

    const encoded = try encodeBase64(allocator, "");
    defer allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 0), encoded.len);

    const decoded = try decodeBase64(allocator, encoded);
    defer allocator.free(decoded);

    try std.testing.expectEqualStrings("", decoded);
}

test "share request as curl" {
    const allocator = std.testing.allocator;

    var req = VoltFile.VoltRequest.init(allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/users";
    try req.addHeader("Accept", "application/json");

    const result = try shareRequest(allocator, &req, .curl);
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "curl") != null);
    try std.testing.expect(mem.indexOf(u8, result, "https://api.example.com/users") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Accept: application/json") != null);
    // GET should not include -X flag
    try std.testing.expect(mem.indexOf(u8, result, "-X") == null);
}

test "share request as curl with POST" {
    const allocator = std.testing.allocator;

    var req = VoltFile.VoltRequest.init(allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/users";
    req.body = "{\"name\": \"test\"}";

    const result = try shareRequest(allocator, &req, .curl);
    defer allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "-X POST") != null);
    try std.testing.expect(mem.indexOf(u8, result, "-d") != null);
}

test "share request as base64" {
    const allocator = std.testing.allocator;

    var req = VoltFile.VoltRequest.init(allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/users";

    const result = try shareRequest(allocator, &req, .base64);
    defer allocator.free(result);

    try std.testing.expect(mem.startsWith(u8, result, "volt import base64 '"));
    try std.testing.expect(mem.endsWith(u8, result, "'"));
}

test "share request as url" {
    const allocator = std.testing.allocator;

    var req = VoltFile.VoltRequest.init(allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/users";

    const result = try shareRequest(allocator, &req, .url);
    defer allocator.free(result);

    try std.testing.expect(mem.startsWith(u8, result, "volt://request?"));
    try std.testing.expect(mem.indexOf(u8, result, "method=POST") != null);
    try std.testing.expect(mem.indexOf(u8, result, "url=") != null);
}

test "generate share string" {
    const allocator = std.testing.allocator;

    var req = VoltFile.VoltRequest.init(allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/health";

    const result = try generateShareString(allocator, &req);
    defer allocator.free(result);

    try std.testing.expect(mem.startsWith(u8, result, "volt://import?data="));
}

test "share format fromString" {
    try std.testing.expectEqual(ShareFormat.curl, ShareFormat.fromString("curl"));
    try std.testing.expectEqual(ShareFormat.base64, ShareFormat.fromString("base64"));
    try std.testing.expectEqual(ShareFormat.url, ShareFormat.fromString("url"));
    try std.testing.expectEqual(ShareFormat.base64, ShareFormat.fromString("unknown"));
}

test "serialize and import roundtrip" {
    const allocator = std.testing.allocator;

    var req = VoltFile.VoltRequest.init(allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/data";
    try req.addHeader("Content-Type", "application/json");

    // Serialize
    const serialized = try serializeRequest(allocator, &req);
    defer allocator.free(serialized);

    // Encode
    const encoded = try encodeBase64(allocator, serialized);
    defer allocator.free(encoded);

    // Import back
    var imported = try importFromBase64(allocator, encoded);
    defer imported.deinit(allocator);

    try std.testing.expectEqual(VoltFile.Method.POST, imported.request.method);
    try std.testing.expectEqualStrings("https://api.example.com/data", imported.request.url);
}
