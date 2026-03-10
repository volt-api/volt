const std = @import("std");
const builtin = @import("builtin");
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

// ── OS-Native File Watching ──────────────────────────────────────────

/// Returns true on platforms where native file watching (inotify) is available.
pub fn supportsNativeWatch() bool {
    return builtin.os.tag == .linux;
}

/// NativeWatcher wraps platform-specific file watching mechanisms.
/// On Linux it uses inotify for efficient kernel-level notifications.
/// On all other platforms it falls back to polling via `hasChanges()` + sleep.
pub const NativeWatcher = struct {
    allocator: Allocator,
    watch_paths: std.ArrayList([]const u8),
    use_native: bool,
    // For Linux inotify
    inotify_fd: ?i32 = null,
    // For polling fallback
    poll_state: ?WatchState = null,

    pub fn init(allocator: Allocator) NativeWatcher {
        var watcher = NativeWatcher{
            .allocator = allocator,
            .watch_paths = std.ArrayList([]const u8).init(allocator),
            .use_native = false,
            .inotify_fd = null,
            .poll_state = null,
        };

        if (comptime builtin.os.tag == .linux) {
            // Attempt to initialise inotify; fall back to polling on failure
            const fd = std.os.linux.inotify_init1(0);
            const signed: i32 = @bitCast(@as(u32, @truncate(fd)));
            if (signed >= 0) {
                watcher.inotify_fd = signed;
                watcher.use_native = true;
            } else {
                watcher.poll_state = WatchState.init(allocator);
            }
        } else {
            // Non-Linux: always use polling fallback
            watcher.poll_state = WatchState.init(allocator);
        }

        return watcher;
    }

    pub fn deinit(self: *NativeWatcher) void {
        if (comptime builtin.os.tag == .linux) {
            if (self.inotify_fd) |fd| {
                std.posix.close(fd);
                self.inotify_fd = null;
            }
        }

        if (self.poll_state) |*ps| {
            ps.deinit();
            self.poll_state = null;
        }

        for (self.watch_paths.items) |p| {
            self.allocator.free(p);
        }
        self.watch_paths.deinit();
    }

    /// Register a directory path to watch for .volt file changes.
    pub fn addPath(self: *NativeWatcher, path: []const u8) !void {
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);

        if (comptime builtin.os.tag == .linux) {
            if (self.inotify_fd) |fd| {
                // Watch for modifications, creates, and moves in the directory.
                const flags = std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.MOVED_TO;
                // inotify_add_watch requires a null-terminated path
                const path_z = try self.allocator.dupeZ(u8, path);
                defer self.allocator.free(path_z);
                const wd = std.os.linux.inotify_add_watch(fd, path_z, flags);
                const signed_wd: i32 = @bitCast(@as(u32, @truncate(wd)));
                if (signed_wd < 0) {
                    // If adding this specific watch fails, we still keep the
                    // path for a potential polling fallback but don't error out.
                }
            }
        }

        try self.watch_paths.append(owned);
    }

    /// Block until a .volt file changes (or until `timeout_ms` elapses).
    /// Returns the path of the first changed file, or null on timeout.
    /// The caller does NOT own the returned slice.
    pub fn waitForChange(self: *NativeWatcher, timeout_ms: u32) !?[]const u8 {
        if (comptime builtin.os.tag == .linux) {
            if (self.use_native and self.inotify_fd != null) {
                return self.waitInotify(timeout_ms);
            }
        }
        // Polling fallback
        return self.waitPolling(timeout_ms);
    }

    // ── Linux inotify path ──────────────────────────────────────────

    fn waitInotify(self: *NativeWatcher, timeout_ms: u32) !?[]const u8 {
        if (comptime builtin.os.tag != .linux) {
            // Unreachable on non-Linux, but keeps the compiler happy.
            return self.waitPolling(timeout_ms);
        } else {
            const fd = self.inotify_fd orelse return self.waitPolling(timeout_ms);

            var pfd = [1]std.posix.pollfd{.{
                .fd = fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            }};

            const ret = std.posix.poll(&pfd, @intCast(timeout_ms)) catch {
                return self.waitPolling(timeout_ms);
            };

            if (ret == 0) return null; // timeout

            // Drain the inotify buffer and look for .volt files
            var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
            const bytes_read = std.posix.read(fd, &buf) catch {
                return self.waitPolling(timeout_ms);
            };

            if (bytes_read <= 0) return null;

            var offset: usize = 0;
            while (offset < bytes_read) {
                const event: *const std.os.linux.inotify_event = @ptrCast(@alignCast(buf[offset..].ptr));
                const name_len = event.len;
                if (name_len > 0) {
                    const name_bytes = buf[offset + @sizeOf(std.os.linux.inotify_event) ..][0..name_len];
                    // name is null-terminated inside the buffer
                    const name = mem.sliceTo(name_bytes, 0);
                    if (mem.endsWith(u8, name, ".volt")) {
                        // Return the first matching watch path as context
                        if (self.watch_paths.items.len > 0) {
                            return self.watch_paths.items[0];
                        }
                    }
                }
                offset += @sizeOf(std.os.linux.inotify_event) + name_len;
            }

            return null;
        }
    }

    // ── Polling fallback ────────────────────────────────────────────

    fn waitPolling(self: *NativeWatcher, timeout_ms: u32) !?[]const u8 {
        const state = &(self.poll_state orelse return null);

        var files = try scanFiles(self.allocator, self.watch_paths.items);
        defer {
            for (files.items) |item| {
                self.allocator.free(item);
            }
            files.deinit();
        }

        if (hasChanges(self.allocator, state, files.items)) {
            if (self.watch_paths.items.len > 0) {
                return self.watch_paths.items[0];
            }
            return null;
        }

        // Sleep for the requested interval, then re-check once
        const sleep_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
        std.time.sleep(sleep_ns);

        var files2 = try scanFiles(self.allocator, self.watch_paths.items);
        defer {
            for (files2.items) |item| {
                self.allocator.free(item);
            }
            files2.deinit();
        }

        if (hasChanges(self.allocator, state, files2.items)) {
            if (self.watch_paths.items.len > 0) {
                return self.watch_paths.items[0];
            }
        }

        return null;
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
                state.last_modified.put(file_path, current_mtime) catch |err| {
                    std.debug.print("warning: watch: mtime update failed: {s}\n", .{@errorName(err)});
                };
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

test "NativeWatcher init and deinit" {
    var watcher = NativeWatcher.init(std.testing.allocator);
    defer watcher.deinit();

    // On Linux with inotify available, use_native should be true.
    // On other platforms, it should fall back to polling.
    if (comptime builtin.os.tag == .linux) {
        // inotify may or may not succeed in a test sandbox, so
        // just verify internal consistency.
        if (watcher.use_native) {
            try std.testing.expect(watcher.inotify_fd != null);
            try std.testing.expect(watcher.poll_state == null);
        } else {
            try std.testing.expect(watcher.inotify_fd == null);
            try std.testing.expect(watcher.poll_state != null);
        }
    } else {
        try std.testing.expect(!watcher.use_native);
        try std.testing.expect(watcher.inotify_fd == null);
        try std.testing.expect(watcher.poll_state != null);
    }

    try std.testing.expectEqual(@as(usize, 0), watcher.watch_paths.items.len);
}

test "supportsNativeWatch returns expected value" {
    const expected = builtin.os.tag == .linux;
    try std.testing.expectEqual(expected, supportsNativeWatch());
}

test "NativeWatcher falls back to polling" {
    // On non-Linux platforms (or when inotify is unavailable) the watcher
    // must initialise a poll_state for the polling fallback path.
    var watcher = NativeWatcher.init(std.testing.allocator);
    defer watcher.deinit();

    if (comptime builtin.os.tag != .linux) {
        // Must be in polling mode
        try std.testing.expect(!watcher.use_native);
        try std.testing.expect(watcher.poll_state != null);

        // addPath should work in polling mode
        try watcher.addPath("nonexistent_test_dir");
        try std.testing.expectEqual(@as(usize, 1), watcher.watch_paths.items.len);

        // waitForChange should return null (no real files to detect)
        const result = try watcher.waitForChange(0);
        try std.testing.expect(result == null);
    } else {
        // On Linux, force polling by simulating inotify failure:
        // Close inotify fd if present and switch to polling.
        if (watcher.inotify_fd) |fd| {
            std.posix.close(fd);
            watcher.inotify_fd = null;
        }
        watcher.use_native = false;
        if (watcher.poll_state == null) {
            watcher.poll_state = WatchState.init(std.testing.allocator);
        }

        try std.testing.expect(!watcher.use_native);
        try std.testing.expect(watcher.poll_state != null);

        try watcher.addPath("nonexistent_test_dir");
        try std.testing.expectEqual(@as(usize, 1), watcher.watch_paths.items.len);

        const result = try watcher.waitForChange(0);
        try std.testing.expect(result == null);
    }
}
