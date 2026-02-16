const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Project Config (.voltrc) ────────────────────────────────────────────
// Supports project-level configuration:
//   base_url: https://api.example.com
//   timeout: 30000
//   environment: staging
//   headers:
//     - Accept: application/json
//   proxy: http://localhost:8080
//   verbose: false
//   follow_redirects: true
//   max_redirects: 10
//   verify_ssl: true
//   output_format: pretty  (pretty|compact|raw)

pub const VoltConfig = struct {
    base_url: ?[]const u8 = null,
    timeout_ms: u32 = 30_000,
    environment: ?[]const u8 = null,
    default_headers: std.ArrayList(HeaderEntry),
    proxy: ?[]const u8 = null,
    verbose: bool = false,
    follow_redirects: bool = true,
    max_redirects: u8 = 10,
    verify_ssl: bool = true,
    output_format: OutputFormat = .pretty,
    color: bool = true,

    pub fn init(allocator: Allocator) VoltConfig {
        return .{
            .default_headers = std.ArrayList(HeaderEntry).init(allocator),
        };
    }

    pub fn deinit(self: *VoltConfig) void {
        self.default_headers.deinit();
    }
};

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const OutputFormat = enum {
    pretty,
    compact,
    raw,

    pub fn fromString(s: []const u8) OutputFormat {
        if (mem.eql(u8, s, "compact")) return .compact;
        if (mem.eql(u8, s, "raw")) return .raw;
        return .pretty;
    }
};

/// Load config from .voltrc file
pub fn loadConfig(allocator: Allocator, dir_path: []const u8) !VoltConfig {
    var config = VoltConfig.init(allocator);
    errdefer config.deinit();

    // Try to open .voltrc in the given directory
    const voltrc_path = std.fmt.allocPrint(allocator, "{s}/.voltrc", .{dir_path}) catch return config;
    defer allocator.free(voltrc_path);

    const file = std.fs.cwd().openFile(voltrc_path, .{}) catch {
        // Try current directory
        const cwd_rc = std.fs.cwd().openFile(".voltrc", .{}) catch return config;
        defer cwd_rc.close();
        const content = cwd_rc.readToEndAlloc(allocator, 1024 * 1024) catch return config;
        defer allocator.free(content);
        parseConfig(&config, content) catch {};
        return config;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return config;
    defer allocator.free(content);

    parseConfig(&config, content) catch {};
    return config;
}

/// Parse .voltrc content
fn parseConfig(config: *VoltConfig, content: []const u8) !void {
    var in_headers = false;

    var lines = mem.splitSequence(u8, content, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, mem.trimRight(u8, raw_line, "\r"), " \t");
        if (line.len == 0 or line[0] == '#') continue;

        if (mem.eql(u8, line, "headers:")) {
            in_headers = true;
            continue;
        }

        if (in_headers) {
            if (mem.startsWith(u8, line, "- ")) {
                const entry = line[2..];
                if (mem.indexOf(u8, entry, ": ")) |colon| {
                    try config.default_headers.append(.{
                        .name = entry[0..colon],
                        .value = entry[colon + 2 ..],
                    });
                }
                continue;
            }
            in_headers = false;
        }

        // Key: value parsing
        if (mem.indexOf(u8, line, ": ")) |colon_pos| {
            const key = line[0..colon_pos];
            const value = line[colon_pos + 2 ..];

            if (mem.eql(u8, key, "base_url")) {
                config.base_url = value;
            } else if (mem.eql(u8, key, "timeout")) {
                config.timeout_ms = std.fmt.parseInt(u32, value, 10) catch 30_000;
            } else if (mem.eql(u8, key, "environment")) {
                config.environment = value;
            } else if (mem.eql(u8, key, "proxy")) {
                config.proxy = value;
            } else if (mem.eql(u8, key, "verbose")) {
                config.verbose = mem.eql(u8, value, "true");
            } else if (mem.eql(u8, key, "follow_redirects")) {
                config.follow_redirects = mem.eql(u8, value, "true");
            } else if (mem.eql(u8, key, "max_redirects")) {
                config.max_redirects = std.fmt.parseInt(u8, value, 10) catch 10;
            } else if (mem.eql(u8, key, "verify_ssl")) {
                config.verify_ssl = mem.eql(u8, value, "true");
            } else if (mem.eql(u8, key, "output")) {
                config.output_format = OutputFormat.fromString(value);
            } else if (mem.eql(u8, key, "color")) {
                config.color = mem.eql(u8, value, "true");
            }
        }
    }
}

/// Generate a default .voltrc file
pub fn generateDefaultConfig(allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("# Volt Project Configuration\n");
    try writer.writeAll("# Place this file in your project root as .voltrc\n\n");
    try writer.writeAll("# Base URL for all requests (prepended to relative URLs)\n");
    try writer.writeAll("# base_url: https://api.example.com\n\n");
    try writer.writeAll("# Default environment\n");
    try writer.writeAll("# environment: development\n\n");
    try writer.writeAll("# Request timeout in milliseconds\n");
    try writer.writeAll("timeout: 30000\n\n");
    try writer.writeAll("# Default headers applied to all requests\n");
    try writer.writeAll("headers:\n");
    try writer.writeAll("  - Accept: application/json\n");
    try writer.writeAll("  - User-Agent: Volt/0.2.0\n\n");
    try writer.writeAll("# Output format: pretty | compact | raw\n");
    try writer.writeAll("output: pretty\n\n");
    try writer.writeAll("# Enable colored output\n");
    try writer.writeAll("color: true\n\n");
    try writer.writeAll("# Follow HTTP redirects\n");
    try writer.writeAll("follow_redirects: true\n");
    try writer.writeAll("max_redirects: 10\n\n");
    try writer.writeAll("# SSL verification\n");
    try writer.writeAll("verify_ssl: true\n");

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse voltrc config" {
    var config = VoltConfig.init(std.testing.allocator);
    defer config.deinit();

    const content =
        \\base_url: https://api.example.com
        \\timeout: 5000
        \\environment: staging
        \\verbose: true
        \\output: compact
        \\headers:
        \\  - Accept: application/json
        \\  - X-Custom: test
    ;

    try parseConfig(&config, content);

    try std.testing.expectEqualStrings("https://api.example.com", config.base_url.?);
    try std.testing.expectEqual(@as(u32, 5000), config.timeout_ms);
    try std.testing.expectEqualStrings("staging", config.environment.?);
    try std.testing.expect(config.verbose);
    try std.testing.expect(config.output_format == .compact);
    try std.testing.expectEqual(@as(usize, 2), config.default_headers.items.len);
    try std.testing.expectEqualStrings("Accept", config.default_headers.items[0].name);
}

test "generate default config" {
    const output = try generateDefaultConfig(std.testing.allocator);
    defer std.testing.allocator.free(output);

    try std.testing.expect(mem.indexOf(u8, output, "timeout") != null);
    try std.testing.expect(mem.indexOf(u8, output, "headers") != null);
    try std.testing.expect(mem.indexOf(u8, output, "output: pretty") != null);
}

test "default config values" {
    var config = VoltConfig.init(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 30_000), config.timeout_ms);
    try std.testing.expect(config.follow_redirects);
    try std.testing.expect(config.verify_ssl);
    try std.testing.expect(config.base_url == null);
}
