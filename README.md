# Claude Watch

Control the [Claude Code](https://claude.com/claude-code) sessions on your Mac from your Apple Watch.

- **See your sessions**: which are busy, open on the Mac, idle, or waiting on you.
- **Talk to them**: dictate a message to any session, including the ones open in the Claude
  desktop app or a terminal. Replies come back short enough to read on a watch, or the watch
  reads them aloud.
- **Get told when one needs you**: an alert the moment a session asks a question or shows a
  permission prompt. The answers are buttons on the alert.
- **Get told when it's done**: an alert with the last reply when a long task finishes.
- **Watch face complications**: who needs you, how many sessions are working, and how much of
  your Claude usage limit is spent.

> Unofficial. Not made or supported by Anthropic.

## How it works

```
Apple Watch app ──HTTPS──▶ Cloudflare Tunnel ──▶ bridge on your Mac (127.0.0.1:8787)
       ▲                                              │  reads  ~/.claude/projects/*.jsonl
       │                                              │  runs   claude -p … (headless replies)
       └──── Apple push (alerts, face reloads) ◀──────┘  relays into sessions open on the Mac
```

- `bridge/server.mjs` runs on your Mac. Plain Node, no dependencies. It listens only on
  `127.0.0.1`, and every request needs a pairing token. It reads session transcripts, sends
  messages with the `claude` command line, and pushes alerts through Apple's push service.
- `ClaudeWatch/` is the watchOS app (SwiftUI, no iPhone app needed) with its complications.
- A Cloudflare Tunnel gives the bridge an HTTPS address the watch can reach from anywhere.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the details.

## Requirements

- A Mac with [Claude Code](https://claude.com/claude-code) (the desktop app or the CLI) and
  Node 18 or later.
- Xcode 26 or later, and a paid Apple Developer account (for push notifications and installing on
  a watch).
- An Apple Watch on watchOS 26 or later, with Developer Mode on.
- A domain on Cloudflare, for a stable address (a free account is enough). Without one, you can
  try it with a temporary address.

## Setting it up

**Using Claude Code?** Open this folder in Claude Code and say *"set this up for me"*. The steps
for agents are in [AGENTS.md](AGENTS.md); Claude does what it can and tells you when it needs you
(sign-ins, passwords, and taps on the watch).

By hand, from the repository folder:

1. **Sign the bridge in to Claude** (once). The desktop app's sign-in isn't shared with the
   command line the bridge uses.

   ```bash
   node bridge/server.mjs login
   ```

2. **Create the tunnel.** Replace `watch.example.com` with a hostname on your Cloudflare domain.

   ```bash
   brew install cloudflared
   cloudflared tunnel login
   cloudflared tunnel create claude-watch
   cloudflared tunnel route dns claude-watch watch.example.com
   ```

3. **Run the bridge and tunnel at login.** This copies the bridge to `~/.claude-watch` and
   installs two login agents, which restart the bridge and tunnel if they stop.

   ```bash
   bridge/install-agents.sh
   ```

4. **Point the app at your Mac and your Apple account.** Your team ID is under Membership on
   developer.apple.com. The bundle prefix is any reverse-DNS name you own.

   ```bash
   node bridge/server.mjs configure https://watch.example.com --team ABCDE12345 --bundle-prefix com.yourname.claudewatch
   ```

   This writes `ClaudeWatch/Shared/Config.generated.swift` (the address and pairing token) and
   `ClaudeWatch/Local.xcconfig` (your signing settings). Git ignores both.

5. **Turn on alerts.** On developer.apple.com, open Keys, add a key with **Apple Push
   Notifications service (APNs)**, and download it. Then:

   ```bash
   node bridge/server.mjs push
   ```

   This finds the newest `AuthKey_….p8` in Downloads. You can pass a path instead.

6. **Install on your watch.** Turn on Developer Mode on the watch (Settings → Privacy & Security).
   Sign in to Xcode with your Apple account (Settings → Apple Accounts), open
   `ClaudeWatch/ClaudeWatch.xcodeproj`, pick the **ClaudeWatch** scheme and your watch, and press
   Run. Allow notifications when the app asks.

7. **Add the complications.** Long-press your watch face, tap Edit, and choose **Claude sessions**
   or **Claude usage** for a slot.

## Using it

- **Sessions list**: the bar beside each session shows its state: orange needs you, green busy,
  blue open on the Mac, gray idle.
- **In a session**: the mic button dictates a message, and the speaker button reads the last
  reply aloud. When Claude offers choices, they show as buttons.
- **New session**: starts one in `~/.claude-watch/workspace`. Say *"Tell harness to run the
  tests"* to message the session whose project folder or title is "harness" instead.
- **Alerts**: tap an answer button, or Reply, on a "needs you" alert. Permission prompts can only
  be answered on the Mac.

### Messages to sessions open on your Mac

A session open in the Claude desktop app or a terminal gets your message delivered into it, using
Claude Code's session-to-session messaging. It answers in its own conversation, so you see the
exchange on the Mac too. Notes:

- The message arrives labelled as relayed from your watch, not as typed by you.
- A busy session reads it between steps.
- A running Mac session can't be stopped from the watch.

Sessions that aren't open anywhere are resumed headless by the bridge instead.

## Configuration

Environment variables for the bridge. Set them in the `EnvironmentVariables` of
`~/Library/LaunchAgents/local.claudewatch.bridge.plist`, or export them before running it.

| Variable | Default | What it does |
| --- | --- | --- |
| `BRIDGE_PORT` | `8787` | Port on 127.0.0.1 |
| `BRIDGE_PERMISSION_MODE` | Claude's default | `claude --permission-mode` for headless watch messages, e.g. `acceptEdits` |
| `BRIDGE_NEW_CWD` | `~/.claude-watch/workspace` | Folder for sessions started from the watch |
| `BRIDGE_LIVE_MODE` | `relay` | `copy` answers sessions open on the Mac from a fork instead |
| `BRIDGE_DONE_MIN_SECONDS` | `45` | Shortest turn at the Mac that gets a "done" alert |
| `BRIDGE_KEEP_AWAKE` | on | `0` lets the Mac sleep while plugged in |
| `TUNNEL_NAME` | `claude-watch` | Cloudflare tunnel name, read by `install-agents.sh` |
| `CLAUDE_BIN` | found automatically | Path to the `claude` binary |

After editing `bridge/server.mjs`, run `bridge/install-agents.sh` again to restart the bridge.

## Security

Anyone with your bridge address and pairing token can run Claude on your Mac. See
[SECURITY.md](SECURITY.md). In short: keep `Config.generated.swift` and `~/.claude-watch` private,
and if the token leaks, use **New pairing token** in the watch app's Settings.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "Can't reach your Mac" | The Mac is asleep (on battery, or the lid is closed), or the tunnel is down. Check `~/.claude-watch/logs/tunnel.log`. |
| "Bridge is not signed in" | Run `node bridge/server.mjs login`. |
| "didn't accept the pairing token" | The token changed. Run `configure` again and reinstall, or enter it in the app's Settings. |
| No alerts | Run `node bridge/server.mjs push`, allow notifications on the watch, and check `~/.claude-watch/devices.json` lists the watch. |
| Xcode "No Accounts" or a profile error | Sign in under Xcode → Settings → Apple Accounts, then build again. |
| Install fails with "profile cannot be installed" | A stale wildcard profile without your watch. Remove it from `~/Library/Developer/Xcode/UserData/Provisioning Profiles` and build again. |

Bridge logs are in `~/.claude-watch/logs/`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). MIT licensed; see [LICENSE](LICENSE).
