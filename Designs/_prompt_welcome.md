Design the **Welcome / Sign-in screen** for the iOS app **Page** — the on-call interface for AI agents.

This is the **very first screen** a user sees on launching the app for the first time. Hero moment for the brand. After auth, they go to the Pair-your-Mac screen.

# Brand (same as the other screens — strict)

- **The Pulse**: glowing dot + 2–3 concentric asymmetric radial rings. On this screen it's the **hero**, presented at large scale (120–140px) with a soft outer glow halo. This is the most prominent appearance of the brand mark anywhere in the app.
- **Dark palette**: bg `#0E1014`, raised `#181B22`, text `#E8EAED`, muted `#8B92A1`. Pulse accent: cyan→teal gradient `#5EEAD4 → #38BDF8`.
- **Light palette**: bg `#FAF8F4`, raised `#FFFFFF`, text `#15171A`, muted `#6B7280`. Pulse accent: amber→chartreuse gradient `#F2C94C → #C9E265`.
- **Typography**: Inter Display 36pt bold for the app name; 17pt regular for the tagline; 15pt body; 12pt uppercase muted for legal microcopy.

# Mobile structure

- Status bar 62px (OS-controlled).
- One vertical wrapper container, 24px horizontal padding, generous vertical spacing.
- **No tab bar** — this is a pre-auth screen.

# Composition (top to bottom inside the wrapper)

1. **~60px** of top spacing under the status bar.
2. **Hero Pulse mark**: 128×128, centred horizontally. The dot is solid in the pulse-gradient colour with a soft outer-glow halo (~24px radius blur). The radial rings are slightly asymmetric, fading outward. The rings near the dot are saturated; the outermost ring is just a hairline.
3. **24px** gap.
4. **App name** "Page" centred, Inter Display 36pt bold, near-tight tracking.
5. **6px** gap.
6. **Tagline** centred, Inter Display 17pt regular muted: "The on-call interface for AI agents".
7. **Flex spacer** (push the auth buttons toward the bottom 40% of the screen).
8. **Sign in with Apple button** — system-standard, full-width, 52px tall, 12px corner radius. Per Apple HIG: black background + white text + Apple logo in dark mode; white background + black text + Apple logo + 1px hairline border in light mode. Label: "Sign in with Apple".
9. **8px** gap.
10. **Continue with Google button** — full-width, 52px tall, 12px corner radius. Per Google's branding rules: white background + Google "G" icon + dark text in light mode; dark grey (`#1F1F1F`) background + Google "G" icon + white text in dark mode. 1px hairline border in both modes. Label: "Continue with Google".
11. **20px** gap.
12. **Legal microcopy** centred, 12pt muted, line height 1.4: "By continuing, you agree to the Terms and Privacy Policy." The words "Terms" and "Privacy Policy" are underlined to suggest they're links.
13. **34px** safe-area padding at the bottom.

# Deliverable

A single `.pen` file with **two artboards side by side**, both 393×852 (iPhone 15 Pro):
- Left: **Welcome — Dark**
- Right: **Welcome — Light**

The hero Pulse must look **genuinely glowing** — soft halo, the gradient feels luminous against the deep ink (dark) / warm paper (light) background. This is the moment a new user falls in love with the brand or doesn't. Get it right.
