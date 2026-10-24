import { test, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { normalizeP8, sendApnsPush, ApnsKeyError } from "../src/apns.ts";
import { UserRelay } from "../src/durable.ts";
import {
  buildAlertPush, categoryForKind, collapseIdFor, interruptionLevelForKind, bodyForPush
} from "../src/logic.ts";
import { FakeState, FakeWS, clock, env, call, iv, open, close, macFrame } from "./helpers.mjs";

clock.install();

// A real P-256 key so JWT signing runs end to end.
const keyPair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", keyPair.privateKey));
const b64 = btoa(String.fromCharCode(...pkcs8));
const PEM = `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g).join("\n")}\n-----END PRIVATE KEY-----\n`;

const apnsEnv = (overrides = {}) => env({
  APNS_KEY_P8: PEM, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "TEAMID1234", ...overrides
});

const TOKEN_A = "a".repeat(64);
const TOKEN_B = "b".repeat(64);

let calls, responder, realFetch;
beforeEach(() => {
  clock.now = Date.parse("2026-10-24T12:00:00.000Z");
  calls = [];
  responder = () => new Response(null, { status: 200 });
  realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    const call = { url: String(url), headers: init.headers, body: JSON.parse(init.body) };
    calls.push(call);
    return responder(call);
  };
});
afterEach(() => { globalThis.fetch = realFetch; });

const apnsError = (status, reason) => new Response(JSON.stringify({ reason }), { status });

// MARK: key handling

test("normalizeP8 tolerates escaped newlines, quotes and CRLF", () => {
  const variants = [
    PEM,
    PEM.replace(/\n/g, "\\n"),
    `"${PEM.replace(/\n/g, "\\n")}"`,
    PEM.replace(/\n/g, "\r\n"),
    `  '${PEM}'  `,
    b64
  ];
  for (const v of variants) assert.equal(normalizeP8(v), b64);
});

test("normalizeP8 explains SEC1, encrypted, empty and truncated keys", () => {
  assert.throws(() => normalizeP8("-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----"), /openssl pkcs8 -topk8/);
  assert.throws(() => normalizeP8("-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----"), /encrypted/);
  assert.throws(() => normalizeP8(""), ApnsKeyError);
  assert.throws(() => normalizeP8("-----BEGIN PRIVATE KEY-----"), /no key body/);
  assert.throws(() => normalizeP8("-----BEGIN PRIVATE KEY-----\nab$cd\n"), /not valid base64/);
});

// MARK: transport

test("alert push carries collapse id, expiration and a valid ES256 JWT", async () => {
  const built = buildAlertPush(iv("x".repeat(80)), clock.now);
  const r = await sendApnsPush(apnsEnv(), { token: TOKEN_A, env: "production", envKnown: true },
    { pushType: "alert", ...built });
  assert.equal(r.ok, true);
  const [c] = calls;
  assert.equal(c.url, `https://api.push.apple.com/3/device/${TOKEN_A}`);
  assert.equal(c.headers["apns-push-type"], "alert");
  assert.equal(c.headers["apns-priority"], "10");
  assert.equal(c.headers["apns-collapse-id"], "x".repeat(64));
  assert.equal(c.headers["apns-expiration"], String(Math.floor(clock.now / 1000) + 3600));
  assert.equal(c.headers["apns-topic"], "app.page.Page");

  const [h, p, sig] = c.headers.authorization.replace("bearer ", "").split(".");
  const dec = s => JSON.parse(Buffer.from(s, "base64url").toString());
  assert.deepEqual(dec(h), { alg: "ES256", kid: "KEYID12345", typ: "JWT" });
  assert.equal(dec(p).iss, "TEAMID1234");
  const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, keyPair.publicKey,
    Buffer.from(sig, "base64url"), new TextEncoder().encode(`${h}.${p}`));
  assert.ok(valid, "JWT signature verifies");
});

test("missing secrets and malformed keys fail softly", async () => {
  let r = await sendApnsPush(env(), { token: TOKEN_A, env: "development", envKnown: true }, { pushType: "alert", payload: {} });
  assert.equal(r.reason, "not_configured");
  r = await sendApnsPush(apnsEnv({ APNS_KEY_P8: "garbage!!", APNS_KEY_ID: "OTHERKEY01" }),
    { token: TOKEN_A, env: "development", envKnown: true }, { pushType: "alert", payload: {} });
  assert.equal(r.ok, false);
  assert.match(r.reason, /^key_error/);
  assert.equal(calls.length, 0);
});

test("403 InvalidProviderToken re-mints and retries once", async () => {
  let n = 0;
  responder = () => (n++ === 0 ? apnsError(403, "InvalidProviderToken") : new Response(null, { status: 200 }));
  const r = await sendApnsPush(apnsEnv({ APNS_KEY_ID: "ROTATED001" }), { token: TOKEN_A, env: "development", envKnown: true },
    { pushType: "alert", payload: {} });
  assert.equal(r.ok, true);
  assert.equal(calls.length, 2);
});

test("BadDeviceToken on an unknown env retries the other host", async () => {
  responder = c => (c.url.includes("development") ? apnsError(400, "BadDeviceToken") : new Response(null, { status: 200 }));
  const r = await sendApnsPush(apnsEnv(), { token: TOKEN_A, env: "development", envKnown: false }, { pushType: "alert", payload: {} });
  assert.equal(r.ok, true);
  assert.equal(r.env, "production");
  calls = [];
  const known = await sendApnsPush(apnsEnv(), { token: TOKEN_A, env: "development", envKnown: true }, { pushType: "alert", payload: {} });
  assert.equal(known.ok, false);
  assert.equal(known.dropDevice, true);
  assert.equal(calls.length, 1);
});

// MARK: payloads

test("payload category, interruption level and thread id follow the kind", () => {
  assert.equal(categoryForKind("permission"), "PAGE_APPROVAL");
  assert.equal(categoryForKind("plan"), "PAGE_APPROVAL");
  assert.equal(categoryForKind("user_input"), "PAGE_INPUT");
  assert.equal(categoryForKind("idle"), "PAGE_IDLE");
  assert.equal(categoryForKind("rate_limit"), "PAGE_INFO");
  assert.equal(interruptionLevelForKind("question"), "time-sensitive");
  assert.equal(interruptionLevelForKind("idle"), "active");
  const { payload } = buildAlertPush(iv("a", { kind: "question" }), clock.now, ["old"]);
  assert.equal(payload.aps.category, "PAGE_INPUT");
  assert.equal(payload.aps["thread-id"], "sess-1");
  assert.equal(payload.aps["interruption-level"], "time-sensitive");
  assert.equal(payload.interventionId, "a");
  assert.equal(payload.sessionId, "sess-1");
  assert.deepEqual(payload.interventionClosedIds, ["old"]);
  assert.equal(collapseIdFor("é".repeat(40)).length, 32, "truncated by UTF-8 bytes");
  assert.equal(bodyForPush({ ...iv("a"), context: "😀".repeat(200) }).includes("\ud83d…"), false, "no split surrogate");
});

// MARK: relay integration

async function relayWithDevices(devices) {
  const state = new FakeState();
  const relay = new UserRelay(state, apnsEnv());
  for (const d of devices) await call(relay, "POST", "/device/register", d);
  return { state, relay };
}

test("open pushes every device; 410 and BadDeviceToken remove devices; env is learned", async () => {
  const TOKEN_C = "c".repeat(64);
  const { state, relay } = await relayWithDevices([
    { apnsToken: TOKEN_A, apnsEnv: "production" },
    { apnsToken: TOKEN_B },
    { apnsToken: TOKEN_C, apnsEnv: "development" }
  ]);
  responder = c => {
    if (c.url.endsWith(TOKEN_A)) return apnsError(410, "Unregistered");
    if (c.url.endsWith(TOKEN_B)) return c.url.includes("development") ? apnsError(400, "BadDeviceToken") : new Response(null, { status: 200 });
    return apnsError(400, "DeviceTokenNotForTopic");
  };
  await open(relay, iv("a"));
  assert.deepEqual(state.storage.keysWithPrefix("dev:"), [`dev:${TOKEN_B}`]);
  assert.equal((await state.storage.get(`dev:${TOKEN_B}`)).learnedEnv, "production");
  // The old phone (no apnsEnv) got the legacy category; the others the per-kind one.
  const cats = Object.fromEntries(calls.filter(c => c.body.aps.alert).map(c => [c.url.slice(-64), c.body.aps.category]));
  assert.equal(cats[TOKEN_B], "PAGE");
  assert.equal(cats[TOKEN_A], "PAGE_APPROVAL");
  // Next push goes straight to the learned host.
  calls = [];
  responder = () => new Response(null, { status: 200 });
  await open(relay, iv("b", { sessionId: "s2" }));
  assert.equal(calls.length, 1);
  assert.ok(calls[0].url.startsWith("https://api.push.apple.com/"));
  const status = (await call(relay, "GET", "/status")).body;
  assert.equal(status.devices, 1);
  assert.ok(status.lastPushError);
  assert.equal(status.apnsConfigured, true);
});

test("close sends one silent push listing the cascaded ids", async () => {
  const { state, relay } = await relayWithDevices([{ apnsToken: TOKEN_A, apnsEnv: "development" }]);
  await open(relay, iv("a"));
  await state.storage.put("p:b", { iv: { ...iv("b"), backend: "claude", source: "terminal" }, receivedAt: clock.now });
  calls = [];
  await close(relay, "a", "user_resolved_in_terminal");
  assert.equal(calls.length, 1);
  const [c] = calls;
  assert.equal(c.headers["apns-push-type"], "background");
  assert.equal(c.headers["apns-priority"], "5");
  assert.equal(c.headers["apns-collapse-id"], undefined);
  // Background pushes carry only content-available (no badge — Apple's
  // rules); the app recounts its badge from a fresh inbox when woken.
  assert.deepEqual(c.body, { aps: { "content-available": 1 }, interventionClosedId: "a", interventionClosedIds: ["a", "b"] });
});

test("a failed injection alerts the phone only when the app isn't connected", async () => {
  const { relay } = await relayWithDevices([{ apnsToken: TOKEN_A, apnsEnv: "development" }]);
  const mac = new FakeWS();
  relay.attachSocket(mac, true);
  await open(relay, iv("a", { projectName: "acme" }));
  await call(relay, "POST", "/reply/a", { text: "", action: "approve" });
  calls = [];
  await macFrame(relay, mac, "reply.injected", { interventionId: "a", method: "tmux", success: false, detail: "Couldn't find the session's terminal" });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].body.aps.alert.title, "Reply to acme not delivered");
  assert.equal(calls[0].body.aps.alert.body, "Couldn't find the session's terminal");
  assert.equal(calls[0].headers["apns-collapse-id"], "a");

  const phone = new FakeWS();
  relay.attachSocket(phone, false);
  await call(relay, "POST", "/reply/a", { text: "", action: "approve" });
  calls = [];
  await macFrame(relay, mac, "reply.injected", { interventionId: "a", method: "tmux", success: false });
  assert.equal(calls.length, 0);
  assert.equal(phone.frames("reply.result").length, 1);
});
