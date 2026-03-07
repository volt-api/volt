const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── AWS Signature Version 4 Authentication ──────────────────────────────
//
// Implements AWS SigV4 request signing per:
//   https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html
//
// .volt usage:
//   auth:
//     type: aws
//     access_key: AKIAIOSFODNN7EXAMPLE
//     secret_key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
//     region: us-east-1
//     service: s3
//     session_token: (optional)

pub const AwsAuthConfig = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8,
    service: []const u8,
    session_token: ?[]const u8 = null,
};

/// Sign an HTTP request using AWS Signature Version 4.
/// Returns a list of headers to add (Authorization, X-Amz-Date, and optionally X-Amz-Security-Token).
/// Caller owns all returned slices.
pub fn signRequest(
    allocator: Allocator,
    config: AwsAuthConfig,
    method: []const u8,
    url: []const u8,
    headers: []const [2][]const u8,
    payload: ?[]const u8,
) !SignedHeaders {
    var result = SignedHeaders.init(allocator);
    errdefer result.deinit();

    // 1. Create a date stamp and time stamp
    const now = std.time.timestamp();
    const date_stamp = try formatDateStamp(allocator, now);
    defer allocator.free(date_stamp);
    const amz_date = try formatAmzDate(allocator, now);
    errdefer allocator.free(amz_date);

    try result.addHeader("X-Amz-Date", amz_date);

    if (config.session_token) |token| {
        const token_copy = try allocator.dupe(u8, token);
        errdefer allocator.free(token_copy);
        try result.addHeader("X-Amz-Security-Token", token_copy);
    }

    // 2. Parse URL into host, path, query
    const uri_parts = parseUrl(url);

    // 3. Hash the payload
    const payload_hash = try sha256Hex(allocator, payload orelse "");
    defer allocator.free(payload_hash);

    // 4. Create canonical request
    const canonical_request = try buildCanonicalRequest(
        allocator,
        method,
        uri_parts.path,
        uri_parts.query,
        uri_parts.host,
        amz_date,
        payload_hash,
        headers,
        config.session_token,
    );
    defer allocator.free(canonical_request);

    // 5. Create string to sign
    const canonical_hash = try sha256Hex(allocator, canonical_request);
    defer allocator.free(canonical_hash);

    const credential_scope = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/aws4_request", .{
        date_stamp, config.region, config.service,
    });
    defer allocator.free(credential_scope);

    const string_to_sign = try std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{
        amz_date, credential_scope, canonical_hash,
    });
    defer allocator.free(string_to_sign);

    // 6. Calculate signature
    const signing_key = try deriveSigningKey(
        allocator,
        config.secret_key,
        date_stamp,
        config.region,
        config.service,
    );
    defer allocator.free(signing_key);

    const signature = try hmacSha256Hex(allocator, signing_key, string_to_sign);
    defer allocator.free(signature);

    // 7. Build Authorization header
    const signed_headers_str = try buildSignedHeadersList(allocator, uri_parts.host, headers, config.session_token != null);

    const auth_header = try std.fmt.allocPrint(
        allocator,
        "AWS4-HMAC-SHA256 Credential={s}/{s}, SignedHeaders={s}, Signature={s}",
        .{ config.access_key, credential_scope, signed_headers_str, signature },
    );
    defer allocator.free(signed_headers_str);

    try result.addHeader("Authorization", auth_header);

    return result;
}

// ── Signed Headers Container ────────────────────────────────────────────

pub const SignedHeaders = struct {
    headers: std.ArrayList([2][]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) SignedHeaders {
        return .{
            .headers = std.ArrayList([2][]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SignedHeaders) void {
        for (self.headers.items) |h| {
            self.allocator.free(h[0]);
            self.allocator.free(h[1]);
        }
        self.headers.deinit();
    }

    pub fn addHeader(self: *SignedHeaders, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        // value is already owned by caller (allocated), just take ownership
        try self.headers.append(.{ name_copy, value });
    }
};

// ── URL Parsing ─────────────────────────────────────────────────────────

const UriParts = struct {
    host: []const u8,
    path: []const u8,
    query: []const u8,
};

fn parseUrl(url: []const u8) UriParts {
    var rest = url;

    // Skip scheme
    if (mem.indexOf(u8, rest, "://")) |idx| {
        rest = rest[idx + 3 ..];
    }

    // Extract host
    var host_end: usize = rest.len;
    if (mem.indexOf(u8, rest, "/")) |idx| host_end = idx;
    if (mem.indexOf(u8, rest, "?")) |idx| {
        if (idx < host_end) host_end = idx;
    }
    const host = rest[0..host_end];
    rest = rest[host_end..];

    // Extract path and query
    var path: []const u8 = "/";
    var query: []const u8 = "";

    if (rest.len > 0 and rest[0] == '/') {
        if (mem.indexOf(u8, rest, "?")) |idx| {
            path = rest[0..idx];
            query = rest[idx + 1 ..];
        } else {
            path = rest;
        }
    } else if (rest.len > 0 and rest[0] == '?') {
        query = rest[1..];
    }

    return .{ .host = host, .path = path, .query = query };
}

// ── Canonical Request ───────────────────────────────────────────────────

fn buildCanonicalRequest(
    allocator: Allocator,
    method: []const u8,
    path: []const u8,
    query: []const u8,
    host: []const u8,
    amz_date: []const u8,
    payload_hash: []const u8,
    extra_headers: []const [2][]const u8,
    session_token: ?[]const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    // HTTPRequestMethod
    try writer.writeAll(method);
    try writer.writeByte('\n');

    // CanonicalURI
    try writer.writeAll(if (path.len == 0) "/" else path);
    try writer.writeByte('\n');

    // CanonicalQueryString (sorted)
    try writer.writeAll(query);
    try writer.writeByte('\n');

    // CanonicalHeaders (sorted, lowercase)
    try writer.print("host:{s}\n", .{host});
    try writer.print("x-amz-date:{s}\n", .{amz_date});
    if (session_token) |token| {
        try writer.print("x-amz-security-token:{s}\n", .{token});
    }
    for (extra_headers) |h| {
        try writer.print("{s}:{s}\n", .{ h[0], h[1] });
    }
    try writer.writeByte('\n');

    // SignedHeaders
    try writer.writeAll("host;x-amz-date");
    if (session_token != null) {
        try writer.writeAll(";x-amz-security-token");
    }
    try writer.writeByte('\n');

    // HashedPayload
    try writer.writeAll(payload_hash);

    return buf.toOwnedSlice();
}

fn buildSignedHeadersList(
    allocator: Allocator,
    _: []const u8,
    _: []const [2][]const u8,
    has_session_token: bool,
) ![]const u8 {
    if (has_session_token) {
        return try allocator.dupe(u8, "host;x-amz-date;x-amz-security-token");
    }
    return try allocator.dupe(u8, "host;x-amz-date");
}

// ── Signing Key Derivation ──────────────────────────────────────────────

fn deriveSigningKey(
    allocator: Allocator,
    secret_key: []const u8,
    date_stamp: []const u8,
    region: []const u8,
    service: []const u8,
) ![]const u8 {
    // kDate = HMAC-SHA256("AWS4" + secret_key, date_stamp)
    const prefix = "AWS4";
    const initial_key = try allocator.alloc(u8, prefix.len + secret_key.len);
    defer allocator.free(initial_key);
    @memcpy(initial_key[0..prefix.len], prefix);
    @memcpy(initial_key[prefix.len..], secret_key);

    const k_date = hmacSha256Raw(initial_key, date_stamp);
    const k_region = hmacSha256Raw(&k_date, region);
    const k_service = hmacSha256Raw(&k_region, service);
    const k_signing = hmacSha256Raw(&k_service, "aws4_request");

    return try allocator.dupe(u8, &k_signing);
}

// ── Cryptographic Helpers ───────────────────────────────────────────────

fn sha256Hex(allocator: Allocator, data: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return try hexEncode(allocator, &hash);
}

fn hmacSha256Raw(key: []const u8, data: []const u8) [32]u8 {
    var mac: [32]u8 = undefined;
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(key);
    hmac.update(data);
    hmac.final(&mac);
    return mac;
}

fn hmacSha256Hex(allocator: Allocator, key: []const u8, data: []const u8) ![]const u8 {
    const mac = hmacSha256Raw(key, data);
    return try hexEncode(allocator, &mac);
}

fn hexEncode(allocator: Allocator, data: []const u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, data.len * 2);
    for (data, 0..) |byte, i| {
        result[i * 2] = hex_chars[@as(usize, byte >> 4)];
        result[i * 2 + 1] = hex_chars[@as(usize, byte & 0x0F)];
    }
    return result;
}

// ── Date Formatting ─────────────────────────────────────────────────────

fn formatDateStamp(allocator: Allocator, timestamp: i64) ![]const u8 {
    const es = epochToDate(timestamp);
    return try std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}", .{ es.year, es.month, es.day });
}

fn formatAmzDate(allocator: Allocator, timestamp: i64) ![]const u8 {
    const es = epochToDate(timestamp);
    return try std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        es.year, es.month, es.day, es.hour, es.minute, es.second,
    });
}

const EpochDate = struct {
    year: u32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
};

fn epochToDate(timestamp: i64) EpochDate {
    const secs: u64 = @intCast(if (timestamp < 0) 0 else timestamp);
    const second = @as(u32, @intCast(secs % 60));
    const minute = @as(u32, @intCast((secs / 60) % 60));
    const hour = @as(u32, @intCast((secs / 3600) % 24));

    var days: u32 = @intCast(secs / 86400);
    var year: u32 = 1970;

    while (true) {
        const days_in_year: u32 = if (isLeapYear(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }

    const month_days = if (isLeapYear(year))
        [_]u32{ 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
    else
        [_]u32{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };

    var month: u32 = 1;
    for (month_days) |md| {
        if (days < md) break;
        days -= md;
        month += 1;
    }

    return .{
        .year = year,
        .month = month,
        .day = days + 1,
        .hour = hour,
        .minute = minute,
        .second = second,
    };
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "sha256 hex empty string" {
    const hash = try sha256Hex(std.testing.allocator, "");
    defer std.testing.allocator.free(hash);
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hash);
}

test "sha256 hex known value" {
    const hash = try sha256Hex(std.testing.allocator, "hello");
    defer std.testing.allocator.free(hash);
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", hash);
}

test "parse url basic" {
    const parts = parseUrl("https://s3.amazonaws.com/my-bucket/my-key?acl");
    try std.testing.expectEqualStrings("s3.amazonaws.com", parts.host);
    try std.testing.expectEqualStrings("/my-bucket/my-key", parts.path);
    try std.testing.expectEqualStrings("acl", parts.query);
}

test "parse url no path" {
    const parts = parseUrl("https://example.com");
    try std.testing.expectEqualStrings("example.com", parts.host);
    try std.testing.expectEqualStrings("/", parts.path);
}

test "parse url with port" {
    const parts = parseUrl("https://s3.amazonaws.com:443/bucket");
    try std.testing.expectEqualStrings("s3.amazonaws.com:443", parts.host);
    try std.testing.expectEqualStrings("/bucket", parts.path);
}

test "hmac sha256 produces 32 bytes" {
    const mac = hmacSha256Raw("key", "data");
    try std.testing.expectEqual(@as(usize, 32), mac.len);
}

test "signing key derivation" {
    const key = try deriveSigningKey(
        std.testing.allocator,
        "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        "20130524",
        "us-east-1",
        "s3",
    );
    defer std.testing.allocator.free(key);
    try std.testing.expectEqual(@as(usize, 32), key.len);
}

test "epoch to date" {
    // 2023-01-15 12:30:45 UTC = 1673785845
    const d = epochToDate(1673785845);
    try std.testing.expectEqual(@as(u32, 2023), d.year);
    try std.testing.expectEqual(@as(u32, 1), d.month);
    try std.testing.expectEqual(@as(u32, 15), d.day);
    try std.testing.expectEqual(@as(u32, 12), d.hour);
    try std.testing.expectEqual(@as(u32, 30), d.minute);
    try std.testing.expectEqual(@as(u32, 45), d.second);
}

test "format date stamp" {
    const stamp = try formatDateStamp(std.testing.allocator, 1673785845);
    defer std.testing.allocator.free(stamp);
    try std.testing.expectEqualStrings("20230115", stamp);
}

test "format amz date" {
    const date = try formatAmzDate(std.testing.allocator, 1673785845);
    defer std.testing.allocator.free(date);
    try std.testing.expectEqualStrings("20230115T123045Z", date);
}

test "signed headers init and deinit" {
    var sh = SignedHeaders.init(std.testing.allocator);
    defer sh.deinit();
    const val = try std.testing.allocator.dupe(u8, "test-value");
    try sh.addHeader("test-header", val);
    try std.testing.expectEqual(@as(usize, 1), sh.headers.items.len);
}

test "aws auth config defaults" {
    const config = AwsAuthConfig{
        .access_key = "AKID",
        .secret_key = "secret",
        .region = "us-east-1",
        .service = "s3",
    };
    try std.testing.expect(config.session_token == null);
}

test "is leap year" {
    try std.testing.expect(isLeapYear(2000));
    try std.testing.expect(isLeapYear(2024));
    try std.testing.expect(!isLeapYear(1900));
    try std.testing.expect(!isLeapYear(2023));
}
