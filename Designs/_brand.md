# Page — Brand & Style Spec

Working name: **Page**.
One-liner: *the on-call interface for AI agents.*

When any AI coding agent (Claude Code, Codex, Cursor, Gemini CLI, etc.) needs a
human decision mid-task, it sends a **page**. The app is where you receive,
triage, and respond to pages from your phone.

This is a brand-new category product. Designs must feel unique, premium, and
distinctive — not a generic AI tool, not Anthropic-coral, not OpenAI-green.

---

## Brand mark: The Pulse

The single visual signature across the entire product.

A glowing dot at the centre with **two or three concentric radial rings**
expanding outward, slightly asymmetric so it feels alive. Think: a beacon
signal, a sonar ping, an on-call pager going off.

States:
- **Resting** (no pages): the dot is solid, rings are faint
- **New page**: dot brightens, rings ripple outward
- **Replied**: rings contract back into the dot

The mark replaces icons in many places (logo, empty states, app icon, splash).

---

## Palette

**Light surface** (warm paper):
- bg: `#FAF8F4`
- bg raised: `#FFFFFF`
- text: `#15171A`
- text muted: `#6B7280`
- border / hairline: `#E5E2DC`
- **pulse accent: amber → chartreuse gradient** `#F2C94C → #C9E265`

**Dark surface** (deep ink):
- bg: `#0E1014`
- bg raised: `#181B22`
- text: `#E8EAED`
- text muted: `#8B92A1`
- border / hairline: `rgba(232,234,237,0.08)`
- **pulse accent: cyan → teal gradient** `#5EEAD4 → #38BDF8`

The pulse gradient is the only colour besides neutrals. No additional accents.
A muted red `#E06464` is permitted only for destructive confirmations (e.g. "Deny" button), used sparingly.

---

## Typography

- **Display / headings**: Inter Display (fallback: SF Pro Display) — bold, tight tracking
- **Body / UI**: SF Pro Text
- **Mono** (for transcript snippets, code, session IDs): SF Mono
- Title sizes must be identical across every screen (per platform guidelines)

Heading scale:
- App title: 28pt, weight 700, tight tracking
- Section title: 17pt, weight 600
- Card title: 15pt, weight 600
- Body: 15pt, weight 400
- Caption / meta: 12pt, weight 500, uppercase, letter-spacing 0.5

---

## Voice

The product talks like a calm dispatcher, not a chirpy assistant.

- "3 pages waiting" — not "You have 3 notifications!"
- "All quiet" — empty state
- "Paged 12s ago" — time format
- "Approve · Deny · Carry on" — concrete actions

---

## Screen list (this spec covers all)

1. **Inbox** — list of pending pages (priority order)
2. **Reply** — context-first response screen
3. **History** — resolved pages (collapsed log)
4. **Settings** — pair Mac, manage devices, log

The Inbox + Reply screens are the heart of the product.
