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
}

/// The multi-agent run as a ring of nodes with "4/7 agents done" in the
/// middle. Tap a node for that agent's transcript.
struct NWWorkflowOrbit: View {
    var orbit: WorkflowOrbit
    var onAgent: (String) -> Void = { _ in }
    private let size: CGFloat = 300

    var body: some View {
        let radius = size / 2 - 18
        ZStack {
            Circle().stroke(Color.white.opacity(0.07), lineWidth: 1).frame(width: radius * 2, height: radius * 2)
            // The progress ring.
            Circle().stroke(Color.white.opacity(0.07), lineWidth: 12).frame(width: radius * 1.1, height: radius * 1.1)
            Circle().trim(from: 0, to: CGFloat(orbit.total > 0 ? Double(orbit.done) / Double(orbit.total) : 0))
                .stroke(NightWatch.Palette.teal.color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90)).frame(width: radius * 1.1, height: radius * 1.1)
                .shadow(color: NightWatch.Palette.teal.opacity(0.55).color, radius: 10)
            VStack(spacing: 2) {
                Text(orbit.centre).font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundColor(NightWatch.Palette.textPrimary.color)
                Text(orbit.caption).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            ForEach(orbit.nodes) { n in
                let x = CGFloat(sin(n.angle)) * radius, y = -CGFloat(cos(n.angle)) * radius
                Button { onAgent(n.id) } label: {
                    ZStack {
                        Circle().fill(n.state.color.opacity(0.25).color).frame(width: n.state == .running ? 30 : 22, height: n.state == .running ? 30 : 22).blur(radius: 4)
                        Circle().fill(n.state.color.color).frame(width: n.state == .running ? 20 : 15, height: n.state == .running ? 20 : 15)
                    }
                    .frame(width: 44, height: 44).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: x, y: y)
                .accessibilityLabel(Text("\(n.label), \(n.state == .running ? "running" : (n.state == .done ? "done" : (n.state == .failed ? "failed" : "didn't finish")))"))
            }
        }
        .frame(width: size, height: size)
        .frame(maxWidth: .infinity)
    }
}

/// The Workflows lens: the run as its orbit, then its agents grouped as the
/// footer counts them. The footer's own rows in Screen open here too.
struct NWRoomWorkflowsLens: View {
    var data: SessionRoomData
    var actions: SessionRoomActions
    @Binding var runId: String?

    private var run: WorkflowRun? { data.runs.first { $0.id == runId } ?? data.runs.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if data.runs.count > 1 { picker }
                if let run {
                    let orbit = WorkflowOrbit.build(run: run, now: data.now)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(run.name).font(.system(.title3, design: .monospaced, weight: .semibold))
                                    .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(2)
                                if !orbit.meta.isEmpty {
                                    Text(orbit.meta).font(NightWatch.Typo.subline).foregroundColor(NightWatch.Palette.textTertiary.color)
                                }
                            }
                            Spacer(minLength: 8)
                            runChip(run)
                        }
                        if let summary = run.summary {
                            Text(summary).font(NightWatch.Typo.caption).foregroundColor(NightWatch.Palette.textSecondary.color)
                                .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                        }
                        NWWorkflowOrbit(orbit: orbit, onAgent: { actions.openAgent(run.id, $0) }).padding(.top, 8)
                    }
                    .padding(18)
                    .background(NWGlassBackground(radius: 28, tint: run.isRunning ? NightWatch.Palette.teal : nil))
                    agents(run)
                }
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

    private func runChip(_ run: WorkflowRun) -> some View {
        let c: NightWatch.RGBA = run.isRunning ? NightWatch.Palette.teal : (run.status == "failed" || run.status == "stalled" ? NightWatch.Palette.amber : NightWatch.Palette.textSecondary)
        return HStack(spacing: 6) {
            Circle().fill(c.color).frame(width: 8, height: 8)
            Text(run.statusLabel.uppercased()).font(NightWatch.Typo.label).kerning(1)
        }
        .foregroundColor(c.color).padding(.horizontal, 12).frame(minHeight: 34)
        .background(Capsule().fill(c.opacity(0.14).color))
    }

    private func agents(_ run: WorkflowRun) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(WorkflowOrbit.groups(run), id: \.title) { g in
                Text("\(g.title.uppercased()) · \(g.agents.count)").nwLabel().padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(g.agents.enumerated()), id: \.element.id) { i, a in
                        let state = WorkflowOrbit.nodeState(a)
                        Button { actions.openAgent(run.id, a.id) } label: {
                            HStack(spacing: 14) {
                                Circle().fill(state.color.color).frame(width: 10, height: 10)
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
                        .accessibilityLabel(Text("\(a.label), \(state == .running ? "running" : (state == .done ? "done" : (state == .failed ? "failed" : "didn't finish")))"))
                        if i < g.agents.count - 1 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
                    }
                }
                .background(NWGlassBackground(radius: 20, fill: NightWatch.Palette.surface.opacity(0.92)))
            }
            if run.agents.isEmpty {
                Text("No agents have started yet.").font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textTertiary.color)
            }
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
struct NWAgentRoomScreen: View {
    var runName: String
    var agentLabel: String
    var state: WorkflowOrbit.NodeState
    var model: AgentRoomModel?
    var onBack: () -> Void = {}

    var body: some View {
        ZStack {
            NWBackdrop()
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let model {
                            if model.truncated {
                                Text("Earlier steps aren't shown").font(NightWatch.Typo.caption)
                                    .foregroundColor(NightWatch.Palette.textQuiet.color).frame(maxWidth: .infinity)
                            }
                            if let task = model.task { taskCard(task) }
                            ForEach(model.blocks) { b in block(b) }
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
                .defaultScrollAnchor(.bottom)
            }
        }
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
            HStack(spacing: 6) {
                Circle().fill(c.color).frame(width: 8, height: 8)
                Text(state == .running ? "RUNNING" : (state == .done ? "DONE" : (state == .failed ? "FAILED" : "STOPPED")))
                    .font(NightWatch.Typo.label).kerning(1)
            }
            .foregroundColor(c.color).padding(.horizontal, 12).frame(minHeight: 34)
            .background(Capsule().fill(c.opacity(0.14).color))
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
