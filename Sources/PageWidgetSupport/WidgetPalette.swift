import SwiftUI

/// Night Watch colours, as the app's `NightWatch.Palette` has them. The
/// extension cannot link the app's Theme (it draws with AppKit); a test keeps
/// these numbers equal to the app's.
public enum WidgetPalette {
    public struct RGBA: Equatable {
        public let r: Double, g: Double, b: Double, a: Double
        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
        public init(hex: UInt32, alpha: Double = 1) {
            self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, alpha)
        }
        public func opacity(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }
        public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    }

    public static let background = RGBA(hex: 0x05070D)
    public static let backgroundDeep = RGBA(hex: 0x04060A)
    public static let surface = RGBA(hex: 0x14161C)
    public static let textPrimary = RGBA(1, 1, 1, 0.96)
    public static let textSecondary = RGBA(1, 1, 1, 0.70)
    public static let textTertiary = RGBA(1, 1, 1, 0.50)
    public static let textQuiet = RGBA(1, 1, 1, 0.38)
    public static let red = RGBA(hex: 0xF26D6D)
    public static let amber = RGBA(hex: 0xF5B14C)
    public static let green = RGBA(hex: 0x34D399)
    public static let teal = RGBA(hex: 0x5EEAD4)
    public static let sky = RGBA(hex: 0x38BDF8)
    public static let violet = RGBA(hex: 0xA78BFA)
    public static let glass = RGBA(hex: 0x5FD0C8)
    public static let star = RGBA(hex: 0xFFF6E0)
    /// Slate: Page is not running.
    public static let slate = RGBA(hex: 0x8A93A8)

    /// The colour a tone is drawn in.
    public static func color(for tone: WidgetTone) -> RGBA {
        switch tone {
        case .needsYou: return amber
        case .working: return teal
        case .quiet: return star
        case .paused: return violet
        case .asleep: return slate
        }
    }
}
