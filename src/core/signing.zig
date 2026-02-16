const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── Request Signing ────────────────────────────────────────────────────
// Signs API requests with HMAC-SHA256 or custom signing schemes.
// Supports:
//   - HMAC-SHA256 signing
//   - Custom header signing (X-Signature style)
//   - Timestamp-based signatures
//   - AWS SigV4-like canonical request signing

pub const SigningMethod = enum {
    hmac_sha256,
    aws_sigv4,
    custom,

    pub fn fromString(s: []const u8) SigningMethod {
        if (mem.eql(u8, s, "hmac_sha256") or mem.eql(u8, s, "hmac-sha256") or mem.eql(u8, s, "hmac")) return .hmac_sha256;
        if (mem.eql(u8, s, "aws_sigv4") or mem.eql(u8, s, "aws-sigv4") or mem.eql(u8, s, "sigv4")) return .aws_sigv4;
        if (mem.eql(u8, s, "custom")) return .custom;
        return .hmac_sha256;
    }

    pub fn toString(self: SigningMethod) []const u8 {
        return switch (self) {
            .hmac_sha256 => "hmac_sha256",
            .aws_sigv4 => "aws_sigv4",
            .custom => "custom",
        };
    }
};

pub const SigningConfig = struct {
    method: SigningMethod = .hmac_sha256,
    secret_key: []const u8 = "",
    access_key: []const u8 = "",
    region: []const u8 = "",
    service: []const u8 = "",
    header_name: []const u8 = "X-Signature",
    include_timestamp: bool = true,
    timestamp_header: []const u8 = "X-Timestamp",
};

// ── Core Signing Functions ─────────────────────────────────────────────

/// Compute HMAC-SHA256 of a message with the given key.
/// Returns the 32-byte digest.
pub fn hmacSha256(key: []const u8, message: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
    HmacSha256.create(&out, message, key);
    return out;
}

/// Convert a byte array to a lowercase hex string.
pub fn hexEncode(allocator: Allocator, bytes: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, bytes.len * 2);
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        buf[i * 2] = hex_chars[@as(usize, byte >> 4)];
        buf[i * 2 + 1] = hex_chars[@as(usize, byte & 0x0F)];
    }
    return buf;
}

/// Get current timestamp formatted as ISO 8601 (20060102T150405Z).
pub fn getTimestamp() [16]u8 {
    const epoch_seconds: u64 = @intCast(std.time.timestamp());
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();

    var buf: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch {};

    return buf;
}

/// Build a canonical request string for signing.
/// Format:
///   METHOD\n
///   URL\n
///   SORTED_HEADERS\n
///   BODY_HASH
pub fn buildCanonicalRequest(allocator: Allocator, request: *const VoltFile.VoltRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Method
    try writer.writeAll(request.method.toString());
    try writer.writeAll("\n");

    // URL
    try writer.writeAll(request.url);
    try writer.writeAll("\n");

    // Headers: collect and sort by name
    // Use a simple insertion-sort approach via an index list
    var indices = std.ArrayList(usize).init(allocator);
    defer indices.deinit();

    for (0..request.headers.items.len) |i| {
        // Insert sorted
        var pos: usize = 0;
        while (pos < indices.items.len) {
            const existing_idx = indices.items[pos];
            if (mem.order(u8, request.headers.items[i].name, request.headers.items[existing_idx].name) == .lt) {
                break;
            }
            pos += 1;
        }
        try indices.insert(pos, i);
    }

    for (indices.items) |idx| {
        const h = request.headers.items[idx];
        try writer.print("{s}:{s}\n", .{ h.name, h.value });
    }

    // Body hash (SHA-256 of the body, or of empty string)
    const body_data = request.body orelse "";
    var body_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body_data, &body_hash, .{});
    const body_hash_hex = try hexEncode(allocator, &body_hash);
    defer allocator.free(body_hash_hex);
    try writer.writeAll(body_hash_hex);

    return buf.toOwnedSlice();
}

/// Sign a request by computing HMAC-SHA256 of the canonical representation
/// and adding the signature as a header.
/// Note: allocated header values (signature, timestamp) are owned by the allocator.
/// The caller must ensure the allocator outlives the request's usage.
pub fn signRequest(allocator: Allocator, request: *VoltFile.VoltRequest, config: *const SigningConfig) !void {
    // Add timestamp header if requested
    if (config.include_timestamp) {
        const ts = getTimestamp();
        const ts_owned = try allocator.dupe(u8, &ts);
        try request.addHeader(config.timestamp_header, ts_owned);
    }

    // Build canonical request
    const canonical = try buildCanonicalRequest(allocator, request);
    defer allocator.free(canonical);

    switch (config.method) {
        .hmac_sha256 => {
            // Simple HMAC-SHA256: sign the canonical request with the secret key
            const signature = hmacSha256(config.secret_key, canonical);
            const sig_hex = try hexEncode(allocator, &signature);
            // sig_hex is owned by allocator; must outlive the request
            try request.addHeader(config.header_name, sig_hex);
        },
        .aws_sigv4 => {
            // AWS SigV4-like: use a derived signing key
            // key = HMAC(HMAC(HMAC(HMAC("AWS4" + secret, date), region), service), "aws4_request")
            const ts = getTimestamp();
            const date_stamp = ts[0..8]; // YYYYMMDD

            var date_buf: [64]u8 = undefined;
            const date_key_msg = std.fmt.bufPrint(&date_buf, "AWS4{s}", .{config.secret_key}) catch config.secret_key;
            const date_key = hmacSha256(date_key_msg, date_stamp);
            const region_key = hmacSha256(&date_key, config.region);
            const service_key = hmacSha256(&region_key, config.service);
            const signing_key = hmacSha256(&service_key, "aws4_request");

            // Sign the canonical request hash
            var canonical_hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(canonical, &canonical_hash, .{});
            const canonical_hash_hex = try hexEncode(allocator, &canonical_hash);
            defer allocator.free(canonical_hash_hex);

            // Build string to sign
            const string_to_sign = try std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256\n{s}\n{s}/{s}/{s}/aws4_request\n{s}", .{
                &ts,
                date_stamp,
                config.region,
                config.service,
                canonical_hash_hex,
            });
            defer allocator.free(string_to_sign);

            const signature = hmacSha256(&signing_key, string_to_sign);
            const sig_hex = try hexEncode(allocator, &signature);
            defer allocator.free(sig_hex);

            // Build Authorization header -- allocator-owned, must outlive request
            const auth_header = try std.fmt.allocPrint(allocator, "AWS4-HMAC-SHA256 Credential={s}/{s}/{s}/{s}/aws4_request, Signature={s}", .{
                config.access_key,
                date_stamp,
                config.region,
                config.service,
                sig_hex,
            });
            try request.addHeader("Authorization", auth_header);
        },
        .custom => {
            // Custom: just sign with HMAC-SHA256 and use the configured header
            const signature = hmacSha256(config.secret_key, canonical);
            const sig_hex = try hexEncode(allocator, &signature);
            // sig_hex is owned by allocator; must outlive the request
            try request.addHeader(config.header_name, sig_hex);
        },
    }
}

// ── Config Parsing ─────────────────────────────────────────────────────

/// Parse signing config from a .volt file section:
/// ```
/// signing:
///   method: hmac_sha256
///   secret_key: my-secret
///   include_timestamp: true
///   header_name: X-Signature
/// ```
pub fn parseSigningConfig(content: []const u8) SigningConfig {
    var config = SigningConfig{};

    var in_signing = false;
    var lines = mem.splitSequence(u8, content, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trimRight(u8, raw_line, "\r");
        const trimmed = mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (mem.eql(u8, trimmed, "signing:")) {
            in_signing = true;
            continue;
        }

        // Stop if we hit another top-level section
        if (in_signing and trimmed.len > 0 and trimmed[0] != ' ' and trimmed[trimmed.len - 1] == ':' and !mem.startsWith(u8, trimmed, "method:") and !mem.startsWith(u8, trimmed, "secret_key:") and !mem.startsWith(u8, trimmed, "access_key:") and !mem.startsWith(u8, trimmed, "region:") and !mem.startsWith(u8, trimmed, "service:") and !mem.startsWith(u8, trimmed, "header_name:") and !mem.startsWith(u8, trimmed, "include_timestamp:") and !mem.startsWith(u8, trimmed, "timestamp_header:")) {
            in_signing = false;
        }

        if (!in_signing) continue;

        if (mem.startsWith(u8, trimmed, "method:")) {
            const val = mem.trim(u8, trimmed["method:".len..], " \t");
            config.method = SigningMethod.fromString(val);
        } else if (mem.startsWith(u8, trimmed, "secret_key:")) {
            const val = mem.trim(u8, trimmed["secret_key:".len..], " \t");
            config.secret_key = val;
        } else if (mem.startsWith(u8, trimmed, "access_key:")) {
            const val = mem.trim(u8, trimmed["access_key:".len..], " \t");
            config.access_key = val;
        } else if (mem.startsWith(u8, trimmed, "region:")) {
            const val = mem.trim(u8, trimmed["region:".len..], " \t");
            config.region = val;
        } else if (mem.startsWith(u8, trimmed, "service:")) {
            const val = mem.trim(u8, trimmed["service:".len..], " \t");
            config.service = val;
        } else if (mem.startsWith(u8, trimmed, "header_name:")) {
            const val = mem.trim(u8, trimmed["header_name:".len..], " \t");
            config.header_name = val;
        } else if (mem.startsWith(u8, trimmed, "include_timestamp:")) {
            const val = mem.trim(u8, trimmed["include_timestamp:".len..], " \t");
            config.include_timestamp = mem.eql(u8, val, "true");
        } else if (mem.startsWith(u8, trimmed, "timestamp_header:")) {
            const val = mem.trim(u8, trimmed["timestamp_header:".len..], " \t");
            config.timestamp_header = val;
        }
    }

    return config;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "hmac sha256 computation" {
    const key = "secret-key";
    const message = "hello world";
    const result = hmacSha256(key, message);

    // Verify it produces a 32-byte result
    try std.testing.expectEqual(@as(usize, 32), result.len);

    // Verify determinism: same input produces same output
    const result2 = hmacSha256(key, message);
    try std.testing.expectEqualSlices(u8, &result, &result2);

    // Verify different key produces different output
    const result3 = hmacSha256("different-key", message);
    try std.testing.expect(!mem.eql(u8, &result, &result3));
}

test "hex encode" {
    const bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const hex = try hexEncode(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(hex);

    try std.testing.expectEqualStrings("deadbeef", hex);
}

test "hex encode all zeros" {
    const bytes = [_]u8{ 0x00, 0x00, 0x01, 0xFF };
    const hex = try hexEncode(std.testing.allocator, &bytes);
    defer std.testing.allocator.free(hex);

    try std.testing.expectEqualStrings("000001ff", hex);
}

test "build canonical request" {
    var request = VoltFile.VoltRequest.init(std.testing.allocator);
    defer request.deinit();

    request.method = .POST;
    request.url = "https://api.example.com/data";
    try request.addHeader("Content-Type", "application/json");
    try request.addHeader("Accept", "application/json");
    request.body = "{\"key\": \"value\"}";

    const canonical = try buildCanonicalRequest(std.testing.allocator, &request);
    defer std.testing.allocator.free(canonical);

    // Verify structure: METHOD\nURL\nSORTED_HEADERS\nBODY_HASH
    try std.testing.expect(mem.startsWith(u8, canonical, "POST\n"));
    try std.testing.expect(mem.indexOf(u8, canonical, "https://api.example.com/data\n") != null);
    // Accept should come before Content-Type (sorted)
    const accept_pos = mem.indexOf(u8, canonical, "Accept:") orelse 0;
    const content_pos = mem.indexOf(u8, canonical, "Content-Type:") orelse 0;
    try std.testing.expect(accept_pos < content_pos);
    // Should end with a 64-char hex hash
    try std.testing.expectEqual(@as(usize, 64), canonical.len - (mem.lastIndexOf(u8, canonical, "\n") orelse 0) - 1);
}

test "parse signing config" {
    const content =
        \\signing:
        \\  method: hmac_sha256
        \\  secret_key: my-super-secret
        \\  header_name: X-Api-Signature
        \\  include_timestamp: true
        \\  timestamp_header: X-Request-Time
    ;

    const config = parseSigningConfig(content);

    try std.testing.expectEqual(SigningMethod.hmac_sha256, config.method);
    try std.testing.expectEqualStrings("my-super-secret", config.secret_key);
    try std.testing.expectEqualStrings("X-Api-Signature", config.header_name);
    try std.testing.expect(config.include_timestamp);
    try std.testing.expectEqualStrings("X-Request-Time", config.timestamp_header);
}

test "parse signing config aws sigv4" {
    const content =
        \\signing:
        \\  method: aws_sigv4
        \\  secret_key: wJalrXUtnFEMI/K7MDENG+bPxRfiCY
        \\  access_key: AKIAIOSFODNN7EXAMPLE
        \\  region: us-east-1
        \\  service: s3
    ;

    const config = parseSigningConfig(content);

    try std.testing.expectEqual(SigningMethod.aws_sigv4, config.method);
    try std.testing.expectEqualStrings("AKIAIOSFODNN7EXAMPLE", config.access_key);
    try std.testing.expectEqualStrings("us-east-1", config.region);
    try std.testing.expectEqualStrings("s3", config.service);
}

test "get timestamp format" {
    const ts = getTimestamp();
    // Should be 16 chars: YYYYMMDDTHHMMSSz
    try std.testing.expectEqual(@as(usize, 16), ts.len);
    // Check format: position 8 should be 'T', position 15 should be 'Z'
    try std.testing.expectEqual(@as(u8, 'T'), ts[8]);
    try std.testing.expectEqual(@as(u8, 'Z'), ts[15]);
}
