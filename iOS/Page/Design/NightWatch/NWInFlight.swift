import SwiftUI

// The In flight section of Now, and the small callout a first-time tip is
// drawn with. Every card hands its actions to closures; the container routes
// them (open the room, retire a tip). Nothing here types anything: Steer only
// opens the room with the composer focused.

// MARK: - First-time tip

/// A one-line tip with a pointer to the element it explains. Drawn inline in
/// the stream (never over a control), dismissible, and quiet: no motion of
/// its own beyond a fade.
struct NWTipCallout: View {
    enum Pointer { case up, down }

    var text: String
    var symbol: String = "lightbulb"
    var pointer: Pointer = .up
    /// Distance of the pointer from the leading edge.
    var pointerInset: CGFloat = 36
    var onDismiss: () -> Void = {}

    private var base: NightWatch.RGBA { NightWatch.Palette.surface.mixed(with: NightWatch.Palette.teal.opacity(1), 0.13) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pointer == .up { arrow(up: true).padding(.leading, pointerInset) }
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(.footnote, weight: .semibold)).foregroundColor(NightWatch.Palette.teal.color)
                Text(text).font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(.caption2, weight: .bold)).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss tip"))
            }
            .padding(.leading, 14).padding(.vertical, 2)
            .background(NWGlassBackground(radius: 16, fill: base, rim: false))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(NightWatch.Palette.teal.opacity(0.32).color, lineWidth: 1))
            .zIndex(1)
            if pointer == .down { arrow(up: false).padding(.leading, pointerInset) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tip. \(text)"))
    }

    /// A small triangle in the card's colour, its two sloping edges in the rim's.
    private func arrow(up: Bool) -> some View {
        NWTipArrow(up: up).fill(base.color)
            .overlay(NWTipArrow(up: up).stroke(NightWatch.Palette.teal.opacity(0.32).color, lineWidth: 1))
            .frame(width: 18, height: 9)
            .padding(up ? .bottom : .top, -1)
            .accessibilityHidden(true)
    }
}

/// The pointer: an open triangle (its base is left to the card), point up or down.
struct NWTipArrow: Shape {
    var up = true
    func path(in r: CGRect) -> Path {
        var p = Path()
        let base = up ? r.maxY : r.minY, tip = up ? r.minY : r.maxY
        p.move(to: CGPoint(x: r.minX, y: base))
        p.addLine(to: CGPoint(x: r.midX, y: tip))
        p.addLine(to: CGPoint(x: r.maxX, y: base))
        return p
    }
}


// MARK: - In flight

/// When each In flight card, tile and workflow line first showed this app
/// process, and which endings have played (reference-date seconds): a line
/// seen before shows its value at once when it comes back (a scroll back, a
/// tab switch), and an ending plays once per run.
@MainActor enum NWFlightBook {
    private static var book = OneShotBook()

    static func shown(_ key: String, at t: Double) -> Double { book.start(key, now: t) }

    /// True the first time an ending is asked about.
    static func once(_ end: NowMotion.FlightEnd) -> Bool {
        let t = Date().timeIntervalSinceReferenceDate
        return book.start("end|" + end.onceKey, now: t) == t
    }

    /// Whether an ending has played already (asking does not count as playing).
    static func played(_ end: NowMotion.FlightEnd) -> Bool { book.starts["end|" + end.onceKey] != nil }
}

/// The In flight scene and the moment to draw: live on the display clock, or
/// the harness's pinned moment (absolute seconds).
struct NWFlightMotion {
    var scene = NowMotion.FlightScene()
    var pinned: Double? = nil
    var reduceMotion = false
}

/// "IN FLIGHT 3": a side-scroll strip that summarises every working session,
/// then one full card per session, as big as a Review card, so the whole
/// picture of the work is on one screen. Tapping a card opens its room on
/// Story; "Open" shows its terminal and "Steer" opens the composer. Touching
/// and holding offers the same, and Stop (which opens the room where the 0.6 s
/// hold lives). The arcs and bars sweep in, spring to new values and breathe
/// while the work runs (`NowMotion`); a stuck session goes still.
struct NWInFlightSection: View {
    var section: InFlightSection
    /// The first-time tip, when it points at one of these rows.
    var tip: NowTipTarget? = nil
    var biometry = "Face ID"
    var onOpen: (String, RoomEntry) -> Void = { _, _ in }
    var onToggle: () -> Void = {}
    var onHeader: () -> Void = {}
    var onDismissTip: (NWTip) -> Void = { _ in }
    /// What the section has seen since it appeared (`NowMotion.FlightScene`).
    @State private var scene = NowMotion.FlightScene()
    @Environment(\.nwMotion) private var pin
    @Environment(\.nwFlightScript) private var script
    @Environment(\.nwFixedPhase) private var fixedPhase
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.nwReduceMotion) private var forcedReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    /// Its own pin, or the whole of Now's (the harness's motion-now screens).
    private var pinned: Double? { pin.flatMap { $0.kind == .inflight || $0.kind == .now ? $0.time : nil } }
    /// On the display clock (not the harness).
    private var live: Bool { pinned == nil && fixedPhase == nil }

    /// Pinned (the harness): the script replayed up to that moment, as the
    /// live section would have seen it; the harness's still screens draw it
    /// long settled at their fixed phase. Live: the scene with this section
    /// already in it, so the frame that first shows a change draws it.
    private var motion: NWFlightMotion {
        if let p = pinned, let script, let r = NowMotion.replay(script, until: p) {
            return NWFlightMotion(scene: r.scene, pinned: script.base + p, reduceMotion: reduceMotion)
        }
        if let still = fixedPhase {
            return NWFlightMotion(scene: NowMotion.FlightScene(opening: section, at: 0, shown: { _, _ in -100 }), pinned: still, reduceMotion: reduceMotion)
        }
        var s = scene
        s.observe(section, at: Date().timeIntervalSinceReferenceDate, shown: { NWFlightBook.shown($0, at: $1) })
        return NWFlightMotion(scene: s, reduceMotion: reduceMotion)
    }

    var body: some View {
        let m = motion
        VStack(alignment: .leading, spacing: 12) {
            header
            if section.showsStrip {
                NWInFlightStrip(rows: section.strip, motion: m, onOpen: { onOpen($0, .story) })
                    .padding(.horizontal, -NightWatch.Space.gutter)
            }
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { i, row in
                NWInFlightCardView(row: row, index: i, extra: section.isExpanded && i >= InFlightSection.collapsedLimit, motion: m,
                                   onOpen: { onOpen(row.id, $0) })
                    .id("row-inflight-\(row.id)")
                    // Arriving is the card's own rise; leaving, a fade as the cards below close up.
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
                if let tip, tip.anchorId == row.id {
                    NWTipCallout(text: tip.tip.text(biometry: biometry), symbol: tip.tip.symbol, onDismiss: { onDismissTip(tip.tip) })
                        .padding(.top, -4)
                        .transition(.opacity)
                }
            }
            if section.isCapped {
                Button(action: onToggle) {
                    Text(section.isExpanded ? "Show fewer" : section.showAllLabel)
                        .font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.teal.color)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(section.isExpanded ? "Shows only the first few" : "Shows every working session"))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: WorkflowMotion.reducedFade) : .easeOut(duration: NowMotion.leave), value: section.rows.map(\.id))
        .onAppear { if live { scene = motion.scene } }
        .onChange(of: section) { _, s in
            guard live else { return }
            scene.observe(s, at: Date().timeIntervalSinceReferenceDate, shown: { NWFlightBook.shown($0, at: $1) })
        }
    }

    private var header: some View {
        Button(action: onHeader) {
            HStack(spacing: 8) {
                Text("IN FLIGHT").font(NightWatch.Typo.labelLarge).kerning(1.2).foregroundColor(NightWatch.Palette.teal.color)
                Text("\(section.total)").font(NightWatch.Typo.labelLarge).foregroundColor(NightWatch.Palette.textTertiary.color)
                    .nwRolls(Double(section.total), reduceMotion: reduceMotion)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                Image(systemName: "chevron.right").font(.system(.caption2, weight: .bold)).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(Text("In flight, \(section.total)"))
        .accessibilityHint(Text("Goes to Lanes"))
    }
}

/// The side-scroll summary: one small tile per working session (the ribbon),
/// with what it is doing and for how long. A tap opens that session. The
/// tiles' rings and stars run on one clock for the whole strip.
struct NWInFlightStrip: View {
    var rows: [InFlightRow]
    var motion = NWFlightMotion()
    var onOpen: (String) -> Void = { _ in }
    @State private var visible = true

    var body: some View {
        let s = motion.scene, rm = motion.reduceMotion
        let now = motion.pinned ?? Date().timeIntervalSinceReferenceDate
        ScrollView(.horizontal, showsIndicators: false) {
            NWWorkflowClock(origin: 0, until: NowMotion.animatesUntil(s, rows: rows, place: .strip, reduceMotion: rm), pinned: motion.pinned,
                            fps: NowMotion.framesPerSecond(s, rows: rows, at: now, reduceMotion: rm), holding: !visible) { t in
                HStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        Button { onOpen(r.id) } label: { tile(r, index: i, at: t) }.buttonStyle(.plain)
                            .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    }
                }
                .padding(.horizontal, NightWatch.Space.gutter)
            }
        }
        .animation(rm ? .easeOut(duration: WorkflowMotion.reducedFade) : .easeOut(duration: NowMotion.leave), value: rows.map(\.id))
        .modifier(NWOnScreen(visible: $visible))
    }

    private func tile(_ r: InFlightRow, index i: Int, at t: Double) -> some View {
        let s = motion.scene, rm = motion.reduceMotion
        let f = NowMotion.row(s, row: r, index: i, at: t, reduceMotion: rm)
        let time = r.card.turn.map { String($0.dropFirst("working ".count)) } ?? r.age.map { "\($0) ago" }
        // The ring follows the first workflow; when that one has just ended, it closes on the ring first.
        let closing = r.card.closing.first { $0.index == 0 }
        let flow = closing?.line ?? r.card.workflows.first
        let line = flow.map { NowMotion.line(s, row: r, line: $0, key: $0.name, closing: closing, place: .strip, index: i, at: t, reduceMotion: rm) }
        return HStack(spacing: 10) {
            ZStack {
                NWStarGlyph(seed: r.seed, color: r.hue.color, size: 30, glow: f.star?.glow).scaleEffect(CGFloat(f.star?.scale ?? 1))
                if let line, flow?.fraction != nil { NWFlightRing(frame: line, size: 34, lineWidth: 2).opacity(line.fold) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.project).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                Text(r.card.now).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
                HStack(spacing: 6) {
                    if r.card.health.needsAttention, let h = r.card.health.label {
                        Text(h).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.amber.color)
                    } else if let flow, let p = flow.progress {
                        ZStack(alignment: .leading) {
                            Text(p.replacingOccurrences(of: " agents", with: "")).font(NightWatch.Typo.monoMicro)
                                .foregroundColor(NightWatch.Palette.teal.mixed(with: NightWatch.Palette.amber, closing == nil ? 0 : line?.amber ?? 0).color)
                                .nwRolls(p, reduceMotion: rm)
                                .opacity(1 - (line?.check ?? 0))
                            if let line, line.check > 0 {
                                Text("✓ done").font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.teal.color).opacity(line.check)
                            }
                        }
                        .opacity(closing == nil ? 1 : line?.fold ?? 1)
                    }
                    if let time {
                        Text(time).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textQuiet.color).nwRolls(time, reduceMotion: rm)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: 200, height: 72, alignment: .leading)
        .background(tileBackground(amber: f.amber))
        .offset(y: CGFloat(f.rise.offset))
        .opacity(f.rise.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(r.spoken))
        .accessibilityHint(Text("Opens the session"))
        .accessibilityAddTraits(.isButton)
    }

    /// The tile's glass, its amber tint crossing in (and out) as the session turns stuck.
    private func tileBackground(amber: Double) -> some View {
        let fill = NightWatch.Palette.surface.opacity(0.85)
        let shape = RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
        return NWGlassBackground(radius: NightWatch.Radius.row, fill: fill.mixed(with: NightWatch.Palette.amber.opacity(0.85), 0.13 * amber))
            .overlay(shape.strokeBorder(NightWatch.Palette.amber.opacity(0.32 * amber).color, lineWidth: 1).opacity(amber > 0 ? 1 : 0))
    }
}

/// One working session, as big as a Review card: who and where, what it is
/// doing now and just did, how long, its workflows, how it is doing, and two
/// buttons in words. The body is a button that opens the room on Story; the
/// buttons sit under it, each at least 44 pt. It is drawn at one moment of
/// its motion on its own clock: the rise in, the star and the health dot
/// breathing, the workflow bars (`NWFlightBar`), a new step sliding in, and a
/// line that just ended closing.
struct NWInFlightCardView: View {
    var row: InFlightRow
    /// Its place among the cards (the rise's stagger, the breaths' phase).
    var index = 0
    /// Show all brought it in.
    var extra = false
    var motion = NWFlightMotion()
    var onOpen: (RoomEntry) -> Void = { _ in }
    @State private var visible = true
    /// One earlier step's row, and the gap under it: how far the timeline moves when a step joins it.
    @ScaledMetric(relativeTo: .caption2) private var stepPitch: CGFloat = 19.5

    private var card: InFlightCard { row.card }
    private var reduceMotion: Bool { motion.reduceMotion }

    var body: some View {
        let s = motion.scene
        let now = motion.pinned ?? Date().timeIntervalSinceReferenceDate
        NWWorkflowClock(origin: 0, until: NowMotion.animatesUntil(s, rows: [row], reduceMotion: reduceMotion), pinned: motion.pinned,
                        fps: NowMotion.framesPerSecond(s, rows: [row], at: now, reduceMotion: reduceMotion), holding: !visible) { t in
            drawn(NowMotion.row(s, row: row, index: index, extra: extra, at: t, reduceMotion: reduceMotion), at: t)
        }
        .modifier(NWOnScreen(visible: $visible))
    }

    private func drawn(_ f: NowMotion.RowFrame, at t: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { onOpen(.story) } label: {
                VStack(alignment: .leading, spacing: 12) {
                    top(f)
                    fact("NOW") { nowBlock(at: t) }
                    if let time = card.timeText {
                        fact("TIME") { text(time, NightWatch.Palette.textPrimary).nwRolls(time, reduceMotion: reduceMotion) }
                    }
                    if card.workflowHeading != nil || !card.closing.isEmpty { workflows(at: t) }
                    fact("HEALTH") { healthBlock(f) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(row.spoken))
            .accessibilityHint(Text("Opens the session"))
            HStack(spacing: 10) {
                button(.screen, enabled: row.canMirror, kind: .quiet)
                button(.type, enabled: row.canType, kind: .bright)
            }
        }
        .padding(NightWatch.Space.lg)
        .background(NWGlassBackground(radius: NightWatch.Radius.card, tint: NightWatch.Palette.teal.mixed(with: NightWatch.Palette.amber, f.amber)))
        .contextMenu {
            Button { onOpen(.screen) } label: { Label("Open", systemImage: "display") }
            Button { onOpen(.type) } label: { Label("Steer", systemImage: "arrow.turn.down.right") }
            if row.canStop { Button(role: .destructive) { onOpen(.stop) } label: { Label("Stop…", systemImage: "stop.circle") } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Open")) { onOpen(.screen) }
        .accessibilityAction(named: Text("Steer")) { onOpen(.type) }
        .accessibilityActions { if row.canStop { Button("Stop") { onOpen(.stop) } } }
        .offset(y: CGFloat(f.rise.offset))
        .opacity(f.rise.opacity)
    }

    // MARK: parts

    /// The star, the project, and where it runs.
    private func top(_ f: NowMotion.RowFrame) -> some View {
        HStack(spacing: 12) {
            NWStarGlyph(seed: row.seed, color: row.hue.color, size: 30, glow: f.star?.glow).scaleEffect(CGFloat(f.star?.scale ?? 1))
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.project).font(NightWatch.Typo.mono).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                Text(whoWhere).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
            }
            Spacer(minLength: 4)
            if card.health.needsAttention, let h = card.health.label {
                Text(h.uppercased()).font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
                    .foregroundColor(NightWatch.Palette.amber.color)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(NightWatch.Palette.amber.opacity(0.14).color))
            }
        }
    }

    /// "Claude · cmux › page · Opus 4.5".
    private var whoWhere: String {
        [row.character, row.route ?? row.host, card.model].compactMap { $0 }.joined(separator: " · ")
    }

    /// The step in words, and the few before it as a short timeline. A new
    /// step: the old one slides up and fades, the new one rises in, and the
    /// timeline moves down a row (the old step joins it, the oldest leaves).
    private func nowBlock(at t: Double) -> some View {
        let step = motion.scene.step(row.id, at: t, reduceMotion: reduceMotion)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                if let step, let out = step.frame.out {
                    nowText(step.change.now).offset(y: CGFloat(out.offset)).opacity(out.opacity)
                }
                nowText(card.now).offset(y: CGFloat(step?.frame.into.offset ?? 0)).opacity(step?.frame.into.opacity ?? 1)
            }
            previousSteps(step)
        }
    }

    private func nowText(_ s: String) -> some View {
        Text(s).font(NightWatch.Typo.monoSmall.weight(.semibold))
            .foregroundColor(NightWatch.Palette.textPrimary.color)
            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
    }

    private func previousSteps(_ step: (change: NowMotion.FlightScene.StepChange, frame: NowMotion.StepFrame)?) -> some View {
        let new = card.previous
        let old = step?.change.previous ?? new
        let travel = CGFloat(step?.frame.travel ?? 0)
        let dropped = step == nil ? [] : old.filter { !new.contains($0) }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(new.enumerated()), id: \.offset) { i, s in
                let was = old.firstIndex(of: s)
                previousStep(s, index: i)
                    .offset(y: CGFloat((was ?? i) - i) * travel * stepPitch)
                    .opacity(was == nil ? step?.frame.newest ?? 1 : 1)
            }
        }
        // An earlier step that fell off the end goes down with the rest as it fades.
        .overlay(alignment: .topLeading) {
            ForEach(Array(dropped.enumerated()), id: \.offset) { k, s in
                let slot = new.count + k
                let was = old.firstIndex(of: s) ?? slot
                previousStep(s, index: slot)
                    .offset(y: (CGFloat(slot) + CGFloat(was - slot) * travel) * stepPitch)
                    .opacity(step?.frame.dropped ?? 0)
            }
        }
    }

    private func previousStep(_ s: String, index i: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(NightWatch.Palette.textQuiet.opacity(max(0, 1 - 0.22 * Double(i))).color).frame(width: 5, height: 5)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
            Text(s).font(NightWatch.Typo.monoMicro).foregroundColor(NightWatch.Palette.textTertiary.color)
                .lineLimit(1)
        }
    }

    /// The running lines, with a line that just ended back at its place while it closes.
    private var lines: [(key: String, line: FlightWorkflowLine, closing: FlightClosingLine?)] {
        var items: [(FlightWorkflowLine, FlightClosingLine?)] = card.workflows.map { ($0, nil) }
        for c in card.closing.sorted(by: { $0.index < $1.index }) { items.insert((c.line, c), at: min(c.index, items.count)) }
        let names = NowMotion.FlightScene.names(items.map(\.0))
        return items.enumerated().map { i, it in (names[i], it.0, it.1) }
    }

    /// WORKFLOWS: the heading, then each line in words over its bar. With
    /// only a closing line left (the last one ended), the fact folds with it.
    private func workflows(at t: Double) -> some View {
        let items = lines
        let frames = items.enumerated().map { i, it in
            NowMotion.line(motion.scene, row: row, line: it.line, key: it.key, closing: it.closing, place: .card, index: i, at: t, reduceMotion: reduceMotion)
        }
        let fold = card.workflowHeading == nil ? frames.map(\.fold).max() ?? 0 : 1
        return fact("WORKFLOWS") {
            VStack(alignment: .leading, spacing: 0) {
                if let heading = card.workflowHeading {
                    Text(heading).font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.teal.color)
                        .nwRolls(heading, reduceMotion: reduceMotion)
                }
                ForEach(Array(items.enumerated()), id: \.element.key) { i, it in
                    workflowLine(it.line, frame: frames[i], closing: it.closing != nil)
                        .padding(.top, i == 0 && card.workflowHeading == nil ? 0 : 8)
                        .modifier(NWFold(fraction: frames[i].fold))
                }
            }
        }
        .modifier(NWFold(fraction: fold))
    }

    /// "Review changes · Reviewing · 3/5 agents" over its bar. Closing: done
    /// says "✓ done" in place of the count; failed or stopped turns amber.
    private func workflowLine(_ w: FlightWorkflowLine, frame f: NowMotion.LineFrame, closing: Bool) -> some View {
        let color = NightWatch.Palette.textSecondary.mixed(with: NightWatch.Palette.amber, closing ? f.amber : 0)
        // Only the count crosses to "✓ done"; the name and phase stay where they are.
        let lead = [w.name, w.phase].compactMap { $0 }.joined(separator: " · ")
        let sep = lead.isEmpty ? "" : " · "
        return VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                (Text(w.progress == nil ? lead : lead + sep) + Text(w.progress ?? "").foregroundColor(color.opacity(color.a * (1 - f.check)).color))
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor(color.color)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .nwRolls(w.text, reduceMotion: reduceMotion)
                if f.check > 0 {
                    (Text(lead + sep).foregroundColor(.clear) + Text("✓ done").foregroundColor(NightWatch.Palette.teal.opacity(f.check).color))
                        .font(NightWatch.Typo.monoMicro)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
            }
            if w.fraction != nil { NWFlightBar(frame: f) }
        }
    }

    private func healthBlock(_ f: NowMotion.RowFrame) -> some View {
        HStack(spacing: 8) {
            NWFlightDot(color: healthColor.mixed(with: NightWatch.Palette.amber, f.amber), dot: f.dot)
            Text(card.healthLine ?? "Normal")
                .font(NightWatch.Typo.monoMicro).foregroundColor(card.health.needsAttention ? NightWatch.Palette.amber.color : NightWatch.Palette.textSecondary.color)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The dot's colour while it does not need attention (amber crosses over it when it does).
    private var healthColor: NightWatch.RGBA {
        card.health == .longRunning ? NightWatch.Palette.sky : NightWatch.Palette.green
    }

    private func text(_ s: String, _ c: NightWatch.RGBA) -> some View {
        Text(s).font(NightWatch.Typo.monoSmall).foregroundColor(c.color).lineLimit(2)
    }

    /// A small caps label, and its content under it (stacked like the Mac's
    /// card, so a long step or a health line gets the card's whole width).
    private func fact<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(NightWatch.Typo.label).kerning(NightWatch.Typo.labelTracking)
                .foregroundColor(NightWatch.Palette.textTertiary.color)
                .lineLimit(1)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A button in words. A terminal Page cannot mirror or type into is dimmed,
    /// not hidden: it still opens the room, which says why.
    private func button(_ entry: RoomEntry, enabled: Bool, kind: NWButtonStyle.Kind) -> some View {
        Button { onOpen(entry) } label: { Text(entry.buttonTitle) }
            .buttonStyle(NWButtonStyle(kind: enabled ? kind : .quiet))
            .opacity(enabled ? 1 : 0.55)
            .accessibilityHint(Text(enabled ? (entry == .type ? "Opens the session with the keyboard up" : "Shows its terminal")
                                    : (entry == .type ? "Page can't type into this terminal; opens the session to say why" : "Page can't mirror this terminal; opens the session")))
    }
}

// MARK: - In flight motion parts

/// A card's workflow bar at one moment (`NowMotion.LineFrame`): the fill on
/// its track with the room's soft glow, a glint along the filled part while
/// the work runs, the leading end breathing (and flaring at a new value), and
/// a finished line's one soft pulse along the whole bar. Teal, crossing to
/// amber for a stuck session or a line that failed.
struct NWFlightBar: View {
    var frame: NowMotion.LineFrame
    var height: CGFloat = 3

    var body: some View {
        let tint = NightWatch.Palette.teal.mixed(with: NightWatch.Palette.amber, frame.amber)
        GeometryReader { g in
            let w = g.size.width
            let fill = max(height, w * CGFloat(min(1, max(0, frame.value))))
            // Every layer is the bar's own height; the glows sit behind and over it without
            // sizing it, so the bar never thickens or shifts as they grow.
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08)).frame(width: w, height: height)
                Capsule().fill(tint.color).frame(width: fill, height: height).shadow(color: tint.opacity(0.55).color, radius: 3)
                if let gl = frame.glint {
                    let span = w * CGFloat(NowMotion.glintSpan)
                    let x = -span + CGFloat(gl.position) * (fill + span)
                    LinearGradient(colors: [Color.white.opacity(0), tint.mixed(with: .init(1, 1, 1), 0.6).opacity(gl.opacity).color, Color.white.opacity(0)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: span, height: height)
                        .offset(x: x)
                        .frame(width: fill, height: height, alignment: .leading)
                        .clipShape(Capsule())
                }
            }
            .frame(width: w, height: height, alignment: .leading)
            // The finished line's pulse: a soft light round the whole bar, swelling 1 → 1.35× as it fades (the room's ring glow, small).
            .background(alignment: .leading) {
                if let p = frame.pulse {
                    Capsule().fill(tint.opacity(p.opacity).color).frame(width: w, height: height * 2.5 * CGFloat(p.scale)).blur(radius: 3)
                }
            }
            .overlay { head(tint).position(x: fill - height / 2, y: height / 2).opacity(frame.value > 0.0005 ? 1 : 0) }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The leading end: a small light that breathes while the work runs, still otherwise.
    private func head(_ tint: NightWatch.RGBA) -> some View {
        let b = frame.head ?? 0
        return ZStack {
            if let f = frame.flare {
                Circle().fill(tint.opacity(f.opacity).color).frame(width: 12 * CGFloat(f.scale), height: 12 * CGFloat(f.scale)).blur(radius: 3)
            }
            Circle().fill(tint.opacity(0.3 + 0.4 * b).color).frame(width: 12, height: 12).blur(radius: 3)
            Circle().fill(tint.mixed(with: .init(1, 1, 1), 0.55).color).frame(width: 5, height: 5)
                .scaleEffect(1 + CGFloat(WorkflowMotion.breathScale * b))
        }
        // A fixed box, so the flare grows round the head rather than moving it.
        .frame(width: 12, height: 12)
    }
}

/// A strip tile's workflow ring at one moment, round the session's star: the
/// arc with its breathing head (flaring at a new value), the 40° comet round
/// the track while the work runs (the room's orbit comet, small), and a
/// finished line's one soft pulse. In flight's own: `NWRing` stays still
/// everywhere else.
struct NWFlightRing: View {
    var frame: NowMotion.LineFrame
    var size: CGFloat = 34
    var lineWidth: CGFloat = 2

    var body: some View {
        let tint = NightWatch.Palette.teal.mixed(with: NightWatch.Palette.amber, frame.amber)
        let v = min(1, max(0, frame.value))
        ZStack {
            Circle().stroke(tint.opacity(0.2).color, lineWidth: lineWidth)
            if let c = frame.comet { comet(c, tint) }
            // A zero arc would still draw its round cap.
            Circle().trim(from: 0, to: CGFloat(v))
                .stroke(tint.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.55).color, radius: 3)
                .opacity(v > 0.0005 ? 1 : 0)
            if v > 0.0005 { head(at: v, tint) }
            if let p = frame.pulse {
                Circle().stroke(tint.opacity(p.opacity).color, lineWidth: 3).frame(width: size, height: size)
                    .scaleEffect(CGFloat(p.scale)).blur(radius: 2)
            }
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func head(at v: Double, _ tint: NightWatch.RGBA) -> some View {
        let a = v * 2 * Double.pi, r = size / 2
        let b = frame.head ?? 0
        return ZStack {
            if let f = frame.flare {
                Circle().fill(tint.opacity(f.opacity).color).frame(width: 10 * CGFloat(f.scale), height: 10 * CGFloat(f.scale)).blur(radius: 2.5)
            }
            Circle().fill(tint.opacity(0.3 + 0.4 * b).color).frame(width: 10, height: 10).blur(radius: 2.5)
            Circle().fill(tint.mixed(with: .init(1, 1, 1), 0.55).color).frame(width: 4, height: 4)
                .scaleEffect(1 + CGFloat(WorkflowMotion.breathScale * b))
        }
        .offset(x: CGFloat(sin(a)) * r, y: -CGFloat(cos(a)) * r)
    }

    /// A 40° tail of light round the track, its head at `head` (radians clockwise from 12).
    private func comet(_ head: Double, _ tint: NightWatch.RGBA) -> some View {
        let span = WorkflowMotion.cometSpan
        return Circle().trim(from: 0, to: CGFloat(span / (2 * Double.pi)))
            .stroke(AngularGradient(colors: [tint.opacity(0).color, tint.opacity(WorkflowMotion.cometOpacity).color], center: .center,
                                    startAngle: .zero, endAngle: .radians(span)),
                    style: StrokeStyle(lineWidth: lineWidth + 1, lineCap: .round))
            // The trim starts at 3 o'clock; turn it so its head is at `head`.
            .rotationEffect(.radians(head - Double.pi / 2 - span))
    }
}

/// The health dot: breathing while the work runs (green, or sky and slower
/// for a long-running command), one slow amber ring every 3 s while stuck.
struct NWFlightDot: View {
    var color: NightWatch.RGBA
    var dot: NowMotion.Dot
    var size: CGFloat = 7

    var body: some View {
        ZStack {
            if let r = dot.ring {
                Circle().stroke(color.opacity(r.opacity).color, lineWidth: 1.2).frame(width: CGFloat(r.radius) * 2, height: CGFloat(r.radius) * 2)
            }
            if let b = dot.breath {
                Circle().fill(color.opacity(WorkflowMotion.haloLow + (WorkflowMotion.haloHigh - WorkflowMotion.haloLow) * b).color)
                    .frame(width: size * 2, height: size * 2).blur(radius: size * 0.35)
            }
            Circle().fill(color.color).frame(width: size, height: size)
                .scaleEffect(1 + CGFloat(WorkflowMotion.breathScale * (dot.breath ?? 0)))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Folds its content away: `fraction` of its height (clipped while it
/// folds) and, if it `fades`, as much opacity. The same view at 1, so
/// nothing in it resets.
struct NWFold: ViewModifier {
    var fraction: Double
    var fades = true

    func body(content: Content) -> some View {
        let f = CGFloat(min(1, max(0, fraction)))
        NWFoldLayout(fraction: f) { content }
            .clipShape(NWFoldClip(folding: f < 1))
            .opacity(fades ? Double(f) : 1)
    }
}

/// Takes `fraction` of its one subview's height, top-aligned.
private struct NWFoldLayout: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        let size = s.sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * fraction)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// Clips to the bounds only while folding, so a glow round a settled line is never cut.
private struct NWFoldClip: Shape {
    var folding: Bool
    func path(in rect: CGRect) -> Path { Path(folding ? rect : rect.insetBy(dx: -400, dy: -400)) }
}

/// Whether a view is in sight in its scroll view, so a card scrolled away
/// holds its clock. iOS 18 says; before, its frame is checked against the
/// scroll view's bounds (only a change of the answer is reported).
struct NWOnScreen: ViewModifier {
    @Binding var visible: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollVisibilityChange(threshold: 0.01) { visible = $0 }
        } else {
            content.onGeometryChange(for: Bool.self) { g in
                g.bounds(of: .scrollView).map { g.frame(in: .local).intersects($0) } ?? true
            } action: { visible = $0 }
        }
    }
}

extension View {
    /// A number (or a line holding one) that rolls to each new value: the
    /// stream's spring, a 0.2 s cross-fade with Reduce Motion. Not
    /// `animated`: it changes at once (new words that cross-fade on their own).
    func nwRolls<V: Equatable>(_ value: V, reduceMotion: Bool, animated: Bool = true) -> some View {
        contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(!animated ? nil : reduceMotion ? .easeOut(duration: WorkflowMotion.reducedFade)
                       : .spring(response: WorkflowMotion.arcResponse, dampingFraction: WorkflowMotion.arcDamping), value: value)
    }
}
