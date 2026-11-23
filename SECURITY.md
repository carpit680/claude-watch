# Security

Claude Watch lets a watch run Claude Code on your Mac. Treat a paired watch like remote access to
your Mac.

## What protects it

- **The bridge accepts no connections from the internet.** It listens only on `127.0.0.1` and
  connects *out* to the relay.
- **Pairing needs your Mac and your confirmation.**
  - `claude-watch pair` shows a 6-digit code that works once, for 10 minutes. The relay limits
    guesses per address.
  - The watch and Mac each show a check number derived from both their public keys, and the watch
    is let in only after you confirm on the Mac that the numbers match. A relay, or anyone else,
    that swapped keys would produce a different number.
- **Requests and replies are encrypted end to end.** That covers messages, session lists and
  transcripts. The key comes from an X25519 key agreement made at pairing, run through
  HKDF-SHA256, and each message is sealed with ChaCha20-Poly1305 and bound to the watch's id. The
  relay passes only sealed boxes.
- **Messages from the watch follow Claude Code's normal permission rules.** Anything that needs
  approval is blocked, unless you set `BRIDGE_PERMISSION_MODE`. Permission prompts in sessions
  open on the Mac can only be answered at the Mac.
- **Local files are private.** `~/.claude-watch` is created with mode 0700, and its secrets with
  0600.

## What the relay can see

- Which Mac and watch are paired, when they connect, and roughly how much they send.
- **The text of alerts**: a session's title and its question, or the start of its last reply.
  Apple's push service needs readable alert text, so these go through the relay unencrypted.
- The watch's push tokens.

The relay operator holds the Apple push key. You can run your own relay to keep all of this to
yourself; see [relay/README.md](relay/README.md).

## On the watch

The pairing key is kept in the app's shared container, so the complications can use it too.
Unpairing deletes it.

## If something leaks

- Run `claude-watch unpair` on the Mac to cut off every paired watch, then pair again.
- For a direct connection: use **New pairing token** in the watch app's Settings, or delete
  `~/.claude-watch/token` and run `bridge/install-agents.sh`.

## Reporting a problem

Please open a GitHub security advisory on this repository rather than a public issue.
