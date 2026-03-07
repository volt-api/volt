const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Hawk Authentication ─────────────────────────────────────────────────
//
// Implements Hawk HTTP authentication scheme:
//   https://github.com/mozilla/hawk
//
// MAC-based, time-sensitive API authentication. Each request includes
// a MAC computed over the request method, URI, host, port, and a timestamp.
//
// .volt usage:
//   auth:
//     type: hawk
//     hawk_id: dh37fgj492je
//     hawk_key: werxhqb98rpaxn39848xrunpaw3489ruxnpa98w4rxn
//     hawk_algorithm: sha256
//     hawk_ext: some-app-data (optional)

pub const HawkConfig = struct {
    id: []const u8,
    key: []const u8,
    algorithm: Algorithm = .sha256,
    ext: ?[]const u8 = null,

    pub const Algorithm = enum {
        sha256,

        pub fn toString(self: Algorithm) []const u8 {
            return switch (self) {
                .sha256 => "sha256",
            };
        }

        pub fn fromString(s: []const u8) Algorithm {
            if (mem.eql(u8, s, "sha256")) return .sha256;
            return .sha256;
        }
    };
};

/// Generate a Hawk Authorization header value for a request.
/// Caller owns the returned slice.
pub fn generateHeader(
    allocator: Allocator,
    config: HawkConfig,
    method: []const u8,
    url: []const u8,
    payload: ?[]const u8,
    content_type: ?[]const u8,
) ![]const u8 {
    const timestamp = std.time.timestamp();
    const nonce = generateNonce();

    // Parse URL
    const uri_parts = parseUrl(url);

    // Compute payload hash if payload is present
    var payload_hash: ?[]const u8 = null;
    defer if (payload_hash) |ph| allocator.free(ph);

    if (payload) |p| {
        payload_hash = try computePayloadHash(allocator, config.algorithm, p, content_type orelse "");
    }

    // Build normalized string
    const normalized = try buildNormalizedString(
        allocator,
        timestamp,
        &nonce,
        method,
        uri_parts.resource,
        uri_parts.host,
        uri_parts.port,
        payload_hash,
        config.ext,
    );
    defer allocator.free(normalized);

    // Compute MAC
    const mac = try computeMac(allocator, config.key, normalized);
    defer allocator.free(mac);

    // Build header
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.print("Hawk id=\"{s}\", ts=\"{d}\", nonce=\"{s}\", mac=\"{s}\"", .{
        config.id, timestamp, nonce, mac,
    });

    if (payload_hash) |ph| {
        try writer.print(", hash=\"{s}\"", .{ph});
    }

    if (config.ext) |ext| {
        try writer.print(", ext=\"{s}\"", .{ext});
    }

    return buf.toOwnedSlice();
}

// ── Normalized String ───────────────────────────────────────────────────

fn buildNormalizedString(
    allocator: Allocator,
    timestamp: i64,
    nonce: []const u8,
    method: []const u8,
    resource: []const u8,
    host: []const u8,
    port: u16,
    hash: ?[]const u8,
    ext: ?[]const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    // hawk.1.header\n
    try writer.writeAll("hawk.1.header\n");
    // timestamp\n
    try writer.print("{d}\n", .{timestamp});
    // nonce\n
    try writer.writeAll(nonce);
    try writer.writeByte('\n');
    // method\n
    try writer.writeAll(method);
    try writer.writeByte('\n');
    // resource\n
    try writer.writeAll(resource);
    try writer.writeByte('\n');
    // host\n
    try writer.writeAll(host);
    try writer.writeByte('\n');
    // port\n
    try writer.print("{d}\n", .{port});
    // hash\n
    if (hash) |h| {
        try writer.writeAll(h);
    }
    try writer.writeByte('\n');
    // ext\n
    if (ext) |e| {
        try writer.writeAll(e);
    }
    try writer.writeByte('\n');

    return buf.toOwnedSlice();
}

// ── Payload Hash ────────────────────────────────────────────────────────

fn computePayloadHash(
    allocator: Allocator,
    _: HawkConfig.Algorithm,
    payload: []const u8,
    content_type: []const u8,
) ![]const u8 {
    // hawk.1.payload\n<content-type>\n<payload>\n
    var hash_input = std.ArrayList(u8).init(allocator);
    defer hash_input.deinit();
    const writer = hash_input.writer();

    try writer.writeAll("hawk.1.payload\n");
    try writer.writeAll(content_type);
    try writer.writeByte('\n');
    try writer.writeAll(payload);
    try writer.writeByte('\n');

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(hash_input.items, &hash, .{});
    return try base64Encode(allocator, &hash);
}

// ── MAC Computation ─────────────────────────────────────────────────────

fn computeMac(allocator: Allocator, key: []const u8, normalized: []const u8) ![]const u8 {
    var mac: [32]u8 = undefined;
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(key);
    hmac.update(normalized);
    hmac.final(&mac);
    return try base64Encode(allocator, &mac);
}

// ── Nonce Generation ────────────────────────────────────────────────────

fn generateNonce() [8]u8 {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var nonce: [8]u8 = undefined;
    for (&nonce, 0..) |*c, i| {
        c.* = chars[@as(usize, bytes[i]) % chars.len];
    }
    return nonce;
}

// ── URL Parsing ─────────────────────────────────────────────────────────

const UriParts = struct {
    host: []const u8,
    port: u16,
    resource: []const u8,
};

fn parseUrl(url: []const u8) UriParts {
    var rest = url;
    var default_port: u16 = 443;

    // Determine scheme
    if (mem.startsWith(u8, rest, "https://")) {
        rest = rest["https://".len..];
        default_port = 443;
    } else if (mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
        default_port = 80;
    }

    // Find host:port boundary
    var host_end: usize = rest.len;
    if (mem.indexOf(u8, rest, "/")) |idx| host_end = idx;

    const host_port = rest[0..host_end];
    const resource = if (host_end < rest.len) rest[host_end..] else "/";

    // Split host and port
    var host = host_port;
    var port = default_port;

    if (mem.lastIndexOf(u8, host_port, ":")) |colon| {
        host = host_port[0..colon];
        port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch default_port;
    }

    return .{ .host = host, .port = port, .resource = resource };
}

// ── Base64 Encoding ─────────────────────────────────────────────────────

fn base64Encode(allocator: Allocator, data: []const u8) ![]const u8 {
    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = std.base64.standard.Encoder.encode(buf, data);
    return buf;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse url https" {
    const parts = parseUrl("https://api.example.com/resource/123?a=1");
    try std.testing.expectEqualStrings("api.example.com", parts.host);
    try std.testing.expectEqual(@as(u16, 443), parts.port);
    try std.testing.expectEqualStrings("/resource/123?a=1", parts.resource);
}

test "parse url http with port" {
    const parts = parseUrl("http://localhost:8080/api/test");
    try std.testing.expectEqualStrings("localhost", parts.host);
    try std.testing.expectEqual(@as(u16, 8080), parts.port);
    try std.testing.expectEqualStrings("/api/test", parts.resource);
}

test "parse url no path" {
    const parts = parseUrl("https://example.com");
    try std.testing.expectEqualStrings("example.com", parts.host);
    try std.testing.expectEqual(@as(u16, 443), parts.port);
    try std.testing.expectEqualStrings("/", parts.resource);
}

test "nonce generation length" {
    const nonce = generateNonce();
    try std.testing.expectEqual(@as(usize, 8), nonce.len);
}

test "nonce generation chars" {
    const nonce = generateNonce();
    for (nonce) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c));
    }
}

test "compute mac returns base64" {
    const mac = try computeMac(std.testing.allocator, "key123", "test data");
    defer std.testing.allocator.free(mac);
    try std.testing.expect(mac.len > 0);
    // Base64 only contains A-Z, a-z, 0-9, +, /, =
    for (mac) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '+' or c == '/' or c == '=');
    }
}

test "payload hash" {
    const hash = try computePayloadHash(
        std.testing.allocator,
        .sha256,
        "Thank you for flying Hawk",
        "text/plain",
    );
    defer std.testing.allocator.free(hash);
    try std.testing.expect(hash.len > 0);
}

test "normalized string format" {
    var nonce = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h' };
    const normalized = try buildNormalizedString(
        std.testing.allocator,
        1353832234,
        &nonce,
        "GET",
        "/resource/1?b=1&a=2",
        "example.com",
        8000,
        null,
        "some-app-data",
    );
    defer std.testing.allocator.free(normalized);

    try std.testing.expect(mem.indexOf(u8, normalized, "hawk.1.header\n") != null);
    try std.testing.expect(mem.indexOf(u8, normalized, "1353832234\n") != null);
    try std.testing.expect(mem.indexOf(u8, normalized, "abcdefgh\n") != null);
    try std.testing.expect(mem.indexOf(u8, normalized, "GET\n") != null);
    try std.testing.expect(mem.indexOf(u8, normalized, "example.com\n") != null);
    try std.testing.expect(mem.indexOf(u8, normalized, "8000\n") != null);
    try std.testing.expect(mem.indexOf(u8, normalized, "some-app-data\n") != null);
}

test "hawk config algorithm" {
    try std.testing.expectEqualStrings("sha256", HawkConfig.Algorithm.sha256.toString());
    try std.testing.expect(HawkConfig.Algorithm.fromString("sha256") == .sha256);
}

test "generate header contains required fields" {
    const config = HawkConfig{
        .id = "dh37fgj492je",
        .key = "werxhqb98rpaxn39848xrunpaw3489ruxnpa98w4rxn",
        .algorithm = .sha256,
        .ext = "some-app-data",
    };

    const header = try generateHeader(
        std.testing.allocator,
        config,
        "GET",
        "https://example.com:8000/resource/1?b=1&a=2",
        null,
        null,
    );
    defer std.testing.allocator.free(header);

    try std.testing.expect(mem.startsWith(u8, header, "Hawk id=\""));
    try std.testing.expect(mem.indexOf(u8, header, "ts=\"") != null);
    try std.testing.expect(mem.indexOf(u8, header, "nonce=\"") != null);
    try std.testing.expect(mem.indexOf(u8, header, "mac=\"") != null);
    try std.testing.expect(mem.indexOf(u8, header, "ext=\"some-app-data\"") != null);
}
