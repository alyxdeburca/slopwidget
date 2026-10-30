#!/usr/bin/env python3
"""Claude usage relay for slopWidget.

Reads the local Claude Code login (~/.claude/.credentials.json), asks
Anthropic's /api/oauth/usage endpoint for your subscription usage, and serves
ONLY the usage numbers over HTTP on your Tailscale address. The OAuth token
never leaves this machine and is never written to logs or responses.

    GET /usage   Authorization: Bearer <shared secret>

Security properties:
  * binds only to the Tailscale IPv4 address (never a wildcard address)
  * requires a shared secret (constant-time compare), stored in
    ~/.config/slopwidget/relay-secret (mode 0600, generated on first run)
  * never calls the OAuth refresh endpoint: refresh tokens rotate, so a second
    client refreshing would log Claude Code out. When the access token has
    expired the relay answers status "token_expired" until Claude Code itself
    refreshes it (it does so whenever it runs).

Python 3 standard library only.
"""

import argparse
import fcntl
import hmac
import ipaddress
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CACHE_TTL = 60  # seconds a successful upstream answer is reused
ERROR_TTL = 30  # seconds a failed upstream answer is reused
EXPIRY_SKEW_MS = 30_000
DEFAULT_PORT = 8787
SECRET_PATH = Path.home() / ".config" / "slopwidget" / "relay-secret"
# Only these upstream keys are ever relayed.
RELAYED_KEYS = ("five_hour", "seven_day", "limits")


def log(message):
    print(f"[relay] {message}", file=sys.stderr, flush=True)


def credentials_path():
    base = os.environ.get("CLAUDE_CONFIG_DIR")
    root = Path(base) if base else Path.home() / ".claude"
    return root / ".credentials.json"


def load_secret():
    """Return the shared secret, creating the file (0600) on first run."""
    SECRET_PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        fd = os.open(SECRET_PATH, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        secret = SECRET_PATH.read_text().strip()
        if not secret:
            raise SystemExit(f"{SECRET_PATH} is empty; delete it to regenerate.")
        return secret
    secret = secrets.token_urlsafe(32)
    with os.fdopen(fd, "w") as handle:
        handle.write(secret + "\n")
    log(f"generated a new shared secret at {SECRET_PATH} (mode 0600)")
    return secret


def tailscale_ip():
    """Tailscale IPv4: from the CLI, else from the tailscale0 interface."""
    try:
        out = subprocess.run(
            ["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=5, check=True
        ).stdout.split()
        if out:
            return out[0]
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            packed = fcntl.ioctl(
                sock.fileno(), 0x8915, struct.pack("256s", b"tailscale0")  # SIOCGIFADDR
            )
        return socket.inet_ntoa(packed[20:24])
    except OSError:
        return None


def read_access_token():
    """Return (token, expires_at_ms) from the Claude Code login, or raise."""
    try:
        data = json.loads(credentials_path().read_text())
        oauth = data["claudeAiOauth"]
        return oauth["accessToken"], int(oauth.get("expiresAt") or 0)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        raise RelayError("error", f"cannot read Claude Code login ({type(exc).__name__})")


class RelayError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def fetch_upstream():
    token, expires_at = read_access_token()
    if expires_at and expires_at <= time.time() * 1000 + EXPIRY_SKEW_MS:
        raise RelayError(
            "token_expired",
            "Claude Code's access token has expired; run `claude` on the desktop to refresh it.",
        )
    request = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "Accept": "application/json",
            "User-Agent": "slopWidget-relay/1.0",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            upstream = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise RelayError("token_expired", f"Anthropic rejected the token (HTTP {exc.code}).")
        raise RelayError("error", f"Anthropic usage request failed (HTTP {exc.code}).")
    except (OSError, ValueError) as exc:
        raise RelayError("error", f"Anthropic usage request failed ({type(exc).__name__}).")
    if not isinstance(upstream, dict):
        raise RelayError("error", "Unexpected upstream response.")
    return {key: upstream[key] for key in RELAYED_KEYS if key in upstream}


class UsageCache:
    def __init__(self, fetch=fetch_upstream, clock=time.monotonic):
        self._fetch = fetch
        self._clock = clock
        self._lock = threading.Lock()
        self._expires = 0.0
        self._body = None
        self._last_good = None

    def get(self):
        """Return (http_status, body dict). Never raises."""
        with self._lock:
            now = self._clock()
            if self._body is not None and now < self._expires:
                return self._body
            try:
                usage = self._fetch()
                self._last_good = usage
                result = (200, {"status": "ok", "fetched_at": int(time.time()), **usage})
                self._expires = now + CACHE_TTL
            except RelayError as exc:
                body = {"status": exc.status, "message": exc.message}
                if self._last_good:
                    body["stale"] = self._last_good  # last known numbers, clearly marked
                result = (503, body)
                # An expired token is fixed by running Claude Code; recheck soon.
                self._expires = now + (5 if exc.status == "token_expired" else ERROR_TTL)
            self._body = result
            return result


def make_handler(secret, cache):
    secret_bytes = secret.encode()

    class Handler(BaseHTTPRequestHandler):
        server_version = "slopwidget-relay"
        sys_version = ""

        def log_message(self, fmt, *args):  # request line only; never headers
            log(f"{self.address_string()} {fmt % args}")

        def _send(self, status, body):
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)

        def _authorized(self):
            header = self.headers.get("Authorization", "")
            scheme, _, supplied = header.partition(" ")
            if scheme.lower() != "bearer":
                supplied = ""
            return hmac.compare_digest(supplied.strip().encode(), secret_bytes)

        def do_GET(self):
            if not self._authorized():
                time.sleep(0.25)  # blunt brute-force guessing
                self._send(401, {"status": "unauthorized"})
            elif self.path.split("?", 1)[0] == "/usage":
                self._send(*cache.get())
            else:
                self._send(404, {"status": "not_found"})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    parser.add_argument(
        "--bind", help="override the Tailscale address (testing only; wildcard addresses are refused)"
    )
    args = parser.parse_args()

    address = args.bind or tailscale_ip()
    if not address:
        raise SystemExit("Could not find a Tailscale IPv4 address. Is Tailscale up?")
    if ipaddress.ip_address(address).is_unspecified:
        raise SystemExit("Refusing to bind to a wildcard address.")

    secret = load_secret()
    server = ThreadingHTTPServer((address, args.port), make_handler(secret, UsageCache()))
    log(f"serving GET /usage on http://{address}:{args.port} (secret: {SECRET_PATH})")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
