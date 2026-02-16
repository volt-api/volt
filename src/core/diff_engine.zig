const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Enhanced Diff Engine ────────────────────────────────────────────────
//
// Enhanced diff engine for comparing API responses.
// Detects breaking changes in API contracts:
//   - Removed fields
//   - Type changes
//   - Status code changes
//   - Missing required headers
//   - Response size changes

pub const ChangeType = enum {
    field_added,
    field_removed,
    field_type_changed,
    value_changed,
    status_changed,
    header_added,
    header_removed,
    header_value_changed,
    body_size_changed,

    pub fn isBreaking(self: ChangeType) bool {
        return switch (self) {
            .field_removed, .field_type_changed => true,
            .status_changed => true,
            else => false,
        };
    }

    pub fn toString(self: ChangeType) []const u8 {
        return switch (self) {
            .field_added => "field_added",
            .field_removed => "field_removed",
            .field_type_changed => "field_type_changed",
            .value_changed => "value_changed",
            .status_changed => "status_changed",
            .header_added => "header_added",
            .header_removed => "header_removed",
            .header_value_changed => "header_value_changed",
            .body_size_changed => "body_size_changed",
        };
    }
};

pub const Change = struct {
    change_type: ChangeType,
    path: []const u8,
    old_value: ?[]const u8,
    new_value: ?[]const u8,
    severity: Severity,
};

pub const Severity = enum {
    info,
    warning,
    breaking,

    pub fn toString(self: Severity) []const u8 {
        return switch (self) {
            .info => "INFO",
            .warning => "WARNING",
            .breaking => "BREAKING",
        };
    }
};

pub const DiffResult = struct {
    changes: std.ArrayList(Change),
    breaking_count: usize,
    warning_count: usize,
    info_count: usize,
    is_compatible: bool,

    pub fn init(allocator: Allocator) DiffResult {
        return .{
            .changes = std.ArrayList(Change).init(allocator),
            .breaking_count = 0,
            .warning_count = 0,
            .info_count = 0,
            .is_compatible = true,
        };
    }

    pub fn deinit(self: *DiffResult) void {
        self.changes.deinit();
    }
};

const FieldType = enum {
    string,
    number,
    boolean,
    object,
    array,
    null_type,
    unknown,

    pub fn toString(self: FieldType) []const u8 {
        return switch (self) {
            .string => "string",
            .number => "number",
            .boolean => "boolean",
            .object => "object",
            .array => "array",
            .null_type => "null",
            .unknown => "unknown",
        };
    }
};

const FieldInfo = struct {
    name: []const u8,
    field_type: FieldType,
    value: []const u8,
};

/// Detect the JSON type of a value by examining its first non-whitespace character
fn detectType(value: []const u8) FieldType {
    const trimmed = mem.trim(u8, value, " \t\n\r");
    if (trimmed.len == 0) return .unknown;

    return switch (trimmed[0]) {
        '"' => .string,
        '{' => .object,
        '[' => .array,
        't', 'f' => .boolean,
        'n' => .null_type,
        '0'...'9', '-' => .number,
        else => .unknown,
    };
}

/// Extract top-level JSON fields from a JSON object string.
/// Returns a list of FieldInfo structs with name, type, and raw value.
fn extractFields(allocator: Allocator, json: []const u8) !std.ArrayList(FieldInfo) {
    var fields = std.ArrayList(FieldInfo).init(allocator);

    const trimmed = mem.trim(u8, json, " \t\n\r");
    if (trimmed.len < 2 or trimmed[0] != '{') return fields;

    // Scan for top-level "key": value patterns
    var i: usize = 1; // skip opening '{'
    while (i < trimmed.len) {
        // Skip whitespace
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\n' or trimmed[i] == '\r' or trimmed[i] == ',')) {
            i += 1;
        }
        if (i >= trimmed.len or trimmed[i] == '}') break;

        // Expect opening quote for key
        if (trimmed[i] != '"') {
            i += 1;
            continue;
        }
        i += 1;

        // Read key
        const key_start = i;
        while (i < trimmed.len and trimmed[i] != '"') {
            if (trimmed[i] == '\\') i += 1;
            i += 1;
        }
        if (i >= trimmed.len) break;
        const key = trimmed[key_start..i];
        i += 1; // skip closing quote

        // Skip colon and whitespace
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == ':' or trimmed[i] == '\t')) {
            i += 1;
        }
        if (i >= trimmed.len) break;

        // Read value - need to handle nested structures
        const value_start = i;
        var value_end = i;

        if (trimmed[i] == '"') {
            // String value - find closing quote
            i += 1;
            while (i < trimmed.len and trimmed[i] != '"') {
                if (trimmed[i] == '\\') i += 1;
                i += 1;
            }
            if (i < trimmed.len) i += 1;
            value_end = i;
        } else if (trimmed[i] == '{' or trimmed[i] == '[') {
            // Nested object/array - match braces
            const open_char = trimmed[i];
            const close_char: u8 = if (open_char == '{') '}' else ']';
            var depth: usize = 1;
            i += 1;
            while (i < trimmed.len and depth > 0) {
                if (trimmed[i] == open_char) {
                    depth += 1;
                } else if (trimmed[i] == close_char) {
                    depth -= 1;
                } else if (trimmed[i] == '"') {
                    // Skip strings inside nested structures
                    i += 1;
                    while (i < trimmed.len and trimmed[i] != '"') {
                        if (trimmed[i] == '\\') i += 1;
                        i += 1;
                    }
                }
                i += 1;
            }
            value_end = i;
        } else {
            // Primitive value (number, bool, null)
            while (i < trimmed.len and trimmed[i] != ',' and trimmed[i] != '}' and trimmed[i] != '\n' and trimmed[i] != '\r') {
                i += 1;
            }
            value_end = i;
        }

        const value = mem.trim(u8, trimmed[value_start..value_end], " \t\n\r");
        try fields.append(.{
            .name = key,
            .field_type = detectType(value),
            .value = value,
        });
    }

    return fields;
}

/// Compare two JSON response bodies
pub fn diffJson(allocator: Allocator, old_json: []const u8, new_json: []const u8) !DiffResult {
    var result = DiffResult.init(allocator);

    var old_fields = try extractFields(allocator, old_json);
    defer old_fields.deinit();
    var new_fields = try extractFields(allocator, new_json);
    defer new_fields.deinit();

    // Check for fields in old but not in new (removed)
    for (old_fields.items) |old_field| {
        var found = false;
        for (new_fields.items) |new_field| {
            if (mem.eql(u8, old_field.name, new_field.name)) {
                found = true;
                // Check type change
                if (old_field.field_type != new_field.field_type) {
                    try result.changes.append(.{
                        .change_type = .field_type_changed,
                        .path = old_field.name,
                        .old_value = old_field.field_type.toString(),
                        .new_value = new_field.field_type.toString(),
                        .severity = .breaking,
                    });
                    result.breaking_count += 1;
                    result.is_compatible = false;
                } else if (!mem.eql(u8, old_field.value, new_field.value)) {
                    // Same type, different value
                    try result.changes.append(.{
                        .change_type = .value_changed,
                        .path = old_field.name,
                        .old_value = old_field.value,
                        .new_value = new_field.value,
                        .severity = .info,
                    });
                    result.info_count += 1;
                }
                break;
            }
        }
        if (!found) {
            try result.changes.append(.{
                .change_type = .field_removed,
                .path = old_field.name,
                .old_value = old_field.field_type.toString(),
                .new_value = null,
                .severity = .breaking,
            });
            result.breaking_count += 1;
            result.is_compatible = false;
        }
    }

    // Check for fields in new but not in old (added)
    for (new_fields.items) |new_field| {
        var found = false;
        for (old_fields.items) |old_field| {
            if (mem.eql(u8, old_field.name, new_field.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try result.changes.append(.{
                .change_type = .field_added,
                .path = new_field.name,
                .old_value = null,
                .new_value = new_field.field_type.toString(),
                .severity = .info,
            });
            result.info_count += 1;
        }
    }

    return result;
}

/// Compare status codes
pub fn diffStatus(result: *DiffResult, old_status: u16, new_status: u16) !void {
    if (old_status == new_status) return;

    const old_is_success = old_status >= 200 and old_status < 300;
    const new_is_error = new_status >= 400;

    const severity: Severity = if (old_is_success and new_is_error) .breaking else .warning;

    try result.changes.append(.{
        .change_type = .status_changed,
        .path = "status",
        .old_value = statusToStr(old_status),
        .new_value = statusToStr(new_status),
        .severity = severity,
    });

    switch (severity) {
        .breaking => {
            result.breaking_count += 1;
            result.is_compatible = false;
        },
        .warning => {
            result.warning_count += 1;
        },
        .info => {
            result.info_count += 1;
        },
    }
}

fn statusToStr(code: u16) []const u8 {
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
        else => "unknown",
    };
}

/// Compare response headers
pub fn diffHeaders(allocator: Allocator, result: *DiffResult, old_headers: []const [2][]const u8, new_headers: []const [2][]const u8) !void {
    _ = allocator;

    // Check for removed or changed headers
    for (old_headers) |old_h| {
        var found = false;
        for (new_headers) |new_h| {
            if (std.ascii.eqlIgnoreCase(old_h[0], new_h[0])) {
                found = true;
                if (!mem.eql(u8, old_h[1], new_h[1])) {
                    try result.changes.append(.{
                        .change_type = .header_value_changed,
                        .path = old_h[0],
                        .old_value = old_h[1],
                        .new_value = new_h[1],
                        .severity = .warning,
                    });
                    result.warning_count += 1;
                }
                break;
            }
        }
        if (!found) {
            try result.changes.append(.{
                .change_type = .header_removed,
                .path = old_h[0],
                .old_value = old_h[1],
                .new_value = null,
                .severity = .warning,
            });
            result.warning_count += 1;
        }
    }

    // Check for added headers
    for (new_headers) |new_h| {
        var found = false;
        for (old_headers) |old_h| {
            if (std.ascii.eqlIgnoreCase(old_h[0], new_h[0])) {
                found = true;
                break;
            }
        }
        if (!found) {
            try result.changes.append(.{
                .change_type = .header_added,
                .path = new_h[0],
                .old_value = null,
                .new_value = new_h[1],
                .severity = .info,
            });
            result.info_count += 1;
        }
    }
}

/// Format diff result for terminal output
pub fn formatDiff(result: *const DiffResult, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("\x1b[1m--- API Diff Report ---\x1b[0m\n\n");

    for (result.changes.items) |change| {
        const prefix: []const u8 = switch (change.severity) {
            .breaking => "\x1b[31mBREAKING\x1b[0m",
            .warning => "\x1b[33mWARNING\x1b[0m",
            .info => "\x1b[34mINFO\x1b[0m",
        };

        try writer.print("  [{s}] {s}: {s}", .{ prefix, change.change_type.toString(), change.path });

        if (change.old_value) |old| {
            try writer.print(" (was: {s}", .{old});
            if (change.new_value) |new| {
                try writer.print(" -> {s}", .{new});
            }
            try writer.writeAll(")");
        } else if (change.new_value) |new| {
            try writer.print(" (type: {s})", .{new});
        }

        try writer.writeAll("\n");
    }

    try writer.writeAll("\n\x1b[1mSummary:\x1b[0m ");
    try writer.print("{d} breaking, {d} warnings, {d} info\n", .{ result.breaking_count, result.warning_count, result.info_count });

    if (result.is_compatible) {
        try writer.writeAll("\x1b[32mBackwards compatible\x1b[0m\n");
    } else {
        try writer.writeAll("\x1b[31mBreaking changes detected\x1b[0m\n");
    }

    return buf.toOwnedSlice();
}

/// Check if API change is backwards compatible
pub fn isBackwardsCompatible(result: *const DiffResult) bool {
    return result.breaking_count == 0;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "compatible change - field added" {
    const old_json =
        \\{"id": 1, "name": "test"}
    ;
    const new_json =
        \\{"id": 1, "name": "test", "email": "test@example.com"}
    ;

    var result = try diffJson(std.testing.allocator, old_json, new_json);
    defer result.deinit();

    try std.testing.expect(result.is_compatible);
    try std.testing.expectEqual(@as(usize, 0), result.breaking_count);
    // Should have one field_added change
    var added_count: usize = 0;
    for (result.changes.items) |change| {
        if (change.change_type == .field_added) {
            added_count += 1;
            try std.testing.expectEqualStrings("email", change.path);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), added_count);
}

test "breaking change - field removed" {
    const old_json =
        \\{"id": 1, "name": "test", "email": "a@b.com"}
    ;
    const new_json =
        \\{"id": 1, "name": "test"}
    ;

    var result = try diffJson(std.testing.allocator, old_json, new_json);
    defer result.deinit();

    try std.testing.expect(!result.is_compatible);
    try std.testing.expectEqual(@as(usize, 1), result.breaking_count);

    var removed_count: usize = 0;
    for (result.changes.items) |change| {
        if (change.change_type == .field_removed) {
            removed_count += 1;
            try std.testing.expectEqualStrings("email", change.path);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), removed_count);
}

test "diff status codes" {
    var result = DiffResult.init(std.testing.allocator);
    defer result.deinit();

    // Success to error is breaking
    try diffStatus(&result, 200, 500);
    try std.testing.expectEqual(@as(usize, 1), result.breaking_count);
    try std.testing.expect(!result.is_compatible);

    // Same status is no change
    var result2 = DiffResult.init(std.testing.allocator);
    defer result2.deinit();
    try diffStatus(&result2, 200, 200);
    try std.testing.expectEqual(@as(usize, 0), result2.changes.items.len);
}
