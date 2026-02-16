const std = @import("std");
const builtin = @import("builtin");

// ── Terminal Control ────────────────────────────────────────────────────

pub const Color = enum(u8) {
    black = 30,
    red = 31,
    green = 32,
    yellow = 33,
    blue = 34,
    magenta = 35,
    cyan = 36,
    white = 37,
    default = 39,
    bright_black = 90,
    bright_red = 91,
    bright_green = 92,
    bright_yellow = 93,
    bright_blue = 94,
    bright_magenta = 95,
    bright_cyan = 96,
    bright_white = 97,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
};

pub const TermSize = struct {
    width: u16,
    height: u16,
};

pub fn getTermSize() TermSize {
    if (builtin.os.tag == .windows) {
        return getTermSizeWindows();
    }
    return getTermSizePosix();
}

fn getTermSizeWindows() TermSize {
    if (builtin.os.tag != .windows) return .{ .width = 120, .height = 40 };

    const kernel32 = std.os.windows.kernel32;
    const handle = kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse
        return .{ .width = 120, .height = 40 };

    var info: std.os.windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (kernel32.GetConsoleScreenBufferInfo(handle, &info) == 0) {
        return .{ .width = 120, .height = 40 };
    }

    const width = @as(u16, @intCast(info.srWindow.Right - info.srWindow.Left + 1));
    const height = @as(u16, @intCast(info.srWindow.Bottom - info.srWindow.Top + 1));
    return .{ .width = width, .height = height };
}

fn getTermSizePosix() TermSize {
    return .{ .width = 120, .height = 40 };
}

pub const Writer = struct {
    buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{
            .buf = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit();
    }

    pub fn flush(self: *Writer) !void {
        const stdout = std.io.getStdOut();
        try stdout.writeAll(self.buf.items);
        self.buf.clearRetainingCapacity();
    }

    pub fn write(self: *Writer, text: []const u8) !void {
        try self.buf.appendSlice(text);
    }

    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.buf.writer().print(fmt, args);
    }

    // ── Escape sequences ────────────────────────────────────────────

    pub fn clearScreen(self: *Writer) !void {
        try self.write("\x1b[2J");
    }

    pub fn moveTo(self: *Writer, row: u16, col: u16) !void {
        try self.print("\x1b[{d};{d}H", .{ row, col });
    }

    pub fn hideCursor(self: *Writer) !void {
        try self.write("\x1b[?25l");
    }

    pub fn showCursor(self: *Writer) !void {
        try self.write("\x1b[?25h");
    }

    pub fn setStyle(self: *Writer, style: Style) !void {
        try self.write("\x1b[0m"); // Reset first
        if (style.bold) try self.write("\x1b[1m");
        if (style.dim) try self.write("\x1b[2m");
        if (style.italic) try self.write("\x1b[3m");
        if (style.underline) try self.write("\x1b[4m");
        if (style.reverse) try self.write("\x1b[7m");
        if (style.fg != .default) {
            try self.print("\x1b[{d}m", .{@intFromEnum(style.fg)});
        }
        if (style.bg != .default) {
            try self.print("\x1b[{d}m", .{@intFromEnum(style.bg) + 10});
        }
    }

    pub fn resetStyle(self: *Writer) !void {
        try self.write("\x1b[0m");
    }

    pub fn setFg(self: *Writer, color: Color) !void {
        try self.print("\x1b[{d}m", .{@intFromEnum(color)});
    }

    pub fn setBold(self: *Writer) !void {
        try self.write("\x1b[1m");
    }

    pub fn setDim(self: *Writer) !void {
        try self.write("\x1b[2m");
    }

    // ── Drawing primitives ──────────────────────────────────────────

    pub fn drawHLine(self: *Writer, row: u16, col: u16, len: u16, char: u8) !void {
        try self.moveTo(row, col);
        var i: u16 = 0;
        while (i < len) : (i += 1) {
            try self.buf.append(char);
        }
    }

    pub fn drawVLine(self: *Writer, row: u16, col: u16, len: u16, char: u8) !void {
        var i: u16 = 0;
        while (i < len) : (i += 1) {
            try self.moveTo(row + i, col);
            try self.buf.append(char);
        }
    }

    pub fn drawBox(self: *Writer, row: u16, col: u16, width: u16, height: u16) !void {
        // Top border
        try self.moveTo(row, col);
        try self.write("\xe2\x94\x8c"); // ┌
        var i: u16 = 0;
        while (i < width -| 2) : (i += 1) {
            try self.write("\xe2\x94\x80"); // ─
        }
        try self.write("\xe2\x94\x90"); // ┐

        // Sides
        i = 1;
        while (i < height -| 1) : (i += 1) {
            try self.moveTo(row + i, col);
            try self.write("\xe2\x94\x82"); // │
            try self.moveTo(row + i, col + width -| 1);
            try self.write("\xe2\x94\x82"); // │
        }

        // Bottom border
        try self.moveTo(row + height -| 1, col);
        try self.write("\xe2\x94\x94"); // └
        i = 0;
        while (i < width -| 2) : (i += 1) {
            try self.write("\xe2\x94\x80"); // ─
        }
        try self.write("\xe2\x94\x98"); // ┘
    }

    pub fn writeAt(self: *Writer, row: u16, col: u16, text: []const u8) !void {
        try self.moveTo(row, col);
        try self.write(text);
    }

    pub fn writeAtTruncated(self: *Writer, row: u16, col: u16, text: []const u8, max_width: u16) !void {
        try self.moveTo(row, col);
        if (text.len <= max_width) {
            try self.write(text);
        } else if (max_width > 3) {
            try self.write(text[0 .. max_width - 3]);
            try self.write("...");
        }
    }
};
