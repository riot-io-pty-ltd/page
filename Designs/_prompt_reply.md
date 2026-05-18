Design the **Reply screen** for the iOS app **Page** — the on-call interface for AI agents.

This is the screen you reach by tapping a card in the Inbox or by tapping a push notification. It is **context-first**: you read what the AI is asking, then respond.

# Brand (strict — same as Inbox)

- **The Pulse**: glowing dot + 2–3 concentric asymmetric radial rings, expanding outward. Use this brand mark for the back-button affordance and the active-state of the send button.
- **Dark palette**: bg `#0E1014`, raised `#181B22`, text `#E8EAED`, muted `#8B92A1`, border `rgba(232,234,237,0.08)`. Pulse accent: cyan→teal gradient `#5EEAD4 → #38BDF8`.
- **Light palette**: bg `#FAF8F4`, raised `#FFFFFF`, text `#15171A`, muted `#6B7280`, border `#E5E2DC`. Pulse accent: amber→chartreuse `#F2C94C → #C9E265`.
- Muted red `#E06464` only for the destructive "Deny" button.
- **Typography**: Inter Display 28pt bold for screen title; SF Pro Text 15pt regular for body; SF Mono 13pt for code/transcript; captions 12pt uppercase 0.5 tracking weight 500.

# Mobile structure (mandatory)

- Status bar 62px (OS-controlled).
- Top app bar with back chevron (left) + project name (centred, mono 13pt) + session name (centred under it, 15pt semibold). 56px tall, hairline divider at bottom.
- One vertical wrapper container, 20px horizontal padding, 20px gap.
- **No bottom tab bar** on this screen — it's a focused task view. Instead, the action zone is anchored just above the keyboard.

# Reply content (top to bottom, inside the wrapper)

1. **Context block** (most of the screen, ~60% of vertical space, scrollable):
   - Kind chip at top ("PERMISSION REQUEST" / "PLAN APPROVAL" / "QUESTION") with pulse-gradient stroke.
   - Header text (Inter Display 22pt semibold) summarizing what's being asked:
     > "Run this command?"
   - The last 4–6 lines of transcript context, presented as alternating user/assistant blocks. Assistant messages: raised surface with hairline border, 12px radius, 14px padding, mono font for any code, regular font for prose. User messages: no background, muted text colour.
   - For the populated state, show this context (verbatim):
     - assistant block 1 (prose): "I need to install bcrypt to hash passwords for the new login flow. This will add it to dependencies and run a build hook."
     - assistant block 2 (mono code, in a darker inset): `npm install bcrypt@5.1.1`
     - small footnote line (muted, 12pt): "Working directory: ~/projects/acme-web"

2. **Quick actions row** (just above the text field):
   - Three pill buttons: **Approve** (filled with pulse gradient, dark text), **Deny** (filled with muted red), **Carry on** (outlined, hairline border). 44px tall, 22px radius. Equal width, 8px gap.

3. **Text field** (anchored bottom, above keyboard):
   - Rounded raised surface, 24px radius, 12px padding, hairline border.
   - Placeholder: "Or type a reply…" (muted text colour)
   - Right side: a circular send button (44x44), Pulse gradient when text field has content, otherwise muted. Icon: an upward arrow.
   - Below the field, a tiny meta line (12pt muted): "Reply goes to session 7f3a9c2b · injected via tmux"

# Deliverable

A single `.pen` file with **two artboards side by side**, both 393x852 (iPhone 15 Pro):
- Left: **Reply — Dark** (populated with the sample data above)
- Right: **Reply — Light** (same content, light palette)

Make the **kind chip + header text** + the **action row** look polished — those are the moments the user sees most.
