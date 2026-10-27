import SwiftUI

/// The root of the paired app: Now and Lanes, the capsule with the pulse, and
/// every sheet. Two places and one verb; sessions are rooms and Settings is
/// the Tower, never tabs.
struct NightWatchRoot: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var notifications: NotificationService
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var stop: StopCoordinator
    @State private var held: TimeInterval?

    var body: some View {
        let busy = StopPlan.build(sessions: sessions.sessions, hasSessionList: sessions.hasList, workingFromStatus: api.macStatus?.working,
                                 macName: nwMacName(sessions: sessions, pairing: pairing))
        let pulse = NowModel.pulse(inbox: api.inbox, now: Date())
        NWShell(destination: $router.destination,
                decideCount: api.inbox.filter { NowRowBuilder.section(of: $0) == .decide }.count,
                workingCount: sessions.hasList ? sessions.sessions.filter { $0.state == .active }.count : (api.macStatus?.working ?? 0),
                pulseWaiting: pulse.waiting, pulseLongestWait: pulse.longestWait,
                stop: stop.phase, stopPlan: busy, biometry: BiometricGate.displayName, held: $held,
                onPulseTap: { router.openDispatch() },
                onPulseHold: { stop.holdCompleted(plan: busy) }) {
            NowContainer()
        } lanes: {
            LanesContainer()
        }
        // Set on the shell only, so the sheet that covers it keeps animating.
        .environment(\.nwAnimationsPaused, router.sheets.current != nil)
        .preferredColorScheme(.dark)
        .ignoresSafeArea(.keyboard)
        .task {
            // First appearance after launch or after pairing.
            api.activate()
            #if DEBUG
            // Mock data (`-PageDevPairing`) never asks iOS for notifications.
            if api.isDevMode { return }
            #endif
            // After a first pairing, the Paired screen asks (once, in words first).
            if router.pairedWelcome { return }
            await notifications.requestAuthorizationIfNeeded()
        }
        .sheet(item: router.sheetBinding, onDismiss: router.sheetDismissed) { sheet in
            SheetHost(sheet: sheet)
        }
        .confirmationDialog(UnpairCopy.title(mac: pairing.pairedMac?.name), isPresented: $router.confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { pairing.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(UnpairCopy.message)
        }
    }
}

/// What each sheet holds.
private struct SheetHost: View {
    let sheet: NWSheet

    var body: some View {
        switch sheet {
        case .decision(let id):
            DecisionContainer(interventionId: id)
                .presentationDetents([.fraction(0.92), .large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(34)
        case .session(let id):
            // Keyed by the session: a room's draft and last-seen copy can never carry over to another session.
            SessionRoomContainer(sessionId: id)
                .id(id)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(34)
                .presentationBackground(NightWatch.Palette.backgroundDeep.color)
        case .tower(let section):
            TowerContainer(scrollTo: section)
                .presentationDragIndicator(.visible)
        case .dispatch:
            DispatchContainer()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        case .history:
            HistoryContainer()
                .presentationDragIndicator(.visible)
        }
    }
}

/// The unpair confirmation, worded once. The root presents it for Now, Lanes
/// and the Tower's own button alike (the Tower sheet covers the root, so it
/// presents the same dialog itself); both read this copy.
enum UnpairCopy {
    static func title(mac: String?) -> String { "Unpair \(mac ?? "this Mac")?" }
    static let message = "This iPhone will stop receiving pages until you scan a pairing code again. On your Mac, open Page → Pair phone… and scan the new code."
}
