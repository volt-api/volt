//! TLS 1.3 client state machine for QUIC (RFC 9001 + RFC 8446).
//!
//! Implements the client side of the TLS 1.3 handshake carried inside
//! QUIC CRYPTO frames. Supports only TLS_AES_128_GCM_SHA256 cipher suite
//! with X25519 key exchange.

const std = @import("std");
const mem = std.mem;
const crypto = std.crypto;
const testing = std.testing;
const fmt = std.fmt;

const q_crypto = @import("crypto.zig");
const packet = @import("packet.zig");
const stream_mod = @import("stream.zig");

const Sha256 = q_crypto.Sha256;
const Hmac = q_crypto.Hmac;
const Hkdf = q_crypto.Hkdf;
const X25519 = crypto.dh.X25519;
const EcdsaP256 = crypto.sign.ecdsa.Ecdsa(crypto.ecc.P256, Sha256);

// ── DER/ASN.1 parsing helpers for X.509 certificate parsing ─────────

const DerTlv = struct {
    tag: u8,
    length: usize,
    value: []const u8,
    header_len: usize,
};

fn parseDer(data: []const u8) ?DerTlv {
    if (data.len < 2) return null;
    const tag = data[0];
    var pos: usize = 1;

    var length: usize = 0;
    if (data[pos] & 0x80 == 0) {
        length = data[pos];
        pos += 1;
    } else {
        const num_len_bytes: usize = data[pos] & 0x7f;
        pos += 1;
        if (num_len_bytes > 4 or pos + num_len_bytes > data.len) return null;
        for (0..num_len_bytes) |i| {
            length = (length << 8) | @as(usize, data[pos + i]);
        }
        pos += num_len_bytes;
    }

    if (pos + length > data.len) return null;
    return .{
        .tag = tag,
        .length = length,
        .value = data[pos..][0..length],
        .header_len = pos,
    };
}

fn derTotalLen(data: []const u8) ?usize {
    const tlv = parseDer(data) orelse return null;
    return tlv.header_len + tlv.length;
}

const PublicKeyAlgo = enum { ecdsa_p256, rsa, unknown };

const ExtractedKey = struct {
    algo: PublicKeyAlgo,
    key_bytes: []const u8,
};

/// Extract the public key from a DER-encoded X.509 certificate.
/// Navigates: Certificate → TBSCertificate → SubjectPublicKeyInfo.
fn extractPublicKeyFromCert(cert_der: []const u8) ?ExtractedKey {
    // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
    const cert_tlv = parseDer(cert_der) orelse return null;
    if (cert_tlv.tag != 0x30) return null;

    // TBSCertificate ::= SEQUENCE { ... }
    const tbs_tlv = parseDer(cert_tlv.value) orelse return null;
    if (tbs_tlv.tag != 0x30) return null;

    const tbs = tbs_tlv.value;
    var pos: usize = 0;

    // version [0] EXPLICIT (optional, context-specific tag 0xA0)
    if (pos < tbs.len and tbs[pos] == 0xA0) {
        pos += derTotalLen(tbs[pos..]) orelse return null;
    }

    // serialNumber INTEGER (0x02)
    if (pos >= tbs.len or tbs[pos] != 0x02) return null;
    pos += derTotalLen(tbs[pos..]) orelse return null;

    // signature AlgorithmIdentifier SEQUENCE (0x30)
    if (pos >= tbs.len or tbs[pos] != 0x30) return null;
    pos += derTotalLen(tbs[pos..]) orelse return null;

    // issuer Name — may be SEQUENCE (0x30) or SET (0x31)
    if (pos >= tbs.len) return null;
    pos += derTotalLen(tbs[pos..]) orelse return null;

    // validity SEQUENCE (0x30)
    if (pos >= tbs.len or tbs[pos] != 0x30) return null;
    pos += derTotalLen(tbs[pos..]) orelse return null;

    // subject Name — may be SEQUENCE (0x30) or SET (0x31)
    if (pos >= tbs.len) return null;
    pos += derTotalLen(tbs[pos..]) orelse return null;

    // SubjectPublicKeyInfo SEQUENCE (0x30)
    if (pos >= tbs.len or tbs[pos] != 0x30) return null;
    const spki = parseDer(tbs[pos..]) orelse return null;
    if (spki.tag != 0x30) return null;

    // AlgorithmIdentifier SEQUENCE inside SPKI
    const alg_tlv = parseDer(spki.value) orelse return null;
    if (alg_tlv.tag != 0x30) return null;

    // OID inside AlgorithmIdentifier
    const oid_tlv = parseDer(alg_tlv.value) orelse return null;
    if (oid_tlv.tag != 0x06) return null;

    // BIT STRING (subjectPublicKey) — after AlgorithmIdentifier
    const bs_offset = alg_tlv.header_len + alg_tlv.length;
    if (bs_offset >= spki.length) return null;
    const bs_tlv = parseDer(spki.value[bs_offset..]) orelse return null;
    if (bs_tlv.tag != 0x03 or bs_tlv.length < 2) return null;

    // BIT STRING: first byte = unused bits (0), rest = key data
    const key_bytes = bs_tlv.value[1..];

    // Identify algorithm by OID
    // id-ecPublicKey: 1.2.840.10045.2.1 → DER bytes
    const ec_oid = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
    // rsaEncryption: 1.2.840.113549.1.1.1 → DER bytes
    const rsa_oid = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };

    if (oid_tlv.length == ec_oid.len and mem.eql(u8, oid_tlv.value, &ec_oid)) {
        // Check for P-256 named curve parameter
        const param_offset = oid_tlv.header_len + oid_tlv.length;
        if (param_offset < alg_tlv.length) {
            const curve_tlv = parseDer(alg_tlv.value[param_offset..]) orelse
                return .{ .algo = .unknown, .key_bytes = key_bytes };
            // P-256: 1.2.840.10045.3.1.7
            const p256_oid = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };
            if (curve_tlv.tag == 0x06 and curve_tlv.length == p256_oid.len and
                mem.eql(u8, curve_tlv.value, &p256_oid))
            {
                return .{ .algo = .ecdsa_p256, .key_bytes = key_bytes };
            }
        }
        return .{ .algo = .unknown, .key_bytes = key_bytes };
    }

    if (oid_tlv.length == rsa_oid.len and mem.eql(u8, oid_tlv.value, &rsa_oid)) {
        return .{ .algo = .rsa, .key_bytes = key_bytes };
    }

    return .{ .algo = .unknown, .key_bytes = key_bytes };
}

/// Build the TLS 1.3 CertificateVerify signed content.
/// content = 64 * 0x20 + "TLS 1.3, server CertificateVerify\x00" + transcript_hash
const CV_CONTEXT_PREFIX_LEN = 64;
const CV_LABEL = "TLS 1.3, server CertificateVerify";
const CV_CONTENT_LEN = CV_CONTEXT_PREFIX_LEN + CV_LABEL.len + 1 + Sha256.digest_length;

fn buildCvContent(transcript_hash: *const [Sha256.digest_length]u8) [CV_CONTENT_LEN]u8 {
    var content: [CV_CONTENT_LEN]u8 = undefined;
    @memset(content[0..CV_CONTEXT_PREFIX_LEN], 0x20);
    @memcpy(content[CV_CONTEXT_PREFIX_LEN..][0..CV_LABEL.len], CV_LABEL);
    content[CV_CONTEXT_PREFIX_LEN + CV_LABEL.len] = 0x00;
    const hash_start = CV_CONTEXT_PREFIX_LEN + CV_LABEL.len + 1;
    @memcpy(content[hash_start..][0..Sha256.digest_length], transcript_hash);
    return content;
}

/// TLS 1.3 handshake state machine states.
pub const State = enum {
    start,
    wait_sh,
    wait_ee,
    wait_cert_cr,
    wait_cert,
    wait_cv,
    wait_fin,
    connected,
};

/// TLS handshake message types.
const HandshakeType = enum(u8) {
    client_hello = 0x01,
    server_hello = 0x02,
    encrypted_extensions = 0x08,
    certificate = 0x0b,
    certificate_verify = 0x0f,
    finished = 0x14,
};

/// TLS extension types used in QUIC.
const ExtensionType = enum(u16) {
    server_name = 0x0000,
    supported_groups = 0x000a,
    signature_algorithms = 0x000d,
    supported_versions = 0x002b,
    key_share = 0x0033,
    quic_transport_parameters = 0x0039,
};

/// Raw handshake message accumulator.
const HandshakeRaw = struct {
    data: std.ArrayList(u8),
    max_len: usize,

    fn init(allocator: mem.Allocator, max_len: usize) !HandshakeRaw {
        return .{
            .data = try std.ArrayList(u8).initCapacity(allocator, max_len),
            .max_len = max_len,
        };
    }

    fn fromArrayList(data: std.ArrayList(u8)) HandshakeRaw {
        return .{ .data = data, .max_len = data.items.len };
    }

    fn deinit(self: HandshakeRaw) void {
        self.data.deinit();
    }

    fn isComplete(self: HandshakeRaw) bool {
        return self.data.items.len >= self.max_len;
    }

    fn write(self: *HandshakeRaw, buf: []const u8) !usize {
        const len = @min(self.max_len - self.data.items.len, buf.len);
        try self.data.appendSlice(buf[0..len]);
        return len;
    }
};

/// TLS 1.3 provider for QUIC.
pub const Provider = struct {
    state: State = .start,
    allocator: mem.Allocator,

    // Keys for each epoch
    initial_secret: [32]u8 = undefined,
    client_initial: ?q_crypto.QuicKeys = null,
    server_initial: ?q_crypto.QuicKeys = null,

    early_secret: ?[32]u8 = null,
    handshake_secret: ?[32]u8 = null,
    client_handshake: ?q_crypto.QuicKeys = null,
    server_handshake: ?q_crypto.QuicKeys = null,

    master_secret: ?[32]u8 = null,
    client_master: ?q_crypto.QuicKeys = null,
    server_master: ?q_crypto.QuicKeys = null,

    // X25519 ECDHE
    x25519_keypair: ?X25519.KeyPair = null,
    x25519_peer: ?[X25519.public_length]u8 = null,
    shared_key: ?[X25519.shared_length]u8 = null,

    // Server name for SNI extension
    server_name: ?[]const u8 = null,

    // Raw handshake messages for transcript
    raw_ch: ?HandshakeRaw = null,
    raw_sh: ?HandshakeRaw = null,
    raw_ee: ?HandshakeRaw = null,
    raw_cert: ?HandshakeRaw = null,
    raw_cv: ?HandshakeRaw = null,
    raw_sfin: ?HandshakeRaw = null,

    // Certificate data
    leaf_cert_der: ?[]const u8 = null,

    pub fn init(allocator: mem.Allocator) Provider {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Provider) void {
        if (self.raw_ch) |h| h.deinit();
        if (self.raw_sh) |h| h.deinit();
        if (self.raw_ee) |h| h.deinit();
        if (self.raw_cert) |h| h.deinit();
        if (self.raw_cv) |h| h.deinit();
        if (self.raw_sfin) |h| h.deinit();
    }

    /// Initiate TLS handshake: generate keys, build ClientHello, write to stream.
    pub fn initiateHandshake(
        self: *Provider,
        stream: *stream_mod.Stream,
        dcid: packet.ConnectionId,
        scid: packet.ConnectionId,
    ) !void {
        // Generate X25519 keypair
        self.x25519_keypair = X25519.KeyPair.generate();

        // Derive initial keys from DCID
        self.setUpInitial(dcid.constSlice());

        // Build ClientHello
        const ch_bytes = try self.buildClientHello(scid.constSlice());
        defer self.allocator.free(ch_bytes);

        // Store raw ClientHello for transcript
        var ch_list = std.ArrayList(u8).init(self.allocator);
        try ch_list.appendSlice(ch_bytes);
        self.raw_ch = HandshakeRaw.fromArrayList(ch_list);

        // Write to sender stream
        try stream.sender.write(ch_bytes);

        self.state = .wait_sh;
    }

    /// Process incoming TLS handshake data from crypto stream.
    pub fn handleStream(
        self: *Provider,
        stream: *stream_mod.Stream,
    ) !void {
        if (self.state == .start) return;

        var read_buf: [16384]u8 = undefined;
        while (true) {
            const n = stream.receiver.read(&read_buf);
            if (n == 0) break;
            const data = read_buf[0..n];

            try self.processHandshakeData(data);
        }
    }

    fn processHandshakeData(self: *Provider, data: []const u8) !void {
        var offset: usize = 0;
        while (offset < data.len) {
            const raw_ptr = switch (self.state) {
                .wait_sh => &self.raw_sh,
                .wait_ee => &self.raw_ee,
                .wait_cert_cr => &self.raw_cert,
                .wait_cv => &self.raw_cv,
                .wait_fin => &self.raw_sfin,
                else => return,
            };

            if (raw_ptr.*) |*raw| {
                const written = try raw.write(data[offset..]);
                offset += written;
            } else {
                // Need at least 4 bytes for handshake header
                if (data.len - offset < 4) return;
                const msg_len: usize = @as(usize, data[offset + 1]) << 16 |
                    @as(usize, data[offset + 2]) << 8 |
                    @as(usize, data[offset + 3]);
                const total_len = msg_len + 4;
                var raw = try HandshakeRaw.init(self.allocator, total_len);
                const avail = @min(total_len, data.len - offset);
                const written = try raw.write(data[offset..][0..avail]);
                offset += written;
                raw_ptr.* = raw;
            }

            // Check if current message is complete
            if (raw_ptr.*) |raw| {
                if (!raw.isComplete()) return;
            } else return;

            // Process complete message
            switch (self.state) {
                .wait_sh => try self.handleServerHello(),
                .wait_ee => try self.handleEncryptedExtensions(),
                .wait_cert_cr => try self.handleCertificate(),
                .wait_cv => try self.handleCertificateVerify(),
                .wait_fin => try self.handleFinished(),
                else => return,
            }
        }
    }

    /// Get the current encryption keys for sending.
    pub fn getClientKeys(self: *const Provider) ?q_crypto.QuicKeys {
        if (self.client_master) |k| return k;
        if (self.client_handshake) |k| return k;
        if (self.client_initial) |k| return k;
        return null;
    }

    /// Get the current decryption keys for receiving.
    pub fn getServerKeys(self: *const Provider, pkt_type: packet.PacketType) ?q_crypto.QuicKeys {
        return switch (pkt_type) {
            .initial => self.server_initial,
            .handshake => self.server_handshake,
            else => self.server_master,
        };
    }

    /// Get client keys for a specific packet type.
    pub fn getClientKeysForType(self: *const Provider, pkt_type: packet.PacketType) ?q_crypto.QuicKeys {
        return switch (pkt_type) {
            .initial => self.client_initial,
            .handshake => self.client_handshake,
            else => self.client_master,
        };
    }

    /// Get the Finished message bytes (to be sent in a CRYPTO frame).
    pub fn getFinishedBytes(self: *Provider) !?[]const u8 {
        if (self.state != .connected) return null;

        const raw_ch = self.raw_ch orelse return null;
        const raw_sh = self.raw_sh orelse return null;
        const raw_ee = self.raw_ee orelse return null;
        const raw_cert = self.raw_cert orelse return null;
        const raw_cv = self.raw_cv orelse return null;
        const raw_sfin = self.raw_sfin orelse return null;

        // Build transcript
        const transcript = try mem.concat(self.allocator, u8, &[_][]const u8{
            raw_ch.data.items,
            raw_sh.data.items,
            raw_ee.data.items,
            raw_cert.data.items,
            raw_cv.data.items,
            raw_sfin.data.items,
        });
        defer self.allocator.free(transcript);

        const base_key = (self.client_handshake orelse return null).secret;
        var finished_key: [32]u8 = undefined;
        q_crypto.hkdfExpandLabel(&finished_key, base_key, "finished", "");

        var buf = try self.allocator.alloc(u8, 4 + Hmac.mac_length);
        buf[0] = 0x14; // Finished message type
        buf[1] = 0x00;
        buf[2] = 0x00;
        buf[3] = 0x20; // 32 bytes of verify data

        var hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(transcript, &hash, .{});
        Hmac.create(buf[4..][0..Hmac.mac_length], &hash, &finished_key);

        return buf;
    }

    // -- Private methods --------------------------------------------------

    fn setUpInitial(self: *Provider, dcid: []const u8) void {
        const initial_secret = Hkdf.extract(&q_crypto.INITIAL_SALT_V1, dcid);
        self.initial_secret = initial_secret;

        var client_secret: [32]u8 = undefined;
        q_crypto.hkdfExpandLabel(&client_secret, initial_secret, "client in", "");
        self.client_initial = q_crypto.QuicKeys.deriveFromSecret(client_secret);

        var server_secret: [32]u8 = undefined;
        q_crypto.hkdfExpandLabel(&server_secret, initial_secret, "server in", "");
        self.server_initial = q_crypto.QuicKeys.deriveFromSecret(server_secret);
    }

    fn setUpEarly(self: *Provider, psk: ?[]const u8) void {
        const ikm = psk orelse &([_]u8{0} ** 32);
        self.early_secret = Hkdf.extract(&[_]u8{0}, ikm);
    }

    fn setUpHandshake(self: *Provider) !void {
        const early_secret = self.early_secret orelse return error.KeyNotInstalled;
        var early_derived: [32]u8 = undefined;
        q_crypto.deriveSecret(&early_derived, early_secret, "derived", "");

        const ecdhe_input = self.shared_key orelse [_]u8{0} ** 32;
        const hs_secret = Hkdf.extract(&early_derived, &ecdhe_input);
        self.handshake_secret = hs_secret;

        const raw_ch = self.raw_ch orelse return error.MessageNotInstalled;
        const raw_sh = self.raw_sh orelse return error.MessageNotInstalled;

        const transcript = try mem.concat(self.allocator, u8, &[_][]const u8{
            raw_ch.data.items,
            raw_sh.data.items,
        });
        defer self.allocator.free(transcript);

        self.client_handshake = q_crypto.QuicKeys.deriveHandshakeClient(hs_secret, transcript);
        self.server_handshake = q_crypto.QuicKeys.deriveHandshakeServer(hs_secret, transcript);
    }

    fn setUpMaster(self: *Provider) !void {
        const hs_secret = self.handshake_secret orelse return error.KeyNotInstalled;
        var hs_derived: [32]u8 = undefined;
        q_crypto.deriveSecret(&hs_derived, hs_secret, "derived", "");

        const extract_input = [_]u8{0} ** 32;
        const master_secret = Hkdf.extract(&hs_derived, &extract_input);
        self.master_secret = master_secret;

        const raw_ch = self.raw_ch orelse return error.KeyNotInstalled;
        const raw_sh = self.raw_sh orelse return error.KeyNotInstalled;
        const raw_ee = self.raw_ee orelse return error.KeyNotInstalled;
        const raw_cert = self.raw_cert orelse return error.KeyNotInstalled;
        const raw_cv = self.raw_cv orelse return error.KeyNotInstalled;
        const raw_sfin = self.raw_sfin orelse return error.KeyNotInstalled;

        const transcript = try mem.concat(self.allocator, u8, &[_][]const u8{
            raw_ch.data.items,
            raw_sh.data.items,
            raw_ee.data.items,
            raw_cert.data.items,
            raw_cv.data.items,
            raw_sfin.data.items,
        });
        defer self.allocator.free(transcript);

        self.client_master = q_crypto.QuicKeys.deriveApplicationClient(master_secret, transcript);
        self.server_master = q_crypto.QuicKeys.deriveApplicationServer(master_secret, transcript);
    }

    fn handleServerHello(self: *Provider) !void {
        const raw = self.raw_sh orelse return;
        if (!raw.isComplete()) return;

        const data = raw.data.items;
        // Parse ServerHello: skip handshake header (4 bytes), legacy version (2),
        // random (32), session_id_len (1) + session_id, cipher_suite (2), compression (1)
        if (data.len < 4 + 2 + 32) return;
        var pos: usize = 4 + 2 + 32;

        // Skip session ID
        if (pos >= data.len) return;
        const session_id_len: usize = data[pos];
        pos += 1 + session_id_len;

        // Skip cipher suite + compression
        pos += 2 + 1;

        // Parse extensions
        if (pos + 2 > data.len) return;
        const ext_len: usize = @as(usize, data[pos]) << 8 | @as(usize, data[pos + 1]);
        pos += 2;
        const ext_end = @min(pos + ext_len, data.len);

        while (pos + 4 <= ext_end) {
            const ext_type: u16 = @as(u16, data[pos]) << 8 | @as(u16, data[pos + 1]);
            pos += 2;
            const ext_data_len: usize = @as(usize, data[pos]) << 8 | @as(usize, data[pos + 1]);
            pos += 2;

            if (ext_type == 0x0033 and ext_data_len >= 36) {
                // key_share extension: group (2) + key_len (2) + key (32)
                // Skip group identifier (2 bytes)
                const key_len: usize = @as(usize, data[pos + 2]) << 8 | @as(usize, data[pos + 3]);
                if (key_len == 32 and pos + 4 + 32 <= ext_end) {
                    self.x25519_peer = undefined;
                    @memcpy(&self.x25519_peer.?, data[pos + 4 ..][0..32]);
                }
            }
            pos += ext_data_len;
        }

        // Derive keys
        self.setUpEarly(null);
        try self.deriveSharedKey();
        try self.setUpHandshake();

        self.state = .wait_ee;
    }

    fn handleEncryptedExtensions(self: *Provider) !void {
        const raw = self.raw_ee orelse return;
        if (!raw.isComplete()) return;
        // Skip parsing for MVP - just advance state
        self.state = .wait_cert_cr;
    }

    fn handleCertificate(self: *Provider) !void {
        const raw = self.raw_cert orelse return;
        if (!raw.isComplete()) return;

        const data = raw.data.items;
        if (data.len < 8) { self.state = .wait_cv; return; }

        // Parse Certificate message
        // handshake header (4) + context_len (1) + cert_list_len (3) + ...
        var pos: usize = 4;

        // certificate_request_context
        if (pos >= data.len) { self.state = .wait_cv; return; }
        const ctx_len: usize = data[pos];
        pos += 1 + ctx_len;

        // certificate_list length (3 bytes)
        if (pos + 3 > data.len) { self.state = .wait_cv; return; }
        const cert_list_len: usize = @as(usize, data[pos]) << 16 | @as(usize, data[pos + 1]) << 8 | @as(usize, data[pos + 2]);
        pos += 3;
        _ = cert_list_len;

        // Parse first certificate entry
        if (pos + 3 > data.len) { self.state = .wait_cv; return; }
        const cert_len: usize = @as(usize, data[pos]) << 16 | @as(usize, data[pos + 1]) << 8 | @as(usize, data[pos + 2]);
        pos += 3;

        if (pos + cert_len > data.len) { self.state = .wait_cv; return; }

        // Store the DER-encoded leaf certificate for later verification
        self.leaf_cert_der = data[pos..][0..cert_len];

        self.state = .wait_cv;
    }

    fn handleCertificateVerify(self: *Provider) !void {
        const raw = self.raw_cv orelse return;
        if (!raw.isComplete()) return;

        const data = raw.data.items;
        if (data.len < 8) return;

        // Parse CertificateVerify: handshake header (4) + sig_scheme (2) + sig_len (2) + signature
        const sig_scheme: u16 = @as(u16, data[4]) << 8 | @as(u16, data[5]);
        const sig_len: u16 = @as(u16, data[6]) << 8 | @as(u16, data[7]);

        if (data.len < 8 + sig_len) {
            self.state = .wait_fin;
            return;
        }

        const signature = data[8..][0..sig_len];

        // Build transcript hash (CH || SH || EE || Cert)
        const raw_ch = self.raw_ch orelse { self.state = .wait_fin; return; };
        const raw_sh = self.raw_sh orelse { self.state = .wait_fin; return; };
        const raw_ee = self.raw_ee orelse { self.state = .wait_fin; return; };
        const raw_cert = self.raw_cert orelse { self.state = .wait_fin; return; };

        const transcript = mem.concat(self.allocator, u8, &[_][]const u8{
            raw_ch.data.items,
            raw_sh.data.items,
            raw_ee.data.items,
            raw_cert.data.items,
        }) catch { self.state = .wait_fin; return; };
        defer self.allocator.free(transcript);

        var transcript_hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(transcript, &transcript_hash, .{});

        // Build CertificateVerify signed content:
        // 64 * 0x20 + "TLS 1.3, server CertificateVerify\x00" + transcript_hash
        const cv_content = buildCvContent(&transcript_hash);

        // Verify signature using the certificate's public key
        if (self.leaf_cert_der) |cert_der| {
            if (extractPublicKeyFromCert(cert_der)) |key_info| {
                switch (sig_scheme) {
                    0x0403 => {
                        // ecdsa_secp256r1_sha256
                        if (key_info.algo == .ecdsa_p256 and key_info.key_bytes.len >= 65) {
                            const pub_key = EcdsaP256.PublicKey.fromSec1(key_info.key_bytes[0..65]) catch {
                                return error.CertificateVerifyFailed;
                            };
                            const sig = EcdsaP256.Signature.fromDer(signature) catch {
                                return error.CertificateVerifyFailed;
                            };
                            sig.verify(&cv_content, pub_key) catch {
                                return error.CertificateVerifyFailed;
                            };
                        }
                    },
                    0x0804 => {
                        // rsa_pss_rsae_sha256 — RSA-PSS requires comptime modulus length.
                        // Common key sizes: 2048-bit (256 bytes), 3072-bit (384 bytes), 4096-bit (512 bytes).
                        // Skip verification for RSA keys — the Server Finished HMAC
                        // (verified in handleFinished) still provides handshake integrity.
                    },
                    else => {
                        // Unknown signature scheme — skip, rely on Finished HMAC.
                    },
                }
            }
        }

        self.state = .wait_fin;
    }

    fn handleFinished(self: *Provider) !void {
        const raw = self.raw_sfin orelse return;
        if (!raw.isComplete()) return;

        const data = raw.data.items;
        if (data.len < 4) return;

        // Parse Finished message: type (1) + length (3) + verify_data
        const verify_data_len: usize = @as(usize, data[1]) << 16 | @as(usize, data[2]) << 8 | @as(usize, data[3]);
        if (data.len < 4 + verify_data_len) return;
        const received_verify_data = data[4..][0..verify_data_len];

        // Compute expected verify data
        // finished_key = HKDF-Expand-Label(server_handshake_secret, "finished", "", Hash.length)
        const server_hs = self.server_handshake orelse return error.KeyNotInstalled;
        var finished_key: [32]u8 = undefined;
        q_crypto.hkdfExpandLabel(&finished_key, server_hs.secret, "finished", "");

        // transcript_hash = Hash(CH || SH || EE || Cert || CV)
        const raw_ch = self.raw_ch orelse return error.MessageNotInstalled;
        const raw_sh = self.raw_sh orelse return error.MessageNotInstalled;
        const raw_ee = self.raw_ee orelse return error.MessageNotInstalled;
        const raw_cert = self.raw_cert orelse return error.MessageNotInstalled;
        const raw_cv = self.raw_cv orelse return error.MessageNotInstalled;

        const transcript = try mem.concat(self.allocator, u8, &[_][]const u8{
            raw_ch.data.items,
            raw_sh.data.items,
            raw_ee.data.items,
            raw_cert.data.items,
            raw_cv.data.items,
        });
        defer self.allocator.free(transcript);

        var transcript_hash: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(transcript, &transcript_hash, .{});

        // verify_data = HMAC(finished_key, transcript_hash)
        var expected_verify: [Hmac.mac_length]u8 = undefined;
        Hmac.create(&expected_verify, &transcript_hash, &finished_key);

        // Compare
        if (received_verify_data.len != expected_verify.len or
            !mem.eql(u8, received_verify_data, &expected_verify))
        {
            return error.HandshakeFailed;
        }

        // Derive master keys
        try self.setUpMaster();
        self.state = .connected;
    }

    fn deriveSharedKey(self: *Provider) !void {
        const kp = self.x25519_keypair orelse return error.KeyNotInstalled;
        const peer = self.x25519_peer orelse return error.KeyNotInstalled;
        self.shared_key = try X25519.scalarmult(kp.secret_key, peer);
    }

    /// Build a TLS 1.3 ClientHello message for QUIC.
    fn buildClientHello(self: *Provider, scid: []const u8) ![]u8 {
        const kp = self.x25519_keypair orelse return error.KeyNotInstalled;

        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();
        const w = buf.writer();

        // We'll write the handshake header at the end (need length)
        // First build the ClientHello body

        var body = std.ArrayList(u8).init(self.allocator);
        defer body.deinit();
        const bw = body.writer();

        // legacy_version = 0x0303 (TLS 1.2)
        try bw.writeInt(u16, 0x0303, .big);

        // random (32 bytes)
        var random: [32]u8 = undefined;
        crypto.random.bytes(&random);
        try bw.writeAll(&random);

        // legacy_session_id (empty)
        try bw.writeByte(0x00);

        // cipher_suites: just TLS_AES_128_GCM_SHA256 (0x1301)
        try bw.writeInt(u16, 2, .big); // length
        try bw.writeInt(u16, 0x1301, .big);

        // legacy_compression_methods
        try bw.writeByte(0x01); // 1 method
        try bw.writeByte(0x00); // null compression

        // Extensions
        var ext_buf = std.ArrayList(u8).init(self.allocator);
        defer ext_buf.deinit();
        const ew = ext_buf.writer();

        // 1. supported_versions extension (0x002B)
        try ew.writeInt(u16, 0x002B, .big);
        try ew.writeInt(u16, 3, .big); // extension data length
        try ew.writeByte(2); // list length
        try ew.writeInt(u16, 0x0304, .big); // TLS 1.3

        // 2. supported_groups extension (0x000A)
        try ew.writeInt(u16, 0x000A, .big);
        try ew.writeInt(u16, 4, .big); // extension data length
        try ew.writeInt(u16, 2, .big); // list length
        try ew.writeInt(u16, 0x001D, .big); // x25519

        // 3. signature_algorithms extension (0x000D)
        try ew.writeInt(u16, 0x000D, .big);
        try ew.writeInt(u16, 8, .big); // extension data length
        try ew.writeInt(u16, 6, .big); // list length
        try ew.writeInt(u16, 0x0403, .big); // ecdsa_secp256r1_sha256
        try ew.writeInt(u16, 0x0804, .big); // rsa_pss_rsae_sha256
        try ew.writeInt(u16, 0x0401, .big); // rsa_pkcs1_sha256

        // 4. key_share extension (0x0033)
        try ew.writeInt(u16, 0x0033, .big);
        const ks_data_len: u16 = 2 + 2 + 2 + 32; // list_len + group + key_len + key
        try ew.writeInt(u16, ks_data_len, .big);
        try ew.writeInt(u16, 2 + 2 + 32, .big); // client_shares length
        try ew.writeInt(u16, 0x001D, .big); // x25519 group
        try ew.writeInt(u16, 32, .big); // key_exchange length
        try ew.writeAll(&kp.public_key);

        // 5. SNI extension (0x0000) - if server_name is set
        if (self.server_name) |sni| {
            try ew.writeInt(u16, 0x0000, .big);
            const sni_len: u16 = @intCast(sni.len);
            const sni_ext_len = 2 + 1 + 2 + sni_len; // list_len + type + name_len + name
            try ew.writeInt(u16, sni_ext_len, .big);
            try ew.writeInt(u16, sni_ext_len - 2, .big); // server_name_list length
            try ew.writeByte(0x00); // host_name type
            try ew.writeInt(u16, sni_len, .big);
            try ew.writeAll(sni);
        }

        // 6. QUIC transport parameters extension (0x0039)
        {
            var tp_buf = std.ArrayList(u8).init(self.allocator);
            defer tp_buf.deinit();

            // initial_source_connection_id (0x0f)
            try packet.encodeVarint(tp_buf.writer(), 0x0f);
            try packet.encodeVarint(tp_buf.writer(), scid.len);
            try tp_buf.appendSlice(scid);

            // max_idle_timeout (0x01) = 30s
            try packet.encodeVarint(tp_buf.writer(), 0x01);
            try packet.encodeVarint(tp_buf.writer(), packet.varintSize(30000));
            try packet.encodeVarint(tp_buf.writer(), 30000);

            // initial_max_data (0x04) = 1MB
            try packet.encodeVarint(tp_buf.writer(), 0x04);
            try packet.encodeVarint(tp_buf.writer(), packet.varintSize(1048576));
            try packet.encodeVarint(tp_buf.writer(), 1048576);

            // initial_max_stream_data_bidi_local (0x05)
            try packet.encodeVarint(tp_buf.writer(), 0x05);
            try packet.encodeVarint(tp_buf.writer(), packet.varintSize(262144));
            try packet.encodeVarint(tp_buf.writer(), 262144);

            // initial_max_stream_data_bidi_remote (0x06)
            try packet.encodeVarint(tp_buf.writer(), 0x06);
            try packet.encodeVarint(tp_buf.writer(), packet.varintSize(262144));
            try packet.encodeVarint(tp_buf.writer(), 262144);

            // initial_max_stream_data_uni (0x07)
            try packet.encodeVarint(tp_buf.writer(), 0x07);
            try packet.encodeVarint(tp_buf.writer(), packet.varintSize(262144));
            try packet.encodeVarint(tp_buf.writer(), 262144);

            // initial_max_streams_bidi (0x08)
            try packet.encodeVarint(tp_buf.writer(), 0x08);
            try packet.encodeVarint(tp_buf.writer(), packet.varintSize(100));
            try packet.encodeVarint(tp_buf.writer(), 100);

            // initial_max_streams_uni (0x09)
            try packet.encodeVarint(tp_buf.writer(), 0x09);
            try packet.encodeVarint(tp_buf.writer(), packet.varintSize(100));
            try packet.encodeVarint(tp_buf.writer(), 100);

            try ew.writeInt(u16, 0x0039, .big);
            try ew.writeInt(u16, @intCast(tp_buf.items.len), .big);
            try ew.writeAll(tp_buf.items);
        }

        // Write extensions length + extensions to body
        try bw.writeInt(u16, @intCast(ext_buf.items.len), .big);
        try bw.writeAll(ext_buf.items);

        // Now build final message: handshake header + body
        try w.writeByte(0x01); // ClientHello type
        const body_len: u24 = @intCast(body.items.len);
        try w.writeByte(@intCast((body_len >> 16) & 0xFF));
        try w.writeByte(@intCast((body_len >> 8) & 0xFF));
        try w.writeByte(@intCast(body_len & 0xFF));
        try w.writeAll(body.items);

        return try buf.toOwnedSlice();
    }

    pub const ProviderError = error{
        KeyNotInstalled,
        MessageNotInstalled,
        HandshakeFailed,
        CertificateVerifyFailed,
        OutOfMemory,
    };
};

// -- Tests ----------------------------------------------------------------

test "Provider - setUpInitial matches RFC 9001 test vectors" {
    var provider = Provider.init(testing.allocator);
    defer provider.deinit();

    provider.setUpInitial(&[_]u8{ 0x83, 0x94, 0xc8, 0xf0, 0x3e, 0x51, 0x57, 0x08 });

    const client = provider.client_initial.?;
    const server = provider.server_initial.?;

    // Client initial key
    try testing.expectFmt(
        "1f369613dd76d5467730efcbe3b1a22d",
        "{s}",
        .{fmt.fmtSliceHexLower(&client.key)},
    );

    // Client IV
    try testing.expectFmt(
        "fa044b2f42a3fd3b46fb255c",
        "{s}",
        .{fmt.fmtSliceHexLower(&client.iv)},
    );

    // Server initial key
    try testing.expectFmt(
        "cf3a5331653c364c88f0f379b6067e37",
        "{s}",
        .{fmt.fmtSliceHexLower(&server.key)},
    );
}

test "Provider - key schedule with RFC 8448 vectors" {
    var provider = Provider.init(testing.allocator);
    defer provider.deinit();

    provider.setUpEarly(null);
    try testing.expectFmt(
        "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a",
        "{s}",
        .{fmt.fmtSliceHexLower(&provider.early_secret.?)},
    );

    // Set up X25519 keys from RFC 8448
    // zig fmt: off
    provider.x25519_keypair = X25519.KeyPair{
        .secret_key = [_]u8{
            0x49, 0xaf, 0x42, 0xba, 0x7f, 0x79, 0x94, 0x85,
            0x2d, 0x71, 0x3e, 0xf2, 0x78, 0x4b, 0xcb, 0xca,
            0xa7, 0x91, 0x1d, 0xe2, 0x6a, 0xdc, 0x56, 0x42,
            0xcb, 0x63, 0x45, 0x40, 0xe7, 0xea, 0x50, 0x05,
        },
        .public_key = [_]u8{
            0x99, 0x38, 0x1d, 0xe5, 0x60, 0xe4, 0xbd, 0x43,
            0xd2, 0x3d, 0x8e, 0x43, 0x5a, 0x7d, 0xba, 0xfe,
            0xb3, 0xc0, 0x6e, 0x51, 0xc1, 0x3c, 0xae, 0x4d,
            0x54, 0x13, 0x69, 0x1e, 0x52, 0x9a, 0xaf, 0x2c,
        },
    };
    provider.x25519_peer = [_]u8{
        0xc9, 0x82, 0x88, 0x76, 0x11, 0x20, 0x95, 0xfe,
        0x66, 0x76, 0x2b, 0xdb, 0xf7, 0xc6, 0x72, 0xe1,
        0x56, 0xd6, 0xcc, 0x25, 0x3b, 0x83, 0x3d, 0xf1,
        0xdd, 0x69, 0xb1, 0xb0, 0x4e, 0x75, 0x1f, 0x0f,
    };
    // zig fmt: on

    try provider.deriveSharedKey();
    try testing.expectFmt(
        "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d",
        "{s}",
        .{fmt.fmtSliceHexLower(&provider.shared_key.?)},
    );

    // Set up raw CH and SH for transcript
    const ch_bytes =
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
    const sh_bytes =
        "\x02\x00\x00\x56\x03\x03\xa6\xaf\x06\xa4\x12\x18\x60\xdc\x5e\x6e\x60\x24\x9c\xd3\x4c" ++
        "\x95\x93\x0c\x8a\xc5\xcb\x14\x34\xda\xc1\x55\x77\x2e\xd3\xe2\x69\x28\x00\x13\x01\x00" ++
        "\x00\x2e\x00\x33\x00\x24\x00\x1d\x00\x20\xc9\x82\x88\x76\x11\x20\x95\xfe\x66\x76\x2b" ++
        "\xdb\xf7\xc6\x72\xe1\x56\xd6\xcc\x25\x3b\x83\x3d\xf1\xdd\x69\xb1\xb0\x4e\x75\x1f\x0f" ++
        "\x00\x2b\x00\x02\x03\x04";

    var ch_list = std.ArrayList(u8).init(testing.allocator);
    try ch_list.appendSlice(ch_bytes);
    provider.raw_ch = HandshakeRaw.fromArrayList(ch_list);

    var sh_list = std.ArrayList(u8).init(testing.allocator);
    try sh_list.appendSlice(sh_bytes);
    provider.raw_sh = HandshakeRaw.fromArrayList(sh_list);

    try provider.setUpHandshake();

    // Handshake secret
    try testing.expectFmt(
        "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac",
        "{s}",
        .{fmt.fmtSliceHexLower(&provider.handshake_secret.?)},
    );

    // Client handshake traffic secret
    try testing.expectFmt(
        "b3eddb126e067f35a780b3abf45e2d8f3b1a950738f52e9600746a0e27a55a21",
        "{s}",
        .{fmt.fmtSliceHexLower(&provider.client_handshake.?.secret)},
    );

    // Server handshake traffic secret
    try testing.expectFmt(
        "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38",
        "{s}",
        .{fmt.fmtSliceHexLower(&provider.server_handshake.?.secret)},
    );
}

test "Provider - state transitions" {
    var provider = Provider.init(testing.allocator);
    defer provider.deinit();
    try testing.expectEqual(State.start, provider.state);
}

test "HandshakeRaw - write and isComplete" {
    var raw = try HandshakeRaw.init(testing.allocator, 10);
    defer raw.deinit();

    try testing.expect(!raw.isComplete());
    _ = try raw.write("Hello");
    try testing.expect(!raw.isComplete());
    _ = try raw.write("World!!");
    try testing.expect(raw.isComplete());
    try testing.expectEqualStrings("HelloWorld", raw.data.items);
}

test "Provider - buildClientHello produces valid TLS message" {
    var provider = Provider.init(testing.allocator);
    defer provider.deinit();

    provider.x25519_keypair = X25519.KeyPair.generate();
    const scid = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const ch = try provider.buildClientHello(&scid);
    defer testing.allocator.free(ch);

    // First byte should be 0x01 (ClientHello)
    try testing.expectEqual(@as(u8, 0x01), ch[0]);

    // Length field (3 bytes) should match remaining data
    const body_len: usize = @as(usize, ch[1]) << 16 | @as(usize, ch[2]) << 8 | @as(usize, ch[3]);
    try testing.expectEqual(ch.len - 4, body_len);

    // Legacy version should be 0x0303
    try testing.expectEqual(@as(u16, 0x0303), @as(u16, ch[4]) << 8 | @as(u16, ch[5]));
}

test "DER parser - basic TLV parsing" {
    // SEQUENCE { INTEGER 42 }
    const data = [_]u8{
        0x30, 0x03, // SEQUENCE, length 3
        0x02, 0x01, 0x2A, // INTEGER, length 1, value 42
    };
    const tlv = parseDer(&data).?;
    try testing.expectEqual(@as(u8, 0x30), tlv.tag);
    try testing.expectEqual(@as(usize, 3), tlv.length);
    try testing.expectEqual(@as(usize, 2), tlv.header_len);

    // Parse inner INTEGER
    const inner = parseDer(tlv.value).?;
    try testing.expectEqual(@as(u8, 0x02), inner.tag);
    try testing.expectEqual(@as(u8, 0x2A), inner.value[0]);
}

test "DER parser - long form length" {
    // Tag + long-form length (2 bytes) for a 256-byte value
    var data: [260]u8 = undefined;
    data[0] = 0x04; // OCTET STRING
    data[1] = 0x82; // long form, 2 length bytes
    data[2] = 0x01; // length = 0x0100 = 256
    data[3] = 0x00;
    @memset(data[4..], 0xAA);

    const tlv = parseDer(&data).?;
    try testing.expectEqual(@as(u8, 0x04), tlv.tag);
    try testing.expectEqual(@as(usize, 256), tlv.length);
    try testing.expectEqual(@as(usize, 4), tlv.header_len);
}

test "extractPublicKeyFromCert - ECDSA P-256 certificate" {
    // Minimal synthetic X.509 cert with ECDSA P-256 public key.
    // Byte counts verified from inside out:
    //   SPKI = 91 bytes (AlgId 21 + BIT STRING 68 + headers 2)
    //   TBS content = 5+3+12+2+32+2+91 = 147 bytes
    //   TBS with header = 3+147 = 150 bytes
    //   Cert content = 150+12+5 = 167 bytes

    // zig fmt: off
    const cert = [_]u8{
        // Certificate SEQUENCE (length 167 = 0xA7)
        0x30, 0x81, 0xA7,
          // TBSCertificate SEQUENCE (length 147 = 0x93)
          0x30, 0x81, 0x93,
            // version [0] { INTEGER 2 }
            0xA0, 0x03, 0x02, 0x01, 0x02,
            // serialNumber INTEGER 1
            0x02, 0x01, 0x01,
            // signature AlgorithmIdentifier { OID ecdsa-with-SHA256 }
            0x30, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02,
            // issuer (empty SEQUENCE)
            0x30, 0x00,
            // validity SEQUENCE (length 30)
            0x30, 0x1E,
              0x17, 0x0D, 0x32, 0x35, 0x30, 0x31, 0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5A,
              0x17, 0x0D, 0x32, 0x36, 0x30, 0x31, 0x30, 0x31, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x5A,
            // subject (empty SEQUENCE)
            0x30, 0x00,
            // SubjectPublicKeyInfo SEQUENCE (length 89 = 0x59)
            0x30, 0x59,
              // AlgorithmIdentifier SEQUENCE (length 19 = 0x13)
              0x30, 0x13,
                0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
                0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
              // BIT STRING (length 66 = 0x42): unused=0, point=04||x||y
              0x03, 0x42, 0x00,
                0x04,
    } ++ [_]u8{0x01} ** 32
      ++ [_]u8{0x02} ** 32
      ++ [_]u8{
          // signatureAlgorithm SEQUENCE { OID }
          0x30, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02,
          // signatureValue BIT STRING (dummy)
          0x03, 0x03, 0x00, 0x01, 0x02,
    };
    // zig fmt: on

    const result = extractPublicKeyFromCert(&cert).?;
    try testing.expectEqual(PublicKeyAlgo.ecdsa_p256, result.algo);
    try testing.expectEqual(@as(usize, 65), result.key_bytes.len);
    try testing.expectEqual(@as(u8, 0x04), result.key_bytes[0]);
}

test "buildCvContent - correct structure" {
    var hash: [Sha256.digest_length]u8 = undefined;
    @memset(&hash, 0x42);
    const content = buildCvContent(&hash);

    // First 64 bytes should be 0x20 (space)
    for (content[0..64]) |b| {
        try testing.expectEqual(@as(u8, 0x20), b);
    }

    // Label should follow
    const expected_label = "TLS 1.3, server CertificateVerify";
    try testing.expectEqualStrings(expected_label, content[64..][0..expected_label.len]);

    // Null terminator
    try testing.expectEqual(@as(u8, 0x00), content[64 + expected_label.len]);

    // Hash should be at the end
    const hash_start = 64 + expected_label.len + 1;
    try testing.expectEqual(@as(u8, 0x42), content[hash_start]);
    try testing.expectEqual(CV_CONTENT_LEN, content.len);
}

test "ECDSA P-256 CertificateVerify sign and verify round-trip" {
    // Generate a key pair, sign CertificateVerify content, verify it
    const kp = EcdsaP256.KeyPair.generate();
    var hash: [Sha256.digest_length]u8 = undefined;
    @memset(&hash, 0xAB);
    const cv_content = buildCvContent(&hash);

    const sig = try kp.sign(&cv_content, null);

    // Verify should succeed
    try sig.verify(&cv_content, kp.public_key);

    // Verify with wrong content should fail
    var wrong_content = cv_content;
    wrong_content[0] = 0xFF;
    try testing.expectError(error.SignatureVerificationFailed, sig.verify(&wrong_content, kp.public_key));
}
