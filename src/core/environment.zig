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

// ── Variable Scope ──────────────────────────────────────────────────────

pub const VariableScope = enum {
    request,
    runtime,
    collection,
    environment,
    global,
    dynamic,
};

pub const ScopedValue = struct {
    value: ?[]const u8,
    scope: VariableScope,
};

// ── Environment Manager ─────────────────────────────────────────────────

pub const EnvManager = struct {
    allocator: Allocator,
    environments: std.StringHashMap(Environment),
    active_env: ?[]const u8,
    global_vars: std.StringHashMap([]const u8),
    runtime_vars: std.StringHashMap([]const u8),
    collection_vars: std.StringHashMap([]const u8),
    unresolved_vars: std.ArrayList([]const u8),
    env_file_contents: std.ArrayList([]const u8),

    pub fn init(allocator: Allocator) EnvManager {
        return .{
            .allocator = allocator,
            .environments = std.StringHashMap(Environment).init(allocator),
            .active_env = null,
            .global_vars = std.StringHashMap([]const u8).init(allocator),
            .runtime_vars = std.StringHashMap([]const u8).init(allocator),
            .collection_vars = std.StringHashMap([]const u8).init(allocator),
            .unresolved_vars = std.ArrayList([]const u8).init(allocator),
            .env_file_contents = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *EnvManager) void {
        var it = self.environments.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.environments.deinit();
        self.global_vars.deinit();
        self.clearRuntimeVars();
        self.runtime_vars.deinit();
        self.clearCollectionVars();
        self.collection_vars.deinit();
        self.unresolved_vars.deinit();

        for (self.env_file_contents.items) |c| {
            self.allocator.free(c);
        }
        self.env_file_contents.deinit();
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

    /// Resolve a variable by checking: request vars → runtime vars → collection vars → active env → global vars → dynamic vars
    pub fn resolve(self: *const EnvManager, key: []const u8, request_vars: ?*const std.StringHashMap([]const u8)) ?[]const u8 {
        // 1. Request-level variables
        if (request_vars) |rv| {
            if (rv.get(key)) |val| return val;
        }

        // 2. Runtime variables (set during collection runs via extract/set commands)
        if (self.runtime_vars.get(key)) |val| return val;

        // 3. Collection-level variables (from _collection.volt)
        if (self.collection_vars.get(key)) |val| return val;

        // 4. Active environment
        if (self.active_env) |env_name| {
            if (self.environments.get(env_name)) |env| {
                if (env.variables.get(key)) |val| return val;
                if (env.secrets.get(key)) |val| return val;
            }
        }

        // 5. Global variables
        if (self.global_vars.get(key)) |val| return val;

        return null;
    }

    /// Resolve a variable and return both the value and which scope it came from.
    /// Resolution order: request → runtime → collection → environment → global → dynamic.
    pub fn resolveWithScope(self: *const EnvManager, key: []const u8, request_vars: ?*const std.StringHashMap([]const u8)) ScopedValue {
        // 1. Request-level variables
        if (request_vars) |rv| {
            if (rv.get(key)) |val| return .{ .value = val, .scope = .request };
        }

        // 2. Runtime variables
        if (self.runtime_vars.get(key)) |val| return .{ .value = val, .scope = .runtime };

        // 3. Collection-level variables
        if (self.collection_vars.get(key)) |val| return .{ .value = val, .scope = .collection };

        // 4. Active environment
        if (self.active_env) |env_name| {
            if (self.environments.get(env_name)) |env| {
                if (env.variables.get(key)) |val| return .{ .value = val, .scope = .environment };
                if (env.secrets.get(key)) |val| return .{ .value = val, .scope = .environment };
            }
        }

        // 5. Global variables
        if (self.global_vars.get(key)) |val| return .{ .value = val, .scope = .global };

        // 5. Dynamic variables
        if (mem.startsWith(u8, key, "$")) {
            const dynamic_val = resolveDynamic(self.allocator, key);
            if (dynamic_val != null) {
                // Note: caller must be aware this is a dynamic allocation
                return .{ .value = dynamic_val, .scope = .dynamic };
            }
        }

        return .{ .value = null, .scope = .request };
    }

    /// Set a runtime variable (used during collection runs via extract/set commands).
    pub fn setRuntimeVar(self: *EnvManager, key: []const u8, value: []const u8) !void {
        if (self.runtime_vars.getPtr(key)) |existing| {
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, value);
            return;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.runtime_vars.put(key_copy, value_copy);
    }

    /// Clear all runtime variables.
    pub fn clearRuntimeVars(self: *EnvManager) void {
        var it = self.runtime_vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.runtime_vars.clearAndFree();
    }

    /// Set a collection-level variable (from _collection.volt).
    pub fn setCollectionVar(self: *EnvManager, key: []const u8, value: []const u8) !void {
        if (self.collection_vars.getPtr(key)) |existing| {
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, value);
            return;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.collection_vars.put(key_copy, value_copy);
    }

    /// Clear all collection-level variables.
    pub fn clearCollectionVars(self: *EnvManager) void {
        var it = self.collection_vars.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.collection_vars.clearAndFree();
    }

    /// Interpolate variables in a string: {{var_name}} → resolved value.
    /// Unresolved variables are kept as-is and added to self.unresolved_vars for caller inspection.
    pub fn interpolate(self: *EnvManager, input: []const u8, request_vars: ?*const std.StringHashMap([]const u8), allocator: Allocator) ![]const u8 {
        // Clear unresolved vars from any previous interpolation call
        self.unresolved_vars.clearRetainingCapacity();
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
                                // Keep original placeholder and track as unresolved
                                try result.appendSlice(input[i .. end + 2]);
                                try self.unresolved_vars.append(var_name);
                            }
                        }
                    } else if (self.resolve(var_name, request_vars)) |val| {
                        try result.appendSlice(val);
                    } else {
                        // Keep original placeholder if unresolved and track it
                        try result.appendSlice(input[i .. end + 2]);
                        try self.unresolved_vars.append(var_name);
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
        errdefer self.allocator.free(content);
        try self.env_file_contents.append(content);

        // Supports two formats:
        //
        // YAML-like format:
        //   environment: dev
        //   variables:
        //     base_url: https://api.dev.example.com
        //     $api_key: secret123
        //
        // INI-like format (created by `volt init`):
        //   [default]
        //   base_url = https://httpbin.org
        //   api_key = your-key

        var current_env_name: ?[]const u8 = null;
        var in_variables = false;

        var lines = mem.splitSequence(u8, content, "\n");
        while (lines.next()) |raw_line| {
            const line = mem.trimRight(u8, raw_line, "\r");
            const trimmed = mem.trim(u8, line, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // YAML-like: environment: dev
            if (mem.startsWith(u8, trimmed, "environment:")) {
                const val = mem.trim(u8, trimmed["environment:".len..], " \t");
                current_env_name = val;
                _ = try self.createEnv(val);
                self.setActive(val);
                in_variables = false;
            } else if (mem.eql(u8, trimmed, "variables:")) {
                in_variables = true;
            } else if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                // INI-like: [section_name]
                const section_name = trimmed[1 .. trimmed.len - 1];
                if (section_name.len > 0) {
                    current_env_name = section_name;
                    _ = try self.createEnv(section_name);
                    self.setActive(section_name);
                    in_variables = true; // variables follow directly
                }
            } else if (in_variables and current_env_name != null) {
                // YAML-like: key: value  OR  INI-like: key = value
                var key: ?[]const u8 = null;
                var value: ?[]const u8 = null;

                if (mem.indexOf(u8, trimmed, " = ")) |eq_pos| {
                    key = trimmed[0..eq_pos];
                    value = trimmed[eq_pos + 3 ..];
                } else if (mem.indexOf(u8, trimmed, ": ")) |colon_pos| {
                    key = trimmed[0..colon_pos];
                    value = trimmed[colon_pos + 2 ..];
                }

                if (key) |k| {
                    if (value) |v| {
                        if (self.getEnv(current_env_name.?)) |env| {
                            try env.set(k, v);
                        }
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

test "unresolved_vars tracking" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    const env = try mgr.createEnv("dev");
    try env.set("host", "localhost");
    mgr.setActive("dev");

    const result = try mgr.interpolate("{{host}}/{{missing_a}}/{{missing_b}}", null, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("localhost/{{missing_a}}/{{missing_b}}", result);

    // unresolved_vars should contain both missing variable names
    try std.testing.expectEqual(@as(usize, 2), mgr.unresolved_vars.items.len);
    try std.testing.expectEqualStrings("missing_a", mgr.unresolved_vars.items[0]);
    try std.testing.expectEqualStrings("missing_b", mgr.unresolved_vars.items[1]);
}

test "resolveWithScope returns correct scope" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Set up environment variable
    const env = try mgr.createEnv("dev");
    try env.set("env_var", "from_env");
    mgr.setActive("dev");

    // Set up global variable
    try mgr.global_vars.put("global_var", "from_global");

    // Set up runtime variable
    try mgr.setRuntimeVar("runtime_var", "from_runtime");

    // Set up request variables
    var req_vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer req_vars.deinit();
    try req_vars.put("req_var", "from_request");

    // Test request scope
    const req_result = mgr.resolveWithScope("req_var", &req_vars);
    try std.testing.expectEqualStrings("from_request", req_result.value.?);
    try std.testing.expect(req_result.scope == .request);

    // Test runtime scope
    const runtime_result = mgr.resolveWithScope("runtime_var", null);
    try std.testing.expectEqualStrings("from_runtime", runtime_result.value.?);
    try std.testing.expect(runtime_result.scope == .runtime);

    // Test environment scope
    const env_result = mgr.resolveWithScope("env_var", null);
    try std.testing.expectEqualStrings("from_env", env_result.value.?);
    try std.testing.expect(env_result.scope == .environment);

    // Test global scope
    const global_result = mgr.resolveWithScope("global_var", null);
    try std.testing.expectEqualStrings("from_global", global_result.value.?);
    try std.testing.expect(global_result.scope == .global);

    // Test not found
    const not_found = mgr.resolveWithScope("nonexistent", null);
    try std.testing.expect(not_found.value == null);
}

test "runtime variable resolution order" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Set the same key at multiple scopes
    const env = try mgr.createEnv("dev");
    try env.set("shared_key", "from_env");
    mgr.setActive("dev");
    try mgr.global_vars.put("shared_key", "from_global");
    try mgr.setRuntimeVar("shared_key", "from_runtime");

    // Runtime should win over environment and global
    try std.testing.expectEqualStrings("from_runtime", mgr.resolve("shared_key", null).?);

    // Request should win over runtime
    var req_vars = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer req_vars.deinit();
    try req_vars.put("shared_key", "from_request");
    try std.testing.expectEqualStrings("from_request", mgr.resolve("shared_key", &req_vars).?);

    // After clearing runtime vars, environment should be used
    mgr.clearRuntimeVars();
    try std.testing.expectEqualStrings("from_env", mgr.resolve("shared_key", null).?);
}

test "setRuntimeVar and clearRuntimeVars" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setRuntimeVar("token", "abc123");
    try mgr.setRuntimeVar("session_id", "sess_xyz");

    try std.testing.expectEqualStrings("abc123", mgr.resolve("token", null).?);
    try std.testing.expectEqualStrings("sess_xyz", mgr.resolve("session_id", null).?);

    mgr.clearRuntimeVars();

    try std.testing.expect(mgr.resolve("token", null) == null);
    try std.testing.expect(mgr.resolve("session_id", null) == null);
}

test "runtime vars interpolation" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setRuntimeVar("extracted_id", "42");

    const result = try mgr.interpolate("/api/users/{{extracted_id}}", null, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("/api/users/42", result);
}

test "collection vars resolution order" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    // Set the same key at multiple scopes
    const env = try mgr.createEnv("dev");
    try env.set("shared_key", "from_env");
    mgr.setActive("dev");
    try mgr.global_vars.put("shared_key", "from_global");
    try mgr.setCollectionVar("shared_key", "from_collection");

    // Collection should win over environment and global
    try std.testing.expectEqualStrings("from_collection", mgr.resolve("shared_key", null).?);

    // Runtime should win over collection
    try mgr.setRuntimeVar("shared_key", "from_runtime");
    try std.testing.expectEqualStrings("from_runtime", mgr.resolve("shared_key", null).?);

    // After clearing runtime, collection should be used
    mgr.clearRuntimeVars();
    try std.testing.expectEqualStrings("from_collection", mgr.resolve("shared_key", null).?);

    // After clearing collection, environment should be used
    mgr.clearCollectionVars();
    try std.testing.expectEqualStrings("from_env", mgr.resolve("shared_key", null).?);
}

test "resolveWithScope returns collection scope" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setCollectionVar("coll_var", "from_collection");

    const result = mgr.resolveWithScope("coll_var", null);
    try std.testing.expectEqualStrings("from_collection", result.value.?);
    try std.testing.expect(result.scope == .collection);
}

test "setCollectionVar and clearCollectionVars" {
    var mgr = EnvManager.init(std.testing.allocator);
    defer mgr.deinit();

    try mgr.setCollectionVar("base_url", "https://api.dev.com");
    try mgr.setCollectionVar("timeout", "5000");

    try std.testing.expectEqualStrings("https://api.dev.com", mgr.resolve("base_url", null).?);
    try std.testing.expectEqualStrings("5000", mgr.resolve("timeout", null).?);

    mgr.clearCollectionVars();

    try std.testing.expect(mgr.resolve("base_url", null) == null);
    try std.testing.expect(mgr.resolve("timeout", null) == null);
}
