# .volt File Format

The `.volt` format is a human-readable, git-friendly file format for defining API requests, tests, and configuration. Every `.volt` file is a plain text file you can edit in any text editor.

---

## Basic structure

A minimal `.volt` file:

```yaml
method: GET
url: https://api.example.com/users
```

A full request:

```yaml
name: Create User
description: Creates a new user account
method: POST
url: https://api.example.com/users
tags: users, auth, v2
timeout: 5000
headers:
  - Content-Type: application/json
  - Accept: application/json
  - X-Request-ID: {{$uuid}}
auth:
  type: bearer
  token: {{api_token}}
body:
  type: json
  content: |
    {
      "name": "Jane Doe",
      "email": "jane@example.com"
    }
pre_script: |
  log Starting create user request
  set start_time now
post_script: |
  log User created
  extract user_id body.id
tests:
  - status equals 201
  - $.id exists
  - $.name equals Jane Doe
  - header.content-type contains json
variables:
  base_url: https://api.example.com
```

---

## Fields

### Request fields

| Field | Required | Description |
|-------|----------|-------------|
| `method` | Yes | HTTP method: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` |
| `url` | Yes | Request URL. Supports `{{variable}}` interpolation. |
| `name` | No | Human-readable request name |
| `description` | No | Longer description for documentation |
| `tags` | No | Comma-separated tags for organization: `tags: auth, users, v2` |
| `timeout` | No | Per-request timeout in milliseconds |

### Headers

```yaml
headers:
  - Content-Type: application/json
  - Accept: application/json
  - Authorization: Bearer {{token}}
  - X-Custom: some-value
```

Each header is prefixed with `- ` (YAML list syntax).

### Authentication

**Bearer token:**

```yaml
auth:
  type: bearer
  token: my-secret-token
```

**Basic auth:**

```yaml
auth:
  type: basic
  username: myuser
  password: mypass
```

**API key:**

```yaml
auth:
  type: api_key
  key_name: X-Api-Key
  key_value: my-key-123
  key_location: header
```

`key_location` can be `header` (default) or `query`.

### Request body

**JSON body:**

```yaml
body:
  type: json
  content: |
    {
      "key": "value"
    }
```

**Form data:**

```yaml
body:
  type: form
  content: |
    username=john
    password=secret
```

**Raw text:**

```yaml
body:
  type: raw
  content: |
    Plain text content here
```

### Request signing

```yaml
signing:
  type: hmac-sha256
  key: your-secret-key
  headers: date host content-type
```

---

## Test assertions

Tests are defined under the `tests:` section. Each test is a line with the format:

```
- <field> <operator> <value>
```

### Fields you can test

| Field | Description | Example |
|-------|-------------|---------|
| `status` | HTTP status code | `status equals 200` |
| `body` | Response body as text | `body contains "success"` |
| `header.<name>` | Response header value | `header.content-type contains json` |
| `$.<path>` | JSONPath into response body | `$.data.id equals 123` |

### Operators

| Operator | Description | Example |
|----------|-------------|---------|
| `equals` | Exact match | `status equals 200` |
| `!=` | Not equal | `status != 404` |
| `contains` | Substring match | `body contains "users"` |
| `<` | Less than (numeric) | `status < 300` |
| `>` | Greater than (numeric) | `status > 100` |
| `exists` | Field exists (no value needed) | `$.id exists` |

### JSONPath assertions

Use `$.` prefix to test specific JSON fields in the response:

```yaml
tests:
  - $.name equals Leanne Graham
  - $.address.city equals Gwenborough
  - $.company.name equals Romaguera-Crona
  - $.id exists
  - $.email != ""
```

Array access: `$.users[0].name`, `$.data[2].id`

### Full example

```yaml
tests:
  - status equals 200
  - status < 300
  - body contains users
  - header.content-type contains application/json
  - $.data[0].name equals John
  - $.meta.total > 0
  - $.data[0].id exists
```

---

## Variables

### Template variables

Use `{{variable}}` syntax anywhere in URL, headers, body, or auth fields:

```yaml
url: {{base_url}}/users/{{user_id}}
headers:
  - Authorization: Bearer {{token}}
```

Variables are resolved from (highest priority first):
1. **Request-level** — `variables:` section in the `.volt` file
2. **Runtime** — variables set by `extract` in previous requests
3. **Environment** — `_env.volt` file
4. **Global** — `.voltrc` config

### Dynamic variables

Built-in variables that generate values on each run:

| Variable | Description | Example output |
|----------|-------------|----------------|
| `{{$uuid}}` | UUID v4 | `f47ac10b-58cc-4372-a567-0e02b2c3d479` |
| `{{$timestamp}}` | Unix timestamp | `1709472000` |
| `{{$isoDate}}` | ISO 8601 date | `2026-03-03T10:00:00Z` |
| `{{$randomInt}}` | Random integer | `42917` |

```yaml
headers:
  - X-Request-ID: {{$uuid}}
body:
  type: json
  content: |
    {
      "created_at": "{{$isoDate}}",
      "nonce": {{$randomInt}}
    }
```

### Request-level variables

Define variables local to a single file:

```yaml
variables:
  base_url: https://api.example.com
  version: v2
```

---

## Scripts

### Pre-request scripts

Run before the request is sent:

```yaml
pre_script: |
  log Starting request...
  set request_time now
```

### Post-response scripts

Run after the response is received:

```yaml
post_script: |
  log Response received
  extract user_id body.id
  extract token body.auth.token
  assert status == 200
```

### Script commands

| Command | Description |
|---------|-------------|
| `log <message>` | Print a message |
| `set <var> <value>` | Set a runtime variable |
| `extract <var> <path>` | Extract a value from the response and save as variable |
| `assert <condition>` | Assert a condition (fails the script if false) |

Extracted variables are available in subsequent requests during collection runs.

---

## Special files

### `_collection.volt`

Placed in a collection directory. Defines shared configuration inherited by all requests in that directory:

```yaml
name: My API Collection
description: Shared settings for all requests
method: GET
url: https://api.example.com
headers:
  - Accept: application/json
auth:
  type: bearer
  token: {{api_token}}
```

All requests in the same directory inherit the headers, auth, and base URL from `_collection.volt`.

### `_env.volt`

Defines environment variables. Uses INI-style sections:

```ini
[default]
base_url = https://localhost:3000
api_key = dev-key

[staging]
base_url = https://staging.example.com
api_key = staging-key

[production]
base_url = https://api.example.com
api_key = prod-key
```

### `.voltrc`

Project-level configuration file placed in the project root:

```yaml
# Base URL prepended to relative URLs
base_url: https://api.example.com

# Default request timeout (ms)
timeout: 30000

# Default headers for all requests
headers:
  - Accept: application/json
  - User-Agent: Volt/1.0.0

# Output format: pretty | compact | raw
output: pretty

# Enable colored output
color: true

# Follow redirects
follow_redirects: true
max_redirects: 10

# SSL verification
verify_ssl: true
```

---

## GraphQL requests

For GraphQL, use a regular POST `.volt` file with the query in the body:

```yaml
name: Countries Query
method: POST
url: https://countries.trevorblades.com/graphql
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {"query":"{ countries { name capital } }"}
tests:
  - status equals 200
  - body contains countries
```

Or use the dedicated GraphQL command:

```bash
volt graphql query.volt
```

---

## Data-driven testing

Pair a `.volt` template with a CSV or JSON data file:

**template.volt:**

```yaml
method: POST
url: https://api.example.com/users
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "name": "{{name}}",
      "email": "{{email}}"
    }
tests:
  - status equals 201
```

**data.csv:**

```csv
name,email
Alice,alice@example.com
Bob,bob@example.com
Charlie,charlie@example.com
```

```bash
volt test template.volt --data data.csv
```

Each row in the CSV becomes a separate test run, with `{{name}}` and `{{email}}` replaced by the row values.

---

## File naming conventions

| Pattern | Purpose |
|---------|---------|
| `*.volt` | Request files |
| `_collection.volt` | Collection config (inherited by sibling files) |
| `_env.volt` | Environment variables |
| `.voltrc` | Project configuration |
| `_`-prefixed files | Skipped by `volt lint` and `volt test` |

Files are plain text, git-diffable, and safe to commit to version control. Use `volt secrets encrypt` to encrypt sensitive values before committing.
