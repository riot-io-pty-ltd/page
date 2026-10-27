# Page — iOS app

The on-call interface for AI coding agents. When a Claude Code or Codex
session on your Mac needs you (an approval, a question, an idle session, a
rate limit), the Page menu-bar app sends a page through your Cloudflare
Worker relay to this app. You answer from the lock screen or the app, and
the Mac types your reply into the live session.

## Build

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen). Edit `project.yml`, not
`Page.xcodeproj`, and regenerate after adding or removing files:

```sh
brew install xcodegen
cd iOS
xcodegen generate
open Page.xcodeproj
```

The app compiles Metal shaders (the aurora, the pulse's light and the glass
rim in `Page/Design/NightWatch/Shaders`), so Xcode needs its Metal Toolchain
component: `xcodebuild -downloadComponent MetalToolchain` once per Mac or CI
image. The widget and the macOS proxy renderer don't use it.

Simulator builds need no Apple account. The same command CI runs:

```sh
xcodebuild -project Page.xcodeproj -scheme Page -sdk iphonesimulator \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
```

### Running on your iPhone

Per-developer settings live in `Config/Local.xcconfig`, which is git-ignored.
`Config/Page.xcconfig` includes it.

1. `cp Config/Local.xcconfig.example Config/Local.xcconfig`
2. Set `DEVELOPMENT_TEAM` to your team id.
3. If the bundle id `app.page.Page` belongs to another team, set
   `PAGE_BUNDLE_ID` to your own. Use the same value as `APNS_BUNDLE_ID` in
   `Cloudflare/wrangler.toml`.
4. Run `xcodegen generate`, then build to your device from Xcode.

### Push notifications need a paid Apple Developer Program team

APNs needs the `aps-environment` entitlement. Free Apple IDs (Personal
Teams) can't get it, so the default entitlements file
(`Page/Page.entitlements`) leaves it out and the app builds for everyone.
Without push, pages only arrive while the app is open. Settings → Push and
an Inbox banner tell you when that's the case.

With a paid team:

1. In `Config/Local.xcconfig`, set
   `PAGE_ENTITLEMENTS = Page/Page-Push.entitlements`.
2. Create an APNs auth key (`.p8`) and set the Worker secrets
   (`APNS_KEY_P8`, `APNS_KEY_ID`, `APNS_TEAM_ID`). See `Cloudflare/README.md`.
3. Run `xcodegen generate` and rebuild.

The app tells the relay which APNs gateway its device token belongs to
(`apnsEnv`: `development` for Xcode-signed builds, `production` for
TestFlight and the App Store). It reads this from the embedded provisioning
profile, and falls back to the build configuration when there is none.

### Versioning

`MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` are the
only place to bump the version. `Info.plist` reads both, and Settings → About
shows them.

## Pairing

There are no accounts. The phone and the Mac share one relay token.

1. On the Mac, click the Page menu-bar icon → **Pair phone…**.
2. In the app, tap **Scan pairing code**, or **Enter pairing code manually**
   and paste the JSON from **Copy pairing JSON**. The Simulator has no camera,
   so use the manual option there.
3. The app checks the code before saving it:
   - It must be version 1.
   - The relay must be `https://` or `wss://`.
   - The relay must not still be the example host `your-page-relay.workers.dev`.
   - The relay's `/health` must answer as a Page relay.
   - The relay must accept the token on `/status`. Older Workers without
     `/status` are checked on `/interventions` instead.
4. You confirm the Mac name and relay host, and the app saves the pairing.

Unpairing (Settings → Unpair) closes the live connection and asks the relay
to forget this phone's push token (`POST /device/unregister`). It also clears
the inbox, history, delivered notifications and the live-sessions key.

## How it works

- **Credentials.** The relay URL and token are stored in the Keychain with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. They never leave the
  device in backups. Every request reads them straight from the Keychain, so
  lock-screen actions work even when iOS launches the app in the background.
  Older builds kept a plaintext copy in UserDefaults; it's moved into the
  Keychain once and then deleted.
- **Live updates.** A WebSocket to `/ws` receives these frames:
  `intervention.opened` / `intervention.closed`, `heartbeat`, `mac.status`,
  `reply.result` and `relay.retired`.
  - Each callback is checked against the current socket, so stale sockets
    are ignored.
  - The socket sends a ping every 25s. If no frame or pong has arrived for
    40s (a half-open connection), or a ping fails, it reconnects with
    exponential backoff plus jitter.
  - On every (re)connect, and whenever the app becomes active, the app
    refetches the inbox and `/status`.
  - The socket closes when the app goes to the background; APNs takes over.
- **Mac presence.** Comes from `GET /status`, `mac.status` frames and
  heartbeats. The Inbox warns when the Mac is offline or has stopped sending
  heartbeats. If the relay reports (`macEverSeen: false`) that no Mac has
  ever connected with this pairing, the Inbox says so and offers Re-pair, and
  the pairing screen warns before you pair with such a code. After a long
  offline spell the offline banner also offers Re-pair, because a token
  regenerated on the Mac looks exactly like an offline Mac to the phone.
  Older Workers only send heartbeats, so presence there comes from heartbeat
  freshness alone.
- **Replaced pairings.** When you regenerate the token on your Mac, the Mac
  retires the old one on the relay. From then on the relay answers every
  request on the old token with `410 {"error":"token_retired","why":…}` and
  sends a `relay.retired` frame to open sockets. Either one makes the phone
  forget the pairing: it clears the inbox, history and banners and goes back
  to the pairing screen, which shows the relay's explanation. A refused
  WebSocket upgrade, or a socket closed with code 4410 / reason
  `token_retired`, is confirmed through `/status` first, because neither
  carries a readable body. A plain 410 from `/reply` (the page closed)
  is never treated as a replaced pairing. Scanning an old code that was
  replaced says so on the pairing screen.
- **Notifications.** Each page kind has its own category:
  - `PAGE_APPROVAL`: Approve, Deny, Deny with instructions
  - `PAGE_INPUT`: Reply
  - `PAGE_IDLE`: Reply, Carry on
  - `PAGE_INFO`: no actions
  - `PAGE`: the legacy category, still registered for older Workers. Its
    Approve and Deny are ignored for pages that aren't approvals.

  Actions run in the background without opening the app. Anything that
  types into your Mac requires Face ID or your passcode first
  (`.authenticationRequired`).
  - Tapping the notification itself only opens that page. It never sends
    anything.
  - If a lock-screen reply fails, you get a local notification saying why.
  - When pages close, a silent push (every id in `interventionClosedIds`,
    or the older single `interventionClosedId`) or a WebSocket close removes
    their banners. An alert's own `interventionClosedIds` (pages it
    superseded) are cleared too whenever the app runs for that alert. There
    is no Notification Service Extension, so a backgrounded app relies on the
    relay's close push and on the cleanup at the next foreground refresh.
  - The badge is the number of pending pages: the relay sets `aps.badge` on
    each alert, and the app recounts from a freshly fetched inbox whenever
    it opens or a close push wakes it. It never recounts from a list that
    went stale while suspended; if that refetch fails, the badge keeps its
    last value until the next successful one.
- **Replies.** Approve, Deny and Carry on are sent with empty text, so a
  half-typed note can never override the button you tapped. The reply screen
  then shows delivery progress: sending, sent or queued (Mac offline),
  delivered (with the Mac's detail), or failed (with Retry). A sent reply
  the Mac hasn't confirmed keeps showing "waiting for your Mac" for the
  relay's 20-minute ack window, during which the relay would refuse a second
  answer; only after that (or a reported failure) can you answer again.
  Relays that predate delivery reporting re-open input after a minute. If
  the page is answered or resolved elsewhere while you're looking at it, the
  screen says so and closes itself; a close whose reason didn't reach the
  phone is looked up in History before saying how it was resolved.
  Pages from an older blocking hook (`hookBlocking`) can only take Approve
  or Deny, so they show no text field; if the relay refuses a reply (422),
  the screen shows the relay's `why` text.
- **Deep links.** `page://intervention/<id>` opens that page's reply screen.

## Sessions tab

The Sessions tab lists every live agent session on your Mac (Claude Code,
Codex, and other terminal agents), grouped **Needs you**, **Working** and
**Idle**. Tap a session to see its recent transcript and type into it at any
time, not only when it pages you. The wire contract is
`docs/SESSIONS-PROTOCOL.md`.

- **End-to-end encrypted.** The pairing QR carries a 32-byte session key
  (`sk`). It is stored in the Keychain beside the relay token and deleted on
  unpair or when the pairing is retired. Lists, transcripts and your typed
  text are sealed with AES-GCM under per-direction keys derived from it, so
  the relay only forwards opaque envelopes. Nothing is stored on the relay.
- **Live only while you look.** The Mac sends the list while the app's
  socket is open, and a transcript only for the session on screen (the
  detail screen re-sends `watch` every 30 seconds).
- **Typing.** Each message shows its delivery state: Sending, then Typed,
  Queued (the agent reads it after its current step) or Refused with the
  reason and what to do. With no answer from the Mac within 20 seconds it
  says so. The Mac decides what is safe to type: it refuses while a prompt is
  on screen (use **Open page**), while there's a half-typed draft in the
  terminal, or where it can't type at all, in which case the composer is
  replaced by the reason.
- **Stop** appears while a session is working and its terminal supports it.
  After a confirmation it presses Esc in the session.
- The reply screen shows **Open session** when the page's session is live.

### Re-pairing for live sessions

Pairings made before live sessions existed, or with an older Page on the
Mac, have no session key. The Sessions tab then says **Re-pair with your Mac
to see live sessions**. Update Page on the Mac, unpair in Settings (or tap
**Re-pair…**), then on the Mac open **Pair phone…** and scan the new code.
The inbox keeps working meanwhile.

The tab also tells you when the relay needs updating (its `/status` lacks
`sessions-v1`), when the Mac is offline, when the Mac is online but sends no
list within 5 seconds (update Page on the Mac), and when the two clocks
disagree by more than 10 minutes.

## Files

```
Config/
  Page.xcconfig                Shared settings; includes Local.xcconfig
  Local.xcconfig.example       Template for team id / bundle id / push
Page/
  PageApp.swift                App entry, environment wiring, scene phase, deep links
  PageAppDelegate.swift        Launch-time notification setup, APNs callbacks, close pushes
  Info.plist                   Versions from build settings, camera usage, page:// scheme
  Page.entitlements            Default (no push) entitlements
  Page-Push.entitlements       aps-environment, for paid teams
  Design/NightWatch/          The Night Watch design system: tokens (NWTheme), glass, controls, every screen
  Models/                      Foundation-only: Intervention + lenient decoding, pairing
                               validation, ordering, presence, stats, notification decisions,
                               live sessions (decoding, crypto, delivery, availability)
  Services/
    APIClient.swift            REST + WebSocket client, delivery tracking
    SessionStore.swift         Live sessions: decrypts updates, sends commands
    NotificationService.swift  Permission, categories, APNs registration, action handling
    PairingStore.swift         Pair / unpair
    KeychainStore.swift        Keychain storage + RelayCredentials
    AppRouter.swift            Tab + "open this intervention" state
    DevBypass.swift            DEBUG-only mock data ("Skip pairing (DEV)")
  Views/                       Pair, Inbox, Sessions, Session detail, Reply, History (with
                               Stats), Settings, shared components
Tests/
  LogicTests.swift             Tests for Page/Models
  run-logic-tests.sh           Builds and runs them with swiftc
```

## Testing the pure logic

The code in `Page/Models` only depends on Foundation (and CryptoKit for the
sessions envelope). It covers wire decoding, ordering, pairing validation,
notification-action decisions, presence, stats and live sessions, including
the protocol's crypto test vector. Its tests run without a simulator:

```sh
./Tests/run-logic-tests.sh
```

## Development shortcuts

Debug builds show **Skip pairing (DEV)** on the pairing screen. It loads mock
pages and live sessions, and simulates replies and typed messages in memory.
The `-PageDevPairing` launch argument does the same; add `-PageDevSession
active` to open a mock session's detail screen. It never writes credentials or
touches the network, and it isn't compiled into Release builds.

## Not supported yet

- More than one Mac per phone.
- End-to-end encryption of page contents. Pages pass through your Worker and,
  for push notifications, through Apple's APNs. (Live sessions are
  end-to-end encrypted.)
