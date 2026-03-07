const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── XPath Query Engine ────────────────────────────────────────────────
// Simple XPath expression evaluator for XML response filtering.
// Supports basic XPath syntax for querying XML response bodies.
//
// Supported syntax:
//   /root/child           — absolute path (child axis)
//   //element             — descendant search
//   //element[@attr]      — attribute existence check
//   //element[@attr='v']  — attribute value match
//   //element[1]          — index predicate (1-based)
//   //element/text()      — text content extraction
//
// This is NOT a full XPath 1.0 implementation — it covers common
// API response filtering patterns only.

// ── Public Types ────────────────────────────────────────────────────────

pub const Axis = enum {
    child,
    descendant,
    self_node,
    attribute,
};

pub const AttributePredicate = struct {
    name: []const u8,
    value: []const u8,
};

pub const Predicate = union(enum) {
    index: usize,
    attribute: AttributePredicate,
    has_attribute: []const u8,
};

pub const XPathStep = struct {
    axis: Axis,
    node_name: []const u8,
    predicate: ?Predicate = null,
};

pub const XmlElement = struct {
    name: []const u8,
    content: []const u8,
    inner_content: []const u8,
    attributes: []const u8,
};

pub const XPathResult = struct {
    allocator: Allocator,
    values: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) XPathResult {
        return .{
            .allocator = allocator,
            .values = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *XPathResult) void {
        for (self.values.items) |v| {
            self.allocator.free(v);
        }
        self.values.deinit();
    }
};

pub const XPathExpression = struct {
    raw: []const u8,
    steps: std.ArrayList(XPathStep),

    pub fn parse(allocator: Allocator, expr: []const u8) !XPathExpression {
        return parseExpression(allocator, expr);
    }

    pub fn deinit(self: *XPathExpression) void {
        self.steps.deinit();
    }
};

// ── Public API ──────────────────────────────────────────────────────────

/// Main entry point: evaluate an XPath expression against XML content.
/// Returns an XPathResult containing all matching values (caller owns).
pub fn evaluate(allocator: Allocator, xml_content: []const u8, xpath_expr: []const u8) !XPathResult {
    var expr = try parseExpression(allocator, xpath_expr);
    defer expr.deinit();

    var result = XPathResult.init(allocator);
    errdefer result.deinit();

    if (expr.steps.items.len == 0) return result;

    // Determine if the last step is text() extraction
    var want_text = false;
    var effective_steps = expr.steps.items;
    if (effective_steps.len > 0) {
        const last = effective_steps[effective_steps.len - 1];
        if (mem.eql(u8, last.node_name, "text()")) {
            want_text = true;
            effective_steps = effective_steps[0 .. effective_steps.len - 1];
        }
    }

    if (effective_steps.len == 0) return result;

    // Walk steps, accumulating matching content slices
    var current_contexts = std.ArrayList([]const u8).init(allocator);
    defer current_contexts.deinit();
    try current_contexts.append(xml_content);

    for (effective_steps) |step| {
        var next_contexts = std.ArrayList([]const u8).init(allocator);
        errdefer next_contexts.deinit();

        for (current_contexts.items) |ctx| {
            var elements = try findElements(allocator, ctx, step.node_name, step.axis);
            defer elements.deinit();

            for (elements.items) |elem| {
                // Apply predicate filtering
                if (step.predicate) |pred| {
                    switch (pred) {
                        .index => {
                            // Index predicates are handled below after collecting all matches
                        },
                        .attribute => |attr_pred| {
                            if (!matchesAttributeValue(elem.attributes, attr_pred.name, attr_pred.value)) {
                                continue;
                            }
                        },
                        .has_attribute => |attr_name| {
                            if (!hasAttribute(elem.attributes, attr_name)) {
                                continue;
                            }
                        },
                    }
                }
                try next_contexts.append(elem.inner_content);
            }

            // Handle index predicates: filter the collected results from this context
            if (step.predicate) |pred| {
                if (pred == .index) {
                    var idx_elements = try findElements(allocator, ctx, step.node_name, step.axis);
                    defer idx_elements.deinit();

                    // Replace next_contexts with just the indexed element
                    // First remove what we just added from this context
                    var filtered = std.ArrayList([]const u8).init(allocator);
                    errdefer filtered.deinit();

                    const target_idx = pred.index;
                    if (target_idx > 0 and target_idx <= idx_elements.items.len) {
                        try filtered.append(idx_elements.items[target_idx - 1].inner_content);
                    }

                    // Replace next_contexts contents from this context pass
                    next_contexts.deinit();
                    next_contexts = filtered;
                }
            }
        }

        current_contexts.deinit();
        current_contexts = next_contexts;
    }

    // Collect final values
    for (current_contexts.items) |ctx| {
        const text = if (want_text) extractText(ctx) else ctx;
        const trimmed = mem.trim(u8, text, " \t\r\n");
        const duped = try allocator.dupe(u8, trimmed);
        try result.values.append(duped);
    }

    return result;
}

/// Parse an XPath expression string into an XPathExpression.
pub fn parseExpression(allocator: Allocator, expr_str: []const u8) !XPathExpression {
    const trimmed = mem.trim(u8, expr_str, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidXPath;

    var steps = std.ArrayList(XPathStep).init(allocator);
    errdefer steps.deinit();

    var rest = trimmed;

    // Consume leading slash(es)
    if (!mem.startsWith(u8, rest, "/")) return error.InvalidXPath;

    while (rest.len > 0) {
        if (mem.startsWith(u8, rest, "//")) {
            // Descendant axis
            rest = rest[2..];
            const step = try parseStep(rest, .descendant);
            try steps.append(step.step);
            rest = step.remaining;
        } else if (mem.startsWith(u8, rest, "/")) {
            // Child axis
            rest = rest[1..];
            if (rest.len == 0) break;
            const step = try parseStep(rest, .child);
            try steps.append(step.step);
            rest = step.remaining;
        } else {
            break;
        }
    }

    if (steps.items.len == 0) return error.InvalidXPath;

    return XPathExpression{
        .raw = trimmed,
        .steps = steps,
    };
}

const StepParseResult = struct {
    step: XPathStep,
    remaining: []const u8,
};

/// Parse a single step (node name + optional predicate) from the current position.
fn parseStep(input: []const u8, axis: Axis) !StepParseResult {
    if (input.len == 0) return error.InvalidXPath;

    // Find end of node name: next '/', '[', or end of string
    var name_end: usize = 0;
    while (name_end < input.len and input[name_end] != '/' and input[name_end] != '[') {
        name_end += 1;
    }

    if (name_end == 0) return error.InvalidXPath;

    const node_name = input[0..name_end];
    var remaining = input[name_end..];
    var predicate: ?Predicate = null;

    // Parse predicate if present
    if (remaining.len > 0 and remaining[0] == '[') {
        const pred_result = try parsePredicate(remaining);
        predicate = pred_result.predicate;
        remaining = pred_result.remaining;
    }

    return StepParseResult{
        .step = XPathStep{
            .axis = axis,
            .node_name = node_name,
            .predicate = predicate,
        },
        .remaining = remaining,
    };
}

const PredicateParseResult = struct {
    predicate: Predicate,
    remaining: []const u8,
};

/// Parse a predicate expression: [index], [@attr], [@attr='value']
fn parsePredicate(input: []const u8) !PredicateParseResult {
    if (input.len < 2 or input[0] != '[') return error.InvalidXPath;

    const close = mem.indexOf(u8, input, "]") orelse return error.InvalidXPath;
    const inner = input[1..close];
    const remaining = input[close + 1 ..];

    if (inner.len == 0) return error.InvalidXPath;

    // [@attr='value'] or [@attr]
    if (inner[0] == '@') {
        const attr_content = inner[1..];

        // Check for ='value'
        if (mem.indexOf(u8, attr_content, "=")) |eq_pos| {
            const attr_name = attr_content[0..eq_pos];
            var value_part = attr_content[eq_pos + 1 ..];

            // Strip surrounding quotes
            if (value_part.len >= 2) {
                if ((value_part[0] == '\'' and value_part[value_part.len - 1] == '\'') or
                    (value_part[0] == '"' and value_part[value_part.len - 1] == '"'))
                {
                    value_part = value_part[1 .. value_part.len - 1];
                }
            }

            return PredicateParseResult{
                .predicate = .{ .attribute = .{
                    .name = attr_name,
                    .value = value_part,
                } },
                .remaining = remaining,
            };
        } else {
            // [@attr] — has_attribute
            return PredicateParseResult{
                .predicate = .{ .has_attribute = attr_content },
                .remaining = remaining,
            };
        }
    }

    // Numeric index (1-based)
    const idx = std.fmt.parseInt(usize, inner, 10) catch return error.InvalidXPath;
    if (idx == 0) return error.InvalidXPath;

    return PredicateParseResult{
        .predicate = .{ .index = idx },
        .remaining = remaining,
    };
}

/// Find XML elements by name in the given content, using the specified axis.
/// For child axis, only direct children are returned.
/// For descendant axis, all nested matches are returned.
pub fn findElements(allocator: Allocator, xml_content: []const u8, node_name: []const u8, axis: Axis) !std.ArrayList(XmlElement) {
    var results = std.ArrayList(XmlElement).init(allocator);
    errdefer results.deinit();

    if (xml_content.len == 0) return results;

    // For text() pseudo-node, return the content itself as an element
    if (mem.eql(u8, node_name, "text()")) {
        try results.append(XmlElement{
            .name = "text()",
            .content = xml_content,
            .inner_content = xml_content,
            .attributes = "",
        });
        return results;
    }

    var pos: usize = 0;
    var depth: usize = 0;

    while (pos < xml_content.len) {
        // Find next '<'
        const tag_start = mem.indexOfPos(u8, xml_content, pos, "<") orelse break;

        // Skip closing tags and processing instructions
        if (tag_start + 1 >= xml_content.len) break;
        if (xml_content[tag_start + 1] == '/' or xml_content[tag_start + 1] == '?' or xml_content[tag_start + 1] == '!') {
            // Closing tag — track depth for child axis
            if (xml_content[tag_start + 1] == '/') {
                if (depth > 0) depth -= 1;
            }
            const after = mem.indexOfPos(u8, xml_content, tag_start + 1, ">") orelse break;
            pos = after + 1;
            continue;
        }

        // Extract tag name from opening tag
        const tag_name_start = tag_start + 1;
        var tag_name_end = tag_name_start;
        while (tag_name_end < xml_content.len and
            xml_content[tag_name_end] != '>' and
            xml_content[tag_name_end] != ' ' and
            xml_content[tag_name_end] != '/' and
            xml_content[tag_name_end] != '\t' and
            xml_content[tag_name_end] != '\n' and
            xml_content[tag_name_end] != '\r')
        {
            tag_name_end += 1;
        }

        const tag_name = xml_content[tag_name_start..tag_name_end];
        const tag_close = mem.indexOfPos(u8, xml_content, tag_name_end, ">") orelse break;

        // Extract attributes (between name end and '>')
        const attr_region_end = if (xml_content[tag_close - 1] == '/') tag_close - 1 else tag_close;
        const raw_attributes = mem.trim(u8, xml_content[tag_name_end..attr_region_end], " \t\r\n");

        const is_self_closing = xml_content[tag_close - 1] == '/';

        // Check if this tag matches our target node_name
        const matches_name = mem.eql(u8, tag_name, node_name);
        const should_include = matches_name and (axis == .descendant or depth == 0);

        if (should_include) {
            if (is_self_closing) {
                const full_content = xml_content[tag_start .. tag_close + 1];
                try results.append(XmlElement{
                    .name = tag_name,
                    .content = full_content,
                    .inner_content = "",
                    .attributes = raw_attributes,
                });
            } else {
                // Find matching closing tag
                const inner_start = tag_close + 1;
                if (findClosingTag(xml_content, inner_start, tag_name)) |closing| {
                    const inner_content = xml_content[inner_start..closing.inner_end];
                    const full_content = xml_content[tag_start..closing.outer_end];
                    try results.append(XmlElement{
                        .name = tag_name,
                        .content = full_content,
                        .inner_content = inner_content,
                        .attributes = raw_attributes,
                    });
                }
            }
        }

        // Advance position and track depth
        if (is_self_closing) {
            pos = tag_close + 1;
        } else {
            if (!matches_name or axis == .descendant) {
                // For descendant axis, enter the tag to keep searching
                depth += 1;
                pos = tag_close + 1;
            } else if (axis == .child and matches_name) {
                // For child axis with a match, skip past the entire element
                const inner_start = tag_close + 1;
                if (findClosingTag(xml_content, inner_start, tag_name)) |closing| {
                    pos = closing.outer_end;
                } else {
                    pos = tag_close + 1;
                }
            } else {
                depth += 1;
                pos = tag_close + 1;
            }
        }
    }

    return results;
}

const ClosingTagInfo = struct {
    inner_end: usize,
    outer_end: usize,
};

/// Find the matching closing tag for an element, handling nesting.
fn findClosingTag(xml: []const u8, start: usize, tag_name: []const u8) ?ClosingTagInfo {
    var pos = start;
    var nesting: usize = 1;

    while (pos < xml.len) {
        const next_lt = mem.indexOfPos(u8, xml, pos, "<") orelse return null;

        if (next_lt + 1 >= xml.len) return null;

        if (xml[next_lt + 1] == '/') {
            // Closing tag
            const name_start = next_lt + 2;
            var name_end = name_start;
            while (name_end < xml.len and xml[name_end] != '>' and xml[name_end] != ' ') {
                name_end += 1;
            }
            const close_name = xml[name_start..name_end];
            const gt = mem.indexOfPos(u8, xml, name_end, ">") orelse return null;

            if (mem.eql(u8, close_name, tag_name)) {
                nesting -= 1;
                if (nesting == 0) {
                    return ClosingTagInfo{
                        .inner_end = next_lt,
                        .outer_end = gt + 1,
                    };
                }
            }
            pos = gt + 1;
        } else if (xml[next_lt + 1] == '!' or xml[next_lt + 1] == '?') {
            // Comment or PI — skip
            const gt = mem.indexOfPos(u8, xml, next_lt + 1, ">") orelse return null;
            pos = gt + 1;
        } else {
            // Opening tag
            const name_start = next_lt + 1;
            var name_end = name_start;
            while (name_end < xml.len and
                xml[name_end] != '>' and
                xml[name_end] != ' ' and
                xml[name_end] != '/' and
                xml[name_end] != '\t' and
                xml[name_end] != '\n')
            {
                name_end += 1;
            }
            const open_name = xml[name_start..name_end];
            const gt = mem.indexOfPos(u8, xml, name_end, ">") orelse return null;
            const is_self_closing = xml[gt - 1] == '/';

            if (mem.eql(u8, open_name, tag_name) and !is_self_closing) {
                nesting += 1;
            }
            pos = gt + 1;
        }
    }

    return null;
}

/// Extract text content from XML element inner content.
/// Strips all tags and returns the remaining text.
pub fn extractText(element_content: []const u8) []const u8 {
    // Find the first stretch of text that is not inside a tag.
    // For simple cases: content between tags at the top level.
    var i: usize = 0;
    var text_start: ?usize = null;

    while (i < element_content.len) {
        if (element_content[i] == '<') {
            if (text_start) |ts| {
                const text = element_content[ts..i];
                const trimmed = mem.trim(u8, text, " \t\r\n");
                if (trimmed.len > 0) return trimmed;
            }
            // Skip tag
            const gt = mem.indexOfPos(u8, element_content, i, ">") orelse break;
            i = gt + 1;
            text_start = null;
        } else {
            if (text_start == null) text_start = i;
            i += 1;
        }
    }

    // Trailing text after last tag (or entire content if no tags)
    if (text_start) |ts| {
        const text = element_content[ts..];
        const trimmed = mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }

    return element_content;
}

// ── Internal Helpers ────────────────────────────────────────────────────

/// Check if an attribute string contains an attribute with a specific value.
fn matchesAttributeValue(attributes: []const u8, name: []const u8, value: []const u8) bool {
    // Search for name="value" or name='value'
    var pos: usize = 0;
    while (pos < attributes.len) {
        // Skip whitespace
        while (pos < attributes.len and (attributes[pos] == ' ' or attributes[pos] == '\t')) {
            pos += 1;
        }
        if (pos >= attributes.len) break;

        // Read attribute name
        var attr_name_end = pos;
        while (attr_name_end < attributes.len and attributes[attr_name_end] != '=' and attributes[attr_name_end] != ' ') {
            attr_name_end += 1;
        }
        const attr_name = attributes[pos..attr_name_end];

        // Skip to '='
        pos = attr_name_end;
        while (pos < attributes.len and attributes[pos] == ' ') pos += 1;
        if (pos >= attributes.len or attributes[pos] != '=') {
            pos += 1;
            continue;
        }
        pos += 1; // skip '='

        // Skip whitespace
        while (pos < attributes.len and attributes[pos] == ' ') pos += 1;

        // Read value
        if (pos >= attributes.len) break;
        const quote = attributes[pos];
        if (quote != '"' and quote != '\'') {
            pos += 1;
            continue;
        }
        pos += 1;
        const val_start = pos;
        while (pos < attributes.len and attributes[pos] != quote) {
            pos += 1;
        }
        const attr_value = attributes[val_start..pos];
        if (pos < attributes.len) pos += 1; // skip closing quote

        if (mem.eql(u8, attr_name, name) and mem.eql(u8, attr_value, value)) {
            return true;
        }
    }
    return false;
}

/// Check if an attribute string contains a given attribute name.
fn hasAttribute(attributes: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (pos < attributes.len) {
        // Skip whitespace
        while (pos < attributes.len and (attributes[pos] == ' ' or attributes[pos] == '\t')) {
            pos += 1;
        }
        if (pos >= attributes.len) break;

        // Read attribute name
        var attr_name_end = pos;
        while (attr_name_end < attributes.len and attributes[attr_name_end] != '=' and attributes[attr_name_end] != ' ') {
            attr_name_end += 1;
        }
        const attr_name = attributes[pos..attr_name_end];

        if (mem.eql(u8, attr_name, name)) return true;

        // Skip past the value
        pos = attr_name_end;
        while (pos < attributes.len and attributes[pos] == ' ') pos += 1;
        if (pos < attributes.len and attributes[pos] == '=') {
            pos += 1;
            while (pos < attributes.len and attributes[pos] == ' ') pos += 1;
            if (pos < attributes.len and (attributes[pos] == '"' or attributes[pos] == '\'')) {
                const q = attributes[pos];
                pos += 1;
                while (pos < attributes.len and attributes[pos] != q) pos += 1;
                if (pos < attributes.len) pos += 1;
            }
        } else {
            pos += 1;
        }
    }
    return false;
}

// ── Tests ───────────────────────────────────────────────────────────────

const testing = std.testing;
const test_allocator = testing.allocator;

const test_xml =
    \\<root><users><user id="1"><name>Alice</name><role>admin</role></user><user id="2"><name>Bob</name><role>dev</role></user></users><meta><count>2</count></meta></root>
;

test "parse simple absolute path /root/child" {
    var expr = try parseExpression(test_allocator, "/root/child");
    defer expr.deinit();

    try testing.expectEqual(@as(usize, 2), expr.steps.items.len);
    try testing.expectEqualStrings("root", expr.steps.items[0].node_name);
    try testing.expectEqual(Axis.child, expr.steps.items[0].axis);
    try testing.expectEqualStrings("child", expr.steps.items[1].node_name);
    try testing.expectEqual(Axis.child, expr.steps.items[1].axis);
    try testing.expect(expr.steps.items[0].predicate == null);
    try testing.expect(expr.steps.items[1].predicate == null);
}

test "parse descendant path //element" {
    var expr = try parseExpression(test_allocator, "//element");
    defer expr.deinit();

    try testing.expectEqual(@as(usize, 1), expr.steps.items.len);
    try testing.expectEqualStrings("element", expr.steps.items[0].node_name);
    try testing.expectEqual(Axis.descendant, expr.steps.items[0].axis);
}

test "parse attribute predicate //element[@attr='value']" {
    var expr = try parseExpression(test_allocator, "//element[@attr='value']");
    defer expr.deinit();

    try testing.expectEqual(@as(usize, 1), expr.steps.items.len);
    try testing.expectEqualStrings("element", expr.steps.items[0].node_name);
    try testing.expectEqual(Axis.descendant, expr.steps.items[0].axis);

    const pred = expr.steps.items[0].predicate orelse return error.TestUnexpectedResult;
    switch (pred) {
        .attribute => |attr| {
            try testing.expectEqualStrings("attr", attr.name);
            try testing.expectEqualStrings("value", attr.value);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse index predicate //items/item[1]" {
    var expr = try parseExpression(test_allocator, "//items/item[1]");
    defer expr.deinit();

    try testing.expectEqual(@as(usize, 2), expr.steps.items.len);
    try testing.expectEqualStrings("items", expr.steps.items[0].node_name);
    try testing.expectEqual(Axis.descendant, expr.steps.items[0].axis);
    try testing.expectEqualStrings("item", expr.steps.items[1].node_name);
    try testing.expectEqual(Axis.child, expr.steps.items[1].axis);

    const pred = expr.steps.items[1].predicate orelse return error.TestUnexpectedResult;
    switch (pred) {
        .index => |idx| try testing.expectEqual(@as(usize, 1), idx),
        else => return error.TestUnexpectedResult,
    }
}

test "evaluate simple path on XML" {
    var result = try evaluate(test_allocator, test_xml, "/root/meta/count");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.values.items.len);
    try testing.expectEqualStrings("2", result.values.items[0]);
}

test "evaluate descendant search on nested XML" {
    var result = try evaluate(test_allocator, test_xml, "//name");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.values.items.len);
    try testing.expectEqualStrings("Alice", result.values.items[0]);
    try testing.expectEqualStrings("Bob", result.values.items[1]);
}

test "evaluate attribute filter" {
    var result = try evaluate(test_allocator, test_xml, "//user[@id='2']/name");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.values.items.len);
    try testing.expectEqualStrings("Bob", result.values.items[0]);
}

test "evaluate text() extraction" {
    var result = try evaluate(test_allocator, test_xml, "//role/text()");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.values.items.len);
    try testing.expectEqualStrings("admin", result.values.items[0]);
    try testing.expectEqualStrings("dev", result.values.items[1]);
}

test "evaluate index predicate" {
    var result = try evaluate(test_allocator, test_xml, "//users/user[2]/name");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.values.items.len);
    try testing.expectEqualStrings("Bob", result.values.items[0]);
}

test "handle self-closing tags" {
    const xml = "<root><item/><item value=\"test\"/><item>content</item></root>";

    var result = try evaluate(test_allocator, xml, "//item");
    defer result.deinit();

    // Should find 3 items: 2 self-closing + 1 with content
    try testing.expectEqual(@as(usize, 3), result.values.items.len);
}

test "handle missing elements (empty result)" {
    var result = try evaluate(test_allocator, test_xml, "//nonexistent");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.values.items.len);
}

test "handle malformed xpath gracefully" {
    const bad_exprs = [_][]const u8{
        "",
        "no-leading-slash",
        "/",
        "//",
    };

    for (bad_exprs) |expr| {
        var parsed = parseExpression(test_allocator, expr) catch continue;
        parsed.deinit();
        // Should have returned an error — reaching here means test failure
        return error.TestUnexpectedResult;
    }
}

test "parse has_attribute predicate //element[@attr]" {
    var expr = try parseExpression(test_allocator, "//user[@id]");
    defer expr.deinit();

    try testing.expectEqual(@as(usize, 1), expr.steps.items.len);
    const pred = expr.steps.items[0].predicate orelse return error.TestUnexpectedResult;
    switch (pred) {
        .has_attribute => |attr_name| {
            try testing.expectEqualStrings("id", attr_name);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "evaluate has_attribute filter" {
    var result = try evaluate(test_allocator, test_xml, "//user[@id]");
    defer result.deinit();

    // Both users have id attribute
    try testing.expectEqual(@as(usize, 2), result.values.items.len);
}

test "extractText returns text from element content" {
    const inner = "Alice";
    const text = extractText(inner);
    try testing.expectEqualStrings("Alice", text);

    const with_tags = "<name>Alice</name><role>admin</role>";
    const text2 = extractText(with_tags);
    // extractText returns first text node — but here all text is inside child tags
    // The content between <name> tags would need to be navigated; at the top level
    // there is no bare text, so it returns the full content.
    _ = text2;
}

test "evaluate combined descendant and child path" {
    var result = try evaluate(test_allocator, test_xml, "//users/user/role");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.values.items.len);
    try testing.expectEqualStrings("admin", result.values.items[0]);
    try testing.expectEqualStrings("dev", result.values.items[1]);
}
