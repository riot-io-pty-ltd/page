import SwiftUI

private typealias P = WidgetPalette

// The widget faces. Plain views over values, with no padding of their own:
// the extension puts them in `containerBackground` (which brings the system's
// margins on macOS 14), the Tower previews put them in `WidgetPreviewFrame`.
// Night Watch is dark, so a widget does not follow the light appearance.

// MARK: - Background

/// The widget's sky: near-black navy with a faint aurora in the tone's colour at
/// the top right, and, with Card glow on, the teal glow along the bottom edge.
public struct WidgetBackdrop: View {
    public var tone: WidgetTone
    /// 0, 0.5 or 1.
    public var glow: Double

    public init(tone: WidgetTone, glow: Double = 0) { self.tone = tone; self.glow = glow }

    public var body: some View {
        let c = P.color(for: tone)
        ZStack {
            P.backgroundDeep.color
            RadialGradient(colors: [c.opacity(tone == .asleep ? 0.10 : (tone == .quiet ? 0.12 : 0.26)).color, .clear],
                           center: .topTrailing, startRadius: 4, endRadius: 260)
            RadialGradient(colors: [P.violet.opacity(tone == .paused ? 0.30 : 0.07).color, .clear],
                           center: .topLeading, startRadius: 4, endRadius: 220)
            LinearGradient(colors: [.clear, P.backgroundDeep.opacity(0.65).color], startPoint: .center, endPoint: .bottom)
            if glow > 0 {
                RadialGradient(colors: [P.glass.opacity(0.30 * glow).color, .clear],
                               center: .bottom, startRadius: 2, endRadius: 190)
            }
        }
    }
}

/// A widget as the desktop shows it: the face on its backdrop, rounded, at its
/// size. Only for the Tower's previews; the real widget gets this from the system.
public struct WidgetPreviewFrame<Content: View>: View {
    public var size: WidgetFaceSize
    public var tone: WidgetTone
    public var glow: Double
    @ViewBuilder public var content: () -> Content

    public init(size: WidgetFaceSize, tone: WidgetTone, glow: Double = 0, @ViewBuilder content: @escaping () -> Content) {
        self.size = size; self.tone = tone; self.glow = glow; self.content = content
    }

    public var body: some View {
        content()
            .padding(16)
            .frame(width: CGFloat(size.points.width), height: CGFloat(size.points.height), alignment: .topLeading)
            .background(WidgetBackdrop(tone: tone, glow: glow))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .allowsHitTesting(false)
    }
}

// MARK: - The pulse, as a still

/// The menu-bar pulse held on one frame: a dot, and ripples when something
/// needs you.
public struct WidgetPulseGlyph: View {
    public var tone: WidgetTone
    public var size: CGFloat

    public init(tone: WidgetTone, size: CGFloat = 44) { self.tone = tone; self.size = size }

    public var body: some View {
        let c = P.color(for: tone)
        let d = size * 0.34
        ZStack {
            switch tone {
            case .needsYou:
                Circle().stroke(c.opacity(0.18).color, lineWidth: 1.5).frame(width: size, height: size)
                Circle().stroke(c.opacity(0.38).color, lineWidth: 1.5).frame(width: size * 0.74, height: size * 0.74)
                Circle().fill(c.color).frame(width: d, height: d).shadow(color: c.opacity(0.7).color, radius: size * 0.12)
            case .working:
                Circle().fill(c.opacity(0.16).color).frame(width: size * 0.9, height: size * 0.9)
                Circle().stroke(c.opacity(0.35).color, lineWidth: 1.5).frame(width: size * 0.66, height: size * 0.66)
                Circle().fill(c.color).frame(width: d, height: d).shadow(color: c.opacity(0.6).color, radius: size * 0.1)
            case .quiet:
                Circle().fill(c.opacity(0.10).color).frame(width: size * 0.8, height: size * 0.8)
                Circle().fill(c.color).frame(width: d * 0.85, height: d * 0.85).shadow(color: c.opacity(0.5).color, radius: size * 0.08)
            case .paused:
                Circle().fill(c.opacity(0.45).color).frame(width: d, height: d).offset(y: -size * 0.06)
                Capsule().fill(c.opacity(0.55).color).frame(width: size * 0.7, height: 2).offset(y: size * 0.18)
            case .asleep:
                Circle().stroke(c.opacity(0.8).color, lineWidth: 2).frame(width: d * 1.1, height: d * 1.1)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Page status

/// "Page": who needs you, who is working, the runway.
public struct PageStatusWidgetView: View {
    public var snapshot: WidgetSnapshot?
    public var size: WidgetFaceSize
    public var now: Date
    public var timeZone: TimeZone
    /// True in the extension, where `Link` rows work; false in previews.
    public var interactive: Bool

    public init(snapshot: WidgetSnapshot?, size: WidgetFaceSize, now: Date = Date(), timeZone: TimeZone = .current,
                interactive: Bool = true) {
        self.snapshot = snapshot; self.size = size; self.now = now; self.timeZone = timeZone; self.interactive = interactive
    }

    private var tone: WidgetTone { WidgetDisplay.tone(snapshot, now: now) }
    private var color: Color { P.color(for: tone).color }

    public var body: some View {
        Group {
            if let s = snapshot {
                switch size {
                case .small: small(s)
                case .medium: medium(s)
                case .large: large(s)
                }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: pieces

    private func note(_ s: WidgetSnapshot) -> String? { WidgetDisplay.note(s, now: now, timeZone: timeZone) }

    private func footer(_ s: WidgetSnapshot, compact: Bool) -> some View {
        let text = note(s) ?? WidgetDisplay.runway(s, now: now, timeZone: timeZone)
        let isNote = note(s) != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: isNote ? "moon.zzz" : (s.mood == .dusk ? "pause.fill" : (s.battery?.onAC == false ? "battery.50" : "bolt.fill")))
                    .font(Font.system(size: 9, weight: .bold))
                Text(text).font(Font.system(size: 11, weight: .medium)).lineLimit(compact ? 2 : 1).minimumScaleFactor(0.8)
            }
            .foregroundColor((isNote ? P.textTertiary : (s.mood == .dusk ? P.violet : P.teal)).opacity(0.95).color)
            if !compact, !isNote, let b = WidgetDisplay.battery(s) {
                Text("Battery \(b)").font(Font.system(size: 10.5, weight: .regular)).foregroundColor(P.textTertiary.color)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            WidgetPulseGlyph(tone: .asleep, size: size == .small ? 34 : 44)
            Spacer(minLength: 0)
            Text("Page").font(Font.system(size: 15, weight: .semibold)).foregroundColor(P.textPrimary.color)
            Text(WidgetDisplay.missing).font(Font.system(size: 12, weight: .medium)).foregroundColor(P.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func small(_ s: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                WidgetPulseGlyph(tone: tone, size: 30)
                Text("Page").font(Font.system(size: 12, weight: .semibold)).foregroundColor(P.textTertiary.color)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Text(WidgetDisplay.headline(s)).font(Font.system(size: 23, weight: .bold)).kerning(-0.5)
                .foregroundColor(color).lineLimit(2).minimumScaleFactor(0.7)
            if let second = WidgetDisplay.secondLine(s) {
                Text(second).font(Font.system(size: 12.5, weight: .medium)).foregroundColor(P.textSecondary.color).lineLimit(1)
            }
            footer(s, compact: true).padding(.top, 2)
        }
    }

    private func medium(_ s: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(s.macName.isEmpty ? "PAGE" : "PAGE · " + s.macName.uppercased()).nwLabelStyle().lineLimit(1)
                Text(WidgetDisplay.headline(s)).font(Font.system(size: 29, weight: .bold)).kerning(-0.7)
                    .foregroundColor(color).lineLimit(1).minimumScaleFactor(0.6)
                if let second = WidgetDisplay.secondLine(s) {
                    Text(second).font(Font.system(size: 13, weight: .medium)).foregroundColor(P.textSecondary.color).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let d = s.decisions.first {
                    topRow(project: d.project, chip: d.chip, text: nil)
                } else if let f = s.inFlight.first {
                    topRow(project: f.project, chip: nil, text: f.doing)
                }
                footer(s, compact: false)
            }
            Spacer(minLength: 0)
            WidgetPulseGlyph(tone: tone, size: 64).offset(x: 2, y: 4)
        }
    }

    private func topRow(project: String, chip: String?, text: String?) -> some View {
        HStack(spacing: 6) {
            if let chip { chipView(chip) }
            Text(project).font(Font.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(P.textPrimary.color).lineLimit(1)
            if let text { Text(text).font(Font.system(size: 11.5)).foregroundColor(P.textSecondary.color).lineLimit(1) }
        }
        .padding(.bottom, 3)
    }

    private func chipView(_ raw: String) -> some View {
        let chip = WidgetDisplay.chip(raw)
        let c: P.RGBA = chip.tone == .red ? P.red : (chip.tone == .teal ? P.teal : P.amber)
        return Text(chip.title).font(Font.system(size: 8.5, weight: .heavy)).kerning(0.7)
            .foregroundColor(c.color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(c.opacity(0.16).color))
            .fixedSize()
    }

    private func large(_ s: WidgetSnapshot) -> some View {
        let rows = WidgetDisplay.largeRows(decisions: s.decisions.count, inFlight: s.inFlight.count,
                                           moreDecisions: s.attention > s.decisions.count,
                                           moreWorking: s.working > s.inFlight.count)
        let moreDecisions = max(0, s.attention - rows.decisions)
        let moreWorking = max(0, s.working - rows.inFlight)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                WidgetPulseGlyph(tone: tone, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WidgetDisplay.headline(s)).font(Font.system(size: 26, weight: .bold)).kerning(-0.6)
                        .foregroundColor(color).lineLimit(1).minimumScaleFactor(0.6)
                    Text([WidgetDisplay.secondLine(s), s.macName.isEmpty ? nil : s.macName].compactMap { $0 }.joined(separator: " · "))
                        .font(Font.system(size: 12, weight: .medium)).foregroundColor(P.textSecondary.color).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if rows.decisions > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    Text("NEEDS YOU").nwLabelStyle()
                    ForEach(Array(s.decisions.prefix(rows.decisions))) { d in
                        link(.item(id: d.id)) { decisionRow(d) }
                    }
                    if moreDecisions > 0 { moreLine("+\(moreDecisions) more in Page") }
                }
            }
            if rows.inFlight > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    Text("WORKING").nwLabelStyle()
                    ForEach(Array(s.inFlight.prefix(rows.inFlight))) { f in
                        link(.item(id: f.id)) { flightRow(f) }
                    }
                    if moreWorking > 0 { moreLine("+\(moreWorking) more working") }
                }
            }
            if rows.decisions == 0 && rows.inFlight == 0 {
                Text(s.mood == .dusk ? "Agents are paused until the battery recovers."
                     : "Nothing is waiting on you and nothing is running.")
                    .font(Font.system(size: 12.5)).foregroundColor(P.textSecondary.color)
            }
            Spacer(minLength: 0)
            footer(s, compact: false)
        }
    }

    @ViewBuilder
    private func link<Label: View>(_ route: WidgetRoute, @ViewBuilder label: () -> Label) -> some View {
        if interactive { Link(destination: route.url) { label() } } else { label() }
    }

    private func decisionRow(_ d: WidgetSnapshot.Decision) -> some View {
        HStack(alignment: .top, spacing: 8) {
            chipView(d.chip).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.project).font(Font.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(P.textPrimary.color).lineLimit(1)
                if !d.summary.isEmpty {
                    Text(d.summary).font(Font.system(size: 11)).foregroundColor(P.textSecondary.color).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func flightRow(_ f: WidgetSnapshot.Flight) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(P.teal.color).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.project).font(Font.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(P.textPrimary.color).lineLimit(1)
                Text(f.doing.isEmpty ? "working" : f.doing).font(Font.system(size: 11)).foregroundColor(P.textSecondary.color).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func moreLine(_ text: String) -> some View {
        Text(text).font(Font.system(size: 11, weight: .medium)).foregroundColor(P.textTertiary.color)
    }
}

extension Text {
    /// The small tracked all-caps label.
    func nwLabelStyle() -> some View {
        self.font(Font.system(size: 9, weight: .heavy)).kerning(0.9).foregroundColor(WidgetPalette.textTertiary.color)
    }
}

// MARK: - Claude usage

/// "Claude usage": the 5-hour and 7-day windows as rings, with their resets.
public struct ClaudeUsageWidgetView: View {
    public var snapshot: WidgetSnapshot?
    public var size: WidgetFaceSize
    public var now: Date
    public var timeZone: TimeZone

    public init(snapshot: WidgetSnapshot?, size: WidgetFaceSize, now: Date = Date(), timeZone: TimeZone = .current) {
        self.snapshot = snapshot; self.size = size; self.now = now; self.timeZone = timeZone
    }

    public var body: some View {
        Group {
            if let s = snapshot, let u = s.usage, u.fiveHour != nil || u.sevenDay != nil {
                if size == .small { small(s, u) } else { medium(s, u) }
            } else {
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude usage").font(Font.system(size: 15, weight: .semibold)).foregroundColor(P.textPrimary.color)
            Text(snapshot == nil ? WidgetDisplay.missing : "Turn on “Show my Claude usage” in Page’s Budget settings")
                .font(Font.system(size: 12, weight: .medium)).foregroundColor(P.textSecondary.color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func color(_ g: WidgetSnapshot.Gauge) -> P.RGBA { WidgetDisplay.usageIsHot(g) ? P.amber : P.teal }

    private func ring(_ g: WidgetSnapshot.Gauge, size: CGFloat, line: CGFloat) -> some View {
        let c = color(g)
        return ZStack {
            Circle().stroke(c.opacity(0.18).color, lineWidth: line)
            Circle().trim(from: 0, to: CGFloat(max(0.01, g.pct / 100)))
                .stroke(c.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: c.opacity(0.45).color, radius: 3)
            Text("\(WidgetDisplay.percent(g))").font(Font.system(size: size * 0.30, weight: .bold, design: .rounded))
                .foregroundColor(P.textPrimary.color)
        }
        .frame(width: size, height: size)
    }

    private func staleNote(_ s: WidgetSnapshot, _ u: WidgetSnapshot.Usage) -> String? {
        if let n = WidgetDisplay.note(s, now: now, timeZone: timeZone) { return n }
        if now.timeIntervalSince(u.updatedAt) > 6 * 3600 { return "Claude Code last reported at \(WidgetDisplay.clock(u.updatedAt, timeZone: timeZone))" }
        return nil
    }

    private func column(_ g: WidgetSnapshot.Gauge, short: String, label: String, ringSize: CGFloat, line: CGFloat) -> some View {
        VStack(spacing: 4) {
            ring(g, size: ringSize, line: line)
            Text(short).font(Font.system(size: 12, weight: .semibold)).foregroundColor(P.textPrimary.color)
            Text(WidgetDisplay.resetText(g, now: now, timeZone: timeZone) ?? " ")
                .font(Font.system(size: 10, weight: .medium)).foregroundColor(P.textTertiary.color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label), \(WidgetDisplay.percent(g)) percent used"))
    }

    private func small(_ s: WidgetSnapshot, _ u: WidgetSnapshot.Usage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CLAUDE USAGE").nwLabelStyle()
            HStack(alignment: .top, spacing: 6) {
                if let g = u.fiveHour { column(g, short: "5h", label: "5-hour limit", ringSize: 56, line: 7) }
                if let g = u.sevenDay { column(g, short: "7d", label: "7-day limit", ringSize: 56, line: 7) }
            }
            .frame(maxHeight: .infinity, alignment: .center)
            if let n = staleNote(s, u) {
                Text(n).font(Font.system(size: 9.5)).foregroundColor(P.textTertiary.color).lineLimit(2)
            }
        }
    }

    private func medium(_ s: WidgetSnapshot, _ u: WidgetSnapshot.Usage) -> some View {
        let v = WidgetDisplay.usageVerdict(u)
        return VStack(alignment: .leading, spacing: 8) {
            Text("CLAUDE USAGE").nwLabelStyle()
            HStack(alignment: .center, spacing: 16) {
                HStack(alignment: .top, spacing: 10) {
                    if let g = u.fiveHour { column(g, short: "5-hour", label: "5-hour limit", ringSize: 70, line: 8) }
                    if let g = u.sevenDay { column(g, short: "7-day", label: "7-day limit", ringSize: 70, line: 8) }
                }
                .frame(width: 190)
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.text).font(Font.system(size: 14, weight: .semibold))
                        .foregroundColor((v.warning ? P.amber : P.textPrimary).color)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(staleNote(s, u) ?? "Updated \(WidgetDisplay.clock(u.updatedAt, timeZone: timeZone))")
                        .font(Font.system(size: 11)).foregroundColor(P.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }
}
