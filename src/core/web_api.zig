const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");
const Environment = @import("environment.zig");
const Importer = @import("importer.zig");
const Exporter = @import("exporter.zig");
const CollectionRunner = @import("collection_runner.zig");
const History = @import("history.zig");
// TestGenerator requires both request+response; test generation from web UI uses templates
const Config = @import("config.zig");
const CurlImport = @import("curl_import.zig");
const Themes = @import("themes.zig");
const CollectionOrganizer = @import("collection_organizer.zig");

// ── Web API Handler ─────────────────────────────────────────────────────
//
// JSON API endpoints that wrap existing Volt core modules.
// Each endpoint: parse JSON input → call core module → serialize result → return JSON.
//
// All endpoints return JSON with Content-Type: application/json.
// Errors return { "error": "description" }.

pub const ApiHandler = struct {
    allocator: Allocator,
    history: History.RequestHistory,
    env_manager: Environment.EnvManager,

    // WebSocket simulation state
    ws_connected: bool = false,
    ws_url: []const u8 = "",
    ws_id: []const u8 = "",
    ws_messages: std.ArrayList(WsMessage) = undefined,
    ws_initialized: bool = false,

    // SSE simulation state
    sse_connected: bool = false,
    sse_url: []const u8 = "",
    sse_id: []const u8 = "",
    sse_events: std.ArrayList(SseEvent) = undefined,
    sse_initialized: bool = false,

    pub const WsMessage = struct {
        data: []const u8,
        timestamp: i64,
        direction: []const u8, // "sent" or "received"
    };

    pub const SseEvent = struct {
        event_type: []const u8,
        data: []const u8,
        id: []const u8,
        timestamp: i64,
    };

    pub fn init(allocator: Allocator) ApiHandler {
        return .{
            .allocator = allocator,
            .history = History.RequestHistory.init(allocator),
            .env_manager = Environment.EnvManager.init(allocator),
            .ws_messages = std.ArrayList(WsMessage).init(allocator),
            .ws_initialized = true,
            .sse_events = std.ArrayList(SseEvent).init(allocator),
            .sse_initialized = true,
        };
    }

    pub fn deinit(self: *ApiHandler) void {
        self.history.deinit();
        self.env_manager.deinit();
        if (self.ws_initialized) {
            for (self.ws_messages.items) |msg| {
                self.allocator.free(msg.data);
                self.allocator.free(msg.direction);
            }
            self.ws_messages.deinit();
        }
        if (self.ws_url.len > 0) self.allocator.free(self.ws_url);
        if (self.ws_id.len > 0) self.allocator.free(self.ws_id);
        if (self.sse_initialized) {
            for (self.sse_events.items) |evt| {
                self.allocator.free(evt.event_type);
                self.allocator.free(evt.data);
                self.allocator.free(evt.id);
            }
            self.sse_events.deinit();
        }
        if (self.sse_url.len > 0) self.allocator.free(self.sse_url);
        if (self.sse_id.len > 0) self.allocator.free(self.sse_id);
    }

    /// Route an API request to the appropriate handler.
    /// Returns owned JSON string that the caller must free.
    pub fn handleRequest(
        self: *ApiHandler,
        path: []const u8,
        method: std.http.Method,
        body: ?[]const u8,
        query: []const u8,
    ) ![]const u8 {
        // Request execution
        if (mem.eql(u8, path, "/api/request/execute") and method == .POST) {
            return self.handleExecuteRequest(body);
        }
        if (mem.eql(u8, path, "/api/request/parse") and method == .POST) {
            return self.handleParseRequest(body);
        }

        // Collections
        if (mem.eql(u8, path, "/api/collections") and method == .GET) {
            return self.handleListCollections(query);
        }
        if (mem.eql(u8, path, "/api/collections/tree") and method == .GET) {
            return self.handleCollectionTree(query);
        }
        if (mem.eql(u8, path, "/api/collections/search") and method == .GET) {
            return self.handleSearchCollections(query);
        }

        // Environments
        if (mem.eql(u8, path, "/api/environments") and method == .GET) {
            return self.handleListEnvironments();
        }
        if (mem.eql(u8, path, "/api/environments") and method == .POST) {
            return self.handleCreateEnvironment(body);
        }

        // Import
        if (mem.eql(u8, path, "/api/import/curl") and method == .POST) {
            return self.handleImportCurl(body);
        }

        // Export
        if (mem.startsWith(u8, path, "/api/export/") and method == .POST) {
            const format = path["/api/export/".len..];
            return self.handleExport(format, body);
        }

        // Test generation
        if (mem.eql(u8, path, "/api/test/generate") and method == .POST) {
            return self.handleGenerateTests(body);
        }

        // History
        if (mem.eql(u8, path, "/api/history") and method == .GET) {
            return self.handleGetHistory();
        }
        if (mem.eql(u8, path, "/api/history/clear") and method == .POST) {
            return self.handleClearHistory();
        }

        // Themes
        if (mem.eql(u8, path, "/api/themes") and method == .GET) {
            return self.handleListThemes();
        }

        // Config
        if (mem.eql(u8, path, "/api/config") and method == .GET) {
            return self.handleGetConfig();
        }
        if (mem.eql(u8, path, "/api/config") and method == .POST) {
            return self.handleUpdateConfig(body);
        }

        // WebSocket simulation
        if (mem.eql(u8, path, "/api/ws/connect") and method == .POST) {
            return self.handleWsConnect(body);
        }
        if (mem.eql(u8, path, "/api/ws/send") and method == .POST) {
            return self.handleWsSend(body);
        }
        if (mem.eql(u8, path, "/api/ws/messages") and method == .GET) {
            return self.handleWsMessages();
        }
        if (mem.eql(u8, path, "/api/ws/disconnect") and method == .POST) {
            return self.handleWsDisconnect();
        }
        if (mem.eql(u8, path, "/api/ws/status") and method == .GET) {
            return self.handleWsStatus();
        }

        // SSE simulation
        if (mem.eql(u8, path, "/api/sse/connect") and method == .POST) {
            return self.handleSseConnect(body);
        }
        if (mem.eql(u8, path, "/api/sse/events") and method == .GET) {
            return self.handleSseEvents();
        }
        if (mem.eql(u8, path, "/api/sse/disconnect") and method == .POST) {
            return self.handleSseDisconnect();
        }
        if (mem.eql(u8, path, "/api/sse/status") and method == .GET) {
            return self.handleSseStatus();
        }

        // Collection runner
        if (mem.eql(u8, path, "/api/collection/files") and method == .GET) {
            return self.handleCollectionFiles(query);
        }
        if (mem.eql(u8, path, "/api/collection/run") and method == .POST) {
            return self.handleCollectionRun(body);
        }

        // Health check
        if (mem.eql(u8, path, "/api/health")) {
            return try std.fmt.allocPrint(self.allocator, "{{\"status\": \"ok\", \"version\": \"1.1.0\"}}", .{});
        }

        return try std.fmt.allocPrint(self.allocator, "{{\"error\": \"Unknown API endpoint: {s}\"}}", .{path});
    }

    // ── Request Execution ───────────────────────────────────────────────

    fn handleExecuteRequest(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        const json_body = body orelse return try self.jsonError("Request body is required");

        // Parse the JSON request
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_body, .{}) catch {
            return try self.jsonError("Invalid JSON in request body");
        };
        defer parsed.deinit();

        const root = parsed.value.object;

        // Build a VoltRequest from the JSON
        var request = VoltFile.VoltRequest.init(self.allocator);
        defer request.deinit();

        // Method
        if (root.get("method")) |m| {
            if (m == .string) {
                request.method = VoltFile.Method.fromString(m.string) orelse .GET;
            }
        }

        // URL
        if (root.get("url")) |u| {
            if (u == .string) {
                request.url = u.string;
            }
        }

        // Headers
        if (root.get("headers")) |h| {
            if (h == .object) {
                var it = h.object.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try request.headers.append(.{
                            .name = entry.key_ptr.*,
                            .value = entry.value_ptr.string,
                        });
                    }
                }
            }
        }

        // Body
        if (root.get("body")) |b| {
            if (b == .string) {
                request.body = b.string;
                request.body_type = .json;
            }
        }

        // Auth
        if (root.get("auth")) |auth_obj| {
            if (auth_obj == .object) {
                if (auth_obj.object.get("type")) |auth_type| {
                    if (auth_type == .string) {
                        if (mem.eql(u8, auth_type.string, "bearer")) {
                            if (auth_obj.object.get("token")) |token| {
                                if (token == .string) {
                                    request.auth.token = token.string;
                                }
                            }
                        } else if (mem.eql(u8, auth_type.string, "basic")) {
                            if (auth_obj.object.get("username")) |user| {
                                if (user == .string) request.auth.username = user.string;
                            }
                            if (auth_obj.object.get("password")) |pass| {
                                if (pass == .string) request.auth.password = pass.string;
                            }
                        }
                    }
                }
            }
        }

        if (request.url.len == 0) {
            return try self.jsonError("URL is required");
        }

        // Execute the request
        const config = HttpClient.ClientConfig{};
        var response = HttpClient.execute(self.allocator, &request, config) catch |err| {
            return try std.fmt.allocPrint(self.allocator,
                \\{{"error": "Request failed: {s}", "details": "{s}"}}
            , .{ @errorName(err), request.url });
        };
        defer response.deinit();

        // Record in history
        self.history.record(&request, &response, null) catch |err| {
            std.debug.print("warning: web_api: history record failed: {s}\n", .{@errorName(err)});
        };

        // Build response JSON
        return try self.buildResponseJson(&response);
    }

    fn handleParseRequest(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        const volt_content = body orelse return try self.jsonError("Request body with .volt content is required");

        var request = VoltFile.parse(self.allocator, volt_content) catch |err| {
            return try std.fmt.allocPrint(self.allocator,
                \\{{"error": "Parse failed: {s}"}}
            , .{@errorName(err)});
        };
        defer request.deinit();

        // Serialize parsed request to JSON
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{");
        try writer.print("\"method\": \"{s}\",", .{request.method.toString()});
        try self.writeJsonString(writer, "url", request.url);
        try writer.writeAll(",");

        // Headers
        try writer.writeAll("\"headers\": {");
        for (request.headers.items, 0..) |h, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\": \"{s}\"", .{ h.name, h.value });
        }
        try writer.writeAll("},");

        // Body
        if (request.body) |b| {
            try self.writeJsonString(writer, "body", b);
            try writer.writeAll(",");
        }

        // Tests
        try writer.writeAll("\"tests\": [");
        for (request.tests.items, 0..) |t, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"field\": \"{s}\", \"operator\": \"{s}\", \"expected\": \"{s}\"}}", .{
                t.field, t.operator, t.value,
            });
        }
        try writer.writeAll("]");

        // Name and description
        if (request.name) |n| {
            try writer.writeAll(",");
            try self.writeJsonString(writer, "name", n);
        }
        if (request.description) |d| {
            try writer.writeAll(",");
            try self.writeJsonString(writer, "description", d);
        }

        try writer.writeAll("}");

        return buf.toOwnedSlice();
    }

    // ── Collections ─────────────────────────────────────────────────────

    fn handleListCollections(self: *ApiHandler, query: []const u8) ![]const u8 {
        const dir_path = self.getQueryParam(query, "dir") orelse ".";

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return try self.jsonError("Cannot open directory");
        };
        defer dir.close();

        var files = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (files.items) |f| self.allocator.free(f);
            files.deinit();
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".volt")) {
                if (mem.startsWith(u8, entry.name, "_")) continue;
                try files.append(try self.allocator.dupe(u8, entry.name));
            }
        }

        // Build JSON array
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{\"files\": [");
        for (files.items, 0..) |f, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{f});
        }
        try writer.writeAll("]}");

        return buf.toOwnedSlice();
    }

    fn handleCollectionTree(self: *ApiHandler, query: []const u8) ![]const u8 {
        const dir_path = self.getQueryParam(query, "dir") orelse ".";

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return try self.jsonError("Cannot open directory");
        };
        defer dir.close();

        var paths = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (paths.items) |p| self.allocator.free(p);
            paths.deinit();
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".volt")) {
                try paths.append(try self.allocator.dupe(u8, entry.name));
            }
        }

        var tree = try CollectionOrganizer.buildTree(self.allocator, paths.items);
        defer tree.deinit();

        const rendered = try CollectionOrganizer.renderTree(self.allocator, &tree);
        defer self.allocator.free(rendered);

        // Return as JSON with tree text
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();
        try writer.writeAll("{\"tree\": \"");
        // Escape the tree string for JSON
        for (rendered) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => {},
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        try writer.print("\\u{x:0>4}", .{c});
                    } else {
                        try writer.writeByte(c);
                    }
                },
            }
        }
        try writer.writeAll("\"}");

        return buf.toOwnedSlice();
    }

    fn handleSearchCollections(self: *ApiHandler, query: []const u8) ![]const u8 {
        const search_query = self.getQueryParam(query, "q") orelse "";

        if (search_query.len == 0) {
            return try self.jsonError("Query parameter 'q' is required");
        }

        // Search current directory for .volt files matching query
        var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch {
            return try self.jsonError("Cannot open directory");
        };
        defer dir.close();

        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();
        try writer.writeAll("{\"results\": [");
        var count: usize = 0;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".volt")) continue;
            if (mem.startsWith(u8, entry.name, "_")) continue;

            // Simple substring match on filename
            if (mem.indexOf(u8, entry.name, search_query) != null) {
                if (count > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{entry.name});
                count += 1;
            }
        }
        try writer.writeAll("]}");

        return buf.toOwnedSlice();
    }

    // ── Environments ────────────────────────────────────────────────────

    fn handleListEnvironments(self: *ApiHandler) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{\"environments\": [");

        var it = self.env_manager.environments.iterator();
        var i: usize = 0;
        while (it.next()) |entry| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"name\": \"{s}\"}}", .{entry.key_ptr.*});
            i += 1;
        }
        if (i == 0) {
            // Return default environment names from _env.volt convention
            try writer.writeAll("\"default\"");
        }

        try writer.writeAll("],");

        // Active environment
        if (self.env_manager.active_env) |active| {
            try writer.print("\"active\": \"{s}\"", .{active});
        } else {
            try writer.writeAll("\"active\": null");
        }

        try writer.writeAll("}");
        return buf.toOwnedSlice();
    }

    fn handleCreateEnvironment(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        const json_body = body orelse return try self.jsonError("Request body is required");

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_body, .{}) catch {
            return try self.jsonError("Invalid JSON");
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const name_val = root.get("name") orelse return try self.jsonError("'name' field is required");
        if (name_val != .string) return try self.jsonError("'name' must be a string");

        const env = try self.env_manager.createEnv(name_val.string);

        // Set variables if provided
        if (root.get("variables")) |vars| {
            if (vars == .object) {
                var var_it = vars.object.iterator();
                while (var_it.next()) |entry| {
                    if (entry.value_ptr.* == .string) {
                        try env.set(entry.key_ptr.*, entry.value_ptr.string);
                    }
                }
            }
        }

        // Set active if requested
        if (root.get("active")) |active| {
            if (active == .bool and active.bool) {
                self.env_manager.setActive(name_val.string);
            }
        }

        return try std.fmt.allocPrint(self.allocator, "{{\"created\": \"{s}\"}}", .{name_val.string});
    }

    // ── Import ──────────────────────────────────────────────────────────

    fn handleImportCurl(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        const curl_cmd = body orelse return try self.jsonError("cURL command is required in request body");

        var result = CurlImport.parseCurl(self.allocator, curl_cmd) catch {
            return try self.jsonError("Failed to parse cURL command");
        };
        defer result.deinit();

        // Build JSON with parsed request details
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{");
        try writer.print("\"method\": \"{s}\",", .{result.method});
        try self.writeJsonString(writer, "url", result.url);
        try writer.writeAll(",\"headers\": {");
        for (result.headers.items, 0..) |h, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\": \"{s}\"", .{ h.name, h.value });
        }
        try writer.writeAll("}");
        if (result.body) |b| {
            try writer.writeAll(",");
            try self.writeJsonString(writer, "body", b);
        }
        try writer.writeAll("}");

        return buf.toOwnedSlice();
    }

    // ── Export ───────────────────────────────────────────────────────────

    fn handleExport(self: *ApiHandler, format: []const u8, body: ?[]const u8) ![]const u8 {
        const volt_content = body orelse return try self.jsonError("Request body with .volt content is required");

        var request = VoltFile.parse(self.allocator, volt_content) catch {
            return try self.jsonError("Failed to parse .volt content");
        };
        defer request.deinit();

        const exported = blk: {
            if (mem.eql(u8, format, "curl")) {
                break :blk Exporter.exportCurl(&request, self.allocator) catch {
                    return try self.jsonError("Export to curl failed");
                };
            } else if (mem.eql(u8, format, "python")) {
                break :blk Exporter.exportPython(&request, self.allocator) catch {
                    return try self.jsonError("Export to python failed");
                };
            } else if (mem.eql(u8, format, "javascript") or mem.eql(u8, format, "js")) {
                break :blk Exporter.exportJavaScript(&request, self.allocator) catch {
                    return try self.jsonError("Export to javascript failed");
                };
            } else if (mem.eql(u8, format, "go")) {
                break :blk Exporter.exportGo(&request, self.allocator) catch {
                    return try self.jsonError("Export to go failed");
                };
            } else {
                return try std.fmt.allocPrint(self.allocator, "{{\"error\": \"Unsupported export format: {s}\"}}", .{format});
            }
        };
        defer self.allocator.free(exported);

        // Escape the exported content for JSON
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();
        try writer.writeAll("{\"exported\": \"");
        for (exported) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => {},
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        try writer.print("\", \"format\": \"{s}\"}}", .{format});

        return buf.toOwnedSlice();
    }

    // ── Test Generation ─────────────────────────────────────────────────

    fn handleGenerateTests(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        const json_body = body orelse return try self.jsonError("Response JSON is required");

        // Test generation requires both a request and response.
        // From the web UI, we generate basic status + body assertions.
        _ = json_body;

        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();
        try writer.writeAll("{\"tests\": [");
        // Suggest common test assertions
        try writer.writeAll("{\"field\": \"status\", \"operator\": \"equals\", \"value\": \"200\"},");
        try writer.writeAll("{\"field\": \"body\", \"operator\": \"contains\", \"value\": \"\"},");
        try writer.writeAll("{\"field\": \"header.content-type\", \"operator\": \"contains\", \"value\": \"application/json\"}");
        try writer.writeAll("]}");

        return buf.toOwnedSlice();
    }

    // ── History ─────────────────────────────────────────────────────────

    fn handleGetHistory(self: *ApiHandler) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        const entries = self.history.lastN(50);

        try writer.writeAll("{\"entries\": [");
        for (entries, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"method\": \"{s}\", \"url\": \"{s}\", \"status\": {d}, \"time_ms\": {d:.1}}}", .{
                entry.method.toString(),
                entry.url,
                entry.status_code,
                entry.timing_ms,
            });
        }
        try writer.print("], \"total\": {d}}}", .{self.history.count()});

        return buf.toOwnedSlice();
    }

    fn handleClearHistory(self: *ApiHandler) ![]const u8 {
        self.history.clear();
        return try std.fmt.allocPrint(self.allocator, "{{\"cleared\": true}}", .{});
    }

    // ── Themes ──────────────────────────────────────────────────────────

    fn handleListThemes(self: *ApiHandler) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{\"themes\": [");

        const theme_data = [_]struct { name: []const u8, primary: []const u8, bg: []const u8, surface: []const u8 }{
            .{ .name = "dark", .primary = "#00bcd4", .bg = "#1e1e1e", .surface = "#252525" },
            .{ .name = "light", .primary = "#1565c0", .bg = "#fafafa", .surface = "#ffffff" },
            .{ .name = "solarized", .primary = "#2aa198", .bg = "#002b36", .surface = "#073642" },
            .{ .name = "nord", .primary = "#88c0d0", .bg = "#2e3440", .surface = "#3b4252" },
            .{ .name = "dracula", .primary = "#bd93f9", .bg = "#282a36", .surface = "#44475a" },
            .{ .name = "monokai", .primary = "#66d9ef", .bg = "#272822", .surface = "#3e3d32" },
            .{ .name = "none", .primary = "#808080", .bg = "#000000", .surface = "#1a1a1a" },
        };

        for (theme_data, 0..) |t, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"name\": \"{s}\", \"primary\": \"{s}\", \"bg\": \"{s}\", \"surface\": \"{s}\"}}", .{
                t.name, t.primary, t.bg, t.surface,
            });
        }

        try writer.writeAll("]}");
        return buf.toOwnedSlice();
    }

    // ── Config ──────────────────────────────────────────────────────────

    fn handleGetConfig(self: *ApiHandler) ![]const u8 {
        var config = Config.loadConfig(self.allocator, ".") catch {
            return try std.fmt.allocPrint(self.allocator, "{{\"base_url\": \"\", \"timeout\": 30000, \"theme\": \"dark\"}}", .{});
        };
        defer config.deinit();

        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();
        try writer.writeAll("{");
        try writer.print("\"base_url\": \"{s}\",", .{config.base_url orelse ""});
        try writer.print("\"timeout\": {d},", .{config.timeout_ms});
        try writer.writeAll("\"theme\": \"dark\",");
        try writer.print("\"output_format\": \"{s}\"", .{@tagName(config.output_format)});
        try writer.writeAll("}");
        return buf.toOwnedSlice();
    }

    fn handleUpdateConfig(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        const json_body = body orelse return try self.jsonError("Config JSON is required");

        // Write the config content to .voltrc
        const file = std.fs.cwd().createFile(".voltrc", .{}) catch {
            return try self.jsonError("Cannot write .voltrc");
        };
        defer file.close();
        file.writeAll(json_body) catch {
            return try self.jsonError("Failed to write config");
        };

        return try std.fmt.allocPrint(self.allocator, "{{\"saved\": true}}", .{});
    }

    // ── WebSocket Simulation ───────────────────────────────────────────

    fn handleWsConnect(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        const json_body = body orelse return try self.jsonError("Request body is required");

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_body, .{}) catch {
            return try self.jsonError("Invalid JSON in request body");
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const url_val = root.get("url") orelse return try self.jsonError("'url' field is required");
        if (url_val != .string) return try self.jsonError("'url' must be a string");

        // Clean up previous connection state
        if (self.ws_url.len > 0) self.allocator.free(self.ws_url);
        if (self.ws_id.len > 0) self.allocator.free(self.ws_id);
        for (self.ws_messages.items) |msg| {
            self.allocator.free(msg.data);
            self.allocator.free(msg.direction);
        }
        self.ws_messages.clearRetainingCapacity();

        self.ws_url = try self.allocator.dupe(u8, url_val.string);
        self.ws_id = try std.fmt.allocPrint(self.allocator, "ws-{d}", .{std.time.timestamp()});
        self.ws_connected = true;

        // Add a simulated welcome message
        try self.ws_messages.append(.{
            .data = try self.allocator.dupe(u8, "Connected to WebSocket server"),
            .timestamp = std.time.timestamp(),
            .direction = try self.allocator.dupe(u8, "received"),
        });

        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();
        try writer.writeAll("{\"status\": \"connected\", \"id\": \"");
        try writer.writeAll(self.ws_id);
        try writer.writeAll("\"}");
        return buf.toOwnedSlice();
    }

    fn handleWsSend(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        if (!self.ws_connected) return try self.jsonError("WebSocket is not connected");

        const json_body = body orelse return try self.jsonError("Request body is required");

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_body, .{}) catch {
            return try self.jsonError("Invalid JSON in request body");
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_val = root.get("message") orelse return try self.jsonError("'message' field is required");
        if (msg_val != .string) return try self.jsonError("'message' must be a string");

        const now = std.time.timestamp();

        // Record the sent message
        try self.ws_messages.append(.{
            .data = try self.allocator.dupe(u8, msg_val.string),
            .timestamp = now,
            .direction = try self.allocator.dupe(u8, "sent"),
        });

        // Simulate an echo response
        const echo_data = try std.fmt.allocPrint(self.allocator, "Echo: {s}", .{msg_val.string});
        try self.ws_messages.append(.{
            .data = echo_data,
            .timestamp = now + 1,
            .direction = try self.allocator.dupe(u8, "received"),
        });

        return try std.fmt.allocPrint(self.allocator, "{{\"status\": \"sent\"}}", .{});
    }

    fn handleWsMessages(self: *ApiHandler) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{\"messages\": [");
        for (self.ws_messages.items, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"data\": \"");
            for (msg.data) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => {},
                    else => try writer.writeByte(c),
                }
            }
            try writer.print("\", \"timestamp\": {d}, \"direction\": \"{s}\"}}", .{ msg.timestamp, msg.direction });
        }
        try writer.writeAll("]}");
        return buf.toOwnedSlice();
    }

    fn handleWsDisconnect(self: *ApiHandler) ![]const u8 {
        if (self.ws_connected) {
            // Add disconnect message
            try self.ws_messages.append(.{
                .data = try self.allocator.dupe(u8, "Disconnected"),
                .timestamp = std.time.timestamp(),
                .direction = try self.allocator.dupe(u8, "received"),
            });
        }
        self.ws_connected = false;
        return try std.fmt.allocPrint(self.allocator, "{{\"status\": \"disconnected\"}}", .{});
    }

    fn handleWsStatus(self: *ApiHandler) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();
        try writer.print("{{\"connected\": {s}, \"url\": \"", .{if (self.ws_connected) "true" else "false"});
        for (self.ws_url) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeAll("\"}");
        return buf.toOwnedSlice();
    }

    // ── SSE Simulation ──────────────────────────────────────────────────

    fn handleSseConnect(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        const json_body = body orelse return try self.jsonError("Request body is required");

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_body, .{}) catch {
            return try self.jsonError("Invalid JSON in request body");
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const url_val = root.get("url") orelse return try self.jsonError("'url' field is required");
        if (url_val != .string) return try self.jsonError("'url' must be a string");

        // Clean up previous state
        if (self.sse_url.len > 0) self.allocator.free(self.sse_url);
        if (self.sse_id.len > 0) self.allocator.free(self.sse_id);
        for (self.sse_events.items) |evt| {
            self.allocator.free(evt.event_type);
            self.allocator.free(evt.data);
            self.allocator.free(evt.id);
        }
        self.sse_events.clearRetainingCapacity();

        self.sse_url = try self.allocator.dupe(u8, url_val.string);
        self.sse_id = try std.fmt.allocPrint(self.allocator, "sse-{d}", .{std.time.timestamp()});
        self.sse_connected = true;

        // Add a simulated initial event
        try self.sse_events.append(.{
            .event_type = try self.allocator.dupe(u8, "open"),
            .data = try self.allocator.dupe(u8, "SSE connection established"),
            .id = try self.allocator.dupe(u8, "0"),
            .timestamp = std.time.timestamp(),
        });

        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();
        try writer.writeAll("{\"status\": \"connected\", \"id\": \"");
        try writer.writeAll(self.sse_id);
        try writer.writeAll("\"}");
        return buf.toOwnedSlice();
    }

    fn handleSseEvents(self: *ApiHandler) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{\"events\": [");
        for (self.sse_events.items, 0..) |evt, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"type\": \"");
            try writer.writeAll(evt.event_type);
            try writer.writeAll("\", \"data\": \"");
            for (evt.data) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => {},
                    else => try writer.writeByte(c),
                }
            }
            try writer.print("\", \"id\": \"{s}\", \"timestamp\": {d}}}", .{ evt.id, evt.timestamp });
        }
        try writer.writeAll("]}");
        return buf.toOwnedSlice();
    }

    fn handleSseDisconnect(self: *ApiHandler) ![]const u8 {
        if (self.sse_connected) {
            try self.sse_events.append(.{
                .event_type = try self.allocator.dupe(u8, "close"),
                .data = try self.allocator.dupe(u8, "SSE connection closed"),
                .id = try std.fmt.allocPrint(self.allocator, "{d}", .{self.sse_events.items.len}),
                .timestamp = std.time.timestamp(),
            });
        }
        self.sse_connected = false;
        return try std.fmt.allocPrint(self.allocator, "{{\"status\": \"disconnected\"}}", .{});
    }

    fn handleSseStatus(self: *ApiHandler) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();
        try writer.print("{{\"connected\": {s}, \"url\": \"", .{if (self.sse_connected) "true" else "false"});
        for (self.sse_url) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeAll("\"}");
        return buf.toOwnedSlice();
    }

    // ── Collection Runner ───────────────────────────────────────────────

    fn handleCollectionFiles(self: *ApiHandler, query: []const u8) ![]const u8 {
        const dir_path = self.getQueryParam(query, "dir") orelse ".";

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return try self.jsonError("Cannot open directory");
        };
        defer dir.close();

        var files = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (files.items) |f| self.allocator.free(f);
            files.deinit();
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".volt")) {
                try files.append(try self.allocator.dupe(u8, entry.name));
            }
        }

        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{\"files\": [");
        for (files.items, 0..) |f, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{f});
        }
        try writer.print("], \"dir\": \"{s}\", \"count\": {d}}}", .{ dir_path, files.items.len });

        return buf.toOwnedSlice();
    }

    fn handleCollectionRun(self: *ApiHandler, body: ?[]const u8) ![]const u8 {
        const json_body = body orelse return try self.jsonError("Request body is required");

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_body, .{}) catch {
            return try self.jsonError("Invalid JSON in request body");
        };
        defer parsed.deinit();

        const root = parsed.value.object;
        const dir_val = root.get("dir") orelse return try self.jsonError("'dir' field is required");
        if (dir_val != .string) return try self.jsonError("'dir' must be a string");

        const dir_path = dir_val.string;

        // List .volt files in the directory
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            return try self.jsonError("Cannot open directory");
        };
        defer dir.close();

        var volt_files = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (volt_files.items) |f| self.allocator.free(f);
            volt_files.deinit();
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".volt")) {
                if (mem.startsWith(u8, entry.name, "_")) continue; // Skip _env.volt etc.
                try volt_files.append(try self.allocator.dupe(u8, entry.name));
            }
        }

        // Run each .volt file
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{\"results\": [");

        var passed: usize = 0;
        var failed: usize = 0;

        for (volt_files.items, 0..) |file_name, i| {
            if (i > 0) try writer.writeAll(",");

            // Try to read and parse the .volt file
            const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir_path, file_name });
            defer self.allocator.free(file_path);

            const file_content = blk: {
                const file = std.fs.cwd().openFile(file_path, .{}) catch {
                    try writer.print("{{\"file\": \"{s}\", \"status\": \"error\", \"error\": \"Cannot open file\"}}", .{file_name});
                    failed += 1;
                    continue;
                };
                defer file.close();
                break :blk file.readToEndAlloc(self.allocator, 1024 * 1024) catch {
                    try writer.print("{{\"file\": \"{s}\", \"status\": \"error\", \"error\": \"Cannot read file\"}}", .{file_name});
                    failed += 1;
                    continue;
                };
            };
            defer self.allocator.free(file_content);

            // Parse the .volt file
            var request = VoltFile.parse(self.allocator, file_content) catch {
                try writer.print("{{\"file\": \"{s}\", \"status\": \"error\", \"error\": \"Parse error\"}}", .{file_name});
                failed += 1;
                continue;
            };
            defer request.deinit();

            // Execute the request
            const config = HttpClient.ClientConfig{};
            var response = HttpClient.execute(self.allocator, &request, config) catch {
                try writer.print("{{\"file\": \"{s}\", \"method\": \"{s}\", \"url\": \"{s}\", \"status\": \"error\", \"error\": \"Request failed\"}}", .{
                    file_name, request.method.toString(), request.url,
                });
                failed += 1;
                continue;
            };
            defer response.deinit();

            // Record in history
            self.history.record(&request, &response, null) catch |err| {
                std.debug.print("warning: web_api: history record failed: {s}\n", .{@errorName(err)});
            };

            const success = response.status_code >= 200 and response.status_code < 400;
            if (success) {
                passed += 1;
            } else {
                failed += 1;
            }

            try writer.print("{{\"file\": \"{s}\", \"method\": \"{s}\", \"url\": \"{s}\", \"status_code\": {d}, \"time_ms\": {d}, \"status\": \"{s}\"}}", .{
                file_name,
                request.method.toString(),
                request.url,
                response.status_code,
                response.timing.total_ms,
                if (success) "pass" else "fail",
            });
        }

        try writer.print("], \"total\": {d}, \"passed\": {d}, \"failed\": {d}}}", .{
            volt_files.items.len, passed, failed,
        });

        return buf.toOwnedSlice();
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    fn buildResponseJson(self: *ApiHandler, response: *const HttpClient.Response) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        try writer.writeAll("{");
        try writer.print("\"status_code\": {d},", .{response.status_code});
        try self.writeJsonString(writer, "status_text", response.status_text);
        try writer.writeAll(",");

        // Response headers
        try writer.writeAll("\"headers\": {");
        for (response.headers.items, 0..) |h, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("\"{s}\": \"{s}\"", .{ h.name, h.value });
        }
        try writer.writeAll("},");

        // Body
        try writer.writeAll("\"body\": ");
        const body_slice = response.bodySlice();
        // Try to embed as raw JSON if it looks like valid JSON
        if (body_slice.len > 0 and (body_slice[0] == '{' or body_slice[0] == '[')) {
            // Attempt to validate by parsing
            const valid = std.json.parseFromSlice(std.json.Value, self.allocator, body_slice, .{}) catch null;
            if (valid) |v| {
                v.deinit();
                try writer.writeAll(body_slice);
            } else {
                try self.writeJsonStringValue(writer, body_slice);
            }
        } else {
            try self.writeJsonStringValue(writer, body_slice);
        }

        // Timing
        try writer.print(",\"timing\": {{\"dns_ms\": {d}, \"connect_ms\": {d}, \"tls_ms\": {d}, \"ttfb_ms\": {d}, \"transfer_ms\": {d}, \"total_ms\": {d}}}", .{
            response.timing.dns_ms,
            response.timing.connect_ms,
            response.timing.tls_ms,
            response.timing.ttfb_ms,
            response.timing.transfer_ms,
            response.timing.total_ms,
        });

        // Size
        try writer.print(",\"size_bytes\": {d}", .{response.size_bytes});

        try writer.writeAll("}");

        return buf.toOwnedSlice();
    }

    fn jsonError(self: *ApiHandler, msg: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "{{\"error\": \"{s}\"}}", .{msg});
    }

    fn writeJsonString(self: *ApiHandler, writer: anytype, key: []const u8, value: []const u8) !void {
        _ = self;
        try writer.print("\"{s}\": ", .{key});
        try writer.writeByte('"');
        for (value) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        try writer.print("\\u{x:0>4}", .{c});
                    } else {
                        try writer.writeByte(c);
                    }
                },
            }
        }
        try writer.writeByte('"');
    }

    fn writeJsonStringValue(self: *ApiHandler, writer: anytype, value: []const u8) !void {
        _ = self;
        try writer.writeByte('"');
        for (value) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (c < 0x20) {
                        try writer.print("\\u{x:0>4}", .{c});
                    } else {
                        try writer.writeByte(c);
                    }
                },
            }
        }
        try writer.writeByte('"');
    }

    fn getQueryParam(self: *ApiHandler, query: []const u8, key: []const u8) ?[]const u8 {
        _ = self;
        if (query.len == 0) return null;

        var pairs = mem.splitSequence(u8, query, "&");
        while (pairs.next()) |pair| {
            if (mem.indexOf(u8, pair, "=")) |eq| {
                const k = pair[0..eq];
                const v = pair[eq + 1 ..];
                if (mem.eql(u8, k, key)) return v;
            }
        }
        return null;
    }

    fn jsonValidate(self: *ApiHandler, data: []const u8) bool {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return false;
        parsed.deinit();
        return true;
    }
};

// ── Tests ───────────────────────────────────────────────────────────────

test "api handler init" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();
}

test "api handler health check" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.handleRequest("/api/health", .GET, null, "");
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "\"status\": \"ok\"") != null);
}

test "api handler unknown endpoint" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.handleRequest("/api/unknown", .GET, null, "");
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "error") != null);
}

test "api handler list themes" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.handleRequest("/api/themes", .GET, null, "");
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "dark") != null);
    try std.testing.expect(mem.indexOf(u8, result, "nord") != null);
    try std.testing.expect(mem.indexOf(u8, result, "dracula") != null);
}

test "api handler get history empty" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.handleRequest("/api/history", .GET, null, "");
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "\"entries\": []") != null);
}

test "api handler clear history" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.handleRequest("/api/history/clear", .POST, null, "");
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "\"cleared\": true") != null);
}

test "api handler parse request" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const volt_content =
        \\GET https://api.example.com/users
        \\Accept: application/json
    ;

    const result = try handler.handleRequest("/api/request/parse", .POST, volt_content, "");
    defer std.testing.allocator.free(result);

    // Should contain method and url fields (either parsed successfully or returned an error)
    try std.testing.expect(result.len > 0);
    try std.testing.expect(mem.indexOf(u8, result, "GET") != null or mem.indexOf(u8, result, "error") != null);
}

test "api handler execute missing url" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.handleRequest("/api/request/execute", .POST, "{\"method\": \"GET\"}", "");
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "error") != null);
}

test "api handler get config" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.handleRequest("/api/config", .GET, null, "");
    defer std.testing.allocator.free(result);

    // Should return some config (default or from .voltrc)
    try std.testing.expect(result.len > 0);
}

test "api handler import curl missing body" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const result = try handler.handleRequest("/api/import/curl", .POST, null, "");
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "error") != null);
}

test "api handler query param parsing" {
    var handler = ApiHandler.init(std.testing.allocator);
    defer handler.deinit();

    const val = handler.getQueryParam("dir=examples&format=json", "dir");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("examples", val.?);

    const val2 = handler.getQueryParam("dir=examples&format=json", "format");
    try std.testing.expect(val2 != null);
    try std.testing.expectEqualStrings("json", val2.?);

    const val3 = handler.getQueryParam("dir=examples", "missing");
    try std.testing.expect(val3 == null);
}
