---
layout: page
title: Web UI Guide
---

# Volt Web UI Guide

Volt ships with a full-featured browser-based API client built right into the same binary you already have. No Electron wrapper, no separate install, no account required, no telemetry -- just open your browser and start building requests. The entire UI is under 5 MB, embedded directly in the Volt binary at compile time.

This guide walks through every feature of the Web UI, from launching it for the first time to configuring PWA offline support. If you prefer the terminal, jump to the [Terminal UI (TUI)](#terminal-ui-tui) section at the end.

---

## Table of Contents

1. [What Is the Volt Web UI?](#what-is-the-volt-web-ui)
2. [Starting the Web UI](#starting-the-web-ui)
3. [Request Builder](#request-builder)
4. [Response Viewer](#response-viewer)
5. [Collections and Environments](#collections-and-environments)
6. [History and Tools](#history-and-tools)
7. [Themes](#themes)
8. [PWA Features](#pwa-features)
9. [WebSocket and SSE Testing](#websocket-and-sse-testing)
10. [Collection Runner](#collection-runner)
11. [Terminal UI (TUI)](#terminal-ui-tui)
12. [Web UI vs TUI Comparison](#web-ui-vs-tui-comparison)
13. [API Endpoints](#api-endpoints-for-power-users)

---

## What Is the Volt Web UI?

The Volt Web UI is a browser-based graphical interface for designing, sending, and inspecting API requests. It is served by an embedded HTTP server inside the Volt binary itself -- the same `volt` binary you use on the command line.

**Key facts:**

- **Zero install** -- If you have `volt`, you already have the Web UI. No plugins, no extensions.
- **No Electron** -- It runs in your existing browser. Chrome, Firefox, Safari, Edge -- anything modern works.
- **No account** -- There is no sign-up, no cloud sync, no login wall. Everything stays on your machine.
- **Under 5 MB** -- The HTML, CSS, and JavaScript are compiled into the binary with `@embedFile`. There are no external asset files to manage.
- **Offline-capable** -- A service worker caches the app shell so the UI loads even when the Volt server is not running (API calls will gracefully degrade).
- **Git-native** -- Your `.volt` request files and `_env.volt` environment files live in your repo. The Web UI reads them directly from disk.

Think of it as a local Postman alternative that boots in under a second and never phones home.

---

## Starting the Web UI

There are two ways to launch the Web UI, depending on whether you want local-only or network access.

### Local Use: `volt ui`

```bash
volt ui
```

This starts the embedded server on **127.0.0.1:8080** and automatically opens your default browser. Only your machine can reach it.

**Custom port:**

```bash
volt ui --port 3000
```

or using the short flag:

```bash
volt ui -p 3000
```

The browser opens to `http://127.0.0.1:3000`.

### Team / Network Use: `volt serve`

```bash
volt serve
```

This binds to **0.0.0.0:8080**, making the UI accessible from other machines on your network. Useful for:

- Sharing a running UI with a teammate over the local network
- Running Volt on a remote dev server and connecting from your laptop
- Hosting a team API workbench on an internal server

**Custom port:**

```bash
volt serve --port 9090
```

Anyone on your network can then open `http://your-ip:9090` in their browser.

> **Note:** `volt serve` does not open a browser automatically. It prints the URL and waits for connections. Press `Ctrl+C` to stop the server.

### What Happens at Startup

When either command starts, the server:

1. Binds to the configured host and port
2. Serves the embedded HTML, CSS, JavaScript, manifest, and service worker
3. Routes all `/api/*` requests to the internal API handler
4. Prints a startup banner with the URL

```
  Volt Web UI running on http://127.0.0.1:8080

  Open in your browser to start making requests.
  Press Ctrl+C to stop.
```

---

## Request Builder

The request builder is the top section of the main workspace. It is where you compose API requests.

### URL Bar

The URL bar spans the full width and contains three elements:

| Element | Description |
|---|---|
| **Method selector** | Dropdown: `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, `HEAD`, `OPTIONS`. Each method is color-coded (green for GET, yellow for POST, blue for PUT, purple for PATCH, red for DELETE). |
| **URL input** | Type your URL here. Supports environment variable interpolation (e.g., `{{base_url}}/users`). Placeholder text reads "Enter URL or paste cURL..." |
| **Send button** | Click to execute, or press `Ctrl+Enter` from anywhere in the builder. The button glows while a request is in flight. |

### cURL Paste

One of the handiest features: **paste a cURL command directly into the URL bar**. Volt detects it automatically and converts it into a structured request.

1. Copy a cURL command from your browser DevTools, documentation, or a colleague's Slack message
2. Click the URL input field and paste (`Ctrl+V`)
3. Volt parses the method, URL, headers, and body from the cURL string and populates all the appropriate fields

This works for commands starting with `curl ` or `curl.exe `.

You can also use the dedicated import dialog (`Ctrl+I` or the **Import** button in the toolbar) to paste longer cURL commands into a full-size text area.

### Request Tabs

Below the URL bar, seven tabs organize your request configuration:

#### Params

A key-value table for query parameters. Each row has a Key field, a Value field, and a remove button. Parameters are automatically appended to the URL when you send the request.

Click **+ Add Parameter** to add a new row.

#### Headers

Same key-value format as Params. A default `Accept: application/json` header is pre-filled for new requests. Add custom headers like `Authorization`, `X-Request-ID`, or anything your API needs.

Click **+ Add Header** to add a new row.

#### Body

The body panel has a mode selector and a text editor.

**Body modes:**

| Mode | Content-Type set automatically |
|---|---|
| **None** | No body sent |
| **JSON** | `application/json` |
| **Form** | `application/x-www-form-urlencoded` |
| **Text** | `text/plain` |

Type or paste your request body into the editor. For JSON, the editor accepts raw JSON:

```json
{
  "name": "Ada Lovelace",
  "email": "ada@example.com",
  "role": "admin"
}
```

The editor uses a monospace font (JetBrains Mono) with proper tab sizing for comfortable editing.

#### Auth

Select an authentication type from the dropdown and fill in the required fields. Volt supports nine auth types:

| Auth Type | Fields |
|---|---|
| **No Auth** | (default) No authentication |
| **Bearer Token** | Token |
| **Basic Auth** | Username, Password |
| **API Key** | Key name, Value, Location (Header or Query Param) |
| **Digest Auth** | Username, Password |
| **AWS Signature V4** | Access Key, Secret Key, Region, Service, Session Token (optional) |
| **Hawk Auth** | Hawk ID, Hawk Key, Algorithm (SHA-256), Ext (optional) |
| **OAuth 2.0 (Client Credentials)** | Token URL, Client ID, Client Secret, Scope (optional) |
| **OAuth 2.0 (Password Grant)** | Token URL, Client ID, Client Secret (optional), Username, Password, Scope (optional) |
| **OAuth 2.0 (Implicit)** | Authorization URL, Client ID, Scope (optional) |

Each auth type dynamically shows only the fields it needs. AWS and Hawk auth types display in a labeled group box for clarity.

#### Pre-Script

A script editor that runs **before** the request is sent. Use pre-scripts to set dynamic variables, generate timestamps, or log values.

```
# Set a dynamic variable
env.set token {{$timestamp}}
# Log values
log Starting request...
```

The editor includes a hint banner explaining its purpose.

#### Post-Script

A script editor that runs **after** the response is received. Use post-scripts to extract values from the response, run assertions, or chain requests together.

```
# Extract a value from response
extract $.data.id as user_id
# Assert status
assert.status 200
# Chain to next request
chain get-user-details.volt
```

#### Tests

Write inline test assertions using a simple syntax. Tests run automatically against every response.

**Test syntax:**

```
status == 200
$.name == "John"
headers.content-type contains json
```

**Supported operators:** `==`, `!=`, `contains`, `>`, `<`, `>=`, `<=`

**Supported fields:**

| Field pattern | What it checks |
|---|---|
| `status` | HTTP status code |
| `headers.<name>` | Response header value |
| `$.<path>` | JSONPath into the response body |

You can also click **Auto-Generate Tests** to let Volt suggest assertions based on the current response. This creates starter tests for status code, body content, and content-type that you can customize.

---

## Response Viewer

After sending a request, the response viewer appears below the builder. It displays everything about the HTTP response.

### Status Line

A colored badge shows the status code and text:

| Range | Color | Example |
|---|---|---|
| 2xx | Green | `200 OK` |
| 3xx | Blue | `301 Moved Permanently` |
| 4xx | Yellow | `404 Not Found` |
| 5xx | Red | `500 Internal Server Error` |

Next to the badge, you see the **response time** (in milliseconds) and **response size** (formatted as B, KB, MB).

### Action Buttons

Three buttons appear to the right of the status line:

| Button | Action |
|---|---|
| **Copy** | Copies the response body to your clipboard |
| **Export** | Opens the export dialog to generate code in another language |
| **Save .volt** | Downloads the current request as a `.volt` file |

### Response Tabs

#### Body

The response body with three view modes:

- **Pretty** (default) -- Syntax-highlighted JSON with color-coded keys, strings, numbers, booleans, and nulls. The highlighting adapts to your selected theme.
- **Raw** -- Plain text, no formatting. Useful for non-JSON responses or when you need to copy exact bytes.
- **Preview** -- For HTML responses, renders the HTML in a sandboxed iframe so you can see the page as a browser would display it.

#### Headers

A two-column table showing every response header. The header name is highlighted in the primary accent color. Rows highlight on hover for easy scanning.

| Name | Value |
|---|---|
| `content-type` | `application/json; charset=utf-8` |
| `cache-control` | `no-cache` |
| `x-request-id` | `abc-123-def-456` |

#### Timing

A visual waterfall chart breaking down exactly where time was spent during the request:

| Phase | Color | What it measures |
|---|---|---|
| **DNS** | Blue | Domain name resolution |
| **Connect** | Green | TCP connection establishment |
| **TLS** | Yellow | TLS/SSL handshake |
| **TTFB** | Cyan | Time to first byte (server processing) |
| **Transfer** | Purple | Response body transfer |

Each phase shows a proportional bar and its duration in milliseconds. A **Total** row at the bottom sums everything up.

This is invaluable for diagnosing slow requests -- you can immediately see whether the bottleneck is DNS, the TLS handshake, or the server itself.

#### Tests

Shows the pass/fail results of every test assertion you defined in the Tests tab. Each result is color-coded:

- Green checkmark for passing tests
- Red X for failing tests

---

## Collections and Environments

### Sidebar

The left sidebar contains three tabs:

#### Collections Tab

A file browser showing all `.volt` files in the current working directory. Click any file to load it into the request builder.

Each file is displayed with a color-coded method badge (guessed from the filename -- files containing "post" or "create" show as POST, "delete" or "remove" as DELETE, and so on).

**Search:** Type in the search box at the top of the sidebar to filter files. The search uses weighted scoring through the CollectionOrganizer module, so partial matches and substring matches are supported.

**New Request:** Click the **+** button next to the search box to create a blank request. This clears all fields and focuses the URL input.

You can **collapse the sidebar** by clicking the toggle arrow on its right edge, giving the request builder and response viewer the full width.

#### History Tab

Shows your recent requests with method badges, URLs, status codes, and response times. Click any history entry to reload that method and URL into the builder.

#### Protocols Tab

Provides access to WebSocket, Server-Sent Events, and Collection Runner panels. See the [WebSocket and SSE Testing](#websocket-and-sse-testing) and [Collection Runner](#collection-runner) sections below.

### Environment Switcher

In the toolbar at the top of the page, the **Env** dropdown lets you switch between environments. Environments are loaded from `_env.volt` files in your project directory.

Common setup:

```
# _env.volt
[dev]
base_url = https://dev-api.example.com
api_key = dev-key-12345

[staging]
base_url = https://staging-api.example.com
api_key = staging-key-67890

[production]
base_url = https://api.example.com
api_key = prod-key-XXXXX
```

When you select an environment, variables like `{{base_url}}` in your request URLs and headers are replaced with the environment's values before the request is sent.

### Workspace Selector

The **Workspace** dropdown in the toolbar lets you switch between different project directories. The default workspace is "Personal."

---

## History and Tools

### Request History

Every request you send through the Web UI is recorded in the history. The API stores the most recent entries and displays them in reverse chronological order.

Each history entry shows:
- Method badge (color-coded)
- URL (truncated if long)
- Status code (green for success, red for error)
- Response time in milliseconds

Click any entry to restore that method and URL into the request builder.

To clear all history, use the API endpoint directly: `POST /api/history/clear`.

### cURL Import

Two ways to import cURL commands:

1. **Paste into URL bar** -- Paste a cURL command directly and Volt auto-detects it
2. **Import dialog** -- Click **Import** in the toolbar (or press `Ctrl+I`) to open a dialog with a large text area for pasting cURL commands

The import dialog also supports **drag-and-drop**:
- Drop a **Postman collection** `.json` file to import the first request from the collection
- Drop a **`.volt` file** to load it directly

### Code Export

After sending a request, click **Export** in the response action bar to generate equivalent code in another language.

**Supported export formats:**

| Language | Format |
|---|---|
| cURL | Shell command |
| Python | `requests` library |
| JavaScript | `fetch` API |
| Go | `net/http` |
| Ruby | `net/http` |
| PHP | `curl` extension |
| Rust | `reqwest` |
| Java | `HttpClient` |
| Swift | `URLSession` |
| Kotlin | `OkHttp` |

The export dialog has three buttons:
- **Generate** -- Create the code snippet for the selected format
- **Copy** -- Copy the generated code to your clipboard
- **Close** -- Dismiss the dialog

### Auto-Generate Tests

After receiving a response, click **Auto-Generate Tests** in the Tests tab to have Volt suggest test assertions based on the response. Volt generates starter tests for:

- Status code verification (`status == 200`)
- Body content checks
- Content-Type header validation (`headers.content-type contains application/json`)

Edit the generated tests to match your specific requirements.

### Save as .volt

Click **Save .volt** in the response toolbar to download the current request as a `.volt` file. This serializes the method, URL, headers, body, auth, and scripts into Volt's plain-text format. Save it into your project directory and it becomes part of your collection, versionable with Git.

---

## Themes

Volt includes six carefully designed themes. Each theme defines a complete color palette covering backgrounds, text, syntax highlighting, method badges, status codes, and the timing waterfall.

### Available Themes

| Theme | Style | Primary Color |
|---|---|---|
| **Dark** (default) | Deep layered blacks with electric cyan glow | `#22d3ee` |
| **Light** | Clean white surfaces with teal accents | `#0891b2` |
| **Solarized** | Ethan Schoonover's classic dark palette | `#2aa198` |
| **Nord** | Arctic blue-grey with frost accents | `#88c0d0` |
| **Dracula** | Deep purple with pink highlights | `#bd93f9` |
| **Monokai** | Warm dark with vibrant syntax colors | `#66d9ef` |

### How to Switch Themes

Use the theme dropdown in the top-right corner of the toolbar. Select a theme and it applies instantly -- no page reload needed.

Your theme preference is saved to `localStorage` in your browser, so it persists across sessions. Each browser/profile can have its own theme.

### Theme Details

Every theme defines variables for:

- **Surface colors** -- background, surface, hover, active states
- **Text colors** -- primary text, muted text, bright/emphasized text
- **Status colors** -- success (green), warning (yellow), error (red), info (blue)
- **Method colors** -- unique color for each HTTP method
- **JSON syntax** -- keys, strings, numbers, booleans, nulls
- **Scrollbar** -- thumb and track colors to match the theme
- **Shadows and glows** -- elevation effects tuned to the theme's brightness

The Dark theme features a subtle grid texture in the background and glowing accent effects. The Light theme uses crisp shadows and clean borders. Each theme maintains full readability and WCAG-friendly contrast ratios.

---

## PWA Features

The Volt Web UI is a Progressive Web App (PWA). This means you can install it to your device and use it like a native application.

### Installing Volt as a Desktop App

**Chrome / Edge:**
1. Open the Volt Web UI in your browser
2. Click the install icon in the address bar (or go to Menu > "Install Volt API Client")
3. Volt opens in its own window without browser chrome -- it looks and feels like a native app

**Firefox:**
Firefox does not support PWA installation on desktop, but the UI works perfectly in a regular browser tab.

**Mobile (Android):**
1. Open the Volt Web UI in Chrome
2. Tap the "Add to Home Screen" prompt (or use Menu > "Add to Home Screen")
3. Volt appears as an app icon on your home screen with standalone display mode

### Offline Support

The service worker (`sw.js`) caches the app shell on first visit:

- `/` (index.html)
- `/style.css`
- `/app.js`
- `/manifest.json`

**Caching strategy:**

| Request type | Strategy |
|---|---|
| **App shell** (HTML, CSS, JS) | **Cache-first** with background update. Returns the cached version instantly, then fetches the latest version in the background for next time. |
| **API requests** (`/api/*`) | **Network-only**. API calls always go to the server. If offline, they return a `503` JSON error: `{"error": "Offline -- API unavailable"}`. |
| **WebSocket upgrades** | **Network-only**. Never cached. |

This means the UI itself loads instantly after the first visit, even on slow connections. When the Volt server is not running, you can still browse the UI, review your theme, and compose requests -- they just will not execute until the server is back.

**Cache versioning:** The cache is keyed to the Volt version string (e.g., `volt-v1.1.0`). When you upgrade Volt, the old cache is automatically purged and replaced.

### Web App Manifest

The manifest provides metadata for installed PWA instances:

| Property | Value |
|---|---|
| Name | Volt API Client |
| Short name | Volt |
| Display | Standalone |
| Theme color | `#00bcd4` |
| Background color | `#1e1e1e` |
| Orientation | Any |
| Categories | Developer Tools, Productivity, Utilities |

---

## WebSocket and SSE Testing

Volt's Web UI includes dedicated panels for testing real-time protocols. Access them from the **Protocols** tab in the sidebar.

### WebSocket Panel

Test WebSocket connections directly from the browser UI.

1. Click **Protocols** in the sidebar, then click **WebSocket**
2. Enter a WebSocket URL (e.g., `ws://localhost:8080/ws`)
3. Click **Connect**

Once connected:
- A green **Connected** badge appears
- Type messages in the input bar at the bottom and press **Send** (or hit Enter)
- Sent messages appear with a blue "YOU" label
- Received messages appear with a green "SRV" label
- Each message shows a timestamp

Click **Disconnect** to close the connection. The message log is preserved so you can review the conversation.

### Server-Sent Events (SSE) Panel

Test SSE endpoints:

1. Click **Protocols** in the sidebar, then click **Server-Sent Events**
2. Enter an SSE endpoint URL (e.g., `https://api.example.com/events`)
3. Click **Connect**

Events appear as they arrive, each showing:
- Event type (highlighted badge)
- Event ID
- Timestamp
- Event data in a monospace code block

Click **Disconnect** to stop receiving events.

---

## Collection Runner

The Collection Runner executes all `.volt` files in a directory and reports the results. It is perfect for smoke testing an entire API, running regression checks, or validating a collection before deployment.

### How to Use

1. Click **Protocols** in the sidebar, then click **Collection Runner**
2. Set the **Directory** (defaults to `.`, the current working directory)
3. Optionally select an **Environment** from the dropdown
4. Click **Run Collection**

### Progress and Results

While running:
- A progress bar fills from left to right
- A counter shows the current file out of the total (e.g., `3/12`)

After completion, a results table shows:

| Column | Description |
|---|---|
| **File** | The `.volt` filename |
| **Method** | HTTP method badge |
| **Status** | HTTP status code (or error message) |
| **Time** | Response time in milliseconds |
| **Result** | PASS (green), FAIL (red), or ERR (yellow) |

A request is considered PASS if its status code is 2xx or 3xx, and FAIL for 4xx/5xx. Requests that cannot be sent (parse errors, connection failures) are marked ERR.

A summary line shows the total: e.g., "Done: 10 passed, 2 failed."

---

## Terminal UI (TUI)

If you prefer staying in the terminal, Volt includes a full-featured TUI (Terminal User Interface) with Vim-inspired keybindings. Launch it by running `volt` with no arguments:

```bash
volt
```

### Layout

The TUI uses a three-pane split layout:

```
+--- Collection ---+--- Request --------+--- Response --------+
| get-users.volt   | GET                |  HTTP 200 | 42ms    |
| create-user.volt | URL: /api/users    |                     |
| delete-user.volt | Headers:           |  content-type: json  |
| update-user.volt |   Accept: app/json |                     |
|                  | Body:              |  {"users": [...]}   |
|                  |   (none)           |                     |
+------------------+--------------------+---------------------+
  NORMAL  Tab 1/3  | get-users.volt | 200 OK              42ms
```

- **Left pane (Collection):** File browser showing `.volt` files. Supports tree view.
- **Middle pane (Request):** Shows method, URL, headers, body, and auth for the selected request.
- **Right pane (Response):** Shows formatted response with status, headers, and pretty-printed body.

### Vim Keybindings

The TUI supports three modes, just like Vim:

**Normal Mode** (default):

| Key | Action |
|---|---|
| `h` | Move focus to the left pane |
| `j` | Navigate down (next file, next field, scroll response) |
| `k` | Navigate up (previous file, previous field, scroll response) |
| `l` | Move focus to the right pane |
| `Tab` | Cycle focus: Collection -> Request -> Response |
| `i` | Enter Insert mode (when in Request pane) |
| `:` | Enter Command mode |
| `/` | Enter search mode (Collection or Response pane) |
| `q` | Quit |
| `r` | Re-send the current request |
| `R` | Refresh the collection file list |
| `m` | Cycle HTTP method (GET -> POST -> PUT -> ...) |
| `n` | Jump to next search match |
| `N` | Jump to previous search match |
| `gg` | Jump to top of list |
| `G` | Jump to bottom of list |
| `Enter` | Load selected file (Collection pane) or send request (Request pane) |

**Insert Mode** (press `i` in Request pane):

| Key | Action |
|---|---|
| Type characters | Edit the URL |
| `Backspace` | Delete last character |
| `Enter` | Send the request |
| `Escape` | Return to Normal mode |

**Command Mode** (press `:` in Normal mode):

| Command | Action |
|---|---|
| `:q` or `:quit` | Quit |
| `:w` or `:save` | Save the current request to its `.volt` file |
| `:wq` | Save and quit |
| `:e <path>` | Open (edit) a specific `.volt` file |

### Tabs

The TUI supports multiple tabs so you can work on several requests simultaneously:

| Key | Action |
|---|---|
| `Ctrl+T` | Open a new tab |
| `Ctrl+W` | Close the current tab (cannot close the last tab) |
| `Alt+1` through `Alt+9` | Switch to tab 1-9 directly |
| `gt` | Next tab |
| `gT` | Previous tab |

The tab bar displays at the top of the right pane area. The active tab is highlighted in cyan. Each tab maintains its own request, response, scroll position, and method selection independently.

### Response Search

Press `/` while the Response pane is focused to enter search mode:

1. Type your search query
2. Matching lines are highlighted in yellow
3. Press `Enter` to jump to the first match and exit search mode
4. Press `n` to jump to the next match
5. Press `N` to jump to the previous match
6. A match counter shows your position (e.g., `[2/5]`)
7. Press `Escape` to cancel the search

### Collection Search

Press `/` while the Collection pane is focused to search across `.volt` files. Uses the CollectionOrganizer for weighted scoring -- results are ranked by relevance, not just substring position.

### Split-View Comparison

The TUI supports a split-view mode for comparing two responses side by side. This is useful for regression testing or comparing responses across environments.

### JSONPath Filtering

Use JSONPath expressions to drill into large JSON responses and display only the data you care about.

### Lazy Rendering

For large responses (over 10 MB), the TUI uses lazy rendering. Instead of formatting the entire response at once, it pre-computes a line offset index and renders only the visible lines. This keeps scrolling smooth even for multi-megabyte API responses.

### Session Persistence

When you quit the TUI (`:q`, `q`, or `Ctrl+C`), your session is automatically saved to `.volt-session` in the collection directory. The next time you launch `volt`, your tabs, scroll positions, and active tab are restored exactly as you left them.

The session file records:
- Each open tab and its associated `.volt` file
- Scroll positions
- Selected HTTP method
- The active tab index

---

## Web UI vs TUI Comparison

Both interfaces are first-class citizens in Volt. Choose based on your workflow:

| Feature | Web UI (`volt ui`) | TUI (`volt`) |
|---|---|---|
| **Launch** | Opens in browser | Runs in terminal |
| **Keyboard navigation** | Mouse + keyboard shortcuts | Vim keybindings (hjkl, :w, :q) |
| **Syntax highlighting** | Full JSON/XML/HTML highlighting | JSON formatting with status colors |
| **Themes** | 6 themes (Dark, Light, Solarized, Nord, Dracula, Monokai) | Terminal color scheme |
| **Tabs** | Single request (multi-tab planned) | Full multi-tab with Ctrl+T, gt/gT |
| **Search** | Sidebar search box | Vim-style `/` search in any pane |
| **Auth types** | 9 types with visual forms | Configured in `.volt` files |
| **Response timing** | Visual waterfall chart | Inline timing display |
| **Export** | Export dialog with 10 languages | `volt export` CLI command |
| **WebSocket / SSE** | Dedicated panels | `volt ws` / `volt sse` CLI commands |
| **Collection Runner** | Built-in panel | `volt run <dir>` CLI command |
| **cURL import** | Paste into URL bar or import dialog | `volt import curl <command>` |
| **Offline** | PWA with service worker cache | Always works (it is local) |
| **Team sharing** | `volt serve` on network | Share `.volt` files via Git |
| **Session persistence** | Browser localStorage | `.volt-session` file |
| **Large responses** | Browser scrolling | Lazy rendering for 10MB+ |
| **Best for** | Visual exploration, team demos, auth form filling | Fast keyboard-driven workflows, scripting, SSH |

**When to use the Web UI:**
- You want visual forms for auth configuration (especially AWS Sig V4 or OAuth)
- You want the timing waterfall chart
- You want to export code to multiple languages through a dialog
- You are demoing APIs to a team or stakeholder
- You want to install Volt as a PWA on your desktop or phone

**When to use the TUI:**
- You live in the terminal and never want to leave
- You are on a remote server over SSH
- You want Vim-style modal editing and navigation
- You need multi-tab workflows with session persistence
- You want to compare responses in split-view

---

## API Endpoints (for Power Users)

The Web UI communicates with the Volt backend over a JSON API. These endpoints are available whenever `volt ui` or `volt serve` is running. You can call them directly with `curl` or from your own scripts.

All endpoints return JSON. Errors return `{"error": "description"}`.

### Request Execution

#### `POST /api/request/execute`

Execute an HTTP request.

**Request body:**

```json
{
  "method": "GET",
  "url": "https://api.example.com/users",
  "headers": {
    "Accept": "application/json",
    "X-Custom-Header": "value"
  },
  "body": "{\"name\": \"test\"}",
  "auth": {
    "type": "bearer",
    "token": "your-token-here"
  }
}
```

**Response:**

```json
{
  "status_code": 200,
  "status_text": "OK",
  "headers": {
    "content-type": "application/json",
    "x-request-id": "abc123"
  },
  "body": {"users": [...]},
  "timing": {
    "dns_ms": 5,
    "connect_ms": 12,
    "tls_ms": 25,
    "ttfb_ms": 48,
    "transfer_ms": 3,
    "total_ms": 93
  },
  "size_bytes": 1234
}
```

#### `POST /api/request/parse`

Parse a `.volt` file's content into structured JSON.

**Request body:** Raw `.volt` file content as plain text.

**Response:**

```json
{
  "method": "POST",
  "url": "https://api.example.com/users",
  "headers": {"Content-Type": "application/json"},
  "body": "{\"name\": \"test\"}",
  "tests": [
    {"field": "status", "operator": "equals", "value": "201"}
  ]
}
```

### Collections

#### `GET /api/collections`

List `.volt` files in a directory.

**Query parameters:**
- `dir` (optional) -- directory path, defaults to `.`

**Response:**

```json
{
  "files": ["get-users.volt", "create-user.volt", "delete-user.volt"]
}
```

#### `GET /api/collections/tree`

Get a tree-structured view of the collection.

**Query parameters:**
- `dir` (optional) -- directory path, defaults to `.`

**Response:**

```json
{
  "tree": "get-users.volt\ncreate-user.volt\ndelete-user.volt"
}
```

#### `GET /api/collections/search?q=<query>`

Search for `.volt` files matching a query string.

**Query parameters:**
- `q` (required) -- search query

**Response:**

```json
{
  "results": ["get-users.volt", "get-user-by-id.volt"]
}
```

### Environments

#### `GET /api/environments`

List available environments and the active one.

**Response:**

```json
{
  "environments": [
    {"name": "dev"},
    {"name": "staging"},
    {"name": "production"}
  ],
  "active": "dev"
}
```

#### `POST /api/environments`

Create a new environment.

**Request body:**

```json
{
  "name": "local",
  "variables": {
    "base_url": "http://localhost:3000",
    "api_key": "test-key"
  },
  "active": true
}
```

### Import and Export

#### `POST /api/import/curl`

Parse a cURL command into a structured request.

**Request body:** Raw cURL command as plain text.

**Response:**

```json
{
  "method": "POST",
  "url": "https://api.example.com/users",
  "headers": {"Content-Type": "application/json"},
  "body": "{\"name\": \"test\"}"
}
```

#### `POST /api/export/<format>`

Export a request to another language. Supported formats: `curl`, `python`, `javascript`, `go`.

**Request body:** Raw `.volt` file content as plain text.

**Response:**

```json
{
  "exported": "curl -X POST https://api.example.com/users ...",
  "format": "curl"
}
```

### History

#### `GET /api/history`

Get the most recent request history entries (up to 50).

**Response:**

```json
{
  "entries": [
    {
      "method": "GET",
      "url": "https://api.example.com/users",
      "status": 200,
      "time_ms": 42
    }
  ],
  "total": 15
}
```

#### `POST /api/history/clear`

Clear all history entries.

**Response:**

```json
{"cleared": true}
```

### Other Endpoints

| Endpoint | Method | Description |
|---|---|---|
| `/api/themes` | GET | List available themes with color metadata |
| `/api/config` | GET | Get current configuration (base URL, timeout, theme) |
| `/api/config` | POST | Update configuration (writes to `.voltrc`) |
| `/api/test/generate` | POST | Generate test assertions from a response body |
| `/api/health` | GET | Health check -- returns `{"status": "ok", "version": "1.1.0"}` |
| `/api/ws/connect` | POST | Connect to a WebSocket server |
| `/api/ws/send` | POST | Send a message over the WebSocket connection |
| `/api/ws/messages` | GET | Get all WebSocket messages |
| `/api/ws/disconnect` | POST | Disconnect from the WebSocket server |
| `/api/ws/status` | GET | Get WebSocket connection status |
| `/api/sse/connect` | POST | Connect to an SSE endpoint |
| `/api/sse/events` | GET | Get received SSE events |
| `/api/sse/disconnect` | POST | Disconnect from the SSE endpoint |
| `/api/sse/status` | GET | Get SSE connection status |
| `/api/collection/files` | GET | List `.volt` files for the collection runner |
| `/api/collection/run` | POST | Run all `.volt` files in a directory |

---

## Keyboard Shortcuts (Web UI)

Quick reference for Web UI keyboard shortcuts:

| Shortcut | Action |
|---|---|
| `Ctrl+Enter` | Send request |
| `Ctrl+S` | Save current request as `.volt` file |
| `Ctrl+L` | Clear response |
| `Ctrl+I` | Open import dialog |
| `Ctrl+H` | Switch to History sidebar tab |
| `Escape` | Close any open modal |

You can also drag and drop `.volt` files or Postman collection `.json` files anywhere on the page to import them.

---

## Settings

Click **Settings** in the toolbar to configure:

| Setting | Description |
|---|---|
| **Base URL** | A URL prefix prepended to relative URLs (e.g., `https://api.example.com`) |
| **Default Timeout** | Request timeout in milliseconds (default: 30000) |

Settings are saved to the `.voltrc` file in your project directory when you click **Save**.
