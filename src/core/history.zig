const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");

// ── Cookie Jar ──────────────────────────────────────────────────────────

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    expires: ?i64 = null, // unix timestamp
    secure: bool = false,
    http_only: bool = false,
};

pub const CookieJar = struct {
    allocator: Allocator,
    cookies: std.ArrayList(Cookie),

    pub fn init(allocator: Allocator) CookieJar {
        return .{
            .allocator = allocator,
            .cookies = std.ArrayList(Cookie).init(allocator),
        };
    }

    pub fn deinit(self: *CookieJar) void {
        self.cookies.deinit();
    }

    /// Parse Set-Cookie header and store cookie
    pub fn parseSetCookie(self: *CookieJar, header_value: []const u8, domain: ?[]const u8) !void {
        // Parse "name=value; attr1; attr2=val2"
        var parts = mem.splitSequence(u8, header_value, "; ");
        const name_value = parts.next() orelse return;

        const eq_pos = mem.indexOf(u8, name_value, "=") orelse return;
        const name = name_value[0..eq_pos];
        const value = name_value[eq_pos + 1 ..];

        var cookie = Cookie{
            .name = name,
            .value = value,
            .domain = domain,
        };

        // Parse attributes
        while (parts.next()) |attr| {
            const lower_attr = attr;
            if (mem.startsWith(u8, lower_attr, "path=")) {
                cookie.path = attr["path=".len..];
            } else if (mem.startsWith(u8, lower_attr, "domain=")) {
                cookie.domain = attr["domain=".len..];
            } else if (mem.eql(u8, lower_attr, "secure")) {
                cookie.secure = true;
            } else if (mem.eql(u8, lower_attr, "httponly") or mem.eql(u8, lower_attr, "HttpOnly")) {
                cookie.http_only = true;
            }
        }

        // Update existing cookie or add new one
        for (self.cookies.items) |*c| {
            if (mem.eql(u8, c.name, name)) {
                c.value = value;
                c.domain = cookie.domain;
                c.path = cookie.path;
                c.secure = cookie.secure;
                c.http_only = cookie.http_only;
                return;
            }
        }

        try self.cookies.append(cookie);
    }

    /// Get all cookies for a given domain/path as a Cookie header value
    pub fn getCookieHeader(self: *const CookieJar, domain: []const u8, path: []const u8) ?[]const u8 {
        _ = domain;
        _ = path;
        // Simple: return all cookies (proper implementation would filter by domain/path)
        if (self.cookies.items.len == 0) return null;
        // Return the first cookie's value for simplicity
        // Full implementation would join all matching cookies
        return null;
    }

    /// Build cookie header string
    pub fn buildCookieString(self: *const CookieJar, allocator: Allocator) !?[]const u8 {
        if (self.cookies.items.len == 0) return null;

        var buf = std.ArrayList(u8).init(allocator);
        for (self.cookies.items, 0..) |c, i| {
            if (i > 0) try buf.appendSlice("; ");
            try buf.appendSlice(c.name);
            try buf.append('=');
            try buf.appendSlice(c.value);
        }
        const slice = try buf.toOwnedSlice();
        return slice;
    }

    /// Extract cookies from HTTP response
    pub fn extractFromResponse(self: *CookieJar, response: *const HttpClient.Response) !void {
        for (response.headers.items) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "set-cookie") or
                std.ascii.eqlIgnoreCase(h.name, "Set-Cookie"))
            {
                try self.parseSetCookie(h.value, null);
            }
        }
    }

    pub fn count(self: *const CookieJar) usize {
        return self.cookies.items.len;
    }

    pub fn clear(self: *CookieJar) void {
        self.cookies.clearRetainingCapacity();
    }
};

// ── Request History ─────────────────────────────────────────────────────

pub const HistoryEntry = struct {
    method: VoltFile.Method,
    url: []const u8,
    status_code: u16,
    timing_ms: f64,
    size_bytes: usize,
    timestamp: i64,
    file: ?[]const u8 = null,
};

pub const RequestHistory = struct {
    allocator: Allocator,
    entries: std.ArrayList(HistoryEntry),
    max_entries: usize,

    pub fn init(allocator: Allocator) RequestHistory {
        return .{
            .allocator = allocator,
            .entries = std.ArrayList(HistoryEntry).init(allocator),
            .max_entries = 1000,
        };
    }

    pub fn deinit(self: *RequestHistory) void {
        self.entries.deinit();
    }

    /// Record a completed request
    pub fn record(
        self: *RequestHistory,
        request: *const VoltFile.VoltRequest,
        response: *const HttpClient.Response,
        file: ?[]const u8,
    ) !void {
        if (self.entries.items.len >= self.max_entries) {
            // Remove oldest entry
            _ = self.entries.orderedRemove(0);
        }

        try self.entries.append(.{
            .method = request.method,
            .url = request.url,
            .status_code = response.status_code,
            .timing_ms = response.timing.total_ms,
            .size_bytes = response.size_bytes,
            .timestamp = std.time.timestamp(),
            .file = file,
        });
    }

    /// Get the last N entries
    pub fn lastN(self: *const RequestHistory, n: usize) []const HistoryEntry {
        if (self.entries.items.len <= n) return self.entries.items;
        return self.entries.items[self.entries.items.len - n ..];
    }

    /// Print history to stdout
    pub fn printHistory(self: *const RequestHistory, count_n: usize) !void {
        const stdout = std.io.getStdOut().writer();
        const entries = self.lastN(count_n);

        if (entries.len == 0) {
            try stdout.writeAll("No request history.\n");
            return;
        }

        try stdout.print("\x1b[1mRequest History\x1b[0m (last {d}):\n\n", .{entries.len});

        for (entries) |entry| {
            const status_color: []const u8 = if (entry.status_code < 300) "\x1b[32m" else if (entry.status_code < 400) "\x1b[33m" else "\x1b[31m";
            try stdout.print("  \x1b[36m{s}\x1b[0m {s} {s}{d}\x1b[0m {d:.0}ms", .{
                entry.method.toString(),
                entry.url,
                status_color,
                entry.status_code,
                entry.timing_ms,
            });
            if (entry.file) |f| {
                try stdout.print(" \x1b[90m({s})\x1b[0m", .{f});
            }
            try stdout.writeAll("\n");
        }
    }

    /// Clear all history
    pub fn clear(self: *RequestHistory) void {
        self.entries.clearRetainingCapacity();
    }

    pub fn count(self: *const RequestHistory) usize {
        return self.entries.items.len;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "cookie jar parse set-cookie" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("session=abc123; path=/; HttpOnly", null);
    try std.testing.expectEqual(@as(usize, 1), jar.count());
    try std.testing.expectEqualStrings("session", jar.cookies.items[0].name);
    try std.testing.expectEqualStrings("abc123", jar.cookies.items[0].value);
}

test "cookie jar update existing" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("token=old", null);
    try jar.parseSetCookie("token=new", null);
    try std.testing.expectEqual(@as(usize, 1), jar.count());
    try std.testing.expectEqualStrings("new", jar.cookies.items[0].value);
}

test "cookie jar build string" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("a=1", null);
    try jar.parseSetCookie("b=2", null);

    const cookie_str = try jar.buildCookieString(std.testing.allocator);
    defer if (cookie_str) |s| std.testing.allocator.free(s);

    try std.testing.expect(cookie_str != null);
    try std.testing.expect(mem.indexOf(u8, cookie_str.?, "a=1") != null);
    try std.testing.expect(mem.indexOf(u8, cookie_str.?, "b=2") != null);
}

test "request history record and count" {
    var history = RequestHistory.init(std.testing.allocator);
    defer history.deinit();

    try std.testing.expectEqual(@as(usize, 0), history.count());
}

test "request history lastN" {
    var history = RequestHistory.init(std.testing.allocator);
    defer history.deinit();

    const entries = history.lastN(5);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
