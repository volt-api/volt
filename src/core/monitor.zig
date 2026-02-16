const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");

// ── API Health Monitor ──────────────────────────────────────────────────
// Periodically sends requests and tracks uptime, latency, and errors.

pub const MonitorConfig = struct {
    interval_seconds: u32 = 60, // check interval
    timeout_ms: u32 = 10_000, // request timeout
    max_checks: u32 = 0, // 0 = unlimited (capped at 1000)
    expected_status: u16 = 200,
    alert_on_failure: bool = true,
    alert_threshold: u32 = 3, // consecutive failures before alert
};

pub const HealthCheck = struct {
    timestamp: i64,
    status_code: ?u16,
    latency_ms: f64,
    healthy: bool,
    error_msg: ?[]const u8,
};

pub const MonitorResult = struct {
    endpoint: []const u8,
    checks: std.ArrayList(HealthCheck),
    total_checks: u32,
    healthy_count: u32,
    unhealthy_count: u32,
    avg_latency_ms: f64,
    min_latency_ms: f64,
    max_latency_ms: f64,
    uptime_percent: f64,
    consecutive_failures: u32,

    pub fn init(allocator: Allocator) MonitorResult {
        return .{
            .endpoint = "",
            .checks = std.ArrayList(HealthCheck).init(allocator),
            .total_checks = 0,
            .healthy_count = 0,
            .unhealthy_count = 0,
            .avg_latency_ms = 0,
            .min_latency_ms = std.math.floatMax(f64),
            .max_latency_ms = 0,
            .uptime_percent = 100.0,
            .consecutive_failures = 0,
        };
    }

    pub fn deinit(self: *MonitorResult) void {
        self.checks.deinit();
    }

    /// Record a new health check and update statistics.
    pub fn recordCheck(self: *MonitorResult, check: HealthCheck) !void {
        try self.checks.append(check);
        self.total_checks += 1;

        if (check.healthy) {
            self.healthy_count += 1;
            self.consecutive_failures = 0;
        } else {
            self.unhealthy_count += 1;
            self.consecutive_failures += 1;
        }

        self.updateStats();
    }

    /// Recompute statistics from the checks list.
    pub fn updateStats(self: *MonitorResult) void {
        if (self.checks.items.len == 0) return;

        var sum: f64 = 0;
        var min_val: f64 = std.math.floatMax(f64);
        var max_val: f64 = 0;

        for (self.checks.items) |check| {
            sum += check.latency_ms;
            if (check.latency_ms < min_val) min_val = check.latency_ms;
            if (check.latency_ms > max_val) max_val = check.latency_ms;
        }

        self.avg_latency_ms = sum / @as(f64, @floatFromInt(self.checks.items.len));
        self.min_latency_ms = min_val;
        self.max_latency_ms = max_val;

        if (self.total_checks > 0) {
            self.uptime_percent = @as(f64, @floatFromInt(self.healthy_count)) / @as(f64, @floatFromInt(self.total_checks)) * 100.0;
        }
    }
};

/// Run a single health check against the endpoint.
pub fn checkHealth(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    config: *const MonitorConfig,
) !HealthCheck {
    const start_time = std.time.nanoTimestamp();
    const timestamp = std.time.timestamp();

    var response = HttpClient.execute(allocator, request, .{
        .timeout_ms = config.timeout_ms,
    }) catch {
        const elapsed = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1_000_000.0;
        return HealthCheck{
            .timestamp = timestamp,
            .status_code = null,
            .latency_ms = elapsed,
            .healthy = false,
            .error_msg = "connection error",
        };
    };
    defer response.deinit();

    const elapsed = @as(f64, @floatFromInt(std.time.nanoTimestamp() - start_time)) / 1_000_000.0;
    const healthy = response.status_code == config.expected_status;

    return HealthCheck{
        .timestamp = timestamp,
        .status_code = response.status_code,
        .latency_ms = elapsed,
        .healthy = healthy,
        .error_msg = if (!healthy) "unexpected status code" else null,
    };
}

/// Run monitoring loop (blocking).
/// Loops up to max_checks (or up to 1000 if max_checks is 0).
pub fn runMonitor(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    config: *const MonitorConfig,
) !MonitorResult {
    var result = MonitorResult.init(allocator);
    result.endpoint = request.url;

    const max_iterations: u32 = if (config.max_checks == 0) 1000 else config.max_checks;

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\x1b[1mVolt Monitor\x1b[0m - Health Checking\n", .{});
    try stdout.print("Endpoint: \x1b[36m{s}\x1b[0m\n", .{request.url});
    try stdout.print("Interval: {d}s | Expected: {d}\n\n", .{ config.interval_seconds, config.expected_status });

    var i: u32 = 0;
    while (i < max_iterations) : (i += 1) {
        const check = try checkHealth(allocator, request, config);
        try result.recordCheck(check);

        try printCheck(&check, request.url);

        // Alert on consecutive failures
        if (config.alert_on_failure and result.consecutive_failures >= config.alert_threshold) {
            try stdout.print("  \x1b[31m[ALERT] {d} consecutive failures!\x1b[0m\n", .{result.consecutive_failures});
        }

        // Sleep between checks (skip sleep on last iteration)
        if (i + 1 < max_iterations) {
            std.time.sleep(@as(u64, config.interval_seconds) * std.time.ns_per_s);
        }
    }

    return result;
}

/// Format monitor result for display.
pub fn formatResult(result: *const MonitorResult, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("\x1b[1m--- Monitor Summary ---\x1b[0m\n\n", .{});
    try writer.print("  Endpoint:         {s}\n", .{result.endpoint});
    try writer.print("  Total Checks:     {d}\n", .{result.total_checks});
    try writer.print("  Healthy:          \x1b[32m{d}\x1b[0m\n", .{result.healthy_count});
    try writer.print("  Unhealthy:        \x1b[31m{d}\x1b[0m\n", .{result.unhealthy_count});
    try writer.print("  Uptime:           {d:.1}%\n\n", .{result.uptime_percent});

    try writer.writeAll("  \x1b[1mLatency\x1b[0m\n");
    if (result.total_checks > 0) {
        try writer.print("    Avg:            {d:.1}ms\n", .{result.avg_latency_ms});
        if (result.min_latency_ms < std.math.floatMax(f64)) {
            try writer.print("    Min:            {d:.1}ms\n", .{result.min_latency_ms});
        }
        try writer.print("    Max:            {d:.1}ms\n", .{result.max_latency_ms});
    }

    if (result.consecutive_failures > 0) {
        try writer.print("\n  \x1b[31mConsecutive Failures: {d}\x1b[0m\n", .{result.consecutive_failures});
    }

    return buf.toOwnedSlice();
}

/// Print a single check result to stdout (for live monitoring).
pub fn printCheck(check: *const HealthCheck, endpoint: []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Format timestamp
    const epoch_secs: u64 = @intCast(@max(check.timestamp, 0));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_seconds = epoch_seconds.getDaySeconds();
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    if (check.healthy) {
        const status = check.status_code orelse 0;
        const status_text = HttpClient.httpStatusText(status);
        try stdout.print("  [{d:0>2}:{d:0>2}:{d:0>2}] \x1b[32m+\x1b[0m {d} {s} ({d:.0}ms) {s}\n", .{
            hour, minute, second, status, status_text, check.latency_ms, endpoint,
        });
    } else {
        const err_msg = check.error_msg orelse "error";
        if (check.status_code) |code| {
            try stdout.print("  [{d:0>2}:{d:0>2}:{d:0>2}] \x1b[31m-\x1b[0m {d} {s} ({d:.0}ms) {s}\n", .{
                hour, minute, second, code, err_msg, check.latency_ms, endpoint,
            });
        } else {
            try stdout.print("  [{d:0>2}:{d:0>2}:{d:0>2}] \x1b[31m-\x1b[0m {s} ({d:.0}ms) {s}\n", .{
                hour, minute, second, err_msg, check.latency_ms, endpoint,
            });
        }
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "monitor result init and record checks" {
    var result = MonitorResult.init(std.testing.allocator);
    defer result.deinit();

    try std.testing.expectEqual(@as(u32, 0), result.total_checks);
    try std.testing.expectEqual(@as(f64, 100.0), result.uptime_percent);

    // Record healthy check
    try result.recordCheck(.{
        .timestamp = 1000,
        .status_code = 200,
        .latency_ms = 50.0,
        .healthy = true,
        .error_msg = null,
    });

    try std.testing.expectEqual(@as(u32, 1), result.total_checks);
    try std.testing.expectEqual(@as(u32, 1), result.healthy_count);
    try std.testing.expectEqual(@as(u32, 0), result.unhealthy_count);
    try std.testing.expectEqual(@as(f64, 100.0), result.uptime_percent);
    try std.testing.expectEqual(@as(f64, 50.0), result.avg_latency_ms);

    // Record unhealthy check
    try result.recordCheck(.{
        .timestamp = 1060,
        .status_code = 500,
        .latency_ms = 150.0,
        .healthy = false,
        .error_msg = "unexpected status code",
    });

    try std.testing.expectEqual(@as(u32, 2), result.total_checks);
    try std.testing.expectEqual(@as(u32, 1), result.healthy_count);
    try std.testing.expectEqual(@as(u32, 1), result.unhealthy_count);
    try std.testing.expectEqual(@as(f64, 50.0), result.uptime_percent);
    try std.testing.expectEqual(@as(f64, 100.0), result.avg_latency_ms); // (50 + 150) / 2
    try std.testing.expectEqual(@as(f64, 50.0), result.min_latency_ms);
    try std.testing.expectEqual(@as(f64, 150.0), result.max_latency_ms);
    try std.testing.expectEqual(@as(u32, 1), result.consecutive_failures);
}

test "health check struct creation" {
    const check = HealthCheck{
        .timestamp = std.time.timestamp(),
        .status_code = 200,
        .latency_ms = 42.5,
        .healthy = true,
        .error_msg = null,
    };

    try std.testing.expect(check.healthy);
    try std.testing.expectEqual(@as(u16, 200), check.status_code.?);
    try std.testing.expectEqual(@as(f64, 42.5), check.latency_ms);
    try std.testing.expect(check.error_msg == null);
}
