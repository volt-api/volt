const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// -- gRPC Protocol Support ------------------------------------------------
//
// gRPC uses HTTP/2 with Protocol Buffers. This module provides:
//   1. Protobuf-like message framing (length-prefixed binary framing)
//   2. gRPC request building (HTTP/2 headers and frame encoding)
//   3. Proto file parsing (extract service/method/message definitions)
//   4. .volt file generation from proto definitions
//   5. gRPC metadata (headers/trailers handling)
//
// gRPC wire format:
//   Messages are length-prefixed: 1 byte compressed flag + 4 bytes
//   big-endian length + message bytes.
//   Content-Type: application/grpc
//   Uses HTTP/2 (frames built here, actual transport via std.http).

pub const GrpcMethod = struct {
    service: []const u8,
    method: []const u8,
    input_type: []const u8,
    output_type: []const u8,
    is_client_streaming: bool,
    is_server_streaming: bool,
};

pub const ProtoField = struct {
    name: []const u8,
    field_type: []const u8,
    number: u32,
    repeated: bool,
};

pub const ProtoMessage = struct {
    name: []const u8,
    fields: std.ArrayList(ProtoField),

    pub fn init(allocator: Allocator, name: []const u8) ProtoMessage {
        return .{
            .name = name,
            .fields = std.ArrayList(ProtoField).init(allocator),
        };
    }

    pub fn deinit(self: *ProtoMessage) void {
        self.fields.deinit();
    }
};

pub const ProtoService = struct {
    name: []const u8,
    methods: std.ArrayList(GrpcMethod),

    pub fn init(allocator: Allocator, name: []const u8) ProtoService {
        return .{
            .name = name,
            .methods = std.ArrayList(GrpcMethod).init(allocator),
        };
    }

    pub fn deinit(self: *ProtoService) void {
        self.methods.deinit();
    }
};

pub const ProtoFile = struct {
    package: []const u8,
    services: std.ArrayList(ProtoService),
    messages: std.ArrayList(ProtoMessage),

    pub fn init(allocator: Allocator) ProtoFile {
        return .{
            .package = "",
            .services = std.ArrayList(ProtoService).init(allocator),
            .messages = std.ArrayList(ProtoMessage).init(allocator),
        };
    }

    pub fn deinit(self: *ProtoFile) void {
        for (self.services.items) |*svc| {
            svc.deinit();
        }
        self.services.deinit();
        for (self.messages.items) |*msg| {
            msg.deinit();
        }
        self.messages.deinit();
    }
};

/// Encode a message with gRPC length-prefix framing.
/// Format: [1 byte: compressed=0] [4 bytes: big-endian length] [message bytes]
pub fn encodeMessage(allocator: Allocator, message: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);

    // Compressed flag: 0 = not compressed
    try buf.append(0x00);

    // 4-byte big-endian message length
    const len: u32 = @intCast(message.len);
    try buf.append(@intCast((len >> 24) & 0xFF));
    try buf.append(@intCast((len >> 16) & 0xFF));
    try buf.append(@intCast((len >> 8) & 0xFF));
    try buf.append(@intCast(len & 0xFF));

    // Message payload
    try buf.appendSlice(message);

    return buf.toOwnedSlice();
}

/// Decode a gRPC length-prefixed message, returning the payload.
pub fn decodeMessage(data: []const u8) !struct { compressed: bool, payload: []const u8 } {
    if (data.len < 5) return error.InvalidMessage;

    const compressed = data[0] != 0;
    const len: u32 = (@as(u32, data[1]) << 24) |
        (@as(u32, data[2]) << 16) |
        (@as(u32, data[3]) << 8) |
        @as(u32, data[4]);

    if (data.len < 5 + len) return error.InvalidMessage;

    return .{
        .compressed = compressed,
        .payload = data[5 .. 5 + len],
    };
}

/// Skip whitespace and return the remaining slice.
fn skipWhitespace(input: []const u8) []const u8 {
    var i: usize = 0;
    while (i < input.len and (input[i] == ' ' or input[i] == '\t' or input[i] == '\n' or input[i] == '\r')) {
        i += 1;
    }
    return input[i..];
}

/// Find the next token (non-whitespace, non-delimiter sequence).
fn nextToken(input: []const u8) ?struct { token: []const u8, rest: []const u8 } {
    const trimmed = skipWhitespace(input);
    if (trimmed.len == 0) return null;

    // Single-character delimiters are tokens by themselves
    if (trimmed[0] == '{' or trimmed[0] == '}' or trimmed[0] == '(' or
        trimmed[0] == ')' or trimmed[0] == ';' or trimmed[0] == '=')
    {
        return .{ .token = trimmed[0..1], .rest = trimmed[1..] };
    }

    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t' and
        trimmed[end] != '\n' and trimmed[end] != '\r' and trimmed[end] != '{' and
        trimmed[end] != '}' and trimmed[end] != '(' and trimmed[end] != ')' and
        trimmed[end] != ';' and trimmed[end] != '=')
    {
        end += 1;
    }

    if (end == 0) return null;
    return .{ .token = trimmed[0..end], .rest = trimmed[end..] };
}

/// Parse a .proto file to extract service and message definitions.
/// Uses simple token scanning -- not a full parser.
pub fn parseProtoFile(allocator: Allocator, content: []const u8) !ProtoFile {
    var proto = ProtoFile.init(allocator);
    errdefer proto.deinit();

    var rest = content;

    while (rest.len > 0) {
        const tok_result = nextToken(rest) orelse break;
        const token = tok_result.token;
        rest = tok_result.rest;

        // -- package declaration --
        if (mem.eql(u8, token, "package")) {
            const pkg = nextToken(rest) orelse continue;
            // Strip trailing semicolon if present
            var pkg_name = pkg.token;
            if (mem.endsWith(u8, pkg_name, ";")) {
                pkg_name = pkg_name[0 .. pkg_name.len - 1];
            }
            proto.package = pkg_name;
            rest = pkg.rest;
            // Consume the semicolon token if it was separate
            const maybe_semi = nextToken(rest);
            if (maybe_semi) |s| {
                if (mem.eql(u8, s.token, ";")) rest = s.rest;
            }
            continue;
        }

        // -- service block --
        if (mem.eql(u8, token, "service")) {
            const name_tok = nextToken(rest) orelse continue;
            var svc = ProtoService.init(allocator, name_tok.token);
            rest = name_tok.rest;

            // Expect '{'
            const brace = nextToken(rest) orelse continue;
            if (!mem.eql(u8, brace.token, "{")) continue;
            rest = brace.rest;

            // Parse rpc methods until '}'
            while (rest.len > 0) {
                const inner = nextToken(rest) orelse break;
                if (mem.eql(u8, inner.token, "}")) {
                    rest = inner.rest;
                    break;
                }
                if (mem.eql(u8, inner.token, "rpc")) {
                    rest = inner.rest;
                    // method name
                    const method_tok = nextToken(rest) orelse break;
                    rest = method_tok.rest;

                    // '('
                    const lp = nextToken(rest) orelse break;
                    if (!mem.eql(u8, lp.token, "(")) { rest = lp.rest; continue; }
                    rest = lp.rest;

                    // possibly "stream" keyword then input type
                    var client_streaming = false;
                    const inp1 = nextToken(rest) orelse break;
                    var input_type = inp1.token;
                    rest = inp1.rest;
                    if (mem.eql(u8, input_type, "stream")) {
                        client_streaming = true;
                        const inp2 = nextToken(rest) orelse break;
                        input_type = inp2.token;
                        rest = inp2.rest;
                    }

                    // ')'
                    const rp = nextToken(rest) orelse break;
                    if (mem.eql(u8, rp.token, ")")) rest = rp.rest;

                    // "returns"
                    const ret = nextToken(rest) orelse break;
                    if (!mem.eql(u8, ret.token, "returns")) { rest = ret.rest; continue; }
                    rest = ret.rest;

                    // '('
                    const lp2 = nextToken(rest) orelse break;
                    if (mem.eql(u8, lp2.token, "(")) rest = lp2.rest;

                    // possibly "stream" keyword then output type
                    var server_streaming = false;
                    const out1 = nextToken(rest) orelse break;
                    var output_type = out1.token;
                    rest = out1.rest;
                    if (mem.eql(u8, output_type, "stream")) {
                        server_streaming = true;
                        const out2 = nextToken(rest) orelse break;
                        output_type = out2.token;
                        rest = out2.rest;
                    }

                    // ')'
                    const rp2 = nextToken(rest) orelse break;
                    if (mem.eql(u8, rp2.token, ")")) rest = rp2.rest;

                    // Skip to ';' or '{' ... '}'
                    while (rest.len > 0) {
                        const skip = nextToken(rest) orelse break;
                        rest = skip.rest;
                        if (mem.eql(u8, skip.token, ";")) break;
                        if (mem.eql(u8, skip.token, "{")) {
                            // consume until matching '}'
                            var depth: u32 = 1;
                            while (depth > 0) {
                                const inner2 = nextToken(rest) orelse break;
                                rest = inner2.rest;
                                if (mem.eql(u8, inner2.token, "{")) depth += 1;
                                if (mem.eql(u8, inner2.token, "}")) depth -= 1;
                            }
                            break;
                        }
                    }

                    try svc.methods.append(.{
                        .service = name_tok.token,
                        .method = method_tok.token,
                        .input_type = input_type,
                        .output_type = output_type,
                        .is_client_streaming = client_streaming,
                        .is_server_streaming = server_streaming,
                    });
                } else {
                    rest = inner.rest;
                }
            }

            try proto.services.append(svc);
            continue;
        }

        // -- message block --
        if (mem.eql(u8, token, "message")) {
            const name_tok = nextToken(rest) orelse continue;
            var msg = ProtoMessage.init(allocator, name_tok.token);
            rest = name_tok.rest;

            // Expect '{'
            const brace = nextToken(rest) orelse continue;
            if (!mem.eql(u8, brace.token, "{")) continue;
            rest = brace.rest;

            // Parse fields until '}'
            while (rest.len > 0) {
                const ft = nextToken(rest) orelse break;
                if (mem.eql(u8, ft.token, "}")) {
                    rest = ft.rest;
                    break;
                }

                var field_type = ft.token;
                var repeated = false;
                rest = ft.rest;

                if (mem.eql(u8, field_type, "repeated")) {
                    repeated = true;
                    const ft2 = nextToken(rest) orelse break;
                    field_type = ft2.token;
                    rest = ft2.rest;
                }

                // field name
                const fname = nextToken(rest) orelse break;
                rest = fname.rest;

                // '='
                const eq = nextToken(rest) orelse break;
                if (!mem.eql(u8, eq.token, "=")) { rest = eq.rest; continue; }
                rest = eq.rest;

                // field number
                const fnum_tok = nextToken(rest) orelse break;
                rest = fnum_tok.rest;

                // Strip trailing ';' from number if attached
                var num_str = fnum_tok.token;
                if (mem.endsWith(u8, num_str, ";")) {
                    num_str = num_str[0 .. num_str.len - 1];
                }

                const fnum = std.fmt.parseInt(u32, num_str, 10) catch 0;

                // consume optional ';'
                const maybe_semi = nextToken(rest);
                if (maybe_semi) |s| {
                    if (mem.eql(u8, s.token, ";")) rest = s.rest;
                }

                try msg.fields.append(.{
                    .name = fname.token,
                    .field_type = field_type,
                    .number = fnum,
                    .repeated = repeated,
                });
            }

            try proto.messages.append(msg);
            continue;
        }
    }

    return proto;
}

/// Build gRPC request headers for a method call.
pub fn buildGrpcHeaders(allocator: Allocator, host: []const u8, service: []const u8, method: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.print("POST /{s}/{s} HTTP/2\r\n", .{ service, method });
    try writer.print("Host: {s}\r\n", .{host});
    try writer.writeAll("Content-Type: application/grpc\r\n");
    try writer.writeAll("TE: trailers\r\n");
    try writer.writeAll("Grpc-Encoding: identity\r\n");
    try writer.writeAll("Grpc-Accept-Encoding: identity\r\n");
    try writer.writeAll("\r\n");

    return buf.toOwnedSlice();
}

/// Generate .volt file content for a gRPC service.
/// Returns one entry per RPC method.
pub fn generateVoltFromProto(allocator: Allocator, proto: *const ProtoFile) !std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(allocator);

    // Build a map from message name to message definition for body generation
    for (proto.services.items) |svc| {
        for (svc.methods.items) |m| {
            var buf = std.ArrayList(u8).init(allocator);
            const writer = buf.writer();

            try writer.writeAll("# gRPC call\n");
            try writer.print("POST grpc://{s}/{s}\n", .{ m.service, m.method });
            try writer.writeAll("\n");
            try writer.writeAll("Content-Type: application/grpc\n");
            try writer.writeAll("TE: trailers\n");
            try writer.writeAll("\n");

            // Build a JSON body template from the input message type
            try writer.writeAll("{\n");
            var found_msg = false;
            for (proto.messages.items) |msg| {
                if (mem.eql(u8, msg.name, m.input_type)) {
                    found_msg = true;
                    for (msg.fields.items, 0..) |field, idx| {
                        const default_val = protoTypeDefault(field.field_type, field.repeated);
                        try writer.print("  \"{s}\": {s}", .{ field.name, default_val });
                        if (idx + 1 < msg.fields.items.len) {
                            try writer.writeAll(",");
                        }
                        try writer.writeAll("\n");
                    }
                }
            }
            if (!found_msg) {
                try writer.writeAll("  \n");
            }
            try writer.writeAll("}\n");

            const content = try buf.toOwnedSlice();
            try results.append(content);
        }
    }

    return results;
}

/// Return a JSON placeholder value for a proto field type.
fn protoTypeDefault(field_type: []const u8, repeated: bool) []const u8 {
    if (repeated) return "[]";
    if (mem.eql(u8, field_type, "string")) return "\"\"";
    if (mem.eql(u8, field_type, "int32") or mem.eql(u8, field_type, "int64") or
        mem.eql(u8, field_type, "uint32") or mem.eql(u8, field_type, "uint64") or
        mem.eql(u8, field_type, "sint32") or mem.eql(u8, field_type, "sint64") or
        mem.eql(u8, field_type, "fixed32") or mem.eql(u8, field_type, "fixed64") or
        mem.eql(u8, field_type, "sfixed32") or mem.eql(u8, field_type, "sfixed64"))
        return "0";
    if (mem.eql(u8, field_type, "float") or mem.eql(u8, field_type, "double")) return "0.0";
    if (mem.eql(u8, field_type, "bool")) return "false";
    if (mem.eql(u8, field_type, "bytes")) return "\"\"";
    return "{}";
}

/// Format service listing for display.
pub fn formatServices(allocator: Allocator, proto: *const ProtoFile) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    if (proto.package.len > 0) {
        try writer.print("Package: {s}\n\n", .{proto.package});
    }

    for (proto.services.items) |svc| {
        try writer.print("Service: {s}\n", .{svc.name});
        for (svc.methods.items) |m| {
            const cs: []const u8 = if (m.is_client_streaming) "stream " else "";
            const ss: []const u8 = if (m.is_server_streaming) "stream " else "";
            try writer.print("  rpc {s}({s}{s}) returns ({s}{s})\n", .{
                m.method,
                cs,
                m.input_type,
                ss,
                m.output_type,
            });
        }
        try writer.writeAll("\n");
    }

    if (proto.messages.items.len > 0) {
        try writer.writeAll("Messages:\n");
        for (proto.messages.items) |msg| {
            try writer.print("  {s}\n", .{msg.name});
            for (msg.fields.items) |field| {
                const rep: []const u8 = if (field.repeated) "repeated " else "";
                try writer.print("    {s}{s} {s} = {d}\n", .{ rep, field.field_type, field.name, field.number });
            }
        }
    }

    return buf.toOwnedSlice();
}

// -- Tests ----------------------------------------------------------------

test "encode and decode message roundtrip" {
    const allocator = std.testing.allocator;
    const original = "Hello, gRPC!";

    const encoded = try encodeMessage(allocator, original);
    defer allocator.free(encoded);

    // Check total length: 5-byte header + message length
    try std.testing.expectEqual(@as(usize, 5 + original.len), encoded.len);

    // First byte should be 0x00 (not compressed)
    try std.testing.expectEqual(@as(u8, 0x00), encoded[0]);

    // Decode and verify roundtrip
    const decoded = try decodeMessage(encoded);
    try std.testing.expect(!decoded.compressed);
    try std.testing.expectEqualStrings(original, decoded.payload);
}

test "parse simple proto file" {
    const allocator = std.testing.allocator;
    const proto_content =
        \\syntax = "proto3";
        \\package greeter;
        \\
        \\service Greeter {
        \\  rpc SayHello (HelloRequest) returns (HelloReply) {}
        \\  rpc StreamGreetings (HelloRequest) returns (stream HelloReply) {}
        \\}
        \\
        \\message HelloRequest {
        \\  string name = 1;
        \\  int32 age = 2;
        \\}
        \\
        \\message HelloReply {
        \\  string message = 1;
        \\}
    ;

    var proto = try parseProtoFile(allocator, proto_content);
    defer proto.deinit();

    try std.testing.expectEqualStrings("greeter", proto.package);
    try std.testing.expectEqual(@as(usize, 1), proto.services.items.len);
    try std.testing.expectEqualStrings("Greeter", proto.services.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), proto.services.items[0].methods.items.len);

    const say_hello = proto.services.items[0].methods.items[0];
    try std.testing.expectEqualStrings("SayHello", say_hello.method);
    try std.testing.expectEqualStrings("HelloRequest", say_hello.input_type);
    try std.testing.expectEqualStrings("HelloReply", say_hello.output_type);
    try std.testing.expect(!say_hello.is_client_streaming);
    try std.testing.expect(!say_hello.is_server_streaming);

    const stream_method = proto.services.items[0].methods.items[1];
    try std.testing.expect(stream_method.is_server_streaming);

    try std.testing.expectEqual(@as(usize, 2), proto.messages.items.len);
    try std.testing.expectEqualStrings("HelloRequest", proto.messages.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), proto.messages.items[0].fields.items.len);
    try std.testing.expectEqualStrings("name", proto.messages.items[0].fields.items[0].name);
    try std.testing.expectEqualStrings("string", proto.messages.items[0].fields.items[0].field_type);
}

test "build grpc headers" {
    const allocator = std.testing.allocator;

    const headers = try buildGrpcHeaders(allocator, "localhost:50051", "Greeter", "SayHello");
    defer allocator.free(headers);

    try std.testing.expect(mem.indexOf(u8, headers, "POST /Greeter/SayHello HTTP/2") != null);
    try std.testing.expect(mem.indexOf(u8, headers, "Host: localhost:50051") != null);
    try std.testing.expect(mem.indexOf(u8, headers, "Content-Type: application/grpc") != null);
    try std.testing.expect(mem.indexOf(u8, headers, "TE: trailers") != null);
}

test "format services" {
    const allocator = std.testing.allocator;

    const proto_content =
        \\package myapi;
        \\
        \\service UserService {
        \\  rpc GetUser (GetUserRequest) returns (User) {}
        \\  rpc ListUsers (ListUsersRequest) returns (stream User) {}
        \\}
        \\
        \\message GetUserRequest {
        \\  string id = 1;
        \\}
        \\
        \\message User {
        \\  string id = 1;
        \\  string name = 2;
        \\}
    ;

    var proto = try parseProtoFile(allocator, proto_content);
    defer proto.deinit();

    const formatted = try formatServices(allocator, &proto);
    defer allocator.free(formatted);

    try std.testing.expect(mem.indexOf(u8, formatted, "Package: myapi") != null);
    try std.testing.expect(mem.indexOf(u8, formatted, "Service: UserService") != null);
    try std.testing.expect(mem.indexOf(u8, formatted, "rpc GetUser") != null);
    try std.testing.expect(mem.indexOf(u8, formatted, "rpc ListUsers") != null);
    try std.testing.expect(mem.indexOf(u8, formatted, "stream User") != null);
    try std.testing.expect(mem.indexOf(u8, formatted, "Messages:") != null);
}
