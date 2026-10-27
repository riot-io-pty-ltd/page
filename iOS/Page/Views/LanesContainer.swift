import SwiftUI

/// LANES, live: the fleet as a list of lanes, from the session list.
struct LanesContainer: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var activity: ActivityStore

    var body: some View {
        // Ages and presence re-evaluate every 5 s. The store bumps `waitTick`
        // when the first-list wait runs out, which re-renders this view.
        TimelineView(.periodic(from: .now, by: 5)) { context in
            screen(now: context.date)
        }
        .task {
            while !Task.isCancelled, pairing.savedMacs.count > 1 {
                await pairing.refreshOthers()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    private func screen(now: Date) -> some View {
        let availability = sessions.availability(presence: MacPresence.evaluate(api.macStatus, now: Date()),
                                                 socketConnected: api.connection == .connected, now: Date())
        let name = nwMacName(sessions: sessions, pairing: pairing)
        let paused = api.inbox.contains { $0.kind == .idle && $0.subtype == "low_battery" }
        let rings = DayStats.today(history: api.history, now: now, calendar: .current).rings
        let sky = SkyModel.build(sessions: sessions.sessions, interventions: api.inbox, status: api.macStatus, rings: rings,
                                 macName: name, paused: paused, now: now)
        let lanes = LanesModel.build(sky: sky, log: activity.log, now: now)
        let macs = TowerMacRow.build(saved: pairing.savedMacs, activeId: pairing.activeMacId, activeStatus: api.macStatus,
                                     others: pairing.otherStatus, now: now)
        var data = LanesScreenData(fleet: sky, lanes: lanes, now: now, standby: macs)
        data.duskDawn = activity.duskDawn
        if availability != .ready { data.availability = SessionAvailabilityCopy(availability) }
        var a = LanesScreenActions()
        a.openRow = { row in
            if let id = row.interventionId { router.open(interventionId: id) } else { router.openSession(row.id) }
        }
        a.tapMoon = { router.openTower(.power) }
        a.availabilityAction = { action in
            switch action {
            case .repair: router.requestUnpair()
            case .retry: sessions.refresh(); Task { await api.refreshAll() }
            }
        }
        a.makeLive = { pairing.switchTo($0) }
        a.toNow = { withAnimation { router.destination = .now } }
        a.refresh = {
            sessions.refresh()
            await api.refreshAll()
            await pairing.refreshOthers()
        }
        return NWLanesScreen(data: data, actions: a)
            .onChange(of: sessions.sessions) { _, list in
                activity.observe(sessions: list, interventions: api.inbox, paused: paused)
                activity.observePower(paused: paused, sessions: list)
            }
            .onChange(of: paused) { _, p in activity.observePower(paused: p, sessions: sessions.sessions) }
            .onAppear {
                // The old Sky/Lanes toggle is gone; clear what it remembered.
                LegacySkyMode.forget()
                activity.observePower(paused: paused, sessions: sessions.sessions)
            }
    }
}
