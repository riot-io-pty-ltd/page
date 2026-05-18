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

Codex exposes rate-limit state as a first-class protocol notification:

```
account/rateLimits/updated
  { limitId, usedPercent, windowDurationMins, resetsAt: <unix> }
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

One caveat that surfaced: threads come back with `status: {type:"notLoaded"}`
and don't push notifications until you explicitly attach. The backend has
to maintain a watched-threads set and call `thread/read` (or equivalent
subscribe) for each one we care about. The list endpoint is for discovery
only.

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
   only. The backend needs an explicit subscribe step (`thread/read`)
   before notifications about a thread start arriving.

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
   kinds? The spike confirmed the method names exist (`item/commandExecution/requestApproval`,
   `item/fileChange/requestApproval`, `tool/requestUserInput`,
   `thread/status/changed` with `activeFlags`) but did not yet observe one
   firing live. Phase 2 needs to capture the real payloads when triggered.
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
