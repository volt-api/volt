const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const volt_core = @import("volt-core");
const VoltFile = volt_core.VoltFile;
const Exporter = volt_core.Exporter;

// ── Export Code Generation Tests ────────────────────────────────────────
//
// Validates that the Exporter module generates correct curl, Python,
// JavaScript, and Go code from VoltRequest structures.
// Tests cover: methods, headers, auth types, body types, and special chars.

// ── curl Export Tests ───────────────────────────────────────────────────

test "export curl GET request" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/users";
    try req.addHeader("Accept", "application/json");

    const result = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(result);

    // GET should not have -X flag (curl default)
    try testing.expect(mem.indexOf(u8, result, "-X GET") == null);
    try testing.expect(mem.indexOf(u8, result, "curl") != null);
    try testing.expect(mem.indexOf(u8, result, "'https://api.example.com/users'") != null);
    try testing.expect(mem.indexOf(u8, result, "Accept: application/json") != null);
}

test "export curl POST with JSON body" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/users";
    req.body = "{\"name\": \"test\", \"email\": \"test@example.com\"}";
    req.body_type = .json;
    try req.addHeader("Content-Type", "application/json");

    const result = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "-X POST") != null);
    try testing.expect(mem.indexOf(u8, result, "-d") != null);
    try testing.expect(mem.indexOf(u8, result, "\"name\"") != null);
    try testing.expect(mem.indexOf(u8, result, "Content-Type: application/json") != null);
}

test "export curl PUT request" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .PUT;
    req.url = "https://api.example.com/users/42";
    req.body = "{\"name\": \"updated\"}";

    const result = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "-X PUT") != null);
    try testing.expect(mem.indexOf(u8, result, "/users/42") != null);
}

test "export curl DELETE request" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .DELETE;
    req.url = "https://api.example.com/users/42";

    const result = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "-X DELETE") != null);
    try testing.expect(mem.indexOf(u8, result, "-d") == null); // No body
}

test "export curl with bearer auth" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/me";
    req.auth = .{ .type = .bearer, .token = "my-secret-token" };

    const result = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "Authorization: Bearer my-secret-token") != null);
}

test "export curl with basic auth" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/admin";
    req.auth = .{ .type = .basic, .username = "admin", .password = "secret123" };

    const result = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "-u 'admin:secret123'") != null);
}

test "export curl with api_key auth in header" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/data";
    req.auth = .{
        .type = .api_key,
        .key_name = "X-API-Key",
        .key_value = "abc123",
        .key_location = "header",
    };

    const result = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "X-API-Key: abc123") != null);
}

test "export curl with digest auth" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/secure";
    req.auth = .{ .type = .digest, .username = "user", .password = "pass" };

    const result = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "--digest") != null);
    try testing.expect(mem.indexOf(u8, result, "-u 'user:pass'") != null);
}

test "export curl with body containing single quotes" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/data";
    req.body = "{\"name\": \"O'Brien\"}";

    const result = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(result);

    // Single quotes in body should be escaped
    try testing.expect(mem.indexOf(u8, result, "-d") != null);
    try testing.expect(mem.indexOf(u8, result, "O") != null);
}

// ── Python Export Tests ─────────────────────────────────────────────────

test "export python GET request" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/users";
    try req.addHeader("Accept", "application/json");

    const result = try Exporter.exportPython(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "import requests") != null);
    try testing.expect(mem.indexOf(u8, result, "requests.get(") != null);
    try testing.expect(mem.indexOf(u8, result, "https://api.example.com/users") != null);
    try testing.expect(mem.indexOf(u8, result, "headers=headers") != null);
    try testing.expect(mem.indexOf(u8, result, "\"Accept\"") != null);
    try testing.expect(mem.indexOf(u8, result, "print(") != null);
}

test "export python POST with JSON body" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/users";
    req.body = "{\"name\": \"test\"}";
    req.body_type = .json;

    const result = try Exporter.exportPython(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "requests.post(") != null);
    try testing.expect(mem.indexOf(u8, result, "json=") != null);
}

test "export python POST with form body" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/login";
    req.body = "username=admin&password=secret";
    req.body_type = .form;

    const result = try Exporter.exportPython(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "requests.post(") != null);
    try testing.expect(mem.indexOf(u8, result, "data=") != null);
}

test "export python without headers omits headers dict" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/health";

    const result = try Exporter.exportPython(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "headers = {") == null);
    try testing.expect(mem.indexOf(u8, result, "headers=headers") == null);
}

// ── JavaScript Export Tests ─────────────────────────────────────────────

test "export javascript GET request" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/users";
    try req.addHeader("Accept", "application/json");

    const result = try Exporter.exportJavaScript(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "await fetch(") != null);
    try testing.expect(mem.indexOf(u8, result, "method: \"GET\"") != null);
    try testing.expect(mem.indexOf(u8, result, "https://api.example.com/users") != null);
    try testing.expect(mem.indexOf(u8, result, "\"Accept\"") != null);
    try testing.expect(mem.indexOf(u8, result, "console.log") != null);
}

test "export javascript POST with body" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/users";
    req.body = "{\"name\": \"test\"}";
    req.body_type = .json;

    const result = try Exporter.exportJavaScript(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "method: \"POST\"") != null);
    try testing.expect(mem.indexOf(u8, result, "JSON.stringify(") != null);
    try testing.expect(mem.indexOf(u8, result, "response.json()") != null);
}

// ── Go Export Tests ─────────────────────────────────────────────────────

test "export go GET request" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/users";
    try req.addHeader("Accept", "application/json");

    const result = try Exporter.exportGo(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "package main") != null);
    try testing.expect(mem.indexOf(u8, result, "\"net/http\"") != null);
    try testing.expect(mem.indexOf(u8, result, "http.NewRequest(\"GET\"") != null);
    try testing.expect(mem.indexOf(u8, result, "https://api.example.com/users") != null);
    try testing.expect(mem.indexOf(u8, result, "req.Header.Set(\"Accept\"") != null);
    try testing.expect(mem.indexOf(u8, result, "resp.StatusCode") != null);
    // No body => no "strings" import
    try testing.expect(mem.indexOf(u8, result, "\"strings\"") == null);
}

test "export go POST with body" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/users";
    req.body = "{\"name\": \"test\"}";
    req.body_type = .json;

    const result = try Exporter.exportGo(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "\"strings\"") != null);
    try testing.expect(mem.indexOf(u8, result, "strings.NewReader(") != null);
    try testing.expect(mem.indexOf(u8, result, "http.NewRequest(\"POST\"") != null);
}

test "export go request without body uses nil" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .DELETE;
    req.url = "https://api.example.com/users/42";

    const result = try Exporter.exportGo(&req, testing.allocator);
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "nil)") != null);
}

// ── OpenAPI Export Test ─────────────────────────────────────────────────

test "export OpenAPI from request collection" {
    var requests: [3]VoltFile.VoltRequest = undefined;

    // GET /users
    requests[0] = VoltFile.VoltRequest.init(testing.allocator);
    requests[0].method = .GET;
    requests[0].url = "https://api.example.com/users";
    requests[0].name = "List Users";

    // POST /users (with JSON body)
    requests[1] = VoltFile.VoltRequest.init(testing.allocator);
    requests[1].method = .POST;
    requests[1].url = "https://api.example.com/users";
    requests[1].name = "Create User";
    requests[1].body = "{\"name\": \"test\"}";
    requests[1].body_type = .json;

    // GET /users/{id} (with bearer auth)
    requests[2] = VoltFile.VoltRequest.init(testing.allocator);
    requests[2].method = .GET;
    requests[2].url = "https://api.example.com/users/42";
    requests[2].name = "Get User";
    requests[2].auth = .{ .type = .bearer, .token = "tok123" };

    defer for (&requests) |*r| r.deinit();

    const result = try Exporter.exportOpenAPI(testing.allocator, &requests, "Test API");
    defer testing.allocator.free(result);

    // Should have YAML structure
    try testing.expect(mem.indexOf(u8, result, "openapi: '3.0.3'") != null);
    try testing.expect(mem.indexOf(u8, result, "title: Test API") != null);
    try testing.expect(mem.indexOf(u8, result, "paths:") != null);
    try testing.expect(mem.indexOf(u8, result, "/users:") != null);
    try testing.expect(mem.indexOf(u8, result, "get:") != null);
    try testing.expect(mem.indexOf(u8, result, "post:") != null);
    try testing.expect(mem.indexOf(u8, result, "summary: List Users") != null);
    try testing.expect(mem.indexOf(u8, result, "summary: Create User") != null);
    try testing.expect(mem.indexOf(u8, result, "requestBody:") != null);
    try testing.expect(mem.indexOf(u8, result, "application/json") != null);
    try testing.expect(mem.indexOf(u8, result, "bearerAuth") != null);
    try testing.expect(mem.indexOf(u8, result, "components:") != null);
    try testing.expect(mem.indexOf(u8, result, "securitySchemes:") != null);
}

// ── Multi-Format Roundtrip ──────────────────────────────────────────────

test "same request produces valid output in all export formats" {
    var req = VoltFile.VoltRequest.init(testing.allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/data";
    req.name = "Submit Data";
    req.body = "{\"key\": \"value\"}";
    req.body_type = .json;
    try req.addHeader("Content-Type", "application/json");
    try req.addHeader("Authorization", "Bearer tok123");

    // All exports should produce non-empty, valid output
    const curl = try Exporter.exportCurl(&req, testing.allocator);
    defer testing.allocator.free(curl);
    try testing.expect(curl.len > 0);
    try testing.expect(mem.indexOf(u8, curl, "curl") != null);

    const python = try Exporter.exportPython(&req, testing.allocator);
    defer testing.allocator.free(python);
    try testing.expect(python.len > 0);
    try testing.expect(mem.indexOf(u8, python, "import requests") != null);

    const javascript = try Exporter.exportJavaScript(&req, testing.allocator);
    defer testing.allocator.free(javascript);
    try testing.expect(javascript.len > 0);
    try testing.expect(mem.indexOf(u8, javascript, "fetch") != null);

    const go_code = try Exporter.exportGo(&req, testing.allocator);
    defer testing.allocator.free(go_code);
    try testing.expect(go_code.len > 0);
    try testing.expect(mem.indexOf(u8, go_code, "package main") != null);
}
