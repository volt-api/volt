const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");

// ── Extended Code Snippet Generator ─────────────────────────────────────
// Generates HTTP request code in many programming languages.
// Extends the basic exporter with more languages including Ruby, PHP,
// C#, Rust, Java, Swift, Kotlin, Dart, R, HTTPie, wget, and PowerShell.

/// Escape double quotes and backslashes for embedding in a "..." string literal.
fn escapeForStringLiteral(allocator: Allocator, input: []const u8) ![]const u8 {
    var count: usize = 0;
    for (input) |c| {
        if (c == '"' or c == '\\') count += 1;
    }
    if (count == 0) return allocator.dupe(u8, input);

    var buf = try allocator.alloc(u8, input.len + count);
    var i: usize = 0;
    for (input) |c| {
        if (c == '\\' or c == '"') {
            buf[i] = '\\';
            i += 1;
        }
        buf[i] = c;
        i += 1;
    }
    return buf;
}

pub const Language = enum {
    ruby,
    php,
    csharp,
    rust,
    java,
    swift,
    kotlin,
    dart,
    r,
    httpie,
    wget,
    powershell,

    pub fn fromString(s: []const u8) ?Language {
        if (mem.eql(u8, s, "ruby")) return .ruby;
        if (mem.eql(u8, s, "php")) return .php;
        if (mem.eql(u8, s, "csharp") or mem.eql(u8, s, "c#")) return .csharp;
        if (mem.eql(u8, s, "rust")) return .rust;
        if (mem.eql(u8, s, "java")) return .java;
        if (mem.eql(u8, s, "swift")) return .swift;
        if (mem.eql(u8, s, "kotlin")) return .kotlin;
        if (mem.eql(u8, s, "dart")) return .dart;
        if (mem.eql(u8, s, "r")) return .r;
        if (mem.eql(u8, s, "httpie")) return .httpie;
        if (mem.eql(u8, s, "wget")) return .wget;
        if (mem.eql(u8, s, "powershell")) return .powershell;
        return null;
    }

    pub fn toString(self: Language) []const u8 {
        return switch (self) {
            .ruby => "ruby",
            .php => "php",
            .csharp => "csharp",
            .rust => "rust",
            .java => "java",
            .swift => "swift",
            .kotlin => "kotlin",
            .dart => "dart",
            .r => "r",
            .httpie => "httpie",
            .wget => "wget",
            .powershell => "powershell",
        };
    }
};

/// Generate a code snippet in the specified language
pub fn generateSnippet(allocator: Allocator, request: *const VoltFile.VoltRequest, lang: Language) ![]const u8 {
    return switch (lang) {
        .ruby => exportRuby(request, allocator),
        .php => exportPhp(request, allocator),
        .csharp => exportCSharp(request, allocator),
        .rust => exportRust(request, allocator),
        .java => exportJava(request, allocator),
        .swift => exportSwift(request, allocator),
        .kotlin => exportKotlin(request, allocator),
        .dart => exportDart(request, allocator),
        .r => exportR(request, allocator),
        .httpie => exportHttpie(request, allocator),
        .wget => exportWget(request, allocator),
        .powershell => exportPowerShell(request, allocator),
    };
}

/// Export as Ruby using Net::HTTP
pub fn exportRuby(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("require 'net/http'\n");
    try writer.writeAll("require 'uri'\n");
    try writer.writeAll("require 'json'\n\n");

    try writer.print("uri = URI.parse(\"{s}\")\n", .{request.url});
    try writer.writeAll("http = Net::HTTP.new(uri.host, uri.port)\n");
    try writer.writeAll("http.use_ssl = uri.scheme == 'https'\n\n");

    // Build request object
    const method_class = switch (request.method) {
        .GET => "Get",
        .POST => "Post",
        .PUT => "Put",
        .PATCH => "Patch",
        .DELETE => "Delete",
        .HEAD => "Head",
        .OPTIONS => "Options",
    };
    try writer.print("request = Net::HTTP::{s}.new(uri.request_uri)\n", .{method_class});

    // Headers
    for (request.headers.items) |h| {
        try writer.print("request[\"{s}\"] = \"{s}\"\n", .{ h.name, h.value });
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print("request[\"Authorization\"] = \"Bearer {s}\"\n", .{token});
            }
        },
        .basic => {
            if (request.auth.username) |user| {
                if (request.auth.password) |pass| {
                    try writer.print("request.basic_auth(\"{s}\", \"{s}\")\n", .{ user, pass });
                }
            }
        },
        .api_key => {
            if (request.auth.key_name) |name| {
                if (request.auth.key_value) |value| {
                    const location = request.auth.key_location orelse "header";
                    if (mem.eql(u8, location, "header")) {
                        try writer.print("request[\"{s}\"] = \"{s}\"\n", .{ name, value });
                    }
                }
            }
        },
        .digest => {},
        .aws, .hawk, .oauth_cc, .oauth_password, .oauth_implicit => {},
        .none => {},
    }

    // Body
    if (request.body) |body| {
        try writer.print("request.body = '{s}'\n", .{body});
    }

    try writer.writeAll("\nresponse = http.request(request)\n");
    try writer.writeAll("puts \"Status: #{response.code}\"\n");
    try writer.writeAll("puts response.body\n");

    return buf.toOwnedSlice();
}

/// Export as PHP using curl functions
pub fn exportPhp(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("<?php\n\n");
    try writer.writeAll("$ch = curl_init();\n\n");
    try writer.print("curl_setopt($ch, CURLOPT_URL, \"{s}\");\n", .{request.url});
    try writer.writeAll("curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);\n");

    // Method
    if (request.method != .GET) {
        try writer.print("curl_setopt($ch, CURLOPT_CUSTOMREQUEST, \"{s}\");\n", .{request.method.toString()});
    }

    // Headers
    if (request.headers.items.len > 0 or request.auth.type != .none) {
        try writer.writeAll("\n$headers = [\n");
        for (request.headers.items) |h| {
            try writer.print("    \"{s}: {s}\",\n", .{ h.name, h.value });
        }
        // Auth headers
        switch (request.auth.type) {
            .bearer => {
                if (request.auth.token) |token| {
                    try writer.print("    \"Authorization: Bearer {s}\",\n", .{token});
                }
            },
            .api_key => {
                if (request.auth.key_name) |name| {
                    if (request.auth.key_value) |value| {
                        const location = request.auth.key_location orelse "header";
                        if (mem.eql(u8, location, "header")) {
                            try writer.print("    \"{s}: {s}\",\n", .{ name, value });
                        }
                    }
                }
            },
            else => {},
        }
        try writer.writeAll("];\n");
        try writer.writeAll("curl_setopt($ch, CURLOPT_HTTPHEADER, $headers);\n");
    }

    // Basic auth
    if (request.auth.type == .basic) {
        if (request.auth.username) |user| {
            if (request.auth.password) |pass| {
                try writer.print("\ncurl_setopt($ch, CURLOPT_USERPWD, \"{s}:{s}\");\n", .{ user, pass });
            }
        }
    }

    // Body
    if (request.body) |body| {
        try writer.print("\ncurl_setopt($ch, CURLOPT_POSTFIELDS, '{s}');\n", .{body});
    }

    try writer.writeAll("\n$response = curl_exec($ch);\n");
    try writer.writeAll("$httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);\n");
    try writer.writeAll("curl_close($ch);\n\n");
    try writer.writeAll("echo \"Status: $httpCode\\n\";\n");
    try writer.writeAll("echo $response;\n");

    return buf.toOwnedSlice();
}

/// Export as C# using HttpClient
pub fn exportCSharp(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("using System;\n");
    try writer.writeAll("using System.Net.Http;\n");
    try writer.writeAll("using System.Text;\n");
    try writer.writeAll("using System.Threading.Tasks;\n\n");

    try writer.writeAll("class Program\n{\n");
    try writer.writeAll("    static async Task Main(string[] args)\n    {\n");
    try writer.writeAll("        using var client = new HttpClient();\n\n");

    // Headers (skip Content-Type — set via StringContent constructor)
    for (request.headers.items) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "content-type")) continue;
        try writer.print("        client.DefaultRequestHeaders.Add(\"{s}\", \"{s}\");\n", .{ h.name, h.value });
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print("        client.DefaultRequestHeaders.Add(\"Authorization\", \"Bearer {s}\");\n", .{token});
            }
        },
        .api_key => {
            if (request.auth.key_name) |name| {
                if (request.auth.key_value) |value| {
                    const location = request.auth.key_location orelse "header";
                    if (mem.eql(u8, location, "header")) {
                        try writer.print("        client.DefaultRequestHeaders.Add(\"{s}\", \"{s}\");\n", .{ name, value });
                    }
                }
            }
        },
        else => {},
    }

    try writer.writeAll("\n");

    // Request
    const method_name = switch (request.method) {
        .GET => "GetAsync",
        .POST => "PostAsync",
        .PUT => "PutAsync",
        .PATCH => "PatchAsync",
        .DELETE => "DeleteAsync",
        else => "SendAsync",
    };

    if (request.body) |body| {
        const content_type = switch (request.body_type) {
            .json => "application/json",
            .form => "application/x-www-form-urlencoded",
            .xml => "application/xml",
            else => "text/plain",
        };
        const escaped_body = escapeForStringLiteral(allocator, body) catch body;
        defer if (escaped_body.ptr != body.ptr) allocator.free(escaped_body);
        try writer.print("        var content = new StringContent(\"{s}\", Encoding.UTF8, \"{s}\");\n", .{ escaped_body, content_type });

        if (request.method == .POST or request.method == .PUT or request.method == .PATCH) {
            try writer.print("        var response = await client.{s}(\"{s}\", content);\n", .{ method_name, request.url });
        } else {
            try writer.writeAll("        var requestMsg = new HttpRequestMessage\n        {\n");
            try writer.print("            Method = HttpMethod.{s},\n", .{httpMethodCSharp(request.method)});
            try writer.print("            RequestUri = new Uri(\"{s}\"),\n", .{request.url});
            try writer.writeAll("            Content = content\n");
            try writer.writeAll("        };\n");
            try writer.writeAll("        var response = await client.SendAsync(requestMsg);\n");
        }
    } else {
        if (request.method == .GET) {
            try writer.print("        var response = await client.{s}(\"{s}\");\n", .{ method_name, request.url });
        } else if (request.method == .DELETE) {
            try writer.print("        var response = await client.{s}(\"{s}\");\n", .{ method_name, request.url });
        } else {
            try writer.print("        var response = await client.{s}(\"{s}\", null);\n", .{ method_name, request.url });
        }
    }

    try writer.writeAll("\n        var body = await response.Content.ReadAsStringAsync();\n");
    try writer.writeAll("        Console.WriteLine($\"Status: {(int)response.StatusCode}\");\n");
    try writer.writeAll("        Console.WriteLine(body);\n");
    try writer.writeAll("    }\n}\n");

    return buf.toOwnedSlice();
}

/// Export as Rust using reqwest
pub fn exportRust(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("use reqwest;\n\n");
    try writer.writeAll("#[tokio::main]\n");
    try writer.writeAll("async fn main() -> Result<(), Box<dyn std::error::Error>> {\n");
    try writer.writeAll("    let client = reqwest::Client::new();\n\n");

    const method_lower = methodToLower(request.method);
    try writer.print("    let response = client.{s}(\"{s}\")\n", .{ method_lower, request.url });

    // Headers
    for (request.headers.items) |h| {
        try writer.print("        .header(\"{s}\", \"{s}\")\n", .{ h.name, h.value });
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print("        .bearer_auth(\"{s}\")\n", .{token});
            }
        },
        .basic => {
            if (request.auth.username) |user| {
                if (request.auth.password) |pass| {
                    try writer.print("        .basic_auth(\"{s}\", Some(\"{s}\"))\n", .{ user, pass });
                }
            }
        },
        .api_key => {
            if (request.auth.key_name) |name| {
                if (request.auth.key_value) |value| {
                    const location = request.auth.key_location orelse "header";
                    if (mem.eql(u8, location, "header")) {
                        try writer.print("        .header(\"{s}\", \"{s}\")\n", .{ name, value });
                    }
                }
            }
        },
        .digest => {},
        .aws, .hawk, .oauth_cc, .oauth_password, .oauth_implicit => {},
        .none => {},
    }

    // Body
    if (request.body) |body| {
        if (request.body_type == .json) {
            try writer.print("        .body(r#\"{s}\"#)\n", .{body});
        } else {
            try writer.print("        .body(\"{s}\")\n", .{body});
        }
    }

    try writer.writeAll("        .send()\n");
    try writer.writeAll("        .await?;\n\n");
    try writer.writeAll("    println!(\"Status: {}\", response.status());\n");
    try writer.writeAll("    let body = response.text().await?;\n");
    try writer.writeAll("    println!(\"{}\", body);\n\n");
    try writer.writeAll("    Ok(())\n");
    try writer.writeAll("}\n");

    return buf.toOwnedSlice();
}

/// Export as Java using HttpClient (Java 11+)
pub fn exportJava(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("import java.net.URI;\n");
    try writer.writeAll("import java.net.http.HttpClient;\n");
    try writer.writeAll("import java.net.http.HttpRequest;\n");
    try writer.writeAll("import java.net.http.HttpResponse;\n\n");

    try writer.writeAll("public class VoltRequest {\n");
    try writer.writeAll("    public static void main(String[] args) throws Exception {\n");
    try writer.writeAll("        HttpClient client = HttpClient.newHttpClient();\n\n");

    try writer.writeAll("        HttpRequest request = HttpRequest.newBuilder()\n");
    try writer.print("            .uri(URI.create(\"{s}\"))\n", .{request.url});

    // Method and body
    if (request.body) |body| {
        const escaped_body = escapeForStringLiteral(allocator, body) catch body;
        defer if (escaped_body.ptr != body.ptr) allocator.free(escaped_body);
        try writer.print("            .method(\"{s}\", HttpRequest.BodyPublishers.ofString(\"{s}\"))\n", .{ request.method.toString(), escaped_body });
    } else {
        if (request.method == .GET) {
            try writer.writeAll("            .GET()\n");
        } else if (request.method == .DELETE) {
            try writer.writeAll("            .DELETE()\n");
        } else {
            try writer.print("            .method(\"{s}\", HttpRequest.BodyPublishers.noBody())\n", .{request.method.toString()});
        }
    }

    // Headers
    for (request.headers.items) |h| {
        try writer.print("            .header(\"{s}\", \"{s}\")\n", .{ h.name, h.value });
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print("            .header(\"Authorization\", \"Bearer {s}\")\n", .{token});
            }
        },
        .api_key => {
            if (request.auth.key_name) |name| {
                if (request.auth.key_value) |value| {
                    const location = request.auth.key_location orelse "header";
                    if (mem.eql(u8, location, "header")) {
                        try writer.print("            .header(\"{s}\", \"{s}\")\n", .{ name, value });
                    }
                }
            }
        },
        else => {},
    }

    try writer.writeAll("            .build();\n\n");

    try writer.writeAll("        HttpResponse<String> response = client.send(\n");
    try writer.writeAll("            request, HttpResponse.BodyHandlers.ofString());\n\n");
    try writer.writeAll("        System.out.println(\"Status: \" + response.statusCode());\n");
    try writer.writeAll("        System.out.println(response.body());\n");
    try writer.writeAll("    }\n}\n");

    return buf.toOwnedSlice();
}

/// Export as Swift using URLSession
pub fn exportSwift(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("import Foundation\n\n");
    try writer.print("let url = URL(string: \"{s}\")!\n", .{request.url});
    try writer.writeAll("var request = URLRequest(url: url)\n");
    try writer.print("request.httpMethod = \"{s}\"\n", .{request.method.toString()});

    // Headers
    for (request.headers.items) |h| {
        try writer.print("request.setValue(\"{s}\", forHTTPHeaderField: \"{s}\")\n", .{ h.value, h.name });
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print("request.setValue(\"Bearer {s}\", forHTTPHeaderField: \"Authorization\")\n", .{token});
            }
        },
        .api_key => {
            if (request.auth.key_name) |name| {
                if (request.auth.key_value) |value| {
                    const location = request.auth.key_location orelse "header";
                    if (mem.eql(u8, location, "header")) {
                        try writer.print("request.setValue(\"{s}\", forHTTPHeaderField: \"{s}\")\n", .{ value, name });
                    }
                }
            }
        },
        else => {},
    }

    // Body
    if (request.body) |body| {
        const escaped_body = escapeForStringLiteral(allocator, body) catch body;
        defer if (escaped_body.ptr != body.ptr) allocator.free(escaped_body);
        try writer.print("request.httpBody = \"{s}\".data(using: .utf8)\n", .{escaped_body});
    }

    try writer.writeAll("\nlet task = URLSession.shared.dataTask(with: request) { data, response, error in\n");
    try writer.writeAll("    if let error = error {\n");
    try writer.writeAll("        print(\"Error: \\(error)\")\n");
    try writer.writeAll("        return\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    if let httpResponse = response as? HTTPURLResponse {\n");
    try writer.writeAll("        print(\"Status: \\(httpResponse.statusCode)\")\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("    if let data = data, let body = String(data: data, encoding: .utf8) {\n");
    try writer.writeAll("        print(body)\n");
    try writer.writeAll("    }\n");
    try writer.writeAll("}\n");
    try writer.writeAll("task.resume()\n");
    try writer.writeAll("RunLoop.main.run(until: Date(timeIntervalSinceNow: 30))\n");

    return buf.toOwnedSlice();
}

/// Export as Kotlin using OkHttp
pub fn exportKotlin(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("import okhttp3.OkHttpClient\n");
    try writer.writeAll("import okhttp3.Request\n");
    if (request.body != null) {
        try writer.writeAll("import okhttp3.RequestBody.Companion.toRequestBody\n");
        try writer.writeAll("import okhttp3.MediaType.Companion.toMediaType\n");
    }
    try writer.writeAll("\n");

    try writer.writeAll("fun main() {\n");
    try writer.writeAll("    val client = OkHttpClient()\n\n");

    // Body
    if (request.body) |body| {
        const media_type = switch (request.body_type) {
            .json => "application/json",
            .form => "application/x-www-form-urlencoded",
            .xml => "application/xml",
            else => "text/plain",
        };
        const escaped_body = escapeForStringLiteral(allocator, body) catch body;
        defer if (escaped_body.ptr != body.ptr) allocator.free(escaped_body);
        try writer.print("    val body = \"{s}\".toRequestBody(\"{s}\".toMediaType())\n\n", .{ escaped_body, media_type });
    }

    try writer.writeAll("    val request = Request.Builder()\n");
    try writer.print("        .url(\"{s}\")\n", .{request.url});

    // Method
    if (request.body != null) {
        try writer.print("        .method(\"{s}\", body)\n", .{request.method.toString()});
    } else {
        if (request.method == .GET) {
            try writer.writeAll("        .get()\n");
        } else {
            try writer.print("        .method(\"{s}\", null)\n", .{request.method.toString()});
        }
    }

    // Headers
    for (request.headers.items) |h| {
        try writer.print("        .addHeader(\"{s}\", \"{s}\")\n", .{ h.name, h.value });
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print("        .addHeader(\"Authorization\", \"Bearer {s}\")\n", .{token});
            }
        },
        .api_key => {
            if (request.auth.key_name) |name| {
                if (request.auth.key_value) |value| {
                    const location = request.auth.key_location orelse "header";
                    if (mem.eql(u8, location, "header")) {
                        try writer.print("        .addHeader(\"{s}\", \"{s}\")\n", .{ name, value });
                    }
                }
            }
        },
        else => {},
    }

    try writer.writeAll("        .build()\n\n");

    try writer.writeAll("    val response = client.newCall(request).execute()\n");
    try writer.writeAll("    println(\"Status: ${response.code}\")\n");
    try writer.writeAll("    println(response.body?.string())\n");
    try writer.writeAll("}\n");

    return buf.toOwnedSlice();
}

/// Export as Dart using http package
pub fn exportDart(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("import 'package:http/http.dart' as http;\n");
    try writer.writeAll("import 'dart:convert';\n\n");

    try writer.writeAll("void main() async {\n");
    try writer.print("  final url = Uri.parse('{s}');\n\n", .{request.url});

    // Headers map
    if (request.headers.items.len > 0 or request.auth.type != .none) {
        try writer.writeAll("  final headers = {\n");
        for (request.headers.items) |h| {
            try writer.print("    '{s}': '{s}',\n", .{ h.name, h.value });
        }
        switch (request.auth.type) {
            .bearer => {
                if (request.auth.token) |token| {
                    try writer.print("    'Authorization': 'Bearer {s}',\n", .{token});
                }
            },
            .api_key => {
                if (request.auth.key_name) |name| {
                    if (request.auth.key_value) |value| {
                        const location = request.auth.key_location orelse "header";
                        if (mem.eql(u8, location, "header")) {
                            try writer.print("    '{s}': '{s}',\n", .{ name, value });
                        }
                    }
                }
            },
            else => {},
        }
        try writer.writeAll("  };\n\n");
    }

    // Request call
    const method_lower = methodToLower(request.method);
    if (request.body) |body| {
        try writer.print("  final response = await http.{s}(\n", .{method_lower});
        try writer.writeAll("    url,\n");
        if (request.headers.items.len > 0 or request.auth.type != .none) {
            try writer.writeAll("    headers: headers,\n");
        }
        try writer.print("    body: '{s}',\n", .{body});
        try writer.writeAll("  );\n");
    } else {
        if (request.headers.items.len > 0 or request.auth.type != .none) {
            try writer.print("  final response = await http.{s}(url, headers: headers);\n", .{method_lower});
        } else {
            try writer.print("  final response = await http.{s}(url);\n", .{method_lower});
        }
    }

    try writer.writeAll("\n  print('Status: ${response.statusCode}');\n");
    try writer.writeAll("  print(response.body);\n");
    try writer.writeAll("}\n");

    return buf.toOwnedSlice();
}

/// Export as R using httr library
pub fn exportR(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("library(httr)\n\n");

    const r_method = switch (request.method) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .PATCH => "PATCH",
        .DELETE => "DELETE",
        .HEAD => "HEAD",
        .OPTIONS => "VERB",
    };

    try writer.print("response <- {s}(\n", .{r_method});
    try writer.print("  \"{s}\"", .{request.url});

    // Headers
    if (request.headers.items.len > 0) {
        try writer.writeAll(",\n  add_headers(\n");
        for (request.headers.items, 0..) |h, i| {
            if (i > 0) try writer.writeAll(",\n");
            try writer.print("    `{s}` = \"{s}\"", .{ h.name, h.value });
        }
        try writer.writeAll("\n  )");
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print(",\n  add_headers(Authorization = \"Bearer {s}\")", .{token});
            }
        },
        .basic => {
            if (request.auth.username) |user| {
                if (request.auth.password) |pass| {
                    try writer.print(",\n  authenticate(\"{s}\", \"{s}\")", .{ user, pass });
                }
            }
        },
        else => {},
    }

    // Body
    if (request.body) |body| {
        if (request.body_type == .json) {
            try writer.print(",\n  body = '{s}',\n  encode = \"json\"", .{body});
        } else {
            try writer.print(",\n  body = \"{s}\"", .{body});
        }
    }

    try writer.writeAll("\n)\n\n");
    try writer.writeAll("cat(\"Status:\", status_code(response), \"\\n\")\n");
    try writer.writeAll("cat(content(response, \"text\"), \"\\n\")\n");

    return buf.toOwnedSlice();
}

/// Export as HTTPie command
pub fn exportHttpie(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    const method_lower = methodToLower(request.method);

    try writer.print("http {s} '{s}'", .{ method_lower, request.url });

    // Headers
    for (request.headers.items) |h| {
        try writer.print(" \\\n  {s}:{s}", .{ h.name, h.value });
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print(" \\\n  Authorization:\"Bearer {s}\"", .{token});
            }
        },
        .basic => {
            if (request.auth.username) |user| {
                if (request.auth.password) |pass| {
                    try writer.print(" \\\n  --auth {s}:{s}", .{ user, pass });
                }
            }
        },
        .api_key => {
            if (request.auth.key_name) |name| {
                if (request.auth.key_value) |value| {
                    const location = request.auth.key_location orelse "header";
                    if (mem.eql(u8, location, "header")) {
                        try writer.print(" \\\n  {s}:{s}", .{ name, value });
                    }
                }
            }
        },
        .digest => {},
        .aws, .hawk, .oauth_cc, .oauth_password, .oauth_implicit => {},
        .none => {},
    }

    // Body - for HTTPie, use raw input
    if (request.body) |body| {
        try writer.print(" \\\n  --raw '{s}'", .{body});
    }

    try writer.writeByte('\n');
    return buf.toOwnedSlice();
}

/// Export as wget command
pub fn exportWget(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("wget");

    // Method (wget uses --method for non-GET)
    if (request.method != .GET) {
        try writer.print(" --method={s}", .{request.method.toString()});
    }

    // Quiet and output to stdout
    try writer.writeAll(" -qO-");

    // Headers
    for (request.headers.items) |h| {
        try writer.print(" \\\n  --header='{s}: {s}'", .{ h.name, h.value });
    }

    // Auth
    switch (request.auth.type) {
        .bearer => {
            if (request.auth.token) |token| {
                try writer.print(" \\\n  --header='Authorization: Bearer {s}'", .{token});
            }
        },
        .basic => {
            if (request.auth.username) |user| {
                if (request.auth.password) |pass| {
                    try writer.print(" \\\n  --user={s} --password={s}", .{ user, pass });
                }
            }
        },
        .api_key => {
            if (request.auth.key_name) |name| {
                if (request.auth.key_value) |value| {
                    const location = request.auth.key_location orelse "header";
                    if (mem.eql(u8, location, "header")) {
                        try writer.print(" \\\n  --header='{s}: {s}'", .{ name, value });
                    }
                }
            }
        },
        .digest => {},
        .aws, .hawk, .oauth_cc, .oauth_password, .oauth_implicit => {},
        .none => {},
    }

    // Body
    if (request.body) |body| {
        try writer.print(" \\\n  --body-data='{s}'", .{body});
    }

    // URL last
    try writer.print(" \\\n  '{s}'\n", .{request.url});

    return buf.toOwnedSlice();
}

/// Export as PowerShell using Invoke-RestMethod
pub fn exportPowerShell(request: *const VoltFile.VoltRequest, allocator: Allocator) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    // Headers
    if (request.headers.items.len > 0 or request.auth.type != .none) {
        try writer.writeAll("$headers = @{\n");
        for (request.headers.items) |h| {
            try writer.print("    \"{s}\" = \"{s}\"\n", .{ h.name, h.value });
        }
        switch (request.auth.type) {
            .bearer => {
                if (request.auth.token) |token| {
                    try writer.print("    \"Authorization\" = \"Bearer {s}\"\n", .{token});
                }
            },
            .api_key => {
                if (request.auth.key_name) |name| {
                    if (request.auth.key_value) |value| {
                        const location = request.auth.key_location orelse "header";
                        if (mem.eql(u8, location, "header")) {
                            try writer.print("    \"{s}\" = \"{s}\"\n", .{ name, value });
                        }
                    }
                }
            },
            else => {},
        }
        try writer.writeAll("}\n\n");
    }

    // Body
    if (request.body) |body| {
        try writer.print("$body = @'\n{s}\n'@\n\n", .{body});
    }

    // Invoke-RestMethod call
    try writer.writeAll("$response = Invoke-RestMethod");
    try writer.print(" -Uri \"{s}\"", .{request.url});
    try writer.print(" -Method {s}", .{request.method.toString()});

    if (request.headers.items.len > 0 or request.auth.type != .none) {
        try writer.writeAll(" -Headers $headers");
    }

    if (request.body != null) {
        try writer.writeAll(" -Body $body");

        const content_type = switch (request.body_type) {
            .json => "application/json",
            .form => "application/x-www-form-urlencoded",
            .xml => "application/xml",
            else => "text/plain",
        };
        try writer.print(" -ContentType \"{s}\"", .{content_type});
    }

    // Basic auth
    if (request.auth.type == .basic) {
        if (request.auth.username) |user| {
            if (request.auth.password) |pass| {
                try writer.print("\n\n$secpasswd = ConvertTo-SecureString \"{s}\" -AsPlainText -Force\n", .{pass});
                try writer.print("$cred = New-Object System.Management.Automation.PSCredential(\"{s}\", $secpasswd)\n", .{user});
                try writer.writeAll("$response = Invoke-RestMethod");
                try writer.print(" -Uri \"{s}\"", .{request.url});
                try writer.print(" -Method {s}", .{request.method.toString()});
                try writer.writeAll(" -Credential $cred");
            }
        }
    }

    try writer.writeAll("\n\n$response | ConvertTo-Json -Depth 10\n");

    return buf.toOwnedSlice();
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn methodToLower(method: VoltFile.Method) []const u8 {
    return switch (method) {
        .GET => "get",
        .POST => "post",
        .PUT => "put",
        .PATCH => "patch",
        .DELETE => "delete",
        .HEAD => "head",
        .OPTIONS => "options",
    };
}

fn httpMethodCSharp(method: VoltFile.Method) []const u8 {
    return switch (method) {
        .GET => "Get",
        .POST => "Post",
        .PUT => "Put",
        .PATCH => "Patch",
        .DELETE => "Delete",
        .HEAD => "Head",
        .OPTIONS => "Options",
    };
}

// ── Tests ───────────────────────────────────────────────────────────────

test "ruby snippet contains expected keywords" {
    var req = VoltFile.VoltRequest.init(std.testing.allocator);
    defer req.deinit();
    req.method = .POST;
    req.url = "https://api.example.com/users";
    try req.addHeader("Content-Type", "application/json");
    req.body = "{\"name\": \"test\"}";

    const result = try exportRuby(&req, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "require 'net/http'") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Net::HTTP::Post") != null);
    try std.testing.expect(mem.indexOf(u8, result, "https://api.example.com/users") != null);
    try std.testing.expect(mem.indexOf(u8, result, "Content-Type") != null);
}

test "java snippet contains expected keywords" {
    var req = VoltFile.VoltRequest.init(std.testing.allocator);
    defer req.deinit();
    req.method = .GET;
    req.url = "https://api.example.com/users";
    try req.addHeader("Accept", "application/json");

    const result = try exportJava(&req, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "import java.net.http.HttpClient") != null);
    try std.testing.expect(mem.indexOf(u8, result, "HttpRequest.newBuilder()") != null);
    try std.testing.expect(mem.indexOf(u8, result, "https://api.example.com/users") != null);
    try std.testing.expect(mem.indexOf(u8, result, ".GET()") != null);
}

test "powershell snippet contains expected keywords" {
    var req = VoltFile.VoltRequest.init(std.testing.allocator);
    defer req.deinit();
    req.method = .PUT;
    req.url = "https://api.example.com/users/1";
    req.body = "{\"name\": \"updated\"}";
    req.body_type = .json;
    try req.addHeader("Content-Type", "application/json");

    const result = try exportPowerShell(&req, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expect(mem.indexOf(u8, result, "Invoke-RestMethod") != null);
    try std.testing.expect(mem.indexOf(u8, result, "-Method PUT") != null);
    try std.testing.expect(mem.indexOf(u8, result, "https://api.example.com/users/1") != null);
    try std.testing.expect(mem.indexOf(u8, result, "$headers") != null);
    try std.testing.expect(mem.indexOf(u8, result, "$body") != null);
}
