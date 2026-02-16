const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Multipart Form Data Builder ────────────────────────────────────────
// Generates RFC 2046 multipart/form-data bodies for file uploads
// and form submissions.

pub const Part = struct {
    name: []const u8,
    filename: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    data: []const u8,
};

pub const MultipartBuilder = struct {
    parts: std.ArrayList(Part),
    boundary: [36]u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) MultipartBuilder {
        // Generate a boundary using a simple timestamp-based approach.
        // Format: "----VoltBoundary" + hex digits from timestamp.
        var boundary: [36]u8 = undefined;
        const prefix = "----VoltBoundary";
        @memcpy(boundary[0..prefix.len], prefix);

        const ts: u64 = @intCast(std.time.milliTimestamp());
        const hex_chars = "0123456789abcdef";
        var remaining = ts;
        var idx: usize = prefix.len;
        while (idx < 36) : (idx += 1) {
            boundary[idx] = hex_chars[@as(usize, @intCast(remaining & 0xF))];
            remaining >>= 4;
        }

        return .{
            .parts = std.ArrayList(Part).init(allocator),
            .boundary = boundary,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MultipartBuilder) void {
        self.parts.deinit();
    }

    /// Add a text field
    pub fn addField(self: *MultipartBuilder, name: []const u8, value: []const u8) !void {
        try self.parts.append(.{
            .name = name,
            .data = value,
        });
    }

    /// Add a file part with content provided directly
    pub fn addFile(self: *MultipartBuilder, name: []const u8, filename: []const u8, content: []const u8, content_type: ?[]const u8) !void {
        try self.parts.append(.{
            .name = name,
            .filename = filename,
            .content_type = content_type,
            .data = content,
        });
    }

    /// Add a file from disk, detecting content type from extension
    pub fn addFileFromPath(self: *MultipartBuilder, name: []const u8, file_path: []const u8) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(self.allocator, 50 * 1024 * 1024);

        // Extract filename from path
        const filename = extractFilename(file_path);

        // Detect content type from extension
        const content_type = detectContentType(file_path);

        try self.parts.append(.{
            .name = name,
            .filename = filename,
            .content_type = content_type,
            .data = data,
        });
    }

    /// Build the complete multipart body
    pub fn build(self: *MultipartBuilder) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        const writer = buf.writer();

        for (self.parts.items) |part| {
            // Boundary line
            try writer.writeAll("--");
            try writer.writeAll(&self.boundary);
            try writer.writeAll("\r\n");

            // Content-Disposition header
            if (part.filename) |filename| {
                try writer.print("Content-Disposition: form-data; name=\"{s}\"; filename=\"{s}\"\r\n", .{ part.name, filename });
            } else {
                try writer.print("Content-Disposition: form-data; name=\"{s}\"\r\n", .{part.name});
            }

            // Content-Type header (only for file parts)
            if (part.content_type) |ct| {
                try writer.print("Content-Type: {s}\r\n", .{ct});
            } else if (part.filename != null) {
                try writer.writeAll("Content-Type: application/octet-stream\r\n");
            }

            // Blank line separating headers from body
            try writer.writeAll("\r\n");

            // Part data
            try writer.writeAll(part.data);
            try writer.writeAll("\r\n");
        }

        // Closing boundary
        try writer.writeAll("--");
        try writer.writeAll(&self.boundary);
        try writer.writeAll("--\r\n");

        return buf.toOwnedSlice();
    }

    /// Get the Content-Type header value including boundary (returns a slice into self.boundary)
    pub fn contentType(self: *const MultipartBuilder) []const u8 {
        _ = self;
        return "multipart/form-data";
    }

    /// Get the full Content-Type header value as an allocated string
    pub fn getContentTypeHeader(self: *const MultipartBuilder, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{&self.boundary});
    }
};

// ── Helpers ────────────────────────────────────────────────────────────

/// Extract filename from a file path (last component after / or \)
fn extractFilename(path: []const u8) []const u8 {
    // Search backward for path separator
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '/' or path[i] == '\\') {
            return path[i + 1 ..];
        }
    }
    return path;
}

/// Detect MIME content type from file extension
fn detectContentType(path: []const u8) ?[]const u8 {
    // Find extension
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i] == '.') {
            const ext = path[i..];
            if (mem.eql(u8, ext, ".txt")) return "text/plain";
            if (mem.eql(u8, ext, ".html") or mem.eql(u8, ext, ".htm")) return "text/html";
            if (mem.eql(u8, ext, ".css")) return "text/css";
            if (mem.eql(u8, ext, ".js")) return "application/javascript";
            if (mem.eql(u8, ext, ".json")) return "application/json";
            if (mem.eql(u8, ext, ".xml")) return "application/xml";
            if (mem.eql(u8, ext, ".pdf")) return "application/pdf";
            if (mem.eql(u8, ext, ".zip")) return "application/zip";
            if (mem.eql(u8, ext, ".gz") or mem.eql(u8, ext, ".gzip")) return "application/gzip";
            if (mem.eql(u8, ext, ".png")) return "image/png";
            if (mem.eql(u8, ext, ".jpg") or mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
            if (mem.eql(u8, ext, ".gif")) return "image/gif";
            if (mem.eql(u8, ext, ".svg")) return "image/svg+xml";
            if (mem.eql(u8, ext, ".webp")) return "image/webp";
            if (mem.eql(u8, ext, ".ico")) return "image/x-icon";
            if (mem.eql(u8, ext, ".mp3")) return "audio/mpeg";
            if (mem.eql(u8, ext, ".mp4")) return "video/mp4";
            if (mem.eql(u8, ext, ".csv")) return "text/csv";
            if (mem.eql(u8, ext, ".yaml") or mem.eql(u8, ext, ".yml")) return "text/yaml";
            return "application/octet-stream";
        }
        if (path[i] == '/' or path[i] == '\\') break;
    }
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "multipart build simple fields" {
    var builder = MultipartBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.addField("username", "john");
    try builder.addField("password", "secret");

    const body = try builder.build();
    defer std.testing.allocator.free(body);

    // Verify structure
    try std.testing.expect(mem.indexOf(u8, body, "Content-Disposition: form-data; name=\"username\"") != null);
    try std.testing.expect(mem.indexOf(u8, body, "john") != null);
    try std.testing.expect(mem.indexOf(u8, body, "Content-Disposition: form-data; name=\"password\"") != null);
    try std.testing.expect(mem.indexOf(u8, body, "secret") != null);
    // Verify closing boundary
    try std.testing.expect(mem.indexOf(u8, body, "--\r\n") != null);
}

test "multipart build with file" {
    var builder = MultipartBuilder.init(std.testing.allocator);
    defer builder.deinit();

    try builder.addField("description", "My upload");
    try builder.addFile("document", "test.txt", "Hello, World!", "text/plain");

    const body = try builder.build();
    defer std.testing.allocator.free(body);

    // Verify file part
    try std.testing.expect(mem.indexOf(u8, body, "filename=\"test.txt\"") != null);
    try std.testing.expect(mem.indexOf(u8, body, "Content-Type: text/plain") != null);
    try std.testing.expect(mem.indexOf(u8, body, "Hello, World!") != null);
    // Verify field part
    try std.testing.expect(mem.indexOf(u8, body, "name=\"description\"") != null);
    try std.testing.expect(mem.indexOf(u8, body, "My upload") != null);
}

test "multipart content type header" {
    var builder = MultipartBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const header = try builder.getContentTypeHeader(std.testing.allocator);
    defer std.testing.allocator.free(header);

    try std.testing.expect(mem.startsWith(u8, header, "multipart/form-data; boundary="));
    try std.testing.expect(header.len > "multipart/form-data; boundary=".len);
}

test "detect content type" {
    try std.testing.expectEqualStrings("image/png", detectContentType("photo.png").?);
    try std.testing.expectEqualStrings("application/json", detectContentType("/path/to/data.json").?);
    try std.testing.expectEqualStrings("text/plain", detectContentType("readme.txt").?);
    try std.testing.expect(detectContentType("noextension") == null);
}

test "extract filename" {
    try std.testing.expectEqualStrings("file.txt", extractFilename("/home/user/file.txt"));
    try std.testing.expectEqualStrings("photo.png", extractFilename("C:\\Users\\A\\photo.png"));
    try std.testing.expectEqualStrings("data.json", extractFilename("data.json"));
}
