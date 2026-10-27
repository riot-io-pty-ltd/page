import SwiftUI

/// SKY, live: the fleet as constellations or Lanes, from the session list.
struct SkyContainer: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var activity: ActivityStore
    @State private var mode = SkyMode.load()
    @State private var selected: String?

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
        var data = SkyScreenData(sky: sky, lanes: lanes, mode: mode, now: now, standby: macs, selectedStar: selected)
        data.duskDawn = activity.duskDawn
        if availability != .ready { data.availability = SessionAvailabilityCopy(availability) }
        var a = SkyScreenActions()
        a.setMode = { m in mode = m; m.save() }
        a.select = { selected = $0 }
        a.openStar = { star in
            selected = nil
            if let id = star.interventionId { router.open(interventionId: id) } else { router.openSession(star.id) }
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
        return NWSkyScreen(data: data, actions: a)
            .onChange(of: sessions.sessions) { _, list in
                activity.observe(sessions: list, interventions: api.inbox, paused: paused)
                activity.observePower(paused: paused, sessions: list)
            }
            .onChange(of: paused) { _, p in activity.observePower(paused: p, sessions: sessions.sessions) }
            .onAppear { activity.observePower(paused: paused, sessions: sessions.sessions) }
    }
}
