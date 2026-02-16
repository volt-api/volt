const std = @import("std");
const builtin = @import("builtin");

// ── Key Input ───────────────────────────────────────────────────────────

pub const Key = enum {
    // Navigation
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    // Actions
    enter,
    tab,
    backspace,
    delete,
    escape,
    // Ctrl combinations
    ctrl_c,
    ctrl_d,
    ctrl_p,
    ctrl_q,
    ctrl_s,
    ctrl_r,
    ctrl_l,
    ctrl_w,
    // Characters
    char,
    // Special
    unknown,
    none,
};

pub const InputEvent = struct {
    key: Key,
    char: u8 = 0,
};

pub fn enableRawMode() void {
    if (builtin.os.tag == .windows) {
        enableRawModeWindows();
    }
}

pub fn disableRawMode() void {
    if (builtin.os.tag == .windows) {
        disableRawModeWindows();
    }
}

var original_mode: u32 = 0;

fn enableRawModeWindows() void {
    if (builtin.os.tag != .windows) return;
    const kernel32 = std.os.windows.kernel32;
    const handle = kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) orelse return;

    _ = kernel32.GetConsoleMode(handle, &original_mode);

    // Enable virtual terminal input, disable line input and echo
    const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
    const new_mode = (original_mode & ~@as(u32, 0x0006)) | ENABLE_VIRTUAL_TERMINAL_INPUT; // Disable ECHO and LINE_INPUT
    _ = kernel32.SetConsoleMode(handle, new_mode);

    // Also enable VT processing on output
    const out_handle = kernel32.GetStdHandle(std.os.windows.STD_OUTPUT_HANDLE) orelse return;
    var out_mode: u32 = 0;
    _ = kernel32.GetConsoleMode(out_handle, &out_mode);
    const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
    _ = kernel32.SetConsoleMode(out_handle, out_mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
}

fn disableRawModeWindows() void {
    if (builtin.os.tag != .windows) return;
    const kernel32 = std.os.windows.kernel32;
    const handle = kernel32.GetStdHandle(std.os.windows.STD_INPUT_HANDLE) orelse return;
    _ = kernel32.SetConsoleMode(handle, original_mode);
}

pub fn readKey() InputEvent {
    const stdin = std.io.getStdIn();
    var buf: [8]u8 = undefined;
    const n = stdin.read(&buf) catch return .{ .key = .none };
    if (n == 0) return .{ .key = .none };

    // Single byte
    if (n == 1) {
        return switch (buf[0]) {
            3 => .{ .key = .ctrl_c },
            4 => .{ .key = .ctrl_d },
            9 => .{ .key = .tab },
            10, 13 => .{ .key = .enter },
            12 => .{ .key = .ctrl_l },
            16 => .{ .key = .ctrl_p },
            17 => .{ .key = .ctrl_q },
            18 => .{ .key = .ctrl_r },
            19 => .{ .key = .ctrl_s },
            23 => .{ .key = .ctrl_w },
            27 => .{ .key = .escape },
            127 => .{ .key = .backspace },
            else => |c| if (c >= 32 and c < 127)
                .{ .key = .char, .char = c }
            else
                .{ .key = .unknown },
        };
    }

    // Escape sequences
    if (buf[0] == 27 and n >= 3) {
        if (buf[1] == '[') {
            return switch (buf[2]) {
                'A' => .{ .key = .up },
                'B' => .{ .key = .down },
                'C' => .{ .key = .right },
                'D' => .{ .key = .left },
                'H' => .{ .key = .home },
                'F' => .{ .key = .end },
                '3' => .{ .key = .delete },
                '5' => .{ .key = .page_up },
                '6' => .{ .key = .page_down },
                else => .{ .key = .unknown },
            };
        }
    }

    return .{ .key = .unknown };
}
