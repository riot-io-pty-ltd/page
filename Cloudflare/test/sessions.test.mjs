// Live sessions (sessions-v1, docs/SESSIONS-PROTOCOL.md §3): the Worker
// forwards opaque envelopes between the Mac and the phones, never stores
// them, and tells the Mac how many phones are looking.
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { UserRelay } from "../src/durable.ts";
import {
  parseSessionsEnvelope, parseSessionsUpdate, takeToken,
  MAX_SESSIONS_UPDATE_BYTES, MAX_SESSIONS_COMMAND_BYTES, SESSIONS_COMMAND_RATE
} from "../src/logic.ts";
import { FakeState, FakeWS, clock, env, call, iv, open, macFrame } from "./helpers.mjs";

clock.install();

// The spec's test-vector envelope (mac->phone).
const E = {
  v: 1,
  n: "oKGio6Slpqeoqaqr",
  c: "izpLGj9N9Rpxuzq00howYI0D93aMC4vbU3Un38nzkzaX6rpd2wEiAvuseOahsZ9_zyivF1z2cuLwWX3k6Coa8QEvrfguLaN3"
};

let state, relay;
beforeEach(() => {
  clock.now = Date.parse("2026-10-24T12:00:00.000Z");
  state = new FakeState();
  relay = new UserRelay(state, env());
});

const connect = (mac, r = relay) => { const ws = new FakeWS(); r.attachSocket(ws, mac); return ws; };
const update = (ws, payload = { e: E }, r = relay) => macFrame(r, ws, "sessions.update", payload);
const command = (body, r = relay) => call(r, "POST", "/sessions/command", body);
const phonesSeen = (ws) => ws.frames("phones.status").map(f => f.payload.phones);
/// Everything in storage, the alarm included (FakeStorage.writes counts puts only).
const snapshot = () => JSON.stringify([[...state.storage.map].sort(), state.storage.alarm, state.storage.writes]);

// MARK: sessions.update

test("sessions.update from the Mac goes to every phone socket and no Mac socket", async () => {
  const mac = connect(true);
  const otherMac = connect(true);
  const p1 = connect(false), p2 = connect(false);
  await update(mac, { e: { ...E, extra: "dropped" }, junk: 1 });
  for (const p of [p1, p2]) {
    assert.deepEqual(p.frames("sessions.update").map(f => f.payload), [{ e: E }], "rebuilt {v, n, c} only");
  }
  assert.equal(mac.frames("sessions.update").length, 0);
  assert.equal(otherMac.frames("sessions.update").length, 0);
});

test("sessions.update makes zero storage writes and doesn't flush the reply queue", async () => {
  // A reply waiting for the Mac: a regular Mac frame would flush (and delete) it.
  await open(relay, iv("pg"));
  assert.equal((await call(relay, "POST", "/reply/pg", { text: "yes", action: null })).body.queued, true);
  const mac = connect(true);
  connect(false);
  const before = snapshot();
  for (let i = 0; i < 5; i++) await update(mac);
  assert.equal(snapshot(), before, "storage and alarm untouched");
  assert.equal(mac.frames("reply").length, 0);
  // The Mac's heartbeat / sync still flushes it.
  await macFrame(relay, mac, "heartbeat", { activeSessions: 1, battery: 50 });
  assert.equal(mac.frames("reply").length, 1);
});

test("sessions.update on a fresh object writes nothing, not even macEverSeen", async () => {
  const mac = connect(true);
  connect(false);
  await update(mac);
  assert.equal(state.storage.writes, 0);
  assert.equal(state.storage.map.size, 0);
});

test("malformed or oversized sessions.update frames are dropped", async () => {
  const mac = connect(true);
  const phone = connect(false);
  const bad = [
    null, "x", [], {}, { e: null }, { e: "x" },
    { e: { ...E, v: 2 } }, { e: { ...E, v: "1" } }, { e: { v: 1, n: E.n } }, { e: { v: 1, c: E.c } },
    { e: { ...E, n: 7 } }, { e: { ...E, c: ["x"] } }, { e: { ...E, n: "" } }, { e: { ...E, c: "" } },
    { e: { ...E, c: "not base64url!" } }, { e: { ...E, n: "a+b/c" } }, { e: { ...E, c: "ab=c" } },
    { e: { ...E, n: "A".repeat(65) } },
    { e: { ...E, c: "A".repeat(MAX_SESSIONS_UPDATE_BYTES) } }
  ];
  for (const payload of bad) await update(mac, payload);
  await relay.webSocketMessage(mac, JSON.stringify({ type: "sessions.update" }));   // no payload
  assert.equal(phone.frames("sessions.update").length, 0);

  // Padding is accepted, and anything up to the limit goes through.
  await update(mac, { e: { ...E, n: "oKGio6Slpqeoqaqr==", c: "AAAA=" } });
  await update(mac, { e: { ...E, c: "A".repeat(MAX_SESSIONS_UPDATE_BYTES - 100) } });
  assert.equal(phone.frames("sessions.update").length, 2);
});

test("only a Mac socket can send sessions.update", async () => {
  const mac = connect(true);
  const phone = connect(false);
  // Over HTTP: refused before anything is written (no macEverSeen either).
  const r = await call(relay, "POST", "/intervention", { type: "sessions.update", payload: { e: E } });
  assert.equal(r.status, 403);
  assert.equal(r.body.error, "mac_socket_only");
  assert.equal(phone.frames("sessions.update").length, 0);
  assert.equal(state.storage.writes, 0);
  assert.equal((await call(relay, "GET", "/status")).body.macEverSeen, true, "a Mac socket is open");

  // Over WS, an untagged socket sending sessions.update is NOT promoted to
  // the Mac (unlike the legacy rule for older Mac frames): it stays a phone,
  // its frame is refused and goes nowhere, and it never gets commands.
  const intruder = connect(false);
  mac.clear();
  await update(intruder);
  assert.notEqual(intruder.attachment?.role, "mac");
  assert.equal(phone.frames("sessions.update").length, 0, "refused, not forwarded");
  assert.equal(intruder.frames("sessions.update").length, 0);
  assert.equal(state.storage.writes, 0);
  await update(mac);
  assert.equal(phone.frames("sessions.update").length, 1);
  assert.equal(intruder.frames("sessions.update").length, 1, "still a phone: gets the Mac's update");
  await call(relay, "POST", "/sessions/command", { e: E });
  assert.equal(intruder.frames("sessions.command").length, 0, "never gets commands");
});

test("phone-originated sessions types sent over WS are dropped and never tag the socket", async () => {
  const mac = connect(true);
  const phone = connect(false);
  mac.clear();
  await relay.webSocketMessage(phone, JSON.stringify({ type: "sessions.command", payload: { e: E } }));
  await relay.webSocketMessage(phone, JSON.stringify({ type: "phones.status", payload: { phones: 9 } }));
  assert.equal(phone.attachment, null);
  assert.equal(mac.frames().length, 0);
  assert.equal(state.storage.writes, 0);
});

// MARK: POST /sessions/command

test("a command goes to every Mac socket, never to phones, and answers 202", async () => {
  const mac = connect(true), mac2 = connect(true);
  const phone = connect(false);
  const before = snapshot();
  const r = await command({ e: { ...E, extra: 1 } });
  assert.equal(r.status, 202);
  assert.deepEqual(r.body, { ok: true });
  assert.match(r.headers.get("cache-control"), /no-store/);
  for (const m of [mac, mac2]) {
    assert.deepEqual(m.frames("sessions.command").map(f => f.payload), [{ e: E }]);
  }
  assert.equal(phone.frames("sessions.command").length, 0);
  assert.equal(snapshot(), before, "zero storage writes");
});

test("no Mac socket: 503 mac_offline and nothing is queued", async () => {
  const phone = connect(false);
  const before = snapshot();
  const r = await command({ e: E });
  assert.equal(r.status, 503);
  assert.equal(r.body.error, "mac_offline");
  assert.equal(snapshot(), before);
  assert.equal(phone.frames("sessions.command").length, 0);
  // A Mac connecting later gets nothing from before.
  const mac = connect(true);
  await macFrame(relay, mac, "heartbeat", { activeSessions: 0, battery: 50 });
  assert.equal(mac.frames("sessions.command").length, 0);
  // A dead Mac socket counts as offline too.
  mac.failSend = true;
  assert.equal((await command({ e: E })).status, 503);
});

test("bad command bodies: 400 invalid_envelope / invalid_json, 413 too_large", async () => {
  const mac = connect(true);
  for (const body of [{}, { e: null }, { e: { ...E, v: 2 } }, { e: { ...E, c: "!" } }, [E], E, { e: { v: 1, n: E.n } }]) {
    const r = await command(body);
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.equal(r.body.error, "invalid_envelope");
  }
  assert.equal((await command("{not json")).body.error, "invalid_json");
  assert.equal((await command(undefined)).body.error, "invalid_envelope", "empty body");

  const big = await command({ e: { ...E, c: "A".repeat(MAX_SESSIONS_COMMAND_BYTES) } });
  assert.equal(big.status, 413);
  assert.equal(big.body.error, "too_large");
  // Multi-byte text is measured in bytes.
  const wide = await command(JSON.stringify({ e: E, pad: "é".repeat(MAX_SESSIONS_COMMAND_BYTES / 2) }));
  assert.equal(wide.status, 413);
  // A declared length over the limit is refused without reading.
  const declared = await relay.fetch(new Request("https://relay.test/sessions/command", {
    method: "POST", headers: { "content-length": String(MAX_SESSIONS_COMMAND_BYTES + 1) }, body: JSON.stringify({ e: E })
  }));
  assert.equal(declared.status, 413);
  assert.equal(mac.frames("sessions.command").length, 0);
});

/// A body of exactly `bytes` (ASCII, so chars == bytes) whose ciphertext is
/// padding: the Worker never looks inside it.
const sizedBody = bytes => {
  const pad = bytes - JSON.stringify({ e: { ...E, c: "" } }).length;
  const body = JSON.stringify({ e: { ...E, c: "A".repeat(pad) } });
  assert.equal(body.length, bytes);
  return body;
};

test("an image part's envelope (~59.5 KB) is forwarded whole; 64 KiB passes, 64 KiB + 1 is 413", async () => {
  // Images design: a 32 KiB raw part with the longest ids the Mac accepts
  // makes a body of about 59.5 KB, under the 64 KiB cap with room to spare.
  const mac = connect(true);
  const part = sizedBody(59_500);
  assert.ok(part.length < MAX_SESSIONS_COMMAND_BYTES);
  const r = await command(part);
  assert.equal(r.status, 202);
  const [frame] = mac.frames("sessions.command");
  assert.equal(frame.payload.e.c, JSON.parse(part).e.c, "ciphertext forwarded intact");

  assert.equal((await command(sizedBody(MAX_SESSIONS_COMMAND_BYTES))).status, 202, "exactly 64 KiB is allowed");
  const over = await command(sizedBody(MAX_SESSIONS_COMMAND_BYTES + 1));
  assert.equal(over.status, 413);
  assert.equal(over.body.error, "too_large");
  assert.equal(mac.frames("sessions.command").length, 2);
});

test("commands are rate limited to 120 a minute per relay", async () => {
  const mac = connect(true);
  for (let i = 0; i < SESSIONS_COMMAND_RATE; i++) assert.equal((await command({ e: E })).status, 202);
  const r = await command({ e: E });
  assert.equal(r.status, 429);
  assert.equal(r.body.error, "rate_limited");
  assert.equal(mac.frames("sessions.command").length, SESSIONS_COMMAND_RATE);
  clock.advance(1000);              // refills 2 a second
  assert.equal((await command({ e: E })).status, 202);
  assert.equal((await command({ e: E })).status, 202);
  assert.equal((await command({ e: E })).status, 429);
  clock.advance(60_000);
  assert.equal((await command({ e: E })).status, 202);
  assert.equal(state.storage.writes, 0);
});

test("a retired token answers /sessions/command with 410", async () => {
  const mac = connect(true);
  await macFrame(relay, mac, "relay.retire", { reason: "token_regenerated" });
  const r = await command({ e: E });
  assert.equal(r.status, 410);
  assert.equal(r.body.error, "token_retired");
});

// MARK: phones.status

test("phones.status reaches the Macs on Mac connect, phone open and phone close", async () => {
  const mac = connect(true);
  assert.deepEqual(phonesSeen(mac), [0], "on connect");
  const p1 = connect(false);
  const p2 = connect(false);
  assert.deepEqual(phonesSeen(mac), [0, 1, 2]);
  assert.equal(p1.frames("phones.status").length, 0, "never sent to phones");

  const mac2 = connect(true);
  assert.deepEqual(phonesSeen(mac2), [2]);

  await relay.webSocketClose(p1, 1000, "", true);
  assert.deepEqual(phonesSeen(mac).slice(-1), [1]);
  assert.deepEqual(phonesSeen(mac2).slice(-1), [1]);

  // webSocketError leaves the socket reading as open: it must still be excluded.
  await relay.webSocketError(p2, new Error("reset"));
  assert.equal(p2.readyState, 1);
  assert.deepEqual(phonesSeen(mac).slice(-1), [0]);

  // A Mac socket closing doesn't send phones.status.
  mac.clear();
  await relay.webSocketClose(mac2, 1000, "", true);
  assert.equal(mac.frames("phones.status").length, 0);
});

test("phones.status counts from getWebSockets, so it survives hibernation", async () => {
  connect(true);
  const p1 = connect(false);
  connect(false);
  // The object is evicted; the sockets live on in the same state.
  const woken = new UserRelay(state, env());
  const mac = connect(true, woken);
  assert.deepEqual(phonesSeen(mac), [2]);
  connect(false, woken);
  assert.deepEqual(phonesSeen(mac).slice(-1), [3]);

  const again = new UserRelay(state, env());
  await again.webSocketClose(p1, 1001, "gone", true);
  assert.deepEqual(phonesSeen(mac).slice(-1), [2]);
});

test("a socket accepted before it reads as open is still counted / still told", async () => {
  const mac = connect(true);
  const phone = new FakeWS();
  phone.readyState = 0;             // CONNECTING: the upgrade hasn't completed
  relay.attachSocket(phone, false);
  assert.deepEqual(phonesSeen(mac), [0, 1]);
  phone.readyState = 1;
  const mac2 = new FakeWS();
  mac2.readyState = 0;
  relay.attachSocket(mac2, true);
  assert.deepEqual(phonesSeen(mac2), [1], "the new Mac is told directly");
  mac2.readyState = 1;
  assert.deepEqual(phonesSeen(mac), [0, 1, 1], "one frame per event, no duplicates");
  connect(true);
  assert.deepEqual(phonesSeen(mac2), [1, 1], "and only once");
});

test("a legacy Mac tagged by its first frame stops counting as a phone", async () => {
  const mac = connect(true);
  const legacy = connect(false);
  assert.deepEqual(phonesSeen(mac), [0, 1]);
  await macFrame(relay, legacy, "heartbeat", { activeSessions: 0, battery: 80 });
  assert.deepEqual(phonesSeen(mac).slice(-1), [0]);
  assert.deepEqual(phonesSeen(legacy), [0]);
});

// MARK: /status

test("/status advertises sessions-v1", async () => {
  assert.deepEqual((await call(relay, "GET", "/status")).body.features, ["sessions-v1", "reply-retract-v1"]);
});

// MARK: pure logic

test("parseSessionsEnvelope / parseSessionsUpdate / takeToken", () => {
  assert.deepEqual(parseSessionsEnvelope(E), E);
  assert.equal(parseSessionsEnvelope({ ...E, v: 1.5 }), null);
  assert.deepEqual(parseSessionsUpdate({ e: E }), { ok: true, e: E, bytes: JSON.stringify({ e: E }).length });
  assert.deepEqual(parseSessionsUpdate({ e: { ...E, v: 0 } }), { ok: false, error: "invalid_envelope" });
  assert.deepEqual(
    parseSessionsUpdate({ e: E, pad: "é".repeat(MAX_SESSIONS_UPDATE_BYTES / 2) }),
    { ok: false, error: "too_large" }, "bytes, not chars"
  );

  let b;
  for (let i = 0; i < 3; i++) {
    const t = takeToken(b, 0, 3, 60_000);
    assert.equal(t.allowed, true);
    b = t.bucket;
  }
  assert.equal(takeToken(b, 0, 3, 60_000).allowed, false);
  assert.equal(takeToken(b, -10_000, 3, 60_000).allowed, false, "a clock stepping back refills nothing");
  assert.equal(takeToken(b, 20_000, 3, 60_000).allowed, true);
  assert.equal(takeToken({ tokens: 0, at: 0 }, 10 * 60_000, 3, 60_000).bucket.tokens, 2, "refill caps at capacity");
});
