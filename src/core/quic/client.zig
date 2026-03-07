//! High-level HTTP/3 client that integrates QUIC transport with
//! the existing h3.zig HTTP/3 framing and QPACK compression.
//!
//! Provides a single `sendRequest()` function that:
//! 1. Establishes a QUIC connection (TLS 1.3 handshake over UDP)
//! 2. Opens HTTP/3 control + QPACK streams
//! 3. Sends HEADERS + DATA frames via QPACK
//! 4. Reads response HEADERS + DATA frames
//! 5. Returns structured H3Response

const std = @import("std");
const mem = std.mem;
const testing = std.testing;

const connection = @import("connection.zig");
const packet = @import("packet.zig");
const stream_mod = @import("stream.zig");
const H3 = @import("../h3.zig");

pub const H3Response = struct {
    status_code: u16,
    headers: std.ArrayList(H3.Header),
    body: std.ArrayList(u8),

    pub fn init(allocator: mem.Allocator) H3Response {
        return .{
            .status_code = 0,
            .headers = std.ArrayList(H3.Header).init(allocator),
            .body = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *H3Response) void {
        self.headers.deinit();
        self.body.deinit();
    }
};

/// Send an HTTP/3 request over a real QUIC/UDP connection.
///
/// This is the main entry point for HTTP/3 transport. It handles:
/// - QUIC connection establishment (UDP socket + TLS 1.3 handshake)
/// - HTTP/3 control stream setup (SETTINGS frame)
/// - QPACK encoder stream setup
/// - Request encoding (HEADERS + DATA frames on a request stream)
/// - Response decoding (parsing HEADERS + DATA from the response stream)
pub fn sendRequest(
    host: []const u8,
    port: u16,
    method: []const u8,
    path: []const u8,
    headers: []const H3.Header,
    body: ?[]const u8,
    allocator: mem.Allocator,
) !H3Response {
    var response = H3Response.init(allocator);
    errdefer response.deinit();

    // 1. Create QUIC connection
    var conn = connection.QuicConnection.init(host, port, allocator);
    defer conn.deinit();

    // Establish connection (UDP socket + TLS handshake)
    try conn.connect();
    try conn.handshakeLoop();

    if (!conn.isConnected()) {
        return error.ConnectionFailed;
    }

    // 2. Open HTTP/3 control stream (unidirectional stream 2)
    //    Send stream type (0x00 = control) + SETTINGS frame
    {
        const settings = H3.Settings{};
        const settings_frame = try H3.buildSettingsFrame(allocator, settings);
        defer allocator.free(settings_frame);

        // Control stream: type byte (0x00) + SETTINGS frame
        var control_data = std.ArrayList(u8).init(allocator);
        defer control_data.deinit();
        try control_data.append(0x00); // Control stream type
        try control_data.appendSlice(settings_frame);

        try conn.sendStream(2, control_data.items, false);
    }

    // 3. Open QPACK encoder stream (unidirectional stream 6)
    {
        var encoder_data = [_]u8{0x02}; // QPACK encoder stream type
        try conn.sendStream(6, &encoder_data, false);
    }

    // 4. Open request stream (bidirectional stream 0)
    //    Send HEADERS frame + optional DATA frame, then FIN
    {
        // Build request headers including pseudo-headers
        var h3_headers = std.ArrayList(H3.Header).init(allocator);
        defer h3_headers.deinit();

        // Add pseudo-headers
        try h3_headers.append(.{ .name = ":method", .value = method });
        try h3_headers.append(.{ .name = ":path", .value = path });
        try h3_headers.append(.{ .name = ":scheme", .value = "https" });
        try h3_headers.append(.{ .name = ":authority", .value = host });

        // Add user headers
        for (headers) |h| {
            try h3_headers.append(h);
        }

        // Encode headers with QPACK
        const encoded_headers = try H3.encodeHeaders(allocator, h3_headers.items);
        defer allocator.free(encoded_headers);

        // Build HEADERS frame
        const headers_frame = try H3.buildHeadersFrame(allocator, encoded_headers);
        defer allocator.free(headers_frame);

        // Build request data
        var request_data = std.ArrayList(u8).init(allocator);
        defer request_data.deinit();
        try request_data.appendSlice(headers_frame);

        // Add DATA frame if body present
        if (body) |b| {
            if (b.len > 0) {
                const data_frame = try H3.buildDataFrame(allocator, b);
                defer allocator.free(data_frame);
                try request_data.appendSlice(data_frame);
            }
        }

        // Send on stream 0 with FIN
        try conn.sendStream(0, request_data.items, true);
    }

    // 5. Read response
    //    Receive packets and look for HEADERS + DATA frames on stream 0
    {
        var recv_attempts: usize = 0;
        const max_recv_attempts: usize = 200;
        var got_headers = false;
        var no_data_count: usize = 0;
        var expected_length: ?usize = null;

        while (recv_attempts < max_recv_attempts) : (recv_attempts += 1) {
            conn.recv() catch break;

            var got_data_this_round = false;

            // Try to read response data from stream 0
            if (conn.readStreamAll(0)) |maybe_data| {
                if (maybe_data) |*data| {
                    defer data.deinit();
                    got_data_this_round = true;
                    no_data_count = 0;

                    // Parse H3 frames from response
                    var offset: usize = 0;
                    while (offset < data.items.len) {
                        const frame_result = H3.parseFrame(data.items[offset..]);
                        if (frame_result) |result| {
                            offset += result.total_bytes;
                            const frame = result.frame;

                            switch (frame.frame_type) {
                                .headers => {
                                    // Decode QPACK headers
                                    if (frame.payload.len > 0) {
                                        var decoded = H3.decodeHeaderBlock(allocator, frame.payload) catch null;
                                        if (decoded) |*hdrs| {
                                            defer hdrs.deinit();
                                            for (hdrs.items) |h| {
                                                if (mem.eql(u8, h.name, ":status")) {
                                                    response.status_code = std.fmt.parseInt(u16, h.value, 10) catch 0;
                                                } else {
                                                    if (mem.eql(u8, h.name, "content-length")) {
                                                        expected_length = std.fmt.parseInt(usize, h.value, 10) catch null;
                                                    }
                                                    try response.headers.append(h);
                                                }
                                            }
                                            got_headers = true;
                                        }
                                    }
                                },
                                .data => {
                                    if (frame.payload.len > 0) {
                                        try response.body.appendSlice(frame.payload);
                                    }
                                },
                                else => {},
                            }
                        } else break;
                    }
                }
            } else |_| {}

            // Check if stream 0 has received FIN (response complete)
            if (conn.isStreamFinished(0)) break;

            // Check completion heuristics
            if (got_headers) {
                // Bodyless responses: 1xx, 204, 304
                if (response.status_code == 204 or response.status_code == 304 or
                    (response.status_code >= 100 and response.status_code < 200))
                {
                    break;
                }
                // Content-length based completion — break when full body received
                if (expected_length) |expected| {
                    if (response.body.items.len >= expected) break;
                }
            }

            // If we're getting no new data, count idle rounds
            if (!got_data_this_round) {
                no_data_count += 1;
                // After getting headers, bail after idle rounds (increased for large responses)
                if (got_headers and no_data_count >= 10) break;
            }
        }
    }

    // 6. Close connection
    conn.close();

    return response;
}

// ── Tests ────────────────────────────────────────────────────────────────

test "H3Response init and deinit" {
    var resp = H3Response.init(testing.allocator);
    defer resp.deinit();

    resp.status_code = 200;
    try resp.headers.append(.{ .name = "content-type", .value = "text/html" });
    try resp.body.appendSlice("<html></html>");

    try testing.expectEqual(@as(u16, 200), resp.status_code);
    try testing.expectEqualStrings("text/html", resp.headers.items[0].value);
    try testing.expectEqualStrings("<html></html>", resp.body.items);
}

test "H3Response default status" {
    var resp = H3Response.init(testing.allocator);
    defer resp.deinit();
    try testing.expectEqual(@as(u16, 0), resp.status_code);
}
