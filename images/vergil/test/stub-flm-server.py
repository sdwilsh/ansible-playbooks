#!/usr/bin/env python3
"""Answer the transcription path and the chat path with one chosen body.

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
CHAT_PATH = "/v1/chat/completions"


def choice(content: Any) -> dict[str, Any]:
    return {"choices": [{"message": {"content": content}}]}


CHAT_BODIES: dict[str, Any] = {
    "empty-text": choice(""),
    "no-choices": {"choices": []},
    "null": None,
    "null-text": choice(None),
    "text": choice("PROBE"),
}
# The probe gives the server 20 seconds.  This stall is longer than that.
STALL_SECONDS = 25
DATA_URL = "data:image/png;base64,"


def chat_request_fault(request: bytes) -> str:
    """Name the fault of a chat request.  An empty answer means no fault."""
    try:
        content = json.loads(request)["messages"][0]["content"]
    except (LookupError, TypeError, ValueError) as fault:
        return f"the request holds no message content: {fault}"
    parts = {part.get("type"): part for part in content}
    if "image_url" not in parts or "text" not in parts:
        return f"the message holds these parts only: {sorted(parts)}"
    url = parts["image_url"].get("image_url", {}).get("url", "")
    if not url.startswith(DATA_URL):
        return f"the image url starts with {url[:32]!r}"
    return ""


class Handler(http.server.BaseHTTPRequestHandler):
    mode: str = "text"
    protocol_version: str = "HTTP/1.1"

    def do_POST(self) -> None:
        remaining = int(self.headers.get("Content-Length") or 0)
        request = b""
        while remaining > 0:
            part = self.rfile.read(min(remaining, 65536))
            remaining -= len(part)
            request += part
        if self.path == CHAT_PATH and (fault := chat_request_fault(request)):
            self.send_error(400, fault)
            return
        if self.mode == "stall":
            time.sleep(STALL_SECONDS)
            return
        if self.mode == "error":
            self.send_error(500, "no model")
            return
        bodies = CHAT_BODIES if self.path == CHAT_PATH else BODIES
        if self.mode not in bodies:
            self.send_error(500, f"{self.mode} is no mode of {self.path}")
            return
        body = json.dumps(bodies[self.mode]).encode()
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
    if mode not in set(BODIES) | set(CHAT_BODIES) | {"error", "stall"}:
        print(f"unknown mode: {mode}", file=sys.stderr)
        return 2
    Handler.mode = mode
    port = int(sys.argv[2]) if len(sys.argv) == 3 else 8080
    http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
