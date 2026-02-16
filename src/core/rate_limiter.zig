const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Token Bucket Rate Limiter ───────────────────────────────────────────
// Controls the rate of API requests to avoid overwhelming servers.
// Supports per-domain and global rate limiting.

pub const RateLimitStats = struct {
    total_requests: u64,
    total_waited_ms: f64,
    current_tokens: f64,
    max_tokens: f64,
    refill_rate: f64,
};

pub const RateLimiter = struct {
    tokens: f64,
    max_tokens: f64,
    refill_rate: f64, // tokens per second
    last_refill: i128, // nanosecond timestamp
    total_requests: u64,
    total_waited_ms: f64,

    pub fn init(requests_per_second: f64, burst: f64) RateLimiter {
        return .{
            .tokens = burst,
            .max_tokens = burst,
            .refill_rate = requests_per_second,
            .last_refill = std.time.nanoTimestamp(),
            .total_requests = 0,
            .total_waited_ms = 0,
        };
    }

    /// Acquire a token, blocking until one is available.
    pub fn acquire(self: *RateLimiter) void {
        self.refill();
        while (self.tokens < 1.0) {
            // Calculate how long to wait for one token
            const deficit = 1.0 - self.tokens;
            const wait_seconds = deficit / self.refill_rate;
            const wait_ns: u64 = @intFromFloat(wait_seconds * std.time.ns_per_s);
            if (wait_ns > 0) {
                self.total_waited_ms += wait_seconds * 1000.0;
                std.time.sleep(wait_ns);
            }
            self.refill();
        }
        self.tokens -= 1.0;
        self.total_requests += 1;
    }

    /// Try to acquire a token without blocking. Returns true if acquired.
    pub fn tryAcquire(self: *RateLimiter) bool {
        self.refill();
        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            self.total_requests += 1;
            return true;
        }
        return false;
    }

    /// Get current available tokens (after refill).
    pub fn available(self: *RateLimiter) f64 {
        self.refill();
        return self.tokens;
    }

    /// Refill tokens based on elapsed time.
    fn refill(self: *RateLimiter) void {
        const now = std.time.nanoTimestamp();
        const elapsed_ns = now - self.last_refill;
        if (elapsed_ns <= 0) return;

        const elapsed_seconds: f64 = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_s);
        const new_tokens = elapsed_seconds * self.refill_rate;
        self.tokens = @min(self.tokens + new_tokens, self.max_tokens);
        self.last_refill = now;
    }

    /// Reset the limiter to initial state.
    pub fn reset(self: *RateLimiter) void {
        self.tokens = self.max_tokens;
        self.last_refill = std.time.nanoTimestamp();
        self.total_requests = 0;
        self.total_waited_ms = 0;
    }

    /// Get stats.
    pub fn stats(self: *const RateLimiter) RateLimitStats {
        return .{
            .total_requests = self.total_requests,
            .total_waited_ms = self.total_waited_ms,
            .current_tokens = self.tokens,
            .max_tokens = self.max_tokens,
            .refill_rate = self.refill_rate,
        };
    }
};

/// Per-domain rate limiter.
/// Maintains separate token buckets for each domain.
pub const DomainRateLimiter = struct {
    limiters: std.StringHashMap(RateLimiter),
    default_rps: f64,
    default_burst: f64,
    allocator: Allocator,

    pub fn init(allocator: Allocator, default_rps: f64, default_burst: f64) DomainRateLimiter {
        return .{
            .limiters = std.StringHashMap(RateLimiter).init(allocator),
            .default_rps = default_rps,
            .default_burst = default_burst,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DomainRateLimiter) void {
        var it = self.limiters.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.limiters.deinit();
    }

    /// Acquire token for a specific domain. Creates a limiter if none exists.
    pub fn acquireForDomain(self: *DomainRateLimiter, domain: []const u8) !void {
        const entry = self.limiters.getPtr(domain);
        if (entry) |limiter| {
            limiter.acquire();
        } else {
            const owned_key = try self.allocator.dupe(u8, domain);
            var limiter = RateLimiter.init(self.default_rps, self.default_burst);
            limiter.acquire();
            try self.limiters.put(owned_key, limiter);
        }
    }

    /// Set custom rate for a domain.
    pub fn setDomainRate(self: *DomainRateLimiter, domain: []const u8, rps: f64, burst: f64) !void {
        const entry = self.limiters.getPtr(domain);
        if (entry) |limiter| {
            limiter.refill_rate = rps;
            limiter.max_tokens = burst;
            limiter.tokens = @min(limiter.tokens, burst);
        } else {
            const owned_key = try self.allocator.dupe(u8, domain);
            const limiter = RateLimiter.init(rps, burst);
            try self.limiters.put(owned_key, limiter);
        }
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "rate limiter init and tryAcquire" {
    var limiter = RateLimiter.init(10.0, 5.0);

    // Should start with 5 tokens (burst)
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    // All 5 tokens consumed
    try std.testing.expect(!limiter.tryAcquire());
    try std.testing.expectEqual(@as(u64, 5), limiter.total_requests);
}

test "rate limiter stats and reset" {
    var limiter = RateLimiter.init(10.0, 3.0);

    _ = limiter.tryAcquire();
    _ = limiter.tryAcquire();

    const s = limiter.stats();
    try std.testing.expectEqual(@as(u64, 2), s.total_requests);
    try std.testing.expectEqual(@as(f64, 3.0), s.max_tokens);
    try std.testing.expectEqual(@as(f64, 10.0), s.refill_rate);

    limiter.reset();
    try std.testing.expectEqual(@as(u64, 0), limiter.total_requests);
    try std.testing.expectEqual(@as(f64, 0), limiter.total_waited_ms);
}

test "domain rate limiter init and deinit" {
    var domain_limiter = DomainRateLimiter.init(std.testing.allocator, 10.0, 5.0);
    defer domain_limiter.deinit();

    try domain_limiter.setDomainRate("api.example.com", 20.0, 10.0);

    const entry = domain_limiter.limiters.get("api.example.com");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(f64, 20.0), entry.?.refill_rate);
    try std.testing.expectEqual(@as(f64, 10.0), entry.?.max_tokens);
}
