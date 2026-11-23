# Architecture

## Pieces

| Piece | Where | Role |
| --- | --- | --- |
| Bridge | `bridge/server.mjs`, installed copy in `~/.claude-watch/server.mjs` | The watch API; reads transcripts, runs and relays messages, asks for pushes |
| Relay | `relay/` (Cloudflare Worker) | Carries encrypted requests between watch and Mac; pairing codes; sends Apple pushes |
| Login agents | `~/Library/LaunchAgents/local.claudewatch.{bridge,tunnel}.plist` | Start the bridge (and an optional tunnel) at login, restart them if they exit |
| `claude-watch` command | `~/.claude-watch/bin/claude-watch`, linked onto the PATH | `pair`, `unpair`, `login`, … for the installed bridge |
| Watch app | `ClaudeWatch/ClaudeWatch/` | Sessions list, session view, dictation, read-aloud, alert handling |
| Complications | `ClaudeWatch/ClaudeWidgets/` | WidgetKit: "Claude sessions" and "Claude usage" |
| Shared code | `ClaudeWatch/Shared/` | API client and models, used by both the app and the complications |
| Container app | `WristBridge` target | Empty iOS wrapper, needed only to upload builds to TestFlight |

State on the Mac, all in `~/.claude-watch/` (mode 0700):

| File | Holds |
| --- | --- |
| `relay.json` | this Mac's relay account (id, secret) and its X25519 key pair |
| `pairings.json` | watches paired through the relay, with their public keys |
| `token` | the token for a direct connection |
| `apns.json`, `apns.p8` | an Apple push key, for direct connections only |
| `devices.json` | push tokens from directly connected watches |
| `forks.json` | sessions copied for the watch (when `BRIDGE_LIVE_MODE=copy`) |
| `summaries.json` | cached transcript summaries, so a restarted bridge answers at once |
| `workspace/` | where new sessions from the watch run |
| `logs/` | bridge and tunnel output |

## The relay and pairing

```
watch                         relay                              Mac (bridge)
  │                             │◀──── WebSocket, hello(secret) ────│
  │                             │◀── POST pairing {pk_mac} ─────────│  claude-watch pair
  │                             │──── code 123 456 ────────────────▶│  shows the code
  │── POST join {code, pk_w} ──▶│                                   │
  │◀── watchId, secret, pk_mac ─│──── joined {pk_w} ───────────────▶│
  │  shows check(pk_mac, pk_w)  │                                   │  shows check(pk_mac, pk_w)
  │                             │◀── confirm (you typed y) ─────────│
  │── rpc {box} ───────────────▶│──── rpc {box} ───────────────────▶│  opens, runs the API call,
  │◀── {box} ───────────────────│◀─── rpc-reply {box} ──────────────│  seals the answer
```

- **Key:** `HKDF-SHA256(X25519(own private, peer public), salt = pk_mac ‖ pk_w,
  info = "claude-watch v1")`, giving 32 bytes.
- **Box:** ChaCha20-Poly1305, laid out as `nonce(12) ‖ ciphertext ‖ tag(16)`, base64. The AAD is
  the watch id. Inside is `{method, path, body}` going in and `{status, body}` coming back: the
  same API as the local HTTP one.
- **Check number:** `SHA-256("claude-watch check" ‖ pk_mac ‖ pk_w)`. Take the first 4 bytes as a
  big-endian integer, mod 1 000 000.
- **Pushes:** the bridge sends `{type: "push", kind, payload}` over its WebSocket. The relay sends
  that to every confirmed watch's push tokens, with its own Apple key. Once any watch is paired
  through the relay, the bridge stops sending pushes directly.

## Reading sessions

Claude Code writes each session to `~/.claude/projects/<folder>/<session-id>.jsonl`. The bridge
reads the tail of each transcript (at most 8 MB the first time, then only the lines added since)
and folds the entries into:

- a title, project and recent turns;
- **choices**: an open `AskUserQuestion`, a `wrap_up` ask with its buttons, or a final
  `Options: a | b` line in a reply.

Running Claude processes each write `~/.claude/sessions/<pid>.json` with `sessionId`, `status`
(`busy`, `idle`, or `waiting` plus `waitingFor` while a dialog such as a permission prompt is
open) and `messagingSocketPath`. The bridge uses these to tell which sessions are open on the
Mac and what they are doing.

Session states, as the watch shows them:

| State | Meaning | Bar |
| --- | --- | --- |
| needs you | open question, or a dialog waiting on the Mac | orange |
| `running` | working on a message from the watch | green |
| `active` | busy on the Mac | green |
| `open` | open on the Mac, idle | blue |
| `idle` | not open anywhere | gray |

## Sending a message

`POST /sessions/:id/message` picks one of three paths:

1. **Open on the Mac, relay mode (default).** A short-lived helper
   (`claude -p --model haiku --allowedTools SendMessage`) sends the text to the session's socket
   with Claude Code's cross-session messaging. The live session answers in its own conversation.
   The bridge counts the relay done once that conversation shows the relayed message followed by
   a reply.
2. **Open on the Mac, copy mode.** The bridge runs `claude -p --resume <id> --fork-session` into a
   new session, so two processes never write the same transcript.
3. **Not open anywhere.** `claude -p --resume <id>`, run headless in the session's folder.

Headless runs get an extra system prompt asking for a reply of about 50 words with an optional
`Options:` line. Relayed messages carry the same request in the message itself.

`POST /sessions` starts a new session, unless the text starts with "tell/ask/message <name>" and
`<name>` matches a recent session's project folder or title. Then it goes to that session.

## Alerts and the watch face

Every 3 seconds the bridge looks at recent sessions and pushes through Apple's push service with
a token-based key:

- **needs you** (category `needs-you`, or `on-mac` for dialogs): sent once per question. The
  options travel in the payload. The app's notification scene turns them into buttons, which open
  the session and send the answer. (watchOS gives an app no network access while it handles a
  notification button in the background.)
- **done** (category `done`): when a session goes from busy to idle after at least
  `BRIDGE_DONE_MIN_SECONDS`, or after any message from the watch.
- **widget reload** (push type `widgets`, watchOS 26+): when the counts on the face change.

Usage limits come from the `rate_limit_event` that `claude -p --output-format stream-json`
reports. The bridge makes a tiny request for it at most every 10 minutes, and only while the watch
asks for `/status`.

## Bridge API

The same calls arrive two ways: inside relay boxes from paired watches, or over local HTTP with
`Authorization: Bearer <token>` (a direct connection through your own tunnel).

| Method and path | Returns |
| --- | --- |
| `GET /sessions` | `{sessions: [{id, title, project, updatedAt, state, needsYou, preview, watchCopy}]}` (newest 30) |
| `GET /sessions/:id` | `{id, title, project, state, turns, choices, pending, error, canStop, watchCopy, waitingOnMac}` |
| `POST /sessions` `{text}` | `{id, title, routed?}`: a new session, or the session it was routed to |
| `POST /sessions/:id/message` `{text}` | `{id, title}`: `id` is a fork's id in copy mode |
| `POST /sessions/:id/stop` | stops a headless run (not a relay) |
| `GET /status` | `{needsYou, working, idle, top, usage}` for the watch face |
| `POST /devices` `{token, sandbox, kind}` | registers a push token (`kind`: `app` or `widgets`) |
| `POST /token/rotate` | `{token}`: a new direct-connection token (not over the relay) |
