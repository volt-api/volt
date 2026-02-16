const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Server-Sent Events (SSE) Client ────────────────────────────────────
//
// Server-Sent Events (SSE) client.
// Connects to event stream endpoints and parses SSE protocol events.
//
// SSE Protocol:
//   event: name\n
//   data: payload\n
//   id: event-id\n
//   retry: 5000\n
//   \n

pub const SSEEvent = struct {
    event_type: []const u8,
    data: []const u8,
    id: ?[]const u8,
    retry_ms: ?u32,
    timestamp: i64,
};

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const SSEConfig = struct {
    url: []const u8 = "",
    headers: std.ArrayList(HeaderPair),
    last_event_id: ?[]const u8 = null,
    retry_ms: u32 = 3000,
    max_events: u32 = 0,
    auto_reconnect: bool = true,

    pub fn init(allocator: Allocator) SSEConfig {
        return .{
            .headers = std.ArrayList(HeaderPair).init(allocator),
        };
    }

    pub fn deinit(self: *SSEConfig) void {
        self.headers.deinit();
    }
};

pub const SSESession = struct {
    config: SSEConfig,
    events: std.ArrayList(SSEEvent),
    total_events: u64,
    connected: bool,
    last_event_id: ?[]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: SSEConfig) SSESession {
        return .{
            .config = config,
            .events = std.ArrayList(SSEEvent).init(allocator),
            .total_events = 0,
            .connected = false,
            .last_event_id = config.last_event_id,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SSESession) void {
        self.events.deinit();
    }

    /// Record a parsed event
    pub fn recordEvent(self: *SSESession, event: SSEEvent) !void {
        try self.events.append(event);
        self.total_events += 1;
        if (event.id) |id| {
            self.last_event_id = id;
        }
    }

    /// Get events of a specific type
    pub fn getEventsByType(self: *const SSESession, event_type: []const u8) std.ArrayList(SSEEvent) {
        var result = std.ArrayList(SSEEvent).init(self.allocator);
        for (self.events.items) |event| {
            if (mem.eql(u8, event.event_type, event_type)) {
                result.append(event) catch continue;
            }
        }
        return result;
    }

    /// Get all events
    pub fn getEvents(self: *const SSESession) []const SSEEvent {
        return self.events.items;
    }
};

/// Parse SSE stream data into events.
/// Input is the raw text stream containing event blocks separated by \n\n
pub fn parseEvents(allocator: Allocator, stream_data: []const u8) !std.ArrayList(SSEEvent) {
    var events = std.ArrayList(SSEEvent).init(allocator);

    // Split on double newlines to get event blocks
    var rest = stream_data;
    while (rest.len > 0) {
        // Find the next blank line (double newline separator)
        var block_end: usize = rest.len;
        var next_start: usize = rest.len;

        // Look for \n\n separator
        if (mem.indexOf(u8, rest, "\n\n")) |pos| {
            block_end = pos;
            next_start = pos + 2;
        } else if (mem.indexOf(u8, rest, "\r\n\r\n")) |pos| {
            block_end = pos;
            next_start = pos + 4;
        }

        const block = mem.trim(u8, rest[0..block_end], " \t\n\r");
        if (block.len > 0) {
            if (parseSingleEvent(allocator, block)) |event| {
                try events.append(event);
            }
        }

        if (next_start >= rest.len) break;
        rest = rest[next_start..];
    }

    return events;
}

/// Parse a single event block (lines between \n\n separators)
pub fn parseSingleEvent(allocator: Allocator, block: []const u8) ?SSEEvent {
    var event_type: []const u8 = "message";
    var id: ?[]const u8 = null;
    var retry_ms: ?u32 = null;
    var data_parts = std.ArrayList(u8).init(allocator);
    var has_data = false;

    var lines = mem.splitSequence(u8, block, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trimRight(u8, raw_line, "\r");

        // Lines starting with ':' are comments - ignore
        if (line.len > 0 and line[0] == ':') continue;

        // Empty line
        if (line.len == 0) continue;

        if (mem.startsWith(u8, line, "event:")) {
            event_type = mem.trim(u8, line["event:".len..], " ");
        } else if (mem.startsWith(u8, line, "data:")) {
            const data_val = mem.trim(u8, line["data:".len..], " ");
            if (has_data) {
                data_parts.append('\n') catch return null;
            }
            data_parts.appendSlice(data_val) catch return null;
            has_data = true;
        } else if (mem.startsWith(u8, line, "id:")) {
            id = mem.trim(u8, line["id:".len..], " ");
        } else if (mem.startsWith(u8, line, "retry:")) {
            const retry_str = mem.trim(u8, line["retry:".len..], " ");
            retry_ms = std.fmt.parseInt(u32, retry_str, 10) catch null;
        }
    }

    if (!has_data) {
        data_parts.deinit();
        return null;
    }

    // We keep the data in the ArrayList's backing memory (owned by the caller via the items slice)
    const data_slice = data_parts.toOwnedSlice() catch return null;

    return SSEEvent{
        .event_type = event_type,
        .data = data_slice,
        .id = id,
        .retry_ms = retry_ms,
        .timestamp = std.time.timestamp(),
    };
}

/// Build the SSE connection request headers
pub fn buildSSEHeaders(allocator: Allocator, config: *const SSEConfig) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("Accept: text/event-stream\r\n");
    try writer.writeAll("Cache-Control: no-cache\r\n");
    try writer.writeAll("Connection: keep-alive\r\n");

    if (config.last_event_id) |last_id| {
        try writer.print("Last-Event-ID: {s}\r\n", .{last_id});
    }

    for (config.headers.items) |header| {
        try writer.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    return buf.toOwnedSlice();
}

/// Format events for display
pub fn formatEvents(events: []const SSEEvent, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("\x1b[1mSSE Events\x1b[0m\n\n");

    for (events, 0..) |event, i| {
        try writer.print("  \x1b[36m[{d}]\x1b[0m ", .{i + 1});
        try writer.print("type: \x1b[33m{s}\x1b[0m", .{event.event_type});

        if (event.id) |id| {
            try writer.print("  id: {s}", .{id});
        }

        try writer.writeAll("\n");

        // Data preview (truncate if too long)
        const max_preview = 100;
        if (event.data.len > max_preview) {
            try writer.print("      data: {s}...\n", .{event.data[0..max_preview]});
        } else {
            try writer.print("      data: {s}\n", .{event.data});
        }
    }

    try writer.print("\n  Total: {d} events\n", .{events.len});

    return buf.toOwnedSlice();
}

/// Format session info for display
pub fn formatSession(session: *const SSESession, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("\x1b[1mSSE Session\x1b[0m\n");
    try writer.print("  URL:            {s}\n", .{session.config.url});
    try writer.print("  Connected:      {s}\n", .{if (session.connected) "yes" else "no"});
    try writer.print("  Total Events:   {d}\n", .{session.total_events});
    try writer.print("  Retry Interval: {d}ms\n", .{session.config.retry_ms});

    if (session.last_event_id) |id| {
        try writer.print("  Last Event ID:  {s}\n", .{id});
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse single event" {
    const block =
        \\event: update
        \\data: {"user": "alice"}
        \\id: 42
    ;
    const event = parseSingleEvent(std.testing.allocator, block).?;
    defer std.testing.allocator.free(event.data);

    try std.testing.expectEqualStrings("update", event.event_type);
    try std.testing.expectEqualStrings("{\"user\": \"alice\"}", event.data);
    try std.testing.expectEqualStrings("42", event.id.?);
}

test "parse events with multiple events" {
    const stream =
        \\event: message
        \\data: hello
        \\
        \\event: update
        \\data: world
        \\id: 2
    ;
    var events = try parseEvents(std.testing.allocator, stream);
    defer {
        for (events.items) |event| {
            std.testing.allocator.free(event.data);
        }
        events.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), events.items.len);
    try std.testing.expectEqualStrings("message", events.items[0].event_type);
    try std.testing.expectEqualStrings("hello", events.items[0].data);
    try std.testing.expectEqualStrings("update", events.items[1].event_type);
    try std.testing.expectEqualStrings("world", events.items[1].data);
    try std.testing.expectEqualStrings("2", events.items[1].id.?);
}

test "parse events with multi-line data" {
    const stream =
        \\data: line one
        \\data: line two
        \\data: line three
    ;
    var events = try parseEvents(std.testing.allocator, stream);
    defer {
        for (events.items) |event| {
            std.testing.allocator.free(event.data);
        }
        events.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("message", events.items[0].event_type);
    try std.testing.expectEqualStrings("line one\nline two\nline three", events.items[0].data);
}
