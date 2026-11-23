#!/bin/zsh
# For a clone of the repository: installs this copy of the bridge, the same as `npx wrist-bridge
# setup` does without pairing. Re-run after editing server.mjs. Remove with: install-agents.sh uninstall
set -euo pipefail
exec node "${0:A:h}/server.mjs" "${1:-install}"
