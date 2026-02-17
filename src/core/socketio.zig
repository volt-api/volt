const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Socket.IO Client Support (Protocol v4/v5) ──────────────────────────
//
// Socket.IO client for real-time API testing.
// Supports the Engine.IO transport layer and Socket.IO packet encoding.
//
// Engine.IO packet types: open(0), close(1), ping(2), pong(3), message(4), upgrade(5), noop(6)
// Socket.IO packet types: connect(0), disconnect(1), event(2), ack(3), error(4), binary_event(5), binary_ack(6)

pub const SocketIOConfig = struct {
    url: []const u8 = "http://localhost:3000",
    path: []const u8 = "/socket.io/",
    namespace: []const u8 = "/",
    auth: ?[]const u8 = null,
    reconnect: bool = true,
};

pub const PacketType = enum(u8) {
    connect = 0,
    disconnect = 1,
    event = 2,
    ack = 3,
    error_packet = 4,
    binary_event = 5,
    binary_ack = 6,

    pub fn toChar(self: PacketType) u8 {
        return @intFromEnum(self) + '0';
    }

    pub fn fromChar(c: u8) ?PacketType {
        if (c < '0' or c > '6') return null;
        return @enumFromInt(c - '0');
    }
};

pub const EngineIOPacketType = enum(u8) {
    open = 0,
    close = 1,
    ping = 2,
    pong = 3,
    message = 4,
    upgrade = 5,
    noop = 6,

    pub fn toChar(self: EngineIOPacketType) u8 {
        return @intFromEnum(self) + '0';
    }

    pub fn fromChar(c: u8) ?EngineIOPacketType {
        if (c < '0' or c > '6') return null;
        return @enumFromInt(c - '0');
    }
};

pub const SocketIOEvent = struct {
    name: []const u8,
    data: []const u8,
    id: ?u32,
};

pub const EngineIOOpenResult = struct {
    sid: []const u8,
    ping_interval: u32,
    ping_timeout: u32,
};

pub const SocketIOClient = struct {
    config: SocketIOConfig,
    connected: bool,
    sid: ?[]const u8,
    events: std.ArrayList(SocketIOEvent),
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: SocketIOConfig) SocketIOClient {
        return .{
            .config = config,
            .connected = false,
            .sid = null,
            .events = std.ArrayList(SocketIOEvent).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SocketIOClient) void {
        self.events.deinit();
    }
};

/// Build the Engine.IO HTTP polling handshake URL.
/// Format: {url}{path}?EIO=4&transport=polling
pub fn buildHandshakeUrl(allocator: Allocator, config: SocketIOConfig) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Strip trailing slash from url if path starts with slash
    var url = config.url;
    if (url.len > 0 and url[url.len - 1] == '/' and config.path.len > 0 and config.path[0] == '/') {
        url = url[0 .. url.len - 1];
    }

    try writer.print("{s}{s}?EIO=4&transport=polling", .{ url, config.path });

    return buf.toOwnedSlice();
}

/// Parse Engine.IO open packet.
/// The open packet is "0{json}" where json contains sid, pingInterval, pingTimeout.
/// Returns null if the data is not a valid open packet.
pub fn parseEngineIOOpen(allocator: Allocator, data: []const u8) ?EngineIOOpenResult {
    if (data.len < 2) return null;

    // Must start with '0' (Engine.IO open type)
    if (data[0] != '0') return null;

    const json_str = data[1..];

    // Simple JSON parser - extract "sid", "pingInterval", "pingTimeout"
    const sid = extractJsonString(json_str, "sid") orelse return null;
    const ping_interval = extractJsonNumber(json_str, "pingInterval") orelse 25000;
    const ping_timeout = extractJsonNumber(json_str, "pingTimeout") orelse 20000;

    const sid_copy = allocator.dupe(u8, sid) catch return null;

    return EngineIOOpenResult{
        .sid = sid_copy,
        .ping_interval = ping_interval,
        .ping_timeout = ping_timeout,
    };
}

/// Encode a Socket.IO packet.
/// Format: "{type}{namespace},{data}" (namespace omitted if "/")
pub fn encodePacket(allocator: Allocator, packet_type: PacketType, namespace: []const u8, data: ?[]const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Packet type digit
    try writer.writeByte(packet_type.toChar());

    // Namespace (only include if not the default "/")
    if (!mem.eql(u8, namespace, "/")) {
        try writer.print("{s},", .{namespace});
    }

    // Data payload
    if (data) |d| {
        try writer.writeAll(d);
    }

    return buf.toOwnedSlice();
}

/// Decode an incoming Socket.IO packet into a SocketIOEvent.
/// Returns null if the data cannot be parsed.
pub fn decodePacket(allocator: Allocator, raw: []const u8) ?SocketIOEvent {
    if (raw.len == 0) return null;

    // First character is the packet type
    const ptype = PacketType.fromChar(raw[0]) orelse return null;
    _ = ptype;

    var rest = raw[1..];

    // Check for namespace (contains comma)
    if (mem.indexOf(u8, rest, ",")) |comma_pos| {
        // There may be a namespace prefix before the comma
        const ns_candidate = rest[0..comma_pos];
        if (ns_candidate.len > 0 and ns_candidate[0] == '/') {
            rest = rest[comma_pos + 1 ..];
        }
    }

    // Try to parse as JSON array: ["event_name", data]
    if (rest.len > 0 and rest[0] == '[') {
        return parseEventArray(allocator, rest);
    }

    // Fallback: treat entire rest as data with "message" as event name
    if (rest.len > 0) {
        const name_copy = allocator.dupe(u8, "message") catch return null;
        const data_copy = allocator.dupe(u8, rest) catch {
            allocator.free(name_copy);
            return null;
        };
        return SocketIOEvent{
            .name = name_copy,
            .data = data_copy,
            .id = null,
        };
    }

    return null;
}

/// Encode an event as a JSON array: '["event_name",data]'
pub fn encodeEvent(allocator: Allocator, event_name: []const u8, data: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("[\"{s}\",{s}]", .{ event_name, data });

    return buf.toOwnedSlice();
}

/// Format a SocketIOEvent for display.
pub fn formatEvent(allocator: Allocator, event: SocketIOEvent) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("\x1b[36m{s}\x1b[0m", .{event.name});

    if (event.id) |id| {
        try writer.print(" (ack:{d})", .{id});
    }

    try writer.print(" {s}", .{event.data});

    return buf.toOwnedSlice();
}

// ── Internal Helpers ────────────────────────────────────────────────────

/// Extract a JSON string value by key from a simple JSON object.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key":"value"
    // Build the search pattern: "key":"
    var search_buf: [256]u8 = undefined;
    const search_prefix = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;

    const start_pos = mem.indexOf(u8, json, search_prefix) orelse return null;
    const value_start = start_pos + search_prefix.len;
    if (value_start >= json.len) return null;

    // Find closing quote
    const value_end = mem.indexOf(u8, json[value_start..], "\"") orelse return null;

    return json[value_start .. value_start + value_end];
}

/// Extract a JSON number value by key from a simple JSON object.
fn extractJsonNumber(json: []const u8, key: []const u8) ?u32 {
    // Search for "key":number
    var search_buf: [256]u8 = undefined;
    const search_prefix = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;

    const start_pos = mem.indexOf(u8, json, search_prefix) orelse return null;
    const value_start = start_pos + search_prefix.len;
    if (value_start >= json.len) return null;

    // Find the end of the number (non-digit character)
    var value_end: usize = value_start;
    while (value_end < json.len and json[value_end] >= '0' and json[value_end] <= '9') {
        value_end += 1;
    }

    if (value_end == value_start) return null;

    return std.fmt.parseInt(u32, json[value_start..value_end], 10) catch null;
}

/// Parse a JSON array like ["event_name", data] into a SocketIOEvent.
fn parseEventArray(allocator: Allocator, data: []const u8) ?SocketIOEvent {
    if (data.len < 4) return null;
    if (data[0] != '[') return null;

    // Find the event name (first quoted string)
    const first_quote = mem.indexOf(u8, data, "\"") orelse return null;
    const name_start = first_quote + 1;
    const name_end_offset = mem.indexOf(u8, data[name_start..], "\"") orelse return null;
    const name_end = name_start + name_end_offset;

    const event_name = data[name_start..name_end];

    // Find the comma after the closing quote
    const after_name = name_end + 1;
    const comma_pos = mem.indexOf(u8, data[after_name..], ",") orelse return null;
    const data_start = after_name + comma_pos + 1;

    // Rest until closing bracket (strip the trailing ']')
    if (data_start >= data.len) return null;
    var event_data = data[data_start..];
    if (event_data.len > 0 and event_data[event_data.len - 1] == ']') {
        event_data = event_data[0 .. event_data.len - 1];
    }
    event_data = mem.trim(u8, event_data, " ");

    const name_copy = allocator.dupe(u8, event_name) catch return null;
    const data_copy = allocator.dupe(u8, event_data) catch {
        allocator.free(name_copy);
        return null;
    };

    return SocketIOEvent{
        .name = name_copy,
        .data = data_copy,
        .id = null,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

test "build handshake url" {
    const config = SocketIOConfig{
        .url = "http://localhost:3000",
        .path = "/socket.io/",
    };

    const url = try buildHandshakeUrl(std.testing.allocator, config);
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings("http://localhost:3000/socket.io/?EIO=4&transport=polling", url);
}

test "build handshake url strips double slash" {
    const config = SocketIOConfig{
        .url = "http://localhost:3000/",
        .path = "/socket.io/",
    };

    const url = try buildHandshakeUrl(std.testing.allocator, config);
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings("http://localhost:3000/socket.io/?EIO=4&transport=polling", url);
}

test "encode and decode packet roundtrip" {
    // Encode an event packet with default namespace
    const encoded = try encodePacket(std.testing.allocator, .event, "/", "[\"chat\",\"hello\"]");
    defer std.testing.allocator.free(encoded);

    // Should be "2[\"chat\",\"hello\"]"
    try std.testing.expect(encoded[0] == '2');
    try std.testing.expect(mem.indexOf(u8, encoded, "chat") != null);

    // Decode it back
    const event = decodePacket(std.testing.allocator, encoded).?;
    defer std.testing.allocator.free(event.name);
    defer std.testing.allocator.free(event.data);

    try std.testing.expectEqualStrings("chat", event.name);
    try std.testing.expectEqualStrings("\"hello\"", event.data);
}

test "encode and decode packet with namespace" {
    const encoded = try encodePacket(std.testing.allocator, .event, "/admin", "[\"kick\",\"user1\"]");
    defer std.testing.allocator.free(encoded);

    // Should be "2/admin,[\"kick\",\"user1\"]"
    try std.testing.expect(encoded[0] == '2');
    try std.testing.expect(mem.indexOf(u8, encoded, "/admin,") != null);

    const event = decodePacket(std.testing.allocator, encoded).?;
    defer std.testing.allocator.free(event.name);
    defer std.testing.allocator.free(event.data);

    try std.testing.expectEqualStrings("kick", event.name);
    try std.testing.expectEqualStrings("\"user1\"", event.data);
}

test "encode event" {
    const encoded = try encodeEvent(std.testing.allocator, "message", "\"hello world\"");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("[\"message\",\"hello world\"]", encoded);
}

test "parse engine io open" {
    const data = "0{\"sid\":\"abc123\",\"upgrades\":[\"websocket\"],\"pingInterval\":25000,\"pingTimeout\":20000}";

    const result = parseEngineIOOpen(std.testing.allocator, data).?;
    defer std.testing.allocator.free(result.sid);

    try std.testing.expectEqualStrings("abc123", result.sid);
    try std.testing.expectEqual(@as(u32, 25000), result.ping_interval);
    try std.testing.expectEqual(@as(u32, 20000), result.ping_timeout);
}

test "parse engine io open rejects invalid" {
    // Not starting with '0'
    try std.testing.expect(parseEngineIOOpen(std.testing.allocator, "1{\"sid\":\"x\"}") == null);
    // Too short
    try std.testing.expect(parseEngineIOOpen(std.testing.allocator, "0") == null);
    // No sid
    try std.testing.expect(parseEngineIOOpen(std.testing.allocator, "0{\"foo\":\"bar\"}") == null);
}

test "format event" {
    const event = SocketIOEvent{
        .name = "chat",
        .data = "\"hello\"",
        .id = null,
    };

    const formatted = try formatEvent(std.testing.allocator, event);
    defer std.testing.allocator.free(formatted);

    try std.testing.expect(mem.indexOf(u8, formatted, "chat") != null);
    try std.testing.expect(mem.indexOf(u8, formatted, "hello") != null);
}

test "packet type conversions" {
    try std.testing.expectEqual(@as(u8, '0'), PacketType.connect.toChar());
    try std.testing.expectEqual(@as(u8, '2'), PacketType.event.toChar());
    try std.testing.expectEqual(PacketType.event, PacketType.fromChar('2').?);
    try std.testing.expect(PacketType.fromChar('9') == null);

    try std.testing.expectEqual(@as(u8, '2'), EngineIOPacketType.ping.toChar());
    try std.testing.expectEqual(EngineIOPacketType.message, EngineIOPacketType.fromChar('4').?);
    try std.testing.expect(EngineIOPacketType.fromChar('8') == null);
}
