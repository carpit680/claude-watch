# Security

Claude Watch lets a watch run Claude Code on your Mac. Treat the bridge like remote access to
your Mac.

## What protects it

- The bridge listens only on `127.0.0.1`. It's reachable from outside only through your
  Cloudflare Tunnel.
- Every request needs the pairing token, a random 256-bit value in `~/.claude-watch/token`. It's
  compared in constant time, and failed attempts are slowed down.
- Messages from the watch run with Claude Code's normal permission rules. Anything that needs
  approval is blocked, unless you start the bridge with `BRIDGE_PERMISSION_MODE`. Permission
  prompts in sessions open on the Mac can only be answered at the Mac.
- `~/.claude-watch` is created with mode 0700, and its secrets with 0600.

## What you must keep private

- `ClaudeWatch/Shared/Config.generated.swift`: it holds the token. It's in `.gitignore`; don't
  commit it, and don't share builds made from it.
- `~/.claude-watch/` (token, Apple push key, device tokens).

## If the token leaks

Use **Settings → New pairing token** in the watch app. The old token stops working at once, and
the watch keeps the new one. Before you next build the app, run
`node bridge/server.mjs configure <url>` so the built-in token matches.

You can also rotate it from the Mac: delete `~/.claude-watch/token`, run
`bridge/install-agents.sh`, then `configure` and reinstall the app.

For extra protection, put the tunnel's hostname behind Cloudflare Access with a service token.
The watch app would then need to send that token too; it doesn't yet.

## Reporting a problem

Please open a GitHub security advisory on this repository rather than a public issue.
