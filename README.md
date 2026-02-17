<p align="center">
  <h1 align="center">Volt</h1>
  <p align="center"><strong>The API client that respects you.</strong></p>
  <p align="center">Offline-first. Git-native. Single binary. Zero bloat.</p>
</p>

<p align="center">
  <code>3.9 MB binary</code> &nbsp;&middot;&nbsp; <code>42ms startup</code> &nbsp;&middot;&nbsp; <code>5 MB RAM</code> &nbsp;&middot;&nbsp; <code>0 dependencies</code>
</p>

<p align="center">
  <a href="#install">Install</a> &bull;
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#the-volt-format">The .volt Format</a> &bull;
  <a href="#how-volt-compares">How Volt Compares</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#web-ui">Web UI</a> &bull;
  <a href="docs/getting-started.md">Docs</a> &bull;
  <a href="BENCHMARKS.md">Benchmarks</a>
</p>

---

<p align="center">
  <img src="assets/volt-demo.svg" alt="Volt running a GET request with syntax-highlighted JSON response in 47ms" width="800">
</p>

Volt is a complete API development toolkit built from scratch in **Zig**. 62 modules, 37,000+ lines, 383 tests — zero external dependencies. Plain-text `.volt` files live in your git repo alongside your code. No account required. No cloud sync. No telemetry. No Electron. Just a single binary that does everything Postman does in 1/128th the size.

> **[Getting Started](docs/getting-started.md)** &nbsp;&middot;&nbsp; **[Command Reference](docs/commands.md)** &nbsp;&middot;&nbsp; **[.volt File Format](docs/volt-file-format.md)**

## Install

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/volt-api/volt/main/scripts/install.sh | bash

# Homebrew
brew install volt-api/volt/volt

# Scoop (Windows)
scoop bucket add volt https://github.com/volt-api/scoop-volt && scoop install volt
```

Or download a [pre-built binary](../../releases) — it's a single file, just put it on your PATH.

<details>
<summary><strong>More install options</strong></summary>

### GitHub Actions

```yaml
- uses: volt-api/volt-action@v1
  with:
    command: test
```

### Pre-built Binaries

| Platform | Download |
|----------|----------|
| Linux x86_64 | `volt-linux-x86_64` |
| Linux ARM64 | `volt-linux-aarch64` |
| macOS ARM | `volt-macos-aarch64` |
| macOS Intel | `volt-macos-x86_64` |
| Windows | `volt-windows-x86_64.exe` |

### Build from Source

Requires [Zig 0.14.1](https://ziglang.org/download/):

```bash
git clone https://github.com/volt-api/volt.git && cd volt
zig build -Doptimize=ReleaseFast
# Binary at ./zig-out/bin/volt
```

</details>

## Quick Start

**1. Create a request** — it's just a text file:

```yaml
# api/get-users.volt
name: Get Users
method: GET
url: https://jsonplaceholder.typicode.com/users
headers:
  - Accept: application/json
tests:
  - status equals 200
  - header.content-type contains json
  - $.0.name equals Leanne Graham
```

**2. Run it:**

```bash
volt run api/get-users.volt          # Execute request
volt run api/                        # Run entire directory as collection
```

**3. Test it:**

```bash
volt test api/                       # Run all tests
volt test --report junit -o results.xml   # CI/CD output
```

<p align="center">
  <img src="assets/volt-test.svg" alt="Volt test results: 7 passed, 0 failed in 243ms" width="700">
</p>

**4. Commit it.** Your API tests now live in git alongside your code. No cloud. No sync conflicts. Just files.

## The .volt Format

Plain text. Human readable. Git diffable. Everything in one file.

<p align="center">
  <img src="assets/volt-file.svg" alt="A .volt file showing method, URL, headers, JSON body, and test assertions" width="680">
</p>

- **Variables**: `{{name}}` syntax, resolved from `_env.volt` files or inline `variables:` blocks
- **Secrets**: Variables starting with `$` are automatically masked as `***` in output
- **Dynamic values**: `{{$uuid}}`, `{{$timestamp}}`, `{{$randomInt}}`, `{{$isoDate}}` generate fresh values each run
- **Environments**: Switch with `--env dev` or `--env production`

```yaml
# _env.volt
environment: dev
variables:
  host: api.dev.example.com
  $api_key: dev-secret-key-123    # masked in output
```

## How Volt Compares

<p align="center">
  <img src="assets/volt-comparison.svg" alt="Volt vs HTTPie vs Bruno vs Insomnia vs Postman: binary size, startup time, memory, and feature comparison" width="790">
</p>

| | Volt | curl | HTTPie | Bruno | Insomnia | Postman |
|---|---|---|---|---|---|---|
| **Install size** | **3.9 MB** | ~300 KB | ~30 MB | ~150 MB | ~470 MB | ~500 MB |
| **Startup** | **~42ms** | ~46ms | ~500-2000ms | ~800-2000ms | ~2-4s | ~3-8s |
| **RAM (idle)** | **~5 MB** | ~3 MB | ~30 MB | ~80-150 MB | ~200-400 MB | ~300-800 MB |
| **Dependencies** | **0** | libcurl | Python | Electron | Electron | Electron |
| **Account required** | **No** | No | No | No | Optional | **Yes** |
| **Works offline** | **Always** | Yes | Yes | Yes | Partial | Requires login |
| **Git native** | **Yes** | N/A | N/A | Yes | No | No |
| **Built-in tests** | **Yes** | No | No | No | No | Separate (Newman) |
| **CI/CD ready** | **Copy 1 file** | N/A | pip install | npm install | npm install | npm install |
| **Data format** | **Plain text** | N/A | N/A | JSON files | JSON + DB | JSON (cloud) |

If you open your API client **20 times a day**: Volt costs you **0.84 seconds**. Postman costs you **100 seconds** (~30 minutes per month wasted on startup alone).

> Full methodology and raw data: **[BENCHMARKS.md](BENCHMARKS.md)**

### Switching from another tool?

```bash
volt import postman collection.json --output api/    # From Postman
volt import insomnia export.json --output api/        # From Insomnia
volt import openapi spec.yaml --output api/           # From OpenAPI / Swagger
volt import curl 'curl -X POST ...' --output req.volt # From cURL
volt import har recording.har --output api/            # From HAR files
```

One command. Your collections become plain text files in git.

## Features

### Requests & Collections

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
| **Web UI** | **`volt ui` (opens browser, no Electron)** |

### Testing & CI

Built-in assertions — no separate test runner needed:

```yaml
tests:
  - status equals 200
  - header.content-type contains json
  - body contains "success"
  - $.data.users[0].name equals Alice
  - $.id exists
```

| Output | Command |
|--------|---------|
| JUnit XML (GitHub Actions, Jenkins) | `volt test --report junit -o results.xml` |
| HTML report (dark theme) | `volt test --report html -o report.html` |
| JSON (custom tooling) | `volt test --report json` |
| Data-driven | `volt test --data users.csv` |
| Schema validation | `volt validate file.volt --schema schema.txt` |

### Import & Export

| Import from | Export to |
|-------------|----------|
| Postman collections | cURL |
| Insomnia | Python, JavaScript, Go |
| OpenAPI / Swagger | Rust, PHP, Java, C# |
| cURL commands | 15+ languages total |
| HAR recordings | API documentation (HTML) |

### Authentication

| Type | Syntax |
|------|--------|
| Bearer token | `auth: { type: bearer, token: ... }` |
| Basic auth | `auth: { type: basic, username: ..., password: ... }` |
| API key | `auth: { type: api_key, key_name: ..., key_value: ... }` |
| Digest auth | `auth: { type: digest, username: ..., password: ... }` |
| OAuth 2.0 | `volt auth oauth <token-url> --client-id <id>` |
| Collection-level | Defined in `_collection.volt`, inherited by all requests |

### Protocols

| Protocol | Command | Status |
|----------|---------|--------|
| HTTP/HTTPS | `volt run request.volt` | Stable |
| GraphQL | `volt graphql query.volt` (with introspection) | Stable |
| WebSocket | `volt ws wss://echo.websocket.org` | Stable |
| SSE | `volt sse https://api.example.com/events` | Stable |
| gRPC | `volt grpc list service.proto` | Beta |
| HTTP/2 | Frame building, HPACK compression, stream management | Beta — TLS negotiation WIP |
| MQTT | `volt mqtt broker:1883 pub topic msg` | Beta |
| Socket.IO | `volt socketio http://localhost:3000` | Beta |

### Security & Sharing

| Feature | Command |
|---------|---------|
| E2E encrypted secrets | `volt secrets keygen` / `encrypt` / `decrypt` |
| Secret detection | `volt secrets detect file.volt` |
| Share requests | `volt share file.volt --format curl\|url` |
| OAuth login (PKCE) | `volt login github\|google\|custom` |

### Dev Tools

| Feature | Command |
|---------|---------|
| Watch mode | `volt watch api/ --test` |
| Zero-config CI | `volt ci` (auto-detects 7 CI environments) |
| Proxy capture | `volt proxy --port 8080` |
| Replay with diff | `volt replay <index> --verbose` |
| Collection search | `volt search <query> --tag auth --tree` |
| OpenAPI design | `volt design spec.json generate` |
| Color themes | `volt theme set dracula` |
| Plugin system | `volt plugin list\|run\|init` |
| Response viewer | HTML-to-text, XML highlighting, timing waterfall |

## Web UI

Volt includes a full browser-based UI — served from the same binary. No Electron. No install. No account.

```bash
volt ui                    # Opens browser to localhost:8080
volt ui --port 3000        # Custom port
volt serve --port 8080     # Bind to 0.0.0.0 (team/self-hosted access)
```

One binary. CLI, TUI, and web UI. Under 5 MB.

### More

- **Retry with backoff**: `--retry 3 --retry-strategy exponential`
- **Cookie jar**: Cookies persist across collection runs
- **Request signing**: HMAC-SHA256
- **Response caching**: Session-level cache
- **Request diffing**: `volt diff a.volt b.volt --response`
- **Shell completions**: Bash, Zsh, Fish, PowerShell

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
      - uses: volt-api/volt-action@v1
        with:
          command: test --report junit -o results.xml
      - uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: results.xml
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

No runtime to install. No `npm install`. Just a binary.

## Built With Zig

Volt is built entirely in [Zig](https://ziglang.org) — the same language behind [Bun](https://bun.sh), [Tigerbeetle](https://tigerbeetle.com), and infrastructure at Uber, Cloudflare, and AWS.

- **Zero dependencies.** Only the Zig standard library. No package manager, no node_modules.
- **Cross-compilation built in.** `zig build -Dtarget=x86_64-linux` produces a Linux binary from any OS.
- **No hidden allocations.** Every byte is accounted for. This is why Volt uses 5 MB while Postman uses 500 MB.

```
62 modules  |  37,000+ lines of code  |  383 tests  |  0 dependencies
```

## Current Limitations

Volt is production-ready for HTTP requests, testing, collections, import/export, CI/CD, and the web UI. Some newer features are still maturing:

- **HTTP/2**: Frame layer and HPACK are built. TLS ALPN negotiation is WIP — real HTTP/2 endpoints fall back to HTTP/1.1.
- **MQTT / Socket.IO**: Packet building and parsing work. Not yet battle-tested against real brokers/servers.
- **gRPC**: Proto parsing and `.volt` generation work. Actual calls depend on HTTP/2 over TLS (see above).
- **OAuth browser flow**: PKCE and token exchange work. Localhost callback server not yet automatic — generates URL for manual flow.
- **Plugin system**: Manifest and discovery work. `volt plugin install <url>` not yet implemented.
- **No GUI**: Terminal-first (CLI + TUI + web UI via `volt ui`). No native desktop app.

## Roadmap

- [ ] Full HTTP/2 over TLS (ALPN negotiation)
- [ ] CI results dashboard (web — first paid feature)
- [ ] Team secrets vault
- [ ] VS Code extension (syntax highlighting)
- [ ] HTTP/3 (QUIC) support
- [ ] GraphQL subscriptions

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). All tests must pass: `zig build test`

## License

[MIT](LICENSE)

---

<p align="center">
  <strong>Stop paying for bloatware. Start using Volt.</strong>
  <br>
  <a href="#install">Install now</a> &mdash; it takes 10 seconds.
</p>
