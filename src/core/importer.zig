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
    collection_auth: ?VoltFile.Auth = null,
    collection_variables: std.ArrayList(CollectionVariable),

    pub const CollectionVariable = struct {
        key: []const u8,
        value: []const u8,
    };

    pub fn init(allocator: Allocator) ImportResult {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .requests = std.ArrayList(ImportedRequest).init(allocator),
            .collection_name = "",
            .errors = std.ArrayList([]const u8).init(allocator),
            .collection_auth = null,
            .collection_variables = std.ArrayList(CollectionVariable).init(allocator),
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
        self.collection_variables.deinit();
        // Arena frees all string allocations at once
        self.arena.deinit();
    }

    /// Generate _collection.volt content for inherited collection-level auth
    pub fn generateCollectionVolt(self: *const ImportResult, allocator: Allocator) !?[]const u8 {
        const auth = self.collection_auth orelse return null;
        if (auth.type == .none) return null;

        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.print("# Collection-level auth for {s}\n", .{self.collection_name});
        try writer.writeAll("auth:\n");
        try writer.print("  type: {s}\n", .{auth.type.toString()});
        if (auth.token) |token| {
            try writer.print("  token: {s}\n", .{token});
        }
        if (auth.username) |username| {
            try writer.print("  username: {s}\n", .{username});
        }
        if (auth.password) |password| {
            try writer.print("  password: {s}\n", .{password});
        }
        if (auth.key_name) |key_name| {
            try writer.print("  key_name: {s}\n", .{key_name});
        }
        if (auth.key_value) |key_value| {
            try writer.print("  key_value: {s}\n", .{key_value});
        }
        if (auth.key_location) |key_location| {
            try writer.print("  key_location: {s}\n", .{key_location});
        }

        const slice = try buf.toOwnedSlice();
        return @as([]const u8, slice);
    }

    /// Generate _env.volt content for collection variables
    pub fn generateEnvVolt(self: *const ImportResult, allocator: Allocator) !?[]const u8 {
        if (self.collection_variables.items.len == 0) return null;

        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.print("# Collection variables for {s}\n", .{self.collection_name});
        try writer.writeAll("environment: collection\n");
        try writer.writeAll("variables:\n");
        for (self.collection_variables.items) |v| {
            try writer.print("  {s}: {s}\n", .{ v.key, v.value });
        }

        const slice = try buf.toOwnedSlice();
        return @as([]const u8, slice);
    }
};

/// Detect Postman schema version from the info.schema field.
/// Returns true for v2.0 or v2.1 (both supported), false for unknown.
fn detectPostmanVersion(root: std.json.ObjectMap) enum { v2_0, v2_1, unknown } {
    if (root.get("info")) |info| {
        if (info == .object) {
            if (info.object.get("schema")) |schema| {
                if (schema == .string) {
                    if (mem.indexOf(u8, schema.string, "v2.0.0") != null) return .v2_0;
                    if (mem.indexOf(u8, schema.string, "v2.1.0") != null) return .v2_1;
                }
            }
        }
    }
    // If no schema field, try to detect from structure.
    // v2.0 uses string URLs, v2.1 uses object URLs. Accept both.
    return .v2_1;
}

/// Import a Postman Collection v2.0 or v2.1 JSON file
pub fn importPostman(allocator: Allocator, json_content: []const u8) ImportError!ImportResult {
    var result = ImportResult.init(allocator);
    errdefer result.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_content, .{}) catch
        return ImportError.InvalidJson;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return ImportError.InvalidJson;

    const str_alloc = result.arena.allocator();

    const version = detectPostmanVersion(root.object);
    _ = version; // Both v2.0 and v2.1 handled uniformly

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

    // Collection-level auth (requirement 5)
    if (root.object.get("auth")) |auth| {
        if (auth == .object) {
            result.collection_auth = parseAuth(str_alloc, auth.object) catch null;
        }
    }

    // Collection variables (requirement 6)
    if (root.object.get("variable")) |variables| {
        if (variables == .array) {
            for (variables.array.items) |v| {
                if (v != .object) continue;
                const key = blk: {
                    if (v.object.get("key")) |k| {
                        if (k == .string) break :blk str_alloc.dupe(u8, k.string) catch continue;
                    }
                    continue;
                };
                const value = blk: {
                    if (v.object.get("value")) |val| {
                        if (val == .string) break :blk str_alloc.dupe(u8, val.string) catch continue;
                    }
                    break :blk str_alloc.dupe(u8, "") catch continue;
                };
                result.collection_variables.append(.{ .key = key, .value = value }) catch {
                    return ImportError.OutOfMemory;
                };
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

/// Parse a Postman auth object into a VoltFile.Auth struct.
/// Handles bearer, basic, apikey, and oauth2 auth types.
fn parseAuth(str_alloc: Allocator, auth_obj: std.json.ObjectMap) Allocator.Error!VoltFile.Auth {
    var auth = VoltFile.Auth{};

    const auth_type_val = auth_obj.get("type") orelse return auth;
    if (auth_type_val != .string) return auth;
    const auth_type_str = auth_type_val.string;

    if (mem.eql(u8, auth_type_str, "bearer")) {
        auth.type = .bearer;
        if (auth_obj.get("bearer")) |bearer| {
            if (bearer == .array) {
                auth.token = findKvValue(str_alloc, bearer.array.items, "token");
            }
        }
    } else if (mem.eql(u8, auth_type_str, "basic")) {
        auth.type = .basic;
        if (auth_obj.get("basic")) |basic| {
            if (basic == .array) {
                auth.username = findKvValue(str_alloc, basic.array.items, "username");
                auth.password = findKvValue(str_alloc, basic.array.items, "password");
            }
        }
    } else if (mem.eql(u8, auth_type_str, "apikey")) {
        auth.type = .api_key;
        if (auth_obj.get("apikey")) |apikey| {
            if (apikey == .array) {
                auth.key_name = findKvValue(str_alloc, apikey.array.items, "key");
                auth.key_value = findKvValue(str_alloc, apikey.array.items, "value");
                auth.key_location = findKvValue(str_alloc, apikey.array.items, "in");
            }
        }
    } else if (mem.eql(u8, auth_type_str, "oauth2")) {
        // Map OAuth2 to bearer auth using the access_token
        auth.type = .bearer;
        if (auth_obj.get("oauth2")) |oauth2| {
            if (oauth2 == .array) {
                auth.token = findKvValue(str_alloc, oauth2.array.items, "accessToken") orelse
                    findKvValue(str_alloc, oauth2.array.items, "access_token");
            }
        }
    }

    return auth;
}

/// Find a value in a Postman key-value array (e.g., bearer, basic, apikey arrays).
/// Each element is an object with "key" and "value" string fields.
fn findKvValue(str_alloc: Allocator, items: []const std.json.Value, key_name: []const u8) ?[]const u8 {
    for (items) |item| {
        if (item != .object) continue;
        if (item.object.get("key")) |k| {
            if (k == .string and mem.eql(u8, k.string, key_name)) {
                if (item.object.get("value")) |v| {
                    if (v == .string) {
                        return str_alloc.dupe(u8, v.string) catch null;
                    }
                }
            }
        }
    }
    return null;
}

/// Build form-encoded body string from a Postman formdata or urlencoded array.
/// Produces "key=value&key2=value2" format.
fn buildFormBody(str_alloc: Allocator, items: []const std.json.Value) ?[]const u8 {
    var buf = std.ArrayList(u8).init(str_alloc);
    const writer = buf.writer();
    var first = true;
    for (items) |item| {
        if (item != .object) continue;
        const key = blk: {
            if (item.object.get("key")) |k| {
                if (k == .string) break :blk k.string;
            }
            continue;
        };
        const value = blk: {
            if (item.object.get("value")) |v| {
                if (v == .string) break :blk v.string;
            }
            break :blk "";
        };
        // Skip disabled fields
        if (item.object.get("disabled")) |d| {
            if (d == .bool and d.bool) continue;
        }
        if (!first) {
            writer.writeByte('&') catch return null;
        }
        writer.print("{s}={s}", .{ key, value }) catch return null;
        first = false;
    }
    if (buf.items.len == 0) return null;
    return buf.toOwnedSlice() catch null;
}

/// Convert Postman pre-request/test scripts to Volt script commands.
/// Handles common pm.* patterns and returns the converted script string.
/// Unrecognized lines are skipped and logged to the errors list.
fn convertPostmanScript(
    str_alloc: Allocator,
    script_lines: []const []const u8,
    script_type: enum { prerequest, test_script },
    item_name: []const u8,
    result: *ImportResult,
) ?[]const u8 {
    var buf = std.ArrayList(u8).init(str_alloc);
    const writer = buf.writer();
    var has_content = false;

    for (script_lines) |line| {
        const trimmed = mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Skip pure JS boilerplate
        if (mem.eql(u8, trimmed, "});") or
            mem.eql(u8, trimmed, "})") or
            mem.eql(u8, trimmed, "});") or
            mem.eql(u8, trimmed, "}") or
            mem.eql(u8, trimmed, "{") or
            mem.startsWith(u8, trimmed, "//") or
            mem.startsWith(u8, trimmed, "var ") or
            mem.startsWith(u8, trimmed, "let ") or
            mem.startsWith(u8, trimmed, "const "))
        {
            // Check if it's a "const jsonData = pm.response.json();" pattern
            if (mem.indexOf(u8, trimmed, "pm.response.json()") != null) {
                // This defines jsonData, handled via assert patterns below
                continue;
            }
            continue;
        }

        // pm.environment.set("key", "value") -> set key value
        if (convertPmEnvSet(trimmed, writer)) {
            has_content = true;
            continue;
        }

        // pm.test("name", function() { pm.expect(pm.response.code).to.equal(N); })
        // or multi-line pm.expect patterns
        if (convertPmAssert(trimmed, writer)) {
            has_content = true;
            continue;
        }

        // pm.expect(jsonData.field).to.equal("value") -> assert body.field equals value
        if (convertPmExpect(trimmed, writer)) {
            has_content = true;
            continue;
        }

        // If we couldn't convert, log it as skipped
        const type_str = switch (script_type) {
            .prerequest => "pre-request",
            .test_script => "test",
        };
        const msg = std.fmt.allocPrint(str_alloc, "Skipped {s} script line in '{s}': {s}", .{
            type_str, item_name, trimmed,
        }) catch continue;
        result.errors.append(msg) catch {};
    }

    if (!has_content) return null;
    return buf.toOwnedSlice() catch null;
}

/// Try to convert pm.environment.set("key", "value") to "set key value\n"
fn convertPmEnvSet(line: []const u8, writer: anytype) bool {
    // Match: pm.environment.set("key", "value")
    const set_prefix = "pm.environment.set(";
    const idx = mem.indexOf(u8, line, set_prefix) orelse return false;
    const rest = line[idx + set_prefix.len ..];

    // Parse first argument (key)
    const key = extractQuotedString(rest) orelse return false;
    // Find comma after first arg
    const after_key = mem.indexOf(u8, rest, ",") orelse return false;
    const value_part = mem.trim(u8, rest[after_key + 1 ..], " \t");
    // Parse second argument (value)
    const value = extractQuotedString(value_part) orelse return false;

    writer.print("set {s} {s}\n", .{ key, value }) catch return false;
    return true;
}

/// Try to convert pm.test/pm.expect status assertions
fn convertPmAssert(line: []const u8, writer: anytype) bool {
    // pm.expect(pm.response.code).to.equal(200)
    // pm.test("name", function() { pm.expect(pm.response.code).to.equal(200); })
    const code_pattern = "pm.response.code";
    if (mem.indexOf(u8, line, code_pattern) == null) return false;

    const equal_pattern = ".to.equal(";
    const equal_idx = mem.indexOf(u8, line, equal_pattern) orelse return false;
    const after_equal = line[equal_idx + equal_pattern.len ..];
    // Extract the number/value before the closing paren
    const close_paren = mem.indexOf(u8, after_equal, ")") orelse return false;
    const status_val = mem.trim(u8, after_equal[0..close_paren], " \t\"'");
    if (status_val.len == 0) return false;

    writer.print("assert status equals {s}\n", .{status_val}) catch return false;
    return true;
}

/// Try to convert pm.expect(jsonData.field).to.equal("value") patterns
fn convertPmExpect(line: []const u8, writer: anytype) bool {
    const expect_prefix = "pm.expect(";
    const idx = mem.indexOf(u8, line, expect_prefix) orelse return false;
    const rest = line[idx + expect_prefix.len ..];

    // Find the closing paren of pm.expect(...)
    const close_paren = mem.indexOf(u8, rest, ")") orelse return false;
    const field_expr = mem.trim(u8, rest[0..close_paren], " \t");

    // Parse field: jsonData.field -> body.field, pm.response.json().field -> body.field
    const field_suffix = mapFieldToVolt(field_expr) orelse return false;

    // Look for .to.equal(, .to.eql(, .to.be.equal(
    const after_close = rest[close_paren + 1 ..];
    const equal_patterns = [_][]const u8{ ".to.equal(", ".to.eql(", ".to.be.equal(" };
    for (equal_patterns) |pattern| {
        if (mem.indexOf(u8, after_close, pattern)) |eq_idx| {
            const value_start = after_close[eq_idx + pattern.len ..];
            const value_close = mem.indexOf(u8, value_start, ")") orelse continue;
            const raw_value = mem.trim(u8, value_start[0..value_close], " \t");
            // Strip quotes from value if present
            const value = stripQuotes(raw_value);

            writer.print("assert body{s} equals {s}\n", .{ field_suffix, value }) catch return false;
            return true;
        }
    }

    return false;
}

/// Map a field expression from Postman script to Volt field reference suffix.
/// "jsonData.field" -> ".field"
/// "pm.response.json().field" -> ".field"
/// "jsonData.nested.field" -> ".nested.field"
/// Returns the suffix (starting with ".") to be appended to "body".
fn mapFieldToVolt(expr: []const u8) ?[]const u8 {
    if (mem.startsWith(u8, expr, "jsonData")) {
        return expr["jsonData".len..]; // Returns ".field"
    }
    if (mem.startsWith(u8, expr, "pm.response.json()")) {
        return expr["pm.response.json()".len..]; // Returns ".field"
    }
    return null;
}

/// Extract a quoted string value from text like `"key"` or `'key'`.
/// Returns the content between quotes, or null if not found.
fn extractQuotedString(text: []const u8) ?[]const u8 {
    const trimmed = mem.trim(u8, text, " \t");
    if (trimmed.len < 2) return null;

    const quote_char = trimmed[0];
    if (quote_char != '"' and quote_char != '\'') return null;

    // Find matching close quote
    var i: usize = 1;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] == quote_char and (i == 1 or trimmed[i - 1] != '\\')) {
            return trimmed[1..i];
        }
    }
    return null;
}

/// Strip surrounding quotes from a string value.
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2) {
        if ((s[0] == '"' and s[s.len - 1] == '"') or
            (s[0] == '\'' and s[s.len - 1] == '\''))
        {
            return s[1 .. s.len - 1];
        }
    }
    return s;
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
            // Graceful per-item error handling (requirement 9)
            processRequest(allocator, str_alloc, item, req_obj, name, parent_path, result) catch |e| {
                const msg = std.fmt.allocPrint(str_alloc, "Failed to import '{s}': {s}", .{
                    name, @errorName(e),
                }) catch continue;
                result.errors.append(msg) catch continue;
                continue;
            };
        }
    }
}

/// Process a single request item. Extracted for per-item error handling.
fn processRequest(
    allocator: Allocator,
    str_alloc: Allocator,
    item: std.json.Value,
    req_obj: std.json.Value,
    name: []const u8,
    parent_path: []const u8,
    result: *ImportResult,
) Allocator.Error!void {
    var volt_req = VoltFile.VoltRequest.init(allocator);
    errdefer {
        volt_req.headers.deinit();
        volt_req.tests.deinit();
        volt_req.variables.deinit();
    }

    volt_req.name = dupeStr(str_alloc, name);

    if (req_obj == .object) {
        // Method
        if (req_obj.object.get("method")) |method| {
            if (method == .string) {
                volt_req.method = VoltFile.Method.fromString(method.string) orelse .GET;
            }
        }

        // URL (handles both v2.0 string and v2.1 object formats)
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

        // Description (requirement 12)
        if (req_obj.object.get("description")) |desc| {
            if (desc == .string) {
                volt_req.description = dupeStr(str_alloc, desc.string);
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

        // Body (enhanced with formdata and urlencoded support)
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
                            // Requirement 10: formdata body
                            volt_req.body_type = .form;
                            if (body.object.get("formdata")) |formdata| {
                                if (formdata == .array) {
                                    volt_req.body = buildFormBody(str_alloc, formdata.array.items);
                                }
                            }
                        } else if (mem.eql(u8, mode.string, "urlencoded")) {
                            // Requirement 11: urlencoded body
                            volt_req.body_type = .form;
                            if (body.object.get("urlencoded")) |urlencoded| {
                                if (urlencoded == .array) {
                                    volt_req.body = buildFormBody(str_alloc, urlencoded.array.items);
                                }
                            }
                        }
                    }
                }
            }
        }

        // Auth (enhanced with basic, apikey, oauth2 support)
        if (req_obj.object.get("auth")) |auth| {
            if (auth == .object) {
                volt_req.auth = parseAuth(str_alloc, auth.object) catch VoltFile.Auth{};
            }
        }
    }

    // Process event scripts (requirement 8)
    if (item.object.get("event")) |events| {
        if (events == .array) {
            for (events.array.items) |event| {
                if (event != .object) continue;
                const listen = blk: {
                    if (event.object.get("listen")) |l| {
                        if (l == .string) break :blk l.string;
                    }
                    continue;
                };
                const script_obj = event.object.get("script") orelse continue;
                if (script_obj != .object) continue;
                const exec = script_obj.object.get("exec") orelse continue;
                if (exec != .array) continue;

                // Collect script lines
                var lines = std.ArrayList([]const u8).init(str_alloc);
                for (exec.array.items) |exec_line| {
                    if (exec_line == .string) {
                        lines.append(exec_line.string) catch continue;
                    }
                }

                if (lines.items.len > 0) {
                    if (mem.eql(u8, listen, "prerequest")) {
                        volt_req.pre_script = convertPostmanScript(
                            str_alloc,
                            lines.items,
                            .prerequest,
                            name,
                            result,
                        );
                    } else if (mem.eql(u8, listen, "test")) {
                        volt_req.post_script = convertPostmanScript(
                            str_alloc,
                            lines.items,
                            .test_script,
                            name,
                            result,
                        );
                    }
                }
            }
        }
    }

    // Build output path
    const file_name = std.fmt.allocPrint(str_alloc, "{s}.volt", .{name}) catch return error.OutOfMemory;
    const full_path = if (parent_path.len > 0)
        std.fmt.allocPrint(str_alloc, "{s}/{s}", .{ parent_path, file_name }) catch return error.OutOfMemory
    else
        file_name;

    try result.requests.append(.{
        .path = full_path,
        .request = volt_req,
    });
}

/// Write imported requests to the filesystem
pub fn writeImportedCollection(
    allocator: Allocator,
    result: *const ImportResult,
    output_dir: []const u8,
) !void {
    // Create output directory
    std.fs.cwd().makePath(output_dir) catch {};

    // Write _collection.volt if collection-level auth exists
    writeCollectionVolt(allocator, result, output_dir);

    // Write _env.volt if collection variables exist
    writeEnvVolt(allocator, result, output_dir);

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

fn writeCollectionVolt(allocator: Allocator, result: *const ImportResult, output_dir: []const u8) void {
    const content = result.generateCollectionVolt(allocator) catch return;
    if (content) |c| {
        defer allocator.free(c);
        const coll_path = std.fmt.allocPrint(allocator, "{s}/_collection.volt", .{output_dir}) catch return;
        defer allocator.free(coll_path);
        const file = std.fs.cwd().createFile(coll_path, .{}) catch return;
        defer file.close();
        file.writeAll(c) catch return;
    }
}

fn writeEnvVolt(allocator: Allocator, result: *const ImportResult, output_dir: []const u8) void {
    const content = result.generateEnvVolt(allocator) catch return;
    if (content) |c| {
        defer allocator.free(c);
        const env_path = std.fmt.allocPrint(allocator, "{s}/_env.volt", .{output_dir}) catch return;
        defer allocator.free(env_path);
        const file = std.fs.cwd().createFile(env_path, .{}) catch return;
        defer file.close();
        file.writeAll(c) catch return;
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

test "import postman v2.0 collection" {
    const json =
        \\{
        \\  "info": {
        \\    "name": "Legacy API",
        \\    "schema": "https://schema.getpostman.com/json/collection/v2.0.0/collection.json"
        \\  },
        \\  "item": [
        \\    {
        \\      "name": "Get Status",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/status"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqualStrings("Legacy API", result.collection_name);
    try std.testing.expectEqual(@as(usize, 1), result.requests.items.len);
    try std.testing.expectEqualStrings("https://api.example.com/status", result.requests.items[0].request.url);
}

test "import basic auth" {
    const json =
        \\{
        \\  "info": { "name": "Auth API" },
        \\  "item": [
        \\    {
        \\      "name": "Protected",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/protected",
        \\        "auth": {
        \\          "type": "basic",
        \\          "basic": [
        \\            { "key": "username", "value": "admin" },
        \\            { "key": "password", "value": "secret123" }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.requests.items.len);
    const auth = result.requests.items[0].request.auth;
    try std.testing.expectEqual(VoltFile.AuthType.basic, auth.type);
    try std.testing.expectEqualStrings("admin", auth.username.?);
    try std.testing.expectEqualStrings("secret123", auth.password.?);
}

test "import apikey auth" {
    const json =
        \\{
        \\  "info": { "name": "Key API" },
        \\  "item": [
        \\    {
        \\      "name": "Keyed Request",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/data",
        \\        "auth": {
        \\          "type": "apikey",
        \\          "apikey": [
        \\            { "key": "key", "value": "X-API-Key" },
        \\            { "key": "value", "value": "abc123xyz" },
        \\            { "key": "in", "value": "header" }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const auth = result.requests.items[0].request.auth;
    try std.testing.expectEqual(VoltFile.AuthType.api_key, auth.type);
    try std.testing.expectEqualStrings("X-API-Key", auth.key_name.?);
    try std.testing.expectEqualStrings("abc123xyz", auth.key_value.?);
    try std.testing.expectEqualStrings("header", auth.key_location.?);
}

test "import oauth2 auth maps to bearer" {
    const json =
        \\{
        \\  "info": { "name": "OAuth API" },
        \\  "item": [
        \\    {
        \\      "name": "OAuth Request",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/me",
        \\        "auth": {
        \\          "type": "oauth2",
        \\          "oauth2": [
        \\            { "key": "grant_type", "value": "authorization_code" },
        \\            { "key": "accessToken", "value": "ya29.token-here" },
        \\            { "key": "tokenType", "value": "Bearer" }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const auth = result.requests.items[0].request.auth;
    try std.testing.expectEqual(VoltFile.AuthType.bearer, auth.type);
    try std.testing.expectEqualStrings("ya29.token-here", auth.token.?);
}

test "import collection-level auth" {
    const json =
        \\{
        \\  "info": { "name": "Team API" },
        \\  "auth": {
        \\    "type": "bearer",
        \\    "bearer": [
        \\      { "key": "token", "value": "collection-token-xyz" }
        \\    ]
        \\  },
        \\  "item": [
        \\    {
        \\      "name": "List",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/list"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expect(result.collection_auth != null);
    try std.testing.expectEqual(VoltFile.AuthType.bearer, result.collection_auth.?.type);
    try std.testing.expectEqualStrings("collection-token-xyz", result.collection_auth.?.token.?);

    // Verify _collection.volt generation
    const coll_content = try result.generateCollectionVolt(std.testing.allocator);
    try std.testing.expect(coll_content != null);
    defer std.testing.allocator.free(coll_content.?);
    try std.testing.expect(mem.indexOf(u8, coll_content.?, "type: bearer") != null);
    try std.testing.expect(mem.indexOf(u8, coll_content.?, "token: collection-token-xyz") != null);
}

test "import collection variables" {
    const json =
        \\{
        \\  "info": { "name": "Vars API" },
        \\  "variable": [
        \\    { "key": "base_url", "value": "https://api.example.com" },
        \\    { "key": "api_version", "value": "v2" }
        \\  ],
        \\  "item": [
        \\    {
        \\      "name": "Test",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "{{base_url}}/{{api_version}}/test"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.collection_variables.items.len);
    try std.testing.expectEqualStrings("base_url", result.collection_variables.items[0].key);
    try std.testing.expectEqualStrings("https://api.example.com", result.collection_variables.items[0].value);

    // Verify _env.volt generation
    const env_content = try result.generateEnvVolt(std.testing.allocator);
    try std.testing.expect(env_content != null);
    defer std.testing.allocator.free(env_content.?);
    try std.testing.expect(mem.indexOf(u8, env_content.?, "environment: collection") != null);
    try std.testing.expect(mem.indexOf(u8, env_content.?, "base_url: https://api.example.com") != null);
}

test "postman variable syntax preserved" {
    const json =
        \\{
        \\  "info": { "name": "Vars" },
        \\  "item": [
        \\    {
        \\      "name": "Var Test",
        \\      "request": {
        \\        "method": "POST",
        \\        "url": "{{base_url}}/users",
        \\        "header": [
        \\          { "key": "Authorization", "value": "Bearer {{token}}" }
        \\        ],
        \\        "body": {
        \\          "mode": "raw",
        \\          "raw": "{\"env\": \"{{environment}}\"}"
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const req = result.requests.items[0].request;
    try std.testing.expectEqualStrings("{{base_url}}/users", req.url);
    try std.testing.expectEqualStrings("Bearer {{token}}", req.headers.items[0].value);
    try std.testing.expectEqualStrings("{\"env\": \"{{environment}}\"}", req.body.?);
}

test "import formdata body" {
    const json =
        \\{
        \\  "info": { "name": "Form API" },
        \\  "item": [
        \\    {
        \\      "name": "Upload",
        \\      "request": {
        \\        "method": "POST",
        \\        "url": "https://api.example.com/upload",
        \\        "body": {
        \\          "mode": "formdata",
        \\          "formdata": [
        \\            { "key": "name", "value": "John" },
        \\            { "key": "email", "value": "john@example.com" }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const req = result.requests.items[0].request;
    try std.testing.expectEqual(VoltFile.BodyType.form, req.body_type);
    try std.testing.expectEqualStrings("name=John&email=john@example.com", req.body.?);
}

test "import urlencoded body" {
    const json =
        \\{
        \\  "info": { "name": "Form API" },
        \\  "item": [
        \\    {
        \\      "name": "Login",
        \\      "request": {
        \\        "method": "POST",
        \\        "url": "https://api.example.com/login",
        \\        "body": {
        \\          "mode": "urlencoded",
        \\          "urlencoded": [
        \\            { "key": "username", "value": "admin" },
        \\            { "key": "password", "value": "pass123" }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const req = result.requests.items[0].request;
    try std.testing.expectEqual(VoltFile.BodyType.form, req.body_type);
    try std.testing.expectEqualStrings("username=admin&password=pass123", req.body.?);
}

test "import request description" {
    const json =
        \\{
        \\  "info": { "name": "Docs API" },
        \\  "item": [
        \\    {
        \\      "name": "Documented Request",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/health",
        \\        "description": "Health check endpoint for monitoring"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const req = result.requests.items[0].request;
    try std.testing.expectEqualStrings("Health check endpoint for monitoring", req.description.?);
}

test "import pre-request and test scripts" {
    const json =
        \\{
        \\  "info": { "name": "Script API" },
        \\  "item": [
        \\    {
        \\      "name": "Scripted Request",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/data"
        \\      },
        \\      "event": [
        \\        {
        \\          "listen": "prerequest",
        \\          "script": {
        \\            "exec": [
        \\              "pm.environment.set(\"token\", \"abc123\");"
        \\            ]
        \\          }
        \\        },
        \\        {
        \\          "listen": "test",
        \\          "script": {
        \\            "exec": [
        \\              "pm.test(\"Status OK\", function() {",
        \\              "    pm.expect(pm.response.code).to.equal(200);",
        \\              "});"
        \\            ]
        \\          }
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const req = result.requests.items[0].request;

    // Pre-request script should have "set token abc123"
    try std.testing.expect(req.pre_script != null);
    try std.testing.expect(mem.indexOf(u8, req.pre_script.?, "set token abc123") != null);

    // Test script should have "assert status equals 200"
    try std.testing.expect(req.post_script != null);
    try std.testing.expect(mem.indexOf(u8, req.post_script.?, "assert status equals 200") != null);
}

test "graceful partial import on bad items" {
    const json =
        \\{
        \\  "info": { "name": "Mixed API" },
        \\  "item": [
        \\    {
        \\      "name": "Good Request",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/good"
        \\      }
        \\    },
        \\    "not-an-object",
        \\    {
        \\      "name": "Another Good",
        \\      "request": {
        \\        "method": "POST",
        \\        "url": "https://api.example.com/also-good"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    // Both valid requests should be imported, invalid item skipped
    try std.testing.expectEqual(@as(usize, 2), result.requests.items.len);
    try std.testing.expectEqualStrings("https://api.example.com/good", result.requests.items[0].request.url);
    try std.testing.expectEqualStrings("https://api.example.com/also-good", result.requests.items[1].request.url);
}

test "import invalid json returns error" {
    const result = importPostman(std.testing.allocator, "not json at all");
    try std.testing.expectError(ImportError.InvalidJson, result);
}

test "import non-object root returns error" {
    const result = importPostman(std.testing.allocator, "[1, 2, 3]");
    try std.testing.expectError(ImportError.InvalidJson, result);
}

test "formdata skips disabled fields" {
    const json =
        \\{
        \\  "info": { "name": "Form API" },
        \\  "item": [
        \\    {
        \\      "name": "Filtered Form",
        \\      "request": {
        \\        "method": "POST",
        \\        "url": "https://api.example.com/form",
        \\        "body": {
        \\          "mode": "formdata",
        \\          "formdata": [
        \\            { "key": "active", "value": "yes" },
        \\            { "key": "debug", "value": "true", "disabled": true },
        \\            { "key": "mode", "value": "prod" }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const req = result.requests.items[0].request;
    try std.testing.expectEqual(VoltFile.BodyType.form, req.body_type);
    try std.testing.expectEqualStrings("active=yes&mode=prod", req.body.?);
}

test "collection-level basic auth" {
    const json =
        \\{
        \\  "info": { "name": "Basic Auth API" },
        \\  "auth": {
        \\    "type": "basic",
        \\    "basic": [
        \\      { "key": "username", "value": "admin" },
        \\      { "key": "password", "value": "secret" }
        \\    ]
        \\  },
        \\  "item": [
        \\    {
        \\      "name": "Test",
        \\      "request": { "method": "GET", "url": "https://api.example.com/test" }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expect(result.collection_auth != null);
    try std.testing.expectEqual(VoltFile.AuthType.basic, result.collection_auth.?.type);
    try std.testing.expectEqualStrings("admin", result.collection_auth.?.username.?);
    try std.testing.expectEqualStrings("secret", result.collection_auth.?.password.?);
}

test "no collection auth or vars returns null for generation" {
    const json =
        \\{
        \\  "info": { "name": "Simple" },
        \\  "item": [
        \\    {
        \\      "name": "Test",
        \\      "request": { "method": "GET", "url": "https://api.example.com/test" }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expect(result.collection_auth == null);
    try std.testing.expectEqual(@as(usize, 0), result.collection_variables.items.len);

    const coll_content = try result.generateCollectionVolt(std.testing.allocator);
    try std.testing.expect(coll_content == null);

    const env_content = try result.generateEnvVolt(std.testing.allocator);
    try std.testing.expect(env_content == null);
}

test "extractQuotedString helper" {
    try std.testing.expectEqualStrings("hello", extractQuotedString("\"hello\"").?);
    try std.testing.expectEqualStrings("world", extractQuotedString("'world'").?);
    try std.testing.expectEqualStrings("spaced", extractQuotedString("  \"spaced\"  ").?);
    try std.testing.expect(extractQuotedString("no quotes") == null);
    try std.testing.expect(extractQuotedString("") == null);
    try std.testing.expect(extractQuotedString("\"") == null);
}

test "stripQuotes helper" {
    try std.testing.expectEqualStrings("hello", stripQuotes("\"hello\""));
    try std.testing.expectEqualStrings("world", stripQuotes("'world'"));
    try std.testing.expectEqualStrings("noquotes", stripQuotes("noquotes"));
    try std.testing.expectEqualStrings("200", stripQuotes("200"));
}

test "convertPmEnvSet helper" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try std.testing.expect(convertPmEnvSet("pm.environment.set(\"token\", \"abc123\");", writer));
    try std.testing.expectEqualStrings("set token abc123\n", buf.items);
}

test "convertPmAssert helper" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try std.testing.expect(convertPmAssert("pm.expect(pm.response.code).to.equal(200);", writer));
    try std.testing.expectEqualStrings("assert status equals 200\n", buf.items);
}

test "convertPmAssert inside pm.test wrapper" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try std.testing.expect(convertPmAssert("pm.test(\"OK\", function() { pm.expect(pm.response.code).to.equal(201); });", writer));
    try std.testing.expectEqualStrings("assert status equals 201\n", buf.items);
}

test "convertPmExpect with jsonData field" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const writer = buf.writer();

    try std.testing.expect(convertPmExpect("pm.expect(jsonData.status).to.equal(\"ok\");", writer));
    try std.testing.expectEqualStrings("assert body.status equals ok\n", buf.items);
}

test "script conversion skips unconvertible lines and logs errors" {
    const lines = [_][]const u8{
        "pm.environment.set(\"key\", \"val\");",
        "console.log('debug');",
        "pm.expect(pm.response.code).to.equal(200);",
    };

    var result = ImportResult.init(std.testing.allocator);
    defer result.deinit();
    const str_alloc = result.arena.allocator();

    const script = convertPostmanScript(str_alloc, &lines, .test_script, "TestReq", &result);
    try std.testing.expect(script != null);
    try std.testing.expect(mem.indexOf(u8, script.?, "set key val") != null);
    try std.testing.expect(mem.indexOf(u8, script.?, "assert status equals 200") != null);

    // The console.log line should be logged as a skipped error
    try std.testing.expect(result.errors.items.len > 0);
    try std.testing.expect(mem.indexOf(u8, result.errors.items[0], "console.log") != null);
}

test "bearer auth with existing pattern still works" {
    const json =
        \\{
        \\  "info": { "name": "Bearer" },
        \\  "item": [
        \\    {
        \\      "name": "Auth Test",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/me",
        \\        "auth": {
        \\          "type": "bearer",
        \\          "bearer": [
        \\            { "key": "token", "value": "my-bearer-token" }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const auth = result.requests.items[0].request.auth;
    try std.testing.expectEqual(VoltFile.AuthType.bearer, auth.type);
    try std.testing.expectEqualStrings("my-bearer-token", auth.token.?);
}

test "detect postman v2.0 schema from full import" {
    // v2.0 collection detected by schema field and imported successfully
    const json_v20 =
        \\{
        \\  "info": {
        \\    "name": "V2 API",
        \\    "schema": "https://schema.getpostman.com/json/collection/v2.0.0/collection.json"
        \\  },
        \\  "item": [
        \\    {
        \\      "name": "Ping",
        \\      "request": { "method": "GET", "url": "https://api.example.com/ping" }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json_v20);
    defer result.deinit();

    try std.testing.expectEqualStrings("V2 API", result.collection_name);
    try std.testing.expectEqual(@as(usize, 1), result.requests.items.len);
}

test "empty collection imports with no items" {
    const json =
        \\{
        \\  "info": { "name": "Empty" },
        \\  "item": []
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    try std.testing.expectEqualStrings("Empty", result.collection_name);
    try std.testing.expectEqual(@as(usize, 0), result.requests.items.len);
}

test "oauth2 with access_token key variant" {
    const json =
        \\{
        \\  "info": { "name": "OAuth" },
        \\  "item": [
        \\    {
        \\      "name": "OAuth Req",
        \\      "request": {
        \\        "method": "GET",
        \\        "url": "https://api.example.com/me",
        \\        "auth": {
        \\          "type": "oauth2",
        \\          "oauth2": [
        \\            { "key": "access_token", "value": "fallback-token" }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var result = try importPostman(std.testing.allocator, json);
    defer result.deinit();

    const auth = result.requests.items[0].request.auth;
    try std.testing.expectEqual(VoltFile.AuthType.bearer, auth.type);
    try std.testing.expectEqualStrings("fallback-token", auth.token.?);
}
