import Foundation

enum AgentBackendID: String, Codable, Equatable, Hashable {
    case claude
    case codex
}

enum AgentSessionSource: String, Codable, Equatable {
    case terminal
    case desktop
    case vscode
    case exec
    case remote
    case unknown
}

enum AgentSessionState: String, Codable, Equatable {
    case idle
    case active
    case waitingOnUser
    case waitingOnApproval
    case rateLimited
    case interrupted
    case failed
    case offline
}

struct AgentSession: Equatable {
    let backend: AgentBackendID
    let sessionId: String
    let cwd: String?
    let title: String?
    let source: AgentSessionSource
    let state: AgentSessionState
    let lastActivityAt: Date?
    let activeFlags: [String]
    let supportsRemoteReply: Bool
}

struct AgentBackendSnapshot: Equatable {
    let backendID: AgentBackendID
    let displayName: String
    let sessions: [AgentSession]
    let wantsPowerAssertion: Bool
    let pendingInterventions: [InterventionEvent]
    /// Most recent active rate-limit known to this backend, if any.
    /// Coordinator merges across backends to derive the global state.
    var currentRateLimit: RateLimitEvent? = nil
}

protocol AgentBackend: AnyObject {
    var id: AgentBackendID { get }
    var displayName: String { get }
    var currentSnapshot: AgentBackendSnapshot { get }

    func start()
    func refresh()
    func reloadConfig(_ config: Config)
    func shutdown()
}
