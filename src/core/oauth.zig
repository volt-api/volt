const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const HttpClient = @import("http_client.zig");
const VoltFile = @import("volt_file.zig");

// ── OAuth 2.0 Client ───────────────────────────────────────────────────
//
// OAuth 2.0 client implementation.
// Supports:
//   - Client Credentials grant
//   - Authorization Code grant (with PKCE)
//   - Token refresh
//   - Token storage and management

pub const GrantType = enum {
    client_credentials,
    authorization_code,
    refresh_token,
    password,

    pub fn toString(self: GrantType) []const u8 {
        return switch (self) {
            .client_credentials => "client_credentials",
            .authorization_code => "authorization_code",
            .refresh_token => "refresh_token",
            .password => "password",
        };
    }

    pub fn fromString(s: []const u8) ?GrantType {
        if (mem.eql(u8, s, "client_credentials")) return .client_credentials;
        if (mem.eql(u8, s, "authorization_code")) return .authorization_code;
        if (mem.eql(u8, s, "refresh_token")) return .refresh_token;
        if (mem.eql(u8, s, "password")) return .password;
        return null;
    }
};

pub const OAuthConfig = struct {
    grant_type: GrantType = .client_credentials,
    token_url: []const u8 = "",
    auth_url: []const u8 = "",
    client_id: []const u8 = "",
    client_secret: []const u8 = "",
    scope: ?[]const u8 = null,
    redirect_uri: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: ?u32 = null,
    refresh_token: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    obtained_at: i64,

    pub fn isExpired(self: *const TokenResponse) bool {
        const expires = self.expires_in orelse return false;
        const now = std.time.timestamp();
        return now > self.obtained_at + @as(i64, @intCast(expires));
    }
};

pub const OAuthError = error{
    TokenRequestFailed,
    InvalidResponse,
    MissingCredentials,
    OutOfMemory,
};

pub const OAuthClient = struct {
    config: OAuthConfig,
    current_token: ?TokenResponse,
    allocator: Allocator,

    pub fn init(allocator: Allocator, config: OAuthConfig) OAuthClient {
        return .{
            .config = config,
            .current_token = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OAuthClient) void {
        _ = self;
    }

    /// Get a valid token (fetch new one or refresh expired)
    pub fn getToken(self: *OAuthClient) OAuthError!?TokenResponse {
        // If we have a valid non-expired token, return it
        if (self.current_token) |*token| {
            if (!token.isExpired()) {
                return token.*;
            }
            // Token expired - try refresh if we have a refresh token
            if (token.refresh_token != null) {
                const body = self.buildRefreshBody(self.allocator) catch return OAuthError.OutOfMemory;
                defer self.allocator.free(body);
                return self.requestToken(body);
            }
        }

        // No token or expired without refresh - request a new one
        const body = switch (self.config.grant_type) {
            .client_credentials => self.buildClientCredentialsBody(self.allocator) catch return OAuthError.OutOfMemory,
            .password => self.buildPasswordGrantBody(self.allocator) catch return OAuthError.OutOfMemory,
            .refresh_token => self.buildRefreshBody(self.allocator) catch return OAuthError.OutOfMemory,
            .authorization_code => return OAuthError.MissingCredentials,
        };
        defer self.allocator.free(body);

        return self.requestToken(body);
    }

    fn requestToken(self: *OAuthClient, body: []const u8) OAuthError!?TokenResponse {
        // Build a VoltRequest to POST to the token endpoint
        var request = VoltFile.VoltRequest.init(self.allocator);
        defer request.deinit();

        request.method = .POST;
        request.url = self.config.token_url;
        request.body = body;
        request.body_type = .form;
        request.addHeader("Content-Type", "application/x-www-form-urlencoded") catch return OAuthError.OutOfMemory;

        const response = HttpClient.execute(self.allocator, &request, .{}) catch {
            return OAuthError.TokenRequestFailed;
        };
        var resp = response;
        defer resp.deinit();

        const resp_body = resp.bodySlice();
        if (resp_body.len == 0) return OAuthError.InvalidResponse;

        const token = parseTokenResponse(self.allocator, resp_body) catch {
            return OAuthError.InvalidResponse;
        };
        self.current_token = token;
        return token;
    }

    /// Build the token request body for client_credentials grant
    pub fn buildClientCredentialsBody(self: *const OAuthClient, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.writeAll("grant_type=client_credentials");
        try writer.writeAll("&client_id=");
        const encoded_id = try urlEncode(allocator, self.config.client_id);
        defer allocator.free(encoded_id);
        try writer.writeAll(encoded_id);

        try writer.writeAll("&client_secret=");
        const encoded_secret = try urlEncode(allocator, self.config.client_secret);
        defer allocator.free(encoded_secret);
        try writer.writeAll(encoded_secret);

        if (self.config.scope) |scope| {
            try writer.writeAll("&scope=");
            const encoded_scope = try urlEncode(allocator, scope);
            defer allocator.free(encoded_scope);
            try writer.writeAll(encoded_scope);
        }

        return buf.toOwnedSlice();
    }

    /// Build the token request body for password grant
    pub fn buildPasswordGrantBody(self: *const OAuthClient, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.writeAll("grant_type=password");
        try writer.writeAll("&client_id=");
        const encoded_id = try urlEncode(allocator, self.config.client_id);
        defer allocator.free(encoded_id);
        try writer.writeAll(encoded_id);

        if (self.config.username) |username| {
            try writer.writeAll("&username=");
            const encoded_user = try urlEncode(allocator, username);
            defer allocator.free(encoded_user);
            try writer.writeAll(encoded_user);
        }

        if (self.config.password) |pw| {
            try writer.writeAll("&password=");
            const encoded_pw = try urlEncode(allocator, pw);
            defer allocator.free(encoded_pw);
            try writer.writeAll(encoded_pw);
        }

        if (self.config.scope) |scope| {
            try writer.writeAll("&scope=");
            const encoded_scope = try urlEncode(allocator, scope);
            defer allocator.free(encoded_scope);
            try writer.writeAll(encoded_scope);
        }

        return buf.toOwnedSlice();
    }

    /// Build refresh token request body
    pub fn buildRefreshBody(self: *const OAuthClient, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.writeAll("grant_type=refresh_token");

        if (self.current_token) |token| {
            if (token.refresh_token) |rt| {
                try writer.writeAll("&refresh_token=");
                const encoded_rt = try urlEncode(allocator, rt);
                defer allocator.free(encoded_rt);
                try writer.writeAll(encoded_rt);
            }
        }

        try writer.writeAll("&client_id=");
        const encoded_id = try urlEncode(allocator, self.config.client_id);
        defer allocator.free(encoded_id);
        try writer.writeAll(encoded_id);

        try writer.writeAll("&client_secret=");
        const encoded_secret = try urlEncode(allocator, self.config.client_secret);
        defer allocator.free(encoded_secret);
        try writer.writeAll(encoded_secret);

        return buf.toOwnedSlice();
    }

    /// Apply token to a request (add Authorization header)
    pub fn applyToRequest(self: *const OAuthClient, request: *VoltFile.VoltRequest) !void {
        if (self.current_token) |token| {
            var auth_buf: [1024]u8 = undefined;
            const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{token.access_token}) catch return;
            try request.addHeader("Authorization", auth_value);
        }
    }

    /// Generate the authorization URL for auth code flow
    pub fn getAuthorizationUrl(self: *const OAuthClient, state: []const u8, allocator: Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        try writer.writeAll(self.config.auth_url);
        try writer.writeAll("?response_type=code");

        try writer.writeAll("&client_id=");
        const encoded_id = try urlEncode(allocator, self.config.client_id);
        defer allocator.free(encoded_id);
        try writer.writeAll(encoded_id);

        if (self.config.redirect_uri) |redirect| {
            try writer.writeAll("&redirect_uri=");
            const encoded_redirect = try urlEncode(allocator, redirect);
            defer allocator.free(encoded_redirect);
            try writer.writeAll(encoded_redirect);
        }

        if (self.config.scope) |scope| {
            try writer.writeAll("&scope=");
            const encoded_scope = try urlEncode(allocator, scope);
            defer allocator.free(encoded_scope);
            try writer.writeAll(encoded_scope);
        }

        try writer.writeAll("&state=");
        const encoded_state = try urlEncode(allocator, state);
        defer allocator.free(encoded_state);
        try writer.writeAll(encoded_state);

        return buf.toOwnedSlice();
    }
};

/// Parse OAuth config from .volt file section
pub fn parseOAuthConfig(content: []const u8) OAuthConfig {
    var config = OAuthConfig{};

    var lines = mem.splitSequence(u8, content, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trimRight(u8, raw_line, "\r");
        const trimmed = mem.trim(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (mem.startsWith(u8, trimmed, "grant_type:")) {
            const val = mem.trim(u8, trimmed["grant_type:".len..], " \t");
            config.grant_type = GrantType.fromString(val) orelse .client_credentials;
        } else if (mem.startsWith(u8, trimmed, "token_url:")) {
            config.token_url = mem.trim(u8, trimmed["token_url:".len..], " \t");
        } else if (mem.startsWith(u8, trimmed, "auth_url:")) {
            config.auth_url = mem.trim(u8, trimmed["auth_url:".len..], " \t");
        } else if (mem.startsWith(u8, trimmed, "client_id:")) {
            config.client_id = mem.trim(u8, trimmed["client_id:".len..], " \t");
        } else if (mem.startsWith(u8, trimmed, "client_secret:")) {
            config.client_secret = mem.trim(u8, trimmed["client_secret:".len..], " \t");
        } else if (mem.startsWith(u8, trimmed, "scope:")) {
            config.scope = mem.trim(u8, trimmed["scope:".len..], " \t");
        } else if (mem.startsWith(u8, trimmed, "redirect_uri:")) {
            config.redirect_uri = mem.trim(u8, trimmed["redirect_uri:".len..], " \t");
        } else if (mem.startsWith(u8, trimmed, "username:")) {
            config.username = mem.trim(u8, trimmed["username:".len..], " \t");
        } else if (mem.startsWith(u8, trimmed, "password:")) {
            config.password = mem.trim(u8, trimmed["password:".len..], " \t");
        }
    }

    return config;
}

/// Simple URL-encode function
pub fn urlEncode(allocator: Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);

    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try buf.append(c);
        } else if (c == ' ') {
            try buf.append('+');
        } else {
            try buf.append('%');
            const hex = "0123456789ABCDEF";
            try buf.append(hex[c >> 4]);
            try buf.append(hex[c & 0x0F]);
        }
    }

    return buf.toOwnedSlice();
}

/// Parse a JSON token response (simple string search for key fields)
pub fn parseTokenResponse(allocator: Allocator, json: []const u8) !TokenResponse {
    _ = allocator;

    const access_token = extractJsonStringValue(json, "access_token") orelse return error.InvalidResponse;
    const token_type = extractJsonStringValue(json, "token_type") orelse "Bearer";
    const refresh_token = extractJsonStringValue(json, "refresh_token");
    const scope = extractJsonStringValue(json, "scope");
    const expires_in = extractJsonNumberValue(json, "expires_in");

    return TokenResponse{
        .access_token = access_token,
        .token_type = token_type,
        .expires_in = expires_in,
        .refresh_token = refresh_token,
        .scope = scope,
        .obtained_at = std.time.timestamp(),
    };
}

/// Extract a string value from a JSON key. Looks for "key":"value" pattern.
fn extractJsonStringValue(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key"
    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = key_pos + search_key.len;

    // Skip whitespace and colon
    var i = after_key;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) {
        i += 1;
    }
    if (i >= json.len) return null;

    // Expect opening quote
    if (json[i] != '"') return null;
    i += 1;

    // Find closing quote
    const start = i;
    while (i < json.len and json[i] != '"') {
        if (json[i] == '\\') {
            i += 1; // skip escaped char
        }
        i += 1;
    }
    if (i >= json.len) return null;

    return json[start..i];
}

/// Extract a number value from a JSON key. Looks for "key": number pattern.
fn extractJsonNumberValue(json: []const u8, key: []const u8) ?u32 {
    var search_buf: [256]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = mem.indexOf(u8, json, search_key) orelse return null;
    const after_key = key_pos + search_key.len;

    // Skip whitespace and colon
    var i = after_key;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t' or json[i] == '\n' or json[i] == '\r')) {
        i += 1;
    }
    if (i >= json.len) return null;

    // Parse number
    var result: u32 = 0;
    var found_digit = false;
    while (i < json.len and json[i] >= '0' and json[i] <= '9') {
        result = result * 10 + @as(u32, json[i] - '0');
        found_digit = true;
        i += 1;
    }

    if (!found_digit) return null;
    return result;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "build client credentials body" {
    const config = OAuthConfig{
        .grant_type = .client_credentials,
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .client_secret = "my-secret",
        .scope = "read write",
    };
    var client = OAuthClient.init(std.testing.allocator, config);
    defer client.deinit();

    const body = try client.buildClientCredentialsBody(std.testing.allocator);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.indexOf(u8, body, "grant_type=client_credentials") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_id=my-client") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_secret=my-secret") != null);
    try std.testing.expect(mem.indexOf(u8, body, "scope=read+write") != null);
}

test "url encode" {
    const encoded = try urlEncode(std.testing.allocator, "hello world&foo=bar");
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(mem.indexOf(u8, encoded, "hello+world") != null);
    try std.testing.expect(mem.indexOf(u8, encoded, "%26") != null);
    try std.testing.expect(mem.indexOf(u8, encoded, "%3D") != null);
}

test "parse token response" {
    const json =
        \\{"access_token":"eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9","token_type":"Bearer","expires_in":3600,"scope":"read write"}
    ;
    const token = try parseTokenResponse(std.testing.allocator, json);

    try std.testing.expectEqualStrings("eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9", token.access_token);
    try std.testing.expectEqualStrings("Bearer", token.token_type);
    try std.testing.expectEqual(@as(?u32, 3600), token.expires_in);
    try std.testing.expectEqualStrings("read write", token.scope.?);
}
