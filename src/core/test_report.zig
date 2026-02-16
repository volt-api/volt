const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Test Report Generator ───────────────────────────────────────────────
// Generates HTML and JSON test reports for sharing Volt test results.
// HTML reports use a dark theme with inline CSS (no external dependencies).
// JSON reports provide machine-readable structured output for custom tooling.

pub const ReportEntry = struct {
    file: []const u8,
    test_name: []const u8,
    passed: bool,
    actual: ?[]const u8,
    expected: ?[]const u8,
    time_ms: f64,
};

pub const ReportSummary = struct {
    total: usize,
    passed: usize,
    failed: usize,
    time_ms: f64,
    entries: std.ArrayList(ReportEntry),

    pub fn init(allocator: Allocator) ReportSummary {
        return .{
            .total = 0,
            .passed = 0,
            .failed = 0,
            .time_ms = 0,
            .entries = std.ArrayList(ReportEntry).init(allocator),
        };
    }

    pub fn deinit(self: *ReportSummary) void {
        self.entries.deinit();
    }
};

/// Write HTML-escaped text to the writer
fn writeHtmlEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Write JSON-escaped text to the writer
fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}

/// Generate a dark-themed HTML test report
pub fn generateHtmlReport(allocator: Allocator, summary: *const ReportSummary) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // HTML head with inline CSS
    try writer.writeAll("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n");
    try writer.writeAll("  <meta charset=\"UTF-8\">\n");
    try writer.writeAll("  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n");
    try writer.writeAll("  <title>Volt Test Report</title>\n");
    try writer.writeAll("  <style>\n");
    try writer.writeAll("    * { margin: 0; padding: 0; box-sizing: border-box; }\n");
    try writer.writeAll("    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;\n");
    try writer.writeAll("      background: #1a1a2e; color: #e0e0e0; line-height: 1.6; padding: 2rem; }\n");
    try writer.writeAll("    .container { max-width: 960px; margin: 0 auto; }\n");
    try writer.writeAll("    h1 { color: #00d4ff; margin-bottom: 0.5rem; font-size: 2rem; }\n");
    try writer.writeAll("    .subtitle { color: #888; margin-bottom: 2rem; }\n");
    try writer.writeAll("    .summary { display: flex; gap: 1.5rem; margin-bottom: 2rem; flex-wrap: wrap; }\n");
    try writer.writeAll("    .summary-card { background: #16213e; border-radius: 8px; padding: 1rem 1.5rem;\n");
    try writer.writeAll("      border: 1px solid #2a2a4a; min-width: 140px; }\n");
    try writer.writeAll("    .summary-card .label { color: #888; font-size: 0.85rem; text-transform: uppercase; }\n");
    try writer.writeAll("    .summary-card .value { font-size: 1.8rem; font-weight: bold; }\n");
    try writer.writeAll("    .value-total { color: #00d4ff; }\n");
    try writer.writeAll("    .value-passed { color: #2ecc71; }\n");
    try writer.writeAll("    .value-failed { color: #e74c3c; }\n");
    try writer.writeAll("    .value-time { color: #f39c12; }\n");
    try writer.writeAll("    .results { margin-top: 1.5rem; }\n");
    try writer.writeAll("    .result-row { background: #16213e; border-radius: 8px; padding: 1rem 1.5rem;\n");
    try writer.writeAll("      margin-bottom: 0.75rem; border: 1px solid #2a2a4a;\n");
    try writer.writeAll("      display: flex; align-items: center; gap: 1rem; }\n");
    try writer.writeAll("    .result-icon { font-size: 1.2rem; min-width: 1.5rem; text-align: center; }\n");
    try writer.writeAll("    .icon-pass { color: #2ecc71; }\n");
    try writer.writeAll("    .icon-fail { color: #e74c3c; }\n");
    try writer.writeAll("    .result-info { flex: 1; }\n");
    try writer.writeAll("    .result-file { color: #888; font-size: 0.85rem; }\n");
    try writer.writeAll("    .result-name { color: #e0e0e0; font-weight: 500; }\n");
    try writer.writeAll("    .result-time { color: #888; font-size: 0.85rem; min-width: 80px; text-align: right; }\n");
    try writer.writeAll("    .result-detail { color: #e74c3c; font-size: 0.85rem; margin-top: 0.25rem; }\n");
    try writer.writeAll("    .footer { color: #555; font-size: 0.85rem; margin-top: 2rem; text-align: center; }\n");
    try writer.writeAll("    hr { border: none; border-top: 1px solid #2a2a4a; margin: 2rem 0; }\n");
    try writer.writeAll("  </style>\n");
    try writer.writeAll("</head>\n<body>\n");
    try writer.writeAll("  <div class=\"container\">\n");

    // Title
    try writer.writeAll("    <h1>Volt Test Report</h1>\n");
    try writer.writeAll("    <p class=\"subtitle\">Generated by Volt API Client</p>\n");

    // Summary cards
    try writer.writeAll("    <div class=\"summary\">\n");
    try writer.print("      <div class=\"summary-card\"><div class=\"label\">Total</div><div class=\"value value-total\">{d}</div></div>\n", .{summary.total});
    try writer.print("      <div class=\"summary-card\"><div class=\"label\">Passed</div><div class=\"value value-passed\">{d}</div></div>\n", .{summary.passed});
    try writer.print("      <div class=\"summary-card\"><div class=\"label\">Failed</div><div class=\"value value-failed\">{d}</div></div>\n", .{summary.failed});
    try writer.print("      <div class=\"summary-card\"><div class=\"label\">Time</div><div class=\"value value-time\">{d:.1}ms</div></div>\n", .{summary.time_ms});
    try writer.writeAll("    </div>\n");

    try writer.writeAll("    <hr>\n");

    // Results list
    try writer.writeAll("    <div class=\"results\">\n");
    for (summary.entries.items) |entry| {
        try writer.writeAll("      <div class=\"result-row\">\n");

        // Pass/fail icon
        if (entry.passed) {
            try writer.writeAll("        <div class=\"result-icon icon-pass\">&#10003;</div>\n");
        } else {
            try writer.writeAll("        <div class=\"result-icon icon-fail\">&#10007;</div>\n");
        }

        // Info block
        try writer.writeAll("        <div class=\"result-info\">\n");
        try writer.writeAll("          <div class=\"result-file\">");
        try writeHtmlEscaped(writer, entry.file);
        try writer.writeAll("</div>\n");
        try writer.writeAll("          <div class=\"result-name\">");
        try writeHtmlEscaped(writer, entry.test_name);
        try writer.writeAll("</div>\n");

        // Show expected/actual for failures
        if (!entry.passed) {
            if (entry.expected) |expected| {
                try writer.writeAll("          <div class=\"result-detail\">Expected: ");
                try writeHtmlEscaped(writer, expected);
                try writer.writeAll("</div>\n");
            }
            if (entry.actual) |actual| {
                try writer.writeAll("          <div class=\"result-detail\">Actual: ");
                try writeHtmlEscaped(writer, actual);
                try writer.writeAll("</div>\n");
            }
        }

        try writer.writeAll("        </div>\n");

        // Timing
        try writer.print("        <div class=\"result-time\">{d:.1}ms</div>\n", .{entry.time_ms});

        try writer.writeAll("      </div>\n");
    }
    try writer.writeAll("    </div>\n");

    // Footer
    try writer.print("    <p class=\"footer\">{d} test(s) executed</p>\n", .{summary.total});
    try writer.writeAll("  </div>\n");
    try writer.writeAll("</body>\n</html>\n");

    return buf.toOwnedSlice();
}

/// Generate a structured JSON test report
pub fn generateJsonReport(allocator: Allocator, summary: *const ReportSummary) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\n");
    try writer.writeAll("  \"summary\": {\n");
    try writer.print("    \"total\": {d},\n", .{summary.total});
    try writer.print("    \"passed\": {d},\n", .{summary.passed});
    try writer.print("    \"failed\": {d},\n", .{summary.failed});
    try writer.print("    \"time_ms\": {d:.2}\n", .{summary.time_ms});
    try writer.writeAll("  },\n");

    try writer.writeAll("  \"results\": [\n");
    for (summary.entries.items, 0..) |entry, i| {
        if (i > 0) try writer.writeAll(",\n");
        try writer.writeAll("    {\n");
        try writer.writeAll("      \"file\": \"");
        try writeJsonEscaped(writer, entry.file);
        try writer.writeAll("\",\n");
        try writer.writeAll("      \"test_name\": \"");
        try writeJsonEscaped(writer, entry.test_name);
        try writer.writeAll("\",\n");
        try writer.print("      \"passed\": {s},\n", .{if (entry.passed) "true" else "false"});
        try writer.print("      \"time_ms\": {d:.2}", .{entry.time_ms});

        if (entry.expected) |expected| {
            try writer.writeAll(",\n      \"expected\": \"");
            try writeJsonEscaped(writer, expected);
            try writer.writeAll("\"");
        }
        if (entry.actual) |actual| {
            try writer.writeAll(",\n      \"actual\": \"");
            try writeJsonEscaped(writer, actual);
            try writer.writeAll("\"");
        }

        try writer.writeAll("\n    }");
    }
    try writer.writeAll("\n  ]\n");
    try writer.writeAll("}\n");

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "generate HTML report contains summary" {
    const allocator = std.testing.allocator;

    var summary = ReportSummary.init(allocator);
    defer summary.deinit();
    summary.total = 3;
    summary.passed = 2;
    summary.failed = 1;
    summary.time_ms = 345.6;

    try summary.entries.append(.{
        .file = "api/users.volt",
        .test_name = "status equals 200",
        .passed = true,
        .actual = null,
        .expected = null,
        .time_ms = 120.0,
    });
    try summary.entries.append(.{
        .file = "api/users.volt",
        .test_name = "body contains users",
        .passed = true,
        .actual = null,
        .expected = null,
        .time_ms = 100.0,
    });
    try summary.entries.append(.{
        .file = "api/orders.volt",
        .test_name = "status equals 201",
        .passed = false,
        .actual = "400",
        .expected = "201",
        .time_ms = 125.6,
    });

    const html = try generateHtmlReport(allocator, &summary);
    defer allocator.free(html);

    // Verify HTML structure
    try std.testing.expect(mem.indexOf(u8, html, "<!DOCTYPE html>") != null);
    try std.testing.expect(mem.indexOf(u8, html, "Volt Test Report") != null);
    // Verify summary values are present
    try std.testing.expect(mem.indexOf(u8, html, "Total") != null);
    try std.testing.expect(mem.indexOf(u8, html, "Passed") != null);
    try std.testing.expect(mem.indexOf(u8, html, "Failed") != null);
    // Verify test entries appear
    try std.testing.expect(mem.indexOf(u8, html, "api/users.volt") != null);
    try std.testing.expect(mem.indexOf(u8, html, "status equals 200") != null);
    try std.testing.expect(mem.indexOf(u8, html, "api/orders.volt") != null);
    // Verify pass/fail indicators present
    try std.testing.expect(mem.indexOf(u8, html, "icon-pass") != null);
    try std.testing.expect(mem.indexOf(u8, html, "icon-fail") != null);
    // Verify inline CSS is present (no external dependencies)
    try std.testing.expect(mem.indexOf(u8, html, "<style>") != null);
    // Verify dark theme background color
    try std.testing.expect(mem.indexOf(u8, html, "#1a1a2e") != null);
}

test "generate JSON report has valid structure" {
    const allocator = std.testing.allocator;

    var summary = ReportSummary.init(allocator);
    defer summary.deinit();
    summary.total = 2;
    summary.passed = 1;
    summary.failed = 1;
    summary.time_ms = 250.0;

    try summary.entries.append(.{
        .file = "api/health.volt",
        .test_name = "status equals 200",
        .passed = true,
        .actual = null,
        .expected = null,
        .time_ms = 50.0,
    });
    try summary.entries.append(.{
        .file = "api/health.volt",
        .test_name = "body contains ok",
        .passed = false,
        .actual = "error",
        .expected = "ok",
        .time_ms = 200.0,
    });

    const json = try generateJsonReport(allocator, &summary);
    defer allocator.free(json);

    // Verify JSON structure keys
    try std.testing.expect(mem.indexOf(u8, json, "\"summary\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"results\"") != null);
    // Verify summary fields
    try std.testing.expect(mem.indexOf(u8, json, "\"total\": 2") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"passed\": 1") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"failed\": 1") != null);
    // Verify results entries
    try std.testing.expect(mem.indexOf(u8, json, "\"file\": \"api/health.volt\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"test_name\": \"status equals 200\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"passed\": true") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"passed\": false") != null);
    // Verify failure details present
    try std.testing.expect(mem.indexOf(u8, json, "\"expected\": \"ok\"") != null);
    try std.testing.expect(mem.indexOf(u8, json, "\"actual\": \"error\"") != null);
}
