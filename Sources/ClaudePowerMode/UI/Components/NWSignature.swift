import SwiftUI

// The pieces of the signature motions that sit on a row or a panel: the
// receipt thread's strip, the hold ring on a key cap, the arrival's glow and
// contrail, the "New ↑" pill and Welcome back's sunrise. Each one draws a
// frame from the pure models in SignatureMotion.swift; the timing lives there.

// MARK: - Receipt thread

/// The receipt thread under a row that has been answered at the Mac: the
/// row's dot (with its rings), a thread of light to the keystroke and on to
/// the screen, and a word for where it is. Success is drawn only from a
/// resolved `.verified` thread; until then the thread waits short of the
/// keystroke node.
struct NWReceiptStrip: View {
    var frame: ReceiptThreadModel.Frame
    /// Waiting for Touch ID: nothing has been sent yet.
    var authenticating = false
    @Environment(\.nwCardGlow) private var cardGlow

    private var transit: NightWatch.RGBA { NightWatch.Palette.sky }
    private var lineColor: NightWatch.RGBA {
        if frame.failure != nil { return NightWatch.Palette.amber }
        if frame.stage == .arm || authenticating { return NightWatch.RGBA(1, 1, 1, 0.9) }
        return transit.mixed(with: NightWatch.Palette.green, frame.verifiedTint)
    }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                let w = geo.size.width, midY = geo.size.height / 2
                let x0: CGFloat = 11, x1 = w - 9
                let span = x1 - x0
                ZStack(alignment: .topLeading) {
                    // The track.
                    Path { p in p.move(to: CGPoint(x: x0, y: midY)); p.addLine(to: CGPoint(x: x1, y: midY)) }
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    // The thread of light, and its bright head.
                    if frame.thread > 0.001 {
                        let head = x0 + span * CGFloat(frame.thread)
                        Path { p in p.move(to: CGPoint(x: x0, y: midY)); p.addLine(to: CGPoint(x: head, y: midY)) }
                            .stroke(LinearGradient(colors: [lineColor.opacity(0.35).color, lineColor.color],
                                                   startPoint: .leading, endPoint: .trailing),
                                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .shadow(color: lineColor.opacity(0.55 * cardGlow.intensity).color, radius: 3)
                        Circle()
                            .fill(lineColor.opacity(0.35 + 0.65 * frame.head).color)
                            .frame(width: 4.5, height: 4.5)
                            .shadow(color: lineColor.opacity(0.8 * frame.head).color, radius: 2 + 3 * cardGlow.intensity)
                            .position(x: head, y: midY)
                    }
                    node("keyboard", lit: frame.thread >= 0.5 - 1e-6, at: CGPoint(x: x0 + span / 2, y: midY))
                    node("display", lit: frame.thread >= 1 - 1e-6, at: CGPoint(x: x1, y: midY))
                    dot.position(x: x0, y: midY)
                }
            }
            .frame(minWidth: frame.failure == nil ? 120 : 64)
            .frame(height: 20)
            // The words win the space: on a failure they are the point.
            Text(authenticating ? "Touch ID" : frame.label)
                .font(NightWatch.Typo.monoMicro.weight(.semibold))
                .foregroundColor(labelColor.color)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    private var labelColor: NightWatch.RGBA {
        if frame.failure != nil { return NightWatch.Palette.amber }
        if frame.stage == .verified { return NightWatch.Palette.green }
        if frame.stage == .arm || authenticating { return NightWatch.Palette.textPrimary }
        return transit
    }

    private var accessibilityText: String {
        if authenticating { return "Waiting for Touch ID, nothing sent" }
        if let f = frame.failure { return "Not delivered: \(f)" }
        switch frame.stage {
        case .verified?: return "Delivered and verified on screen"
        case .typed?: return "Typed"
        case .sent?: return frame.label == "queued" ? "Queued after this turn" : "Sent, waiting for the Mac"
        case .arm?: return "Armed, nothing sent"
        case nil: return ""
        }
    }

    /// The row's dot: amber turning teal as it is verified, its rings
    /// contracting into it; during ARM (or Touch ID) a ring winds round it.
    private var dot: some View {
        let c = NightWatch.Palette.amber.mixed(with: NightWatch.Palette.teal, frame.dotTeal)
        let wound = authenticating ? 1 : frame.armRing
        return ZStack {
            ForEach(0..<2, id: \.self) { i in
                let r = CGFloat(i == 0 ? 6.5 : 9.5) * CGFloat(0.35 + 0.65 * frame.rings)
                Circle()
                    .stroke(c.opacity((i == 0 ? 0.45 : 0.22) * frame.rings).color, lineWidth: 1)
                    .frame(width: r * 2, height: r * 2)
            }
            if wound > 0 {
                Circle()
                    .trim(from: 0, to: CGFloat(wound))
                    .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 13, height: 13)
            }
            Circle()
                .fill(c.color)
                .frame(width: 6, height: 6)
                .shadow(color: c.opacity(0.7 * max(0.3, cardGlow.intensity)).color, radius: 2.5)
        }
    }

    private func node(_ symbol: String, lit: Bool, at p: CGPoint) -> some View {
        let c = lit ? lineColor : NightWatch.RGBA(1, 1, 1, 0.38)
        return ZStack {
            Circle().fill(lit ? c.opacity(0.18).color : Color.white.opacity(0.06))
            Image(systemName: symbol)
                .font(Font.system(size: 7.5, weight: .semibold))
                .foregroundColor(c.color)
        }
        .frame(width: 16, height: 16)
        .position(p)
    }
}

// MARK: - Hold ring

/// The border that fills around a key cap while it is held (the "hold 1" of
/// an Irreversible approval): nothing for 300 ms, then a clockwise fill,
/// amber warming to red only in its final third. Glows with the Card glow
/// setting.
struct NWHoldBorder: View {
    var progress: Double
    var radius: CGFloat = NightWatch.Radius.keycap
    /// 0...1 the burst after Touch ID: the ring flares towards teal (confirmed).
    var flash: Double = 0
    @Environment(\.nwCardGlow) private var cardGlow

    var body: some View {
        let p = min(1, max(0, progress))
        let warm = NightWatch.Palette.amber.mixed(with: NightWatch.Palette.red, HoldRingModel.warmth(progress: p))
        let c = warm.mixed(with: NightWatch.Palette.teal, 0.8 * flash)
        ZStack {
            NWTopStartRoundedRect(radius: radius)
                .stroke(c.opacity(0.18).color, lineWidth: 2)
                .opacity(p > 0 ? 1 : 0)
            NWTopStartRoundedRect(radius: radius)
                .trim(from: 0, to: CGFloat(p))
                .stroke(c.color, style: StrokeStyle(lineWidth: 2 + flash, lineCap: .round))
                .shadow(color: c.opacity((0.35 + 0.5 * flash) * max(cardGlow.intensity, flash)).color, radius: 3 + 4 * flash)
        }
        .accessibilityHidden(true)
    }
}

/// A rounded rectangle whose path starts at 12 o'clock and runs clockwise,
/// so a trimmed stroke fills like a clock hand (SwiftUI's own starts elsewhere).
struct NWTopStartRoundedRect: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// The ring that fills while a key or button is held (Stop all): the same
/// rule as the cap's border, as a circle filling clockwise from 12 o'clock.
struct NWHoldRing: View {
    var progress: Double
    var size: CGFloat = 26
    var lineWidth: CGFloat = 3
    @Environment(\.nwCardGlow) private var cardGlow

    var body: some View {
        let p = min(1, max(0, progress))
        let c = NightWatch.Palette.amber.mixed(with: NightWatch.Palette.red, HoldRingModel.warmth(progress: p))
        ZStack {
            Circle().stroke(c.opacity(0.16).color, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(p))
                .stroke(c.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: c.opacity(0.5 * cardGlow.intensity).color, radius: 4)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Final approach

/// The arrival's glow: an amber border that brightens as the card lands and
/// goes off as it settles. The bloom follows the Card glow setting.
struct NWArrivalGlow: View {
    var glow: Double
    /// The plain outline that stands in for the card while it flies (no light).
    var edge: Double = 0
    var radius: CGFloat = NightWatch.Radius.row
    @Environment(\.nwCardGlow) private var cardGlow

    var body: some View {
        let c = NightWatch.Palette.amber
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(c.opacity(0.85 * max(glow, edge)).color, lineWidth: 1.4)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(c.opacity(0.07 * glow).color))
            // The soft light round it is a glow, so it follows the Card glow setting (Off: none).
            .shadow(color: c.opacity(0.55 * glow * cardGlow.intensity).color, radius: 9)
            .allowsHitTesting(false)
    }
}

/// The faint contrail from the pulse down to an arriving card's top edge.
struct NWContrail: View {
    var from: CGPoint
    var to: CGPoint
    var strength: Double

    var body: some View {
        let c = NightWatch.Palette.amber
        Path { p in p.move(to: from); p.addLine(to: to) }
            .stroke(LinearGradient(colors: [c.opacity(0.85 * strength).color, c.opacity(0.35 * strength).color],
                                   startPoint: UnitPoint(x: 0.5, y: 0), endPoint: UnitPoint(x: 0.5, y: 1)),
                    style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .allowsHitTesting(false)
    }
}

/// "New ↑ 1": arrivals held back while the pointer is over the list.
struct NWNewPill: View {
    var count: Int
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up").font(Font.system(size: 9, weight: .bold))
                Text("New \(count)").font(Font.system(size: 11, weight: .semibold))
            }
            .foregroundColor(NightWatch.Palette.backgroundDeep.color)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(NightWatch.Palette.amber.color))
            .shadow(color: Color.black.opacity(0.35), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(count) new, show"))
    }
}

// MARK: - Sunrise

/// Welcome back's sunrise: warm light rising from the panel's bottom edge,
/// higher and warmer the more of the absence finished well. Plays once over
/// 2.2 s, then rests at a low glow. Reduce Motion: the resting glow.
struct NWSunrise: View {
    var scale: Double
    var shownAt: Date?
    @Environment(\.nwReduceMotion) private var reduceMotion

    var body: some View {
        NWOneShot(start: shownAt, duration: DuskDawnModel.sunriseDuration, fps: NWMotionRate.ambient) { now in
            let e = reduceMotion || shownAt == nil ? DuskDawnModel.sunriseDuration : now.timeIntervalSince(shownAt!)
            let s = DuskDawnModel.sunrise(elapsed: e, scale: scale)
            GeometryReader { geo in
                let h = geo.size.height, w = geo.size.width
                let warm = NightWatch.RGBA(hex: 0xF5B14C)
                let peach = NightWatch.RGBA(hex: 0xFFD9A0)
                let frontY = h * CGFloat(1 - s.front)
                ZStack {
                    // The light behind the front.
                    LinearGradient(stops: [
                        .init(color: peach.opacity(0).color, location: 0),
                        .init(color: peach.opacity(0.10 * s.glow).color, location: 0.35),
                        .init(color: warm.opacity(0.26 * s.glow).color, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: max(1, h - frontY + 24))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    // The sun's glow on the horizon.
                    RadialGradient(colors: [warm.opacity(0.32 * s.glow).color, warm.opacity(0).color],
                                   center: .center, startRadius: 0, endRadius: w * 0.5)
                        .frame(width: w * 1.4, height: h * 0.9 * CGFloat(0.4 + s.front))
                        .scaleEffect(x: 1, y: 0.55)
                        .position(x: w * 0.32, y: h)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
