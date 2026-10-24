// Push dedupe between the blocking hook's pages (hookpre-) and other pages
// for the same session (Mac detector, Notification hook).
import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { UserRelay } from "../src/durable.ts";
import { decideOpenPush, buildAlertPush, HOOK_DEDUPE_WINDOW_MS } from "../src/logic.ts";
import { FakeState, FakeWS, clock, env, call, iv, open, close } from "./helpers.mjs";

clock.install();

const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
const PEM = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8)).match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;
const apnsEnv = () => env({ APNS_KEY_P8: PEM, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234" });
const TOKEN = "a".repeat(64);

let calls, realFetch;
beforeEach(() => {
  clock.now = Date.parse("2026-10-24T12:00:00.000Z");
  calls = [];
  realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    calls.push({ url: String(url), headers: init.headers, body: JSON.parse(init.body) });
    return new Response(null, { status: 200 });
  };
});
afterEach(() => { globalThis.fetch = realFetch; });

async function relay() {
  const state = new FakeState();
  const r = new UserRelay(state, apnsEnv());
  await call(r, "POST", "/device/register", { apnsToken: TOKEN, apnsEnv: "development" });
  return { state, relay: r };
}
const alerts = () => calls.filter(c => c.body.aps?.alert);
const silent = () => calls.filter(c => c.body.aps?.["content-available"] === 1);

test("decideOpenPush rules", () => {
  const now = clock.now;
  const rec = (id, o = {}) => ({ iv: { ...iv(id), backend: "claude", source: "terminal", ...(o.iv ?? {}) }, receivedAt: now - 1000, ...o.rec });
  const hook = iv("hookpre-abc-1-2");
  const detector = iv("sess-1-permission-1");
  // Non-hook page while a hook page holds the session: no alert.
  assert.equal(decideOpenPush(detector, [rec("hookpre-abc-1-2")], now), "none");
  // ...but other sessions' hook pages don't matter.
  assert.equal(decideOpenPush(detector, [rec("hookpre-x", { iv: { sessionId: "other" } })], now), "alert");
  // Hook page right after an audible same-session approval: quiet.
  assert.equal(decideOpenPush(hook, [rec("sess-1-permission-1", { rec: { alertedAt: now - 5000 } })], now), "quiet");
  // Too old, never alerted, other session, or an idle page: loud.
  assert.equal(decideOpenPush(hook, [rec("d", { rec: { alertedAt: now - HOOK_DEDUPE_WINDOW_MS - 1 } })], now), "alert");
  assert.equal(decideOpenPush(hook, [rec("d")], now), "alert");
  assert.equal(decideOpenPush(hook, [rec("d", { iv: { sessionId: "other" }, rec: { alertedAt: now } })], now), "alert");
  assert.equal(decideOpenPush(hook, [rec("d", { iv: { kind: "idle" }, rec: { alertedAt: now } })], now), "alert");
  // A hook idle page (Codex Stop) is its own event: loud.
  assert.equal(decideOpenPush(iv("hookpre-s", { kind: "idle" }), [rec("d", { rec: { alertedAt: now } })], now), "alert");
  // Two hook pages (parallel prompts) each buzz.
  assert.equal(decideOpenPush(hook, [rec("hookpre-other", { rec: { alertedAt: now } })], now), "alert");
  assert.equal(decideOpenPush(detector, [], now), "alert");
});

test("quiet alert payload has no sound and a passive level", () => {
  const p = buildAlertPush(iv("hookpre-a"), clock.now, ["old"], { quiet: true }).payload;
  assert.equal(p.aps.sound, undefined);
  assert.equal(p.aps["interruption-level"], "passive");
  assert.deepEqual(p.interventionClosedIds, ["old"]);
  const loud = buildAlertPush(iv("x"), clock.now).payload;
  assert.equal(loud.aps.sound, "default");
});

test("detector page while the hook holds the session: stored and broadcast, no alert", async () => {
  const { state, relay: r } = await relay();
  const phone = new FakeWS();
  r.attachSocket(phone, false);
  await open(r, iv("hookpre-sess1-100-1"));
  assert.equal(alerts().length, 1);
  calls = [];
  const res = await open(r, iv("sess-1-permission-100"));
  assert.equal(res.status, 200);
  assert.equal(alerts().length, 0);
  assert.ok(await state.storage.get("p:sess-1-permission-100"), "still stored");
  assert.ok(await state.storage.get("p:hookpre-sess1-100-1"), "hook page untouched");
  assert.ok(phone.frames("intervention.opened").some(f => f.payload.id === "sess-1-permission-100"));
  // Once the hook is done, the session pages normally again.
  await close(r, "hookpre-sess1-100-1", "timeout");
  calls = [];
  await open(r, iv("sess-1-permission-200"));
  assert.equal(alerts().length, 1);
});

test("suppressed open still clears the banners of the pages it superseded", async () => {
  const { relay: r } = await relay();
  await open(r, iv("hook-sess1-1-1"));                     // Notification-hook page (pushed)
  await open(r, iv("hookpre-sess1-2-2"));                  // blocking hook (quiet: same prompt)
  calls = [];
  await open(r, iv("sess-1-permission-3"));                // detector: supersedes nothing pending non-hookpre…
  assert.equal(alerts().length, 0);
  // hook-sess1-1-1 was already superseded by the hookpre open; nothing else to clear.
  assert.equal(silent().length, 0);
  calls = [];
  await open(r, iv("sess-1-question-4", { kind: "question" })); // supersedes sess-1-permission-3
  assert.equal(alerts().length, 0);
  assert.equal(silent().length, 1);
  assert.deepEqual(silent()[0].body.interventionClosedIds, ["sess-1-permission-3"]);
});

test("hook page right after the detector's alert goes out quietly and replaces it", async () => {
  const { state, relay: r } = await relay();
  await open(r, iv("sess-1-permission-100"));
  assert.equal(alerts().length, 1);
  assert.equal(alerts()[0].body.aps.sound, "default");
  clock.advance(5000);
  calls = [];
  await open(r, iv("hookpre-sess1-105-9"));
  assert.equal(alerts().length, 1);
  const a = alerts()[0].body;
  assert.equal(a.aps.sound, undefined);
  assert.equal(a.aps["interruption-level"], "passive");
  assert.deepEqual(a.interventionClosedIds, ["sess-1-permission-100"]);
  // No Notification Service Extension: a backgrounded phone only learns the
  // superseded id from a background close push.
  assert.equal(silent().length, 1);
  assert.deepEqual(silent()[0].body.interventionClosedIds, ["sess-1-permission-100"]);
  assert.equal(await state.storage.get("p:sess-1-permission-100"), undefined, "superseded as before");
});

test("hook page long after the detector's alert buzzes again", async () => {
  const { relay: r } = await relay();
  await open(r, iv("sess-1-permission-100"));
  clock.advance(HOOK_DEDUPE_WINDOW_MS + 1000);
  calls = [];
  await open(r, iv("hookpre-sess1-200-9"));
  assert.equal(alerts()[0].body.aps.sound, "default");
});

test("codex hook replies say they wait for the Codex hook", async () => {
  const { relay: r } = await relay();
  await open(r, iv("hookpre-codex1-1-1", { backend: "codex", sessionId: "019a-thread" }));
  const res = await call(r, "POST", "/reply/hookpre-codex1-1-1", { text: "", action: "approve" });
  assert.deepEqual(res.body, { ok: true, queued: false });
  const list = (await call(r, "GET", "/interventions")).body;
  assert.equal(list[0].deliveryDetail, "Waiting for the Codex hook to pick it up");
  assert.equal(list[0].backend, "codex");
});
