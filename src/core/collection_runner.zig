const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");
const Environment = @import("environment.zig");
const Scripting = @import("scripting.zig");
const JsonPath = @import("jsonpath.zig");
const CookieJar = @import("cookie_jar.zig");

// ── Collection Runner ───────────────────────────────────────────────────
// Runs an entire directory of .volt files in sequence, with:
// - Alphabetical ordering (use numeric prefixes: 01-login.volt, 02-profile.volt)
// - Variable extraction from responses carrying to subsequent requests
// - Pre/post script execution
// - Summary report

pub const RunResult = struct {
    allocator: Allocator,
    file: []const u8,
    method: VoltFile.Method,
    url: []const u8,
    status_code: u16,
    timing_ms: f64,
    passed: bool,
    test_results: std.ArrayList(TestResult),
    file_owned: bool,
    url_owned: bool,

    pub fn init(allocator: Allocator) RunResult {
        return .{
            .allocator = allocator,
            .file = "",
            .method = .GET,
            .url = "",
            .status_code = 0,
            .timing_ms = 0,
            .passed = true,
            .test_results = std.ArrayList(TestResult).init(allocator),
            .file_owned = false,
            .url_owned = false,
        };
    }

    pub fn deinit(self: *RunResult) void {
        if (self.file_owned) self.allocator.free(self.file);
        if (self.url_owned) self.allocator.free(self.url);

        for (self.test_results.items) |tr| {
            self.allocator.free(tr.expression);
        }
        self.test_results.deinit();
    }
};

pub const TestResult = struct {
    expression: []const u8,
    passed: bool,
};

pub const CollectionResult = struct {
    results: std.ArrayList(RunResult),
    total_time_ms: f64,
    total_requests: usize,
    successful: usize,
    failed: usize,
    total_tests: usize,
    tests_passed: usize,
    tests_failed: usize,

    pub fn init(allocator: Allocator) CollectionResult {
        return .{
            .results = std.ArrayList(RunResult).init(allocator),
            .total_time_ms = 0,
            .total_requests = 0,
            .successful = 0,
            .failed = 0,
            .total_tests = 0,
            .tests_passed = 0,
            .tests_failed = 0,
        };
    }

    pub fn deinit(self: *CollectionResult) void {
        for (self.results.items) |*r| {
            r.deinit();
        }
        self.results.deinit();
    }
};

/// Run all .volt files in a directory
pub fn runCollection(
    allocator: Allocator,
    dir_path: []const u8,
    env_mgr: *Environment.EnvManager,
    verbose: bool,
) !CollectionResult {
    var result = CollectionResult.init(allocator);
    const stdout = std.io.getStdOut().writer();

    const dir_path_norm = blk: {
        const trimmed = mem.trimRight(u8, dir_path, "/\\");
        if (trimmed.len == 0) break :blk ".";
        break :blk trimmed;
    };

    // Ensure clean slate for chaining.
    env_mgr.clearRuntimeVars();

    // Collect and sort .volt files
    var files = std.ArrayList([]const u8).init(allocator);
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit();
    }

    var dir = std.fs.cwd().openDir(dir_path_norm, .{ .iterate = true }) catch {
        return result;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".volt")) continue;
        if (mem.startsWith(u8, entry.name, "_")) continue;
        try files.append(try allocator.dupe(u8, entry.name));
    }

    // Sort alphabetically (so numeric prefixes work)
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    if (files.items.len == 0) {
        try stdout.writeAll("No .volt files found in directory.\n");
        return result;
    }

    try stdout.print("\x1b[1mRunning collection:\x1b[0m {s} ({d} requests)\n\n", .{ dir_path_norm, files.items.len });

    // Cookie jar shared across requests in the collection
    var cookie_jar = CookieJar.CookieJar.init(allocator);
    defer cookie_jar.deinit();

    // Load collection-level auth from _collection.volt if present
    var collection_auth = VoltFile.Auth{};
    const coll_config_path = std.fmt.allocPrint(allocator, "{s}/_collection.volt", .{dir_path}) catch null;
    defer if (coll_config_path) |cp| allocator.free(cp);
    if (coll_config_path) |cp| {
        const coll_file = std.fs.cwd().openFile(cp, .{}) catch null;
        if (coll_file) |cf| {
            defer cf.close();
            const coll_content = cf.readToEndAlloc(allocator, 1024 * 1024) catch null;
            if (coll_content) |cc| {
                defer allocator.free(cc);
                var coll_req = VoltFile.parse(allocator, cc) catch null;
                if (coll_req) |*cr| {
                    defer cr.deinit();
                    collection_auth = cr.auth;
                }
            }
        }
    }

    const start_time = std.time.nanoTimestamp();

    for (files.items) |filename| {
        var run_result = RunResult.init(allocator);
        run_result.file = try allocator.dupe(u8, filename);
        run_result.file_owned = true;

        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path_norm, filename }) catch continue;
        defer allocator.free(full_path);

        const file = std.fs.cwd().openFile(full_path, .{}) catch {
            run_result.passed = false;
            result.failed += 1;
            result.total_requests += 1;
            try result.results.append(run_result);
            continue;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        var request = VoltFile.parse(allocator, content) catch {
            run_result.passed = false;
            result.failed += 1;
            result.total_requests += 1;
            try result.results.append(run_result);
            continue;
        };
        defer request.deinit();

        // Inherit collection-level auth if request doesn't define its own
        if (request.auth.type == .none and collection_auth.type != .none) {
            request.auth = collection_auth;
        }

        // Script context (pre/post) participates in runtime variable propagation.
        var script_ctx = Scripting.ScriptContext.init(allocator);
        defer script_ctx.deinit();
        script_ctx.env_mgr = env_mgr;

        // Execute pre-script first so it can set runtime variables used in interpolation.
        if (request.pre_script) |pre| {
            script_ctx.request = &request;
            Scripting.executeScript(&script_ctx, pre) catch |err| {
                std.debug.print("warning: collection_runner: pre-script execution failed: {s}\n", .{@errorName(err)});
            };
        }

        // Interpolate request fields (URL, headers, auth, body) using:
        // request.variables → env_mgr.runtime_vars → active env → global → dynamic.
        var transient_allocs = std.ArrayList([]const u8).init(allocator);
        defer {
            for (transient_allocs.items) |s| allocator.free(s);
            transient_allocs.deinit();
        }

        const resolved_url = try env_mgr.interpolate(request.url, &request.variables, allocator);
        try transient_allocs.append(resolved_url);
        request.url = resolved_url;

        // Interpolate headers
        var resolved_headers = std.ArrayList(VoltFile.Header).init(allocator);
        defer resolved_headers.deinit();
        for (request.headers.items) |h| {
            const rn = try env_mgr.interpolate(h.name, &request.variables, allocator);
            const rv = try env_mgr.interpolate(h.value, &request.variables, allocator);
            try transient_allocs.append(rn);
            try transient_allocs.append(rv);
            try resolved_headers.append(.{ .name = rn, .value = rv });
        }
        request.headers.clearRetainingCapacity();
        for (resolved_headers.items) |h| {
            try request.headers.append(h);
        }

        // Interpolate auth fields
        if (request.auth.token) |t| {
            const rt = try env_mgr.interpolate(t, &request.variables, allocator);
            try transient_allocs.append(rt);
            request.auth.token = rt;
        }
        if (request.auth.username) |u| {
            const ru = try env_mgr.interpolate(u, &request.variables, allocator);
            try transient_allocs.append(ru);
            request.auth.username = ru;
        }
        if (request.auth.password) |p| {
            const rp = try env_mgr.interpolate(p, &request.variables, allocator);
            try transient_allocs.append(rp);
            request.auth.password = rp;
        }
        if (request.auth.key_name) |kn| {
            const rkn = try env_mgr.interpolate(kn, &request.variables, allocator);
            try transient_allocs.append(rkn);
            request.auth.key_name = rkn;
        }
        if (request.auth.key_value) |kv| {
            const rkv = try env_mgr.interpolate(kv, &request.variables, allocator);
            try transient_allocs.append(rkv);
            request.auth.key_value = rkv;
        }

        // Interpolate body
        if (request.body) |body| {
            const rb = try env_mgr.interpolate(body, &request.variables, allocator);
            if (request.body_owned) allocator.free(body);
            request.body = rb;
            request.body_owned = true;
        }

        // Apply cookies from jar to request (after URL resolved)
        const cookie_header = cookie_jar.getCookieHeader(request.url) catch null;
        defer if (cookie_header) |ch| allocator.free(ch);
        if (cookie_header) |ch| {
            request.headers.append(.{ .name = "Cookie", .value = ch }) catch |err| {
                std.debug.print("warning: collection_runner: cookie header append failed: {s}\n", .{@errorName(err)});
            };
        }

        run_result.method = request.method;
        run_result.url = try allocator.dupe(u8, request.url);
        run_result.url_owned = true;

        // Print progress
        try stdout.print("  \x1b[36m{s}\x1b[0m {s} ... ", .{ request.method.toString(), filename });

        // Execute request
        var response = HttpClient.execute(allocator, &request, .{}) catch {
            try stdout.writeAll("\x1b[31mFAILED\x1b[0m (connection error)\n");
            run_result.passed = false;
            result.failed += 1;
            result.total_requests += 1;
            try result.results.append(run_result);
            continue;
        };
        defer response.deinit();

        run_result.status_code = response.status_code;
        run_result.timing_ms = response.timing.total_ms;

        // Collect cookies from Set-Cookie response headers
        for (response.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "set-cookie")) {
                const domain = extractDomainFromUrl(request.url);
                cookie_jar.parseSetCookie(h.value, domain) catch |err| {
                    std.debug.print("warning: collection_runner: parseSetCookie failed: {s}\n", .{@errorName(err)});
                };
            }
        }

        // Execute post-script
        if (request.post_script) |post| {
            script_ctx.response = &response;
            Scripting.executeScript(&script_ctx, post) catch |err| {
                std.debug.print("warning: collection_runner: post-script execution failed: {s}\n", .{@errorName(err)});
            };
        }

        // Run test assertions
        var tests_passed_here: usize = 0;
        var tests_failed_here: usize = 0;

        for (request.tests.items) |t| {
            result.total_tests += 1;
            const passed = evaluateTestAssertion(&t, &response);
            if (passed) {
                tests_passed_here += 1;
                result.tests_passed += 1;
            } else {
                tests_failed_here += 1;
                result.tests_failed += 1;
                run_result.passed = false;
            }
            try run_result.test_results.append(.{
                .expression = try allocator.dupe(u8, t.field),
                .passed = passed,
            });
        }

        // Print result
        const status_color: []const u8 = if (response.status_code < 300) "\x1b[32m" else if (response.status_code < 400) "\x1b[33m" else "\x1b[31m";
        try stdout.print("{s}{d}\x1b[0m ({d:.0}ms)", .{ status_color, response.status_code, response.timing.total_ms });

        if (request.tests.items.len > 0) {
            if (tests_failed_here == 0) {
                try stdout.print(" \x1b[32m{d}/{d} tests\x1b[0m", .{ tests_passed_here, request.tests.items.len });
            } else {
                try stdout.print(" \x1b[31m{d}/{d} tests\x1b[0m", .{ tests_passed_here, request.tests.items.len });
            }
        }
        try stdout.writeAll("\n");

        // Print verbose details
        if (verbose) {
            for (request.tests.items) |t| {
                const test_passed = evaluateTestAssertion(&t, &response);
                if (test_passed) {
                    try stdout.print("    \x1b[32m✓\x1b[0m {s} {s} {s}\n", .{ t.field, t.operator, t.value });
                } else {
                    try stdout.print("    \x1b[31m✗\x1b[0m {s} {s} {s}\n", .{ t.field, t.operator, t.value });
                }
            }

            // Print script output
            if (script_ctx.output.items.len > 0) {
                try stdout.print("    \x1b[90m{s}\x1b[0m", .{script_ctx.output.items});
                script_ctx.output.clearRetainingCapacity();
            }
        }

        if (run_result.passed) {
            result.successful += 1;
        } else {
            result.failed += 1;
        }
        result.total_requests += 1;

        try result.results.append(run_result);
    }

    const end_time = std.time.nanoTimestamp();
    result.total_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    return result;
}

fn evaluateTestAssertion(t: *const VoltFile.TestAssertion, response: *const HttpClient.Response) bool {
    if (mem.eql(u8, t.field, "status")) {
        const expected = std.fmt.parseInt(u16, t.value, 10) catch return false;
        if (mem.eql(u8, t.operator, "equals") or mem.eql(u8, t.operator, "==")) {
            return response.status_code == expected;
        }
        if (mem.eql(u8, t.operator, "!=")) return response.status_code != expected;
        if (mem.eql(u8, t.operator, "<")) return response.status_code < expected;
        if (mem.eql(u8, t.operator, ">")) return response.status_code > expected;
    }

    if (mem.eql(u8, t.field, "body")) {
        const body = response.bodySlice();
        if (mem.eql(u8, t.operator, "contains")) return mem.indexOf(u8, body, t.value) != null;
        if (mem.eql(u8, t.operator, "equals")) return mem.eql(u8, body, t.value);
    }

    if (mem.startsWith(u8, t.field, "header.")) {
        const header_name = t.field["header.".len..];
        const header_value = response.getHeader(header_name) orelse return false;
        if (mem.eql(u8, t.operator, "equals") or mem.eql(u8, t.operator, "==")) return mem.eql(u8, header_value, t.value);
        if (mem.eql(u8, t.operator, "contains")) return mem.indexOf(u8, header_value, t.value) != null;
    }

    // JSONPath assertions: $.field.path operator value
    if (mem.startsWith(u8, t.field, "$.") or mem.eql(u8, t.field, "$")) {
        const body = response.bodySlice();
        const result = JsonPath.query(std.heap.page_allocator, body, t.field) catch return false;
        if (result) |val| {
            defer std.heap.page_allocator.free(val);
            if (mem.eql(u8, t.operator, "equals") or mem.eql(u8, t.operator, "==")) return mem.eql(u8, val, t.value);
            if (mem.eql(u8, t.operator, "contains")) return mem.indexOf(u8, val, t.value) != null;
            if (mem.eql(u8, t.operator, "!=")) return !mem.eql(u8, val, t.value);
            if (mem.eql(u8, t.operator, "exists")) return true;
        } else {
            if (mem.eql(u8, t.operator, "exists")) return false;
            return false;
        }
    }

    return false;
}

/// Print collection run summary
pub fn printSummary(result: *const CollectionResult) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n\x1b[1m--- Summary ---\x1b[0m\n", .{});
    try stdout.print("  Requests:   {d} total, \x1b[32m{d} ok\x1b[0m, \x1b[31m{d} failed\x1b[0m\n", .{
        result.total_requests,
        result.successful,
        result.failed,
    });
    if (result.total_tests > 0) {
        try stdout.print("  Tests:      {d} total, \x1b[32m{d} passed\x1b[0m, \x1b[31m{d} failed\x1b[0m\n", .{
            result.total_tests,
            result.tests_passed,
            result.tests_failed,
        });
    }
    try stdout.print("  Duration:   {d:.0}ms\n", .{result.total_time_ms});
}

fn extractDomainFromUrl(url: []const u8) []const u8 {
    if (mem.indexOf(u8, url, "://")) |scheme_end| {
        const after_scheme = url[scheme_end + 3 ..];
        if (mem.indexOf(u8, after_scheme, "/")) |path_start| {
            const host_port = after_scheme[0..path_start];
            if (mem.indexOf(u8, host_port, ":")) |colon| {
                return host_port[0..colon];
            }
            return host_port;
        }
        if (mem.indexOf(u8, after_scheme, ":")) |colon| {
            return after_scheme[0..colon];
        }
        return after_scheme;
    }
    return url;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "collection result init" {
    var result = CollectionResult.init(std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.total_requests);
}
