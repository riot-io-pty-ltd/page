# Contributing to Page

Thanks for considering a contribution. Page is small enough that the bar is
"does this make the product clearly better for someone running their own
agents," and big enough that we'd love help.

## Quick links

- **Bug?** Open an issue with the Bug Report template — include a log
  excerpt from `~/Library/Logs/ClaudePowerMode.log` if relevant.
- **Feature idea?** Open a Discussion or an issue with the Feature Request
  template. We say no to a lot of features; please don't take it personally.
- **Security issue?** **Do not** open a public issue. See [SECURITY.md](SECURITY.md).

## Architecture in 30 seconds

```
 ┌──────────────────────┐         ┌────────────────────────┐         ┌──────────────────┐
 │ Mac menu bar (Swift) │ ──ws──▶ │ Cloudflare Worker      │ ──APNs─▶│ iOS app (SwiftUI)│
 │ Sources/             │         │ Cloudflare/            │         │ iOS/Page/        │
 └──────────────────────┘         │ Durable Object         │         └──────────────────┘
       │   detects                │ + WebSocket relay      │              │
       │   - Claude transcripts   └────────────────────────┘              │
       │   - Codex rollouts                                               │
       │   - rate-limit walls                                             │
       │                                                                 │
       └─────────── injects replies back into terminals ◀─────────────────┘
                    (AppleScript / tmux / `codex exec resume`)
```

Three components, each its own subdirectory. PRs typically touch only one.

## Dev loop

### Mac (Swift)

```sh
swift build               # debug build, fast
./build.sh                # release .app bundle
./install.sh              # builds, signs with first Apple cert, installs LaunchAgent
tail -f ~/Library/Logs/ClaudePowerMode.log
```

The Mac side is a single SwiftPM target (`ClaudePowerMode`, the internal name
predates the rename to Page). Two backends — `ClaudeBackend` and
`CodexBackend` — share an `AgentBackend` protocol. Most new agent work lives
behind that protocol.

### iOS (Xcode)

```sh
cd iOS
xcodegen generate         # regenerates Page.xcodeproj from project.yml
xcodebuild -project Page.xcodeproj -scheme Page -sdk iphonesimulator build
xcrun simctl install <udid> path/to/Page.app
```

XcodeGen is the source of truth — don't edit `Page.xcodeproj` directly.

### Cloudflare Worker (TypeScript)

```sh
cd Cloudflare
npm install
npx wrangler dev          # local dev
npx wrangler deploy       # ship to your own account
```

Set the APNs secrets once (see `Cloudflare/README.md`).

## Code style

- **Swift**: follow the surrounding code. Long descriptive names, comments
  explain *why* not *what*, no SwiftLint config so we're going on taste.
- **TypeScript**: tsc strict, no third-party deps if reasonable.
- **Logging**: be conservative. Page is a long-running daemon — a log line per
  scan tick is a log line per 15 seconds is ~5800 lines per day. Log when state
  changes, not when state is queried.

## Commit messages

Conventional-ish prefixes are nice but not required:

```
feat(codex): rate-limit signal via account/rateLimits/updated
fix(claude): mtime cache was suppressing idle interventions
perf(mac): move Coordinator.tick off the main thread
docs: rewrite README for open source
```

The body should explain the why. The diff already shows the what.

## PRs

- One thing per PR. If you find yourself writing "and also" in the description,
  split it.
- Include a test plan in the PR description, even if it's just "ran `swift
  build` and `xcodebuild`, observed the menu bar updates on idle."
- CI runs `swift build` and `npx tsc --noEmit` on every push. Both must pass.
- Squash-merge by default. We don't preserve work-in-progress commits.

## What we won't take

To keep the project small:

- Bundling other transports (Slack, Discord, email). Page is a phone-app
  product. If you want to bridge to chat, a downstream service can subscribe
  to the Worker's WebSocket.
- Cloud telemetry / analytics SDKs. The whole point is "your prompts stay on
  your devices."
- Heavy dependencies on either side. Swift side is AppKit-only on purpose;
  TypeScript side has only what the Worker runtime ships with.

## License

By contributing, you agree that your contributions are licensed under the
Apache License 2.0 (see [LICENSE](LICENSE)). Submitting a PR implies you
agree to the Developer Certificate of Origin — i.e. you wrote it, or you
have the right to license it under Apache 2.0, and you understand the
project may redistribute it.
