# Changelog

All notable changes to Volt will be documented in this file.

## [1.1.0] - 2026-03-07

### Added

**HTTPie Feature Parity (12 features):**
- Meaningful exit codes with `--check-status` (0=ok, 2=timeout, 4=4xx, 5=5xx, 6=conn fail, 7=TLS)
- Client certificate / mutual TLS support (`--cert`, `--cert-key`, `--ca-bundle`)
- Named sessions (`--session=<name>`) — persist headers, cookies, and auth per host
- Download mode with progress bar (`--download`, `-d`) with resume support (`--continue`)
- HTTPie-style shorthand syntax (`volt quick POST :3000/users name=John age:=30`)
- Smart URL defaults — `:3000/path` expands to `http://localhost:3000/path`, auto GET/POST
- Granular output control (`--print=HBhbm`) — filter request/response headers, body, metadata
- TLS configurability (`--verify=no|yes|/path`, `--ssl=tls1.2|tls1.3`, `--ciphers=...`)
- SOCKS5 proxy support (`--proxy socks5://user:pass@host:port`)
- Streaming output (`--stream`, `-S`) — real-time chunked/SSE response rendering
- Chunked transfer encoding (`--chunked`) and request compression (`--compress`)
- Offline mode (`--offline`) — print raw HTTP request without sending

**GraphQL:**
- GraphQL subscriptions over WebSocket
- GraphQL autocomplete and schema-aware query building

**TUI Improvements:**
- Tabbed interface (`Ctrl+T` new, `Ctrl+W` close, `Alt+1-9` switch)
- Lazy rendering for large responses — only renders visible lines
- Split-pane layout with collection tree browser
- Tab persistence across sessions

**New Modules:**
- `session.zig` — Named session management with JSON persistence (5 tests)
- `download.zig` — Download mode with progress bar and resume (5 tests)
- `quick.zig` — HTTPie-style shorthand request parser (14 tests)
- `jwt.zig` — JWT token decoding, expiry checking, claim validation (13 tests)
- `xpath.zig` — XPath query engine for XML/HTML responses (16 tests)

**Other:**
- OS-native file watchers (inotify, kqueue, ReadDirectoryChanges) with poll fallback
- OAuth 2.0 token auto-refresh
- Concurrent bench requests with percentile stats (p50/p95/p99)
- HTTPS proxy interception via CONNECT tunneling
- Plugin sandboxed execution with timeout control
- Additional color themes (gruvbox, catppuccin)
- GitHub Sponsors funding configuration
- `yaml_to_json.zig` — YAML-to-JSON converter for OpenAPI spec import (9 tests)
- OpenAPI import now supports both JSON and YAML specs
- `volt export openapi <dir>` — export combined OpenAPI spec from a directory of .volt files
- `volt lint <file.volt>` — lint a single .volt file (previously directories only)
- Collection runner recurses into subdirectories (e.g. `01-auth/`, `02-data/`)
- cURL import `--output` accepts directories (auto-generates `imported.volt`)
- Share serialization infers body_type (json/xml/raw) from body content

### Fixed
- Response header memory safety — headers no longer reference stack-allocated buffer after `execute()` returns
- Session directory creation error handling (was silently swallowing errors)
- Postman import handles 50MB+ collections without memory issues
- 151 silent `catch {}` blocks replaced with proper error logging across 19 modules
- OpenAPI import no longer silently returns 0 endpoints for YAML specs
- `_env.volt` now loads correctly in both YAML-like and INI-style formats
- `volt env get` correctly resolves variable values
- `volt plugin init` creates directory and plugin.json scaffold
- Collection headers from `_collection.volt` properly inherited by requests

### Changed
- Module count: 56 → 78
- Test count: 366 → 816
- Lines of code: 31K → 50K+

## [1.0.1] - 2026-02-15

### Fixed
- `volt init` generated malformed .volt template (missing `method:`/`url:` keys)
- Use-after-free in config loader (string slices pointed to freed buffer)
- Dynamic variable interpolation in request body
- Collection auth inheritance causing 400 errors
- `volt lint` now skips `_`-prefixed files (env/config files)
- Default User-Agent updated from `Volt/0.2.0` to `Volt/1.0.0`

## [1.0.0] - 2026-02-14

Initial release. 56 modules, 31K lines of Zig, 366 tests.
