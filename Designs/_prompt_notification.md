Design the **lock-screen push notification** for the iOS app **Page** — the on-call interface for AI agents.

This is the very first thing a user sees when an AI pages them. It must be instantly recognisable, communicate urgency without being alarmist, and let the user reply directly from the lock screen without unlocking the phone.

# Brand (same as Inbox/Reply)

- **The Pulse**: glowing dot + 2–3 concentric asymmetric radial rings. Use it as the notification's app-icon glyph (top-left of the banner) — this is the brand cue.
- Dark palette: bg `#0E1014`, raised `#181B22`, text `#E8EAED`, muted `#8B92A1`. Pulse: cyan→teal `#5EEAD4 → #38BDF8`.
- Light palette: bg `#FAF8F4`, raised `#FFFFFF`, text `#15171A`, muted `#6B7280`. Pulse: amber→chartreuse `#F2C94C → #C9E265`.
- Typography: SF Pro Text everywhere (system notification typography). Headline 15pt semibold; body 14pt regular; meta 13pt regular muted.

# Composition

iPhone lock-screen, iPhone 15 Pro size (393x852). The notification sits in the **upper middle third** of the lock screen. Below it, show the lock-screen clock + date in standard iOS styling so the context is unambiguous.

# Wallpaper

For dark variant: a soft radial gradient from `#10131A` (centre, slightly lighter) to `#070809` (edges). Subtle, blurred, no imagery. Just enough texture to read as "wallpaper, not solid colour".

For light variant: a soft radial gradient from `#FFFFFF` (centre) to `#EDE9E0` (edges).

# Status bar

Standard iOS, 62px, OS-controlled, time `9:41`. Above the lock-screen content area.

# Lock-screen elements (top to bottom, before the notification)

1. Status bar (above).
2. Lock-screen time: huge, very thin, Inter Display or system-thin font, centred. `9:41` in dark, same in light.
3. Date line under it (small, muted): `Monday · May 12`.
4. ~80px of breathing space.

# The notification card

A single expanded notification card, 353px wide (centred with 20px horizontal margin), 22px corner radius, raised surface colour with a subtle blur/glass effect (1px hairline border).

Top row of the card:
- Left: 28x28 Pulse mark (active state — bright dot + rings, in pulse gradient).
- Right of that: app name "Page" (13pt semibold) + meta "now" (13pt muted) on the same baseline.

Below the top row, 8px gap:
- Title (15pt semibold): "acme-web paged you"
- Body (14pt regular): "Permission needed: `npm install bcrypt@5.1.1`"

Below body, 12px gap, divider hairline, then action row:
- Three quick-action buttons stacked vertically inside the expanded notification: **Approve** (filled pulse gradient), **Deny** (outlined hairline, muted red text), **Reply…** (outlined hairline, neutral). Each 44px tall, full width, separated by 1px hairlines (iOS expanded-notification style).

Below the action row: a single-line text input ghost (only visible in the dark artboard for variety) showing what the inline quick-reply field looks like when expanded: rounded full-width input with placeholder "Type a reply…" and a circular pulse-gradient send button on the right.

# Below the notification

Lock-screen "swipe up to unlock" hint at the bottom: a small horizontal pill (134x5px) in muted colour, centred, 34px above the bottom safe area.

# Deliverable

A single `.pen` file with **two artboards side by side**, both 393x852:
- Left: **Notification — Dark**
- Right: **Notification — Light**

The Pulse mark on the notification card should look genuinely glowing — slight outer-glow halo behind the rings, using the pulse gradient. This is the brand moment of contact.
