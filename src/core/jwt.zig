const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── JWT (JSON Web Token) Decoder & Inspector ────────────────────────
//
// Decodes and inspects JWT tokens for API authentication workflows.
// Supports:
//   - Base64url decoding of header and payload
//   - Standard claim extraction (iss, sub, aud, exp, nbf, iat, jti)
//   - Expiry validation against current time
//   - Pretty-printed claim display for terminal output
//   - Custom claim extraction from raw JSON payload
//
// NOTE: This module does NOT verify signatures (that requires crypto
// keys). It decodes and inspects tokens, which is what API clients need.

// ── Structs ─────────────────────────────────────────────────────────

pub const JwtToken = struct {
    raw: []const u8,
    header: JwtHeader,
    payload: JwtPayload,
    signature: []const u8,
    // Internal: decoded JSON buffers owned by the token
    header_json: []const u8,
    allocator: Allocator,

    /// Free the decoded header and payload JSON buffers.
    pub fn deinit(self: *const JwtToken) void {
        self.allocator.free(self.header_json);
        self.allocator.free(self.payload.raw_json);
    }
};

pub const JwtHeader = struct {
    alg: []const u8, // "HS256", "RS256", etc.
    typ: []const u8, // "JWT"
    kid: ?[]const u8 = null, // key id (optional)
};

pub const JwtPayload = struct {
    // Standard claims
    iss: ?[]const u8 = null, // issuer
    sub: ?[]const u8 = null, // subject
    aud: ?[]const u8 = null, // audience
    exp: ?i64 = null, // expiration time (unix timestamp)
    nbf: ?i64 = null, // not before
    iat: ?i64 = null, // issued at
    jti: ?[]const u8 = null, // JWT ID
    // Raw JSON for custom claims
    raw_json: []const u8,
};

pub const JwtValidation = struct {
    is_expired: bool,
    is_not_yet_valid: bool,
    seconds_until_expiry: ?i64,
    seconds_since_issued: ?i64,
};

// ── Base64url Decoding ──────────────────────────────────────────────

/// Decode a base64url-encoded string (RFC 4648 Section 5).
/// Replaces `-` with `+` and `_` with `/`, adds padding, then
/// uses the standard base64 decoder.
/// Caller owns the returned slice.
pub fn base64UrlDecode(allocator: Allocator, input: []const u8) ![]u8 {
    // Replace URL-safe characters with standard base64 characters
    const buf = try allocator.alloc(u8, input.len + 3); // extra space for padding
    defer allocator.free(buf);

    for (input, 0..) |c, i| {
        buf[i] = switch (c) {
            '-' => '+',
            '_' => '/',
            else => c,
        };
    }

    // Add padding to make length a multiple of 4
    var padded_len = input.len;
    const remainder = padded_len % 4;
    if (remainder != 0) {
        const padding_needed = 4 - remainder;
        for (0..padding_needed) |j| {
            buf[padded_len + j] = '=';
        }
        padded_len += padding_needed;
    }

    const padded = buf[0..padded_len];

    // Decode using standard base64
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(padded) catch return error.InvalidBase64;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);

    std.base64.standard.Decoder.decode(decoded, padded) catch return error.InvalidBase64;

    return decoded;
}

// ── JWT Decoding ────────────────────────────────────────────────────

/// Decode a JWT token string into its constituent parts.
/// Splits on `.`, base64url-decodes header and payload, parses JSON fields.
/// Caller must call `deinit()` on the returned JwtToken to free memory.
pub fn decode(allocator: Allocator, token_string: []const u8) !JwtToken {
    // Split token on '.' — must have exactly 3 parts
    var parts: [3][]const u8 = undefined;
    var part_count: usize = 0;
    var iter = mem.splitScalar(u8, token_string, '.');
    while (iter.next()) |part| {
        if (part_count >= 3) return error.InvalidTokenFormat;
        parts[part_count] = part;
        part_count += 1;
    }
    if (part_count != 3) return error.InvalidTokenFormat;

    // Base64url-decode header and payload
    const header_json = try base64UrlDecode(allocator, parts[0]);
    errdefer allocator.free(header_json);

    const payload_json = try base64UrlDecode(allocator, parts[1]);
    errdefer allocator.free(payload_json);

    // Parse header
    const header = parseHeader(header_json);

    // Parse payload
    const payload = parsePayload(payload_json);

    return JwtToken{
        .raw = token_string,
        .header = header,
        .payload = payload,
        .signature = parts[2],
        .header_json = header_json,
        .allocator = allocator,
    };
}

/// Parse JWT header JSON to extract alg, typ, and kid fields.
fn parseHeader(json: []const u8) JwtHeader {
    return .{
        .alg = extractJsonString(json, "alg") orelse "unknown",
        .typ = extractJsonString(json, "typ") orelse "unknown",
        .kid = extractJsonString(json, "kid"),
    };
}

/// Parse JWT payload JSON to extract standard claims.
fn parsePayload(json: []const u8) JwtPayload {
    return .{
        .iss = extractJsonString(json, "iss"),
        .sub = extractJsonString(json, "sub"),
        .aud = extractJsonString(json, "aud"),
        .exp = extractJsonNumber(json, "exp"),
        .nbf = extractJsonNumber(json, "nbf"),
        .iat = extractJsonNumber(json, "iat"),
        .jti = extractJsonString(json, "jti"),
        .raw_json = json,
    };
}

// ── Validation ──────────────────────────────────────────────────────

/// Validate a JWT token against the current time.
/// Checks expiration (exp) and not-before (nbf) claims.
pub fn validate(token: JwtToken) JwtValidation {
    const now = std.time.timestamp();

    const is_expired = if (token.payload.exp) |exp| now >= exp else false;
    const is_not_yet_valid = if (token.payload.nbf) |nbf| now < nbf else false;

    const seconds_until_expiry: ?i64 = if (token.payload.exp) |exp| exp - now else null;
    const seconds_since_issued: ?i64 = if (token.payload.iat) |iat| now - iat else null;

    return .{
        .is_expired = is_expired,
        .is_not_yet_valid = is_not_yet_valid,
        .seconds_until_expiry = seconds_until_expiry,
        .seconds_since_issued = seconds_since_issued,
    };
}

/// Simple expiry check. Returns true if the token's exp claim is in the past.
/// Returns false if there is no exp claim.
pub fn isExpired(token: JwtToken) bool {
    const exp = token.payload.exp orelse return false;
    return std.time.timestamp() >= exp;
}

/// Returns the number of seconds until the token expires.
/// Negative values mean the token is already expired.
/// Returns null if there is no exp claim.
pub fn timeUntilExpiry(token: JwtToken) ?i64 {
    const exp = token.payload.exp orelse return null;
    return exp - std.time.timestamp();
}

// ── Display ─────────────────────────────────────────────────────────

/// Pretty-print JWT claims for terminal display.
/// Caller owns the returned slice.
pub fn formatClaims(allocator: Allocator, token: JwtToken) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("JWT Token Claims:\n");

    // Header info
    try writer.writeAll("  Algorithm: ");
    try writer.writeAll(token.header.alg);
    try writer.writeAll("\n");

    try writer.writeAll("  Type: ");
    try writer.writeAll(token.header.typ);
    try writer.writeAll("\n");

    if (token.header.kid) |kid| {
        try writer.writeAll("  Key ID: ");
        try writer.writeAll(kid);
        try writer.writeAll("\n");
    }

    // Payload claims
    if (token.payload.iss) |iss| {
        try writer.writeAll("  Issuer: ");
        try writer.writeAll(iss);
        try writer.writeAll("\n");
    }

    if (token.payload.sub) |sub| {
        try writer.writeAll("  Subject: ");
        try writer.writeAll(sub);
        try writer.writeAll("\n");
    }

    if (token.payload.aud) |aud| {
        try writer.writeAll("  Audience: ");
        try writer.writeAll(aud);
        try writer.writeAll("\n");
    }

    if (token.payload.exp) |exp| {
        try writer.print("  Expires: {d}", .{exp});
        const remaining = timeUntilExpiry(token);
        if (remaining) |r| {
            if (r >= 0) {
                try writer.print(" (in {d}s)", .{r});
            } else {
                try writer.print(" (expired {d}s ago)", .{-r});
            }
        }
        try writer.writeAll("\n");
    }

    if (token.payload.nbf) |nbf| {
        try writer.print("  Not Before: {d}\n", .{nbf});
    }

    if (token.payload.iat) |iat| {
        try writer.print("  Issued At: {d}\n", .{iat});
    }

    if (token.payload.jti) |jti| {
        try writer.writeAll("  JWT ID: ");
        try writer.writeAll(jti);
        try writer.writeAll("\n");
    }

    return buf.toOwnedSlice();
}

// ── Claim Extraction ────────────────────────────────────────────────

/// Extract a specific claim value from the raw JSON payload.
/// Performs a simple JSON key search — finds `"claim_name":` then
/// extracts the value (string or number).
pub fn extractClaim(payload: JwtPayload, claim_name: []const u8) ?[]const u8 {
    return extractJsonString(payload.raw_json, claim_name);
}

// ── Internal JSON Helpers ───────────────────────────────────────────

/// Extract a string value for a given key from a JSON object.
/// Finds `"key":"value"` and returns the value (without quotes).
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key" : "value" pattern
    var pos: usize = 0;
    while (pos < json.len) {
        // Find the next opening quote
        const key_start = mem.indexOf(u8, json[pos..], "\"") orelse return null;
        const abs_key_start = pos + key_start + 1;
        if (abs_key_start + key.len >= json.len) return null;

        // Check if this quoted string matches our key
        if (abs_key_start + key.len < json.len and
            mem.eql(u8, json[abs_key_start .. abs_key_start + key.len], key))
        {
            // Verify the closing quote is right after the key
            if (json[abs_key_start + key.len] == '"') {
                // Find the colon after the key
                var colon_pos = abs_key_start + key.len + 1;
                while (colon_pos < json.len and (json[colon_pos] == ' ' or json[colon_pos] == '\t')) {
                    colon_pos += 1;
                }
                if (colon_pos >= json.len or json[colon_pos] != ':') {
                    pos = abs_key_start + key.len;
                    continue;
                }

                // Skip whitespace after colon
                var val_start = colon_pos + 1;
                while (val_start < json.len and (json[val_start] == ' ' or json[val_start] == '\t')) {
                    val_start += 1;
                }
                if (val_start >= json.len) return null;

                // Check if value is a string (starts with quote)
                if (json[val_start] == '"') {
                    val_start += 1;
                    // Find closing quote (handle escaped quotes)
                    var val_end = val_start;
                    while (val_end < json.len) {
                        if (json[val_end] == '\\') {
                            val_end += 2; // skip escaped character
                            continue;
                        }
                        if (json[val_end] == '"') break;
                        val_end += 1;
                    }
                    if (val_end <= json.len) {
                        return json[val_start..val_end];
                    }
                }

                return null;
            }
        }

        pos = abs_key_start + 1;
    }

    return null;
}

/// Extract a numeric value for a given key from a JSON object.
/// Finds `"key":12345` and returns the parsed i64.
fn extractJsonNumber(json: []const u8, key: []const u8) ?i64 {
    var pos: usize = 0;
    while (pos < json.len) {
        const key_start = mem.indexOf(u8, json[pos..], "\"") orelse return null;
        const abs_key_start = pos + key_start + 1;
        if (abs_key_start + key.len >= json.len) return null;

        if (abs_key_start + key.len < json.len and
            mem.eql(u8, json[abs_key_start .. abs_key_start + key.len], key))
        {
            if (json[abs_key_start + key.len] == '"') {
                var colon_pos = abs_key_start + key.len + 1;
                while (colon_pos < json.len and (json[colon_pos] == ' ' or json[colon_pos] == '\t')) {
                    colon_pos += 1;
                }
                if (colon_pos >= json.len or json[colon_pos] != ':') {
                    pos = abs_key_start + key.len;
                    continue;
                }

                var val_start = colon_pos + 1;
                while (val_start < json.len and (json[val_start] == ' ' or json[val_start] == '\t')) {
                    val_start += 1;
                }
                if (val_start >= json.len) return null;

                // Extract numeric value (digits, optional leading minus)
                var val_end = val_start;
                if (val_end < json.len and json[val_end] == '-') {
                    val_end += 1;
                }
                while (val_end < json.len and json[val_end] >= '0' and json[val_end] <= '9') {
                    val_end += 1;
                }

                if (val_end > val_start) {
                    return std.fmt.parseInt(i64, json[val_start..val_end], 10) catch null;
                }

                return null;
            }
        }

        pos = abs_key_start + 1;
    }

    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

// Test JWT (valid base64url structure):
// Header:  {"alg":"HS256","typ":"JWT"}
// Payload: {"sub":"user123","iss":"auth.example.com","exp":9999999999,"iat":1709506800,"jti":"abc123"}
const test_jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMTIzIiwiaXNzIjoiYXV0aC5leGFtcGxlLmNvbSIsImV4cCI6OTk5OTk5OTk5OSwiaWF0IjoxNzA5NTA2ODAwLCJqdGkiOiJhYmMxMjMifQ.signature";

test "base64url decode simple string" {
    const input = "SGVsbG8"; // "Hello" in base64url (no padding needed for 5 bytes)
    const decoded = try base64UrlDecode(std.testing.allocator, input);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("Hello", decoded);
}

test "base64url decode with URL-safe characters" {
    // Standard base64 would use + and /, but base64url uses - and _
    // We test that - and _ are correctly replaced with + and /
    const input = "YS1i_2M"; // contains - and _ which are URL-safe variants
    const decoded = try base64UrlDecode(std.testing.allocator, input);
    defer std.testing.allocator.free(decoded);

    // Verify we got valid decoded output (the replacement worked)
    try std.testing.expect(decoded.len > 0);
}

test "base64url decode with padding needed" {
    // "AB" in base64 is "QUI" (3 chars, needs 1 pad to make 4)
    const input = "QUI";
    const decoded = try base64UrlDecode(std.testing.allocator, input);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqualStrings("AB", decoded);
}

test "decode valid JWT header" {
    const token = try decode(std.testing.allocator, test_jwt);
    defer token.deinit();

    try std.testing.expectEqualStrings("HS256", token.header.alg);
    try std.testing.expectEqualStrings("JWT", token.header.typ);
    try std.testing.expect(token.header.kid == null);
}

test "decode valid JWT payload claims" {
    const token = try decode(std.testing.allocator, test_jwt);
    defer token.deinit();

    try std.testing.expectEqualStrings("user123", token.payload.sub.?);
    try std.testing.expectEqualStrings("auth.example.com", token.payload.iss.?);
    try std.testing.expectEqual(@as(i64, 9999999999), token.payload.exp.?);
    try std.testing.expectEqual(@as(i64, 1709506800), token.payload.iat.?);
    try std.testing.expectEqualStrings("abc123", token.payload.jti.?);
}

test "decode JWT - invalid format (not 3 parts) returns error" {
    // Only 2 parts
    const result = decode(std.testing.allocator, "part1.part2");
    try std.testing.expectError(error.InvalidTokenFormat, result);

    // 4 parts
    const result2 = decode(std.testing.allocator, "a.b.c.d");
    try std.testing.expectError(error.InvalidTokenFormat, result2);

    // Single part
    const result3 = decode(std.testing.allocator, "justonepart");
    try std.testing.expectError(error.InvalidTokenFormat, result3);
}

test "isExpired returns false for far-future exp" {
    const token = try decode(std.testing.allocator, test_jwt);
    defer token.deinit();

    // exp=9999999999 is far in the future
    try std.testing.expect(!isExpired(token));
}

test "isExpired returns true for past exp" {
    // Build a token with exp=1000 (far in the past)
    // Header: {"alg":"HS256","typ":"JWT"} -> eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9
    // Payload: {"exp":1000} -> eyJleHAiOjEwMDB9
    const expired_jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjEwMDB9.sig";
    const token = try decode(std.testing.allocator, expired_jwt);
    defer token.deinit();

    try std.testing.expectEqual(@as(i64, 1000), token.payload.exp.?);
    try std.testing.expect(isExpired(token));
}

test "timeUntilExpiry returns positive for future token" {
    const token = try decode(std.testing.allocator, test_jwt);
    defer token.deinit();

    const remaining = timeUntilExpiry(token);
    try std.testing.expect(remaining != null);
    try std.testing.expect(remaining.? > 0);
}

test "formatClaims produces readable output" {
    const token = try decode(std.testing.allocator, test_jwt);
    defer token.deinit();

    const output = try formatClaims(std.testing.allocator, token);
    defer std.testing.allocator.free(output);

    try std.testing.expect(mem.indexOf(u8, output, "JWT Token Claims:") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Algorithm: HS256") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Type: JWT") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Issuer: auth.example.com") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Subject: user123") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Expires: 9999999999") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Issued At: 1709506800") != null);
    try std.testing.expect(mem.indexOf(u8, output, "JWT ID: abc123") != null);
}

test "extractClaim finds existing claim" {
    const token = try decode(std.testing.allocator, test_jwt);
    defer token.deinit();

    const sub = extractClaim(token.payload, "sub");
    try std.testing.expect(sub != null);
    try std.testing.expectEqualStrings("user123", sub.?);

    const iss = extractClaim(token.payload, "iss");
    try std.testing.expect(iss != null);
    try std.testing.expectEqualStrings("auth.example.com", iss.?);
}

test "extractClaim returns null for missing claim" {
    const token = try decode(std.testing.allocator, test_jwt);
    defer token.deinit();

    const missing = extractClaim(token.payload, "nonexistent_claim");
    try std.testing.expect(missing == null);

    const also_missing = extractClaim(token.payload, "email");
    try std.testing.expect(also_missing == null);
}

test "validate checks both expired and not-yet-valid" {
    // Test with the far-future token (should not be expired, should be valid)
    const token = try decode(std.testing.allocator, test_jwt);
    defer token.deinit();

    const v = validate(token);
    try std.testing.expect(!v.is_expired);
    try std.testing.expect(!v.is_not_yet_valid);
    try std.testing.expect(v.seconds_until_expiry != null);
    try std.testing.expect(v.seconds_until_expiry.? > 0);
    try std.testing.expect(v.seconds_since_issued != null);
    try std.testing.expect(v.seconds_since_issued.? > 0);

    // Test with an expired token (exp=1000)
    const expired_jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjEwMDB9.sig";
    const expired_token = try decode(std.testing.allocator, expired_jwt);
    defer expired_token.deinit();

    const v2 = validate(expired_token);
    try std.testing.expect(v2.is_expired);
    try std.testing.expect(v2.seconds_until_expiry != null);
    try std.testing.expect(v2.seconds_until_expiry.? < 0);
}
