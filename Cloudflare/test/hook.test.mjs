// End-to-end tests for hooks/page-notify.sh against the real UserRelay,
// served over a local HTTP server. Each test runs the hook with a temp HOME
// (token, logs, hold markers), a fake `ioreg` (the user is "away") and the
// relay on 127.0.0.1. Nothing touches the real ~/.claude or any terminal.
// Skipped when bash/jq/curl aren't available.
import { test, before, after, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { spawn, execFileSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, chmodSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { UserRelay } from "../src/durable.ts";
import { FakeState, env } from "./helpers.mjs";

const HOOK = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "hooks", "page-notify.sh");
const TOKEN = "test-token-0123456789abcdefghij";
const SID = "abcdef12-3456-7890-abcd-ef1234567890";

function have(cmd) {
  try { execFileSync("/bin/sh", ["-c", `command -v ${cmd}`], { stdio: "ignore" }); return true; } catch { return false; }
}
const skip = !(have("bash") && have("jq") && have("curl")) && "needs bash, jq and curl";

let server, port, relay, requests, dropNextOpenResponse;
before(async () => {
  if (skip) return;
  server = createServer(async (req, res) => {
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const body = Buffer.concat(chunks).toString();
    const entry = { method: req.method, url: req.url, ua: req.headers["user-agent"], body: body ? JSON.parse(body) : undefined };
    requests.push(entry);
    const out = await relay.fetch(new Request(`http://relay.test${req.url}`, {
      method: req.method, headers: req.headers, body: body || undefined
    }));
    if (dropNextOpenResponse && entry.body?.type === "intervention.opened") {
      // The Worker stored the page, but the response never reaches the hook.
      dropNextOpenResponse = false;
      req.socket.destroy();
      return;
    }
    res.writeHead(out.status, { "content-type": "application/json" });
    res.end(await out.text());
  });
  await new Promise(r => server.listen(0, "127.0.0.1", r));
  port = server.address().port;
});
after(() => server?.close());

let home, bin, logFile;
beforeEach(() => {
  if (skip) return;
  relay = new UserRelay(new FakeState(), env());
  requests = [];
  dropNextOpenResponse = false;
  home = mkdtempSync(join(tmpdir(), "page-hook-test-"));
  const support = join(home, "Library", "Application Support", "ClaudePowerMode");
  mkdirSync(support, { recursive: true });
  writeFileSync(join(support, "relay_token.txt"), TOKEN + "\n");
  bin = join(home, "bin");
  mkdirSync(bin);
  // Away from the Mac for 999 s, unless a test writes the epoch of the
  // "last input" to $HOME/lastinput.
  writeFileSync(join(bin, "ioreg"), [
    "#!/bin/sh",
    "if [ -f \"$HOME/lastinput\" ]; then idle=$(( $(date +%s) - $(cat \"$HOME/lastinput\") )); else idle=999; fi",
    "echo \"    | |   \\\"HIDIdleTime\\\" = ${idle}000000000\"",
    ""
  ].join("\n"));
  chmodSync(join(bin, "ioreg"), 0o755);
  logFile = join(home, "hook.log");
});
afterEach(() => { if (home) rmSync(home, { recursive: true, force: true }); });

function hookEnv(extra = {}) {
  return {
    HOME: home,
    PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin`,
    TMPDIR: home,
    PAGE_RELAY_URL: `http://127.0.0.1:${port}`,
    PAGE_HOOK_LOG: logFile,
    // These tests may themselves run under a `claude -p`; only the M1 cases
    // (which build their own `claude -p` parent) test the step-aside.
    PAGE_HOOK_PRINT: "1",
    ...extra
  };
}

const permissionEvent = (o = {}) => ({
  hook_event_name: "PermissionRequest", session_id: SID, cwd: "/tmp/acme",
  tool_name: "Bash", tool_input: { command: "npm test" }, permission_mode: "default", ...o
});

/// Runs the hook. `argv` defaults to the script itself; `wrap` builds a
/// custom bash -c command line around "$HOOK" and "$EVT".
function runHook(event, { args = [], extraEnv = {}, wrap } = {}) {
  const evtFile = join(home, `evt-${Math.random().toString(36).slice(2)}.json`);
  writeFileSync(evtFile, JSON.stringify(event));
  const hookEnvVars = { ...hookEnv(extraEnv), HOOK, EVT: evtFile };
  const child = wrap
    ? spawn("/bin/bash", ["-c", wrap], { env: hookEnvVars })
    : spawn("/bin/bash", [HOOK, ...args], { env: hookEnvVars, stdio: ["pipe", "pipe", "pipe"] });
  if (!wrap) { child.stdin.end(JSON.stringify(event)); }
  let stdout = "";
  child.stdout.on("data", d => { stdout += d; });
  child.stderr.on("data", () => {});
  const done = new Promise(resolve => child.on("close", code => resolve({ code, stdout })));
  return { child, done };
}

async function until(fn, ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v) return v;
    await new Promise(r => setTimeout(r, 50));
  }
  throw new Error("timed out waiting");
}

const support = () => join(home, "Library", "Application Support", "ClaudePowerMode");
const nowSec = () => Math.floor(Date.now() / 1000);
const userInputAt = (sec) => writeFileSync(join(home, "lastinput"), `${sec}\n`);
const syntheticAt = (sec) => writeFileSync(join(support(), "synthetic-input"), `${sec}\n`);
const reply = (id, body) => relay.fetch(new Request(`http://relay.test/reply/${id}`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body)
}));

const opens = () => requests.filter(r => r.body?.type === "intervention.opened");
const closes = () => requests.filter(r => r.body?.type === "intervention.closed");
const log = () => (existsSync(logFile) ? readFileSync(logFile, "utf8") : "");
const pending = async () => (await (await relay.fetch(new Request("http://relay.test/interventions"))).json());

test("phone approve: the hook announces its wait, prints allow, and closes the page as replied", { skip, timeout: 30000 }, async () => {
  const { done } = runHook(permissionEvent());
  const open = await until(() => opens()[0]);
  const id = open.body.payload.id;
  assert.match(id, /^hookpre-abcdef12-/);
  assert.equal(open.body.payload.holdSeconds <= 540 && open.body.payload.holdSeconds >= 530, true, `holdSeconds=${open.body.payload.holdSeconds}`);
  const r = await relay.fetch(new Request(`http://relay.test/reply/${id}`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text: "", action: "approve" })
  }));
  assert.equal(r.status, 200);
  const { code, stdout } = await done;
  assert.equal(code, 0);
  assert.equal(JSON.parse(stdout).hookSpecificOutput.decision.behavior, "allow");
  assert.deepEqual(closes().map(c => c.body.payload.reason), ["replied"]);
  assert.deepEqual(await pending(), []);
});

test("H1: a lost open response still gets the page closed (no orphan on the relay)", { skip, timeout: 30000 }, async () => {
  dropNextOpenResponse = true;
  const { done } = runHook(permissionEvent());
  const { stdout } = await done;
  assert.equal(stdout, "", "falls back to the dialog");
  assert.equal(opens().length, 1);
  assert.equal(closes().length, 1, "the close goes out although the open answered 000");
  assert.equal(closes()[0].body.payload.id, opens()[0].body.payload.id);
  assert.deepEqual(await pending(), []);
});

test("M2: the wait is capped by --agent-timeout whatever PAGE_HOOK_TIMEOUT says", { skip, timeout: 30000 }, async () => {
  const { child, done } = runHook(permissionEvent(), { args: ["--agent-timeout", "45"], extraEnv: { PAGE_HOOK_TIMEOUT: "900" } });
  const open = await until(() => opens()[0]);
  assert.ok(open.body.payload.holdSeconds <= 15, `holdSeconds=${open.body.payload.holdSeconds}`);
  assert.match(log(), /PAGE_HOOK_TIMEOUT=900 capped to \d+s by the agent's 45s hook timeout/);
  child.kill("SIGTERM");
  const { stdout } = await done;
  assert.equal(stdout, "");
  assert.deepEqual(closes().map(c => c.body.payload.reason), ["hook_exited"]);
  // --codex still parses alongside the new argument.
  requests = [];
  const codex = runHook(permissionEvent(), { args: ["--codex", "--agent-timeout=45"] });
  const o2 = await until(() => opens()[0]);
  assert.equal(o2.body.payload.backend, "codex");
  codex.child.kill("SIGTERM");
  await codex.done;
});

test("M1: dontAsk mode and claude --print runs step aside; PAGE_HOOK_PRINT=1 pages them", { skip, timeout: 30000 }, async () => {
  const noOptIn = { PAGE_HOOK_PRINT: "" };
  let r = await runHook(permissionEvent({ permission_mode: "dontAsk" }), { extraEnv: noOptIn }).done;
  assert.equal(r.stdout, "");
  assert.equal(requests.length, 0);

  // A parent whose argv reads `claude … -p` (argv[0] set with exec -a).
  const wrap = 'exec -a claude /bin/bash -c \'/bin/bash "$HOOK" < "$EVT"; true\' claude-arg0 -p';
  r = await runHook(permissionEvent(), { wrap, extraEnv: noOptIn }).done;
  assert.equal(r.stdout, "");
  assert.equal(requests.length, 0);
  assert.match(log(), /non-interactive claude --print run/);

  // A --print process driven by a host that can prompt (IDE/SDK sessions)
  // is not stepped around.
  const hosted = runHook(permissionEvent(), {
    wrap: `${wrap} --input-format stream-json --output-format stream-json`, extraEnv: noOptIn
  });
  await until(() => opens()[0]);
  hosted.child.kill("SIGTERM");
  await hosted.done;
  requests = [];

  const paged = runHook(permissionEvent(), { wrap: `PAGE_HOOK_PRINT=1 ${wrap}`, extraEnv: noOptIn });
  await until(() => opens()[0]);
  await relay.fetch(new Request(`http://relay.test/reply/${opens()[0].body.payload.id}`, {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ text: "", action: "deny" })
  }));
  r = await paged.done;
  assert.equal(JSON.parse(r.stdout).hookSpecificOutput.decision.behavior, "deny");
});

test("PAGE_HOOK_SKIP=1 makes the hook inert", { skip, timeout: 30000 }, async () => {
  const r = await runHook(permissionEvent(), { extraEnv: { PAGE_HOOK_SKIP: "1" } }).done;
  assert.equal(r.stdout, "");
  assert.equal(requests.length, 0);
});

test("L2: when the agent process goes away the hook stops waiting and closes as agent_exited", { skip, timeout: 30000 }, async () => {
  // The agent (a parent whose argv[0] is `claude`) starts the hook and
  // exits after a second, as a crashed or SIGKILLed agent would.
  const wrap = 'exec -a claude /bin/bash -c \'/bin/bash "$HOOK" < "$EVT" & sleep 1; exit 0\' claude-arg0';
  const { done } = runHook(permissionEvent(), { wrap });
  await until(() => closes()[0], 20000);
  assert.equal(closes()[0].body.payload.reason, "agent_exited");
  await done;
});

test("SEC-5: plain http to a non-local host (or with user-info) never carries the token", { skip, timeout: 30000 }, async () => {
  for (const url of [`http://localhost.example.com:${port}`, `http://localhost:x@127.0.0.1:${port}`, `http://127.0.0.1.nip.io:${port}`]) {
    requests = [];
    const r = await runHook(permissionEvent(), { extraEnv: { PAGE_RELAY_URL: url } }).done;
    assert.equal(r.stdout, "", url);
    assert.equal(requests.length, 0, url);
  }
  assert.match(log(), /plain http for a non-local host/);
});

test("L3: a GNU stat ahead of /usr/bin doesn't make the Mac detector look dead", { skip, timeout: 30000 }, async () => {
  writeFileSync(join(bin, "stat"), "#!/bin/sh\n# GNU stat: -f means --file-system\nexit 1\n");
  chmodSync(join(bin, "stat"), 0o755);
  writeFileSync(join(home, "Library", "Application Support", "ClaudePowerMode", "detector.alive"), "");
  const r = await runHook({
    hook_event_name: "Notification", session_id: SID, cwd: "/tmp/acme",
    notification_type: "permission_prompt", message: "Claude needs your permission to use Bash"
  }).done;
  assert.equal(r.stdout, "");
  assert.equal(requests.length, 0);
  assert.match(log(), /Mac detector alive/);
  rmSync(join(bin, "stat"));
});

// MARK: promptKey

test("promptKey: PermissionRequest sends the event's tool_use_id", { skip, timeout: 30000 }, async () => {
  const { child, done } = runHook(permissionEvent({ tool_use_id: "toolu_01PermEvent" }));
  const open = await until(() => opens()[0]);
  assert.equal(open.body.payload.promptKey, "toolu_01PermEvent");
  assert.equal((await pending())[0].promptKey, "toolu_01PermEvent", "the Worker stores it");
  child.kill("SIGTERM");
  await done;
});

test("promptKey: without tool_use_id, the first unanswered tool call (the prompt Claude shows first, as the Mac compares)", { skip, timeout: 30000 }, async () => {
  const transcript = join(home, "t.jsonl");
  const lines = [
    { type: "user", message: { content: "go" } },
    { type: "assistant", message: { content: [{ type: "tool_use", id: "toolu_A", name: "Bash", input: {} }] } },
    { type: "user", message: { content: [{ type: "tool_result", tool_use_id: "toolu_A" }] } },
    { type: "assistant", message: { content: [{ type: "tool_use", id: "toolu_B", name: "Bash", input: {} },
                                              { type: "tool_use", id: "toolu_C", name: "Edit", input: {} }] } },
    { type: "assistant", isSidechain: true, message: { content: [{ type: "tool_use", id: "toolu_SIDE", name: "Bash", input: {} }] } },
    { type: "system", subtype: "turn_duration" }
  ];
  writeFileSync(transcript, "half a line\"}\n" + lines.map(l => JSON.stringify(l)).join("\n") + "\n");
  const r = await runHook({
    hook_event_name: "Notification", session_id: SID, cwd: "/tmp/acme", transcript_path: transcript,
    notification_type: "permission_prompt", message: "Claude needs your permission to use Edit"
  }).done;
  assert.equal(r.stdout, "");
  const open = opens()[0];
  assert.match(open.body.payload.id, /^hook-abcdef12-/);
  assert.equal(open.body.payload.promptKey, "toolu_B");

  // Answered, or a real user message since: no key at all.
  requests = [];
  writeFileSync(transcript, lines.map(l => JSON.stringify(l)).join("\n") + "\n" +
    JSON.stringify({ type: "user", message: { content: [{ type: "text", text: "never mind" }] } }) + "\n");
  await runHook({
    hook_event_name: "Notification", session_id: SID, cwd: "/tmp/acme", transcript_path: transcript,
    notification_type: "idle_prompt", message: "Claude is waiting for your input"
  }).done;
  assert.equal("promptKey" in opens()[0].body.payload, false);
});

test("promptKey: a malformed tool_use_id is never sent", { skip, timeout: 30000 }, async () => {
  const { child, done } = runHook(permissionEvent({ tool_use_id: "toolu_1; rm -rf /" }));
  const open = await until(() => opens()[0]);
  assert.equal("promptKey" in open.body.payload, false);
  child.kill("SIGTERM");
  await done;
});

// MARK: Page's own synthetic keystroke

test("presence: an idle reset explained by Page's synthetic-input marker still pages; others step aside", { skip, timeout: 30000 }, async () => {
  // Input 1 s ago, and Page typed at that moment: away.
  userInputAt(nowSec() - 1);
  syntheticAt(nowSec() - 1);
  const paged = runHook(permissionEvent());
  await until(() => opens()[0]);
  assert.match(log(), /Page's own keystroke — treating as away/);
  paged.child.kill("SIGTERM");
  await paged.done;

  // No marker: the user is at the Mac.
  requests = [];
  rmSync(join(support(), "synthetic-input"));
  let r = await runHook(permissionEvent()).done;
  assert.equal(r.stdout, "");
  assert.equal(requests.length, 0);
  assert.match(log(), /user is at the Mac/);

  // A marker 10 s away from the input doesn't explain it.
  userInputAt(nowSec() - 1);
  syntheticAt(nowSec() - 11);
  r = await runHook(permissionEvent()).done;
  assert.equal(requests.length, 0);
});

test("wait: Page's own keystroke mid-wait doesn't end the wait; a real input does", { skip, timeout: 30000 }, async () => {
  const first = runHook(permissionEvent());
  const open = await until(() => opens()[0]);
  const t = nowSec();
  syntheticAt(t);
  userInputAt(t);
  await until(() => /Page's own keystroke — still waiting/.test(log()), 10000);
  assert.equal(closes().length, 0);
  await reply(open.body.payload.id, { text: "", action: "approve" });
  const { stdout } = await first.done;
  assert.equal(JSON.parse(stdout).hookSpecificOutput.decision.behavior, "allow");
  assert.deepEqual(closes().map(c => c.body.payload.reason), ["replied"]);

  // Control: the same input without a marker is the user coming back.
  requests = [];
  rmSync(join(home, "lastinput"));
  rmSync(join(support(), "synthetic-input"));
  const second = runHook(permissionEvent());
  await until(() => opens()[0]);
  userInputAt(nowSec());
  const r = await second.done;
  assert.equal(r.stdout, "");
  assert.deepEqual(closes().map(c => c.body.payload.reason), ["user_returned"]);
});

// MARK: token retirement

test("a waiting hook whose token is retired falls back at once (no 10 failed polls)", { skip, timeout: 30000 }, async () => {
  const { done } = runHook(permissionEvent());
  await until(() => opens()[0]);
  const t0 = Date.now();
  await relay.fetch(new Request("http://relay.test/intervention", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "relay.retire", payload: { reason: "token_regenerated" } })
  }));
  const r = await done;
  assert.equal(r.stdout, "");
  assert.ok(Date.now() - t0 < 8000, "gave up on the first 410 poll");
  assert.match(log(), /relay token was retired/);
  assert.equal(closes().length, 0, "no close is attempted for a page the Worker already dropped");
});
