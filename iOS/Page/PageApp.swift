import SwiftUI

@main
struct PageApp: App {
    @UIApplicationDelegateAdaptor(PageAppDelegate.self) private var appDelegate
    @StateObject private var pairing = PairingStore()
    @StateObject private var api = APIClient.shared
    @StateObject private var notifications = NotificationService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(pairing)
                .environmentObject(api)
                .environmentObject(notifications)
                .preferredColorScheme(nil)  // system-driven
                .task {
                    await notifications.requestAuthorization()
                }
                .onChange(of: pairing.relayURL) { _, newValue in
                    PairingStoreShared.relayURL = newValue
                }
                .onChange(of: pairing.relayToken) { _, newValue in
                    PairingStoreShared.relayToken = newValue
                }
                .onAppear {
                    // Seed the cross-store bridges on first appearance so
                    // APIClient has values before any user interaction.
                    PairingStoreShared.relayURL = pairing.relayURL
                    PairingStoreShared.relayToken = pairing.relayToken
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var pairing: PairingStore

    var body: some View {
        if pairing.pairedMac == nil {
            PairMacView()
        } else {
            MainTabView()
        }
    }
}

struct MainTabView: View {
    @State private var selection: AppTab = .inbox

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selection {
                case .inbox:    InboxView()
                case .history:  HistoryView()
                case .stats:    StatsView()
                case .settings: SettingsView()
                }
            }
            PillTabBar(selection: $selection)
        }
        .ignoresSafeArea(.keyboard)
    }
}
