const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const volt_core = @import("volt-core");
const VoltFile = volt_core.VoltFile;
const Validator = volt_core.Validator;
const Formatter = volt_core.Formatter;

// ── Lint and Validation Tests ───────────────────────────────────────────
//
// Tests the Validator (JSON schema validation, schema parsing, inference)
// and Formatter (JSON pretty-print, minify, XML format) modules using
// realistic payloads matching the launch-schedule test fixtures.

// ── JSON Schema Validation ──────────────────────────────────────────────

test "validate GraphQL response schema" {
    // Simulated GraphQL response body
    const json_body =
        \\{"data": {"users": [{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]}}
    ;

    var schema = Validator.Schema.init(testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    try schema.required_fields.append("data");
    try schema.fields.append(.{ .name = "data", .field_type = .object, .required = true });

    var result = try Validator.validate(testing.allocator, json_body, &schema);
    defer result.deinit();

    try testing.expect(result.valid);
    try testing.expectEqual(@as(usize, 0), result.errors.items.len);
}

test "validate OAuth token response schema" {
    const json_body =
        \\{"access_token": "eyJhbGciOiJIUzI1NiJ9.test", "token_type": "bearer", "expires_in": 3600}
    ;

    var schema = Validator.Schema.init(testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    try schema.required_fields.append("access_token");
    try schema.required_fields.append("token_type");
    try schema.required_fields.append("expires_in");

    try schema.fields.append(.{ .name = "access_token", .field_type = .string, .required = true });
    try schema.fields.append(.{ .name = "token_type", .field_type = .string, .required = true });
    try schema.fields.append(.{ .name = "expires_in", .field_type = .number, .required = true });

    var result = try Validator.validate(testing.allocator, json_body, &schema);
    defer result.deinit();

    try testing.expect(result.valid);
    try testing.expect(result.fields_checked >= 3);
}

test "validate login response schema" {
    // Matches test_server.py /login endpoint
    const json_body =
        \\{"token": "abc123", "user": {"id": 1}}
    ;

    var schema = Validator.Schema.init(testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    try schema.required_fields.append("token");
    try schema.required_fields.append("user");

    try schema.fields.append(.{ .name = "token", .field_type = .string, .required = true });
    try schema.fields.append(.{ .name = "user", .field_type = .object, .required = true });

    var result = try Validator.validate(testing.allocator, json_body, &schema);
    defer result.deinit();

    try testing.expect(result.valid);
}

test "validate fails on missing required field" {
    const json_body =
        \\{"token": "abc123"}
    ;

    var schema = Validator.Schema.init(testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    try schema.required_fields.append("token");
    try schema.required_fields.append("user");

    try schema.fields.append(.{ .name = "token", .field_type = .string, .required = true });
    try schema.fields.append(.{ .name = "user", .field_type = .object, .required = true });

    var result = try Validator.validate(testing.allocator, json_body, &schema);
    defer result.deinit();

    try testing.expect(!result.valid);
    try testing.expect(result.errors.items.len >= 1);

    // Find the specific error for "user"
    var found_user_error = false;
    for (result.errors.items) |err| {
        if (mem.eql(u8, err.path, "user")) {
            try testing.expectEqualStrings("Required field missing", err.message);
            found_user_error = true;
        }
    }
    try testing.expect(found_user_error);
}

test "validate fails on type mismatch" {
    const json_body =
        \\{"id": "not_a_number", "name": 42}
    ;

    var schema = Validator.Schema.init(testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    try schema.fields.append(.{ .name = "id", .field_type = .number });
    try schema.fields.append(.{ .name = "name", .field_type = .string });

    var result = try Validator.validate(testing.allocator, json_body, &schema);
    defer result.deinit();

    try testing.expect(!result.valid);
    try testing.expect(result.errors.items.len >= 2);
}

test "validate empty body fails" {
    var schema = Validator.Schema.init(testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    var result = try Validator.validate(testing.allocator, "", &schema);
    defer result.deinit();

    try testing.expect(!result.valid);
    try testing.expect(result.errors.items.len >= 1);
    try testing.expectEqualStrings("Empty response body", result.errors.items[0].message);
}

test "validate root type mismatch (array vs object)" {
    const json_body = "[1, 2, 3]";

    var schema = Validator.Schema.init(testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    var result = try Validator.validate(testing.allocator, json_body, &schema);
    defer result.deinit();

    try testing.expect(!result.valid);
    try testing.expectEqualStrings("Root type mismatch", result.errors.items[0].message);
}

test "validate nullable field accepts null" {
    const json_body =
        \\{"id": 42, "email": null}
    ;

    var schema = Validator.Schema.init(testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    try schema.fields.append(.{ .name = "id", .field_type = .number });
    try schema.fields.append(.{ .name = "email", .field_type = .string, .nullable = true });

    var result = try Validator.validate(testing.allocator, json_body, &schema);
    defer result.deinit();

    try testing.expect(result.valid);
}

test "validate optional absent field produces warning not error" {
    const json_body =
        \\{"id": 42}
    ;

    var schema = Validator.Schema.init(testing.allocator);
    defer schema.deinit();
    schema.root_type = .object;

    try schema.fields.append(.{ .name = "id", .field_type = .number });
    try schema.fields.append(.{ .name = "email", .field_type = .string }); // not in required_fields

    var result = try Validator.validate(testing.allocator, json_body, &schema);
    defer result.deinit();

    try testing.expect(result.valid);
    try testing.expect(result.warnings.items.len >= 1);
    try testing.expectEqualStrings("email", result.warnings.items[0].path);
}

// ── Schema Inference ────────────────────────────────────────────────────

test "infer schema from login response" {
    const json_body =
        \\{"token": "abc123", "user": {"id": 1}}
    ;

    var schema = try Validator.inferSchema(testing.allocator, json_body);
    defer schema.deinit();

    try testing.expectEqual(Validator.SchemaType.object, schema.root_type);
    try testing.expect(schema.fields.items.len >= 2);

    var found_token = false;
    var found_user = false;
    for (schema.fields.items) |field| {
        if (mem.eql(u8, field.name, "token")) {
            try testing.expectEqual(Validator.SchemaType.string, field.field_type);
            found_token = true;
        }
        if (mem.eql(u8, field.name, "user")) {
            try testing.expectEqual(Validator.SchemaType.object, field.field_type);
            found_user = true;
        }
    }
    try testing.expect(found_token);
    try testing.expect(found_user);
}

test "infer schema from GraphQL response" {
    const json_body =
        \\{"data": {"users": [{"id": 1, "name": "Alice"}]}, "errors": null}
    ;

    var schema = try Validator.inferSchema(testing.allocator, json_body);
    defer schema.deinit();

    try testing.expectEqual(Validator.SchemaType.object, schema.root_type);

    var found_data = false;
    for (schema.fields.items) |field| {
        if (mem.eql(u8, field.name, "data")) {
            try testing.expectEqual(Validator.SchemaType.object, field.field_type);
            found_data = true;
        }
    }
    try testing.expect(found_data);
}

test "infer schema from array response" {
    const json_body = "[1, 2, 3]";

    var schema = try Validator.inferSchema(testing.allocator, json_body);
    defer schema.deinit();

    try testing.expectEqual(Validator.SchemaType.array, schema.root_type);
    // Arrays don't have top-level fields
    try testing.expectEqual(@as(usize, 0), schema.fields.items.len);
}

test "infer schema from empty string" {
    var schema = try Validator.inferSchema(testing.allocator, "");
    defer schema.deinit();

    // Default should be object with no fields
    try testing.expectEqual(@as(usize, 0), schema.fields.items.len);
}

// ── Schema Parsing ──────────────────────────────────────────────────────

test "parse schema for OAuth token response" {
    const schema_def =
        \\type: object
        \\required: access_token, token_type, expires_in
        \\properties:
        \\  access_token: string
        \\  token_type: string
        \\  expires_in: number
        \\  scope: string
    ;

    var schema = try Validator.parseSchema(testing.allocator, schema_def);
    defer schema.deinit();

    try testing.expectEqual(Validator.SchemaType.object, schema.root_type);
    try testing.expectEqual(@as(usize, 3), schema.required_fields.items.len);
    try testing.expectEqual(@as(usize, 4), schema.fields.items.len);

    // Required fields
    try testing.expectEqualStrings("access_token", schema.required_fields.items[0]);
    try testing.expectEqualStrings("token_type", schema.required_fields.items[1]);

    // access_token should be marked required
    try testing.expect(schema.fields.items[0].required);
    try testing.expectEqual(Validator.SchemaType.string, schema.fields.items[0].field_type);

    // scope should not be required
    try testing.expect(!schema.fields.items[3].required);
}

test "parse schema with nullable field" {
    const schema_def =
        \\type: object
        \\required: id
        \\properties:
        \\  id: number
        \\  email: string nullable
    ;

    var schema = try Validator.parseSchema(testing.allocator, schema_def);
    defer schema.deinit();

    try testing.expectEqual(@as(usize, 2), schema.fields.items.len);
    try testing.expect(!schema.fields.items[0].nullable); // id
    try testing.expect(schema.fields.items[1].nullable); // email
}

// ── Validation Result Formatting ────────────────────────────────────────

test "format passing validation result" {
    var result = Validator.ValidationResult.init(testing.allocator);
    defer result.deinit();
    result.valid = true;
    result.fields_checked = 5;

    const output = try Validator.formatResult(&result, testing.allocator);
    defer testing.allocator.free(output);

    try testing.expect(mem.indexOf(u8, output, "PASSED") != null);
    try testing.expect(mem.indexOf(u8, output, "5") != null);
}

test "format failing validation result" {
    var result = Validator.ValidationResult.init(testing.allocator);
    defer result.deinit();
    result.valid = false;
    result.fields_checked = 3;

    try result.errors.append(.{
        .path = "token",
        .message = "Required field missing",
        .expected = "present",
        .actual = "missing",
    });

    const output = try Validator.formatResult(&result, testing.allocator);
    defer testing.allocator.free(output);

    try testing.expect(mem.indexOf(u8, output, "FAILED") != null);
    try testing.expect(mem.indexOf(u8, output, "token") != null);
    try testing.expect(mem.indexOf(u8, output, "Required field missing") != null);
}

// ── JSON Formatting (Lint) ──────────────────────────────────────────────

test "format minified JSON into pretty-printed" {
    const minified = "{\"token\":\"abc123\",\"user\":{\"id\":1}}";

    const pretty = try Formatter.formatJsonPlain(testing.allocator, minified);
    defer testing.allocator.free(pretty);

    // Should have newlines
    try testing.expect(mem.indexOf(u8, pretty, "\n") != null);
    // Should have indentation
    try testing.expect(mem.indexOf(u8, pretty, "  ") != null);
    // Content preserved
    try testing.expect(mem.indexOf(u8, pretty, "\"token\"") != null);
    try testing.expect(mem.indexOf(u8, pretty, "\"abc123\"") != null);
    try testing.expect(mem.indexOf(u8, pretty, "\"user\"") != null);
}

test "format already pretty JSON" {
    const input =
        \\{
        \\  "name": "test",
        \\  "value": 42
        \\}
    ;

    const pretty = try Formatter.formatJsonPlain(testing.allocator, input);
    defer testing.allocator.free(pretty);

    try testing.expect(mem.indexOf(u8, pretty, "\"name\"") != null);
    try testing.expect(mem.indexOf(u8, pretty, "42") != null);
}

test "minify pretty-printed JSON" {
    const pretty = "{\n  \"name\": \"test\",\n  \"value\": 42\n}";

    const minified = try Formatter.minifyJson(testing.allocator, pretty);
    defer testing.allocator.free(minified);

    try testing.expectEqualStrings("{\"name\":\"test\",\"value\":42}", minified);
}

test "format empty JSON object" {
    const result = try Formatter.formatJsonPlain(testing.allocator, "{}");
    defer testing.allocator.free(result);

    try testing.expect(mem.indexOf(u8, result, "{}") != null);
}

test "format JSON array" {
    const input = "[1,2,3]";

    const pretty = try Formatter.formatJsonPlain(testing.allocator, input);
    defer testing.allocator.free(pretty);

    try testing.expect(mem.indexOf(u8, pretty, "1") != null);
    try testing.expect(mem.indexOf(u8, pretty, "2") != null);
    try testing.expect(mem.indexOf(u8, pretty, "3") != null);
}

test "format JSON with nested objects and arrays" {
    const input = "{\"users\":[{\"id\":1,\"name\":\"Alice\"},{\"id\":2,\"name\":\"Bob\"}],\"total\":2}";

    const pretty = try Formatter.formatJsonPlain(testing.allocator, input);
    defer testing.allocator.free(pretty);

    try testing.expect(mem.indexOf(u8, pretty, "\"users\"") != null);
    try testing.expect(mem.indexOf(u8, pretty, "\"Alice\"") != null);
    try testing.expect(mem.indexOf(u8, pretty, "\"Bob\"") != null);
    try testing.expect(mem.indexOf(u8, pretty, "\"total\"") != null);
}

test "format JSON with boolean and null values" {
    const input = "{\"active\":true,\"deleted\":false,\"error\":null}";

    const pretty = try Formatter.formatJsonPlain(testing.allocator, input);
    defer testing.allocator.free(pretty);

    try testing.expect(mem.indexOf(u8, pretty, "true") != null);
    try testing.expect(mem.indexOf(u8, pretty, "false") != null);
    try testing.expect(mem.indexOf(u8, pretty, "null") != null);
}

// ── XML Formatting ──────────────────────────────────────────────────────

test "format XML response" {
    const xml_input = "<?xml version='1.0'?><root><item>value</item></root>";

    const formatted = try Formatter.formatXml(testing.allocator, xml_input);
    defer testing.allocator.free(formatted);

    try testing.expect(mem.indexOf(u8, formatted, "<?xml") != null);
    try testing.expect(mem.indexOf(u8, formatted, "<root>") != null);
    try testing.expect(mem.indexOf(u8, formatted, "<item>") != null);
    try testing.expect(mem.indexOf(u8, formatted, "</root>") != null);
    // Should have newlines for pretty-printing
    try testing.expect(mem.indexOf(u8, formatted, "\n") != null);
}

// ── End-to-End: Parse Fixture -> Validate Schema ────────────────────────

test "parse and validate chain fixture structure" {
    const content = @embedFile("fixtures/chain/01-login.volt");
    var req = try VoltFile.parse(testing.allocator, content);
    defer req.deinit();

    // Validate the request is a well-formed GET (test server /login uses GET)
    try testing.expectEqual(VoltFile.Method.GET, req.method);
    try testing.expect(req.url.len > 0);

    // The login fixture should reference the local test server
    try testing.expect(mem.indexOf(u8, req.url, "127.0.0.1") != null or
        mem.indexOf(u8, req.url, "localhost") != null or
        mem.indexOf(u8, req.url, "login") != null);
}

test "validate all fixture names are non-empty" {
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

        try testing.expect(req.name != null);
        try testing.expect(req.name.?.len > 0);
        try testing.expect(req.url.len > 0);
    }
}
