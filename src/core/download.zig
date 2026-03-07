const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Download Mode ─────────────────────────────────────────────────────
// Downloads response body to a file with a terminal progress bar.
// Supports resume via Range header and auto-detection of filenames
// from Content-Disposition headers or URL path.

pub const DownloadConfig = struct {
    output_path: ?[]const u8 = null,
    show_progress: bool = true,
    continue_download: bool = false,
};

pub const DownloadProgress = struct {
    total_bytes: usize = 0,
    downloaded_bytes: usize = 0,
    speed_bps: f64 = 0,
    eta_seconds: f64 = 0,
    filename: []const u8 = "download",
};

/// Extract filename from Content-Disposition header.
/// Handles: attachment; filename="myfile.zip"
///          attachment; filename=myfile.zip
pub fn extractFilename(header_value: []const u8) ?[]const u8 {
    // Look for filename="..." or filename=...
    const patterns = [_][]const u8{ "filename=\"", "filename=" };
    for (patterns) |pattern| {
        if (mem.indexOf(u8, header_value, pattern)) |pos| {
            const start = pos + pattern.len;
            if (pattern[pattern.len - 1] == '"') {
                // Quoted: find closing quote
                if (mem.indexOf(u8, header_value[start..], "\"")) |end| {
                    return header_value[start .. start + end];
                }
            } else {
                // Unquoted: until ; or end
                const rest = header_value[start..];
                const end = mem.indexOf(u8, rest, ";") orelse rest.len;
                const trimmed = mem.trim(u8, rest[0..end], " \t\r\n\"");
                if (trimmed.len > 0) return trimmed;
            }
        }
    }
    return null;
}

/// Extract filename from URL path (last segment).
pub fn extractFilenameFromUrl(url: []const u8) []const u8 {
    // Strip query string
    const path_end = mem.indexOf(u8, url, "?") orelse url.len;
    const url_path = url[0..path_end];

    // Find last '/'
    var last_slash: usize = 0;
    for (url_path, 0..) |c, i| {
        if (c == '/') last_slash = i;
    }

    const name = url_path[last_slash + 1 ..];
    if (name.len == 0) return "download";
    return name;
}

/// Get the size of an existing file for resume support.
pub fn getExistingFileSize(path: []const u8) usize {
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.size;
}

/// Write response body to file, rendering a progress bar.
pub fn downloadToFile(
    body: []const u8,
    filename: []const u8,
    total_content_length: usize,
    resume_offset: usize,
    show_progress: bool,
) !void {
    const file = if (resume_offset > 0)
        try std.fs.cwd().openFile(filename, .{ .mode = .write_only })
    else
        try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    if (resume_offset > 0) {
        try file.seekTo(resume_offset);
    }

    const stderr = std.io.getStdErr().writer();
    const chunk_size: usize = 8192;
    var written: usize = 0;
    const start_time = std.time.nanoTimestamp();
    const total = if (total_content_length > 0) total_content_length else body.len;

    while (written < body.len) {
        const end = @min(written + chunk_size, body.len);
        try file.writeAll(body[written..end]);
        written = end - written + written;

        if (show_progress and total > 0) {
            const elapsed_ns = std.time.nanoTimestamp() - start_time;
            const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            const effective_written = resume_offset + written;
            const speed: f64 = if (elapsed_s > 0.01) @as(f64, @floatFromInt(written)) / elapsed_s else 0;
            const remaining = if (total > effective_written) total - effective_written else 0;
            const eta: f64 = if (speed > 0) @as(f64, @floatFromInt(remaining)) / speed else 0;

            var progress = DownloadProgress{
                .total_bytes = total,
                .downloaded_bytes = effective_written,
                .speed_bps = speed,
                .eta_seconds = eta,
                .filename = filename,
            };
            renderProgressBar(&progress, stderr) catch {}; // output only
        }

        written = end;
    }

    if (show_progress) {
        // Final progress line
        stderr.writeAll("\n") catch {};
    }
}

/// Render a terminal progress bar.
pub fn renderProgressBar(progress: *const DownloadProgress, writer: anytype) !void {
    const bar_width: usize = 20;
    const pct: f64 = if (progress.total_bytes > 0)
        @as(f64, @floatFromInt(progress.downloaded_bytes)) / @as(f64, @floatFromInt(progress.total_bytes)) * 100.0
    else
        0;
    const filled: usize = if (progress.total_bytes > 0)
        @intFromFloat(@as(f64, @floatFromInt(bar_width)) * pct / 100.0)
    else
        0;

    // Build bar
    var bar: [20]u8 = undefined;
    for (0..bar_width) |i| {
        bar[i] = if (i < filled) '#' else '-';
    }

    // Format speed
    const speed_display = formatSpeed(progress.speed_bps);
    const eta_display = formatEta(progress.eta_seconds);

    try writer.print("\r\x1b[2KDownloading {s}  [{s}]  {d:.0}%  {s}  {s}", .{
        truncateFilename(progress.filename),
        bar[0..bar_width],
        pct,
        speed_display,
        eta_display,
    });
}

fn formatSpeed(bps: f64) []const u8 {
    if (bps > 1024 * 1024 * 1024) return "> 1 GB/s";
    if (bps > 1024 * 1024) return "MB/s";
    if (bps > 1024) return "KB/s";
    return "B/s";
}

fn formatEta(seconds: f64) []const u8 {
    if (seconds <= 0 or seconds > 86400) return "";
    if (seconds < 60) return "ETA < 1m";
    return "ETA > 1m";
}

fn truncateFilename(name: []const u8) []const u8 {
    if (name.len <= 30) return name;
    return name[0..30];
}

// ── Tests ───────────────────────────────────────────────────────────────

test "extract filename from content-disposition" {
    try std.testing.expectEqualStrings(
        "report.pdf",
        extractFilename("attachment; filename=\"report.pdf\"").?,
    );
    try std.testing.expectEqualStrings(
        "data.csv",
        extractFilename("attachment; filename=data.csv").?,
    );
    try std.testing.expect(extractFilename("inline") == null);
}

test "extract filename from url" {
    try std.testing.expectEqualStrings("file.zip", extractFilenameFromUrl("https://example.com/files/file.zip"));
    try std.testing.expectEqualStrings("file.zip", extractFilenameFromUrl("https://example.com/files/file.zip?token=abc"));
    try std.testing.expectEqualStrings("download", extractFilenameFromUrl("https://example.com/"));
}

test "progress bar rendering" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    const progress = DownloadProgress{
        .total_bytes = 1000,
        .downloaded_bytes = 500,
        .speed_bps = 1024 * 100,
        .eta_seconds = 5,
        .filename = "test.zip",
    };
    try renderProgressBar(&progress, writer);
    const output = fbs.getWritten();
    try std.testing.expect(output.len > 0);
    try std.testing.expect(mem.indexOf(u8, output, "test.zip") != null);
}

test "format speed" {
    try std.testing.expectEqualStrings("B/s", formatSpeed(500));
    try std.testing.expectEqualStrings("KB/s", formatSpeed(2048));
    try std.testing.expectEqualStrings("MB/s", formatSpeed(2 * 1024 * 1024));
}

test "truncate filename" {
    try std.testing.expectEqualStrings("short.txt", truncateFilename("short.txt"));
    const long_name = "a_very_long_filename_that_exceeds_thirty_characters.txt";
    try std.testing.expectEqual(@as(usize, 30), truncateFilename(long_name).len);
}
