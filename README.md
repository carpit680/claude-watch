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

<img src="docs/images/pairing.png" width="205" alt="Pairing screen on an Apple Watch: a 6-digit code pad">

## How it works

```
Apple Watch app ──HTTPS──▶ relay (Cloudflare Worker) ◀──WebSocket── bridge on your Mac
       ▲                     │  passes encrypted requests;            │ reads ~/.claude/projects
       └── Apple push ◀──────┘  sends alerts                          │ runs and relays to claude
```

- **`bridge/server.mjs`** runs on your Mac. Plain Node, no dependencies.
  - It reads Claude Code's session transcripts, sends messages with the `claude` command line, and
    watches for sessions that need you.
  - It connects *out* to the relay, so your Mac needs no open port, tunnel or domain.
- **`relay/`** is a small Cloudflare Worker that passes messages between watches and Macs.
  - Watch and Mac agree on a key when you pair, so requests and replies are encrypted end to end.
    The relay can't read them.
  - It holds the Apple push key and sends the alerts.
- **`ClaudeWatch/`** is the watchOS app (SwiftUI, no iPhone app needed) with its complications.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) has the details.

## Requirements

- A Mac with [Claude Code](https://claude.com/claude-code) (the desktop app or the CLI) and
  Node 22 or later (`brew install node`).
- An Apple Watch on watchOS 26 or later.
- Until the app is on the App Store, you also need Xcode 26+ and an Apple Developer account to
  install it (see [Building the app yourself](#building-the-app-yourself)).

## Setting it up

**Website with screenshots: https://carpit680.github.io/claude-watch/**

1. Install **Wrist Bridge** on your Apple Watch from the [App Store](https://apps.apple.com/app/id6838125368), and open it.
2. On your Mac:

   ```bash
   npx wrist-bridge setup
   ```

   It installs the bridge to start at login, and signs it in to Claude if needed. Then it shows a
   6-digit code.
3. On the watch, tap **Pair with your Mac** and enter the code. When the watch and Mac show the
   same check number, type `y` on the Mac.

Optionally, add the **Sessions** or **Usage** complication to a watch face.

Later: `wrist-bridge status`, `wrist-bridge pair`, `wrist-bridge unpair`, and
`wrist-bridge uninstall`.

**Using Claude Code?** Open this folder in Claude Code and say *"set this up for me"*.
[AGENTS.md](AGENTS.md) has the steps for agents.

Or install the [Wrist Bridge skill](skills/wrist-bridge/SKILL.md), so any Claude Code session can
set it up, check it or fix it, without a copy of this repository:

```bash
mkdir -p ~/.claude/skills/wrist-bridge && curl -fsSL https://raw.githubusercontent.com/carpit680/claude-watch/main/skills/wrist-bridge/SKILL.md -o ~/.claude/skills/wrist-bridge/SKILL.md
```

Then ask Claude to *"set up Wrist Bridge"*.

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

## Building the app yourself

Until the app is on the App Store:

1. Put in your Apple team ID (developer.apple.com → Membership) and a bundle prefix you own:

   ```bash
   node bridge/server.mjs configure --team ABCDE12345 --bundle-prefix com.yourname.claudewatch
   ```

   This writes `ClaudeWatch/Local.xcconfig`, which git ignores.

2. Sign in to Xcode (Settings → Apple Accounts), and turn on Developer Mode on the watch
   (Settings → Privacy & Security).

3. Open `ClaudeWatch/ClaudeWatch.xcodeproj`, choose the **ClaudeWatch** scheme and your watch, and
   press Run.

With your own bundle ID, the shared relay can't send your build alerts, because Apple ties push
keys to the publisher's apps. Everything else works. For alerts, run your own relay; see
[relay/README.md](relay/README.md).

### Without a relay

You can also reach the bridge directly through your own HTTPS tunnel, such as a Cloudflare Tunnel
to `http://localhost:8787`. Enter the address, and the token from `~/.claude-watch/token`, under
the watch app's Settings → Direct connection. For alerts in this mode, the bridge needs your own
push key: run `node bridge/server.mjs push` with the `AuthKey_….p8` in Downloads.
`install-agents.sh` also runs a Cloudflare tunnel named `claude-watch` at login, if you have one.

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
| `BRIDGE_RELAY` | the shared relay | Relay used by `wrist-bridge pair` |
| `TUNNEL_NAME` | `claude-watch` | Cloudflare tunnel for a direct connection, read by `install-agents.sh` |
| `CLAUDE_BIN` | found automatically | Path to the `claude` binary |

After editing `bridge/server.mjs`, run `bridge/install-agents.sh` to install and restart your copy.

## Security and privacy

A paired watch can run Claude on your Mac, so treat it like remote access. In short:

- Requests and replies between watch and Mac are encrypted end to end. Pairing needs a one-time
  code *and* your confirmation of matching check numbers, so the relay can't swap the keys.
- **Alert text passes through the relay unencrypted**: the session title and question, or the
  start of the last reply. Apple's push service needs readable alert text.
- `wrist-bridge unpair` cuts a watch off at once.

More in [SECURITY.md](SECURITY.md).

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| "Your Mac isn't connected" | The Mac is asleep (on battery, or the lid is closed), or the bridge isn't running. Run `wrist-bridge status`. |
| "Bridge is not signed in" | Run `wrist-bridge login`. |
| "That code isn't valid" | Codes work once, for 10 minutes. Run `wrist-bridge pair` again. |
| "no longer paired" | The Mac unpaired the watch. Pair again. |
| No alerts | Allow notifications for the app on the watch (Settings → Notifications), then reopen it so it signs up again. |
| Xcode "No Accounts" or a profile error | Sign in under Xcode → Settings → Apple Accounts, quit and reopen Xcode, then build again. |
| Install fails with "profile cannot be installed" | A stale wildcard profile without your watch. Remove it from `~/Library/Developer/Xcode/UserData/Provisioning Profiles` and build again. |

Bridge logs are in `~/.claude-watch/logs/`.

## Privacy

See [PRIVACY.md](PRIVACY.md). In short: no accounts, analytics or tracking. Your prompts and
replies are encrypted end to end, and the relay keeps only what it needs to connect and alert.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). MIT licensed; see [LICENSE](LICENSE).
