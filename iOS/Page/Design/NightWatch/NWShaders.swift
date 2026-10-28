import SwiftUI

/// The Metal half of the living backdrop (Shaders/NWNightWatch.metal, ports of
/// the boards' aurora, pulse and glass GLSL), used through `.colorEffect`.
/// Only the app target compiles the shaders; anywhere without them (the
/// widget extension, the macOS proxy renderer) gets the Canvas drawing, so
/// there is always a picture.
enum NWShaders {
    /// The shaders are in this bundle. Checked once.
    static let available: Bool = Bundle.main.url(forResource: "default", withExtension: "metallib") != nil
}

/// The aurora: the Metal port of aurora.glsl when it is there, the Canvas
/// ribbons when it is not. `stars` dims the aurora's own scatter of stars
/// (the dusk). Redrawn by its caller's clock (`NWAnimated`).
struct NWLivingAurora: View {
    var palette: NightWatch.AuroraPalette
    var seconds: Double
    var stars: Double = 1
    @Environment(\.nwFixedPhase) private var fixed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The curtains' phase, accumulated so a change of speed never jumps them.
    @State private var clock = AuroraPhaseClock()

    var body: some View {
        if NWShaders.available {
            // Read once per draw, outside the GeometryReader (its closure may run more than once).
            let phase = AuroraPhaseClock.shaderPhase(NWAuroraPhase.at(seconds, palette: palette, clock: clock, still: fixed != nil || reduceMotion))
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.black)
                    .colorEffect(ShaderLibrary.default.nwAurora(
                        // Wrapped: the raw reference-date clock is frozen at float precision.
                        .float2(geo.size), .float(ShaderClock.seconds(seconds)),
                        // The boards' u_speed is 0.4 at a palette speed of 1 (`NWAuroraPhase`).
                        // The GLSL's 0.9 intensity was drawn for a whole board; behind a phone's
                        // Horizon it drowns the pulse, so it runs at two thirds of that.
                        .float(phase),
                        .color(palette.skyTop.color), .color(palette.skyBottom.color),
                        .color(palette.c1.color), .color(palette.c2.color), .color(palette.c3.color),
                        .float(0.6 * palette.intensity), .float(stars)))
            }
        } else {
            // The Canvas ribbons dim their own stars with the palette's intensity, and with `stars`.
            NWAuroraCanvas(palette: palette, seconds: seconds, starField: stars)
        }
    }
}

/// The pulse's light: the Metal port of pulse.glsl (core, halo and the
/// rings, a little wobbly) behind the glyph, the rings placed from
/// `PulseModel.ripples` so they match the Canvas version exactly. Nil when
/// the shaders are not here: the orb then draws its own halo.
struct NWPulseLight: View {
    var color: NightWatch.RGBA
    var ripples: [PulseModel.Ripple]
    /// 0...1: how much light (dim at dusk, swelling on the exhale).
    var glow: Double
    var seconds: Double

    var body: some View {
        GeometryReader { geo in
            let r = ripples.map(\.progress) + Array(repeating: -1, count: max(0, 4 - ripples.count))
            Rectangle()
                .fill(Color.white)
                .colorEffect(ShaderLibrary.default.nwPulse(
                    .float2(geo.size), .float(ShaderClock.seconds(seconds)),
                    .color(color.mixed(with: NightWatch.RGBA(1, 1, 1), 0.25).color), .color(color.color),
                    .float(0.09), .float(glow),
                    .float4(Float(r[0]), Float(r[1]), Float(r[2]), Float(r[3])), .float(1.0)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// glass.glsl's edge light over a glass surface: the rim catches a light from
/// the top-left with a sheen along it and a fine inner highlight. It is a
/// light, so it follows the Card glow setting (Off draws nothing) and it is
/// still: the sheen is set by `sheen`, not a clock, so glass costs nothing
/// per frame.
struct NWGlassEdgeLight: View {
    var radius: CGFloat
    var sheen: Double = 0.6
    @Environment(\.nwCardGlow) private var glow

    var body: some View {
        if NWShaders.available, glow.isOn {
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.white)
                    .colorEffect(ShaderLibrary.default.nwGlassRim(
                        .float2(geo.size), .float(Float(radius)), .float(sheen),
                        .color(NightWatch.RGBA(hex: 0x9FF5E8).color), .float(0.55 * glow.strength)))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
