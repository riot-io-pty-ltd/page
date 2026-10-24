# Codex Integration Spec

## Purpose

Define how Claude Power Mode and Page should support Codex sessions without
forking the product into separate Claude and Codex implementations.

This document covers:

- the target architecture
- why Codex app-server is the preferred control plane
- how existing Claude-specific components map to a backend abstraction
- the rollout plan, risks, and open questions

This is a design and implementation spec only. It does not change runtime
behavior by itself.

## Current implementation status (October 2026)

Read this section first. The rest of this document is the original design.
Where the two disagree, this section describes what actually ships.

### Why the shipped design differs from the plan

The plan assumed Page's own `codex app-server` child could watch and steer
the user's sessions. It can't. Each Codex surface (the CLI TUI, Codex Desktop,
the VS Code extension) embeds its own app-server. A separately spawned child
can list every thread on disk (`thread/list`, `thread/read`), but it never
receives `turn/*`, `thread/status/changed` or approval requests for turns
that another process drives. `thread/read` does not subscribe the child to
another process's live thread.

The one signal every surface shares is the rollout JSONL file each session
appends to. So the shipped backend uses the app-server for discovery and the
rollout files for live state.

### What works

| Capability | How | Surfaces |
|---|---|---|
| Discovery | `thread/list` through Page's app-server child. It requests `sortKey: "updated_at"`, `sortDirection: "desc"` (dropped after an RPC error on older servers) and follows `nextCursor` for up to 4 pages of 50. Pages are merged and deduplicated by id. Sub-agent threads are skipped. | all |
| Which threads count | A thread is watched if it was updated in the last 30 min, or it has an open idle page, or it is the newest thread in a directory where a live interactive `codex` process runs. Older threads in the same directory are history and are ignored. | all |
| Keep-awake | State is re-derived from the rollout tail on every tick. In a turn (`task_started`/`response_item` after the last `task_complete`/`turn_aborted`) means active, for up to 15 min without writes. A turn that has been silent longer counts as stalled and stops holding power. After the turn ends the session is idle. Pending pages also hold power, but only for `holdAwakeForPendingPageMinutes`. | all |
| Idle pages | The latest turn ended with `task_complete`, at least `idlePageDelaySeconds` ago and at most 4h ago. The page is held back while the user is at the Mac (`idlePageOnlyWhenAwaySeconds`). Its id is `codex-idle-<threadId>-<task_complete epoch>`, keyed on the turn end rather than the file mtime, because `thread_settings_applied` can be written after `task_complete`. Some sessions never page: aborted turns (the user hit Esc), `codex exec` threads, and terminal sessions whose `codex` process has exited. | all |
| Rate limits | The `rate_limits` snapshot in rollout `token_count` events (snake_case) and `account/rateLimits/updated` (camelCase, nested under `rateLimits`). Limited means either window has `usedPercent >= 100` or `rateLimitReachedType` is set. The limit clears when a newer snapshot shows it isn't limited, or when `resetsAt` passes. It is reported once per limit, tagged `backend: .codex` and attributed to "Codex account". It is never auto-resumed. | all |
| Replies | `Codex/CodexInjector.swift`, and only when the thread's latest turn has ended (see below). | CLI in tmux or Terminal.app; Desktop and VS Code through exec resume |
| Approvals arriving at Page's own child | Correctly classified as JSON-RPC server requests (id + method). `item/commandExecution/requestApproval` and `item/fileChange/requestApproval` become `.permission` pages and are answered with `{decision: "accept" \| "decline"}`. Every other server request (for example `item/tool/requestUserInput`) gets a `-32601` reply so the server never blocks. This only fires if a turn runs against Page's child, which doesn't happen today. | none in practice |

### What does not work, and why

- **Codex approval prompts are not detected** for CLI, Desktop or VS Code
  sessions. Codex does not persist approval requests to the rollout: across
  every local rollout inspected there are no `*_approval_request` events. A
  session blocked on an approval looks mid-turn, so it shows as active for
  15 min and then as stalled. A heuristic such as "tool call without output,
  quiet for N seconds" was rejected. It fires on every long-running command,
  and it would put Approve buttons on the phone that Page can't honour safely.
  The parser does recognise `exec_approval_request`,
  `apply_patch_approval_request` and `request_user_input` if a future Codex
  persists them, but it only uses them for session state, not pages.
- **Phone Approve/Deny for a live Codex TUI** is refused with "Answer Codex
  approval prompts on your Mac". The TUI's approval keystrokes are unverified,
  and letters typed into an approval overlay act as hotkeys.

### Reply safety rules (CodexInjector + CodexBackend.replyPlan)

1. Text is typed only if the latest turn-relevant rollout line is
   `task_complete` or `turn_aborted`. Mid-turn the reply is refused ("Codex is
   still working — reply once the turn finishes"), and so is an unknown phase.
2. Targeting is exact or it fails. The target is the codex process holding the
   thread's rollout open (when `lsof` shows it), else the single interactive
   codex whose cwd matches. Processes are grouped by tty, because the Node
   wrapper and the native binary share one. Two terminals means the reply is
   refused as ambiguous.
3. tmux: the pane whose `#{pane_tty}` is that tty gets `send-keys -l` (or a
   bracketed `paste-buffer -p` for multi-line text). Page then waits 0.4s,
   because Codex folds an Enter that arrives inside a paste burst into the
   text, and sends an `Enter` key. Every exit code is checked.
4. Terminal.app: `do script` into the tab with that tty, then select the tab
   and bring it to the front. Page then checks that Terminal is frontmost
   with that tab selected immediately before sending Return through System
   Events `tell process "Terminal"`. Codex treats a typed newline as a newline
   inside the composer, so submitting needs a real Return key event.
   `ok_no_enter` (Accessibility not granted) is reported as a failure, and the
   reply says the text is waiting in the composer.
5. Other hosts (iTerm2, VS Code's terminal, cmux, ...) fail with "Page can't
   type into <App> yet — use tmux or Terminal.app".
6. `codex exec resume <thread> <text>` runs in the background (15-min
   timeout, output in `~/Library/Logs/Page-codex-replies/`). This happens only
   when no live interactive codex owns the thread or its directory, and only if
   `headlessResumeFallbackEnabled` is on. This is the Desktop / VS Code path.
   `--skip-git-repo-check` is added (before `resume`, because it is an `exec`
   option) only after the CLI's own refusal message names it. That message
   proves the flag exists in the installed build, without Page having to
   probe `codex exec --help`.

### App-server client hardening

- Inbound messages are classified as response, server request or
  notification, and `id` may be an integer or a string.
- Partial stdout lines are buffered until their newline arrives, and stderr is
  drained to the log.
- The stdin pipe has `F_SETNOSIGPIPE`, so a write to a dead child returns
  EPIPE instead of killing the app. `main.swift` also ignores SIGPIPE.
- A generation counter means a stale child's exit or output can never fail
  the current child's calls.
- A failed handshake terminates the child it spawned.
- `shutdown()` sends SIGTERM, then SIGKILL after 2s.
- Restarts back off exponentially (15s up to 5 min). A child that dies within
  a minute of starting counts as a failed start.
- The `codex` binary is found with
  `ProcessRunner.findExecutable("codex", configured: codexPath)`, using
  `ProcessRunner.augmentedEnvironment()`. Changing `codexPath` restarts the
  child.

### Future work: the protocol-native architecture

To make approvals, steering and live status first-class, sessions have to run
against one shared app-server instead of each surface's embedded one:

- Page runs a long-lived app-server on a local socket, and users start the TUI
  with `codex --remote <addr>` (or a wrapper that does). Approval requests
  then arrive at Page as server requests and can be answered with the
  decision enum. Replies become `turn/steer` / `turn/start` instead of
  keystrokes, and `thread/status/changed` becomes authoritative. The routing
  for this is already in place in `AppServerClient` and
  `CodexBackend.handleServerRequest`.
- Open questions for that work: WebSocket/remote transport stability (still
  marked experimental), Desktop and VS Code support for a remote server,
  and auth for a socket other local processes can reach.
- `item/tool/requestUserInput` answers: the answer schema
  (`ToolRequestUserInputResponse`) is unverified, so these are rejected with
  `-32601` today.

## Summary

Codex support should be built around a backend abstraction, not around more
Claude-specific conditionals.

The core decision is:

- keep the existing relay, power-management, and menu bar UX generic
- move current Claude logic behind a `ClaudeBackend`
- add a `CodexBackend`
- use Codex app-server as the primary Codex control and state interface
- use Codex on-disk session artifacts only as fallback observability

`codex remote-control` should not be treated as the contract. It appears to be
a convenience entrypoint around Codex app-server behavior, while app-server is
the documented interface for rich clients.

## Background

Today the project is organized around Claude-specific signals:

- process detection via `pgrep`
- transcript activity detection in `~/.claude/projects`
- transcript parsing for rate limits and waiting states
- reply injection via tmux or `claude --resume ... --print ...`

That is sufficient for Claude because Claude Code exposes those behaviors in a
stable way. Codex exposes a different local footprint and also has a richer
control surface:

- `~/.codex/sessions/.../rollout-*.jsonl`
- `~/.codex/session_index.jsonl`
- `~/.codex/state_5.sqlite`
- `codex resume`
- `codex app-server`
- `codex --remote ws://...`

The official Codex docs describe app-server as the interface used for rich
clients, including authentication, conversation history, approvals, and
streamed agent events.

## Goals

- Support Codex terminal and desktop sessions through one internal abstraction.
- Preserve the current Page product model:
  keep a machine awake while the agent is active, detect waiting states, relay
  prompts to a phone, and send replies back into the session.
- Minimize Claude regressions by isolating backend-specific logic.
- Prefer supported protocol surfaces over transcript scraping and terminal
  injection.
- Keep the current Cloudflare relay and iOS app mostly backend-agnostic.

## Non-goals

- Rebuild the product around Codex only.
- Remove Claude support.
- Depend on undocumented terminal text parsing when a documented protocol
  exists.
- Achieve feature parity for every Claude-only behavior on day one.
- Support every experimental Codex feature in the first pass.

## Current Claude Coupling

The current implementation is tightly coupled to Claude in these files:

- `Sources/ClaudePowerMode/Config.swift`
  Claude-specific process and transcript settings.
- `Sources/ClaudePowerMode/ProcessMonitor.swift`
  Looks for a Claude process.
- `Sources/ClaudePowerMode/ActivityMonitor.swift`
  Detects activity by Claude transcript mtime.
- `Sources/ClaudePowerMode/TranscriptParser.swift`
  Parses Claude transcript JSONL for rate limits.
- `Sources/ClaudePowerMode/InterventionDetector.swift`
  Infers waiting states from Claude transcript JSONL.
- `Sources/ClaudePowerMode/InjectionExecutor.swift`
  Sends responses back through tmux or `claude --resume`.
- `Sources/ClaudePowerMode/Coordinator.swift`
  Orchestrates all of the above as if there is one backend.
- `Sources/ClaudePowerMode/AppDelegate.swift`
  Renders menu state using Claude terminology.
- `Sources/ClaudePowerMode/PreferencesWindow.swift`
  Exposes Claude-specific settings and copy.

The rest of the system is already closer to generic:

- `PowerManager`
- `RelayClient`
- the iOS app model of "pending interventions"
- the Cloudflare relay transport

## Core Decision

Introduce a backend abstraction centered on agent sessions.

Suggested normalized model:

```text
AgentBackend
  id
  displayName
  discoverSessions()
  refreshRuntimeState()
  subscribe()
  sendReply()
  interrupt()
  resume()

AgentSession
  backend
  sessionId
  cwd
  title
  source
  state
  lastActivityAt
  activeFlags
  supportsRemoteReply
```

Suggested normalized state:

```text
SessionState
  idle
  active
  waitingOnUser
  waitingOnApproval
  rateLimited
  interrupted
  failed
  offline
```

`Coordinator` should aggregate one or more backends and derive the product
state from normalized sessions rather than direct Claude checks.

## Why App Server

Codex app-server is the best integration surface for Codex because it provides
exactly the classes of information and control the product needs:

- stored thread and runtime thread operations
- turn lifecycle control
- streamed output and state updates
- explicit approvals for commands and file changes
- explicit user-input requests
- authenticated local or remote transport

That is materially better than:

- polling file mtimes only
- inferring waiting state from transcripts only
- sending simulated terminal input

### App-server capabilities relevant to this project

The official docs describe support for:

- thread operations such as `thread/list`, `thread/read`, `thread/resume`,
  `thread/archive`, `thread/unarchive`
- turn operations such as `turn/start`, `turn/steer`, `turn/interrupt`
- runtime status notifications such as `thread/status/changed`
- approval request flows for command execution and file changes
- `tool/requestUserInput`
- streamed agent items and conversation history

This maps directly to the product's needs:

- "is the agent active?" -> thread status + in-flight turn state
- "is the agent waiting on me?" -> waiting flags + approval requests +
  request-user-input events
- "can I answer from my phone?" -> `turn/steer` or the matching input response
- "can the terminal attach to the same session?" -> `codex --remote`

## Why Not Build on `codex remote-control`

`codex remote-control` exists in the local CLI, but it is not the documented
surface in the Codex docs.

The project should assume:

- `remote-control` is an entrypoint or wrapper
- app-server is the actual integration contract

This keeps the implementation aligned with the documented protocol and lowers
the risk of binding the product to a moving convenience command.

## Codex Architecture

### Transport choice

**Decision: stdio.** The Codex docs explicitly mark the WebSocket transport
as "experimental and unsupported, appropriate for localhost and SSH
port-forwarding workflows." Since ClaudePowerMode will own the app-server
child process anyway (see Resolved Questions), stdio is the simpler and only
stable option:

- no port management or discovery
- no auth token to mint and inject
- one process lifecycle, owned by us
- credentials flow naturally from the parent's `~/.codex` state

WebSocket and SSH-forwarded WebSocket are deferred until Codex stabilizes
those transports. Remote-host support is a Phase 6+ concern.

### Session model

Codex sessions should be treated as threads exposed by app-server.

Each thread should capture:

- thread id
- persisted rollout path if available
- cwd
- title
- source kind such as `cli`, `vscode`, or `appServer`
- runtime status
- active flags such as `waitingOnApproval`
- last activity timestamp
- whether the thread currently accepts reply/steer input

### Activity detection

Codex activity should come from app-server first.

Preferred sources, in order:

1. runtime thread status from app-server
2. streamed turn and item events
3. persisted rollout timestamp
4. fallback `~/.codex/sessions` mtime scan

This is an important design point: Codex should not be modeled as "a process is
running and some JSONL file changed recently" unless app-server is unavailable.

### Waiting-state detection

Codex waiting state should be explicit, not heuristic-first.

Preferred triggers:

- `thread/status/changed` with waiting flags
- command approval requests
- file change approval requests
- `tool/requestUserInput`

Fallback trigger:

- no protocol status, but a loaded thread stops making progress while the last
  known item implies waiting

This is more reliable than the current Claude transcript-tail heuristics.

### Reply injection

Reply injection should use protocol operations, not terminal keystrokes.

Preferred behaviors:

- answer pending `tool/requestUserInput`
- answer approval requests
- use `turn/steer` to append input to an in-flight turn
- use `turn/start` for a fresh follow-up when the thread is idle but resumable

Fallback behaviors:

- `codex resume <sessionId> "<prompt>"`
- no tmux-based keystroke injection for Codex unless app-server proves
  insufficient and no supported alternative exists

## Backend Shape

### `ClaudeBackend`

Keep the current Claude behavior mostly intact behind a backend facade:

- process monitor
- transcript activity monitor
- transcript parser
- intervention detector
- injection executor

This backend remains heuristic-heavy because Claude is integrated that way
today.

### `CodexBackend`

New backend responsibilities:

- launch or connect to app-server
- authenticate transport if needed
- list and subscribe to threads
- normalize thread and turn state into `AgentSession`
- surface explicit waiting/approval events
- send replies and approvals back through app-server
- optionally fall back to on-disk Codex session files when app-server is
  unavailable

### `BackendCoordinator`

The current `Coordinator` should evolve into a backend aggregator.

It should:

- own multiple backends
- merge session snapshots
- derive product-level boosting state from normalized sessions
- choose which sessions are relay-worthy
- render generic status strings

## File-Level Refactor Plan

### Keep mostly unchanged

- `Sources/ClaudePowerMode/PowerManager.swift`
- `Sources/ClaudePowerMode/RelayClient.swift`
- `Cloudflare/*`
- `iOS/Page/*`

### Split or generalize

- `Config.swift`
  from Claude-specific fields to backend-aware settings
- `Coordinator.swift`
  from single Claude pipeline to backend aggregation
- `AppDelegate.swift`
  from Claude wording to generic agent/session wording
- `PreferencesWindow.swift`
  from Claude-only options to backend-aware sections

### Move behind `ClaudeBackend`

- `ProcessMonitor.swift`
- `ActivityMonitor.swift`
- `TranscriptParser.swift`
- `RateLimitWatcher.swift`
- `InterventionDetector.swift`
- `InjectionExecutor.swift`

### Add for Codex

Suggested new files:

- `Sources/ClaudePowerMode/Backends/AgentBackend.swift`
- `Sources/ClaudePowerMode/Backends/AgentSession.swift`
- `Sources/ClaudePowerMode/Backends/ClaudeBackend.swift`
- `Sources/ClaudePowerMode/Backends/CodexBackend.swift`
- `Sources/ClaudePowerMode/Codex/AppServerClient.swift`
- `Sources/ClaudePowerMode/Codex/AppServerProtocol.swift`
- `Sources/ClaudePowerMode/Codex/CodexSessionStore.swift`

Naming can change, but the ownership boundaries should stay roughly this clean.

## UI and Config Changes

### Menu bar

Current strings like:

- "Claude: active"
- "Claude idle"

should become generic:

- "Agent: active"
- "1 session active"
- "2 sessions waiting"
- "Codex waiting on approval"

The menu should still show backend-specific details when useful, but the top
level product language should stop assuming Claude.

### Preferences

Split preferences into:

- Global power settings
- Claude backend settings
- Codex backend settings
- Relay settings

Examples of Codex settings:

- enable Codex backend
- app-server transport: `stdio` or `websocket`
- WebSocket listen/connect address if applicable
- auth token file path if using WebSocket auth
- fallback on-disk session detection enable/disable

Claude-specific fields such as transcript directory and process pattern should
remain under the Claude backend section.

## Relay and iPhone Implications

The relay protocol should stay session-oriented, not backend-oriented.

The existing payloads already map reasonably well:

- intervention opened
- intervention closed
- reply injected

Add backend metadata so the phone can display and the Mac can route correctly:

- backend: `claude` or `codex`
- session source: `terminal`, `desktop`, `vscode`, `remote`
- intervention kind: `approval`, `user_input`, `idle`, `rate_limit`

The iOS app should not need to know whether Codex uses app-server internally.
It only needs normalized intervention context and a reply path.

## Rollout Plan

### Phase 1: Session abstraction

- Introduce normalized session/backend types.
- Wrap existing Claude logic inside `ClaudeBackend`.
- Keep behavior unchanged for Claude.

Exit criteria:

- no user-visible regression for Claude
- coordinator derives state from backend snapshots

### Phase 2: Codex observability

- Add `CodexBackend` in read-only mode.
- Connect to app-server or fallback session storage.
- Surface Codex sessions in logs and internal state only.

Exit criteria:

- Codex sessions are discoverable
- active/idle state is visible in the app internally

### Phase 3: Codex power mode

- Let Codex sessions influence boosting decisions.
- Update menu bar wording to generic agent/session wording.

Exit criteria:

- active Codex sessions hold the no-sleep assertion
- idle Codex sessions release it correctly

### Phase 4: Codex waiting detection

- Translate app-server waiting and approval events into normalized
  interventions.
- Send those through the existing relay.

Exit criteria:

- Page/iPhone can see pending Codex interventions

### Phase 5: Codex reply path

- Implement app-server approval responses and input steering.
- Do **not** ship a `codex resume` fallback in v1.
  If app-server works, we use it; if it doesn't, the Codex backend is
  considered unsupported on that machine. Carrying a rarely-exercised
  fallback path costs more in trust than it earns in coverage.

Exit criteria:

- a phone reply can unblock a Codex session end to end

## Risks

### Protocol maturity

Codex app-server is documented, but still marked as primarily for development
and debugging, and parts of the transport are experimental.

Mitigation:

- isolate Codex protocol handling in a small module
- keep fallback observability from on-disk session artifacts
- avoid baking protocol details across the app

### App lifecycle ownership

If the macOS app launches app-server, it owns lifecycle and reconnect behavior.
If it connects to an existing app-server, it needs discovery and connection
management.

Mitigation:

- pick one mode for v1
- treat the other as a follow-on

### Session attachment semantics

Codex may have different semantics for:

- answering an approval
- steering an in-flight turn
- resuming a completed thread

Mitigation:

- prototype each reply path against a local app-server before wiring the relay
- keep `turn/start` and `turn/steer` behavior explicit in the client

### Cross-client contention

If desktop app, terminal TUI, and Page all act on the same thread, approvals and
steering requests can race.

Mitigation:

- treat app-server requests as authoritative
- close pending phone prompts when the server says the request is resolved
- record request ids and only answer the matching request

## Gaps and additions

The first draft of this spec missed a few things that need to be addressed
before Phase 2 begins.

### Rate-limit handling should be generic, not Claude-only

An earlier draft of this spec proposed treating rate-limit detection as a
Claude-only feature because Anthropic's reset wording ("resets 7:10pm
(Africa/Johannesburg)") is so specific to Claude Code's transcript. The
app-server spike disproved that assumption.

Codex exposes rate-limit state as a first-class protocol notification. The
shape below was confirmed against the 0.142.5 binary's serde strings and the
`token_count` events in real rollouts (an earlier draft showed a flat
`{limitId, usedPercent, resetsAt}`; the parser still accepts it):

```
account/rateLimits/updated
  { rateLimits: { limitId, limitName?, planType?, rateLimitReachedType?,
                  primary:   { usedPercent, windowDurationMins, resetsAt: <unix> },
                  secondary: { usedPercent, windowDurationMins, resetsAt: <unix> } | null } }

rollout event_msg/token_count (same snapshot, snake_case)
  { rate_limits: { limit_id, primary: { used_percent, window_minutes, resets_at }, secondary,
                   rate_limit_reached_type } }
```

That is strictly easier to consume than Claude's transcript regex — the
reset timestamp arrives structured, not as a localized human string.

Revised design: introduce a generic `RateLimitAware` capability on
`AgentBackend`. Both backends opt in, implemented differently:

- `ClaudeBackend` keeps the existing transcript-tail parser as its
  implementation; it emits a normalized `RateLimitEvent { resetsAt,
  usedPercent? }` upward.
- `CodexBackend` subscribes to `account/rateLimits/updated` and emits the
  same normalized event.

`ResumeScheduler` and the launchd plist machinery stay generic — they take a
`RateLimitEvent` and a backend-supplied "how do I resume this session"
closure. Auto-resume for Codex falls out for free once the closure is
implemented (likely `turn/start` with the same prompt that originally hit
the wall, or a fresh thread).

This is a Phase 4 concern, not Phase 2, but the interface needs to be
designed in Phase 1 so neither backend gets shaped around the wrong
assumption.

### iOS intervention kind reconciliation

The relay payload section proposes `intervention kind: approval | user_input |
idle | rate_limit`. The current iOS `InterventionKind` enum is
`permission | plan | question | idle`. These need to reconcile:

| New (relay)  | Old (iOS)    | Notes |
|--------------|--------------|-------|
| `approval`   | `permission` | Same concept; rename in iOS or map in backend |
| `user_input` | `question`   | Same concept |
| `idle`       | `idle`       | Unchanged |
| `rate_limit` | (new)        | Add to iOS enum; Claude-only initially |
|              | `plan`       | Keep as Claude-specific subtype of approval |

Decision: rename iOS enum to match the new vocabulary (`approval`,
`user_input`, `idle`, `rate_limit`) and add a Claude-only subtype field for
plan-mode approvals. Less ambiguity than maintaining two vocabularies.

### Cloudflare relay schema needs a bump

Adding `backend`, `source`, and the new `kind` enum to relay payloads is a
protocol change. Both `Cloudflare/src/durable.ts` `Intervention` interface and
the iOS `Intervention` struct need updates. Phasing:

- Worker first: accept and store the new fields. Treat missing fields as
  `backend: "claude"`, `source: "terminal"` for back-compat.
- Mac next: start emitting them on `intervention.opened`.
- iOS last: surface them in the UI (especially `source` — a "VS Code" or
  "remote" label changes how the user reads a page).

This belongs in Phase 1 alongside the session abstraction, since it's a
protocol change that everything else builds on.

### Config migration

Phase 1 promises "no user-visible regression for Claude." That requires the
new `Config.swift` shape to migrate from the existing flat layout. Plan:

- Keep all current keys at the top level as deprecated aliases for one
  release. Read them, log a one-time warning, and write the new nested shape
  on next save.
- Drop deprecated aliases in a later release after a clean session has
  validated the migration.

### Codex thread model: verified by spike ✓

The thread = session assumption held up under empirical testing. A live
`thread/list` against the local app-server returned per-thread `cwd`,
`source` (e.g. `"vscode"`), `name`, `path` (rollout JSONL), `cliVersion`,
and `modelProvider`. See "Empirical findings" section below.

One caveat that surfaced: threads come back with `status: {type:"notLoaded"}`.
The original plan was to `thread/read` each watched thread to subscribe.
In practice `thread/read` doesn't attach Page's child to a thread another
process is driving, so no notifications arrive (see "Current implementation
status"). The shipped backend no longer calls it per thread.

## Empirical findings from app-server spike

A one-afternoon spike (2026-05-13) connected to `codex app-server`
(codex-cli 0.130.0) over stdio and walked through `initialize` →
`account/read` → `thread/list` → `experimentalFeature/list` →
`model/list`. The findings below are what the docs got right, what they got
slightly wrong, and what the backend code needs to handle that wasn't
obvious from the docs alone.

### Confirmed by the spike

- `codex app-server` runs cleanly from a `Popen(["codex","app-server"])` —
  no flags, no setup. Inherits the parent's `~/.codex` auth state.
- Newline-delimited JSON on stdin/stdout.
- `thread/list` returns the fields we need: `id`, `cwd`, `source`
  (`"cli"`, `"vscode"`, etc.), `path` (rollout JSONL), `cliVersion`,
  `name`, `modelProvider`, `createdAt`/`updatedAt` (unix seconds).
- `account/read` returns `{type, email, planType}` — usable for surfacing
  which Codex account is paged, and for gating features by plan tier.
- `experimentalFeature/list` and `model/list` exist and can drive
  Preferences UI (model picker, feature toggles) without hard-coding lists.

### Differences from the docs

1. **No `jsonrpc: "2.0"` field on the wire.** Messages are bare
   `{method, id, params}` and `{id, result}` / `{id, error}`. The protocol
   is JSON-RPC-shaped but not literally JSON-RPC. `AppServerProtocol.swift`
   should not emit or require that field.

2. **`initialize` response is flatter than documented.** No `serverInfo`
   wrapper; fields like `userAgent`, `codexHome`, `platformFamily`,
   `platformOs` appear at the top of `result`. Strict struct decoding will
   break on minor version bumps — use permissive decoding.

3. **Threads are `notLoaded` until attached.** `thread/list` is discovery
   only. Attaching requires *driving* the thread from this server
   (`thread/resume` / `turn/start`); `thread/read` does not subscribe to a
   thread another surface's embedded server is running.

4. **WebSocket is documented as "experimental and unsupported."** Only
   stdio is a viable transport for v1.

5. **Server overload error code is `-32001`.** The backend needs
   exponential backoff with jitter when this fires.

### Implementation guidance derived from the spike

- **Decode permissively.** Treat the protocol as forward-compatible JSON:
  unknown fields ignored, missing optional fields defaulted, mandatory
  fields validated only where business logic depends on them. Pin to a
  tested `codex` version range in the menu bar's "About" output so we
  notice when the user upgrades past what we've validated.

- **Watched-threads reconciliation on launch.** On `CodexBackend` start:
  call `thread/list`, intersect with live `codex` PIDs' working
  directories (analog of the `liveClaudeSessionIds()` filter), then
  `thread/read` each survivor to subscribe. Drop threads from the watched
  set when their `codex` process exits.

- **`experimentalApi: true` is required** in the `initialize` capabilities
  block to unlock `tool/requestUserInput`, the chatgpt-auth-tokens method,
  and some thread-level features. We should request it. The protocol may
  shift these out of "experimental" later; that's fine.

- **Free-plan caveat.** The spike account is on `planType: "free"`. Rate
  limits, model availability, and approval-flow behavior may differ on
  Plus/Team/Enterprise plans. Test against at least one paid plan before
  declaring Phase 2 done.

## Resolved (formerly open) questions

1. **Launch app-server ourselves vs connect to external.**
   **Decision: launch our own child process.** ClaudePowerMode is already a
   LaunchAgent-managed background service; making it the owner of the
   app-server child keeps one lifecycle, no port management, no discovery
   logic, and credentials flow naturally from us to the child. The "connect
   to externally-started" mode can be added later as a power-user option if
   it turns out to matter.

2. **`stdio` vs local WebSocket transport.**
   **Decision: stdio.** Codex docs explicitly mark WebSocket as
   "experimental and unsupported." Stdio also avoids port management and
   removes a whole class of auth/discovery work.

3. **How to authenticate the app-server connection.**
   **Decision: reuse the parent's `~/.codex` state — no separate token.**
   Confirmed empirically: a `Popen` of `codex app-server` inherits the
   active ChatGPT browser-login session with no handshake. The "auth token
   file path" Preferences field originally proposed for WebSocket mode is
   no longer needed.

4. **Do all thread sources expose enough metadata?**
   **Decision: yes — `cwd`, `source`, `name`, `path` are all present** for
   the cases observed (`cli`, `vscode`). The phone-copy "unknown project"
   fallback still belongs in the UI for defensive reasons, but it should
   be rare.

## Remaining open questions

These still need proof during implementation:

1. Which exact app-server messages map best to the current Page intervention
   kinds? The method names exist as server *requests* (id + method):
   `item/commandExecution/requestApproval`, `item/fileChange/requestApproval`,
   `item/tool/requestUserInput` (not `tool/requestUserInput`). Approval decisions
   are `accept | acceptForSession | decline | cancel`. `thread/status/changed`
   is `{threadId, status: {type, activeFlags?}}`, with flags `waitingOnApproval`
   and `waitingOnUserInput`. None of these has been observed firing live, and
   they only reach Page under the shared-server architecture (future work).
2. Does the same Codex auth grant cover the desktop app's threads, or are
   they isolated per surface? `thread/list` returned a `vscode`-source
   thread on the spike, suggesting they share state — but this needs
   confirmation against the standalone desktop app once that's installed.
3. What is the right behavior when the user runs `codex` directly in a
   terminal while our app-server child is also running? Two app-servers
   touching the same `~/.codex` state may or may not be safe.
4. How does `account/rateLimits/updated` behave for the free plan vs. paid
   plans? Spike account is free; we haven't observed a rate-limit
   notification fire yet because we haven't hit a wall.

## Recommendation

Proceed with a backend abstraction and implement Codex on top of app-server.

Do not build the Codex integration around:

- transcript scraping as the primary state source
- process detection as the primary activity source
- tmux or synthetic terminal input as the primary reply mechanism
- `codex remote-control` as the contract
- `codex resume` as a fallback reply path

Use app-server as the control plane, and use Codex session files only as backup
observability and recovery tooling.

> **Status note (October 2026):** the shipped backend deliberately departs
> from this recommendation until sessions can share one app-server. Rollout
> files are the primary state source. Process detection picks the reply
> target. tmux, Terminal.app and `codex exec resume` are the reply paths,
> under the safety rules in "Current implementation status". The
> recommendation still describes the target architecture.

## Recommended next step

The handshake-and-discovery spike (`initialize`, `account/read`,
`thread/list`, `experimentalFeature/list`, `model/list`) is complete — see
"Empirical findings" above. Phase 1 is materially in place.

Ready to start Phase 2. The first slice of `CodexBackend` should be:

1. `Sources/ClaudePowerMode/Codex/AppServerClient.swift` — owns the child
   process, does the `initialize` + `initialized` handshake, exposes a
   `call(method:params:)` and a notification stream. Permissive decoding,
   `-32001` backoff baked in.
2. `Sources/ClaudePowerMode/Codex/AppServerProtocol.swift` — typed structs
   for the message shapes we've observed empirically. Start narrow:
   `ThreadSummary`, `Account`, `InitializeResult`. Grow it as we wire up
   each new method.
3. `Sources/ClaudePowerMode/Backends/CodexBackend.swift` — read-only
   first: `thread/list` on startup, filter by live `codex` PIDs' cwd,
   subscribe via `thread/read`, log status changes. No reply path yet, no
   menu bar surface yet.

Phase 2 exit criteria stay as written: Codex sessions are discoverable and
internally visible. Phase 3 (boosting decisions) and Phase 4 (waiting
events to relay) follow, with the rate-limit generalization baked into the
backend interface from the start so Claude's transcript watcher can later
emit the same normalized `RateLimitEvent` as Codex's notification handler.

## References

Official references used for this spec:

- Codex CLI reference:
  https://developers.openai.com/codex/cli/reference
- Codex CLI features:
  https://developers.openai.com/codex/cli/features
- Codex app-server:
  https://developers.openai.com/codex/app-server
- Codex remote connections:
  https://developers.openai.com/codex/remote-connections
