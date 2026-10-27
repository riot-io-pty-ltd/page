import SwiftUI

/// The Tower, live: power, budget, Macs, attention, pairing, appearance and
/// about, from the stores. Every option the old Settings screen had is here.
struct TowerContainer: View {
    var scrollTo: TowerSection?

    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var notifications: NotificationService
    @EnvironmentObject var glowStore: CardGlowStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var tips: TipStore
    @Environment(\.dismiss) private var dismiss
    @State private var addingMac = false
    @State private var removingMac: SavedMac?
    @State private var confirmingUnpair = false

    static let feedbackURL = URL(string: "https://github.com/riot-io-pty-ltd/page/issues")!

    var body: some View {
        // Presence and ages re-evaluate every 15 s even when no data changes.
        TimelineView(.periodic(from: .now, by: 15)) { context in
            NWTowerScreen(data: data(now: context.date), actions: actions)
        }
        .background(NightWatch.Palette.backgroundDeep.color.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            await api.refreshStatus()
            await notifications.refreshAuthorization()
            await pairing.refreshOthers()
        }
        .sheet(isPresented: $addingMac) {
            PairMacView(onPaired: {
                addingMac = false
                api.activate()
            })
            .environmentObject(pairing)
            .environmentObject(api)
        }
        .confirmationDialog(UnpairCopy.title(mac: pairing.pairedMac?.name), isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { pairing.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(UnpairCopy.message)
        }
        .confirmationDialog("Remove \(removingMac?.name ?? "this Mac")?",
                            isPresented: Binding(get: { removingMac != nil }, set: { if !$0 { removingMac = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let m = removingMac { pairing.remove(m.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This iPhone forgets that Mac. Scan its pairing code again to add it back.")
        }
    }

    private func data(now: Date) -> TowerScreenData {
        let name = pairing.pairedMac?.name ?? nwMacName(sessions: sessions, pairing: pairing)
        let presence = MacPresence.evaluate(api.macStatus, now: now)
        var line: [String] = [presence.summary(now: now)]
        if presence.isReachable, let s = api.macStatus {
            if let n = s.activeSessions { line.append("\(n) active session\(n == 1 ? "" : "s")") }
            if let p = s.batteryPercent { line.append("Battery \(p)%" + (s.onAC == true ? ", on power" : "")) }
        }
        let availability = sessions.availability(presence: presence, socketConnected: api.connection == .connected, now: now)
        let live: String
        switch availability {
        case .ready: let n = sessions.sessions.count; live = "\(n) live session\(n == 1 ? "" : "s") · end-to-end encrypted"
        case .needsRepair: live = "Re-pair with your Mac to turn on live sessions"
        default: live = SessionAvailabilityCopy(availability).shortStatus
        }
        return TowerScreenData(
            macName: name, power: TowerPower.build(status: api.macStatus), budget: TowerBudget.build(usage: api.macStatus?.usage, now: now),
            macs: TowerMacRow.build(saved: pairing.savedMacs, activeId: pairing.activeMacId, activeStatus: api.macStatus, others: pairing.otherStatus, now: now),
            macLine: line.joined(separator: " · "), relayHost: pairing.relayHost,
            relayText: RelayConnectionText.text(connected: api.connection == .connected, connecting: api.connection == .connecting, failure: api.inboxLoad.failureMessage),
            notifications: notifications.authorization.nw, push: notifications.nwPush, liveSessionsText: live,
            glow: glowStore.glow, version: SettingsVersion.string, now: now, scrollTo: scrollTo, feedbackURL: Self.feedbackURL)
    }

    private var actions: TowerScreenActions {
        var a = TowerScreenActions()
        a.close = { dismiss() }
        a.switchMac = { id in pairing.switchTo(id); dismiss() }
        a.removeMac = { id in removingMac = pairing.savedMacs.first { $0.id == id } }
        a.addMac = { addingMac = true }
        a.unpair = { confirmingUnpair = true }
        a.openNotificationSettings = { SystemSettings.openNotifications() }
        a.turnOnNotifications = { Task { await notifications.requestAuthorizationIfNeeded() } }
        a.setGlow = { glowStore.glow = $0 }
        a.openHistory = { router.openHistory() }
        a.resetTips = { tips.resetAll() }
        a.refresh = {
            await api.refreshAll()
            await notifications.refreshAuthorization()
            await pairing.refreshOthers()
        }
        return a
    }
}

/// "0.1.0 (1)" from the bundle, which XcodeGen fills from
/// MARKETING_VERSION / CURRENT_PROJECT_VERSION.
enum SettingsVersion {
    static var string: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
