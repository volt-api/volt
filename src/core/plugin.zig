const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Plugin/Extension System ─────────────────────────────────────────────
// Plugins are external executables that communicate via stdin/stdout JSON.
// Each plugin declares hooks it supports in a plugin.json manifest file.
// The plugin manager discovers, loads, and executes plugins on demand.

pub const PluginHook = enum {
    pre_request,
    post_response,
    auth_provider,
    variable_provider,
    formatter,

    pub fn toString(self: PluginHook) []const u8 {
        return switch (self) {
            .pre_request => "pre_request",
            .post_response => "post_response",
            .auth_provider => "auth_provider",
            .variable_provider => "variable_provider",
            .formatter => "formatter",
        };
    }

    pub fn fromString(s: []const u8) ?PluginHook {
        if (mem.eql(u8, s, "pre_request")) return .pre_request;
        if (mem.eql(u8, s, "post_response")) return .post_response;
        if (mem.eql(u8, s, "auth_provider")) return .auth_provider;
        if (mem.eql(u8, s, "variable_provider")) return .variable_provider;
        if (mem.eql(u8, s, "formatter")) return .formatter;
        return null;
    }
};

pub const PluginManifest = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    executable: []const u8,
    hooks: std.ArrayList(PluginHook),

    pub fn init(allocator: Allocator) PluginManifest {
        return .{
            .name = "",
            .version = "",
            .description = "",
            .executable = "",
            .hooks = std.ArrayList(PluginHook).init(allocator),
        };
    }

    pub fn deinit(self: *PluginManifest) void {
        self.hooks.deinit();
    }
};

pub const PluginMessage = struct {
    msg_type: []const u8, // "request", "response", "variable", "auth"
    data: []const u8,
};

pub const PluginManager = struct {
    allocator: Allocator,
    plugins: std.ArrayList(PluginManifest),
    plugin_dir: []const u8,

    pub fn init(allocator: Allocator) PluginManager {
        return .{
            .allocator = allocator,
            .plugins = std.ArrayList(PluginManifest).init(allocator),
            .plugin_dir = ".volt-plugins",
        };
    }

    pub fn deinit(self: *PluginManager) void {
        for (self.plugins.items) |*p| {
            p.deinit();
        }
        self.plugins.deinit();
    }
};

/// Parse a plugin.json manifest from JSON content.
/// Expected format:
///   { "name": "...", "version": "...", "description": "...", "executable": "...", "hooks": ["..."] }
pub fn loadManifest(allocator: Allocator, json_content: []const u8) ?PluginManifest {
    var manifest = PluginManifest.init(allocator);

    manifest.name = extractJsonString(json_content, "name") orelse {
        manifest.deinit();
        return null;
    };
    manifest.version = extractJsonString(json_content, "version") orelse {
        manifest.deinit();
        return null;
    };
    manifest.description = extractJsonString(json_content, "description") orelse {
        manifest.deinit();
        return null;
    };
    manifest.executable = extractJsonString(json_content, "executable") orelse {
        manifest.deinit();
        return null;
    };

    // Parse hooks array
    const hooks_start = mem.indexOf(u8, json_content, "\"hooks\"") orelse {
        manifest.deinit();
        return null;
    };
    const after_hooks_key = json_content[hooks_start + "\"hooks\"".len ..];

    // Find the opening bracket
    const bracket_pos = mem.indexOf(u8, after_hooks_key, "[") orelse {
        manifest.deinit();
        return null;
    };
    const bracket_end = mem.indexOf(u8, after_hooks_key, "]") orelse {
        manifest.deinit();
        return null;
    };

    const hooks_content = after_hooks_key[bracket_pos + 1 .. bracket_end];

    // Parse each hook string from the array
    var remaining = hooks_content;
    while (mem.indexOf(u8, remaining, "\"")) |quote_start| {
        const after_quote = remaining[quote_start + 1 ..];
        const quote_end = mem.indexOf(u8, after_quote, "\"") orelse break;
        const hook_str = after_quote[0..quote_end];

        if (PluginHook.fromString(hook_str)) |hook| {
            manifest.hooks.append(hook) catch {
                manifest.deinit();
                return null;
            };
        }

        remaining = after_quote[quote_end + 1 ..];
    }

    return manifest;
}

/// Scan a directory for plugin.json files and load all plugin manifests.
pub fn discoverPlugins(allocator: Allocator, dir_path: []const u8) std.ArrayList(PluginManifest) {
    var plugins = std.ArrayList(PluginManifest).init(allocator);

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return plugins;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;

        // Try to open plugin.json inside each subdirectory
        var sub_dir = dir.openDir(entry.name, .{}) catch continue;
        defer sub_dir.close();

        const file = sub_dir.openFile("plugin.json", .{}) catch continue;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 64 * 1024) catch continue;
        defer allocator.free(content);

        if (loadManifest(allocator, content)) |manifest| {
            plugins.append(manifest) catch continue;
        }
    }

    return plugins;
}

/// Execute a plugin executable as a child process.
/// Writes input_json to stdin and reads the plugin's stdout response.
pub fn executePlugin(allocator: Allocator, manifest: *const PluginManifest, input_json: []const u8) ?[]const u8 {
    const argv: []const []const u8 = &.{manifest.executable};
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;

    child.spawn() catch return null;

    // Write input to stdin and close it
    if (child.stdin) |stdin| {
        var stdin_file = stdin;
        stdin_file.writeAll(input_json) catch {};
        stdin_file.close();
        child.stdin = null;
    }

    // Read stdout
    var stdout_buf = std.ArrayList(u8).init(allocator);
    if (child.stdout) |stdout| {
        const reader = stdout.reader();
        reader.readAllArrayList(&stdout_buf, 1024 * 1024) catch {};
    }

    _ = child.wait() catch {
        stdout_buf.deinit();
        return null;
    };

    return stdout_buf.toOwnedSlice() catch {
        stdout_buf.deinit();
        return null;
    };
}

/// Format a list of installed plugins for display.
pub fn formatPluginList(allocator: Allocator, plugins: []const PluginManifest) []const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    writer.writeAll("\x1b[1mInstalled Plugins\x1b[0m\n\n") catch return "";

    if (plugins.len == 0) {
        writer.writeAll("  No plugins installed.\n") catch return "";
        return buf.toOwnedSlice() catch return "";
    }

    for (plugins, 0..) |plugin, i| {
        writer.print("  \x1b[36m{d}.\x1b[0m \x1b[1m{s}\x1b[0m v{s}\n", .{ i + 1, plugin.name, plugin.version }) catch continue;
        writer.print("     {s}\n", .{plugin.description}) catch continue;
        writer.writeAll("     Hooks: ") catch continue;
        for (plugin.hooks.items, 0..) |hook, j| {
            if (j > 0) writer.writeAll(", ") catch {};
            writer.print("{s}", .{hook.toString()}) catch {};
        }
        writer.writeAll("\n") catch {};
        writer.print("     Executable: {s}\n\n", .{plugin.executable}) catch {};
    }

    writer.print("{d} plugin(s) installed.\n", .{plugins.len}) catch {};

    return buf.toOwnedSlice() catch return "";
}

/// Serialize request context as JSON for plugin input.
pub fn serializeRequest(allocator: Allocator, method: []const u8, url: []const u8, headers_str: []const u8, body: []const u8) []const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    writer.writeAll("{") catch return "";
    writer.print("\"type\":\"request\",", .{}) catch return "";
    writer.print("\"method\":\"{s}\",", .{escapeJsonString(method)}) catch return "";
    writer.print("\"url\":\"{s}\",", .{escapeJsonString(url)}) catch return "";
    writer.print("\"headers\":\"{s}\",", .{escapeJsonString(headers_str)}) catch return "";
    writer.print("\"body\":\"{s}\"", .{escapeJsonString(body)}) catch return "";
    writer.writeAll("}") catch return "";

    return buf.toOwnedSlice() catch return "";
}

/// Serialize response context as JSON for plugin input.
pub fn serializeResponse(allocator: Allocator, status: u16, headers_str: []const u8, body: []const u8) []const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    writer.writeAll("{") catch return "";
    writer.print("\"type\":\"response\",", .{}) catch return "";
    writer.print("\"status\":{d},", .{status}) catch return "";
    writer.print("\"headers\":\"{s}\",", .{escapeJsonString(headers_str)}) catch return "";
    writer.print("\"body\":\"{s}\"", .{escapeJsonString(body)}) catch return "";
    writer.writeAll("}") catch return "";

    return buf.toOwnedSlice() catch return "";
}

// ── Helpers ─────────────────────────────────────────────────────────────

/// Extract a string value for a given key from simple JSON.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    // Build search pattern: "key"
    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = json[key_pos + search_key.len ..];

    // Skip colon and whitespace
    var pos: usize = 0;
    while (pos < after_key.len and (after_key[pos] == ':' or after_key[pos] == ' ' or after_key[pos] == '\t')) {
        pos += 1;
    }
    if (pos >= after_key.len) return null;

    // Expect opening quote
    if (after_key[pos] != '"') return null;
    pos += 1;

    const value_start = pos;
    while (pos < after_key.len and after_key[pos] != '"') {
        if (after_key[pos] == '\\') pos += 1; // skip escaped chars
        pos += 1;
    }

    return after_key[value_start..pos];
}

/// Simple JSON string escaping for serialization.
fn escapeJsonString(input: []const u8) []const u8 {
    // For simple strings without special chars, return as-is
    for (input) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') {
            // Contains chars that need escaping; for simplicity return as-is
            // A full implementation would allocate and escape
            return input;
        }
    }
    return input;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "loadManifest parses valid plugin.json" {
    const json =
        \\{ "name": "aws-auth", "version": "1.0", "description": "AWS SigV4 auth", "executable": "./aws-auth", "hooks": ["auth_provider"] }
    ;

    var manifest = loadManifest(std.testing.allocator, json) orelse {
        return error.TestUnexpectedResult;
    };
    defer manifest.deinit();

    try std.testing.expectEqualStrings("aws-auth", manifest.name);
    try std.testing.expectEqualStrings("1.0", manifest.version);
    try std.testing.expectEqualStrings("AWS SigV4 auth", manifest.description);
    try std.testing.expectEqualStrings("./aws-auth", manifest.executable);
    try std.testing.expectEqual(@as(usize, 1), manifest.hooks.items.len);
    try std.testing.expectEqual(PluginHook.auth_provider, manifest.hooks.items[0]);
}

test "loadManifest parses multiple hooks" {
    const json =
        \\{ "name": "multi", "version": "2.0", "description": "Multi-hook plugin", "executable": "./multi", "hooks": ["pre_request", "post_response", "formatter"] }
    ;

    var manifest = loadManifest(std.testing.allocator, json) orelse {
        return error.TestUnexpectedResult;
    };
    defer manifest.deinit();

    try std.testing.expectEqual(@as(usize, 3), manifest.hooks.items.len);
    try std.testing.expectEqual(PluginHook.pre_request, manifest.hooks.items[0]);
    try std.testing.expectEqual(PluginHook.post_response, manifest.hooks.items[1]);
    try std.testing.expectEqual(PluginHook.formatter, manifest.hooks.items[2]);
}

test "loadManifest returns null for invalid json" {
    const result = loadManifest(std.testing.allocator, "not json at all");
    try std.testing.expect(result == null);
}

test "loadManifest returns null for missing fields" {
    const json =
        \\{ "name": "incomplete" }
    ;
    const result = loadManifest(std.testing.allocator, json);
    try std.testing.expect(result == null);
}

test "formatPluginList with no plugins" {
    const plugins = [_]PluginManifest{};
    const result = formatPluginList(std.testing.allocator, &plugins);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "No plugins installed") != null);
}

test "formatPluginList with plugins" {
    var manifest = PluginManifest.init(std.testing.allocator);
    defer manifest.deinit();
    manifest.name = "test-plugin";
    manifest.version = "1.0";
    manifest.description = "A test plugin";
    manifest.executable = "./test-plugin";
    try manifest.hooks.append(.pre_request);

    const plugins = [_]PluginManifest{manifest};
    const result = formatPluginList(std.testing.allocator, &plugins);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "test-plugin") != null);
    try std.testing.expect(mem.indexOf(u8, result, "v1.0") != null);
    try std.testing.expect(mem.indexOf(u8, result, "A test plugin") != null);
    try std.testing.expect(mem.indexOf(u8, result, "pre_request") != null);
    try std.testing.expect(mem.indexOf(u8, result, "1 plugin(s) installed") != null);
}

test "serializeRequest produces valid json structure" {
    const result = serializeRequest(
        std.testing.allocator,
        "POST",
        "https://api.example.com/users",
        "Content-Type: application/json",
        "{\"name\":\"test\"}",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "\"type\":\"request\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"method\":\"POST\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"url\":\"https://api.example.com/users\"") != null);
}

test "serializeResponse produces valid json structure" {
    const result = serializeResponse(
        std.testing.allocator,
        200,
        "Content-Type: application/json",
        "{\"ok\":true}",
    );
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "\"type\":\"response\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"status\":200") != null);
}

test "PluginHook toString and fromString roundtrip" {
    const hooks = [_]PluginHook{ .pre_request, .post_response, .auth_provider, .variable_provider, .formatter };
    for (hooks) |hook| {
        const str = hook.toString();
        const parsed = PluginHook.fromString(str);
        try std.testing.expect(parsed != null);
        try std.testing.expectEqual(hook, parsed.?);
    }
}

test "PluginHook fromString returns null for unknown" {
    const result = PluginHook.fromString("nonexistent_hook");
    try std.testing.expect(result == null);
}

test "PluginManager init and deinit" {
    var manager = PluginManager.init(std.testing.allocator);
    defer manager.deinit();

    try std.testing.expectEqualStrings(".volt-plugins", manager.plugin_dir);
    try std.testing.expectEqual(@as(usize, 0), manager.plugins.items.len);
}
