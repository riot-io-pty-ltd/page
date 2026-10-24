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
    "host": "cmux" | "tmux" | "Terminal" | "iTerm" | "Ghostty" | "VS Code" | "desktop" | "unknown",
    "canType": true,
    "typeBlocker": "Page can't type into Ghostty yet",
    "canInterrupt": true,
    "provider": "anthropic" | "ollama" | "lmStudio" | "otherLocal" | "cloudGateway" | "unknown",
    "lastActivityAt": "2026-10-24T12:00:00Z",
    "interventionId": "<open page id, if any>",
    "preview": "Running the test suite…"
  } ] }
```

- `cwd` is home-abbreviated. `preview` is at most 160 characters and
  redacted, giving the current activity: the last tool-call one-liner while
  `active`, otherwise the last assistant line.
- `typeBlocker` is present only when `canType` is false.
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

### `result`

```json
{ "kind": "result", "boot": "…", "seq": 14, "ts": …, "clientId": "…", "ok": true,
  "code": "delivered|queued|refused|failed",
  "reason": "waiting|unknown_state|not_typable|draft|digit_while_busy|ended|codex_mid_turn|disabled|stale|replay|not_found|interrupt_unsupported|error",
  "detail": "Typed into cmux", "interventionId": "<when reason == waiting>" }
```

`detail` is a short sentence the user sees, at most 200 characters. It never
contains secrets or terminal output.

## 5. Phone → Mac: `sessions.command` plaintext ops

Every op carries `clientId` (UUID, unique per command), `ts` (ms epoch,
phone clock) and `viewer` (a random id per app install, persisted).

| op | Fields | Mac behaviour |
|---|---|---|
| `watch` | `sessionId` (string, or null to stop viewing) | Sets the viewer's watched session (one per viewer) with a 90 s TTL. The phone re-sends it every 30 s while the detail screen is visible, and sends null when leaving it. Sends a `transcript` immediately. No `result` is sent. |
| `refresh` | — | Sends a `list` now, plus the `transcript` for this viewer's watched session. No `result`. |
| `input` | `sessionId`, `text` (1–8000 characters after trimming) | Runs the input gate, then delivers. Always replies with a `result`. |
| `interrupt` | `sessionId` | Presses Esc in the session (`sendInterrupt`). Only when `canInterrupt` and state is `active`. Always replies with a `result`. |

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
| input text | 8000 chars (phone 8000, Worker body 64 KiB) |
| `sessions.update` payload at the Worker | 256 KiB |
| list throttle / liveness refresh | 1 s / 20 s |
| transcript throttle | 1.5 s per session |
| watch TTL / phone re-send | 90 s / 30 s |
| command freshness / replay window | ±5 min / 15 min, 2000 ids |
| phone result timeout | 20 s |
| Worker command rate | 120 per minute per relay |
