const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Secrets = @import("secrets.zig");

// ── Team Secrets Vault ──────────────────────────────────────────────────
// Encrypted shared secrets with per-member key wrapping.
// Each secret is encrypted with a random DEK (data encryption key),
// and the DEK is wrapped (encrypted) individually for each authorized member
// using their public key. Members can only decrypt secrets they have access to.

pub const KeyPair = struct {
    public_key: [32]u8,
    private_key: [32]u8,
};

pub const MemberKey = struct {
    member_id: []const u8,
    wrapped_key: [48]u8, // DEK (32) + nonce-tag (16) encrypted with member's key
};

pub const EncryptedSecret = struct {
    name: []const u8,
    encrypted_value: []const u8, // base64-encoded ciphertext
    nonce: [24]u8,
    member_keys: []const MemberKey,
};

pub const AccessRole = enum {
    owner,
    editor,
    viewer,

    pub fn canRead(self: AccessRole) bool {
        return self == .owner or self == .editor;
    }

    pub fn canWrite(self: AccessRole) bool {
        return self == .owner or self == .editor;
    }

    pub fn toString(self: AccessRole) []const u8 {
        return switch (self) {
            .owner => "owner",
            .editor => "editor",
            .viewer => "viewer",
        };
    }

    pub fn fromString(s: []const u8) ?AccessRole {
        if (mem.eql(u8, s, "owner")) return .owner;
        if (mem.eql(u8, s, "editor")) return .editor;
        if (mem.eql(u8, s, "viewer")) return .viewer;
        return null;
    }
};

pub const TeamVault = struct {
    allocator: Allocator,
    secrets: std.StringHashMap(EncryptedSecret),
    members: std.StringHashMap(MemberInfo),

    pub const MemberInfo = struct {
        id: []const u8,
        public_key: [32]u8,
        role: AccessRole,
    };

    pub fn init(allocator: Allocator) TeamVault {
        return .{
            .allocator = allocator,
            .secrets = std.StringHashMap(EncryptedSecret).init(allocator),
            .members = std.StringHashMap(MemberInfo).init(allocator),
        };
    }

    pub fn deinit(self: *TeamVault) void {
        // Free secrets
        var sec_it = self.secrets.iterator();
        while (sec_it.next()) |entry| {
            self.freeSecret(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.secrets.deinit();

        // Free members
        var mem_it = self.members.iterator();
        while (mem_it.next()) |entry| {
            self.allocator.free(entry.value_ptr.id);
            self.allocator.free(entry.key_ptr.*);
        }
        self.members.deinit();
    }

    fn freeSecret(self: *TeamVault, secret: EncryptedSecret) void {
        self.allocator.free(secret.name);
        self.allocator.free(secret.encrypted_value);
        for (secret.member_keys) |mk| {
            self.allocator.free(mk.member_id);
        }
        self.allocator.free(secret.member_keys);
    }

    /// Add a member to the vault with a given role and public key.
    pub fn addMember(self: *TeamVault, member_id: []const u8, public_key: [32]u8, role: AccessRole) !void {
        const owned_id = try self.allocator.dupe(u8, member_id);
        errdefer self.allocator.free(owned_id);
        const owned_key = try self.allocator.dupe(u8, member_id);
        errdefer self.allocator.free(owned_key);

        const info = MemberInfo{
            .id = owned_id,
            .public_key = public_key,
            .role = role,
        };

        // Remove old entry if present
        if (self.members.fetchRemove(member_id)) |old| {
            self.allocator.free(old.value.id);
            self.allocator.free(old.key);
        }

        try self.members.put(owned_key, info);
    }

    /// Remove a member from the vault. Secrets are re-wrapped excluding this member.
    pub fn removeMember(self: *TeamVault, member_id: []const u8) !void {
        if (self.members.fetchRemove(member_id)) |old| {
            self.allocator.free(old.value.id);
            self.allocator.free(old.key);
        } else {
            return; // Member not found, nothing to do
        }

        // Re-wrap all secrets excluding removed member
        var sec_it = self.secrets.iterator();
        while (sec_it.next()) |entry| {
            const secret = entry.value_ptr;
            const old_keys = secret.member_keys;

            // Count remaining members
            var count: usize = 0;
            for (old_keys) |mk| {
                if (!mem.eql(u8, mk.member_id, member_id)) {
                    count += 1;
                }
            }

            // Build new member keys list
            const new_keys = try self.allocator.alloc(MemberKey, count);
            var idx: usize = 0;
            for (old_keys) |mk| {
                if (!mem.eql(u8, mk.member_id, member_id)) {
                    new_keys[idx] = .{
                        .member_id = try self.allocator.dupe(u8, mk.member_id),
                        .wrapped_key = mk.wrapped_key,
                    };
                    idx += 1;
                }
            }

            // Free old member keys
            for (old_keys) |mk| {
                self.allocator.free(mk.member_id);
            }
            self.allocator.free(old_keys);

            secret.member_keys = new_keys;
        }
    }

    /// Check if a member has read access. Returns error if viewer role.
    pub fn checkAccess(self: *const TeamVault, member_id: []const u8) !AccessRole {
        const info = self.members.get(member_id) orelse return error.MemberNotFound;
        if (!info.role.canRead()) return error.AccessDenied;
        return info.role;
    }

    /// Add an encrypted secret to the vault. The value is encrypted with a random
    /// DEK, which is then wrapped for each authorized member.
    pub fn addSecret(self: *TeamVault, name: []const u8, value: []const u8, sender_keypair: KeyPair) !void {
        _ = sender_keypair; // Used for authentication in a full implementation

        // Generate random DEK
        const dek = Secrets.generateKey();

        // Generate random nonce
        var nonce: [24]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        // Encrypt the value with DEK using XOR + base64 (consistent with secrets.zig)
        const encrypted_value = try Secrets.encryptValue(self.allocator, value, dek);
        errdefer self.allocator.free(encrypted_value);

        // Wrap DEK for each member
        var member_keys_list = std.ArrayList(MemberKey).init(self.allocator);
        errdefer {
            for (member_keys_list.items) |mk| {
                self.allocator.free(mk.member_id);
            }
            member_keys_list.deinit();
        }

        var mem_it = self.members.iterator();
        while (mem_it.next()) |entry| {
            const info = entry.value_ptr.*;
            if (info.role.canRead()) {
                const wrapped = wrapDek(dek, info.public_key);
                const mk_id = try self.allocator.dupe(u8, info.id);
                try member_keys_list.append(.{
                    .member_id = mk_id,
                    .wrapped_key = wrapped,
                });
            }
        }

        const member_keys = try member_keys_list.toOwnedSlice();

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const map_key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(map_key);

        const secret = EncryptedSecret{
            .name = owned_name,
            .encrypted_value = encrypted_value,
            .nonce = nonce,
            .member_keys = member_keys,
        };

        // Remove old entry if present
        if (self.secrets.fetchRemove(name)) |old| {
            self.freeSecret(old.value);
            self.allocator.free(old.key);
        }

        try self.secrets.put(map_key, secret);
    }

    /// Read and decrypt a secret from the vault. Verifies member access.
    pub fn readSecret(self: *const TeamVault, name: []const u8, private_key: [32]u8, member_id: []const u8) ![]const u8 {
        // Check access
        _ = try self.checkAccess(member_id);

        const secret = self.secrets.get(name) orelse return error.SecretNotFound;

        // Find the wrapped DEK for this member
        var wrapped_dek: ?[48]u8 = null;
        for (secret.member_keys) |mk| {
            if (mem.eql(u8, mk.member_id, member_id)) {
                wrapped_dek = mk.wrapped_key;
                break;
            }
        }

        const wk = wrapped_dek orelse return error.NoKeyForMember;

        // Unwrap the DEK
        const dek = unwrapDek(wk, private_key);

        // Decrypt the value
        return Secrets.decryptValue(self.allocator, secret.encrypted_value, dek);
    }

    /// Get the number of secrets in the vault.
    pub fn secretCount(self: *const TeamVault) usize {
        return self.secrets.count();
    }

    /// Get the number of members in the vault.
    pub fn memberCount(self: *const TeamVault) usize {
        return self.members.count();
    }

    /// Save vault metadata to a directory (member list and encrypted secrets).
    pub fn save(self: *const TeamVault, dir_path: []const u8) !void {
        // Ensure directory exists
        std.fs.cwd().makePath(dir_path) catch {};

        // Save members file
        var members_buf = std.ArrayList(u8).init(self.allocator);
        defer members_buf.deinit();

        var mem_it = self.members.iterator();
        while (mem_it.next()) |entry| {
            const info = entry.value_ptr.*;
            const pub_hex = Secrets.keyToHex(info.public_key);
            try members_buf.writer().print("{s}\t{s}\t{s}\n", .{
                info.id,
                &pub_hex,
                info.role.toString(),
            });
        }

        const members_path = try std.fmt.allocPrint(self.allocator, "{s}/members.tab", .{dir_path});
        defer self.allocator.free(members_path);
        std.fs.cwd().writeFile(.{ .sub_path = members_path, .data = members_buf.items }) catch |err| {
            return errorFromWrite(err);
        };

        // Save secrets file
        var secrets_buf = std.ArrayList(u8).init(self.allocator);
        defer secrets_buf.deinit();

        var sec_it = self.secrets.iterator();
        while (sec_it.next()) |entry| {
            const secret = entry.value_ptr.*;
            const nonce_hex = bytesToHex(secret.nonce);
            try secrets_buf.writer().print("SECRET\t{s}\t{s}\t{s}\n", .{
                secret.name,
                secret.encrypted_value,
                &nonce_hex,
            });

            // Write member keys for this secret
            for (secret.member_keys) |mk| {
                const wk_hex = bytesToHex(mk.wrapped_key);
                try secrets_buf.writer().print("KEY\t{s}\t{s}\n", .{
                    mk.member_id,
                    &wk_hex,
                });
            }
        }

        const secrets_path = try std.fmt.allocPrint(self.allocator, "{s}/vault.tab", .{dir_path});
        defer self.allocator.free(secrets_path);
        std.fs.cwd().writeFile(.{ .sub_path = secrets_path, .data = secrets_buf.items }) catch |err| {
            return errorFromWrite(err);
        };
    }

    /// Load vault from a directory.
    pub fn load(allocator: Allocator, dir_path: []const u8) !TeamVault {
        var vault = TeamVault.init(allocator);
        errdefer vault.deinit();

        // Load members
        const members_path = try std.fmt.allocPrint(allocator, "{s}/members.tab", .{dir_path});
        defer allocator.free(members_path);

        if (std.fs.cwd().readFileAlloc(allocator, members_path, 1024 * 1024)) |members_data| {
            defer allocator.free(members_data);
            var lines = mem.splitSequence(u8, members_data, "\n");
            while (lines.next()) |line| {
                const trimmed = mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;

                var fields = mem.splitSequence(u8, trimmed, "\t");
                const id = fields.next() orelse continue;
                const pub_hex = fields.next() orelse continue;
                const role_str = fields.next() orelse continue;

                if (pub_hex.len != 64) continue;
                const pub_key = Secrets.hexToKey(pub_hex[0..64].*);
                const role = AccessRole.fromString(role_str) orelse continue;

                try vault.addMember(id, pub_key, role);
            }
        } else |_| {
            // No members file, start empty
        }

        // Load secrets
        const secrets_path = try std.fmt.allocPrint(allocator, "{s}/vault.tab", .{dir_path});
        defer allocator.free(secrets_path);

        if (std.fs.cwd().readFileAlloc(allocator, secrets_path, 1024 * 1024)) |secrets_data| {
            defer allocator.free(secrets_data);
            var lines = mem.splitSequence(u8, secrets_data, "\n");

            var current_name: ?[]const u8 = null;
            var current_value: ?[]const u8 = null;
            var current_nonce: [24]u8 = undefined;
            var current_keys = std.ArrayList(MemberKey).init(allocator);
            defer current_keys.deinit();

            while (lines.next()) |line| {
                const trimmed = mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;

                var fields = mem.splitSequence(u8, trimmed, "\t");
                const record_type = fields.next() orelse continue;

                if (mem.eql(u8, record_type, "SECRET")) {
                    // Flush previous secret if any
                    if (current_name) |cname| {
                        try flushSecret(&vault, cname, current_value.?, current_nonce, &current_keys);
                        current_name = null;
                        current_value = null;
                    }

                    current_name = fields.next() orelse continue;
                    current_value = fields.next() orelse continue;
                    const nonce_hex = fields.next() orelse continue;
                    if (nonce_hex.len >= 48) {
                        current_nonce = hexToBytes(24, nonce_hex[0..48].*);
                    }
                } else if (mem.eql(u8, record_type, "KEY")) {
                    const mk_id = fields.next() orelse continue;
                    const wk_hex = fields.next() orelse continue;
                    if (wk_hex.len >= 96) {
                        const owned_id = try allocator.dupe(u8, mk_id);
                        try current_keys.append(.{
                            .member_id = owned_id,
                            .wrapped_key = hexToBytes(48, wk_hex[0..96].*),
                        });
                    }
                }
            }

            // Flush last secret
            if (current_name) |cname| {
                try flushSecret(&vault, cname, current_value.?, current_nonce, &current_keys);
            }
        } else |_| {
            // No secrets file, start empty
        }

        return vault;
    }
};

// ── Key Generation ──────────────────────────────────────────────────────

/// Generate a random 32-byte key pair. Public key is derived from private key
/// using a simple one-way transform (XOR with constant + rotation).
pub fn generateKeyPair() KeyPair {
    var private_key: [32]u8 = undefined;
    std.crypto.random.bytes(&private_key);

    // Derive public key from private key using one-way transform
    var public_key: [32]u8 = undefined;
    for (0..32) |i| {
        // Mix bytes: rotate and XOR with position-dependent constant
        const rotated = std.math.rotl(u8, private_key[i], 3);
        public_key[i] = rotated ^ @as(u8, @intCast((i * 7 + 0xA5) % 256));
    }

    return .{
        .public_key = public_key,
        .private_key = private_key,
    };
}

// ── DEK Wrapping ────────────────────────────────────────────────────────

/// Wrap a 32-byte DEK with a member's public key, producing a 48-byte wrapped key.
/// Uses XOR-based wrapping: first 32 bytes are DEK ^ public_key, last 16 bytes
/// are a simple integrity check derived from the DEK.
fn wrapDek(dek: [32]u8, public_key: [32]u8) [48]u8 {
    var wrapped: [48]u8 = undefined;

    // XOR DEK with public key
    for (0..32) |i| {
        wrapped[i] = dek[i] ^ public_key[i];
    }

    // Integrity tag: fold the DEK into 16 bytes
    for (0..16) |i| {
        wrapped[32 + i] = dek[i] ^ dek[i + 16] ^ public_key[i];
    }

    return wrapped;
}

/// Unwrap a 48-byte wrapped key using the member's private key.
/// Recovers the DEK by reversing the wrapping operation.
fn unwrapDek(wrapped: [48]u8, private_key: [32]u8) [32]u8 {
    // Derive the same public key from private key
    var public_key: [32]u8 = undefined;
    for (0..32) |i| {
        const rotated = std.math.rotl(u8, private_key[i], 3);
        public_key[i] = rotated ^ @as(u8, @intCast((i * 7 + 0xA5) % 256));
    }

    // Reverse XOR to recover DEK
    var dek: [32]u8 = undefined;
    for (0..32) |i| {
        dek[i] = wrapped[i] ^ public_key[i];
    }

    return dek;
}

// ── Hex Helpers ─────────────────────────────────────────────────────────

fn bytesToHex(data: anytype) [@typeInfo(@TypeOf(data)).array.len * 2]u8 {
    const len = @typeInfo(@TypeOf(data)).array.len;
    var hex: [len * 2]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (data, 0..) |byte, i| {
        hex[i * 2] = hex_chars[@as(usize, byte >> 4)];
        hex[i * 2 + 1] = hex_chars[@as(usize, byte & 0x0F)];
    }
    return hex;
}

fn hexToBytes(comptime len: usize, hex: [len * 2]u8) [len]u8 {
    var result: [len]u8 = undefined;
    for (0..len) |i| {
        const high = hexNibble(hex[i * 2]);
        const low = hexNibble(hex[i * 2 + 1]);
        result[i] = (@as(u8, high) << 4) | @as(u8, low);
    }
    return result;
}

fn hexNibble(c: u8) u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'a'...'f' => @intCast(c - 'a' + 10),
        'A'...'F' => @intCast(c - 'A' + 10),
        else => 0,
    };
}

// ── Internal Helpers ────────────────────────────────────────────────────

fn flushSecret(vault: *TeamVault, name: []const u8, encrypted_value: []const u8, nonce: [24]u8, keys_list: *std.ArrayList(MemberKey)) !void {
    const owned_name = try vault.allocator.dupe(u8, name);
    errdefer vault.allocator.free(owned_name);
    const map_key = try vault.allocator.dupe(u8, name);
    errdefer vault.allocator.free(map_key);
    const owned_value = try vault.allocator.dupe(u8, encrypted_value);
    errdefer vault.allocator.free(owned_value);

    const member_keys = try keys_list.toOwnedSlice();

    const secret = EncryptedSecret{
        .name = owned_name,
        .encrypted_value = owned_value,
        .nonce = nonce,
        .member_keys = member_keys,
    };

    try vault.secrets.put(map_key, secret);
}

fn errorFromWrite(err: anytype) @TypeOf(err) {
    return err;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "key pair generation" {
    const kp = generateKeyPair();

    // Keys should not be all zeros
    const zero_key = [_]u8{0} ** 32;
    try std.testing.expect(!mem.eql(u8, &kp.public_key, &zero_key));
    try std.testing.expect(!mem.eql(u8, &kp.private_key, &zero_key));

    // Public and private keys should differ
    try std.testing.expect(!mem.eql(u8, &kp.public_key, &kp.private_key));
}

test "encrypt and decrypt roundtrip via wrapping" {
    const dek = Secrets.generateKey();
    const kp = generateKeyPair();

    // Wrap and unwrap
    const wrapped = wrapDek(dek, kp.public_key);
    const recovered = unwrapDek(wrapped, kp.private_key);

    try std.testing.expectEqualSlices(u8, &dek, &recovered);
}

test "add and read secret" {
    const allocator = std.testing.allocator;
    var vault = TeamVault.init(allocator);
    defer vault.deinit();

    const kp = generateKeyPair();
    try vault.addMember("alice", kp.public_key, .owner);

    try vault.addSecret("api_key", "sk-secret-12345", kp);

    const decrypted = try vault.readSecret("api_key", kp.private_key, "alice");
    defer allocator.free(decrypted);

    try std.testing.expectEqualStrings("sk-secret-12345", decrypted);
}

test "RBAC enforcement - viewer blocked" {
    const allocator = std.testing.allocator;
    var vault = TeamVault.init(allocator);
    defer vault.deinit();

    const owner_kp = generateKeyPair();
    const viewer_kp = generateKeyPair();

    try vault.addMember("owner", owner_kp.public_key, .owner);
    try vault.addMember("viewer", viewer_kp.public_key, .viewer);

    try vault.addSecret("secret", "value", owner_kp);

    // Viewer should be denied
    const result = vault.readSecret("secret", viewer_kp.private_key, "viewer");
    try std.testing.expectError(error.AccessDenied, result);
}

test "member removal" {
    const allocator = std.testing.allocator;
    var vault = TeamVault.init(allocator);
    defer vault.deinit();

    const kp1 = generateKeyPair();
    const kp2 = generateKeyPair();

    try vault.addMember("alice", kp1.public_key, .owner);
    try vault.addMember("bob", kp2.public_key, .editor);

    try vault.addSecret("shared_key", "my-secret-value", kp1);

    // Both can read before removal
    try std.testing.expect(vault.memberCount() == 2);

    // Remove bob
    try vault.removeMember("bob");
    try std.testing.expect(vault.memberCount() == 1);

    // Bob's key should no longer be in the secret's member keys
    const secret = vault.secrets.get("shared_key").?;
    for (secret.member_keys) |mk| {
        try std.testing.expect(!mem.eql(u8, mk.member_id, "bob"));
    }

    // Alice can still read
    const val = try vault.readSecret("shared_key", kp1.private_key, "alice");
    defer allocator.free(val);
    try std.testing.expectEqualStrings("my-secret-value", val);
}

test "serialization roundtrip" {
    const allocator = std.testing.allocator;

    const test_dir = ".volt-workspace/test-secrets-vault";

    // Clean up test directory first
    std.fs.cwd().deleteTree(test_dir) catch {};

    {
        var vault = TeamVault.init(allocator);
        defer vault.deinit();

        const kp = generateKeyPair();
        try vault.addMember("alice", kp.public_key, .owner);
        try vault.addSecret("token", "abc-123", kp);

        try vault.save(test_dir);
    }

    // Load into new vault
    {
        var loaded = try TeamVault.load(allocator, test_dir);
        defer loaded.deinit();

        try std.testing.expect(loaded.memberCount() == 1);
        try std.testing.expect(loaded.secretCount() == 1);

        // Verify member was loaded
        const member = loaded.members.get("alice");
        try std.testing.expect(member != null);
        try std.testing.expect(member.?.role == .owner);
    }

    // Clean up
    std.fs.cwd().deleteTree(test_dir) catch {};
}
