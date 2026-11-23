# Contributing

Issues and pull requests are welcome.

- **Bridge** (`bridge/server.mjs`): one file, Node 18+, no dependencies. Please keep it that way.
  Run `node --check bridge/server.mjs` before sending a change.
- **Watch app** (`ClaudeWatch/`): SwiftUI. Build with the `ClaudeWatch` scheme. Put your own
  signing values in `ClaudeWatch/Local.xcconfig`, never in the project file.
- Never commit `Config.generated.swift`, `Local.xcconfig`, push keys (`*.p8`) or anything from
  `~/.claude-watch`.
- Describe what you tested: on a real watch, or only that it builds.

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) explains how the pieces fit together.
