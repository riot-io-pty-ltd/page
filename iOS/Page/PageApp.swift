import SwiftUI

@main
struct PageApp: App {
    @UIApplicationDelegateAdaptor(PageAppDelegate.self) private var appDelegate
    @StateObject private var pairing = PairingStore()
    @StateObject private var api = APIClient.shared
    @StateObject private var notifications = NotificationService.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var sessions = SessionStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pairing)
                .environmentObject(api)
                .environmentObject(notifications)
                .environmentObject(router)
                .environmentObject(sessions)
                .onOpenURL { url in
                    // page://intervention/<id> opens that page's reply screen.
                    router.handle(url: url)
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var notifications: NotificationService
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if pairing.isPaired {
                MainTabView()
            } else {
                PairMacView()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                pairing.reloadIfNeeded()
                // Unreadable before the first unlock after a reboot.
                if !SessionStore.shared.hasKey { SessionStore.shared.reloadKey() }
                Task { await notifications.refreshAuthorization() }
                // Backfills the widget's copy for pairings made before it.
                WidgetShare.sync()
                if pairing.isPaired {
                    api.activate()
                    Task { await notifications.requestAuthorizationIfNeeded() }
                }
            case .background:
                // iOS would freeze the socket anyway; close it cleanly and
                // rely on APNs until we're back.
                api.disconnect()
                WidgetShare.reload()
            default:
                break
            }
        }
    }
}

struct MainTabView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var notifications: NotificationService
    @EnvironmentObject var router: AppRouter

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch router.tab {
                case .inbox:    InboxView()
                case .sessions: SessionsView()
                case .history:  HistoryView()
                case .settings: SettingsView()
                }
            }
            // A second sheet host: only one sheet can be up at a time, and
            // AppRouter hands over between this one and the reply sheet.
            .sheet(item: $router.presentedSession, onDismiss: router.sheetDismissed) { item in
                SessionDetailView(sessionId: item.id)
            }
            TabBarHost(selection: $router.tab, inboxCount: api.inbox.count)
        }
        .ignoresSafeArea(.keyboard)
        .task {
            // First appearance after launch or after pairing.
            api.activate()
            await notifications.requestAuthorizationIfNeeded()
        }
        .sheet(item: $router.presented, onDismiss: router.sheetDismissed) { item in
            ReplyView(interventionId: item.id)
        }
    }
}

/// The tab bar plus the one thing it needs from live sessions (how many
/// need you), so session updates re-render the bar, not every tab.
private struct TabBarHost: View {
    @Binding var selection: AppTab
    let inboxCount: Int
    @EnvironmentObject var sessions: SessionStore

    var body: some View {
        PillTabBar(selection: $selection, inboxCount: inboxCount,
                   sessionsNeedingYou: SessionGrouping.needsYouCount(sessions.sessions))
    }
}
