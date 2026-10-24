# Roadmap

Where Page is heading, and why. This is a plan, not a promise: phases
after 0 are estimates and may change. Status is as of October 2026.

## The product split (decided)

Page stays **one monorepo** and becomes two apps that share one Swift library:

```
                    ┌──────────────────────── PageCore (Swift package) ─────────────────────────┐
                    │ relay client + wire protocol · session registry · reply safety rules ·     │
                    │ redaction · config · hook protocol · local socket protocol                 │
                    └───────────────▲──────────────────────────────────────▲────────────────────┘
                                    │                                      │
          ┌─────────────────────────┴──────────┐        ┌──────────────────┴──────────────────────┐
          │ Page AI Power Control (this app)   │◀──────▶│ Page Terminal                           │
          │ menu bar: keep-awake, battery      │ local  │ our own terminal; panes register with   │
          │ policy, detection, phone relay,    │ socket │ Power Control so replies are written    │
          │ hooks, delivery to other terminals │        │ straight to the pane's PTY              │
          └────────────────────────────────────┘        └─────────────────────────────────────────┘
```

- **PageCore** holds everything both apps need: the relay client and wire
  protocol ([PROTOCOL.md](PROTOCOL.md)), the Claude/Codex session registry,
  the reply-safety rules (status-aware keystrokes, staleness checks, fail
  closed), context redaction, config, and the local socket protocol. Today
  this code lives in the single `ClaudePowerMode` target. Extracting it is
  part of Phase 1.
- **Page AI Power Control** is the current menu-bar app. It stays the hub. It
  owns the relay connection, presence, dedupe and power policy, and it keeps
  delivering to terminals it doesn't own (tmux, Terminal.app, iTerm2, cmux)
  and to agent apps through hooks.
- **Page Terminal** is a terminal of our own, built on
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) behind a
  `TerminalEngine` protocol, so the engine can be swapped later.
  [libghostty](https://ghostty.org) becomes an option once it ships a stable,
  embeddable C API with a renderer. Each pane registers with Power Control
  over a local socket (session id, agent, pid, pty), so a phone reply is
  written straight to that pane's PTY. That removes the AppleScript and
  screen-reading workarounds, and the "which terminal owns this session"
  guesswork, for sessions started there.
- **Naming.** "Page Terminal" is our own product. It is not a fork of, or
  named after, cmux, which is a separate project with its own license (see
  [Licensing](#licensing)).

**Why both.** A terminal can't help with the Claude desktop app, the IDE
extensions or the Codex desktop app. Only hooks reach those, so Power Control
and its hook channel come first and stay the universal path. A terminal we
own gives the best delivery for sessions started in it: direct PTY writes, no
TCC prompts, exact pane identity, and a draft and dialog state that it knows
rather than infers.

## Phases

### Phase 0: in this branch

| Item | Status |
|---|---|
| Blocking `PermissionRequest` hook for Claude Code and Codex (approve, deny, deny with text). Away-only, falls back to the dialog | Done |
| `PreToolUse` for `AskUserQuestion` (answers) and `ExitPlanMode` (approve or feedback) | Done |
| Codex opt-in `Stop` hook (a typed reply becomes the next prompt) | Done |
| In-app hook installer: diff preview, backup, idempotent merge, uninstall | Done |
| Duplicate suppression between hook pages, detector pages and Notification pages (hold markers, Worker push dedupe) | Done |
| cmux bridge: socket-mode check, Password-mode onboarding, Feed replies for approvals, guarded `paste --submit` for text | Done |
| iTerm2 delivery by tty | Done |
| No headless `--resume --print` for sessions that are still live | Done |
| Status-aware keystrokes, exact targeting, delivery confirmation, token retirement | Done |
| Lid closed on AC, opt-in lid closed on battery with watchdog, low-battery pause and resume | Done |
| Claude desktop app session detection (reading its local session records) | Not started |
| Skip sessions controlled remotely by Anthropic's apps; publish client presence so Claude doesn't double-notify | Not started |
| `Elicitation` (MCP forms) and `StopFailure` (rate limits) hooks | Not started |

### Phase 1: one local hub (estimated 2–4 weeks)

- **Local hook socket served by Page.app.** Today the hook is a second relay
  client: it POSTs to the Worker directly and polls. In Phase 1, Page.app
  serves a 0600 Unix socket, and the hook talks only to it (curl's
  `--unix-socket` keeps the script in plain bash). Page.app then owns the
  relay, presence and dedupe for every channel. Talking to the Worker directly
  remains a fallback for when the app isn't running.
- **Reply inbox via `asyncRewake`.** An async `Stop`/`SessionStart` hook waits
  on Page's inbox and wakes an idle Claude session with the phone's text,
  without typing into the prompt box. Open question: how Claude weighs a
  rewake message compared with a real user turn.
- **`page run claude|codex`.** A thin PTY wrapper (forkpty, transparent
  proxying that passes terminal queries such as DA1, XTVERSION and `CSI ? u`
  through untouched). Sessions started this way register with Power Control
  and get direct PTY delivery in any terminal. It has to compose with other
  wrappers on `PATH`.
- **Launcher-tier channels**, only for sessions Page starts:
  - **Claude:** the channels/permission-relay mechanism (a research preview
    today).
  - **Codex:** a shared `codex app-server` on a local socket, with the TUI
    attached via `codex --remote`. Approvals then arrive at Page as protocol
    requests, and replies become `turn/start` / `turn/steer` instead of
    keystrokes. The routing for this already exists in `AppServerClient` and
    `CodexBackend.handleServerRequest`.
- **Extract PageCore** as a Swift package that both apps depend on.

### Phase 2: Page Terminal MVP (estimated 6–10 weeks)

This starts only once Phase 1 has shipped and there's a list of concrete gaps
it doesn't close.

- SwiftTerm behind `TerminalEngine`, with a project sidebar, tabs and splits,
  and attention indicators that are driven by real session state, never
  guessed.
- Agents launched pre-wired (hooks and registration).
- Direct PTY writes: bracketed paste only when the application enabled mode
  2004, a separate `\r`, a correctly encoded Esc, and keys that respect the
  kitty keyboard flags.
- Shell-integration OSCs (133, 7, 9, 99, 777).

### Phase 3: later (estimated +3–4 months)

- Session restore, an iOS pane mirror (SwiftTerm has a UIKit view), a socket
  API and CLI.
- Decide on libghostty, depending on whether its API has stabilised.

**Risks:**

- the long tail of terminal-emulation and IME bugs;
- agents that gate features on `TERM_PROGRAM`;
- SwiftTerm throughput under heavy output;
- the ongoing cost of competing as someone's daily-driver terminal.

Page's advantage is working across *every* surface (agent apps, IDEs and any
terminal), not the terminal itself.

## Integration matrix

Legend:

- **H**: documented and robust.
- **M**: documented but untested here, or works with caveats.
- **L**: fragile.
- **—**: not possible.

| Surface | Detect "needs a human" | Approve / deny from the phone | Send a text reply | Page today |
|---|---|---|---|---|
| Terminal.app | sessions file + hooks **H** | hook **H**; typed `1` / menu digit **M** | AppleScript **M** | Detection; replies typed by tty (no lone Esc) |
| iTerm2 | sessions file + hooks **H** | hook **H**; `1` / Esc **M** | AppleScript `write text` **M** | Claude replies by tty; Codex not yet |
| tmux (any host) | sessions file + hooks **H** | hook **H**; `send-keys` **M** | `send-keys` / bracketed paste **M** | Claude and Codex |
| cmux | sessions file + hooks **H**; cmux session records **M** | cmux Feed **H** (Password mode); hook **H** | `paste --submit` into an empty prompt **M** | Claude and Codex, after one-time setup |
| Ghostty, VS Code terminal, others | sessions file + hooks **H** | hook **H** | — (use tmux) | Hooks only; no typing |
| Claude desktop app (Code sessions) | hooks **M** | hook **M** | `asyncRewake` **M** (Phase 1) | Hook approvals (documented, not yet verified) |
| Claude Code IDE extensions | hooks **M** | hook **M** | `asyncRewake` **M** (Phase 1) | Hook approvals (documented, not yet verified) |
| Claude Code on the web / remote | — (local settings aren't read) | Anthropic's apps only | — | Should be skipped (Phase 0, not started) |
| Codex CLI | rollouts **H**; hooks **H** (after `/hooks` trust) | `PermissionRequest` hook **M–H**; shared app-server **M** (Phase 1) | `Stop` hook continuation **M–H**; keystrokes after the turn ends **M** | Idle pages, rate limits, replies after the turn; approvals via hook |
| Codex desktop app / IDE extension | rollouts **H**; hooks unverified | hook (unverified) | `Stop` hook (unverified); `codex exec resume` **L** (not visible live) | Idle pages; replies via `exec resume` |
| Ollama, LM Studio, llama.cpp, MLX (servers and apps) | Not applicable: no prompts. Busy from `/slots` **M** (documented, not verified live) or GPU time **H** (measured) | — | — | Keep-awake while generating (power-only, nothing on the wire) |
| opencode, aider, goose, crush, qwen-code and other terminal agents on open-weight models | Terminal output recency **M** (keep-awake only) | Deferred: opencode plugin / qwen-code hooks, or Page Terminal | Deferred to Page Terminal | Keep-awake while they work |

## What we borrow from cmux: ideas only

cmux is a well-made agent terminal, and several of its *ideas* are worth
adopting. No code is borrowed.

| Idea | Why it fits Page |
|---|---|
| A blocking `PermissionRequest` hook with a soft timeout that falls back to the agent's dialog | It approves without typing, and it fails safe (done in Phase 0) |
| Checking draft and dialog state before typing (empty / draft / dialog) | Never type over a half-written prompt, and never pick a menu option when you meant to send text (done for tmux and cmux) |
| Binding a hook to its pane by a stable id (environment, then tty, then process tree), never by title or file time | Same discipline as Page's exact targeting; needed for Page Terminal |
| Per-launch `--settings` instead of editing user settings | Nothing global to break for sessions Page launches. Desktop and IDE sessions still need user settings |
| One forwarder connection carrying all hook events in order | Lower per-hook latency (relevant to the Phase 1 local socket) |
| An event stream with sequence numbers, resume and a gap flag | Robust phone and Mac sync |
| Attention rings, "jump to latest unread", sidebar metadata | Page Terminal UI |

**What we avoid:**

- Starting agents with permission-bypass flags so that a reply can approve.
- Bypassing hook trust.
- Switching off the agent's own notification channel.
- Wrapping the user's reply as untrusted "not an instruction" text.
- Undocumented `PATH` shims.
- Status indicators that guess.
- Unbounded logs.
- Scope creep beyond paging and delivery.

## Licensing

- Page is **Apache-2.0**.
- cmux's apps and CLI are **GPL-3.0-or-later**, and parts of its server code
  are under the Business Source License.
- Copying cmux code into Page would bring GPL obligations into an Apache
  codebase, so **we never copy, port or paraphrase cmux code**. Contributors
  must not paste it in.
- Page drives cmux only as a separate program, through its documented CLI and
  socket. We understand that this doesn't make Page a derivative work, but
  this is not legal advice.
- SwiftTerm, libghostty and Sparkle are MIT-licensed and fine to depend on
  with attribution in [NOTICE](../NOTICE).

## Open questions

| Question | Current default |
|---|---|
| Should Page install hooks into the user's agent settings? | Yes, opt-in from the app, with a diff preview and backup; away-only; falls back to the dialog |
| On a phone timeout: fall back to the dialog, or deny? | Always fall back. Never auto-deny or auto-allow |
| Which cmux socket mode should Page ask for? | Password mode, with the password in the Keychain. Automation mode lets in any process running as the user |
| cmux's own iPhone forwarding or Page: who pages? | Page; we suggest turning off cmux's forwarding to avoid two alerts per event |
| Is the agent's dialog still usable while a `PermissionRequest` hook is waiting? | Unverified; mitigated by away-only gating and handing back on any input |
| How do Page's and cmux's `PermissionRequest` hooks interact in one session? | Unverified; deny wins between hooks, and Page never denies without an explicit answer |
| Do the Codex desktop app and IDE extension run `~/.codex/hooks.json`? | Undocumented; test before claiming support |
| Does the Codex hook's `session_id` equal the thread id Page uses? | Unverified; affects duplicate suppression |
| When to start Page Terminal? | After Phase 1, against a written list of gaps it closes |
| Engine: SwiftTerm now, libghostty later? | Yes, behind `TerminalEngine`; revisit libghostty when its C API is stable and includes a renderer |
