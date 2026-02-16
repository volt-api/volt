const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── JSONPath Query Engine ───────────────────────────────────────────────
// Simple JSONPath query engine for use in test assertions.
// Supports basic dot-notation paths for querying JSON response bodies.
//
// Supported syntax:
//   $.field           — top-level field
//   $.field.nested    — nested field access
//   $.array[0]        — array index access
//   $.array[0].field  — array element field access
//   $.field[*]        — array length (returns count as string)
//   $                 — root value

/// Query a JSON string with a JSONPath expression.
/// Returns the matched value as an allocated string, or null if not found.
/// For string values, surrounding quotes are stripped.
/// For objects/arrays, the raw JSON is returned.
pub fn query(allocator: Allocator, json: []const u8, path: []const u8) !?[]const u8 {
    const trimmed_json = mem.trim(u8, json, " \t\r\n");
    if (trimmed_json.len == 0) return null;

    // Handle root query "$"
    const trimmed_path = mem.trim(u8, path, " ");
    if (mem.eql(u8, trimmed_path, "$")) {
        return try allocator.dupe(u8, trimmed_json);
    }

    // Remove leading "$." or "$"
    var rest = trimmed_path;
    if (mem.startsWith(u8, rest, "$.")) {
        rest = rest[2..];
    } else if (mem.startsWith(u8, rest, "$")) {
        rest = rest[1..];
    }
    if (rest.len == 0) {
        return try allocator.dupe(u8, trimmed_json);
    }

    // Split path into segments on '.' — but we need to handle [N] within segments
    var current = trimmed_json;

    var segments = std.ArrayList([]const u8).init(allocator);
    defer segments.deinit();
    try splitPath(allocator, rest, &segments);

    for (segments.items) |segment| {
        // Check for array index: "field[N]" or "[N]" or "field[*]"
        if (mem.indexOf(u8, segment, "[")) |bracket_pos| {
            const field_name = segment[0..bracket_pos];
            const bracket_content = segment[bracket_pos + 1 ..];

            // Navigate into the field first if field_name is not empty
            if (field_name.len > 0) {
                current = findJsonValue(current, field_name) orelse return null;
            }

            // Now handle the bracket expression
            if (mem.startsWith(u8, bracket_content, "*]")) {
                // Array length — count elements
                const count_val = countArrayElements(current);
                return try std.fmt.allocPrint(allocator, "{d}", .{count_val});
            } else {
                // Array index
                const idx_end = mem.indexOf(u8, bracket_content, "]") orelse return null;
                const idx_str = bracket_content[0..idx_end];
                const idx = std.fmt.parseInt(usize, idx_str, 10) catch return null;
                current = getArrayElement(current, idx) orelse return null;
            }
        } else {
            // Simple field access
            current = findJsonValue(current, segment) orelse return null;
        }
    }

    // Strip surrounding quotes for string values
    if (current.len >= 2 and current[0] == '"' and current[current.len - 1] == '"') {
        return try allocator.dupe(u8, current[1 .. current.len - 1]);
    }

    return try allocator.dupe(u8, current);
}

/// Query and parse the result as a boolean.
pub fn queryBool(allocator: Allocator, json: []const u8, path: []const u8) !?bool {
    const val = try query(allocator, json, path) orelse return null;
    defer allocator.free(val);

    if (mem.eql(u8, val, "true")) return true;
    if (mem.eql(u8, val, "false")) return false;
    return null;
}

/// Query and parse the result as a number.
pub fn queryNumber(allocator: Allocator, json: []const u8, path: []const u8) !?f64 {
    const val = try query(allocator, json, path) orelse return null;
    defer allocator.free(val);

    return std.fmt.parseFloat(f64, val) catch null;
}

/// Check whether a value exists at the given path.
pub fn exists(json: []const u8, path: []const u8) bool {
    // Use a stack-based check — we can't allocate here, so we navigate manually
    const trimmed_json = mem.trim(u8, json, " \t\r\n");
    if (trimmed_json.len == 0) return false;

    const trimmed_path = mem.trim(u8, path, " ");
    if (mem.eql(u8, trimmed_path, "$")) return true;

    var rest = trimmed_path;
    if (mem.startsWith(u8, rest, "$.")) {
        rest = rest[2..];
    } else if (mem.startsWith(u8, rest, "$")) {
        rest = rest[1..];
    }
    if (rest.len == 0) return true;

    // Walk segments one at a time
    var current = trimmed_json;
    var remaining = rest;

    while (remaining.len > 0) {
        // Extract next segment (up to next '.' or end)
        var seg_end: usize = 0;
        var bracket_depth: usize = 0;
        while (seg_end < remaining.len) {
            if (remaining[seg_end] == '[') bracket_depth += 1;
            if (remaining[seg_end] == ']') bracket_depth -|= 1;
            if (remaining[seg_end] == '.' and bracket_depth == 0) break;
            seg_end += 1;
        }
        const segment = remaining[0..seg_end];
        remaining = if (seg_end < remaining.len) remaining[seg_end + 1 ..] else "";

        if (mem.indexOf(u8, segment, "[")) |bracket_pos| {
            const field_name = segment[0..bracket_pos];
            const bracket_content = segment[bracket_pos + 1 ..];

            if (field_name.len > 0) {
                current = findJsonValue(current, field_name) orelse return false;
            }

            if (mem.startsWith(u8, bracket_content, "*]")) {
                // Array length — always exists if current is an array
                return current.len > 0 and current[0] == '[';
            } else {
                const idx_end = mem.indexOf(u8, bracket_content, "]") orelse return false;
                const idx_str = bracket_content[0..idx_end];
                const idx = std.fmt.parseInt(usize, idx_str, 10) catch return false;
                current = getArrayElement(current, idx) orelse return false;
            }
        } else {
            current = findJsonValue(current, segment) orelse return false;
        }
    }

    return true;
}

// ── Internal Helpers ────────────────────────────────────────────────────

/// Split a JSONPath expression into segments, respecting bracket notation.
fn splitPath(allocator: Allocator, path: []const u8, segments: *std.ArrayList([]const u8)) !void {
    var start: usize = 0;
    var i: usize = 0;
    var bracket_depth: usize = 0;

    while (i < path.len) {
        if (path[i] == '[') bracket_depth += 1;
        if (path[i] == ']') bracket_depth -|= 1;
        if (path[i] == '.' and bracket_depth == 0) {
            if (i > start) {
                try segments.append(path[start..i]);
            }
            start = i + 1;
        }
        i += 1;
    }
    if (start < path.len) {
        try segments.append(path[start..]);
    }
    _ = allocator;
}

/// Find the value associated with a key in a JSON object string.
/// Returns the raw value substring.
fn findJsonValue(json: []const u8, key: []const u8) ?[]const u8 {
    const trimmed = mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;

    // Search for "key" : value at depth 1
    var i: usize = 1; // skip opening {
    var depth: usize = 1;

    while (i < trimmed.len) {
        const c = trimmed[i];

        // Skip strings
        if (c == '"') {
            // Check if this is our key at depth 1
            if (depth == 1) {
                const str_start = i + 1;
                const str_end = findStringEnd(trimmed, i);
                if (str_end == null) return null;
                const end = str_end.?;
                const str_content = trimmed[str_start..end];

                i = end + 1;

                // Check if this key matches
                if (mem.eql(u8, str_content, key)) {
                    // Skip whitespace and colon
                    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n')) : (i += 1) {}
                    if (i < trimmed.len and trimmed[i] == ':') {
                        i += 1;
                        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n')) : (i += 1) {}
                        // Extract the value
                        return extractValue(trimmed, i);
                    }
                } else {
                    // Skip past the colon and value
                    continue;
                }
            } else {
                // Skip string at other depths
                const end = findStringEnd(trimmed, i) orelse return null;
                i = end + 1;
                continue;
            }
        }

        if (c == '{' or c == '[') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == '}' or c == ']') {
            depth -|= 1;
            if (depth == 0) break;
            i += 1;
            continue;
        }

        i += 1;
    }

    return null;
}

/// Find the end of a JSON string starting at the opening quote position.
/// Returns the index of the closing quote.
fn findStringEnd(json: []const u8, start: usize) ?usize {
    var i = start + 1;
    while (i < json.len) {
        if (json[i] == '\\') {
            i += 2;
            continue;
        }
        if (json[i] == '"') return i;
        i += 1;
    }
    return null;
}

/// Extract a JSON value starting at position `pos`.
/// Returns the substring representing the entire value.
fn extractValue(json: []const u8, pos: usize) ?[]const u8 {
    if (pos >= json.len) return null;

    const c = json[pos];

    if (c == '"') {
        // String value — include quotes
        const end = findStringEnd(json, pos) orelse return null;
        return json[pos .. end + 1];
    }

    if (c == '{' or c == '[') {
        // Object or array
        const open = c;
        const close: u8 = if (open == '{') '}' else ']';
        var depth: usize = 0;
        var in_string = false;
        var i = pos;
        while (i < json.len) {
            if (json[i] == '"' and (i == 0 or json[i - 1] != '\\')) {
                in_string = !in_string;
            } else if (!in_string) {
                if (json[i] == open) depth += 1;
                if (json[i] == close) {
                    depth -= 1;
                    if (depth == 0) return json[pos .. i + 1];
                }
            }
            i += 1;
        }
        return json[pos..];
    }

    // Primitive: read until comma, }, ], or whitespace that precedes them
    var end = pos;
    while (end < json.len and json[end] != ',' and json[end] != '}' and json[end] != ']' and json[end] != '\n' and json[end] != '\r') {
        end += 1;
    }
    return mem.trim(u8, json[pos..end], " \t");
}

/// Get an element from a JSON array by index.
fn getArrayElement(json: []const u8, index: usize) ?[]const u8 {
    const trimmed = mem.trim(u8, json, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '[') return null;

    var i: usize = 1; // skip opening [
    var current_index: usize = 0;

    // Skip whitespace
    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n')) : (i += 1) {}

    while (i < trimmed.len and trimmed[i] != ']') {
        // We're at the start of an element
        const val = extractValue(trimmed, i) orelse return null;

        if (current_index == index) return val;

        // Advance past this value
        i += val.len;

        // Skip whitespace and comma
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n' or trimmed[i] == ',')) : (i += 1) {}

        current_index += 1;
    }

    return null;
}

/// Count the number of elements in a JSON array.
fn countArrayElements(json: []const u8) usize {
    const trimmed = mem.trim(u8, json, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '[') return 0;

    // Empty array
    const inner = mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
    if (inner.len == 0) return 0;

    var count: usize = 0;
    var i: usize = 1; // skip [

    // Skip whitespace
    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n')) : (i += 1) {}

    while (i < trimmed.len and trimmed[i] != ']') {
        const val = extractValue(trimmed, i) orelse break;
        count += 1;
        i += val.len;

        // Skip whitespace and comma
        while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t' or trimmed[i] == '\r' or trimmed[i] == '\n' or trimmed[i] == ',')) : (i += 1) {}
    }

    return count;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "query top-level field" {
    const json =
        \\{"name": "Alice", "age": 30, "active": true}
    ;

    const name = try query(std.testing.allocator, json, "$.name");
    try std.testing.expect(name != null);
    defer std.testing.allocator.free(name.?);
    try std.testing.expectEqualStrings("Alice", name.?);

    const age = try queryNumber(std.testing.allocator, json, "$.age");
    try std.testing.expect(age != null);
    try std.testing.expectEqual(@as(f64, 30.0), age.?);

    const active = try queryBool(std.testing.allocator, json, "$.active");
    try std.testing.expect(active != null);
    try std.testing.expect(active.?);
}

test "query nested field" {
    const json =
        \\{"user": {"name": "Bob", "address": {"city": "NYC"}}}
    ;

    const city = try query(std.testing.allocator, json, "$.user.address.city");
    try std.testing.expect(city != null);
    defer std.testing.allocator.free(city.?);
    try std.testing.expectEqualStrings("NYC", city.?);

    // Verify exists works too
    try std.testing.expect(exists(json, "$.user.address.city"));
    try std.testing.expect(!exists(json, "$.user.address.zip"));
}

test "query array index" {
    const json =
        \\{"items": [{"id": 1}, {"id": 2}, {"id": 3}]}
    ;

    const second_id = try query(std.testing.allocator, json, "$.items[1].id");
    try std.testing.expect(second_id != null);
    defer std.testing.allocator.free(second_id.?);
    try std.testing.expectEqualStrings("2", second_id.?);
}

test "query array length" {
    const json =
        \\{"tags": ["a", "b", "c", "d"]}
    ;

    const length = try query(std.testing.allocator, json, "$.tags[*]");
    try std.testing.expect(length != null);
    defer std.testing.allocator.free(length.?);
    try std.testing.expectEqualStrings("4", length.?);
}
