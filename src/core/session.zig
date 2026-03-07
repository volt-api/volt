const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── Named Session Manager ─────────────────────────────────────────────
// Stores per-host sessions (headers, cookies, auth) in JSON files.
// Sessions persist across requests, enabling workflows like:
//   volt run login.volt --session=myapi     # saves auth token
//   volt run users.volt --session=myapi     # reuses auth token

pub const SessionAuth = struct {
    auth_type: []const u8 = "",
    token: []const u8 = "",
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8 = "",
    path: []const u8 = "/",
};

pub const Session = struct {
    allocator: Allocator,
    name: []const u8,
    host: []const u8,
    headers: std.StringHashMap([]const u8),
    cookies: std.ArrayList(Cookie),
    auth: SessionAuth = .{},
    updated_at: []const u8 = "",

    /// Owned strings that need to be freed
    _owned_strings: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator, name: []const u8, host: []const u8) Session {
        return .{
            .allocator = allocator,
            .name = name,
            .host = host,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .cookies = std.ArrayList(Cookie).init(allocator),
            ._owned_strings = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Session) void {
        self.headers.deinit();
        self.cookies.deinit();
        for (self._owned_strings.items) |s| self.allocator.free(s);
        self._owned_strings.deinit();
    }

    fn trackString(self: *Session, s: []const u8) void {
        self._owned_strings.append(s) catch {};
    }
};

/// Load a named session from disk.
pub fn loadSession(allocator: Allocator, name: []const u8, host: []const u8) !?Session {
    const path = try sessionPath(allocator, name, host);
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    const result = try parseSessionJson(allocator, name, host, content);
    return result;
}

/// Save a session to disk as JSON.
pub fn saveSession(allocator: Allocator, session: *const Session) !void {
    const path = try sessionPath(allocator, session.name, session.host);
    defer allocator.free(path);

    // Ensure directory exists
    const dir_path = try sessionDir(allocator, session.host);
    defer allocator.free(dir_path);
    try std.fs.cwd().makePath(dir_path);

    const json = try serializeSession(allocator, session);
    defer allocator.free(json);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(json);
}

/// List all sessions for a given host (or all hosts).
pub fn listSessions(allocator: Allocator) !std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(allocator);

    var base_dir = std.fs.cwd().openDir(".volt-sessions", .{ .iterate = true }) catch return results;
    defer base_dir.close();

    var iter = base_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            var host_dir = base_dir.openDir(entry.name, .{ .iterate = true }) catch continue;
            defer host_dir.close();
            var host_iter = host_dir.iterate();
            while (try host_iter.next()) |file_entry| {
                if (file_entry.kind == .file and mem.endsWith(u8, file_entry.name, ".json")) {
                    const session_name = file_entry.name[0 .. file_entry.name.len - 5]; // strip .json
                    const display = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.name, session_name });
                    try results.append(display);
                }
            }
        }
    }

    return results;
}

/// Delete a named session.
pub fn deleteSession(allocator: Allocator, name: []const u8, host: []const u8) !void {
    const path = try sessionPath(allocator, name, host);
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

/// Apply session headers and cookies to a request's header list.
/// Returns allocated header strings that the caller must free.
pub fn applySession(session: *const Session, headers: *std.ArrayList(Header), allocator: Allocator) !void {
    // Merge session headers (session headers don't override existing request headers)
    var h_iter = session.headers.iterator();
    while (h_iter.next()) |entry| {
        var found = false;
        for (headers.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.name, entry.key_ptr.*)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try headers.append(.{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
        }
    }

    // Add session cookies as Cookie header
    if (session.cookies.items.len > 0) {
        var cookie_buf = std.ArrayList(u8).init(allocator);
        defer cookie_buf.deinit();
        for (session.cookies.items, 0..) |cookie, i| {
            if (i > 0) try cookie_buf.appendSlice("; ");
            try cookie_buf.appendSlice(cookie.name);
            try cookie_buf.append('=');
            try cookie_buf.appendSlice(cookie.value);
        }
        const cookie_str = try cookie_buf.toOwnedSlice();
        // Caller should be aware these point into session memory
        try headers.append(.{ .name = "Cookie", .value = cookie_str });
    }

    // Apply auth
    if (session.auth.token.len > 0) {
        var found = false;
        for (headers.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.name, "Authorization")) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (mem.eql(u8, session.auth.auth_type, "bearer")) {
                const auth_val = try std.fmt.allocPrint(allocator, "Bearer {s}", .{session.auth.token});
                try headers.append(.{ .name = "Authorization", .value = auth_val });
            }
        }
    }
}

/// Update session from response Set-Cookie headers.
pub fn updateFromResponse(session: *Session, response_headers: []const Header) void {
    for (response_headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Set-Cookie") or std.ascii.eqlIgnoreCase(h.name, "set-cookie")) {
            // Parse "name=value; ..." from Set-Cookie
            const cookie_str = h.value;
            if (mem.indexOf(u8, cookie_str, "=")) |eq_pos| {
                const cname = cookie_str[0..eq_pos];
                const rest = cookie_str[eq_pos + 1 ..];
                // Value is up to first ';' or end
                const semi = mem.indexOf(u8, rest, ";") orelse rest.len;
                const cvalue = rest[0..semi];

                // Duplicate strings for session ownership
                const owned_name = session.allocator.dupe(u8, cname) catch continue;
                const owned_value = session.allocator.dupe(u8, cvalue) catch {
                    session.allocator.free(owned_name);
                    continue;
                };
                session.trackString(owned_name);
                session.trackString(owned_value);

                // Update existing or add new
                var found = false;
                for (session.cookies.items) |*cookie| {
                    if (mem.eql(u8, cookie.name, cname)) {
                        cookie.value = owned_value;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    session.cookies.append(.{
                        .name = owned_name,
                        .value = owned_value,
                        .domain = session.host,
                    }) catch {};
                }
            }
        }
    }
}

// Use VoltFile.Header for compatibility
pub const Header = VoltFile.Header;

// ── Internal Helpers ───────────────────────────────────────────────────

fn sessionDir(allocator: Allocator, host: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".volt-sessions/{s}", .{host});
}

fn sessionPath(allocator: Allocator, name: []const u8, host: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, ".volt-sessions/{s}/{s}.json", .{ host, name });
}

fn parseSessionJson(allocator: Allocator, name: []const u8, host: []const u8, content: []const u8) !Session {
    var session = Session.init(allocator, name, host);
    errdefer session.deinit();

    // Simple JSON parser for session format
    // Look for "headers": { ... }
    if (mem.indexOf(u8, content, "\"headers\"")) |_| {
        // Find headers object
        if (findJsonObject(content, "headers")) |headers_str| {
            var lines = mem.splitSequence(u8, headers_str, "\n");
            while (lines.next()) |line| {
                const trimmed = mem.trim(u8, line, " \t\r,");
                if (trimmed.len < 5) continue;
                if (trimmed[0] != '"') continue;
                // Parse "Key": "Value"
                if (mem.indexOf(u8, trimmed[1..], "\"")) |end_key| {
                    const key = trimmed[1 .. end_key + 1];
                    const after_key = trimmed[end_key + 2 ..];
                    if (mem.indexOf(u8, after_key, "\"")) |val_start| {
                        const val_rest = after_key[val_start + 1 ..];
                        if (mem.indexOf(u8, val_rest, "\"")) |val_end| {
                            const val = val_rest[0..val_end];
                            const owned_key = try allocator.dupe(u8, key);
                            session.trackString(owned_key);
                            const owned_val = try allocator.dupe(u8, val);
                            session.trackString(owned_val);
                            try session.headers.put(owned_key, owned_val);
                        }
                    }
                }
            }
        }
    }

    // Parse cookies array
    if (mem.indexOf(u8, content, "\"cookies\"")) |_| {
        // Simple extraction of cookie name/value pairs
        var search_pos: usize = 0;
        while (search_pos < content.len) {
            const cookie_name_start = mem.indexOf(u8, content[search_pos..], "\"name\"") orelse break;
            const abs_pos = search_pos + cookie_name_start;
            if (extractJsonStringValue(content[abs_pos..])) |cname| {
                const value_start = mem.indexOf(u8, content[abs_pos + 6 ..], "\"value\"") orelse break;
                const abs_val = abs_pos + 6 + value_start;
                if (extractJsonStringValue(content[abs_val..])) |cvalue| {
                    const owned_name = try allocator.dupe(u8, cname);
                    session.trackString(owned_name);
                    const owned_value = try allocator.dupe(u8, cvalue);
                    session.trackString(owned_value);
                    try session.cookies.append(.{
                        .name = owned_name,
                        .value = owned_value,
                        .domain = host,
                    });
                    search_pos = abs_val + 8;
                } else break;
            } else break;
        }
    }

    // Parse auth
    if (findJsonObject(content, "auth")) |auth_str| {
        if (extractJsonStringValueFromObj(auth_str, "type")) |atype| {
            const owned = try allocator.dupe(u8, atype);
            session.trackString(owned);
            session.auth.auth_type = owned;
        }
        if (extractJsonStringValueFromObj(auth_str, "token")) |atoken| {
            const owned = try allocator.dupe(u8, atoken);
            session.trackString(owned);
            session.auth.token = owned;
        }
    }

    return session;
}

fn serializeSession(allocator: Allocator, session: *const Session) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\n");
    try writer.print("  \"name\": \"{s}\",\n", .{session.name});
    try writer.print("  \"host\": \"{s}\",\n", .{session.host});

    // Headers
    try writer.writeAll("  \"headers\": {");
    var h_iter = session.headers.iterator();
    var first = true;
    while (h_iter.next()) |entry| {
        if (!first) try writer.writeAll(",");
        try writer.print("\n    \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
        first = false;
    }
    if (!first) try writer.writeAll("\n  ");
    try writer.writeAll("},\n");

    // Cookies
    try writer.writeAll("  \"cookies\": [");
    for (session.cookies.items, 0..) |cookie, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.print("\n    {{\"name\": \"{s}\", \"value\": \"{s}\", \"domain\": \"{s}\"}}", .{
            cookie.name, cookie.value, cookie.domain,
        });
    }
    if (session.cookies.items.len > 0) try writer.writeAll("\n  ");
    try writer.writeAll("],\n");

    // Auth
    try writer.writeAll("  \"auth\": {");
    if (session.auth.token.len > 0) {
        try writer.print("\n    \"type\": \"{s}\",\n    \"token\": \"{s}\"\n  ", .{
            session.auth.auth_type, session.auth.token,
        });
    }
    try writer.writeAll("}\n");

    try writer.writeAll("}\n");

    return buf.toOwnedSlice();
}

fn findJsonObject(content: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key" in content (with quotes around the key)
    var search_pos: usize = 0;
    while (search_pos < content.len) {
        const quote_pos = mem.indexOf(u8, content[search_pos..], "\"") orelse return null;
        const abs_quote = search_pos + quote_pos;
        if (abs_quote + 1 + key.len + 1 > content.len) return null;
        // Check if this is our key
        if (content[abs_quote + 1 .. abs_quote + 1 + key.len].len == key.len and
            mem.eql(u8, content[abs_quote + 1 .. abs_quote + 1 + key.len], key) and
            content[abs_quote + 1 + key.len] == '"')
        {
            const after_key = content[abs_quote + 1 + key.len + 1 ..];
            const brace = mem.indexOf(u8, after_key, "{") orelse return null;
            const start = abs_quote + 1 + key.len + 1 + brace;
            // Find matching closing brace
            var depth: usize = 1;
            var pos: usize = start + 1;
            while (pos < content.len and depth > 0) : (pos += 1) {
                if (content[pos] == '{') depth += 1;
                if (content[pos] == '}') depth -= 1;
            }
            if (depth == 0) return content[start + 1 .. pos - 1];
            return null;
        }
        search_pos = abs_quote + 1;
    }
    return null;
}

fn extractJsonStringValue(content: []const u8) ?[]const u8 {
    // From '"key": "value"' extract value
    const colon = mem.indexOf(u8, content, ":") orelse return null;
    const after_colon = mem.trim(u8, content[colon + 1 ..], " \t\r\n");
    if (after_colon.len < 2 or after_colon[0] != '"') return null;
    const end_quote = mem.indexOf(u8, after_colon[1..], "\"") orelse return null;
    return after_colon[1 .. end_quote + 1];
}

fn extractJsonStringValueFromObj(obj: []const u8, key: []const u8) ?[]const u8 {
    // Build the search pattern at runtime
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;
    const key_pos = mem.indexOf(u8, obj, search) orelse return null;
    return extractJsonStringValue(obj[key_pos..]);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "session init and deinit" {
    var session = Session.init(std.testing.allocator, "test", "api.example.com");
    defer session.deinit();

    try session.headers.put("Authorization", "Bearer abc123");
    try session.cookies.append(.{ .name = "sid", .value = "xyz" });

    try std.testing.expectEqualStrings("test", session.name);
    try std.testing.expectEqualStrings("api.example.com", session.host);
    try std.testing.expectEqual(@as(usize, 1), session.cookies.items.len);
}

test "serialize and parse session" {
    const allocator = std.testing.allocator;

    var session = Session.init(allocator, "myapi", "api.example.com");
    defer session.deinit();

    try session.headers.put("X-Custom", "value1");
    try session.cookies.append(.{ .name = "session_id", .value = "abc123", .domain = "api.example.com" });
    session.auth = .{ .auth_type = "bearer", .token = "tok123" };

    const json = try serializeSession(allocator, &session);
    defer allocator.free(json);

    // Verify JSON contains expected content
    try std.testing.expect(mem.indexOf(u8, json, "\"myapi\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"api.example.com\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"X-Custom\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"session_id\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"tok123\"") != null);
}

test "session path construction" {
    const path = try sessionPath(std.testing.allocator, "myapi", "api.example.com");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings(".volt-sessions/api.example.com/myapi.json", path);
}

test "update session from set-cookie" {
    var session = Session.init(std.testing.allocator, "test", "example.com");
    defer session.deinit();

    const headers = [_]Header{
        .{ .name = "Set-Cookie", .value = "session_id=abc123; Path=/; HttpOnly" },
        .{ .name = "Set-Cookie", .value = "theme=dark" },
    };

    updateFromResponse(&session, &headers);

    try std.testing.expectEqual(@as(usize, 2), session.cookies.items.len);
    try std.testing.expectEqualStrings("session_id", session.cookies.items[0].name);
    try std.testing.expectEqualStrings("abc123", session.cookies.items[0].value);
    try std.testing.expectEqualStrings("theme", session.cookies.items[1].name);
    try std.testing.expectEqualStrings("dark", session.cookies.items[1].value);
}

test "apply session to headers" {
    var session = Session.init(std.testing.allocator, "test", "example.com");
    defer session.deinit();

    try session.headers.put("X-Api-Key", "secret");
    try session.cookies.append(.{ .name = "sid", .value = "abc" });
    session.auth = .{ .auth_type = "bearer", .token = "tok" };

    var headers = std.ArrayList(Header).init(std.testing.allocator);
    defer {
        // Free allocated cookie string
        for (headers.items) |h| {
            if (mem.eql(u8, h.name, "Cookie") or mem.eql(u8, h.name, "Authorization")) {
                std.testing.allocator.free(h.value);
            }
        }
        headers.deinit();
    }

    try applySession(&session, &headers, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), headers.items.len);
}
