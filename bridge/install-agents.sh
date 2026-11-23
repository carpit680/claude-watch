#!/bin/zsh
# Runs the bridge and the Cloudflare tunnel at login, and restarts them if they exit.
# Copies the bridge to ~/.claude-watch so it keeps working wherever this project lives.
# Re-run after editing server.mjs. Remove with: bridge/install-agents.sh uninstall
set -euo pipefail

HERE="${0:A:h}"
DEST="$HOME/.claude-watch"
AGENTS="$HOME/Library/LaunchAgents"
DOMAIN="gui/$(id -u)"
TUNNEL="${TUNNEL_NAME:-claude-watch}"
LABELS=(local.claudewatch.bridge local.claudewatch.tunnel)

for label in $LABELS; do
  launchctl bootout "$DOMAIN/$label" 2>/dev/null || true
  # bootout returns before the agent is fully gone; starting it again too early fails.
  for _ in {1..20}; do
    launchctl print "$DOMAIN/$label" >/dev/null 2>&1 || break
    sleep 0.5
  done
done

if [[ "${1:-}" == "uninstall" ]]; then
  for label in $LABELS; do rm -f "$AGENTS/$label.plist"; done
  echo "Removed login agents."
  exit 0
fi

NODE="$(command -v node)"
CLOUDFLARED="$(command -v cloudflared)"
mkdir -p "$DEST/logs" "$AGENTS"
cp "$HERE/server.mjs" "$DEST/server.mjs"

write_plist() { # label, log name, then program arguments
  local label="$1" log="$2"; shift 2
  local args=""
  for a in "$@"; do args+="    <string>$a</string>\n"; done
  printf '%b' "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
$args  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>${NODE:h}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$DEST/logs/$log.log</string>
  <key>StandardErrorPath</key><string>$DEST/logs/$log.log</string>
</dict>
</plist>
" > "$AGENTS/$label.plist"
}

write_plist local.claudewatch.bridge bridge "$NODE" "$DEST/server.mjs"
write_plist local.claudewatch.tunnel tunnel "$CLOUDFLARED" tunnel --no-autoupdate run --url http://localhost:8787 "$TUNNEL"

for label in $LABELS; do
  launchctl bootstrap "$DOMAIN" "$AGENTS/$label.plist"
done
echo "Installed. Logs are in $DEST/logs."
