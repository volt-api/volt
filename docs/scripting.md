---
layout: page
title: Scripting Engine
---

# Scripting Engine

A complete guide to Volt's built-in scripting engine -- automate API workflows, chain requests together, validate responses, and build dynamic request pipelines, all without leaving your `.volt` files.

---

## Table of Contents

1. [What is API Scripting?](#1-what-is-api-scripting)
2. [Pre-Request Scripts](#2-pre-request-scripts)
3. [Post-Response Scripts](#3-post-response-scripts)
4. [Script Language Basics](#4-script-language-basics)
5. [Complete Command Reference](#5-complete-command-reference)
6. [Variable Chaining Between Requests](#6-variable-chaining-between-requests)
7. [Assertions and Testing in Scripts](#7-assertions-and-testing-in-scripts)
8. [Conditionals](#8-conditionals)
9. [Named Test Blocks](#9-named-test-blocks)
10. [Workflow Files](#10-workflow-files)
11. [Practical Examples](#11-practical-examples)
12. [Debugging Scripts](#12-debugging-scripts)
13. [Script Best Practices](#13-script-best-practices)

---

## 1. What is API Scripting?

When you work with APIs, you often need to do more than just send a single request and read the response. Real-world API workflows look like this:

1. **Log in** to get an access token.
2. **Use that token** to create a resource.
3. **Extract the resource ID** from the response.
4. **Verify the resource exists** by fetching it with that ID.
5. **Check that the data matches** what you sent.

Doing this manually -- copying tokens, pasting IDs, eyeballing status codes -- is tedious and error-prone. **API scripting** lets you automate all of it.

Volt's scripting engine lets you embed small scripts directly inside your `.volt` request files. These scripts run at two specific points in the request lifecycle:

- **Pre-request scripts** (`pre_script:`) run **before** the HTTP request is sent. Use them to set headers dynamically, generate timestamps, encode credentials, or prepare the request in any way you need.

- **Post-response scripts** (`post_script:`) run **after** the HTTP response is received. Use them to extract values from the response (like tokens or IDs), validate the response with assertions, set environment variables for the next request, or log diagnostic information.

Here is a visual overview of when each script runs:

```
  .volt file loaded
        |
        v
  +------------------+
  |  pre_script: |    |  <-- Runs BEFORE the request
  |  (set headers,   |      (modify request, generate values)
  |   generate UUIDs,|
  |   encode values) |
  +------------------+
        |
        v
  +------------------+
  |  HTTP Request     |  <-- Volt sends the request
  |  GET /api/users   |
  +------------------+
        |
        v
  +------------------+
  |  HTTP Response    |  <-- Server responds
  |  200 OK {...}     |
  +------------------+
        |
        v
  +------------------+
  |  post_script: |   |  <-- Runs AFTER the response
  |  (extract token, |      (read response, assert, chain)
  |   assert status,  |
  |   log output)     |
  +------------------+
```

The scripting language is intentionally simple -- it is not JavaScript or Lua. It is a **line-based command language** designed specifically for API workflows. Each line is a command. There are no complex control flow structures, no classes, no callbacks. If you can read a shell script, you can read a Volt script.

---

## 2. Pre-Request Scripts

A pre-request script runs **before** the HTTP request is sent. This is the right place to:

- Set or modify request headers dynamically.
- Generate unique values (UUIDs, timestamps, nonces).
- Encode credentials (Base64 for Basic auth).
- Set environment variables that will be used in the request URL or body.
- Log what you are about to do.

### Syntax

Add a `pre_script:` block to your `.volt` file using the YAML block scalar syntax (`|`):

```yaml
name: My Request
method: GET
url: https://api.example.com/data
pre_script: |
  # Your script commands go here
  # Each line is one command
  log Starting request...
  timestamp
  env.set request_time $last
```

The `|` character after `pre_script:` tells Volt that the following indented lines are the script content. Every line indented under `pre_script:` is part of the script.

### Example: Generate a Unique Request ID

```yaml
name: Create Order
method: POST
url: https://api.example.com/orders
headers:
  - Content-Type: application/json
pre_script: |
  uuid
  header X-Request-ID $last
  timestamp
  header X-Timestamp $last
  log Generated request ID and timestamp
body:
  type: json
  content: |
    {
      "product": "widget",
      "quantity": 5
    }
```

In this example, the `uuid` command generates a UUID and stores it in the internal `$last` result. The `header` command then sets the `X-Request-ID` header to that value. The same pattern is used with `timestamp` to set `X-Timestamp`.

### Example: Encode Basic Auth Credentials

```yaml
name: Authenticated Request
method: GET
url: https://api.example.com/secure-data
pre_script: |
  base64.encode admin:secretpassword
  header Authorization Basic $last
```

This encodes the string `admin:secretpassword` in Base64 and sets the `Authorization` header with the result.

### What Pre-Scripts Cannot Do

Pre-request scripts run before the response exists, so response-related commands (`response.status`, `response.body`, `response.header`, `response.json`, `extract`, `chain`, and all `assert.*` commands) are not available in pre-scripts. If you try to use them, they will simply have no effect -- there is no response data to read yet.

---

## 3. Post-Response Scripts

A post-response script runs **after** the HTTP response is received. This is the right place to:

- Extract values from the response (tokens, IDs, URLs).
- Assert that the response matches your expectations.
- Set environment variables for subsequent requests.
- Log response details for debugging.
- Chain data to the next request in a collection.

### Syntax

Add a `post_script:` block to your `.volt` file:

```yaml
name: Login
method: POST
url: https://api.example.com/auth/login
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "username": "admin",
      "password": "secret"
    }
post_script: |
  # Check the response
  assert.status 200
  assert.json token exists

  # Extract the token for the next request
  extract auth_token token
  log Extracted token successfully

  # Also grab the user ID
  extract user_id user.id
```

### Example: Validate and Extract

```yaml
name: Get User List
method: GET
url: https://api.example.com/users
headers:
  - Accept: application/json
post_script: |
  # Verify the basics
  assert.status 200
  assert.header content-type contains application/json

  # Check response structure
  assert.json data exists
  assert.json total_count exists

  # Extract pagination info for the next request
  extract total data.total_count
  extract next_page data.next_page_url

  # Log what we found
  log Total users found:
  response.json data.total_count
```

---

## 4. Script Language Basics

Before diving into the full command reference, here are the fundamentals of Volt's scripting language.

### One Command Per Line

Each line in a script is a single command. There is no line continuation or multi-line commands:

```
# Good
env.set base_url https://api.example.com
log Setting up environment

# Bad (this is not how it works)
env.set base_url
  https://api.example.com
```

### Comments

Lines starting with `#` or `//` are comments and are ignored:

```
# This is a comment
// This is also a comment
env.set api_key abc123
```

### Blank Lines

Empty lines are ignored. Use them freely to organize your script:

```
# Setup
env.set host api.example.com

# Assertions
assert.status 200
assert.json data exists

# Extraction
extract token auth.token
```

### Values with Spaces

When a command takes a value, everything after the last required parameter is treated as the value. For example:

```
log Hello World         # "Hello World" is the message
env.set greeting Hello World  # "Hello World" is the value
```

You do not need to quote strings -- the engine naturally captures the remainder of the line.

### The `$last` Result

Some commands produce a result that is stored internally as `$last`. This is how you chain commands together. For example, `uuid` generates a UUID and stores it as `$last`, and the next command can reference it:

```
uuid
# $last now contains something like "a3b8f042-1e16-4f0e-8c74-59b2a4738d1c"
```

Commands that set `$last`: `uuid`, `timestamp`, `base64.encode`, `base64.decode`, `env.get`, `response.json`.

---

## 5. Complete Command Reference

Here is every command available in Volt's scripting engine, organized by category.

### Environment Variable Commands

These commands read and write environment variables. Variables set here persist across requests in a collection run, making them the primary mechanism for passing data between requests.

#### `env.set <key> <value>`

Set an environment variable. The variable is immediately available to subsequent requests in a collection run via `{{key}}` interpolation.

```
env.set base_url https://api.example.com
env.set auth_token eyJhbGciOiJIUzI1NiJ9...
env.set page_size 25
```

**Where it works:** pre_script, post_script

#### `env.get <key>`

Retrieve the current value of an environment variable. The result is stored in `$last`.

```
env.get base_url
# $last now contains "https://api.example.com"
```

**Where it works:** pre_script, post_script

#### `env.delete <key>`

Remove an environment variable from the active environment.

```
env.delete temp_token
env.delete old_session_id
```

**Where it works:** pre_script, post_script

---

### Response Commands

These commands read data from the HTTP response. They are only useful in `post_script:` blocks (in a pre-script, there is no response yet).

#### `response.status`

Print the HTTP status code to the script output.

```
response.status
# Outputs: 200
```

**Where it works:** post_script only

#### `response.body`

Print the full response body to the script output.

```
response.body
# Outputs the entire response body
```

**Where it works:** post_script only

#### `response.header <name>`

Get a specific response header value and print it to the script output.

```
response.header content-type
# Outputs: application/json; charset=utf-8

response.header x-request-id
# Outputs: req_abc123
```

**Where it works:** post_script only

#### `response.json <path>`

Extract a value from the JSON response body using a dot-notation path. The result is printed to the script output and stored in `$last`.

```
response.json data.user.name
# Outputs: "Alice"
# $last is set to "Alice"

response.json data.items.0.id
# Outputs: "42"
```

The path uses dot notation to navigate nested objects: `data.user.name` reaches into `{"data": {"user": {"name": "Alice"}}}`.

**Where it works:** post_script only

#### `response.time`

Get the response time in milliseconds.

```
response.time
# Outputs: 247
```

**Where it works:** post_script only

---

### Variable Extraction Commands

These commands extract data from the response and save it as a variable, making it available to subsequent requests.

#### `extract <var> <jsonpath>`

Extract a value from the response body using a JSONPath-like expression and save it as both a local variable and a runtime environment variable. The variable becomes available to the next request in a collection as `{{var}}`.

```
extract auth_token token
# Extracts $.token from response and saves as "auth_token"

extract user_id data.user.id
# Extracts $.data.user.id from response and saves as "user_id"

extract next_url pagination.next
# Extracts $.pagination.next from response and saves as "next_url"
```

You can optionally prefix the path with `body.` -- both forms work identically:

```
extract token body.token      # Same as: extract token token
extract id body.data.user.id  # Same as: extract id data.user.id
```

**Where it works:** post_script only

#### `chain <var> <jsonpath>`

An alias for `extract`. Behaves identically -- extracts a value from the response and propagates it as a variable for the next request.

```
chain auth_token token
chain user_id data.user.id
```

The name `chain` emphasizes that you are chaining data from one request to the next. Use whichever name reads more clearly in your script.

**Where it works:** post_script only

---

### Local Variable Commands

#### `set <var> <value>`

Set a local variable within the script. This variable exists only for the duration of the script execution. Unlike `env.set`, it does not propagate to subsequent requests in a collection -- use `env.set` or `extract` for that.

```
set expected_status 200
set api_version v2
set greeting Hello World
```

Local variables are useful for intermediate calculations and for use with `if` conditionals and `expect` assertions within the same script.

**Where it works:** pre_script, post_script

---

### Request Modification Commands

#### `header <name> <value>`

Dynamically add or set a request header. This is useful in pre-scripts to add headers that depend on computed values.

```
header X-Request-ID 550e8400-e29b-41d4-a716-446655440000
header Authorization Bearer eyJhbGciOiJIUzI1NiJ9...
header X-Timestamp 1708617600
```

Typically used after generating a value:

```
uuid
header X-Request-ID $last

timestamp
header X-Timestamp $last

base64.encode admin:password
header Authorization Basic $last
```

**Where it works:** pre_script (this is where it makes sense -- you are modifying the request before it is sent)

---

### Assertion Commands

Assertions verify that the response matches your expectations. If an assertion fails, it is counted as a failure in the test results but does **not** stop script execution -- subsequent commands still run.

#### `assert.status <code>`

Assert that the HTTP status code matches the expected value.

```
assert.status 200
assert.status 201
assert.status 204
```

#### `assert.header <name> <operator> <value>`

Assert that a response header matches a condition.

```
assert.header content-type contains application/json
assert.header content-type equals application/json; charset=utf-8
assert.header x-ratelimit-remaining exists
assert.header cache-control contains no-cache
```

#### `assert.body <operator> <value>`

Assert that the full response body matches a condition.

```
assert.body contains "success"
assert.body contains "id"
assert.body != ""
```

#### `assert.json <path> <operator> <value>`

Assert that a specific JSON field in the response matches a condition.

```
assert.json data.user.name equals Alice
assert.json data.count != 0
assert.json data.items exists
assert.json data.status contains active
assert.json data.email endsWith @example.com
assert.json data.url startsWith https://
```

#### `expect <field> <operator> <expected>`

A general-purpose assertion that can check local variables, response status, headers, and body content.

```
# Check a local variable
set x hello
expect x equals hello

# Check response status
expect status equals 200
expect status != 404
expect status < 400

# Check a header
expect header.content-type contains json

# Check the body
expect body contains success
```

#### Available Operators

All assertion commands (`assert.*` and `expect`) support the following operators:

| Operator | Meaning | Example |
|----------|---------|---------|
| `equals` or `==` | Exact string match | `assert.json name equals Alice` |
| `!=` | Not equal | `assert.status != 404` |
| `contains` | Substring present | `assert.body contains success` |
| `startsWith` | Starts with prefix | `assert.json url startsWith https` |
| `endsWith` | Ends with suffix | `assert.json email endsWith .com` |
| `exists` | Value is non-empty | `assert.json token exists` |
| `matches` | Pattern found in value | `assert.body matches "id"` |

---

### Utility Commands

#### `log <message>`

Print a message to the console output. Useful for debugging and tracing script execution.

```
log Starting authentication flow...
log Token extracted successfully
log About to call the users endpoint
```

The message is everything after `log ` to the end of the line.

#### `base64.encode <value>`

Base64-encode a value. The result is printed to the script output and stored in `$last`.

```
base64.encode hello
# Output: aGVsbG8=
# $last = "aGVsbG8="

base64.encode admin:secretpassword
# Output: YWRtaW46c2VjcmV0cGFzc3dvcmQ=
```

**Common use case:** generating Basic auth headers:

```
base64.encode myuser:mypassword
header Authorization Basic $last
```

#### `base64.decode <value>`

Base64-decode a value. The result is stored in `$last`.

```
base64.decode aGVsbG8=
# $last = "hello"
```

#### `uuid`

Generate a random UUID (v4) and store it in `$last`.

```
uuid
# $last = "a3b8f042-1e16-4f0e-8c74-59b2a4738d1c"
```

**Common use case:** unique request IDs or idempotency keys:

```
uuid
header X-Request-ID $last
header Idempotency-Key $last
```

#### `timestamp`

Get the current Unix timestamp (seconds since epoch) and store it in `$last`.

```
timestamp
# $last = "1708617600"
```

**Common use case:** timestamped requests or nonce generation:

```
timestamp
header X-Timestamp $last
env.set request_timestamp $last
```

#### `sleep <ms>`

Pause execution for the specified number of milliseconds.

```
sleep 1000    # Wait 1 second
sleep 500     # Wait half a second
sleep 2000    # Wait 2 seconds
```

**Common use cases:**

- Wait for an asynchronous operation to complete before checking its result.
- Respect rate limits between requests.
- Simulate real-world timing in workflows.

---

## 6. Variable Chaining Between Requests

Variable chaining is one of the most powerful features of Volt's scripting engine. It lets you **pass data from one request to the next** in a collection or workflow -- for example, extracting an auth token from a login response and using it in subsequent API calls.

### How It Works

1. A `post_script:` in one request uses `extract` (or `chain` or `env.set`) to save a value.
2. The value is stored as a **runtime variable**.
3. The next request in the collection references it with `{{variable_name}}` -- Volt resolves it automatically.

### Complete Multi-Step Example

Here is a realistic three-step API workflow: log in, create a resource, then verify it exists.

**Step 1: `01-login.volt`**

```yaml
name: Login
method: POST
url: {{base_url}}/auth/login
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "username": "admin",
      "password": "{{$admin_password}}"
    }
post_script: |
  # Verify login succeeded
  assert.status 200
  assert.json token exists
  assert.json user.id exists

  # Extract the token and user ID for subsequent requests
  extract auth_token token
  extract user_id user.id

  log Login successful, token extracted
tests:
  - status equals 200
```

**Step 2: `02-create-post.volt`**

```yaml
name: Create Blog Post
method: POST
url: {{base_url}}/api/posts
headers:
  - Content-Type: application/json
  - Authorization: Bearer {{auth_token}}
body:
  type: json
  content: |
    {
      "title": "Hello from Volt",
      "body": "Automated API testing is great!",
      "author_id": "{{user_id}}"
    }
post_script: |
  assert.status 201
  assert.json id exists

  # Extract the new post's ID
  extract post_id id

  log Created post with ID:
  response.json id
tests:
  - status equals 201
```

**Step 3: `03-verify-post.volt`**

```yaml
name: Verify Post Exists
method: GET
url: {{base_url}}/api/posts/{{post_id}}
headers:
  - Authorization: Bearer {{auth_token}}
post_script: |
  assert.status 200
  assert.json title equals Hello from Volt
  assert.json author_id equals {{user_id}}

  log Post verified successfully
tests:
  - status equals 200
  - $.title equals Hello from Volt
```

### Running the Chain

Run all three files as a collection:

```bash
volt collection my-api/
```

Or run them individually in order (with `volt run`), though `volt collection` is recommended since it automatically propagates variables between requests.

### Variable Flow Diagram

```
01-login.volt
  |  POST /auth/login
  |  Response: {"token": "eyJ...", "user": {"id": "42"}}
  |  extract auth_token token    -->  auth_token = "eyJ..."
  |  extract user_id user.id     -->  user_id = "42"
  |
  v
02-create-post.volt
  |  Authorization: Bearer {{auth_token}}  -->  Bearer eyJ...
  |  "author_id": "{{user_id}}"           -->  "42"
  |  POST /api/posts
  |  Response: {"id": "789", "title": "Hello from Volt"}
  |  extract post_id id          -->  post_id = "789"
  |
  v
03-verify-post.volt
     GET /api/posts/{{post_id}}  -->  GET /api/posts/789
     Authorization: Bearer {{auth_token}}  -->  Bearer eyJ...
     Response: {"id": "789", "title": "Hello from Volt", "author_id": "42"}
     All assertions pass
```

### Runtime Variable Scope

Variables set by `extract`, `chain`, and `env.set` during a collection run are **runtime variables**. They follow Volt's standard variable resolution order:

1. Request-level variables (from `variables:` in the `.volt` file)
2. **Runtime variables** (from `extract`, `chain`, `env.set` in scripts) -- **this is where chained values live**
3. Collection-level variables (from `_collection.volt`)
4. Environment variables (from `_env.volt`)
5. Global variables (from `.voltrc`)
6. Dynamic variables (`$uuid`, `$timestamp`, etc.)

Runtime variables have the **second-highest priority**, so they override environment, collection, and global variables but can be overridden by request-level variables.

---

## 7. Assertions and Testing in Scripts

While Volt has a dedicated `tests:` section for declarative assertions, the scripting engine gives you **programmatic assertions** that are more flexible. You can combine both approaches in the same `.volt` file.

### Declarative Tests vs. Script Assertions

**Declarative tests** (the `tests:` section) are simple and clean:

```yaml
tests:
  - status equals 200
  - $.data.name equals Alice
  - $.data.email exists
```

**Script assertions** (in `post_script:`) give you more control:

```yaml
post_script: |
  assert.status 200
  assert.json data.name equals Alice
  assert.json data.email exists

  # You can also extract + assert in sequence
  extract name data.name
  log User name is:
  response.json data.name

  # Conditional logic
  if status equals 200
  log Success! User data is valid
```

**When to use which:**

- Use `tests:` for straightforward assertions that do not depend on extracted values.
- Use `post_script:` when you need to extract values, perform conditional checks, or combine assertions with logging.
- You can use both in the same file -- they complement each other.

### Assertion Counting

Every `assert.*` and `expect` command increments an internal assertion counter. Volt reports how many assertions passed and failed:

```yaml
post_script: |
  assert.status 200                        # Assertion 1
  assert.header content-type contains json # Assertion 2
  assert.json data exists                  # Assertion 3
  assert.json data.count != 0             # Assertion 4
```

After execution, Volt reports: `4 assertions: 4 passed, 0 failed`

---

## 8. Conditionals

The scripting engine supports simple conditional execution with the `if` command.

### Syntax

```
if <field> <operator> <value>
<command that runs only if the condition is true>
```

The `if` command evaluates a condition, and if it is true, the **next line** executes. If the condition is false, the next line is skipped. Only one line is affected -- this is not a block-style if/else.

### Fields You Can Check

| Field | What it checks |
|-------|---------------|
| `status` | The HTTP response status code |
| `header.<name>` | A response header value |
| `body` | The full response body |
| `<variable>` | A local variable set with `set` |

### Examples

```yaml
post_script: |
  # Only log success if status is 200
  if status equals 200
  log Request succeeded!

  # Only log error if status is not 200
  if status != 200
  log Request failed with non-200 status

  # Check a header
  if header.content-type contains json
  log Response is JSON

  # Check a variable
  set mode production
  if mode equals production
  log Running in production mode

  # Conditional extraction
  if status equals 200
  extract token data.token

  if status equals 401
  log Authentication failed -- token may be expired
```

### Chaining Multiple Conditions

Since `if` only controls the next single line, you write multiple independent conditions:

```yaml
post_script: |
  if status < 300
  log Status OK

  if status >= 400
  log Status indicates an error

  if status equals 429
  log Rate limited -- consider adding a delay
```

---

## 9. Named Test Blocks

For organized testing, you can group related assertions into **named test blocks** using `test "name" { ... }` syntax. Test blocks are reported individually in test results, making it easy to see which logical group of assertions passed or failed.

### Syntax

```
test "descriptive name" {
  expect field operator value
  expect field operator value
}
```

### Example

```yaml
post_script: |
  test "response is valid JSON" {
    expect status equals 200
    expect header.content-type contains json
  }

  test "user data is correct" {
    set expected_name Alice
    expect body contains Alice
  }

  test "pagination is present" {
    expect body contains total_count
    expect body contains next_page
  }
```

Test results are reported individually:

```
  PASS  response is valid JSON
  PASS  user data is correct
  PASS  pagination is present

3 tests: 3 passed, 0 failed
```

If any `expect` inside a test block fails, the entire block is marked as failed.

---

## 10. Workflow Files

For complex multi-step API flows that go beyond simple collections, Volt supports **workflow files**. A workflow is a YAML file (with a `.workflow` extension) that defines a sequence of steps, each referencing a `.volt` file, with support for variable extraction, delays, and conditional execution.

### Why Use Workflows?

Collections run all `.volt` files in a directory alphabetically. Workflows give you explicit control:

- **Choose exactly which files to run** and in what order.
- **Add delays** between steps (e.g., wait for an async operation).
- **Add conditions** (e.g., only run step 3 if step 2 returned 200).
- **Extract variables** at the workflow level, separate from per-file scripts.
- **Name each step** for clear reporting.

### Workflow File Format

```yaml
name: My API Workflow

steps:
  - file: path/to/first-request.volt
    name: Step Name (optional)
    extract:
      variable_name: body.json.path
      another_var: header.HeaderName
    delay: 0
    condition: status == 200
```

### Field Reference

| Field | Required | Description |
|-------|----------|-------------|
| `name` (top-level) | No | A descriptive name for the workflow |
| `steps` | Yes | The list of steps to execute in order |
| `- file` | Yes | Path to the `.volt` file for this step |
| `name` (step-level) | No | A human-readable name for the step (shown in output) |
| `extract` | No | Variables to extract from the response |
| `delay` | No | Milliseconds to wait before executing this step |
| `condition` | No | Only execute if the condition (checked against the previous step) is true |

### Extract Sources

In the `extract:` section of a workflow step, the source specifier tells Volt where to find the value:

| Source | Description | Example |
|--------|-------------|---------|
| `body.<path>` | JSON field in response body | `body.token`, `body.data.user.id` |
| `header.<name>` | Response header | `header.x-request-id` |
| `status` | The HTTP status code as a string | `status` |
| `body` | The entire response body | `body` |

### Condition Syntax

Conditions in workflow steps are checked against the **previous step's** result:

| Condition | Meaning |
|-----------|---------|
| `status == 200` | Previous step returned status 200 |
| `status != 404` | Previous step did not return 404 |
| `status < 400` | Previous step returned a non-error status |
| `status >= 200` | Previous step returned 200 or above |
| `passed == true` | Previous step was considered successful |
| `passed == false` | Previous step failed |

### Complete Workflow Example

Suppose you have the following `.volt` files in your project:

**auth/login.volt:**
```yaml
name: Login
method: POST
url: {{base_url}}/auth/login
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "username": "admin",
      "password": "{{$admin_password}}"
    }
```

**users/create-user.volt:**
```yaml
name: Create User
method: POST
url: {{base_url}}/api/users
headers:
  - Content-Type: application/json
  - Authorization: Bearer {{auth_token}}
body:
  type: json
  content: |
    {
      "name": "New User",
      "email": "newuser@example.com"
    }
```

**users/get-user.volt:**
```yaml
name: Get User
method: GET
url: {{base_url}}/api/users/{{user_id}}
headers:
  - Authorization: Bearer {{auth_token}}
```

**users/delete-user.volt:**
```yaml
name: Delete User
method: DELETE
url: {{base_url}}/api/users/{{user_id}}
headers:
  - Authorization: Bearer {{auth_token}}
```

Now create a workflow that ties them all together:

**user-lifecycle.workflow:**
```yaml
name: User Lifecycle Test

steps:
  - file: auth/login.volt
    name: Authenticate
    extract:
      auth_token: body.token

  - file: users/create-user.volt
    name: Create a new user
    condition: status == 200
    extract:
      user_id: body.id
      user_email: body.email

  - file: users/get-user.volt
    name: Verify user exists
    condition: status == 201
    delay: 500

  - file: users/delete-user.volt
    name: Clean up test user
    condition: status == 200
```

### Running a Workflow

```bash
volt workflow user-lifecycle.workflow
```

With an environment:

```bash
volt workflow user-lifecycle.workflow --env staging
```

### Workflow Output

Volt prints a step-by-step report:

```
--- Workflow Results ---

  Step 1: Authenticate [PASS]
    Status: 200 | Time: 234.5ms
    Extracted:
      auth_token = eyJhbGciOiJIUzI1NiJ9...

  Step 2: Create a new user [PASS]
    Status: 201 | Time: 156.2ms
    Extracted:
      user_id = 789
      user_email = newuser@example.com

  Step 3: Verify user exists [PASS]
    Status: 200 | Time: 89.1ms

  Step 4: Clean up test user [PASS]
    Status: 204 | Time: 67.3ms

--- Summary ---
  Steps:    4 total, 4 passed, 0 failed
  Duration: 1047.1ms
  Variables:
    auth_token = eyJhbGciOiJIUzI1NiJ9...
    user_id = 789
    user_email = newuser@example.com
```

If a step fails or its condition is not met, the workflow continues but marks that step as failed or skipped.

### Workflows vs. Collections

| Feature | Collection (`volt collection dir/`) | Workflow (`volt workflow file`) |
|---------|-------------------------------------|-------------------------------|
| File selection | All `.volt` files in directory | Explicitly listed files |
| Execution order | Alphabetical by filename | Order defined in workflow file |
| Variable passing | Via `post_script:` in each file | Via `extract:` in workflow + `post_script:` in files |
| Delays | Not supported | `delay:` per step |
| Conditionals | Not supported | `condition:` per step |
| Best for | Running an entire API test suite | Specific multi-step scenarios |

---

## 11. Practical Examples

### Example 1: Login and Use Token

The most common scripting pattern -- authenticate and reuse the token.

**login.volt:**
```yaml
name: Login to API
method: POST
url: https://api.example.com/auth/login
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "email": "user@example.com",
      "password": "s3cret"
    }
post_script: |
  assert.status 200
  assert.json access_token exists
  assert.json refresh_token exists

  extract access_token access_token
  extract refresh_token refresh_token
  extract token_expiry expires_in

  log Login successful
  log Token expires in:
  response.json expires_in
```

**get-profile.volt:**
```yaml
name: Get My Profile
method: GET
url: https://api.example.com/api/me
headers:
  - Authorization: Bearer {{access_token}}
post_script: |
  assert.status 200
  assert.json email equals user@example.com
  log Profile retrieved for:
  response.json name
```

### Example 2: Create Resource Then Verify It Exists

**create-item.volt:**
```yaml
name: Create Item
method: POST
url: https://api.example.com/api/items
headers:
  - Content-Type: application/json
  - Authorization: Bearer {{access_token}}
body:
  type: json
  content: |
    {
      "name": "Test Widget",
      "price": 29.99,
      "category": "electronics"
    }
post_script: |
  assert.status 201
  assert.json id exists
  assert.json name equals Test Widget

  extract item_id id
  log Created item with ID:
  response.json id
```

**verify-item.volt:**
```yaml
name: Verify Item Exists
method: GET
url: https://api.example.com/api/items/{{item_id}}
headers:
  - Authorization: Bearer {{access_token}}
post_script: |
  assert.status 200
  assert.json name equals Test Widget
  assert.json price equals 29.99
  assert.json category equals electronics

  log Item verified:
  response.json name
```

### Example 3: Pagination -- Extract Next Page URL

```yaml
name: Get Users (Page 1)
method: GET
url: https://api.example.com/api/users?page=1&limit=10
headers:
  - Authorization: Bearer {{access_token}}
post_script: |
  assert.status 200
  assert.json data exists
  assert.json pagination exists

  # Extract pagination details
  extract total_pages pagination.total_pages
  extract current_page pagination.current_page
  extract next_page_url pagination.next_url

  log Page:
  response.json pagination.current_page
  log Total pages:
  response.json pagination.total_pages
  log Next page URL extracted for chaining
```

Then a second request can use `{{next_page_url}}` directly:

```yaml
name: Get Users (Page 2)
method: GET
url: {{next_page_url}}
headers:
  - Authorization: Bearer {{access_token}}
post_script: |
  assert.status 200
  log Fetched next page of results
```

### Example 4: Generate Dynamic Auth Headers

Some APIs require a computed authorization header with a timestamp and nonce.

```yaml
name: Request with Dynamic Auth
method: GET
url: https://api.example.com/secure/data
pre_script: |
  # Generate a unique nonce
  uuid
  header X-Nonce $last

  # Add current timestamp
  timestamp
  header X-Timestamp $last

  # Encode API credentials
  base64.encode myapp:secret123
  header Authorization Basic $last

  log Dynamic auth headers set
post_script: |
  assert.status 200
  log Secure data retrieved successfully
```

### Example 5: Timestamp and Nonce Generation for HMAC APIs

```yaml
name: HMAC-Signed Request
method: POST
url: https://api.example.com/webhook
pre_script: |
  # Generate unique request identifiers
  timestamp
  env.set request_ts $last
  header X-Timestamp $last

  uuid
  env.set request_nonce $last
  header X-Nonce $last

  # Encode the payload signature
  base64.encode webhook-secret:{{request_ts}}:{{request_nonce}}
  header X-Signature $last

  log Request signed with timestamp and nonce
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "event": "order.created",
      "data": {
        "order_id": "12345"
      }
    }
post_script: |
  assert.status 200
  log Webhook delivered successfully
```

### Example 6: Conditional Assertions

```yaml
name: Create or Update User
method: PUT
url: https://api.example.com/api/users/{{user_id}}
headers:
  - Content-Type: application/json
  - Authorization: Bearer {{access_token}}
body:
  type: json
  content: |
    {
      "name": "Updated Name",
      "email": "updated@example.com"
    }
post_script: |
  # Handle both "created" and "updated" responses
  if status equals 201
  log User was created (new resource)

  if status equals 200
  log User was updated (existing resource)

  if status equals 409
  log Conflict -- user with this email already exists

  # Assert we got one of the success codes
  if status < 300
  extract user_id id

  if status >= 400
  log Request failed -- check the response body

  # Always log the status
  response.status
```

### Example 7: Multi-Environment API Smoke Test

This example shows a `.volt` file that works across all environments thanks to variable interpolation and scripts.

```yaml
name: API Health Check
method: GET
url: {{base_url}}/health
pre_script: |
  timestamp
  header X-Check-Time $last
  log Running health check against {{base_url}}
post_script: |
  assert.status 200
  assert.json status equals healthy
  assert.json version exists

  extract api_version version
  log API version:
  response.json version

  log Response time:
  response.time

  if status != 200
  log ALERT: Health check failed!
tests:
  - status equals 200
  - $.status equals healthy
```

Run against different environments:

```bash
volt run health-check.volt --env development
volt run health-check.volt --env staging
volt run health-check.volt --env production
```

### Example 8: Token Refresh Flow

A complete workflow for handling token refresh.

**refresh-token.workflow:**
```yaml
name: Token Refresh Flow

steps:
  - file: auth/login.volt
    name: Initial login
    extract:
      access_token: body.access_token
      refresh_token: body.refresh_token

  - file: api/get-data.volt
    name: Access protected resource
    condition: status == 200

  - file: auth/refresh.volt
    name: Refresh the access token
    condition: status == 200
    delay: 1000
    extract:
      access_token: body.access_token

  - file: api/get-data.volt
    name: Access resource with new token
    condition: status == 200
```

**auth/refresh.volt:**
```yaml
name: Refresh Token
method: POST
url: {{base_url}}/auth/refresh
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "refresh_token": "{{refresh_token}}"
    }
post_script: |
  assert.status 200
  assert.json access_token exists

  extract access_token access_token
  log Token refreshed successfully
```

---

## 12. Debugging Scripts

When a script does not behave as expected, the `log` command is your primary debugging tool. Since Volt's scripting engine is line-based and deterministic, strategic log statements will quickly reveal what is happening.

### Strategy 1: Log Before and After Key Operations

```yaml
post_script: |
  log === Starting post-response script ===

  log Checking status code...
  response.status

  log Extracting auth token...
  extract auth_token token
  log Token extracted (check if variable is set)

  log Checking JSON structure...
  response.json data.user.name

  log === Script complete ===
```

### Strategy 2: Dump the Full Response

When you are not sure what the API returned:

```yaml
post_script: |
  log --- Response Status ---
  response.status

  log --- Response Headers ---
  response.header content-type
  response.header x-request-id

  log --- Response Body ---
  response.body

  log --- Specific JSON Fields ---
  response.json data
  response.json data.token
  response.json error
  response.json message
```

### Strategy 3: Verify Variable Values

If a variable is not being resolved correctly, log each step of the extraction:

```yaml
post_script: |
  log Step 1: Checking if data field exists
  response.json data

  log Step 2: Checking if data.token exists
  response.json data.token

  log Step 3: Extracting token
  extract my_token data.token

  log Step 4: Verifying extraction
  env.get my_token
```

### Strategy 4: Use Assertions as Debug Probes

Even if you are not testing, assertions tell you the state of things:

```yaml
post_script: |
  # These will show PASS or FAIL in output
  assert.status 200
  assert.json data exists
  assert.json data.token exists
  assert.header content-type contains json
```

### Common Pitfalls

**Problem: Variable not being interpolated in the next request.**

- Make sure you used `extract`, `chain`, or `env.set` in the `post_script:` (not just `set`, which is local-only).
- Make sure the variable name in `extract token data.token` matches the `{{token}}` reference in the next file.
- Make sure you are running via `volt collection` or `volt workflow`, not individual `volt run` calls (runtime variables do not persist across separate `volt run` invocations).

**Problem: JSON path returns nothing.**

- Use `response.body` to see the raw response and verify the structure.
- Paths are dot-separated: `data.user.name`, not `data->user->name` or `data["user"]["name"]`.
- The path does not use `$` prefix -- use `data.token`, not `$.data.token`. (The `$` prefix is for the `tests:` section, not for scripting commands.)

**Problem: Pre-script header not appearing in the request.**

- Make sure the `header` command is in `pre_script:`, not `post_script:`.
- The header name is case-sensitive in the `header` command.

**Problem: Assertion says it failed but the value looks correct.**

- The `equals` operator does an **exact string match**. If the response has `"200"` and you assert `equals 200`, it will pass because the engine compares string representations. But if the response has `"200 "` (with a trailing space), it will fail. Use `contains` for looser matching.

---

## 13. Script Best Practices

### Keep Scripts Short and Focused

A script should do one logical thing. If your post_script is 50 lines long, consider splitting the workflow into multiple `.volt` files with simpler scripts in each.

```yaml
# Good: focused script
post_script: |
  assert.status 200
  extract token data.access_token
  log Token acquired

# Avoid: doing too much in one script
post_script: |
  assert.status 200
  assert.json data exists
  assert.json data.token exists
  assert.json data.user exists
  assert.json data.user.name exists
  assert.json data.user.email exists
  assert.json data.permissions exists
  extract token data.token
  extract user_id data.user.id
  extract user_name data.user.name
  extract user_email data.user.email
  extract role data.user.role
  extract permissions data.permissions
  env.set session_token token
  env.set current_user user_id
  log Got everything
```

### Use Meaningful Variable Names

Variable names carry data between requests. Make them self-documenting:

```yaml
# Good
extract auth_token data.access_token
extract created_user_id data.id
extract next_page_cursor pagination.cursor

# Avoid
extract t data.access_token
extract x data.id
extract c pagination.cursor
```

### Always Assert Before Extracting

If the response is an error, extracting fields will silently fail or extract wrong data. Assert the status first:

```yaml
post_script: |
  # Check status first
  assert.status 200

  # Then extract (only makes sense if status is 200)
  extract token data.token
```

### Use Comments to Document Intent

Scripts are code -- document them:

```yaml
post_script: |
  # Verify the registration succeeded
  assert.status 201

  # Save the new user's ID so we can verify their profile next
  extract new_user_id data.id

  # Save the activation link for the email verification step
  extract activation_url data.activation_link
```

### Combine `tests:` and `post_script:` Effectively

Use `tests:` for simple, declarative assertions. Use `post_script:` for extraction and anything that needs sequencing:

```yaml
# Declarative tests -- clean and easy to read
tests:
  - status equals 200
  - $.data.name equals Alice
  - $.data.email exists

# Script -- for extraction and chaining
post_script: |
  extract user_id data.id
  extract user_email data.email
  log User data extracted for next request
```

### Use Workflows for Complex Scenarios

If you have more than 3-4 steps that need to run in sequence with conditions and delays, a workflow file is cleaner than a collection of numbered files:

```yaml
# user-crud.workflow -- clear and explicit
name: User CRUD Lifecycle

steps:
  - file: auth/login.volt
    name: Authenticate
    extract:
      token: body.access_token

  - file: users/create.volt
    name: Create user
    condition: status == 200
    extract:
      user_id: body.id

  - file: users/read.volt
    name: Verify user created
    condition: status == 201

  - file: users/update.volt
    name: Update user profile
    condition: status == 200

  - file: users/delete.volt
    name: Clean up
    condition: status == 200
    delay: 200
```

### Do Not Put Secrets in Scripts

Never hard-code secrets in scripts. Use environment variables:

```yaml
# Bad
pre_script: |
  base64.encode admin:supersecretpassword
  header Authorization Basic $last

# Good -- use environment variables
pre_script: |
  base64.encode {{$username}}:{{$password}}
  header Authorization Basic $last
```

Store the actual credentials in `_env.volt` (which should be in your `.gitignore`):

```yaml
environment: development
variables:
  $username: admin
  $password: supersecretpassword
```

---

## Quick Reference Card

A condensed reference you can keep open while writing scripts.

### Pre-Script Commands

| Command | Description |
|---------|-------------|
| `env.set <key> <value>` | Set environment variable |
| `env.get <key>` | Get env var (into `$last`) |
| `env.delete <key>` | Delete environment variable |
| `set <var> <value>` | Set local variable |
| `header <name> <value>` | Add/set request header |
| `base64.encode <value>` | Base64 encode (into `$last`) |
| `base64.decode <value>` | Base64 decode (into `$last`) |
| `uuid` | Generate UUID (into `$last`) |
| `timestamp` | Unix timestamp (into `$last`) |
| `sleep <ms>` | Pause for N milliseconds |
| `log <message>` | Print to console |
| `if <field> <op> <val>` | Conditional (next line only) |

### Post-Script Commands

All pre-script commands, plus:

| Command | Description |
|---------|-------------|
| `response.status` | Print status code |
| `response.body` | Print full response body |
| `response.header <name>` | Print response header |
| `response.json <path>` | Print/extract JSON value |
| `response.time` | Print response time (ms) |
| `extract <var> <path>` | Extract JSON value as variable |
| `chain <var> <path>` | Alias for `extract` |
| `assert.status <code>` | Assert status code |
| `assert.header <n> <op> <v>` | Assert header value |
| `assert.body <op> <v>` | Assert body content |
| `assert.json <path> <op> <v>` | Assert JSON value |
| `expect <field> <op> <val>` | General assertion |
| `test "name" { ... }` | Named test block |

### Operators

| Operator | Description |
|----------|-------------|
| `equals` / `==` | Exact match |
| `!=` | Not equal |
| `contains` | Substring present |
| `startsWith` | Starts with |
| `endsWith` | Ends with |
| `exists` | Non-empty value |
| `matches` | Pattern found |

---

## Further Reading

- **[Getting Started](getting-started.md)** -- if you are new to Volt, start here.
- **[Testing Guide](testing.md)** -- deep dive into the `tests:` section and test reporting.
- **[Environments & Configuration](environments.md)** -- how variables, environments, and resolution order work.
- **[Command Reference](commands.md)** -- every CLI command with full usage examples.
- **[.volt File Format](volt-file-format.md)** -- complete specification for the `.volt` file format.
