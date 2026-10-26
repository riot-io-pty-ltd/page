import SwiftUI

// Small translations from the live services to the pure values the Night
// Watch screens draw.

extension NotificationService.Authorization {
    var nw: NotificationsState {
        switch self {
        case .authorized: return .allowed
        case .denied: return .off
        case .notDetermined: return .notSet
        case .unknown: return .checking
        }
    }
}

extension NotificationService {
    /// The push registration, as the Tower words it.
    var nwPush: PushStatus {
        switch push {
        case .registered: return .registered
        case .registering: return .registering
        case .failed(let why), .unavailable(let why): return .problem(why)
        case .unknown: return authorization == .authorized ? .waitingForApple : .needsNotifications
        }
    }
}

extension APIClient.LoadState {
    /// For `NowInputs`: "All quiet" is only true after a successful load.
    var nowState: NowInputs.InboxState {
        switch self {
        case .loaded: return .loaded
        case .failed: return .failed
        case .idle, .loading: return .loading
        }
    }
}

/// The name every preview and chip uses for the active Mac.
@MainActor
func nwMacName(sessions: SessionStore, pairing: PairingStore) -> String {
    sessions.macName ?? pairing.pairedMac?.name ?? "Your Mac"
}
