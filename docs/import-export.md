---
layout: page
title: Import & Export
---

# Import & Export Guide

Volt speaks the same language as the tools you already use. Whether you are migrating from Postman, converting a cURL command from Stack Overflow, ingesting an OpenAPI spec, or generating production-ready code in 16+ programming languages, Volt has you covered.

This guide walks you through every import and export feature, with complete examples and tips for common workflows.

---

## Table of Contents

- [Why Switch to Volt?](#why-switch-to-volt)
- [Importing](#importing)
  - [From Postman](#importing-from-postman)
  - [From cURL](#importing-from-curl)
  - [From OpenAPI / Swagger](#importing-from-openapi--swagger)
  - [From Insomnia](#importing-from-insomnia)
  - [From HAR Files](#importing-from-har-files)
- [Exporting](#exporting)
  - [To Code (16+ Languages)](#exporting-to-code)
  - [To OpenAPI](#exporting-to-openapi)
  - [To HAR](#exporting-to-har)
- [API Documentation Generation](#api-documentation-generation)
- [OpenAPI Design-First Workflow](#openapi-design-first-workflow)
- [Bulk Migration Tips](#bulk-migration-tips)

---

## Why Switch to Volt?

If you are currently using Postman, Insomnia, or another GUI-based API client, here are some reasons you might consider migrating to Volt:

- **Plain-text files.** Every request lives in a `.volt` file that you can read, edit, diff, and commit to git -- just like your source code. No opaque JSON blobs or proprietary databases.
- **No account required.** You never need to create an account, sign in, or connect to a cloud service. Everything is local and offline.
- **Tiny and fast.** The entire tool is a single ~4 MB binary with zero dependencies. It starts in under 10 ms and uses about 5 MB of RAM.
- **Team-friendly.** Because `.volt` files are plain text in your repo, every teammate gets the same collection by running `git pull`. No manual syncing, no paid team plans.
- **CI/CD ready.** Run your API tests directly in your pipeline with `volt test` or `volt ci`. Generate JUnit XML, HTML, or JSON reports.

The best part: migration is usually a single command. Volt can import your existing Postman collections, Insomnia exports, OpenAPI specs, HAR recordings, and cURL commands -- and turn them into `.volt` files instantly.

---

## Importing

### Importing from Postman

This is the most common migration path. Volt imports Postman Collection v2.0 and v2.1 formats, which covers every modern Postman export.

#### Command

```bash
volt import postman collection.json
```

#### What Gets Imported

Volt faithfully translates Postman collections into `.volt` files. Here is what carries over:

| Postman Feature | Volt Equivalent |
|---|---|
| Request name | Comment at top of `.volt` file |
| HTTP method & URL | `GET https://...` line |
| Headers | Header lines below the URL |
| Request body (raw, JSON, form-data) | Body section after headers |
| Authorization (Bearer, Basic, API Key, OAuth2) | `auth:` section in `.volt` file |
| Pre-request scripts | `script:` section (pre-request) |
| Test scripts | `script:` section (post-response) |
| Folder structure | Directory structure on disk |
| Form data & multipart | Multipart body format |
| Variables (`{{variable}}`) | Preserved as `{{variable}}` syntax |

Volt has been tested with large Postman collections containing 101+ requests and handles them without issues. If any individual request in the collection is malformed, Volt logs a warning and continues importing the rest -- it never fails silently or crashes on bad input.

#### Step-by-Step: Exporting from Postman

Before you can import into Volt, you need to export your collection from Postman:

1. Open **Postman** and find your collection in the left sidebar.
2. Click the **three dots** (...) next to the collection name.
3. Select **Export**.
4. Choose **Collection v2.1** (recommended) or **Collection v2.0**. Both work.
5. Click **Export** and save the `.json` file to your project directory.
6. Now run the import:

```bash
volt import postman my-collection.json
```

#### Choosing an Output Directory

By default, imported files are written to the current directory. You can specify a different output directory:

```bash
volt import postman collection.json --output api/
```

This creates the `api/` directory (if it does not exist) and writes all `.volt` files there.

#### Example

Suppose you export a Postman collection called "User API" that contains three requests. Running the import produces:

```
$ volt import postman user-api.json --output api/

Importing collection: User API
Found 3 requests
  api/get-users.volt
  api/create-user.volt
  api/delete-user.volt
Successfully imported to api/
```

Each `.volt` file is a self-contained, human-readable request. Open one up and you will see exactly what it does.

---

### Importing from cURL

Found a cURL command in documentation, on Stack Overflow, or in your browser's DevTools? Paste it straight into Volt.

#### Command

```bash
volt import curl "curl -X POST https://api.example.com/users -H 'Content-Type: application/json' -d '{\"name\": \"Alice\", \"email\": \"alice@example.com\"}'"
```

Note: wrap the entire cURL command in double quotes. If your cURL command contains double quotes internally, escape them with backslashes as shown above.

#### What Gets Imported

| cURL Flag | Volt Equivalent |
|---|---|
| `-X METHOD` | HTTP method line |
| URL | URL on the method line |
| `-H 'Header: Value'` | Header lines |
| `-d 'body'` / `--data` | Request body |
| `-u user:pass` | `auth: basic` section |
| `-H 'Authorization: Bearer ...'` | `auth: bearer` section |

#### Example with a Complex cURL Command

Here is a real-world cURL command with multiple headers, authentication, and a JSON body:

```bash
volt import curl "curl -X PUT https://api.example.com/users/42 \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -H 'X-Request-ID: abc-123' \
  -u admin:secretpass \
  -d '{\"name\": \"Bob\", \"role\": \"admin\"}'"
```

This prints the generated `.volt` content to stdout. To save it directly to a file, use `--output`:

```bash
volt import curl "curl -X GET https://api.example.com/health" --output health-check.volt
```

The resulting `.volt` file will look something like:

```
# Imported from cURL

---

PUT https://api.example.com/users/42

Content-Type: application/json
Accept: application/json
X-Request-ID: abc-123

auth: basic
username: admin
password: secretpass

{"name": "Bob", "role": "admin"}
```

---

### Importing from OpenAPI / Swagger

If your team publishes an OpenAPI 3.x or Swagger 2.0 specification, you can generate `.volt` files for every endpoint in a single command.

#### Command

```bash
volt import openapi spec.json
```

Works with both JSON and YAML spec files.

#### What Gets Imported

| OpenAPI Feature | Volt Equivalent |
|---|---|
| Each path + method combination | One `.volt` file per endpoint |
| Path parameters (`/users/{id}`) | URL with parameter placeholders |
| Query parameters | Documented in comments |
| Request body schemas | Body section with content type |
| Response definitions | Test assertions (status codes) |
| Server URLs | Base URL configuration |

#### Example

Given an OpenAPI spec for a "Pet Store API" with three endpoints:

```bash
volt import openapi petstore.json --output petstore/
```

Output:

```
Imported 3 endpoint(s) from OpenAPI to petstore/
```

The generated files (`petstore/endpoint-1.volt`, `petstore/endpoint-2.volt`, etc.) are ready to run immediately:

```bash
volt run petstore/endpoint-1.volt
```

#### Tip: Use with `volt design` for More Control

If you want a richer OpenAPI workflow (spec summary, file generation with meaningful names, response validation), see the [OpenAPI Design-First Workflow](#openapi-design-first-workflow) section below. The `volt design` command gives you more control over how spec files are generated.

---

### Importing from Insomnia

Migrating from Insomnia? Volt reads Insomnia's JSON export format.

#### Command

```bash
volt import insomnia export.json
```

#### Step-by-Step: Exporting from Insomnia

1. Open **Insomnia** and go to the workspace you want to export.
2. Click the **dropdown arrow** next to the workspace name (top-left).
3. Select **Import/Export**.
4. Click **Export Data** and choose **Current Workspace**.
5. Select **Insomnia v4 (JSON)** as the format.
6. Save the file and then run:

```bash
volt import insomnia my-workspace.json --output api/
```

#### What Gets Imported

Volt parses the Insomnia export and creates one `.volt` file per request. Method, URL, headers, body, and authentication settings are all preserved.

#### Example

```
$ volt import insomnia insomnia-export.json --output api/

Found 12 requests
  api/request-1.volt
  api/request-2.volt
  ...
  api/request-12.volt
Successfully imported to api/
```

---

### Importing from HAR Files

HAR (HTTP Archive) files are recordings of actual HTTP traffic captured by your browser or proxy. They are a great way to capture real-world API interactions and turn them into reusable `.volt` files.

#### What Is a HAR File?

A HAR file is a JSON-formatted log of a browser's network activity. It records every HTTP request and response -- the URLs, headers, bodies, timing, cookies, and more. Browsers, proxies, and testing tools all support the HAR 1.2 format.

Think of it as a "session recording" for HTTP traffic. This is especially useful when you want to:

- Capture and replay a sequence of API calls you made manually in a browser
- Debug a production issue by recording the exact requests that were sent
- Convert an existing browser-based workflow into automated `.volt` requests

#### How to Create a HAR File from Browser DevTools

**Chrome / Edge:**

1. Open DevTools (F12 or Ctrl+Shift+I).
2. Go to the **Network** tab.
3. Make sure recording is enabled (the red circle should be active).
4. Perform the actions you want to capture (navigate pages, submit forms, etc.).
5. Right-click anywhere in the network log and choose **Save all as HAR with content**.
6. Save the `.har` file.

**Firefox:**

1. Open DevTools (F12).
2. Go to the **Network** tab.
3. Perform the actions you want to capture.
4. Click the **gear icon** in the Network tab toolbar.
5. Select **Save All As HAR**.

#### Command

```bash
volt import har traffic.har
```

You can also use the `volt har` subcommand:

```bash
volt har import traffic.har --output captured/
```

#### Example

```
$ volt import har session-recording.har --output api/

Imported 8 request(s) from HAR to api/
```

Each request from the HAR file becomes its own `.volt` file (`request-1.volt`, `request-2.volt`, etc.), preserving the method, URL, headers, and body from the original traffic.

---

## Exporting

### Exporting to Code

This is one of Volt's most powerful features. Take any `.volt` request and generate production-ready code in **16+ programming languages**. This is perfect for:

- Generating starter code for your application
- Sharing runnable examples with teammates who do not use Volt
- Including code samples in API documentation
- Quickly switching between languages during prototyping

#### Command

```bash
volt export <language> <file.volt>
```

#### Supported Languages

| Language | Command | Library / Framework |
|---|---|---|
| cURL | `volt export curl` | cURL CLI |
| Python | `volt export python` | `requests` |
| JavaScript | `volt export javascript` | `fetch` API |
| Go | `volt export go` | `net/http` |
| Ruby | `volt export ruby` | `Net::HTTP` |
| PHP | `volt export php` | `curl_*` functions |
| C# | `volt export csharp` | `.NET HttpClient` |
| Rust | `volt export rust` | `reqwest` |
| Java | `volt export java` | `java.net.http.HttpClient` (Java 11+) |
| Swift | `volt export swift` | `URLSession` |
| Kotlin | `volt export kotlin` | `OkHttp` |
| Dart | `volt export dart` | `package:http` |
| R | `volt export r` | `httr` |
| HTTPie | `volt export httpie` | HTTPie CLI |
| wget | `volt export wget` | wget CLI |
| PowerShell | `volt export powershell` | `Invoke-RestMethod` |

You can also use `js` as a shorthand for `javascript`:

```bash
volt export js api/login.volt
```

#### Example Outputs

Let's say you have a `.volt` file like this:

```
# Create User

---

POST https://api.example.com/users

Content-Type: application/json
Accept: application/json

{"name": "Alice", "email": "alice@example.com"}
```

Here is what the generated code looks like in several popular languages:

**cURL:**

```bash
$ volt export curl api/create-user.volt
```

```bash
curl -X POST 'https://api.example.com/users' \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json' \
  -d '{"name": "Alice", "email": "alice@example.com"}'
```

**Python (requests):**

```bash
$ volt export python api/create-user.volt
```

```python
import requests

headers = {
    "Content-Type": "application/json",
    "Accept": "application/json",
}

response = requests.post(
    "https://api.example.com/users",
    headers=headers,
    json={"name": "Alice", "email": "alice@example.com"},
)

print(f"Status: {response.status_code}")
print(response.text)
```

**JavaScript (fetch):**

```bash
$ volt export javascript api/create-user.volt
```

```javascript
const response = await fetch("https://api.example.com/users", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "Accept": "application/json",
  },
  body: JSON.stringify({"name": "Alice", "email": "alice@example.com"}),
});

const data = await response.json();
console.log(data);
```

**Go (net/http):**

```bash
$ volt export go api/create-user.volt
```

```go
package main

import (
    "fmt"
    "io"
    "net/http"
    "strings"
)

func main() {
    body := strings.NewReader(`{"name": "Alice", "email": "alice@example.com"}`)
    req, err := http.NewRequest("POST", "https://api.example.com/users", body)
    if err != nil {
        panic(err)
    }

    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("Accept", "application/json")

    resp, err := http.DefaultClient.Do(req)
    if err != nil {
        panic(err)
    }
    defer resp.Body.Close()

    respBody, _ := io.ReadAll(resp.Body)
    fmt.Printf("Status: %d\n", resp.StatusCode)
    fmt.Println(string(respBody))
}
```

#### Authentication in Exports

Volt correctly translates authentication settings into each language's idiom. For example:

- **Bearer tokens** become `Authorization: Bearer ...` headers
- **Basic auth** becomes `-u user:pass` in cURL, `request.basic_auth()` in Ruby, `--auth user:pass` in HTTPie, and the equivalent in each language
- **API keys** are placed in headers (or query parameters, depending on configuration)

---

### Exporting to OpenAPI

Generate an OpenAPI 3.0 specification from your `.volt` file collection. This is the reverse of importing -- take your hand-crafted `.volt` requests and produce a standard spec.

#### Command

```bash
volt export openapi api/login.volt
```

This exports a single `.volt` file as an OpenAPI spec. The generated YAML includes:

- **Info block** with title and version
- **Server URLs** extracted from request URLs
- **Paths** with methods, request bodies, and response definitions
- **Security schemes** (Bearer, Basic, API Key, Digest) based on auth configuration
- **Parameters** from custom headers

#### Example Output

```yaml
openapi: '3.0.3'
info:
  title: Volt Collection
  version: '1.1.0'
  description: Generated by Volt API Client
servers:
  - url: https://api.example.com
paths:
  /users:
    post:
      summary: Create User
      operationId: createUser
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
      responses:
        '200':
          description: Successful response
      security:
        - bearerAuth: []
components:
  securitySchemes:
    bearerAuth:
      type: http
      scheme: bearer
    basicAuth:
      type: http
      scheme: basic
    apiKeyAuth:
      type: apiKey
      in: header
      name: X-API-Key
```

#### Tip

If you want to export an entire directory of `.volt` files into a single OpenAPI spec, use the [Design workflow](#openapi-design-first-workflow) or feed them through `volt export openapi` individually.

---

### Exporting to HAR

Export a `.volt` request as a HAR (HTTP Archive) entry. This executes the request and captures both the request and response in HAR 1.2 format.

#### Command

```bash
volt har export api/users.volt
```

Optionally save to a file:

```bash
volt har export api/users.volt --output trace.har
```

Note: HAR export actually **executes** the request because it needs to capture the response. This is different from code export, which only generates code without sending anything.

#### When to Use HAR Export

- **Sharing debug traces** with teammates or support teams
- **Importing into browser DevTools** for visual inspection
- **Feeding into performance analysis tools** that accept HAR format
- **Archiving request/response pairs** for compliance or auditing

---

## API Documentation Generation

Volt can generate API documentation directly from your `.volt` files. No extra tooling needed.

#### Markdown Output

```bash
volt docs api/
```

This scans the `api/` directory for all `.volt` files and generates a Markdown document listing every endpoint, its method, URL, headers, body, and test assertions.

Save to a file:

```bash
volt docs api/ --output docs.md
```

#### HTML Output

```bash
volt docs api/ --html -o docs.html
```

This produces a standalone HTML page with styled, human-readable API documentation. You can open it in a browser, host it on a static server, or include it in your project's documentation site.

#### Customizing the Title

```bash
volt docs api/ --title "My API Reference" --html -o api-docs.html
```

#### What the Generated Docs Include

For each `.volt` file in the directory:

- **Endpoint name** (from the comment at the top of the file)
- **HTTP method and URL**
- **Request headers** (with values)
- **Request body** (with content type)
- **Test assertions** (expected status codes, body checks, etc.)

The documentation stays in sync with your actual requests because it is generated from the same `.volt` files you use for testing and development. When you change a request, regenerate the docs and they are automatically up to date.

---

## OpenAPI Design-First Workflow

The `volt design` command gives you a full design-first workflow: start with an OpenAPI spec and generate ready-to-run `.volt` files.

This is different from `volt import openapi` in that it gives you richer output -- meaningful file names, collection files, environment files, and spec validation.

### View Spec Summary

```bash
volt design spec.json
```

This parses the OpenAPI spec and prints a color-coded summary:

```
Pet Store API v1.0.0
A sample pet store API
Server: https://petstore.example.com/v1

Endpoints (3):
  GET  /pets - List all pets
  POST /pets - Create a pet
  GET  /pets/{petId} - Get pet by ID
```

### Generate .volt Files from Spec

```bash
volt design spec.json generate
```

This creates one `.volt` file per endpoint, plus supporting files:

```
  _collection.volt
  _env.volt
  get-pets.volt
  post-pets.volt
  get-pets-petId.volt

Generated 5 .volt file(s) from OpenAPI spec.
```

Here is what each file type contains:

**`_collection.volt`** -- Collection metadata:

```
# Collection: Pet Store API
# Version: 1.0.0
# A sample pet store API

---

BASE_URL https://petstore.example.com/v1
```

**`_env.volt`** -- Environment variables:

```
# Environment variables

---

base_url=https://petstore.example.com/v1
```

**`get-pets.volt`** -- An endpoint file:

```
# List all pets
# Returns all pets in the store

---

GET https://petstore.example.com/v1/pets

---

assert status equals 200
```

### Validate Responses Against Spec

```bash
volt design spec.json validate
```

This validates that your actual API responses match the spec's expected status codes and content types. Validation checks include:

- **Status code matching** -- Does the response return a status code defined in the spec?
- **Content-type matching** -- Does the response's `Content-Type` match the spec's expected content type?

Validation errors are reported with severity levels (ERROR or WARNING) so you can distinguish between critical mismatches and minor inconsistencies.

---

## Bulk Migration Tips

Migrating a large project with many requests? Here is a practical workflow.

### 1. Start with Postman Export

If you have an existing Postman workspace, export each collection as a separate JSON file. Then import them all:

```bash
# Import each collection into its own directory
volt import postman users-api.json --output api/users/
volt import postman payments-api.json --output api/payments/
volt import postman auth-api.json --output api/auth/
```

### 2. Organize with Directory Structure

Volt uses the filesystem for organization. A clean directory structure makes everything easier:

```
api/
  auth/
    login.volt
    register.volt
    refresh-token.volt
  users/
    list-users.volt
    get-user.volt
    create-user.volt
    update-user.volt
    delete-user.volt
  payments/
    create-payment.volt
    get-payment.volt
```

### 3. Set Up Shared Configuration

Create a `.voltrc` file in your project root to define shared settings:

```bash
volt init
```

Edit `.voltrc` to set your base URL, default headers, and environment:

```
base_url=https://api.example.com
timeout=10000

[headers]
Accept=application/json
X-Client=volt/1.1.0
```

### 4. Create Environment Files

Set up environment-specific variables in `_env.volt`:

```
# Environments

---

[development]
base_url=http://localhost:3000
api_key=dev-key-12345

[staging]
base_url=https://staging.example.com
api_key=staging-key-67890

[production]
base_url=https://api.example.com
api_key=prod-key-xxxxx
```

### 5. Verify the Migration

Run all your imported requests to make sure everything works:

```bash
# Run all requests in a directory
volt run api/

# Or run tests if you have assertions
volt test api/

# Generate a report
volt test api/ --report html -o migration-report.html
```

### 6. Commit to Git

Since `.volt` files are plain text, they play nicely with version control:

```bash
git add api/ .voltrc _env.volt
git commit -m "Migrate API collection from Postman to Volt"
```

### 7. Share with Your Team

Your teammates can now get the entire API collection by pulling the repo. No Postman account needed, no syncing, no workspace invitations. Just:

```bash
git pull
volt test api/
```

### Common Migration Pitfalls

- **Environment variables.** Postman uses `{{variable}}` syntax, and so does Volt. Variables in URLs, headers, and bodies are preserved during import. Make sure to set up your `_env.volt` file with the actual values.
- **Pre-request scripts.** Volt imports Postman scripts, but the scripting runtimes are different. Complex JavaScript logic in Postman scripts may need to be adapted.
- **Collection-level auth.** If your Postman collection uses collection-level authentication (inherited by all requests), you may need to add auth settings to individual `.volt` files or use `.voltrc` defaults.
- **Binary files and file uploads.** Multipart form data and file references are imported, but file paths need to point to actual files on your system.

---

## Quick Reference

Here is a cheat sheet of every import and export command:

### Import Commands

```bash
volt import postman collection.json            # Postman v2.0/v2.1
volt import postman collection.json --output dir/

volt import curl "curl -X GET ..."             # cURL command
volt import curl "curl ..." --output file.volt

volt import openapi spec.json                  # OpenAPI 3.x / Swagger 2.0
volt import openapi spec.json --output dir/

volt import insomnia export.json               # Insomnia export
volt import insomnia export.json --output dir/

volt import har traffic.har                    # HAR 1.2 file
volt import har traffic.har --output dir/
```

### Export Commands

```bash
volt export curl api/request.volt              # cURL
volt export python api/request.volt            # Python (requests)
volt export javascript api/request.volt        # JavaScript (fetch)
volt export go api/request.volt                # Go (net/http)
volt export ruby api/request.volt              # Ruby (Net::HTTP)
volt export php api/request.volt               # PHP (cURL)
volt export csharp api/request.volt            # C# (HttpClient)
volt export rust api/request.volt              # Rust (reqwest)
volt export java api/request.volt              # Java (HttpClient)
volt export swift api/request.volt             # Swift (URLSession)
volt export kotlin api/request.volt            # Kotlin (OkHttp)
volt export dart api/request.volt              # Dart (http)
volt export r api/request.volt                 # R (httr)
volt export httpie api/request.volt            # HTTPie
volt export wget api/request.volt              # wget
volt export powershell api/request.volt        # PowerShell

volt export openapi api/request.volt           # OpenAPI 3.0 YAML

volt har export api/request.volt               # HAR 1.2 (executes request)
volt har export api/request.volt --output f.har
```

### Documentation & Design Commands

```bash
volt docs api/                                 # Markdown docs
volt docs api/ --html -o docs.html             # HTML docs
volt docs api/ --title "My API"                # Custom title

volt design spec.json                          # Show spec summary
volt design spec.json generate                 # Generate .volt files
volt design spec.json validate                 # Validate against spec
```
