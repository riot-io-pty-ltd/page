import SwiftUI

// The room's other three lenses: Screen (the Mac's mirror of the terminal),
// Changes (what the turn changed, with the diff) and Workflows (a run as a
// ring of agent nodes). All of them are read-only; the only thing they can
// ask for is more of what the Mac already sends.

// MARK: - Screen

extension TerminalTone {
    var color: NightWatch.RGBA {
        switch self {
        case .tool: return NightWatch.Palette.green
        case .busy: return NightWatch.RGBA(hex: 0xE89E64)
        case .footer: return NightWatch.Palette.violet
        case .prompt: return NightWatch.Palette.textPrimary
        case .quiet: return NightWatch.Palette.textQuiet
        case .plain: return NightWatch.Palette.textSecondary
        }
    }
}

/// The session's screen as the Mac last read it, in SF Mono on dark glass,
/// following the bottom where the footer is. Wrap (remembered) folds long
/// lines so a workflow row's counts show; off, lines stay as on the Mac. A
/// row naming one of the session's workflows opens it. There are no key
/// buttons here: the room's only keyboard is its composer.
struct NWRoomScreenLens: View {
    var data: SessionRoomData
    var actions: SessionRoomActions
    @AppStorage("page.terminal.wrap") private var wrap = true

    private static let font = Font.system(size: 12, design: .monospaced)

    var body: some View {
        Group {
            if let screen = data.screen {
                VStack(spacing: 10) {
                    statusRow
                    terminal(screen)
                    Text(data.runs.isEmpty ? "Redacted before it leaves the Mac" : "Tap a workflow row to open it · redacted before it leaves the Mac")
                        .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                }
                .padding(.horizontal, NightWatch.Space.lg).padding(.top, 8).padding(.bottom, 8)
            } else {
                VStack { Spacer(); Text("The screen appears once your Mac sends it.").font(NightWatch.Typo.body)
                    .foregroundColor(NightWatch.Palette.textTertiary.color); Spacer() }.frame(maxWidth: .infinity)
            }
        }
        // The question the terminal is asking, answerable over its own screen.
        .overlay(alignment: .bottom) {
            if let ask = data.ask {
                NWAnswerHost(ask: ask, delivery: data.askDelivery, route: data.answerRoute, mac: data.macName,
                             agent: data.character.name, compact: true, viaHook: data.askViaHook, onSubmit: actions.submitAnswers)
                .padding(.horizontal, NightWatch.Space.md).padding(.bottom, 8)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            if let f = data.screenFreshness {
                let color: NightWatch.RGBA = f.tone == .live ? NightWatch.Palette.teal : (f.tone == .slow ? NightWatch.Palette.amber : NightWatch.Palette.textTertiary)
                HStack(spacing: 8) {
                    Circle().fill(color.color).frame(width: 9, height: 9)
                    Text(f.label).font(.system(.footnote, weight: .bold)).foregroundColor(color.color)
                }
                .padding(.horizontal, 14).frame(minHeight: 38)
                .background(Capsule().fill(color.opacity(0.12).color))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(f.tone == .slow ? "Screen is slow, \(f.label)" : "Screen \(f.label)"))
            }
            Text(data.session.hostLabel).font(NightWatch.Typo.monoSmall)
                .foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
            Spacer(minLength: 4)
            Button { wrap.toggle() } label: {
                Image(systemName: wrap ? "text.alignleft" : "arrow.left.and.right.text.vertical")
                    .font(.system(.body, weight: .medium))
                    .foregroundColor((wrap ? NightWatch.Palette.teal : NightWatch.Palette.textSecondary).color)
                    .frame(width: 48, height: 48)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(wrap ? NightWatch.Palette.teal.opacity(0.14).color : Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(wrap ? "Don't wrap lines" : "Wrap lines"))
        }
    }

    private func terminal(_ screen: SessionScreen) -> some View {
        let links = TerminalRunLinks.match(lines: screen.lines, runs: data.runs)
        return ScrollViewReader { proxy in
            ScrollView(wrap ? [.vertical] : [.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(screen.lines.enumerated()), id: \.offset) { i, line in
                        lineView(line, run: links[i]).id(i)
                    }
                }
                .padding(16)
                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                .textSelectionIfAvailable()
            }
            .background(NWGlassBackground(radius: 24, fill: NightWatch.Palette.inset.opacity(0.95)))
            .onAppear { proxy.scrollTo(screen.lines.count - 1, anchor: .bottomLeading) }
            .onChange(of: screen.lines) { _, lines in proxy.scrollTo(lines.count - 1, anchor: .bottomLeading) }
        }
    }

    @ViewBuilder private func lineView(_ line: String, run: WorkflowRun?) -> some View {
        let tone = run == nil ? TerminalTone.classify(line) : .footer
        let text = Text(line.isEmpty ? " " : line)
            .font(Self.font)
            .foregroundColor(tone.color.color)
            .lineLimit(wrap && tone != .quiet ? nil : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: !wrap, vertical: wrap)
            .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
        if let run {
            Button { actions.openRun(run.id) } label: {
                text.padding(.vertical, 3).padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(NightWatch.Palette.teal.opacity(0.10).color))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Workflow \(run.name), \(run.progressLabel)"))
            .accessibilityHint(Text("Opens the workflow"))
        } else {
            text
        }
    }
}

// MARK: - Changes

/// The Changes lens: the Mac's answer to "what did this turn change", or
/// what it is still doing about it. One scope comes back (this turn's files,
/// or the repository's uncommitted changes), so the scope is a label, not a
/// switch.
struct NWRoomChangesLens: View {
    var data: SessionRoomData
    var actions: SessionRoomActions

    var body: some View {
        NWChangesPanel(model: data.changes, load: data.changesLoad, onRefresh: actions.refreshChanges, onCopy: actions.copy) {
            reviewBar
        }
    }

    @ViewBuilder private var reviewBar: some View {
        if let row = data.reviewRow, data.pageOutcome == .none, row.action(.carryOn) != nil {
            VStack(alignment: .leading, spacing: 8) {
                Button { actions.looksGood(row) } label: { Text("Looks good ✦") }.buttonStyle(NWButtonStyle(kind: .bright))
                if let p = row.action(.carryOn)?.preview { NWDeliveryPreview(text: p) }
            }
        } else if let row = data.reviewRow, data.pageOutcome != .none {
            NWOutcomeStrip(outcome: data.pageOutcome, pending: data.pagePending, onCancel: { actions.cancel(row.id) })
        }
    }
}

/// The files a turn changed with +/− counts, a bar of the proportion and
/// each file's diff (the first one open). Shared by the room's Changes lens
/// and the changes sheet a finished-turn page opens.
struct NWChangesPanel<Footer: View>: View {
    var model: ChangesModel?
    var load: ChangesModel.Load
    var onRefresh: () -> Void = {}
    var onCopy: (String) -> Void = { _ in }
    @ViewBuilder var footer: () -> Footer
    @State private var opened: Set<String> = []
    @State private var seeded = false

    var body: some View {
        switch load {
        case .loaded:
            if let m = model { content(m) } else { message("exclamationmark.triangle", "No answer from your Mac.", retry: true) }
        case .loading:
            VStack(spacing: 12) {
                Spacer()
                ProgressView().tint(NightWatch.Palette.textSecondary.color)
                Text("Asking your Mac…").font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textTertiary.color)
                Spacer()
            }.frame(maxWidth: .infinity)
        case .noAnswer:
            message("wifi.exclamationmark", "No answer from your Mac. Pull down or tap Refresh to try again.", retry: true)
        case .failed(let why):
            message("exclamationmark.triangle", why, retry: true)
        }
    }

    private func message(_ symbol: String, _ text: String, retry: Bool = false) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: symbol).font(.system(.title2)).foregroundColor(NightWatch.Palette.textTertiary.color)
            Text(text).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color).multilineTextAlignment(.center)
            if retry { Button("Refresh", action: onRefresh).buttonStyle(NWButtonStyle(kind: .quiet)).frame(maxWidth: 200) }
            Spacer()
        }
        .padding(.horizontal, 32).frame(maxWidth: .infinity)
    }

    private func content(_ m: ChangesModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(m.scopeLabel).font(NightWatch.Typo.label).kerning(1.2).foregroundColor(NightWatch.Palette.textTertiary.color)
                    if let repo = m.repo {
                        Text(repo).font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(1)
                    }
                    Spacer()
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise").font(.system(.footnote, weight: .semibold))
                            .foregroundColor(NightWatch.Palette.textSecondary.color).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel(Text("Refresh"))
                }
                evidence(m)
                bar(m)
                if let note = m.note { Text(note).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color) }
                if let e = m.emptyText { Text(e).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textTertiary.color) }
                if !m.files.isEmpty { fileList(m) }
                ForEach(m.unmatchedSections) { sec in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(sec.path.isEmpty ? "Patch" : sec.path).font(NightWatch.Typo.monoSmall)
                            .foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(1).truncationMode(.head)
                        NWDiffBlock(lines: sec.lines).padding(.horizontal, -10)
                    }
                }
                if m.truncated {
                    Text("Cut short to fit — the rest is on your Mac.").font(NightWatch.Typo.caption)
                        .foregroundColor(NightWatch.Palette.textTertiary.color).frame(maxWidth: .infinity)
                }
                footer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NightWatch.Space.lg).padding(.top, 8).padding(.bottom, 12)
        }
        .refreshable { onRefresh() }
        .onAppear { if !seeded, let first = m.files.first { opened = [first.path]; seeded = true } }
    }

    private func evidence(_ m: ChangesModel) -> some View {
        HStack(spacing: 10) {
            evidenceChip(m.fileCountText, NightWatch.Palette.textPrimary, mono: false)
            evidenceChip("+\(m.added)", NightWatch.Palette.green)
            evidenceChip("−\(m.removed)", NightWatch.Palette.red.mixed(with: NightWatch.Palette.amber, 0.45))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(m.fileCountText), \(m.added) added, \(m.removed) removed"))
    }

    private func evidenceChip(_ text: String, _ c: NightWatch.RGBA, mono: Bool = true) -> some View {
        Text(text).font(mono ? .system(.subheadline, design: .monospaced, weight: .semibold) : .system(.subheadline, weight: .semibold))
            .foregroundColor(c.color)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(c.opacity(mono ? 0.13 : 0.08).color))
    }

    private func bar(_ m: ChangesModel) -> some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                Capsule().fill(NightWatch.Palette.green.color).frame(width: max(6, (geo.size.width - 4) * CGFloat(m.addedFraction)))
                if m.removed > 0 {
                    Capsule().fill(NightWatch.Palette.red.mixed(with: NightWatch.Palette.amber, 0.45).color)
                }
            }
        }
        .frame(height: 6).accessibilityHidden(true)
    }

    private func fileList(_ m: ChangesModel) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(m.files.enumerated()), id: \.element.id) { i, f in
                let on = opened.contains(f.path)
                let section = m.sections.first { $0.path == f.path }
                VStack(spacing: 0) {
                    Button { if on { opened.remove(f.path) } else { opened.insert(f.path) } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "chevron.down" : "chevron.right").font(.system(.footnote, weight: .semibold))
                                .foregroundColor(NightWatch.Palette.textTertiary.color).frame(width: 18)
                            Text(f.path).font(NightWatch.Typo.monoBody).foregroundColor(NightWatch.Palette.textPrimary.color)
                                .lineLimit(1).truncationMode(.head)
                            Spacer(minLength: 6)
                            if let a = f.added { Text("+\(a)").foregroundColor(NightWatch.Palette.green.color) }
                            if let r = f.removed { Text("−\(r)").foregroundColor(NightWatch.Palette.red.mixed(with: NightWatch.Palette.amber, 0.45).color) }
                        }
                        .font(NightWatch.Typo.monoSmall)
                        .padding(.horizontal, 16).frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("\(f.path), \(f.added.map { "\($0) added" } ?? "")"))
                    .accessibilityHint(Text(on ? "Hides the diff" : "Shows the diff"))
                    .contextMenu {
                        Button { onCopy(ChangesModel.question(about: f.path)) } label: { Label("Copy a question about this", systemImage: "questionmark.bubble") }
                    }
                    if on, let section { NWDiffBlock(lines: section.lines) }
                    if i < m.files.count - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
                }
            }
        }
        .background(NWGlassBackground(radius: 20, fill: NightWatch.Palette.surface.opacity(0.92)))
    }
}

/// A file's unified diff: hunk headers quiet, additions green, removals
/// warm, in SF Mono. Lines never wrap, so columns stay aligned; scroll sideways.
struct NWDiffBlock: View {
    var lines: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    let kind = ChangesModel.lineKind(line)
                    HStack(spacing: 0) {
                        Text(kind == .added ? "+" : (kind == .removed ? "−" : " "))
                            .frame(width: 22).foregroundColor(color(kind).color)
                        Text(line.isEmpty ? " " : (kind == .added || kind == .removed ? String(line.dropFirst()) : line))
                            .foregroundColor(color(kind).color).fixedSize()
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.vertical, 5).padding(.horizontal, 8)
                    .frame(minWidth: 300, alignment: .leading)
                    .background(background(kind))
                }
            }
            .textSelectionIfAvailable()
        }
        .background(NightWatch.Palette.inset.opacity(0.9).color)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 10).padding(.bottom, 10)
    }

    private func color(_ k: ChangesModel.LineKind) -> NightWatch.RGBA {
        switch k {
        case .hunk: return NightWatch.Palette.textTertiary
        case .added: return NightWatch.Palette.green
        case .removed: return NightWatch.Palette.red.mixed(with: NightWatch.Palette.amber, 0.45)
        case .context: return NightWatch.Palette.textSecondary
        }
    }

    private func background(_ k: ChangesModel.LineKind) -> Color {
        switch k {
        case .added: return NightWatch.Palette.green.opacity(0.10).color
        case .removed: return NightWatch.Palette.red.opacity(0.10).color
        default: return .clear
        }
    }
}

// MARK: - Workflows

extension WorkflowOrbit.NodeState {
    var color: NightWatch.RGBA {
        switch self {
        case .running: return NightWatch.Palette.teal
        case .done: return NightWatch.Palette.green
        // A failed agent is amber: red is for two hold rings only.
        case .failed: return NightWatch.Palette.amber
        case .stopped: return NightWatch.RGBA(hex: 0x8A8FA0)
        }
    }

    /// A running node is drawn larger.
    var coreSize: CGFloat { self == .running ? 20 : 15 }
    var haloSize: CGFloat { self == .running ? 30 : 22 }

    var spoken: String {
        switch self {
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        case .stopped: return "didn't finish"
        }
    }
}

/// When each run's ring closed with its pulse (reference-date seconds), so
/// the pulse plays once per run per app process however often the lens is
/// reopened: a later look gets the first moment back, long past.
@MainActor enum NWWorkflowPulseBook {
    private static var book = OneShotBook()

    static func start(_ run: String, at t: Double) -> Double { book.start(run, now: t) }
}

/// The Workflows lens's clock (and Now's In flight cards'): seconds since
/// `origin` (the entrance), redrawn at most `fps` (≤ 30) times a second
/// while `until` is ahead (for ever while the run runs, else until the
/// entrance and any one-shot have played), then one settled frame with the
/// clock paused. The harness pins it (`.workflow`, `.inflight`); it holds
/// still while its screen is covered, the app is not active, or `holding`
/// (a card scrolled out of sight). Ticking or not it is the one view, so
/// what it draws keeps its identity (a text selection, VoiceOver's place)
/// as the clock starts and stops.
struct NWWorkflowClock<Content: View>: View {
    var origin: Double
    var until: Double
    var pinned: Double?
    var fps: Double = 30
    var holding = false
    @ViewBuilder var content: (Double) -> Content
    @State private var stopped: Key?
    @Environment(\.nwAnimationsPaused) private var covered
    @Environment(\.scenePhase) private var scenePhase

    private struct Key: Equatable {
        let origin: Double
        let until: Double
    }

    var body: some View {
        let key = Key(origin: origin, until: until)
        let ticking = pinned == nil && stopped != key && Date().timeIntervalSinceReferenceDate - origin < until
        TimelineView(.animation(minimumInterval: 1.0 / max(1, min(fps, 30)), paused: !ticking || holding || covered || scenePhase != .active)) { tl in
            content(pinned ?? ((ticking ? tl.date : Date()).timeIntervalSinceReferenceDate - origin))
        }
        .task(id: key) {
            let left = origin + until - Date().timeIntervalSinceReferenceDate
            guard pinned == nil, until.isFinite, left > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
            if !Task.isCancelled { stopped = key }
        }
    }
}

/// A status dot that breathes in the workflow rhythm while `breath` (0 ... 1) is set.
private struct NWBreathingDot: View {
    var color: NightWatch.RGBA
    var size: CGFloat
    var breath: Double?

    var body: some View {
        ZStack {
            if let b = breath {
                Circle().fill(color.opacity(WorkflowMotion.haloLow + (WorkflowMotion.haloHigh - WorkflowMotion.haloLow) * b).color)
                    .frame(width: size * 2, height: size * 2).blur(radius: size * 0.35)
            }
            Circle().fill(color.color).frame(width: size, height: size)
                .scaleEffect(1 + WorkflowMotion.breathScale * (breath ?? 0))
        }
        .frame(width: size, height: size)
    }
}

/// The multi-agent run as a ring of nodes with "4/7 agents done" in the
/// middle, drawn at one moment of its motion (`WorkflowMotion.Frame`): nodes
/// entering clockwise as the arc sweeps, running nodes breathing and
/// rippling under a comet, a finished node filling, and the ring closing
/// with one soft pulse. Tap a node for that agent's transcript.
struct NWWorkflowOrbit: View {
    var frame: WorkflowMotion.Frame
    var caption: String
    /// "4 of 7 agents done, 2 running, 1 failed".
    var summary: String
    var reduceMotion = false
    var onAgent: (String) -> Void = { _ in }
    private let size: CGFloat = 300

    var body: some View {
        let radius = size / 2 - 18
        let ring = radius * 1.1
        let teal = NightWatch.Palette.teal
        ZStack {
            Group {
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 1).frame(width: radius * 2, height: radius * 2)
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 12).frame(width: ring, height: ring)
            }
            .opacity(frame.track)
            if let head = frame.comet { comet(head, radius: radius).opacity(frame.track * frame.loops) }
            // The progress ring (a zero arc would still draw its round cap).
            Circle().trim(from: 0, to: CGFloat(min(1, max(0, frame.arc))))
                .stroke(teal.color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: ring, height: ring)
                .shadow(color: teal.opacity(0.55).color, radius: 10)
                .opacity(frame.arc > 0.0005 ? frame.content : 0)
            if let b = frame.head, frame.arc > 0.0005 { head(b, at: frame.arc, radius: ring / 2).opacity(frame.content * frame.loops) }
            if let p = frame.pulse {
                Circle().stroke(teal.opacity(p.opacity).color, lineWidth: 10)
                    .frame(width: ring, height: ring).scaleEffect(CGFloat(p.scale)).blur(radius: 4)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            VStack(spacing: 2) {
                Text("\(frame.shownDone)/\(frame.total)").font(.system(size: 34, weight: .bold, design: .monospaced))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    // Past the entrance the count rolls to each new value.
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(frame.shownDone)))
                    .animation(frame.rolls ? (reduceMotion ? .easeOut(duration: WorkflowMotion.reducedFade)
                        : .spring(response: WorkflowMotion.arcResponse, dampingFraction: WorkflowMotion.arcDamping)) : nil,
                               value: frame.shownDone)
                Text(caption).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            .scaleEffect(CGFloat(frame.textScale))
            .opacity(frame.content)
            // The orbit in one sentence, read first; the nodes stay focusable after it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(summary))
            .accessibilitySortPriority(1)
            ForEach(frame.nodes) { n in node(n, radius: radius) }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func node(_ n: WorkflowMotion.NodeFrame, radius: CGFloat) -> some View {
        let x = CGFloat(sin(n.angle)) * radius, y = -CGFloat(cos(n.angle)) * radius
        let c = n.from.color.mixed(with: n.state.color, n.mix)
        let k = CGFloat(n.mix)
        let core = n.from.coreSize + (n.state.coreSize - n.from.coreSize) * k
        let halo = n.from.haloSize + (n.state.haloSize - n.from.haloSize) * k
        return Button { onAgent(n.id) } label: {
            ZStack {
                ForEach(Array(n.rings.enumerated()), id: \.offset) { _, r in
                    Circle().stroke(r.state.color.opacity(r.opacity).color, lineWidth: 1.5)
                        .frame(width: CGFloat(r.radius) * 2, height: CGFloat(r.radius) * 2)
                }
                Circle().fill(c.opacity(n.halo).color).frame(width: halo, height: halo).blur(radius: 4)
                Circle().fill(c.color).frame(width: core, height: core).scaleEffect(CGFloat(n.core))
                // A finished agent's disc fills in the done colour.
                if let f = n.fill { Circle().fill(n.state.color.color).frame(width: core, height: core).scaleEffect(CGFloat(f)) }
            }
            .scaleEffect(CGFloat(n.scale))
            .opacity(n.opacity)
            .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .offset(x: x, y: y)
        .accessibilityLabel(Text("\(n.label), \(n.state.spoken)"))
    }

    /// The arc's leading end: a small light that breathes while the run runs.
    private func head(_ b: Double, at arc: Double, radius r: CGFloat) -> some View {
        let a = min(1, arc) * 2 * Double.pi
        let teal = NightWatch.Palette.teal
        return ZStack {
            Circle().fill(teal.opacity(0.3 + 0.4 * b).color).frame(width: 22, height: 22).blur(radius: 5)
            Circle().fill(teal.mixed(with: .init(1, 1, 1), 0.55).color).frame(width: 7, height: 7)
                .scaleEffect(1 + WorkflowMotion.breathScale * b)
        }
        .offset(x: CGFloat(sin(a)) * r, y: -CGFloat(cos(a)) * r)
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    /// A 40° tail of light round the outer track, its head at `head` (radians clockwise from 12).
    private func comet(_ head: Double, radius: CGFloat) -> some View {
        let span = WorkflowMotion.cometSpan
        let teal = NightWatch.Palette.teal
        return Circle().trim(from: 0, to: CGFloat(span / (2 * Double.pi)))
            .stroke(AngularGradient(colors: [teal.opacity(0).color, teal.opacity(WorkflowMotion.cometOpacity).color], center: .center,
                                    startAngle: .zero, endAngle: .radians(span)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .frame(width: radius * 2, height: radius * 2)
            // The trim starts at 3 o'clock; turn it so its head is at `head`.
            .rotationEffect(.radians(head - Double.pi / 2 - span))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// The Workflows lens: the run as its orbit, then its agents grouped as the
/// footer counts them. The footer's own rows in Screen open here too. Each
/// opening (and each run picked) plays the entrance; while the lens is open
/// the run's changes play as they arrive (`WorkflowMotion.Scene`), and a
/// finished, settled run is drawn with its clock stopped.
struct NWRoomWorkflowsLens: View {
    var data: SessionRoomData
    var actions: SessionRoomActions
    @Binding var runId: String?
    /// The run being watched: when its entrance began and what has played since.
    @State private var watched: Watched?
    @Environment(\.nwMotion) private var pin
    @Environment(\.nwWorkflowScript) private var script
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.nwReduceMotion) private var forcedReduceMotion

    private struct Watched {
        let run: String
        let origin: Double
        var scene: WorkflowMotion.Scene
    }

    private var run: WorkflowRun? { data.runs.first { $0.id == runId } ?? data.runs.first }
    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    private var pinned: Double? { pin?.kind == .workflow ? pin?.time : nil }

    /// What the scene diffs on: the agents' states and the counts, not the run's age or tokens.
    private var runKey: [String] {
        guard let r = run else { return [] }
        return [r.id, r.status, "\(r.done)/\(r.total)"] + r.agents.map { "\($0.id) \($0.state)" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if data.runs.count > 1 { picker }
                if let run { moving(run) }
                if let line = WorkflowOrbit.finishedLine(runs: data.runs, now: data.now) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").foregroundColor(NightWatch.Palette.teal.color)
                        Text(line).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                    .padding(14).background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.045)))
                }
                Text("Workflow agents are read-only · tap one to watch its transcript")
                    .font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textQuiet.color)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, NightWatch.Space.lg).padding(.top, 8).padding(.bottom, 12)
        }
        // A fresh lens has no `watched`; one coming back into view keeps its scene rather than replaying the entrance.
        .onAppear { if watched?.run != run?.id { watch(run) } }
        .onChange(of: run?.id) { _, _ in watch(run) }
        .onChange(of: runKey) { _, _ in observe() }
    }

    /// The run's card on the lens's clock, then its agents, which need a
    /// clock only for their entrance: a running row's dot breathes on its
    /// own, so a long list is not redrawn 30 times a second.
    @ViewBuilder private func moving(_ run: WorkflowRun) -> some View {
        let orbit = WorkflowOrbit.build(run: run, now: data.now)
        let w = watched?.run == run.id ? watched : nil
        // Pinned (the harness): the script replayed up to that moment, as the live lens would have seen it.
        let scene = pinned.flatMap { t in script.flatMap { WorkflowMotion.replay($0, until: t, now: data.now)?.scene } }
            ?? w?.scene ?? WorkflowMotion.Scene(opening: orbit)
        let origin = w?.origin ?? Date().timeIntervalSinceReferenceDate
        let rowsUntil = reduceMotion ? WorkflowMotion.reducedFade
            : WorkflowMotion.rowStart(WorkflowMotion.rowsStaggered - 1) + WorkflowMotion.rowDuration
        VStack(alignment: .leading, spacing: 14) {
            NWWorkflowClock(origin: origin, until: scene.animatesUntil(reduceMotion: reduceMotion), pinned: pinned) { t in
                let frame = WorkflowMotion.frame(scene, at: t, reduceMotion: reduceMotion)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center) {
                        Text(run.name).font(.system(.title3, design: .monospaced, weight: .semibold))
                            .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(2)
                        Spacer(minLength: 8)
                        // RUNNING cross-fades to DONE or FAILED.
                        ZStack(alignment: .trailing) {
                            if let from = scene.statusFrom, frame.statusMix < 1 { runChip(from, breath: frame.breath).opacity(1 - frame.statusMix) }
                            runChip(scene.orbit, breath: frame.breath).opacity(scene.statusFrom != nil ? frame.statusMix : 1)
                        }
                    }
                    // Its own line, clear of the chip, so a change of status never reflows the card.
                    if !orbit.meta.isEmpty {
                        Text(orbit.meta).font(NightWatch.Typo.subline).foregroundColor(NightWatch.Palette.textTertiary.color)
                    }
                    if let summary = run.summary {
                        Text(summary).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }
                    NWWorkflowOrbit(frame: frame, caption: orbit.caption, summary: WorkflowMotion.summary(orbit), reduceMotion: reduceMotion,
                                    onAgent: { actions.openAgent(run.id, $0) }).padding(.top, 8)
                }
                .padding(18)
                .background(cardBackground(scene, mix: frame.statusMix))
            }
            NWWorkflowClock(origin: origin, until: rowsUntil, pinned: pinned) { t in
                agents(run, t: t, origin: origin)
            }
        }
    }

    /// A new entrance: the lens opened, or another run was picked.
    private func watch(_ run: WorkflowRun?) {
        guard pinned == nil, let run else { return }
        let origin = Date().timeIntervalSinceReferenceDate
        let opening = WorkflowMotion.Scene(opening: WorkflowOrbit.build(run: run, now: data.now))
        watched = Watched(run: run.id, origin: origin, scene: booked(opening, run: run.id, origin: origin))
    }

    /// The run changed while watched: its changes join the scene, and what finished is said once.
    private func observe() {
        guard pinned == nil, let run, var w = watched, w.run == run.id else { return }
        let orbit = WorkflowOrbit.build(run: run, now: data.now)
        let events = w.scene.observe(orbit, at: Date().timeIntervalSinceReferenceDate - w.origin)
        w.scene = booked(w.scene, run: run.id, origin: w.origin)
        watched = w
        if let text = WorkflowMotion.announcement(events, orbit: orbit) {
            var spoken = AttributedString(text)
            spoken.accessibilitySpeechAnnouncementPriority = .low
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    /// The pulse plays once per run per app process: a ring that already closed keeps its first moment, now past.
    private func booked(_ scene: WorkflowMotion.Scene, run: String, origin: Double) -> WorkflowMotion.Scene {
        guard let c = scene.completionAt else { return scene }
        var s = scene
        s.completionAt = NWWorkflowPulseBook.start(run, at: origin + c) - origin
        return s
    }

    private var picker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(data.runs) { r in
                    let on = r.id == (run?.id ?? "")
                    Button { runId = r.id } label: {
                        HStack(spacing: 6) {
                            Circle().fill((r.isRunning ? NightWatch.Palette.teal : NightWatch.Palette.textTertiary).color).frame(width: 8, height: 8)
                            Text(r.name).font(NightWatch.Typo.monoSmall).lineLimit(1)
                        }
                        .foregroundColor((on ? NightWatch.Palette.textPrimary : NightWatch.Palette.textSecondary).color)
                        .padding(.horizontal, 14).frame(minHeight: 40)
                        .background(Capsule().fill(on ? Color.white.opacity(0.13) : Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private func runChip(_ o: WorkflowOrbit, breath: Double?) -> some View {
        let c: NightWatch.RGBA = o.isRunning ? NightWatch.Palette.teal : (o.status == "failed" || o.status == "stalled" ? NightWatch.Palette.amber : NightWatch.Palette.textSecondary)
        return HStack(spacing: 6) {
            NWBreathingDot(color: c, size: 8, breath: o.isRunning ? breath : nil)
            Text(o.statusLabel.uppercased()).font(NightWatch.Typo.label).kerning(1)
        }
        .foregroundColor(c.color).padding(.horizontal, 12).frame(minHeight: 34)
        .background(Capsule().fill(c.opacity(0.14).color))
    }

    /// The card, teal-tinted while the run runs; the tint cross-fades as it
    /// stops (two cards only for those 0.35 s, so a settled card is the one
    /// card). The new card lies beneath and the old one fades off it, so its
    /// teal rim is gone by the end rather than vanishing at it.
    @ViewBuilder private func cardBackground(_ scene: WorkflowMotion.Scene, mix: Double) -> some View {
        let now = NWGlassBackground(radius: 28, tint: scene.orbit.isRunning ? NightWatch.Palette.teal : nil)
        if let from = scene.statusFrom, from.isRunning != scene.orbit.isRunning, mix < 1 {
            ZStack {
                now
                NWGlassBackground(radius: 28, tint: from.isRunning ? NightWatch.Palette.teal : nil).opacity(1 - mix)
            }
        } else {
            now
        }
    }

    private func agents(_ run: WorkflowRun, t: Double, origin: Double) -> some View {
        let groups = WorkflowOrbit.groups(run)
        // Where each group's first row falls down the list, for the rows' stagger.
        let firsts = groups.indices.map { gi in groups[..<gi].reduce(0) { $0 + $1.agents.count } }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(groups.enumerated()), id: \.element.title) { gi, g in
                let lead = WorkflowMotion.row(t, index: firsts[gi], reduceMotion: reduceMotion)
                Text("\(g.title.uppercased()) · \(g.agents.count)").nwLabel().padding(.top, 4)
                    .offset(y: CGFloat(lead.offset)).opacity(lead.opacity)
                VStack(spacing: 0) {
                    ForEach(Array(g.agents.enumerated()), id: \.element.id) { i, a in
                        let state = WorkflowOrbit.nodeState(a)
                        let rise = WorkflowMotion.row(t, index: firsts[gi] + i, reduceMotion: reduceMotion)
                        Button { actions.openAgent(run.id, a.id) } label: {
                            HStack(spacing: 14) {
                                rowDot(state, live: run.isRunning && state == .running && !reduceMotion, origin: origin)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(a.label).font(NightWatch.Typo.bodyStrong).foregroundColor(NightWatch.Palette.textPrimary.color)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    Text(agentMeta(a, state)).font(NightWatch.Typo.caption)
                                        .foregroundColor((state == .failed ? NightWatch.Palette.amber : NightWatch.Palette.textTertiary).color)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right").font(.system(.footnote, weight: .semibold))
                                    .foregroundColor(NightWatch.Palette.textQuiet.color)
                            }
                            .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 60)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("\(a.label), \(state.spoken)"))
                        .offset(y: CGFloat(rise.offset)).opacity(rise.opacity)
                        if i < g.agents.count - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).opacity(rise.opacity) }
                    }
                }
                // The card comes in with its first row; each row rises into it.
                .background(NWGlassBackground(radius: 20, fill: NightWatch.Palette.surface.opacity(0.92)).opacity(lead.opacity))
            }
            if run.agents.isEmpty {
                Text("No agents have started yet.").font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
        }
    }

    /// A running row's dot breathes with the orbit, on a clock of its own so the rows around it stay still.
    @ViewBuilder private func rowDot(_ state: WorkflowOrbit.NodeState, live: Bool, origin: Double) -> some View {
        if live {
            NWWorkflowClock(origin: origin, until: .infinity, pinned: pinned) { t in
                NWBreathingDot(color: state.color, size: 10, breath: WorkflowMotion.breath(t))
            }
        } else {
            NWBreathingDot(color: state.color, size: 10, breath: nil)
        }
    }

    private func agentMeta(_ a: WorkflowRun.Agent, _ state: WorkflowOrbit.NodeState) -> String {
        var parts: [String] = []
        if let p = a.phase { parts.append(p) }
        if state == .failed, let at = a.lastActivityAt { parts.append("failed \(RelativeTime.ago(since: at, now: data.now))") }
        else if let at = a.lastActivityAt { parts.append(RelativeTime.ago(since: at, now: data.now)) }
        else if state == .failed { parts.append("failed") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - A workflow agent

/// One workflow agent: what it was asked, what it did, what it said. Read
/// only. It lives inside a run, so its header names the run it belongs to.
/// Its items rise in as the lens's rows do (the first ones staggered, later
/// ones as they arrive) and its chip's dot breathes while it runs; Reduce
/// Motion draws them still.
struct NWAgentRoomScreen: View {
    var runName: String
    var agentLabel: String
    var state: WorkflowOrbit.NodeState
    var model: AgentRoomModel?
    var onBack: () -> Void = {}
    /// The screen's clock starts as it opens (reference-date seconds).
    @State private var origin = Date().timeIntervalSinceReferenceDate
    /// When items that came after the opening started rising (seconds after `origin`).
    @State private var arrivals: [String: Double] = [:]
    @State private var known: Set<String>?
    @Environment(\.nwMotion) private var pin
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.nwReduceMotion) private var forcedReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || forcedReduceMotion }
    private var pinned: Double? { pin?.kind == .workflow ? pin?.time : nil }
    /// The task card, then the blocks, by id.
    private var itemIds: [String] { (model?.task == nil ? [] : ["task"]) + (model?.blocks.map(\.id) ?? []) }

    var body: some View {
        ZStack {
            NWBackdrop()
            VStack(spacing: 0) {
                header
                ScrollView {
                    NWWorkflowClock(origin: origin, until: riseUntil, pinned: pinned) { t in
                        VStack(alignment: .leading, spacing: 12) {
                            if let model {
                                if model.truncated {
                                    Text("Earlier steps aren't shown").font(NightWatch.Typo.caption)
                                        .foregroundColor(NightWatch.Palette.textQuiet.color).frame(maxWidth: .infinity)
                                }
                                if let task = model.task { rising(taskCard(task), id: "task", index: 0, t: t) }
                                ForEach(Array(model.blocks.enumerated()), id: \.element.id) { i, b in
                                    rising(block(b), id: b.id, index: i + (model.task == nil ? 0 : 1), t: t)
                                }
                                if model.blocks.isEmpty && model.task == nil {
                                    Text("Nothing yet.").font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textTertiary.color)
                                }
                            } else {
                                HStack(spacing: 10) { ProgressView().tint(NightWatch.Palette.textSecondary.color); Text("Asking your Mac…") }
                                    .font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textTertiary.color)
                                    .frame(maxWidth: .infinity).padding(.top, 40)
                            }
                            NWInfoNote(text: AgentRoomModel.readOnlyNote, symbol: "eye").padding(.top, 8)
                        }
                        .padding(.horizontal, NightWatch.Space.lg).padding(.vertical, 12)
                    }
                }
                .defaultScrollAnchor(.bottom)
            }
        }
        .onAppear { arrive(itemIds) }
        .onChange(of: itemIds) { _, ids in arrive(ids) }
    }

    /// Items there when the transcript first shows rise staggered from the
    /// opening; later ones rise as they arrive.
    private func arrive(_ ids: [String]) {
        guard pinned == nil else { return }
        guard let seen = known else { known = Set(ids); return }
        let fresh = ids.filter { !seen.contains($0) && arrivals[$0] == nil }
        guard !fresh.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate - origin
        // The first items after an empty "Asking your Mac…" still stagger, from now.
        for (i, id) in fresh.enumerated() {
            arrivals[id] = now + (seen.isEmpty ? WorkflowMotion.rowStart(i) - WorkflowMotion.rowStart : 0)
        }
        known = seen.union(ids)
    }

    /// When item `id` starts rising. One drawn before its arrival is recorded
    /// (the body runs before `onChange`) waits, hidden, rather than blink in first.
    private func riseStart(_ id: String, index: Int) -> Double {
        if let a = arrivals[id] { return a }
        if pinned == nil, let known, !known.contains(id) { return .infinity }
        return WorkflowMotion.rowStart(index)
    }

    private var riseUntil: Double {
        guard !reduceMotion else { return 0 }
        let starts = itemIds.enumerated().map { riseStart($0.element, index: $0.offset) }.filter(\.isFinite)
        return (starts.max() ?? 0) + WorkflowMotion.rowDuration
    }

    private func rising<V: View>(_ v: V, id: String, index: Int, t: Double) -> some View {
        let r = reduceMotion ? (offset: 0.0, opacity: 1.0) : WorkflowMotion.rise(t - riseStart(id, index: index))
        return v.offset(y: CGFloat(r.offset)).opacity(r.opacity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.system(.body, weight: .semibold))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .frame(width: 48, height: 48).nwChromeGlass(in: Circle()) { Circle().fill(Color.white.opacity(0.09)) }
            }
            .buttonStyle(.plain).accessibilityLabel(Text("Back"))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(runName)").font(NightWatch.Typo.monoSmall).foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
                Text(agentLabel).font(.system(.title3, weight: .bold)).foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(2)
            }
            Spacer(minLength: 6)
            let c = state.color
            let live = state == .running && !reduceMotion
            HStack(spacing: 6) {
                // Breathes in the lens's rhythm while the agent runs.
                NWWorkflowClock(origin: origin, until: live ? .infinity : 0, pinned: pinned) { t in
                    NWBreathingDot(color: c, size: 8, breath: live ? WorkflowMotion.breath(t) : nil)
                }
                Text(state == .running ? "RUNNING" : (state == .done ? "DONE" : (state == .failed ? "FAILED" : "STOPPED")))
                    .font(NightWatch.Typo.label).kerning(1)
            }
            .foregroundColor(c.color).padding(.horizontal, 12).frame(minHeight: 34)
            .background(Capsule().fill(c.opacity(0.14).color))
            .animation(.easeOut(duration: reduceMotion ? WorkflowMotion.reducedFade : WorkflowMotion.crossFade), value: state)
        }
        .padding(.horizontal, NightWatch.Space.lg).padding(.top, 14).padding(.bottom, 6)
    }

    private func taskCard(_ task: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TASK FROM THE WORKFLOW").font(NightWatch.Typo.label).kerning(1.2).foregroundColor(NightWatch.Palette.violet.color)
            Text(task).font(.system(.body)).foregroundColor(NightWatch.Palette.textPrimary.color).fixedSize(horizontal: false, vertical: true)
                .textSelectionIfAvailable()
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 20, fill: NightWatch.Palette.surface.mixed(with: NightWatch.Palette.violet.opacity(1), 0.06).opacity(0.95)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func block(_ b: StoryBlock) -> some View {
        switch b {
        case .steps(_, let steps, _):
            VStack(spacing: 8) {
                ForEach(steps) { s in
                    HStack(spacing: 14) {
                        Image(systemName: s.symbol).foregroundColor(NightWatch.Palette.textTertiary.color).frame(width: 24)
                        Text(s.title).font(s.mono ? NightWatch.Typo.monoBody : NightWatch.Typo.body)
                            .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(3)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 52)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.05)))
                }
            }
        case .assistant(let e):
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkle").font(.system(.subheadline)).foregroundColor(NightWatch.Palette.violet.color)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NightWatch.Palette.violet.opacity(0.16).color))
                Text(e.text).font(.system(.body)).foregroundColor(NightWatch.Palette.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true).textSelectionIfAvailable()
                Spacer(minLength: 0)
            }
        case .marker(_, let text):
            Text(text).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color).frame(maxWidth: .infinity)
        case .user(let entry, _):
            // A later instruction the workflow gave this agent.
            VStack(alignment: .leading, spacing: 4) {
                Text("FROM THE WORKFLOW").font(NightWatch.Typo.label).kerning(1.2).foregroundColor(NightWatch.Palette.violet.color)
                Text(entry.text).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                    .fixedSize(horizontal: false, vertical: true).textSelectionIfAvailable()
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.045)))
        case .pending, .divider:
            EmptyView()
        }
    }
}
