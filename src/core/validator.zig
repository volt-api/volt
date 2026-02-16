const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── JSON Schema Validator ──────────────────────────────────────────────
// Validates response bodies against simple JSON schemas.
// Schema format (simplified JSON Schema subset):
// {
//   "type": "object",
//   "required": ["id", "name"],
//   "properties": {
//     "id": { "type": "number" },
//     "name": { "type": "string" },
//     "tags": { "type": "array" }
//   }
// }

pub const SchemaType = enum {
    object,
    array,
    string,
    number,
    boolean,
    null_type,
    any,

    pub fn fromString(s: []const u8) SchemaType {
        if (mem.eql(u8, s, "object")) return .object;
        if (mem.eql(u8, s, "array")) return .array;
        if (mem.eql(u8, s, "string")) return .string;
        if (mem.eql(u8, s, "number") or mem.eql(u8, s, "integer")) return .number;
        if (mem.eql(u8, s, "boolean") or mem.eql(u8, s, "bool")) return .boolean;
        if (mem.eql(u8, s, "null")) return .null_type;
        return .any;
    }

    pub fn toString(self: SchemaType) []const u8 {
        return switch (self) {
            .object => "object",
            .array => "array",
            .string => "string",
            .number => "number",
            .boolean => "boolean",
            .null_type => "null",
            .any => "any",
        };
    }
};

pub const ValidationError = struct {
    path: []const u8,
    message: []const u8,
    expected: []const u8,
    actual: []const u8,
};

pub const ValidationResult = struct {
    valid: bool,
    errors: std.ArrayList(ValidationError),
    warnings: std.ArrayList(ValidationError),
    fields_checked: usize,

    pub fn init(allocator: Allocator) ValidationResult {
        return .{
            .valid = true,
            .errors = std.ArrayList(ValidationError).init(allocator),
            .warnings = std.ArrayList(ValidationError).init(allocator),
            .fields_checked = 0,
        };
    }

    pub fn deinit(self: *ValidationResult) void {
        self.errors.deinit();
        self.warnings.deinit();
    }
};

pub const SchemaField = struct {
    name: []const u8,
    field_type: SchemaType,
    required: bool = false,
    nullable: bool = false,
};

pub const Schema = struct {
    root_type: SchemaType,
    fields: std.ArrayList(SchemaField),
    required_fields: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Schema {
        return .{
            .root_type = .object,
            .fields = std.ArrayList(SchemaField).init(allocator),
            .required_fields = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Schema) void {
        self.fields.deinit();
        self.required_fields.deinit();
    }
};

// ── Validation ─────────────────────────────────────────────────────────

/// Detect the JSON type of a value by examining its first non-whitespace character.
fn detectJsonType(value: []const u8) SchemaType {
    const trimmed = mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return .any;

    return switch (trimmed[0]) {
        '"' => .string,
        '[' => .array,
        '{' => .object,
        't', 'f' => .boolean,
        'n' => .null_type,
        '0'...'9', '-' => .number,
        else => .any,
    };
}

/// Find the value associated with a key in a JSON object string.
/// Returns the raw value substring (e.g., `"hello"`, `42`, `[1,2]`).
fn findJsonValue(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = json[key_pos + search_key.len ..];

    // Skip colon and whitespace
    var start: usize = 0;
    while (start < after_key.len and (after_key[start] == ':' or after_key[start] == ' ' or after_key[start] == '\t' or after_key[start] == '\n' or after_key[start] == '\r')) {
        start += 1;
    }
    if (start >= after_key.len) return null;

    const value_data = after_key[start..];

    // Determine the extent of the value
    if (value_data[0] == '"') {
        // String: find closing quote (unescaped)
        var i: usize = 1;
        while (i < value_data.len) {
            if (value_data[i] == '\\') {
                i += 2;
                continue;
            }
            if (value_data[i] == '"') {
                return value_data[0 .. i + 1];
            }
            i += 1;
        }
        return value_data;
    } else if (value_data[0] == '{' or value_data[0] == '[') {
        // Object or array: find matching brace
        const open = value_data[0];
        const close: u8 = if (open == '{') '}' else ']';
        var depth: usize = 0;
        var in_string = false;
        for (value_data, 0..) |c, idx| {
            if (c == '"' and (idx == 0 or value_data[idx - 1] != '\\')) {
                in_string = !in_string;
                continue;
            }
            if (in_string) continue;
            if (c == open) depth += 1;
            if (c == close) {
                depth -= 1;
                if (depth == 0) return value_data[0 .. idx + 1];
            }
        }
        return value_data;
    } else {
        // Primitive: read until comma, brace, or newline
        var end: usize = 0;
        while (end < value_data.len and value_data[end] != ',' and value_data[end] != '}' and value_data[end] != ']' and value_data[end] != '\n') {
            end += 1;
        }
        return mem.trim(u8, value_data[0..end], " \t\r\n");
    }
}

/// Validate a JSON response body against a schema
pub fn validate(allocator: Allocator, json_body: []const u8, schema: *const Schema) !ValidationResult {
    var result = ValidationResult.init(allocator);

    const trimmed = mem.trim(u8, json_body, " \t\r\n");
    if (trimmed.len == 0) {
        try result.errors.append(.{
            .path = "(root)",
            .message = "Empty response body",
            .expected = schema.root_type.toString(),
            .actual = "empty",
        });
        result.valid = false;
        return result;
    }

    // Check root type
    const actual_root = detectJsonType(trimmed);
    if (schema.root_type != .any and actual_root != schema.root_type) {
        try result.errors.append(.{
            .path = "(root)",
            .message = "Root type mismatch",
            .expected = schema.root_type.toString(),
            .actual = actual_root.toString(),
        });
        result.valid = false;
        return result;
    }

    // For object types, check required fields and field types
    if (schema.root_type == .object) {
        // Check required fields
        for (schema.required_fields.items) |req_field| {
            result.fields_checked += 1;
            if (findJsonValue(trimmed, req_field) == null) {
                try result.errors.append(.{
                    .path = req_field,
                    .message = "Required field missing",
                    .expected = "present",
                    .actual = "missing",
                });
                result.valid = false;
            }
        }

        // Check field types for defined properties
        for (schema.fields.items) |field| {
            result.fields_checked += 1;
            if (findJsonValue(trimmed, field.name)) |value| {
                const actual_type = detectJsonType(value);

                // Allow null if field is nullable
                if (actual_type == .null_type and field.nullable) {
                    continue;
                }

                if (field.field_type != .any and actual_type != field.field_type) {
                    try result.errors.append(.{
                        .path = field.name,
                        .message = "Type mismatch",
                        .expected = field.field_type.toString(),
                        .actual = actual_type.toString(),
                    });
                    result.valid = false;
                }
            } else {
                // Field not present - warn if not required (required already checked above)
                var is_required = false;
                for (schema.required_fields.items) |rf| {
                    if (mem.eql(u8, rf, field.name)) {
                        is_required = true;
                        break;
                    }
                }
                if (!is_required) {
                    try result.warnings.append(.{
                        .path = field.name,
                        .message = "Optional field not present",
                        .expected = field.field_type.toString(),
                        .actual = "absent",
                    });
                }
            }
        }
    }

    return result;
}

// ── Schema Inference ───────────────────────────────────────────────────

/// Auto-generate a schema from a JSON response body.
/// Infers types of top-level fields.
pub fn inferSchema(allocator: Allocator, json_body: []const u8) !Schema {
    var schema = Schema.init(allocator);

    const trimmed = mem.trim(u8, json_body, " \t\r\n");
    if (trimmed.len == 0) return schema;

    schema.root_type = detectJsonType(trimmed);

    if (schema.root_type != .object) return schema;

    // Extract top-level keys by scanning for "key": patterns at depth 1.
    // We track depth carefully, skipping over nested strings/objects/arrays.
    var depth: usize = 0;
    var i: usize = 0;

    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];

        // Skip strings entirely
        if (c == '"') {
            i += 1;
            while (i < trimmed.len) : (i += 1) {
                if (trimmed[i] == '\\') {
                    i += 1; // skip escaped char
                    continue;
                }
                if (trimmed[i] == '"') break;
            }
            continue;
        }

        if (c == '{' or c == '[') {
            depth += 1;
            continue;
        }
        if (c == '}' or c == ']') {
            depth -|= 1;
            continue;
        }
    }

    // Simpler approach: use findJsonValue for each candidate key.
    // Scan for top-level "key" patterns at depth 1 by looking for
    // `"key":` patterns where the key is at the object's top level.
    i = 0;
    depth = 0;
    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];

        if (c == '"') {
            const str_start = i;
            const key_start = i + 1;
            // Find end of string
            i += 1;
            while (i < trimmed.len) : (i += 1) {
                if (trimmed[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (trimmed[i] == '"') break;
            }
            if (i >= trimmed.len) break;
            const key_end = i;
            _ = str_start;

            // Check if this string at depth==1 is followed by ':'
            if (depth == 1) {
                var j = key_end + 1;
                while (j < trimmed.len and (trimmed[j] == ' ' or trimmed[j] == '\t')) : (j += 1) {}
                if (j < trimmed.len and trimmed[j] == ':') {
                    const key = trimmed[key_start..key_end];
                    if (findJsonValue(trimmed, key)) |value| {
                        const field_type = detectJsonType(value);
                        try schema.fields.append(.{
                            .name = key,
                            .field_type = field_type,
                            .required = true,
                        });
                        try schema.required_fields.append(key);
                    }
                }
            }
            continue;
        }

        if (c == '{' or c == '[') {
            depth += 1;
        } else if (c == '}' or c == ']') {
            depth -|= 1;
        }
    }

    return schema;
}

// ── Schema Parsing ─────────────────────────────────────────────────────

/// Parse a schema definition from a simple YAML-like format:
/// ```
/// type: object
/// required: id, name, email
/// properties:
///   id: number
///   name: string
///   email: string
///   tags: array
///   active: boolean
/// ```
pub fn parseSchema(allocator: Allocator, content: []const u8) !Schema {
    var schema = Schema.init(allocator);
    errdefer schema.deinit();

    var in_properties = false;

    var lines = mem.splitSequence(u8, content, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trimRight(u8, raw_line, "\r");
        const trimmed = mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (mem.startsWith(u8, trimmed, "type:")) {
            const val = mem.trim(u8, trimmed["type:".len..], " \t");
            schema.root_type = SchemaType.fromString(val);
            in_properties = false;
        } else if (mem.startsWith(u8, trimmed, "required:")) {
            const val = mem.trim(u8, trimmed["required:".len..], " \t");
            // Parse comma-separated field names
            var fields = mem.splitSequence(u8, val, ",");
            while (fields.next()) |field| {
                const name = mem.trim(u8, field, " \t");
                if (name.len > 0) {
                    try schema.required_fields.append(name);
                }
            }
            in_properties = false;
        } else if (mem.eql(u8, trimmed, "properties:")) {
            in_properties = true;
        } else if (in_properties) {
            // Parse "name: type" or "name: type (nullable)"
            if (mem.indexOf(u8, trimmed, ": ")) |colon_pos| {
                const name = trimmed[0..colon_pos];
                const type_str = trimmed[colon_pos + 2 ..];

                var nullable = false;
                var actual_type = type_str;
                if (mem.indexOf(u8, type_str, " ")) |space_pos| {
                    const modifier = type_str[space_pos + 1 ..];
                    actual_type = type_str[0..space_pos];
                    if (mem.eql(u8, modifier, "nullable") or mem.eql(u8, modifier, "null")) {
                        nullable = true;
                    }
                }

                // Check if this field is in the required list
                var is_required = false;
                for (schema.required_fields.items) |rf| {
                    if (mem.eql(u8, rf, name)) {
                        is_required = true;
                        break;
                    }
                }

                try schema.fields.append(.{
                    .name = name,
                    .field_type = SchemaType.fromString(actual_type),
                    .required = is_required,
                    .nullable = nullable,
                });
            }
        }
    }

    return schema;
}

// ── Formatting ─────────────────────────────────────────────────────────

/// Format validation result for display
pub fn formatResult(result: *const ValidationResult, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    if (result.valid) {
        try writer.writeAll("\x1b[32mValidation PASSED\x1b[0m\n");
    } else {
        try writer.writeAll("\x1b[31mValidation FAILED\x1b[0m\n");
    }

    try writer.print("  Fields checked: {d}\n\n", .{result.fields_checked});

    if (result.errors.items.len > 0) {
        try writer.writeAll("  \x1b[31mErrors:\x1b[0m\n");
        for (result.errors.items) |err| {
            try writer.print("    \x1b[31m[FAIL]\x1b[0m {s}: {s}\n", .{ err.path, err.message });
            try writer.print("           expected: {s}, got: {s}\n", .{ err.expected, err.actual });
        }
        try writer.writeAll("\n");
    }

    if (result.warnings.items.len > 0) {
        try writer.writeAll("  \x1b[33mWarnings:\x1b[0m\n");
        for (result.warnings.items) |warn| {
            try writer.print("    \x1b[33m[WARN]\x1b[0m {s}: {s}\n", .{ warn.path, warn.message });
        }
        try writer.writeAll("\n");
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "validate valid JSON against schema" {
    const json =
        \\{"id": 42, "name": "John", "email": "john@example.com", "active": true}
    ;

    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    try schema.required_fields.append("id");
    try schema.required_fields.append("name");

    try schema.fields.append(.{ .name = "id", .field_type = .number, .required = true });
    try schema.fields.append(.{ .name = "name", .field_type = .string, .required = true });
    try schema.fields.append(.{ .name = "email", .field_type = .string });
    try schema.fields.append(.{ .name = "active", .field_type = .boolean });

    var result = try validate(std.testing.allocator, json, &schema);
    defer result.deinit();

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
}

test "validate JSON with type errors" {
    const json =
        \\{"id": "not-a-number", "name": 123}
    ;

    var schema = Schema.init(std.testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    try schema.required_fields.append("id");
    try schema.required_fields.append("name");
    try schema.required_fields.append("email");

    try schema.fields.append(.{ .name = "id", .field_type = .number, .required = true });
    try schema.fields.append(.{ .name = "name", .field_type = .string, .required = true });

    var result = try validate(std.testing.allocator, json, &schema);
    defer result.deinit();

    try std.testing.expect(!result.valid);
    // Should have errors: id is string not number, name is number not string, email is missing
    try std.testing.expect(result.errors.items.len >= 2);
}

test "infer schema from JSON" {
    const json =
        \\{"id": 42, "name": "John", "tags": [1, 2], "active": true}
    ;

    var schema = try inferSchema(std.testing.allocator, json);
    defer schema.deinit();

    try std.testing.expectEqual(SchemaType.object, schema.root_type);
    try std.testing.expect(schema.fields.items.len >= 3);

    // Verify inferred types
    var found_id = false;
    var found_name = false;
    var found_tags = false;
    var found_active = false;
    for (schema.fields.items) |field| {
        if (mem.eql(u8, field.name, "id")) {
            try std.testing.expectEqual(SchemaType.number, field.field_type);
            found_id = true;
        }
        if (mem.eql(u8, field.name, "name")) {
            try std.testing.expectEqual(SchemaType.string, field.field_type);
            found_name = true;
        }
        if (mem.eql(u8, field.name, "tags")) {
            try std.testing.expectEqual(SchemaType.array, field.field_type);
            found_tags = true;
        }
        if (mem.eql(u8, field.name, "active")) {
            try std.testing.expectEqual(SchemaType.boolean, field.field_type);
            found_active = true;
        }
    }
    try std.testing.expect(found_id);
    try std.testing.expect(found_name);
    try std.testing.expect(found_tags);
    try std.testing.expect(found_active);
}

test "parse schema from YAML-like format" {
    const content =
        \\type: object
        \\required: id, name, email
        \\properties:
        \\  id: number
        \\  name: string
        \\  email: string
        \\  tags: array
        \\  active: boolean
    ;

    var schema = try parseSchema(std.testing.allocator, content);
    defer schema.deinit();

    try std.testing.expectEqual(SchemaType.object, schema.root_type);
    try std.testing.expectEqual(@as(usize, 3), schema.required_fields.items.len);
    try std.testing.expectEqual(@as(usize, 5), schema.fields.items.len);

    try std.testing.expectEqualStrings("id", schema.fields.items[0].name);
    try std.testing.expectEqual(SchemaType.number, schema.fields.items[0].field_type);
    try std.testing.expect(schema.fields.items[0].required);

    try std.testing.expectEqualStrings("tags", schema.fields.items[3].name);
    try std.testing.expectEqual(SchemaType.array, schema.fields.items[3].field_type);
    try std.testing.expect(!schema.fields.items[3].required);
}
