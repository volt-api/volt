const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Color Themes for TUI Customization ──────────────────────────────────
//
// Provides built-in color themes for terminal output.
// Themes control ANSI escape codes for syntax highlighting,
// status colors, and general terminal formatting.

pub const ThemeColors = struct {
    primary: []const u8 = "\x1b[36m",
    success: []const u8 = "\x1b[32m",
    error_color: []const u8 = "\x1b[31m",
    warning: []const u8 = "\x1b[33m",
    muted: []const u8 = "\x1b[90m",
    key: []const u8 = "\x1b[36m",
    string: []const u8 = "\x1b[32m",
    number: []const u8 = "\x1b[33m",
    boolean: []const u8 = "\x1b[35m",
    null_color: []const u8 = "\x1b[90m",
    bold: []const u8 = "\x1b[1m",
    reset: []const u8 = "\x1b[0m",
};

pub const Theme = struct {
    name: []const u8,
    colors: ThemeColors,
};

// ── Built-in Themes ─────────────────────────────────────────────────────

/// Dark theme - the default colors used in Volt.
pub const dark = ThemeColors{
    .primary = "\x1b[36m",
    .success = "\x1b[32m",
    .error_color = "\x1b[31m",
    .warning = "\x1b[33m",
    .muted = "\x1b[90m",
    .key = "\x1b[36m",
    .string = "\x1b[32m",
    .number = "\x1b[33m",
    .boolean = "\x1b[35m",
    .null_color = "\x1b[90m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Light theme - inverted for light terminal backgrounds.
pub const light = ThemeColors{
    .primary = "\x1b[34m",
    .success = "\x1b[32m",
    .error_color = "\x1b[31m",
    .warning = "\x1b[33m",
    .muted = "\x1b[37m",
    .key = "\x1b[34m",
    .string = "\x1b[32m",
    .number = "\x1b[33m",
    .boolean = "\x1b[35m",
    .null_color = "\x1b[37m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Solarized theme - based on the Solarized color palette.
pub const solarized = ThemeColors{
    .primary = "\x1b[38;5;37m",
    .success = "\x1b[38;5;64m",
    .error_color = "\x1b[38;5;160m",
    .warning = "\x1b[38;5;136m",
    .muted = "\x1b[38;5;246m",
    .key = "\x1b[38;5;37m",
    .string = "\x1b[38;5;64m",
    .number = "\x1b[38;5;136m",
    .boolean = "\x1b[38;5;125m",
    .null_color = "\x1b[38;5;246m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Nord theme - blue/cyan heavy, inspired by Arctic colors.
pub const nord = ThemeColors{
    .primary = "\x1b[38;5;81m",
    .success = "\x1b[38;5;108m",
    .error_color = "\x1b[38;5;174m",
    .warning = "\x1b[38;5;179m",
    .muted = "\x1b[38;5;60m",
    .key = "\x1b[38;5;81m",
    .string = "\x1b[38;5;108m",
    .number = "\x1b[38;5;173m",
    .boolean = "\x1b[38;5;139m",
    .null_color = "\x1b[38;5;60m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Dracula theme - purple heavy, based on the Dracula palette.
pub const dracula = ThemeColors{
    .primary = "\x1b[38;5;141m",
    .success = "\x1b[38;5;84m",
    .error_color = "\x1b[38;5;210m",
    .warning = "\x1b[38;5;228m",
    .muted = "\x1b[38;5;61m",
    .key = "\x1b[38;5;141m",
    .string = "\x1b[38;5;228m",
    .number = "\x1b[38;5;141m",
    .boolean = "\x1b[38;5;212m",
    .null_color = "\x1b[38;5;61m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Monokai theme - orange/green, based on the Monokai palette.
pub const monokai = ThemeColors{
    .primary = "\x1b[38;5;81m",
    .success = "\x1b[38;5;118m",
    .error_color = "\x1b[38;5;197m",
    .warning = "\x1b[38;5;208m",
    .muted = "\x1b[38;5;242m",
    .key = "\x1b[38;5;81m",
    .string = "\x1b[38;5;186m",
    .number = "\x1b[38;5;141m",
    .boolean = "\x1b[38;5;141m",
    .null_color = "\x1b[38;5;242m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// No-color theme - all empty strings, for piping and non-TTY output.
pub const none = ThemeColors{
    .primary = "",
    .success = "",
    .error_color = "",
    .warning = "",
    .muted = "",
    .key = "",
    .string = "",
    .number = "",
    .boolean = "",
    .null_color = "",
    .bold = "",
    .reset = "",
};

/// All available built-in themes.
const builtin_themes = [_]Theme{
    .{ .name = "dark", .colors = dark },
    .{ .name = "light", .colors = light },
    .{ .name = "solarized", .colors = solarized },
    .{ .name = "nord", .colors = nord },
    .{ .name = "dracula", .colors = dracula },
    .{ .name = "monokai", .colors = monokai },
    .{ .name = "none", .colors = none },
};

/// Look up a theme by name. Returns the dark theme if not found.
pub fn getTheme(name: []const u8) ThemeColors {
    for (builtin_themes) |theme| {
        if (mem.eql(u8, theme.name, name)) return theme.colors;
    }
    return dark;
}

/// Parse theme name from .voltrc config content and return the theme colors.
/// Looks for a line like "theme: nord" in the config.
/// Returns null if no theme line is found.
pub fn loadThemeFromConfig(allocator: Allocator, config_content: []const u8) ?ThemeColors {
    _ = allocator;

    var lines = mem.splitSequence(u8, config_content, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trim(u8, mem.trimRight(u8, raw_line, "\r"), " \t");
        if (line.len == 0 or line[0] == '#') continue;

        if (mem.startsWith(u8, line, "theme:")) {
            const theme_name = mem.trim(u8, line["theme:".len..], " \t");
            if (theme_name.len > 0) {
                return getTheme(theme_name);
            }
        }
    }

    return null;
}

/// Format available themes for display.
pub fn listThemes(allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("\x1b[1mAvailable Themes\x1b[0m\n\n");

    for (builtin_themes) |theme| {
        try writer.print("  {s}{s}\x1b[0m", .{ theme.colors.primary, theme.name });

        // Show color samples
        try writer.print("  {s}success\x1b[0m", .{theme.colors.success});
        try writer.print("  {s}error\x1b[0m", .{theme.colors.error_color});
        try writer.print("  {s}warning\x1b[0m", .{theme.colors.warning});
        try writer.print("  {s}muted\x1b[0m", .{theme.colors.muted});
        try writer.writeAll("\n");
    }

    try writer.print("\n  Set theme in .voltrc: theme: <name>\n", .{});

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "get theme by name" {
    const dark_theme = getTheme("dark");
    try std.testing.expectEqualStrings("\x1b[36m", dark_theme.primary);
    try std.testing.expectEqualStrings("\x1b[32m", dark_theme.success);
    try std.testing.expectEqualStrings("\x1b[0m", dark_theme.reset);

    const nord_theme = getTheme("nord");
    try std.testing.expectEqualStrings("\x1b[38;5;81m", nord_theme.primary);

    const dracula_theme = getTheme("dracula");
    try std.testing.expectEqualStrings("\x1b[38;5;141m", dracula_theme.primary);

    const none_theme = getTheme("none");
    try std.testing.expectEqualStrings("", none_theme.primary);
    try std.testing.expectEqualStrings("", none_theme.success);
    try std.testing.expectEqualStrings("", none_theme.reset);
}

test "get theme unknown name returns dark" {
    const theme = getTheme("nonexistent-theme");
    try std.testing.expectEqualStrings("\x1b[36m", theme.primary);
    try std.testing.expectEqualStrings("\x1b[32m", theme.success);
    try std.testing.expectEqualStrings("\x1b[31m", theme.error_color);
}

test "load theme from config" {
    const config_content =
        \\# Volt config
        \\base_url: https://api.example.com
        \\theme: nord
        \\timeout: 5000
    ;

    const theme = loadThemeFromConfig(std.testing.allocator, config_content).?;
    try std.testing.expectEqualStrings("\x1b[38;5;81m", theme.primary);
}

test "load theme from config no theme line" {
    const config_content =
        \\base_url: https://api.example.com
        \\timeout: 5000
    ;

    try std.testing.expect(loadThemeFromConfig(std.testing.allocator, config_content) == null);
}

test "load theme from config unknown theme defaults to dark" {
    const config_content =
        \\theme: unknown-theme
    ;

    const theme = loadThemeFromConfig(std.testing.allocator, config_content).?;
    try std.testing.expectEqualStrings("\x1b[36m", theme.primary);
}

test "list themes" {
    const output = try listThemes(std.testing.allocator);
    defer std.testing.allocator.free(output);

    try std.testing.expect(mem.indexOf(u8, output, "dark") != null);
    try std.testing.expect(mem.indexOf(u8, output, "light") != null);
    try std.testing.expect(mem.indexOf(u8, output, "solarized") != null);
    try std.testing.expect(mem.indexOf(u8, output, "nord") != null);
    try std.testing.expect(mem.indexOf(u8, output, "dracula") != null);
    try std.testing.expect(mem.indexOf(u8, output, "monokai") != null);
    try std.testing.expect(mem.indexOf(u8, output, "none") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Available Themes") != null);
}

test "theme colors are consistent" {
    // Every theme should have a non-null reset
    for (builtin_themes) |theme| {
        // The "none" theme has empty reset, others have the ANSI reset
        if (mem.eql(u8, theme.name, "none")) {
            try std.testing.expectEqualStrings("", theme.colors.reset);
        } else {
            try std.testing.expectEqualStrings("\x1b[0m", theme.colors.reset);
        }
        // Bold should be consistent across color themes
        if (!mem.eql(u8, theme.name, "none")) {
            try std.testing.expectEqualStrings("\x1b[1m", theme.colors.bold);
        }
    }
}
