const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── Mock Server ─────────────────────────────────────────────────────────

pub const MockRoute = struct {
    method: VoltFile.Method,
    path: []const u8,
    status_code: u16,
    content_type: []const u8,
    body: []const u8,
    headers: std.ArrayList(VoltFile.Header),

    pub fn init(allocator: Allocator) MockRoute {
        return .{
            .method = .GET,
            .path = "/",
            .status_code = 200,
            .content_type = "application/json",
            .body = "",
            .headers = std.ArrayList(VoltFile.Header).init(allocator),
        };
    }

    pub fn deinit(self: *MockRoute) void {
        self.headers.deinit();
    }
};

pub const MockServer = struct {
    allocator: Allocator,
    routes: std.ArrayList(MockRoute),
    port: u16,
    running: bool = false,

    pub fn init(allocator: Allocator, port: u16) MockServer {
        return .{
            .allocator = allocator,
            .routes = std.ArrayList(MockRoute).init(allocator),
            .port = port,
        };
    }

    pub fn deinit(self: *MockServer) void {
        for (self.routes.items) |*r| {
            r.deinit();
        }
        self.routes.deinit();
    }

    /// Load .volt files from a directory as mock routes
    pub fn loadCollection(self: *MockServer, dir_path: []const u8) !void {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".volt")) continue;
            if (mem.startsWith(u8, entry.name, "_")) continue; // skip _env.volt

            const file = dir.openFile(entry.name, .{}) catch continue;
            defer file.close();

            const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch continue;
            defer self.allocator.free(content);

            var request = VoltFile.parse(self.allocator, content) catch continue;
            defer request.deinit();

            // Extract path from URL
            const path = extractPath(request.url);

            var route = MockRoute.init(self.allocator);
            route.method = request.method;
            route.path = try self.allocator.dupe(u8, path);
            route.status_code = 200;

            // Use body from .volt file as mock response, or generate a default
            if (request.body) |body| {
                route.body = try self.allocator.dupe(u8, body);
                if (request.body_type == .json) {
                    route.content_type = "application/json";
                }
            } else {
                // Generate a simple JSON response
                const resp_body = try std.fmt.allocPrint(self.allocator, "{{\"message\": \"Mock response for {s} {s}\", \"status\": \"ok\"}}", .{ request.method.toString(), path });
                route.body = resp_body;
            }

            try self.routes.append(route);
        }
    }

    /// Find a matching route for a request
    pub fn findRoute(self: *const MockServer, method: VoltFile.Method, path: []const u8) ?*const MockRoute {
        for (self.routes.items) |*route| {
            if (route.method == method and matchPath(route.path, path)) {
                return route;
            }
        }
        // Try any-method match
        for (self.routes.items) |*route| {
            if (matchPath(route.path, path)) {
                return route;
            }
        }
        return null;
    }

    /// Start serving
    pub fn serve(self: *MockServer) !void {
        const stdout = std.io.getStdOut().writer();
        const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, self.port);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        self.running = true;

        try stdout.print("\x1b[1mVolt Mock Server\x1b[0m running on http://localhost:{d}\n\n", .{self.port});
        try stdout.print("Routes loaded: {d}\n", .{self.routes.items.len});
        for (self.routes.items) |route| {
            try stdout.print("  \x1b[36m{s}\x1b[0m {s}\n", .{ route.method.toString(), route.path });
        }
        try stdout.writeAll("\nPress Ctrl+C to stop\n\n");

        while (self.running) {
            const conn = server.accept() catch continue;
            self.handleConnection(conn, stdout) catch continue;
        }
    }

    fn handleConnection(self: *MockServer, conn: std.net.Server.Connection, log_writer: anytype) !void {
        defer conn.stream.close();

        var buf: [8192]u8 = undefined;
        var http_server = std.http.Server.init(conn, &buf);

        var request = http_server.receiveHead() catch return;

        // Parse method and path
        const method = httpMethodToVolt(request.head.method);
        const target = request.head.target;
        const path = if (mem.indexOf(u8, target, "?")) |q| target[0..q] else target;

        // Find matching route
        if (self.findRoute(method, path)) |route| {
            log_writer.print("\x1b[32m{s}\x1b[0m {s} -> {d}\n", .{ route.method.toString(), path, route.status_code }) catch {};

            request.respond(route.body, .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = route.content_type },
                    .{ .name = "X-Powered-By", .value = "Volt Mock Server" },
                    .{ .name = "Access-Control-Allow-Origin", .value = "*" },
                },
            }) catch return;
        } else {
            log_writer.print("\x1b[33m{s}\x1b[0m {s} -> 404\n", .{ @tagName(request.head.method), path }) catch {};

            // Respond with generic not-found JSON
            request.respond("{\"error\": \"No mock route found\"}", .{
                .status = .not_found,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/json" },
                    .{ .name = "X-Powered-By", .value = "Volt Mock Server" },
                },
            }) catch return;
        }
    }
};

fn httpMethodToVolt(method: std.http.Method) VoltFile.Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .HEAD => .HEAD,
        .OPTIONS => .OPTIONS,
        else => .GET,
    };
}

fn extractPath(url: []const u8) []const u8 {
    // Extract path from full URL, e.g., "https://api.example.com/users" -> "/users"
    if (mem.indexOf(u8, url, "://")) |scheme_end| {
        const after_scheme = url[scheme_end + 3 ..];
        if (mem.indexOf(u8, after_scheme, "/")) |path_start| {
            return after_scheme[path_start..];
        }
        return "/";
    }
    // Already a path
    if (url.len > 0 and url[0] == '/') return url;
    return "/";
}

fn matchPath(route_path: []const u8, request_path: []const u8) bool {
    // Exact match
    if (mem.eql(u8, route_path, request_path)) return true;

    // Simple wildcard: /users/:id matches /users/123
    var route_parts = mem.splitSequence(u8, route_path, "/");
    var req_parts = mem.splitSequence(u8, request_path, "/");

    while (true) {
        const route_part = route_parts.next();
        const req_part = req_parts.next();

        if (route_part == null and req_part == null) return true;
        if (route_part == null or req_part == null) return false;

        // :param matches anything
        if (route_part.?.len > 0 and route_part.?[0] == ':') continue;
        if (!mem.eql(u8, route_part.?, req_part.?)) return false;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "extract path from url" {
    try std.testing.expectEqualStrings("/users", extractPath("https://api.example.com/users"));
    try std.testing.expectEqualStrings("/users/123", extractPath("https://api.example.com/users/123"));
    try std.testing.expectEqualStrings("/", extractPath("https://api.example.com"));
    try std.testing.expectEqualStrings("/health", extractPath("/health"));
}

test "match path exact" {
    try std.testing.expect(matchPath("/users", "/users"));
    try std.testing.expect(!matchPath("/users", "/posts"));
}

test "match path with params" {
    try std.testing.expect(matchPath("/users/:id", "/users/123"));
    try std.testing.expect(matchPath("/users/:id/posts", "/users/123/posts"));
    try std.testing.expect(!matchPath("/users/:id", "/users/123/extra"));
}
