const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Minimal YAML-to-JSON converter for OpenAPI specs ────────────────────
// Handles the YAML subset used in OpenAPI/Swagger specs:
//   - Mappings (key: value), sequences (- item), scalars
//   - Quoted strings (single/double), block scalars (|, >)
//   - Comments (#), document markers (---)
// Does NOT handle anchors, aliases, tags, or merge keys.

const Line = struct {
    indent: usize,
    content: []const u8,
};

/// Convert YAML text to JSON text.
pub fn convert(allocator: Allocator, yaml: []const u8) ![]const u8 {
    var lines = std.ArrayList(Line).init(allocator);
    defer lines.deinit();

    var iter = mem.splitScalar(u8, yaml, '\n');
    while (iter.next()) |raw| {
        const clean = mem.trimRight(u8, raw, "\r \t");
        const trimmed = mem.trimLeft(u8, clean, " ");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (mem.eql(u8, trimmed, "---") or mem.eql(u8, trimmed, "...")) continue;
        const indent = clean.len - trimmed.len;
        const content = stripInlineComment(trimmed);
        if (content.len == 0) continue;
        try lines.append(.{ .indent = indent, .content = content });
    }

    if (lines.items.len == 0) return try allocator.dupe(u8, "{}");

    var ctx = Ctx{
        .allocator = allocator,
        .lines = lines.items,
        .pos = 0,
        .buf = std.ArrayList(u8).init(allocator),
    };
    errdefer ctx.buf.deinit();

    try ctx.writeValue(0);
    return ctx.buf.toOwnedSlice();
}

const Ctx = struct {
    allocator: Allocator,
    lines: []const Line,
    pos: usize,
    buf: std.ArrayList(u8),

    fn peek(self: *Ctx) ?Line {
        if (self.pos >= self.lines.len) return null;
        return self.lines[self.pos];
    }

    const WriteError = Allocator.Error;

    fn writeValue(self: *Ctx, min_indent: usize) WriteError!void {
        const line = self.peek() orelse {
            try self.buf.appendSlice("null");
            return;
        };
        if (line.indent < min_indent) {
            try self.buf.appendSlice("null");
            return;
        }
        if (mem.startsWith(u8, line.content, "- ") or mem.eql(u8, line.content, "-")) {
            try self.writeSequence(line.indent);
        } else if (isMapping(line.content)) {
            try self.writeMapping(line.indent);
        } else {
            try writeScalar(&self.buf, line.content);
            self.pos += 1;
        }
    }

    fn writeMapping(self: *Ctx, base_indent: usize) WriteError!void {
        try self.buf.append('{');
        var first = true;

        while (self.peek()) |line| {
            if (line.indent != base_indent) break;
            if (!isMapping(line.content)) break;
            if (mem.startsWith(u8, line.content, "- ")) break;

            if (!first) try self.buf.appendSlice(", ");
            first = false;

            const kv = splitKeyValue(line.content);
            try writeJsonString(&self.buf, unquote(kv.key));
            try self.buf.appendSlice(": ");
            self.pos += 1;

            if (kv.value) |val| {
                if (isBlockIndicator(val)) {
                    try self.writeBlockScalar(base_indent);
                } else {
                    try writeScalar(&self.buf, val);
                }
            } else {
                try self.writeValue(base_indent + 1);
            }
        }

        try self.buf.append('}');
    }

    fn writeSequence(self: *Ctx, base_indent: usize) WriteError!void {
        try self.buf.append('[');
        var first = true;

        while (self.peek()) |line| {
            if (line.indent != base_indent) break;
            if (!mem.startsWith(u8, line.content, "- ") and !mem.eql(u8, line.content, "-")) break;

            if (!first) try self.buf.appendSlice(", ");
            first = false;

            if (mem.eql(u8, line.content, "-")) {
                self.pos += 1;
                try self.writeValue(base_indent + 1);
            } else {
                const rest = line.content[2..];
                const content_indent = base_indent + 2;

                if (isMapping(rest)) {
                    try self.buf.append('{');
                    const kv = splitKeyValue(rest);
                    try writeJsonString(&self.buf, unquote(kv.key));
                    try self.buf.appendSlice(": ");
                    self.pos += 1;

                    if (kv.value) |val| {
                        if (isBlockIndicator(val)) {
                            try self.writeBlockScalar(content_indent);
                        } else {
                            try writeScalar(&self.buf, val);
                        }
                    } else {
                        try self.writeValue(content_indent + 1);
                    }

                    // Continuation entries at content_indent
                    while (self.peek()) |next| {
                        if (next.indent != content_indent) break;
                        if (mem.startsWith(u8, next.content, "- ")) break;
                        if (!isMapping(next.content)) break;

                        try self.buf.appendSlice(", ");
                        const nkv = splitKeyValue(next.content);
                        try writeJsonString(&self.buf, unquote(nkv.key));
                        try self.buf.appendSlice(": ");
                        self.pos += 1;

                        if (nkv.value) |nval| {
                            if (isBlockIndicator(nval)) {
                                try self.writeBlockScalar(content_indent);
                            } else {
                                try writeScalar(&self.buf, nval);
                            }
                        } else {
                            try self.writeValue(content_indent + 1);
                        }
                    }

                    try self.buf.append('}');
                } else {
                    try writeScalar(&self.buf, rest);
                    self.pos += 1;
                }
            }
        }

        try self.buf.append(']');
    }

    fn writeBlockScalar(self: *Ctx, base_indent: usize) WriteError!void {
        var block = std.ArrayList(u8).init(self.allocator);
        defer block.deinit();
        var first_block = true;

        while (self.peek()) |line| {
            if (line.indent <= base_indent) break;
            if (!first_block) try block.append('\n');
            first_block = false;
            try block.appendSlice(line.content);
            self.pos += 1;
        }

        try writeJsonString(&self.buf, block.items);
    }
};

// ── Helpers ─────────────────────────────────────────────────────────────

fn isMapping(content: []const u8) bool {
    if (content.len == 0) return false;
    if (mem.startsWith(u8, content, "- ")) return false;
    if (content[0] == '[' or content[0] == '{') return false;

    var in_sq: bool = false;
    var in_dq: bool = false;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (c == '\'' and !in_dq) {
            in_sq = !in_sq;
            continue;
        }
        if (c == '"' and !in_sq) {
            in_dq = !in_dq;
            continue;
        }
        if (!in_sq and !in_dq and c == ':') {
            if (i + 1 < content.len and content[i + 1] == ' ') return true;
            if (i + 1 == content.len) return true;
        }
    }
    return false;
}

const KeyValue = struct {
    key: []const u8,
    value: ?[]const u8,
};

fn splitKeyValue(content: []const u8) KeyValue {
    var in_sq: bool = false;
    var in_dq: bool = false;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (c == '\'' and !in_dq) {
            in_sq = !in_sq;
            continue;
        }
        if (c == '"' and !in_sq) {
            in_dq = !in_dq;
            continue;
        }
        if (!in_sq and !in_dq and c == ':') {
            if (i + 1 < content.len and content[i + 1] == ' ') {
                const key = content[0..i];
                const val = mem.trim(u8, content[i + 2 ..], " ");
                return .{ .key = key, .value = if (val.len > 0) val else null };
            }
            if (i + 1 == content.len) {
                return .{ .key = content[0..i], .value = null };
            }
        }
    }
    return .{ .key = content, .value = null };
}

fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2) {
        if ((text[0] == '\'' and text[text.len - 1] == '\'') or
            (text[0] == '"' and text[text.len - 1] == '"'))
        {
            return text[1 .. text.len - 1];
        }
    }
    return text;
}

fn isBlockIndicator(val: []const u8) bool {
    return mem.eql(u8, val, "|") or mem.eql(u8, val, ">") or
        mem.eql(u8, val, "|-") or mem.eql(u8, val, ">-");
}

fn writeScalar(buf: *std.ArrayList(u8), text: []const u8) !void {
    // Flow syntax pass-through
    if (text.len > 0 and (text[0] == '{' or text[0] == '[')) {
        try buf.appendSlice(text);
        return;
    }
    // Unquote strings
    if (text.len >= 2) {
        if ((text[0] == '\'' and text[text.len - 1] == '\'') or
            (text[0] == '"' and text[text.len - 1] == '"'))
        {
            try writeJsonString(buf, text[1 .. text.len - 1]);
            return;
        }
    }
    // Special values
    if (mem.eql(u8, text, "null") or mem.eql(u8, text, "~")) {
        try buf.appendSlice("null");
        return;
    }
    if (mem.eql(u8, text, "true") or mem.eql(u8, text, "True") or mem.eql(u8, text, "TRUE")) {
        try buf.appendSlice("true");
        return;
    }
    if (mem.eql(u8, text, "false") or mem.eql(u8, text, "False") or mem.eql(u8, text, "FALSE")) {
        try buf.appendSlice("false");
        return;
    }
    if (isNumber(text)) {
        try buf.appendSlice(text);
        return;
    }
    try writeJsonString(buf, text);
}

fn isNumber(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = 0;
    if (text[0] == '-' or text[0] == '+') i = 1;
    if (i >= text.len) return false;
    var has_dot = false;
    var has_digit = false;
    while (i < text.len) : (i += 1) {
        if (text[i] >= '0' and text[i] <= '9') {
            has_digit = true;
        } else if (text[i] == '.' and !has_dot) {
            has_dot = true;
        } else {
            return false;
        }
    }
    return has_digit;
}

fn writeJsonString(buf: *std.ArrayList(u8), text: []const u8) !void {
    try buf.append('"');
    for (text) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => try buf.append(c),
        }
    }
    try buf.append('"');
}

fn stripInlineComment(line: []const u8) []const u8 {
    var in_sq: bool = false;
    var in_dq: bool = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c == '\'' and !in_dq) {
            in_sq = !in_sq;
            continue;
        }
        if (c == '"' and !in_sq) {
            in_dq = !in_dq;
            continue;
        }
        if (!in_sq and !in_dq and c == '#' and i > 0 and line[i - 1] == ' ') {
            return mem.trimRight(u8, line[0..i], " ");
        }
    }
    return line;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "simple mapping" {
    const yaml =
        \\key1: value1
        \\key2: value2
    ;
    const json = try convert(std.testing.allocator, yaml);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("value1", parsed.value.object.get("key1").?.string);
    try std.testing.expectEqualStrings("value2", parsed.value.object.get("key2").?.string);
}

test "nested mapping" {
    const yaml =
        \\info:
        \\  title: Test API
        \\  version: '1.0.0'
    ;
    const json = try convert(std.testing.allocator, yaml);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const info = parsed.value.object.get("info").?.object;
    try std.testing.expectEqualStrings("Test API", info.get("title").?.string);
    try std.testing.expectEqualStrings("1.0.0", info.get("version").?.string);
}

test "sequence of mappings" {
    const yaml =
        \\servers:
        \\  - url: https://api.example.com
        \\    description: Production
        \\  - url: https://staging.example.com
    ;
    const json = try convert(std.testing.allocator, yaml);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const servers = parsed.value.object.get("servers").?.array;
    try std.testing.expectEqual(@as(usize, 2), servers.items.len);
    try std.testing.expectEqualStrings("https://api.example.com", servers.items[0].object.get("url").?.string);
    try std.testing.expectEqualStrings("Production", servers.items[0].object.get("description").?.string);
}

test "openapi spec" {
    const yaml =
        \\---
        \\openapi: '3.0.3'
        \\info:
        \\  title: Test API
        \\  version: '1.0.0'
        \\servers:
        \\  - url: https://api.example.com
        \\paths:
        \\  /users:
        \\    get:
        \\      summary: List Users
        \\      responses:
        \\        '200':
        \\          description: Success
        \\    post:
        \\      summary: Create User
        \\      requestBody:
        \\        content:
        \\          application/json:
        \\            schema:
        \\              type: object
        \\      responses:
        \\        '201':
        \\          description: Created
    ;
    const json = try convert(std.testing.allocator, yaml);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("3.0.3", root.get("openapi").?.string);
    const paths = root.get("paths").?.object;
    const users = paths.get("/users").?.object;
    try std.testing.expect(users.get("get") != null);
    try std.testing.expect(users.get("post") != null);
    try std.testing.expectEqualStrings("List Users", users.get("get").?.object.get("summary").?.string);
}

test "simple sequence" {
    const yaml =
        \\items:
        \\  - foo
        \\  - bar
        \\  - baz
    ;
    const json = try convert(std.testing.allocator, yaml);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("items").?.array;
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqualStrings("foo", items.items[0].string);
}

test "numbers and booleans" {
    const yaml =
        \\count: 42
        \\pi: 3.14
        \\enabled: true
        \\disabled: false
        \\nothing: null
    ;
    const json = try convert(std.testing.allocator, yaml);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 42), root.get("count").?.integer);
    try std.testing.expect(root.get("enabled").?.bool == true);
    try std.testing.expect(root.get("disabled").?.bool == false);
    try std.testing.expect(root.get("nothing").? == .null);
}

test "comments stripped" {
    const yaml =
        \\# This is a comment
        \\key: value # inline comment
    ;
    const json = try convert(std.testing.allocator, yaml);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("value", parsed.value.object.get("key").?.string);
}

test "url with colon in value" {
    const yaml =
        \\url: https://api.example.com:8080/v1
    ;
    const json = try convert(std.testing.allocator, yaml);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("https://api.example.com:8080/v1", parsed.value.object.get("url").?.string);
}

test "empty input" {
    const json = try convert(std.testing.allocator, "");
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{}", json);
}
