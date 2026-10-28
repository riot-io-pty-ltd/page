import SwiftUI

/// Drives an animation from the clock, or holds one still frame when Reduce
/// Motion is on, the render harness pins a time, or `active` is false (a
/// still pulse runs no clock at all). `content` gets seconds. `fps` caps the
/// redraw rate: 30 for the aurora's slow ribbons (the blurred layers are
/// costly at 120 Hz), lower for a slow breath; nothing redraws while the app
/// is backgrounded or the screen is covered.
struct NWAnimated<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwFixedPhase) private var fixed
    @Environment(\.nwAnimationsPaused) private var covered
    @Environment(\.scenePhase) private var scenePhase
    var fps: Double
    var active: Bool
    var content: (Double) -> Content

    init(fps: Double = 30, active: Bool = true, @ViewBuilder content: @escaping (Double) -> Content) {
        self.fps = fps
        self.active = active
        self.content = content
    }

    var body: some View {
        if reduceMotion || fixed != nil || !active {
            content(fixed ?? 2.0)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / max(1, min(fps, 30)), paused: covered || scenePhase != .active)) { tl in
                content(tl.date.timeIntervalSinceReferenceDate)
            }
        }
    }
}

/// The curtains' phase at clock time `seconds`: the boards' u_speed (0.4 at a
/// palette speed of 1) accumulated by the view's `AuroraPhaseClock`, so a
/// time-of-day tick, a mood change or the exhale changes the pace without a
/// jump. A still frame (the harness's pinned time, Reduce Motion) is the plain
/// product, so a pinned frame is the same frame every time.
enum NWAuroraPhase {
    static func at(_ seconds: Double, palette: NightWatch.AuroraPalette, clock: AuroraPhaseClock, still: Bool) -> Double {
        let rate = 0.4 * palette.speed
        return still ? seconds * rate : clock.advance(to: seconds, rate: rate)
    }
}

/// The aurora itself: a sky gradient, soft ribbons that drift, upward rays
/// and a scatter of stars. `seconds` moves it; the palette's `intensity`
/// scales it (0 draws only the sky, as at dusk).
struct NWAuroraCanvas: View {
    var palette: NightWatch.AuroraPalette
    var seconds: Double
    /// How much of the star field is left: it fades with the dusk, as the shader's does.
    var starField: Double = 1
    @Environment(\.nwFixedPhase) private var fixed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The ribbons' phase, accumulated so a change of speed never jumps them.
    @State private var clock = AuroraPhaseClock()

    var body: some View {
        // Read once per draw, outside the Canvas closure.
        let t = NWAuroraPhase.at(seconds, palette: palette, clock: clock, still: fixed != nil || reduceMotion)
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [palette.skyTop.color, palette.skyBottom.color]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            guard palette.intensity > 0 else { stars(ctx, w, h, 0.3 * starField); return }

            let k = palette.intensity

            // Ribbons: soft wavy bands across the header.
            let bands: [(Int, Double, Double, Double, Double)] = [
                // index, vertical centre, line width (share of height), alpha, blur
                (0, 0.56, 0.22, 0.95, 18), (1, 0.44, 0.15, 0.55, 14), (2, 0.66, 0.17, 0.45, 20)
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
                layer.stroke(path, with: .color(colors[n].opacity(alpha * k * 0.8).color),
                             style: StrokeStyle(lineWidth: h * CGFloat(lw), lineCap: .round))
            }

            // Rays: streaks of varied width and reach rising from the main ribbon.
            var rays = ctx
            rays.addFilter(.blur(radius: 3))
            rays.blendMode = .plusLighter
            for i in 0..<34 {
                let seed = abs(sin(Double(i) * 12.9898) * 43758.5453).truncatingRemainder(dividingBy: 1)
                let seed2 = abs(sin(Double(i) * 78.233 + 1.3) * 24634.6345).truncatingRemainder(dividingBy: 1)
                let u = (Double(i) + seed * 0.8) / 34
                let x = w * CGFloat(u)
                let wobble: Double = 0.7 + 0.3 * sin(Double(i) * 1.9 + t * 1.4)
                let reach: CGFloat = h * CGFloat(0.16 + 0.34 * seed2 * wobble)
                let yMid = h * CGFloat(0.58 + 0.07 * sin(u * 5.2 + t))
                let width = CGFloat(1.4 + 3.0 * seed)
                let rect = CGRect(x: x, y: yMid - reach, width: width, height: reach)
                let c = colors[i % 2]
                rays.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .linearGradient(
                    Gradient(colors: [c.opacity(0).color, c.opacity((0.30 + 0.40 * seed2) * k).color]),
                    startPoint: CGPoint(x: x, y: rect.minY), endPoint: CGPoint(x: x, y: rect.maxY)))
            }
            stars(ctx, w, h, (0.4 + 0.6 * k) * starField)
        }
    }

    private func stars(_ ctx: GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ strength: Double) {
        guard strength > 0.005 else { return }
        for i in 0..<40 {
            let sx = abs(sin(Double(i) * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
            let sy = abs(sin(Double(i) * 12.9898 + 4.1) * 24634.6345).truncatingRemainder(dividingBy: 1)
            let twinkle = 0.5 + 0.5 * sin(seconds * 0.8 + Double(i))
            let r: CGFloat = i % 7 == 0 ? 1.2 : 0.7
            let p = CGPoint(x: w * CGFloat(sx), y: h * CGFloat(sy) * 0.85)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(Color.white.opacity((0.25 + 0.4 * twinkle) * strength)))
        }
    }
}

/// The rounded-triangle glyph at the heart of the pulse.
struct NWPulseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let top = CGPoint(x: rect.minX + w * 0.5, y: rect.minY + h * 0.06)
        let right = CGPoint(x: rect.minX + w * 0.95, y: rect.minY + h * 0.86)
        let left = CGPoint(x: rect.minX + w * 0.05, y: rect.minY + h * 0.86)
        let r = min(w, h) * 0.26
        var p = Path()
        p.move(to: CGPoint(x: (top.x + left.x) / 2, y: (top.y + left.y) / 2))
        p.addArc(tangent1End: top, tangent2End: right, radius: r)
        p.addArc(tangent1End: right, tangent2End: left, radius: r)
        p.addArc(tangent1End: left, tangent2End: top, radius: r)
        p.closeSubpath()
        return p
    }
}


extension NightWatch.AuroraPalette {
    /// Part-way from this palette to `other` (0 = self, 1 = other): how the
    /// aurora settles after the last item clears, fades to dusk and comes
    /// back at dawn, as one sky rather than a cut.
    func mixed(with other: NightWatch.AuroraPalette, _ t: Double) -> NightWatch.AuroraPalette {
        let k = max(0, min(1, t))
        if k == 0 { return self }
        if k == 1 { return other }
        return NightWatch.AuroraPalette(c1: c1.mixed(with: other.c1, k), c2: c2.mixed(with: other.c2, k), c3: c3.mixed(with: other.c3, k),
                                        skyTop: skyTop.mixed(with: other.skyTop, k), skyBottom: skyBottom.mixed(with: other.skyBottom, k),
                                        intensity: intensity + (other.intensity - intensity) * k, speed: speed + (other.speed - speed) * k)
    }

    /// The same mix, perceptually (`PerceptualMix`): how the needs-you aurora
    /// settles in the exhale. The curtains keep their chroma (half way they
    /// are an aurora green and rose, not khaki and mauve), the sky behind them
    /// meets at a neutral night, and the light lifts a little through the
    /// middle, the one long breath out. Dusk and dawn keep the plain blend.
    /// The Mac's is the same.
    func mixedPerceptual(with other: NightWatch.AuroraPalette, _ t: Double) -> NightWatch.AuroraPalette {
        let k = max(0, min(1, t))
        if k == 0 { return self }
        if k == 1 { return other }
        let lift = 0.2 * sin(Double.pi * k)
        return NightWatch.AuroraPalette(c1: c1.mixedPerceptual(with: other.c1, k), c2: c2.mixedPerceptual(with: other.c2, k),
                                        c3: c3.mixedPerceptual(with: other.c3, k),
                                        skyTop: skyTop.mixedPerceptual(with: other.skyTop, k, keepChroma: false),
                                        skyBottom: skyBottom.mixedPerceptual(with: other.skyBottom, k, keepChroma: false),
                                        intensity: intensity + (other.intensity - intensity) * k + lift, speed: speed + (other.speed - speed) * k)
    }
}

extension NightWatch.RGBA {
    /// Part-way to `other` through OKLCH (`PerceptualMix`), for the exhale:
    /// amber reaches teal by way of a bright green, never khaki.
    func mixedPerceptual(with other: NightWatch.RGBA, _ t: Double, keepChroma: Bool = true) -> NightWatch.RGBA {
        let k = max(0, min(1, t))
        if k == 0 { return self }
        if k == 1 { return other }
        let c = PerceptualMix.mix((r, g, b), (other.r, other.g, other.b), k, keepChroma: keepChroma)
        return NightWatch.RGBA(c.r, c.g, c.b, a + (other.a - a) * k)
    }
}

extension PulseModel.Mode {
    /// Star-white quiet, teal working, amber waiting, a violet dusk.
    var tone: NightWatch.RGBA {
        switch self {
        case .quiet: return NightWatch.Palette.star
        case .working: return NightWatch.Palette.teal
        case .waiting: return NightWatch.Palette.amber
        case .dusk: return NightWatch.Palette.violet
        }
    }
}

/// THE PULSE: one glyph for everything (`PulseModel` for the timing). Still
/// star-white when quiet; a teal breath every 4 s while agents work, a little
/// quicker with more of them; an amber ripple when something needs you, one
/// ring per waiting item, faster the longer the oldest has waited (never more
/// than one ring every 1.5 s); a dim low glow at dusk. After the last item
/// clears, `exhale` (seconds since) turns it amber to teal over 800 ms with
/// one long breath out. Reduce Motion: a static ring with the count.
///
/// A still pulse runs no clock; a breath redraws at 20 fps, a ripple at 30.
/// `halo` false leaves the glow and rings to a layer drawn behind it (the
/// Horizon's Metal pulse), so the two never double up.
struct NWPulseOrb: View {
    enum Style: Equatable {
        case needsYou, working, quiet, dusk
        /// A problem: the pulse goes hollow. Slate when the Mac is simply
        /// not there, amber when something needs fixing.
        case hollowSlate, hollowAmber

        init(_ mood: NowModel.Mood) {
            switch mood {
            case .needsYou: self = .needsYou
            case .working: self = .working
            case .quiet: self = .quiet
            case .dusk: self = .dusk
            }
        }

        /// The pulse a style stands for when no counts are given (widgets,
        /// the gallery): two waiting, one working.
        var defaultModel: PulseModel {
            switch self {
            case .needsYou: return PulseModel(working: 0, waiting: 2)
            case .working: return PulseModel(working: 1, waiting: 0)
            case .quiet, .hollowSlate, .hollowAmber: return PulseModel(working: 0, waiting: 0)
            case .dusk: return PulseModel(working: 0, waiting: 0, paused: true)
            }
        }
    }
    var style: Style
    /// The counts behind the pulse; `style.defaultModel` when nil.
    var model: PulseModel? = nil
    /// Seconds since the last waiting item cleared, while the exhale plays.
    var exhale: Double? = nil
    var halo = true
    /// Draws this moment (seconds) with no clock of its own: the caller's
    /// timeline drives it (the Horizon runs one clock for sky and pulse).
    var time: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pulse: PulseModel { model ?? style.defaultModel }
    private var hollow: Bool { style == .hollowSlate || style == .hollowAmber }
    private var exhaling: Bool { exhale.map { !PulseModel.exhale(elapsed: $0).finished } ?? false }

    /// The colour now: the mode's, or part-way from amber during the exhale.
    private var color: NightWatch.RGBA { Self.color(style: style, pulse: pulse, exhale: exhale) }

    static func color(style: Style, pulse: PulseModel, exhale: Double?) -> NightWatch.RGBA {
        switch style {
        case .hollowSlate: return NightWatch.RGBA(hex: 0x8A93A8)
        case .hollowAmber: return NightWatch.Palette.amber
        default:
            let base = pulse.mode.tone
            guard let e = exhale else { return base }
            return NightWatch.Palette.amber.mixedPerceptual(with: base, PulseModel.exhale(elapsed: e).colour)
        }
    }

    var body: some View {
        Group {
            if let time {
                frame(time)
            } else {
                NWAnimated(fps: exhaling ? 30 : pulse.framesPerSecond, active: !hollow && (pulse.isAnimated || exhaling)) { t in
                    frame(t)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func frame(_ t: Double) -> some View {
        let mode = hollow ? PulseModel.Mode.quiet : pulse.mode
        let dusk = mode == .dusk
        let quiet = mode == .quiet && !hollow
        let breath = pulse.breath(at: t)
        let swell = exhale.map { PulseModel.exhale(elapsed: $0).swell } ?? 0
        let count = reduceMotion ? pulse.staticCount : nil
        // Reduce Motion keeps the ring and drops the ripples.
        let ripples = reduceMotion || hollow ? [] : pulse.ripples(at: t)
        return GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                if halo {
                    // Ripples: thin rings that open from the core ring outwards and fade.
                    ForEach(Array(ripples.enumerated()), id: \.offset) { _, r in
                        Circle()
                            .stroke(color.opacity(0.62 * r.opacity).color, lineWidth: 1.2)
                            .frame(width: s, height: s)
                            .scaleEffect(0.5 + 0.5 * r.progress)
                    }
                    // The exhale lets one last ring go as it turns.
                    if let e = exhale, swell > 0 {
                        let p = MotionCurve.clamp01(e / PulseModel.exhaleDuration)
                        Circle().stroke(color.opacity(0.45 * (1 - p)).color, lineWidth: 1.2)
                            .frame(width: s, height: s).scaleEffect(0.5 + 0.5 * MotionCurve.easeOut(p))
                    }
                    // Glow.
                    Circle()
                        .fill(RadialGradient(colors: [color.opacity(hollow ? 0.07 : (dusk ? 0.16 : (quiet ? 0.30 : 0.45))).color, color.opacity(0).color],
                                             center: .center, startRadius: 1, endRadius: s * 0.42))
                        .frame(width: s, height: s)
                        .scaleEffect(1 + 0.10 * (breath - 0.5) * 2 * (mode == .working ? 1 : 0) + 0.30 * swell)
                }
                // The ring (none when quiet: still white is just the light).
                Circle()
                    .stroke(color.opacity(dusk ? 0.35 : (quiet ? 0.0 : 0.85)).color, lineWidth: 1.6)
                    .frame(width: s * 0.5, height: s * 0.5)
                    .scaleEffect(1 + (mode == .working ? 0.04 * (breath - 0.5) * 2 : 0) + 0.06 * swell)
                if let count {
                    Text("\(count)")
                        .font(.system(size: s * 0.2, weight: .bold, design: .rounded))
                        .foregroundColor(color.color)
                        .minimumScaleFactor(0.5)
                } else {
                    NWPulseGlyph()
                        .fill(hollow ? AnyShapeStyle(Color.clear)
                              : AnyShapeStyle(RadialGradient(colors: [Color.white.opacity(dusk ? 0.4 : 1), color.opacity(dusk ? 0.3 : 0.92).color],
                                                             center: .center, startRadius: 0, endRadius: s * 0.15)))
                        .overlay(NWPulseGlyph().stroke(color.opacity(dusk ? 0.3 : (hollow ? 0.8 : 0.9)).color, lineWidth: hollow ? 2 : 1.4))
                        .frame(width: s * 0.26, height: s * 0.26)
                        .scaleEffect(1 + (mode == .working ? 0.03 * (breath - 0.5) * 2 : 0))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}
