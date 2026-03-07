const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const volt_core = @import("volt-core");
const OpenAPIImport = volt_core.OpenAPIImport;
const VoltFile = volt_core.VoltFile;

// ── OpenAPI Import Validation Tests ─────────────────────────────────────
//
// Validates that the OpenAPI importer correctly parses the minimal fixture
// at fixtures/openapi/openapi-min.json and can handle larger specs with
// multiple paths, methods, request bodies, and parameters.

test "import minimal OpenAPI fixture" {
    const json_content = @embedFile("fixtures/openapi/openapi-min.json");

    var endpoints = try OpenAPIImport.parseOpenAPI(testing.allocator, json_content);
    defer {
        for (endpoints.items) |*ep| {
            testing.allocator.free(ep.path);
            if (ep.summary) |s| testing.allocator.free(s);
            testing.allocator.free(ep.url);
            for (ep.headers.items) |h| {
                testing.allocator.free(h.name);
                testing.allocator.free(h.value);
            }
            if (ep.body_example) |b| testing.allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    // The minimal fixture has one endpoint: GET /login
    try testing.expectEqual(@as(usize, 1), endpoints.items.len);

    const ep = &endpoints.items[0];
    try testing.expectEqualStrings("GET", ep.method);
    try testing.expectEqualStrings("/login", ep.path);
    try testing.expectEqualStrings("http://127.0.0.1:8787/login", ep.url);
    try testing.expectEqualStrings("Login", ep.summary.?);
    try testing.expectEqual(@as(u16, 200), ep.expected_status.?);
}

test "minimal fixture generates valid .volt content" {
    const json_content = @embedFile("fixtures/openapi/openapi-min.json");

    var endpoints = try OpenAPIImport.parseOpenAPI(testing.allocator, json_content);
    defer {
        for (endpoints.items) |*ep| {
            testing.allocator.free(ep.path);
            if (ep.summary) |s| testing.allocator.free(s);
            testing.allocator.free(ep.url);
            for (ep.headers.items) |h| {
                testing.allocator.free(h.name);
                testing.allocator.free(h.value);
            }
            if (ep.body_example) |b| testing.allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    try testing.expect(endpoints.items.len > 0);

    const volt_content = try OpenAPIImport.endpointToVolt(testing.allocator, &endpoints.items[0]);
    defer testing.allocator.free(volt_content);

    // Should contain the key fields
    try testing.expect(mem.indexOf(u8, volt_content, "name: Login") != null);
    try testing.expect(mem.indexOf(u8, volt_content, "method: GET") != null);
    try testing.expect(mem.indexOf(u8, volt_content, "url: http://127.0.0.1:8787/login") != null);
    try testing.expect(mem.indexOf(u8, volt_content, "status equals 200") != null);
}

test "generated .volt content parses back correctly" {
    const json_content = @embedFile("fixtures/openapi/openapi-min.json");

    var endpoints = try OpenAPIImport.parseOpenAPI(testing.allocator, json_content);
    defer {
        for (endpoints.items) |*ep| {
            testing.allocator.free(ep.path);
            if (ep.summary) |s| testing.allocator.free(s);
            testing.allocator.free(ep.url);
            for (ep.headers.items) |h| {
                testing.allocator.free(h.name);
                testing.allocator.free(h.value);
            }
            if (ep.body_example) |b| testing.allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    const volt_content = try OpenAPIImport.endpointToVolt(testing.allocator, &endpoints.items[0]);
    defer testing.allocator.free(volt_content);

    // Parse the generated .volt content with VoltFile parser
    var req = try VoltFile.parse(testing.allocator, volt_content);
    defer req.deinit();

    try testing.expectEqualStrings("Login", req.name.?);
    try testing.expectEqual(VoltFile.Method.GET, req.method);
    try testing.expectEqualStrings("http://127.0.0.1:8787/login", req.url);
    try testing.expectEqual(@as(usize, 1), req.tests.items.len);
    try testing.expectEqualStrings("status", req.tests.items[0].field);
    try testing.expectEqualStrings("equals", req.tests.items[0].operator);
    try testing.expectEqualStrings("200", req.tests.items[0].value);
}

test "import OpenAPI with multiple paths and methods" {
    const json_content =
        \\{
        \\  "openapi": "3.0.3",
        \\  "info": { "title": "Multi-Endpoint API", "version": "2.0.0" },
        \\  "servers": [{ "url": "https://api.example.com/v2" }],
        \\  "paths": {
        \\    "/users": {
        \\      "get": {
        \\        "summary": "List Users",
        \\        "responses": { "200": { "description": "OK" } }
        \\      },
        \\      "post": {
        \\        "summary": "Create User",
        \\        "requestBody": {
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {
        \\                "type": "object",
        \\                "example": { "name": "John", "email": "john@test.com" }
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "responses": { "201": { "description": "Created" } }
        \\      }
        \\    },
        \\    "/users/{id}": {
        \\      "get": {
        \\        "summary": "Get User",
        \\        "parameters": [{
        \\          "name": "X-Request-Id",
        \\          "in": "header",
        \\          "schema": { "type": "string" }
        \\        }],
        \\        "responses": { "200": { "description": "OK" } }
        \\      },
        \\      "put": {
        \\        "summary": "Update User",
        \\        "requestBody": {
        \\          "content": {
        \\            "application/json": {
        \\              "schema": { "type": "object" }
        \\            }
        \\          }
        \\        },
        \\        "responses": { "200": { "description": "Updated" } }
        \\      },
        \\      "delete": {
        \\        "summary": "Delete User",
        \\        "responses": { "204": { "description": "Deleted" } }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var endpoints = try OpenAPIImport.parseOpenAPI(testing.allocator, json_content);
    defer {
        for (endpoints.items) |*ep| {
            testing.allocator.free(ep.path);
            if (ep.summary) |s| testing.allocator.free(s);
            testing.allocator.free(ep.url);
            for (ep.headers.items) |h| {
                testing.allocator.free(h.name);
                testing.allocator.free(h.value);
            }
            if (ep.body_example) |b| testing.allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    // 5 endpoints total: GET /users, POST /users, GET /users/{id}, PUT /users/{id}, DELETE /users/{id}
    try testing.expectEqual(@as(usize, 5), endpoints.items.len);

    // Verify methods present
    var method_counts = std.StringHashMap(usize).init(testing.allocator);
    defer method_counts.deinit();
    for (endpoints.items) |ep| {
        const entry = try method_counts.getOrPut(ep.method);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }
    try testing.expectEqual(@as(usize, 2), method_counts.get("GET").?);
    try testing.expectEqual(@as(usize, 1), method_counts.get("POST").?);
    try testing.expectEqual(@as(usize, 1), method_counts.get("PUT").?);
    try testing.expectEqual(@as(usize, 1), method_counts.get("DELETE").?);

    // Verify POST has json body type
    for (endpoints.items) |ep| {
        if (mem.eql(u8, ep.method, "POST")) {
            try testing.expectEqualStrings("json", ep.body_type);
            try testing.expect(ep.body_example != null);
        }
    }

    // Verify DELETE has 204 status
    for (endpoints.items) |ep| {
        if (mem.eql(u8, ep.method, "DELETE")) {
            try testing.expectEqual(@as(u16, 204), ep.expected_status.?);
        }
    }
}

test "import OpenAPI with header parameters" {
    const json_content =
        \\{
        \\  "openapi": "3.0.3",
        \\  "info": { "title": "Header API", "version": "1.0.0" },
        \\  "servers": [{ "url": "https://api.example.com" }],
        \\  "paths": {
        \\    "/data": {
        \\      "get": {
        \\        "summary": "Get Data",
        \\        "parameters": [
        \\          { "name": "X-Api-Key", "in": "header", "schema": { "type": "string" } },
        \\          { "name": "X-Request-Id", "in": "header", "schema": { "type": "string" } },
        \\          { "name": "page", "in": "query", "schema": { "type": "integer" } }
        \\        ],
        \\        "responses": { "200": { "description": "OK" } }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var endpoints = try OpenAPIImport.parseOpenAPI(testing.allocator, json_content);
    defer {
        for (endpoints.items) |*ep| {
            testing.allocator.free(ep.path);
            if (ep.summary) |s| testing.allocator.free(s);
            testing.allocator.free(ep.url);
            for (ep.headers.items) |h| {
                testing.allocator.free(h.name);
                testing.allocator.free(h.value);
            }
            if (ep.body_example) |b| testing.allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    try testing.expectEqual(@as(usize, 1), endpoints.items.len);
    const ep = &endpoints.items[0];

    // Only header params should be extracted (not query params)
    try testing.expectEqual(@as(usize, 2), ep.headers.items.len);

    var found_api_key = false;
    var found_request_id = false;
    for (ep.headers.items) |h| {
        if (mem.eql(u8, h.name, "X-Api-Key")) found_api_key = true;
        if (mem.eql(u8, h.name, "X-Request-Id")) found_request_id = true;
    }
    try testing.expect(found_api_key);
    try testing.expect(found_request_id);
}

test "importOpenAPIToVoltFiles produces one .volt string per endpoint" {
    const json_content = @embedFile("fixtures/openapi/openapi-min.json");

    var volt_files = try OpenAPIImport.importOpenAPIToVoltFiles(testing.allocator, json_content);
    defer {
        for (volt_files.items) |item| testing.allocator.free(item);
        volt_files.deinit();
    }

    try testing.expectEqual(@as(usize, 1), volt_files.items.len);

    // Each string should be valid .volt content
    var req = try VoltFile.parse(testing.allocator, volt_files.items[0]);
    defer req.deinit();

    try testing.expectEqual(VoltFile.Method.GET, req.method);
    try testing.expect(mem.indexOf(u8, req.url, "/login") != null);
}

test "import Swagger 2.0 fallback" {
    const json_content =
        \\{
        \\  "swagger": "2.0",
        \\  "info": { "title": "Legacy API", "version": "1.0.0" },
        \\  "host": "old-api.example.com",
        \\  "basePath": "/api/v1",
        \\  "schemes": ["https"],
        \\  "paths": {
        \\    "/items": {
        \\      "get": {
        \\        "summary": "List Items",
        \\        "responses": { "200": { "description": "OK" } }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var endpoints = try OpenAPIImport.parseOpenAPI(testing.allocator, json_content);
    defer {
        for (endpoints.items) |*ep| {
            testing.allocator.free(ep.path);
            if (ep.summary) |s| testing.allocator.free(s);
            testing.allocator.free(ep.url);
            for (ep.headers.items) |h| {
                testing.allocator.free(h.name);
                testing.allocator.free(h.value);
            }
            if (ep.body_example) |b| testing.allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    try testing.expectEqual(@as(usize, 1), endpoints.items.len);
    try testing.expectEqualStrings("https://old-api.example.com/api/v1/items", endpoints.items[0].url);
    try testing.expectEqualStrings("List Items", endpoints.items[0].summary.?);
}

test "import empty OpenAPI returns no endpoints" {
    const json_content =
        \\{
        \\  "openapi": "3.0.3",
        \\  "info": { "title": "Empty", "version": "1.0.0" },
        \\  "paths": {}
        \\}
    ;

    var endpoints = try OpenAPIImport.parseOpenAPI(testing.allocator, json_content);
    defer {
        for (endpoints.items) |*ep| {
            testing.allocator.free(ep.path);
            if (ep.summary) |s| testing.allocator.free(s);
            testing.allocator.free(ep.url);
            for (ep.headers.items) |h| {
                testing.allocator.free(h.name);
                testing.allocator.free(h.value);
            }
            if (ep.body_example) |b| testing.allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    try testing.expectEqual(@as(usize, 0), endpoints.items.len);
}

test "import non-openapi content returns empty" {
    const content = "not valid json at all";

    var endpoints = try OpenAPIImport.parseOpenAPI(testing.allocator, content);
    defer {
        for (endpoints.items) |*ep| ep.deinit();
        endpoints.deinit();
    }

    try testing.expectEqual(@as(usize, 0), endpoints.items.len);
}
