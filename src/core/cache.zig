const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Response Cache ──────────────────────────────────────────────────────
// Response cache with TTL-based expiration.
// Caches HTTP responses to avoid redundant requests.
// Supports in-memory caching with configurable TTL and max entries.

pub const CacheEntry = struct {
    key: []const u8, // cache key (method:url)
    response_body: []const u8,
    status_code: u16,
    content_type: ?[]const u8,
    headers_serialized: []const u8,
    created_at: i64, // epoch seconds
    ttl_seconds: u32, // time-to-live
    hit_count: u32,

    pub fn isExpired(self: *const CacheEntry) bool {
        const now = std.time.timestamp();
        return now > self.created_at + @as(i64, @intCast(self.ttl_seconds));
    }
};

pub const CacheStats = struct {
    entries: usize,
    hits: u64,
    misses: u64,
    hit_rate: f64, // 0.0 - 1.0
    max_entries: usize,
};

pub const ResponseCache = struct {
    entries: std.StringHashMap(CacheEntry),
    allocator: Allocator,
    default_ttl: u32, // default TTL in seconds
    max_entries: usize,
    hits: u64,
    misses: u64,

    pub fn init(allocator: Allocator, default_ttl: u32, max_entries: usize) ResponseCache {
        return .{
            .entries = std.StringHashMap(CacheEntry).init(allocator),
            .allocator = allocator,
            .default_ttl = default_ttl,
            .max_entries = max_entries,
            .hits = 0,
            .misses = 0,
        };
    }

    pub fn deinit(self: *ResponseCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.response_body);
            self.allocator.free(entry.value_ptr.*.headers_serialized);
            if (entry.value_ptr.*.content_type) |ct| {
                self.allocator.free(ct);
            }
        }
        self.entries.deinit();
    }

    /// Get cached response, returns null if not found or expired.
    pub fn get(self: *ResponseCache, method: []const u8, url: []const u8) ?*CacheEntry {
        const key = makeKey(self.allocator, method, url) catch {
            self.misses += 1;
            return null;
        };
        defer self.allocator.free(key);

        const entry = self.entries.getPtr(key);
        if (entry) |e| {
            if (e.isExpired()) {
                self.misses += 1;
                return null;
            }
            e.hit_count += 1;
            self.hits += 1;
            return e;
        }

        self.misses += 1;
        return null;
    }

    /// Store response in cache.
    /// If at max_entries, evicts expired entries first, then oldest if needed.
    pub fn put(
        self: *ResponseCache,
        method: []const u8,
        url: []const u8,
        status_code: u16,
        body: []const u8,
        content_type: ?[]const u8,
        ttl: ?u32,
    ) !void {
        // Evict if at capacity
        if (self.entries.count() >= self.max_entries) {
            const evicted = self.evictExpired();
            // If no expired entries were removed, evict the oldest
            if (evicted == 0 and self.entries.count() >= self.max_entries) {
                self.evictOldest();
            }
        }

        const key = try makeKey(self.allocator, method, url);
        errdefer self.allocator.free(key);

        // Remove existing entry if present
        if (self.entries.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.response_body);
            self.allocator.free(old.value.headers_serialized);
            if (old.value.content_type) |ct| {
                self.allocator.free(ct);
            }
        }

        const owned_body = try self.allocator.dupe(u8, body);
        errdefer self.allocator.free(owned_body);

        const owned_headers = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(owned_headers);

        const owned_ct: ?[]const u8 = if (content_type) |ct|
            try self.allocator.dupe(u8, ct)
        else
            null;

        const entry = CacheEntry{
            .key = key,
            .response_body = owned_body,
            .status_code = status_code,
            .content_type = owned_ct,
            .headers_serialized = owned_headers,
            .created_at = std.time.timestamp(),
            .ttl_seconds = ttl orelse self.default_ttl,
            .hit_count = 0,
        };

        try self.entries.put(key, entry);
    }

    /// Remove entry from cache.
    pub fn invalidate(self: *ResponseCache, method: []const u8, url: []const u8) void {
        const key = makeKey(self.allocator, method, url) catch return;
        defer self.allocator.free(key);

        if (self.entries.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.response_body);
            self.allocator.free(old.value.headers_serialized);
            if (old.value.content_type) |ct| {
                self.allocator.free(ct);
            }
        }
    }

    /// Clear all entries.
    pub fn clear(self: *ResponseCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*.response_body);
            self.allocator.free(entry.value_ptr.*.headers_serialized);
            if (entry.value_ptr.*.content_type) |ct| {
                self.allocator.free(ct);
            }
        }
        self.entries.clearRetainingCapacity();
        self.hits = 0;
        self.misses = 0;
    }

    /// Remove expired entries. Returns the count of entries removed.
    pub fn evictExpired(self: *ResponseCache) usize {
        var removed: usize = 0;
        var keys_to_remove = std.ArrayList([]const u8).init(self.allocator);
        defer keys_to_remove.deinit();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.isExpired()) {
                keys_to_remove.append(entry.key_ptr.*) catch continue;
            }
        }

        for (keys_to_remove.items) |key| {
            if (self.entries.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value.response_body);
                self.allocator.free(old.value.headers_serialized);
                if (old.value.content_type) |ct| {
                    self.allocator.free(ct);
                }
                removed += 1;
            }
        }

        return removed;
    }

    /// Evict the oldest entry (smallest created_at).
    fn evictOldest(self: *ResponseCache) void {
        var oldest_key: ?[]const u8 = null;
        var oldest_time: i64 = std.math.maxInt(i64);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.created_at < oldest_time) {
                oldest_time = entry.value_ptr.*.created_at;
                oldest_key = entry.key_ptr.*;
            }
        }

        if (oldest_key) |key| {
            if (self.entries.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value.response_body);
                self.allocator.free(old.value.headers_serialized);
                if (old.value.content_type) |ct| {
                    self.allocator.free(ct);
                }
            }
        }
    }

    /// Get cache stats.
    pub fn getStats(self: *const ResponseCache) CacheStats {
        const total = self.hits + self.misses;
        return .{
            .entries = self.entries.count(),
            .hits = self.hits,
            .misses = self.misses,
            .hit_rate = if (total > 0) @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total)) else 0.0,
            .max_entries = self.max_entries,
        };
    }

    /// Generate cache key from method + url.
    fn makeKey(allocator: Allocator, method: []const u8, url: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}:{s}", .{ method, url });
    }
};

/// Format cache stats for display.
pub fn formatStats(stats_val: *const CacheStats, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("\x1b[1mCache Stats\x1b[0m\n", .{});
    try writer.print("  Entries:    {d}/{d}\n", .{ stats_val.entries, stats_val.max_entries });
    try writer.print("  Hits:       {d}\n", .{stats_val.hits});
    try writer.print("  Misses:     {d}\n", .{stats_val.misses});
    try writer.print("  Hit Rate:   {d:.1}%\n", .{stats_val.hit_rate * 100.0});

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "cache put and get" {
    var cache = ResponseCache.init(std.testing.allocator, 3600, 100);
    defer cache.deinit();

    try cache.put("GET", "https://api.example.com/users", 200, "{\"users\":[]}", "application/json", null);

    const entry = cache.get("GET", "https://api.example.com/users");
    try std.testing.expect(entry != null);
    try std.testing.expectEqual(@as(u16, 200), entry.?.status_code);
    try std.testing.expectEqualStrings("{\"users\":[]}", entry.?.response_body);
    try std.testing.expectEqualStrings("application/json", entry.?.content_type.?);
    try std.testing.expectEqual(@as(u32, 1), entry.?.hit_count);

    // Cache miss for different URL
    const miss = cache.get("GET", "https://api.example.com/other");
    try std.testing.expect(miss == null);
}

test "cache expiration check" {
    // Create a cache entry that is already expired (ttl=0)
    const expired_entry = CacheEntry{
        .key = "test",
        .response_body = "body",
        .status_code = 200,
        .content_type = null,
        .headers_serialized = "",
        .created_at = 0, // epoch start -- definitely expired
        .ttl_seconds = 1,
        .hit_count = 0,
    };
    try std.testing.expect(expired_entry.isExpired());

    // Create an entry with a far-future creation time
    const fresh_entry = CacheEntry{
        .key = "test2",
        .response_body = "body2",
        .status_code = 200,
        .content_type = null,
        .headers_serialized = "",
        .created_at = std.time.timestamp(),
        .ttl_seconds = 3600, // 1 hour TTL
        .hit_count = 0,
    };
    try std.testing.expect(!fresh_entry.isExpired());
}

test "cache stats" {
    var cache = ResponseCache.init(std.testing.allocator, 3600, 100);
    defer cache.deinit();

    // Initial stats
    var s = cache.getStats();
    try std.testing.expectEqual(@as(usize, 0), s.entries);
    try std.testing.expectEqual(@as(u64, 0), s.hits);
    try std.testing.expectEqual(@as(u64, 0), s.misses);
    try std.testing.expectEqual(@as(f64, 0.0), s.hit_rate);

    // Add an entry and access it
    try cache.put("GET", "https://example.com", 200, "ok", null, null);
    _ = cache.get("GET", "https://example.com"); // hit
    _ = cache.get("GET", "https://other.com"); // miss

    s = cache.getStats();
    try std.testing.expectEqual(@as(usize, 1), s.entries);
    try std.testing.expectEqual(@as(u64, 1), s.hits);
    try std.testing.expectEqual(@as(u64, 1), s.misses);
    try std.testing.expectEqual(@as(f64, 0.5), s.hit_rate);
}
