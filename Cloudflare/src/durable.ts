import type {
  Env, Intervention, DeviceRegistration, InboundEnvelope, OutboundEnvelope
} from "./types";
import { sendApnsPush } from "./apns";

interface StoredState {
  apnsDeviceToken?: string;
  apnsAppVersion?: string;
  apnsRegisteredAt?: string;
  pendingInterventions: Record<string, Intervention>;
  history: Intervention[];   // newest first; capped at MAX_HISTORY
  replyQueue: Array<{ interventionId: string; text: string; action?: string | null }>;
  lastHeartbeatAt?: string;
  lastBattery?: number;
  lastActiveSessions?: number;
}

interface WSAttachment {
  role?: "mac" | "phone";
}

const INITIAL_STATE: StoredState = {
  pendingInterventions: {},
  history: [],
  replyQueue: []
};

const MAX_HISTORY = 500;
// Close reasons that count as a "meaningful" resolution worth archiving.
// Cleanup/dedup events are skipped so history isn't full of noise.
const HISTORY_WORTHY_REASONS = new Set([
  "replied",
  "session_resolved",
  "user_resolved_in_terminal",
  "timeout"
]);

const STATE_KEY = "state.v1";
const MAX_QUEUE = 200;

export class UserRelay {
  private state: DurableObjectState;
  private env: Env;
  private cached?: StoredState;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  // MARK: storage

  private async load(): Promise<StoredState> {
    if (this.cached) return this.cached;
    const stored = await this.state.storage.get<StoredState>(STATE_KEY);
    this.cached = stored ?? structuredClone(INITIAL_STATE);
    return this.cached;
  }

  private async save(s: StoredState): Promise<void> {
    this.cached = s;
    await this.state.storage.put(STATE_KEY, s);
  }

  // MARK: routing

  async fetch(req: Request): Promise<Response> {
    const url = new URL(req.url);
    const path = url.pathname;

    if (path === "/ws") {
      const upgrade = req.headers.get("Upgrade");
      if (upgrade !== "websocket") {
        return new Response("Expected WebSocket upgrade", { status: 426 });
      }
      const ua = req.headers.get("User-Agent") ?? "";
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      // Hibernation API — the WS connection survives DO eviction.
      this.state.acceptWebSocket(server);
      // Tag the Mac immediately by its User-Agent, so replies route correctly
      // even if it never sends an inbound message (passive-listen scenarios
      // are valid). iOS WSs are left untagged.
      if (ua.includes("page-mac")) {
        server.serializeAttachment({ role: "mac" } satisfies WSAttachment);
        await this.flushReplyQueue();
      }
      return new Response(null, { status: 101, webSocket: client });
    }

    if (req.method === "GET" && path === "/interventions") {
      const s = await this.load();
      const list = Object.values(s.pendingInterventions).sort(
        (a, b) => b.openedAt.localeCompare(a.openedAt)
      );
      return jsonResponse(list);
    }

    if (req.method === "GET" && path === "/history") {
      const s = await this.load();
      // history is stored newest-first; just slice to a sensible cap.
      const limitParam = parseInt(url.searchParams.get("limit") ?? "100", 10);
      const limit = Math.min(Math.max(limitParam, 1), MAX_HISTORY);
      return jsonResponse((s.history ?? []).slice(0, limit));
    }

    if (req.method === "POST" && path.startsWith("/reply/")) {
      const id = decodeURIComponent(path.slice("/reply/".length));
      return await this.handlePhoneReply(id, await safeJson(req));
    }

    if (req.method === "POST" && path === "/device/register") {
      return await this.handleDeviceRegister((await safeJson(req)) as Partial<DeviceRegistration>);
    }

    if (req.method === "POST" && path === "/intervention") {
      const env = (await safeJson(req)) as InboundEnvelope;
      await this.handleInbound(env);
      return jsonResponse({ ok: true });
    }

    return new Response("Not found", { status: 404 });
  }

  // MARK: hibernation-API WS handlers (Cloudflare-invoked)

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    try {
      const text = typeof message === "string"
        ? message
        : new TextDecoder().decode(message);
      const env = JSON.parse(text) as InboundEnvelope;

      // Tag the role from the first authoritative message.
      const macTypes = new Set([
        "intervention.opened", "intervention.closed", "heartbeat", "reply.injected"
      ]);
      const attachment = (ws.deserializeAttachment() ?? {}) as WSAttachment;
      if (!attachment.role && macTypes.has(env.type)) {
        ws.serializeAttachment({ role: "mac" });
        // Mac just identified itself — flush any queued replies for it.
        await this.flushReplyQueue();
      }

      await this.handleInbound(env);
    } catch (err) {
      console.error("WS frame parse error:", err);
    }
  }

  async webSocketClose(_ws: WebSocket, _code: number, _reason: string, _wasClean: boolean): Promise<void> {
    // No-op — getWebSockets() automatically excludes closed sockets.
  }

  async webSocketError(_ws: WebSocket, err: unknown): Promise<void> {
    console.warn("WS error:", err);
  }

  // MARK: inbound dispatch

  private async handleInbound(env: InboundEnvelope): Promise<void> {
    switch (env.type) {
      case "intervention.opened":
        await this.openIntervention(env.payload as Intervention);
        return;
      case "intervention.closed":
        await this.closeIntervention(env.payload as { id: string; reason?: string });
        return;
      case "heartbeat":
        await this.recordHeartbeat(env.payload as { ts: string; activeSessions: number; battery: number });
        return;
      case "reply.injected":
        console.log("reply.injected", env.payload);
        return;
      case "device.register":
        await this.handleDeviceRegister(env.payload as DeviceRegistration);
        return;
      default:
        console.warn("Unknown inbound type", (env as { type: string }).type);
    }
  }

  // MARK: intervention lifecycle

  private async openIntervention(iv: Intervention): Promise<void> {
    if (!iv.id || !iv.sessionId) return;
    const s = await this.load();
    if (s.pendingInterventions[iv.id]) return;

    // SUPERSEDE: a session has exactly one current state — newest wins. Close
    // any existing pending intervention for the same sessionId so the inbox
    // doesn't accumulate "IDLE 1m ago + QUESTION 0s ago" for the same project.
    const supersededIds: string[] = [];
    for (const [existingId, existing] of Object.entries(s.pendingInterventions)) {
      if (existing.sessionId === iv.sessionId && existingId !== iv.id) {
        supersededIds.push(existingId);
      }
    }
    for (const id of supersededIds) {
      delete s.pendingInterventions[id];
    }

    const stored: Intervention = {
      ...iv,
      openedAt: iv.openedAt || new Date().toISOString(),
      // Pre-Phase-4 Macs don't send these; default so downstream clients
      // can always rely on them being present.
      backend: iv.backend ?? "claude",
      source: iv.source ?? "terminal"
    };
    s.pendingInterventions[iv.id] = stored;
    await this.save(s);

    for (const id of supersededIds) {
      this.broadcast({ type: "intervention.closed", payload: { id, reason: "superseded" } });
    }

    // Push to every connected client (the iPhone sees this live, no APNs needed).
    this.broadcast({ type: "intervention.opened", payload: stored });

    // Also send via APNs for backgrounded apps.
    if (s.apnsDeviceToken) {
      try {
        await sendApnsPush(this.env, s.apnsDeviceToken, {
          aps: {
            alert: { title: `${iv.projectName} paged you`, body: this.bodyForPush(iv) },
            category: "PAGE", sound: "default", "mutable-content": 1
          },
          interventionId: iv.id, kind: iv.kind
        });
      } catch (err) { console.error("APNs push failed:", err); }
    }
  }

  private async closeIntervention(p: { id: string; reason?: string }): Promise<void> {
    const s = await this.load();
    const closing = s.pendingInterventions[p.id];
    if (!closing) return;
    const reason = p.reason ?? "closed";
    closing.closedAt = new Date().toISOString();
    closing.closeReason = reason;
    delete s.pendingInterventions[p.id];

    // Archive to history if the close represents a real resolution (not a
    // dedup or cleanup). Newest first, capped.
    if (HISTORY_WORTHY_REASONS.has(reason)) {
      if (!s.history) s.history = [];
      s.history.unshift(closing);
      if (s.history.length > MAX_HISTORY) s.history.length = MAX_HISTORY;
    }

    // CASCADE: if a session resolves one of its interventions (user typed in
    // the terminal, replied via phone, etc.) close any other pending entries
    // for the same session too. Stale duplicates shouldn't sit on the phone.
    const cascadeIds: string[] = [];
    for (const [otherId, other] of Object.entries(s.pendingInterventions)) {
      if (other.sessionId === closing.sessionId) {
        cascadeIds.push(otherId);
      }
    }
    for (const id of cascadeIds) {
      delete s.pendingInterventions[id];
    }
    await this.save(s);

    this.broadcast({ type: "intervention.closed", payload: { id: p.id, reason } });
    for (const id of cascadeIds) {
      this.broadcast({ type: "intervention.closed", payload: { id, reason: "session_resolved" } });
    }

    if (s.apnsDeviceToken) {
      try {
        await sendApnsPush(this.env, s.apnsDeviceToken, {
          aps: { "content-available": 1 },
          interventionClosedId: p.id
        }, { silent: true });
      } catch (err) { console.error("Silent APNs push failed:", err); }
    }
  }

  // MARK: phone replies

  private async handlePhoneReply(id: string, body: unknown): Promise<Response> {
    const reply = body as { text?: string; action?: string | null };
    if (!reply || typeof reply !== "object") {
      return new Response(JSON.stringify({ error: "bad_request" }), { status: 400 });
    }
    const text = (reply.text ?? "").toString();
    const action = reply.action ?? null;

    const s = await this.load();
    // Prefer the live intervention; if it was closed (e.g. via cascade right
    // before this reply landed), fall back to history so the user's typed
    // text isn't silently dropped.
    const livedIv: Intervention | undefined = s.pendingInterventions[id];
    const historyIv: Intervention | undefined = (s.history ?? []).find(h => h.id === id);
    const iv: Intervention | undefined = livedIv ?? historyIv;
    const source: "pending" | "history" = livedIv ? "pending" : "history";
    if (!iv) {
      return new Response(JSON.stringify({ error: "no_such_intervention" }), { status: 404 });
    }

    iv.repliedAt = new Date().toISOString();
    iv.repliedText = text;
    iv.repliedAction = action ?? undefined;
    await this.save(s);
    console.log(`reply for ${id} (${source}) — forwarding text=${text.length}B action=${action}`);

    const envelope: OutboundEnvelope = {
      type: "reply",
      payload: { interventionId: id, text, action, sessionId: iv.sessionId, cwd: iv.cwd }
    };

    const delivered = this.sendToMac(envelope);
    if (!delivered) {
      s.replyQueue.push({ interventionId: id, text, action });
      if (s.replyQueue.length > MAX_QUEUE) s.replyQueue.shift();
      await this.save(s);
    }

    return jsonResponse({ ok: true, queued: !delivered });
  }

  private async flushReplyQueue(): Promise<void> {
    const s = await this.load();
    if (!s.replyQueue.length) return;
    const buffer = [...s.replyQueue];
    s.replyQueue = [];
    await this.save(s);
    for (const r of buffer) {
      const iv = s.pendingInterventions[r.interventionId];
      const env: OutboundEnvelope = {
        type: "reply",
        payload: {
          interventionId: r.interventionId,
          text: r.text,
          action: r.action ?? null,
          sessionId: iv?.sessionId,
          cwd: iv?.cwd
        }
      };
      this.sendToMac(env);
    }
  }

  // MARK: phone registration

  private async handleDeviceRegister(reg: Partial<DeviceRegistration>): Promise<Response> {
    if (!reg.apnsToken) {
      return new Response(JSON.stringify({ error: "missing_apnsToken" }), { status: 400 });
    }
    const s = await this.load();
    s.apnsDeviceToken = reg.apnsToken;
    s.apnsAppVersion = reg.appVersion ?? "unknown";
    s.apnsRegisteredAt = new Date().toISOString();
    await this.save(s);
    return jsonResponse({ ok: true });
  }

  // MARK: socket helpers

  private broadcast(env: OutboundEnvelope): void {
    const msg = JSON.stringify(env);
    const sockets = this.state.getWebSockets();
    let sent = 0;
    for (const ws of sockets) {
      try {
        if (ws.readyState === WebSocket.READY_STATE_OPEN) { ws.send(msg); sent++; }
      } catch (err) {
        console.warn("broadcast send failed:", err);
      }
    }
    console.log(`broadcast ${env.type}: sent=${sent} total=${sockets.length}`);
  }

  private sendToMac(env: OutboundEnvelope): boolean {
    // Broadcast to every connected mac socket. The Mac side may have
    // multiple RelayClient instances (one per backend — Claude and Codex
    // each maintain their own). Each backend filters incoming replies by
    // intervention-ID prefix so only the right one acts. Sending to only
    // the first mac socket would silently drop replies for whichever
    // backend isn't first in the iteration.
    const msg = JSON.stringify(env);
    let delivered = 0;
    for (const ws of this.state.getWebSockets()) {
      const role = (ws.deserializeAttachment() as WSAttachment | null)?.role;
      if (role === "mac" && ws.readyState === WebSocket.READY_STATE_OPEN) {
        try { ws.send(msg); delivered++; } catch (err) { console.warn("sendToMac failed:", err); }
      }
    }
    return delivered > 0;
  }

  // MARK: misc

  private async recordHeartbeat(p: { ts: string; activeSessions: number; battery: number }): Promise<void> {
    const s = await this.load();
    s.lastHeartbeatAt = p.ts;
    s.lastActiveSessions = p.activeSessions;
    s.lastBattery = p.battery;
    await this.save(s);
    // Forward to phone clients so the UI can show live session counts.
    this.broadcast({ type: "heartbeat", payload: p });
  }

  private bodyForPush(iv: Intervention): string {
    const max = 180;
    const trimmed = iv.context.length > max ? iv.context.slice(0, max) + "…" : iv.context;
    switch (iv.kind) {
      case "permission":
      case "approval":   return `Approval needed: ${trimmed}`;
      case "plan":       return `Plan ready: ${trimmed}`;
      case "question":
      case "user_input": return trimmed;
      case "idle":       return `Session is waiting: ${trimmed}`;
      case "rate_limit": return `Rate-limited: ${trimmed}`;
    }
  }
}

// MARK: file-scope helpers

function jsonResponse(body: unknown, status: number = 200): Response {
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

async function safeJson(req: Request): Promise<unknown> {
  try { return await req.json(); } catch { return {}; }
}
