const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── Postman Collection Importer ─────────────────────────────────────────

pub const ImportError = error{
    InvalidJson,
    UnsupportedFormat,
    IoError,
    OutOfMemory,
};

pub const ImportedRequest = struct {
    path: []const u8, // Output file path (relative)
    request: VoltFile.VoltRequest,

    pub fn deinit(self: *ImportedRequest) void {
        self.request.deinit();
    }
};

pub const ImportResult = struct {
    allocator: Allocator,
    arena: std.heap.ArenaAllocator,
    requests: std.ArrayList(ImportedRequest),
    collection_name: []const u8,
    errors: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) ImportResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .requests = std.ArrayList(ImportedRequest).init(allocator),
            .collection_name = "",
            .errors = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ImportResult) void {
        // Free ArrayLists inside each request (they use the parent allocator)
        for (self.requests.items) |*r| {
            r.request.headers.deinit();
            r.request.tests.deinit();
            r.request.variables.deinit();
        }
        self.requests.deinit();
        self.errors.deinit();
        // Arena frees all string allocations at once
        self.arena.deinit();
    }
};

/// Import a Postman Collection v2.1 JSON file
pub fn importPostman(allocator: Allocator, json_content: []const u8) ImportError!ImportResult {
    var result = ImportResult.init(allocator);
    errdefer result.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch
        return ImportError.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return ImportError.InvalidJson;

    const str_alloc = result.arena.allocator();

    // Get collection info
    if (root.object.get("info")) |info| {
        if (info == .object) {
            if (info.object.get("name")) |name| {
                if (name == .string) {
                    result.collection_name = str_alloc.dupe(u8, name.string) catch
                        return ImportError.OutOfMemory;
                }
            }
        }
    }

    // Process items (requests and folders)
    if (root.object.get("item")) |items| {
        if (items == .array) {
            processItems(allocator, str_alloc, items.array.items, "", &result) catch |e| {
                switch (e) {
                    error.OutOfMemory => return ImportError.OutOfMemory,
                }
            };
        }
    }

    return result;
}

fn dupeStr(allocator: Allocator, s: []const u8) []const u8 {
    return allocator.dupe(u8, s) catch return "";
}

fn processItems(
    allocator: Allocator,
    str_alloc: Allocator,
    items: []const std.json.Value,
    parent_path: []const u8,
    result: *ImportResult,
) Allocator.Error!void {
    for (items) |item| {
        if (item != .object) continue;

        const name = blk: {
            if (item.object.get("name")) |n| {
                if (n == .string) break :blk n.string;
            }
            break :blk "unnamed";
        };

        // Check if this is a folder (has sub-items) or a request
        if (item.object.get("item")) |sub_items| {
            // It's a folder - recurse
            if (sub_items == .array) {
                const folder_path = if (parent_path.len > 0)
                    std.fmt.allocPrint(str_alloc, "{s}/{s}", .{ parent_path, name }) catch continue
                else
                    try str_alloc.dupe(u8, name);

                processItems(allocator, str_alloc, sub_items.array.items, folder_path, result) catch continue;
            }
        } else if (item.object.get("request")) |req_obj| {
            // It's a request
            var volt_req = VoltFile.VoltRequest.init(allocator);

            volt_req.name = dupeStr(str_alloc, name);

            if (req_obj == .object) {
                // Method
                if (req_obj.object.get("method")) |method| {
                    if (method == .string) {
                        volt_req.method = VoltFile.Method.fromString(method.string) orelse .GET;
                    }
                }

                // URL
                if (req_obj.object.get("url")) |url_val| {
                    if (url_val == .string) {
                        volt_req.url = dupeStr(str_alloc, url_val.string);
                    } else if (url_val == .object) {
                        if (url_val.object.get("raw")) |raw| {
                            if (raw == .string) {
                                volt_req.url = dupeStr(str_alloc, raw.string);
                            }
                        }
                    }
                }

                // Headers
                if (req_obj.object.get("header")) |headers| {
                    if (headers == .array) {
                        for (headers.array.items) |h| {
                            if (h != .object) continue;
                            const hname = blk: {
                                if (h.object.get("key")) |k| {
                                    if (k == .string) break :blk dupeStr(str_alloc, k.string);
                                }
                                break :blk "";
                            };
                            const hvalue = blk: {
                                if (h.object.get("value")) |v| {
                                    if (v == .string) break :blk dupeStr(str_alloc, v.string);
                                }
                                break :blk "";
                            };
                            if (hname.len > 0) {
                                volt_req.addHeader(hname, hvalue) catch continue;
                            }
                        }
                    }
                }

                // Body
                if (req_obj.object.get("body")) |body| {
                    if (body == .object) {
                        if (body.object.get("mode")) |mode| {
                            if (mode == .string) {
                                if (mem.eql(u8, mode.string, "raw")) {
                                    volt_req.body_type = .raw;
                                    // Check options for JSON
                                    if (body.object.get("options")) |opts| {
                                        if (opts == .object) {
                                            if (opts.object.get("raw")) |raw_opts| {
                                                if (raw_opts == .object) {
                                                    if (raw_opts.object.get("language")) |lang| {
                                                        if (lang == .string and mem.eql(u8, lang.string, "json")) {
                                                            volt_req.body_type = .json;
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    if (body.object.get("raw")) |raw_body| {
                                        if (raw_body == .string) {
                                            volt_req.body = dupeStr(str_alloc, raw_body.string);
                                        }
                                    }
                                } else if (mem.eql(u8, mode.string, "formdata")) {
                                    volt_req.body_type = .form;
                                }
                            }
                        }
                    }
                }

                // Auth
                if (req_obj.object.get("auth")) |auth| {
                    if (auth == .object) {
                        if (auth.object.get("type")) |auth_type| {
                            if (auth_type == .string) {
                                if (mem.eql(u8, auth_type.string, "bearer")) {
                                    volt_req.auth.type = .bearer;
                                    if (auth.object.get("bearer")) |bearer| {
                                        if (bearer == .array) {
                                            for (bearer.array.items) |b| {
                                                if (b == .object) {
                                                    if (b.object.get("key")) |k| {
                                                        if (k == .string and mem.eql(u8, k.string, "token")) {
                                                            if (b.object.get("value")) |v| {
                                                                if (v == .string) {
                                                                    volt_req.auth.token = dupeStr(str_alloc, v.string);
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                } else if (mem.eql(u8, auth_type.string, "basic")) {
                                    volt_req.auth.type = .basic;
                                } else if (mem.eql(u8, auth_type.string, "apikey")) {
                                    volt_req.auth.type = .api_key;
                                }
                            }
                        }
                    }
                }
            }

            // Build output path
            const file_name = std.fmt.allocPrint(str_alloc, "{s}.volt", .{name}) catch continue;
            const full_path = if (parent_path.len > 0)
                std.fmt.allocPrint(str_alloc, "{s}/{s}", .{ parent_path, file_name }) catch continue
            else
                file_name;

            result.requests.append(.{
                .path = full_path,
                .request = volt_req,
            }) catch continue;
        }
    }
}

/// Write imported requests to the filesystem
pub fn writeImportedCollection(
    allocator: Allocator,
    result: *const ImportResult,
    output_dir: []const u8,
) !void {
    // Create output directory
    std.fs.cwd().makePath(output_dir) catch {};

    for (result.requests.items) |*imported| {
        // Create subdirectories if needed
        const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, imported.path }) catch continue;
        defer allocator.free(full_path);

        // Create parent directories
        if (mem.lastIndexOf(u8, full_path, "/")) |last_slash| {
            std.fs.cwd().makePath(full_path[0..last_slash]) catch {};
        }

        // Serialize to .volt format
        const content = VoltFile.serialize(&imported.request, allocator) catch continue;
        defer allocator.free(content);

        // Write file
        const file = std.fs.cwd().createFile(full_path, .{}) catch continue;
        defer file.close();
        file.writeAll(content) catch continue;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "import simple postman collection" {
    const json =
        \\{
        \\  "info": {
        \\    "name": "Test API",
        \\    "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"
        \\  },
        \\  "item": [
        \\    {
        \\      "name": "Get Users",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": {
        \\          "raw": "https://api.example.com/users"
        \\        },
        \\        "header": [
        \\          {
        \\            "key": "Accept",
        \\            "value": "application/json"
        \\          }
        \\        ]
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqualStrings("Test API", result.collection_name);
    try std.testing.expectEqual(@as(usize, 1), result.requests.items.len);
    try std.testing.expectEqual(VoltFile.Method.GET, result.requests.items[0].request.method);
    try std.testing.expectEqualStrings("https://api.example.com/users", result.requests.items[0].request.url);
}

test "import postman collection with folders" {
    const json =
        \\{
        \\  "info": { "name": "API" },
        \\  "item": [
        \\    {
        \\      "name": "Users",
        \\      "item": [
        \\        {
        \\          "name": "List Users",
        \\          "request": {
        \\            "method": "GET",
        \\            "url": "https://api.example.com/users"
        \\          }
        \\        },
        \\        {
        \\          "name": "Create User",
        \\          "request": {
        \\            "method": "POST",
        \\            "url": "https://api.example.com/users",
        \\            "body": {
        \\              "mode": "raw",
        \\              "raw": "{\"name\": \"John\"}",
        \\              "options": { "raw": { "language": "json" } }
        \\            }
        \\          }
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.requests.items.len);
    try std.testing.expectEqual(VoltFile.Method.POST, result.requests.items[1].request.method);
    try std.testing.expectEqual(VoltFile.BodyType.json, result.requests.items[1].request.body_type);
}
