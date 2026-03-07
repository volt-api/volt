const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const volt_core = @import("volt-core");
const Replay = volt_core.Replay;
const History = volt_core.History;
const VoltFile = volt_core.VoltFile;
const HttpClient = volt_core.HttpClient;

// ── Replay and History Tests ────────────────────────────────────────────
//
// Validates response diffing (Replay module) and request history tracking
// (History module) using data patterns from the launch-schedule fixtures.
// Tests cover: JSON field diff, header diff, status comparison, replay
// formatting, history recording, and stateful counter simulation.

// ── Response Comparison: JSON Bodies ────────────────────────────────────

test "compare identical login responses" {
    const original = "{\"token\": \"abc123\", \"user\": {\"id\": 1}}";
    const replay_body = "{\"token\": \"abc123\", \"user\": {\"id\": 1}}";

    var changes = Replay.compareResponses(testing.allocator, original, replay_body);
    defer changes.deinit();

    // All fields unchanged
    for (changes.items) |change| {
        try testing.expectEqual(Replay.ChangeType.unchanged, change.change_type);
    }
}

test "compare login response with changed token" {
    const original = "{\"token\": \"abc123\", \"user\": {\"id\": 1}}";
    const replay_body = "{\"token\": \"xyz789\", \"user\": {\"id\": 1}}";

    var changes = Replay.compareResponses(testing.allocator, original, replay_body);
    defer changes.deinit();

    var found_modified = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "token") and change.change_type == .modified) {
            found_modified = true;
            try testing.expectEqualStrings("abc123", change.old_value);
            try testing.expectEqualStrings("xyz789", change.new_value);
        }
    }
    try testing.expect(found_modified);
}

test "compare responses with added field" {
    const original = "{\"token\": \"abc123\"}";
    const replay_body = "{\"token\": \"abc123\", \"refresh_token\": \"rt_456\"}";

    var changes = Replay.compareResponses(testing.allocator, original, replay_body);
    defer changes.deinit();

    var found_added = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "refresh_token") and change.change_type == .added) {
            found_added = true;
            try testing.expectEqualStrings("rt_456", change.new_value);
        }
    }
    try testing.expect(found_added);
}

test "compare responses with removed field" {
    const original = "{\"token\": \"abc123\", \"expires_in\": 3600}";
    const replay_body = "{\"token\": \"abc123\"}";

    var changes = Replay.compareResponses(testing.allocator, original, replay_body);
    defer changes.deinit();

    var found_removed = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "expires_in") and change.change_type == .removed) {
            found_removed = true;
        }
    }
    try testing.expect(found_removed);
}

test "compare non-JSON text responses identical" {
    const original = "<h1>Volt HTML</h1><p>ok</p>";
    const replay_body = "<h1>Volt HTML</h1><p>ok</p>";

    var changes = Replay.compareResponses(testing.allocator, original, replay_body);
    defer changes.deinit();

    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(Replay.ChangeType.unchanged, changes.items[0].change_type);
    try testing.expectEqualStrings("body", changes.items[0].field);
}

test "compare non-JSON text responses different" {
    const original = "<h1>Volt HTML</h1><p>v1</p>";
    const replay_body = "<h1>Volt HTML</h1><p>v2</p>";

    var changes = Replay.compareResponses(testing.allocator, original, replay_body);
    defer changes.deinit();

    try testing.expectEqual(@as(usize, 1), changes.items.len);
    try testing.expectEqual(Replay.ChangeType.modified, changes.items[0].change_type);
}

// ── Header Comparison ───────────────────────────────────────────────────

test "compare identical headers" {
    const original = "Content-Type: application/json\nX-Request-Id: req-001";
    const replay_hdrs = "Content-Type: application/json\nX-Request-Id: req-001";

    var changes = Replay.compareHeaders(testing.allocator, original, replay_hdrs);
    defer changes.deinit();

    for (changes.items) |change| {
        try testing.expectEqual(Replay.ChangeType.unchanged, change.change_type);
    }
}

test "compare headers with modified value" {
    const original = "Content-Type: application/json\nX-Version: 1";
    const replay_hdrs = "Content-Type: application/json\nX-Version: 2";

    var changes = Replay.compareHeaders(testing.allocator, original, replay_hdrs);
    defer changes.deinit();

    var found_modified = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "X-Version") and change.change_type == .modified) {
            found_modified = true;
            try testing.expectEqualStrings("1", change.old_value);
            try testing.expectEqualStrings("2", change.new_value);
        }
    }
    try testing.expect(found_modified);
}

test "compare headers with added and removed" {
    const original = "Content-Type: application/json\nX-Old-Header: value";
    const replay_hdrs = "Content-Type: application/json\nX-New-Header: value";

    var changes = Replay.compareHeaders(testing.allocator, original, replay_hdrs);
    defer changes.deinit();

    var found_removed = false;
    var found_added = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "X-Old-Header") and change.change_type == .removed) found_removed = true;
        if (mem.eql(u8, change.field, "X-New-Header") and change.change_type == .added) found_added = true;
    }
    try testing.expect(found_removed);
    try testing.expect(found_added);
}

// ── Replay Result Formatting ────────────────────────────────────────────

test "format replay diff with matching status" {
    var result = Replay.ReplayResult.init(testing.allocator);
    defer result.deinit();
    result.original_status = 200;
    result.replay_status = 200;
    result.timing_ms = 25.5;
    result.matched = true;

    try result.changes.append(.{
        .field = "token",
        .old_value = "abc",
        .new_value = "abc",
        .change_type = .unchanged,
    });

    const diff = Replay.formatReplayDiff(testing.allocator, &result);
    defer testing.allocator.free(diff);

    try testing.expect(mem.indexOf(u8, diff, "Replay Diff") != null);
    try testing.expect(mem.indexOf(u8, diff, "200") != null);
    try testing.expect(mem.indexOf(u8, diff, "unchanged") != null);
    try testing.expect(mem.indexOf(u8, diff, "25.5ms") != null);
}

test "format replay diff with changed status" {
    var result = Replay.ReplayResult.init(testing.allocator);
    defer result.deinit();
    result.original_status = 200;
    result.replay_status = 500;
    result.timing_ms = 100.0;
    result.matched = false;

    const diff = Replay.formatReplayDiff(testing.allocator, &result);
    defer testing.allocator.free(diff);

    try testing.expect(mem.indexOf(u8, diff, "200") != null);
    try testing.expect(mem.indexOf(u8, diff, "500") != null);
    try testing.expect(mem.indexOf(u8, diff, "CHANGED") != null);
}

test "format replay diff with all change types" {
    var result = Replay.ReplayResult.init(testing.allocator);
    defer result.deinit();
    result.original_status = 200;
    result.replay_status = 200;
    result.timing_ms = 50.0;
    result.matched = true;

    try result.changes.append(.{
        .field = "id",
        .old_value = "1",
        .new_value = "1",
        .change_type = .unchanged,
    });
    try result.changes.append(.{
        .field = "name",
        .old_value = "Alice",
        .new_value = "Bob",
        .change_type = .modified,
    });
    try result.changes.append(.{
        .field = "email",
        .old_value = "",
        .new_value = "bob@test.com",
        .change_type = .added,
    });
    try result.changes.append(.{
        .field = "age",
        .old_value = "30",
        .new_value = "",
        .change_type = .removed,
    });

    const diff = Replay.formatReplayDiff(testing.allocator, &result);
    defer testing.allocator.free(diff);

    try testing.expect(mem.indexOf(u8, diff, "~ name") != null);
    try testing.expect(mem.indexOf(u8, diff, "+ email") != null);
    try testing.expect(mem.indexOf(u8, diff, "- age") != null);
    // Summary line: +1 -1 ~1
    try testing.expect(mem.indexOf(u8, diff, "+1") != null);
    try testing.expect(mem.indexOf(u8, diff, "-1") != null);
    try testing.expect(mem.indexOf(u8, diff, "~1") != null);
}

// ── Replay Summary ──────────────────────────────────────────────────────

test "format replay summary one-liner" {
    var result = Replay.ReplayResult.init(testing.allocator);
    defer result.deinit();
    result.replay_status = 200;
    result.timing_ms = 42.0;
    result.matched = true;

    try result.changes.append(.{
        .field = "name",
        .old_value = "old",
        .new_value = "new",
        .change_type = .modified,
    });

    const summary = Replay.formatReplaySummary(testing.allocator, &result);
    defer testing.allocator.free(summary);

    try testing.expect(mem.indexOf(u8, summary, "Replay:") != null);
    try testing.expect(mem.indexOf(u8, summary, "200") != null);
    try testing.expect(mem.indexOf(u8, summary, "1 change(s)") != null);
    try testing.expect(mem.indexOf(u8, summary, "42.0ms") != null);
}

test "format replay summary with zero changes" {
    var result = Replay.ReplayResult.init(testing.allocator);
    defer result.deinit();
    result.replay_status = 200;
    result.timing_ms = 10.0;
    result.matched = true;

    try result.changes.append(.{
        .field = "data",
        .old_value = "same",
        .new_value = "same",
        .change_type = .unchanged,
    });

    const summary = Replay.formatReplaySummary(testing.allocator, &result);
    defer testing.allocator.free(summary);

    try testing.expect(mem.indexOf(u8, summary, "0 change(s)") != null);
}

// ── Replay Result Lifecycle ─────────────────────────────────────────────

test "ReplayResult init defaults" {
    var result = Replay.ReplayResult.init(testing.allocator);
    defer result.deinit();

    try testing.expectEqual(@as(?u16, null), result.original_status);
    try testing.expectEqual(@as(u16, 0), result.replay_status);
    try testing.expect(result.matched);
    try testing.expectEqual(@as(usize, 0), result.changes.items.len);
}

test "ChangeType toString and symbol" {
    try testing.expectEqualStrings("added", Replay.ChangeType.added.toString());
    try testing.expectEqualStrings("+", Replay.ChangeType.added.symbol());
    try testing.expectEqualStrings("removed", Replay.ChangeType.removed.toString());
    try testing.expectEqualStrings("-", Replay.ChangeType.removed.symbol());
    try testing.expectEqualStrings("modified", Replay.ChangeType.modified.toString());
    try testing.expectEqualStrings("~", Replay.ChangeType.modified.symbol());
    try testing.expectEqualStrings("unchanged", Replay.ChangeType.unchanged.toString());
    try testing.expectEqualStrings(" ", Replay.ChangeType.unchanged.symbol());
}

// ── Stateful Counter Replay Simulation ──────────────────────────────────
//
// Simulates the replay/counter.volt fixture scenario: a stateful /counter
// endpoint that increments on each call. Verifies that replay diff correctly
// detects the counter value change.

test "simulate stateful counter replay diff" {
    // First call: counter returns 1
    const response_1 = "{\"count\": 1}";
    // Replay call: counter returns 2 (incremented)
    const response_2 = "{\"count\": 2}";

    var changes = Replay.compareResponses(testing.allocator, response_1, response_2);
    defer changes.deinit();

    var found_count_modified = false;
    for (changes.items) |change| {
        if (mem.eql(u8, change.field, "count") and change.change_type == .modified) {
            found_count_modified = true;
            try testing.expectEqualStrings("1", change.old_value);
            try testing.expectEqualStrings("2", change.new_value);
        }
    }
    try testing.expect(found_count_modified);
}

test "simulate counter replay with same value" {
    const response_1 = "{\"count\": 5}";
    const response_2 = "{\"count\": 5}";

    var changes = Replay.compareResponses(testing.allocator, response_1, response_2);
    defer changes.deinit();

    for (changes.items) |change| {
        try testing.expectEqual(Replay.ChangeType.unchanged, change.change_type);
    }
}

// ── Request History ─────────────────────────────────────────────────────

test "history init and count" {
    var history = History.RequestHistory.init(testing.allocator);
    defer history.deinit();

    try testing.expectEqual(@as(usize, 0), history.count());
}

test "history lastN returns empty for no entries" {
    var history = History.RequestHistory.init(testing.allocator);
    defer history.deinit();

    const entries = history.lastN(10);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "history max_entries default is 1000" {
    var history = History.RequestHistory.init(testing.allocator);
    defer history.deinit();

    try testing.expectEqual(@as(usize, 1000), history.max_entries);
}

test "history clear empties all entries" {
    var history = History.RequestHistory.init(testing.allocator);
    defer history.deinit();

    history.clear();
    try testing.expectEqual(@as(usize, 0), history.count());
}

// ── Cookie Jar ──────────────────────────────────────────────────────────

test "cookie jar stores and retrieves cookies" {
    var jar = History.CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("session=tok123; path=/; HttpOnly", null);
    try testing.expectEqual(@as(usize, 1), jar.count());
    try testing.expectEqualStrings("session", jar.cookies.items[0].name);
    try testing.expectEqualStrings("tok123", jar.cookies.items[0].value);
    try testing.expect(jar.cookies.items[0].http_only);
}

test "cookie jar updates existing cookie" {
    var jar = History.CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("session=old_value", null);
    try jar.parseSetCookie("session=new_value", null);

    try testing.expectEqual(@as(usize, 1), jar.count());
    try testing.expectEqualStrings("new_value", jar.cookies.items[0].value);
}

test "cookie jar builds cookie string" {
    var jar = History.CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("session=abc", null);
    try jar.parseSetCookie("csrf=xyz", null);

    const cookie_str = try jar.buildCookieString(testing.allocator);
    defer if (cookie_str) |s| testing.allocator.free(s);

    try testing.expect(cookie_str != null);
    try testing.expect(mem.indexOf(u8, cookie_str.?, "session=abc") != null);
    try testing.expect(mem.indexOf(u8, cookie_str.?, "csrf=xyz") != null);
}

test "cookie jar clear removes all cookies" {
    var jar = History.CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("session=abc", null);
    try jar.parseSetCookie("csrf=xyz", null);
    try testing.expectEqual(@as(usize, 2), jar.count());

    jar.clear();
    try testing.expectEqual(@as(usize, 0), jar.count());
}

test "cookie jar parses secure flag" {
    var jar = History.CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("token=val; secure; path=/api", null);

    try testing.expectEqual(@as(usize, 1), jar.count());
    try testing.expect(jar.cookies.items[0].secure);
}

test "cookie jar parses domain and path" {
    var jar = History.CookieJar.init(testing.allocator);
    defer jar.deinit();

    try jar.parseSetCookie("session=abc; domain=.example.com; path=/api", null);

    try testing.expectEqual(@as(usize, 1), jar.count());
    try testing.expectEqualStrings(".example.com", jar.cookies.items[0].domain.?);
    try testing.expectEqualStrings("/api", jar.cookies.items[0].path.?);
}
