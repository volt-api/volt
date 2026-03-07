---
layout: page
title: Environments & Configuration
---

# Environments & Configuration

This guide covers everything you need to know about configuring Volt for your projects -- from environment variables and project settings to themes, shell completions, and directory organization. Whether you are working alone or across a team with development, staging, and production servers, Volt gives you the tools to manage it all from plain-text files.

---

## Table of Contents

1. [What Are Environments?](#what-are-environments)
2. [The _env.volt File](#the-_envvolt-file)
3. [Using Variables in Requests](#using-variables-in-requests)
4. [Switching Environments](#switching-environments)
5. [Variable Resolution Order](#variable-resolution-order)
6. [The .voltrc File](#the-voltrc-file)
7. [Environment CLI Commands](#environment-cli-commands)
8. [Collection-Level Configuration](#collection-level-configuration)
9. [Dynamic Variables](#dynamic-variables)
10. [Secret Variables](#secret-variables)
11. [Themes](#themes)
12. [Shell Completions](#shell-completions)
13. [Cache Management](#cache-management)
14. [Directory Structure Best Practices](#directory-structure-best-practices)

---

## What Are Environments?

When you build an API, you typically run it on several different servers throughout its lifecycle:

- **Development** -- your local machine or a shared dev server, used for day-to-day coding.
- **Staging** -- a server that mirrors production, used for final testing before a release.
- **Production** -- the live server that real users interact with.

The API endpoints are the same (e.g., `/api/users`, `/api/orders`), but the **base URL**, **API keys**, **database credentials**, and other settings change depending on which server you are talking to.

Environments in Volt let you define these varying values in a single file and switch between them with a command-line flag. You write your `.volt` request files once, using placeholder variables like `{{base_url}}`, and Volt fills in the correct value for whichever environment you choose.

**Why does this matter?**

- You never have to edit request files when switching between dev and production.
- Sensitive credentials (API keys, tokens) are kept in one place, separate from your request definitions.
- Your entire team can share the same request files and simply select their own environment.

---

## The _env.volt File

The `_env.volt` file is where you define your environments and their variables. Place it in the root of your project directory or alongside your `.volt` request files.

### Format

The file uses a simple YAML-like format with two key directives:

- `environment:` -- declares the name of the environment.
- `variables:` -- begins the list of key-value pairs for that environment.

Under `variables:`, each variable is defined as `key: value`, indented with spaces.

### A Minimal Example

```yaml
# _env.volt — Development environment

environment: development
variables:
  base_url: http://localhost:3000
  api_version: v1
```

This defines a single environment called `development` with two variables: `base_url` and `api_version`.

### Multiple Environments in Separate Files

For larger projects, you can create multiple `_env.volt` files with descriptive names:

**dev_env.volt**
```yaml
environment: development
variables:
  base_url: http://localhost:3000
  api_version: v1
  $api_key: dev-key-12345
  $db_password: localpass
```

**staging_env.volt**
```yaml
environment: staging
variables:
  base_url: https://staging-api.example.com
  api_version: v1
  $api_key: staging-key-67890
  $db_password: staging-secret
```

**production_env.volt**
```yaml
environment: production
variables:
  base_url: https://api.example.com
  api_version: v2
  $api_key: prod-key-ABCDEF
  $db_password: super-secret-prod-password
```

Notice that variables prefixed with `$` (like `$api_key` and `$db_password`) are treated as **secrets** -- their values are masked in terminal output. More on this in the [Secret Variables](#secret-variables) section.

### Comments

Lines starting with `#` are treated as comments and ignored:

```yaml
# This is the staging configuration
# Last updated: 2025-01-15

environment: staging
variables:
  # The staging API server
  base_url: https://staging-api.example.com
  api_version: v1
```

---

## Using Variables in Requests

Once your variables are defined in `_env.volt`, you reference them inside your `.volt` request files using **double curly braces**: `{{variable_name}}`.

Variables can be used in virtually every part of a request:

### In the URL

```yaml
name: List Users
method: GET
url: {{base_url}}/api/{{api_version}}/users
```

When run with the `development` environment, this resolves to:
```
GET http://localhost:3000/api/v1/users
```

When run with `production`:
```
GET https://api.example.com/api/v2/users
```

### In Headers

```yaml
name: Authenticated Request
method: GET
url: {{base_url}}/api/me
headers:
  - Authorization: Bearer {{$api_key}}
  - X-Request-ID: {{$uuid}}
  - Accept: application/json
```

### In the Request Body

```yaml
name: Create User
method: POST
url: {{base_url}}/api/{{api_version}}/users
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "email": "{{user_email}}",
      "role": "{{default_role}}"
    }
```

### In Authentication

```yaml
name: Access Protected Resource
method: GET
url: {{base_url}}/api/protected
auth:
  type: bearer
  token: {{$api_key}}
```

```yaml
name: Basic Auth Request
method: GET
url: {{base_url}}/api/admin
auth:
  type: basic
  username: {{admin_user}}
  password: {{$admin_password}}
```

### In Request-Level Variables

You can also define variables directly inside a `.volt` file. These are useful for values specific to a single request:

```yaml
name: Get User by ID
method: GET
url: {{base_url}}/api/users/{{user_id}}
variables:
  user_id: 42
```

Request-level variables take the **highest priority** -- they override environment variables and all other scopes.

---

## Switching Environments

### Using the --env Flag

To select an environment when running a request, use the `--env` flag:

```bash
# Run against the development environment
volt run get-users.volt --env development

# Run against staging
volt run get-users.volt --env staging

# Run against production
volt run get-users.volt --env production
```

The `--env` flag works with all commands that execute requests:

```bash
# Run an entire collection against staging
volt collection api/ --env staging

# Run a workflow against production
volt workflow deploy-flow.workflow --env production

# Run tests against staging
volt test api/ --env staging
```

### Setting a Default Environment

You can set a default environment in your `.voltrc` file so you do not need to pass `--env` every time:

```yaml
environment: development
```

Now, running `volt run get-users.volt` automatically uses the `development` environment. You can still override it with `--env`:

```bash
# Uses "development" from .voltrc
volt run get-users.volt

# Overrides to "staging"
volt run get-users.volt --env staging
```

---

## Variable Resolution Order

When Volt encounters a `{{variable_name}}` placeholder, it searches for the value across multiple scopes. If the same variable is defined in more than one place, the **higher-priority scope wins**.

Here is the resolution order, from **highest** to **lowest** priority:

| Priority | Scope | Source | Description |
|----------|-------|--------|-------------|
| 1 (highest) | **Request** | `variables:` section in the `.volt` file | Variables defined inside the request itself |
| 2 | **Runtime** | `extract` / `set` in `post_script:` | Variables set during execution via scripting |
| 3 | **Collection** | `_collection.volt` | Variables inherited by all requests in a directory |
| 4 | **Environment** | `_env.volt` (active environment) | Variables from the selected environment |
| 5 | **Global** | `.voltrc` | Project-wide defaults |
| 6 (lowest) | **Dynamic** | Built-in generators | Auto-generated values like `$uuid`, `$timestamp` |

### How This Works in Practice

Suppose you have:

**_env.volt**
```yaml
environment: development
variables:
  base_url: http://localhost:3000
  timeout: 5000
```

**_collection.volt**
```yaml
variables:
  timeout: 10000
  api_version: v1
```

**get-users.volt**
```yaml
method: GET
url: {{base_url}}/api/{{api_version}}/users
variables:
  api_version: v2
```

When Volt resolves the variables for `get-users.volt`:

- `base_url` -- found in the environment (`http://localhost:3000`)
- `api_version` -- found in the request's own `variables:` section (`v2`), which overrides the collection-level value (`v1`)
- `timeout` -- found in the collection (`10000`), which overrides the environment-level value (`5000`)

### Runtime Variables via Scripting

Variables set by `post_script:` blocks persist across requests in a collection run. This is how you pass data between requests (e.g., extracting a token from a login response and using it in subsequent requests):

**01-login.volt**
```yaml
name: Login
method: POST
url: {{base_url}}/api/login
body:
  type: json
  content: |
    {
      "username": "admin",
      "password": "{{$admin_password}}"
    }
post_script: |
  extract auth_token $.token
```

**02-get-profile.volt**
```yaml
name: Get Profile
method: GET
url: {{base_url}}/api/me
headers:
  - Authorization: Bearer {{auth_token}}
```

After the login request completes, the `extract` command in its `post_script` pulls the `token` field from the JSON response and stores it as the runtime variable `auth_token`. The next request in the collection then uses `{{auth_token}}` in its header -- Volt resolves it from the runtime scope.

---

## The .voltrc File

The `.voltrc` file is your **project-level configuration file**. Place it in the root of your project directory. It controls default behavior for all Volt commands run within that project.

### Format

Like `_env.volt`, the `.voltrc` file uses a simple `key: value` format with support for comments (`#`) and list items (headers).

### Complete Reference

Here is a `.voltrc` file with every supported option explained:

```yaml
# =============================================================================
# Volt Project Configuration (.voltrc)
# Place this file in your project root.
# =============================================================================

# ── Base URL ─────────────────────────────────────────────────────────────
# Prepended to any relative URL in your .volt files.
# If a .volt file uses url: /api/users, the actual request goes to:
#   https://api.example.com/api/users
base_url: https://api.example.com

# ── Default Environment ──────────────────────────────────────────────────
# Which environment to activate when --env is not specified on the CLI.
# Must match an environment name defined in your _env.volt file.
environment: development

# ── Request Timeout ──────────────────────────────────────────────────────
# How long to wait for a response, in milliseconds.
# Default: 30000 (30 seconds). Set to 0 for no timeout.
timeout: 30000

# ── Default Headers ──────────────────────────────────────────────────────
# These headers are automatically added to every request.
# Individual .volt files can override them by setting the same header name.
headers:
  - Accept: application/json
  - User-Agent: Volt/1.1.0

# ── Output Format ────────────────────────────────────────────────────────
# Controls how response bodies are displayed in the terminal.
#   pretty  — syntax-highlighted, indented JSON (default)
#   compact — minified JSON on a single line
#   raw     — unprocessed response body as-is
output: pretty

# ── Colored Output ───────────────────────────────────────────────────────
# Enable or disable ANSI color codes in terminal output.
# Set to false if you are piping output to a file or another program.
color: true

# ── Redirect Behavior ───────────────────────────────────────────────────
# Whether Volt should automatically follow HTTP redirects (3xx responses).
follow_redirects: true

# Maximum number of redirects to follow before giving up.
# Prevents infinite redirect loops.
max_redirects: 10

# ── SSL / TLS Settings ──────────────────────────────────────────────────
# Whether to verify the server's TLS certificate.
# Set to false for self-signed certificates during development.
# WARNING: Never disable this in production.
verify_ssl: true

# Path to a client certificate file (PEM format) for mutual TLS (mTLS).
# Used when the server requires client certificate authentication.
# client_cert: /path/to/client.pem

# Path to the private key file for the client certificate.
# client_key: /path/to/client-key.pem

# Path to a custom CA bundle file for verifying the server's certificate.
# Useful when your server uses an internal/private certificate authority.
# ca_bundle: /path/to/ca-bundle.crt

# Minimum TLS version to use for HTTPS connections.
# Options: tls1.0, tls1.1, tls1.2, tls1.3
# ssl_version: tls1.2

# ── Proxy ────────────────────────────────────────────────────────────────
# Route all HTTP(S) requests through a proxy server.
# Useful for debugging with tools like Charles, Fiddler, or mitmproxy.
# proxy: http://localhost:8080

# ── Verbose Mode ─────────────────────────────────────────────────────────
# When true, print full request and response headers for every request.
# verbose: true

# ── Theme ────────────────────────────────────────────────────────────────
# Color theme for terminal output. See the Themes section for all options.
# theme: nord

# ── Session ──────────────────────────────────────────────────────────────
# Default named session. Sessions persist cookies and headers across runs.
# session: my-api
```

### Option Details

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `base_url` | string | *(none)* | Prepended to relative URLs in `.volt` files |
| `environment` | string | *(none)* | Default environment name to activate |
| `timeout` | integer | `30000` | Request timeout in milliseconds |
| `headers` | list | *(none)* | Default headers applied to all requests |
| `output` | string | `pretty` | Output format: `pretty`, `compact`, or `raw` |
| `color` | boolean | `true` | Enable ANSI colored terminal output |
| `follow_redirects` | boolean | `true` | Automatically follow HTTP 3xx redirects |
| `max_redirects` | integer | `10` | Maximum redirect hops before stopping |
| `verify_ssl` | boolean | `true` | Verify server TLS certificates |
| `client_cert` | string | *(none)* | Path to client certificate (PEM) for mTLS |
| `client_key` | string | *(none)* | Path to client certificate private key |
| `ca_bundle` | string | *(none)* | Path to custom CA bundle |
| `ssl_version` | string | *(none)* | Minimum TLS version (`tls1.0` through `tls1.3`) |
| `proxy` | string | *(none)* | HTTP proxy URL for all requests |
| `verbose` | boolean | `false` | Show full request/response headers |
| `theme` | string | `dark` | Color theme for syntax highlighting |
| `session` | string | *(none)* | Default named session for cookie persistence |

---

## Environment CLI Commands

Volt provides the `volt env` command for managing environments from the terminal.

### List Environments

```bash
volt env list
```

Scans the current directory for `_env.volt` files and lists all discovered environments.

**Example output:**
```
Environments:
  dev_env.volt
  staging_env.volt
  production_env.volt
```

### Set a Variable

```bash
volt env set <key> <value>
```

Sets a variable in the active environment.

```bash
volt env set base_url https://api.staging.example.com
volt env set api_version v2
volt env set '$api_key' my-secret-key-123
```

**Example output:**
```
Set base_url = https://api.staging.example.com
```

### Get a Variable

```bash
volt env get <key>
```

Retrieves the current value of a variable.

```bash
volt env get base_url
```

**Example output:**
```
Variable: base_url
```

### Delete a Variable

```bash
volt env delete <key>
```

Removes a variable from the active environment.

```bash
volt env delete old_api_key
```

### Create a New Environment

```bash
volt env create <name>
```

Creates a new named environment.

```bash
volt env create staging
```

This is useful when setting up a project for the first time or adding a new deployment target.

---

## Collection-Level Configuration

When you organize your `.volt` files into directories (collections), you can place a special `_collection.volt` file in the directory to define settings that are **inherited by every request** in that collection.

### What _collection.volt Provides

- **Shared authentication** -- every request in the directory inherits the auth configuration unless it defines its own.
- **Shared headers** -- common headers applied to all requests.
- **Shared variables** -- variables available to all requests in the directory.
- **Base URL** -- a common base URL for all requests in the collection.

### Complete Example

```yaml
# _collection.volt — Shared configuration for this collection
# All requests in this directory inherit these settings.

name: User API Collection
description: Endpoints for the user management service

# Shared authentication — applied to all requests unless overridden
auth:
  type: bearer
  token: {{$api_key}}

# Shared headers
headers:
  - Content-Type: application/json
  - X-API-Version: {{api_version}}
  - X-Client: volt-cli

# Shared variables
variables:
  default_page_size: 25
  default_sort: created_at
```

### How Inheritance Works

When Volt runs a request from a collection directory:

1. It checks for a `_collection.volt` file in the same directory.
2. If the request does **not** define its own `auth:` section, it inherits the authentication from `_collection.volt`.
3. Collection-level variables are available to all requests at the **collection** scope (priority 3 in the resolution order).

**Example directory:**
```
api/users/
  _collection.volt        # Shared auth + headers
  01-list-users.volt       # Inherits auth from _collection.volt
  02-create-user.volt      # Inherits auth from _collection.volt
  03-admin-override.volt   # Defines its own auth: section (overrides)
```

**01-list-users.volt** (inherits collection auth):
```yaml
name: List Users
method: GET
url: {{base_url}}/api/users?page_size={{default_page_size}}
```

**03-admin-override.volt** (overrides collection auth):
```yaml
name: Admin Delete User
method: DELETE
url: {{base_url}}/api/users/{{user_id}}
auth:
  type: basic
  username: admin
  password: {{$admin_password}}
```

In this example, `01-list-users.volt` and `02-create-user.volt` automatically get the bearer token authentication from `_collection.volt`. The `03-admin-override.volt` file defines its own `auth:` section, so the collection-level auth is skipped for that request.

---

## Dynamic Variables

Dynamic variables are **built-in variables** that generate a fresh value every time they are used. They are prefixed with `$` and enclosed in double curly braces: `{{$variable_name}}`.

Unlike environment variables, you do not define these anywhere -- Volt generates them automatically at runtime.

### Available Dynamic Variables

| Variable | Description | Example Output |
|----------|-------------|----------------|
| `{{$uuid}}` | Random UUID v4 | `a3b8f042-1e16-4f0e-8c74-59b2a4738d1c` |
| `{{$guid}}` | Alias for `$uuid` | `f47ac10b-58cc-4372-a567-0e02b2c3d479` |
| `{{$timestamp}}` | Current Unix timestamp (seconds) | `1708617600` |
| `{{$isoTimestamp}}` | Current time in ISO 8601 format | `2025-02-22T14:30:00Z` |
| `{{$isoDate}}` | Alias for `$isoTimestamp` | `2025-02-22T14:30:00Z` |
| `{{$date}}` | Current date (YYYY-MM-DD) | `2025-02-22` |
| `{{$randomInt}}` | Random integer between 0 and 9999 | `4271` |
| `{{$randomFloat}}` | Random float between 0.00 and 1.00 | `0.73` |
| `{{$randomEmail}}` | Random email address | `user5823@example.com` |
| `{{$randomString}}` | Random 8-character lowercase string | `kxmqvbzf` |
| `{{$randomBool}}` | Random boolean (`true` or `false`) | `true` |

### Usage Examples

**Creating a resource with a unique ID:**
```yaml
name: Create Order
method: POST
url: {{base_url}}/api/orders
headers:
  - Content-Type: application/json
  - X-Request-ID: {{$uuid}}
  - X-Timestamp: {{$isoTimestamp}}
body:
  type: json
  content: |
    {
      "order_id": "{{$guid}}",
      "item_count": {{$randomInt}},
      "test_email": "{{$randomEmail}}",
      "created_at": "{{$isoTimestamp}}"
    }
```

**Using dynamic variables in tests:**
```yaml
name: Generate Test Data
method: POST
url: {{base_url}}/api/test-data
body:
  type: json
  content: |
    {
      "name": "{{$randomString}}",
      "email": "{{$randomEmail}}",
      "active": {{$randomBool}},
      "score": {{$randomFloat}},
      "registered": "{{$date}}"
    }
```

Every time you run this request, all the dynamic variables produce new values. This is especially useful for:

- **Idempotency testing** -- generating unique IDs to avoid conflicts.
- **Load testing** -- creating varied test data across runs.
- **Correlation IDs** -- attaching unique request IDs for tracing.

---

## Secret Variables

Any variable whose name starts with `$` is treated as a **secret** by Volt. When Volt displays output in the terminal, secret values are automatically replaced with `***` to prevent accidental exposure.

### How It Works

**In your _env.volt:**
```yaml
environment: production
variables:
  base_url: https://api.example.com
  $api_key: sk-prod-ABCDEFghijklmnop123456
  $db_password: super-secret-password
```

**In your request:**
```yaml
name: Authenticated Request
method: GET
url: {{base_url}}/api/data
headers:
  - Authorization: Bearer {{$api_key}}
```

**What you see in the terminal:**
```
POST https://api.example.com/api/data
Authorization: Bearer ****************************

200 OK (142ms)
```

The actual value `sk-prod-ABCDEFghijklmnop123456` is sent in the HTTP request, but Volt masks it in all terminal output so it does not appear in logs, screen recordings, or over-the-shoulder views.

### Best Practices for Secrets

1. **Always prefix sensitive values with `$`**: API keys, tokens, passwords, and any credentials.
2. **Add `_env.volt` to your `.gitignore`**: Never commit environment files containing secrets to version control.
3. **Use separate env files per environment**: Keep production secrets in a file that only authorized team members have access to.

**Recommended .gitignore entries:**
```
# Volt environment files (may contain secrets)
*_env.volt
_env.volt

# Volt response cache
.volt-cache/
```

---

## Themes

Volt supports color themes to customize how output appears in your terminal. Themes control syntax highlighting for JSON, status colors, headers, and general formatting.

### Available Themes

| Theme | Description |
|-------|-------------|
| `dark` | Default theme -- cyan/green on dark backgrounds |
| `light` | Inverted colors for light terminal backgrounds |
| `solarized` | Based on the Solarized color palette |
| `nord` | Arctic blue/cyan inspired by Nord |
| `dracula` | Purple-heavy Dracula palette |
| `monokai` | Orange/green Monokai palette |
| `rose_pine` | Muted purples/pinks with rose gold accents |
| `catppuccin` | Pastel colors (Catppuccin Mocha) |
| `github_dark` | GitHub's dark default palette |
| `github_light` | GitHub's light default palette |
| `one_dark` | Atom editor's One Dark Pro |
| `gruvbox` | Retro earthy tones |
| `tokyo_night` | Blue-purple neon palette |
| `kanagawa` | Japanese-inspired wave palette |
| `everforest` | Green-based nature palette |
| `ayu` | Warm orange accents |
| `synthwave` | Neon pink/cyan/purple (Synthwave '84) |
| `palenight` | Muted pastels (Material Palenight) |
| `none` | No colors -- plain text output for piping |

### Theme Commands

**List all available themes with color previews:**
```bash
volt theme list
```

**Set the active theme:**
```bash
volt theme set nord
```

**Preview a theme's colors without setting it:**
```bash
volt theme preview dracula
```

### Setting a Theme Permanently

Add the `theme` key to your `.voltrc` file:

```yaml
theme: nord
```

This applies the theme every time you run Volt in that project.

### Disabling Colors

If you are piping Volt output to a file or another tool, you can disable all colors:

```yaml
# In .voltrc
color: false
```

Or use the `none` theme:

```yaml
theme: none
```

---

## Shell Completions

Volt can generate tab-completion scripts for your shell, giving you auto-complete for all commands, subcommands, file arguments, and export formats.

### Generating Completions

```bash
volt completions bash
volt completions zsh
volt completions fish
volt completions powershell
```

### Installation by Shell

#### Bash

Add to your `~/.bashrc`:

```bash
eval "$(volt completions bash)"
```

Or save to a file and source it:

```bash
volt completions bash > ~/.local/share/bash-completion/completions/volt
```

#### Zsh

Add to your `~/.zshrc`:

```bash
eval "$(volt completions zsh)"
```

Or save to your completions directory:

```bash
volt completions zsh > ~/.zfunc/_volt
# Make sure ~/.zfunc is in your fpath:
# fpath=(~/.zfunc $fpath)
```

#### Fish

Save to your Fish completions directory:

```bash
volt completions fish > ~/.config/fish/completions/volt.fish
```

#### PowerShell

Add to your `$PROFILE`:

```powershell
volt completions powershell | Invoke-Expression
```

Or save to a file and dot-source it:

```powershell
volt completions powershell > "$HOME\.volt-completions.ps1"
# Then add to $PROFILE:
# . "$HOME\.volt-completions.ps1"
```

### What Gets Completed

After installing completions, pressing Tab will auto-complete:

- **Top-level commands**: `volt run`, `volt test`, `volt bench`, `volt export`, etc.
- **Subcommand arguments**: `volt export curl`, `volt export python`, `volt completions zsh`, etc.
- **File arguments**: `.volt` files for commands that accept them (`run`, `test`, `bench`, `lint`, `validate`, `diff`, `docs`).
- **Export formats**: `curl`, `python`, `javascript`, `go`, `openapi`, `ruby`, `php`, `csharp`, `rust`, `java`, `swift`, `kotlin`, `dart`, `har`.

---

## Cache Management

Volt includes a response cache that can store HTTP responses to avoid redundant requests during development. The cache is session-based by default and can be managed with the `volt cache` command.

### Cache Commands

**View cache statistics:**
```bash
volt cache stats
```

Shows the number of cached entries, hit/miss ratio, and memory usage.

**Clear the cache:**
```bash
volt cache clear
```

Removes all cached responses.

### How Caching Works

- Each cache entry is keyed by the request method and URL (e.g., `GET:https://api.example.com/users`).
- Entries have a configurable TTL (time-to-live). Once expired, the next request fetches a fresh response.
- Cache hits increment a counter, so you can see how effective caching has been via `volt cache stats`.
- The cache is in-memory and session-only by default. Start Volt with `--cache` to enable persistent caching.

### When to Use Caching

- **During development**: Avoid hitting rate-limited APIs repeatedly while iterating on request definitions.
- **In CI pipelines**: Cache responses from slow external services to speed up test runs.
- **When offline**: Replay cached responses when you do not have network access.

---

## Directory Structure Best Practices

A well-organized Volt project makes it easy to find requests, manage environments, and collaborate with your team. Here is a recommended structure:

### Small Project

```
my-api/
  .voltrc                   # Project configuration
  _env.volt                 # Environment variables (dev by default)

  get-users.volt            # Individual request files
  create-user.volt
  get-user-by-id.volt
  update-user.volt
  delete-user.volt
```

### Medium Project

```
my-api/
  .voltrc                   # Project configuration
  _env.volt                 # Development environment
  staging_env.volt          # Staging environment
  production_env.volt       # Production environment
  .gitignore                # Ignore _env.volt files with secrets

  auth/
    _collection.volt        # Shared auth config for this folder
    01-login.volt
    02-refresh-token.volt
    03-logout.volt

  users/
    _collection.volt        # Shared headers + auth
    01-list-users.volt
    02-create-user.volt
    03-get-user.volt
    04-update-user.volt
    05-delete-user.volt

  orders/
    _collection.volt
    01-list-orders.volt
    02-create-order.volt
    03-get-order.volt
```

### Large Project / Monorepo

```
my-api/
  .voltrc                   # Project-wide settings
  .gitignore

  environments/
    dev_env.volt
    staging_env.volt
    production_env.volt
    ci_env.volt             # Environment for CI/CD pipelines

  collections/
    auth/
      _collection.volt
      01-login.volt
      02-signup.volt
      03-forgot-password.volt
      04-reset-password.volt
      05-refresh-token.volt

    users/
      _collection.volt
      01-list.volt
      02-create.volt
      03-read.volt
      04-update.volt
      05-delete.volt
      06-bulk-import.volt

    billing/
      _collection.volt
      01-list-invoices.volt
      02-create-subscription.volt
      03-cancel-subscription.volt

    admin/
      _collection.volt
      01-system-health.volt
      02-audit-log.volt

  workflows/
    onboarding.workflow     # Multi-step workflow: signup -> verify -> profile
    deploy-check.workflow   # Pre-deploy API smoke tests

  tests/
    smoke-tests.volt        # Quick health checks
    regression/
      user-crud.volt
      auth-flow.volt
```

### Naming Conventions

- **Use numeric prefixes** for ordered execution: `01-login.volt`, `02-get-profile.volt`. When Volt runs a collection, files are executed in alphabetical order, so numeric prefixes guarantee the right sequence.
- **Use descriptive names**: `create-user.volt` is better than `post.volt`.
- **Prefix config files with underscore**: `_collection.volt`, `_env.volt`. Volt skips files starting with `_` during linting and collection runs (they are config, not requests).
- **Group related requests into directories**: Each directory is a collection that can be run together with `volt collection <dir>`.

### .gitignore Recommendations

```gitignore
# Volt environment files (may contain secrets)
*_env.volt
_env.volt

# Volt cache
.volt-cache/

# Volt history
.volt-history/

# Compiled test executables (if any)
*.exe
*.obj
*.pdb
```

---

## Putting It All Together

Here is a complete example that ties together environments, collections, variables, and project configuration:

**1. Project configuration (.voltrc):**
```yaml
base_url: http://localhost:3000
timeout: 15000
environment: development
headers:
  - Accept: application/json
  - User-Agent: Volt/1.1.0
output: pretty
color: true
theme: nord
follow_redirects: true
max_redirects: 10
verify_ssl: true
```

**2. Environment file (_env.volt):**
```yaml
environment: development
variables:
  base_url: http://localhost:3000
  api_version: v1
  $api_key: dev-key-12345
  $admin_password: admin123
```

**3. Collection config (api/users/_collection.volt):**
```yaml
auth:
  type: bearer
  token: {{$api_key}}
headers:
  - Content-Type: application/json
  - X-API-Version: {{api_version}}
variables:
  default_page_size: 25
```

**4. Request file (api/users/01-list-users.volt):**
```yaml
name: List Users
description: Get paginated list of all users
method: GET
url: {{base_url}}/api/{{api_version}}/users?limit={{default_page_size}}
tests:
  - status equals 200
  - $.data exists
```

**5. Run it:**
```bash
# Run against development (default)
volt run api/users/01-list-users.volt

# Run against staging
volt run api/users/01-list-users.volt --env staging

# Run the entire users collection
volt collection api/users/ --env staging

# Run tests
volt test api/users/ --env development
```

This setup gives you a clean separation between requests, configuration, and credentials -- making it easy to switch between environments, share request files with your team, and keep secrets out of version control.
