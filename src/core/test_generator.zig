const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");

// ── Smart Test Generator ────────────────────────────────────────────────
// Analyzes request/response pairs and auto-generates test assertions.
// Rule-based engine that infers:
//   - Status code checks
//   - Response time thresholds
//   - JSON schema validation (required fields, types)
//   - Content-Type assertions
//   - Body content checks
//   - Header presence checks

pub const GeneratedTest = struct {
    field: []const u8,
    operator: []const u8,
    value: []const u8,
    confidence: f64, // 0.0 - 1.0
    category: TestCategory,
};

pub const TestCategory = enum {
    status,
    timing,
    content_type,
    body_schema,
    body_content,
    header,

    pub fn toString(self: TestCategory) []const u8 {
        return switch (self) {
            .status => "status",
            .timing => "timing",
            .content_type => "content-type",
            .body_schema => "body-schema",
            .body_content => "body-content",
            .header => "header",
        };
    }
};

pub const GenerationResult = struct {
    tests: std.ArrayList(GeneratedTest),
    json_fields: std.ArrayList(JsonFieldInfo),
    response_type: ResponseType,

    pub fn init(allocator: Allocator) GenerationResult {
        return .{
            .tests = std.ArrayList(GeneratedTest).init(allocator),
            .json_fields = std.ArrayList(JsonFieldInfo).init(allocator),
            .response_type = .unknown,
        };
    }

    pub fn deinit(self: *GenerationResult) void {
        self.tests.deinit();
        self.json_fields.deinit();
    }
};

pub const ResponseType = enum {
    json_object,
    json_array,
    html,
    xml,
    text,
    binary,
    unknown,
};

pub const JsonFieldInfo = struct {
    path: []const u8,
    field_type: JsonType,
    sample_value: []const u8,
    is_array: bool = false,
};

pub const JsonType = enum {
    string,
    number,
    boolean,
    null_type,
    object,
    array,

    pub fn toString(self: JsonType) []const u8 {
        return switch (self) {
            .string => "string",
            .number => "number",
            .boolean => "boolean",
            .null_type => "null",
            .object => "object",
            .array => "array",
        };
    }
};

/// Analyze a request/response pair and generate test assertions
pub fn generateTests(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    response: *const HttpClient.Response,
) !GenerationResult {
    _ = request;
    var result = GenerationResult.init(allocator);

    // 1. Status code assertion (always generated, high confidence)
    try result.tests.append(.{
        .field = "status",
        .operator = "equals",
        .value = statusCodeStr(response.status_code),
        .confidence = 1.0,
        .category = .status,
    });

    // 2. Response time assertion (if reasonable)
    if (response.timing.total_ms > 0 and response.timing.total_ms < 30000) {
        const threshold = computeTimeThreshold(response.timing.total_ms);
        try result.tests.append(.{
            .field = "timing",
            .operator = "<",
            .value = threshold,
            .confidence = 0.7,
            .category = .timing,
        });
    }

    // 3. Content-Type assertion
    if (response.getHeader("content-type")) |ct| {
        if (mem.indexOf(u8, ct, "json") != null) {
            result.response_type = .json_object;
            try result.tests.append(.{
                .field = "header.content-type",
                .operator = "contains",
                .value = "json",
                .confidence = 0.95,
                .category = .content_type,
            });
        } else if (mem.indexOf(u8, ct, "html") != null) {
            result.response_type = .html;
            try result.tests.append(.{
                .field = "header.content-type",
                .operator = "contains",
                .value = "html",
                .confidence = 0.9,
                .category = .content_type,
            });
        } else if (mem.indexOf(u8, ct, "xml") != null) {
            result.response_type = .xml;
        }
    }

    // 4. Body content assertions for JSON responses
    const body = response.bodySlice();
    if (body.len > 0 and result.response_type == .json_object) {
        // Check if it's an array
        const trimmed_body = mem.trim(u8, body, " \t\r\n");
        if (trimmed_body.len > 0 and trimmed_body[0] == '[') {
            result.response_type = .json_array;
        }

        // Extract top-level JSON fields
        try extractJsonFields(body, &result.json_fields);

        // Generate body assertions based on fields
        for (result.json_fields.items) |field| {
            switch (field.field_type) {
                .string => {
                    if (field.sample_value.len > 0 and field.sample_value.len < 100) {
                        try result.tests.append(.{
                            .field = "body",
                            .operator = "contains",
                            .value = field.path,
                            .confidence = 0.8,
                            .category = .body_schema,
                        });
                    }
                },
                .number, .boolean => {
                    try result.tests.append(.{
                        .field = "body",
                        .operator = "contains",
                        .value = field.path,
                        .confidence = 0.8,
                        .category = .body_schema,
                    });
                },
                else => {},
            }
        }

        // Body non-empty assertion
        try result.tests.append(.{
            .field = "body",
            .operator = "contains",
            .value = "{",
            .confidence = 0.85,
            .category = .body_content,
        });
    }

    // 5. Important header presence checks
    if (response.getHeader("cache-control") != null) {
        try result.tests.append(.{
            .field = "header.cache-control",
            .operator = "exists",
            .value = "",
            .confidence = 0.6,
            .category = .header,
        });
    }

    return result;
}

/// Generate a complete .volt file with tests from a response
pub fn generateVoltFile(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    gen_result: *const GenerationResult,
    min_confidence: f64,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Write request section
    if (request.name) |name| {
        try writer.print("name: {s}\n", .{name});
    }
    try writer.print("method: {s}\n", .{request.method.toString()});
    try writer.print("url: {s}\n", .{request.url});

    // Headers
    if (request.headers.items.len > 0) {
        try writer.writeAll("headers:\n");
        for (request.headers.items) |h| {
            try writer.print("  - {s}: {s}\n", .{ h.name, h.value });
        }
    }

    // Body
    if (request.body) |body| {
        try writer.writeAll("body:\n");
        try writer.print("  type: {s}\n", .{request.body_type.toString()});
        if (mem.indexOf(u8, body, "\n") != null) {
            try writer.writeAll("  content: |\n");
            var lines = mem.splitSequence(u8, body, "\n");
            while (lines.next()) |line| {
                try writer.print("    {s}\n", .{line});
            }
        } else {
            try writer.print("  content: {s}\n", .{body});
        }
    }

    // Auth
    if (request.auth.type != .none) {
        try writer.writeAll("auth:\n");
        try writer.print("  type: {s}\n", .{request.auth.type.toString()});
        if (request.auth.token) |t| try writer.print("  token: {s}\n", .{t});
    }

    // Generated tests
    try writer.writeAll("tests:\n");
    for (gen_result.tests.items) |t| {
        if (t.confidence >= min_confidence) {
            if (t.value.len > 0) {
                try writer.print("  - {s} {s} {s}\n", .{ t.field, t.operator, t.value });
            } else {
                try writer.print("  - {s} {s}\n", .{ t.field, t.operator });
            }
        }
    }

    return buf.toOwnedSlice();
}

/// Format generation results for display
pub fn formatResults(result: *const GenerationResult, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("\x1b[1mGenerated Tests\x1b[0m\n\n");

    var by_category: [6]usize = .{ 0, 0, 0, 0, 0, 0 };
    for (result.tests.items) |t| {
        const idx: usize = @intFromEnum(t.category);
        if (idx < 6) by_category[idx] += 1;
    }

    for (result.tests.items) |t| {
        const conf_color: []const u8 = if (t.confidence >= 0.9) "\x1b[32m" else if (t.confidence >= 0.7) "\x1b[33m" else "\x1b[90m";
        try writer.print("  {s}[{d:.0}%]\x1b[0m {s} {s} {s}", .{
            conf_color,
            t.confidence * 100,
            t.field,
            t.operator,
            t.value,
        });
        try writer.print("  \x1b[90m({s})\x1b[0m\n", .{t.category.toString()});
    }

    try writer.print("\n  Total: {d} assertions", .{result.tests.items.len});

    if (result.json_fields.items.len > 0) {
        try writer.print(" | {d} JSON fields detected", .{result.json_fields.items.len});
    }
    try writer.writeAll("\n");

    return buf.toOwnedSlice();
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn statusCodeStr(code: u16) []const u8 {
    return switch (code) {
        200 => "200",
        201 => "201",
        204 => "204",
        301 => "301",
        302 => "302",
        304 => "304",
        400 => "400",
        401 => "401",
        403 => "403",
        404 => "404",
        500 => "500",
        502 => "502",
        503 => "503",
        else => "200",
    };
}

fn computeTimeThreshold(actual_ms: f64) []const u8 {
    if (actual_ms < 100) return "500";
    if (actual_ms < 500) return "2000";
    if (actual_ms < 1000) return "5000";
    if (actual_ms < 5000) return "10000";
    return "30000";
}

/// Extract top-level JSON field names and types from a JSON body
fn extractJsonFields(body: []const u8, fields: *std.ArrayList(JsonFieldInfo)) !void {
    const trimmed = mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return;

    // Handle array - analyze first element
    var json = trimmed;
    if (json[0] == '[') {
        // Find first object in array
        if (mem.indexOf(u8, json, "{")) |start| {
            json = json[start..];
        } else return;
    }

    if (json[0] != '{') return;

    // Simple top-level field extraction
    var pos: usize = 1;
    while (pos < json.len) {
        // Find next key
        const key_start = mem.indexOf(u8, json[pos..], "\"") orelse break;
        const abs_key_start = pos + key_start + 1;
        if (abs_key_start >= json.len) break;

        const key_end = mem.indexOf(u8, json[abs_key_start..], "\"") orelse break;
        const key = json[abs_key_start .. abs_key_start + key_end];

        // Skip to value (past ": ")
        var value_start = abs_key_start + key_end + 1;
        while (value_start < json.len and (json[value_start] == ':' or json[value_start] == ' ' or json[value_start] == '\t')) {
            value_start += 1;
        }
        if (value_start >= json.len) break;

        // Determine value type
        const c = json[value_start];
        var field_type: JsonType = .string;
        var sample: []const u8 = "";
        var next_pos: usize = value_start + 1;

        if (c == '"') {
            field_type = .string;
            if (mem.indexOf(u8, json[value_start + 1 ..], "\"")) |end| {
                sample = json[value_start + 1 .. value_start + 1 + end];
                next_pos = value_start + 1 + end + 1;
            }
        } else if (c == '{') {
            field_type = .object;
            next_pos = skipBrace(json, value_start);
        } else if (c == '[') {
            field_type = .array;
            next_pos = skipBrace(json, value_start);
        } else if (c == 't' or c == 'f') {
            field_type = .boolean;
            sample = if (c == 't') "true" else "false";
            next_pos = value_start + if (c == 't') @as(usize, 4) else @as(usize, 5);
        } else if (c == 'n') {
            field_type = .null_type;
            next_pos = value_start + 4;
        } else if (c >= '0' and c <= '9' or c == '-') {
            field_type = .number;
            var end = value_start;
            while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != '\n') : (end += 1) {}
            sample = mem.trim(u8, json[value_start..end], " \t\r\n");
            next_pos = end;
        }

        try fields.append(.{
            .path = key,
            .field_type = field_type,
            .sample_value = sample,
        });

        pos = next_pos;

        // Only extract top-level fields (limit depth)
        if (fields.items.len >= 20) break;
    }
}

fn skipBrace(json: []const u8, start: usize) usize {
    if (start >= json.len) return start;
    const open = json[start];
    const close: u8 = if (open == '{') '}' else ']';
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < json.len) : (i += 1) {
        if (json[i] == '"' and (i == 0 or json[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (json[i] == open) depth += 1;
        if (json[i] == close) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return json.len;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "generate tests from simple response" {
    var resp = HttpClient.Response.init(std.testing.allocator);
    defer resp.deinit();
    resp.status_code = 200;
    resp.timing.total_ms = 150;
    try resp.headers.append(.{ .name = "content-type", .value = "application/json" });
    try resp.body.appendSlice("{\"id\": 1, \"name\": \"test\"}");

    var req = VoltFile.VoltRequest.init(std.testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/users/1";

    var result = try generateTests(std.testing.allocator, &req, &resp);
    defer result.deinit();

    // Should have status, timing, content-type, and body assertions
    try std.testing.expect(result.tests.items.len >= 3);
    try std.testing.expectEqualStrings("status", result.tests.items[0].field);
    try std.testing.expectEqualStrings("200", result.tests.items[0].value);
}

test "extract json fields" {
    var fields = std.ArrayList(JsonFieldInfo).init(std.testing.allocator);
    defer fields.deinit();

    try extractJsonFields("{\"id\": 1, \"name\": \"John\", \"active\": true}", &fields);

    try std.testing.expect(fields.items.len >= 3);
    try std.testing.expectEqualStrings("id", fields.items[0].path);
    try std.testing.expect(fields.items[0].field_type == .number);
    try std.testing.expectEqualStrings("name", fields.items[1].path);
    try std.testing.expect(fields.items[1].field_type == .string);
}

test "generate volt file with tests" {
    var resp = HttpClient.Response.init(std.testing.allocator);
    defer resp.deinit();
    resp.status_code = 200;
    resp.timing.total_ms = 100;
    try resp.headers.append(.{ .name = "content-type", .value = "application/json" });
    try resp.body.appendSlice("{\"status\": \"ok\"}");

    var req = VoltFile.VoltRequest.init(std.testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/health";

    var gen = try generateTests(std.testing.allocator, &req, &resp);
    defer gen.deinit();

    const output = try generateVoltFile(std.testing.allocator, &req, &gen, 0.5);
    defer std.testing.allocator.free(output);

    try std.testing.expect(mem.indexOf(u8, output, "tests:") != null);
    try std.testing.expect(mem.indexOf(u8, output, "status equals 200") != null);
}
