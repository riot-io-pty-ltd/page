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
  "caps": ["hold-v1", "retract-v1", "images-v1"],
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
    },
    "canHold": true,
    "held": [ { "clientId": "<the input's clientId>", "text": "Then run the linter", "heldAt": "2026-10-24T12:00:00Z",
                "state": "held" } ],
    "attach": "image" | "path",
    "attachBlocker": "Page can't send photos to Codex yet"
  } ] }
```

- `caps` (header, optional): what this Mac accepts beyond the ops in §5, so a
  phone offers a feature only when the Mac says it can do it. `hold-v1`: the
  `input` op's `hold` field and the row's `held` list ("Holding a message
  until the turn ends"). `retract-v1`: the `retract` op ("Taking a message
  back"). `images-v1`: the `imagePart` and `inputImages` ops, the row's
  `attach` / `attachBlocker` and the result's `attached` / `missing`
  ("Images"). Later features append their own names to the same array. Older
  Macs send no `caps`; a phone treats a missing `caps` as `[]`. Readers ignore
  names they don't know.

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
- `canHold` (optional, `hold-v1`): `true` when Page can type into this
  session's terminal once its turn ends, so the phone may offer "Send when it
  finishes". It follows the probed host before the Codex mid-turn rule, so a
  busy Codex session outside cmux has `canType: false` (no "Send now") but
  `canHold: true`. Absent means no: a host Page can't type into, or one not
  probed yet. A phone offers holding only when `caps` has `hold-v1` and the
  row has `canHold`.
- `held` is optional and present only while the Mac holds messages for this
  session, or settled one in the last 15 minutes (§5 "Holding a message until
  the turn ends"). Oldest first; at most 10 waiting and 10 settled entries.
  - `clientId`: the `clientId` of the `input` that asked to hold it. It is
    also the `heldId` a `retract` names.
  - `text`: the message, redacted and clipped to 200 characters (the phone
    that sent it has the full text).
  - `heldAt`: ISO 8601, when the Mac accepted it.
  - `state`: `held` (waiting for the turn to end), `typing` (being typed
    right now), or a settled outcome: `typed`, `deleted`, `ended` (the
    session ended first), `expired` (6 hours passed), `failed` (refused or
    failed when Page tried; `detail` says why), or `unconfirmed` (Page
    restarted while typing it and does not retype it: check the session).
  - `at` (settled only): ISO 8601, when it settled. `detail`: on a settled
    entry, the sentence the final `result` carried; on a `held` entry, why
    the last try didn't type it (for example someone typing at the Mac),
    when one was refused for a passing reason.
  A phone reconciles its receipts from this list as well as from `result`
  frames, because a `result` reaches only the phones that are connected at
  that moment.
- `attach` (optional, `images-v1`): how a photo sent from the session chat
  reaches this session. `"image"`: pasted, so Claude attaches it as an image.
  `"path"`: the photo's location is typed as text and Claude opens the file
  itself (not attached). Present only on a Claude row with `canType` true, in
  a terminal Page has a photo route for ("Images"). A phone shows the photo
  button only when `caps` has `images-v1` and the row has `attach`.
- `attachBlocker` (optional): why a row Page can type into takes no photos,
  e.g. "Page can't send photos to Codex yet". Absent when `canType` is false
  (the `typeBlocker` already says why).
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
- `images` (optional, `user` entries only): how many photos the message
  carried, so the phone can draw a "2 photos" chip. Claude Code stores each
  pasted image inline as base64 in the transcript (lines of megabytes); only
  the count is ever sent. The entry's `text` is the message as Claude Code
  wrote it ("[Image #1] [Image #2]what are these?"), or "[Image]" /
  "[2 images]" when it has no text. Known gap: the transcript is read from a
  256 KiB tail, widened to 2 MiB; a record with several large photos (about
  3.4 MB for four) is longer than that, so its row is missing from the
  phone's transcript until the tail readers are widened.

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
  "code": "delivered|queued|refused|failed|cancelled",
  "reason": "waiting|unknown_state|not_typable|draft|digit_while_busy|ended|codex_mid_turn|disabled|stale|replay|not_found|interrupt_unsupported|target_mismatch|question_changed|answer_unsupported|cancelled|expired|too_late|attachment_missing|attachment_invalid|attach_unsupported|attach_busy|error",
  "detail": "Typed into cmux", "interventionId": "<when reason == waiting>",
  "held": true, "fromHold": true, "retract": "deleted|too_late|not_found",
  "attached": 2, "missing": ["<imageId>"] }
```

`detail` is a short sentence the user sees, at most 200 characters. It never
contains secrets or terminal output.

`ok` is true only for `delivered` and `queued`. The last five fields are
optional and come only from a Mac that advertises `hold-v1` / `retract-v1` /
`images-v1`:

- `held: true` (with `code: "queued"`): the Mac is holding the message until
  the session's turn ends. It is not the final word on that `clientId`: one
  more `result` follows.
- `fromHold: true`: the final `result` for a held message, with the same
  `clientId`. A phone replaces its "Held" receipt with it. Phones that don't
  know the field drop it as a second result, as before.
- `retract`: the answer to a `retract` op, also given as `code` / `reason`.
- `code: "cancelled"` (with `reason: "cancelled"`, `ok: false`) only ever
  answers an `input` with `hold`: it was deleted and nothing was typed.
  Phones read an unknown `code` as `failed` when `ok` is false, so older
  apps still show it as not sent.
- `attached` (`images-v1`, answers to `inputImages` only): how many photos
  Claude received as images, read back from the session's transcript; `0`
  when they went as file locations or Claude took the pasted paths as text.
  Absent when Page couldn't read it back. `missing`: the ids of photos whose
  pieces never arrived (`attachment_missing`).

## 5. Phone → Mac: `sessions.command` plaintext ops

Every op carries `clientId` (UUID, unique per command), `ts` (ms epoch,
phone clock) and `viewer` (a random id per app install, persisted).

| op | Fields | Mac behaviour |
|---|---|---|
| `watch` | `sessionId` (string, or null to stop viewing); optional `runId` + `agentId` | Sets the viewer's watched session (one per viewer) with a 90 s TTL. The phone re-sends it every 30 s while the detail screen is visible, and sends null when leaving it. Sends a `transcript` immediately. With `runId` and `agentId` (plain ids: letters, digits, `_`, `-`, at most 64; anything else is ignored and the session is watched instead) the viewer is on that workflow agent's screen: the Mac sends the agent's transcript instead of the session's, and stops reading the session's screen. No `result` is sent. |
| `refresh` | — | Sends a `list` now, plus the `transcript` for this viewer's watched session. No `result`. |
| `input` | `sessionId`, `text` (1–8000 characters after trimming); optional `hold` (`true`: type it when the turn ends; needs `hold-v1`) | Runs the input gate, then delivers. Always replies with a `result`. With `hold`, see "Holding a message until the turn ends". |
| `retract` | exactly one of `heldId` (a held `input`'s `clientId`) or `interventionId` (a `/reply` the Mac is holding); needs `retract-v1` | Takes back a message the Mac is holding and hasn't typed. Always replies with a `result` carrying `retract` (see "Taking a message back"). |
| `imagePart` | `sessionId`, `imageId`, `index`, `total`, `bytes`, `sha256`, `mime`, `data`; needs `images-v1` | One piece of a photo (see "Images"). Kept in memory; **never** answered. |
| `inputImages` | `sessionId`, `text` (0–8000 characters), `images` (1–4); optional `expectCwd` / `expectTitle` as for `input`; needs `images-v1` | Sends the photos with the caption into the session (see "Images"). Always replies with one `result`. |
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
  dropped silently. An `imagePart` skips this check (see "Images").
- The feature is enabled in config (`remoteSessionsEnabled`, default
  `true`, with a toggle in Preferences ▸ Integrations or Phone). Otherwise
  it replies `refused/disabled`.

An `imagePart` that is stale or arrives while the feature is off is dropped
silently: pieces never get a `result`.

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

### Holding a message until the turn ends (`hold-v1`)

When the user steers a busy session, the phone lets them choose per message:

- **Send now** (no `hold`): today's behaviour. The text is typed at once and
  Claude Code queues it, so Claude reads it after its current step
  (`queued`). The phone may hold the POST back for a few seconds as an undo
  window; that is phone-only.
- **Send when it finishes** (`"hold": true`): the Mac holds the message and
  types it (text + Return, through the same input gate) only once the
  session's turn is over. Until then either phone can delete it (`retract`).

```json
{ "op": "input", "clientId": "c7", "ts": 1761300000000, "viewer": "v1",
  "sessionId": "…", "text": "Then run the linter", "hold": true,
  "expectCwd": "~/projects/page", "expectTitle": "page" }
```

A phone sends `hold` only when the list header's `caps` contains `hold-v1`
and the row has `canHold`. An older Mac ignores the field and types the
message at once, as before.
`hold` from this Mac's own panel is ignored (it always types at once).

**On arrival** the Mac runs the usual checks first (`not_found`,
`target_mismatch`, empty or too long text). Then:

- A host the Mac knows it can't type into (`canType` false, before the Codex
  mid-turn rule is applied) is refused with its `typeBlocker`: holding would
  only fail later.
- More than 10 messages waiting for the session, or 50 in all, is refused
  (`error`, "Page is already holding 10 messages for this session — delete
  one first").
- If the turn is already over (Claude's sessions file reads `idle` or
  `shell`; a Codex thread that is `idle`, `interrupted` or `failed`), the Mac
  tries to type it right away and answers with one ordinary `result`
  (`delivered`, or the refusal), with no `held` or `fromHold`. If that try
  finds the session busy again, it is held instead.
- Otherwise (working, a prompt is open, rate limited, or the status can't be
  read) it is held:
  `{"code":"queued","ok":true,"held":true,"detail":"Held — Page types it when Claude finishes this turn"}`
  ("…when Codex finishes this turn" for Codex).

**While held** the Mac re-reads the session's state every 2 s (Claude's
sessions file; Codex's state from the last scan) and on every tick, whether
or not a phone is looking. When the turn is over it types the oldest held
message:

- Through the normal input gate with two extra rules: the session must be
  idle (a busy session is refused before any key, and the check is repeated
  before every key, so the text is never queued behind a running turn), and
  a waiting prompt is never typed into. Claude: `deliverToLiveSession` with
  the input box required empty. Codex: only a finished turn, never the cmux
  mid-turn queue, never `exec resume`.
- One held message per idle period. Typing it starts a new turn, so the next
  waits for that turn to end, and for at least 8 s after the last one was
  typed.
- Not while a rate limit is active for the session, and not while "Live
  sessions" is turned off on the Mac.
- The folder and title the phone showed (`expectCwd` / `expectTitle`) are
  checked again before typing.

A try that is refused before any key for a passing reason keeps the message
held and tries again later (5 s after the first refusal, 5 s more after each
one after that, at most 60 s apart): still busy, a prompt
(`waiting`), `unknown_state`, `draft` (someone is typing at the Mac), the
session not in front of its terminal, or `codex_mid_turn`. Anything else is
final and the message is never retried, in particular a `failed`, which may
have typed part of the text.

**Exactly one final `result`** (`fromHold: true`, same `clientId`) ends every
held message, and the row's `held` entry settles to the same outcome:

| Outcome | `code` / `reason` | `detail` | `held` state |
|---|---|---|---|
| Typed | `delivered` | the delivery's own ("Typed into tmux pane %3") | `typed` |
| Deleted (a `retract`) | `cancelled` / `cancelled` | "Deleted — not sent" | `deleted` |
| Session ended first (gone from the Mac's list for 30 s and 2 ticks, or the gate found no process) | `refused` / `ended` | "Not sent — the session ended" | `ended` |
| Turn never ended | `refused` / `expired` | "Not sent — the turn didn't finish within 6 hours" | `expired` |
| Refused or failed when typing | the gate's `code` / `reason` | "Not sent — " + the gate's detail | `failed` |

The final `result` goes only to phones connected when it happens, so a phone
also settles a "Held" receipt from the row's `held` list. A held entry that
vanishes from the list without a settled state (its session left the list)
reads as "No longer held — check the session".

**Persistence.** Held messages survive a Page restart: they are kept in
`held_outbox.json` in Page's Application Support folder (0600, written
atomically on every change, at most 50 waiting messages and the settled
entries of the last 15 minutes). The text is stored because it must be typed
later; nothing else of the session is. A message whose typing had started
when Page quit is never retyped after the restart: it settles as
`unconfirmed`. If the pairing's session key changes (Regenerate pairing),
every held message is dropped untyped, since the phone that sent it is no
longer trusted.

Logs carry the session id prefix, the message's `clientId` prefix, the
outcome and the text length, never the text.

**On the Mac.** The menu-bar panel lists held messages on their session's
In-flight card ("Held from your phone · “…” · 4m") with a Delete button,
which sends the same `retract` through `performLocal`, so the race rule and
the phones' final `cancelled` result are the same as a delete from a phone.

### Taking a message back (`retract-v1`)

```json
{ "op": "retract", "clientId": "r1", "ts": 1761300000000, "viewer": "v1", "heldId": "c7" }
{ "op": "retract", "clientId": "r2", "ts": 1761300000000, "viewer": "v1", "interventionId": "<page id>" }
```

`clientId` is the retract command's own id (unique, through the replay guard
like every command); the message to take back is named by `heldId` or
`interventionId`, never both (that, or neither, is refused `error`). A phone
sends `retract` only when `caps` contains `retract-v1`; an older Mac ignores
the unknown op and the phone's 20 s timeout applies ("Couldn't confirm the
delete — it may still be sent").

Results (always one, for the retract's own `clientId`):

| `retract` | `code` / `reason` | `detail` |
|---|---|---|
| `deleted` | `delivered` (`ok: true`) | "Deleted — not sent" (or "Already deleted — not sent" for a second delete) |
| `too_late` | `refused` / `too_late` | "Too late — it was already typed" (or "Too late — Page had started typing it; check the session" when that try failed part way) |
| `not_found` | `refused` / `not_found` | "Page isn't holding that message" |

**`heldId`: a held `input`.** Deleted while it waits. The race with typing
is decided by a one-way switch that the delivery flips right before its first
key and a delete flips while the message waits: whichever comes first wins,
so a message is never both typed and deleted. A delete that arrives after the
switch has gone to the delivery waits for that try to finish (seconds, well
inside the phone's 20 s): typed gives `too_late`; refused before any key gives
`deleted` (and the original's final `result` is `cancelled`); `failed` (part
of the text may be in the input box) gives `too_late`, and the original's
final `result` is that failure. After a delete,
the original `input`'s `clientId` gets its final `cancelled` result.

**`interventionId`: a `/reply` the Mac is holding** (after the relay's own
`DELETE /reply/<id>` answered `409 too_late`):

- A written reply to a rate-limit page, held until the limit resets. Its
  `reply.injected` now carries `method: "held_until_reset"` (older phones keep
  showing it as delivered, with the same "Will send it when the limit resets
  at 3:00 PM" detail). Deleted: `detail` "Deleted — not sent. Page will type
  your carry-on prompt when the limit resets" when auto-resume is on, else
  "Deleted — not sent. Nothing will be typed at reset". Too late, once Page
  has taken it to type: "Too late — Page was already typing it after the
  limit reset". When it is finally typed, or can't be, the Mac sends one more
  `reply.injected` for the page (`success: true` with the delivery's method
  and "Typed when the limit reset — Typed into tmux pane %3", or
  `success: false`, method `none`, and one of "Not sent — the session ended",
  "Not sent — the session was busy when the limit reset", "Not sent — the
  session got going again before the limit reset", "Not sent — the limit
  reset over 2 hours ago and Page didn't type it", or "Not sent — " + the
  delivery's own reason).
- A reply to an ended Claude session waiting behind another background
  `claude --resume --print`, or a Codex reply waiting for `exec resume`.
  Deleted before its run starts; once it has started: "Too late — it's
  already running"; already delivered: "Too late — it was already delivered".

On every `interventionId` delete the Mac also sends the relay
`reply.injected {"interventionId", "success": false, "method": "retracted",
"detail": "Deleted — not sent"}`, so the stored page and every phone show it
as not sent. An id the Mac isn't holding gives `not_found`.

### Images (`images-v1`)

From a session's chat screen a phone can send up to 4 photos with a caption
into a Claude session. The relay doesn't change: each photo travels in pieces,
every piece its own sealed `sessions.command`, then one `inputImages` names
the photos and carries the caption. The Mac puts each photo back together,
checks it, writes it to a private temporary folder and gets it into Claude:
pasted as a path where that is measured (`attach: "image"`), else typed as a
file location (`attach: "path"`). Only the session chat sends photos in this
version: the decision sheet, notification replies, the question card and
`start` stay text only.

**When a phone offers it.** Only when the list header's `caps` has
`images-v1` and the row has `attach`. With `"path"` the phone says so before
sending ("Terminal can't paste photos — Claude gets the file's location and
opens it itself"). While the session is waiting on a prompt the room's
composer goes to "Tell it instead" (plaintext `/reply`), and the photo button
is off ("Answer the prompt first").

**What the phone sends** (the Mac checks every point again):

- Every photo is decoded and re-encoded on the phone, even a small JPEG or PNG
  that already fits: picker data carries the original bytes, GPS included,
  and those are never sent. HEIC never leaves the phone.
- JPEG (photos: quality 0.8, stepping down to 0.6, then a 1600, a 1280 and
  finally a 1024 px long edge at 0.5) or PNG (screenshots and pictures with
  transparency, when it fits; else JPEG at 0.9, then the same steps). Long edge at
  most 2000 px (Claude Code's own cap). At most 1 MiB each, 4 per message and
  2.5 MiB in all.
- The SHA-256 of each prepared photo.

**Pieces** (`imagePart`, never answered):

```json
{ "op": "imagePart", "clientId": "…", "ts": 1761300000000, "viewer": "v1", "sessionId": "…",
  "imageId": "img_0001", "index": 0, "total": 13, "bytes": 412345,
  "sha256": "<64 hex>", "mime": "image/jpeg", "data": "<standard base64 of at most 32 KiB>" }
```

- `imageId` is `[A-Za-z0-9_-]{8,64}`, unique per photo. `index` is 0-based and
  below `total` (1–32). `bytes` (1 B–1 MiB) and `sha256` are the whole photo's.
  `mime` is `image/jpeg` or `image/png`. Every piece repeats the metadata, so
  pieces may arrive in any order. A piece with any field out of range is
  ignored.
- 32 KiB of raw data per piece: base64 inside the JSON (43,692 characters),
  sealed, then base64url in the envelope. With the longest ids the Mac accepts
  (`clientId` and `viewer` 128, `sessionId` 256) the body is about 59.5 KB,
  under the Worker's 64 KiB with about 6 KB to spare. Bigger pieces don't fit.
- Upload: at most 3 piece POSTs in flight, each retried piece with a new
  `clientId`; on 429 back off and retry (the bucket refills at 2 per second); on
  503 `mac_offline` stop ("Your Mac went offline"). Send `inputImages` only
  after every piece got its 202. The phone's timeout starts with `inputImages`
  and is 30 s for it (a delivery that waits for the chips can take 12–15 s).

**The message** (`inputImages`, one `result`):

```json
{ "op": "inputImages", "clientId": "c9", "ts": 1761300000000, "viewer": "v1", "sessionId": "…",
  "text": "What's wrong with this screen?",
  "images": [ { "id": "img_0001", "sha256": "<64 hex>", "bytes": 412345, "mime": "image/jpeg" } ],
  "expectCwd": "~/projects/page", "expectTitle": "page" }
```

`text` may be empty (0–8000 characters after trimming). `images` has 1–4
distinct entries within 2.5 MiB; a malformed list is refused whole
(`attachment_invalid`), never used in part. Nothing is ever added to `input`,
so an older Mac can never type the caption and drop the photo.

**On the Mac: receiving.**

- `imagePart` keeps decryption, the ±5 minute freshness check and the enabled
  check, but skips the replay guard, and a stale or disabled piece is dropped
  without a `result`. The guard writes its whole table to disk on every id, and
  a photo's dozens of piece ids would push genuine commands' ids out while they
  are still fresh enough to replay. Pieces are idempotent instead: keyed by
  (`imageId`, `index`) inside the authenticated plaintext, a repeated identical
  piece is ignored, a conflicting one (or one whose `sessionId`, `viewer`,
  `bytes`, `sha256`, `mime` or `total` differs from the photo's other pieces)
  spoils the photo, and a photo that was handed to an `inputImages` is
  remembered for 15 minutes so its pieces can't be replayed into a new one.
  `inputImages` goes through the replay guard like every command.
- In memory only, bounded: at most 8 photos open and 6 MiB held; a photo
  expires 120 s after its last piece.
- `inputImages`: `not_found`, `target_mismatch` and the text length are
  checked first. If pieces are still missing it waits up to 3 s for them (the
  relay forwards in order over the Mac's one socket, so they are normally
  there already), then answers `attachment_missing` with their ids in
  `missing`. The phone resends those photos' pieces once and sends a new
  `inputImages` with a new `clientId`. A photo whose length or SHA-256 doesn't
  match, or that belongs to another session or viewer, is `attachment_invalid`.
- The checks (`ImageCheck`), before anything is written: JPEG (`FF D8 FF`) or
  PNG (`89 50 4E 47 0D 0A 1A 0A`) by its own first bytes (the declared `mime`
  is ignored), readable by ImageIO (its pixels are decoded once), at most 4096 px on the
  long edge and 40 megapixels, at most 8 frames, and **no GPS block** in any
  frame or in the file's own properties (ImageIO folds XMP location tags into
  the same block): a photo that still carries location data is refused ("Your
  phone sent location data with the photo, so Page didn't use it").
- Logs carry the session id prefix, the photo id prefix, piece numbers and
  sizes only: never image data, captions or paths.

**On the Mac: storage.** `<per-user temporary folder>/page-images/<session
id>/<random UUID>.jpg|png` (`/private/var/folders/…/T/` on macOS: private to
the user, no spaces). The folders are 0700 and must be real directories owned
by the user (a link there is refused); each file is created exclusively, 0600,
never through a link, and only when `inputImages` runs. Paths are canonical
(`realpath`) and must match `^/[A-Za-z0-9._/-]+\.(jpg|png)$` before they are
typed; the phone never chooses any part of one. Files go after 24 hours, a
session's folder an hour after the session ends (checked hourly), and
everything when the pairing's session key changes. A photo refused before
the paste (or the typed message, on the path route) is deleted at once. Claude Code keeps its own base64 copy in the session
transcript, so deleting Page's copy never breaks the conversation.

**Delivery** (`ImageDelivery`, on the Claude backend's injection queue, so it
never interleaves with a reply, a held message or a battery pause). First, for
both routes: the session must be live, its sessions file `idle` or `shell`
(`waiting` gives `waiting` with the page id; `busy` gives `attach_busy`,
"Claude is working — send the photo when it finishes", because whether Claude
keeps a queued message's photos is unmeasured), in front of its terminal, not
a paused Claude Squad instance, in a terminal with a photo route
(`attach_unsupported` otherwise).

Paste route (`attach: "image"`):

1. The input box must read empty (the same reading as `input`, dim
   placeholder and suggestion text ignored); otherwise `draft`.
2. The photos are written and the transcript's size is noted (0 for a session
   that hasn't written one yet).
3. Status and foreground are checked again, then **one bracketed paste**: the
   paths, one per line, then the caption (sanitised like `input`: control
   characters, ESC included, are stripped, so the caption can't end the paste
   early). Claude Code puts the chips first, so the caption never starts the
   box and a leading `/` or `!` can't start a command. A caption line that is
   itself only an absolute image path would be taken as another photo, so it
   is refused up front (`error`, "…add a word before it"). The paste is never
   empty (an empty bracketed paste makes Claude Code read the Mac's
   clipboard).
4. The box is read every 100 ms for up to 5 s. Enter only when it holds exactly
   one `[Image #n]` chip per photo and the caption (whitespace ignored, so
   wrapping doesn't matter; a long caption may show as one `[Pasted text #n +k
   lines]` placeholder). More chips than photos, other text, or an unreadable
   screen: no Enter, `failed` "Your photo and message are in Claude's input box
   at your Mac, not sent" (unless the transcript shows the message already went
   in, when someone at the Mac pressed Return first). No chip but exactly the
   pasted text: Claude took the paths as text; Enter sends it as a plain
   message and the result says so (`attached: 0`).
5. Status and foreground once more (a prompt that opened would take Enter as
   "Yes"), then Enter as its own key.
6. Within 2 s the box must empty or Claude turn busy, else the same `failed`.
7. The transcript is read forward from the noted size for up to 4 s (bounded to
   16 MB, so a multi-megabyte line is fine) for the first main-thread
   `type: "user"` record with `imagePasteIds`; its `image` blocks give
   `attached`.

Path route (`attach: "path"`): the photos are written, then the caption and
one `Photo from my phone: <path>` line per photo go through the ordinary
`input` delivery (input box required empty, refused if Claude turned busy).
Every path line starts with words because Claude Code attaches a pasted line
that is only a path, and the Return typed right after it would race the
photo loading. Claude opens the file itself with its Read tool; in Claude
Code's default permission mode that asks "Yes, allow reading from
…/page-images/<session> during this session", which reaches the phone as an
ordinary page.

Codex rows have no `attach` yet (`attachBlocker`: "Page can't send photos to
Codex yet"); its paste rules differ (one path per paste) and are unmeasured.

| Outcome | `code` / `reason` | `detail` (examples) | `attached` |
|---|---|---|---|
| Pasted and confirmed | `delivered` | "Sent 2 photos to Claude in tmux pane %3" | 2 |
| Pasted, transcript not read back in time | `delivered` | "Sent the photo to Claude in tmux pane %3 — it hasn't logged it yet" | — |
| Fewer images in the transcript | `delivered` | "Sent, but Claude received 1 of 2 photos" | 1 |
| Paths taken as text | `delivered` | "Sent, but Claude took the photo as a file location, not an image" | 0 |
| Path route | `delivered` | "Sent as a file location — Claude opens the photo itself (not attached)" | 0 |
| Pieces missing after 3 s | `refused` / `attachment_missing` | "Part of a photo didn't reach your Mac — send it again" (+ `missing`) | — |
| Hash, size, type, decode or GPS check failed | `refused` / `attachment_invalid` | the check's sentence | — |
| Terminal without a photo route | `refused` / `attach_unsupported` | why | — |
| Claude busy | `refused` / `attach_busy` | "Claude is working — send the photo when it finishes" | — |
| Prompt open / draft / ended / not in front | `waiting` / `draft` / `ended` / `not_typable` | as for `input` | — |
| Chip never shown, Enter swallowed, prompt before Enter | `failed` / `error` | "Your photo and message are in Claude's input box at your Mac, not sent" | — |

Phones show `detail` for any reason they don't know.

**Terminals** (`TerminalCatalog.attach`, which both the gate and the list's
`attach` read, and which the Mac's Terminals page shows):

| Terminal (wire host) | `attach` | Paste route | Measured |
|---|---|---|---|
| tmux (`tmux`) | `image` | `load-buffer`, then `paste-buffer -p -r` (bracketed, line feeds kept); box read with `capture-pane -e`; Enter with `send-keys` | Yes (below) |
| Claude Squad (`Claude Squad`) | `image` | the same tmux transport (its agents are tmux panes) | Through tmux only: not probed in a Squad pane |
| WezTerm (`WezTerm`) | `path` | `cli send-text` without `--no-paste` is wired | Not measured: WezTerm is not installed on the Mac the probe ran on |
| iTerm2, kitty, Herdr, cmux | `path` | kitty `send-text --bracketed-paste enable` and Herdr `pane.send_input` are wired; iTerm2's `write text` and cmux's `paste` refuse a photo paste | Not measured: they need a window |
| Terminal.app (`Terminal`) | `path` | none (`do script` adds a Return) | — |

The path route itself was run only in tmux (with the probe's `--attach path`
override, in auto permission mode). In the terminals that ship it (Terminal,
iTerm2, kitty, Herdr, cmux, WezTerm) it rides on the `input` delivery those
terminals already use, but has not been run there with a photo.

Measured with the DEBUG `--probe-image` tool (AnswerProbe.swift) against
throwaway Claude Code 2.1.312 sessions on Haiku (the bundle research behind
the design was on 2.1.311), started with user settings and hooks skipped,
inside a detached private tmux server, through the real `ImageDelivery.run`.
Photos: a 1.7 KB PNG, a 2.4 KB JPEG and two 2000×1500 noise JPEGs of 915 KB.
No real session and no window was touched.

- A single paste of a path, a line feed and a caption shows
  `[Image #1]What colour is this square? …` (the chip in the normal colour,
  directly followed by the caption); two photos show `[Image #3] [Image #4]…`.
  Chips are numbered per session. A 15-line caption shows as
  `[Image #6][Pasted text #7 +14 lines]`. A photo with no caption is just
  `[Image #5]`.
- tmux's default paste (each LF turned into a CR) kept a path followed by a
  caption as plain text: Claude Code splits a paste into lines on LF only. With
  `-r` the photo attached. So `.paste` keeps its line feeds; a one-line paste is
  still bracketed.
- A path in the temporary folder, outside the session's own folder, attached
  in both the auto and the manual (default) permission mode.
- The transcript held one `type: "user"` record with `imagePasteIds` and one
  `image` block per photo (also in a brand-new session), and Haiku named each
  square's colour correctly.
- The 915 KB photo's chip showed within about 0.15 s of the paste, through the
  catalog's own route (no override).
- An Enter sent straight after the paste (as `paste --submit` or `do script`
  would) was **not** dropped, for the 2.4 KB and for the 915 KB JPEG: the
  message went in with its image. The dropped Return the bundle reading
  predicted didn't reproduce here; Page still waits for the chip before Enter.
- Path route in tmux (auto mode): Claude read the file with Read and answered.
  In manual mode, a path that went in as text (the CR case above) made Claude
  call Read, which raised the permission prompt above.
- Not measured: whether a message typed while Claude is busy keeps its photos
  (so busy is refused), and every terminal other than tmux.

Re-run `--probe-image` whenever Claude Code updates: the paste detector, the
chip and the transcript record are Claude Code internals, not documented
interfaces.

**Compatibility.** An older Mac sends no `images-v1` and no `attach`, so no
phone offers photos; a phone that sends anyway gets nothing typed (unknown ops
are ignored) and times out. Older phones ignore `caps`, `attach`,
`attachBlocker`, `images`, `attached`, `missing` and the new reasons. Every
`sessions-v1` relay works; nothing is stored on the Worker.

**Test vector** (the §2 key and nonce, phone→Mac): an 8-byte "photo" (the PNG
signature, SHA-256 `4c4b6a3be1314ab86138bef4314dde022e600960d8689a2c8f8631802d20dab6`).

```
plaintext = {"op":"imagePart","clientId":"p1","ts":1761300000000,"viewer":"v1","sessionId":"s1","imageId":"img_0001","index":0,"total":1,"bytes":8,"sha256":"4c4b6a3be1314ab86138bef4314dde022e600960d8689a2c8f8631802d20dab6","mime":"image/png","data":"iVBORw0KGgo="}
c         = sfJ3_bSsO7l2-_M4mMyqKxe10i_Q0D61cL5j4Popm85vXQ9Hp1dfQj6dH7htBjpm-mAZLF4Zn4LmtnRVzdbV-wg5ihZiEycDG8ROltjZGvf5NleVwJxZyQAh27rd_icoECLTsVeB0dO1byIYo8XlndG-KezuqN-17JSE65Aqpgg-31jI_KaizgNnnPsfF_on_Lfg0ibBnsPwNg2xNJz4GSO8b_2SX1kn36Es7xohPMngqJBCjeKMBY9wpMiFKBeRqKqf_VIC-foBtzPDdgnuD4lX2XIMHhcC6T-z_7YqiViBEha8t23VoCHhAO6F-Bvzy8CmL9jZmO4L2Ck9rm_TTTsE1TF1_uaPBnrB-Q
```

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
| held messages: waiting per session / in all | 10 / 50 |
| held message: lifetime / retry after a passing refusal / gap after one is typed | 6 h / 5 s, +5 s per try, at most 60 s / 8 s |
| held state re-read while any is held | every 2 s (and every tick) |
| "session ended": absent from the list for | 30 s and 2 ticks |
| row `held`: entries / text / settled kept | 10 waiting + 10 settled / 200 chars / 15 min |
| photos: per message / each / in all / long edge sent | 4 / 1 MiB / 2.5 MiB / 2000 px (Mac accepts 4096 px, 40 MP) |
| photo pieces: raw size / per photo / body | 32 KiB / 32 / about 59.5 KB |
| photos held on the Mac (memory): open / bytes / expiry after last piece | 8 / 6 MiB / 120 s |
| `inputImages`: wait for pieces / caption / phone timeout | 3 s / 8000 chars / 30 s |
| photo delivery: chip wait / box clears / transcript read-back | 5 s / 2 s / 4 s (16 MB forward read) |
| photo files: kept / after the session ends / used photo ids remembered | 24 h / 1 h / 15 min |
