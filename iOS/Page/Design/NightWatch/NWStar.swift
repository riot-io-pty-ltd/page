import SwiftUI

/// A session's own star: a rounded shape seeded from a stable hash of its
/// folder, so the same project always looks the same. 3 to 5 points, each
/// with its own reach, corners rounded like the pulse glyph.
struct NWStarShape: Shape {
    var seed: UInt64

    func path(in rect: CGRect) -> Path {
        let n = 3 + Int(seed % 3)
        let rotation = Double((seed >> 8) % 360) * .pi / 180
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var pts: [CGPoint] = []
        for i in 0..<n {
            let jitter = 0.80 + 0.20 * Double((seed >> UInt64(16 + i * 5)) & 0x1F) / 31.0
            let a = rotation + Double(i) / Double(n) * 2 * .pi - .pi / 2
            pts.append(CGPoint(x: c.x + CGFloat(cos(a) * jitter) * r, y: c.y + CGFloat(sin(a) * jitter) * r))
        }
        let radius = r * 0.55
        var p = Path()
        p.move(to: CGPoint(x: (pts[0].x + pts[n - 1].x) / 2, y: (pts[0].y + pts[n - 1].y) / 2))
        for i in 0..<n { p.addArc(tangent1End: pts[i], tangent2End: pts[(i + 1) % n], radius: radius) }
        p.closeSubpath()
        return p
    }
}

/// The star as a glyph: a soft halo, the shape filled from white to the
/// colour, a fine outline.
struct NWStarGlyph: View {
    var seed: UInt64
    var color: NightWatch.RGBA
    var size: CGFloat = 28
    var brightness: Double = 1
    /// The halo's strength when it breathes (In flight's 0.3 → 0.55); nil is the resting 0.42.
    var glow: Double? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [color.opacity((glow ?? 0.42) * brightness).color, color.opacity(0).color],
                                     center: .center, startRadius: 1, endRadius: size * 0.75))
                .frame(width: size * 1.5, height: size * 1.5)
            NWStarShape(seed: seed)
                .fill(RadialGradient(colors: [Color.white.opacity(0.95 * brightness), color.opacity(0.9 * brightness).color],
                                     center: .center, startRadius: 0, endRadius: size * 0.5))
                .overlay(NWStarShape(seed: seed).stroke(color.opacity(0.9 * brightness).color, lineWidth: 1))
                .frame(width: size * 0.7, height: size * 0.7)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension StarState {
    /// Teal working, amber needs you, dim white idle; the rest follow.
    var color: NightWatch.RGBA {
        switch self {
        case .working: return NightWatch.Palette.teal
        case .needsYou, .stuck: return NightWatch.Palette.amber
        case .rateLimited: return NightWatch.Palette.sky
        case .paused: return NightWatch.RGBA(hex: 0x8A8FA0)
        case .idle: return NightWatch.RGBA(hex: 0xC9CEDB)
        case .offline: return NightWatch.RGBA(hex: 0x6B7080)
        }
    }
}

extension ProjectHue {
    var color: NightWatch.RGBA { NightWatch.RGBA(hex: hex) }
}
