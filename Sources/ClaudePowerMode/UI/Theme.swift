import AppKit
import SwiftUI

/// Night Watch design tokens: colour, type, spacing, radius, and the aurora
/// palettes. Values are read off the approved v4 boards (Designs/v4); fonts
/// are the system ones (SF Pro / SF Mono) rather than the boards' Inter /
/// JetBrains Mono.
enum NightWatch {
    // MARK: colour

    /// A colour as plain numbers, so the same token feeds SwiftUI (`Color`)
    /// and AppKit drawing (`NSColor`, the status-bar glyph) and can be
    /// compared in tests. sRGB, 0...1.
    struct RGBA: Equatable {
        let r: Double, g: Double, b: Double, a: Double

        init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
            self.r = r; self.g = g; self.b = b; self.a = a
        }

        /// 0xRRGGBB.
        init(hex: UInt32, alpha: Double = 1) {
            self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255,
                      Double(hex & 0xFF) / 255, alpha)
        }

        func opacity(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }
        /// Mix towards `other` by `t` (0 = self, 1 = other); alpha follows.
        func mixed(with other: RGBA, _ t: Double) -> RGBA {
            RGBA(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
        var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    }

    enum Palette {
        /// Near-black navy the surfaces sit on.
        static let background = RGBA(hex: 0x05070D)
        static let backgroundDeep = RGBA(hex: 0x04060A)
        /// The popover body: a shade lighter than the background, like the glass on the boards.
        static let popoverBody = RGBA(hex: 0x090C12)
        /// Card / row fills (white at low alpha over the background).
        static let surface = RGBA(hex: 0x14161C)
        static let surfaceRaised = RGBA(hex: 0x1B1E25)
        static let hairline = RGBA(1, 1, 1, 0.08)

        static let textPrimary = RGBA(1, 1, 1, 0.96)
        static let textSecondary = RGBA(1, 1, 1, 0.70)
        static let textTertiary = RGBA(1, 1, 1, 0.50)
        static let textQuiet = RGBA(1, 1, 1, 0.38)

        // Status colours. Red appears only for irreversible things (and the
        // hold ring); amber means "needs you" / "looks stuck".
        static let red = RGBA(hex: 0xF26D6D)
        static let amber = RGBA(hex: 0xF5B14C)
        static let green = RGBA(hex: 0x34D399)
        static let teal = RGBA(hex: 0x5EEAD4)
        static let sky = RGBA(hex: 0x38BDF8)
        static let violet = RGBA(hex: 0xA78BFA)
        /// The rim / bottom glow of a glass card.
        static let glass = RGBA(hex: 0x5FD0C8)
        /// Star white: the pulse when everything is quiet.
        static let star = RGBA(hex: 0xFFF6E0)
    }

    // MARK: type

    enum Typo {
        /// 18 pt bold, tight: "2 need you · 5 working".
        static let headline = Font.system(size: 18, weight: .bold)
        static let title = Font.system(size: 15, weight: .semibold)
        /// 12 pt medium: the line under a headline.
        static let subline = Font.system(size: 12, weight: .medium)
        static let body = Font.system(size: 13, weight: .regular)
        static let bodyStrong = Font.system(size: 13, weight: .semibold)
        static let caption = Font.system(size: 11, weight: .regular)
        /// Session names and commands.
        static let mono = Font.system(size: 13, weight: .semibold, design: .monospaced)
        static let monoBody = Font.system(size: 12, weight: .regular, design: .monospaced)
        static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let monoMicro = Font.system(size: 10, weight: .medium, design: .monospaced)
        /// Small all-caps tracked label: IRREVERSIBLE, WELCOME BACK.
        static let label = Font.system(size: 9, weight: .heavy)
        static let labelLarge = Font.system(size: 11, weight: .bold)
        /// Tracking for `label` (points), applied with `.kerning`.
        static let labelTracking: CGFloat = 0.9
        static let headlineTracking: CGFloat = -0.3
    }

    // MARK: space and shape

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        /// Menu-bar popover width (the spec's 380 pt).
        static let popoverWidth: CGFloat = 380
        /// The popover's footer row.
        static let panelFooterHeight: CGFloat = 38
    }

    enum Radius {
        static let popover: CGFloat = 20
        static let card: CGFloat = 14
        static let row: CGFloat = 12
        static let keycap: CGFloat = 7
        static let chip: CGFloat = 5
    }

    // MARK: aurora

    /// Colours and strength of a header aurora. `intensity` 0 draws only the
    /// base gradient (dusk has no aurora).
    struct AuroraPalette: Equatable {
        let c1: RGBA
        let c2: RGBA
        let c3: RGBA
        /// Top and bottom of the sky behind the curtains.
        let skyTop: RGBA
        let skyBottom: RGBA
        let intensity: Double
        /// Curtain speed (1 = the boards' u_speed 0.4).
        let speed: Double

        /// Something needs you: amber (#F5B14C / #F2C94C / #B45309 on the board).
        static let needsYou = AuroraPalette(
            c1: RGBA(hex: 0xF5B14C), c2: RGBA(hex: 0xF2C94C), c3: RGBA(hex: 0xB45309),
            skyTop: RGBA(hex: 0x1A1306), skyBottom: RGBA(hex: 0x07080D), intensity: 1, speed: 1)
        /// Agents working, nothing needs you: teal over a violet tail, half strength.
        static let working = AuroraPalette(
            c1: RGBA(hex: 0x5EEAD4), c2: RGBA(hex: 0x38BDF8), c3: RGBA(hex: 0x6D5BD0),
            skyTop: RGBA(hex: 0x0B1B24), skyBottom: RGBA(hex: 0x07080D), intensity: 0.5, speed: 0.4)
        /// Nothing running: the same teal, barely there.
        static let quiet = AuroraPalette(
            c1: RGBA(hex: 0x5EEAD4), c2: RGBA(hex: 0x38BDF8), c3: RGBA(hex: 0x6D5BD0),
            skyTop: RGBA(hex: 0x0A141C), skyBottom: RGBA(hex: 0x07080D), intensity: 0.3, speed: 0.3)
        /// Paused for battery: a flat dusk gradient (#3B2A6A to #120E22), no curtains.
        static let dusk = AuroraPalette(
            c1: RGBA(hex: 0x6D5BD0), c2: RGBA(hex: 0x3B2A6A), c3: RGBA(hex: 0x3B2A6A),
            skyTop: RGBA(hex: 0x3B2A6A), skyBottom: RGBA(hex: 0x120E22), intensity: 0, speed: 0)
    }

    /// Reduce Motion, with a harness override: the render harness sets this
    /// so frames are deterministic, and views pick the static fallback.
    static var systemReduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

// MARK: - Environment

private struct NWReduceMotionKey: EnvironmentKey {
    static var defaultValue: Bool { NightWatch.systemReduceMotion }
}

private struct NWFixedPhaseKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

private struct NWCardGlowKey: EnvironmentKey {
    static let defaultValue: CardGlow = .off
}

extension EnvironmentValues {
    /// The one place every glass surface reads the "Card glow" setting from.
    var nwCardGlow: CardGlow {
        get { self[NWCardGlowKey.self] }
        set { self[NWCardGlowKey.self] = newValue }
    }
    /// True when animations must fall back to a still frame.
    var nwReduceMotion: Bool {
        get { self[NWReduceMotionKey.self] }
        set { self[NWReduceMotionKey.self] = newValue }
    }
    /// When set, aurora and breath use this phase (0...1) instead of the clock.
    var nwFixedPhase: Double? {
        get { self[NWFixedPhaseKey.self] }
        set { self[NWFixedPhaseKey.self] = newValue }
    }
}

/// The live appearance setting, shared by the separate panels (menu bar panel,
/// Dispatch, Welcome back). The app writes it from config.json; `NWAppearanceRoot`
/// feeds it into the environment. The Tower previews its own unsaved form value.
final class NWAppearance: ObservableObject {
    static let shared = NWAppearance()
    @Published var cardGlow: CardGlow = .off

    /// Only publishes a change, so a per-tick call is free.
    func set(cardGlow value: CardGlow) {
        if cardGlow != value { cardGlow = value }
    }
}

/// Root of a panel's SwiftUI tree: puts the shared appearance in the environment.
struct NWAppearanceRoot<Content: View>: View {
    @ObservedObject private var appearance = NWAppearance.shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().environment(\.nwCardGlow, appearance.cardGlow)
    }
}

extension Text {
    /// The small all-caps tracked label style.
    func nwLabel(_ color: NightWatch.RGBA = NightWatch.Palette.textTertiary) -> Text {
        self.font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
            .foregroundColor(color.color)
    }
}
