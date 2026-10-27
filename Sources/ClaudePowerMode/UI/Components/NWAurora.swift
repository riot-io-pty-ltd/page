import SwiftUI

/// Drives ambient motion from the clock, at most 30 frames a second and only
/// while the surface can be seen; holds one still frame when Reduce Motion is
/// on (or the render harness pins a phase). `content` gets seconds.
struct NWAnimated<Content: View>: View {
    @Environment(\.nwReduceMotion) private var reduceMotion
    @Environment(\.nwFixedPhase) private var fixed
    @Environment(\.nwMotionActive) private var active
    var fps: Double = NWMotionRate.ambient
    /// False when nothing in the content moves (a still pulse, a dusk sky):
    /// one frame, no timeline.
    var moves = true
    var content: (Double) -> Content

    init(fps: Double = NWMotionRate.ambient, moves: Bool = true, @ViewBuilder content: @escaping (Double) -> Content) {
        self.fps = fps
        self.moves = moves
        self.content = content
    }

    var body: some View {
        if reduceMotion || fixed != nil || !moves {
            content(fixed ?? 2.0)
        } else {
            TimelineView(.animation(minimumInterval: 1 / fps, paused: !active)) { tl in
                content(tl.date.timeIntervalSinceReferenceDate)
            }
        }
    }
}

extension NightWatch.AuroraPalette {
    /// Mix towards `other` by `t` (0 = self, 1 = other), every field.
    func mixed(with other: NightWatch.AuroraPalette, _ t: Double) -> NightWatch.AuroraPalette {
        let k = min(1, max(0, t))
        if k <= 0 { return self }
        if k >= 1 { return other }
        return NightWatch.AuroraPalette(
            c1: c1.mixed(with: other.c1, k), c2: c2.mixed(with: other.c2, k), c3: c3.mixed(with: other.c3, k),
            skyTop: skyTop.mixed(with: other.skyTop, k), skyBottom: skyBottom.mixed(with: other.skyBottom, k),
            intensity: intensity + (other.intensity - intensity) * k, speed: speed + (other.speed - speed) * k)
    }

    /// The same mix, perceptually (`PerceptualMix`): how the needs-you aurora
    /// settles in the exhale. The curtains keep their chroma (half way they are
    /// an aurora green and rose, not khaki and mauve), the sky behind them meets
    /// at a neutral night, and the light lifts a little through the middle, the
    /// one long breath out. Dusk and dawn keep the plain blend.
    func mixedPerceptual(with other: NightWatch.AuroraPalette, _ t: Double) -> NightWatch.AuroraPalette {
        let k = min(1, max(0, t))
        if k <= 0 { return self }
        if k >= 1 { return other }
        let lift = 0.2 * sin(Double.pi * k)
        return NightWatch.AuroraPalette(
            c1: c1.mixedPerceptual(with: other.c1, k), c2: c2.mixedPerceptual(with: other.c2, k),
            c3: c3.mixedPerceptual(with: other.c3, k),
            skyTop: skyTop.mixedPerceptual(with: other.skyTop, k, keepChroma: false),
            skyBottom: skyBottom.mixedPerceptual(with: other.skyBottom, k, keepChroma: false),
            intensity: intensity + (other.intensity - intensity) * k + lift, speed: speed + (other.speed - speed) * k)
    }

    /// Paused for battery, settled: the dusk gone to near-black, horizon only
    /// (board 07, "paused · horizon only"). The same values as the phone's.
    static let night = NightWatch.AuroraPalette(
        c1: NightWatch.RGBA(hex: 0x2A2440), c2: NightWatch.RGBA(hex: 0x16131F), c3: NightWatch.RGBA(hex: 0x16131F),
        skyTop: NightWatch.RGBA(hex: 0x0B0B14), skyBottom: NightWatch.RGBA(hex: 0x07080D), intensity: 0, speed: 0)

    /// The sky `duskMix` (0...1) of the way from `self` into the night: purple
    /// dusk at the halfway point, dark by the end.
    func towardNight(_ duskMix: Double) -> NightWatch.AuroraPalette {
        let d = min(1, max(0, duskMix))
        return d < 0.5 ? mixed(with: .dusk, d * 2) : NightWatch.AuroraPalette.dusk.mixed(with: .night, (d - 0.5) * 2)
    }
}

extension NightWatch.RGBA {
    /// Part-way to `other` through OKLCH (`PerceptualMix`), for the exhale:
    /// amber reaches teal by way of a bright green, never khaki.
    func mixedPerceptual(with other: NightWatch.RGBA, _ t: Double, keepChroma: Bool = true) -> NightWatch.RGBA {
        let k = min(1, max(0, t))
        if k <= 0 { return self }
        if k >= 1 { return other }
        let c = PerceptualMix.mix((r, g, b), (other.r, other.g, other.b), k, keepChroma: keepChroma)
        return NightWatch.RGBA(c.r, c.g, c.b, a + (other.a - a) * k)
    }
}

// MARK: - Sky state

/// One session's star in the header sky (shown for dusk and dawn). Placed by a
/// hash of its id, so a session keeps its place.
struct NWSkyStar: Equatable, Identifiable {
    let id: String
    /// 0...1 across.
    let x: Double
    /// 0 = top ... 1 = horizon.
    let y: Double
    /// Brightness; 1 = lit, a little over 1 while flaring.
    var light: Double

    /// Pure. A stable spot for `id` in the upper sky.
    static func place(id: String, light: Double) -> NWSkyStar {
        var h: UInt64 = 1469598103934665603
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        let x = 0.08 + 0.62 * Double(h & 0xFFFF) / 65535      // the left two thirds: the pulse sits at the right
        let y = 0.16 + 0.5 * Double((h >> 16) & 0xFFFF) / 65535
        return NWSkyStar(id: id, x: x, y: y, light: light)
    }
}

/// What the sky is doing besides its palette: the horizon band, dawn rising,
/// and the working stars.
struct NWSky: Equatable {
    /// 0...1 the grey horizon band.
    var horizon: Double = 0
    /// 0...1 dawn's front, up from the horizon.
    var dawnFront: Double = 0
    /// 0...1 dawn's warm light.
    var dawnGlow: Double = 0
    /// How much of the background star field is left (dims at dusk).
    var starField: Double = 1
    var stars: [NWSkyStar] = []
    /// The horizon's height as a share of the header, from the top.
    var horizonAt: Double = 0.86

    static let clear = NWSky()
}

// MARK: - Aurora (Canvas fallback)

/// The aurora drawn with Canvas: a sky gradient, a few soft ribbons that
/// drift, upward rays and a scatter of stars. `seconds` moves it; the
/// palette's `intensity` scales it (0 draws only the sky, as at dusk). Used
/// before macOS 14, when the shader library will not load, and in renders
/// that can't capture shaders.
struct NWAuroraCanvas: View {
    var palette: NightWatch.AuroraPalette
    var seconds: Double
    var sky: NWSky = .clear

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [palette.skyTop.color, palette.skyBottom.color]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            if palette.intensity > 0 { drawCurtains(&ctx, w: w, h: h) }

            // Background stars.
            if sky.starField > 0.01 {
                for i in 0..<34 {
                    let sx = abs(sin(Double(i) * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
                    let sy = abs(sin(Double(i) * 12.9898 + 4.1) * 24634.6345).truncatingRemainder(dividingBy: 1)
                    let twinkle = 0.5 + 0.5 * sin(seconds * 0.8 + Double(i))
                    let r: CGFloat = i % 7 == 0 ? 1.1 : 0.6
                    let p = CGPoint(x: w * CGFloat(sx), y: h * CGFloat(sy) * 0.8)
                    let k = max(palette.intensity, 0.3)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(Color.white.opacity((0.25 + 0.4 * twinkle) * (0.4 + 0.6 * k) * sky.starField)))
                }
            }

            // Dawn: warm light behind a front rising from the horizon.
            if sky.dawnGlow > 0.005 {
                let horizonY = h * CGFloat(sky.horizonAt)
                let frontY = horizonY - horizonY * CGFloat(sky.dawnFront)
                let warm = NightWatch.RGBA(hex: 0xF5B14C)
                let peach = NightWatch.RGBA(hex: 0xFFD9A0)
                ctx.fill(Path(CGRect(x: 0, y: max(0, frontY - h * 0.2), width: w, height: horizonY - frontY + h * 0.2 + (h - horizonY))),
                         with: .linearGradient(Gradient(stops: [
                            .init(color: peach.opacity(0).color, location: 0),
                            .init(color: peach.opacity(0.16 * sky.dawnGlow).color, location: 0.25),
                            .init(color: warm.opacity(0.42 * sky.dawnGlow).color, location: 0.85),
                            .init(color: warm.opacity(0.2 * sky.dawnGlow).color, location: 1)]),
                            startPoint: CGPoint(x: 0, y: max(0, frontY - h * 0.2)), endPoint: CGPoint(x: 0, y: h)))
            }

        }
    }

    private func drawCurtains(_ ctx: inout GraphicsContext, w: CGFloat, h: CGFloat) {
        let t = seconds * 0.4 * palette.speed
        let k = palette.intensity

        // Ribbons: soft wavy bands across the header.
        let bands: [(Int, Double, Double, Double, Double)] = [
            // index, vertical centre, line width (share of height), alpha, blur
            (0, 0.56, 0.22, 0.95, 12), (1, 0.44, 0.15, 0.55, 9), (2, 0.66, 0.17, 0.45, 14)
        ]
        let colors = [palette.c1, palette.c2, palette.c3]
        for (n, base, lw, alpha, blur) in bands {
            var layer = ctx
            layer.addFilter(.blur(radius: CGFloat(blur)))
            layer.blendMode = .plusLighter
            var path = Path()
            var x: CGFloat = -30
            var first = true
            while x <= w + 30 {
                let u = Double(x / w)
                let slow: Double = 0.07 * sin(u * 5.2 + t + Double(n) * 1.7)
                let fast: Double = 0.04 * sin(u * 11 - t * 1.3 + Double(n))
                let y: CGFloat = h * CGFloat(base + slow + fast)
                if first { path.move(to: CGPoint(x: x, y: y)); first = false } else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 6
            }
            layer.stroke(path, with: .color(colors[n].opacity(alpha * k).color),
                         style: StrokeStyle(lineWidth: h * CGFloat(lw), lineCap: .round))
        }

        // Rays: streaks of varied width and reach rising from the main ribbon.
        var rays = ctx
        rays.addFilter(.blur(radius: 2.6))
        rays.blendMode = .plusLighter
        for i in 0..<34 {
            let seed = abs(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
            let seed2 = abs(sin(Double(i) * 78.233 + 1.3) * 24634.6345).truncatingRemainder(dividingBy: 1)
            let u = (Double(i) + seed * 0.8) / 34
            let x = w * CGFloat(u)
            let reach = h * CGFloat(0.16 + 0.34 * seed2 * (0.7 + 0.3 * sin(Double(i) * 1.9 + t * 1.4)))
            let yMid = h * CGFloat(0.58 + 0.07 * sin(u * 5.2 + t))
            let width = CGFloat(1.2 + 2.8 * seed)
            let rect = CGRect(x: x, y: yMid - reach, width: width, height: reach)
            let c = colors[i % 2]
            rays.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .linearGradient(
                Gradient(colors: [c.opacity(0).color, c.opacity((0.35 + 0.45 * seed2) * k).color]),
                startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: rect.maxY)))
        }
    }
}

// MARK: - Aurora (Metal)

/// The aurora as a Metal shader (aurora.glsl, ported). Same inputs as the Canvas.
@available(macOS 14, *)
struct NWAuroraShaderView: View {
    var library: ShaderLibrary
    var palette: NightWatch.AuroraPalette
    var seconds: Double
    var sky: NWSky = .clear

    var body: some View {
        // A wrapped clock keeps Float precision: seconds since 2001 would be too big.
        let t = Float(seconds.truncatingRemainder(dividingBy: 3600))
        let p = palette
        Rectangle()
            .fill(Color.black)
            .visualEffect { content, proxy in
                content.colorEffect(library.nwAurora(
                    .float2(proxy.size), .float(t),
                    .float3(Float(p.c1.r), Float(p.c1.g), Float(p.c1.b)),
                    .float3(Float(p.c2.r), Float(p.c2.g), Float(p.c2.b)),
                    .float3(Float(p.c3.r), Float(p.c3.g), Float(p.c3.b)),
                    .float3(Float(p.skyTop.r), Float(p.skyTop.g), Float(p.skyTop.b)),
                    .float3(Float(p.skyBottom.r), Float(p.skyBottom.g), Float(p.skyBottom.b)),
                    .float4(Float(p.intensity), Float(p.speed), Float(sky.starField), 0),
                    .float4(Float(sky.dawnFront), Float(sky.dawnGlow), Float(sky.horizon), Float(sky.horizonAt))))
            }
    }
}

/// The sky: shader when it may, Canvas otherwise.
struct NWAuroraSky: View {
    @Environment(\.nwShaders) private var shadersAllowed
    var palette: NightWatch.AuroraPalette
    var seconds: Double
    var sky: NWSky = .clear

    var body: some View {
        if NWShaders.usable(shadersAllowed), #available(macOS 14, *), let lib = NWShaders.library {
            NWAuroraShaderView(library: lib, palette: palette, seconds: seconds, sky: sky)
        } else {
            NWAuroraCanvas(palette: palette, seconds: seconds, sky: sky)
        }
    }
}

/// The working stars over the sky: one per session, dimming together at dusk
/// and relighting one by one at dawn.
struct NWSkyStars: View {
    var stars: [NWSkyStar]

    var body: some View {
        Canvas { ctx, size in
            for s in stars where s.light > 0.01 {
                let p = CGPoint(x: size.width * CGFloat(s.x), y: size.height * CGFloat(s.y))
                let l = min(1.4, s.light)
                let glowR: CGFloat = 5 + 3 * CGFloat(max(0, l - 0.6))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)),
                         with: .radialGradient(Gradient(colors: [Color.white.opacity(0.35 * min(1, l)), .clear]),
                                               center: p, startRadius: 0, endRadius: glowR))
                let r: CGFloat = 1.3 + 0.5 * CGFloat(max(0, l - 1))
                // Dimmed for the pause it is a faint speck, there to be relit, not a lit star.
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                         with: .color(NightWatch.Palette.star.opacity(min(1, 0.1 + 0.9 * l)).color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The grey horizon band that holds while agents are paused for battery:
/// a crisp hairline with a soft glow, drawn above the header's wash.
struct NWHorizonLine: View {
    var strength: Double
    var at: Double

    var body: some View {
        GeometryReader { g in
            let y = g.size.height * CGFloat(at)
            // Over a near-black night it is the one thing left to see, so it is crisp and light.
            ZStack {
                Rectangle()
                    .fill(LinearGradient(colors: [Color(white: 0.72).opacity(0), Color(white: 0.72).opacity(0.28 * strength),
                                                  Color(white: 0.72).opacity(0)], startPoint: .top, endPoint: .bottom))
                    .frame(height: 8)
                    .position(x: g.size.width / 2, y: y)
                Rectangle()
                    .fill(LinearGradient(stops: [.init(color: Color(white: 0.82).opacity(0), location: 0),
                                                 .init(color: Color(white: 0.82).opacity(0.95 * strength), location: 0.08),
                                                 .init(color: Color(white: 0.82).opacity(0.95 * strength), location: 0.92),
                                                 .init(color: Color(white: 0.82).opacity(0), location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width - 28, height: 1.2)
                    .position(x: g.size.width / 2, y: y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The glass rim over the header (glass.glsl, ported): near the top edge and
/// corners the aurora bends outward and blurs, and a slow specular runs along
/// the top-left. Only with shaders; the Canvas path keeps the plain rim.
struct NWGlassRimEffect: ViewModifier {
    @Environment(\.nwShaders) private var shadersAllowed
    var seconds: Double
    var radius: CGFloat

    func body(content: Content) -> some View {
        if NWShaders.usable(shadersAllowed), #available(macOS 14, *), let lib = NWShaders.library {
            let t = Float(seconds.truncatingRemainder(dividingBy: 3600))
            let edge = NightWatch.RGBA(hex: 0x9FF5E8)
            content.visualEffect { c, proxy in
                c.layerEffect(lib.nwGlass(.float2(proxy.size), .float(t),
                                          .float4(Float(radius), 6, 12, 1),
                                          .float3(Float(edge.r), Float(edge.g), Float(edge.b))),
                              maxSampleOffset: CGSize(width: 10, height: 10))
            }
        } else {
            content
        }
    }
}

// MARK: - Header

/// The header of a Now surface: aurora, a wash that darkens into the body, the
/// headline and subline at the left, and the pulse at the right.
struct NWAuroraHeader: View {
    var palette: NightWatch.AuroraPalette
    var headline: String
    var subline: String
    var pulse: NWPulseOrb.Style = .working
    var height: CGFloat = 92
    var showsPulse = true
    /// The pulse's counts and the exhale; nil draws `pulse` with one of everything.
    var pulseInputs: NWPulseInputs? = nil
    var sky: NWSky = .clear
    /// "N working" in the headline or subline becomes a button that jumps to
    /// the In-flight cards. nil: plain text (every other surface).
    var onWorkingTap: (() -> Void)? = nil
    /// The pulse becomes a button that opens Settings. nil: just the glyph.
    var onPulseTap: (() -> Void)? = nil

    /// The header's height in the popover.
    static let headerHeight: CGFloat = 92

    /// Where the pulse's centre sits, from the header's top-right corner.
    static let pulseInset = CGSize(width: 14 + 30, height: 10 + 30)

    var body: some View {
        ZStack(alignment: .topLeading) {
            // A settled dusk has no curtains and no dawn: nothing to tick for.
            NWAnimated(moves: palette.intensity > 0.001 || sky.dawnGlow > 0.001) { t in
                ZStack {
                    NWAuroraSky(palette: palette, seconds: t, sky: sky)
                    // Darken towards the body, as on the boards.
                    LinearGradient(stops: [.init(color: NightWatch.Palette.backgroundDeep.opacity(0.0).color, location: 0),
                                           .init(color: NightWatch.Palette.backgroundDeep.opacity(0.18).color, location: 0.45),
                                           .init(color: NightWatch.Palette.popoverBody.color, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        // Thinned while dawn's light rises from the horizon, so it shows; a
                        // paused sky keeps the full wash (the horizon line is drawn above it).
                        .opacity(1 - 0.45 * min(1, sky.dawnGlow * 4))
                }
                .modifier(NWGlassRimEffect(seconds: t, radius: NightWatch.Radius.popover))
            }
            if sky.horizon > 0.005 { NWHorizonLine(strength: sky.horizon, at: sky.horizonAt) }
            if !sky.stars.isEmpty { NWSkyStars(stars: sky.stars) }
            VStack(alignment: .leading, spacing: 4) {
                NWHeaderLine(text: headline, font: NightWatch.Typo.headline, kerning: NightWatch.Typo.headlineTracking,
                             color: NightWatch.Palette.textPrimary, onWorkingTap: onWorkingTap)
                NWHeaderLine(text: subline, font: NightWatch.Typo.subline, kerning: 0,
                             color: NightWatch.Palette.textSecondary, onWorkingTap: onWorkingTap)
            }
            .padding(.leading, 18)
            .padding(.top, 20)
            .padding(.trailing, showsPulse ? 70 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsPulse {
                pulseView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 10)
                    .padding(.trailing, 14)
            }
        }
        .frame(height: height)
        .clipped()
    }

    /// The pulse, 60 pt square (its centre anchors the arriving cards' contrails, so a
    /// button around it never moves it).
    @ViewBuilder
    private var pulseView: some View {
        let orb = NWPulseOrb(inputs: pulseInputs ?? NWPulseInputs(style: pulse)).frame(width: 60, height: 60)
        if let tap = onPulseTap {
            Button(action: tap) { orb.contentShape(Circle()) }
                .buttonStyle(.plain)
                .overlay(NWCursorRect(cursor: .pointingHand))
                .help("Settings")
                .accessibilityLabel(Text("Settings"))
                .accessibilityHint(Text("Opens Page's settings"))
        } else {
            orb
        }
    }
}

/// One line of the header's words. With `onWorkingTap`, the "N working" in it
/// is a button (underlined on hover, with a pointing hand); the rest is plain text.
struct NWHeaderLine: View {
    var text: String
    var font: Font
    var kerning: CGFloat
    var color: NightWatch.RGBA
    var onWorkingTap: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        if let tap = onWorkingTap, let part = WorkingPhrase.split(text) {
            HStack(spacing: 0) {
                if !part.before.isEmpty { line(part.before) }
                Button(action: tap) {
                    line(part.token).underline(hovering, color: color.opacity(0.7).color)
                }
                .buttonStyle(.plain)
                .layoutPriority(1)
                .onHover { hovering = $0 }
                .overlay(NWCursorRect(cursor: .pointingHand))
                .help("Show the sessions in flight")
                .accessibilityLabel(Text(part.token))
                .accessibilityHint(Text("Shows the working sessions"))
                if !part.after.isEmpty { line(part.after) }
            }
        } else {
            line(text)
        }
    }

    private func line(_ s: String) -> Text {
        Text(s).font(font).kerning(kerning).foregroundColor(color.color)
    }
}

/// A pointing-hand cursor over the view it overlays, through AppKit's own
/// cursor rects (no push and pop to get out of balance when a panel closes
/// under the pointer). Mouse events pass straight through it.
struct NWCursorRect: NSViewRepresentable {
    var cursor: NSCursor

    func makeNSView(context: Context) -> NSView { CursorView(cursor: cursor) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CursorView)?.cursor = cursor
        nsView.window?.invalidateCursorRects(for: nsView)
    }

    private final class CursorView: NSView {
        var cursor: NSCursor
        init(cursor: NSCursor) {
            self.cursor = cursor
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }
        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }
    }
}

// MARK: - Pulse

/// What the pulse shows: its style, how many are waiting or working, the
/// longest wait (ripple rate), and when the last Decide item cleared.
struct NWPulseInputs: Equatable {
    var style: NWPulseOrb.Style
    var waiting: Int = 1
    var agents: Int = 1
    var longestWait: TimeInterval = 0
    /// The last Decide item cleared then: amber exhales to teal from it.
    var clearedAt: Date? = nil
    /// Rings that were out when it cleared (they fade during the exhale).
    var clearedRings: Int = 0
}

/// The pulse: one glyph for everything (signature motion 1). Still star-white
/// when quiet; a teal breath at 4 s (a little faster with more agents) while
/// they work; amber with one ripple ring per waiting item, quicker the longer
/// the wait, never more than one every 1.5 s; a dim low glow at dusk. When the
/// last waiting item clears it exhales from amber to teal over 800 ms. Reduce
/// Motion: a still ring, and the waiting count beside it.
struct NWPulseOrb: View {
    enum Style: Equatable { case needsYou, working, quiet, dusk }
    var inputs: NWPulseInputs
    @Environment(\.nwReduceMotion) private var reduceMotion
    @Environment(\.nwShaders) private var shadersAllowed

    init(style: Style) { inputs = NWPulseInputs(style: style) }
    init(inputs: NWPulseInputs) { self.inputs = inputs }

    var style: Style { inputs.style }

    /// Ring and ripple geometry inside the 60 pt frame.
    static let ringRadius: CGFloat = 13
    static let rippleOuter: CGFloat = 36
    static let coreRadius: CGFloat = 5.5
    /// The soft layer (halo and ripples) is larger than the 60 pt frame, so
    /// the outer rings are not cut; it fades to nothing before its edge.
    static let softSide: CGFloat = 92

    var body: some View {
        ZStack {
            if let cleared = inputs.clearedAt, style != .needsYou, style != .dusk, !reduceMotion {
                NWOneShot(start: cleared, duration: 1.45, fps: NWMotionRate.ambient) { now in
                    NWAnimated { t in drawing(t: t, exhale: PulseModel.exhale(elapsed: now.timeIntervalSince(cleared))) }
                }
            } else {
                // Quiet is still and dusk is a low glow: only breath and ripple tick.
                NWAnimated(moves: style == .working || style == .needsYou) { t in drawing(t: t, exhale: nil) }
            }
        }
        .accessibilityHidden(true)
    }

    private func baseColor(exhale: PulseModel.Exhale?) -> NightWatch.RGBA {
        switch style {
        case .needsYou: return NightWatch.Palette.amber
        case .dusk: return NightWatch.Palette.violet
        case .working, .quiet:
            guard let x = exhale, !x.finished else {
                return style == .working ? NightWatch.Palette.teal : NightWatch.Palette.star
            }
            let teal = NightWatch.Palette.amber.mixedPerceptual(with: NightWatch.Palette.teal, x.tealMix)
            return style == .quiet ? teal.mixedPerceptual(with: NightWatch.Palette.star, x.starMix) : teal
        }
    }

    @ViewBuilder
    private func drawing(t: Double, exhale: PulseModel.Exhale?) -> some View {
        let color = baseColor(exhale: exhale)
        let still = reduceMotion
        let breath = (style == .working && !still) ? PulseModel.breath(at: t, agents: inputs.agents) : 0.5
        let swell = exhale.map { $0.finished ? 0 : $0.swell } ?? 0
        let rings: [PulseModel.Ring] = {
            if still { return [] }
            if style == .needsYou { return PulseModel.rings(at: t, waiting: inputs.waiting, longestWait: inputs.longestWait) }
            if let x = exhale, !x.finished, inputs.clearedRings > 0 {
                return PulseModel.rings(at: t, waiting: inputs.clearedRings, longestWait: 0)
                    .map { PulseModel.Ring(progress: $0.progress, alpha: $0.alpha * x.ringFade) }
            }
            return []
        }()
        let showsRing = style != .quiet || (exhale.map { !$0.finished && $0.starMix < 1 } ?? false)
        let dim = style == .dusk
        let glow = dim ? PulseModel.pausedGlow * 2 : (style == .quiet ? 0.42 : 0.55)

        ZStack {
            // Soft parts: halo and ripples (shader when it may).
            NWPulseSoft(color: color, t: t, rings: rings, glow: glow * (1 + 0.25 * breath) * (1 + 2 * swell),
                        shaders: NWShaders.usable(shadersAllowed))
                .scaleEffect(1 + 0.12 * breath + swell)
            // The dot's own ring.
            if showsRing {
                Circle()
                    .stroke(color.opacity(dim ? 0.3 : 0.88).color, lineWidth: 1.5)
                    .frame(width: Self.ringRadius * 2, height: Self.ringRadius * 2)
                    .scaleEffect(1 + 0.045 * breath + 0.5 * swell)
                    .opacity(style == .quiet ? (1 - (exhale?.starMix ?? 1)) : 1)
            }
            // Reduce Motion: a still ring where the ripple would be.
            if still && style == .needsYou {
                Circle()
                    .stroke(color.opacity(0.5).color, lineWidth: 1.2)
                    .frame(width: 42, height: 42)
            }
            // The core: white-hot centre, coloured rim.
            Circle()
                .fill(RadialGradient(colors: [Color.white.opacity(dim ? 0.35 : 1),
                                              color.opacity(dim ? 0.3 : 0.92).color],
                                     center: .center, startRadius: 0, endRadius: Self.coreRadius + 1))
                .frame(width: Self.coreRadius * 2, height: Self.coreRadius * 2)
                .scaleEffect(1 + 0.06 * breath)
            if still && style == .needsYou && inputs.waiting > 0 {
                Text(inputs.waiting > 99 ? "99+" : "\(inputs.waiting)")
                    .font(Font.system(size: 9, weight: .heavy))
                    .foregroundColor(NightWatch.Palette.backgroundDeep.color)
                    .padding(.horizontal, 3.5)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Capsule().fill(color.color))
                    .offset(x: 17, y: 15)
            }
        }
        .frame(width: 60, height: 60)
    }
}

/// The pulse's halo and ripple rings: the pulse.glsl shader on macOS 14+,
/// circles otherwise.
private struct NWPulseSoft: View {
    var color: NightWatch.RGBA
    var t: Double
    var rings: [PulseModel.Ring]
    var glow: Double
    var shaders: Bool

    var body: some View {
        if shaders, #available(macOS 14, *), let lib = NWShaders.library {
            let edge = color.mixed(with: NightWatch.RGBA(1, 1, 1), 0.15)
            let flat = rings.flatMap { [Float($0.progress), Float($0.alpha)] }
            Rectangle()
                .fill(Color.black)
                .frame(width: NWPulseOrb.softSide, height: NWPulseOrb.softSide)
                .visualEffect { content, proxy in
                    content.colorEffect(lib.nwPulse(
                        .float2(proxy.size), .float(Float(t.truncatingRemainder(dividingBy: 3600))),
                        .float3(Float(color.r), Float(color.g), Float(color.b)),
                        .float3(Float(edge.r), Float(edge.g), Float(edge.b)),
                        .float4(Float(NWPulseOrb.coreRadius), Float(NWPulseOrb.ringRadius), Float(NWPulseOrb.rippleOuter), Float(glow)),
                        .floatArray(flat.isEmpty ? [0, 0] : flat)))
                }
        } else {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(0.55 * min(1.4, glow / 0.55)).color, color.opacity(0).color],
                                         center: .center, startRadius: 1, endRadius: 26))
                    .frame(width: 60, height: 60)
                ForEach(Array(rings.enumerated()), id: \.offset) { _, r in
                    let radius = NWPulseOrb.ringRadius + (NWPulseOrb.rippleOuter - NWPulseOrb.ringRadius) * CGFloat(r.progress)
                    Circle()
                        .stroke(color.opacity(0.85 * r.alpha).color, lineWidth: 1.1)
                        .frame(width: radius * 2, height: radius * 2)
                }
            }
            .frame(width: NWPulseOrb.softSide, height: NWPulseOrb.softSide)
        }
    }
}
