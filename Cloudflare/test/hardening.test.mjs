// Regression tests for the hook-page lifecycle (legacy v1 blocking hook,
// shadowed pages, orphan expiry), reply-failure pushes, sync grace, badge
// counts and Mac presence (macEverSeen).
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { UserRelay } from "../src/durable.ts";
import {
  decideOpenPush, selectStaleForSync, isLegacyBlockingHookOpen, hookPageExpiresAt,
  HOOK_EXPIRY_MARGIN_MS, HOOK_MAX_HOLD_MS, HOOK_PAGE_MAX_AGE_MS, DELIVERY_ACK_TIMEOUT_MS,
  buildReplyFailedPush, normalizeIntervention
} from "../src/logic.ts";
import { FakeState, FakeStorage, FakeWS, clock, env, call, iv, open, close, macFrame } from "./helpers.mjs";

clock.install();

const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
const PEM = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;
const apnsEnv = () => env({ APNS_KEY_P8: PEM, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234" });
const TOKEN = "b".repeat(64);
const SID = "11111111-2222-3333-4444-555555555555";

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
const pendingIds = async () => (await call(relay, "GET", "/interventions")).body.map(i => i.id).sort();
const connect = (mac) => { const ws = new FakeWS(); relay.attachSocket(ws, mac); return ws; };

/// POST /intervention with a User-Agent (the hook's route).
async function postAs(ua, type, payload) {
  const res = await relay.fetch(new Request("https://relay.test/intervention", {
    method: "POST",
    headers: { "content-type": "application/json", "User-Agent": ua },
    body: JSON.stringify({ type, payload })
  }));
  return { status: res.status, body: await res.json() };
}

/// The v1 hook's PreToolUse open, exactly as HEAD's script built it.
const v1PreToolUse = (id, o = {}) => ({
  id, sessionId: SID, cwd: "/Users/me/acme", projectName: "acme", kind: "permission",
  openedAt: "2026-10-24T12:00:00Z", context: "$ rm -rf build", ...o
});
const detector = (t = 100, o = {}) => iv(`${SID}-permission-${t}`, { sessionId: SID, ...o });

// MARK: F1 — the deployed v1 blocking hook

test("v1 blocking hook page: reply stored for the hook, never forwarded to the Mac, never erased", async () => {
  const mac = connect(true);
  const r = await postAs("page-hook/1.0", "intervention.opened", v1PreToolUse("hook-11111111-1-1"));
  assert.equal(r.status, 200);
  const [stored] = (await call(relay, "GET", "/interventions")).body;
  assert.equal(stored.hookBlocking, true);

  const reply = await call(relay, "POST", "/reply/hook-11111111-1-1", { text: "", action: "approve" });
  assert.deepEqual(reply.body, { ok: true, queued: false });
  assert.equal(mac.frames("reply").length, 0, "the Mac must not get it (its refusal used to erase the answer)");
  // What the v1 hook polls for: `.[] | select(.id == $id) | .repliedAction`.
  const [polled] = (await call(relay, "GET", "/interventions")).body;
  assert.equal(polled.repliedAction, "approve");

  // The v1 hook closes with "replied" once it read it: delivered.
  await postAs("page-hook/1.0", "intervention.closed", { id: "hook-11111111-1-1", reason: "replied" });
  const [h] = (await call(relay, "GET", "/history")).body;
  assert.equal(h.deliveryStatus, "delivered");
  // A later reply to the finished hook page is refused, not sent to the Mac.
  const late = await call(relay, "POST", "/reply/hook-11111111-1-1", { text: "", action: "deny" });
  assert.equal(late.status, 409);
  // A v1 page whose hook timed out (reply unread) answers 410, never the Mac.
  await postAs("page-hook/1.0", "intervention.opened", v1PreToolUse("hook-11111111-1-3", { sessionId: "s-t" }));
  await postAs("page-hook/1.0", "intervention.closed", { id: "hook-11111111-1-3", reason: "timeout" });
  const gone = await call(relay, "POST", "/reply/hook-11111111-1-3", { text: "", action: "approve" });
  assert.equal(gone.status, 410);
  assert.equal(gone.body.why, "hook_finished");
  assert.equal(mac.frames("reply").length, 0);
});

test("v1 blocking hook page only accepts Approve or Deny (it turns anything else into allow)", async () => {
  await postAs("page-hook/1.0", "intervention.opened", v1PreToolUse("hook-11111111-1-2"));
  for (const body of [{ text: "no, don't", action: "custom" }, { text: "", action: "carry_on" }, { text: "stop" }]) {
    const r = await call(relay, "POST", "/reply/hook-11111111-1-2", body);
    assert.equal(r.status, 422, JSON.stringify(body));
    assert.equal(r.body.error, "approve_or_deny_only");
  }
  const [still] = (await call(relay, "GET", "/interventions")).body;
  assert.equal(still.repliedAt, undefined);
  const deny = await call(relay, "POST", "/reply/hook-11111111-1-2", { text: "", action: "deny" });
  assert.equal(deny.status, 200);
});

test("v1 Notification pages, v2 hook pages and WS opens are still delivered by the Mac", async () => {
  const mac = connect(true);
  // v1 Notification path: kind "question" — the Mac types the reply.
  await postAs("page-hook/1.0", "intervention.opened", v1PreToolUse("hook-11111111-2-1", { kind: "question", sessionId: "s-q" }));
  // Current script: sends backend.
  await postAs("page-hook/3.0", "intervention.opened", v1PreToolUse("hook-11111111-2-2", { sessionId: "s-v3", backend: "claude" }));
  // Same shape over the Mac socket: no User-Agent, never flagged.
  await macFrame(relay, mac, "intervention.opened", v1PreToolUse("hook-11111111-2-3", { sessionId: "s-ws" }));
  for (const id of ["hook-11111111-2-1", "hook-11111111-2-2", "hook-11111111-2-3"]) {
    const r = await call(relay, "POST", `/reply/${id}`, { text: "go", action: "custom" });
    assert.equal(r.status, 200, id);
  }
  assert.deepEqual(mac.frames("reply").map(f => f.payload.interventionId).sort(),
    ["hook-11111111-2-1", "hook-11111111-2-2", "hook-11111111-2-3"]);
});

test("isLegacyBlockingHookOpen needs every v1 trait, and the flag can't be forged in a payload", () => {
  const raw = v1PreToolUse("hook-x");
  assert.equal(isLegacyBlockingHookOpen(raw, "page-hook/1.0"), true);
  assert.equal(isLegacyBlockingHookOpen(raw, "page-hook/3.0"), false);
  assert.equal(isLegacyBlockingHookOpen(raw, undefined), false);
  assert.equal(isLegacyBlockingHookOpen({ ...raw, backend: "claude" }, "page-hook/1.0"), false);
  assert.equal(isLegacyBlockingHookOpen({ ...raw, kind: "question" }, "page-hook/1.0"), false);
  assert.equal(isLegacyBlockingHookOpen({ ...raw, id: "x-1" }, "page-hook/1.0"), false);
  const n = normalizeIntervention({ ...raw, hookBlocking: true }, clock.now);
  assert.equal(n.iv.hookBlocking, undefined);
});

// MARK: F4 — a hook page replaces the detector page only while it holds

test("hook gives up: the detector page it replaced comes back and alerts", async () => {
  const phone = connect(false);
  await open(relay, detector());
  assert.equal(alerts().length, 1);
  clock.advance(2000);
  await open(relay, iv("hookpre-11111111-2-9", { sessionId: SID, holdSeconds: 540 }));
  assert.deepEqual(await pendingIds(), ["hookpre-11111111-2-9"]);
  // Archived (a reply gets a clear 410) but not tombstoned.
  const r410 = await call(relay, "POST", `/reply/${SID}-permission-100`, { text: "x", action: "custom" });
  assert.equal(r410.status, 410);

  // The phone replies to the hook page, which rewrites its record: the
  // shadow list and expiry must survive that.
  await call(relay, "POST", "/reply/hookpre-11111111-2-9", { text: "", action: "approve" });
  const rec = await state.storage.get("p:hookpre-11111111-2-9");
  assert.deepEqual(rec.shadowed, [`${SID}-permission-100`]);
  assert.ok(rec.hookExpiresAt > clock.now);

  calls = [];
  phone.clear();
  clock.advance(540_000);
  await close(relay, "hookpre-11111111-2-9", "timeout");
  assert.deepEqual(await pendingIds(), [`${SID}-permission-100`]);
  assert.deepEqual(phone.frames("intervention.opened").map(f => f.payload.id), [`${SID}-permission-100`]);
  const back = alerts().find(c => c.body.interventionId === `${SID}-permission-100`);
  assert.ok(back, "the restored page alerts again");
  assert.equal(back.body.aps.badge, 1);
  // The unread reply is reported as failed (a connected phone gets reply.result).
  assert.equal(phone.frames("reply.result")[0].payload.success, false);
  // Hidden history no longer lists it as superseded.
  const all = (await call(relay, "GET", "/history?all=1")).body.map(h => h.id);
  assert.ok(!all.includes(`${SID}-permission-100`));
  // Replies to the restored page go to the Mac as usual.
  const mac = connect(true);
  const r = await call(relay, "POST", `/reply/${SID}-permission-100`, { text: "", action: "approve" });
  assert.equal(r.status, 200);
  assert.equal(mac.frames("reply").length, 1);
});

test("hook answered the prompt: the replaced page stays closed and a late open is ignored", async () => {
  await open(relay, detector());
  await open(relay, iv("hookpre-11111111-3-1", { sessionId: SID }));
  await call(relay, "POST", "/reply/hookpre-11111111-3-1", { text: "", action: "approve" });
  await close(relay, "hookpre-11111111-3-1", "replied");
  assert.deepEqual(await pendingIds(), []);
  const again = await open(relay, detector());
  assert.equal(again.body.ignored, "closed");
});

test("user_returned restores the card without a buzz; a Mac close meanwhile keeps it closed", async () => {
  await open(relay, detector());
  await open(relay, iv("hookpre-11111111-4-1", { sessionId: SID }));
  calls = [];
  await close(relay, "hookpre-11111111-4-1", "user_returned");
  assert.deepEqual(await pendingIds(), [`${SID}-permission-100`]);
  assert.equal(alerts().length, 0);

  // Second round: the Mac resolves the detector page while the hook holds.
  await open(relay, detector(200));
  await open(relay, iv("hookpre-11111111-4-2", { sessionId: SID }));
  await close(relay, `${SID}-permission-200`, "user_resolved_in_terminal");
  await close(relay, "hookpre-11111111-4-2", "timeout");
  assert.deepEqual(await pendingIds(), []);
});

test("a page stored silently while the hook held the session alerts once the hook gives up", async () => {
  await open(relay, iv("hookpre-11111111-5-1", { sessionId: SID }));
  clock.advance(1000);
  await open(relay, detector(300, { kind: "idle" }));
  calls = [];
  await close(relay, "hookpre-11111111-5-1", "hook_fallback");
  assert.deepEqual(alerts().map(c => c.body.interventionId), [`${SID}-permission-300`]);
});

// MARK: W1 / H1 / W4 — orphaned hook pages expire

test("an orphaned hookpre page expires after the hook's own wait plus margin and stops muting the session", async () => {
  const phone = connect(false);
  await open(relay, detector());
  await open(relay, iv("hookpre-11111111-6-1", { sessionId: SID, holdSeconds: 60 }));
  const rec = await state.storage.get("p:hookpre-11111111-6-1");
  assert.equal(rec.hookExpiresAt, clock.now + 60_000 + HOOK_EXPIRY_MARGIN_MS);
  assert.ok(state.storage.alarm <= rec.hookExpiresAt + 1000, "an alarm covers the expiry");
  await call(relay, "POST", "/reply/hookpre-11111111-6-1", { text: "", action: "approve" });
  phone.close(1000, "bye");  // backgrounded phone: failures are pushed

  calls = [];
  clock.now = state.storage.alarm;
  await relay.alarm();
  assert.deepEqual(await pendingIds(), [`${SID}-permission-100`], "closed as hook_lost; the shadowed page is back");
  const hist = (await call(relay, "GET", "/history")).body;
  const lost = hist.find(h => h.id === "hookpre-11111111-6-1");
  assert.equal(lost.closeReason, "hook_lost");
  assert.equal(lost.deliveryStatus, "failed");
  assert.ok(silent().some(c => c.body.interventionClosedIds.includes("hookpre-11111111-6-1")));
  assert.ok(alerts().some(c => c.body.replyFailed === true && c.body.interventionId === "hookpre-11111111-6-1"));
  assert.ok(alerts().some(c => c.body.interventionId === `${SID}-permission-100`));
});

test("expired hook records are ignored for push dedupe even before the alarm runs", async () => {
  await open(relay, iv("hookpre-11111111-7-1", { sessionId: SID }));   // no holdSeconds: 3600 s cap
  const rec = await state.storage.get("p:hookpre-11111111-7-1");
  assert.equal(rec.hookExpiresAt, clock.now + HOOK_MAX_HOLD_MS + HOOK_EXPIRY_MARGIN_MS);
  assert.equal(decideOpenPush(detector(), [rec], clock.now + 1000), "none");
  assert.equal(decideOpenPush(detector(), [rec], rec.hookExpiresAt), "alert");
  // Through the open path: the orphan is reaped and the new page buzzes.
  clock.now = rec.hookExpiresAt + 5;
  calls = [];
  await open(relay, detector(9999));
  assert.ok(alerts().some(c => c.body.interventionId === `${SID}-permission-9999`));
  assert.deepEqual(await pendingIds(), [`${SID}-permission-9999`]);
});

test("notification hook pages expire after a day (archived, tombstoned, no cascade)", async () => {
  await open(relay, iv("hook-11111111-8-1", { sessionId: "s-n", kind: "question", backend: "claude" }));
  const rec = await state.storage.get("p:hook-11111111-8-1");
  assert.equal(hookPageExpiresAt(rec), rec.receivedAt + HOOK_PAGE_MAX_AGE_MS);
  await open(relay, iv("other", { sessionId: "s-other" }));
  clock.advance(HOOK_PAGE_MAX_AGE_MS - 1000);
  await relay.alarm();
  assert.ok((await pendingIds()).includes("hook-11111111-8-1"), "not before its time");
  clock.advance(2000);
  calls = [];
  await relay.alarm();
  assert.deepEqual(await pendingIds(), ["other"]);
  const [h] = (await call(relay, "GET", "/history")).body;
  assert.equal(h.closeReason, "expired");
  assert.ok(await state.storage.get("tomb:hook-11111111-8-1"));
  assert.equal(silent().length, 1);
});

// MARK: W2 — failures on closed pages are pushed too

test("a failed reply to a page that closed meanwhile is pushed, with an action-less category", async () => {
  const mac = connect(true);
  await open(relay, iv("idle-1", { kind: "idle" }));
  await close(relay, "idle-1", "user_resolved_in_terminal");
  const r = await call(relay, "POST", "/reply/idle-1", { text: "continue", action: "custom" });
  assert.equal(r.status, 200);
  calls = [];
  await macFrame(relay, mac, "reply.injected", { interventionId: "idle-1", method: "headless", success: false, detail: "Session has ended" });
  assert.equal(alerts().length, 1);
  assert.equal(alerts()[0].body.aps.category, "PAGE_INFO");
  assert.equal(alerts()[0].body.aps.alert.body, "Session has ended");
  assert.equal(buildReplyFailedPush(iv("p", { kind: "permission" }), "x", clock.now).payload.aps.category, "PAGE_APPROVAL");
});

test("a queued reply whose page closed before the Mac returned is reported by push", async () => {
  await open(relay, iv("q-1"));
  await call(relay, "POST", "/reply/q-1", { text: "do it", action: "custom" });   // Mac offline: queued
  await close(relay, "q-1", "user_resolved_in_terminal");
  calls = [];
  const mac = connect(true);
  await macFrame(relay, mac, "heartbeat", { ts: "t", activeSessions: 0, battery: 50 });
  assert.equal(mac.frames("reply").length, 0);
  assert.equal(alerts().filter(c => c.body.replyFailed).length, 1);
});

// MARK: W3 — sync keeps pages whose delivery is in flight

test("sync doesn't close a page whose queued reply was forwarded late and is still unacknowledged", async () => {
  await open(relay, iv("d-1"));
  await call(relay, "POST", "/reply/d-1", { text: "carry on please", action: "custom" });  // queued
  clock.advance(5 * 60_000);
  const mac = connect(true);
  await macFrame(relay, mac, "sync", { backend: "claude", openIds: [] });
  assert.deepEqual(await pendingIds(), ["d-1"], "repliedAt is 5 min old, but the reply is only now going out");
  assert.equal(mac.frames("reply").length, 1);
  await macFrame(relay, mac, "reply.injected", { interventionId: "d-1", method: "headless", success: true, detail: "Sent via background resume" });
  const [p] = (await call(relay, "GET", "/interventions")).body;
  assert.equal(p.deliveryStatus, "delivered");
  // Once the ack window has passed with nothing in flight, sync closes as usual.
  clock.advance(DELIVERY_ACK_TIMEOUT_MS + 1000);
  await macFrame(relay, mac, "sync", { backend: "claude", openIds: [] });
  assert.deepEqual(await pendingIds(), []);
});

test("selectStaleForSync: delivery grace keys on the forward time", () => {
  const now = clock.now;
  const rec = (o) => ({ iv: { ...iv("x"), backend: "claude", ...o }, receivedAt: now - 3_600_000 });
  const sync = { backend: "claude", openIds: new Set() };
  const old = new Date(now - 10 * 60_000).toISOString();
  const fresh = new Date(now - 60_000).toISOString();
  assert.deepEqual(selectStaleForSync([rec({ repliedAt: old, deliveryStatus: "pending", deliveryForwardedAt: fresh })], sync, now), []);
  assert.deepEqual(selectStaleForSync([rec({ repliedAt: old, deliveryStatus: "pending" })], sync, now), []);
  assert.deepEqual(selectStaleForSync([rec({ repliedAt: old, deliveryStatus: "delivered" })], sync, now), ["x"]);
  assert.deepEqual(selectStaleForSync([rec({ hookBlocking: true, id: "hook-a" })], sync, now), []);
});

// MARK: W5 — a flushed reply to a closed page is recorded

test("flushing a queued reply to a closed page records the forward on the archived copy", async () => {
  await open(relay, iv("c-1", { kind: "idle" }));
  await close(relay, "c-1", "user_resolved_in_terminal");
  await call(relay, "POST", "/reply/c-1", { text: "continue", action: "custom" });  // closed + queued
  clock.advance(1000);
  const mac = connect(true);
  await macFrame(relay, mac, "heartbeat", { ts: "t", activeSessions: 1, battery: 50 });
  assert.equal(mac.frames("reply").length, 1);
  const [h] = (await call(relay, "GET", "/history")).body;
  assert.equal(h.deliveryDetail, "Sent to your Mac");
  assert.match(h.deliveryForwardedAt, /Z$/);
});

// MARK: W6 — migration schedules the queue's alarm

test("migrating a legacy blob with queued replies schedules an alarm", async () => {
  const storage = new FakeStorage();
  await storage.put("state.v1", {
    pendingInterventions: {
      a: { id: "a", sessionId: "s", cwd: "/x", projectName: "x", kind: "question", context: "", openedAt: "2026-10-24T11:00:00.000Z", repliedAt: "2026-10-24T11:30:00.000Z" }
    },
    replyQueue: [{ interventionId: "a", text: "yes", action: null }]
  });
  const r = new UserRelay(new FakeState(storage), env());
  await call(r, "GET", "/status");
  assert.notEqual(storage.alarm, null);
  clock.now = storage.alarm;
  await r.alarm();
  const [p] = (await call(r, "GET", "/interventions")).body;
  assert.equal(p.deliveryStatus, "failed", "the old queued reply fails instead of answering 409 forever");
});

// MARK: IOS-2 / IOS-3 — presence and badges

test("/status macEverSeen: false for a pairing no Mac used, true (and persisted) after Mac traffic", async () => {
  assert.equal((await call(relay, "GET", "/status")).body.macEverSeen, false);
  await call(relay, "POST", "/reply/nope", { text: "x" });
  assert.equal((await call(relay, "GET", "/status")).body.macEverSeen, false, "phone traffic doesn't count");
  await postAs("page-hook/3.0", "intervention.opened", iv("hook-a-1-1", { backend: "claude", kind: "question" }));
  assert.equal((await call(relay, "GET", "/status")).body.macEverSeen, true);
  assert.equal((await state.storage.get("meta")).macEverSeen, true);

  // A Mac socket frame counts too, and the flag survives a fresh instance.
  const s2 = new FakeState();
  const r2 = new UserRelay(s2, env());
  const ws = new FakeWS();
  r2.attachSocket(ws, true);
  await r2.webSocketMessage(ws, JSON.stringify({ type: "sync", payload: { backend: "claude", openIds: [] } }));
  ws.close(1000, "x");
  const r3 = new UserRelay(new FakeState(s2.storage), env());
  assert.equal((await call(r3, "GET", "/status")).body.macEverSeen, true);
});

test("alert pushes carry the pending count as the badge", async () => {
  await open(relay, iv("b-1", { sessionId: "s1" }));
  await open(relay, iv("b-2", { sessionId: "s2" }));
  assert.deepEqual(alerts().map(c => c.body.aps.badge), [1, 2]);
  calls = [];
  await close(relay, "b-1", "user_resolved_in_terminal");
  // The close is a background push: content-available only, no badge.
  assert.equal(silent()[0].body.aps.badge, undefined);
});
