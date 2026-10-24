# Page Relay — Cloudflare Worker

The relay between the **Page** Mac app (menu bar, `Sources/ClaudePowerMode`), the optional Claude Code hook (`hooks/page-notify.sh`) and the **Page** iOS app. Built on Cloudflare Workers + Durable Objects + APNs HTTP/2.

## What it does

- **One Durable Object per relay token.** The token is generated on your Mac and shared with your iPhone via the pairing QR. Each (Mac, iPhone) pair gets its own DO instance, isolated from everyone else's. Tokens shorter than 16 characters are refused with `401 invalid_token`.
- **Holds WebSockets from the Mac and the phone.** The Mac (User-Agent `page-mac/…`) sends interventions, heartbeats, reply results and `sync` frames; the phone receives live updates.
- **REST for the phone and the hook.** See [Routes](#routes).
- **Pushes via APNs HTTP/2** to every registered phone, signing an ES256 JWT with your `.p8` key. Each phone says whether its token is for the development or production APNs host.
- **Buffers replies while the Mac is offline** — up to 200, each for at most an hour, then the phone is told the reply wasn't delivered.

## File map

```
Cloudflare/
  wrangler.toml       Worker + Durable Object binding config
  package.json        Wrangler, types, scripts (typecheck, test, deploy)
  tsconfig.json
  src/
    index.ts          Auth (bearer token), /health, routing to the DO
    durable.ts        UserRelay Durable Object: storage, sockets, routes
    logic.ts          Pure decision logic: validation, reply gating, sync, push payloads
    apns.ts           APNs HTTP/2 client, ES256 JWT minting, .p8 parsing
    types.ts          Wire types
  test/               node:test suites run against src/ with an in-memory DO shim
```

## Routes

All routes except `/health` need `Authorization: Bearer <relayToken>`. Every response is JSON; errors are `{ "error": "<code>", … }`.

**Retired tokens.** Once a token has been retired (see [Token retirement](#token-retirement)), *every* request on it — each route below, a WebSocket upgrade, an unknown path — is answered `410 {"error": "token_retired", "why": "This pairing was replaced on your Mac — scan the new QR code"}`. Only `/health` (which never reaches the token's Durable Object) still answers `200`. `410` therefore has two meanings: clients must key on `error` — `gone` (that one page closed, see [Replies](#replies)) vs `token_retired` (the whole pairing is dead: re-pair).

| Route | Who | What |
|---|---|---|
| `GET /health` | anyone | `{ok, service, time, apnsConfigured}` — no per-user data |
| `GET /ws` | Mac, phone | WebSocket upgrade (hibernation API). On a retired token the upgrade gets `410`; WebSocket clients (e.g. `URLSessionWebSocketTask`) usually see only the status, not the body, so treat HTTP 410 on `/ws` as `token_retired` without parsing JSON |
| `GET /interventions` | phone, hook | Pending interventions, newest first |
| `GET /history?limit=N&all=1` | phone, hook | Closed interventions, newest first. `limit` 1–300 (default 100). Bookkeeping closes (`superseded`, `evicted`) are hidden unless `all=1` |
| `GET /status` | phone | Mac presence: `{macConnected, macEverSeen, lastHeartbeatAt?, activeSessions?, battery?, onAC?, pendingCount, queuedReplies, devices, apnsConfigured, lastPushError?}`. `macEverSeen` is `false` until any Mac-side traffic (a Mac socket frame, or a Mac/hook `POST /intervention`) has reached this relay token; it is persisted. `false` means no Mac has ever used this pairing code (a stale QR screenshot, a typo), as opposed to "the Mac is offline" |
| `POST /reply/:id` | phone | `{text, action}` — see [Replies](#replies) |
| `POST /device/register` | phone | `{apnsToken, appVersion, apnsEnv?}` — `apnsEnv` is `"development"` or `"production"`; missing → `APNS_ENV` (and learned from Apple's answer) |
| `POST /device/unregister` | phone | `{apnsToken}` → `{ok, removed}` |
| `POST /intervention` | hook | A Mac-style frame (`{type, payload}`) over HTTPS; `400` on a malformed frame |

## Wire protocol

All v2 additions are optional, so older Macs, phones and hooks keep working.

### Mac → Worker (WebSocket frames, or `POST /intervention`)
```json
{ "type": "intervention.opened", "payload": Intervention }
{ "type": "intervention.closed", "payload": { "id": "...", "reason": "..." } }
{ "type": "heartbeat",           "payload": { "ts": "...", "activeSessions": N, "battery": N, "onAC": bool } }
{ "type": "reply.injected",      "payload": { "interventionId": "...", "method": "...", "success": bool, "detail": "short, human" } }
{ "type": "sync",                "payload": { "backend": "claude|codex", "openIds": ["..."] } }
{ "type": "device.register",     "payload": { "apnsToken": "...", "appVersion": "...", "apnsEnv": "..." } }
{ "type": "relay.retire",        "payload": { "reason": "token_regenerated" } }
```

`battery` is `-1` when unknown. `reply.injected`'s legacy `output` field is ignored — never stored, logged or shown.

**Ingest validation** (`intervention.opened`): `id` and `sessionId` must be non-empty strings ≤ 200 chars (else `400`). Unknown `kind` → `"question"`. `context` is coerced to a string and truncated to 4000 chars; `cwd`/`projectName` to 500. `openedAt` must parse as a date (else now). Unknown fields and Worker-managed fields (`repliedAt`, `deliveryStatus`, `hookBlocking`, …) are dropped.

Optional on a blocking hook's open: `holdSeconds` — the longest the hook will wait for the phone (5–3600). The Worker uses it to expire the page if the hook dies without closing it (see *Hook pages expire*).

Optional on any open: `promptKey` — the prompt the page is about, as the agent's tool_use id. The hook sends the event's `tool_use_id` (PermissionRequest / PreToolUse) when it has one, else the last tool call in the Claude transcript tail that has no `tool_result` yet (Notification pages; omitted when nothing is pending, e.g. idle). Kept only if it matches `^[A-Za-z0-9_.:-]{1,200}$`, stored on the Intervention as `promptKey`, and echoed to the Mac in the `reply` frame (see *Worker → Mac*), so the Mac can check the prompt on screen is still the one the user answered. Detector pages don't send it (the Mac keeps its own).

**The v1 blocking hook.** The original hook script (User-Agent `page-hook/1.x`) was a blocking PreToolUse hook that opened `hook-…` pages and polled `GET /interventions` for `repliedAction` itself. A `POST /intervention` open with that User-Agent, a `hook-` id, kind `permission` and no `backend` is stored with `hookBlocking: true` and treated exactly like a `hookpre-` page (its Notification pages, kind `question`, are not: the Mac still delivers those). Because that script turns any reply other than Deny into "allow", these pages accept only `approve` and `deny` (`422 approve_or_deny_only` otherwise).

**Lifecycle rules:**
- **Supersede:** a new page for a session closes the session's older pages (`superseded`, archived but hidden from history).
- **Cascade:** closing a page closes the session's other pages (`session_resolved`).
- **Tombstones:** closed ids are remembered for 24 h, so a late or replayed open (or a close that overtook its open) can't resurrect a page.
- **`sync`:** closes (reason `stale`, not archived, not tombstoned) every pending page of that backend whose id isn't in `openIds` — except hook-owned ids (`hook-`, `hookpre-`), pages replied to in the last 2 minutes, pages whose reply is still being delivered (forwarded or queued, until 20 minutes after it was handed to the Mac), and pages received in the last 30 s.
- **Blocking-hook pages** (`hookpre-…`, and v1 `hookBlocking` pages) are never superseded, cascaded or synced away; the hook closes them itself. Replies to them are stored for the hook to poll, never sent to the Mac. Closing with `replied` marks the reply delivered; any other reason marks it failed (and pushes "not delivered" to a backgrounded phone).
- **A blocking-hook page replaces a page, but only while it holds.** Its open archives the session's other pages (`superseded`) *without* a tombstone. If the hook then closes with `replied` or `resolved_elsewhere`, they are tombstoned as usual. With any other reason (`timeout`, `hook_exited`, `hook_fallback`, `agent_exited`, `user_returned`, `hook_lost`, …) the agent is still blocked on that prompt and the Mac won't page it again, so they are put back (unless the Mac closed them meanwhile or a newer page covers the session) and alerted again — together with any same-session page that was stored silently while the hook held the session. `user_returned` restores without a buzz.
- **Hook pages expire.** A blocking-hook page whose hook died without closing it (lost open response, failed close, SIGKILL) is closed as `hook_lost` once `receivedAt + holdSeconds + 2 min` has passed (3600 s + 2 min without `holdSeconds`); past that point it stops muting the session's other pages at once, even before the alarm closes it. A Notification-hook page (`hook-…`, nothing else ever closes it) is closed as `expired` 24 h after it arrived. Both are archived and tombstoned, never cascade, and get a silent close push.

### Worker → Mac
```json
{ "type": "reply", "payload": { "interventionId": "...", "text": "...", "action": "approve|deny|carry_on|custom|null",
                                "sessionId": "...", "cwd": "...", "kind": "...", "backend": "claude|codex", "source": "...",
                                "closed": true, "closeReason": "...", "promptKey": "toolu_…" } }
```
`closed`/`closeReason` appear only on free text sent to a page that closed in the last 10 minutes; the Mac should type it only into an idle or busy session, never into a prompt. `promptKey` appears only when the page's open carried one (queued replies keep it); it is never `null` or empty.

### Worker → phone (WebSocket frames)
```json
{ "type": "intervention.opened", "payload": Intervention }
{ "type": "intervention.closed", "payload": { "id": "...", "reason": "..." } }
{ "type": "heartbeat",           "payload": { "ts": "...", "activeSessions": N, "battery": N, "onAC": bool } }
{ "type": "reply.result",        "payload": { "interventionId": "...", "success": bool, "method": "...", "detail": "..." } }
{ "type": "mac.status",          "payload": { "macConnected": bool, "lastHeartbeatAt": "..." } }
{ "type": "relay.retired",       "payload": { "reason": "token_regenerated", "why": "This pairing was replaced on your Mac — scan the new QR code" } }
```
Text `"ping"` is answered with `"pong"` without waking the Durable Object. Phones should ignore frame types they don't know.

### Close reasons

`intervention.closed` frames, archived history entries (`closeReason`) and tombstones use these. Unknown reasons are passed through (truncated to 64 chars), so clients should show a generic label for anything new.

| Reason | From | Meaning |
|---|---|---|
| `superseded` | Worker | A newer page for the same session replaced it (hidden from default history) |
| `evicted` | Worker | More than 200 pages pending; the oldest went (hidden from default history) |
| `session_resolved` | Worker | Another page of the session was resolved (cascade) |
| `stale` | Worker (`sync`) | The Mac no longer has it; not archived |
| `hook_lost` | Worker | A blocking-hook page whose hook died without closing it (see *Hook pages expire*) |
| `expired` | Worker | A Notification-hook page older than 24 h |
| `token_retired` | Worker | The token was retired; sent once to connected phones, not archived |
| `replied` | hook | The blocking hook read the reply and printed the decision (delivery confirmed) |
| `resolved_elsewhere` | hook | The prompt was answered at the Mac (or by another hook) |
| `user_returned` | hook | The user touched the Mac; the dialog takes over (restored pages don't buzz) |
| `timeout` | hook | No reply within the hook's wait |
| `agent_exited` | hook | The agent process went away mid-wait |
| `too_late` | hook | A reply arrived too close to the agent's hook timeout to apply safely |
| `not_a_decision`, `hook_fallback`, `hook_exited` | hook | The reply wasn't a decision / the hook gave up for another reason / the hook was killed |
| others (`resolved`, `user_resolved_in_terminal`, …) | Mac | The Mac's own reasons |

## Token retirement

When the user regenerates the pairing token on the Mac, the Mac sends, on the **old** token (its socket, or `POST /intervention`), `{"type": "relay.retire", "payload": {"reason": "token_regenerated"}}` before switching to the new one. The Worker then:

1. persists `meta.retired = true` (it survives hibernation and is never cleared) and answers the frame `200 {ok: true, retired: true}`;
2. drops every pending page, queued reply and registered phone, without archiving and without any APNs push (nothing may go out for a dead pairing), and cancels the alarm;
3. sends each connected phone `intervention.closed` (`token_retired`) for every dropped page, then `relay.retired` with the `why` text;
4. closes every socket (Mac and phone) with code **4410** / reason `token_retired`, so a phone reconnects straight into the `410` instead of keeping a socket the ping auto-response makes look healthy;
5. from then on answers every request on that token with `410 token_retired` (see [Routes](#routes)), WebSocket upgrades included. A repeated `relay.retire` also gets `410 token_retired`, which the Mac should treat as success.

Phones treat `410 token_retired` from any endpoint, the `relay.retired` frame and close code 4410 as "re-pair needed". The hook treats a `410` on its open or poll like a rejected token: it prints nothing (the agent's own dialog shows). Older Macs never send `relay.retire`; their tokens behave as before.

## Replies

`POST /reply/:id` with `{text, action}`:

| Status | Body | When |
|---|---|---|
| `200` | `{ok: true, queued}` | Accepted. `queued: true` means the Mac is offline; it's delivered when the Mac reconnects |
| `400` | `empty_reply` | `text` is blank and `action` is `null`/`custom` (a banner tap must never become "carry on") |
| `400` | `invalid_action`, `bad_request` | `action` not one of approve/deny/carry_on/custom/null; body not an object |
| `404` | `no_such_intervention` | Never seen this id |
| `409` | `already_replied` | A reply is already in flight or delivered (lock-screen action + in-app reply can't double-inject). Allowed again after a failed delivery |
| `410` | `gone` + `why`, `closeReason`, `closedAt`, `currentId?` | The page closed: superseded, a decision (approve/deny/carry_on) on a closed prompt, closed more than 10 minutes ago, or the session already has a newer page (`currentId`) |
| `410` | `token_retired` + `why` | The pairing token was retired (see [Token retirement](#token-retirement)) — re-pair |
| `413` | `reply_too_long` | Over 16 000 characters |
| `422` | `approve_or_deny_only` + `why` | A v1 blocking-hook page (`hookBlocking`) got something other than Approve or Deny; show `why` |

Each intervention carries `deliveryStatus` (`pending` → `delivered` | `failed`), `deliveryDetail` and `deliveryMethod`. When the Mac reports a failure the Worker clears `repliedAt` (so the user can retry), broadcasts `reply.result`, and — if no phone socket is connected — sends an alert push "Reply to <project> not delivered". That push also goes out when the page has already closed (a reply from a lingering lock-screen banner, a queued reply whose page closed before the Mac came back); for a closed page it uses the action-less `PAGE_INFO` category.

## APNs

- **Alert push** when a page opens, to every registered phone. Headers `apns-collapse-id: <intervention id>` and `apns-expiration: now + 1 h`. Payload `aps.thread-id = sessionId`, `aps.category` by kind (`PAGE_APPROVAL`, `PAGE_INPUT`, `PAGE_IDLE`, `PAGE_INFO`), `interruption-level` `time-sensitive` for approvals and questions (needs the Time Sensitive entitlement on iOS) and `active` otherwise. Custom keys `interventionId`, `kind`, `sessionId`, `projectName` (so the phone needn't parse it out of the title), and `interventionClosedIds` for pages this one superseded or evicted.
- **Reply-failure push**: alert, same collapse id as the page, title "Reply to <project> not delivered", custom keys `interventionId`, `kind`, `sessionId`, `projectName`, `replyFailed: true`.
- **Silent push** (`content-available: 1`, priority 5) when pages close: `interventionClosedId` (first id) and `interventionClosedIds` (all), so the phone can remove their banners. An open that supersedes or evicts pages sends one too (after its alert), with the same ids as the alert's `interventionClosedIds`: there is no Notification Service Extension, so a backgrounded app never sees the alert's own keys.
- **Badge:** alert pushes, reply-failure pushes and close pushes carry `aps.badge` = the number of pending pages after the change, so the app badge follows the inbox while the app is suspended.
- **Device hygiene:** a device is removed on `410`, or `400` `BadDeviceToken` / `DeviceTokenNotForTopic`. For phones that didn't send `apnsEnv`, a `BadDeviceToken` is first retried on the other host and the working environment is remembered.
- **Older phones** (no `apnsEnv` at registration) only know the legacy `PAGE` category, so their alerts keep using it.

## Storage

Per-record keys in the DO's storage (no single value can outgrow the value limit): `p:<id>` pending, `h:<inverted-ms>:<id>` history (capped at 300, newest first), `hx:<id>` history index, `q:<ms>:<id>` reply queue, `dev:<token>` devices, `tomb:<id>` tombstones, `meta` counters and the last persisted presence. Heartbeats live in memory and are written at most every 5 minutes. A relay created by an older Worker (single `state.v1` blob) is migrated automatically on first load, then the blob is deleted. `meta.macEverSeen` records that a Mac has used this token (see `GET /status`); `meta.retired` (+ `retiredAt`, `retiredReason`) marks a retired token. An alarm expires queued replies, closes expired hook pages and sweeps tombstones.

## Deploy

### 1. Install deps + log in
```sh
cd Cloudflare
npm install
npx wrangler login          # one-time browser auth
```

### 2. Gather what Apple needs
From `developer.apple.com`:
- **APNs Auth Key** (`.p8` file) — Keys → `+` → "Apple Push Notifications service (APNs)" → download once and keep safe.
- **Key ID** — the 10-char identifier shown next to the key.
- **Team ID** — Membership → Team ID (10-char).

### 3. Set the secrets
```sh
# Pipe the file — an interactive paste can keep only the first line.
cat AuthKey_XXXXXXXXXX.p8 | npx wrangler secret put APNS_KEY_P8
npx wrangler secret put APNS_KEY_ID      # 10-char Key ID
npx wrangler secret put APNS_TEAM_ID     # 10-char Team ID
```

The non-secret `APNS_BUNDLE_ID` and `APNS_ENV` live in `wrangler.toml`. `APNS_ENV` is only the default for phones that don't report their environment: `development` for Xcode debug builds, `production` for TestFlight, Ad Hoc and App Store builds. Without the secrets the relay still works over WebSocket; it just can't push.

### 4. Deploy
```sh
npm run deploy              # typecheck + tests, then wrangler deploy
```

Wrangler prints your URL, e.g. `https://page-relay.<your-subdomain>.workers.dev`. Health-check it:

```sh
curl https://page-relay.<your-subdomain>.workers.dev/health
# {"ok":true,"service":"page-relay","time":"…","apnsConfigured":true}
```

### 5. Point the Mac + iOS clients at your Worker

**Mac:** in Preferences (or `~/Library/Application Support/ClaudePowerMode/config.json`), set `relayURL` to your Worker's WebSocket URL, `wss://page-relay.<your-subdomain>.workers.dev/ws`, then Reload Config.

**iOS:** the pairing QR carries the relay URL from the Mac config. Re-scan after changing it.

## Local dev & tests

```sh
npm run typecheck
npm test                    # node --test against src/ (Node ≥ 22.18 strips the TS types itself);
                            # test/hook.test.mjs also runs ../hooks/page-notify.sh end to end
                            # (temp HOME, fake ioreg, relay on 127.0.0.1; skipped without bash/jq/curl)
npx wrangler dev            # http://localhost:8787, ws://localhost:8787/ws
```

`wrangler dev` still talks to Apple's real APNs hosts, so pushes arrive for real from local.

## Troubleshooting

- **No pushes:** `curl …/health` → `apnsConfigured: false` means a secret is missing. Otherwise `GET /status` (with your token) shows `devices` and `lastPushError`, and `npx wrangler tail` / the dashboard's Logs show every APNs failure with Apple's reason.
  - `BadDeviceToken` — the token is for the other APNs environment (Xcode build vs TestFlight). Current phones report it; for older ones set `APNS_ENV`.
  - `DeviceTokenNotForTopic` — `APNS_BUNDLE_ID` doesn't match the app's bundle id.
  - `InvalidProviderToken` — wrong `APNS_KEY_ID`/`APNS_TEAM_ID`, or the key was revoked.
  - `key_error: … SEC1 "EC PRIVATE KEY"` — upload the original `.p8` (PKCS#8), or convert with `openssl pkcs8 -topk8 -nocrypt -in key.pem -out AuthKey.p8`.
  - `key_error: … not valid base64` — the secret was truncated by a paste; pipe the file as above.
- **Phone says the Mac is offline:** `GET /status` → `macConnected` reflects the Mac's WebSocket right now; `lastHeartbeatAt` is when it last spoke.
- **Reply refused with 410 `gone`:** the page closed or moved on before the reply arrived — answer the newer page (`currentId`) instead.
- **Everything answers 410 `token_retired`:** the token was regenerated on the Mac — scan the new QR code.
- **`401 invalid_token`:** the token in the request is shorter than 16 characters — re-pair the phone.

## Costs

For one person (a handful of pages a day) this fits in Cloudflare's free plan, which includes SQLite-backed Durable Objects: Workers 100 000 requests/day; Durable Objects roughly 100 000 requests/day and 13 000 GB-s of duration/day. Hibernating WebSockets and the in-memory heartbeat keep duration low. Workers Paid includes far more (1M DO requests and 400 000 GB-s a month).

## Not done here (on purpose)

- **No account system.** The relay token is the auth. For multi-user, verify a JWT in `index.ts` and key DOs by the verified subject.
- **No long-term storage.** History keeps the last 300 closes; nothing else is retained.
- **No web dashboard.** Use `GET /status`, `/interventions` and `/history` with curl.
