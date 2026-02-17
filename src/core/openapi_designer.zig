const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── OpenAPI Design-First Workflow ───────────────────────────────────────
// Parse OpenAPI 3.0 JSON specs, generate .volt files for each endpoint,
// and validate actual responses against the spec definitions.

pub const Parameter = struct {
    name: []const u8,
    location: []const u8, // "query", "path", "header"
    required: bool,
    param_type: []const u8,
};

pub const RequestBody = struct {
    content_type: []const u8,
    schema_type: []const u8,
    example: ?[]const u8 = null,
};

pub const ResponseDef = struct {
    status_code: u16,
    description: []const u8,
    content_type: ?[]const u8 = null,
};

pub const Endpoint = struct {
    path: []const u8,
    method: []const u8,
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
    parameters: std.ArrayList(Parameter),
    request_body: ?RequestBody = null,
    responses: std.ArrayList(ResponseDef),

    pub fn init(allocator: Allocator) Endpoint {
        return .{
            .path = "",
            .method = "GET",
            .parameters = std.ArrayList(Parameter).init(allocator),
            .responses = std.ArrayList(ResponseDef).init(allocator),
        };
    }

    pub fn deinit(self: *Endpoint) void {
        self.parameters.deinit();
        self.responses.deinit();
    }
};

pub const OpenAPISpec = struct {
    title: []const u8,
    version: []const u8,
    description: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    endpoints: std.ArrayList(Endpoint),

    pub fn init(allocator: Allocator) OpenAPISpec {
        return .{
            .title = "",
            .version = "",
            .endpoints = std.ArrayList(Endpoint).init(allocator),
        };
    }

    pub fn deinit(self: *OpenAPISpec) void {
        for (self.endpoints.items) |*ep| {
            ep.deinit();
        }
        self.endpoints.deinit();
    }
};

pub const GeneratedFile = struct {
    path: []const u8,
    content: []const u8,
};

pub const ValidationSeverity = enum {
    error_sev,
    warning,

    pub fn toString(self: ValidationSeverity) []const u8 {
        return switch (self) {
            .error_sev => "ERROR",
            .warning => "WARNING",
        };
    }
};

pub const ValidationError = struct {
    field: []const u8,
    message: []const u8,
    severity: ValidationSeverity,
};

/// Parse an OpenAPI 3.0 JSON specification into an OpenAPISpec struct.
/// Handles info, servers, and paths with their methods, parameters, requestBody, and responses.
pub fn parseOpenAPISpec(allocator: Allocator, json_content: []const u8) ?OpenAPISpec {
    var spec = OpenAPISpec.init(allocator);

    // Parse info section
    spec.title = extractNestedString(json_content, "info", "title") orelse {
        spec.deinit();
        return null;
    };
    spec.version = extractNestedString(json_content, "info", "version") orelse {
        spec.deinit();
        return null;
    };
    spec.description = extractNestedString(json_content, "info", "description");

    // Parse servers section - extract first server url
    spec.base_url = extractFirstServerUrl(json_content);

    // Parse paths section
    const paths_start = mem.indexOf(u8, json_content, "\"paths\"") orelse {
        // No paths is valid but not useful
        return spec;
    };
    const after_paths_key = json_content[paths_start + "\"paths\"".len ..];

    // Find the paths object
    const obj_start = mem.indexOf(u8, after_paths_key, "{") orelse return spec;
    const paths_obj = after_paths_key[obj_start..];

    // Find matching closing brace for paths object
    const paths_content = findMatchingBrace(paths_obj) orelse return spec;

    // Parse each path entry: "/path": { "method": { ... } }
    var remaining = paths_content[1..]; // skip opening brace
    while (mem.indexOf(u8, remaining, "\"")) |path_quote_start| {
        const after_quote = remaining[path_quote_start + 1 ..];
        const path_quote_end = mem.indexOf(u8, after_quote, "\"") orelse break;
        const path_str = after_quote[0..path_quote_end];

        // Skip non-path keys (paths start with /)
        if (path_str.len == 0 or path_str[0] != '/') {
            remaining = after_quote[path_quote_end + 1 ..];
            continue;
        }

        // Find the path's method object
        const after_path_key = after_quote[path_quote_end + 1 ..];
        const method_obj_start = mem.indexOf(u8, after_path_key, "{") orelse break;
        const method_obj_content = after_path_key[method_obj_start..];
        const method_block = findMatchingBrace(method_obj_content) orelse break;

        // Try each HTTP method
        const methods = [_][]const u8{ "get", "post", "put", "patch", "delete", "head", "options" };
        for (methods) |method_name| {
            var method_search_buf: [32]u8 = undefined;
            const method_search = std.fmt.bufPrint(&method_search_buf, "\"{s}\"", .{method_name}) catch continue;

            if (mem.indexOf(u8, method_block, method_search)) |method_pos| {
                var endpoint = Endpoint.init(allocator);
                endpoint.path = path_str;
                endpoint.method = methodToUpper(method_name);

                // Extract summary and description from method block
                const method_data = method_block[method_pos..];
                endpoint.summary = extractJsonString(method_data, "summary");
                endpoint.description = extractJsonString(method_data, "description");

                // Parse parameters
                parseParameters(allocator, method_data, &endpoint) catch {};

                // Parse request body
                endpoint.request_body = parseRequestBody(method_data);

                // Parse responses
                parseResponses(allocator, method_data, &endpoint) catch {};

                spec.endpoints.append(endpoint) catch {
                    endpoint.deinit();
                    continue;
                };
            }
        }

        remaining = after_path_key[method_obj_start + method_block.len ..];
    }

    return spec;
}

/// Generate .volt files from a parsed OpenAPI spec.
/// Creates one .volt file per endpoint plus a _collection.volt and _env.volt.
pub fn generateVoltFiles(allocator: Allocator, spec: *const OpenAPISpec) std.ArrayList(GeneratedFile) {
    var files = std.ArrayList(GeneratedFile).init(allocator);

    const base_url = spec.base_url orelse "https://api.example.com";

    // Generate _collection.volt
    var coll_buf = std.ArrayList(u8).init(allocator);
    const coll_writer = coll_buf.writer();
    coll_writer.print("# Collection: {s}\n", .{spec.title}) catch {};
    coll_writer.print("# Version: {s}\n", .{spec.version}) catch {};
    if (spec.description) |desc| {
        coll_writer.print("# {s}\n", .{desc}) catch {};
    }
    coll_writer.writeAll("\n---\n\n") catch {};
    coll_writer.print("BASE_URL {s}\n", .{base_url}) catch {};
    files.append(.{
        .path = "_collection.volt",
        .content = coll_buf.toOwnedSlice() catch "",
    }) catch {};

    // Generate _env.volt
    var env_buf = std.ArrayList(u8).init(allocator);
    const env_writer = env_buf.writer();
    env_writer.writeAll("# Environment variables\n\n") catch {};
    env_writer.writeAll("---\n\n") catch {};
    env_writer.print("base_url={s}\n", .{base_url}) catch {};
    files.append(.{
        .path = "_env.volt",
        .content = env_buf.toOwnedSlice() catch "",
    }) catch {};

    // Generate one .volt file per endpoint
    for (spec.endpoints.items) |endpoint| {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        // Header comment
        if (endpoint.summary) |summary| {
            writer.print("# {s}\n", .{summary}) catch {};
        }
        if (endpoint.description) |desc| {
            writer.print("# {s}\n", .{desc}) catch {};
        }

        writer.writeAll("\n---\n\n") catch {};

        // Method and URL
        writer.print("{s} {s}{s}\n", .{ endpoint.method, base_url, endpoint.path }) catch {};

        // Headers from header-type parameters
        var has_headers = false;
        for (endpoint.parameters.items) |param| {
            if (mem.eql(u8, param.location, "header")) {
                if (!has_headers) {
                    writer.writeAll("\n") catch {};
                    has_headers = true;
                }
                writer.print("{s}: <{s}>\n", .{ param.name, param.param_type }) catch {};
            }
        }

        // Request body
        if (endpoint.request_body) |body| {
            writer.writeAll("\n") catch {};
            writer.print("Content-Type: {s}\n", .{body.content_type}) catch {};
            writer.writeAll("\n") catch {};
            if (body.example) |example| {
                writer.print("{s}\n", .{example}) catch {};
            } else {
                writer.writeAll("{}\n") catch {};
            }
        }

        // Test assertions from response definitions
        if (endpoint.responses.items.len > 0) {
            writer.writeAll("\n---\n\n") catch {};
            for (endpoint.responses.items) |resp| {
                writer.print("assert status equals {d}\n", .{resp.status_code}) catch {};
            }
        }

        // Build filename from method and path
        const filename = buildFilename(allocator, endpoint.method, endpoint.path) catch continue;

        files.append(.{
            .path = filename,
            .content = buf.toOwnedSlice() catch "",
        }) catch {};
    }

    return files;
}

/// Validate an actual response against a spec endpoint definition.
/// Returns a list of validation errors found.
pub fn validateResponseAgainstSpec(
    allocator: Allocator,
    endpoint: *const Endpoint,
    status_code: u16,
    content_type: ?[]const u8,
    body: []const u8,
) std.ArrayList(ValidationError) {
    _ = body;
    var errors = std.ArrayList(ValidationError).init(allocator);

    // Check if status code is in the endpoint's response definitions
    var status_found = false;
    var expected_content_type: ?[]const u8 = null;
    for (endpoint.responses.items) |resp| {
        if (resp.status_code == status_code) {
            status_found = true;
            expected_content_type = resp.content_type;
            break;
        }
    }

    if (!status_found) {
        // Build expected status codes string
        var expected_buf: [128]u8 = undefined;
        var expected_len: usize = 0;
        for (endpoint.responses.items, 0..) |resp, i| {
            if (i > 0) {
                if (expected_len + 2 < expected_buf.len) {
                    @memcpy(expected_buf[expected_len .. expected_len + 2], ", ");
                    expected_len += 2;
                }
            }
            const code_str = std.fmt.bufPrint(expected_buf[expected_len..], "{d}", .{resp.status_code}) catch break;
            expected_len += code_str.len;
        }

        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "Unexpected status code {d}, expected one of: {s}", .{ status_code, expected_buf[0..expected_len] }) catch "Unexpected status code";

        errors.append(.{
            .field = "status_code",
            .message = msg,
            .severity = .error_sev,
        }) catch {};
    }

    // Check content-type if expected
    if (expected_content_type) |expected_ct| {
        if (content_type) |actual_ct| {
            // Compare base content type (ignore parameters like charset)
            const actual_base = extractBaseContentType(actual_ct);
            if (!mem.eql(u8, actual_base, expected_ct)) {
                var ct_msg_buf: [256]u8 = undefined;
                const ct_msg = std.fmt.bufPrint(&ct_msg_buf, "Expected content-type '{s}', got '{s}'", .{ expected_ct, actual_base }) catch "Content-type mismatch";

                errors.append(.{
                    .field = "content_type",
                    .message = ct_msg,
                    .severity = .error_sev,
                }) catch {};
            }
        } else {
            errors.append(.{
                .field = "content_type",
                .message = "Response missing content-type header",
                .severity = .warning,
            }) catch {};
        }
    }

    return errors;
}

/// Format a human-readable spec summary for display.
pub fn formatSpecSummary(allocator: Allocator, spec: *const OpenAPISpec) []const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    writer.print("\x1b[1m{s}\x1b[0m v{s}\n", .{ spec.title, spec.version }) catch return "";
    if (spec.description) |desc| {
        writer.print("{s}\n", .{desc}) catch {};
    }
    if (spec.base_url) |base| {
        writer.print("Server: {s}\n", .{base}) catch {};
    }
    writer.writeAll("\n") catch {};

    writer.print("Endpoints ({d}):\n", .{spec.endpoints.items.len}) catch {};
    for (spec.endpoints.items) |endpoint| {
        const method_color: []const u8 = if (mem.eql(u8, endpoint.method, "GET"))
            "\x1b[32m"
        else if (mem.eql(u8, endpoint.method, "POST"))
            "\x1b[34m"
        else if (mem.eql(u8, endpoint.method, "PUT"))
            "\x1b[33m"
        else if (mem.eql(u8, endpoint.method, "DELETE"))
            "\x1b[31m"
        else
            "\x1b[36m";

        writer.print("  {s}{s}\x1b[0m {s}", .{ method_color, endpoint.method, endpoint.path }) catch {};
        if (endpoint.summary) |summary| {
            writer.print(" - {s}", .{summary}) catch {};
        }
        writer.writeAll("\n") catch {};
    }

    return buf.toOwnedSlice() catch return "";
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// Extract a string value for a given key from simple JSON.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = json[key_pos + search_key.len ..];

    var pos: usize = 0;
    while (pos < after_key.len and (after_key[pos] == ':' or after_key[pos] == ' ' or after_key[pos] == '\t')) {
        pos += 1;
    }
    if (pos >= after_key.len) return null;
    if (after_key[pos] != '"') return null;
    pos += 1;

    const value_start = pos;
    while (pos < after_key.len and after_key[pos] != '"') {
        if (after_key[pos] == '\\') pos += 1;
        pos += 1;
    }

    return after_key[value_start..pos];
}

/// Extract a string value nested inside an object key.
fn extractNestedString(json: []const u8, outer_key: []const u8, inner_key: []const u8) ?[]const u8 {
    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{outer_key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = json[key_pos + search_key.len ..];

    // Find the opening brace of the outer object
    const obj_start = mem.indexOf(u8, after_key, "{") orelse return null;
    const obj_content = after_key[obj_start..];
    const obj_block = findMatchingBrace(obj_content) orelse return null;

    return extractJsonString(obj_block, inner_key);
}

/// Extract the first server URL from the "servers" array.
fn extractFirstServerUrl(json: []const u8) ?[]const u8 {
    const servers_pos = mem.indexOf(u8, json, "\"servers\"") orelse return null;
    const after_servers = json[servers_pos + "\"servers\"".len ..];

    const arr_start = mem.indexOf(u8, after_servers, "[") orelse return null;
    const arr_end = mem.indexOf(u8, after_servers, "]") orelse return null;
    const arr_content = after_servers[arr_start..arr_end];

    return extractJsonString(arr_content, "url");
}

/// Find the matching closing brace/bracket for an opening one.
fn findMatchingBrace(data: []const u8) ?[]const u8 {
    if (data.len == 0) return null;
    const open = data[0];
    const close: u8 = if (open == '{') '}' else if (open == '[') ']' else return null;
    var depth: usize = 0;
    var in_string = false;

    for (data, 0..) |c, i| {
        if (c == '"' and (i == 0 or data[i - 1] != '\\')) {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;

        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return data[0 .. i + 1];
        }
    }
    return null;
}

/// Parse parameters from a method block in the spec.
fn parseParameters(_: Allocator, method_data: []const u8, endpoint: *Endpoint) !void {
    const params_pos = mem.indexOf(u8, method_data, "\"parameters\"") orelse return;
    const after_params = method_data[params_pos + "\"parameters\"".len ..];
    const arr_start = mem.indexOf(u8, after_params, "[") orelse return;
    const arr_content = after_params[arr_start..];
    const arr_block = findMatchingBrace(arr_content) orelse return;

    // Parse each parameter object in the array
    var remaining = arr_block[1..]; // skip opening bracket
    while (mem.indexOf(u8, remaining, "{")) |obj_start| {
        const obj_data = remaining[obj_start..];
        const obj_block = findMatchingBrace(obj_data) orelse break;

        const name = extractJsonString(obj_block, "name") orelse {
            remaining = remaining[obj_start + obj_block.len ..];
            continue;
        };
        const location = extractJsonString(obj_block, "in") orelse "query";

        // Check "required" field
        const required = if (mem.indexOf(u8, obj_block, "\"required\"")) |req_pos| blk: {
            const after_req = obj_block[req_pos + "\"required\"".len ..];
            break :blk mem.indexOf(u8, after_req, "true") != null and
                (mem.indexOf(u8, after_req, "true").? < (mem.indexOf(u8, after_req, ",") orelse after_req.len));
        } else false;

        // Extract type from schema
        const param_type = extractSchemaType(obj_block) orelse "string";

        try endpoint.parameters.append(.{
            .name = name,
            .location = location,
            .required = required,
            .param_type = param_type,
        });

        remaining = remaining[obj_start + obj_block.len ..];
    }
}

/// Parse request body from a method block.
fn parseRequestBody(method_data: []const u8) ?RequestBody {
    const rb_pos = mem.indexOf(u8, method_data, "\"requestBody\"") orelse return null;
    const after_rb = method_data[rb_pos + "\"requestBody\"".len ..];
    const obj_start = mem.indexOf(u8, after_rb, "{") orelse return null;
    const obj_data = after_rb[obj_start..];
    const obj_block = findMatchingBrace(obj_data) orelse return null;

    // Look for content type in "content" object
    const content_type = if (mem.indexOf(u8, obj_block, "application/json") != null)
        "application/json"
    else if (mem.indexOf(u8, obj_block, "application/xml") != null)
        "application/xml"
    else if (mem.indexOf(u8, obj_block, "multipart/form-data") != null)
        "multipart/form-data"
    else
        "application/json";

    const schema_type = extractSchemaType(obj_block) orelse "object";

    return RequestBody{
        .content_type = content_type,
        .schema_type = schema_type,
        .example = extractJsonString(obj_block, "example"),
    };
}

/// Parse response definitions from a method block.
fn parseResponses(_: Allocator, method_data: []const u8, endpoint: *Endpoint) !void {
    const resp_key_pos = mem.indexOf(u8, method_data, "\"responses\"") orelse return;
    const after_resp_key = method_data[resp_key_pos + "\"responses\"".len ..];
    const obj_start = mem.indexOf(u8, after_resp_key, "{") orelse return;
    const obj_data = after_resp_key[obj_start..];
    const resp_block = findMatchingBrace(obj_data) orelse return;

    // Find status code keys like "200", "201", "404"
    var remaining = resp_block[1..];
    while (mem.indexOf(u8, remaining, "\"")) |quote_start| {
        const after_quote = remaining[quote_start + 1 ..];
        const quote_end = mem.indexOf(u8, after_quote, "\"") orelse break;
        const key_str = after_quote[0..quote_end];

        // Try to parse as status code
        const status_code = std.fmt.parseInt(u16, key_str, 10) catch {
            remaining = after_quote[quote_end + 1 ..];
            continue;
        };

        // Find the response object for this status code
        const after_status_key = after_quote[quote_end + 1 ..];
        const resp_obj_start = mem.indexOf(u8, after_status_key, "{") orelse break;
        const resp_obj_data = after_status_key[resp_obj_start..];
        const resp_obj_block = findMatchingBrace(resp_obj_data) orelse break;

        const description = extractJsonString(resp_obj_block, "description") orelse "";

        // Detect content type
        const content_type: ?[]const u8 = if (mem.indexOf(u8, resp_obj_block, "application/json") != null)
            "application/json"
        else if (mem.indexOf(u8, resp_obj_block, "text/plain") != null)
            "text/plain"
        else
            null;

        try endpoint.responses.append(.{
            .status_code = status_code,
            .description = description,
            .content_type = content_type,
        });

        remaining = after_status_key[resp_obj_start + resp_obj_block.len ..];
    }
}

/// Extract "type" from a "schema" object.
fn extractSchemaType(json: []const u8) ?[]const u8 {
    const schema_pos = mem.indexOf(u8, json, "\"schema\"") orelse return null;
    const after_schema = json[schema_pos + "\"schema\"".len ..];
    const obj_start = mem.indexOf(u8, after_schema, "{") orelse return null;
    const obj_data = after_schema[obj_start..];
    const schema_block = findMatchingBrace(obj_data) orelse return null;

    return extractJsonString(schema_block, "type");
}

/// Convert a lowercase HTTP method string to uppercase.
fn methodToUpper(method: []const u8) []const u8 {
    if (mem.eql(u8, method, "get")) return "GET";
    if (mem.eql(u8, method, "post")) return "POST";
    if (mem.eql(u8, method, "put")) return "PUT";
    if (mem.eql(u8, method, "patch")) return "PATCH";
    if (mem.eql(u8, method, "delete")) return "DELETE";
    if (mem.eql(u8, method, "head")) return "HEAD";
    if (mem.eql(u8, method, "options")) return "OPTIONS";
    return "GET";
}

/// Build a .volt filename from method and path.
fn buildFilename(allocator: Allocator, method: []const u8, path: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Lowercase method
    for (method) |c| {
        try writer.writeByte(if (c >= 'A' and c <= 'Z') c + 32 else c);
    }

    try writer.writeByte('-');

    // Sanitize path: replace / with -, skip leading /
    var first = true;
    for (path) |c| {
        if (c == '/') {
            if (first) {
                first = false;
                continue;
            }
            try writer.writeByte('-');
        } else if (c == '{' or c == '}') {
            // Skip braces from path parameters
            continue;
        } else {
            try writer.writeByte(c);
        }
    }

    try writer.writeAll(".volt");
    return buf.toOwnedSlice();
}

/// Extract base content type (before semicolon).
fn extractBaseContentType(ct: []const u8) []const u8 {
    if (mem.indexOf(u8, ct, ";")) |semicolon_pos| {
        return mem.trim(u8, ct[0..semicolon_pos], " ");
    }
    return ct;
}

// ── Tests ───────────────────────────────────────────────────────────────

const sample_spec =
    \\{
    \\  "openapi": "3.0.0",
    \\  "info": {
    \\    "title": "Pet Store API",
    \\    "version": "1.0.0",
    \\    "description": "A sample pet store API"
    \\  },
    \\  "servers": [
    \\    { "url": "https://petstore.example.com/v1" }
    \\  ],
    \\  "paths": {
    \\    "/pets": {
    \\      "get": {
    \\        "summary": "List all pets",
    \\        "description": "Returns all pets in the store",
    \\        "parameters": [
    \\          {
    \\            "name": "limit",
    \\            "in": "query",
    \\            "required": false,
    \\            "schema": { "type": "integer" }
    \\          }
    \\        ],
    \\        "responses": {
    \\          "200": {
    \\            "description": "A list of pets",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": { "type": "array" }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      },
    \\      "post": {
    \\        "summary": "Create a pet",
    \\        "requestBody": {
    \\          "required": true,
    \\          "content": {
    \\            "application/json": {
    \\              "schema": { "type": "object" }
    \\            }
    \\          }
    \\        },
    \\        "responses": {
    \\          "201": {
    \\            "description": "Pet created",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": { "type": "object" }
    \\              }
    \\            }
    \\          }
    \\        }
    \\      }
    \\    },
    \\    "/pets/{petId}": {
    \\      "get": {
    \\        "summary": "Get pet by ID",
    \\        "parameters": [
    \\          {
    \\            "name": "petId",
    \\            "in": "path",
    \\            "required": true,
    \\            "schema": { "type": "string" }
    \\          }
    \\        ],
    \\        "responses": {
    \\          "200": {
    \\            "description": "A single pet",
    \\            "content": {
    \\              "application/json": {
    \\                "schema": { "type": "object" }
    \\              }
    \\            }
    \\          },
    \\          "404": {
    \\            "description": "Pet not found"
    \\          }
    \\        }
    \\      }
    \\    }
    \\  }
    \\}
;

test "parseOpenAPISpec parses sample spec" {
    var spec = parseOpenAPISpec(std.testing.allocator, sample_spec) orelse {
        return error.TestUnexpectedResult;
    };
    defer spec.deinit();

    try std.testing.expectEqualStrings("Pet Store API", spec.title);
    try std.testing.expectEqualStrings("1.0.0", spec.version);
    try std.testing.expectEqualStrings("A sample pet store API", spec.description.?);
    try std.testing.expectEqualStrings("https://petstore.example.com/v1", spec.base_url.?);
    try std.testing.expect(spec.endpoints.items.len >= 2);
}

test "parseOpenAPISpec extracts endpoints with correct methods" {
    var spec = parseOpenAPISpec(std.testing.allocator, sample_spec) orelse {
        return error.TestUnexpectedResult;
    };
    defer spec.deinit();

    // Find the GET /pets endpoint
    var found_get_pets = false;
    var found_post_pets = false;
    for (spec.endpoints.items) |ep| {
        if (mem.eql(u8, ep.method, "GET") and mem.eql(u8, ep.path, "/pets")) {
            found_get_pets = true;
            try std.testing.expectEqualStrings("List all pets", ep.summary.?);
            try std.testing.expect(ep.parameters.items.len >= 1);
        }
        if (mem.eql(u8, ep.method, "POST") and mem.eql(u8, ep.path, "/pets")) {
            found_post_pets = true;
            try std.testing.expect(ep.request_body != null);
            try std.testing.expectEqualStrings("application/json", ep.request_body.?.content_type);
        }
    }
    try std.testing.expect(found_get_pets);
    try std.testing.expect(found_post_pets);
}

test "parseOpenAPISpec returns null for invalid json" {
    const result = parseOpenAPISpec(std.testing.allocator, "not valid json");
    try std.testing.expect(result == null);
}

test "generateVoltFiles creates files for each endpoint" {
    var spec = parseOpenAPISpec(std.testing.allocator, sample_spec) orelse {
        return error.TestUnexpectedResult;
    };
    defer spec.deinit();

    var files = generateVoltFiles(std.testing.allocator, &spec);
    defer {
        for (files.items) |f| {
            std.testing.allocator.free(f.content);
            // path is either a static string or allocated
            if (!mem.eql(u8, f.path, "_collection.volt") and !mem.eql(u8, f.path, "_env.volt")) {
                std.testing.allocator.free(f.path);
            }
        }
        files.deinit();
    }

    // Should have _collection.volt + _env.volt + at least 2 endpoint files
    try std.testing.expect(files.items.len >= 4);

    // Check _collection.volt exists
    var found_collection = false;
    var found_env = false;
    for (files.items) |f| {
        if (mem.eql(u8, f.path, "_collection.volt")) {
            found_collection = true;
            try std.testing.expect(mem.indexOf(u8, f.content, "Pet Store API") != null);
            try std.testing.expect(mem.indexOf(u8, f.content, "BASE_URL") != null);
        }
        if (mem.eql(u8, f.path, "_env.volt")) {
            found_env = true;
            try std.testing.expect(mem.indexOf(u8, f.content, "base_url=") != null);
        }
    }
    try std.testing.expect(found_collection);
    try std.testing.expect(found_env);
}

test "validateResponseAgainstSpec with matching status" {
    var endpoint = Endpoint.init(std.testing.allocator);
    defer endpoint.deinit();
    endpoint.path = "/pets";
    endpoint.method = "GET";
    try endpoint.responses.append(.{
        .status_code = 200,
        .description = "Success",
        .content_type = "application/json",
    });

    var errors = validateResponseAgainstSpec(
        std.testing.allocator,
        &endpoint,
        200,
        "application/json",
        "{}",
    );
    defer errors.deinit();

    try std.testing.expectEqual(@as(usize, 0), errors.items.len);
}

test "validateResponseAgainstSpec with wrong status code" {
    var endpoint = Endpoint.init(std.testing.allocator);
    defer endpoint.deinit();
    endpoint.path = "/pets";
    endpoint.method = "GET";
    try endpoint.responses.append(.{
        .status_code = 200,
        .description = "Success",
        .content_type = null,
    });

    var errors = validateResponseAgainstSpec(
        std.testing.allocator,
        &endpoint,
        500,
        null,
        "{}",
    );
    defer errors.deinit();

    try std.testing.expect(errors.items.len > 0);
    try std.testing.expectEqualStrings("status_code", errors.items[0].field);
    try std.testing.expectEqual(ValidationSeverity.error_sev, errors.items[0].severity);
}

test "validateResponseAgainstSpec with wrong content type" {
    var endpoint = Endpoint.init(std.testing.allocator);
    defer endpoint.deinit();
    endpoint.path = "/pets";
    endpoint.method = "GET";
    try endpoint.responses.append(.{
        .status_code = 200,
        .description = "Success",
        .content_type = "application/json",
    });

    var errors = validateResponseAgainstSpec(
        std.testing.allocator,
        &endpoint,
        200,
        "text/html",
        "{}",
    );
    defer errors.deinit();

    try std.testing.expect(errors.items.len > 0);
    try std.testing.expectEqualStrings("content_type", errors.items[0].field);
}

test "formatSpecSummary produces readable output" {
    var spec = parseOpenAPISpec(std.testing.allocator, sample_spec) orelse {
        return error.TestUnexpectedResult;
    };
    defer spec.deinit();

    const summary = formatSpecSummary(std.testing.allocator, &spec);
    defer std.testing.allocator.free(summary);

    try std.testing.expect(mem.indexOf(u8, summary, "Pet Store API") != null);
    try std.testing.expect(mem.indexOf(u8, summary, "1.0.0") != null);
    try std.testing.expect(mem.indexOf(u8, summary, "Endpoints") != null);
    try std.testing.expect(mem.indexOf(u8, summary, "/pets") != null);
}

test "buildFilename generates correct names" {
    const name1 = try buildFilename(std.testing.allocator, "GET", "/pets");
    defer std.testing.allocator.free(name1);
    try std.testing.expectEqualStrings("get-pets.volt", name1);

    const name2 = try buildFilename(std.testing.allocator, "POST", "/pets/{petId}/toys");
    defer std.testing.allocator.free(name2);
    try std.testing.expectEqualStrings("post-pets-petId-toys.volt", name2);
}

test "extractBaseContentType strips parameters" {
    try std.testing.expectEqualStrings("application/json", extractBaseContentType("application/json; charset=utf-8"));
    try std.testing.expectEqualStrings("text/html", extractBaseContentType("text/html"));
}
