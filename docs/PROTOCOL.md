# Page wire protocol (v2)

This is the protocol as implemented by the relay Worker
(`Cloudflare/src/types.ts`, `logic.ts`, `durable.ts`), the Mac app
(`RelayClient.swift`, `Coordinator.swift`, the backends), the hook
(`hooks/page-notify.sh`) and the iOS app (`iOS/Page/Services/APIClient.swift`,
`Models/`). When this document and the code disagree, the code is right;
please file a bug.

v2 is a strict superset of v1. Every v2 field is optional, and no v1 field
has been renamed or removed. Older Macs, hooks, phones and Workers keep
working against newer peers (see [Compatibility rules](#15-compatibility-rules)).

## Contents

1. [Parties and transport](#1-parties-and-transport)
2. [Conventions](#2-conventions)
3. [The Intervention object](#3-the-intervention-object)
4. [Intervention ids](#4-intervention-ids)
5. [Frames](#5-frames)
6. [HTTP routes](#6-http-routes)
7. [Page lifecycle on the Worker](#7-page-lifecycle-on-the-worker)
8. [Replies and delivery confirmation](#8-replies-and-delivery-confirmation)
9. [Presence](#9-presence)
10. [Token retirement](#10-token-retirement)
11. [Phones and APNs](#11-phones-and-apns)
12. [Pairing payload](#12-pairing-payload)
13. [Close reasons](#13-close-reasons)
14. [Limits and timers](#14-limits-and-timers)
15. [Compatibility rules](#15-compatibility-rules)
16. [Live sessions](#16-live-sessions)

## 1. Parties and transport

```
 Mac app ══ WebSocket /ws (User-Agent page-mac/…) ══╗
 Hook    ── HTTPS POST /intervention, GET polls ────╫── Worker ──▶ Durable Object (one per relay token)
 Phone   ══ WebSocket /ws  +  HTTPS REST ───────────╝                   │
                                                                         └── APNs ──▶ phone
```

- **Auth.** Every request except `GET /health` (and `GET /`) carries
  `Authorization: Bearer <relayToken>`. The token is generated on the Mac (32
  random bytes, base64url, 43 characters) and handed to the phone in the
  pairing QR. The Worker answers a missing token with `401 missing_token`, and
  a token shorter than 16 or longer than 512 characters with
  `401 invalid_token`. Any other token is routed to the Durable Object named
  after it, so **the token is the only credential**, and a new token silently
  gets a new, empty relay.
- **The Mac** keeps one WebSocket per Mac (v2: one shared RelayClient for all
  backends). Its User-Agent contains `page-mac`, which is how the Worker tags
  the socket as the Mac's. A socket that sends any Mac-only frame type is also
  tagged as the Mac (legacy path).
- **The hook** never opens a socket. It POSTs frames to `/intervention` and
  polls `GET /interventions` / `GET /history`. User-Agent: `page-hook/3.0`
  (v1 scripts sent `page-hook/1.x`).
- **The phone** keeps a WebSocket for live updates and uses REST for
  everything else.
- **Keepalive.** The Mac and the phone send WebSocket control-frame pings
  every 25 s; the Mac drops the socket if no pong arrives within 10 s. For
  clients that want an application-level keepalive, the Worker also answers
  a text frame `"ping"` with `"pong"` without waking the Durable Object.

## 2. Conventions

- **Envelopes.** Every WebSocket frame and every `POST /intervention` body is
  `{"type": "<frame type>", "payload": <object>}`.
- **Timestamps.** UTC ISO 8601 with whole seconds: `"2026-10-24T12:00:00Z"`.
  Every timestamp the Worker writes uses this form, because deployed phones
  decode dates with Swift's `.iso8601` strategy, which rejects fractional
  seconds. The Worker re-emits inbound `openedAt` in this form and rewrites
  legacy millisecond timestamps during migration. Readers should still
  accept fractions (current iOS does). Internal queue and record times are ms
  epochs and never go on the wire.
- **Errors.** JSON `{"error": "<code>", …}` with an HTTP status. Responses
  carry `cache-control: no-store`.
- **Unknown fields** are ignored by every reader. The Worker builds stored
  objects field by field, so unknown or Worker-managed fields sent by a
  client are dropped, never trusted.
- **Unknown frame types** must be ignored by Macs and phones. The Mac logs
  each new one once.
- **Rejected WebSocket frames** get no error frame back. The Worker logs them
  and moves on. Only HTTP callers see the error body.

## 3. The Intervention object

An *intervention* (a "page") is one moment where an agent needs a human.

| Field | Type | Set by | Notes |
|---|---|---|---|
| `id` | string | sender | Required, 1–200 chars. See [ids](#4-intervention-ids) |
| `sessionId` | string | sender | Required, 1–200 chars. Claude session UUID, Codex thread id, or `codex-account` |
| `cwd` | string | sender | Coerced to string, ≤ 500 |
| `projectName` | string | sender | ≤ 500. Defaults to `basename(cwd)`, else `"Agent"` |
| `kind` | string | sender | See below. Unknown → `"question"` |
| `context` | string | sender | Coerced to string, truncated to 4000 chars with `…` |
| `openedAt` | timestamp | sender | Unparseable → time of receipt |
| `closedAt`, `closeReason` | timestamp, string | Worker | Set when archived. Reason ≤ 64 chars |
| `repliedAt`, `repliedText`, `repliedAction` | timestamp, string, string | Worker | The latest accepted reply. `repliedAt` and `repliedAction` are cleared when delivery fails (`repliedText` is kept) |
| `backend` | `"claude"` \| `"codex"` | sender | Missing → `codex` if the id starts with `codex-`, else `claude` |
| `source` | `terminal` \| `desktop` \| `vscode` \| `exec` \| `remote` \| `unknown` | sender | Missing → `terminal`. Unrecognised → `unknown` |
| `subtype` | string | sender | Free-form, ≤ 100. Known values: `plan`, `low_battery`; v4: `looping`, `stuck`, `workflow_stalled` (kind `idle`), `battery_forecast`, `usage_forecast` (kind `rate_limit`) |
| `promptKey` | string | sender (hook) | The agent's tool-use id for the prompt (`toolu_…`, `call_…`). Kept only if it matches `^[A-Za-z0-9_.:-]{1,200}$` |
| `deliveryStatus` | `pending` \| `delivered` \| `failed` | Worker | v2. Never trusted inbound |
| `deliveryDetail` | string | Worker | v2. Short, human, phone-safe (≤ 300) |
| `deliveryMethod` | string | Worker | v2. The `method` from `reply.injected`, or `hook` / `queue` |
| `deliveryForwardedAt` | timestamp | Worker | When the reply was handed to a Mac socket (not just queued) |
| `hookBlocking` | `true` | Worker | Marks a v1 blocking-hook page ([§7](#hook-pages)). Never trusted inbound |

Open-only fields that are read on ingest but not stored on the object:

- `holdSeconds`: number. A blocking hook's maximum wait, clamped to 5–3600.
  The Worker uses it to expire an orphaned page.

**Kinds.** The v1 vocabulary is `permission`, `plan`, `question` and `idle`.
v2 adds `approval`, `user_input` and `rate_limit`. Both vocabularies are
valid. iOS canonicalises `permission`/`plan` → approval and `question` →
user input, and decodes an unknown kind as user input. Senders keep emitting
the v1 names so old phones decode them:

| Sender emits | Means |
|---|---|
| `permission` | An approval prompt (tool call). With `subtype: "plan"`: a plan approval. The Mac sends plans as `permission` + `plan`; it never puts `plan` in `kind` |
| `question` | The agent asked something (AskUserQuestion, elicitation) |
| `idle` | The turn finished and the session waits. With `subtype: "low_battery"`: Page paused it at the battery cutoff. Codex `Stop`-hook pages are `idle` too |
| `rate_limit` | A usage limit was hit (information only). A written reply is queued and typed into the session when the limit resets (v4). With `subtype: "battery_forecast"` (session id `page-mac-battery`): the battery reaches the cutoff in about 15 min while agents work. With `subtype: "usage_forecast"` (session id `page-mac-usage`): the 5-hour limit is about 30 min away at the current pace. Both are Mac-wide, opened and closed by the Coordinator; replies are answered "nothing to answer" |
| `idle` + `subtype: "looping"` / `"stuck"` / `"workflow_stalled"` | v4 stuck watch: a busy session repeats a failing call, has written nothing for the configured time, or one of its workflows stopped making progress. A written reply is typed as a message (queued while busy); Deny on `looping`/`stuck` presses Esc (Stop). Id `<sessionId>-<subtype>-<epoch>` |

Approval-type kinds are `permission`, `plan` and `approval`. Question-type
kinds are `question` and `user_input`. Both are *blocking kinds* (the agent
is stuck until someone answers).

## 4. Intervention ids

Ids are opaque to the phone, but they carry routing meaning on the Worker and
the Mac.

| Pattern | Opened by | Reply goes to |
|---|---|---|
| `<sessionId>-<kind>-<stateStartEpoch>`, e.g. `…-permission-1761300000` (kind `permission`, `question`, `idle`) | Mac Claude detector | Mac (ClaudeBackend) |
| `<sessionId>-rate_limit-<eventEpoch>` | Mac Claude rate-limit watcher | (information only) |
| `<sessionId>-low_battery-<tripEpoch>` | Mac Coordinator (battery pause) | Mac Coordinator, which intercepts these before backend routing |
| `codex-idle-<threadId>-<turnEndEpoch>` | Mac CodexBackend | Mac (CodexBackend) |
| `codex-req-<childToken>-<requestId>` | Mac CodexBackend (approval request from its own app-server child) | Mac (CodexBackend) |
| `hook-<sid8>-<epoch>-<pid>` | Hook, Notification event (fire-and-forget) | Mac, which resolves the live session by the payload's `sessionId` (a UUID starting with `sid8`) |
| `hookpre-<sid8>-<epoch>-<pid>` | Hook, blocking event (PermissionRequest, PreToolUse, Codex Stop) | **The waiting hook.** Never forwarded to the Mac |

Rules that depend on the prefix:

- **Backend routing.** The Mac routes a reply by its `backend` field when
  present, else by prefix (`codex-` → Codex, everything else → Claude). A
  low-battery page carries the session's own backend, so a Codex one does
  *not* start with `codex-`. Route by `backend`.
- **Hook-owned ids** (`hook-`, `hookpre-`) are never closed by `sync`. The
  Mac excludes them from its `openIds`.
- **Blocking-hook ids** (`hookpre-`, plus v1 `hookBlocking` pages) are never
  superseded, cascaded or synced away. Their replies are stored for the hook
  to poll and never sent to the Mac (no `reply` frame, no queueing). The Mac
  ignores `hookpre-` replies defensively too.
- Mac ids are deterministic per session state, so after a Mac restart the
  same pages are re-sent with the same ids. The Worker treats a re-open of a
  pending id as a no-op (`{ok:true, duplicate:true}`) and ignores a re-open of
  a recently closed id ([tombstones](#7-page-lifecycle-on-the-worker)).

## 5. Frames

### Mac/hook → Worker

Sent over the Mac's WebSocket, or as the body of `POST /intervention`.

| `type` | Payload | Notes |
|---|---|---|
| `intervention.opened` | Intervention, plus optional `holdSeconds` | Validated as in [§3](#3-the-intervention-object). `400 invalid_id` / `invalid_sessionId` / `invalid_payload` on failure |
| `intervention.closed` | `{id, reason}` | `reason` defaults to `"closed"`. A close for an unknown id leaves a tombstone (except `stale`) and returns `{ok:true, unknown:true}` |
| `heartbeat` | `{ts, activeSessions, battery, onAC?, working?, forecast?, usage?}` | `battery` is 0–100, or `-1` when unknown. The Mac sends one on connect and every 15 s. v4 adds three optional fields, validated field by field (a bad one is dropped): `working` (sessions mid-turn); `forecast` `{cutoff, minutes, drainPerHour}`, the battery's time to the low-battery cutoff at the current drain (sent on battery only); `usage` `{fiveHour?: {pct, resetsAt?}, sevenDay?: {pct, resetsAt?}, hitAt?, updatedAt?}`, Claude subscription usage when the user turned on usage capture, with `hitAt` the forecast time the 5-hour limit is reached. All three are forwarded to phones and reported by `GET /status` (`forecast` only while `onAC` is false) |
| `reply.injected` | `{interventionId, method, success, detail?, output?}` | Delivery result ([§8](#8-replies-and-delivery-confirmation)). `detail` is ≤ 200 from the Mac, stored ≤ 300. `output` (diagnostic text, ≤ 2000) is **ignored by the Worker**: never stored, logged or shown |
| `sync` | `{backend: "claude"\|"codex", openIds: string[]}` | v2. The Mac's truth about which of its pages are still open. Sent per backend after connect (once the first scan has finished) and every 60 s. At most 1000 ids are read |
| `device.register` | `{apnsToken, appVersion, apnsEnv?}` | Same as the HTTP route. Phones normally use HTTP |
| `relay.retire` | `{reason?}` | v2. Sent on the **old** token when the Mac regenerates its token ([§10](#10-token-retirement)) |

Any other type: `400 unknown_type` (HTTP) or a log line (WebSocket).

The Mac ignores these frames when they arrive on its socket: `reply.result`,
`mac.status`, `heartbeat`, `sync`, `relay.retired`, `ping`, `pong`, `ack` and
any `intervention.*`.

### Worker → Mac

| `type` | Payload |
|---|---|
| `reply` | `{interventionId, text, action, sessionId, cwd, kind, backend, source?, closed?, closeReason?, promptKey?}` |

- v1 fields: `interventionId`, `text`, `action`, `sessionId`, `cwd`. v2 adds
  `kind`, `backend` and `source`. `kind`/`backend`/`source`/`promptKey` are
  captured when the reply is accepted, so a queued reply never depends on the
  page still being pending.
- `action` is `"approve"`, `"deny"`, `"carry_on"`, `"custom"` or `null`. The
  Mac treats a missing or `null` `text` as `""`.
- `closed: true` and `closeReason` appear only on **free text sent to a page
  that closed in the last 10 minutes**. The Mac must type such a reply only
  into an idle or busy session, never into a prompt that is now showing.
- `promptKey` appears only when the page's open carried one. It's never
  `null` or empty. The Mac compares it with the prompt on screen.
- The Worker sends `reply` to every open Mac socket. Older Macs held one
  socket per backend and filtered by id prefix.
- The Mac must treat the payload's `cwd` as untrusted. Current Macs resolve
  the target from their own session records.

### Worker → phone

| `type` | Payload | When |
|---|---|---|
| `intervention.opened` | Intervention | A page opened, or a shadowed page was restored |
| `intervention.closed` | `{id, reason}` | A page closed ([reasons](#13-close-reasons)) |
| `heartbeat` | `{ts, activeSessions, battery, onAC?}` | Every Mac heartbeat, forwarded |
| `reply.result` | `{interventionId, success, method, detail}` | v2. Delivery outcome of a reply (from the Mac, the hook's close, or the queue expiring) |
| `mac.status` | `{macConnected, lastHeartbeatAt?}` | v2. A Mac socket connected, or the last one closed |
| `relay.retired` | `{reason, why}` | v2. The token was retired: re-pair ([§10](#10-token-retirement)) |

Phone sockets are never sent `reply`. Macs are never sent phone-facing frames.

## 6. HTTP routes

All routes except `/health` require the bearer token. Request bodies are
limited to 256 KiB (`413 body_too_large`). Malformed JSON gets
`400 invalid_json`.

| Route | Caller | Success | Errors |
|---|---|---|---|
| `GET /health`, `GET /` | anyone | `200 {ok, service: "page-relay", time, apnsConfigured}` | none |
| `GET /ws` | Mac, phone | `101` WebSocket upgrade (hibernation API) | `426 expected_websocket_upgrade` |
| `GET /interventions` | phone, hook | `200 Intervention[]`, pending, newest `openedAt` first | |
| `GET /history?limit=N&all=1` | phone, hook | `200 Intervention[]`, closed, newest first. `limit` 1–300 (default 100). `superseded`/`evicted` closes are hidden unless `all=1` | |
| `GET /status` | phone | `200` [status object](#9-presence) | |
| `POST /reply/:id` | phone | `200 {ok: true, queued}` | see [§8](#8-replies-and-delivery-confirmation) |
| `POST /device/register` | phone | `200 {ok: true, apnsEnv}` (the environment the Worker will use) | `400 bad_request` / `missing_apnsToken` / `invalid_apnsToken` |
| `POST /device/unregister` | phone | `200 {ok: true, removed}` | `400 invalid_apnsToken` |
| `POST /intervention` | hook, older Macs | `200 {ok: true, …}` ([frame-specific extras](#post-intervention-responses)) | `400 bad_request` (not an envelope), `400 <validation code>` |

Status codes that apply to every route:

| Status | `error` | Meaning |
|---|---|---|
| `400` | `bad_request`, `invalid_json`, `bad_id`, … | Malformed request |
| `401` | `missing_token`, `invalid_token` | No bearer token, or a malformed one |
| `404` | `not_found` | Unknown path |
| `410` | `token_retired` (+ `why`) | This token was retired. **Every** route answers this, including WebSocket upgrades (whose clients often see only the status) |
| `413` | `body_too_large` | Body over 256 KiB |
| `500` | `internal_error` | Bug; logged |

`410` therefore has two meanings. Key on `error`: `gone` means that one page
closed ([§8](#8-replies-and-delivery-confirmation)), while `token_retired`
means the whole pairing is dead.

### POST /intervention responses

| Frame | Response |
|---|---|
| `intervention.opened` | `{ok:true}`. `{ok:true, duplicate:true}` if already pending. `{ok:true, ignored:"closed"}` if tombstoned. `{ok:true, pushed:false}` if stored without an alert (a blocking hook already holds the session) |
| `intervention.closed` | `{ok:true}`, or `{ok:true, unknown:true}` |
| `sync` | `{ok:true, closed: N}` |
| `relay.retire` | `{ok:true, retired:true}`. A repeat gets `410 token_retired`, which the Mac treats as success |
| others | `{ok:true}` |

## 7. Page lifecycle on the Worker

- **One current page per session (supersede).** When a page opens, the
  session's other pending pages close as `superseded`. They're archived but
  hidden from default history, and tombstoned. Blocking-hook pages are
  exempt: they never supersede *by tombstoning* and are never superseded
  (see below).
- **Cascade.** When a page closes (any reason except `stale`), the session's
  other pending non-blocking pages close as `session_resolved`.
- **Tombstones.** Every close except `stale` remembers the id for 24 h. A
  late or replayed open of that id is ignored, and a close that overtakes its
  open still wins. `stale` closes are neither archived nor tombstoned,
  because they come from the Mac's own truth and a later open from the Mac
  must work.
- **Eviction.** At most 200 pages are pending. The oldest are closed as
  `evicted`.
- **`sync`.** Closes as `stale` (not archived, not tombstoned) every pending
  page with all of the following true. The page:
  - has the frame's `backend` (missing → `claude`);
  - is not in `openIds`;
  - is not hook-owned or `hookBlocking`;
  - was received more than 30 s ago;
  - wasn't replied to in the last 2 minutes;
  - doesn't have a reply still awaiting confirmation. A delivery in flight
    (forwarded or queued, `deliveryStatus: pending`) protects the page until
    20 minutes after it was forwarded.

  Senders must not send a `sync` before their first scan has finished: an
  empty `openIds` would close every page and make them re-alert.

### Hook pages

- **Blocking-hook pages** are `hookpre-` ids, plus v1 `hookBlocking` pages:
  - The hook closes them itself. Closing with `replied` marks the stored reply
    `delivered` (method `hook`). Any other reason marks it `failed` and frees
    the page for a retry.
  - **They replace pages only while they hold.** A blocking-hook open
    archives the session's other pages as `superseded` *without* a tombstone
    and remembers them (`shadowed`, at most 10).
  - When the hook closes with `replied` or `resolved_elsewhere`, those pages
    are tombstoned. With any other reason (`timeout`, `hook_exited`,
    `hook_fallback`, `agent_exited`, `user_returned`, `hook_lost`, …) the
    agent is still blocked, so they are restored and re-alerted, along with
    any same-session page that was stored silently meanwhile. Pages aren't
    restored if the Mac closed them in the meantime, or if a newer page
    covers the session. `user_returned` restores without a sound.
- **The v1 blocking hook** is recognised only on an HTTP open with all of:
  - User-Agent `page-hook/1.x`;
  - a `hook-` id;
  - kind `permission`;
  - no `backend`.

  Such pages get `hookBlocking: true` and behave like `hookpre-`. Because that
  script turned any reply other than Deny into "allow", they accept only
  `approve`/`deny` (`422 approve_or_deny_only`).
- **Expiry.**
  - A blocking-hook page whose hook died without closing it is closed as
    `hook_lost` at `receivedAt + holdSeconds + 2 min`, or 3600 s + 2 min if
    `holdSeconds` is missing.
  - A Notification-hook page (`hook-`) is closed as `expired` 24 h after it
    arrived.
  - Both are archived and tombstoned, never cascade, and get a silent close
    push. An expired blocking page stops muting other pages immediately,
    even before the alarm closes it.

### Push decision for a new page

| Situation | Push |
|---|---|
| A non-hook page for a session that a live blocking-hook page already holds | **none** (stored and broadcast; `{pushed:false}`) |
| A blocking-hook page within 30 s of an audible alert for the same session's blocking page | **quiet** (no sound, `interruption-level: passive`) |
| Everything else | **alert** |

## 8. Replies and delivery confirmation

### POST /reply/:id

Body `{text, action}`. `text` is a string, number, boolean or null (≤ 16 000
chars). `action` is `approve`, `deny`, `carry_on`, `custom` or `null`.

| Status | Body | When |
|---|---|---|
| `200` | `{ok: true, queued}` | Accepted. `queued: true` means no Mac socket was open; the reply waits in the queue. Blocking-hook pages always answer `queued: false` (the hook polls) |
| `400` | `empty_reply` | `text` is blank and `action` is `null` or `custom`. A banner tap must never become "carry on" |
| `400` | `invalid_action`, `bad_request`, `bad_id` | Bad action, non-object body, or an id that is empty, > 200 chars or badly encoded |
| `404` | `no_such_intervention` | Never seen (not pending, archived or tombstoned) |
| `409` | `already_replied` + `repliedAt`, `deliveryStatus` | A reply is live: delivered, queued, or forwarded less than 20 min ago without a result. A lock-screen action and an in-app reply can't double-inject. After a `failed` delivery, or 20 min without an ack, a new reply is accepted. Phones treat `deliveryStatus: "pending"` as "in flight", not "answered" |
| `410` | `gone` + `why`, `closeReason`, `closedAt`, `currentId?` | The page closed. `why`: `superseded`, `expired` (closed > 10 min ago), `prompt_closed` (approve/deny/carry_on to a closed page), `session_moved_on` (the session has a newer page, `currentId`), `hook_finished` (a blocking hook already decided), `closed` (tombstone only) |
| `410` | `token_retired` + `why` | The pairing was retired |
| `413` | `reply_too_long` | `text` over 16 000 chars |
| `422` | `approve_or_deny_only` + `why` | v1 blocking-hook page, and the action isn't approve/deny. Show `why` |

Free text to a page that closed less than 10 minutes ago, whose session has
no newer page, is accepted and forwarded with `closed: true`.

On acceptance the Worker sets `repliedAt`, `repliedText`, `repliedAction`
and `deliveryStatus: "pending"`, then does one of:

- **Blocking-hook page:** stores the reply for the hook (detail "Waiting for
  the Claude Code hook to pick it up" / "…Codex hook…"). Nothing goes to the
  Mac.
- **Mac page, Mac connected:** sends `reply`, sets `deliveryForwardedAt`
  (detail "Sent to your Mac").
- **Mac page, Mac offline:** queues it (detail "Waiting for your Mac to come
  online"). The queue is flushed on the Mac's next frame (normally its
  heartbeat), oldest first, after that frame is handled, so a `sync` has
  already closed pages the Mac no longer has. A queue entry is deleted only
  once a Mac socket accepted it. A page that closed meanwhile fails the entry
  ("The page closed before your Mac came back online"). Queued replies expire
  after 1 h, or 10 min for closed-page replies ("Your Mac was offline too
  long — reply not delivered"). At most 200 are queued.

### reply.injected → reply.result

The Mac reports every delivery attempt:

```json
{ "type": "reply.injected",
  "payload": { "interventionId": "…", "method": "tmux", "success": true,
               "detail": "Approved in tmux pane %3" } }
```

- `success: true`: `deliveryStatus = "delivered"`. The Mac also closes the
  page with reason `replied`.
- `success: false`: `deliveryStatus = "failed"`. `repliedAt` and
  `repliedAction` are cleared so the user can retry, and the page stays
  pending.
- Either way the Worker broadcasts `reply.result
  {interventionId, success, method, detail}` to phones. On failure with no
  phone socket open, it also sends an alert push "Reply to <project> not
  delivered" ([§11](#11-phones-and-apns)). That happens even when the page has
  closed meanwhile.
- Missing `detail` defaults to "Delivered to your Mac" / "Your Mac couldn't
  deliver the reply".

`method` values in use:

| Method | Sender |
|---|---|
| `tmux`, `terminal_applescript`, `iterm_applescript`, `cmux`, `cmux_feed`, `claude_resume_print`, `none` | Mac, Claude replies |
| `tmux`, `terminal_applescript`, `cmux`, `codex_exec_resume`, `codex_app_server`, `none` | Mac, Codex replies |
| `battery` | Mac Coordinator, replies to low-battery pages |
| `hook` | Hook (it also posts `reply.injected` before closing), and the Worker when a blocking-hook page closes |
| `queue` | Worker, a queued reply expired or was dropped |

`detail` strings are shown to the user verbatim after "Delivered — " or
"Failed: ". Keep them short, human and free of secrets.

## 9. Presence

`GET /status`:

```json
{ "macConnected": true, "macEverSeen": true,
  "lastHeartbeatAt": "2026-10-24T12:00:00Z", "activeSessions": 3,
  "battery": 64, "onAC": false,
  "pendingCount": 1, "queuedReplies": 0, "devices": 1,
  "apnsConfigured": true, "lastPushError": "…" }
```

- `macConnected` reflects whether a Mac socket is open right now.
- `macEverSeen` is persisted. It becomes `true` the first time any Mac-side
  traffic reaches this token (a Mac socket frame, or a Mac/hook
  `POST /intervention`). `false` means no Mac has ever used this pairing
  code (a stale QR or a typo), as opposed to "the Mac is offline".
- `lastHeartbeatAt`, `activeSessions`, `battery` (omitted when unknown) and
  `onAC` come from the latest heartbeat. They're kept in memory and persisted
  at most every 5 minutes, so after the Durable Object hibernates they can be
  up to 5 minutes old.
- `lastPushError` is the last APNs failure (time, status, Apple's reason).

`mac.status` frames announce changes live. Phones treat the Mac as online if
a heartbeat arrived within 90 s. A Worker without `/status` (`404`) means
heartbeats only.

## 10. Token retirement

When the user regenerates the pairing token, the Mac sends
`{"type": "relay.retire", "payload": {"reason": "token_regenerated"}}` on the
**old** token (over its socket, or by `POST /intervention`, waiting up to
about 2 s) before switching. The Worker then:

1. Persists `retired` in its meta record. It is never cleared.
2. Deletes every pending page, queued reply and registered phone, without
   archiving and without any push, and cancels its alarm.
3. Sends phones `intervention.closed` (reason `token_retired`) for each
   dropped page, then `relay.retired {reason, why}`.
4. Closes every socket with code **4410**, reason `token_retired`.
5. From then on answers **every** request on that token with
   `410 {error: "token_retired", why: "This pairing was replaced on your Mac — scan the new QR code"}`.

Phones treat `410 token_retired` from any route, the `relay.retired` frame
and close code 4410 as "re-pair needed". The hook treats a `410` like a
rejected token: it prints nothing and the agent's own dialog shows.

History and tombstones of a retired token stay in its Durable Object's
storage. They're unreachable through the API, but not erased.

## 11. Phones and APNs

### Device registration

`POST /device/register {apnsToken, appVersion, apnsEnv?}`:

- `apnsToken` is hex (whitespace and `<>` are stripped, then lowercased; 32–200
  chars).
- `apnsEnv` is `"development"` (Xcode builds) or `"production"` (TestFlight,
  App Store). `apnsEnvironment` is accepted as an alias.
- Phones that don't send `apnsEnv` are treated as older builds:
  - the Worker uses its `APNS_ENV` default;
  - a `BadDeviceToken` is retried once on the other host, and the host that
    worked is remembered;
  - alerts use the legacy `PAGE` category.
- Up to 10 devices per token; the oldest registration is dropped beyond that.
- A device is removed on APNs `410`, or `400` with reason `BadDeviceToken`,
  `DeviceTokenNotForTopic` or `Unregistered`.
- Phones call `/device/unregister` with the old token when they unpair.

### Pushes

All pushes go to every registered device. A 403
`InvalidProviderToken`/`ExpiredProviderToken` re-mints the JWT and retries
once. Each APNs request times out after 4 s.

**Alert push** (a page opened, or a shadowed page was restored):

- Headers: `apns-push-type: alert`, `apns-priority: 10`,
  `apns-topic: <APNS_BUNDLE_ID>`,
  `apns-collapse-id: <intervention id, truncated to 64 UTF-8 bytes>`,
  `apns-expiration: now + 3600`.
- Payload:

```json
{ "aps": { "alert": { "title": "<projectName> paged you", "body": "Approval needed: …" },
           "category": "PAGE_APPROVAL", "sound": "default", "mutable-content": 1,
           "thread-id": "<sessionId>", "interruption-level": "time-sensitive", "badge": 2 },
  "interventionId": "…", "kind": "permission", "sessionId": "…", "projectName": "…",
  "interventionClosedIds": ["…"] }
```

- `aps.alert.body`: a kind prefix ("Approval needed: ", "Plan ready: ",
  "Session is waiting: ", "Rate-limited: ", or none for questions) plus the
  first 180 characters of `context`.
- `aps.category` by kind:

  | Kind | Category |
  |---|---|
  | `permission`, `plan`, `approval` | `PAGE_APPROVAL` |
  | `question`, `user_input` | `PAGE_INPUT` |
  | `idle` | `PAGE_IDLE` |
  | `rate_limit` and anything else | `PAGE_INFO` |

  Devices registered without `apnsEnv` get `PAGE` instead.
- `aps.interruption-level` is `time-sensitive` for blocking kinds and
  `active` otherwise. Quiet pushes use `passive` and have no `sound`.
- `aps.badge` is the number of pending pages after the change.
- `interventionClosedIds` appears only when the open superseded or evicted
  pages.
- Keep the title format: phones fall back to parsing "<project> paged you"
  when `projectName` is missing.

**Reply-failed push**: an alert with the same collapse id as the page, title
"Reply to <projectName> not delivered", body = the failure `detail`, the
kind's category (`PAGE_INFO` if the page has closed, because Approve/Deny on
a closed page would only get 410), plus `replyFailed: true` and the same
custom keys. It's only sent when no phone socket is open.

**Close push** (silent, when pages close):

- Headers: `apns-push-type: background`, `apns-priority: 5`.
- Payload:

```json
{ "aps": { "content-available": 1, "badge": 1 },
  "interventionClosedId": "<first id>", "interventionClosedIds": ["…", "…"] }
```

`interventionClosedId` is the v1 key. An open that supersedes or evicts pages
sends a close push too, after its alert, because there is no Notification
Service Extension: a backgrounded app never sees the alert's own
`interventionClosedIds`.

Phones match delivered banners by `userInfo.interventionId`, which also
serves as the notification's request identifier via the collapse id.

**Notification categories the phone registers:**

| Category | Actions |
|---|---|
| `PAGE_APPROVAL` | Approve, Deny, Deny with instructions (text) |
| `PAGE_INPUT` | Reply (text) |
| `PAGE_IDLE` | Reply (text), Carry on |
| `PAGE_INFO` | none |
| `PAGE` (legacy) | Approve, Deny, Reply (text). The phone refuses Approve/Deny for non-approval kinds using the payload's `kind` |

Every action requires device authentication. None opens the app.

## 12. Pairing payload

The Mac's QR code (and "Copy pairing JSON") encodes:

```json
{ "v": 1, "token": "<43-char base64url>", "relay": "https://page-relay.example.workers.dev", "host": "<Mac name>" }
```

- `relay` is always the normalised https base: never ws/wss, never a trailing
  `/ws`, never the placeholder.
- The phone requires `v == 1` and a token of at least 16 characters with no
  whitespace. It requires an https/wss relay that isn't the placeholder, and
  `GET /health` must report `service == "page-relay"`. It then probes
  `GET /status` with the token: 401/403 means the token was rejected, and
  `macEverSeen: false` gets a warning.

## 13. Close reasons

Unknown reasons are passed through (≤ 64 chars). Clients should show a
generic label for anything new.

| Reason | From | Meaning |
|---|---|---|
| `superseded` | Worker | A newer page for the session replaced it (hidden from default history) |
| `evicted` | Worker | Over 200 pending; the oldest went (hidden from default history) |
| `session_resolved` | Worker, Mac | Another page of the session was resolved (cascade), or the session/limit ended |
| `stale` | Worker (`sync`), Mac | The Mac no longer has it. Not archived. The Mac also uses it when Codex is disabled |
| `hook_lost` | Worker | Blocking-hook page whose hook died |
| `expired` | Worker | Notification-hook page older than 24 h |
| `token_retired` | Worker | Token retired. Sent once to connected phones, not archived |
| `replied` | Mac, hook | The reply was delivered (Mac), or the hook read it and printed the decision |
| `user_resolved_in_terminal` | Mac | The prompt was answered at the Mac |
| `resolved_elsewhere` | hook | The prompt was answered at the Mac or by another hook |
| `user_returned` | hook | The user touched the Mac; the dialog takes over |
| `timeout` | hook | No reply within the hook's wait |
| `agent_exited` | hook | The agent process went away mid-wait |
| `too_late` | hook | The reply arrived too close to the agent's hook timeout to apply safely |
| `not_a_decision`, `hook_fallback`, `hook_exited` | hook | The reply wasn't a decision, the hook gave up for another reason, or the hook was killed |

## 14. Limits and timers

| What | Value | Where |
|---|---|---|
| id / sessionId length | 1–200 | Worker |
| context | 4000 chars (Mac detector context ≤ 1500, hook ≤ 3500) | Worker / senders |
| cwd, projectName | 500 | Worker |
| subtype / close reason | 100 / 64 | Worker |
| reply text | 16 000 | Worker |
| `reply.injected` detail | 200 sent / 300 stored | Mac / Worker |
| request body | 256 KiB | Worker |
| pending pages | 200 | Worker |
| history | 300 (no time limit) | Worker |
| reply queue | 200 entries, 1 h TTL (10 min for closed-page replies) | Worker |
| tombstones | 24 h, max 2000 | Worker |
| devices per token | 10 | Worker |
| closed-page free-text window | 10 min | Worker |
| sync grace: newly received / replied / unacknowledged delivery | 30 s / 2 min / 20 min after forward | Worker |
| delivery ack timeout (409 stops blocking a retry) | 20 min | Worker, iOS |
| blocking-hook expiry | `holdSeconds` (5–3600, default 3600) + 2 min | Worker |
| Notification-hook page expiry | 24 h | Worker |
| hook push dedupe window | 30 s | Worker |
| presence persistence | every 5 min | Worker |
| APNs request timeout / alert expiration | 4 s / 1 h | Worker |
| Mac heartbeat / sync / ping | 15 s / 60 s / 25 s | Mac |
| Mac outbound queue | 200 frames, coalesced | Mac |
| phone "Mac online" threshold | heartbeat within 90 s | iOS |
| hook default wait / installed agent timeout | 540 s / 570 s (wait ends ≥ 30 s before the timeout) | hook |
| headless resume timeout | 15 min | Mac |
| `sessions.update` payload (serialised) | 256 KiB | Worker |
| `POST /sessions/command` body | 64 KiB (`413 too_large`) | Worker |
| `sessions.command` rate | 120 per minute per relay (in-memory token bucket, `429 rate_limited`) | Worker |
| sessions envelope nonce `n` | ≤ 64 chars | Worker |

## 15. Compatibility rules

- **Never remove or rename a field.** Add fields only as optional.
- **Readers ignore unknown fields and unknown frame types.** Phones show a
  generic label for unknown close reasons and decode an unknown kind as user
  input.
- **Kinds.** Senders keep emitting the v1 kind names. Plans are
  `permission` + `subtype: "plan"`.
- **Defaults on ingest.** Missing `backend` → inferred from the id prefix.
  Missing `source` → `terminal`. Unknown `kind` → `question`.
- **Old Macs** never send `sync` (no stale closing happens), `relay.retire`
  (their tokens behave as before) or `detail` (default detail strings are
  used). Two-socket Macs still get every `reply` (broadcast to all Mac
  sockets) and filter by prefix.
- **Old phones** don't send `apnsEnv`. They get the legacy `PAGE` category
  and host learning. They ignore HTTP status codes, so refusals are silent
  drops on those builds, which is the safe failure.
- **Old hooks** (`page-hook/1.x`) are handled by the `hookBlocking` rule.
  Their Notification pages still go to the Mac.
- **Legacy storage.** A Durable Object written by the pre-v2 Worker
  (a single `state.v1` blob) is migrated on first load to per-record keys,
  with timestamps rewritten to whole seconds. A reply that was forwarded but
  never confirmed is marked failed rather than left to return 409 forever.
- **Timestamps.** Write whole seconds; read with or without fractions.
- **Wrangler migrations are append-only.** Never rename the `UserRelay` class
  or edit the `v1` migration tag.

## 16. Live sessions

The **Active sessions** view (`sessions-v1`) is specified in
[SESSIONS-PROTOCOL.md](SESSIONS-PROTOCOL.md), including its crypto envelope,
plaintext kinds and the Mac's input gate. It changes nothing above. The
Worker only relays opaque envelopes `{"v":1,"n":"<b64url>","c":"<b64url>"}`:
it never decrypts them, never stores them (zero storage writes, no APNs) and
logs only their size.

| Direction | Frame / route | Worker behaviour |
|---|---|---|
| Mac → Worker (WS) | `sessions.update` `{e}` | Mac sockets only. Unlike older Mac frames it never tags an untagged socket as the Mac: from an untagged socket it's refused and dropped. Over `POST /intervention` it gets `403 mac_socket_only`. Checks `e.v == 1` and that `n`/`c` are base64url strings, rebuilds `{v, n, c}`, broadcasts to phone sockets only. Doesn't flush the reply queue or set `macEverSeen` |
| Worker → phone (WS) | `sessions.update` `{e}` | As above. Never sent to Macs |
| Phone → Worker | `POST /sessions/command` `{e}` | `202 {ok:true}`: forwarded as `sessions.command` `{e}` to every Mac socket. `503 mac_offline` with no Mac socket (never queued), `400 invalid_envelope` (bad shape) / `invalid_json`, `413 too_large`, `429 rate_limited`, `410 token_retired` |
| Worker → Mac (WS) | `sessions.command` `{e}` | Never sent to phones |
| Worker → Mac (WS) | `phones.status` `{phones}` | When a Mac socket connects (or a legacy socket is tagged as the Mac), and when a phone socket opens, closes or errors. `phones` counts open, non-Mac sockets from `state.getWebSockets()`, so it's right after hibernation |
| `GET /status` | `features: ["sessions-v1"]` | Lets the phone tell "relay too old" from "no sessions" |

Check order for `POST /sessions/command`: size (413), JSON and shape (400),
Mac online (503), rate (429). Oversized, malformed and Mac-offline commands
don't use up the rate budget. The bucket lives in
memory, so it starts full again after the object hibernates.
Phone-originated types (`sessions.command`, `phones.status`) are not Mac
frame types: a phone sending them over its socket is ignored (logged and
dropped) and never tagged as the Mac.
