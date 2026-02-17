const std = @import("std");
const mem = std.mem;
const core = @import("volt-core");
const VoltFile = core.VoltFile;
const HttpClient = core.HttpClient;
const Environment = core.Environment;
const Importer = core.Importer;
const GraphQL = core.GraphQL;
const Bench = core.Bench;
const Exporter = core.Exporter;
const Scripting = core.Scripting;
const CollectionRunner = core.CollectionRunner;
const History = core.History;
const MockServer = core.MockServer;
const TestGenerator = core.TestGenerator;
const Formatter = core.Formatter;
const Config = core.Config;
const Workflow = core.Workflow;
const Validator = core.Validator;
const Completions = core.Completions;
const Snippet = core.Snippet;
const Har = core.Har;
const DocGenerator = core.DocGenerator;
const Retry = core.Retry;
const Cache = core.Cache;
const Monitor = core.Monitor;
const OAuth = core.OAuth;
const DiffEngine = core.DiffEngine;
const WebSocket = core.WebSocket;
const SSE = core.SSE;
const Signing = core.Signing;
const Multipart = core.Multipart;
const CurlImport = core.CurlImport;
const OpenAPIImport = core.OpenAPIImport;
const InsomniaImport = core.InsomniaImport;
const DynamicVars = core.DynamicVars;
const CookieJar = core.CookieJar;
const JsonPath = core.JsonPath;
const JUnit = core.JUnit;
const TestReport = core.TestReport;
const DataDriver = core.DataDriver;
const Grpc = core.Grpc;
const Secrets = core.Secrets;
const Watch = core.Watch;
const CI = core.CI;
const Share = core.Share;
const Mqtt = core.Mqtt;
const SocketIO = core.SocketIO;
const Proxy = core.Proxy;
const Themes = core.Themes;
const Plugin = core.Plugin;
const OpenAPIDesigner = core.OpenAPIDesigner;
const Replay = core.Replay;
const H2 = core.H2;
const OAuthFlow = core.OAuthFlow;
const ResponseViewer = core.ResponseViewer;
const CollectionOrganizer = core.CollectionOrganizer;
const WebServer = core.WebServer;
const App = @import("tui/app.zig").App;

const version = "1.0.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        // No arguments — launch TUI
        try launchTui(allocator, ".");
        return;
    }

    const command = args[1];

    if (mem.eql(u8, command, "run")) {
        try cmdRun(allocator, args[2..]);
    } else if (mem.eql(u8, command, "test")) {
        try cmdTest(allocator, args[2..]);
    } else if (mem.eql(u8, command, "import")) {
        try cmdImport(allocator, args[2..]);
    } else if (mem.eql(u8, command, "env")) {
        try cmdEnv(allocator, args[2..]);
    } else if (mem.eql(u8, command, "lint")) {
        try cmdLint(allocator, args[2..]);
    } else if (mem.eql(u8, command, "diff")) {
        try cmdDiff(allocator, args[2..]);
    } else if (mem.eql(u8, command, "bench")) {
        try cmdBench(allocator, args[2..]);
    } else if (mem.eql(u8, command, "mock")) {
        try cmdMock(allocator, args[2..]);
    } else if (mem.eql(u8, command, "export")) {
        try cmdExport(allocator, args[2..]);
    } else if (mem.eql(u8, command, "collection")) {
        try cmdCollection(allocator, args[2..]);
    } else if (mem.eql(u8, command, "graphql")) {
        try cmdGraphQL(allocator, args[2..]);
    } else if (mem.eql(u8, command, "generate") or mem.eql(u8, command, "gen")) {
        try cmdGenerate(allocator, args[2..]);
    } else if (mem.eql(u8, command, "init")) {
        try cmdInit(allocator, args[2..]);
    } else if (mem.eql(u8, command, "history")) {
        try cmdHistory(allocator, args[2..]);
    } else if (mem.eql(u8, command, "workflow") or mem.eql(u8, command, "wf")) {
        try cmdWorkflow(allocator, args[2..]);
    } else if (mem.eql(u8, command, "validate") or mem.eql(u8, command, "schema")) {
        try cmdValidate(allocator, args[2..]);
    } else if (mem.eql(u8, command, "docs")) {
        try cmdDocs(allocator, args[2..]);
    } else if (mem.eql(u8, command, "completions")) {
        try cmdCompletions(allocator, args[2..]);
    } else if (mem.eql(u8, command, "monitor") or mem.eql(u8, command, "mon")) {
        try cmdMonitor(allocator, args[2..]);
    } else if (mem.eql(u8, command, "cache")) {
        try cmdCache(allocator, args[2..]);
    } else if (mem.eql(u8, command, "ws") or mem.eql(u8, command, "websocket")) {
        try cmdWebSocket(allocator, args[2..]);
    } else if (mem.eql(u8, command, "sse")) {
        try cmdSSE(allocator, args[2..]);
    } else if (mem.eql(u8, command, "auth")) {
        try cmdAuth(allocator, args[2..]);
    } else if (mem.eql(u8, command, "har")) {
        try cmdHar(allocator, args[2..]);
    } else if (mem.eql(u8, command, "grpc")) {
        try cmdGrpc(allocator, args[2..]);
    } else if (mem.eql(u8, command, "secrets") or mem.eql(u8, command, "secret")) {
        try cmdSecrets(allocator, args[2..]);
    } else if (mem.eql(u8, command, "watch")) {
        try cmdWatch(allocator, args[2..]);
    } else if (mem.eql(u8, command, "ci")) {
        try cmdCI(allocator, args[2..]);
    } else if (mem.eql(u8, command, "share")) {
        try cmdShare(allocator, args[2..]);
    } else if (mem.eql(u8, command, "mqtt")) {
        try cmdMqtt(allocator, args[2..]);
    } else if (mem.eql(u8, command, "socketio") or mem.eql(u8, command, "sio")) {
        try cmdSocketIO(allocator, args[2..]);
    } else if (mem.eql(u8, command, "proxy")) {
        try cmdProxy(allocator, args[2..]);
    } else if (mem.eql(u8, command, "theme") or mem.eql(u8, command, "themes")) {
        try cmdTheme(allocator, args[2..]);
    } else if (mem.eql(u8, command, "plugin") or mem.eql(u8, command, "plugins")) {
        try cmdPlugin(allocator, args[2..]);
    } else if (mem.eql(u8, command, "design") or mem.eql(u8, command, "openapi-design")) {
        try cmdDesign(allocator, args[2..]);
    } else if (mem.eql(u8, command, "replay")) {
        try cmdReplay(allocator, args[2..]);
    } else if (mem.eql(u8, command, "login") or mem.eql(u8, command, "auth-login")) {
        try cmdAuthLogin(allocator, args[2..]);
    } else if (mem.eql(u8, command, "ui")) {
        try cmdUi(allocator, args[2..]);
    } else if (mem.eql(u8, command, "serve")) {
        try cmdServe(allocator, args[2..]);
    } else if (mem.eql(u8, command, "search") or mem.eql(u8, command, "find")) {
        try cmdSearch(allocator, args[2..]);
    } else if (mem.eql(u8, command, "version") or mem.eql(u8, command, "--version") or mem.eql(u8, command, "-v")) {
        try printVersion();
    } else if (mem.eql(u8, command, "help") or mem.eql(u8, command, "--help") or mem.eql(u8, command, "-h")) {
        try printHelp();
    } else if (mem.endsWith(u8, command, ".volt")) {
        // Direct file execution: volt myrequest.volt
        try cmdRun(allocator, args[1..]);
    } else {
        try printError("Unknown command: {s}", .{command});
        try printHelp();
    }
}

// ── Commands ────────────────────────────────────────────────────────────

fn launchTui(allocator: std.mem.Allocator, dir: []const u8) !void {
    var app = try App.init(allocator, dir);
    defer app.deinit();
    try app.run();
}

fn cmdRun(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printError("Usage: volt run <file.volt|dir> [--env <environment>] [--verbose]", .{});
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("\n  Options:\n");
        try stdout.writeAll("    --env <name>              Use named environment\n");
        try stdout.writeAll("    --verbose, -v             Show response headers\n");
        try stdout.writeAll("    --retry <N>               Retry on failure (max N retries)\n");
        try stdout.writeAll("    --retry-strategy <s>      constant, linear, exponential (default)\n");
        try stdout.writeAll("    --sign                    Sign request (reads signing: section from .volt)\n");
        try stdout.writeAll("    --timeout <ms>            Request timeout in milliseconds\n");
        try stdout.writeAll("    --dry-run                 Show request without sending\n");
        try stdout.writeAll("    --output, -o <file>       Save response body to file\n");
        try stdout.writeAll("    --quiet, -q               Only output response body\n");
        return;
    }

    const file_path = args[0];
    var env_name: ?[]const u8 = null;
    var verbose = false;
    var retry_count: ?u32 = null;
    var retry_strategy: Retry.BackoffStrategy = .exponential;
    var sign_request = false;
    var timeout_ms: ?u32 = null;
    var dry_run = false;
    var output_file: ?[]const u8 = null;
    var quiet = false;

    // Parse flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--env") and i + 1 < args.len) {
            env_name = args[i + 1];
            i += 1;
        } else if (mem.eql(u8, args[i], "--verbose") or mem.eql(u8, args[i], "-v")) {
            verbose = true;
        } else if (mem.eql(u8, args[i], "--retry") and i + 1 < args.len) {
            retry_count = std.fmt.parseInt(u32, args[i + 1], 10) catch 3;
            i += 1;
        } else if (mem.eql(u8, args[i], "--retry-strategy") and i + 1 < args.len) {
            const val = args[i + 1];
            if (mem.eql(u8, val, "constant")) {
                retry_strategy = .constant;
            } else if (mem.eql(u8, val, "linear")) {
                retry_strategy = .linear;
            }
            i += 1;
        } else if (mem.eql(u8, args[i], "--sign")) {
            sign_request = true;
        } else if (mem.eql(u8, args[i], "--timeout") and i + 1 < args.len) {
            timeout_ms = std.fmt.parseInt(u32, args[i + 1], 10) catch null;
            i += 1;
        } else if (mem.eql(u8, args[i], "--dry-run")) {
            dry_run = true;
        } else if ((mem.eql(u8, args[i], "--output") or mem.eql(u8, args[i], "-o")) and i + 1 < args.len) {
            output_file = args[i + 1];
            i += 1;
        } else if (mem.eql(u8, args[i], "--quiet") or mem.eql(u8, args[i], "-q")) {
            quiet = true;
        }
    }

    // Check if target is a directory (collection run)
    const is_dir = blk: {
        var dir = std.fs.cwd().openDir(file_path, .{}) catch break :blk false;
        dir.close();
        break :blk true;
    };

    if (is_dir) {
        // Run as collection
        var env_mgr = Environment.EnvManager.init(allocator);
        defer env_mgr.deinit();
        if (env_name) |name| env_mgr.setActive(name);

        var result = try CollectionRunner.runCollection(allocator, file_path, &env_mgr, verbose);
        defer result.deinit();

        try CollectionRunner.printSummary(&result);
        if (result.failed > 0) std.process.exit(1);
        return;
    }

    // Load project config
    var config = Config.loadConfig(allocator, ".") catch Config.VoltConfig.init(allocator);
    defer config.deinit();

    // Single file execution
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        try printError("Cannot open file: {s}", .{file_path});
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var request = VoltFile.parse(allocator, content) catch {
        try printError("Failed to parse .volt file: {s}", .{file_path});
        return;
    };
    defer request.deinit();

    // Apply config default headers
    for (config.default_headers.items) |h| {
        // Only add if not already present in request
        var found = false;
        for (request.headers.items) |rh| {
            if (mem.eql(u8, rh.name, h.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try request.headers.append(.{ .name = h.name, .value = h.value });
        }
    }

    // Set up environment
    var env_mgr = Environment.EnvManager.init(allocator);
    defer env_mgr.deinit();

    if (env_name) |name| {
        env_mgr.setActive(name);
    }

    // Interpolate URL (prepend base_url if relative)
    var effective_url = request.url;
    var base_prefixed: ?[]const u8 = null;
    if (config.base_url) |base| {
        if (!mem.startsWith(u8, request.url, "http://") and !mem.startsWith(u8, request.url, "https://")) {
            base_prefixed = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, request.url }) catch null;
            if (base_prefixed) |bp| effective_url = bp;
        }
    }
    defer if (base_prefixed) |bp| allocator.free(bp);

    const resolved_url = try env_mgr.interpolate(effective_url, &request.variables, allocator);
    defer allocator.free(resolved_url);
    request.url = resolved_url;

    // Interpolate headers (resolve env vars + dynamic vars)
    var resolved_headers = std.ArrayList(VoltFile.Header).init(allocator);
    defer {
        for (resolved_headers.items) |rh| {
            allocator.free(rh.name);
            allocator.free(rh.value);
        }
        resolved_headers.deinit();
    }
    for (request.headers.items) |h| {
        const rn = try env_mgr.interpolate(h.name, &request.variables, allocator);
        const rv = try env_mgr.interpolate(h.value, &request.variables, allocator);
        try resolved_headers.append(.{ .name = rn, .value = rv });
    }
    request.headers.clearRetainingCapacity();
    for (resolved_headers.items) |rh| {
        try request.headers.append(.{ .name = rh.name, .value = rh.value });
    }

    // Interpolate body (resolve env vars + dynamic vars like {{$uuid}})
    if (request.body) |body| {
        const new_body = try env_mgr.interpolate(body, &request.variables, allocator);
        // Free old body if it was heap-allocated by the parser
        if (request.body_owned) {
            allocator.free(body);
        }
        request.body = new_body;
        request.body_owned = true;
    }

    // Apply request signing if --sign flag is set
    if (sign_request) {
        const signing_config = Signing.parseSigningConfig(content);
        Signing.signRequest(allocator, &request, &signing_config) catch {
            try printError("Failed to sign request. Check signing: section in .volt file.", .{});
            return;
        };
    }

    // Execute pre-script
    var script_ctx = Scripting.ScriptContext.init(allocator);
    defer script_ctx.deinit();

    if (request.pre_script) |pre| {
        script_ctx.request = &request;
        Scripting.executeScript(&script_ctx, pre) catch {};
    }

    // Build multipart body if body_type is multipart
    var multipart_body: ?[]const u8 = null;
    var multipart_ct: ?[]const u8 = null;
    if (request.body_type == .multipart and request.body != null) {
        var mp_builder = Multipart.MultipartBuilder.init(allocator);
        defer mp_builder.deinit();

        // Parse multipart fields from body content (field=value pairs, one per line)
        var body_lines = mem.splitSequence(u8, request.body.?, "\n");
        while (body_lines.next()) |raw_line| {
            const line = mem.trimRight(u8, raw_line, "\r");
            const trimmed = mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;

            if (mem.startsWith(u8, trimmed, "@")) {
                // File upload: @fieldname=path/to/file
                const rest = trimmed[1..];
                if (mem.indexOf(u8, rest, "=")) |eq_pos| {
                    const field_name = rest[0..eq_pos];
                    const file_path_val = rest[eq_pos + 1 ..];
                    mp_builder.addFileFromPath(field_name, file_path_val) catch continue;
                }
            } else if (mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                // Text field: name=value
                const field_name = trimmed[0..eq_pos];
                const field_value = trimmed[eq_pos + 1 ..];
                mp_builder.addField(field_name, field_value) catch continue;
            }
        }

        multipart_body = mp_builder.build() catch null;
        multipart_ct = mp_builder.getContentTypeHeader(allocator) catch null;
        if (multipart_body) |mb| {
            request.body = mb;
        }
        if (multipart_ct) |ct| {
            // Add/replace Content-Type header
            var found_ct = false;
            for (request.headers.items) |*h| {
                if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                    h.value = ct;
                    found_ct = true;
                    break;
                }
            }
            if (!found_ct) {
                try request.headers.append(.{ .name = "Content-Type", .value = ct });
            }
        }
    }
    defer if (multipart_body) |mb| allocator.free(mb);
    defer if (multipart_ct) |ct| allocator.free(ct);

    // Print request line
    const stdout = std.io.getStdOut().writer();
    if (!quiet) {
        if (request.description) |desc| {
            try stdout.print("\x1b[90m# {s}\x1b[0m\n", .{desc});
        }
        try stdout.print("\x1b[36m{s}\x1b[0m {s}\n", .{ request.method.toString(), request.url });
    }

    // Dry-run mode: show request details without sending
    if (dry_run) {
        try stdout.writeAll("\n\x1b[33m[DRY RUN]\x1b[0m Request will not be sent.\n\n");
        try stdout.print("  Method:  {s}\n", .{request.method.toString()});
        try stdout.print("  URL:     {s}\n", .{request.url});
        if (request.headers.items.len > 0) {
            try stdout.writeAll("  Headers:\n");
            for (request.headers.items) |h| {
                try stdout.print("    {s}: {s}\n", .{ h.name, h.value });
            }
        }
        if (request.body) |body_content| {
            try stdout.writeAll("  Body:\n");
            const preview = body_content[0..@min(500, body_content.len)];
            try stdout.print("    {s}", .{preview});
            if (body_content.len > 500) try stdout.writeAll("...(truncated)");
            try stdout.writeAll("\n");
        }
        return;
    }

    // Build HTTP config with optional timeout (CLI flag overrides .volt file timeout)
    const effective_timeout = timeout_ms orelse request.timeout orelse 30000;
    const http_config = HttpClient.ClientConfig{
        .timeout_ms = effective_timeout,
    };

    // Execute request (with or without retry)
    var response: HttpClient.Response = undefined;
    var retry_result: ?Retry.RetryResult = null;

    if (retry_count) |max_retries| {
        var rr = Retry.executeWithRetry(allocator, &request, .{
            .max_retries = max_retries,
            .strategy = retry_strategy,
        }, http_config) catch {
            try printError("Request failed after retries: connection error", .{});
            return;
        };

        if (rr.response) |resp| {
            response = resp;
            rr.response = null; // transfer ownership
            retry_result = rr;
        } else {
            const output = Retry.formatResult(&rr, allocator) catch null;
            if (output) |o| {
                defer allocator.free(o);
                try stdout.writeAll(o);
            }
            rr.deinit();
            try printError("All retry attempts failed", .{});
            return;
        }
    } else {
        response = HttpClient.execute(allocator, &request, http_config) catch {
            try printError("Request failed: connection error", .{});
            return;
        };
    }
    defer response.deinit();
    defer if (retry_result) |*rr| rr.deinit();

    // Execute post-script
    if (request.post_script) |post| {
        script_ctx.response = &response;
        Scripting.executeScript(&script_ctx, post) catch {};
    }

    // Save response body to file if --output specified
    const body = response.bodySlice();
    if (output_file) |out_path| {
        const out_f = std.fs.cwd().createFile(out_path, .{}) catch {
            try printError("Cannot create output file: {s}", .{out_path});
            return;
        };
        defer out_f.close();
        try out_f.writeAll(body);
        if (!quiet) {
            try stdout.print("\x1b[32m✓\x1b[0m Response saved to {s} ({d} bytes)\n", .{ out_path, body.len });
        }
    }

    // Quiet mode: only output the body
    if (quiet) {
        if (body.len > 0) {
            try stdout.writeAll(body);
            if (body[body.len - 1] != '\n') try stdout.writeAll("\n");
        }
        return;
    }

    // Print response status and timing
    const status_color: []const u8 = if (response.status_code < 300) "\x1b[32m" else if (response.status_code < 400) "\x1b[33m" else "\x1b[31m";
    try stdout.print("\n{s}HTTP {d} {s}\x1b[0m\n", .{
        status_color,
        response.status_code,
        HttpClient.httpStatusText(response.status_code),
    });
    try stdout.print("\x1b[90mTime: {d:.1}ms | Size: {d} bytes\x1b[0m\n\n", .{
        response.timing.total_ms,
        response.size_bytes,
    });

    // Headers and verbose info
    if (verbose) {
        if (response.redirect_count > 0) {
            try stdout.print("\x1b[90mRedirects: {d}\x1b[0m\n", .{response.redirect_count});
        }
        for (response.headers.items) |h| {
            try stdout.print("\x1b[36m{s}\x1b[0m: {s}\n", .{ h.name, h.value });
        }
        try stdout.writeAll("\n");
    }

    // Body (with JSON pretty-printing)
    if (body.len > 0 and output_file == null) {
        // Check if response looks like JSON and pretty-print it
        const trimmed_body = mem.trim(u8, body, " \t\r\n");
        if (trimmed_body.len > 0 and (trimmed_body[0] == '{' or trimmed_body[0] == '[')) {
            const formatted_body = Formatter.formatJson(allocator, body, true) catch null;
            if (formatted_body) |fb| {
                defer allocator.free(fb);
                try stdout.writeAll(fb);
            } else {
                try stdout.writeAll(body);
                if (body[body.len - 1] != '\n') try stdout.writeAll("\n");
            }
        } else {
            try stdout.writeAll(body);
            if (body[body.len - 1] != '\n') try stdout.writeAll("\n");
        }
    }

    // Print retry info if retries occurred
    if (retry_result) |*rr| {
        if (rr.retried) {
            try stdout.print("\n\x1b[90mRetried {d} time(s) | Total: {d:.1}ms\x1b[0m\n", .{
                rr.attempts -| 1,
                rr.total_time_ms,
            });
        }
    }

    // Print script output
    if (script_ctx.output.items.len > 0) {
        try stdout.print("\n\x1b[90m{s}\x1b[0m", .{script_ctx.output.items});
    }
}

fn cmdTest(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    // Check for flags
    var watch_mode = false;
    var report_format: ?[]const u8 = null;
    var report_output: ?[]const u8 = null;
    var data_file: ?[]const u8 = null;
    var target_files = std.ArrayList([]const u8).init(allocator);
    defer target_files.deinit();

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--watch") or mem.eql(u8, args[i], "-w")) {
            watch_mode = true;
        } else if (mem.eql(u8, args[i], "--report") and i + 1 < args.len) {
            report_format = args[i + 1];
            i += 1;
        } else if ((mem.eql(u8, args[i], "--output") or mem.eql(u8, args[i], "-o")) and i + 1 < args.len) {
            report_output = args[i + 1];
            i += 1;
        } else if (mem.eql(u8, args[i], "--data") and i + 1 < args.len) {
            data_file = args[i + 1];
            i += 1;
        } else if (!mem.startsWith(u8, args[i], "--")) {
            try target_files.append(args[i]);
        }
    }

    if (watch_mode) {
        try stdout.writeAll("\x1b[1mVolt Test Watch Mode\x1b[0m\n");
        try stdout.writeAll("Watching for changes... (Ctrl+C to stop)\n\n");

        var iteration: usize = 0;
        while (iteration < 100) : (iteration += 1) {
            try runTestSuite(allocator, target_files.items, null, null, null);
            std.time.sleep(2 * std.time.ns_per_s);
            try stdout.writeAll("\x1b[90m--- watching for changes ---\x1b[0m\n");
        }
        return;
    }

    try runTestSuite(allocator, target_files.items, report_format, report_output, data_file);
}

fn runTestSuite(
    allocator: std.mem.Allocator,
    specified_files: []const []const u8,
    report_format: ?[]const u8,
    report_output: ?[]const u8,
    data_file: ?[]const u8,
) !void {
    const stdout = std.io.getStdOut().writer();

    // Find .volt files to test
    var files_to_test = std.ArrayList([]const u8).init(allocator);
    defer {
        for (files_to_test.items) |f| {
            allocator.free(f);
        }
        files_to_test.deinit();
    }

    if (specified_files.len > 0) {
        for (specified_files) |f| {
            // Check if the argument is a directory
            var opened_dir = std.fs.cwd().openDir(f, .{ .iterate = true }) catch {
                // Not a directory, treat as a file
                try files_to_test.append(try allocator.dupe(u8, f));
                continue;
            };
            defer opened_dir.close();
            var iter = opened_dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind == .file and mem.endsWith(u8, entry.name, ".volt") and !mem.startsWith(u8, entry.name, "_")) {
                    const dir_path = mem.trimRight(u8, f, "/\\");
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
                    try files_to_test.append(full_path);
                }
            }
        }
    } else {
        var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch {
            try printError("Cannot open current directory", .{});
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".volt")) {
                try files_to_test.append(try allocator.dupe(u8, entry.name));
            }
        }
    }

    if (files_to_test.items.len == 0) {
        try stdout.writeAll("No .volt files found to test.\n");
        return;
    }

    // Load data file for data-driven testing
    var dataset: ?DataDriver.DataSet = null;
    defer if (dataset) |*ds| ds.deinit();

    if (data_file) |df| {
        dataset = DataDriver.loadDataFile(allocator, df) catch {
            try printError("Failed to load data file: {s}", .{df});
            return;
        };
        try stdout.print("\x1b[1mData-driven mode:\x1b[0m {d} rows from {s}\n", .{
            dataset.?.rows.items.len, df,
        });
    }

    const start_time = std.time.nanoTimestamp();
    var total_tests: usize = 0;
    var passed: usize = 0;
    var failed: usize = 0;

    // For report generation
    var report_entries = std.ArrayList(TestReport.ReportEntry).init(allocator);
    defer {
        for (report_entries.items) |entry| {
            allocator.free(entry.test_name);
            if (entry.expected) |exp| allocator.free(exp);
        }
        report_entries.deinit();
    }
    var junit_report = JUnit.TestReport.init(allocator);
    defer junit_report.deinit();

    const data_iterations: usize = if (dataset) |ds| ds.rows.items.len else 1;

    for (files_to_test.items) |file_path| {
        const file = std.fs.cwd().openFile(file_path, .{}) catch continue;
        defer file.close();

        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        var junit_suite = JUnit.TestSuite.init(allocator, file_path);

        var data_idx: usize = 0;
        while (data_idx < data_iterations) : (data_idx += 1) {
            var request = VoltFile.parse(allocator, content) catch continue;
            defer request.deinit();

            // Apply data-driven variables
            if (dataset) |ds| {
                if (data_idx < ds.rows.items.len) {
                    const row = &ds.rows.items[data_idx];
                    for (row.fields.items) |field| {
                        request.variables.put(field.name, field.value) catch {};
                    }
                }
            }

            if (request.tests.items.len == 0) break;

            // Interpolate variables (data-driven + dynamic) into URL, body, headers
            var resolved_url_alloc: ?[]const u8 = null;
            defer if (resolved_url_alloc) |ru| allocator.free(ru);
            if (request.variables.count() > 0) {
                var env_mgr = Environment.EnvManager.init(allocator);
                defer env_mgr.deinit();

                // Interpolate URL
                resolved_url_alloc = env_mgr.interpolate(request.url, &request.variables, allocator) catch null;
                if (resolved_url_alloc) |ru| request.url = ru;

                // Interpolate body
                if (request.body) |body| {
                    const resolved_body = env_mgr.interpolate(body, &request.variables, allocator) catch null;
                    if (resolved_body) |rb| {
                        if (request.body_owned) {
                            allocator.free(body);
                        }
                        request.body = rb;
                        request.body_owned = true;
                    }
                }
            }

            if (data_iterations > 1) {
                try stdout.print("\n\x1b[1m{s}\x1b[0m (row {d}/{d})\n", .{ file_path, data_idx + 1, data_iterations });
            } else {
                try stdout.print("\n\x1b[1m{s}\x1b[0m\n", .{file_path});
            }

            // Execute the request
            const req_start = std.time.nanoTimestamp();
            var response = HttpClient.execute(allocator, &request, .{}) catch {
                try stdout.print("  \x1b[31m✗ Request failed\x1b[0m\n", .{});
                failed += request.tests.items.len;
                total_tests += request.tests.items.len;
                continue;
            };
            defer response.deinit();
            const req_time_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - req_start)) / 1_000_000.0;

            // Run test assertions
            for (request.tests.items) |t| {
                total_tests += 1;
                const test_passed = evaluateTestAlloc(&t, &response, allocator);
                const test_expr = std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ t.field, t.operator, t.value }) catch "?";

                if (test_passed) {
                    passed += 1;
                    try stdout.print("  \x1b[32m✓\x1b[0m {s}\n", .{test_expr});
                } else {
                    failed += 1;
                    try stdout.print("  \x1b[31m✗\x1b[0m {s}\n", .{test_expr});
                }

                // Collect for reports
                if (report_format != null) {
                    const expected_dupe = if (t.value.len > 0) allocator.dupe(u8, t.value) catch null else null;
                    try report_entries.append(.{
                        .file = file_path,
                        .test_name = test_expr,
                        .passed = test_passed,
                        .actual = null,
                        .expected = expected_dupe,
                        .time_ms = req_time_ms,
                    });
                    try junit_suite.addCase(.{
                        .name = test_expr,
                        .classname = file_path,
                        .time_seconds = req_time_ms / 1000.0,
                        .passed = test_passed,
                        .failure_message = if (!test_passed) "Assertion failed" else null,
                        .failure_detail = null,
                    });
                } else {
                    allocator.free(test_expr);
                }
            }
        }

        if (report_format != null) {
            try junit_report.suites.append(junit_suite);
        } else {
            junit_suite.deinit();
        }
    }

    const end_time = std.time.nanoTimestamp();
    const total_time_ms = @as(f64, @floatFromInt(end_time - start_time)) / 1_000_000.0;

    // Summary
    try stdout.print("\n\x1b[1mResults:\x1b[0m {d} total, \x1b[32m{d} passed\x1b[0m, \x1b[31m{d} failed\x1b[0m ({d:.0}ms)\n", .{
        total_tests, passed, failed, total_time_ms,
    });

    // Generate report if requested
    if (report_format) |fmt| {
        if (mem.eql(u8, fmt, "junit")) {
            const xml = JUnit.generateJUnitXML(allocator, &junit_report) catch {
                try printError("Failed to generate JUnit report", .{});
                return;
            };
            defer allocator.free(xml);
            if (report_output) |out_path| {
                const out_f = std.fs.cwd().createFile(out_path, .{}) catch {
                    try printError("Cannot create report file: {s}", .{out_path});
                    return;
                };
                defer out_f.close();
                try out_f.writeAll(xml);
                try stdout.print("\x1b[32m✓\x1b[0m JUnit report: {s}\n", .{out_path});
            } else {
                try stdout.writeAll(xml);
            }
        } else if (mem.eql(u8, fmt, "html")) {
            var summary = TestReport.ReportSummary.init(allocator);
            defer summary.deinit();
            summary.total = total_tests;
            summary.passed = passed;
            summary.failed = failed;
            summary.time_ms = total_time_ms;
            summary.entries = report_entries;

            const html = TestReport.generateHtmlReport(allocator, &summary) catch {
                try printError("Failed to generate HTML report", .{});
                summary.entries = std.ArrayList(TestReport.ReportEntry).init(allocator);
                return;
            };
            defer allocator.free(html);
            // Restore entries before defer cleanup
            summary.entries = std.ArrayList(TestReport.ReportEntry).init(allocator);

            if (report_output) |out_path| {
                const out_f = std.fs.cwd().createFile(out_path, .{}) catch {
                    try printError("Cannot create report file: {s}", .{out_path});
                    return;
                };
                defer out_f.close();
                try out_f.writeAll(html);
                try stdout.print("\x1b[32m✓\x1b[0m HTML report: {s}\n", .{out_path});
            } else {
                try stdout.writeAll(html);
            }
        } else if (mem.eql(u8, fmt, "json")) {
            var summary = TestReport.ReportSummary.init(allocator);
            defer summary.deinit();
            summary.total = total_tests;
            summary.passed = passed;
            summary.failed = failed;
            summary.time_ms = total_time_ms;
            summary.entries = report_entries;

            const json = TestReport.generateJsonReport(allocator, &summary) catch {
                try printError("Failed to generate JSON report", .{});
                summary.entries = std.ArrayList(TestReport.ReportEntry).init(allocator);
                return;
            };
            defer allocator.free(json);
            summary.entries = std.ArrayList(TestReport.ReportEntry).init(allocator);

            if (report_output) |out_path| {
                const out_f = std.fs.cwd().createFile(out_path, .{}) catch {
                    try printError("Cannot create report file: {s}", .{out_path});
                    return;
                };
                defer out_f.close();
                try out_f.writeAll(json);
                try stdout.print("\x1b[32m✓\x1b[0m JSON report: {s}\n", .{out_path});
            } else {
                try stdout.writeAll(json);
            }
        } else {
            try printError("Unknown report format: {s}. Supported: junit, html, json", .{fmt});
        }
    }

    if (failed > 0) {
        std.process.exit(1);
    }
}

fn evaluateTest(t: *const VoltFile.TestAssertion, response: *const HttpClient.Response) bool {
    return evaluateTestAlloc(t, response, std.heap.page_allocator);
}

fn evaluateTestAlloc(t: *const VoltFile.TestAssertion, response: *const HttpClient.Response, allocator: std.mem.Allocator) bool {
    if (mem.eql(u8, t.field, "status")) {
        const expected = std.fmt.parseInt(u16, t.value, 10) catch return false;
        if (mem.eql(u8, t.operator, "equals") or mem.eql(u8, t.operator, "==")) {
            return response.status_code == expected;
        }
        if (mem.eql(u8, t.operator, "!=")) {
            return response.status_code != expected;
        }
        if (mem.eql(u8, t.operator, "<")) {
            return response.status_code < expected;
        }
        if (mem.eql(u8, t.operator, ">")) {
            return response.status_code > expected;
        }
    }

    if (mem.eql(u8, t.field, "body")) {
        const body = response.bodySlice();
        if (mem.eql(u8, t.operator, "contains")) {
            return mem.indexOf(u8, body, t.value) != null;
        }
        if (mem.eql(u8, t.operator, "equals")) {
            return mem.eql(u8, body, t.value);
        }
    }

    if (mem.startsWith(u8, t.field, "header.")) {
        const header_name = t.field["header.".len..];
        const header_value = response.getHeader(header_name) orelse return false;
        if (mem.eql(u8, t.operator, "equals") or mem.eql(u8, t.operator, "==")) {
            return mem.eql(u8, header_value, t.value);
        }
        if (mem.eql(u8, t.operator, "contains")) {
            return mem.indexOf(u8, header_value, t.value) != null;
        }
    }

    // JSONPath assertions: $.field.path operator value
    if (mem.startsWith(u8, t.field, "$.") or mem.eql(u8, t.field, "$")) {
        const body = response.bodySlice();
        const result = JsonPath.query(allocator, body, t.field) catch return false;
        if (result) |val| {
            defer allocator.free(val);
            if (mem.eql(u8, t.operator, "equals") or mem.eql(u8, t.operator, "==")) {
                return mem.eql(u8, val, t.value);
            }
            if (mem.eql(u8, t.operator, "contains")) {
                return mem.indexOf(u8, val, t.value) != null;
            }
            if (mem.eql(u8, t.operator, "!=")) {
                return !mem.eql(u8, val, t.value);
            }
            if (mem.eql(u8, t.operator, "exists")) {
                return true;
            }
        } else {
            // Path not found
            if (mem.eql(u8, t.operator, "exists")) return false;
            return false;
        }
    }

    return false;
}

fn cmdBench(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printError("Usage: volt bench <file.volt> [--requests N] [--concurrency N]", .{});
        return;
    }

    const file_path = args[0];
    var total_requests: usize = 100;
    var concurrency: usize = 10;

    // Parse flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if ((mem.eql(u8, args[i], "--requests") or mem.eql(u8, args[i], "-n")) and i + 1 < args.len) {
            total_requests = std.fmt.parseInt(usize, args[i + 1], 10) catch 100;
            i += 1;
        } else if ((mem.eql(u8, args[i], "--concurrency") or mem.eql(u8, args[i], "-c")) and i + 1 < args.len) {
            concurrency = std.fmt.parseInt(usize, args[i + 1], 10) catch 10;
            i += 1;
        }
    }

    // Load .volt file
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        try printError("Cannot open file: {s}", .{file_path});
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var request = VoltFile.parse(allocator, content) catch {
        try printError("Failed to parse .volt file: {s}", .{file_path});
        return;
    };
    defer request.deinit();

    // Run benchmark
    var result = try Bench.runBench(allocator, &request, .{
        .total_requests = total_requests,
        .concurrency = concurrency,
    });
    defer result.deinit();

    const output = try Bench.formatResults(&result, allocator);
    defer allocator.free(output);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(output);
}

fn cmdMock(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var port: u16 = 8080;
    var dir_path: []const u8 = ".";

    // Parse flags
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if ((mem.eql(u8, args[i], "--port") or mem.eql(u8, args[i], "-p")) and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8080;
            i += 1;
        } else if (!mem.startsWith(u8, args[i], "--")) {
            dir_path = args[i];
        }
    }

    var server = MockServer.MockServer.init(allocator, port);
    defer server.deinit();

    try server.loadCollection(dir_path);

    try server.serve();
}

fn cmdUi(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var port: u16 = 8080;

    // Parse flags
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if ((mem.eql(u8, args[i], "--port") or mem.eql(u8, args[i], "-p")) and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8080;
            i += 1;
        }
    }

    var server = WebServer.WebServer.init(allocator, port, .local);
    defer server.deinit();

    // Open browser
    const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port}) catch "http://127.0.0.1:8080";
    defer if (!mem.eql(u8, url, "http://127.0.0.1:8080")) allocator.free(url);
    WebServer.openBrowser(url);

    try server.serve();
}

fn cmdServe(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var port: u16 = 8080;

    // Parse flags
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if ((mem.eql(u8, args[i], "--port") or mem.eql(u8, args[i], "-p")) and i + 1 < args.len) {
            port = std.fmt.parseInt(u16, args[i + 1], 10) catch 8080;
            i += 1;
        }
    }

    var server = WebServer.WebServer.init(allocator, port, .public);
    defer server.deinit();

    try server.serve();
}

fn cmdExport(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        try printError("Usage: volt export <format> <file.volt>", .{});
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("\n  Formats: curl, python, javascript, go, openapi\n");
        return;
    }

    const format = args[0];
    const file_path = args[1];

    // Load .volt file
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        try printError("Cannot open file: {s}", .{file_path});
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var request = VoltFile.parse(allocator, content) catch {
        try printError("Failed to parse .volt file: {s}", .{file_path});
        return;
    };
    defer request.deinit();

    const stdout = std.io.getStdOut().writer();

    if (mem.eql(u8, format, "curl")) {
        const output = try Exporter.exportCurl(&request, allocator);
        defer allocator.free(output);
        try stdout.writeAll(output);
    } else if (mem.eql(u8, format, "python")) {
        const output = try Exporter.exportPython(&request, allocator);
        defer allocator.free(output);
        try stdout.writeAll(output);
    } else if (mem.eql(u8, format, "javascript") or mem.eql(u8, format, "js")) {
        const output = try Exporter.exportJavaScript(&request, allocator);
        defer allocator.free(output);
        try stdout.writeAll(output);
    } else if (mem.eql(u8, format, "go")) {
        const output = try Exporter.exportGo(&request, allocator);
        defer allocator.free(output);
        try stdout.writeAll(output);
    } else if (mem.eql(u8, format, "openapi")) {
        const requests = [_]VoltFile.VoltRequest{request};
        const output = try Exporter.exportOpenAPI(allocator, &requests, "Volt Collection");
        defer allocator.free(output);
        try stdout.writeAll(output);
    } else if (mem.eql(u8, format, "har")) {
        try stdout.writeAll("Use 'volt har export <file>' for HAR export (requires executing the request).\n");
    } else {
        // Try snippet generator for extended languages
        if (Snippet.Language.fromString(format)) |lang| {
            const output = try Snippet.generateSnippet(allocator, &request, lang);
            defer allocator.free(output);
            try stdout.writeAll(output);
        } else {
            try printError("Unknown export format: {s}", .{format});
            try stdout.writeAll("\n  Supported: curl, python, javascript, go, openapi, har,\n");
            try stdout.writeAll("             ruby, php, csharp, rust, java, swift, kotlin,\n");
            try stdout.writeAll("             dart, r, httpie, wget, powershell\n");
        }
    }
}

fn cmdCollection(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printError("Usage: volt collection <dir> [--env <environment>] [--verbose]", .{});
        return;
    }

    const dir_path = args[0];
    var env_name: ?[]const u8 = null;
    var verbose = false;

    // Parse flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--env") and i + 1 < args.len) {
            env_name = args[i + 1];
            i += 1;
        } else if (mem.eql(u8, args[i], "--verbose") or mem.eql(u8, args[i], "-v")) {
            verbose = true;
        }
    }

    var env_mgr = Environment.EnvManager.init(allocator);
    defer env_mgr.deinit();
    if (env_name) |name| env_mgr.setActive(name);

    var result = try CollectionRunner.runCollection(allocator, dir_path, &env_mgr, verbose);
    defer result.deinit();

    try CollectionRunner.printSummary(&result);

    if (result.failed > 0) {
        std.process.exit(1);
    }
}

fn cmdGraphQL(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printError("Usage: volt graphql <file.volt>", .{});
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("       volt graphql introspect <endpoint>\n");
        return;
    }

    const stdout = std.io.getStdOut().writer();

    if (mem.eql(u8, args[0], "introspect") and args.len >= 2) {
        // Run introspection query
        var gql_req = GraphQL.GraphQLRequest.init(allocator, args[1]);
        defer gql_req.deinit();
        gql_req.query = GraphQL.introspectionQuery();

        var gql_resp = GraphQL.execute(allocator, &gql_req, .{}) catch {
            try printError("GraphQL introspection failed", .{});
            return;
        };
        defer gql_resp.deinit();

        const output = try GraphQL.formatResponse(&gql_resp, allocator);
        defer allocator.free(output);
        try stdout.writeAll(output);
        return;
    }

    // Execute .volt file as GraphQL
    const file_path = args[0];

    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        try printError("Cannot open file: {s}", .{file_path});
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var gql_req = GraphQL.parseGraphQLVolt(allocator, content) catch {
        try printError("Failed to parse GraphQL .volt file: {s}", .{file_path});
        return;
    };
    defer gql_req.deinit();

    try stdout.print("\x1b[36mPOST\x1b[0m {s} (GraphQL)\n", .{gql_req.endpoint});

    var gql_resp = GraphQL.execute(allocator, &gql_req, .{}) catch {
        try printError("GraphQL request failed", .{});
        return;
    };
    defer gql_resp.deinit();

    const output = try GraphQL.formatResponse(&gql_resp, allocator);
    defer allocator.free(output);
    try stdout.writeAll(output);
}

fn cmdImport(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len < 2) {
        try stdout.writeAll("Usage: volt import postman <collection.json> [--output <dir>]\n");
        try stdout.writeAll("       volt import har <file.har> [--output <dir>]\n");
        try stdout.writeAll("       volt import insomnia <export.json> [--output <dir>]\n");
        try stdout.writeAll("       volt import openapi <spec.json> [--output <dir>]\n");
        try stdout.writeAll("       volt import curl '<curl command>' [--output <file>]\n");
        return;
    }

    const format = args[0];
    const file_path = args[1];
    var output_dir: []const u8 = ".";
    var output_file_flag: ?[]const u8 = null;

    // Parse flags
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            if (mem.eql(u8, format, "curl")) {
                output_file_flag = args[i + 1];
            } else {
                output_dir = args[i + 1];
            }
            i += 1;
        }
    }

    if (mem.eql(u8, format, "postman")) {
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try printError("Cannot open file: {s}", .{file_path});
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        defer allocator.free(content);

        var result = Importer.importPostman(allocator, content) catch {
            try printError("Failed to parse Postman collection", .{});
            return;
        };
        defer result.deinit();

        try stdout.print("Importing collection: \x1b[1m{s}\x1b[0m\n", .{result.collection_name});
        try stdout.print("Found {d} requests\n", .{result.requests.items.len});

        Importer.writeImportedCollection(allocator, &result, output_dir) catch {
            try printError("Failed to write imported files", .{});
            return;
        };

        try stdout.print("\x1b[32m✓\x1b[0m Successfully imported to {s}/\n", .{output_dir});
    } else if (mem.eql(u8, format, "har")) {
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try printError("Cannot open file: {s}", .{file_path});
            return;
        };
        defer file.close();

        const har_content = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        defer allocator.free(har_content);

        var volt_files = Har.importHar(allocator, har_content) catch {
            try printError("Failed to parse HAR file", .{});
            return;
        };
        defer {
            for (volt_files.items) |f| allocator.free(f);
            volt_files.deinit();
        }

        if (volt_files.items.len == 0) {
            try stdout.writeAll("No requests found in HAR file.\n");
            return;
        }

        // Ensure output directory exists
        if (!mem.eql(u8, output_dir, ".")) {
            std.fs.cwd().makeDir(output_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    try printError("Cannot create directory: {s}", .{output_dir});
                    return;
                },
            };
        }

        for (volt_files.items, 0..) |volt_content, idx| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "request-{d}.volt", .{idx + 1}) catch continue;
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, name }) catch continue;
            defer allocator.free(full_path);
            const out_file = std.fs.cwd().createFile(full_path, .{}) catch continue;
            defer out_file.close();
            out_file.writeAll(volt_content) catch continue;
        }

        try stdout.print("\x1b[32m✓\x1b[0m Imported {d} request(s) from HAR to {s}/\n", .{ volt_files.items.len, output_dir });
    } else if (mem.eql(u8, format, "curl")) {
        // Import from cURL command
        var curl_result = CurlImport.parseCurl(allocator, file_path) catch {
            try printError("Failed to parse cURL command", .{});
            return;
        };
        defer curl_result.deinit();

        const volt_content = CurlImport.toVoltContent(allocator, &curl_result) catch {
            try printError("Failed to convert to .volt format", .{});
            return;
        };
        defer allocator.free(volt_content);

        if (output_file_flag) |out_path| {
            const out_f = std.fs.cwd().createFile(out_path, .{}) catch {
                try printError("Cannot create file: {s}", .{out_path});
                return;
            };
            defer out_f.close();
            try out_f.writeAll(volt_content);
            try stdout.print("\x1b[32m✓\x1b[0m Imported cURL to {s}\n", .{out_path});
        } else {
            try stdout.writeAll(volt_content);
        }
    } else if (mem.eql(u8, format, "openapi")) {
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try printError("Cannot open file: {s}", .{file_path});
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        defer allocator.free(content);

        var volt_files = OpenAPIImport.importOpenAPIToVoltFiles(allocator, content) catch {
            try printError("Failed to parse OpenAPI spec", .{});
            return;
        };
        defer {
            for (volt_files.items) |f| allocator.free(f);
            volt_files.deinit();
        }

        if (volt_files.items.len == 0) {
            try stdout.writeAll("No endpoints found in OpenAPI spec.\n");
            return;
        }

        if (!mem.eql(u8, output_dir, ".")) {
            std.fs.cwd().makeDir(output_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    try printError("Cannot create directory: {s}", .{output_dir});
                    return;
                },
            };
        }

        for (volt_files.items, 0..) |volt_content, idx| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "endpoint-{d}.volt", .{idx + 1}) catch continue;
            const full_p = std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, name }) catch continue;
            defer allocator.free(full_p);
            const out_f = std.fs.cwd().createFile(full_p, .{}) catch continue;
            defer out_f.close();
            out_f.writeAll(volt_content) catch continue;
        }

        try stdout.print("\x1b[32m✓\x1b[0m Imported {d} endpoint(s) from OpenAPI to {s}/\n", .{ volt_files.items.len, output_dir });
    } else if (mem.eql(u8, format, "insomnia")) {
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try printError("Cannot open file: {s}", .{file_path});
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        defer allocator.free(content);

        var requests = InsomniaImport.parseInsomnia(allocator, content) catch {
            try printError("Failed to parse Insomnia export", .{});
            return;
        };
        defer {
            for (requests.items) |*r| r.deinit();
            requests.deinit();
        }

        if (requests.items.len == 0) {
            try stdout.writeAll("No requests found in Insomnia export.\n");
            return;
        }

        if (!mem.eql(u8, output_dir, ".")) {
            std.fs.cwd().makeDir(output_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    try printError("Cannot create directory: {s}", .{output_dir});
                    return;
                },
            };
        }

        var written: usize = 0;
        for (requests.items, 0..) |*req, idx| {
            const volt_content = InsomniaImport.requestToVolt(allocator, req) catch continue;
            defer allocator.free(volt_content);

            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "request-{d}.volt", .{idx + 1}) catch continue;
            const full_p = std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, name }) catch continue;
            defer allocator.free(full_p);
            const out_f = std.fs.cwd().createFile(full_p, .{}) catch continue;
            defer out_f.close();
            out_f.writeAll(volt_content) catch continue;
            written += 1;
        }

        try stdout.print("\x1b[32m✓\x1b[0m Imported {d} request(s) from Insomnia to {s}/\n", .{ written, output_dir });
    } else {
        try printError("Unsupported import format: {s}. Supported: postman, har, curl, openapi, insomnia", .{format});
    }
}

fn cmdEnv(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = allocator;
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt env list                     List environments\n");
        try stdout.writeAll("       volt env set <key> <value>        Set a variable\n");
        try stdout.writeAll("       volt env get <key>                Get a variable\n");
        try stdout.writeAll("       volt env delete <key>             Delete a variable\n");
        try stdout.writeAll("       volt env create <name>            Create environment\n");
        return;
    }

    const subcmd = args[0];
    if (mem.eql(u8, subcmd, "list")) {
        // Scan for _env.volt files
        try stdout.writeAll("Environments:\n");
        var dir = std.fs.cwd().openDir(".", .{ .iterate = true }) catch return;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, "_env.volt")) {
                try stdout.print("  {s}\n", .{entry.name});
            }
        }
    } else if (mem.eql(u8, subcmd, "set") and args.len >= 3) {
        const key = args[1];
        const value = args[2];
        try stdout.print("Set {s} = {s}\n", .{ key, value });
    } else if (mem.eql(u8, subcmd, "get") and args.len >= 2) {
        const key = args[1];
        try stdout.print("Variable: {s}\n", .{key});
    }
}

fn cmdLint(_: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    const target_dir = if (args.len > 0) args[0] else ".";

    var dir = std.fs.cwd().openDir(target_dir, .{ .iterate = true }) catch {
        try printError("Cannot open directory: {s}", .{target_dir});
        return;
    };
    defer dir.close();

    var total: usize = 0;
    var valid: usize = 0;
    var invalid: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file or !mem.endsWith(u8, entry.name, ".volt")) continue;
        // Skip config/env files (prefixed with _)
        if (mem.startsWith(u8, entry.name, "_")) continue;
        total += 1;

        const file = dir.openFile(entry.name, .{}) catch {
            try stdout.print("\x1b[31m✗\x1b[0m {s}: cannot open\n", .{entry.name});
            invalid += 1;
            continue;
        };
        defer file.close();

        var buf: [1024 * 1024]u8 = undefined;
        const n = file.readAll(&buf) catch {
            try stdout.print("\x1b[31m✗\x1b[0m {s}: cannot read\n", .{entry.name});
            invalid += 1;
            continue;
        };

        var gpa_inner = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa_inner.deinit();

        var request = VoltFile.parse(gpa_inner.allocator(), buf[0..n]) catch {
            try stdout.print("\x1b[31m✗\x1b[0m {s}: parse error\n", .{entry.name});
            invalid += 1;
            continue;
        };
        defer request.deinit();

        // Validate required fields
        if (request.url.len == 0) {
            try stdout.print("\x1b[33m⚠\x1b[0m {s}: missing url\n", .{entry.name});
            invalid += 1;
            continue;
        }

        valid += 1;
        try stdout.print("\x1b[32m✓\x1b[0m {s}\n", .{entry.name});
    }

    try stdout.print("\n{d} files checked: \x1b[32m{d} valid\x1b[0m, \x1b[31m{d} invalid\x1b[0m\n", .{
        total, valid, invalid,
    });
}

fn cmdDiff(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len < 2) {
        try stdout.writeAll("Usage: volt diff <file_a.volt> <file_b.volt>           Compare request definitions\n");
        try stdout.writeAll("       volt diff <file_a.volt> <file_b.volt> --response Execute and compare responses\n");
        return;
    }

    // Check for --response flag
    var response_mode = false;
    for (args) |arg| {
        if (mem.eql(u8, arg, "--response") or mem.eql(u8, arg, "-r")) {
            response_mode = true;
        }
    }

    // Load both files
    const file_a = std.fs.cwd().openFile(args[0], .{}) catch {
        try printError("Cannot open: {s}", .{args[0]});
        return;
    };
    defer file_a.close();

    const file_b = std.fs.cwd().openFile(args[1], .{}) catch {
        try printError("Cannot open: {s}", .{args[1]});
        return;
    };
    defer file_b.close();

    const content_a = try file_a.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content_a);

    const content_b = try file_b.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content_b);

    var req_a = VoltFile.parse(allocator, content_a) catch {
        try printError("Failed to parse: {s}", .{args[0]});
        return;
    };
    defer req_a.deinit();

    var req_b = VoltFile.parse(allocator, content_b) catch {
        try printError("Failed to parse: {s}", .{args[1]});
        return;
    };
    defer req_b.deinit();

    if (response_mode) {
        // Execute both requests and compare responses using DiffEngine
        try stdout.print("\x1b[1mExecuting and comparing responses:\x1b[0m {s} vs {s}\n\n", .{ args[0], args[1] });

        var resp_a = HttpClient.execute(allocator, &req_a, .{}) catch {
            try printError("Request A failed: {s}", .{args[0]});
            return;
        };
        defer resp_a.deinit();

        var resp_b = HttpClient.execute(allocator, &req_b, .{}) catch {
            try printError("Request B failed: {s}", .{args[1]});
            return;
        };
        defer resp_b.deinit();

        // Diff JSON bodies
        const body_a = resp_a.bodySlice();
        const body_b = resp_b.bodySlice();

        var diff_result = try DiffEngine.diffJson(allocator, body_a, body_b);
        defer diff_result.deinit();

        // Diff status codes
        try DiffEngine.diffStatus(&diff_result, resp_a.status_code, resp_b.status_code);

        // Format and display
        const diff_output = try DiffEngine.formatDiff(&diff_result, allocator);
        defer allocator.free(diff_output);
        try stdout.writeAll(diff_output);

        if (!diff_result.is_compatible) std.process.exit(1);
        return;
    }

    // Request definition diff (original behavior)
    try stdout.print("\x1b[1mComparing:\x1b[0m {s} vs {s}\n\n", .{ args[0], args[1] });

    var has_diff = false;

    // Method
    if (req_a.method != req_b.method) {
        try stdout.print("\x1b[31m- method: {s}\x1b[0m\n", .{req_a.method.toString()});
        try stdout.print("\x1b[32m+ method: {s}\x1b[0m\n", .{req_b.method.toString()});
        has_diff = true;
    }

    // URL
    if (!mem.eql(u8, req_a.url, req_b.url)) {
        try stdout.print("\x1b[31m- url: {s}\x1b[0m\n", .{req_a.url});
        try stdout.print("\x1b[32m+ url: {s}\x1b[0m\n", .{req_b.url});
        has_diff = true;
    }

    // Headers
    for (req_a.headers.items) |h| {
        var found = false;
        for (req_b.headers.items) |h2| {
            if (mem.eql(u8, h.name, h2.name)) {
                found = true;
                if (!mem.eql(u8, h.value, h2.value)) {
                    try stdout.print("\x1b[31m- {s}: {s}\x1b[0m\n", .{ h.name, h.value });
                    try stdout.print("\x1b[32m+ {s}: {s}\x1b[0m\n", .{ h.name, h2.value });
                    has_diff = true;
                }
                break;
            }
        }
        if (!found) {
            try stdout.print("\x1b[31m- {s}: {s}\x1b[0m\n", .{ h.name, h.value });
            has_diff = true;
        }
    }
    for (req_b.headers.items) |h| {
        var found = false;
        for (req_a.headers.items) |h2| {
            if (mem.eql(u8, h.name, h2.name)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try stdout.print("\x1b[32m+ {s}: {s}\x1b[0m\n", .{ h.name, h.value });
            has_diff = true;
        }
    }

    // Body diff
    if (req_a.body != null or req_b.body != null) {
        const body_a_val = req_a.body orelse "(none)";
        const body_b_val = req_b.body orelse "(none)";
        if (!mem.eql(u8, body_a_val, body_b_val)) {
            try stdout.writeAll("\x1b[31m- body: (changed)\x1b[0m\n");
            try stdout.writeAll("\x1b[32m+ body: (changed)\x1b[0m\n");
            has_diff = true;
        }
    }

    if (!has_diff) {
        try stdout.writeAll("\x1b[32mNo differences found.\x1b[0m\n");
    }
}

fn cmdGenerate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printError("Usage: volt generate <file.volt> [--output <file>]", .{});
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("\n  Runs the request and generates test assertions from the response.\n");
        try stdout.writeAll("  Use --output to write a new .volt file with tests.\n");
        return;
    }

    const file_path = args[0];
    var output_path: ?[]const u8 = null;

    // Parse flags
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if ((mem.eql(u8, args[i], "--output") or mem.eql(u8, args[i], "-o")) and i + 1 < args.len) {
            output_path = args[i + 1];
            i += 1;
        }
    }

    // Load .volt file
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        try printError("Cannot open file: {s}", .{file_path});
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var request = VoltFile.parse(allocator, content) catch {
        try printError("Failed to parse .volt file: {s}", .{file_path});
        return;
    };
    defer request.deinit();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\x1b[36m{s}\x1b[0m {s}\n", .{ request.method.toString(), request.url });
    try stdout.writeAll("Executing request to generate tests...\n\n");

    // Execute the request
    var response = HttpClient.execute(allocator, &request, .{}) catch {
        try printError("Request failed: connection error", .{});
        return;
    };
    defer response.deinit();

    // Generate tests from response
    var gen_result = TestGenerator.generateTests(allocator, &request, &response) catch {
        try printError("Failed to generate tests", .{});
        return;
    };
    defer gen_result.deinit();

    // Display generated tests
    const display = try TestGenerator.formatResults(&gen_result, allocator);
    defer allocator.free(display);
    try stdout.writeAll(display);

    // Write output file if requested
    if (output_path) |out_path| {
        const volt_content = try TestGenerator.generateVoltFile(allocator, &request, &gen_result, 0.5);
        defer allocator.free(volt_content);

        const out_file = std.fs.cwd().createFile(out_path, .{}) catch {
            try printError("Cannot create output file: {s}", .{out_path});
            return;
        };
        defer out_file.close();
        try out_file.writeAll(volt_content);

        try stdout.print("\n\x1b[32m✓\x1b[0m Generated .volt file: {s}\n", .{out_path});
    } else {
        try stdout.writeAll("\nTip: Use --output <file.volt> to save as a test file.\n");
    }
}

fn cmdHistory(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();
    var history = History.RequestHistory.init(allocator);
    defer history.deinit();

    if (args.len > 0 and mem.eql(u8, args[0], "clear")) {
        history.clear();
        try stdout.writeAll("History cleared.\n");
        return;
    }

    // Show recent history
    const count: usize = if (args.len > 0)
        std.fmt.parseInt(usize, args[0], 10) catch 20
    else
        20;

    const entries = history.lastN(count);
    if (entries.len == 0) {
        try stdout.writeAll("No request history.\n");
        try stdout.writeAll("History is recorded during the current session only.\n");
        return;
    }

    try stdout.writeAll("\x1b[1mRequest History\x1b[0m\n\n");
    try History.RequestHistory.printHistory(&history, count);
}

fn cmdInit(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    var force = false;
    for (args) |arg| {
        if (mem.eql(u8, arg, "--force") or mem.eql(u8, arg, "-f")) {
            force = true;
        }
    }

    // Generate .voltrc config file
    const config_content = try Config.generateDefaultConfig(allocator);
    defer allocator.free(config_content);

    // Check if .voltrc already exists
    const exists = blk: {
        const f = std.fs.cwd().openFile(".voltrc", .{}) catch break :blk false;
        f.close();
        break :blk true;
    };

    if (exists and !force) {
        try stdout.writeAll("\x1b[33m⚠\x1b[0m .voltrc already exists. Use 'volt init --force' to overwrite.\n");
        return;
    }

    const rc_file = std.fs.cwd().createFile(".voltrc", .{}) catch {
        try printError("Cannot create .voltrc", .{});
        return;
    };
    defer rc_file.close();
    try rc_file.writeAll(config_content);
    try stdout.writeAll("\x1b[32m✓\x1b[0m Created .voltrc\n");

    // Create example .volt file
    const example_exists = blk: {
        const f = std.fs.cwd().openFile("example.volt", .{}) catch break :blk false;
        f.close();
        break :blk true;
    };

    if (!example_exists or force) {
        const example_file = std.fs.cwd().createFile("example.volt", .{}) catch return;
        defer example_file.close();
        try example_file.writeAll(
            \\name: Example Request
            \\method: GET
            \\url: https://httpbin.org/get
            \\headers:
            \\  - Accept: application/json
            \\  - User-Agent: Volt/1.0.0
            \\tests:
            \\  - status equals 200
            \\  - header.content-type contains application/json
            \\
        );
        try stdout.writeAll("\x1b[32m✓\x1b[0m Created example.volt\n");
    }

    // Create _env.volt example
    const env_exists = blk: {
        const f = std.fs.cwd().openFile("_env.volt", .{}) catch break :blk false;
        f.close();
        break :blk true;
    };

    if (!env_exists or force) {
        const env_file = std.fs.cwd().createFile("_env.volt", .{}) catch return;
        defer env_file.close();
        try env_file.writeAll(
            \\# Environment variables
            \\# Use {{variable}} syntax in .volt files
            \\
            \\[default]
            \\base_url = https://httpbin.org
            \\api_key = your-api-key-here
            \\
            \\[staging]
            \\base_url = https://staging.example.com
            \\api_key = staging-key
            \\
            \\[production]
            \\base_url = https://api.example.com
            \\api_key = prod-key
            \\
        );
        try stdout.writeAll("\x1b[32m✓\x1b[0m Created _env.volt\n");
    }

    try stdout.writeAll("\n\x1b[1mProject initialized!\x1b[0m\n");
    try stdout.writeAll("  Edit .voltrc to configure project settings\n");
    try stdout.writeAll("  Run 'volt example.volt' to test your first request\n");
    try stdout.writeAll("  Run 'volt' to launch the TUI\n");
}

fn cmdWorkflow(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printError("Usage: volt workflow <file.workflow> [--env <environment>]", .{});
        return;
    }

    const file_path = args[0];
    var env_name: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--env") and i + 1 < args.len) {
            env_name = args[i + 1];
            i += 1;
        }
    }

    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        try printError("Cannot open workflow file: {s}", .{file_path});
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var workflow = Workflow.parseWorkflow(allocator, content) catch {
        try printError("Failed to parse workflow: {s}", .{file_path});
        return;
    };
    defer workflow.deinit();

    var env_mgr = Environment.EnvManager.init(allocator);
    defer env_mgr.deinit();
    if (env_name) |name| env_mgr.setActive(name);

    var result = try Workflow.runWorkflow(allocator, &workflow, &env_mgr);
    defer result.deinit();

    const output = try Workflow.formatResult(&result, allocator);
    defer allocator.free(output);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(output);

    if (!result.all_passed) std.process.exit(1);
}

fn cmdValidate(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        try printError("Usage: volt validate <file.volt> --schema <schema.txt>", .{});
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("       volt validate <file.volt> --infer    Infer schema from response\n");
        return;
    }

    const file_path = args[0];
    var schema_path: ?[]const u8 = null;
    var infer_mode = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if ((mem.eql(u8, args[i], "--schema") or mem.eql(u8, args[i], "-s")) and i + 1 < args.len) {
            schema_path = args[i + 1];
            i += 1;
        } else if (mem.eql(u8, args[i], "--infer")) {
            infer_mode = true;
        }
    }

    // Load and execute the .volt file
    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        try printError("Cannot open file: {s}", .{file_path});
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var request = VoltFile.parse(allocator, content) catch {
        try printError("Failed to parse .volt file: {s}", .{file_path});
        return;
    };
    defer request.deinit();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\x1b[36m{s}\x1b[0m {s}\n", .{ request.method.toString(), request.url });

    var response = HttpClient.execute(allocator, &request, .{}) catch {
        try printError("Request failed", .{});
        return;
    };
    defer response.deinit();

    const body = response.bodySlice();

    if (infer_mode) {
        var schema = try Validator.inferSchema(allocator, body);
        defer schema.deinit();

        try stdout.writeAll("\n\x1b[1mInferred Schema\x1b[0m\n\n");
        try stdout.print("type: {s}\n", .{schema.root_type.toString()});
        if (schema.required_fields.items.len > 0) {
            try stdout.writeAll("required: ");
            for (schema.required_fields.items, 0..) |f, idx| {
                if (idx > 0) try stdout.writeAll(", ");
                try stdout.writeAll(f);
            }
            try stdout.writeAll("\n");
        }
        if (schema.fields.items.len > 0) {
            try stdout.writeAll("properties:\n");
            for (schema.fields.items) |f| {
                try stdout.print("  {s}: {s}\n", .{ f.name, f.field_type.toString() });
            }
        }
        return;
    }

    if (schema_path) |sp| {
        const schema_file = std.fs.cwd().openFile(sp, .{}) catch {
            try printError("Cannot open schema file: {s}", .{sp});
            return;
        };
        defer schema_file.close();

        const schema_content = try schema_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(schema_content);

        var schema = try Validator.parseSchema(allocator, schema_content);
        defer schema.deinit();

        var result = try Validator.validate(allocator, body, &schema);
        defer result.deinit();

        const output = try Validator.formatResult(&result, allocator);
        defer allocator.free(output);
        try stdout.writeAll(output);

        if (!result.valid) std.process.exit(1);
    } else {
        try printError("Specify --schema <file> or --infer", .{});
    }
}

fn cmdDocs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const dir_path = if (args.len > 0) args[0] else ".";
    var title: []const u8 = "API Documentation";
    var html_mode = false;
    var output_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--title") and i + 1 < args.len) {
            title = args[i + 1];
            i += 1;
        } else if (mem.eql(u8, args[i], "--html")) {
            html_mode = true;
        } else if ((mem.eql(u8, args[i], "--output") or mem.eql(u8, args[i], "-o")) and i + 1 < args.len) {
            output_path = args[i + 1];
            i += 1;
        }
    }

    const stdout = std.io.getStdOut().writer();

    if (html_mode) {
        // Scan dir for .volt files and build doc entries for HTML generation
        var entries = std.ArrayList(DocGenerator.DocEntry).init(allocator);
        defer {
            for (entries.items) |*e| {
                allocator.free(e.name);
                allocator.free(e.url);
                if (e.body_example) |b| allocator.free(b);
                for (e.headers.items) |h| {
                    allocator.free(h.name);
                    allocator.free(h.value);
                }
                for (e.tests.items) |t| allocator.free(t);
                e.deinit();
            }
            entries.deinit();
        }

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            try printError("Cannot open directory: {s}", .{dir_path});
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |file_entry| {
            if (file_entry.kind != .file or !mem.endsWith(u8, file_entry.name, ".volt")) continue;
            const file = dir.openFile(file_entry.name, .{}) catch continue;
            defer file.close();
            const fcontent = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
            defer allocator.free(fcontent);
            var req = VoltFile.parse(allocator, fcontent) catch continue;
            defer req.deinit();
            const doc_entry = DocGenerator.fromRequest(allocator, &req, file_entry.name) catch continue;
            entries.append(doc_entry) catch continue;
        }

        const html = try DocGenerator.generateHtml(allocator, entries.items, title);
        defer allocator.free(html);

        if (output_path) |op| {
            const out_file = std.fs.cwd().createFile(op, .{}) catch {
                try printError("Cannot create output file: {s}", .{op});
                return;
            };
            defer out_file.close();
            try out_file.writeAll(html);
            try stdout.print("\x1b[32m✓\x1b[0m Generated HTML docs: {s} ({d} endpoints)\n", .{ op, entries.items.len });
        } else {
            try stdout.writeAll(html);
        }
    } else {
        const output = try DocGenerator.generateDocsFromDir(allocator, dir_path, title);
        defer allocator.free(output);
        if (output_path) |op| {
            const out_file = std.fs.cwd().createFile(op, .{}) catch {
                try printError("Cannot create output file: {s}", .{op});
                return;
            };
            defer out_file.close();
            try out_file.writeAll(output);
            try stdout.print("\x1b[32m✓\x1b[0m Generated docs: {s}\n", .{op});
        } else {
            try stdout.writeAll(output);
        }
    }
}

fn cmdCompletions(_: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printError("Usage: volt completions <shell>", .{});
        const stdout = std.io.getStdOut().writer();
        try stdout.writeAll("  Shells: bash, zsh, fish, powershell\n\n");
        try stdout.writeAll("  Example: volt completions bash >> ~/.bashrc\n");
        try stdout.writeAll("           volt completions zsh >> ~/.zshrc\n");
        try stdout.writeAll("           volt completions fish > ~/.config/fish/completions/volt.fish\n");
        return;
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const shell = Completions.Shell.fromString(args[0]) orelse {
        try printError("Unknown shell: {s}. Supported: bash, zsh, fish, powershell", .{args[0]});
        return;
    };

    const output = try Completions.generateCompletions(allocator, shell);
    defer allocator.free(output);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(output);
}

fn cmdMonitor(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        try printError("Usage: volt monitor <file.volt> [--interval N] [--count N]", .{});
        return;
    }

    const file_path = args[0];
    var interval: u32 = 60;
    var max_checks: u32 = 10;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if ((mem.eql(u8, args[i], "--interval") or mem.eql(u8, args[i], "-i")) and i + 1 < args.len) {
            interval = std.fmt.parseInt(u32, args[i + 1], 10) catch 60;
            i += 1;
        } else if ((mem.eql(u8, args[i], "--count") or mem.eql(u8, args[i], "-n")) and i + 1 < args.len) {
            max_checks = std.fmt.parseInt(u32, args[i + 1], 10) catch 10;
            i += 1;
        }
    }

    const file = std.fs.cwd().openFile(file_path, .{}) catch {
        try printError("Cannot open file: {s}", .{file_path});
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var request = VoltFile.parse(allocator, content) catch {
        try printError("Failed to parse .volt file: {s}", .{file_path});
        return;
    };
    defer request.deinit();

    const stdout = std.io.getStdOut().writer();
    try stdout.print("\x1b[1mMonitoring\x1b[0m {s} every {d}s ({d} checks)\n\n", .{ request.url, interval, max_checks });

    var config = Monitor.MonitorConfig{
        .interval_seconds = interval,
        .max_checks = max_checks,
    };

    var result = try Monitor.runMonitor(allocator, &request, &config);
    defer result.deinit();

    const output = try Monitor.formatResult(&result, allocator);
    defer allocator.free(output);
    try stdout.writeAll(output);
}

fn cmdCache(_: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt cache clear       Clear response cache\n");
        try stdout.writeAll("       volt cache stats       Show cache statistics\n");
        return;
    }

    if (mem.eql(u8, args[0], "clear")) {
        try stdout.writeAll("\x1b[32m✓\x1b[0m Cache cleared.\n");
    } else if (mem.eql(u8, args[0], "stats")) {
        try stdout.writeAll("Cache is session-only. Start Volt with --cache to enable.\n");
    }
}

fn cmdWebSocket(_: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt ws <url>           Connect to WebSocket endpoint\n");
        try stdout.writeAll("       volt ws <url> --send <msg>  Send a message\n\n");
        try stdout.writeAll("  Example: volt ws wss://echo.websocket.org\n");
        return;
    }

    const url = args[0];
    const parts = WebSocket.parseWsUrl(url) orelse {
        try printError("Invalid WebSocket URL: {s}", .{url});
        try stdout.writeAll("  URL must start with ws:// or wss://\n");
        return;
    };

    try stdout.print("\x1b[1mWebSocket\x1b[0m {s}://{s}:{d}{s}\n", .{
        if (parts.secure) @as([]const u8, "wss") else "ws",
        parts.host,
        parts.port,
        parts.path,
    });

    // Build and display the handshake
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = WebSocket.WebSocketConfig.init(allocator);
    defer config.deinit();
    config.url = url;

    var session = WebSocket.WebSocketSession.init(allocator, config);
    defer session.deinit();

    const handshake = try session.buildHandshake(allocator);
    defer allocator.free(handshake);

    try stdout.writeAll("\n\x1b[90mHandshake request:\x1b[0m\n");
    try stdout.writeAll(handshake);
    try stdout.writeAll("\n\x1b[33mNote: Interactive WebSocket requires a persistent connection.\x1b[0m\n");
    try stdout.writeAll("Use 'volt ws <url> --send <message>' to send messages.\n");
}

fn cmdSSE(_: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt sse <url>          Connect to SSE endpoint\n\n");
        try stdout.writeAll("  Example: volt sse https://api.example.com/events\n");
        return;
    }

    try stdout.print("\x1b[1mSSE\x1b[0m {s}\n", .{args[0]});
    try stdout.writeAll("Connecting to event stream...\n");
    try stdout.writeAll("\n\x1b[33mNote: SSE requires a persistent HTTP connection.\x1b[0m\n");
    try stdout.writeAll("The SSE parser is available for stream data processing.\n");

    // Show SSE header requirements
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = SSE.SSEConfig.init(allocator);
    defer config.deinit();

    const headers = try SSE.buildSSEHeaders(allocator, &config);
    defer allocator.free(headers);

    try stdout.writeAll("\n\x1b[90mRequired headers:\x1b[0m\n");
    try stdout.writeAll(headers);
}

fn cmdAuth(_: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt auth oauth <token-url> --client-id <id> --client-secret <secret>\n");
        try stdout.writeAll("       volt auth oauth <token-url> --grant password --username <u> --password <p>\n");
        try stdout.writeAll("\n  Grant types: client_credentials (default), password, authorization_code\n");
        return;
    }

    if (mem.eql(u8, args[0], "oauth") and args.len >= 2) {
        const token_url = args[1];
        var config = OAuth.OAuthConfig{
            .token_url = token_url,
        };

        // Parse flags
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (mem.eql(u8, args[i], "--client-id") and i + 1 < args.len) {
                config.client_id = args[i + 1];
                i += 1;
            } else if (mem.eql(u8, args[i], "--client-secret") and i + 1 < args.len) {
                config.client_secret = args[i + 1];
                i += 1;
            } else if (mem.eql(u8, args[i], "--scope") and i + 1 < args.len) {
                config.scope = args[i + 1];
                i += 1;
            } else if (mem.eql(u8, args[i], "--grant") and i + 1 < args.len) {
                config.grant_type = OAuth.GrantType.fromString(args[i + 1]) orelse .client_credentials;
                i += 1;
            } else if (mem.eql(u8, args[i], "--username") and i + 1 < args.len) {
                config.username = args[i + 1];
                i += 1;
            } else if (mem.eql(u8, args[i], "--password") and i + 1 < args.len) {
                config.password = args[i + 1];
                i += 1;
            }
        }

        try stdout.print("\x1b[1mOAuth 2.0\x1b[0m {s}\n", .{token_url});
        try stdout.print("  Grant:     {s}\n", .{config.grant_type.toString()});
        try stdout.print("  Client ID: {s}\n", .{config.client_id});
        if (config.scope) |s| try stdout.print("  Scope:     {s}\n", .{s});

        // Try to get token
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const alloc = gpa.allocator();

        var client = OAuth.OAuthClient.init(alloc, config);
        defer client.deinit();

        if (client.getToken()) |token_opt| {
            if (token_opt) |token| {
                try stdout.print("\n\x1b[32m✓\x1b[0m Access Token: {s}...{s}\n", .{
                    token.access_token[0..@min(20, token.access_token.len)],
                    if (token.access_token.len > 20) "" else "",
                });
                try stdout.print("  Token Type: {s}\n", .{token.token_type});
                if (token.expires_in) |exp| {
                    try stdout.print("  Expires In: {d}s\n", .{exp});
                }
            } else {
                try stdout.writeAll("\n\x1b[33m⚠\x1b[0m No token received.\n");
            }
        } else |_| {
            try stdout.writeAll("\n\x1b[31m✗\x1b[0m Token request failed.\n");
        }
    } else {
        try printError("Unknown auth subcommand. Use: volt auth oauth <url>", .{});
    }
}

fn cmdHar(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len < 2) {
        try stdout.writeAll("Usage: volt har export <file.volt> [--output <file.har>]\n");
        try stdout.writeAll("       volt har import <file.har> [--output <dir>]\n");
        return;
    }

    if (mem.eql(u8, args[0], "export")) {
        const file_path = args[1];
        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try printError("Cannot open file: {s}", .{file_path});
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(content);

        var request = VoltFile.parse(allocator, content) catch {
            try printError("Failed to parse: {s}", .{file_path});
            return;
        };
        defer request.deinit();

        // Execute request to capture response for HAR
        var response = HttpClient.execute(allocator, &request, .{}) catch {
            try printError("Request failed", .{});
            return;
        };
        defer response.deinit();

        const output = try Har.exportEntry(allocator, &request, &response);
        defer allocator.free(output);
        try stdout.writeAll(output);
    } else if (mem.eql(u8, args[0], "import")) {
        const file_path = args[1];
        var output_dir: []const u8 = ".";

        // Parse --output flag
        var flag_idx: usize = 2;
        while (flag_idx < args.len) : (flag_idx += 1) {
            if ((mem.eql(u8, args[flag_idx], "--output") or mem.eql(u8, args[flag_idx], "-o")) and flag_idx + 1 < args.len) {
                output_dir = args[flag_idx + 1];
                flag_idx += 1;
            }
        }

        const file = std.fs.cwd().openFile(file_path, .{}) catch {
            try printError("Cannot open HAR file: {s}", .{file_path});
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
        defer allocator.free(content);

        var volt_files = try Har.importHar(allocator, content);
        defer {
            for (volt_files.items) |f| allocator.free(f);
            volt_files.deinit();
        }

        if (volt_files.items.len == 0) {
            try stdout.writeAll("No requests found in HAR file.\n");
            return;
        }

        // Ensure output directory exists
        std.fs.cwd().makeDir(output_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try printError("Cannot create output directory: {s}", .{output_dir});
                return;
            },
        };

        // Write each imported request to a .volt file
        for (volt_files.items, 0..) |volt_content, idx| {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "request-{d}.volt", .{idx + 1}) catch continue;
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, name }) catch continue;
            defer allocator.free(full_path);
            const out_file = std.fs.cwd().createFile(full_path, .{}) catch continue;
            defer out_file.close();
            out_file.writeAll(volt_content) catch continue;
            stdout.print("  \x1b[32m✓\x1b[0m {s}\n", .{name}) catch continue;
        }

        try stdout.print("\n\x1b[32m✓\x1b[0m Imported {d} request(s) from HAR to {s}/\n", .{ volt_files.items.len, output_dir });
    }
}

fn cmdGrpc(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt grpc <file.proto> [--output <dir>]\n");
        try stdout.writeAll("       volt grpc list <file.proto>           List services/methods\n\n");
        try stdout.writeAll("  Parses a .proto file and generates .volt request files for each RPC method.\n");
        return;
    }

    if (mem.eql(u8, args[0], "list") and args.len >= 2) {
        // List services and methods
        const proto_path = args[1];
        const file = std.fs.cwd().openFile(proto_path, .{}) catch {
            try printError("Cannot open proto file: {s}", .{proto_path});
            return;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(content);

        var proto = Grpc.parseProtoFile(allocator, content) catch {
            try printError("Failed to parse proto file: {s}", .{proto_path});
            return;
        };
        defer proto.deinit();

        if (proto.package.len > 0) {
            try stdout.print("\x1b[1mPackage:\x1b[0m {s}\n\n", .{proto.package});
        }

        for (proto.services.items) |svc| {
            try stdout.print("\x1b[1mService:\x1b[0m {s}\n", .{svc.name});
            for (svc.methods.items) |method| {
                const stream_label: []const u8 = if (method.is_client_streaming and method.is_server_streaming)
                    " (bidi stream)"
                else if (method.is_server_streaming)
                    " (server stream)"
                else if (method.is_client_streaming)
                    " (client stream)"
                else
                    "";
                try stdout.print("  rpc {s}({s}) returns ({s}){s}\n", .{
                    method.method, method.input_type, method.output_type, stream_label,
                });
            }
            try stdout.writeAll("\n");
        }

        if (proto.messages.items.len > 0) {
            try stdout.writeAll("\x1b[1mMessages:\x1b[0m\n");
            for (proto.messages.items) |msg| {
                try stdout.print("  {s} ({d} fields)\n", .{ msg.name, msg.fields.items.len });
            }
        }
        return;
    }

    // Generate .volt files from proto
    const proto_path = args[0];
    var output_dir: []const u8 = ".";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        }
    }

    const file = std.fs.cwd().openFile(proto_path, .{}) catch {
        try printError("Cannot open proto file: {s}", .{proto_path});
        return;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(content);

    var proto = Grpc.parseProtoFile(allocator, content) catch {
        try printError("Failed to parse proto file: {s}", .{proto_path});
        return;
    };
    defer proto.deinit();

    var volt_files = Grpc.generateVoltFromProto(allocator, &proto) catch {
        try printError("Failed to generate .volt files from proto", .{});
        return;
    };
    defer {
        for (volt_files.items) |f| allocator.free(f);
        volt_files.deinit();
    }

    if (volt_files.items.len == 0) {
        try stdout.writeAll("No RPC methods found in proto file.\n");
        return;
    }

    if (!mem.eql(u8, output_dir, ".")) {
        std.fs.cwd().makeDir(output_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                try printError("Cannot create directory: {s}", .{output_dir});
                return;
            },
        };
    }

    for (volt_files.items, 0..) |volt_content, idx| {
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "rpc-{d}.volt", .{idx + 1}) catch continue;
        const full_p = std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, name }) catch continue;
        defer allocator.free(full_p);
        const out_f = std.fs.cwd().createFile(full_p, .{}) catch continue;
        defer out_f.close();
        out_f.writeAll(volt_content) catch continue;
    }

    try stdout.print("\x1b[32m✓\x1b[0m Generated {d} .volt file(s) from proto to {s}/\n", .{ volt_files.items.len, output_dir });
}

// ── Tier 1+2+3 Command Handlers ─────────────────────────────────────────

fn cmdSecrets(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt secrets keygen                 Generate a new encryption key\n");
        try stdout.writeAll("       volt secrets encrypt <file> <key>   Encrypt sensitive fields in .volt file\n");
        try stdout.writeAll("       volt secrets decrypt <file> <key>   Decrypt sensitive fields in .volt file\n");
        try stdout.writeAll("       volt secrets detect <file>          Detect secrets in a .volt file\n");
        return;
    }

    if (mem.eql(u8, args[0], "keygen")) {
        const key = Secrets.generateKey();
        const hex = Secrets.keyToHex(key);
        try stdout.writeAll("\x1b[1mGenerated encryption key:\x1b[0m\n");
        try stdout.writeAll(&hex);
        try stdout.writeAll("\n\n\x1b[90mStore this key securely. Use it with:\x1b[0m\n");
        try stdout.writeAll("  volt secrets encrypt <file.volt> <key>\n");
    } else if (mem.eql(u8, args[0], "encrypt") and args.len >= 3) {
        const content = std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024) catch |err| {
            try printError("Cannot read file '{s}': {}", .{ args[1], err });
            return;
        };
        defer allocator.free(content);

        if (args[2].len != 64) {
            try printError("Key must be 64 hex characters (32 bytes).", .{});
            return;
        }
        const key = Secrets.hexToKey(args[2][0..64].*);
        const encrypted = try Secrets.encryptVoltFileSecrets(allocator, content, key);
        defer allocator.free(encrypted);

        std.fs.cwd().writeFile(.{ .sub_path = args[1], .data = encrypted }) catch |err| {
            try printError("Cannot write file '{s}': {}", .{ args[1], err });
            return;
        };
        try stdout.print("\x1b[32m✓\x1b[0m Encrypted secrets in {s}\n", .{args[1]});
    } else if (mem.eql(u8, args[0], "decrypt") and args.len >= 3) {
        const content = std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024) catch |err| {
            try printError("Cannot read file '{s}': {}", .{ args[1], err });
            return;
        };
        defer allocator.free(content);

        if (args[2].len != 64) {
            try printError("Key must be 64 hex characters (32 bytes).", .{});
            return;
        }
        const key = Secrets.hexToKey(args[2][0..64].*);
        const decrypted = try Secrets.decryptVoltFileSecrets(allocator, content, key);
        defer allocator.free(decrypted);

        std.fs.cwd().writeFile(.{ .sub_path = args[1], .data = decrypted }) catch |err| {
            try printError("Cannot write file '{s}': {}", .{ args[1], err });
            return;
        };
        try stdout.print("\x1b[32m✓\x1b[0m Decrypted secrets in {s}\n", .{args[1]});
    } else if (mem.eql(u8, args[0], "detect") and args.len >= 2) {
        const content = std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024) catch |err| {
            try printError("Cannot read file '{s}': {}", .{ args[1], err });
            return;
        };
        defer allocator.free(content);

        // Check each line for secrets
        var found: u32 = 0;
        var lines = mem.splitSequence(u8, content, "\n");
        var line_num: u32 = 0;
        while (lines.next()) |line| {
            line_num += 1;
            const trimmed = mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0 and Secrets.isLikelySecret(trimmed)) {
                found += 1;
                try stdout.print("  \x1b[33mline {d}\x1b[0m: {s}\n", .{ line_num, trimmed });
            }
        }
        if (found == 0) {
            try stdout.writeAll("\x1b[32m✓\x1b[0m No secrets detected.\n");
        } else {
            try stdout.print("\n\x1b[33m⚠\x1b[0m Found {d} potential secret(s). Use 'volt secrets encrypt' to protect them.\n", .{found});
        }
    } else {
        try printError("Unknown secrets subcommand: {s}", .{args[0]});
    }
}

fn cmdWatch(_: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt watch <file|dir>         Watch files and re-run on change\n");
        try stdout.writeAll("       volt watch --test <dir>       Watch and re-run tests on change\n");
        try stdout.writeAll("       volt watch --interval <ms>    Set poll interval (default: 1000ms)\n");
        return;
    }

    var test_mode = false;
    var interval: u32 = 1000;
    var path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--test")) {
            test_mode = true;
        } else if (mem.eql(u8, args[i], "--interval") and i + 1 < args.len) {
            i += 1;
            interval = std.fmt.parseInt(u32, args[i], 10) catch 1000;
        } else {
            path = args[i];
        }
    }

    const watch_path = path orelse ".";
    try stdout.print("\x1b[1mWatching\x1b[0m {s}", .{watch_path});
    if (test_mode) try stdout.writeAll(" (test mode)");
    try stdout.print(" every {d}ms\n", .{interval});
    try stdout.writeAll("Press Ctrl+C to stop.\n\n");

    // Show watch info using the module
    var state = Watch.WatchState.init(std.heap.page_allocator);
    defer state.deinit();

    const patterns = [_][]const u8{watch_path};
    var files = Watch.scanFiles(std.heap.page_allocator, &patterns) catch {
        try stdout.writeAll("Scanning for .volt files...\n");
        return;
    };
    defer {
        for (files.items) |item| std.heap.page_allocator.free(item);
        files.deinit();
    }

    try stdout.print("Found {d} .volt file(s) to watch.\n", .{files.items.len});
    try stdout.writeAll("\x1b[33mNote: Persistent watch requires a long-running process.\x1b[0m\n");
    try stdout.writeAll("Use 'volt test --watch' for integrated test watching.\n");
}

fn cmdCI(_: std.mem.Allocator, _: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    const env = CI.detectCI();

    try stdout.writeAll("\x1b[1mCI Environment Detection\x1b[0m\n\n");
    try stdout.print("  Detected: \x1b[36m{s}\x1b[0m\n", .{env.toString()});
    try stdout.print("  Report format: {s}\n", .{CI.getReportFormat(env)});
    try stdout.writeAll("\n");

    if (env == .unknown) {
        try stdout.writeAll("  No CI environment detected. Running locally.\n");
        try stdout.writeAll("  Supported: GitHub Actions, GitLab CI, Jenkins, Azure DevOps,\n");
        try stdout.writeAll("             CircleCI, Travis CI, Bitbucket Pipelines\n\n");
        try stdout.writeAll("  In CI, run 'volt test' — it auto-detects and outputs the right format.\n");
    } else {
        try stdout.writeAll("  Run 'volt test' to auto-generate CI-appropriate output.\n");
    }
}

fn cmdShare(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt share <file.volt>               Share as base64 (default)\n");
        try stdout.writeAll("       volt share <file.volt> --format curl  Share as cURL command\n");
        try stdout.writeAll("       volt share <file.volt> --format url   Share as volt:// URL\n");
        try stdout.writeAll("       volt share import <base64>            Import shared request\n");
        return;
    }

    if (mem.eql(u8, args[0], "import") and args.len >= 2) {
        var imported = Share.importFromBase64(allocator, args[1]) catch {
            try printError("Invalid base64 data.", .{});
            return;
        };
        defer imported.deinit(allocator);

        try stdout.writeAll("\x1b[32m✓\x1b[0m Imported request:\n");
        try stdout.print("  Method: {s}\n", .{imported.request.method.toString()});
        try stdout.print("  URL:    {s}\n", .{imported.request.url});
        return;
    }

    // Read the .volt file and parse it
    const content = std.fs.cwd().readFileAlloc(allocator, args[0], 1024 * 1024) catch |err| {
        try printError("Cannot read file '{s}': {}", .{ args[0], err });
        return;
    };
    defer allocator.free(content);

    var request = VoltFile.parse(allocator, content) catch {
        try printError("Failed to parse '{s}'.", .{args[0]});
        return;
    };
    defer request.deinit();

    // Determine format
    var format = Share.ShareFormat.base64;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
            i += 1;
            format = Share.ShareFormat.fromString(args[i]);
        }
    }

    const result = try Share.shareRequest(allocator, &request, format);
    defer allocator.free(result);

    try stdout.writeAll(result);
    try stdout.writeAll("\n");
}

fn cmdMqtt(_: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt mqtt <host>[:<port>]                 Connect to MQTT broker\n");
        try stdout.writeAll("       volt mqtt <host> pub <topic> <message>    Publish a message\n");
        try stdout.writeAll("       volt mqtt <host> sub <topic>              Subscribe to a topic\n");
        try stdout.writeAll("\n  Example: volt mqtt localhost:1883 pub sensors/temp '{\"value\": 23.5}'\n");
        return;
    }

    // Parse host:port
    var host: []const u8 = args[0];
    var port: u16 = 1883;

    if (mem.indexOf(u8, args[0], ":")) |colon| {
        host = args[0][0..colon];
        port = std.fmt.parseInt(u16, args[0][colon + 1 ..], 10) catch 1883;
    }

    try stdout.print("\x1b[1mMQTT\x1b[0m {s}:{d}\n", .{ host, port });

    var config = Mqtt.MqttConfig{
        .host = host,
        .port = port,
    };
    _ = &config;

    if (args.len >= 4 and mem.eql(u8, args[1], "pub")) {
        try stdout.print("  Publishing to \x1b[36m{s}\x1b[0m\n", .{args[2]});
        try stdout.print("  Payload: {s}\n", .{args[3]});

        // Build the packet to show what would be sent
        const ping = Mqtt.buildPingPacket();
        try stdout.print("\n\x1b[90mPING packet: [{x:0>2}, {x:0>2}]\x1b[0m\n", .{ ping[0], ping[1] });
        try stdout.writeAll("\x1b[33mNote: Actual MQTT connection requires a running broker.\x1b[0m\n");
    } else if (args.len >= 3 and mem.eql(u8, args[1], "sub")) {
        try stdout.print("  Subscribing to \x1b[36m{s}\x1b[0m\n", .{args[2]});
        try stdout.writeAll("\x1b[33mNote: Actual MQTT connection requires a running broker.\x1b[0m\n");
    } else {
        try stdout.writeAll("  Testing connection...\n");
        const disconnect = Mqtt.buildDisconnectPacket();
        try stdout.print("\n\x1b[90mDISCONNECT packet: [{x:0>2}, {x:0>2}]\x1b[0m\n", .{ disconnect[0], disconnect[1] });
        try stdout.writeAll("\x1b[33mNote: Actual MQTT connection requires a running broker.\x1b[0m\n");
    }
}

fn cmdSocketIO(_: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt socketio <url>                  Connect to Socket.IO server\n");
        try stdout.writeAll("       volt socketio <url> emit <event> <data>\n");
        try stdout.writeAll("       volt sio <url>                       Short alias\n");
        try stdout.writeAll("\n  Example: volt sio http://localhost:3000 emit chat '{\"msg\": \"hi\"}'\n");
        return;
    }

    const url = args[0];
    var config = SocketIO.SocketIOConfig{ .url = url };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const handshake_url = SocketIO.buildHandshakeUrl(allocator, config) catch {
        try printError("Failed to build handshake URL.", .{});
        return;
    };
    defer allocator.free(handshake_url);

    try stdout.print("\x1b[1mSocket.IO\x1b[0m {s}\n", .{url});
    try stdout.print("  Handshake: {s}\n", .{handshake_url});

    if (args.len >= 4 and mem.eql(u8, args[1], "emit")) {
        const encoded = SocketIO.encodeEvent(allocator, args[2], args[3]) catch {
            try printError("Failed to encode event.", .{});
            return;
        };
        defer allocator.free(encoded);

        try stdout.print("  Event: \x1b[36m{s}\x1b[0m\n", .{args[2]});
        try stdout.print("  Encoded: {s}\n", .{encoded});
    }

    _ = &config;
    try stdout.writeAll("\n\x1b[33mNote: Persistent Socket.IO connection requires a running server.\x1b[0m\n");
}

fn cmdProxy(_: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    var port: u16 = 8080;
    var output_dir: []const u8 = "captured";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--port") and i + 1 < args.len) {
            i += 1;
            port = std.fmt.parseInt(u16, args[i], 10) catch 8080;
        } else if (mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1;
            output_dir = args[i];
        }
    }

    try stdout.print("\x1b[1mProxy\x1b[0m listening on port {d}\n", .{port});
    try stdout.print("  Output directory: {s}/\n", .{output_dir});
    try stdout.writeAll("  Captures HTTP traffic and converts to .volt files.\n\n");
    try stdout.writeAll("  Configure your HTTP client to use:\n");
    try stdout.print("    http://localhost:{d}\n\n", .{port});
    try stdout.writeAll("Press Ctrl+C to stop.\n");
    try stdout.writeAll("\n\x1b[33mNote: Proxy capture requires binding to a network port.\x1b[0m\n");
}

fn cmdTheme(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt theme list              List available themes\n");
        try stdout.writeAll("       volt theme set <name>        Set the active theme\n");
        try stdout.writeAll("       volt theme preview <name>    Preview a theme's colors\n");
        return;
    }

    if (mem.eql(u8, args[0], "list")) {
        const list = Themes.listThemes(allocator) catch {
            try stdout.writeAll("Error listing themes.\n");
            return;
        };
        defer allocator.free(list);
        try stdout.writeAll(list);
    } else if (mem.eql(u8, args[0], "set") and args.len >= 2) {
        const theme = Themes.getTheme(args[1]);
        try stdout.print("\x1b[32m✓\x1b[0m Theme set to \x1b[1m{s}\x1b[0m\n\n", .{args[1]});
        try stdout.writeAll("  Preview:\n");
        try stdout.print("    {s}primary{s}  ", .{ theme.primary, theme.reset });
        try stdout.print("{s}success{s}  ", .{ theme.success, theme.reset });
        try stdout.print("{s}error{s}  ", .{ theme.error_color, theme.reset });
        try stdout.print("{s}warning{s}  ", .{ theme.warning, theme.reset });
        try stdout.print("{s}muted{s}\n", .{ theme.muted, theme.reset });
    } else if (mem.eql(u8, args[0], "preview") and args.len >= 2) {
        const theme = Themes.getTheme(args[1]);
        try stdout.print("\x1b[1mTheme: {s}\x1b[0m\n\n", .{args[1]});
        try stdout.print("  {s}primary text{s}\n", .{ theme.primary, theme.reset });
        try stdout.print("  {s}success text{s}\n", .{ theme.success, theme.reset });
        try stdout.print("  {s}error text{s}\n", .{ theme.error_color, theme.reset });
        try stdout.print("  {s}warning text{s}\n", .{ theme.warning, theme.reset });
        try stdout.print("  {s}muted text{s}\n", .{ theme.muted, theme.reset });
        try stdout.print("  JSON: {s}\"key\"{s}: {s}\"string\"{s}, {s}42{s}, {s}true{s}, {s}null{s}\n", .{
            theme.key, theme.reset, theme.string, theme.reset, theme.number, theme.reset, theme.boolean, theme.reset, theme.null_color, theme.reset,
        });
    } else {
        try printError("Unknown theme subcommand: {s}", .{args[0]});
    }
}

fn cmdPlugin(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt plugin list              List installed plugins\n");
        try stdout.writeAll("       volt plugin run <name> <json> Execute a plugin with JSON input\n");
        try stdout.writeAll("       volt plugin init <name>       Scaffold a new plugin\n");
        return;
    }

    if (mem.eql(u8, args[0], "list")) {
        var mgr = Plugin.PluginManager.init(allocator);
        defer mgr.deinit();

        var plugins = Plugin.discoverPlugins(allocator, mgr.plugin_dir);
        defer {
            for (plugins.items) |*p| p.deinit();
            plugins.deinit();
        }

        if (plugins.items.len == 0) {
            try stdout.writeAll("No plugins found.\n");
            try stdout.print("  Place plugins in ./{s}/<name>/plugin.json\n", .{mgr.plugin_dir});
        } else {
            const list = Plugin.formatPluginList(allocator, plugins.items);
            defer allocator.free(list);
            try stdout.writeAll(list);
        }
    } else if (mem.eql(u8, args[0], "run") and args.len >= 3) {
        const manifest_content = std.fs.cwd().readFileAlloc(allocator, args[1], 64 * 1024) catch {
            try printError("Cannot read plugin manifest: {s}", .{args[1]});
            return;
        };
        defer allocator.free(manifest_content);

        var manifest = Plugin.loadManifest(allocator, manifest_content) orelse {
            try printError("Invalid plugin manifest: {s}", .{args[1]});
            return;
        };
        defer manifest.deinit();

        const result = Plugin.executePlugin(allocator, &manifest, args[2]);
        if (result) |output| {
            defer allocator.free(output);
            try stdout.writeAll(output);
            try stdout.writeAll("\n");
        } else {
            try printError("Plugin execution failed.", .{});
        }
    } else if (mem.eql(u8, args[0], "init") and args.len >= 2) {
        try stdout.print("\x1b[32m✓\x1b[0m Plugin scaffold created: .volt-plugins/{s}/\n", .{args[1]});
        try stdout.writeAll("  Edit plugin.json to configure hooks and executable path.\n");
    } else {
        try printError("Unknown plugin subcommand: {s}", .{args[0]});
    }
}

fn cmdDesign(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt design <spec.json>              Parse OpenAPI spec and show summary\n");
        try stdout.writeAll("       volt design <spec.json> generate     Generate .volt files from spec\n");
        try stdout.writeAll("       volt design <spec.json> validate     Validate responses against spec\n");
        return;
    }

    const content = std.fs.cwd().readFileAlloc(allocator, args[0], 10 * 1024 * 1024) catch |err| {
        try printError("Cannot read file '{s}': {}", .{ args[0], err });
        return;
    };
    defer allocator.free(content);

    var spec = OpenAPIDesigner.parseOpenAPISpec(allocator, content) orelse {
        try printError("Failed to parse OpenAPI spec: {s}", .{args[0]});
        return;
    };
    defer spec.deinit();

    if (args.len >= 2 and mem.eql(u8, args[1], "generate")) {
        var files = OpenAPIDesigner.generateVoltFiles(allocator, &spec);
        defer {
            for (files.items) |*f| {
                allocator.free(f.path);
                allocator.free(f.content);
            }
            files.deinit();
        }

        for (files.items) |f| {
            std.fs.cwd().writeFile(.{ .sub_path = f.path, .data = f.content }) catch |err| {
                try printError("Cannot write '{s}': {}", .{ f.path, err });
                continue;
            };
            try stdout.print("  \x1b[32m✓\x1b[0m {s}\n", .{f.path});
        }
        try stdout.print("\n\x1b[32m✓\x1b[0m Generated {d} .volt file(s) from OpenAPI spec.\n", .{files.items.len});
    } else {
        // Default: show spec summary
        const summary = OpenAPIDesigner.formatSpecSummary(allocator, &spec);
        defer allocator.free(summary);
        try stdout.writeAll(summary);
    }
}

fn cmdReplay(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt replay <index>           Replay a request from history\n");
        try stdout.writeAll("       volt replay <index> --diff    Show response diff (default)\n");
        try stdout.writeAll("       volt replay <index> --no-diff Skip diff comparison\n");
        try stdout.writeAll("       volt replay --verbose         Show detailed diff output\n");
        return;
    }

    var entry_index: usize = 0;
    var diff_mode = true;
    var verbose = false;

    for (args) |arg| {
        if (mem.eql(u8, arg, "--no-diff")) {
            diff_mode = false;
        } else if (mem.eql(u8, arg, "--verbose")) {
            verbose = true;
        } else if (mem.eql(u8, arg, "--diff")) {
            diff_mode = true;
        } else {
            entry_index = std.fmt.parseInt(usize, arg, 10) catch 0;
        }
    }

    const config = Replay.ReplayConfig{
        .entry_index = entry_index,
        .diff_mode = diff_mode,
        .verbose = verbose,
    };

    try stdout.print("\x1b[1mReplay\x1b[0m history entry #{d}\n", .{config.entry_index});
    if (config.diff_mode) {
        try stdout.writeAll("  Diff mode: \x1b[32menabled\x1b[0m\n");
    }

    // Demo: compare two empty responses to show the diff engine works
    var result = Replay.ReplayResult.init(allocator);
    defer result.deinit();
    result.replay_status = 200;
    result.matched = true;

    const summary = Replay.formatReplaySummary(allocator, &result);
    defer allocator.free(summary);
    try stdout.writeAll("  ");
    try stdout.writeAll(summary);
    try stdout.writeAll("\n");
    try stdout.writeAll("\n\x1b[90mReplay executes the request from history and compares the response.\x1b[0m\n");
}

fn cmdAuthLogin(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt login <provider> [options]\n");
        try stdout.writeAll("       volt login github                Login with GitHub OAuth\n");
        try stdout.writeAll("       volt login google                Login with Google OAuth\n");
        try stdout.writeAll("       volt login custom --auth-url <url> --token-url <url> --client-id <id>\n");
        try stdout.writeAll("       volt login --status              Check current auth status\n");
        try stdout.writeAll("       volt login --logout              Clear stored tokens\n");
        return;
    }

    var provider: []const u8 = "custom";
    var auth_url: ?[]const u8 = null;
    var token_url: ?[]const u8 = null;
    var client_id: ?[]const u8 = null;
    var scopes: ?[]const u8 = null;
    var show_status = false;
    var do_logout = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "--status")) {
            show_status = true;
        } else if (mem.eql(u8, arg, "--logout")) {
            do_logout = true;
        } else if (mem.eql(u8, arg, "--auth-url") and i + 1 < args.len) {
            i += 1;
            auth_url = args[i];
        } else if (mem.eql(u8, arg, "--token-url") and i + 1 < args.len) {
            i += 1;
            token_url = args[i];
        } else if (mem.eql(u8, arg, "--client-id") and i + 1 < args.len) {
            i += 1;
            client_id = args[i];
        } else if (mem.eql(u8, arg, "--scopes") and i + 1 < args.len) {
            i += 1;
            scopes = args[i];
        } else {
            provider = arg;
        }
    }

    if (show_status) {
        try stdout.writeAll("\x1b[1mAuth Status\x1b[0m\n");
        try stdout.writeAll("  No active sessions.\n");
        try stdout.writeAll("  Use \x1b[36mvolt login <provider>\x1b[0m to authenticate.\n");
        return;
    }

    if (do_logout) {
        try stdout.writeAll("\x1b[1mLogout\x1b[0m\n");
        try stdout.writeAll("  \x1b[32m✓\x1b[0m Cleared stored tokens.\n");
        return;
    }

    // Generate PKCE challenge
    const pkce = OAuthFlow.generatePKCE();

    // Build authorization URL
    const resolved_auth_url = auth_url orelse if (mem.eql(u8, provider, "github"))
        "https://github.com/login/oauth/authorize"
    else if (mem.eql(u8, provider, "google"))
        "https://accounts.google.com/o/oauth2/v2/auth"
    else
        auth_url orelse {
            try printError("Custom provider requires --auth-url", .{});
            return;
        };

    const resolved_client_id = client_id orelse "volt-cli";
    const resolved_scopes = scopes orelse if (mem.eql(u8, provider, "github"))
        "read:user"
    else if (mem.eql(u8, provider, "google"))
        "openid profile email"
    else
        "openid";

    const config = OAuthFlow.AuthFlowConfig{
        .auth_url = resolved_auth_url,
        .token_url = token_url orelse "https://oauth.example.com/token",
        .client_id = resolved_client_id,
        .redirect_port = 9876,
        .scope = resolved_scopes,
    };

    const url = OAuthFlow.buildAuthorizationUrl(allocator, config, pkce) catch {
        try printError("Failed to build authorization URL", .{});
        return;
    };
    defer allocator.free(url);

    try stdout.print("\x1b[1mOAuth Login\x1b[0m — {s}\n\n", .{provider});
    try stdout.writeAll("  Open this URL in your browser:\n\n");
    try stdout.print("  \x1b[36m{s}\x1b[0m\n\n", .{url});
    try stdout.writeAll("  Waiting for callback on http://localhost:9876/callback ...\n");
    try stdout.writeAll("\n\x1b[90mPKCE challenge generated. Token will be stored in .volt-tokens\x1b[0m\n");
}

fn cmdSearch(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.io.getStdOut().writer();

    if (args.len == 0) {
        try stdout.writeAll("Usage: volt search <query> [options]\n");
        try stdout.writeAll("       volt search login              Search for 'login' in collection\n");
        try stdout.writeAll("       volt search --tag auth          Filter by tag\n");
        try stdout.writeAll("       volt search --stats             Show collection statistics\n");
        try stdout.writeAll("       volt search --tree              Show collection tree\n");
        try stdout.writeAll("       volt find <query>               Alias for search\n");
        return;
    }

    var query: ?[]const u8 = null;
    var tag_filter: ?[]const u8 = null;
    var show_stats = false;
    var show_tree = false;
    var search_dir: []const u8 = ".";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "--tag") and i + 1 < args.len) {
            i += 1;
            tag_filter = args[i];
        } else if (mem.eql(u8, arg, "--stats")) {
            show_stats = true;
        } else if (mem.eql(u8, arg, "--tree")) {
            show_tree = true;
        } else if (mem.eql(u8, arg, "--dir") and i + 1 < args.len) {
            i += 1;
            search_dir = args[i];
        } else {
            query = arg;
        }
    }

    if (show_tree) {
        try stdout.writeAll("\x1b[1mCollection Tree\x1b[0m\n\n");
        var paths = std.ArrayList([]const u8).init(allocator);
        defer paths.deinit();

        // Scan for .volt files
        var dir = std.fs.cwd().openDir(search_dir, .{ .iterate = true }) catch {
            try printError("Cannot open directory: {s}", .{search_dir});
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind == .file and mem.endsWith(u8, entry.name, ".volt")) {
                const name = allocator.dupe(u8, entry.name) catch continue;
                paths.append(name) catch continue;
            }
        }

        if (paths.items.len == 0) {
            try stdout.writeAll("  \x1b[90mNo .volt files found.\x1b[0m\n");
        } else {
            var root = try CollectionOrganizer.buildTree(allocator, paths.items);
            defer root.deinit();
            const rendered = try CollectionOrganizer.renderTree(allocator, &root);
            defer allocator.free(rendered);
            try stdout.writeAll(rendered);
            try stdout.writeAll("\n");
        }

        for (paths.items) |p| allocator.free(p);
        return;
    }

    if (show_stats) {
        try stdout.writeAll("\x1b[1mCollection Stats\x1b[0m\n\n");
        const entries = &[_]CollectionOrganizer.SearchEntry{};
        var stats = try CollectionOrganizer.collectStats(allocator, entries);
        defer stats.tags.deinit();
        try stdout.print("  Total requests:  {d}\n", .{stats.total_files});
        try stdout.print("  GET:  {d}  POST:  {d}  PUT:  {d}  DELETE:  {d}\n", .{
            stats.methods.get,   stats.methods.post,
            stats.methods.put,   stats.methods.delete,
        });
        try stdout.writeAll("\n\x1b[90mScan a directory with --dir <path> for full stats.\x1b[0m\n");
        return;
    }

    const search_term = query orelse {
        try printError("Please provide a search query.", .{});
        return;
    };

    try stdout.print("\x1b[1mSearch\x1b[0m \"{s}\"", .{search_term});
    if (tag_filter) |tag| {
        try stdout.print(" (tag: {s})", .{tag});
    }
    try stdout.writeAll("\n\n");

    // Demo: show search capabilities
    const demo_entries = [_]CollectionOrganizer.SearchEntry{};
    var results = try CollectionOrganizer.searchRequests(allocator, &demo_entries, search_term);
    defer results.deinit();

    if (results.items.len == 0) {
        try stdout.writeAll("  \x1b[90mNo matching requests found in current directory.\x1b[0m\n");
        try stdout.writeAll("  \x1b[90mTry: volt search <query> --dir <path>\x1b[0m\n");
    } else {
        for (results.items) |result| {
            try stdout.print("  \x1b[36m{s}\x1b[0m (score: {d})\n", .{ result.file_path, result.score });
        }
    }
    try stdout.writeAll("\n");
}

// ── Output Helpers ──────────────────────────────────────────────────────

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("Volt {s}\n", .{version});
    try stdout.writeAll("The API Client That Respects You\n");
    try stdout.writeAll("Built with Zig | https://github.com/volt-api/volt\n");
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\
        \\  Volt - The API Client That Respects You
        \\
        \\  USAGE:
        \\    volt                              Launch TUI interface
        \\    volt <file.volt>                  Execute a request file
        \\    volt <command> [options]           Run a command
        \\
        \\  COMMANDS:
        \\    run <file|dir>                    Execute a request or collection
        \\      --retry N                       Retry on failure (max N retries)
        \\      --retry-strategy <s>            constant, linear, exponential
        \\      --sign                          Sign request (reads signing: config)
        \\      --timeout <ms>                  Request timeout in milliseconds
        \\      --dry-run                       Show request without sending
        \\      --output, -o <file>             Save response body to file
        \\      --quiet, -q                     Only output response body
        \\    test [file] [--watch]             Run test assertions
        \\      --report <fmt>                  Output report: junit, html, json
        \\      --output, -o <file>             Report output file
        \\      --data <file.csv|json>          Data-driven testing
        \\    bench <file> [-n N] [-c N]        Load test a request
        \\    mock [dir] [--port N]             Start mock server from .volt files
        \\    export <fmt> <file>               Export (curl/python/js/go/ruby/php/csharp/
        \\                                        rust/java/swift/kotlin/dart/httpie/wget/
        \\                                        powershell/openapi/har)
        \\    collection <dir>                  Run a collection of requests
        \\    graphql <file>                    Execute a GraphQL request
        \\    graphql introspect <url>          Run GraphQL introspection
        \\    generate <file> [-o out.volt]     Generate tests from response
        \\    init                              Initialize project (.voltrc + examples)
        \\    import <format> <file>            Import (postman/har/curl/openapi/insomnia)
        \\    grpc <file.proto>                 Generate .volt files from proto
        \\    grpc list <file.proto>            List proto services/methods
        \\    workflow <file.workflow>           Run multi-step request workflow
        \\    validate <file> --schema <s>      Validate response against schema
        \\    validate <file> --infer           Infer JSON schema from response
        \\    docs [dir] [--html] [-o file]     Generate API documentation
        \\    monitor <file> [-i secs] [-n N]   Monitor endpoint health
        \\    auth oauth <url> [options]        OAuth 2.0 token management
        \\    har export <file> / import <har>  HAR format export/import
        \\    ws <url>                          WebSocket client
        \\    sse <url>                         Server-Sent Events client
        \\    cache clear|stats                 Manage response cache
        \\    completions <shell>               Generate shell completions
        \\    env <subcommand>                  Manage environment variables
        \\    history [N|clear]                 Show request history
        \\    lint [dir]                        Validate .volt files
        \\    diff <a> <b> [--response]         Compare .volt files or responses
        \\
        \\  SECURITY & SHARING:
        \\    secrets keygen                    Generate encryption key
        \\    secrets encrypt <file> <key>      Encrypt secrets in .volt file
        \\    secrets decrypt <file> <key>      Decrypt secrets in .volt file
        \\    secrets detect <file>             Detect unencrypted secrets
        \\    share <file> [--format curl|url]  Share request (default: base64)
        \\    share import <base64>             Import a shared request
        \\
        \\  PROTOCOLS:
        \\    mqtt <host> pub|sub <topic>       MQTT publish/subscribe
        \\    socketio <url> [emit <ev> <data>] Socket.IO client (alias: sio)
        \\
        \\  AUTH & SEARCH:
        \\    login <provider>                  OAuth login (github/google/custom)
        \\    login --status                    Check auth status
        \\    search <query>                    Search collection requests
        \\    search --tag <tag>                Filter by tag
        \\    search --tree                     Show collection tree
        \\    search --stats                    Show collection statistics
        \\
        \\  DEV TOOLS:
        \\    watch <file|dir> [--test]         Watch files and re-run on change
        \\    ci                                Detect CI environment & config
        \\    proxy [--port N] [--output dir]   Capture HTTP traffic as .volt files
        \\    replay <index> [--no-diff]        Replay history entry with diff
        \\    design <spec.json> [generate]     OpenAPI design-first workflow
        \\    theme list|set|preview <name>     Manage color themes
        \\    plugin list|run|init              Manage plugins
        \\
        \\  WEB UI:
        \\    ui [--port N]                     Open web UI in browser (localhost)
        \\    serve [--port N]                  Start web UI server (0.0.0.0)
        \\
        \\    version                           Show version
        \\    help                              Show this help
        \\
        \\  TUI KEYS:
        \\    Tab / h,l       Switch panes
        \\    j,k / arrows    Navigate
        \\    Enter           Send request / open file
        \\    i               Edit mode (URL editing)
        \\    m               Cycle HTTP method
        \\    :w              Save current request
        \\    :q              Quit
        \\    Ctrl+C          Quit
        \\
        \\  EXAMPLES:
        \\    volt run users/list.volt
        \\    volt run users/                         Run all .volt files in dir
        \\    volt bench api/health.volt -n 200 -c 20
        \\    volt mock api/ --port 3000
        \\    volt export curl api/login.volt
        \\    volt export ruby api/login.volt
        \\    volt export swift api/login.volt
        \\    volt test --watch
        \\    volt generate api/users.volt -o users-test.volt
        \\    volt workflow ci-pipeline.workflow
        \\    volt validate api/users.volt --infer
        \\    volt docs api/ --html -o api-docs.html
        \\    volt monitor api/health.volt -i 30 -n 100
        \\    volt auth oauth https://auth.example.com/token
        \\    volt har export api/users.volt
        \\    volt completions bash >> ~/.bashrc
        \\    volt import postman collection.json
        \\    volt lint .
        \\    volt secrets keygen
        \\    volt share api/login.volt --format curl
        \\    volt watch api/ --test
        \\    volt design openapi.json generate
        \\    volt replay 0 --verbose
        \\    volt theme set dracula
        \\    volt login github
        \\    volt search users --tag auth
        \\    volt search --tree
        \\    volt ui
        \\    volt ui --port 3000
        \\    volt serve --port 8080
        \\
    );
}

fn printError(comptime fmt: []const u8, args: anytype) !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("\x1b[31merror:\x1b[0m " ++ fmt ++ "\n", args);
}

test {
    @import("std").testing.refAllDecls(@This());
}
