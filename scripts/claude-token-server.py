#!/usr/bin/env python3
"""Serve the desktop's current Claude Code access token to the slopWidget app.

GET /token  (Authorization: Bearer <shared secret>)
  200 {"accessToken", "expiresAt", "scopes"}   token is valid for > margin
  409 {"status": "expired", ...}               expired or about to expire
  503 {"status": "no_credentials", ...}        not logged in / file missing
  500 {"status": "unreadable", ...}            credentials file unparseable
  401 {"status": "unauthorized"}               missing / wrong secret

The credentials file is re-read on every request, so whatever Claude Code last
wrote is what gets served. The refresh token is never read into the response.
This script never calls Anthropic's OAuth endpoint: refresh tokens rotate, and
refreshing behind Claude Code's back could log it out.

Binds only to the Tailscale IPv4 address (never 0.0.0.0). Plain HTTP by default
(Tailscale already encrypts the hop with WireGuard); pass --tls-cert/--tls-key
(e.g. from `tailscale cert`) to serve HTTPS.
"""

import argparse
import hashlib
import hmac
import json
import os
import secrets
import ssl
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DEFAULT_CREDENTIALS = Path.home() / ".claude" / ".credentials.json"
DEFAULT_SECRET_FILE = Path.home() / ".config" / "slopwidget" / "token-secret"
DEFAULT_PORT = 8787
DEFAULT_MARGIN_SECONDS = 600


def load_or_create_secret(path: Path) -> bytes:
    """Return the shared secret, creating it (0600) on first run."""
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        mode = path.stat().st_mode & 0o777
        if mode & 0o077:
            os.chmod(path, 0o600)
            print(f"warning: tightened {path} from {mode:o} to 600", file=sys.stderr)
        value = path.read_text().strip()
        if len(value) < 16:
            sys.exit(f"{path} is too short to be a safe secret; delete it to regenerate")
        return value.encode()
    value = secrets.token_urlsafe(32)
    with os.fdopen(fd, "w") as f:
        f.write(value + "\n")
    print(f"created new sync secret at {path} (read it with: cat {path})", file=sys.stderr)
    return value.encode()


def tailscale_ipv4() -> str:
    try:
        out = subprocess.run(
            ["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=10, check=True
        ).stdout.split()
    except (OSError, subprocess.SubprocessError) as exc:
        sys.exit(f"could not determine the Tailscale IP ({exc}); pass --host explicitly")
    if not out:
        sys.exit("tailscale reported no IPv4 address; is Tailscale up?")
    return out[0]


def _digest(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()


def make_handler(secret: bytes, credentials_path: Path, margin: int):
    secret_digest = _digest(secret)

    class Handler(BaseHTTPRequestHandler):
        server_version = "claude-token-server"
        sys_version = ""

        def log_message(self, fmt, *args):  # never log headers or bodies
            return

        def _log(self, status: int):
            ts = time.strftime("%Y-%m-%dT%H:%M:%S")
            print(f"{ts} {self.client_address[0]} {self.command} {self.path.split('?')[0]} {status}",
                  file=sys.stderr, flush=True)

        def _send(self, status: int, body: dict):
            payload = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(payload)
            self._log(status)

        def _authorized(self) -> bool:
            header = self.headers.get("Authorization", "")
            scheme, _, presented = header.partition(" ")
            if scheme.lower() != "bearer":
                return False
            # Compare fixed-length digests so neither length nor content leaks.
            return hmac.compare_digest(_digest(presented.strip().encode()), secret_digest)

        def do_GET(self):
            if not self._authorized():
                time.sleep(0.3)  # blunt brute-force speed
                return self._send(401, {"status": "unauthorized"})
            if self.path.split("?")[0] != "/token":
                return self._send(404, {"status": "not_found"})

            try:
                raw = json.loads(credentials_path.read_text())
            except FileNotFoundError:
                return self._send(503, {"status": "no_credentials",
                                        "message": "Claude Code is not logged in on this machine."})
            except (OSError, ValueError):
                return self._send(500, {"status": "unreadable",
                                        "message": "Could not read the Claude Code credentials file."})

            oauth = raw.get("claudeAiOauth") if isinstance(raw, dict) else None
            token = oauth.get("accessToken") if isinstance(oauth, dict) else None
            expires_at = oauth.get("expiresAt") if isinstance(oauth, dict) else None
            if not isinstance(token, str) or not token or not isinstance(expires_at, (int, float)):
                return self._send(503, {"status": "no_credentials",
                                        "message": "No Claude subscription login found."})

            if expires_at / 1000 - time.time() < margin:
                return self._send(409, {"status": "expired", "expiresAt": int(expires_at),
                                        "message": "Token expired or about to; run Claude Code to refresh it."})

            scopes = oauth.get("scopes")
            self._send(200, {
                "accessToken": token,
                "expiresAt": int(expires_at),
                "scopes": scopes if isinstance(scopes, list) else [],
            })

    return Handler


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--host", help="address to bind (default: this machine's Tailscale IPv4)")
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--credentials", type=Path, default=DEFAULT_CREDENTIALS)
    p.add_argument("--secret-file", type=Path, default=DEFAULT_SECRET_FILE)
    p.add_argument("--margin-seconds", type=int, default=DEFAULT_MARGIN_SECONDS,
                   help="report 'expired' when fewer than this many seconds remain")
    p.add_argument("--tls-cert", type=Path)
    p.add_argument("--tls-key", type=Path)
    args = p.parse_args()

    host = args.host or tailscale_ipv4()
    if host in ("0.0.0.0", "::", ""):
        sys.exit("refusing to bind a wildcard address; use the Tailscale IP")

    secret = load_or_create_secret(args.secret_file)
    server = ThreadingHTTPServer((host, args.port), make_handler(secret, args.credentials, args.margin_seconds))
    scheme = "http"
    if args.tls_cert and args.tls_key:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = "https"
    print(f"serving {scheme}://{host}:{args.port}/token", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
