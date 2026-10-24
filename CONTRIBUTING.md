# Contributing to Page

Thanks for considering a contribution. The bar is simple: does this make Page
clearly better for someone running their own agents, without making it less
safe?

## Quick links

- **Bug?** Open an issue with the Bug Report template. Include an excerpt
  from `~/Library/Logs/ClaudePowerMode.log` (and `~/Library/Logs/page-hook.log`
  for hook problems). Both redact the relay token, but check the excerpt for
  project paths or prompt text you'd rather not post.
- **Feature idea?** Open a Discussion, or an issue with the Feature Request
  template. We say no to a lot of features; please don't take it personally.
- **Security issue?** **Do not** open a public issue. See
  [SECURITY.md](SECURITY.md).

Background reading:

- [README.md](README.md): what Page does, its configuration and its safety
  model.
- [docs/PROTOCOL.md](docs/PROTOCOL.md): the wire protocol between the Mac,
  the hook, the Worker and the phone.
- [docs/ROADMAP.md](docs/ROADMAP.md): where the project is going.
- [Cloudflare/README.md](Cloudflare/README.md) and
  [iOS/README.md](iOS/README.md): component details.

## Safety rules for contributors

Page types into terminals that can run arbitrary commands. These rules are
not optional.

1. **Never test reply delivery against real agent sessions.** Don't point a
   development build at your own running Claude Code or Codex sessions, and
   don't send keystrokes, `tmux send-keys`, AppleScript, `cmux` commands or
   anything else to a terminal, cmux, `claude` or `codex` process you didn't
   create for the test. One wrong key on a permission menu approves a tool
   call.
2. **Use private tmux servers.** Injection tests run against a throwaway
   server on its own socket, with a harmless program in the pane:

   ```sh
   tmux -L page-test new-session -d -s t 'cat'
   # … exercise the code against `tmux -L page-test` …
   tmux -L page-test kill-server
   ```

   Never use the default tmux server (no `-L`): that's where real sessions
   live. Unit tests use fakes and fixtures for `ps`, `lsof`, AppleScript and
   the `cmux` CLI. The real cmux runner refuses socket commands under XCTest.
3. **Don't touch real user state from tests or scripts.** This means
   `~/.claude`, `~/.codex`, `~/Library/LaunchAgents`, the real `config.json`
   and `relay_token.txt`, the Keychain, and `pmset` (except read-only
   `pmset -g`). Use temp directories and injected runners. The Worker's hook
   test runs `page-notify.sh` with a temp `HOME`, a fake `ioreg` and a local
   relay.
4. **Keep the delivery invariants.** A change to `InjectionExecutor`,
   `CodexInjector`, `CmuxBridge` or the hook must keep every rule in the
   README's [Safety model](README.md#safety-model):
   - exact target or fail;
   - keys that depend on the live status;
   - no text + Enter while a prompt is showing, and no digit assumed to mean
     "No" (a lone Esc denies; Terminal.app's appended Return after a single
     menu digit is the one documented exception);
   - refuse stale answers;
   - never type over drafts;
   - fail closed with a phone-safe reason;
   - hooks are away-only and never decide on their own.

   Add a test that would have caught the bug you're fixing.
5. **No secrets or user content in logs or on the wire.** Never log the relay
   token, reply text or terminal output. `reply.injected.detail` is shown on
   the phone, so keep it short, human and free of command output. Context
   leaving the Mac goes through `ContextRedactor`.
6. **No cmux code.** cmux is GPL-3.0. Page is Apache-2.0. Don't copy, port or
   paraphrase cmux source. Drive it through its CLI only (see
   [ROADMAP.md](docs/ROADMAP.md#licensing)).

## Dev loop

### Mac app (Swift)

```sh
swift build                    # debug build
swift test                     # XCTest suites in Tests/ClaudePowerModeTests
swift test --filter InjectionSafety   # all InjectionSafety* suites
./build.sh                     # release Page.app (CONFIG, VERSION, CODESIGN_IDENTITY optional)
```

- `./install.sh` builds, installs to `/Applications`, and restarts the
  `local.Page` LaunchAgent, so it replaces your running Page. Only use it
  when you mean to.
- `build.sh` signs with `CODESIGN_IDENTITY`, else the first "Apple
  Development" identity, else the first "Developer ID Application" identity,
  else ad-hoc. A stable identity keeps macOS permission grants across
  rebuilds.
- Follow the app's log with `tail -f ~/Library/Logs/ClaudePowerMode.log`.

The Mac side is a single SwiftPM executable target named `ClaudePowerMode`
(the name predates the rename to Page), plus one test target. Backends
(`ClaudeBackend`, `CodexBackend`) implement `AgentBackend`, and battery pause
support is `BatteryPausable`. The `Coordinator` owns the one shared
`RelayClient`.

Where to put things:

- Spawn every subprocess through `ProcessRunner`; don't use raw `Process`
  with `waitUntilExit`.
- Keep decision logic in pure functions with tests. Most of the code already
  works this way: `decide()`, `plan()`, `BatteryPolicy`, `HookInstaller`,
  `Config.validated()`.

### Cloudflare Worker (TypeScript)

```sh
cd Cloudflare
npm install
npm test                       # node:test against src/ (Node ≥ 22.18 runs the TS directly)
npm run typecheck              # tsc --noEmit
npx wrangler dev               # http://localhost:8787 (the Mac accepts http:// for localhost)
npm run deploy                 # typecheck + tests, then deploy to your own account
```

Decision logic lives in `src/logic.ts` (pure, unit-tested). `src/durable.ts`
wires it to storage, sockets and APNs. `test/hook.test.mjs` also runs
`hooks/page-notify.sh` end to end; it's skipped if bash, jq or curl is
missing. Wrangler migrations are append-only: never rename `UserRelay` or
edit the `v1` tag.

### Hook (bash + Python)

```sh
bash -n hooks/page-notify.sh
python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' hooks/page-extract-context.py
(cd Cloudflare && npm test)    # includes the end-to-end hook test
```

The script must keep working under macOS `/bin/bash` 3.2 and `sh`: no
associative arrays, no `${x,,}`, no process substitution. Every path exits 0,
and a decision is printed only for an explicit phone answer. The redaction
patterns in `page-extract-context.py` and the Swift `ContextRedactor` must
stay in sync; `ContextRedactorTests` compares them.

### iOS app (SwiftUI)

```sh
cd iOS
xcodegen generate              # regenerate Page.xcodeproj from project.yml
xcodebuild -project Page.xcodeproj -scheme Page -sdk iphonesimulator \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
./Tests/run-logic-tests.sh     # Page/Models logic tests with swiftc, no simulator
```

XcodeGen is the source of truth: edit `project.yml`, not the `.xcodeproj`.
Per-developer signing goes in the git-ignored `Config/Local.xcconfig`. See
[iOS/README.md](iOS/README.md) for push setup and the DEBUG launch arguments.

### Before you open a PR

Run whichever of these your change touches:

```sh
swift build && swift test
(cd Cloudflare && npm run typecheck && npm test)
./iOS/Tests/run-logic-tests.sh
bash -n hooks/page-notify.sh
```

CI (`.github/workflows/ci.yml`) currently runs only `swift build` (debug and
release), the iOS simulator build, and the Worker typecheck. It does **not**
run the test suites, so run them locally.

## File layout

```
Sources/ClaudePowerMode/   Mac app
  Backends/                AgentBackend, ClaudeBackend, CodexBackend
  Codex/                   app-server client + protocol, CodexInjector
  …                        Coordinator, RelayClient, InjectionExecutor, CmuxBridge,
                           HookInstaller, PowerManager, PowerBatteryPolicy, SleepGuard,
                           ResumeScheduler, RateLimitWatcher, ProcessRunner, Config, …
Tests/ClaudePowerModeTests/  XCTest suites (one file per area)
Cloudflare/src/            Worker: index.ts, durable.ts, logic.ts, apns.ts, types.ts
Cloudflare/test/           node:test suites + in-memory Durable Object shim
iOS/Page/                  SwiftUI app (Models/ is Foundation-only and tested by iOS/Tests/)
hooks/                     page-notify.sh, page-extract-context.py
docs/                      PROTOCOL.md, ROADMAP.md
build.sh, install.sh       build/sign; install/power helpers/hooks/uninstall
```

## Code style

- **Swift:** follow the surrounding code. Use descriptive names, write
  comments that explain *why*, and prefer pure functions for decisions. Stay
  AppKit and Foundation only, with no third-party dependencies.
- **TypeScript:** `tsc` strict, Web APIs only, no runtime dependencies.
- **Logging:** Page is a long-running daemon. A line per tick is about 5,800
  lines a day. Log state changes, not state queries, and never secrets.
- **Wire changes:** add optional fields only, update
  [docs/PROTOCOL.md](docs/PROTOCOL.md), and keep old peers working.

## Commit messages and PRs

Conventional-ish prefixes are nice but not required:

```
feat(codex): rate-limit signal via account/rateLimits/updated
fix(claude): refuse approve when the prompt key no longer matches
docs: protocol v2 reference
```

The body should explain the why. The diff already shows the what.

- One thing per PR. If you find yourself writing "and also", split it.
- Include a test plan, for example "ran swift test and npm test; exercised
  delivery against a `tmux -L page-test` pane running cat".
- Squash-merge by default.

## What we won't take

- **Other transports** (Slack, Discord, email). Page is a phone-app product.
  A downstream service can subscribe to the Worker's WebSocket.
- **Telemetry or analytics SDKs.** Your prompts go only to your own Worker
  and Apple's push service.
- **Heavy dependencies** on either side.
- **Anything that weakens the safety rules for convenience.** That includes
  auto-approving, typing into "the most likely" terminal, or sending Enter to
  a prompt.

## License

By contributing, you agree that your contributions are licensed under the
Apache License 2.0 (see [LICENSE](LICENSE)). Submitting a PR implies you agree
to the Developer Certificate of Origin: you wrote it, or you have the right
to license it under Apache 2.0, and you understand the project may
redistribute it.
