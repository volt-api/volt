const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── cURL Command Import ─────────────────────────────────────────────────
// Parse cURL command strings into .volt file content.
// Supports: method, URL, headers, data, auth, cookies, form, compressed, insecure.

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const FormField = struct {
    name: []const u8,
    value: []const u8,
    is_file: bool,
};

pub const CurlParseResult = struct {
    allocator: Allocator,
    method: []const u8,
    method_owned: bool,
    url: []const u8,
    url_owned: bool,
    headers: std.ArrayList(Header),
    body: ?[]const u8,
    auth_type: []const u8, // "none", "basic", "bearer"
    auth_value: ?[]const u8,
    form_fields: std.ArrayList(FormField),
    insecure: bool,

    pub fn init(allocator: Allocator) CurlParseResult {
        return .{
            .allocator = allocator,
            .method = "GET",
            .method_owned = false,
            .url = "",
            .url_owned = false,
            .headers = std.ArrayList(Header).init(allocator),
            .body = null,
            .auth_type = "none",
            .auth_value = null,
            .form_fields = std.ArrayList(FormField).init(allocator),
            .insecure = false,
        };
    }

    pub fn deinit(self: *CurlParseResult) void {
        if (self.method_owned) self.allocator.free(self.method);
        if (self.url_owned) self.allocator.free(self.url);
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit();
        if (self.body) |b| self.allocator.free(b);
        if (self.auth_value) |v| self.allocator.free(v);
        for (self.form_fields.items) |f| {
            self.allocator.free(f.name);
            self.allocator.free(f.value);
        }
        self.form_fields.deinit();
    }
};

/// Parse a cURL command string into a CurlParseResult.
/// Handles quoted strings, backslash line continuations, and common flags.
pub fn parseCurl(allocator: Allocator, curl_command: []const u8) !CurlParseResult {
    var result = CurlParseResult.init(allocator);
    errdefer result.deinit();

    // Normalize line continuations: replace backslash-newline sequences with a space
    var normalized = std.ArrayList(u8).init(allocator);
    defer normalized.deinit();

    var i: usize = 0;
    while (i < curl_command.len) {
        if (curl_command[i] == '\\' and i + 1 < curl_command.len and (curl_command[i + 1] == '\n' or
            (curl_command[i + 1] == '\r' and i + 2 < curl_command.len and curl_command[i + 2] == '\n')))
        {
            try normalized.append(' ');
            i += if (curl_command[i + 1] == '\r') @as(usize, 3) else @as(usize, 2);
        } else {
            try normalized.append(curl_command[i]);
            i += 1;
        }
    }

    // Tokenize the normalized string respecting quotes
    var tokens = std.ArrayList([]const u8).init(allocator);
    defer tokens.deinit();

    var token_buf = std.ArrayList(u8).init(allocator);
    defer token_buf.deinit();

    var in_single_quote = false;
    var in_double_quote = false;
    var escaped = false;

    for (normalized.items) |c| {
        if (escaped) {
            try token_buf.append(c);
            escaped = false;
            continue;
        }
        if (c == '\\' and !in_single_quote) {
            escaped = true;
            continue;
        }
        if (c == '\'' and !in_double_quote) {
            in_single_quote = !in_single_quote;
            continue;
        }
        if (c == '"' and !in_single_quote) {
            in_double_quote = !in_double_quote;
            continue;
        }
        if ((c == ' ' or c == '\t' or c == '\n' or c == '\r') and !in_single_quote and !in_double_quote) {
            if (token_buf.items.len > 0) {
                const tok = try allocator.dupe(u8, token_buf.items);
                try tokens.append(tok);
                token_buf.clearRetainingCapacity();
            }
            continue;
        }
        try token_buf.append(c);
    }
    if (token_buf.items.len > 0) {
        const tok = try allocator.dupe(u8, token_buf.items);
        try tokens.append(tok);
    }

    // Free tokens on exit (they are duped into result fields or discarded)
    defer {
        for (tokens.items) |tok| {
            allocator.free(tok);
        }
    }

    // Parse tokens
    var has_explicit_method = false;
    var ti: usize = 0;
    while (ti < tokens.items.len) : (ti += 1) {
        const tok = tokens.items[ti];

        if (mem.eql(u8, tok, "curl")) {
            continue;
        }

        if (mem.eql(u8, tok, "-X") or mem.eql(u8, tok, "--request")) {
            ti += 1;
            if (ti < tokens.items.len) {
                if (result.method_owned) allocator.free(result.method);
                result.method = try allocator.dupe(u8, tokens.items[ti]);
                result.method_owned = true;
                has_explicit_method = true;
            }
            continue;
        }

        if (mem.eql(u8, tok, "-H") or mem.eql(u8, tok, "--header")) {
            ti += 1;
            if (ti < tokens.items.len) {
                const header_str = tokens.items[ti];
                // Check for Authorization: Bearer ... pattern
                if (parseHeaderString(header_str)) |hdr| {
                    if (std.ascii.eqlIgnoreCase(hdr.name, "Authorization")) {
                        if (mem.startsWith(u8, hdr.value, "Bearer ") or mem.startsWith(u8, hdr.value, "bearer ")) {
                            result.auth_type = "bearer";
                            result.auth_value = try allocator.dupe(u8, hdr.value[7..]);
                            continue;
                        }
                    }
                    try result.headers.append(.{
                        .name = try allocator.dupe(u8, hdr.name),
                        .value = try allocator.dupe(u8, hdr.value),
                    });
                }
            }
            continue;
        }

        if (mem.eql(u8, tok, "-d") or mem.eql(u8, tok, "--data") or
            mem.eql(u8, tok, "--data-raw") or mem.eql(u8, tok, "--data-binary"))
        {
            ti += 1;
            if (ti < tokens.items.len) {
                result.body = try allocator.dupe(u8, tokens.items[ti]);
                if (!has_explicit_method) {
                    result.method = "POST";
                }
            }
            continue;
        }

        if (mem.eql(u8, tok, "-u") or mem.eql(u8, tok, "--user")) {
            ti += 1;
            if (ti < tokens.items.len) {
                result.auth_type = "basic";
                result.auth_value = try allocator.dupe(u8, tokens.items[ti]);
            }
            continue;
        }

        if (mem.eql(u8, tok, "-b") or mem.eql(u8, tok, "--cookie")) {
            ti += 1;
            if (ti < tokens.items.len) {
                try result.headers.append(.{
                    .name = try allocator.dupe(u8, "Cookie"),
                    .value = try allocator.dupe(u8, tokens.items[ti]),
                });
            }
            continue;
        }

        if (mem.eql(u8, tok, "-F") or mem.eql(u8, tok, "--form")) {
            ti += 1;
            if (ti < tokens.items.len) {
                const form_str = tokens.items[ti];
                if (mem.indexOf(u8, form_str, "=")) |eq_pos| {
                    const fname = form_str[0..eq_pos];
                    const fval = form_str[eq_pos + 1 ..];
                    const is_file = fval.len > 0 and fval[0] == '@';
                    try result.form_fields.append(.{
                        .name = try allocator.dupe(u8, fname),
                        .value = try allocator.dupe(u8, if (is_file) fval[1..] else fval),
                        .is_file = is_file,
                    });
                    if (!has_explicit_method) {
                        result.method = "POST";
                    }
                }
            }
            continue;
        }

        if (mem.eql(u8, tok, "--compressed")) {
            // Accept-Encoding is implicit; just skip
            continue;
        }

        if (mem.eql(u8, tok, "-k") or mem.eql(u8, tok, "--insecure")) {
            result.insecure = true;
            continue;
        }

        // If the token doesn't start with '-', treat it as the URL
        if (tok.len > 0 and tok[0] != '-') {
            if (result.url_owned) allocator.free(result.url);
            result.url = try allocator.dupe(u8, tok);
            result.url_owned = true;
            continue;
        }
    }

    return result;
}

/// Convert a CurlParseResult into .volt file content string.
pub fn toVoltContent(allocator: Allocator, result: *const CurlParseResult) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Method
    try writer.print("method: {s}\n", .{result.method});

    // URL
    try writer.print("url: {s}\n", .{result.url});

    // Headers
    if (result.headers.items.len > 0) {
        try writer.writeAll("headers:\n");
        for (result.headers.items) |h| {
            try writer.print("  - {s}: {s}\n", .{ h.name, h.value });
        }
    }

    // Body
    if (result.body) |body| {
        try writer.writeAll("body:\n");
        // Detect JSON body
        if (body.len > 0 and (body[0] == '{' or body[0] == '[')) {
            try writer.writeAll("  type: json\n");
        } else {
            try writer.writeAll("  type: raw\n");
        }
        try writer.print("  content: {s}\n", .{body});
    }

    // Form fields (multipart)
    if (result.form_fields.items.len > 0 and result.body == null) {
        try writer.writeAll("body:\n");
        try writer.writeAll("  type: multipart\n");
        try writer.writeAll("  fields:\n");
        for (result.form_fields.items) |field| {
            if (field.is_file) {
                try writer.print("    - {s}: @{s}\n", .{ field.name, field.value });
            } else {
                try writer.print("    - {s}: {s}\n", .{ field.name, field.value });
            }
        }
    }

    // Auth
    if (mem.eql(u8, result.auth_type, "bearer")) {
        try writer.writeAll("auth:\n");
        try writer.writeAll("  type: bearer\n");
        if (result.auth_value) |token| {
            try writer.print("  token: {s}\n", .{token});
        }
    } else if (mem.eql(u8, result.auth_type, "basic")) {
        try writer.writeAll("auth:\n");
        try writer.writeAll("  type: basic\n");
        if (result.auth_value) |creds| {
            // Split user:pass
            if (mem.indexOf(u8, creds, ":")) |colon_pos| {
                try writer.print("  username: {s}\n", .{creds[0..colon_pos]});
                try writer.print("  password: {s}\n", .{creds[colon_pos + 1 ..]});
            } else {
                try writer.print("  username: {s}\n", .{creds});
            }
        }
    }

    return buf.toOwnedSlice();
}

// ── Internal Helpers ────────────────────────────────────────────────────

const ParsedHeader = struct {
    name: []const u8,
    value: []const u8,
};

fn parseHeaderString(s: []const u8) ?ParsedHeader {
    // Header format: "Name: Value" or "Name:Value"
    if (mem.indexOf(u8, s, ":")) |colon_pos| {
        const name = mem.trim(u8, s[0..colon_pos], " \t");
        const value_start = colon_pos + 1;
        const value = if (value_start < s.len) mem.trim(u8, s[value_start..], " \t") else "";
        if (name.len > 0) {
            return .{ .name = name, .value = value };
        }
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse simple GET with headers" {
    const curl_cmd = "curl -X GET 'https://api.example.com/users' -H 'Accept: application/json' -H 'X-Api-Key: abc123'";
    var result = try parseCurl(std.testing.allocator, curl_cmd);
    defer result.deinit();

    try std.testing.expectEqualStrings("GET", result.method);
    try std.testing.expectEqualStrings("https://api.example.com/users", result.url);
    try std.testing.expectEqual(@as(usize, 2), result.headers.items.len);
    try std.testing.expectEqualStrings("Accept", result.headers.items[0].name);
    try std.testing.expectEqualStrings("application/json", result.headers.items[0].value);
    try std.testing.expectEqualStrings("X-Api-Key", result.headers.items[1].name);
    try std.testing.expectEqualStrings("abc123", result.headers.items[1].value);
}

test "parse POST with JSON body and auth" {
    const curl_cmd =
        \\curl -X POST https://api.example.com/data \
        \\  -H "Content-Type: application/json" \
        \\  -H "Authorization: Bearer my-token-123" \
        \\  -d '{"name": "test", "value": 42}'
    ;
    var result = try parseCurl(std.testing.allocator, curl_cmd);
    defer result.deinit();

    try std.testing.expectEqualStrings("POST", result.method);
    try std.testing.expectEqualStrings("https://api.example.com/data", result.url);
    try std.testing.expectEqualStrings("bearer", result.auth_type);
    try std.testing.expectEqualStrings("my-token-123", result.auth_value.?);
    try std.testing.expect(result.body != null);
    try std.testing.expect(mem.indexOf(u8, result.body.?, "\"name\"") != null);
    try std.testing.expectEqual(@as(usize, 1), result.headers.items.len);
    try std.testing.expectEqualStrings("Content-Type", result.headers.items[0].name);
}

test "parse multipart form data" {
    const curl_cmd = "curl https://api.example.com/upload -F 'file=@photo.jpg' -F 'description=My photo' -k";
    var result = try parseCurl(std.testing.allocator, curl_cmd);
    defer result.deinit();

    try std.testing.expectEqualStrings("POST", result.method);
    try std.testing.expectEqualStrings("https://api.example.com/upload", result.url);
    try std.testing.expect(result.insecure);
    try std.testing.expectEqual(@as(usize, 2), result.form_fields.items.len);
    try std.testing.expectEqualStrings("file", result.form_fields.items[0].name);
    try std.testing.expectEqualStrings("photo.jpg", result.form_fields.items[0].value);
    try std.testing.expect(result.form_fields.items[0].is_file);
    try std.testing.expectEqualStrings("description", result.form_fields.items[1].name);
    try std.testing.expectEqualStrings("My photo", result.form_fields.items[1].value);
    try std.testing.expect(!result.form_fields.items[1].is_file);
}
