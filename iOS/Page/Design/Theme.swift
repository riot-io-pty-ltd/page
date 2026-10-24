import SwiftUI
import UIKit

/// The Page design system. Single source of truth for colours, typography,
/// spacing, and radii. Matches the Pencil mockups.
enum Theme {
    // MARK: - Colours
    enum Colour {
        static let surface = Color(lightHex: "#FAF8F4", darkHex: "#0E1014")
        static let surfaceRaised = Color(lightHex: "#FFFFFF", darkHex: "#181B22")
        static let surfaceInset = Color(lightHex: "#F2EFE9", darkHex: "#12151B")
        static let text = Color(lightHex: "#15171A", darkHex: "#E8EAED")
        static let textMuted = Color(lightHex: "#5F6672", darkHex: "#8B92A1")
        static let hairline = Color(lightHex: "#E5E2DC", darkHex: "#262A31")
        /// Fill for the destructive Deny button (dark text on top).
        static let destructive = Color(hex: "#E06464")
        /// Destructive *text* on light surfaces needs a darker red for contrast.
        static let destructiveText = Color(lightHex: "#B42318", darkHex: "#F07878")
        static let warning = Color(lightHex: "#B45309", darkHex: "#FBBF24")
        static let success = Color(lightHex: "#047857", darkHex: "#34D399")

        // MARK: Intervention kind hues — each kind chip ring and footer dot
        // use the same colour so the eye can match them at a glance. The
        // light variants are darker so 11pt chip text stays above 4.5:1 on
        // white (the dark-mode neon hues are ~1.5:1 on white).
        static let kindApproval  = Color(lightHex: "#0F766E", darkHex: "#5EEAD4")  // teal
        static let kindUserInput = Color(lightHex: "#0369A1", darkHex: "#38BDF8")  // blue
        static let kindIdle      = Color(lightHex: "#B45309", darkHex: "#FBBF24")  // amber
        static let kindRateLimit = Color(lightHex: "#B42318", darkHex: "#E06464")  // red

        // MARK: Backend brand tints — pill text, background and stroke.
        static let backendClaude = Color(lightHex: "#9A3412", darkHex: "#E89E64")  // copper
        static let backendCodex  = Color(lightHex: "#047857", darkHex: "#10A37F")  // green
        /// Any other backend (local models, future agents): neutral slate.
        static let backendOther  = Color(lightHex: "#475467", darkHex: "#A3ADC2")

        /// The signature gradient. Cyan→teal in dark, amber→chartreuse in light.
        static func pulseGradient(_ scheme: ColorScheme) -> LinearGradient {
            let stops = (scheme == .dark)
                ? [Color(hex: "#5EEAD4"), Color(hex: "#38BDF8")]
                : [Color(hex: "#F2C94C"), Color(hex: "#C9E265")]
            return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
        }

        /// Text drawn on top of the pulse gradient or the destructive fill.
        static let onAccent = Color(hex: "#15171A")
    }

    // MARK: - Typography
    // Text-style based so everything follows the user's Dynamic Type size.
    // At the default size each style matches the mockups' point sizes
    // (title 28, title2 22, headline 17, subheadline 15, footnote 13,
    // caption 12, caption2 11).
    enum Font {
        static let display28 = SwiftUI.Font.system(.title, design: .default, weight: .bold).leading(.tight)
        static let display22 = SwiftUI.Font.system(.title2, design: .default, weight: .semibold).leading(.tight)
        static let title17 = SwiftUI.Font.system(.headline)
        static let button17 = SwiftUI.Font.system(.body, design: .default, weight: .semibold)
        static let body15 = SwiftUI.Font.system(.subheadline)
        static let bodyEm = SwiftUI.Font.system(.subheadline, design: .default, weight: .semibold)
        static let caption12 = SwiftUI.Font.system(.caption, design: .default, weight: .medium)
        static let chip11 = SwiftUI.Font.system(.caption2, design: .default, weight: .semibold)
        static let mono13 = SwiftUI.Font.system(.footnote, design: .monospaced)
    }

    // MARK: - Spacing
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 14
        static let button: CGFloat = 22
        static let input: CGFloat = 24
    }
}

extension InterventionKind {
    /// Ring colour for the chip and matching footer dot.
    var color: Color {
        switch self {
        case .approval:   return Theme.Colour.kindApproval
        case .userInput:  return Theme.Colour.kindUserInput
        case .idle:       return Theme.Colour.kindIdle
        case .rateLimit:  return Theme.Colour.kindRateLimit
        }
    }
}

extension InterventionBackend {
    /// Brand tint for the backend pill.
    var tint: Color {
        switch self {
        case .claude: return Theme.Colour.backendClaude
        case .codex:  return Theme.Colour.backendCodex
        }
    }
}

extension AgentBackend {
    /// Brand tint for Claude and Codex, neutral for anything else.
    var tint: Color {
        switch self {
        case .known(let b): return b.tint
        case .other: return Theme.Colour.backendOther
        }
    }
}

extension LiveSessionState {
    /// State dot and chip colour. Waiting states reuse the matching page
    /// kind's hue, so a session and its page read as the same thing.
    var color: Color {
        switch self {
        case .waitingOnApproval: return Theme.Colour.kindApproval
        case .waitingOnUser:     return Theme.Colour.kindUserInput
        case .active:            return Theme.Colour.success
        case .rateLimited:       return Theme.Colour.kindRateLimit
        case .interrupted:       return Theme.Colour.warning
        case .failed:            return Theme.Colour.destructiveText
        case .idle, .offline, .unknown: return Theme.Colour.textMuted
        }
    }
}

// MARK: - Color hex initialisers
extension Color {
    init(hex: String) {
        self.init(uiColor: UIColor(hexString: hex))
    }

    /// A colour that follows the system light/dark appearance.
    init(lightHex: String, darkHex: String) {
        let dynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hexString: darkHex) : UIColor(hexString: lightHex)
        }
        self.init(uiColor: dynamic)
    }
}

extension UIColor {
    convenience init(hexString: String) {
        let s = hexString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = CGFloat((rgb & 0xFF0000) >> 16) / 255
        let g = CGFloat((rgb & 0x00FF00) >> 8) / 255
        let b = CGFloat(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
