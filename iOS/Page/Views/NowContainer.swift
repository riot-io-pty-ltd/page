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
    @Environment(\.scenePhase) private var scenePhase

    /// Ids on screen, so the order never re-sorts under a finger.
    @State private var shown: [String] = []
    @State private var touching = false
    @EnvironmentObject var away: AwayStore
    @State private var briefExpanded = false

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
        let model = NowModel.build(inputs(now: now))
        let merged = StableOrder.merge(shown: shown, ranked: model.rows, frozen: touching)
        var shownModel = model
        shownModel.rows = merged.rows
        let ids = model.rows.map(\.id)
        return NWNowScreen(data: data(model: shownModel, queued: merged.queuedNew, now: now), actions: actions(model: model))
            .onChange(of: ids) { _, new in if !touching { shown = new } }
            .onChange(of: touching) { _, t in if !t { shown = ids } }
            .onAppear { shown = ids }
            .onChange(of: sessions.sessions) { _, list in
                activity.observe(sessions: list, interventions: api.inbox, paused: model.paused)
            }
    }

    private func data(model: NowModel, queued: Int, now: Date) -> NowScreenData {
        var d = NowScreenData(model: model, log: SettledLog.build(history: api.history, now: now, calendar: .current), chip: MacChipModel.build(macName: macName, status: api.macStatus, now: now),
                              now: now)
        d.queuedNew = queued
        d.strands = InFlightStrand.build(sessions: sessions.sessions, workflows: sessions.workflows, now: now)
        d.pending = coordinator.pending
        var outcomes: [String: CardOutcome] = [:]
        for row in model.rows {
            if let why = coordinator.localProblems[row.id] { outcomes[row.id] = .problem(why); continue }
            let o = CardOutcome.from(pending: coordinator.pending[row.id], delivery: api.deliveries[row.id], now: now)
            if o != .none { outcomes[row.id] = o }
        }
        d.outcomes = outcomes
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
        a.approve = { coordinator.begin(row: $0, kind: .approve) }
        a.holdComplete = { coordinator.commitHold(row: $0, macName: macName) }
        a.deny = { coordinator.begin(row: $0, kind: .deny) }
        a.looksGood = { coordinator.begin(row: $0, kind: .carryOn) }
        a.steer = { router.open(interventionId: $0.id) }
        a.cancel = { id in
            // The ring, if it is still running; otherwise the sheet, to see and retry.
            if coordinator.isArming(id) { coordinator.cancel(id) } else { router.open(interventionId: id) }
        }
        a.tapChip = { router.openTower() }
        a.tapRunway = { router.openTower(.budget) }
        a.tapStrand = { router.openSession($0) }
        a.toSky = { withAnimation { router.destination = .sky } }
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
