import SwiftUI

/// Everything the Now screen draws, as values. The live container builds it
/// from the stores; the render harness builds it from fixtures.
struct NowScreenData {
    var model: NowModel
    var log: SettledLog
    var chip: MacChipModel
    var banners: [NowBanner] = []
    var brief: ReturnBrief? = nil
    var briefExpanded = false
    /// The working sessions, one row each.
    var inFlight: InFlightSection = .empty
    /// The one first-time tip showing, and the row it points at.
    var tip: NowTipTarget? = nil
    /// How this phone confirms ("Face ID"), for the hold tip.
    var biometry = "Face ID"
    var now: Date
    /// New arrivals held behind the "New ↑" pill.
    var queuedNew = 0
    /// Actions in flight, and what each card should say about them.
    var pending: [String: PendingAction] = [:]
    var outcomes: [String: CardOutcome] = [:]
    /// Draws the Irreversible hold button part-way (the render harness).
    var fixedHold: Double? = nil
    var fixedDrag: CGFloat? = nil
    /// The Horizon sentence when you were away 10 minutes or more.
    var handover: String? = nil
    /// Something Page can see is wrong: the Horizon says so and the fix is the first card.
    var problem: ProblemState? = nil
    /// Scrolls this row to the middle on appear (the render harness, to frame a card below the fold).
    var scrollTo: String? = nil
    /// Scrolls this element (a section) to the top on appear: the state after "2 working" is tapped.
    var scrollToId: String? = nil
    /// Each action's delivery state, drawn as its Receipt thread.
    var receipts: [String: ReceiptThreadInput] = [:]
    /// Where a Delete of the receipt's queued reply stands (deleting, too late, couldn't confirm).
    var retractNote: RetractNote? = nil
    /// Rows that have left with their reply confirmed, kept while the thread
    /// resolves and the card folds into Settled (`DepartingRows`).
    var ghosts: Set<String> = []
    /// The render harness: this row is the one arriving (`-NWTime` is how far in).
    var pinnedArrival: String? = nil
    /// The inbox has loaded at least once: what is there then is the first
    /// look, not a flood of arrivals.
    var inboxLoaded = true
    /// Question rows whose questions the Mac sent: opened, they offer tap-to-tick answers.
    var answerable: Set<String> = []
}

/// What the Now screen can ask for. Every one is routed by the container
/// through the existing services; the screen sends nothing itself.
struct NowScreenActions {
    var open: (String) -> Void = { _ in }
    var approve: (NowRow) -> Void = { _ in }
    var holdComplete: (NowRow) -> Void = { _ in }
    var deny: (NowRow) -> Void = { _ in }
    var looksGood: (NowRow) -> Void = { _ in }
    var steer: (NowRow) -> Void = { _ in }
    var cancel: (String) -> Void = { _ in }
    var tapChip: () -> Void = {}
    var tapRunway: () -> Void = {}
    /// Opens a working session's room: on Story, Screen, the composer, or where Stop is held.
    var openRoom: (String, RoomEntry) -> Void = { _, _ in }
    var toggleInFlight: () -> Void = {}
    var dismissTip: (NWTip) -> Void = { _ in }
    var toLanes: () -> Void = {}
    /// The orb in the corner: the Tower (Settings).
    var openSettings: () -> Void = {}
    var toggleBrief: () -> Void = {}
    var dismissBrief: () -> Void = {}
    var reviewFinished: () -> Void = {}
    var seeAll: () -> Void = {}
    /// Delete the reply the latest receipt says is waiting (at the relay, or held on the Mac).
    var deleteQueued: (ReceiptRetract) -> Void = { _ in }
    var banner: (NowBanner.Action) -> Void = { _ in }
    var problem: (ProblemState.Action) -> Void = { _ in }
    var showNew: () -> Void = {}
    var refresh: () async -> Void = {}
    var touching: (Bool) -> Void = { _ in }
}

/// NOW: the ranked stream. Horizon, Runway, what needs you (amber first), the
/// Return Brief, in flight, then Settled. If anything is blocked on you, the
/// first card under the Runway is that card: nothing sits in front of it.
struct NWNowScreen: View {
    var data: NowScreenData
    var actions = NowScreenActions()
    @Environment(\.nwTopInset) private var topInsetOverride
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// "Review the finished" asks the stream to scroll to that section.
    @State private var scrollRequest: String?
    /// A finger is down on the stream. A `GestureState` resets itself when the
    /// scroll view takes the touch over, so the order freeze can never stick.
    @GestureState private var pressing = false
    /// The rows already seen. Anything new descends from the pulse (Final
    /// approach); nil until the first look, which plays nothing.
    @State private var seen: Set<String>?
    /// The arriving card's height, for the harness's frame of the cards below.
    @State private var arrivalHeight: CGFloat = 0
    @Environment(\.nwMotion) private var motionPin
    /// The time of day the Horizon's sky is drawn at.
    @Environment(\.nwDaypart) private var daypart
    /// What the rest of Now has seen since it appeared (`NowMotion.NowScene`):
    /// the Runway, the Horizon's words, Settled's arrivals, the chips.
    @State private var nowScene = NowMotion.NowScene()
    @Environment(\.nwNowScript) private var nowScript
    @Environment(\.nwFixedPhase) private var fixedPhase
    @Environment(\.nwReduceMotion) private var forcedReduceMotion

    var body: some View {
        GeometryReader { geo in
            let inset = topInsetOverride ?? geo.safeAreaInsets.top
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    horizon(inset: inset)
                    VStack(spacing: 16) { stream(inset: inset) }
                        .padding(.horizontal, NightWatch.Space.gutter)
                        // Cards below a new arrival make room on its spring; nothing above moves.
                        .animation(reduceMotion ? nil : .spring(response: ApproachModel.response, dampingFraction: ApproachModel.damping),
                                   value: NWStreamSpring(rows: rowIds, horizon: horizonHeight))
                        // The New pill comes and goes (the cards below make room); a row change keeps the spring above.
                        .animation(queuedAnimation, value: data.queuedNew > 0)
                    Spacer().frame(height: 120)
                }
                .coordinateSpace(name: nwStreamSpace)
            }
            .onAppear { if seen == nil, data.inboxLoaded { seen = Set(rowIds) } }
            .onChange(of: data.inboxLoaded) { _, loaded in if loaded, seen == nil { seen = Set(rowIds) } }
            .onChange(of: rowIds) { _, ids in if seen != nil { seen = Set(ids) } }
            .onAppear { if motionLive { nowScene = motion.scene } }
            .onChange(of: data.look) { _, look in
                guard motionLive else { return }
                nowScene.observe(look, at: Date().timeIntervalSinceReferenceDate, shown: { NWNowBook.shown($0, at: $1) })
            }
            .onAppear {
                guard let id = data.scrollToId else { return }
                DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
            }
            .onAppear {
                guard let id = data.scrollTo else { return }
                // After the first layout, so the row exists to be found.
                DispatchQueue.main.async { proxy.scrollTo("row-\(id)", anchor: .center) }
            }
            .onChange(of: scrollRequest) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .top) }
                scrollRequest = nil
            }
            .refreshable { await actions.refresh() }
            .ignoresSafeArea(edges: .top)
            .simultaneousGesture(DragGesture(minimumDistance: 0).updating($pressing) { _, state, _ in state = true })
            .onChange(of: pressing) { _, now in actions.touching(now) }
            }
        }
    }

    private func reviewFinished() {
        actions.reviewFinished()
        scrollRequest = "section-review"
    }

    private var quiet: Bool { data.model.rows.isEmpty }

    /// On the display clock (not the harness).
    private var motionLive: Bool { motionPin?.kind != .now && fixedPhase == nil }

    /// The rest of Now at its moment. Pinned (the harness): the script
    /// replayed up to then, as the live screen would have seen it; the
    /// harness's still screens draw it long settled. Live: the scene with
    /// this look already in it, so the frame that first shows a change draws it.
    private var motion: NWNowMotion {
        let rm = reduceMotion || forcedReduceMotion
        if let p = motionPin.flatMap({ $0.kind == .now ? $0.time : nil }), let script = nowScript, let r = NowMotion.replay(script, until: p) {
            return NWNowMotion(scene: r.scene, pinned: script.base + p, reduceMotion: rm)
        }
        if let still = fixedPhase {
            return NWNowMotion(scene: NowMotion.NowScene(opening: data.look, at: 0, shown: { _, _ in -100 }), pinned: still, reduceMotion: rm)
        }
        var s = nowScene
        s.observe(data.look, at: Date().timeIntervalSinceReferenceDate, shown: { NWNowBook.shown($0, at: $1) })
        return NWNowMotion(scene: s, reduceMotion: rm)
    }

    /// The NOW dot breathes on the pulse's 4 s while agents work: still when nothing runs, at dusk, or with a problem showing.
    private var runwayBreath: Double? {
        let m = data.model
        guard data.problem == nil, !m.paused, m.workingCount > 0 else { return nil }
        return PulseModel.baseBreath
    }
    private var rowIds: [String] { data.model.rows.map(\.id) }

    /// The pulse behind the Horizon: what works, what waits and for how long.
    /// It counts what the headline names (the decisions, else the looks), as
    /// the capsule and the Mac do.
    private var pulseModel: PulseModel {
        let m = data.model
        let waiting = m.pulseRows.filter { !data.ghosts.contains($0.id) }
        return PulseModel(working: m.workingCount, waiting: m.pulseWaiting,
                          longestWait: PulseModel.pacedWait(PulseModel.longestWait(since: waiting.map(\.waitingSince), now: data.now)),
                          paused: m.paused)
    }

    /// The Horizon's height, and where its pulse sits in the stream's space.
    private var horizonHeight: CGFloat { quiet && data.problem == nil ? 470 : 244 }
    private func pulseY(inset: CGFloat) -> CGFloat { inset + 38 + min(150, max(96, horizonHeight - 112)) / 2 }
    /// The Horizon's headline and subline, between the orb and its foot: an
    /// arriving card's outline passes behind them, never across them.
    private func wordsBand(inset: CGFloat) -> ClosedRange<CGFloat> {
        (inset + 38 + min(150, max(96, horizonHeight - 112)) + 2)...(inset + horizonHeight - 2)
    }

    // MARK: Horizon

    private func horizon(inset: CGFloat) -> some View {
        let m = data.model
        let p = data.problem
        // A problem is never "All quiet": the Horizon goes hollow and says what is wrong.
        // Board 01: the Horizon is a quarter to a third of the screen when something
        // needs you, so the first Decide card is in view; all quiet gets the sky to itself.
        let height = horizonHeight
        return ZStack(alignment: .top) {
            NWHorizon(palette: p.map { $0.tone == .slate ? .asleep : .problem } ?? NightWatch.AuroraPalette(m.mood, daypart: daypart),
                      pulse: p.map { $0.tone == .slate ? .hollowSlate : .hollowAmber } ?? NWPulseOrb.Style(m.mood),
                      headline: data.horizonHeadline, subline: data.horizonSubline,
                      footnote: p == nil && quiet && m.headline == "All quiet" ? "Page is keeping watch. Go to sleep." : nil,
                      height: height, topInset: inset, model: pulseModel,
                      workingJump: workingJump(problem: p).map { j in (j.jump, j.rest, { scrollRequest = HeaderJump.sectionId }) },
                      motion: motion)
            NWChromeGlassGroup {
                HStack(alignment: .top) {
                    NWMacChip(model: data.chip, onTap: actions.tapChip)
                    Spacer()
                    settingsOrb(rings: m.rings)
                }
            }
            .padding(.horizontal, NightWatch.Space.gutter)
            .padding(.top, inset + 6)
        }
        .frame(height: height + inset)
        // Swipe the Horizon to go to Lanes.
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            if NWDestination.afterDrag(from: .now, translation: Double(v.translation.width), vertical: Double(v.translation.height)) == .lanes { actions.toLanes() }
        })
    }

    /// "2 working" scrolls to the In flight cards, while the subline is that sentence.
    private func workingJump(problem: ProblemState?) -> (jump: String, rest: String)? {
        guard problem == nil, data.handover == nil,
              HeaderJump.target(working: data.model.workingCount, inFlightShown: data.inFlight.rows.count) != nil else { return nil }
        return HeaderJump.split(subline: data.model.subline, working: data.model.workingCount)
    }

    /// The round glyph in the corner is the way to Settings (the Tower): the
    /// day's rings when there are some, a plain ring when there are none.
    private func settingsOrb(rings: [RingStat]) -> some View {
        Button(action: actions.openSettings) {
            ZStack {
                if rings.isEmpty {
                    Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 4).frame(width: 40, height: 40)
                } else {
                    NWConcentricRings(rings: rings, size: 46)
                }
            }
            .frame(width: 56, height: 56)
            // The rings sit on a glass disc; before glass they float bare.
            .nwChromeGlass(in: Circle()) { Color.clear }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, -2)
        .accessibilityLabel(Text("Settings"))
        .accessibilityValue(Text(rings.map { "\($0.kind.rawValue) \($0.detail)" }.joined(separator: ", ")))
        .accessibilityHint(Text("Opens the Tower"))
    }

    // MARK: Stream

    @ViewBuilder private func stream(inset: CGFloat) -> some View {
        if let p = data.problem { NWProblemCard(problem: p, onAction: actions.problem) }
        ForEach(data.banners.filter { b in !(data.problem?.replacesBanners.contains(b.id) ?? false) }) { b in NWBannerCard(banner: b, onAction: actions.banner) }
        // With the Mac out of reach the Runway would be a stale promise, so it steps aside.
        if data.problem?.kind != .macAsleep {
            NWGlassCard(radius: 24, padding: 6) { NWNowRunway(model: data.model.runway, motion: motion, breathPeriod: runwayBreath) }
                .contentShape(Rectangle())
                .onTapGesture(perform: actions.tapRunway)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Opens the Tower at Budget"))
        }
        if let b = data.brief, !b.hasUrgent {
            // Nothing in Decide or Look: the Brief opens straight under the Runway.
            NWBriefCard(brief: b, expanded: data.briefExpanded || quiet, onToggle: actions.toggleBrief,
                        onDismiss: actions.dismissBrief, onReview: reviewFinished)
        }
        if data.queuedNew > 0 {
            NWNewPill(count: data.queuedNew, onTap: actions.showNew).frame(maxWidth: .infinity)
                .transition(queuedTransition)
        }
        ForEach(sections, id: \.0) { section, rows in
            // In flight sits between what needs you and what has finished.
            if section == .review { inFlight }
            NWSectionHeader(title: section.title, count: rows.filter { !data.ghosts.contains($0.id) }.count, color: section.color)
                .id("section-\(section.title.lowercased())")
                .offset(y: push(below: rows.first.flatMap { order.firstIndex(of: $0.id) }.map { $0 - 1 }))
            ForEach(rows) { row in
                arriving(row, inset: inset)
                    .id("row-\(row.id)")
                    .offset(y: push(below: order.firstIndex(of: row.id).map { $0 - 1 }))
                    // The approach draws an arrival itself; a departure has already folded or simply fades.
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .identity, removal: .opacity))
                if let tip = data.tip, tip.anchorId == row.id { tipCallout(tip, under: row).offset(y: push(below: order.firstIndex(of: row.id))) }
            }
            // The Brief sits after Decide and Look when something needs you.
            if section == .look || (section == .decide && !sections.contains { $0.0 == .look }), let b = data.brief, b.hasUrgent {
                NWBriefCard(brief: b, expanded: data.briefExpanded, onToggle: actions.toggleBrief,
                            onDismiss: actions.dismissBrief, onReview: reviewFinished)
                    .offset(y: push(below: rows.last.flatMap { order.firstIndex(of: $0.id) }))
            }
        }
        if !sections.contains(where: { $0.0 == .review }) { inFlight }
        if let b = data.brief, b.hasUrgent, !sections.contains(where: { $0.0 == .decide || $0.0 == .look }) {
            NWBriefCard(brief: b, expanded: data.briefExpanded, onToggle: actions.toggleBrief,
                        onDismiss: actions.dismissBrief, onReview: reviewFinished)
        }
        Group {
            if let line = data.model.receiptLine {
                // The reply that is queued (at the relay, or held on the Mac) and its Delete: it rises in,
                // a new word (held, sending, delivered) cross-fades, and going it fades as Settled closes up.
                VStack(spacing: 16) {
                    NWReceiptLine(text: line, failed: data.model.receiptFailed)
                        .contentTransition(.opacity)
                        .animation(queuedAnimation, value: line)
                    // A reply still waiting at the relay or on the Mac: Delete takes it back.
                    if let r = data.model.receiptRetract { receiptDelete(r).transition(.opacity) }
                }
                .transition(queuedTransition)
            }
            if quiet && data.problem == nil { NWTonightCard(rings: data.model.rings) }
            NWSettledList(log: data.log, onSeeAll: actions.seeAll, motion: motion, now: data.now).padding(.top, 6)
                .id("section-settled")
        }
        .animation(queuedAnimation, value: QueuedKey(line: data.model.receiptLine != nil, delete: data.model.receiptRetract != nil))
        .offset(y: push(below: order.count - 1))
    }

    /// How what is queued comes and goes: rising 6 pt as it fades in, fading as what is below closes up.
    private var queuedTransition: AnyTransition {
        reduceMotion || forcedReduceMotion ? .opacity
            : .asymmetric(insertion: .offset(y: NowMotion.queuedRise).combined(with: .opacity), removal: .opacity)
    }

    private var queuedAnimation: Animation {
        .easeOut(duration: reduceMotion || forcedReduceMotion ? WorkflowMotion.reducedFade : NowMotion.queuedFade)
    }

    /// Delete under the receipt of a reply that is still waiting somewhere it can be taken back from.
    @ViewBuilder private func receiptDelete(_ r: ReceiptRetract) -> some View {
        HStack(spacing: 12) {
            if let n = data.retractNote {
                Text(n.text).font(NightWatch.Typo.caption)
                    .foregroundColor((n.isFinal ? NightWatch.Palette.textSecondary : NightWatch.Palette.amber).color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if data.retractNote?.isBusy == true {
                ProgressView().controlSize(.small).tint(NightWatch.Palette.textSecondary.color).frame(width: 44, height: 44)
            } else {
                Button { actions.deleteQueued(r) } label: {
                    Text("Delete").font(NightWatch.Typo.captionStrong).foregroundColor(NightWatch.Palette.red.color)
                        .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(r.layer == .relay ? "Takes the reply back from the relay so it is never typed."
                                        : "Takes the reply back from your Mac so it is never typed."))
            }
        }
        .padding(.horizontal, 14)
    }

    /// The In flight rows, between Decide/Look and Review (or after them when nothing has finished).
    @ViewBuilder private var inFlight: some View {
        if !data.inFlight.rows.isEmpty {
            let before = sections.first { $0.0 == .review }?.1.first.flatMap { order.firstIndex(of: $0.id) }.map { $0 - 1 } ?? (order.count - 1)
            NWInFlightSection(section: data.inFlight, tip: data.tip.flatMap { $0.tip == .inFlight ? $0 : nil }, biometry: data.biometry,
                              onOpen: actions.openRoom, onToggle: actions.toggleInFlight, onHeader: actions.toLanes, onDismissTip: actions.dismissTip)
                .id("section-in flight")
                .offset(y: push(below: before))
        }
    }

    /// A first-time tip under the row it explains. Under a card that is
    /// arriving it waits for the card to land (`NWArrivalTail`), and that
    /// fade is its entrance.
    private func tipCallout(_ tip: NowTipTarget, under row: NowRow) -> some View {
        let arriving = arrivalPlan[row.id] != nil && !data.ghosts.contains(row.id)
        return NWArrivalTail(arriving: arriving, delay: arrivalPlan[row.id] ?? 0, pinned: approachPin(row)) {
            NWTipCallout(text: tip.tip.text(biometry: data.biometry), symbol: tip.tip.symbol, onDismiss: { actions.dismissTip(tip.tip) })
        }
        .padding(.top, -6)
        .transition(arriving && !reduceMotion ? .asymmetric(insertion: .identity, removal: .opacity) : .opacity)
    }

    // MARK: Final approach

    /// The rows in the order drawn.
    private var order: [String] { sections.flatMap { $0.1.map(\.id) } }

    /// The render harness draws the cards below a pinned arrival making room
    /// (live, the stream's own spring does it). `index` is the last row above
    /// the element; it moves when the arrival is at or above that row.
    private func push(below index: Int?) -> CGFloat {
        guard let id = data.pinnedArrival, let t = motionPin.flatMap({ $0.kind == .approach ? $0.time : nil }),
              let a = order.firstIndex(of: id), let i = index, i >= a else { return 0 }
        return CGFloat(ApproachModel.pushOffset(height: Double(arrivalHeight) + 16, elapsed: t))
    }

    /// When each new row leaves the pulse: a few arrivals come down one after
    /// another; a flood just appears.
    private var arrivalPlan: [String: TimeInterval] {
        ApproachModel.schedule(ApproachModel.arrivals(previous: seen.map { Array($0) }, current: order), start: 0)
    }

    /// The render harness's moment in the approach, for the row it pins.
    private func approachPin(_ row: NowRow) -> Double? {
        data.pinnedArrival == row.id ? motionPin.flatMap { $0.kind == .approach ? $0.time : nil } : nil
    }

    /// A card, arriving from the pulse if it is new, or folding away if it
    /// has just been confirmed and has left.
    @ViewBuilder private func arriving(_ row: NowRow, inset: CGFloat) -> some View {
        let pinned = approachPin(row)
        let plan = arrivalPlan
        if data.ghosts.contains(row.id) {
            card(row).modifier(NWResolveFold(changedAt: data.receipts[row.id]?.changedAt))
        } else {
            NWArrival(arriving: plan[row.id] != nil, delay: plan[row.id] ?? 0, pulseY: pulseY(inset: inset), tint: row.section.color,
                      radius: row.canSwipeApprove ? NightWatch.Radius.row : NightWatch.Radius.card,
                      clear: wordsBand(inset: inset), pinned: pinned) {
                card(row)
                    .background(GeometryReader { g in
                        Color.clear.onAppear { if pinned != nil { arrivalHeight = g.size.height } }
                    })
            }
        }
    }

    private var sections: [(NowRow.Section, [NowRow])] {
        [NowRow.Section.decide, .look, .review].compactMap { s in
            let rows = data.model.rows.filter { $0.section == s }
            return rows.isEmpty ? nil : (s, rows)
        }
    }

    @ViewBuilder private func card(_ row: NowRow) -> some View {
        let outcome = data.outcomes[row.id] ?? .none
        let pending = data.pending[row.id]
        switch row.section {
        case .decide where row.canSwipeApprove:
            NWUndoableRow(row: row, now: data.now, outcome: outcome, pending: pending, receipt: data.receipts[row.id], fixedDrag: data.fixedDrag,
                          onApprove: { actions.approve(row) }, onOpen: { actions.open(row.id) }, onCancel: { actions.cancel(row.id) })
        case .decide where row.chip == .question:
            NWQuestionCard(row: row, now: data.now, answerable: data.answerable.contains(row.id), onOpen: { actions.open(row.id) })
        case .decide:
            NWDecideCard(row: row, now: data.now, outcome: outcome, pending: pending, receipt: data.receipts[row.id], fixedHold: data.fixedHold,
                         onApprove: { actions.approve(row) }, onHoldComplete: { actions.holdComplete(row) },
                         onDeny: { actions.deny(row) }, onOpen: { actions.open(row.id) }, onCancel: { actions.cancel(row.id) })
        case .look:
            NWLookCard(row: row, now: data.now, outcome: outcome, pending: pending, receipt: data.receipts[row.id],
                       onSteer: { actions.steer(row) }, onOpen: { actions.open(row.id) }, onCancel: { actions.cancel(row.id) })
        case .review:
            NWReviewCard(row: row, now: data.now, outcome: outcome, pending: pending, receipt: data.receipts[row.id],
                         chipsShownAt: motion.scene.chipsShown[row.id], motion: motion,
                         onLooksGood: { actions.looksGood(row) }, onSteer: { actions.steer(row) },
                         onOpen: { actions.open(row.id) }, onCancel: { actions.cancel(row.id) })
        }
    }
}

/// What the stream springs on: its rows. A change that comes with the
/// Horizon giving up its room (the first item arriving) or taking it back
/// (the last one going) counts as no change, so the stream jumps with the
/// Horizon in that one frame and the only thing moving is the arrival, not
/// the Runway gliding 226 pt up through it.
private struct NWStreamSpring: Equatable {
    var rows: [String]
    var horizon: CGFloat

    static func == (a: Self, b: Self) -> Bool { a.horizon != b.horizon || a.rows == b.rows }
}

/// What is queued at the foot of the stream: the reply's line, and its Delete.
private struct QueuedKey: Equatable {
    var line: Bool
    var delete: Bool
}

/// When each first-appearance one-shot of the rest of Now began this app
/// process (reference-date seconds): the Runway drawing in, each Review
/// row's chips counting up. Now is rebuilt on every return from Lanes and
/// every Mac switch; these play once.
@MainActor enum NWNowBook {
    private static var book = OneShotBook()

    static func shown(_ key: String, at t: Double) -> Double { book.start(key, now: t) }
}

/// The rest of Now's scene and the moment to draw: live on the display
/// clock, or the harness's pinned moment (absolute seconds).
struct NWNowMotion {
    var scene = NowMotion.NowScene()
    var pinned: Double? = nil
    var reduceMotion = false
}

/// The Runway on Now, on one clock: its line drawing in and its markers
/// popping the first time it shows this app process, a marker gliding to
/// a new place or flashing as it reaches now, and the NOW dot breathing
/// with the pulse while agents work. With nothing breathing the clock
/// stops once the last one-shot is over; scrolled away or covered it holds.
struct NWNowRunway: View {
    var model: RunwayModel
    var motion = NWNowMotion()
    var breathPeriod: Double? = nil
    @State private var visible = true

    var body: some View {
        let s = motion.scene.runway, rm = motion.reduceMotion
        let settles = s.settlesAt(reduceMotion: rm)
        let now = motion.pinned ?? Date().timeIntervalSinceReferenceDate
        NWWorkflowClock(origin: 0, until: breathPeriod != nil && !rm ? .infinity : settles, pinned: motion.pinned,
                        fps: now < settles ? 30 : 20, holding: !visible) { t in
            NWRunwayBar(model: model, frame: NowMotion.runway(s, model, at: t, breathPeriod: breathPeriod, reduceMotion: rm))
                // Its motion is its own: a row arriving in the same update (the stream's spring) never animates it too.
                .transaction { $0.animation = nil }
        }
        .modifier(NWOnScreen(visible: $visible))
    }
}

extension NowScreenData {
    /// The Horizon's two lines as Now draws them: a problem's words, else the handover, else the model's.
    var horizonHeadline: String { problem?.title ?? handover ?? model.headline }
    var horizonSubline: String { problem?.subtitle ?? (handover == nil ? model.subline : model.headline) }

    /// What the rest of Now's motion looks at (`NowMotion.NowLook`).
    var look: NowMotion.NowLook {
        NowMotion.NowLook(headline: horizonHeadline, subline: horizonSubline, runway: model.runway, settled: log.today,
                          reviews: model.rows.filter { $0.section == .review }.map(\.id), badges: [model.needYouCount, model.workingCount])
    }
}
