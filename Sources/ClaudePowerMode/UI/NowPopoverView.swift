import SwiftUI

extension NowModel.Mood {
    var palette: NightWatch.AuroraPalette {
        switch self {
        case .needsYou: return .needsYou
        case .working: return .working
        case .quiet: return .quiet
        case .dusk: return .dusk
        }
    }

    var pulse: NWPulseOrb.Style {
        switch self {
        case .needsYou: return .needsYou
        case .working: return .working
        case .quiet: return .quiet
        case .dusk: return .dusk
        }
    }
}

// MARK: - Hold ring

/// The border that fills around a key cap while it is held (the "hold 1" of an
/// Irreversible approval): neutral at first, red in the last third.
struct NWHoldBorder: View {
    var progress: Double
    var radius: CGFloat = NightWatch.Radius.keycap

    var body: some View {
        let p = min(1, max(0, progress))
        let split = 2.0 / 3.0
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .trim(from: 0, to: CGFloat(min(p, split)))
                .stroke(Color.white.opacity(0.9), lineWidth: 2)
            if p > split {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .trim(from: CGFloat(split), to: CGFloat(p))
                    .stroke(NightWatch.Palette.red.color, lineWidth: 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The ring that fills while a key or button is held: neutral at first, red in
/// the last third (the only red besides an Irreversible chip).
struct NWHoldRing: View {
    var progress: Double
    var size: CGFloat = 26
    var lineWidth: CGFloat = 3

    var body: some View {
        let p = min(1, max(0, progress))
        let split = 2.0 / 3.0
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(p, split)))
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            if p > split {
                Circle()
                    .trim(from: CGFloat(split), to: CGFloat(p))
                    .stroke(NightWatch.Palette.red.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Row

/// One row of the Now stream: a coloured bar, the session name with its chip,
/// the command or summary, and the keys it answers to. The selected row also
/// states exactly what will be typed and where.
struct NWDecideRowView: View {
    var row: DecideRow
    var focused = false
    /// The answer is on its way: dimmed, keys do nothing.
    var sending = false
    /// 0...1 while "hold 1" is held on this row, else nil.
    var holdProgress: Double?
    var onKey: (KeyHint.Action) -> Void = { _ in }
    var onHoldBegan: () -> Void = {}
    var onHoldEnded: () -> Void = {}

    private var tint: NightWatch.RGBA { row.chip.color }
    private var irreversible: Bool { row.chip == .irreversible }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint.color)
                    .frame(width: 3, height: 32)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(row.projectName)
                            .font(NightWatch.Typo.mono)
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                            .lineLimit(1)
                        NWChip(kind: row.chip)
                    }
                    Text(row.summary)
                        .font(NightWatch.Typo.monoBody)
                        .foregroundColor(NightWatch.Palette.textSecondary.opacity(0.78).color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    ForEach(Array(row.keys.enumerated()), id: \.offset) { _, key in
                        keyCap(key)
                    }
                }
            }
            if focused, let preview = row.focusPreview {
                // While held, a short lead-in; the end of the line is what gets cut, so
                // "Will type 1 · <route>" always stays readable.
                Text(holdProgress != nil ? "Hold · Touch ID · \(preview)" : preview)
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
                .fill(irreversible ? tint.opacity(focused ? 0.11 : 0.07).color : Color.white.opacity(focused ? 0.08 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
                .strokeBorder(borderColor, lineWidth: focused ? 1.5 : 1)
        )
        .opacity(sending ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.projectName), \(row.chip.title.capitalized), \(row.summary)"))
    }

    private var borderColor: Color {
        if irreversible { return tint.opacity(focused ? 0.85 : 0.5).color }
        return focused ? NightWatch.Palette.glass.opacity(0.75).color : Color.white.opacity(0.06)
    }

    @ViewBuilder
    private func keyCap(_ key: KeyHint) -> some View {
        let cap = NWKeyCap(label: key.label, emphasised: key.action == row.returnAction)
        if key.isHold {
            // Press and hold on the cap does what holding 1 does.
            cap.overlay(Group { if let p = holdProgress { NWHoldBorder(progress: p) } })
                .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in onHoldBegan() }   // the store latches: once per press
                .onEnded { _ in onHoldEnded() })
        } else {
            Button { onKey(key.action) } label: { cap }
                .buttonStyle(.plain)
        }
    }
}

// MARK: - Composer

/// "Tell it instead": a one-line field under the row. Sent as Esc, then the
/// text, then Return (the reply planner decides what applies to the session).
struct NWComposer: View {
    @ObservedObject var store: NowStore
    var row: DecideRow
    @FocusState private var focused: Bool
    @Environment(\.nwFixedPhase) private var fixedPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble")
                    .font(Font.system(size: 12, weight: .medium))
                    .foregroundColor(NightWatch.Palette.teal.color)
                TextField("Tell it instead…", text: Binding(get: { store.composerText }, set: { store.composerText = $0 }))
                    .textFieldStyle(.plain)
                    .font(Font.system(size: 13))
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .focused($focused)
                NWKeyCap(label: "↵", emphasised: true)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(NightWatch.Palette.glass.opacity(0.6).color, lineWidth: 1))
            if let preview = row.tellPreview {
                Text(preview)
                    .font(NightWatch.Typo.monoMicro)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 4)
            }
        }
        .padding(.horizontal, 2)
        .onAppear { if fixedPhase == nil { focused = true } }
        .onChange(of: store.composerFocusToken) { _ in focused = true }
    }
}

// MARK: - In flight

/// The In-flight strip: which agents are working right now.
struct NWInFlightStrip: View {
    var agents: [NowModel.InFlightAgent]
    var maxNames = 3

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(NightWatch.Palette.teal.color).frame(width: 6, height: 6)
            Text("IN FLIGHT").nwLabel()
            Text(names)
                .font(NightWatch.Typo.monoMicro)
                .foregroundColor(NightWatch.Palette.textSecondary.color)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Text("\(agents.count)")
                .font(NightWatch.Typo.monoMicro)
                .foregroundColor(NightWatch.Palette.textTertiary.color)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(agents.count) working: \(names)"))
    }

    /// Pure. "bottle-flip · page · llm-play" (the first few; the count follows at the right).
    var names: String {
        agents.prefix(maxNames).map(\.project).joined(separator: " · ")
    }
}

// MARK: - The panel

/// The menu-bar panel: aurora header, runway, ranked rows, in-flight strip,
/// receipt line and footer. All state comes from the store, which the harness
/// fills with fixtures. Other moods swap the body: All quiet shows the day's
/// rings and the phone line, Paused for battery shows the paused agents and
/// "Resume now anyway" (with any open approvals and questions below them).
struct NWNowPopover: View {
    @ObservedObject var store: NowStore

    private var model: NowModel { store.model }

    var body: some View {
        VStack(spacing: 0) {
            NWAuroraHeader(palette: model.mood.palette, headline: model.headline, subline: model.subline,
                           pulse: model.mood.pulse)
            switch model.mood {
            case .dusk: duskBody
            default:
                if model.rows.isEmpty { quietBody } else { rowsBody }
            }
            configNotice
            stopStrip
            footer
        }
        .frame(width: NightWatch.Space.popoverWidth)
        .background(NWGlassBackground(radius: NightWatch.Radius.popover,
                                      fill: NightWatch.Palette.popoverBody, glowHeight: 30, rim: false))
        .clipShape(RoundedRectangle(cornerRadius: NightWatch.Radius.popover, style: .continuous))
        // The rim goes above the clip so it runs round the header too.
        .overlay(NWGlassRim(radius: NightWatch.Radius.popover))
    }

    // MARK: needs you / looks stuck

    private var visibleRows: [DecideRow] {
        store.expanded ? model.rows : Array(model.rows.prefix(NowModel.visibleRows))
    }

    private var rowsBody: some View {
        VStack(spacing: 0) {
            NWRunwayBar(model: model.runway)
                .padding(.top, 2)
            rowList
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
            if !model.inFlight.isEmpty { NWInFlightStrip(agents: model.inFlight) }
            statusLine
        }
    }

    @ViewBuilder
    private var rowList: some View {
        let content = VStack(spacing: 8) {
            ForEach(visibleRows) { row in
                VStack(spacing: 6) {
                    NWDecideRowView(
                        row: row, focused: row.id == store.selectedId, sending: store.sending.contains(row.id),
                        holdProgress: holdProgress(for: row),
                        onKey: { store.click($0, on: row) },
                        onHoldBegan: { store.mouseHoldBegan(.approve(rowId: row.id)) },
                        onHoldEnded: { store.mouseHoldEnded() })
                        .onTapGesture { store.select(row.id) }
                        .id(row.id)
                    if let c = store.composer, c.rowId == row.id {
                        NWComposer(store: store, row: row)
                    }
                }
            }
            if !store.expanded && model.overflowRows > 0 {
                Button { store.setExpanded(true) } label: {
                    Text("+\(model.overflowRows) more")
                        .font(NightWatch.Typo.monoSmall)
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 6)
                }
                .buttonStyle(.plain)
            }
        }
        if store.expanded && model.rows.count > 5 {
            ScrollViewReader { proxy in
                // Four and a half rows: the half row, and the scroller, say there is more.
                ScrollView(.vertical, showsIndicators: true) { content.padding(.trailing, 4) }
                    .frame(height: 4.5 * 69)
                    .onChange(of: store.selectedId) { id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
            }
        } else {
            content
        }
    }

    private func holdProgress(for row: DecideRow) -> Double? {
        guard let h = store.hold, case .approve(let id) = h.kind, id == row.id else { return nil }
        return store.holdProgress
    }

    /// The receipt of the last delivery, or the result of the last action.
    @ViewBuilder
    private var statusLine: some View {
        if let n = store.notice {
            NWReceiptLine(text: n.text, failed: n.failed)
        } else if let r = model.receiptLine {
            NWReceiptLine(text: r, failed: model.receiptFailed)
        }
    }

    // MARK: all quiet

    private var quietBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.rings.isEmpty { NWRingsRow(rings: model.rings, ringSize: 24) }
            if let phone = model.phoneLine {
                Text(phone)
                    .font(NightWatch.Typo.subline)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
            }
            if !model.inFlight.isEmpty { NWInFlightStrip(agents: model.inFlight).padding(.horizontal, -16) }
            statusLine.padding(.horizontal, -16)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: paused for battery (dusk)

    private var duskBody: some View {
        VStack(spacing: 8) {
            Rectangle().fill(Color.white.opacity(0.28)).frame(height: 1).padding(.horizontal, 12)
            VStack(spacing: 6) {
                ForEach(model.paused) { p in
                    HStack(spacing: 10) {
                        Image(systemName: "pause")
                            .font(Font.system(size: 10, weight: .bold))
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                        Text(p.project)
                            .font(NightWatch.Typo.mono)
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                            .lineLimit(1)
                        Spacer()
                        if p.summaryWritten {
                            HStack(spacing: 4) {
                                Text("summary")
                                Image(systemName: "checkmark")
                            }
                            .font(Font.system(size: 11, weight: .medium))
                            .foregroundColor(NightWatch.Palette.green.color)
                            .accessibilityLabel(Text("Summary written"))
                        } else {
                            Text(p.detail)
                                .font(NightWatch.Typo.monoMicro)
                                .foregroundColor(NightWatch.Palette.textTertiary.color)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
                        .fill(Color.white.opacity(0.045)))
                }
                if model.canResumeNow {
                    Button { store.command(.resumePaused) } label: {
                        Text("Resume now anyway")
                            .font(NightWatch.Typo.bodyStrong)
                            .foregroundColor(NightWatch.Palette.textPrimary.color)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
                                .fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            // A blocked agent is still blocked while the others are paused.
            if !model.rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("STILL WAITING ON YOU").nwLabel().padding(.leading, 6)
                    rowList
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            statusLine
        }
        .padding(.top, 6)
    }

    // MARK: config problem

    /// "Config problem · using safe values", with the way to the file.
    @ViewBuilder
    private var configNotice: some View {
        if let problem = model.configProblem {
            HStack(spacing: 9) {
                Image(systemName: "exclamationmark.triangle")
                    .font(Font.system(size: 12, weight: .medium))
                Text("Config problem · using safe values")
                    .font(Font.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Button { store.command(.openConfig) } label: {
                    Text("Open config…")
                        .font(Font.system(size: 11.5, weight: .semibold))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(NightWatch.Palette.amber.opacity(0.95).color)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(NightWatch.Palette.amber.opacity(0.07).color)
            .help(problem)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: stop all

    /// Shown while ⌘. (or the footer's stop button) is held: the ring and what
    /// it will do.
    @ViewBuilder
    private var stopStrip: some View {
        if let h = store.hold, h.kind == .stopAll {
            HStack(spacing: 12) {
                NWHoldRing(progress: store.holdProgress, size: 28, lineWidth: 3.5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep holding to stop")
                        .font(Font.system(size: 12, weight: .semibold))
                        .foregroundColor(NightWatch.Palette.textPrimary.color)
                    Text(store.stopScope)
                        .font(NightWatch.Typo.monoMicro)
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(NightWatch.Palette.red.opacity(0.08).color)
        }
    }

    // MARK: footer

    /// Key glyphs stay monospaced; the words round them are SF Pro.
    private func keyGlyphs(_ s: String) -> Text {
        Text(s).font(NightWatch.Typo.monoMicro)
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button { store.command(.newSession) } label: { keyGlyphs("⌘N") + Text(" new") }
                .buttonStyle(.plain)
            Text(" · ")
            (keyGlyphs("⌘.") + Text(" hold to stop all"))
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in store.mouseHoldBegan(.stopAll) }
                    .onEnded { _ in store.mouseHoldEnded() })
            Spacer(minLength: 8)
            Button { store.command(.preferences) } label: {
                Image(systemName: "gearshape").font(Font.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Preferences…")
            .accessibilityLabel(Text("Preferences"))
            Button { store.command(.more) } label: {
                Image(systemName: "ellipsis").font(Font.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("More")
            .accessibilityLabel(Text("More"))
            Text(model.shortcutHint).font(NightWatch.Typo.monoMicro).padding(.leading, 6)
        }
        .font(NightWatch.Typo.subline)
        .foregroundColor(NightWatch.Palette.textTertiary.color)
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Color.white.opacity(0.03))
    }
}

// MARK: - Welcome back

/// The panel that drops for a few seconds on return: the handover headline and
/// the day's rings. The eyebrow is teal and the panel neutral, as on board 05,
/// even when something needs you; the count in the headline says so.
struct NWWelcomeBackView: View {
    var model: WelcomeBack

    private var accent: NightWatch.RGBA { NightWatch.Palette.teal }

    var body: some View {
        NWGlassCard(radius: 22, glowHeight: 26, padding: 0) {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.eyebrow)
                    .font(NightWatch.Typo.labelLarge)
                    .kerning(1.6)
                    .foregroundColor(accent.color)
                Text(model.headline)
                    .font(Font.system(size: 22, weight: .bold))
                    .kerning(-0.5)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.rings.isEmpty { NWRingsRow(rings: model.rings, ringSize: 26) }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 380)
    }
}
