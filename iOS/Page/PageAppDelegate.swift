import SwiftUI
import UIKit
import UserNotifications

/// UIKit delegate adaptor for what SwiftUI's App lifecycle doesn't surface:
/// launch-time notification setup, APNs device-token callbacks and silent
/// "page closed" pushes.
final class PageAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        // The render harness (-NWRender) never touches notifications or push.
        if RenderArguments.parse(ProcessInfo.processInfo.arguments) != nil { return true }
        #endif
        // Must happen before launch finishes: a Deny/Reply tapped on the lock
        // screen can launch the app in the background with no scene at all,
        // and iOS drops the response if no delegate is set by then.
        NotificationService.shared.configure()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationService.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No polling fallback exists: without APNs, pages only arrive while
        // the app is open. NotificationService surfaces this in the UI.
        NotificationService.shared.didFailToRegister(error: error)
    }

    /// Silent push the Worker sends when pages close
    /// (`{aps:{content-available:1}, interventionClosedId, interventionClosedIds}`):
    /// pull every stale banner off the lock screen and recount the badge.
    /// One event can close several pages (a cascade, or the Mac's sync), so
    /// the whole `interventionClosedIds` array is honoured, not just the
    /// v1 single id.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let closedIds = PushPayload.closedIds(from: userInfo)
        guard !closedIds.isEmpty else {
            completionHandler(.noData)
            return
        }
        // iOS gives a silent push about 30s; answer by 25s even if the
        // inbox refetch is still running, or later pushes get throttled.
        let once = CompletionOnce(completionHandler)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            once.call(.newData)
        }
        Task { @MainActor in
            await APIClient.shared.handleClosePush(interventionIds: closedIds)
            once.call(.newData)
        }
    }
}

/// Calls a background-fetch completion handler exactly once.
@MainActor
private final class CompletionOnce {
    private var handler: ((UIBackgroundFetchResult) -> Void)?

    init(_ handler: @escaping (UIBackgroundFetchResult) -> Void) { self.handler = handler }

    func call(_ result: UIBackgroundFetchResult) {
        handler?(result)
        handler = nil
    }
}
