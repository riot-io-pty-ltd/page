Design the **Inbox screen** for a new iOS app called **Page** — the on-call interface for AI agents (Claude Code, Codex, Cursor, etc.). When any agent needs a human decision mid-task, the user gets paged on their phone, opens the app, and sees the Inbox.

# Visual direction (strict — follow exactly)

- **Brand mark: "The Pulse"** — a single glowing dot with two-to-three concentric radial rings expanding outward, slightly asymmetric. This is the entire visual identity. Use it as the logo, the empty-state illustration, and any decorative element. Do not invent additional iconography for branding.
- **Palette**:
  - Dark (primary): bg `#0E1014`, raised `#181B22`, text `#E8EAED`, muted `#8B92A1`, border `rgba(232,234,237,0.08)`. **Pulse accent**: cyan→teal gradient `#5EEAD4 → #38BDF8`.
  - Light: bg `#FAF8F4`, raised `#FFFFFF`, text `#15171A`, muted `#6B7280`, border `#E5E2DC`. **Pulse accent**: amber→chartreuse gradient `#F2C94C → #C9E265`.
  - **Pulse gradient is the only colour besides neutrals.** No purple, no Anthropic-coral, no other gradient.
  - Muted red `#E06464` permitted only for destructive cues (Deny / urgent badges) — use sparingly.
- **Typography**: Inter Display for the app title (28pt bold, tight tracking), SF Pro Text for body (15pt regular), SF Mono for any code/session-ID snippets, captions 12pt uppercase letter-spacing 0.5 weight 500.
- **Vibe**: premium, calm, distinctive. Not generic AI app, not iOS-default, not Anthropic-branded. Confident editorial typography + restrained palette + the Pulse as the one piece of personality.

# Mobile structure (mandatory)

- Status bar at top (62px, OS-controlled, do not redraw).
- One vertical wrapper container with 20px horizontal padding, 24px gap between major sections.
- Pill-style bottom tab bar (62px height, 36px corner radius, 4 tabs: **Inbox** (active), **History**, **Stats**, **Settings**, each with 18px icon + 10px uppercase label).

# Inbox content (top to bottom, inside the wrapper)

1. **Header row**
   - Left: the word "Page" in 28pt Inter Display bold (this is the app title — use the same typographic treatment that will appear on every screen).
   - Right: a small Pulse mark (24x24, the brand mark in miniature, pulse gradient).
2. **Status line** (small, muted): either "3 pages waiting" or "All quiet" depending on state.
3. **List of intervention cards** (vertical stack, 12px gap between cards). Each card:
   - Background: raised surface, 14px corner radius, 1px hairline border, 16px padding.
   - Top row: project name (mono, 13pt) · session name (15pt semibold) · kind chip (small pill: "permission" / "plan" / "question").
   - Body: last context line (15pt, max 2 lines, truncated with ellipsis).
   - Bottom row: time-since-paged in muted caption ("Paged 12s ago", "Paged 4m ago") + the Pulse mark on the right side, animated/pulsing for the most-recently-arrived card.
   - Most-urgent card (longest-waiting OR permission_request kind) gets a thin pulse-gradient ring along its left edge to indicate priority.
4. Sufficient bottom padding (24px) below the last card before the tab bar.

# Sample data to populate (use these exact values)

- Card 1 (most urgent, top): project `acme-web` · session "Auth flow" · kind `permission` · context "Bash command needs approval:  `npm install bcrypt@5.1.1`" · "Paged 12s ago"
- Card 2: project `nova-firmware` · session "Modem provisioning" · kind `question` · context "Should I retry the cert download at 9600 baud instead of 38400?" · "Paged 2m ago"
- Card 3: project `helix-mobile` · session "Onboarding redesign" · kind `plan` · context "4-step plan for the Reply screen is ready — review before implementation?" · "Paged 5m ago"

# Deliverable

A single .pen file containing **two artboards side by side**:
- Left artboard: **Inbox — Dark** (populated with the three sample cards above)
- Right artboard: **Inbox — Light** (same content, light palette)

Both artboards: iPhone 15 Pro size (393x852 logical px, design at 1x).

Make the Pulse mark on the top-right + the priority ring on Card 1 look polished — those are the brand moments.
