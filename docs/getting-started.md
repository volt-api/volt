---
layout: page
title: Getting Started
---

# Getting Started with Volt

Welcome to Volt -- the fast, offline-first API development toolkit. This guide will walk you through everything from scratch, assuming you have never used an API client before. By the end, you will be confidently making HTTP requests, writing tests, organizing collections, and more.

---

## Table of Contents

1. [What is an API?](#1-what-is-an-api)
2. [What is Volt?](#2-what-is-volt)
3. [Installation](#3-installation)
4. [Your First Request](#4-your-first-request)
5. [Your First POST Request](#5-your-first-post-request)
6. [Your First Test](#6-your-first-test)
7. [Initialize a Project](#7-initialize-a-project)
8. [Environment Variables](#8-environment-variables)
9. [Collections](#9-collections)
10. [Quick Requests (HTTPie-style)](#10-quick-requests-httpie-style)
11. [Import from Other Tools](#11-import-from-other-tools)
12. [Export to Code](#12-export-to-code)
13. [Authentication](#13-authentication)
14. [Dynamic Variables](#14-dynamic-variables)
15. [Web UI](#15-web-ui)
16. [TUI (Terminal UI)](#16-tui-terminal-ui)
17. [What's Next](#17-whats-next)

---

## 1. What is an API?

If you are brand new to APIs, here is the short version.

**API** stands for **Application Programming Interface**. It is a way for two programs to talk to each other over the internet. When you open a weather app on your phone, that app sends a message to a weather server asking "What is the forecast for New York?" The server sends a message back with the answer. That back-and-forth conversation happens through an API.

Most web APIs use a protocol called **HTTP** (the same one your browser uses). Here are the key concepts:

### Requests and Responses

Every API interaction has two parts:

- **Request** -- the message you send. It includes:
  - A **URL** (the address of the server, like `https://api.example.com/users`)
  - An **HTTP method** (what you want to do)
  - Optional **headers** (metadata, like what format you expect)
  - An optional **body** (data you are sending, like a new user's name)

- **Response** -- the message you get back. It includes:
  - A **status code** (a number that tells you what happened)
  - **Headers** (metadata about the response)
  - A **body** (the actual data, usually in JSON format)

### HTTP Methods

The method tells the server what action you want to perform:

| Method | What it does | Example |
|--------|-------------|---------|
| `GET` | Read data | Get a list of users |
| `POST` | Create something new | Create a new user |
| `PUT` | Replace something entirely | Update a user's full profile |
| `PATCH` | Update part of something | Change just a user's email |
| `DELETE` | Remove something | Delete a user |

### Status Codes

The server responds with a number that tells you what happened:

| Code | Meaning |
|------|---------|
| `200` | OK -- everything worked |
| `201` | Created -- a new resource was made |
| `400` | Bad Request -- you sent something wrong |
| `401` | Unauthorized -- you need to log in |
| `404` | Not Found -- that thing does not exist |
| `500` | Server Error -- something broke on their end |

### JSON

Most modern APIs send and receive data in **JSON** (JavaScript Object Notation). It looks like this:

```json
{
  "id": 1,
  "name": "Alice",
  "email": "alice@example.com"
}
```

It is just a structured way to represent data using curly braces `{}` for objects, square brackets `[]` for lists, and `"key": "value"` pairs.

Now that you know the basics, let's use Volt to make your first API request.

---

## 2. What is Volt?

Volt is a **complete API development toolkit** -- think of it like Postman, Insomnia, or HTTPie, but:

- **Single tiny binary** -- about 4 MB. No Electron, no Java, no Node.js.
- **No account required** -- no sign-up, no cloud, no telemetry.
- **Works 100% offline** -- everything runs on your machine.
- **Git-friendly** -- your API requests are plain text `.volt` files that live in your repo.
- **Starts instantly** -- under 10 milliseconds. Uses about 5 MB of RAM.

With Volt, you write your API requests as simple text files (the `.volt` format), run them from the command line, and even write tests that verify your API is working correctly. You can also use the built-in Web UI or Terminal UI if you prefer a visual interface.

Here is a quick comparison to give you a sense of scale:

| | Volt | Postman |
|---|---|---|
| Install size | ~4 MB | ~500 MB |
| Startup time | <10ms | 3-8 seconds |
| RAM usage | ~5 MB | 300-800 MB |
| Account required | No | Yes |
| Works offline | Always | Requires login |

---

## 3. Installation

Choose the method that works best for your system.

### Homebrew (macOS)

If you use Homebrew on macOS, this is the easiest option:

```bash
brew install volt-api/volt/volt
```

### Install Script (Linux / macOS)

A one-liner that downloads the right binary for your system:

```bash
curl -fsSL https://raw.githubusercontent.com/volt-api/volt/main/scripts/install.sh | bash
```

### Scoop (Windows)

If you use Scoop on Windows:

```powershell
scoop bucket add volt https://github.com/volt-api/scoop-volt
scoop install volt
```

### Manual Download (All Platforms)

Download the binary for your platform from the [GitHub Releases page](https://github.com/volt-api/volt/releases/latest):

| Platform | Binary name |
|----------|-------------|
| Linux x86_64 | `volt-linux-x86_64` |
| Linux ARM64 | `volt-linux-aarch64` |
| macOS Apple Silicon | `volt-macos-aarch64` |
| macOS Intel | `volt-macos-x86_64` |
| Windows | `volt-windows-x86_64.exe` |

After downloading:

**Linux / macOS:**

```bash
# Make it executable
chmod +x volt-linux-x86_64

# Move it to your PATH (so you can run "volt" from anywhere)
sudo mv volt-linux-x86_64 /usr/local/bin/volt
```

**Windows:**

Rename the file to `volt.exe` and move it to a directory that is in your PATH (for example, `C:\Users\YourName\bin`). Or add its directory to your PATH environment variable.

### Build from Source

If you want to build Volt yourself, you need [Zig 0.14.1](https://ziglang.org/download/) or later:

```bash
git clone https://github.com/volt-api/volt.git
cd volt
zig build -Doptimize=ReleaseFast
```

The binary will be at `./zig-out/bin/volt`. Move it to your PATH.

### Verify Your Installation

No matter which method you used, confirm everything is working:

```bash
volt version
```

You should see output like:

```
Volt 1.1.0
```

If you see that, you are ready to go.

---

## 4. Your First Request

Let's make a real HTTP request. We will use a free, public test API called [httpbin.org](https://httpbin.org) that echoes back whatever you send it.

### Step 1: Create a `.volt` file

Open your favorite text editor and create a file called `hello.volt` with these contents:

```yaml
name: Hello World
method: GET
url: https://httpbin.org/get
headers:
  - Accept: application/json
```

Let's break down each line:

- **`name: Hello World`** -- a human-readable label for this request (optional, but helpful).
- **`method: GET`** -- we want to read data (not create or update anything).
- **`url: https://httpbin.org/get`** -- the address we are sending the request to.
- **`headers:`** -- a list of HTTP headers to include.
  - **`- Accept: application/json`** -- tells the server "please send me JSON back."

### Step 2: Run it

```bash
volt run hello.volt
```

### Step 3: Read the output

You will see something like this (simplified):

```
HTTP/1.1 200 OK
Content-Type: application/json

{
  "args": {},
  "headers": {
    "Accept": "application/json",
    "Host": "httpbin.org"
  },
  "origin": "203.0.113.42",
  "url": "https://httpbin.org/get"
}

Status: 200 OK | Time: 247ms | Size: 314 B
```

Here is what each part means:

- **`HTTP/1.1 200 OK`** -- the status line. `200` means everything worked.
- **Response headers** -- metadata from the server (like `Content-Type: application/json`).
- **Response body** -- the actual data. httpbin echoes back the headers you sent, your IP address, and the URL.
- **Status / Time / Size** -- a summary showing the status code, how long the request took, and how many bytes the response was.

Congratulations -- you just made your first API request with Volt.

---

## 5. Your First POST Request

A GET request reads data. A **POST** request sends data to create something new. Let's create a fake blog post using the [JSONPlaceholder](https://jsonplaceholder.typicode.com) test API.

Create a file called `create-post.volt`:

```yaml
name: Create Blog Post
method: POST
url: https://jsonplaceholder.typicode.com/posts
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "title": "Hello from Volt",
      "body": "This is my first POST request!",
      "userId": 1
    }
```

New things to notice:

- **`method: POST`** -- we are creating something, not reading.
- **`Content-Type: application/json`** -- tells the server we are sending JSON.
- **`body:`** -- the data we are sending:
  - **`type: json`** -- the format of the body.
  - **`content: |`** -- the `|` symbol means "the following indented lines are the content." This is how you write multi-line text in `.volt` files.

Run it:

```bash
volt run create-post.volt
```

You should see a response like:

```json
{
  "title": "Hello from Volt",
  "body": "This is my first POST request!",
  "userId": 1,
  "id": 101
}
```

```
Status: 201 Created | Time: 312ms | Size: 121 B
```

The `201 Created` status means the server accepted your data and created a new resource. The response includes an `id` field (101) -- that is the ID the server assigned to your new post.

---

## 6. Your First Test

One of Volt's most powerful features is built-in **test assertions**. You can add tests right inside your `.volt` file, and Volt will verify them automatically.

Create a file called `user-test.volt`:

```yaml
name: User API Test
method: GET
url: https://jsonplaceholder.typicode.com/users/1
headers:
  - Accept: application/json
tests:
  - status equals 200
  - header.content-type contains json
  - $.name equals Leanne Graham
  - $.email equals Sincere@april.biz
  - $.address.city equals Gwenborough
  - $.id exists
```

The `tests:` section is a list of assertions. Each one checks something about the response:

| Test | What it checks |
|------|---------------|
| `status equals 200` | The HTTP status code is 200 |
| `header.content-type contains json` | The Content-Type header includes the word "json" |
| `$.name equals Leanne Graham` | The `name` field in the JSON response is "Leanne Graham" |
| `$.email equals Sincere@april.biz` | The `email` field matches exactly |
| `$.address.city equals Gwenborough` | A nested field -- `address` is an object, and its `city` field is "Gwenborough" |
| `$.id exists` | The `id` field is present in the response (any value is fine) |

The `$.` prefix is called **JSONPath** -- it is a way to reach into a JSON response and pick out specific fields. You can nest as deep as you need: `$.address.geo.lat`, `$.company.name`, etc.

### Run the tests

Use `volt test` instead of `volt run`:

```bash
volt test user-test.volt
```

You will see output like:

```
user-test.volt
  ✓ status equals 200
  ✓ header.content-type contains json
  ✓ $.name equals Leanne Graham
  ✓ $.email equals Sincere@april.biz
  ✓ $.address.city equals Gwenborough
  ✓ $.id exists

6 passed, 0 failed
```

Every test passed. If one had failed, you would see it marked with a cross and a message explaining what went wrong.

### Available test operators

You can use these operators in your assertions:

| Operator | Meaning | Example |
|----------|---------|---------|
| `equals` | Exact match | `status equals 200` |
| `!=` | Not equal | `status != 404` |
| `contains` | Substring match | `body contains "success"` |
| `>` | Greater than | `$.count > 0` |
| `<` | Less than | `status < 300` |
| `exists` | Field is present | `$.id exists` |

### Run tests in a directory

You can also test every `.volt` file in a directory at once:

```bash
volt test api/
```

---

## 7. Initialize a Project

When you are working on a real project, you will want a proper directory structure. Volt has an `init` command that sets everything up for you.

### Create your project

```bash
mkdir my-api
cd my-api
volt init
```

This creates three files:

```
my-api/
  .voltrc          # Project configuration
  _env.volt        # Environment variables
  example.volt     # A sample request to get you started
```

### What each file does

**`.voltrc`** -- Project-level configuration. This controls default behavior for all requests in the project:

```yaml
# Base URL for all requests (prepended to relative URLs)
# base_url: https://api.example.com

# Request timeout in milliseconds
timeout: 30000

# Default headers applied to all requests
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
```

If you uncomment `base_url` and set it to (for example) `https://api.example.com`, then your `.volt` files can use relative URLs like `/users` instead of the full address.

**`_env.volt`** -- Environment variables (covered in the next section).

**`example.volt`** -- A sample request you can run immediately to verify everything works:

```bash
volt run example.volt
```

---

## 8. Environment Variables

Real-world APIs have different servers for development, staging, and production. You do not want to hard-code URLs and API keys into every request file. Instead, you use **environment variables**.

### Create `_env.volt`

When you run `volt init`, a `_env.volt` file is created for you. Here is what it looks like:

```ini
[default]
base_url = https://localhost:3000
api_key = dev-key-123

[staging]
base_url = https://staging.api.example.com
api_key = staging-key-456

[production]
base_url = https://api.example.com
api_key = prod-key-789
```

Each `[section]` is a named environment. The `[default]` environment is used unless you specify otherwise.

### Use variables in your requests

Reference any variable with double curly braces: `{{variable_name}}`

```yaml
name: Get Users
method: GET
url: {{base_url}}/users
headers:
  - Accept: application/json
  - X-Api-Key: {{api_key}}
tests:
  - status equals 200
```

When you run this, Volt replaces `{{base_url}}` with `https://localhost:3000` and `{{api_key}}` with `dev-key-123` (the values from the `[default]` section).

### Switch environments

Use the `--env` flag to pick a different environment:

```bash
# Uses [default] environment
volt run get-users.volt

# Uses [staging] environment
volt run get-users.volt --env staging

# Uses [production] environment
volt run get-users.volt --env production
```

Same request file, different servers. No editing needed.

### Manage environments from the command line

```bash
volt env list                    # Show all environments and their variables
volt env set api_key new-key-99  # Set a variable in the active environment
volt env get api_key             # Get a variable's value
volt env create staging          # Create a new environment
```

### Secret variables

If a variable name starts with `$`, Volt automatically masks its value as `***` in all output. This keeps sensitive values like passwords and API keys from appearing in your terminal or logs:

```ini
[default]
base_url = https://api.example.com
$api_key = super-secret-key
$password = hunter2
```

In output, you will see `***` instead of the actual values.

### Variable resolution order

When Volt encounters `{{some_variable}}`, it looks for a value in this order (first match wins):

1. **Request-level** -- `variables:` section in the `.volt` file itself
2. **Runtime** -- variables set by `extract` in previous requests during a collection run
3. **Collection** -- `_collection.volt` in the same directory
4. **Environment** -- `_env.volt` file
5. **Global** -- `.voltrc` configuration

---

## 9. Collections

A **collection** is simply a directory of `.volt` files that work together. Collections let you organize related requests, share configuration, and chain requests together (for example, log in first, then use the token for subsequent requests).

### Basic structure

```
my-api/
  .voltrc                  # Project configuration
  _env.volt                # Environment variables
  _collection.volt         # Shared defaults for all requests in this directory
  01-auth/
    _collection.volt       # Auth-specific shared config
    01-login.volt          # Step 1: Log in
    02-get-token.volt      # Step 2: Get access token
  02-users/
    get-users.volt         # Get all users
    create-user.volt       # Create a new user
    get-user-by-id.volt    # Get a specific user
```

### `_collection.volt` -- Shared defaults

This special file defines headers, auth, and other settings that are **inherited by every request in the same directory**:

```yaml
name: My API Collection
description: Shared settings for all requests
headers:
  - Accept: application/json
  - X-Api-Version: v2
auth:
  type: bearer
  token: {{api_token}}
```

Now every request in that directory automatically gets those headers and auth without you repeating them in each file.

### Numeric prefixes for ordering

Files and directories starting with numbers (like `01-`, `02-`) are executed in that order when you run a collection. This is important when requests depend on each other:

```
01-login.volt        # Runs first
02-get-token.volt    # Runs second (can use variables from step 1)
03-get-users.volt    # Runs third (can use variables from steps 1 and 2)
```

### Variable chaining

When you run a collection, variables extracted from one request are available to the next. This lets you build multi-step workflows:

**01-login.volt:**
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
      "password": "{{$password}}"
    }
post_script: |
  extract auth_token $.token
tests:
  - status equals 200
  - $.token exists
```

**02-get-profile.volt:**
```yaml
name: Get Profile
method: GET
url: {{base_url}}/me
headers:
  - Authorization: Bearer {{auth_token}}
tests:
  - status equals 200
  - $.username equals admin
```

The `extract auth_token $.token` line in the first request pulls the `token` field from the response and saves it as `auth_token`. The second request then uses `{{auth_token}}` in its Authorization header.

### Run a collection

```bash
# Run all requests in order
volt run my-api/01-auth/

# Run and test all assertions
volt test my-api/

# Run the entire collection
volt collection my-api/
```

---

## 10. Quick Requests (HTTPie-style)

Sometimes you just want to fire off a quick request without creating a file. The `volt quick` command (alias: `volt q`) lets you do that right from the command line, using a concise syntax inspired by [HTTPie](https://httpie.io).

### Basic GET request

```bash
volt quick https://httpbin.org/get
```

### POST with JSON data

```bash
volt quick POST https://httpbin.org/post name=Alice age:=30 active:=true
```

This sends a POST request with a JSON body: `{"name": "Alice", "age": 30, "active": true}`.

### All item types

The magic of `volt quick` is in the item syntax. Each item after the URL is parsed based on its separator:

| Syntax | What it does | Example |
|--------|-------------|---------|
| `field=value` | JSON string field | `name=Alice` sends `{"name": "Alice"}` |
| `field:=value` | Raw JSON value (number, bool, array, object) | `age:=30` sends `{"age": 30}` |
| `param==value` | URL query parameter | `q==search` adds `?q=search` to the URL |
| `Header:Value` | HTTP header | `Authorization:Bearer\ token123` |
| `field@/path` | File upload (switches to multipart) | `photo@./avatar.png` |

### Smart defaults

Volt figures out the right settings automatically:

- **No body items?** It defaults to **GET**.
- **Body items present?** It defaults to **POST**.
- **`:3000/path`** expands to **`http://localhost:3000/path`** (great for local development).
- **JSON body?** Automatically sets `Content-Type: application/json`.

### More examples

```bash
# GET with query parameters
volt quick https://api.example.com/search q==volt page==1

# POST JSON to a local server
volt quick POST :3000/users name=John email=john@example.com

# PUT to update a resource
volt quick PUT :3000/users/1 name=Jane

# Custom header
volt quick GET https://api.example.com/data "Authorization:Bearer mytoken"

# File upload
volt quick POST :3000/upload avatar@./photo.jpg

# Short alias
volt q :8080/health
```

---

## 11. Import from Other Tools

Already have API collections in another tool? Volt can import them in one command.

### From Postman

Export your Postman collection as JSON (Collection v2.0 or v2.1), then:

```bash
volt import postman my-collection.json --output api/
```

This converts every request -- including auth, headers, body, scripts, and folder structure -- into `.volt` files.

### From cURL

Got a cURL command? Paste it:

```bash
volt import curl 'curl -X POST https://api.example.com/users -H "Content-Type: application/json" -d "{\"name\":\"Alice\"}"' --output create-user.volt
```

### From OpenAPI / Swagger

If you have an API spec:

```bash
volt import openapi swagger.yaml --output api/
```

This creates a `.volt` file for every endpoint in the spec.

### From Insomnia

Export from Insomnia as JSON, then:

```bash
volt import insomnia export.json --output api/
```

### From HAR files

HAR (HTTP Archive) files are recordings from your browser's developer tools:

```bash
volt import har recording.har --output api/
```

### Summary of import commands

```bash
volt import postman collection.json     # Postman v2.0 / v2.1
volt import curl 'curl -X GET ...'      # cURL command
volt import openapi spec.yaml           # OpenAPI 3.x / Swagger
volt import insomnia export.json        # Insomnia
volt import har traffic.har             # HAR 1.2 files
```

---

## 12. Export to Code

Volt can turn any `.volt` file into working code in 18+ programming languages. This is incredibly useful when you have debugged and perfected a request in Volt and now need to write the actual application code.

### Examples

```bash
volt export curl request.volt           # cURL command
volt export python request.volt         # Python (requests library)
volt export javascript request.volt     # JavaScript (fetch API)
volt export go request.volt             # Go (net/http)
volt export rust request.volt           # Rust (reqwest)
volt export java request.volt           # Java (HttpClient)
volt export csharp request.volt         # C# (.NET HttpClient)
volt export php request.volt            # PHP (cURL)
volt export ruby request.volt           # Ruby (Net::HTTP)
volt export swift request.volt          # Swift (URLSession)
volt export kotlin request.volt         # Kotlin (OkHttp)
volt export dart request.volt           # Dart (http package)
volt export r request.volt              # R (httr)
volt export httpie request.volt         # HTTPie command
volt export wget request.volt           # wget command
volt export powershell request.volt     # PowerShell (Invoke-WebRequest)
volt export openapi api/                # OpenAPI spec from a collection
volt export har request.volt            # HAR recording
```

For example, `volt export python create-post.volt` might output:

```python
import requests

response = requests.post(
    "https://jsonplaceholder.typicode.com/posts",
    headers={"Content-Type": "application/json"},
    json={
        "title": "Hello from Volt",
        "body": "This is my first POST request!",
        "userId": 1
    }
)

print(response.status_code)
print(response.json())
```

You can copy that directly into your project.

---

## 13. Authentication

Most real APIs require you to prove who you are. Volt supports all the common authentication methods directly in your `.volt` files.

### Bearer Token

The most common method for modern APIs. You receive a token (usually from a login endpoint) and send it with every request:

```yaml
name: Get My Profile
method: GET
url: https://api.example.com/me
auth:
  type: bearer
  token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
```

Using an environment variable (recommended -- keeps tokens out of your files):

```yaml
auth:
  type: bearer
  token: {{$api_token}}
```

### Basic Authentication

Username and password, encoded and sent in a header. Common for simple APIs and internal tools:

```yaml
name: Admin Dashboard
method: GET
url: https://internal.example.com/admin
auth:
  type: basic
  username: admin
  password: {{$admin_password}}
```

### API Key

An API key sent as a header or query parameter. Common for public APIs like weather, maps, or data services:

**As a header (most common):**

```yaml
name: Weather Forecast
method: GET
url: https://api.weather.com/forecast?city=London
auth:
  type: api_key
  key_name: X-Api-Key
  key_value: {{$weather_api_key}}
  key_location: header
```

**As a query parameter:**

```yaml
name: Maps API
method: GET
url: https://maps.api.com/geocode
auth:
  type: api_key
  key_name: apikey
  key_value: {{$maps_key}}
  key_location: query
```

### Digest Authentication

A more secure alternative to Basic auth:

```yaml
auth:
  type: digest
  username: myuser
  password: mypass
```

### Collection-level Authentication

If every request in a collection uses the same auth, put it in `_collection.volt` so you do not have to repeat it:

```yaml
# _collection.volt
name: My API
auth:
  type: bearer
  token: {{$api_token}}
```

Now every `.volt` file in that directory automatically inherits this auth.

### OAuth 2.0

For services that use OAuth (like GitHub, Google, etc.), Volt can handle the entire login flow:

```bash
volt login github                        # Log in with GitHub
volt login google                        # Log in with Google
volt login custom --auth-url <url> --token-url <url> --client-id <id>  # Custom provider
volt login --status                      # Check if you are logged in
volt login --logout                      # Log out
```

---

## 14. Dynamic Variables

Volt has built-in variables that generate fresh values every time a request runs. These are prefixed with `$` and wrapped in double curly braces.

### Available dynamic variables

| Variable | What it generates | Example output |
|----------|------------------|----------------|
| `{{$uuid}}` | A UUID v4 | `550e8400-e29b-41d4-a716-446655440000` |
| `{{$guid}}` | Same as `$uuid` | `550e8400-e29b-41d4-a716-446655440000` |
| `{{$timestamp}}` | Unix timestamp (seconds) | `1708300800` |
| `{{$isoTimestamp}}` | ISO 8601 date-time | `2026-02-19T08:00:00Z` |
| `{{$isoDate}}` | Same as `$isoTimestamp` | `2026-02-19T08:00:00Z` |
| `{{$date}}` | Date only | `2026-02-19` |
| `{{$randomInt}}` | Random integer (0-9999) | `7291` |
| `{{$randomFloat}}` | Random float (0-1) | `0.4832` |
| `{{$randomEmail}}` | Random email address | `user4832@example.com` |
| `{{$randomString}}` | Random 8-char alphanumeric | `a8f3k2x9` |
| `{{$randomBool}}` | Random boolean | `true` or `false` |

### Example: Using dynamic variables

```yaml
name: Create User with Unique Data
method: POST
url: https://api.example.com/users
headers:
  - Content-Type: application/json
  - X-Request-ID: {{$uuid}}
body:
  type: json
  content: |
    {
      "email": "{{$randomEmail}}",
      "username": "user_{{$randomString}}",
      "created_at": "{{$isoTimestamp}}",
      "score": {{$randomInt}}
    }
tests:
  - status equals 201
  - $.id exists
```

Every time you run this request, it generates a unique email, username, timestamp, and score. This is perfect for testing -- you never get conflicts from duplicate data.

---

## 15. Web UI

Volt includes a full browser-based user interface served from the same tiny binary. No Electron, no extra install, no account.

### Launch the Web UI

```bash
volt ui
```

This starts a local web server and opens your browser to `http://localhost:8080`.

To use a custom port:

```bash
volt ui --port 3000
```

### What you can do in the Web UI

- **Request builder** -- visual editor for method, URL, headers, body (JSON/form/XML/multipart/raw), auth, and tests.
- **Response viewer** -- syntax-highlighted response body, headers panel, and timing waterfall.
- **Collections** -- file tree navigation, browse and run your `.volt` files.
- **Environments** -- switch environments and edit variables.
- **History** -- view and replay past requests.
- **Import** -- paste a cURL command and convert it.
- **Export** -- generate code in 18+ languages from any request.
- **Themes** -- Dark, Light, Solarized, and Nord color schemes.

### Team access

If you want to share the UI with your team on a local network:

```bash
volt serve --port 8080
```

`volt serve` binds to `0.0.0.0` (accessible from other machines), while `volt ui` binds to `localhost` only (just your machine).

### PWA support

The Web UI is a Progressive Web App. You can "install" it from your browser to get a desktop shortcut that works offline.

---

## 16. TUI (Terminal UI)

If you prefer staying in the terminal but want a visual interface, Volt has a built-in **Terminal UI (TUI)** with vim-style keybindings.

### Launch it

Just run `volt` with no arguments:

```bash
volt
```

### Key bindings

| Key | Action |
|-----|--------|
| `Tab` or `h` / `l` | Switch between panes |
| `j` / `k` or arrow keys | Navigate up/down |
| `Enter` | Send request or open file |
| `i` | Edit mode (for editing the URL) |
| `m` | Cycle through HTTP methods (GET, POST, PUT, etc.) |
| `Ctrl+T` | Open a new tab |
| `Ctrl+W` | Close the current tab |
| `Alt+1` through `Alt+9` | Switch to tab 1-9 |
| `gt` / `gT` | Next tab / previous tab (vim-style) |
| `/` | Search your collections |
| `Ctrl+F` | Search within the response |
| `n` / `N` | Next / previous search match |
| `Ctrl+S` | Toggle split-view comparison |
| `:w` | Save |
| `:q` | Quit |

### Features

- **Split-pane layout** -- request list on the left, response on the right.
- **Tabbed interface** -- work on multiple requests at once.
- **Collection browser** -- browse your `.volt` files in a tree view.
- **JSONPath filtering** -- type `$.key` to filter the response.
- **Lazy rendering** -- handles large responses without slowing down.
- **Tab persistence** -- your open tabs are saved between sessions.

---

## 17. What's Next

You now know the fundamentals of using Volt. Here are some resources to go deeper:

### Documentation

- **[Command Reference](commands.md)** -- every CLI command with full usage and examples.
- **[.volt File Format](volt-file-format.md)** -- complete specification for the `.volt` file format, including all fields, body types, scripting commands, and special files.
- **[Feature Status](FEATURE_STATUS.md)** -- honest assessment of every feature's maturity level.
- **[Plugin Development](plugin-development.md)** -- build your own plugins using the JSON stdin/stdout protocol.

### More things to try

- **Load testing**: `volt bench api/health.volt -n 1000 -c 50` -- send 1000 requests with 50 concurrent connections.
- **Mock server**: `volt mock api/ --port 3000` -- turn your `.volt` files into a mock API server.
- **Watch mode**: `volt test --watch` -- automatically re-run tests when files change.
- **Data-driven testing**: `volt test template.volt --data users.csv` -- run the same request with many inputs.
- **Request diff**: `volt diff a.volt b.volt --response` -- compare two requests or their responses.
- **CI/CD**: `volt test --report junit -o results.xml` -- generate test reports for CI pipelines.
- **API docs**: `volt docs api/ --format html` -- generate HTML documentation from your collection.
- **WebSocket**: `volt ws wss://echo.websocket.org` -- connect to WebSocket servers.
- **GraphQL**: `volt graphql query.volt` -- execute GraphQL queries and mutations.
- **Shell completions**: `volt completions bash >> ~/.bashrc` -- add tab completion for your shell.

### Getting help

```bash
volt help              # Show all available commands
volt help run          # Show help for a specific command
```

### Source code and issues

- **GitHub**: [https://github.com/volt-api/volt](https://github.com/volt-api/volt)
- **Issues**: [https://github.com/volt-api/volt/issues](https://github.com/volt-api/volt/issues)

---

Happy API testing!
