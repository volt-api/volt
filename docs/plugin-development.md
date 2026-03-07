---
layout: page
title: Plugin Development
---

# Plugin Development Guide

Want to extend Volt with custom behavior? Plugins let you hook into Volt's request lifecycle using **any programming language** — Python, Node.js, Go, Bash, Rust, Ruby, or anything else that can read stdin and write stdout.

This guide walks you through everything you need to know, from your first plugin to advanced patterns.

---

## Table of Contents

- [What Are Volt Plugins?](#what-are-volt-plugins)
- [How Plugins Work](#how-plugins-work)
- [Your First Plugin (Step by Step)](#your-first-plugin-step-by-step)
- [Plugin Manifest Reference](#plugin-manifest-reference)
- [Available Hooks](#available-hooks)
- [Environment Variables](#environment-variables)
- [Complete Examples](#complete-examples)
- [Testing Plugins](#testing-plugins)
- [Plugin Management Commands](#plugin-management-commands)
- [Error Handling](#error-handling)
- [Publishing and Sharing](#publishing-and-sharing)
- [Best Practices](#best-practices)
- [Plugin Ideas](#plugin-ideas)

---

## What Are Volt Plugins?

Plugins are external programs that Volt invokes at specific points in the request lifecycle. They extend Volt with custom behavior without modifying Volt itself.

**Key features:**

- **Any language** — Write plugins in Python, Node.js, Go, Bash, Rust, or any language that can read/write JSON
- **Sandboxed** — Plugins run as separate processes with no direct access to Volt internals
- **Configurable timeouts** — Each plugin has a timeout (default 5 seconds) to prevent hangs
- **Simple protocol** — JSON in via stdin, JSON out via stdout. That's it!

**What can plugins do?**

- Add custom authentication headers (e.g., fetch tokens from HashiCorp Vault, AWS Secrets Manager)
- Inject dynamic variables (e.g., read from a database, compute time-based tokens)
- Modify requests before they're sent (e.g., add correlation IDs, transform request bodies)
- Process responses after they're received (e.g., log metrics, send alerts, transform data)

---

## How Plugins Work

Here's the lifecycle of a plugin call:

```
1. Volt prepares the request
2. Volt finds plugins registered for the current hook point
3. For each plugin:
   a. Volt serializes input as JSON
   b. Volt starts the plugin as a child process
   c. Volt writes the JSON to the plugin's stdin, then closes stdin
   d. The plugin reads stdin, processes it, and writes JSON to stdout
   e. Volt reads the plugin's stdout
   f. Volt parses the JSON response
   g. Volt applies the plugin's modifications
4. Volt continues with the (possibly modified) request
```

If a plugin fails (non-zero exit code, timeout, or invalid JSON), Volt logs the error and continues without the plugin's changes. Your requests never break because of a misbehaving plugin.

---

## Your First Plugin (Step by Step)

Let's build a simple plugin that adds a custom header to every request. We'll use Python, but you could use any language.

### Step 1: Create the Plugin Directory

```bash
mkdir my-first-plugin
cd my-first-plugin
```

### Step 2: Create the Manifest

Create `plugin.json`:

```json
{
  "name": "my-first-plugin",
  "version": "1.0.0",
  "description": "Adds a custom X-Powered-By header to every request",
  "author": "Your Name",
  "hook": "pre_request",
  "entry": "main.py",
  "timeout": 5000
}
```

### Step 3: Write the Plugin

Create `main.py`:

```python
import json
import sys
from datetime import datetime

def main():
    # Read the input from Volt (via stdin)
    input_data = json.load(sys.stdin)

    # Get the request from the input
    request = input_data.get("request", {})

    # Get existing headers (or start with empty dict)
    headers = request.get("headers", {})

    # Add our custom header
    headers["X-Powered-By"] = "Volt Plugin"
    headers["X-Plugin-Timestamp"] = datetime.utcnow().isoformat()

    # Update the request with modified headers
    request["headers"] = headers

    # Write the output back to Volt (via stdout)
    output = {"request": request}
    json.dump(output, sys.stdout)

if __name__ == "__main__":
    main()
```

### Step 4: Test It

Create a test input file `test-input.json`:

```json
{
  "hook": "pre_request",
  "request": {
    "method": "GET",
    "url": "https://api.example.com/users",
    "headers": {
      "Accept": "application/json"
    }
  }
}
```

Run the plugin:

```bash
volt plugin run plugin.json test-input.json
```

You should see the plugin's output with the added headers.

### Step 5: Use It in Your Project

Your plugin is ready! When Volt encounters a `pre_request` hook, it will invoke your plugin automatically.

---

## Plugin Manifest Reference

The `plugin.json` file describes your plugin. Here's every field:

```json
{
  "name": "my-plugin",
  "version": "1.0.0",
  "description": "A custom auth provider for our internal API",
  "author": "Jane Doe",
  "hook": "auth_provider",
  "entry": "main.py",
  "timeout": 5000
}
```

| Field | Required | Description | Example |
|-------|----------|-------------|---------|
| `name` | **Yes** | Plugin identifier. Lowercase, hyphens allowed. | `"vault-auth"` |
| `version` | **Yes** | Semantic version string | `"1.0.0"` |
| `description` | No | What this plugin does | `"Fetches tokens from Vault"` |
| `author` | No | Who wrote it | `"Jane Doe"` |
| `hook` | **Yes** | When to run: `auth_provider`, `variable_provider`, `pre_request`, or `post_response` | `"auth_provider"` |
| `entry` | **Yes** | Path to the executable, relative to the plugin directory | `"main.py"` |
| `timeout` | No | Max execution time in milliseconds (default: 5000) | `10000` |

**About the `entry` field:**

- For interpreted languages (Python, Node.js, Ruby), use the script filename: `"main.py"`, `"index.js"`, `"main.rb"`
- For compiled languages, use the binary name: `"plugin"`, `"plugin.exe"`
- The path is relative to the plugin directory

---

## Available Hooks

Plugins can hook into four points in the request lifecycle. Each hook receives different input and expects different output.

### `auth_provider`

**When:** Called before a request is sent.
**Purpose:** Add authentication headers or query parameters.
**Use cases:** Fetch tokens from a secrets manager, compute custom signatures, rotate API keys, add OAuth tokens from a custom provider.

**Input (what Volt sends to your plugin via stdin):**

```json
{
  "hook": "auth_provider",
  "request": {
    "method": "GET",
    "url": "https://api.example.com/data",
    "headers": {}
  },
  "config": {}
}
```

**Expected output (what your plugin writes to stdout):**

```json
{
  "headers": {
    "Authorization": "Bearer computed-token-12345"
  }
}
```

Volt merges the returned headers into the request. You can also return query parameters:

```json
{
  "headers": {
    "X-Custom-Auth": "signature"
  },
  "query": {
    "api_key": "abc123"
  }
}
```

---

### `variable_provider`

**When:** Called during variable resolution.
**Purpose:** Inject dynamic variables into the template engine.
**Use cases:** Fetch secrets from a vault, generate time-based tokens (TOTP), compute derived values, read from external configuration.

**Input:**

```json
{
  "hook": "variable_provider",
  "variables": {
    "existing_var": "current_value",
    "base_url": "https://api.example.com"
  },
  "config": {}
}
```

**Expected output:**

```json
{
  "variables": {
    "dynamic_secret": "fetched-from-vault-abc123",
    "totp_code": "847291",
    "deployment_id": "deploy-2026-02-22-001"
  }
}
```

The returned variables are merged with existing ones. Your plugin can read the existing variables and compute new ones based on them.

---

### `pre_request`

**When:** Called after variable resolution but before the request is sent.
**Purpose:** Modify the fully-resolved request.
**Use cases:** Add timestamps, transform the request body, add correlation IDs, log requests to an external system, add computed signatures.

**Input:**

```json
{
  "hook": "pre_request",
  "request": {
    "method": "POST",
    "url": "https://api.example.com/users",
    "headers": {
      "Content-Type": "application/json"
    },
    "body": "{\"name\": \"test\"}"
  }
}
```

**Expected output:**

```json
{
  "request": {
    "method": "POST",
    "url": "https://api.example.com/users",
    "headers": {
      "Content-Type": "application/json",
      "X-Correlation-ID": "abc-123-def-456",
      "X-Timestamp": "2026-02-22T10:30:00Z"
    },
    "body": "{\"name\": \"test\"}"
  }
}
```

Return the full request object. Volt replaces the current request with your returned version.

---

### `post_response`

**When:** Called after the response is received.
**Purpose:** Process, transform, or log the response.
**Use cases:** Extract metrics (response time, status), send alerts on errors, log to an external service, transform the response body, collect analytics.

**Input:**

```json
{
  "hook": "post_response",
  "request": {
    "method": "GET",
    "url": "https://api.example.com/data"
  },
  "response": {
    "status": 200,
    "headers": {
      "content-type": "application/json"
    },
    "body": "{\"result\": \"ok\", \"count\": 42}"
  }
}
```

**Expected output:**

```json
{
  "response": {
    "status": 200,
    "headers": {
      "content-type": "application/json"
    },
    "body": "{\"result\": \"ok\", \"count\": 42}"
  }
}
```

You can modify the response (e.g., redact sensitive fields) or just return it unchanged if you only wanted to log it.

---

## Environment Variables

Volt provides these environment variables to every plugin:

| Variable | Description | Example |
|----------|-------------|---------|
| `VOLT_PLUGIN_DIR` | Absolute path to the plugin's directory | `/home/user/project/plugins/my-plugin` |
| `VOLT_PROJECT_DIR` | Absolute path to the Volt project root | `/home/user/project` |
| `VOLT_ENV` | Active environment name | `default`, `staging`, `production` |

Use these to make your plugins project-aware. For example, a plugin could read a config file from the project directory or behave differently in staging vs. production.

---

## Complete Examples

### Example 1: HashiCorp Vault Auth Provider (Python)

A plugin that fetches authentication tokens from HashiCorp Vault:

**plugin.json:**

```json
{
  "name": "vault-auth",
  "version": "1.0.0",
  "description": "Fetches auth tokens from HashiCorp Vault",
  "author": "DevOps Team",
  "hook": "auth_provider",
  "entry": "main.py",
  "timeout": 10000
}
```

**main.py:**

```python
import json
import sys
import os
import urllib.request

def main():
    input_data = json.load(sys.stdin)

    # Read Vault configuration from environment
    vault_addr = os.environ.get("VAULT_ADDR", "http://localhost:8200")
    vault_token = os.environ.get("VAULT_TOKEN", "")
    secret_path = os.environ.get("VAULT_SECRET_PATH", "secret/data/api-token")

    try:
        # Fetch the secret from Vault
        req = urllib.request.Request(
            f"{vault_addr}/v1/{secret_path}",
            headers={"X-Vault-Token": vault_token}
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read())
            api_token = data["data"]["data"]["token"]

        output = {
            "headers": {
                "Authorization": f"Bearer {api_token}"
            }
        }
    except Exception as e:
        # On error, log to stderr and return empty headers
        # Volt will continue without plugin modifications
        print(f"Vault plugin error: {e}", file=sys.stderr)
        output = {"headers": {}}

    json.dump(output, sys.stdout)

if __name__ == "__main__":
    main()
```

---

### Example 2: Variable Provider (Node.js)

A plugin that reads additional variables from a `.env` file and computes derived values:

**plugin.json:**

```json
{
  "name": "dotenv-vars",
  "version": "1.0.0",
  "description": "Loads variables from .env file and computes TOTP codes",
  "hook": "variable_provider",
  "entry": "index.js",
  "timeout": 3000
}
```

**index.js:**

```javascript
const fs = require('fs');
const path = require('path');

// Read all of stdin
let input = '';
process.stdin.on('data', (chunk) => input += chunk);
process.stdin.on('end', () => {
    const data = JSON.parse(input);
    const projectDir = process.env.VOLT_PROJECT_DIR || '.';

    const variables = {};

    // Load variables from .env file
    const envFile = path.join(projectDir, '.env');
    if (fs.existsSync(envFile)) {
        const lines = fs.readFileSync(envFile, 'utf8').split('\n');
        for (const line of lines) {
            const trimmed = line.trim();
            if (trimmed && !trimmed.startsWith('#')) {
                const [key, ...valueParts] = trimmed.split('=');
                variables[key.trim()] = valueParts.join('=').trim();
            }
        }
    }

    // Add computed values
    variables['build_timestamp'] = new Date().toISOString();
    variables['node_version'] = process.version;

    const output = { variables };
    process.stdout.write(JSON.stringify(output));
});
```

---

### Example 3: Request Logger (Python)

A `pre_request` plugin that logs every outgoing request to a file:

**plugin.json:**

```json
{
  "name": "request-logger",
  "version": "1.0.0",
  "description": "Logs all outgoing requests to a file",
  "hook": "pre_request",
  "entry": "main.py",
  "timeout": 2000
}
```

**main.py:**

```python
import json
import sys
import os
from datetime import datetime

def main():
    input_data = json.load(sys.stdin)
    request = input_data.get("request", {})

    # Log the request to a file
    project_dir = os.environ.get("VOLT_PROJECT_DIR", ".")
    log_file = os.path.join(project_dir, "volt-requests.log")

    log_entry = {
        "timestamp": datetime.utcnow().isoformat(),
        "method": request.get("method", ""),
        "url": request.get("url", ""),
        "environment": os.environ.get("VOLT_ENV", "default")
    }

    with open(log_file, "a") as f:
        f.write(json.dumps(log_entry) + "\n")

    # Return the request unchanged
    json.dump({"request": request}, sys.stdout)

if __name__ == "__main__":
    main()
```

---

### Example 4: Error Alerter (Python)

A `post_response` plugin that sends a notification when an API returns an error:

**plugin.json:**

```json
{
  "name": "error-alerter",
  "version": "1.0.0",
  "description": "Sends alerts when API responses indicate errors",
  "hook": "post_response",
  "entry": "main.py",
  "timeout": 5000
}
```

**main.py:**

```python
import json
import sys
import os
from datetime import datetime

def main():
    input_data = json.load(sys.stdin)
    request = input_data.get("request", {})
    response = input_data.get("response", {})
    status = response.get("status", 0)

    # Check for errors (4xx or 5xx)
    if status >= 400:
        alert = {
            "timestamp": datetime.utcnow().isoformat(),
            "severity": "error" if status >= 500 else "warning",
            "method": request.get("method", ""),
            "url": request.get("url", ""),
            "status": status,
            "environment": os.environ.get("VOLT_ENV", "default")
        }

        # Log to stderr (visible in Volt output for debugging)
        print(f"ALERT: {alert['severity'].upper()} - {status} on {alert['url']}", file=sys.stderr)

        # You could also send to Slack, PagerDuty, email, etc.
        # For example: send_slack_webhook(alert)

        project_dir = os.environ.get("VOLT_PROJECT_DIR", ".")
        alert_file = os.path.join(project_dir, "volt-alerts.log")
        with open(alert_file, "a") as f:
            f.write(json.dumps(alert) + "\n")

    # Return the response unchanged
    json.dump({"response": response}, sys.stdout)

if __name__ == "__main__":
    main()
```

---

### Example 5: Simple Auth Provider (Bash)

Plugins don't have to be Python! Here's a minimal Bash plugin:

**plugin.json:**

```json
{
  "name": "simple-auth",
  "version": "1.0.0",
  "description": "Adds a static auth header from an environment variable",
  "hook": "auth_provider",
  "entry": "main.sh",
  "timeout": 2000
}
```

**main.sh:**

```bash
#!/bin/bash
# Read stdin (we don't need it for this simple plugin)
cat > /dev/null

# Output the auth header using an environment variable
TOKEN="${API_TOKEN:-default-token}"
echo "{\"headers\": {\"Authorization\": \"Bearer ${TOKEN}\"}}"
```

Make it executable: `chmod +x main.sh`

---

## Testing Plugins

### Using `volt plugin run`

The easiest way to test a plugin:

```bash
volt plugin run my-plugin/plugin.json test-input.json
```

Where `test-input.json` contains the hook input payload. The plugin's stdout is printed to your terminal.

### Piping Input Directly

For quick testing without creating an input file:

```bash
echo '{"hook":"auth_provider","request":{"method":"GET","url":"https://example.com"},"config":{}}' | python my-plugin/main.py
```

### Creating Test Fixtures

Build a set of test inputs for different scenarios:

```
my-plugin/
  plugin.json
  main.py
  tests/
    auth-get.json          # Test with GET request
    auth-post.json         # Test with POST request
    auth-empty.json        # Test with no headers
    auth-existing.json     # Test with pre-existing auth header
```

Run them all:

```bash
for f in my-plugin/tests/*.json; do
    echo "Testing: $f"
    volt plugin run my-plugin/plugin.json "$f"
    echo "---"
done
```

### Debugging with stderr

Plugins can write debug information to **stderr** without interfering with the JSON protocol (which uses stdout):

```python
import sys

# This goes to the terminal (debug output)
print("Debug: processing request...", file=sys.stderr)

# This goes to Volt (plugin output)
json.dump(output, sys.stdout)
```

---

## Plugin Management Commands

### `volt plugin list`

Show all installed/detected plugins:

```bash
volt plugin list
```

### `volt plugin init <name>`

Create a new plugin scaffold with all the boilerplate:

```bash
volt plugin init my-awesome-plugin
```

This creates a directory with `plugin.json` and a starter entry point file.

### `volt plugin run <manifest> <input>`

Run a plugin manually with test input:

```bash
volt plugin run my-plugin/plugin.json input.json
```

---

## Error Handling

Volt is designed to be resilient to plugin failures. Here's what happens in each error case:

| Situation | What Happens |
|-----------|-------------|
| Plugin exits with non-zero code | Volt logs the error and continues without modifications |
| Plugin exceeds timeout | Volt kills the process, logs a timeout warning, and continues |
| Plugin writes invalid JSON | Volt logs a parse error and continues |
| Plugin writes to stderr | Stderr output is shown as warnings (useful for debugging) |
| Plugin is missing or not found | Volt logs a "plugin not found" warning and continues |
| Plugin entry point is not executable | Volt logs a permission error and continues |

**The golden rule:** A broken plugin should never break your API requests. Volt always continues, even if a plugin fails.

### Writing Resilient Plugins

```python
import json
import sys

def main():
    try:
        input_data = json.load(sys.stdin)
        # ... your logic here ...
        output = {"headers": {"X-Custom": "value"}}
    except json.JSONDecodeError:
        print("Error: Could not parse input JSON", file=sys.stderr)
        output = {"headers": {}}
    except Exception as e:
        print(f"Plugin error: {e}", file=sys.stderr)
        output = {"headers": {}}

    json.dump(output, sys.stdout)

if __name__ == "__main__":
    main()
```

---

## Publishing and Sharing

Plugins are currently local-only. To share a plugin with your team:

1. **Package the plugin directory** — Include the manifest, entry point, and any dependencies
2. **Distribute as a zip or git repository**
3. **Users clone or extract** it into their project
4. **Reference via `volt plugin run`** to use it

```bash
# Clone a shared plugin
git clone https://github.com/your-team/volt-vault-auth.git plugins/vault-auth

# Test it
volt plugin run plugins/vault-auth/plugin.json test-input.json
```

**Coming soon:** Remote plugin installation with `volt plugin install <url>` is planned for a future release.

---

## Best Practices

1. **Keep plugins focused** — Each plugin should do one thing well. Need auth AND logging? Write two plugins.

2. **Handle errors gracefully** — Always catch exceptions and return valid JSON, even on failure. Use stderr for error messages.

3. **Use stderr for debugging** — Never mix debug output with your JSON response. Use `print(..., file=sys.stderr)` for debug info.

4. **Set appropriate timeouts** — The default 5 seconds is fine for most plugins. Increase it for plugins that make network calls (e.g., fetching from Vault). Keep it low for simple computation plugins.

5. **Don't block forever** — If your plugin makes network calls, always set timeouts on those calls too. A hung plugin delays the entire request.

6. **Validate input before processing** — Check that expected fields exist before accessing them. Don't assume the input structure.

7. **Use environment variables for config** — Don't hardcode URLs, tokens, or paths in your plugin. Read them from environment variables or the `VOLT_PROJECT_DIR`.

8. **Test with multiple scenarios** — Create test fixtures for different request types, error cases, and edge conditions.

9. **Document your plugin** — Include a README explaining what it does, what environment variables it needs, and how to configure it.

10. **Keep dependencies minimal** — The simpler your plugin, the easier it is to distribute and maintain.

---

## Plugin Ideas

Looking for inspiration? Here are some plugins you could build:

- **Vault auth provider** — Fetch tokens from HashiCorp Vault, AWS Secrets Manager, or Azure Key Vault
- **TOTP generator** — Generate time-based one-time passwords for 2FA-protected APIs
- **Request signer** — Compute custom HMAC or RSA signatures for APIs that need them
- **Correlation ID injector** — Add unique trace IDs to every request for distributed tracing
- **Response validator** — Validate responses against a custom schema or business rules
- **Metrics collector** — Send response time and status metrics to Prometheus, Datadog, or Grafana
- **Slack notifier** — Alert a Slack channel when API tests fail
- **Request sanitizer** — Remove PII from request logs before saving
- **Dynamic URL rewriter** — Route requests to different backends based on environment
- **Rate limit tracker** — Parse `X-RateLimit-*` headers and warn when approaching limits
- **Response cache** — Cache responses locally for faster development
- **Mock data generator** — Generate realistic test data using Faker

---

## What's Next?

- [Getting Started](getting-started.md) — Install Volt and send your first request
- [Command Reference](commands.md) — Every CLI command and flag
- [Scripting Engine](scripting.md) — Built-in pre/post scripts (no plugin needed)
- [Security & Secrets](security.md) — Encryption and safe credential management
