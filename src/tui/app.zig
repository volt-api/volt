const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const terminal = @import("terminal.zig");
const input = @import("input.zig");
const core = @import("volt-core");
const VoltFile = core.VoltFile;
const HttpClient = core.HttpClient;
const Environment = core.Environment;
const Formatter = core.Formatter;

// ── TUI Application ────────────────────────────────────────────────────

pub const Pane = enum {
    collection,
    request,
    response,
};

pub const RequestField = enum {
    method,
    url,
    headers,
    body,
};

pub const App = struct {
    allocator: Allocator,
    writer: terminal.Writer,
    running: bool = true,
    active_pane: Pane = .collection,
    term_size: terminal.TermSize,

    // Collection tree
    collection_files: std.ArrayList([]const u8),
    collection_selected: usize = 0,
    collection_scroll: usize = 0,
    collection_dir: []const u8 = ".",

    // Request state
    current_request: ?VoltFile.VoltRequest = null,
    current_file: ?[]const u8 = null,
    request_field: RequestField = .url,
    url_input: std.ArrayList(u8),
    url_cursor: usize = 0,
    method_index: usize = 0,

    // Response state
    current_response: ?HttpClient.Response = null,
    response_scroll: usize = 0,
    response_formatted: ?[]const u8 = null,

    // Environment
    env_manager: Environment.EnvManager,

    // Status
    status_message: ?[]const u8 = null,
    mode: enum { normal, insert, command } = .normal,
    command_buf: std.ArrayList(u8),

    const METHODS = [_]VoltFile.Method{ .GET, .POST, .PUT, .PATCH, .DELETE, .HEAD, .OPTIONS };
    const LEFT_PANE_WIDTH = 30;
    const DIVIDER_WIDTH = 1;

    pub fn init(allocator: Allocator, dir: []const u8) !App {
        var app = App{
            .allocator = allocator,
            .writer = terminal.Writer.init(allocator),
            .term_size = terminal.getTermSize(),
            .collection_files = std.ArrayList([]const u8).init(allocator),
            .url_input = std.ArrayList(u8).init(allocator),
            .env_manager = Environment.EnvManager.init(allocator),
            .command_buf = std.ArrayList(u8).init(allocator),
            .collection_dir = dir,
        };
        try app.scanCollection(dir);
        return app;
    }

    pub fn deinit(self: *App) void {
        self.writer.deinit();
        self.collection_files.deinit();
        if (self.current_request) |*req| req.deinit();
        if (self.current_response) |*resp| resp.deinit();
        self.url_input.deinit();
        self.env_manager.deinit();
        self.command_buf.deinit();
        if (self.response_formatted) |f| self.allocator.free(f);
    }

    pub fn scanCollection(self: *App, dir: []const u8) !void {
        self.collection_files.clearRetainingCapacity();

        var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch {
            return;
        };
        defer d.close();

        var iter = d.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                if (mem.endsWith(u8, entry.name, ".volt")) {
                    const name = try self.allocator.dupe(u8, entry.name);
                    try self.collection_files.append(name);
                }
            }
        }
    }

    pub fn run(self: *App) !void {
        input.enableRawMode();
        defer input.disableRawMode();

        try self.writer.hideCursor();
        defer {
            self.writer.showCursor() catch {};
            self.writer.resetStyle() catch {};
            self.writer.clearScreen() catch {};
            self.writer.moveTo(1, 1) catch {};
            self.writer.flush() catch {};
        }

        while (self.running) {
            self.term_size = terminal.getTermSize();
            try self.render();
            try self.writer.flush();

            const event = input.readKey();
            try self.handleInput(event);
        }
    }

    fn handleInput(self: *App, event: input.InputEvent) !void {
        switch (self.mode) {
            .normal => try self.handleNormalMode(event),
            .insert => try self.handleInsertMode(event),
            .command => try self.handleCommandMode(event),
        }
    }

    fn handleNormalMode(self: *App, event: input.InputEvent) !void {
        switch (event.key) {
            .ctrl_c, .ctrl_q => self.running = false,
            .tab => {
                self.active_pane = switch (self.active_pane) {
                    .collection => .request,
                    .request => .response,
                    .response => .collection,
                };
            },
            .char => switch (event.char) {
                'q' => self.running = false,
                'j' => try self.navigateDown(),
                'k' => try self.navigateUp(),
                'h' => {
                    self.active_pane = switch (self.active_pane) {
                        .response => .request,
                        .request => .collection,
                        .collection => .collection,
                    };
                },
                'l' => {
                    self.active_pane = switch (self.active_pane) {
                        .collection => .request,
                        .request => .response,
                        .response => .response,
                    };
                },
                'i' => {
                    if (self.active_pane == .request) {
                        self.mode = .insert;
                        self.status_message = "-- INSERT --";
                    }
                },
                ':' => {
                    self.mode = .command;
                    self.command_buf.clearRetainingCapacity();
                    self.status_message = ":";
                },
                'm' => {
                    // Cycle method
                    self.method_index = (self.method_index + 1) % METHODS.len;
                    if (self.current_request) |*req| {
                        req.method = METHODS[self.method_index];
                    }
                },
                'r' => {
                    // Re-send current request
                    if (self.current_request != null) {
                        try self.sendRequest();
                    }
                },
                'R' => {
                    // Refresh collection file list
                    try self.scanCollection(self.collection_dir);
                    self.status_message = "Refreshed";
                },
                'G' => {
                    // Jump to bottom of list
                    if (self.active_pane == .collection and self.collection_files.items.len > 0) {
                        self.collection_selected = self.collection_files.items.len - 1;
                    }
                },
                'g' => {
                    // Jump to top of list
                    if (self.active_pane == .collection) {
                        self.collection_selected = 0;
                        self.collection_scroll = 0;
                    }
                },
                else => {},
            },
            .enter => {
                if (self.active_pane == .collection) {
                    try self.loadSelectedRequest();
                } else if (self.active_pane == .request) {
                    try self.sendRequest();
                }
            },
            .up => try self.navigateUp(),
            .down => try self.navigateDown(),
            .left => {
                self.active_pane = switch (self.active_pane) {
                    .response => .request,
                    .request => .collection,
                    .collection => .collection,
                };
            },
            .right => {
                self.active_pane = switch (self.active_pane) {
                    .collection => .request,
                    .request => .response,
                    .response => .response,
                };
            },
            else => {},
        }
    }

    fn handleInsertMode(self: *App, event: input.InputEvent) !void {
        switch (event.key) {
            .escape => {
                self.mode = .normal;
                self.status_message = null;
            },
            .enter => try self.sendRequest(),
            .char => {
                try self.url_input.append(event.char);
                self.url_cursor += 1;
                if (self.current_request) |*req| {
                    req.url = self.url_input.items;
                }
            },
            .backspace => {
                if (self.url_input.items.len > 0) {
                    _ = self.url_input.pop();
                    if (self.url_cursor > 0) self.url_cursor -= 1;
                    if (self.current_request) |*req| {
                        req.url = self.url_input.items;
                    }
                }
            },
            .ctrl_c => {
                self.mode = .normal;
                self.status_message = null;
            },
            else => {},
        }
    }

    fn handleCommandMode(self: *App, event: input.InputEvent) !void {
        switch (event.key) {
            .escape => {
                self.mode = .normal;
                self.status_message = null;
            },
            .enter => {
                const cmd = self.command_buf.items;
                if (mem.eql(u8, cmd, "q") or mem.eql(u8, cmd, "quit")) {
                    self.running = false;
                } else if (mem.eql(u8, cmd, "w") or mem.eql(u8, cmd, "save")) {
                    try self.saveCurrentRequest();
                } else if (mem.eql(u8, cmd, "wq")) {
                    try self.saveCurrentRequest();
                    self.running = false;
                } else if (mem.startsWith(u8, cmd, "e ")) {
                    const path = cmd[2..];
                    try self.loadRequest(path);
                }
                self.mode = .normal;
                self.command_buf.clearRetainingCapacity();
            },
            .char => {
                try self.command_buf.append(event.char);
                self.status_message = ":";
            },
            .backspace => {
                if (self.command_buf.items.len > 0) {
                    _ = self.command_buf.pop();
                }
                if (self.command_buf.items.len == 0) {
                    self.mode = .normal;
                    self.status_message = null;
                }
            },
            else => {},
        }
    }

    fn navigateDown(self: *App) !void {
        switch (self.active_pane) {
            .collection => {
                if (self.collection_files.items.len > 0 and
                    self.collection_selected < self.collection_files.items.len - 1)
                {
                    self.collection_selected += 1;
                }
            },
            .request => {
                self.request_field = switch (self.request_field) {
                    .method => .url,
                    .url => .headers,
                    .headers => .body,
                    .body => .body,
                };
            },
            .response => {
                self.response_scroll += 1;
            },
        }
    }

    fn navigateUp(self: *App) !void {
        switch (self.active_pane) {
            .collection => {
                if (self.collection_selected > 0) {
                    self.collection_selected -= 1;
                }
            },
            .request => {
                self.request_field = switch (self.request_field) {
                    .method => .method,
                    .url => .method,
                    .headers => .url,
                    .body => .headers,
                };
            },
            .response => {
                if (self.response_scroll > 0) self.response_scroll -= 1;
            },
        }
    }

    fn loadSelectedRequest(self: *App) !void {
        if (self.collection_files.items.len == 0) return;
        const filename = self.collection_files.items[self.collection_selected];
        try self.loadRequest(filename);
    }

    fn loadRequest(self: *App, path: []const u8) !void {
        const full_path = if (mem.eql(u8, self.collection_dir, "."))
            path
        else blk: {
            break :blk std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.collection_dir, path }) catch path;
        };

        const file = std.fs.cwd().openFile(full_path, .{}) catch {
            self.status_message = "Error: cannot open file";
            return;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch {
            self.status_message = "Error: cannot read file";
            return;
        };
        defer self.allocator.free(content);

        if (self.current_request) |*req| req.deinit();

        self.current_request = VoltFile.parse(self.allocator, content) catch {
            self.status_message = "Error: invalid .volt file";
            return;
        };
        self.current_file = path;

        // Update URL input
        self.url_input.clearRetainingCapacity();
        if (self.current_request) |req| {
            self.url_input.appendSlice(req.url) catch {};
        }

        // Find method index
        if (self.current_request) |req| {
            for (METHODS, 0..) |m, idx| {
                if (m == req.method) {
                    self.method_index = idx;
                    break;
                }
            }
        }

        self.active_pane = .request;
        self.status_message = "Loaded";

        // Clear previous response
        if (self.current_response) |*resp| resp.deinit();
        self.current_response = null;
        if (self.response_formatted) |f| {
            self.allocator.free(f);
            self.response_formatted = null;
        }
    }

    fn sendRequest(self: *App) !void {
        if (self.current_request == null) {
            // Create a new request from the URL input
            self.current_request = VoltFile.VoltRequest.init(self.allocator);
            self.current_request.?.method = METHODS[self.method_index];
        }

        self.current_request.?.url = self.url_input.items;

        // Interpolate variables
        const resolved_url = self.env_manager.interpolate(
            self.current_request.?.url,
            null,
            self.allocator,
        ) catch self.url_input.items;

        var req_copy = self.current_request.?;
        req_copy.url = resolved_url;

        self.status_message = "Sending...";
        try self.render();
        try self.writer.flush();

        // Clean up previous response
        if (self.current_response) |*resp| resp.deinit();
        if (self.response_formatted) |f| {
            self.allocator.free(f);
            self.response_formatted = null;
        }

        self.current_response = HttpClient.execute(
            self.allocator,
            &req_copy,
            .{},
        ) catch {
            self.status_message = "Error: request failed";
            self.active_pane = .response;
            return;
        };

        if (self.current_response) |*resp| {
            // Use JSON formatter for response body if it looks like JSON
            const body = resp.bodySlice();
            const trimmed = mem.trim(u8, body, " \t\r\n");
            if (trimmed.len > 0 and (trimmed[0] == '{' or trimmed[0] == '[')) {
                const pretty = Formatter.formatJsonPlain(self.allocator, body) catch null;
                if (pretty) |p| {
                    // Build formatted response with headers + pretty body
                    var buf = std.ArrayList(u8).init(self.allocator);
                    const w = buf.writer();
                    w.print("HTTP {d} | {d:.0}ms | {d} bytes\n\n", .{
                        resp.status_code,
                        resp.timing.total_ms,
                        resp.size_bytes,
                    }) catch {};
                    for (resp.headers.items) |h| {
                        w.print("{s}: {s}\n", .{ h.name, h.value }) catch {};
                    }
                    w.writeAll("\n") catch {};
                    w.writeAll(p) catch {};
                    self.allocator.free(p);
                    self.response_formatted = buf.toOwnedSlice() catch null;
                } else {
                    self.response_formatted = HttpClient.formatResponse(resp, self.allocator) catch null;
                }
            } else {
                self.response_formatted = HttpClient.formatResponse(resp, self.allocator) catch null;
            }
        }

        self.active_pane = .response;
        self.response_scroll = 0;
        if (self.current_response) |resp| {
            var status_buf: [64]u8 = undefined;
            const status_msg = std.fmt.bufPrint(&status_buf, "HTTP {d} | {d:.0}ms", .{
                resp.status_code,
                resp.timing.total_ms,
            }) catch "Done";
            self.status_message = status_msg;
        }
    }

    fn saveCurrentRequest(self: *App) !void {
        if (self.current_request == null) return;
        const path = self.current_file orelse "new_request.volt";

        const content = VoltFile.serialize(&self.current_request.?, self.allocator) catch {
            self.status_message = "Error: cannot serialize";
            return;
        };
        defer self.allocator.free(content);

        const file = std.fs.cwd().createFile(path, .{}) catch {
            self.status_message = "Error: cannot save";
            return;
        };
        defer file.close();
        file.writeAll(content) catch {
            self.status_message = "Error: write failed";
            return;
        };

        self.status_message = "Saved";
    }

    // ── Rendering ───────────────────────────────────────────────────

    fn render(self: *App) !void {
        try self.writer.clearScreen();

        // Title bar
        try self.renderTitleBar();

        // Main content area
        const content_start_row: u16 = 2;
        const content_height = self.term_size.height -| 3; // Leave room for title + status

        try self.renderCollectionPane(content_start_row, 1, LEFT_PANE_WIDTH, content_height);
        try self.renderDivider(content_start_row, LEFT_PANE_WIDTH + 1, content_height);

        const right_start = LEFT_PANE_WIDTH + 2;
        const right_width = self.term_size.width -| right_start;
        const half_width = right_width / 2;

        try self.renderRequestPane(content_start_row, right_start, half_width, content_height);
        try self.renderDivider(content_start_row, right_start + half_width, content_height);
        try self.renderResponsePane(content_start_row, right_start + half_width + 1, half_width, content_height);

        // Status bar
        try self.renderStatusBar();
    }

    fn renderTitleBar(self: *App) !void {
        try self.writer.moveTo(1, 1);
        try self.writer.setStyle(.{ .bg = .blue, .fg = .white, .bold = true });

        // Fill title bar
        var i: u16 = 0;
        while (i < self.term_size.width) : (i += 1) {
            try self.writer.write(" ");
        }

        try self.writer.moveTo(1, 2);
        try self.writer.write(" VOLT ");
        try self.writer.setStyle(.{ .bg = .blue, .fg = .bright_white });
        try self.writer.write(" API Client");

        // Right side - help hint
        const help = " q:quit  Tab:pane  r:send  m:method  i:edit  R:refresh  :w save ";
        if (self.term_size.width > help.len + 20) {
            try self.writer.moveTo(1, self.term_size.width -| @as(u16, @intCast(help.len)));
            try self.writer.write(help);
        }

        try self.writer.resetStyle();
    }

    fn renderCollectionPane(self: *App, row: u16, col: u16, width: u16, height: u16) !void {
        const is_active = self.active_pane == .collection;

        // Pane header
        try self.writer.moveTo(row, col);
        if (is_active) {
            try self.writer.setStyle(.{ .fg = .cyan, .bold = true });
        } else {
            try self.writer.setStyle(.{ .fg = .bright_black });
        }
        try self.writer.writeAtTruncated(row, col, " Collection", width);
        try self.writer.resetStyle();

        // Draw separator
        try self.writer.moveTo(row + 1, col);
        try self.writer.setStyle(.{ .fg = .bright_black });
        var sep_i: u16 = 0;
        while (sep_i < width) : (sep_i += 1) {
            try self.writer.write("\xe2\x94\x80");
        }
        try self.writer.resetStyle();

        // File list
        if (self.collection_files.items.len == 0) {
            try self.writer.setStyle(.{ .fg = .bright_black, .italic = true });
            try self.writer.writeAtTruncated(row + 3, col + 1, "No .volt files found", width -| 2);
            try self.writer.writeAtTruncated(row + 4, col + 1, "Create one or import", width -| 2);
            try self.writer.resetStyle();
            return;
        }

        const visible_start = self.collection_scroll;
        const visible_count = @min(self.collection_files.items.len - visible_start, height -| 2);

        var i: usize = 0;
        while (i < visible_count) : (i += 1) {
            const file_idx = visible_start + i;
            const file = self.collection_files.items[file_idx];
            const display_row = row + 2 + @as(u16, @intCast(i));

            if (file_idx == self.collection_selected) {
                if (is_active) {
                    try self.writer.setStyle(.{ .bg = .cyan, .fg = .black, .bold = true });
                } else {
                    try self.writer.setStyle(.{ .bg = .bright_black, .fg = .white });
                }
                // Fill selection background
                try self.writer.moveTo(display_row, col);
                var fill: u16 = 0;
                while (fill < width) : (fill += 1) {
                    try self.writer.write(" ");
                }
            } else {
                try self.writer.setStyle(.{ .fg = .white });
            }

            // Show method badge + filename
            try self.writer.writeAtTruncated(display_row, col + 1, file, width -| 2);
            try self.writer.resetStyle();
        }
    }

    fn renderRequestPane(self: *App, row: u16, col: u16, width: u16, height: u16) !void {
        const is_active = self.active_pane == .request;

        // Pane header
        try self.writer.moveTo(row, col);
        if (is_active) {
            try self.writer.setStyle(.{ .fg = .yellow, .bold = true });
        } else {
            try self.writer.setStyle(.{ .fg = .bright_black });
        }
        try self.writer.writeAtTruncated(row, col, " Request", width);
        try self.writer.resetStyle();

        // Separator
        try self.writer.moveTo(row + 1, col);
        try self.writer.setStyle(.{ .fg = .bright_black });
        var sep_i: u16 = 0;
        while (sep_i < width) : (sep_i += 1) {
            try self.writer.write("\xe2\x94\x80");
        }
        try self.writer.resetStyle();

        var current_row = row + 2;

        // Method selector
        const method_name = if (self.current_request) |req|
            req.method.toString()
        else
            METHODS[self.method_index].toString();

        const method_color: terminal.Color = if (mem.eql(u8, method_name, "GET"))
            .green
        else if (mem.eql(u8, method_name, "POST"))
            .yellow
        else if (mem.eql(u8, method_name, "PUT"))
            .blue
        else if (mem.eql(u8, method_name, "DELETE"))
            .red
        else
            .magenta;

        const is_method_selected = is_active and self.request_field == .method;
        if (is_method_selected) {
            try self.writer.setStyle(.{ .fg = method_color, .bold = true, .reverse = true });
        } else {
            try self.writer.setStyle(.{ .fg = method_color, .bold = true });
        }
        try self.writer.writeAt(current_row, col + 1, " ");
        try self.writer.write(method_name);
        try self.writer.write(" ");
        try self.writer.resetStyle();

        // URL
        current_row += 1;
        const is_url_selected = is_active and self.request_field == .url;
        try self.writer.moveTo(current_row, col + 1);
        try self.writer.setStyle(.{ .fg = .bright_black });
        try self.writer.write("URL: ");
        if (is_url_selected and self.mode == .insert) {
            try self.writer.setStyle(.{ .fg = .white, .underline = true });
        } else if (is_url_selected) {
            try self.writer.setStyle(.{ .fg = .white, .bold = true });
        } else {
            try self.writer.setStyle(.{ .fg = .white });
        }

        const url_display = if (self.url_input.items.len > 0)
            self.url_input.items
        else if (self.current_request) |req|
            req.url
        else
            "(enter URL)";
        try self.writer.writeAtTruncated(current_row, col + 6, url_display, width -| 7);
        try self.writer.resetStyle();

        // Headers section
        current_row += 2;
        const is_headers_selected = is_active and self.request_field == .headers;
        if (is_headers_selected) {
            try self.writer.setStyle(.{ .fg = .cyan, .bold = true });
        } else {
            try self.writer.setStyle(.{ .fg = .bright_black });
        }
        try self.writer.writeAt(current_row, col + 1, "Headers:");
        try self.writer.resetStyle();

        if (self.current_request) |req| {
            for (req.headers.items, 0..) |h, idx| {
                if (idx >= height -| 10) break;
                current_row += 1;
                try self.writer.setStyle(.{ .fg = .cyan });
                try self.writer.writeAt(current_row, col + 3, h.name);
                try self.writer.setStyle(.{ .fg = .bright_black });
                try self.writer.write(": ");
                try self.writer.setStyle(.{ .fg = .white });
                try self.writer.writeAtTruncated(current_row, col + 4 + @as(u16, @intCast(h.name.len + 2)), h.value, width -| @as(u16, @intCast(h.name.len + 7)));
                try self.writer.resetStyle();
            }
        }

        // Body section
        current_row += 2;
        const is_body_selected = is_active and self.request_field == .body;
        if (is_body_selected) {
            try self.writer.setStyle(.{ .fg = .magenta, .bold = true });
        } else {
            try self.writer.setStyle(.{ .fg = .bright_black });
        }
        try self.writer.writeAt(current_row, col + 1, "Body:");
        try self.writer.resetStyle();

        if (self.current_request) |req| {
            if (req.body_type != .none) {
                current_row += 1;
                try self.writer.setStyle(.{ .fg = .bright_black });
                try self.writer.print("  type: {s}", .{req.body_type.toString()});
                try self.writer.resetStyle();
            }
            if (req.body) |body| {
                current_row += 1;
                var body_lines = mem.splitSequence(u8, body, "\n");
                var line_count: u16 = 0;
                while (body_lines.next()) |line| {
                    if (line_count >= height -| current_row) break;
                    try self.writer.setStyle(.{ .fg = .white });
                    try self.writer.writeAtTruncated(current_row + line_count, col + 3, line, width -| 4);
                    try self.writer.resetStyle();
                    line_count += 1;
                }
            }
        }

        // Auth section
        if (self.current_request) |req| {
            if (req.auth.type != .none) {
                current_row += 2;
                try self.writer.setStyle(.{ .fg = .bright_black });
                try self.writer.writeAt(current_row, col + 1, "Auth: ");
                try self.writer.setStyle(.{ .fg = .yellow });
                try self.writer.write(req.auth.type.toString());
                try self.writer.resetStyle();
            }
        }
    }

    fn renderResponsePane(self: *App, row: u16, col: u16, width: u16, height: u16) !void {
        const is_active = self.active_pane == .response;

        // Pane header
        try self.writer.moveTo(row, col);
        if (is_active) {
            try self.writer.setStyle(.{ .fg = .green, .bold = true });
        } else {
            try self.writer.setStyle(.{ .fg = .bright_black });
        }
        try self.writer.writeAtTruncated(row, col, " Response", width);
        try self.writer.resetStyle();

        // Separator
        try self.writer.moveTo(row + 1, col);
        try self.writer.setStyle(.{ .fg = .bright_black });
        var sep_i: u16 = 0;
        while (sep_i < width) : (sep_i += 1) {
            try self.writer.write("\xe2\x94\x80");
        }
        try self.writer.resetStyle();

        if (self.current_response == null) {
            try self.writer.setStyle(.{ .fg = .bright_black, .italic = true });
            try self.writer.writeAtTruncated(row + 4, col + 2, "No response yet", width -| 4);
            try self.writer.writeAtTruncated(row + 5, col + 2, "Press Enter to send", width -| 4);
            try self.writer.resetStyle();
            return;
        }

        if (self.response_formatted) |formatted| {
            var lines = mem.splitSequence(u8, formatted, "\n");
            var line_idx: usize = 0;
            var display_row: u16 = 0;

            while (lines.next()) |line| {
                if (line_idx < self.response_scroll) {
                    line_idx += 1;
                    continue;
                }
                if (display_row >= height -| 2) break;

                const render_row = row + 2 + display_row;

                // Colorize status lines and headers
                if (display_row == 0 and mem.startsWith(u8, line, "HTTP")) {
                    // Status line
                    if (self.current_response) |resp| {
                        const color: terminal.Color = if (resp.status_code < 300) .green else if (resp.status_code < 400) .yellow else .red;
                        try self.writer.setStyle(.{ .fg = color, .bold = true });
                    }
                } else if (mem.indexOf(u8, line, ": ") != null and display_row < 20) {
                    try self.writer.setStyle(.{ .fg = .cyan });
                } else {
                    try self.writer.setStyle(.{ .fg = .white });
                }

                try self.writer.writeAtTruncated(render_row, col + 1, line, width -| 2);
                try self.writer.resetStyle();

                line_idx += 1;
                display_row += 1;
            }
        }
    }

    fn renderDivider(self: *App, row: u16, col: u16, height: u16) !void {
        try self.writer.setStyle(.{ .fg = .bright_black });
        var i: u16 = 0;
        while (i < height) : (i += 1) {
            try self.writer.writeAt(row + i, col, "\xe2\x94\x82");
        }
        try self.writer.resetStyle();
    }

    fn renderStatusBar(self: *App) !void {
        const status_row = self.term_size.height;
        try self.writer.moveTo(status_row, 1);
        try self.writer.setStyle(.{ .bg = .bright_black, .fg = .white });

        // Fill status bar
        var i: u16 = 0;
        while (i < self.term_size.width) : (i += 1) {
            try self.writer.write(" ");
        }

        try self.writer.moveTo(status_row, 2);

        // Mode indicator
        switch (self.mode) {
            .normal => {
                try self.writer.setStyle(.{ .bg = .green, .fg = .black, .bold = true });
                try self.writer.write(" NORMAL ");
            },
            .insert => {
                try self.writer.setStyle(.{ .bg = .yellow, .fg = .black, .bold = true });
                try self.writer.write(" INSERT ");
            },
            .command => {
                try self.writer.setStyle(.{ .bg = .magenta, .fg = .black, .bold = true });
                try self.writer.write(" COMMAND ");
            },
        }

        try self.writer.setStyle(.{ .bg = .bright_black, .fg = .white });

        // Status message
        if (self.status_message) |msg| {
            try self.writer.write(" ");
            try self.writer.write(msg);
        }

        // Command buffer
        if (self.mode == .command and self.command_buf.items.len > 0) {
            try self.writer.write(":");
            try self.writer.write(self.command_buf.items);
        }

        // Right side info — response timing + file
        var right_info_buf: [128]u8 = undefined;
        var right_info: []const u8 = "";
        if (self.current_response) |resp| {
            if (self.current_file) |file| {
                right_info = std.fmt.bufPrint(&right_info_buf, "{d}ms | {s}", .{
                    @as(u32, @intFromFloat(resp.timing.total_ms)),
                    file,
                }) catch file;
            } else {
                right_info = std.fmt.bufPrint(&right_info_buf, "{d}ms", .{
                    @as(u32, @intFromFloat(resp.timing.total_ms)),
                }) catch "";
            }
        } else if (self.current_file) |file| {
            right_info = file;
        }
        if (right_info.len > 0) {
            const right_col = self.term_size.width -| @as(u16, @intCast(@min(right_info.len + 2, self.term_size.width)));
            try self.writer.moveTo(status_row, right_col);
            try self.writer.write(right_info);
        }

        try self.writer.resetStyle();
    }
};
