#!/usr/bin/env node
// The `wrist-bridge` command (npx wrist-bridge setup). With no arguments it shows help instead of
// starting a second bridge; the installed bridge runs at login.
process.env.WRIST_BRIDGE_CLI = '1';
await import('./server.mjs');
