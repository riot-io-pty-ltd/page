# Security Policy

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Email the maintainer with details instead. We'll acknowledge receipt within
72 hours, and aim to land a fix within two weeks for anything that looks like
a real exposure. We credit reporters in the release notes unless you'd
prefer otherwise.

## What Page is, from a security point of view

Page relays prompts from AI coding agents on your Mac to your phone, and
types your answers back into those agents' terminals. Those terminals can run
arbitrary commands. So **a reply Page delivers can approve a tool call**, and
the security model is about who can send replies and what Page will type.

```
 Mac (trusted)  ──wss/https──▶  your Cloudflare Worker  ──APNs──▶  your iPhone (trusted)
   Page.app, hook                 (you deploy and own it)            Page app
```

| Component | Trust and attack surface |
|---|---|
| **Mac app** | Runs as you, from a LaunchAgent. It can send Apple Events to Terminal.app and iTerm2 (Automation), post a Return key through System Events for Codex in Terminal.app (Accessibility), drive cmux through its CLI, run `claude`/`codex` in the background, and run the narrow `pmset` commands below through sudo if you opted in. It has no listening network socket. Its only remote peer is your Worker |
| **Hook** (`hooks/page-notify.sh`) | Run by Claude Code / Codex as you. It POSTs pages to your Worker over HTTPS and prints a permission decision only for an explicit phone answer |
| **Worker** | A public HTTPS/WebSocket endpoint on your Cloudflare account. Its only authentication is the bearer relay token |
| **iOS app** | Connects to your Worker. Receives APNs pushes. Lock-screen actions require device authentication |

## The relay token

**The relay token is the only credential.** Anyone who has it can:

- read your pending pages and the last 300 closed ones, including their
  context and your replies;
- see presence (battery, session count);
- register a phone for push;
- **send replies that your Mac will deliver.** Delivery is still subject to
  the safety rules in the [README](README.md#safety-model): exact target,
  status-aware keys, staleness checks, fail closed. Those rules limit what a
  reply can do; they don't decide who may send one.

The token alone can **not** read the live sessions view or type into a
session from it: that needs the session key (next section).

How the token is generated and handled:

- **Generated** on the Mac: 32 random bytes from `SecRandomCopyBytes` (with
  the system generator as a fallback), base64url-encoded to 43 characters.
- **Mac:** stored in
  `~/Library/Application Support/ClaudePowerMode/relay_token.txt`. The file
  is created 0600 from the start: written to an `O_EXCL` temp file, fsynced
  and renamed. Any process running as your user can read it (the hook does).
- **Phone:** stored in the iOS Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; not in backups, not
  synced).
- **Shown** in the pairing QR. "Copy pairing JSON" marks the clipboard entry
  concealed and transient for clipboard managers that honour it.
- **Sent** only as an `Authorization: Bearer` header over TLS. Plain `http://`
  relay URLs are refused except for `localhost`, `127.0.0.1` and `[::1]` (for
  `wrangler dev`). The hook passes the token to `curl` through a config file
  on stdin, never on the command line, and ignores `~/.curlrc`.
- **Never logged.** The Mac log redacts bearer tokens and `token=` values. The
  hook log (0600) never contains it. The Worker logs ids, sizes and outcomes
  only.

**Rotating and retiring it.** In the Mac's pairing window (**Pair phone…**),
click **Regenerate token…**:

1. Before switching, the Mac sends `relay.retire` on the old token.
2. The Worker marks that token retired, permanently.
3. It deletes the token's pending pages, queued replies and registered
   phones, sends nothing more for it, and closes its sockets.
4. From then on it answers every request on the old token with
   `410 token_retired`.
5. Phones paired with the old token are told to re-pair.

Rotate if a QR screenshot, a pairing JSON, a backup or a log containing the
token may have leaked. An older Worker that predates retirement keeps
accepting the old token. Redeploy the Worker to get retirement.

**Known gaps:**

- **No rate limiting.** The Worker has no rate limit, and anyone can create
  Durable Objects for tokens of their own. Add a Cloudflare rate-limiting
  rule or WAF rule if that matters to you.
- **No account system.** There's no per-user identity beyond the token.

## The live-sessions key (end-to-end)

The phone's **Sessions** tab (docs/SESSIONS-PROTOCOL.md) is end-to-end
encrypted with a second secret, the **session key**:

- **Generated** on the Mac (32 bytes from `SecRandomCopyBytes`), stored next
  to the token in `session_key.txt` with the same 0600 atomic write, and
  sent to the phone only inside the pairing QR (`sk`). The phone keeps it in
  the Keychain. **Regenerate token…** replaces it too.
- **Directional keys.** Each direction has its own HKDF-SHA256 subkey
  (`mac->phone`, `phone->mac`), and each frame is AES-256-GCM with a fresh
  random nonce and the frame type as associated data. The relay can't
  reflect a Mac frame back as a command or relabel one frame as another.
- **What the relay sees:** that a list, transcript or command went by, its
  size and timing, and how many phones are connected. **What it can't
  see:** session titles, folders, transcripts, typed text, or even which
  session a command targets. Nothing in this view is written to Worker
  storage, history, logs or push payloads.
- **Typing requires the key.** The Mac acts on a command only if it
  decrypts with the phone→Mac key, is within ±5 minutes of the Mac's clock
  and hasn't been seen in the last 15 minutes (seen ids are kept on disk,
  in `session_replay.json`, so a captured command can't be replayed after
  Page restarts either). A leaked relay token alone
  can't type anything here. Every accepted command then goes through the
  Mac's input gate, which never weakens the reply path's rules (no Esc on a
  prompt, no typing over a draft, no background resume).
- **Only while someone is looking.** The Mac sends the list only while a
  phone socket is open, and transcripts only for sessions a phone is
  viewing. The transcript never includes tool output; text is redacted
  before it's cut. The Terminal view mirrors the watched session's visible
  screen (tmux and cmux only), which can show tool output: every line is
  redacted, and it's sent only while that session is open on the phone.
  The Mac logs session id prefixes, the operation, the outcome and lengths,
  never content.
- **If the session key leaks** (a QR screenshot, a backup of the phone's
  Keychain), regenerate the token: the old key stops working on the Mac at
  once. Turn the view off entirely with `remoteSessionsEnabled: false`
  (**Preferences ▸ Phone**); the Mac then refuses every command.

## Features that act on the Mac from the phone (v4)

- **Starting a session** runs a command on the Mac, so it is off by default
  (`phoneStartSessionsEnabled`). When on, it accepts only an authenticated
  `sessions.command` (the pairing's session key), only for a folder where
  Claude sessions already ran in the last 30 days (exact match), and runs a
  fixed command, `claude -- '<prompt>'`: the prompt is one shell-quoted
  argument after `--`, folded to one line with control characters
  stripped, so it can't become a flag or a second command. A one-word prompt gets a full stop added, because Claude Code matches its first argument against subcommand names even after `--` ("purge" becomes "purge."). cmux only, with
  the same socket gate as typing.
- **Stop my agents** (Siri / Shortcuts) presses Esc in every working
  session through the same gate as the Stop button, and needs an unlocked
  phone.
- **Diffs** are sent only over the encrypted sessions channel, redacted,
  capped at 48 KiB. Untracked files are included only when they are regular
  text files inside the repository; symlinks are never followed. The page
  itself carries only counts ("Changed 3 files (+12 −4)").
- **Usage capture** edits `~/.claude/settings.json` (`statusLine.command`)
  only when you turn it on, after a backup, and puts the original back
  byte for byte when you turn it off. The wrapper script is 0700 in Page's
  Application Support folder; the saved status line input (model, folder,
  usage numbers, no secrets) is 0600.

## What the Worker stores, and for how long

Everything lives in the Durable Object for your token, on your Cloudflare
account.

| Data | Contents | Retention |
|---|---|---|
| Pending pages | Intervention objects: session id, project name, cwd, kind, context (≤ 4000 chars), reply text and delivery status | Until closed. At most 200. Notification-hook pages expire after 24 h, blocking-hook pages after their wait + 2 min |
| History | Closed pages, including context and `repliedText` | **The last 300 closes, with no time limit** |
| Reply queue | Replies waiting for the Mac (text, action, routing) | 1 h (10 min for closed-page replies), then failed. At most 200 |
| Tombstones | Closed ids, reason, time | 24 h. At most 2000 |
| Devices | APNs device tokens, app version, APNs environment | Until unregistered, rejected by Apple, or pushed out by newer ones (10 max) |
| Meta | History count, last heartbeat (time, session count, battery %, on-AC), `macEverSeen`, `retired` flag | Indefinitely (presence is overwritten) |
| Worker logs (`[observability]`) | Ids, sizes, outcomes, APNs status/reason. Never reply text, context or Mac output | Your Cloudflare account's log retention |

- **Retiring a token** deletes its pending pages, queue and devices. Its
  history, tombstones and meta stay in storage, unreachable through the API
  (every request gets 410), but not erased. To erase everything, delete the
  Worker or its Durable Object data from your Cloudflare account.
- **`reply.injected` output.** The Mac's delivery reports may include a short
  diagnostic `output` (up to 500 characters for Claude replies, 2000 at most).
  The Worker discards it: never stored, logged or forwarded. Only the short
  `detail` string is kept and shown on the phone.

## What Apple sees

Each push goes through Apple's APNs. Alert pushes carry the project name, the
session id, the page kind, the intervention id and **the first 180
characters of the page's context** as the notification body. Silent close
pushes carry only intervention ids and the badge count.

## Redaction

Before context leaves the Mac, both the Mac app (`ContextRedactor`, applied
again at the relay client) and the hook (`page-extract-context.py`) mask
common secret shapes:

- `KEY=value` where the name looks secret;
- bearer, basic and token credentials;
- PEM blocks;
- `user:pass@` in URLs;
- `sk-`, `ghp_`, `github_pat_`, `xox*`, `AKIA` and `AIza` keys.

The hook leaves tool output out of the page by default
(`PAGE_CONTEXT_TOOL_OUTPUT=1` turns it back on). **Redaction is best-effort
pattern matching.** Treat anything an agent shows on screen as something
that can reach your Worker and, in part, Apple.

## Local privileges Page installs

### sudoers (only when you turn on the power helper)

A plain install never uses sudo. The power helper is installed either from the
app (turning on lid-closed-on-battery, or Preferences ▸ Power ▸ Install…, which
shows the standard macOS admin prompt) or by `./install.sh
--enable-power-helpers`. Both write the same `/etc/sudoers.d/claude-power-mode`
(mode 0440, root:wheel; a test keeps the two identical). The fragment is
validated with `visudo -c` before it goes live and the whole sudoers
configuration is re-checked afterwards, rolling back on failure. The app embeds
the fragment in the root script itself and stages it under a dotted name in
`/etc/sudoers.d` (which sudo ignores), so no user-writable file is ever copied
into place. The fragment allows your user, without a password,
**exactly** these commands:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset schedule wake [0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9] [0-9][0-9]\:[0-9][0-9]\:[0-9][0-9]
<you> ALL=(root) NOPASSWD: /usr/bin/pmset schedule cancel wake [0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9] [0-9][0-9]\:[0-9][0-9]\:[0-9][0-9]
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1
```

- The wake rules take exactly one `MM/dd/yyyy HH:mm:ss` argument, with no
  trailing wildcard (`*` would match extra arguments) and no `cancelall`.
- Installs made by earlier Page versions had a broader wildcard rule. Re-run
  `--enable-power-helpers` to replace it.
- `--disable-power-helpers` stops Page, clears `disablesleep`, removes the
  file, clears the flag again and removes the watchdog. `--uninstall` removes
  the file too.

The worst a misuse of these rules can do is schedule wakes, or keep the Mac
from sleeping with the lid closed.

### LaunchAgents (per user, in `~/Library/LaunchAgents`)

| Label | Installed by | What it runs |
|---|---|---|
| `local.Page` | `install.sh` | `/Applications/Page.app` at login. It's restarted after a crash, not after a clean exit |
| `local.Page.sleepguard` | Page, when lid-closed-on-battery is turned on (removed when it's off and the flag is clear) | Every 60 s (and at load), `~/Library/Application Support/ClaudePowerMode/sleepguard.sh` clears `pmset disablesleep` if Page isn't running or hasn't refreshed its `disablesleep.active` marker for 3 minutes |
| `local.ClaudePowerMode.resume.<sessionId>` | Page, per scheduled rate-limit resume (`autoResumeEnabled`) | A 0700 bash script that runs `claude --resume <id> --print "<prompt>"` once after the reset, unless the session is live. It removes itself afterwards. Older builds used `local.Page.resume.*` / `local.PageAI.resume.*`; those are cleaned up |

## Hooks never auto-allow

- The hook prints a decision **only for an explicit answer from your phone**.
  Relay down, token missing or rejected, timeout, an answer that isn't a
  decision, the agent exiting, or you touching the Mac all print nothing, so
  the agent shows its own dialog.
- It never sets `updatedPermissions`, `interrupt` or a blocking `onFailure`.
- The Worker refuses anything but Approve/Deny for pages from the v1 hook,
  whose script treated any other reply as "allow".
- **One opt-in exception:** `PAGE_HOOK_AUTO=allow|deny|ask` makes a legacy
  generic `PreToolUse` install return that decision without asking the phone.
  It's ignored by the `PermissionRequest`, `AskUserQuestion` and
  `ExitPlanMode` handlers that Page installs. Don't set it unless you mean it.
- The hook's temporary payload files (which hold commands and transcript
  excerpts) are 0600 inside a private temp directory deleted on exit.

## cmux

- Phone replies to cmux sessions need cmux in Password mode. Page stores that
  password in your **login Keychain** (service `local.Page.cmux`).
- It passes the password to cmux only through the `CMUX_SOCKET_PASSWORD`
  environment variable of the `cmux` CLI inside cmux.app, never on a command
  line. It does so only after verifying that the CLI's code signature is
  Apple-anchored with cmux's Team ID.
- Inherited `CMUX_*` variables are stripped from every call, and each call
  names its surface explicitly.
- Page reads only `CMUX_SURFACE_ID` and `CMUX_WORKSPACE_ID` from a session's
  environment, and discards everything else, including cmux's capability
  token.

## Headless resumes

When a session has ended, Page may deliver a text reply with
`claude --resume <id> --print` or `codex exec resume`, which runs with **your
default permission settings** for that agent. Turn this off with
`headlessResumeFallbackEnabled: false`. Page refuses a headless resume
whenever there's any sign the session is still running.

## Scope

We're most interested in:

- ways to send replies without the relay token, or to reach another token's
  Durable Object;
- anything that makes the Mac type into a session or terminal other than the
  one the page came from, or press keys the safety rules forbid (for example
  text + Enter while a permission menu is showing; see the Terminal.app
  exception in the README's safety model);
- a hook printing an allow decision without an explicit phone approval;
- token leaks (logs, build artifacts, pushes, the clipboard);
- escalation through the sudoers rules or LaunchAgents beyond what's
  described above;
- TCC scope creep, or unexpected use of the macOS permissions Page requests.

Out of scope:

- attacks that already require running code as your user on the Mac (Page
  assumes the Mac is trusted; such code could read the token file anyway);
- denial of service against your own Worker;
- vulnerabilities in third-party software (Apple frameworks, the Cloudflare
  runtime, Claude Code, Codex, cmux). Please report those upstream.
