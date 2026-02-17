const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── HTTP/2 Protocol Support (RFC 7540) ────────────────────────────────
//
// HTTP/2 framing and header compression for the Volt API client.
// Supports building and parsing HTTP/2 frames, simplified HPACK
// header encoding/decoding, stream management, and request building.
//
// HTTP/2 frame layout (Section 4.1):
//   3 bytes: payload length (24-bit big-endian)
//   1 byte:  frame type
//   1 byte:  flags
//   4 bytes: stream identifier (R + 31-bit stream ID)
//   N bytes: payload
//
// This module uses Zig stdlib only — no external dependencies.

/// HTTP/2 connection preface sent by the client (Section 3.5).
pub const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

// ── Frame Types (Section 6) ──────────────────────────────────────────

pub const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,

    pub fn toString(self: FrameType) []const u8 {
        return switch (self) {
            .data => "DATA",
            .headers => "HEADERS",
            .priority => "PRIORITY",
            .rst_stream => "RST_STREAM",
            .settings => "SETTINGS",
            .push_promise => "PUSH_PROMISE",
            .ping => "PING",
            .goaway => "GOAWAY",
            .window_update => "WINDOW_UPDATE",
            .continuation => "CONTINUATION",
        };
    }
};

// ── Frame Flags ──────────────────────────────────────────────────────

pub const Flags = struct {
    pub const END_STREAM: u8 = 0x1;
    pub const ACK: u8 = 0x1;
    pub const END_HEADERS: u8 = 0x4;
    pub const PADDED: u8 = 0x8;
    pub const PRIORITY: u8 = 0x20;
};

// ── Error Codes (Section 7) ──────────────────────────────────────────

pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refused_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,

    pub fn toString(self: ErrorCode) []const u8 {
        return switch (self) {
            .no_error => "NO_ERROR",
            .protocol_error => "PROTOCOL_ERROR",
            .internal_error => "INTERNAL_ERROR",
            .flow_control_error => "FLOW_CONTROL_ERROR",
            .settings_timeout => "SETTINGS_TIMEOUT",
            .stream_closed => "STREAM_CLOSED",
            .frame_size_error => "FRAME_SIZE_ERROR",
            .refused_stream => "REFUSED_STREAM",
            .cancel => "CANCEL",
            .compression_error => "COMPRESSION_ERROR",
            .connect_error => "CONNECT_ERROR",
            .enhance_your_calm => "ENHANCE_YOUR_CALM",
            .inadequate_security => "INADEQUATE_SECURITY",
            .http_1_1_required => "HTTP_1_1_REQUIRED",
        };
    }
};

// ── Settings (Section 6.5) ───────────────────────────────────────────

pub const Setting = enum(u16) {
    header_table_size = 0x1,
    enable_push = 0x2,
    max_concurrent_streams = 0x3,
    initial_window_size = 0x4,
    max_frame_size = 0x5,
    max_header_list_size = 0x6,
};

pub const Settings = struct {
    header_table_size: u32 = 4096,
    enable_push: bool = true,
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = 65535,
    max_frame_size: u32 = 16384,
    max_header_list_size: u32 = 8192,
};

// ── Header ───────────────────────────────────────────────────────────

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

// ── Frame ────────────────────────────────────────────────────────────

pub const Frame = struct {
    length: u32, // 24-bit payload length
    frame_type: FrameType,
    flags: u8,
    stream_id: u32,
    payload: []const u8,
};

// ── Stream Management ────────────────────────────────────────────────

pub const StreamState = enum {
    idle,
    reserved_local,
    reserved_remote,
    open,
    half_closed_local,
    half_closed_remote,
    closed,

    pub fn toString(self: StreamState) []const u8 {
        return switch (self) {
            .idle => "idle",
            .reserved_local => "reserved (local)",
            .reserved_remote => "reserved (remote)",
            .open => "open",
            .half_closed_local => "half-closed (local)",
            .half_closed_remote => "half-closed (remote)",
            .closed => "closed",
        };
    }
};

pub const Stream = struct {
    id: u32,
    state: StreamState,
    window_size: i32,
};

pub const H2Connection = struct {
    allocator: Allocator,
    settings: Settings,
    peer_settings: Settings,
    next_stream_id: u32,
    streams: std.ArrayList(Stream),

    pub fn init(allocator: Allocator) H2Connection {
        return .{
            .allocator = allocator,
            .settings = Settings{},
            .peer_settings = Settings{},
            .next_stream_id = 1, // odd for client-initiated streams
            .streams = std.ArrayList(Stream).init(allocator),
        };
    }

    pub fn deinit(self: *H2Connection) void {
        self.streams.deinit();
    }

    /// Create a new stream with the next available client stream ID.
    /// Client-initiated streams use odd IDs (1, 3, 5, ...).
    pub fn createStream(self: *H2Connection) !*Stream {
        const id = self.next_stream_id;
        self.next_stream_id += 2; // client IDs are odd, increment by 2

        try self.streams.append(.{
            .id = id,
            .state = .open,
            .window_size = @as(i32, @intCast(self.peer_settings.initial_window_size)),
        });

        return &self.streams.items[self.streams.items.len - 1];
    }

    /// Look up a stream by its ID.
    pub fn getStream(self: *H2Connection, stream_id: u32) ?*Stream {
        for (self.streams.items) |*stream| {
            if (stream.id == stream_id) return stream;
        }
        return null;
    }

    /// Count the number of streams in the given state.
    pub fn countStreamsInState(self: *const H2Connection, state: StreamState) u32 {
        var count: u32 = 0;
        for (self.streams.items) |stream| {
            if (stream.state == state) count += 1;
        }
        return count;
    }
};

// ── Frame Building Functions ─────────────────────────────────────────

/// Build a 9-byte HTTP/2 frame header.
/// Layout: 3-byte length (big-endian) | 1-byte type | 1-byte flags | 4-byte stream ID.
pub fn buildFrameHeader(length: u32, frame_type: FrameType, flags: u8, stream_id: u32) [9]u8 {
    const masked_length = length & 0x00FFFFFF; // 24-bit
    const masked_stream = stream_id & 0x7FFFFFFF; // 31-bit (R bit = 0)
    return [9]u8{
        @intCast((masked_length >> 16) & 0xFF),
        @intCast((masked_length >> 8) & 0xFF),
        @intCast(masked_length & 0xFF),
        @intFromEnum(frame_type),
        flags,
        @intCast((masked_stream >> 24) & 0xFF),
        @intCast((masked_stream >> 16) & 0xFF),
        @intCast((masked_stream >> 8) & 0xFF),
        @intCast(masked_stream & 0xFF),
    };
}

/// Parse a 9-byte frame header from raw bytes.
/// Returns null if data is too short or contains an unknown frame type.
pub fn parseFrameHeader(data: []const u8) ?Frame {
    if (data.len < 9) return null;

    const length: u32 = (@as(u32, data[0]) << 16) |
        (@as(u32, data[1]) << 8) |
        @as(u32, data[2]);

    const raw_type = data[3];
    const frame_type: FrameType = std.meta.intToEnum(FrameType, raw_type) catch return null;

    const flags = data[4];

    const stream_id: u32 = ((@as(u32, data[5]) & 0x7F) << 24) |
        (@as(u32, data[6]) << 16) |
        (@as(u32, data[7]) << 8) |
        @as(u32, data[8]);

    // If there is payload data beyond the 9-byte header, reference it
    const payload = if (data.len > 9 and length > 0)
        data[9..@min(data.len, 9 + length)]
    else
        data[0..0]; // empty slice

    return Frame{
        .length = length,
        .frame_type = frame_type,
        .flags = flags,
        .stream_id = stream_id,
        .payload = payload,
    };
}

/// Build a SETTINGS frame (Section 6.5).
/// Each setting is a 6-byte pair: 2-byte identifier + 4-byte value.
/// Settings frames are always sent on stream 0.
pub fn buildSettingsFrame(allocator: Allocator, settings: Settings) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Collect non-default settings as identifier/value pairs
    var payload = std.ArrayList(u8).init(allocator);
    defer payload.deinit();

    // SETTINGS_HEADER_TABLE_SIZE (0x1)
    try appendSetting(&payload, @intFromEnum(Setting.header_table_size), settings.header_table_size);

    // SETTINGS_ENABLE_PUSH (0x2)
    try appendSetting(&payload, @intFromEnum(Setting.enable_push), if (settings.enable_push) @as(u32, 1) else @as(u32, 0));

    // SETTINGS_MAX_CONCURRENT_STREAMS (0x3)
    try appendSetting(&payload, @intFromEnum(Setting.max_concurrent_streams), settings.max_concurrent_streams);

    // SETTINGS_INITIAL_WINDOW_SIZE (0x4)
    try appendSetting(&payload, @intFromEnum(Setting.initial_window_size), settings.initial_window_size);

    // SETTINGS_MAX_FRAME_SIZE (0x5)
    try appendSetting(&payload, @intFromEnum(Setting.max_frame_size), settings.max_frame_size);

    // SETTINGS_MAX_HEADER_LIST_SIZE (0x6)
    try appendSetting(&payload, @intFromEnum(Setting.max_header_list_size), settings.max_header_list_size);

    // Frame header: stream 0, no flags
    const header = buildFrameHeader(@intCast(payload.items.len), .settings, 0, 0);
    try buf.appendSlice(&header);
    try buf.appendSlice(payload.items);

    return buf.toOwnedSlice();
}

/// Append a single 6-byte setting (2-byte ID + 4-byte value) to a buffer.
fn appendSetting(buf: *std.ArrayList(u8), id: u16, value: u32) !void {
    try buf.append(@intCast((id >> 8) & 0xFF));
    try buf.append(@intCast(id & 0xFF));
    try buf.append(@intCast((value >> 24) & 0xFF));
    try buf.append(@intCast((value >> 16) & 0xFF));
    try buf.append(@intCast((value >> 8) & 0xFF));
    try buf.append(@intCast(value & 0xFF));
}

/// Build a HEADERS frame (Section 6.2).
/// The header_block should already be HPACK-encoded.
pub fn buildHeadersFrame(allocator: Allocator, stream_id: u32, header_block: []const u8, end_stream: bool, end_headers: bool) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var flags: u8 = 0;
    if (end_stream) flags |= Flags.END_STREAM;
    if (end_headers) flags |= Flags.END_HEADERS;

    const header = buildFrameHeader(@intCast(header_block.len), .headers, flags, stream_id);
    try buf.appendSlice(&header);
    try buf.appendSlice(header_block);

    return buf.toOwnedSlice();
}

/// Build a DATA frame (Section 6.1).
pub fn buildDataFrame(allocator: Allocator, stream_id: u32, data: []const u8, end_stream: bool) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var flags: u8 = 0;
    if (end_stream) flags |= Flags.END_STREAM;

    const header = buildFrameHeader(@intCast(data.len), .data, flags, stream_id);
    try buf.appendSlice(&header);
    try buf.appendSlice(data);

    return buf.toOwnedSlice();
}

/// Build a WINDOW_UPDATE frame (Section 6.9).
/// Returns a fixed 13-byte frame (9-byte header + 4-byte increment).
pub fn buildWindowUpdateFrame(stream_id: u32, increment: u32) [13]u8 {
    const masked_inc = increment & 0x7FFFFFFF; // 31-bit
    const header = buildFrameHeader(4, .window_update, 0, stream_id);
    return header ++ [4]u8{
        @intCast((masked_inc >> 24) & 0xFF),
        @intCast((masked_inc >> 16) & 0xFF),
        @intCast((masked_inc >> 8) & 0xFF),
        @intCast(masked_inc & 0xFF),
    };
}

/// Build a PING frame (Section 6.7).
/// Returns a fixed 17-byte frame (9-byte header + 8-byte opaque data).
pub fn buildPingFrame(opaque_data: [8]u8, ack: bool) [17]u8 {
    const flags: u8 = if (ack) Flags.ACK else 0;
    const header = buildFrameHeader(8, .ping, flags, 0);
    return header ++ opaque_data;
}

/// Build a GOAWAY frame (Section 6.8).
/// Payload: 4-byte last-stream-id + 4-byte error code + optional debug data.
pub fn buildGoawayFrame(allocator: Allocator, last_stream_id: u32, error_code: ErrorCode) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const masked_id = last_stream_id & 0x7FFFFFFF;
    const ec: u32 = @intFromEnum(error_code);

    // Payload: 8 bytes (4 last-stream-id + 4 error code)
    var payload: [8]u8 = undefined;
    payload[0] = @intCast((masked_id >> 24) & 0xFF);
    payload[1] = @intCast((masked_id >> 16) & 0xFF);
    payload[2] = @intCast((masked_id >> 8) & 0xFF);
    payload[3] = @intCast(masked_id & 0xFF);
    payload[4] = @intCast((ec >> 24) & 0xFF);
    payload[5] = @intCast((ec >> 16) & 0xFF);
    payload[6] = @intCast((ec >> 8) & 0xFF);
    payload[7] = @intCast(ec & 0xFF);

    // GOAWAY is always on stream 0
    const header = buildFrameHeader(8, .goaway, 0, 0);
    try buf.appendSlice(&header);
    try buf.appendSlice(&payload);

    return buf.toOwnedSlice();
}

/// Build a RST_STREAM frame (Section 6.4).
/// Returns a fixed 13-byte frame (9-byte header + 4-byte error code).
pub fn buildRstStreamFrame(stream_id: u32, error_code: ErrorCode) [13]u8 {
    const ec: u32 = @intFromEnum(error_code);
    const header = buildFrameHeader(4, .rst_stream, 0, stream_id);
    return header ++ [4]u8{
        @intCast((ec >> 24) & 0xFF),
        @intCast((ec >> 16) & 0xFF),
        @intCast((ec >> 8) & 0xFF),
        @intCast(ec & 0xFF),
    };
}

// ── HPACK Header Compression (simplified) ────────────────────────────
//
// This implements literal header field without indexing (Section 6.2.2
// of RFC 7541). Each header is encoded as:
//   0x00 (4-bit prefix 0000) | name length (7+ integer) | name | value length (7+ integer) | value
//
// This is the simplest correct HPACK encoding — it does not use the
// static/dynamic table or Huffman coding, but is always valid.

/// Encode a single header as a literal header field without indexing.
pub fn encodeHeader(allocator: Allocator, name: []const u8, value: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Literal header field without indexing — new name (0000 0000)
    try buf.append(0x00);

    // Name length (7-bit prefix integer encoding)
    try encodeInteger(&buf, name.len, 7);
    try buf.appendSlice(name);

    // Value length (7-bit prefix integer encoding)
    try encodeInteger(&buf, value.len, 7);
    try buf.appendSlice(value);

    return buf.toOwnedSlice();
}

/// Encode multiple headers into a single HPACK header block.
pub fn encodeHeaders(allocator: Allocator, headers: []const Header) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    for (headers) |hdr| {
        const encoded = try encodeHeader(allocator, hdr.name, hdr.value);
        defer allocator.free(encoded);
        try buf.appendSlice(encoded);
    }

    return buf.toOwnedSlice();
}

/// Decode an HPACK header block containing literal header fields without indexing.
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

    var pos: usize = 0;
    while (pos < data.len) {
        const first_byte = data[pos];

        // We only handle literal header field without indexing (0x00 prefix)
        if (first_byte & 0xF0 == 0x00) {
            pos += 1; // skip the 0x00 byte

            // Decode name length
            const name_result = decodeInteger(data[pos..], 7);
            pos += name_result.bytes_used;
            const name_len = name_result.value;

            if (pos + name_len > data.len) break;
            const name = try allocator.dupe(u8, data[pos .. pos + name_len]);
            errdefer allocator.free(name);
            pos += name_len;

            // Decode value length
            const value_result = decodeInteger(data[pos..], 7);
            pos += value_result.bytes_used;
            const value_len = value_result.value;

            if (pos + value_len > data.len) break;
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

/// Encode an integer using HPACK integer representation (Section 5.1 of RFC 7541).
fn encodeInteger(buf: *std.ArrayList(u8), value: usize, prefix_bits: u4) !void {
    const max_prefix: usize = (@as(usize, 1) << prefix_bits) - 1;

    if (value < max_prefix) {
        try buf.append(@intCast(value));
    } else {
        try buf.append(@intCast(max_prefix));
        var remaining = value - max_prefix;
        while (remaining >= 128) {
            try buf.append(@as(u8, @intCast(remaining % 128)) | 0x80);
            remaining /= 128;
        }
        try buf.append(@intCast(remaining));
    }
}

/// Decode an HPACK integer from raw bytes.
fn decodeInteger(data: []const u8, prefix_bits: u4) struct { value: usize, bytes_used: usize } {
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

// ── Request Building ─────────────────────────────────────────────────

/// Build a complete HTTP/2 request as a list of frames.
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

    // Encode all headers using HPACK
    const header_block = try encodeHeaders(allocator, all_headers.items);
    defer allocator.free(header_block);

    // Determine if this is end-of-stream (no body)
    const has_body = body != null and body.?.len > 0;
    const end_stream_on_headers = !has_body;

    // Stream ID 1 for the first request
    const stream_id: u32 = 1;

    // Build HEADERS frame
    const headers_frame = try buildHeadersFrame(allocator, stream_id, header_block, end_stream_on_headers, true);
    try frames.append(headers_frame);

    // Build DATA frame if there is a body
    if (has_body) {
        const data_frame = try buildDataFrame(allocator, stream_id, body.?, true);
        try frames.append(data_frame);
    }

    return frames;
}

// ── Display Formatting ───────────────────────────────────────────────

/// Format frame information for human-readable display.
pub fn formatFrameInfo(allocator: Allocator, frame_type: FrameType, stream_id: u32, length: u32, flags: u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("{s} frame: stream={d}, length={d}, flags=0x{x:0>2}", .{
        frame_type.toString(),
        stream_id,
        length,
        flags,
    });

    // Annotate known flags
    if (frame_type == .data or frame_type == .headers) {
        if (flags & Flags.END_STREAM != 0) {
            try writer.writeAll(" [END_STREAM]");
        }
    }
    if (frame_type == .headers or frame_type == .continuation) {
        if (flags & Flags.END_HEADERS != 0) {
            try writer.writeAll(" [END_HEADERS]");
        }
    }
    if (frame_type == .settings or frame_type == .ping) {
        if (flags & Flags.ACK != 0) {
            try writer.writeAll(" [ACK]");
        }
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "frame header build and parse roundtrip" {
    const header = buildFrameHeader(42, .headers, Flags.END_HEADERS | Flags.END_STREAM, 7);

    const parsed = parseFrameHeader(&header).?;
    try std.testing.expectEqual(@as(u32, 42), parsed.length);
    try std.testing.expectEqual(FrameType.headers, parsed.frame_type);
    try std.testing.expectEqual(Flags.END_HEADERS | Flags.END_STREAM, parsed.flags);
    try std.testing.expectEqual(@as(u32, 7), parsed.stream_id);

    // Also test with a large 24-bit length and stream ID
    const header2 = buildFrameHeader(0x00ABCDEF, .data, 0, 0x7FFFFFFF);
    const parsed2 = parseFrameHeader(&header2).?;
    try std.testing.expectEqual(@as(u32, 0x00ABCDEF), parsed2.length);
    try std.testing.expectEqual(FrameType.data, parsed2.frame_type);
    try std.testing.expectEqual(@as(u32, 0x7FFFFFFF), parsed2.stream_id);

    // Too-short data returns null
    try std.testing.expect(parseFrameHeader(&[_]u8{ 0, 0, 0, 0 }) == null);
}

test "settings frame building" {
    const allocator = std.testing.allocator;

    const settings = Settings{
        .header_table_size = 4096,
        .enable_push = false,
        .max_concurrent_streams = 128,
        .initial_window_size = 65535,
        .max_frame_size = 16384,
        .max_header_list_size = 8192,
    };

    const frame = try buildSettingsFrame(allocator, settings);
    defer allocator.free(frame);

    // Parse the frame header (first 9 bytes)
    const parsed = parseFrameHeader(frame).?;
    try std.testing.expectEqual(FrameType.settings, parsed.frame_type);
    try std.testing.expectEqual(@as(u32, 0), parsed.stream_id); // always stream 0
    try std.testing.expectEqual(@as(u8, 0), parsed.flags); // no ACK

    // Payload should be 6 settings x 6 bytes = 36 bytes
    try std.testing.expectEqual(@as(u32, 36), parsed.length);
    try std.testing.expectEqual(@as(usize, 9 + 36), frame.len);
}

test "headers frame building with encoded headers" {
    const allocator = std.testing.allocator;

    const headers = [_]Header{
        .{ .name = ":method", .value = "GET" },
        .{ .name = ":path", .value = "/api/v1/users" },
    };

    const header_block = try encodeHeaders(allocator, &headers);
    defer allocator.free(header_block);

    const frame = try buildHeadersFrame(allocator, 1, header_block, false, true);
    defer allocator.free(frame);

    const parsed = parseFrameHeader(frame).?;
    try std.testing.expectEqual(FrameType.headers, parsed.frame_type);
    try std.testing.expectEqual(@as(u32, 1), parsed.stream_id);
    // END_HEADERS set, END_STREAM not set
    try std.testing.expect(parsed.flags & Flags.END_HEADERS != 0);
    try std.testing.expect(parsed.flags & Flags.END_STREAM == 0);
    try std.testing.expectEqual(@as(u32, @intCast(header_block.len)), parsed.length);
}

test "data frame building" {
    const allocator = std.testing.allocator;
    const body = "{\"name\":\"volt\"}";

    const frame = try buildDataFrame(allocator, 3, body, true);
    defer allocator.free(frame);

    const parsed = parseFrameHeader(frame).?;
    try std.testing.expectEqual(FrameType.data, parsed.frame_type);
    try std.testing.expectEqual(@as(u32, 3), parsed.stream_id);
    try std.testing.expect(parsed.flags & Flags.END_STREAM != 0);
    try std.testing.expectEqual(@as(u32, @intCast(body.len)), parsed.length);

    // Verify payload matches
    try std.testing.expectEqualStrings(body, frame[9..]);
}

test "ping frame building ack and non-ack" {
    const ping_data = [8]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };

    // Non-ACK ping
    const ping = buildPingFrame(ping_data, false);
    const parsed = parseFrameHeader(&ping).?;
    try std.testing.expectEqual(FrameType.ping, parsed.frame_type);
    try std.testing.expectEqual(@as(u32, 0), parsed.stream_id);
    try std.testing.expectEqual(@as(u32, 8), parsed.length);
    try std.testing.expect(parsed.flags & Flags.ACK == 0);

    // ACK ping
    const ack_ping = buildPingFrame(ping_data, true);
    const parsed_ack = parseFrameHeader(&ack_ping).?;
    try std.testing.expect(parsed_ack.flags & Flags.ACK != 0);

    // Opaque data should be preserved in both
    try std.testing.expectEqualSlices(u8, &ping_data, ping[9..17]);
    try std.testing.expectEqualSlices(u8, &ping_data, ack_ping[9..17]);
}

test "window update frame" {
    const frame = buildWindowUpdateFrame(5, 32768);
    const parsed = parseFrameHeader(&frame).?;

    try std.testing.expectEqual(FrameType.window_update, parsed.frame_type);
    try std.testing.expectEqual(@as(u32, 5), parsed.stream_id);
    try std.testing.expectEqual(@as(u32, 4), parsed.length);

    // Parse the increment from the payload
    const increment: u32 = (@as(u32, frame[9]) << 24) |
        (@as(u32, frame[10]) << 16) |
        (@as(u32, frame[11]) << 8) |
        @as(u32, frame[12]);
    try std.testing.expectEqual(@as(u32, 32768), increment);
}

test "goaway frame" {
    const allocator = std.testing.allocator;

    const frame = try buildGoawayFrame(allocator, 13, .protocol_error);
    defer allocator.free(frame);

    const parsed = parseFrameHeader(frame).?;
    try std.testing.expectEqual(FrameType.goaway, parsed.frame_type);
    try std.testing.expectEqual(@as(u32, 0), parsed.stream_id); // always stream 0
    try std.testing.expectEqual(@as(u32, 8), parsed.length);

    // Parse last-stream-id from payload
    const last_stream: u32 = (@as(u32, frame[9]) << 24) |
        (@as(u32, frame[10]) << 16) |
        (@as(u32, frame[11]) << 8) |
        @as(u32, frame[12]);
    try std.testing.expectEqual(@as(u32, 13), last_stream);

    // Parse error code from payload
    const ec: u32 = (@as(u32, frame[13]) << 24) |
        (@as(u32, frame[14]) << 16) |
        (@as(u32, frame[15]) << 8) |
        @as(u32, frame[16]);
    try std.testing.expectEqual(@as(u32, 0x1), ec); // PROTOCOL_ERROR
}

test "rst_stream frame" {
    const frame = buildRstStreamFrame(7, .cancel);
    const parsed = parseFrameHeader(&frame).?;

    try std.testing.expectEqual(FrameType.rst_stream, parsed.frame_type);
    try std.testing.expectEqual(@as(u32, 7), parsed.stream_id);
    try std.testing.expectEqual(@as(u32, 4), parsed.length);

    // Parse error code
    const ec: u32 = (@as(u32, frame[9]) << 24) |
        (@as(u32, frame[10]) << 16) |
        (@as(u32, frame[11]) << 8) |
        @as(u32, frame[12]);
    try std.testing.expectEqual(@as(u32, 0x8), ec); // CANCEL
}

test "hpack header encoding and decoding roundtrip" {
    const allocator = std.testing.allocator;

    const headers = [_]Header{
        .{ .name = ":method", .value = "POST" },
        .{ .name = ":path", .value = "/api/data" },
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = "Bearer token123" },
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

    try std.testing.expectEqual(@as(usize, 4), decoded.items.len);

    try std.testing.expectEqualStrings(":method", decoded.items[0].name);
    try std.testing.expectEqualStrings("POST", decoded.items[0].value);

    try std.testing.expectEqualStrings(":path", decoded.items[1].name);
    try std.testing.expectEqualStrings("/api/data", decoded.items[1].value);

    try std.testing.expectEqualStrings("content-type", decoded.items[2].name);
    try std.testing.expectEqualStrings("application/json", decoded.items[2].value);

    try std.testing.expectEqualStrings("authorization", decoded.items[3].name);
    try std.testing.expectEqualStrings("Bearer token123", decoded.items[3].value);
}

test "connection preface constant" {
    // RFC 7540 Section 3.5: the connection preface is exactly 24 bytes
    try std.testing.expectEqual(@as(usize, 24), CONNECTION_PREFACE.len);
    try std.testing.expectEqualStrings("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", CONNECTION_PREFACE);

    // Must start with "PRI"
    try std.testing.expect(mem.startsWith(u8, CONNECTION_PREFACE, "PRI"));
}

test "stream state management" {
    const allocator = std.testing.allocator;

    var conn = H2Connection.init(allocator);
    defer conn.deinit();

    // Create first stream — should be ID 1
    const s1 = try conn.createStream();
    try std.testing.expectEqual(@as(u32, 1), s1.id);
    try std.testing.expectEqual(StreamState.open, s1.state);
    try std.testing.expectEqual(@as(i32, 65535), s1.window_size);

    // Create second stream — should be ID 3 (odd, client-initiated)
    const s2 = try conn.createStream();
    try std.testing.expectEqual(@as(u32, 3), s2.id);

    // Look up stream by ID
    const found = conn.getStream(1).?;
    try std.testing.expectEqual(@as(u32, 1), found.id);
    try std.testing.expectEqual(StreamState.open, found.state);

    // Transition stream state
    found.state = .half_closed_local;
    try std.testing.expectEqual(StreamState.half_closed_local, conn.getStream(1).?.state);

    // Count streams in state
    try std.testing.expectEqual(@as(u32, 1), conn.countStreamsInState(.open));
    try std.testing.expectEqual(@as(u32, 1), conn.countStreamsInState(.half_closed_local));
    try std.testing.expectEqual(@as(u32, 0), conn.countStreamsInState(.closed));

    // Non-existent stream returns null
    try std.testing.expect(conn.getStream(999) == null);
}

test "full request building headers and data" {
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
    const hdr_frame = parseFrameHeader(frames.items[0]).?;
    try std.testing.expectEqual(FrameType.headers, hdr_frame.frame_type);
    try std.testing.expectEqual(@as(u32, 1), hdr_frame.stream_id);
    // END_HEADERS set, END_STREAM not set (because there is a body)
    try std.testing.expect(hdr_frame.flags & Flags.END_HEADERS != 0);
    try std.testing.expect(hdr_frame.flags & Flags.END_STREAM == 0);

    // Second frame is DATA with END_STREAM
    const data_frame = parseFrameHeader(frames.items[1]).?;
    try std.testing.expectEqual(FrameType.data, data_frame.frame_type);
    try std.testing.expectEqual(@as(u32, 1), data_frame.stream_id);
    try std.testing.expect(data_frame.flags & Flags.END_STREAM != 0);
    try std.testing.expectEqualStrings(body, frames.items[1][9..]);
}

test "full request building without body" {
    const allocator = std.testing.allocator;

    var frames = try buildRequest(allocator, "GET", "/index.html", "www.example.com", &[_]Header{}, null);
    defer {
        for (frames.items) |frame| {
            allocator.free(frame);
        }
        frames.deinit();
    }

    // GET with no body should produce only 1 frame: HEADERS with END_STREAM
    try std.testing.expectEqual(@as(usize, 1), frames.items.len);

    const hdr_frame = parseFrameHeader(frames.items[0]).?;
    try std.testing.expectEqual(FrameType.headers, hdr_frame.frame_type);
    try std.testing.expect(hdr_frame.flags & Flags.END_STREAM != 0);
    try std.testing.expect(hdr_frame.flags & Flags.END_HEADERS != 0);
}

test "error code toString" {
    try std.testing.expectEqualStrings("NO_ERROR", ErrorCode.no_error.toString());
    try std.testing.expectEqualStrings("PROTOCOL_ERROR", ErrorCode.protocol_error.toString());
    try std.testing.expectEqualStrings("INTERNAL_ERROR", ErrorCode.internal_error.toString());
    try std.testing.expectEqualStrings("FLOW_CONTROL_ERROR", ErrorCode.flow_control_error.toString());
    try std.testing.expectEqualStrings("SETTINGS_TIMEOUT", ErrorCode.settings_timeout.toString());
    try std.testing.expectEqualStrings("STREAM_CLOSED", ErrorCode.stream_closed.toString());
    try std.testing.expectEqualStrings("FRAME_SIZE_ERROR", ErrorCode.frame_size_error.toString());
    try std.testing.expectEqualStrings("REFUSED_STREAM", ErrorCode.refused_stream.toString());
    try std.testing.expectEqualStrings("CANCEL", ErrorCode.cancel.toString());
    try std.testing.expectEqualStrings("COMPRESSION_ERROR", ErrorCode.compression_error.toString());
    try std.testing.expectEqualStrings("CONNECT_ERROR", ErrorCode.connect_error.toString());
    try std.testing.expectEqualStrings("ENHANCE_YOUR_CALM", ErrorCode.enhance_your_calm.toString());
    try std.testing.expectEqualStrings("INADEQUATE_SECURITY", ErrorCode.inadequate_security.toString());
    try std.testing.expectEqualStrings("HTTP_1_1_REQUIRED", ErrorCode.http_1_1_required.toString());
}

test "format frame info display" {
    const allocator = std.testing.allocator;

    const info = try formatFrameInfo(allocator, .headers, 1, 128, Flags.END_STREAM | Flags.END_HEADERS);
    defer allocator.free(info);

    try std.testing.expect(mem.indexOf(u8, info, "HEADERS") != null);
    try std.testing.expect(mem.indexOf(u8, info, "stream=1") != null);
    try std.testing.expect(mem.indexOf(u8, info, "length=128") != null);
    try std.testing.expect(mem.indexOf(u8, info, "[END_STREAM]") != null);
    try std.testing.expect(mem.indexOf(u8, info, "[END_HEADERS]") != null);

    // Test SETTINGS with ACK
    const settings_info = try formatFrameInfo(allocator, .settings, 0, 0, Flags.ACK);
    defer allocator.free(settings_info);

    try std.testing.expect(mem.indexOf(u8, settings_info, "SETTINGS") != null);
    try std.testing.expect(mem.indexOf(u8, settings_info, "[ACK]") != null);
}
