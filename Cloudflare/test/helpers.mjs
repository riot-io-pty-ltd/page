// Minimal in-memory stand-ins for the Durable Object runtime, enough to run
// src/durable.ts under plain node (which strips the TypeScript types itself).
// Storage clones values on the way in and out, like the real thing, so
// tests catch code that mutates a value it read and forgets to write it back.

export class FakeStorage {
  constructor() {
    this.map = new Map();
    this.alarm = null;
    this.writes = 0;
  }

  async get(key) {
    if (Array.isArray(key)) {
      const out = new Map();
      for (const k of key) if (this.map.has(k)) out.set(k, structuredClone(this.map.get(k)));
      return out;
    }
    return this.map.has(key) ? structuredClone(this.map.get(key)) : undefined;
  }

  async put(key, value) {
    if (typeof key === "object") {
      const entries = Object.entries(key);
      if (entries.length > 128) throw new Error("put: more than 128 keys");
      for (const [k, v] of entries) this.map.set(k, structuredClone(v));
      this.writes += entries.length;
      return;
    }
    this.map.set(key, structuredClone(value));
    this.writes++;
  }

  async delete(key) {
    if (Array.isArray(key)) {
      if (key.length > 128) throw new Error("delete: more than 128 keys");
      let n = 0;
      for (const k of key) if (this.map.delete(k)) n++;
      return n;
    }
    return this.map.delete(key);
  }

  async list({ prefix = "", limit, reverse = false } = {}) {
    let ks = [...this.map.keys()].filter(k => k.startsWith(prefix)).sort();
    if (reverse) ks.reverse();
    if (limit !== undefined) ks = ks.slice(0, limit);
    return new Map(ks.map(k => [k, structuredClone(this.map.get(k))]));
  }

  async getAlarm() { return this.alarm; }
  async setAlarm(t) { this.alarm = typeof t === "number" ? t : t.getTime(); }
  async deleteAlarm() { this.alarm = null; }

  keysWithPrefix(prefix) {
    return [...this.map.keys()].filter(k => k.startsWith(prefix)).sort();
  }
}

export class FakeWS {
  constructor() {
    this.sent = [];
    this.readyState = 1;
    this.attachment = null;
    this.closedWith = null;
    this.failSend = false;
  }
  send(msg) {
    if (this.failSend) throw new Error("socket dead");
    this.sent.push(msg);
  }
  serializeAttachment(a) { this.attachment = structuredClone(a); }
  deserializeAttachment() { return this.attachment; }
  close(code, reason) {
    this.closedWith = { code, reason };
    this.readyState = 3;
  }
  frames(type) {
    const all = this.sent.filter(s => s !== "pong").map(s => JSON.parse(s));
    return type ? all.filter(f => f.type === type) : all;
  }
  clear() { this.sent = []; }
}

export class FakeState {
  constructor(storage = new FakeStorage()) {
    this.storage = storage;
    this.sockets = [];
  }
  acceptWebSocket(ws) { this.sockets.push(ws); }
  getWebSockets() { return this.sockets.filter(ws => ws.readyState !== 3); }
  blockConcurrencyWhile(fn) { return fn(); }
  setWebSocketAutoResponse() {}
}

/// Controllable clock: everything in src/ reads Date.now().
export const clock = {
  now: Date.parse("2026-10-24T12:00:00.000Z"),
  install() {
    this.real = Date.now;
    Date.now = () => this.now;
  },
  advance(ms) { this.now += ms; }
};

export const env = (overrides = {}) => ({
  USERS: null,
  APNS_BUNDLE_ID: "app.page.Page",
  APNS_ENV: "development",
  ...overrides
});

export function req(method, path, body) {
  return new Request(`https://relay.test${path}`, {
    method,
    headers: body === undefined ? {} : { "content-type": "application/json" },
    body: body === undefined ? undefined : (typeof body === "string" ? body : JSON.stringify(body))
  });
}

export async function call(relay, method, path, body) {
  const res = await relay.fetch(req(method, path, body));
  const text = await res.text();
  return { status: res.status, body: text ? JSON.parse(text) : null, headers: res.headers };
}

export function iv(id, overrides = {}) {
  return {
    id,
    sessionId: "sess-1",
    cwd: "/Users/me/projects/acme",
    projectName: "acme",
    kind: "permission",
    context: "Bash: npm test",
    openedAt: new Date(clock.now).toISOString(),
    ...overrides
  };
}

export const open = (relay, intervention) =>
  call(relay, "POST", "/intervention", { type: "intervention.opened", payload: intervention });

export const close = (relay, id, reason) =>
  call(relay, "POST", "/intervention", { type: "intervention.closed", payload: { id, reason } });

export const macFrame = (relay, ws, type, payload) =>
  relay.webSocketMessage(ws, JSON.stringify({ type, payload }));
