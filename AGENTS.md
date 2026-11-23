# Setting up Claude Watch: instructions for coding agents

You are helping a user install Claude Watch: a bridge on their Mac, and a watchOS app that talks
to it. Work from the repository root. Do every step you can yourself. Stop and ask the user only
for the steps marked **(user)**: sign-ins, passwords, purchases, and taps on the watch. Never type
their passwords or handle their Apple or Cloudflare credentials.

Check each step's result before moving on. If a check fails, use the README's Troubleshooting
table before asking the user.

## 0. Gather what you need

Ask the user, in one question, for:

- a hostname on a domain in their Cloudflare account, for the bridge (e.g. `watch.example.com`);
- a reverse-DNS bundle prefix they own (suggest `com.<their-name>.claudewatch`).

Find their Apple team ID yourself where you can. With Xcode signed in, `security find-identity -v
-p codesigning` shows `Apple Development: … (TEAMID)`. Otherwise ask them to read it from
developer.apple.com → Membership.

Check the tools:

```bash
node --version          # 18 or later
xcodebuild -version     # Xcode 26 or later
command -v cloudflared || brew install cloudflared
```

If `xcodebuild` says the developer directory is the Command Line Tools, prefix the commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` instead of changing it system-wide.

## 1. Sign the bridge's claude in (user)

```bash
node bridge/server.mjs login
```

This opens a browser sign-in. Run it in a terminal the user can see, and wait for them to finish.

## 2. Tunnel

```bash
cloudflared tunnel login                                  # (user) picks their domain in the browser
cloudflared tunnel create claude-watch
cloudflared tunnel route dns claude-watch <hostname>
```

`cloudflared tunnel login` can time out. Run it again if it does.

## 3. Bridge and tunnel at login

```bash
bridge/install-agents.sh
curl -s -o /dev/null -w "%{http_code}\n" https://<hostname>/status   # expect 401 (no token): reachable
```

## 4. Configure the app

```bash
node bridge/server.mjs configure https://<hostname> --team <TEAM_ID> --bundle-prefix <prefix>
```

Never commit `ClaudeWatch/Shared/Config.generated.swift` (it holds the token) or
`ClaudeWatch/Local.xcconfig`.

## 5. Push key (user, then you)

The user creates a key on developer.apple.com → Certificates, Identifiers & Profiles → Keys,
ticks Apple Push Notifications service, and downloads `AuthKey_XXXXXXXXXX.p8`. Then you run:

```bash
node bridge/server.mjs push
```

## 6. Build and install

The user must be signed in to Xcode (Settings → Apple Accounts) **(user)**, and their watch must
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

- "No Accounts" from `xcodebuild` means Xcode isn't signed in. Ask the user to sign in, then quit
  and reopen Xcode.
- An install can fail with "device disconnected", or with error 3002 while the watch is asleep.
  Ask the user to wake the watch, then retry.
- If the install says the widget's profile "cannot be installed on this device", move the stale
  `iOS Team Provisioning Profile: *` out of
  `~/Library/Developer/Xcode/UserData/Provisioning Profiles`, then build again.

The app asks to send notifications on first launch **(user taps Allow)**. Then check:

```bash
cat ~/.claude-watch/devices.json   # should list a device with "kind": "app"
```

## 7. Complications (user)

Ask the user to edit their watch face and add **Claude sessions** and/or **Claude usage**. Once
one is on the face, `devices.json` also gains a `"kind": "widgets"` entry.

## Done: what to tell the user

- The bar colors: orange needs you, green busy, blue open on the Mac, gray idle.
- Alerts arrive when a session asks something, shows a permission prompt (answerable only on the
  Mac), or finishes a long task.
- *"Tell <project> …"* on New session messages that session.
- Keep the Mac plugged in, or it may sleep and the watch can't reach it.

## Working on the code

- Bridge: `bridge/server.mjs`, a single file with no dependencies. Check syntax with
  `node --check bridge/server.mjs`, then run `bridge/install-agents.sh` to restart the installed
  copy. `node bridge/server.mjs route "<text>"` tests spoken routing without sending anything.
- App: `ClaudeWatch/` has three source folders. `ClaudeWatch/` is the app, `ClaudeWidgets/` the
  complications, and `Shared/` holds code both use. The Xcode project uses folder references, so
  new files are picked up automatically.
- Signing values come from `ClaudeWatch/Base.xcconfig`, overridden by `Local.xcconfig`. Don't put
  team IDs or bundle IDs in `project.pbxproj`.
- Architecture and the HTTP API: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
