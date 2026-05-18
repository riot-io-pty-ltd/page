Design the **Settings screen** for the iOS app **Page**, focused on **pairing this iPhone with the user's Mac**.

This is the first screen most users see (onboarding) and also the screen they return to to add/remove a Mac. The hero moment is pairing.

# Brand (same as Inbox/Reply/Notification)

- The Pulse mark: glowing dot + radial rings; use it as the visual centrepiece on the empty/onboarding state.
- Dark: bg `#0E1014`, raised `#181B22`, text `#E8EAED`, muted `#8B92A1`. Pulse: cyan→teal `#5EEAD4 → #38BDF8`.
- Light: bg `#FAF8F4`, raised `#FFFFFF`, text `#15171A`, muted `#6B7280`. Pulse: amber→chartreuse `#F2C94C → #C9E265`.
- Typography: Inter Display 28pt bold for screen title (same as Inbox/Reply for cross-screen consistency); SF Pro Text 15pt body; captions 12pt uppercase 0.5 tracking weight 500; SF Mono 13pt for IDs/hostnames.

# Mobile structure (mandatory)

- Status bar 62px.
- Wrapper container, 20px horizontal padding, 24px gap between sections.
- Pill-style bottom tab bar (same as Inbox, **Settings** active). 4 tabs: Inbox / History / Stats / Settings.

# Content (top to bottom, inside the wrapper)

1. **Header**: "Settings" in Inter Display 28pt bold.

2. **Section: Paired Macs**
   - Section header (12pt uppercase muted, 0.5 tracking): "PAIRED MACS"
   - One card listing the user's connected Mac:
     - Raised surface, 14px radius, hairline border, 16px padding.
     - Top row: Mac name "MacBook Pro" (15pt semibold) + a small live status dot on the right: a pulse-mini in the gradient, with caption "Connected · 4ms ping" (12pt muted).
     - Body row: hostname in mono "studio.local" (13pt mono muted) + project count "3 active sessions" (13pt muted).
     - Bottom row: text-button "Unpair" (12pt uppercase, muted red).
   - Below the card, a full-width outlined button (hairline border, 44px tall, 22px radius) with leading "+" icon and label "Pair another Mac".

3. **Section: Account**
   - Section header: "ACCOUNT"
   - Card with:
     - Top: "Alex Morgan" (15pt semibold) + email "alex@example.com" (13pt muted).
     - Caption row: "Member since May 2026" (12pt muted).
   - Below: outlined button "Sign out".

4. **Section: About**
   - Two small rows:
     - "Version" — right-aligned "0.1.0" (13pt mono muted)
     - "Help & feedback" — right-aligned chevron

5. **Bottom**: 24px padding-bottom, then the pill tab bar.

# Pairing-empty state (alternate artboard)

In addition to the populated Settings above, design a **third artboard**: the **Onboarding / first-launch state** where no Mac is paired.

- Same header "Settings" + tab bar.
- Centre of the screen: a large Pulse mark (96x96, glowing intensely — this is the hero brand moment).
- Below the Pulse, headline (Inter Display 22pt semibold): "Pair your Mac"
- Body line (15pt regular, muted): "Open ClaudePowerMode on your Mac, click the menu-bar icon, and scan the QR code shown there with this phone's camera."
- Full-width primary button (filled pulse gradient, 52px tall, 26px radius): "Open camera"
- Below it, text button (muted): "Enter pairing code manually"

# Deliverable

A single `.pen` file with **three artboards side by side**, all 393x852:
- Left: **Settings — Dark** (populated, Mac paired)
- Middle: **Settings — Light** (same, light palette)
- Right: **Onboarding — Dark** (no Mac paired, pairing call to action with hero Pulse)
