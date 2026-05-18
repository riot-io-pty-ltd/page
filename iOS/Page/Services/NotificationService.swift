import Foundation
import UserNotifications
import UIKit

@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    @Published private(set) var authorized: Bool = false
    @Published private(set) var deviceToken: String?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            authorized = granted
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            authorized = false
        }
        // Add the action category once.
        let approve = UNNotificationAction(identifier: "APPROVE", title: "Approve", options: [.foreground])
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [.foreground],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Type a reply…")
        let category = UNNotificationCategory(identifier: "PAGE",
                                              actions: [approve, deny, reply],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func setDeviceToken(_ data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        Task { await APIClient.shared.registerAPNs(deviceToken: token) }
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let interventionId = info["interventionId"] as? String else { return }

        let action: String? = {
            switch response.actionIdentifier {
            case "APPROVE": return "approve"
            case "DENY": return "deny"
            case "REPLY": return "custom"
            default: return nil
            }
        }()
        let text: String = (response as? UNTextInputNotificationResponse)?.userText ?? ""

        await APIClient.shared.reply(interventionId: interventionId, text: text, action: action)
    }
}
