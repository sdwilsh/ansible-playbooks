#!/usr/bin/env python3
"""Answer `/v1/audio/transcriptions` with one chosen body.

The server reads the whole request first, because `curl` sends the probe clip
as a multipart body.  `HTTP/1.1` answers the `Expect: 100-continue` header
that `curl` sends for a body of this size.

Usage: stub-flm-server.py <mode> [port]
"""

import http.server
import json
import sys
import time
from typing import Any

# A real server answers 200 with a body of `null` when it loads no ASR model.
BODIES: dict[str, Any] = {
    "empty-text": {"text": ""},
    "null": None,
    "null-text": {"text": None},
    "text": {"text": "hello"},
}
# The probe gives the server 20 seconds.  This stall is longer than that.
STALL_SECONDS = 25


class Handler(http.server.BaseHTTPRequestHandler):
    mode: str = "text"
    protocol_version: str = "HTTP/1.1"

    def do_POST(self) -> None:
        remaining = int(self.headers.get("Content-Length") or 0)
        while remaining > 0:
            remaining -= len(self.rfile.read(min(remaining, 65536)))
        if self.mode == "stall":
            time.sleep(STALL_SECONDS)
            return
        if self.mode == "error":
            self.send_error(500, "no model")
            return
        body = json.dumps(BODIES[self.mode]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *arguments: Any) -> None:
        """Keep the output of the suite readable."""


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("Usage: stub-flm-server.py <mode> [port]", file=sys.stderr)
        return 2
    mode = sys.argv[1]
    if mode not in set(BODIES) | {"error", "stall"}:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    Handler.mode = mode
    port = int(sys.argv[2]) if len(sys.argv) == 3 else 8080
    http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
