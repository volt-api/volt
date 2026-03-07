---
layout: page
title: Authentication Guide
---

# Authentication Guide

A complete guide to every authentication method supported by Volt. Whether you are calling a simple REST API with an API key or signing requests for AWS services, this guide walks you through each method with full, runnable `.volt` file examples.

---

## Table of Contents

1. [What is API Authentication?](#1-what-is-api-authentication)
2. [Bearer Token Auth](#2-bearer-token-auth)
3. [Basic Auth](#3-basic-auth)
4. [API Key Auth](#4-api-key-auth)
5. [Digest Auth](#5-digest-auth)
6. [AWS Signature Version 4](#6-aws-signature-version-4)
7. [Hawk Authentication](#7-hawk-authentication)
8. [OAuth 2.0](#8-oauth-20)
9. [Collection-Level Auth](#9-collection-level-auth)
10. [Auth with Variables](#10-auth-with-variables)
11. [Request Signing (HMAC-SHA256)](#11-request-signing-hmac-sha256)
12. [Cookie-Based Auth](#12-cookie-based-auth)
13. [Client Certificates (mTLS)](#13-client-certificates-mtls)
14. [JWT Inspection](#14-jwt-inspection)
15. [Best Practices](#15-best-practices)

---

## 1. What is API Authentication?

When you visit a website and log in with your username and password, the website knows who you are and what you are allowed to do. API authentication works the same way, but for programs talking to other programs.

**Why do APIs need authentication?**

- **Identity** -- The server needs to know *who* is making the request. Is it your application? A different developer's application? A malicious bot?
- **Authorization** -- Even after knowing who you are, the server must decide *what you are allowed to do*. Can you read data? Can you delete records? Can you access other users' data?
- **Rate limiting** -- APIs often limit how many requests you can make. Without authentication, the server cannot track your usage.
- **Billing** -- Many APIs charge per request. Authentication ties requests to a paying account.
- **Audit trails** -- For security and compliance, servers log who did what and when.

Think of it like a building security system. The front door (the API endpoint) is locked. You need a badge (your credentials) to get in, and your badge determines which floors and rooms you can access.

Volt supports many authentication methods because different APIs use different security schemes. The sections below cover each one in detail.

---

## 2. Bearer Token Auth

Bearer token authentication is the most common method you will encounter in modern APIs. You include a token in the `Authorization` header, and the server trusts whoever "bears" (carries) that token.

**How it works:** The server gives you a token (usually after you log in or register for an API key). You send that token with every request. The server checks the token and, if valid, processes your request.

**When to use it:** REST APIs, services that issue JWT tokens, APIs behind OAuth 2.0 flows, and most SaaS platforms (GitHub, Stripe, Slack, etc.).

### .volt file example

```yaml
# get-profile.volt
# Fetch the authenticated user's profile using a bearer token.

name: Get My Profile
description: Retrieve current user info with bearer token auth
method: GET
url: https://api.example.com/v1/me

headers:
  - Accept: application/json

auth:
  type: bearer
  token: eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U

tests:
  - status equals 200
  - $.name exists
```

Run it:

```bash
volt run get-profile.volt
```

**What Volt does behind the scenes:** It adds the header `Authorization: Bearer eyJhbGci...` to your request. You do not need to write that header manually.

### Using a variable for the token

In practice, you should never hardcode tokens in your `.volt` files. Use a variable instead:

```yaml
auth:
  type: bearer
  token: "{{$api_token}}"
```

See [Auth with Variables](#10-auth-with-variables) and [Best Practices](#15-best-practices) for more.

---

## 3. Basic Auth

Basic authentication sends a username and password with every request. Despite the name, it is still widely used, especially for internal APIs, legacy systems, and services that prefer simplicity over token-based flows.

**How it works:**

1. You provide a username and password.
2. The client combines them into the string `username:password`.
3. That string is encoded using **Base64** (a way to represent binary data as ASCII text -- it is *not* encryption).
4. The encoded string is sent in the `Authorization` header as `Basic dXNlcm5hbWU6cGFzc3dvcmQ=`.

**Important:** Base64 is *encoding*, not *encryption*. Anyone who intercepts the request can decode it instantly. Always use HTTPS with Basic auth.

### .volt file example

```yaml
# list-repos.volt
# List repositories using basic auth credentials.

name: List Repositories
description: Fetch all repos for the authenticated user
method: GET
url: https://api.example.com/v1/repos

headers:
  - Accept: application/json

auth:
  type: basic
  username: jdoe
  password: s3cret-passw0rd

tests:
  - status equals 200
  - $.length greater_than 0
```

Run it:

```bash
volt run list-repos.volt
```

**What Volt does behind the scenes:** It Base64-encodes `jdoe:s3cret-passw0rd` to produce `amRvZTpzM2NyZXQtcGFzc3cwcmQ=`, then sends the header `Authorization: Basic amRvZTpzM2NyZXQtcGFzc3cwcmQ=`.

### With variables for credentials

```yaml
auth:
  type: basic
  username: "{{$basic_user}}"
  password: "{{$basic_pass}}"
```

Define `$basic_user` and `$basic_pass` in your `_env.volt` file (the `$` prefix marks them as secrets, so Volt will mask their values in output).

---

## 4. API Key Auth

Many APIs issue a static API key that you send with every request. The key can be placed either in a **header** or as a **query parameter**, depending on the API's requirements.

**How it works:** When you sign up for a service, it gives you a key (a long random string). You include that key in a specific location in every request. The server looks for the key, validates it, and determines your access level.

### API key in a header

Most APIs expect the key in a custom header like `X-API-Key`, `Authorization`, or a service-specific name.

```yaml
# weather-forecast.volt
# Get the 5-day weather forecast using an API key in a header.

name: Weather Forecast
description: Fetch 5-day forecast for London
method: GET
url: https://api.weather.example.com/v2/forecast?city=London&days=5

auth:
  type: api_key
  key_name: X-API-Key
  key_value: wk_live_abc123def456ghi789
  key_location: header

tests:
  - status equals 200
  - $.forecast exists
```

**What Volt does:** It adds the header `X-API-Key: wk_live_abc123def456ghi789` to the request.

### API key as a query parameter

Some APIs (especially older ones or map services) expect the key in the URL query string.

```yaml
# geocode.volt
# Geocode an address with the API key in the query string.

name: Geocode Address
description: Convert an address to latitude/longitude
method: GET
url: https://maps.example.com/api/geocode?address=1600+Amphitheatre+Parkway

auth:
  type: api_key
  key_name: apikey
  key_value: gk_12345abcde67890fghij
  key_location: query

tests:
  - status equals 200
  - $.lat exists
  - $.lng exists
```

**What Volt does:** It appends `&apikey=gk_12345abcde67890fghij` to the URL, making the final URL `https://maps.example.com/api/geocode?address=1600+Amphitheatre+Parkway&apikey=gk_12345abcde67890fghij`.

### The `key_location` field

| Value   | Where the key is placed              |
|---------|--------------------------------------|
| `header`| Added as an HTTP header              |
| `query` | Appended to the URL query string     |

If you omit `key_location`, Volt defaults to `header`.

---

## 5. Digest Auth

Digest authentication is a challenge-response protocol that avoids sending your password in plain text (unlike Basic auth). It is less common today but still used by some enterprise systems and network devices.

**How it works (simplified):**

1. The client makes a request without credentials.
2. The server responds with `401 Unauthorized` and includes a challenge: a unique `nonce` (a one-time random value) and other parameters.
3. The client computes a cryptographic hash (MD5 or SHA-256) that mixes together the username, password, nonce, request method, and URL.
4. The client resends the request with the computed hash in the `Authorization` header.
5. The server performs the same computation and compares results. If they match, access is granted.

**Why this is better than Basic auth:** The password is never sent over the wire, even in encoded form. An attacker who intercepts the request sees only the hash, which cannot be reversed to reveal the password.

### .volt file example

```yaml
# digest-protected.volt
# Access a resource protected by digest authentication.

name: Digest Auth Resource
description: Access protected endpoint using digest auth
method: GET
url: https://httpbin.org/digest-auth/auth/myuser/mypassword/SHA-256

auth:
  type: digest
  username: myuser
  password: mypassword

tests:
  - status equals 200
  - $.authenticated equals true
```

Run it:

```bash
volt run digest-protected.volt
```

**What Volt does:** It handles the full challenge-response handshake automatically. You only need to provide the username and password -- Volt takes care of the nonce, hash computation, and retry.

---

## 6. AWS Signature Version 4

AWS Signature Version 4 (SigV4) is the authentication method required by all Amazon Web Services APIs. It is a sophisticated signing scheme that creates a cryptographic signature from your request details and secret key.

**When do you need this?** Whenever you call an AWS API directly (S3, DynamoDB, Lambda, SQS, SNS, EC2, etc.) without using an AWS SDK. If you are testing AWS endpoints or building infrastructure tooling, this is the auth method you need.

**How it works (simplified):**

1. A "canonical request" is built from the HTTP method, URL, query parameters, headers, and payload hash.
2. A "string to sign" is created from the timestamp, credential scope, and the hash of the canonical request.
3. A signing key is derived by running your secret key through a chain of HMAC-SHA256 operations using the date, region, and service name.
4. The final signature is computed by HMAC-signing the "string to sign" with the derived key.
5. The `Authorization` header is assembled with your access key, credential scope, signed headers list, and the signature.

### .volt file example

```yaml
# list-s3-bucket.volt
# List objects in an S3 bucket using AWS SigV4 authentication.

name: List S3 Bucket
description: List objects in my-data-bucket using AWS SigV4
method: GET
url: https://my-data-bucket.s3.us-east-1.amazonaws.com/?list-type=2&max-keys=10

headers:
  - Accept: application/xml

auth:
  type: aws
  access_key: AKIAIOSFODNN7EXAMPLE
  secret_key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
  region: us-east-1
  service: s3

tests:
  - status equals 200
```

Run it:

```bash
volt run list-s3-bucket.volt
```

### Field reference

| Field            | Description                                                        | Required |
|------------------|--------------------------------------------------------------------|----------|
| `access_key`     | Your AWS access key ID (starts with `AKIA...`)                     | Yes      |
| `secret_key`     | Your AWS secret access key                                         | Yes      |
| `region`         | AWS region (e.g., `us-east-1`, `eu-west-2`, `ap-southeast-1`)     | Yes      |
| `service`        | AWS service name (e.g., `s3`, `dynamodb`, `execute-api`, `lambda`) | Yes      |
| `session_token`  | Temporary session token (for assumed roles or temporary credentials)| No       |

### Using temporary credentials (STS)

If you are using AWS STS (Security Token Service) to assume a role, you will have a session token in addition to the access key and secret key:

```yaml
# assumed-role-request.volt
# Query DynamoDB using temporary credentials from STS AssumeRole.

name: DynamoDB Query
description: Query the users table with temporary STS credentials
method: POST
url: https://dynamodb.us-east-1.amazonaws.com/

headers:
  - Content-Type: application/x-amz-json-1.0
  - X-Amz-Target: DynamoDB_20120810.Query

auth:
  type: aws
  access_key: ASIAIOSFODNN7EXAMPLE
  secret_key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
  region: us-east-1
  service: dynamodb
  session_token: FwoGZXIvYXdzEBYaDH...long-token-here

body:
  type: json
  content: |
    {
      "TableName": "users",
      "KeyConditionExpression": "pk = :pk",
      "ExpressionAttributeValues": {
        ":pk": {"S": "USER#123"}
      }
    }

tests:
  - status equals 200
```

### With variables

```yaml
auth:
  type: aws
  access_key: "{{$AWS_ACCESS_KEY_ID}}"
  secret_key: "{{$AWS_SECRET_ACCESS_KEY}}"
  region: "{{aws_region}}"
  service: s3
```

**What Volt does:** Volt automatically generates the `X-Amz-Date` header, computes the payload hash, derives the signing key, builds the canonical request, and assembles the full `Authorization` header. You just provide your credentials and tell Volt which region and service to sign for.

---

## 7. Hawk Authentication

Hawk is an HTTP authentication scheme designed by Mozilla. It provides HMAC-based request authentication -- each request is signed with a shared secret key, a timestamp, and a random nonce. This makes it resistant to replay attacks.

**When do you need this?** When your API uses the Hawk authentication scheme (common in Mozilla services and some enterprise APIs).

**How it works:**

1. The client and server share a secret key and an ID.
2. For each request, the client generates a timestamp and a random nonce.
3. A "normalized string" is built from the Hawk version, timestamp, nonce, HTTP method, URL path, host, and port.
4. The string is signed using HMAC-SHA256 with the shared key.
5. The MAC (message authentication code), along with the ID, timestamp, and nonce, are placed in the `Authorization: Hawk ...` header.

**Replay protection:** Because the timestamp and nonce are included in the MAC, an attacker who intercepts a request cannot replay it -- the server will reject duplicate nonces and stale timestamps.

### .volt file example

```yaml
# hawk-protected.volt
# Access a Hawk-authenticated API endpoint.

name: Hawk Protected Resource
description: Fetch a resource secured by Hawk authentication
method: GET
url: https://api.example.com/resource/123?filter=active

auth:
  type: hawk
  hawk_id: dh37fgj492je
  hawk_key: werxhqb98rpaxn39848xrunpaw3489ruxnpa98w4rxn
  hawk_algorithm: sha256
  hawk_ext: some-app-specific-data

tests:
  - status equals 200
```

Run it:

```bash
volt run hawk-protected.volt
```

### Field reference

| Field            | Description                                              | Required |
|------------------|----------------------------------------------------------|----------|
| `hawk_id`        | Your Hawk credential identifier                          | Yes      |
| `hawk_key`       | The shared secret key                                    | Yes      |
| `hawk_algorithm` | HMAC algorithm to use (currently `sha256`)               | Yes      |
| `hawk_ext`       | Application-specific extension data included in the MAC  | No       |

**What Volt does:** It generates the timestamp, creates a cryptographically random nonce, builds the Hawk normalized string, computes the HMAC-SHA256 MAC, and assembles the full `Authorization: Hawk id="...", ts="...", nonce="...", mac="..."` header. If you provide a request body, Volt also computes and includes the payload hash.

---

## 8. OAuth 2.0

OAuth 2.0 is an authorization framework that lets applications access resources on behalf of a user (or on their own behalf) without sharing passwords. It is the standard used by virtually every major platform: Google, GitHub, Facebook, Microsoft, Slack, and thousands more.

### What is OAuth? A beginner-friendly explanation

Imagine you want a house-cleaning service to enter your home while you are at work. You would not give them a copy of your master key. Instead, you give them a temporary code for the smart lock that works only during business hours and only opens the front door, not the safe.

That is OAuth in a nutshell:

- **You** are the resource owner (it is your house / your data).
- **The cleaning service** is the application (the "client") that wants access.
- **The smart lock system** is the authorization server (Google, GitHub, etc.).
- **The temporary code** is the access token.
- **The restrictions** (hours, which doors) are the scopes.

OAuth lets users grant applications limited access to their accounts without revealing their passwords.

### OAuth grant types in Volt

Volt supports four OAuth 2.0 grant types:

| Grant Type         | `.volt` auth type    | Use Case                                            |
|--------------------|----------------------|-----------------------------------------------------|
| Client Credentials | `oauth_cc`           | Server-to-server, no user involved                  |
| Password Grant     | `oauth_password`     | Trusted first-party apps (legacy, avoid if possible) |
| Authorization Code + PKCE | `volt login`  | User-facing apps, browser-based login               |
| Implicit           | `oauth_implicit`     | Single-page apps (legacy, not recommended)           |

---

### 8a. Client Credentials Flow

The Client Credentials flow is for **machine-to-machine** communication. There is no user involved -- the application authenticates as itself. This is the simplest OAuth flow.

**When to use it:** Backend services calling other backend services, cron jobs, data pipelines, CI/CD scripts.

```yaml
# fetch-analytics.volt
# Fetch analytics data using OAuth 2.0 Client Credentials.

name: Fetch Analytics
description: Machine-to-machine API call with client credentials
method: GET
url: https://api.example.com/v1/analytics/summary

auth:
  type: oauth_cc
  client_id: my-analytics-app
  client_secret: cc_secret_a1b2c3d4e5f6
  token_url: https://auth.example.com/oauth/token
  scope: analytics:read reports:read

tests:
  - status equals 200
  - $.total_views exists
```

**How it works:**

1. Volt sends a `POST` request to the `token_url` with `grant_type=client_credentials`, your `client_id`, `client_secret`, and requested `scope`.
2. The authorization server verifies your credentials and returns an access token.
3. Volt attaches that token as a `Bearer` token to your actual API request.

### Field reference for `oauth_cc`

| Field           | Description                                  | Required |
|-----------------|----------------------------------------------|----------|
| `client_id`     | Application client ID                        | Yes      |
| `client_secret` | Application client secret                    | Yes      |
| `token_url`     | Token endpoint URL                           | Yes      |
| `scope`         | Space-separated list of requested scopes     | No       |

---

### 8b. Password Grant Flow

The Password Grant (also called Resource Owner Password Credentials) sends the user's username and password directly to the token endpoint. The authorization server validates them and returns an access token.

**When to use it:** Only for highly trusted first-party applications where the user trusts the app with their credentials. This flow is considered legacy and is not recommended for new applications.

```yaml
# user-data.volt
# Fetch user data using OAuth 2.0 Password Grant.

name: Fetch User Data
description: Authenticate with username/password to get user profile
method: GET
url: https://api.example.com/v1/user/profile

auth:
  type: oauth_password
  client_id: my-mobile-app
  client_secret: pw_secret_x9y8z7
  token_url: https://auth.example.com/oauth/token
  scope: profile email
  username: jane@example.com
  password: correct-horse-battery-staple

tests:
  - status equals 200
  - $.email equals jane@example.com
```

**How it works:**

1. Volt sends a `POST` request to the `token_url` with `grant_type=password`, your `client_id`, `client_secret`, `username`, `password`, and `scope`.
2. The server validates the credentials and returns an access token.
3. Volt uses that token as a `Bearer` token for your request.

---

### 8c. Authorization Code + PKCE (Browser Login)

The Authorization Code flow with PKCE (Proof Key for Code Exchange) is the most secure OAuth flow for user-facing applications. Volt implements this as an interactive login command that opens your browser, handles the callback, and stores the token locally.

**When to use it:** Logging in as a user to services like GitHub, Google, or any OAuth 2.0 provider.

#### Login to GitHub

```bash
volt login github
```

Volt will:

1. Generate a cryptographically random PKCE code verifier and code challenge.
2. Generate a random CSRF state parameter.
3. Build the authorization URL with `response_type=code`, `code_challenge`, and `code_challenge_method=S256`.
4. Open your default browser to the GitHub authorization page.
5. Start a local callback server on `http://localhost:9876/callback`.
6. Wait for GitHub to redirect back with an authorization code.
7. Exchange the code (plus the PKCE code verifier) for an access token.
8. Store the token in `.volt-tokens`.

#### Login to Google

```bash
volt login google
```

The same PKCE flow, but with Google's OAuth endpoints and `openid profile email` scopes.

#### Login to a custom OAuth provider

```bash
volt login custom \
  --auth-url https://login.mycompany.com/authorize \
  --token-url https://login.mycompany.com/token \
  --client-id my-volt-app \
  --scopes "openid profile api:read"
```

#### Check login status

```bash
volt login --status
```

Shows whether you have an active token, which provider it is from, and when it expires.

#### Logout (clear stored tokens)

```bash
volt login --logout
```

Removes all tokens from the `.volt-tokens` storage file.

#### How PKCE works (for the curious)

Traditional OAuth requires a `client_secret` to exchange the authorization code for a token. But CLI tools and mobile apps cannot safely store a secret. PKCE solves this:

1. The client generates a random `code_verifier` (a 43-character Base64URL string).
2. It computes `code_challenge = Base64URL(SHA256(code_verifier))`.
3. The authorization request includes only the `code_challenge`.
4. When exchanging the authorization code for a token, the client sends the original `code_verifier`.
5. The server hashes the verifier and compares it to the stored challenge. Only the original client could know the verifier.

This means even if an attacker intercepts the authorization code, they cannot exchange it without the code verifier.

---

### 8d. Implicit Flow

The Implicit flow returns the access token directly in the URL fragment (after the `#`). It was designed for single-page applications that cannot securely store a client secret.

**Important:** The Implicit flow is considered **legacy** and is not recommended for new applications. Use Authorization Code + PKCE instead.

```yaml
# implicit-flow.volt
# Configure implicit OAuth for a single-page app.

name: Implicit Flow Config
description: Implicit OAuth (legacy, prefer PKCE)
method: GET
url: https://api.example.com/v1/dashboard

auth:
  type: oauth_implicit
  client_id: my-spa-app
  auth_url: https://auth.example.com/authorize
  token_url: https://auth.example.com/token
  scope: read write

tests:
  - status equals 200
```

**How it differs:** The authorization request uses `response_type=token` instead of `response_type=code`. The access token is returned directly in the URL fragment, skipping the code exchange step entirely. This is less secure because the token is exposed in the browser history and URL bar.

---

### 8e. CLI OAuth command

Volt also provides a standalone OAuth command for obtaining tokens outside of `.volt` files:

```bash
# Client Credentials grant from the command line
volt auth oauth https://auth.example.com/token \
  --client-id my-app \
  --client-secret my-secret \
  --scope "read write"

# Password grant from the command line
volt auth oauth https://auth.example.com/token \
  --grant password \
  --username user@example.com \
  --password s3cret \
  --client-id my-app \
  --client-secret my-secret
```

This fetches and displays the token directly, which you can then use in your `.volt` files or scripts.

---

## 9. Collection-Level Auth

When you have a folder full of `.volt` files that all need the same authentication, you do not want to repeat the `auth:` block in every single file. Instead, create a `_collection.volt` file in the directory, and all requests in that folder will inherit its settings.

### Example project structure

```
api/
  _collection.volt       # Shared auth + headers for all requests
  _env.volt              # Environment variables and secrets
  get-users.volt
  create-user.volt
  delete-user.volt
  get-profile.volt
```

### `_collection.volt`

```yaml
# _collection.volt
# Shared configuration for all requests in this directory.

name: My API Collection

headers:
  - Accept: application/json
  - X-Client-Version: 2.1.0

auth:
  type: bearer
  token: "{{$api_token}}"

variables:
  base_url: https://api.example.com/v2
```

### `get-users.volt`

```yaml
# get-users.volt
# This request inherits auth and headers from _collection.volt.
# No need to repeat the auth: block.

name: List Users
method: GET
url: "{{base_url}}/users?page=1&limit=20"

tests:
  - status equals 200
  - $.data.length greater_than 0
```

### `create-user.volt`

```yaml
# create-user.volt
# Also inherits collection-level auth automatically.

name: Create User
method: POST
url: "{{base_url}}/users"

headers:
  - Content-Type: application/json

body:
  type: json
  content: |
    {
      "name": "Alice Johnson",
      "email": "alice@example.com",
      "role": "editor"
    }

tests:
  - status equals 201
  - $.id exists
```

Run the entire collection:

```bash
volt collection api/
```

Every request in the `api/` directory inherits the bearer token auth, the shared headers, and the `base_url` variable from `_collection.volt`.

**Key points:**

- The `_collection.volt` file must be named exactly `_collection.volt` (with the underscore prefix).
- Request-level `auth:` overrides the collection-level auth for that specific request.
- Variables defined in `_collection.volt` are available to all requests in the directory.

---

## 10. Auth with Variables

Hardcoding credentials in `.volt` files is convenient for learning but dangerous in practice. Volt's variable system lets you separate secrets from request definitions.

### Variable interpolation syntax

Use `{{variable_name}}` anywhere in a `.volt` file to insert a variable's value:

```yaml
auth:
  type: bearer
  token: "{{$api_token}}"
```

### Where variables come from

Volt resolves variables in this order (highest priority first):

1. **Request variables** -- defined in the `variables:` section of the `.volt` file
2. **Runtime variables** -- set dynamically during collection runs (e.g., extracted from a previous response)
3. **Collection variables** -- defined in `_collection.volt`
4. **Environment variables** -- defined in `_env.volt` for the active environment
5. **Global variables** -- set via `volt env set`
6. **Dynamic variables** -- built-in variables like `$timestamp`, `$randomUUID`, etc.

### Setting up `_env.volt`

Create an `_env.volt` file in your project root:

```yaml
# _env.volt
# Environment-specific variables. Add this file to .gitignore!

environment: development
variables:
  base_url: https://api.dev.example.com
  $api_token: dev_tk_a1b2c3d4e5f6g7h8i9j0
  $basic_user: dev-admin
  $basic_pass: dev-password-123
  $aws_access_key: AKIAIOSFODNN7EXAMPLE
  $aws_secret_key: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
```

**The `$` prefix:** Variables whose names start with `$` are treated as **secrets**. Volt will mask their values in terminal output, replacing them with `***`. This prevents accidental exposure of sensitive data in logs, screenshots, and CI output.

### Using environment variables in auth

```yaml
# secure-request.volt
# All credentials come from _env.volt, nothing is hardcoded.

name: Secure Request
method: GET
url: "{{base_url}}/v1/protected-resource"

auth:
  type: bearer
  token: "{{$api_token}}"

tests:
  - status equals 200
```

### Switching environments

You can define multiple environments:

```yaml
# _env.volt

environment: production
variables:
  base_url: https://api.example.com
  $api_token: prod_tk_REAL_TOKEN_HERE
```

Activate an environment:

```bash
volt env set active production
```

### Extracted variables (chaining requests)

When running a collection, you can extract values from one response and use them in subsequent requests. A common pattern is logging in first, then using the returned token:

```yaml
# 01-login.volt
name: Login
method: POST
url: "{{base_url}}/auth/login"

body:
  type: json
  content: |
    {
      "email": "{{$login_email}}",
      "password": "{{$login_password}}"
    }

variables:
  auth_token: $.access_token

tests:
  - status equals 200
  - $.access_token exists
```

```yaml
# 02-get-data.volt
name: Get Protected Data
method: GET
url: "{{base_url}}/data"

auth:
  type: bearer
  token: "{{auth_token}}"

tests:
  - status equals 200
```

When you run `volt collection api/`, Volt executes files alphabetically. The `auth_token` extracted from the login response is automatically available to subsequent requests.

---

## 11. Request Signing (HMAC-SHA256)

Some APIs require request signing -- a cryptographic signature computed from the request details that proves the request has not been tampered with in transit. This is different from authentication (which proves *who* you are) -- signing proves the request *has not been modified*.

Volt supports a `signing:` section in `.volt` files and a `--sign` flag to activate signing.

### How request signing works

1. A **canonical request** is built from the HTTP method, URL, sorted headers, and a SHA-256 hash of the body.
2. The canonical request is signed with HMAC-SHA256 using your secret key.
3. The resulting signature is added as a custom header (default: `X-Signature`).
4. Optionally, a timestamp header is added (default: `X-Timestamp`).

### .volt file example

```yaml
# signed-webhook.volt
# Send a signed webhook notification.

name: Signed Webhook
description: Send a webhook payload with HMAC-SHA256 signature
method: POST
url: https://hooks.example.com/ingest

headers:
  - Content-Type: application/json

body:
  type: json
  content: |
    {
      "event": "order.completed",
      "order_id": "ORD-12345",
      "amount": 99.99,
      "currency": "USD"
    }

signing:
  method: hmac_sha256
  secret_key: whsec_MIGfMA0GCSqGSIb3DQEBAQUAA4GN
  header_name: X-Webhook-Signature
  include_timestamp: true
  timestamp_header: X-Webhook-Timestamp

tests:
  - status equals 200
```

Run it with the `--sign` flag:

```bash
volt run signed-webhook.volt --sign
```

**What Volt does:** It builds the canonical request string `POST\nhttps://hooks.example.com/ingest\nContent-Type:application/json\n<body-sha256-hash>`, computes the HMAC-SHA256 signature, and adds the `X-Webhook-Signature` and `X-Webhook-Timestamp` headers.

### Signing configuration reference

| Field               | Description                                           | Default           |
|---------------------|-------------------------------------------------------|-------------------|
| `method`            | Signing method: `hmac_sha256`, `aws_sigv4`, `custom`  | `hmac_sha256`     |
| `secret_key`        | The secret key for HMAC signing                       | (required)        |
| `header_name`       | Header name for the signature                         | `X-Signature`     |
| `include_timestamp` | Whether to add a timestamp header                     | `true`            |
| `timestamp_header`  | Header name for the timestamp                         | `X-Timestamp`     |
| `access_key`        | Access key (for `aws_sigv4` method)                   | (for aws_sigv4)   |
| `region`            | AWS region (for `aws_sigv4` method)                   | (for aws_sigv4)   |
| `service`           | AWS service (for `aws_sigv4` method)                  | (for aws_sigv4)   |

### Custom signing header name

```yaml
signing:
  method: hmac_sha256
  secret_key: "{{$signing_secret}}"
  header_name: X-Api-Signature
  include_timestamp: false
```

---

## 12. Cookie-Based Auth

Many web applications use cookie-based authentication: you log in, the server sets a session cookie, and your browser sends that cookie with every subsequent request. Volt supports this pattern through **named sessions**.

### How named sessions work

A named session persists cookies and headers across multiple requests. When you use `--session=myapi`, Volt:

1. Loads any existing session data from `.volt-sessions/<host>/<name>.json`.
2. Applies stored cookies and headers to the outgoing request.
3. After receiving the response, saves any `Set-Cookie` headers back to the session file.
4. The next request with the same session name will include those cookies automatically.

### Example: Login and use cookies

**Step 1: Log in (creates the session)**

```yaml
# login.volt
# Log in to the web app. The server will set a session cookie.

name: Login
method: POST
url: https://webapp.example.com/api/login

headers:
  - Content-Type: application/json

body:
  type: json
  content: |
    {
      "email": "user@example.com",
      "password": "my-password"
    }

tests:
  - status equals 200
```

```bash
volt run login.volt --session=webapp
```

The server responds with `Set-Cookie: session_id=abc123; HttpOnly; Secure`. Volt saves this to `.volt-sessions/webapp.example.com/webapp.json`.

**Step 2: Make authenticated requests (cookies sent automatically)**

```yaml
# dashboard.volt
# Fetch the dashboard. Session cookie is sent automatically.

name: Dashboard
method: GET
url: https://webapp.example.com/api/dashboard

tests:
  - status equals 200
  - $.user.email equals user@example.com
```

```bash
volt run dashboard.volt --session=webapp
```

Volt automatically includes the `Cookie: session_id=abc123` header.

### Read-only sessions

If you want to use a session's cookies without updating them (useful for testing):

```bash
volt run test-endpoint.volt --session-read-only=webapp
```

This loads the session but does not save any new cookies from the response.

### Session file storage

Session data is stored in:

```
.volt-sessions/
  <host>/
    <session-name>.json
```

For example, `.volt-sessions/webapp.example.com/webapp.json`.

---

## 13. Client Certificates (mTLS)

Mutual TLS (mTLS) is a security pattern where both the client and the server present certificates to verify each other's identity. Standard HTTPS only verifies the server's identity. With mTLS, the server also verifies the client.

**When do you need this?** Enterprise APIs, banking systems, government services, internal microservices with zero-trust security, and any API that requires client certificate authentication.

### Command-line flags

```bash
# Provide a client certificate and private key
volt run api/request.volt --cert client.pem --cert-key client-key.pem

# Also specify a custom CA bundle (for self-signed server certificates)
volt run api/request.volt --cert client.pem --cert-key client-key.pem --ca-bundle /path/to/ca.crt
```

### .volt file example with mTLS

```yaml
# mtls-request.volt
# Access a mutual TLS-protected internal API.

name: Internal Service Call
description: Call the payments microservice with client certificate
method: POST
url: https://payments.internal.example.com/v1/process

headers:
  - Content-Type: application/json

body:
  type: json
  content: |
    {
      "order_id": "ORD-67890",
      "amount": 150.00,
      "currency": "EUR"
    }

tests:
  - status equals 200
  - $.transaction_id exists
```

```bash
volt run mtls-request.volt \
  --cert /etc/ssl/client/app.pem \
  --cert-key /etc/ssl/client/app-key.pem \
  --ca-bundle /etc/ssl/ca/internal-ca.crt
```

### Flag reference

| Flag           | Description                                               |
|----------------|-----------------------------------------------------------|
| `--cert`       | Path to the client certificate file (PEM format)          |
| `--cert-key`   | Path to the client certificate's private key (PEM format) |
| `--ca-bundle`  | Path to a custom CA certificate bundle (PEM format)       |
| `--verify=no`  | Skip TLS verification entirely (for development only)     |
| `--ssl=tls1.2` | Pin a specific TLS version (e.g., `tls1.2`, `tls1.3`)    |

### Skipping TLS verification (development only)

When working with self-signed certificates in development:

```bash
volt run api/dev-endpoint.volt --verify=no
```

**Warning:** Never use `--verify=no` in production or CI. It disables all certificate validation, making the connection vulnerable to man-in-the-middle attacks.

---

## 14. JWT Inspection

JSON Web Tokens (JWTs) are the most common token format used with Bearer auth and OAuth 2.0. Volt provides built-in tools to decode and inspect JWTs without sending a request.

### What is a JWT?

A JWT is a compact, URL-safe token format with three parts separated by dots:

```
eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.sHnNrPGCOz6vH8OM6ewX2aH-VKrT0UFgMB1VNR-6ppQ
|---- Header ----||----- Payload -----||----- Signature -----|
```

- **Header** -- specifies the signing algorithm (e.g., `HS256`, `RS256`).
- **Payload** -- contains the claims (user ID, expiry time, scopes, etc.).
- **Signature** -- a cryptographic signature that verifies the token has not been tampered with.

Each part is Base64URL-encoded. You can decode the header and payload without the secret key (they are not encrypted, just encoded).

### Inspecting JWTs with Volt

Volt can decode JWTs from Bearer auth in your `.volt` files, showing the decoded header, payload, and expiry status. This is useful for debugging:

- Is the token expired?
- What scopes does it include?
- Which algorithm was used to sign it?
- Who issued it?

### Example: A token that you can inspect

```yaml
# inspect-token.volt
# The token in this file can be decoded to inspect its claims.

name: Token Inspection Example
method: GET
url: https://api.example.com/protected

auth:
  type: bearer
  token: eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyXzEyMyIsIm5hbWUiOiJBbGljZSIsImVtYWlsIjoiYWxpY2VAZXhhbXBsZS5jb20iLCJyb2xlIjoiYWRtaW4iLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MTcwMDAwMzYwMCwiaXNzIjoiaHR0cHM6Ly9hdXRoLmV4YW1wbGUuY29tIiwiYXVkIjoiaHR0cHM6Ly9hcGkuZXhhbXBsZS5jb20ifQ.signature-here
```

Decoding the payload reveals:

```json
{
  "sub": "user_123",
  "name": "Alice",
  "email": "alice@example.com",
  "role": "admin",
  "iat": 1700000000,
  "exp": 1700003600,
  "iss": "https://auth.example.com",
  "aud": "https://api.example.com"
}
```

### Common JWT claims

| Claim | Full Name | Description                                |
|-------|-----------|--------------------------------------------|
| `sub` | Subject   | Who the token represents (user ID)         |
| `iss` | Issuer    | Who issued the token (auth server URL)     |
| `aud` | Audience  | Who the token is intended for (API URL)    |
| `exp` | Expiry    | Unix timestamp when the token expires      |
| `iat` | Issued At | Unix timestamp when the token was created  |
| `nbf` | Not Before| Token is not valid before this time        |
| `scope`| Scope    | Space-separated list of permissions        |

### Expiry checking

When Volt encounters a JWT-formatted bearer token, it can check the `exp` claim against the current time and warn you if the token is expired or about to expire. This is especially useful when working with OAuth flows where tokens have a limited lifetime.

Volt's OAuth token storage (`.volt-tokens`) also tracks expiry and supports **auto-refresh**: if a stored token has a `refresh_token` and is within 5 minutes of expiry, Volt can automatically refresh it before making the request.

---

## 15. Best Practices

### Never hardcode secrets in `.volt` files

This is the most important rule. If your `.volt` files are committed to git, anyone with access to the repository can see your credentials.

**Bad:**

```yaml
auth:
  type: bearer
  token: sk_live_REAL_PRODUCTION_TOKEN_HERE
```

**Good:**

```yaml
auth:
  type: bearer
  token: "{{$api_token}}"
```

### Use `_env.volt` for credentials and add it to `.gitignore`

```yaml
# _env.volt

environment: development
variables:
  base_url: https://api.dev.example.com
  $api_token: dev_tk_a1b2c3d4e5f6
  $client_secret: cs_dev_xyz789
```

Add to `.gitignore`:

```
_env.volt
.volt-tokens
.volt-sessions/
```

### Use the `$` prefix for secret variables

Variables prefixed with `$` are treated as secrets by Volt. Their values are **masked** in terminal output (displayed as `***`), preventing accidental exposure in:

- Terminal output
- CI/CD logs
- Screen recordings and screenshots
- Log files

```yaml
# _env.volt
variables:
  base_url: https://api.example.com      # Not sensitive, no prefix
  $api_key: sk_live_abc123               # Sensitive! Use $ prefix
  $db_password: supersecret              # Sensitive! Use $ prefix
  api_version: v2                        # Not sensitive, no prefix
```

### Use collection-level auth

Do not repeat auth blocks in every file. Set auth once in `_collection.volt` and let all requests inherit it:

```yaml
# _collection.volt
auth:
  type: bearer
  token: "{{$api_token}}"
```

### Use environment-specific credentials

Maintain separate credentials for development, staging, and production:

```
project/
  _env.volt              # Development (gitignored)
  _env.staging.volt      # Staging (gitignored)
  _env.production.volt   # Production (gitignored)
```

### Rotate credentials regularly

- API keys should be rotated periodically.
- OAuth tokens should have short expiry times with refresh tokens.
- If a credential is accidentally committed, rotate it immediately.

### Use encrypted secrets for team sharing

If you need to share secrets in version control (for CI/CD, for example), use Volt's built-in encryption:

```bash
# Generate an encryption key
volt secrets keygen

# Encrypt sensitive fields in a .volt file
volt secrets encrypt api/config.volt <encryption-key>

# Decrypt when needed
volt secrets decrypt api/config.volt <encryption-key>
```

### Detect accidentally exposed secrets

Volt can scan your files for unencrypted secrets:

```bash
volt secrets detect api/
```

This checks for patterns that look like API keys, tokens, and passwords.

### Summary of auth types

| Auth Type        | `.volt` `type:` value | Best For                                      |
|------------------|-----------------------|-----------------------------------------------|
| Bearer Token     | `bearer`              | Most modern REST APIs                         |
| Basic Auth       | `basic`               | Legacy APIs, simple internal services         |
| API Key          | `api_key`             | Public APIs with key-based access             |
| Digest Auth      | `digest`              | Enterprise systems, network devices           |
| AWS SigV4        | `aws`                 | All AWS services (S3, DynamoDB, Lambda, etc.) |
| Hawk             | `hawk`                | Mozilla services, HMAC-based APIs             |
| OAuth 2.0 CC     | `oauth_cc`            | Machine-to-machine, backend services          |
| OAuth 2.0 PW     | `oauth_password`      | Trusted first-party apps (legacy)             |
| OAuth 2.0 PKCE   | `volt login`          | User-facing apps, browser login               |
| OAuth 2.0 Implicit| `oauth_implicit`     | Legacy single-page apps (avoid)               |
| HMAC Signing     | `signing:` section    | Webhook verification, request integrity       |
| Cookie Sessions  | `--session=name`      | Web applications, stateful APIs               |
| Client Cert mTLS | `--cert` / `--cert-key`| Enterprise, banking, zero-trust              |

---

*For the full command reference, see the [Commands documentation](commands.md). For the `.volt` file format specification, see the [Format Spec](format-spec.md).*
