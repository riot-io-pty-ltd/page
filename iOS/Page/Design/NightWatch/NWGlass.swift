import SwiftUI

/// Eased gradient stops for a ramp: `alpha(t)` sampled at `steps + 1` points,
/// so a glow rises with no visible step or band.
func nwRampStops(_ color: NightWatch.RGBA, steps: Int = 14, alpha: (Double) -> Double) -> [Gradient.Stop] {
    (0...steps).map { i in
        let t = Double(i) / Double(steps)
        return Gradient.Stop(color: color.opacity(alpha(t)).color, location: t)
    }
}

/// The glass of a Night Watch surface: a near-black fill and a hairline rim.
/// The "Card glow" setting (`\.nwCardGlow`) decides whether a soft light
/// also rises from the bottom edge. Off (the default) draws no light at all:
/// no teal tint in the fill and none in the rim. When on, the light follows
/// the card's own rounded outline (a blurred inner stroke, masked so it
/// fades smoothly upwards) and a faint wash; it never stops at a hard edge
/// and never leaves the card's corners.
///
/// `tint` colours the surface for a state (red for Irreversible, amber for
/// Look). That is the card's own colour, not the glow, so it stays with the
/// glow Off.
struct NWGlassBackground: View {
    var radius: CGFloat = NightWatch.Radius.card
    var fill: NightWatch.RGBA = NightWatch.Palette.surface.opacity(0.92)
    var tint: NightWatch.RGBA? = nil
    var rim = true
    @Environment(\.nwCardGlow) private var glow

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let base = tint.map { fill.mixed(with: $0.opacity(1), 0.13) } ?? fill
        ZStack {
            shape.fill(base.color)
            if glow.isOn { NWCardGlowLight(radius: radius, glow: glow) }
            if rim {
                shape.strokeBorder(LinearGradient(
                    colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                    startPoint: .top, endPoint: .bottom), lineWidth: 1)
                if let tint {
                    shape.strokeBorder(tint.opacity(0.32).color, lineWidth: 1)
                }
                if glow.isOn { NWCardGlowRim(radius: radius, glow: glow) }
            }
        }
    }
}

/// The inner light: a wide, soft wash plus a blurred stroke that hugs the
/// rounded outline, both masked with an eased bottom-weighted ramp. Drawn
/// inside the shape (clipped to it), so it follows the corners.
struct NWCardGlowLight: View {
    var radius: CGFloat
    var glow: CardGlow
    private let tint = NightWatch.Palette.glass

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let reach = glow.reach
        ZStack {
            // Wash: an ellipse centred on the bottom edge.
            shape.fill(EllipticalGradient(
                stops: nwRampStops(tint) { t in glow.lightAlpha(at: 1 - t) * 0.5 },
                center: .bottom, startRadiusFraction: 0, endRadiusFraction: 0.85))
            // Edge light: the outline, blurred inwards.
            shape.strokeBorder(tint.opacity(glow.bottomAlpha * 1.4).color, lineWidth: 5)
                .blur(radius: 7)
                .mask(LinearGradient(stops: nwRampStops(.init(1, 1, 1)) { t in
                    glow.lightAlpha(at: (t - (1 - reach)) / reach) / max(0.0001, glow.bottomAlpha)
                }, startPoint: .top, endPoint: .bottom))
        }
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

/// The rim's glow: the outline warms towards the bottom along an eased ramp
/// (zero over the top half).
struct NWCardGlowRim: View {
    var radius: CGFloat
    var glow: CardGlow

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(LinearGradient(
                stops: nwRampStops(NightWatch.Palette.glass) { glow.rimAlpha(at: $0) },
                startPoint: .top, endPoint: .bottom), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// Just the rim of a glass surface, for drawing above content that fills the
/// whole shape (an aurora header).
struct NWGlassRim: View {
    var radius: CGFloat = NightWatch.Radius.card
    /// False when the surface under this rim already draws the glow (a glass
    /// background): the hairline alone is repeated, never the glow twice.
    var withGlow = true
    @Environment(\.nwCardGlow) private var glow

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.13), Color.white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
            if withGlow, glow.isOn { NWCardGlowRim(radius: radius, glow: glow) }
        }
        .allowsHitTesting(false)
    }
}

/// A glass card around its content.
struct NWGlassCard<Content: View>: View {
    var radius: CGFloat = NightWatch.Radius.card
    var padding: CGFloat = NightWatch.Space.lg
    var tint: NightWatch.RGBA? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NWGlassBackground(radius: radius, tint: tint))
    }
}

/// The page background: the night sky's darkness with a whisper of violet at
/// the top. There is deliberately no light at the bottom: any glow comes
/// from the Card glow setting, on the cards themselves.
struct NWBackdrop: View {
    var body: some View {
        ZStack {
            NightWatch.Palette.backgroundDeep.color
            RadialGradient(colors: [NightWatch.Palette.violet.opacity(0.07).color, .clear],
                           center: .topTrailing, startRadius: 10, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}
