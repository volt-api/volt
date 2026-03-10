//! QUIC connection state machine and UDP I/O.
//!
//! Manages the QUIC handshake, packet send/recv, packet number spaces,
//! and crypto/application stream dispatch. Uses connected UDP sockets
//! for cross-platform compatibility (including Windows).

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const net = std.net;
const posix = std.posix;
const testing = std.testing;

const crypto_mod = @import("crypto.zig");
const packet_mod = @import("packet.zig");
const stream_mod = @import("stream.zig");
const tls_mod = @import("tls_provider.zig");

const ConnectionId = packet_mod.ConnectionId;
const PacketType = packet_mod.PacketType;
const Frame = packet_mod.Frame;

const RECV_BUF_SIZE = 65535;
const DEFAULT_TIMEOUT_MS = 5000;
const MAX_HANDSHAKE_RETRIES = 5;

pub const ConnectionState = enum {
    idle,
    handshaking,
    connected,
    closed,
};

pub const QuicConnection = struct {
    state: ConnectionState = .idle,
    allocator: mem.Allocator,

    // Connection IDs
    dcid: ConnectionId,
    scid: ConnectionId,

    // TLS provider
    tls: tls_mod.Provider,

    // Crypto streams (per-epoch)
    crypto_streams: stream_mod.CryptoStreams,

    // Application streams
    app_streams: std.AutoHashMap(u64, stream_mod.Stream),

    // Per-stream write offsets
    stream_offsets: std.AutoHashMap(u64, u64),

    // Packet number spaces
    pn_spaces: packet_mod.PacketNumberSpaces,

    // UDP socket
    socket: ?posix.socket_t = null,
    peer_addr: ?net.Address = null,

    // Host info
    host: []const u8,
    port: u16,

    // Outgoing packet queue
    pending_packets: std.ArrayList(std.ArrayList(u8)),

    // Whether we've updated DCID from the first server response
    dcid_updated: bool = false,

    pub fn init(host: []const u8, port: u16, allocator: mem.Allocator) QuicConnection {
        var tls_provider = tls_mod.Provider.init(allocator);
        tls_provider.server_name = host;

        return .{
            .allocator = allocator,
            .dcid = ConnectionId.initRandom(8),
            .scid = ConnectionId.initRandom(8),
            .tls = tls_provider,
            .crypto_streams = stream_mod.CryptoStreams.init(allocator),
            .app_streams = std.AutoHashMap(u64, stream_mod.Stream).init(allocator),
            .stream_offsets = std.AutoHashMap(u64, u64).init(allocator),
            .pn_spaces = packet_mod.PacketNumberSpaces.init(allocator),
            .host = host,
            .port = port,
            .pending_packets = std.ArrayList(std.ArrayList(u8)).init(allocator),
        };
    }

    pub fn deinit(self: *QuicConnection) void {
        self.tls.deinit();
        self.crypto_streams.deinit();

        var it = self.app_streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.app_streams.deinit();

        self.stream_offsets.deinit();

        self.pn_spaces.deinit();

        for (self.pending_packets.items) |*pkt| {
            pkt.deinit();
        }
        self.pending_packets.deinit();

        if (self.socket) |sock| {
            posix.close(sock);
        }
    }

    /// Create UDP socket and connect to peer.
    pub fn createSocket(self: *QuicConnection) !void {
        // Resolve host — try IP parsing first, fall back to DNS for hostnames
        var addr: net.Address = undefined;
        if (net.Address.resolveIp(self.host, self.port)) |a| {
            addr = a;
        } else |_| {
            // DNS resolution for hostnames via getAddressList
            const list = try net.getAddressList(self.allocator, self.host, self.port);
            defer list.deinit();
            if (list.addrs.len == 0) return error.AddressNotFound;
            addr = list.addrs[0];
        }
        self.peer_addr = addr;

        // Create UDP socket
        const sock = try posix.socket(
            addr.any.family,
            posix.SOCK.DGRAM,
            0,
        );
        errdefer posix.close(sock);

        // Connect UDP socket (sets default peer address)
        try posix.connect(sock, &addr.any, addr.getOsSockLen());

        // Set receive timeout so read() doesn't block forever
        if (builtin.os.tag == .windows) {
            const ws2 = std.os.windows.ws2_32;
            const timeout_ms: i32 = @intCast(DEFAULT_TIMEOUT_MS);
            _ = ws2.setsockopt(sock, ws2.SOL.SOCKET, ws2.SO.RCVTIMEO, @ptrCast(std.mem.asBytes(&timeout_ms)), @sizeOf(i32));
        } else {
            const timeout_opt: [@sizeOf(posix.timeval)]u8 = blk: {
                const tv: posix.timeval = if (comptime @hasField(posix.timeval, "tv_sec"))
                    .{ .tv_sec = @intCast(DEFAULT_TIMEOUT_MS / 1000), .tv_usec = @intCast((DEFAULT_TIMEOUT_MS % 1000) * 1000) }
                else
                    .{ .sec = @intCast(DEFAULT_TIMEOUT_MS / 1000), .usec = @intCast((DEFAULT_TIMEOUT_MS % 1000) * 1000) };
                break :blk @bitCast(tv);
            };
            posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &timeout_opt) catch |err| {
                std.debug.print("warning: quic/connection: setsockopt RCVTIMEO failed: {s}\n", .{@errorName(err)});
            };
        }

        self.socket = sock;
    }

    /// Initiate the QUIC handshake.
    pub fn connect(self: *QuicConnection) !void {
        if (self.socket == null) {
            try self.createSocket();
        }

        self.state = .handshaking;

        // Initiate TLS handshake (builds ClientHello, writes to crypto stream)
        const initial_stream = self.crypto_streams.getPtr(.initial);
        try self.tls.initiateHandshake(initial_stream, self.dcid, self.scid);

        // Build and send Initial packet with CRYPTO frames
        try self.buildAndSendInitial();
    }

    /// Run the handshake loop until connected or timeout.
    pub fn handshakeLoop(self: *QuicConnection) !void {
        const sock = self.socket orelse return error.SocketNotCreated;
        var recv_buf: [RECV_BUF_SIZE]u8 = undefined;
        var retries: usize = 0;

        while (self.state == .handshaking and retries < MAX_HANDSHAKE_RETRIES) {
            // Try to receive a packet (non-blocking with timeout)
            const n = posix.read(sock, &recv_buf) catch |err| {
                if (err == error.WouldBlock) {
                    retries += 1;
                    // Retransmit initial
                    try self.buildAndSendInitial();
                    continue;
                }
                return err;
            };

            if (n == 0) {
                retries += 1;
                continue;
            }

            try self.handleReceivedPacket(recv_buf[0..n]);

            // Check if handshake is complete
            if (self.tls.state == .connected) {
                // Send client Finished
                try self.sendClientFinished();
                self.state = .connected;
                return;
            }

            // Send any pending handshake packets
            try self.flushHandshakePackets();
        }

        if (self.state != .connected) {
            return error.HandshakeTimeout;
        }
    }

    /// Send data on a QUIC stream.
    pub fn sendStream(self: *QuicConnection, stream_id: u64, data: []const u8, fin: bool) !void {
        const sock = self.socket orelse return error.SocketNotCreated;
        const client_keys = self.tls.client_master orelse return error.NotConnected;

        // Get current offset for this stream
        const current_offset = self.stream_offsets.get(stream_id) orelse 0;

        // Build STREAM frame with correct offset
        const stream_frame = Frame{
            .stream = .{
                .stream_id = stream_id,
                .offset = current_offset,
                .data = data,
                .fin = fin,
            },
        };

        const pn = self.pn_spaces.application.generate();
        const frames = [_]Frame{stream_frame};

        // Use short header (1-RTT) for application data
        const encrypted = try packet_mod.encodeShortPacket(
            self.dcid,
            pn,
            &frames,
            client_keys,
            self.allocator,
        );
        defer encrypted.deinit();

        _ = try posix.write(sock, encrypted.items);

        // Update stream offset
        try self.stream_offsets.put(stream_id, current_offset + data.len);
    }

    /// Receive data from the UDP socket and process it.
    pub fn recv(self: *QuicConnection) !void {
        const sock = self.socket orelse return error.SocketNotCreated;
        var recv_buf: [RECV_BUF_SIZE]u8 = undefined;

        const n = posix.read(sock, &recv_buf) catch |err| {
            if (err == error.WouldBlock) return;
            return err;
        };

        if (n > 0) {
            try self.handleReceivedPacket(recv_buf[0..n]);
        }
    }

    /// Read data received on a specific stream.
    pub fn readStream(self: *QuicConnection, stream_id: u64, buf: []u8) usize {
        if (self.app_streams.getPtr(stream_id)) |stream| {
            return stream.receiver.read(buf);
        }
        return 0;
    }

    /// Read all available data from a stream.
    pub fn readStreamAll(self: *QuicConnection, stream_id: u64) !?std.ArrayList(u8) {
        if (self.app_streams.getPtr(stream_id)) |stream| {
            var result = try stream.receiver.readAll(self.allocator);
            if (result.items.len == 0) {
                result.deinit();
                return null;
            }
            return result;
        }
        return null;
    }

    /// Check if a stream has received a FIN.
    pub fn isStreamFinished(self: *QuicConnection, stream_id: u64) bool {
        if (self.app_streams.getPtr(stream_id)) |stream| {
            return stream.recv_fin;
        }
        return false;
    }

    /// Send CONNECTION_CLOSE and cleanup.
    pub fn close(self: *QuicConnection) void {
        if (self.socket != null and self.state == .connected) {
            const close_frame = Frame{
                .connection_close = .{
                    .error_code = 0,
                },
            };
            const keys = self.tls.client_master orelse {
                self.state = .closed;
                return;
            };

            const pn = self.pn_spaces.application.generate();
            const frames = [_]Frame{close_frame};

            // Use short header for application-level close
            const encrypted = packet_mod.encodeShortPacket(
                self.dcid,
                pn,
                &frames,
                keys,
                self.allocator,
            ) catch {
                self.state = .closed;
                return;
            };
            defer encrypted.deinit();

            if (self.socket) |sock| {
                _ = posix.write(sock, encrypted.items) catch |err| {
                    std.debug.print("warning: quic/connection: close packet write failed: {s}\n", .{@errorName(err)});
                };
            }
        }
        self.state = .closed;
    }

    pub fn isConnected(self: *const QuicConnection) bool {
        return self.state == .connected;
    }

    // -- Private methods --------------------------------------------------

    fn handleReceivedPacket(self: *QuicConnection, data: []const u8) !void {
        var remaining = data;

        // Loop to handle coalesced packets (e.g., Initial + Handshake in one UDP datagram)
        while (remaining.len >= 5) {
            const first_byte = remaining[0];
            const is_long = (first_byte & 0x80) != 0;

            if (is_long) {
                const consumed = try self.handleLongHeaderPacket(remaining);
                if (consumed == 0 or consumed > remaining.len) break;
                remaining = remaining[consumed..];
            } else {
                // Short header packets always come last (no length field)
                try self.handleShortHeaderPacket(remaining);
                break;
            }
        }
    }

    fn handleLongHeaderPacket(self: *QuicConnection, data: []const u8) !usize {
        const decoded = packet_mod.decodeLongHeader(data) catch return data.len;
        const consumed = decoded.header_bytes.len + decoded.payload_bytes.len;

        // Get decryption keys for this packet type
        const keys = self.tls.getServerKeys(decoded.packet_type) orelse return consumed;

        // Decrypt the packet
        var decrypted = crypto_mod.decryptPacket(
            decoded.header_bytes,
            decoded.payload_bytes,
            keys.key,
            keys.iv,
            keys.hp,
            self.allocator,
            false,
        ) catch return consumed;
        defer decrypted.deinit();

        // Update DCID from server's SCID on first response
        if (self.state == .handshaking and !self.dcid_updated) {
            self.dcid = decoded.scid;
            self.dcid_updated = true;
        }

        // Record packet number for ACK
        const header_len = decoded.header_bytes.len;
        if (decrypted.items.len > header_len) {
            // Extract packet number from decrypted header
            const pn_len: usize = @as(usize, @intCast(decrypted.items[0] & 0x03)) + 1;
            if (header_len + pn_len <= decrypted.items.len) {
                var pn: u32 = 0;
                for (decrypted.items[header_len..][0..pn_len]) |b| {
                    pn = (pn << 8) | @as(u32, b);
                }
                const space = self.pn_spaces.getPtr(decoded.packet_type.toSpace());
                try space.recordReceived(pn);
            }
        }

        // Parse frames from decrypted payload (after header + PN)
        const pn_len: usize = @as(usize, @intCast(decrypted.items[0] & 0x03)) + 1;
        const frame_data = decrypted.items[decoded.header_bytes.len + pn_len ..];
        try self.processFrames(frame_data, decoded.packet_type.toEpoch());

        // Send ACK for this packet
        try self.sendAck(decoded.packet_type);

        return consumed;
    }

    fn handleShortHeaderPacket(self: *QuicConnection, data: []const u8) !void {
        // Short header: 1-RTT packets (application data)
        const keys = self.tls.server_master orelse return;

        // Short header format: flags (1) + DCID (N) + encrypted PN + payload
        const dcid_len = self.scid.len;
        if (data.len < 1 + dcid_len + 4) return;

        const header = data[0 .. 1 + dcid_len];
        const payload = data[1 + dcid_len ..];

        var decrypted = crypto_mod.decryptPacket(
            header,
            payload,
            keys.key,
            keys.iv,
            keys.hp,
            self.allocator,
            true,
        ) catch return;
        defer decrypted.deinit();

        const pn_length: usize = @as(usize, @intCast(decrypted.items[0] & 0x03)) + 1;

        // Record packet number for ACK generation
        var pn: u32 = 0;
        const pn_start = header.len;
        for (decrypted.items[pn_start..][0..pn_length]) |b| {
            pn = (pn << 8) | @as(u32, b);
        }
        try self.pn_spaces.application.recordReceived(pn);

        const frame_start = header.len + pn_length;
        if (frame_start < decrypted.items.len) {
            try self.processFrames(decrypted.items[frame_start..], .application);
        }

        // Send ACK for application data
        const app_space = &self.pn_spaces.application;
        if (app_space.buildAckFrame(self.allocator)) |ack_frame| {
            var ack = ack_frame;
            defer ack.deinit();
            const app_keys = self.tls.client_master orelse return;
            const ack_pn = app_space.generate();
            const ack_frames = [_]Frame{.{ .ack = ack_frame }};
            const encrypted = packet_mod.encodeShortPacket(self.dcid, ack_pn, &ack_frames, app_keys, self.allocator) catch return;
            defer encrypted.deinit();
            if (self.socket) |s| {
                _ = posix.write(s, encrypted.items) catch |err| {
                    std.debug.print("warning: quic/connection: ACK packet write failed: {s}\n", .{@errorName(err)});
                };
            }
        }
    }

    fn processFrames(self: *QuicConnection, data: []const u8, epoch: packet_mod.Epoch) !void {
        var stream = std.io.fixedBufferStream(data);
        const reader = stream.reader();

        while (stream.pos < data.len) {
            // Skip padding
            if (data[stream.pos] == 0) {
                stream.pos += 1;
                continue;
            }

            var frame = Frame.decode(reader, self.allocator) catch break;
            defer frame.deinit(self.allocator);

            switch (frame) {
                .crypto => |cf| {
                    var cs = self.crypto_streams.getPtr(epoch);
                    const duped = try self.allocator.dupe(u8, cf.data);
                    try cs.receiver.push(duped, cf.offset);

                    // Process TLS messages
                    try self.tls.handleStream(cs);
                },
                .stream => |sf| {
                    // Get or create application stream
                    const result = try self.app_streams.getOrPut(sf.stream_id);
                    if (!result.found_existing) {
                        result.value_ptr.* = stream_mod.Stream.init(self.allocator);
                    }
                    const duped = try self.allocator.dupe(u8, sf.data);
                    try result.value_ptr.receiver.push(duped, sf.offset);

                    if (sf.fin) {
                        result.value_ptr.recv_fin = true;
                    }
                },
                .ack => {},
                .handshake_done => {
                    if (self.state == .handshaking) {
                        self.state = .connected;
                    }
                },
                .connection_close => {
                    self.state = .closed;
                    return;
                },
                .padding => {},
            }
        }
    }

    fn sendAck(self: *QuicConnection, pkt_type: PacketType) !void {
        const sock = self.socket orelse return;
        const space = self.pn_spaces.getPtr(pkt_type.toSpace());

        const ack_frame_opt = space.buildAckFrame(self.allocator);
        if (ack_frame_opt) |ack_frame| {
            var ack = ack_frame;
            defer ack.deinit();

            const pn = space.generate();
            const frames = [_]Frame{.{ .ack = ack_frame }};

            const keys = self.tls.getClientKeysForType(pkt_type) orelse return;

            if (pkt_type == .initial or pkt_type == .handshake) {
                const encrypted = packet_mod.encodePacket(
                    pkt_type,
                    packet_mod.QUIC_VERSION_1,
                    self.dcid,
                    self.scid,
                    pn,
                    &frames,
                    keys,
                    self.allocator,
                    pkt_type == .initial,
                    null,
                ) catch return;
                defer encrypted.deinit();
                _ = posix.write(sock, encrypted.items) catch |err| {
                    std.debug.print("warning: quic/connection: sendAck initial/handshake write failed: {s}\n", .{@errorName(err)});
                };
            } else {
                const encrypted = packet_mod.encodeShortPacket(
                    self.dcid,
                    pn,
                    &frames,
                    keys,
                    self.allocator,
                ) catch return;
                defer encrypted.deinit();
                _ = posix.write(sock, encrypted.items) catch |err| {
                    std.debug.print("warning: quic/connection: sendAck short packet write failed: {s}\n", .{@errorName(err)});
                };
            }
        }
    }

    fn buildAndSendInitial(self: *QuicConnection) !void {
        const sock = self.socket orelse return error.SocketNotCreated;
        const keys = self.tls.client_initial orelse return error.KeyNotInstalled;

        // Get crypto data from initial stream
        var initial_stream = self.crypto_streams.getPtr(.initial);
        var frames = std.ArrayList(Frame).init(self.allocator);
        defer frames.deinit();

        // Emit crypto frames
        while (try initial_stream.sender.emit(RECV_BUF_SIZE, self.allocator)) |range_buf| {
            const data = try self.allocator.dupe(u8, range_buf.buf);
            var rb = range_buf;
            rb.deinit(self.allocator);
            try frames.append(.{
                .crypto = .{
                    .offset = rb.offset,
                    .data = data,
                },
            });
        }

        if (frames.items.len == 0) return;

        const pn = self.pn_spaces.initial.generate();
        const encrypted = try packet_mod.encodePacket(
            .initial,
            packet_mod.QUIC_VERSION_1,
            self.dcid,
            self.scid,
            pn,
            frames.items,
            keys,
            self.allocator,
            true,
            null,
        );
        defer encrypted.deinit();

        // Free crypto frame data
        for (frames.items) |*f| {
            f.deinit(self.allocator);
        }

        _ = try posix.write(sock, encrypted.items);
    }

    fn flushHandshakePackets(self: *QuicConnection) !void {
        const sock = self.socket orelse return error.SocketNotCreated;

        // Send handshake crypto data
        var hs_stream = self.crypto_streams.getPtr(.handshake);
        var frames = std.ArrayList(Frame).init(self.allocator);
        defer frames.deinit();

        while (try hs_stream.sender.emit(RECV_BUF_SIZE, self.allocator)) |range_buf| {
            const data = try self.allocator.dupe(u8, range_buf.buf);
            var rb = range_buf;
            rb.deinit(self.allocator);
            try frames.append(.{
                .crypto = .{
                    .offset = rb.offset,
                    .data = data,
                },
            });
        }

        if (frames.items.len == 0) return;

        const hs_keys = self.tls.client_handshake orelse return;
        const pn = self.pn_spaces.handshake.generate();

        const encrypted = try packet_mod.encodePacket(
            .handshake,
            packet_mod.QUIC_VERSION_1,
            self.dcid,
            self.scid,
            pn,
            frames.items,
            hs_keys,
            self.allocator,
            false,
            null,
        );
        defer encrypted.deinit();

        for (frames.items) |*f| {
            f.deinit(self.allocator);
        }

        _ = try posix.write(sock, encrypted.items);
    }

    fn sendClientFinished(self: *QuicConnection) !void {
        const finished_bytes = try self.tls.getFinishedBytes() orelse return;
        defer self.allocator.free(finished_bytes);

        var hs_stream = self.crypto_streams.getPtr(.handshake);
        try hs_stream.sender.write(finished_bytes);

        try self.flushHandshakePackets();
    }
};

// -- Tests ----------------------------------------------------------------

test "QuicConnection - init and deinit" {
    var conn = QuicConnection.init("localhost", 443, testing.allocator);
    defer conn.deinit();

    try testing.expectEqual(ConnectionState.idle, conn.state);
    try testing.expectEqual(@as(u8, 8), conn.dcid.len);
    try testing.expectEqual(@as(u8, 8), conn.scid.len);
}

test "QuicConnection - state transitions" {
    var conn = QuicConnection.init("localhost", 443, testing.allocator);
    defer conn.deinit();

    try testing.expect(!conn.isConnected());
    conn.state = .connected;
    try testing.expect(conn.isConnected());
}

test "PacketNumberSpaces - isolation" {
    var spaces = packet_mod.PacketNumberSpaces.init(testing.allocator);
    defer spaces.deinit();

    const pn0 = spaces.initial.generate();
    const pn1 = spaces.initial.generate();
    const pn2 = spaces.handshake.generate();

    try testing.expectEqual(@as(u32, 0), pn0);
    try testing.expectEqual(@as(u32, 1), pn1);
    try testing.expectEqual(@as(u32, 0), pn2);
}

test "QuicConnection - close from idle" {
    var conn = QuicConnection.init("localhost", 443, testing.allocator);
    defer conn.deinit();

    conn.close();
    try testing.expectEqual(ConnectionState.closed, conn.state);
}
