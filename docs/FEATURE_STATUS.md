# Volt Feature Status

Honest assessment of every feature. Last updated: Feb 21, 2026.

**78 core modules** | **50,000+ lines of Zig** | **816 unit tests** | **0 failures**

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
| HTTP client (GET/POST/PUT/PATCH/DELETE/HEAD/OPTIONS) | `http_client.zig` | 15 | `volt run` | Redirects, timeouts, large responses, binary detection, streaming, chunked transfer |
| Environment variables | `environment.zig` | 10 | `volt env` | Scoped resolution (request → runtime → collection → env → global) |
| Test assertions | `volt_file.zig` | — | `volt test` | status, body, headers, JSONPath assertions |
| Collection runner | `collection_runner.zig` | 1 | `volt collection` | Sequential execution, variable propagation, request chaining |
| Postman import | `importer.zig` | 36 | `volt import postman` | v2.0+v2.1, OAuth2 auth, scripts, formdata, large collections, graceful errors |
| cURL import | `curl_import.zig` | 3 | `volt import curl` | Headers, body, method, auth |
| Insomnia import | `insomnia_import.zig` | — | `volt import insomnia` | Insomnia export format support |
| Export (15+ languages) | `exporter.zig` | 3 | `volt export` | curl, python, javascript, go, ruby, php, csharp, rust, java, swift, kotlin, dart, httpie, wget, powershell |
| Config (.voltrc) | `config.zig` | 3 | `volt init` | base_url, timeout, theme, headers, output format, TLS settings, session config |
| History | `history.zig` | 5 | `volt history` | Per-session request history |
| Test reports | `test_report.zig` | 2 | `volt test --report` | JUnit XML, HTML, JSON |
| Data-driven testing | `data_driver.zig` | 3 | `volt test --data` | CSV and JSON data sources |
| Formatter | `formatter.zig` | 4 | `volt lint` | .volt file validation |
| Dynamic variables | `dynamic_vars.zig` | 3 | built-in | `$timestamp`, `$uuid`, `$randomInt`, `$isoDate`, etc. |
| Retry with backoff | `retry.zig` | 3 | `volt run --retry` | Constant, linear, exponential strategies |
| Color themes | `themes.zig` | 8 | `volt theme` | dark, light, solarized, nord, dracula, monokai, gruvbox, catppuccin, none |
| Shell completions | `completions.zig` | 2 | `volt completions` | bash, zsh, fish, PowerShell |
| Diff engine | `diff_engine.zig` | 3 | `volt diff` | .volt file and response comparison |
| Snippet library | `snippet.zig` | 3 | built-in | Common request templates |
| Response viewer | `response_viewer.zig` | 33 | built-in | HTML-to-text, XML highlighting, XPath queries, timing waterfall, file type detection |
| Collection organizer | `collection_organizer.zig` | 15 | `volt search` | Tree view, tag search, weighted search, stats |
| CI auto-detection | `ci.zig` | 16 | `volt ci` | GitHub Actions, GitLab CI, Jenkins, Azure, CircleCI, Travis, Bitbucket |
| JWT decode/inspect | `jwt.zig` | 13 | built-in | Header/payload decoding, expiry checking, claim validation |
| XPath queries | `xpath.zig` | 16 | built-in | XML/HTML response querying with XPath expressions |

## HTTPie Feature Parity — Tested

Full HTTPie-compatible feature set. All tested against live endpoints.

| Feature | Module | Tests | CLI Flag | Notes |
|---------|--------|-------|----------|-------|
| Meaningful exit codes | `main.zig` | — | `--check-status` | 0=ok, 2=timeout, 4=4xx, 5=5xx, 6=conn fail, 7=TLS |
| Client certificates / mTLS | `http_client.zig` | — | `--cert`, `--cert-key`, `--ca-bundle` | Mutual TLS authentication |
| Named sessions | `session.zig` | 5 | `--session=<name>` | Persist headers/cookies/auth across requests per host |
| Download with progress bar | `download.zig` | 5 | `--download`, `-d` | Content-Disposition filename, resume with `--continue` |
| HTTPie-style shorthand | `quick.zig` | 14 | `volt quick` | `field=val` (JSON), `field:=raw`, `param==val` (query), `Header:Val` |
| Smart URL defaults | `quick.zig` | — | `volt quick :3000/path` | Localhost shorthand, auto method (GET/POST), auto JSON headers |
| Granular output control | `main.zig` | — | `--print=HBhbm` | H=req headers, B=req body, h=resp headers, b=resp body, m=metadata |
| TLS configurability | `http_client.zig` | — | `--verify`, `--ssl`, `--ciphers` | Pin TLS version, custom CA, disable verification |
| SOCKS proxy | `http_client.zig` | — | `--proxy socks5://...` | SOCKS5 handshake with optional auth |
| Streaming output | `http_client.zig` | — | `--stream`, `-S` | Real-time chunked/SSE output, auto-detect `text/event-stream` |
| Chunked transfer + compression | `http_client.zig` | — | `--chunked`, `--compress` | Transfer-Encoding: chunked, Content-Encoding: deflate |
| Offline mode | `main.zig` | — | `--offline` | Print raw HTTP request without sending |

## Protocol Support — Tested

| Feature | Module | Tests | CLI Command | Notes |
|---------|--------|-------|-------------|-------|
| HTTP/2 | `h2.zig` | 26 | built-in | Frame building, HPACK compression, stream management, TLS ALPN negotiation, h2c cleartext upgrade |
| HTTP/3 (QUIC) | `h3.zig` + `quic/` | 65+ | `--http3` | Full H3 framing + real QUIC transport over UDP. TLS 1.3 handshake (X25519 + AES-128-GCM), AEAD packet protection, header protection (short/long), QPACK compression, stream management, per-stream offsets, ACK generation, FIN tracking, Server Finished HMAC verification, ECDSA P-256 CertificateVerify signature verification, X.509 DER parsing, DNS resolution for hostnames, coalesced packet handling, content-length body completion, socket timeouts, 64KB recv buffer. |
| GraphQL queries + subscriptions | `graphql.zig` | 31 | `volt graphql` | Introspection, schema validation, autocomplete, schema caching with TTL, WebSocket subscriptions |
| WebSocket | `ws.zig` | 3 | `volt ws` | Frame building correct. Needs testing against real WebSocket servers. |
| SSE (Server-Sent Events) | `sse.zig` | 3 | `volt sse` | Event parsing correct. Needs testing against real SSE endpoints. |
| MQTT (v3.1.1) | `mqtt.zig` | 9 | `volt mqtt` | CONNECT/PUBLISH/SUBSCRIBE packet building. QoS 0/1/2. Needs real broker test. |
| Socket.IO (v4/v5) | `socketio.zig` | 9 | `volt sio` | Engine.IO + Socket.IO encoding/decoding. Needs real server test. |
| gRPC | `grpc.zig` | 4 | `volt grpc` | Proto file parsing, .volt generation. Needs real gRPC service test. |

## Security & Auth — Tested

| Feature | Module | Tests | CLI Command | Notes |
|---------|--------|-------|-------------|-------|
| Bearer / Basic / API Key / Digest auth | `volt_file.zig` | — | built-in | All common auth methods supported in HTTP requests. |
| OAuth 2.0 with PKCE | `oauth_flow.zig` | 39 | `volt login` | PKCE generation, auth URL, live callback server, token storage, auto-refresh. |
| OAuth 2.0 (Client Credentials) | `oauth_flow.zig` | — | built-in | `grant_type=client_credentials` flow. |
| OAuth 2.0 (Password) | `oauth_flow.zig` | — | built-in | `grant_type=password` flow. |
| OAuth 2.0 (Implicit) | `oauth_flow.zig` | — | built-in | `response_type=token` URL builder. |
| AWS SigV4 authentication | `aws_auth.zig` | 13 | built-in | Full AWS Signature Version 4: canonical request, derived signing key, HMAC-SHA256. |
| Hawk authentication | `hawk_auth.zig` | 10 | built-in | Hawk auth header with timestamp, nonce, MAC, payload hash. |
| E2E encrypted secrets | `secrets.zig` | 10 | `volt secrets` | Keygen, encrypt, decrypt, detect. Safe for git commits. |
| Request signing (HMAC) | `signing.zig` | 7 | `volt run --sign` | HMAC-SHA256 signing. |
| Cookie persistence | `cookie_jar.zig` | 3 | built-in | Parse Set-Cookie, build Cookie header. Domain/path filtering. |

## Team & Collaboration — Tested

| Feature | Module | Tests | CLI Command | Notes |
|---------|--------|-------|-------------|-------|
| Team workspaces + RBAC | `collaboration.zig` | 9 | built-in | Owner/editor/viewer roles, workspace manager, member invitations, activity logging. |
| Team secrets vault | `team_secrets.zig` | 6 | built-in | Encrypted shared secrets with vault management. |
| CI dashboard | `ci_dashboard.zig` | 5 | built-in | Test run tracking, trend analysis, pass/fail history. |
| Pre/post scripting engine | `script_engine.zig` | 15 | built-in | `env.set`, `env.get`, `extract` (JSONPath), `assert.status`, `assert.json`, `base64.encode`, `timestamp`, `sleep`, named test blocks. |

## Developer Tools — Tested

| Feature | Module | Tests | CLI Command | Notes |
|---------|--------|-------|-------------|-------|
| Mock server | `mock_server.zig` | 3 | `volt mock` | Loads .volt files as routes. Single-threaded. |
| Load testing / bench | `bench.zig` | 3 | `volt bench` | Concurrent requests with thread pool. Percentile stats (p50/p95/p99). |
| Proxy / traffic capture | `proxy.zig` | 19 | `volt proxy` | HTTP/HTTPS capture to .volt files. CONNECT tunnel support. Auto test generation. |
| Watch mode | `watch.zig` | 9 | `volt watch` | OS-native file watchers (inotify/kqueue/ReadDirectoryChanges) with poll fallback. |
| History replay | `replay.zig` | 15 | `volt replay` | JSON field-level diff, header comparison, ANSI-colored output. |
| Request sharing | `share.zig` | 9 | `volt share` | base64, cURL, URL formats. |
| Plugin system | `plugin.zig` | 14 | `volt plugin` | JSON stdin/stdout protocol. Install/uninstall from local path. Sandboxed execution, timeout control. |
| API docs generation | `doc_generator.zig` | 2 | `volt docs` | Markdown and HTML output from .volt files. |
| Schema validation | `validator.zig` | 4 | `volt validate` | JSON Schema validation + inference. |
| OpenAPI design-first | `openapi_designer.zig` | 10 | `volt design` | Spec parsing, .volt generation, response validation. |
| HAR export/import | `har.zig` | 2 | `volt har` | HAR 1.2 format. |
| Workflow engine | `workflow.zig` | 3 | `volt workflow` | Multi-step request chaining. |

## TUI (Terminal UI) — Tested

| Feature | Module | Tests | Notes |
|---------|--------|-------|-------|
| Split-pane layout | `app.zig` | — | Request list + response viewer, vim keybindings |
| Tabbed interface | `app.zig` | — | `Ctrl+T` new tab, `Ctrl+W` close, `Alt+1-9` switch, `gt`/`gT` vim-style |
| Response search | `app.zig` | — | `Ctrl+F` in response pane, `n`/`N` for next/prev match |
| Split-view comparison | `app.zig` | — | `Ctrl+S` toggle dual-column response view |
| JSONPath filtering | `app.zig` | — | `$.key`, `$.array[0]`, `$.key[*]` wildcard |
| Lazy rendering | `app.zig` | — | Only renders visible lines — handles large responses without lag |
| Collection tree browser | `app.zig` | — | Browse and run .volt files, `/` search with weighted scoring |
| Tab persistence | `app.zig` | — | Tabs survive across sessions via `.volt-session` file |

## Web UI — Tested

| Feature | Module | Tests | CLI Command | Notes |
|---------|--------|-------|-------------|-------|
| Web server | `web_server.zig` | 6 | `volt ui` / `volt serve` | Embedded HTTP server, static files via @embedFile |
| Web API | `web_api.zig` | 11 | (internal) | JSON API wrapping all core modules |
| Frontend SPA | `web/` | — | browser | Vanilla JS, 7 themes, request builder, response viewer |
| PWA offline support | `manifest.json` + `sw.js` | — | browser | Installable on desktop/mobile, cache-first strategy, offline capable |

`volt ui` opens browser on localhost (local development). `volt serve` binds 0.0.0.0 (self-hosted team access).

## Beta Features

These have known limitations that may affect some users.

| Feature | Status | Limitation |
|---------|--------|------------|
| gRPC over HTTP/2 | Proto parsing and .volt generation work. **Actual gRPC calls** depend on HTTP/2 over TLS — needs real-world testing with gRPC services. |
| Concurrency in bench | `volt bench` supports concurrent requests via thread pool. True async I/O awaiting Zig async stabilization. |

## Planned Features

| Feature | Target | Notes |
|---------|--------|-------|
| Plugin install from URL | 2026 Q3 | `volt plugin install <url>` — download and register plugins from remote sources. Local install already works. |
| VS Code extension | Deprioritized | Web UI (`volt ui`) covers the GUI use case. May revisit later. |

---

## How We Test

- **Unit tests**: 615 tests across 72 modules. Run via `zig build test`.
- **Integration tests**: 155 tests across 10 test suites (chain propagation, large imports, protocol fixtures, exports, search, replay, validation, OpenAPI import).
- **Manual testing**: CLI commands tested against real services (jsonplaceholder.typicode.com, httpbin.org).
- **Web UI testing**: Browser automation verified full SPA functionality (request/response, themes, method switching).
- **Integration**: `volt init && volt run example.volt && volt test example.volt` verified end-to-end.
- **Import testing**: Postman v2.0 and v2.1 collections tested with real exports (including 101-request collections and 50MB+ responses).
- **HTTPie parity**: All 12 HTTPie-competitive features tested against live endpoints.

To run all tests yourself:

```
zig build test
```
