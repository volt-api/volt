const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");

// ── Retry Engine ────────────────────────────────────────────────────────
// Retry logic with exponential backoff for HTTP requests.
// Wraps HTTP request execution with automatic retry on failure.

pub const BackoffStrategy = enum {
    constant, // same delay every time
    linear, // delay increases linearly
    exponential, // delay doubles each time

    pub fn toString(self: BackoffStrategy) []const u8 {
        return switch (self) {
            .constant => "constant",
            .linear => "linear",
            .exponential => "exponential",
        };
    }
};

pub const RetryConfig = struct {
    max_retries: u32 = 3,
    strategy: BackoffStrategy = .exponential,
    initial_delay_ms: u64 = 1000,
    max_delay_ms: u64 = 30000,
    retry_on_status: [8]u16 = .{ 500, 502, 503, 504, 408, 429, 0, 0 },
    retry_on_status_count: u8 = 6,
    retry_on_error: bool = true, // retry on connection errors
};

pub const AttemptInfo = struct {
    attempt: u32,
    status_code: ?u16,
    timing_ms: f64,
    error_msg: ?[]const u8,
    was_retry: bool,
};

pub const RetryResult = struct {
    response: ?HttpClient.Response,
    attempts: u32,
    total_time_ms: f64,
    retried: bool,
    last_error: ?[]const u8,
    attempt_history: std.ArrayList(AttemptInfo),

    pub fn init(allocator: Allocator) RetryResult {
        return .{
            .response = null,
            .attempts = 0,
            .total_time_ms = 0,
            .retried = false,
            .last_error = null,
            .attempt_history = std.ArrayList(AttemptInfo).init(allocator),
        };
    }

    pub fn deinit(self: *RetryResult) void {
        if (self.response) |*resp| {
            resp.deinit();
        }
        self.attempt_history.deinit();
    }
};

/// Execute request with retry logic.
/// Loops up to max_retries on failure or retriable status codes,
/// computing backoff delay between each attempt.
pub fn executeWithRetry(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    config: RetryConfig,
    http_config: HttpClient.ClientConfig,
) !RetryResult {
    var result = RetryResult.init(allocator);
    errdefer result.deinit();

    const start_time = std.time.nanoTimestamp();
    var attempt: u32 = 0;

    while (attempt <= config.max_retries) : (attempt += 1) {
        const attempt_start = std.time.nanoTimestamp();

        var response_opt: ?HttpClient.Response = null;
        var error_msg: ?[]const u8 = null;

        response_opt = HttpClient.execute(allocator, request, http_config) catch {
            error_msg = "connection error";

            try result.attempt_history.append(.{
                .attempt = attempt,
                .status_code = null,
                .timing_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - attempt_start)) / 1_000_000.0,
                .error_msg = error_msg,
                .was_retry = attempt > 0,
            });

            result.last_error = error_msg;
            result.attempts = attempt + 1;

            if (attempt < config.max_retries and config.retry_on_error) {
                result.retried = true;
                const delay_ms = calculateDelay(&config, attempt);
                std.time.sleep(delay_ms * std.time.ns_per_ms);
                continue;
            }
            break;
        };

        if (response_opt) |resp| {
            const attempt_time = @as(f64, @floatFromInt(std.time.nanoTimestamp() - attempt_start)) / 1_000_000.0;

            try result.attempt_history.append(.{
                .attempt = attempt,
                .status_code = resp.status_code,
                .timing_ms = attempt_time,
                .error_msg = null,
                .was_retry = attempt > 0,
            });

            result.attempts = attempt + 1;

            // Check if we should retry based on status code
            if (attempt < config.max_retries and shouldRetry(&config, resp.status_code)) {
                result.retried = true;
                result.last_error = "retriable status code";
                // Deinit this response since we are retrying
                var mutable_resp = resp;
                mutable_resp.deinit();
                const delay_ms = calculateDelay(&config, attempt);
                std.time.sleep(delay_ms * std.time.ns_per_ms);
                continue;
            }

            // Success or non-retriable status -- keep the response
            result.response = resp;
            break;
        }
    }

    const end_time = std.time.nanoTimestamp();
    result.total_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    return result;
}

/// Calculate delay in milliseconds for a given attempt number.
/// - constant: returns initial_delay_ms
/// - linear:   returns initial_delay_ms * (attempt + 1)
/// - exponential: returns initial_delay_ms * 2^attempt
/// All values are capped at max_delay_ms.
pub fn calculateDelay(config: *const RetryConfig, attempt: u32) u64 {
    const raw: u64 = switch (config.strategy) {
        .constant => config.initial_delay_ms,
        .linear => config.initial_delay_ms * (@as(u64, attempt) + 1),
        .exponential => blk: {
            const shift: u6 = @intCast(@min(attempt, 63));
            const multiplier: u64 = @as(u64, 1) << shift;
            break :blk config.initial_delay_ms *| multiplier;
        },
    };
    return @min(raw, config.max_delay_ms);
}

/// Check if a status code should trigger a retry.
pub fn shouldRetry(config: *const RetryConfig, status_code: u16) bool {
    for (0..config.retry_on_status_count) |i| {
        if (config.retry_on_status[i] == status_code) return true;
    }
    return false;
}

/// Format retry result for display.
pub fn formatResult(result: *const RetryResult, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("\x1b[1mRetry Result\x1b[0m\n", .{});
    try writer.print("  Attempts:    {d}\n", .{result.attempts});
    try writer.print("  Retried:     {}\n", .{result.retried});
    try writer.print("  Total Time:  {d:.1}ms\n\n", .{result.total_time_ms});

    if (result.attempt_history.items.len > 0) {
        try writer.writeAll("  \x1b[1mAttempt History\x1b[0m\n");
        for (result.attempt_history.items) |info| {
            const retry_marker: []const u8 = if (info.was_retry) " (retry)" else "";
            if (info.status_code) |code| {
                try writer.print("    #{d}: {d} {d:.1}ms{s}\n", .{ info.attempt + 1, code, info.timing_ms, retry_marker });
            } else {
                const err = info.error_msg orelse "unknown error";
                try writer.print("    #{d}: {s} {d:.1}ms{s}\n", .{ info.attempt + 1, err, info.timing_ms, retry_marker });
            }
        }
    }

    if (result.last_error) |err| {
        try writer.print("\n  Last Error: {s}\n", .{err});
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "calculateDelay constant strategy" {
    const config = RetryConfig{
        .strategy = .constant,
        .initial_delay_ms = 500,
        .max_delay_ms = 30000,
    };
    try std.testing.expectEqual(@as(u64, 500), calculateDelay(&config, 0));
    try std.testing.expectEqual(@as(u64, 500), calculateDelay(&config, 1));
    try std.testing.expectEqual(@as(u64, 500), calculateDelay(&config, 5));
}

test "calculateDelay linear and exponential strategies" {
    const linear_config = RetryConfig{
        .strategy = .linear,
        .initial_delay_ms = 1000,
        .max_delay_ms = 30000,
    };
    try std.testing.expectEqual(@as(u64, 1000), calculateDelay(&linear_config, 0));
    try std.testing.expectEqual(@as(u64, 2000), calculateDelay(&linear_config, 1));
    try std.testing.expectEqual(@as(u64, 3000), calculateDelay(&linear_config, 2));

    const exp_config = RetryConfig{
        .strategy = .exponential,
        .initial_delay_ms = 1000,
        .max_delay_ms = 30000,
    };
    try std.testing.expectEqual(@as(u64, 1000), calculateDelay(&exp_config, 0)); // 1000 * 2^0
    try std.testing.expectEqual(@as(u64, 2000), calculateDelay(&exp_config, 1)); // 1000 * 2^1
    try std.testing.expectEqual(@as(u64, 4000), calculateDelay(&exp_config, 2)); // 1000 * 2^2
    try std.testing.expectEqual(@as(u64, 8000), calculateDelay(&exp_config, 3)); // 1000 * 2^3
    // Capped at max_delay_ms
    try std.testing.expectEqual(@as(u64, 30000), calculateDelay(&exp_config, 10)); // would be 1024000, capped
}

test "shouldRetry checks status codes" {
    const config = RetryConfig{};
    // Default retry_on_status: 500, 502, 503, 504, 408, 429
    try std.testing.expect(shouldRetry(&config, 500));
    try std.testing.expect(shouldRetry(&config, 502));
    try std.testing.expect(shouldRetry(&config, 503));
    try std.testing.expect(shouldRetry(&config, 504));
    try std.testing.expect(shouldRetry(&config, 408));
    try std.testing.expect(shouldRetry(&config, 429));
    // Non-retriable
    try std.testing.expect(!shouldRetry(&config, 200));
    try std.testing.expect(!shouldRetry(&config, 404));
    try std.testing.expect(!shouldRetry(&config, 401));
}
