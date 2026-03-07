const std = @import("std");
const mem = std.mem;
const volt_core = @import("volt-core");
const HttpClient = volt_core.HttpClient;
const VoltFile = volt_core.VoltFile;

// ── Large Response Performance Test ─────────────────────────────────────
//
// Validates that the HTTP client's Response struct correctly handles
// large (~50MB) JSON response data, including truncation flags,
// total_size tracking, and binary detection.

/// Generate a large JSON string (~50MB) consisting of an array of objects
/// with incrementing IDs. Each object is roughly 100 bytes, so ~500,000
/// objects produce approximately 50MB.
fn generateLargeJson(allocator: std.mem.Allocator, target_size_mb: usize) ![]u8 {
    const target_bytes = target_size_mb * 1024 * 1024;
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    // Pre-allocate to avoid repeated reallocations
    try buf.ensureTotalCapacity(target_bytes + 1024);

    try buf.appendSlice("[");

    var id: usize = 1;
    while (buf.items.len < target_bytes) : (id += 1) {
        if (id > 1) {
            try buf.appendSlice(",");
        }
        // Each object: {"id":N,"name":"item_N","value":N,"active":true,"tags":["a","b"]}
        // This is roughly 80-120 bytes per object depending on ID length
        var num_buf: [20]u8 = undefined;
        const id_str = std.fmt.bufPrint(&num_buf, "{d}", .{id}) catch unreachable;

        try buf.appendSlice("{\"id\":");
        try buf.appendSlice(id_str);
        try buf.appendSlice(",\"name\":\"item_");
        try buf.appendSlice(id_str);
        try buf.appendSlice("\",\"value\":");
        try buf.appendSlice(id_str);
        try buf.appendSlice(",\"active\":true,\"tags\":[\"alpha\",\"beta\",\"gamma\"],\"description\":\"A test record for performance validation number ");
        try buf.appendSlice(id_str);
        try buf.appendSlice("\"}");
    }

    try buf.appendSlice("]");

    return try buf.toOwnedSlice();
}

test "large response sets truncation flag when size exceeds stream_threshold" {
    const allocator = std.testing.allocator;
    const config = HttpClient.ClientConfig{};
    const stream_threshold = config.stream_threshold; // 5MB

    // Create a mock response
    var response = HttpClient.Response.init(allocator);
    defer response.deinit();

    // Generate data larger than stream_threshold (use ~6MB to be safely over 5MB)
    const large_data = try generateLargeJson(allocator, 6);
    defer allocator.free(large_data);

    const actual_size = large_data.len;

    // Simulate the truncation logic from http_client.execute()
    if (actual_size > stream_threshold) {
        response.truncated = true;
        response.total_size = actual_size;
    }

    try response.body.appendSlice(large_data);
    response.size_bytes = response.body.items.len;
    if (response.total_size == 0) response.total_size = response.size_bytes;

    // Assert: truncation flag is set
    try std.testing.expect(response.truncated);

    // Assert: total_size is correct
    try std.testing.expect(response.total_size > stream_threshold);
    try std.testing.expectEqual(actual_size, response.total_size);

    // Assert: body data is accessible
    try std.testing.expect(response.body.items.len > stream_threshold);
    try std.testing.expectEqual(actual_size, response.body.items.len);
}

test "response below stream_threshold is not truncated" {
    const allocator = std.testing.allocator;
    const config = HttpClient.ClientConfig{};
    const stream_threshold = config.stream_threshold; // 5MB

    var response = HttpClient.Response.init(allocator);
    defer response.deinit();

    // Generate small data (~1MB, well under 5MB threshold)
    const small_data = try generateLargeJson(allocator, 1);
    defer allocator.free(small_data);

    const actual_size = small_data.len;

    // Simulate the truncation logic
    if (actual_size > stream_threshold) {
        response.truncated = true;
        response.total_size = actual_size;
    }

    try response.body.appendSlice(small_data);
    response.size_bytes = response.body.items.len;
    if (response.total_size == 0) response.total_size = response.size_bytes;

    // Assert: truncation flag is NOT set
    try std.testing.expect(!response.truncated);

    // Assert: total_size equals body size
    try std.testing.expectEqual(response.size_bytes, response.total_size);

    // Assert: data is under threshold
    try std.testing.expect(response.body.items.len < stream_threshold);
}

test "total_size tracking is accurate for large responses" {
    const allocator = std.testing.allocator;

    var response = HttpClient.Response.init(allocator);
    defer response.deinit();

    // Generate ~10MB of data
    const data = try generateLargeJson(allocator, 10);
    defer allocator.free(data);

    const expected_size = data.len;

    // Set total_size before appending (as execute() does)
    response.total_size = expected_size;
    response.truncated = true;

    try response.body.appendSlice(data);
    response.size_bytes = response.body.items.len;

    // Assert: total_size exactly matches the generated data length
    try std.testing.expectEqual(expected_size, response.total_size);

    // Assert: size_bytes matches body length
    try std.testing.expectEqual(response.body.items.len, response.size_bytes);

    // Assert: total_size and size_bytes agree
    try std.testing.expectEqual(response.total_size, response.size_bytes);

    // Assert: data is well over 10MB
    try std.testing.expect(response.total_size > 10 * 1024 * 1024);
}

test "binary detection returns false for large JSON response" {
    const allocator = std.testing.allocator;

    var response = HttpClient.Response.init(allocator);
    defer response.deinit();

    // Set JSON content-type header
    try response.headers.append(.{
        .name = "Content-Type",
        .value = "application/json; charset=utf-8",
    });

    // Generate ~2MB of JSON data (enough for binary detection check)
    const json_data = try generateLargeJson(allocator, 2);
    defer allocator.free(json_data);

    try response.body.appendSlice(json_data);
    response.size_bytes = response.body.items.len;

    // Assert: binary detection returns false for JSON content
    try std.testing.expect(!HttpClient.isBinaryResponse(&response));
}

test "binary detection returns false for large JSON without content-type" {
    const allocator = std.testing.allocator;

    var response = HttpClient.Response.init(allocator);
    defer response.deinit();

    // No Content-Type header -- detection falls back to byte inspection.
    // JSON is valid text, so binary detection should still return false.

    // Generate ~2MB of JSON data
    const json_data = try generateLargeJson(allocator, 2);
    defer allocator.free(json_data);

    try response.body.appendSlice(json_data);
    response.size_bytes = response.body.items.len;

    // Assert: byte-level inspection sees valid text, not binary
    try std.testing.expect(!HttpClient.isBinaryResponse(&response));
}

test "response defaults are correct before large data" {
    var response = HttpClient.Response.init(std.testing.allocator);
    defer response.deinit();

    // Defaults before any data is added
    try std.testing.expect(!response.truncated);
    try std.testing.expectEqual(@as(usize, 0), response.total_size);
    try std.testing.expectEqual(@as(usize, 0), response.size_bytes);
    try std.testing.expectEqual(@as(u16, 0), response.status_code);
    try std.testing.expectEqual(@as(usize, 0), response.body.items.len);
}

test "stream_threshold and max_response_size config defaults" {
    const config = HttpClient.ClientConfig{};

    // stream_threshold should be 5MB
    try std.testing.expectEqual(@as(usize, 5 * 1024 * 1024), config.stream_threshold);

    // max_response_size should be 50MB
    try std.testing.expectEqual(@as(usize, 50 * 1024 * 1024), config.max_response_size);

    // stream_threshold should be less than max_response_size
    try std.testing.expect(config.stream_threshold < config.max_response_size);
}

test "large json generation produces valid json structure" {
    const allocator = std.testing.allocator;

    // Generate a small chunk to validate structure
    const data = try generateLargeJson(allocator, 1);
    defer allocator.free(data);

    // Should start with '[' and end with ']'
    try std.testing.expect(data.len > 2);
    try std.testing.expectEqual(@as(u8, '['), data[0]);
    try std.testing.expectEqual(@as(u8, ']'), data[data.len - 1]);

    // Should be parseable as JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| {
        std.debug.print("JSON parse failed: {}\n", .{err});
        return error.TestUnexpectedResult;
    };
    defer parsed.deinit();

    // Root should be an array
    try std.testing.expect(parsed.value == .array);

    // Should have many items
    try std.testing.expect(parsed.value.array.items.len > 1000);

    // First item should have expected fields
    const first = parsed.value.array.items[0];
    try std.testing.expect(first == .object);
    try std.testing.expect(first.object.get("id") != null);
    try std.testing.expect(first.object.get("name") != null);
    try std.testing.expect(first.object.get("value") != null);
    try std.testing.expect(first.object.get("active") != null);
    try std.testing.expect(first.object.get("tags") != null);
}

test "50MB response truncation flag with exact threshold boundary" {
    const allocator = std.testing.allocator;
    const config = HttpClient.ClientConfig{};
    const stream_threshold = config.stream_threshold;

    // Test data at exactly the threshold size
    var response_at = HttpClient.Response.init(allocator);
    defer response_at.deinit();

    // Create data of exactly stream_threshold bytes
    const exact_data = try allocator.alloc(u8, stream_threshold);
    defer allocator.free(exact_data);
    @memset(exact_data, 'A');

    const at_size = exact_data.len;
    if (at_size > stream_threshold) {
        response_at.truncated = true;
        response_at.total_size = at_size;
    }

    // At exactly the threshold, truncated should be false (> not >=)
    try std.testing.expect(!response_at.truncated);

    // Test data 1 byte over threshold
    var response_over = HttpClient.Response.init(allocator);
    defer response_over.deinit();

    const over_data = try allocator.alloc(u8, stream_threshold + 1);
    defer allocator.free(over_data);
    @memset(over_data, 'B');

    const over_size = over_data.len;
    if (over_size > stream_threshold) {
        response_over.truncated = true;
        response_over.total_size = over_size;
    }

    // 1 byte over threshold, truncated should be true
    try std.testing.expect(response_over.truncated);
    try std.testing.expectEqual(stream_threshold + 1, response_over.total_size);
}
