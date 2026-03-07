---
layout: page
title: .volt File Format
---

# .volt File Format Specification

The `.volt` format is the heart of Volt. It's a human-readable, git-friendly file format for defining API requests, test assertions, scripts, and configuration. Every `.volt` file is a plain text file you can edit in any text editor — no special IDE required.

Think of it like this: a `.volt` file is a recipe for an API request. It tells Volt what to send, how to authenticate, and what to check in the response.

---

## Table of Contents

- [What Makes .volt Files Special?](#what-makes-volt-files-special)
- [Basic Structure](#basic-structure)
- [Complete Field Reference](#complete-field-reference)
- [Headers](#headers)
- [Authentication](#authentication)
- [Request Body](#request-body)
- [Test Assertions](#test-assertions)
- [Scripts](#scripts)
- [Variables](#variables)
- [Request Signing](#request-signing)
- [Special Files](#special-files)
- [GraphQL Requests](#graphql-requests)
- [Data-Driven Templates](#data-driven-templates)
- [File Naming Conventions](#file-naming-conventions)
- [Complete Real-World Example](#complete-real-world-example)

---

## What Makes .volt Files Special?

- **Plain text** — Open them in VS Code, Vim, Notepad, or any editor
- **Human-readable** — You can understand what a request does just by reading the file
- **Git-friendly** — Clean diffs, easy code review, no binary blobs
- **Self-contained** — URL, headers, body, auth, tests, and scripts all in one file
- **YAML-like** — Familiar syntax if you've used YAML, but parsed by Volt's own reader (not strict YAML)

---

## Basic Structure

The simplest possible `.volt` file needs just two lines:

```yaml
method: GET
url: https://api.example.com/users
```

That's it! Volt will send a GET request to that URL and show you the response.

Here's a more complete example showing the most common fields:

```yaml
name: Get Users
description: Fetch all users from the API
method: GET
url: https://api.example.com/users
headers:
  - Accept: application/json
  - X-Request-ID: {{$uuid}}
tests:
  - status equals 200
  - header.content-type contains json
```

And here's a full-featured file using almost every field:

```yaml
name: Create User
description: Creates a new user account and returns the user object
method: POST
url: https://{{host}}/api/v2/users
timeout: 5000
tags: users, create, v2

headers:
  - Content-Type: application/json
  - Accept: application/json
  - X-Request-ID: {{$uuid}}
  - X-Client-Version: 2.0

auth:
  type: bearer
  token: {{api_token}}

body:
  type: json
  content: |
    {
      "name": "{{username}}",
      "email": "{{$randomEmail}}",
      "role": "member",
      "created_at": "{{$isoTimestamp}}"
    }

signing:
  type: hmac-sha256
  key: {{signing_key}}
  headers: date host content-type

pre_script: |
  set request_time {{$timestamp}}
  log Creating user: {{username}}

post_script: |
  extract user_id $.id
  extract auth_token $.auth.token
  log User created with ID: $last

tests:
  - status equals 201
  - header.content-type contains json
  - $.id exists
  - $.name equals {{username}}
  - $.role equals member
  - $.email != ""

variables:
  username: Jane Doe
  host: api.example.com
```

---

## Complete Field Reference

Here's every field you can use in a `.volt` file:

### Request Fields

| Field | Required | Description | Example |
|-------|----------|-------------|---------|
| `method` | **Yes** | HTTP method | `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS` |
| `url` | **Yes** | Request URL (supports `{{variable}}` interpolation) | `https://api.example.com/users` |
| `name` | No | Human-readable name for the request | `Get All Users` |
| `description` | No | Longer description (great for documentation) | `Fetches paginated user list` |
| `tags` | No | Comma-separated tags for organization and search | `users, auth, v2` |
| `timeout` | No | Per-request timeout in milliseconds | `5000` |

### Content Fields

| Field | Required | Description |
|-------|----------|-------------|
| `headers` | No | HTTP headers (list format with `- ` prefix) |
| `auth` | No | Authentication configuration (see [Authentication](#authentication)) |
| `body` | No | Request body with type and content (see [Request Body](#request-body)) |
| `body_type` | No | Shorthand for body type (alternative to nested `body.type`) |

### Testing and Scripting Fields

| Field | Required | Description |
|-------|----------|-------------|
| `tests` | No | List of test assertions (see [Test Assertions](#test-assertions)) |
| `pre_script` | No | Script to run before the request (see [Scripts](#scripts)) |
| `post_script` | No | Script to run after the response (see [Scripts](#scripts)) |

### Other Fields

| Field | Required | Description |
|-------|----------|-------------|
| `variables` | No | Request-level variables (key-value pairs) |
| `signing` | No | Request signing configuration (see [Request Signing](#request-signing)) |

---

## Headers

Headers are defined as a list, with each header on its own line prefixed by `- `:

```yaml
headers:
  - Content-Type: application/json
  - Accept: application/json
  - Authorization: Bearer {{token}}
  - X-Request-ID: {{$uuid}}
  - Cache-Control: no-cache
  - User-Agent: MyApp/1.0
```

**Key things to know:**

- Each header follows the format `- Name: Value`
- You can use `{{variables}}` in header values
- You can use dynamic variables like `{{$uuid}}` and `{{$timestamp}}`
- Headers from `_collection.volt` are inherited automatically (you can override them)
- Header names are case-insensitive in HTTP, but Volt preserves your casing

---

## Authentication

Volt supports 8 authentication methods. Define them under the `auth:` section.

### Bearer Token

The most common auth method for modern APIs. Sends `Authorization: Bearer <token>`.

```yaml
auth:
  type: bearer
  token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

With a variable (recommended — don't hardcode tokens!):

```yaml
auth:
  type: bearer
  token: {{api_token}}
```

### Basic Auth

Username and password, Base64-encoded. Sends `Authorization: Basic <encoded>`.

```yaml
auth:
  type: basic
  username: myuser
  password: mypassword
```

### API Key

Send an API key as a header or query parameter.

**In a header** (most common):

```yaml
auth:
  type: api_key
  key_name: X-Api-Key
  key_value: my-secret-key-123
  key_location: header
```

**As a query parameter:**

```yaml
auth:
  type: api_key
  key_name: api_key
  key_value: my-secret-key-123
  key_location: query
```

### Digest Auth

Challenge-response authentication. More secure than Basic but less common.

```yaml
auth:
  type: digest
  username: myuser
  password: mypassword
```

### AWS Signature Version 4

Required for authenticating with AWS services (S3, DynamoDB, Lambda, etc.).

```yaml
auth:
  type: aws
  access_key: AKIAIOSFODNN7EXAMPLE
  secret_key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
  region: us-east-1
  service: s3
```

### Hawk Authentication

HMAC-based authentication with timestamp and nonce.

```yaml
auth:
  type: hawk
  id: dh37fgj492je
  key: werxhqb98rpaxn39848xrunpaw3489ruxnpa98w4rxn
  algorithm: sha256
```

### OAuth 2.0 — Client Credentials

For server-to-server authentication (no user interaction needed).

```yaml
auth:
  type: oauth_cc
  client_id: my-client-id
  client_secret: my-client-secret
  token_url: https://auth.example.com/oauth/token
  scope: read write
```

### OAuth 2.0 — Password Grant

When you have the user's credentials directly (typically for first-party apps).

```yaml
auth:
  type: oauth_password
  client_id: my-client-id
  token_url: https://auth.example.com/oauth/token
  username: user@example.com
  password: userpassword
```

See the [Authentication Guide](authentication.md) for a deeper explanation of each method, including OAuth 2.0 PKCE with `volt login`.

---

## Request Body

Define the request body using the `body:` section with a `type` and `content`.

### JSON Body

The most common body type for modern APIs:

```yaml
body:
  type: json
  content: |
    {
      "name": "Jane Doe",
      "email": "jane@example.com",
      "age": 28,
      "tags": ["developer", "admin"]
    }
```

You can use variables inside the JSON:

```yaml
body:
  type: json
  content: |
    {
      "name": "{{username}}",
      "email": "{{$randomEmail}}",
      "request_id": "{{$uuid}}"
    }
```

### Form Data (URL-Encoded)

For traditional HTML form submissions. Sends `Content-Type: application/x-www-form-urlencoded`.

```yaml
body:
  type: form
  content: |
    username=john
    password=secret
    remember=true
```

### Raw Text

Plain text content:

```yaml
body:
  type: raw
  content: |
    This is plain text content.
    It can be multiple lines.
```

### Multipart Form Data

For file uploads and mixed content. Sends `Content-Type: multipart/form-data`.

```yaml
body:
  type: multipart
  content: |
    file=@/path/to/document.pdf
    description=My uploaded file
    category=reports
```

### Body Type Shorthand

You can also use the `body_type` field as a shorthand:

```yaml
body_type: json
body: |
  {
    "name": "Jane Doe"
  }
```

---

## Test Assertions

Tests are the superpower of `.volt` files. Define assertions that Volt checks automatically after running the request.

### Syntax

Each test is a line under `tests:` with the format:

```
- <field> <operator> <expected_value>
```

### Fields You Can Test

| Field | What it checks | Example |
|-------|---------------|---------|
| `status` | HTTP status code | `status equals 200` |
| `body` | Full response body as text | `body contains "success"` |
| `header.<name>` | A specific response header | `header.content-type contains json` |
| `$.<path>` | JSONPath into the response body | `$.data.name equals John` |

### Operators

| Operator | What it does | Example |
|----------|-------------|---------|
| `equals` (or `==`) | Exact match | `status equals 200` |
| `!=` | Not equal | `status != 404` |
| `<` | Less than (numeric) | `status < 300` |
| `>` | Greater than (numeric) | `$.count > 0` |
| `contains` | Substring match | `body contains "users"` |
| `exists` | Field exists (no value needed) | `$.id exists` |

### JSONPath Assertions

JSONPath lets you drill into JSON responses to test specific fields:

```yaml
tests:
  # Simple field
  - $.name equals Leanne Graham

  # Nested field
  - $.address.city equals Gwenborough

  # Array element by index
  - $.users[0].name equals Alice

  # Array wildcard (check if any element matches)
  - $.tags[*] contains developer

  # Deeply nested
  - $.data.users[0].profile.avatar exists

  # Numeric comparison
  - $.meta.total > 0
  - $.meta.page equals 1

  # Check existence
  - $.id exists
  - $.created_at exists

  # Check non-equality
  - $.email != ""
  - $.status != inactive
```

### Comprehensive Test Example

```yaml
tests:
  # Status checks
  - status equals 200
  - status < 300
  - status != 404

  # Header checks
  - header.content-type contains application/json
  - header.x-request-id exists

  # Body checks
  - body contains users

  # JSON field checks
  - $.data[0].name equals John
  - $.data[0].email contains @
  - $.meta.total > 0
  - $.meta.page equals 1
  - $.data[0].id exists
```

See the [Testing Guide](testing.md) for data-driven testing, test reports, and more.

---

## Scripts

Scripts let you run logic before and after requests. They're essential for multi-step workflows like "login, extract token, use token."

### Pre-Request Scripts

Run before the request is sent. Use for setup, variable generation, and header manipulation.

```yaml
pre_script: |
  set timestamp {{$timestamp}}
  log Starting request at $last
  header X-Timestamp {{$timestamp}}
  uuid
  set request_id $last
```

### Post-Response Scripts

Run after the response is received. Use for extraction, assertions, and logging.

```yaml
post_script: |
  log Response status: response.status
  extract user_id $.id
  extract auth_token $.auth.token
  assert.status 201
  assert.json $.name equals Jane
```

### Complete Script Command Reference

**Environment commands:**

| Command | Description | Example |
|---------|-------------|---------|
| `env.set <key> <value>` | Set an environment variable | `env.set api_url https://api.example.com` |
| `env.get <key>` | Get an environment variable | `env.get api_url` |
| `env.delete <key>` | Delete an environment variable | `env.delete temp_token` |

**Response commands** (post-script only):

| Command | Description | Example |
|---------|-------------|---------|
| `response.status` | Get HTTP status code | `response.status` |
| `response.body` | Get full response body | `response.body` |
| `response.header <name>` | Get a response header value | `response.header content-type` |
| `response.json <path>` | Extract a JSON value using JSONPath | `response.json $.data.id` |
| `response.time` | Get response time in milliseconds | `response.time` |

**Variable commands:**

| Command | Description | Example |
|---------|-------------|---------|
| `extract <var> <jsonpath>` | Extract from response and save as variable | `extract user_id $.id` |
| `chain <var> <jsonpath>` | Alias for extract | `chain token $.auth.token` |
| `set <var> <value>` | Set a local variable | `set timestamp 1234567890` |
| `header <name> <value>` | Set a request header dynamically | `header X-Custom my-value` |

**Assertion commands:**

| Command | Description | Example |
|---------|-------------|---------|
| `assert.status <code>` | Assert status code | `assert.status 200` |
| `assert.header <name> <op> <val>` | Assert a header value | `assert.header content-type contains json` |
| `assert.body <op> <val>` | Assert body content | `assert.body contains success` |
| `assert.json <path> <op> <val>` | Assert a JSON value | `assert.json $.id exists` |

**Utility commands:**

| Command | Description | Example |
|---------|-------------|---------|
| `log <message>` | Print a message to console | `log User created successfully` |
| `base64.encode <value>` | Base64 encode a value | `base64.encode myuser:mypass` |
| `base64.decode <value>` | Base64 decode a value | `base64.decode dXNlcjpwYXNz` |
| `uuid` | Generate a UUID (stored in `$last`) | `uuid` |
| `timestamp` | Get current Unix timestamp (stored in `$last`) | `timestamp` |
| `sleep <ms>` | Pause execution for milliseconds | `sleep 1000` |

See the [Scripting Guide](scripting.md) for workflows, variable chaining, and advanced examples.

---

## Variables

Variables make your `.volt` files dynamic and reusable. There are three types.

### Template Variables

Use `{{variable_name}}` anywhere — URLs, headers, body, auth fields:

```yaml
url: {{base_url}}/users/{{user_id}}
headers:
  - Authorization: Bearer {{token}}
body:
  type: json
  content: |
    {
      "name": "{{username}}"
    }
```

### Dynamic Variables

Built-in variables that generate fresh values on every request. Always prefixed with `$`:

| Variable | Description | Example Output |
|----------|-------------|----------------|
| `{{$uuid}}` | UUID v4 | `550e8400-e29b-41d4-a716-446655440000` |
| `{{$guid}}` | Alias for UUID | `550e8400-e29b-41d4-a716-446655440000` |
| `{{$timestamp}}` | Unix timestamp (seconds) | `1708300800` |
| `{{$isoTimestamp}}` | ISO 8601 datetime | `2026-02-19T08:00:00Z` |
| `{{$isoDate}}` | Alias for isoTimestamp | `2026-02-19T08:00:00Z` |
| `{{$date}}` | Date only | `2026-02-19` |
| `{{$randomInt}}` | Random integer (0-9999) | `7291` |
| `{{$randomFloat}}` | Random float (0-1) | `0.4832` |
| `{{$randomEmail}}` | Random email address | `user4832@example.com` |
| `{{$randomString}}` | 8 random alphanumeric chars | `a8f3k2x9` |
| `{{$randomBool}}` | Random boolean | `true` or `false` |

**Usage example:**

```yaml
headers:
  - X-Request-ID: {{$uuid}}
  - X-Timestamp: {{$timestamp}}
body:
  type: json
  content: |
    {
      "email": "{{$randomEmail}}",
      "nonce": {{$randomInt}},
      "created": "{{$isoTimestamp}}"
    }
```

### Request-Level Variables

Define variables local to a single `.volt` file:

```yaml
variables:
  base_url: https://api.example.com
  version: v2
  default_limit: 50
```

### Variable Resolution Order

When the same variable name exists in multiple places, Volt uses this priority (highest first):

1. **Request-level** — `variables:` section in the `.volt` file
2. **Runtime** — Variables set by `extract` or `set` in previous requests
3. **Collection** — Variables from `_collection.volt`
4. **Environment** — Variables from `_env.volt` (based on active environment)
5. **Global** — Variables from `.voltrc`
6. **Dynamic** — Built-in `$` variables (generated fresh)

---

## Request Signing

Sign your requests with HMAC-SHA256 for APIs that require message authentication.

```yaml
signing:
  type: hmac-sha256
  key: your-secret-signing-key
  headers: date host content-type
```

Then run with the `--sign` flag:

```bash
volt run api/secure-endpoint.volt --sign
```

Volt builds a canonical request from the specified headers, computes the HMAC-SHA256 signature, and adds it to the request. This is similar to how AWS Signature v4 works.

---

## Special Files

Volt recognizes three special file types that configure how your project works.

### `_collection.volt`

Place this in any directory to define shared configuration inherited by all requests in that directory.

```yaml
name: My API Collection
description: Shared settings for all user API requests

# Default method (requests can override this)
method: GET

# Base URL — all requests in this directory inherit this
url: https://api.example.com

# Shared headers — applied to every request
headers:
  - Accept: application/json
  - X-Api-Version: 2.0

# Shared auth — every request uses this unless it defines its own
auth:
  type: bearer
  token: {{api_token}}

# Shared variables
variables:
  version: v2
```

Individual requests in the same directory inherit these settings. If a request defines its own `auth:` or headers, they override the collection defaults.

### `_env.volt`

Defines environment variables using INI-style sections. Place this in your project root or any directory.

```ini
[default]
base_url = https://localhost:3000
api_key = dev-key-123
debug = true

[staging]
base_url = https://staging.api.example.com
api_key = staging-key-456
debug = false

[production]
base_url = https://api.example.com
api_key = prod-key-789
debug = false
```

Switch environments with `--env`:

```bash
volt run request.volt --env staging
```

**Secret masking:** Variables whose names start with `$` are automatically masked as `***` in terminal output:

```ini
[default]
$api_key = super-secret-key-123
$db_password = hunter2
```

### `.voltrc`

Project-level configuration file. Place this in your project root (created by `volt init`).

```yaml
# Base URL prepended to relative URLs
base_url: https://api.example.com

# Default request timeout (ms)
timeout: 30000

# Default headers for all requests
headers:
  - Accept: application/json
  - User-Agent: Volt/1.1.0

# Output format: pretty | compact | raw
output: pretty

# Enable colored output
color: true

# Follow HTTP redirects
follow_redirects: true
max_redirects: 10

# SSL verification
verify_ssl: true

# Client certificate (mutual TLS)
client_cert: /path/to/cert.pem
client_key: /path/to/key.pem

# Custom CA bundle
ca_bundle: /path/to/ca-bundle.crt

# TLS version
ssl_version: tls1.3

# Color theme
theme: dracula

# Proxy
proxy: http://proxy.company.com:8080

# Session settings
session: default
```

See the [Environments Guide](environments.md) for a complete walkthrough.

---

## GraphQL Requests

You can write GraphQL queries as regular `.volt` files with a JSON body:

```yaml
name: Countries Query
method: POST
url: https://countries.trevorblades.com/graphql
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "query": "{ countries { name capital currency } }"
    }
tests:
  - status equals 200
  - $.data.countries exists
```

**GraphQL with variables:**

```yaml
name: User by ID
method: POST
url: https://api.example.com/graphql
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "query": "query GetUser($id: ID!) { user(id: $id) { name email } }",
      "variables": { "id": "123" },
      "operationName": "GetUser"
    }
tests:
  - status equals 200
  - $.data.user.name exists
```

You can also use the dedicated `volt graphql` command for additional features like schema introspection. See the [Protocols Guide](protocols.md).

---

## Data-Driven Templates

Use `{{variables}}` as placeholders in a `.volt` file, then feed data from a CSV or JSON file to run the same request many times with different inputs.

**template.volt:**

```yaml
name: Create User - {{name}}
method: POST
url: https://api.example.com/users
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "name": "{{name}}",
      "email": "{{email}}",
      "role": "{{role}}"
    }
tests:
  - status equals 201
  - $.name equals {{name}}
```

**data.csv:**

```csv
name,email,role
Alice,alice@example.com,admin
Bob,bob@example.com,editor
Charlie,charlie@example.com,viewer
```

**Run it:**

```bash
volt test template.volt --data data.csv
```

Each row becomes a separate test run. See the [Testing Guide](testing.md) for JSON data sources too.

---

## File Naming Conventions

| Pattern | Purpose |
|---------|---------|
| `*.volt` | Regular request files |
| `_collection.volt` | Collection-level config (inherited by sibling files) |
| `_env.volt` | Environment variables |
| `.voltrc` | Project configuration |
| `_`-prefixed files | Skipped by `volt lint` and `volt test` |
| `01-`, `02-` numeric prefixes | Control execution order in collections |

**Example project structure:**

```
my-api/
  .voltrc                    # Project config
  _env.volt                  # Global environment variables
  api/
    _collection.volt         # Shared auth and headers for all API requests
    _env.volt                # API-specific variables
    01-auth/
      01-login.volt          # Runs first
      02-get-token.volt      # Runs second, uses token from login
    02-users/
      get-users.volt
      create-user.volt
      update-user.volt
    03-posts/
      list-posts.volt
      create-post.volt
```

Files are plain text, git-diffable, and safe to commit. Use `volt secrets encrypt` to protect sensitive values before committing.

---

## Complete Real-World Example

Here's a realistic `.volt` file that demonstrates many features working together:

```yaml
# api/users/create-user.volt
# This request creates a new user and extracts the ID for subsequent requests.

name: Create User
description: |
  Creates a new user account with the given details.
  Requires admin authentication. The user ID is extracted
  for use in follow-up requests (update, delete, verify).

method: POST
url: {{base_url}}/api/v2/users
timeout: 10000
tags: users, create, v2, admin

headers:
  - Content-Type: application/json
  - Accept: application/json
  - X-Request-ID: {{$uuid}}
  - X-Idempotency-Key: {{$uuid}}

auth:
  type: bearer
  token: {{$admin_token}}

body:
  type: json
  content: |
    {
      "name": "{{username}}",
      "email": "{{$randomEmail}}",
      "role": "member",
      "department": "{{department}}",
      "metadata": {
        "source": "volt-api-test",
        "created_at": "{{$isoTimestamp}}",
        "request_id": "{{$uuid}}"
      }
    }

pre_script: |
  log Creating user: {{username}} in department: {{department}}
  set start_time {{$timestamp}}

post_script: |
  extract user_id $.id
  extract user_email $.email
  log Created user {{user_id}} ({{user_email}})
  assert.status 201
  assert.json $.role equals member

tests:
  - status equals 201
  - header.content-type contains application/json
  - header.location exists
  - $.id exists
  - $.name equals {{username}}
  - $.role equals member
  - $.email != ""
  - $.metadata.source equals volt-api-test
  - $.created_at exists

variables:
  username: Jane Doe
  department: Engineering
```

---

## What's Next?

- [Getting Started](getting-started.md) — Send your first request step by step
- [Command Reference](commands.md) — Every CLI command and flag
- [Testing Guide](testing.md) — Deep dive into assertions and test reports
- [Scripting Engine](scripting.md) — Advanced scripts and workflows
- [Authentication Guide](authentication.md) — All auth methods explained
- [Environments Guide](environments.md) — Variables, environments, and project config
