const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Data-Driven Test Driver ─────────────────────────────────────────────
// CSV and JSON data file reader for parameterized/data-driven testing.
// Reads external data files and returns rows of key-value pairs that can
// be used as variable substitutions when running the same .volt file
// multiple times with different input data.

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const DataRow = struct {
    fields: std.ArrayList(Field),

    pub fn init(allocator: Allocator) DataRow {
        return .{
            .fields = std.ArrayList(Field).init(allocator),
        };
    }

    pub fn deinit(self: *DataRow) void {
        self.fields.deinit();
    }

    /// Look up a field value by name. Returns null if the field is not found.
    pub fn get(self: *const DataRow, name: []const u8) ?[]const u8 {
        for (self.fields.items) |field| {
            if (mem.eql(u8, field.name, name)) {
                return field.value;
            }
        }
        return null;
    }
};

pub const DataSet = struct {
    rows: std.ArrayList(DataRow),
    column_names: std.ArrayList([]const u8),
    /// Tracks heap-allocated strings that this DataSet owns and must free.
    owned_strings: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) DataSet {
        return .{
            .rows = std.ArrayList(DataRow).init(allocator),
            .column_names = std.ArrayList([]const u8).init(allocator),
            .owned_strings = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DataSet) void {
        for (self.rows.items) |*row| {
            row.deinit();
        }
        self.rows.deinit();
        self.column_names.deinit();
        // Free all owned string allocations
        for (self.owned_strings.items) |s| {
            self.allocator.free(s);
        }
        self.owned_strings.deinit();
    }

    pub fn rowCount(self: *const DataSet) usize {
        return self.rows.items.len;
    }
};

/// Parse CSV content with a header row into a DataSet.
/// The first line defines column names (split on commas).
/// Subsequent lines are data rows. Supports quoted fields
/// (double-quote-wrapped fields that may contain commas).
pub fn parseCSV(allocator: Allocator, content: []const u8) !DataSet {
    var dataset = DataSet.init(allocator);
    errdefer dataset.deinit();

    // Split into lines
    var lines = std.ArrayList([]const u8).init(allocator);
    defer lines.deinit();

    var line_iter = mem.splitSequence(u8, content, "\n");
    while (line_iter.next()) |raw_line| {
        // Strip trailing \r for Windows line endings
        const line = mem.trimRight(u8, raw_line, "\r");
        // Skip empty lines
        if (mem.trim(u8, line, " \t").len == 0) continue;
        try lines.append(line);
    }

    if (lines.items.len == 0) return dataset;

    // Parse header row
    var header_fields = try parseCSVLine(allocator, lines.items[0]);
    defer header_fields.deinit();

    for (header_fields.items) |hf| {
        const duped_key = try allocator.dupe(u8, mem.trim(u8, hf, " \t"));
        try dataset.owned_strings.append(duped_key);
        try dataset.column_names.append(duped_key);
    }

    // Parse data rows
    for (lines.items[1..]) |line| {
        var value_fields = try parseCSVLine(allocator, line);
        defer value_fields.deinit();

        var row = DataRow.init(allocator);
        errdefer row.deinit();

        for (dataset.column_names.items, 0..) |col_name, col_idx| {
            const raw_value = if (col_idx < value_fields.items.len)
                mem.trim(u8, value_fields.items[col_idx], " \t")
            else
                "";
            const duped_value = try allocator.dupe(u8, raw_value);
            try dataset.owned_strings.append(duped_value);
            try row.fields.append(.{
                .name = col_name,
                .value = duped_value,
            });
        }

        try dataset.rows.append(row);
    }

    return dataset;
}

/// Parse a single CSV line into a list of field values, handling quoted fields.
fn parseCSVLine(allocator: Allocator, line: []const u8) !std.ArrayList([]const u8) {
    var fields = std.ArrayList([]const u8).init(allocator);
    errdefer fields.deinit();

    var i: usize = 0;
    while (i <= line.len) {
        if (i == line.len) {
            // Trailing comma produced an empty field
            break;
        }

        if (line[i] == '"') {
            // Quoted field: find closing quote (skip escaped double-quotes "")
            i += 1; // skip opening quote
            const start = i;
            while (i < line.len) {
                if (line[i] == '"') {
                    // Check for escaped quote ""
                    if (i + 1 < line.len and line[i + 1] == '"') {
                        i += 2;
                        continue;
                    }
                    break;
                }
                i += 1;
            }
            const field_value = line[start..i];
            try fields.append(field_value);
            // Skip closing quote and comma
            if (i < line.len) i += 1; // closing quote
            if (i < line.len and line[i] == ',') i += 1; // comma
        } else {
            // Unquoted field: read until comma or end
            const start = i;
            while (i < line.len and line[i] != ',') {
                i += 1;
            }
            try fields.append(line[start..i]);
            if (i < line.len) i += 1; // skip comma
        }
    }

    return fields;
}

/// Parse JSON array content into a DataSet.
/// Expects a top-level JSON array where each element is an object
/// with string values. All strings are duplicated so the DataSet
/// owns its data independently of the JSON parser.
pub fn parseJSON(allocator: Allocator, content: []const u8) !DataSet {
    var dataset = DataSet.init(allocator);
    errdefer dataset.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return error.InvalidFormat;

    // Collect column names from the first object (duplicate strings)
    if (root.array.items.len > 0) {
        const first = root.array.items[0];
        if (first == .object) {
            var key_iter = first.object.iterator();
            while (key_iter.next()) |entry| {
                const duped_key = try allocator.dupe(u8, entry.key_ptr.*);
                try dataset.owned_strings.append(duped_key);
                try dataset.column_names.append(duped_key);
            }
        }
    }

    // Parse each array element as a row
    for (root.array.items) |item| {
        if (item != .object) continue;

        var row = DataRow.init(allocator);
        errdefer row.deinit();

        // Add columns that already exist in order
        for (dataset.column_names.items) |col_name| {
            const val = item.object.get(col_name);
            const raw_value = if (val) |v| jsonValueToStr(v) else "";
            // Duplicate the value string so it outlives the parsed JSON
            const duped_value = try allocator.dupe(u8, raw_value);
            try dataset.owned_strings.append(duped_value);
            try row.fields.append(.{
                .name = col_name,
                .value = duped_value,
            });
        }

        try dataset.rows.append(row);
    }

    return dataset;
}

/// Convert a std.json.Value to a string slice (for string values only;
/// other types return a static representation).
fn jsonValueToStr(value: std.json.Value) []const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => "0",
        .float => "0",
        .bool => |b| if (b) "true" else "false",
        .null => "",
        else => "",
    };
}

/// Load a data file from disk and auto-detect format based on file extension.
/// Supports .csv and .json extensions.
pub fn loadDataFile(allocator: Allocator, file_path: []const u8) !DataSet {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    // Auto-detect format from extension
    if (mem.endsWith(u8, file_path, ".json")) {
        return parseJSON(allocator, content);
    } else if (mem.endsWith(u8, file_path, ".csv")) {
        return parseCSV(allocator, content);
    }

    // Try to detect from content
    const trimmed = mem.trim(u8, content, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '[') {
        return parseJSON(allocator, content);
    }

    // Default to CSV
    return parseCSV(allocator, content);
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse CSV with headers" {
    const allocator = std.testing.allocator;

    const csv_content =
        \\username,email,expected_status
        \\john,john@example.com,200
        \\jane,jane@example.com,200
        \\missing,,400
    ;

    var dataset = try parseCSV(allocator, csv_content);
    defer dataset.deinit();

    // Verify column names
    try std.testing.expectEqual(@as(usize, 3), dataset.column_names.items.len);
    try std.testing.expectEqualStrings("username", dataset.column_names.items[0]);
    try std.testing.expectEqualStrings("email", dataset.column_names.items[1]);
    try std.testing.expectEqualStrings("expected_status", dataset.column_names.items[2]);

    // Verify row count
    try std.testing.expectEqual(@as(usize, 3), dataset.rowCount());

    // Verify first row values
    try std.testing.expectEqualStrings("john", dataset.rows.items[0].get("username").?);
    try std.testing.expectEqualStrings("john@example.com", dataset.rows.items[0].get("email").?);
    try std.testing.expectEqualStrings("200", dataset.rows.items[0].get("expected_status").?);

    // Verify second row values
    try std.testing.expectEqualStrings("jane", dataset.rows.items[1].get("username").?);

    // Verify row with empty field
    try std.testing.expectEqualStrings("missing", dataset.rows.items[2].get("username").?);
    try std.testing.expectEqualStrings("", dataset.rows.items[2].get("email").?);
    try std.testing.expectEqualStrings("400", dataset.rows.items[2].get("expected_status").?);
}

test "parse JSON array" {
    const allocator = std.testing.allocator;

    const json_content =
        \\[
        \\  {"username": "john", "email": "john@example.com", "expected_status": "200"},
        \\  {"username": "jane", "email": "jane@example.com", "expected_status": "200"}
        \\]
    ;

    var dataset = try parseJSON(allocator, json_content);
    defer dataset.deinit();

    // Verify column names extracted from first object
    try std.testing.expectEqual(@as(usize, 3), dataset.column_names.items.len);

    // Verify row count
    try std.testing.expectEqual(@as(usize, 2), dataset.rowCount());

    // Verify first row values
    try std.testing.expectEqualStrings("john", dataset.rows.items[0].get("username").?);
    try std.testing.expectEqualStrings("john@example.com", dataset.rows.items[0].get("email").?);
    try std.testing.expectEqualStrings("200", dataset.rows.items[0].get("expected_status").?);

    // Verify second row values
    try std.testing.expectEqualStrings("jane", dataset.rows.items[1].get("username").?);
    try std.testing.expectEqualStrings("jane@example.com", dataset.rows.items[1].get("email").?);
}

test "DataRow.get returns correct value" {
    const allocator = std.testing.allocator;

    var row = DataRow.init(allocator);
    defer row.deinit();

    try row.fields.append(.{ .name = "username", .value = "alice" });
    try row.fields.append(.{ .name = "email", .value = "alice@example.com" });
    try row.fields.append(.{ .name = "role", .value = "admin" });

    // Verify existing fields return correct values
    try std.testing.expectEqualStrings("alice", row.get("username").?);
    try std.testing.expectEqualStrings("alice@example.com", row.get("email").?);
    try std.testing.expectEqualStrings("admin", row.get("role").?);

    // Verify non-existent field returns null
    try std.testing.expect(row.get("nonexistent") == null);
}
