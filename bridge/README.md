# wrist-bridge

The Mac companion for **Wrist Bridge**, the Apple Watch app for your Claude Code sessions.

```bash
npx wrist-bridge setup
```

That installs the bridge (it runs at login), signs it in to Claude, and shows a code to pair your
watch. Afterwards: `wrist-bridge status`, `wrist-bridge pair`, `wrist-bridge unpair`,
`wrist-bridge uninstall`.

Needs macOS, Node 22+, and Claude Code. Details: https://carpit680.github.io/claude-watch/

Unofficial; not made or endorsed by Anthropic. MIT licensed.
