//! QUIC stream buffer management: ordered reassembly for received data
//! and FIFO queue for outgoing data. Also manages per-epoch crypto streams.

const std = @import("std");
const mem = std.mem;
const math = std.math;
const testing = std.testing;
const packet = @import("packet.zig");

// ── Range Buffer ─────────────────────────────────────────────────────────

/// A buffer associated with a byte offset in a stream.
pub const RangeBuf = struct {
    buf: []const u8,
    offset: u64,

    pub fn fromSlice(buf: []const u8, offset: u64) RangeBuf {
        return .{ .buf = buf, .offset = offset };
    }

    pub fn endOffset(self: RangeBuf) u64 {
        return self.offset + self.buf.len;
    }

    pub fn getSliceWithOffset(self: RangeBuf, offset: u64) ?[]const u8 {
        if (offset < self.offset) return null;
        const pos: usize = @intCast(offset - self.offset);
        if (pos >= self.buf.len) return self.buf[self.buf.len..];
        return self.buf[pos..];
    }

    pub fn deinit(self: *RangeBuf, allocator: mem.Allocator) void {
        allocator.free(self.buf);
    }
};

// ── Receive Stream ───────────────────────────────────────────────────────

/// Receive-side stream buffer with ordered reassembly via priority queue.
pub const RecvStream = struct {
    data: std.PriorityQueue(RangeBuf, void, rangePriorTo),
    offset: u64 = 0,
    allocator: mem.Allocator,

    fn rangePriorTo(_: void, a: RangeBuf, b: RangeBuf) std.math.Order {
        const ord = math.order(a.offset, b.offset);
        if (ord != .eq) return ord;
        return math.order(a.endOffset(), b.endOffset());
    }

    pub fn init(allocator: mem.Allocator) RecvStream {
        return .{
            .data = std.PriorityQueue(RangeBuf, void, rangePriorTo).init(allocator, {}),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RecvStream) void {
        while (self.data.count() > 0) {
            var buf = self.data.remove();
            buf.deinit(self.allocator);
        }
        self.data.deinit();
    }

    /// Push data at a given byte offset. Data is duped by the caller.
    pub fn push(self: *RecvStream, buf: []const u8, offset: u64) !void {
        const r_buf = RangeBuf.fromSlice(buf, offset);
        try self.data.add(r_buf);
    }

    /// Read contiguous data starting from current offset.
    pub fn read(self: *RecvStream, out: []u8) usize {
        var total: usize = 0;

        while (self.data.count() > 0) {
            const top = self.data.peek().?;
            if (top.endOffset() <= self.offset) {
                var removed = self.data.remove();
                removed.deinit(self.allocator);
                continue;
            }

            if (top.offset > self.offset) break; // gap

            if (top.getSliceWithOffset(self.offset)) |slice| {
                const copy_len = @min(out.len - total, slice.len);
                if (copy_len == 0) break;
                @memcpy(out[total..][0..copy_len], slice[0..copy_len]);
                total += copy_len;
                self.offset += copy_len;

                if (top.endOffset() <= self.offset) {
                    var removed = self.data.remove();
                    removed.deinit(self.allocator);
                }
            } else break;
        }

        return total;
    }

    /// Read all available contiguous data into an ArrayList.
    pub fn readAll(self: *RecvStream, allocator: mem.Allocator) !std.ArrayList(u8) {
        var result = std.ArrayList(u8).init(allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.read(&buf);
            if (n == 0) break;
            try result.appendSlice(buf[0..n]);
        }
        return result;
    }
};

// ── Send Stream ──────────────────────────────────────────────────────────

/// Send-side stream buffer (FIFO queue of outgoing data).
pub const SendStream = struct {
    chunks: std.ArrayList(RangeBuf),
    write_offset: u64 = 0,
    read_offset: u64 = 0,
    allocator: mem.Allocator,

    pub fn init(allocator: mem.Allocator) SendStream {
        return .{
            .chunks = std.ArrayList(RangeBuf).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SendStream) void {
        for (self.chunks.items) |*chunk| {
            chunk.deinit(self.allocator);
        }
        self.chunks.deinit();
    }

    /// Write data to the send buffer. Data is duped.
    pub fn write(self: *SendStream, data: []const u8) !void {
        const copy = try self.allocator.dupe(u8, data);
        try self.chunks.append(RangeBuf.fromSlice(copy, self.write_offset));
        self.write_offset += data.len;
    }

    /// Emit up to max_len bytes of data from the send buffer.
    pub fn emit(self: *SendStream, max_len: usize, allocator: mem.Allocator) !?RangeBuf {
        if (self.chunks.items.len == 0) return null;

        const chunk = &self.chunks.items[0];
        const pos: usize = @intCast(self.read_offset - chunk.offset);
        const available = chunk.buf.len - pos;
        const len = @min(max_len, available);

        const copy = try allocator.dupe(u8, chunk.buf[pos..][0..len]);
        const offset = self.read_offset;
        self.read_offset += len;

        if (chunk.endOffset() <= self.read_offset) {
            var removed = self.chunks.orderedRemove(0);
            removed.deinit(self.allocator);
        }

        return RangeBuf.fromSlice(copy, offset);
    }

    /// Check if there is data pending to send.
    pub fn hasPending(self: *const SendStream) bool {
        return self.chunks.items.len > 0 and self.read_offset < self.write_offset;
    }
};

// ── Bidirectional Stream ─────────────────────────────────────────────────

pub const Stream = struct {
    receiver: RecvStream,
    sender: SendStream,
    recv_fin: bool = false,
    send_fin: bool = false,

    pub fn init(allocator: mem.Allocator) Stream {
        return .{
            .receiver = RecvStream.init(allocator),
            .sender = SendStream.init(allocator),
        };
    }

    pub fn deinit(self: *Stream) void {
        self.receiver.deinit();
        self.sender.deinit();
    }
};

// ── Crypto Streams (per-epoch) ───────────────────────────────────────────

pub const CryptoStreams = struct {
    initial: Stream,
    handshake: Stream,
    application: Stream,

    pub fn init(allocator: mem.Allocator) CryptoStreams {
        return .{
            .initial = Stream.init(allocator),
            .handshake = Stream.init(allocator),
            .application = Stream.init(allocator),
        };
    }

    pub fn deinit(self: *CryptoStreams) void {
        self.initial.deinit();
        self.handshake.deinit();
        self.application.deinit();
    }

    pub fn getPtr(self: *CryptoStreams, epoch: packet.Epoch) *Stream {
        return switch (epoch) {
            .initial => &self.initial,
            .handshake => &self.handshake,
            .application, .no_crypto => &self.application,
        };
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

test "RecvStream - push and read in order" {
    var rs = RecvStream.init(testing.allocator);
    defer rs.deinit();

    try rs.push(try testing.allocator.dupe(u8, "Hello"), 0);
    try rs.push(try testing.allocator.dupe(u8, ", World"), 5);

    var buf: [32]u8 = undefined;
    const n = rs.read(&buf);
    try testing.expectEqualStrings("Hello, World", buf[0..n]);
}

test "RecvStream - push out of order" {
    var rs = RecvStream.init(testing.allocator);
    defer rs.deinit();

    try rs.push(try testing.allocator.dupe(u8, "World"), 5);
    try rs.push(try testing.allocator.dupe(u8, "Hello"), 0);

    var buf: [32]u8 = undefined;
    const n = rs.read(&buf);
    try testing.expectEqualStrings("HelloWorld", buf[0..n]);
}

test "RecvStream - gap blocks read" {
    var rs = RecvStream.init(testing.allocator);
    defer rs.deinit();

    try rs.push(try testing.allocator.dupe(u8, "Hello"), 0);
    // Skip offset 5-9, push at 10
    try rs.push(try testing.allocator.dupe(u8, "World"), 10);

    var buf: [32]u8 = undefined;
    const n1 = rs.read(&buf);
    try testing.expectEqualStrings("Hello", buf[0..n1]);

    // Gap at offset 5, can't read further
    const n2 = rs.read(&buf);
    try testing.expectEqual(@as(usize, 0), n2);
}

test "SendStream - write and emit" {
    var ss = SendStream.init(testing.allocator);
    defer ss.deinit();

    try ss.write("hello, world.");
    try ss.write("abcdef");

    var buf1 = (try ss.emit(5, testing.allocator)).?;
    defer buf1.deinit(testing.allocator);
    try testing.expectEqualStrings("hello", buf1.buf);

    var buf2 = (try ss.emit(500, testing.allocator)).?;
    defer buf2.deinit(testing.allocator);
    try testing.expectEqualStrings(", world.", buf2.buf);

    var buf3 = (try ss.emit(500, testing.allocator)).?;
    defer buf3.deinit(testing.allocator);
    try testing.expectEqualStrings("abcdef", buf3.buf);

    const buf4 = try ss.emit(500, testing.allocator);
    try testing.expect(buf4 == null);
}

test "CryptoStreams - per-epoch isolation" {
    var cs = CryptoStreams.init(testing.allocator);
    defer cs.deinit();

    try cs.getPtr(.initial).sender.write("initial data");
    try cs.getPtr(.handshake).sender.write("handshake data");

    var buf1 = (try cs.getPtr(.initial).sender.emit(100, testing.allocator)).?;
    defer buf1.deinit(testing.allocator);
    try testing.expectEqualStrings("initial data", buf1.buf);

    var buf2 = (try cs.getPtr(.handshake).sender.emit(100, testing.allocator)).?;
    defer buf2.deinit(testing.allocator);
    try testing.expectEqualStrings("handshake data", buf2.buf);
}

test "RangeBuf - getSliceWithOffset" {
    const data = "0123456789";
    const buf = RangeBuf.fromSlice(data, 10);

    try testing.expect(buf.getSliceWithOffset(5) == null);
    try testing.expectEqualStrings(data, buf.getSliceWithOffset(10).?);
    try testing.expectEqualStrings(data[2..], buf.getSliceWithOffset(12).?);
}
