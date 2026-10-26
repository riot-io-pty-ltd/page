import SwiftUI

/// Drives an animation from the clock, or holds one still frame when Reduce
/// Motion is on (or the render harness pins a phase). `content` gets seconds.
struct NWAnimated<Content: View>: View {
    @Environment(\.nwReduceMotion) private var reduceMotion
    @Environment(\.nwFixedPhase) private var fixed
    var content: (Double) -> Content

    init(@ViewBuilder content: @escaping (Double) -> Content) { self.content = content }

    var body: some View {
        if reduceMotion || fixed != nil {
            content(fixed ?? 2.0)
        } else {
            TimelineView(.animation) { tl in content(tl.date.timeIntervalSinceReferenceDate) }
        }
    }
}

/// The aurora itself: a sky gradient, a few soft ribbons that drift, upward
/// rays and a scatter of stars. `seconds` moves it; the palette's `intensity`
/// scales it (0 draws only the sky, as at dusk).
struct NWAuroraCanvas: View {
    var palette: NightWatch.AuroraPalette
    var seconds: Double

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let rect = CGRect(origin: .zero, size: size)
            ctx.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [palette.skyTop.color, palette.skyBottom.color]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            guard palette.intensity > 0 else { return }

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

            // Stars.
            for i in 0..<34 {
                let sx = abs(sin(Double(i) * 78.233) * 43758.5453).truncatingRemainder(dividingBy: 1)
                let sy = abs(sin(Double(i) * 12.9898 + 4.1) * 24634.6345).truncatingRemainder(dividingBy: 1)
                let twinkle = 0.5 + 0.5 * sin(seconds * 0.8 + Double(i))
                let r: CGFloat = i % 7 == 0 ? 1.1 : 0.6
                let p = CGPoint(x: w * CGFloat(sx), y: h * CGFloat(sy) * 0.8)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(Color.white.opacity((0.25 + 0.4 * twinkle) * (0.4 + 0.6 * k))))
            }
        }
    }
}

/// The header of a Now surface: aurora, a wash that darkens into the body, the
/// headline and subline at the left, and the pulse at the right.
struct NWAuroraHeader: View {
    var palette: NightWatch.AuroraPalette
    var headline: String
    var subline: String
    var pulse: NWPulseOrb.Style = .working
    var height: CGFloat = 92
    var showsPulse = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            NWAnimated { t in NWAuroraCanvas(palette: palette, seconds: t) }
            // Darken towards the body, as on the boards.
            LinearGradient(stops: [.init(color: NightWatch.Palette.backgroundDeep.opacity(0.0).color, location: 0),
                                   .init(color: NightWatch.Palette.backgroundDeep.opacity(0.18).color, location: 0.45),
                                   .init(color: NightWatch.Palette.popoverBody.color, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(NightWatch.Typo.headline)
                    .kerning(NightWatch.Typo.headlineTracking)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .lineLimit(1)
                Text(subline)
                    .font(NightWatch.Typo.subline)
                    .foregroundColor(NightWatch.Palette.textSecondary.color)
                    .lineLimit(1)
            }
            .padding(.leading, 18)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            if showsPulse {
                NWPulseOrb(style: pulse)
                    .frame(width: 60, height: 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.top, 10)
                    .padding(.trailing, 14)
            }
        }
        .frame(height: height)
        .clipped()
    }
}

/// The pulse: one glyph for everything. Amber with a ripple per waiting item
/// when something needs you, teal breathing while agents work, still
/// star-white when quiet, a dim low glow at dusk. Reduce Motion: a static
/// ring (with no ripple).
struct NWPulseOrb: View {
    enum Style: Equatable { case needsYou, working, quiet, dusk }
    var style: Style

    private var color: NightWatch.RGBA {
        switch style {
        case .needsYou: return NightWatch.Palette.amber
        case .working: return NightWatch.Palette.teal
        case .quiet: return NightWatch.Palette.star
        case .dusk: return NightWatch.Palette.violet
        }
    }

    var body: some View {
        NWAnimated { t in
            let breath = style == .working ? 0.5 + 0.5 * sin(t * 2 * .pi / 4) : 0.5
            let period = style == .needsYou ? 2.4 : 4.0
            let ph = (t / period).truncatingRemainder(dividingBy: 1)
            ZStack {
                // Outer rings: the ripple.
                ForEach(0..<2, id: \.self) { i in
                    let p = style == .needsYou ? (ph + Double(i) * 0.5).truncatingRemainder(dividingBy: 1) : 0.0
                    Circle()
                        .stroke(color.opacity(style == .needsYou ? 0.45 * (1 - p) : 0.12).color, lineWidth: 1)
                        .scaleEffect(style == .needsYou ? 0.62 + 0.38 * p : (i == 0 ? 0.98 : 0.72))
                }
                // Glow.
                Circle()
                    .fill(RadialGradient(colors: [color.opacity(style == .dusk ? 0.18 : 0.55).color, color.opacity(0).color],
                                         center: .center, startRadius: 1, endRadius: 22))
                    .scaleEffect(1 + 0.12 * breath)
                // The ring and its bright core.
                Circle()
                    .stroke(color.opacity(style == .dusk ? 0.35 : 0.9).color, lineWidth: 1.6)
                    .frame(width: 22, height: 22)
                    .scaleEffect(1 + 0.05 * breath)
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(style == .dusk ? 0.35 : 1),
                                                  color.opacity(style == .dusk ? 0.3 : 0.9).color],
                                         center: .center, startRadius: 0, endRadius: 7))
                    .frame(width: 11, height: 11)
            }
        }
    }
}
