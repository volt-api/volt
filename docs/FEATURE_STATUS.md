# Volt Feature Status

Honest assessment of every feature. Last updated: Feb 17, 2026.

**56 core modules** | **31K+ lines of Zig** | **366+ unit tests** | **0 failures**

---

## Status Legend

- **Stable** — Unit tested + used in real workflows. Ship with confidence.
- **Tested** — Unit tested, not yet battle-tested against real services. May have edge cases.
- **Beta** — Implemented but known limitations. Works for common cases, may fail on edge cases.
- **Planned** — Not yet implemented.

---

## Core Features — Stable

These features are thoroughly tested and form the backbone of Volt.

| Feature | Module | Tests | CLI Command | Notes |
|---------|--------|-------|-------------|-------|
| .volt file parsing | `volt_file.zig` | 20+ | `volt run` | Handles all field types, auth, tests, scripts, tags |
| HTTP client (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS) | `http_client.zig` | 11 | `volt run` | Redirects, timeouts, large responses, binary detection |
| Environment variables | `environment.zig` | 10 | `volt env` | Scoped resolution (request → runtime → env → global) |
| Test assertions | `volt_file.zig` | — | `volt test` | status, body, headers, JSONPath assertions |
| Collection runner | `collection_runner.zig` | — | `volt collection` | Sequential execution, variable propagation |
| Postman import | `importer.zig` | 30 | `volt import postman` | v2.0+v2.1, OAuth2 auth, scripts, formdata, graceful errors |
| cURL import | `curl_import.zig` | — | `volt import curl` | Headers, body, method, auth |
| Export (15+ languages) | `exporter.zig` | — | `volt export` | curl, python, javascript, go, ruby, php, csharp, rust, java, swift, kotlin, dart, httpie, wget, powershell |
| Config (.voltrc) | `config.zig` | — | `volt init` | base_url, timeout, theme, headers, output format |
| History | `history.zig` | — | `volt history` | Per-session request history |
| Test reports | `test_report.zig` | — | `volt test --report` | JUnit XML, HTML, JSON |
| Data-driven testing | `data_driver.zig` | — | `volt test --data` | CSV and JSON data sources |
| Formatter | `formatter.zig` | — | `volt lint` | .volt file validation |
| Dynamic variables | `dynamic_vars.zig` | — | built-in | `$timestamp`, `$uuid`, `$randomInt`, `$isoDate`, etc. |
| Retry with backoff | `retry.zig` | — | `volt run --retry` | Constant, linear, exponential strategies |
| Color themes | `themes.zig` | 7 | `volt theme` | dark, light, solarized, nord, dracula, monokai, none |
| Shell completions | `completions.zig` | — | `volt completions` | bash, zsh, fish, PowerShell |
| Diff engine | `diff_engine.zig` | — | `volt diff` | .volt file and response comparison |
| Snippet library | `snippet.zig` | — | built-in | Common request templates |
| Response viewer | `response_viewer.zig` | 28 | built-in | HTML-to-text, XML highlighting, timing waterfall, file type detection |
| Collection organizer | `collection_organizer.zig` | 15 | `volt search` | Tree view, tag search, weighted search, stats |
| CI auto-detection | `ci.zig` | 16 | `volt ci` | GitHub Actions, GitLab CI, Jenkins, Azure, CircleCI, Travis, Bitbucket |

## Protocol Support — Tested

Unit tests pass. Protocol implementations are correct per spec. Not yet battle-tested against real services.

| Feature | Module | Tests | CLI Command | Known Limitations |
|---------|--------|-------|-------------|-------------------|
| GraphQL queries | `graphql.zig` | 6 | `volt graphql` | Introspection parsing, schema validation. Subscriptions not yet supported. |
| WebSocket | `ws.zig` | — | `volt ws` | Frame building correct. Needs testing against real WebSocket servers. |
| SSE (Server-Sent Events) | `sse.zig` | — | `volt sse` | Event parsing correct. Needs testing against real SSE endpoints. |
| MQTT (v3.1.1) | `mqtt.zig` | 9 | `volt mqtt` | CONNECT/PUBLISH/SUBSCRIBE packet building. QoS 0/1/2. Needs real broker test. |
| Socket.IO (v4/v5) | `socketio.zig` | 9 | `volt sio` | Engine.IO + Socket.IO encoding/decoding. Needs real server test. |
| gRPC | `grpc.zig` | — | `volt grpc` | Proto file parsing, .volt generation. Needs real gRPC service test. |

## Security & Auth — Tested

| Feature | Module | Tests | CLI Command | Known Limitations |
|---------|--------|-------|-------------|-------------------|
| Bearer / Basic / API Key auth | `volt_file.zig` | — | built-in | Works in HTTP requests. |
| OAuth 2.0 with PKCE | `oauth_flow.zig` | 21 | `volt login` | PKCE generation, auth URL, token storage all tested. Live callback server (localhost listener) needs battle testing. |
| E2E encrypted secrets | `secrets.zig` | 10 | `volt secrets` | XOR + base64 encryption. Keygen, encrypt, decrypt, detect all working. |
| Request signing (HMAC) | `signing.zig` | — | `volt run --sign` | HMAC-SHA256 signing. AWS SigV4 not yet implemented. |
| Cookie persistence | `cookie_jar.zig` | — | built-in | Parse Set-Cookie, build Cookie header. Domain/path filtering simplified. |

## Developer Tools — Tested

| Feature | Module | Tests | CLI Command | Known Limitations |
|---------|--------|-------|-------------|-------------------|
| Mock server | `mock_server.zig` | 3 | `volt mock` | Loads .volt files as routes. Single-threaded. |
| Load testing / bench | `bench.zig` | — | `volt bench` | Sequential requests with timing. No true concurrency (Zig stdlib limitation). |
| Proxy / traffic capture | `proxy.zig` | 10 | `volt proxy` | HTTP capture to .volt files. HTTPS interception not supported. |
| Watch mode | `watch.zig` | 6 | `volt watch` | Poll-based file watching. No OS-native watchers yet. |
| History replay | `replay.zig` | 15 | `volt replay` | JSON field-level diff, header comparison. |
| Request sharing | `share.zig` | 9 | `volt share` | base64, cURL, URL formats. |
| Plugin system | `plugin.zig` | 11 | `volt plugin` | JSON stdin/stdout protocol. Plugin install from URL not yet implemented. |
| API docs generation | `doc_generator.zig` | — | `volt docs` | Markdown and HTML output from .volt files. |
| Schema validation | `validator.zig` | — | `volt validate` | JSON Schema validation + inference. |
| OpenAPI design-first | `openapi_designer.zig` | 10 | `volt design` | Spec parsing, .volt generation, response validation. |
| HAR export/import | `har.zig` | — | `volt har` | HAR 1.2 format. |
| Workflow engine | `workflow.zig` | — | `volt workflow` | Multi-step request chaining. |

## Web UI — Tested

| Feature | Module | Tests | CLI Command | Known Limitations |
|---------|--------|-------|-------------|-------------------|
| Web server | `web_server.zig` | 6 | `volt ui` / `volt serve` | Embedded HTTP server, static files via @embedFile |
| Web API | `web_api.zig` | 11 | (internal) | JSON API wrapping all core modules |
| Frontend SPA | `web/` | — | browser | Vanilla JS, 7 themes, request builder, response viewer |

`volt ui` opens browser on localhost (local development). `volt serve` binds 0.0.0.0 (self-hosted team access).

## Beta Features

These have known limitations that may affect some users.

| Feature | Status | Limitation |
|---------|--------|------------|
| HTTP/2 | Frame building + HPACK + stream management complete (975 lines, 15 tests). **TLS ALPN negotiation not implemented** — Zig stdlib doesn't expose TLS extension hooks. h2c (cleartext) upgrade also pending. |
| OAuth browser flow | Auth URL + PKCE + token exchange tested. **Live callback server** (binding localhost port for browser redirect) generates URL but doesn't yet start the HTTP listener automatically. |
| gRPC over HTTP/2 | Proto parsing and .volt generation work. **Actual gRPC calls** depend on HTTP/2 over TLS (see above). |
| Concurrency in bench | `volt bench` runs requests sequentially. True concurrent load testing requires Zig async or thread pool. |

## Planned Features

| Feature | Target | Notes |
|---------|--------|-------|
| HTTP/3 (QUIC) | 2027 | Future-proofing. First API client with native HTTP/3 would be a differentiator. |
| GraphQL subscriptions | 2026 Q4 | WebSocket-based. Requires stable WebSocket client. |
| OS-native file watchers | 2026 Q3 | inotify (Linux), kqueue (macOS), ReadDirectoryChanges (Windows). Currently poll-based. |
| Plugin install from URL | 2026 Q3 | `volt plugin install <url>` — download and register plugins. |
| VS Code extension | Deprioritized | Web UI (`volt ui`) covers the GUI use case. May revisit later. |

---

## How We Test

- **Unit tests**: 366+ tests across 56 modules. Run via `zig build test`.
- **Manual testing**: CLI commands tested against real services during development.
- **Integration**: `volt init && volt run example.volt && volt test example.volt` verified end-to-end.
- **Import testing**: Postman v2.0 and v2.1 collections tested with real exports.

To run all tests yourself:

```
zig build test
```
