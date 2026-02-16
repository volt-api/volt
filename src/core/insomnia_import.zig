const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── Insomnia v4 JSON Export Import ──────────────────────────────────────
// Parse Insomnia v4 JSON export format and generate .volt files for each request.
// Handles resource types: request, request_group (folders), environment.
// Extracts: method, url, headers, body (JSON/form/multipart), authentication.

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const InsomniaRequest = struct {
    allocator: Allocator,
    name: []const u8,
    method: []const u8,
    url: []const u8,
    headers: std.ArrayList(Header),
    body: ?[]const u8,
    body_type: []const u8,
    auth_type: []const u8,
    auth_value: ?[]const u8,
    folder: ?[]const u8,

    pub fn init(allocator: Allocator) InsomniaRequest {
        return .{
            .allocator = allocator,
            .name = "",
            .method = "GET",
            .url = "",
            .headers = std.ArrayList(Header).init(allocator),
            .body = null,
            .body_type = "none",
            .auth_type = "none",
            .auth_value = null,
            .folder = null,
        };
    }

    pub fn deinit(self: *InsomniaRequest) void {
        self.headers.deinit();
    }
};

/// Parse an Insomnia v4 JSON export and extract all requests.
pub fn parseInsomnia(allocator: Allocator, json_content: []const u8) !std.ArrayList(InsomniaRequest) {
    var requests = std.ArrayList(InsomniaRequest).init(allocator);
    errdefer {
        for (requests.items) |*req| {
            req.deinit();
        }
        requests.deinit();
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch
        return requests;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return requests;

    // Get the resources array
    const resources = root.object.get("resources") orelse return requests;
    if (resources != .array) return requests;

    // First pass: build a map of _id -> name for request_group (folders)
    var folder_map = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = folder_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        folder_map.deinit();
    }

    for (resources.array.items) |resource| {
        if (resource != .object) continue;
        const type_val = resource.object.get("_type") orelse continue;
        if (type_val != .string) continue;
        if (!mem.eql(u8, type_val.string, "request_group")) continue;

        const id_val = resource.object.get("_id") orelse continue;
        if (id_val != .string) continue;

        const name_val = resource.object.get("name") orelse continue;
        if (name_val != .string) continue;

        const id_dup = allocator.dupe(u8, id_val.string) catch continue;
        const name_dup = allocator.dupe(u8, name_val.string) catch {
            allocator.free(id_dup);
            continue;
        };
        folder_map.put(id_dup, name_dup) catch {
            allocator.free(id_dup);
            allocator.free(name_dup);
            continue;
        };
    }

    // Second pass: extract requests
    for (resources.array.items) |resource| {
        if (resource != .object) continue;
        const type_val = resource.object.get("_type") orelse continue;
        if (type_val != .string) continue;
        if (!mem.eql(u8, type_val.string, "request")) continue;

        var req = InsomniaRequest.init(allocator);

        // Name
        if (resource.object.get("name")) |name_val| {
            if (name_val == .string) {
                req.name = try allocator.dupe(u8, name_val.string);
            }
        }

        // Method
        if (resource.object.get("method")) |method_val| {
            if (method_val == .string) {
                req.method = try allocator.dupe(u8, method_val.string);
            }
        }

        // URL
        if (resource.object.get("url")) |url_val| {
            if (url_val == .string) {
                req.url = try allocator.dupe(u8, url_val.string);
            }
        }

        // Headers
        if (resource.object.get("headers")) |headers_val| {
            if (headers_val == .array) {
                for (headers_val.array.items) |h| {
                    if (h != .object) continue;
                    const hname = blk: {
                        if (h.object.get("name")) |n| {
                            if (n == .string) break :blk n.string;
                        }
                        break :blk "";
                    };
                    const hvalue = blk: {
                        if (h.object.get("value")) |v| {
                            if (v == .string) break :blk v.string;
                        }
                        break :blk "";
                    };
                    if (hname.len > 0) {
                        try req.headers.append(.{
                            .name = try allocator.dupe(u8, hname),
                            .value = try allocator.dupe(u8, hvalue),
                        });
                    }
                }
            }
        }

        // Body
        if (resource.object.get("body")) |body_val| {
            if (body_val == .object) {
                // mimeType
                if (body_val.object.get("mimeType")) |mime_val| {
                    if (mime_val == .string) {
                        if (mem.indexOf(u8, mime_val.string, "json") != null) {
                            req.body_type = "json";
                        } else if (mem.indexOf(u8, mime_val.string, "form") != null) {
                            req.body_type = "form";
                        } else if (mem.indexOf(u8, mime_val.string, "multipart") != null) {
                            req.body_type = "multipart";
                        } else if (mem.indexOf(u8, mime_val.string, "xml") != null) {
                            req.body_type = "xml";
                        } else {
                            req.body_type = "raw";
                        }
                    }
                }
                // text content
                if (body_val.object.get("text")) |text_val| {
                    if (text_val == .string and text_val.string.len > 0) {
                        req.body = try allocator.dupe(u8, text_val.string);
                    }
                }
            }
        }

        // Authentication
        if (resource.object.get("authentication")) |auth_val| {
            if (auth_val == .object) {
                if (auth_val.object.get("type")) |auth_type_val| {
                    if (auth_type_val == .string) {
                        if (mem.eql(u8, auth_type_val.string, "bearer")) {
                            req.auth_type = "bearer";
                            if (auth_val.object.get("token")) |token_val| {
                                if (token_val == .string and token_val.string.len > 0) {
                                    req.auth_value = try allocator.dupe(u8, token_val.string);
                                }
                            }
                        } else if (mem.eql(u8, auth_type_val.string, "basic")) {
                            req.auth_type = "basic";
                            // Combine username:password
                            var creds_buf = std.ArrayList(u8).init(allocator);
                            defer creds_buf.deinit();
                            if (auth_val.object.get("username")) |u_val| {
                                if (u_val == .string) {
                                    try creds_buf.appendSlice(u_val.string);
                                }
                            }
                            try creds_buf.append(':');
                            if (auth_val.object.get("password")) |p_val| {
                                if (p_val == .string) {
                                    try creds_buf.appendSlice(p_val.string);
                                }
                            }
                            if (creds_buf.items.len > 1) {
                                req.auth_value = try allocator.dupe(u8, creds_buf.items);
                            }
                        } else if (mem.eql(u8, auth_type_val.string, "oauth2")) {
                            req.auth_type = "oauth2";
                            if (auth_val.object.get("accessTokenUrl")) |url_val| {
                                if (url_val == .string and url_val.string.len > 0) {
                                    req.auth_value = try allocator.dupe(u8, url_val.string);
                                }
                            } else if (auth_val.object.get("token")) |token_val| {
                                if (token_val == .string and token_val.string.len > 0) {
                                    req.auth_value = try allocator.dupe(u8, token_val.string);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Folder (from parentId)
        if (resource.object.get("parentId")) |parent_val| {
            if (parent_val == .string) {
                if (folder_map.get(parent_val.string)) |folder_name| {
                    req.folder = try allocator.dupe(u8, folder_name);
                }
            }
        }

        try requests.append(req);
    }

    return requests;
}

/// Convert an InsomniaRequest to .volt file content.
pub fn requestToVolt(allocator: Allocator, request: *const InsomniaRequest) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Name
    if (request.name.len > 0) {
        try writer.print("name: {s}\n", .{request.name});
    }

    // Method
    try writer.print("method: {s}\n", .{request.method});

    // URL
    try writer.print("url: {s}\n", .{request.url});

    // Headers
    if (request.headers.items.len > 0) {
        try writer.writeAll("headers:\n");
        for (request.headers.items) |h| {
            try writer.print("  - {s}: {s}\n", .{ h.name, h.value });
        }
    }

    // Body
    if (request.body) |body| {
        try writer.writeAll("body:\n");
        try writer.print("  type: {s}\n", .{request.body_type});
        try writer.print("  content: {s}\n", .{body});
    }

    // Auth
    if (mem.eql(u8, request.auth_type, "bearer")) {
        try writer.writeAll("auth:\n");
        try writer.writeAll("  type: bearer\n");
        if (request.auth_value) |token| {
            try writer.print("  token: {s}\n", .{token});
        }
    } else if (mem.eql(u8, request.auth_type, "basic")) {
        try writer.writeAll("auth:\n");
        try writer.writeAll("  type: basic\n");
        if (request.auth_value) |creds| {
            if (mem.indexOf(u8, creds, ":")) |colon_pos| {
                try writer.print("  username: {s}\n", .{creds[0..colon_pos]});
                try writer.print("  password: {s}\n", .{creds[colon_pos + 1 ..]});
            }
        }
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse Insomnia export with one request" {
    const insomnia_json =
        \\{
        \\  "_type": "export",
        \\  "__export_format": 4,
        \\  "resources": [
        \\    {
        \\      "_type": "request",
        \\      "_id": "req_1",
        \\      "parentId": "wrk_1",
        \\      "name": "Get Users",
        \\      "method": "GET",
        \\      "url": "https://api.example.com/users",
        \\      "headers": [],
        \\      "body": {},
        \\      "authentication": {}
        \\    }
        \\  ]
        \\}
    ;

    var results = try parseInsomnia(std.testing.allocator, insomnia_json);
    defer {
        for (results.items) |*req| {
            std.testing.allocator.free(req.name);
            std.testing.allocator.free(req.method);
            std.testing.allocator.free(req.url);
            for (req.headers.items) |h| {
                std.testing.allocator.free(h.name);
                std.testing.allocator.free(h.value);
            }
            if (req.body) |b| std.testing.allocator.free(b);
            if (req.auth_value) |v| std.testing.allocator.free(v);
            if (req.folder) |f| std.testing.allocator.free(f);
            req.deinit();
        }
        results.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("Get Users", results.items[0].name);
    try std.testing.expectEqualStrings("GET", results.items[0].method);
    try std.testing.expectEqualStrings("https://api.example.com/users", results.items[0].url);
}

test "parse Insomnia export with headers and body" {
    const insomnia_json =
        \\{
        \\  "_type": "export",
        \\  "__export_format": 4,
        \\  "resources": [
        \\    {
        \\      "_type": "request_group",
        \\      "_id": "fld_1",
        \\      "parentId": "wrk_1",
        \\      "name": "API Endpoints"
        \\    },
        \\    {
        \\      "_type": "request",
        \\      "_id": "req_2",
        \\      "parentId": "fld_1",
        \\      "name": "Create User",
        \\      "method": "POST",
        \\      "url": "https://api.example.com/users",
        \\      "headers": [
        \\        { "name": "Content-Type", "value": "application/json" },
        \\        { "name": "Accept", "value": "application/json" }
        \\      ],
        \\      "body": {
        \\        "mimeType": "application/json",
        \\        "text": "{\"name\": \"John\", \"email\": \"john@example.com\"}"
        \\      },
        \\      "authentication": {
        \\        "type": "bearer",
        \\        "token": "my-secret-token"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var results = try parseInsomnia(std.testing.allocator, insomnia_json);
    defer {
        for (results.items) |*req| {
            std.testing.allocator.free(req.name);
            std.testing.allocator.free(req.method);
            std.testing.allocator.free(req.url);
            for (req.headers.items) |h| {
                std.testing.allocator.free(h.name);
                std.testing.allocator.free(h.value);
            }
            if (req.body) |b| std.testing.allocator.free(b);
            if (req.auth_value) |v| std.testing.allocator.free(v);
            if (req.folder) |f| std.testing.allocator.free(f);
            req.deinit();
        }
        results.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    const req = &results.items[0];
    try std.testing.expectEqualStrings("Create User", req.name);
    try std.testing.expectEqualStrings("POST", req.method);
    try std.testing.expectEqualStrings("https://api.example.com/users", req.url);
    try std.testing.expectEqual(@as(usize, 2), req.headers.items.len);
    try std.testing.expectEqualStrings("Content-Type", req.headers.items[0].name);
    try std.testing.expectEqualStrings("application/json", req.headers.items[0].value);
    try std.testing.expectEqualStrings("Accept", req.headers.items[1].name);
    try std.testing.expectEqualStrings("json", req.body_type);
    try std.testing.expect(req.body != null);
    try std.testing.expect(mem.indexOf(u8, req.body.?, "\"name\"") != null);
    try std.testing.expectEqualStrings("bearer", req.auth_type);
    try std.testing.expectEqualStrings("my-secret-token", req.auth_value.?);
    try std.testing.expectEqualStrings("API Endpoints", req.folder.?);
}
