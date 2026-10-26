import SwiftUI

/// The glass of a Night Watch surface: a near-black fill and a hairline rim
/// that is white at the top. When the "Card glow" setting is on (read from the
/// environment, the one place every surface gets it from), a soft teal glow
/// rises from the bottom edge and the rim warms to teal there. With it off
/// (the default) the card is plain glass. Drawn with plain fills and gradients
/// (no materials), so it looks the same on any wallpaper and renders the same
/// off screen.
struct NWGlassBackground: View {
    @Environment(\.nwCardGlow) private var cardGlow
    var radius: CGFloat = NightWatch.Radius.card
    var fill: NightWatch.RGBA = NightWatch.Palette.surface.opacity(0.92)
    /// How far up the glow reaches (the glow fades out well before the top), in points.
    var glowHeight: CGFloat = 26
    var rim: Bool = true

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(fill.color)
            if cardGlow != .off {
                NWBottomGlow(intensity: cardGlow.intensity, reach: glowHeight).clipShape(shape)
            }
            if rim { NWGlassRim(radius: radius) }
        }
    }
}

/// A soft elliptical glow centred on the bottom edge. It is a radial gradient
/// whose falloff is eased to nothing before its edge, so there is no band, and
/// the owner clips it to the card's rounded shape so it follows the corners.
struct NWBottomGlow: View {
    var color: NightWatch.RGBA = NightWatch.Palette.glass
    /// 0...1; 1 is the full glow.
    var intensity: Double
    /// The card's `glowHeight`; the glow reaches about twice this far up.
    var reach: CGFloat

    /// Opacity of the glow at the bottom edge when `intensity` is 1.
    static let peak = 0.34

    /// Eased falloff: opacity at distance `t` (0 centre ... 1 edge) from the
    /// bottom centre. Smooth to zero at both ends.
    static func falloff(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        let s = 1 - x
        return s * s * s * (0.35 + 0.65 * s)
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width), h = max(1, geo.size.height)
            let ry = min(h * 0.9, max(24, reach * 2.2))
            let rx = max(ry * 1.4, w * 0.62)
            let a = Self.peak * min(1, max(0, intensity))
            let stops = (0...8).map { i -> Gradient.Stop in
                let t = Double(i) / 8
                return .init(color: color.opacity(a * Self.falloff(t)).color, location: t)
            }
            // A unit disc scaled into the ellipse, so the falloff is oval.
            RadialGradient(gradient: Gradient(stops: stops), center: .center, startRadius: 0, endRadius: 50)
                .frame(width: 100, height: 100)
                .scaleEffect(x: rx / 50, y: ry / 50)
                .position(x: w / 2, y: h)
        }
        .allowsHitTesting(false)
    }
}

/// Just the rim of a glass surface (see `NWGlassBackground`), for drawing above
/// content that fills the whole shape, such as an aurora header.
struct NWGlassRim: View {
    @Environment(\.nwCardGlow) private var cardGlow
    var radius: CGFloat = NightWatch.Radius.card
    var glow: NightWatch.RGBA = NightWatch.Palette.glass

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(
                stops: [.init(color: Color.white.opacity(0.13), location: 0),
                        .init(color: Color.white.opacity(0.05), location: 0.55),
                        .init(color: bottom, location: 1)],
                startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
    }

    /// Off: a plain white hairline. On: it warms to the glow colour.
    private var bottom: Color {
        let k = cardGlow.intensity
        guard k > 0 else { return Color.white.opacity(0.06) }
        return glow.opacity(0.18 + 0.37 * k).color
    }
}

/// A glass card around its content.
struct NWGlassCard<Content: View>: View {
    var radius: CGFloat = NightWatch.Radius.card
    var glowHeight: CGFloat = 22
    var padding: CGFloat = NightWatch.Space.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .background(NWGlassBackground(radius: radius, glowHeight: glowHeight))
    }
}

/// The dark, backdrop-free base the harness draws surfaces on, standing in
/// for a wallpaper.
struct NWBackdrop: View {
    @Environment(\.nwCardGlow) private var cardGlow

    var body: some View {
        ZStack {
            NightWatch.Palette.backgroundDeep.color
            RadialGradient(colors: [NightWatch.Palette.glass.opacity(0.10 * cardGlow.intensity).color, .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [NightWatch.Palette.violet.opacity(0.08).color, .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 480)
        }
    }
}
