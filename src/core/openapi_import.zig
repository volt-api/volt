const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── OpenAPI 3.x / Swagger 2.0 JSON Import ───────────────────────────────
// Parse OpenAPI JSON specs and generate .volt file content for each endpoint.
// Supports JSON format only. Extracts paths, methods, parameters,
// requestBody, responses, and server base URLs.

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const OpenAPIEndpoint = struct {
    allocator: Allocator,
    method: []const u8,
    path: []const u8,
    summary: ?[]const u8,
    url: []const u8, // full URL with base
    headers: std.ArrayList(Header),
    body_example: ?[]const u8,
    body_type: []const u8,
    expected_status: ?u16,

    pub fn init(allocator: Allocator) OpenAPIEndpoint {
        return .{
            .allocator = allocator,
            .method = "GET",
            .path = "/",
            .summary = null,
            .url = "",
            .headers = std.ArrayList(Header).init(allocator),
            .body_example = null,
            .body_type = "none",
            .expected_status = null,
        };
    }

    pub fn deinit(self: *OpenAPIEndpoint) void {
        self.headers.deinit();
    }
};

/// Parse an OpenAPI JSON spec and extract all endpoints.
pub fn parseOpenAPI(allocator: Allocator, json_content: []const u8) !std.ArrayList(OpenAPIEndpoint) {
    var endpoints = std.ArrayList(OpenAPIEndpoint).init(allocator);
    errdefer {
        for (endpoints.items) |*ep| {
            ep.deinit();
        }
        endpoints.deinit();
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch
        return endpoints;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return endpoints;

    // Extract base URL from servers (OpenAPI 3.x) or host+basePath (Swagger 2.0)
    var base_url_buf = std.ArrayList(u8).init(allocator);
    defer base_url_buf.deinit();

    if (root.object.get("servers")) |servers_val| {
        // OpenAPI 3.x
        if (servers_val == .array and servers_val.array.items.len > 0) {
            const first_server = servers_val.array.items[0];
            if (first_server == .object) {
                if (first_server.object.get("url")) |url_val| {
                    if (url_val == .string) {
                        try base_url_buf.appendSlice(url_val.string);
                    }
                }
            }
        }
    } else {
        // Swagger 2.0 fallback
        var scheme: []const u8 = "https";
        if (root.object.get("schemes")) |schemes_val| {
            if (schemes_val == .array and schemes_val.array.items.len > 0) {
                if (schemes_val.array.items[0] == .string) {
                    scheme = schemes_val.array.items[0].string;
                }
            }
        }
        if (root.object.get("host")) |host_val| {
            if (host_val == .string) {
                try base_url_buf.appendSlice(scheme);
                try base_url_buf.appendSlice("://");
                try base_url_buf.appendSlice(host_val.string);
                if (root.object.get("basePath")) |bp_val| {
                    if (bp_val == .string) {
                        try base_url_buf.appendSlice(bp_val.string);
                    }
                }
            }
        }
    }

    // Remove trailing slash from base URL
    const base_url = blk: {
        const items = base_url_buf.items;
        if (items.len > 0 and items[items.len - 1] == '/') {
            break :blk items[0 .. items.len - 1];
        }
        break :blk items;
    };

    // Navigate to paths
    const paths = root.object.get("paths") orelse return endpoints;
    if (paths != .object) return endpoints;

    // Iterate over each path
    var path_it = paths.object.iterator();
    while (path_it.next()) |path_entry| {
        const path_str = path_entry.key_ptr.*;
        const path_obj = path_entry.value_ptr.*;
        if (path_obj != .object) continue;

        // Iterate over each method on this path
        const http_methods = [_][]const u8{ "get", "post", "put", "patch", "delete", "head", "options" };
        for (http_methods) |method_name| {
            const method_val = path_obj.object.get(method_name) orelse continue;
            if (method_val != .object) continue;

            var endpoint = OpenAPIEndpoint.init(allocator);

            // Method (uppercase)
            endpoint.method = upperMethod(method_name);
            endpoint.path = try allocator.dupe(u8, path_str);

            // Summary
            if (method_val.object.get("summary")) |summary_val| {
                if (summary_val == .string) {
                    endpoint.summary = try allocator.dupe(u8, summary_val.string);
                }
            }

            // Full URL
            const full_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path_str });
            endpoint.url = full_url;

            // Extract header parameters
            if (method_val.object.get("parameters")) |params_val| {
                if (params_val == .array) {
                    for (params_val.array.items) |param| {
                        if (param != .object) continue;
                        const in_val = param.object.get("in") orelse continue;
                        if (in_val != .string) continue;
                        if (!mem.eql(u8, in_val.string, "header")) continue;

                        const param_name = blk: {
                            if (param.object.get("name")) |n| {
                                if (n == .string) break :blk n.string;
                            }
                            break :blk "";
                        };
                        if (param_name.len > 0) {
                            try endpoint.headers.append(.{
                                .name = try allocator.dupe(u8, param_name),
                                .value = try allocator.dupe(u8, "<value>"),
                            });
                        }
                    }
                }
            }

            // Extract requestBody (OpenAPI 3.x)
            if (method_val.object.get("requestBody")) |req_body_val| {
                if (req_body_val == .object) {
                    if (req_body_val.object.get("content")) |content_val| {
                        if (content_val == .object) {
                            if (content_val.object.get("application/json")) |json_content_val| {
                                endpoint.body_type = "json";
                                if (json_content_val == .object) {
                                    if (json_content_val.object.get("schema")) |schema_val| {
                                        if (schema_val == .object) {
                                            if (schema_val.object.get("example")) |example_val| {
                                                endpoint.body_example = try jsonValueToString(allocator, example_val);
                                            }
                                        }
                                    }
                                }
                            } else if (content_val.object.get("application/x-www-form-urlencoded") != null) {
                                endpoint.body_type = "form";
                            } else if (content_val.object.get("multipart/form-data") != null) {
                                endpoint.body_type = "multipart";
                            }
                        }
                    }
                }
            }

            // Expected status from responses
            if (method_val.object.get("responses")) |resp_val| {
                if (resp_val == .object) {
                    // Look for common success codes in order
                    const status_codes = [_][]const u8{ "200", "201", "204", "202" };
                    for (status_codes) |code| {
                        if (resp_val.object.get(code) != null) {
                            endpoint.expected_status = std.fmt.parseInt(u16, code, 10) catch null;
                            break;
                        }
                    }
                }
            }

            try endpoints.append(endpoint);
        }
    }

    return endpoints;
}

/// Convert a single OpenAPIEndpoint to .volt file content.
pub fn endpointToVolt(allocator: Allocator, endpoint: *const OpenAPIEndpoint) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Name from summary
    if (endpoint.summary) |summary| {
        try writer.print("name: {s}\n", .{summary});
    }

    // Method
    try writer.print("method: {s}\n", .{endpoint.method});

    // URL
    try writer.print("url: {s}\n", .{endpoint.url});

    // Headers
    if (endpoint.headers.items.len > 0) {
        try writer.writeAll("headers:\n");
        for (endpoint.headers.items) |h| {
            try writer.print("  - {s}: {s}\n", .{ h.name, h.value });
        }
    }

    // Body
    if (!mem.eql(u8, endpoint.body_type, "none")) {
        try writer.writeAll("body:\n");
        try writer.print("  type: {s}\n", .{endpoint.body_type});
        if (endpoint.body_example) |example| {
            try writer.print("  content: {s}\n", .{example});
        }
    }

    // Tests from expected status
    if (endpoint.expected_status) |status| {
        try writer.writeAll("tests:\n");
        try writer.print("  - status equals {d}\n", .{status});
    }

    return buf.toOwnedSlice();
}

/// Parse an OpenAPI JSON spec and return .volt file content strings for all endpoints.
pub fn importOpenAPIToVoltFiles(allocator: Allocator, json_content: []const u8) !std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (results.items) |item| {
            allocator.free(item);
        }
        results.deinit();
    }

    var endpoints = try parseOpenAPI(allocator, json_content);
    defer {
        for (endpoints.items) |*ep| {
            allocator.free(ep.path);
            if (ep.summary) |s| allocator.free(s);
            allocator.free(ep.url);
            for (ep.headers.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            if (ep.body_example) |b| allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    for (endpoints.items) |*ep| {
        const volt_content = try endpointToVolt(allocator, ep);
        try results.append(volt_content);
    }

    return results;
}

// ── Internal Helpers ────────────────────────────────────────────────────

fn upperMethod(method: []const u8) []const u8 {
    if (mem.eql(u8, method, "get")) return "GET";
    if (mem.eql(u8, method, "post")) return "POST";
    if (mem.eql(u8, method, "put")) return "PUT";
    if (mem.eql(u8, method, "patch")) return "PATCH";
    if (mem.eql(u8, method, "delete")) return "DELETE";
    if (mem.eql(u8, method, "head")) return "HEAD";
    if (mem.eql(u8, method, "options")) return "OPTIONS";
    return "GET";
}

fn jsonValueToString(allocator: Allocator, value: std.json.Value) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();
    try writeJsonValue(writer, value);
    return buf.toOwnedSlice();
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| {
            try writer.writeByte('"');
            try writer.writeAll(s);
            try writer.writeByte('"');
        },
        .array => |arr| {
            try writer.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(", ");
                try writeJsonValue(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |obj| {
            try writer.writeByte('{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try writer.writeAll(", ");
                first = false;
                try writer.print("\"{s}\": ", .{entry.key_ptr.*});
                try writeJsonValue(writer, entry.value_ptr.*);
            }
            try writer.writeByte('}');
        },
        .number_string => |s| try writer.writeAll(s),
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse simple OpenAPI with one endpoint" {
    const openapi_json =
        \\{
        \\  "openapi": "3.0.3",
        \\  "info": { "title": "Test API", "version": "1.0.0" },
        \\  "servers": [{ "url": "https://api.example.com" }],
        \\  "paths": {
        \\    "/users": {
        \\      "get": {
        \\        "summary": "List Users",
        \\        "responses": {
        \\          "200": { "description": "Success" }
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var endpoints = try parseOpenAPI(std.testing.allocator, openapi_json);
    defer {
        for (endpoints.items) |*ep| {
            std.testing.allocator.free(ep.path);
            if (ep.summary) |s| std.testing.allocator.free(s);
            std.testing.allocator.free(ep.url);
            for (ep.headers.items) |h| {
                std.testing.allocator.free(h.name);
                std.testing.allocator.free(h.value);
            }
            if (ep.body_example) |b| std.testing.allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), endpoints.items.len);
    try std.testing.expectEqualStrings("GET", endpoints.items[0].method);
    try std.testing.expectEqualStrings("/users", endpoints.items[0].path);
    try std.testing.expectEqualStrings("https://api.example.com/users", endpoints.items[0].url);
    try std.testing.expectEqualStrings("List Users", endpoints.items[0].summary.?);
    try std.testing.expectEqual(@as(u16, 200), endpoints.items[0].expected_status.?);
}

test "parse OpenAPI with multiple methods on same path" {
    const openapi_json =
        \\{
        \\  "openapi": "3.0.3",
        \\  "info": { "title": "Test API", "version": "1.0.0" },
        \\  "servers": [{ "url": "https://api.example.com/v1" }],
        \\  "paths": {
        \\    "/items": {
        \\      "get": {
        \\        "summary": "List Items",
        \\        "responses": { "200": { "description": "OK" } }
        \\      },
        \\      "post": {
        \\        "summary": "Create Item",
        \\        "requestBody": {
        \\          "content": {
        \\            "application/json": {
        \\              "schema": {
        \\                "type": "object",
        \\                "example": { "name": "Widget" }
        \\              }
        \\            }
        \\          }
        \\        },
        \\        "responses": { "201": { "description": "Created" } }
        \\      }
        \\    }
        \\  }
        \\}
    ;

    var endpoints = try parseOpenAPI(std.testing.allocator, openapi_json);
    defer {
        for (endpoints.items) |*ep| {
            std.testing.allocator.free(ep.path);
            if (ep.summary) |s| std.testing.allocator.free(s);
            std.testing.allocator.free(ep.url);
            for (ep.headers.items) |h| {
                std.testing.allocator.free(h.name);
                std.testing.allocator.free(h.value);
            }
            if (ep.body_example) |b| std.testing.allocator.free(b);
            ep.deinit();
        }
        endpoints.deinit();
    }

    try std.testing.expectEqual(@as(usize, 2), endpoints.items.len);

    // Find the GET and POST endpoints (iteration order may vary)
    var get_idx: ?usize = null;
    var post_idx: ?usize = null;
    for (endpoints.items, 0..) |ep, idx| {
        if (mem.eql(u8, ep.method, "GET")) get_idx = idx;
        if (mem.eql(u8, ep.method, "POST")) post_idx = idx;
    }

    try std.testing.expect(get_idx != null);
    try std.testing.expect(post_idx != null);

    const post_ep = &endpoints.items[post_idx.?];
    try std.testing.expectEqualStrings("json", post_ep.body_type);
    try std.testing.expect(post_ep.body_example != null);
    try std.testing.expectEqual(@as(u16, 201), post_ep.expected_status.?);
}

test "generate .volt content from endpoint" {
    var endpoint = OpenAPIEndpoint.init(std.testing.allocator);
    defer endpoint.deinit();

    endpoint.method = "POST";
    endpoint.path = "/users";
    endpoint.summary = "Create User";
    endpoint.url = "https://api.example.com/users";
    endpoint.body_type = "json";
    endpoint.body_example = "{\"name\": \"John\"}";
    endpoint.expected_status = 201;
    try endpoint.headers.append(.{ .name = "X-Request-Id", .value = "<value>" });

    const volt_content = try endpointToVolt(std.testing.allocator, &endpoint);
    defer std.testing.allocator.free(volt_content);

    try std.testing.expect(mem.indexOf(u8, volt_content, "method: POST") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "url: https://api.example.com/users") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "name: Create User") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "type: json") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "status equals 201") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "X-Request-Id") != null);
}
