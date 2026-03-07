const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");
const WebApi = @import("web_api.zig");

// ── Web Server ──────────────────────────────────────────────────────────
//
// Embedded HTTP server for the Volt Web UI.
// Serves static assets (HTML/CSS/JS) compiled into the binary via @embedFile,
// and routes /api/* requests to web_api.zig handlers.
//
// Two modes:
//   volt ui    → 127.0.0.1 (local only, opens browser)
//   volt serve → 0.0.0.0   (network-accessible, self-hosted)

// Static files embedded at compile time — single binary, zero external files
const index_html = @embedFile("web/index.html");
const style_css = @embedFile("web/style.css");
const app_js = @embedFile("web/app.js");
const manifest_json = @embedFile("web/manifest.json");
const sw_js = @embedFile("web/sw.js");

pub const WebServer = struct {
    allocator: Allocator,
    port: u16,
    host: Host,
    api: WebApi.ApiHandler,

    pub const Host = enum {
        local, // 127.0.0.1 — volt ui
        public, // 0.0.0.0 — volt serve
    };

    pub fn init(allocator: Allocator, port: u16, host: Host) WebServer {
        return .{
            .allocator = allocator,
            .port = port,
            .host = host,
            .api = WebApi.ApiHandler.init(allocator),
        };
    }

    pub fn deinit(self: *WebServer) void {
        self.api.deinit();
    }

    /// Start serving. Blocks until Ctrl-C.
    pub fn serve(self: *WebServer) !void {
        const stdout = std.io.getStdOut().writer();

        const ip = switch (self.host) {
            .local => [4]u8{ 127, 0, 0, 1 },
            .public => [4]u8{ 0, 0, 0, 0 },
        };

        const address = std.net.Address.initIp4(ip, self.port);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        const host_str: []const u8 = switch (self.host) {
            .local => "127.0.0.1",
            .public => "0.0.0.0",
        };

        try stdout.print(
            \\
            \\  {s}Volt Web UI{s} running on http://{s}:{d}
            \\
            \\  Open in your browser to start making requests.
            \\  Press Ctrl+C to stop.
            \\
            \\
        , .{ "\x1b[1m", "\x1b[0m", host_str, self.port });

        while (true) {
            const conn = server.accept() catch continue;
            self.handleConnection(conn) catch continue;
        }
    }

    fn handleConnection(self: *WebServer, conn: std.net.Server.Connection) !void {
        defer conn.stream.close();

        var buf: [16384]u8 = undefined;
        var http_server = std.http.Server.init(conn, &buf);

        var request = http_server.receiveHead() catch return;

        const target = request.head.target;
        const path = if (mem.indexOf(u8, target, "?")) |q| target[0..q] else target;
        const query = if (mem.indexOf(u8, target, "?")) |q| target[q + 1 ..] else "";

        // Handle CORS preflight
        if (request.head.method == .OPTIONS) {
            try self.sendCorsResponse(&request, "");
            return;
        }

        // Route: static files
        if (mem.eql(u8, path, "/") or mem.eql(u8, path, "/index.html")) {
            try self.sendStatic(&request, index_html, "text/html; charset=utf-8");
            return;
        }
        if (mem.eql(u8, path, "/style.css")) {
            try self.sendStatic(&request, style_css, "text/css; charset=utf-8");
            return;
        }
        if (mem.eql(u8, path, "/app.js")) {
            try self.sendStatic(&request, app_js, "application/javascript; charset=utf-8");
            return;
        }
        if (mem.eql(u8, path, "/manifest.json")) {
            try self.sendStatic(&request, manifest_json, "application/manifest+json; charset=utf-8");
            return;
        }
        if (mem.eql(u8, path, "/sw.js")) {
            try self.sendStatic(&request, sw_js, "application/javascript; charset=utf-8");
            return;
        }
        if (mem.eql(u8, path, "/favicon.ico")) {
            request.respond("", .{
                .status = .no_content,
                .extra_headers = &.{
                    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                },
            }) catch return;
            return;
        }

        // Route: API endpoints
        if (mem.startsWith(u8, path, "/api/")) {
            self.handleApiRoute(&request, path, query) catch |err| {
                const err_body = std.fmt.allocPrint(self.allocator, "{{\"error\": \"{s}\"}}", .{@errorName(err)}) catch return;
                defer self.allocator.free(err_body);
                self.sendJson(&request, err_body, .internal_server_error) catch return;
            };
            return;
        }

        // 404 for everything else
        self.sendJson(&request, "{\"error\": \"Not found\"}", .not_found) catch return;
    }

    fn handleApiRoute(self: *WebServer, request: *std.http.Server.Request, path: []const u8, query: []const u8) !void {
        // Read request body for POST/PUT
        var body: ?[]const u8 = null;
        defer if (body) |b| self.allocator.free(b);

        if (request.head.method == .POST or request.head.method == .PUT or request.head.method == .PATCH) {
            if (request.head.content_length) |len| {
                if (len > 0 and len <= 10 * 1024 * 1024) {
                    const buf = self.allocator.alloc(u8, len) catch null;
                    if (buf) |b| {
                        const reader = request.reader() catch {
                            self.allocator.free(b);
                            return;
                        };
                        const n = reader.readAll(b) catch 0;
                        if (n > 0) {
                            // Free the full allocation and dupe only the bytes read,
                            // so the defer free on body frees the correct size.
                            const trimmed = self.allocator.dupe(u8, b[0..n]) catch {
                                self.allocator.free(b);
                                return;
                            };
                            self.allocator.free(b);
                            body = trimmed;
                        } else {
                            self.allocator.free(b);
                        }
                    }
                }
            }
        }

        const result = self.api.handleRequest(path, request.head.method, body, query) catch |err| {
            const err_body = std.fmt.allocPrint(self.allocator, "{{\"error\": \"{s}\"}}", .{@errorName(err)}) catch return;
            defer self.allocator.free(err_body);
            try self.sendJson(request, err_body, .internal_server_error);
            return;
        };
        defer self.allocator.free(result);

        try self.sendJson(request, result, .ok);
    }

    fn sendStatic(self: *WebServer, request: *std.http.Server.Request, content: []const u8, content_type: []const u8) !void {
        _ = self;
        request.respond(content, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = content_type },
                .{ .name = "Cache-Control", .value = "no-cache" },
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                .{ .name = "X-Powered-By", .value = "Volt" },
            },
        }) catch return;
    }

    fn sendJson(self: *WebServer, request: *std.http.Server.Request, json_body: []const u8, status: std.http.Status) !void {
        _ = self;
        request.respond(json_body, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
                .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
                .{ .name = "X-Powered-By", .value = "Volt" },
            },
        }) catch return;
    }

    fn sendCorsResponse(self: *WebServer, request: *std.http.Server.Request, _: []const u8) !void {
        _ = self;
        request.respond("", .{
            .status = .no_content,
            .extra_headers = &.{
                .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                .{ .name = "Access-Control-Allow-Methods", .value = "GET, POST, PUT, DELETE, OPTIONS" },
                .{ .name = "Access-Control-Allow-Headers", .value = "Content-Type, Authorization" },
                .{ .name = "Access-Control-Max-Age", .value = "86400" },
            },
        }) catch return;
    }
};

// ── Browser Launcher ────────────────────────────────────────────────────

pub fn openBrowser(url: []const u8) void {
    const argv = switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "cmd", "/c", "start", url },
        .macos => &[_][]const u8{ "open", url },
        else => &[_][]const u8{ "xdg-open", url },
    };

    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.spawn() catch return;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "web server init" {
    const server = WebServer.init(std.testing.allocator, 8080, .local);
    _ = server;
}

test "web server public host" {
    const server = WebServer.init(std.testing.allocator, 3000, .public);
    _ = server;
}

test "embedded files are not empty" {
    try std.testing.expect(index_html.len > 0);
    try std.testing.expect(style_css.len > 0);
    try std.testing.expect(app_js.len > 0);
}

test "embedded html contains doctype" {
    try std.testing.expect(mem.indexOf(u8, index_html, "<!DOCTYPE") != null);
}

test "embedded css contains theme" {
    try std.testing.expect(mem.indexOf(u8, style_css, "data-theme") != null);
}

test "embedded js contains app" {
    try std.testing.expect(mem.indexOf(u8, app_js, "VoltApp") != null);
}
