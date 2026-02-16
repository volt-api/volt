<p align="center">
  <h1 align="center">Volt</h1>
  <p align="center"><strong>The API client that respects you.</strong></p>
  <p align="center">Offline-first. Git-native. Single binary. Zero bloat.</p>
  <p align="center">Built from scratch in Zig. 3.9 MB. Starts in 42ms. No Electron.</p>
</p>

<p align="center">
  <a href="#install">Install</a> &bull;
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#benchmarks">Benchmarks</a> &bull;
  <a href="#vs-the-competition">vs The Competition</a> &bull;
  <a href="BENCHMARKS.md">Full Benchmark Report</a>
</p>

---

Volt is a complete API development toolkit built from scratch in **Zig**. It runs as a CLI, a TUI, and produces plain-text `.volt` files that live in your git repo alongside your code. No account required. No cloud sync. No telemetry. No Electron.

```
$ volt run api/users.volt

# Get Users
GET https://api.example.com/users

HTTP 200 OK
Time: 47.3ms | Size: 2841 bytes

[
  { "id": 1, "name": "Alice" },
  { "id": 2, "name": "Bob" }
]
```

## Why Volt?

Your API client shouldn't need 500MB of RAM to send a GET request.

| Problem | Volt's Answer |
|---------|--------------|
| Postman requires an account and internet connection | Volt works **100% offline** |
| Collections locked in proprietary cloud formats | `.volt` files are **plain text in git** |
| Electron apps eat RAM for breakfast | Volt is a **3.9MB static binary** |
| Startup takes seconds | Volt starts in **~50ms** |
| Export your data? Good luck | Volt **is** your data — it's just files |

## Install

### Quick Install (Linux / macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/volt-api/volt/main/scripts/install.sh | bash
```

### Homebrew (macOS / Linux)

```bash
brew install volt-api/volt/volt
```

### Scoop (Windows)

```powershell
scoop bucket add volt https://github.com/volt-api/scoop-volt
scoop install volt
```

### GitHub Actions

```yaml
- uses: volt-api/volt-action@v1
  with:
    command: test
```

### Pre-built Binaries

Download from [Releases](../../releases):

| Platform | Download |
|----------|----------|
| Linux x86_64 | `volt-linux-x86_64` |
| Linux ARM64 | `volt-linux-aarch64` |
| macOS ARM | `volt-macos-aarch64` |
| macOS Intel | `volt-macos-x86_64` |
| Windows | `volt-windows-x86_64.exe` |

```bash
# Linux / macOS
chmod +x volt && sudo mv volt /usr/local/bin/

# Or just put it anywhere on your PATH
```

### Build from Source

Requires [Zig 0.14.1](https://ziglang.org/download/):

```bash
git clone https://github.com/volt-api/volt.git
cd volt
zig build -Doptimize=ReleaseFast
# Binary at ./zig-out/bin/volt
```

## Quick Start

### 1. Create a request

```bash
volt init    # Creates .voltrc, example.volt, _env.volt
```

Or write one by hand — it's just text:

```yaml
# api/get-users.volt
name: Get Users
description: Fetch all users from the API
method: GET
url: https://jsonplaceholder.typicode.com/users
headers:
  - Accept: application/json
tests:
  - status equals 200
  - header.content-type contains json
  - $.0.name equals Leanne Graham
```

### 2. Run it

```bash
volt run api/get-users.volt              # Execute request
volt run api/get-users.volt --verbose    # Show headers + redirect info
volt run api/get-users.volt --dry-run    # Preview without sending
volt run api/                            # Run entire directory as collection
```

### 3. Test it

```bash
volt test                                # Run all .volt files with tests
volt test --report junit -o results.xml  # JUnit XML for CI/CD
volt test --report html -o report.html   # Visual HTML report
volt test --data users.csv               # Data-driven testing
volt test --watch                        # Re-run on changes
```

### 4. Commit it

```bash
git add api/
git commit -m "add user API tests"
# That's it. Your API tests live with your code.
```

## The .volt Format

Plain text. Human readable. Git diffable.

```yaml
name: Create User
description: Register a new user account
method: POST
url: https://{{host}}/api/v1/users
timeout: 5000

headers:
  - Content-Type: application/json
  - Authorization: Bearer {{$api_key}}

auth:
  type: bearer
  token: {{$api_key}}

body:
  type: json
  content: |
    {
      "name": "{{username}}",
      "email": "{{email}}",
      "role": "member"
    }

tests:
  - status equals 201
  - $.id exists
  - $.name equals {{username}}
  - header.location contains /users/

variables:
  username: testuser
  email: test@example.com
```

**Variables** use `{{name}}` syntax. **Secret variables** start with `$` and are masked in output. **Dynamic variables** like `{{$uuid}}`, `{{$timestamp}}`, `{{$randomInt}}` generate fresh values on each run.

## Features

### Core

| Feature | Command |
|---------|---------|
| Execute requests | `volt run <file.volt>` |
| Run collections | `volt run <directory>/` |
| Test assertions | `volt test [files...]` |
| Data-driven testing | `volt test --data data.csv` |
| Watch mode | `volt test --watch` |
| Load testing | `volt bench <file> -n 1000 -c 50` |
| Mock server | `volt mock api/ --port 3000` |
| Request workflows | `volt workflow pipeline.workflow` |
| Endpoint monitoring | `volt monitor health.volt -i 30` |
| Terminal UI | `volt` (no arguments) |

### Import / Export

| Feature | Command |
|---------|---------|
| Import from Postman | `volt import postman collection.json` |
| Import from Insomnia | `volt import insomnia export.json` |
| Import from OpenAPI | `volt import openapi spec.yaml` |
| Import from cURL | `volt import curl 'curl -X POST ...'` |
| Import from HAR | `volt import har recording.har` |
| Export to cURL | `volt export curl request.volt` |
| Export to Python | `volt export python request.volt` |
| Export to JavaScript | `volt export js request.volt` |
| Export to 15+ languages | `volt export <lang> request.volt` |
| Generate API docs | `volt docs api/ --html -o docs.html` |

### Testing & CI

| Feature | Detail |
|---------|--------|
| Status assertions | `status equals 200` |
| Header assertions | `header.content-type contains json` |
| Body assertions | `body contains "success"` |
| JSONPath assertions | `$.data.users[0].name equals Alice` |
| JUnit XML reports | `--report junit` for GitHub Actions / Jenkins |
| HTML reports | `--report html` with dark theme |
| JSON reports | `--report json` for custom tooling |
| Data-driven testing | `--data file.csv` or `--data file.json` |
| Schema validation | `volt validate file.volt --schema schema.txt` |
| Schema inference | `volt validate file.volt --infer` |

### Authentication

| Type | Syntax in .volt |
|------|----------------|
| Bearer token | `auth: { type: bearer, token: ... }` |
| Basic auth | `auth: { type: basic, username: ..., password: ... }` |
| API key | `auth: { type: api_key, key_name: ..., key_value: ... }` |
| Digest auth | `auth: { type: digest, username: ..., password: ... }` |
| OAuth 2.0 | `volt auth oauth <token-url> --client-id <id>` |
| Collection-level auth | Define in `_collection.volt`, inherited by all requests |

### Advanced

| Feature | Detail |
|---------|--------|
| Environments | `_env.volt` files with `{{variable}}` interpolation |
| Dynamic variables | `{{$uuid}}`, `{{$timestamp}}`, `{{$randomInt}}`, `{{$isoDate}}` |
| Secret masking | Variables starting with `$` are masked in output |
| Request signing | HMAC-SHA256 request signing |
| Cookie jar | Cookies persist across collection runs automatically |
| Retry with backoff | `--retry 3 --retry-strategy exponential` |
| Response caching | Session-level response cache |
| gRPC | `volt grpc list service.proto` / generate .volt from proto |
| WebSocket | `volt ws wss://echo.websocket.org` |
| SSE | `volt sse https://api.example.com/events` |
| GraphQL | `volt graphql query.volt` / introspection |
| Request diffing | `volt diff a.volt b.volt --response` |
| Shell completions | `volt completions bash\|zsh\|fish\|powershell` |

## Benchmarks

Measured on Windows 11, AMD Ryzen, NVMe SSD. Volt built with `zig build -Doptimize=ReleaseFast`.
Full methodology and raw data: **[BENCHMARKS.md](BENCHMARKS.md)**

### vs The Competition

| | Volt | curl | HTTPie | Bruno | Insomnia | Postman |
|---|---|---|---|---|---|---|
| **Install size** | **3.9 MB** | ~300 KB | ~30 MB | ~150 MB | ~470 MB | ~500 MB |
| **Startup** | **~42ms** | ~46ms | ~500-2000ms | ~800-2000ms | ~2-4s | ~3-8s |
| **RAM (idle)** | **~5 MB** | ~3 MB | ~30 MB | ~80-150 MB | ~200-400 MB | ~300-800 MB |
| **Dependencies** | **0** | libcurl | Python | Electron | Electron | Electron |
| **Account required** | **No** | No | No | No | Optional | **Yes** |
| **Offline** | **Yes** | Yes | Yes | Yes | Partial | Requires login |
| **Git native** | **Yes** | N/A | N/A | Yes | No | No |
| **Built-in tests** | **Yes** | No | No | No | No | Separate (Newman) |
| **CI/CD ready** | **Copy 1 file** | N/A | pip install | npm install | npm install | npm install |
| **Data format** | **Plain text** | N/A | N/A | JSON files | JSON + DB | JSON (cloud) |

> Sources: [Postman system requirements](https://learning.postman.com/docs/getting-started/installation/system-requirements), [Postman RAM issues](https://github.com/postmanlabs/postman-app-support/issues/4687), [Bruno vs Postman](https://www.usebruno.com/compare/bruno-vs-postman), [Insomnia download](https://www.softpedia.com/get/Programming/Other-Programming-Files/Insomnia-HTTP-Client.shtml), [HTTPie startup](https://github.com/httpie/cli/issues/1298)

### Volt Raw Numbers

```
Startup:            42ms average  (10 runs, min 38ms, max 52ms)
curl baseline:      46ms average  (same machine — Volt matches curl)
Parse .volt file:   8.7ms
Lint 9 files:       43ms
Export to curl:     40ms
127 unit tests:     400ms
Build (release):    265ms
Build (debug):      400ms
Binary:             3.9 MB (zero dependencies)
```

### What This Means In Practice

If you open your API client **20 times a day**:
- Volt: 20 x 42ms = **0.84 seconds** per day
- Postman: 20 x 5s = **100 seconds** per day (~30 minutes/month wasted on startup)

In **CI/CD pipelines**:
- Volt: Copy binary, run tests. No runtime, no `npm install`, no Docker image.
- Postman/Newman: Install Node.js, `npm install newman`, wait for startup.

### Why It's Fast

Volt is written in **Zig** — a systems programming language for performance-critical software. No garbage collector. No runtime. No virtual machine.

The same language powering:
- [Bun](https://bun.sh) — the JavaScript runtime
- [Tigerbeetle](https://tigerbeetle.com) — the financial database
- Infrastructure at Uber, Cloudflare, and AWS

This isn't JavaScript wrapped in Chromium pretending to be a desktop app. This is a native binary that starts before your terminal prompt finishes rendering.

## Environments

Create `_env.volt` files for different environments:

```yaml
environment: dev
variables:
  host: api.dev.example.com
  api_version: v2
  $api_key: dev-secret-key-123
```

```yaml
environment: production
variables:
  host: api.example.com
  api_version: v2
  $api_key: prod-secret-key-456
```

```bash
volt run api/users.volt --env dev        # Use dev environment
volt run api/users.volt --env production # Use production
```

Variables starting with `$` are **secrets** — automatically masked as `***` in output.

## CI/CD Integration

### GitHub Actions

```yaml
name: API Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        run: |
          curl -L https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
          chmod +x volt
          sudo mv volt /usr/local/bin/

      - name: Run API tests
        run: volt test --report junit -o test-results.xml

      - name: Upload test results
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: test-results.xml
```

### GitLab CI

```yaml
api_tests:
  script:
    - volt test --report junit -o results.xml
  artifacts:
    reports:
      junit: results.xml
```

## Shell Completions

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

## Migrating from Other Tools

```bash
# From Postman
volt import postman collection.json --output api/

# From Insomnia
volt import insomnia export.json --output api/

# From OpenAPI / Swagger
volt import openapi spec.yaml --output api/

# From cURL
volt import curl 'curl -X POST https://api.example.com/users -H "Content-Type: application/json" -d "{\"name\":\"test\"}"' --output create-user.volt

# From HAR (browser network recording)
volt import har recording.har --output api/
```

## Built With Zig

Volt is one of the first production developer tools built entirely in Zig. Here's why that matters:

- **No dependencies.** The entire project uses only the Zig standard library. No package manager, no node_modules, no transitive dependency surprises.
- **Cross-compilation built in.** `zig build -Dtarget=x86_64-linux` produces a Linux binary from Windows or macOS. No Docker. No CI matrix. One command.
- **Comptime.** Zig's compile-time execution means zero-cost abstractions that are actually zero-cost. Format strings are validated at compile time. Buffer sizes are computed at compile time.
- **No hidden allocations.** Every allocation is explicit. Every byte is accounted for. This is why Volt uses 5MB of RAM while Postman uses 500MB.
- **Safety without overhead.** Bounds checking, null safety, and error unions — without a garbage collector or runtime.

If you're curious about Zig: [ziglang.org](https://ziglang.org)

## Project Stats

```
Files:         45 Zig source files
Code:          19,149 lines
Tests:         127 (all passing)
Dependencies:  0 (stdlib only)
Binary:        3.9 MB (release)
Platforms:     Windows, Linux, macOS (x86_64, aarch64)
```

## Roadmap

- [ ] AI-powered test generation (run request, get suggested assertions)
- [ ] VS Code extension
- [ ] `volt cloud` — optional encrypted sync (paid feature)
- [ ] Team workspaces with RBAC
- [ ] Plugin system for custom auth flows
- [ ] Interactive TUI improvements (split pane, syntax highlighting)
- [ ] Hosted mock servers
- [ ] API monitoring dashboard

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). We welcome PRs!

```bash
zig build test    # All 127 tests must pass
```

## License

[MIT](LICENSE)

---

<p align="center">
  <strong>Volt</strong> &mdash; The API Client That Respects You
  <br>
  Built with Zig. No account required. No telemetry. No nonsense.
</p>
