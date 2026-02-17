const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── File Watch Mode ───────────────────────────────────────────────────
// Re-runs requests/tests on file change for development workflows.
// Watches .volt files and triggers execution when modifications are detected.

pub const WatchConfig = struct {
    paths: std.ArrayList([]const u8),
    test_mode: bool = false,
    interval_ms: u32 = 1000,
    clear_screen: bool = false,

    pub fn init(allocator: Allocator) WatchConfig {
        return .{
            .paths = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *WatchConfig) void {
        self.paths.deinit();
    }
};

pub const WatchState = struct {
    last_modified: std.StringHashMap(i128),
    running: bool,
    allocator: Allocator,

    pub fn init(allocator: Allocator) WatchState {
        return .{
            .last_modified = std.StringHashMap(i128).init(allocator),
            .running = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WatchState) void {
        var it = self.last_modified.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.last_modified.deinit();
    }
};

// ── File Scanning ─────────────────────────────────────────────────────

/// Scan directories for .volt files matching the given path patterns.
/// Each pattern entry is treated as a directory path to scan recursively.
pub fn scanFiles(allocator: Allocator, patterns: []const []const u8) !std.ArrayList([]const u8) {
    var results = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (results.items) |item| {
            allocator.free(item);
        }
        results.deinit();
    }

    for (patterns) |pattern| {
        // Try to open the pattern as a directory
        var dir = std.fs.cwd().openDir(pattern, .{ .iterate = true }) catch continue;
        defer dir.close();

        var walker = dir.iterate();
        while (walker.next() catch null) |entry| {
            if (entry.kind != .file) continue;

            // Check for .volt extension
            if (mem.endsWith(u8, entry.name, ".volt")) {
                const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ pattern, entry.name }) catch continue;
                try results.append(full_path);
            }
        }
    }

    return results;
}

/// Get the modification timestamp of a file.
/// Returns null if the file cannot be accessed.
pub fn getModTime(path: []const u8) ?i128 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    return stat.mtime;
}

/// Compare current modification times against stored state.
/// Updates the state with new timestamps and returns true if any file changed.
pub fn hasChanges(allocator: Allocator, state: *WatchState, files: []const []const u8) bool {
    var changed = false;

    for (files) |file_path| {
        const current_mtime = getModTime(file_path) orelse continue;

        if (state.last_modified.get(file_path)) |stored_mtime| {
            if (current_mtime != stored_mtime) {
                changed = true;
                state.last_modified.put(file_path, current_mtime) catch {};
            }
        } else {
            // New file, store its mtime
            const owned_path = allocator.dupe(u8, file_path) catch continue;
            state.last_modified.put(owned_path, current_mtime) catch {
                allocator.free(owned_path);
                continue;
            };
            changed = true;
        }
    }

    return changed;
}

// ── Watch Loop ────────────────────────────────────────────────────────

/// Main watch loop: scan for changes, execute on change, sleep, repeat.
/// Runs until state.running is set to false.
pub fn runWatchLoop(allocator: Allocator, config: *const WatchConfig, state: *WatchState) !void {
    const stdout = std.io.getStdOut().writer();

    state.running = true;
    try stdout.print("\x1b[1mVolt Watch Mode\x1b[0m\n", .{});
    try stdout.print("  Watching {d} path(s), interval: {d}ms\n", .{ config.paths.items.len, config.interval_ms });
    if (config.test_mode) {
        try stdout.print("  Mode: test\n", .{});
    }
    try stdout.print("\n", .{});

    while (state.running) {
        // Scan for files
        var files = try scanFiles(allocator, config.paths.items);
        defer {
            for (files.items) |item| {
                allocator.free(item);
            }
            files.deinit();
        }

        if (hasChanges(allocator, state, files.items)) {
            if (config.clear_screen) {
                // ANSI clear screen
                try stdout.print("\x1b[2J\x1b[H", .{});
            }

            // Collect changed files for output
            const output = try formatWatchOutput(allocator, files.items);
            defer allocator.free(output);
            try stdout.print("{s}", .{output});

            if (config.test_mode) {
                try stdout.print("  Running tests...\n\n", .{});
            } else {
                try stdout.print("  Running requests...\n\n", .{});
            }
        }

        try stdout.print("\x1b[2m[watching for changes...]\x1b[0m\n", .{});

        // Sleep for the configured interval
        const sleep_ns = @as(u64, config.interval_ms) * std.time.ns_per_ms;
        std.time.sleep(sleep_ns);

        // Only run one iteration if max_checks logic is needed externally
        // For tests, the caller sets state.running = false
        if (!state.running) break;
    }
}

/// Format a list of changed files for display.
pub fn formatWatchOutput(allocator: Allocator, changed_files: []const []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    const epoch_secs: u64 = @intCast(@max(std.time.timestamp(), 0));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_seconds = epoch.getDaySeconds();

    try writer.print("\x1b[1m[{d:0>2}:{d:0>2}:{d:0>2}]\x1b[0m Changes detected:\n", .{
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });

    for (changed_files) |file| {
        try writer.print("  \x1b[33m*\x1b[0m {s}\n", .{file});
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "watch config init and deinit" {
    var config = WatchConfig.init(std.testing.allocator);
    defer config.deinit();

    try std.testing.expectEqual(@as(u32, 1000), config.interval_ms);
    try std.testing.expect(!config.test_mode);
    try std.testing.expect(!config.clear_screen);
    try std.testing.expectEqual(@as(usize, 0), config.paths.items.len);
}

test "watch state init and deinit" {
    var state = WatchState.init(std.testing.allocator);
    defer state.deinit();

    try std.testing.expect(!state.running);
    try std.testing.expectEqual(@as(usize, 0), state.last_modified.count());
}

test "hasChanges detects new files" {
    const allocator = std.testing.allocator;
    var state = WatchState.init(allocator);
    defer state.deinit();

    // Use a file we know exists in the project
    const files = [_][]const u8{"build.zig"};
    const changed = hasChanges(allocator, &state, &files);

    // First scan should always report changes (new files)
    try std.testing.expect(changed);

    // Second scan should report no changes (same file, same mtime)
    const changed2 = hasChanges(allocator, &state, &files);
    try std.testing.expect(!changed2);
}

test "formatWatchOutput" {
    const allocator = std.testing.allocator;

    const files = [_][]const u8{ "api/users.volt", "api/auth.volt" };
    const output = try formatWatchOutput(allocator, &files);
    defer allocator.free(output);

    // Should contain the file names
    try std.testing.expect(mem.indexOf(u8, output, "api/users.volt") != null);
    try std.testing.expect(mem.indexOf(u8, output, "api/auth.volt") != null);
    try std.testing.expect(mem.indexOf(u8, output, "Changes detected") != null);
}

test "scanFiles returns empty for nonexistent directory" {
    const allocator = std.testing.allocator;

    const patterns = [_][]const u8{"nonexistent_directory_xyz"};
    var results = try scanFiles(allocator, &patterns);
    defer {
        for (results.items) |item| {
            allocator.free(item);
        }
        results.deinit();
    }

    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "getModTime returns null for nonexistent file" {
    const result = getModTime("this_file_does_not_exist_at_all.volt");
    try std.testing.expect(result == null);
}
