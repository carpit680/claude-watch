---
name: wrist-bridge
description: Set up, check or fix Wrist Bridge, the Apple Watch app for Claude Code. Use when the user wants to see, talk to or get alerts from their Claude Code sessions on an Apple Watch, asks to install or pair Wrist Bridge (or Claude Watch), or reports that the watch app can't reach their Mac, has no alerts, or shows the wrong sessions.
---

# Wrist Bridge

Wrist Bridge puts the user's Claude Code sessions on their Apple Watch. A small bridge runs on
their Mac and connects out to a relay. The watch pairs with it through the relay, and requests
and replies are encrypted end to end.

- App Store: https://apps.apple.com/app/id6838125368
- Source and full docs: https://github.com/carpit680/claude-watch
- npm package: `wrist-bridge`

Do every step you can yourself. Stop and ask the user only for the steps marked **(user)**:
sign-ins and taps on the watch. Never type their passwords or handle their Apple or Claude
credentials. Check each step's result before going on.

## Before you start

- The Mac must be macOS with Claude Code installed (the desktop app or the CLI). Check with
  `claude --version`. If it's missing, suggest the desktop app's Code tab or
  `npm install -g @anthropic-ai/claude-code`.
- Node 22 or later: `node --version`. If it's older or missing, suggest `brew install node`, or
  `nvm install 22` if they use nvm.
- An Apple Watch on watchOS 26 or later.

## 1. The app on the watch (user)

Ask the user to install **Wrist Bridge** from the App Store on their watch, or on the iPhone it's
paired with, and open it once. To build it from source instead, follow `AGENTS.md` in the
repository; it needs Xcode and an Apple Developer account.

## 2. The bridge on the Mac

Run this in a terminal the user can see, because it's interactive:

```bash
npx wrist-bridge setup
```

It installs the bridge to start at login, and adds the `wrist-bridge` command. Then:

- If the bridge isn't signed in to Claude, it opens a browser sign-in **(user)**.
- It then shows a 6-digit pairing code. Go to step 3 while it waits.

## 3. Pair (user)

Tell the user:

1. On the watch, open Wrist Bridge, tap **Pair with your Mac**, and enter the code.
2. The watch shows a check number. When the Mac asks about the same number, type `y` in the
   terminal and press Return.
3. Tap **Allow** when the app asks to send notifications.

The code works once, for 10 minutes. If it expires, run `wrist-bridge pair` for a new one.

## 4. Check it

```bash
wrist-bridge status
```

All four lines should have a check: bridge running, relay connected, Claude sign-in, paired. The
watch's session list should fill in within a few seconds.

## 5. Complications (user, optional)

Ask the user to edit a watch face and add the **Sessions** and/or **Usage** complication from
Wrist Bridge.

## What to tell the user when it works

- **Bar colors** in the session list: orange needs you, green busy, blue open on the Mac, gray
  idle.
- **Alerts** come when a session asks a question (its answers are buttons on the alert), shows a
  permission prompt (answerable only on the Mac), or finishes a long task.
- **New session** starts one from the watch. *"Tell <project> …"* messages that project's
  session instead.
- **Keep the Mac plugged in.** If it sleeps, the watch can't reach it.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| "Your Mac isn't connected" | The Mac is asleep or the bridge isn't running. Run `wrist-bridge status`; if the bridge is down, run `npx wrist-bridge install`. |
| "Bridge is not signed in" | Run `wrist-bridge login` in a terminal the user can see **(user)**. |
| "That code isn't valid" | Codes work once, for 10 minutes. Run `wrist-bridge pair` again. |
| "no longer paired" | The Mac unpaired the watch. Run `wrist-bridge pair`. |
| No alerts | On the watch: Settings → Notifications → Wrist Bridge, allow them, then reopen the app **(user)**. |
| `setup` says Claude Code isn't found | Install Claude Code, or set `CLAUDE_BIN` to its path and run setup again. |

Logs are in `~/.claude-watch/logs/`. Other commands: `wrist-bridge unpair` cuts off every paired
watch, and `wrist-bridge uninstall` removes the bridge.

## Privacy, briefly

Prompts, replies and session lists are encrypted between the watch and the Mac; the relay can't
read them. The relay does see alert text, because Apple's push service needs readable text. The
user can run their own relay; see `relay/README.md` in the repository.
