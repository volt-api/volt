const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const volt_core = @import("volt-core");
const CollectionOrganizer = volt_core.CollectionOrganizer;
const VoltFile = volt_core.VoltFile;

// ── Search, Tree, Stats, and Sorting Tests ──────────────────────────────
//
// Validates the CollectionOrganizer module using realistic data models
// that mirror the fixtures in the launch-schedule test directory.
// Tests cover: weighted search scoring, tree building and rendering,
// collection statistics, tag filtering, and multi-field sorting.

// ── Weighted Search Scoring ─────────────────────────────────────────────

test "search matches file name with weight 3" {
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "fixtures/graphql/query-users.volt", .name = "GraphQL Query Users", .method = "POST", .url = "http://127.0.0.1:9090/graphql" },
        .{ .file_path = "fixtures/websocket/echo.volt", .name = "WebSocket Echo", .method = "GET", .url = "ws://127.0.0.1:9090/ws/echo" },
    };

    var results = try CollectionOrganizer.searchRequests(testing.allocator, &entries, "query-users");
    defer results.deinit();

    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("fixtures/graphql/query-users.volt", results.items[0].file_path);
    try testing.expect(results.items[0].score >= 3);
}

test "search matches request name with weight 3" {
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "fixtures/sse/events.volt", .name = "SSE Event Stream", .method = "GET", .url = "http://127.0.0.1:9090/sse/events" },
        .{ .file_path = "fixtures/mqtt/connect.volt", .name = "MQTT Connect", .method = "GET", .url = "mqtt://broker.test.local:1883/telemetry/sensors" },
    };

    var results = try CollectionOrganizer.searchRequests(testing.allocator, &entries, "Event");
    defer results.deinit();

    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("fixtures/sse/events.volt", results.items[0].file_path);
}

test "search matches URL with weight 2" {
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "fixtures/oauth/token-exchange.volt", .name = "OAuth Token Exchange", .method = "POST", .url = "http://127.0.0.1:9090/oauth/token" },
        .{ .file_path = "fixtures/proxy/capture.volt", .name = "Proxy Capture", .method = "GET", .url = "http://127.0.0.1:9090/proxy-target" },
    };

    var results = try CollectionOrganizer.searchRequests(testing.allocator, &entries, "proxy-target");
    defer results.deinit();

    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("fixtures/proxy/capture.volt", results.items[0].file_path);
}

test "search matches tags with highest weight 4" {
    const auth_tags = [_][]const u8{ "auth", "oauth" };
    const ws_tags = [_][]const u8{"realtime"};
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "fixtures/oauth/token-exchange.volt", .name = "OAuth Token Exchange", .method = "POST", .url = "http://127.0.0.1:9090/oauth/token", .tags = &auth_tags },
        .{ .file_path = "fixtures/websocket/echo.volt", .name = "WebSocket Echo", .method = "GET", .url = "ws://127.0.0.1:9090/ws/echo", .tags = &ws_tags },
    };

    var results = try CollectionOrganizer.searchRequests(testing.allocator, &entries, "oauth");
    defer results.deinit();

    // oauth matches by: file name (3) + name (3) + URL (2) + tag (4) = 12 for oauth fixture
    try testing.expect(results.items.len >= 1);
    try testing.expectEqualStrings("fixtures/oauth/token-exchange.volt", results.items[0].file_path);
    try testing.expect(results.items[0].score >= 4);
}

test "search matches description with weight 1" {
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "fixtures/graphql/query-users.volt", .name = "GraphQL Query Users", .method = "POST", .url = "http://127.0.0.1:9090/graphql", .description = "Fetches all users from the GraphQL API endpoint" },
        .{ .file_path = "fixtures/websocket/echo.volt", .name = "WebSocket Echo", .method = "GET", .url = "ws://127.0.0.1:9090/ws/echo" },
    };

    var results = try CollectionOrganizer.searchRequests(testing.allocator, &entries, "endpoint");
    defer results.deinit();

    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("fixtures/graphql/query-users.volt", results.items[0].file_path);
}

test "search results sorted by score descending" {
    const protocol_tags = [_][]const u8{"protocol"};
    const entries = [_]CollectionOrganizer.SearchEntry{
        // Low match: description only (1)
        .{ .file_path = "a.volt", .name = "Alpha", .method = "GET", .url = "/a", .description = "uses graphql internally" },
        // High match: file + name + URL + tag (3+3+2+4 = 12)
        .{ .file_path = "graphql/query.volt", .name = "GraphQL Query", .method = "POST", .url = "http://localhost/graphql", .tags = &protocol_tags },
        // Medium match: URL only (2)
        .{ .file_path = "b.volt", .name = "Beta", .method = "GET", .url = "/graphql/health" },
    };

    var results = try CollectionOrganizer.searchRequests(testing.allocator, &entries, "graphql");
    defer results.deinit();

    try testing.expectEqual(@as(usize, 3), results.items.len);
    // First result should have highest score
    try testing.expect(results.items[0].score >= results.items[1].score);
    try testing.expect(results.items[1].score >= results.items[2].score);
    try testing.expectEqualStrings("graphql/query.volt", results.items[0].file_path);
}

test "search with no matches returns empty" {
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "fixtures/graphql/query-users.volt", .name = "GraphQL Query Users", .method = "POST", .url = "http://127.0.0.1:9090/graphql" },
    };

    var results = try CollectionOrganizer.searchRequests(testing.allocator, &entries, "nonexistent_xyz_456");
    defer results.deinit();

    try testing.expectEqual(@as(usize, 0), results.items.len);
}

test "search is case-insensitive across all fields" {
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "SSE/Events.volt", .name = "SSE EVENT STREAM", .method = "GET", .url = "HTTP://127.0.0.1:9090/SSE/events" },
    };

    var results = try CollectionOrganizer.searchRequests(testing.allocator, &entries, "sse");
    defer results.deinit();

    try testing.expectEqual(@as(usize, 1), results.items.len);
    // Should match on multiple fields
    try testing.expect(results.items[0].score >= 5); // name(3) + URL(2)
}

// ── Tree Building and Rendering ─────────────────────────────────────────

test "build tree from protocol fixture paths" {
    const paths = [_][]const u8{
        "fixtures/graphql/query-users.volt",
        "fixtures/graphql/query-with-variables.volt",
        "fixtures/websocket/echo.volt",
        "fixtures/sse/events.volt",
        "fixtures/mqtt/connect.volt",
        "fixtures/oauth/token-exchange.volt",
        "fixtures/proxy/capture.volt",
        "fixtures/socketio/handshake.volt",
    };

    var tree = try CollectionOrganizer.buildTree(testing.allocator, &paths);
    defer tree.deinit();

    // Root should be "."
    try testing.expectEqualStrings(".", tree.name);
    try testing.expect(tree.is_directory);

    // Should have one child: "fixtures/"
    try testing.expectEqual(@as(usize, 1), tree.children.items.len);
    try testing.expectEqualStrings("fixtures", tree.children.items[0].name);
    try testing.expect(tree.children.items[0].is_directory);

    // "fixtures/" should have 7 protocol directories (graphql has 2 files but is 1 dir)
    const fixtures = &tree.children.items[0];
    try testing.expectEqual(@as(usize, 7), fixtures.children.items.len);

    // graphql/ should have 2 children
    var graphql_dir: ?*CollectionOrganizer.TreeNode = null;
    for (fixtures.children.items) |*child| {
        if (mem.eql(u8, child.name, "graphql")) {
            graphql_dir = child;
        }
    }
    try testing.expect(graphql_dir != null);
    try testing.expect(graphql_dir.?.is_directory);
    try testing.expectEqual(@as(usize, 2), graphql_dir.?.children.items.len);
}

test "render tree produces box-drawing characters" {
    const paths = [_][]const u8{
        "graphql/query-users.volt",
        "graphql/query-with-variables.volt",
        "websocket/echo.volt",
    };

    var tree = try CollectionOrganizer.buildTree(testing.allocator, &paths);
    defer tree.deinit();

    const rendered = try CollectionOrganizer.renderTree(testing.allocator, &tree);
    defer testing.allocator.free(rendered);

    try testing.expect(rendered.len > 0);
    try testing.expect(mem.indexOf(u8, rendered, "graphql/") != null);
    try testing.expect(mem.indexOf(u8, rendered, "websocket/") != null);
    try testing.expect(mem.indexOf(u8, rendered, "query-users.volt") != null);
    try testing.expect(mem.indexOf(u8, rendered, "echo.volt") != null);
    // Has box-drawing characters
    try testing.expect(
        mem.indexOf(u8, rendered, "\xe2\x94\x9c\xe2\x94\x80\xe2\x94\x80") != null or
            mem.indexOf(u8, rendered, "\xe2\x94\x94\xe2\x94\x80\xe2\x94\x80") != null,
    );
}

test "tree directories sorted before files" {
    const paths = [_][]const u8{
        "api/users/list.volt",
        "api/health.volt",
        "api/users/create.volt",
    };

    var tree = try CollectionOrganizer.buildTree(testing.allocator, &paths);
    defer tree.deinit();

    const api = &tree.children.items[0];
    // "users/" directory should come before "health.volt" file
    try testing.expect(api.children.items[0].is_directory);
    try testing.expectEqualStrings("users", api.children.items[0].name);
    try testing.expect(!api.children.items[1].is_directory);
    try testing.expectEqualStrings("health.volt", api.children.items[1].name);
}

// ── Collection Statistics ───────────────────────────────────────────────

test "stats count HTTP methods from protocol fixtures" {
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "graphql/query-users.volt", .method = "POST" },
        .{ .file_path = "graphql/query-vars.volt", .method = "POST" },
        .{ .file_path = "websocket/echo.volt", .method = "GET" },
        .{ .file_path = "sse/events.volt", .method = "GET" },
        .{ .file_path = "mqtt/connect.volt", .method = "GET" },
        .{ .file_path = "socketio/handshake.volt", .method = "GET" },
        .{ .file_path = "oauth/token-exchange.volt", .method = "POST" },
        .{ .file_path = "proxy/capture.volt", .method = "GET" },
    };

    var stats = try CollectionOrganizer.collectStats(testing.allocator, &entries);
    defer stats.deinit();

    try testing.expectEqual(@as(usize, 8), stats.total_files);
    try testing.expectEqual(@as(usize, 5), stats.methods.get);
    try testing.expectEqual(@as(usize, 3), stats.methods.post);
    try testing.expectEqual(@as(usize, 0), stats.methods.put);
    try testing.expectEqual(@as(usize, 0), stats.methods.delete);
}

test "stats count tags across entries" {
    const auth_tags = [_][]const u8{ "auth", "security" };
    const real_tags = [_][]const u8{ "realtime", "protocol" };
    const proto_tags = [_][]const u8{"protocol"};
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "oauth/token.volt", .tags = &auth_tags },
        .{ .file_path = "ws/echo.volt", .tags = &real_tags },
        .{ .file_path = "sse/events.volt", .tags = &proto_tags },
    };

    var stats = try CollectionOrganizer.collectStats(testing.allocator, &entries);
    defer stats.deinit();

    try testing.expectEqual(@as(usize, 1), stats.tags.get("auth").?);
    try testing.expectEqual(@as(usize, 1), stats.tags.get("security").?);
    try testing.expectEqual(@as(usize, 1), stats.tags.get("realtime").?);
    try testing.expectEqual(@as(usize, 2), stats.tags.get("protocol").?);
}

// ── Tag Filtering ───────────────────────────────────────────────────────

test "filter by tag returns matching indices" {
    const auth_tags = [_][]const u8{ "auth", "security" };
    const proto_tags = [_][]const u8{"protocol"};
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "oauth/token.volt", .tags = &auth_tags },
        .{ .file_path = "ws/echo.volt", .tags = &proto_tags },
        .{ .file_path = "basic-auth/login.volt", .tags = &auth_tags },
        .{ .file_path = "sse/events.volt", .tags = &proto_tags },
    };

    var auth_indices = try CollectionOrganizer.filterByTag(testing.allocator, &entries, "auth");
    defer auth_indices.deinit();

    try testing.expectEqual(@as(usize, 2), auth_indices.items.len);
    try testing.expectEqual(@as(usize, 0), auth_indices.items[0]);
    try testing.expectEqual(@as(usize, 2), auth_indices.items[1]);

    var proto_indices = try CollectionOrganizer.filterByTag(testing.allocator, &entries, "protocol");
    defer proto_indices.deinit();

    try testing.expectEqual(@as(usize, 2), proto_indices.items.len);
    try testing.expectEqual(@as(usize, 1), proto_indices.items[0]);
    try testing.expectEqual(@as(usize, 3), proto_indices.items[1]);
}

test "filter by tag is case-insensitive" {
    const tags = [_][]const u8{"Protocol"};
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "ws/echo.volt", .tags = &tags },
    };

    var indices = try CollectionOrganizer.filterByTag(testing.allocator, &entries, "protocol");
    defer indices.deinit();

    try testing.expectEqual(@as(usize, 1), indices.items.len);
}

test "filter by nonexistent tag returns empty" {
    const tags = [_][]const u8{"auth"};
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "a.volt", .tags = &tags },
    };

    var indices = try CollectionOrganizer.filterByTag(testing.allocator, &entries, "nonexistent");
    defer indices.deinit();

    try testing.expectEqual(@as(usize, 0), indices.items.len);
}

// ── Sorting ─────────────────────────────────────────────────────────────

test "sort entries by name ascending" {
    var entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "c.volt", .name = "WebSocket Echo" },
        .{ .file_path = "a.volt", .name = "GraphQL Query" },
        .{ .file_path = "b.volt", .name = "OAuth Token" },
    };

    CollectionOrganizer.sortEntries(&entries, .name_asc);

    try testing.expectEqualStrings("GraphQL Query", entries[0].name.?);
    try testing.expectEqualStrings("OAuth Token", entries[1].name.?);
    try testing.expectEqualStrings("WebSocket Echo", entries[2].name.?);
}

test "sort entries by name descending" {
    var entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "c.volt", .name = "WebSocket Echo" },
        .{ .file_path = "a.volt", .name = "GraphQL Query" },
        .{ .file_path = "b.volt", .name = "OAuth Token" },
    };

    CollectionOrganizer.sortEntries(&entries, .name_desc);

    try testing.expectEqualStrings("WebSocket Echo", entries[0].name.?);
    try testing.expectEqualStrings("OAuth Token", entries[1].name.?);
    try testing.expectEqualStrings("GraphQL Query", entries[2].name.?);
}

test "sort entries by method" {
    var entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "a.volt", .method = "POST" },
        .{ .file_path = "b.volt", .method = "DELETE" },
        .{ .file_path = "c.volt", .method = "GET" },
        .{ .file_path = "d.volt", .method = "PUT" },
    };

    CollectionOrganizer.sortEntries(&entries, .method);

    try testing.expectEqualStrings("DELETE", entries[0].method);
    try testing.expectEqualStrings("GET", entries[1].method);
    try testing.expectEqualStrings("POST", entries[2].method);
    try testing.expectEqualStrings("PUT", entries[3].method);
}

test "sort entries by URL" {
    var entries = [_]CollectionOrganizer.SearchEntry{
        .{ .file_path = "c.volt", .url = "ws://localhost/ws" },
        .{ .file_path = "a.volt", .url = "http://localhost/api" },
        .{ .file_path = "b.volt", .url = "mqtt://broker/topic" },
    };

    CollectionOrganizer.sortEntries(&entries, .url);

    try testing.expectEqualStrings("http://localhost/api", entries[0].url);
    try testing.expectEqualStrings("mqtt://broker/topic", entries[1].url);
    try testing.expectEqualStrings("ws://localhost/ws", entries[2].url);
}

// ── Integration: Parse Fixtures and Feed to Search ──────────────────────

test "parse chain fixtures and search for login" {
    const login_content = @embedFile("fixtures/chain/01-login.volt");
    var login_req = try VoltFile.parse(testing.allocator, login_content);
    defer login_req.deinit();

    const me_content = @embedFile("fixtures/chain/02-me.volt");
    var me_req = try VoltFile.parse(testing.allocator, me_content);
    defer me_req.deinit();

    // Build search entries from parsed fixtures
    const entries = [_]CollectionOrganizer.SearchEntry{
        .{
            .file_path = "fixtures/chain/01-login.volt",
            .name = login_req.name,
            .method = login_req.method.toString(),
            .url = login_req.url,
        },
        .{
            .file_path = "fixtures/chain/02-me.volt",
            .name = me_req.name,
            .method = me_req.method.toString(),
            .url = me_req.url,
        },
    };

    var results = try CollectionOrganizer.searchRequests(testing.allocator, &entries, "login");
    defer results.deinit();

    // Should find the login fixture
    try testing.expect(results.items.len >= 1);
    try testing.expectEqualStrings("fixtures/chain/01-login.volt", results.items[0].file_path);
}
