//! QUIC transport module for Volt.
//!
//! Provides a minimal QUIC v1 client implementation built from scratch
//! using Zig stdlib crypto primitives. Used by the HTTP/3 transport layer.

pub const crypto = @import("quic/crypto.zig");
pub const packet = @import("quic/packet.zig");
pub const tls_provider = @import("quic/tls_provider.zig");
pub const stream = @import("quic/stream.zig");
pub const connection = @import("quic/connection.zig");
pub const client = @import("quic/client.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
