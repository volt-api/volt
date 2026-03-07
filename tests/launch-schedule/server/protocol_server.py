#!/usr/bin/env python3
"""Protocol test server for Volt integration tests.

Provides endpoints for GraphQL, SSE, OAuth token exchange, and proxy capture.
Run with: python protocol_server.py [--port 9090]
"""

import json
import time
import argparse
from http.server import HTTPServer, BaseHTTPRequestHandler


class ProtocolHandler(BaseHTTPRequestHandler):
    """Handles requests for multiple protocol test endpoints."""

    def do_GET(self):
        if self.path == "/sse/events":
            self._handle_sse()
        elif self.path == "/proxy-target":
            self._handle_proxy_target()
        elif self.path.startswith("/socket.io/"):
            self._handle_socketio_poll()
        elif self.path == "/health":
            self._send_json(200, {"status": "ok"})
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path == "/graphql":
            self._handle_graphql()
        elif self.path == "/oauth/token":
            self._handle_oauth_token()
        else:
            self._send_json(404, {"error": "not found"})

    def _handle_graphql(self):
        """Handle GraphQL POST requests with realistic response data."""
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length else "{}"
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._send_json(400, {"errors": [{"message": "Invalid JSON"}]})
            return

        query = payload.get("query", "")
        variables = payload.get("variables", {})

        if "users" in query:
            data = {
                "data": {
                    "users": [
                        {"id": "1", "name": "Alice", "email": "alice@example.com"},
                        {"id": "2", "name": "Bob", "email": "bob@example.com"},
                        {"id": "3", "name": "Charlie", "email": "charlie@example.com"},
                    ]
                }
            }
        elif "user" in query and "id" in variables:
            user_id = variables["id"]
            data = {
                "data": {
                    "user": {
                        "id": user_id,
                        "name": f"User {user_id}",
                        "email": f"user{user_id}@example.com",
                    }
                }
            }
        else:
            data = {"data": None, "errors": [{"message": "Unknown query"}]}

        self._send_json(200, data)

    def _handle_sse(self):
        """Send a short burst of Server-Sent Events then close."""
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        events = [
            {"event": "launch", "data": {"mission": "Starship IFT-5", "status": "go"}},
            {"event": "countdown", "data": {"t_minus": 10, "hold": False}},
            {"event": "telemetry", "data": {"altitude_km": 0, "velocity_ms": 0}},
        ]
        for i, evt in enumerate(events):
            line = f"id: {i}\nevent: {evt['event']}\ndata: {json.dumps(evt['data'])}\n\n"
            self.wfile.write(line.encode("utf-8"))
            self.wfile.flush()
            time.sleep(0.05)

    def _handle_oauth_token(self):
        """Return a mock OAuth2 access token response."""
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode("utf-8") if content_length else ""

        # Validate grant_type is present
        if "grant_type=client_credentials" not in body:
            self._send_json(400, {"error": "unsupported_grant_type"})
            return

        token_response = {
            "access_token": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test-token",
            "token_type": "Bearer",
            "expires_in": 3600,
            "scope": "read write",
        }
        self._send_json(200, token_response)

    def _handle_proxy_target(self):
        """Return request metadata for proxy capture testing."""
        data = {
            "received_headers": dict(self.headers),
            "path": self.path,
            "method": "GET",
            "proxy_detected": self.headers.get("X-Proxy-Capture") == "true",
            "forwarded_for": self.headers.get("X-Forwarded-For", ""),
        }
        self._send_json(200, data)

    def _handle_socketio_poll(self):
        """Return a Socket.IO handshake response (Engine.IO v4)."""
        handshake = {
            "sid": "abc123def456",
            "upgrades": ["websocket"],
            "pingInterval": 25000,
            "pingTimeout": 20000,
            "maxPayload": 1000000,
        }
        # Socket.IO wraps the JSON in a length prefix for polling
        payload = json.dumps(handshake)
        encoded = f"0{payload}"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=UTF-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded.encode("utf-8"))

    def _send_json(self, status, data):
        """Helper to send a JSON response."""
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        """Suppress default request logging for cleaner test output."""
        pass


def main():
    parser = argparse.ArgumentParser(description="Volt protocol test server")
    parser.add_argument("--port", type=int, default=9090, help="Port to listen on")
    parser.add_argument("--host", default="127.0.0.1", help="Host to bind to")
    args = parser.parse_args()

    server = HTTPServer((args.host, args.port), ProtocolHandler)
    print(f"Protocol test server listening on {args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
