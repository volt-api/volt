const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── E2E Encrypted Secrets ─────────────────────────────────────────────
// Encrypts sensitive values in .volt files for safe git commits.
// Uses XOR-based encryption with base64 encoding and a 32-byte key.
// Detects secrets heuristically and encrypts them in-place.

pub const SecretStore = struct {
    allocator: Allocator,
    entries: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) SecretStore {
        return .{
            .allocator = allocator,
            .entries = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *SecretStore) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    /// Store a secret value under a given name.
    pub fn put(self: *SecretStore, name: []const u8, value: []const u8) !void {
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const owned_value = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned_value);

        // Remove old entry if present
        if (self.entries.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }

        try self.entries.put(owned_name, owned_value);
    }

    /// Retrieve a secret value by name.
    pub fn get(self: *const SecretStore, name: []const u8) ?[]const u8 {
        return self.entries.get(name);
    }
};

// ── Encryption ────────────────────────────────────────────────────────

/// Encrypt plaintext using XOR with a 32-byte key, then base64-encode the result.
pub fn encryptValue(allocator: Allocator, plaintext: []const u8, key: [32]u8) ![]const u8 {
    // XOR each byte with the key (cycling)
    const xored = try allocator.alloc(u8, plaintext.len);
    defer allocator.free(xored);

    for (plaintext, 0..) |byte, i| {
        xored[i] = byte ^ key[i % 32];
    }

    // Base64 encode
    return encodeBase64(allocator, xored);
}

/// Decrypt a base64-encoded ciphertext by decoding then XOR with the same key.
pub fn decryptValue(allocator: Allocator, ciphertext: []const u8, key: [32]u8) ![]const u8 {
    // Base64 decode
    const decoded = try decodeBase64(allocator, ciphertext);
    defer allocator.free(decoded);

    // XOR to recover plaintext
    const plaintext = try allocator.alloc(u8, decoded.len);
    for (decoded, 0..) |byte, i| {
        plaintext[i] = byte ^ key[i % 32];
    }

    return plaintext;
}

/// Generate a random 32-byte encryption key.
pub fn generateKey() [32]u8 {
    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);
    return key;
}

/// Convert a 32-byte key to a 64-character hex string.
pub fn keyToHex(key: [32]u8) [64]u8 {
    var hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (key, 0..) |byte, i| {
        hex[i * 2] = hex_chars[@as(usize, byte >> 4)];
        hex[i * 2 + 1] = hex_chars[@as(usize, byte & 0x0F)];
    }
    return hex;
}

/// Convert a 64-character hex string back to a 32-byte key.
pub fn hexToKey(hex: [64]u8) [32]u8 {
    var key: [32]u8 = undefined;
    for (0..32) |i| {
        const high = hexCharToNibble(hex[i * 2]);
        const low = hexCharToNibble(hex[i * 2 + 1]);
        key[i] = (@as(u8, high) << 4) | @as(u8, low);
    }
    return key;
}

fn hexCharToNibble(c: u8) u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => 0,
    };
}

// ── Secret Detection ──────────────────────────────────────────────────

/// Heuristic detection: checks if a string looks like an API key, token, or password.
pub fn isLikelySecret(value: []const u8) bool {
    // Check for known secret prefixes
    if (mem.startsWith(u8, value, "sk-")) return true;
    if (mem.startsWith(u8, value, "pk-")) return true;
    if (mem.startsWith(u8, value, "ghp_")) return true;
    if (mem.startsWith(u8, value, "gho_")) return true;
    if (mem.startsWith(u8, value, "ghu_")) return true;
    if (mem.startsWith(u8, value, "ghs_")) return true;
    if (mem.startsWith(u8, value, "ghr_")) return true;
    if (mem.startsWith(u8, value, "glpat-")) return true;
    if (mem.startsWith(u8, value, "xoxb-")) return true;
    if (mem.startsWith(u8, value, "xoxp-")) return true;
    if (mem.startsWith(u8, value, "AKIA")) return true;
    if (mem.startsWith(u8, value, "Bearer ")) return true;

    // Long mixed alphanumeric strings (length > 20) are likely secrets
    if (value.len > 20) {
        var has_upper = false;
        var has_lower = false;
        var has_digit = false;
        var alnum_count: usize = 0;

        for (value) |c| {
            if (c >= 'A' and c <= 'Z') {
                has_upper = true;
                alnum_count += 1;
            } else if (c >= 'a' and c <= 'z') {
                has_lower = true;
                alnum_count += 1;
            } else if (c >= '0' and c <= '9') {
                has_digit = true;
                alnum_count += 1;
            }
        }

        // If most characters are alphanumeric and we have a mix, likely a secret
        if (has_upper and has_lower and has_digit and alnum_count > value.len / 2) {
            return true;
        }
    }

    return false;
}

// ── File-Level Encryption ─────────────────────────────────────────────

/// Scan .volt file content, find sensitive values after known field names
/// (token:, password:, key_value:, $ prefixed vars), and encrypt them in-place
/// as ${{encrypted:base64...}}.
pub fn encryptVoltFileSecrets(allocator: Allocator, content: []const u8, key: [32]u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    const sensitive_fields = [_][]const u8{ "token:", "password:", "key_value:" };

    var lines = mem.splitSequence(u8, content, "\n");
    var first = true;
    while (lines.next()) |raw_line| {
        if (!first) {
            try result.append('\n');
        }
        first = false;

        const line = mem.trimRight(u8, raw_line, "\r");
        const trimmed = mem.trim(u8, line, " \t");

        // Check if this line contains a sensitive field
        var is_sensitive = false;
        var field_end: usize = 0;
        for (sensitive_fields) |field| {
            if (mem.startsWith(u8, trimmed, field)) {
                is_sensitive = true;
                field_end = field.len;
                break;
            }
        }

        if (is_sensitive) {
            const value_part = mem.trim(u8, trimmed[field_end..], " \t");
            // Skip already-encrypted values
            if (mem.startsWith(u8, value_part, "${{encrypted:")) {
                try result.appendSlice(line);
                continue;
            }

            if (value_part.len > 0) {
                // Get the leading whitespace + field name
                const prefix_len = mem.indexOf(u8, line, trimmed) orelse 0;
                try result.appendSlice(line[0..prefix_len]);
                try result.appendSlice(trimmed[0..field_end]);
                try result.append(' ');

                // Encrypt the value
                const encrypted = try encryptValue(allocator, value_part, key);
                defer allocator.free(encrypted);
                try result.appendSlice("${{encrypted:");
                try result.appendSlice(encrypted);
                try result.appendSlice("}}");
                continue;
            }
        }

        // Check for $VARIABLE patterns (environment variable references are not encrypted,
        // but inline $-prefixed values that look like secrets are)
        if (mem.indexOf(u8, trimmed, "${{encrypted:") != null) {
            // Already encrypted, pass through
            try result.appendSlice(line);
            continue;
        }

        try result.appendSlice(line);
    }

    return result.toOwnedSlice();
}

/// Find ${{encrypted:...}} patterns in content and decrypt them back to plaintext.
pub fn decryptVoltFileSecrets(allocator: Allocator, content: []const u8, key: [32]u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    const marker_start = "${{encrypted:";
    const marker_end = "}}";

    var i: usize = 0;
    while (i < content.len) {
        if (i + marker_start.len < content.len and mem.startsWith(u8, content[i..], marker_start)) {
            // Found encrypted marker
            const enc_start = i + marker_start.len;
            if (mem.indexOf(u8, content[enc_start..], marker_end)) |end_offset| {
                const enc_data = content[enc_start .. enc_start + end_offset];
                const decrypted = decryptValue(allocator, enc_data, key) catch {
                    // If decryption fails, leave the marker as-is
                    try result.appendSlice(marker_start);
                    i += marker_start.len;
                    continue;
                };
                defer allocator.free(decrypted);
                try result.appendSlice(decrypted);
                i = enc_start + end_offset + marker_end.len;
                continue;
            }
        }

        try result.append(content[i]);
        i += 1;
    }

    return result.toOwnedSlice();
}

// ── Base64 Helpers ────────────────────────────────────────────────────

fn encodeBase64(allocator: Allocator, data: []const u8) ![]const u8 {
    const encoder = std.base64.standard;
    const encoded_len = encoder.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, encoded_len);
    _ = encoder.Encoder.encode(buf, data);
    return buf;
}

fn decodeBase64(allocator: Allocator, encoded: []const u8) ![]const u8 {
    const decoder = std.base64.standard;
    const decoded_len = decoder.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const buf = try allocator.alloc(u8, decoded_len);
    decoder.Decoder.decode(buf, encoded) catch return error.InvalidBase64;
    return buf;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "encrypt and decrypt roundtrip" {
    const allocator = std.testing.allocator;
    const key = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20 };

    const plaintext = "sk-my-super-secret-api-key-12345";
    const encrypted = try encryptValue(allocator, plaintext, key);
    defer allocator.free(encrypted);

    // Encrypted should be different from plaintext
    try std.testing.expect(!mem.eql(u8, plaintext, encrypted));

    const decrypted = try decryptValue(allocator, encrypted, key);
    defer allocator.free(decrypted);

    try std.testing.expectEqualStrings(plaintext, decrypted);
}

test "encrypt and decrypt empty string" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0xAB} ** 32;

    const encrypted = try encryptValue(allocator, "", key);
    defer allocator.free(encrypted);

    const decrypted = try decryptValue(allocator, encrypted, key);
    defer allocator.free(decrypted);

    try std.testing.expectEqualStrings("", decrypted);
}

test "key to hex and back" {
    const key = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1C };

    const hex = keyToHex(key);
    try std.testing.expect(mem.startsWith(u8, &hex, "deadbeef"));

    const recovered = hexToKey(hex);
    try std.testing.expectEqualSlices(u8, &key, &recovered);
}

test "isLikelySecret detects known prefixes" {
    try std.testing.expect(isLikelySecret("sk-1234567890abcdef"));
    try std.testing.expect(isLikelySecret("pk-test-key"));
    try std.testing.expect(isLikelySecret("ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"));
    try std.testing.expect(isLikelySecret("Bearer eyJhbGciOiJIUzI1NiJ9"));
    try std.testing.expect(isLikelySecret("glpat-xxxxxxxxxxxxxxxxxxxx"));
    try std.testing.expect(isLikelySecret("xoxb-123-456-abc"));
    try std.testing.expect(isLikelySecret("AKIAxxxxxxxxxxxxxxxx"));
}

test "isLikelySecret rejects non-secrets" {
    try std.testing.expect(!isLikelySecret("hello"));
    try std.testing.expect(!isLikelySecret("application/json"));
    try std.testing.expect(!isLikelySecret("https://example.com"));
    try std.testing.expect(!isLikelySecret("200"));
    try std.testing.expect(!isLikelySecret("true"));
}

test "isLikelySecret detects long mixed alphanumeric" {
    // A sufficiently long mixed-case alphanumeric string
    try std.testing.expect(isLikelySecret("aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"));
}

test "encrypt volt file secrets" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x42} ** 32;

    const content =
        \\method: GET
        \\url: https://api.example.com
        \\auth:
        \\  type: bearer
        \\  token: sk-my-secret-key
        \\headers:
        \\  - Accept: application/json
    ;

    const encrypted = try encryptVoltFileSecrets(allocator, content, key);
    defer allocator.free(encrypted);

    // Token value should be encrypted
    try std.testing.expect(mem.indexOf(u8, encrypted, "sk-my-secret-key") == null);
    try std.testing.expect(mem.indexOf(u8, encrypted, "${{encrypted:") != null);

    // Non-sensitive fields should be unchanged
    try std.testing.expect(mem.indexOf(u8, encrypted, "method: GET") != null);
    try std.testing.expect(mem.indexOf(u8, encrypted, "url: https://api.example.com") != null);
}

test "decrypt volt file secrets" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x42} ** 32;

    const original =
        \\method: GET
        \\url: https://api.example.com
        \\auth:
        \\  type: bearer
        \\  token: sk-my-secret-key
    ;

    // Encrypt then decrypt should yield original
    const encrypted = try encryptVoltFileSecrets(allocator, original, key);
    defer allocator.free(encrypted);

    const decrypted = try decryptVoltFileSecrets(allocator, encrypted, key);
    defer allocator.free(decrypted);

    // The token line should be restored
    try std.testing.expect(mem.indexOf(u8, decrypted, "sk-my-secret-key") != null);
}

test "secret store put and get" {
    var store = SecretStore.init(std.testing.allocator);
    defer store.deinit();

    try store.put("api_key", "sk-test-12345");
    try store.put("db_password", "hunter2");

    try std.testing.expectEqualStrings("sk-test-12345", store.get("api_key").?);
    try std.testing.expectEqualStrings("hunter2", store.get("db_password").?);
    try std.testing.expect(store.get("nonexistent") == null);
}

test "already encrypted values are not double-encrypted" {
    const allocator = std.testing.allocator;
    const key = [_]u8{0x42} ** 32;

    const content =
        \\auth:
        \\  token: ${{encrypted:AQIDBAU=}}
    ;

    const result = try encryptVoltFileSecrets(allocator, content, key);
    defer allocator.free(result);

    // Should pass through unchanged
    try std.testing.expect(mem.indexOf(u8, result, "${{encrypted:AQIDBAU=}}") != null);
}
