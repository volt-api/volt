const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Collection Organizer ──────────────────────────────────────────────
//
// Search, filter, and organize .volt file collections.
// Provides tree views, tag filtering, sorting, and collection statistics.

// ── Data Types ────────────────────────────────────────────────────────

pub const SearchEntry = struct {
    file_path: []const u8,
    name: ?[]const u8 = null,
    method: []const u8 = "GET",
    url: []const u8 = "",
    tags: []const []const u8 = &.{},
    description: ?[]const u8 = null,
};

pub const SearchResult = struct {
    file_path: []const u8,
    name: ?[]const u8,
    method: []const u8,
    url: []const u8,
    tags: []const []const u8,
    score: u32,
};

pub const TreeNode = struct {
    name: []const u8,
    is_directory: bool,
    children: std.ArrayList(TreeNode),
    file_path: ?[]const u8,
    depth: usize,

    pub fn init(allocator: Allocator, name: []const u8, is_dir: bool, depth: usize) TreeNode {
        return .{
            .name = name,
            .is_directory = is_dir,
            .children = std.ArrayList(TreeNode).init(allocator),
            .file_path = null,
            .depth = depth,
        };
    }

    pub fn deinit(self: *TreeNode) void {
        for (self.children.items) |*child| child.deinit();
        self.children.deinit();
    }
};

pub const CollectionStats = struct {
    total_files: usize,
    methods: struct {
        get: usize,
        post: usize,
        put: usize,
        patch: usize,
        delete: usize,
        other: usize,
    },
    tags: std.StringHashMap(usize),

    pub fn init(allocator: Allocator) CollectionStats {
        return .{
            .total_files = 0,
            .methods = .{
                .get = 0,
                .post = 0,
                .put = 0,
                .patch = 0,
                .delete = 0,
                .other = 0,
            },
            .tags = std.StringHashMap(usize).init(allocator),
        };
    }

    pub fn deinit(self: *CollectionStats) void {
        self.tags.deinit();
    }
};

pub const SortOrder = enum {
    name_asc,
    name_desc,
    method,
    url,

    pub fn toString(self: SortOrder) []const u8 {
        return switch (self) {
            .name_asc => "name_asc",
            .name_desc => "name_desc",
            .method => "method",
            .url => "url",
        };
    }
};

// ── Search ────────────────────────────────────────────────────────────

/// Check if `haystack` contains `needle` in a case-insensitive manner.
fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const end = haystack.len - needle.len + 1;
    var i: usize = 0;
    while (i < end) : (i += 1) {
        var matched = true;
        for (0..needle.len) |j| {
            if (toLowerByte(haystack[i + j]) != toLowerByte(needle[j])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn toLowerByte(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

/// Search across pre-loaded entries, matching against file name, request name,
/// URL, tags, and description with weighted scoring.
/// Returns results sorted by score (highest first).
pub fn searchRequests(allocator: Allocator, entries: []const SearchEntry, query: []const u8) !std.ArrayList(SearchResult) {
    var results = std.ArrayList(SearchResult).init(allocator);

    for (entries) |entry| {
        var score: u32 = 0;

        // File name match (weight 3)
        const basename = extractBasename(entry.file_path);
        if (containsInsensitive(basename, query)) {
            score += 3;
        }

        // Request name match (weight 3)
        if (entry.name) |name| {
            if (containsInsensitive(name, query)) {
                score += 3;
            }
        }

        // URL match (weight 2)
        if (containsInsensitive(entry.url, query)) {
            score += 2;
        }

        // Tags exact match (weight 4)
        for (entry.tags) |tag| {
            if (eqlInsensitive(tag, query)) {
                score += 4;
                break;
            }
        }

        // Description match (weight 1)
        if (entry.description) |desc| {
            if (containsInsensitive(desc, query)) {
                score += 1;
            }
        }

        if (score > 0) {
            try results.append(.{
                .file_path = entry.file_path,
                .name = entry.name,
                .method = entry.method,
                .url = entry.url,
                .tags = entry.tags,
                .score = score,
            });
        }
    }

    // Sort by score descending
    mem.sort(SearchResult, results.items, {}, struct {
        fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
            return a.score > b.score;
        }
    }.lessThan);

    return results;
}

fn extractBasename(path: []const u8) []const u8 {
    // Handle both forward and back slashes
    var last: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or c == '\\') last = i + 1;
    }
    return path[last..];
}

fn eqlInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (toLowerByte(ac) != toLowerByte(bc)) return false;
    }
    return true;
}

// ── Tree Building ─────────────────────────────────────────────────────

/// Build a tree from a flat list of file paths.
/// Paths should use '/' as separator (e.g., "api/users/list.volt").
pub fn buildTree(allocator: Allocator, paths: []const []const u8) !TreeNode {
    var root = TreeNode.init(allocator, ".", true, 0);

    for (paths) |path| {
        var current = &root;
        var depth: usize = 1;

        // Split path into segments
        var seg_iter = mem.splitScalar(u8, path, '/');
        // Collect all segments first to know which is last
        var segments = std.ArrayList([]const u8).init(allocator);
        defer segments.deinit();
        while (seg_iter.next()) |seg| {
            if (seg.len > 0) try segments.append(seg);
        }

        for (segments.items, 0..) |seg, idx| {
            const is_last = idx == segments.items.len - 1;
            const is_dir = !is_last;

            // Check if child already exists
            var found: ?*TreeNode = null;
            for (current.children.items) |*child| {
                if (mem.eql(u8, child.name, seg)) {
                    found = child;
                    break;
                }
            }

            if (found) |child| {
                current = child;
            } else {
                var new_node = TreeNode.init(allocator, seg, is_dir, depth);
                if (is_last) {
                    new_node.file_path = path;
                }
                try current.children.append(new_node);
                current = &current.children.items[current.children.items.len - 1];
            }
            depth += 1;
        }
    }

    // Sort children alphabetically at each level (directories first, then files)
    sortTreeChildren(&root);

    return root;
}

fn sortTreeChildren(node: *TreeNode) void {
    mem.sort(TreeNode, node.children.items, {}, struct {
        fn lessThan(_: void, a: TreeNode, b: TreeNode) bool {
            // Directories before files
            if (a.is_directory and !b.is_directory) return true;
            if (!a.is_directory and b.is_directory) return false;
            // Then alphabetical
            return mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    for (node.children.items) |*child| {
        sortTreeChildren(child);
    }
}

// ── Tree Rendering ────────────────────────────────────────────────────

/// Render a tree with box-drawing characters for terminal display.
pub fn renderTree(allocator: Allocator, root: *const TreeNode) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    // Render root name if it's a meaningful directory
    if (!mem.eql(u8, root.name, ".")) {
        try writer.print("{s}/\n", .{root.name});
    }

    for (root.children.items, 0..) |*child, idx| {
        const is_last = idx == root.children.items.len - 1;
        try renderNode(writer, child, "", is_last);
    }

    return buf.toOwnedSlice();
}

fn renderNode(writer: anytype, node: *const TreeNode, prefix: []const u8, is_last: bool) !void {
    // Choose the connector
    const connector: []const u8 = if (is_last) "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80 " else "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80 ";

    try writer.writeAll(prefix);
    try writer.writeAll(connector);
    try writer.writeAll(node.name);
    if (node.is_directory) try writer.writeAll("/");
    try writer.writeAll("\n");

    // Build child prefix
    const extension: []const u8 = if (is_last) "    " else "\xe2\x94\x82   ";
    var child_prefix = std.ArrayList(u8).init(std.heap.page_allocator);
    defer child_prefix.deinit();
    try child_prefix.appendSlice(prefix);
    try child_prefix.appendSlice(extension);

    for (node.children.items, 0..) |*child, idx| {
        const child_is_last = idx == node.children.items.len - 1;
        try renderNode(writer, child, child_prefix.items, child_is_last);
    }
}

// ── Tag Filtering ─────────────────────────────────────────────────────

/// Returns indices of entries that have the given tag (case-insensitive).
pub fn filterByTag(allocator: Allocator, entries: []const SearchEntry, tag: []const u8) !std.ArrayList(usize) {
    var indices = std.ArrayList(usize).init(allocator);

    for (entries, 0..) |entry, i| {
        for (entry.tags) |entry_tag| {
            if (eqlInsensitive(entry_tag, tag)) {
                try indices.append(i);
                break;
            }
        }
    }

    return indices;
}

// ── Collection Statistics ─────────────────────────────────────────────

/// Collect statistics about a set of search entries.
pub fn collectStats(allocator: Allocator, entries: []const SearchEntry) !CollectionStats {
    var stats = CollectionStats.init(allocator);

    stats.total_files = entries.len;

    for (entries) |entry| {
        // Count methods
        if (eqlInsensitive(entry.method, "GET")) {
            stats.methods.get += 1;
        } else if (eqlInsensitive(entry.method, "POST")) {
            stats.methods.post += 1;
        } else if (eqlInsensitive(entry.method, "PUT")) {
            stats.methods.put += 1;
        } else if (eqlInsensitive(entry.method, "PATCH")) {
            stats.methods.patch += 1;
        } else if (eqlInsensitive(entry.method, "DELETE")) {
            stats.methods.delete += 1;
        } else {
            stats.methods.other += 1;
        }

        // Count tags
        for (entry.tags) |tag| {
            const result = try stats.tags.getOrPut(tag);
            if (result.found_existing) {
                result.value_ptr.* += 1;
            } else {
                result.value_ptr.* = 1;
            }
        }
    }

    return stats;
}

// ── Sorting ───────────────────────────────────────────────────────────

/// Sort entries in-place by the given order.
pub fn sortEntries(entries: []SearchEntry, order: SortOrder) void {
    switch (order) {
        .name_asc => mem.sort(SearchEntry, entries, {}, struct {
            fn lessThan(_: void, a: SearchEntry, b: SearchEntry) bool {
                const a_name = a.name orelse a.file_path;
                const b_name = b.name orelse b.file_path;
                return mem.lessThan(u8, a_name, b_name);
            }
        }.lessThan),
        .name_desc => mem.sort(SearchEntry, entries, {}, struct {
            fn lessThan(_: void, a: SearchEntry, b: SearchEntry) bool {
                const a_name = a.name orelse a.file_path;
                const b_name = b.name orelse b.file_path;
                return mem.lessThan(u8, b_name, a_name);
            }
        }.lessThan),
        .method => mem.sort(SearchEntry, entries, {}, struct {
            fn lessThan(_: void, a: SearchEntry, b: SearchEntry) bool {
                return mem.lessThan(u8, a.method, b.method);
            }
        }.lessThan),
        .url => mem.sort(SearchEntry, entries, {}, struct {
            fn lessThan(_: void, a: SearchEntry, b: SearchEntry) bool {
                return mem.lessThan(u8, a.url, b.url);
            }
        }.lessThan),
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

test "search with name match" {
    const entries = [_]SearchEntry{
        .{ .file_path = "api/users.volt", .name = "List Users", .method = "GET", .url = "https://api.example.com/users" },
        .{ .file_path = "api/health.volt", .name = "Health Check", .method = "GET", .url = "https://api.example.com/health" },
    };
    var results = try searchRequests(std.testing.allocator, &entries, "Users");
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("api/users.volt", results.items[0].file_path);
}

test "search with URL match" {
    const entries = [_]SearchEntry{
        .{ .file_path = "api/users.volt", .name = "List Users", .method = "GET", .url = "https://api.example.com/users" },
        .{ .file_path = "api/health.volt", .name = "Health Check", .method = "GET", .url = "https://api.example.com/health" },
    };
    var results = try searchRequests(std.testing.allocator, &entries, "health");
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("api/health.volt", results.items[0].file_path);
}

test "search with tag match has highest priority" {
    const secure_tags = [_][]const u8{"secure"};
    const entries = [_]SearchEntry{
        .{ .file_path = "api/login.volt", .name = "Login", .method = "POST", .url = "https://api.example.com/login", .tags = &secure_tags },
        .{ .file_path = "api/signup.volt", .name = "Signup", .method = "POST", .url = "https://api.example.com/signup" },
    };
    // Search for "secure" — only login.volt has the tag, signup.volt has no match at all
    var results = try searchRequests(std.testing.allocator, &entries, "secure");
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("api/login.volt", results.items[0].file_path);
    try std.testing.expect(results.items[0].score >= 4); // tag weight is 4
}

test "search returns results sorted by score" {
    const v2_tags = [_][]const u8{"v2"};
    const entries = [_]SearchEntry{
        .{ .file_path = "api/other.volt", .name = "Other", .method = "GET", .url = "https://api.example.com/other", .description = "v2 endpoint" },
        .{ .file_path = "api/v2.volt", .name = "V2 Main", .method = "GET", .url = "https://api.example.com/v2", .tags = &v2_tags },
    };
    var results = try searchRequests(std.testing.allocator, &entries, "v2");
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    // v2.volt matches on file name (3) + name (3) + URL (2) + tag (4) = 12
    // other.volt matches on description (1) only
    try std.testing.expect(results.items[0].score >= results.items[1].score);
    try std.testing.expectEqualStrings("api/v2.volt", results.items[0].file_path);
}

test "search case-insensitive" {
    const entries = [_]SearchEntry{
        .{ .file_path = "api/Users.volt", .name = "LIST USERS", .method = "GET", .url = "https://api.example.com/users" },
    };
    var results = try searchRequests(std.testing.allocator, &entries, "users");
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 1), results.items.len);
}

test "search no results" {
    const entries = [_]SearchEntry{
        .{ .file_path = "api/users.volt", .name = "List Users", .method = "GET", .url = "https://api.example.com/users" },
    };
    var results = try searchRequests(std.testing.allocator, &entries, "nonexistent");
    defer results.deinit();

    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "tree building from flat paths" {
    const paths = [_][]const u8{
        "api/users/list.volt",
        "api/users/create.volt",
        "api/health.volt",
    };
    var tree = try buildTree(std.testing.allocator, &paths);
    defer tree.deinit();

    try std.testing.expectEqualStrings(".", tree.name);
    try std.testing.expect(tree.is_directory);
    // Should have one child: "api/"
    try std.testing.expectEqual(@as(usize, 1), tree.children.items.len);
    try std.testing.expectEqualStrings("api", tree.children.items[0].name);
    try std.testing.expect(tree.children.items[0].is_directory);

    // "api/" should have two children: "users/" dir and "health.volt" file
    // Sorted: directories first, then files; both alphabetical
    const api = &tree.children.items[0];
    try std.testing.expectEqual(@as(usize, 2), api.children.items.len);
    try std.testing.expectEqualStrings("users", api.children.items[0].name);
    try std.testing.expect(api.children.items[0].is_directory);
    try std.testing.expectEqualStrings("health.volt", api.children.items[1].name);
    try std.testing.expect(!api.children.items[1].is_directory);
}

test "tree rendering with box characters" {
    const paths = [_][]const u8{
        "api/health.volt",
        "api/users/create.volt",
        "api/users/list.volt",
    };
    var tree = try buildTree(std.testing.allocator, &paths);
    defer tree.deinit();

    const rendered = try renderTree(std.testing.allocator, &tree);
    defer std.testing.allocator.free(rendered);

    // Should contain box-drawing characters and proper structure
    try std.testing.expect(mem.indexOf(u8, rendered, "api/") != null);
    try std.testing.expect(mem.indexOf(u8, rendered, "health.volt") != null);
    try std.testing.expect(mem.indexOf(u8, rendered, "users/") != null);
    try std.testing.expect(mem.indexOf(u8, rendered, "create.volt") != null);
    try std.testing.expect(mem.indexOf(u8, rendered, "list.volt") != null);
    // Check for box-drawing chars (UTF-8)
    try std.testing.expect(mem.indexOf(u8, rendered, "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80") != null or
        mem.indexOf(u8, rendered, "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80") != null);
}

test "tag filtering" {
    const auth_tags = [_][]const u8{ "auth", "v2" };
    const user_tags = [_][]const u8{"users"};
    const entries = [_]SearchEntry{
        .{ .file_path = "api/login.volt", .tags = &auth_tags },
        .{ .file_path = "api/users.volt", .tags = &user_tags },
        .{ .file_path = "api/health.volt" },
        .{ .file_path = "api/signup.volt", .tags = &auth_tags },
    };
    var indices = try filterByTag(std.testing.allocator, &entries, "auth");
    defer indices.deinit();

    try std.testing.expectEqual(@as(usize, 2), indices.items.len);
    try std.testing.expectEqual(@as(usize, 0), indices.items[0]);
    try std.testing.expectEqual(@as(usize, 3), indices.items[1]);
}

test "collection stats method counts" {
    const entries = [_]SearchEntry{
        .{ .file_path = "a.volt", .method = "GET" },
        .{ .file_path = "b.volt", .method = "POST" },
        .{ .file_path = "c.volt", .method = "GET" },
        .{ .file_path = "d.volt", .method = "DELETE" },
        .{ .file_path = "e.volt", .method = "PUT" },
        .{ .file_path = "f.volt", .method = "PATCH" },
    };
    var stats = try collectStats(std.testing.allocator, &entries);
    defer stats.deinit();

    try std.testing.expectEqual(@as(usize, 6), stats.total_files);
    try std.testing.expectEqual(@as(usize, 2), stats.methods.get);
    try std.testing.expectEqual(@as(usize, 1), stats.methods.post);
    try std.testing.expectEqual(@as(usize, 1), stats.methods.put);
    try std.testing.expectEqual(@as(usize, 1), stats.methods.patch);
    try std.testing.expectEqual(@as(usize, 1), stats.methods.delete);
    try std.testing.expectEqual(@as(usize, 0), stats.methods.other);
}

test "collection stats tag counts" {
    const auth_tags = [_][]const u8{ "auth", "v2" };
    const user_tags = [_][]const u8{ "users", "v2" };
    const entries = [_]SearchEntry{
        .{ .file_path = "a.volt", .tags = &auth_tags },
        .{ .file_path = "b.volt", .tags = &user_tags },
        .{ .file_path = "c.volt" },
    };
    var stats = try collectStats(std.testing.allocator, &entries);
    defer stats.deinit();

    try std.testing.expectEqual(@as(usize, 1), stats.tags.get("auth").?);
    try std.testing.expectEqual(@as(usize, 2), stats.tags.get("v2").?);
    try std.testing.expectEqual(@as(usize, 1), stats.tags.get("users").?);
}

test "sort by name ascending" {
    var entries = [_]SearchEntry{
        .{ .file_path = "c.volt", .name = "Zebra" },
        .{ .file_path = "a.volt", .name = "Alpha" },
        .{ .file_path = "b.volt", .name = "Middle" },
    };
    sortEntries(&entries, .name_asc);

    try std.testing.expectEqualStrings("Alpha", entries[0].name.?);
    try std.testing.expectEqualStrings("Middle", entries[1].name.?);
    try std.testing.expectEqualStrings("Zebra", entries[2].name.?);
}

test "sort by method" {
    var entries = [_]SearchEntry{
        .{ .file_path = "a.volt", .method = "POST" },
        .{ .file_path = "b.volt", .method = "DELETE" },
        .{ .file_path = "c.volt", .method = "GET" },
    };
    sortEntries(&entries, .method);

    try std.testing.expectEqualStrings("DELETE", entries[0].method);
    try std.testing.expectEqualStrings("GET", entries[1].method);
    try std.testing.expectEqualStrings("POST", entries[2].method);
}

test "sort order toString" {
    try std.testing.expectEqualStrings("name_asc", SortOrder.name_asc.toString());
    try std.testing.expectEqualStrings("name_desc", SortOrder.name_desc.toString());
    try std.testing.expectEqualStrings("method", SortOrder.method.toString());
    try std.testing.expectEqualStrings("url", SortOrder.url.toString());
}

test "tag filtering case-insensitive" {
    const auth_tags = [_][]const u8{"Auth"};
    const entries = [_]SearchEntry{
        .{ .file_path = "a.volt", .tags = &auth_tags },
        .{ .file_path = "b.volt" },
    };
    var indices = try filterByTag(std.testing.allocator, &entries, "auth");
    defer indices.deinit();

    try std.testing.expectEqual(@as(usize, 1), indices.items.len);
    try std.testing.expectEqual(@as(usize, 0), indices.items[0]);
}
