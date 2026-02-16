const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── WebSocket Client ────────────────────────────────────────────────────
//
// WebSocket client for API testing.
// Supports connecting to WebSocket endpoints, sending messages,
// and receiving responses.
//
// NOTE: This is a simplified WebSocket implementation using
// Zig's standard TCP networking. It handles the WebSocket
// handshake and basic frame encoding/decoding.

pub const WebSocketState = enum {
    connecting,
    open,
    closing,
    closed,
};

pub const MessageType = enum {
    text,
    binary,
    ping,
    pong,
    close,
};

pub const WebSocketMessage = struct {
    msg_type: MessageType,
    data: []const u8,
    timestamp: i64,
};

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const WebSocketConfig = struct {
    url: []const u8 = "",
    headers: std.ArrayList(HeaderPair),
    ping_interval_ms: u32 = 30_000,
    max_message_size: usize = 16 * 1024 * 1024,
    auto_reconnect: bool = false,
    subprotocol: ?[]const u8 = null,

    pub fn init(allocator: Allocator) WebSocketConfig {
        return .{
            .headers = std.ArrayList(HeaderPair).init(allocator),
        };
    }

    pub fn deinit(self: *WebSocketConfig) void {
        self.headers.deinit();
    }
};

pub const FrameHeader = struct {
    fin: bool,
    opcode: u4,
    masked: bool,
    payload_length: u64,
    header_size: usize,
};

pub const WebSocketSession = struct {
    config: WebSocketConfig,
    state: WebSocketState,
    messages_sent: u64,
    messages_received: u64,
    message_log: std.ArrayList(WebSocketMessage),
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: WebSocketConfig) WebSocketSession {
        return .{
            .config = config,
            .state = .closed,
            .messages_sent = 0,
            .messages_received = 0,
            .message_log = std.ArrayList(WebSocketMessage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WebSocketSession) void {
        self.message_log.deinit();
    }

    /// Build WebSocket upgrade request
    pub fn buildHandshake(self: *const WebSocketSession, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        const url_parts = parseWsUrl(self.config.url) orelse return error.InvalidUrl;

        try writer.print("GET {s} HTTP/1.1\r\n", .{url_parts.path});
        try writer.print("Host: {s}", .{url_parts.host});
        if ((url_parts.secure and url_parts.port != 443) or
            (!url_parts.secure and url_parts.port != 80))
        {
            try writer.print(":{d}", .{url_parts.port});
        }
        try writer.writeAll("\r\n");
        try writer.writeAll("Upgrade: websocket\r\n");
        try writer.writeAll("Connection: Upgrade\r\n");
        try writer.writeAll("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n");
        try writer.writeAll("Sec-WebSocket-Version: 13\r\n");

        if (self.config.subprotocol) |proto| {
            try writer.print("Sec-WebSocket-Protocol: {s}\r\n", .{proto});
        }

        for (self.config.headers.items) |header| {
            try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
        }

        try writer.writeAll("\r\n");

        return buf.toOwnedSlice();
    }

    /// Encode a text message as a WebSocket frame
    pub fn encodeTextFrame(allocator: Allocator, message: []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);

        // First byte: FIN=1, opcode=0x1 (text)
        try buf.append(0x81);

        // Second byte: MASK=1 + payload length
        const len = message.len;
        if (len <= 125) {
            try buf.append(@as(u8, @intCast(len)) | 0x80);
        } else if (len <= 65535) {
            try buf.append(126 | 0x80);
            try buf.append(@as(u8, @intCast((len >> 8) & 0xFF)));
            try buf.append(@as(u8, @intCast(len & 0xFF)));
        } else {
            try buf.append(127 | 0x80);
            // 8 bytes of length (big-endian)
            const len64: u64 = @intCast(len);
            var i: u6 = 56;
            while (true) {
                try buf.append(@as(u8, @intCast((len64 >> i) & 0xFF)));
                if (i == 0) break;
                i -= 8;
            }
        }

        // Masking key (fixed for simplicity)
        const mask_key = [4]u8{ 0x37, 0xFA, 0x21, 0x3D };
        try buf.appendSlice(&mask_key);

        // Masked payload
        for (message, 0..) |byte, idx| {
            try buf.append(byte ^ mask_key[idx % 4]);
        }

        return buf.toOwnedSlice();
    }

    /// Encode a close frame
    pub fn encodeCloseFrame(allocator: Allocator, code: u16, reason: []const u8) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);

        // First byte: FIN=1, opcode=0x8 (close)
        try buf.append(0x88);

        // Payload = 2 bytes status code + reason
        const payload_len = 2 + reason.len;
        if (payload_len <= 125) {
            try buf.append(@as(u8, @intCast(payload_len)) | 0x80);
        } else {
            try buf.append(126 | 0x80);
            try buf.append(@as(u8, @intCast((payload_len >> 8) & 0xFF)));
            try buf.append(@as(u8, @intCast(payload_len & 0xFF)));
        }

        // Masking key
        const mask_key = [4]u8{ 0x37, 0xFA, 0x21, 0x3D };
        try buf.appendSlice(&mask_key);

        // Masked status code (big-endian)
        try buf.append(@as(u8, @intCast((code >> 8) & 0xFF)) ^ mask_key[0]);
        try buf.append(@as(u8, @intCast(code & 0xFF)) ^ mask_key[1]);

        // Masked reason
        for (reason, 0..) |byte, idx| {
            try buf.append(byte ^ mask_key[(idx + 2) % 4]);
        }

        return buf.toOwnedSlice();
    }

    /// Encode a ping frame
    pub fn encodePingFrame(allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);

        // First byte: FIN=1, opcode=0x9 (ping)
        try buf.append(0x89);
        // Second byte: MASK=1, length=0
        try buf.append(0x80);
        // Masking key (required even with zero payload)
        const mask_key = [4]u8{ 0x37, 0xFA, 0x21, 0x3D };
        try buf.appendSlice(&mask_key);

        return buf.toOwnedSlice();
    }

    /// Decode a WebSocket frame header
    pub fn decodeFrameHeader(data: []const u8) ?FrameHeader {
        if (data.len < 2) return null;

        const fin = (data[0] & 0x80) != 0;
        const opcode: u4 = @intCast(data[0] & 0x0F);
        const masked = (data[1] & 0x80) != 0;
        const len7: u7 = @intCast(data[1] & 0x7F);

        var payload_length: u64 = 0;
        var header_size: usize = 2;

        if (len7 <= 125) {
            payload_length = @intCast(len7);
        } else if (len7 == 126) {
            if (data.len < 4) return null;
            payload_length = (@as(u64, data[2]) << 8) | @as(u64, data[3]);
            header_size = 4;
        } else if (len7 == 127) {
            if (data.len < 10) return null;
            payload_length = 0;
            for (0..8) |i| {
                payload_length = (payload_length << 8) | @as(u64, data[2 + i]);
            }
            header_size = 10;
        }

        if (masked) {
            header_size += 4; // masking key
        }

        return FrameHeader{
            .fin = fin,
            .opcode = opcode,
            .masked = masked,
            .payload_length = payload_length,
            .header_size = header_size,
        };
    }

    /// Record a sent message
    pub fn recordSent(self: *WebSocketSession, msg_type: MessageType, data: []const u8) !void {
        try self.message_log.append(.{
            .msg_type = msg_type,
            .data = data,
            .timestamp = std.time.timestamp(),
        });
        self.messages_sent += 1;
    }

    /// Record a received message
    pub fn recordReceived(self: *WebSocketSession, msg_type: MessageType, data: []const u8) !void {
        try self.message_log.append(.{
            .msg_type = msg_type,
            .data = data,
            .timestamp = std.time.timestamp(),
        });
        self.messages_received += 1;
    }

    /// Get message history
    pub fn getHistory(self: *const WebSocketSession) []const WebSocketMessage {
        return self.message_log.items;
    }
};

pub const WsUrlParts = struct {
    secure: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

/// Parse WebSocket URL (ws://host:port/path or wss://host:port/path)
pub fn parseWsUrl(url: []const u8) ?WsUrlParts {
    var secure = false;
    var rest: []const u8 = undefined;

    if (mem.startsWith(u8, url, "wss://")) {
        secure = true;
        rest = url["wss://".len..];
    } else if (mem.startsWith(u8, url, "ws://")) {
        secure = false;
        rest = url["ws://".len..];
    } else {
        return null;
    }

    // Split host:port from path
    var host: []const u8 = rest;
    var path: []const u8 = "/";
    var port: u16 = if (secure) 443 else 80;

    // Find path separator
    if (mem.indexOf(u8, rest, "/")) |slash_pos| {
        host = rest[0..slash_pos];
        path = rest[slash_pos..];
    }

    // Check for port in host
    if (mem.indexOf(u8, host, ":")) |colon_pos| {
        const port_str = host[colon_pos + 1 ..];
        host = host[0..colon_pos];
        port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    }

    if (host.len == 0) return null;

    return WsUrlParts{
        .secure = secure,
        .host = host,
        .port = port,
        .path = path,
    };
}

/// Format session info for display
pub fn formatSession(session: *const WebSocketSession, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("\x1b[1mWebSocket Session\x1b[0m\n");
    try writer.print("  URL:               {s}\n", .{session.config.url});
    try writer.print("  State:             {s}\n", .{switch (session.state) {
        .connecting => "connecting",
        .open => "open",
        .closing => "closing",
        .closed => "closed",
    }});
    try writer.print("  Messages Sent:     {d}\n", .{session.messages_sent});
    try writer.print("  Messages Received: {d}\n", .{session.messages_received});
    try writer.print("  History Size:      {d}\n", .{session.message_log.items.len});

    if (session.config.subprotocol) |proto| {
        try writer.print("  Subprotocol:       {s}\n", .{proto});
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse ws url" {
    const parts = parseWsUrl("ws://echo.websocket.org:8080/test").?;
    try std.testing.expectEqualStrings("echo.websocket.org", parts.host);
    try std.testing.expectEqual(@as(u16, 8080), parts.port);
    try std.testing.expectEqualStrings("/test", parts.path);
    try std.testing.expect(!parts.secure);

    const secure_parts = parseWsUrl("wss://secure.example.com/ws").?;
    try std.testing.expectEqualStrings("secure.example.com", secure_parts.host);
    try std.testing.expectEqual(@as(u16, 443), secure_parts.port);
    try std.testing.expectEqualStrings("/ws", secure_parts.path);
    try std.testing.expect(secure_parts.secure);

    // Invalid URL
    try std.testing.expect(parseWsUrl("http://example.com") == null);
}

test "encode text frame" {
    const frame = try WebSocketSession.encodeTextFrame(std.testing.allocator, "Hello");
    defer std.testing.allocator.free(frame);

    // First byte should be 0x81 (FIN + text)
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]);
    // Second byte: MASK=1 (0x80) | length=5 (0x05) = 0x85
    try std.testing.expectEqual(@as(u8, 0x85), frame[1]);
    // Masking key is 4 bytes at positions 2-5
    // Total frame: 2 (header) + 4 (mask) + 5 (payload) = 11
    try std.testing.expectEqual(@as(usize, 11), frame.len);

    // Verify masked payload can be unmasked
    const mask_key = frame[2..6];
    var unmasked: [5]u8 = undefined;
    for (0..5) |i| {
        unmasked[i] = frame[6 + i] ^ mask_key[i % 4];
    }
    try std.testing.expectEqualStrings("Hello", &unmasked);
}

test "decode frame header" {
    // Build a simple unmasked text frame header: FIN=1, opcode=1, no mask, length=5
    const data = [_]u8{ 0x81, 0x05 };
    const header = WebSocketSession.decodeFrameHeader(&data).?;

    try std.testing.expect(header.fin);
    try std.testing.expectEqual(@as(u4, 1), header.opcode);
    try std.testing.expect(!header.masked);
    try std.testing.expectEqual(@as(u64, 5), header.payload_length);
    try std.testing.expectEqual(@as(usize, 2), header.header_size);

    // Test masked frame header
    const masked_data = [_]u8{ 0x81, 0x85, 0x37, 0xFA, 0x21, 0x3D };
    const masked_header = WebSocketSession.decodeFrameHeader(&masked_data).?;
    try std.testing.expect(masked_header.masked);
    try std.testing.expectEqual(@as(u64, 5), masked_header.payload_length);
    try std.testing.expectEqual(@as(usize, 6), masked_header.header_size);
}
