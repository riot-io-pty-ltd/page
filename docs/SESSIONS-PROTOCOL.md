# Live sessions protocol (`sessions-v1`)

This adds an **Active sessions** view to the phone. It lists every live
agent session on the Mac, shows what each one is doing as a recent
transcript, and lets the user type into a session or stop it at any time,
not only when a page is open. It sits on top of wire v2 (`PROTOCOL.md`) and
changes none of it: old Macs, phones and Workers keep working, and simply
don't show the feature.

## Design rules

1. **Session content is end-to-end encrypted.** The Mac and the phone share
   a 32-byte session key from the pairing QR. The Worker sees opaque
   envelopes, the frame type and sizes. It never sees session titles,
   paths, transcripts, typed text or even which session a command targets.
2. **Encryption is also the authorisation for typing.** The Mac acts on a
   command only if it decrypts with the phone→Mac key, is fresh and hasn't
   been seen before. A leaked relay token on its own can't type anything.
3. **Ephemeral.** Nothing in this protocol is written to Worker storage,
   history, logs or APNs payloads. The Worker forwards and forgets.
4. **Only while someone is looking.** The Mac sends the list and
   transcripts only while at least one phone socket is open, and sends
   transcripts only for sessions a phone is viewing.
5. **The Mac's input gate is the safety boundary** (see "Mac input gate").
   It never weakens the rules the inbox reply path already follows.

## 1. Pairing: the session key

The pairing payload stays `"v": 1` and gains one optional field:

```json
{ "v": 1, "token": "…", "relay": "https://…", "host": "Roy's MacBook", "sk": "<base64url, 32 bytes, no padding>" }
```

- **Mac.** It generates `sk` with `SecRandomCopyBytes` the first time it's
  needed. It stores it next to the relay token (`session_key.txt` in the
  same Application Support folder, with the same 0600 file permissions and
  atomic write as `relay_token.txt`). It regenerates `sk` whenever the token
  is regenerated.
- **Phone.** `PairingValidator` reads `sk` when present: it must decode to
  exactly 32 bytes, otherwise the phone ignores it and doesn't use it. The
  key is stored in the Keychain beside the token and cleared on unpair,
  `reset()` and token retirement. A pairing without `sk` (an older Mac, or
  a phone paired before this shipped) shows the Sessions tab with "Re-pair
  with your Mac to see live sessions" plus how to do it.
- Old phones ignore the extra field (`PairingValidator` reads only known
  keys).

## 2. Crypto envelope

- **Directional subkeys.** Each subkey is
  `HKDF-SHA256(ikm: sk, salt: "page-sessions-v1", info: <direction>, 32 bytes)`,
  where `<direction>` is `"mac->phone"` or `"phone->mac"`. With separate keys
  per direction, the relay can't reflect a Mac frame back to the Mac as a
  command.
- **Cipher.** AES-256-GCM with a random 12-byte nonce for every message and
  a 16-byte tag. Use CryptoKit on both sides.
- **AAD** is the frame type as UTF-8: `"sessions.update"` (Mac→phone) or
  `"sessions.command"` (phone→Mac). The relay therefore can't relabel a frame
  as a different type.
- **Envelope** (JSON, the only thing the Worker sees):
  `{"v":1,"n":"<b64url nonce>","c":"<b64url ciphertext‖tag>"}`.
  base64url has no padding, and readers accept padding too.
- Plaintext is UTF-8 JSON. Readers ignore unknown fields, and also ignore
  any unknown `kind`/`op` value.

### Test vector (both implementations must reproduce it exactly)

```
sk (root)       = AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8   (bytes 0x00…0x1f)
nonce (both)    = oKGio6Slpqeoqaqr                               (bytes 0xa0…0xab)

mac->phone subkey = ofSfPY2KtPqbs29ecqGVJzfSrP61BvMETQTitpTwtYE
  aad       = sessions.update
  plaintext = {"kind":"list","seq":1,"ts":1761300000000,"sessions":[]}
  c         = izpLGj9N9Rpxuzq00howYI0D93aMC4vbU3Un38nzkzaX6rpd2wEiAvuseOahsZ9_zyivF1z2cuLwWX3k6Coa8QEvrfguLaN3

phone->mac subkey = s_XovkSs3InwR9tqHVrGlT_dVvTJeDPPtd0r-wC1qp4
  aad       = sessions.command
  plaintext = {"op":"input","clientId":"c1","ts":1761300000000,"sessionId":"s1","text":"hi","viewer":"v1"}
  c         = sfJ3_bSsO7l16uEp6oH6PFnwlSLI8D_5PtVk8-InyYs-UxcC40NUQDmbHrttBjpm5nJaeQFIgITtiHUF1c6EvBs3hEB0DiBSSIlItp7XAqPjYgLckNcOihF1sKMrZVv8vgUfNIaRAtrMrd_k
```

## 3. Worker

The Worker never decrypts and never stores. Its only additions:

| Direction | What | Worker behaviour |
|---|---|---|
| Mac → Worker (WS) | `{"type":"sessions.update","payload":{"e":<envelope>}}` | Accepted only from a socket already tagged as the Mac (by its `page-mac` User-Agent). `sessions.update` joins `MAC_FRAME_TYPES` but, unlike older Mac frames, never tags an untagged socket: from one it's refused and dropped. It checks the shape (`e.v == 1`, `n` and `c` are strings, the serialised payload is at most 256 KiB), broadcasts `{"type":"sessions.update","payload":{"e":…}}` to phone sockets only, and makes **zero storage writes**. It logs the size only. |
| Phone → Worker (HTTP) | `POST /sessions/command`, body `{"e":<envelope>}`, at most 64 KiB | Bearer auth as usual. With no Mac socket open it returns `503 {"error":"mac_offline"}` and queues nothing. Otherwise it sends `{"type":"sessions.command","payload":{"e":…}}` to every Mac socket and returns `202 {"ok":true}`. A bad shape returns `400 {"error":"invalid_envelope"}`, and too large returns `413 {"error":"too_large"}`. Rate limit: an in-memory token bucket of 120 commands per minute per object, above which it returns `429 {"error":"rate_limited"}`. It makes zero storage writes. |
| Worker → Mac (WS) | `{"type":"phones.status","payload":{"phones":<int>}}` | Sent to Mac sockets when a phone socket opens or closes, and when a Mac socket connects. The count comes from `state.getWebSockets()` (non-Mac sockets that are open), so it survives hibernation. |
| `GET /status` | adds `"features":["sessions-v1"]` | Lets the phone tell "relay too old" apart from "no sessions". |

- `sessions.command` and `phones.status` go only to Mac sockets.
  `sessions.update` goes only to phone sockets.
- Phone-originated types never join `MAC_FRAME_TYPES`, so a phone can't
  get itself tagged as the Mac by sending them.
- Unknown WS types keep today's behaviour (logged, dropped).

## 4. Mac → phone: `sessions.update` plaintext kinds

Every plaintext carries `ts` (ms epoch, Mac clock) and `seq`, a counter
that increases monotonically for each Mac process. The phone drops any
`list` whose `seq` is at or below the last applied `list` with the same
`boot` (see below). It also drops anything with `ts` more than 10 minutes
old, as a replay guard.

`boot` is a random id chosen at Mac launch and included in every plaintext.
When it changes, the phone resets its `seq` tracking.

### `list`

```json
{ "kind": "list", "boot": "…", "seq": 12, "ts": 1761300000000,
  "macName": "Roy's MacBook",
  "sessions": [ {
    "id": "<sessionId / Codex thread id>",
    "backend": "claude" | "codex" | "<other>",
    "title": "mac-on-claude-code",
    "cwd": "~/projects/mac-on-claude-code",
    "state": "idle|active|waitingOnUser|waitingOnApproval|rateLimited|interrupted|failed|offline",
    "host": "cmux" | "tmux" | "Terminal" | "iTerm" | "Ghostty" | "VS Code" | "desktop" | "background" | "unknown",
    "canType": true,
    "typeBlocker": "Page can't type into Ghostty yet",
    "canInterrupt": true,
    "provider": "anthropic" | "ollama" | "lmStudio" | "otherLocal" | "cloudGateway" | "unknown",
    "lastActivityAt": "2026-10-24T12:00:00Z",
    "interventionId": "<open page id, if any>",
    "preview": "Running the test suite…",
    "ask": {
      "id": "<tool_use id of the AskUserQuestion on screen>",
      "hasPreview": false,
      "questions": [ { "question": "Which branch?", "header": "Branch", "multi": false,
                       "options": [ { "label": "main", "description": "The released code." } ] } ]
    }
  } ] }
```

- `cwd` is home-abbreviated. `preview` is at most 160 characters and
  redacted, giving the current activity: the last tool-call one-liner while
  `active`, otherwise the last assistant line.
- `typeBlocker` is present only when `canType` is false.
- `ask` is optional and present only while a Claude session is blocked on
  exactly one pending AskUserQuestion call, read from its transcript: either
  `waitingOn*` with the dialog on screen, or held by Page's own question hook
  (PreToolUse on `AskUserQuestion`) after the user has been away for a while,
  when the session still reads `active` and no dialog is drawn. In that second
  case the phone answers the hook's page by text, with the option numbers as
  `map_answers` in `hooks/page-notify.sh` reads them, and the Mac's `answer`
  op refuses. (Observed on Claude Code 2.1.311: the assistant's tool call is in
  the transcript while the dialog is up only when a PreToolUse hook is
  installed for the tool, as Page's hook does; in a session with no hook it
  was not written until the question was answered, and then there is no
  `ask`.) Text is redacted and clipped (question 400, header
  40, label 120, description 200 characters; at most 4 questions and 7
  options each). For a dialog on screen the Mac sends `ask` only when it can
  press keys in that session's terminal (`canType`, and a terminal whose keys it
  has measured: tmux, including Claude Squad panes), so a phone never offers a
  picker whose Submit would be refused; a hook-held question carries it on any
  terminal, since nothing is pressed. A Mac that sends it also accepts `answer` (§5), so a phone
  offers its picker only when `ask` is there and falls back to a text reply
  (Esc, then the words) otherwise. `hasPreview` is true when an option carries
  a `preview`: that dialog lays out differently and is answered at the Mac.
  Phones ignore a malformed `ask` and keep the session.
- **Working-session fields** (all optional, only on a row whose `state` is
  `active`, each left out when the Mac doesn't know it; older phones ignore
  them, and a phone that finds none shows the card it can from `preview`):
  - `busySince` and `startedAt`: ISO 8601, when the running turn began (the
    session file's busy-since) and when the Claude Code process started the
    session. Absolute dates only: the phone computes "working 12m" and
    "session 2h 10m", so a minute passing never changes the list.
  - `model`: the conversation's model, short ("Opus 4.7").
  - `recentSteps`: up to 3 strings, oldest first, the last the current step, in
    plain words ("Running swift test", "Editing SessionRoom.swift"), redacted,
    at most 100 characters each.
  - `workflows`: up to 3 running workflows, `{ "name", "phase"?, "done",
    "total", "running" }` (agents done / in the run / running now; name at most
    60 characters, phase 40, redacted), and `workflowsRunning`: how many are
    running in all.
  - `health`: present only when it is not normal: `"stuck"` (Page's stuck
    watch has a page open: a loop or no progress; `healthDetail` is its line),
    `"rateLimited"` (`resetsAt`, ISO 8601), or `"longRunning"` (the current
    step has run over 3 minutes; `stepSince`, ISO 8601). A missing `health`
    reads as normal.
- Order: needs-you first (`waitingOn*`), then `active`, then by
  `lastActivityAt` descending. At most 100 sessions.
- **When it's sent:** immediately on `phones.status` going from 0 to more
  than 0, on any change to the list's content (throttled to at most one per
  second), and at least every 20 s while phones > 0 (a liveness refresh).
  Nothing is sent while phones == 0.

### `transcript`

```json
{ "kind": "transcript", "boot": "…", "seq": 13, "ts": …, "sessionId": "…",
  "entries": [ { "id": "<stable id>", "role": "user|assistant|tool|system", "text": "…", "at": "ISO", "tool": "Bash" } ],
  "truncated": true }
```

- This is the **last 40 meaningful entries**, as a full snapshot every time
  (no deltas). It is re-sent when the content changes, throttled to at most
  one every 1.5 s per session. It goes only for sessions in the watch set
  (§5 `watch`), and only while phones > 0.
- `user` entries are the user's prompts, including queued mid-turn
  messages. `assistant` entries are the assistant's text. `tool` entries are
  one-liners describing a tool call (for example "Bash: npm test" or
  "Edit: Sources/App.swift"), reusing the summaries the page detector
  already builds. **Tool output and results are never included.** Sidechain
  or sub-agent records are skipped. `system` is for markers like
  "Interrupted" or "Rate limited until 3pm".
- Every text field is redacted with `ContextRedactor` **before**
  truncation. Each entry is capped at 2000 characters, and the whole
  plaintext at 48 KiB: the oldest entries are dropped first, and
  `truncated: true` is set.
- `id` is stable across snapshots so the phone can diff and keep its
  scroll position. Use the transcript record's uuid, or the line's offset.

### `screen`

```json
{ "kind": "screen", "boot": "…", "seq": 14, "ts": …, "sessionId": "…",
  "lines": ["❯ ", "  ⏵⏵ auto mode on · 1 shell", "  ○ design-pass  11/23 · 2h05m"] }
```

- The visible screen of a watched session's terminal, so the phone can show
  what the transcript can't: the agent's footer (background workflows and
  their progress, shells, sub-agents, todo lists).
- Only for sessions a phone is watching, re-read at most every 2.5 s and
  sent only when it changed (and once on each `watch` / `refresh`). tmux
  and cmux only (`capture-pane -p` / `read-screen --surface … --workspace …`);
  Terminal.app and iTerm2 aren't mirrored.
- Plain text: escape codes stripped, trailing spaces and blank lines
  dropped, the last 80 lines kept, each capped at 300 characters and
  **redacted**, lines dropped from the top until the plaintext fits 32 KiB.
  Unlike `transcript`, this can include tool output that is on screen.
- Per-session `seq` on the phone, like transcripts. A phone that doesn't
  know the kind ignores it (§4), so older apps are unaffected.

### `workflows`

```json
{ "kind": "workflows", "boot": "…", "seq": 15, "ts": …, "sessionId": "…",
  "runs": [{ "id": "wf_5efbb134-a4c", "name": "design-pass-ch1-8-opus", "summary": "…",
             "status": "running", "phase": "Fix B", "done": 28, "total": 30,
             "startedAt": 1761290000000, "endedAt": null, "tokens": null,
             "agents": [{ "id": "a501def47993d54be", "label": "ch5: fix", "phase": "Fix B",
                          "state": "running", "lastActivityAt": 1761299990000 }] }] }
```

- A watched Claude session's dynamic workflows, read from the files Claude
  Code keeps beside the session transcript (`<session>/subagents/workflows/
  <runId>/journal.jsonl`, `<session>/workflows/<runId>.json`, and the
  Workflow tool's launch record in the session transcript for the name and
  summary). Read-only; the terminal is never touched.
- `status`: `running`, `completed`, `failed`, `killed`, or `stalled` (no end
  record and nothing written for 20 min). `done`/`total` count the journal's
  finished/started agents, as the footer does.
- Sent while a phone watches the session (or one of its agents), re-checked
  every 3 s, sent only when changed and once per `watch`. A session that
  never ran a workflow sends nothing.
- Caps: 12 runs (running first, then finished in the last 24 h), 100 agents
  per run (running first), name 80, summary 300, label 160, phase 60
  characters; summary and labels redacted; plaintext 64 KiB (agents trimmed
  from the largest runs to fit).

A `transcript` may carry `runId` and `agentId`: it is then that workflow
agent's transcript (same shape and caps), sent while a viewer watches the
agent (§5 `watch`). The phone keys it apart from the session's own.

### `diff`

```json
{ "kind": "diff", "boot": "…", "seq": 16, "ts": …, "sessionId": "…", "clientId": "…",
  "scope": "turn", "repo": "page",
  "files": [{ "path": "Sources/a.swift", "added": 12, "removed": 3, "status": "modified" },
            { "path": "docs/new.md", "added": 40, "removed": 0, "status": "added" },
            { "path": "notes.txt", "status": "changed" }],
  "patch": "diff --git a/Sources/a.swift b/Sources/a.swift\n…", "truncated": false }
```

- The answer to a `diff` op (§5). `scope` is `turn` when the session's
  current turn edited files (its Edit/MultiEdit/Write/NotebookEdit calls),
  else `uncommitted` (every uncommitted change in the repository).
- `status`: `modified` (diff against HEAD), `added` (untracked: shown as a
  new file), `changed` (no stats: outside the repository, or already
  committed). `added`/`removed` are absent when unknown.
- `patch` is a unified diff against HEAD, redacted like everything else,
  at most 48 KiB, cut at a line; untracked files are included only when
  they're regular text files inside the repository (never symlinks).
  `truncated` is true when the patch or the file list was cut. With no
  repository, `files` is empty, `patch` is `""` and `note` says why.
- Plaintext at most 64 KiB.

### `folders`

```json
{ "kind": "folders", "boot": "…", "seq": 17, "ts": …, "clientId": "…",
  "enabled": true, "agents": ["claude"],
  "folders": [{ "path": "/Users/me/projects/page", "name": "page", "lastUsedAt": 1761290000000 }] }
```

The answer to a `folders` op: where a new session may be started (§5
`start`), newest first, at most 40: the folders of live Claude sessions and
of Claude transcripts written in the last 30 days (never `/` or the home
folder). With "Let my phone start sessions" off, `enabled` is false and
`folders` is empty.

### `result`

```json
{ "kind": "result", "boot": "…", "seq": 14, "ts": …, "clientId": "…", "ok": true,
  "code": "delivered|queued|refused|failed",
  "reason": "waiting|unknown_state|not_typable|draft|digit_while_busy|ended|codex_mid_turn|disabled|stale|replay|not_found|interrupt_unsupported|target_mismatch|question_changed|answer_unsupported|error",
  "detail": "Typed into cmux", "interventionId": "<when reason == waiting>" }
```

`detail` is a short sentence the user sees, at most 200 characters. It never
contains secrets or terminal output.

## 5. Phone → Mac: `sessions.command` plaintext ops

Every op carries `clientId` (UUID, unique per command), `ts` (ms epoch,
phone clock) and `viewer` (a random id per app install, persisted).

| op | Fields | Mac behaviour |
|---|---|---|
| `watch` | `sessionId` (string, or null to stop viewing); optional `runId` + `agentId` | Sets the viewer's watched session (one per viewer) with a 90 s TTL. The phone re-sends it every 30 s while the detail screen is visible, and sends null when leaving it. Sends a `transcript` immediately. With `runId` and `agentId` (plain ids: letters, digits, `_`, `-`, at most 64; anything else is ignored and the session is watched instead) the viewer is on that workflow agent's screen: the Mac sends the agent's transcript instead of the session's, and stops reading the session's screen. No `result` is sent. |
| `refresh` | — | Sends a `list` now, plus the `transcript` for this viewer's watched session. No `result`. |
| `input` | `sessionId`, `text` (1–8000 characters after trimming) | Runs the input gate, then delivers. Always replies with a `result`. |
| `interrupt` | `sessionId` | Presses Esc in the session (`sendInterrupt`). Only when `canInterrupt` and state is `active`. Always replies with a `result`. |
| `answer` | `sessionId`, `promptKey` (the `ask.id`), `answers` (below); optional `expectCwd` / `expectTitle` as for `input` | Answers the question dialog the session is blocked on, in one pass (see "Answering a question"). Always replies with a `result`. |
| `diff` | `sessionId` | Replies with a `diff` (§4), or a `result` `refused/not_found` for a session that isn't running. |
| `folders` | — | Replies with a `folders` (§4). |
| `interruptAll` | — | Siri / Shortcuts "Stop my agents": presses Esc in every session that is `active` (skipping hosts where Esc can't be sent), each through the same gate as `interrupt`. Replies with one `result`: "Stopped 2 agents", "Stopped 1 of 2 agents" or "No agents were working". |
| `start` | `folder`, `text` (the prompt, 0–4000 characters; may be empty) | Starts a new Claude session: a cmux workspace in `folder` running `claude -- '<text>'`. Off unless "Let my phone start sessions" is on (`phoneStartSessionsEnabled`, default false): `refused/disabled`. `folder` must be one the `folders` list would contain, compared after standardising (`refused/not_found`). The prompt is folded to one line, control characters stripped, and passed as one shell-quoted argument after `--`, so it can never be read as a flag; a one-word prompt gets a full stop added so it can never match a `claude` subcommand (`purge` → `purge.`). Needs cmux in a mode that lets Page in (`refused/not_typable` with cmux's reason). Always replies with a `result`. |

### Acceptance (before any op)

The Mac checks, in order:

- It decrypts with the phone→Mac subkey and AAD `sessions.command`.
  Failure means it is dropped silently and logged as "undecryptable" with
  no content.
- `|now − ts| ≤ 5 min`. Otherwise it replies `refused/stale`.
- `clientId` hasn't been seen in the last 15 min (an LRU of up to 2000
  entries, persisted to disk so it survives a Mac restart). Otherwise it is
  dropped silently.
- The feature is enabled in config (`remoteSessionsEnabled`, default
  `true`, with a toggle in Preferences ▸ Integrations or Phone). Otherwise
  it replies `refused/disabled`.

### Mac input gate (`input`)

The session must be in the Mac's **current** list (looked up by id; the
phone's copy is never trusted for cwd, pid or host). Then:

1. **Claude.**
   - Re-read live state (`liveSessions(forSessionId:)` plus
     `currentRecord(forPid:)`).
   - Refuse if: there is no live process (`ended`); status is `unknown`, or
     there is no sessions file (`unknown_state`); status is `waiting`, so a
     prompt is on screen (`waiting`, with the open `interventionId` if there
     is one); the host is unsupported (`not_typable`); or the state is busy
     and the text's first non-space character is a digit (`digit_while_busy`,
     "Starts with a number: wait for Claude to finish, or add a word first").
   - Deliver through the battery-pause seam: a synthetic
     `ClaudeReplyRequest` with interventionId `"<sid>-phone-<clientId>"`,
     `resolveClaudeTarget`, then `deliverToLiveSession`. It always uses
     `requireEmptyInput: true`, so a half-typed draft is refused with
     `draft`. It **never** uses the headless or `--resume` fallback.
   - `idle` means text + Enter (`delivered`). `busy` means text + Enter,
     queued by Claude Code, never Esc (`queued`, "Queued — Claude reads it
     after the current step").
2. **Codex.**
   - Turn finished (`completed`, `aborted` or `idle`): `deliverToSession`
     with `requireEmptyComposer: true`.
   - `inTurn`: allowed only in a cmux pane whose composer reads empty, using
     the battery `PauseStrategy.queue` path (`queued`). Anywhere else, refuse
     with `codex_mid_turn` ("Codex is mid-turn — Page can type once the turn
     ends").
   - Any `pendingRequest` gives `waiting`. Never `exec resume`.
3. Any other backend gives `refused/not_typable`.
4. Text is sanitised by the existing `sanitize` (strips control
   characters, caps at 8000, guards a leading `!`).

Each command is logged as session id prefix + op + outcome + text length.
Never the text.

### `interrupt`

Allowed only for state `active` and a host where `sendInterrupt` works
(tmux, iTerm, cmux; cmux refuses while a dialog is open). Otherwise it
replies `refused/interrupt_unsupported`. Claude and Codex both treat Esc as
"stop this turn".

### Answering a question (`answer`)

```json
{ "op": "answer", "sessionId": "…", "promptKey": "toolu_…",
  "answers": [ { "i": 0, "picks": [1] }, { "i": 1, "picks": [0, 2], "other": "kiwi pie" } ] }
```

`i` is the question's index; `picks` are 0-based option indices (one for a
single-select, any number for a multi-select); `other` is the "Other" text
(a single-select with `other` has no `picks`). Every question must be
answered. The phone drafts all answers, shows what will be chosen and where,
and sends once ("Submit all"). The Mac trusts only `promptKey`, the indices
and the Other text: it re-reads the raw question from the transcript (the
list's copy is redacted) and checks everything again.

The key model (measured on Claude Code 2.1.311, in tmux first and then end to
end in every terminal listed below): in a single-select a digit picks that option and advances (the last question goes to Review; one
question submits at once); the Other row is `N+1`, its digit only focuses it,
then the text and Enter. In a multi-select a digit toggles that option and Tab
moves on; the Other row is reached with Down × N (its digit would tick an empty
box), then the text, Tab (to Next) and Enter. On Review, `1` submits and `2`
cancels. Esc cancels everything and "Chat about this" (`N+2`) rejects the tool:
Page never sends either, and never `2` on Review.

The Mac drives it one key at a time, never from a precomputed script:

1. The session must still be `waiting`, exactly one tool call pending, that
   call the AskUserQuestion named by `promptKey`, and no Page hook holding the
   prompt; otherwise `refused/question_changed` (or `answer_unsupported`).
2. It reads the terminal's screen before every key and parses the dialog (the
   `N. label` rows, the question text with wrapping collapsed, the cursor row,
   the `[✔]` ticks). Digits are sent only with the cursor on a real option row;
   ticks are planned from what is on screen, so a half-answered dialog is
   corrected, not toggled blindly. The dialog must be on its first question.
3. After each key it waits (100 ms polls, 1.5 s) for the screen to show the
   effect before sending the next. Before each key the process must still be
   in front of its terminal, the status still `waiting` with the same
   `statusUpdatedAt` (±0.5 s) and the same pending call.
4. On Review, the listed answers must equal the intended ones exactly, then
   `1` is sent.
5. It reads `toolUseResult.answers` from the transcript and compares: the
   `result` says "Answered 2 questions in tmux pane %0", or that Claude got
   different answers, or that the dialog was dismissed first.

Anything unexpected stops the run with a reason and leaves the dialog open
for the Mac (`failed` with "part-filled at your Mac" when keys were already
sent). Refused without pressing anything: previews (`hasPreview`), more than 7
options, a screen the parser can't read (a narrow or short pane can scroll the
question off the top: it fails closed) and Terminal.app (below). Results use
the existing codes plus reasons `question_changed` and `answer_unsupported`
(older phones show `detail`).

**Terminals** (each driven end to end against a throwaway Claude Code 2.1.311
session on Haiku, through the real `AnswerDelivery.run`; the transcript's
`toolUseResult.answers` equalled the intended answers in every run). The session
list advertises `ask` only for a host marked yes (`AnswerDelivery.takesAnswerKeys`,
by the wire host name, read from `TerminalCatalog`); the Mac's Terminals page and
the phone's "Works with" list show the same fact per terminal.

| Terminal (wire host) | Screen read | Keys | Answers |
|---|---|---|---|
| tmux, Claude Squad (`tmux`, `Claude Squad`) | `capture-pane` | `send-keys`: digits, `Tab`, `Down`, `Enter` and the text | Yes, every shape |
| iTerm2 (`iTerm`) | AppleScript `contents` | `write text … newline NO` for digits and text; Tab and Enter as `character id 9` / `13`; arrows as ESC `[` `B` in one write | Yes, every shape |
| cmux (`cmux`) | `cmux read-screen --surface` | `send --force` for a digit, `send-key --force` for `tab` / `down` / `enter`, `paste --force -` for the Other text | Yes, every shape |
| WezTerm (`WezTerm`) | `cli get-text` | `cli send-text --no-paste`: digits, `\t`, `\r`, ESC `[` `B` in one write | Yes, every shape |
| kitty (`kitty`) | `@ get-text --extent screen` | `@ send-text` (bracketed paste off) for digits and text, `@ send-key tab|down|enter` | Yes, every shape |
| Herdr (`Herdr`) | `pane.read` (visible, text) | `pane.send_text` for digits and one-line text, `pane.send_keys` `tab` / `down` / `enter` | Yes, every shape |
| Terminal.app (`Terminal`) | AppleScript `contents` | `do script` always appends a Return | Not yet |

Every host in the table was driven with arrow keys (the Other row of a
multi-select is Down × N away), so none is limited to digits. A host whose
transport could only type digits, Tab and Enter would have to refuse an Other
in a multi-select up front (`AnswerKeyCaps.plainKeysOnly`); none ships that way.

Host-specific measurements that shaped the code:

- **cmux** refuses every key into an open dialog unless `--force` is passed, and
  its `surface.input_state` reads `dialog` on every question screen but reports
  `unknown` on the final "Review your answers" screen. Page accepts `unknown`
  only when the screen read shows "Review your answers", "Ready to submit your
  answers?" and "1. Submit answers"; any other wording fails closed. cmux's own
  Feed hold on a question was not exercised.
- **iTerm2, WezTerm and kitty** need the session's real environment: a terminal
  started with another Claude session's variables (`CLAUDE_CODE_*`) in its environment makes
  the inner `claude` skip `~/.claude/sessions/<pid>.json`, and Page then refuses
  the session as `unknown_state`. A normally started terminal is unaffected.
- **kitty** starts each window's shell under `login -f -l -p user …/kitten
  run-shell`; the host app is the kitty process above that row.
- **WezTerm** was measured on the headless mux server (`cli spawn`); a GUI window
  uses the same CLI against its own `WEZTERM_UNIX_SOCKET`.
- **Terminal.app** was not measured live (the Mac's screen was locked, so no
  AppleScript window event ran). On a tmux stand-in, the Return that `do script`
  appends lands on the next question of a multi-question set, and dismisses
  ("User declined to answer questions") a single-select with Other. A
  one-question single-select without Other behaved, but is unproven in the real
  transport, so Page refuses every Terminal.app answer with "Terminal.app adds a
  Return to every key Page types, which would skip or dismiss questions".

## 6. Phone UX contract

- **Tabs.** Inbox · Sessions · History · Settings. Stats moves into History
  as a segment, which keeps four tabs and the Dynamic Type cap.
- **Sessions list.** Grouped as "Needs you", "Working" and "Idle". Each card
  shows the project (mono), a backend pill, the host, the state dot,
  `preview` and its age. Sessions with an open page get an "Open page"
  affordance into `ReplyView`.
- **Detail screen.** A header (project, backend, host, state), the
  transcript (chat-style: user right, assistant left, tool one-liners as
  compact mono rows), and a composer pinned to the bottom (the extracted
  `replyField`). There's a **Stop** button while `active` and
  `canInterrupt`, with a confirmation step.
  - When `canType` is false, the composer is replaced with the
    `typeBlocker` text.
  - When the state is `waitingOnApproval` or `waitingOnUser` with an
    `interventionId`, a banner opens that page.
  - Each sent message shows its delivery state (Sending → Queued / Typed /
    Refused + reason), keyed by `clientId`. The phone gives up after 20 s
    without a `result` ("No answer from your Mac").
- **States the screen handles:** relay without `sessions-v1` ("Update your
  relay"), no `sk` ("Re-pair"), Mac offline (503 or `mac.status`), Mac
  online but no `list` within 5 s of connecting (older Mac: "Update Page on
  your Mac"), and an empty list.
- Session state lives in its own `ObservableObject` (`SessionStore`), not in
  `APIClient`, and is cleared on `reset()`.

## 7. Limits

| What | Value |
|---|---|
| sessions per list | 100 |
| transcript entries / entry text / plaintext | 40 / 2000 chars / 48 KiB |
| `preview` | 160 chars |
| `recentSteps` / `workflows` per row | 3 steps of 100 chars / 3 workflows |
| input text | 8000 chars (phone 8000, Worker body 64 KiB) |
| `answer`: questions / options each / Other text | 4 / 7 / 300 chars |
| `answer` run: wait per key / whole run / read-back | 1.5 s / 12 s / 4 s (under the phone's 20 s) |
| `sessions.update` payload at the Worker | 256 KiB |
| list throttle / liveness refresh | 1 s / 20 s |
| transcript throttle | 1.5 s per session |
| screen lines / line / plaintext / interval | 80 / 300 chars / 32 KiB / 2.5 s |
| workflows runs / agents per run / plaintext / interval | 12 / 100 / 64 KiB / 3 s |
| watch TTL / phone re-send | 90 s / 30 s |
| command freshness / replay window | ±5 min / 15 min, 2000 ids |
| phone result timeout | 20 s |
| Worker command rate | 120 per minute per relay |
