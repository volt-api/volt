//! QUIC packet protection and key derivation (RFC 9001).
//!
//! Provides HKDF-based key derivation, AEAD encryption/decryption,
//! and header protection for QUIC packets using AES-128-GCM.

const std = @import("std");
const crypto = std.crypto;
const mem = std.mem;
const fmt = std.fmt;
const testing = std.testing;

pub const Sha256 = crypto.hash.sha2.Sha256;
pub const Hmac = crypto.auth.hmac.sha2.HmacSha256;
pub const Hkdf = crypto.kdf.hkdf.HkdfSha256;
pub const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
pub const Aes128 = crypto.core.aes.Aes128;

/// QUIC v1 initial salt (RFC 9001 §5.2)
// zig fmt: off
pub const INITIAL_SALT_V1 = [_]u8{
    0x38, 0x76, 0x2c, 0xf7,
    0xf5, 0x59, 0x34, 0xb3,
    0x4d, 0x17, 0x9a, 0xe6,
    0xa4, 0xc8, 0x0c, 0xad,
    0xcc, 0xbb, 0x7f, 0x0a,
};
// zig fmt: on

pub const HP_KEY_LENGTH = 16;

/// QUIC keys for packet protection (one direction).
pub const QuicKeys = struct {
    secret: [32]u8 = undefined,
    key: [16]u8 = undefined,
    iv: [12]u8 = undefined,
    hp: [16]u8 = undefined,

    /// Derive key, IV, and HP key from the traffic secret.
    pub fn deriveFromSecret(secret: [32]u8) QuicKeys {
        var self = QuicKeys{ .secret = secret };
        hkdfExpandLabel(&self.key, secret, "quic key", "");
        hkdfExpandLabel(&self.iv, secret, "quic iv", "");
        hkdfExpandLabel(&self.hp, secret, "quic hp", "");
        return self;
    }

    /// Derive client handshake traffic keys.
    pub fn deriveHandshakeClient(hs_secret: [32]u8, transcript: []const u8) QuicKeys {
        var secret: [32]u8 = undefined;
        deriveSecret(&secret, hs_secret, "c hs traffic", transcript);
        return deriveFromSecret(secret);
    }

    /// Derive server handshake traffic keys.
    pub fn deriveHandshakeServer(hs_secret: [32]u8, transcript: []const u8) QuicKeys {
        var secret: [32]u8 = undefined;
        deriveSecret(&secret, hs_secret, "s hs traffic", transcript);
        return deriveFromSecret(secret);
    }

    /// Derive client application traffic keys.
    pub fn deriveApplicationClient(master: [32]u8, transcript: []const u8) QuicKeys {
        var secret: [32]u8 = undefined;
        deriveSecret(&secret, master, "c ap traffic", transcript);
        return deriveFromSecret(secret);
    }

    /// Derive server application traffic keys.
    pub fn deriveApplicationServer(master: [32]u8, transcript: []const u8) QuicKeys {
        var secret: [32]u8 = undefined;
        deriveSecret(&secret, master, "s ap traffic", transcript);
        return deriveFromSecret(secret);
    }
};

/// Derive initial client and server keys from destination connection ID.
pub fn deriveInitialKeys(dcid: []const u8) struct { client: QuicKeys, server: QuicKeys } {
    const initial_secret = Hkdf.extract(&INITIAL_SALT_V1, dcid);

    var client_secret: [32]u8 = undefined;
    hkdfExpandLabel(&client_secret, initial_secret, "client in", "");
    var server_secret: [32]u8 = undefined;
    hkdfExpandLabel(&server_secret, initial_secret, "server in", "");

    return .{
        .client = QuicKeys.deriveFromSecret(client_secret),
        .server = QuicKeys.deriveFromSecret(server_secret),
    };
}

/// HKDF-Expand-Label as defined in RFC 8446 §7.1.
/// Constructs the info parameter with "tls13 " prefix and calls HKDF-Expand.
pub fn hkdfExpandLabel(
    out: []u8,
    secret: [Hmac.key_length]u8,
    label: []const u8,
    context: []const u8,
) void {
    const LABEL_PREFIX = "tls13 ";
    const MAX_INFO_LEN = 600;

    var hkdf_label: [MAX_INFO_LEN]u8 = undefined;
    var offset: usize = 0;

    // Length of output (2 bytes, big-endian)
    const out_len: u16 = @intCast(out.len);
    hkdf_label[offset] = @intCast(out_len >> 8);
    hkdf_label[offset + 1] = @intCast(out_len & 0xff);
    offset += 2;

    // Label length (1 byte) + "tls13 " + label
    hkdf_label[offset] = @intCast(LABEL_PREFIX.len + label.len);
    offset += 1;

    @memcpy(hkdf_label[offset..][0..LABEL_PREFIX.len], LABEL_PREFIX);
    offset += LABEL_PREFIX.len;

    @memcpy(hkdf_label[offset..][0..label.len], label);
    offset += label.len;

    // Context length (1 byte) + context
    hkdf_label[offset] = @intCast(context.len);
    offset += 1;

    @memcpy(hkdf_label[offset..][0..context.len], context);
    offset += context.len;

    Hkdf.expand(out, hkdf_label[0..offset], secret);
}

/// Derive-Secret as defined in RFC 8446 §7.1.
/// Hash the message with SHA-256, then call HKDF-Expand-Label.
pub fn deriveSecret(
    out: *[Sha256.digest_length]u8,
    secret: [Hmac.key_length]u8,
    label: []const u8,
    message: []const u8,
) void {
    var h: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(message, &h, .{});
    hkdfExpandLabel(out, secret, label, &h);
}

/// Encrypt a QUIC packet: AEAD encrypt payload, then apply header protection.
/// `header` is from first byte through packet number field.
/// `payload` is the packet payload (after packet number).
pub fn encryptPacket(
    header: []const u8,
    payload: []const u8,
    key: [16]u8,
    iv: [12]u8,
    hp_key: [HP_KEY_LENGTH]u8,
    allocator: mem.Allocator,
    is_short_header: bool,
) !std.ArrayList(u8) {
    // Create nonce by XOR'ing IV with packet number
    const pn_length: usize = @as(usize, @intCast(header[0] & 0x03)) + 1;
    var nonce: [12]u8 = iv;
    for (header[header.len - pn_length ..], 0..) |value, index| {
        nonce[12 - pn_length + index] ^= value;
    }

    // Encrypt payload with AEAD
    const protected_payload = try allocator.alloc(u8, payload.len);
    defer allocator.free(protected_payload);
    var auth_tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(protected_payload, &auth_tag, payload, header, nonce, key);

    // Get header protection sample (4 bytes after the packet number)
    var sample: [HP_KEY_LENGTH]u8 = undefined;
    @memcpy(&sample, protected_payload[4 - pn_length .. 20 - pn_length]);

    // Create header protection mask
    const mask = deriveHpMask(hp_key, sample);

    // Apply header protection to first byte and packet number
    // Short headers protect 5 bits (0x1f), long headers protect 4 bits (0x0f)
    var encrypted_packet = std.ArrayList(u8).init(allocator);
    try encrypted_packet.appendSlice(header);
    encrypted_packet.items[0] ^= (mask[0] & (if (is_short_header) @as(u8, 0x1f) else @as(u8, 0x0f)));
    for (encrypted_packet.items[header.len - pn_length ..], 0..) |*value, index| {
        value.* ^= mask[1 + index];
    }

    // Append encrypted payload and auth tag
    try encrypted_packet.appendSlice(protected_payload);
    try encrypted_packet.appendSlice(&auth_tag);

    return encrypted_packet;
}

/// Decrypt a QUIC packet: remove header protection, then AEAD decrypt.
/// `header` is from first byte through the "length" field (before encrypted PN).
/// `payload` is the remainder (includes encrypted packet number + ciphertext + tag).
pub fn decryptPacket(
    header: []const u8,
    payload: []const u8,
    key: [16]u8,
    iv: [12]u8,
    hp_key: [HP_KEY_LENGTH]u8,
    allocator: mem.Allocator,
    is_short_header: bool,
) !std.ArrayList(u8) {
    // Get header protection sample and derive mask
    const sample = payload[4..20];
    const mask = deriveHpMask(hp_key, sample.*);

    // Build result with unprotected header
    var decrypted_res = std.ArrayList(u8).init(allocator);
    errdefer decrypted_res.deinit();
    try decrypted_res.ensureTotalCapacityPrecise(
        header.len + payload.len - Aes128Gcm.tag_length,
    );

    // Unprotect first byte and derive packet number length
    try decrypted_res.appendSlice(header);
    decrypted_res.items[0] = header[0] ^ (mask[0] & (if (is_short_header) @as(u8, 0x1f) else @as(u8, 0x0f)));
    const pn_length: usize = @as(usize, @intCast(decrypted_res.items[0] & 0x03)) + 1;

    // Unprotect packet number
    try decrypted_res.appendSlice(payload[0..pn_length]);
    const pn_start = decrypted_res.items.len - pn_length;
    for (decrypted_res.items[pn_start..][0..pn_length], 0..) |*val, idx| {
        val.* ^= mask[1 + idx];
    }

    // Create nonce from IV XOR packet number
    var nonce: [12]u8 = iv;
    for (nonce[12 - pn_length ..][0..pn_length], 0..) |*val, idx| {
        val.* ^= decrypted_res.items[pn_start + idx];
    }

    // Decrypt payload
    const encrypted_payload = payload[pn_length .. payload.len - Aes128Gcm.tag_length];
    const auth_tag: [Aes128Gcm.tag_length]u8 = payload[payload.len - Aes128Gcm.tag_length ..][0..Aes128Gcm.tag_length].*;
    const decrypted_payload = try allocator.alloc(u8, encrypted_payload.len);
    defer allocator.free(decrypted_payload);
    try Aes128Gcm.decrypt(
        decrypted_payload,
        encrypted_payload,
        auth_tag,
        decrypted_res.items,
        nonce,
        key,
    );
    try decrypted_res.appendSlice(decrypted_payload);

    return decrypted_res;
}

/// Derive header protection mask using AES-128-ECB single-block encrypt.
pub fn deriveHpMask(
    hp_key: [HP_KEY_LENGTH]u8,
    sample: [HP_KEY_LENGTH]u8,
) [HP_KEY_LENGTH]u8 {
    var mask: [HP_KEY_LENGTH]u8 = undefined;
    const ctx = Aes128.initEnc(hp_key);
    ctx.encrypt(&mask, &sample);
    return mask;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "HKDF-Expand-Label" {
    const random_bytes = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07 };
    const initial_secret = Hkdf.extract(&INITIAL_SALT_V1, &random_bytes);
    var client_initial: [32]u8 = undefined;
    hkdfExpandLabel(&client_initial, initial_secret, "client in", "");

    var client_key: [16]u8 = undefined;
    hkdfExpandLabel(&client_key, client_initial, "quic key", "");

    // zig fmt: off
    const expected = [_]u8{
        0xb1, 0x4b, 0x91, 0x81,
        0x24, 0xfd, 0xa5, 0xc8,
        0xd7, 0x98, 0x47, 0x60,
        0x2f, 0xa3, 0x52, 0x0b,
    };
    // zig fmt: on

    try testing.expectEqual(expected, client_key);
}

test "Derive-Secret with RFC 8448 vectors" {
    const handshake_secret =
        "\x1d\xc8\x26\xe9\x36\x06\xaa\x6f\xdc\x0a\xad\xc1\x2f\x74\x1b" ++
        "\x01\x04\x6a\xa6\xb9\x9f\x69\x1e\xd2\x21\xa9\xf0\xca\x04\x3f" ++
        "\xbe\xac";
    const client_hello_bytes =
        "\x01\x00\x00\xc0\x03\x03\xcb\x34\xec\xb1\xe7\x81\x63\xba\x1c\x38\xc6\xda\xcb\x19\x6a" ++
        "\x6d\xff\xa2\x1a\x8d\x99\x12\xec\x18\xa2\xef\x62\x83\x02\x4d\xec\xe7\x00\x00\x06\x13" ++
        "\x01\x13\x03\x13\x02\x01\x00\x00\x91\x00\x00\x00\x0b\x00\x09\x00\x00\x06\x73\x65\x72" ++
        "\x76\x65\x72\xff\x01\x00\x01\x00\x00\x0a\x00\x14\x00\x12\x00\x1d\x00\x17\x00\x18\x00" ++
        "\x19\x01\x00\x01\x01\x01\x02\x01\x03\x01\x04\x00\x23\x00\x00\x00\x33\x00\x26\x00\x24" ++
        "\x00\x1d\x00\x20\x99\x38\x1d\xe5\x60\xe4\xbd\x43\xd2\x3d\x8e\x43\x5a\x7d\xba\xfe\xb3" ++
        "\xc0\x6e\x51\xc1\x3c\xae\x4d\x54\x13\x69\x1e\x52\x9a\xaf\x2c\x00\x2b\x00\x03\x02\x03" ++
        "\x04\x00\x0d\x00\x20\x00\x1e\x04\x03\x05\x03\x06\x03\x02\x03\x08\x04\x08\x05\x08\x06" ++
        "\x04\x01\x05\x01\x06\x01\x02\x01\x04\x02\x05\x02\x06\x02\x02\x02\x00\x2d\x00\x02\x01" ++
        "\x01\x00\x1c\x00\x02\x40\x01";
    const server_hello_bytes =
        "\x02\x00\x00\x56\x03\x03\xa6\xaf\x06\xa4\x12\x18\x60\xdc\x5e\x6e\x60\x24\x9c\xd3\x4c" ++
        "\x95\x93\x0c\x8a\xc5\xcb\x14\x34\xda\xc1\x55\x77\x2e\xd3\xe2\x69\x28\x00\x13\x01\x00" ++
        "\x00\x2e\x00\x33\x00\x24\x00\x1d\x00\x20\xc9\x82\x88\x76\x11\x20\x95\xfe\x66\x76\x2b" ++
        "\xdb\xf7\xc6\x72\xe1\x56\xd6\xcc\x25\x3b\x83\x3d\xf1\xdd\x69\xb1\xb0\x4e\x75\x1f\x0f" ++
        "\x00\x2b\x00\x02\x03\x04";
    const message = client_hello_bytes ++ server_hello_bytes;
    var client_handshake_traffic_secret: [Sha256.digest_length]u8 = undefined;
    deriveSecret(
        &client_handshake_traffic_secret,
        handshake_secret.*,
        "c hs traffic",
        message,
    );
    try testing.expectFmt(
        "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21",
        "{s}",
        .{fmt.fmtSliceHexLower(&client_handshake_traffic_secret)},
    );
}

test "deriveInitialKeys - RFC 9001 test vectors" {
    const dcid = [_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 };
    const keys = deriveInitialKeys(&dcid);

    // Client initial key
    try testing.expectFmt(
        "1f369613dd76d5467730efcbe3b1a22d",
        "{s}",
        .{fmt.fmtSliceHexLower(&keys.client.key)},
    );

    // Client IV
    try testing.expectFmt(
        "fa044b2f42a3fd3b46fb255c",
        "{s}",
        .{fmt.fmtSliceHexLower(&keys.client.iv)},
    );

    // Client HP key
    try testing.expectFmt(
        "9f50449e04a0e810283a1e9933adedd2",
        "{s}",
        .{fmt.fmtSliceHexLower(&keys.client.hp)},
    );

    // Server initial key
    try testing.expectFmt(
        "cf3a5331653c364c88f0f379b6067e37",
        "{s}",
        .{fmt.fmtSliceHexLower(&keys.server.key)},
    );

    // Server IV
    try testing.expectFmt(
        "0ac1493ca1905853b0bba03e",
        "{s}",
        .{fmt.fmtSliceHexLower(&keys.server.iv)},
    );

    // Server HP key
    try testing.expectFmt(
        "c206b8d9b9f0f37644430b490eeaa314",
        "{s}",
        .{fmt.fmtSliceHexLower(&keys.server.hp)},
    );
}

test "encryptPacket - RFC 9001 client initial" {
    var header_array = [_]u8{0} ** 256;
    const header = try fmt.hexToBytes(
        &header_array,
        "c300000001088394c8f03e5157080000449e00000002",
    );
    var payload_array = [_]u8{0} ** 2048;
    // zig fmt: off
    _ = try fmt.hexToBytes(
        &payload_array,
        "060040f1010000ed0303ebf8fa56f129" ++ "39b9584a3896472ec40bb863cfd3e868" ++
        "04fe3a47f06a2b69484c000004130113" ++ "02010000c000000010000e00000b6578" ++
        "616d706c652e636f6dff01000100000a" ++ "00080006001d00170018001000070005" ++
        "04616c706e0005000501000000000033" ++ "00260024001d00209370b2c9caa47fba" ++
        "baf4559fedba753de171fa71f50f1ce1" ++ "5d43e994ec74d748002b000302030400" ++
        "0d0010000e0403050306030203080408" ++ "050806002d00020101001c0002400100" ++
        "3900320408ffffffffffffffff050480" ++ "00ffff07048000ffff08011001048000" ++
        "75300901100f088394c8f03e51570806" ++ "048000ffff",
    );
    // zig fmt: on

    const payload = payload_array[0..1162];

    const client_key = "\x1f\x36\x96\x13\xdd\x76\xd5\x46\x77\x30\xef\xcb\xe3\xb1\xa2\x2d".*;
    const client_iv = "\xfa\x04\x4b\x2f\x42\xa3\xfd\x3b\x46\xfb\x25\x5c".*;
    const client_hp = "\x9f\x50\x44\x9e\x04\xa0\xe8\x10\x28\x3a\x1e\x99\x33\xad\xed\xd2".*;

    const encrypted = try encryptPacket(
        header,
        payload,
        client_key,
        client_iv,
        client_hp,
        testing.allocator,
        false,
    );
    defer encrypted.deinit();

    // Verify first 16 bytes of encrypted packet match RFC 9001 test vector
    try testing.expectFmt(
        "c000000001088394c8f03e5157080000",
        "{s}",
        .{fmt.fmtSliceHexLower(encrypted.items[0..16])},
    );
}

test "decryptPacket - RFC 9001 server initial" {
    var header = [_]u8{0} ** 18;
    _ = try fmt.hexToBytes(&header, "cf000000010008f067a5502a4262b5004075");
    var payload = [_]u8{0} ** 117;
    // zig fmt: off
    _ = try fmt.hexToBytes(
        &payload,
        "c0d95a482cd0991cd25b0aac406a" ++
        "5816b6394100f37a1c69797554780bb3" ++ "8cc5a99f5ede4cf73c3ec2493a1839b3" ++
        "dbcba3f6ea46c5b7684df3548e7ddeb9" ++ "c3bf9c73cc3f3bded74b562bfb19fb84" ++
        "022f8ef4cdd93795d77d06edbb7aaf2f" ++ "58891850abbdca3d20398c276456cbc4" ++
        "2158407dd074ee",
    );
    // zig fmt: on

    const server_key = "\xcf\x3a\x53\x31\x65\x3c\x36\x4c\x88\xf0\xf3\x79\xb6\x06\x7e\x37".*;
    const server_iv = "\x0a\xc1\x49\x3c\xa1\x90\x58\x53\xb0\xbb\xa0\x3e".*;
    const server_hp = "\xc2\x06\xb8\xd9\xb9\xf0\xf3\x76\x44\x43\x0b\x49\x0e\xea\xa3\x14".*;

    var decrypted = try decryptPacket(
        &header,
        &payload,
        server_key,
        server_iv,
        server_hp,
        testing.allocator,
        false,
    );
    defer decrypted.deinit();

    // Verify the decrypted header starts with unprotected first byte
    try testing.expectFmt(
        "c1000000010008f067a5502a4262b50040750001",
        "{s}",
        .{fmt.fmtSliceHexLower(decrypted.items[0..20])},
    );
}

test "QuicKeys.deriveFromSecret" {
    // RFC 9001 client initial secret → key, iv, hp
    var secret: [32]u8 = undefined;
    _ = try fmt.hexToBytes(&secret, "c00cf151ca5be075ed0ebfb5c80323c42d6b7db67881289af4008f1f6c357aea");

    const keys = QuicKeys.deriveFromSecret(secret);

    try testing.expectFmt(
        "1f369613dd76d5467730efcbe3b1a22d",
        "{s}",
        .{fmt.fmtSliceHexLower(&keys.key)},
    );
    try testing.expectFmt(
        "fa044b2f42a3fd3b46fb255c",
        "{s}",
        .{fmt.fmtSliceHexLower(&keys.iv)},
    );
    try testing.expectFmt(
        "9f50449e04a0e810283a1e9933adedd2",
        "{s}",
        .{fmt.fmtSliceHexLower(&keys.hp)},
    );
}

test "deriveHpMask produces deterministic output" {
    const hp_key = [_]u8{0x42} ** 16;
    const sample = [_]u8{0x69} ** 16;
    const mask1 = deriveHpMask(hp_key, sample);
    const mask2 = deriveHpMask(hp_key, sample);
    try testing.expectEqual(mask1, mask2);
    // Mask should not be all zeros
    var all_zero = true;
    for (mask1) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);
}

test "AEAD encrypt then decrypt round-trip" {
    const key = [_]u8{0x69} ** 16;
    const nonce = [_]u8{0x42} ** 12;
    const plaintext = "Hello, QUIC!";
    const ad = "associated data";

    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [Aes128Gcm.tag_length]u8 = undefined;
    Aes128Gcm.encrypt(&ciphertext, &tag, plaintext, ad, nonce, key);

    var decrypted: [plaintext.len]u8 = undefined;
    try Aes128Gcm.decrypt(&decrypted, &ciphertext, tag, ad, nonce, key);
    try testing.expectEqualStrings(plaintext, &decrypted);
}
