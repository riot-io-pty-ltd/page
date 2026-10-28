import SwiftUI

@main
struct PageApp: App {
    @UIApplicationDelegateAdaptor(PageAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            LaunchGate()
        }
    }
}

/// Chooses what the window shows. In DEBUG, `-NWRender <screen>` swaps the
/// app for the render harness (fixtures only); `LiveApp`, which owns every
/// live store (pairing, relay, notifications, sessions), is then never built,
/// so the harness cannot touch the Keychain, the network or push.
struct LaunchGate: View {
    var body: some View {
        #if DEBUG
        if let args = RenderArguments.parse(ProcessInfo.processInfo.arguments) {
            RenderHarnessRoot(args: args)
        } else {
            LiveApp()
        }
        #else
        LiveApp()
        #endif
    }
}

/// The real app: the live stores, the Card glow setting and the root view.
struct LiveApp: View {
    @StateObject private var pairing = PairingStore()
    @StateObject private var api = APIClient.shared
    @StateObject private var notifications = NotificationService.shared
    @StateObject private var router = AppRouter.shared
    @StateObject private var sessions = SessionStore.shared
    @StateObject private var glow = CardGlowStore()
    @StateObject private var coordinator = ActionCoordinator()
    @StateObject private var stop = StopCoordinator()
    @StateObject private var activity = ActivityStore()
    @StateObject private var away = AwayStore()
    @StateObject private var tips = TipStore()

    var body: some View {
        RootView()
            .environmentObject(pairing)
            .environmentObject(api)
            .environmentObject(notifications)
            .environmentObject(router)
            .environmentObject(sessions)
            .environmentObject(glow)
            .environmentObject(coordinator)
            .environmentObject(stop)
            .environmentObject(activity)
            .environmentObject(away)
            .environmentObject(tips)
            // The one place every glass surface reads the Card glow from.
            .environment(\.nwCardGlow, glow.glow)
            .onOpenURL { url in
                // page://intervention/<id> opens that page's reply screen.
                router.handle(url: url)
            }
    }
}

struct RootView: View {
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var notifications: NotificationService
    @EnvironmentObject var activity: ActivityStore
    @EnvironmentObject var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if pairing.isPaired {
                NightWatchRoot()
            } else {
                PairMacView()
            }
            // A first pairing ends on its own screen: the first star, what Page pages you for,
            // and the one place notifications are asked for.
            if router.pairedWelcome && pairing.isPaired {
                PairedContainer()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: router.pairedWelcome)
        .onChange(of: pairing.isPaired) { was, now in
            guard !was, now else { return }
            #if DEBUG
            if api.isDevMode { return }
            #endif
            // Only the first Mac gets the welcome; adding another Mac (a sheet) does not.
            if pairing.savedMacs.count <= 1 { router.pairedWelcome = true }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                pairing.reloadIfNeeded()
                // Unreadable before the first unlock after a reboot.
                if !SessionStore.shared.hasKey { SessionStore.shared.reloadKey() }
                // A countdown that ran out while Page was away sends now (or comes back as a draft if long stale).
                SessionStore.shared.appBecameActive()
                Task { await notifications.refreshAuthorization() }
                // Backfills the widget's copy for pairings made before it.
                WidgetShare.sync()
                if pairing.isPaired {
                    api.activate()
                    #if DEBUG
                    if api.isDevMode { break }
                    #endif
                    if !router.pairedWelcome { Task { await notifications.requestAuthorizationIfNeeded() } }
                }
            case .background:
                // iOS would freeze the socket anyway; close it cleanly and
                // rely on APNs until we're back.
                api.disconnect()
                WidgetShare.reload()
                // When Page was last in front: the Return Brief measures an absence from here.
                AwayTracker.markActive(Date())
                activity.flush()
            default:
                break
            }
        }
    }
}
