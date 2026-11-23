# Privacy policy

*Wrist Bridge* (this project's Apple Watch app) and its relay service. Last updated November 23, 2026.

Wrist Bridge lets you use the Claude Code sessions on your own Mac from your Apple Watch. It's
built so that your work stays between your watch and your Mac.

## What we don't collect

- No accounts, no names or email addresses, no analytics, no advertising, and no tracking.
- We don't see your prompts, Claude's replies, your session list, or your code. These travel
  between your watch and your Mac encrypted end to end, with a key only those two devices have.

## What the relay handles

To connect your watch to your Mac without either one needing a public address, the app uses a
relay service we run on Cloudflare. It keeps the minimum needed to do that:

- **Random ids and secrets** for your Mac and each paired watch, the devices' public keys, and the
  time each watch was paired. These are kept until you unpair (`claude-watch unpair`, or Unpair in
  the app's Settings).
- **Push tokens**, so it can send alerts to your watch. Apple issues these, and they identify only
  the app on your device.
- **Alert text**, while an alert is being sent: the session's title and its question, or the start
  of its last reply. Apple's push service needs readable text to display an alert. The relay
  passes it to Apple and doesn't store it.
- **Short-lived pairing codes**, deleted on use or after 10 minutes.

Cloudflare and Apple process this data as our service providers, under their own privacy
policies. Cloudflare may keep standard request logs, such as IP addresses, for security.

## On your devices

- **The Mac companion:** the bridge runs on your Mac. It reads your Claude Code sessions there,
  and keeps its settings in `~/.claude-watch`.
- **The watch app:** it keeps its pairing key and settings on the watch.

## Demo mode

Entering the code 000 000 shows sample sessions. Nothing leaves the watch in demo mode.

## Your choices

- Unpairing deletes your watch's records from the relay.
- Removing the app or the bridge deletes their local data.
- You can run your own relay; the source is public.

## Contact

Open an issue at https://github.com/carpit680/claude-watch/issues.
