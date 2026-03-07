//! QUIC packet wire format: long/short headers, frame encoding/decoding,
//! and variable-length integer codec (RFC 9000).

const std = @import("std");
const mem = std.mem;
const math = std.math;
const io = std.io;
const testing = std.testing;
const crypto_mod = @import("crypto.zig");

pub const QUIC_VERSION_1: u32 = 0x00000001;
pub const MIN_UDP_PAYLOAD_LENGTH: usize = 1200;

// ── Variable-Length Integer ──────────────────────────────────────────────

/// Encode a QUIC variable-length integer (RFC 9000 §16).
pub fn encodeVarint(writer: anytype, value: u64) !void {
    if (value <= 63) {
        try writer.writeByte(@intCast(value));
    } else if (value <= 16383) {
        const v: u16 = @intCast(value);
        try writer.writeInt(u16, v | 0x4000, .big);
    } else if (value <= 1073741823) {
        const v: u32 = @intCast(value);
        try writer.writeInt(u32, v | 0x80000000, .big);
    } else {
        try writer.writeInt(u64, value | 0xC000000000000000, .big);
    }
}

/// Decode a QUIC variable-length integer (RFC 9000 §16).
pub fn decodeVarint(reader: anytype) !u64 {
    const first = try reader.readByte();
    const len_bits = first & 0xC0;

    if (len_bits == 0x00) {
        return @intCast(first & 0x3F);
    } else if (len_bits == 0x40) {
        const second = try reader.readByte();
        const val: u16 = (@as(u16, first & 0x3F) << 8) | @as(u16, second);
        return @intCast(val);
    } else if (len_bits == 0x80) {
        var buf: [3]u8 = undefined;
        try reader.readNoEof(&buf);
        const val: u32 = (@as(u32, first & 0x3F) << 24) |
            (@as(u32, buf[0]) << 16) |
            (@as(u32, buf[1]) << 8) |
            @as(u32, buf[2]);
        return @intCast(val);
    } else {
        var buf: [7]u8 = undefined;
        try reader.readNoEof(&buf);
        const val: u64 = (@as(u64, first & 0x3F) << 56) |
            (@as(u64, buf[0]) << 48) |
            (@as(u64, buf[1]) << 40) |
            (@as(u64, buf[2]) << 32) |
            (@as(u64, buf[3]) << 24) |
            (@as(u64, buf[4]) << 16) |
            (@as(u64, buf[5]) << 8) |
            @as(u64, buf[6]);
        return val;
    }
}

/// Calculate the number of bytes needed to encode a varint.
pub fn varintSize(value: u64) usize {
    if (value <= 63) return 1;
    if (value <= 16383) return 2;
    if (value <= 1073741823) return 4;
    return 8;
}

// ── Connection ID ────────────────────────────────────────────────────────

pub const ConnectionId = struct {
    data: [20]u8 = undefined,
    len: u8 = 0,

    pub fn initRandom(size: u8) ConnectionId {
        var cid = ConnectionId{ .len = size };
        std.crypto.random.bytes(cid.data[0..size]);
        return cid;
    }

    pub fn fromSlice(slice: []const u8) ConnectionId {
        var cid = ConnectionId{ .len = @intCast(slice.len) };
        @memcpy(cid.data[0..slice.len], slice);
        return cid;
    }

    pub fn constSlice(self: *const ConnectionId) []const u8 {
        return self.data[0..self.len];
    }

    pub fn encode(self: *const ConnectionId, writer: anytype) !void {
        try writer.writeByte(self.len);
        try writer.writeAll(self.data[0..self.len]);
    }

    pub fn decode(reader: anytype) !ConnectionId {
        const len = try reader.readByte();
        var cid = ConnectionId{ .len = len };
        try reader.readNoEof(cid.data[0..len]);
        return cid;
    }
};

// ── Packet Types ─────────────────────────────────────────────────────────

pub const PacketType = enum(u2) {
    initial = 0b00,
    zero_rtt = 0b01,
    handshake = 0b10,
    retry = 0b11,

    pub fn toEpoch(self: PacketType) Epoch {
        return switch (self) {
            .initial => .initial,
            .handshake => .handshake,
            .zero_rtt, .retry => .no_crypto,
        };
    }

    pub fn toSpace(self: PacketType) Space {
        return switch (self) {
            .initial => .initial,
            .handshake => .handshake,
            .zero_rtt, .retry => .application,
        };
    }
};

pub const Epoch = enum {
    initial,
    handshake,
    application,
    no_crypto,
};

pub const Space = enum {
    initial,
    handshake,
    application,
};

// ── Frames ───────────────────────────────────────────────────────────────

pub const FrameType = enum {
    padding,
    ack,
    crypto,
    stream,
    connection_close,
    handshake_done,
};

pub const Frame = union(FrameType) {
    padding: PaddingFrame,
    ack: AckFrame,
    crypto: CryptoFrame,
    stream: StreamFrame,
    connection_close: ConnectionCloseFrame,
    handshake_done: HandshakeDoneFrame,

    pub fn encode(self: *const Frame, writer: anytype) !void {
        switch (self.*) {
            .padding => |f| try f.encode(writer),
            .ack => |f| try f.encode(writer),
            .crypto => |f| try f.encode(writer),
            .stream => |f| try f.encode(writer),
            .connection_close => |f| try f.encode(writer),
            .handshake_done => try writer.writeByte(0x1e),
        }
    }

    pub fn decode(reader: anytype, allocator: mem.Allocator) !Frame {
        const type_id = try decodeVarint(reader);
        return switch (type_id) {
            0x00 => Frame{ .padding = PaddingFrame{ .length = 1 } },
            0x02, 0x03 => Frame{ .ack = try AckFrame.decode(type_id, reader, allocator) },
            0x06 => Frame{ .crypto = try CryptoFrame.decode(reader, allocator) },
            0x08...0x0f => Frame{ .stream = try StreamFrame.decodeWithType(type_id, reader, allocator) },
            0x1c, 0x1d => Frame{ .connection_close = try ConnectionCloseFrame.decode(type_id, reader) },
            0x1e => Frame{ .handshake_done = HandshakeDoneFrame{} },
            else => {
                // Skip unknown frames
                return Frame{ .padding = PaddingFrame{ .length = 0 } };
            },
        };
    }

    pub fn deinit(self: *Frame, allocator: mem.Allocator) void {
        switch (self.*) {
            .ack => |*f| f.deinit(),
            .crypto => |*f| f.deinit(allocator),
            .stream => |*f| f.deinit(allocator),
            else => {},
        }
    }

    /// Calculate encoded size of a frame.
    pub fn encodedSize(self: *const Frame) usize {
        return switch (self.*) {
            .padding => |f| f.length,
            .ack => |f| f.encodedSize(),
            .crypto => |f| f.encodedSize(),
            .stream => |f| f.encodedSize(),
            .connection_close => |f| f.encodedSize(),
            .handshake_done => 1,
        };
    }
};

pub const PaddingFrame = struct {
    length: usize,

    pub fn encode(self: PaddingFrame, writer: anytype) !void {
        var i: usize = 0;
        while (i < self.length) : (i += 1) {
            try writer.writeByte(0);
        }
    }
};

pub const AckFrame = struct {
    largest_acked: u64,
    ack_delay: u64,
    first_ack_range: u64,
    ranges: std.ArrayList(AckRange),
    has_ecn: bool = false,

    pub const AckRange = struct {
        gap: u64,
        ack_range_length: u64,
    };

    pub fn init(allocator: mem.Allocator) AckFrame {
        return .{
            .largest_acked = 0,
            .ack_delay = 0,
            .first_ack_range = 0,
            .ranges = std.ArrayList(AckRange).init(allocator),
        };
    }

    pub fn deinit(self: *AckFrame) void {
        self.ranges.deinit();
    }

    pub fn encode(self: *const AckFrame, writer: anytype) !void {
        try encodeVarint(writer, if (self.has_ecn) 0x03 else 0x02);
        try encodeVarint(writer, self.largest_acked);
        try encodeVarint(writer, self.ack_delay);
        try encodeVarint(writer, self.ranges.items.len);
        try encodeVarint(writer, self.first_ack_range);
        for (self.ranges.items) |r| {
            try encodeVarint(writer, r.gap);
            try encodeVarint(writer, r.ack_range_length);
        }
    }

    pub fn decode(type_id: u64, reader: anytype, allocator: mem.Allocator) !AckFrame {
        const largest = try decodeVarint(reader);
        const delay = try decodeVarint(reader);
        const range_count = try decodeVarint(reader);
        const first_range = try decodeVarint(reader);

        var ranges = std.ArrayList(AckRange).init(allocator);
        var i: u64 = 0;
        while (i < range_count) : (i += 1) {
            const gap = try decodeVarint(reader);
            const length = try decodeVarint(reader);
            try ranges.append(.{ .gap = gap, .ack_range_length = length });
        }

        // Skip ECN counts if present
        if (type_id & 0x01 == 0x01) {
            _ = try decodeVarint(reader);
            _ = try decodeVarint(reader);
            _ = try decodeVarint(reader);
        }

        return .{
            .largest_acked = largest,
            .ack_delay = delay,
            .first_ack_range = first_range,
            .ranges = ranges,
            .has_ecn = (type_id & 0x01) == 0x01,
        };
    }

    pub fn encodedSize(self: *const AckFrame) usize {
        var size: usize = 0;
        size += varintSize(if (self.has_ecn) 0x03 else 0x02);
        size += varintSize(self.largest_acked);
        size += varintSize(self.ack_delay);
        size += varintSize(self.ranges.items.len);
        size += varintSize(self.first_ack_range);
        for (self.ranges.items) |r| {
            size += varintSize(r.gap);
            size += varintSize(r.ack_range_length);
        }
        return size;
    }
};

pub const CryptoFrame = struct {
    offset: u64,
    data: []const u8,

    pub fn deinit(self: *CryptoFrame, allocator: mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn encode(self: CryptoFrame, writer: anytype) !void {
        try encodeVarint(writer, 0x06); // frame type
        try encodeVarint(writer, self.offset);
        try encodeVarint(writer, self.data.len);
        try writer.writeAll(self.data);
    }

    pub fn decode(reader: anytype, allocator: mem.Allocator) !CryptoFrame {
        const offset = try decodeVarint(reader);
        const length = try decodeVarint(reader);
        const data = try allocator.alloc(u8, @intCast(length));
        errdefer allocator.free(data);
        try reader.readNoEof(data);
        return .{ .offset = offset, .data = data };
    }

    pub fn encodedSize(self: CryptoFrame) usize {
        return varintSize(0x06) + varintSize(self.offset) +
            varintSize(self.data.len) + self.data.len;
    }
};

pub const StreamFrame = struct {
    stream_id: u64,
    offset: u64,
    data: []const u8,
    fin: bool,

    pub fn deinit(self: *StreamFrame, allocator: mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn encode(self: StreamFrame, writer: anytype) !void {
        // Stream frame type byte: 0b0000_1xxx
        // bit 0 = FIN, bit 1 = LEN, bit 2 = OFF
        var type_byte: u8 = 0x08;
        if (self.offset > 0) type_byte |= 0x04; // OFF bit
        type_byte |= 0x02; // LEN bit (always include length)
        if (self.fin) type_byte |= 0x01; // FIN bit
        try encodeVarint(writer, type_byte);
        try encodeVarint(writer, self.stream_id);
        if (self.offset > 0) {
            try encodeVarint(writer, self.offset);
        }
        try encodeVarint(writer, self.data.len);
        try writer.writeAll(self.data);
    }

    pub fn decodeWithType(type_id: u64, reader: anytype, allocator: mem.Allocator) !StreamFrame {
        const stream_id = try decodeVarint(reader);
        const has_offset = (type_id & 0x04) != 0;
        const has_length = (type_id & 0x02) != 0;
        const fin = (type_id & 0x01) != 0;

        const offset = if (has_offset) try decodeVarint(reader) else 0;
        const length = if (has_length) try decodeVarint(reader) else 0;

        const data = if (length > 0) blk: {
            const buf = try allocator.alloc(u8, @intCast(length));
            errdefer allocator.free(buf);
            try reader.readNoEof(buf);
            break :blk buf;
        } else try allocator.alloc(u8, 0);

        return .{
            .stream_id = stream_id,
            .offset = offset,
            .data = data,
            .fin = fin,
        };
    }

    pub fn encodedSize(self: StreamFrame) usize {
        var type_byte: u8 = 0x08;
        if (self.offset > 0) type_byte |= 0x04;
        type_byte |= 0x02;
        if (self.fin) type_byte |= 0x01;
        var size: usize = varintSize(type_byte);
        size += varintSize(self.stream_id);
        if (self.offset > 0) size += varintSize(self.offset);
        size += varintSize(self.data.len);
        size += self.data.len;
        return size;
    }
};

pub const ConnectionCloseFrame = struct {
    error_code: u64,
    frame_type: u64 = 0,
    reason: []const u8 = "",
    is_app: bool = false,

    pub fn encode(self: ConnectionCloseFrame, writer: anytype) !void {
        try encodeVarint(writer, if (self.is_app) 0x1d else 0x1c);
        try encodeVarint(writer, self.error_code);
        if (!self.is_app) {
            try encodeVarint(writer, self.frame_type);
        }
        try encodeVarint(writer, self.reason.len);
        if (self.reason.len > 0) {
            try writer.writeAll(self.reason);
        }
    }

    pub fn decode(type_id: u64, reader: anytype) !ConnectionCloseFrame {
        const error_code = try decodeVarint(reader);
        const is_app = type_id == 0x1d;
        const frame_type_val = if (!is_app) try decodeVarint(reader) else 0;
        const reason_len = try decodeVarint(reader);
        // Skip reason phrase for now
        var i: u64 = 0;
        while (i < reason_len) : (i += 1) {
            _ = try reader.readByte();
        }
        return .{
            .error_code = error_code,
            .frame_type = frame_type_val,
            .is_app = is_app,
        };
    }

    pub fn encodedSize(self: ConnectionCloseFrame) usize {
        var size: usize = varintSize(if (self.is_app) 0x1d else 0x1c);
        size += varintSize(self.error_code);
        if (!self.is_app) size += varintSize(self.frame_type);
        size += varintSize(self.reason.len);
        size += self.reason.len;
        return size;
    }
};

pub const HandshakeDoneFrame = struct {};

// ── Packet Encoding/Decoding ─────────────────────────────────────────────

/// Encode, encrypt, and return a complete QUIC packet.
pub fn encodePacket(
    packet_type: PacketType,
    version: u32,
    dcid: ConnectionId,
    scid: ConnectionId,
    packet_number: u32,
    frames: []const Frame,
    keys: crypto_mod.QuicKeys,
    allocator: mem.Allocator,
    is_initial: bool,
    token: ?[]const u8,
) !std.ArrayList(u8) {
    // Build unencrypted payload
    var payload_buf = std.ArrayList(u8).init(allocator);
    defer payload_buf.deinit();
    for (frames) |frame| {
        try frame.encode(payload_buf.writer());
    }

    // Calculate header
    var header_buf = std.ArrayList(u8).init(allocator);
    defer header_buf.deinit();

    // First byte: long header form (1) | fixed bit (1) | type (2) | PN length (2)
    const pn_len: u2 = 3; // 4 bytes
    const first_byte: u8 = 0xC0 | (@as(u8, @intFromEnum(packet_type)) << 4) | @as(u8, pn_len);
    try header_buf.append(first_byte);

    // Version
    try header_buf.writer().writeInt(u32, version, .big);

    // Connection IDs
    try dcid.encode(header_buf.writer());
    try scid.encode(header_buf.writer());

    // Token (Initial only)
    if (is_initial) {
        const tok = token orelse &[_]u8{};
        try encodeVarint(header_buf.writer(), tok.len);
        if (tok.len > 0) try header_buf.appendSlice(tok);
    }

    // Payload length = payload + PN length + AEAD tag
    const payload_length = payload_buf.items.len + 4 + crypto_mod.Aes128Gcm.tag_length;

    // Padding for initial packets to reach minimum UDP payload size
    var padding_needed: usize = 0;
    if (is_initial) {
        const total_before_padding = header_buf.items.len + varintSize(payload_length) + payload_length;
        if (total_before_padding < MIN_UDP_PAYLOAD_LENGTH) {
            padding_needed = MIN_UDP_PAYLOAD_LENGTH - total_before_padding;
        }
    }

    const final_payload_length = payload_length + padding_needed;
    try encodeVarint(header_buf.writer(), final_payload_length);

    // Packet number (4 bytes)
    try header_buf.writer().writeInt(u32, packet_number, .big);

    // Add padding to payload if needed
    var i: usize = 0;
    while (i < padding_needed) : (i += 1) {
        try payload_buf.append(0);
    }

    // Encrypt (long header)
    const encrypted = try crypto_mod.encryptPacket(
        header_buf.items,
        payload_buf.items,
        keys.key,
        keys.iv,
        keys.hp,
        allocator,
        false,
    );

    return encrypted;
}

/// Encode and encrypt a QUIC short header (1-RTT) packet.
pub fn encodeShortPacket(
    dcid: ConnectionId,
    packet_number: u32,
    frames: []const Frame,
    keys: crypto_mod.QuicKeys,
    allocator: mem.Allocator,
) !std.ArrayList(u8) {
    // Build unencrypted payload
    var payload_buf = std.ArrayList(u8).init(allocator);
    defer payload_buf.deinit();
    for (frames) |frame| {
        try frame.encode(payload_buf.writer());
    }

    // Build short header
    var header_buf = std.ArrayList(u8).init(allocator);
    defer header_buf.deinit();

    // First byte: Form(0) | Fixed(1) | Spin(0) | Reserved(00) | KeyPhase(0) | PNLen(11)
    // = 0b0_1_0_00_0_11 = 0x43
    const pn_len: u2 = 3; // 4-byte packet number
    const first_byte: u8 = 0x40 | @as(u8, pn_len);
    try header_buf.append(first_byte);

    // DCID (no length prefix in short header)
    try header_buf.appendSlice(dcid.constSlice());

    // Packet number (4 bytes)
    try header_buf.writer().writeInt(u32, packet_number, .big);

    // Encrypt (short header)
    return try crypto_mod.encryptPacket(
        header_buf.items,
        payload_buf.items,
        keys.key,
        keys.iv,
        keys.hp,
        allocator,
        true,
    );
}

/// Decode a QUIC long header packet (version, CIDs, payload boundaries).
/// Returns the header info and a reader positioned at the payload.
pub const DecodedHeader = struct {
    packet_type: PacketType,
    version: u32,
    dcid: ConnectionId,
    scid: ConnectionId,
    packet_number: u32,
    token: ?[]const u8,
    header_bytes: []const u8,
    payload_bytes: []const u8,
};

pub fn decodeLongHeader(data: []const u8) !DecodedHeader {
    if (data.len < 5) return error.PacketTooShort;

    var stream = io.fixedBufferStream(data);
    var reader = stream.reader();

    const first_byte = try reader.readByte();
    const is_long = (first_byte & 0x80) != 0;
    if (!is_long) return error.NotLongHeader;

    const pkt_type: PacketType = @enumFromInt(@as(u2, @intCast((first_byte >> 4) & 0x03)));
    const version = try reader.readInt(u32, .big);
    const dcid = try ConnectionId.decode(reader);
    const scid = try ConnectionId.decode(reader);

    var token_data: ?[]const u8 = null;
    if (pkt_type == .initial) {
        const token_len = try decodeVarint(reader);
        if (token_len > 0) {
            const pos: usize = @intCast(stream.pos);
            token_data = data[pos..][0..@intCast(token_len)];
            stream.pos += @intCast(token_len);
        }
    }

    // Length field
    const payload_length = try decodeVarint(reader);
    const header_end: usize = @intCast(stream.pos);

    // The payload includes the packet number + encrypted data
    const payload_start = header_end;
    const payload_end = @min(payload_start + @as(usize, @intCast(payload_length)), data.len);

    return .{
        .packet_type = pkt_type,
        .version = version,
        .dcid = dcid,
        .scid = scid,
        .packet_number = 0, // Not yet known (encrypted)
        .token = token_data,
        .header_bytes = data[0..header_end],
        .payload_bytes = data[payload_start..payload_end],
    };
}

// ── Number Spaces ────────────────────────────────────────────────────────

pub const NumberSpace = struct {
    next_pn: u32 = 0,
    largest_acked: ?u64 = null,
    ack_list: std.ArrayList(u64),

    pub fn init(allocator: mem.Allocator) NumberSpace {
        return .{
            .ack_list = std.ArrayList(u64).init(allocator),
        };
    }

    pub fn deinit(self: *NumberSpace) void {
        self.ack_list.deinit();
    }

    pub fn generate(self: *NumberSpace) u32 {
        const pn = self.next_pn;
        self.next_pn += 1;
        return pn;
    }

    pub fn recordReceived(self: *NumberSpace, pn: u64) !void {
        try self.ack_list.append(pn);
        if (self.largest_acked == null or pn > self.largest_acked.?) {
            self.largest_acked = pn;
        }
    }

    pub fn buildAckFrame(self: *NumberSpace, allocator: mem.Allocator) ?AckFrame {
        if (self.ack_list.items.len == 0) return null;

        const largest = self.largest_acked orelse return null;

        return AckFrame{
            .largest_acked = largest,
            .ack_delay = 0,
            .first_ack_range = 0,
            .ranges = std.ArrayList(AckFrame.AckRange).init(allocator),
        };
    }
};

pub const PacketNumberSpaces = struct {
    initial: NumberSpace,
    handshake: NumberSpace,
    application: NumberSpace,

    pub fn init(allocator: mem.Allocator) PacketNumberSpaces {
        return .{
            .initial = NumberSpace.init(allocator),
            .handshake = NumberSpace.init(allocator),
            .application = NumberSpace.init(allocator),
        };
    }

    pub fn deinit(self: *PacketNumberSpaces) void {
        self.initial.deinit();
        self.handshake.deinit();
        self.application.deinit();
    }

    pub fn getPtr(self: *PacketNumberSpaces, space: Space) *NumberSpace {
        return switch (space) {
            .initial => &self.initial,
            .handshake => &self.handshake,
            .application => &self.application,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "varint round-trip - 1 byte" {
    var buf: [8]u8 = undefined;
    var stream = io.fixedBufferStream(&buf);
    try encodeVarint(stream.writer(), 37);
    stream.pos = 0;
    const decoded = try decodeVarint(stream.reader());
    try testing.expectEqual(@as(u64, 37), decoded);
}

test "varint round-trip - 2 bytes" {
    var buf: [8]u8 = undefined;
    var stream = io.fixedBufferStream(&buf);
    try encodeVarint(stream.writer(), 15293);
    stream.pos = 0;
    const decoded = try decodeVarint(stream.reader());
    try testing.expectEqual(@as(u64, 15293), decoded);
}

test "varint round-trip - 4 bytes" {
    var buf: [8]u8 = undefined;
    var stream = io.fixedBufferStream(&buf);
    try encodeVarint(stream.writer(), 494878333);
    stream.pos = 0;
    const decoded = try decodeVarint(stream.reader());
    try testing.expectEqual(@as(u64, 494878333), decoded);
}

test "varint round-trip - 8 bytes" {
    var buf: [8]u8 = undefined;
    var stream = io.fixedBufferStream(&buf);
    try encodeVarint(stream.writer(), 151288809941952652);
    stream.pos = 0;
    const decoded = try decodeVarint(stream.reader());
    try testing.expectEqual(@as(u64, 151288809941952652), decoded);
}

test "varintSize" {
    try testing.expectEqual(@as(usize, 1), varintSize(0));
    try testing.expectEqual(@as(usize, 1), varintSize(63));
    try testing.expectEqual(@as(usize, 2), varintSize(64));
    try testing.expectEqual(@as(usize, 2), varintSize(16383));
    try testing.expectEqual(@as(usize, 4), varintSize(16384));
    try testing.expectEqual(@as(usize, 8), varintSize(1073741824));
}

test "ConnectionId initRandom and fromSlice" {
    const cid = ConnectionId.initRandom(8);
    try testing.expectEqual(@as(u8, 8), cid.len);

    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const cid2 = ConnectionId.fromSlice(&data);
    try testing.expectEqual(@as(u8, 4), cid2.len);
    try testing.expectEqualSlices(u8, &data, cid2.constSlice());
}

test "CryptoFrame encode/decode round-trip" {
    const allocator = testing.allocator;
    const original = CryptoFrame{
        .offset = 0,
        .data = "hello QUIC",
    };

    var buf: [64]u8 = undefined;
    var stream = io.fixedBufferStream(&buf);
    try original.encode(stream.writer());

    const written = stream.pos;
    stream.pos = 0;

    // Read frame type
    const ftype = try decodeVarint(stream.reader());
    try testing.expectEqual(@as(u64, 0x06), ftype);

    const decoded = try CryptoFrame.decode(stream.reader(), allocator);
    defer allocator.free(decoded.data);

    try testing.expectEqual(@as(u64, 0), decoded.offset);
    try testing.expectEqualStrings("hello QUIC", decoded.data);
    _ = written;
}

test "AckFrame encode/decode round-trip" {
    const allocator = testing.allocator;
    var original = AckFrame.init(allocator);
    defer original.deinit();
    original.largest_acked = 42;
    original.ack_delay = 0;
    original.first_ack_range = 0;

    var buf: [64]u8 = undefined;
    var stream = io.fixedBufferStream(&buf);
    try original.encode(stream.writer());

    stream.pos = 0;
    const type_id = try decodeVarint(stream.reader());
    var decoded = try AckFrame.decode(type_id, stream.reader(), allocator);
    defer decoded.deinit();

    try testing.expectEqual(@as(u64, 42), decoded.largest_acked);
}
