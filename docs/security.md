---
layout: page
title: Security & Secrets
---

# Security & Secrets

A comprehensive guide to protecting your API credentials, signing requests, configuring TLS, and working with secrets safely in Volt.

---

## Table of Contents

- [Why API Security Matters](#why-api-security-matters)
- [Secret Masking](#secret-masking)
- [E2E Encrypted Secrets](#e2e-encrypted-secrets)
- [Team Secrets Vault](#team-secrets-vault)
- [Request Signing (HMAC-SHA256)](#request-signing-hmac-sha256)
- [TLS/SSL Configuration](#tlsssl-configuration)
- [Proxy Support](#proxy-support)
- [Named Sessions](#named-sessions)
- [Cookie Management](#cookie-management)
- [Safe Git Commits](#safe-git-commits)
- [Request Sharing](#request-sharing)
- [Security Best Practices Checklist](#security-best-practices-checklist)

---

## Why API Security Matters

Every time you make an API request, you are likely sending sensitive information: API keys, passwords, OAuth tokens, session cookies. If any of these credentials leak -- whether through a Git commit, a shared screenshot, or an unencrypted log file -- an attacker can impersonate you, access your data, or run up charges on your account.

Common ways credentials leak:

- **Committed to Git**: A `.volt` file containing a real API key gets pushed to a public repository
- **Visible in terminal output**: A Bearer token is printed in plain text during debugging
- **Shared unsafely**: You paste a request containing secrets into Slack or email
- **Transmitted over insecure channels**: Using HTTP instead of HTTPS, or skipping certificate verification

Volt is designed to prevent these mistakes with built-in protections: secret masking, encryption, TLS enforcement, and safe sharing tools. This guide walks through every security feature so you can use Volt confidently, even in team and CI/CD environments.

---

## Secret Masking

Volt automatically masks the values of secret variables in all terminal output. Any environment variable whose name begins with `$` is treated as a secret.

### How It Works

In your `_env.volt` environment file, prefix any variable name with `$` to mark it as sensitive:

```yaml
environment: production
variables:
  base_url: https://api.example.com
  $api_key: sk-live-a1b2c3d4e5f6g7h8i9j0
  $db_password: hunter2
```

When Volt encounters these values in output (response bodies, headers, logs), it replaces every occurrence with `***`:

```
$ volt run get-users.volt --env production

GET https://api.example.com/users
Authorization: Bearer ***

HTTP/1.1 200 OK
```

The actual value `sk-live-a1b2c3d4e5f6g7h8i9j0` is never printed to the terminal.

### Masking Rules

- Only variable names starting with `$` are treated as secrets
- The masking is applied to the full output text -- response headers, response body, and metadata
- Secret values shorter than 3 characters are not masked (to avoid false positives replacing single characters)
- Masking happens at the display layer; the underlying HTTP request still sends the real value

### Example: Separating Secrets from Configuration

```yaml
# _env.volt — Environment file with secrets
environment: staging
variables:
  base_url: https://staging.api.example.com
  api_version: v2
  $auth_token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
  $stripe_key: sk_test_EXAMPLE_KEY_REPLACE_ME
```

```yaml
# get-profile.volt — Request file (safe to commit)
name: Get User Profile
method: GET
url: {{base_url}}/{{api_version}}/profile
headers:
  - Authorization: Bearer {{$auth_token}}
```

The request file contains no secrets -- only variable references. The secrets live in `_env.volt`, which you add to `.gitignore`.

---

## E2E Encrypted Secrets

When you need to commit `.volt` files that contain sensitive values (such as auth tokens or passwords), Volt provides end-to-end encryption using a 32-byte key. Sensitive fields are encrypted in-place within the file, so the rest of the file remains readable.

### Generate an Encryption Key

```bash
volt secrets keygen
```

Output:

```
Generated encryption key:
a3f8b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1

Store this key securely. Use it with:
  volt secrets encrypt <file.volt> <key>
```

This generates a cryptographically random 32-byte key, displayed as 64 hexadecimal characters. **Store this key in a password manager or secure vault** -- never commit it to Git.

### Encrypt Secrets in a .volt File

```bash
volt secrets encrypt api-request.volt a3f8b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1
```

**Before encryption:**

```yaml
method: GET
url: https://api.example.com/me
auth:
  type: bearer
  token: sk-my-secret-key-12345
headers:
  - Accept: application/json
```

**After encryption:**

```yaml
method: GET
url: https://api.example.com/me
auth:
  type: bearer
  token: ${{encrypted:dGhpcyBpcyBub3QgcmVhbCBlbmNyeXB0aW9u}}
headers:
  - Accept: application/json
```

Only the sensitive fields (`token:`, `password:`, `key_value:`) are encrypted. Everything else -- method, URL, headers, tests -- stays in plain text, so the file is still human-readable and easy to review in a diff.

Already-encrypted values (those wrapped in `${{encrypted:...}}`) are never double-encrypted.

### Decrypt Secrets

```bash
volt secrets decrypt api-request.volt a3f8b2c1d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1
```

This reverses the encryption in-place, restoring the original plaintext values.

### Detect Unencrypted Secrets

Before committing, scan your `.volt` files for secrets that have not yet been encrypted:

```bash
volt secrets detect api-request.volt
```

Output when secrets are found:

```
  line 5: token: sk-my-secret-key-12345

Found 1 potential secret(s). Use 'volt secrets encrypt' to protect them.
```

Output when clean:

```
No secrets detected.
```

The detection engine uses heuristics to identify likely secrets:

- **Known prefixes**: `sk-`, `pk-`, `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `glpat-`, `xoxb-`, `xoxp-`, `AKIA`, `Bearer`
- **Sensitive field names**: Lines starting with `token:`, `password:`, `secret:`, `api_key:`, `apikey:`, `key:`, `access_token:`, `auth_token:`
- **Long mixed-character strings**: Strings longer than 20 characters containing a mix of uppercase, lowercase, and digits (a common pattern for API keys)

### Complete Encryption Workflow

Here is the full workflow for working with encrypted secrets in a team project:

```bash
# 1. Generate a key (one-time setup)
volt secrets keygen
# Save the key in your password manager or CI secret store

# 2. Write your .volt file normally
# edit payment-api.volt

# 3. Scan for secrets before committing
volt secrets detect payment-api.volt

# 4. Encrypt sensitive fields
volt secrets encrypt payment-api.volt <your-64-char-hex-key>

# 5. Verify secrets are encrypted
cat payment-api.volt
# token: ${{encrypted:...}}  <-- safe to commit

# 6. Commit safely
git add payment-api.volt
git commit -m "Add payment API request"

# 7. When you need to edit, decrypt first
volt secrets decrypt payment-api.volt <your-64-char-hex-key>
# Make your changes...
# Then re-encrypt before committing
volt secrets encrypt payment-api.volt <your-64-char-hex-key>
```

---

## Team Secrets Vault

For teams that need to share secrets securely, Volt provides an encrypted team vault with role-based access control. Each secret is encrypted with a random data encryption key (DEK), which is then individually wrapped for each authorized team member using their public key.

### How the Vault Works

1. Each team member generates a key pair (public + private)
2. The team lead adds members to the vault using their public keys
3. When a secret is added, Volt generates a random DEK, encrypts the secret, and wraps the DEK separately for each authorized member
4. Each member can only decrypt secrets using their own private key
5. When a member is removed, their wrapped DEK copies are stripped from all secrets

The vault is stored in `.volt-workspace/secrets/` as two files:
- `members.tab` -- Member IDs, public keys, and roles
- `vault.tab` -- Encrypted secrets and per-member wrapped keys

### Role-Based Access Control

| Role | Read Secrets | Write Secrets | Manage Members |
|------|:---:|:---:|:---:|
| **owner** | Yes | Yes | Yes |
| **editor** | Yes | Yes | No |
| **viewer** | No | No | No |

Viewers can see that secrets exist but cannot decrypt their values. This is useful for auditing or limited access scenarios.

### Managing the Team Vault

**List members:**

```bash
volt secrets team list
```

**Add a member:**

```bash
volt secrets team add alice <64-char-public-key-hex>
```

Each member generates their key pair locally and shares only the public key. The private key never leaves their machine.

**Remove a member:**

```bash
volt secrets team remove alice
```

When a member is removed, all secrets are re-wrapped to exclude their key. They lose access immediately.

### Sharing Secrets

```bash
volt secrets share API_KEY sk-live-a1b2c3d4e5f6g7h8
```

This encrypts the value and stores it in the vault, wrapped for all authorized members.

### Example: Setting Up a Team Vault

```bash
# Team lead generates key pair and initializes the vault
# (Key pair generation is done per-member, offline)

# Add team members with their public keys
volt secrets team add alice a1b2c3...  # 64 hex chars
volt secrets team add bob   d4e5f6...  # 64 hex chars

# Share secrets to the vault
volt secrets share STRIPE_KEY sk_live_abc123
volt secrets share DB_PASSWORD supersecretpass

# List members to verify
volt secrets team list

# If someone leaves the team
volt secrets team remove bob
```

---

## Request Signing (HMAC-SHA256)

Many APIs require request signing to verify that (a) the request was not tampered with in transit (integrity) and (b) the request comes from an authorized sender (authentication). Volt supports HMAC-SHA256 signing, AWS SigV4, and custom signing schemes.

### What Is HMAC Signing?

HMAC-SHA256 is a cryptographic algorithm that combines a secret key with a message to produce a unique signature. The API server, which has the same secret key, can recompute the signature and verify it matches. If anyone modifies the request in transit, the signature will not match.

The signature covers:
- The HTTP method
- The full URL
- All headers (sorted alphabetically)
- A SHA-256 hash of the request body

### Adding a Signing Section to .volt Files

Add a `signing:` section to any `.volt` file:

```yaml
name: Create Payment
method: POST
url: https://api.stripe.com/v1/charges
headers:
  - Content-Type: application/json
body: |
  {"amount": 2000, "currency": "usd"}

signing:
  method: hmac_sha256
  secret_key: whsec_your_webhook_signing_secret
  header_name: X-Signature
  include_timestamp: true
  timestamp_header: X-Timestamp
```

### Signing Configuration Fields

| Field | Default | Description |
|-------|---------|-------------|
| `method` | `hmac_sha256` | Signing algorithm: `hmac_sha256`, `aws_sigv4`, or `custom` |
| `secret_key` | *(required)* | The shared secret used for signing |
| `header_name` | `X-Signature` | Header name where the signature is placed |
| `include_timestamp` | `true` | Whether to add a timestamp header |
| `timestamp_header` | `X-Timestamp` | Header name for the timestamp |
| `access_key` | *(for AWS)* | AWS access key ID |
| `region` | *(for AWS)* | AWS region (e.g., `us-east-1`) |
| `service` | *(for AWS)* | AWS service name (e.g., `s3`) |

### Running with Request Signing

Use the `--sign` flag to activate signing:

```bash
volt run create-payment.volt --sign
```

Volt will:
1. Add an `X-Timestamp` header with the current time in ISO 8601 format (`20260222T143025Z`)
2. Build a canonical representation of the request (method, URL, sorted headers, body hash)
3. Compute the HMAC-SHA256 of the canonical string using your `secret_key`
4. Add the resulting hex-encoded signature as the `X-Signature` header

The final request sent over the wire will include both the `X-Timestamp` and `X-Signature` headers.

### AWS SigV4 Signing

For AWS APIs, use the `aws_sigv4` method:

```yaml
name: List S3 Objects
method: GET
url: https://s3.amazonaws.com/my-bucket?list-type=2

signing:
  method: aws_sigv4
  secret_key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
  access_key: AKIAIOSFODNN7EXAMPLE
  region: us-east-1
  service: s3
```

```bash
volt run list-s3.volt --sign
```

Volt computes a full AWS Signature Version 4 Authorization header, including the credential scope, signed headers, and signature.

---

## TLS/SSL Configuration

Volt verifies SSL/TLS certificates by default for all HTTPS requests. You can customize TLS behavior using command-line flags or the `.voltrc` project config.

### Default Behavior

By default, `verify_ssl` is `true`. Volt will reject connections to servers with invalid, expired, or self-signed certificates.

### Skip SSL Verification

```bash
volt run request.volt --verify=no
```

**When to use this:**
- Talking to a local development server with a self-signed certificate
- Debugging connection issues behind a corporate proxy
- Testing against a staging environment without proper certificates

**When NOT to use this:**
- Never in production
- Never in CI/CD pipelines that interact with real APIs
- Never when handling real user data

### Pin a TLS Version

Force a specific TLS version:

```bash
# Require TLS 1.2
volt run request.volt --ssl=tls1.2

# Require TLS 1.3
volt run request.volt --ssl=tls1.3
```

This is useful when:
- An API requires a minimum TLS version
- You want to verify your server supports TLS 1.3
- Security compliance requires a specific TLS version

### Custom CA Bundle

Point Volt at a custom Certificate Authority bundle:

```bash
volt run request.volt --ca-bundle /path/to/ca-certificates.crt
```

This is common in corporate environments where an internal CA signs certificates for internal services.

You can also pass a CA path via `--verify`:

```bash
volt run request.volt --verify=/path/to/ca-certificates.crt
```

### Client Certificates (Mutual TLS / mTLS)

Some APIs require the client to present a certificate, not just the server. This is called mutual TLS (mTLS):

```bash
volt run request.volt \
  --cert /path/to/client.crt \
  --cert-key /path/to/client.key
```

| Flag | Description |
|------|-------------|
| `--cert <path>` | Path to the client certificate file (PEM format) |
| `--cert-key <path>` | Path to the client certificate private key |
| `--ca-bundle <path>` | Path to CA bundle for verifying the server |

### Custom Cipher Suites

Restrict which cipher suites Volt will use:

```
# In .voltrc
ciphers: ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256
```

### Project-Level TLS Configuration

Set TLS defaults for an entire project in `.voltrc`:

```yaml
# .voltrc
verify_ssl: true
ssl_version: tls1.2
ca_bundle: /etc/ssl/certs/internal-ca.crt
client_cert: /path/to/client.crt
client_key: /path/to/client.key
ciphers: ECDHE-RSA-AES256-GCM-SHA384
```

These defaults apply to every `volt run` in the project, unless overridden by command-line flags.

---

## Proxy Support

Volt supports HTTP, HTTPS, and SOCKS5 proxies for routing traffic through intermediary servers.

### HTTP Proxy

```bash
volt run request.volt --proxy http://proxy.example.com:8080
```

### HTTPS Proxy

```bash
volt run request.volt --proxy https://secure-proxy.example.com:443
```

### SOCKS5 Proxy

SOCKS5 proxies support TCP-level proxying and optional username/password authentication:

```bash
# Without authentication
volt run request.volt --proxy socks5://proxy.example.com:1080

# With authentication
volt run request.volt --proxy socks5://user:pass@proxy.example.com:1080
```

Volt performs the full SOCKS5 handshake (method negotiation, optional username/password auth, connect request) before tunneling the HTTP traffic.

### Project-Level Proxy Configuration

Set a default proxy for all requests in `.voltrc`:

```yaml
# .voltrc
proxy: http://corporate-proxy.internal:3128
```

Command-line `--proxy` always overrides the `.voltrc` setting.

### When to Use Proxies

- **Corporate networks**: Route traffic through the company proxy
- **Debugging**: Use a tool like mitmproxy or Fiddler to inspect traffic
- **Anonymity**: Route traffic through a SOCKS5 proxy for privacy
- **Geo-testing**: Test APIs from different geographic locations
- **Capture mode**: Volt's built-in `volt proxy` captures traffic as `.volt` files for replay

---

## Named Sessions

Named sessions persist cookies, headers, and auth tokens across multiple requests, just like a browser session. This is essential for workflows that require authentication.

### Creating and Using a Session

```bash
# First request: log in and save the session
volt run login.volt --session=myapi

# Subsequent requests: reuse the session
volt run get-profile.volt --session=myapi
volt run update-profile.volt --session=myapi
```

On the first request, Volt creates a new session. On each subsequent request with the same `--session=myapi`, Volt:

1. **Loads** the session from disk
2. **Applies** saved headers, cookies, and auth to the outgoing request
3. **Executes** the request
4. **Updates** the session with any `Set-Cookie` headers from the response
5. **Saves** the session back to disk

### Session Storage

Sessions are stored as JSON files in the `.volt-sessions/` directory, organized by host:

```
.volt-sessions/
  api.example.com/
    myapi.json
    staging.json
  auth.example.com/
    myapi.json
```

Each session file contains:

```json
{
  "name": "myapi",
  "host": "api.example.com",
  "headers": {
    "X-Api-Key": "abc123"
  },
  "cookies": [
    {"name": "session_id", "value": "xyz789", "domain": "api.example.com"}
  ],
  "auth": {
    "type": "bearer",
    "token": "eyJhbGciOiJIUzI1NiJ9..."
  }
}
```

### Read-Only Sessions

Use a session without modifying it (the session will not be updated with new cookies):

```bash
volt run request.volt --session-read-only=myapi
```

This is useful for:
- Running tests that should not change session state
- Replaying a request against a known session snapshot
- Debugging without side effects

### How Session Data Is Applied

When a session is loaded, Volt merges its data into the request:

1. **Headers**: Session headers are added to the request unless the request already defines the same header name (request headers take precedence)
2. **Cookies**: All session cookies are combined into a single `Cookie` header (`name1=value1; name2=value2`)
3. **Auth**: If the session has a Bearer token and the request has no `Authorization` header, the session token is applied automatically

### Managing Sessions

```bash
# List all saved sessions
volt run --session=list  # or view .volt-sessions/ directory

# Delete a session
# Remove the JSON file from .volt-sessions/<host>/<name>.json
```

### Example: Login and Reuse Session

```yaml
# login.volt
name: Login
method: POST
url: https://api.example.com/auth/login
headers:
  - Content-Type: application/json
body: |
  {"email": "user@example.com", "password": "{{$password}}"}
```

```yaml
# get-dashboard.volt
name: Get Dashboard
method: GET
url: https://api.example.com/dashboard
headers:
  - Accept: application/json
```

```bash
# Log in -- the response Set-Cookie headers are saved
volt run login.volt --session=app --env production

# Access protected endpoint -- session cookies are sent automatically
volt run get-dashboard.volt --session=app
```

---

## Cookie Management

Volt automatically handles cookies during collection runs and session-based requests.

### Automatic Set-Cookie Parsing

When a response includes `Set-Cookie` headers, Volt parses them and stores the cookies with their full attributes:

```
Set-Cookie: session_id=abc123; Path=/; HttpOnly; Secure
Set-Cookie: theme=dark; Path=/; Max-Age=86400
```

Volt extracts:
- **Name and value**: `session_id=abc123`
- **Domain**: From the `Domain` attribute or the request's host
- **Path**: From the `Path` attribute (defaults to `/`)
- **Expiry**: From the `Max-Age` attribute (in seconds from now)
- **Flags**: `Secure` and `HttpOnly`

### Cookie Header Building

On the next request, Volt builds a `Cookie` header by selecting cookies that match:
- **Domain**: The cookie's domain must match the request URL's domain (or be a parent domain)
- **Path**: The request path must start with the cookie's path
- **Expiry**: Expired cookies are excluded

```
Cookie: session_id=abc123; theme=dark
```

### Domain Matching Rules

| Cookie Domain | Request URL | Match? |
|---------------|-------------|--------|
| `example.com` | `https://example.com/api` | Yes |
| `example.com` | `https://api.example.com/data` | Yes (subdomain) |
| `.example.com` | `https://api.example.com/data` | Yes (dot-prefix) |
| `other.com` | `https://example.com/api` | No |

### Cookie Jar in Collection Runs

During a collection run (`volt collection`), cookies persist across all requests in the collection. This allows multi-step workflows like:

1. POST `/login` -- receives `Set-Cookie: session_id=...`
2. GET `/dashboard` -- sends `Cookie: session_id=...`
3. POST `/logout` -- sends `Cookie: session_id=...`

The cookie jar is managed automatically; no configuration is needed.

---

## Safe Git Commits

Committing `.volt` files to Git is safe and encouraged -- but you need to ensure that secrets do not end up in the repository. Here is the recommended approach.

### Strategy 1: Use Environment Files (Recommended)

Keep secrets in `_env.volt` and add it to `.gitignore`:

```yaml
# _env.volt (DO NOT commit this file)
environment: production
variables:
  base_url: https://api.example.com
  $api_key: sk-live-real-key-here
  $db_password: real-password-here
```

```yaml
# get-users.volt (safe to commit)
method: GET
url: {{base_url}}/users
headers:
  - Authorization: Bearer {{$api_key}}
```

### Strategy 2: Encrypt Secrets In-Place

If you need the secrets inside the `.volt` file (for portability or completeness):

```bash
# Encrypt before committing
volt secrets encrypt api-request.volt <key>

# Commit the encrypted version
git add api-request.volt
git commit -m "Add API request with encrypted credentials"
```

### Recommended .gitignore Patterns

Add these lines to your `.gitignore`:

```gitignore
# Volt environment files (contain secrets)
_env.volt
*_env.volt
*.env.volt

# Volt session data (contains cookies and auth tokens)
.volt-sessions/

# Volt workspace (team vault, local state)
.volt-workspace/

# Encryption keys (if accidentally saved to a file)
*.key
*.pem

# OS files
.DS_Store
Thumbs.db
```

### Pre-Commit Check

Run `volt secrets detect` as part of your pre-commit hook:

```bash
#!/bin/bash
# .git/hooks/pre-commit

# Check all staged .volt files for unencrypted secrets
for file in $(git diff --cached --name-only --diff-filter=ACM | grep '\.volt$'); do
    result=$(volt secrets detect "$file" 2>&1)
    if echo "$result" | grep -q "potential secret"; then
        echo "ERROR: Unencrypted secrets found in $file"
        echo "$result"
        echo ""
        echo "Run: volt secrets encrypt $file <key>"
        exit 1
    fi
done
```

### What Is Safe to Commit

| File | Safe? | Why |
|------|:---:|-----|
| `request.volt` (no secrets) | Yes | Contains only method, URL, headers, test assertions |
| `request.volt` (encrypted secrets) | Yes | Secrets wrapped in `${{encrypted:...}}` |
| `_env.volt` | **No** | Contains plaintext secrets |
| `.voltrc` | Yes | Contains project config, no secrets by default |
| `.volt-sessions/` | **No** | Contains auth tokens and cookies |
| `.volt-workspace/secrets/` | Depends | Vault files are encrypted, but treat with care |

---

## Request Sharing

Volt can export any request as a shareable string in multiple formats, making it easy to share API requests with teammates without sharing your entire project.

### Share Formats

**Base64 (default):**

```bash
volt share request.volt
# Output:
# volt import base64 'bWV0aG9kOiBHRVQKdXJsOi...'
```

The entire `.volt` file is serialized and base64-encoded. The recipient can import it with a single command.

**cURL:**

```bash
volt share request.volt --format curl
# Output:
# curl 'https://api.example.com/users' \
#   -H 'Accept: application/json' \
#   -H 'Authorization: Bearer token123'
```

**URL:**

```bash
volt share request.volt --format url
# Output:
# volt://request?method=GET&url=https%3A%2F%2Fapi.example.com%2Fusers
```

### Importing Shared Requests

```bash
# Import from base64
volt import base64 'bWV0aG9kOiBHRVQKdXJsOi...'

# Import from a volt:// URL
volt import url 'volt://import?data=bWV0aG9kOiBHRVQKdXJsOi...'
```

### Security Considerations When Sharing

- **The curl format includes auth headers and tokens in plain text.** Only share via secure channels (encrypted Slack, private message, etc.).
- **The base64 format is encoded, not encrypted.** Base64 is trivially reversible. Do not treat it as a security measure.
- If you need to share a request that contains secrets, encrypt the `.volt` file first, then share:

```bash
# Encrypt secrets, then share
volt secrets encrypt request.volt <key>
volt share request.volt

# Recipient decrypts after importing
volt secrets decrypt request.volt <key>
```

---

## Security Best Practices Checklist

### Do

- **Use `$`-prefixed variables for all secrets** in `_env.volt` so they are automatically masked in output
- **Add `_env.volt` and `.volt-sessions/` to `.gitignore`** before your first commit
- **Run `volt secrets detect` before committing** any `.volt` file to scan for unencrypted secrets
- **Encrypt secrets with `volt secrets encrypt`** if you must commit files that contain credentials
- **Store encryption keys in a password manager** or CI/CD secret store (GitHub Secrets, Vault, etc.) -- never in the repository
- **Use named sessions (`--session=name`)** to avoid hardcoding auth tokens in request files
- **Enable SSL verification** (`verify_ssl: true`) in production and CI environments
- **Pin TLS 1.2 or 1.3** (`--ssl=tls1.2`) when interacting with production APIs
- **Use mTLS (`--cert`, `--cert-key`)** when the API requires client certificate authentication
- **Use the team vault** for shared secrets instead of sending keys over chat
- **Rotate encryption keys periodically** -- decrypt all files with the old key, re-encrypt with a new key
- **Use `--session-read-only`** in test scripts to avoid unintentionally modifying session state
- **Set a project-level proxy in `.voltrc`** if your organization requires one

### Do Not

- **Do not commit `_env.volt` files** -- they contain plaintext secrets
- **Do not commit `.volt-sessions/`** -- session files contain auth tokens and cookies
- **Do not use `--verify=no` in production** -- this disables SSL certificate verification and exposes you to man-in-the-middle attacks
- **Do not share cURL exports in public channels** -- they contain auth headers in plain text
- **Do not store encryption keys in `.volt` files, `.voltrc`, or any file in the repository**
- **Do not reuse the same encryption key across unrelated projects** -- if one is compromised, only that project is affected
- **Do not skip `volt secrets detect`** before committing -- it takes seconds and can prevent a credential leak
- **Do not treat base64-encoded shares as encrypted** -- base64 is encoding, not encryption; anyone can decode it
- **Do not leave `--proxy` flags pointing at debug proxies in committed scripts** -- route production traffic directly
- **Do not hardcode tokens in `.volt` files** when you can use variable references (`{{$api_key}}`) instead
