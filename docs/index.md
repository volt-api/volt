---
layout: home
title: Volt Documentation
---

# Welcome to Volt

**The API client that respects you.**

Volt is a complete API development toolkit built from scratch in [Zig](https://ziglang.org) -- the same language behind [Bun](https://bun.sh), [Tigerbeetle](https://tigerbeetle.com), and infrastructure at Uber, Cloudflare, and AWS. It is a single binary with zero external dependencies that does everything Postman does -- requests, testing, collections, environments, import/export, CI/CD, and even a web UI -- in about 1/100th the size.

No account required. No cloud sync. No telemetry. No Electron. Just a fast, honest tool that works 100% offline and stores everything as plain-text files in your git repo, right alongside your code.

Whether you are building your first API or managing hundreds of endpoints across microservices, Volt is designed to get out of your way and let you work.

---

## At a Glance

| | |
|---|---|
| **Binary size** | ~4 MB -- smaller than most favicons folders |
| **Startup time** | <10 ms -- faster than your terminal prompt |
| **Memory usage** | ~5 MB RAM -- less than a single browser tab |
| **Dependencies** | 0 -- only the Zig standard library, nothing else |
| **Codebase** | 72 modules, 44,000+ lines of Zig, 615+ unit tests |
| **Platforms** | Linux (x86_64, ARM64), macOS (Apple Silicon, Intel), Windows |

Volt starts instantly, uses almost no resources, and never phones home. You can run it on a Raspberry Pi, inside a Docker container, on a CI runner, or on your laptop at 35,000 feet with no Wi-Fi. It just works.

---

## Who Is This For?

Volt is for anyone who works with APIs. Here is how different roles tend to use it:

**Backend developers** -- You are building the API. Volt lets you define requests as `.volt` files that live in your repo. Write tests inline, run them in CI, chain requests together, and export to 18 languages. No context switching to a separate GUI app.

**Frontend developers** -- You are consuming the API. Use `volt quick GET :3000/users` for fast one-off requests during development, or set up a mock server with `volt mock api/` so you can build your UI before the backend is ready.

**QA engineers** -- You need to test the API systematically. Volt has built-in assertions, data-driven testing from CSV/JSON files, JUnit XML reports, HTML reports, and watch mode that re-runs tests when files change. All from a single binary with no test runner to install.

**DevOps and platform engineers** -- You need API tests in CI/CD. Volt auto-detects 7 CI environments (GitHub Actions, GitLab CI, Jenkins, Azure, CircleCI, Travis, Bitbucket). Copy one binary into your pipeline, run `volt test`, done. No `npm install`, no Python runtime, no container images to pull.

**Students and learners** -- You are learning about HTTP, REST, GraphQL, WebSockets, or APIs in general. Volt is free, open source, and runs everywhere. The `.volt` file format is human-readable plain text, so you can see exactly what is happening. No signup walls, no 25-request limits, no "upgrade to pro" prompts.

**Open source maintainers** -- You want contributors to be able to test your API without installing a 500 MB desktop app. Commit your `.volt` files to the repo. Anyone with the single binary can run `volt test api/` and verify everything works.

---

## Quick Navigation

Here is everything in the Volt documentation. If you are brand new, start with **Getting Started** and the **Command Reference**. Everything else you can explore as you need it.

### Essentials

| Guide | Description |
|-------|-------------|
| [Getting Started](getting-started.md) | Install Volt, send your first request, write your first test, set up a project |
| [Command Reference](commands.md) | Every CLI command with complete usage examples and flags |
| [.volt File Format](volt-file-format.md) | The complete specification for `.volt` files -- fields, auth, tests, scripts, variables |

### Configuration and Environments

| Guide | Description |
|-------|-------------|
| [Environments & Configuration](environments.md) | Managing variables across dev, staging, and production with `_env.volt`, `.voltrc`, themes, shell completions, and project structure |

### Testing

| Guide | Description |
|-------|-------------|
| [Testing Guide](testing.md) | Built-in assertions, JSONPath, data-driven testing, watch mode, load testing, monitoring, schema validation, CI reports |

### Authentication

| Guide | Description |
|-------|-------------|
| [Authentication Guide](authentication.md) | Bearer, Basic, API key, Digest, AWS SigV4, Hawk, OAuth 2.0 (PKCE, client credentials, password), mTLS, JWT, sessions |

### Import and Export

| Guide | Description |
|-------|-------------|
| [Import & Export](import-export.md) | Import from Postman, Insomnia, OpenAPI, cURL, HAR. Export to 18 languages. Generate docs. OpenAPI design-first workflow. |

### Protocols

| Guide | Description |
|-------|-------------|
| [Protocols Guide](protocols.md) | HTTP/2, HTTP/3 (QUIC), GraphQL, WebSocket, SSE, MQTT, Socket.IO, gRPC -- all protocols explained with examples |

### Security

| Guide | Description |
|-------|-------------|
| [Security & Secrets](security.md) | E2E encrypted secrets vault, secret detection, request signing, TLS/proxy config, sessions, cookies, safe git commits |

### Scripting

| Guide | Description |
|-------|-------------|
| [Scripting Engine](scripting.md) | Pre-request and post-response scripts -- 24+ commands, variable chaining, workflows, assertions, practical examples |

### Web UI and TUI

| Guide | Description |
|-------|-------------|
| [Web UI Guide](web-ui.md) | Browser-based request builder, response viewer, terminal UI, themes, PWA offline support, keyboard shortcuts, API endpoints |

### CI/CD

| Guide | Description |
|-------|-------------|
| [CI/CD Integration](ci-cd.md) | GitHub Actions, GitLab CI, Jenkins, Azure, CircleCI, Travis, Bitbucket -- complete config examples, reports, Docker |

### Extending Volt

| Guide | Description |
|-------|-------------|
| [Plugin Development](plugin-development.md) | Build plugins using the JSON stdin/stdout protocol -- any language, 4 hook points, sandboxed execution, complete examples |

### Reference

| Guide | Description |
|-------|-------------|
| [Feature Status](FEATURE_STATUS.md) | Honest, up-to-date assessment of every feature -- what is stable, what is beta, what is planned |

---

## Why Volt?

There are a lot of API tools out there. Here is why Volt exists and what makes it different.

### It is a single file

Volt is one binary. Download it, put it on your PATH, and you are done. No installer, no package manager, no runtime, no Docker image. It works on Linux, macOS, and Windows. You can copy it to a USB drive, email it to a teammate, or `scp` it to a server. Uninstalling means deleting one file.

### Your requests live in git

Every request, every test, every environment variable is a plain-text `.volt` file. You can `git diff` them, review them in pull requests, track changes over time, and search them with `grep`. No proprietary JSON blobs. No cloud sync that overwrites your teammate's changes. No "export collection" dance.

### It works offline, always

Volt never contacts a server. There is no login screen, no "checking for updates" spinner, no "could not reach cloud" error. You can build and test an entire API on an airplane, in a subway, or on a network with no internet access. Your work is yours.

### It is absurdly fast

Volt starts in under 10 milliseconds. For comparison, Postman takes 3-8 seconds. If you open your API client 20 times a day, Volt costs you 0.2 seconds total. Postman costs you about 100 seconds -- roughly 50 minutes per month wasted on startup alone.

### It replaces multiple tools

Volt is not just an HTTP client. It includes a test runner, a collection organizer, a mock server, a load testing tool, a proxy/traffic capture tool, a code generator (18 languages), an importer (5 formats), a documentation generator, a web UI, a terminal UI, a linter, a secrets manager, a plugin system, and support for GraphQL, WebSocket, SSE, MQTT, gRPC, Socket.IO, HTTP/2, and HTTP/3. All from one binary under 4 MB.

### It is honest about what works

Check the [Feature Status](FEATURE_STATUS.md) page. Every feature has a clear label: Stable, Tested, Beta, or Planned. We tell you what is battle-tested and what is still maturing. No asterisks, no fine print.

---

## 30-Second Demo

Here is Volt in action, from zero to tested API in four commands.

**Step 1: Initialize a project**

```bash
volt init
```

This creates `.voltrc` (project config), `example.volt` (a sample request), and `_env.volt` (environment variables).

**Step 2: Create a request file**

Create a file called `get-users.volt` with any text editor:

```yaml
# get-users.volt
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

That is the entire file. Plain text. No JSON nesting. No XML. Readable at a glance.

**Step 3: Run it**

```bash
volt run get-users.volt
```

You will see the response status, headers, a syntax-highlighted JSON body, and timing information.

**Step 4: Test it**

```bash
volt test get-users.volt
```

Output:

```
get-users.volt
  PASS  status equals 200
  PASS  header.content-type contains json
  PASS  $.0.name equals Leanne Graham

3 passed, 0 failed
```

That is it. Your API test is a plain text file in your repo. Commit it, push it, run it in CI. Done.

**Bonus -- one-liner requests:**

```bash
volt quick GET https://httpbin.org/get        # Quick GET request
volt quick POST :3000/users name=John age:=30  # POST JSON to localhost
```

---

## How Volt Compares

Here is an honest side-by-side comparison with other popular tools.

| | **Volt** | **curl** | **HTTPie** | **Bruno** | **Insomnia** | **Postman** |
|---|---|---|---|---|---|---|
| **Install size** | **~4 MB** | ~300 KB | ~30 MB | ~150 MB | ~470 MB | ~500 MB |
| **Startup time** | **<10 ms** | ~46 ms | ~500-2000 ms | ~800-2000 ms | ~2-4 s | ~3-8 s |
| **RAM (idle)** | **~5 MB** | ~3 MB | ~30 MB | ~80-150 MB | ~200-400 MB | ~300-800 MB |
| **Dependencies** | **0** | libcurl | Python | Electron | Electron | Electron |
| **Account required** | **No** | No | No | No | Optional | **Yes** |
| **Works offline** | **Always** | Yes | Yes | Yes | Partial | Requires login |
| **Git-native files** | **Yes** | N/A | N/A | Yes (JSON) | No | No |
| **Built-in tests** | **Yes** | No | No | No | No | Separate (Newman) |
| **CI/CD deployment** | **Copy 1 file** | N/A | pip install | npm install | npm install | npm install |
| **Data format** | **Plain text** | N/A | N/A | JSON files | JSON + DB | JSON (cloud) |
| **Code export** | **18 languages** | N/A | N/A | No | No | Limited |
| **Web UI** | **Yes (same binary)** | No | No | No | Desktop only | Desktop + Cloud |
| **Multiple protocols** | **9 protocols** | HTTP only | HTTP only | HTTP only | HTTP + GraphQL | HTTP + GraphQL |
| **Price** | **Free, forever** | Free | Free / $$ | Free / $$ | Free / $$$ | Free / $$$$ |

A few things to note:

- **curl** is the gold standard for simplicity. Volt does not replace curl for quick one-liners -- but Volt adds tests, collections, environments, and a persistent workflow that curl does not have.
- **Bruno** shares Volt's philosophy of git-native files. Bruno stores collections as JSON; Volt uses a simpler plain-text format. Bruno requires Electron; Volt is a single native binary.
- **Postman** is the most feature-rich GUI tool. If you need collaborative cloud workspaces with role-based access for a large team, Postman may still be the right choice. Volt is for developers who prefer files, git, and speed.

### Switching from another tool?

Volt can import your existing collections in one command:

```bash
volt import postman collection.json     # From Postman (v2.0/v2.1)
volt import insomnia export.json        # From Insomnia
volt import openapi spec.yaml           # From OpenAPI / Swagger
volt import curl 'curl -X POST ...'     # From a cURL command
volt import har recording.har           # From HAR files
```

Your collections become plain text `.volt` files. One command, and you are migrated.

---

## What Can Volt Do?

Here is a quick overview of everything packed into that tiny binary.

### Requests and Collections

```bash
volt run request.volt               # Execute a request
volt run api/                       # Run all requests in a directory
volt quick POST :3000/users name=Jo # HTTPie-style one-liners
volt collection api/                # Run ordered collection with variable chaining
volt mock api/ --port 3000          # Spin up a mock server from .volt files
volt bench api/health.volt -n 1000  # Load test with 1000 requests
```

### Testing

```bash
volt test api/                      # Run all tests
volt test --watch                   # Re-run on file changes
volt test --data users.csv          # Data-driven testing
volt test --report junit -o out.xml # JUnit XML for CI
volt test --report html -o out.html # HTML report
```

### Protocols Beyond HTTP

```bash
volt graphql query.volt             # GraphQL queries and mutations
volt ws wss://echo.websocket.org    # WebSocket connections
volt sse https://api.example.com/e  # Server-Sent Events
volt mqtt broker:1883 sub topic     # MQTT subscribe
volt sio http://localhost:3000      # Socket.IO client
```

### Import, Export, and Generate

```bash
volt import postman collection.json # Import from 5 formats
volt export python request.volt     # Export to 18 languages
volt docs api/ --format html        # Generate API documentation
volt design spec.json generate      # Generate .volt files from OpenAPI
```

### Security

```bash
volt secrets keygen                 # Generate encryption key
volt secrets encrypt file.volt KEY  # Encrypt secrets for safe git commits
volt secrets detect file.volt       # Scan for accidentally exposed secrets
volt login github                   # OAuth 2.0 with PKCE
```

### Developer Tools

```bash
volt watch api/ --test              # Watch mode (re-run tests on save)
volt diff a.volt b.volt             # Diff two requests or responses
volt history list                   # View request history
volt replay 0 --verbose             # Replay and diff against previous response
volt search users --tree            # Search collections
volt proxy --port 8080              # Capture HTTP traffic as .volt files
volt validate file.volt --schema s  # Validate against JSON Schema
volt plugin list                    # Manage plugins
volt ci                             # Auto-detect CI environment
```

### User Interfaces

```bash
volt                                # Terminal UI (TUI) with vim keybindings
volt ui                             # Web UI in your browser (no Electron)
volt serve --port 8080              # Self-hosted Web UI for teams
```

---

## Installing Volt

Getting started takes about 10 seconds.

**Linux / macOS:**

```bash
curl -fsSL https://raw.githubusercontent.com/volt-api/volt/main/scripts/install.sh | bash
```

**Homebrew:**

```bash
brew install volt-api/volt/volt
```

**Windows (Scoop):**

```powershell
scoop bucket add volt https://github.com/volt-api/scoop-volt
scoop install volt
```

**Manual download:**

Grab the binary for your platform from the [GitHub Releases](https://github.com/volt-api/volt/releases/latest) page. It is a single file -- just put it somewhere on your PATH.

**Build from source** (requires [Zig 0.14.1](https://ziglang.org/download/)):

```bash
git clone https://github.com/volt-api/volt.git && cd volt
zig build -Doptimize=ReleaseFast
# Binary at ./zig-out/bin/volt
```

Verify it works:

```bash
volt version
```

Head to the [Getting Started](getting-started.md) guide for a full walkthrough.

---

## Community and Links

Volt is open source under the [MIT License](https://github.com/volt-api/volt/blob/main/LICENSE).

| | |
|---|---|
| **GitHub** | [github.com/volt-api/volt](https://github.com/volt-api/volt) -- source code, issues, discussions |
| **Releases** | [Latest release](https://github.com/volt-api/volt/releases/latest) -- pre-built binaries for all platforms |
| **Contributing** | [CONTRIBUTING.md](https://github.com/volt-api/volt/blob/main/CONTRIBUTING.md) -- how to contribute, run tests, submit PRs |
| **Feature Status** | [Feature Status](FEATURE_STATUS.md) -- honest assessment of every feature |
| **Bug Reports** | [Open an issue](https://github.com/volt-api/volt/issues/new) -- we read every one |

### Getting Help

- Browse the documentation pages linked in the [Quick Navigation](#quick-navigation) above
- Search [existing issues](https://github.com/volt-api/volt/issues) -- someone may have already asked
- Open a [new issue](https://github.com/volt-api/volt/issues/new) with details about what you are trying to do

### Contributing

Volt is written in Zig and has zero external dependencies. To run the test suite:

```bash
git clone https://github.com/volt-api/volt.git
cd volt
zig build test
```

All 615+ tests must pass before submitting a pull request. See [CONTRIBUTING.md](https://github.com/volt-api/volt/blob/main/CONTRIBUTING.md) for the full guide.

---

**Ready to get started?** Head to the [Getting Started](getting-started.md) guide and send your first request in under a minute.
