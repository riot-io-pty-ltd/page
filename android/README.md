# Page — Android app

The Android phone app for Page, with the same features as the iOS app: an
inbox of pages from your Mac's agents (approve, deny, reply), history and
stats, and live sessions — the list, each session's transcript, its terminal
screen and workflows, typing into a session and stopping it — end-to-end
encrypted with the key from the pairing QR.

Kotlin + Jetpack Compose, minSdk 26 (Android 8.0), target/compile SDK 35. No
Google Play services, no Firebase, no account.

## Build

You need the Android SDK (platform 35, build-tools 35.0.0) and a JDK 17+.
Android Studio's bundled JDK works:

```sh
cd android
echo "sdk.dir=$HOME/Library/Android/sdk" > local.properties   # git-ignored
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
./gradlew :app:assembleDebug test lint
```

- `test` runs the JUnit logic tests (no device needed): wire decoding, reply
  and delivery rules, presence, pairing validation, notification-action
  decisions and URIs, live-session decoding and seq gating, and the
  `SESSIONS-PROTOCOL.md` §2 AES-GCM test vector, byte for byte.
- `gradle.properties` sets `android.builder.sdkDownload=false`, so a missing
  SDK component fails the build instead of downloading.
- Or open `android/` in Android Studio.

## Install on a phone

```sh
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

The debug build is `app.page.android.debug` and installs beside a release
build. For a release APK, `./gradlew :app:assembleRelease` (minified); it is
signed with the debug key so it installs without setup — replace
`signingConfig` in `app/build.gradle.kts` with your own key before sharing
it.

Sideloading notes:

- Enable **Developer options → USB debugging** for `adb`, or copy the APK to
  the phone and allow **Install unknown apps** for the app you open it with.
- Updating keeps your pairing only if the new APK is signed with the same key.
- Nothing is backed up: `allowBackup` is off and every cloud backup and
  device transfer is excluded, so a new phone pairs again.

## Pair

1. On the Mac: Page menu-bar icon → **Pair phone…**.
2. In the app: **Scan pairing code** (CameraX with the on-device ZXing
   decoder), or **Paste pairing code** with the JSON from **Copy pairing
   JSON**. Pasting is the way to pair an emulator.
3. The code is validated exactly as on iOS (version 1, a real token, an
   `https`/`wss` relay that isn't the placeholder), then the relay is probed
   (`/health`, then `/status` with the token) before you confirm.

The relay token, relay URL and live-sessions key are stored encrypted with
an AES-256-GCM key held in the Android Keystore; they never leave the phone.

## How notifications work without push

The relay's push path is APNs-only today (`device.register` needs an
`apnsToken`), so the Android app registers nothing with the relay and uses two
mechanisms instead:

- **While Page is open** it holds the relay WebSocket and posts a
  notification the moment a page opens.
- **Stay connected** (Settings → Connection, off by default) keeps that
  socket open in the background with a foreground service. You get pages
  within seconds; Android shows a low-importance ongoing "Page is staying
  connected" notification with **Turn off**. It restarts after a reboot. It
  uses the `specialUse` foreground-service type (a user-enabled long-lived
  connection to your own relay; `dataSync` is time-limited on Android 15).
  Battery use is small (one idle socket and a ping every 25 s), but aggressive
  OEM battery savers may still stop it — exclude Page from battery
  optimisation if pages arrive late.
- **Otherwise** a WorkManager check runs every 15 minutes (Android's minimum)
  when the phone has a network, and posts any page not notified yet.

All three share one record of what was notified, so a page buzzes once. Page
notifications carry the same actions as iOS: **Approve / Deny / Deny with
instructions** for approvals, **Reply** for questions, **Reply / Carry on**
for idle sessions, **Stop it / Tell it what to do** for a stuck session,
**Send when it resets** for a rate limit, none for forecasts. Every action
needs the phone unlocked first. Actions only trust the page id and action in
the notification's own data URI and Page's record of what it posted, and the
reply is sent by an expedited background job, so a slow network never shows a
false "not sent"; failures become a notice you can tap.

Android 13+ asks for notification permission once, after pairing.

Push can be added later behind `notify/PushProvider.kt` once the relay can
register non-APNs devices.

## Demo mode (debug builds)

**Try the demo** on the pairing screen fills the app with sample pages,
history, sessions, a transcript, a terminal screen, workflows, a diff and
start folders, without a Mac or network. For scripted screenshots:

```sh
adb shell am start -n app.page.android.debug/app.page.android.MainActivity --ez page_demo true \
  [--es page_demo_tab inbox|sessions|history|settings] [--es page_demo_open dev-1] \
  [--es page_demo_session active] [--es page_demo_pane terminal|workflows|changes] \
  [--es page_demo_run wf_5efbb134-a4c] [--ez page_demo_new true] [--ez page_demo_notify true]
```

Release builds contain none of it.

## Layout

```
app/src/main/java/app/page/android/
├── model/    pure Kotlin ports of iOS Models/ (decoding, rules, crypto, sessions); JUnit-tested
├── data/     SecretStore (Keystore), RelayClient (OkHttp REST + WebSocket), SessionStore,
│             PairingStore, AppRouter
├── notify/   notifications, action receiver + ReplyWorker, Stay connected service,
│             15-minute check, boot receiver, PushProvider
└── ui/       theme (Theme.swift), components, pairing, inbox/reply, history/stats,
              sessions (detail, terminal, workflows, changes, new session), settings
app/src/debug/    demo fixtures        app/src/release/  empty demo stub
```

## Differences from iOS

- No push: Stay connected and the 15-minute check stand in (above); no device
  registration with the relay, no badge count.
- WebSocket liveness uses OkHttp's ping/pong timeout (25 s pings; a missed
  pong fails the socket) instead of iOS's own deadline.
- Sheets are full-screen overlays with Android back handling; confirmation
  dialogs are Material dialogs.
- Copy says "phone" where iOS says "iPhone".
