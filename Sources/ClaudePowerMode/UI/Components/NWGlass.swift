import SwiftUI

/// The glass of a Night Watch surface: a near-black fill, a hairline rim that
/// warms from white at the top to a faint cyan at the bottom, and a soft
/// cyan glow along the bottom edge. Drawn with plain fills and gradients (no
/// materials), so it looks the same on any wallpaper and renders the same
/// off screen.
struct NWGlassBackground: View {
    var radius: CGFloat = NightWatch.Radius.card
    var fill: NightWatch.RGBA = NightWatch.Palette.surface.opacity(0.92)
    var glow: NightWatch.RGBA = NightWatch.Palette.glass
    /// Height of the bottom glow, in points.
    var glowHeight: CGFloat = 26
    var rim: Bool = true

    var body: some View {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let f = min(1, glowHeight / max(1, geo.size.height))
            ZStack {
                shape.fill(fill.color)
                // Bottom glow.
                shape.fill(LinearGradient(
                    stops: [.init(color: glow.opacity(0).color, location: 1 - f),
                            .init(color: glow.opacity(0.16).color, location: 1 - f * 0.45),
                            .init(color: glow.opacity(0.52).color, location: 1)],
                    startPoint: .top, endPoint: .bottom))
                if rim {
                    shape.strokeBorder(LinearGradient(
                        stops: [.init(color: Color.white.opacity(0.13), location: 0),
                                .init(color: Color.white.opacity(0.05), location: 0.55),
                                .init(color: glow.opacity(0.55).color, location: 1)],
                        startPoint: .top, endPoint: .bottom), lineWidth: 1)
                }
            }
        }
    }
}

/// Just the rim of a glass surface (see `NWGlassBackground`), for drawing above
/// content that fills the whole shape, such as an aurora header.
struct NWGlassRim: View {
    var radius: CGFloat = NightWatch.Radius.card
    var glow: NightWatch.RGBA = NightWatch.Palette.glass

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(
                stops: [.init(color: Color.white.opacity(0.13), location: 0),
                        .init(color: Color.white.opacity(0.05), location: 0.55),
                        .init(color: glow.opacity(0.55).color, location: 1)],
                startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
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
    var body: some View {
        ZStack {
            NightWatch.Palette.backgroundDeep.color
            RadialGradient(colors: [NightWatch.Palette.glass.opacity(0.10).color, .clear],
                           center: .bottomLeading, startRadius: 10, endRadius: 520)
            RadialGradient(colors: [NightWatch.Palette.violet.opacity(0.08).color, .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 480)
        }
    }
}
