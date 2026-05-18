# Page — iOS app

The on-call interface for AI agents. Companion to ClaudePowerMode running on your Mac.

## Open in Xcode

This folder is a **Swift source tree**, not yet an `.xcodeproj`. To bring it up:

1. Open Xcode → **File → New → Project…** → iOS → App.
2. Name the product **Page**, organization identifier `app.page` (or whatever you prefer — it has to match your Apple Developer team).
3. Interface: **SwiftUI**. Language: **Swift**. Storage: **None**.
4. Once Xcode creates the project, **close it**, then **delete** the placeholder `Page/` group it generated.
5. In Finder, drag this entire `Page/` directory into the Xcode project navigator, choosing **"Copy items if needed: OFF"**, "Create groups", and add to the **Page** target.
6. Set the `Info.plist` and `Page.entitlements` as the project's plist/entitlements (Build Settings → Packaging → Info.plist File / Code Signing Entitlements).
7. Capabilities to enable in the target's *Signing & Capabilities* tab:
   - **Sign In with Apple**
   - **Push Notifications**
   - **Keychain Sharing** (with group `app.page`)
8. Minimum deployment target: **iOS 17.0**.

## Configure your Cloudflare Worker URL

The default placeholder is `https://page-relay.example.workers.dev`. Once your Worker is deployed:

- Update `googleSignInURL` in `Services/AuthStore.swift`.
- Update the default `relayURL` in `Models/Intervention.swift` if you bake it in, or just rely on the QR-pair flow to inject it at runtime (recommended — keeps the app vendor-neutral).

## What's in here

```
Page/
  PageApp.swift                  App entry, environment wiring, URL callbacks
  PageAppDelegate.swift          UIKit adaptor for APNs token registration
  Info.plist                     Capabilities + URL schemes
  Page.entitlements              Sign in with Apple + push notifications

  Design/
    Theme.swift                  Palette + typography + spacing
    PulseMark.swift              The animated brand mark (used everywhere)
    PillTabBar.swift             Bottom navigation

  Models/
    Intervention.swift           Intervention, PairedMac, AppUser, PairingPayload

  Services/
    AuthStore.swift              Sign in with Apple (+ Google placeholder)
    PairingStore.swift           QR pairing + relay URL/token storage
    APIClient.swift              REST + WebSocket against Cloudflare Worker
    NotificationService.swift    APNs registration + reply categories
    KeychainStore.swift          Generic secure storage

  Views/
    WelcomeView.swift            First launch: hero Pulse + auth buttons
    PairMacView.swift            QR scanner via AVFoundation
    InboxView.swift              List of pending pages
    ReplyView.swift              Context-first reply screen
    SettingsView.swift           Paired Mac, Account, About
                                 (HistoryView + StatsView placeholders)
```

## Status of this implementation

✅ **Done in this pass:**
- Visual design system (matches Pencil mockups)
- All 4 primary screens (Welcome, PairMac, Inbox, Reply, Settings)
- Sign in with Apple flow
- QR scanner + pairing
- REST + WebSocket client (`APIClient`)
- APNs registration + reply notification categories
- Keychain storage of auth/pairing tokens

🟡 **Stubs / placeholders (need your Cloudflare Worker first):**
- Google sign-in goes via a backend OAuth start endpoint (you'll need to implement
  `/auth/google/start` and `/auth/google/callback` in the Worker)
- Default Worker URL is `page-relay.example.workers.dev` — replace with yours
- `History` and `Stats` tabs are placeholder views

⚪ **Out of scope for v0.1:**
- Multi-Mac support (single Mac assumed; add a Macs list when you want this)
- E2E encryption of intervention payloads (added later if needed)
