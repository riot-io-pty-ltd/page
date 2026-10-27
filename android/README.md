# Page — Android app

The Android phone app for Page, in the v4 "Night Watch" design and with the same behaviour and trust model as
the iOS app. **Now** is the ranked stream of what needs you (Decide, Look, Review), what is working (In flight)
and what has settled; **Sky** is the fleet as constellations, or as Lanes. A card opens the **Decision sheet**
(reversibility chip, exactly what will be typed and where, swipe / tap / hold-plus-fingerprint by how reversible
it is); a session opens as a **Room** (Story, Screen, Changes, Workflows, answering the terminal's questions,
Stop as a 0.6 s hold). **Dispatch** starts new work, the **Tower** holds every setting, and live sessions are
end-to-end encrypted with the key from the pairing QR.

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
2. In the app: **Pair with your Mac** opens the scanner (CameraX with the on-device ZXing decoder), or
   **Paste a pairing link instead** with the JSON from **Copy pairing JSON**. Pasting is the way to pair an
   emulator.
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
- **Stay connected** (Tower → Attention, off by default) keeps that
  socket open in the background with a foreground service. You get pages
  within seconds; Android shows a low-importance ongoing live notification ("2 need you · 5 working", the
  runway drawn under it) with **Turn off**. It restarts after a reboot. It
  uses the `specialUse` foreground-service type (a user-enabled long-lived
  connection to your own relay; `dataSync` is time-limited on Android 15).
  Battery use is small (one idle socket and a ping every 25 s), but aggressive
  OEM battery savers may still stop it — exclude Page from battery
  optimisation if pages arrive late.
- **Otherwise** a WorkManager check runs every 15 minutes (Android's minimum)
  when the phone has a network, and posts any page not notified yet.

All three share one record of what was notified, so a page buzzes once. Page
notifications carry the same actions as iOS, in words: **Approve / Deny / Tell it…** for an *undoable*
approval, and **Open to decide / Deny / Tell it…** for anything else (a Considered action needs a tap and an
Irreversible one a hold plus your fingerprint, which a notification cannot give, so it opens the Decision
sheet); **Answer…** for questions, **Looks good / Steer…** for a finished turn, **Stop it / Steer…** for a stuck
session, **Send after reset** for a rate limit, none for forecasts. Whether Approve is offered is decided from
the page's full text when the notification is posted, and checked again from the live inbox when it is tapped.
Every action needs the phone unlocked first. Actions only trust the page id and action in
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
adb shell am start -S -W -n app.page.android.debug/app.page.android.MainActivity --ez page_demo true \
  --es page_render <screen> [--es page_glow off|subtle|full] [--ef page_time 2.0]
```

`page_render` names one of the fixture screens in `Demo.screens` (now, sky, decision-*, room-*, ask-*, tower-*,
motion-*, gallery, glow-compare and so on); it pins the clock and the aurora so a screen is identical every time.
`tools/screens.sh [out-dir] [--glow ...] [--font-scale 1.3] [-- screen ...]` captures all of them on the PagePixel
emulator (default out-dir `build/screens`).

**The signature motions.** On a `motion-*` screen `page_time` is the seconds into that motion (the pulse's ripples,
the exhale, Final approach, a receipt-thread stage, the hold ring's burst, dusk, dawn, the Brief's sunrise), the
same screens and default moments as iOS's `-NWRender motion-* -NWTime`. `tools/render-motion.sh [out-dir]
[--canvas [--noblur]] [--reduce]` captures iOS's frame list and tiles one contact sheet per motion, like board 07
(default out-dir `build/motion`); `--canvas` draws the Canvas fallbacks a phone below Android 13 gets instead of
the AGSL shaders, `--noblur` the aurora as a phone below Android 12 draws it, `--reduce` turns on Remove animations
for the run. `tools/live-motion.sh [out-dir] [--reduce]` records the scripted live demo (`--ez page_live_motion
true`: an approve, an arrival, the exhale, dusk, dawn) with `screenrecord`, to see the motions on their real,
unpinned paths, and cuts it into filmstrips (`tools/live-motion-sheets.py`).

Release builds contain none of it.

## Home screen and Quick Settings

- **Quick Settings tile** ("Page"): shows how many need you, lit amber while something does, and opens Now.
  It never acts on its own.
- **Home-screen widget** (Glance): "2 need you" / "All quiet" / "Mac offline", what is working, the Mac and its
  power, and the runway on the wide size. Counts and times only: never a project name or a command.

Both read a small non-secret snapshot (`StatusSnapshot`) the app keeps up to date and the 15-minute check
refreshes while the app is closed, so they can lag the app by that long and no more.

## Appearance and accessibility

Night Watch is dark only. The Card glow (Tower → Appearance: Off, Subtle, Full; default Off) is the only light on
the glass. System **Remove animations** stops the aurora, the pulse and every one-shot; the system font size is
followed everywhere (the Horizon and Sky's labels cap it so fixed-size sky layout never breaks; Lanes is the
list that scales fully). Every gesture has a named TalkBack action (Approve, Deny, Open, Steer, Stop, Stop all
agents), so nothing depends on a swipe or a hold.

## Layout

```
app/src/main/java/app/page/android/
├── model/    pure Kotlin ports of iOS Models/ (decoding, rules, crypto, sessions); JUnit-tested
├── data/     SecretStore (Keystore), RelayClient (OkHttp REST + WebSocket), SessionStore,
│             PairingStore, AppRouter, NowStore / ActionCoordinator / StopCoordinator,
│             StatusSnapshot (widget + tile)
├── notify/   notifications (+ the live one), action receiver + ReplyWorker, Stay connected service,
│             15-minute check, boot receiver, PushProvider
├── widget/   Glance home-screen widget, Quick Settings tile
└── ui/nw/    Night Watch: theme, components, shell, now, decision, room, sky, tower, dispatch,
              onboarding, history (ui/theme + the first-generation screens in ui/inbox, ui/sessions,
              ui/settings, ui/history, ui/components are retired and unreferenced: delete them)
app/src/debug/    demo fixtures        app/src/release/  empty demo stub
```

## Differences from iOS

- No push: Stay connected and the 15-minute check stand in (above); no device
  registration with the relay, no badge count.
- WebSocket liveness uses OkHttp's ping/pong timeout (25 s pings; a missed
  pong fails the socket) instead of iOS's own deadline.
- Sheets are Compose overlays with Android back handling (one at a time); confirmation dialogs are Material
  dialogs in the Night Watch colours. The pulse's hold asks for the fingerprint, face or screen lock (BiometricPrompt).
- One Mac per pairing (no saved-Macs list), and no Siri / Live Activity; the Quick Settings tile and the
  Glance widget stand in.
- Copy says "phone" where iOS says "iPhone".
