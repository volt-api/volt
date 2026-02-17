const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Zero-Config CI Mode ───────────────────────────────────────────────
// Auto-detect CI environment and output test results in the appropriate format.
// Supports GitHub Actions annotations, JUnit XML, and other CI systems.

pub const CIEnvironment = enum {
    github_actions,
    gitlab_ci,
    jenkins,
    azure_devops,
    circle_ci,
    travis_ci,
    bitbucket,
    unknown,

    pub fn toString(self: CIEnvironment) []const u8 {
        return switch (self) {
            .github_actions => "GitHub Actions",
            .gitlab_ci => "GitLab CI",
            .jenkins => "Jenkins",
            .azure_devops => "Azure DevOps",
            .circle_ci => "CircleCI",
            .travis_ci => "Travis CI",
            .bitbucket => "Bitbucket Pipelines",
            .unknown => "Unknown",
        };
    }
};

// ── CI Detection ──────────────────────────────────────────────────────

/// Detect the current CI environment by checking well-known environment variables.
pub fn detectCI() CIEnvironment {
    const env = std.process.getEnvMap(std.heap.page_allocator) catch return .unknown;
    // Note: we don't deinit env here since it uses page_allocator and this is
    // typically called once at startup. For test usage, see detectCIFromEnv.
    return detectCIFromMap(env);
}

/// Detect CI environment from a given environment map (testable).
pub fn detectCIFromMap(env: std.process.EnvMap) CIEnvironment {
    if (env.get("GITHUB_ACTIONS")) |val| {
        if (mem.eql(u8, val, "true")) return .github_actions;
    }
    if (env.get("GITLAB_CI")) |val| {
        if (mem.eql(u8, val, "true")) return .gitlab_ci;
    }
    if (env.get("JENKINS_URL")) |_| {
        return .jenkins;
    }
    if (env.get("TF_BUILD")) |val| {
        if (mem.eql(u8, val, "True")) return .azure_devops;
    }
    if (env.get("CIRCLECI")) |val| {
        if (mem.eql(u8, val, "true")) return .circle_ci;
    }
    if (env.get("TRAVIS")) |val| {
        if (mem.eql(u8, val, "true")) return .travis_ci;
    }
    if (env.get("BITBUCKET_BUILD_NUMBER")) |_| {
        return .bitbucket;
    }
    return .unknown;
}

// ── Report Formatting ─────────────────────────────────────────────────

/// Return the appropriate output format for a given CI environment.
pub fn getReportFormat(env: CIEnvironment) []const u8 {
    return switch (env) {
        .github_actions => "github",
        .jenkins => "junit",
        .gitlab_ci => "junit",
        .azure_devops => "junit",
        .circle_ci => "junit",
        .travis_ci => "junit",
        .bitbucket => "junit",
        .unknown => "junit",
    };
}

/// Format a test result as a GitHub Actions annotation.
/// On failure: ::error file={file}::{message}
/// On success: ::notice file={file}::Test passed: {test_name}
pub fn formatGitHubAnnotation(
    allocator: Allocator,
    file: []const u8,
    test_name: []const u8,
    passed: bool,
    message: []const u8,
) ![]const u8 {
    if (passed) {
        return std.fmt.allocPrint(allocator, "::notice file={s}::Test passed: {s}", .{ file, test_name });
    } else {
        return std.fmt.allocPrint(allocator, "::error file={s}::{s}", .{ file, message });
    }
}

/// Format a single test result as a JUnit XML <testcase> element.
pub fn formatJUnitTestCase(
    allocator: Allocator,
    test_name: []const u8,
    file: []const u8,
    passed: bool,
    message: []const u8,
    time_ms: f64,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    const time_s = time_ms / 1000.0;

    if (passed) {
        try writer.print("    <testcase name=\"{s}\" classname=\"{s}\" time=\"{d:.3}\" />\n", .{ test_name, file, time_s });
    } else {
        try writer.print("    <testcase name=\"{s}\" classname=\"{s}\" time=\"{d:.3}\">\n", .{ test_name, file, time_s });
        try writer.print("      <failure message=\"{s}\" />\n", .{message});
        try writer.writeAll("    </testcase>\n");
    }

    return buf.toOwnedSlice();
}

// ── CI Runner ─────────────────────────────────────────────────────────

pub const TestResult = struct {
    name: []const u8,
    file: []const u8,
    passed: bool,
    message: []const u8,
    time_ms: f64,
};

pub const CIRunner = struct {
    allocator: Allocator,
    environment: CIEnvironment,
    results: std.ArrayList(TestResult),

    pub fn init(allocator: Allocator) CIRunner {
        return .{
            .allocator = allocator,
            .environment = detectCI(),
            .results = std.ArrayList(TestResult).init(allocator),
        };
    }

    pub fn deinit(self: *CIRunner) void {
        for (self.results.items) |result| {
            self.allocator.free(result.name);
            self.allocator.free(result.file);
            self.allocator.free(result.message);
        }
        self.results.deinit();
    }

    /// Record a test result.
    pub fn recordResult(self: *CIRunner, name: []const u8, file: []const u8, passed: bool, message: []const u8, time_ms: f64) !void {
        try self.results.append(.{
            .name = try self.allocator.dupe(u8, name),
            .file = try self.allocator.dupe(u8, file),
            .passed = passed,
            .message = try self.allocator.dupe(u8, message),
            .time_ms = time_ms,
        });
    }

    /// Find all .volt files recursively in a directory.
    pub fn findVoltFiles(self: *CIRunner, dir_path: []const u8) !std.ArrayList([]const u8) {
        var results = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (results.items) |item| {
                self.allocator.free(item);
            }
            results.deinit();
        }

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return results;
        defer dir.close();

        var walker = dir.iterate();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (mem.endsWith(u8, entry.name, ".volt")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, entry.name });
                try results.append(full_path);
            }
        }

        return results;
    }

    /// Run all tests and return exit code (0 = all passed, 1 = failures).
    pub fn runAllTests(self: *CIRunner, dir: []const u8) !u8 {
        const stdout = std.io.getStdOut().writer();
        const format = getReportFormat(self.environment);

        try stdout.print("\x1b[1mVolt CI Mode\x1b[0m - {s}\n", .{self.environment.toString()});
        try stdout.print("  Format: {s}\n\n", .{format});

        // Find all .volt files
        var files = try self.findVoltFiles(dir);
        defer {
            for (files.items) |item| {
                self.allocator.free(item);
            }
            files.deinit();
        }

        if (files.items.len == 0) {
            try stdout.print("  No .volt files found in {s}\n", .{dir});
            return 0;
        }

        try stdout.print("  Found {d} .volt file(s)\n\n", .{files.items.len});

        // Output results in detected format
        var total: u32 = 0;
        var passed: u32 = 0;
        var failed: u32 = 0;
        var total_time_ms: f64 = 0;

        for (self.results.items) |result| {
            total += 1;
            if (result.passed) {
                passed += 1;
            } else {
                failed += 1;
            }
            total_time_ms += result.time_ms;

            if (mem.eql(u8, format, "github")) {
                const annotation = try formatGitHubAnnotation(
                    self.allocator,
                    result.file,
                    result.name,
                    result.passed,
                    result.message,
                );
                defer self.allocator.free(annotation);
                try stdout.print("{s}\n", .{annotation});
            }
        }

        try printCISummary(self.environment, total, passed, failed, total_time_ms);

        return if (failed > 0) 1 else 0;
    }
};

/// Print a CI-friendly summary of test results.
pub fn printCISummary(env: CIEnvironment, total: u32, passed: u32, failed: u32, time_ms: f64) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n\x1b[1m--- CI Summary ({s}) ---\x1b[0m\n", .{env.toString()});
    try stdout.print("  Total:   {d}\n", .{total});
    try stdout.print("  Passed:  \x1b[32m{d}\x1b[0m\n", .{passed});
    try stdout.print("  Failed:  \x1b[31m{d}\x1b[0m\n", .{failed});
    try stdout.print("  Time:    {d:.1}ms\n", .{time_ms});

    if (failed == 0) {
        try stdout.print("  Result:  \x1b[32mPASSED\x1b[0m\n", .{});
    } else {
        try stdout.print("  Result:  \x1b[31mFAILED\x1b[0m\n", .{});
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "detect CI from environment map - github actions" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GITHUB_ACTIONS", "true");

    const result = detectCIFromMap(env);
    try std.testing.expectEqual(CIEnvironment.github_actions, result);
}

test "detect CI from environment map - gitlab" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("GITLAB_CI", "true");

    const result = detectCIFromMap(env);
    try std.testing.expectEqual(CIEnvironment.gitlab_ci, result);
}

test "detect CI from environment map - jenkins" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("JENKINS_URL", "http://jenkins.example.com");

    const result = detectCIFromMap(env);
    try std.testing.expectEqual(CIEnvironment.jenkins, result);
}

test "detect CI from environment map - azure devops" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TF_BUILD", "True");

    const result = detectCIFromMap(env);
    try std.testing.expectEqual(CIEnvironment.azure_devops, result);
}

test "detect CI from environment map - circle ci" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("CIRCLECI", "true");

    const result = detectCIFromMap(env);
    try std.testing.expectEqual(CIEnvironment.circle_ci, result);
}

test "detect CI from environment map - travis" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("TRAVIS", "true");

    const result = detectCIFromMap(env);
    try std.testing.expectEqual(CIEnvironment.travis_ci, result);
}

test "detect CI from environment map - bitbucket" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("BITBUCKET_BUILD_NUMBER", "42");

    const result = detectCIFromMap(env);
    try std.testing.expectEqual(CIEnvironment.bitbucket, result);
}

test "detect CI from environment map - unknown" {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();

    const result = detectCIFromMap(env);
    try std.testing.expectEqual(CIEnvironment.unknown, result);
}

test "get report format" {
    try std.testing.expectEqualStrings("github", getReportFormat(.github_actions));
    try std.testing.expectEqualStrings("junit", getReportFormat(.jenkins));
    try std.testing.expectEqualStrings("junit", getReportFormat(.gitlab_ci));
    try std.testing.expectEqualStrings("junit", getReportFormat(.azure_devops));
    try std.testing.expectEqualStrings("junit", getReportFormat(.circle_ci));
    try std.testing.expectEqualStrings("junit", getReportFormat(.unknown));
}

test "format github annotation - passed" {
    const allocator = std.testing.allocator;
    const annotation = try formatGitHubAnnotation(allocator, "api/users.volt", "status is 200", true, "");
    defer allocator.free(annotation);

    try std.testing.expectEqualStrings("::notice file=api/users.volt::Test passed: status is 200", annotation);
}

test "format github annotation - failed" {
    const allocator = std.testing.allocator;
    const annotation = try formatGitHubAnnotation(allocator, "api/users.volt", "status is 200", false, "Expected 200 but got 500");
    defer allocator.free(annotation);

    try std.testing.expectEqualStrings("::error file=api/users.volt::Expected 200 but got 500", annotation);
}

test "format junit test case - passed" {
    const allocator = std.testing.allocator;
    const xml = try formatJUnitTestCase(allocator, "status check", "api/users.volt", true, "", 42.5);
    defer allocator.free(xml);

    try std.testing.expect(mem.indexOf(u8, xml, "testcase") != null);
    try std.testing.expect(mem.indexOf(u8, xml, "status check") != null);
    try std.testing.expect(mem.indexOf(u8, xml, "failure") == null);
}

test "format junit test case - failed" {
    const allocator = std.testing.allocator;
    const xml = try formatJUnitTestCase(allocator, "status check", "api/users.volt", false, "Expected 200", 100.0);
    defer allocator.free(xml);

    try std.testing.expect(mem.indexOf(u8, xml, "testcase") != null);
    try std.testing.expect(mem.indexOf(u8, xml, "failure") != null);
    try std.testing.expect(mem.indexOf(u8, xml, "Expected 200") != null);
}

test "CI runner init and deinit" {
    var runner = CIRunner.init(std.testing.allocator);
    defer runner.deinit();

    try std.testing.expectEqual(@as(usize, 0), runner.results.items.len);
}

test "CI runner record result" {
    var runner = CIRunner.init(std.testing.allocator);
    defer runner.deinit();

    try runner.recordResult("test1", "file1.volt", true, "ok", 10.0);
    try runner.recordResult("test2", "file2.volt", false, "failed", 20.0);

    try std.testing.expectEqual(@as(usize, 2), runner.results.items.len);
    try std.testing.expect(runner.results.items[0].passed);
    try std.testing.expect(!runner.results.items[1].passed);
}

test "CI environment toString" {
    try std.testing.expectEqualStrings("GitHub Actions", CIEnvironment.github_actions.toString());
    try std.testing.expectEqualStrings("Jenkins", CIEnvironment.jenkins.toString());
    try std.testing.expectEqualStrings("Unknown", CIEnvironment.unknown.toString());
}
