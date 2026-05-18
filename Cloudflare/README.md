# Page Relay — Cloudflare Worker

The bidirectional relay that sits between **ClaudePowerMode** (your Mac) and the **Page** iOS app. Built on Cloudflare Workers + Durable Objects + APNs HTTP/2.

## What it does

- **One Durable Object per relay token.** The token is generated on your Mac and shared with your iPhone via the pairing QR. Each (Mac, iPhone) pair gets its own DO instance, isolated from everyone else's.
- **Holds a persistent WebSocket from your Mac.** Inbound messages: `intervention.opened`, `intervention.closed`, `heartbeat`, `reply.injected`. Outbound: `reply`.
- **REST endpoints for your iPhone.** `GET /interventions`, `POST /reply/:id`, `POST /device/register`.
- **Pushes via APNs HTTP/2.** Signs an ES256 JWT with your `.p8` auth key, posts to `api.development.push.apple.com` (or production for App Store builds).
- **Buffers replies when the Mac is offline.** Up to 200 queued; delivered on next WS reconnect.

## File map

```
Cloudflare/
  wrangler.toml       Worker + Durable Object binding config
  package.json        Wrangler + types
  tsconfig.json
  src/
    index.ts          Auth, routing
    durable.ts        UserRelay Durable Object
    apns.ts           HTTP/2 APNs client + ES256 JWT minting
    types.ts          Shared TypeScript types
```

## Deploy

### 1. Install deps + log in
```sh
cd Cloudflare
npm install
npx wrangler login          # one-time browser auth
```

### 2. Gather what Apple needs
You'll need from `developer.apple.com`:
- **APNs Auth Key** (`.p8` file) — Keys → `+` → "Apple Push Notifications service (APNs)" → download once and keep safe.
- **Key ID** — the 10-char identifier shown next to the key.
- **Team ID** — Membership → Team ID (10-char).

### 3. Set the secrets
```sh
# Paste the full contents of AuthKey_XXXXXXXXXX.p8 (BEGIN/END lines included).
npx wrangler secret put APNS_KEY_P8

# Paste the 10-char Key ID:
npx wrangler secret put APNS_KEY_ID

# Paste the 10-char Team ID:
npx wrangler secret put APNS_TEAM_ID
```

The non-secret `APNS_BUNDLE_ID` and `APNS_ENV` are already in `wrangler.toml`.

### 4. Deploy
```sh
npx wrangler deploy
```

Wrangler prints your URL, e.g. `https://page-relay.<your-subdomain>.workers.dev`. Health-check it:

```sh
curl https://page-relay.<your-subdomain>.workers.dev/health
# {"ok":true,"service":"page-relay","time":"…"}
```

### 5. Point the Mac + iOS clients at your Worker

**Mac side:** edit `~/Library/Application Support/ClaudePowerMode/config.json`, replace `relayURL` with your Worker URL (note the WebSocket path):
```json
{
  "relayEnabled": true,
  "relayURL": "wss://page-relay.<your-subdomain>.workers.dev/ws",
  ...
}
```
Then in the menu bar: `Reload Config`.

**iOS side:** the pairing QR will now contain your real Worker URL automatically (because `pairingPayloadJSON` reads from `coordinator.config.relayURL`). Re-scan / re-paste on the phone after updating the Mac config.

## Wire protocol

### Mac → Worker (WebSocket frames)
```json
{ "type": "intervention.opened", "payload": Intervention }
{ "type": "intervention.closed", "payload": { "id": "...", "reason": "..." } }
{ "type": "heartbeat",           "payload": { "ts": "...", "activeSessions": N, "battery": N } }
{ "type": "reply.injected",      "payload": { "interventionId": "...", "method": "tmux|claude_resume_print", "success": bool, "output": "..." } }
```

### Worker → Mac (WebSocket frames)
```json
{ "type": "reply", "payload": { "interventionId": "...", "text": "...", "action": "approve|deny|carry_on|custom|null", "sessionId": "...", "cwd": "..." } }
```

### iPhone → Worker (HTTPS REST, `Authorization: Bearer <relayToken>`)
```
GET  /interventions                 → [Intervention]
POST /reply/:interventionId         → body: { text, action? }
POST /device/register               → body: { apnsToken, appVersion }
```

### Worker → iPhone (APNs)
- **Alert push** when an intervention opens. Category `PAGE` (matches the iOS app's notification category, which exposes Approve/Deny/Reply quick actions).
- **Silent push** (`content-available: 1`) when an intervention is closed remotely — lets the inbox update without a banner.

## Local dev

```sh
npx wrangler dev
```

Local mode runs at `http://localhost:8787`. WebSocket works at `ws://localhost:8787/ws`. APNs will still go to Apple's real APNs sandbox (`api.development.push.apple.com`) — so you'll get pushes for real even from local.

## Costs

For a single user with this volume (a handful of pages per day), you're inside the Cloudflare free tier indefinitely:
- Workers: 100 000 requests/day free
- Durable Objects: 1M requests + 400 000 GB-s storage free
- WebSocket: counts as one request per session (cheap)

## Things this Worker is NOT doing (intentionally, for v1)

- **No Sign in with Apple / Google JWT verification.** The relay token is the auth. If multi-user matters later, add JWT verification in `index.ts` and key DOs by the verified `sub` claim.
- **No persistence beyond Durable Object storage.** No analytics, no audit log. Add R2 if you want history beyond the live in-DO state.
- **No web dashboard.** Pure relay. You see state by hitting `GET /interventions` with curl.
