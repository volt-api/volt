---
layout: page
title: Protocols Guide
---

# Protocols Guide

Volt is not just an HTTP client. It speaks nine different network protocols, giving you a single tool for testing REST APIs, GraphQL endpoints, real-time WebSocket connections, IoT message brokers, and more. This guide covers every protocol Volt supports, with complete examples and explanations suitable for beginners and experienced developers alike.

---

## Table of Contents

- [What Are Network Protocols?](#what-are-network-protocols)
- [HTTP/HTTPS](#httphttps)
- [HTTP/2](#http2)
- [HTTP/3 (QUIC)](#http3-quic)
- [GraphQL](#graphql)
- [WebSocket](#websocket)
- [Server-Sent Events (SSE)](#server-sent-events-sse)
- [MQTT](#mqtt)
- [Socket.IO](#socketio)
- [gRPC](#grpc)
- [Protocol Comparison Table](#protocol-comparison-table)

---

## What Are Network Protocols?

A **network protocol** is a set of rules that two computers follow when they communicate over a network. Think of it like a language: if two people want to have a conversation, they need to agree on which language to speak, how to take turns, and how to signal when the conversation is over.

When you open a web page, your browser and the web server are speaking a protocol called HTTP. When you use a chat app that shows messages in real time, the app might be using WebSockets. When a temperature sensor in a factory sends readings to a monitoring system, it might be using MQTT.

Each protocol is designed for a specific kind of communication:

- **HTTP** is great for "ask a question, get an answer" conversations (like loading a web page or calling an API).
- **WebSocket** is great for ongoing two-way conversations (like a chat room where either side can send messages at any time).
- **SSE** is great for one-way broadcasts (like a news ticker that pushes updates to you).
- **MQTT** is great for lightweight messaging between devices (like sensors reporting data).
- **gRPC** is great for high-performance communication between backend services.

Volt supports all of these, so you can test any kind of API or service from a single tool. You do not need to install separate clients for each protocol.

---

## HTTP/HTTPS

### What Is HTTP?

HTTP (HyperText Transfer Protocol) is the foundation of the web. Every time you load a website, submit a form, or call a REST API, you are using HTTP. It follows a simple pattern: the client sends a **request** ("give me this resource"), and the server sends back a **response** ("here it is, along with a status code telling you how it went").

HTTPS is the secure version of HTTP. It encrypts the communication using TLS (Transport Layer Security), so nobody can eavesdrop on the data traveling between client and server. In practice, almost all modern APIs use HTTPS.

### HTTP in Volt

HTTP/HTTPS is the default protocol in Volt. When you run `volt run`, you are making an HTTP request. Every `.volt` file describes an HTTP request unless you explicitly use a different protocol command.

**Basic GET request:**

```yaml
# get-users.volt
name: Get Users
method: GET
url: https://jsonplaceholder.typicode.com/users
headers:
  - Accept: application/json
```

```bash
volt run get-users.volt
```

**POST request with a JSON body:**

```yaml
# create-user.volt
name: Create User
method: POST
url: https://jsonplaceholder.typicode.com/users
headers:
  - Content-Type: application/json
body: |
  {
    "name": "Jane Smith",
    "email": "jane@example.com"
  }
```

```bash
volt run create-user.volt
```

**Quick one-liner requests (HTTPie-style):**

```bash
volt quick GET https://httpbin.org/get                      # Simple GET
volt quick POST :3000/users name=John age:=30               # POST JSON to localhost
volt quick PUT :3000/users/1 name=Jane                      # PUT with JSON body
volt quick GET https://api.example.com/users q==search      # Query parameters
```

### HTTP Methods

Volt supports all standard HTTP methods:

| Method | Purpose | Example |
|--------|---------|---------|
| `GET` | Retrieve a resource | Fetch a list of users |
| `POST` | Create a new resource | Create a new user |
| `PUT` | Replace a resource entirely | Update all fields of a user |
| `PATCH` | Partially update a resource | Change just the user's email |
| `DELETE` | Remove a resource | Delete a user |
| `HEAD` | Get headers only (no body) | Check if a resource exists |
| `OPTIONS` | Ask what methods are allowed | CORS preflight checks |

### TLS and Security Options

Volt gives you fine-grained control over TLS when making HTTPS requests:

```bash
volt run api/login.volt --cert client.pem --cert-key client.key   # Client certificate (mTLS)
volt run api/login.volt --ca-bundle /path/to/ca.crt               # Custom CA bundle
volt run api/login.volt --verify=no                                # Skip TLS verification
volt run api/login.volt --ssl=tls1.2                               # Pin TLS version
volt run api/login.volt --ciphers="ECDHE-RSA-AES256-GCM-SHA384"   # Custom cipher suite
```

---

## HTTP/2

### What Is HTTP/2?

HTTP/2 is the second major version of the HTTP protocol, published in 2015. It was designed to make web communication faster without changing the meaning of HTTP requests and responses. The same methods (GET, POST, etc.), status codes (200, 404, etc.), and headers still work -- HTTP/2 changes *how* the data is transported, not *what* the data means.

The biggest improvement in HTTP/2 is **multiplexing**. In HTTP/1.1, if you need to make five requests, they typically happen one at a time over a single connection (or you open multiple connections). HTTP/2 allows all five requests to travel over a single connection simultaneously, interleaved as small chunks called **frames**. This eliminates the "head-of-line blocking" problem where a slow response blocks everything behind it.

Other HTTP/2 improvements include:

- **Header compression (HPACK)**: HTTP headers are compressed, which reduces overhead significantly when you are sending the same headers (like `Authorization` or `Content-Type`) repeatedly.
- **Binary framing**: Instead of plain text, HTTP/2 uses a compact binary format for framing, which is faster to parse.
- **Stream prioritization**: Clients can signal which requests are more important, so servers can prioritize responses.

### How Volt Implements HTTP/2

Volt includes a complete HTTP/2 implementation built from scratch in Zig with zero external dependencies. The implementation covers:

- **Frame building and parsing**: All HTTP/2 frame types are supported -- DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE, PING, GOAWAY, WINDOW_UPDATE, and CONTINUATION frames. Each frame follows the RFC 7540 layout: 3 bytes for payload length, 1 byte for type, 1 byte for flags, 4 bytes for stream ID, followed by the payload.

- **HPACK header compression**: Headers are compressed using the HPACK algorithm (RFC 7541), which uses Huffman coding and a dynamic table to dramatically reduce header sizes. This is especially effective for APIs where you send the same `Authorization` header on every request.

- **Stream management**: Each HTTP/2 request/response pair runs on its own numbered stream within a single TCP connection. Volt manages stream lifecycle, flow control windows, and concurrent stream limits.

- **TLS ALPN negotiation**: When connecting over TLS (HTTPS), Volt uses Application-Layer Protocol Negotiation (ALPN) to tell the server it supports HTTP/2. The server and client agree on the protocol during the TLS handshake.

- **h2c cleartext upgrade**: For unencrypted HTTP/2 (rare in production, but useful in development), Volt supports the HTTP Upgrade mechanism to switch from HTTP/1.1 to HTTP/2 over a plain TCP connection.

The module includes 26 unit tests covering frame construction, HPACK encoding/decoding, stream management, and protocol compliance.

### Using HTTP/2

To force HTTP/2 for a request, use the `--http2` flag:

```bash
volt run api/users.volt --http2
```

This works with the `volt quick` shorthand too:

```bash
volt quick GET https://api.example.com/users --http2
```

> **Beta note**: Volt's HTTP/2 framing and compression are fully tested in unit tests. When connecting to real-world endpoints, Volt will fall back to HTTP/1.1 if the server does not support HTTP/2 or if the connection upgrade fails. This fallback is automatic and transparent.

### When to Use HTTP/2

HTTP/2 is most beneficial when:

- You are making many requests to the same server (multiplexing reduces connection overhead).
- Your requests carry large or repetitive headers (HPACK compression helps).
- You are benchmarking or load testing and want to simulate modern browser behavior.

Most modern web servers and CDNs support HTTP/2, so using `--http2` is generally safe and often faster than HTTP/1.1 for repeated requests.

---

## HTTP/3 (QUIC)

### What Is HTTP/3?

HTTP/3 is the newest version of the HTTP protocol. The big change is the transport layer: HTTP/1.1 and HTTP/2 both run on top of TCP (Transmission Control Protocol), but HTTP/3 runs on top of **QUIC**, which uses **UDP** (User Datagram Protocol).

Why does this matter? TCP has a limitation: if a single packet is lost, *everything* stops until that packet is retransmitted, even data on different streams (this is called head-of-line blocking at the transport layer). HTTP/2 solved head-of-line blocking at the application layer with multiplexing, but the TCP layer underneath could still block everything when a packet went missing.

QUIC solves this by building reliability directly into the protocol on top of UDP. Each stream is independent at the transport level, so a lost packet on one stream does not block other streams. QUIC also integrates TLS 1.3 directly into the handshake, which means connections are established faster -- often in a single round trip instead of the two or three required by TCP + TLS.

In short, HTTP/3 gives you:

- **Faster connection setup**: QUIC combines the transport and TLS handshakes, reducing latency.
- **No head-of-line blocking**: Packet loss on one stream does not affect others.
- **Better performance on unreliable networks**: Mobile networks, Wi-Fi with interference, and high-latency connections all benefit.

### How Volt Implements HTTP/3

Volt includes a full HTTP/3 and QUIC implementation built from scratch in Zig. This is one of the most technically ambitious parts of Volt, comprising a dedicated `quic/` module directory with separate components for connections, packets, streams, TLS, and cryptography. The implementation covers:

- **Full H3 framing**: All HTTP/3 frame types are supported (DATA, HEADERS, CANCEL_PUSH, SETTINGS, PUSH_PROMISE, GOAWAY, MAX_PUSH_ID), following the RFC 9114 specification. Frames use QUIC variable-length integer encoding as defined in RFC 9000.

- **QPACK header compression**: HTTP/3 uses QPACK instead of HPACK for header compression. QPACK is designed to work with QUIC's out-of-order delivery, avoiding the head-of-line blocking that HPACK can cause.

- **Real QUIC transport over UDP**: This is not a simulation. Volt implements actual QUIC packet construction and parsing, including Initial, Handshake, and 1-RTT (short header) packets. The implementation handles:
  - QUIC variable-length integer encoding (1, 2, 4, or 8 bytes depending on value size)
  - Connection IDs and version negotiation
  - Per-stream offset tracking and FIN flag management
  - ACK frame generation
  - 64KB receive buffers
  - Socket timeouts
  - Coalesced packet handling (multiple QUIC packets in a single UDP datagram)

- **TLS 1.3 handshake**: The QUIC TLS provider implements a full TLS 1.3 handshake including:
  - X25519 key exchange for forward secrecy
  - AES-128-GCM authenticated encryption
  - AEAD packet protection for both header and payload
  - Header protection (for both short and long header packets)
  - Server Finished HMAC verification

- **Certificate verification**: Volt parses X.509 certificates in DER format and verifies ECDSA P-256 CertificateVerify signatures. This means Volt can validate the server's identity during the QUIC handshake without relying on external TLS libraries.

- **DNS resolution**: Hostnames are resolved before connecting, so you can use domain names (not just IP addresses) with HTTP/3.

- **Content-length body completion**: Volt tracks how much response data has been received and correctly signals completion based on the Content-Length header.

The HTTP/3 and QUIC modules include **65+ unit tests** covering frame construction, QPACK encoding, packet building, TLS handshake steps, AEAD encryption, stream management, and error handling.

### Using HTTP/3

To use HTTP/3 for a request, use the `--http3` flag:

```bash
volt run api/users.volt --http3
```

With quick mode:

```bash
volt quick GET https://api.example.com/data --http3
```

Volt will show HTTP/3-specific information in the response output, including the number of H3 frame bytes transferred:

```
HTTP/3 200 OK
Time: 45.2ms | Size: 1234 bytes | H3 frames: 892 bytes
```

> **Note**: HTTP/3 support requires the server to advertise HTTP/3 availability (typically via the `Alt-Svc` header). Not all servers support HTTP/3 yet. Major providers like Google, Cloudflare, and Facebook do support it.

### When to Use HTTP/3

HTTP/3 shines when:

- You are testing APIs hosted behind Cloudflare, Google Cloud, or other providers that support QUIC.
- You are working on mobile applications where network conditions are unreliable.
- You want to verify that your server's HTTP/3 implementation is working correctly.
- You are comparing performance between HTTP versions.

---

## GraphQL

### What Is GraphQL?

GraphQL is a query language for APIs, developed by Facebook (now Meta) and released as open source in 2015. Unlike REST, where the server decides what data each endpoint returns, GraphQL lets the **client** specify exactly what data it needs.

**The problem GraphQL solves**: Imagine you are building a mobile app that shows a user's profile. With a REST API, you might need to call `/users/123` to get the user's name and email, then `/users/123/posts` to get their posts, then `/users/123/followers` to get the follower count. That is three separate HTTP requests, and each one might return more data than you actually need (the user endpoint returns 30 fields, but you only need the name).

With GraphQL, you send a single request describing exactly what you want:

```graphql
{
  user(id: 123) {
    name
    email
    posts {
      title
    }
    followersCount
  }
}
```

The server returns exactly that data -- nothing more, nothing less -- in a single response.

**Key differences from REST:**

| | REST | GraphQL |
|---|---|---|
| **Endpoints** | Multiple (one per resource) | Single endpoint for everything |
| **Data fetching** | Server decides what to return | Client specifies what it needs |
| **Over-fetching** | Common (returns all fields) | Never (returns only requested fields) |
| **Under-fetching** | Common (requires multiple calls) | Never (get everything in one request) |
| **Protocol** | Uses HTTP methods (GET, POST, etc.) | Almost always uses HTTP POST |
| **Schema** | Implicit (documented separately) | Explicit (introspectable at runtime) |

### Executing GraphQL Queries

Volt has a dedicated `graphql` command for working with GraphQL APIs.

**Running a GraphQL query from a .volt file:**

```bash
volt graphql api/query.volt
```

This parses the `.volt` file, extracts the GraphQL query from the body, sends it as an HTTP POST to the endpoint, and displays the response with syntax highlighting.

### Writing GraphQL .volt Files

A GraphQL `.volt` file looks like a regular HTTP request, but with a GraphQL query in the body. GraphQL queries are always sent as HTTP POST requests with `Content-Type: application/json`.

**Simple query:**

```yaml
# get-user.volt
name: Get User by ID
method: POST
url: https://api.example.com/graphql
headers:
  - Content-Type: application/json
  - Authorization: Bearer {{token}}
body: |
  {
    "query": "{ user(id: 1) { name email posts { title } } }"
  }
```

```bash
volt graphql get-user.volt
```

**Multi-line query (more readable):**

```yaml
# list-repos.volt
name: List Repositories
method: POST
url: https://api.github.com/graphql
headers:
  - Content-Type: application/json
  - Authorization: Bearer {{github_token}}
body: |
  {
    "query": "query { viewer { repositories(first: 10) { nodes { name description stargazerCount } } } }"
  }
```

### Schema Introspection

One of GraphQL's most powerful features is **introspection** -- you can ask a GraphQL server to describe its own schema. This tells you every type, field, and operation the API supports, without reading any documentation.

```bash
volt graphql introspect https://api.example.com/graphql
```

This sends a standard introspection query and displays the schema in a readable format:

```
Schema for https://api.example.com/graphql

Root types:
  Query:        Query
  Mutation:     Mutation
  Subscription: Subscription

Types:
  User (OBJECT) - A registered user
    - id: ID!
    - name: String!
    - email: String
    - posts: [Post!]!
  Post (OBJECT) - A blog post
    - id: ID!
    - title: String!
    - body: String
    - author: User!
  Query (OBJECT) - Root query type
    - user(id: ID!): User
    - users: [User!]!
    - post(id: ID!): Post
```

Volt's introspection also detects query types, mutation types, and subscription types, giving you a complete picture of what the API can do.

### Schema Caching with TTL

Running an introspection query on every request would be slow. Volt caches introspection results locally in the `.volt-cache/` directory. Each cached schema includes a TTL (time-to-live) timestamp.

- **Default cache location**: `.volt-cache/` in your project directory
- **Default TTL**: 1 hour (3600 seconds)
- **Cache file naming**: A hash of the endpoint URL ensures different endpoints get separate cache files

When Volt needs the schema (for validation or autocomplete), it checks the cache first:

1. If the cache exists and is within TTL, use the cached schema (instant, no network request).
2. If the cache is expired or missing, run an introspection query, cache the result, and use it.

You do not need to manage the cache manually. To clear cached schemas, use `volt cache clear`.

### Mutations

Mutations are GraphQL's way of modifying data (creating, updating, deleting). They work exactly like queries syntactically, but use the `mutation` keyword.

```yaml
# create-post.volt
name: Create a Blog Post
method: POST
url: https://api.example.com/graphql
headers:
  - Content-Type: application/json
  - Authorization: Bearer {{token}}
body: |
  {
    "query": "mutation { createPost(input: { title: \"My New Post\", body: \"Hello from Volt!\" }) { id title createdAt } }"
  }
```

```bash
volt graphql create-post.volt
```

Response:

```json
{
  "data": {
    "createPost": {
      "id": "42",
      "title": "My New Post",
      "createdAt": "2026-02-22T10:30:00Z"
    }
  }
}
```

### Variables in GraphQL Queries

Hardcoding values into query strings is messy and error-prone. GraphQL variables let you parameterize your queries cleanly.

```yaml
# get-user-by-id.volt
name: Get User with Variables
method: POST
url: https://api.example.com/graphql
headers:
  - Content-Type: application/json
body: |
  {
    "query": "query GetUser($userId: ID!) { user(id: $userId) { name email } }",
    "variables": {
      "userId": "42"
    },
    "operationName": "GetUser"
  }
```

The `variables` field is a JSON object that maps variable names to values. The `operationName` field tells the server which operation to execute when your query document contains multiple operations.

Volt correctly handles all three parts of a GraphQL request body: `query`, `variables`, and `operationName`.

You can also combine this with Volt environment variables for maximum flexibility:

```yaml
body: |
  {
    "query": "query GetUser($userId: ID!) { user(id: $userId) { name email } }",
    "variables": {
      "userId": "{{user_id}}"
    }
  }
```

### Subscriptions (WebSocket-Based)

GraphQL subscriptions let you receive real-time updates from the server. Unlike queries and mutations (which are one-shot request/response pairs), subscriptions keep a connection open and push data to the client whenever something changes.

Under the hood, GraphQL subscriptions use the **graphql-ws** protocol over WebSocket. The flow works like this:

1. Client opens a WebSocket connection to the GraphQL endpoint.
2. Client sends a `connection_init` message.
3. Server responds with `connection_ack`.
4. Client sends a `subscribe` message with the subscription query.
5. Server sends `next` messages whenever new data is available.
6. Client (or server) can send `complete` to end the subscription.

Volt implements this entire protocol:

```yaml
# new-messages.volt
name: Subscribe to New Messages
method: POST
url: ws://localhost:4000/graphql
headers:
  - Content-Type: application/json
body: |
  {
    "query": "subscription { messageAdded { id text author { name } } }"
  }
```

**Subscriptions with variables:**

```yaml
# channel-messages.volt
name: Subscribe to Channel Messages
method: POST
url: ws://localhost:4000/graphql
headers:
  - Content-Type: application/json
body: |
  {
    "query": "subscription OnMsg($ch: String!) { messageAdded(channel: $ch) { id text } }",
    "variables": {
      "ch": "general"
    },
    "operationName": "OnMsg"
  }
```

Volt's GraphQL module includes 31 unit tests covering query building, introspection parsing, schema validation, autocomplete, caching, subscription message encoding/decoding, and error handling.

---

## WebSocket

### What Are WebSockets?

WebSocket is a protocol that provides a **persistent, two-way communication channel** between a client and a server. Unlike HTTP, where the client always initiates communication (request/response), WebSocket allows both the client and the server to send messages to each other at any time, independently.

Think of HTTP as sending letters: you write a letter (request), mail it, and wait for a reply (response). WebSocket is like a phone call: once the connection is established, either party can speak at any time without waiting for the other to finish.

**How it works:**

1. The client sends a regular HTTP request with an `Upgrade: websocket` header.
2. The server responds with `101 Switching Protocols`.
3. The connection is now "upgraded" -- both sides can send messages freely over the same TCP connection.
4. Messages are sent as **frames** (small packets of data with a header indicating the type and length).

**Common uses for WebSockets:**

- Chat applications (Slack, Discord)
- Live sports scores or stock tickers
- Collaborative editing (Google Docs)
- Online gaming
- IoT device communication
- Real-time dashboards and monitoring

### Using WebSocket in Volt

Connect to a WebSocket server:

```bash
volt ws wss://echo.websocket.org
```

Volt parses the WebSocket URL (which uses `ws://` for unencrypted or `wss://` for encrypted connections), builds the HTTP upgrade handshake, and displays the connection details:

```
WebSocket wss://echo.websocket.org:443/

Handshake request:
GET / HTTP/1.1
Host: echo.websocket.org
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==
Sec-WebSocket-Version: 13
```

**Send a message to a WebSocket server:**

```bash
volt ws wss://echo.websocket.org --send "Hello from Volt!"
```

**Connect with custom headers:**

WebSocket connections often require authentication or custom headers:

```bash
volt ws wss://api.example.com/stream --send '{"type": "subscribe", "channel": "updates"}'
```

### WebSocket Frame Building

Volt includes a complete WebSocket frame encoder/decoder. WebSocket frames consist of:

- **FIN bit**: Indicates whether this is the final fragment of a message.
- **Opcode** (4 bits): The type of frame -- text (0x1), binary (0x2), close (0x8), ping (0x9), or pong (0xA).
- **Mask bit**: Client-to-server frames must be masked (a security requirement).
- **Payload length**: Can be 7 bits (for payloads up to 125 bytes), 16 bits (up to 65535 bytes), or 64 bits (for larger payloads).
- **Masking key**: 4 bytes used to XOR the payload (only for client frames).
- **Payload data**: The actual message content.

Volt handles all of this automatically. You send text, and Volt builds the correct frames with proper masking, opcodes, and length encoding.

### WebSocket Configuration

Volt's WebSocket client supports several configuration options:

| Option | Default | Description |
|--------|---------|-------------|
| Ping interval | 30 seconds | How often to send keepalive pings |
| Max message size | 16 MB | Maximum size of a single WebSocket message |
| Auto-reconnect | Off | Automatically reconnect if the connection drops |
| Subprotocol | None | Request a specific WebSocket subprotocol |

---

## Server-Sent Events (SSE)

### What Is SSE?

Server-Sent Events (SSE) is a protocol for **one-way, server-to-client streaming** over HTTP. The server keeps the HTTP connection open and sends events to the client as they happen. Unlike WebSocket, SSE is one-directional: the server pushes data, but the client cannot send messages back over the same connection.

Think of SSE as a radio broadcast: the station (server) transmits, and you (the client) listen. If you want to send something back, you need to make a separate HTTP request.

**SSE vs. WebSocket:**

| | SSE | WebSocket |
|---|---|---|
| **Direction** | Server to client only | Both directions |
| **Protocol** | Regular HTTP | Upgraded HTTP connection |
| **Reconnection** | Built-in auto-reconnect | Must implement yourself |
| **Data format** | Text only | Text or binary |
| **Simplicity** | Very simple | More complex |
| **Browser support** | `EventSource` API | `WebSocket` API |

SSE is ideal when you only need the server to push updates: live dashboards, notification feeds, log tailing, AI chat streaming (like ChatGPT's streaming responses), and event-driven architectures.

### SSE Protocol Format

SSE uses a simple text-based format. Each event is a block of lines separated by a blank line:

```
event: message
data: {"user": "Alice", "text": "Hello!"}
id: 1

event: message
data: {"user": "Bob", "text": "Hi Alice!"}
id: 2

event: heartbeat
data:

```

Each line in an event has a field name and a value:

| Field | Purpose |
|-------|---------|
| `event:` | The event type (defaults to "message" if omitted) |
| `data:` | The event payload (can span multiple lines) |
| `id:` | An ID for the event (used for reconnection) |
| `retry:` | Tells the client how long to wait before reconnecting (in milliseconds) |

### Using SSE in Volt

Connect to an SSE endpoint:

```bash
volt sse https://api.example.com/events
```

Volt connects to the URL, sends the required headers (`Accept: text/event-stream`), and parses incoming events in real time.

**SSE with the run command:**

You can also use `volt run` with the `--stream` flag. Volt auto-detects SSE when the server responds with `Content-Type: text/event-stream`:

```bash
volt run api/events.volt --stream
```

Or with quick mode:

```bash
volt quick GET https://api.example.com/events --stream
```

**SSE .volt file example:**

```yaml
# listen-events.volt
name: Listen for Events
method: GET
url: https://api.example.com/events
headers:
  - Accept: text/event-stream
  - Authorization: Bearer {{token}}
```

```bash
volt run listen-events.volt --stream
```

### Event Parsing

Volt's SSE parser correctly handles:

- **Named events** (`event: update`, `event: delete`, etc.)
- **Multi-line data** (multiple `data:` lines are concatenated with newlines)
- **Event IDs** (tracked for reconnection via the `Last-Event-ID` header)
- **Retry intervals** (the server can tell the client how long to wait before reconnecting)
- **Auto-reconnection** (enabled by default, with configurable retry interval starting at 3000ms)

### SSE Configuration

| Option | Default | Description |
|--------|---------|-------------|
| Last Event ID | None | Resume from a specific event ID after reconnection |
| Retry interval | 3000 ms | How long to wait before reconnecting |
| Max events | 0 (unlimited) | Stop after receiving N events |
| Auto-reconnect | On | Automatically reconnect on disconnection |

---

## MQTT

### What Is MQTT?

MQTT (Message Queuing Telemetry Transport) is a **lightweight messaging protocol** designed for constrained devices and unreliable networks. It was created in 1999 for monitoring oil pipelines via satellite, and today it is the de facto standard for IoT (Internet of Things) communication.

MQTT uses a **publish/subscribe** model, which is fundamentally different from HTTP's request/response model:

- **HTTP**: Client asks a specific server for something. Direct, point-to-point.
- **MQTT**: Client publishes a message to a **topic**, and any number of other clients subscribed to that topic receive it. Communication goes through a central **broker** (the MQTT server).

Think of MQTT topics like radio channels. A temperature sensor publishes to the `sensors/kitchen/temperature` topic. A dashboard app subscribes to `sensors/#` (the `#` wildcard means "everything under sensors"). The broker makes sure the dashboard receives the temperature readings, without the sensor and dashboard ever needing to know about each other.

**Why MQTT is popular for IoT:**

- **Tiny overhead**: A minimal MQTT packet is just 2 bytes. HTTP headers alone are typically 200-800 bytes.
- **Low bandwidth**: Perfect for devices on cellular or satellite connections.
- **Reliable delivery**: QoS (Quality of Service) levels guarantee message delivery even on unreliable networks.
- **Last Will and Testament**: A device can register a "last will" message that the broker sends if the device disconnects unexpectedly (useful for detecting device failures).

### MQTT in Volt

Volt implements the MQTT v3.1.1 protocol, including CONNECT, PUBLISH, SUBSCRIBE, PINGREQ, and DISCONNECT packet building and parsing.

**Publish a message:**

```bash
volt mqtt localhost:1883 pub "sensors/temperature" '{"value": 23.5, "unit": "celsius"}'
```

This builds an MQTT PUBLISH packet with the specified topic and payload, and sends it to the broker.

**Subscribe to a topic:**

```bash
volt mqtt localhost:1883 sub "sensors/#"
```

This subscribes to all topics under `sensors/` using the MQTT wildcard `#`, and displays messages as they arrive.

**Connect to a specific broker with a custom port:**

```bash
volt mqtt mybroker.example.com:8883 sub "events/+/alerts"
```

The `+` wildcard matches exactly one topic level, so this subscribes to topics like `events/server1/alerts` and `events/server2/alerts`, but not `events/server1/cpu/alerts`.

### QoS Levels Explained

MQTT has three Quality of Service levels that control delivery guarantees. This is one of MQTT's most important features:

**QoS 0 -- At most once ("fire and forget")**

The message is delivered at most once. The sender sends it and does not check if it arrived. Like sending a postcard -- it probably arrives, but you have no confirmation.

- **Use when**: The occasional lost message is acceptable (e.g., a temperature reading sent every second; missing one is fine).
- **Overhead**: Minimal. One packet, no acknowledgment.

**QoS 1 -- At least once**

The message is guaranteed to arrive at least once. The sender keeps resending until it gets an acknowledgment (PUBACK). This means the message might be delivered more than once if the acknowledgment is lost.

- **Use when**: Every message must arrive, and duplicates are acceptable or your application handles deduplication (e.g., a "door opened" alert -- getting it twice is better than missing it).
- **Overhead**: Two packets (PUBLISH + PUBACK).

**QoS 2 -- Exactly once**

The message is guaranteed to arrive exactly once. This uses a four-step handshake (PUBLISH, PUBREC, PUBREL, PUBCOMP) to ensure no duplicates.

- **Use when**: Duplicates are unacceptable (e.g., financial transactions, billing events).
- **Overhead**: Four packets. The most expensive QoS level.

| QoS Level | Guarantee | Packets | Best For |
|-----------|-----------|---------|----------|
| 0 | At most once | 1 | Frequent sensor readings, metrics |
| 1 | At least once | 2 | Alerts, notifications, commands |
| 2 | Exactly once | 4 | Payments, critical state changes |

### MQTT Configuration

Volt's MQTT client supports these configuration options:

| Option | Default | Description |
|--------|---------|-------------|
| Host | `localhost` | Broker hostname or IP |
| Port | `1883` | Broker port (8883 for TLS) |
| Client ID | `volt-client` | Identifies this client to the broker |
| Username | None | Authentication username |
| Password | None | Authentication password |
| Keep Alive | 60 seconds | Interval for keepalive pings |
| Clean Session | Yes | Start fresh (no stored state from previous connections) |

### MQTT Packet Structure

MQTT packets use a compact binary format designed for efficiency:

- **Fixed header**: 1 byte for packet type (4 bits) and flags (4 bits), followed by a variable-length encoding of the remaining packet length. The variable-length encoding uses 1-4 bytes and can represent lengths from 0 to 268,435,455 bytes.
- **Variable header**: Protocol-specific fields (e.g., topic name for PUBLISH, packet ID for QoS 1/2).
- **Payload**: The message data.

Volt's implementation includes 9 unit tests covering packet encoding, decoding, variable-length integers, and all packet types.

---

## Socket.IO

### What Is Socket.IO?

Socket.IO is a library and protocol for **real-time, bidirectional communication** between clients and servers. It was originally built for Node.js and has become one of the most popular choices for building real-time web applications like chat apps, multiplayer games, collaborative tools, and live dashboards.

Socket.IO is built on top of two layers:

1. **Engine.IO**: The transport layer. It handles the actual connection, starting with HTTP long-polling and upgrading to WebSocket when possible. This fallback mechanism is what makes Socket.IO more reliable than raw WebSockets in restrictive network environments (corporate firewalls, proxies, etc.).

2. **Socket.IO**: The application layer. It adds features on top of Engine.IO: namespaces (multiplexing multiple channels on one connection), rooms (grouping connections), acknowledgments (confirming message receipt), and automatic reconnection.

**Socket.IO vs. raw WebSocket:**

| | Socket.IO | WebSocket |
|---|---|---|
| **Fallback** | Auto-falls back to long-polling if WebSocket fails | No fallback |
| **Reconnection** | Built-in, automatic | Must implement yourself |
| **Rooms/namespaces** | Built-in | Must implement yourself |
| **Acknowledgments** | Built-in | Must implement yourself |
| **Binary support** | Yes, with automatic encoding | Yes |
| **Overhead** | Slightly more (Engine.IO framing) | Minimal |
| **Ecosystem** | Huge (Node.js, Python, Java, etc.) | Universal browser support |

### Socket.IO in Volt

Volt supports Socket.IO protocol v4 and v5, implementing both the Engine.IO transport layer and the Socket.IO packet encoding/decoding.

**Connect to a Socket.IO server:**

```bash
volt sio http://localhost:3000
```

This performs the Engine.IO handshake (HTTP polling to get a session ID, ping interval, and supported transports), then displays the connection details.

**Emit an event:**

```bash
volt sio http://localhost:3000 emit "chat" '{"message": "Hello from Volt!", "user": "tester"}'
```

This encodes the event name and data into the Socket.IO packet format and sends it to the server.

**Full alias:**

`volt sio` is the short alias. `volt socketio` also works:

```bash
volt socketio http://localhost:3000 emit "join-room" '{"room": "general"}'
```

### Engine.IO + Socket.IO Encoding

Volt correctly handles the two-layer encoding:

**Engine.IO packet types:**

| Type | Code | Description |
|------|------|-------------|
| open | 0 | Server sends connection parameters (SID, ping interval) |
| close | 1 | Request connection close |
| ping | 2 | Heartbeat ping |
| pong | 3 | Heartbeat pong |
| message | 4 | Application data (Socket.IO packets travel inside these) |
| upgrade | 5 | Transport upgrade (long-polling to WebSocket) |
| noop | 6 | No operation (used during upgrades) |

**Socket.IO packet types:**

| Type | Code | Description |
|------|------|-------------|
| connect | 0 | Connect to a namespace |
| disconnect | 1 | Disconnect from a namespace |
| event | 2 | Send an event (the most common type) |
| ack | 3 | Acknowledge receipt of an event |
| error | 4 | Error notification |
| binary_event | 5 | Event with binary data attachments |
| binary_ack | 6 | Acknowledge receipt of a binary event |

When you run `volt sio http://localhost:3000 emit "chat" "hello"`, Volt:

1. Builds the Engine.IO handshake URL: `http://localhost:3000/socket.io/?EIO=4&transport=polling`
2. Encodes the Socket.IO event: `42["chat","hello"]` (type 4 = Engine.IO message, type 2 = Socket.IO event)
3. Displays the encoded packet for debugging

### Socket.IO Configuration

| Option | Default | Description |
|--------|---------|-------------|
| URL | `http://localhost:3000` | Server URL |
| Path | `/socket.io/` | Engine.IO handshake path |
| Namespace | `/` | Socket.IO namespace to connect to |
| Auth | None | Authentication payload sent with connect |
| Reconnect | Yes | Auto-reconnect on disconnection |

The Socket.IO module includes 9 unit tests covering Engine.IO handshake URL building, packet encoding/decoding, event serialization, and namespace handling.

---

## gRPC

### What Is gRPC?

gRPC (gRPC Remote Procedure Calls) is a high-performance RPC framework developed by Google. Instead of calling URLs with JSON payloads (like REST), gRPC lets you call functions on a remote server as if they were local functions in your code.

**How gRPC is different from REST:**

| | REST | gRPC |
|---|---|---|
| **Data format** | JSON (text) | Protocol Buffers (binary) |
| **Transport** | HTTP/1.1 or HTTP/2 | Always HTTP/2 |
| **Schema** | Optional (OpenAPI, etc.) | Required (.proto files) |
| **Code generation** | Optional | Central workflow |
| **Streaming** | Limited | Full support (client, server, bidirectional) |
| **Performance** | Good | Excellent (smaller payloads, less parsing overhead) |

**Protocol Buffers (protobuf):** gRPC uses Protocol Buffers as its serialization format. You define your data structures and service interfaces in `.proto` files, and tools generate code for your programming language. Protobuf is binary, compact, and fast to serialize/deserialize -- typically 3-10x smaller and faster than JSON.

**The `.proto` file** is the contract between client and server. It defines:
- **Messages**: The data structures (like JSON objects, but strongly typed)
- **Services**: The available RPC methods (like REST endpoints)

Here is an example `.proto` file:

```protobuf
syntax = "proto3";
package bookstore;

service BookService {
  rpc GetBook(GetBookRequest) returns (Book);
  rpc ListBooks(ListBooksRequest) returns (stream Book);
  rpc CreateBook(Book) returns (Book);
}

message Book {
  string id = 1;
  string title = 2;
  string author = 3;
  int32 year = 4;
}

message GetBookRequest {
  string id = 1;
}

message ListBooksRequest {
  int32 page_size = 1;
  string page_token = 2;
}
```

### gRPC in Volt

Volt's gRPC support focuses on proto file parsing and `.volt` file generation, making it easy to explore and test gRPC services.

**List services and methods from a proto file:**

```bash
volt grpc list bookstore.proto
```

Output:

```
Package: bookstore

Service: BookService
  rpc GetBook(GetBookRequest) returns (Book)
  rpc ListBooks(ListBooksRequest) returns (Book) (server stream)
  rpc CreateBook(Book) returns (Book)

Messages:
  Book (4 fields)
  GetBookRequest (1 fields)
  ListBooksRequest (2 fields)
```

This gives you a quick overview of every service, RPC method, message type, and streaming direction defined in the proto file.

**Generate .volt files from a proto file:**

```bash
volt grpc bookstore.proto --output grpc-requests/
```

This creates a `.volt` file for each RPC method, pre-configured with the correct URL pattern, HTTP/2 headers, and Content-Type (`application/grpc`). You can then fill in the request body and run the files with `volt run`.

**Streaming types:**

gRPC supports four kinds of RPC:

| Type | Description | Example |
|------|-------------|---------|
| **Unary** | One request, one response | GetBook -- send an ID, get a book back |
| **Server streaming** | One request, stream of responses | ListBooks -- send a query, get books one at a time |
| **Client streaming** | Stream of requests, one response | UploadChunks -- send file chunks, get a confirmation |
| **Bidirectional streaming** | Stream both ways simultaneously | Chat -- both sides send messages freely |

Volt detects the streaming type from the proto file and labels it in the `volt grpc list` output.

**Proto file parsing:**

Volt's proto parser extracts:
- Package name
- Service definitions (name and methods)
- Method definitions (name, input type, output type, streaming flags)
- Message definitions (name and fields with types and field numbers)

> **Beta note**: Proto file parsing and `.volt` file generation are tested and working. Actual gRPC calls over HTTP/2 are possible but depend on the HTTP/2 transport layer, which is still maturing for real-world endpoints. gRPC services that require TLS and real HTTP/2 framing should be tested carefully.

The gRPC module includes 4 unit tests covering proto parsing, service discovery, and `.volt` generation.

---

## Protocol Comparison Table

Here is a quick reference for choosing the right protocol for your use case.

| Protocol | Direction | Transport | Data Format | Best For |
|----------|-----------|-----------|-------------|----------|
| **HTTP/HTTPS** | Request/response | TCP | Text (JSON, XML, etc.) | REST APIs, web services, general-purpose |
| **HTTP/2** | Request/response (multiplexed) | TCP | Binary frames | High-throughput APIs, many concurrent requests |
| **HTTP/3 (QUIC)** | Request/response (multiplexed) | UDP | Binary frames | Unreliable networks, mobile, low latency |
| **GraphQL** | Request/response | HTTP POST | JSON | Flexible data fetching, single-endpoint APIs |
| **WebSocket** | Bidirectional, persistent | TCP (upgraded HTTP) | Text or binary frames | Chat, gaming, live collaboration |
| **SSE** | Server-to-client, persistent | HTTP | Text (event stream) | Notifications, live feeds, AI streaming |
| **MQTT** | Pub/sub via broker | TCP | Binary (compact) | IoT, sensors, device-to-device messaging |
| **Socket.IO** | Bidirectional, persistent | HTTP/WebSocket | Text/binary with framing | Real-time web apps (with fallback transport) |
| **gRPC** | RPC (all streaming modes) | HTTP/2 | Protocol Buffers (binary) | Microservices, high-performance backends |

### Decision Flowchart

Use this to quickly decide which protocol fits your situation:

**"I need to call a REST API."** -- Use HTTP/HTTPS (`volt run` or `volt quick`).

**"I need faster HTTP with multiplexing."** -- Use HTTP/2 (`--http2` flag).

**"I need the fastest possible HTTP on unreliable networks."** -- Use HTTP/3 (`--http3` flag).

**"I need to query an API where I want to pick exactly which fields I get back."** -- Use GraphQL (`volt graphql`).

**"I need a persistent connection where both sides can send messages."** -- Use WebSocket (`volt ws`).

**"I need the server to push updates to me (one-way streaming)."** -- Use SSE (`volt sse` or `--stream` flag).

**"I need lightweight messaging between IoT devices."** -- Use MQTT (`volt mqtt`).

**"I need real-time communication with automatic reconnection and fallback transports."** -- Use Socket.IO (`volt sio`).

**"I need high-performance RPC between backend services."** -- Use gRPC (`volt grpc`).

### Volt CLI Quick Reference

| Protocol | Command | Example |
|----------|---------|---------|
| HTTP/HTTPS | `volt run` | `volt run api/users.volt` |
| HTTP (quick) | `volt quick` | `volt quick GET :3000/users` |
| HTTP/2 | `volt run --http2` | `volt run api/users.volt --http2` |
| HTTP/3 | `volt run --http3` | `volt run api/users.volt --http3` |
| GraphQL | `volt graphql` | `volt graphql api/query.volt` |
| GraphQL introspect | `volt graphql introspect` | `volt graphql introspect https://api.example.com/graphql` |
| WebSocket | `volt ws` | `volt ws wss://echo.websocket.org` |
| SSE | `volt sse` | `volt sse https://api.example.com/events` |
| MQTT publish | `volt mqtt ... pub` | `volt mqtt localhost:1883 pub topic "message"` |
| MQTT subscribe | `volt mqtt ... sub` | `volt mqtt localhost:1883 sub "sensors/#"` |
| Socket.IO | `volt sio` | `volt sio http://localhost:3000` |
| Socket.IO emit | `volt sio ... emit` | `volt sio http://localhost:3000 emit "chat" "hello"` |
| gRPC list | `volt grpc list` | `volt grpc list service.proto` |
| gRPC generate | `volt grpc` | `volt grpc service.proto --output grpc/` |

---

## Further Reading

- [Command Reference](commands.md) -- Complete CLI documentation for all commands and flags
- [.volt File Format](volt-file-format.md) -- How to write `.volt` request files
- [Getting Started](getting-started.md) -- Install Volt and send your first request
- [Feature Status](FEATURE_STATUS.md) -- Honest assessment of what is stable, tested, and beta
