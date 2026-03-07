#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    counter_lock = threading.Lock()
    counter = 0

    def log_message(self, fmt: str, *args):
        # Keep smoke test output clean.
        return

    def _send(self, status: int, content_type: str, body: bytes):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]

        if path == "/login":
            body = json.dumps({"token": "abc123", "user": {"id": 1}}).encode("utf-8")
            return self._send(200, "application/json", body)

        if path == "/me":
            auth = self.headers.get("Authorization", "")
            body = json.dumps({"received_auth": auth}).encode("utf-8")
            return self._send(200, "application/json", body)

        if path == "/counter":
            with Handler.counter_lock:
                Handler.counter += 1
                n = Handler.counter
            body = json.dumps({"counter": n}).encode("utf-8")
            return self._send(200, "application/json", body)

        if path == "/html":
            body = (
                "<html><body>"
                "<h1>Volt HTML</h1>"
                "<p>Hello <b>world</b>.</p>"
                "<ul><li>One</li><li>Two</li></ul>"
                "</body></html>"
            ).encode("utf-8")
            return self._send(200, "text/html; charset=utf-8", body)

        if path == "/xml":
            body = b"<?xml version='1.0'?><root><msg>Hello</msg></root>"
            return self._send(200, "application/xml", body)

        if path == "/large":
            # ~6MB JSON response to exercise large-response paths.
            payload = "a" * (6 * 1024 * 1024)
            body = json.dumps({"data": payload}).encode("utf-8")
            return self._send(200, "application/json", body)

        if path == "/binary":
            body = b"\x00\x01\x02\x00\xffbinary\x00data\x00"
            return self._send(200, "application/octet-stream", body)

        return self._send(404, "text/plain", b"not found")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())

