const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");

// ── HAR (HTTP Archive 1.2) Format Support ───────────────────────────────
// Export request/response pairs to HAR JSON format.
// Import HAR files and convert to .volt format.

pub const HeaderPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const HarEntry = struct {
    method: []const u8,
    url: []const u8,
    status_code: u16,
    status_text: []const u8,
    request_headers: std.ArrayList(HeaderPair),
    response_headers: std.ArrayList(HeaderPair),
    request_body: ?[]const u8 = null,
    response_body: ?[]const u8 = null,
    timing_ms: f64,
    started: []const u8, // ISO 8601 timestamp

    pub fn init(allocator: Allocator) HarEntry {
        return .{
            .method = "GET",
            .url = "",
            .status_code = 0,
            .status_text = "",
            .request_headers = std.ArrayList(HeaderPair).init(allocator),
            .response_headers = std.ArrayList(HeaderPair).init(allocator),
            .timing_ms = 0,
            .started = "1970-01-01T00:00:00.000Z",
        };
    }

    pub fn deinit(self: *HarEntry) void {
        self.request_headers.deinit();
        self.response_headers.deinit();
    }
};

/// Export a single request/response pair to a HAR JSON entry string
pub fn exportEntry(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    response: *const HttpClient.Response,
) ![]const u8 {
    var entry = try buildEntry(allocator, request, response);
    defer entry.deinit();

    // Build just the entry JSON directly (single entry export)

    // Build just the entry JSON
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writeEntryJson(writer, &entry);

    return buf.toOwnedSlice();
}

/// Export a complete HAR file with multiple entries
pub fn exportHar(allocator: Allocator, entries: []const HarEntry) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("{\n");
    try writer.writeAll("  \"log\": {\n");
    try writer.writeAll("    \"version\": \"1.2\",\n");
    try writer.writeAll("    \"creator\": {\n");
    try writer.writeAll("      \"name\": \"Volt\",\n");
    try writer.writeAll("      \"version\": \"0.3.0\"\n");
    try writer.writeAll("    },\n");
    try writer.writeAll("    \"entries\": [\n");

    for (entries, 0..) |*entry, i| {
        if (i > 0) try writer.writeAll(",\n");
        try writer.writeAll("      ");
        try writeEntryJson(writer, entry);
    }

    try writer.writeAll("\n    ]\n");
    try writer.writeAll("  }\n");
    try writer.writeAll("}\n");

    return buf.toOwnedSlice();
}

/// Build a HarEntry from a request/response pair
pub fn buildEntry(
    allocator: Allocator,
    request: *const VoltFile.VoltRequest,
    response: *const HttpClient.Response,
) !HarEntry {
    var entry = HarEntry.init(allocator);

    entry.method = request.method.toString();
    entry.url = request.url;
    entry.status_code = response.status_code;
    entry.status_text = HttpClient.httpStatusText(response.status_code);
    entry.timing_ms = response.timing.total_ms;
    entry.started = "2024-01-01T00:00:00.000Z";

    // Copy request headers
    for (request.headers.items) |h| {
        try entry.request_headers.append(.{ .name = h.name, .value = h.value });
    }

    // Copy response headers
    for (response.headers.items) |h| {
        try entry.response_headers.append(.{ .name = h.name, .value = h.value });
    }

    // Body content
    entry.request_body = request.body;
    if (response.body.items.len > 0) {
        entry.response_body = response.bodySlice();
    }

    return entry;
}

/// Import HAR JSON and generate .volt file content for each entry
pub fn importHar(allocator: Allocator, har_json: []const u8) !std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (results.items) |item| {
            allocator.free(item);
        }
        results.deinit();
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, har_json, .{}) catch
        return results;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return results;

    // Navigate to log.entries
    const log = root.object.get("log") orelse return results;
    if (log != .object) return results;

    const entries = log.object.get("entries") orelse return results;
    if (entries != .array) return results;

    for (entries.array.items) |entry_val| {
        if (entry_val != .object) continue;

        var volt_buf = std.ArrayList(u8).init(allocator);
        const writer = volt_buf.writer();

        // Extract request info
        if (entry_val.object.get("request")) |req_obj| {
            if (req_obj != .object) continue;

            // Method
            if (req_obj.object.get("method")) |method_val| {
                if (method_val == .string) {
                    writer.print("method: {s}\n", .{method_val.string}) catch continue;
                }
            }

            // URL
            if (req_obj.object.get("url")) |url_val| {
                if (url_val == .string) {
                    writer.print("url: {s}\n", .{url_val.string}) catch continue;
                }
            }

            // Headers
            if (req_obj.object.get("headers")) |headers_val| {
                if (headers_val == .array and headers_val.array.items.len > 0) {
                    writer.writeAll("headers:\n") catch continue;
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
                            writer.print("  - {s}: {s}\n", .{ hname, hvalue }) catch continue;
                        }
                    }
                }
            }

            // Body (postData)
            if (req_obj.object.get("postData")) |post_data| {
                if (post_data == .object) {
                    if (post_data.object.get("text")) |text_val| {
                        if (text_val == .string and text_val.string.len > 0) {
                            writer.writeAll("body:\n") catch continue;
                            // Detect type from mimeType
                            if (post_data.object.get("mimeType")) |mime_val| {
                                if (mime_val == .string) {
                                    if (mem.indexOf(u8, mime_val.string, "json") != null) {
                                        writer.writeAll("  type: json\n") catch continue;
                                    } else if (mem.indexOf(u8, mime_val.string, "xml") != null) {
                                        writer.writeAll("  type: xml\n") catch continue;
                                    } else if (mem.indexOf(u8, mime_val.string, "form") != null) {
                                        writer.writeAll("  type: form\n") catch continue;
                                    } else {
                                        writer.writeAll("  type: raw\n") catch continue;
                                    }
                                }
                            }
                            writer.print("  content: {s}\n", .{text_val.string}) catch continue;
                        }
                    }
                }
            }
        }

        // Add test based on response status if available
        if (entry_val.object.get("response")) |resp_obj| {
            if (resp_obj == .object) {
                if (resp_obj.object.get("status")) |status_val| {
                    if (status_val == .integer) {
                        writer.writeAll("tests:\n") catch continue;
                        writer.print("  - status equals {d}\n", .{status_val.integer}) catch continue;
                    }
                }
            }
        }

        const volt_content = volt_buf.toOwnedSlice() catch continue;
        results.append(volt_content) catch {
            allocator.free(volt_content);
            continue;
        };
    }

    return results;
}

// ── Internal Helpers ────────────────────────────────────────────────────

fn writeEntryJson(writer: anytype, entry: *const HarEntry) !void {
    try writer.writeAll("{\n");
    try writer.print("        \"startedDateTime\": \"{s}\",\n", .{entry.started});
    try writer.print("        \"time\": {d:.2},\n", .{entry.timing_ms});

    // Request
    try writer.writeAll("        \"request\": {\n");
    try writer.print("          \"method\": \"{s}\",\n", .{entry.method});
    try writer.print("          \"url\": \"{s}\",\n", .{entry.url});

    // Request headers
    try writer.writeAll("          \"headers\": [");
    for (entry.request_headers.items, 0..) |h, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{{\"name\": \"{s}\", \"value\": \"{s}\"}}", .{ h.name, h.value });
    }
    try writer.writeAll("]");

    // Request body
    if (entry.request_body) |body| {
        try writer.writeAll(",\n          \"postData\": {\n");
        try writer.writeAll("            \"mimeType\": \"application/json\",\n");
        try writer.writeAll("            \"text\": \"");
        try writeJsonEscaped(writer, body);
        try writer.writeAll("\"\n");
        try writer.writeAll("          }");
    }
    try writer.writeAll("\n        },\n");

    // Response
    try writer.writeAll("        \"response\": {\n");
    try writer.print("          \"status\": {d},\n", .{entry.status_code});
    try writer.print("          \"statusText\": \"{s}\",\n", .{entry.status_text});

    // Response headers
    try writer.writeAll("          \"headers\": [");
    for (entry.response_headers.items, 0..) |h, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("{{\"name\": \"{s}\", \"value\": \"{s}\"}}", .{ h.name, h.value });
    }
    try writer.writeAll("],\n");

    // Response content
    try writer.writeAll("          \"content\": {\n");
    if (entry.response_body) |body| {
        try writer.print("            \"size\": {d},\n", .{body.len});
        try writer.writeAll("            \"mimeType\": \"application/json\",\n");
        try writer.writeAll("            \"text\": \"");
        try writeJsonEscaped(writer, body);
        try writer.writeAll("\"\n");
    } else {
        try writer.writeAll("            \"size\": 0,\n");
        try writer.writeAll("            \"mimeType\": \"application/octet-stream\",\n");
        try writer.writeAll("            \"text\": \"\"\n");
    }
    try writer.writeAll("          }\n");
    try writer.writeAll("        },\n");

    // Timings
    try writer.writeAll("        \"timings\": {\n");
    try writer.writeAll("          \"send\": 0,\n");
    try writer.print("          \"wait\": {d:.2},\n", .{entry.timing_ms});
    try writer.writeAll("          \"receive\": 0\n");
    try writer.writeAll("        }\n");
    try writer.writeAll("      }");
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
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
}

// ── Tests ───────────────────────────────────────────────────────────────

test "export entry produces valid HAR JSON" {
    var req = VoltFile.VoltRequest.init(std.testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/users";
    try req.addHeader("Accept", "application/json");

    var resp = HttpClient.Response.init(std.testing.allocator);
    defer resp.deinit();
    resp.status_code = 200;
    resp.timing.total_ms = 123.45;
    try resp.headers.append(.{ .name = "Content-Type", .value = "application/json" });
    try resp.body.appendSlice("{\"users\": []}");

    const result = try exportEntry(std.testing.allocator, &req, &resp);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "\"method\": \"GET\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"url\": \"https://api.example.com/users\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"status\": 200") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"statusText\": \"OK\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"startedDateTime\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"timings\"") != null);
}

test "import basic HAR file" {
    const har_json =
        \\{
        \\  "log": {
        \\    "version": "1.2",
        \\    "creator": { "name": "Test", "version": "1.0" },
        \\    "entries": [
        \\      {
        \\        "request": {
        \\          "method": "POST",
        \\          "url": "https://api.example.com/data",
        \\          "headers": [
        \\            { "name": "Content-Type", "value": "application/json" }
        \\          ],
        \\          "postData": {
        \\            "mimeType": "application/json",
        \\            "text": "{\"key\": \"value\"}"
        \\          }
        \\        },
        \\        "response": {
        \\          "status": 201,
        \\          "statusText": "Created",
        \\          "headers": [],
        \\          "content": { "size": 0, "text": "" }
        \\        }
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    var results = try importHar(std.testing.allocator, har_json);
    defer {
        for (results.items) |item| {
            std.testing.allocator.free(item);
        }
        results.deinit();
    }

    try std.testing.expectEqual(@as(usize, 1), results.items.len);

    const volt_content = results.items[0];
    try std.testing.expect(mem.indexOf(u8, volt_content, "method: POST") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "url: https://api.example.com/data") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "Content-Type: application/json") != null);
    try std.testing.expect(mem.indexOf(u8, volt_content, "type: json") != null);
}
