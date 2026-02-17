# Command Reference

Every Volt CLI command with usage and examples.

---

## Core Commands

### `volt run <file|dir>`

Execute a request from a `.volt` file or all files in a directory.

```bash
volt run api/get-users.volt
volt run api/                          # Run all .volt files in directory
volt run api/login.volt --dry-run      # Show request without sending
volt run api/login.volt -o response.json  # Save response body to file
volt run api/login.volt -q             # Quiet mode — only output body
volt run api/health.volt --timeout 5000   # Custom timeout (ms)
volt run api/health.volt --retry 3        # Retry up to 3 times on failure
volt run api/health.volt --retry 3 --retry-strategy exponential
volt run api/login.volt --sign         # Sign request (reads signing: config)
```

You can also run a file directly without `run`:

```bash
volt api/get-users.volt
```

### `volt test [file|dir]`

Run test assertions defined in `.volt` files.

```bash
volt test                              # Test all .volt files in current dir
volt test api/users.volt               # Test a single file
volt test api/                         # Test all files in a directory
volt test --watch                      # Re-run tests on file changes
volt test --report junit -o results.xml   # JUnit XML report
volt test --report html -o report.html    # HTML report
volt test --report json -o results.json   # JSON report
volt test template.volt --data data.csv   # Data-driven testing
```

### `volt collection <dir>`

Run a collection of requests in order. Requests are executed alphabetically, and variables propagate between them.

```bash
volt collection api/
```

### `volt bench <file> [-n N] [-c N]`

Load test a request.

```bash
volt bench api/health.volt -n 100      # 100 requests
volt bench api/health.volt -n 200 -c 20  # 200 requests, 20 concurrent
```

### `volt init`

Initialize a new Volt project in the current directory.

```bash
volt init
```

Creates `.voltrc` (config), `example.volt` (sample request), and `_env.volt` (environments).

---

## Import & Export

### `volt import <format> <file>`

Import requests from other tools.

```bash
volt import postman collection.json    # Postman v2.0/v2.1
volt import curl "curl -X GET ..."     # cURL command
volt import openapi spec.json          # OpenAPI 3.0 spec
volt import insomnia export.json       # Insomnia
volt import har traffic.har            # HAR 1.2
```

### `volt export <format> <file>`

Export a `.volt` file to other formats.

```bash
volt export curl api/login.volt
volt export python api/login.volt
volt export javascript api/login.volt
volt export go api/login.volt
volt export ruby api/login.volt
volt export php api/login.volt
volt export csharp api/login.volt
volt export rust api/login.volt
volt export java api/login.volt
volt export swift api/login.volt
volt export kotlin api/login.volt
volt export dart api/login.volt
volt export httpie api/login.volt
volt export wget api/login.volt
volt export powershell api/login.volt
```

---

## GraphQL

### `volt graphql <file>`

Execute a GraphQL request from a `.volt` file.

```bash
volt graphql api/query.volt
```

### `volt graphql introspect <url>`

Fetch and display the schema from a GraphQL endpoint.

```bash
volt graphql introspect https://api.example.com/graphql
```

---

## Protocols

### `volt ws <url>`

Connect to a WebSocket server.

```bash
volt ws wss://echo.websocket.org
```

### `volt sse <url>`

Connect to a Server-Sent Events endpoint.

```bash
volt sse https://api.example.com/events
```

### `volt mqtt <host> pub|sub <topic>`

MQTT publish and subscribe (v3.1.1).

```bash
volt mqtt localhost:1883 sub "sensors/#"
volt mqtt localhost:1883 pub "sensors/temp" "22.5"
```

### `volt socketio <url> [emit <event> <data>]`

Socket.IO client. Alias: `volt sio`.

```bash
volt sio http://localhost:3000
volt sio http://localhost:3000 emit "chat" "hello"
```

---

## Security & Secrets

### `volt secrets`

Manage encrypted secrets in `.volt` files for safe git commits.

```bash
volt secrets keygen                     # Generate 32-byte encryption key
volt secrets encrypt file.volt <key>    # Encrypt sensitive fields in-place
volt secrets decrypt file.volt <key>    # Decrypt back to plaintext
volt secrets detect file.volt           # Detect unencrypted secrets
```

### `volt share <file>`

Share a request as a portable string.

```bash
volt share api/login.volt               # Base64-encoded (default)
volt share api/login.volt --format curl  # As cURL command
volt share api/login.volt --format url   # As volt:// URL
volt share import <base64>              # Import a shared request
```

---

## Authentication

### `volt login <provider>`

OAuth 2.0 login with PKCE.

```bash
volt login github
volt login google
volt login custom --auth-url <url> --token-url <url> --client-id <id>
volt login --status                     # Check auth status
volt login --logout                     # Clear stored tokens
```

---

## Search & Organization

### `volt search`

Search and explore your request collections.

```bash
volt search users                       # Search by name, URL, tag
volt search --tag auth                  # Filter by tag
volt search --tree                      # Show collection as a tree
volt search --stats                     # Show collection statistics
```

### `volt lint [dir]`

Validate `.volt` files for syntax errors.

```bash
volt lint .                             # Lint all files in current dir
volt lint api/                          # Lint a specific directory
```

---

## Dev Tools

### `volt watch <file|dir>`

Watch files and re-run on changes. Like `jest --watch` for APIs.

```bash
volt watch api/health.volt              # Re-run on file save
volt watch api/ --test                  # Re-run tests on any change
volt watch api/ --interval 2000         # Custom poll interval (ms)
```

### `volt ci`

Auto-detect CI environment and output appropriate test format.

```bash
volt ci
```

Detects: GitHub Actions, GitLab CI, Jenkins, Azure DevOps, CircleCI, Travis CI, Bitbucket Pipelines.

### `volt mock [dir] [--port N]`

Start a mock server from `.volt` files. Each file becomes a route.

```bash
volt mock api/ --port 3000
```

### `volt proxy [--port N] [--output dir]`

Capture HTTP traffic and auto-convert to `.volt` files.

```bash
volt proxy --port 8888 --output captured/
```

### `volt replay <index>`

Replay a request from history and diff against the previous response.

```bash
volt history                            # View past requests
volt replay 0                           # Replay most recent
volt replay 0 --verbose                 # Detailed diff output
volt replay 0 --no-diff                 # Replay without diffing
```

### `volt design <spec.json>`

OpenAPI design-first workflow — generate `.volt` files from an OpenAPI spec.

```bash
volt design openapi.json                # Show spec summary
volt design openapi.json generate       # Generate .volt files from spec
```

### `volt generate <file>`

Generate test assertions from a response.

```bash
volt generate api/users.volt -o users-test.volt
```

### `volt diff <a> <b>`

Compare two `.volt` files or responses.

```bash
volt diff api/v1.volt api/v2.volt
volt diff api/v1.volt api/v2.volt --response
```

### `volt validate <file>`

Validate responses against JSON schemas.

```bash
volt validate api/users.volt --schema schema.json
volt validate api/users.volt --infer    # Infer schema from response
```

### `volt docs [dir]`

Generate API documentation from `.volt` files.

```bash
volt docs api/                          # Markdown output
volt docs api/ --html -o docs.html      # HTML output
```

### `volt monitor <file>`

Monitor an endpoint's health over time.

```bash
volt monitor api/health.volt -i 30 -n 100   # Every 30s, 100 checks
```

### `volt workflow <file>`

Run a multi-step request workflow.

```bash
volt workflow ci-pipeline.workflow
```

---

## Configuration

### `volt theme`

Manage terminal color themes.

```bash
volt theme list                         # Show available themes
volt theme set dracula                  # Set theme
volt theme preview nord                 # Preview a theme
```

Available themes: `dark` (default), `light`, `solarized`, `nord`, `dracula`, `monokai`, `none`.

### `volt env`

Manage environment variables.

```bash
volt env list                           # List environments
volt env set KEY value                  # Set a variable
```

### `volt completions <shell>`

Generate shell completions.

```bash
volt completions bash >> ~/.bashrc
volt completions zsh >> ~/.zshrc
volt completions fish > ~/.config/fish/completions/volt.fish
volt completions powershell >> $PROFILE
```

### `volt plugin`

Manage plugins.

```bash
volt plugin list                        # List installed plugins
volt plugin init myPlugin               # Create plugin scaffold
volt plugin run manifest.json input.json  # Run a plugin
```

### `volt cache`

Manage response cache.

```bash
volt cache stats                        # Show cache size
volt cache clear                        # Clear all cached responses
```

---

## Web UI

### `volt ui`

Open the web UI in your browser. Serves on `localhost` (local only).

```bash
volt ui                                 # Default port 8080
volt ui --port 3000                     # Custom port
```

### `volt serve`

Start the web UI server bound to `0.0.0.0` for network access (self-hosted team use).

```bash
volt serve                              # Default port 8080
volt serve --port 8080                  # Custom port
```

---

## Other

### `volt version`

```bash
volt version
volt --version
volt -v
```

### `volt help`

```bash
volt help
volt --help
volt -h
```

### `volt har`

HAR format import/export.

```bash
volt har export api/users.volt
volt har import traffic.har
```
