const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Dynamic Variable Expansion ──────────────────────────────────────────
// Replaces special variables like {{$uuid}}, {{$timestamp}}, {{$randomInt}}
// with generated values in .volt file content.
// Regular {{name}} patterns (without $) are left untouched — those are
// environment variables handled by the environment module.

const dynamic_var_names = [_][]const u8{
    "$uuid",
    "$timestamp",
    "$isoTimestamp",
    "$isoDate",
    "$randomInt",
    "$randomFloat",
    "$randomEmail",
    "$randomString",
    "$randomBool",
    "$guid",
    "$date",
};

/// Check whether a variable name (without braces) is a known dynamic variable.
pub fn isDynamicVar(name: []const u8) bool {
    for (dynamic_var_names) |dv| {
        if (mem.eql(u8, name, dv)) return true;
    }
    return false;
}

/// Generate a value for a dynamic variable.
/// Returns null if the name is not a recognised dynamic variable.
pub fn generateValue(allocator: Allocator, var_name: []const u8) !?[]const u8 {
    if (mem.eql(u8, var_name, "$uuid") or mem.eql(u8, var_name, "$guid")) {
        return try generateUuid(allocator);
    }
    if (mem.eql(u8, var_name, "$timestamp")) {
        return try generateTimestamp(allocator);
    }
    if (mem.eql(u8, var_name, "$isoTimestamp") or mem.eql(u8, var_name, "$isoDate")) {
        return try generateIsoTimestamp(allocator);
    }
    if (mem.eql(u8, var_name, "$randomInt")) {
        return try generateRandomInt(allocator);
    }
    if (mem.eql(u8, var_name, "$randomFloat")) {
        return try generateRandomFloat(allocator);
    }
    if (mem.eql(u8, var_name, "$randomEmail")) {
        return try generateRandomEmail(allocator);
    }
    if (mem.eql(u8, var_name, "$randomString")) {
        return try generateRandomString(allocator);
    }
    if (mem.eql(u8, var_name, "$randomBool")) {
        return try generateRandomBool(allocator);
    }
    if (mem.eql(u8, var_name, "$date")) {
        return try generateDate(allocator);
    }
    return null;
}

/// Scan `input` for `{{$...}}` patterns and replace them with generated values.
/// Regular `{{name}}` patterns (without $) are left untouched.
pub fn expandDynamicVars(allocator: Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < input.len) {
        if (i + 1 < input.len and input[i] == '{' and input[i + 1] == '{') {
            // Find closing }}
            const start = i + 2;
            var end = start;
            while (end + 1 < input.len) {
                if (input[end] == '}' and input[end + 1] == '}') break;
                end += 1;
            }
            if (end + 1 < input.len and input[end] == '}' and input[end + 1] == '}') {
                const var_name = mem.trim(u8, input[start..end], " ");

                if (mem.startsWith(u8, var_name, "$")) {
                    if (try generateValue(allocator, var_name)) |val| {
                        defer allocator.free(val);
                        try result.appendSlice(val);
                    } else {
                        // Unknown dynamic variable — keep original placeholder
                        try result.appendSlice(input[i .. end + 2]);
                    }
                } else {
                    // Not a dynamic variable — keep original placeholder
                    try result.appendSlice(input[i .. end + 2]);
                }
                i = end + 2;
            } else {
                try result.append(input[i]);
                i += 1;
            }
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

// ── Value Generators ────────────────────────────────────────────────────

fn generateUuid(allocator: Allocator) ![]const u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Set version 4 (bits 12-15 of time_hi_and_version)
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    // Set variant (bits 6-7 of clk_seq_hi_res)
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    var buf: [36]u8 = undefined;
    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (bytes, 0..) |b, idx| {
        if (idx == 4 or idx == 6 or idx == 8 or idx == 10) {
            buf[pos] = '-';
            pos += 1;
        }
        buf[pos] = hex[@as(usize, b >> 4)];
        buf[pos + 1] = hex[@as(usize, b & 0x0F)];
        pos += 2;
    }

    return try allocator.dupe(u8, &buf);
}

fn generateTimestamp(allocator: Allocator) ![]const u8 {
    const ts: u64 = @intCast(std.time.timestamp());
    return try std.fmt.allocPrint(allocator, "{d}", .{ts});
}

fn generateIsoTimestamp(allocator: Allocator) ![]const u8 {
    const epoch_seconds: u64 = @intCast(std.time.timestamp());
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn generateRandomInt(allocator: Allocator) ![]const u8 {
    const val = std.crypto.random.intRangeAtMost(u16, 0, 9999);
    return try std.fmt.allocPrint(allocator, "{d}", .{val});
}

fn generateRandomFloat(allocator: Allocator) ![]const u8 {
    const int_val = std.crypto.random.intRangeAtMost(u32, 0, 100);
    const f: f64 = @as(f64, @floatFromInt(int_val)) / 100.0;
    return try std.fmt.allocPrint(allocator, "{d:.2}", .{f});
}

fn generateRandomEmail(allocator: Allocator) ![]const u8 {
    const n = std.crypto.random.intRangeAtMost(u16, 0, 9999);
    return try std.fmt.allocPrint(allocator, "user{d}@example.com", .{n});
}

fn generateRandomString(allocator: Allocator) ![]const u8 {
    var buf: [8]u8 = undefined;
    for (&buf) |*c| {
        c.* = 'a' + std.crypto.random.intRangeAtMost(u8, 0, 25);
    }
    return try allocator.dupe(u8, &buf);
}

fn generateRandomBool(allocator: Allocator) ![]const u8 {
    const val = std.crypto.random.boolean();
    return try allocator.dupe(u8, if (val) "true" else "false");
}

fn generateDate(allocator: Allocator) ![]const u8 {
    const epoch_seconds: u64 = @intCast(std.time.timestamp());
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
}

// ── Tests ───────────────────────────────────────────────────────────────

test "expand $timestamp produces digits" {
    const input = "ts={{$timestamp}}";
    const result = try expandDynamicVars(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    // Should start with "ts=" and the rest should be digits
    try std.testing.expect(mem.startsWith(u8, result, "ts="));
    const ts_part = result["ts=".len..];
    try std.testing.expect(ts_part.len > 0);
    for (ts_part) |c| {
        try std.testing.expect(c >= '0' and c <= '9');
    }
}

test "expand $uuid produces 36-char UUID" {
    const input = "id={{$uuid}}";
    const result = try expandDynamicVars(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.startsWith(u8, result, "id="));
    const uuid_part = result["id=".len..];
    // UUID v4 is 36 characters: 8-4-4-4-12
    try std.testing.expectEqual(@as(usize, 36), uuid_part.len);
    try std.testing.expectEqual(@as(u8, '-'), uuid_part[8]);
    try std.testing.expectEqual(@as(u8, '-'), uuid_part[13]);
    try std.testing.expectEqual(@as(u8, '-'), uuid_part[18]);
    try std.testing.expectEqual(@as(u8, '-'), uuid_part[23]);
}

test "non-dynamic vars left untouched" {
    const input = "url={{base_url}}/api/{{version}}";
    const result = try expandDynamicVars(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    // Non-dynamic variables should remain as-is
    try std.testing.expectEqualStrings("url={{base_url}}/api/{{version}}", result);
}
