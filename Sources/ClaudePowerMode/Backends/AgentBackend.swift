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

/// A reply from the phone, as forwarded by the Worker. Fields beyond the v1
/// set (`kind`, `backend`, `source`) are only present from v2 Workers; see
/// CONTRACT notes in RelayClient.swift.
struct RelayReply: Codable, Equatable {
    let interventionId: String
    let text: String
    /// "approve" | "deny" | "carry_on" | "custom" | nil
    let action: String?
    let sessionId: String?
    let cwd: String?
    /// The stored intervention kind ("permission", "question", "idle", ...).
    let kind: String?
    /// "claude" | "codex". Older Workers omit it; route by id prefix then.
    let backend: String?
    let source: String?
    /// v2 Workers set this when they forward free text to a page that had
    /// already closed (answered at the Mac moments ago). Such text may only
    /// be typed as a plain message into an idle or busy session — never as
    /// a prompt answer, never with Esc. Absent from older Workers.
    var closed: Bool? = nil
    /// Why that page closed ("user_resolved_in_terminal", …); diagnostic.
    var closeReason: String? = nil
    /// tool_use id of the prompt the page was raised for, when its sender
    /// knew it (notification-hook pages). Lets a stale approve be told
    /// apart from a newer prompt. Absent from older Workers / hooks.
    var promptKey: String? = nil

    /// Backend that owns this reply: explicit field first, else the
    /// historical id-prefix convention (`codex-*` → Codex).
    var owningBackend: AgentBackendID {
        if let backend, let id = AgentBackendID(rawValue: backend) { return id }
        return interventionId.hasPrefix("codex-") ? .codex : .claude
    }
}

/// Outbound channel to the relay. There is exactly one shared connection,
/// owned by the Coordinator; backends never create their own RelayClient.
/// All methods are thread-safe and never block.
protocol RelaySink: AnyObject {
    var isConnected: Bool { get }
    func sendInterventionOpened(_ event: InterventionEvent)
    func sendInterventionClosed(id: String, reason: String)
    /// `detail` is short, human-readable and shown on the phone — never put
    /// secrets or raw command output in it. `output` is for the Worker log.
    func sendReplyInjected(interventionId: String, method: String, success: Bool, detail: String, output: String?)
}

protocol AgentBackend: AnyObject {
    var id: AgentBackendID { get }
    var displayName: String { get }
    var currentSnapshot: AgentBackendSnapshot { get }

    /// Set by the Coordinator before `start()`; may be replaced (or set to
    /// nil) at any time when the relay is reconfigured.
    var relay: RelaySink? { get set }
    var onNewIntervention: ((InterventionEvent) -> Void)? { get set }
    var onNewRateLimit: ((RateLimitEvent) -> Void)? { get set }

    func start()
    func refresh()
    func reloadConfig(_ config: Config)
    func shutdown()

    /// Deliver a phone reply this backend owns (see `RelayReply.owningBackend`).
    /// Called on a background queue; must report the outcome through
    /// `relay?.sendReplyInjected` and close the intervention on success.
    func handleReply(_ reply: RelayReply)

    /// Ids of interventions this backend currently considers open. The
    /// Coordinator sends these to the Worker in a `sync` frame on connect and
    /// periodically so ghost cards (Mac restarted, session died) get cleared.
    func openInterventionIds() -> [String]
}

/// A session Page interrupted because the battery hit the user's cutoff.
struct PausedSession: Equatable, Codable {
    let backend: AgentBackendID
    let sessionId: String
    let projectName: String
    let cwd: String
    let pausedAt: Date
    /// Short human description of how it was paused ("Interrupted in tmux
    /// pane %3", "Queued a pause message — Terminal.app can't press Esc").
    let detail: String
}

/// Low-battery pause. Orchestrated by the Coordinator (when the battery hits
/// `lowBatteryCutoff` on battery power); implemented per backend because only
/// the backend knows how to reach its sessions.
protocol BatteryPausable: AnyObject {
    /// Ask every *busy* session to stop at once and summarise where it got
    /// to. Sessions already waiting on the user (prompt on screen) or idle
    /// are left alone. Blocking; call off the main thread. Returns the
    /// sessions it actually paused.
    func pauseBusySessions(message: String) -> [PausedSession]
    /// After power returns: type `message` into each still-paused session
    /// that is idle and that the user hasn't touched since `pausedAt`.
    /// Blocking; call off the main thread. Returns ids it resumed.
    func resumePausedSessions(_ sessions: [PausedSession], message: String) -> [String]
}
