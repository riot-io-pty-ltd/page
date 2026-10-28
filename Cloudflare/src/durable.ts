import type {
  DeviceRecord, Env, InboundEnvelope, Intervention, OutboundEnvelope, QueuedReply
} from "./types.ts";
import { apnsConfigured, sendApnsPush, type PushRequest } from "./apns.ts";
import {
  type BuiltPush, type PendingRecord, type Tombstone, type HeartbeatForecast, type HeartbeatUsage,
  buildAlertPush, buildClosePush, buildReplyFailedPush, decideOpenPush, decideReply, decideRetract, idFromTimeKey,
  hookCloseResolvedPrompt, hookHoldMs, hookPageExpiresAt, isExpiredHookPage, isHookBlocking,
  isHookPreId, keys, MAX_ID_LENGTH, normalizeApnsToken, normalizeCloseReason,
  normalizeIntervention, parseDeviceRegistration, parseHeartbeat, parseReplyBody,
  parseReplyInjected, parseSync, prefixes, queueEntryExpired, selectStaleForSync,
  TOMBSTONE_TTL_MS, CLOSED_REPLY_WINDOW_MS, QUEUE_TTL_MS, HOOK_EXPIRY_MARGIN_MS, HOOK_MAX_HOLD_MS,
  isoSeconds, type TokenBucket, MAX_SESSIONS_COMMAND_BYTES, SESSIONS_FEATURE, parseSessionsCommand,
  parseSessionsUpdate, takeToken, utf8Length, REPLY_RETRACT_FEATURE, RETRACTED_DETAIL, RETRACTED_METHOD
} from "./logic.ts";

/// Storage layout (one Durable Object per relay token). Every record has its
/// own key so no single value can outgrow the storage value limit — the old
/// layout kept everything in one "state.v1" blob, which a few hundred
/// verbose hook pages could push past the limit and brick the relay.
///
///   meta                     Meta (small: counters + last persisted presence)
///   p:<id>                   PendingRecord (write back with `{ ...rec, iv }`: it
///                            carries alertedAt / hookExpiresAt / shadowed too)
///   h:<inverted-ms>:<id>     Intervention, archived; lexical order = newest first
///   hx:<id>                  → its h: key (reply / reply.injected lookups by id)
///   q:<ms>:<id>              QueuedReply, oldest first
///   dev:<apnsToken>          DeviceRecord
///   tomb:<id>                Tombstone (closed ids; blocks late/replayed opens)
///
/// Concurrency: the runtime's input gate keeps other events out while we
/// await storage, but NOT while we await fetch (APNs). So every handler reads
/// fresh from storage (it has its own in-memory cache), finishes all its
/// mutations, and only then pushes. Nothing read before a push is reused
/// after it.

interface Meta {
  schema: 2;
  historyCount: number;
  lastHeartbeatAt?: string;
  activeSessions?: number;
  battery?: number;
  onAC?: boolean;
  working?: number;
  forecast?: HeartbeatForecast;
  usage?: HeartbeatUsage;
  /// When presence was last written (ms). Survives hibernation so a DO that
  /// wakes for every 15 s heartbeat doesn't rewrite storage every time.
  presenceSavedAt?: number;
  /// Set (once) the first time any Mac-side traffic reaches this relay: a
  /// Mac socket frame, or a Mac/hook POST /intervention. /status reports it
  /// as `macEverSeen` so a phone can tell "no Mac has ever used this
  /// pairing code" (stale QR, typo) from "your Mac is offline".
  macEverSeen?: boolean;
  /// Set by `relay.retire`: the Mac regenerated its pairing token and this
  /// one must never work again. Every request is then answered 410
  /// token_retired (see retiredResponse). Never cleared.
  retired?: boolean;
  retiredAt?: string;
  retiredReason?: string;
}

interface Presence {
  lastHeartbeatAt: string;
  activeSessions: number;
  battery: number;
  onAC?: boolean;
  working?: number;
  forecast?: HeartbeatForecast;
  usage?: HeartbeatUsage;
}

/// The pre-v2 single-blob layout, migrated on first load then deleted.
interface LegacyState {
  apnsDeviceToken?: string;
  apnsAppVersion?: string;
  apnsRegisteredAt?: string;
  pendingInterventions?: Record<string, Intervention>;
  history?: Intervention[];
  replyQueue?: Array<{ interventionId: string; text?: string; action?: string | null }>;
  lastHeartbeatAt?: string;
  lastBattery?: number;
  lastActiveSessions?: number;
}

interface WSAttachment {
  role?: "mac" | "phone";
}

interface Outcome {
  status: number;
  body: Record<string, unknown>;
}

/// What closes still have to tell the phone over APNs. Collected while the
/// storage mutations run and pushed afterwards (pushes await fetch, which
/// lets other events in).
interface Effects {
  /// Ids for the background close push.
  closedIds: string[];
  /// Replies that turned out undeliverable (alert push each).
  failed: Intervention[];
  /// Pages to alert again: put back after a blocking hook gave up on their
  /// prompt, or stored silently while it held the session.
  realert: Intervention[];
}

const newEffects = (): Effects => ({ closedIds: [], failed: [], realert: [] });

/// closeRecord modes: drop the pending record only; also archive it (a
/// later reply gets a clear 410, but the id may open again); or archive and
/// tombstone it (a late or replayed open is ignored for TOMBSTONE_TTL_MS).
type CloseMode = "forget" | "archive" | "remember";

const HISTORY_CAP = 300;
const MAX_PENDING = 200;
const MAX_QUEUE = 200;
const MAX_DEVICES = 10;
const MAX_TOMBSTONES = 2000;
/// Pages a single blocking-hook page may hold in reserve (see `shadowed`).
const MAX_SHADOWED = 10;
const MAX_BODY_BYTES = 256 * 1024;
const PRESENCE_PERSIST_MS = 5 * 60 * 1000;
const STORAGE_BATCH = 128;          // put/delete accept at most 128 keys per call
const WS_OPEN = 1;                  // WebSocket.READY_STATE_OPEN

/// Archived but hidden from GET /history unless `?all=1`: bookkeeping
/// closes, not resolutions. Kept so a reply typed against a still-visible
/// banner gets a clear 410 instead of a 404.
const HIDDEN_HISTORY_REASONS = new Set(["superseded", "evicted"]);

/// Frames only a Mac sends; an untagged socket sending one is a Mac.
/// Phone-originated types (sessions.command) must never join this set, or a
/// phone could get itself tagged as the Mac by sending one.
const MAC_FRAME_TYPES = new Set([
  "intervention.opened", "intervention.closed", "heartbeat", "reply.injected", "sync", "relay.retire",
  "sessions.update"
]);

/// Mac frames that are forwarded and forgotten (sessions-v1): accepted only
/// from a Mac socket, and they never touch storage — no macEverSeen write, no
/// reply-queue flush. A sessions-v1 Mac sends `sync` / a heartbeat on connect,
/// which do both.
const EPHEMERAL_FRAME_TYPES = new Set(["sessions.update"]);

/// What a retired token answers to everything (see Meta.retired).
export const TOKEN_RETIRED_WHY = "This pairing was replaced on your Mac — scan the new QR code";
/// WebSocket close code sent to every socket when the token is retired
/// (4000–4999 is the application range; 4410 mirrors the HTTP 410).
export const TOKEN_RETIRED_CLOSE_CODE = 4410;

let warnedApnsUnconfigured = false;

export class UserRelay {
  private state: DurableObjectState;
  private env: Env;
  private storage: DurableObjectStorage;
  private ready: Promise<void>;
  /// Latest heartbeat, kept in memory (lost on hibernation — then /status
  /// falls back to the copy in meta, at most PRESENCE_PERSIST_MS old).
  private presence?: Presence;
  private presenceSavedAt?: number;
  /// Number of queued replies if known; undefined after a wake. Lets the hot
  /// path (every Mac frame) skip a storage list when the queue is empty.
  private queueHint?: number;
  private flushing = false;
  private lastPushError?: string;
  /// meta.macEverSeen is known to be true (saves a meta read per frame).
  private macEverSeen = false;
  /// meta.retired, loaded at startup and set by retire().
  private retired = false;
  /// POST /sessions/command rate limit. In memory only (a wake starts full):
  /// commands must never cost a storage write.
  private commandBucket?: TokenBucket;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
    this.storage = state.storage;
    this.ready = state.blockConcurrencyWhile(async () => {
      await this.migrate();
      // Separate from migrate(), which returns early for schema-2 objects.
      this.retired = (await this.storage.get<Meta>(keys.meta))?.retired === true;
    });
    // Lets clients keep the socket alive with a text "ping" without waking
    // the object from hibernation.
    if (typeof WebSocketRequestResponsePair !== "undefined") {
      try {
        state.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
      } catch (err) { console.warn("setWebSocketAutoResponse failed:", err); }
    }
  }

  // MARK: migration

  /// One-time move from the legacy single "state.v1" blob to per-record
  /// keys. Idempotent: if it dies half way, meta isn't written and state.v1
  /// isn't deleted, so the next load redoes it, overwriting the same keys.
  private async migrate(): Promise<void> {
    const meta = await this.storage.get<Meta>(keys.meta);
    if (meta?.schema === 2) return;
    const legacy = await this.storage.get<LegacyState>(keys.legacyState);
    if (!legacy) return;            // fresh object: nothing to write yet

    const now = Date.now();
    const puts: Record<string, unknown> = {};
    const legacyPending = legacy.pendingInterventions ?? {};

    const legacyQueued = new Set((legacy.replyQueue ?? []).map(r => r?.interventionId));
    for (const iv of Object.values(legacyPending)) {
      if (!iv || typeof iv.id !== "string" || typeof iv.sessionId !== "string") continue;
      const migrated: Intervention = canonicalTimes({ ...iv, backend: iv.backend ?? "claude", source: iv.source ?? "terminal" });
      if (migrated.repliedAt && !isHookPreId(iv.id)) {
        if (legacyQueued.has(iv.id)) {
          migrated.deliveryStatus = "pending";
        } else {
          // The old Worker forwarded it but never learned the outcome, and a
          // successful injection would have closed the page. Free it for a
          // retry instead of answering 409 forever.
          migrated.deliveryStatus = "failed";
          migrated.deliveryDetail = "Your Mac never confirmed this reply — you can send it again";
          delete migrated.repliedAt;
          delete migrated.repliedAction;
        }
      }
      const rec: PendingRecord = { iv: migrated, receivedAt: Date.parse(iv.openedAt) || now };
      puts[keys.pending(iv.id)] = rec;
    }

    let historyCount = 0;
    (legacy.history ?? []).slice(0, HISTORY_CAP).forEach((iv, i) => {
      if (!iv || typeof iv.id !== "string") return;
      const indexKey = keys.historyIndex(iv.id);
      if (puts[indexKey]) return;   // duplicate id: legacy history is newest-first, keep the first
      const closedMs = Date.parse(iv.closedAt ?? "") || Date.parse(iv.openedAt ?? "") || now - i;
      const historyKey = keys.history(closedMs, iv.id);
      puts[historyKey] = canonicalTimes(iv);
      puts[indexKey] = historyKey;
      historyCount++;
    });

    const token = normalizeApnsToken(legacy.apnsDeviceToken);
    if (token) {
      const dev: DeviceRecord = {
        appVersion: legacy.apnsAppVersion ?? "unknown",
        registeredAt: legacy.apnsRegisteredAt ?? isoSeconds(now)
      };
      puts[keys.device(token)] = dev;
    }

    for (const r of legacy.replyQueue ?? []) {
      const iv = legacyPending[r?.interventionId];
      // Legacy entries carried no routing info; without a live intervention
      // there's nothing safe to deliver them to.
      if (!iv || isHookPreId(iv.id)) continue;
      const parsed = parseReplyBody({ text: r.text, action: r.action });
      if (!parsed.ok) continue;
      const queuedAt = Date.parse(iv.repliedAt ?? "") || now;
      const entry: QueuedReply = {
        interventionId: iv.id, text: parsed.text, action: parsed.action,
        sessionId: iv.sessionId, cwd: iv.cwd ?? "", kind: iv.kind,
        backend: iv.backend ?? "claude", source: iv.source, queuedAt
      };
      puts[keys.queue(queuedAt, iv.id)] = entry;
    }

    const newMeta: Meta = { schema: 2, historyCount };
    if (legacy.lastHeartbeatAt) {
      newMeta.lastHeartbeatAt = legacy.lastHeartbeatAt;
      newMeta.activeSessions = legacy.lastActiveSessions;
    }
    await this.putAll(puts);
    await this.storage.put(keys.meta, newMeta);
    await this.storage.delete(keys.legacyState);
    // The legacy Worker never used alarms: without one, migrated queued
    // replies would sit "pending" (and refuse retries with 409) until some
    // unrelated event happened to schedule an alarm, and migrated hook pages
    // would never expire.
    await this.rescheduleAlarm(now, false);
    console.log(
      `migrated state.v1: ${Object.keys(legacyPending).length} pending, ${historyCount} history, ` +
      `${token ? 1 : 0} device`
    );
  }

  // MARK: routing

  async fetch(req: Request): Promise<Response> {
    await this.ready;
    const url = new URL(req.url);
    const path = url.pathname;

    // A retired token answers nothing but 410 — WS upgrades and unknown
    // paths included. (/health never reaches the object: index.ts serves it.)
    if (this.retired) return retiredResponse();

    try {
      if (path === "/ws") return this.handleUpgrade(req);

      if (req.method === "GET" && path === "/interventions") {
        const list = (await this.listPending()).map(r => r.iv).sort(
          (a, b) => (Date.parse(b.openedAt) || 0) - (Date.parse(a.openedAt) || 0)
        );
        return jsonResponse(list);
      }

      if (req.method === "GET" && path === "/history") {
        return jsonResponse(await this.listHistory(url.searchParams));
      }

      if (req.method === "GET" && path === "/status") {
        return jsonResponse(await this.status());
      }

      if ((req.method === "POST" || req.method === "DELETE") && path.startsWith("/reply/")) {
        let id: string;
        try { id = decodeURIComponent(path.slice("/reply/".length)); } catch { return errorResponse("bad_id", 400); }
        if (!id || id.length > MAX_ID_LENGTH) return errorResponse("bad_id", 400);
        // DELETE takes back a queued reply (reply-retract-v1); any body is ignored.
        if (req.method === "DELETE") return await this.retractReply(id);
        const body = await readJson(req);
        if ("error" in body) return errorResponse(body.error, body.status);
        return await this.handlePhoneReply(id, body.value);
      }

      if (req.method === "POST" && (path === "/device/register" || path === "/device/unregister")) {
        const body = await readJson(req);
        if ("error" in body) return errorResponse(body.error, body.status);
        const out = path === "/device/register"
          ? await this.registerDevice(body.value)
          : await this.unregisterDevice(body.value);
        return jsonResponse(out.body, out.status);
      }

      if (req.method === "POST" && path === "/sessions/command") {
        return await this.handleSessionsCommand(req);
      }

      if (req.method === "POST" && path === "/intervention") {
        const body = await readJson(req);
        if ("error" in body) return errorResponse(body.error, body.status);
        const env = body.value;
        if (!isObject(env) || typeof env.type !== "string") return errorResponse("bad_request", 400);
        // Socket-only frames: refused before anything is written.
        if (EPHEMERAL_FRAME_TYPES.has(env.type)) return errorResponse("mac_socket_only", 403);
        // Mac-side frames over HTTP come from the Mac's hook script (or an
        // older Mac): proof the Mac has used this pairing.
        if (MAC_FRAME_TYPES.has(env.type)) await this.noteMacSeen();
        const out = await this.handleInbound(env as unknown as InboundEnvelope, {
          userAgent: req.headers.get("User-Agent") ?? undefined
        });
        return jsonResponse(out.body, out.status);
      }

      return errorResponse("not_found", 404);
    } catch (err) {
      console.error(`${req.method} ${path} failed:`, err);
      return errorResponse("internal_error", 500);
    }
  }

  private handleUpgrade(req: Request): Response {
    if ((req.headers.get("Upgrade") ?? "").toLowerCase() !== "websocket") {
      return errorResponse("expected_websocket_upgrade", 426);
    }
    const ua = req.headers.get("User-Agent") ?? "";
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.attachSocket(server, ua.includes("page-mac"));
    return new Response(null, { status: 101, webSocket: client });
  }

  /// Accepts a server-side socket (hibernation API — it survives eviction).
  /// The Mac is tagged immediately by its User-Agent so replies route to it
  /// even if it only listens; phone sockets stay untagged.
  /// Queued replies are NOT flushed here: they go out on the Mac's first
  /// frame (v2 Macs send `sync` on connect, older ones a heartbeat within
  /// 15 s), when the socket has proven it works in both directions.
  attachSocket(ws: WebSocket, isMac: boolean): void {
    this.state.acceptWebSocket(ws);
    if (isMac) this.markMac(ws);
    // Counted explicitly: a socket accepted mid-upgrade needn't read as open yet.
    else this.sendPhonesStatus(ws, 1);
  }

  /// Also the legacy path (an untagged socket that sent a Mac frame): it was
  /// counted as a phone until now, so the Macs hear the new count either way.
  private markMac(ws: WebSocket): void {
    ws.serializeAttachment({ role: "mac" } satisfies WSAttachment);
    this.broadcastToPhones({
      type: "mac.status",
      payload: { macConnected: true, lastHeartbeatAt: this.presence?.lastHeartbeatAt }
    });
    // The new Mac gets the count directly (it may not read as open yet).
    const status = JSON.stringify({ type: "phones.status", payload: { phones: this.phoneCount(ws) } } satisfies OutboundEnvelope);
    this.sendToMac(status, ws);
    try { ws.send(status); } catch (err) { console.warn("phones.status to the new Mac failed:", err); }
  }

  // MARK: hibernation-API WS handlers (Cloudflare-invoked)

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    await this.ready;
    if (this.retired) {
      // A socket that outlived the retirement (it should have been closed).
      try { ws.close(TOKEN_RETIRED_CLOSE_CODE, "token_retired"); } catch { /* already closed */ }
      return;
    }
    const text = typeof message === "string" ? message : new TextDecoder().decode(message);
    if (text === "ping") {          // only reached when the auto-response isn't installed
      try { ws.send("pong"); } catch { /* socket gone */ }
      return;
    }
    let env: unknown;
    try { env = JSON.parse(text); } catch {
      console.warn(`WS frame parse error (${text.length} chars)`);
      return;
    }
    if (!isObject(env) || typeof env.type !== "string") return;

    const attachment = (ws.deserializeAttachment() ?? {}) as WSAttachment;
    let isMac = attachment.role === "mac";
    if (!isMac && MAC_FRAME_TYPES.has(env.type) && !EPHEMERAL_FRAME_TYPES.has(env.type)) {
      // Legacy path: a Mac that connected without the page-mac User-Agent.
      // Not for sessions.update: every Mac that sends it also sends the
      // page-mac User-Agent, so a socket sending it untagged is a phone (or
      // a token holder) and must not get the Mac role or its commands.
      this.markMac(ws);
      isMac = true;
    }

    const ephemeral = EPHEMERAL_FRAME_TYPES.has(env.type);
    if (isMac && !ephemeral) await this.noteMacSeen();
    try {
      const out = await this.handleInbound(env as unknown as InboundEnvelope, { role: isMac ? "mac" : "phone" });
      if (out.status >= 400) console.warn(`WS ${env.type} rejected: ${String(out.body.error)}`);
    } catch (err) {
      console.error(`WS ${env.type} failed:`, err);
    }
    // After the frame, so a `sync` has already closed pages the Mac no
    // longer has before we decide which queued replies are still deliverable.
    // Never after a relay.retire: nothing goes out on a retired token.
    if (isMac && !ephemeral && !this.retired) await this.flushReplyQueue();
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string, _wasClean: boolean): Promise<void> {
    // Reciprocate the close handshake, or the client waits out its close
    // timeout and sees 1006. close() rejects reserved codes (1005/1006/...).
    try { ws.close(isSendableCloseCode(code) ? code : 1000, truncateUtf8(reason || "closing", 123)); } catch { /* already closed */ }
    await this.onSocketGone(ws);
  }

  async webSocketError(ws: WebSocket, err: unknown): Promise<void> {
    console.warn("WS error:", err);
    await this.onSocketGone(ws);
  }

  /// `ws` is excluded explicitly: after webSocketError (or before the
  /// runtime has finished closing it) it can still read as open.
  private async onSocketGone(ws: WebSocket): Promise<void> {
    await this.ready;
    if (this.retired) return;
    if (this.roleOf(ws) !== "mac") {
      this.sendPhonesStatus(ws);
      return;
    }
    if (this.macConnected(ws)) return;
    this.broadcastToPhones({
      type: "mac.status",
      payload: { macConnected: false, lastHeartbeatAt: this.presence?.lastHeartbeatAt }
    });
    if (this.presence) await this.persistPresence(Date.now());
  }

  /// Periodic housekeeping: expires queued replies the Mac never came back
  /// for (so the phone hears "not delivered" instead of waiting forever),
  /// closes abandoned hook pages (see hookPageExpiresAt) and prunes
  /// tombstones.
  async alarm(): Promise<void> {
    await this.ready;
    if (this.retired) {
      // Nothing may push for a retired token (retire() also deletes the alarm).
      await this.storage.deleteAlarm();
      return;
    }
    const now = Date.now();
    const fx = newEffects();
    for (const [key, entry] of await this.storage.list<QueuedReply>({ prefix: prefixes.queue })) {
      if (queueEntryExpired(entry, now)) {
        const iv = await this.failQueued(key, entry, "Your Mac was offline too long — reply not delivered");
        if (iv) fx.failed.push(iv);
      }
    }
    await this.expireHookPages(now, fx);
    const tombsLeft = await this.pruneTombstones(now);
    await this.rescheduleAlarm(now, tombsLeft);
    await this.pushEffects(fx, now);
  }

  // MARK: inbound dispatch

  /// `ctx.role`: the sending socket's role (WebSocket frames only; absent
  /// for HTTP). `userAgent`: HTTP only.
  private async handleInbound(
    env: InboundEnvelope, ctx: { userAgent?: string; role?: WSAttachment["role"] } = {}
  ): Promise<Outcome> {
    switch (env.type) {
      case "intervention.opened": return this.openIntervention(env.payload, ctx.userAgent);
      case "intervention.closed": return this.closeIntervention(env.payload);
      case "heartbeat":           return this.recordHeartbeat(env.payload);
      case "reply.injected":      return this.handleReplyInjected(env.payload);
      case "device.register":     return this.registerDevice(env.payload);
      case "sync":                return this.handleSync(env.payload);
      case "relay.retire":        return this.retire(env.payload);
      case "sessions.update":
        return ctx.role === "mac" ? this.forwardSessionsUpdate(env.payload) : fail("mac_socket_only", 403);
      default:
        console.warn("Unknown inbound type", (env as { type: string }).type);
        return fail("unknown_type");
    }
  }

  // MARK: intervention lifecycle

  /// `userAgent`: only passed for HTTP opens (the hook's route); it
  /// identifies the v1 blocking hook (see isLegacyBlockingHookOpen).
  private async openIntervention(raw: unknown, userAgent?: string): Promise<Outcome> {
    const now = Date.now();
    const n = normalizeIntervention(raw, now, { userAgent });
    if (!n.ok) {
      console.warn(`intervention.opened rejected: ${n.error}`);
      return fail(n.error);
    }
    const iv = n.iv;
    if (await this.storage.get(keys.pending(iv.id))) return ok({ duplicate: true });
    const tomb = await this.getTomb(iv.id, now);
    if (tomb) {
      // A late or replayed open for a page that's already closed (e.g. a
      // retry queue flushed after the close). Don't resurrect it.
      console.log(`ignoring open for closed ${iv.id} (${tomb.reason})`);
      return ok({ ignored: "closed" });
    }

    // Orphaned hook pages go first, so they can't mute this page.
    const fx = newEffects();
    await this.expireHookPages(now, fx);

    const pending = await this.listPending();
    const blocking = isHookBlocking(iv);
    // SUPERSEDE: a session has exactly one current state — newest wins, so
    // the inbox doesn't show "IDLE 1m ago + QUESTION 0s ago" for one session.
    // Blocking-hook pages are exempt: the hook owns their lifetime.
    const superseded = pending.filter(r =>
      r.iv.sessionId === iv.sessionId && r.iv.id !== iv.id && !isHookBlocking(r.iv)
    );
    // Runaway-client guard: never hold more than MAX_PENDING pages.
    const remaining = pending
      .filter(r => !superseded.includes(r))
      .sort((a, b) => a.receivedAt - b.receivedAt);
    const evicted = remaining.slice(0, Math.max(0, remaining.length - (MAX_PENDING - 1)));

    // Decided against the pages pending *before* this one (the page it
    // supersedes is the one that may have just buzzed).
    const pushMode = decideOpenPush(iv, pending, now);
    const rec: PendingRecord = { iv, receivedAt: now };
    if (pushMode === "alert") rec.alertedAt = now;
    if (blocking) {
      rec.hookExpiresAt = now + (hookHoldMs(raw) ?? HOOK_MAX_HOLD_MS) + HOOK_EXPIRY_MARGIN_MS;
      // The pages a blocking hook replaces are usually the Mac detector's
      // page for the very same prompt. If the hook later gives up (timeout,
      // lost relay, user came and went) the agent is still blocked and the
      // Mac won't page it again, so keep them restorable: archived (a reply
      // gets 410 "superseded") but not tombstoned.
      if (superseded.length) rec.shadowed = superseded.map(r => r.iv.id).slice(-MAX_SHADOWED);
    }
    await this.storage.put(keys.pending(iv.id), rec);
    for (const r of superseded) await this.closeRecord(r, "superseded", now, blocking ? "archive" : "remember");
    for (const r of evicted) await this.closeRecord(r, "evicted", now, "remember");
    await this.rescheduleAlarm(now, superseded.length > 0 || evicted.length > 0);

    for (const r of superseded) {
      this.broadcastToPhones({ type: "intervention.closed", payload: { id: r.iv.id, reason: "superseded" } });
    }
    for (const r of evicted) {
      this.broadcastToPhones({ type: "intervention.closed", payload: { id: r.iv.id, reason: "evicted" } });
    }
    // The phone sees this live over its socket, no APNs needed...
    this.broadcastToPhones({ type: "intervention.opened", payload: iv });
    // ...and via APNs when the app is backgrounded. Last: it awaits fetch.
    const closedIds = [...fx.closedIds, ...superseded.map(r => r.iv.id), ...evicted.map(r => r.iv.id)];
    fx.closedIds = [];
    const badge = await this.pendingCount();
    if (pushMode === "none") {
      console.log(`open ${iv.id}: a blocking hook is already paging session ${iv.sessionId.slice(0, 8)} — stored without an alert`);
      // The superseded pages' banners still have to go.
      if (closedIds.length) await this.pushToDevices(buildClosePush(closedIds, { badge }), "background");
      await this.pushEffects(fx, now);
      return ok({ pushed: false });
    }
    if (pushMode === "quiet") {
      console.log(`open ${iv.id}: session ${iv.sessionId.slice(0, 8)} was paged < 30 s ago — quiet push`);
    }
    await this.pushToDevices(buildAlertPush(iv, now, closedIds, { quiet: pushMode === "quiet", badge }), "alert");
    // The alert's interventionClosedIds only reach app code that runs for
    // the alert (there is no Notification Service Extension), so a
    // backgrounded phone also gets the ids in a background close push.
    if (closedIds.length) await this.pushToDevices(buildClosePush(closedIds, { badge }), "background");
    await this.pushEffects(fx, now);
    return ok();
  }

  private async closeIntervention(raw: unknown): Promise<Outcome> {
    if (!isObject(raw) || typeof raw.id !== "string" || !raw.id || raw.id.length > MAX_ID_LENGTH) {
      return fail("invalid_id");
    }
    const id = raw.id;
    const reason = normalizeCloseReason(raw.reason);
    const now = Date.now();

    const rec = await this.storage.get<PendingRecord>(keys.pending(id));
    if (!rec) {
      // Already closed, or the close overtook its open (reconnect replay).
      // Remember it so the late open is ignored. `stale` comes from sync and
      // is the Mac's own truth — a later open from the Mac must still work.
      if (reason !== "stale" && !(await this.getTomb(id, now))) {
        await this.putTomb(id, reason, now);
        await this.rescheduleAlarm(now, true);
      }
      return ok({ unknown: true });
    }

    const fx = newEffects();
    await this.closePending(rec, reason, now, fx, { cascade: true });
    await this.rescheduleAlarm(now, reason !== "stale");
    await this.pushEffects(fx, now);
    return ok();
  }

  /// Closes one pending page: settles a reply a blocking hook was meant to
  /// read, archives (unless `stale`), cascades to the session's other pages
  /// (when asked), settles a blocking hook's shadowed pages, and broadcasts.
  /// APNs work is left in `fx` for pushEffects.
  private async closePending(
    rec: PendingRecord, reason: string, now: number, fx: Effects, opts: { cascade: boolean }
  ): Promise<void> {
    const id = rec.iv.id;
    let iv = rec.iv;
    const blocking = isHookBlocking(iv);
    // The blocking hook closes its own page with "replied" once it has read
    // the decision — that's the delivery confirmation for hook replies. Any
    // other reason (timeout, hook_exited, hook_lost) means it never read it.
    let hookResult: { success: boolean; detail: string } | undefined;
    if (blocking && iv.repliedAt && iv.deliveryStatus === "pending") {
      hookResult = reason === "replied"
        ? { success: true, detail: `${iv.backend === "codex" ? "Codex" : "Claude Code"} applied your decision` }
        : { success: false, detail: "The hook stopped waiting before it read your reply" };
      iv = { ...iv, deliveryStatus: hookResult.success ? "delivered" : "failed", deliveryMethod: "hook", deliveryDetail: hookResult.detail };
      if (!hookResult.success) { delete iv.repliedAt; delete iv.repliedAction; }
    }
    const historyWorthy = reason !== "stale";
    await this.closeRecord({ ...rec, iv }, reason, now, historyWorthy ? "remember" : "forget");

    // CASCADE: when a session resolves one of its pages (typed in the
    // terminal, replied via phone, ...) its other pending pages are stale
    // too. Archived as session_resolved so replies to them get a clear answer.
    // Blocking-hook pages neither cascade nor get cascaded.
    const cascade = !opts.cascade || !historyWorthy || blocking ? [] : (await this.listPending()).filter(r =>
      r.iv.sessionId === iv.sessionId && !isHookBlocking(r.iv)
    );
    for (const r of cascade) await this.closeRecord(r, "session_resolved", now, "remember");

    this.broadcastToPhones({ type: "intervention.closed", payload: { id, reason } });
    for (const r of cascade) {
      this.broadcastToPhones({ type: "intervention.closed", payload: { id: r.iv.id, reason: "session_resolved" } });
    }
    if (hookResult) {
      this.broadcastToPhones({
        type: "reply.result",
        payload: { interventionId: id, success: hookResult.success, method: "hook", detail: hookResult.detail }
      });
      if (!hookResult.success) fx.failed.push({ ...iv, closedAt: isoSeconds(now), closeReason: reason });
    }
    fx.closedIds.push(id, ...cascade.map(r => r.iv.id));
    if (blocking) await this.settleShadowed(rec, reason, now, fx);
  }

  /// After a blocking hook's page closes. If the prompt was answered
  /// ("replied", "resolved_elsewhere") the pages it replaced are finished:
  /// tombstone them. Otherwise the agent may still be blocked on that
  /// prompt, so put them back (unless the Mac closed them meanwhile or a
  /// newer page covers the session) and re-alert them, together with any
  /// same-session page that arrived silently while the hook held it.
  /// "user_returned" restores without a buzz: the user is at the Mac.
  private async settleShadowed(rec: PendingRecord, reason: string, now: number, fx: Effects): Promise<void> {
    const sessionId = rec.iv.sessionId;
    const restore = !hookCloseResolvedPrompt(reason);
    const pending = await this.listPending();
    const stillHeld = pending.some(r =>
      r.iv.sessionId === sessionId && isHookBlocking(r.iv) && !isExpiredHookPage(r, now));
    const loud = restore && reason !== "user_returned" && !stillHeld;
    let covered = pending.some(r => r.iv.sessionId === sessionId && !isHookBlocking(r.iv));

    for (const sid of rec.shadowed ?? []) {
      if (await this.getTomb(sid, now)) continue;          // the Mac closed it meanwhile
      if (!restore || covered) { await this.putTomb(sid, "superseded", now); continue; }
      const archived = await this.getArchived(sid);
      if (!archived || await this.storage.get(keys.pending(sid))) continue;
      const back: Intervention = { ...archived.iv };
      delete back.closedAt;
      delete back.closeReason;
      await this.unarchive(sid, archived.key);
      const restored: PendingRecord = { iv: back, receivedAt: now };
      if (loud) restored.alertedAt = now;
      await this.storage.put(keys.pending(sid), restored);
      covered = true;
      console.log(`restored ${sid}: the hook page ${rec.iv.id} closed (${reason}) without answering its prompt`);
      this.broadcastToPhones({ type: "intervention.opened", payload: back });
      if (loud) fx.realert.push(back);
    }

    if (!loud) return;
    for (const r of pending) {
      if (r.iv.sessionId !== sessionId || isHookBlocking(r.iv) || r.alertedAt !== undefined) continue;
      if (r.receivedAt < rec.receivedAt || fx.realert.some(x => x.id === r.iv.id)) continue;
      await this.storage.put(keys.pending(r.iv.id), { ...r, alertedAt: now } satisfies PendingRecord);
      fx.realert.push(r.iv);
    }
  }

  /// Closes every pending hook page past its expiry: blocking-hook pages as
  /// "hook_lost" (their hook died without closing them), notification-hook
  /// pages as "expired". No cascade: an old card going away says nothing
  /// about the session's newer pages.
  private async expireHookPages(now: number, fx: Effects): Promise<void> {
    for (const r of await this.listPending()) {
      if (!isExpiredHookPage(r, now)) continue;
      const current = await this.storage.get<PendingRecord>(keys.pending(r.iv.id));
      if (!current) continue;
      const reason = isHookBlocking(current.iv) ? "hook_lost" : "expired";
      console.log(`expiring ${current.iv.id} (${reason})`);
      await this.closePending(current, reason, now, fx, { cascade: false });
    }
  }

  /// Sends what closes left in `fx`, after all storage mutations. Re-alerts
  /// only pages that are still pending by then.
  private async pushEffects(fx: Effects, now: number): Promise<void> {
    const realert: Intervention[] = [];
    for (const iv of fx.realert) {
      if (await this.storage.get(keys.pending(iv.id))) realert.push(iv);
    }
    if (!realert.length && !fx.closedIds.length && !fx.failed.length) return;
    const badge = await this.pendingCount();
    for (const iv of realert) await this.pushToDevices(buildAlertPush(iv, now, [], { badge }), "alert");
    if (fx.closedIds.length) await this.pushToDevices(buildClosePush(fx.closedIds, { badge }), "background");
    await this.pushReplyFailures(fx.failed, badge);
  }

  /// Removes a pending record; see CloseMode.
  private async closeRecord(rec: PendingRecord, reason: string, closedMs: number, mode: CloseMode): Promise<void> {
    await this.storage.delete(keys.pending(rec.iv.id));
    if (mode === "forget") return;
    await this.archive({ ...rec.iv, closedAt: isoSeconds(closedMs), closeReason: reason }, closedMs);
    if (mode === "remember") await this.putTomb(rec.iv.id, reason, closedMs);
  }

  private async handleSync(raw: unknown): Promise<Outcome> {
    const sync = parseSync(raw);
    if (!sync) return fail("invalid_payload");
    const now = Date.now();
    const pending = await this.listPending();
    const staleIds = selectStaleForSync(pending, sync, now);
    if (!staleIds.length) return ok({ closed: 0 });

    for (const r of pending) {
      if (staleIds.includes(r.iv.id)) await this.closeRecord(r, "stale", now, "forget");
    }
    for (const id of staleIds) {
      this.broadcastToPhones({ type: "intervention.closed", payload: { id, reason: "stale" } });
    }
    console.log(`sync(${sync.backend}): closed ${staleIds.length} stale page(s)`);
    await this.pushToDevices(buildClosePush(staleIds, { badge: await this.pendingCount() }), "background");
    return ok({ closed: staleIds.length });
  }

  // MARK: token retirement

  /// `relay.retire` from the Mac, on the OLD token, just before it switches
  /// to a regenerated one. From here on every request on this token gets
  /// 410 token_retired (meta.retired survives hibernation). Pending pages,
  /// queued replies and registered phones are dropped without archiving and
  /// without any push (nothing may go out for a dead pairing); phone
  /// sockets hear `intervention.closed` (token_retired) for each page and
  /// then `relay.retired`, and every socket is closed so a phone reconnects
  /// straight into the 410 instead of sitting on a socket that the ping
  /// auto-response keeps looking healthy.
  private async retire(raw: unknown): Promise<Outcome> {
    const now = Date.now();
    const reason = isObject(raw) && typeof raw.reason === "string" && raw.reason
      ? normalizeCloseReason(raw.reason) : "token_regenerated";
    const meta = await this.getMeta();
    meta.retired = true;
    meta.retiredAt = isoSeconds(now);
    meta.retiredReason = reason;
    await this.storage.put(keys.meta, meta);
    this.retired = true;

    const pending = await this.listPending();
    const doomed = pending.map(r => keys.pending(r.iv.id));
    for (const prefix of [prefixes.queue, prefixes.device]) {
      for (const key of (await this.storage.list({ prefix })).keys()) doomed.push(key);
    }
    await this.deleteAll(doomed);
    this.queueHint = 0;
    await this.storage.deleteAlarm();
    console.log(`token retired (${reason}): dropped ${pending.length} pending page(s)`);

    for (const r of pending) {
      this.broadcastToPhones({ type: "intervention.closed", payload: { id: r.iv.id, reason: "token_retired" } });
    }
    this.broadcastToPhones({ type: "relay.retired", payload: { reason, why: TOKEN_RETIRED_WHY } });
    for (const ws of this.openSockets()) {
      try { ws.close(TOKEN_RETIRED_CLOSE_CODE, "token_retired"); } catch { /* already closed */ }
    }
    return ok({ retired: true });
  }

  // MARK: phone replies

  private async handlePhoneReply(id: string, body: unknown): Promise<Response> {
    const parsed = parseReplyBody(body);
    if (!parsed.ok) return errorResponse(parsed.error, parsed.status);
    const now = Date.now();

    const rec = await this.storage.get<PendingRecord>(keys.pending(id));
    let archived: { key: string; iv: Intervention } | undefined;
    let tomb: Tombstone | undefined;
    let currentId: string | undefined;
    if (!rec) {
      archived = await this.getArchived(id);
      if (!archived) tomb = await this.getTomb(id, now);
      const sessionId = archived?.iv.sessionId;
      if (sessionId) currentId = (await this.listPending()).find(r => r.iv.sessionId === sessionId)?.iv.id;
    }

    const decision = decideReply({
      pending: rec?.iv, closed: archived?.iv, tomb, currentIdForSession: currentId,
      action: parsed.action, now
    });
    if (!decision.ok) {
      console.log(`reply for ${id} refused: ${decision.status} ${String(decision.body.why ?? decision.body.error)}`);
      return jsonResponse(decision.body, decision.status);
    }

    const target = decision.target;
    const updated: Intervention = {
      ...target,
      repliedAt: isoSeconds(now),
      repliedText: parsed.text,
      deliveryStatus: "pending"
    };
    if (parsed.action) updated.repliedAction = parsed.action; else delete updated.repliedAction;
    delete updated.deliveryMethod;
    delete updated.deliveryForwardedAt;

    if (!decision.forwardToMac) {
      // Blocking hook page: the hook polls GET /interventions for this.
      updated.deliveryDetail = target.backend === "codex"
        ? "Waiting for the Codex hook to pick it up"
        : "Waiting for the Claude Code hook to pick it up";
      await this.saveIntervention(updated, rec, archived);
      console.log(`reply for ${id} stored for the hook (text=${parsed.text.length}B action=${parsed.action})`);
      return jsonResponse({ ok: true, queued: false });
    }

    const entry: QueuedReply = {
      interventionId: id, text: parsed.text, action: parsed.action,
      sessionId: target.sessionId, cwd: target.cwd, kind: target.kind,
      backend: target.backend ?? "claude", source: target.source, queuedAt: now
    };
    if (decision.closed) { entry.closed = true; entry.closeReason = target.closeReason; }
    if (target.promptKey) entry.promptKey = target.promptKey;

    const sent = this.sendToMac({ type: "reply", payload: replyPayload(entry) });
    updated.deliveryDetail = sent ? "Sent to your Mac" : "Waiting for your Mac to come online";
    if (sent) updated.deliveryForwardedAt = isoSeconds(now);
    await this.saveIntervention(updated, rec, archived);
    if (!sent) await this.enqueue(entry);
    console.log(
      `reply for ${id} (${decision.closed ? "closed" : "pending"}) ${sent ? "forwarded" : "queued"} ` +
      `text=${parsed.text.length}B action=${parsed.action}`
    );
    return jsonResponse({ ok: true, queued: !sent });
  }

  private async saveIntervention(
    iv: Intervention, rec: PendingRecord | undefined, archived: { key: string } | undefined
  ): Promise<void> {
    if (rec) await this.storage.put(keys.pending(iv.id), { ...rec, iv } satisfies PendingRecord);
    else if (archived) await this.storage.put(archived.key, iv);
  }

  private async enqueue(entry: QueuedReply): Promise<void> {
    await this.storage.put(keys.queue(entry.queuedAt, entry.interventionId), entry);
    const queue = await this.storage.list<QueuedReply>({ prefix: prefixes.queue });
    this.queueHint = queue.size;
    const failed: Intervention[] = [];
    if (queue.size > MAX_QUEUE) {
      let excess = queue.size - MAX_QUEUE;
      for (const [key, old] of queue) {        // oldest first
        if (excess-- <= 0) break;
        const iv = await this.failQueued(key, old, "Too many replies were waiting for your Mac");
        if (iv) failed.push(iv);
      }
    }
    await this.scheduleAlarm(entry.queuedAt + (entry.closed ? CLOSED_REPLY_WINDOW_MS : QUEUE_TTL_MS) + 1000);
    await this.pushReplyFailures(failed);
  }

  /// Sends queued replies to the Mac, oldest first. An entry is deleted only
  /// once a Mac socket accepted it; expired entries and entries whose page
  /// closed meanwhile are dropped and reported as failed to the phone.
  private async flushReplyQueue(): Promise<void> {
    if (this.queueHint === 0 || this.flushing) return;
    this.flushing = true;
    const failed: Intervention[] = [];
    try {
      const queue = await this.storage.list<QueuedReply>({ prefix: prefixes.queue });
      this.queueHint = queue.size;
      const now = Date.now();
      for (const [key, entry] of queue) {
        if (queueEntryExpired(entry, now)) {
          const iv = await this.failQueued(key, entry, "Your Mac was offline too long — reply not delivered");
          if (iv) failed.push(iv);
          continue;
        }
        const rec = entry.closed ? undefined : await this.storage.get<PendingRecord>(keys.pending(entry.interventionId));
        if (!entry.closed && !rec) {
          const iv = await this.failQueued(key, entry, "The page closed before your Mac came back online");
          if (iv) failed.push(iv);
          continue;
        }
        if (!this.sendToMac({ type: "reply", payload: replyPayload(entry) })) break;
        await this.storage.delete(key);
        this.queueHint = Math.max(0, (this.queueHint ?? 1) - 1);
        // Record the forward wherever the page lives now (a closed page's
        // archived copy too), so the detail is right and an unacknowledged
        // delivery times out like a direct forward.
        const loc = await this.locate(entry.interventionId);
        if (loc && loc.iv.deliveryStatus === "pending") {
          await loc.save({ ...loc.iv, deliveryDetail: "Sent to your Mac", deliveryForwardedAt: isoSeconds(Date.now()) });
        }
        console.log(`flushed queued reply for ${entry.interventionId}`);
      }
    } finally {
      this.flushing = false;
    }
    // Pushes await fetch (input gate opens), so they go after all mutations.
    await this.pushReplyFailures(failed);
  }

  /// Drops a queue entry and marks its intervention's reply failed so the
  /// user can retry. Returns the updated intervention when one was found
  /// (pending or archived: either way the user sent a reply that won't
  /// arrive and must hear about it).
  private async failQueued(key: string, entry: QueuedReply, detail: string): Promise<Intervention | undefined> {
    await this.storage.delete(key);
    if (this.queueHint !== undefined) this.queueHint = Math.max(0, this.queueHint - 1);
    console.log(`queued reply for ${entry.interventionId} dropped: ${detail}`);
    const loc = await this.locate(entry.interventionId);
    let iv: Intervention | undefined;
    if (loc && loc.iv.deliveryStatus === "pending") {
      iv = { ...loc.iv, deliveryStatus: "failed", deliveryDetail: detail, deliveryMethod: "queue" };
      delete iv.repliedAt;
      delete iv.repliedAction;
      await loc.save(iv);
    }
    this.broadcastToPhones({
      type: "reply.result",
      payload: { interventionId: entry.interventionId, success: false, method: "queue", detail }
    });
    return iv;
  }

  /// DELETE /reply/<id>: takes back a reply still waiting in the queue for an
  /// offline Mac (see decideRetract). Storage awaits only — no fetch, no
  /// push — so the input gate keeps flushReplyQueue out until it's done: a
  /// queue entry is either still here (deleted, never sent) or already gone
  /// to the Mac (too_late), never both. The phones hear reply.result with
  /// method "retracted" and `cancelled`; there is no APNs alert, since the
  /// user asked for this.
  private async retractReply(id: string): Promise<Response> {
    const queued: string[] = [];
    for (const [key, entry] of await this.storage.list<QueuedReply>({ prefix: prefixes.queue })) {
      if (entry?.interventionId === id) queued.push(key);
    }
    const loc = await this.locate(id);
    const tomb = loc ? undefined : await this.getTomb(id, Date.now());
    const decision = decideRetract({ queued: queued.length > 0, iv: loc?.iv, tomb });
    if (decision.kind !== "deleted") {
      console.log(`retract for ${id}: ${decision.kind} ${String(decision.body.stage ?? "")}`.trim());
      return jsonResponse(decision.body, decision.status);
    }

    await this.deleteAll(queued);
    if (this.queueHint !== undefined) this.queueHint = Math.max(0, this.queueHint - queued.length);
    if (loc && loc.iv.deliveryStatus === "pending") {
      // Freed like a failed delivery, so a fresh reply isn't refused with 409.
      const iv: Intervention = {
        ...loc.iv, deliveryStatus: "failed", deliveryMethod: RETRACTED_METHOD, deliveryDetail: RETRACTED_DETAIL
      };
      delete iv.repliedAt;
      delete iv.repliedAction;
      delete iv.repliedText;
      delete iv.deliveryForwardedAt;
      await loc.save(iv);
    }
    console.log(`retract for ${id}: deleted the queued reply`);
    this.broadcastToPhones({
      type: "reply.result",
      payload: { interventionId: id, success: false, method: RETRACTED_METHOD, cancelled: true, detail: RETRACTED_DETAIL }
    });
    return jsonResponse(decision.body, decision.status);
  }

  private async handleReplyInjected(raw: unknown): Promise<Outcome> {
    const p = parseReplyInjected(raw);
    if (!p) return fail("invalid_payload");
    // Never log `output` — it may contain terminal / model output.
    console.log(`reply.injected ${p.interventionId} success=${p.success} method=${p.method}`);

    const loc = await this.locate(p.interventionId);
    // The Mac deleted a reply it was holding (rate-limit or resume queue):
    // the user asked for that, so no "not delivered" alert.
    const retracted = !p.success && p.method === RETRACTED_METHOD;
    let failedIv: Intervention | undefined;
    if (loc) {
      const iv: Intervention = {
        ...loc.iv,
        deliveryStatus: p.success ? "delivered" : "failed",
        deliveryDetail: p.detail,
        deliveryMethod: p.method
      };
      if (!p.success) {
        // Free the page for a retry (409 only guards a live reply). Pushed
        // even when the page has closed meanwhile: the user still sent a
        // reply (often from a lingering lock-screen banner) that didn't land.
        delete iv.repliedAt;
        delete iv.repliedAction;
        if (retracted) {
          delete iv.repliedText;
          delete iv.deliveryForwardedAt;
        } else {
          failedIv = iv;
        }
      }
      await loc.save(iv);
    }
    this.broadcastToPhones({
      type: "reply.result",
      payload: {
        interventionId: p.interventionId, success: p.success, method: p.method, detail: p.detail,
        ...(retracted ? { cancelled: true } : {})
      }
    });
    if (failedIv) await this.pushReplyFailures([failedIv]);
    return ok();
  }

  /// Alert push for failed replies — only when no phone socket is open
  /// (a foregrounded app already got `reply.result`).
  private async pushReplyFailures(ivs: Intervention[], badge?: number): Promise<void> {
    if (!ivs.length || this.phoneConnected()) return;
    const now = Date.now();
    const count = badge ?? await this.pendingCount();
    for (const iv of ivs) {
      await this.pushToDevices(
        buildReplyFailedPush(iv, iv.deliveryDetail ?? "Reply not delivered", now, { badge: count }), "alert"
      );
    }
  }

  // MARK: live sessions (sessions-v1, see docs/SESSIONS-PROTOCOL.md)
  //
  // Forward and forget: no storage reads or writes, no APNs, and nothing
  // about the envelope is logged except its size.

  /// `sessions.update` from a Mac socket → every phone socket.
  private forwardSessionsUpdate(raw: unknown): Outcome {
    const p = parseSessionsUpdate(raw);
    if (!p.ok) return fail(p.error, p.error === "too_large" ? 413 : 400);
    const phones = this.phoneCount();
    if (phones) this.broadcastToPhones({ type: "sessions.update", payload: { e: p.e } });
    console.log(`sessions.update ${p.bytes}B → ${phones} phone(s)`);
    return ok();
  }

  /// POST /sessions/command: the phone's envelope → every Mac socket. Never
  /// queued: with no Mac online the phone hears 503 and can retry.
  private async handleSessionsCommand(req: Request): Promise<Response> {
    const body = await readJson(req, MAX_SESSIONS_COMMAND_BYTES, "too_large");
    if ("error" in body) return errorResponse(body.error, body.status);
    const e = parseSessionsCommand(body.value);
    if (!e) return errorResponse("invalid_envelope", 400);
    // Before the rate limit, so retries while the Mac is away don't drain
    // the bucket it needs once it's back.
    if (!this.macConnected()) return errorResponse("mac_offline", 503);
    const taken = takeToken(this.commandBucket, Date.now());
    this.commandBucket = taken.bucket;
    if (!taken.allowed) {
      console.warn("sessions.command rate limited");
      return errorResponse("rate_limited", 429);
    }
    if (!this.sendToMac({ type: "sessions.command", payload: { e } })) {
      return errorResponse("mac_offline", 503);
    }
    console.log(`sessions.command ${e.n.length + e.c.length}B forwarded`);
    return jsonResponse({ ok: true }, 202);
  }

  /// Tells every Mac socket how many phone sockets are open (the Mac sends
  /// live sessions only while someone is looking). Counted from
  /// getWebSockets, so it's right after hibernation too.
  /// `ws` / `adjust`: a socket to leave out of the count, then added back
  /// as `adjust` (1 for one just opened, 0 for one going away).
  private sendPhonesStatus(ws?: WebSocket, adjust: 0 | 1 = 0): void {
    this.sendToMac({ type: "phones.status", payload: { phones: this.phoneCount(ws) + adjust } });
  }

  // MARK: phone registration

  private async registerDevice(raw: unknown): Promise<Outcome> {
    const reg = parseDeviceRegistration(raw);
    if (!reg.ok) return fail(reg.error);
    const rec: DeviceRecord = { appVersion: reg.appVersion, registeredAt: isoSeconds(Date.now()) };
    if (reg.apnsEnv) {
      rec.apnsEnv = reg.apnsEnv;
    } else {
      // Older phones re-register on every launch; keep what we learned.
      const previous = await this.storage.get<DeviceRecord>(keys.device(reg.token));
      if (previous?.learnedEnv) rec.learnedEnv = previous.learnedEnv;
    }
    await this.storage.put(keys.device(reg.token), rec);

    const devices = await this.listDevices();
    if (devices.length > MAX_DEVICES) {
      const oldest = devices
        .filter(d => d.token !== reg.token)
        .sort((a, b) => a.rec.registeredAt.localeCompare(b.rec.registeredAt))
        .slice(0, devices.length - MAX_DEVICES);
      await this.deleteAll(oldest.map(d => keys.device(d.token)));
    }
    const effective = rec.apnsEnv ?? rec.learnedEnv ?? this.env.APNS_ENV;
    console.log(`device registered …${reg.token.slice(-8)} (${rec.apnsEnv ? effective : `unreported, using ${effective}`})`);
    return ok({ apnsEnv: effective });
  }

  private async unregisterDevice(raw: unknown): Promise<Outcome> {
    const token = isObject(raw) ? normalizeApnsToken(raw.apnsToken) : null;
    if (!token) return fail("invalid_apnsToken");
    const removed = !!(await this.storage.get(keys.device(token)));
    await this.storage.delete(keys.device(token));
    return ok({ removed });
  }

  // MARK: presence

  private async recordHeartbeat(raw: unknown): Promise<Outcome> {
    const now = Date.now();
    const hb = parseHeartbeat(raw, now);
    this.presence = {
      lastHeartbeatAt: isoSeconds(now),
      activeSessions: hb.activeSessions,
      battery: hb.battery,
      ...(hb.onAC !== undefined ? { onAC: hb.onAC } : {}),
      ...(hb.working !== undefined ? { working: hb.working } : {}),
      ...(hb.forecast ? { forecast: hb.forecast } : {}),
      ...(hb.usage ? { usage: hb.usage } : {})
    };
    // Forward to phone clients so the UI can show live session counts.
    this.broadcastToPhones({ type: "heartbeat", payload: hb });
    // Storage only every few minutes: /status falls back to it after
    // hibernation, and nothing else reads it.
    if (this.presenceSavedAt === undefined) {
      this.presenceSavedAt = (await this.storage.get<Meta>(keys.meta))?.presenceSavedAt ?? 0;
    }
    if (now - this.presenceSavedAt >= PRESENCE_PERSIST_MS) await this.persistPresence(now);
    return ok();
  }

  /// Persists meta.macEverSeen the first time Mac-side traffic arrives.
  private async noteMacSeen(): Promise<void> {
    if (this.macEverSeen) return;
    const meta = await this.getMeta();
    if (!meta.macEverSeen) {
      meta.macEverSeen = true;
      await this.storage.put(keys.meta, meta);
    }
    this.macEverSeen = true;
  }

  private async persistPresence(now: number): Promise<void> {
    if (!this.presence) return;
    const meta = await this.getMeta();
    meta.lastHeartbeatAt = this.presence.lastHeartbeatAt;
    meta.activeSessions = this.presence.activeSessions;
    meta.battery = this.presence.battery;
    if (this.presence.onAC !== undefined) meta.onAC = this.presence.onAC; else delete meta.onAC;
    if (this.presence.working !== undefined) meta.working = this.presence.working; else delete meta.working;
    if (this.presence.forecast) meta.forecast = this.presence.forecast; else delete meta.forecast;
    if (this.presence.usage) meta.usage = this.presence.usage; else delete meta.usage;
    meta.presenceSavedAt = now;
    await this.storage.put(keys.meta, meta);
    this.presenceSavedAt = now;
  }

  private async status(): Promise<Record<string, unknown>> {
    const meta = await this.getMeta();
    const p: Partial<Presence> = this.presence ?? {
      lastHeartbeatAt: meta.lastHeartbeatAt,
      activeSessions: meta.activeSessions,
      battery: meta.battery,
      onAC: meta.onAC,
      working: meta.working,
      forecast: meta.forecast,
      usage: meta.usage
    };
    const [pending, queue, devices] = await Promise.all([
      this.storage.list({ prefix: prefixes.pending }),
      this.storage.list({ prefix: prefixes.queue }),
      this.storage.list({ prefix: prefixes.device })
    ]);
    const macConnected = this.macConnected();
    const out: Record<string, unknown> = {
      macConnected,
      macEverSeen: meta.macEverSeen === true || !!meta.lastHeartbeatAt || !!this.presence || macConnected,
      pendingCount: pending.size,
      queuedReplies: queue.size,
      devices: devices.size,
      apnsConfigured: apnsConfigured(this.env),
      features: [SESSIONS_FEATURE, REPLY_RETRACT_FEATURE]
    };
    if (p.lastHeartbeatAt) out.lastHeartbeatAt = p.lastHeartbeatAt;
    if (typeof p.activeSessions === "number") out.activeSessions = p.activeSessions;
    if (typeof p.battery === "number" && p.battery >= 0) out.battery = p.battery;
    if (typeof p.onAC === "boolean") out.onAC = p.onAC;
    if (typeof p.working === "number") out.working = p.working;
    // A forecast only means something on battery.
    if (p.forecast && p.onAC === false) out.forecast = p.forecast;
    if (p.usage) out.usage = p.usage;
    if (this.lastPushError) out.lastPushError = this.lastPushError;
    return out;
  }

  // MARK: APNs

  private async pushToDevices(built: BuiltPush, pushType: PushRequest["pushType"]): Promise<void> {
    if (!apnsConfigured(this.env)) {
      if (!warnedApnsUnconfigured) {
        warnedApnsUnconfigured = true;
        console.warn("APNs secrets (APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID) not set — skipping pushes");
      }
      return;
    }
    const devices = await this.listDevices();
    if (!devices.length) return;
    const results = await Promise.all(devices.map(d => sendApnsPush(this.env, {
      token: d.token,
      env: d.rec.apnsEnv ?? d.rec.learnedEnv ?? this.env.APNS_ENV,
      envKnown: !!(d.rec.apnsEnv ?? d.rec.learnedEnv)
    }, {
      pushType,
      payload: d.rec.apnsEnv ? built.payload : withLegacyCategory(built.payload),
      collapseId: built.collapseId,
      expiration: built.expiration
    })));

    // Fresh reads from here on: other events may have run during the fetches.
    for (let i = 0; i < devices.length; i++) {
      const { token, rec } = devices[i];
      const r = results[i];
      if (r.dropDevice) {
        await this.storage.delete(keys.device(token));
        console.warn(`removed device …${token.slice(-8)}: APNs ${r.status} ${r.reason ?? ""}`);
      } else if (r.ok && !rec.apnsEnv && rec.learnedEnv !== r.env) {
        // Learned which host this older phone's token belongs to.
        const current = await this.storage.get<DeviceRecord>(keys.device(token));
        if (current && !current.apnsEnv) await this.storage.put(keys.device(token), { ...current, learnedEnv: r.env });
      }
      if (!r.ok) this.lastPushError = `${isoSeconds(Date.now())} ${r.status} ${r.reason ?? ""}`.trim();
    }
  }

  // MARK: storage helpers

  private async getMeta(): Promise<Meta> {
    return (await this.storage.get<Meta>(keys.meta)) ?? { schema: 2, historyCount: 0 };
  }

  private async listPending(): Promise<PendingRecord[]> {
    return [...(await this.storage.list<PendingRecord>({ prefix: prefixes.pending })).values()];
  }

  /// Pending pages right now (the app badge).
  private async pendingCount(): Promise<number> {
    return (await this.storage.list({ prefix: prefixes.pending })).size;
  }

  private async listDevices(): Promise<Array<{ token: string; rec: DeviceRecord }>> {
    const out: Array<{ token: string; rec: DeviceRecord }> = [];
    for (const [key, rec] of await this.storage.list<DeviceRecord>({ prefix: prefixes.device })) {
      out.push({ token: key.slice(prefixes.device.length), rec });
    }
    return out;
  }

  private async listHistory(params: URLSearchParams): Promise<Intervention[]> {
    const parsed = Number.parseInt(params.get("limit") ?? "", 10);
    const limit = Number.isFinite(parsed) ? Math.min(Math.max(parsed, 1), HISTORY_CAP) : 100;
    const all = params.get("all") === "1";
    const entries = await this.storage.list<Intervention>({
      prefix: prefixes.history, limit: all ? limit : HISTORY_CAP
    });
    const out: Intervention[] = [];
    for (const iv of entries.values()) {
      if (!all && HIDDEN_HISTORY_REASONS.has(iv.closeReason ?? "")) continue;
      out.push(iv);
      if (out.length >= limit) break;
    }
    return out;
  }

  /// Archives a closed intervention (newest first) and trims to HISTORY_CAP.
  /// `closedMs` keeps millisecond ordering in the key (closedAt is seconds).
  private async archive(iv: Intervention, closedMs: number): Promise<void> {
    const meta = await this.getMeta();
    const indexKey = keys.historyIndex(iv.id);
    const previous = await this.storage.get<string>(indexKey);
    if (previous) {
      // Same id archived before (reopened after its tombstone expired).
      await this.storage.delete(previous);
      meta.historyCount = Math.max(0, meta.historyCount - 1);
    }
    const historyKey = keys.history(closedMs, iv.id);
    await this.storage.put({ [historyKey]: iv, [indexKey]: historyKey });
    meta.historyCount += 1;

    if (meta.historyCount > HISTORY_CAP) {
      const oldest = await this.storage.list<Intervention>({
        prefix: prefixes.history, reverse: true, limit: meta.historyCount - HISTORY_CAP
      });
      const doomed: string[] = [];
      for (const key of oldest.keys()) {
        doomed.push(key, keys.historyIndex(idFromTimeKey(key, prefixes.history)));
      }
      await this.deleteAll(doomed);
      meta.historyCount -= oldest.size;
    }
    await this.storage.put(keys.meta, meta);
  }

  /// Removes an archived copy (the page is pending again).
  private async unarchive(id: string, historyKey: string): Promise<void> {
    await this.deleteAll([historyKey, keys.historyIndex(id)]);
    const meta = await this.getMeta();
    meta.historyCount = Math.max(0, meta.historyCount - 1);
    await this.storage.put(keys.meta, meta);
  }

  private async getArchived(id: string): Promise<{ key: string; iv: Intervention } | undefined> {
    const key = await this.storage.get<string>(keys.historyIndex(id));
    if (!key) return undefined;
    const iv = await this.storage.get<Intervention>(key);
    return iv ? { key, iv } : undefined;
  }

  /// Finds an intervention wherever it lives, with a setter that writes it
  /// back to the same place.
  private async locate(id: string): Promise<{ iv: Intervention; pending: boolean; save: (iv: Intervention) => Promise<void> } | undefined> {
    const rec = await this.storage.get<PendingRecord>(keys.pending(id));
    if (rec) {
      return {
        iv: rec.iv, pending: true,
        save: iv => this.storage.put(keys.pending(id), { ...rec, iv } satisfies PendingRecord)
      };
    }
    const archived = await this.getArchived(id);
    if (archived) return { iv: archived.iv, pending: false, save: iv => this.storage.put(archived.key, iv) };
    return undefined;
  }

  private async getTomb(id: string, now: number): Promise<Tombstone | undefined> {
    const t = await this.storage.get<Tombstone>(keys.tomb(id));
    return t && t.expiresAt > now ? t : undefined;
  }

  private async putTomb(id: string, reason: string, closedMs: number): Promise<void> {
    const t: Tombstone = { closedAt: isoSeconds(closedMs), reason, expiresAt: closedMs + TOMBSTONE_TTL_MS };
    await this.storage.put(keys.tomb(id), t);
  }

  /// Deletes expired tombstones (and the oldest beyond MAX_TOMBSTONES).
  /// Returns whether any remain.
  private async pruneTombstones(now: number): Promise<boolean> {
    const tombs = await this.storage.list<Tombstone>({ prefix: prefixes.tomb });
    const live: Array<[string, Tombstone]> = [];
    const doomed: string[] = [];
    for (const [key, t] of tombs) {
      if (!t || t.expiresAt <= now) doomed.push(key); else live.push([key, t]);
    }
    if (live.length > MAX_TOMBSTONES) {
      live.sort((a, b) => a[1].expiresAt - b[1].expiresAt);
      for (const [key] of live.splice(0, live.length - MAX_TOMBSTONES)) doomed.push(key);
    }
    await this.deleteAll(doomed);
    return live.length > 0;
  }

  private async scheduleAlarm(at: number): Promise<void> {
    const current = await this.storage.getAlarm();
    if (current === null || current > at) await this.storage.setAlarm(at);
  }

  /// Next alarm: the earliest queue expiry or hook-page expiry, or a
  /// tombstone sweep. Only ever moves an existing alarm earlier.
  private async rescheduleAlarm(now: number, haveTombs: boolean): Promise<void> {
    let next = haveTombs ? now + TOMBSTONE_TTL_MS + 60_000 : Infinity;
    for (const entry of (await this.storage.list<QueuedReply>({ prefix: prefixes.queue })).values()) {
      next = Math.min(next, entry.queuedAt + (entry.closed ? CLOSED_REPLY_WINDOW_MS : QUEUE_TTL_MS) + 1000);
    }
    for (const rec of await this.listPending()) {
      const at = hookPageExpiresAt(rec);
      if (at !== undefined) next = Math.min(next, at + 1000);
    }
    if (next !== Infinity) await this.scheduleAlarm(Math.max(next, now + 1000));
  }

  private async putAll(entries: Record<string, unknown>): Promise<void> {
    const all = Object.entries(entries);
    for (let i = 0; i < all.length; i += STORAGE_BATCH) {
      await this.storage.put(Object.fromEntries(all.slice(i, i + STORAGE_BATCH)));
    }
  }

  private async deleteAll(list: string[]): Promise<void> {
    for (let i = 0; i < list.length; i += STORAGE_BATCH) {
      await this.storage.delete(list.slice(i, i + STORAGE_BATCH));
    }
  }

  // MARK: socket helpers

  private roleOf(ws: WebSocket): WSAttachment["role"] {
    try { return (ws.deserializeAttachment() as WSAttachment | null)?.role; } catch { return undefined; }
  }

  private openSockets(): WebSocket[] {
    return this.state.getWebSockets().filter(ws => ws.readyState === WS_OPEN);
  }

  private macConnected(excluding?: WebSocket): boolean {
    return this.openSockets().some(ws => ws !== excluding && this.roleOf(ws) === "mac");
  }

  private phoneConnected(): boolean {
    return this.openSockets().some(ws => this.roleOf(ws) !== "mac");
  }

  /// Open phone sockets: every open socket that isn't tagged as a Mac.
  private phoneCount(excluding?: WebSocket): number {
    return this.openSockets().filter(ws => ws !== excluding && this.roleOf(ws) !== "mac").length;
  }

  private broadcastToPhones(env: OutboundEnvelope): void {
    const msg = JSON.stringify(env);
    for (const ws of this.openSockets()) {
      if (this.roleOf(ws) === "mac") continue;   // Macs ignore phone-facing frames
      try { ws.send(msg); } catch (err) { console.warn(`broadcast ${env.type} failed:`, err); }
    }
  }

  /// Sends to every open Mac socket. v2 Macs hold one shared socket; older
  /// builds opened one per backend and filter replies by id prefix, so they
  /// still need the broadcast. Returns whether any socket accepted it.
  /// `env` may come pre-serialised; `skip` leaves one socket out.
  private sendToMac(env: OutboundEnvelope | string, skip?: WebSocket): boolean {
    const msg = typeof env === "string" ? env : JSON.stringify(env);
    let delivered = 0;
    for (const ws of this.openSockets()) {
      if (ws === skip || this.roleOf(ws) !== "mac") continue;
      try { ws.send(msg); delivered++; } catch (err) { console.warn("sendToMac failed:", err); }
    }
    return delivered > 0;
  }
}

// MARK: file-scope helpers

/// Phones that don't report `apnsEnv` predate the per-kind categories and
/// only registered the legacy "PAGE" category; sending them PAGE_APPROVAL
/// etc. would show banners with no actions at all.
function withLegacyCategory(payload: Record<string, unknown>): Record<string, unknown> {
  const aps = payload.aps as Record<string, unknown> | undefined;
  if (!aps || typeof aps.category !== "string") return payload;
  return { ...payload, aps: { ...aps, category: "PAGE" } };
}

/// The old Worker wrote `toISOString()` timestamps (with milliseconds), which
/// phones in the field can't decode. Rewrites them in whole-second form.
function canonicalTimes(iv: Intervention): Intervention {
  const out = { ...iv };
  for (const field of ["openedAt", "closedAt", "repliedAt"] as const) {
    const v = out[field];
    const ms = typeof v === "string" ? Date.parse(v) : NaN;
    if (Number.isFinite(ms)) out[field] = isoSeconds(ms);
  }
  return out;
}

/// The `reply` frame for the Mac. v1 fields first; kind/backend/source are
/// v2 additions. `closed` marks free text aimed at a page that has already
/// closed — the Mac should only type it into an idle or busy session, never
/// into a prompt that's now showing.
function replyPayload(e: QueuedReply): Record<string, unknown> {
  const payload: Record<string, unknown> = {
    interventionId: e.interventionId,
    text: e.text,
    action: e.action,
    sessionId: e.sessionId,
    cwd: e.cwd,
    kind: e.kind,
    backend: e.backend
  };
  if (e.source) payload.source = e.source;
  if (e.closed) { payload.closed = true; payload.closeReason = e.closeReason; }
  // The hook's prompt key (pending tool_use id): the Mac matches it against
  // the prompt on screen. Omitted when unknown (older hooks, detector pages).
  if (e.promptKey) payload.promptKey = e.promptKey;
  return payload;
}

function ok(extra: Record<string, unknown> = {}): Outcome {
  return { status: 200, body: { ok: true, ...extra } };
}

function fail(error: string, status = 400): Outcome {
  return { status, body: { error } };
}

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function isSendableCloseCode(code: number): boolean {
  return code === 1000 || (code >= 1001 && code <= 1003) || (code >= 1007 && code <= 1014) ||
    (code >= 3000 && code <= 4999);
}

function truncateUtf8(s: string, maxBytes: number): string {
  const enc = new TextEncoder();
  if (enc.encode(s).length <= maxBytes) return s;
  let out = "";
  for (const ch of s) {
    if (enc.encode(out + ch).length > maxBytes) break;
    out += ch;
  }
  return out;
}

/// `maxBytes` / `tooLarge`: the route's body limit and its 413 error code.
async function readJson(
  req: Request, maxBytes: number = MAX_BODY_BYTES, tooLarge: string = "body_too_large"
): Promise<{ value: unknown } | { error: string; status: number }> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > maxBytes) return { error: tooLarge, status: 413 };
  let text: string;
  try { text = await req.text(); } catch { return { error: "bad_request", status: 400 }; }
  // UTF-16 length is a lower bound on the byte count; count exactly only
  // when it could matter.
  if (text.length > maxBytes || (text.length * 3 > maxBytes && utf8Length(text) > maxBytes)) {
    return { error: tooLarge, status: 413 };
  }
  if (!text.trim()) return { value: undefined };
  try { return { value: JSON.parse(text) }; } catch { return { error: "invalid_json", status: 400 }; }
}

export function jsonResponse(body: unknown, status: number = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      // Inbox / history endpoints are real-time state. Caching them at any
      // layer (URLSession on iOS, Cloudflare edge, intermediate proxy) leads
      // to ghost cards that won't go away even after the actual state changes.
      "cache-control": "no-store, no-cache, must-revalidate",
      "pragma": "no-cache"
    }
  });
}

export function errorResponse(error: string, status: number): Response {
  return jsonResponse({ error }, status);
}

export function retiredResponse(): Response {
  return jsonResponse({ error: "token_retired", why: TOKEN_RETIRED_WHY }, 410);
}
