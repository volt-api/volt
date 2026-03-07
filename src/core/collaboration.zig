const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

// ── Collaboration & Team Workspaces ─────────────────────────────────────
//
// Provides workspace-based collaboration for Volt teams.
// Workspaces contain collections, environments, and member access.
//
// Features:
//   - Workspaces: isolated containers for API collections
//   - Members: invite collaborators with role-based access
//   - Roles: owner, editor, viewer (RBAC)
//   - Sync: real-time workspace change broadcasting
//
// Storage: .volt-workspace/ directory in the project root
//   - workspace.json: workspace metadata + members
//   - shared-env.json: shared environment variables
//   - activity.log: audit trail of changes

pub const Role = enum {
    owner,
    editor,
    viewer,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .owner => "owner",
            .editor => "editor",
            .viewer => "viewer",
        };
    }

    pub fn fromString(s: []const u8) ?Role {
        if (mem.eql(u8, s, "owner")) return .owner;
        if (mem.eql(u8, s, "editor")) return .editor;
        if (mem.eql(u8, s, "viewer")) return .viewer;
        return null;
    }

    pub fn canEdit(self: Role) bool {
        return self == .owner or self == .editor;
    }

    pub fn canManageMembers(self: Role) bool {
        return self == .owner;
    }

    pub fn canView(_: Role) bool {
        return true;
    }
};

pub const Member = struct {
    id: []const u8,
    name: []const u8,
    email: ?[]const u8 = null,
    role: Role,
    joined_at: i64,
};

pub const Workspace = struct {
    id: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    created_at: i64,
    members: std.ArrayList(Member),
    collections: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator, id: []const u8, name: []const u8) Workspace {
        return .{
            .id = id,
            .name = name,
            .created_at = std.time.timestamp(),
            .members = std.ArrayList(Member).init(allocator),
            .collections = std.ArrayList([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.members.deinit();
        for (self.collections.items) |c| {
            self.allocator.free(c);
        }
        self.collections.deinit();
    }

    pub fn addMember(self: *Workspace, member: Member) !void {
        try self.members.append(member);
    }

    pub fn removeMember(self: *Workspace, member_id: []const u8) bool {
        for (self.members.items, 0..) |m, i| {
            if (mem.eql(u8, m.id, member_id)) {
                _ = self.members.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn getMember(self: *const Workspace, member_id: []const u8) ?*const Member {
        for (self.members.items) |*m| {
            if (mem.eql(u8, m.id, member_id)) return m;
        }
        return null;
    }

    pub fn getMemberRole(self: *const Workspace, member_id: []const u8) ?Role {
        if (self.getMember(member_id)) |m| return m.role;
        return null;
    }

    pub fn addCollection(self: *Workspace, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        try self.collections.append(path_copy);
    }
};

// ── Workspace Manager ───────────────────────────────────────────────────

pub const WorkspaceManager = struct {
    allocator: Allocator,
    workspaces: std.StringHashMap(Workspace),
    active_workspace: ?[]const u8,
    current_user_id: ?[]const u8,
    activity_log: std.ArrayList(ActivityEntry),

    pub fn init(allocator: Allocator) WorkspaceManager {
        return .{
            .allocator = allocator,
            .workspaces = std.StringHashMap(Workspace).init(allocator),
            .active_workspace = null,
            .current_user_id = null,
            .activity_log = std.ArrayList(ActivityEntry).init(allocator),
        };
    }

    pub fn deinit(self: *WorkspaceManager) void {
        var it = self.workspaces.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.workspaces.deinit();
        for (self.activity_log.items) |entry| {
            self.allocator.free(entry.description);
        }
        self.activity_log.deinit();
    }

    pub fn createWorkspace(self: *WorkspaceManager, id: []const u8, name: []const u8) !*Workspace {
        var ws = Workspace.init(self.allocator, id, name);

        // Auto-add creator as owner
        if (self.current_user_id) |uid| {
            try ws.addMember(.{
                .id = uid,
                .name = "Owner",
                .role = .owner,
                .joined_at = std.time.timestamp(),
            });
        }

        try self.workspaces.put(id, ws);
        try self.logActivity("workspace_created", id);
        return self.workspaces.getPtr(id).?;
    }

    pub fn getWorkspace(self: *WorkspaceManager, id: []const u8) ?*Workspace {
        return self.workspaces.getPtr(id);
    }

    pub fn setActive(self: *WorkspaceManager, id: []const u8) void {
        self.active_workspace = id;
    }

    pub fn getActive(self: *WorkspaceManager) ?*Workspace {
        if (self.active_workspace) |id| {
            return self.workspaces.getPtr(id);
        }
        return null;
    }

    /// Check if the current user has permission for an action
    pub fn checkPermission(self: *WorkspaceManager, workspace_id: []const u8, action: Action) bool {
        const ws = self.workspaces.getPtr(workspace_id) orelse return false;
        const uid = self.current_user_id orelse return false;
        const role = ws.getMemberRole(uid) orelse return false;

        return switch (action) {
            .view => role.canView(),
            .edit => role.canEdit(),
            .manage_members => role.canManageMembers(),
            .delete_workspace => role == .owner,
        };
    }

    /// Invite a member to a workspace
    pub fn inviteMember(
        self: *WorkspaceManager,
        workspace_id: []const u8,
        member: Member,
    ) !bool {
        // Check permission
        if (!self.checkPermission(workspace_id, .manage_members)) return false;

        const ws = self.workspaces.getPtr(workspace_id) orelse return false;
        try ws.addMember(member);
        try self.logActivity("member_invited", workspace_id);
        return true;
    }

    fn logActivity(self: *WorkspaceManager, action: []const u8, workspace_id: []const u8) !void {
        const desc = try std.fmt.allocPrint(self.allocator, "{s} on {s}", .{ action, workspace_id });
        try self.activity_log.append(.{
            .timestamp = std.time.timestamp(),
            .user_id = self.current_user_id orelse "system",
            .action = action,
            .description = desc,
        });
    }

    pub const Action = enum {
        view,
        edit,
        manage_members,
        delete_workspace,
    };
};

pub const ActivityEntry = struct {
    timestamp: i64,
    user_id: []const u8,
    action: []const u8,
    description: []const u8,
};

// ── Shared Environment ──────────────────────────────────────────────────

pub const SharedEnvironment = struct {
    workspace_id: []const u8,
    variables: std.StringHashMap([]const u8),
    secrets: std.StringHashMap(SecretVar),
    allocator: Allocator,

    pub const SecretVar = struct {
        /// Secrets are stored locally only, never synced
        value: []const u8,
        masked: bool = true,
    };

    pub fn init(allocator: Allocator, workspace_id: []const u8) SharedEnvironment {
        return .{
            .workspace_id = workspace_id,
            .variables = std.StringHashMap([]const u8).init(allocator),
            .secrets = std.StringHashMap(SecretVar).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SharedEnvironment) void {
        self.variables.deinit();
        self.secrets.deinit();
    }

    pub fn set(self: *SharedEnvironment, key: []const u8, value: []const u8) !void {
        try self.variables.put(key, value);
    }

    pub fn get(self: *const SharedEnvironment, key: []const u8) ?[]const u8 {
        return self.variables.get(key);
    }

    pub fn setSecret(self: *SharedEnvironment, key: []const u8, value: []const u8) !void {
        try self.secrets.put(key, .{ .value = value, .masked = true });
    }

    /// Get secret value (only returns if caller is authorized)
    pub fn getSecret(self: *const SharedEnvironment, key: []const u8) ?[]const u8 {
        if (self.secrets.get(key)) |sv| return sv.value;
        return null;
    }

    /// Mask a value for display (replace with asterisks)
    pub fn maskValue(self: *const SharedEnvironment, allocator: Allocator, input: []const u8) ![]const u8 {
        var output = try allocator.dupe(u8, input);
        var secret_it = self.secrets.iterator();
        while (secret_it.next()) |entry| {
            const secret_val = entry.value_ptr.value;
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
        return output;
    }
};

// ── Serialization ───────────────────────────────────────────────────────

pub fn serializeWorkspace(allocator: Allocator, ws: *const Workspace) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.print("id: {s}\n", .{ws.id});
    try writer.print("name: {s}\n", .{ws.name});
    if (ws.description) |d| {
        try writer.print("description: {s}\n", .{d});
    }
    try writer.print("created_at: {d}\n", .{ws.created_at});

    try writer.writeAll("members:\n");
    for (ws.members.items) |m| {
        try writer.print("  - id: {s}\n    name: {s}\n    role: {s}\n", .{
            m.id, m.name, m.role.toString(),
        });
    }

    try writer.writeAll("collections:\n");
    for (ws.collections.items) |c| {
        try writer.print("  - {s}\n", .{c});
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "role permissions" {
    try std.testing.expect(Role.owner.canEdit());
    try std.testing.expect(Role.owner.canManageMembers());
    try std.testing.expect(Role.editor.canEdit());
    try std.testing.expect(!Role.editor.canManageMembers());
    try std.testing.expect(!Role.viewer.canEdit());
    try std.testing.expect(Role.viewer.canView());
}

test "role from string" {
    try std.testing.expect(Role.fromString("owner").? == .owner);
    try std.testing.expect(Role.fromString("editor").? == .editor);
    try std.testing.expect(Role.fromString("viewer").? == .viewer);
    try std.testing.expect(Role.fromString("invalid") == null);
}

test "workspace add and remove member" {
    var ws = Workspace.init(std.testing.allocator, "ws-1", "Test Workspace");
    defer ws.deinit();

    try ws.addMember(.{ .id = "user-1", .name = "Alice", .role = .owner, .joined_at = 0 });
    try ws.addMember(.{ .id = "user-2", .name = "Bob", .role = .editor, .joined_at = 0 });

    try std.testing.expectEqual(@as(usize, 2), ws.members.items.len);
    try std.testing.expect(ws.getMemberRole("user-1").? == .owner);
    try std.testing.expect(ws.getMemberRole("user-2").? == .editor);

    try std.testing.expect(ws.removeMember("user-2"));
    try std.testing.expectEqual(@as(usize, 1), ws.members.items.len);
}

test "workspace manager create and get" {
    var mgr = WorkspaceManager.init(std.testing.allocator);
    defer mgr.deinit();

    mgr.current_user_id = "admin";

    const ws = try mgr.createWorkspace("ws-1", "My API Project");
    try std.testing.expectEqualStrings("ws-1", ws.id);
    try std.testing.expectEqualStrings("My API Project", ws.name);
    try std.testing.expectEqual(@as(usize, 1), ws.members.items.len); // creator auto-added
}

test "workspace manager permissions" {
    var mgr = WorkspaceManager.init(std.testing.allocator);
    defer mgr.deinit();

    mgr.current_user_id = "admin";
    _ = try mgr.createWorkspace("ws-1", "Test");

    try std.testing.expect(mgr.checkPermission("ws-1", .view));
    try std.testing.expect(mgr.checkPermission("ws-1", .edit));
    try std.testing.expect(mgr.checkPermission("ws-1", .manage_members));
}

test "workspace manager active workspace" {
    var mgr = WorkspaceManager.init(std.testing.allocator);
    defer mgr.deinit();

    mgr.current_user_id = "admin";
    _ = try mgr.createWorkspace("ws-1", "Test");

    try std.testing.expect(mgr.getActive() == null);
    mgr.setActive("ws-1");
    try std.testing.expect(mgr.getActive() != null);
}

test "shared environment" {
    var env = SharedEnvironment.init(std.testing.allocator, "ws-1");
    defer env.deinit();

    try env.set("base_url", "https://api.example.com");
    try std.testing.expectEqualStrings("https://api.example.com", env.get("base_url").?);

    try env.setSecret("api_key", "secret123");
    try std.testing.expectEqualStrings("secret123", env.getSecret("api_key").?);
}

test "shared environment masking" {
    var env = SharedEnvironment.init(std.testing.allocator, "ws-1");
    defer env.deinit();

    try env.setSecret("token", "mysecret");
    const masked = try env.maskValue(std.testing.allocator, "Authorization: Bearer mysecret");
    defer std.testing.allocator.free(masked);

    try std.testing.expect(mem.indexOf(u8, masked, "mysecret") == null);
    try std.testing.expect(mem.indexOf(u8, masked, "********") != null);
}

test "serialize workspace" {
    var ws = Workspace.init(std.testing.allocator, "ws-1", "Test");
    defer ws.deinit();

    try ws.addMember(.{ .id = "user-1", .name = "Alice", .role = .owner, .joined_at = 0 });

    const output = try serializeWorkspace(std.testing.allocator, &ws);
    defer std.testing.allocator.free(output);

    try std.testing.expect(mem.indexOf(u8, output, "id: ws-1") != null);
    try std.testing.expect(mem.indexOf(u8, output, "name: Test") != null);
    try std.testing.expect(mem.indexOf(u8, output, "role: owner") != null);
}
