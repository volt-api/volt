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

/// Rosé Pine theme - muted purples/pinks with rose gold accents.
pub const rose_pine = ThemeColors{
    .primary = "\x1b[38;5;211m",
    .success = "\x1b[38;5;108m",
    .error_color = "\x1b[38;5;167m",
    .warning = "\x1b[38;5;216m",
    .muted = "\x1b[38;5;59m",
    .key = "\x1b[38;5;182m",
    .string = "\x1b[38;5;216m",
    .number = "\x1b[38;5;211m",
    .boolean = "\x1b[38;5;139m",
    .null_color = "\x1b[38;5;59m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Catppuccin Mocha theme - pastel colors on dark background.
pub const catppuccin = ThemeColors{
    .primary = "\x1b[38;5;183m",
    .success = "\x1b[38;5;115m",
    .error_color = "\x1b[38;5;211m",
    .warning = "\x1b[38;5;223m",
    .muted = "\x1b[38;5;60m",
    .key = "\x1b[38;5;117m",
    .string = "\x1b[38;5;115m",
    .number = "\x1b[38;5;216m",
    .boolean = "\x1b[38;5;183m",
    .null_color = "\x1b[38;5;60m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// GitHub Dark Default theme.
pub const github_dark = ThemeColors{
    .primary = "\x1b[38;5;75m",
    .success = "\x1b[38;5;114m",
    .error_color = "\x1b[38;5;203m",
    .warning = "\x1b[38;5;215m",
    .muted = "\x1b[38;5;245m",
    .key = "\x1b[38;5;75m",
    .string = "\x1b[38;5;117m",
    .number = "\x1b[38;5;117m",
    .boolean = "\x1b[38;5;75m",
    .null_color = "\x1b[38;5;245m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// GitHub Light Default theme.
pub const github_light = ThemeColors{
    .primary = "\x1b[38;5;33m",
    .success = "\x1b[38;5;28m",
    .error_color = "\x1b[38;5;160m",
    .warning = "\x1b[38;5;130m",
    .muted = "\x1b[38;5;102m",
    .key = "\x1b[38;5;33m",
    .string = "\x1b[38;5;25m",
    .number = "\x1b[38;5;25m",
    .boolean = "\x1b[38;5;33m",
    .null_color = "\x1b[38;5;102m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// One Dark Pro theme - Atom editor style.
pub const one_dark = ThemeColors{
    .primary = "\x1b[38;5;75m",
    .success = "\x1b[38;5;114m",
    .error_color = "\x1b[38;5;204m",
    .warning = "\x1b[38;5;180m",
    .muted = "\x1b[38;5;59m",
    .key = "\x1b[38;5;204m",
    .string = "\x1b[38;5;114m",
    .number = "\x1b[38;5;173m",
    .boolean = "\x1b[38;5;173m",
    .null_color = "\x1b[38;5;59m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Gruvbox Dark theme - retro earthy tones.
pub const gruvbox = ThemeColors{
    .primary = "\x1b[38;5;108m",
    .success = "\x1b[38;5;142m",
    .error_color = "\x1b[38;5;167m",
    .warning = "\x1b[38;5;214m",
    .muted = "\x1b[38;5;243m",
    .key = "\x1b[38;5;108m",
    .string = "\x1b[38;5;142m",
    .number = "\x1b[38;5;175m",
    .boolean = "\x1b[38;5;175m",
    .null_color = "\x1b[38;5;243m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Tokyo Night theme - blue-purple neon palette.
pub const tokyo_night = ThemeColors{
    .primary = "\x1b[38;5;75m",
    .success = "\x1b[38;5;115m",
    .error_color = "\x1b[38;5;203m",
    .warning = "\x1b[38;5;215m",
    .muted = "\x1b[38;5;59m",
    .key = "\x1b[38;5;75m",
    .string = "\x1b[38;5;115m",
    .number = "\x1b[38;5;215m",
    .boolean = "\x1b[38;5;173m",
    .null_color = "\x1b[38;5;59m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Kanagawa theme - wave theme with Japanese palette.
pub const kanagawa = ThemeColors{
    .primary = "\x1b[38;5;110m",
    .success = "\x1b[38;5;108m",
    .error_color = "\x1b[38;5;167m",
    .warning = "\x1b[38;5;179m",
    .muted = "\x1b[38;5;102m",
    .key = "\x1b[38;5;110m",
    .string = "\x1b[38;5;108m",
    .number = "\x1b[38;5;175m",
    .boolean = "\x1b[38;5;173m",
    .null_color = "\x1b[38;5;102m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Everforest Dark theme - green-based nature palette.
pub const everforest = ThemeColors{
    .primary = "\x1b[38;5;108m",
    .success = "\x1b[38;5;142m",
    .error_color = "\x1b[38;5;167m",
    .warning = "\x1b[38;5;214m",
    .muted = "\x1b[38;5;102m",
    .key = "\x1b[38;5;108m",
    .string = "\x1b[38;5;142m",
    .number = "\x1b[38;5;175m",
    .boolean = "\x1b[38;5;210m",
    .null_color = "\x1b[38;5;102m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Ayu Dark theme - warm orange accents.
pub const ayu = ThemeColors{
    .primary = "\x1b[38;5;208m",
    .success = "\x1b[38;5;149m",
    .error_color = "\x1b[38;5;203m",
    .warning = "\x1b[38;5;215m",
    .muted = "\x1b[38;5;59m",
    .key = "\x1b[38;5;208m",
    .string = "\x1b[38;5;149m",
    .number = "\x1b[38;5;208m",
    .boolean = "\x1b[38;5;208m",
    .null_color = "\x1b[38;5;59m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Synthwave '84 theme - neon pink/cyan/purple.
pub const synthwave = ThemeColors{
    .primary = "\x1b[38;5;51m",
    .success = "\x1b[38;5;84m",
    .error_color = "\x1b[38;5;197m",
    .warning = "\x1b[38;5;220m",
    .muted = "\x1b[38;5;60m",
    .key = "\x1b[38;5;51m",
    .string = "\x1b[38;5;213m",
    .number = "\x1b[38;5;141m",
    .boolean = "\x1b[38;5;213m",
    .null_color = "\x1b[38;5;60m",
    .bold = "\x1b[1m",
    .reset = "\x1b[0m",
};

/// Material Palenight theme - muted pastels.
pub const palenight = ThemeColors{
    .primary = "\x1b[38;5;111m",
    .success = "\x1b[38;5;115m",
    .error_color = "\x1b[38;5;204m",
    .warning = "\x1b[38;5;222m",
    .muted = "\x1b[38;5;60m",
    .key = "\x1b[38;5;111m",
    .string = "\x1b[38;5;115m",
    .number = "\x1b[38;5;216m",
    .boolean = "\x1b[38;5;204m",
    .null_color = "\x1b[38;5;60m",
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
    .{ .name = "rose_pine", .colors = rose_pine },
    .{ .name = "catppuccin", .colors = catppuccin },
    .{ .name = "github_dark", .colors = github_dark },
    .{ .name = "github_light", .colors = github_light },
    .{ .name = "one_dark", .colors = one_dark },
    .{ .name = "gruvbox", .colors = gruvbox },
    .{ .name = "tokyo_night", .colors = tokyo_night },
    .{ .name = "kanagawa", .colors = kanagawa },
    .{ .name = "everforest", .colors = everforest },
    .{ .name = "ayu", .colors = ayu },
    .{ .name = "synthwave", .colors = synthwave },
    .{ .name = "palenight", .colors = palenight },
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
    try std.testing.expect(mem.indexOf(u8, output, "rose_pine") != null);
    try std.testing.expect(mem.indexOf(u8, output, "catppuccin") != null);
    try std.testing.expect(mem.indexOf(u8, output, "github_dark") != null);
    try std.testing.expect(mem.indexOf(u8, output, "github_light") != null);
    try std.testing.expect(mem.indexOf(u8, output, "one_dark") != null);
    try std.testing.expect(mem.indexOf(u8, output, "gruvbox") != null);
    try std.testing.expect(mem.indexOf(u8, output, "tokyo_night") != null);
    try std.testing.expect(mem.indexOf(u8, output, "kanagawa") != null);
    try std.testing.expect(mem.indexOf(u8, output, "everforest") != null);
    try std.testing.expect(mem.indexOf(u8, output, "ayu") != null);
    try std.testing.expect(mem.indexOf(u8, output, "synthwave") != null);
    try std.testing.expect(mem.indexOf(u8, output, "palenight") != null);
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

test "new themes have correct primary colors" {
    // Rosé Pine - rose gold primary (256-color 211)
    const rp = getTheme("rose_pine");
    try std.testing.expectEqualStrings("\x1b[38;5;211m", rp.primary);

    // Catppuccin Mocha - lavender primary (256-color 183)
    const cat = getTheme("catppuccin");
    try std.testing.expectEqualStrings("\x1b[38;5;183m", cat.primary);

    // GitHub Dark - blue primary (256-color 75)
    const ghd = getTheme("github_dark");
    try std.testing.expectEqualStrings("\x1b[38;5;75m", ghd.primary);

    // GitHub Light - blue primary (256-color 33)
    const ghl = getTheme("github_light");
    try std.testing.expectEqualStrings("\x1b[38;5;33m", ghl.primary);

    // One Dark - blue primary (256-color 75)
    const od = getTheme("one_dark");
    try std.testing.expectEqualStrings("\x1b[38;5;75m", od.primary);

    // Gruvbox - aqua primary (256-color 108)
    const gb = getTheme("gruvbox");
    try std.testing.expectEqualStrings("\x1b[38;5;108m", gb.primary);

    // Tokyo Night - blue primary (256-color 75)
    const tn = getTheme("tokyo_night");
    try std.testing.expectEqualStrings("\x1b[38;5;75m", tn.primary);

    // Kanagawa - blue primary (256-color 110)
    const kg = getTheme("kanagawa");
    try std.testing.expectEqualStrings("\x1b[38;5;110m", kg.primary);

    // Everforest - green primary (256-color 108)
    const ef = getTheme("everforest");
    try std.testing.expectEqualStrings("\x1b[38;5;108m", ef.primary);

    // Ayu - orange primary (256-color 208)
    const ay = getTheme("ayu");
    try std.testing.expectEqualStrings("\x1b[38;5;208m", ay.primary);

    // Synthwave - cyan primary (256-color 51)
    const sw = getTheme("synthwave");
    try std.testing.expectEqualStrings("\x1b[38;5;51m", sw.primary);

    // Palenight - blue primary (256-color 111)
    const pn = getTheme("palenight");
    try std.testing.expectEqualStrings("\x1b[38;5;111m", pn.primary);
}
