import SwiftUI

/// Drives an animation from the clock, or holds one still frame when Reduce
/// Motion is on (or the render harness pins a time). `content` gets seconds.
struct NWAnimated<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwFixedPhase) private var fixed
    @Environment(\.nwAnimationsPaused) private var covered
    @Environment(\.scenePhase) private var scenePhase
    var content: (Double) -> Content

    init(@ViewBuilder content: @escaping (Double) -> Content) { self.content = content }

    var body: some View {
        if reduceMotion || fixed != nil {
            content(fixed ?? 2.0)
        } else {
            // 30 fps is plenty for slow ribbons (the blurred layers are costly at
            // 120 Hz), and nothing redraws while the app is backgrounded or covered.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: covered || scenePhase != .active)) { tl in
                content(tl.date.timeIntervalSinceReferenceDate)
            }
        }
    }
}

/// The aurora itself: a sky gradient, soft ribbons that drift, upward rays
/// and a scatter of stars. `seconds` moves it; the palette's `intensity`
/// scales it (0 draws only the sky, as at dusk).
struct NWAuroraCanvas: View {
    var palette: NightWatch.AuroraPalette
    var seconds: Double

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .linearGradient(
                Gradient(colors: [palette.skyTop.color, palette.skyBottom.color]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            guard palette.intensity > 0 else { stars(ctx, w, h, 0.3); return }

            let t = seconds * 0.4 * palette.speed
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
            stars(ctx, w, h, 0.4 + 0.6 * k)
        }
    }

    private func stars(_ ctx: GraphicsContext, _ w: CGFloat, _ h: CGFloat, _ strength: Double) {
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

/// The Horizon: the top of the Now screen. Aurora behind, the pulse in the
/// middle, the one honest sentence below it. It fades into the page, so it
/// has no edge of its own to look cut off.
struct NWHorizon: View {
    var palette: NightWatch.AuroraPalette
    var pulse: NWPulseOrb.Style
    var headline: String
    var subline: String
    /// A third, quieter line ("Page is keeping watch. Go to sleep.").
    var footnote: String? = nil
    var height: CGFloat = 330
    /// Space kept clear at the top for the status bar and the Mac chip.
    var topInset: CGFloat = 0

    private var orbSize: CGFloat { min(150, max(96, height - 112)) }

    var body: some View {
        ZStack(alignment: .top) {
            NWAnimated { t in NWAuroraCanvas(palette: palette, seconds: t) }
            // Fade into the page.
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: NightWatch.Palette.backgroundDeep.opacity(0.0).color, location: 0.35),
                                   .init(color: NightWatch.Palette.backgroundDeep.opacity(0.85).color, location: 0.88),
                                   .init(color: NightWatch.Palette.backgroundDeep.color, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                // The orb shrinks with a short Horizon so the headline never rides over it.
                NWPulseOrb(style: pulse)
                    .frame(width: orbSize, height: orbSize)
                    .padding(.top, topInset + 38)
                Spacer(minLength: 0)
                Text(headline)
                    .font(NightWatch.Typo.hero)
                    .kerning(NightWatch.Typo.heroTracking)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                Text(subline)
                    .font(NightWatch.Typo.subline)
                    .foregroundColor(NightWatch.Palette.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.bottom, footnote == nil ? 14 : 0)
                if let footnote {
                    Text(footnote).font(NightWatch.Typo.subline)
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2).padding(.bottom, 14)
                }
            }
            .padding(.horizontal, NightWatch.Space.xl)
        }
        .frame(height: height + topInset)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(headline). \(subline)"))
        .accessibilityAddTraits(.isHeader)
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

/// The pulse: one glyph for everything. Amber with a ripple per waiting item
/// when something needs you, teal breathing while agents work, still
/// star-white when quiet, a dim low glow at dusk. Reduce Motion: a static
/// ring with no ripple.
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
    }
    var style: Style

    private var color: NightWatch.RGBA {
        switch style {
        case .needsYou: return NightWatch.Palette.amber
        case .working: return NightWatch.Palette.teal
        case .quiet: return NightWatch.Palette.star
        case .dusk: return NightWatch.Palette.violet
        case .hollowSlate: return NightWatch.RGBA(hex: 0x8A93A8)
        case .hollowAmber: return NightWatch.Palette.amber
        }
    }

    private var hollow: Bool { style == .hollowSlate || style == .hollowAmber }

    var body: some View {
        NWAnimated { t in
            let dusk = style == .dusk
            let breath = style == .working ? 0.5 + 0.5 * sin(t * 2 * .pi / 4) : 0.5
            let period = style == .needsYou ? 2.4 : 4.0
            let ph = (t / period).truncatingRemainder(dividingBy: 1)
            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                ZStack {
                    // Ripples: wide, thin rings that open outwards.
                    ForEach(0..<2, id: \.self) { i in
                        let p = style == .needsYou ? (ph + Double(i) * 0.5).truncatingRemainder(dividingBy: 1) : 0.0
                        Circle()
                            .stroke(color.opacity(style == .needsYou ? 0.40 * (1 - p) : 0.14).color, lineWidth: 1)
                            .frame(width: s, height: s)
                            .scaleEffect(style == .needsYou ? 0.55 + 0.45 * p : (i == 0 ? 0.98 : 0.74))
                    }
                    // Glow.
                    Circle()
                        .fill(RadialGradient(colors: [color.opacity(hollow ? 0.07 : (dusk ? 0.16 : 0.45)).color, color.opacity(0).color],
                                             center: .center, startRadius: 1, endRadius: s * 0.42))
                        .frame(width: s, height: s)
                        .scaleEffect(1 + 0.10 * breath)
                    // The ring and its bright core.
                    Circle()
                        .stroke(color.opacity(dusk ? 0.35 : 0.85).color, lineWidth: 1.6)
                        .frame(width: s * 0.5, height: s * 0.5)
                        .scaleEffect(1 + 0.04 * breath)
                    NWPulseGlyph()
                        .fill(hollow ? AnyShapeStyle(Color.clear)
                              : AnyShapeStyle(RadialGradient(colors: [Color.white.opacity(dusk ? 0.4 : 1), color.opacity(dusk ? 0.3 : 0.92).color],
                                                             center: .center, startRadius: 0, endRadius: s * 0.15)))
                        .overlay(NWPulseGlyph().stroke(color.opacity(dusk ? 0.3 : (hollow ? 0.8 : 0.9)).color, lineWidth: hollow ? 2 : 1.4))
                        .frame(width: s * 0.26, height: s * 0.26)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .accessibilityHidden(true)
    }
}
