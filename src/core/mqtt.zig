const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── MQTT Protocol Support (v3.1.1) ──────────────────────────────────────
//
// MQTT client for API testing.
// Supports building and parsing MQTT packets for publish/subscribe
// messaging over lightweight IoT and messaging protocols.
//
// MQTT v3.1.1 packet structure:
//   Fixed header: packet type (4 bits) + flags (4 bits) + remaining length
//   Variable header: protocol-specific fields
//   Payload: message data

pub const MqttConfig = struct {
    host: []const u8 = "localhost",
    port: u16 = 1883,
    client_id: []const u8 = "volt-client",
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    keep_alive: u16 = 60,
    clean_session: bool = true,
};

pub const MqttMessage = struct {
    topic: []const u8,
    payload: []const u8,
    qos: u8,
    retain: bool,
};

pub const MqttClient = struct {
    config: MqttConfig,
    connected: bool,
    messages: std.ArrayList(MqttMessage),
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: MqttConfig) MqttClient {
        return .{
            .config = config,
            .connected = false,
            .messages = std.ArrayList(MqttMessage).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MqttClient) void {
        self.messages.deinit();
    }
};

/// Encode MQTT remaining length using variable-length encoding.
/// Values 0-127 use 1 byte, 128-16383 use 2 bytes, etc. up to 4 bytes.
pub fn encodeRemainingLength(length: u32) struct { bytes: [4]u8, len: u8 } {
    var result = [4]u8{ 0, 0, 0, 0 };
    var encoded_len: u8 = 0;
    var value = length;

    while (true) {
        var encoded_byte: u8 = @intCast(value % 128);
        value = value / 128;
        if (value > 0) {
            encoded_byte |= 0x80;
        }
        result[encoded_len] = encoded_byte;
        encoded_len += 1;
        if (value == 0) break;
    }

    return .{ .bytes = result, .len = encoded_len };
}

/// Decode MQTT variable-length remaining length from raw bytes.
pub fn decodeRemainingLength(data: []const u8) struct { value: u32, bytes_used: u8 } {
    var multiplier: u32 = 1;
    var value: u32 = 0;
    var index: u8 = 0;

    while (index < 4 and index < data.len) {
        const encoded_byte = data[index];
        value += @as(u32, encoded_byte & 0x7F) * multiplier;
        index += 1;
        if ((encoded_byte & 0x80) == 0) break;
        multiplier *= 128;
    }

    return .{ .value = value, .bytes_used = index };
}

/// Build MQTT CONNECT packet (packet type 1).
/// Protocol: "MQTT", level 4 (v3.1.1), flags for clean session/username/password.
pub fn buildConnectPacket(allocator: Allocator, config: MqttConfig) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Variable header: protocol name "MQTT"
    // Length MSB, Length LSB, 'M', 'Q', 'T', 'T'
    try buf.appendSlice(&[_]u8{ 0x00, 0x04, 'M', 'Q', 'T', 'T' });

    // Protocol level: 4 (MQTT 3.1.1)
    try buf.append(0x04);

    // Connect flags
    var flags: u8 = 0;
    if (config.clean_session) flags |= 0x02;
    if (config.username != null) flags |= 0x80;
    if (config.password != null) flags |= 0x40;
    try buf.append(flags);

    // Keep alive (big-endian u16)
    try buf.append(@intCast((config.keep_alive >> 8) & 0xFF));
    try buf.append(@intCast(config.keep_alive & 0xFF));

    // Payload: Client ID (length-prefixed UTF-8 string)
    const client_id_len: u16 = @intCast(config.client_id.len);
    try buf.append(@intCast((client_id_len >> 8) & 0xFF));
    try buf.append(@intCast(client_id_len & 0xFF));
    try buf.appendSlice(config.client_id);

    // Optional username
    if (config.username) |username| {
        const uname_len: u16 = @intCast(username.len);
        try buf.append(@intCast((uname_len >> 8) & 0xFF));
        try buf.append(@intCast(uname_len & 0xFF));
        try buf.appendSlice(username);
    }

    // Optional password
    if (config.password) |password| {
        const pass_len: u16 = @intCast(password.len);
        try buf.append(@intCast((pass_len >> 8) & 0xFF));
        try buf.append(@intCast(pass_len & 0xFF));
        try buf.appendSlice(password);
    }

    // Now build the fixed header
    const remaining = encodeRemainingLength(@intCast(buf.items.len));
    var packet = std.ArrayList(u8).init(allocator);
    errdefer packet.deinit();

    // Fixed header: packet type 1 (CONNECT) shifted left 4 bits
    try packet.append(0x10);
    try packet.appendSlice(remaining.bytes[0..remaining.len]);
    try packet.appendSlice(buf.items);

    buf.deinit();
    return packet.toOwnedSlice();
}

/// Build MQTT PUBLISH packet (packet type 3).
pub fn buildPublishPacket(allocator: Allocator, topic: []const u8, payload: []const u8, qos: u8, retain: bool) ![]const u8 {
    var var_buf = std.ArrayList(u8).init(allocator);
    errdefer var_buf.deinit();

    // Variable header: topic name (length-prefixed)
    const topic_len: u16 = @intCast(topic.len);
    try var_buf.append(@intCast((topic_len >> 8) & 0xFF));
    try var_buf.append(@intCast(topic_len & 0xFF));
    try var_buf.appendSlice(topic);

    // If QoS > 0, include a packet identifier
    if (qos > 0) {
        try var_buf.append(0x00);
        try var_buf.append(0x01);
    }

    // Payload
    try var_buf.appendSlice(payload);

    // Build fixed header
    const remaining = encodeRemainingLength(@intCast(var_buf.items.len));
    var packet = std.ArrayList(u8).init(allocator);
    errdefer packet.deinit();

    // Packet type 3 (PUBLISH) with flags: DUP=0, QoS, RETAIN
    var first_byte: u8 = 0x30;
    first_byte |= (@as(u8, qos) & 0x03) << 1;
    if (retain) first_byte |= 0x01;
    try packet.append(first_byte);
    try packet.appendSlice(remaining.bytes[0..remaining.len]);
    try packet.appendSlice(var_buf.items);

    var_buf.deinit();
    return packet.toOwnedSlice();
}

/// Build MQTT SUBSCRIBE packet (packet type 8).
pub fn buildSubscribePacket(allocator: Allocator, packet_id: u16, topic: []const u8, qos: u8) ![]const u8 {
    var var_buf = std.ArrayList(u8).init(allocator);
    errdefer var_buf.deinit();

    // Variable header: packet identifier
    try var_buf.append(@intCast((packet_id >> 8) & 0xFF));
    try var_buf.append(@intCast(packet_id & 0xFF));

    // Payload: topic filter (length-prefixed) + requested QoS
    const topic_len: u16 = @intCast(topic.len);
    try var_buf.append(@intCast((topic_len >> 8) & 0xFF));
    try var_buf.append(@intCast(topic_len & 0xFF));
    try var_buf.appendSlice(topic);
    try var_buf.append(qos);

    // Build fixed header
    const remaining = encodeRemainingLength(@intCast(var_buf.items.len));
    var packet = std.ArrayList(u8).init(allocator);
    errdefer packet.deinit();

    // Packet type 8 (SUBSCRIBE) with reserved flags (0x02)
    try packet.append(0x82);
    try packet.appendSlice(remaining.bytes[0..remaining.len]);
    try packet.appendSlice(var_buf.items);

    var_buf.deinit();
    return packet.toOwnedSlice();
}

/// Build MQTT PINGREQ packet (0xC0, 0x00).
pub fn buildPingPacket() [2]u8 {
    return [2]u8{ 0xC0, 0x00 };
}

/// Build MQTT DISCONNECT packet (0xE0, 0x00).
pub fn buildDisconnectPacket() [2]u8 {
    return [2]u8{ 0xE0, 0x00 };
}

/// Parse an incoming PUBLISH packet into an MqttMessage.
/// Returns null if the data is not a valid PUBLISH packet.
pub fn parsePublishPacket(allocator: Allocator, data: []const u8) ?MqttMessage {
    if (data.len < 4) return null;

    // Check packet type is PUBLISH (type 3, upper 4 bits = 0x30)
    const first_byte = data[0];
    if ((first_byte & 0xF0) != 0x30) return null;

    const retain = (first_byte & 0x01) != 0;
    const qos: u8 = (first_byte >> 1) & 0x03;

    // Decode remaining length
    const remaining = decodeRemainingLength(data[1..]);
    if (remaining.bytes_used == 0) return null;
    const header_size: usize = 1 + @as(usize, remaining.bytes_used);

    if (data.len < header_size + remaining.value) return null;
    const payload_start = header_size;
    const payload_data = data[payload_start..payload_start + remaining.value];

    // Parse topic length
    if (payload_data.len < 2) return null;
    const topic_len: u16 = (@as(u16, payload_data[0]) << 8) | @as(u16, payload_data[1]);
    if (payload_data.len < 2 + @as(usize, topic_len)) return null;

    const topic = payload_data[2 .. 2 + topic_len];

    // If QoS > 0, skip the 2-byte packet identifier
    var msg_offset: usize = 2 + @as(usize, topic_len);
    if (qos > 0) {
        if (payload_data.len < msg_offset + 2) return null;
        msg_offset += 2;
    }

    const payload = payload_data[msg_offset..];

    // Duplicate strings so the caller owns them
    const topic_copy = allocator.dupe(u8, topic) catch return null;
    const payload_copy = allocator.dupe(u8, payload) catch {
        allocator.free(topic_copy);
        return null;
    };

    return MqttMessage{
        .topic = topic_copy,
        .payload = payload_copy,
        .qos = qos,
        .retain = retain,
    };
}

/// Format an MqttMessage for display: "[topic] payload"
pub fn formatMessage(allocator: Allocator, msg: MqttMessage) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("[{s}] {s}", .{ msg.topic, msg.payload });

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "encode and decode remaining length roundtrip" {
    // Test single-byte lengths
    const enc0 = encodeRemainingLength(0);
    try std.testing.expectEqual(@as(u8, 1), enc0.len);
    try std.testing.expectEqual(@as(u8, 0), enc0.bytes[0]);

    const dec0 = decodeRemainingLength(&enc0.bytes);
    try std.testing.expectEqual(@as(u32, 0), dec0.value);

    const enc127 = encodeRemainingLength(127);
    try std.testing.expectEqual(@as(u8, 1), enc127.len);
    const dec127 = decodeRemainingLength(&enc127.bytes);
    try std.testing.expectEqual(@as(u32, 127), dec127.value);

    // Test two-byte lengths
    const enc128 = encodeRemainingLength(128);
    try std.testing.expectEqual(@as(u8, 2), enc128.len);
    const dec128 = decodeRemainingLength(enc128.bytes[0..enc128.len]);
    try std.testing.expectEqual(@as(u32, 128), dec128.value);

    const enc16383 = encodeRemainingLength(16383);
    try std.testing.expectEqual(@as(u8, 2), enc16383.len);
    const dec16383 = decodeRemainingLength(enc16383.bytes[0..enc16383.len]);
    try std.testing.expectEqual(@as(u32, 16383), dec16383.value);

    // Test three-byte lengths
    const enc16384 = encodeRemainingLength(16384);
    try std.testing.expectEqual(@as(u8, 3), enc16384.len);
    const dec16384 = decodeRemainingLength(enc16384.bytes[0..enc16384.len]);
    try std.testing.expectEqual(@as(u32, 16384), dec16384.value);

    // Test four-byte length (max MQTT remaining length: 268435455)
    const enc_max = encodeRemainingLength(268435455);
    try std.testing.expectEqual(@as(u8, 4), enc_max.len);
    const dec_max = decodeRemainingLength(enc_max.bytes[0..enc_max.len]);
    try std.testing.expectEqual(@as(u32, 268435455), dec_max.value);
}

test "build connect packet structure" {
    const config = MqttConfig{
        .host = "broker.example.com",
        .port = 1883,
        .client_id = "test-client",
        .username = "user",
        .password = "pass",
        .keep_alive = 60,
        .clean_session = true,
    };

    const packet = try buildConnectPacket(std.testing.allocator, config);
    defer std.testing.allocator.free(packet);

    // First byte: CONNECT packet type (0x10)
    try std.testing.expectEqual(@as(u8, 0x10), packet[0]);

    // Decode remaining length
    const remaining = decodeRemainingLength(packet[1..]);
    const header_end: usize = 1 + @as(usize, remaining.bytes_used);

    // Protocol name "MQTT" at offset header_end
    try std.testing.expectEqual(@as(u8, 0x00), packet[header_end]);
    try std.testing.expectEqual(@as(u8, 0x04), packet[header_end + 1]);
    try std.testing.expectEqualStrings("MQTT", packet[header_end + 2 .. header_end + 6]);

    // Protocol level 4
    try std.testing.expectEqual(@as(u8, 0x04), packet[header_end + 6]);

    // Connect flags: clean session (0x02) | username (0x80) | password (0x40) = 0xC2
    try std.testing.expectEqual(@as(u8, 0xC2), packet[header_end + 7]);

    // Total packet should contain all fields
    try std.testing.expect(packet.len > 20);
}

test "build connect packet without credentials" {
    const config = MqttConfig{
        .client_id = "simple-client",
        .clean_session = true,
    };

    const packet = try buildConnectPacket(std.testing.allocator, config);
    defer std.testing.allocator.free(packet);

    try std.testing.expectEqual(@as(u8, 0x10), packet[0]);

    // Decode and check flags: only clean session (0x02)
    const remaining = decodeRemainingLength(packet[1..]);
    const header_end: usize = 1 + @as(usize, remaining.bytes_used);
    try std.testing.expectEqual(@as(u8, 0x02), packet[header_end + 7]);
}

test "parse publish packet" {
    // Build a PUBLISH packet and then parse it
    const packet = try buildPublishPacket(std.testing.allocator, "test/topic", "hello world", 0, false);
    defer std.testing.allocator.free(packet);

    const msg = parsePublishPacket(std.testing.allocator, packet).?;
    defer std.testing.allocator.free(msg.topic);
    defer std.testing.allocator.free(msg.payload);

    try std.testing.expectEqualStrings("test/topic", msg.topic);
    try std.testing.expectEqualStrings("hello world", msg.payload);
    try std.testing.expectEqual(@as(u8, 0), msg.qos);
    try std.testing.expect(!msg.retain);
}

test "parse publish packet with qos and retain" {
    const packet = try buildPublishPacket(std.testing.allocator, "sensor/temp", "22.5", 1, true);
    defer std.testing.allocator.free(packet);

    const msg = parsePublishPacket(std.testing.allocator, packet).?;
    defer std.testing.allocator.free(msg.topic);
    defer std.testing.allocator.free(msg.payload);

    try std.testing.expectEqualStrings("sensor/temp", msg.topic);
    try std.testing.expectEqualStrings("22.5", msg.payload);
    try std.testing.expectEqual(@as(u8, 1), msg.qos);
    try std.testing.expect(msg.retain);
}

test "parse publish packet rejects non-publish" {
    // PINGREQ packet should not parse as PUBLISH
    const ping = buildPingPacket();
    try std.testing.expect(parsePublishPacket(std.testing.allocator, &ping) == null);
}

test "format message" {
    const msg = MqttMessage{
        .topic = "home/living-room/temp",
        .payload = "23.5",
        .qos = 0,
        .retain = false,
    };

    const formatted = try formatMessage(std.testing.allocator, msg);
    defer std.testing.allocator.free(formatted);

    try std.testing.expectEqualStrings("[home/living-room/temp] 23.5", formatted);
}

test "ping and disconnect packets" {
    const ping = buildPingPacket();
    try std.testing.expectEqual(@as(u8, 0xC0), ping[0]);
    try std.testing.expectEqual(@as(u8, 0x00), ping[1]);

    const disconnect = buildDisconnectPacket();
    try std.testing.expectEqual(@as(u8, 0xE0), disconnect[0]);
    try std.testing.expectEqual(@as(u8, 0x00), disconnect[1]);
}

test "subscribe packet structure" {
    const packet = try buildSubscribePacket(std.testing.allocator, 1, "test/topic", 1);
    defer std.testing.allocator.free(packet);

    // First byte: SUBSCRIBE packet type (0x82)
    try std.testing.expectEqual(@as(u8, 0x82), packet[0]);

    // Packet should contain the topic
    try std.testing.expect(mem.indexOf(u8, packet, "test/topic") != null);
}
