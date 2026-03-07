const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const volt_core = @import("volt-core");
const Environment = volt_core.Environment;
const EnvManager = Environment.EnvManager;

// ── 10-Request Chain Variable Propagation Tests ─────────────────────────
//
// Simulates a 10-request sequential chain where each request:
//   1. Resolves variables from the environment (using interpolate())
//   2. Extracts a value from a mock response
//   3. Sets that value as a runtime variable (using setRuntimeVar())
//   4. The next request uses {{extracted_var}} which resolves to the previous step's value
//
// This validates the core mechanism behind collection runner variable chaining.

/// Simulate extracting a value from a mock JSON response body.
/// In real usage this would be a JSONPath extraction; here we return a deterministic
/// value based on the step number and the resolved URL from the previous step.
fn mockExtractFromResponse(allocator: std.mem.Allocator, step: usize, resolved_url: []const u8) ![]const u8 {
    // Simulate a response that returns an ID derived from the request URL.
    // For step 0: the seed URL produces "id_1"
    // For step N: incorporates the previous resolved URL to prove chaining worked.
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.print("id_{d}", .{step + 1});

    // Append a hash suffix derived from the resolved URL to prove the URL was correct
    var hash: u32 = 0;
    for (resolved_url) |c| {
        hash = hash *% 31 +% @as(u32, c);
    }
    try writer.print("_{x}", .{hash});

    return buf.toOwnedSlice();
}

// ── Test: 10-step sequential chain propagation ──────────────────────────

test "10-request chain propagation via runtime variables" {
    const allocator = testing.allocator;

    var mgr = EnvManager.init(allocator);
    defer mgr.deinit();

    // Set up a base environment with a seed variable
    const env = try mgr.createEnv("staging");
    try env.set("base_url", "https://api.launch-schedule.dev");
    try env.set("api_version", "v3");
    mgr.setActive("staging");

    // Set an initial seed value that the first request will use
    try mgr.setRuntimeVar("current_id", "seed_0");

    // Define 10 request URL templates — each uses {{current_id}} from the previous step
    const request_templates = [_][]const u8{
        "{{base_url}}/{{api_version}}/launches/{{current_id}}",
        "{{base_url}}/{{api_version}}/missions/{{current_id}}",
        "{{base_url}}/{{api_version}}/vehicles/{{current_id}}",
        "{{base_url}}/{{api_version}}/pads/{{current_id}}",
        "{{base_url}}/{{api_version}}/orbits/{{current_id}}",
        "{{base_url}}/{{api_version}}/payloads/{{current_id}}",
        "{{base_url}}/{{api_version}}/agencies/{{current_id}}",
        "{{base_url}}/{{api_version}}/astronauts/{{current_id}}",
        "{{base_url}}/{{api_version}}/events/{{current_id}}",
        "{{base_url}}/{{api_version}}/updates/{{current_id}}",
    };

    // Track all extracted values to verify at the end
    var extracted_values: [10][]const u8 = undefined;
    var num_extracted: usize = 0;
    defer {
        for (extracted_values[0..num_extracted]) |v| {
            allocator.free(v);
        }
    }

    // Execute the 10-step chain
    for (request_templates, 0..) |template, step| {
        // Step 1: Resolve variables in the request URL
        const resolved_url = try mgr.interpolate(template, null, allocator);
        defer allocator.free(resolved_url);

        // Verify that {{current_id}} was resolved (no unresolved placeholders remain)
        try testing.expect(mem.indexOf(u8, resolved_url, "{{current_id}}") == null);

        // Verify the base_url and api_version were resolved
        try testing.expect(mem.startsWith(u8, resolved_url, "https://api.launch-schedule.dev/v3/"));

        // For step 0, the URL should contain the seed value
        if (step == 0) {
            try testing.expect(mem.indexOf(u8, resolved_url, "seed_0") != null);
        } else {
            // For subsequent steps, the URL should contain the value extracted in the previous step
            try testing.expect(mem.indexOf(u8, resolved_url, extracted_values[step - 1]) != null);
        }

        // Step 2: Simulate extracting a value from the mock response
        const extracted = try mockExtractFromResponse(allocator, step, resolved_url);
        extracted_values[step] = extracted;
        num_extracted = step + 1;

        // Step 3: Set the extracted value as a runtime variable for the next request
        try mgr.setRuntimeVar("current_id", extracted);

        // Verify the runtime variable was updated
        const current = mgr.resolve("current_id", null);
        try testing.expect(current != null);
        try testing.expectEqualStrings(extracted, current.?);
    }

    // Final verification: after all 10 steps, current_id should be the last extracted value
    const final_id = mgr.resolve("current_id", null).?;
    try testing.expectEqualStrings(extracted_values[9], final_id);

    // Verify all 10 values are distinct (each step produced a unique ID)
    for (extracted_values[0..10], 0..) |val_a, i| {
        for (extracted_values[0..10], 0..) |val_b, j| {
            if (i != j) {
                try testing.expect(!mem.eql(u8, val_a, val_b));
            }
        }
    }
}

// ── Test: Chain propagation with scoping hierarchy ──────────────────────

test "chain propagation respects scoping hierarchy: request > runtime > environment > global" {
    const allocator = testing.allocator;

    var mgr = EnvManager.init(allocator);
    defer mgr.deinit();

    // Set up all four scope levels with the same key
    // Global (lowest priority)
    try mgr.global_vars.put("token", "global_token_aaa");

    // Environment
    const env = try mgr.createEnv("prod");
    try env.set("token", "env_token_bbb");
    mgr.setActive("prod");

    // Verify: environment > global
    const url1 = try mgr.interpolate("Bearer {{token}}", null, allocator);
    defer allocator.free(url1);
    try testing.expectEqualStrings("Bearer env_token_bbb", url1);

    // Runtime (set during chain execution, higher than environment)
    try mgr.setRuntimeVar("token", "runtime_token_ccc");

    const url2 = try mgr.interpolate("Bearer {{token}}", null, allocator);
    defer allocator.free(url2);
    try testing.expectEqualStrings("Bearer runtime_token_ccc", url2);

    // Request-level variables (highest priority)
    var req_vars = std.StringHashMap([]const u8).init(allocator);
    defer req_vars.deinit();
    try req_vars.put("token", "request_token_ddd");

    const url3 = try mgr.interpolate("Bearer {{token}}", &req_vars, allocator);
    defer allocator.free(url3);
    try testing.expectEqualStrings("Bearer request_token_ddd", url3);

    // Now simulate a chain: step 1 extracts a new token, overriding runtime
    try mgr.setRuntimeVar("token", "chain_step1_token_eee");

    // Without request vars, runtime should win over environment and global
    const url4 = try mgr.interpolate("Bearer {{token}}", null, allocator);
    defer allocator.free(url4);
    try testing.expectEqualStrings("Bearer chain_step1_token_eee", url4);

    // With request vars, request level still wins
    const url5 = try mgr.interpolate("Bearer {{token}}", &req_vars, allocator);
    defer allocator.free(url5);
    try testing.expectEqualStrings("Bearer request_token_ddd", url5);

    // After clearing runtime, fall back to environment
    mgr.clearRuntimeVars();
    const url6 = try mgr.interpolate("Bearer {{token}}", null, allocator);
    defer allocator.free(url6);
    try testing.expectEqualStrings("Bearer env_token_bbb", url6);
}

// ── Test: Chain with multiple variables propagated per step ──────────────

test "chain propagation with multiple variables per step" {
    const allocator = testing.allocator;

    var mgr = EnvManager.init(allocator);
    defer mgr.deinit();

    const env = try mgr.createEnv("test");
    try env.set("base_url", "https://api.example.com");
    mgr.setActive("test");

    // Step 1: Login — extract both token and user_id
    const login_url = try mgr.interpolate("{{base_url}}/auth/login", null, allocator);
    defer allocator.free(login_url);
    try testing.expectEqualStrings("https://api.example.com/auth/login", login_url);

    // Mock extraction: response contains token and user_id
    try mgr.setRuntimeVar("auth_token", "eyJhbGciOiJIUzI1NiJ9.tok123");
    try mgr.setRuntimeVar("user_id", "usr_42");

    // Step 2: Get user profile — uses both extracted variables
    const profile_url = try mgr.interpolate("{{base_url}}/users/{{user_id}}", null, allocator);
    defer allocator.free(profile_url);
    try testing.expectEqualStrings("https://api.example.com/users/usr_42", profile_url);

    const auth_header = try mgr.interpolate("Bearer {{auth_token}}", null, allocator);
    defer allocator.free(auth_header);
    try testing.expectEqualStrings("Bearer eyJhbGciOiJIUzI1NiJ9.tok123", auth_header);

    // Step 3: Extract nested data and chain it forward
    try mgr.setRuntimeVar("org_id", "org_99");

    const org_url = try mgr.interpolate("{{base_url}}/orgs/{{org_id}}/members/{{user_id}}", null, allocator);
    defer allocator.free(org_url);
    try testing.expectEqualStrings("https://api.example.com/orgs/org_99/members/usr_42", org_url);
}

// ── Test: 10-step chain with evolving runtime overrides ─────────────────

test "10-step chain with runtime variable updates at each step" {
    const allocator = testing.allocator;

    var mgr = EnvManager.init(allocator);
    defer mgr.deinit();

    // Set up environment baseline
    const env = try mgr.createEnv("chain-test");
    try env.set("host", "chain.example.com");
    mgr.setActive("chain-test");

    // Simulate 10 steps where each step extracts a "page_token" for pagination
    try mgr.setRuntimeVar("page_token", "start");

    var step: usize = 0;
    while (step < 10) : (step += 1) {
        // Build URL with the current page_token
        const url = try mgr.interpolate("https://{{host}}/items?page={{page_token}}", null, allocator);
        defer allocator.free(url);

        // Verify the page_token is resolved
        try testing.expect(mem.indexOf(u8, url, "{{page_token}}") == null);
        try testing.expect(mem.indexOf(u8, url, "page=") != null);

        // Simulate: response returns next page token
        var token_buf: [32]u8 = undefined;
        const next_token = std.fmt.bufPrint(&token_buf, "page_{d}", .{step + 1}) catch unreachable;

        try mgr.setRuntimeVar("page_token", next_token);
    }

    // After 10 iterations, page_token should be "page_10"
    const final_token = mgr.resolve("page_token", null).?;
    try testing.expectEqualStrings("page_10", final_token);
}

// ── Test: Chain propagation preserves unrelated variables ────────────────

test "chain propagation preserves unrelated variables across steps" {
    const allocator = testing.allocator;

    var mgr = EnvManager.init(allocator);
    defer mgr.deinit();

    const env = try mgr.createEnv("preserve-test");
    try env.set("base_url", "https://api.test.com");
    try env.set("api_key", "key_abc123");
    mgr.setActive("preserve-test");

    // Set initial runtime vars
    try mgr.setRuntimeVar("session_id", "sess_001");
    try mgr.setRuntimeVar("cursor", "cursor_start");

    // Step 1: Update cursor but session_id should remain
    try mgr.setRuntimeVar("cursor", "cursor_page2");
    try testing.expectEqualStrings("sess_001", mgr.resolve("session_id", null).?);
    try testing.expectEqualStrings("cursor_page2", mgr.resolve("cursor", null).?);

    // Interpolate a URL using all of them
    const url = try mgr.interpolate(
        "{{base_url}}/data?key={{api_key}}&session={{session_id}}&cursor={{cursor}}",
        null,
        allocator,
    );
    defer allocator.free(url);
    try testing.expectEqualStrings(
        "https://api.test.com/data?key=key_abc123&session=sess_001&cursor=cursor_page2",
        url,
    );

    // Step 2-10: Keep updating cursor, verify session stays intact
    var i: usize = 3;
    while (i <= 10) : (i += 1) {
        var cursor_buf: [32]u8 = undefined;
        const new_cursor = std.fmt.bufPrint(&cursor_buf, "cursor_page{d}", .{i}) catch unreachable;
        try mgr.setRuntimeVar("cursor", new_cursor);

        // session_id is never touched, should remain
        try testing.expectEqualStrings("sess_001", mgr.resolve("session_id", null).?);

        // api_key comes from the environment, should remain
        try testing.expectEqualStrings("key_abc123", mgr.resolve("api_key", null).?);
    }

    // Final state
    try testing.expectEqualStrings("cursor_page10", mgr.resolve("cursor", null).?);
    try testing.expectEqualStrings("sess_001", mgr.resolve("session_id", null).?);
}

// ── Test: resolveWithScope across 10-step chain ─────────────────────────

test "resolveWithScope correctly identifies scope at each chain step" {
    const allocator = testing.allocator;

    var mgr = EnvManager.init(allocator);
    defer mgr.deinit();

    // Global variable
    try mgr.global_vars.put("fallback_id", "global_fallback");

    // Environment variable
    const env = try mgr.createEnv("scope-chain");
    try env.set("env_id", "env_default");
    try env.set("fallback_id", "env_override");
    mgr.setActive("scope-chain");

    // Before any chain steps: fallback_id should resolve from environment (overrides global)
    var scoped = mgr.resolveWithScope("fallback_id", null);
    try testing.expectEqualStrings("env_override", scoped.value.?);
    try testing.expect(scoped.scope == .environment);

    // Chain step 1: set runtime variable
    try mgr.setRuntimeVar("fallback_id", "runtime_step1");

    scoped = mgr.resolveWithScope("fallback_id", null);
    try testing.expectEqualStrings("runtime_step1", scoped.value.?);
    try testing.expect(scoped.scope == .runtime);

    // Chain step 2-10: update runtime, verify scope stays runtime
    var step: usize = 2;
    while (step <= 10) : (step += 1) {
        var val_buf: [32]u8 = undefined;
        const val = std.fmt.bufPrint(&val_buf, "runtime_step{d}", .{step}) catch unreachable;
        try mgr.setRuntimeVar("fallback_id", val);

        scoped = mgr.resolveWithScope("fallback_id", null);
        try testing.expect(scoped.scope == .runtime);
    }

    // After clearing runtime vars, should fall back to environment scope
    mgr.clearRuntimeVars();
    scoped = mgr.resolveWithScope("fallback_id", null);
    try testing.expectEqualStrings("env_override", scoped.value.?);
    try testing.expect(scoped.scope == .environment);

    // env_id was never overridden, always in environment scope
    scoped = mgr.resolveWithScope("env_id", null);
    try testing.expectEqualStrings("env_default", scoped.value.?);
    try testing.expect(scoped.scope == .environment);
}
