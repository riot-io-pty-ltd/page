# Page AI Power Control

**Keeps your Mac awake while AI coding agents work, pauses them gracefully at
your battery cutoff, and pages your phone only when they truly need you.
Your reply lands back in the live session.**

Page watches Claude Code and Codex sessions on your Mac. While an agent is
mid-turn, the Mac stays awake (lid closed too, on AC). When the battery runs
low, Page asks busy agents to stop and summarise before the Mac sleeps, and
tells them to carry on when power is back. When an agent is blocked on an
approval, asks a question, or sits idle while you're away, your iPhone gets a
page. Approve, deny or type a reply from the lock screen, and Page delivers it
into the exact session that asked, or tells you why it couldn't.

There are three pieces, all of which you run yourself:

- **The Mac menu-bar app** (Swift/AppKit, `Sources/ClaudePowerMode`). It does
  the detection, keep-awake, battery policy and reply delivery.
- **A relay Worker on your own Cloudflare account** (TypeScript, Durable
  Objects, `Cloudflare/`).
- **The iOS app** (SwiftUI, `iOS/`).

> The Swift target is still called `ClaudePowerMode`, and so are the config
> and log paths, from before the project was renamed. The app bundle, menu and
> LaunchAgent are named Page.

## Contents

- [Features](#features)
- [Getting started](#getting-started)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Safety model](#safety-model)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)
- [Development](#development)

## Features

### Keep-awake driven by real session state

- **Real session status, not CPU guesses.** Claude Code writes
  `~/.claude/sessions/<pid>.json` for each live interactive session, with a
  `status` of `busy`, `waiting` or `idle`. Page reads those files, checks that
  each pid is alive and really is `claude`, and holds a no-idle-sleep
  assertion only while some session is `busy`. Older Claude Code builds
  without a sessions file fall back to recent transcript writes
  (`transcriptActivityWindowSeconds`). Codex state comes from its rollout
  JSONL files.
- **Lid closed on AC, by default.** While agents work on AC power, Page also
  holds a `PreventSystemSleep` assertion so the Mac keeps running with the lid
  shut (`keepAwakeLidClosedOnAC`). macOS honours that assertion on AC only.
- **Lid closed on battery: opt-in, with a watchdog.** Turn on "Keep awake with
  the lid closed on battery" in the menu (or Preferences ▸ Power). The first
  time, macOS asks for your password once so Page can install its power helper
  (the same rule `./install.sh --enable-power-helpers` installs). Page then runs
  `sudo -n pmset -a disablesleep 1`, and only while all of these hold: agents
  are mid-turn, you're on battery, the charge is more than 5 points above your
  cutoff when it turns on (it stays on down to the cutoff, never at or below
  5%), the Mac isn't running hot, and the watchdog is loaded. Page clears the
  flag the moment any condition fails, and also on quit, on SIGTERM and at
  launch. The `local.Page.sleepguard` LaunchAgent clears it within a minute if
  Page dies or stops refreshing its marker for 3 minutes.
- **Holds for pending pages.** A page waiting for your reply keeps the Mac
  awake for up to `holdAwakeForPendingPageMinutes` (60 by default), so the
  reply can still be delivered. This only applies when the relay is on.
- **Rate limits.** When a Claude session hits a usage limit, Page shows the
  reset time and can keep the Mac awake until it passes. Optionally it can
  schedule a system wake a minute before the reset and continue the
  conversation afterwards; see [Rate limits](#rate-limits).

### Low-battery pause and resume

When the battery reaches `lowBatteryCutoff` on battery power, Page does what
you chose in Preferences ▸ Battery:

- **`pause`** (the default) asks busy agents to stop now and reply with a
  two-line summary.
- **`afterTurn`** asks them to finish the current step first. The message is
  queued behind the turn, never an interrupt.
- **`off`** only stops keeping the Mac awake.

Page keeps the Mac awake for `lowBatteryPauseGraceSeconds` (90 by default) so
the agents can write their summary, then lets it sleep. Each paused session
gets one phone page. Carry on resumes it, and a typed reply resumes it with
your text as the instruction. To leave it paused, don't answer (or resume
later from the menu). When power is back (`recoveryThreshold`, and AC if
`recoveryRequiresAC`), Page tells the sessions it paused to carry on. It only
does this for sessions you haven't touched since, and never while you're using
the Mac. Turn `resumeAfterBatteryRecovery` off to resume them yourself from
the menu instead.

How a pause is delivered depends on the terminal:

- tmux, iTerm2 and cmux sessions are interrupted with Esc.
- Terminal.app sessions and `afterTurn` get the message queued.
- Codex sessions with `pause` are interrupted only in tmux and cmux (Esc,
  then the message once the turn has ended). With `afterTurn` the message is
  queued only in cmux, when its composer is empty. Everywhere else Codex
  sessions are skipped, because typing blind into a running Codex turn could
  trigger an approval hotkey.

### Phone pages

| Kind | When | Phone actions |
|---|---|---|
| Approval (`permission`, plus subtype `plan` for plans) | A tool call or plan is waiting for approval | Approve, Deny, Deny with instructions |
| Question | `AskUserQuestion` or another prompt that needs an answer | Typed reply |
| Idle | The turn finished and nothing has been typed for `idlePageDelaySeconds`, while you've been away for `idlePageOnlyWhenAwaySeconds` | Carry on, typed reply |
| Rate limit | A usage limit was hit | Information only |
| Low battery (`idle` + subtype `low_battery`) | Page paused the session at the cutoff | Carry on (resume), Deny (stay paused), typed instructions |

Approvals and questions page at once. Idle and rate-limit pages wait until
you've stepped away.

A session has one current page. A newer page replaces the older one, and
resolving one at the Mac clears its card from the phone. The phone shows
whether each reply was **delivered**, **queued** (the Mac is offline) or
**failed**, with a short reason such as "Approved in tmux pane %3" or
"You have a half-typed message in that pane".

### Phone approvals in every surface (opt-in hooks)

Terminal detection only sees sessions Page can type into. For everything
else, Page installs hooks into the agents' own settings. Use
**menu ▸ Integrations ▸ Install agent hooks…**, which opens the "Phone
Approvals in Every App" window. It shows each agent's status and the exact
diff to `~/.claude/settings.json` and/or `~/.codex/hooks.json`, and asks for
confirmation before writing. It backs up the file as
`<file>.page-backup-<timestamp>` and can uninstall again.

| Hook | Agent | What it does |
|---|---|---|
| `PermissionRequest` (blocking) | Claude Code, Codex | Approve → allow. Deny → deny. A typed reply → deny with your words as the message, so the agent reads it and adjusts |
| `PreToolUse` on `AskUserQuestion\|ExitPlanMode` (blocking) | Claude Code | Answers a multiple-choice question by option number or label (one line per question), or approves a plan / sends it back with feedback |
| `Notification` (fire-and-forget) | Claude Code | Pages only. The Mac app types the reply. It stays quiet while the Mac app's own detector is running |
| `Stop` (blocking, opt-in checkbox) | Codex | While you're away, a typed reply becomes Codex's next prompt. No reply or Deny lets it stop |

Because hooks run wherever the agent runs, this covers:

- Claude Code in any terminal or in cmux;
- local Code sessions in the Claude desktop app;
- the VS Code and JetBrains extensions;
- the Codex CLI.

Anthropic documents hook support for the desktop app and IDE extensions, but
Page hasn't been tested on every one of those surfaces. Whether the Codex
desktop app and IDE extension run `~/.codex/hooks.json` is undocumented.
Codex also asks you to trust new hooks once: open Codex and run `/hooks`, and
again after moving Page.app.

The hooks are **away-only** and **never decide on their own**:

- If you've touched the Mac in the last 120 s (`PAGE_HOOK_ONLY_WHEN_AWAY`),
  the hook steps aside and the normal dialog appears.
- While it waits, touching the Mac hands the prompt back to the dialog.
- A timeout (540 s by default), a dead relay, a missing token, or an answer
  that isn't a decision all print nothing, so the agent shows its own dialog.

The hook script's header
([`hooks/page-notify.sh`](hooks/page-notify.sh)) documents every mode and
environment variable.

### Where replies can be delivered

Page delivers a reply only into the exact terminal that owns the session (see
[Safety model](#safety-model)).

| Host | Claude Code | Codex | Limits |
|---|---|---|---|
| **tmux** (in any terminal app) | ✓ Approve "1", Deny Esc, text with bracketed paste | ✓ Text after the turn ends | Refuses if the pane shows a half-typed draft |
| **Terminal.app** | ✓ via AppleScript, matched by tty | ✓ Text after the turn ends; Return goes through System Events | Claude: Terminal can't send a lone Esc, so Deny types the menu's own "N. No" digit (read from the screen) and questions can't be cancelled. Approve is refused when several tool calls are pending. Codex needs Accessibility permission |
| **iTerm2** | ✓ via AppleScript `write text`, matched by tty | ✗ | Multi-line text is joined into one line |
| **cmux** | ✓ via cmux's own CLI: approvals through cmux's Feed while its hook holds the request, keys only into an open dialog, text only into an empty prompt | ✓ Text into an empty composer | Needs cmux in **Password mode**; see [cmux setup](#5-cmux-setup-optional) |
| Anything else (Ghostty, VS Code's terminal, Warp, …) | ✗ "Page can't type into <App> yet — use tmux or Terminal.app" | ✗ | Run the agent inside tmux, or use the hooks |
| **Session has exited** | Text replies run `claude --resume <id> --print` in the background (`headlessResumeFallbackEnabled`) | `codex exec resume` (the Codex Desktop / VS Code path) | Only when no live process owns the session. Output goes to a log, not a terminal. Approve/Deny are refused |

### Active sessions on your phone

The phone's **Sessions** tab lists every live Claude Code and Codex session
on the Mac (what needs you first, then what's working), shows what each one
is doing as a live transcript, and lets you type into a session or stop it
at any time, not only when a page is open.

- **End-to-end encrypted.** The pairing QR carries a 32-byte session key
  (`sk`). Titles, folders, transcripts and anything you type are sealed with
  it (AES-256-GCM); the relay only forwards opaque envelopes and never
  stores them. Phones paired before this shipped need to scan the QR again.
- **Only while you're looking.** The Mac sends the list only while the app
  is open, and a transcript only for the session on screen. The transcript
  never includes tool output, and every line is redacted before it's cut.
- **Terminal view.** In a session, switch to Terminal to see its screen as
  it is on the Mac, including Claude Code's footer (background workflows,
  shells, sub-agents). tmux and cmux sessions only. It can show tool
  output, so every line is redacted first, and the Mac reads it only while
  that session is open on your phone.
- **Typing goes through the same gate as replies.** Claude Code gets your
  text as a message (Enter), queued behind the current step when it's
  busy, never Esc and never a background resume. Page refuses while a
  prompt is on screen, when the input box isn't empty, when it can't tell
  what the session is doing, and when a busy session's message starts with
  a digit (it could pick a menu option). Codex is typed into once its turn
  ends, or mid-turn only in a cmux pane with an empty composer. **Stop**
  presses Esc in a working session (tmux, iTerm2, cmux).
- **Which sessions can be typed into** follows the table above; the phone
  shows why when one can't. Turn the view off with
  **Preferences ▸ Phone ▸ Show my live sessions on my phone**
  (`remoteSessionsEnabled`). It needs a relay that speaks `sessions-v1`.

### Codex support level

Codex support is real but narrower than Claude's:

| Works | Doesn't |
|---|---|
| Keep-awake while a turn runs (from the rollout files every Codex surface writes) | **Approval prompts aren't detected** by the Mac app, because Codex doesn't write them to the rollout. Use the Codex `PermissionRequest` hook instead |
| Idle pages once a turn ends | Phone Approve/Deny into a live Codex TUI (refused: "Answer Codex approval prompts on your Mac") |
| Replies typed after the turn ends: tmux, Terminal.app, cmux, or `codex exec resume` for Desktop and VS Code | Typing while a turn is running |
| Rate-limit display (from `token_count` snapshots) | Auto-resume after a Codex rate limit |
| Approvals and opt-in Stop continuation through Codex hooks | Proof that the Codex desktop app and IDE extension run hooks (undocumented) |

[`CODEX_INTEGRATION_SPEC.md`](CODEX_INTEGRATION_SPEC.md) has the details. Its
"Current implementation status" section describes what ships; note that its
reply rule 5 predates cmux support for Codex.

### Local and open-weight models

Page keeps the Mac awake while a local model is **generating**, and never just
because one is loaded. It only looks: it never starts, stops or unloads a model.
Turn it off in Preferences ▸ Agents ▸ Local models. Menu ▸ Integrations ▸ Copy
local-model diagnostics shows what it sees.

| What you run | How Page knows it's working |
|---|---|
| Ollama (CLI or app, including `ollama run`) | The model runner's own `/slots` busy flag (exact); GPU time as a fallback |
| llama.cpp `llama-server` (also inside Jan, Msty) | `/slots` (exact) on the port it listens on; GPU time when slots are off or an API key is set |
| LM Studio (its server *and* its in-app chat), MLX (`mlx_lm.*`) | The app's Apple-GPU time (above 25% for two polls) |
| `llama-cli`, `llamafile`, koboldcpp | GPU time, else terminal output |
| Terminal agents on open-weight models: opencode, aider, goose, crush, qwen-code, cline, Kilo, droid, pi, `lms chat` | Output to their terminal in the last 2 minutes (covers tool runs between model calls) |
| Claude Code / Codex pointed at Ollama or LM Studio (`ollama launch claude`, `ANTHROPIC_BASE_URL`, `codex --oss`) | Their normal session state, as for any Claude Code or Codex session |

Notes:

- Estimated signals stop counting after a long unbroken stretch: 3 h for GPU
  time and 90 min for terminal output, until the process goes quiet once.
  Exact `/slots` signals are never capped.
- Local activity keeps an open Mac from idle-sleeping. It does not count
  toward "lid closed on battery", and the low-battery cutoff still lets the
  Mac sleep (sleep freezes local generation, and it carries on after wake).
- Claude Code sessions on a non-Anthropic model are never restarted in the
  background (headless or scheduled resume), because that would run them on
  your Anthropic account. Page needs positive evidence the session ran on
  Anthropic. At the battery cutoff, sessions on local models get Esc only,
  with no summary request, to save the battery.
- GPU time needs Apple silicon. Ollama in Docker and servers on other
  machines aren't detected. The Ollama and LM Studio behaviour is built from
  their documentation and source. The GPU signal was measured on an M3 Pro.

### Rate limits

Page reads Claude Code's rate-limit records, including the structured reset
time when the transcript has it. It shows the limit in the menu and on the
phone, and can hold the Mac awake until the reset (`holdAssertionUntilReset`).

With `autoResumeEnabled` on:

- A session that's still open gets `carryOnPrompt` typed 60 s after the reset,
  but only while you're away.
- An ended session gets a per-session launchd job that runs
  `claude --resume <id> --print "<prompt>"` in the session's launch directory.
  In that headless run, tool calls that need approval are denied. The job
  exits without running if the session is live again.

`wakeViaPmsetEnabled` adds a `pmset schedule wake` one minute before the job
fires. This needs the power helper (Preferences ▸ Power ▸ Install…, or
`--enable-power-helpers`).

## Getting started

Plan on 20–30 minutes the first time.

### Prerequisites

- macOS 12 or later, and Xcode Command Line Tools (`xcode-select --install`)
- A Cloudflare account (the free plan is enough for one person) and
  Node.js ≥ 22.18 for Wrangler and the Worker tests
- For the phone: an iPhone on iOS 17+, Xcode and
  [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- **For push notifications: a paid Apple Developer Program team.** Free Apple
  IDs (Personal Teams) can't get the `aps-environment` entitlement. Without
  push, pages only reach the phone while the Page app is open.
- `jq` and `curl` for the hooks (both ship with recent macOS)

### 1. Deploy your relay Worker

```sh
cd Cloudflare
npm install
npx wrangler login
```

Create an APNs auth key (`.p8`) at developer.apple.com (Keys ▸ + ▸ Apple Push
Notifications service), note its Key ID and your Team ID, then set the
secrets. Pipe the key file, because an interactive paste can keep only its
first line:

```sh
cat AuthKey_XXXXXXXXXX.p8 | npx wrangler secret put APNS_KEY_P8
npx wrangler secret put APNS_KEY_ID      # 10-character Key ID
npx wrangler secret put APNS_TEAM_ID     # 10-character Team ID
```

In `wrangler.toml`, set `APNS_BUNDLE_ID` to your iOS bundle id if you changed
it from `app.page.Page`. Then deploy and check the result:

```sh
npm run deploy             # typecheck + tests, then wrangler deploy
curl https://page-relay.<your-subdomain>.workers.dev/health
# {"ok":true,"service":"page-relay","time":"…","apnsConfigured":true}
```

The relay works without the APNs secrets too, but then it can't reach a
backgrounded phone. [`Cloudflare/README.md`](Cloudflare/README.md) covers the
routes, costs and APNs troubleshooting.

### 2. Install the Mac app

```sh
./install.sh
```

This builds `Page.app`, copies it to `/Applications`, and registers the
`local.Page` LaunchAgent so Page starts at login. It never uses sudo. Signing
uses `CODESIGN_IDENTITY` if set, else the first "Apple Development" identity,
else the first "Developer ID Application" identity, else ad-hoc. A stable
identity keeps macOS permission grants across rebuilds.

| Option | What it does |
|---|---|
| *(none)* | Build, install and (re)launch. No sudo |
| `--enable-power-helpers` | Installs the narrow sudoers rule that scheduled wakes and lid-closed-on-battery need (admin password once); see [SECURITY.md](SECURITY.md) for the exact commands. Old name: `--enable-wake` |
| `--disable-power-helpers` | Stops Page, clears `disablesleep`, removes the rule and the sleep watchdog, then restarts Page. Old name: `--disable-wake` |
| `--install-hook` | Copies the hook into `~/.claude/hooks` and prints the `settings.json` entries to add by hand. It does not edit `settings.json`; the in-app installer is easier |
| `--uninstall [--force]` | Removes the app, the LaunchAgents, scheduled resumes and (with sudo) the rule. It stops if Page's hooks are still installed; remove them in the hook window first, or pass `--force` |
| `--help` | Prints the usage header |

The first time Page types into Terminal.app or iTerm2, macOS asks for
**Automation** permission. Codex delivery through Terminal.app also needs
**Accessibility** permission, to press Return.

### 3. Point the Mac at your Worker

Open the menu-bar icon ▸ **Preferences…** ▸ **Phone**, turn the relay on,
paste your Worker URL (`https://page-relay.<your-subdomain>.workers.dev`) and
click **Test**. The `ws(s)://` and `/ws` forms are normalised to that https
base. Plain `http://` is refused except for `localhost`, `127.0.0.1` and
`[::1]` (local `wrangler dev`), because requests carry your token. The phone's
pairing check refuses `http`/`ws` outright, so a local relay can't be paired
from a phone.

### 4. Build the iOS app and pair

```sh
cd iOS
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set DEVELOPMENT_TEAM
# paid team, for push: PAGE_ENTITLEMENTS = Page/Page-Push.entitlements
xcodegen generate
open Page.xcodeproj
```

Build to your iPhone. On the Mac, choose **Pair phone…** from the menu. It
refuses while the relay is off, or its URL is unset, invalid or still the
placeholder. Scan the QR in
the app's Pair screen. The QR holds `{v, token, relay, host}`, and the phone
checks the relay's `/health` before adopting it.

[`iOS/README.md`](iOS/README.md) has signing details, push setup and the
development shortcuts.

**The QR code is your credential.** Anyone who has the token can read your
pages and send replies. If it leaks, use **Regenerate token…** in the pairing
window. The old token is retired on the Worker, and phones paired with it are
told to re-pair.

### 5. cmux setup (optional)

cmux's default socket mode only accepts processes cmux started itself, so it
refuses Page. Phone replies to cmux sessions then fail with
"cmux blocks Page — open Page ▸ Integrations ▸ Set up cmux…". To fix it:

1. In cmux, open Settings ▸ Automation ▸ Socket Control Mode and choose
   **Password mode**. Under Socket Password, click Set.
2. In Page, open **Integrations ▸ Set up cmux…**, enter the same password,
   click **Save** (it's stored in your login Keychain), then
   **Test connection**.
3. Optional: in cmux, turn off Settings ▸ Notifications ▸ "Forward
   notifications to my iPhone", so each prompt reaches you once.

Page drives cmux only through the `cmux` CLI bundled inside cmux.app. It
passes the password to that CLI only after checking the CLI's code signature
against cmux's Team ID. Page contains no cmux code.

### 6. Phone approvals everywhere (optional)

Open **Integrations ▸ Install agent hooks…**, review the diff and click
Install. For Codex, run `/hooks` once inside Codex to trust the hook.

To set this up by hand instead, `./install.sh --install-hook` prints the
entries. Blocking entries need `"timeout": 570`; the hook's own wait ends at
least 30 s before that.

## Configuration

Settings live in
`~/Library/Application Support/ClaudePowerMode/config.json`. Most of them can
be set in **Preferences…**, which has Phone, Power, Battery, Agents and Rate
limits tabs and writes only the fields you change. Hand edits are fine:

- Each key is decoded on its own, so a mistyped value falls back to its
  default and is reported in the menu.
- An unparseable file is copied to `config.json.bad-<timestamp>` and never
  overwritten.
- Out-of-range values are clamped.

Apply hand edits with **Reload Config** in the menu.

| Key | Default | Meaning |
|---|---|---|
| `relayEnabled` | `false` | Master switch for phone pages and replies |
| `relayURL` | placeholder (`https://your-page-relay.workers.dev`, treated as unset) | Your Worker's https base URL. ws/wss and a trailing `/ws` are normalised; http only for localhost |
| `interventionDetectionEnabled` | `true` | Detect approvals, questions and idle sessions and page them |
| `idlePageDelaySeconds` | `60` (0–3600) | How long a session must sit idle (turn finished, nothing typed) before it pages |
| `idlePageOnlyWhenAwaySeconds` | `120` (0–3600) | Hold idle and rate-limit pages while you've used the Mac within this many seconds. `0` disables the check. Approvals and questions always page |
| `holdAwakeForPendingPageMinutes` | `60` (0–1440) | Keep the Mac awake this long while a page waits for a reply (relay on only). `0` = don't hold |
| `headlessResumeFallbackEnabled` | `true` | When the session's process has exited, deliver a text reply with `claude --resume --print` / `codex exec resume`. Never used while the session is still running |
| `remoteSessionsEnabled` | `true` | Show live sessions on the paired phone (end-to-end encrypted) and let it type into them or stop them. See [Active sessions on your phone](#active-sessions-on-your-phone) |
| `keepAwakeLidClosedOnAC` | `true` | While agents work on AC, also hold `PreventSystemSleep` so the lid can be closed |
| `keepAwakeLidClosedOnBattery` | `false` | Opt-in lid-closed-on-battery via `pmset disablesleep`. Needs the power helper (installed from the app, or `--enable-power-helpers`) |
| `lowBatteryCutoff` | `10` (0–100) | Battery % (on battery power) at which Page pauses agents and stops keeping the Mac awake |
| `lowBatteryAction` | `"pause"` | `pause` (interrupt and summarise), `afterTurn` (finish the step, then summarise), or `off` (don't message the agents, just let the Mac sleep) |
| `lowBatteryPauseGraceSeconds` | `90` (15–600) | How long to stay awake after the pause so the agents can write their summary |
| `recoveryThreshold` | `25` (0–100, ≥ cutoff) | Battery % at which power counts as back. Without `recoveryRequiresAC` it must be above the cutoff |
| `recoveryRequiresAC` | `true` | Power counts as back only when plugged in |
| `resumeAfterBatteryRecovery` | `true` | When power is back, tell the sessions Page paused to carry on (sessions you haven't touched, while you're away) |
| `checkIntervalSeconds` | `15` (2–600) | Main tick interval |
| `claudeProcessPattern` | `"claude"` | Process-name pattern for Claude processes |
| `excludePatterns` | `["ClaudePowerMode"]` | Command-line substrings that disqualify a process from counting as Claude |
| `requireRecentTranscriptActivity` | `true` | For sessions without a sessions-file status, count them as working only if their transcript was written recently |
| `transcriptActivityWindowSeconds` | `90` (5–3600) | "Recently" for the check above. Also Codex's activity window |
| `transcriptDirectory` | `"~/.claude/projects"` | Where Claude Code transcripts live |
| `rateLimitWatcherEnabled` | `true` | Watch Claude transcripts for usage limits |
| `holdAssertionUntilReset` | `true` | Keep the Mac awake while a rate limit is active |
| `autoResumeEnabled` | `false` | After a Claude rate limit resets, continue the conversation (see [Rate limits](#rate-limits)) |
| `carryOnPrompt` | `"carry on"` | The prompt used for that auto-resume |
| `wakeViaPmsetEnabled` | `false` | Schedule a system wake before a scheduled resume. Needs the power helper |
| `codexBackendEnabled` | `false` | Watch Codex sessions as well |
| `codexPath` | `""` | Absolute path to `codex`. Empty = auto-discover (`~/.local/bin`, Homebrew, `/usr/local/bin`, npm-global, nvm) |

The hook reads its own environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `PAGE_RELAY_URL` | `relayURL` from config.json, when `relayEnabled` is true | Override the Worker URL |
| `PAGE_HOOK_ONLY_WHEN_AWAY` | `120` | Seconds without keyboard or mouse input before a blocking hook pages. `0` = always |
| `PAGE_HOOK_TIMEOUT` | `540` (5–3600) | How long a blocking hook waits for the phone, never past the agent's timeout minus 30 s |
| `PAGE_HOOK_PRINT` | unset | `1` also pages from non-interactive `claude -p` runs |
| `PAGE_HOOK_SKIP` | unset | `1` makes the hook do nothing for that run |
| `PAGE_HOOK_AUTO` | unset | Legacy generic PreToolUse installs only: `allow`, `deny` or `ask` skips the phone and returns that decision |
| `PAGE_CONTEXT_TOOL_OUTPUT` | unset | `1` includes short tool-output excerpts in the page (off by default: tool output is where secrets live) |
| `PAGE_HOOK_LOG` | `~/Library/Logs/page-hook.log` | Hook log (0600, rotated at 1 MB; never contains the token) |

Other files in `~/Library/Application Support/ClaudePowerMode/`:

- `relay_token.txt` (0600): the pairing token.
- `detector.alive`: tells the Notification hook the Mac app is paging.
- `hook-holds/`: markers left by blocking hooks.
- `battery-paused.json`.
- `disablesleep.active`: marker while lid-closed-on-battery is on.
- `scheduled/`: rate-limit resume jobs.

## How it works

```
  Your Mac                                   Your Cloudflare account          Apple        Your iPhone
 ┌──────────────────────────────────────┐   ┌──────────────────────────┐
 │ Page.app (menu bar, LaunchAgent)     │   │ Worker  /health, auth    │
 │                                      │   │   │                      │
 │  ClaudeBackend ─┐                    │   │   ▼  one Durable Object  │   ┌──────┐   ┌──────────────┐
 │   ~/.claude/sessions, transcripts    │   │      per relay token     │──▶│ APNs │──▶│ Page (iOS)   │
 │  CodexBackend ──┼─▶ Coordinator ──▶ one shared RelayClient ══ wss ══▶│   └──────┘   │ lock-screen  │
 │   app-server child + rollouts        │   │  p:  pending pages       │              │ actions,     │
 │  BatteryPolicy, PowerManager,        │   │  h:  history (300)       │◀══ wss ═════▶│ inbox, reply │
 │   SleepGuard                         │   │  q:  reply queue (1 h)   │◀── HTTPS ────│ POST /reply  │
 │       ▲                              │   │  dev: phones, tomb:      │              └──────────────┘
 │       │ reply frames ◀───────────────┼═══│  presence (heartbeats)   │
 │  InjectionExecutor / CodexInjector   │   └──────────────────────────┘
 │   → tmux · Terminal.app · iTerm2 ·   │                ▲
 │     cmux · headless resume           │                │ HTTPS POST /intervention, GET poll
 │       │ reply.injected (delivered/   │                │
 │       │ failed + short detail)       │   ┌────────────┴─────────────┐
 └───────┼──────────────────────────────┘   │ hooks/page-notify.sh     │  run by Claude Code /
         ▼                                  │ (PermissionRequest,      │  Codex in any surface
   the agent's terminal                     │  PreToolUse, Notification│
                                            │  Stop)                   │
                                            └──────────────────────────┘
```

**Mac.** The `Coordinator` ticks every `checkIntervalSeconds` on a background
queue. Each tick:

1. Every enabled backend reports its sessions.
2. Power policy decides which assertions to hold, whether
   `disablesleep` may be on, and whether the battery has tripped.
3. New pages go to the relay.

The Coordinator owns a **single shared RelayClient**: one WebSocket per Mac
with User-Agent `page-mac/…`. On connect the client sends a heartbeat, then
one `sync` frame per backend listing the pages that are really still open.
After that it sends heartbeats every 15 s and `sync` every 60 s. An offline
outbound queue coalesces frames until the socket is back.

**Replies.** Each reply carries `backend`, so the Coordinator routes it to
that backend's serial queue. The backend re-reads the session state, resolves
the exact terminal, delivers the reply, then reports `reply.injected` with
`success` and a short phone-safe `detail`. On success it closes the page with
reason `replied`.

**Worker.** Every request is authenticated by `Authorization: Bearer <relay
token>`. Each token maps to its own Durable Object. The Object stores each
record under its own key (pending pages, history capped at 300, a reply queue,
phones, closed-id tombstones), so no single value can outgrow the storage
limit. The Worker applies these rules:

- A newer page supersedes the session's older one.
- Resolving a page closes the session's other pages.
- `sync` closes pages the Mac no longer has.
- A reply that's already in flight gets 409.
- A reply to a page that has moved on gets 410.

Replies wait in the queue for up to an hour while the Mac is offline. If one
can't be delivered, the phone is told. The Worker tracks Mac presence from
heartbeats and socket state and serves it at `GET /status`.

**Hooks.** The hook script is a second relay client. It POSTs pages to the
Worker over HTTPS and polls for your answer. Blocking-hook pages (`hookpre-`
ids) are never forwarded to the Mac: the waiting hook reads the reply and
prints the decision. While a hook holds a session, the Mac detector doesn't
page the same prompt again, and the Worker sends the duplicate quietly or not
at all.

[`docs/PROTOCOL.md`](docs/PROTOCOL.md) specifies every frame, route, status
code and push payload.

## Safety model

Typing into someone's terminal is the dangerous part. These rules are
enforced in code and covered by tests:

- **Exact target or nothing.** The reply's session id resolves to a live pid,
  then to that pid's tty, then to the tmux pane, Terminal/iTerm2 tab or cmux
  surface on that tty. If any step is ambiguous, delivery fails with a reason.
  Page never guesses, never falls back to "any claude process", never uses the
  reply payload's `cwd`, and never uses System Events keystrokes aimed at
  whichever app is frontmost. (One exception: the Codex Terminal.app Return
  goes through System Events, but only after checking that Terminal is
  frontmost with the right tab selected.) A session that's stopped (^Z),
  running in the background, or behind another job in its terminal is refused.
- **Status-aware keystrokes.** The keys depend on the session's live status,
  re-read before every key:
  - `waiting` (a prompt is on screen): Approve sends `1` with no Enter. Deny
    sends Esc. Text sends Esc, waits until the prompt has actually closed, then
    types the text and Enter.
  - `idle`: text and Enter.
  - `busy`: text and Enter, which Claude queues. Approve/Deny are refused,
    because "the prompt is no longer showing".
- **No Enter on a menu, and no digit is assumed to mean "No".** Claude's
  permission menu ignores letters, and Enter accepts the highlighted "Yes". So
  "no, stop" followed by Enter would *approve*. Page doesn't send text and
  Enter while a prompt is showing.
  - Everywhere except Terminal.app, Deny is a lone Esc.
  - Page never sends a fixed `2`, which means "Yes, and don't ask again" on
    three-option prompts.
  - **Terminal.app is the one exception.** AppleScript `do script` always
    appends a Return. Deny there types the digit that the visible menu labels
    "No", and refuses unless exactly one such line is found. The single menu
    digit (that one, or `1` for Approve) closes the menu before the Return
    arrives, so the Return lands on the empty input. Approve is refused when
    another menu could be queued behind the current one.
- **Stale answers are refused.**
  - An approval aimed at a prompt that has since been replaced is refused.
    Pages carry the prompt's tool-use id (`promptKey`) where it's known.
  - A decision sent to a closed page gets 410 from the Worker.
  - Free text to a page that closed in the last 10 minutes is typed only into
    an idle or busy session, never into a prompt.
  - An empty reply is never turned into "carry on".
- **No drafts overwritten.** Text isn't typed over a half-written message in
  tmux or cmux.
- **Text is sanitised.** Control characters are stripped. A leading `!`
  (Claude's bash mode) gets a space in front. Multi-line text uses bracketed
  paste. All injections run on one serial queue.
- **Fail closed.** Unknown status, an unreadable screen, an unexpected menu
  layout or a missing permission all mean "not delivered, here's why". The
  phone shows the reason and lets you retry.
- **Hooks are away-only and never auto-decide.** A decision is printed only
  for an explicit phone answer. Every error, timeout, or sign that you're back
  at the Mac hands the prompt to the agent's own dialog. The one exception is
  the legacy opt-in `PAGE_HOOK_AUTO`; see [SECURITY.md](SECURITY.md).
- **Headless resume only for ended sessions.** `claude --resume --print` runs
  only when no process, cmux record or recent transcript write suggests the
  session is still alive.

## Privacy and where your data goes

Page has no account, no analytics and no third-party SDKs. But a page has to
travel, so "nothing leaves your devices" isn't true. What leaves your devices:

- **To your Cloudflare Worker.** Each page carries the session id, project
  name, working directory and up to 4000 characters of context: the command,
  diff or question, plus recent activity. Your replies go there too. The
  Worker keeps pending pages, the last 300 closed pages (with their context
  and your reply text) and queued replies. [SECURITY.md](SECURITY.md) lists
  what is stored and for how long.
- **Live sessions (Sessions tab).** Session titles, folders, transcripts and
  what you type there are end-to-end encrypted with the pairing's session
  key. The Worker forwards them while the app is open and stores none of
  it; it sees only frame types, sizes and timing.
- **To Apple's push service (APNs).** Each push carries the project name, the
  session id, the page kind and up to 180 characters of the context as the
  notification body.
- **Redaction.** Before context leaves the Mac, Page masks common secret
  shapes: `KEY=value` with secret-like names, bearer and basic credentials,
  PEM blocks, `user:pass@` in URLs, and `sk-`, `ghp_`, `github_pat_`, `xox*`,
  `AKIA` and `AIza` keys. The hook leaves tool output out by default.
  Redaction is best-effort pattern matching. Assume anything on your screen
  can reach your Worker.

## Troubleshooting

| Symptom | Check |
|---|---|
| Menu says the relay is off or misconfigured | Preferences ▸ Phone: relay on, URL valid, **Test** passes. The placeholder URL counts as unset |
| No pushes, but the app shows pages when open | `curl <worker>/health` → `apnsConfigured`. With your token, `GET /status` shows `devices` and `lastPushError`. Push needs a paid team and `Page-Push.entitlements`. See the [Worker troubleshooting](Cloudflare/README.md#troubleshooting) |
| Phone says the Mac is offline | The menu shows the relay state. The Mac reconnects after wake. `GET /status` → `macConnected`, `lastHeartbeatAt` |
| Phone says no Mac has ever connected with this pairing | You scanned an old QR, or regenerated the token. Pair again |
| Everything answers 410 `token_retired` | The token was regenerated on the Mac. Scan the new QR |
| "Page can't type into <App> yet" | That terminal isn't supported. Run the agent in tmux, or install the hooks |
| "cmux blocks Page" | Follow [cmux setup](#5-cmux-setup-optional) |
| "Session is now waiting for approval — open the new page" / "The prompt is no longer showing" | The session moved on before your reply arrived; answer the newer page |
| "You have a half-typed message in that pane" | Clear the draft at the Mac, or answer there |
| Terminal.app: "can't press Esc — deny this one at the Mac" | Terminal.app can't send a lone Esc; use tmux or iTerm2 for remote denies |
| Codex reply refused "still working" | Codex replies are typed only after the turn ends |
| Hook never pages | The hook pages only after 120 s with no input at the Mac. Check `~/Library/Logs/page-hook.log`. For Codex, run `/hooks` to trust the hook |
| Lid-closed-on-battery won't turn on | Preferences ▸ Power shows whether the sudo helper and watchdog are installed. It needs a charge more than 5 points above your cutoff and agents mid-turn |
| Mac won't sleep after Page quit | `pmset -g` shows `SleepDisabled`; run `sudo pmset -a disablesleep 0`. The menu warns when a clear fails |
| config.json edits ignored | The menu shows a config problem. Look for `config.json.bad-<timestamp>` |

Logs:

- `~/Library/Logs/ClaudePowerMode.log`: the app, rotated at 5 MB, tokens
  redacted.
- `~/Library/Logs/page-hook.log`: the hook.
- `~/Library/Logs/ClaudePowerMode-resumes/`: headless Claude runs.
- `~/Library/Logs/Page-codex-replies/`: `codex exec resume` runs.
- `npx wrangler tail`: the Worker.

## Project layout

```
.
├── Sources/ClaudePowerMode/     Mac menu-bar app (single SwiftPM executable target)
│   ├── Backends/                AgentBackend protocol, ClaudeBackend, CodexBackend
│   ├── Codex/                   codex app-server JSON-RPC client, CodexInjector
│   ├── Coordinator.swift        tick loop, shared relay, sync, battery effects
│   ├── ClaudeSessionRegistry.swift  ~/.claude/sessions reader
│   ├── InterventionDetector.swift   page decisions + ContextRedactor
│   ├── InjectionExecutor.swift      Claude reply delivery (tmux/Terminal/iTerm2/cmux/headless)
│   ├── CmuxBridge.swift         cmux CLI transport (+ CmuxSetupWindow)
│   ├── HookInstaller.swift      settings.json / hooks.json merge (+ HookInstallerWindow)
│   ├── PowerManager.swift, PowerBatteryPolicy.swift, SleepGuard.swift
│   ├── RateLimitWatcher.swift, TranscriptParser.swift, ResumeScheduler.swift
│   └── RelayClient.swift, PairingTokenManager.swift, ProcessRunner.swift, …
├── Tests/ClaudePowerModeTests/  XCTest suites for the Mac app (`swift test`)
├── Cloudflare/                  relay Worker + Durable Object (see its README)
│   ├── src/                     index.ts, durable.ts, logic.ts (pure), apns.ts, types.ts
│   └── test/                    node:test suites, incl. an end-to-end hook test
├── iOS/                         iOS app (see its README)
│   ├── Page/                    SwiftUI sources (Models/ is Foundation-only, testable)
│   ├── Tests/                   logic tests (run-logic-tests.sh)
│   ├── Config/                  xcconfig + Local.xcconfig.example
│   └── project.yml              XcodeGen spec (edit this, not the .xcodeproj)
├── hooks/                       page-notify.sh + page-extract-context.py (bundled into Page.app)
├── docs/                        PROTOCOL.md (wire protocol), ROADMAP.md
├── Tools/                       icon generator, parser test pointer
├── Resources/                   Mac app icon and entitlements
├── Designs/                     Pencil design sources
├── website/                     project website
├── build.sh                     build + sign Page.app
├── install.sh                   install / power helpers / hooks / uninstall
└── CODEX_INTEGRATION_SPEC.md    Codex design notes and current status
```

## Development

```sh
swift build                         # Mac app, debug
swift test                          # Mac unit tests (XCTest)
(cd Cloudflare && npm test)         # Worker tests (node:test, Node ≥ 22.18), incl. the hook end to end
(cd Cloudflare && npm run typecheck)
./iOS/Tests/run-logic-tests.sh      # iOS model/logic tests, no simulator needed
bash -n hooks/page-notify.sh
```

**Never test reply delivery against real agent sessions.** Use a private tmux
server (`tmux -L page-test …`) running `cat`. [CONTRIBUTING.md](CONTRIBUTING.md)
has the dev loop and the rules for contributors.
[docs/ROADMAP.md](docs/ROADMAP.md) covers where the project is heading.

## Contributing, security, license

- PRs are welcome: read [CONTRIBUTING.md](CONTRIBUTING.md).
- Found a vulnerability? Don't open a public issue; see
  [SECURITY.md](SECURITY.md).
- Code of conduct: [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

Page builds on Anthropic's Claude Code, OpenAI's Codex, Cloudflare Workers and
Durable Objects, and XcodeGen.

[Apache License 2.0](LICENSE). The "Page" name and the Pulse mark are project
trademarks; see [NOTICE](NOTICE).
