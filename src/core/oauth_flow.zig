const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const builtin = @import("builtin");

// ── OAuth 2.0 Browser-Based Authorization Flow ──────────────────────
//
// Implements the OAuth 2.0 Authorization Code flow with PKCE (RFC 7636).
// Supports:
//   - PKCE challenge generation (code_verifier + code_challenge)
//   - Authorization URL construction
//   - Local callback server request parsing
//   - Token exchange body building
//   - Token serialization/deserialization for .volt-tokens files
//   - Browser launch (cross-platform)
//   - CSRF state parameter generation

// ── PKCE (Proof Key for Code Exchange) ──────────────────────────────

pub const PKCEChallenge = struct {
    code_verifier: [43]u8,
    code_challenge: [43]u8,
};

/// Generate a PKCE challenge pair (code_verifier and code_challenge).
/// code_verifier: 32 random bytes -> base64url-encoded (no padding), yielding 43 chars.
/// code_challenge: SHA256(code_verifier) -> base64url-encoded (no padding), yielding 43 chars.
pub fn generatePKCE() PKCEChallenge {
    // Generate 32 random bytes for the verifier
    var random_bytes: [32]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);

    // Base64url-encode to produce the code_verifier (43 chars from 32 bytes)
    var verifier: [43]u8 = undefined;
    base64urlEncode(&verifier, &random_bytes);

    // SHA256 hash of the verifier string
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&verifier, &hash, .{});

    // Base64url-encode the hash to produce the code_challenge (43 chars from 32 bytes)
    var challenge: [43]u8 = undefined;
    base64urlEncode(&challenge, &hash);

    return .{
        .code_verifier = verifier,
        .code_challenge = challenge,
    };
}

// ── Base64url Encoding ──────────────────────────────────────────────

const base64url_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Encode exactly 32 bytes into 43 base64url characters (no padding).
/// 32 bytes = 256 bits -> ceil(256/6) = 43 base64url characters.
fn base64urlEncode(dest: *[43]u8, src: *const [32]u8) void {
    var bit_buf: u32 = 0;
    var bits_in_buf: u5 = 0;
    var out_idx: usize = 0;
    var in_idx: usize = 0;

    while (out_idx < 43) {
        // Feed more bytes into the bit buffer when needed
        while (bits_in_buf < 6 and in_idx < 32) {
            bit_buf = (bit_buf << 8) | @as(u32, src[in_idx]);
            bits_in_buf += 8;
            in_idx += 1;
        }

        // Extract the top 6 bits
        if (bits_in_buf >= 6) {
            const shift: u5 = bits_in_buf - 6;
            const idx: u6 = @intCast((bit_buf >> shift) & 0x3F);
            dest[out_idx] = base64url_alphabet[idx];
            bit_buf &= (@as(u32, 1) << shift) - 1;
            bits_in_buf -= 6;
        } else {
            // Last partial group: shift remaining bits to the left
            const shift: u5 = 6 - bits_in_buf;
            const idx: u6 = @intCast((bit_buf << shift) & 0x3F);
            dest[out_idx] = base64url_alphabet[idx];
            bits_in_buf = 0;
            bit_buf = 0;
        }
        out_idx += 1;
    }
}

// ── Authorization URL Builder ───────────────────────────────────────

pub const AuthFlowConfig = struct {
    auth_url: []const u8,
    token_url: []const u8,
    client_id: []const u8,
    client_secret: ?[]const u8 = null,
    redirect_port: u16 = 8234,
    scope: ?[]const u8 = null,
    state: ?[]const u8 = null,
};

/// Build the full authorization URL with all required query parameters.
/// Caller owns the returned slice.
pub fn buildAuthorizationUrl(allocator: Allocator, config: AuthFlowConfig, pkce: PKCEChallenge) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll(config.auth_url);
    try writer.writeAll("?client_id=");
    const encoded_id = try urlEncode(allocator, config.client_id);
    defer allocator.free(encoded_id);
    try writer.writeAll(encoded_id);

    // redirect_uri = http://localhost:<port>/callback
    try writer.writeAll("&redirect_uri=");
    var redirect_buf: [64]u8 = undefined;
    const redirect_uri = std.fmt.bufPrint(&redirect_buf, "http://localhost:{d}/callback", .{config.redirect_port}) catch return error.OutOfMemory;
    const encoded_redirect = try urlEncode(allocator, redirect_uri);
    defer allocator.free(encoded_redirect);
    try writer.writeAll(encoded_redirect);

    try writer.writeAll("&response_type=code");

    if (config.scope) |scope| {
        try writer.writeAll("&scope=");
        const encoded_scope = try urlEncode(allocator, scope);
        defer allocator.free(encoded_scope);
        try writer.writeAll(encoded_scope);
    }

    try writer.writeAll("&code_challenge=");
    try writer.writeAll(&pkce.code_challenge);

    try writer.writeAll("&code_challenge_method=S256");

    if (config.state) |state| {
        try writer.writeAll("&state=");
        const encoded_state = try urlEncode(allocator, state);
        defer allocator.free(encoded_state);
        try writer.writeAll(encoded_state);
    }

    return buf.toOwnedSlice();
}

// ── Callback Request Parsing ────────────────────────────────────────

pub const CallbackResult = struct {
    code: ?[]const u8,
    state: ?[]const u8,
    error_msg: ?[]const u8,
};

/// Parse the raw HTTP GET request from the browser redirect.
/// Extracts `code`, `state`, and `error` query parameters from requests like:
///   GET /callback?code=AUTH_CODE&state=STATE HTTP/1.1
pub fn parseCallbackRequest(raw_request: []const u8) CallbackResult {
    var result = CallbackResult{
        .code = null,
        .state = null,
        .error_msg = null,
    };

    // Find the request line (first line up to \r\n or \n)
    const line_end = mem.indexOf(u8, raw_request, "\r\n") orelse
        mem.indexOf(u8, raw_request, "\n") orelse
        raw_request.len;
    const request_line = raw_request[0..line_end];

    // Extract the path+query from "GET /callback?... HTTP/1.1"
    const path_start = mem.indexOf(u8, request_line, " ") orelse return result;
    const after_method = request_line[path_start + 1 ..];
    const path_end = mem.indexOf(u8, after_method, " ") orelse after_method.len;
    const path_query = after_method[0..path_end];

    // Split on '?' to get the query string
    const query_start = mem.indexOf(u8, path_query, "?") orelse return result;
    const query_string = path_query[query_start + 1 ..];

    // Parse query parameters
    var params = mem.splitScalar(u8, query_string, '&');
    while (params.next()) |param| {
        const eq_pos = mem.indexOf(u8, param, "=") orelse continue;
        const key = param[0..eq_pos];
        const value = param[eq_pos + 1 ..];

        if (mem.eql(u8, key, "code")) {
            result.code = value;
        } else if (mem.eql(u8, key, "state")) {
            result.state = value;
        } else if (mem.eql(u8, key, "error")) {
            result.error_msg = value;
        }
    }

    return result;
}

// ── Token Exchange ──────────────────────────────────────────────────

/// Build the URL-encoded form body for the token exchange request.
/// Caller owns the returned slice.
pub fn buildTokenExchangeBody(
    allocator: Allocator,
    code: []const u8,
    config: AuthFlowConfig,
    pkce: PKCEChallenge,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("grant_type=authorization_code");

    try writer.writeAll("&code=");
    const encoded_code = try urlEncode(allocator, code);
    defer allocator.free(encoded_code);
    try writer.writeAll(encoded_code);

    try writer.writeAll("&redirect_uri=");
    var redirect_buf: [64]u8 = undefined;
    const redirect_uri = std.fmt.bufPrint(&redirect_buf, "http://localhost:{d}/callback", .{config.redirect_port}) catch return error.OutOfMemory;
    const encoded_redirect = try urlEncode(allocator, redirect_uri);
    defer allocator.free(encoded_redirect);
    try writer.writeAll(encoded_redirect);

    try writer.writeAll("&client_id=");
    const encoded_id = try urlEncode(allocator, config.client_id);
    defer allocator.free(encoded_id);
    try writer.writeAll(encoded_id);

    try writer.writeAll("&code_verifier=");
    try writer.writeAll(&pkce.code_verifier);

    if (config.client_secret) |secret| {
        try writer.writeAll("&client_secret=");
        const encoded_secret = try urlEncode(allocator, secret);
        defer allocator.free(encoded_secret);
        try writer.writeAll(encoded_secret);
    }

    return buf.toOwnedSlice();
}

// ── Token Storage ───────────────────────────────────────────────────

pub const StoredToken = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8,
    expires_at: i64,
    scope: ?[]const u8,
    provider: []const u8,
};

/// Serialize a StoredToken to a simple key: value text format for .volt-tokens files.
/// Caller owns the returned slice.
pub fn serializeToken(allocator: Allocator, token: StoredToken) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("access_token: ");
    try writer.writeAll(token.access_token);
    try writer.writeAll("\n");

    if (token.refresh_token) |rt| {
        try writer.writeAll("refresh_token: ");
        try writer.writeAll(rt);
        try writer.writeAll("\n");
    }

    try writer.print("expires_at: {d}\n", .{token.expires_at});

    if (token.scope) |scope| {
        try writer.writeAll("scope: ");
        try writer.writeAll(scope);
        try writer.writeAll("\n");
    }

    try writer.writeAll("provider: ");
    try writer.writeAll(token.provider);
    try writer.writeAll("\n");

    return buf.toOwnedSlice();
}

/// Parse a StoredToken from key: value text format.
/// Returns null if required fields (access_token, provider) are missing.
/// The returned token fields point into the original content slice.
pub fn parseStoredToken(allocator: Allocator, content: []const u8) ?StoredToken {
    _ = allocator;

    var access_token: ?[]const u8 = null;
    var refresh_token: ?[]const u8 = null;
    var expires_at: i64 = 0;
    var scope: ?[]const u8 = null;
    var provider: ?[]const u8 = null;

    var lines = mem.splitSequence(u8, content, "\n");
    while (lines.next()) |raw_line| {
        const line = mem.trimRight(u8, raw_line, "\r");
        const trimmed = mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (mem.startsWith(u8, trimmed, "access_token: ")) {
            access_token = trimmed["access_token: ".len..];
        } else if (mem.startsWith(u8, trimmed, "refresh_token: ")) {
            refresh_token = trimmed["refresh_token: ".len..];
        } else if (mem.startsWith(u8, trimmed, "expires_at: ")) {
            const val_str = trimmed["expires_at: ".len..];
            expires_at = std.fmt.parseInt(i64, val_str, 10) catch 0;
        } else if (mem.startsWith(u8, trimmed, "scope: ")) {
            scope = trimmed["scope: ".len..];
        } else if (mem.startsWith(u8, trimmed, "provider: ")) {
            provider = trimmed["provider: ".len..];
        }
    }

    if (access_token == null or provider == null) return null;

    return StoredToken{
        .access_token = access_token.?,
        .refresh_token = refresh_token,
        .expires_at = expires_at,
        .scope = scope,
        .provider = provider.?,
    };
}

// ── Browser Launch ──────────────────────────────────────────────────

pub const BrowserCommand = struct {
    prog: []const u8,
    args: [2][]const u8,
};

/// Return the platform-specific command to open a URL in the default browser.
pub fn getBrowserCommand(url: []const u8) BrowserCommand {
    return switch (builtin.os.tag) {
        .windows => .{
            .prog = "rundll32",
            .args = .{ "url.dll,FileProtocolHandler", url },
        },
        .macos => .{
            .prog = "open",
            .args = .{ url, "" },
        },
        else => .{
            // Linux and other Unix-like systems
            .prog = "xdg-open",
            .args = .{ url, "" },
        },
    };
}

// ── Callback HTML Response ──────────────────────────────────────────

const success_response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n" ++
    "<html><body><h1>Authorization successful!</h1>" ++
    "<p>You can close this tab.</p></body></html>";

const error_response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n" ++
    "<html><body><h1>Authorization failed.</h1>" ++
    "<p>Please try again.</p></body></html>";

/// Return an HTTP response with an HTML page to display in the browser after callback.
pub fn buildCallbackResponse(success: bool) []const u8 {
    return if (success) success_response else error_response;
}

// ── URL Encoding ────────────────────────────────────────────────────

/// Percent-encode non-URL-safe characters.
/// Caller owns the returned slice.
pub fn urlEncode(allocator: Allocator, input: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

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

// ── State Parameter Generation ──────────────────────────────────────

/// Generate a 16-byte random hex string for use as a CSRF state parameter.
/// Returns 32 hex characters packed into a [16]u8 array of the raw random bytes,
/// suitable for hex-encoding when used.
pub fn generateState() [16]u8 {
    var state: [16]u8 = undefined;
    std.crypto.random.bytes(&state);
    return state;
}

/// Format a state value as a 32-character hex string.
pub fn formatStateHex(state: [16]u8) [32]u8 {
    var hex: [32]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (state, 0..) |byte, i| {
        hex[i * 2] = hex_chars[@as(usize, byte >> 4)];
        hex[i * 2 + 1] = hex_chars[@as(usize, byte & 0x0F)];
    }
    return hex;
}

// ── Full Flow Orchestration ─────────────────────────────────────────

pub const AuthFlowState = struct {
    pkce: PKCEChallenge,
    state: [16]u8,
    authorization_url: []const u8,
    config: AuthFlowConfig,
    allocator: Allocator,

    pub fn deinit(self: *AuthFlowState) void {
        self.allocator.free(self.authorization_url);
    }
};

/// Initialize the authorization flow: generate PKCE, state, and build the authorization URL.
/// Caller must call deinit() on the returned AuthFlowState.
pub fn startAuthFlow(allocator: Allocator, config: AuthFlowConfig) !AuthFlowState {
    const pkce = generatePKCE();
    const state = generateState();
    const state_hex = formatStateHex(state);

    // Build config with state for the URL
    var url_config = config;
    url_config.state = &state_hex;

    const auth_url = try buildAuthorizationUrl(allocator, url_config, pkce);

    return AuthFlowState{
        .pkce = pkce,
        .state = state,
        .authorization_url = auth_url,
        .config = config,
        .allocator = allocator,
    };
}

// ── Local Callback Server ───────────────────────────────────────────
//
// TCP listener that captures the OAuth authorization code from the browser redirect.
// The browser redirects to http://localhost:<port>/callback?code=AUTH_CODE&state=STATE
// and this server captures the code, responds with a success/error page, then closes.

pub const CallbackServer = struct {
    allocator: Allocator,
    port: u16,
    server: ?std.net.Server,

    pub fn init(allocator: Allocator, port: u16) CallbackServer {
        return .{
            .allocator = allocator,
            .port = port,
            .server = null,
        };
    }

    /// Start listening on the configured port.
    pub fn listen(self: *CallbackServer) !void {
        const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, self.port);
        self.server = try address.listen(.{
            .reuse_address = true,
        });
    }

    /// Wait for the browser callback, parse the authorization code, and respond.
    /// Returns the parsed CallbackResult containing the auth code.
    /// Returned string slices are heap-allocated; caller must free them.
    /// Blocks until a connection is received or timeout occurs.
    pub fn waitForCallback(self: *CallbackServer) !CallbackResult {
        var server = self.server orelse return error.ServerNotStarted;

        const connection = try server.accept();
        defer connection.stream.close();

        // Read the HTTP request
        var request_buf: [4096]u8 = undefined;
        const bytes_read = try connection.stream.read(&request_buf);
        if (bytes_read == 0) return error.EmptyRequest;

        const raw_request = request_buf[0..bytes_read];

        // Parse the callback parameters (slices point into stack buffer)
        const parsed = parseCallbackRequest(raw_request);

        // Send response to browser
        const response_html = buildCallbackResponse(parsed.code != null and parsed.error_msg == null);
        connection.stream.writeAll(response_html) catch |err| {
            std.debug.print("warning: oauth_flow: callback response write failed: {s}\n", .{@errorName(err)});
        };

        // Dupe strings to heap so they outlive the stack buffer
        return CallbackResult{
            .code = if (parsed.code) |c| self.allocator.dupe(u8, c) catch null else null,
            .state = if (parsed.state) |s| self.allocator.dupe(u8, s) catch null else null,
            .error_msg = if (parsed.error_msg) |e| self.allocator.dupe(u8, e) catch null else null,
        };
    }

    /// Clean up the server resources.
    pub fn deinit(self: *CallbackServer) void {
        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }
    }
};

/// Run the complete OAuth callback flow:
/// 1. Start local callback server
/// 2. Open browser to authorization URL
/// 3. Wait for callback with auth code
/// Returns the authorization code on success.
pub fn runCallbackFlow(allocator: Allocator, flow: *AuthFlowState) ![]const u8 {
    // Start callback server
    var server = CallbackServer.init(allocator, flow.config.redirect_port);
    defer server.deinit();
    try server.listen();

    // Open browser to authorization URL
    const browser_cmd = getBrowserCommand(flow.authorization_url);
    const argv: []const []const u8 = &.{ browser_cmd.prog, browser_cmd.args[0], browser_cmd.args[1] };
    var child = std.process.Child.init(argv, allocator);
    child.spawn() catch |err| {
        std.debug.print("warning: oauth_flow: browser launch failed: {s}\n", .{@errorName(err)});
    };

    // Wait for callback (returned strings are heap-allocated)
    const result = try server.waitForCallback();
    defer {
        if (result.state) |s| allocator.free(s);
        if (result.error_msg) |e| allocator.free(e);
    }

    if (result.error_msg) |_| {
        if (result.code) |c| allocator.free(c);
        return error.AuthorizationDenied;
    }

    if (result.code) |code| {
        return code; // Transfer ownership to caller
    }

    return error.NoAuthorizationCode;
}

// ── Token Auto-Refresh ──────────────────────────────────────────────

/// Check if a stored token is expired.
/// Returns true if the current time is past the token's expiry time,
/// accounting for a 60-second buffer for clock skew.
pub fn isTokenExpired(token: StoredToken) bool {
    const now = std.time.timestamp();
    // Subtract 60-second buffer: treat token as expired 60s before actual expiry
    // to account for clock skew between client and server.
    return now >= (token.expires_at - 60);
}

/// Check if a token should be automatically refreshed.
/// Returns true if the token has a refresh_token AND is within 5 minutes
/// of expiry or already expired.
pub fn shouldAutoRefresh(token: StoredToken) bool {
    // Must have a refresh token to be eligible for auto-refresh
    if (token.refresh_token == null) return false;

    const now = std.time.timestamp();
    const five_minutes: i64 = 5 * 60; // 300 seconds

    // Auto-refresh if within 5 minutes of expiry or already expired
    return now >= (token.expires_at - five_minutes);
}

/// Build the URL-encoded form body for a token refresh request.
/// Uses grant_type=refresh_token per RFC 6749 Section 6.
/// Caller owns the returned slice.
pub fn buildRefreshTokenBody(
    allocator: Allocator,
    refresh_token: []const u8,
    config: AuthFlowConfig,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("grant_type=refresh_token");

    try writer.writeAll("&refresh_token=");
    const encoded_token = try urlEncode(allocator, refresh_token);
    defer allocator.free(encoded_token);
    try writer.writeAll(encoded_token);

    try writer.writeAll("&client_id=");
    const encoded_id = try urlEncode(allocator, config.client_id);
    defer allocator.free(encoded_id);
    try writer.writeAll(encoded_id);

    if (config.client_secret) |secret| {
        try writer.writeAll("&client_secret=");
        const encoded_secret = try urlEncode(allocator, secret);
        defer allocator.free(encoded_secret);
        try writer.writeAll(encoded_secret);
    }

    if (config.scope) |scope| {
        try writer.writeAll("&scope=");
        const encoded_scope = try urlEncode(allocator, scope);
        defer allocator.free(encoded_scope);
        try writer.writeAll(encoded_scope);
    }

    return buf.toOwnedSlice();
}

// ── Client Credentials Grant (RFC 6749 Section 4.4) ─────────────────

/// Build the URL-encoded form body for a Client Credentials grant request.
/// Used for machine-to-machine authentication (no user involvement).
/// Caller owns the returned slice.
pub fn buildClientCredentialsBody(
    allocator: Allocator,
    config: AuthFlowConfig,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("grant_type=client_credentials");

    try writer.writeAll("&client_id=");
    const encoded_id = try urlEncode(allocator, config.client_id);
    defer allocator.free(encoded_id);
    try writer.writeAll(encoded_id);

    if (config.client_secret) |secret| {
        try writer.writeAll("&client_secret=");
        const encoded_secret = try urlEncode(allocator, secret);
        defer allocator.free(encoded_secret);
        try writer.writeAll(encoded_secret);
    }

    if (config.scope) |scope| {
        try writer.writeAll("&scope=");
        const encoded_scope = try urlEncode(allocator, scope);
        defer allocator.free(encoded_scope);
        try writer.writeAll(encoded_scope);
    }

    return buf.toOwnedSlice();
}

// ── Resource Owner Password Grant (RFC 6749 Section 4.3) ────────────

/// Build the URL-encoded form body for a Password grant request.
/// Uses resource owner's credentials directly (username + password).
/// Caller owns the returned slice.
pub fn buildPasswordGrantBody(
    allocator: Allocator,
    username: []const u8,
    password: []const u8,
    config: AuthFlowConfig,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("grant_type=password");

    try writer.writeAll("&username=");
    const encoded_user = try urlEncode(allocator, username);
    defer allocator.free(encoded_user);
    try writer.writeAll(encoded_user);

    try writer.writeAll("&password=");
    const encoded_pass = try urlEncode(allocator, password);
    defer allocator.free(encoded_pass);
    try writer.writeAll(encoded_pass);

    try writer.writeAll("&client_id=");
    const encoded_id = try urlEncode(allocator, config.client_id);
    defer allocator.free(encoded_id);
    try writer.writeAll(encoded_id);

    if (config.client_secret) |secret| {
        try writer.writeAll("&client_secret=");
        const encoded_secret = try urlEncode(allocator, secret);
        defer allocator.free(encoded_secret);
        try writer.writeAll(encoded_secret);
    }

    if (config.scope) |scope| {
        try writer.writeAll("&scope=");
        const encoded_scope = try urlEncode(allocator, scope);
        defer allocator.free(encoded_scope);
        try writer.writeAll(encoded_scope);
    }

    return buf.toOwnedSlice();
}

// ── Implicit Grant (RFC 6749 Section 4.2) ───────────────────────────

/// Build the authorization URL for the Implicit grant flow.
/// Returns a URL that redirects with an access_token fragment (no code exchange).
/// Caller owns the returned slice.
pub fn buildImplicitAuthUrl(
    allocator: Allocator,
    config: AuthFlowConfig,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll(config.auth_url);
    try writer.writeAll("?client_id=");
    const encoded_id = try urlEncode(allocator, config.client_id);
    defer allocator.free(encoded_id);
    try writer.writeAll(encoded_id);

    try writer.writeAll("&redirect_uri=");
    var redirect_buf: [64]u8 = undefined;
    const redirect_uri = std.fmt.bufPrint(&redirect_buf, "http://localhost:{d}/callback", .{config.redirect_port}) catch return error.OutOfMemory;
    const encoded_redirect = try urlEncode(allocator, redirect_uri);
    defer allocator.free(encoded_redirect);
    try writer.writeAll(encoded_redirect);

    try writer.writeAll("&response_type=token");

    if (config.scope) |scope| {
        try writer.writeAll("&scope=");
        const encoded_scope = try urlEncode(allocator, scope);
        defer allocator.free(encoded_scope);
        try writer.writeAll(encoded_scope);
    }

    if (config.state) |state| {
        try writer.writeAll("&state=");
        const encoded_state = try urlEncode(allocator, state);
        defer allocator.free(encoded_state);
        try writer.writeAll(encoded_state);
    }

    return buf.toOwnedSlice();
}

// ── Tests ───────────────────────────────────────────────────────────────

test "CallbackServer init" {
    var server = CallbackServer.init(std.testing.allocator, 8234);
    defer server.deinit();

    try std.testing.expectEqual(@as(u16, 8234), server.port);
    try std.testing.expect(server.server == null);
}

test "PKCE generation - verifier length" {
    const pkce = generatePKCE();
    try std.testing.expectEqual(@as(usize, 43), pkce.code_verifier.len);
}

test "PKCE generation - challenge length" {
    const pkce = generatePKCE();
    try std.testing.expectEqual(@as(usize, 43), pkce.code_challenge.len);
}

test "PKCE generation - verifier and challenge differ" {
    const pkce = generatePKCE();
    try std.testing.expect(!mem.eql(u8, &pkce.code_verifier, &pkce.code_challenge));
}

test "PKCE generation - characters are base64url safe" {
    const pkce = generatePKCE();
    for (pkce.code_verifier) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
    for (pkce.code_challenge) |c| {
        try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '-' or c == '_');
    }
}

test "build authorization URL contains required params" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client-id",
        .redirect_port = 8234,
        .scope = "openid profile",
        .state = "test-state-value",
    };

    const pkce = PKCEChallenge{
        .code_verifier = "abcdefghijklmnopqrstuvwxyz01234567890ABCDEF".*,
        .code_challenge = "XYZabcdefghijklmnopqrstuvwxyz0123456789ABCD".*,
    };

    const url = try buildAuthorizationUrl(std.testing.allocator, config, pkce);
    defer std.testing.allocator.free(url);

    try std.testing.expect(mem.startsWith(u8, url, "https://auth.example.com/authorize?"));
    try std.testing.expect(mem.indexOf(u8, url, "client_id=my-client-id") != null);
    try std.testing.expect(mem.indexOf(u8, url, "redirect_uri=") != null);
    try std.testing.expect(mem.indexOf(u8, url, "response_type=code") != null);
    try std.testing.expect(mem.indexOf(u8, url, "scope=openid+profile") != null);
    try std.testing.expect(mem.indexOf(u8, url, "code_challenge=XYZabcdefghijklmnopqrstuvwxyz0123456789ABC") != null);
    try std.testing.expect(mem.indexOf(u8, url, "code_challenge_method=S256") != null);
    try std.testing.expect(mem.indexOf(u8, url, "state=test-state-value") != null);
}

test "parse callback request - valid code and state" {
    const request = "GET /callback?code=abc123&state=xyz789 HTTP/1.1\r\nHost: localhost:8234\r\n\r\n";
    const result = parseCallbackRequest(request);

    try std.testing.expectEqualStrings("abc123", result.code.?);
    try std.testing.expectEqualStrings("xyz789", result.state.?);
    try std.testing.expect(result.error_msg == null);
}

test "parse callback request - error response" {
    const request = "GET /callback?error=access_denied&state=xyz789 HTTP/1.1\r\n\r\n";
    const result = parseCallbackRequest(request);

    try std.testing.expect(result.code == null);
    try std.testing.expectEqualStrings("xyz789", result.state.?);
    try std.testing.expectEqualStrings("access_denied", result.error_msg.?);
}

test "parse callback request - missing params" {
    const request = "GET /callback HTTP/1.1\r\n\r\n";
    const result = parseCallbackRequest(request);

    try std.testing.expect(result.code == null);
    try std.testing.expect(result.state == null);
    try std.testing.expect(result.error_msg == null);
}

test "build token exchange body" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .client_secret = "my-secret",
        .redirect_port = 9090,
    };

    const pkce = PKCEChallenge{
        .code_verifier = "abcdefghijklmnopqrstuvwxyz01234567890ABCDEF".*,
        .code_challenge = "XYZabcdefghijklmnopqrstuvwxyz0123456789ABCD".*,
    };

    const body = try buildTokenExchangeBody(std.testing.allocator, "AUTH_CODE_123", config, pkce);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.indexOf(u8, body, "grant_type=authorization_code") != null);
    try std.testing.expect(mem.indexOf(u8, body, "code=AUTH_CODE_123") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_id=my-client") != null);
    try std.testing.expect(mem.indexOf(u8, body, "code_verifier=abcdefghijklmnopqrstuvwxyz01234567890ABCDE") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_secret=my-secret") != null);
    try std.testing.expect(mem.indexOf(u8, body, "redirect_uri=") != null);
}

test "token serialization and deserialization roundtrip" {
    const original = StoredToken{
        .access_token = "eyJhbGciOiJSUzI1NiJ9.test",
        .refresh_token = "dGVzdC1yZWZyZXNoLXRva2Vu",
        .expires_at = 1700000000,
        .scope = "read write",
        .provider = "google",
    };

    const serialized = try serializeToken(std.testing.allocator, original);
    defer std.testing.allocator.free(serialized);

    const parsed = parseStoredToken(std.testing.allocator, serialized) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqualStrings(original.access_token, parsed.access_token);
    try std.testing.expectEqualStrings(original.refresh_token.?, parsed.refresh_token.?);
    try std.testing.expectEqual(original.expires_at, parsed.expires_at);
    try std.testing.expectEqualStrings(original.scope.?, parsed.scope.?);
    try std.testing.expectEqualStrings(original.provider, parsed.provider);
}

test "token serialization without optional fields" {
    const token = StoredToken{
        .access_token = "some-token",
        .refresh_token = null,
        .expires_at = 1234567890,
        .scope = null,
        .provider = "github",
    };

    const serialized = try serializeToken(std.testing.allocator, token);
    defer std.testing.allocator.free(serialized);

    try std.testing.expect(mem.indexOf(u8, serialized, "access_token: some-token") != null);
    try std.testing.expect(mem.indexOf(u8, serialized, "provider: github") != null);
    try std.testing.expect(mem.indexOf(u8, serialized, "refresh_token:") == null);
    try std.testing.expect(mem.indexOf(u8, serialized, "scope:") == null);

    const parsed = parseStoredToken(std.testing.allocator, serialized) orelse {
        return error.TestUnexpectedResult;
    };
    try std.testing.expect(parsed.refresh_token == null);
    try std.testing.expect(parsed.scope == null);
}

test "parse stored token returns null for missing required fields" {
    const content = "scope: read\nexpires_at: 100\n";
    const result = parseStoredToken(std.testing.allocator, content);
    try std.testing.expect(result == null);
}

test "url encode" {
    const encoded = try urlEncode(std.testing.allocator, "hello world&foo=bar");
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(mem.indexOf(u8, encoded, "hello+world") != null);
    try std.testing.expect(mem.indexOf(u8, encoded, "%26") != null);
    try std.testing.expect(mem.indexOf(u8, encoded, "%3D") != null);
}

test "url encode preserves safe characters" {
    const encoded = try urlEncode(std.testing.allocator, "abc-def_ghi.jkl~mno");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("abc-def_ghi.jkl~mno", encoded);
}

test "url encode encodes special characters" {
    const encoded = try urlEncode(std.testing.allocator, "http://localhost:8234/callback");
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(mem.indexOf(u8, encoded, "%3A") != null);
    try std.testing.expect(mem.indexOf(u8, encoded, "%2F") != null);
}

test "state generation produces correct size" {
    const state = generateState();
    try std.testing.expectEqual(@as(usize, 16), state.len);
}

test "state hex format produces 32 hex characters" {
    const state = generateState();
    const hex = formatStateHex(state);
    try std.testing.expectEqual(@as(usize, 32), hex.len);
    for (hex) |c| {
        try std.testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "browser command per platform" {
    const url = "https://example.com/auth";
    const cmd = getBrowserCommand(url);

    switch (builtin.os.tag) {
        .windows => {
            try std.testing.expectEqualStrings("rundll32", cmd.prog);
            try std.testing.expectEqualStrings("url.dll,FileProtocolHandler", cmd.args[0]);
            try std.testing.expectEqualStrings(url, cmd.args[1]);
        },
        .macos => {
            try std.testing.expectEqualStrings("open", cmd.prog);
            try std.testing.expectEqualStrings(url, cmd.args[0]);
        },
        else => {
            try std.testing.expectEqualStrings("xdg-open", cmd.prog);
            try std.testing.expectEqualStrings(url, cmd.args[0]);
        },
    }
}

test "callback response success" {
    const response = buildCallbackResponse(true);
    try std.testing.expect(mem.indexOf(u8, response, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(mem.indexOf(u8, response, "Content-Type: text/html") != null);
    try std.testing.expect(mem.indexOf(u8, response, "Authorization successful!") != null);
    try std.testing.expect(mem.indexOf(u8, response, "You can close this tab.") != null);
}

test "callback response error" {
    const response = buildCallbackResponse(false);
    try std.testing.expect(mem.indexOf(u8, response, "HTTP/1.1 200 OK") != null);
    try std.testing.expect(mem.indexOf(u8, response, "Content-Type: text/html") != null);
    try std.testing.expect(mem.indexOf(u8, response, "Authorization failed.") != null);
    try std.testing.expect(mem.indexOf(u8, response, "Please try again.") != null);
}

test "AuthFlowState init and deinit" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "test-client",
        .redirect_port = 8234,
        .scope = "openid",
    };

    var flow = try startAuthFlow(std.testing.allocator, config);
    defer flow.deinit();

    // Verify the flow state is properly initialized
    try std.testing.expectEqual(@as(usize, 43), flow.pkce.code_verifier.len);
    try std.testing.expectEqual(@as(usize, 43), flow.pkce.code_challenge.len);
    try std.testing.expect(flow.authorization_url.len > 0);
    try std.testing.expect(mem.startsWith(u8, flow.authorization_url, "https://auth.example.com/authorize?"));
    try std.testing.expect(mem.indexOf(u8, flow.authorization_url, "client_id=test-client") != null);
    try std.testing.expect(mem.indexOf(u8, flow.authorization_url, "code_challenge_method=S256") != null);
    try std.testing.expect(mem.indexOf(u8, flow.authorization_url, "state=") != null);
}

test "isTokenExpired - expired token" {
    const token = StoredToken{
        .access_token = "expired-access-token",
        .refresh_token = "some-refresh-token",
        .expires_at = 1000, // Far in the past
        .scope = null,
        .provider = "test",
    };
    try std.testing.expect(isTokenExpired(token));
}

test "isTokenExpired - valid token far in the future" {
    const now = std.time.timestamp();
    const token = StoredToken{
        .access_token = "valid-access-token",
        .refresh_token = null,
        .expires_at = now + 3600, // 1 hour from now
        .scope = null,
        .provider = "test",
    };
    try std.testing.expect(!isTokenExpired(token));
}

test "isTokenExpired - token within 60s clock skew buffer is treated as expired" {
    const now = std.time.timestamp();
    const token = StoredToken{
        .access_token = "almost-expired-token",
        .refresh_token = null,
        .expires_at = now + 30, // 30 seconds from now, within 60s buffer
        .scope = null,
        .provider = "test",
    };
    // Should be expired because now >= (expires_at - 60) => now >= now - 30 => true
    try std.testing.expect(isTokenExpired(token));
}

test "isTokenExpired - token just outside 60s buffer is not expired" {
    const now = std.time.timestamp();
    const token = StoredToken{
        .access_token = "not-yet-expired-token",
        .refresh_token = null,
        .expires_at = now + 120, // 2 minutes from now, well outside 60s buffer
        .scope = null,
        .provider = "test",
    };
    try std.testing.expect(!isTokenExpired(token));
}

test "shouldAutoRefresh - expired token with refresh_token" {
    const token = StoredToken{
        .access_token = "expired",
        .refresh_token = "refresh-me",
        .expires_at = 1000, // Far in the past
        .scope = null,
        .provider = "test",
    };
    try std.testing.expect(shouldAutoRefresh(token));
}

test "shouldAutoRefresh - token without refresh_token" {
    const token = StoredToken{
        .access_token = "expired",
        .refresh_token = null,
        .expires_at = 1000, // Far in the past
        .scope = null,
        .provider = "test",
    };
    // No refresh token available, so cannot auto-refresh
    try std.testing.expect(!shouldAutoRefresh(token));
}

test "shouldAutoRefresh - token within 5 minutes of expiry with refresh_token" {
    const now = std.time.timestamp();
    const token = StoredToken{
        .access_token = "almost-expired",
        .refresh_token = "refresh-me",
        .expires_at = now + 120, // 2 minutes from now (within 5 min window)
        .scope = null,
        .provider = "test",
    };
    try std.testing.expect(shouldAutoRefresh(token));
}

test "shouldAutoRefresh - token far from expiry with refresh_token" {
    const now = std.time.timestamp();
    const token = StoredToken{
        .access_token = "fresh",
        .refresh_token = "refresh-me",
        .expires_at = now + 3600, // 1 hour from now
        .scope = null,
        .provider = "test",
    };
    try std.testing.expect(!shouldAutoRefresh(token));
}

test "buildRefreshTokenBody - basic refresh request" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .redirect_port = 8234,
    };

    const body = try buildRefreshTokenBody(std.testing.allocator, "my-refresh-token", config);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.indexOf(u8, body, "grant_type=refresh_token") != null);
    try std.testing.expect(mem.indexOf(u8, body, "refresh_token=my-refresh-token") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_id=my-client") != null);
    // No client_secret or scope by default
    try std.testing.expect(mem.indexOf(u8, body, "client_secret=") == null);
    try std.testing.expect(mem.indexOf(u8, body, "scope=") == null);
}

test "buildRefreshTokenBody - with client_secret and scope" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .client_secret = "my-secret",
        .redirect_port = 8234,
        .scope = "openid profile email",
    };

    const body = try buildRefreshTokenBody(std.testing.allocator, "rt_abc123", config);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.indexOf(u8, body, "grant_type=refresh_token") != null);
    try std.testing.expect(mem.indexOf(u8, body, "refresh_token=rt_abc123") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_id=my-client") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_secret=my-secret") != null);
    try std.testing.expect(mem.indexOf(u8, body, "scope=openid+profile+email") != null);
}

test "buildRefreshTokenBody - special characters in refresh token are encoded" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .redirect_port = 8234,
    };

    const body = try buildRefreshTokenBody(std.testing.allocator, "token/with=special&chars", config);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.indexOf(u8, body, "grant_type=refresh_token") != null);
    // The special characters should be percent-encoded
    try std.testing.expect(mem.indexOf(u8, body, "refresh_token=token%2Fwith%3Dspecial%26chars") != null);
}

test "buildRefreshTokenBody - grant_type comes first" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "test",
        .redirect_port = 8234,
    };

    const body = try buildRefreshTokenBody(std.testing.allocator, "rt", config);
    defer std.testing.allocator.free(body);

    // grant_type should be the first parameter
    try std.testing.expect(mem.startsWith(u8, body, "grant_type=refresh_token"));
}

test "buildClientCredentialsBody - basic request" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .client_secret = "my-secret",
        .redirect_port = 8234,
        .scope = "read write",
    };

    const body = try buildClientCredentialsBody(std.testing.allocator, config);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.startsWith(u8, body, "grant_type=client_credentials"));
    try std.testing.expect(mem.indexOf(u8, body, "client_id=my-client") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_secret=my-secret") != null);
    try std.testing.expect(mem.indexOf(u8, body, "scope=read+write") != null);
}

test "buildClientCredentialsBody - without optional fields" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .redirect_port = 8234,
    };

    const body = try buildClientCredentialsBody(std.testing.allocator, config);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.startsWith(u8, body, "grant_type=client_credentials"));
    try std.testing.expect(mem.indexOf(u8, body, "client_id=my-client") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_secret=") == null);
    try std.testing.expect(mem.indexOf(u8, body, "scope=") == null);
}

test "buildPasswordGrantBody - basic request" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .client_secret = "my-secret",
        .redirect_port = 8234,
        .scope = "openid",
    };

    const body = try buildPasswordGrantBody(std.testing.allocator, "user@example.com", "p@ssw0rd", config);
    defer std.testing.allocator.free(body);

    try std.testing.expect(mem.startsWith(u8, body, "grant_type=password"));
    try std.testing.expect(mem.indexOf(u8, body, "username=user%40example.com") != null);
    try std.testing.expect(mem.indexOf(u8, body, "password=p%40ssw0rd") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_id=my-client") != null);
    try std.testing.expect(mem.indexOf(u8, body, "client_secret=my-secret") != null);
    try std.testing.expect(mem.indexOf(u8, body, "scope=openid") != null);
}

test "buildImplicitAuthUrl - contains required params" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .redirect_port = 8234,
        .scope = "openid profile",
        .state = "csrf-token",
    };

    const url = try buildImplicitAuthUrl(std.testing.allocator, config);
    defer std.testing.allocator.free(url);

    try std.testing.expect(mem.startsWith(u8, url, "https://auth.example.com/authorize?"));
    try std.testing.expect(mem.indexOf(u8, url, "client_id=my-client") != null);
    try std.testing.expect(mem.indexOf(u8, url, "response_type=token") != null);
    try std.testing.expect(mem.indexOf(u8, url, "redirect_uri=") != null);
    try std.testing.expect(mem.indexOf(u8, url, "scope=openid+profile") != null);
    try std.testing.expect(mem.indexOf(u8, url, "state=csrf-token") != null);
}

test "buildImplicitAuthUrl - without optional fields" {
    const config = AuthFlowConfig{
        .auth_url = "https://auth.example.com/authorize",
        .token_url = "https://auth.example.com/token",
        .client_id = "my-client",
        .redirect_port = 8234,
    };

    const url = try buildImplicitAuthUrl(std.testing.allocator, config);
    defer std.testing.allocator.free(url);

    try std.testing.expect(mem.indexOf(u8, url, "response_type=token") != null);
    try std.testing.expect(mem.indexOf(u8, url, "scope=") == null);
    try std.testing.expect(mem.indexOf(u8, url, "state=") == null);
}
