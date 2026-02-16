const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const HttpClient = @import("http_client.zig");
const VoltFile = @import("volt_file.zig");

// ── GraphQL Support ─────────────────────────────────────────────────────

pub const GraphQLRequest = struct {
    endpoint: []const u8,
    query: []const u8,
    variables: ?[]const u8 = null,
    operation_name: ?[]const u8 = null,
    headers: std.ArrayList(VoltFile.Header),

    pub fn init(allocator: Allocator, endpoint: []const u8) GraphQLRequest {
        return .{
            .endpoint = endpoint,
            .query = "",
            .headers = std.ArrayList(VoltFile.Header).init(allocator),
        };
    }

    pub fn deinit(self: *GraphQLRequest) void {
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

    // Build request body
    const body = try buildRequestBody(allocator, gql_req);
    http_req.body = body;
    http_req.body_type = .json;

    // Execute
    gql_resp.http_response = try HttpClient.execute(allocator, &http_req, config);
    allocator.free(body);

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

    // The body contains the GraphQL query
    if (volt_req.body) |body| {
        gql_req.query = body;
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
