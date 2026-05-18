# Page

**An on-call interface for AI coding agents.**

When Claude, Codex, or another AI coding agent stops mid-task and needs a
human decision — an approval prompt, a question, a session sitting idle —
Page lands a notification on your phone. Reply from anywhere; your answer
goes straight back into the live session.

> Run agents while you're not at your desk. Page keeps your Mac awake,
> watches your battery, weathers rate limits, and tags you in only when
> your agents truly need a human.

Three pieces:

```
 ┌──────────────────────┐         ┌────────────────────────┐         ┌──────────────────┐
 │ Mac menu bar app     │ ──ws──▶ │ Cloudflare Worker      │ ──APNs─▶│ iOS app          │
 │ (Swift, AppKit)      │         │ (Durable Object)       │         │ (SwiftUI)        │
 └──────────────────────┘         │ /Cloudflare            │         │ /iOS/Page        │
       │ detects                  └────────────────────────┘              │
       │ - Claude transcripts                                             │
       │ - Codex rollouts                                                 │
       │ - rate-limit walls                                               │
       │                                                                  │
       └────── injects replies back into the live session ◀────────────────┘
              (AppleScript / tmux / `codex exec resume`)
```

## Features

- **Multi-agent.** Works with Claude Code, Codex CLI, Codex Desktop, and
  Codex in VS Code today. Built around a backend abstraction so new agents
  drop in cleanly.
- **Detects four kinds of "needs you":** approval requests, user-input
  questions, idle waiting after a turn completes, and rate-limit walls.
- **Replies land where you typed:** AppleScript into Terminal.app, tmux
  send-keys, or `codex exec resume` for non-TTY surfaces like Desktop.
- **Power-aware:** holds a no-sleep assertion while agents are mid-turn,
  releases it the moment they idle. Configurable battery cutoff.
- **Local-first:** prompts and replies never leave your devices and your
  own Cloudflare Worker. No account, no analytics, no third-party SDKs.
- **Survives rate limits:** schedules a system wake 30 seconds before
  your quota refills; optionally auto-resumes the conversation.

## Getting started

Page has three components that you'll set up in order. Plan for ~15 minutes
the first time.

### Prerequisites

- macOS 12 or later
- Xcode Command Line Tools (`xcode-select --install`)
- An Apple Developer account *or* a free Apple ID (for code-signing the
  Mac app and APNs)
- A Cloudflare account (Workers free tier is plenty)
- Node.js 18+ (for Wrangler)
- An iPhone running iOS 17+ (optional but recommended)

### 1. Deploy your own relay Worker

```sh
cd Cloudflare
npm install
npx wrangler login
npx wrangler deploy
```

Then set the APNs secrets (one-time, see `Cloudflare/README.md` for how to
generate the key):

```sh
npx wrangler secret put APNS_KEY_P8         # paste the .p8 file contents
npx wrangler secret put APNS_KEY_ID         # 10-char key id
npx wrangler secret put APNS_TEAM_ID        # 10-char team id
```

Note the deploy URL Wrangler prints (something like
`https://page-relay.<your-subdomain>.workers.dev`). You'll plug it into the
Mac config in step 2.

### 2. Install the Mac app

```sh
./install.sh
```

`install.sh` builds, signs with the first Apple Developer identity in your
keychain, copies the app to `/Applications/Page.app`, and registers a
LaunchAgent so it starts at login.

Then point it at your Worker:

```sh
# Edit ~/Library/Application Support/ClaudePowerMode/config.json:
{
  "relayURL": "https://page-relay.<your-subdomain>.workers.dev",
  "relayEnabled": true,
  "codexBackendEnabled": true
}
```

Click the menu bar icon → **Reload config**. The relay client should
connect (you'll see `RelayClient connected` in
`~/Library/Logs/ClaudePowerMode.log`).

The first time Page tries to type into Terminal or press Return for Codex,
macOS will prompt for **Automation** and **Accessibility** permissions.
Grant both once — they persist across rebuilds because we sign with your
stable Apple cert.

### 3. Build and pair the iOS app

```sh
cd iOS
xcodegen generate
open Page.xcodeproj
```

In Xcode: set your signing team on the `Page` target, build for your
device or the simulator, run.

In the app: tap "Pair Mac." On the Mac, click the menu bar icon → **Pair
phone…** to display the QR. Point the phone's camera at the QR. The phone
now knows your Worker URL and the shared pairing token.

You're done. Start a Claude or Codex session, walk away, get paged.

## Configuration

All Mac-side config lives at
`~/Library/Application Support/ClaudePowerMode/config.json`. The most
useful keys:

| Key | Default | What it does |
|---|---|---|
| `relayURL` | placeholder | Your Cloudflare Worker URL |
| `relayEnabled` | `false` | Master switch for phone push |
| `codexBackendEnabled` | `false` | Watch Codex sessions alongside Claude |
| `lowBatteryCutoff` | `10` | Stop boosting below this % |
| `recoveryThreshold` | `25` | Resume boosting at this % |
| `recoveryRequiresAC` | `true` | Resume only when plugged in |
| `autoResumeEnabled` | `false` | After rate-limit reset, auto-`claude --resume` |
| `wakeViaPmsetEnabled` | `false` | Schedule system wake for rate-limit reset |
| `holdAssertionUntilReset` | `true` | Keep Mac awake through rate-limit windows |
| `interventionDetectionEnabled` | `true` | Watch transcripts for idle/permission states |
| `checkIntervalSeconds` | `15` | How often the coordinator ticks |

Apply changes with **Reload config** in the menu bar, or restart the
LaunchAgent.

## How it works

### Mac side

A Swift menu-bar app that runs as a LaunchAgent. The `Coordinator` ticks
every 15 seconds on a background queue. Each tick:

1. Asks each `AgentBackend` (Claude, Codex) for a snapshot of its current
   state.
2. Holds or releases the no-sleep assertion based on aggregate state.
3. Pushes new interventions to the Worker over WebSocket.

`ClaudeBackend` watches `~/.claude/projects/*.jsonl` for new transcript
activity and infers idle/permission states. `CodexBackend` spawns a
`codex app-server` child to discover threads, then tails the rollout JSONL
files for those threads to detect `task_complete`-then-quiet.

Replies coming back from the phone are dispatched per backend by
intervention-ID prefix (`codex-*` → Codex, everything else → Claude) and
injected via tmux send-keys, AppleScript into Terminal.app, or
`codex exec resume` for non-TTY surfaces.

### Worker

A single Cloudflare Durable Object per relay token. Holds:

- Pending interventions (newest wins per session id)
- A 500-entry history of resolved ones
- One queued reply per intervention if the Mac is offline

Routes:

- `POST /intervention` — Mac sends `intervention.opened/closed`, heartbeats
- `GET /interventions` — phone fetches the inbox
- `GET /history` — phone fetches recent history
- `POST /reply/<id>` — phone sends a reply (queued if Mac is offline)
- `WS /ws` — bidirectional live updates

### iOS app

SwiftUI app. On launch it connects to the Worker over wss, fetches the
inbox, and listens for live `intervention.opened/closed/heartbeat` frames.

Replies go via `POST /reply/<id>`. The Worker stores the reply, then
broadcasts it to every Mac socket; each Mac backend filters by intervention
ID prefix and the right one injects.

## Project layout

```
.
├── Sources/ClaudePowerMode/   # Mac menu bar app (Swift)
│   ├── Backends/              # Per-agent backend implementations
│   ├── Codex/                 # app-server protocol client
│   └── ...
├── Cloudflare/                # Worker + Durable Object (TypeScript)
│   └── src/
├── iOS/                       # iOS app
│   ├── Page/                  # SwiftUI sources
│   └── project.yml            # XcodeGen spec (edit this, not the xcodeproj)
├── Resources/                 # Mac app icon
├── Designs/                   # Pencil source files for app + website
├── hooks/                     # PreToolUse hook for Claude Code
├── build.sh                   # Build the .app bundle
├── install.sh                 # Build + sign + install + LaunchAgent
└── CODEX_INTEGRATION_SPEC.md  # Design notes for the Codex integration
```

## Contributing

PRs welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) for the bar, dev loop,
and what we won't take.

## Security

Found a vulnerability? Please don't open a public issue — see
[SECURITY.md](SECURITY.md).

## Acknowledgements

Page was built on top of a lot of other people's work:

- Anthropic's Claude Code
- OpenAI's Codex
- Cloudflare Workers + Durable Objects
- The XcodeGen project, which makes the iOS project setup readable

## License

[Apache License 2.0](LICENSE). Use it, fork it, ship it. The "Page" name and
the Pulse mark are project trademarks — see [NOTICE](NOTICE).
