import Foundation

/// App-wide navigation state, so a notification tap or a `page://` link can
/// open a specific intervention whether the app was running, suspended or
/// cold-launched. On a cold launch the notification delegate fires before
/// any view exists; the request simply sits in `presented` until
/// MainTabView appears and presents it.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    struct PresentedIntervention: Identifiable, Equatable {
        let id: String
    }

    @Published var tab: AppTab = .inbox
    @Published var presented: PresentedIntervention?

    private init() {}

    func open(interventionId: String) {
        tab = .inbox
        presented = PresentedIntervention(id: interventionId)
    }

    /// Handles `page://intervention/<id>`. Returns false for anything else.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let id = DeepLink.interventionId(from: url) else { return false }
        open(interventionId: id)
        return true
    }

    func reset() {
        tab = .inbox
        presented = nil
    }
}
