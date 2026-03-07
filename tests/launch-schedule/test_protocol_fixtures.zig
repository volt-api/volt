const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const volt_core = @import("volt-core");
const VoltFile = volt_core.VoltFile;

// -- Protocol Fixture Parser Validation Tests ---------------------------------
//
// Reads each protocol-specific .volt fixture via @embedFile and validates
// that VoltFile.parse correctly extracts method, URL, headers, body, auth,
// tests, and variables. No network calls -- pure parser validation.

test "parse graphql query-users fixture" {
    const content = @embedFile("fixtures/graphql/query-users.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqualStrings("GraphQL Query Users", req.name.?);
    try testing.expectEqual(VoltFile.Method.POST, req.method);
    try testing.expectEqualStrings("http://127.0.0.1:9090/graphql", req.url);
    try testing.expectEqual(@as(usize, 2), req.headers.items.len);
    try testing.expectEqualStrings("Content-Type", req.headers.items[0].name);
    try testing.expectEqualStrings("application/json", req.headers.items[0].value);
    try testing.expect(req.body != null);
    try testing.expect(mem.indexOf(u8, req.body.?, "users") != null);
    try testing.expectEqual(VoltFile.BodyType.json, req.body_type);
}

test "parse graphql query-with-variables fixture" {
    const content = @embedFile("fixtures/graphql/query-with-variables.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqualStrings("GraphQL Query With Variables", req.name.?);
    try testing.expectEqual(VoltFile.Method.POST, req.method);
    try testing.expectEqualStrings("http://127.0.0.1:9090/graphql", req.url);
    try testing.expect(req.body != null);
    try testing.expect(mem.indexOf(u8, req.body.?, "variables") != null);
    try testing.expect(mem.indexOf(u8, req.body.?, "GetUser") != null);
    try testing.expectEqual(@as(usize, 2), req.tests.items.len);
    try testing.expectEqualStrings("$.data.user.id", req.tests.items[1].field);
}

test "parse websocket echo fixture" {
    const content = @embedFile("fixtures/websocket/echo.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqualStrings("WebSocket Echo", req.name.?);
    try testing.expectEqual(VoltFile.Method.GET, req.method);
    try testing.expectEqualStrings("ws://127.0.0.1:9090/ws/echo", req.url);
    try testing.expect(mem.startsWith(u8, req.url, "ws://"));
    try testing.expectEqual(@as(usize, 3), req.headers.items.len);
    try testing.expectEqualStrings("Upgrade", req.headers.items[0].name);
    try testing.expectEqualStrings("websocket", req.headers.items[0].value);
}

test "parse sse events fixture" {
    const content = @embedFile("fixtures/sse/events.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqualStrings("SSE Event Stream", req.name.?);
    try testing.expectEqual(VoltFile.Method.GET, req.method);
    try testing.expectEqualStrings("http://127.0.0.1:9090/sse/events", req.url);
    try testing.expectEqual(@as(usize, 2), req.headers.items.len);
    try testing.expectEqualStrings("Accept", req.headers.items[0].name);
    try testing.expectEqualStrings("text/event-stream", req.headers.items[0].value);
    try testing.expectEqual(@as(usize, 1), req.tests.items.len);
}

test "parse mqtt connect fixture" {
    const content = @embedFile("fixtures/mqtt/connect.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqualStrings("MQTT Connect", req.name.?);
    try testing.expectEqual(VoltFile.Method.GET, req.method);
    try testing.expectEqualStrings("mqtt://broker.test.local:1883/telemetry/sensors", req.url);
    try testing.expect(mem.startsWith(u8, req.url, "mqtt://"));
    try testing.expectEqual(@as(usize, 2), req.headers.items.len);
    // Verify variables parsed
    const topic = req.variables.get("topic");
    try testing.expect(topic != null);
    try testing.expectEqualStrings("telemetry/sensors", topic.?);
    const qos = req.variables.get("qos");
    try testing.expect(qos != null);
    try testing.expectEqualStrings("1", qos.?);
}

test "parse socketio handshake fixture" {
    const content = @embedFile("fixtures/socketio/handshake.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqualStrings("Socket.IO Handshake", req.name.?);
    try testing.expectEqual(VoltFile.Method.GET, req.method);
    try testing.expect(mem.indexOf(u8, req.url, "socket.io") != null);
    try testing.expect(mem.indexOf(u8, req.url, "EIO=4") != null);
    try testing.expect(mem.indexOf(u8, req.url, "transport=polling") != null);
    try testing.expectEqual(@as(usize, 2), req.headers.items.len);
    try testing.expectEqual(@as(usize, 1), req.tests.items.len);
}

test "parse oauth token-exchange fixture" {
    const content = @embedFile("fixtures/oauth/token-exchange.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqualStrings("OAuth Token Exchange", req.name.?);
    try testing.expectEqual(VoltFile.Method.POST, req.method);
    try testing.expectEqualStrings("http://127.0.0.1:9090/oauth/token", req.url);
    // Auth section
    try testing.expectEqual(VoltFile.AuthType.oauth_cc, req.auth.type);
    try testing.expectEqualStrings("volt-test-app", req.auth.client_id.?);
    try testing.expectEqualStrings("test-secret-key-12345", req.auth.client_secret.?);
    try testing.expectEqualStrings("http://127.0.0.1:9090/oauth/token", req.auth.token_url.?);
    try testing.expectEqualStrings("read write", req.auth.scope.?);
    // Body
    try testing.expectEqual(VoltFile.BodyType.form, req.body_type);
    try testing.expect(req.body != null);
    try testing.expectEqualStrings("grant_type=client_credentials", req.body.?);
    // Tests
    try testing.expectEqual(@as(usize, 2), req.tests.items.len);
    try testing.expectEqualStrings("$.access_token", req.tests.items[1].field);
    try testing.expectEqualStrings("exists", req.tests.items[1].operator);
}

test "parse proxy capture fixture" {
    const content = @embedFile("fixtures/proxy/capture.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqualStrings("Proxy Capture", req.name.?);
    try testing.expectEqual(VoltFile.Method.GET, req.method);
    try testing.expectEqualStrings("http://127.0.0.1:9090/proxy-target", req.url);
    try testing.expectEqual(@as(usize, 3), req.headers.items.len);
    try testing.expectEqualStrings("X-Proxy-Capture", req.headers.items[0].name);
    try testing.expectEqualStrings("true", req.headers.items[0].value);
    // Variables
    const proxy_port = req.variables.get("proxy_port");
    try testing.expect(proxy_port != null);
    try testing.expectEqualStrings("8888", proxy_port.?);
    // Tests
    try testing.expectEqual(@as(usize, 1), req.tests.items.len);
}
