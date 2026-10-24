import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { UserRelay } from "../src/durable.ts";
import worker from "../src/index.ts";
import {
  FakeState, FakeStorage, FakeWS, clock, env, call, iv, open, close, macFrame
} from "./helpers.mjs";

clock.install();

let state, relay;
beforeEach(() => {
  clock.now = Date.parse("2026-10-24T12:00:00.000Z");
  state = new FakeState();
  relay = new UserRelay(state, env());
});

function connect({ mac }) {
  const ws = new FakeWS();
  relay.attachSocket(ws, mac);
  return ws;
}

const pendingIds = async () => (await call(relay, "GET", "/interventions")).body.map(i => i.id);

// MARK: open / supersede / close / tombstones

test("open stores a validated record and broadcasts to phones only", async () => {
  const phone = connect({ mac: false });
  const mac = connect({ mac: true });
  const r = await open(relay, iv("a", { kind: "bogus", context: "x".repeat(5000), extra: "dropped", repliedAt: "forged" }));
  assert.equal(r.status, 200);
  const [stored] = (await call(relay, "GET", "/interventions")).body;
  assert.equal(stored.kind, "question");
  assert.equal(stored.context.length, 4000);
  assert.ok(stored.context.endsWith("…"));
  assert.equal(stored.backend, "claude");
  assert.equal(stored.source, "terminal");
  assert.equal(stored.extra, undefined);
  assert.equal(stored.repliedAt, undefined);
  assert.equal(phone.frames("intervention.opened").length, 1);
  assert.equal(mac.frames("intervention.opened").length, 0);
});

test("open rejects missing or oversized ids with 400 and JSON body", async () => {
  let r = await open(relay, iv("", {}));
  assert.equal(r.status, 400);
  assert.equal(r.body.error, "invalid_id");
  assert.equal(r.headers.get("content-type"), "application/json");
  r = await open(relay, iv("x".repeat(201)));
  assert.equal(r.status, 400);
  r = await open(relay, iv("ok", { sessionId: 42 }));
  assert.equal(r.body.error, "invalid_sessionId");
  r = await call(relay, "POST", "/intervention", "{not json");
  assert.equal(r.status, 400);
  r = await call(relay, "POST", "/intervention", { type: "nope", payload: {} });
  assert.equal(r.body.error, "unknown_type");
});

test("every timestamp the Worker emits has whole seconds (old phones decode with .iso8601)", async () => {
  const mac = connect({ mac: true });
  await open(relay, iv("a", { openedAt: "2026-10-24T13:00:00+01:00" }));
  await open(relay, iv("b", { sessionId: "s2", openedAt: "garbage" }));
  clock.advance(1234);
  await call(relay, "POST", "/reply/a", { text: "hi" });
  await macFrame(relay, mac, "heartbeat", { ts: "t", activeSessions: 1, battery: 10 });
  const list = (await call(relay, "GET", "/interventions")).body;
  const a = list.find(i => i.id === "a");
  assert.equal(a.openedAt, "2026-10-24T12:00:00Z");
  assert.match(a.repliedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.match(list.find(i => i.id === "b").openedAt, /:\d\dZ$/);
  await close(relay, "a", "replied");
  const [h] = (await call(relay, "GET", "/history")).body;
  assert.match(h.closedAt, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.match((await call(relay, "GET", "/status")).body.lastHeartbeatAt, /:\d\dZ$/);
});

test("duplicate open is idempotent", async () => {
  await open(relay, iv("a"));
  const r = await open(relay, iv("a", { context: "changed" }));
  assert.equal(r.body.duplicate, true);
  assert.deepEqual(await pendingIds(), ["a"]);
});

test("supersede archives the old page (hidden from default history) and replies to it get 410", async () => {
  const phone = connect({ mac: false });
  await open(relay, iv("old", { kind: "idle" }));
  clock.advance(1000);
  await open(relay, iv("new"));
  assert.deepEqual(await pendingIds(), ["new"]);
  assert.deepEqual(phone.frames("intervention.closed").map(f => f.payload), [{ id: "old", reason: "superseded" }]);

  assert.equal((await call(relay, "GET", "/history")).body.length, 0);
  const all = (await call(relay, "GET", "/history?all=1")).body;
  assert.equal(all[0].id, "old");
  assert.equal(all[0].closeReason, "superseded");

  const r = await call(relay, "POST", "/reply/old", { text: "hello", action: "custom" });
  assert.equal(r.status, 410);
  assert.equal(r.body.error, "gone");
  assert.equal(r.body.closeReason, "superseded");
  assert.equal(r.body.currentId, "new");
});

test("hookpre pages are never superseded or cascaded", async () => {
  await open(relay, iv("hookpre-aaaa-1-1"));
  await open(relay, iv("mac-page"));
  assert.deepEqual((await pendingIds()).sort(), ["hookpre-aaaa-1-1", "mac-page"]);
  await close(relay, "mac-page", "user_resolved_in_terminal");
  assert.deepEqual(await pendingIds(), ["hookpre-aaaa-1-1"]);
});

test("close archives, cascades same-session pages and tombstones the ids", async () => {
  await open(relay, iv("hookpre-x-1-1"));
  await open(relay, iv("a", { sessionId: "s2" }));
  await open(relay, iv("b", { sessionId: "s3" }));
  const r = await close(relay, "a", "user_resolved_in_terminal");
  assert.equal(r.status, 200);
  const hist = (await call(relay, "GET", "/history")).body;
  assert.deepEqual(hist.map(h => [h.id, h.closeReason]), [["a", "user_resolved_in_terminal"]]);

  // A late/replayed open for the closed id must not resurrect it.
  const late = await open(relay, iv("a", { sessionId: "s2" }));
  assert.equal(late.body.ignored, "closed");
  assert.ok(!(await pendingIds()).includes("a"));
});

test("cascade archives siblings as session_resolved", async () => {
  // Two pages for one session can coexist only via hookpre exemption, so
  // force it: write a sibling directly, then close the other one.
  await open(relay, iv("a"));
  await state.storage.put("p:b", { iv: { ...iv("b"), backend: "claude", source: "terminal" }, receivedAt: clock.now });
  await close(relay, "a", "replied");
  assert.deepEqual(await pendingIds(), []);
  const all = (await call(relay, "GET", "/history?all=1")).body;
  assert.deepEqual(all.map(h => h.closeReason).sort(), ["replied", "session_resolved"]);
});

test("a close that overtakes its open tombstones the id", async () => {
  await close(relay, "early", "user_resolved_in_terminal");
  const r = await open(relay, iv("early"));
  assert.equal(r.body.ignored, "closed");
  assert.deepEqual(await pendingIds(), []);
  // ...but only for a day.
  clock.advance(25 * 3600 * 1000);
  await open(relay, iv("early"));
  assert.deepEqual(await pendingIds(), ["early"]);
});

test("history is capped and pruned oldest-first", async () => {
  for (let i = 0; i < 305; i++) {
    await open(relay, iv(`p${i}`, { sessionId: `s${i}` }));
    clock.advance(10);
    await close(relay, `p${i}`, "user_resolved_in_terminal");
  }
  const hist = (await call(relay, "GET", "/history?limit=1000")).body;
  assert.equal(hist.length, 300);
  assert.equal(hist[0].id, "p304");
  assert.equal(hist[299].id, "p5");
  assert.equal(state.storage.keysWithPrefix("h:").length, 300);
  assert.equal(state.storage.keysWithPrefix("hx:").length, 300);
  assert.equal((await state.storage.get("meta")).historyCount, 300);
});

test("/history parses limit safely", async () => {
  for (const q of ["?limit=abc", "?limit=-5", "?limit=", ""]) {
    const r = await call(relay, "GET", `/history${q}`);
    assert.equal(r.status, 200);
    assert.ok(Array.isArray(r.body));
  }
});

// MARK: replies

test("empty replies and unknown actions are refused with 400", async () => {
  await open(relay, iv("a"));
  for (const body of [{ text: "", action: null }, { text: "   " }, { text: "", action: "custom" }, {}, null]) {
    const r = await call(relay, "POST", "/reply/a", body);
    assert.equal(r.status, 400, JSON.stringify(body));
  }
  const bad = await call(relay, "POST", "/reply/a", { text: "x", action: "nuke" });
  assert.equal(bad.body.error, "invalid_action");
  const pending = (await call(relay, "GET", "/interventions")).body[0];
  assert.equal(pending.repliedAt, undefined);
});

test("unknown intervention → 404", async () => {
  const r = await call(relay, "POST", "/reply/nope", { text: "hi" });
  assert.equal(r.status, 404);
  assert.equal(r.body.error, "no_such_intervention");
});

test("a forwarded reply the Mac never acknowledges frees the page for retry after 20 min", async () => {
  const mac = connect({ mac: true });
  await open(relay, iv("a"));
  assert.equal((await call(relay, "POST", "/reply/a", { text: "", action: "approve" })).status, 200);
  const stored = (await call(relay, "GET", "/interventions")).body[0];
  assert.ok(stored.deliveryForwardedAt, "forwarded replies are stamped");

  clock.now += 19 * 60 * 1000;
  assert.equal((await call(relay, "POST", "/reply/a", { text: "", action: "deny" })).status, 409);

  clock.now += 2 * 60 * 1000;   // 21 min, no reply.injected ever arrived
  const retry = await call(relay, "POST", "/reply/a", { text: "", action: "deny" });
  assert.equal(retry.status, 200);
  assert.equal(mac.frames("reply").length, 2);
});

test("a queued reply (Mac offline) is not freed by the ack timeout", async () => {
  await open(relay, iv("a"));
  const r = await call(relay, "POST", "/reply/a", { text: "", action: "approve" });
  assert.deepEqual(r.body, { ok: true, queued: true });
  clock.now += 30 * 60 * 1000;
  assert.equal((await call(relay, "POST", "/reply/a", { text: "", action: "deny" })).status, 409);
});

test("reply to a live page forwards a v2 frame; second reply → 409", async () => {
  const mac = connect({ mac: true });
  await open(relay, iv("a", { backend: "claude", source: "terminal" }));
  const r = await call(relay, "POST", "/reply/a", { text: "", action: "approve" });
  assert.deepEqual(r.body, { ok: true, queued: false });
  const [frame] = mac.frames("reply");
  assert.deepEqual(frame.payload, {
    interventionId: "a", text: "", action: "approve", sessionId: "sess-1",
    cwd: "/Users/me/projects/acme", kind: "permission", backend: "claude", source: "terminal"
  });
  const stored = (await call(relay, "GET", "/interventions")).body[0];
  assert.equal(stored.deliveryStatus, "pending");
  assert.equal(stored.repliedAction, "approve");

  const again = await call(relay, "POST", "/reply/a", { text: "ok" });
  assert.equal(again.status, 409);
  assert.equal(again.body.error, "already_replied");
  assert.equal(mac.frames("reply").length, 1);
});

test("reply.injected failure frees the page for retry and broadcasts reply.result", async () => {
  const mac = connect({ mac: true });
  const phone = connect({ mac: false });
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "", action: "approve" });
  await macFrame(relay, mac, "reply.injected", {
    interventionId: "a", method: "tmux", success: false, output: "SECRET OUTPUT", detail: "The prompt is no longer showing"
  });
  const stored = (await call(relay, "GET", "/interventions")).body[0];
  assert.equal(stored.deliveryStatus, "failed");
  assert.equal(stored.deliveryDetail, "The prompt is no longer showing");
  assert.equal(stored.repliedAt, undefined);
  assert.ok(!JSON.stringify(stored).includes("SECRET"));
  assert.deepEqual(phone.frames("reply.result")[0].payload, {
    interventionId: "a", success: false, method: "tmux", detail: "The prompt is no longer showing"
  });
  const retry = await call(relay, "POST", "/reply/a", { text: "", action: "deny" });
  assert.equal(retry.status, 200);
});

test("reply.injected success marks delivered", async () => {
  const mac = connect({ mac: true });
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "go on" });
  await macFrame(relay, mac, "reply.injected", { interventionId: "a", method: "tmux", success: true });
  const stored = (await call(relay, "GET", "/interventions")).body[0];
  assert.equal(stored.deliveryStatus, "delivered");
  assert.equal(stored.deliveryMethod, "tmux");
  assert.ok(stored.repliedAt);
});

test("closed pages: decisions → 410, free text within 10 min forwards with closed flag, later → 410", async () => {
  const mac = connect({ mac: true });
  await open(relay, iv("a", { kind: "idle" }));
  await close(relay, "a", "user_resolved_in_terminal");

  const approve = await call(relay, "POST", "/reply/a", { text: "", action: "approve" });
  assert.equal(approve.status, 410);
  assert.equal(approve.body.closeReason, "user_resolved_in_terminal");

  clock.advance(60 * 1000);
  const text = await call(relay, "POST", "/reply/a", { text: "also run lint" });
  assert.equal(text.status, 200);
  const frame = mac.frames("reply")[0];
  assert.equal(frame.payload.closed, true);
  assert.equal(frame.payload.closeReason, "user_resolved_in_terminal");
  // Already replied now → 409 even though it's closed.
  assert.equal((await call(relay, "POST", "/reply/a", { text: "again" })).status, 409);

  await open(relay, iv("b", { sessionId: "s9", kind: "idle" }));
  await close(relay, "b", "timeout");
  clock.advance(11 * 60 * 1000);
  const late = await call(relay, "POST", "/reply/b", { text: "hello?" });
  assert.equal(late.status, 410);
  assert.equal(late.body.why, "expired");
});

test("free text to a closed page is refused when the session has a newer page", async () => {
  await open(relay, iv("a", { kind: "idle" }));
  await close(relay, "a", "user_resolved_in_terminal");
  await open(relay, iv("b"));
  const r = await call(relay, "POST", "/reply/a", { text: "hi" });
  assert.equal(r.status, 410);
  assert.equal(r.body.currentId, "b");
});

test("hookpre replies are stored for the hook, never forwarded or queued", async () => {
  const mac = connect({ mac: true });
  const phone = connect({ mac: false });
  await open(relay, iv("hookpre-abc-1-2"));
  const r = await call(relay, "POST", "/reply/hookpre-abc-1-2", { text: "", action: "deny" });
  assert.deepEqual(r.body, { ok: true, queued: false });
  assert.equal(mac.frames("reply").length, 0);
  assert.equal(state.storage.keysWithPrefix("q:").length, 0);
  const stored = (await call(relay, "GET", "/interventions")).body[0];
  assert.equal(stored.repliedAction, "deny");
  // The hook closes with "replied" once it has applied the decision.
  await close(relay, "hookpre-abc-1-2", "replied");
  assert.equal(phone.frames("reply.result")[0].payload.success, true);
  const hist = (await call(relay, "GET", "/history")).body[0];
  assert.equal(hist.deliveryStatus, "delivered");

  // A hook that gives up before reading the reply reports it as failed.
  phone.clear();
  await open(relay, iv("hookpre-def-1-3", { sessionId: "s7" }));
  await call(relay, "POST", "/reply/hookpre-def-1-3", { text: "", action: "approve" });
  await close(relay, "hookpre-def-1-3", "timeout");
  assert.equal(phone.frames("reply.result")[0].payload.success, false);
  // ...and the closed hook page refuses further replies.
  const late = await call(relay, "POST", "/reply/hookpre-def-1-3", { text: "", action: "approve" });
  assert.equal(late.status, 410);
  assert.equal(late.body.why, "hook_finished");
});

// MARK: queue

test("offline replies queue with routing info and flush on the Mac's first frame", async () => {
  await open(relay, iv("codex-7", { backend: "codex", sessionId: "thread-1", cwd: "/w" }));
  const r = await call(relay, "POST", "/reply/codex-7", { text: "yes do it" });
  assert.deepEqual(r.body, { ok: true, queued: true });
  const [qkey] = state.storage.keysWithPrefix("q:");
  const entry = await state.storage.get(qkey);
  assert.equal(entry.sessionId, "thread-1");
  assert.equal(entry.cwd, "/w");
  assert.equal(entry.backend, "codex");
  assert.equal(entry.kind, "permission");
  assert.ok(state.storage.alarm !== null, "expiry alarm scheduled");

  const mac = connect({ mac: true });
  assert.equal(mac.frames("reply").length, 0, "not flushed on bare connect");
  await macFrame(relay, mac, "heartbeat", { ts: "t", activeSessions: 1, battery: -1 });
  const [frame] = mac.frames("reply");
  assert.equal(frame.payload.interventionId, "codex-7");
  assert.equal(frame.payload.backend, "codex");
  assert.equal(frame.payload.sessionId, "thread-1");
  assert.equal(state.storage.keysWithPrefix("q:").length, 0);
});

test("flush keeps entries whose send failed", async () => {
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "hi" });
  const mac = connect({ mac: true });
  mac.failSend = true;
  await macFrame(relay, mac, "heartbeat", { ts: "t", activeSessions: 0, battery: 50 });
  assert.equal(state.storage.keysWithPrefix("q:").length, 1);
  mac.failSend = false;
  await macFrame(relay, mac, "heartbeat", { ts: "t", activeSessions: 0, battery: 50 });
  assert.equal(state.storage.keysWithPrefix("q:").length, 0);
  assert.equal(mac.frames("reply").length, 1);
});

test("queued replies older than an hour are dropped and marked failed", async () => {
  const phone = connect({ mac: false });
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "hi" });
  clock.advance(61 * 60 * 1000);
  const mac = connect({ mac: true });
  await macFrame(relay, mac, "heartbeat", { ts: "t", activeSessions: 0, battery: 50 });
  assert.equal(mac.frames("reply").length, 0);
  assert.equal(state.storage.keysWithPrefix("q:").length, 0);
  const stored = (await call(relay, "GET", "/interventions")).body[0];
  assert.equal(stored.deliveryStatus, "failed");
  assert.equal(stored.repliedAt, undefined);
  assert.equal(phone.frames("reply.result")[0].payload.success, false);
});

test("the alarm expires queued replies even if the Mac never returns", async () => {
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "hi" });
  clock.now = state.storage.alarm;
  await relay.alarm();
  assert.equal(state.storage.keysWithPrefix("q:").length, 0);
  const stored = (await call(relay, "GET", "/interventions")).body[0];
  assert.equal(stored.deliveryStatus, "failed");
});

test("queued replies for pages that closed meanwhile are not delivered", async () => {
  await open(relay, iv("a"));
  await call(relay, "POST", "/reply/a", { text: "hi" });
  await close(relay, "a", "timeout");
  const mac = connect({ mac: true });
  await macFrame(relay, mac, "heartbeat", { ts: "t", activeSessions: 0, battery: 50 });
  assert.equal(mac.frames("reply").length, 0);
  assert.equal(state.storage.keysWithPrefix("q:").length, 0);
});

// MARK: sync

test("sync closes stale pages for its backend only, skipping hook and recently replied pages", async () => {
  const phone = connect({ mac: false });
  const mac = connect({ mac: true });
  await open(relay, iv("keep", { sessionId: "s1" }));
  await open(relay, iv("stale", { sessionId: "s2" }));
  await open(relay, iv("hook-ab-1-1", { sessionId: "s3" }));
  await open(relay, iv("hookpre-ab-1-1", { sessionId: "s4" }));
  await open(relay, iv("codex-1", { sessionId: "t1", backend: "codex" }));
  await open(relay, iv("replied", { sessionId: "s5" }));
  clock.advance(60 * 1000);
  await call(relay, "POST", "/reply/replied", { text: "on it" });
  await open(relay, iv("fresh", { sessionId: "s6" }));

  await macFrame(relay, mac, "sync", { backend: "claude", openIds: ["keep"] });
  assert.deepEqual((await pendingIds()).sort(),
    ["codex-1", "fresh", "hook-ab-1-1", "hookpre-ab-1-1", "keep", "replied"]);
  assert.deepEqual(phone.frames("intervention.closed").map(f => f.payload), [{ id: "stale", reason: "stale" }]);
  // stale closes aren't history-worthy and don't tombstone
  assert.equal((await call(relay, "GET", "/history?all=1")).body.length, 0);
  await open(relay, iv("stale", { sessionId: "s2" }));
  assert.ok((await pendingIds()).includes("stale"));

  clock.advance(3 * 60 * 1000);
  await macFrame(relay, mac, "sync", { backend: "codex", openIds: [] });
  assert.ok(!(await pendingIds()).includes("codex-1"));
  assert.ok((await pendingIds()).includes("replied"));
});

test("invalid sync payloads are ignored", async () => {
  await open(relay, iv("a"));
  clock.advance(60 * 1000);
  const r = await call(relay, "POST", "/intervention", { type: "sync", payload: { backend: "other", openIds: [] } });
  assert.equal(r.status, 400);
  assert.deepEqual(await pendingIds(), ["a"]);
});

// MARK: presence

test("heartbeats pass through, persist at most every few minutes, and feed /status", async () => {
  const phone = connect({ mac: false });
  const mac = connect({ mac: true });
  assert.deepEqual(phone.frames("mac.status")[0].payload.macConnected, true);

  await macFrame(relay, mac, "heartbeat", { ts: "2026", activeSessions: 3, battery: 81, onAC: true });
  const writesAfterFirst = state.storage.writes;
  for (let i = 0; i < 10; i++) {
    clock.advance(15 * 1000);
    await macFrame(relay, mac, "heartbeat", { ts: "2026", activeSessions: 3, battery: 81, onAC: true });
  }
  assert.equal(state.storage.writes, writesAfterFirst, "no storage write per heartbeat");
  assert.deepEqual(phone.frames("heartbeat").at(-1).payload, { ts: "2026", activeSessions: 3, battery: 81, onAC: true });

  const s = (await call(relay, "GET", "/status")).body;
  assert.equal(s.macConnected, true);
  assert.equal(s.activeSessions, 3);
  assert.equal(s.battery, 81);
  assert.equal(s.onAC, true);
  assert.equal(s.pendingCount, 0);
  assert.ok(s.lastHeartbeatAt);

  clock.advance(5 * 60 * 1000);
  await macFrame(relay, mac, "heartbeat", { ts: "2026", activeSessions: 2, battery: -1 });
  assert.equal((await state.storage.get("meta")).activeSessions, 2);
  assert.equal((await call(relay, "GET", "/status")).body.battery, undefined, "unknown battery omitted");
});

test("webSocketClose reciprocates and announces the Mac going offline", async () => {
  const phone = connect({ mac: false });
  const mac = connect({ mac: true });
  phone.clear();
  await relay.webSocketClose(mac, 1005, "", false);
  assert.deepEqual(mac.closedWith, { code: 1000, reason: "closing" });
  assert.equal(phone.frames("mac.status")[0].payload.macConnected, false);
  assert.equal((await call(relay, "GET", "/status")).body.macConnected, false);

  const mac2 = connect({ mac: true });
  await relay.webSocketClose(mac2, 4001, "bye", true);
  assert.deepEqual(mac2.closedWith, { code: 4001, reason: "bye" });
});

test("a phone socket closing doesn't announce anything", async () => {
  const phone = connect({ mac: false });
  const other = connect({ mac: false });
  connect({ mac: true });
  other.clear();
  await relay.webSocketClose(phone, 1000, "", true);
  assert.equal(other.frames("mac.status").length, 0);
});

// MARK: devices

test("device register validates tokens, keeps several devices, unregister removes", async () => {
  const t1 = "a".repeat(64), t2 = "B".repeat(64);
  assert.equal((await call(relay, "POST", "/device/register", { apnsToken: "not-hex" })).status, 400);
  assert.equal((await call(relay, "POST", "/device/register", {})).body.error, "missing_apnsToken");
  let r = await call(relay, "POST", "/device/register", { apnsToken: t1, appVersion: "1.0" });
  assert.equal(r.body.apnsEnv, "development");
  r = await call(relay, "POST", "/device/register", { apnsToken: t2, appVersion: "1.1", apnsEnv: "production" });
  assert.equal(r.body.apnsEnv, "production");
  assert.deepEqual(state.storage.keysWithPrefix("dev:"), [`dev:${t1}`, `dev:${"b".repeat(64)}`]);
  assert.equal((await state.storage.get(`dev:${"b".repeat(64)}`)).apnsEnv, "production");
  r = await call(relay, "POST", "/device/unregister", { apnsToken: t1 });
  assert.equal(r.body.removed, true);
  assert.deepEqual(state.storage.keysWithPrefix("dev:"), [`dev:${"b".repeat(64)}`]);
});

// MARK: migration

test("migrates the legacy state.v1 blob to per-record keys and deletes it", async () => {
  const storage = new FakeStorage();
  const t = Date.parse("2026-10-24T11:00:00.000Z");
  await storage.put("state.v1", {
    apnsDeviceToken: "c".repeat(64),
    apnsAppVersion: "0.9",
    apnsRegisteredAt: "2026-10-01T00:00:00.000Z",
    pendingInterventions: {
      p1: { id: "p1", sessionId: "s1", cwd: "/a", projectName: "a", kind: "idle", context: "", openedAt: new Date(t).toISOString(), repliedAt: new Date(t + 1000).toISOString(), repliedText: "hi" },
      p2: { id: "p2", sessionId: "s2", cwd: "/b", projectName: "b", kind: "question", context: "?", openedAt: new Date(t).toISOString() },
      p3: { id: "p3", sessionId: "s5", cwd: "/e", projectName: "e", kind: "idle", context: "", openedAt: new Date(t).toISOString(), repliedAt: new Date(t).toISOString(), repliedText: "x" }
    },
    history: [
      { id: "h2", sessionId: "s3", cwd: "/c", projectName: "c", kind: "idle", context: "", openedAt: new Date(t - 5000).toISOString(), closedAt: new Date(t - 1000).toISOString(), closeReason: "replied" },
      { id: "h1", sessionId: "s4", cwd: "/d", projectName: "d", kind: "idle", context: "", openedAt: new Date(t - 9000).toISOString(), closedAt: new Date(t - 8000).toISOString(), closeReason: "timeout" }
    ],
    replyQueue: [{ interventionId: "p1", text: "hi", action: null }, { interventionId: "gone", text: "x", action: null }],
    // p3 was forwarded by the old Worker but never confirmed.
    lastHeartbeatAt: "2026-10-24T11:59:00.000Z",
    lastActiveSessions: 4
  });
  const s = new FakeState(storage);
  relay = new UserRelay(s, env());
  state = s;

  assert.deepEqual((await pendingIds()).sort(), ["p1", "p2", "p3"]);
  assert.equal(await storage.get("state.v1"), undefined);
  const p1 = (await call(relay, "GET", "/interventions")).body.find(i => i.id === "p1");
  assert.equal(p1.deliveryStatus, "pending", "queued legacy reply stays pending");
  assert.equal((await call(relay, "POST", "/reply/p3", { text: "retry" })).status, 200, "unconfirmed legacy reply can be retried");
  assert.equal((await call(relay, "POST", "/reply/p1", { text: "dup" })).status, 409);
  const migratedHistory = (await call(relay, "GET", "/history")).body;
  assert.deepEqual(migratedHistory.map(h => h.id), ["h2", "h1"]);
  assert.equal(migratedHistory[0].closedAt, "2026-10-24T10:59:59Z", "legacy ms timestamps rewritten");
  assert.deepEqual(storage.keysWithPrefix("dev:"), [`dev:${"c".repeat(64)}`]);
  // The legacy p1 entry plus the p3 retry above; "gone" had no live page.
  const queue = storage.keysWithPrefix("q:");
  assert.equal(queue.length, 2);
  const entry = await storage.get(queue.find(k => k.endsWith(":p1")));
  assert.equal(entry.sessionId, "s1");
  assert.equal(entry.queuedAt, t + 1000, "legacy queue age taken from the reply time");
  const meta = await storage.get("meta");
  assert.equal(meta.schema, 2);
  assert.equal(meta.historyCount, 2);
  assert.equal((await call(relay, "GET", "/status")).body.activeSessions, 4);

  // A second instance (wake from hibernation) doesn't redo anything.
  const before = storage.writes;
  relay = new UserRelay(new FakeState(storage), env());
  await call(relay, "GET", "/interventions");
  assert.equal(storage.writes, before);
});

test("a fresh object writes nothing on read-only requests", async () => {
  await call(relay, "GET", "/interventions");
  await call(relay, "GET", "/status");
  assert.equal(state.storage.writes, 0);
});

// MARK: routing / auth

test("unknown routes and bad reply ids return JSON errors", async () => {
  let r = await call(relay, "GET", "/nope");
  assert.equal(r.status, 404);
  assert.equal(r.body.error, "not_found");
  r = await call(relay, "POST", "/reply/%E0%A4%A", { text: "x" });
  assert.equal(r.status, 400);
  assert.equal(r.body.error, "bad_id");
});

test("index.ts rejects missing and short tokens with 401", async () => {
  const routed = [];
  const workerEnv = env({
    USERS: { idFromName: t => t, get: id => ({ fetch: async () => { routed.push(id); return new Response("ok"); } }) }
  });
  const mk = auth => new Request("https://relay.test/interventions", { headers: auth ? { Authorization: auth } : {} });
  let res = await worker.fetch(mk(null), workerEnv, {});
  assert.equal(res.status, 401);
  assert.equal((await res.json()).error, "missing_token");
  res = await worker.fetch(mk("Bearer short"), workerEnv, {});
  assert.equal(res.status, 401);
  assert.equal((await res.json()).error, "invalid_token");
  res = await worker.fetch(mk("Bearer " + "x".repeat(43)), workerEnv, {});
  assert.equal(res.status, 200);
  assert.equal(routed.length, 1);
  res = await worker.fetch(new Request("https://relay.test/health"), workerEnv, {});
  const health = await res.json();
  assert.equal(health.ok, true);
  assert.equal(health.apnsConfigured, false);
});
