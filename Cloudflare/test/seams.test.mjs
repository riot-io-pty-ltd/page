// Cross-component seams: the hook's promptKey (stored, echoed to the Mac),
// token retirement (relay.retire → 410 token_retired everywhere), and the
// push payload additions (projectName, background close push on supersede /
// evict).
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { UserRelay, TOKEN_RETIRED_CLOSE_CODE } from "../src/durable.ts";
import worker from "../src/index.ts";
import { buildAlertPush, buildReplyFailedPush, normalizeIntervention, normalizePromptKey } from "../src/logic.ts";
import { FakeState, FakeWS, clock, env, call, iv, open, close, macFrame } from "./helpers.mjs";

clock.install();

const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
const PEM = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;
const apnsEnv = () => env({ APNS_KEY_P8: PEM, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234" });
const TOKEN = "c".repeat(64);
const RETIRED = { error: "token_retired", why: "This pairing was replaced on your Mac — scan the new QR code" };

let calls, realFetch, state, relay;
beforeEach(async () => {
  clock.now = Date.parse("2026-10-24T12:00:00.000Z");
  calls = [];
  realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), headers: init.headers, body: JSON.parse(init.body) });
    return new Response(null, { status: 200 });
  };
  state = new FakeState();
  relay = new UserRelay(state, apnsEnv());
  await call(relay, "POST", "/device/register", { apnsToken: TOKEN, apnsEnv: "development" });
  calls = [];
});
afterEach(() => { globalThis.fetch = realFetch; });

const alerts = () => calls.filter(c => c.body.aps?.alert);
const silent = () => calls.filter(c => c.body.aps?.["content-available"] === 1);
const connect = (mac) => { const ws = new FakeWS(); relay.attachSocket(ws, mac); return ws; };

// MARK: promptKey

test("promptKey is stored on the page and echoed to the Mac in the reply frame", async () => {
  const mac = connect(true);
  await open(relay, iv("hook-11111111-100-1", { kind: "question", promptKey: "toolu_01AbC-9" }));
  const [stored] = (await call(relay, "GET", "/interventions")).body;
  assert.equal(stored.promptKey, "toolu_01AbC-9");
  await call(relay, "POST", "/reply/hook-11111111-100-1", { text: "1", action: "custom" });
  const [frame] = mac.frames("reply");
  assert.equal(frame.payload.promptKey, "toolu_01AbC-9");
});

test("promptKey survives the offline queue and the closed-page path", async () => {
  await open(relay, iv("hook-11111111-200-1", { sessionId: "s-q", kind: "question", promptKey: "toolu_Q" }));
  const r = await call(relay, "POST", "/reply/hook-11111111-200-1", { text: "yes", action: "custom" });
  assert.equal(r.body.queued, true);
  const mac = connect(true);
  await macFrame(relay, mac, "heartbeat", { activeSessions: 1 });
  assert.equal(mac.frames("reply")[0].payload.promptKey, "toolu_Q");

  // Free text to a page that closed a moment ago still carries its key.
  await open(relay, iv("hook-11111111-300-1", { sessionId: "s-c", kind: "idle", promptKey: "toolu_C" }));
  await close(relay, "hook-11111111-300-1", "user_resolved_in_terminal");
  mac.clear();
  await call(relay, "POST", "/reply/hook-11111111-300-1", { text: "carry on please" });
  const [f] = mac.frames("reply");
  assert.equal(f.payload.closed, true);
  assert.equal(f.payload.promptKey, "toolu_C");
});

test("pages without a (valid) promptKey send none: no null, no empty string", async () => {
  const mac = connect(true);
  await open(relay, iv("sess-1-permission-1"));
  await open(relay, iv("hook-22222222-1-1", { sessionId: "s-bad", kind: "question", promptKey: "bad key; rm -rf" }));
  for (const id of ["sess-1-permission-1", "hook-22222222-1-1"]) {
    await call(relay, "POST", `/reply/${id}`, { text: "ok", action: "custom" });
  }
  for (const f of mac.frames("reply")) assert.equal("promptKey" in f.payload, false, f.payload.interventionId);
  const listed = (await call(relay, "GET", "/interventions")).body;
  for (const p of listed) assert.equal(p.promptKey, undefined);
});

test("normalizePromptKey accepts tool_use ids only", () => {
  for (const ok of ["toolu_01ABCdef", "call_abc-123", "a", "x".repeat(200), "ns:id.1"]) assert.equal(normalizePromptKey(ok), ok);
  for (const bad of ["", " ", "x".repeat(201), "a b", "a\nb", "a\"b", 42, null, undefined, {}, ["toolu_1"]]) {
    assert.equal(normalizePromptKey(bad), undefined, JSON.stringify(bad));
  }
  const n = normalizeIntervention({ id: "x", sessionId: "s", promptKey: "toolu_9" }, clock.now);
  assert.equal(n.iv.promptKey, "toolu_9");
});

// MARK: token retirement

async function retireOverHttp() {
  return call(relay, "POST", "/intervention", { type: "relay.retire", payload: { reason: "token_regenerated" } });
}

test("relay.retire: every route then answers 410 token_retired, WS upgrades included", async () => {
  await open(relay, iv("sess-1-permission-1"));
  calls = [];
  const r = await retireOverHttp();
  assert.equal(r.status, 200);
  assert.equal(r.body.retired, true);

  const routes = [
    ["GET", "/interventions"], ["GET", "/history"], ["GET", "/history?all=1"], ["GET", "/status"],
    ["POST", "/reply/sess-1-permission-1", { text: "", action: "approve" }],
    ["POST", "/device/register", { apnsToken: TOKEN, apnsEnv: "development" }],
    ["POST", "/device/unregister", { apnsToken: TOKEN }],
    ["POST", "/intervention", { type: "intervention.opened", payload: iv("sess-2-permission-2", { sessionId: "s2" }) }],
    ["POST", "/intervention", { type: "heartbeat", payload: {} }],
    ["POST", "/intervention", { type: "relay.retire", payload: {} }],
    ["GET", "/nope"], ["GET", "/ws"]
  ];
  for (const [method, path, body] of routes) {
    const res = await call(relay, method, path, body);
    assert.equal(res.status, 410, `${method} ${path}`);
    assert.deepEqual(res.body, RETIRED, `${method} ${path}`);
  }
  // A real upgrade request is refused before any WebSocketPair is made.
  const up = await relay.fetch(new Request("https://relay.test/ws", { headers: { Upgrade: "websocket", "User-Agent": "page-ios/2" } }));
  assert.equal(up.status, 410);
  assert.deepEqual(await up.json(), RETIRED);
  assert.equal(calls.length, 0, "no push of any kind for a retired token");
});

test("retirement survives hibernation (a fresh object on the same storage)", async () => {
  await retireOverHttp();
  const woken = new UserRelay(new FakeState(state.storage), apnsEnv());
  const res = await call(woken, "GET", "/interventions");
  assert.equal(res.status, 410);
  assert.deepEqual(res.body, RETIRED);
  const meta = await state.storage.get("meta");
  assert.equal(meta.retired, true);
  assert.equal(meta.retiredReason, "token_regenerated");
});

test("relay.retire over the Mac socket: phones hear the closes and relay.retired, then every socket is closed", async () => {
  const phone = connect(false);
  const mac = connect(true);
  await open(relay, iv("sess-1-permission-1"));
  await open(relay, iv("sess-2-idle-2", { sessionId: "s2", kind: "idle" }));
  // A queued reply must never go out on the retired token.
  mac.readyState = 3;
  await call(relay, "POST", "/reply/sess-1-permission-1", { text: "", action: "approve" });
  const mac2 = connect(true);
  phone.clear();
  calls = [];

  await macFrame(relay, mac2, "relay.retire", { reason: "token_regenerated" });

  const closed = phone.frames("intervention.closed").map(f => [f.payload.id, f.payload.reason]).sort();
  assert.deepEqual(closed, [["sess-1-permission-1", "token_retired"], ["sess-2-idle-2", "token_retired"]]);
  const [retired] = phone.frames("relay.retired");
  assert.deepEqual(retired.payload, { reason: "token_regenerated", why: RETIRED.why });
  const types = phone.frames().map(f => f.type);
  assert.equal(types[types.length - 1], "relay.retired", "relay.retired comes last");
  assert.deepEqual(phone.closedWith, { code: TOKEN_RETIRED_CLOSE_CODE, reason: "token_retired" });
  assert.deepEqual(mac2.closedWith, { code: TOKEN_RETIRED_CLOSE_CODE, reason: "token_retired" });
  assert.equal(mac2.frames("reply").length, 0, "queued reply not flushed on the retiring socket");
  assert.equal(calls.length, 0, "no APNs push");

  // Pending pages, queue, devices dropped; nothing archived as a close.
  assert.deepEqual(state.storage.keysWithPrefix("p:"), []);
  assert.deepEqual(state.storage.keysWithPrefix("q:"), []);
  assert.deepEqual(state.storage.keysWithPrefix("dev:"), []);
  assert.deepEqual(state.storage.keysWithPrefix("tomb:"), []);
  assert.equal(state.storage.alarm, null);

  // A socket that somehow outlived it is closed on its next frame, and
  // the frame does nothing.
  const straggler = new FakeWS();
  straggler.attachment = { role: "mac" };
  await macFrame(relay, straggler, "intervention.opened", iv("sess-3-permission-3", { sessionId: "s3" }));
  assert.equal(straggler.closedWith.code, TOKEN_RETIRED_CLOSE_CODE);
  assert.deepEqual(state.storage.keysWithPrefix("p:"), []);
});

test("the alarm does nothing for a retired token", async () => {
  await open(relay, iv("hookpre-sess1-1-1", { holdSeconds: 10 }));
  await retireOverHttp();
  calls = [];
  clock.advance(60 * 60 * 1000);
  await relay.alarm();
  assert.equal(calls.length, 0);
  assert.equal(state.storage.alarm, null);
});

test("index.ts: /health stays 200 for everyone while a retired token gets 410", async () => {
  await retireOverHttp();
  const workerEnv = env({ USERS: { idFromName: t => t, get: () => relay } });
  const health = await worker.fetch(new Request("https://relay.test/health", {
    headers: { Authorization: "Bearer " + "r".repeat(43) }
  }), workerEnv, {});
  assert.equal(health.status, 200);
  assert.equal((await health.json()).ok, true);
  const res = await worker.fetch(new Request("https://relay.test/interventions", {
    headers: { Authorization: "Bearer " + "r".repeat(43) }
  }), workerEnv, {});
  assert.equal(res.status, 410);
  assert.deepEqual(await res.json(), RETIRED);
});

test("a token that was never retired is unaffected (older Macs never send relay.retire)", async () => {
  const res = await call(relay, "GET", "/status");
  assert.equal(res.status, 200);
  assert.equal(res.body.macEverSeen, false);
});

// MARK: push payloads

test("alert and reply-failed pushes carry a top-level projectName", async () => {
  await open(relay, iv("sess-1-permission-1", { projectName: "acme-web" }));
  assert.equal(alerts()[0].body.projectName, "acme-web");
  const p = buildReplyFailedPush({ ...iv("x"), projectName: "acme-web", backend: "claude", source: "terminal" }, "nope", clock.now);
  assert.equal(p.payload.projectName, "acme-web");
  const a = buildAlertPush({ ...iv("y"), projectName: "Agent", backend: "claude", source: "terminal" }, clock.now);
  assert.equal(a.payload.projectName, "Agent");

  // The pushed reply failure (Mac reports a failed injection, no phone socket).
  const mac = connect(true);
  await call(relay, "POST", "/reply/sess-1-permission-1", { text: "", action: "approve" });
  calls = [];
  await macFrame(relay, mac, "reply.injected", { interventionId: "sess-1-permission-1", success: false, method: "tmux", detail: "nope" });
  const [failed] = alerts();
  assert.equal(failed.body.replyFailed, true);
  assert.equal(failed.body.projectName, "acme-web");
});

test("an open that supersedes a page also sends a background close push with the superseded id", async () => {
  await open(relay, iv("sess-1-idle-1", { kind: "idle" }));
  calls = [];
  await open(relay, iv("sess-1-permission-2"));
  assert.equal(alerts().length, 1);
  assert.deepEqual(alerts()[0].body.interventionClosedIds, ["sess-1-idle-1"]);
  assert.equal(silent().length, 1);
  assert.deepEqual(silent()[0].body.interventionClosedIds, ["sess-1-idle-1"]);
  assert.equal(silent()[0].body.aps.badge, undefined);   // background push: no badge
  assert.equal(silent()[0].headers["apns-push-type"], "background");

  // No supersede, no extra push.
  calls = [];
  await open(relay, iv("sess-9-permission-3", { sessionId: "s9" }));
  assert.equal(alerts().length, 1);
  assert.equal(silent().length, 0);
});

test("an open that evicts the oldest page (200 cap) also sends the evicted id in a background push", async () => {
  for (let i = 0; i < 200; i++) {
    await open(relay, iv(`s${i}-idle-${i}`, { sessionId: `s${i}`, kind: "idle" }));
    clock.advance(10);
  }
  calls = [];
  await open(relay, iv("new-permission-1", { sessionId: "s-new" }));
  assert.deepEqual(alerts()[0].body.interventionClosedIds, ["s0-idle-0"]);
  assert.equal(silent().length, 1);
  assert.deepEqual(silent()[0].body.interventionClosedIds, ["s0-idle-0"]);
});
