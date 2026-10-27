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

/// Each row's frame in the popover's space, for Final approach.
struct NWRowFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, b in b })
    }
}

/// The header sky at a moment: the mood's palette, moved by the exhale
/// (signature motion 1) or by dusk and dawn (5), with the session stars.
enum NowSky {
    /// The stars fade once every one has relit and dawn is done.
    static let starFade: TimeInterval = 0.6
    /// How far into the night the paused sky settles: all the way, near-black
    /// with only the horizon (board 07, "paused · horizon only").
    static let pausedDepth = 1.0
    /// What is left of the background star field once paused (it fades with the dusk).
    static let pausedStarField = 0.05

    /// Pure. When each paused session's star relights (seconds after dawn began).
    static func relightTimes(_ d: NowMotion.Dawn) -> [String: TimeInterval] {
        DuskDawnModel.relightTimes(d.stars.map { s in
            DuskDawnModel.Star(id: s.id, height: NWSkyStar.place(id: s.id, light: 0).y / NWSky().horizonAt,
                               confirmedAt: d.confirmed[s.id].map { max(0, $0.timeIntervalSince(d.startedAt)) })
        })
    }

    /// Pure. The palette and sky at `now`. Reduce Motion shows each state's end.
    static func look(model: NowModel, motion: NowMotion, now: Date,
                     reduceMotion: Bool) -> (palette: NightWatch.AuroraPalette, sky: NWSky) {
        let base = model.mood.palette
        let paused = NightWatch.AuroraPalette.working.towardNight(pausedDepth)
        if model.mood == .dusk {
            let e = motion.duskAt.map { reduceMotion ? DuskDawnModel.duskDuration : now.timeIntervalSince($0) } ?? DuskDawnModel.duskDuration
            let d = DuskDawnModel.dusk(elapsed: e)
            var sky = NWSky(horizon: d.horizon, starField: 1 - (1 - pausedStarField) * d.duskMix)
            sky.stars = model.paused.map { NWSkyStar.place(id: $0.id, light: d.stars) }
            return (NightWatch.AuroraPalette.working.towardNight(pausedDepth * d.duskMix), sky)
        }
        if let dawn = motion.dawn {
            let times = relightTimes(dawn)
            let allLit = dawn.stars.allSatisfy { times[$0.id] != nil }
            let end = max(DuskDawnModel.dawnDuration, (times.values.max() ?? 0) + DuskDawnModel.relightDuration)
            let e = reduceMotion ? end + starFade : now.timeIntervalSince(dawn.startedAt)
            let fade = allLit ? 1 - MotionCurve.segment(e, start: end, duration: starFade) : 1
            let d = DuskDawnModel.dawn(elapsed: e)
            if fade <= 0 && d.finished { return (base, .clear) }
            var sky = NWSky(horizon: d.horizon, dawnFront: d.front, dawnGlow: d.glow,
                            starField: pausedStarField + (1 - pausedStarField) * d.auroraReturn)
            sky.stars = dawn.stars.map { NWSkyStar.place(id: $0.id, light: DuskDawnModel.starLight(elapsed: e, relitAt: times[$0.id]) * fade) }
            return (paused.mixed(with: base, d.auroraReturn), sky)
        }
        if let c = motion.clearedAt, model.mood != .needsYou, !reduceMotion {
            let x = PulseModel.exhale(elapsed: now.timeIntervalSince(c))
            return (NightWatch.AuroraPalette.needsYou.mixedPerceptual(with: base, x.auroraSettle), .clear)
        }
        return (base, .clear)
    }

    /// Pure. The header's words at `now`: the model's, except while dawn is
    /// relighting the paused stars. Then an agent counts as working only once
    /// its star has relit (its resume confirmed and the sweep past it), so the
    /// words never claim a resume the light has not shown. Reduce Motion
    /// counts every confirmed resume at once.
    static func lines(model: NowModel, motion: NowMotion, now: Date,
                      reduceMotion: Bool) -> (headline: String, subline: String) {
        guard model.mood != .dusk, let dawn = motion.dawn else { return (model.headline, model.subline) }
        let times = relightTimes(dawn)
        let e = reduceMotion ? Double.infinity : now.timeIntervalSince(dawn.startedAt)
        let dark = Set(dawn.stars.map(\.id).filter { id in times[id].map { e < $0 } ?? true })
        let unlit = model.inFlight.filter { dark.contains($0.id) }.count
        guard unlit > 0 else { return (model.headline, model.subline) }
        let working = max(0, model.workingCount - unlit)
        let need = model.needYouCount, look = model.lookCount
        // The same words NowModel.build uses, with the count the light has reached.
        if need > 0 || look > 0 {
            let n = need > 0 ? need : look
            let what = need > 0 ? (n == 1 ? "needs you" : "need you") : (n == 1 ? "needs a look" : "need a look")
            return (working > 0 ? "\(n) \(what) · \(working) working" : "\(n) \(what)", model.subline)
        }
        return ("All quiet", working > 0 ? "\(working) working · resuming the rest" : "resuming after the pause")
    }
}

// The hold ring (NWHoldBorder, NWHoldRing) lives with the other signature
// motions in Components/NWSignature.swift.

// MARK: - Row

/// One row of the Now stream: a coloured bar, the session name with its chip,
/// the command or summary, and the keys it answers to. The selected row also
/// states exactly what will be typed and where. Once answered it carries the
/// receipt thread (signature motion 3): the thread waits short of the Mac
/// until the delivery is confirmed, then the row folds into a hairline and
/// drifts away; a failure snaps the thread back and shakes the row once.
struct NWDecideRowView: View {
    var row: DecideRow
    var focused = false
    /// The answer is on its way: dimmed, keys do nothing.
    var sending = false
    /// 0...1 while "hold 1" is held on this row, else nil.
    var holdProgress: Double?
    /// The reply's receipt thread, once answered.
    var thread: NowMotion.Thread? = nil
    /// The hold on this row's cap was let go early: it unwinds.
    var unwind: NowMotion.Unwind? = nil
    /// Touch ID passed for this row: the cap's ring bursts.
    var burst: NowMotion.Burst? = nil
    var onKey: (KeyHint.Action) -> Void = { _ in }
    var onHoldBegan: () -> Void = {}
    var onHoldEnded: () -> Void = {}
    @Environment(\.nwReduceMotion) private var reduceMotion

    private var tint: NightWatch.RGBA { row.chip.color }
    private var irreversible: Bool { row.chip == .irreversible }

    /// Pure. The thread's frame at `now` (seconds on the reference clock).
    static func threadFrame(_ t: NowMotion.Thread, now: Date, reduceMotion: Bool) -> ReceiptThreadModel.Frame {
        ReceiptThreadModel.frame(now: now.timeIntervalSinceReferenceDate, armedAt: nil,
                                 sentAt: t.sentAt?.timeIntervalSinceReferenceDate,
                                 resolvedAt: t.resolvedAt?.timeIntervalSinceReferenceDate,
                                 resolution: t.resolution, reduceMotion: reduceMotion)
    }

    var body: some View {
        if let th = thread, th.sentAt != nil || th.authenticating {
            // Resolving: a one-shot at 60 fps. Waiting on the Mac (up to its 25 s
            // timeout): the head breathes at 20, which is plenty for a 1.2 s breath.
            let resolving = th.resolvedAt != nil
            NWOneShot(start: th.resolvedAt ?? th.sentAt, duration: resolving ? ReceiptThreadModel.resolveDuration + 0.05 : 30,
                      fps: resolving ? NWMotionRate.oneShot : 20) { now in
                let f = Self.threadFrame(th, now: now, reduceMotion: reduceMotion)
                card(thread: f, authenticating: th.authenticating)
                    .scaleEffect(x: 1, y: 1 - 0.96 * f.fold, anchor: .center)
                    .overlay(hairline(f))
                    .offset(x: f.shake, y: 16 * f.drift)
                    .opacity(1 - f.drift)
            }
        } else {
            card(thread: nil, authenticating: false)
        }
    }

    /// The folded row: a teal hairline where the card was.
    private func hairline(_ f: ReceiptThreadModel.Frame) -> some View {
        Rectangle()
            .fill(LinearGradient(colors: [NightWatch.Palette.teal.opacity(0).color, NightWatch.Palette.teal.color,
                                          NightWatch.Palette.teal.opacity(0).color],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(height: 1.5)
            .shadow(color: NightWatch.Palette.teal.opacity(0.7).color, radius: 3)
            .padding(.horizontal, 18)
            .opacity(MotionCurve.smoothstep(0.55, 1, f.fold))
            .allowsHitTesting(false)
    }

    private func card(thread f: ReceiptThreadModel.Frame?, authenticating: Bool) -> some View {
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
            }
            .opacity(sending || f != nil ? 0.5 : 1)
            if let f {
                NWReceiptStrip(frame: f, authenticating: authenticating)
                    .padding(.leading, 9)
            } else if !sending, !(row.keys + row.moreKeys).isEmpty {
                // Every action in words, always there: Approve, Deny, Steer, Open. The keys
                // work too, and live in each button's tooltip and the shortcuts sheet.
                actionStrip(authenticating: authenticating)
                    .padding(.leading, 15)
            }
            if f == nil, focused, let preview = row.focusPreview {
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
        .opacity(sending && f == nil ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.projectName), \(row.chip.title.capitalized), \(row.summary)"))
    }

    /// The row's actions as buttons in words. Return is marked on the one it
    /// does (a brighter button); an Irreversible approval keeps its press-and-hold.
    @ViewBuilder
    private func actionStrip(authenticating: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array((row.keys + row.moreKeys).enumerated()), id: \.offset) { _, key in
                stripButton(key, authenticating: authenticating)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func stripButton(_ key: KeyHint, authenticating: Bool) -> some View {
        let title = row.buttonTitle(for: key.action)
        let help = key.action.tooltip(key: key.label)
        let label = NWActionLabel(title: title, emphasised: key.action == row.returnAction)
        if key.isHold {
            label.overlay(holdRing(authenticating: authenticating))
                .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in onHoldBegan() }
                .onEnded { _ in onHoldEnded() })
                .help(help)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(Text("\(title), hold key 1"))
        } else {
            NWActionButton(title: title, emphasised: key.action == row.returnAction, help: help) { onKey(key.action) }
        }
    }

    private var borderColor: Color {
        if irreversible { return tint.opacity(focused ? 0.85 : 0.5).color }
        return focused ? NightWatch.Palette.glass.opacity(0.75).color : Color.white.opacity(0.06)
    }

    /// The ring on the hold button (signature motion 4): filling while held, full
    /// while Touch ID is up, bursting once it passes, unwinding when let go early.
    @ViewBuilder
    private func holdRing(authenticating: Bool) -> some View {
        if let p = holdProgress {
            NWHoldBorder(progress: p)
        } else if authenticating {
            NWHoldBorder(progress: 1)
        } else if let b = burst, b.rowId == row.id, !reduceMotion {
            NWOneShot(start: b.at, duration: HoldRingModel.burstDuration) { now in
                let f = HoldRingModel.burst(elapsed: now.timeIntervalSince(b.at))
                NWHoldBorder(progress: 1, flash: f.flash)
                    .scaleEffect(CGFloat(f.scale))
                    .opacity(f.alpha)
            }
        } else if let u = unwind, u.kind == .approve(rowId: row.id), !reduceMotion {
            NWOneShot(start: u.at, duration: HoldRingModel.unwindDuration(from: u.from)) { now in
                NWHoldBorder(progress: HoldRingModel.unwound(from: u.from, since: now.timeIntervalSince(u.at)))
            }
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

// MARK: - The panel

/// The menu-bar panel: aurora header, runway, ranked rows, in-flight strip,
/// receipt line and footer. All state comes from the store, which the harness
/// fills with fixtures. Other moods swap the body: All quiet shows the day's
/// rings and the phone line, Paused for battery shows the paused agents and
/// "Resume now anyway" (with any open approvals and questions below them).
struct NWNowPopover: View {
    @ObservedObject var store: NowStore
    @Environment(\.nwReduceMotion) private var reduceMotion
    /// Each row's frame in the popover (for Final approach and the gap a folded row leaves).
    @State private var rowFrames: [String: CGRect] = [:]

    private var model: NowModel { store.model }
    static let space = "nwPopover"
    /// The pulse's centre in the popover.
    static let pulseCenter = CGPoint(x: NightWatch.Space.popoverWidth - NWAuroraHeader.pulseInset.width,
                                     y: NWAuroraHeader.pulseInset.height)

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.state.showShortcuts {
                NWShortcutsSheet { store.toggleShortcuts() }
            } else {
                switch model.mood {
                case .dusk: duskBody
                default:
                    if store.shownRows.isEmpty && store.queuedNew == 0 { quietBody } else { rowsBody }
                }
            }
            configNotice
            stopStrip
            footer
        }
        .frame(width: NightWatch.Space.popoverWidth)
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(NWRowFramesKey.self) { frames in
            // Keep the last known frame of rows that have gone (a closing gap needs its height).
            var all = rowFrames
            for (k, v) in frames { all[k] = v }
            if all != rowFrames { rowFrames = all }
        }
        .background(NWGlassBackground(radius: NightWatch.Radius.popover,
                                      fill: NightWatch.Palette.popoverBody, glowHeight: 30, rim: false))
        .clipShape(RoundedRectangle(cornerRadius: NightWatch.Radius.popover, style: .continuous))
        // The rim goes above the clip so it runs round the header too.
        .overlay(NWGlassRim(radius: NightWatch.Radius.popover))
    }

    // MARK: header: the pulse, the exhale, dusk and dawn

    private var pulseInputs: NWPulseInputs {
        let now = store.now()
        return NWPulseInputs(
            // The same count as the glyph and the headline: decisions, else looks.
            style: model.mood.pulse, waiting: model.needYouCount > 0 ? model.needYouCount : model.lookCount,
            agents: model.workingCount,
            longestWait: PulseModel.longestWait(rows: model.rows, now: now),
            clearedAt: store.motion.clearedAt, clearedRings: store.motion.clearedRings)
    }

    /// The one-shot that changes the sky, if one is playing: the aurora
    /// settling after the exhale, dusk falling, or dawn rising.
    private var skyMotion: (start: Date, duration: TimeInterval)? {
        let m = store.motion
        if model.mood == .dusk, let at = m.duskAt { return (at, DuskDawnModel.duskDuration) }
        if let d = m.dawn {
            let lastRelight = NowSky.relightTimes(d).values.max() ?? 0
            return (d.startedAt, max(DuskDawnModel.dawnDuration, lastRelight + DuskDawnModel.relightDuration) + NowSky.starFade)
        }
        if let at = m.clearedAt, model.mood != .needsYou { return (at, PulseModel.auroraSettleDuration) }
        return nil
    }

    private var header: some View {
        let motion = skyMotion
        return NWOneShot(start: motion?.start, duration: motion?.duration ?? 0, fps: NWMotionRate.ambient) { now in
            let look = NowSky.look(model: model, motion: store.motion, now: now, reduceMotion: reduceMotion)
            let words = NowSky.lines(model: model, motion: store.motion, now: now, reduceMotion: reduceMotion)
            NWAuroraHeader(palette: look.palette, headline: words.headline, subline: words.subline,
                           pulse: model.mood.pulse, pulseInputs: pulseInputs, sky: look.sky,
                           // "N working" jumps to the cards; the pulse opens Settings (the Tower).
                           onWorkingTap: store.flightRows.isEmpty ? nil : { store.jumpToInFlight() },
                           onPulseTap: { store.command(.preferences) })
        }
    }

    // MARK: needs you / looks stuck

    private var visibleRows: [DecideRow] {
        store.expanded ? store.shownRows : Array(store.shownRows.prefix(NowModel.visibleRows))
    }

    private var overflowRows: Int { max(0, store.shownRows.count - NowModel.visibleRows) }

    private var rowsBody: some View {
        VStack(spacing: 0) {
            NWRunwayBar(model: model.runway)
                .padding(.top, 2)
            tip.padding(.horizontal, 10).padding(.top, 8)
            rowList
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
            if !store.flightRows.isEmpty {
                NWInFlightGroup(store: store, maxCardsHeight: store.flightCardsMaxHeight)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
            statusLine
        }
    }

    /// The list's own one-shot: arrivals flying in and gaps closing.
    private var listMotion: (start: Date, duration: TimeInterval)? {
        let m = store.motion
        let starts = Array(m.arrivals.values) + m.gaps.map(\.at)
        guard let first = starts.min(), let last = starts.max() else { return nil }
        return (first, last.timeIntervalSince(first) + max(ApproachModel.duration, NowMotion.gapDuration) + 0.02)
    }

    @ViewBuilder
    private var rowList: some View {
        let scrolls = store.expanded && store.shownRows.count > 5
        let motion = listMotion
        let content = NWOneShot(start: scrolls ? nil : motion?.start, duration: motion?.duration ?? 0) { now in
            VStack(spacing: 8) {
                if store.queuedNew > 0 {
                    NWNewPill(count: store.queuedNew) { store.showNew() }
                        .frame(maxWidth: .infinity)
                }
                ForEach(Array(visibleRows.enumerated()), id: \.element.id) { index, row in
                    rowCell(row, index: index, now: now, flies: !scrolls)
                }
                if !store.expanded && overflowRows > 0 {
                    Button { store.setExpanded(true) } label: {
                        Text("+\(overflowRows) more")
                            .font(NightWatch.Typo.monoSmall)
                            .foregroundColor(NightWatch.Palette.textTertiary.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay(contrails(now: now, flies: !scrolls))
        }
        .onHover { store.pointerInList = $0 }
        if scrolls {
            ScrollViewReader { proxy in
                // Four and a half rows: the half row, and the scroller, say there is more.
                ScrollView(.vertical, showsIndicators: true) { content.padding(.trailing, 4) }
                    .frame(height: 4.5 * 96)
                    .onChange(of: store.selectedId) { id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                    }
            }
        } else {
            content
        }
    }

    private func rowCell(_ row: DecideRow, index: Int, now: Date, flies: Bool) -> some View {
        let arrival = flies && !reduceMotion ? store.motion.arrivals[row.id] : nil
        let elapsed = arrival.map { now.timeIntervalSince($0) }
        let f = elapsed.map { ApproachModel.frame(elapsed: max(0, $0)) }
        let slot = rowFrames[row.id]
        // Its top edge starts on the pulse; until its slot is known (first frame) it waits unseen.
        let dy: CGFloat = {
            guard let e = elapsed, let slot else { return 0 }
            return CGFloat(ApproachModel.cardOffset(pulseY: Double(Self.pulseCenter.y), slotTop: Double(slot.minY), elapsed: max(0, e)))
        }()
        let pulseX = slot.map { Self.pulseCenter.x - $0.minX } ?? 0
        let hidden = elapsed.map { $0 < 0 || slot == nil } ?? false
        let flying = f.map { !$0.finished } ?? false
        return VStack(spacing: 6) {
            NWDecideRowView(
                row: row, focused: row.id == store.selectedId, sending: store.sending.contains(row.id),
                holdProgress: holdProgress(for: row), thread: store.motion.threads[row.id],
                unwind: store.motion.unwind, burst: store.motion.burst,
                onKey: { store.click($0, on: row) },
                onHoldBegan: { store.mouseHoldBegan(.approve(rowId: row.id)) },
                onHoldEnded: { store.mouseHoldEnded() })
                // In flight it is an empty outline (board 07): its words, and the solid card
                // under them, come only as it lands, so nothing is drawn over the header's or
                // the runway's words on the way down.
                .opacity(flying ? (f?.content ?? 1) : 1)
                .background(Group { if let f, flying, f.content > 0.001 {
                    RoundedRectangle(cornerRadius: NightWatch.Radius.row, style: .continuous)
                        .fill(NightWatch.Palette.popoverBody.opacity(f.content).color)
                } })
                .overlay(Group { if let f, flying || f.glow > 0.001 { arrivalOutline(f, pulseX: pulseX) } })
                .onTapGesture { store.select(row.id) }
                .id(row.id)
            if let c = store.composer, c.rowId == row.id {
                NWComposer(store: store, row: row)
            }
        }
        .opacity(hidden ? 0 : (f?.opacity ?? 1))
        .offset(y: dy + (flies && !reduceMotion ? shift(forIndex: index, now: now) : 0))
        .zIndex(arrival != nil ? 1 : 0)
        // Measured outside the offset, so it is the slot, not where the card is drawn.
        .background(GeometryReader { g in
            Color.clear.preference(key: NWRowFramesKey.self, value: [row.id: g.frame(in: .named(Self.space))])
        })
    }

    /// The arriving card's outline: it widens out from under the pulse to the
    /// card's full width before any of the card's words show.
    private func arrivalOutline(_ f: ApproachModel.Frame, pulseX: CGFloat) -> some View {
        GeometryReader { g in
            let w = g.size.width * CGFloat(0.3 + 0.7 * f.reveal)
            let cx = min(g.size.width - w / 2 + 4, pulseX + (g.size.width / 2 - pulseX) * CGFloat(f.reveal))
            NWArrivalGlow(glow: f.glow, edge: f.edge)
                .frame(width: w, height: g.size.height)
                .position(x: cx, y: g.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    /// Where a row is drawn relative to its place: rows below an arrival start
    /// one card height up and ease down; rows below a closed gap start one
    /// card height down and glide up. Nothing above either moves.
    private func shift(forIndex index: Int, now: Date) -> CGFloat {
        var dy: CGFloat = 0
        let rows = store.shownRows
        for (j, r) in rows.enumerated() where j < index {
            guard let at = store.motion.arrivals[r.id] else { continue }
            let h = (rowFrames[r.id]?.height ?? 53) + 8
            dy += CGFloat(ApproachModel.belowOffset(cardHeight: Double(h), elapsed: max(0, now.timeIntervalSince(at))))
        }
        for g in store.motion.gaps where index >= g.index {
            let h = (rowFrames[g.rowId]?.height ?? 53) + 8
            let u = MotionCurve.easeOut(now.timeIntervalSince(g.at) / NowMotion.gapDuration)
            dy += h * CGFloat(1 - u)
        }
        return dy
    }

    /// The contrail from the pulse to each arriving card's top edge, drawn in
    /// the list's space (it reaches up over the header).
    private func contrails(now: Date, flies: Bool) -> some View {
        GeometryReader { g in
            let origin = g.frame(in: .named(Self.space)).origin
            ForEach(Array(store.motion.arrivals.keys.sorted()), id: \.self) { id in
                if flies, !reduceMotion, let at = store.motion.arrivals[id], let slot = rowFrames[id] {
                    let e = now.timeIntervalSince(at)
                    let f = ApproachModel.frame(elapsed: max(0, e))
                    if e >= 0, f.contrail > 0.001 {
                        let top = slot.minY + CGFloat(ApproachModel.cardOffset(pulseY: Double(Self.pulseCenter.y), slotTop: Double(slot.minY), elapsed: e))
                        NWContrail(from: CGPoint(x: Self.pulseCenter.x - origin.x, y: Self.pulseCenter.y - origin.y + 7),
                                   to: CGPoint(x: Self.pulseCenter.x - origin.x, y: top - origin.y),
                                   strength: f.contrail)
                    }
                }
            }
        }
        .allowsHitTesting(false)
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

    /// The first-run tip: shown once, the first time there is a row to act on.
    @ViewBuilder
    private var tip: some View {
        if store.tipVisible { NWTipStrip(text: PanelTip.text) { store.dismissTip() } }
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
            tip
            if !store.flightRows.isEmpty { NWInFlightGroup(store: store, maxCardsHeight: store.flightCardsMaxHeight) }
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
            stopStrip(progress: store.holdProgress, holding: true)
        } else if let u = store.motion.unwind, u.kind == .stopAll, !reduceMotion {
            // Let go early: the ring unwinds backwards, and nothing is sent.
            NWOneShot(start: u.at, duration: HoldRingModel.unwindDuration(from: u.from)) { now in
                stopStrip(progress: HoldRingModel.unwound(from: u.from, since: now.timeIntervalSince(u.at)), holding: false)
            }
        }
    }

    private func stopStrip(progress: Double, holding: Bool) -> some View {
        HStack(spacing: 12) {
            NWHoldRing(progress: progress, size: 28, lineWidth: 3.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(holding ? "Keep holding to stop" : "Let go · nothing sent")
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
            Button { store.toggleShortcuts() } label: {
                Image(systemName: store.state.showShortcuts ? "questionmark.circle.fill" : "questionmark.circle")
                    .font(Font.system(size: 12, weight: .medium))
                    .foregroundColor(store.state.showShortcuts ? NightWatch.Palette.teal.color : NightWatch.Palette.textTertiary.color)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Every keyboard shortcut (\(PanelKeys.help))")
            .accessibilityLabel(Text("Keyboard shortcuts"))
            Button { store.command(.preferences) } label: {
                Image(systemName: "gearshape").font(Font.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Settings…")
            .accessibilityLabel(Text("Settings"))
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
    /// When it dropped in: the sunrise (signature motion 5) plays from here,
    /// scaled to how much of the absence finished well.
    var shownAt: Date? = nil

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
            .background(NWSunrise(scale: model.sunrise, shownAt: shownAt)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
        }
        .frame(width: 380)
    }
}
