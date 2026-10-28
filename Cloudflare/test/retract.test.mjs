// DELETE /reply/<id> (reply-retract-v1): taking back a reply that is still
// queued on the relay while the Mac is offline.
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { UserRelay } from "../src/durable.ts";
import { decideRetract, REPLY_RETRACT_FEATURE, RETRACTED_DETAIL } from "../src/logic.ts";
import { FakeState, FakeWS, clock, env, call, iv, open, close, macFrame } from "./helpers.mjs";

clock.install();

let state, relay;
beforeEach(() => {
  clock.now = Date.parse("2026-10-24T12:00:00.000Z");
  state = new FakeState();
  relay = new UserRelay(state, env());
});

const connect = (mac, r = relay) => { const ws = new FakeWS(); r.attachSocket(ws, mac); return ws; };
const retract = (id, r = relay) => call(r, "DELETE", `/reply/${encodeURIComponent(id)}`);
const heartbeat = (mac, r = relay) => macFrame(r, mac, "heartbeat", { ts: "t", activeSessions: 0, battery: 50 });
const pendingIv = async id => (await call(relay, "GET", "/interventions")).body.find(i => i.id === id);
const historyIv = async id => (await call(relay, "GET", "/history?all=1")).body.find(i => i.id === id);

const DELETED = { ok: true, retracted: true };
const NOTHING = { ok: true, retracted: false, nothing: true };

// MARK: pure decision

test("decideRetract table", () => {
  const t = "2026-10-24T12:00:00Z";
  const base = iv("a");
  const rows = [
    // [name, ctx, kind, status, body]
    ["queued", { queued: true, iv: { ...base, repliedAt: t, deliveryStatus: "pending" } }, "deleted", 200, DELETED],
    ["queued, record gone (history evicted)", { queued: true }, "deleted", 200, DELETED],
    ["queued on a closed page", { queued: true, iv: { ...base, closedAt: t, repliedAt: t, deliveryStatus: "pending" } }, "deleted", 200, DELETED],
    ["forwarded", { queued: false, iv: { ...base, repliedAt: t, deliveryStatus: "pending", deliveryForwardedAt: t } },
      "too_late", 409, { error: "too_late", stage: "forwarded", deliveryForwardedAt: t }],
    ["delivered", { queued: false, iv: { ...base, repliedAt: t, deliveryStatus: "delivered" } },
      "too_late", 409, { error: "too_late", stage: "delivered" }],
    ["hook-held (hookpre id)", { queued: false, iv: { ...iv("hookpre-x-1-2"), repliedAt: t, deliveryStatus: "pending" } },
      "hook_held", 409, { error: "hook_held" }],
    ["hook-held (v1 hookBlocking)", { queued: false, iv: { ...base, hookBlocking: true, repliedAt: t, deliveryStatus: "pending" } },
      "hook_held", 409, { error: "hook_held" }],
    ["pending, not queued/forwarded/hook", { queued: false, iv: { ...base, repliedAt: t, deliveryStatus: "pending" } },
      "too_late", 409, { error: "too_late", stage: "not_held" }],
    ["failed", { queued: false, iv: { ...base, deliveryStatus: "failed" } }, "nothing", 200, NOTHING],
    ["never replied", { queued: false, iv: base }, "nothing", 200, NOTHING],
    ["tombstoned only", { queued: false, tomb: { closedAt: t, reason: "timeout", expiresAt: 0 } }, "nothing", 200, NOTHING],
    ["unknown", { queued: false }, "not_found", 404, { error: "no_such_intervention" }]
  ];
  for (const [name, ctx, kind, status, body] of rows) {
    assert.deepEqual(decideRetract(ctx), { kind, status, body }, name);
  }
});

test("a forwarded reply past the 20-min ack timeout is still too late, not nothing", () => {
  // hasLiveReply would call it free; the Mac may still type it.
  const forwarded = "2026-10-24T11:00:00Z";
  const d = decideRetract({ queued: false, iv: { ...iv("a"), repliedAt: forwarded, deliveryStatus: "pending", deliveryForwardedAt: forwarded } });
  assert.equal(d.kind, "too_late");
  assert.equal(d.body.stage, "forwarded");
});

// MARK: routes

test("/status advertises reply-retract-v1", async () => {
  assert.ok((await call(relay, "GET", "/status")).body.features.includes(REPLY_RETRACT_FEATURE));
});

test("retract before the flush: the entry is gone, nothing reaches the Mac, the page is free again", async () => {
  const phone = connect(false);
  await open(relay, iv("a"));
  assert.deepEqual((await call(relay, "POST", "/reply/a", { text: "use the other branch", action: "custom" })).body, { ok: true, queued: true });
  assert.equal((await call(relay, "GET", "/status")).body.queuedReplies, 1);

  const r = await retract("a");
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, DELETED);
  assert.equal(state.storage.keysWithPrefix("q:").length, 0);
  assert.equal((await call(relay, "GET", "/status")).body.queuedReplies, 0);

  const stored = await pendingIv("a");
  assert.equal(stored.deliveryStatus, "failed");
  assert.equal(stored.deliveryMethod, "retracted");
  assert.equal(stored.deliveryDetail, RETRACTED_DETAIL);
  assert.equal(stored.repliedAt, undefined);
  assert.equal(stored.repliedAction, undefined);
  assert.equal(stored.repliedText, undefined);
  assert.deepEqual(phone.frames("reply.result").map(f => f.payload), [{
    interventionId: "a", success: false, method: "retracted", cancelled: true, detail: RETRACTED_DETAIL
  }]);

  const mac = connect(true);
  await heartbeat(mac);
  assert.equal(mac.frames("reply").length, 0, "nothing to flush");
});

test("retract after the flush: 409 too_late / forwarded, then delivered; the Mac keeps its one reply", async () => {
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "hi" });
  const mac = connect(true);
  await heartbeat(mac);
  assert.equal(mac.frames("reply").length, 1);

  const r = await retract("a");
  assert.equal(r.status, 409);
  assert.equal(r.body.error, "too_late");
  assert.equal(r.body.stage, "forwarded");
  assert.equal(r.body.deliveryForwardedAt, (await pendingIv("a")).deliveryForwardedAt);
  assert.equal((await pendingIv("a")).deliveryStatus, "pending", "record untouched");

  await macFrame(relay, mac, "reply.injected", { interventionId: "a", method: "tmux", success: true });
  const late = await retract("a");
  assert.equal(late.status, 409);
  assert.deepEqual(late.body, { error: "too_late", stage: "delivered" });
  assert.equal(mac.frames("reply").length, 1);
});

test("retract of a reply forwarded straight to a connected Mac is too late", async () => {
  connect(true);
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "", action: "approve" });
  const r = await retract("a");
  assert.equal(r.status, 409);
  assert.equal(r.body.stage, "forwarded");
});

test("retract after expiry: the sweep already failed it, so there's nothing to take back", async () => {
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "hi" });
  clock.advance(61 * 60 * 1000);
  await relay.alarm();
  const phone = connect(false);
  const r = await retract("a");
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, NOTHING);
  assert.equal(phone.frames("reply.result").length, 0, "no second result");
  assert.equal((await pendingIv("a")).deliveryMethod, "queue", "the expiry's record stays");
});

test("retract of an expired entry the sweep hasn't reached yet deletes it (it was never sent)", async () => {
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "hi" });
  clock.advance(61 * 60 * 1000);
  const r = await retract("a");
  assert.deepEqual(r.body, DELETED);
  assert.equal(state.storage.keysWithPrefix("q:").length, 0);
  await relay.alarm();
  assert.equal((await pendingIv("a")).deliveryMethod, "retracted", "the alarm finds nothing to fail");
});

test("retract of a queued reply whose page closed meanwhile updates the archived copy", async () => {
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "hi" });
  await close(relay, "a", "user_resolved_in_terminal");
  const r = await retract("a");
  assert.deepEqual(r.body, DELETED);
  const hist = await historyIv("a");
  assert.equal(hist.deliveryMethod, "retracted");
  assert.equal(hist.repliedAt, undefined);
  assert.equal(state.storage.keysWithPrefix("q:").length, 0);
});

test("retract of free text queued for a closed page (closed: true entry)", async () => {
  await open(relay, iv("a", { kind: "idle" }));
  await close(relay, "a", "user_resolved_in_terminal");
  clock.advance(60 * 1000);
  assert.deepEqual((await call(relay, "POST", "/reply/a", { text: "also run lint" })).body, { ok: true, queued: true });
  const [qkey] = state.storage.keysWithPrefix("q:");
  assert.equal((await state.storage.get(qkey)).closed, true);

  const r = await retract("a");
  assert.deepEqual(r.body, DELETED);
  assert.equal((await historyIv("a")).deliveryDetail, RETRACTED_DETAIL);
  const mac = connect(true);
  await heartbeat(mac);
  assert.equal(mac.frames("reply").length, 0);
});

test("double retract: the second is 200 nothing and broadcasts nothing", async () => {
  const phone = connect(false);
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "hi" });
  assert.deepEqual((await retract("a")).body, DELETED);
  const again = await retract("a");
  assert.equal(again.status, 200);
  assert.deepEqual(again.body, NOTHING);
  assert.equal(phone.frames("reply.result").length, 1);
});

test("retract then a new reply: accepted, queued afresh, and only the new text is flushed", async () => {
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "old" });
  await retract("a");
  const r = await call(relay, "POST", "/reply/a", { text: "new" });
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { ok: true, queued: true });
  assert.equal(state.storage.keysWithPrefix("q:").length, 1);
  const stored = await pendingIv("a");
  assert.equal(stored.deliveryStatus, "pending");
  assert.equal(stored.repliedText, "new");
  assert.equal(stored.deliveryMethod, undefined);

  const mac = connect(true);
  await heartbeat(mac);
  assert.deepEqual(mac.frames("reply").map(f => f.payload.text), ["new"]);
});

test("retract leaves other queued replies alone", async () => {
  await open(relay, iv("a"));
  await open(relay, iv("b", { sessionId: "sess-2" }));
  await call(relay, "POST", "/reply/a", { text: "for a" });
  clock.advance(1000);
  await call(relay, "POST", "/reply/b", { text: "for b" });
  assert.deepEqual((await retract("a")).body, DELETED);
  assert.equal((await call(relay, "GET", "/status")).body.queuedReplies, 1);
  const mac = connect(true);
  await heartbeat(mac);
  assert.deepEqual(mac.frames("reply").map(f => f.payload.interventionId), ["b"]);
});

test("a reply held for a blocking hook: 409 hook_held, record unchanged", async () => {
  await open(relay, iv("hookpre-abc-1-2"));
  await call(relay, "POST", "/reply/hookpre-abc-1-2", { text: "", action: "deny" });
  const before = await pendingIv("hookpre-abc-1-2");
  const r = await retract("hookpre-abc-1-2");
  assert.equal(r.status, 409);
  assert.deepEqual(r.body, { error: "hook_held" });
  assert.deepEqual(await pendingIv("hookpre-abc-1-2"), before);
});

test("no reply / unknown / tombstoned / bad ids", async () => {
  await open(relay, iv("a"));
  assert.deepEqual((await retract("a")).body, NOTHING);
  const unknown = await retract("nope");
  assert.equal(unknown.status, 404);
  assert.equal(unknown.body.error, "no_such_intervention", "not the old relay's not_found");
  await close(relay, "ghost", "timeout");        // close before open: tombstone only
  assert.deepEqual((await retract("ghost")).body, NOTHING);
  let r = await call(relay, "DELETE", "/reply/%E0%A4%A");
  assert.equal(r.status, 400);
  assert.equal(r.body.error, "bad_id");
  r = await call(relay, "DELETE", `/reply/${"x".repeat(201)}`);
  assert.equal(r.status, 400);
  r = await call(relay, "DELETE", "/reply/");
  assert.equal(r.body.error, "bad_id");
});

test("a retired token answers DELETE /reply with 410", async () => {
  const mac = connect(true);
  await macFrame(relay, mac, "relay.retire", { reason: "token_regenerated" });
  const r = await retract("a");
  assert.equal(r.status, 410);
  assert.equal(r.body.error, "token_retired");
});

// MARK: no APNs alert

const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
const PEM = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;
const apnsEnv = () => env({ APNS_KEY_P8: PEM, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234" });

let pushes, realFetch;
beforeEach(() => {
  pushes = [];
  realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    pushes.push({ url: String(url), body: JSON.parse(init.body) });
    return new Response(null, { status: 200 });
  };
});
afterEach(() => { globalThis.fetch = realFetch; });

test("a retract sends no push, even with no phone socket open", async () => {
  const r = new UserRelay(new FakeState(), apnsEnv());
  await call(r, "POST", "/device/register", { apnsToken: "a".repeat(64), apnsEnv: "development" });
  await open(r, iv("a"));
  await call(r, "POST", "/reply/a", { text: "hi" });
  pushes = [];
  assert.deepEqual((await retract("a", r)).body, DELETED);
  assert.equal(pushes.length, 0);
  // Contrast: an expiry with no phone open does alert.
  await open(r, iv("b", { sessionId: "sess-2" }));
  await call(r, "POST", "/reply/b", { text: "hi" });
  pushes = [];
  clock.advance(61 * 60 * 1000);
  await r.alarm();
  assert.equal(pushes.filter(p => p.body.aps?.alert).length, 1);
});

test("a Mac-side delete (reply.injected method retracted) frees the page without an alert", async () => {
  const r = new UserRelay(new FakeState(), apnsEnv());
  await call(r, "POST", "/device/register", { apnsToken: "a".repeat(64), apnsEnv: "development" });
  const mac = connect(true, r);
  await open(r, iv("a"));
  await call(r, "POST", "/reply/a", { text: "carry on" });
  pushes = [];
  await macFrame(r, mac, "reply.injected", { interventionId: "a", success: false, method: "retracted", detail: RETRACTED_DETAIL });
  assert.equal(pushes.length, 0);
  const a = (await call(r, "GET", "/interventions")).body.find(i => i.id === "a");
  assert.equal(a.deliveryMethod, "retracted");
  assert.equal(a.repliedText, undefined);
  assert.equal(a.deliveryForwardedAt, undefined);
  assert.equal((await call(r, "POST", "/reply/a", { text: "again" })).status, 200);
  // Contrast: a real failure still alerts.
  await open(r, iv("b", { sessionId: "sess-2" }));
  await call(r, "POST", "/reply/b", { text: "hi" });
  pushes = [];
  await macFrame(r, mac, "reply.injected", { interventionId: "b", success: false, method: "none", detail: "Not sent — the session ended" });
  assert.equal(pushes.filter(p => p.body.aps?.alert).length, 1);
});

test("a Mac-side delete broadcasts reply.result with cancelled", async () => {
  const mac = connect(true);
  const phone = connect(false);
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "carry on" });
  phone.sent.length = 0;
  await macFrame(relay, mac, "reply.injected", { interventionId: "a", success: false, method: "retracted", detail: RETRACTED_DETAIL });
  const results = phone.sent.map(s => JSON.parse(s)).filter(m => m.type === "reply.result");
  assert.equal(results.length, 1);
  assert.equal(results[0].payload.cancelled, true);
});
