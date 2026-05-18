import SwiftUI

/// The Page design system. Single source of truth for colours, typography,
/// spacing, and radii. Matches the Pencil mockups exactly.
enum Theme {
    // MARK: - Colours
    enum Colour {
        static let surface = Color("Surface", bundle: .main, lightHex: "#FAF8F4", darkHex: "#0E1014")
        static let surfaceRaised = Color("SurfaceRaised", bundle: .main, lightHex: "#FFFFFF", darkHex: "#181B22")
        static let text = Color("Text", bundle: .main, lightHex: "#15171A", darkHex: "#E8EAED")
        static let textMuted = Color("TextMuted", bundle: .main, lightHex: "#6B7280", darkHex: "#8B92A1")
        static let hairline = Color("Hairline", bundle: .main, lightHex: "#E5E2DC", darkHex: "#202326")
        static let destructive = Color(hex: "#E06464")

        // MARK: Intervention kind hues — each kind chip ring and footer dot
        // use the same colour so the eye can match them at a glance.
        static let kindApproval  = Color(hex: "#5EEAD4")  // cyan
        static let kindUserInput = Color(hex: "#38BDF8")  // blue
        static let kindIdle      = Color(hex: "#FBBF24")  // yellow
        static let kindRateLimit = Color(hex: "#E06464")  // red

        // MARK: Backend brand tints — pill background and stroke.
        static let backendClaude = Color(hex: "#E89E64")  // amber/copper
        static let backendCodex  = Color(hex: "#10A37F")  // OpenAI-ish green

        /// The signature gradient. Cyan→teal in dark, amber→chartreuse in light.
        static func pulseGradient(_ scheme: ColorScheme) -> LinearGradient {
            let stops = (scheme == .dark)
                ? [Color(hex: "#5EEAD4"), Color(hex: "#38BDF8")]
                : [Color(hex: "#F2C94C"), Color(hex: "#C9E265")]
            return LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    // MARK: - Typography
    enum Font {
        static let display28 = SwiftUI.Font.system(size: 28, weight: .bold, design: .default).leading(.tight)
        static let display22 = SwiftUI.Font.system(size: 22, weight: .semibold, design: .default).leading(.tight)
        static let display36 = SwiftUI.Font.system(size: 36, weight: .bold, design: .default).leading(.tight)
        static let title17 = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let body15 = SwiftUI.Font.system(size: 15, weight: .regular)
        static let bodyEm = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let caption12 = SwiftUI.Font.system(size: 12, weight: .medium)
        static let mono13 = SwiftUI.Font.system(size: 13, weight: .regular, design: .monospaced)
        static let mono15 = SwiftUI.Font.system(size: 15, weight: .regular, design: .monospaced)
    }

    // MARK: - Spacing
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let huge: CGFloat = 32
    }

    enum Radius {
        static let chip: CGFloat = 10
        static let card: CGFloat = 14
        static let button: CGFloat = 22
        static let input: CGFloat = 24
    }
}

// MARK: - Color hex initialiser
extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        _ = scanner.scanString("#")
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }

    init(_ name: String, bundle: Bundle, lightHex: String, darkHex: String) {
        // Prefer asset-catalog color if available, else fall back to dynamic UIColor.
        #if canImport(UIKit)
        let dynamic = UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hexString: darkHex) : UIColor(hexString: lightHex)
        }
        self.init(uiColor: dynamic)
        #else
        self.init(hex: lightHex)
        #endif
    }
}

#if canImport(UIKit)
import UIKit
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
#endif
