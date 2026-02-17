const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Response Visualization Module ────────────────────────────────────────
//
// Provides terminal-friendly rendering of HTTP response bodies:
//   - HTML to plain text conversion (lynx-style)
//   - XML syntax highlighting with ANSI colors
//   - Response timing waterfall charts
//   - Binary file type detection and reporting
//   - Orchestrated content formatting by type

// ── ANSI Color Constants ────────────────────────────────────────────────

const Ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const italic = "\x1b[3m";
    const dim = "\x1b[90m";
    const cyan = "\x1b[36m";
    const green = "\x1b[32m";
    const yellow = "\x1b[33m";
    const blue = "\x1b[34m";
    const magenta = "\x1b[35m";
    const red = "\x1b[31m";
};

// ── File Type Detection ─────────────────────────────────────────────────

pub const FileType = enum {
    json,
    xml,
    html,
    css,
    javascript,
    plain_text,
    png,
    jpeg,
    gif,
    webp,
    svg,
    pdf,
    zip,
    gzip,
    binary_unknown,

    pub fn toString(self: FileType) []const u8 {
        return switch (self) {
            .json => "JSON",
            .xml => "XML",
            .html => "HTML",
            .css => "CSS",
            .javascript => "JavaScript",
            .plain_text => "Plain Text",
            .png => "PNG Image",
            .jpeg => "JPEG Image",
            .gif => "GIF Image",
            .webp => "WebP Image",
            .svg => "SVG Image",
            .pdf => "PDF Document",
            .zip => "ZIP Archive",
            .gzip => "GZIP Archive",
            .binary_unknown => "Binary",
        };
    }

    pub fn emoji(self: FileType) []const u8 {
        return switch (self) {
            .json => "[JSON]",
            .xml => "[XML]",
            .html => "[HTML]",
            .css => "[CSS]",
            .javascript => "[JS]",
            .plain_text => "[TXT]",
            .png => "[PNG]",
            .jpeg => "[JPG]",
            .gif => "[GIF]",
            .webp => "[WEBP]",
            .svg => "[SVG]",
            .pdf => "[PDF]",
            .zip => "[ZIP]",
            .gzip => "[GZ]",
            .binary_unknown => "[BIN]",
        };
    }
};

/// Detect file type from Content-Type header and/or content bytes.
/// Content-Type header takes priority when provided.
pub fn detectFileType(content: []const u8, content_type: ?[]const u8) FileType {
    // Check Content-Type header first
    if (content_type) |ct| {
        const lower_ct = ct;
        if (containsInsensitive(lower_ct, "application/json")) return .json;
        if (containsInsensitive(lower_ct, "text/json")) return .json;
        if (containsInsensitive(lower_ct, "text/html")) return .html;
        if (containsInsensitive(lower_ct, "application/xhtml")) return .html;
        if (containsInsensitive(lower_ct, "text/xml")) return .xml;
        if (containsInsensitive(lower_ct, "application/xml")) return .xml;
        if (containsInsensitive(lower_ct, "text/css")) return .css;
        if (containsInsensitive(lower_ct, "application/javascript")) return .javascript;
        if (containsInsensitive(lower_ct, "text/javascript")) return .javascript;
        if (containsInsensitive(lower_ct, "image/png")) return .png;
        if (containsInsensitive(lower_ct, "image/jpeg")) return .jpeg;
        if (containsInsensitive(lower_ct, "image/gif")) return .gif;
        if (containsInsensitive(lower_ct, "image/webp")) return .webp;
        if (containsInsensitive(lower_ct, "image/svg+xml")) return .svg;
        if (containsInsensitive(lower_ct, "application/pdf")) return .pdf;
        if (containsInsensitive(lower_ct, "application/zip")) return .zip;
        if (containsInsensitive(lower_ct, "application/gzip")) return .gzip;
        if (containsInsensitive(lower_ct, "text/plain")) return .plain_text;
    }

    // Fall back to magic bytes / content sniffing
    if (content.len == 0) return .plain_text;

    // PNG: \x89PNG\r\n\x1a\n
    if (content.len >= 4 and content[0] == 0x89 and content[1] == 'P' and content[2] == 'N' and content[3] == 'G') return .png;
    // JPEG: \xFF\xD8\xFF
    if (content.len >= 3 and content[0] == 0xFF and content[1] == 0xD8 and content[2] == 0xFF) return .jpeg;
    // GIF: GIF87a or GIF89a
    if (content.len >= 6 and mem.eql(u8, content[0..3], "GIF") and (mem.eql(u8, content[3..6], "87a") or mem.eql(u8, content[3..6], "89a"))) return .gif;
    // PDF: %PDF
    if (content.len >= 4 and mem.eql(u8, content[0..4], "%PDF")) return .pdf;
    // ZIP: PK\x03\x04
    if (content.len >= 4 and content[0] == 'P' and content[1] == 'K' and content[2] == 0x03 and content[3] == 0x04) return .zip;
    // GZIP: \x1f\x8b
    if (content.len >= 2 and content[0] == 0x1F and content[1] == 0x8B) return .gzip;

    // Check for binary content (null bytes in first 512 chars)
    const check_len = @min(content.len, 512);
    for (content[0..check_len]) |byte| {
        if (byte == 0) return .binary_unknown;
    }

    // Text-based detection
    const trimmed = mem.trimLeft(u8, content, " \t\r\n");
    if (trimmed.len == 0) return .plain_text;

    // XML: starts with <?xml or < + letter
    if (trimmed.len >= 5 and mem.eql(u8, trimmed[0..5], "<?xml")) return .xml;

    // HTML: contains <html or <!doctype (case-insensitive)
    if (containsInsensitive(content, "<html") or containsInsensitive(content, "<!doctype")) return .html;

    // JSON: starts with { or [
    if (trimmed[0] == '{' or trimmed[0] == '[') return .json;

    // XML: starts with < + letter
    if (trimmed[0] == '<' and trimmed.len > 1 and std.ascii.isAlphabetic(trimmed[1])) return .xml;

    return .plain_text;
}

// ── Size Formatting ─────────────────────────────────────────────────────

pub const SizeInfo = struct {
    value: f64,
    unit: []const u8,
};

/// Format a byte size into human-readable units (bytes, KB, MB, GB).
pub fn formatSize(size: usize) SizeInfo {
    const size_f: f64 = @floatFromInt(size);
    if (size < 1024) {
        return .{ .value = size_f, .unit = "bytes" };
    } else if (size < 1024 * 1024) {
        return .{ .value = size_f / 1024.0, .unit = "KB" };
    } else if (size < 1024 * 1024 * 1024) {
        return .{ .value = size_f / (1024.0 * 1024.0), .unit = "MB" };
    } else {
        return .{ .value = size_f / (1024.0 * 1024.0 * 1024.0), .unit = "GB" };
    }
}

// ── Binary Info Formatting ──────────────────────────────────────────────

/// Format a summary for binary response content.
pub fn formatBinaryInfo(allocator: Allocator, file_type: FileType, size: usize) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    const si = formatSize(size);

    try writer.print("  {s} {s} {d:.1} {s}\n", .{
        file_type.emoji(),
        file_type.toString(),
        si.value,
        si.unit,
    });
    try writer.writeAll("  Binary content — use --output to save to file\n");

    return buf.toOwnedSlice();
}

// ── HTML to Text Conversion ─────────────────────────────────────────────

/// Convert HTML to readable plain text for terminal display.
/// Strips tags, converts structural elements to text equivalents,
/// and applies ANSI formatting for bold/italic/code.
pub fn htmlToText(allocator: Allocator, html: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '<') {
            // Parse the tag
            const tag_start = i;
            const tag_end = mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                // No closing >, treat as text
                try buf.append(html[i]);
                i += 1;
                continue;
            };

            const tag_content = html[tag_start + 1 .. tag_end];
            const tag_lower = try toLowerAlloc(allocator, tag_content);
            defer allocator.free(tag_lower);

            // Handle script and style blocks — remove entirely
            if (mem.startsWith(u8, tag_lower, "script") and !mem.startsWith(u8, tag_lower, "script/")) {
                const end_script = findClosingTag(html, tag_end + 1, "script");
                i = end_script;
                continue;
            }
            if (mem.startsWith(u8, tag_lower, "style") and !mem.startsWith(u8, tag_lower, "style/")) {
                const end_style = findClosingTag(html, tag_end + 1, "style");
                i = end_style;
                continue;
            }

            // Handle specific tags
            if (mem.eql(u8, tag_lower, "br") or mem.eql(u8, tag_lower, "br/") or mem.eql(u8, tag_lower, "br /")) {
                try buf.append('\n');
            } else if (mem.startsWith(u8, tag_lower, "p") and (tag_lower.len == 1 or tag_lower[1] == ' ')) {
                try buf.appendSlice("\n\n");
            } else if (mem.eql(u8, tag_lower, "/p")) {
                try buf.appendSlice("\n\n");
            } else if (isHeadingOpen(tag_lower)) {
                try buf.appendSlice("\n\n");
                // Collect text up to closing heading tag and uppercase it
                const heading_level = tag_lower[1];
                var close_tag_buf: [4]u8 = undefined;
                close_tag_buf[0] = '/';
                close_tag_buf[1] = 'h';
                close_tag_buf[2] = heading_level;
                const close_tag = close_tag_buf[0..3];
                const heading_text_end = findClosingTagPos(html, tag_end + 1, close_tag);
                const heading_text = html[tag_end + 1 .. heading_text_end];
                // Strip any inner tags from heading text
                const stripped = try stripTags(allocator, heading_text);
                defer allocator.free(stripped);
                // Convert to uppercase
                for (stripped) |ch| {
                    try buf.append(std.ascii.toUpper(ch));
                }
                try buf.append('\n');
                // Skip past the closing tag
                const after_close = mem.indexOfScalarPos(u8, html, heading_text_end, '>') orelse heading_text_end;
                i = after_close + 1;
                continue;
            } else if (mem.startsWith(u8, tag_lower, "li") and (tag_lower.len == 2 or tag_lower[2] == ' ')) {
                try buf.appendSlice("\n  - ");
            } else if (mem.eql(u8, tag_lower, "hr") or mem.eql(u8, tag_lower, "hr/") or mem.eql(u8, tag_lower, "hr /")) {
                try buf.appendSlice("\n" ++ "\u{2500}" ** 24 ++ "\n");
            } else if (mem.eql(u8, tag_lower, "strong") or mem.eql(u8, tag_lower, "b")) {
                try buf.appendSlice(Ansi.bold);
            } else if (mem.eql(u8, tag_lower, "/strong") or mem.eql(u8, tag_lower, "/b")) {
                try buf.appendSlice(Ansi.reset);
            } else if (mem.eql(u8, tag_lower, "em") or mem.eql(u8, tag_lower, "i")) {
                try buf.appendSlice(Ansi.italic);
            } else if (mem.eql(u8, tag_lower, "/em") or mem.eql(u8, tag_lower, "/i")) {
                try buf.appendSlice(Ansi.reset);
            } else if (mem.eql(u8, tag_lower, "code")) {
                try buf.appendSlice(Ansi.cyan);
            } else if (mem.eql(u8, tag_lower, "/code")) {
                try buf.appendSlice(Ansi.reset);
            } else if (mem.startsWith(u8, tag_lower, "a ")) {
                // Extract href
                if (extractHref(tag_content)) |href| {
                    // Collect link text up to </a>
                    const link_text_end = findClosingTagPos(html, tag_end + 1, "/a");
                    const link_text = html[tag_end + 1 .. link_text_end];
                    const stripped_link = try stripTags(allocator, link_text);
                    defer allocator.free(stripped_link);
                    try buf.appendSlice(stripped_link);
                    try buf.appendSlice(" [");
                    try buf.appendSlice(href);
                    try buf.append(']');
                    const after_close = mem.indexOfScalarPos(u8, html, link_text_end, '>') orelse link_text_end;
                    i = after_close + 1;
                    continue;
                }
                // No href found, just skip the tag
            }
            // All other tags are stripped silently

            i = tag_end + 1;
        } else if (html[i] == '&') {
            // Decode HTML entities
            const entity_end = mem.indexOfScalarPos(u8, html, i + 1, ';');
            if (entity_end) |end| {
                const entity = html[i .. end + 1];
                if (mem.eql(u8, entity, "&amp;")) {
                    try buf.append('&');
                } else if (mem.eql(u8, entity, "&lt;")) {
                    try buf.append('<');
                } else if (mem.eql(u8, entity, "&gt;")) {
                    try buf.append('>');
                } else if (mem.eql(u8, entity, "&quot;")) {
                    try buf.append('"');
                } else if (mem.eql(u8, entity, "&#39;")) {
                    try buf.append('\'');
                } else if (mem.eql(u8, entity, "&nbsp;")) {
                    try buf.append(' ');
                } else {
                    // Unknown entity, emit as-is
                    try buf.appendSlice(entity);
                }
                i = end + 1;
            } else {
                try buf.append('&');
                i += 1;
            }
        } else {
            try buf.append(html[i]);
            i += 1;
        }
    }

    // Post-processing: collapse multiple blank lines to max 2, trim trailing whitespace per line
    const raw = try buf.toOwnedSlice();
    defer allocator.free(raw);

    return postProcess(allocator, raw);
}

/// Post-process text: collapse blank lines and trim trailing whitespace per line.
fn postProcess(allocator: Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var lines = mem.splitSequence(u8, text, "\n");
    var blank_count: usize = 0;
    var first = true;

    while (lines.next()) |line| {
        const trimmed = mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0) {
            blank_count += 1;
            if (blank_count <= 2) {
                if (!first) try result.append('\n');
            }
        } else {
            blank_count = 0;
            if (!first) try result.append('\n');
            try result.appendSlice(trimmed);
        }
        first = false;
    }

    return result.toOwnedSlice();
}

// ── XML Syntax Highlighting ─────────────────────────────────────────────

/// Add ANSI color codes to XML content for terminal display.
pub fn highlightXml(allocator: Allocator, xml: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var i: usize = 0;
    while (i < xml.len) {
        if (i + 4 <= xml.len and mem.eql(u8, xml[i .. i + 4], "<!--")) {
            // Comment
            try buf.appendSlice(Ansi.dim);
            const end = findSubstring(xml, i + 4, "-->") orelse xml.len;
            const comment_end = if (end < xml.len) end + 3 else end;
            try buf.appendSlice(xml[i..comment_end]);
            try buf.appendSlice(Ansi.reset);
            i = comment_end;
        } else if (i + 9 <= xml.len and mem.eql(u8, xml[i .. i + 9], "<![CDATA[")) {
            // CDATA section
            try buf.appendSlice(Ansi.magenta);
            const end = findSubstring(xml, i + 9, "]]>") orelse xml.len;
            const cdata_end = if (end < xml.len) end + 3 else end;
            try buf.appendSlice(xml[i..cdata_end]);
            try buf.appendSlice(Ansi.reset);
            i = cdata_end;
        } else if (i + 2 <= xml.len and mem.eql(u8, xml[i .. i + 2], "<?")) {
            // Processing instruction
            try buf.appendSlice(Ansi.dim);
            const end = findSubstring(xml, i + 2, "?>") orelse xml.len;
            const pi_end = if (end < xml.len) end + 2 else end;
            try buf.appendSlice(xml[i..pi_end]);
            try buf.appendSlice(Ansi.reset);
            i = pi_end;
        } else if (xml[i] == '<') {
            // Tag — highlight tag name, attributes, etc.
            const tag_end = mem.indexOfScalarPos(u8, xml, i + 1, '>') orelse xml.len;
            const actual_end = if (tag_end < xml.len) tag_end + 1 else tag_end;
            const tag_slice = xml[i..actual_end];

            try highlightTag(allocator, &buf, tag_slice);
            i = actual_end;
        } else {
            // Text content — default color
            try buf.append(xml[i]);
            i += 1;
        }
    }

    return buf.toOwnedSlice();
}

/// Highlight a single XML tag with ANSI colors.
fn highlightTag(allocator: Allocator, buf: *std.ArrayList(u8), tag: []const u8) !void {
    _ = allocator;
    if (tag.len < 2) {
        try buf.appendSlice(tag);
        return;
    }

    // Find the end of the tag name
    var i: usize = 1; // skip '<'
    if (i < tag.len and tag[i] == '/') i += 1; // closing tag

    // Tag name
    const name_start = i;
    while (i < tag.len and tag[i] != ' ' and tag[i] != '\t' and tag[i] != '\n' and tag[i] != '/' and tag[i] != '>') : (i += 1) {}
    const name_end = i;

    // Emit colored tag opening: < or </
    try buf.appendSlice(Ansi.cyan);
    if (tag[1] == '/') {
        try buf.appendSlice("</");
    } else {
        try buf.appendSlice("<");
    }
    try buf.appendSlice(tag[name_start..name_end]);
    try buf.appendSlice(Ansi.reset);

    // Parse attributes
    while (i < tag.len and tag[i] != '>' and tag[i] != '/') {
        // Skip whitespace
        if (tag[i] == ' ' or tag[i] == '\t' or tag[i] == '\n' or tag[i] == '\r') {
            try buf.append(tag[i]);
            i += 1;
            continue;
        }

        // Attribute name
        const attr_start = i;
        while (i < tag.len and tag[i] != '=' and tag[i] != ' ' and tag[i] != '>' and tag[i] != '/') : (i += 1) {}
        if (i > attr_start) {
            try buf.appendSlice(Ansi.yellow);
            try buf.appendSlice(tag[attr_start..i]);
            try buf.appendSlice(Ansi.reset);
        }

        // Equals sign
        if (i < tag.len and tag[i] == '=') {
            try buf.append('=');
            i += 1;

            // Attribute value (quoted)
            if (i < tag.len and (tag[i] == '"' or tag[i] == '\'')) {
                const quote = tag[i];
                const val_start = i;
                i += 1;
                while (i < tag.len and tag[i] != quote) : (i += 1) {}
                if (i < tag.len) i += 1; // skip closing quote
                try buf.appendSlice(Ansi.green);
                try buf.appendSlice(tag[val_start..i]);
                try buf.appendSlice(Ansi.reset);
            }
        }
    }

    // Emit closing part of tag
    try buf.appendSlice(Ansi.cyan);
    if (i < tag.len and tag[i] == '/') {
        try buf.appendSlice("/");
        i += 1;
    }
    if (i < tag.len and tag[i] == '>') {
        try buf.appendSlice(">");
    }
    try buf.appendSlice(Ansi.reset);
}

// ── Response Timing Waterfall ───────────────────────────────────────────

pub const TimingPhase = struct {
    name: []const u8,
    duration_ms: f64,
    color: []const u8,
};

/// Build an ASCII timing waterfall chart for response phases.
pub fn buildTimingWaterfall(allocator: Allocator, dns_ms: f64, connect_ms: f64, tls_ms: f64, ttfb_ms: f64, transfer_ms: f64) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    const phases = [_]TimingPhase{
        .{ .name = "DNS", .duration_ms = dns_ms, .color = Ansi.cyan },
        .{ .name = "Connect", .duration_ms = connect_ms, .color = Ansi.yellow },
        .{ .name = "TLS", .duration_ms = tls_ms, .color = Ansi.magenta },
        .{ .name = "TTFB", .duration_ms = ttfb_ms, .color = Ansi.green },
        .{ .name = "Transfer", .duration_ms = transfer_ms, .color = Ansi.blue },
    };

    const total = dns_ms + connect_ms + tls_ms + ttfb_ms + transfer_ms;
    if (total <= 0) return buf.toOwnedSlice();

    const bar_width: usize = 20;

    // Find maximum label width for alignment
    var max_label: usize = 0;
    for (phases) |phase| {
        if (phase.duration_ms > 0 and phase.name.len > max_label) {
            max_label = phase.name.len;
        }
    }

    // Cumulative offset tracking
    var cumulative: f64 = 0;
    for (phases) |phase| {
        if (phase.duration_ms <= 0) continue;

        // Pad the label
        try writer.writeAll("  ");
        try writer.writeAll(phase.name);
        var pad: usize = 0;
        while (pad < max_label - phase.name.len + 1) : (pad += 1) {
            try writer.writeByte(' ');
        }

        // Calculate bar positions
        const offset_chars: usize = @intFromFloat(@round(cumulative / total * @as(f64, @floatFromInt(bar_width))));
        const fill_chars_raw: usize = @intFromFloat(@round(phase.duration_ms / total * @as(f64, @floatFromInt(bar_width))));
        const fill_chars = @max(fill_chars_raw, 1); // at least 1 filled char

        // Draw offset (empty space before bar)
        var oc: usize = 0;
        while (oc < offset_chars) : (oc += 1) {
            try writer.writeAll("\u{2591}");
        }

        // Draw filled bar
        try writer.writeAll(phase.color);
        var fc: usize = 0;
        while (fc < fill_chars and (offset_chars + fc) < bar_width) : (fc += 1) {
            try writer.writeAll("\u{2588}");
        }
        try writer.writeAll(Ansi.reset);

        // Draw remaining empty space
        var remaining = bar_width -| (offset_chars + fc);
        while (remaining > 0) : (remaining -= 1) {
            try writer.writeAll("\u{2591}");
        }

        // Duration label
        try writer.print("  {d:.0}ms\n", .{phase.duration_ms});
        cumulative += phase.duration_ms;
    }

    // Separator and total
    try writer.writeAll("  ");
    var sep: usize = 0;
    while (sep < max_label + 1 + bar_width + 8) : (sep += 1) {
        try writer.writeAll("\u{2500}");
    }
    try writer.writeByte('\n');

    try writer.writeAll("  Total");
    var total_pad: usize = 0;
    while (total_pad < max_label - "Total".len + 1) : (total_pad += 1) {
        try writer.writeByte(' ');
    }
    // Pad with spaces to align with duration column
    var space: usize = 0;
    while (space < bar_width) : (space += 1) {
        try writer.writeByte(' ');
    }
    try writer.print("  {d:.0}ms\n", .{total});

    return buf.toOwnedSlice();
}

// ── Response Content Formatter (Orchestrator) ───────────────────────────

/// Format response content for terminal display based on detected type.
/// Delegates to appropriate formatter: JSON pretty-print, XML highlighting,
/// HTML-to-text conversion, or binary info summary.
pub fn formatResponseContent(allocator: Allocator, body: []const u8, content_type: ?[]const u8, colorize: bool) ![]const u8 {
    const file_type = detectFileType(body, content_type);

    switch (file_type) {
        .json => {
            return simpleJsonIndent(allocator, body, colorize);
        },
        .xml => {
            if (colorize) {
                return highlightXml(allocator, body);
            } else {
                return allocator.dupe(u8, body);
            }
        },
        .html => {
            return htmlToText(allocator, body);
        },
        .png, .jpeg, .gif, .webp, .pdf, .zip, .gzip, .binary_unknown => {
            return formatBinaryInfo(allocator, file_type, body.len);
        },
        else => {
            // plain_text, css, javascript, svg — return as-is
            return allocator.dupe(u8, body);
        },
    }
}

/// Simple JSON indentation for the response viewer.
/// Provides basic pretty-printing with optional ANSI colors.
fn simpleJsonIndent(allocator: Allocator, input: []const u8, colorize: bool) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    const trimmed = mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) return buf.toOwnedSlice();

    var indent_level: usize = 0;
    var in_string = false;
    var escape_next = false;
    var i: usize = 0;

    while (i < trimmed.len) : (i += 1) {
        const c = trimmed[i];

        if (escape_next) {
            try buf.append(c);
            escape_next = false;
            continue;
        }
        if (c == '\\' and in_string) {
            try buf.append(c);
            escape_next = true;
            continue;
        }
        if (c == '"') {
            if (!in_string) {
                in_string = true;
                if (colorize) {
                    if (isJsonKeyAt(trimmed, i)) {
                        try buf.appendSlice(Ansi.cyan);
                    } else {
                        try buf.appendSlice(Ansi.green);
                    }
                }
            } else {
                in_string = false;
            }
            try buf.append('"');
            if (!in_string and colorize) try buf.appendSlice(Ansi.reset);
            continue;
        }
        if (in_string) {
            try buf.append(c);
            continue;
        }

        switch (c) {
            '{', '[' => {
                try buf.append(c);
                indent_level += 1;
                try buf.append('\n');
                try writeSpaces(&buf, indent_level * 2);
            },
            '}', ']' => {
                indent_level -|= 1;
                try buf.append('\n');
                try writeSpaces(&buf, indent_level * 2);
                try buf.append(c);
            },
            ',' => {
                try buf.appendSlice(",\n");
                try writeSpaces(&buf, indent_level * 2);
            },
            ':' => {
                try buf.appendSlice(": ");
            },
            ' ', '\t', '\n', '\r' => {},
            else => {
                try buf.append(c);
            },
        }
    }

    return buf.toOwnedSlice();
}

// ── Helper Functions ────────────────────────────────────────────────────

/// Case-insensitive substring search.
fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Allocate a lowercase copy of a string.
fn toLowerAlloc(allocator: Allocator, s: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, idx| {
        result[idx] = std.ascii.toLower(c);
    }
    return result;
}

/// Find the position right after a closing tag like </script>.
fn findClosingTag(html: []const u8, start: usize, tag_name: []const u8) usize {
    var i = start;
    while (i < html.len) {
        if (html[i] == '<' and i + 1 < html.len and html[i + 1] == '/') {
            const after_slash = i + 2;
            if (after_slash + tag_name.len <= html.len) {
                var match = true;
                for (tag_name, 0..) |tc, j| {
                    if (std.ascii.toLower(html[after_slash + j]) != std.ascii.toLower(tc)) {
                        match = false;
                        break;
                    }
                }
                if (match) {
                    const gt = mem.indexOfScalarPos(u8, html, after_slash + tag_name.len, '>');
                    return if (gt) |g| g + 1 else html.len;
                }
            }
        }
        i += 1;
    }
    return html.len;
}

/// Find the start position of a closing tag (before the '<').
fn findClosingTagPos(html: []const u8, start: usize, close_tag: []const u8) usize {
    var i = start;
    while (i < html.len) {
        if (html[i] == '<' and i + 1 < html.len) {
            const remaining = html[i + 1 ..];
            if (remaining.len >= close_tag.len) {
                var match = true;
                for (close_tag, 0..) |tc, j| {
                    if (std.ascii.toLower(remaining[j]) != std.ascii.toLower(tc)) {
                        match = false;
                        break;
                    }
                }
                if (match) return i;
            }
        }
        i += 1;
    }
    return html.len;
}

/// Check if a lowercase tag name is a heading open tag (h1..h6).
fn isHeadingOpen(tag: []const u8) bool {
    if (tag.len < 2) return false;
    if (tag[0] != 'h') return false;
    if (tag[1] < '1' or tag[1] > '6') return false;
    return tag.len == 2 or tag[2] == ' ';
}

/// Strip all HTML tags from a string, returning plain text.
fn stripTags(allocator: Allocator, html: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var in_tag = false;
    for (html) |c| {
        if (c == '<') {
            in_tag = true;
        } else if (c == '>') {
            in_tag = false;
        } else if (!in_tag) {
            try buf.append(c);
        }
    }

    return buf.toOwnedSlice();
}

/// Extract href value from an anchor tag's attribute content.
fn extractHref(tag_content: []const u8) ?[]const u8 {
    // Search for href=" or href='
    var i: usize = 0;
    while (i + 5 < tag_content.len) : (i += 1) {
        if (std.ascii.toLower(tag_content[i]) == 'h' and
            std.ascii.toLower(tag_content[i + 1]) == 'r' and
            std.ascii.toLower(tag_content[i + 2]) == 'e' and
            std.ascii.toLower(tag_content[i + 3]) == 'f' and
            tag_content[i + 4] == '=')
        {
            var start = i + 5;
            // Skip whitespace
            while (start < tag_content.len and (tag_content[start] == ' ' or tag_content[start] == '\t')) : (start += 1) {}
            if (start < tag_content.len and (tag_content[start] == '"' or tag_content[start] == '\'')) {
                const quote = tag_content[start];
                const url_start = start + 1;
                const url_end = mem.indexOfScalarPos(u8, tag_content, url_start, quote) orelse continue;
                return tag_content[url_start..url_end];
            }
        }
    }
    return null;
}

/// Find a substring starting from a given position. Returns the index of the start of the match.
fn findSubstring(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start;
    if (start + needle.len > haystack.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Check if the quote at position i is a JSON key (followed by ':').
fn isJsonKeyAt(json: []const u8, quote_pos: usize) bool {
    var i = quote_pos + 1;
    var escape = false;
    while (i < json.len) : (i += 1) {
        if (escape) {
            escape = false;
            continue;
        }
        if (json[i] == '\\') {
            escape = true;
            continue;
        }
        if (json[i] == '"') {
            var j = i + 1;
            while (j < json.len and (json[j] == ' ' or json[j] == '\t')) : (j += 1) {}
            return j < json.len and json[j] == ':';
        }
    }
    return false;
}

/// Write n spaces to the buffer.
fn writeSpaces(buf: *std.ArrayList(u8), count: usize) !void {
    var n = count;
    while (n > 0) : (n -= 1) {
        try buf.append(' ');
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "htmlToText basic tag stripping" {
    const html = "<div>Hello <span>World</span></div>";
    const result = try htmlToText(std.testing.allocator, html);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "Hello") != null);
    try std.testing.expect(mem.indexOf(u8, result, "World") != null);
    try std.testing.expect(mem.indexOf(u8, result, "<div>") == null);
    try std.testing.expect(mem.indexOf(u8, result, "<span>") == null);
}

test "htmlToText heading conversion" {
    const html = "<h1>Hello World</h1>";
    const result = try htmlToText(std.testing.allocator, html);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "HELLO WORLD") != null);
}

test "htmlToText link conversion" {
    const html = "<a href=\"https://example.com\">Click Here</a>";
    const result = try htmlToText(std.testing.allocator, html);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "Click Here") != null);
    try std.testing.expect(mem.indexOf(u8, result, "[https://example.com]") != null);
}

test "htmlToText list items" {
    const html = "<ul><li>First</li><li>Second</li></ul>";
    const result = try htmlToText(std.testing.allocator, html);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "  - First") != null);
    try std.testing.expect(mem.indexOf(u8, result, "  - Second") != null);
}

test "htmlToText entity decoding" {
    const html = "5 &gt; 3 &amp; 2 &lt; 4 &quot;hello&quot; &#39;world&#39;";
    const result = try htmlToText(std.testing.allocator, html);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "5 > 3 & 2 < 4 \"hello\" 'world'") != null);
}

test "htmlToText script and style removal" {
    const html = "<p>Before</p><script>var x = 1;</script><style>.foo { color: red; }</style><p>After</p>";
    const result = try htmlToText(std.testing.allocator, html);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "Before") != null);
    try std.testing.expect(mem.indexOf(u8, result, "After") != null);
    try std.testing.expect(mem.indexOf(u8, result, "var x") == null);
    try std.testing.expect(mem.indexOf(u8, result, ".foo") == null);
}

test "htmlToText bold and italic" {
    const html = "<strong>bold</strong> and <em>italic</em>";
    const result = try htmlToText(std.testing.allocator, html);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "\x1b[1m") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\x1b[3m") != null);
    try std.testing.expect(mem.indexOf(u8, result, "bold") != null);
    try std.testing.expect(mem.indexOf(u8, result, "italic") != null);
}

test "highlightXml tags get cyan" {
    const xml = "<root>text</root>";
    const result = try highlightXml(std.testing.allocator, xml);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, Ansi.cyan) != null);
    try std.testing.expect(mem.indexOf(u8, result, "root") != null);
    try std.testing.expect(mem.indexOf(u8, result, "text") != null);
}

test "highlightXml attributes get yellow" {
    const xml = "<item id=\"42\">data</item>";
    const result = try highlightXml(std.testing.allocator, xml);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, Ansi.yellow) != null);
    try std.testing.expect(mem.indexOf(u8, result, "id") != null);
}

test "highlightXml comments get dim" {
    const xml = "<!-- this is a comment --><root/>";
    const result = try highlightXml(std.testing.allocator, xml);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, Ansi.dim) != null);
    try std.testing.expect(mem.indexOf(u8, result, "this is a comment") != null);
}

test "highlightXml attribute values get green" {
    const xml = "<tag attr=\"value\"/>";
    const result = try highlightXml(std.testing.allocator, xml);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, Ansi.green) != null);
    try std.testing.expect(mem.indexOf(u8, result, "value") != null);
}

test "highlightXml CDATA gets magenta" {
    const xml = "<data><![CDATA[raw content]]></data>";
    const result = try highlightXml(std.testing.allocator, xml);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, Ansi.magenta) != null);
    try std.testing.expect(mem.indexOf(u8, result, "raw content") != null);
}

test "buildTimingWaterfall all phases shown" {
    const result = try buildTimingWaterfall(std.testing.allocator, 12, 23, 45, 89, 102);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "DNS") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Connect") != null);
    try std.testing.expect(mem.indexOf(u8, result, "TLS") != null);
    try std.testing.expect(mem.indexOf(u8, result, "TTFB") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Transfer") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Total") != null);
    try std.testing.expect(mem.indexOf(u8, result, "12ms") != null);
    try std.testing.expect(mem.indexOf(u8, result, "271ms") != null);
}

test "buildTimingWaterfall zero-duration phases skipped" {
    const result = try buildTimingWaterfall(std.testing.allocator, 0, 50, 0, 100, 25);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "DNS") == null);
    try std.testing.expect(mem.indexOf(u8, result, "Connect") != null);
    try std.testing.expect(mem.indexOf(u8, result, "TLS") == null);
    try std.testing.expect(mem.indexOf(u8, result, "TTFB") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Transfer") != null);
}

test "detectFileType JSON by content" {
    const json_content = "{\"key\": \"value\"}";
    const ft = detectFileType(json_content, null);
    try std.testing.expectEqual(FileType.json, ft);

    const json_array = "[1, 2, 3]";
    const ft2 = detectFileType(json_array, null);
    try std.testing.expectEqual(FileType.json, ft2);
}

test "detectFileType PNG by magic bytes" {
    const png_header = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
    const ft = detectFileType(&png_header, null);
    try std.testing.expectEqual(FileType.png, ft);
}

test "detectFileType Content-Type header takes priority" {
    // Content starts with { which would be JSON, but header says HTML
    const body = "{not really json}";
    const ft = detectFileType(body, "text/html; charset=utf-8");
    try std.testing.expectEqual(FileType.html, ft);
}

test "detectFileType JPEG by magic bytes" {
    const jpeg_header = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0 };
    const ft = detectFileType(&jpeg_header, null);
    try std.testing.expectEqual(FileType.jpeg, ft);
}

test "detectFileType binary with null bytes" {
    var binary_data: [100]u8 = undefined;
    @memset(&binary_data, 0x41);
    binary_data[10] = 0; // null byte
    const ft = detectFileType(&binary_data, null);
    try std.testing.expectEqual(FileType.binary_unknown, ft);
}

test "formatBinaryInfo output" {
    const result = try formatBinaryInfo(std.testing.allocator, .png, 46285);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "[PNG]") != null);
    try std.testing.expect(mem.indexOf(u8, result, "PNG Image") != null);
    try std.testing.expect(mem.indexOf(u8, result, "KB") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Binary content") != null);
}

test "formatSize bytes KB MB" {
    const bytes = formatSize(500);
    try std.testing.expectEqualStrings("bytes", bytes.unit);
    try std.testing.expectEqual(@as(f64, 500.0), bytes.value);

    const kb = formatSize(2048);
    try std.testing.expectEqualStrings("KB", kb.unit);
    try std.testing.expectEqual(@as(f64, 2.0), kb.value);

    const mb = formatSize(5 * 1024 * 1024);
    try std.testing.expectEqualStrings("MB", mb.unit);
    try std.testing.expectEqual(@as(f64, 5.0), mb.value);

    const gb = formatSize(2 * 1024 * 1024 * 1024);
    try std.testing.expectEqualStrings("GB", gb.unit);
    try std.testing.expectEqual(@as(f64, 2.0), gb.value);
}

test "formatResponseContent picks JSON path" {
    const json_body = "{\"name\":\"test\"}";
    const result = try formatResponseContent(std.testing.allocator, json_body, "application/json", false);
    defer std.testing.allocator.free(result);

    // Should be pretty-printed
    try std.testing.expect(mem.indexOf(u8, result, "\"name\"") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\"test\"") != null);
}

test "formatResponseContent picks HTML path" {
    const html_body = "<html><body><h1>Title</h1><p>Hello</p></body></html>";
    const result = try formatResponseContent(std.testing.allocator, html_body, "text/html", false);
    defer std.testing.allocator.free(result);

    // Should be converted to text
    try std.testing.expect(mem.indexOf(u8, result, "TITLE") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Hello") != null);
    try std.testing.expect(mem.indexOf(u8, result, "<html>") == null);
}

test "formatResponseContent picks binary path" {
    const png_data = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00 };
    const result = try formatResponseContent(std.testing.allocator, &png_data, "image/png", false);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "[PNG]") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Binary content") != null);
}

test "formatResponseContent XML with highlighting" {
    const xml_body = "<?xml version=\"1.0\"?><root><item>data</item></root>";
    const result = try formatResponseContent(std.testing.allocator, xml_body, "application/xml", true);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "root") != null);
    try std.testing.expect(mem.indexOf(u8, result, "data") != null);
    try std.testing.expect(mem.indexOf(u8, result, Ansi.cyan) != null);
}

test "FileType toString and emoji" {
    try std.testing.expectEqualStrings("JSON", FileType.json.toString());
    try std.testing.expectEqualStrings("[JSON]", FileType.json.emoji());
    try std.testing.expectEqualStrings("PNG Image", FileType.png.toString());
    try std.testing.expectEqualStrings("[PNG]", FileType.png.emoji());
    try std.testing.expectEqualStrings("Binary", FileType.binary_unknown.toString());
    try std.testing.expectEqualStrings("[BIN]", FileType.binary_unknown.emoji());
}

test "htmlToText br and hr conversion" {
    const html = "line1<br>line2<br/>line3<hr>after";
    const result = try htmlToText(std.testing.allocator, html);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "line1") != null);
    try std.testing.expect(mem.indexOf(u8, result, "line2") != null);
    try std.testing.expect(mem.indexOf(u8, result, "line3") != null);
    try std.testing.expect(mem.indexOf(u8, result, "\u{2500}") != null);
}

test "highlightXml processing instruction gets dim" {
    const xml = "<?xml version=\"1.0\"?><root/>";
    const result = try highlightXml(std.testing.allocator, xml);
    defer std.testing.allocator.free(result);

    // Processing instruction should have dim color
    try std.testing.expect(mem.indexOf(u8, result, Ansi.dim) != null);
    try std.testing.expect(mem.indexOf(u8, result, "xml") != null);
}
