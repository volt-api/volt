# Launch-Schedule Smoke Tests

This folder contains lightweight fixtures used to validate Volt's core features.

## Prerequisites

- Zig 0.14.1 (0.15+ is not compatible)
- Python 3 (for the local test server)

## Quick run (Windows / Git Bash)

From the repo root:

```bash
# 1. Build Volt
zig build

# 2. Start the test server
python tests/launch-schedule/server/test_server.py --port 8787 &
SERVER_PID=$!
sleep 1

# 3. Variable chaining — tests that 01-login.volt extracts a token
#    and 02-me.volt uses {{token}} via shared EnvManager
./zig-out/bin/volt.exe test tests/launch-schedule/fixtures/chain/

# 4. Collection runner (same chain, via `run`)
./zig-out/bin/volt.exe run tests/launch-schedule/fixtures/chain/

# 5. Response types
./zig-out/bin/volt.exe run tests/launch-schedule/fixtures/response-types/html.volt
./zig-out/bin/volt.exe run tests/launch-schedule/fixtures/response-types/xml.volt

# 6. Large response (6 MB JSON)
./zig-out/bin/volt.exe run tests/launch-schedule/fixtures/large-response.volt

# 7. Import/export
./zig-out/bin/volt.exe import postman tests/launch-schedule/fixtures/postman/postman-v2.0-collection.json
./zig-out/bin/volt.exe import openapi tests/launch-schedule/fixtures/openapi/openapi-min.json

# 8. Search (scans .volt files — no longer returns empty)
./zig-out/bin/volt.exe search login --dir tests/launch-schedule/fixtures/chain/
./zig-out/bin/volt.exe search login --dir tests/launch-schedule/fixtures/chain/ --stats
./zig-out/bin/volt.exe search login --dir tests/launch-schedule/fixtures/chain/ --tree

# 9. Export to multiple languages
./zig-out/bin/volt.exe export curl   tests/launch-schedule/fixtures/chain/01-login.volt
./zig-out/bin/volt.exe export python tests/launch-schedule/fixtures/chain/01-login.volt
./zig-out/bin/volt.exe export java   tests/launch-schedule/fixtures/chain/01-login.volt

# 10. Offline features (no server needed)
./zig-out/bin/volt.exe lint     tests/launch-schedule/fixtures/chain/01-login.volt
./zig-out/bin/volt.exe validate tests/launch-schedule/fixtures/chain/01-login.volt
./zig-out/bin/volt.exe docs     tests/launch-schedule/fixtures/chain/01-login.volt
./zig-out/bin/volt.exe completions bash
./zig-out/bin/volt.exe version

# 11. Replay & history
./zig-out/bin/volt.exe replay list
./zig-out/bin/volt.exe history

# 12. Secrets detection
./zig-out/bin/volt.exe secrets detect tests/launch-schedule/fixtures/secrets/secrets-example.volt

# Cleanup
kill $SERVER_PID
```

## Fixture structure

```
fixtures/
  chain/
    01-login.volt          POST /login, extracts token via post_script
    02-me.volt             GET /me with bearer {{token}} (chained)
  response-types/
    html.volt              HTML response rendering
    xml.volt               XML response rendering
    binary.volt            Binary response handling
  large-response.volt      6 MB JSON payload
  replay/
    counter.volt           Stateful counter for replay tests
  secrets/
    secrets-example.volt   Secret detection test
  postman/
    postman-v2.0-collection.json   Postman import test
  openapi/
    openapi-min.json       OpenAPI import test
```

## What the chain test validates

The `chain/` directory tests variable chaining — the most critical feature for API workflows:

1. `01-login.volt` sends `POST /login` with credentials
2. The `post_script: extract token body.token` extracts the JWT from the response
3. `02-me.volt` sends `GET /me` with `auth: { type: bearer, token: {{token}} }`
4. Both `volt test` and `volt run` share an `EnvManager` across files, so the extracted token carries forward

Expected result: **All tests pass** (both `volt test` and `volt run`).

## Notes

- The test server is purely local (`127.0.0.1`) and is only used for deterministic fixtures.
- Some features (OAuth browser flow, TUI interaction, MQTT subscribe) are inherently interactive; they're validated as "command starts / no crash" in smoke testing.
- Files prefixed with `_` (e.g., `_collection.volt`) are skipped as test targets but used for collection-level config.
