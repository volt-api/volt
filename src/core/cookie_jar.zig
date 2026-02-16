const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Cookie Jar ──────────────────────────────────────────────────────────
// Persists cookies across requests in a collection run.
// Parses Set-Cookie response headers, stores cookies with domain/path/expiry
// attributes, and generates Cookie header values for outgoing requests.

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: []const u8,
    path: []const u8,
    expires: ?i64, // epoch seconds, null = session cookie
    secure: bool,
    http_only: bool,
};

pub const CookieJar = struct {
    cookies: std.ArrayList(Cookie),
    allocator: Allocator,

    pub fn init(allocator: Allocator) CookieJar {
        return .{
            .cookies = std.ArrayList(Cookie).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *CookieJar) void {
        for (self.cookies.items) |cookie| {
            self.allocator.free(cookie.name);
            self.allocator.free(cookie.value);
            self.allocator.free(cookie.domain);
            self.allocator.free(cookie.path);
        }
        self.cookies.deinit();
    }

    /// Parse a Set-Cookie header value and store the cookie.
    /// Format: name=value; Domain=...; Path=...; Expires=...; Secure; HttpOnly
    pub fn parseSetCookie(self: *CookieJar, header_value: []const u8, request_domain: []const u8) !void {
        var cookie_name: ?[]const u8 = null;
        var cookie_value: ?[]const u8 = null;
        var domain: ?[]const u8 = null;
        var path: ?[]const u8 = null;
        var expires: ?i64 = null;
        var secure = false;
        var http_only = false;

        var parts = mem.splitSequence(u8, header_value, ";");
        var first = true;
        while (parts.next()) |raw_part| {
            const part = mem.trim(u8, raw_part, " \t");
            if (part.len == 0) continue;

            if (first) {
                first = false;
                // First segment is name=value
                if (mem.indexOf(u8, part, "=")) |eq_pos| {
                    cookie_name = part[0..eq_pos];
                    cookie_value = part[eq_pos + 1 ..];
                } else {
                    // Malformed — skip
                    return;
                }
                continue;
            }

            // Attribute parts
            const lower_part = part;
            if (mem.indexOf(u8, lower_part, "=")) |eq_pos| {
                const attr_name = mem.trim(u8, lower_part[0..eq_pos], " \t");
                const attr_value = mem.trim(u8, lower_part[eq_pos + 1 ..], " \t");

                if (asciiEqlIgnoreCase(attr_name, "Domain")) {
                    domain = attr_value;
                } else if (asciiEqlIgnoreCase(attr_name, "Path")) {
                    path = attr_value;
                } else if (asciiEqlIgnoreCase(attr_name, "Max-Age")) {
                    // Max-Age in seconds from now
                    const seconds = std.fmt.parseInt(i64, attr_value, 10) catch null;
                    if (seconds) |s| {
                        expires = std.time.timestamp() + s;
                    }
                }
                // Expires header parsing is complex (date formats vary);
                // we support Max-Age for expiry control.
            } else {
                if (asciiEqlIgnoreCase(part, "Secure")) {
                    secure = true;
                } else if (asciiEqlIgnoreCase(part, "HttpOnly")) {
                    http_only = true;
                }
            }
        }

        const name_str = cookie_name orelse return;
        const value_str = cookie_value orelse return;

        // Remove any existing cookie with the same name and domain
        const cookie_domain = domain orelse request_domain;
        var i: usize = 0;
        while (i < self.cookies.items.len) {
            const existing = self.cookies.items[i];
            if (mem.eql(u8, existing.name, name_str) and mem.eql(u8, existing.domain, cookie_domain)) {
                self.allocator.free(existing.name);
                self.allocator.free(existing.value);
                self.allocator.free(existing.domain);
                self.allocator.free(existing.path);
                _ = self.cookies.orderedRemove(i);
                continue;
            }
            i += 1;
        }

        const owned_name = try self.allocator.dupe(u8, name_str);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value_str);
        errdefer self.allocator.free(owned_value);
        const owned_domain = try self.allocator.dupe(u8, cookie_domain);
        errdefer self.allocator.free(owned_domain);
        const owned_path = try self.allocator.dupe(u8, path orelse "/");
        errdefer self.allocator.free(owned_path);

        try self.cookies.append(.{
            .name = owned_name,
            .value = owned_value,
            .domain = owned_domain,
            .path = owned_path,
            .expires = expires,
            .secure = secure,
            .http_only = http_only,
        });
    }

    /// Generate a Cookie header value for a given URL.
    /// Returns all matching (non-expired) cookies as "name1=value1; name2=value2",
    /// or null if no cookies match.
    pub fn getCookieHeader(self: *const CookieJar, url: []const u8) !?[]const u8 {
        const url_domain = extractDomain(url) orelse return null;
        const url_path = extractPath(url);
        const now = std.time.timestamp();

        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        var first = true;
        for (self.cookies.items) |cookie| {
            // Check expiry
            if (cookie.expires) |exp| {
                if (now >= exp) continue;
            }

            // Check domain match: cookie domain must match or be a suffix of url domain
            if (!domainMatches(url_domain, cookie.domain)) continue;

            // Check path match: url path must start with cookie path
            if (!mem.startsWith(u8, url_path, cookie.path)) continue;

            if (!first) {
                try buf.appendSlice("; ");
            }
            try buf.appendSlice(cookie.name);
            try buf.append('=');
            try buf.appendSlice(cookie.value);
            first = false;
        }

        if (buf.items.len == 0) {
            buf.deinit();
            return null;
        }

        const slice = try buf.toOwnedSlice();
        return slice;
    }

    /// Clear all cookies.
    pub fn clear(self: *CookieJar) void {
        for (self.cookies.items) |cookie| {
            self.allocator.free(cookie.name);
            self.allocator.free(cookie.value);
            self.allocator.free(cookie.domain);
            self.allocator.free(cookie.path);
        }
        self.cookies.clearRetainingCapacity();
    }

    /// Clear all cookies for a specific domain.
    pub fn clearDomain(self: *CookieJar, domain: []const u8) void {
        var i: usize = 0;
        while (i < self.cookies.items.len) {
            const cookie = self.cookies.items[i];
            if (mem.eql(u8, cookie.domain, domain)) {
                self.allocator.free(cookie.name);
                self.allocator.free(cookie.value);
                self.allocator.free(cookie.domain);
                self.allocator.free(cookie.path);
                _ = self.cookies.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// Return the number of cookies currently stored.
    pub fn count(self: *const CookieJar) usize {
        return self.cookies.items.len;
    }
};

// ── URL Helpers ─────────────────────────────────────────────────────────

/// Extract the domain (host) portion from a URL.
/// E.g. "https://api.example.com/path" -> "api.example.com"
pub fn extractDomain(url: []const u8) ?[]const u8 {
    // Skip scheme
    var start: usize = 0;
    if (mem.indexOf(u8, url, "://")) |scheme_end| {
        start = scheme_end + 3;
    }
    if (start >= url.len) return null;

    // Find end of host (before / or : or end)
    var end = start;
    while (end < url.len and url[end] != '/' and url[end] != ':' and url[end] != '?') {
        end += 1;
    }

    if (end == start) return null;
    return url[start..end];
}

/// Extract the path portion from a URL.
/// E.g. "https://example.com/api/v1" -> "/api/v1"
/// Returns "/" if no path is present.
pub fn extractPath(url: []const u8) []const u8 {
    // Skip scheme
    var start: usize = 0;
    if (mem.indexOf(u8, url, "://")) |scheme_end| {
        start = scheme_end + 3;
    }

    // Find the first / after the host
    if (mem.indexOfPos(u8, url, start, "/")) |slash_pos| {
        // Trim query string
        if (mem.indexOfPos(u8, url, slash_pos, "?")) |q_pos| {
            return url[slash_pos..q_pos];
        }
        return url[slash_pos..];
    }

    return "/";
}

// ── Internal Helpers ────────────────────────────────────────────────────

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
}

fn domainMatches(url_domain: []const u8, cookie_domain: []const u8) bool {
    // Exact match
    if (mem.eql(u8, url_domain, cookie_domain)) return true;

    // Cookie domain can be a suffix preceded by a dot
    // e.g., cookie domain ".example.com" matches "api.example.com"
    if (mem.startsWith(u8, cookie_domain, ".")) {
        const suffix = cookie_domain[1..];
        if (mem.eql(u8, url_domain, suffix)) return true;
        if (mem.endsWith(u8, url_domain, cookie_domain)) return true;
    }

    // url_domain "api.example.com" matches cookie_domain "example.com"
    if (url_domain.len > cookie_domain.len) {
        const offset = url_domain.len - cookie_domain.len;
        if (url_domain[offset - 1] == '.' and mem.eql(u8, url_domain[offset..], cookie_domain)) {
            return true;
        }
    }

    return false;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse Set-Cookie and retrieve" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("session=abc123; Path=/; HttpOnly", "example.com");
    try jar.parseSetCookie("theme=dark; Path=/", "example.com");

    try std.testing.expectEqual(@as(usize, 2), jar.count());

    const header = try jar.getCookieHeader("https://example.com/api/data");
    try std.testing.expect(header != null);
    defer std.testing.allocator.free(header.?);

    // Should contain both cookies
    try std.testing.expect(mem.indexOf(u8, header.?, "session=abc123") != null);
    try std.testing.expect(mem.indexOf(u8, header.?, "theme=dark") != null);
}

test "domain matching" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("token=xyz; Domain=example.com; Path=/", "api.example.com");

    // Should match a subdomain request
    const header = try jar.getCookieHeader("https://api.example.com/data");
    try std.testing.expect(header != null);
    defer std.testing.allocator.free(header.?);
    try std.testing.expect(mem.indexOf(u8, header.?, "token=xyz") != null);

    // Should NOT match a different domain
    const other = try jar.getCookieHeader("https://other.com/data");
    try std.testing.expect(other == null);
}

test "cookie expiry" {
    var jar = CookieJar.init(std.testing.allocator);
    defer jar.deinit();

    // Add a cookie that has already expired (Max-Age=0)
    try jar.parseSetCookie("old=stale; Max-Age=0; Path=/", "example.com");

    try std.testing.expectEqual(@as(usize, 1), jar.count());

    // getCookieHeader should skip expired cookies
    const header = try jar.getCookieHeader("https://example.com/");
    try std.testing.expect(header == null);
}
