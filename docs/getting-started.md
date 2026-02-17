# Getting Started with Volt

Volt is a fast, git-native API development toolkit. Single binary, zero dependencies, works 100% offline.

---

## Install

**macOS (Homebrew):**

```bash
brew install volt-api/volt/volt
```

**Linux / macOS (script):**

```bash
curl -fsSL https://raw.githubusercontent.com/volt-api/volt/main/scripts/install.sh | bash
```

**Windows (Scoop):**

```powershell
scoop bucket add volt https://github.com/volt-api/scoop-volt
scoop install volt
```

**Manual download:**

Download the binary for your platform from [GitHub Releases](https://github.com/volt-api/volt/releases/latest), make it executable, and move it to your PATH.

**Build from source (requires Zig 0.13+):**

```bash
git clone https://github.com/volt-api/volt.git
cd volt
zig build -Doptimize=ReleaseFast
# Binary at ./zig-out/bin/volt
```

Verify the installation:

```bash
volt version
```

---

## Your first request

Create a file called `hello.volt`:

```yaml
name: Hello World
method: GET
url: https://httpbin.org/get
headers:
  - Accept: application/json
tests:
  - status equals 200
```

Run it:

```bash
volt run hello.volt
```

You'll see the response status, headers, body, and timing.

---

## Your first test

Volt has built-in test assertions. Add tests to any `.volt` file:

```yaml
name: User API
method: GET
url: https://jsonplaceholder.typicode.com/users/1
headers:
  - Accept: application/json
tests:
  - status equals 200
  - $.name equals Leanne Graham
  - $.email equals Sincere@april.biz
  - $.address.city equals Gwenborough
```

Run the tests:

```bash
volt test user-api.volt
```

Output:

```
user-api.volt
  ✓ status equals 200
  ✓ $.name equals Leanne Graham
  ✓ $.email equals Sincere@april.biz
  ✓ $.address.city equals Gwenborough

4 passed, 0 failed
```

Run all tests in a directory:

```bash
volt test examples/
```

---

## Initialize a project

```bash
mkdir my-api && cd my-api
volt init
```

This creates:
- `.voltrc` — project configuration (base URL, timeout, default headers)
- `example.volt` — a sample request to get you started
- `_env.volt` — environment variables (development, staging, production)

---

## POST requests with a body

```yaml
name: Create Post
method: POST
url: https://jsonplaceholder.typicode.com/posts
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "title": "Hello from Volt",
      "body": "Sent using Volt",
      "userId": 1
    }
tests:
  - status equals 201
  - body contains title
```

---

## Authentication

**Bearer token:**

```yaml
method: GET
url: https://api.example.com/me
auth:
  type: bearer
  token: your-token-here
```

**Basic auth:**

```yaml
method: GET
url: https://api.example.com/me
auth:
  type: basic
  username: myuser
  password: mypass
```

**API key:**

```yaml
method: GET
url: https://api.example.com/data
auth:
  type: api_key
  key_name: X-Api-Key
  key_value: your-key-here
  key_location: header
```

---

## Environment variables

Create `_env.volt` in your project:

```ini
[default]
base_url = https://api.example.com
api_key = dev-key-123

[staging]
base_url = https://staging.api.example.com
api_key = staging-key-456

[production]
base_url = https://api.example.com
api_key = prod-key-789
```

Reference variables in `.volt` files with `{{variable}}`:

```yaml
method: GET
url: {{base_url}}/users
auth:
  type: api_key
  key_name: X-Api-Key
  key_value: {{api_key}}
  key_location: header
```

Switch environments:

```bash
volt run request.volt --env staging
```

---

## Collections

Organize requests into directories. Each directory is a collection:

```
my-api/
  _collection.volt     # Shared config (inherited auth, headers)
  _env.volt            # Environment variables
  01-health.volt
  02-list-users.volt
  03-create-user.volt
```

Run the entire collection in order:

```bash
volt collection my-api/
```

---

## Import from Postman

```bash
volt import postman my-collection.json
```

This converts your Postman collection (v2.0 and v2.1) to `.volt` files, including auth, headers, body, scripts, and folder structure.

Also supports: `volt import curl`, `volt import openapi`, `volt import insomnia`, `volt import har`.

---

## Export to other languages

```bash
volt export curl request.volt
volt export python request.volt
volt export javascript request.volt
volt export go request.volt
volt export rust request.volt
```

15+ languages supported: curl, python, javascript, go, ruby, php, csharp, rust, java, swift, kotlin, dart, httpie, wget, powershell.

---

## CI/CD integration

Generate JUnit XML reports for CI pipelines:

```bash
volt test --report junit -o results.xml
```

Or let Volt auto-detect your CI environment:

```bash
volt ci
```

Volt detects GitHub Actions, GitLab CI, Jenkins, Azure DevOps, CircleCI, Travis CI, and Bitbucket Pipelines — and outputs the appropriate format automatically.

**GitHub Actions example:**

```yaml
- name: Run API tests
  run: |
    volt test api/ --report junit -o test-results.xml
```

---

## Data-driven testing

Run the same request with multiple inputs from a CSV or JSON file:

`test-data.csv`:
```csv
title,body,userId
First Post,This is test one,1
Second Post,This is test two,2
```

`template.volt`:
```yaml
method: POST
url: https://jsonplaceholder.typicode.com/posts
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "title": "{{title}}",
      "body": "{{body}}",
      "userId": {{userId}}
    }
tests:
  - status equals 201
```

```bash
volt test template.volt --data test-data.csv
```

---

## Web UI

Volt includes a browser-based UI served from the same binary:

```bash
volt ui                    # Opens browser to localhost:8080
volt ui --port 3000        # Custom port
```

For team access on a local network:

```bash
volt serve --port 8080     # Binds to 0.0.0.0
```

No Electron. No install. Just your browser and a 3.9 MB binary.

---

## TUI (Terminal UI)

Launch the interactive terminal interface:

```bash
volt
```

Key bindings:
- `Tab` / `h`, `l` — switch panes
- `j`, `k` / arrows — navigate
- `Enter` — send request / open file
- `i` — edit mode (URL editing)
- `m` — cycle HTTP method
- `Ctrl+T` — new tab, `Ctrl+W` — close tab
- `Alt+1`-`Alt+9` — switch tabs
- `/` — search collections
- `Ctrl+F` — search response
- `:w` — save, `:q` — quit

---

## What's next

- [Command Reference](commands.md) — every CLI command with examples
- [.volt File Format](volt-file-format.md) — complete format specification
- [Examples](https://github.com/volt-api/volt/tree/main/examples) — ready-to-run example files
