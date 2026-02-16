const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── JSON Formatter with Syntax Highlighting ─────────────────────────────
// Pretty-prints JSON with ANSI colors for terminal output.

const Color = struct {
    const reset = "\x1b[0m";
    const key = "\x1b[36m"; // cyan
    const string = "\x1b[32m"; // green
    const number = "\x1b[33m"; // yellow
    const boolean = "\x1b[35m"; // magenta
    const null_val = "\x1b[90m"; // gray
    const brace = "\x1b[0m"; // default
    const comma = "\x1b[90m"; // gray
};

/// Pretty-print JSON with syntax highlighting
pub fn formatJson(allocator: Allocator, input: []const u8, colorize: bool) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const trimmed = mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return buf.toOwnedSlice();

    var indent_level: usize = 0;
    var in_string = false;
    var escape_next = false;
    var i: usize = 0;

    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];

        if (escape_next) {
            try buf.append(c);
            escape_next = false;
            continue;
        }

        if (c == '\\' and in_string) {
            try buf.append(c);
            escape_next = true;
            continue;
        }

        if (c == '"') {
            if (!in_string) {
                in_string = true;
                // Check if this is a key (next non-whitespace after value is ':')
                const is_key = isJsonKey(trimmed, i);
                if (colorize) {
                    if (is_key) {
                        try buf.appendSlice(Color.key);
                    } else {
                        try buf.appendSlice(Color.string);
                    }
                }
                try buf.append('"');
            } else {
                in_string = false;
                try buf.append('"');
                if (colorize) try buf.appendSlice(Color.reset);
            }
            continue;
        }

        if (in_string) {
            try buf.append(c);
            continue;
        }

        // Outside string
        switch (c) {
            '{', '[' => {
                if (colorize) try buf.appendSlice(Color.brace);
                try buf.append(c);
                if (colorize) try buf.appendSlice(Color.reset);
                indent_level += 1;

                // Check if empty object/array
                const close: u8 = if (c == '{') '}' else ']';
                const next_non_ws = nextNonWhitespace(trimmed, i + 1);
                if (next_non_ws < trimmed.len and trimmed[next_non_ws] == close) {
                    // Empty - print inline
                    if (colorize) try buf.appendSlice(Color.brace);
                    try buf.append(close);
                    if (colorize) try buf.appendSlice(Color.reset);
                    indent_level -= 1;
                    i = next_non_ws;
                } else {
                    try buf.append('\n');
                    try writeIndent(&buf, indent_level);
                }
            },
            '}', ']' => {
                indent_level -|= 1;
                try buf.append('\n');
                try writeIndent(&buf, indent_level);
                if (colorize) try buf.appendSlice(Color.brace);
                try buf.append(c);
                if (colorize) try buf.appendSlice(Color.reset);
            },
            ',' => {
                if (colorize) try buf.appendSlice(Color.comma);
                try buf.append(',');
                if (colorize) try buf.appendSlice(Color.reset);
                try buf.append('\n');
                try writeIndent(&buf, indent_level);
            },
            ':' => {
                try buf.appendSlice(": ");
            },
            't', 'f' => {
                // true/false
                if (colorize) try buf.appendSlice(Color.boolean);
                if (c == 't' and i + 3 < trimmed.len and mem.eql(u8, trimmed[i .. i + 4], "true")) {
                    try buf.appendSlice("true");
                    i += 3;
                } else if (c == 'f' and i + 4 < trimmed.len and mem.eql(u8, trimmed[i .. i + 5], "false")) {
                    try buf.appendSlice("false");
                    i += 4;
                } else {
                    try buf.append(c);
                }
                if (colorize) try buf.appendSlice(Color.reset);
            },
            'n' => {
                // null
                if (i + 3 < trimmed.len and mem.eql(u8, trimmed[i .. i + 4], "null")) {
                    if (colorize) try buf.appendSlice(Color.null_val);
                    try buf.appendSlice("null");
                    if (colorize) try buf.appendSlice(Color.reset);
                    i += 3;
                } else {
                    try buf.append(c);
                }
            },
            '0'...'9', '-' => {
                // Number
                if (colorize) try buf.appendSlice(Color.number);
                try buf.append(c);
                while (i + 1 < trimmed.len and isNumberChar(trimmed[i + 1])) {
                    i += 1;
                    try buf.append(trimmed[i]);
                }
                if (colorize) try buf.appendSlice(Color.reset);
            },
            ' ', '\t', '\n', '\r' => {
                // Skip existing whitespace (we control formatting)
            },
            else => {
                try buf.append(c);
            },
        }
    }

    try buf.append('\n');
    return buf.toOwnedSlice();
}

/// Format JSON without colors (for file output)
pub fn formatJsonPlain(allocator: Allocator, input: []const u8) ![]const u8 {
    return formatJson(allocator, input, false);
}

/// Minify JSON (remove whitespace)
pub fn minifyJson(allocator: Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var in_string = false;
    var escape_next = false;

    for (input) |c| {
        if (escape_next) {
            try buf.append(c);
            escape_next = false;
            continue;
        }
        if (c == '\\' and in_string) {
            try buf.append(c);
            escape_next = true;
            continue;
        }
        if (c == '"') {
            in_string = !in_string;
            try buf.append(c);
            continue;
        }
        if (in_string) {
            try buf.append(c);
            continue;
        }
        // Skip whitespace outside strings
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') continue;
        try buf.append(c);
    }

    return buf.toOwnedSlice();
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn writeIndent(buf: *std.ArrayList(u8), level: usize) !void {
    var l: usize = 0;
    while (l < level) : (l += 1) {
        try buf.appendSlice("  ");
    }
}

fn isNumberChar(c: u8) bool {
    return (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '+' or c == 'e' or c == 'E';
}

fn nextNonWhitespace(data: []const u8, start: usize) usize {
    var i = start;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t' or data[i] == '\n' or data[i] == '\r')) : (i += 1) {}
    return i;
}

fn isJsonKey(json: []const u8, quote_pos: usize) bool {
    // Look ahead from the closing quote to see if ':' follows
    var i = quote_pos + 1;
    // Skip the string content
    var escape = false;
    while (i < json.len) : (i += 1) {
        if (escape) {
            escape = false;
            continue;
        }
        if (json[i] == '\\') {
            escape = true;
            continue;
        }
        if (json[i] == '"') {
            // Found closing quote, check what follows
            var j = i + 1;
            while (j < json.len and (json[j] == ' ' or json[j] == '\t')) : (j += 1) {}
            return j < json.len and json[j] == ':';
        }
    }
    return false;
}

// ── XML Formatter ───────────────────────────────────────────────────────

/// Basic XML pretty-printer
pub fn formatXml(allocator: Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var indent_level: usize = 0;
    var i: usize = 0;
    var in_tag = false;

    while (i < input.len) {
        if (input[i] == '<') {
            if (i + 1 < input.len and input[i + 1] == '/') {
                // Closing tag
                indent_level -|= 1;
                try buf.append('\n');
                try writeIndent(&buf, indent_level);
            } else if (!in_tag) {
                if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
                    try buf.append('\n');
                }
                try writeIndent(&buf, indent_level);
                indent_level += 1;
            }
            in_tag = true;
            try buf.append('<');
        } else if (input[i] == '>') {
            in_tag = false;
            try buf.append('>');
            // Check for self-closing tag
            if (buf.items.len >= 2 and buf.items[buf.items.len - 2] == '/') {
                indent_level -|= 1;
            }
        } else {
            try buf.append(input[i]);
        }
        i += 1;
    }

    if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '\n') {
        try buf.append('\n');
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "format simple json" {
    const input = "{\"name\":\"John\",\"age\":30}";
    const result = try formatJsonPlain(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "\"name\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"John\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "30") != null);
    // Should have newlines (pretty-printed)
    try std.testing.expect(mem.indexOf(u8, result, "\n") != null);
}

test "format nested json" {
    const input = "{\"user\":{\"name\":\"John\",\"scores\":[1,2,3]}}";
    const result = try formatJsonPlain(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "\"user\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"name\"") != null);
}

test "minify json" {
    const input = "{\n  \"name\": \"John\",\n  \"age\": 30\n}";
    const result = try minifyJson(std.testing.allocator, input);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("{\"name\":\"John\",\"age\":30}", result);
}

test "format empty json" {
    const result = try formatJsonPlain(std.testing.allocator, "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expect(mem.indexOf(u8, result, "{}") != null);
}
