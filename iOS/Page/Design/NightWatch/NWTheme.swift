import SwiftUI

/// Night Watch design tokens for the phone: colour, type, spacing, radius and
/// the aurora palettes. Values are read off the approved v4 boards
/// (Designs/v4) and match the Mac app's tokens (Sources/ClaudePowerMode/UI/
/// Theme.swift), which the iOS target cannot share. Fonts are the system ones
/// (SF Pro / SF Mono). Night Watch is a dark design; these do not follow the
/// light appearance. Plain SwiftUI, no UIKit, so the views can also be drawn
/// by a macOS proxy renderer.
enum NightWatch {
    // MARK: colour

    /// A colour as plain numbers, so it can be compared, mixed and tested.
    /// sRGB, 0...1.
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
    }

    enum Palette {
        /// Near-black navy the surfaces sit on.
        static let background = RGBA(hex: 0x05070D)
        static let backgroundDeep = RGBA(hex: 0x04060A)
        /// Card / row fills.
        static let surface = RGBA(hex: 0x14161C)
        static let surfaceRaised = RGBA(hex: 0x1B1E25)
        static let inset = RGBA(hex: 0x0A0C11)
        static let hairline = RGBA(1, 1, 1, 0.08)

        static let textPrimary = RGBA(1, 1, 1, 0.96)
        static let textSecondary = RGBA(1, 1, 1, 0.70)
        static let textTertiary = RGBA(1, 1, 1, 0.50)
        static let textQuiet = RGBA(1, 1, 1, 0.38)
        /// Text drawn on the bright teal-to-sky and amber fills.
        static let onBright = RGBA(hex: 0x06141A)

        // Status colours. Red appears only for irreversible things (and the
        // hold ring); amber means "needs you" / "looks stuck".
        static let red = RGBA(hex: 0xF26D6D)
        static let amber = RGBA(hex: 0xF5B14C)
        static let yellow = RGBA(hex: 0xF2C94C)
        static let green = RGBA(hex: 0x34D399)
        static let teal = RGBA(hex: 0x5EEAD4)
        static let sky = RGBA(hex: 0x38BDF8)
        static let violet = RGBA(hex: 0xA78BFA)
        /// The tint of a glass card's optional glow (see `CardGlow`).
        static let glass = RGBA(hex: 0x5FD0C8)
        /// Star white: the pulse when everything is quiet.
        static let star = RGBA(hex: 0xFFF6E0)
    }

    // MARK: type (SF Pro / SF Mono, text styles so Dynamic Type applies)

    enum Typo {
        /// "2 need you": the Horizon sentence.
        static let hero = Font.system(.title, design: .default, weight: .bold)
        /// A card title: "Delete every Dev build?".
        static let headline = Font.system(.title3, design: .default, weight: .bold)
        static let title = Font.system(.headline, design: .default, weight: .semibold)
        static let subline = Font.system(.subheadline, design: .default, weight: .regular)
        static let body = Font.system(.subheadline, design: .default, weight: .regular)
        static let bodyStrong = Font.system(.subheadline, design: .default, weight: .semibold)
        static let button = Font.system(.body, design: .default, weight: .semibold)
        static let caption = Font.system(.caption, design: .default, weight: .regular)
        static let captionStrong = Font.system(.caption, design: .default, weight: .semibold)
        /// Commands and session names.
        static let mono = Font.system(.callout, design: .monospaced, weight: .semibold)
        static let monoBody = Font.system(.footnote, design: .monospaced, weight: .regular)
        static let monoSmall = Font.system(.caption, design: .monospaced, weight: .medium)
        static let monoMicro = Font.system(.caption2, design: .monospaced, weight: .medium)
        /// Small all-caps tracked label: IRREVERSIBLE, DECIDE.
        static let label = Font.system(.caption2, design: .default, weight: .heavy)
        static let labelLarge = Font.system(.footnote, design: .default, weight: .bold)
        static let labelTracking: CGFloat = 1.0
        static let heroTracking: CGFloat = -0.4
    }

    // MARK: space and shape

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        /// Side gutter of the Now stream.
        static let gutter: CGFloat = 16
    }

    enum Radius {
        static let card: CGFloat = 22
        static let row: CGFloat = 18
        static let inset: CGFloat = 14
        static let button: CGFloat = 16
        static let chip: CGFloat = 6
        static let capsule: CGFloat = 32
    }

    // MARK: aurora

    /// Colours and strength of a header aurora. `intensity` 0 draws only the
    /// sky (dusk has no curtains).
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

        /// Something needs you: amber.
        static let needsYou = AuroraPalette(
            c1: RGBA(hex: 0xF5B14C), c2: RGBA(hex: 0xF2C94C), c3: RGBA(hex: 0xB45309),
            skyTop: RGBA(hex: 0x1A1306), skyBottom: RGBA(hex: 0x05070D), intensity: 1, speed: 1)
        /// Agents working, nothing needs you: teal over a violet tail, half strength.
        static let working = AuroraPalette(
            c1: RGBA(hex: 0x5EEAD4), c2: RGBA(hex: 0x38BDF8), c3: RGBA(hex: 0x6D5BD0),
            skyTop: RGBA(hex: 0x0B1B24), skyBottom: RGBA(hex: 0x05070D), intensity: 0.5, speed: 0.4)
        /// Nothing running: the same teal, barely there.
        static let quiet = AuroraPalette(
            c1: RGBA(hex: 0x5EEAD4), c2: RGBA(hex: 0x38BDF8), c3: RGBA(hex: 0x6D5BD0),
            skyTop: RGBA(hex: 0x0A141C), skyBottom: RGBA(hex: 0x05070D), intensity: 0.3, speed: 0.3)
        /// Paused for battery: a flat dusk gradient, no curtains.
        static let dusk = AuroraPalette(
            c1: RGBA(hex: 0x6D5BD0), c2: RGBA(hex: 0x3B2A6A), c3: RGBA(hex: 0x3B2A6A),
            skyTop: RGBA(hex: 0x3B2A6A), skyBottom: RGBA(hex: 0x120E22), intensity: 0, speed: 0)

        /// The Mac is asleep or gone: cold slate sky, no curtains.
        static let asleep = AuroraPalette(
            c1: RGBA(hex: 0x4B5670), c2: RGBA(hex: 0x2B3550), c3: RGBA(hex: 0x2B3550),
            skyTop: RGBA(hex: 0x182033), skyBottom: RGBA(hex: 0x05070D), intensity: 0, speed: 0)
        /// Something needs fixing (relay, pairing): a low amber glow.
        static let problem = AuroraPalette(
            c1: RGBA(hex: 0xB07A2C), c2: RGBA(hex: 0x6B4A18), c3: RGBA(hex: 0x4A3010),
            skyTop: RGBA(hex: 0x1F1608), skyBottom: RGBA(hex: 0x05070D), intensity: 0.28, speed: 0.2)

        init(c1: RGBA, c2: RGBA, c3: RGBA, skyTop: RGBA, skyBottom: RGBA, intensity: Double, speed: Double) {
            self.c1 = c1; self.c2 = c2; self.c3 = c3
            self.skyTop = skyTop; self.skyBottom = skyBottom
            self.intensity = intensity; self.speed = speed
        }

        init(_ mood: NowModel.Mood) {
            switch mood {
            case .needsYou: self = .needsYou
            case .working: self = .working
            case .quiet: self = .quiet
            case .dusk: self = .dusk
            }
        }
    }
}

// MARK: - Environment

private struct NWCardGlowKey: EnvironmentKey {
    static let defaultValue: CardGlow = .default
}

private struct NWAnimationsPausedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NWFixedPhaseKey: EnvironmentKey {
    static let defaultValue: Double? = nil
}

private struct NWTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct NWFixedNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

/// A signature motion pinned at one moment, for the render harness: the
/// views that play `kind` draw the frame `time` seconds after it began
/// instead of following the clock.
struct NWMotionPin: Equatable {
    enum Kind: String, Equatable { case exhale, approach, receipt, hold, dusk, dawn, brief }
    var kind: Kind
    var time: Double
}

private struct NWMotionPinKey: EnvironmentKey {
    static let defaultValue: NWMotionPin? = nil
}

extension EnvironmentValues {
    /// A status-bar height for renderers with no safe area (the macOS proxy).
    var nwTopInset: CGFloat? {
        get { self[NWTopInsetKey.self] }
        set { self[NWTopInsetKey.self] = newValue }
    }

    /// When set, the arm ring and ages use this clock instead of the real
    /// one: the render harness pins it so a ring is drawn part-way.
    var nwFixedNow: Date? {
        get { self[NWFixedNowKey.self] }
        set { self[NWFixedNowKey.self] = newValue }
    }

    /// The Card glow setting. The one place every glass surface reads it
    /// from; set once at the app root. Off unless the user turns it on.
    var nwCardGlow: CardGlow {
        get { self[NWCardGlowKey.self] }
        set { self[NWCardGlowKey.self] = newValue }
    }

    /// True while something covers the screen (a sheet): the aurora and pulse
    /// hold their last frame instead of redrawing under it.
    var nwAnimationsPaused: Bool {
        get { self[NWAnimationsPausedKey.self] }
        set { self[NWAnimationsPausedKey.self] = newValue }
    }

    /// When set, aurora, pulse and stars use this time (seconds) instead of
    /// the clock: the render harness pins it so frames are deterministic.
    var nwFixedPhase: Double? {
        get { self[NWFixedPhaseKey.self] }
        set { self[NWFixedPhaseKey.self] = newValue }
    }

    /// When set, the signature motion of that kind draws the pinned moment
    /// (`NWMotionPin`); the render harness's `-NWTime`.
    var nwMotion: NWMotionPin? {
        get { self[NWMotionPinKey.self] }
        set { self[NWMotionPinKey.self] = newValue }
    }

    /// The pinned seconds into `kind`, or nil when that motion is live.
    func nwPinned(_ kind: NWMotionPin.Kind) -> Double? { nwMotion?.kind == kind ? nwMotion?.time : nil }
}

extension Text {
    /// The small all-caps tracked label style.
    func nwLabel(_ color: NightWatch.RGBA = NightWatch.Palette.textTertiary) -> Text {
        self.font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
            .foregroundColor(color.color)
    }
}
