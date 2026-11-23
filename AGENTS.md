# Setting up Claude Watch: instructions for coding agents

You are helping a user install Claude Watch: a bridge on their Mac, and a watchOS app that pairs
with it through a relay. Work from the repository root. Do every step you can yourself. Stop and
ask the user only for the steps marked **(user)**: sign-ins, passwords, and taps on the watch.
Never type their passwords or handle their Apple or Claude credentials.

Check each step's result before moving on. If a check fails, use the README's Troubleshooting
table before asking the user.

## 0. Check the tools

```bash
node --version          # 22 or later (the bridge uses Node's built-in WebSocket)
```

## 1. Install the bridge and sign it in (user, briefly)

Run this in a terminal the user can see:

```bash
npx wrist-bridge setup
```

It installs the bridge to start at login, and then:

- If the bridge isn't signed in to Claude, it opens a browser sign-in **(user)**.
- Then it shows a pairing code. If the watch app isn't installed yet, stop it with Ctrl-C, do
  step 3, and run `wrist-bridge pair` afterwards.

From a clone of the repository, `bridge/install-agents.sh` installs that copy instead. Check:

```bash
wrist-bridge status    # bridge running, relay connected, signed in, paired
```

## 2. Get the app on the watch

If the app is installed from the App Store (https://apps.apple.com/app/id6838125368), skip to step 3. Otherwise build it:

- Find the Apple team ID yourself where you can: with Xcode signed in,
  `security find-identity -v -p codesigning` shows `Apple Development: … (TEAMID)`. Otherwise
  ask the user (developer.apple.com → Membership).
- Ask the user for a bundle prefix they own, and suggest `com.<their-name>.claudewatch`.

```bash
node bridge/server.mjs configure --team <TEAM_ID> --bundle-prefix <prefix>
```

The user must be signed in to Xcode (Settings → Apple Accounts) **(user)**, and the watch must
have Developer Mode on and be paired with this Mac in Xcode's Devices window **(user)**.

```bash
cd ClaudeWatch
xcodebuild -project ClaudeWatch.xcodeproj -scheme ClaudeWatch \
  -destination 'generic/platform=watchOS' -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl list devices                       # find the watch's identifier
xcrun devicectl device install app --device <watch-id> build/Build/Products/Debug-watchos/ClaudeWatch.app
xcrun devicectl device process launch --device <watch-id> <prefix>.watchkitapp
```

Notes:

- If `xcodebuild` says the developer directory is the Command Line Tools, prefix the commands
  with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- "No Accounts" means Xcode isn't signed in. Ask the user to sign in, then quit and reopen Xcode.
- An install can fail with "device disconnected" or error 3002 while the watch is asleep. Ask the
  user to wake it, then retry.
- If the widget's profile "cannot be installed on this device", move the stale
  `iOS Team Provisioning Profile: *` out of
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, then build again.
- A build with the user's own bundle ID gets no alerts from the shared relay. Tell them; the fix
  is their own relay ([relay/README.md](relay/README.md)).

## 3. Pair (user and you)

Start `wrist-bridge pair` in a terminal the user can see. It prints a 6-digit code. Tell the user:

1. On the watch, open the app, tap **Pair with your Mac**, and enter the code.
2. The watch then shows a check number. If the Mac asks about the same number, type `y` in the
   terminal and press Return.

The code expires after 10 minutes. If it does, run `pair` again. Check the result:

```bash
cat ~/.claude-watch/pairings.json   # one entry per paired watch
```

The app asks to send notifications on first launch **(user taps Allow)**.

## 4. Complications (user)

Ask the user to edit their watch face and add **Claude sessions** and/or **Claude usage**.

## Done: what to tell the user

- The bar colors: orange needs you, green busy, blue open on the Mac, gray idle.
- Alerts arrive when a session asks something (its answers are buttons on the alert), shows a
  permission prompt (answerable only on the Mac), or finishes a long task.
- *"Tell <project> …"* on New session messages that session.
- Keep the Mac plugged in, or it may sleep and the watch can't reach it.

## Working on the code

- **Bridge:** `bridge/server.mjs`, one file, no dependencies.
  - Check syntax with `node --check bridge/server.mjs`, then run `bridge/install-agents.sh` to
    restart the installed copy.
  - `node bridge/server.mjs route "<text>"` tests spoken routing without sending anything.
- **Relay:** `relay/src/index.js`.
  - Test locally with `npx wrangler dev` from `relay/`; see [relay/README.md](relay/README.md).
  - The encryption must match `ClaudeWatch/Shared/Relay.swift` and the relay section of
    `server.mjs` exactly.
- **App:** `ClaudeWatch/` has three source folders.
  - `ClaudeWatch/` is the app, `ClaudeWidgets/` the complications, and `Shared/` the code both use.
  - The project uses folder references, so new files are picked up automatically.
- **Signing and relay settings:** these come from `ClaudeWatch/Base.xcconfig`, overridden by
  `Local.xcconfig`. Don't put team IDs or bundle IDs in `project.pbxproj`.
- **More:** architecture, the HTTP API and the relay protocol are in
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
