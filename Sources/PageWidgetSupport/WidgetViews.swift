import SwiftUI
import WidgetKit

private typealias P = WidgetPalette

// The widget faces. Plain views over values, with no padding of their own:
// the extension puts them in `containerBackground` (which brings the system's
// margins on macOS 14), the Tower previews put them in `WidgetPreviewFrame`.
// Night Watch is dark, so a widget does not follow the light appearance.
//
// Nothing here may draw outside its frame: every line is limited and scales
// down before it would clip, and each face offers tighter variants (`TierFit`)
// for the desktop sizes where the full one does not fit.

// MARK: - Rendering mode

/// How a face is inked. The desktop dims or tints widgets when another app is in
/// front (WidgetKit's accented and vibrant modes): the system flattens colour to
/// luminance there, so colour must not carry meaning. `.vibrant` stands for both.
public enum WidgetFaceMode: Equatable {
    case fullColor
    case vibrant

    /// Pure. A widget that is not in WidgetKit's full-colour mode, or that is shown
    /// without its container background, is drawn in the white-only ink: our text
    /// is white and only reads on a dark or system-tinted backdrop.
    public static func resolve(isFullColor: Bool, showsContainerBackground: Bool) -> WidgetFaceMode {
        isFullColor && showsContainerBackground ? .fullColor : .vibrant
    }
}

extension View {
    /// Marks the headline and glyph as the part the system tints in accented mode.
    @ViewBuilder
    func pageAccent() -> some View {
        if #available(macOS 13.0, *) { self.widgetAccentable() } else { self }
    }
}

/// The first of up to three variants of a face whose content fits the height it is
/// given (ViewThatFits, macOS 13 and later); the last, tightest one before that.
struct TierFit<A: View, B: View, C: View>: View {
    var a: A, b: B, c: C

    init(@ViewBuilder _ a: () -> A, @ViewBuilder _ b: () -> B, @ViewBuilder _ c: () -> C) {
        self.a = a(); self.b = b(); self.c = c()
    }

    var body: some View {
        if #available(macOS 13.0, *) {
            ViewThatFits(in: .vertical) { a; b; c }
        } else {
            c
        }
    }
}

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
/// needs you. In the vibrant ink it is white, the tone told by its shape alone.
public struct WidgetPulseGlyph: View {
    public var tone: WidgetTone
    public var size: CGFloat
    public var mode: WidgetFaceMode

    public init(tone: WidgetTone, size: CGFloat = 44, mode: WidgetFaceMode = .fullColor) {
        self.tone = tone; self.size = size; self.mode = mode
    }

    public var body: some View {
        let vibrant = mode == .vibrant
        let c = vibrant ? P.RGBA(1, 1, 1) : P.color(for: tone)
        let d = size * 0.34
        // Glows turn into smudges once the system flattens the colour.
        let glow: (Double) -> Color = { vibrant ? .clear : c.opacity($0).color }
        ZStack {
            switch tone {
            case .needsYou:
                Circle().strokeBorder(c.opacity(0.18).color, lineWidth: 1.5).frame(width: size, height: size) // inside the frame, not 0.75pt past it
                Circle().stroke(c.opacity(0.38).color, lineWidth: 1.5).frame(width: size * 0.74, height: size * 0.74)
                Circle().fill(c.color).frame(width: d, height: d).shadow(color: glow(0.7), radius: size * 0.12)
            case .working:
                Circle().fill(c.opacity(0.16).color).frame(width: size * 0.9, height: size * 0.9)
                Circle().stroke(c.opacity(0.35).color, lineWidth: 1.5).frame(width: size * 0.66, height: size * 0.66)
                Circle().fill(c.color).frame(width: d, height: d).shadow(color: glow(0.6), radius: size * 0.1)
            case .quiet:
                Circle().fill(c.opacity(0.10).color).frame(width: size * 0.8, height: size * 0.8)
                Circle().fill(c.color).frame(width: d * 0.85, height: d * 0.85).shadow(color: glow(0.5), radius: size * 0.08)
            case .paused:
                Circle().fill(c.opacity(vibrant ? 0.8 : 0.45).color).frame(width: d, height: d).offset(y: -size * 0.06)
                Capsule().fill(c.opacity(vibrant ? 0.8 : 0.55).color).frame(width: size * 0.7, height: 2).offset(y: size * 0.18)
            case .asleep:
                Circle().stroke(c.opacity(0.8).color, lineWidth: 2).frame(width: d * 1.1, height: d * 1.1)
            }
        }
        .frame(width: size, height: size)
        .pageAccent()
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
    public var mode: WidgetFaceMode

    public init(snapshot: WidgetSnapshot?, size: WidgetFaceSize, now: Date = Date(), timeZone: TimeZone = .current,
                interactive: Bool = true, mode: WidgetFaceMode = .fullColor) {
        self.snapshot = snapshot; self.size = size; self.now = now; self.timeZone = timeZone
        self.interactive = interactive; self.mode = mode
    }

    private var vibrant: Bool { mode == .vibrant }
    private var tone: WidgetTone { WidgetDisplay.tone(snapshot, now: now) }
    /// The headline's colour: the tone's, or plain white when colour is flattened.
    private var color: Color { (vibrant ? P.textPrimary : P.color(for: tone)).color }
    private var primary: Color { P.textPrimary.color }
    private var secondary: Color { (vibrant ? P.textPrimary.opacity(0.80) : P.textSecondary).color }
    private var tertiary: Color { (vibrant ? P.textPrimary.opacity(0.62) : P.textTertiary).color }
    private func glyph(_ size: CGFloat) -> some View { WidgetPulseGlyph(tone: tone, size: size, mode: mode) }

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

    /// The runway line, and (`battery`) the battery under it. `lines` is how many lines the runway may use.
    private func footer(_ s: WidgetSnapshot, lines: Int, battery: Bool) -> some View {
        let text = note(s) ?? WidgetDisplay.runway(s, now: now, timeZone: timeZone)
        let isNote = note(s) != nil
        let ink: Color = isNote ? tertiary
            : (vibrant ? secondary : (s.mood == .dusk ? P.violet : P.teal).opacity(0.95).color)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: isNote ? "moon.zzz" : (s.mood == .dusk ? "pause.fill" : (s.battery?.onAC == false ? "battery.50" : "bolt.fill")))
                    .font(Font.system(size: 9, weight: .bold))
                Text(text).font(Font.system(size: 11, weight: .medium)).lineLimit(lines).minimumScaleFactor(0.8)
            }
            .foregroundColor(ink)
            if battery, !isNote, let b = WidgetDisplay.battery(s) {
                Text("Battery \(b)").font(Font.system(size: 10.5, weight: .regular)).foregroundColor(tertiary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            glyph(size == .small ? 34 : 44)
            Spacer(minLength: 0)
            Text("Page").font(Font.system(size: 15, weight: .semibold)).foregroundColor(primary).lineLimit(1)
            Text(WidgetDisplay.missing).font(Font.system(size: 12, weight: .medium)).foregroundColor(secondary)
                .lineLimit(2).minimumScaleFactor(0.8)
        }
    }

    // Small: 1) everything, 2) a one-line footer, 3) no second line.
    private func small(_ s: WidgetSnapshot) -> some View {
        func face(glyph g: CGFloat, footerLines: Int, second: Bool) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    glyph(g)
                    Text("Page").font(Font.system(size: 12, weight: .semibold)).foregroundColor(tertiary).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                Text(WidgetDisplay.headline(s)).font(Font.system(size: 23, weight: .bold)).kerning(-0.5)
                    .foregroundColor(color).lineLimit(2).minimumScaleFactor(0.6).pageAccent()
                if second, let line = WidgetDisplay.secondLine(s) {
                    Text(line).font(Font.system(size: 12.5, weight: .medium)).foregroundColor(secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                footer(s, lines: footerLines, battery: false).padding(.top, 2)
            }
        }
        return TierFit({ face(glyph: 30, footerLines: 2, second: true) },
                       { face(glyph: 26, footerLines: 1, second: true) },
                       { face(glyph: 22, footerLines: 1, second: false) })
    }

    // Medium: 1) everything, 2) no battery line, 3) also no top row.
    private func medium(_ s: WidgetSnapshot) -> some View {
        func face(battery: Bool, top: Bool) -> some View {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.macName.isEmpty ? "PAGE" : "PAGE · " + s.macName.uppercased()).nwLabelStyle(vibrant: vibrant)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(WidgetDisplay.headline(s)).font(Font.system(size: 29, weight: .bold)).kerning(-0.7)
                        .foregroundColor(color).lineLimit(1).minimumScaleFactor(0.6).pageAccent()
                    if let second = WidgetDisplay.secondLine(s) {
                        Text(second).font(Font.system(size: 13, weight: .medium)).foregroundColor(secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    if top {
                        if let d = s.decisions.first {
                            topRow(project: d.project, chip: d.chip, text: nil)
                        } else if let f = s.inFlight.first {
                            topRow(project: f.project, chip: nil, text: f.doing)
                        }
                    }
                    footer(s, lines: 1, battery: battery)
                }
                .layoutPriority(1)
                Spacer(minLength: 0)
                glyph(64)
            }
        }
        return TierFit({ face(battery: true, top: true) },
                       { face(battery: false, top: true) },
                       { face(battery: false, top: false) })
    }

    private func topRow(project: String, chip: String?, text: String?) -> some View {
        HStack(spacing: 6) {
            if let chip { chipView(chip) }
            Text(project).font(Font.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(primary)
                .lineLimit(1).truncationMode(.tail)
            if let text { Text(text).font(Font.system(size: 11.5)).foregroundColor(secondary).lineLimit(1) }
        }
        .padding(.bottom, 3)
    }

    private func chipView(_ raw: String) -> some View {
        let chip = WidgetDisplay.chip(raw)
        let c: P.RGBA = vibrant ? P.textPrimary : (chip.tone == .red ? P.red : (chip.tone == .teal ? P.teal : P.amber))
        return Text(chip.title).font(Font.system(size: 8.5, weight: .heavy)).kerning(0.7)
            .foregroundColor(c.color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(c.opacity(vibrant ? 0.22 : 0.16).color))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(vibrant ? c.opacity(0.45).color : .clear, lineWidth: 0.75))
            .lineLimit(1)
            .fixedSize()
    }

    private func large(_ s: WidgetSnapshot) -> some View {
        // The rows are counted for the room this widget really has: the desktop's large
        // widget is 364x382 or, on a smaller display, 329x345.
        GeometryReader { geo in
            largeStack(s, room: WidgetDisplay.LargeLayout.room(forInnerHeight: Double(geo.size.height)))
        }
    }

    private func largeStack(_ s: WidgetSnapshot, room: Double) -> some View {
        let rows = WidgetDisplay.largeRows(decisions: s.decisions.count, inFlight: s.inFlight.count,
                                           moreDecisions: s.attention > s.decisions.count,
                                           moreWorking: s.working > s.inFlight.count, room: room)
        let moreDecisions = max(0, s.attention - rows.decisions)
        let moreWorking = max(0, s.working - rows.inFlight)
        return VStack(alignment: .leading, spacing: WidgetDisplay.LargeLayout.gap) {
            HStack(alignment: .center, spacing: 10) {
                glyph(46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(WidgetDisplay.headline(s)).font(Font.system(size: 26, weight: .bold)).kerning(-0.6)
                        .foregroundColor(color).lineLimit(1).minimumScaleFactor(0.6).pageAccent()
                    Text([WidgetDisplay.secondLine(s), s.macName.isEmpty ? nil : s.macName].compactMap { $0 }.joined(separator: " · "))
                        .font(Font.system(size: 12, weight: .medium)).foregroundColor(secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            if rows.decisions > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    Text("NEEDS YOU").nwLabelStyle(vibrant: vibrant)
                    ForEach(Array(s.decisions.prefix(rows.decisions))) { d in
                        link(.item(id: d.id)) { decisionRow(d) }
                    }
                    if moreDecisions > 0 { moreLine("+\(moreDecisions) more in Page") }
                }
            }
            if rows.inFlight > 0 {
                VStack(alignment: .leading, spacing: 7) {
                    Text("WORKING").nwLabelStyle(vibrant: vibrant)
                    ForEach(Array(s.inFlight.prefix(rows.inFlight))) { f in
                        link(.item(id: f.id)) { flightRow(f) }
                    }
                    if moreWorking > 0 { moreLine("+\(moreWorking) more working") }
                }
            }
            if rows.decisions == 0 && rows.inFlight == 0 {
                Text(s.mood == .dusk ? "Agents are paused until the battery recovers."
                     : "Nothing is waiting on you and nothing is running.")
                    .font(Font.system(size: 12.5)).foregroundColor(secondary).lineLimit(2).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            footer(s, lines: 1, battery: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func link<Label: View>(_ route: WidgetRoute, @ViewBuilder label: () -> Label) -> some View {
        if interactive { Link(destination: route.url) { label() } } else { label() }
    }

    private func decisionRow(_ d: WidgetSnapshot.Decision) -> some View {
        HStack(alignment: .top, spacing: 8) {
            chipView(d.chip).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(d.project).font(Font.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(primary).lineLimit(1)
                if !d.summary.isEmpty {
                    Text(d.summary).font(Font.system(size: 11)).foregroundColor(secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func flightRow(_ f: WidgetSnapshot.Flight) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill((vibrant ? P.textPrimary : P.teal).color).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(f.project).font(Font.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(primary).lineLimit(1)
                Text(f.doing.isEmpty ? "working" : f.doing).font(Font.system(size: 11)).foregroundColor(secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func moreLine(_ text: String) -> some View {
        Text(text).font(Font.system(size: 11, weight: .medium)).foregroundColor(tertiary).lineLimit(1)
    }
}

extension Text {
    /// The small tracked all-caps label.
    func nwLabelStyle(vibrant: Bool = false) -> some View {
        self.font(Font.system(size: 9, weight: .heavy)).kerning(0.9)
            .foregroundColor((vibrant ? WidgetPalette.textPrimary.opacity(0.62) : WidgetPalette.textTertiary).color)
    }
}

// MARK: - Claude usage

/// "Claude usage": the 5-hour and 7-day windows as rings, with their resets.
public struct ClaudeUsageWidgetView: View {
    public var snapshot: WidgetSnapshot?
    public var size: WidgetFaceSize
    public var now: Date
    public var timeZone: TimeZone
    public var mode: WidgetFaceMode

    public init(snapshot: WidgetSnapshot?, size: WidgetFaceSize, now: Date = Date(), timeZone: TimeZone = .current,
                mode: WidgetFaceMode = .fullColor) {
        self.snapshot = snapshot; self.size = size; self.now = now; self.timeZone = timeZone; self.mode = mode
    }

    private var vibrant: Bool { mode == .vibrant }
    private var primary: Color { P.textPrimary.color }
    private var tertiary: Color { (vibrant ? P.textPrimary.opacity(0.62) : P.textTertiary).color }

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
            Text("Claude usage").font(Font.system(size: 15, weight: .semibold)).foregroundColor(primary).lineLimit(1)
            Text(snapshot == nil ? WidgetDisplay.missing : "Turn on “Show my Claude usage” in Page’s Budget settings")
                .font(Font.system(size: 12, weight: .medium)).foregroundColor((vibrant ? P.textPrimary.opacity(0.8) : P.textSecondary).color)
                .lineLimit(3).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
    }

    private func color(_ g: WidgetSnapshot.Gauge) -> P.RGBA {
        vibrant ? P.textPrimary : (WidgetDisplay.usageIsHot(g) ? P.amber : P.teal)
    }

    private func ring(_ g: WidgetSnapshot.Gauge, size: CGFloat, line: CGFloat) -> some View {
        let c = color(g)
        return ZStack {
            Circle().stroke(c.opacity(vibrant ? 0.28 : 0.18).color, lineWidth: line)
            Circle().trim(from: 0, to: CGFloat(max(0.01, g.pct / 100)))
                .stroke(c.color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: vibrant ? .clear : c.opacity(0.45).color, radius: 3)
                .pageAccent()
            Text("\(WidgetDisplay.percent(g))").font(Font.system(size: size * 0.30, weight: .bold, design: .rounded))
                .foregroundColor(primary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(line / 2 + 1.5) // room for the glow and the round cap: nothing leaves the frame
        .frame(width: size, height: size)
    }

    private func staleNote(_ s: WidgetSnapshot, _ u: WidgetSnapshot.Usage) -> String? {
        if let n = WidgetDisplay.note(s, now: now, timeZone: timeZone) { return n }
        if now.timeIntervalSince(u.updatedAt) > 6 * 3600 { return "Claude Code last reported at \(WidgetDisplay.clock(u.updatedAt, timeZone: timeZone))" }
        return nil
    }

    private func column(_ g: WidgetSnapshot.Gauge, short: String, label: String, ringSize: CGFloat, line: CGFloat) -> some View {
        VStack(spacing: 3) {
            ring(g, size: ringSize, line: line)
            Text(short).font(Font.system(size: 12, weight: .semibold)).foregroundColor(primary).lineLimit(1)
            Text(WidgetDisplay.resetText(g, now: now, timeZone: timeZone) ?? " ")
                .font(Font.system(size: 10, weight: .medium)).foregroundColor(tertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(label), \(WidgetDisplay.percent(g)) percent used"))
    }

    // Small: 1) rings and the note, 2) smaller rings and a one-line note, 3) smallest rings, no note.
    private func small(_ s: WidgetSnapshot, _ u: WidgetSnapshot.Usage) -> some View {
        func face(ring r: CGFloat, line: CGFloat, noteLines: Int) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("CLAUDE USAGE").nwLabelStyle(vibrant: vibrant).lineLimit(1).minimumScaleFactor(0.8)
                HStack(alignment: .top, spacing: 6) {
                    if let g = u.fiveHour { column(g, short: "5h", label: "5-hour limit", ringSize: r, line: line) }
                    if let g = u.sevenDay { column(g, short: "7d", label: "7-day limit", ringSize: r, line: line) }
                }
                .frame(maxHeight: .infinity, alignment: .center)
                if noteLines > 0, let n = staleNote(s, u) {
                    Text(n).font(Font.system(size: 9.5)).foregroundColor(tertiary).lineLimit(noteLines).minimumScaleFactor(0.85)
                }
            }
        }
        return TierFit({ face(ring: 56, line: 7, noteLines: 2) },
                       { face(ring: 48, line: 6, noteLines: 1) },
                       { face(ring: 40, line: 5, noteLines: 0) })
    }

    // Medium: 1) big rings, 2) smaller, 3) smallest.
    private func medium(_ s: WidgetSnapshot, _ u: WidgetSnapshot.Usage) -> some View {
        let v = WidgetDisplay.usageVerdict(u)
        func face(ring r: CGFloat, line: CGFloat) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("CLAUDE USAGE").nwLabelStyle(vibrant: vibrant).lineLimit(1)
                HStack(alignment: .center, spacing: 14) {
                    HStack(alignment: .top, spacing: 8) {
                        if let g = u.fiveHour { column(g, short: "5-hour", label: "5-hour limit", ringSize: r, line: line) }
                        if let g = u.sevenDay { column(g, short: "7-day", label: "7-day limit", ringSize: r, line: line) }
                    }
                    .frame(width: (r + 24) * 2 + 8)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(v.text).font(Font.system(size: 14, weight: .semibold))
                            .foregroundColor((v.warning && !vibrant ? P.amber : P.textPrimary).color)
                            .lineLimit(3).minimumScaleFactor(0.8)
                        Text(staleNote(s, u) ?? "Updated \(WidgetDisplay.clock(u.updatedAt, timeZone: timeZone))")
                            .font(Font.system(size: 11)).foregroundColor(tertiary)
                            .lineLimit(3).minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            }
        }
        return TierFit({ face(ring: 66, line: 8) },
                       { face(ring: 56, line: 7) },
                       { face(ring: 46, line: 6) })
    }
}
