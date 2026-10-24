import Foundation
import UserNotifications
import UIKit

/// Notification permission, APNs registration with the relay, actionable
/// categories, and handling of notification responses.
///
/// `configure()` runs from `application(_:didFinishLaunchingWithOptions:)`:
/// the delegate must be in place before launch finishes, or a lock-screen
/// action that cold-launches the app in the background is dropped.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    enum Authorization: Equatable {
        case unknown, notDetermined, denied, authorized
    }

    enum PushState: Equatable {
        case unknown
        case registering
        case registered
        /// The relay didn't accept the device token (will retry next launch).
        case failed(String)
        /// iOS couldn't give us a device token at all (e.g. a build signed
        /// without the aps-environment entitlement).
        case unavailable(String)
    }

    @Published private(set) var authorization: Authorization = .unknown
    @Published private(set) var push: PushState = .unknown

    private let center = UNUserNotificationCenter.current()
    private static let deviceTokenKey = "page.apnsDeviceToken"
    /// (device token, relay token) last registered this process, so
    /// foregrounding doesn't re-POST every time.
    private var registeredPair: (device: String, relay: String)?
    private var configured = false

    private override init() {
        super.init()
    }

    var deviceToken: String? { KeychainStore.get(Self.deviceTokenKey) }

    func configure() {
        guard !configured else { return }
        configured = true
        center.delegate = self
        registerCategories()
        Task { await refreshAuthorization() }
    }

    /// Per-kind categories (the Worker picks one from the page's kind) plus
    /// the legacy "PAGE" category older Workers send for everything.
    ///
    /// No action uses `.foreground`: replies are sent in the background
    /// straight from the banner. Every action that types into the Mac uses
    /// `.authenticationRequired`, so approving a shell command from a locked
    /// phone requires Face ID / passcode first.
    private func registerCategories() {
        let approve = UNNotificationAction(identifier: NotificationActionID.approve, title: "Approve",
                                           options: [.authenticationRequired],
                                           icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: NotificationActionID.deny, title: "Deny",
                                        options: [.authenticationRequired, .destructive],
                                        icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let carryOn = UNNotificationAction(identifier: NotificationActionID.carryOn, title: "Carry on",
                                           options: [.authenticationRequired],
                                           icon: UNNotificationActionIcon(systemImageName: "arrow.right"))
        let reply = UNTextInputNotificationAction(identifier: NotificationActionID.reply, title: "Reply",
                                                  options: [.authenticationRequired],
                                                  icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: "Send",
                                                  textInputPlaceholder: "Type a reply…")
        let denyWithText = UNTextInputNotificationAction(identifier: NotificationActionID.reply, title: "Deny with instructions",
                                                         options: [.authenticationRequired],
                                                         icon: UNNotificationActionIcon(systemImageName: "text.bubble"),
                                                         textInputButtonTitle: "Send",
                                                         textInputPlaceholder: "What should it do instead?")
        let categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: NotificationCategoryID.approval,
                                   actions: [approve, deny, denyWithText], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationCategoryID.input,
                                   actions: [reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationCategoryID.idle,
                                   actions: [reply, carryOn], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationCategoryID.info,
                                   actions: [], intentIdentifiers: []),
            // Approve/Deny on legacy pages are gated by kind in didReceive.
            UNNotificationCategory(identifier: NotificationCategoryID.legacy,
                                   actions: [approve, deny, reply], intentIdentifiers: [])
        ]
        center.setNotificationCategories(categories)
    }

    // MARK: Permission

    func refreshAuthorization() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized, .provisional, .ephemeral: authorization = .authorized
        @unknown default: authorization = .unknown
        }
    }

    /// Asks once (after pairing, when the user knows why), then registers for
    /// remote notifications whenever permission is granted. Registering on
    /// every activation is cheap and picks up rotated device tokens.
    func requestAuthorizationIfNeeded() async {
        await refreshAuthorization()
        if authorization == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            await refreshAuthorization()
        }
        if authorization == .authorized {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    // MARK: APNs device token

    func didRegister(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        if KeychainStore.get(Self.deviceTokenKey) != token {
            KeychainStore.set(token, for: Self.deviceTokenKey)
        }
        Task { await registerWithRelay() }
    }

    func didFailToRegister(error: Error) {
        let message = error.localizedDescription
        if message.contains("aps-environment") {
            push = .unavailable("This build isn't signed for push notifications, so pages only arrive while Page is open.")
        } else {
            push = .unavailable(message)
        }
    }

    /// Sends the device token to the paired relay. Called whenever iOS hands
    /// us a token and after every (re-)pairing, so whichever arrives last —
    /// token or pairing — completes the registration.
    func registerWithRelay(force: Bool = false) async {
        guard let device = deviceToken, let creds = RelayCredentials.current() else { return }
        if !force, let done = registeredPair, done.device == device, done.relay == creds.token { return }
        push = .registering
        let env = PushEnvironment.current(provisionData: Self.embeddedProvision(), isDebugBuild: Self.isDebugBuild)
        let delays: [UInt64] = [0, 2, 8]
        for delay in delays {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
            // Re-paired or unpaired while we waited.
            guard RelayCredentials.current() == creds else { return }
            if await APIClient.shared.registerDevice(apnsToken: device, environment: env) {
                registeredPair = (device, creds.token)
                push = .registered
                return
            }
        }
        push = .failed("Couldn't register this iPhone with your relay. Page will retry next time it opens.")
    }

    /// Called on unpair with the credentials captured before deletion.
    func unregister(using creds: RelayCredentials) async {
        registeredPair = nil
        push = .unknown
        guard let device = deviceToken else { return }
        await APIClient.shared.unregisterDevice(apnsToken: device, using: creds)
    }

    /// The relay retired this pairing: forget the registration without
    /// telling the relay, which refuses every call on that token now.
    func pairingRetired() {
        registeredPair = nil
        push = .unknown
    }

    func pairingChanged() {
        registeredPair = nil
        Task { await registerWithRelay(force: true) }
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func embeddedProvision() -> Data? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: Badge & delivered notifications

    func setBadge(_ count: Int) {
        center.setBadgeCount(max(0, count)) { _ in }
    }

    /// Removes delivered banners for these interventions (they were answered
    /// or closed elsewhere). Matches on our `interventionId` payload key, not
    /// the request identifier: older Workers don't set a collapse id.
    func removeDelivered(interventionIds: Set<String>) async {
        guard !interventionIds.isEmpty else { return }
        let delivered = await center.deliveredNotifications()
        let ids = delivered
            .filter { ($0.request.content.userInfo["interventionId"] as? String).map(interventionIds.contains) ?? false }
            .map(\.request.identifier)
        if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    /// After a successful inbox load: drop banners for pages that are no
    /// longer pending. Our own local failure notices are left alone.
    func removeDelivered(notIn pending: Set<String>) {
        Task {
            let delivered = await center.deliveredNotifications()
            let ids = delivered.filter { note in
                let info = note.request.content.userInfo
                guard info["pageLocal"] == nil, let id = info["interventionId"] as? String else { return false }
                return !pending.contains(id)
            }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func clearAll() {
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        setBadge(0)
    }

    /// A local notice when a reply sent from a banner didn't go through, so
    /// a lock-screen action never fails silently. Tapping it opens the page.
    private func postNotice(title: String, body: String, interventionId: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = NotificationCategoryID.info
        content.userInfo = ["interventionId": interventionId, "pageLocal": true]
        let request = UNNotificationRequest(identifier: "page-notice-\(interventionId)", content: content, trigger: nil)
        center.add(request) { _ in }
    }

    // MARK: Responses

    fileprivate func handleResponse(interventionId: String, kind: String?, project: String,
                                    response: NotificationResponseKind, userText: String?) async {
        switch NotificationDecision.decide(response, userText: userText, kind: kind) {
        case .open:
            AppRouter.shared.open(interventionId: interventionId)
        case .ignore:
            break
        case .refuse(let why):
            postNotice(title: "Nothing was sent", body: why, interventionId: interventionId)
        case .send(let text, let action):
            await sendFromNotification(interventionId: interventionId, project: project, text: text, action: action)
        }
    }

    private func sendFromNotification(interventionId: String, project: String, text: String, action: ReplyAction) async {
        // Keep the process alive until the POST finishes even if iOS would
        // otherwise suspend us right after the action.
        let app = UIApplication.shared
        let token = BackgroundTaskToken()
        token.id = app.beginBackgroundTask(withName: "page.reply") {
            token.end(app)
        }
        defer { token.end(app) }

        let outcome = await APIClient.shared.reply(to: interventionId, text: text, action: action)
        let where_ = project.isEmpty ? "your Mac" : project
        switch outcome {
        case .accepted, .alreadyReplied, .inFlight:
            // 409 is almost always a double tap or an in-app reply that got
            // there first: the page was answered (or an answer is on its
            // way), which is what the user wanted. If that earlier reply
            // fails, the relay sends its own "not delivered" push.
            break
        case .gone:
            postNotice(title: "Nothing was sent",
                       body: "That page in \(where_) was already resolved.",
                       interventionId: interventionId)
        case .unauthorized:
            postNotice(title: "Reply not sent",
                       body: "Your relay no longer accepts this pairing. Open Page to re-pair with your Mac.",
                       interventionId: interventionId)
        case .retired(let why):
            postNotice(title: "Reply not sent",
                       body: "\(TokenRetirement.sentence(why)) Open Page to pair again.",
                       interventionId: interventionId)
        case .failed(let message):
            postNotice(title: "Reply not sent",
                       body: "\(message) Tap to open the page and try again.",
                       interventionId: interventionId)
        }
    }
}

/// Holds a background task id so the expiration handler and the normal
/// completion path end it exactly once.
@MainActor
private final class BackgroundTaskToken {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end(_ app: UIApplication) {
        guard id != .invalid else { return }
        app.endBackgroundTask(id)
        id = .invalid
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
    -> UNNotificationPresentationOptions {
        // A new page can supersede older ones; the alert lists them.
        let closed = PushPayload.closedIds(from: notification.request.content.userInfo)
        if !closed.isEmpty { await APIClient.shared.handleClosedIdsFromAlert(closed) }
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let content = response.notification.request.content
        let closed = PushPayload.closedIds(from: content.userInfo)
        if !closed.isEmpty { await APIClient.shared.handleClosedIdsFromAlert(closed) }
        guard let interventionId = content.userInfo["interventionId"] as? String else { return }
        let kind = content.userInfo["kind"] as? String
        let project = PushPayload.projectName(userInfo: content.userInfo, title: content.title)
        let mapped: NotificationResponseKind
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: mapped = .open
        case UNNotificationDismissActionIdentifier: mapped = .dismiss
        default: mapped = .action(response.actionIdentifier)
        }
        let text = (response as? UNTextInputNotificationResponse)?.userText
        await handleResponse(interventionId: interventionId, kind: kind, project: project,
                             response: mapped, userText: text)
    }
}
