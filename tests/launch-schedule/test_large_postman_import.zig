const std = @import("std");
const mem = std.mem;
const volt_core = @import("volt-core");
const Importer = volt_core.Importer;
const VoltFile = volt_core.VoltFile;

// ── Large Postman Collection Import Test ────────────────────────────────
//
// Validates that the Volt importer correctly handles a large Postman v2.1
// collection with 100+ requests across 10 folders, mixed HTTP methods,
// various auth types, scripts, and body formats.

test "import large postman collection with 100+ requests" {
    const allocator = std.testing.allocator;

    // Read the fixture file
    const json_content = @embedFile("fixtures/postman/large-collection-100.json");

    // Parse the collection
    var result = try Importer.importPostman(allocator, json_content);
    defer result.deinit();

    // ── Assert: 100+ requests imported ──────────────────────────────
    try std.testing.expect(result.requests.items.len >= 100);

    // ── Assert: collection name set ─────────────────────────────────
    try std.testing.expectEqualStrings("Enterprise API Suite", result.collection_name);

    // ── Assert: collection auth parsed (bearer) ─────────────────────
    try std.testing.expect(result.collection_auth != null);
    const coll_auth = result.collection_auth.?;
    try std.testing.expect(coll_auth.type == .bearer);
    try std.testing.expect(coll_auth.token != null);
    try std.testing.expectEqualStrings("{{global_token}}", coll_auth.token.?);

    // ── Assert: collection variables parsed ──────────────────────────
    try std.testing.expect(result.collection_variables.items.len >= 5);
    // Verify specific variables exist
    var found_base_url = false;
    var found_api_version = false;
    var found_global_token = false;
    for (result.collection_variables.items) |v| {
        if (mem.eql(u8, v.key, "base_url")) {
            try std.testing.expectEqualStrings("https://api.enterprise.io", v.value);
            found_base_url = true;
        }
        if (mem.eql(u8, v.key, "api_version")) {
            try std.testing.expectEqualStrings("v2", v.value);
            found_api_version = true;
        }
        if (mem.eql(u8, v.key, "global_token")) {
            try std.testing.expectEqualStrings("ent-tok-abc123xyz", v.value);
            found_global_token = true;
        }
    }
    try std.testing.expect(found_base_url);
    try std.testing.expect(found_api_version);
    try std.testing.expect(found_global_token);

    // ── Assert: no fatal errors ─────────────────────────────────────
    // Non-fatal script conversion warnings are acceptable, but there
    // should be no structural import failures.
    for (result.errors.items) |err_msg| {
        // Ensure no "Failed to import" errors (structural failures)
        try std.testing.expect(mem.indexOf(u8, err_msg, "Failed to import") == null);
    }

    // ── Assert: folder structure preserved ───────────────────────────
    // Requests should be prefixed with their folder name in the path.
    // Count requests per folder to verify all 10 folders are present.
    var folder_counts = std.StringHashMap(usize).init(allocator);
    defer folder_counts.deinit();

    for (result.requests.items) |req| {
        // Path format is "folder_name/Request Name.volt"
        if (mem.indexOf(u8, req.path, "/")) |slash_idx| {
            const folder = req.path[0..slash_idx];
            const entry = try folder_counts.getOrPut(folder);
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
        }
    }

    // All 10 folders should be present
    const expected_folders = [_][]const u8{
        "users",
        "auth",
        "products",
        "orders",
        "payments",
        "admin",
        "settings",
        "analytics",
        "notifications",
        "webhooks",
    };
    for (expected_folders) |folder_name| {
        const count = folder_counts.get(folder_name);
        try std.testing.expect(count != null);
        // Each folder should have at least 10 requests
        try std.testing.expect(count.? >= 10);
    }
}

test "large collection has mixed HTTP methods" {
    const allocator = std.testing.allocator;
    const json_content = @embedFile("fixtures/postman/large-collection-100.json");

    var result = try Importer.importPostman(allocator, json_content);
    defer result.deinit();

    var get_count: usize = 0;
    var post_count: usize = 0;
    var put_count: usize = 0;
    var patch_count: usize = 0;
    var delete_count: usize = 0;

    for (result.requests.items) |req| {
        switch (req.request.method) {
            .GET => get_count += 1,
            .POST => post_count += 1,
            .PUT => put_count += 1,
            .PATCH => patch_count += 1,
            .DELETE => delete_count += 1,
            else => {},
        }
    }

    // Verify all major methods are represented
    try std.testing.expect(get_count > 0);
    try std.testing.expect(post_count > 0);
    try std.testing.expect(put_count > 0);
    try std.testing.expect(patch_count > 0);
    try std.testing.expect(delete_count > 0);

    // GET and POST should be the most common
    try std.testing.expect(get_count >= 30);
    try std.testing.expect(post_count >= 20);
}

test "large collection has various auth types" {
    const allocator = std.testing.allocator;
    const json_content = @embedFile("fixtures/postman/large-collection-100.json");

    var result = try Importer.importPostman(allocator, json_content);
    defer result.deinit();

    var has_bearer_auth = false;
    var has_basic_auth = false;
    var has_apikey_auth = false;

    for (result.requests.items) |req| {
        switch (req.request.auth.type) {
            .bearer => has_bearer_auth = true,
            .basic => has_basic_auth = true,
            .api_key => has_apikey_auth = true,
            else => {},
        }
    }

    // Collection-level auth is bearer
    try std.testing.expect(result.collection_auth != null);
    try std.testing.expect(result.collection_auth.?.type == .bearer);

    // Request-level auth types should include basic and api_key
    try std.testing.expect(has_basic_auth);
    try std.testing.expect(has_apikey_auth);
}

test "large collection has scripts on some requests" {
    const allocator = std.testing.allocator;
    const json_content = @embedFile("fixtures/postman/large-collection-100.json");

    var result = try Importer.importPostman(allocator, json_content);
    defer result.deinit();

    var pre_script_count: usize = 0;
    var post_script_count: usize = 0;

    for (result.requests.items) |req| {
        if (req.request.pre_script != null) pre_script_count += 1;
        if (req.request.post_script != null) post_script_count += 1;
    }

    // Should have at least some pre-request and test scripts
    try std.testing.expect(pre_script_count >= 2);
    try std.testing.expect(post_script_count >= 5);
}

test "large collection has various body types" {
    const allocator = std.testing.allocator;
    const json_content = @embedFile("fixtures/postman/large-collection-100.json");

    var result = try Importer.importPostman(allocator, json_content);
    defer result.deinit();

    var json_body_count: usize = 0;
    var form_body_count: usize = 0;
    var has_any_body = false;

    for (result.requests.items) |req| {
        if (req.request.body != null) {
            has_any_body = true;
            switch (req.request.body_type) {
                .json => json_body_count += 1,
                .form => form_body_count += 1,
                else => {},
            }
        }
    }

    try std.testing.expect(has_any_body);
    // Should have multiple JSON body requests
    try std.testing.expect(json_body_count >= 15);
    // Should have formdata and urlencoded (both map to .form)
    try std.testing.expect(form_body_count >= 3);
}

test "large collection preserves variable references in URLs" {
    const allocator = std.testing.allocator;
    const json_content = @embedFile("fixtures/postman/large-collection-100.json");

    var result = try Importer.importPostman(allocator, json_content);
    defer result.deinit();

    var variable_url_count: usize = 0;

    for (result.requests.items) |req| {
        if (mem.indexOf(u8, req.request.url, "{{") != null) {
            variable_url_count += 1;
        }
    }

    // Most URLs should contain variable references
    try std.testing.expect(variable_url_count >= 90);
}

test "large collection generates valid collection volt content" {
    const allocator = std.testing.allocator;
    const json_content = @embedFile("fixtures/postman/large-collection-100.json");

    var result = try Importer.importPostman(allocator, json_content);
    defer result.deinit();

    // Generate _collection.volt content
    const coll_content = try result.generateCollectionVolt(allocator);
    try std.testing.expect(coll_content != null);
    defer allocator.free(coll_content.?);

    try std.testing.expect(mem.indexOf(u8, coll_content.?, "type: bearer") != null);
    try std.testing.expect(mem.indexOf(u8, coll_content.?, "Enterprise API Suite") != null);

    // Generate _env.volt content
    const env_content = try result.generateEnvVolt(allocator);
    try std.testing.expect(env_content != null);
    defer allocator.free(env_content.?);

    try std.testing.expect(mem.indexOf(u8, env_content.?, "environment: collection") != null);
    try std.testing.expect(mem.indexOf(u8, env_content.?, "base_url: https://api.enterprise.io") != null);
    try std.testing.expect(mem.indexOf(u8, env_content.?, "api_version: v2") != null);
}

test "large collection exact request count is 101" {
    const allocator = std.testing.allocator;
    const json_content = @embedFile("fixtures/postman/large-collection-100.json");

    var result = try Importer.importPostman(allocator, json_content);
    defer result.deinit();

    // 10 folders x 10 requests each + 1 extra in webhooks = 101
    try std.testing.expectEqual(@as(usize, 101), result.requests.items.len);
}
