const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── CI Dashboard ────────────────────────────────────────────────────────
// Stores test run results, computes trends, and generates an HTML dashboard.
// Data is persisted as JSON files in .volt-ci/run-{timestamp}.json.

pub const FileResult = struct {
    file: []const u8,
    passed: bool,
    duration_ms: u64,
    assertions_passed: u32,
    assertions_failed: u32,
};

pub const RunRecord = struct {
    timestamp: i64,
    request_count: u32,
    test_count: u32,
    pass_count: u32,
    fail_count: u32,
    duration_ms: u64,
    files: []const FileResult,
};

const ci_dir = ".volt-ci";

// ── Persistence ─────────────────────────────────────────────────────────

/// Serialize a RunRecord to JSON and save to .volt-ci/run-{timestamp}.json.
pub fn recordRun(allocator: Allocator, record: RunRecord) !void {
    // Ensure .volt-ci directory exists
    std.fs.cwd().makeDir(ci_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const filename = try std.fmt.allocPrint(allocator, ci_dir ++ "/run-{d}.json", .{record.timestamp});
    defer allocator.free(filename);

    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try serializeRunRecord(writer, record);

    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Serialize a RunRecord as JSON to a writer.
fn serializeRunRecord(writer: anytype, record: RunRecord) !void {
    try writer.writeAll("{\n");
    try writer.print("  \"timestamp\": {d},\n", .{record.timestamp});
    try writer.print("  \"request_count\": {d},\n", .{record.request_count});
    try writer.print("  \"test_count\": {d},\n", .{record.test_count});
    try writer.print("  \"pass_count\": {d},\n", .{record.pass_count});
    try writer.print("  \"fail_count\": {d},\n", .{record.fail_count});
    try writer.print("  \"duration_ms\": {d},\n", .{record.duration_ms});
    try writer.writeAll("  \"files\": [");

    for (record.files, 0..) |f, i| {
        if (i > 0) try writer.writeAll(",");
        try writer.writeAll("\n    {");
        try writer.print("\"file\": \"{s}\", ", .{f.file});
        try writer.print("\"passed\": {s}, ", .{if (f.passed) "true" else "false"});
        try writer.print("\"duration_ms\": {d}, ", .{f.duration_ms});
        try writer.print("\"assertions_passed\": {d}, ", .{f.assertions_passed});
        try writer.print("\"assertions_failed\": {d}", .{f.assertions_failed});
        try writer.writeAll("}");
    }

    if (record.files.len > 0) {
        try writer.writeAll("\n  ");
    }
    try writer.writeAll("]\n}\n");
}

/// Load all run history from .volt-ci/run-*.json files, sorted by timestamp.
pub fn loadHistory(allocator: Allocator) ![]RunRecord {
    var records = std.ArrayList(RunRecord).init(allocator);
    errdefer {
        for (records.items) |rec| freeRunRecord(allocator, rec);
        records.deinit();
    }

    var dir = std.fs.cwd().openDir(ci_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return records.toOwnedSlice(),
        else => return err,
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.startsWith(u8, entry.name, "run-")) continue;
        if (!mem.endsWith(u8, entry.name, ".json")) continue;

        const content = dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch continue;
        defer allocator.free(content);

        const parsed = parseRunRecord(allocator, content) catch continue;
        try records.append(parsed);
    }

    // Sort by timestamp ascending
    std.mem.sort(RunRecord, records.items, {}, struct {
        fn lessThan(_: void, a: RunRecord, b: RunRecord) bool {
            return a.timestamp < b.timestamp;
        }
    }.lessThan);

    return records.toOwnedSlice();
}

/// Parse a RunRecord from JSON content.
pub fn parseRunRecord(allocator: Allocator, content: []const u8) !RunRecord {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    const timestamp = switch (root.get("timestamp").?) {
        .integer => |v| v,
        else => return error.InvalidFormat,
    };
    const request_count = switch (root.get("request_count").?) {
        .integer => |v| @as(u32, @intCast(v)),
        else => return error.InvalidFormat,
    };
    const test_count = switch (root.get("test_count").?) {
        .integer => |v| @as(u32, @intCast(v)),
        else => return error.InvalidFormat,
    };
    const pass_count = switch (root.get("pass_count").?) {
        .integer => |v| @as(u32, @intCast(v)),
        else => return error.InvalidFormat,
    };
    const fail_count = switch (root.get("fail_count").?) {
        .integer => |v| @as(u32, @intCast(v)),
        else => return error.InvalidFormat,
    };
    const duration_ms = switch (root.get("duration_ms").?) {
        .integer => |v| @as(u64, @intCast(v)),
        else => return error.InvalidFormat,
    };

    const files_arr = switch (root.get("files").?) {
        .array => |a| a,
        else => return error.InvalidFormat,
    };

    var files = std.ArrayList(FileResult).init(allocator);
    errdefer {
        for (files.items) |f| allocator.free(f.file);
        files.deinit();
    }

    for (files_arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const file_name = switch (obj.get("file").?) {
            .string => |s| try allocator.dupe(u8, s),
            else => continue,
        };
        const file_passed = switch (obj.get("passed").?) {
            .bool => |b| b,
            else => {
                allocator.free(file_name);
                continue;
            },
        };
        const file_dur = switch (obj.get("duration_ms").?) {
            .integer => |v| @as(u64, @intCast(v)),
            else => {
                allocator.free(file_name);
                continue;
            },
        };
        const a_passed = switch (obj.get("assertions_passed").?) {
            .integer => |v| @as(u32, @intCast(v)),
            else => {
                allocator.free(file_name);
                continue;
            },
        };
        const a_failed = switch (obj.get("assertions_failed").?) {
            .integer => |v| @as(u32, @intCast(v)),
            else => {
                allocator.free(file_name);
                continue;
            },
        };
        try files.append(.{
            .file = file_name,
            .passed = file_passed,
            .duration_ms = file_dur,
            .assertions_passed = a_passed,
            .assertions_failed = a_failed,
        });
    }

    return RunRecord{
        .timestamp = timestamp,
        .request_count = request_count,
        .test_count = test_count,
        .pass_count = pass_count,
        .fail_count = fail_count,
        .duration_ms = duration_ms,
        .files = try files.toOwnedSlice(),
    };
}

/// Free a RunRecord's owned memory.
pub fn freeRunRecord(allocator: Allocator, record: RunRecord) void {
    for (record.files) |f| {
        allocator.free(f.file);
    }
    allocator.free(record.files);
}

// ── Trend Analysis ──────────────────────────────────────────────────────

/// Compute pass rate percentage per run.
pub fn getPassRateTrend(allocator: Allocator, history: []const RunRecord) ![]f64 {
    var rates = try allocator.alloc(f64, history.len);
    for (history, 0..) |run, i| {
        if (run.test_count == 0) {
            rates[i] = 100.0;
        } else {
            rates[i] = @as(f64, @floatFromInt(run.pass_count)) / @as(f64, @floatFromInt(run.test_count)) * 100.0;
        }
    }
    return rates;
}

/// Get duration (ms) per run.
pub fn getDurationTrend(allocator: Allocator, history: []const RunRecord) ![]u64 {
    var durations = try allocator.alloc(u64, history.len);
    for (history, 0..) |run, i| {
        durations[i] = run.duration_ms;
    }
    return durations;
}

/// Regression detection: find files that passed in the previous run but fail now.
pub fn detectRegressions(allocator: Allocator, history: []const RunRecord) ![]const []const u8 {
    if (history.len < 2) return try allocator.alloc([]const u8, 0);

    const prev = history[history.len - 2];
    const curr = history[history.len - 1];

    var regressions = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (regressions.items) |r| allocator.free(r);
        regressions.deinit();
    }

    for (curr.files) |curr_file| {
        if (curr_file.passed) continue;
        // Check if this file was passing in the previous run
        for (prev.files) |prev_file| {
            if (mem.eql(u8, curr_file.file, prev_file.file) and prev_file.passed) {
                try regressions.append(try allocator.dupe(u8, curr_file.file));
                break;
            }
        }
    }

    return regressions.toOwnedSlice();
}

// ── HTML Dashboard Generation ───────────────────────────────────────────

/// Generate a standalone HTML dashboard string.
pub fn generateHtml(allocator: Allocator, history: []const RunRecord) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();

    // Compute stats
    const total_runs = history.len;
    var current_pass_rate: f64 = 0;
    var avg_duration: f64 = 0;

    if (history.len > 0) {
        const latest = history[history.len - 1];
        if (latest.test_count > 0) {
            current_pass_rate = @as(f64, @floatFromInt(latest.pass_count)) / @as(f64, @floatFromInt(latest.test_count)) * 100.0;
        } else {
            current_pass_rate = 100.0;
        }
        var total_dur: u64 = 0;
        for (history) |run| total_dur += run.duration_ms;
        avg_duration = @as(f64, @floatFromInt(total_dur)) / @as(f64, @floatFromInt(history.len));
    }

    // Detect regressions
    const regressions = try detectRegressions(allocator, history);
    defer {
        for (regressions) |r| allocator.free(r);
        allocator.free(regressions);
    }

    // Compute pass rates for chart
    const rates = try getPassRateTrend(allocator, history);
    defer allocator.free(rates);

    // HTML header
    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<title>Volt CI Dashboard</title>
        \\<style>
        \\  * { margin: 0; padding: 0; box-sizing: border-box; }
        \\  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
        \\         background: #0d1117; color: #c9d1d9; padding: 2rem; }
        \\  h1 { color: #58a6ff; margin-bottom: 1.5rem; }
        \\  h2 { color: #8b949e; margin: 1.5rem 0 0.75rem; font-size: 1.1rem; }
        \\  .stats { display: flex; gap: 1.5rem; margin-bottom: 2rem; }
        \\  .stat-card { background: #161b22; border: 1px solid #30363d; border-radius: 8px;
        \\               padding: 1rem 1.5rem; flex: 1; }
        \\  .stat-card .label { color: #8b949e; font-size: 0.85rem; }
        \\  .stat-card .value { font-size: 1.8rem; font-weight: 700; color: #58a6ff; }
        \\  .warn { background: #2d1b00; border-color: #d29922; }
        \\  .warn .value { color: #d29922; }
        \\  table { width: 100%; border-collapse: collapse; margin-top: 0.5rem; }
        \\  th, td { padding: 0.5rem 0.75rem; text-align: left; border-bottom: 1px solid #21262d; }
        \\  th { color: #8b949e; font-weight: 600; font-size: 0.85rem; }
        \\  .pass { color: #3fb950; } .fail { color: #f85149; }
        \\  svg { margin-top: 0.5rem; }
        \\</style>
        \\</head>
        \\<body>
        \\<h1>Volt CI Dashboard</h1>
        \\
    );

    // Summary stats
    try w.writeAll("<div class=\"stats\">\n");
    try w.print("  <div class=\"stat-card\"><div class=\"label\">Total Runs</div><div class=\"value\">{d}</div></div>\n", .{total_runs});
    try w.print("  <div class=\"stat-card\"><div class=\"label\">Current Pass Rate</div><div class=\"value\">{d:.1}%</div></div>\n", .{current_pass_rate});
    try w.print("  <div class=\"stat-card\"><div class=\"label\">Avg Duration</div><div class=\"value\">{d:.0}ms</div></div>\n", .{avg_duration});
    try w.writeAll("</div>\n");

    // Regression warnings
    if (regressions.len > 0) {
        try w.writeAll("<div class=\"stat-card warn\"><div class=\"label\">Regressions Detected</div><div class=\"value\">\n");
        for (regressions) |reg| {
            try w.print("  {s}<br>\n", .{reg});
        }
        try w.writeAll("</div></div>\n");
    }

    // SVG bar chart of pass rates (last 20 runs max)
    if (history.len > 0) {
        try w.writeAll("<h2>Pass Rate Trend</h2>\n");

        const max_bars: usize = 20;
        const start = if (history.len > max_bars) history.len - max_bars else 0;
        const display_count = history.len - start;
        const bar_width: u32 = 24;
        const gap: u32 = 4;
        const chart_height: u32 = 120;
        const svg_width = @as(u32, @intCast(display_count)) * (bar_width + gap) + gap;

        try w.print("<svg width=\"{d}\" height=\"{d}\" role=\"img\" aria-label=\"Pass rate bar chart\">\n", .{ svg_width, chart_height + 20 });

        for (start..history.len) |idx| {
            const bar_idx = idx - start;
            const rate = rates[idx];
            const bar_h = @as(u32, @intFromFloat(rate / 100.0 * @as(f64, @floatFromInt(chart_height))));
            const x = @as(u32, @intCast(bar_idx)) * (bar_width + gap) + gap;
            const y = chart_height - bar_h;
            const color: []const u8 = if (rate >= 80.0) "#3fb950" else if (rate >= 50.0) "#d29922" else "#f85149";

            try w.print("  <rect x=\"{d}\" y=\"{d}\" width=\"{d}\" height=\"{d}\" fill=\"{s}\" rx=\"3\" />\n", .{ x, y, bar_width, bar_h, color });
            try w.print("  <text x=\"{d}\" y=\"{d}\" fill=\"#8b949e\" font-size=\"10\" text-anchor=\"middle\">{d:.0}%</text>\n", .{ x + bar_width / 2, chart_height + 14, rate });
        }
        try w.writeAll("</svg>\n");
    }

    // Recent runs table
    if (history.len > 0) {
        try w.writeAll("<h2>Recent Runs</h2>\n");
        try w.writeAll("<table>\n<tr><th>Timestamp</th><th>Tests</th><th>Passed</th><th>Failed</th><th>Duration</th><th>Pass Rate</th></tr>\n");

        // Show last 20 runs, most recent first
        const table_start = if (history.len > 20) history.len - 20 else 0;
        var i: usize = history.len;
        while (i > table_start) {
            i -= 1;
            const run = history[i];
            const rate = if (run.test_count > 0)
                @as(f64, @floatFromInt(run.pass_count)) / @as(f64, @floatFromInt(run.test_count)) * 100.0
            else
                100.0;
            const rate_class: []const u8 = if (rate >= 80.0) "pass" else "fail";
            try w.print("<tr><td>{d}</td><td>{d}</td><td class=\"pass\">{d}</td><td class=\"fail\">{d}</td><td>{d}ms</td><td class=\"{s}\">{d:.1}%</td></tr>\n", .{ run.timestamp, run.test_count, run.pass_count, run.fail_count, run.duration_ms, rate_class, rate });
        }
        try w.writeAll("</table>\n");
    }

    // Footer
    try w.writeAll(
        \\<p style="margin-top:2rem;color:#484f58;font-size:0.8rem;">Generated by Volt CI Dashboard</p>
        \\</body>
        \\</html>
        \\
    );

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "serialization roundtrip" {
    const allocator = std.testing.allocator;

    const files = try allocator.alloc(FileResult, 2);
    defer allocator.free(files);
    files[0] = .{ .file = "api/users.volt", .passed = true, .duration_ms = 120, .assertions_passed = 3, .assertions_failed = 0 };
    files[1] = .{ .file = "api/orders.volt", .passed = false, .duration_ms = 250, .assertions_passed = 1, .assertions_failed = 2 };

    const original = RunRecord{
        .timestamp = 1700000000,
        .request_count = 5,
        .test_count = 4,
        .pass_count = 3,
        .fail_count = 1,
        .duration_ms = 370,
        .files = files,
    };

    // Serialize
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try serializeRunRecord(buf.writer(), original);

    // Parse back
    const parsed = try parseRunRecord(allocator, buf.items);
    defer freeRunRecord(allocator, parsed);

    try std.testing.expectEqual(original.timestamp, parsed.timestamp);
    try std.testing.expectEqual(original.request_count, parsed.request_count);
    try std.testing.expectEqual(original.test_count, parsed.test_count);
    try std.testing.expectEqual(original.pass_count, parsed.pass_count);
    try std.testing.expectEqual(original.fail_count, parsed.fail_count);
    try std.testing.expectEqual(original.duration_ms, parsed.duration_ms);
    try std.testing.expectEqual(original.files.len, parsed.files.len);
    try std.testing.expectEqualStrings("api/users.volt", parsed.files[0].file);
    try std.testing.expect(parsed.files[0].passed);
    try std.testing.expect(!parsed.files[1].passed);
}

test "pass rate calculation" {
    const allocator = std.testing.allocator;

    const empty_files: []const FileResult = &.{};
    const history = [_]RunRecord{
        .{ .timestamp = 1, .request_count = 2, .test_count = 10, .pass_count = 8, .fail_count = 2, .duration_ms = 100, .files = empty_files },
        .{ .timestamp = 2, .request_count = 2, .test_count = 10, .pass_count = 10, .fail_count = 0, .duration_ms = 90, .files = empty_files },
        .{ .timestamp = 3, .request_count = 2, .test_count = 4, .pass_count = 1, .fail_count = 3, .duration_ms = 200, .files = empty_files },
    };

    const rates = try getPassRateTrend(allocator, &history);
    defer allocator.free(rates);

    try std.testing.expectEqual(@as(usize, 3), rates.len);
    try std.testing.expectApproxEqAbs(@as(f64, 80.0), rates[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 100.0), rates[1], 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 25.0), rates[2], 0.01);
}

test "regression detection" {
    const allocator = std.testing.allocator;

    const prev_files = [_]FileResult{
        .{ .file = "a.volt", .passed = true, .duration_ms = 10, .assertions_passed = 1, .assertions_failed = 0 },
        .{ .file = "b.volt", .passed = true, .duration_ms = 20, .assertions_passed = 2, .assertions_failed = 0 },
        .{ .file = "c.volt", .passed = false, .duration_ms = 30, .assertions_passed = 0, .assertions_failed = 1 },
    };
    const curr_files = [_]FileResult{
        .{ .file = "a.volt", .passed = true, .duration_ms = 10, .assertions_passed = 1, .assertions_failed = 0 },
        .{ .file = "b.volt", .passed = false, .duration_ms = 25, .assertions_passed = 1, .assertions_failed = 1 },
        .{ .file = "c.volt", .passed = false, .duration_ms = 35, .assertions_passed = 0, .assertions_failed = 1 },
    };

    const empty_files: []const FileResult = &.{};
    const history = [_]RunRecord{
        .{ .timestamp = 1, .request_count = 3, .test_count = 3, .pass_count = 2, .fail_count = 1, .duration_ms = 60, .files = &prev_files },
        .{ .timestamp = 2, .request_count = 3, .test_count = 3, .pass_count = 1, .fail_count = 2, .duration_ms = 70, .files = &curr_files },
    };

    const regressions = try detectRegressions(allocator, &history);
    defer {
        for (regressions) |r| allocator.free(r);
        allocator.free(regressions);
    }

    // b.volt regressed (was passing, now failing). c.volt was already failing.
    try std.testing.expectEqual(@as(usize, 1), regressions.len);
    try std.testing.expectEqualStrings("b.volt", regressions[0]);

    // With only one run, no regressions
    const single = [_]RunRecord{
        .{ .timestamp = 1, .request_count = 1, .test_count = 1, .pass_count = 0, .fail_count = 1, .duration_ms = 10, .files = empty_files },
    };
    const no_reg = try detectRegressions(allocator, &single);
    defer allocator.free(no_reg);
    try std.testing.expectEqual(@as(usize, 0), no_reg.len);
}

test "HTML output contains expected elements" {
    const allocator = std.testing.allocator;

    const files = [_]FileResult{
        .{ .file = "test.volt", .passed = true, .duration_ms = 50, .assertions_passed = 2, .assertions_failed = 0 },
    };
    const history = [_]RunRecord{
        .{ .timestamp = 1000, .request_count = 1, .test_count = 2, .pass_count = 2, .fail_count = 0, .duration_ms = 50, .files = &files },
    };

    const html = try generateHtml(allocator, &history);
    defer allocator.free(html);

    try std.testing.expect(mem.indexOf(u8, html, "Volt CI Dashboard") != null);
    try std.testing.expect(mem.indexOf(u8, html, "Total Runs") != null);
    try std.testing.expect(mem.indexOf(u8, html, "Current Pass Rate") != null);
    try std.testing.expect(mem.indexOf(u8, html, "Avg Duration") != null);
    try std.testing.expect(mem.indexOf(u8, html, "Pass Rate Trend") != null);
    try std.testing.expect(mem.indexOf(u8, html, "Recent Runs") != null);
    try std.testing.expect(mem.indexOf(u8, html, "<svg") != null);
    try std.testing.expect(mem.indexOf(u8, html, "<table>") != null);
    try std.testing.expect(mem.indexOf(u8, html, "100.0%") != null);
}

test "empty history handling" {
    const allocator = std.testing.allocator;

    const empty: []const RunRecord = &.{};

    const html = try generateHtml(allocator, empty);
    defer allocator.free(html);

    try std.testing.expect(mem.indexOf(u8, html, "Volt CI Dashboard") != null);
    try std.testing.expect(mem.indexOf(u8, html, "Total Runs") != null);
    // Should show 0 total runs
    try std.testing.expect(mem.indexOf(u8, html, ">0<") != null);
    // No chart or table for empty history
    try std.testing.expect(mem.indexOf(u8, html, "<svg") == null);
    try std.testing.expect(mem.indexOf(u8, html, "Recent Runs") == null);

    // Also test trends with empty data
    const rates = try getPassRateTrend(allocator, empty);
    defer allocator.free(rates);
    try std.testing.expectEqual(@as(usize, 0), rates.len);

    const durations = try getDurationTrend(allocator, empty);
    defer allocator.free(durations);
    try std.testing.expectEqual(@as(usize, 0), durations.len);

    const regressions = try detectRegressions(allocator, empty);
    defer allocator.free(regressions);
    try std.testing.expectEqual(@as(usize, 0), regressions.len);
}
