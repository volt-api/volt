const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── History Replay with Response Diffing ────────────────────────────────
// Re-execute historical requests and compare responses against the original.
// Detects changes in status codes, headers, and response bodies (with
// special handling for JSON payloads to provide field-level diffs).

pub const ChangeType = enum {
    added,
    removed,
    modified,
    unchanged,

    pub fn toString(self: ChangeType) []const u8 {
        return switch (self) {
            .added => "added",
            .removed => "removed",
            .modified => "modified",
            .unchanged => "unchanged",
        };
    }

    pub fn symbol(self: ChangeType) []const u8 {
        return switch (self) {
            .added => "+",
            .removed => "-",
            .modified => "~",
            .unchanged => " ",
        };
    }
};

pub const Change = struct {
    field: []const u8,
    old_value: []const u8,
    new_value: []const u8,
    change_type: ChangeType,
};

pub const ReplayConfig = struct {
    entry_index: usize,
    diff_mode: bool = true,
    verbose: bool = false,
};

pub const ReplayResult = struct {
    original_status: ?u16,
    replay_status: u16,
    timing_ms: f64,
    changes: std.ArrayList(Change),
    matched: bool,

    pub fn init(allocator: Allocator) ReplayResult {
        return .{
            .original_status = null,
            .replay_status = 0,
            .timing_ms = 0,
            .changes = std.ArrayList(Change).init(allocator),
            .matched = true,
        };
    }

    pub fn deinit(self: *ReplayResult) void {
        self.changes.deinit();
    }
};

/// Compare two response bodies and return a list of changes.
/// If both are JSON, performs field-level comparison of top-level keys.
/// Otherwise, performs a simple text equality check.
pub fn compareResponses(allocator: Allocator, original_body: []const u8, replay_body: []const u8) std.ArrayList(Change) {
    var changes = std.ArrayList(Change).init(allocator);

    const orig_trimmed = mem.trim(u8, original_body, " \t\r\n");
    const replay_trimmed = mem.trim(u8, replay_body, " \t\r\n");

    // Check if both look like JSON objects
    const orig_is_json = orig_trimmed.len > 0 and orig_trimmed[0] == '{';
    const replay_is_json = replay_trimmed.len > 0 and replay_trimmed[0] == '{';

    if (orig_is_json and replay_is_json) {
        // JSON field-level comparison of top-level keys
        compareJsonFields(allocator, orig_trimmed, replay_trimmed, &changes);
    } else {
        // Simple text comparison
        if (mem.eql(u8, orig_trimmed, replay_trimmed)) {
            changes.append(.{
                .field = "body",
                .old_value = orig_trimmed,
                .new_value = replay_trimmed,
                .change_type = .unchanged,
            }) catch {}; // output only
        } else {
            changes.append(.{
                .field = "body",
                .old_value = orig_trimmed,
                .new_value = replay_trimmed,
                .change_type = .modified,
            }) catch {}; // output only
        }
    }

    return changes;
}

/// Compare two sets of headers and return a list of changes.
/// Headers are expected as "Name: Value\nName: Value" format.
pub fn compareHeaders(allocator: Allocator, original_headers: []const u8, replay_headers: []const u8) std.ArrayList(Change) {
    var changes = std.ArrayList(Change).init(allocator);

    // Parse headers into maps
    var orig_map = std.StringHashMap([]const u8).init(allocator);
    defer orig_map.deinit();
    var replay_map = std.StringHashMap([]const u8).init(allocator);
    defer replay_map.deinit();

    parseHeadersIntoMap(original_headers, &orig_map);
    parseHeadersIntoMap(replay_headers, &replay_map);

    // Check original headers against replay
    var orig_iter = orig_map.iterator();
    while (orig_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const orig_val = entry.value_ptr.*;
        if (replay_map.get(key)) |replay_val| {
            if (mem.eql(u8, orig_val, replay_val)) {
                changes.append(.{
                    .field = key,
                    .old_value = orig_val,
                    .new_value = replay_val,
                    .change_type = .unchanged,
                }) catch {}; // output only
            } else {
                changes.append(.{
                    .field = key,
                    .old_value = orig_val,
                    .new_value = replay_val,
                    .change_type = .modified,
                }) catch {}; // output only
            }
        } else {
            changes.append(.{
                .field = key,
                .old_value = orig_val,
                .new_value = "",
                .change_type = .removed,
            }) catch {}; // output only
        }
    }

    // Check for headers added in replay
    var replay_iter = replay_map.iterator();
    while (replay_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (orig_map.get(key) == null) {
            changes.append(.{
                .field = key,
                .old_value = "",
                .new_value = entry.value_ptr.*,
                .change_type = .added,
            }) catch {}; // output only
        }
    }

    return changes;
}

/// Format a replay result as a readable diff output with color coding.
pub fn formatReplayDiff(allocator: Allocator, result: *const ReplayResult) []const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    writer.writeAll("\x1b[1mReplay Diff\x1b[0m\n\n") catch return "";

    // Status comparison
    if (result.original_status) |orig_status| {
        if (orig_status == result.replay_status) {
            writer.print("  Status: {d} -> {d} \x1b[32m(unchanged)\x1b[0m\n", .{ orig_status, result.replay_status }) catch {};
        } else {
            writer.print("  Status: {d} -> {d} \x1b[31m(CHANGED)\x1b[0m\n", .{ orig_status, result.replay_status }) catch {};
        }
    } else {
        writer.print("  Status: ? -> {d}\n", .{result.replay_status}) catch {};
    }

    writer.writeAll("\n") catch {};

    // Changes
    if (result.changes.items.len == 0) {
        writer.writeAll("  No changes detected.\n") catch {};
    } else {
        var added_count: usize = 0;
        var removed_count: usize = 0;
        var modified_count: usize = 0;

        for (result.changes.items) |change| {
            switch (change.change_type) {
                .added => {
                    added_count += 1;
                    writer.print("  \x1b[32m+ {s}: {s}\x1b[0m\n", .{ change.field, change.new_value }) catch {};
                },
                .removed => {
                    removed_count += 1;
                    writer.print("  \x1b[31m- {s}: {s}\x1b[0m\n", .{ change.field, change.old_value }) catch {};
                },
                .modified => {
                    modified_count += 1;
                    writer.print("  \x1b[33m~ {s}: {s} -> {s}\x1b[0m\n", .{ change.field, change.old_value, change.new_value }) catch {};
                },
                .unchanged => {
                    writer.print("    {s}: {s}\n", .{ change.field, change.new_value }) catch {};
                },
            }
        }

        writer.writeAll("\n") catch {};
        writer.print("  \x1b[32m+{d}\x1b[0m \x1b[31m-{d}\x1b[0m \x1b[33m~{d}\x1b[0m\n", .{ added_count, removed_count, modified_count }) catch {};
    }

    writer.print("\n  Timing: {d:.1}ms\n", .{result.timing_ms}) catch {};

    return buf.toOwnedSlice() catch return "";
}

/// Format a one-line replay summary.
pub fn formatReplaySummary(allocator: Allocator, result: *const ReplayResult) []const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Count actual changes (non-unchanged)
    var change_count: usize = 0;
    for (result.changes.items) |change| {
        if (change.change_type != .unchanged) {
            change_count += 1;
        }
    }

    const status_indicator: []const u8 = if (result.matched) "\x1b[32m" else "\x1b[31m";

    writer.print("Replay: {s}{d}\x1b[0m | {d} change(s) | {d:.1}ms", .{
        status_indicator,
        result.replay_status,
        change_count,
        result.timing_ms,
    }) catch return "";

    return buf.toOwnedSlice() catch return "";
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// Parse header string into a StringHashMap.
fn parseHeadersIntoMap(headers: []const u8, map: *std.StringHashMap([]const u8)) void {
    var lines = mem.splitSequence(u8, headers, "\n");
    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const colon_pos = mem.indexOf(u8, trimmed, ":") orelse continue;
        const name = mem.trim(u8, trimmed[0..colon_pos], " \t");
        const value = if (colon_pos + 1 < trimmed.len)
            mem.trim(u8, trimmed[colon_pos + 1 ..], " \t")
        else
            "";

        map.put(name, value) catch continue;
    }
}

/// Compare top-level JSON fields between two JSON objects.
fn compareJsonFields(allocator: Allocator, original: []const u8, replay: []const u8, changes: *std.ArrayList(Change)) void {
    // Extract top-level keys from both JSON objects
    var orig_keys = std.StringHashMap([]const u8).init(allocator);
    defer orig_keys.deinit();
    var replay_keys = std.StringHashMap([]const u8).init(allocator);
    defer replay_keys.deinit();

    extractTopLevelKeys(original, &orig_keys);
    extractTopLevelKeys(replay, &replay_keys);

    // Compare original keys against replay
    var orig_iter = orig_keys.iterator();
    while (orig_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const orig_val = entry.value_ptr.*;
        if (replay_keys.get(key)) |replay_val| {
            if (mem.eql(u8, orig_val, replay_val)) {
                changes.append(.{
                    .field = key,
                    .old_value = orig_val,
                    .new_value = replay_val,
                    .change_type = .unchanged,
                }) catch {}; // output only
            } else {
                changes.append(.{
                    .field = key,
                    .old_value = orig_val,
                    .new_value = replay_val,
                    .change_type = .modified,
                }) catch {}; // output only
            }
        } else {
            changes.append(.{
                .field = key,
                .old_value = orig_val,
                .new_value = "",
                .change_type = .removed,
            }) catch {}; // output only
        }
    }

    // Check for keys added in replay
    var replay_iter = replay_keys.iterator();
    while (replay_iter.next()) |entry| {
        const key = entry.key_ptr.*;
        if (orig_keys.get(key) == null) {
            changes.append(.{
                .field = key,
                .old_value = "",
                .new_value = entry.value_ptr.*,
                .change_type = .added,
            }) catch {}; // output only
        }
    }
}

/// Extract top-level key-value pairs from a JSON object string.
fn extractTopLevelKeys(json: []const u8, map: *std.StringHashMap([]const u8)) void {
    if (json.len < 2) return;

    // Skip the outer braces
    const content = json[1 .. json.len - 1];
    var remaining = content;

    while (mem.indexOf(u8, remaining, "\"")) |key_quote_start| {
        const after_quote = remaining[key_quote_start + 1 ..];
        const key_quote_end = mem.indexOf(u8, after_quote, "\"") orelse break;
        const key = after_quote[0..key_quote_end];

        // Skip to colon
        const after_key = after_quote[key_quote_end + 1 ..];
        const colon_pos = mem.indexOf(u8, after_key, ":") orelse break;
        var value_data = after_key[colon_pos + 1 ..];

        // Skip whitespace
        while (value_data.len > 0 and (value_data[0] == ' ' or value_data[0] == '\t' or value_data[0] == '\n' or value_data[0] == '\r')) {
            value_data = value_data[1..];
        }

        if (value_data.len == 0) break;

        // Extract value
        var value: []const u8 = "";
        var advance: usize = 0;

        if (value_data[0] == '"') {
            // String value
            if (mem.indexOf(u8, value_data[1..], "\"")) |end| {
                value = value_data[1 .. end + 1];
                advance = end + 2;
            }
        } else if (value_data[0] == '{' or value_data[0] == '[') {
            // Object or array
            if (findMatchingBrace(value_data)) |block| {
                value = block;
                advance = block.len;
            }
        } else {
            // Number, boolean, null
            var end: usize = 0;
            while (end < value_data.len and value_data[end] != ',' and value_data[end] != '}' and value_data[end] != '\n') {
                end += 1;
            }
            value = mem.trim(u8, value_data[0..end], " \t\r\n");
            advance = end;
        }

        map.put(key, value) catch {}; // output only

        // Move past this key-value pair
        const consumed = @intFromPtr(value_data.ptr) - @intFromPtr(remaining.ptr) + advance;
        if (consumed >= remaining.len) break;
        remaining = remaining[consumed..];
    }
}

/// Find the matching closing brace/bracket for an opening one.
fn findMatchingBrace(data: []const u8) ?[]const u8 {
    if (data.len == 0) return null;
    const open = data[0];
    const close: u8 = if (open == '{') '}' else if (open == '[') ']' else return null;
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

test "compareResponses detects identical JSON" {
    const original = "{\"name\": \"John\", \"age\": 30}";
    const replay = "{\"name\": \"John\", \"age\": 30}";

    var changes = compareResponses(std.testing.allocator, original, replay);
    defer changes.deinit();

    // All fields should be unchanged
    for (changes.items) |change| {
        try std.testing.expectEqual(ChangeType.unchanged, change.change_type);
    }
}

test "compareResponses detects modified JSON field" {
    const original = "{\"name\": \"John\", \"age\": 30}";
    const replay = "{\"name\": \"Jane\", \"age\": 30}";

    var changes = compareResponses(std.testing.allocator, original, replay);
    defer changes.deinit();

    var found_modified = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "name") and change.change_type == .modified) {
            found_modified = true;
            try std.testing.expectEqualStrings("John", change.old_value);
            try std.testing.expectEqualStrings("Jane", change.new_value);
        }
    }
    try std.testing.expect(found_modified);
}

test "compareResponses detects added JSON field" {
    const original = "{\"name\": \"John\"}";
    const replay = "{\"name\": \"John\", \"email\": \"john@test.com\"}";

    var changes = compareResponses(std.testing.allocator, original, replay);
    defer changes.deinit();

    var found_added = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "email") and change.change_type == .added) {
            found_added = true;
        }
    }
    try std.testing.expect(found_added);
}

test "compareResponses detects removed JSON field" {
    const original = "{\"name\": \"John\", \"age\": 30}";
    const replay = "{\"name\": \"John\"}";

    var changes = compareResponses(std.testing.allocator, original, replay);
    defer changes.deinit();

    var found_removed = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "age") and change.change_type == .removed) {
            found_removed = true;
        }
    }
    try std.testing.expect(found_removed);
}

test "compareResponses handles non-JSON text" {
    const original = "Hello World";
    const replay = "Hello Universe";

    var changes = compareResponses(std.testing.allocator, original, replay);
    defer changes.deinit();

    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expectEqual(ChangeType.modified, changes.items[0].change_type);
    try std.testing.expectEqualStrings("body", changes.items[0].field);
}

test "compareResponses handles identical non-JSON text" {
    const original = "Hello World";
    const replay = "Hello World";

    var changes = compareResponses(std.testing.allocator, original, replay);
    defer changes.deinit();

    try std.testing.expectEqual(@as(usize, 1), changes.items.len);
    try std.testing.expectEqual(ChangeType.unchanged, changes.items[0].change_type);
}

test "compareHeaders detects unchanged headers" {
    const original = "Content-Type: application/json\nX-Request-Id: abc123";
    const replay = "Content-Type: application/json\nX-Request-Id: abc123";

    var changes = compareHeaders(std.testing.allocator, original, replay);
    defer changes.deinit();

    for (changes.items) |change| {
        try std.testing.expectEqual(ChangeType.unchanged, change.change_type);
    }
}

test "compareHeaders detects modified header" {
    const original = "Content-Type: application/json\nX-Version: 1";
    const replay = "Content-Type: application/json\nX-Version: 2";

    var changes = compareHeaders(std.testing.allocator, original, replay);
    defer changes.deinit();

    var found_modified = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "X-Version") and change.change_type == .modified) {
            found_modified = true;
            try std.testing.expectEqualStrings("1", change.old_value);
            try std.testing.expectEqualStrings("2", change.new_value);
        }
    }
    try std.testing.expect(found_modified);
}

test "compareHeaders detects added and removed headers" {
    const original = "Content-Type: application/json\nX-Old: value";
    const replay = "Content-Type: application/json\nX-New: value";

    var changes = compareHeaders(std.testing.allocator, original, replay);
    defer changes.deinit();

    var found_removed = false;
    var found_added = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "X-Old") and change.change_type == .removed) found_removed = true;
        if (mem.eql(u8, change.field, "X-New") and change.change_type == .added) found_added = true;
    }
    try std.testing.expect(found_removed);
    try std.testing.expect(found_added);
}

test "formatReplayDiff produces colored output" {
    var result = ReplayResult.init(std.testing.allocator);
    defer result.deinit();
    result.original_status = 200;
    result.replay_status = 200;
    result.timing_ms = 42.5;
    result.matched = true;

    try result.changes.append(.{
        .field = "name",
        .old_value = "John",
        .new_value = "John",
        .change_type = .unchanged,
    });
    try result.changes.append(.{
        .field = "email",
        .old_value = "",
        .new_value = "john@test.com",
        .change_type = .added,
    });
    try result.changes.append(.{
        .field = "age",
        .old_value = "30",
        .new_value = "",
        .change_type = .removed,
    });

    const diff = formatReplayDiff(std.testing.allocator, &result);
    defer std.testing.allocator.free(diff);

    try std.testing.expect(mem.indexOf(u8, diff, "Replay Diff") != null);
    try std.testing.expect(mem.indexOf(u8, diff, "200") != null);
    try std.testing.expect(mem.indexOf(u8, diff, "unchanged") != null);
    try std.testing.expect(mem.indexOf(u8, diff, "+ email") != null);
    try std.testing.expect(mem.indexOf(u8, diff, "- age") != null);
    try std.testing.expect(mem.indexOf(u8, diff, "42.5ms") != null);
}

test "formatReplayDiff shows status change" {
    var result = ReplayResult.init(std.testing.allocator);
    defer result.deinit();
    result.original_status = 200;
    result.replay_status = 404;
    result.timing_ms = 15.0;
    result.matched = false;

    const diff = formatReplayDiff(std.testing.allocator, &result);
    defer std.testing.allocator.free(diff);

    try std.testing.expect(mem.indexOf(u8, diff, "200") != null);
    try std.testing.expect(mem.indexOf(u8, diff, "404") != null);
    try std.testing.expect(mem.indexOf(u8, diff, "CHANGED") != null);
}

test "formatReplaySummary produces one-line output" {
    var result = ReplayResult.init(std.testing.allocator);
    defer result.deinit();
    result.original_status = 200;
    result.replay_status = 200;
    result.timing_ms = 35.2;
    result.matched = true;

    try result.changes.append(.{
        .field = "name",
        .old_value = "old",
        .new_value = "new",
        .change_type = .modified,
    });
    try result.changes.append(.{
        .field = "id",
        .old_value = "1",
        .new_value = "1",
        .change_type = .unchanged,
    });

    const summary = formatReplaySummary(std.testing.allocator, &result);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(mem.indexOf(u8, summary, "Replay:") != null);
    try std.testing.expect(mem.indexOf(u8, summary, "200") != null);
    try std.testing.expect(mem.indexOf(u8, summary, "1 change(s)") != null);
    try std.testing.expect(mem.indexOf(u8, summary, "35.2ms") != null);
}

test "formatReplaySummary counts only actual changes" {
    var result = ReplayResult.init(std.testing.allocator);
    defer result.deinit();
    result.replay_status = 200;
    result.timing_ms = 10.0;
    result.matched = true;

    // Only unchanged entries
    try result.changes.append(.{
        .field = "data",
        .old_value = "same",
        .new_value = "same",
        .change_type = .unchanged,
    });

    const summary = formatReplaySummary(std.testing.allocator, &result);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(mem.indexOf(u8, summary, "0 change(s)") != null);
}

test "ReplayResult init and deinit" {
    var result = ReplayResult.init(std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(?u16, null), result.original_status);
    try std.testing.expectEqual(@as(u16, 0), result.replay_status);
    try std.testing.expectEqual(true, result.matched);
    try std.testing.expectEqual(@as(usize, 0), result.changes.items.len);
}

test "ChangeType toString and symbol" {
    try std.testing.expectEqualStrings("added", ChangeType.added.toString());
    try std.testing.expectEqualStrings("+", ChangeType.added.symbol());
    try std.testing.expectEqualStrings("removed", ChangeType.removed.toString());
    try std.testing.expectEqualStrings("-", ChangeType.removed.symbol());
    try std.testing.expectEqualStrings("modified", ChangeType.modified.toString());
    try std.testing.expectEqualStrings("~", ChangeType.modified.symbol());
    try std.testing.expectEqualStrings("unchanged", ChangeType.unchanged.toString());
    try std.testing.expectEqualStrings(" ", ChangeType.unchanged.symbol());
}
