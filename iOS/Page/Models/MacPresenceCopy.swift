import Foundation

extension MacPresence {
    /// One-line status, e.g. "Online · heartbeat 12s ago".
    func summary(now: Date) -> String {
        switch self {
        case .unknown:
            return "Checking…"
        case .online(let seen):
            guard let seen else { return "Online" }
            return "Online · heartbeat \(RelativeTime.ago(since: seen, now: now))"
        case .stale(let seen):
            return "Not responding · last heartbeat \(RelativeTime.ago(since: seen, now: now))"
        case .offline(let seen):
            guard let seen else { return "Offline" }
            return "Offline · last seen \(RelativeTime.ago(since: seen, now: now))"
        case .neverConnected:
            return "Never connected with this pairing"
        }
    }
}
