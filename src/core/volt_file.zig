const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Data Types ──────────────────────────────────────────────────────────

pub const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
    OPTIONS,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .PATCH => "PATCH",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
        };
    }

    pub fn fromString(s: []const u8) ?Method {
        const upper = s;
        if (mem.eql(u8, upper, "GET")) return .GET;
        if (mem.eql(u8, upper, "POST")) return .POST;
        if (mem.eql(u8, upper, "PUT")) return .PUT;
        if (mem.eql(u8, upper, "PATCH")) return .PATCH;
        if (mem.eql(u8, upper, "DELETE")) return .DELETE;
        if (mem.eql(u8, upper, "HEAD")) return .HEAD;
        if (mem.eql(u8, upper, "OPTIONS")) return .OPTIONS;
        return null;
    }
};

pub const BodyType = enum {
    json,
    form,
    xml,
    raw,
    multipart,
    none,

    pub fn toString(self: BodyType) []const u8 {
        return switch (self) {
            .json => "json",
            .form => "form",
            .xml => "xml",
            .raw => "raw",
            .multipart => "multipart",
            .none => "none",
        };
    }

    pub fn fromString(s: []const u8) BodyType {
        if (mem.eql(u8, s, "json")) return .json;
        if (mem.eql(u8, s, "form")) return .form;
        if (mem.eql(u8, s, "xml")) return .xml;
        if (mem.eql(u8, s, "raw")) return .raw;
        if (mem.eql(u8, s, "multipart")) return .multipart;
        return .none;
    }
};

pub const AuthType = enum {
    none,
    bearer,
    basic,
    api_key,
    digest,

    pub fn toString(self: AuthType) []const u8 {
        return switch (self) {
            .none => "none",
            .bearer => "bearer",
            .basic => "basic",
            .api_key => "api_key",
            .digest => "digest",
        };
    }

    pub fn fromString(s: []const u8) AuthType {
        if (mem.eql(u8, s, "bearer")) return .bearer;
        if (mem.eql(u8, s, "basic")) return .basic;
        if (mem.eql(u8, s, "api_key")) return .api_key;
        if (mem.eql(u8, s, "digest")) return .digest;
        return .none;
    }
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Auth = struct {
    type: AuthType = .none,
    token: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    key_name: ?[]const u8 = null,
    key_value: ?[]const u8 = null,
    key_location: ?[]const u8 = null, // "header" or "query"
};

pub const TestAssertion = struct {
    field: []const u8,
    operator: []const u8,
    value: []const u8,
};

pub const VoltRequest = struct {
    allocator: Allocator,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    method: Method = .GET,
    url: []const u8 = "",
    headers: std.ArrayList(Header),
    body_type: BodyType = .none,
    body: ?[]const u8 = null,
    body_owned: bool = false,
    auth: Auth = .{},
    tests: std.ArrayList(TestAssertion),
    variables: std.StringHashMap([]const u8),
    pre_script: ?[]const u8 = null,
    pre_script_owned: bool = false,
    post_script: ?[]const u8 = null,
    post_script_owned: bool = false,
    timeout: ?u32 = null,
    tags: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) VoltRequest {
        return .{
            .allocator = allocator,
            .headers = std.ArrayList(Header).init(allocator),
            .tests = std.ArrayList(TestAssertion).init(allocator),
            .variables = std.StringHashMap([]const u8).init(allocator),
            .tags = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *VoltRequest) void {
        if (self.body_owned) {
            if (self.body) |b| self.allocator.free(b);
        }
        if (self.pre_script_owned) {
            if (self.pre_script) |s| self.allocator.free(s);
        }
        if (self.post_script_owned) {
            if (self.post_script) |s| self.allocator.free(s);
        }
        self.headers.deinit();
        self.tests.deinit();
        self.variables.deinit();
        self.tags.deinit();
    }

    pub fn addHeader(self: *VoltRequest, name: []const u8, value: []const u8) !void {
        try self.headers.append(.{ .name = name, .value = value });
    }
};

// ── YAML Parser (.volt format) ──────────────────────────────────────────

pub const ParseError = error{
    InvalidFormat,
    UnexpectedToken,
    MissingField,
    OutOfMemory,
};

/// Parse a .volt file content into a VoltRequest
pub fn parse(allocator: Allocator, content: []const u8) ParseError!VoltRequest {
    var request = VoltRequest.init(allocator);
    errdefer request.deinit();

    var current_section: enum {
        none,
        headers,
        body,
        auth,
        tests,
        variables,
        pre_script,
        post_script,
    } = .none;

    var body_lines = std.ArrayList(u8).init(allocator);
    defer body_lines.deinit();
    var script_lines = std.ArrayList(u8).init(allocator);
    defer script_lines.deinit();
    var in_multiline_body = false;
    var in_multiline_script = false;
    var current_script_section: enum { none, pre, post } = .none;

    var lines = mem.splitSequence(u8, content, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trimRight(u8, raw_line, "\r");

        // Handle multiline body (YAML block scalar)
        if (in_multiline_body) {
            if (line.len > 0 and line[0] != ' ' and line[0] != '\t') {
                // End of multiline block
                in_multiline_body = false;
                request.body = body_lines.toOwnedSlice() catch null;
                request.body_owned = request.body != null;
            } else {
                // Strip 2-4 spaces of indentation
                const trimmed = trimIndent(line);
                if (body_lines.items.len > 0) {
                    body_lines.append('\n') catch return ParseError.OutOfMemory;
                }
                body_lines.appendSlice(trimmed) catch return ParseError.OutOfMemory;
                continue;
            }
        }

        // Handle multiline script
        if (in_multiline_script) {
            if (line.len > 0 and line[0] != ' ' and line[0] != '\t') {
                in_multiline_script = false;
                const script_content = script_lines.toOwnedSlice() catch null;
                const is_owned = script_content != null;
                switch (current_script_section) {
                    .pre => {
                        request.pre_script = script_content;
                        request.pre_script_owned = is_owned;
                    },
                    .post => {
                        request.post_script = script_content;
                        request.post_script_owned = is_owned;
                    },
                    .none => {},
                }
            } else {
                const trimmed = trimIndent(line);
                if (script_lines.items.len > 0) {
                    script_lines.append('\n') catch return ParseError.OutOfMemory;
                }
                script_lines.appendSlice(trimmed) catch return ParseError.OutOfMemory;
                continue;
            }
        }

        const trimmed = mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Top-level keys
        if (mem.startsWith(u8, trimmed, "name:")) {
            request.name = extractValue(trimmed, "name:");
            current_section = .none;
        } else if (mem.startsWith(u8, trimmed, "description:")) {
            request.description = extractValue(trimmed, "description:");
            current_section = .none;
        } else if (mem.startsWith(u8, trimmed, "timeout:")) {
            const val = extractValue(trimmed, "timeout:");
            if (val) |v| {
                request.timeout = std.fmt.parseInt(u32, v, 10) catch null;
            }
            current_section = .none;
        } else if (mem.startsWith(u8, trimmed, "tags:")) {
            const val = extractValue(trimmed, "tags:");
            if (val) |v| {
                var tag_iter = mem.splitSequence(u8, v, ",");
                while (tag_iter.next()) |raw_tag| {
                    const tag = mem.trim(u8, raw_tag, " \t");
                    if (tag.len > 0) {
                        request.tags.append(tag) catch return ParseError.OutOfMemory;
                    }
                }
            }
            current_section = .none;
        } else if (mem.startsWith(u8, trimmed, "method:")) {
            const val = extractValue(trimmed, "method:");
            if (val) |v| {
                request.method = Method.fromString(v) orelse .GET;
            }
            current_section = .none;
        } else if (mem.startsWith(u8, trimmed, "url:")) {
            request.url = extractValue(trimmed, "url:") orelse "";
            current_section = .none;
        } else if (mem.eql(u8, trimmed, "headers:")) {
            current_section = .headers;
        } else if (mem.startsWith(u8, trimmed, "body:")) {
            current_section = .body;
            // Check for inline body type indicator
            const body_val = extractValue(trimmed, "body:");
            if (body_val) |bv| {
                if (mem.eql(u8, bv, "|")) {
                    in_multiline_body = true;
                    body_lines.clearRetainingCapacity();
                }
            }
        } else if (mem.startsWith(u8, trimmed, "type:") and current_section == .body) {
            const val = extractValue(trimmed, "type:");
            if (val) |v| {
                request.body_type = BodyType.fromString(v);
            }
        } else if (mem.startsWith(u8, trimmed, "content:") and current_section == .body) {
            const val = extractValue(trimmed, "content:");
            if (val) |v| {
                if (mem.eql(u8, v, "|")) {
                    in_multiline_body = true;
                    body_lines.clearRetainingCapacity();
                } else {
                    request.body = v;
                }
            }
        } else if (mem.eql(u8, trimmed, "auth:")) {
            current_section = .auth;
        } else if (mem.eql(u8, trimmed, "tests:")) {
            current_section = .tests;
        } else if (mem.eql(u8, trimmed, "variables:")) {
            current_section = .variables;
        } else if (mem.startsWith(u8, trimmed, "pre_script:")) {
            current_section = .pre_script;
            const val = extractValue(trimmed, "pre_script:");
            if (val) |v| {
                if (mem.eql(u8, v, "|")) {
                    in_multiline_script = true;
                    current_script_section = .pre;
                    script_lines.clearRetainingCapacity();
                }
            }
        } else if (mem.startsWith(u8, trimmed, "post_script:")) {
            current_section = .post_script;
            const val = extractValue(trimmed, "post_script:");
            if (val) |v| {
                if (mem.eql(u8, v, "|")) {
                    in_multiline_script = true;
                    current_script_section = .post;
                    script_lines.clearRetainingCapacity();
                }
            }
        } else if (current_section == .headers and mem.startsWith(u8, trimmed, "- ")) {
            // Parse header: "- Name: Value"
            const entry = trimmed[2..];
            if (mem.indexOf(u8, entry, ": ")) |colon_pos| {
                const hdr_name = entry[0..colon_pos];
                const hdr_value = entry[colon_pos + 2 ..];
                request.addHeader(hdr_name, hdr_value) catch return ParseError.OutOfMemory;
            }
        } else if (current_section == .auth) {
            if (mem.startsWith(u8, trimmed, "type:")) {
                const val = extractValue(trimmed, "type:");
                if (val) |v| request.auth.type = AuthType.fromString(v);
            } else if (mem.startsWith(u8, trimmed, "token:")) {
                request.auth.token = extractValue(trimmed, "token:");
            } else if (mem.startsWith(u8, trimmed, "username:")) {
                request.auth.username = extractValue(trimmed, "username:");
            } else if (mem.startsWith(u8, trimmed, "password:")) {
                request.auth.password = extractValue(trimmed, "password:");
            } else if (mem.startsWith(u8, trimmed, "key_name:")) {
                request.auth.key_name = extractValue(trimmed, "key_name:");
            } else if (mem.startsWith(u8, trimmed, "key_value:")) {
                request.auth.key_value = extractValue(trimmed, "key_value:");
            } else if (mem.startsWith(u8, trimmed, "key_location:")) {
                request.auth.key_location = extractValue(trimmed, "key_location:");
            }
        } else if (current_section == .tests and mem.startsWith(u8, trimmed, "- ")) {
            // Parse test: "- status equals 200"
            const entry = trimmed[2..];
            var parts = mem.splitSequence(u8, entry, " ");
            const field = parts.next() orelse continue;
            const operator = parts.next() orelse continue;
            const value = parts.rest();
            if (value.len > 0) {
                request.tests.append(.{
                    .field = field,
                    .operator = operator,
                    .value = value,
                }) catch return ParseError.OutOfMemory;
            }
        } else if (current_section == .variables) {
            // Parse "key: value" under variables section
            if (mem.indexOf(u8, trimmed, ": ")) |colon_pos| {
                const key = trimmed[0..colon_pos];
                const value = trimmed[colon_pos + 2 ..];
                request.variables.put(key, value) catch return ParseError.OutOfMemory;
            }
        }
    }

    // Handle EOF while still in multiline
    if (in_multiline_body and body_lines.items.len > 0) {
        request.body = body_lines.toOwnedSlice() catch null;
        request.body_owned = request.body != null;
    }
    if (in_multiline_script and script_lines.items.len > 0) {
        const script_content = script_lines.toOwnedSlice() catch null;
        const is_owned = script_content != null;
        switch (current_script_section) {
            .pre => {
                request.pre_script = script_content;
                request.pre_script_owned = is_owned;
            },
            .post => {
                request.post_script = script_content;
                request.post_script_owned = is_owned;
            },
            .none => {},
        }
    }

    return request;
}

fn trimIndent(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and i < 4) : (i += 1) {
        if (line[i] != ' ' and line[i] != '\t') break;
    }
    return line[i..];
}

fn extractValue(line: []const u8, key: []const u8) ?[]const u8 {
    if (!mem.startsWith(u8, line, key)) return null;
    const rest = mem.trim(u8, line[key.len..], " \t");
    if (rest.len == 0) return null;
    // Remove quotes if present
    if (rest.len >= 2 and rest[0] == '"' and rest[rest.len - 1] == '"') {
        return rest[1 .. rest.len - 1];
    }
    return rest;
}

// ── Serializer ──────────────────────────────────────────────────────────

pub fn serialize(request: *const VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Name
    if (request.name) |name| {
        try writer.print("name: {s}\n", .{name});
    }

    // Description
    if (request.description) |desc| {
        try writer.print("description: {s}\n", .{desc});
    }

    // Method and URL
    try writer.print("method: {s}\n", .{request.method.toString()});
    try writer.print("url: {s}\n", .{request.url});

    // Headers
    if (request.headers.items.len > 0) {
        try writer.writeAll("headers:\n");
        for (request.headers.items) |header| {
            try writer.print("  - {s}: {s}\n", .{ header.name, header.value });
        }
    }

    // Body
    if (request.body_type != .none) {
        try writer.writeAll("body:\n");
        try writer.print("  type: {s}\n", .{request.body_type.toString()});
        if (request.body) |body| {
            if (mem.indexOf(u8, body, "\n") != null) {
                try writer.writeAll("  content: |\n");
                var body_lines = mem.splitSequence(u8, body, "\n");
                while (body_lines.next()) |bl| {
                    try writer.print("    {s}\n", .{bl});
                }
            } else {
                try writer.print("  content: {s}\n", .{body});
            }
        }
    }

    // Auth
    if (request.auth.type != .none) {
        try writer.writeAll("auth:\n");
        try writer.print("  type: {s}\n", .{request.auth.type.toString()});
        if (request.auth.token) |token| {
            try writer.print("  token: {s}\n", .{token});
        }
        if (request.auth.username) |username| {
            try writer.print("  username: {s}\n", .{username});
        }
        if (request.auth.password) |password| {
            try writer.print("  password: {s}\n", .{password});
        }
        if (request.auth.key_name) |key_name| {
            try writer.print("  key_name: {s}\n", .{key_name});
        }
        if (request.auth.key_value) |key_value| {
            try writer.print("  key_value: {s}\n", .{key_value});
        }
        if (request.auth.key_location) |key_location| {
            try writer.print("  key_location: {s}\n", .{key_location});
        }
    }

    // Tests
    if (request.tests.items.len > 0) {
        try writer.writeAll("tests:\n");
        for (request.tests.items) |t| {
            try writer.print("  - {s} {s} {s}\n", .{ t.field, t.operator, t.value });
        }
    }

    // Variables
    if (request.variables.count() > 0) {
        try writer.writeAll("variables:\n");
        var it = request.variables.iterator();
        while (it.next()) |entry| {
            try writer.print("  {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    // Timeout
    if (request.timeout) |t| {
        try writer.print("timeout: {d}\n", .{t});
    }

    // Tags
    if (request.tags.items.len > 0) {
        try writer.writeAll("tags: ");
        for (request.tags.items, 0..) |tag, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll(tag);
        }
        try writer.writeAll("\n");
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse minimal .volt file" {
    const content =
        \\method: GET
        \\url: https://api.example.com/users
    ;
    var request = try parse(std.testing.allocator, content);
    defer request.deinit();

    try std.testing.expectEqual(Method.GET, request.method);
    try std.testing.expectEqualStrings("https://api.example.com/users", request.url);
}

test "parse .volt file with headers" {
    const content =
        \\method: POST
        \\url: https://api.example.com/users
        \\headers:
        \\  - Content-Type: application/json
        \\  - Authorization: Bearer token123
    ;
    var request = try parse(std.testing.allocator, content);
    defer request.deinit();

    try std.testing.expectEqual(Method.POST, request.method);
    try std.testing.expectEqual(@as(usize, 2), request.headers.items.len);
    try std.testing.expectEqualStrings("Content-Type", request.headers.items[0].name);
    try std.testing.expectEqualStrings("application/json", request.headers.items[0].value);
}

test "parse .volt file with auth" {
    const content =
        \\method: GET
        \\url: https://api.example.com/me
        \\auth:
        \\  type: bearer
        \\  token: my-secret-token
    ;
    var request = try parse(std.testing.allocator, content);
    defer request.deinit();

    try std.testing.expectEqual(AuthType.bearer, request.auth.type);
    try std.testing.expectEqualStrings("my-secret-token", request.auth.token.?);
}

test "parse .volt file with tests" {
    const content =
        \\method: GET
        \\url: https://api.example.com/health
        \\tests:
        \\  - status equals 200
        \\  - body.status equals ok
    ;
    var request = try parse(std.testing.allocator, content);
    defer request.deinit();

    try std.testing.expectEqual(@as(usize, 2), request.tests.items.len);
    try std.testing.expectEqualStrings("status", request.tests.items[0].field);
    try std.testing.expectEqualStrings("equals", request.tests.items[0].operator);
    try std.testing.expectEqualStrings("200", request.tests.items[0].value);
}

test "parse .volt file with tags" {
    const content =
        \\method: GET
        \\url: https://api.example.com/users
        \\tags: auth, users, v2
    ;
    var request = try parse(std.testing.allocator, content);
    defer request.deinit();

    try std.testing.expectEqual(@as(usize, 3), request.tags.items.len);
    try std.testing.expectEqualStrings("auth", request.tags.items[0]);
    try std.testing.expectEqualStrings("users", request.tags.items[1]);
    try std.testing.expectEqualStrings("v2", request.tags.items[2]);
}

test "parse .volt file with single tag" {
    const content =
        \\method: POST
        \\url: https://api.example.com/login
        \\tags: auth
    ;
    var request = try parse(std.testing.allocator, content);
    defer request.deinit();

    try std.testing.expectEqual(@as(usize, 1), request.tags.items.len);
    try std.testing.expectEqualStrings("auth", request.tags.items[0]);
}

test "serialize tags roundtrip" {
    var request = VoltRequest.init(std.testing.allocator);
    defer request.deinit();
    request.method = .GET;
    request.url = "https://api.example.com/users";
    try request.tags.append("auth");
    try request.tags.append("users");
    try request.tags.append("v2");

    const output = try serialize(&request, std.testing.allocator);
    defer std.testing.allocator.free(output);

    try std.testing.expect(mem.indexOf(u8, output, "tags: auth, users, v2") != null);

    // Verify roundtrip
    var parsed = try parse(std.testing.allocator, output);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.tags.items.len);
    try std.testing.expectEqualStrings("auth", parsed.tags.items[0]);
    try std.testing.expectEqualStrings("users", parsed.tags.items[1]);
    try std.testing.expectEqualStrings("v2", parsed.tags.items[2]);
}

test "serialize and roundtrip" {
    var request = VoltRequest.init(std.testing.allocator);
    defer request.deinit();
    request.method = .POST;
    request.url = "https://api.example.com/users";
    try request.addHeader("Content-Type", "application/json");

    const output = try serialize(&request, std.testing.allocator);
    defer std.testing.allocator.free(output);

    try std.testing.expect(mem.indexOf(u8, output, "method: POST") != null);
    try std.testing.expect(mem.indexOf(u8, output, "url: https://api.example.com/users") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Content-Type: application/json") != null);
}
