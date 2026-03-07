const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");
const Environment = @import("environment.zig");

// ── Scripting Engine ────────────────────────────────────────────────────
// A simple expression-based scripting language for pre/post request scripts.
// Not full JavaScript, but covers the most common use cases:
//   set <var> <value>           - Set a variable
//   extract <var> <jsonpath>    - Extract value from response body
//   assert <field> <op> <val>   - Assert a condition
//   log <message>               - Print a message
//   if <field> <op> <val>       - Conditional (next line only)
//   header <name> <value>       - Set a request header
//   status                      - Print response status

pub const ScriptContext = struct {
    allocator: Allocator,
    variables: std.StringHashMap([]const u8),
    env_mgr: ?*Environment.EnvManager,
    request: ?*VoltFile.VoltRequest,
    response: ?*const HttpClient.Response,
    output: std.ArrayList(u8),
    assertion_results: std.ArrayList(AssertionResult),

    pub const AssertionResult = struct {
        expression: []const u8,
        passed: bool,
        actual: ?[]const u8 = null,
    };

    pub fn init(allocator: Allocator) ScriptContext {
        return .{
            .allocator = allocator,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .env_mgr = null,
            .request = null,
            .response = null,
            .output = std.ArrayList(u8).init(allocator),
            .assertion_results = std.ArrayList(AssertionResult).init(allocator),
        };
    }

    pub fn deinit(self: *ScriptContext) void {
        self.variables.deinit();
        self.output.deinit();
        self.assertion_results.deinit();
    }

    pub fn setVar(self: *ScriptContext, key: []const u8, value: []const u8) !void {
        if (self.env_mgr) |mgr| {
            try mgr.setRuntimeVar(key, value);
            return;
        }
        try self.variables.put(key, value);
    }

    pub fn getVar(self: *const ScriptContext, key: []const u8) ?[]const u8 {
        if (self.env_mgr) |mgr| {
            return mgr.runtime_vars.get(key);
        }
        return self.variables.get(key);
    }

    pub fn log(self: *ScriptContext, msg: []const u8) !void {
        try self.output.appendSlice(msg);
        try self.output.append('\n');
    }

    /// Resolve a field reference to a value
    pub fn resolveField(self: *const ScriptContext, field: []const u8) ?[]const u8 {
        // Check response fields
        if (self.response) |resp| {
            if (mem.eql(u8, field, "status")) {
                // Return status as string - caller must handle
                return null; // Special handling needed
            }
            if (mem.startsWith(u8, field, "header.")) {
                const header_name = field["header.".len..];
                return resp.getHeader(header_name);
            }
            if (mem.eql(u8, field, "body")) {
                return resp.bodySlice();
            }
            if (mem.startsWith(u8, field, "body.")) {
                // Simple JSON path extraction
                return extractJsonField(resp.bodySlice(), field["body.".len..]);
            }
        }

        // Check variables
        return self.getVar(field);
    }

    pub fn getStatusCode(self: *const ScriptContext) ?u16 {
        if (self.response) |resp| {
            return resp.status_code;
        }
        return null;
    }
};

/// Execute a script (pre or post)
pub fn executeScript(
    ctx: *ScriptContext,
    script: []const u8,
) !void {
    var skip_next = false;

    var lines = mem.splitSequence(u8, script, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (skip_next) {
            skip_next = false;
            continue;
        }

        // Parse command
        var parts = mem.splitSequence(u8, line, " ");
        const cmd = parts.next() orelse continue;

        if (mem.eql(u8, cmd, "set")) {
            // set <var> <value>
            const var_name = parts.next() orelse continue;
            const value = parts.rest();
            if (value.len > 0) {
                try ctx.setVar(var_name, value);
            }
        } else if (mem.eql(u8, cmd, "log")) {
            // log <message>
            const msg = parts.rest();
            try ctx.log(msg);
        } else if (mem.eql(u8, cmd, "assert")) {
            // assert <field> <op> <value>
            const field = parts.next() orelse continue;
            const op = parts.next() orelse continue;
            const expected = parts.rest();

            const passed = evaluateCondition(ctx, field, op, expected);
            try ctx.assertion_results.append(.{
                .expression = line,
                .passed = passed,
            });
        } else if (mem.eql(u8, cmd, "if")) {
            // if <field> <op> <value> (skip next line if false)
            const field = parts.next() orelse continue;
            const op = parts.next() orelse continue;
            const expected = parts.rest();

            if (!evaluateCondition(ctx, field, op, expected)) {
                skip_next = true;
            }
        } else if (mem.eql(u8, cmd, "extract")) {
            // extract <var> <jsonpath>
            const var_name = parts.next() orelse continue;
            var json_path = parts.rest();

            // Common usage is "body.<path>"; scripting extracts from the response body.
            if (mem.startsWith(u8, json_path, "body.")) {
                json_path = json_path["body.".len..];
            }

            if (ctx.response) |resp| {
                const body = resp.bodySlice();
                if (extractJsonField(body, json_path)) |value| {
                    var trimmed_val = mem.trim(u8, value, " \t\r\n");
                    if (trimmed_val.len >= 2 and trimmed_val[0] == '"' and trimmed_val[trimmed_val.len - 1] == '"') {
                        trimmed_val = trimmed_val[1 .. trimmed_val.len - 1];
                    }
                    try ctx.setVar(var_name, trimmed_val);
                }
            }
        } else if (mem.eql(u8, cmd, "header")) {
            // header <name> <value> (modify request)
            const name = parts.next() orelse continue;
            const value = parts.rest();

            if (ctx.request) |req| {
                try req.addHeader(name, value);
            }
        } else if (mem.eql(u8, cmd, "status")) {
            // Print status
            if (ctx.getStatusCode()) |code| {
                var code_buf: [8]u8 = undefined;
                const code_str = std.fmt.bufPrint(&code_buf, "{d}", .{code}) catch "?";
                try ctx.log(code_str);
            }
        }
    }
}

fn evaluateCondition(ctx: *const ScriptContext, field: []const u8, op: []const u8, expected: []const u8) bool {
    // Special handling for status
    if (mem.eql(u8, field, "status")) {
        const status_code = ctx.getStatusCode() orelse return false;
        const expected_code = std.fmt.parseInt(u16, expected, 10) catch return false;

        if (mem.eql(u8, op, "equals") or mem.eql(u8, op, "==")) return status_code == expected_code;
        if (mem.eql(u8, op, "!=")) return status_code != expected_code;
        if (mem.eql(u8, op, "<")) return status_code < expected_code;
        if (mem.eql(u8, op, ">")) return status_code > expected_code;
        if (mem.eql(u8, op, "<=")) return status_code <= expected_code;
        if (mem.eql(u8, op, ">=")) return status_code >= expected_code;
        return false;
    }

    // Resolve field value
    const actual = ctx.resolveField(field) orelse return false;

    if (mem.eql(u8, op, "equals") or mem.eql(u8, op, "==")) {
        return mem.eql(u8, actual, expected);
    }
    if (mem.eql(u8, op, "!=")) {
        return !mem.eql(u8, actual, expected);
    }
    if (mem.eql(u8, op, "contains")) {
        return mem.indexOf(u8, actual, expected) != null;
    }
    if (mem.eql(u8, op, "startsWith")) {
        return mem.startsWith(u8, actual, expected);
    }
    if (mem.eql(u8, op, "endsWith")) {
        return mem.endsWith(u8, actual, expected);
    }
    if (mem.eql(u8, op, "matches")) {
        // Simple glob match
        return mem.indexOf(u8, actual, expected) != null;
    }
    if (mem.eql(u8, op, "exists")) {
        return actual.len > 0;
    }

    return false;
}

/// Simple JSON field extraction (handles basic paths like "data.user.name")
fn extractJsonField(json: []const u8, path: []const u8) ?[]const u8 {
    // Simple string search approach for basic JSON paths
    // Find "key": "value" or "key": value patterns
    var current_key = path;
    var remaining_path: ?[]const u8 = null;

    // Split on first dot
    if (mem.indexOf(u8, path, ".")) |dot_pos| {
        current_key = path[0..dot_pos];
        remaining_path = path[dot_pos + 1 ..];
    }

    // Find the key in JSON
    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{current_key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = json[key_pos + search_key.len ..];

    // Skip ": " or ":"
    var value_start: usize = 0;
    while (value_start < after_key.len and (after_key[value_start] == ':' or after_key[value_start] == ' ')) {
        value_start += 1;
    }
    if (value_start >= after_key.len) return null;

    const value_data = after_key[value_start..];

    if (remaining_path) |rp| {
        // Recurse into nested object
        return extractJsonField(value_data, rp);
    }

    // Extract the value
    if (value_data[0] == '"') {
        // String value
        if (mem.indexOf(u8, value_data[1..], "\"")) |end| {
            return value_data[1 .. end + 1];
        }
    } else if (value_data[0] == '{' or value_data[0] == '[') {
        // Object or array - find matching brace
        return findMatchingBrace(value_data);
    } else {
        // Number, boolean, null
        var end: usize = 0;
        while (end < value_data.len and value_data[end] != ',' and value_data[end] != '}' and value_data[end] != ']' and value_data[end] != '\n') {
            end += 1;
        }
        return mem.trim(u8, value_data[0..end], " \t\r\n");
    }

    return null;
}

fn findMatchingBrace(data: []const u8) ?[]const u8 {
    if (data.len == 0) return null;
    const open = data[0];
    const close: u8 = if (open == '{') '}' else ']';
    var depth: usize = 0;
    var in_string = false;

    for (data, 0..) |c, i| {
        if (c == '"' and (i == 0 or data[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return data[0 .. i + 1];
        }
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "script set and get variable" {
    var ctx = ScriptContext.init(std.testing.allocator);
    defer ctx.deinit();

    try executeScript(&ctx, "set name John\nset age 30");

    try std.testing.expectEqualStrings("John", ctx.getVar("name").?);
    try std.testing.expectEqualStrings("30", ctx.getVar("age").?);
}

test "script log" {
    var ctx = ScriptContext.init(std.testing.allocator);
    defer ctx.deinit();

    try executeScript(&ctx, "log Hello World");

    try std.testing.expect(mem.indexOf(u8, ctx.output.items, "Hello World") != null);
}

test "extract json field" {
    const json = "{\"data\": {\"user\": {\"name\": \"John\", \"age\": 30}}}";

    try std.testing.expectEqualStrings("John", extractJsonField(json, "data.user.name").?);
    try std.testing.expectEqualStrings("30", extractJsonField(json, "data.user.age").?);
}

test "extract json top-level field" {
    const json = "{\"status\": \"ok\", \"count\": 42}";

    try std.testing.expectEqualStrings("ok", extractJsonField(json, "status").?);
    try std.testing.expectEqualStrings("42", extractJsonField(json, "count").?);
}
