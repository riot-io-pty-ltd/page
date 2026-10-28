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
                if glow.isOn {
                    NWCardGlowRim(radius: radius, glow: glow)
                    // glass.glsl's edge light along the top-left rim (Metal; still, no clock).
                    NWGlassEdgeLight(radius: radius)
                }
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

// MARK: - Liquid Glass

/// Liquid Glass is for the chrome that floats over the sky (the capsule, the
/// Mac chip, the round buttons, the composer, a sheet's close button), never
/// for cards and rows: those keep `NWGlassBackground`, opaque enough to read
/// over a moving aurora. iOS 26 and later only; everywhere else, and with
/// Reduce Transparency on, each piece draws exactly today's surface instead.
/// Every `glassEffect` in the app is in this file, behind that one gate.
extension NightWatch.Palette {
    /// The tint of the chrome's glass: the page's own near-black, deep enough
    /// that white labels hold over the brightest sky of the day (the
    /// afternoon, and needs-you's amber at full strength).
    static let chromeGlass = NightWatch.RGBA(hex: 0x04060A, alpha: 0.6)
}

private struct NWLiquidGlassKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the chrome may use Liquid Glass where the system has it. On;
    /// the render harness turns it off (`-NWGlass off`) to draw the fallback.
    var nwLiquidGlass: Bool {
        get { self[NWLiquidGlassKey.self] }
        set { self[NWLiquidGlassKey.self] = newValue }
    }

    /// The gate: the chrome is on glass only where the system draws it
    /// (iOS 26+), the harness allows it and Reduce Transparency is off.
    var nwChromeGlassOn: Bool {
        #if os(iOS)
        guard #available(iOS 26.0, *) else { return false }
        return nwLiquidGlass && !accessibilityReduceTransparency
        #else
        return false
        #endif
    }
}

/// One piece of chrome: Liquid Glass in `shape`, tinted, or `fallback` (the
/// surface it had before glass) behind it.
struct NWChromeGlass<S: Shape, Fallback: View>: ViewModifier {
    var shape: S
    var tint: NightWatch.RGBA
    /// Glass that answers a touch. Off for hold surfaces: their ring is the feedback.
    var interactive: Bool
    var fallback: Fallback
    @Environment(\.nwChromeGlassOn) private var glass

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glass {
                content.glassEffect(.regular.tint(tint.color).interactive(interactive), in: shape)
            } else {
                content.background(fallback)
            }
        } else {
            content.background(fallback)
        }
        #else
        content.background(fallback)
        #endif
    }
}

/// Names a piece of chrome's glass inside an `NWChromeGlassGroup`, so it
/// morphs into its neighbours as it comes and goes. Nothing without glass.
struct NWChromeGlassID<ID: Hashable & Sendable>: ViewModifier {
    var id: ID
    var namespace: Namespace.ID
    @Environment(\.nwChromeGlassOn) private var glass

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glass {
                content.glassEffectID(id, in: namespace)
            } else {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Chrome that sits together: one `GlassEffectContainer`, so the pieces
/// share what they refract and can melt into one another. Just the content
/// without glass.
struct NWChromeGlassGroup<Content: View>: View {
    var spacing: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.nwChromeGlassOn) private var glass

    var body: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            if glass {
                GlassEffectContainer(spacing: spacing) { content() }
            } else {
                content()
            }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

extension View {
    /// This piece of chrome on Liquid Glass (`NWChromeGlass`), or on `fallback`.
    func nwChromeGlass<S: Shape, F: View>(in shape: S, tint: NightWatch.RGBA = NightWatch.Palette.chromeGlass, interactive: Bool = true,
                                          @ViewBuilder fallback: () -> F) -> some View {
        modifier(NWChromeGlass(shape: shape, tint: tint, interactive: interactive, fallback: fallback()))
    }

    /// The glass's identity in its group (`NWChromeGlassID`).
    func nwChromeGlassID<ID: Hashable & Sendable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        modifier(NWChromeGlassID(id: id, namespace: namespace))
    }
}
