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

    // Parse response for errors — use JSON parsing for accuracy
    const resp_body = gql_resp.http_response.bodySlice();
    if (resp_body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, resp_body, .{}) catch null;
        defer if (parsed) |p| p.deinit();
        if (parsed) |p| {
            if (p.value == .object) {
                if (p.value.object.get("errors")) |errors_val| {
                    // Only flag errors if it's a non-empty array
                    if (errors_val == .array and errors_val.array.items.len > 0) {
                        gql_resp.has_errors = true;
                    }
                }
                if (p.value.object.get("data")) |_| {
                    gql_resp.data = resp_body;
                }
            }
        } else {
            // Fallback to string search if JSON parsing fails
            if (mem.indexOf(u8, resp_body, "\"errors\"")) |_| {
                gql_resp.has_errors = true;
            }
            if (mem.indexOf(u8, resp_body, "\"data\"")) |_| {
                gql_resp.data = resp_body;
            }
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

// ── Field Autocomplete ──────────────────────────────────────────────────

/// Return all field names of the given type that start with `prefix`.
/// For an empty prefix, returns all fields. Returns an empty list if the
/// type is not found.
pub fn getFieldCompletions(schema: *const GraphQLSchema, type_name: []const u8, prefix: []const u8) std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(schema.types.allocator);
    for (schema.types.items) |t| {
        if (mem.eql(u8, t.name, type_name)) {
            for (t.fields.items) |f| {
                if (prefix.len == 0 or mem.startsWith(u8, f.name, prefix)) {
                    results.append(f.name) catch |err| {
                        std.debug.print("warning: graphql: skipping field completion '{s}': {s}\n", .{ f.name, @errorName(err) });
                        continue;
                    };
                }
            }
            break;
        }
    }
    return results;
}

/// Return all non-builtin type names (skip those starting with "__") that
/// start with the given prefix.
pub fn getTypeCompletions(schema: *const GraphQLSchema, prefix: []const u8) std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(schema.types.allocator);
    for (schema.types.items) |t| {
        if (mem.startsWith(u8, t.name, "__")) continue;
        if (t.name.len == 0) continue;
        if (prefix.len == 0 or mem.startsWith(u8, t.name, prefix)) {
            results.append(t.name) catch |err| {
                std.debug.print("warning: graphql: skipping type completion '{s}': {s}\n", .{ t.name, @errorName(err) });
                continue;
            };
        }
    }
    return results;
}

/// Given a type and field name, return the type of that field (for nested
/// autocompletion). Returns null if the type or field is not found.
pub fn resolveFieldType(schema: *const GraphQLSchema, type_name: []const u8, field_name: []const u8) ?[]const u8 {
    for (schema.types.items) |t| {
        if (mem.eql(u8, t.name, type_name)) {
            for (t.fields.items) |f| {
                if (mem.eql(u8, f.name, field_name)) {
                    if (f.type_name.len == 0) return null;
                    return f.type_name;
                }
            }
            return null;
        }
    }
    return null;
}

// ── GraphQL Subscriptions (WebSocket-based, graphql-ws protocol) ────────

pub const SubscriptionMessageType = enum {
    connection_ack,
    next,
    @"error",
    complete,
    unknown,
};

pub const SubscriptionMessage = struct {
    msg_type: SubscriptionMessageType,
    id: ?[]const u8,
    payload: ?[]const u8,
};

pub const GraphQLSubscription = struct {
    endpoint: []const u8,
    query: []const u8,
    variables: ?[]const u8 = null,
    operation_name: ?[]const u8 = null,
    headers: std.ArrayList(VoltFile.Header),
    connected: bool = false,
    message_count: usize = 0,

    pub fn init(allocator: Allocator, endpoint: []const u8, query: []const u8) GraphQLSubscription {
        return .{
            .endpoint = endpoint,
            .query = query,
            .headers = std.ArrayList(VoltFile.Header).init(allocator),
        };
    }

    pub fn deinit(self: *GraphQLSubscription) void {
        self.headers.deinit();
    }
};

/// Build a `connection_init` message per the graphql-ws protocol.
pub fn buildSubscriptionInit(allocator: Allocator, sub: *const GraphQLSubscription) ![]const u8 {
    _ = sub;
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"type\":\"connection_init\",\"payload\":{}}");

    return buf.toOwnedSlice();
}

/// Build a `subscribe` message per the graphql-ws protocol.
pub fn buildSubscriptionStart(allocator: Allocator, sub: *const GraphQLSubscription, id: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"type\":\"subscribe\",\"payload\":{\"query\":");
    try writeJsonString(writer, sub.query);

    if (sub.variables) |vars| {
        try writer.writeAll(",\"variables\":");
        try writer.writeAll(vars);
    } else {
        try writer.writeAll(",\"variables\":{}");
    }

    if (sub.operation_name) |op| {
        try writer.writeAll(",\"operationName\":");
        try writeJsonString(writer, op);
    }

    try writer.writeAll("}}");
    return buf.toOwnedSlice();
}

/// Parse an incoming subscription message from the server.
pub fn parseSubscriptionMessage(content: []const u8) SubscriptionMessage {
    var result = SubscriptionMessage{
        .msg_type = .unknown,
        .id = null,
        .payload = null,
    };

    // Extract "type" value
    if (extractJsonStringValue(content, "\"type\"")) |type_str| {
        if (mem.eql(u8, type_str, "connection_ack")) {
            result.msg_type = .connection_ack;
        } else if (mem.eql(u8, type_str, "next")) {
            result.msg_type = .next;
        } else if (mem.eql(u8, type_str, "error")) {
            result.msg_type = .@"error";
        } else if (mem.eql(u8, type_str, "complete")) {
            result.msg_type = .complete;
        }
    }

    // Extract "id" value
    result.id = extractJsonStringValue(content, "\"id\"");

    // Extract "payload" — find the payload object as a raw slice
    if (mem.indexOf(u8, content, "\"payload\"")) |key_pos| {
        var pos = key_pos + "\"payload\"".len;
        // Skip `: `
        while (pos < content.len and (content[pos] == ':' or content[pos] == ' ' or content[pos] == '\t')) : (pos += 1) {}
        if (pos < content.len and content[pos] == '{') {
            if (findMatchingBrace(content, pos)) |end| {
                result.payload = content[pos .. end + 1];
            }
        }
    }

    return result;
}

/// Build a `complete` (stop) message per the graphql-ws protocol.
pub fn buildSubscriptionStop(allocator: Allocator, id: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\"id\":");
    try writeJsonString(writer, id);
    try writer.writeAll(",\"type\":\"complete\"}");

    return buf.toOwnedSlice();
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
            known_fields.put(t.name, {}) catch |err| {
                std.debug.print("warning: graphql: skipping known type '{s}': {s}\n", .{ t.name, @errorName(err) });
                continue;
            };
        }
        for (t.fields.items) |f| {
            known_fields.put(f.name, {}) catch |err| {
                std.debug.print("warning: graphql: skipping known field '{s}': {s}\n", .{ f.name, @errorName(err) });
                continue;
            };
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
            errors.append(msg) catch |err| {
                std.debug.print("warning: graphql: skipping validation error: {s}\n", .{@errorName(err)});
                continue;
            };
        }
    }

    return errors;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

// ── Schema Caching ──────────────────────────────────────────────────────
//
// Caches introspection results to .volt-cache/ for offline validation
// and autocomplete. Cache files include a TTL timestamp.

pub const SchemaCache = struct {
    cache_dir: []const u8,
    ttl_seconds: i64,

    pub const default_cache_dir = ".volt-cache";
    pub const default_ttl: i64 = 3600; // 1 hour

    pub fn init() SchemaCache {
        return .{
            .cache_dir = default_cache_dir,
            .ttl_seconds = default_ttl,
        };
    }

    pub fn initCustom(cache_dir: []const u8, ttl_seconds: i64) SchemaCache {
        return .{
            .cache_dir = cache_dir,
            .ttl_seconds = ttl_seconds,
        };
    }

    /// Build the cache file path for a given endpoint.
    /// Hashes the endpoint URL to produce a deterministic filename.
    pub fn cacheFilePath(self: *const SchemaCache, allocator: Allocator, endpoint: []const u8) ![]const u8 {
        // Simple hash of endpoint URL for the filename
        var hash: u32 = 0;
        for (endpoint) |c| {
            hash = hash *% 31 +% @as(u32, c);
        }
        return std.fmt.allocPrint(allocator, "{s}/schema-{x:0>8}.json", .{ self.cache_dir, hash });
    }

    /// Cache a schema introspection result to disk.
    /// Writes both the raw JSON and a metadata file with the timestamp.
    pub fn cacheSchema(self: *const SchemaCache, allocator: Allocator, endpoint: []const u8, json_body: []const u8) !void {
        // Ensure cache directory exists
        std.fs.cwd().makePath(self.cache_dir) catch |err| {
            std.debug.print("warning: graphql: failed to create cache directory '{s}': {s}\n", .{ self.cache_dir, @errorName(err) });
        };

        const file_path = try self.cacheFilePath(allocator, endpoint);
        defer allocator.free(file_path);

        // Write schema JSON
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(json_body);

        // Write metadata (timestamp)
        const meta_path = try std.fmt.allocPrint(allocator, "{s}.meta", .{file_path});
        defer allocator.free(meta_path);

        const meta_file = try std.fs.cwd().createFile(meta_path, .{});
        defer meta_file.close();

        var ts_buf: [32]u8 = undefined;
        const ts_str = std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.timestamp()}) catch return;
        try meta_file.writeAll(ts_str);
    }

    /// Load a cached schema from disk.
    /// Returns null if the cache doesn't exist or has expired.
    pub fn loadCachedSchema(self: *const SchemaCache, allocator: Allocator, endpoint: []const u8) ?GraphQLSchema {
        const file_path = self.cacheFilePath(allocator, endpoint) catch return null;
        defer allocator.free(file_path);

        // Check if cache is still valid
        if (!self.isCacheValid(allocator, file_path)) return null;

        // Read cached JSON
        const file = std.fs.cwd().openFile(file_path, .{}) catch return null;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return null;
        defer allocator.free(content);

        return parseIntrospectionResult(allocator, content);
    }

    /// Check if a cache file is still within TTL.
    pub fn isCacheValid(self: *const SchemaCache, allocator: Allocator, file_path: []const u8) bool {
        const meta_path = std.fmt.allocPrint(allocator, "{s}.meta", .{file_path}) catch return false;
        defer allocator.free(meta_path);

        const meta_file = std.fs.cwd().openFile(meta_path, .{}) catch return false;
        defer meta_file.close();

        var meta_buf: [32]u8 = undefined;
        const bytes_read = meta_file.readAll(&meta_buf) catch return false;
        const ts_str = meta_buf[0..bytes_read];

        const cached_time = std.fmt.parseInt(i64, ts_str, 10) catch return false;
        const now = std.time.timestamp();

        return (now - cached_time) < self.ttl_seconds;
    }

    /// Invalidate (delete) cached schema for an endpoint.
    pub fn invalidate(self: *const SchemaCache, allocator: Allocator, endpoint: []const u8) void {
        const file_path = self.cacheFilePath(allocator, endpoint) catch return;
        defer allocator.free(file_path);

        std.fs.cwd().deleteFile(file_path) catch |err| {
            std.debug.print("warning: graphql: failed to delete cached schema: {s}\n", .{@errorName(err)});
        };

        const meta_path = std.fmt.allocPrint(allocator, "{s}.meta", .{file_path}) catch return;
        defer allocator.free(meta_path);
        std.fs.cwd().deleteFile(meta_path) catch |err| {
            std.debug.print("warning: graphql: failed to delete cache metadata: {s}\n", .{@errorName(err)});
        };
    }
};

/// Execute a GraphQL introspection query with schema caching.
/// First checks the cache; if expired or missing, runs introspection and caches the result.
pub fn introspectWithCache(
    allocator: Allocator,
    endpoint: []const u8,
    headers: []const VoltFile.Header,
    cache: *const SchemaCache,
    config: HttpClient.ClientConfig,
) !GraphQLSchema {
    // Try cache first
    if (cache.loadCachedSchema(allocator, endpoint)) |schema| {
        return schema;
    }

    // Cache miss — run introspection
    var gql_req = GraphQLRequest.init(allocator, endpoint);
    defer gql_req.deinit();
    gql_req.query = introspectionQuery();

    for (headers) |h| {
        try gql_req.headers.append(h);
    }

    var gql_resp = try execute(allocator, &gql_req, config);
    defer gql_resp.deinit();

    const body = gql_resp.http_response.bodySlice();
    if (body.len == 0) return error.EmptyResponse;

    // Cache the result
    cache.cacheSchema(allocator, endpoint, body) catch |err| {
        std.debug.print("warning: graphql: failed to cache schema for '{s}': {s}\n", .{ endpoint, @errorName(err) });
    };

    return parseIntrospectionResult(allocator, body) orelse return error.InvalidSchema;
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

test "schema cache file path generation" {
    const cache = SchemaCache.init();
    const path = try cache.cacheFilePath(std.testing.allocator, "https://api.example.com/graphql");
    defer std.testing.allocator.free(path);

    try std.testing.expect(mem.startsWith(u8, path, ".volt-cache/schema-"));
    try std.testing.expect(mem.endsWith(u8, path, ".json"));
}

test "schema cache file path is deterministic" {
    const cache = SchemaCache.init();

    const path1 = try cache.cacheFilePath(std.testing.allocator, "https://api.example.com/graphql");
    defer std.testing.allocator.free(path1);

    const path2 = try cache.cacheFilePath(std.testing.allocator, "https://api.example.com/graphql");
    defer std.testing.allocator.free(path2);

    try std.testing.expectEqualStrings(path1, path2);
}

test "schema cache different endpoints get different paths" {
    const cache = SchemaCache.init();

    const path1 = try cache.cacheFilePath(std.testing.allocator, "https://api.example.com/graphql");
    defer std.testing.allocator.free(path1);

    const path2 = try cache.cacheFilePath(std.testing.allocator, "https://other.example.com/graphql");
    defer std.testing.allocator.free(path2);

    try std.testing.expect(!mem.eql(u8, path1, path2));
}

test "schema cache custom config" {
    const cache = SchemaCache.initCustom("/tmp/volt-cache", 7200);

    try std.testing.expectEqualStrings("/tmp/volt-cache", cache.cache_dir);
    try std.testing.expectEqual(@as(i64, 7200), cache.ttl_seconds);
}

test "schema cache default config" {
    const cache = SchemaCache.init();

    try std.testing.expectEqualStrings(".volt-cache", cache.cache_dir);
    try std.testing.expectEqual(@as(i64, 3600), cache.ttl_seconds);
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

// ── Field Autocomplete Tests ────────────────────────────────────────────

const test_schema_json =
    \\{"data":{"__schema":{"types":[
    \\  {"name":"Query","kind":"OBJECT","description":null,"fields":[
    \\    {"name":"users","type":{"name":"User","kind":"OBJECT","ofType":null}},
    \\    {"name":"user","type":{"name":"User","kind":"OBJECT","ofType":null}},
    \\    {"name":"posts","type":{"name":"Post","kind":"OBJECT","ofType":null}}
    \\  ]},
    \\  {"name":"User","kind":"OBJECT","description":"A user","fields":[
    \\    {"name":"id","type":{"name":"ID","kind":"SCALAR","ofType":null}},
    \\    {"name":"name","type":{"name":"String","kind":"SCALAR","ofType":null}},
    \\    {"name":"email","type":{"name":"String","kind":"SCALAR","ofType":null}}
    \\  ]},
    \\  {"name":"Post","kind":"OBJECT","description":null,"fields":[
    \\    {"name":"id","type":{"name":"ID","kind":"SCALAR","ofType":null}},
    \\    {"name":"title","type":{"name":"String","kind":"SCALAR","ofType":null}},
    \\    {"name":"author","type":{"name":"User","kind":"OBJECT","ofType":null}}
    \\  ]},
    \\  {"name":"__Schema","kind":"OBJECT","description":null,"fields":[]},
    \\  {"name":"__Type","kind":"OBJECT","description":null,"fields":[]},
    \\  {"name":"String","kind":"SCALAR","description":null,"fields":null},
    \\  {"name":"ID","kind":"SCALAR","description":null,"fields":null}
    \\],"queryType":{"name":"Query"},"mutationType":null,"subscriptionType":null}}}
;

test "getFieldCompletions returns all fields for empty prefix" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    var completions = getFieldCompletions(&schema, "Query", "");
    defer completions.deinit();

    try std.testing.expectEqual(@as(usize, 3), completions.items.len);
    try std.testing.expectEqualStrings("users", completions.items[0]);
    try std.testing.expectEqualStrings("user", completions.items[1]);
    try std.testing.expectEqualStrings("posts", completions.items[2]);
}

test "getFieldCompletions filters by prefix" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    var completions = getFieldCompletions(&schema, "Query", "user");
    defer completions.deinit();

    try std.testing.expectEqual(@as(usize, 2), completions.items.len);
    try std.testing.expectEqualStrings("users", completions.items[0]);
    try std.testing.expectEqualStrings("user", completions.items[1]);
}

test "getFieldCompletions returns empty for unknown type" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    var completions = getFieldCompletions(&schema, "NonExistent", "");
    defer completions.deinit();

    try std.testing.expectEqual(@as(usize, 0), completions.items.len);
}

test "getFieldCompletions returns empty for no matching prefix" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    var completions = getFieldCompletions(&schema, "User", "zzz");
    defer completions.deinit();

    try std.testing.expectEqual(@as(usize, 0), completions.items.len);
}

test "getTypeCompletions returns non-builtin types" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    var completions = getTypeCompletions(&schema, "");
    defer completions.deinit();

    // Should skip __Schema and __Type, include Query, User, Post, String, ID
    try std.testing.expectEqual(@as(usize, 5), completions.items.len);

    // Verify builtins are excluded
    for (completions.items) |name| {
        try std.testing.expect(!mem.startsWith(u8, name, "__"));
    }
}

test "getTypeCompletions filters by prefix" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    var completions = getTypeCompletions(&schema, "U");
    defer completions.deinit();

    try std.testing.expectEqual(@as(usize, 1), completions.items.len);
    try std.testing.expectEqualStrings("User", completions.items[0]);
}

test "getTypeCompletions skips builtins even with __ prefix" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    var completions = getTypeCompletions(&schema, "__");
    defer completions.deinit();

    try std.testing.expectEqual(@as(usize, 0), completions.items.len);
}

test "resolveFieldType returns correct type" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    // Query.users -> User
    const users_type = resolveFieldType(&schema, "Query", "users");
    try std.testing.expect(users_type != null);
    try std.testing.expectEqualStrings("User", users_type.?);

    // Post.author -> User
    const author_type = resolveFieldType(&schema, "Post", "author");
    try std.testing.expect(author_type != null);
    try std.testing.expectEqualStrings("User", author_type.?);

    // User.name -> String
    const name_type = resolveFieldType(&schema, "User", "name");
    try std.testing.expect(name_type != null);
    try std.testing.expectEqualStrings("String", name_type.?);
}

test "resolveFieldType returns null for unknown type" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    const result = resolveFieldType(&schema, "NonExistent", "id");
    try std.testing.expect(result == null);
}

test "resolveFieldType returns null for unknown field" {
    var schema = parseIntrospectionResult(std.testing.allocator, test_schema_json) orelse {
        return error.TestUnexpectedResult;
    };
    defer schema.deinit();

    const result = resolveFieldType(&schema, "User", "nonexistent");
    try std.testing.expect(result == null);
}

// ── Subscription Tests ──────────────────────────────────────────────────

test "buildSubscriptionInit produces connection_init message" {
    var sub = GraphQLSubscription.init(std.testing.allocator, "ws://localhost:4000/graphql", "subscription { messageAdded { id text } }");
    defer sub.deinit();

    const msg = try buildSubscriptionInit(std.testing.allocator, &sub);
    defer std.testing.allocator.free(msg);

    try std.testing.expectEqualStrings("{\"type\":\"connection_init\",\"payload\":{}}", msg);
}

test "buildSubscriptionStart produces subscribe message" {
    var sub = GraphQLSubscription.init(std.testing.allocator, "ws://localhost:4000/graphql", "subscription { messageAdded { id text } }");
    defer sub.deinit();

    const msg = try buildSubscriptionStart(std.testing.allocator, &sub, "sub-1");
    defer std.testing.allocator.free(msg);

    try std.testing.expect(mem.indexOf(u8, msg, "\"id\":\"sub-1\"") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "\"type\":\"subscribe\"") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "\"query\":\"subscription") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "\"variables\":{}") != null);
}

test "buildSubscriptionStart with variables and operation_name" {
    var sub = GraphQLSubscription.init(std.testing.allocator, "ws://localhost:4000/graphql", "subscription OnMsg($ch: String!) { messageAdded(channel: $ch) { id } }");
    defer sub.deinit();
    sub.variables = "{\"ch\":\"general\"}";
    sub.operation_name = "OnMsg";

    const msg = try buildSubscriptionStart(std.testing.allocator, &sub, "sub-2");
    defer std.testing.allocator.free(msg);

    try std.testing.expect(mem.indexOf(u8, msg, "\"id\":\"sub-2\"") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "\"variables\":{\"ch\":\"general\"}") != null);
    try std.testing.expect(mem.indexOf(u8, msg, "\"operationName\":\"OnMsg\"") != null);
}

test "parseSubscriptionMessage connection_ack" {
    const input = "{\"type\":\"connection_ack\"}";
    const result = parseSubscriptionMessage(input);

    try std.testing.expect(result.msg_type == .connection_ack);
    try std.testing.expect(result.id == null);
    try std.testing.expect(result.payload == null);
}

test "parseSubscriptionMessage next with payload" {
    const input = "{\"id\":\"sub-1\",\"type\":\"next\",\"payload\":{\"data\":{\"messageAdded\":{\"id\":\"1\",\"text\":\"hello\"}}}}";
    const result = parseSubscriptionMessage(input);

    try std.testing.expect(result.msg_type == .next);
    try std.testing.expect(result.id != null);
    try std.testing.expectEqualStrings("sub-1", result.id.?);
    try std.testing.expect(result.payload != null);
    try std.testing.expect(mem.indexOf(u8, result.payload.?, "messageAdded") != null);
}

test "parseSubscriptionMessage error" {
    const input = "{\"id\":\"sub-1\",\"type\":\"error\",\"payload\":{\"message\":\"something went wrong\"}}";
    const result = parseSubscriptionMessage(input);

    try std.testing.expect(result.msg_type == .@"error");
    try std.testing.expect(result.id != null);
    try std.testing.expectEqualStrings("sub-1", result.id.?);
    try std.testing.expect(result.payload != null);
}

test "parseSubscriptionMessage complete" {
    const input = "{\"id\":\"sub-1\",\"type\":\"complete\"}";
    const result = parseSubscriptionMessage(input);

    try std.testing.expect(result.msg_type == .complete);
    try std.testing.expect(result.id != null);
    try std.testing.expectEqualStrings("sub-1", result.id.?);
}

test "parseSubscriptionMessage unknown type" {
    const input = "{\"type\":\"ka\"}";
    const result = parseSubscriptionMessage(input);

    try std.testing.expect(result.msg_type == .unknown);
}

test "buildSubscriptionStop produces complete message" {
    const msg = try buildSubscriptionStop(std.testing.allocator, "sub-1");
    defer std.testing.allocator.free(msg);

    try std.testing.expectEqualStrings("{\"id\":\"sub-1\",\"type\":\"complete\"}", msg);
}

test "GraphQLSubscription init defaults" {
    var sub = GraphQLSubscription.init(std.testing.allocator, "ws://localhost/graphql", "subscription { test }");
    defer sub.deinit();

    try std.testing.expectEqualStrings("ws://localhost/graphql", sub.endpoint);
    try std.testing.expectEqualStrings("subscription { test }", sub.query);
    try std.testing.expect(sub.variables == null);
    try std.testing.expect(sub.operation_name == null);
    try std.testing.expect(sub.connected == false);
    try std.testing.expectEqual(@as(usize, 0), sub.message_count);
}
