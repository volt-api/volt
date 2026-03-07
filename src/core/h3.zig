const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── HTTP/3 Protocol Support (RFC 9114) ────────────────────────────────
//
// HTTP/3 framing and QPACK header compression for the Volt API client.
// Supports building and parsing HTTP/3 frames, QPACK header encoding/decoding,
// QUIC variable-length integer encoding, stream management, and request building.
//
// HTTP/3 frame layout (Section 7.1):
//   Variable-length: frame type (QUIC varint)
//   Variable-length: payload length (QUIC varint)
//   N bytes: payload
//
// QUIC variable-length integer encoding (RFC 9000 §16):
//   1 byte:  6-bit value (0-63)           prefix 00
//   2 bytes: 14-bit value (0-16383)       prefix 01
//   4 bytes: 30-bit value (0-1073741823)  prefix 10
//   8 bytes: 62-bit value                 prefix 11
//
// This module uses Zig stdlib only — no external dependencies.

// ── Constants ────────────────────────────────────────────────────────

/// QUIC version 1 (RFC 9000).
pub const QUIC_VERSION_1: u32 = 0x00000001;

/// Maximum value representable by a QUIC variable-length integer (62 bits).
pub const VARINT_MAX: u64 = (@as(u64, 1) << 62) - 1;

// ── Frame Types (Section 7.2) ────────────────────────────────────────

pub const FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0D,

    pub fn toString(self: FrameType) []const u8 {
        return switch (self) {
            .data => "DATA",
            .headers => "HEADERS",
            .cancel_push => "CANCEL_PUSH",
            .settings => "SETTINGS",
            .push_promise => "PUSH_PROMISE",
            .goaway => "GOAWAY",
            .max_push_id => "MAX_PUSH_ID",
        };
    }
};

// ── Error Codes (Section 8.1 + QPACK) ────────────────────────────────

pub const ErrorCode = enum(u64) {
    h3_no_error = 0x0100,
    h3_general_protocol_error = 0x0101,
    h3_internal_error = 0x0102,
    h3_stream_creation_error = 0x0103,
    h3_closed_critical_stream = 0x0104,
    h3_frame_unexpected = 0x0105,
    h3_frame_error = 0x0106,
    h3_excessive_load = 0x0107,
    h3_id_error = 0x0108,
    h3_settings_error = 0x0109,
    h3_missing_settings = 0x010A,
    h3_request_rejected = 0x010B,
    h3_request_cancelled = 0x010C,
    h3_request_incomplete = 0x010D,
    h3_message_error = 0x010E,
    h3_connect_error = 0x010F,
    h3_version_fallback = 0x0110,
    qpack_decompression_failed = 0x0200,
    qpack_encoder_stream_error = 0x0201,
    qpack_decoder_stream_error = 0x0202,

    pub fn toString(self: ErrorCode) []const u8 {
        return switch (self) {
            .h3_no_error => "H3_NO_ERROR",
            .h3_general_protocol_error => "H3_GENERAL_PROTOCOL_ERROR",
            .h3_internal_error => "H3_INTERNAL_ERROR",
            .h3_stream_creation_error => "H3_STREAM_CREATION_ERROR",
            .h3_closed_critical_stream => "H3_CLOSED_CRITICAL_STREAM",
            .h3_frame_unexpected => "H3_FRAME_UNEXPECTED",
            .h3_frame_error => "H3_FRAME_ERROR",
            .h3_excessive_load => "H3_EXCESSIVE_LOAD",
            .h3_id_error => "H3_ID_ERROR",
            .h3_settings_error => "H3_SETTINGS_ERROR",
            .h3_missing_settings => "H3_MISSING_SETTINGS",
            .h3_request_rejected => "H3_REQUEST_REJECTED",
            .h3_request_cancelled => "H3_REQUEST_CANCELLED",
            .h3_request_incomplete => "H3_REQUEST_INCOMPLETE",
            .h3_message_error => "H3_MESSAGE_ERROR",
            .h3_connect_error => "H3_CONNECT_ERROR",
            .h3_version_fallback => "H3_VERSION_FALLBACK",
            .qpack_decompression_failed => "QPACK_DECOMPRESSION_FAILED",
            .qpack_encoder_stream_error => "QPACK_ENCODER_STREAM_ERROR",
            .qpack_decoder_stream_error => "QPACK_DECODER_STREAM_ERROR",
        };
    }
};

// ── Stream States (RFC 9000 §3) ──────────────────────────────────────

pub const StreamState = enum {
    idle,
    open,
    send,
    recv,
    data_sent,
    data_recvd,
    reset_sent,
    reset_recvd,
    closed,

    pub fn toString(self: StreamState) []const u8 {
        return switch (self) {
            .idle => "idle",
            .open => "open",
            .send => "send",
            .recv => "recv",
            .data_sent => "data-sent",
            .data_recvd => "data-recvd",
            .reset_sent => "reset-sent",
            .reset_recvd => "reset-recvd",
            .closed => "closed",
        };
    }
};

// ── Stream Types ─────────────────────────────────────────────────────

pub const StreamType = enum {
    client_bidi,
    server_bidi,
    client_uni,
    server_uni,

    /// Determine stream type from the low 2 bits of the stream ID (RFC 9000 §2.1).
    pub fn fromStreamId(id: u64) StreamType {
        return switch (@as(u2, @intCast(id & 0x3))) {
            0x0 => .client_bidi,
            0x1 => .server_bidi,
            0x2 => .client_uni,
            0x3 => .server_uni,
        };
    }
};

// ── Unidirectional Stream Types (Section 6.2) ────────────────────────

pub const UniStreamType = enum(u64) {
    control = 0x00,
    push = 0x01,
    qpack_encoder = 0x02,
    qpack_decoder = 0x03,

    pub fn toString(self: UniStreamType) []const u8 {
        return switch (self) {
            .control => "CONTROL",
            .push => "PUSH",
            .qpack_encoder => "QPACK_ENCODER",
            .qpack_decoder => "QPACK_DECODER",
        };
    }
};

// ── Settings (Section 7.2.4) ─────────────────────────────────────────

pub const Setting = enum(u64) {
    qpack_max_table_capacity = 0x01,
    max_field_section_size = 0x06,
    qpack_blocked_streams = 0x07,
};

pub const Settings = struct {
    qpack_max_table_capacity: u64 = 0,
    max_field_section_size: u64 = 0,
    qpack_blocked_streams: u64 = 0,
};

// ── QUIC Packet Types ────────────────────────────────────────────────

pub const QuicPacketType = enum(u2) {
    initial = 0x0,
    zero_rtt = 0x1,
    handshake = 0x2,
    retry = 0x3,

    pub fn toString(self: QuicPacketType) []const u8 {
        return switch (self) {
            .initial => "INITIAL",
            .zero_rtt => "0-RTT",
            .handshake => "HANDSHAKE",
            .retry => "RETRY",
        };
    }
};

// ── ALPN Protocol Negotiation ────────────────────────────────────────

pub const AlpnProtocol = enum {
    h3,
    h2,
    http_1_1,

    pub fn toBytes(self: AlpnProtocol) []const u8 {
        return switch (self) {
            .h3 => "h3",
            .h2 => "h2",
            .http_1_1 => "http/1.1",
        };
    }

    pub fn fromBytes(data: []const u8) ?AlpnProtocol {
        if (mem.eql(u8, data, "h3")) return .h3;
        if (mem.eql(u8, data, "h2")) return .h2;
        if (mem.eql(u8, data, "http/1.1")) return .http_1_1;
        return null;
    }
};

// ── Header ───────────────────────────────────────────────────────────

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

// ── Frame ────────────────────────────────────────────────────────────

pub const Frame = struct {
    frame_type: FrameType,
    length: u64,
    payload: []const u8,
};

// ── Stream ───────────────────────────────────────────────────────────

pub const Stream = struct {
    id: u64,
    state: StreamState,
    stream_type: StreamType,
};

// ── H3 Connection ────────────────────────────────────────────────────

pub const H3Connection = struct {
    allocator: Allocator,
    settings: Settings,
    peer_settings: Settings,
    next_bidi_stream_id: u64,
    next_uni_stream_id: u64,
    streams: std.ArrayList(Stream),
    max_push_id: u64,

    pub fn init(allocator: Allocator) H3Connection {
        return .{
            .allocator = allocator,
            .settings = Settings{},
            .peer_settings = Settings{},
            .next_bidi_stream_id = 0, // client bidi: 0, 4, 8, ... (low bits 0x0)
            .next_uni_stream_id = 2, // client uni: 2, 6, 10, ... (low bits 0x2)
            .streams = std.ArrayList(Stream).init(allocator),
            .max_push_id = 0,
        };
    }

    pub fn deinit(self: *H3Connection) void {
        self.streams.deinit();
    }

    /// Create a new client-initiated bidirectional stream.
    /// Client bidi streams use IDs 0, 4, 8, ... (low 2 bits = 0x0).
    pub fn createBidiStream(self: *H3Connection) !*Stream {
        const id = self.next_bidi_stream_id;
        self.next_bidi_stream_id += 4;

        try self.streams.append(.{
            .id = id,
            .state = .open,
            .stream_type = .client_bidi,
        });

        return &self.streams.items[self.streams.items.len - 1];
    }

    /// Create a new client-initiated unidirectional stream.
    /// Client uni streams use IDs 2, 6, 10, ... (low 2 bits = 0x2).
    pub fn createUniStream(self: *H3Connection) !*Stream {
        const id = self.next_uni_stream_id;
        self.next_uni_stream_id += 4;

        try self.streams.append(.{
            .id = id,
            .state = .open,
            .stream_type = .client_uni,
        });

        return &self.streams.items[self.streams.items.len - 1];
    }

    /// Look up a stream by its ID.
    pub fn getStream(self: *H3Connection, stream_id: u64) ?*Stream {
        for (self.streams.items) |*stream| {
            if (stream.id == stream_id) return stream;
        }
        return null;
    }

    /// Count the number of streams in the given state.
    pub fn countStreamsInState(self: *const H3Connection, state: StreamState) u32 {
        var count: u32 = 0;
        for (self.streams.items) |stream| {
            if (stream.state == state) count += 1;
        }
        return count;
    }
};

// ── Connection ID ────────────────────────────────────────────────────

pub const ConnectionId = struct {
    data: [20]u8 = [_]u8{0} ** 20,
    len: u8 = 0,

    pub fn fromSlice(slice: []const u8) ConnectionId {
        var cid = ConnectionId{};
        const copy_len: u8 = @intCast(@min(slice.len, 20));
        @memcpy(cid.data[0..copy_len], slice[0..copy_len]);
        cid.len = copy_len;
        return cid;
    }

    pub fn toSlice(self: *const ConnectionId) []const u8 {
        return self.data[0..self.len];
    }
};

// ── QUIC Packet Header ──────────────────────────────────────────────

pub const QuicPacketHeader = struct {
    packet_type: QuicPacketType,
    version: u32,
    dest_conn_id: ConnectionId,
    src_conn_id: ConnectionId,
    packet_number: u32,
    payload_length: u64,
};

// ── TLS ALPN Config ──────────────────────────────────────────────────

pub const TlsAlpnConfig = struct {
    protocols: [3]AlpnProtocol = .{ .h3, .h2, .http_1_1 },
    protocol_count: u8 = 3,

    /// Create config preferring HTTP/3, falling back to HTTP/2 then HTTP/1.1
    pub fn preferH3() TlsAlpnConfig {
        return .{
            .protocols = .{ .h3, .h2, .http_1_1 },
            .protocol_count = 3,
        };
    }

    /// Create config for HTTP/3 only
    pub fn h3Only() TlsAlpnConfig {
        return .{
            .protocols = .{ .h3, .h3, .h3 },
            .protocol_count = 1,
        };
    }

    /// Create config preferring HTTP/2
    pub fn preferH2() TlsAlpnConfig {
        return .{
            .protocols = .{ .h2, .http_1_1, .http_1_1 },
            .protocol_count = 2,
        };
    }

    /// Create config for HTTP/2 only
    pub fn h2Only() TlsAlpnConfig {
        return .{
            .protocols = .{ .h2, .h2, .h2 },
            .protocol_count = 1,
        };
    }

    /// Create config for HTTP/1.1 only
    pub fn http11Only() TlsAlpnConfig {
        return .{
            .protocols = .{ .http_1_1, .http_1_1, .http_1_1 },
            .protocol_count = 1,
        };
    }
};

/// Result of ALPN negotiation
pub const AlpnResult = struct {
    selected: AlpnProtocol,
    is_h3: bool,
    is_h2: bool,
};

// ── Zero-RTT Config ─────────────────────────────────────────────────

pub const ZeroRttConfig = struct {
    server_name: []const u8,
    transport_params: []const u8,
    settings: Settings,
    max_early_data: u64,
    enabled: bool,
};

// ── QPACK Static Table Entry ─────────────────────────────────────────

pub const QpackStaticEntry = struct {
    index: u8,
    name: []const u8,
    value: []const u8,
};

// ── QPACK Static Table (RFC 9204 Appendix A) ────────────────────────

pub const QPACK_STATIC_TABLE = [_]QpackStaticEntry{
    .{ .index = 0, .name = ":authority", .value = "" },
    .{ .index = 1, .name = ":path", .value = "/" },
    .{ .index = 2, .name = "age", .value = "0" },
    .{ .index = 3, .name = "content-disposition", .value = "" },
    .{ .index = 4, .name = "content-length", .value = "0" },
    .{ .index = 5, .name = "cookie", .value = "" },
    .{ .index = 6, .name = "date", .value = "" },
    .{ .index = 7, .name = "etag", .value = "" },
    .{ .index = 8, .name = "if-modified-since", .value = "" },
    .{ .index = 9, .name = "if-none-match", .value = "" },
    .{ .index = 10, .name = "last-modified", .value = "" },
    .{ .index = 11, .name = "link", .value = "" },
    .{ .index = 12, .name = "location", .value = "" },
    .{ .index = 13, .name = "referer", .value = "" },
    .{ .index = 14, .name = "set-cookie", .value = "" },
    .{ .index = 15, .name = ":method", .value = "CONNECT" },
    .{ .index = 16, .name = ":method", .value = "DELETE" },
    .{ .index = 17, .name = ":method", .value = "GET" },
    .{ .index = 18, .name = ":method", .value = "HEAD" },
    .{ .index = 19, .name = ":method", .value = "OPTIONS" },
    .{ .index = 20, .name = ":method", .value = "POST" },
    .{ .index = 21, .name = ":method", .value = "PUT" },
    .{ .index = 22, .name = ":scheme", .value = "http" },
    .{ .index = 23, .name = ":scheme", .value = "https" },
    .{ .index = 24, .name = ":status", .value = "103" },
    .{ .index = 25, .name = ":status", .value = "200" },
    .{ .index = 26, .name = ":status", .value = "304" },
    .{ .index = 27, .name = ":status", .value = "404" },
    .{ .index = 28, .name = ":status", .value = "503" },
    .{ .index = 29, .name = "accept", .value = "*/*" },
    .{ .index = 30, .name = "accept", .value = "application/dns-message" },
    .{ .index = 31, .name = "accept-encoding", .value = "gzip, deflate, br" },
    .{ .index = 32, .name = "accept-ranges", .value = "bytes" },
    .{ .index = 33, .name = "access-control-allow-headers", .value = "cache-control" },
    .{ .index = 34, .name = "access-control-allow-headers", .value = "content-type" },
    .{ .index = 35, .name = "access-control-allow-origin", .value = "*" },
    .{ .index = 36, .name = "cache-control", .value = "max-age=0" },
    .{ .index = 37, .name = "cache-control", .value = "max-age=2592000" },
    .{ .index = 38, .name = "cache-control", .value = "max-age=604800" },
    .{ .index = 39, .name = "cache-control", .value = "no-cache" },
    .{ .index = 40, .name = "cache-control", .value = "no-store" },
    .{ .index = 41, .name = "cache-control", .value = "public, max-age=31536000" },
    .{ .index = 42, .name = "content-encoding", .value = "br" },
    .{ .index = 43, .name = "content-encoding", .value = "gzip" },
    .{ .index = 44, .name = "content-type", .value = "" },
    .{ .index = 45, .name = "content-type", .value = "application/dns-message" },
    .{ .index = 46, .name = "content-type", .value = "application/javascript" },
    .{ .index = 47, .name = "content-type", .value = "application/json" },
    .{ .index = 48, .name = "content-type", .value = "application/x-www-form-urlencoded" },
    .{ .index = 49, .name = "content-type", .value = "image/gif" },
    .{ .index = 50, .name = "content-type", .value = "image/jpeg" },
    .{ .index = 51, .name = "content-type", .value = "image/png" },
    .{ .index = 52, .name = "content-type", .value = "text/css" },
    .{ .index = 53, .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .index = 54, .name = "content-type", .value = "text/plain" },
    .{ .index = 55, .name = "content-type", .value = "text/plain;charset=utf-8" },
    .{ .index = 56, .name = "range", .value = "bytes=0-" },
    .{ .index = 57, .name = "strict-transport-security", .value = "max-age=31536000" },
    .{ .index = 58, .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains" },
    .{ .index = 59, .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains; preload" },
    .{ .index = 60, .name = "vary", .value = "accept-encoding" },
    .{ .index = 61, .name = "vary", .value = "origin" },
    .{ .index = 62, .name = "x-content-type-options", .value = "nosniff" },
    .{ .index = 63, .name = "x-xss-protection", .value = "1; mode=block" },
    .{ .index = 64, .name = ":status", .value = "100" },
    .{ .index = 65, .name = ":status", .value = "204" },
    .{ .index = 66, .name = ":status", .value = "206" },
    .{ .index = 67, .name = ":status", .value = "302" },
    .{ .index = 68, .name = ":status", .value = "400" },
    .{ .index = 69, .name = ":status", .value = "403" },
    .{ .index = 70, .name = ":status", .value = "421" },
    .{ .index = 71, .name = ":status", .value = "425" },
    .{ .index = 72, .name = ":status", .value = "500" },
    .{ .index = 73, .name = "accept-language", .value = "" },
    .{ .index = 74, .name = "access-control-allow-credentials", .value = "FALSE" },
    .{ .index = 75, .name = "access-control-allow-credentials", .value = "TRUE" },
    .{ .index = 76, .name = "access-control-allow-headers", .value = "*" },
    .{ .index = 77, .name = "access-control-allow-methods", .value = "get" },
    .{ .index = 78, .name = "access-control-allow-methods", .value = "get, post, options" },
    .{ .index = 79, .name = "access-control-allow-methods", .value = "options" },
    .{ .index = 80, .name = "access-control-expose-headers", .value = "content-length" },
    .{ .index = 81, .name = "access-control-request-headers", .value = "content-type" },
    .{ .index = 82, .name = "access-control-request-method", .value = "get" },
    .{ .index = 83, .name = "access-control-request-method", .value = "post" },
    .{ .index = 84, .name = "alt-svc", .value = "clear" },
    .{ .index = 85, .name = "authorization", .value = "" },
    .{ .index = 86, .name = "content-security-policy", .value = "script-src 'none'; object-src 'none'; base-uri 'none'" },
    .{ .index = 87, .name = "early-data", .value = "1" },
    .{ .index = 88, .name = "expect-ct", .value = "" },
    .{ .index = 89, .name = "forwarded", .value = "" },
    .{ .index = 90, .name = "if-range", .value = "" },
    .{ .index = 91, .name = "origin", .value = "" },
    .{ .index = 92, .name = "purpose", .value = "prefetch" },
    .{ .index = 93, .name = "server", .value = "" },
    .{ .index = 94, .name = "timing-allow-origin", .value = "*" },
    .{ .index = 95, .name = "upgrade-insecure-requests", .value = "1" },
    .{ .index = 96, .name = "user-agent", .value = "" },
    .{ .index = 97, .name = "x-forwarded-for", .value = "" },
    .{ .index = 98, .name = "x-frame-options", .value = "sameorigin" },
};

// ── QUIC Variable-Length Integer Encoding (RFC 9000 §16) ─────────────

/// Encode a QUIC variable-length integer into the buffer.
/// Uses the minimum number of bytes needed to represent the value.
pub fn encodeVarint(buf: *std.ArrayList(u8), value: u64) !void {
    if (value <= 63) {
        // 1 byte: prefix 00, 6-bit value
        try buf.append(@intCast(value));
    } else if (value <= 16383) {
        // 2 bytes: prefix 01, 14-bit value (big-endian)
        try buf.append(@intCast(0x40 | ((value >> 8) & 0x3F)));
        try buf.append(@intCast(value & 0xFF));
    } else if (value <= 1073741823) {
        // 4 bytes: prefix 10, 30-bit value (big-endian)
        try buf.append(@intCast(0x80 | ((value >> 24) & 0x3F)));
        try buf.append(@intCast((value >> 16) & 0xFF));
        try buf.append(@intCast((value >> 8) & 0xFF));
        try buf.append(@intCast(value & 0xFF));
    } else {
        // 8 bytes: prefix 11, 62-bit value (big-endian)
        try buf.append(@intCast(0xC0 | ((value >> 56) & 0x3F)));
        try buf.append(@intCast((value >> 48) & 0xFF));
        try buf.append(@intCast((value >> 40) & 0xFF));
        try buf.append(@intCast((value >> 32) & 0xFF));
        try buf.append(@intCast((value >> 24) & 0xFF));
        try buf.append(@intCast((value >> 16) & 0xFF));
        try buf.append(@intCast((value >> 8) & 0xFF));
        try buf.append(@intCast(value & 0xFF));
    }
}

/// Decode a QUIC variable-length integer from raw bytes.
/// Returns the decoded value and the number of bytes consumed.
pub fn decodeVarint(data: []const u8) struct { value: u64, bytes_used: usize } {
    if (data.len == 0) return .{ .value = 0, .bytes_used = 0 };

    const prefix: u2 = @intCast((data[0] >> 6) & 0x3);

    switch (prefix) {
        0 => {
            // 1 byte: 6-bit value
            return .{
                .value = @as(u64, data[0] & 0x3F),
                .bytes_used = 1,
            };
        },
        1 => {
            // 2 bytes: 14-bit value
            if (data.len < 2) return .{ .value = 0, .bytes_used = 0 };
            const value = (@as(u64, data[0] & 0x3F) << 8) |
                @as(u64, data[1]);
            return .{ .value = value, .bytes_used = 2 };
        },
        2 => {
            // 4 bytes: 30-bit value
            if (data.len < 4) return .{ .value = 0, .bytes_used = 0 };
            const value = (@as(u64, data[0] & 0x3F) << 24) |
                (@as(u64, data[1]) << 16) |
                (@as(u64, data[2]) << 8) |
                @as(u64, data[3]);
            return .{ .value = value, .bytes_used = 4 };
        },
        3 => {
            // 8 bytes: 62-bit value
            if (data.len < 8) return .{ .value = 0, .bytes_used = 0 };
            const value = (@as(u64, data[0] & 0x3F) << 56) |
                (@as(u64, data[1]) << 48) |
                (@as(u64, data[2]) << 40) |
                (@as(u64, data[3]) << 32) |
                (@as(u64, data[4]) << 24) |
                (@as(u64, data[5]) << 16) |
                (@as(u64, data[6]) << 8) |
                @as(u64, data[7]);
            return .{ .value = value, .bytes_used = 8 };
        },
    }
}

/// Calculate the number of bytes needed to encode a QUIC varint.
pub fn varintSize(value: u64) u8 {
    if (value <= 63) return 1;
    if (value <= 16383) return 2;
    if (value <= 1073741823) return 4;
    return 8;
}

// ── Frame Building Functions ─────────────────────────────────────────

/// Build an HTTP/3 frame with varint-encoded type and length.
/// Caller owns the returned slice.
pub fn buildFrame(allocator: Allocator, frame_type: FrameType, payload: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Frame type as varint
    try encodeVarint(&buf, @intFromEnum(frame_type));

    // Payload length as varint
    try encodeVarint(&buf, payload.len);

    // Payload bytes
    try buf.appendSlice(payload);

    return buf.toOwnedSlice();
}

/// Parse an HTTP/3 frame from raw bytes.
/// Returns the parsed frame and the total number of bytes consumed, or null if
/// the data is too short or contains an unknown frame type.
pub fn parseFrame(data: []const u8) ?struct { frame: Frame, total_bytes: usize } {
    if (data.len == 0) return null;

    // Decode frame type varint
    const type_result = decodeVarint(data);
    if (type_result.bytes_used == 0) return null;

    const raw_type = type_result.value;
    const frame_type: FrameType = std.meta.intToEnum(FrameType, raw_type) catch return null;

    // Decode payload length varint
    const remaining_after_type = data[type_result.bytes_used..];
    if (remaining_after_type.len == 0) return null;

    const len_result = decodeVarint(remaining_after_type);
    if (len_result.bytes_used == 0) return null;

    const payload_len = len_result.value;
    const header_size = type_result.bytes_used + len_result.bytes_used;

    // Check if we have enough data for the payload
    if (data.len < header_size + payload_len) return null;

    const payload = if (payload_len > 0)
        data[header_size .. header_size + payload_len]
    else
        data[0..0];

    return .{
        .frame = Frame{
            .frame_type = frame_type,
            .length = payload_len,
            .payload = payload,
        },
        .total_bytes = header_size + payload_len,
    };
}

/// Build a SETTINGS frame (Section 7.2.4).
/// Settings are encoded as varint identifier/value pairs.
/// Only non-zero settings are included in the payload.
pub fn buildSettingsFrame(allocator: Allocator, settings: Settings) ![]const u8 {
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();

    // QPACK_MAX_TABLE_CAPACITY (0x01)
    if (settings.qpack_max_table_capacity > 0) {
        try encodeVarint(&payload, @intFromEnum(Setting.qpack_max_table_capacity));
        try encodeVarint(&payload, settings.qpack_max_table_capacity);
    }

    // MAX_FIELD_SECTION_SIZE (0x06)
    if (settings.max_field_section_size > 0) {
        try encodeVarint(&payload, @intFromEnum(Setting.max_field_section_size));
        try encodeVarint(&payload, settings.max_field_section_size);
    }

    // QPACK_BLOCKED_STREAMS (0x07)
    if (settings.qpack_blocked_streams > 0) {
        try encodeVarint(&payload, @intFromEnum(Setting.qpack_blocked_streams));
        try encodeVarint(&payload, settings.qpack_blocked_streams);
    }

    return buildFrame(allocator, .settings, payload.items);
}

/// Parse a SETTINGS frame payload into a Settings struct.
/// The payload contains varint key/value pairs.
pub fn parseSettingsPayload(data: []const u8) Settings {
    var settings = Settings{};
    var pos: usize = 0;

    while (pos < data.len) {
        const key_result = decodeVarint(data[pos..]);
        if (key_result.bytes_used == 0) break;
        pos += key_result.bytes_used;

        if (pos >= data.len) break;
        const value_result = decodeVarint(data[pos..]);
        if (value_result.bytes_used == 0) break;
        pos += value_result.bytes_used;

        if (key_result.value == @intFromEnum(Setting.qpack_max_table_capacity)) {
            settings.qpack_max_table_capacity = value_result.value;
        } else if (key_result.value == @intFromEnum(Setting.max_field_section_size)) {
            settings.max_field_section_size = value_result.value;
        } else if (key_result.value == @intFromEnum(Setting.qpack_blocked_streams)) {
            settings.qpack_blocked_streams = value_result.value;
        }
        // Unknown settings are ignored per spec
    }

    return settings;
}

/// Build a HEADERS frame (Section 7.2.2).
/// The encoded_headers should already be QPACK-encoded.
pub fn buildHeadersFrame(allocator: Allocator, encoded_headers: []const u8) ![]const u8 {
    return buildFrame(allocator, .headers, encoded_headers);
}

/// Build a DATA frame (Section 7.2.1).
pub fn buildDataFrame(allocator: Allocator, data: []const u8) ![]const u8 {
    return buildFrame(allocator, .data, data);
}

/// Build a GOAWAY frame (Section 7.2.6).
/// Payload is the stream ID encoded as a varint.
pub fn buildGoawayFrame(allocator: Allocator, stream_id: u64) ![]const u8 {
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();

    try encodeVarint(&payload, stream_id);

    return buildFrame(allocator, .goaway, payload.items);
}

/// Build a CANCEL_PUSH frame (Section 7.2.3).
/// Payload is the push ID encoded as a varint.
pub fn buildCancelPushFrame(allocator: Allocator, push_id: u64) ![]const u8 {
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();

    try encodeVarint(&payload, push_id);

    return buildFrame(allocator, .cancel_push, payload.items);
}

/// Build a MAX_PUSH_ID frame (Section 7.2.7).
/// Payload is the maximum push ID encoded as a varint.
pub fn buildMaxPushIdFrame(allocator: Allocator, push_id: u64) ![]const u8 {
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();

    try encodeVarint(&payload, push_id);

    return buildFrame(allocator, .max_push_id, payload.items);
}

// ── QPACK Header Compression (simplified) ────────────────────────────
//
// This implements literal field line without name reference (Section 4.5.6
// of RFC 9204). Each header is encoded as:
//   0b0010_HNNN: H=0 (no Huffman), NNN = name length (3-bit prefix integer)
//   name bytes
//   0bH_VVVVVVV: H=0 (no Huffman), VVVVVVV = value length (7-bit prefix integer)
//   value bytes
//
// This is the simplest correct QPACK encoding — it does not use the
// dynamic table or Huffman coding, but is always valid.

/// Encode a QPACK integer with the given prefix bit width and first byte pattern.
fn encodeQpackInteger(buf: *std.ArrayList(u8), value: usize, prefix_bits: u4, first_byte_pattern: u8) !void {
    const max_prefix: usize = (@as(usize, 1) << prefix_bits) - 1;

    if (value < max_prefix) {
        try buf.append(first_byte_pattern | @as(u8, @intCast(value)));
    } else {
        try buf.append(first_byte_pattern | @as(u8, @intCast(max_prefix)));
        var remaining = value - max_prefix;
        while (remaining >= 128) {
            try buf.append(@as(u8, @intCast(remaining % 128)) | 0x80);
            remaining /= 128;
        }
        try buf.append(@intCast(remaining));
    }
}

/// Decode a QPACK integer from raw bytes with the given prefix bit width.
fn decodeQpackInteger(data: []const u8, prefix_bits: u4) struct { value: usize, bytes_used: usize } {
    if (data.len == 0) return .{ .value = 0, .bytes_used = 0 };

    const max_prefix: usize = (@as(usize, 1) << prefix_bits) - 1;
    const first: usize = @as(usize, data[0]) & max_prefix;

    if (first < max_prefix) {
        return .{ .value = first, .bytes_used = 1 };
    }

    var value: usize = max_prefix;
    var multiplier: usize = 1;
    var idx: usize = 1;

    while (idx < data.len) {
        const b = data[idx];
        value += @as(usize, b & 0x7F) * multiplier;
        idx += 1;
        if ((b & 0x80) == 0) break;
        multiplier *= 128;
    }

    return .{ .value = value, .bytes_used = idx };
}

/// Encode a single header as a QPACK literal field line without name reference.
pub fn encodeHeader(allocator: Allocator, name: []const u8, value: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Literal field line without name reference: 0b0010_HNNN
    // H = 0 (no Huffman), NNN = name length (3-bit prefix)
    try encodeQpackInteger(&buf, name.len, 3, 0x20);
    try buf.appendSlice(name);

    // Value: 0bH_VVVVVVV, H = 0 (no Huffman), 7-bit prefix
    try encodeQpackInteger(&buf, value.len, 7, 0x00);
    try buf.appendSlice(value);

    return buf.toOwnedSlice();
}

/// Encode multiple headers into a single QPACK header block.
/// Prepends the required 2-byte encoded field section prefix (Required Insert Count = 0,
/// Delta Base = 0) before the header field lines.
pub fn encodeHeaders(allocator: Allocator, headers: []const Header) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Required Insert Count = 0 (8-bit prefix integer)
    try buf.append(0x00);
    // Delta Base = 0, Sign bit = 0 (7-bit prefix integer)
    try buf.append(0x00);

    for (headers) |hdr| {
        const encoded = try encodeHeader(allocator, hdr.name, hdr.value);
        defer allocator.free(encoded);
        try buf.appendSlice(encoded);
    }

    return buf.toOwnedSlice();
}

/// Decode a QPACK header block containing literal field lines without name reference.
/// Skips the 2-byte encoded field section prefix.
/// Returns a list of decoded Header values. The caller owns the returned list
/// and the duplicated name/value strings.
pub fn decodeHeaderBlock(allocator: Allocator, data: []const u8) !std.ArrayList(Header) {
    var headers = std.ArrayList(Header).init(allocator);
    errdefer {
        for (headers.items) |hdr| {
            allocator.free(hdr.name);
            allocator.free(hdr.value);
        }
        headers.deinit();
    }

    // Skip 2-byte encoded field section prefix
    if (data.len < 2) return headers;
    var pos: usize = 2;

    while (pos < data.len) {
        const first_byte = data[pos];

        // Literal field line without name reference: 0b001x_xxxx
        if (first_byte & 0xE0 == 0x20) {
            // Decode name length (3-bit prefix, mask with first byte)
            const name_result = decodeQpackInteger(data[pos..], 3);
            pos += name_result.bytes_used;
            const name_len = name_result.value;

            if (pos + name_len > data.len) break;
            const name = try allocator.dupe(u8, data[pos .. pos + name_len]);
            errdefer allocator.free(name);
            pos += name_len;

            // Decode value length (7-bit prefix)
            if (pos >= data.len) {
                allocator.free(name);
                break;
            }
            const value_result = decodeQpackInteger(data[pos..], 7);
            pos += value_result.bytes_used;
            const value_len = value_result.value;

            if (pos + value_len > data.len) {
                allocator.free(name);
                break;
            }
            const value = try allocator.dupe(u8, data[pos .. pos + value_len]);
            pos += value_len;

            try headers.append(.{ .name = name, .value = value });
        } else {
            // Skip unknown encoding types
            pos += 1;
        }
    }

    return headers;
}

/// Look up a header name (and optionally value) in the QPACK static table.
/// If value is provided, matches both name and value. Otherwise matches name only.
/// Returns the static table index, or null if not found.
pub fn findStaticEntry(name: []const u8, value: ?[]const u8) ?u8 {
    for (QPACK_STATIC_TABLE) |entry| {
        if (mem.eql(u8, entry.name, name)) {
            if (value) |v| {
                if (mem.eql(u8, entry.value, v)) return entry.index;
            } else {
                return entry.index;
            }
        }
    }
    return null;
}

// ── Unidirectional Stream Header ─────────────────────────────────────

/// Build a unidirectional stream type header.
/// The stream type is encoded as a single varint at the start of the stream.
pub fn buildUniStreamHeader(allocator: Allocator, stream_type: UniStreamType) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try encodeVarint(&buf, @intFromEnum(stream_type));

    return buf.toOwnedSlice();
}

// ── TLS ALPN Extension ───────────────────────────────────────────────

/// Build the TLS ALPN extension payload.
/// Format per RFC 7301 Section 3.1:
///   2 bytes: ProtocolNameList length
///   For each protocol:
///     1 byte:  protocol name length
///     N bytes: protocol name (e.g. "h3", "h2", "http/1.1")
///
/// Caller owns the returned slice.
pub fn buildAlpnExtension(allocator: Allocator, config: TlsAlpnConfig) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Build protocol list first to compute total length
    var proto_buf = std.ArrayList(u8).init(allocator);
    defer proto_buf.deinit();

    var i: u8 = 0;
    while (i < config.protocol_count) : (i += 1) {
        const proto_bytes = config.protocols[i].toBytes();
        try proto_buf.append(@intCast(proto_bytes.len));
        try proto_buf.appendSlice(proto_bytes);
    }

    // ProtocolNameList length (2 bytes, big-endian)
    const list_len: u16 = @intCast(proto_buf.items.len);
    try buf.append(@intCast((list_len >> 8) & 0xFF));
    try buf.append(@intCast(list_len & 0xFF));
    try buf.appendSlice(proto_buf.items);

    return buf.toOwnedSlice();
}

/// Parse a TLS ALPN extension response to determine the server's selected protocol.
/// Format: 2 bytes list length, 1 byte name length, N bytes name.
pub fn parseAlpnResponse(data: []const u8) ?AlpnProtocol {
    if (data.len < 4) return null; // minimum: 2 (list len) + 1 (name len) + 1 (name)

    const list_len: u16 = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
    if (data.len < 2 + list_len) return null;

    const name_len = data[2];
    if (data.len < 3 + name_len) return null;

    return AlpnProtocol.fromBytes(data[3 .. 3 + name_len]);
}

/// Determine the negotiated protocol from a server ALPN response.
/// Returns null if negotiation failed or protocol is unknown.
pub fn negotiateAlpn(server_response: []const u8) ?AlpnResult {
    const selected = parseAlpnResponse(server_response) orelse return null;
    return AlpnResult{
        .selected = selected,
        .is_h3 = selected == .h3,
        .is_h2 = selected == .h2,
    };
}

// ── QUIC Long Header (RFC 9000 §17.2) ───────────────────────────────

/// Build a QUIC long header packet.
/// Format:
///   1 byte:  header form (1) | fixed bit (1) | long packet type (2) | reserved (2) | packet number length (2)
///   4 bytes: version (big-endian)
///   1 byte:  destination connection ID length
///   N bytes: destination connection ID
///   1 byte:  source connection ID length
///   N bytes: source connection ID
///   varint:  payload length
///   4 bytes: packet number (big-endian, fixed 4-byte encoding)
///
/// Caller owns the returned slice.
pub fn buildLongHeader(allocator: Allocator, header: QuicPacketHeader) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // First byte: form=1 | fixed=1 | type (2 bits) | reserved (2 bits) | pn_len=3 (meaning 4 bytes, encoded as 0x03)
    const first_byte: u8 = 0xC0 | (@as(u8, @intFromEnum(header.packet_type)) << 4) | 0x03;
    try buf.append(first_byte);

    // Version (4 bytes, big-endian)
    try buf.append(@intCast((header.version >> 24) & 0xFF));
    try buf.append(@intCast((header.version >> 16) & 0xFF));
    try buf.append(@intCast((header.version >> 8) & 0xFF));
    try buf.append(@intCast(header.version & 0xFF));

    // Destination connection ID
    try buf.append(header.dest_conn_id.len);
    try buf.appendSlice(header.dest_conn_id.toSlice());

    // Source connection ID
    try buf.append(header.src_conn_id.len);
    try buf.appendSlice(header.src_conn_id.toSlice());

    // Payload length as varint
    try encodeVarint(&buf, header.payload_length);

    // Packet number (4 bytes, big-endian)
    try buf.append(@intCast((header.packet_number >> 24) & 0xFF));
    try buf.append(@intCast((header.packet_number >> 16) & 0xFF));
    try buf.append(@intCast((header.packet_number >> 8) & 0xFF));
    try buf.append(@intCast(header.packet_number & 0xFF));

    return buf.toOwnedSlice();
}

/// Parse a QUIC long header packet from raw bytes.
/// Returns null if the data is too short or does not have the long header form bit set.
pub fn parseLongHeader(data: []const u8) ?QuicPacketHeader {
    // Minimum: 1 (first) + 4 (version) + 1 (dcid len) + 1 (scid len) + 1 (payload len) + 1 (pn) = 9
    if (data.len < 7) return null;

    const first_byte = data[0];

    // Check long header form bit (bit 7 must be 1)
    if ((first_byte & 0x80) == 0) return null;

    // Extract packet type (bits 5-4)
    const raw_type: u2 = @intCast((first_byte >> 4) & 0x03);
    const packet_type: QuicPacketType = @enumFromInt(raw_type);

    // Extract packet number length (bits 1-0): value + 1 = actual length
    const pn_len: usize = @as(usize, first_byte & 0x03) + 1;

    // Version (4 bytes)
    const version: u32 = (@as(u32, data[1]) << 24) |
        (@as(u32, data[2]) << 16) |
        (@as(u32, data[3]) << 8) |
        @as(u32, data[4]);

    var pos: usize = 5;

    // Destination connection ID
    if (pos >= data.len) return null;
    const dcid_len = data[pos];
    pos += 1;
    if (dcid_len > 20 or pos + dcid_len > data.len) return null;
    const dest_conn_id = ConnectionId.fromSlice(data[pos .. pos + dcid_len]);
    pos += dcid_len;

    // Source connection ID
    if (pos >= data.len) return null;
    const scid_len = data[pos];
    pos += 1;
    if (scid_len > 20 or pos + scid_len > data.len) return null;
    const src_conn_id = ConnectionId.fromSlice(data[pos .. pos + scid_len]);
    pos += scid_len;

    // Payload length (varint)
    if (pos >= data.len) return null;
    const payload_result = decodeVarint(data[pos..]);
    if (payload_result.bytes_used == 0) return null;
    pos += payload_result.bytes_used;

    // Packet number (pn_len bytes, big-endian)
    if (pos + pn_len > data.len) return null;
    var packet_number: u32 = 0;
    for (0..pn_len) |j| {
        packet_number = (packet_number << 8) | @as(u32, data[pos + j]);
    }

    return QuicPacketHeader{
        .packet_type = packet_type,
        .version = version,
        .dest_conn_id = dest_conn_id,
        .src_conn_id = src_conn_id,
        .packet_number = packet_number,
        .payload_length = payload_result.value,
    };
}

/// Generate a connection ID of the given length.
/// Uses a deterministic pattern (no crypto RNG in stdlib).
/// Length is clamped to a maximum of 20 bytes.
pub fn generateConnectionId(len: u8) ConnectionId {
    var cid = ConnectionId{};
    const actual_len: u8 = if (len > 20) 20 else len;
    cid.len = actual_len;

    var i: u8 = 0;
    while (i < actual_len) : (i += 1) {
        cid.data[i] = i +% 1; // 0x01, 0x02, 0x03, ...
    }

    return cid;
}

// ── Request Building ─────────────────────────────────────────────────

/// Build a complete HTTP/3 request as a list of frames.
/// Returns: HEADERS frame + optional DATA frame(s).
/// The caller owns each frame slice and the returned list.
pub fn buildRequest(allocator: Allocator, method: []const u8, path: []const u8, authority: []const u8, headers: []const Header, body: ?[]const u8) !std.ArrayList([]const u8) {
    var frames = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (frames.items) |frame| {
            allocator.free(frame);
        }
        frames.deinit();
    }

    // Build pseudo-headers + user headers
    var all_headers = std.ArrayList(Header).init(allocator);
    defer all_headers.deinit();

    try all_headers.append(.{ .name = ":method", .value = method });
    try all_headers.append(.{ .name = ":path", .value = path });
    try all_headers.append(.{ .name = ":scheme", .value = "https" });
    try all_headers.append(.{ .name = ":authority", .value = authority });

    for (headers) |hdr| {
        try all_headers.append(hdr);
    }

    // Encode all headers using QPACK
    const header_block = try encodeHeaders(allocator, all_headers.items);
    defer allocator.free(header_block);

    // Build HEADERS frame
    const headers_frame = try buildHeadersFrame(allocator, header_block);
    try frames.append(headers_frame);

    // Build DATA frame if there is a body
    const has_body = body != null and body.?.len > 0;
    if (has_body) {
        const data_frame = try buildDataFrame(allocator, body.?);
        try frames.append(data_frame);
    }

    return frames;
}

// ── Display Formatting ───────────────────────────────────────────────

/// Format frame information for human-readable display.
pub fn formatFrameInfo(allocator: Allocator, frame_type: FrameType, length: u64) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("{s} frame: length={d}", .{
        frame_type.toString(),
        length,
    });

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "varint encode 1-byte value" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    try encodeVarint(&buf, 37);
    try std.testing.expectEqual(@as(usize, 1), buf.items.len);
    try std.testing.expectEqual(@as(u8, 37), buf.items[0]);
}

test "varint encode 2-byte value" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // 15293 = 0x3BBD. 2-byte encoding: prefix 01 on first byte.
    // First byte: 0x40 | (0x3BBD >> 8) = 0x40 | 0x3B = 0x7B
    // Second byte: 0xBD
    try encodeVarint(&buf, 15293);
    try std.testing.expectEqual(@as(usize, 2), buf.items.len);
    try std.testing.expectEqual(@as(u8, 0x7B), buf.items[0]);
    try std.testing.expectEqual(@as(u8, 0xBD), buf.items[1]);
}

test "varint encode 4-byte value" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // 494878333 = 0x1D7F3E7D. 4-byte encoding: prefix 10.
    // First byte: 0x80 | (0x1D7F3E7D >> 24 & 0x3F) = 0x80 | 0x1D = 0x9D
    // Remaining: 0x7F, 0x3E, 0x7D
    try encodeVarint(&buf, 494878333);
    try std.testing.expectEqual(@as(usize, 4), buf.items.len);
    try std.testing.expectEqual(@as(u8, 0x9D), buf.items[0]);
    try std.testing.expectEqual(@as(u8, 0x7F), buf.items[1]);
    try std.testing.expectEqual(@as(u8, 0x3E), buf.items[2]);
    try std.testing.expectEqual(@as(u8, 0x7D), buf.items[3]);
}

test "varint encode 8-byte value" {
    const allocator = std.testing.allocator;
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();

    // Value larger than 30 bits requires 8-byte encoding
    const value: u64 = 1073741824; // 2^30, just above 4-byte threshold
    try encodeVarint(&buf, value);
    try std.testing.expectEqual(@as(usize, 8), buf.items.len);
    // Prefix should be 11 (0xC0)
    try std.testing.expect((buf.items[0] & 0xC0) == 0xC0);

    // Decode it back
    const result = decodeVarint(buf.items);
    try std.testing.expectEqual(value, result.value);
    try std.testing.expectEqual(@as(usize, 8), result.bytes_used);
}

test "varint encode-decode roundtrip" {
    const allocator = std.testing.allocator;

    const test_values = [_]u64{
        0, 1, 63, // 1-byte boundary
        64, 16383, // 2-byte boundary
        16384, 1073741823, // 4-byte boundary
        1073741824, VARINT_MAX, // 8-byte boundary
    };

    for (test_values) |value| {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try encodeVarint(&buf, value);
        const result = decodeVarint(buf.items);
        try std.testing.expectEqual(value, result.value);
        try std.testing.expectEqual(buf.items.len, result.bytes_used);
    }
}

test "build and parse DATA frame" {
    const allocator = std.testing.allocator;

    const data = "hello";
    const frame = try buildDataFrame(allocator, data);
    defer allocator.free(frame);

    const result = parseFrame(frame).?;
    try std.testing.expectEqual(FrameType.data, result.frame.frame_type);
    try std.testing.expectEqual(@as(u64, 5), result.frame.length);
    try std.testing.expectEqualStrings("hello", result.frame.payload);
}

test "build and parse HEADERS frame" {
    const allocator = std.testing.allocator;

    const headers = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/api/v1/users" },
    };

    const header_block = try encodeHeaders(allocator, &headers);
    defer allocator.free(header_block);

    const frame = try buildHeadersFrame(allocator, header_block);
    defer allocator.free(frame);

    const result = parseFrame(frame).?;
    try std.testing.expectEqual(FrameType.headers, result.frame.frame_type);
    try std.testing.expectEqual(@as(u64, header_block.len), result.frame.length);
}

test "build and parse SETTINGS frame" {
    const allocator = std.testing.allocator;

    const settings = Settings{
        .qpack_max_table_capacity = 4096,
        .max_field_section_size = 8192,
        .qpack_blocked_streams = 100,
    };

    const frame = try buildSettingsFrame(allocator, settings);
    defer allocator.free(frame);

    const result = parseFrame(frame).?;
    try std.testing.expectEqual(FrameType.settings, result.frame.frame_type);

    // Parse the settings payload
    const parsed = parseSettingsPayload(result.frame.payload);
    try std.testing.expectEqual(@as(u64, 4096), parsed.qpack_max_table_capacity);
    try std.testing.expectEqual(@as(u64, 8192), parsed.max_field_section_size);
    try std.testing.expectEqual(@as(u64, 100), parsed.qpack_blocked_streams);
}

test "build and parse GOAWAY frame" {
    const allocator = std.testing.allocator;

    const frame = try buildGoawayFrame(allocator, 42);
    defer allocator.free(frame);

    const result = parseFrame(frame).?;
    try std.testing.expectEqual(FrameType.goaway, result.frame.frame_type);

    // Decode the stream ID from the payload
    const stream_id = decodeVarint(result.frame.payload);
    try std.testing.expectEqual(@as(u64, 42), stream_id.value);
}

test "build and parse CANCEL_PUSH frame" {
    const allocator = std.testing.allocator;

    const frame = try buildCancelPushFrame(allocator, 7);
    defer allocator.free(frame);

    const result = parseFrame(frame).?;
    try std.testing.expectEqual(FrameType.cancel_push, result.frame.frame_type);

    const push_id = decodeVarint(result.frame.payload);
    try std.testing.expectEqual(@as(u64, 7), push_id.value);
}

test "build and parse MAX_PUSH_ID frame" {
    const allocator = std.testing.allocator;

    const frame = try buildMaxPushIdFrame(allocator, 100);
    defer allocator.free(frame);

    const result = parseFrame(frame).?;
    try std.testing.expectEqual(FrameType.max_push_id, result.frame.frame_type);

    const push_id = decodeVarint(result.frame.payload);
    try std.testing.expectEqual(@as(u64, 100), push_id.value);
}

test "QPACK header encode-decode roundtrip" {
    const allocator = std.testing.allocator;

    const headers = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/api" },
        .{ .name = "content-type", .value = "application/json" },
    };

    const encoded = try encodeHeaders(allocator, &headers);
    defer allocator.free(encoded);

    var decoded = try decodeHeaderBlock(allocator, encoded);
    defer {
        for (decoded.items) |hdr| {
            allocator.free(hdr.name);
            allocator.free(hdr.value);
        }
        decoded.deinit();
    }

    try std.testing.expectEqual(@as(usize, 3), decoded.items.len);

    try std.testing.expectEqualStrings(":method", decoded.items[0].name);
    try std.testing.expectEqualStrings("GET", decoded.items[0].value);

    try std.testing.expectEqualStrings(":path", decoded.items[1].name);
    try std.testing.expectEqualStrings("/api", decoded.items[1].value);

    try std.testing.expectEqualStrings("content-type", decoded.items[2].name);
    try std.testing.expectEqualStrings("application/json", decoded.items[2].value);
}

test "QPACK encode headers with long values" {
    const allocator = std.testing.allocator;

    const headers = [_]Header{
        .{ .name = "authorization", .value = "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.longtoken" },
        .{ .name = "x-custom-header-name", .value = "some-very-long-value-that-exceeds-seven-chars" },
    };

    const encoded = try encodeHeaders(allocator, &headers);
    defer allocator.free(encoded);

    var decoded = try decodeHeaderBlock(allocator, encoded);
    defer {
        for (decoded.items) |hdr| {
            allocator.free(hdr.name);
            allocator.free(hdr.value);
        }
        decoded.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), decoded.items.len);
    try std.testing.expectEqualStrings("authorization", decoded.items[0].name);
    try std.testing.expectEqualStrings("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.longtoken", decoded.items[0].value);
    try std.testing.expectEqualStrings("x-custom-header-name", decoded.items[1].name);
    try std.testing.expectEqualStrings("some-very-long-value-that-exceeds-seven-chars", decoded.items[1].value);
}

test "QPACK static table lookup" {
    // Exact match: name + value
    try std.testing.expectEqual(@as(?u8, 17), findStaticEntry(":method", "GET"));
    try std.testing.expectEqual(@as(?u8, 1), findStaticEntry(":path", "/"));
    try std.testing.expectEqual(@as(?u8, 47), findStaticEntry("content-type", "application/json"));

    // No match
    try std.testing.expect(findStaticEntry("nonexistent", "value") == null);
}

test "QPACK static table name-only lookup" {
    // Name-only match (returns first matching entry)
    try std.testing.expectEqual(@as(?u8, 0), findStaticEntry(":authority", null));
    try std.testing.expectEqual(@as(?u8, 15), findStaticEntry(":method", null));

    // No match
    try std.testing.expect(findStaticEntry("x-nonexistent", null) == null);
}

test "H3 connection stream creation" {
    const allocator = std.testing.allocator;

    var conn = H3Connection.init(allocator);
    defer conn.deinit();

    // Create first bidi stream — should be ID 0
    const s1 = try conn.createBidiStream();
    try std.testing.expectEqual(@as(u64, 0), s1.id);
    try std.testing.expectEqual(StreamState.open, s1.state);
    try std.testing.expectEqual(StreamType.client_bidi, s1.stream_type);

    // Create second bidi stream — should be ID 4
    const s2 = try conn.createBidiStream();
    try std.testing.expectEqual(@as(u64, 4), s2.id);

    // Create uni stream — should be ID 2
    const s3 = try conn.createUniStream();
    try std.testing.expectEqual(@as(u64, 2), s3.id);
    try std.testing.expectEqual(StreamType.client_uni, s3.stream_type);

    // Count streams
    try std.testing.expectEqual(@as(u32, 3), conn.countStreamsInState(.open));
    try std.testing.expectEqual(@as(u32, 0), conn.countStreamsInState(.closed));
}

test "H3 connection stream lookup" {
    const allocator = std.testing.allocator;

    var conn = H3Connection.init(allocator);
    defer conn.deinit();

    _ = try conn.createBidiStream(); // ID 0
    _ = try conn.createBidiStream(); // ID 4

    // Look up by ID
    const found = conn.getStream(0).?;
    try std.testing.expectEqual(@as(u64, 0), found.id);

    const found4 = conn.getStream(4).?;
    try std.testing.expectEqual(@as(u64, 4), found4.id);

    // Transition state
    found.state = .closed;
    try std.testing.expectEqual(StreamState.closed, conn.getStream(0).?.state);

    // Non-existent stream
    try std.testing.expect(conn.getStream(999) == null);
}

test "stream type from stream ID" {
    try std.testing.expectEqual(StreamType.client_bidi, StreamType.fromStreamId(0));
    try std.testing.expectEqual(StreamType.server_bidi, StreamType.fromStreamId(1));
    try std.testing.expectEqual(StreamType.client_uni, StreamType.fromStreamId(2));
    try std.testing.expectEqual(StreamType.server_uni, StreamType.fromStreamId(3));
    try std.testing.expectEqual(StreamType.client_bidi, StreamType.fromStreamId(4));
    try std.testing.expectEqual(StreamType.server_uni, StreamType.fromStreamId(7));
}

test "stream state toString" {
    try std.testing.expectEqualStrings("idle", StreamState.idle.toString());
    try std.testing.expectEqualStrings("open", StreamState.open.toString());
    try std.testing.expectEqualStrings("send", StreamState.send.toString());
    try std.testing.expectEqualStrings("recv", StreamState.recv.toString());
    try std.testing.expectEqualStrings("data-sent", StreamState.data_sent.toString());
    try std.testing.expectEqualStrings("data-recvd", StreamState.data_recvd.toString());
    try std.testing.expectEqualStrings("reset-sent", StreamState.reset_sent.toString());
    try std.testing.expectEqualStrings("reset-recvd", StreamState.reset_recvd.toString());
    try std.testing.expectEqualStrings("closed", StreamState.closed.toString());
}

test "ALPN protocol toBytes and fromBytes roundtrip" {
    try std.testing.expectEqualStrings("h3", AlpnProtocol.h3.toBytes());
    try std.testing.expectEqualStrings("h2", AlpnProtocol.h2.toBytes());
    try std.testing.expectEqualStrings("http/1.1", AlpnProtocol.http_1_1.toBytes());

    try std.testing.expectEqual(AlpnProtocol.h3, AlpnProtocol.fromBytes("h3").?);
    try std.testing.expectEqual(AlpnProtocol.h2, AlpnProtocol.fromBytes("h2").?);
    try std.testing.expectEqual(AlpnProtocol.http_1_1, AlpnProtocol.fromBytes("http/1.1").?);
    try std.testing.expect(AlpnProtocol.fromBytes("spdy/3") == null);
}

test "build ALPN extension with h3 preference" {
    const allocator = std.testing.allocator;
    const config = TlsAlpnConfig.preferH3();

    const extension = try buildAlpnExtension(allocator, config);
    defer allocator.free(extension);

    // Should start with 2-byte length
    const list_len = (@as(u16, extension[0]) << 8) | @as(u16, extension[1]);
    try std.testing.expectEqual(@as(u16, @intCast(extension.len - 2)), list_len);

    // First protocol: h3 (length 2)
    try std.testing.expectEqual(@as(u8, 2), extension[2]);
    try std.testing.expectEqualStrings("h3", extension[3..5]);

    // Second protocol: h2 (length 2)
    try std.testing.expectEqual(@as(u8, 2), extension[5]);
    try std.testing.expectEqualStrings("h2", extension[6..8]);

    // Third protocol: http/1.1 (length 8)
    try std.testing.expectEqual(@as(u8, 8), extension[8]);
    try std.testing.expectEqualStrings("http/1.1", extension[9..17]);
}

test "build ALPN extension h3 only" {
    const allocator = std.testing.allocator;
    const config = TlsAlpnConfig.h3Only();

    const extension = try buildAlpnExtension(allocator, config);
    defer allocator.free(extension);

    // Should contain only h3
    const list_len = (@as(u16, extension[0]) << 8) | @as(u16, extension[1]);
    try std.testing.expectEqual(@as(u16, 3), list_len); // 1 + 2 bytes for "h3"
    try std.testing.expectEqual(@as(u8, 2), extension[2]);
    try std.testing.expectEqualStrings("h3", extension[3..5]);
}

test "parse ALPN response h3" {
    // Server selected h3: list_len=3, name_len=2, "h3"
    const response = [_]u8{ 0x00, 0x03, 0x02, 'h', '3' };
    const result = parseAlpnResponse(&response);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(AlpnProtocol.h3, result.?);
}

test "parse ALPN response h2 via H3 module" {
    // Server selected h2: list_len=3, name_len=2, "h2"
    const response = [_]u8{ 0x00, 0x03, 0x02, 'h', '2' };
    const result = parseAlpnResponse(&response);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(AlpnProtocol.h2, result.?);
}

test "negotiate ALPN h3" {
    const response = [_]u8{ 0x00, 0x03, 0x02, 'h', '3' };
    const result = negotiateAlpn(&response);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.is_h3);
    try std.testing.expect(!result.?.is_h2);
    try std.testing.expectEqual(AlpnProtocol.h3, result.?.selected);
}

test "QUIC long header build and parse roundtrip" {
    const allocator = std.testing.allocator;

    const dest_cid = ConnectionId.fromSlice(&[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    const src_cid = ConnectionId.fromSlice(&[_]u8{ 0xCA, 0xFE });

    const original = QuicPacketHeader{
        .packet_type = .initial,
        .version = QUIC_VERSION_1,
        .dest_conn_id = dest_cid,
        .src_conn_id = src_cid,
        .packet_number = 42,
        .payload_length = 256,
    };

    const built = try buildLongHeader(allocator, original);
    defer allocator.free(built);

    const parsed = parseLongHeader(built).?;
    try std.testing.expectEqual(QuicPacketType.initial, parsed.packet_type);
    try std.testing.expectEqual(QUIC_VERSION_1, parsed.version);
    try std.testing.expectEqual(@as(u8, 4), parsed.dest_conn_id.len);
    try std.testing.expectEqualSlices(u8, dest_cid.toSlice(), parsed.dest_conn_id.toSlice());
    try std.testing.expectEqual(@as(u8, 2), parsed.src_conn_id.len);
    try std.testing.expectEqualSlices(u8, src_cid.toSlice(), parsed.src_conn_id.toSlice());
    try std.testing.expectEqual(@as(u32, 42), parsed.packet_number);
    try std.testing.expectEqual(@as(u64, 256), parsed.payload_length);
}

test "QUIC long header parse too short" {
    const short = [_]u8{ 0xC0, 0x00, 0x00 };
    try std.testing.expect(parseLongHeader(&short) == null);

    // Short header form bit not set
    const not_long = [_]u8{ 0x40, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00 };
    try std.testing.expect(parseLongHeader(&not_long) == null);
}

test "build full HTTP/3 request with body" {
    const allocator = std.testing.allocator;

    const custom_headers = [_]Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "accept", .value = "application/json" },
    };
    const body = "{\"key\":\"value\"}";

    var frames = try buildRequest(allocator, "POST", "/api/v1/items", "api.example.com", &custom_headers, body);
    defer {
        for (frames.items) |frame| {
            allocator.free(frame);
        }
        frames.deinit();
    }

    // Should produce 2 frames: HEADERS + DATA
    try std.testing.expectEqual(@as(usize, 2), frames.items.len);

    // First frame is HEADERS
    const hdr_result = parseFrame(frames.items[0]).?;
    try std.testing.expectEqual(FrameType.headers, hdr_result.frame.frame_type);

    // Second frame is DATA
    const data_result = parseFrame(frames.items[1]).?;
    try std.testing.expectEqual(FrameType.data, data_result.frame.frame_type);
    try std.testing.expectEqualStrings(body, data_result.frame.payload);
}

test "build full HTTP/3 request without body" {
    const allocator = std.testing.allocator;

    var frames = try buildRequest(allocator, "GET", "/index.html", "www.example.com", &[_]Header{}, null);
    defer {
        for (frames.items) |frame| {
            allocator.free(frame);
        }
        frames.deinit();
    }

    // GET with no body should produce only 1 frame: HEADERS
    try std.testing.expectEqual(@as(usize, 1), frames.items.len);

    const hdr_result = parseFrame(frames.items[0]).?;
    try std.testing.expectEqual(FrameType.headers, hdr_result.frame.frame_type);
}

test "error code and frame type toString" {
    // Error codes
    try std.testing.expectEqualStrings("H3_NO_ERROR", ErrorCode.h3_no_error.toString());
    try std.testing.expectEqualStrings("H3_GENERAL_PROTOCOL_ERROR", ErrorCode.h3_general_protocol_error.toString());
    try std.testing.expectEqualStrings("QPACK_DECOMPRESSION_FAILED", ErrorCode.qpack_decompression_failed.toString());
    try std.testing.expectEqualStrings("QPACK_ENCODER_STREAM_ERROR", ErrorCode.qpack_encoder_stream_error.toString());

    // Frame types
    try std.testing.expectEqualStrings("DATA", FrameType.data.toString());
    try std.testing.expectEqualStrings("HEADERS", FrameType.headers.toString());
    try std.testing.expectEqualStrings("SETTINGS", FrameType.settings.toString());
    try std.testing.expectEqualStrings("GOAWAY", FrameType.goaway.toString());
    try std.testing.expectEqualStrings("MAX_PUSH_ID", FrameType.max_push_id.toString());

    // Packet types
    try std.testing.expectEqualStrings("INITIAL", QuicPacketType.initial.toString());
    try std.testing.expectEqualStrings("0-RTT", QuicPacketType.zero_rtt.toString());
    try std.testing.expectEqualStrings("HANDSHAKE", QuicPacketType.handshake.toString());
    try std.testing.expectEqualStrings("RETRY", QuicPacketType.retry.toString());

    // Uni stream types
    try std.testing.expectEqualStrings("CONTROL", UniStreamType.control.toString());
    try std.testing.expectEqualStrings("QPACK_ENCODER", UniStreamType.qpack_encoder.toString());

    // Format frame info
    const allocator = std.testing.allocator;
    const info = try formatFrameInfo(allocator, .headers, 128);
    defer allocator.free(info);
    try std.testing.expect(mem.indexOf(u8, info, "HEADERS") != null);
    try std.testing.expect(mem.indexOf(u8, info, "128") != null);
}
