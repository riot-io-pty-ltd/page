import SwiftUI

@main
struct PageApp: App {
    @UIApplicationDelegateAdaptor(PageAppDelegate.self) private var appDelegate
    @StateObject private var pairing = PairingStore()
    @StateObject private var api = APIClient.shared
    @StateObject private var notifications = NotificationService.shared
    @StateObject private var router = AppRouter.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pairing)
                .environmentObject(api)
                .environmentObject(notifications)
                .environmentObject(router)
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
                Task { await notifications.refreshAuthorization() }
                if pairing.isPaired {
                    api.activate()
                    Task { await notifications.requestAuthorizationIfNeeded() }
                }
            case .background:
                // iOS would freeze the socket anyway; close it cleanly and
                // rely on APNs until we're back.
                api.disconnect()
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
                case .history:  HistoryView()
                case .stats:    StatsView()
                case .settings: SettingsView()
                }
            }
            PillTabBar(selection: $router.tab, inboxCount: api.inbox.count)
        }
        .ignoresSafeArea(.keyboard)
        .task {
            // First appearance after launch or after pairing.
            api.activate()
            await notifications.requestAuthorizationIfNeeded()
        }
        .sheet(item: $router.presented) { item in
            ReplyView(interventionId: item.id)
        }
    }
}
