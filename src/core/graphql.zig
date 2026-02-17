const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const HttpClient = @import("http_client.zig");
const VoltFile = @import("volt_file.zig");

// ── GraphQL Support ─────────────────────────────────────────────────────

pub const GraphQLRequest = struct {
    allocator: Allocator,
    endpoint: []const u8,
    query: []const u8,
    query_owned: bool = false,
    raw_body: ?[]const u8 = null,
    raw_body_owned: bool = false,
    variables: ?[]const u8 = null,
    operation_name: ?[]const u8 = null,
    headers: std.ArrayList(VoltFile.Header),

    pub fn init(allocator: Allocator, endpoint: []const u8) GraphQLRequest {
        return .{
            .allocator = allocator,
            .endpoint = endpoint,
            .query = "",
            .headers = std.ArrayList(VoltFile.Header).init(allocator),
        };
    }

    pub fn deinit(self: *GraphQLRequest) void {
        if (self.query_owned) {
            self.allocator.free(self.query);
        }
        if (self.raw_body_owned) {
            if (self.raw_body) |rb| self.allocator.free(rb);
        }
        self.headers.deinit();
    }
};

pub const GraphQLError = struct {
    message: []const u8,
    path: ?[]const u8 = null,
};

pub const GraphQLResponse = struct {
    http_response: HttpClient.Response,
    data: ?[]const u8 = null,
    errors: std.ArrayList(GraphQLError),
    has_errors: bool = false,

    pub fn init(allocator: Allocator) GraphQLResponse {
        return .{
            .http_response = HttpClient.Response.init(allocator),
            .errors = std.ArrayList(GraphQLError).init(allocator),
        };
    }

    pub fn deinit(self: *GraphQLResponse) void {
        self.http_response.deinit();
        self.errors.deinit();
    }
};

/// Build the JSON body for a GraphQL request
pub fn buildRequestBody(allocator: Allocator, gql_req: *const GraphQLRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"query\":");
    try writeJsonString(writer, gql_req.query);

    if (gql_req.variables) |vars| {
        try writer.writeAll(",\"variables\":");
        try writer.writeAll(vars);
    }

    if (gql_req.operation_name) |op| {
        try writer.writeAll(",\"operationName\":");
        try writeJsonString(writer, op);
    }

    try writer.writeAll("}");
    return buf.toOwnedSlice();
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

/// Execute a GraphQL request
pub fn execute(
    allocator: Allocator,
    gql_req: *const GraphQLRequest,
    config: HttpClient.ClientConfig,
) !GraphQLResponse {
    var gql_resp = GraphQLResponse.init(allocator);
    errdefer gql_resp.deinit();

    // Build the HTTP request
    var http_req = VoltFile.VoltRequest.init(allocator);
    defer http_req.deinit();

    http_req.method = .POST;
    http_req.url = gql_req.endpoint;

    // Add Content-Type header
    try http_req.addHeader("Content-Type", "application/json");
    try http_req.addHeader("Accept", "application/json");

    // Copy additional headers
    for (gql_req.headers.items) |h| {
        try http_req.addHeader(h.name, h.value);
    }

    // Build request body (use raw_body if already JSON-wrapped)
    var body_allocated = false;
    if (gql_req.raw_body) |rb| {
        http_req.body = rb;
    } else {
        const body = try buildRequestBody(allocator, gql_req);
        http_req.body = body;
        body_allocated = true;
    }
    http_req.body_type = .json;

    // Execute
    gql_resp.http_response = try HttpClient.execute(allocator, &http_req, config);
    if (body_allocated) {
        if (http_req.body) |b| allocator.free(b);
    }

    // Parse response for errors
    const resp_body = gql_resp.http_response.bodySlice();
    if (resp_body.len > 0) {
        // Simple check for "errors" key in response
        if (mem.indexOf(u8, resp_body, "\"errors\"")) |_| {
            gql_resp.has_errors = true;
        }
        if (mem.indexOf(u8, resp_body, "\"data\"")) |_| {
            gql_resp.data = resp_body;
        }
    }

    return gql_resp;
}

/// Build an introspection query
pub fn introspectionQuery() []const u8 {
    return
        \\{
        \\  __schema {
        \\    types {
        \\      name
        \\      kind
        \\      description
        \\      fields {
        \\        name
        \\        type {
        \\          name
        \\          kind
        \\          ofType {
        \\            name
        \\            kind
        \\          }
        \\        }
        \\      }
        \\    }
        \\    queryType { name }
        \\    mutationType { name }
        \\    subscriptionType { name }
        \\  }
        \\}
    ;
}

/// Parse a .volt file with GraphQL-specific fields
pub fn parseGraphQLVolt(allocator: Allocator, content: []const u8) !GraphQLRequest {
    var volt_req = VoltFile.parse(allocator, content) catch return error.InvalidFormat;
    defer volt_req.deinit();

    var gql_req = GraphQLRequest.init(allocator, volt_req.url);

    // Copy headers
    for (volt_req.headers.items) |h| {
        try gql_req.headers.append(h);
    }

    // The body contains the GraphQL query (dupe to survive volt_req deinit)
    if (volt_req.body) |body| {
        const trimmed_body = mem.trim(u8, body, " \t\n\r");
        // Detect if body is already a JSON-wrapped query (e.g. {"query":"..."})
        if (mem.startsWith(u8, trimmed_body, "{") and mem.indexOf(u8, trimmed_body, "\"query\"") != null) {
            // Body is pre-wrapped JSON — use it directly, skip buildRequestBody
            gql_req.raw_body = try allocator.dupe(u8, trimmed_body);
            gql_req.raw_body_owned = true;
        } else {
            // Raw GraphQL query — will be wrapped by buildRequestBody
            gql_req.query = try allocator.dupe(u8, trimmed_body);
            gql_req.query_owned = true;
        }
    }

    // Check variables section for graphql_variables
    if (volt_req.variables.get("graphql_variables")) |vars| {
        gql_req.variables = vars;
    }
    if (volt_req.variables.get("operation_name")) |op| {
        gql_req.operation_name = op;
    }

    return gql_req;
}

/// Format GraphQL response for display
pub fn formatResponse(gql_resp: *const GraphQLResponse, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    const resp = &gql_resp.http_response;

    try writer.print("HTTP {d} {s}\n", .{ resp.status_code, HttpClient.httpStatusText(resp.status_code) });
    try writer.print("Time: {d:.1}ms | Size: {d} bytes\n", .{ resp.timing.total_ms, resp.size_bytes });

    if (gql_resp.has_errors) {
        try writer.writeAll("\x1b[31mGraphQL errors detected in response\x1b[0m\n");
    }

    try writer.writeAll("\n");
    try writer.writeAll(resp.bodySlice());
    try writer.writeAll("\n");

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "build graphql request body" {
    var gql_req = GraphQLRequest.init(std.testing.allocator, "https://api.example.com/graphql");
    defer gql_req.deinit();
    gql_req.query = "{ users { id name } }";

    const body = try buildRequestBody(std.testing.allocator, &gql_req);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.indexOf(u8, body, "\"query\"") != null);
    try std.testing.expect(mem.indexOf(u8, body, "users") != null);
}

test "build graphql request body with variables" {
    var gql_req = GraphQLRequest.init(std.testing.allocator, "https://api.example.com/graphql");
    defer gql_req.deinit();
    gql_req.query = "query($id: ID!) { user(id: $id) { name } }";
    gql_req.variables = "{\"id\": \"123\"}";
    gql_req.operation_name = "GetUser";

    const body = try buildRequestBody(std.testing.allocator, &gql_req);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.indexOf(u8, body, "\"variables\"") != null);
    try std.testing.expect(mem.indexOf(u8, body, "\"operationName\"") != null);
}

test "introspection query is valid" {
    const query = introspectionQuery();
    try std.testing.expect(mem.indexOf(u8, query, "__schema") != null);
}

// ── Schema Introspection Types ──────────────────────────────────────────

pub const SchemaField = struct {
    name: []const u8,
    type_name: []const u8,
    type_kind: []const u8,
};

pub const SchemaType = struct {
    name: []const u8,
    kind: []const u8,
    description: ?[]const u8,
    fields: std.ArrayList(SchemaField),

    pub fn init(allocator: Allocator) SchemaType {
        return .{
            .name = "",
            .kind = "",
            .description = null,
            .fields = std.ArrayList(SchemaField).init(allocator),
        };
    }

    pub fn deinit(self: *SchemaType) void {
        self.fields.deinit();
    }
};

pub const GraphQLSchema = struct {
    types: std.ArrayList(SchemaType),
    query_type: ?[]const u8,
    mutation_type: ?[]const u8,
    subscription_type: ?[]const u8,

    pub fn init(allocator: Allocator) GraphQLSchema {
        return .{
            .types = std.ArrayList(SchemaType).init(allocator),
            .query_type = null,
            .mutation_type = null,
            .subscription_type = null,
        };
    }

    pub fn deinit(self: *GraphQLSchema) void {
        for (self.types.items) |*t| {
            t.deinit();
        }
        self.types.deinit();
    }
};

/// Parse an introspection result JSON body into a GraphQLSchema struct.
/// Navigates into data.__schema.types array and extracts name/kind/fields.
pub fn parseIntrospectionResult(allocator: Allocator, json_body: []const u8) ?GraphQLSchema {
    var schema = GraphQLSchema.init(allocator);

    // Parse root-level named types from the __schema
    schema.query_type = extractRootTypeName(json_body, "\"queryType\"");
    schema.mutation_type = extractRootTypeName(json_body, "\"mutationType\"");
    schema.subscription_type = extractRootTypeName(json_body, "\"subscriptionType\"");

    // Find "types" array start
    const types_key = "\"types\"";
    const types_pos = mem.indexOf(u8, json_body, types_key) orelse return null;
    const after_key = types_pos + types_key.len;

    // Find opening bracket of array
    var pos = after_key;
    while (pos < json_body.len and json_body[pos] != '[') : (pos += 1) {}
    if (pos >= json_body.len) return null;
    pos += 1; // skip '['

    // Parse each type object in the array
    while (pos < json_body.len) {
        // Skip whitespace/commas
        while (pos < json_body.len and (json_body[pos] == ' ' or json_body[pos] == '\n' or
            json_body[pos] == '\r' or json_body[pos] == '\t' or json_body[pos] == ','))
        {
            pos += 1;
        }
        if (pos >= json_body.len or json_body[pos] == ']') break;
        if (json_body[pos] != '{') break;

        // Find the matching closing brace for this type object
        const obj_start = pos;
        const obj_end = findMatchingBrace(json_body, pos) orelse break;
        const type_obj = json_body[obj_start .. obj_end + 1];

        var schema_type = SchemaType.init(allocator);
        schema_type.name = extractJsonStringValue(type_obj, "\"name\"") orelse "";
        schema_type.kind = extractJsonStringValue(type_obj, "\"kind\"") orelse "";
        schema_type.description = extractJsonStringValue(type_obj, "\"description\"");

        // Parse fields if present
        if (mem.indexOf(u8, type_obj, "\"fields\"")) |fields_key_pos| {
            var fp = fields_key_pos + "\"fields\"".len;
            // Skip to array start or "null"
            while (fp < type_obj.len and type_obj[fp] == ' ') : (fp += 1) {}
            if (fp < type_obj.len and type_obj[fp] == ':') fp += 1;
            while (fp < type_obj.len and (type_obj[fp] == ' ' or type_obj[fp] == '\n' or
                type_obj[fp] == '\r' or type_obj[fp] == '\t'))
            {
                fp += 1;
            }

            if (fp < type_obj.len and type_obj[fp] == '[') {
                fp += 1; // skip '['
                // Parse each field object
                while (fp < type_obj.len) {
                    while (fp < type_obj.len and (type_obj[fp] == ' ' or type_obj[fp] == '\n' or
                        type_obj[fp] == '\r' or type_obj[fp] == '\t' or type_obj[fp] == ','))
                    {
                        fp += 1;
                    }
                    if (fp >= type_obj.len or type_obj[fp] == ']') break;
                    if (type_obj[fp] != '{') break;

                    const field_start = fp;
                    const field_end = findMatchingBrace(type_obj, fp) orelse break;
                    const field_obj = type_obj[field_start .. field_end + 1];

                    const field_name = extractJsonStringValue(field_obj, "\"name\"") orelse "";

                    // Extract type info from nested "type" object
                    var field_type_name: []const u8 = "";
                    var field_type_kind: []const u8 = "";
                    if (mem.indexOf(u8, field_obj, "\"type\"")) |type_key_p| {
                        var tp = type_key_p + "\"type\"".len;
                        while (tp < field_obj.len and field_obj[tp] != '{') : (tp += 1) {}
                        if (tp < field_obj.len) {
                            const nested_end = findMatchingBrace(field_obj, tp) orelse field_obj.len - 1;
                            const type_inner = field_obj[tp .. nested_end + 1];
                            field_type_name = extractJsonStringValue(type_inner, "\"name\"") orelse "";
                            field_type_kind = extractJsonStringValue(type_inner, "\"kind\"") orelse "";
                        }
                    }

                    schema_type.fields.append(.{
                        .name = field_name,
                        .type_name = field_type_name,
                        .type_kind = field_type_kind,
                    }) catch return null;

                    fp = field_end + 1;
                }
            }
        }

        schema.types.append(schema_type) catch return null;
        pos = obj_end + 1;
    }

    return schema;
}

/// Find matching closing brace for an opening brace at `start`.
fn findMatchingBrace(data: []const u8, start: usize) ?usize {
    if (start >= data.len or data[start] != '{') return null;
    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var i = start;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (c == '\\' and in_string) {
            escape = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Extract the string value for a given JSON key.
fn extractJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = mem.indexOf(u8, json, key) orelse return null;
    var pos = key_pos + key.len;
    // Skip `: `
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}
    if (pos >= json.len) return null;
    if (json[pos] == 'n') {
        // null value
        return null;
    }
    if (json[pos] != '"') return null;
    pos += 1; // skip opening quote
    const val_start = pos;
    while (pos < json.len and json[pos] != '"') : (pos += 1) {
        if (json[pos] == '\\') pos += 1; // skip escaped char
    }
    if (pos >= json.len) return null;
    return json[val_start..pos];
}

/// Extract root type name from a section like `"queryType": { "name": "Query" }` or `"queryType": null`
fn extractRootTypeName(json: []const u8, key: []const u8) ?[]const u8 {
    const key_pos = mem.indexOf(u8, json, key) orelse return null;
    var pos = key_pos + key.len;
    // skip `: `
    while (pos < json.len and (json[pos] == ':' or json[pos] == ' ' or json[pos] == '\t')) : (pos += 1) {}
    if (pos >= json.len) return null;
    if (json[pos] == 'n') return null; // null
    if (json[pos] == '{') {
        const obj_end = findMatchingBrace(json, pos) orelse return null;
        const obj_slice = json[pos .. obj_end + 1];
        return extractJsonStringValue(obj_slice, "\"name\"");
    }
    return null;
}

/// Format a GraphQLSchema for terminal display with ANSI colors.
/// Groups by kind, skips built-in types (those starting with "__").
pub fn formatSchema(allocator: Allocator, schema: *const GraphQLSchema) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    const ansi_reset = "\x1b[0m";
    const ansi_bold = "\x1b[1m";
    const ansi_cyan = "\x1b[36m";
    const ansi_green = "\x1b[32m";
    const ansi_yellow = "\x1b[33m";
    const ansi_magenta = "\x1b[35m";
    const ansi_dim = "\x1b[2m";

    // Display root types
    try writer.print("{s}{s}Schema Root Types{s}\n", .{ ansi_bold, ansi_cyan, ansi_reset });
    if (schema.query_type) |qt| {
        try writer.print("  Query:        {s}\n", .{qt});
    }
    if (schema.mutation_type) |mt| {
        try writer.print("  Mutation:     {s}\n", .{mt});
    }
    if (schema.subscription_type) |st| {
        try writer.print("  Subscription: {s}\n", .{st});
    }
    try writer.writeAll("\n");

    const kind_order = [_][]const u8{ "OBJECT", "ENUM", "INPUT_OBJECT", "SCALAR" };
    const kind_colors = [_][]const u8{ ansi_green, ansi_yellow, ansi_magenta, ansi_dim };

    for (kind_order, 0..) |kind, ki| {
        var has_kind = false;
        for (schema.types.items) |t| {
            if (mem.eql(u8, t.kind, kind) and !mem.startsWith(u8, t.name, "__")) {
                if (!has_kind) {
                    try writer.print("{s}{s}── {s} ──{s}\n", .{ ansi_bold, kind_colors[ki], kind, ansi_reset });
                    has_kind = true;
                }
                try writer.print("  {s}{s}{s}{s}", .{ ansi_bold, kind_colors[ki], t.name, ansi_reset });
                if (t.description) |desc| {
                    try writer.print(" {s}({s}){s}", .{ ansi_dim, desc, ansi_reset });
                }
                try writer.writeAll("\n");
                for (t.fields.items) |f| {
                    try writer.print("    {s}: {s}{s}{s}\n", .{ f.name, kind_colors[ki], f.type_name, ansi_reset });
                }
            }
        }
        if (has_kind) {
            try writer.writeAll("\n");
        }
    }

    return buf.toOwnedSlice();
}

/// Find a type by name in the schema.
pub fn findType(schema: *const GraphQLSchema, name: []const u8) ?SchemaType {
    for (schema.types.items) |t| {
        if (mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Basic query validation against a schema.
/// Extracts field names from the query and checks they exist in schema types.
/// Returns a list of validation error messages (empty if valid).
pub fn validateQuery(allocator: Allocator, query: []const u8, schema: *const GraphQLSchema) !std.ArrayList([]const u8) {
    var errors = std.ArrayList([]const u8).init(allocator);

    // Extract field names from query: look for word characters before { or after { that are not keywords
    const keywords = [_][]const u8{ "query", "mutation", "subscription", "fragment", "on", "true", "false", "null" };

    // Collect all known field names from the schema
    var known_fields = std.StringHashMap(void).init(allocator);
    defer known_fields.deinit();

    for (schema.types.items) |t| {
        // Add type names
        if (t.name.len > 0 and !mem.startsWith(u8, t.name, "__")) {
            known_fields.put(t.name, {}) catch {};
        }
        for (t.fields.items) |f| {
            known_fields.put(f.name, {}) catch {};
        }
    }

    // Simple tokenizer: extract identifiers from the query
    var i: usize = 0;
    while (i < query.len) {
        // Skip non-alpha characters
        if (!isIdentChar(query[i]) or (query[i] >= '0' and query[i] <= '9')) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < query.len and isIdentChar(query[i])) : (i += 1) {}
        const token = query[start..i];

        // Skip keywords, type annotations (after : or ()), and variables (after $)
        if (start > 0 and query[start - 1] == '$') continue;
        if (start > 0 and query[start - 1] == ':') continue;

        var is_keyword = false;
        for (keywords) |kw| {
            if (mem.eql(u8, token, kw)) {
                is_keyword = true;
                break;
            }
        }
        if (is_keyword) continue;

        // Check if this identifier is known as a field or type name
        if (!known_fields.contains(token)) {
            const msg = std.fmt.allocPrint(allocator, "Unknown field '{s}' not found in schema", .{token}) catch continue;
            errors.append(msg) catch {};
        }
    }

    return errors;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// ── Introspection Tests ─────────────────────────────────────────────────

test "parseIntrospectionResult basic" {
    const json =
        \\{"data":{"__schema":{"types":[
        \\  {"name":"Query","kind":"OBJECT","description":null,"fields":[
        \\    {"name":"users","type":{"name":"User","kind":"OBJECT","ofType":null}},
        \\    {"name":"posts","type":{"name":"Post","kind":"OBJECT","ofType":null}}
        \\  ]},
        \\  {"name":"User","kind":"OBJECT","description":"A user","fields":[
        \\    {"name":"id","type":{"name":"ID","kind":"SCALAR","ofType":null}},
        \\    {"name":"name","type":{"name":"String","kind":"SCALAR","ofType":null}}
        \\  ]},
        \\  {"name":"__Schema","kind":"OBJECT","description":null,"fields":[]},
        \\  {"name":"String","kind":"SCALAR","description":"Built-in string","fields":null}
        \\],"queryType":{"name":"Query"},"mutationType":null,"subscriptionType":null}}}
    ;

    var schema = parseIntrospectionResult(std.testing.allocator, json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    try std.testing.expectEqualStrings("Query", schema.query_type.?);
    try std.testing.expect(schema.mutation_type == null);
    try std.testing.expect(schema.subscription_type == null);

    // Should have parsed 4 types
    try std.testing.expectEqual(@as(usize, 4), schema.types.items.len);

    // First type is Query with 2 fields
    try std.testing.expectEqualStrings("Query", schema.types.items[0].name);
    try std.testing.expectEqualStrings("OBJECT", schema.types.items[0].kind);
    try std.testing.expectEqual(@as(usize, 2), schema.types.items[0].fields.items.len);
    try std.testing.expectEqualStrings("users", schema.types.items[0].fields.items[0].name);

    // User type with description
    try std.testing.expectEqualStrings("User", schema.types.items[1].name);
    try std.testing.expectEqualStrings("A user", schema.types.items[1].description.?);
}

test "formatSchema skips builtins and groups by kind" {
    const json =
        \\{"data":{"__schema":{"types":[
        \\  {"name":"Query","kind":"OBJECT","description":null,"fields":[
        \\    {"name":"users","type":{"name":"User","kind":"OBJECT","ofType":null}}
        \\  ]},
        \\  {"name":"Status","kind":"ENUM","description":null,"fields":null},
        \\  {"name":"__Schema","kind":"OBJECT","description":null,"fields":[]},
        \\  {"name":"String","kind":"SCALAR","description":null,"fields":null}
        \\],"queryType":{"name":"Query"},"mutationType":null,"subscriptionType":null}}}
    ;

    var schema = parseIntrospectionResult(std.testing.allocator, json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    const output = try formatSchema(std.testing.allocator, &schema);
    defer std.testing.allocator.free(output);

    // Should contain the user-defined types
    try std.testing.expect(mem.indexOf(u8, output, "Query") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Status") != null);
    try std.testing.expect(mem.indexOf(u8, output, "String") != null);
    // Should NOT contain __Schema (built-in)
    try std.testing.expect(mem.indexOf(u8, output, "__Schema") == null);
    // Should contain OBJECT/ENUM/SCALAR section headings
    try std.testing.expect(mem.indexOf(u8, output, "OBJECT") != null);
    try std.testing.expect(mem.indexOf(u8, output, "ENUM") != null);
    try std.testing.expect(mem.indexOf(u8, output, "SCALAR") != null);
}

test "findType returns correct type" {
    const json =
        \\{"data":{"__schema":{"types":[
        \\  {"name":"Query","kind":"OBJECT","description":null,"fields":[]},
        \\  {"name":"User","kind":"OBJECT","description":"A user","fields":[
        \\    {"name":"id","type":{"name":"ID","kind":"SCALAR","ofType":null}}
        \\  ]}
        \\],"queryType":{"name":"Query"},"mutationType":null,"subscriptionType":null}}}
    ;

    var schema = parseIntrospectionResult(std.testing.allocator, json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    const user_type = findType(&schema, "User");
    try std.testing.expect(user_type != null);
    try std.testing.expectEqualStrings("User", user_type.?.name);
    try std.testing.expectEqualStrings("OBJECT", user_type.?.kind);
    try std.testing.expectEqualStrings("A user", user_type.?.description.?);

    const not_found = findType(&schema, "NonExistent");
    try std.testing.expect(not_found == null);
}
