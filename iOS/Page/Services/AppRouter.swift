import Foundation

/// App-wide navigation state, so a notification tap or a `page://` link can
/// open a specific intervention whether the app was running, suspended or
/// cold-launched. On a cold launch the notification delegate fires before
/// any view exists; the request simply sits in `presented` until
/// MainTabView appears and presents it.
///
/// A page's reply screen and a session's detail screen are both sheets on
/// MainTabView, and only one sheet can be up at a time. Opening one while
/// the other is showing dismisses it first and presents the new one from
/// `sheetDismissed()`.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    struct PresentedIntervention: Identifiable, Equatable {
        let id: String
    }

    struct PresentedSession: Identifiable, Equatable {
        let id: String
    }

    @Published var tab: AppTab = .sessions
    @Published var presented: PresentedIntervention?
    @Published var presentedSession: PresentedSession?

    private var pendingIntervention: String?
    private var pendingSession: String?

    private init() {}

    /// Opens a page's reply screen. `switchTab: false` keeps the current
    /// tab (the Sessions list's "Open page").
    func open(interventionId: String, switchTab: Bool = true) {
        if switchTab { tab = .inbox }
        if presentedSession != nil {
            pendingIntervention = interventionId
            pendingSession = nil
            presentedSession = nil
            return
        }
        presented = PresentedIntervention(id: interventionId)
    }

    /// Opens a live session's detail screen (the reply screen's "Open
    /// session", or a tap in the Sessions list).
    func openSession(_ sessionId: String) {
        tab = .sessions
        if presented != nil {
            pendingSession = sessionId
            pendingIntervention = nil
            presented = nil
            return
        }
        presentedSession = PresentedSession(id: sessionId)
    }

    /// Either sheet finished dismissing: present whatever was waiting.
    func sheetDismissed() {
        if let id = pendingIntervention {
            pendingIntervention = nil
            presented = PresentedIntervention(id: id)
        } else if let id = pendingSession {
            pendingSession = nil
            presentedSession = PresentedSession(id: id)
        }
    }

    /// Handles `page://intervention/<id>`. Returns false for anything else.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let id = DeepLink.interventionId(from: url) else { return false }
        open(interventionId: id)
        return true
    }

    func reset() {
        tab = .sessions
        presented = nil
        presentedSession = nil
        pendingIntervention = nil
        pendingSession = nil
    }
}
