---
layout: page
title: Command Reference
---

# Command Reference

Welcome to the complete Volt command reference! This page documents **every single command, subcommand, and flag** that Volt offers. Whether you're a beginner just getting started or a power user looking for a specific flag, you'll find it here.

**Tip:** You can always run `volt help` or `volt --help` to see a quick summary of commands right in your terminal. For help on a specific command, most commands support `--help` too.

---

## How to Read This Guide

Commands are shown like this:

```bash
volt run <file|dir>         # Required argument
volt bench <file> [-n N]    # Optional argument in brackets
volt quick [METHOD] <url>   # Optional METHOD, required url
```

- `<angle brackets>` = required argument
- `[square brackets]` = optional argument
- `|` = "or" (choose one)
- Flags starting with `--` have long forms; `-` flags are short forms

---

## Table of Contents

- [Core Request Commands](#core-request-commands)
- [Testing Commands](#testing-commands)
- [Collection and Organization](#collection-and-organization)
- [Import and Export](#import-and-export)
- [Protocol Commands](#protocol-commands)
- [Security and Authentication](#security-and-authentication)
- [Development Tools](#development-tools)
- [Configuration and Setup](#configuration-and-setup)
- [Web and UI](#web-and-ui)
- [Information](#information)
- [Complete Flag Reference](#complete-flag-reference)
- [Exit Codes](#exit-codes)

---

## Core Request Commands

These are the commands you'll use most often. They send HTTP requests, handle responses, and give you fine-grained control over every aspect of the request/response cycle.

### `volt run <file|dir>`

The bread and butter of Volt. Execute an HTTP request defined in a `.volt` file, or run all `.volt` files in a directory.

**Basic usage:**

```bash
volt run api/get-users.volt              # Run a single request
volt run api/                            # Run all .volt files in directory
volt api/get-users.volt                  # Shorthand — "run" is optional!
```

**Output control:**

```bash
volt run file.volt -v                    # Verbose — show full request AND response
volt run file.volt -q                    # Quiet — only output the response body
volt run file.volt --print=hb            # Custom — show response headers + body only
volt run file.volt --print=HBhbm         # Everything: req Headers, req Body, resp headers, resp body, metadata
volt run file.volt --pretty=all          # Pretty-print with colors and formatting (default)
volt run file.volt --pretty=none         # Raw output, no formatting
volt run file.volt --pretty=colors       # Colors but no reformatting
volt run file.volt --pretty=format       # Reformatting but no colors
volt run file.volt --sorted              # Sort headers and JSON keys alphabetically
volt run file.volt -o response.json      # Save response body to a file
```

Here's what the `--print` letters mean:

| Letter | Meaning |
|--------|---------|
| `H` | Request headers |
| `B` | Request body |
| `h` | Response headers |
| `b` | Response body |
| `m` | Metadata (timing, size) |

**Request behavior:**

```bash
volt run file.volt --timeout 5000        # Timeout after 5 seconds (in milliseconds)
volt run file.volt --retry 3             # Retry up to 3 times on failure
volt run file.volt --retry 3 --retry-strategy exponential   # Exponential backoff
volt run file.volt --retry 3 --retry-strategy linear        # Linear backoff
volt run file.volt --retry 3 --retry-strategy constant      # Same delay each retry
volt run file.volt --dry-run             # Show the request without actually sending it
volt run file.volt --offline             # Print the raw HTTP request to stdout (great for debugging)
volt run file.volt --sign                # Sign the request with HMAC-SHA256 (reads signing: config)
volt run file.volt --check-status        # Exit with meaningful code (4 for 4xx, 5 for 5xx, etc.)
volt run file.volt --env staging         # Use the "staging" environment from _env.volt
```

**Downloads and streaming:**

```bash
volt run file.volt --download            # Download response body to a file (with progress bar!)
volt run file.volt -d                    # Short form of --download
volt run file.volt -d --continue         # Resume an interrupted download
volt run file.volt -d -c                 # Short form of --download --continue
volt run file.volt --stream              # Stream response chunks in real-time
volt run file.volt -S                    # Short form of --stream
volt run file.volt --chunked             # Use Transfer-Encoding: chunked
volt run file.volt --compress            # Compress request body (deflate)
volt run file.volt -x                    # Short form of --compress
```

**Sessions (persist cookies, headers, auth between requests):**

```bash
volt run file.volt --session=myapi       # Use named session — persists cookies and headers
volt run file.volt --session-read-only=myapi  # Load session but don't save changes
```

Session data is stored in `.volt-sessions/<host>/<name>.json`.

**TLS, certificates, and proxies:**

```bash
volt run file.volt --cert client.pem --cert-key client.key   # Client certificate (mTLS)
volt run file.volt --ca-bundle /path/to/ca.crt               # Custom CA certificate bundle
volt run file.volt --verify=no                                # Skip TLS verification (use carefully!)
volt run file.volt --verify=yes                               # Enable TLS verification (default)
volt run file.volt --ssl=tls1.2                               # Pin to TLS 1.2
volt run file.volt --ssl=tls1.3                               # Pin to TLS 1.3
volt run file.volt --proxy http://proxy:8080                  # HTTP proxy
volt run file.volt --proxy socks5://user:pass@host:1080       # SOCKS5 proxy with auth
```

**HTTP version:**

```bash
volt run file.volt --http2               # Force HTTP/2 framing
volt run file.volt --http3               # Force HTTP/3 (QUIC) framing
```

---

### `volt quick [METHOD] <url> [items...]`

HTTPie-style shorthand for quick, one-off requests without creating a `.volt` file. Perfect for rapid testing and exploration.

**Alias:** `volt q`

```bash
# Simple GET request
volt quick https://api.example.com/users
volt q https://api.example.com/users          # Same thing, shorter alias

# POST with JSON body (auto-detected when you provide body items)
volt quick POST https://api.example.com/users name=John age:=30

# Localhost shorthand — :3000 becomes http://localhost:3000
volt quick :3000/users
volt quick POST :3000/users name=John

# PUT request
volt quick PUT :3000/users/1 name=Jane email=jane@example.com

# Query parameters
volt quick GET https://api.example.com/users q==search page==1

# Custom headers
volt quick :3000/api Authorization:"Bearer my-token" Accept:application/json

# File upload (switches to multipart automatically)
volt quick POST :3000/upload file@./data.csv
```

**Item types — how Volt interprets what you type:**

| Syntax | What it does | Example |
|--------|-------------|---------|
| `field=value` | JSON string field in body | `name=John` → `{"name": "John"}` |
| `field:=value` | Raw JSON value (number, bool, object, array) | `age:=30` → `{"age": 30}` |
| `param==value` | URL query parameter | `q==search` → `?q=search` |
| `Header:Value` | HTTP header | `Accept:application/json` |
| `field@/path` | File upload (switches to multipart) | `avatar@./photo.jpg` |

**Smart defaults that save you typing:**

- No body items? Volt assumes **GET**. Body items present? Volt assumes **POST**.
- `:3000/path` automatically becomes `http://localhost:3000/path`
- When sending JSON body items, Volt auto-adds `Content-Type: application/json`

---

## Testing Commands

Volt has built-in testing — no separate test runner needed. Write assertions right in your `.volt` files and run them with these commands.

### `volt test [file|dir]`

Run test assertions defined in `.volt` files. This is one of Volt's most powerful features — your API tests live right alongside your request definitions.

```bash
volt test                                # Test all .volt files in current directory
volt test api/users.volt                 # Test a single file
volt test api/                           # Test all files in a directory
volt test --watch                        # Watch mode — re-run tests when files change
volt test --report junit -o results.xml  # Generate JUnit XML report (for CI/CD)
volt test --report html -o report.html   # Generate HTML report (great for sharing)
volt test --report json -o results.json  # Generate JSON report (for custom tooling)
volt test template.volt --data data.csv  # Data-driven testing with CSV
volt test template.volt --data data.json # Data-driven testing with JSON
```

**Example output:**

```
api/users.volt
  ✓ status equals 200
  ✓ $.name equals Leanne Graham
  ✓ header.content-type contains json

api/posts.volt
  ✓ status equals 200
  ✓ $.length > 0

5 passed, 0 failed (243ms)
```

See the [Testing Guide](testing.md) for a deep dive into assertions, data-driven testing, and more.

---

### `volt bench <file> [-n N] [-c N]`

Load test a request — send it many times and see how your API performs under pressure.

```bash
volt bench api/health.volt               # Quick bench with defaults
volt bench api/health.volt -n 100        # Send 100 requests
volt bench api/health.volt -n 200 -c 20  # 200 requests, 20 running at the same time
volt bench api/health.volt -n 1000 -c 50 # 1000 requests, 50 concurrent
```

**What you get back:**

- Total requests and time taken
- Requests per second (throughput)
- Response time percentiles: p50 (median), p95, p99
- Min, max, and average response times
- Error count and error rate

This is invaluable for catching performance problems before they hit production.

---

### `volt monitor <file> [-i INTERVAL] [-n COUNT]`

Monitor an endpoint's health over time. Like a simple uptime checker built right into Volt.

```bash
volt monitor api/health.volt                 # Monitor with default settings
volt monitor api/health.volt -i 30           # Check every 30 seconds
volt monitor api/health.volt -i 30 -n 100    # Check every 30s, stop after 100 checks
volt monitor api/health.volt -i 60 -n 1440   # Every minute for 24 hours
```

Volt tracks response times, pass/fail status, and trend analysis over the monitoring period. Great for post-deployment verification.

---

### `volt validate <file>`

Validate API responses against JSON Schemas. This ensures your API returns exactly the data structure you expect.

```bash
volt validate api/users.volt --schema schema.json    # Validate against a schema file
volt validate api/users.volt --infer                  # Auto-infer a schema from the response
```

When you use `--infer`, Volt looks at the actual response and generates a JSON Schema for you. This is a great starting point for building your validation rules.

---

## Collection and Organization

These commands help you manage, organize, and explore your API request collections.

### `volt collection <dir>`

Run all requests in a directory in order. Requests execute alphabetically (use numeric prefixes like `01-`, `02-` to control order), and variables extracted from one request are available to the next.

```bash
volt collection api/                     # Run the whole collection
volt collection api/ --env staging       # Run with staging environment
```

This is how you build multi-step workflows like "login, then use the token to fetch data."

---

### `volt search <query>`

Search and explore your request collections. Volt uses weighted scoring to find the most relevant results.

```bash
volt search users                        # Search by name, URL, or tag
volt search --tag auth                   # Filter by tag only
volt search --tree                       # Show your collection as a directory tree
volt search --stats                      # Show collection statistics (count, tags, methods)
```

---

### `volt lint [dir]`

Validate `.volt` files for syntax errors. Run this before committing to catch problems early.

```bash
volt lint                                # Lint all files in current directory
volt lint .                              # Same thing
volt lint api/                           # Lint a specific directory
```

---

### `volt diff <a> <b>`

Compare two `.volt` files or their responses side by side.

```bash
volt diff api/v1.volt api/v2.volt                # Compare the file definitions
volt diff api/v1.volt api/v2.volt --response     # Compare the actual responses
```

---

## Import and Export

Volt plays well with other tools. Import your existing collections, export to any language, and generate documentation.

### `volt import <format> <file>`

Import requests from other API tools. One command turns your existing collections into `.volt` files.

```bash
volt import postman collection.json      # Postman (v2.0 and v2.1)
volt import curl "curl -X GET ..."       # cURL command
volt import openapi spec.yaml            # OpenAPI 3.x / Swagger
volt import insomnia export.json         # Insomnia
volt import har traffic.har              # HAR files (browser network recordings)
```

What gets preserved: auth settings, headers, request body, scripts, folder structure, form data, and more. See the [Import & Export Guide](import-export.md) for details.

---

### `volt export <format> <file>`

Export a `.volt` file to code in 18+ languages. Instantly get working code you can paste into your project.

```bash
volt export curl api/login.volt          # cURL command
volt export python api/login.volt        # Python (requests library)
volt export javascript api/login.volt    # JavaScript (fetch API)
volt export go api/login.volt            # Go (net/http)
volt export ruby api/login.volt          # Ruby (Net::HTTP)
volt export php api/login.volt           # PHP (cURL)
volt export csharp api/login.volt        # C# (.NET HttpClient)
volt export rust api/login.volt          # Rust (reqwest)
volt export java api/login.volt          # Java (HttpClient)
volt export swift api/login.volt         # Swift (URLSession)
volt export kotlin api/login.volt        # Kotlin (OkHttp)
volt export dart api/login.volt          # Dart (http package)
volt export r api/login.volt             # R (httr)
volt export httpie api/login.volt        # HTTPie command
volt export wget api/login.volt          # wget command
volt export powershell api/login.volt    # PowerShell (Invoke-WebRequest)
volt export openapi api/                 # Generate OpenAPI spec from collection
volt export har api/login.volt           # Export as HAR recording
```

---

### `volt har <subcommand>`

Work with HAR (HTTP Archive) files — the standard format browsers use to record network traffic.

```bash
volt har export api/users.volt           # Export request as HAR
volt har import traffic.har              # Import HAR file as .volt files
```

---

### `volt docs [dir]`

Auto-generate API documentation from your `.volt` files. Great for sharing with your team or publishing.

```bash
volt docs api/                           # Generate Markdown documentation
volt docs api/ --format html -o docs.html  # Generate HTML documentation
```

---

### `volt design <spec.json>`

OpenAPI design-first workflow. Start with a spec and generate everything from it.

```bash
volt design openapi.json                 # Show a summary of the spec
volt design openapi.json generate        # Generate .volt files from the spec
volt design openapi.json validate        # Validate responses against the spec
```

---

### `volt generate <file>`

Auto-generate test assertions based on an actual API response. Volt runs the request, looks at the response, and creates sensible tests for you.

```bash
volt generate api/users.volt -o users-test.volt    # Generate tests and save to file
```

This is a great way to bootstrap your test suite — let Volt generate the tests, then tweak them to your needs.

---

## Protocol Commands

Volt isn't just for REST APIs. It speaks multiple protocols right out of the box.

### `volt graphql <file>`

Execute GraphQL queries and mutations. Volt understands GraphQL and provides special features like introspection and schema caching.

```bash
volt graphql api/query.volt              # Execute a GraphQL query
volt graphql introspect https://api.example.com/graphql   # Fetch the schema
```

Schema introspection results are cached with a configurable TTL, so subsequent queries get auto-completion and validation. See the [Protocols Guide](protocols.md) for more.

---

### `volt ws <url>`

Connect to a WebSocket server for real-time, two-way communication.

```bash
volt ws wss://echo.websocket.org         # Connect to a WebSocket endpoint
volt ws ws://localhost:8080/chat          # Connect to local WebSocket
```

---

### `volt sse <url>`

Connect to a Server-Sent Events endpoint for one-way streaming from the server.

```bash
volt sse https://api.example.com/events  # Connect to SSE stream
```

SSE is automatically detected when the response has `Content-Type: text/event-stream`, and the `--stream` flag is enabled automatically.

---

### `volt mqtt <host> pub|sub <topic> [message]`

MQTT v3.1.1 client for lightweight publish/subscribe messaging (commonly used in IoT).

```bash
volt mqtt localhost:1883 sub "sensors/#"           # Subscribe to all sensor topics
volt mqtt localhost:1883 pub "sensors/temp" "22.5"  # Publish a temperature reading
```

Supports QoS levels 0, 1, and 2. The `#` wildcard subscribes to all subtopics, and `+` matches a single level.

---

### `volt socketio <url> [emit <event> <data>]`

Socket.IO v4/v5 client for real-time bidirectional communication.

**Alias:** `volt sio`

```bash
volt sio http://localhost:3000                       # Connect to Socket.IO server
volt sio http://localhost:3000 emit "chat" "hello"   # Emit an event with data
```

---

### `volt grpc <service>`

Work with gRPC services. Parse `.proto` files and generate `.volt` request files.

```bash
volt grpc list service.proto                     # List all services and methods
volt grpc service.proto --output api/            # Generate .volt files from proto
```

**Note:** gRPC is in beta. Proto parsing and `.volt` generation work well. Actual gRPC calls over HTTP/2+TLS are still being refined.

---

## Security and Authentication

Volt takes security seriously. These commands help you manage authentication, encrypt secrets, and share requests safely.

### `volt login <provider>`

OAuth 2.0 login with PKCE (Proof Key for Code Exchange) — the modern, secure way to authenticate with APIs.

```bash
volt login github                        # Login with GitHub
volt login google                        # Login with Google
volt login custom --auth-url <url> --token-url <url> --client-id <id>   # Custom OAuth
volt login --status                      # Check if you're logged in
volt login --logout                      # Clear stored tokens
```

See the [Authentication Guide](authentication.md) for all 8+ auth methods supported in `.volt` files.

---

### `volt secrets`

Manage encrypted secrets in your `.volt` files. This lets you safely commit `.volt` files to git without exposing passwords, tokens, or API keys.

```bash
volt secrets keygen                      # Generate a 32-byte encryption key
volt secrets encrypt file.volt <key>     # Encrypt sensitive fields in-place
volt secrets decrypt file.volt <key>     # Decrypt back to plaintext
volt secrets detect file.volt            # Scan for accidentally unencrypted secrets
```

See the [Security Guide](security.md) for a complete walkthrough.

---

### `volt share <file>`

Share a request as a portable string that anyone can import.

```bash
volt share api/login.volt                # Base64-encoded (default)
volt share api/login.volt --format curl  # As a cURL command
volt share api/login.volt --format url   # As a volt:// URL
volt share import <base64>              # Import a shared request
```

---

## Development Tools

Power tools for API development workflows — watch files, capture traffic, replay requests, and more.

### `volt watch <file|dir>`

Watch files and automatically re-run requests or tests when they change. Like `jest --watch` for APIs.

```bash
volt watch api/health.volt               # Re-run when file changes
volt watch api/ --test                   # Re-run tests when any file in directory changes
volt watch api/ --interval 2000          # Custom poll interval (milliseconds)
```

---

### `volt history`

View and manage your request history. Volt remembers what you've sent.

```bash
volt history                             # List recent requests (same as volt history list)
volt history list                        # List recent requests
volt history clear                       # Clear all history
```

---

### `volt replay <index>`

Replay a request from your history and see what changed (diff against the previous response).

```bash
volt replay 0                            # Replay most recent request
volt replay 1                            # Replay second most recent
volt replay 0 --verbose                  # Detailed diff output
volt replay 0 --no-diff                  # Replay without showing the diff
```

This is fantastic for debugging — "did the API response change since last time?"

---

### `volt mock [dir] [--port N]`

Start a mock server that serves responses defined in your `.volt` files. Each `.volt` file becomes a route.

```bash
volt mock api/ --port 3000               # Start mock server on port 3000
volt mock api/                           # Start on default port
```

This lets your frontend team work against a mock API while the backend is still being built.

---

### `volt proxy [--port N] [--output dir]`

Capture HTTP/HTTPS traffic passing through a proxy and automatically convert it to `.volt` files. Supports CONNECT tunneling for HTTPS.

```bash
volt proxy --port 8888 --output captured/   # Capture traffic, save as .volt files
volt proxy --port 8888                       # Capture without saving
```

Configure your browser or app to use `http://localhost:8888` as its proxy, then browse normally. Volt captures every request and converts it.

---

### `volt workflow <file>`

Run a multi-step request workflow with variable propagation, wait points, and conditionals.

**Alias:** `volt wf`

```bash
volt workflow ci-pipeline.workflow       # Run a workflow file
volt wf login-flow.workflow              # Using the alias
```

See the [Scripting Guide](scripting.md) for how to write workflow files.

---

## Configuration and Setup

Commands for initializing projects, managing environments, customizing themes, and configuring your Volt setup.

### `volt init`

Initialize a new Volt project in the current directory.

```bash
volt init
```

This creates three files:
- **`.voltrc`** — Project configuration (base URL, timeout, default headers)
- **`example.volt`** — A sample request to get you started
- **`_env.volt`** — Environment variables (dev, staging, production)

---

### `volt env`

Manage environment variables. Environments let you use the same requests against different servers (dev, staging, production).

```bash
volt env list                            # List all environments and their variables
volt env set API_KEY my-secret-key       # Set a variable
volt env get API_KEY                     # Get a variable's value
volt env create staging                  # Create a new environment
volt env delete staging                  # Delete an environment
```

See the [Environments Guide](environments.md) for a deep dive.

---

### `volt theme`

Manage terminal color themes. Make Volt look the way you like.

```bash
volt theme list                          # Show all available themes
volt theme set dracula                   # Set your theme
volt theme preview nord                  # Preview a theme without setting it
```

**Available themes:** `dark` (default), `light`, `solarized`, `nord`, `dracula`, `monokai`, `gruvbox`, `catppuccin`, `none` (no colors).

---

### `volt cache`

Manage the response cache. Volt can cache responses to speed up repeated requests.

```bash
volt cache stats                         # Show cache size and entries
volt cache clear                         # Clear all cached responses
```

---

### `volt completions <shell>`

Generate shell auto-completion scripts. Tab-completion makes Volt even faster to use.

```bash
# Bash
volt completions bash >> ~/.bashrc

# Zsh
volt completions zsh >> ~/.zshrc

# Fish
volt completions fish > ~/.config/fish/completions/volt.fish

# PowerShell
volt completions powershell >> $PROFILE
```

After adding completions, restart your shell or run `source ~/.bashrc` (or equivalent).

---

### `volt plugin`

Manage plugins that extend Volt's functionality.

```bash
volt plugin list                         # List installed plugins
volt plugin init myPlugin                # Create a plugin scaffold (directory + manifest)
volt plugin run manifest.json input.json # Test a plugin with sample input
```

See the [Plugin Development Guide](plugin-development.md) for how to build your own plugins.

---

## Web and UI

Volt gives you three interfaces — all from the same tiny binary.

### `volt ui`

Open the web-based UI in your browser. No Electron, no installation — just your browser and Volt.

```bash
volt ui                                  # Opens browser to http://localhost:8080
volt ui --port 3000                      # Custom port
```

This binds to `localhost` only (127.0.0.1) — safe for local development.

---

### `volt serve`

Start the web UI bound to all network interfaces (`0.0.0.0`). This lets other people on your network access the UI.

```bash
volt serve                               # Default port 8080
volt serve --port 8080                   # Custom port
```

Use this for team/self-hosted access on a local network.

---

### `volt` (no arguments)

Launch the Terminal UI (TUI) — an interactive, full-screen interface right in your terminal with vim keybindings, tabs, split-pane view, and more.

```bash
volt                                     # Launch the TUI
```

See the [Web UI Guide](web-ui.md) for a full tour of both interfaces.

---

## Information

### `volt version`

Show the Volt version.

```bash
volt version
volt --version
volt -v
```

### `volt help`

Show help and list all available commands.

```bash
volt help
volt --help
volt -h
```

---

## Complete Flag Reference

These flags work with `volt run` and `volt quick`.

### Output Control

| Flag | Short | Description |
|------|-------|-------------|
| `--verbose` | `-v` | Show full request and response exchange |
| `--quiet` | `-q` | Only output response body |
| `--print=WHAT` | | Control what to show: `H`=req headers, `B`=req body, `h`=resp headers, `b`=resp body, `m`=metadata |
| `--pretty=MODE` | | Formatting mode: `all` (default), `colors`, `format`, `none` |
| `--sorted` | | Sort headers and JSON keys alphabetically |
| `--output FILE` | `-o` | Save response body to file |

### Request Behavior

| Flag | Short | Description |
|------|-------|-------------|
| `--timeout MS` | | Request timeout in milliseconds |
| `--retry N` | | Max retry attempts on failure |
| `--retry-strategy` | | Backoff strategy: `constant`, `linear`, `exponential` |
| `--dry-run` | | Show request without sending |
| `--offline` | | Print raw HTTP request, don't send |
| `--sign` | | Sign request with HMAC-SHA256 |
| `--check-status` | | Map HTTP status to exit code |
| `--env NAME` | | Use named environment |

### Downloads and Streaming

| Flag | Short | Description |
|------|-------|-------------|
| `--download` | `-d` | Download response body to file with progress bar |
| `--continue` | `-c` | Resume interrupted download |
| `--stream` | `-S` | Stream response in real-time (SSE/chunked) |
| `--chunked` | | Use Transfer-Encoding: chunked |
| `--compress` | `-x` | Compress request body (deflate) |

### Sessions

| Flag | Description |
|------|-------------|
| `--session=NAME` | Use named session (persists cookies, headers, auth) |
| `--session-read-only=NAME` | Load session but don't save updates |

### TLS and Certificates

| Flag | Description |
|------|-------------|
| `--cert PATH` | Client certificate for mutual TLS (mTLS) |
| `--cert-key PATH` | Client certificate private key |
| `--ca-bundle PATH` | Custom CA certificate bundle |
| `--verify=yes\|no` | SSL/TLS verification (default: yes) |
| `--ssl=tls1.2\|tls1.3` | Pin TLS version |
| `--proxy URL` | Proxy server (HTTP, HTTPS, or SOCKS5) |

### HTTP Version

| Flag | Description |
|------|-------------|
| `--http2` | Force HTTP/2 framing |
| `--http3` | Force HTTP/3 (QUIC) framing |

---

## Exit Codes

Volt uses meaningful exit codes, compatible with HTTPie. Enable them with `--check-status`.

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Generic error |
| `2` | Request timeout |
| `3` | Too many redirects (3xx) |
| `4` | Client error (4xx) |
| `5` | Server error (5xx) |
| `6` | Connection failed |
| `7` | TLS/SSL error |

These are invaluable in CI/CD pipelines where you need your build to fail when an API is down.

---

## What's Next?

- [Getting Started](getting-started.md) — Install Volt and send your first request
- [.volt File Format](volt-file-format.md) — Complete file format specification
- [Testing Guide](testing.md) — Deep dive into testing features
- [Authentication Guide](authentication.md) — All 8+ auth methods explained
- [Protocols Guide](protocols.md) — GraphQL, WebSocket, SSE, MQTT, and more
- [Scripting Engine](scripting.md) — Pre/post scripts and workflows
- [Security & Secrets](security.md) — Encryption, signing, and safe git commits
- [CI/CD Integration](ci-cd.md) — GitHub Actions, GitLab CI, Jenkins, and more
- [Plugin Development](plugin-development.md) — Build your own plugins
