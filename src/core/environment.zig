const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const VoltFile = @import("volt_file.zig");
const DynamicVars = @import("dynamic_vars.zig");

// ── Environment System ──────────────────────────────────────────────────

pub const Environment = struct {
    name: []const u8,
    variables: std.StringHashMap([]const u8),
    secrets: std.StringHashMap([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: []const u8) Environment {
        return .{
            .name = name,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .secrets = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Environment) void {
        self.variables.deinit();
        self.secrets.deinit();
    }

    pub fn set(self: *Environment, key: []const u8, value: []const u8) !void {
        if (key.len > 0 and key[0] == '$') {
            try self.secrets.put(key, value);
        } else {
            try self.variables.put(key, value);
        }
    }

    pub fn get(self: *const Environment, key: []const u8) ?[]const u8 {
        if (key.len > 0 and key[0] == '$') {
            return self.secrets.get(key);
        }
        return self.variables.get(key);
    }

    pub fn remove(self: *Environment, key: []const u8) void {
        if (key.len > 0 and key[0] == '$') {
            _ = self.secrets.remove(key);
        } else {
            _ = self.variables.remove(key);
        }
    }
};

// ── Environment Manager ─────────────────────────────────────────────────

pub const EnvManager = struct {
    allocator: Allocator,
    environments: std.StringHashMap(Environment),
    active_env: ?[]const u8,
    global_vars: std.StringHashMap([]const u8),

    pub fn init(allocator: Allocator) EnvManager {
        return .{
            .allocator = allocator,
            .environments = std.StringHashMap(Environment).init(allocator),
            .active_env = null,
            .global_vars = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *EnvManager) void {
        var it = self.environments.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.environments.deinit();
        self.global_vars.deinit();
    }

    pub fn createEnv(self: *EnvManager, name: []const u8) !*Environment {
        const env = Environment.init(self.allocator, name);
        try self.environments.put(name, env);
        return self.environments.getPtr(name).?;
    }

    pub fn getEnv(self: *EnvManager, name: []const u8) ?*Environment {
        return self.environments.getPtr(name);
    }

    pub fn setActive(self: *EnvManager, name: []const u8) void {
        self.active_env = name;
    }

    pub fn getActive(self: *EnvManager) ?*Environment {
        if (self.active_env) |name| {
            return self.environments.getPtr(name);
        }
        return null;
    }

    /// Resolve a variable by checking: request vars → active env → global vars → dynamic vars
    pub fn resolve(self: *const EnvManager, key: []const u8, request_vars: ?*const std.StringHashMap([]const u8)) ?[]const u8 {
        // 1. Request-level variables
        if (request_vars) |rv| {
            if (rv.get(key)) |val| return val;
        }

        // 2. Active environment
        if (self.active_env) |env_name| {
            if (self.environments.get(env_name)) |env| {
                if (env.variables.get(key)) |val| return val;
                if (env.secrets.get(key)) |val| return val;
            }
        }

        // 3. Global variables
        if (self.global_vars.get(key)) |val| return val;

        return null;
    }

    /// Interpolate variables in a string: {{var_name}} → resolved value
    pub fn interpolate(self: *const EnvManager, input: []const u8, request_vars: ?*const std.StringHashMap([]const u8), allocator: Allocator) ![]const u8 {
        var result = std.ArrayList(u8).init(allocator);

        var i: usize = 0;
        while (i < input.len) {
            if (i + 1 < input.len and input[i] == '{' and input[i + 1] == '{') {
                // Find closing }}
                const start = i + 2;
                var end = start;
                while (end + 1 < input.len) {
                    if (input[end] == '}' and input[end + 1] == '}') break;
                    end += 1;
                }
                if (end + 1 < input.len and input[end] == '}' and input[end + 1] == '}') {
                    const var_name = mem.trim(u8, input[start..end], " ");

                    // Check for dynamic variables
                    if (mem.startsWith(u8, var_name, "$")) {
                        const dynamic_val = resolveDynamic(allocator, var_name);
                        if (dynamic_val) |dv| {
                            defer allocator.free(dv);
                            try result.appendSlice(dv);
                        } else {
                            // Try as a secret variable
                            if (self.resolve(var_name, request_vars)) |val| {
                                try result.appendSlice(val);
                            } else {
                                // Keep original placeholder
                                try result.appendSlice(input[i .. end + 2]);
                            }
                        }
                    } else if (self.resolve(var_name, request_vars)) |val| {
                        try result.appendSlice(val);
                    } else {
                        // Keep original placeholder if unresolved
                        try result.appendSlice(input[i .. end + 2]);
                    }
                    i = end + 2;
                } else {
                    try result.append(input[i]);
                    i += 1;
                }
            } else {
                try result.append(input[i]);
                i += 1;
            }
        }

        return result.toOwnedSlice();
    }

    /// Mask secret variables in output text.
    /// Replaces any occurrence of a secret value with "***".
    pub fn maskSecrets(self: *const EnvManager, input: []const u8, out_allocator: Allocator) ![]const u8 {
        var output = try out_allocator.dupe(u8, input);
        if (self.active_env) |env_name| {
            if (self.environments.get(env_name)) |env| {
                var secret_it = env.secrets.iterator();
                while (secret_it.next()) |entry| {
                    const secret_val = entry.value_ptr.*;
                    if (secret_val.len < 3) continue;
                    var pos: usize = 0;
                    while (pos + secret_val.len <= output.len) {
                        if (mem.eql(u8, output[pos .. pos + secret_val.len], secret_val)) {
                            @memset(output[pos .. pos + secret_val.len], '*');
                            pos += secret_val.len;
                        } else {
                            pos += 1;
                        }
                    }
                }
            }
        }
        return output;
    }

    /// Load an _env.volt file
    pub fn loadEnvFile(self: *EnvManager, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch return;
        defer self.allocator.free(content);

        // Parse _env.volt format:
        // environment: dev
        // variables:
        //   base_url: https://api.dev.example.com
        //   $api_key: secret123

        var current_env_name: ?[]const u8 = null;
        var in_variables = false;

        var lines = mem.splitSequence(u8, content, "\n");
        while (lines.next()) |raw_line| {
            const line = mem.trimRight(u8, raw_line, "\r");
            const trimmed = mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (mem.startsWith(u8, trimmed, "environment:")) {
                const val = mem.trim(u8, trimmed["environment:".len..], " \t");
                current_env_name = val;
                _ = try self.createEnv(val);
                in_variables = false;
            } else if (mem.eql(u8, trimmed, "variables:")) {
                in_variables = true;
            } else if (in_variables and current_env_name != null) {
                if (mem.indexOf(u8, trimmed, ": ")) |colon_pos| {
                    const key = trimmed[0..colon_pos];
                    const value = trimmed[colon_pos + 2 ..];
                    if (self.getEnv(current_env_name.?)) |env| {
                        try env.set(key, value);
                    }
                }
            }
        }
    }
};

fn resolveDynamic(allocator: Allocator, var_name: []const u8) ?[]const u8 {
    return DynamicVars.generateValue(allocator, var_name) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "environment basic operations" {
    var env = Environment.init(std.testing.allocator, "test");
    defer env.deinit();

    try env.set("base_url", "https://api.example.com");
    try std.testing.expectEqualStrings("https://api.example.com", env.get("base_url").?);
    try std.testing.expect(env.get("nonexistent") == null);
}

test "environment secrets" {
    var env = Environment.init(std.testing.allocator, "test");
    defer env.deinit();

    try env.set("$api_key", "secret123");
    try std.testing.expectEqualStrings("secret123", env.get("$api_key").?);
}

test "env manager variable resolution" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    const env = try mgr.createEnv("dev");
    try env.set("base_url", "https://dev.api.com");
    mgr.setActive("dev");

    try std.testing.expectEqualStrings("https://dev.api.com", mgr.resolve("base_url", null).?);
}

test "env manager interpolation" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    const env = try mgr.createEnv("dev");
    try env.set("host", "dev.api.com");
    try env.set("version", "v2");
    mgr.setActive("dev");

    const result = try mgr.interpolate("https://{{host}}/{{version}}/users", null, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("https://dev.api.com/v2/users", result);
}

test "unresolved variables kept as-is" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    const result = try mgr.interpolate("{{unknown_var}}", null, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("{{unknown_var}}", result);
}
