const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const HttpClient = @import("http_client.zig");
const VoltFile = @import("volt_file.zig");

// ── Load Testing (volt bench) ───────────────────────────────────────────

pub const BenchConfig = struct {
    total_requests: usize = 100,
    concurrency: usize = 10,
    timeout_ms: u32 = 30_000,
};

pub const BenchResult = struct {
    total_requests: usize = 0,
    successful: usize = 0,
    failed: usize = 0,
    total_time_ms: f64 = 0,
    min_ms: f64 = std.math.floatMax(f64),
    max_ms: f64 = 0,
    sum_ms: f64 = 0,
    timings: std.ArrayList(f64),
    status_codes: std.AutoHashMap(u16, usize),
    errors: usize = 0,

    pub fn init(allocator: Allocator) BenchResult {
        return .{
            .timings = std.ArrayList(f64).init(allocator),
            .status_codes = std.AutoHashMap(u16, usize).init(allocator),
        };
    }

    pub fn deinit(self: *BenchResult) void {
        self.timings.deinit();
        self.status_codes.deinit();
    }

    pub fn avgMs(self: *const BenchResult) f64 {
        if (self.successful == 0) return 0;
        return self.sum_ms / @as(f64, @floatFromInt(self.successful));
    }

    pub fn requestsPerSecond(self: *const BenchResult) f64 {
        if (self.total_time_ms == 0) return 0;
        return @as(f64, @floatFromInt(self.total_requests)) / (self.total_time_ms / 1000.0);
    }

    pub fn percentile(self: *BenchResult, p: f64) f64 {
        if (self.timings.items.len == 0) return 0;

        // Sort timings
        std.mem.sort(f64, self.timings.items, {}, std.sort.asc(f64));

        const idx_f = p / 100.0 * @as(f64, @floatFromInt(self.timings.items.len - 1));
        const idx: usize = @intFromFloat(idx_f);
        if (idx >= self.timings.items.len) return self.timings.items[self.timings.items.len - 1];
        return self.timings.items[idx];
    }
};

/// Thread-safe result accumulator for concurrent benchmarks.
const ThreadSafeResult = struct {
    mutex: std.Thread.Mutex,
    result: *BenchResult,
    completed: usize,
    total: usize,

    fn recordSuccess(self: *ThreadSafeResult, timing: f64, status_code: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.result.total_requests += 1;
        self.result.successful += 1;
        self.result.sum_ms += timing;
        self.result.timings.append(timing) catch {};

        if (timing < self.result.min_ms) self.result.min_ms = timing;
        if (timing > self.result.max_ms) self.result.max_ms = timing;

        const entry = self.result.status_codes.getOrPut(status_code) catch return;
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;

        self.completed += 1;
    }

    fn recordFailure(self: *ThreadSafeResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.result.failed += 1;
        self.result.errors += 1;
        self.result.total_requests += 1;
        self.completed += 1;
    }
};

/// Worker function for each concurrent thread.
fn benchWorker(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    requests_to_run: usize,
    timeout_ms: u32,
    shared: *ThreadSafeResult,
) void {
    var i: usize = 0;
    while (i < requests_to_run) : (i += 1) {
        var response = HttpClient.execute(allocator, request, .{
            .timeout_ms = timeout_ms,
        }) catch {
            shared.recordFailure();
            continue;
        };
        defer response.deinit();

        const timing = response.timing.total_ms;
        shared.recordSuccess(timing, response.status_code);
    }
}

/// Run a load test against a .volt request using concurrent threads.
pub fn runBench(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    config: BenchConfig,
) !BenchResult {
    var result = BenchResult.init(allocator);

    const stdout = std.io.getStdOut().writer();

    try stdout.print("\x1b[1mVolt Bench\x1b[0m - Load Testing\n", .{});
    try stdout.print("Target: \x1b[36m{s}\x1b[0m {s}\n", .{ request.method.toString(), request.url });
    try stdout.print("Requests: {d} | Concurrency: {d}\n\n", .{ config.total_requests, config.concurrency });

    const start_time = std.time.nanoTimestamp();

    // Use real concurrency via std.Thread
    const num_threads = @min(config.concurrency, config.total_requests);

    var shared = ThreadSafeResult{
        .mutex = .{},
        .result = &result,
        .completed = 0,
        .total = config.total_requests,
    };

    // Distribute requests across threads
    const base_per_thread = config.total_requests / num_threads;
    const remainder = config.total_requests % num_threads;

    var threads = std.ArrayList(std.Thread).init(allocator);
    defer threads.deinit();

    var t: usize = 0;
    while (t < num_threads) : (t += 1) {
        const count = base_per_thread + @as(usize, if (t < remainder) 1 else 0);
        if (count == 0) continue;

        const thread = std.Thread.spawn(.{}, benchWorker, .{
            allocator,
            request,
            count,
            config.timeout_ms,
            &shared,
        }) catch {
            // Fallback: run remaining sequentially if spawn fails
            benchWorker(allocator, request, count, config.timeout_ms, &shared);
            continue;
        };
        try threads.append(thread);
    }

    // Print progress while threads are running
    while (true) {
        shared.mutex.lock();
        const completed = shared.completed;
        shared.mutex.unlock();
        if (completed >= config.total_requests) break;
        const pct = @as(f64, @floatFromInt(completed)) / @as(f64, @floatFromInt(config.total_requests)) * 100.0;
        stdout.print("\r  Progress: {d}/{d} ({d:.0}%)", .{ completed, config.total_requests, pct }) catch {};
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    // Wait for all threads to finish
    for (threads.items) |thread| {
        thread.join();
    }

    const end_time = std.time.nanoTimestamp();
    result.total_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    try stdout.writeAll("\r                                        \r");

    return result;
}

/// Run a load test sequentially (single-threaded fallback).
pub fn runBenchSequential(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    config: BenchConfig,
) !BenchResult {
    var result = BenchResult.init(allocator);

    const start_time = std.time.nanoTimestamp();
    var completed: usize = 0;

    while (completed < config.total_requests) {
        var response = HttpClient.execute(allocator, request, .{
            .timeout_ms = config.timeout_ms,
        }) catch {
            result.failed += 1;
            result.errors += 1;
            result.total_requests += 1;
            completed += 1;
            continue;
        };
        defer response.deinit();

        result.total_requests += 1;
        result.successful += 1;

        const timing = response.timing.total_ms;
        try result.timings.append(timing);
        result.sum_ms += timing;

        if (timing < result.min_ms) result.min_ms = timing;
        if (timing > result.max_ms) result.max_ms = timing;

        const entry = try result.status_codes.getOrPut(response.status_code);
        if (!entry.found_existing) {
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;

        completed += 1;
    }

    const end_time = std.time.nanoTimestamp();
    result.total_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    return result;
}

/// Format bench results for display
pub fn formatResults(result: *BenchResult, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("\x1b[1m--- Results ---\x1b[0m\n\n");

    // Summary
    try writer.print("  Total Requests:    {d}\n", .{result.total_requests});
    try writer.print("  Successful:        \x1b[32m{d}\x1b[0m\n", .{result.successful});
    try writer.print("  Failed:            \x1b[31m{d}\x1b[0m\n", .{result.failed});
    try writer.print("  Total Time:        {d:.1}ms\n", .{result.total_time_ms});
    try writer.print("  Requests/sec:      \x1b[1m{d:.1}\x1b[0m\n", .{result.requestsPerSecond()});
    try writer.writeAll("\n");

    // Latency
    try writer.writeAll("  \x1b[1mLatency\x1b[0m\n");
    if (result.successful > 0) {
        try writer.print("    Min:             {d:.1}ms\n", .{result.min_ms});
        try writer.print("    Avg:             {d:.1}ms\n", .{result.avgMs()});
        try writer.print("    Max:             {d:.1}ms\n", .{result.max_ms});
        try writer.print("    p50:             {d:.1}ms\n", .{result.percentile(50)});
        try writer.print("    p95:             {d:.1}ms\n", .{result.percentile(95)});
        try writer.print("    p99:             {d:.1}ms\n", .{result.percentile(99)});
    }
    try writer.writeAll("\n");

    // Status code distribution
    try writer.writeAll("  \x1b[1mStatus Codes\x1b[0m\n");
    var it = result.status_codes.iterator();
    while (it.next()) |entry| {
        const color: []const u8 = if (entry.key_ptr.* < 300) "\x1b[32m" else if (entry.key_ptr.* < 400) "\x1b[33m" else "\x1b[31m";
        try writer.print("    {s}{d}\x1b[0m: {d}\n", .{ color, entry.key_ptr.*, entry.value_ptr.* });
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "bench result percentile" {
    var result = BenchResult.init(std.testing.allocator);
    defer result.deinit();

    try result.timings.append(10.0);
    try result.timings.append(20.0);
    try result.timings.append(30.0);
    try result.timings.append(40.0);
    try result.timings.append(50.0);

    try std.testing.expectEqual(@as(f64, 30.0), result.percentile(50));
}

test "bench result stats" {
    var result = BenchResult.init(std.testing.allocator);
    defer result.deinit();

    result.successful = 10;
    result.sum_ms = 1000.0;
    result.total_requests = 10;
    result.total_time_ms = 2000.0;

    try std.testing.expectEqual(@as(f64, 100.0), result.avgMs());
    try std.testing.expectEqual(@as(f64, 5.0), result.requestsPerSecond());
}

test "thread-safe result accumulator" {
    var result = BenchResult.init(std.testing.allocator);
    defer result.deinit();

    var shared = ThreadSafeResult{
        .mutex = .{},
        .result = &result,
        .completed = 0,
        .total = 3,
    };

    shared.recordSuccess(10.0, 200);
    shared.recordSuccess(20.0, 200);
    shared.recordFailure();

    try std.testing.expectEqual(@as(usize, 3), result.total_requests);
    try std.testing.expectEqual(@as(usize, 2), result.successful);
    try std.testing.expectEqual(@as(usize, 1), result.failed);
    try std.testing.expectEqual(@as(f64, 30.0), result.sum_ms);
    try std.testing.expectEqual(@as(f64, 10.0), result.min_ms);
    try std.testing.expectEqual(@as(f64, 20.0), result.max_ms);
    try std.testing.expectEqual(@as(usize, 3), shared.completed);
}
