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
    var strands: [InFlightStrand] = []
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
    /// Each action's delivery state, drawn as its Receipt thread.
    var receipts: [String: ReceiptThreadInput] = [:]
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
    var tapStrand: (String) -> Void = { _ in }
    var toSky: () -> Void = {}
    var toggleBrief: () -> Void = {}
    var dismissBrief: () -> Void = {}
    var reviewFinished: () -> Void = {}
    var seeAll: () -> Void = {}
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
                                   value: rowIds)
                    Spacer().frame(height: 120)
                }
                .coordinateSpace(name: nwStreamSpace)
            }
            .onAppear { if seen == nil, data.inboxLoaded { seen = Set(rowIds) } }
            .onChange(of: data.inboxLoaded) { _, loaded in if loaded, seen == nil { seen = Set(rowIds) } }
            .onChange(of: rowIds) { _, ids in if seen != nil { seen = Set(ids) } }
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
    private var rowIds: [String] { data.model.rows.map(\.id) }

    /// The pulse behind the Horizon: what works, what waits and for how long.
    /// It counts what the headline names (the decisions, else the looks), as
    /// the capsule and the Mac do.
    private var pulseModel: PulseModel {
        let m = data.model
        let waiting = m.pulseRows.filter { !data.ghosts.contains($0.id) }
        return PulseModel(working: m.workingCount, waiting: m.pulseWaiting,
                          longestWait: PulseModel.longestWait(since: waiting.map(\.waitingSince), now: data.now), paused: m.paused)
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
            NWHorizon(palette: p.map { $0.tone == .slate ? .asleep : .problem } ?? NightWatch.AuroraPalette(m.mood),
                      pulse: p.map { $0.tone == .slate ? .hollowSlate : .hollowAmber } ?? NWPulseOrb.Style(m.mood),
                      headline: p?.title ?? data.handover ?? m.headline,
                      subline: p?.subtitle ?? (data.handover == nil ? m.subline : m.headline),
                      footnote: p == nil && quiet && m.headline == "All quiet" ? "Page is keeping watch. Go to sleep." : nil,
                      height: height, topInset: inset, model: pulseModel)
            HStack(alignment: .top) {
                NWMacChip(model: data.chip, onTap: actions.tapChip)
                Spacer()
                NWConcentricRings(rings: m.rings, size: 46)
                    .padding(.top, 4)
                    .accessibilityHidden(m.rings.isEmpty)
            }
            .padding(.horizontal, NightWatch.Space.gutter)
            .padding(.top, inset + 6)
        }
        .frame(height: height + inset)
        // Swipe the Horizon to go to Sky.
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            if NWDestination.afterDrag(from: .now, translation: Double(v.translation.width), vertical: Double(v.translation.height)) == .sky { actions.toSky() }
        })
    }

    // MARK: Stream

    @ViewBuilder private func stream(inset: CGFloat) -> some View {
        if let p = data.problem { NWProblemCard(problem: p, onAction: actions.problem) }
        ForEach(data.banners.filter { b in !(data.problem?.replacesBanners.contains(b.id) ?? false) }) { b in NWBannerCard(banner: b, onAction: actions.banner) }
        // With the Mac out of reach the Runway would be a stale promise, so it steps aside.
        if data.problem?.kind != .macAsleep {
            NWGlassCard(radius: 24, padding: 6) { NWRunwayBar(model: data.model.runway) }
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
        if data.queuedNew > 0 { NWNewPill(count: data.queuedNew, onTap: actions.showNew).frame(maxWidth: .infinity) }
        ForEach(sections, id: \.0) { section, rows in
            NWSectionHeader(title: section.title, count: rows.filter { !data.ghosts.contains($0.id) }.count, color: section.color)
                .id("section-\(section.title.lowercased())")
                .offset(y: push(below: rows.first.flatMap { order.firstIndex(of: $0.id) }.map { $0 - 1 }))
            ForEach(rows) { row in
                arriving(row, inset: inset)
                    .id("row-\(row.id)")
                    .offset(y: push(below: order.firstIndex(of: row.id).map { $0 - 1 }))
                    // The approach draws an arrival itself; a departure has already folded or simply fades.
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .identity, removal: .opacity))
            }
            // The Brief sits after Decide and Look when something needs you.
            if section == .look || (section == .decide && !sections.contains { $0.0 == .look }), let b = data.brief, b.hasUrgent {
                NWBriefCard(brief: b, expanded: data.briefExpanded, onToggle: actions.toggleBrief,
                            onDismiss: actions.dismissBrief, onReview: reviewFinished)
                    .offset(y: push(below: rows.last.flatMap { order.firstIndex(of: $0.id) }))
            }
        }
        if let b = data.brief, b.hasUrgent, !sections.contains(where: { $0.0 == .decide || $0.0 == .look }) {
            NWBriefCard(brief: b, expanded: data.briefExpanded, onToggle: actions.toggleBrief,
                        onDismiss: actions.dismissBrief, onReview: reviewFinished)
        }
        Group {
            if let line = data.model.receiptLine { NWReceiptLine(text: line, failed: data.model.receiptFailed) }
            if quiet && data.problem == nil { NWTonightCard(rings: data.model.rings) }
            if !data.strands.isEmpty {
                NWInFlightRibbon(strands: data.strands, onStrand: actions.tapStrand, onHeader: actions.toSky)
            }
            NWSettledList(log: data.log, onSeeAll: actions.seeAll).padding(.top, 6)
        }
        .offset(y: push(below: order.count - 1))
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

    /// A card, arriving from the pulse if it is new, or folding away if it
    /// has just been confirmed and has left.
    @ViewBuilder private func arriving(_ row: NowRow, inset: CGFloat) -> some View {
        let pinned = data.pinnedArrival == row.id ? motionPin.flatMap { $0.kind == .approach ? $0.time : nil } : nil
        // A few arrivals come down one after another; a flood just appears.
        let plan = ApproachModel.schedule(ApproachModel.arrivals(previous: seen.map { Array($0) }, current: order), start: 0)
        if data.ghosts.contains(row.id) {
            card(row).modifier(NWResolveFold(changedAt: data.receipts[row.id]?.changedAt))
        } else {
            NWArrival(arriving: plan[row.id] != nil, delay: plan[row.id] ?? 0, pulseY: pulseY(inset: inset), tint: row.section.color,
                      radius: row.chip == .undoable ? NightWatch.Radius.row : NightWatch.Radius.card,
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
        case .decide where row.chip == .undoable:
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
                         onLooksGood: { actions.looksGood(row) }, onSteer: { actions.steer(row) },
                         onOpen: { actions.open(row.id) }, onCancel: { actions.cancel(row.id) })
        }
    }
}
