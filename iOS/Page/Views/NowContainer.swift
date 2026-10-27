import SwiftUI

/// NOW, live: builds the ranked stream from the stores and routes every
/// action through the existing services. The drawing is `NWNowScreen`.
struct NowContainer: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var notifications: NotificationService
    @EnvironmentObject var coordinator: ActionCoordinator
    @EnvironmentObject var activity: ActivityStore
    @EnvironmentObject var tips: TipStore
    @Environment(\.scenePhase) private var scenePhase

    /// Ids on screen, so the order never re-sorts under a finger.
    @State private var shown: [String] = []
    @State private var touching = false
    @EnvironmentObject var away: AwayStore
    @State private var briefExpanded = false
    /// The rows as last drawn (ghosts included), so a card whose reply was
    /// just confirmed can stay while its Receipt thread resolves.
    @State private var lastRows: [NowRow] = []
    /// Bumped when a ghost's time is up, to draw the stream without it.
    @State private var ghostTick = 0
    /// "Show all N" is open in In flight.
    @State private var inFlightExpanded = false

    var body: some View {
        // Ages, presence and the arm ring re-evaluate every few seconds even when no data changes.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            content(now: context.date)
        }
        .task {
            await api.refreshHistory()
            away.returned()
        }
        .onChange(of: scenePhase) { old, phase in
            // Only a return from the background is an absence (Face ID and Control Centre are not).
            if phase == .active { if old == .background { away.returned() }; Task { await api.refreshHistory() } }
        }
        // A finger can be cancelled without an end event; never stay frozen for long.
        .task(id: touching) {
            guard touching else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { touching = false }
        }
        .onChange(of: pairing.activeMacId) { _, _ in activity.reset(); coordinator.reset(); shown = [] }
    }

    private var macName: String { nwMacName(sessions: sessions, pairing: pairing) }

    private func inputs(now: Date) -> NowInputs {
        NowInputs(interventions: api.inbox, inbox: api.inboxLoad.nowState, sessions: sessions.sessions, hasSessionList: sessions.hasList,
                  status: api.macStatus, history: api.history, deliveries: api.deliveries, deliveryTimes: api.deliveryTimes, now: now, macName: macName)
    }

    private func content(now: Date) -> some View {
        _ = ghostTick
        let model = NowModel.build(inputs(now: now))
        let merged = StableOrder.merge(shown: shown, ranked: model.rows, frozen: touching)
        // A card confirmed a moment ago stays, as a ghost, while its thread resolves.
        let departing = DepartingRows.merge(previous: lastRows, current: merged.rows, deliveries: api.deliveries,
                                            changedAt: api.deliveryTimes, now: Date())
        var shownModel = model
        shownModel.rows = departing.rows
        let ids = model.rows.map(\.id)
        let drawn = departing.rows.map(\.id)
        var screen = data(model: shownModel, queued: merged.queuedNew, now: now)
        screen.ghosts = departing.ghosts
        screen.inboxLoaded = api.inboxLoad == .loaded
        return NWNowScreen(data: screen, actions: actions(model: model))
            // Another Mac is another sky: nothing that changed here was news (no arrivals, exhale or dawn).
            .id(pairing.activeMacId)
            .onChange(of: ids) { _, new in if !touching { shown = new } }
            .onChange(of: touching) { _, t in if !t { shown = ids } }
            .onChange(of: drawn) { _, _ in lastRows = departing.rows }
            .onAppear { shown = ids; lastRows = departing.rows; activity.observePower(paused: model.paused, sessions: sessions.sessions) }
            .onChange(of: sessions.sessions) { _, list in
                activity.observe(sessions: list, interventions: api.inbox, paused: model.paused)
                activity.observePower(paused: model.paused, sessions: list)
            }
            .onChange(of: model.paused) { _, p in activity.observePower(paused: p, sessions: sessions.sessions) }
            .task(id: departing.ghosts) {
                guard let at = DepartingRows.nextExpiry(ghosts: departing.ghosts, changedAt: api.deliveryTimes) else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(0, at.timeIntervalSinceNow + 0.05) * 1_000_000_000))
                if !Task.isCancelled { ghostTick += 1 }
            }
    }

    private func data(model: NowModel, queued: Int, now: Date) -> NowScreenData {
        var d = NowScreenData(model: model, log: SettledLog.build(history: api.history, now: now, calendar: .current), chip: MacChipModel.build(macName: macName, status: api.macStatus, now: now),
                              now: now)
        d.queuedNew = queued
        d.inFlight = InFlightSection.build(sessions: sessions.sessions, hasSessionList: sessions.hasList, workflows: sessions.workflows,
                                           stuck: FlightHealth.stuckSessionIds(api.inbox), now: now, expanded: inFlightExpanded)
        d.biometry = BiometricGate.displayName
        d.pending = coordinator.pending
        var outcomes: [String: CardOutcome] = [:]
        var receipts: [String: ReceiptThreadInput] = [:]
        for row in model.rows {
            let receipt = ReceiptThreadInput(pending: coordinator.pending[row.id], delivery: api.deliveries[row.id],
                                             localProblem: coordinator.localProblems[row.id], changedAt: api.deliveryTimes[row.id])
            if !receipt.isEmpty { receipts[row.id] = receipt }
            if let why = coordinator.localProblems[row.id] { outcomes[row.id] = .problem(why); continue }
            let o = CardOutcome.from(pending: coordinator.pending[row.id], delivery: api.deliveries[row.id], now: now)
            if o != .none { outcomes[row.id] = o }
        }
        d.outcomes = outcomes
        d.receipts = receipts
        // One first-time tip at a time, under the first row of its kind that has nothing under way.
        d.tip = tips.book.nowTip(NowTipInputs(rows: model.rows, inFlight: d.inFlight.rows.map(\.id),
                                              busy: Set(outcomes.keys).union(coordinator.pending.keys)))
        d.answerable = Set(model.rows.filter { row in
            let page = api.inbox.first { $0.id == row.id }
            return row.chip == .question && AnswerPicker.ask(for: sessions.session(row.sessionId), pageIsQuestion: true,
                                                             hook: page?.isBlockingHook ?? false, pageContext: page?.context) != nil
        }.map(\.id))
        d.problem = problem(now: now)
        d.banners = banners(now: now) + NowBanner.otherMacs(TowerMacRow.build(saved: pairing.savedMacs, activeId: pairing.activeMacId,
                                                                             activeStatus: api.macStatus, others: pairing.otherStatus, now: now))
        if let ab = away.absence {
            // Measured over the absence itself, so it does not grow while you are back.
            let brief = ReturnBrief.build(since: ab.since, now: ab.returnedAt, history: api.history, open: api.inbox, sessions: sessions.sessions,
                                          hasSessionList: sessions.hasList, status: api.macStatus, timeZone: .current)
            if away.briefShowing { d.brief = brief; d.briefExpanded = briefExpanded }
            if ab.showsHandover(now: now) {
                d.handover = ReturnBrief.handoverSentence(away: ab.duration, finished: brief.finished, needYou: model.needYouCount + model.lookCount)
            }
        }
        return d
    }

    /// The one thing that is wrong, if anything: the Horizon goes hollow and the first card says what to do.
    private func problem(now: Date) -> ProblemState? {
        let status = api.macStatus
        return ProblemState.build(.init(
            macName: macName, presence: MacPresence.evaluate(status, now: now), authRejected: api.authRejected,
            inboxFailure: api.inboxLoad.failureMessage, connected: api.connection == .connected,
            relayHost: pairing.savedMacs.first { $0.id == pairing.activeMacId }?.relayHost,
            battery: status?.batteryPercent, onAC: status?.onAC, cutoff: status?.forecast?.cutoff,
            pausedSessions: api.inbox.filter { $0.kind == .idle && $0.subtype == "low_battery" }.count, now: now))
    }

    private func banners(now: Date) -> [NowBanner] {
        NowBanner.build(.init(authRejected: api.authRejected, inboxFailure: api.inboxLoad.failureMessage, connected: api.connection == .connected,
                              presence: MacPresence.evaluate(api.macStatus, now: now), notifications: notifications.authorization.nw,
                              push: notifications.nwPush, now: now))
    }

    private func actions(model: NowModel) -> NowScreenActions {
        var a = NowScreenActions()
        a.open = { router.open(interventionId: $0) }
        a.approve = { row in
            if row.canSwipeApprove { tips.retire(.swipeToApprove) }
            coordinator.begin(row: row, kind: .approve)
        }
        a.holdComplete = { row in
            tips.retire(.holdToApprove)
            coordinator.commitHold(row: row, macName: macName)
        }
        a.deny = { coordinator.begin(row: $0, kind: .deny) }
        a.looksGood = { coordinator.begin(row: $0, kind: .carryOn) }
        a.steer = { router.open(interventionId: $0.id) }
        a.cancel = { id in
            // The ring, if it is still running; otherwise the sheet, to see and retry.
            if coordinator.isArming(id) { coordinator.cancel(id) } else { router.open(interventionId: id) }
        }
        a.tapChip = { router.openTower() }
        a.openSettings = { router.openTower() }
        a.tapRunway = { router.openTower(.budget) }
        a.openRoom = { id, entry in
            tips.retire(.inFlight)
            router.openSession(id, entry: entry)
        }
        a.toggleInFlight = { inFlightExpanded.toggle() }
        a.dismissTip = { tips.retire($0) }
        a.toLanes = { withAnimation { router.destination = .lanes } }
        a.toggleBrief = { briefExpanded.toggle() }
        a.dismissBrief = { away.dismissBrief(); briefExpanded = false }
        a.reviewFinished = { briefExpanded = false }
        a.seeAll = { router.openHistory() }
        a.banner = { action in
            switch action {
            case .repair: router.requestUnpair()
            case .retry: sessions.refresh(); Task { await api.refreshAll() }
            case .openNotificationSettings: SystemSettings.openNotifications()
            case .retryPush: Task { await notifications.registerWithRelay(force: true) }
            case .switchMac(let id): pairing.switchTo(id)
            }
        }
        a.problem = { action in
            switch action {
            case .recheck: sessions.refresh(); Task { await api.refreshAll(); await pairing.refreshOthers() }
            case .repair: router.requestUnpair()
            }
        }
        a.showNew = { shown = model.rows.map(\.id); touching = false }
        a.refresh = {
            // Pulling down re-syncs with the Mac; after 10 minutes away it also re-opens the last Brief.
            sessions.refresh()
            await api.refreshAll()
            await pairing.refreshOthers()
            away.reopenBrief(); briefExpanded = false
        }
        a.touching = { touching = $0 }
        return a
    }
}
