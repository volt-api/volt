const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── JUnit XML Test Report Generator ─────────────────────────────────────
// Generates JUnit XML test reports from Volt test results.
// JUnit XML is the standard format consumed by CI/CD pipelines including
// Jenkins, GitHub Actions, GitLab CI, Azure DevOps, and CircleCI.

pub const TestCase = struct {
    name: []const u8,
    classname: []const u8,
    time_seconds: f64,
    passed: bool,
    failure_message: ?[]const u8,
    failure_detail: ?[]const u8,
};

pub const TestSuite = struct {
    name: []const u8,
    test_cases: std.ArrayList(TestCase),
    time_seconds: f64,

    pub fn init(allocator: Allocator, name: []const u8) TestSuite {
        return .{
            .name = name,
            .test_cases = std.ArrayList(TestCase).init(allocator),
            .time_seconds = 0,
        };
    }

    pub fn deinit(self: *TestSuite) void {
        self.test_cases.deinit();
    }

    pub fn addCase(self: *TestSuite, tc: TestCase) !void {
        try self.test_cases.append(tc);
    }

    pub fn totalTests(self: *const TestSuite) usize {
        return self.test_cases.items.len;
    }

    pub fn totalFailures(self: *const TestSuite) usize {
        var count: usize = 0;
        for (self.test_cases.items) |tc| {
            if (!tc.passed) count += 1;
        }
        return count;
    }
};

pub const TestReport = struct {
    suites: std.ArrayList(TestSuite),

    pub fn init(allocator: Allocator) TestReport {
        return .{
            .suites = std.ArrayList(TestSuite).init(allocator),
        };
    }

    pub fn deinit(self: *TestReport) void {
        for (self.suites.items) |*suite| {
            suite.deinit();
        }
        self.suites.deinit();
    }

    pub fn addSuite(self: *TestReport, suite: TestSuite) !void {
        try self.suites.append(suite);
    }

    pub fn totalTests(self: *const TestReport) usize {
        var count: usize = 0;
        for (self.suites.items) |*suite| {
            count += suite.totalTests();
        }
        return count;
    }

    pub fn totalFailures(self: *const TestReport) usize {
        var count: usize = 0;
        for (self.suites.items) |*suite| {
            count += suite.totalFailures();
        }
        return count;
    }

    pub fn totalTime(self: *const TestReport) f64 {
        var t: f64 = 0;
        for (self.suites.items) |suite| {
            t += suite.time_seconds;
        }
        return t;
    }
};

/// Write XML-escaped text to the writer, escaping &, <, >, ", and '
fn writeXmlEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(c),
        }
    }
}

/// Generate a JUnit XML report string from a TestReport
pub fn generateJUnitXML(allocator: Allocator, report: *const TestReport) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // XML declaration
    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");

    // Root <testsuites> element
    try writer.print("<testsuites tests=\"{d}\" failures=\"{d}\" time=\"{d:.3}\">\n", .{
        report.totalTests(),
        report.totalFailures(),
        report.totalTime(),
    });

    // Each suite
    for (report.suites.items) |*suite| {
        try writer.writeAll("  <testsuite name=\"");
        try writeXmlEscaped(writer, suite.name);
        try writer.print("\" tests=\"{d}\" failures=\"{d}\" time=\"{d:.3}\">\n", .{
            suite.totalTests(),
            suite.totalFailures(),
            suite.time_seconds,
        });

        // Each test case
        for (suite.test_cases.items) |tc| {
            try writer.writeAll("    <testcase name=\"");
            try writeXmlEscaped(writer, tc.name);
            try writer.writeAll("\" classname=\"");
            try writeXmlEscaped(writer, tc.classname);
            try writer.print("\" time=\"{d:.3}\"", .{tc.time_seconds});

            if (tc.passed) {
                // Self-closing tag for passing tests
                try writer.writeAll("/>\n");
            } else {
                // Failing test with <failure> child element
                try writer.writeAll(">\n");
                try writer.writeAll("      <failure");
                if (tc.failure_message) |msg| {
                    try writer.writeAll(" message=\"");
                    try writeXmlEscaped(writer, msg);
                    try writer.writeAll("\"");
                }
                try writer.writeAll(" type=\"AssertionError\">");
                if (tc.failure_detail) |detail| {
                    try writer.writeAll("\n        ");
                    try writeXmlEscaped(writer, detail);
                    try writer.writeAll("\n      ");
                }
                try writer.writeAll("</failure>\n");
                try writer.writeAll("    </testcase>\n");
            }
        }

        try writer.writeAll("  </testsuite>\n");
    }

    try writer.writeAll("</testsuites>\n");

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "generate JUnit XML with passing tests" {
    const allocator = std.testing.allocator;

    var report = TestReport.init(allocator);
    defer report.deinit();

    var suite = TestSuite.init(allocator, "api/users.volt");
    suite.time_seconds = 0.250;

    try suite.addCase(.{
        .name = "status equals 200",
        .classname = "api/users.volt",
        .time_seconds = 0.120,
        .passed = true,
        .failure_message = null,
        .failure_detail = null,
    });
    try suite.addCase(.{
        .name = "body contains users",
        .classname = "api/users.volt",
        .time_seconds = 0.130,
        .passed = true,
        .failure_message = null,
        .failure_detail = null,
    });

    try report.addSuite(suite);

    const xml = try generateJUnitXML(allocator, &report);
    defer allocator.free(xml);

    // Verify XML declaration
    try std.testing.expect(mem.indexOf(u8, xml, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>") != null);
    // Verify testsuites root element with correct counts
    try std.testing.expect(mem.indexOf(u8, xml, "tests=\"2\"") != null);
    try std.testing.expect(mem.indexOf(u8, xml, "failures=\"0\"") != null);
    // Verify suite name
    try std.testing.expect(mem.indexOf(u8, xml, "api/users.volt") != null);
    // Verify test case names
    try std.testing.expect(mem.indexOf(u8, xml, "status equals 200") != null);
    try std.testing.expect(mem.indexOf(u8, xml, "body contains users") != null);
    // Passing tests should be self-closing (no <failure> element)
    try std.testing.expect(mem.indexOf(u8, xml, "<failure") == null);
}

test "generate JUnit XML with failures" {
    const allocator = std.testing.allocator;

    var report = TestReport.init(allocator);
    defer report.deinit();

    var suite = TestSuite.init(allocator, "api/orders.volt");
    suite.time_seconds = 0.456;

    try suite.addCase(.{
        .name = "status equals 200",
        .classname = "api/orders.volt",
        .time_seconds = 0.200,
        .passed = true,
        .failure_message = null,
        .failure_detail = null,
    });
    try suite.addCase(.{
        .name = "body contains orders",
        .classname = "api/orders.volt",
        .time_seconds = 0.256,
        .passed = false,
        .failure_message = "Expected body to contain 'orders'",
        .failure_detail = "Actual: {\"error\": \"not found\"}",
    });

    try report.addSuite(suite);

    const xml = try generateJUnitXML(allocator, &report);
    defer allocator.free(xml);

    // Verify counts reflect failure
    try std.testing.expect(mem.indexOf(u8, xml, "tests=\"2\"") != null);
    try std.testing.expect(mem.indexOf(u8, xml, "failures=\"1\"") != null);
    // Verify failure element is present
    try std.testing.expect(mem.indexOf(u8, xml, "<failure") != null);
    try std.testing.expect(mem.indexOf(u8, xml, "AssertionError") != null);
    // Verify failure message (XML-escaped)
    try std.testing.expect(mem.indexOf(u8, xml, "Expected body to contain &apos;orders&apos;") != null);
    // Verify failure detail contains escaped content
    try std.testing.expect(mem.indexOf(u8, xml, "&quot;error&quot;") != null);
}
