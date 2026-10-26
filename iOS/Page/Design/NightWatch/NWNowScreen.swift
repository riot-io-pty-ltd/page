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

    var body: some View {
        GeometryReader { geo in
            let inset = topInsetOverride ?? geo.safeAreaInsets.top
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 16) {
                    horizon(inset: inset)
                    VStack(spacing: 16) { stream }
                        .padding(.horizontal, NightWatch.Space.gutter)
                    Spacer().frame(height: 120)
                }
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

    // MARK: Horizon

    private func horizon(inset: CGFloat) -> some View {
        let m = data.model
        let p = data.problem
        // A problem is never "All quiet": the Horizon goes hollow and says what is wrong.
        // Board 01: the Horizon is a quarter to a third of the screen when something
        // needs you, so the first Decide card is in view; all quiet gets the sky to itself.
        let height: CGFloat = quiet && p == nil ? 470 : 244
        return ZStack(alignment: .top) {
            NWHorizon(palette: p.map { $0.tone == .slate ? .asleep : .problem } ?? NightWatch.AuroraPalette(m.mood),
                      pulse: p.map { $0.tone == .slate ? .hollowSlate : .hollowAmber } ?? NWPulseOrb.Style(m.mood),
                      headline: p?.title ?? data.handover ?? m.headline,
                      subline: p?.subtitle ?? (data.handover == nil ? m.subline : m.headline),
                      footnote: p == nil && quiet && m.headline == "All quiet" ? "Page is keeping watch. Go to sleep." : nil,
                      height: height, topInset: inset)
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

    @ViewBuilder private var stream: some View {
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
            NWSectionHeader(title: section.title, count: rows.count, color: section.color).id("section-\(section.title.lowercased())")
            ForEach(rows) { row in
                card(row)
                    .id("row-\(row.id)")
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
            // The Brief sits after Decide and Look when something needs you.
            if section == .look || (section == .decide && !sections.contains { $0.0 == .look }), let b = data.brief, b.hasUrgent {
                NWBriefCard(brief: b, expanded: data.briefExpanded, onToggle: actions.toggleBrief,
                            onDismiss: actions.dismissBrief, onReview: reviewFinished)
            }
        }
        if let b = data.brief, b.hasUrgent, !sections.contains(where: { $0.0 == .decide || $0.0 == .look }) {
            NWBriefCard(brief: b, expanded: data.briefExpanded, onToggle: actions.toggleBrief,
                        onDismiss: actions.dismissBrief, onReview: reviewFinished)
        }
        if let line = data.model.receiptLine { NWReceiptLine(text: line, failed: data.model.receiptFailed) }
        if quiet && data.problem == nil { NWTonightCard(rings: data.model.rings) }
        if !data.strands.isEmpty {
            NWInFlightRibbon(strands: data.strands, onStrand: actions.tapStrand, onHeader: actions.toSky)
        }
        NWSettledList(log: data.log, onSeeAll: actions.seeAll).padding(.top, 6)
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
            NWUndoableRow(row: row, now: data.now, outcome: outcome, pending: pending, fixedDrag: data.fixedDrag,
                          onApprove: { actions.approve(row) }, onOpen: { actions.open(row.id) }, onCancel: { actions.cancel(row.id) })
        case .decide where row.chip == .question:
            NWQuestionCard(row: row, now: data.now, onOpen: { actions.open(row.id) })
        case .decide:
            NWDecideCard(row: row, now: data.now, outcome: outcome, pending: pending, fixedHold: data.fixedHold,
                         onApprove: { actions.approve(row) }, onHoldComplete: { actions.holdComplete(row) },
                         onDeny: { actions.deny(row) }, onOpen: { actions.open(row.id) }, onCancel: { actions.cancel(row.id) })
        case .look:
            NWLookCard(row: row, now: data.now, outcome: outcome, pending: pending,
                       onSteer: { actions.steer(row) }, onOpen: { actions.open(row.id) }, onCancel: { actions.cancel(row.id) })
        case .review:
            NWReviewCard(row: row, now: data.now, outcome: outcome, pending: pending,
                         onLooksGood: { actions.looksGood(row) }, onSteer: { actions.steer(row) },
                         onOpen: { actions.open(row.id) }, onCancel: { actions.cancel(row.id) })
        }
    }
}
