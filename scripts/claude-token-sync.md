# Claude token sync server

`claude-token-server.py` lets the slopWidget app on your phone fetch the
Claude Code access token that is currently in `~/.claude/.credentials.json`.
The phone then calls Anthropic's `/api/oauth/usage` itself.

## Install (user unit, nothing runs until you start it)

    mkdir -p ~/.local/share/slopwidget ~/.config/systemd/user
    install -m 755 scripts/claude-token-server.py ~/.local/share/slopwidget/
    install -m 644 scripts/claude-token-server.service ~/.config/systemd/user/
    systemctl --user daemon-reload
    systemctl --user start claude-token-server      # try it
    systemctl --user enable claude-token-server     # optional: start at login

First start creates `~/.config/slopwidget/token-secret` (mode 0600). Copy its
contents into the app's Claude tab ("Sync secret") and set "Token sync URL" to
`http://100.110.102.104:8787/token` (or `http://the-thinker:8787/token`).
Re-run `systemctl --user stop claude-token-server` to stop it. Delete the
secret file to rotate it.

## Behaviour

- Binds only to the Tailscale IPv4 (`tailscale ip -4`); refuses wildcard.
- `GET /token` with `Authorization: Bearer <secret>` returns exactly
  `{accessToken, expiresAt, scopes}`; 409 `{"status":"expired"}` when under
  10 minutes remain; 401 on a wrong/missing secret.
- Re-reads the credentials file per request. Never sends the refresh token and
  never calls Anthropic's OAuth endpoint.

## Why it does not refresh the token itself

Access tokens last ~8 h. Refreshing needs the refresh token, and refresh
tokens rotate: if this script refreshed and Claude Code did not see the new
one, Claude Code could be logged out. Only the official CLI should refresh.

`claude auth status` is read-only (verified: it does not modify the file or
refresh), so it is no help. A refresh happens as a side effect of any real API
call (e.g. `claude -p "hi"`), which spends a small amount of subscription
usage and can race with a running interactive session writing the same file.
Not automated here. Practical rule: the token stays fresh while you use Claude
Code on the desktop; after ~8 h idle the app shows "Run Claude Code on your
desktop to refresh".

## HTTPS (optional)

Tailscale already encrypts the hop with WireGuard, so plain HTTP is used by
default. For HTTPS, enable HTTPS certificates in the tailnet admin console,
run `tailscale cert the-thinker.<tailnet>.ts.net`, then start the server with
`--tls-cert ... --tls-key ...` and use an `https://` URL in the app (no ATS
exception would then be needed for that host).
