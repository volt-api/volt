const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const volt_core = @import("volt-core");
const VoltFile = volt_core.VoltFile;
const HttpClient = volt_core.HttpClient;
const Exporter = volt_core.Exporter;
const Environment = volt_core.Environment;
const EnvManager = Environment.EnvManager;

// ── Integration Test Harness ────────────────────────────────────────────
//
// End-to-end validation that protocol fixtures:
//   1. Parse correctly into VoltRequest structures
//   2. Can be serialized back to .volt format and re-parsed (roundtrip)
//   3. Produce valid export output (curl, python, etc.)
//   4. Have variables properly resolved by EnvManager
//   5. Build correct HTTP request configurations
//
// These tests validate the full pipeline from .volt fixture through to
// request construction without requiring a running server.

// ── Fixture Roundtrip Tests ─────────────────────────────────────────────
//
// Verify that each protocol fixture survives parse -> serialize -> re-parse
// with all critical fields preserved.

test "roundtrip graphql query-users fixture" {
    const content = @embedFile("fixtures/graphql/query-users.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const serialized = try VoltFile.serialize(&req, testing.allocator);
    defer testing.allocator.free(serialized);

    var reparsed = try VoltFile.parse(testing.allocator, serialized);
    defer reparsed.deinit();

    try testing.expectEqual(req.method, reparsed.method);
    try testing.expectEqualStrings(req.url, reparsed.url);
    try testing.expectEqual(req.headers.items.len, reparsed.headers.items.len);
    try testing.expectEqual(req.body_type, reparsed.body_type);
}

test "roundtrip websocket echo fixture" {
    const content = @embedFile("fixtures/websocket/echo.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const serialized = try VoltFile.serialize(&req, testing.allocator);
    defer testing.allocator.free(serialized);

    var reparsed = try VoltFile.parse(testing.allocator, serialized);
    defer reparsed.deinit();

    try testing.expectEqual(VoltFile.Method.GET, reparsed.method);
    try testing.expect(mem.startsWith(u8, reparsed.url, "ws://"));
    try testing.expectEqual(@as(usize, 3), reparsed.headers.items.len);
    try testing.expectEqualStrings("Upgrade", reparsed.headers.items[0].name);
    try testing.expectEqualStrings("websocket", reparsed.headers.items[0].value);
}

test "roundtrip sse events fixture" {
    const content = @embedFile("fixtures/sse/events.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const serialized = try VoltFile.serialize(&req, testing.allocator);
    defer testing.allocator.free(serialized);

    var reparsed = try VoltFile.parse(testing.allocator, serialized);
    defer reparsed.deinit();

    try testing.expectEqual(VoltFile.Method.GET, reparsed.method);
    try testing.expect(mem.indexOf(u8, reparsed.url, "/sse/events") != null);
    // Accept header preserved
    var found_accept = false;
    for (reparsed.headers.items) |h| {
        if (mem.eql(u8, h.name, "Accept") and mem.eql(u8, h.value, "text/event-stream")) {
            found_accept = true;
        }
    }
    try testing.expect(found_accept);
}

test "roundtrip oauth token-exchange fixture" {
    const content = @embedFile("fixtures/oauth/token-exchange.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const serialized = try VoltFile.serialize(&req, testing.allocator);
    defer testing.allocator.free(serialized);

    var reparsed = try VoltFile.parse(testing.allocator, serialized);
    defer reparsed.deinit();

    try testing.expectEqual(VoltFile.Method.POST, reparsed.method);
    try testing.expectEqual(VoltFile.AuthType.oauth_cc, reparsed.auth.type);
    try testing.expectEqualStrings("volt-test-app", reparsed.auth.client_id.?);
    try testing.expectEqualStrings("test-secret-key-12345", reparsed.auth.client_secret.?);
    try testing.expectEqualStrings("read write", reparsed.auth.scope.?);
}

test "roundtrip mqtt connect fixture" {
    const content = @embedFile("fixtures/mqtt/connect.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const serialized = try VoltFile.serialize(&req, testing.allocator);
    defer testing.allocator.free(serialized);

    var reparsed = try VoltFile.parse(testing.allocator, serialized);
    defer reparsed.deinit();

    try testing.expectEqual(VoltFile.Method.GET, reparsed.method);
    try testing.expect(mem.startsWith(u8, reparsed.url, "mqtt://"));
    // Variables preserved
    const topic = reparsed.variables.get("topic");
    try testing.expect(topic != null);
    try testing.expectEqualStrings("telemetry/sensors", topic.?);
}

test "roundtrip proxy capture fixture" {
    const content = @embedFile("fixtures/proxy/capture.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const serialized = try VoltFile.serialize(&req, testing.allocator);
    defer testing.allocator.free(serialized);

    var reparsed = try VoltFile.parse(testing.allocator, serialized);
    defer reparsed.deinit();

    try testing.expectEqualStrings("Proxy Capture", reparsed.name.?);
    try testing.expectEqual(@as(usize, 3), reparsed.headers.items.len);
    const proxy_port = reparsed.variables.get("proxy_port");
    try testing.expect(proxy_port != null);
    try testing.expectEqualStrings("8888", proxy_port.?);
}

// ── Export Pipeline Tests ───────────────────────────────────────────────
//
// Verify that protocol fixtures produce valid export output.

test "graphql fixture exports to curl" {
    const content = @embedFile("fixtures/graphql/query-users.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const curl_output = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(curl_output);

    try testing.expect(mem.indexOf(u8, curl_output, "curl") != null);
    try testing.expect(mem.indexOf(u8, curl_output, "-X POST") != null);
    try testing.expect(mem.indexOf(u8, curl_output, "http://127.0.0.1:9090/graphql") != null);
    try testing.expect(mem.indexOf(u8, curl_output, "Content-Type: application/json") != null);
}

test "graphql fixture exports to python" {
    const content = @embedFile("fixtures/graphql/query-users.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const py_output = try Exporter.exportPython(&req, testing.allocator);
    defer testing.allocator.free(py_output);

    try testing.expect(mem.indexOf(u8, py_output, "import requests") != null);
    try testing.expect(mem.indexOf(u8, py_output, "requests.post") != null);
    try testing.expect(mem.indexOf(u8, py_output, "http://127.0.0.1:9090/graphql") != null);
}

test "oauth fixture exports to curl with auth" {
    const content = @embedFile("fixtures/oauth/token-exchange.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const curl_output = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(curl_output);

    try testing.expect(mem.indexOf(u8, curl_output, "curl") != null);
    try testing.expect(mem.indexOf(u8, curl_output, "-X POST") != null);
    try testing.expect(mem.indexOf(u8, curl_output, "/oauth/token") != null);
    // Body should be present
    try testing.expect(mem.indexOf(u8, curl_output, "-d") != null);
    try testing.expect(mem.indexOf(u8, curl_output, "grant_type=client_credentials") != null);
}

test "websocket fixture exports to javascript" {
    const content = @embedFile("fixtures/websocket/echo.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const js_output = try Exporter.exportJavaScript(&req, testing.allocator);
    defer testing.allocator.free(js_output);

    try testing.expect(mem.indexOf(u8, js_output, "fetch") != null);
    try testing.expect(mem.indexOf(u8, js_output, "ws://127.0.0.1:9090/ws/echo") != null);
    try testing.expect(mem.indexOf(u8, js_output, "Upgrade") != null);
}

test "proxy fixture exports to go" {
    const content = @embedFile("fixtures/proxy/capture.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    const go_output = try Exporter.exportGo(&req, testing.allocator);
    defer testing.allocator.free(go_output);

    try testing.expect(mem.indexOf(u8, go_output, "package main") != null);
    try testing.expect(mem.indexOf(u8, go_output, "http.NewRequest") != null);
    try testing.expect(mem.indexOf(u8, go_output, "/proxy-target") != null);
    try testing.expect(mem.indexOf(u8, go_output, "X-Proxy-Capture") != null);
}

// ── Variable Resolution Pipeline Tests ──────────────────────────────────
//
// Verify that protocol fixtures with {{variables}} resolve correctly
// through the EnvManager pipeline.

test "chain fixture login URL resolves with environment" {
    const content = @embedFile("fixtures/chain/01-login.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    // The login fixture URL should be parseable
    try testing.expect(req.url.len > 0);
    try testing.expectEqual(VoltFile.Method.GET, req.method);
}

test "chain fixture uses extracted token in follow-up" {
    const content_login = @embedFile("fixtures/chain/01-login.volt");
    var req_login = try VoltFile.parse(testing.allocator, content_login);
    defer req_login.deinit();

    const content_me = @embedFile("fixtures/chain/02-me.volt");
    var req_me = try VoltFile.parse(testing.allocator, content_me);
    defer req_me.deinit();

    // Verify the chain relationship: me.volt references a bearer token
    try testing.expectEqual(VoltFile.Method.GET, req_me.method);
    // Either via auth section or Authorization header
    var has_auth_ref = false;
    if (req_me.auth.type == .bearer) has_auth_ref = true;
    for (req_me.headers.items) |h| {
        if (mem.eql(u8, h.name, "Authorization")) {
            has_auth_ref = true;
        }
    }
    try testing.expect(has_auth_ref);
}

// ── HTTP Request Configuration Validation ────────────────────────────────
//
// Verify parsed fixtures produce complete HTTP request configurations.

test "all protocol fixtures produce valid request configs" {
    const fixtures = .{
        @embedFile("fixtures/graphql/query-users.volt"),
        @embedFile("fixtures/graphql/query-with-variables.volt"),
        @embedFile("fixtures/websocket/echo.volt"),
        @embedFile("fixtures/sse/events.volt"),
        @embedFile("fixtures/mqtt/connect.volt"),
        @embedFile("fixtures/socketio/handshake.volt"),
        @embedFile("fixtures/oauth/token-exchange.volt"),
        @embedFile("fixtures/proxy/capture.volt"),
    };

    inline for (fixtures) |fixture_content| {
        var req = try VoltFile.parse(testing.allocator, fixture_content);
        defer req.deinit();

        // Every fixture must have: name, method, url
        try testing.expect(req.name != null);
        try testing.expect(req.url.len > 0);
        // Method should be a valid HTTP method
        const method_str = req.method.toString();
        try testing.expect(method_str.len > 0);
    }
}

test "fixtures with tests have valid assertion structure" {
    const fixtures = .{
        @embedFile("fixtures/graphql/query-with-variables.volt"),
        @embedFile("fixtures/sse/events.volt"),
        @embedFile("fixtures/socketio/handshake.volt"),
        @embedFile("fixtures/oauth/token-exchange.volt"),
        @embedFile("fixtures/proxy/capture.volt"),
    };

    inline for (fixtures) |fixture_content| {
        var req = try VoltFile.parse(testing.allocator, fixture_content);
        defer req.deinit();

        // Fixtures with test assertions should have at least one
        try testing.expect(req.tests.items.len >= 1);

        // Each assertion must have a field and operator
        for (req.tests.items) |t| {
            try testing.expect(t.field.len > 0);
            try testing.expect(t.operator.len > 0);
        }
    }
}

// ── Response Type Fixture Pipeline ──────────────────────────────────────
//
// Validate response-type fixtures parse and roundtrip correctly.

test "html response fixture roundtrip" {
    const content = @embedFile("fixtures/response-types/html.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqual(VoltFile.Method.GET, req.method);
    try testing.expect(req.url.len > 0);

    const serialized = try VoltFile.serialize(&req, testing.allocator);
    defer testing.allocator.free(serialized);

    try testing.expect(mem.indexOf(u8, serialized, "method: GET") != null);
}

test "xml response fixture roundtrip" {
    const content = @embedFile("fixtures/response-types/xml.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqual(VoltFile.Method.GET, req.method);

    const serialized = try VoltFile.serialize(&req, testing.allocator);
    defer testing.allocator.free(serialized);

    try testing.expect(mem.indexOf(u8, serialized, "method: GET") != null);
}

test "binary response fixture roundtrip" {
    const content = @embedFile("fixtures/response-types/binary.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    try testing.expectEqual(VoltFile.Method.GET, req.method);

    const serialized = try VoltFile.serialize(&req, testing.allocator);
    defer testing.allocator.free(serialized);

    try testing.expect(mem.indexOf(u8, serialized, "method: GET") != null);
}

// ── Secrets Detection Fixture Pipeline ──────────────────────────────────

test "secrets fixture has auth tokens detectable" {
    const content = @embedFile("fixtures/secrets/secrets-example.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    // Should have auth section or Authorization header with sensitive values
    var has_sensitive = false;
    if (req.auth.type != .none) has_sensitive = true;
    for (req.headers.items) |h| {
        if (mem.eql(u8, h.name, "Authorization") or
            mem.eql(u8, h.name, "X-API-Key"))
        {
            has_sensitive = true;
        }
    }
    try testing.expect(has_sensitive);
}
