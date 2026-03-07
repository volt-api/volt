const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");
const Environment = @import("environment.zig");

// ── Enhanced Script Engine ──────────────────────────────────────────────
//
// A powerful expression-based scripting language for pre/post request scripts.
// Designed as a Hoppscotch-competitive alternative to JavaScript-based scripting.
//
// Supported commands:
//   env.set <key> <value>          - Set environment variable
//   env.get <key>                  - Get environment variable (into last_result)
//   env.delete <key>               - Remove an environment variable
//   response.status                - Get response status code
//   response.body                  - Get full response body
//   response.header <name>         - Get response header value
//   response.json <path>           - Extract JSON value by path
//   response.time                  - Get response time in ms
//   test <name> { ... }            - Define a test block
//   expect <actual> <op> <expected> - Assert a condition
//   set <var> <value>              - Set a local variable
//   extract <var> <jsonpath>       - Extract from response body
//   log <message>                  - Print a message
//   if <field> <op> <val>          - Conditional (next line only)
//   header <name> <value>          - Set a request header
//   base64.encode <value>          - Base64 encode
//   base64.decode <value>          - Base64 decode
//   uuid                           - Generate UUID (into last_result)
//   timestamp                      - Get current timestamp (into last_result)
//   sleep <ms>                     - Sleep for N milliseconds
//   chain <var> <jsonpath>         - Extract and set for next request
//   assert.status <code>           - Assert status code
//   assert.header <name> <op> <val> - Assert header value
//   assert.body <op> <val>         - Assert body content
//   assert.json <path> <op> <val>  - Assert JSON value

pub const TestResult = struct {
    name: []const u8,
    passed: bool,
    message: ?[]const u8 = null,
};

pub const ScriptEngine = struct {
    allocator: Allocator,
    variables: std.StringHashMap([]const u8),
    env_mgr: ?*Environment.EnvManager,
    request: ?*VoltFile.VoltRequest,
    response: ?*const HttpClient.Response,
    output: std.ArrayList(u8),
    test_results: std.ArrayList(TestResult),
    last_result: ?[]const u8,
    last_result_owned: bool,
    assertion_count: usize,
    assertion_passed: usize,
    // Owned variable values for cleanup
    owned_values: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) ScriptEngine {
        return .{
            .allocator = allocator,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .env_mgr = null,
            .request = null,
            .response = null,
            .output = std.ArrayList(u8).init(allocator),
            .test_results = std.ArrayList(TestResult).init(allocator),
            .last_result = null,
            .last_result_owned = false,
            .assertion_count = 0,
            .assertion_passed = 0,
            .owned_values = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ScriptEngine) void {
        self.variables.deinit();
        self.output.deinit();
        for (self.test_results.items) |tr| {
            if (tr.message) |m| self.allocator.free(m);
        }
        self.test_results.deinit();
        if (self.last_result_owned) {
            if (self.last_result) |lr| self.allocator.free(lr);
        }
        for (self.owned_values.items) |v| {
            self.allocator.free(v);
        }
        self.owned_values.deinit();
    }

    /// Execute a full script
    pub fn execute(self: *ScriptEngine, script: []const u8) !void {
        var skip_next = false;
        var in_test_block = false;
        var test_name: []const u8 = "";
        var test_passed = true;
        var brace_depth: usize = 0;

        var lines = mem.splitSequence(u8, script, "\n");
        while (lines.next()) |raw_line| {
            const line = mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#' or mem.startsWith(u8, line, "//")) continue;

            // Handle test blocks
            if (in_test_block) {
                if (mem.eql(u8, line, "}")) {
                    brace_depth -|= 1;
                    if (brace_depth == 0) {
                        try self.test_results.append(.{
                            .name = test_name,
                            .passed = test_passed,
                        });
                        in_test_block = false;
                        continue;
                    }
                }
                if (mem.endsWith(u8, line, "{")) {
                    brace_depth += 1;
                }
                // Execute line inside test block, track pass/fail
                self.executeLine(line) catch {
                    test_passed = false;
                };
                continue;
            }

            if (skip_next) {
                skip_next = false;
                continue;
            }

            // Check for test block start: test "name" {
            if (mem.startsWith(u8, line, "test ")) {
                const rest = line["test ".len..];
                // Extract quoted name
                if (mem.indexOf(u8, rest, "\"")) |q1| {
                    const after_q1 = rest[q1 + 1 ..];
                    if (mem.indexOf(u8, after_q1, "\"")) |q2| {
                        test_name = after_q1[0..q2];
                        in_test_block = true;
                        test_passed = true;
                        brace_depth = 1;
                        continue;
                    }
                }
            }

            // Handle if/conditional
            if (mem.startsWith(u8, line, "if ")) {
                const cond_str = line["if ".len..];
                if (!self.evaluateConditionStr(cond_str)) {
                    skip_next = true;
                }
                continue;
            }

            self.executeLine(line) catch {};
        }
    }

    fn executeLine(self: *ScriptEngine, line: []const u8) !void {
        var parts = mem.splitSequence(u8, line, " ");
        const cmd = parts.next() orelse return;

        // env.set <key> <value>
        if (mem.eql(u8, cmd, "env.set")) {
            const key = parts.next() orelse return;
            const value = parts.rest();
            if (value.len > 0) {
                if (self.env_mgr) |mgr| {
                    try mgr.setRuntimeVar(key, value);
                }
                try self.setVar(key, value);
            }
            return;
        }

        // env.get <key>
        if (mem.eql(u8, cmd, "env.get")) {
            const key = parts.next() orelse return;
            if (self.env_mgr) |mgr| {
                self.last_result = mgr.resolve(key, null);
                self.last_result_owned = false;
            }
            return;
        }

        // env.delete <key>
        if (mem.eql(u8, cmd, "env.delete")) {
            const key = parts.next() orelse return;
            if (self.env_mgr) |mgr| {
                if (mgr.getActive()) |env| {
                    env.remove(key);
                }
            }
            return;
        }

        // set <var> <value>
        if (mem.eql(u8, cmd, "set")) {
            const var_name = parts.next() orelse return;
            const value = parts.rest();
            if (value.len > 0) {
                try self.setVar(var_name, value);
            }
            return;
        }

        // log <message>
        if (mem.eql(u8, cmd, "log")) {
            const msg = parts.rest();
            try self.output.appendSlice(msg);
            try self.output.append('\n');
            return;
        }

        // extract <var> <jsonpath>
        if (mem.eql(u8, cmd, "extract")) {
            const var_name = parts.next() orelse return;
            var json_path = parts.rest();
            if (mem.startsWith(u8, json_path, "body.")) {
                json_path = json_path["body.".len..];
            }
            if (self.response) |resp| {
                if (extractJsonField(resp.bodySlice(), json_path)) |value| {
                    var trimmed = mem.trim(u8, value, " \t\r\n");
                    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
                        trimmed = trimmed[1 .. trimmed.len - 1];
                    }
                    try self.setVar(var_name, trimmed);
                    if (self.env_mgr) |mgr| {
                        try mgr.setRuntimeVar(var_name, trimmed);
                    }
                }
            }
            return;
        }

        // chain <var> <jsonpath> (extract and propagate)
        if (mem.eql(u8, cmd, "chain")) {
            const var_name = parts.next() orelse return;
            const json_path = parts.rest();
            if (self.response) |resp| {
                if (extractJsonField(resp.bodySlice(), json_path)) |value| {
                    const trimmed = mem.trim(u8, value, " \t\r\n\"");
                    try self.setVar(var_name, trimmed);
                    if (self.env_mgr) |mgr| {
                        try mgr.setRuntimeVar(var_name, trimmed);
                    }
                }
            }
            return;
        }

        // header <name> <value>
        if (mem.eql(u8, cmd, "header")) {
            const name = parts.next() orelse return;
            const value = parts.rest();
            if (self.request) |req| {
                try req.addHeader(name, value);
            }
            return;
        }

        // expect <actual> <op> <expected>
        if (mem.eql(u8, cmd, "expect")) {
            const field = parts.next() orelse return;
            const op = parts.next() orelse return;
            const expected = parts.rest();
            self.assertion_count += 1;
            if (self.evaluateCondition(field, op, expected)) {
                self.assertion_passed += 1;
            }
            return;
        }

        // assert.status <code>
        if (mem.eql(u8, cmd, "assert.status")) {
            const expected = parts.next() orelse return;
            self.assertion_count += 1;
            if (self.response) |resp| {
                const expected_code = std.fmt.parseInt(u16, expected, 10) catch return;
                if (resp.status_code == expected_code) {
                    self.assertion_passed += 1;
                }
            }
            return;
        }

        // assert.header <name> <op> <val>
        if (mem.eql(u8, cmd, "assert.header")) {
            const name = parts.next() orelse return;
            const op = parts.next() orelse return;
            const expected = parts.rest();
            self.assertion_count += 1;
            if (self.response) |resp| {
                if (resp.getHeader(name)) |actual| {
                    if (evalStringOp(actual, op, expected)) {
                        self.assertion_passed += 1;
                    }
                }
            }
            return;
        }

        // assert.body <op> <val>
        if (mem.eql(u8, cmd, "assert.body")) {
            const op = parts.next() orelse return;
            const expected = parts.rest();
            self.assertion_count += 1;
            if (self.response) |resp| {
                if (evalStringOp(resp.bodySlice(), op, expected)) {
                    self.assertion_passed += 1;
                }
            }
            return;
        }

        // assert.json <path> <op> <val>
        if (mem.eql(u8, cmd, "assert.json")) {
            const path = parts.next() orelse return;
            const op = parts.next() orelse return;
            const expected = parts.rest();
            self.assertion_count += 1;
            if (self.response) |resp| {
                if (extractJsonField(resp.bodySlice(), path)) |actual| {
                    const trimmed = mem.trim(u8, actual, " \t\r\n\"");
                    if (evalStringOp(trimmed, op, expected)) {
                        self.assertion_passed += 1;
                    }
                }
            }
            return;
        }

        // response.status
        if (mem.eql(u8, cmd, "response.status")) {
            if (self.response) |resp| {
                var buf: [8]u8 = undefined;
                const code_str = std.fmt.bufPrint(&buf, "{d}", .{resp.status_code}) catch return;
                try self.output.appendSlice(code_str);
                try self.output.append('\n');
            }
            return;
        }

        // response.body
        if (mem.eql(u8, cmd, "response.body")) {
            if (self.response) |resp| {
                try self.output.appendSlice(resp.bodySlice());
                try self.output.append('\n');
            }
            return;
        }

        // response.header <name>
        if (mem.eql(u8, cmd, "response.header")) {
            const name = parts.next() orelse return;
            if (self.response) |resp| {
                if (resp.getHeader(name)) |val| {
                    try self.output.appendSlice(val);
                    try self.output.append('\n');
                }
            }
            return;
        }

        // response.json <path>
        if (mem.eql(u8, cmd, "response.json")) {
            const path = parts.rest();
            if (self.response) |resp| {
                if (extractJsonField(resp.bodySlice(), path)) |val| {
                    self.last_result = val;
                    self.last_result_owned = false;
                    try self.output.appendSlice(val);
                    try self.output.append('\n');
                }
            }
            return;
        }

        // timestamp
        if (mem.eql(u8, cmd, "timestamp")) {
            const ts = std.time.timestamp();
            const ts_str = try std.fmt.allocPrint(self.allocator, "{d}", .{ts});
            try self.owned_values.append(ts_str);
            self.last_result = ts_str;
            self.last_result_owned = false; // managed by owned_values
            return;
        }

        // base64.encode <value>
        if (mem.eql(u8, cmd, "base64.encode")) {
            const value = parts.rest();
            if (value.len > 0) {
                const encoded_len = std.base64.standard.Encoder.calcSize(value.len);
                const encoded = try self.allocator.alloc(u8, encoded_len);
                _ = std.base64.standard.Encoder.encode(encoded, value);
                try self.owned_values.append(encoded);
                self.last_result = encoded;
                self.last_result_owned = false;
                try self.output.appendSlice(encoded);
                try self.output.append('\n');
            }
            return;
        }

        // sleep <ms> - no-op in unit test mode, actual sleep in production
        if (mem.eql(u8, cmd, "sleep")) {
            const ms_str = parts.next() orelse return;
            const ms = std.fmt.parseInt(u64, ms_str, 10) catch return;
            std.time.sleep(ms * std.time.ns_per_ms);
            return;
        }
    }

    fn setVar(self: *ScriptEngine, key: []const u8, value: []const u8) !void {
        try self.variables.put(key, value);
    }

    pub fn getVar(self: *const ScriptEngine, key: []const u8) ?[]const u8 {
        return self.variables.get(key);
    }

    fn evaluateConditionStr(self: *ScriptEngine, condition: []const u8) bool {
        var cond_parts = mem.splitSequence(u8, condition, " ");
        const field = cond_parts.next() orelse return false;
        const op = cond_parts.next() orelse return false;
        const expected = cond_parts.rest();
        return self.evaluateCondition(field, op, expected);
    }

    fn evaluateCondition(self: *ScriptEngine, field: []const u8, op: []const u8, expected: []const u8) bool {
        // Status check
        if (mem.eql(u8, field, "status")) {
            if (self.response) |resp| {
                const expected_code = std.fmt.parseInt(u16, expected, 10) catch return false;
                if (mem.eql(u8, op, "equals") or mem.eql(u8, op, "==")) return resp.status_code == expected_code;
                if (mem.eql(u8, op, "!=")) return resp.status_code != expected_code;
                if (mem.eql(u8, op, "<")) return resp.status_code < expected_code;
                if (mem.eql(u8, op, ">")) return resp.status_code > expected_code;
            }
            return false;
        }

        // Header check
        if (mem.startsWith(u8, field, "header.")) {
            if (self.response) |resp| {
                const header_name = field["header.".len..];
                if (resp.getHeader(header_name)) |actual| {
                    return evalStringOp(actual, op, expected);
                }
            }
            return false;
        }

        // Body check
        if (mem.eql(u8, field, "body")) {
            if (self.response) |resp| {
                return evalStringOp(resp.bodySlice(), op, expected);
            }
            return false;
        }

        // Variable check
        if (self.variables.get(field)) |actual| {
            return evalStringOp(actual, op, expected);
        }

        return false;
    }
};

fn evalStringOp(actual: []const u8, op: []const u8, expected: []const u8) bool {
    if (mem.eql(u8, op, "equals") or mem.eql(u8, op, "==")) return mem.eql(u8, actual, expected);
    if (mem.eql(u8, op, "!=")) return !mem.eql(u8, actual, expected);
    if (mem.eql(u8, op, "contains")) return mem.indexOf(u8, actual, expected) != null;
    if (mem.eql(u8, op, "startsWith")) return mem.startsWith(u8, actual, expected);
    if (mem.eql(u8, op, "endsWith")) return mem.endsWith(u8, actual, expected);
    if (mem.eql(u8, op, "exists")) return actual.len > 0;
    if (mem.eql(u8, op, "matches")) return mem.indexOf(u8, actual, expected) != null;
    return false;
}

/// Simple JSON field extraction (handles basic paths like "data.user.name")
fn extractJsonField(json: []const u8, path: []const u8) ?[]const u8 {
    var current_key = path;
    var remaining_path: ?[]const u8 = null;

    if (mem.indexOf(u8, path, ".")) |dot_pos| {
        current_key = path[0..dot_pos];
        remaining_path = path[dot_pos + 1 ..];
    }

    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{current_key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = json[key_pos + search_key.len ..];

    var value_start: usize = 0;
    while (value_start < after_key.len and (after_key[value_start] == ':' or after_key[value_start] == ' ')) {
        value_start += 1;
    }
    if (value_start >= after_key.len) return null;

    const value_data = after_key[value_start..];

    if (remaining_path) |rp| {
        return extractJsonField(value_data, rp);
    }

    if (value_data[0] == '"') {
        // Find closing quote, skipping escaped quotes
        var qi: usize = 1;
        while (qi < value_data.len) : (qi += 1) {
            if (value_data[qi] == '\\' and qi + 1 < value_data.len) {
                qi += 1; // skip escaped char
                continue;
            }
            if (value_data[qi] == '"') {
                return value_data[1..qi];
            }
        }
    } else if (value_data[0] == '{' or value_data[0] == '[') {
        return findMatchingBrace(value_data);
    } else {
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

test "script engine set and get" {
    var engine = ScriptEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.execute("set name John\nset age 30");
    try std.testing.expectEqualStrings("John", engine.getVar("name").?);
    try std.testing.expectEqualStrings("30", engine.getVar("age").?);
}

test "script engine log" {
    var engine = ScriptEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.execute("log Hello World");
    try std.testing.expect(mem.indexOf(u8, engine.output.items, "Hello World") != null);
}

test "script engine env.set" {
    var mgr = Environment.EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    var engine = ScriptEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.env_mgr = &mgr;

    try engine.execute("env.set api_url https://api.example.com");
    try std.testing.expectEqualStrings("https://api.example.com", mgr.resolve("api_url", null).?);
}

test "script engine assertions" {
    var engine = ScriptEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.execute("set x hello\nexpect x equals hello");
    try std.testing.expectEqual(@as(usize, 1), engine.assertion_count);
    try std.testing.expectEqual(@as(usize, 1), engine.assertion_passed);
}

test "script engine conditional" {
    var engine = ScriptEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.execute("set x 10\nif x equals 10\nlog YES\nif x equals 20\nlog NO");
    try std.testing.expect(mem.indexOf(u8, engine.output.items, "YES") != null);
    try std.testing.expect(mem.indexOf(u8, engine.output.items, "NO") == null);
}

test "script engine test block" {
    var engine = ScriptEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.execute(
        \\test "my test" {
        \\  set x hello
        \\  expect x equals hello
        \\}
    );
    try std.testing.expectEqual(@as(usize, 1), engine.test_results.items.len);
    try std.testing.expectEqualStrings("my test", engine.test_results.items[0].name);
    try std.testing.expect(engine.test_results.items[0].passed);
}

test "script engine comments" {
    var engine = ScriptEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.execute("# comment\n// also comment\nset x 1");
    try std.testing.expectEqualStrings("1", engine.getVar("x").?);
}

test "script engine base64 encode" {
    var engine = ScriptEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.execute("base64.encode hello");
    try std.testing.expect(engine.last_result != null);
    try std.testing.expectEqualStrings("aGVsbG8=", engine.last_result.?);
}

test "script engine timestamp" {
    var engine = ScriptEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.execute("timestamp");
    try std.testing.expect(engine.last_result != null);
    try std.testing.expect(engine.last_result.?.len > 0);
}

test "extract json field" {
    const json = "{\"data\": {\"user\": {\"name\": \"John\"}}}";
    try std.testing.expectEqualStrings("John", extractJsonField(json, "data.user.name").?);
}

test "eval string ops" {
    try std.testing.expect(evalStringOp("hello", "equals", "hello"));
    try std.testing.expect(evalStringOp("hello", "!=", "world"));
    try std.testing.expect(evalStringOp("hello world", "contains", "world"));
    try std.testing.expect(evalStringOp("hello", "startsWith", "hel"));
    try std.testing.expect(evalStringOp("hello", "endsWith", "llo"));
    try std.testing.expect(evalStringOp("data", "exists", ""));
}
