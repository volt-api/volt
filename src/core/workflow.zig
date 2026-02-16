const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const HttpClient = @import("http_client.zig");
const Environment = @import("environment.zig");
const Scripting = @import("scripting.zig");

// ── Workflow Engine ────────────────────────────────────────────────────
// Multi-step API request chains with variable passing.
// Supports:
//   - Sequential execution of .volt files
//   - Variable extraction from responses (JSONPath-like)
//   - Conditional steps (only run if previous step passed)
//   - Delay between steps
//   - Shared environment across all steps

pub const ExtractRule = struct {
    variable: []const u8,
    source: []const u8, // "body.field", "header.name", "status"
};

pub const WorkflowStep = struct {
    name: []const u8 = "",
    file: []const u8,
    extract: std.ArrayList(ExtractRule),
    condition: ?[]const u8 = null,
    delay_ms: u32 = 0,

    pub fn init(allocator: Allocator, file: []const u8) WorkflowStep {
        return .{
            .file = file,
            .extract = std.ArrayList(ExtractRule).init(allocator),
        };
    }

    pub fn deinit(self: *WorkflowStep) void {
        self.extract.deinit();
    }
};

pub const StepResult = struct {
    step_name: []const u8,
    status_code: u16,
    timing_ms: f64,
    passed: bool,
    extracted_vars: std.StringHashMap([]const u8),
    error_message: ?[]const u8 = null,

    pub fn init(allocator: Allocator) StepResult {
        return .{
            .step_name = "",
            .status_code = 0,
            .timing_ms = 0,
            .passed = true,
            .extracted_vars = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *StepResult) void {
        self.extracted_vars.deinit();
    }
};

pub const WorkflowResult = struct {
    steps: std.ArrayList(StepResult),
    total_time_ms: f64,
    all_passed: bool,
    variables: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) WorkflowResult {
        return .{
            .steps = std.ArrayList(StepResult).init(allocator),
            .total_time_ms = 0,
            .all_passed = true,
            .variables = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *WorkflowResult) void {
        for (self.steps.items) |*s| {
            s.deinit();
        }
        self.steps.deinit();
        self.variables.deinit();
    }
};

pub const Workflow = struct {
    name: []const u8,
    steps: std.ArrayList(WorkflowStep),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Workflow {
        return .{
            .name = "",
            .steps = std.ArrayList(WorkflowStep).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Workflow) void {
        for (self.steps.items) |*s| {
            s.deinit();
        }
        self.steps.deinit();
    }
};

// ── Workflow Parser ────────────────────────────────────────────────────

/// Parse a .volt-workflow file format:
/// ```
/// name: Login and Get Profile
///
/// steps:
///   - file: 01-login.volt
///     extract:
///       token: body.token
///       user_id: body.user.id
///
///   - file: 02-get-profile.volt
///     delay: 100
///
///   - file: 03-update-profile.volt
///     condition: status == 200
/// ```
pub fn parseWorkflow(allocator: Allocator, content: []const u8) !Workflow {
    var workflow = Workflow.init(allocator);
    errdefer workflow.deinit();

    var in_steps = false;
    var in_extract = false;
    var current_step: ?*WorkflowStep = null;

    var lines = mem.splitSequence(u8, content, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trimRight(u8, raw_line, "\r");
        const trimmed = mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Top-level name
        if (mem.startsWith(u8, trimmed, "name:")) {
            const val = mem.trim(u8, trimmed["name:".len..], " \t");
            if (val.len > 0) {
                workflow.name = val;
            }
            continue;
        }

        // Steps section
        if (mem.eql(u8, trimmed, "steps:")) {
            in_steps = true;
            in_extract = false;
            continue;
        }

        if (!in_steps) continue;

        // New step: "- file: ..."
        if (mem.startsWith(u8, trimmed, "- file:")) {
            in_extract = false;
            const file_val = mem.trim(u8, trimmed["- file:".len..], " \t");
            if (file_val.len > 0) {
                try workflow.steps.append(WorkflowStep.init(allocator, file_val));
                current_step = &workflow.steps.items[workflow.steps.items.len - 1];
            }
            continue;
        }

        // Step properties (must have a current step)
        if (current_step) |step| {
            if (mem.startsWith(u8, trimmed, "name:")) {
                const val = mem.trim(u8, trimmed["name:".len..], " \t");
                if (val.len > 0) step.name = val;
                in_extract = false;
            } else if (mem.startsWith(u8, trimmed, "delay:")) {
                const val = mem.trim(u8, trimmed["delay:".len..], " \t");
                step.delay_ms = std.fmt.parseInt(u32, val, 10) catch 0;
                in_extract = false;
            } else if (mem.startsWith(u8, trimmed, "condition:")) {
                const val = mem.trim(u8, trimmed["condition:".len..], " \t");
                if (val.len > 0) step.condition = val;
                in_extract = false;
            } else if (mem.eql(u8, trimmed, "extract:")) {
                in_extract = true;
            } else if (in_extract) {
                // Parse "variable: source"
                if (mem.indexOf(u8, trimmed, ": ")) |colon_pos| {
                    const variable = trimmed[0..colon_pos];
                    const source = trimmed[colon_pos + 2 ..];
                    try step.extract.append(.{
                        .variable = variable,
                        .source = source,
                    });
                }
            }
        }
    }

    return workflow;
}

// ── Workflow Execution ─────────────────────────────────────────────────

/// Extract a value from a response based on a source specifier.
/// Supports: "body.field.path", "header.HeaderName", "status"
fn extractFromResponse(
    response: *const HttpClient.Response,
    source: []const u8,
    status_buf: *[16]u8,
) ?[]const u8 {
    if (mem.eql(u8, source, "status")) {
        const s = std.fmt.bufPrint(status_buf, "{d}", .{response.status_code}) catch return null;
        return s;
    }
    if (mem.startsWith(u8, source, "header.")) {
        const header_name = source["header.".len..];
        return response.getHeader(header_name);
    }
    if (mem.startsWith(u8, source, "body.")) {
        const json_path = source["body.".len..];
        return extractJsonField(response.bodySlice(), json_path);
    }
    if (mem.eql(u8, source, "body")) {
        return response.bodySlice();
    }
    return null;
}

/// Simple JSON field extraction (handles "data.user.name" style paths)
fn extractJsonField(json: []const u8, path: []const u8) ?[]const u8 {
    var current_key = path;
    var remaining_path: ?[]const u8 = null;

    if (mem.indexOf(u8, path, ".")) |dot_pos| {
        current_key = path[0..dot_pos];
        remaining_path = path[dot_pos + 1 ..];
    }

    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{current_key}) catch return null;
    const key_pos = mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = json[key_pos + search_key.len ..];

    var value_start: usize = 0;
    while (value_start < after_key.len and (after_key[value_start] == ':' or after_key[value_start] == ' ')) {
        value_start += 1;
    }
    if (value_start >= after_key.len) return null;

    const value_data = after_key[value_start..];

    if (remaining_path) |rp| {
        return extractJsonField(value_data, rp);
    }

    // Extract the value
    if (value_data[0] == '"') {
        if (mem.indexOf(u8, value_data[1..], "\"")) |end| {
            return value_data[1 .. end + 1];
        }
    } else {
        // Number, boolean, null
        var end: usize = 0;
        while (end < value_data.len and value_data[end] != ',' and value_data[end] != '}' and value_data[end] != ']' and value_data[end] != '\n') {
            end += 1;
        }
        return mem.trim(u8, value_data[0..end], " \t\r\n");
    }

    return null;
}

/// Check a condition against the previous step result.
/// Condition format: "status == 200", "status < 400"
fn checkCondition(condition: []const u8, prev_result: *const StepResult) bool {
    var parts = mem.splitSequence(u8, condition, " ");
    const field = parts.next() orelse return false;
    const op = parts.next() orelse return false;
    const expected = parts.rest();

    if (mem.eql(u8, field, "status")) {
        const expected_code = std.fmt.parseInt(u16, expected, 10) catch return false;
        if (mem.eql(u8, op, "==") or mem.eql(u8, op, "equals")) return prev_result.status_code == expected_code;
        if (mem.eql(u8, op, "!=")) return prev_result.status_code != expected_code;
        if (mem.eql(u8, op, "<")) return prev_result.status_code < expected_code;
        if (mem.eql(u8, op, ">")) return prev_result.status_code > expected_code;
        if (mem.eql(u8, op, "<=")) return prev_result.status_code <= expected_code;
        if (mem.eql(u8, op, ">=")) return prev_result.status_code >= expected_code;
    }

    if (mem.eql(u8, field, "passed")) {
        if (mem.eql(u8, expected, "true")) return prev_result.passed;
        if (mem.eql(u8, expected, "false")) return !prev_result.passed;
    }

    return false;
}

/// Execute a workflow: run each step in sequence, passing variables between steps.
pub fn runWorkflow(
    allocator: Allocator,
    workflow: *const Workflow,
    env_mgr: *Environment.EnvManager,
) !WorkflowResult {
    var result = WorkflowResult.init(allocator);
    errdefer result.deinit();

    const start_time = std.time.nanoTimestamp();

    for (workflow.steps.items) |step| {
        var step_result = StepResult.init(allocator);
        step_result.step_name = if (step.name.len > 0) step.name else step.file;

        // Check condition against previous step
        if (step.condition) |condition| {
            if (result.steps.items.len > 0) {
                const prev = &result.steps.items[result.steps.items.len - 1];
                if (!checkCondition(condition, prev)) {
                    step_result.passed = false;
                    step_result.error_message = "Condition not met, skipped";
                    try result.steps.append(step_result);
                    continue;
                }
            }
        }

        // Delay if requested
        if (step.delay_ms > 0) {
            std.time.sleep(@as(u64, step.delay_ms) * 1_000_000);
        }

        // Load and parse the .volt file
        const file = std.fs.cwd().openFile(step.file, .{}) catch {
            step_result.passed = false;
            step_result.error_message = "Could not open file";
            result.all_passed = false;
            try result.steps.append(step_result);
            continue;
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            step_result.passed = false;
            step_result.error_message = "Could not read file";
            result.all_passed = false;
            try result.steps.append(step_result);
            continue;
        };
        defer allocator.free(content);

        var request = VoltFile.parse(allocator, content) catch {
            step_result.passed = false;
            step_result.error_message = "Parse error";
            result.all_passed = false;
            try result.steps.append(step_result);
            continue;
        };
        defer request.deinit();

        // Interpolate URL with environment + accumulated workflow variables
        const resolved_url = env_mgr.interpolate(request.url, &result.variables, allocator) catch null;
        defer if (resolved_url) |ru| allocator.free(ru);
        if (resolved_url) |ru| request.url = ru;

        // Interpolate body too
        if (request.body) |body| {
            const resolved_body = env_mgr.interpolate(body, &result.variables, allocator) catch null;
            if (resolved_body) |rb| {
                if (request.body_owned) {
                    if (request.body) |b| allocator.free(b);
                }
                request.body = rb;
                request.body_owned = true;
            }
        }

        // Execute HTTP request
        const step_start = std.time.nanoTimestamp();
        var response = HttpClient.execute(allocator, &request, .{}) catch {
            step_result.passed = false;
            step_result.error_message = "Connection failed";
            result.all_passed = false;
            try result.steps.append(step_result);
            continue;
        };
        defer response.deinit();

        const step_end = std.time.nanoTimestamp();
        step_result.timing_ms = @as(f64, @floatFromInt(step_end - step_start)) / 1_000_000.0;
        step_result.status_code = response.status_code;

        // Check if status indicates success
        if (response.status_code >= 400) {
            step_result.passed = false;
            result.all_passed = false;
        }

        // Extract variables from response
        for (step.extract.items) |rule| {
            var status_buf: [16]u8 = undefined;
            if (extractFromResponse(&response, rule.source, &status_buf)) |value| {
                try step_result.extracted_vars.put(rule.variable, value);
                try result.variables.put(rule.variable, value);
            }
        }

        try result.steps.append(step_result);
    }

    const end_time = std.time.nanoTimestamp();
    result.total_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    return result;
}

// ── Formatting ─────────────────────────────────────────────────────────

/// Format workflow result for display
pub fn formatResult(result: *const WorkflowResult, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    const writer = buf.writer();

    try writer.writeAll("\x1b[1m--- Workflow Results ---\x1b[0m\n\n");

    for (result.steps.items, 0..) |step, i| {
        const status_icon: []const u8 = if (step.passed) "\x1b[32mPASS\x1b[0m" else "\x1b[31mFAIL\x1b[0m";
        try writer.print("  Step {d}: {s} [{s}]\n", .{ i + 1, step.step_name, status_icon });

        if (step.status_code > 0) {
            const status_color: []const u8 = if (step.status_code < 300) "\x1b[32m" else if (step.status_code < 400) "\x1b[33m" else "\x1b[31m";
            try writer.print("    Status: {s}{d}\x1b[0m | Time: {d:.1}ms\n", .{ status_color, step.status_code, step.timing_ms });
        }

        if (step.error_message) |err| {
            try writer.print("    Error: \x1b[31m{s}\x1b[0m\n", .{err});
        }

        // Show extracted variables
        var var_it = step.extracted_vars.iterator();
        var has_vars = false;
        while (var_it.next()) |entry| {
            if (!has_vars) {
                try writer.writeAll("    Extracted:\n");
                has_vars = true;
            }
            try writer.print("      {s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try writer.writeAll("\n");
    }

    // Summary
    var passed: usize = 0;
    var failed: usize = 0;
    for (result.steps.items) |step| {
        if (step.passed) {
            passed += 1;
        } else {
            failed += 1;
        }
    }

    try writer.writeAll("\x1b[1m--- Summary ---\x1b[0m\n");
    try writer.print("  Steps:    {d} total, \x1b[32m{d} passed\x1b[0m, \x1b[31m{d} failed\x1b[0m\n", .{
        result.steps.items.len,
        passed,
        failed,
    });
    try writer.print("  Duration: {d:.1}ms\n", .{result.total_time_ms});

    if (result.variables.count() > 0) {
        try writer.writeAll("  Variables:\n");
        var it = result.variables.iterator();
        while (it.next()) |entry| {
            try writer.print("    {s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "parse workflow file" {
    const content =
        \\name: Login and Get Profile
        \\
        \\steps:
        \\  - file: 01-login.volt
        \\    extract:
        \\      token: body.token
        \\      user_id: body.user.id
        \\
        \\  - file: 02-get-profile.volt
        \\    delay: 100
        \\
        \\  - file: 03-update-profile.volt
        \\    condition: status == 200
    ;

    var workflow = try parseWorkflow(std.testing.allocator, content);
    defer workflow.deinit();

    try std.testing.expectEqualStrings("Login and Get Profile", workflow.name);
    try std.testing.expectEqual(@as(usize, 3), workflow.steps.items.len);

    // Step 1: login with extract rules
    try std.testing.expectEqualStrings("01-login.volt", workflow.steps.items[0].file);
    try std.testing.expectEqual(@as(usize, 2), workflow.steps.items[0].extract.items.len);
    try std.testing.expectEqualStrings("token", workflow.steps.items[0].extract.items[0].variable);
    try std.testing.expectEqualStrings("body.token", workflow.steps.items[0].extract.items[0].source);
    try std.testing.expectEqualStrings("user_id", workflow.steps.items[0].extract.items[1].variable);
    try std.testing.expectEqualStrings("body.user.id", workflow.steps.items[0].extract.items[1].source);

    // Step 2: delay
    try std.testing.expectEqualStrings("02-get-profile.volt", workflow.steps.items[1].file);
    try std.testing.expectEqual(@as(u32, 100), workflow.steps.items[1].delay_ms);

    // Step 3: condition
    try std.testing.expectEqualStrings("03-update-profile.volt", workflow.steps.items[2].file);
    try std.testing.expectEqualStrings("status == 200", workflow.steps.items[2].condition.?);
}

test "check condition" {
    var step_result = StepResult.init(std.testing.allocator);
    defer step_result.deinit();
    step_result.status_code = 200;
    step_result.passed = true;

    try std.testing.expect(checkCondition("status == 200", &step_result));
    try std.testing.expect(!checkCondition("status == 404", &step_result));
    try std.testing.expect(checkCondition("status < 400", &step_result));
    try std.testing.expect(!checkCondition("status > 300", &step_result));
    try std.testing.expect(checkCondition("passed == true", &step_result));
}

test "extract json field" {
    const json = "{\"token\": \"abc123\", \"user\": {\"id\": \"42\", \"name\": \"John\"}}";

    try std.testing.expectEqualStrings("abc123", extractJsonField(json, "token").?);
    try std.testing.expectEqualStrings("42", extractJsonField(json, "user.id").?);
    try std.testing.expectEqualStrings("John", extractJsonField(json, "user.name").?);
    try std.testing.expect(extractJsonField(json, "nonexistent") == null);
}
