---
layout: page
title: Testing Guide
---

# Testing Guide

A complete guide to testing APIs with Volt -- from your first assertion to data-driven test suites in CI/CD pipelines.

---

## Why Test APIs?

If you build or consume APIs, testing them is one of the most valuable habits you can develop. Here is why:

**Catch bugs before users do.** An API test can verify that your endpoint returns the right status code, the right data shape, and the right values. If someone changes the backend and breaks the contract, your tests fail immediately -- not after a customer files a bug report.

**Confidence during refactoring.** When you rewrite an endpoint or swap a database, a passing test suite tells you that everything still works the same way from the outside.

**Documentation that runs.** A `.volt` test file is both a specification of what the API should do and a runnable check that it actually does it. New team members can read your test files to understand the API.

**Faster development cycles.** Instead of manually opening a browser or Postman every time you change something, run `volt test` and get instant feedback in your terminal.

**CI/CD integration.** Automated API tests in your pipeline catch regressions on every pull request, before code reaches production.

Volt makes all of this easy. Tests live inside the same `.volt` files as your requests -- no separate test framework, no extra dependencies, no configuration.

---

## Your First Test

Create a file called `health-check.volt`:

```yaml
name: Health Check
method: GET
url: https://httpbin.org/get
headers:
  - Accept: application/json
tests:
  - status equals 200
```

Run it:

```bash
volt test health-check.volt
```

Output:

```
health-check.volt
  ✓ status equals 200

1 passed, 0 failed
```

That is it. You wrote a test that sends a GET request and verifies the server responds with HTTP 200. If the server is down or returns a different status code, the test fails.

---

## Test Assertion Syntax

Every test assertion in Volt follows this format:

```
- <field> <operator> <value>
```

Assertions go under the `tests:` section of a `.volt` file, each prefixed with `- ` (a dash and a space):

```yaml
tests:
  - status equals 200
  - body contains "users"
  - header.content-type contains json
  - $.name equals Alice
```

The three parts are:

| Part | Description | Examples |
|------|-------------|----------|
| **field** | What to check in the response | `status`, `body`, `header.content-type`, `$.user.name` |
| **operator** | How to compare | `equals`, `!=`, `<`, `>`, `contains`, `exists` |
| **value** | The expected value | `200`, `Alice`, `json` |

Some operators (like `exists`) do not require a value.

---

## Fields You Can Test

### `status` -- HTTP Status Code

The numeric HTTP status code of the response (200, 201, 404, 500, etc.).

```yaml
tests:
  - status equals 200
  - status equals 201
  - status != 404
  - status < 400
  - status > 199
```

This is the most common assertion. Almost every test file should check the status code.

### `body` -- Full Response Body

The entire response body as a text string. Useful for checking that the response contains certain keywords or matches an exact value.

```yaml
tests:
  - body contains "users"
  - body contains "success"
  - body equals OK
```

**Tip:** The `body contains` assertion is useful when you want to verify that a word or phrase appears somewhere in the response without caring about the exact structure.

### `header.<name>` -- Response Headers

Check the value of a specific response header. The header name is case-insensitive.

```yaml
tests:
  - header.content-type contains json
  - header.content-type equals application/json; charset=utf-8
  - header.cache-control contains max-age
  - header.x-request-id contains -
```

The pattern is `header.` followed by the header name. Volt looks up the header in the response and applies the operator to its value.

**Note:** If the header does not exist in the response, the assertion fails (returns false). This means `header.x-missing-header contains anything` will fail, which is effectively an existence check.

### `$.<jsonpath>` -- JSONPath Into JSON Body

For JSON responses, you can drill into the response body using JSONPath expressions. This is the most powerful assertion type.

```yaml
tests:
  - $.name equals Alice
  - $.address.city equals New York
  - $.users[0].email equals alice@example.com
  - $.tags[*] equals 3
  - $.id exists
```

JSONPath is covered in detail in the next section.

---

## Operators

Volt supports six comparison operators.

### `equals` (or `==`) -- Exact Match

Checks that the actual value is exactly equal to the expected value. Works with status codes, body text, headers, and JSONPath values.

```yaml
tests:
  - status equals 200
  - status == 200
  - $.name equals Alice
  - $.name == Alice
  - header.content-type equals application/json
  - body equals {"status":"ok"}
```

`equals` and `==` are interchangeable -- use whichever you prefer.

### `!=` -- Not Equal

Checks that the actual value does NOT match the expected value.

```yaml
tests:
  - status != 500
  - status != 404
  - $.role != guest
  - $.status != error
```

Useful for "negative" tests -- verifying that something bad is NOT happening.

### `<` -- Less Than

Checks that the actual numeric value is less than the expected value. Primarily used with status codes.

```yaml
tests:
  - status < 300
  - status < 400
```

**Example use case:** "The response is not an error" -- `status < 400` passes for any 1xx, 2xx, or 3xx status code.

### `>` -- Greater Than

Checks that the actual numeric value is greater than the expected value.

```yaml
tests:
  - status > 199
  - status > 100
```

**Example use case:** "The response is not informational" -- `status > 199` passes for 200 and above.

### `contains` -- Substring Match

Checks that the actual value contains the expected value as a substring. Works with body text, headers, and JSONPath string values.

```yaml
tests:
  - body contains "success"
  - body contains user_id
  - header.content-type contains json
  - header.content-type contains utf-8
  - $.description contains important
```

This is more flexible than `equals` because it does not require an exact match. If the Content-Type header is `application/json; charset=utf-8`, the assertion `header.content-type contains json` still passes.

### `exists` -- Value Exists

Checks that a JSONPath field exists in the response body. Does not require a value argument.

```yaml
tests:
  - $.id exists
  - $.created_at exists
  - $.user.email exists
  - $.data[0] exists
```

This is useful when you want to verify the shape of a JSON response without caring about specific values. For example, you might not know what `id` the server will assign, but you want to confirm that it returns one.

---

## JSONPath Assertions -- Deep Dive

JSONPath lets you reach into a JSON response and extract specific values for testing. Volt supports the most common JSONPath patterns.

### Simple Field Access: `$.field`

Access a top-level field in a JSON object.

**Response:**
```json
{
  "id": 42,
  "name": "Alice",
  "email": "alice@example.com",
  "active": true
}
```

**Tests:**
```yaml
tests:
  - $.id equals 42
  - $.name equals Alice
  - $.email equals alice@example.com
  - $.active equals true
```

### Nested Field Access: `$.parent.child`

Chain field names with dots to access nested objects.

**Response:**
```json
{
  "user": {
    "name": "Bob",
    "address": {
      "street": "123 Main St",
      "city": "Portland",
      "state": "OR"
    }
  }
}
```

**Tests:**
```yaml
tests:
  - $.user.name equals Bob
  - $.user.address.city equals Portland
  - $.user.address.state equals OR
  - $.user.address.street contains Main
```

You can nest as deeply as your JSON goes.

### Array Index Access: `$.array[N]`

Access a specific element in a JSON array by its zero-based index.

**Response:**
```json
{
  "users": [
    { "id": 1, "name": "Alice", "role": "admin" },
    { "id": 2, "name": "Bob", "role": "editor" },
    { "id": 3, "name": "Charlie", "role": "viewer" }
  ]
}
```

**Tests:**
```yaml
tests:
  - $.users[0].name equals Alice
  - $.users[0].role equals admin
  - $.users[1].name equals Bob
  - $.users[2].id equals 3
```

Remember: array indices start at 0. The first element is `[0]`, the second is `[1]`, and so on.

### Array Wildcard: `$.array[*]`

The wildcard `[*]` returns the count of elements in an array (as a string).

**Response:**
```json
{
  "tags": ["api", "rest", "http", "testing"]
}
```

**Tests:**
```yaml
tests:
  - $.tags[*] equals 4
```

This is handy for verifying that an endpoint returns the expected number of items.

### Combining Everything -- Real-World Example

Here is a complete test file for a user API endpoint:

```yaml
name: Get User Profile
method: GET
url: https://api.example.com/users/1
headers:
  - Accept: application/json
  - Authorization: Bearer {{api_token}}
tests:
  # Status and content type
  - status equals 200
  - header.content-type contains json

  # Verify required fields exist
  - $.id exists
  - $.name exists
  - $.email exists
  - $.created_at exists

  # Verify specific values
  - $.id equals 1
  - $.name equals Leanne Graham
  - $.email contains @

  # Verify nested data
  - $.address.city equals Gwenborough
  - $.company.name equals Romaguera-Crona

  # Verify array length
  - $.roles[*] equals 2

  # Verify no error
  - $.error != true
```

### JSONPath with Existence Checks

When you test an API that generates dynamic values (UUIDs, timestamps, auto-incremented IDs), you cannot predict the exact value. Use `exists` to verify the field is present:

```yaml
name: Create User
method: POST
url: https://api.example.com/users
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "name": "New User",
      "email": "newuser@example.com"
    }
tests:
  - status equals 201
  - $.id exists
  - $.created_at exists
  - $.name equals New User
```

---

## Running Tests

### Test a Single File

```bash
volt test api/get-users.volt
```

Sends the request defined in the file, then evaluates every assertion in the `tests:` section.

### Test All Files in a Directory

```bash
volt test api/
```

Finds every `.volt` file in the `api/` directory (excluding files prefixed with `_`, like `_env.volt` and `_collection.volt`) and runs their tests.

### Test Everything in the Current Directory

```bash
volt test
```

With no arguments, Volt tests all `.volt` files in the current directory.

### Example Output

```
api/health.volt
  ✓ status equals 200
  ✓ header.content-type contains json

api/users.volt
  ✓ status equals 200
  ✓ $.name equals Leanne Graham
  ✓ $.email equals Sincere@april.biz
  ✗ $.phone equals 555-1234
    expected: 555-1234
    actual:   1-770-736-8031 x56442

api/create-post.volt
  ✓ status equals 201
  ✓ $.id exists

7 passed, 1 failed
```

Volt uses green checkmarks for passing tests and red crosses for failures. When a test fails, it shows what was expected and what was actually received, so you can diagnose the problem immediately.

---

## Watch Mode

During development, you often want to re-run tests every time you change a file. Watch mode does this automatically:

```bash
volt test --watch
```

This runs your test suite, then waits. When you save changes to any `.volt` file, Volt re-runs the tests. Press `Ctrl+C` to stop.

You can also watch a specific file or directory:

```bash
volt test api/users.volt --watch
volt test api/ --watch
```

Watch mode is similar to `jest --watch` or `pytest-watch`. It keeps running in your terminal and gives you instant feedback as you edit your request files.

For more granular file watching (with custom intervals), you can also use:

```bash
volt watch api/ --test                 # Re-run tests on any file change
volt watch api/health.volt             # Watch a single file
volt watch api/ --interval 2000        # Custom poll interval (ms)
```

---

## Data-Driven Testing

Data-driven testing (also called parameterized testing) lets you run the same request multiple times with different input data. Instead of copying a `.volt` file ten times with slightly different values, you write one template and feed it a data file.

### Step 1: Create a Template

Create a `.volt` file with `{{variable}}` placeholders:

`create-user.volt`:
```yaml
name: Create User - {{username}}
method: POST
url: https://api.example.com/users
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "username": "{{username}}",
      "email": "{{email}}",
      "role": "{{role}}"
    }
tests:
  - status equals {{expected_status}}
```

### Step 2: Create a Data File (CSV)

`users.csv`:
```csv
username,email,role,expected_status
alice,alice@example.com,admin,201
bob,bob@example.com,editor,201
charlie,charlie@example.com,viewer,201
,missing@example.com,viewer,400
duplicate,alice@example.com,admin,409
```

Each row becomes one test run. The column headers (`username`, `email`, `role`, `expected_status`) match the `{{variable}}` names in the template.

### Step 3: Run the Tests

```bash
volt test create-user.volt --data users.csv
```

Volt runs the request five times -- once for each row of data -- substituting the variables each time:

```
create-user.volt [row 1: alice]
  ✓ status equals 201

create-user.volt [row 2: bob]
  ✓ status equals 201

create-user.volt [row 3: charlie]
  ✓ status equals 201

create-user.volt [row 4: ]
  ✓ status equals 400

create-user.volt [row 5: duplicate]
  ✓ status equals 409

5 passed, 0 failed
```

### Using JSON Data Files

You can also use a JSON array instead of CSV. Create `users.json`:

```json
[
  {
    "username": "alice",
    "email": "alice@example.com",
    "role": "admin",
    "expected_status": "201"
  },
  {
    "username": "bob",
    "email": "bob@example.com",
    "role": "editor",
    "expected_status": "201"
  },
  {
    "username": "",
    "email": "missing@example.com",
    "role": "viewer",
    "expected_status": "400"
  }
]
```

Run the same way:

```bash
volt test create-user.volt --data users.json
```

Volt auto-detects the format from the file extension (`.csv` or `.json`).

### When to Use Data-Driven Testing

- **Input validation testing** -- test valid and invalid inputs in one pass
- **User role testing** -- verify different permissions with different credentials
- **Edge cases** -- empty strings, special characters, boundary values
- **Multi-tenant testing** -- same request against different tenants or environments
- **Regression testing** -- run known good inputs and verify outputs match

---

## Test Reports

Volt can generate test reports in three formats for sharing, archiving, or CI/CD integration.

### JUnit XML Report

JUnit XML is the industry standard for CI/CD pipelines. GitHub Actions, GitLab CI, Jenkins, Azure DevOps, CircleCI, and nearly every CI tool can parse it.

```bash
volt test api/ --report junit -o results.xml
```

This runs all tests and writes a JUnit XML file:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="api/users.volt" tests="3" failures="0" time="0.234">
    <testcase name="status equals 200" classname="api/users.volt" time="0.234"/>
    <testcase name="$.name equals Alice" classname="api/users.volt" time="0.234"/>
    <testcase name="header.content-type contains json" classname="api/users.volt" time="0.234"/>
  </testsuite>
</testsuites>
```

### HTML Report

For human-readable reports you can share with your team or attach to a pull request:

```bash
volt test api/ --report html -o report.html
```

This generates a self-contained HTML file with a dark theme, summary cards (total, passed, failed, timing), and a detailed result list. No external CSS or JavaScript dependencies -- just open the file in a browser.

The HTML report includes:
- Summary cards with total, passed, failed, and timing
- Color-coded pass/fail indicators for each assertion
- Expected vs. actual values for failed tests
- File names and assertion expressions

### JSON Report

For custom tooling, dashboards, or programmatic analysis:

```bash
volt test api/ --report json -o results.json
```

Output structure:

```json
{
  "summary": {
    "total": 5,
    "passed": 4,
    "failed": 1,
    "time_ms": 523.40
  },
  "results": [
    {
      "file": "api/users.volt",
      "test_name": "status equals 200",
      "passed": true,
      "time_ms": 120.50
    },
    {
      "file": "api/users.volt",
      "test_name": "$.phone equals 555-1234",
      "passed": false,
      "time_ms": 120.50,
      "expected": "555-1234",
      "actual": "1-770-736-8031 x56442"
    }
  ]
}
```

You can pipe the JSON report into `jq`, import it into a database, or feed it to a custom dashboard.

### Combining Reports with Other Flags

Reports work alongside other test features:

```bash
# Data-driven tests with JUnit output
volt test template.volt --data data.csv --report junit -o results.xml

# Watch mode does not support reports (reports are snapshot-based)
# Use reports in CI, use watch mode in development
```

---

## Auto-Generate Tests

If you already have a working `.volt` file but no tests, Volt can generate test assertions automatically by analyzing the actual response:

```bash
volt generate api/users.volt -o users-test.volt
```

Volt sends the request, inspects the response, and generates assertions with confidence scores:

```
Generated Tests

  [100%] status equals 200                    (status)
  [70%]  timing < 2000                        (timing)
  [95%]  header.content-type contains json     (content-type)
  [80%]  body contains id                      (body-schema)
  [80%]  body contains name                    (body-schema)
  [85%]  body contains {                       (body-content)
  [60%]  header.cache-control exists           (header)

  Total: 7 assertions | 3 JSON fields detected
```

The generated file (`users-test.volt`) contains the original request plus all the generated assertions. You can then review it, remove assertions you do not want, adjust expected values, and commit it to your repository.

**What gets generated:**
- Status code check (always, 100% confidence)
- Response time threshold (if response was reasonably fast)
- Content-Type header assertion
- JSON field existence checks (for JSON responses)
- Body content assertions
- Important header presence checks (like `cache-control`)

This is a great starting point. Auto-generated tests capture the current behavior of your API, which you can then refine into a proper test suite.

---

## JSON Schema Validation

Beyond simple assertions, Volt can validate entire response bodies against JSON schemas.

### Validate Against a Schema

Create a JSON Schema file, `user-schema.json`:

```json
{
  "type": "object",
  "required": ["id", "name", "email"],
  "properties": {
    "id": { "type": "number" },
    "name": { "type": "string" },
    "email": { "type": "string" },
    "active": { "type": "boolean" },
    "tags": { "type": "array" }
  }
}
```

Validate a response against it:

```bash
volt validate api/users.volt --schema user-schema.json
```

Volt sends the request, then checks the response body against the schema. It reports:
- Missing required fields
- Type mismatches (expected string, got number)
- Unexpected field types
- Field count statistics

### Infer a Schema from a Response

If you do not have a schema yet, Volt can infer one from the actual response:

```bash
volt validate api/users.volt --infer
```

This sends the request, analyzes the response body, and prints the inferred JSON schema. You can redirect this to a file and then edit it:

```bash
volt validate api/users.volt --infer > user-schema.json
```

This is useful when you are starting a new project and want to lock down the response format.

---

## Load Testing and Benchmarking

Volt includes a built-in load tester for quick performance checks.

### Basic Benchmark

```bash
volt bench api/health.volt -n 100
```

This sends 100 requests to the endpoint and reports:

```
Benchmark: api/health.volt
  Total requests:  100
  Successful:      98
  Failed:          2
  Total time:      4.23s
  Requests/sec:    23.64

Latency:
  Min:     45.2ms
  Max:     892.1ms
  Avg:     187.3ms
  p50:     152.0ms
  p95:     456.7ms
  p99:     891.2ms

Status codes:
  200: 98
  503: 2
```

### Concurrent Requests

Add the `-c` flag to send requests concurrently:

```bash
volt bench api/health.volt -n 200 -c 20
```

This sends 200 total requests with 20 running concurrently. This simulates what happens when 20 users hit your endpoint at the same time.

### Understanding Percentiles

The benchmark output includes percentile statistics:

| Metric | Meaning |
|--------|---------|
| **p50** (median) | 50% of requests were faster than this. This is your "typical" response time. |
| **p95** | 95% of requests were faster than this. This captures most users' experience. |
| **p99** | 99% of requests were faster than this. This catches outliers and worst-case latency. |

**Rules of thumb:**
- If p50 is good but p99 is bad, you have occasional slow requests (maybe database locks, cold caches, or garbage collection pauses).
- If p50 and p99 are both bad, the endpoint is consistently slow.
- For user-facing APIs, aim for p95 < 500ms and p99 < 1000ms.

### Benchmark Examples

```bash
# Quick smoke test: 10 requests
volt bench api/health.volt -n 10

# Moderate load: 500 requests, 50 concurrent
volt bench api/health.volt -n 500 -c 50

# Stress test: 1000 requests, 100 concurrent
volt bench api/health.volt -n 1000 -c 100
```

---

## Endpoint Monitoring

Monitor an endpoint's health over time with periodic checks:

```bash
volt monitor api/health.volt -i 30 -n 100
```

| Flag | Meaning |
|------|---------|
| `-i 30` | Check every 30 seconds |
| `-n 100` | Run 100 checks total |

Volt sends the request repeatedly and tracks:

- **Uptime percentage** -- what fraction of checks returned a healthy response
- **Latency statistics** -- min, max, average response time
- **Consecutive failures** -- how many checks in a row have failed
- **Status code history** -- which status codes were returned

This is useful for:
- **Pre-release verification** -- monitor staging after a deploy
- **On-call investigation** -- watch an endpoint you suspect is flaky
- **SLA validation** -- measure uptime over a period

```bash
# Check every 60 seconds indefinitely (Ctrl+C to stop)
volt monitor api/health.volt -i 60

# Quick 5-minute check: every 10 seconds, 30 checks
volt monitor api/health.volt -i 10 -n 30
```

---

## Collection Testing

A collection is a directory of `.volt` files that run together in sequence. Collections support variable chaining -- values extracted from one response can be used in the next request.

### Setting Up a Collection

Organize your files with numeric prefixes to control execution order:

```
api/
  _env.volt                  # Environment variables (not executed)
  _collection.volt           # Shared config (not executed)
  01-login.volt              # Step 1: Authenticate
  02-get-profile.volt        # Step 2: Get user profile
  03-update-profile.volt     # Step 3: Update profile
  04-verify-update.volt      # Step 4: Verify the update worked
```

Files prefixed with `_` are configuration files and are skipped during execution. The remaining files are executed alphabetically.

### Variable Chaining Between Requests

In a collection, variables set by one request carry forward to the next. Use `post_script` to extract values:

`01-login.volt`:
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
      "email": "admin@example.com",
      "password": "secret123"
    }
tests:
  - status equals 200
  - $.token exists
post_script: |
  extract auth_token $.token
```

`02-get-profile.volt`:
```yaml
name: Get My Profile
method: GET
url: {{base_url}}/users/me
headers:
  - Authorization: Bearer {{auth_token}}
tests:
  - status equals 200
  - $.name exists
  - $.email equals admin@example.com
post_script: |
  extract user_id $.id
```

`03-update-profile.volt`:
```yaml
name: Update Profile
method: PATCH
url: {{base_url}}/users/{{user_id}}
headers:
  - Content-Type: application/json
  - Authorization: Bearer {{auth_token}}
body:
  type: json
  content: |
    {
      "name": "Updated Name"
    }
tests:
  - status equals 200
  - $.name equals Updated Name
```

### Running a Collection

```bash
volt collection api/
```

Volt runs each file in order. The `auth_token` extracted in step 1 is automatically available in step 2, and `user_id` from step 2 flows into step 3. If any request fails, the collection continues but reports the failure.

### Collection Output

```
Collection: api/

  01-login.volt .............. 200 OK (234ms)
    ✓ status equals 200
    ✓ $.token exists

  02-get-profile.volt ........ 200 OK (156ms)
    ✓ status equals 200
    ✓ $.name exists
    ✓ $.email equals admin@example.com

  03-update-profile.volt ..... 200 OK (198ms)
    ✓ status equals 200
    ✓ $.name equals Updated Name

Summary:
  3 requests | 3 successful | 0 failed
  7 tests    | 7 passed     | 0 failed
  Total time: 588ms
```

---

## Pre/Post Scripts

Volt includes a scripting engine for more advanced test workflows. Scripts run before (`pre_script`) or after (`post_script`) the HTTP request.

### Common Script Commands

```yaml
pre_script: |
  log Starting request
  env.set request_time $timestamp
  set correlation_id $uuid

post_script: |
  extract user_id $.id
  extract auth_token $.token
  assert.status 200
  assert.json $.name == Alice
  log User ID: $user_id
```

### Available Commands

| Command | Description |
|---------|-------------|
| `env.set <key> <value>` | Set an environment variable |
| `env.get <key>` | Get an environment variable |
| `extract <var> <jsonpath>` | Extract a value from the response body |
| `chain <var> <jsonpath>` | Extract and set for the next request |
| `assert.status <code>` | Assert the response status code |
| `assert.json <path> <op> <val>` | Assert a JSON value |
| `assert.header <name> <op> <val>` | Assert a header value |
| `assert.body <op> <val>` | Assert body content |
| `log <message>` | Print a message to the console |
| `set <var> <value>` | Set a local variable |
| `base64.encode <value>` | Base64-encode a value |
| `base64.decode <value>` | Base64-decode a value |
| `timestamp` | Get the current Unix timestamp |
| `uuid` | Generate a UUID |
| `sleep <ms>` | Pause for N milliseconds |
| `test <name> { ... }` | Define a named test block |

### Named Test Blocks

You can group assertions into named test blocks for better organization:

```yaml
post_script: |
  test "Response structure" {
    assert.status 200
    assert.json $.id exists
    assert.json $.name exists
  }
  test "Business logic" {
    assert.json $.role == admin
    assert.json $.active == true
  }
```

---

## CI/CD Integration

Volt is designed to work seamlessly in CI/CD pipelines. For detailed setup instructions for your specific CI provider, see the [CI/CD Guide](ci-cd.md).

### Quick Setup

The simplest approach is to generate a JUnit XML report, which every major CI system can parse:

```bash
volt test api/ --report junit -o test-results.xml
```

### GitHub Actions Example

```yaml
name: API Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        run: curl -fsSL https://raw.githubusercontent.com/volt-api/volt/main/scripts/install.sh | bash

      - name: Run API tests
        run: volt test api/ --report junit -o test-results.xml

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: test-results.xml
```

### Auto-Detect CI Environment

Volt can automatically detect your CI environment and output the appropriate format:

```bash
volt ci
```

This detects GitHub Actions, GitLab CI, Jenkins, Azure DevOps, CircleCI, Travis CI, and Bitbucket Pipelines -- and outputs results in the format each platform expects.

### Exit Codes

Volt uses meaningful exit codes for CI integration:

| Exit Code | Meaning |
|-----------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed |

When using `--check-status` with `volt run`:

| Exit Code | Meaning |
|-----------|---------|
| 0 | Success (2xx) |
| 2 | Request timeout |
| 3 | 3xx redirect (not followed) |
| 4 | 4xx client error |
| 5 | 5xx server error |
| 6 | Connection failed |
| 7 | TLS error |

---

## Best Practices

### 1. Always Test the Status Code

Every test file should start with a status code assertion. It is the most basic and most important check:

```yaml
tests:
  - status equals 200
```

### 2. Test Structure Before Values

Check that required fields exist before checking their values. This gives better error messages when the API changes:

```yaml
tests:
  - status equals 200
  - $.id exists
  - $.name exists
  - $.name equals Alice
```

If the `name` field is removed entirely, the `exists` test gives a clear signal. If you only had the `equals` test, the error message would be less obvious.

### 3. Use `contains` for Volatile Content

If a response includes timestamps, UUIDs, or other dynamic content, use `contains` instead of `equals` to avoid brittle tests:

```yaml
# Brittle -- fails if anything in the body changes:
tests:
  - body equals {"id":1,"name":"Alice","updated_at":"2026-02-22T10:00:00Z"}

# Resilient -- passes as long as the important parts are there:
tests:
  - $.id equals 1
  - $.name equals Alice
  - $.updated_at exists
```

### 4. Name Your Request Files Descriptively

Use clear file names that describe what the request does:

```
api/
  get-all-users.volt        # Good
  create-user.volt          # Good
  delete-user-by-id.volt    # Good
  test1.volt                # Bad -- what does it test?
  request.volt              # Bad -- what request?
```

### 5. Use Numeric Prefixes for Collections

When running collections, files execute alphabetically. Use numeric prefixes to control the order:

```
api/
  01-login.volt
  02-get-profile.volt
  03-update-profile.volt
  04-delete-account.volt
```

### 6. Keep Tests Close to Requests

Put test assertions in the same `.volt` file as the request. This keeps everything in one place and makes it easy to understand what each request is supposed to do.

### 7. Test Error Cases Too

Do not only test the happy path. Verify that your API returns proper errors:

```yaml
name: Missing auth returns 401
method: GET
url: https://api.example.com/protected
tests:
  - status equals 401
```

```yaml
name: Invalid input returns 400
method: POST
url: https://api.example.com/users
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "email": "not-an-email"
    }
tests:
  - status equals 400
  - body contains "validation"
```

### 8. Use Environment Variables for URLs and Secrets

Never hardcode base URLs or API keys in test files. Use environment variables so the same tests work across development, staging, and production:

```yaml
method: GET
url: {{base_url}}/users
auth:
  type: bearer
  token: {{api_token}}
tests:
  - status equals 200
```

### 9. Generate Reports in CI, Use Watch Mode Locally

- **Local development:** `volt test --watch` for instant feedback
- **CI pipelines:** `volt test --report junit -o results.xml` for integration with CI dashboards

### 10. Start Small, Then Expand

You do not need to test everything at once. Start with status code checks, then add content type assertions, then JSONPath assertions. Build your test suite incrementally as you gain confidence.

---

## Quick Reference

### Assertion Cheat Sheet

```yaml
tests:
  # Status code
  - status equals 200
  - status == 201
  - status != 500
  - status < 400
  - status > 199

  # Response body
  - body contains success
  - body equals OK

  # Response headers
  - header.content-type contains json
  - header.content-type equals application/json
  - header.cache-control contains max-age

  # JSONPath -- simple field
  - $.name equals Alice
  - $.active equals true
  - $.count equals 42

  # JSONPath -- nested
  - $.user.address.city equals Portland

  # JSONPath -- array
  - $.users[0].name equals Alice
  - $.tags[*] equals 5
  - $.items[2].id exists

  # JSONPath -- existence
  - $.id exists
  - $.created_at exists

  # JSONPath -- not equal
  - $.status != error
  - $.role != guest

  # JSONPath -- contains
  - $.description contains important
```

### CLI Cheat Sheet

```bash
# Run tests
volt test                                  # All .volt files in current dir
volt test file.volt                        # Single file
volt test api/                             # All files in directory
volt test --watch                          # Watch mode

# Data-driven
volt test template.volt --data data.csv    # CSV data source
volt test template.volt --data data.json   # JSON data source

# Reports
volt test --report junit -o results.xml    # JUnit XML
volt test --report html -o report.html     # HTML report
volt test --report json -o results.json    # JSON report

# Generate tests
volt generate api/users.volt -o tests.volt # Auto-generate assertions

# Schema validation
volt validate file.volt --schema schema.json  # Validate against schema
volt validate file.volt --infer               # Infer schema from response

# Benchmarking
volt bench file.volt -n 100               # 100 requests
volt bench file.volt -n 200 -c 20         # 200 requests, 20 concurrent

# Monitoring
volt monitor file.volt -i 30 -n 100       # Every 30s, 100 checks

# Collections
volt collection api/                       # Run collection in order

# CI
volt ci                                    # Auto-detect CI environment
```
