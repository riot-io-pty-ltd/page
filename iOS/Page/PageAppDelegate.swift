import SwiftUI
import UIKit
import UserNotifications

/// UIKit delegate adaptor for things SwiftUI's App lifecycle doesn't surface
/// natively — APNs device-token registration, scene URL callbacks for Google
/// OAuth return, etc.
final class PageAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            NotificationService.shared.setDeviceToken(deviceToken)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Surface in logs; we'll fall back to in-app polling if APNs is unavailable.
        print("APNs registration failed: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        return config
    }
}
