import SwiftUI

/// The Paired screen, live: the Mac's name, how many sessions it is already
/// reporting, and the one button that asks for notifications. The Allow
/// button is the only thing that raises iOS's permission dialog after a first
/// pairing; "Not now" leaves the choice for later.
struct PairedContainer: View {
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var notifications: NotificationService
    @EnvironmentObject var router: AppRouter

    var body: some View {
        let count = sessions.hasList ? sessions.sessions.count : api.macStatus?.activeSessions
        let model = PairedWelcome.build(macName: pairing.pairedMac?.name ?? "", liveSessions: count,
                                        isFirstMac: pairing.savedMacs.count <= 1, notifications: notifications.authorization.nw)
        NWPairedScreen(model: model, onAction: { act(model.action) }, onSkip: { done() })
            .preferredColorScheme(.dark)
            .task {
                // The first status and list land within a moment; the count follows them.
                await notifications.refreshAuthorization()
            }
    }

    private func act(_ action: PairedWelcome.Action) {
        switch action {
        case .allowNotifications:
            Task {
                await notifications.requestAuthorizationIfNeeded()
                done()
            }
        case .openSettings:
            SystemSettings.openNotifications()
            done()
        case .continueToNow:
            done()
        }
    }

    private func done() { router.pairedWelcome = false }
}
