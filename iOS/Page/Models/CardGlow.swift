import Foundation

/// The "Card glow" setting: how much of a soft teal light glass cards and
/// panels draw along their bottom edge. Off by default, because the original
/// hard band looked cut off. Every glass surface reads it through one
/// environment value (`\.nwCardGlow`); nothing draws a glow of its own.
///
/// Foundation-only so the persistence and the numbers can be tested.
enum CardGlow: String, CaseIterable, Equatable, Identifiable {
    case off, subtle, full

    var id: String { rawValue }

    static let `default`: CardGlow = .off
    /// UserDefaults key (the phone's own preference; never synced).
    static let defaultsKey = "page.cardGlow"

    /// Segment label.
    var label: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .full: return "Full"
        }
    }

    /// 0 for Off; the share of the full light the other levels draw.
    var strength: Double {
        switch self {
        case .off: return 0
        case .subtle: return 0.5
        case .full: return 1
        }
    }

    var isOn: Bool { self != .off }

    /// Anything unknown or missing is Off, never a glow.
    init(stored raw: String?) {
        self = raw.flatMap(CardGlow.init(rawValue:)) ?? .off
    }

    /// `-NWGlow off|subtle|full` for the render harness; nil when absent or unknown.
    init?(argument raw: String?) {
        guard let raw, let g = CardGlow(rawValue: raw.lowercased()) else { return nil }
        self = g
    }

    static func load(from defaults: UserDefaults = .standard) -> CardGlow {
        CardGlow(stored: defaults.string(forKey: defaultsKey))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    /// Alpha of the light at the very bottom of a card, for the colour the
    /// card passes in (the glow is a tint, so this stays below the fill).
    var bottomAlpha: Double { 0.34 * strength }

    /// How far up the card the light reaches, as a share of its height.
    var reach: Double { 0.30 + 0.20 * strength }

    /// Alpha of the glow along the rim at `t` (0 top, 1 bottom): an eased
    /// ramp, zero over the top half, with no step anywhere. Pure.
    func rimAlpha(at t: Double) -> Double {
        guard isOn else { return 0 }
        let x = min(1, max(0, (t - 0.5) / 0.5))
        return 0.42 * strength * x * x * (3 - 2 * x)
    }

    /// Alpha of the inner light at `t` (0 at the light's far edge, 1 at the
    /// card's bottom edge): smoothstep-squared, so it starts at exactly zero
    /// with zero slope. Pure.
    func lightAlpha(at t: Double) -> Double {
        guard isOn else { return 0 }
        let x = min(1, max(0, t))
        let s = x * x * (3 - 2 * x)
        return bottomAlpha * s * s
    }
}
