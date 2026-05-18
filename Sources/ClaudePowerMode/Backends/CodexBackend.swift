import Foundation

/// Codex backend (Phase 2 read-only + Phase 3 power-mode).
///
/// Responsibilities:
///   - Launch and own a `codex app-server` child process.
///   - Discover Codex threads via `thread/list` and subscribe via
///     `thread/read`, cross-referenced against live `codex` PIDs.
///   - Track per-thread state from `turn/started`, `turn/completed`,
///     and `thread/status/changed` notifications.
///   - Surface watched threads as `AgentSession`s and claim the
///     no-sleep assertion when any of them is active or waiting.
///
/// Still NOT in this phase:
///   - No reply path. Phase 5.
///   - No relay client — Codex pages don't reach the phone yet. Phase 4.
///   - No rate-limit handling. Phase 4 via the generic `RateLimitAware`
///     capability described in the spec.
final class CodexBackend: AgentBackend {

    let id: AgentBackendID = .codex
    let displayName = "Codex"

    /// Mirror of `ClaudeBackend`'s callback — Coordinator can wire this up
    /// to push Codex rate-limit events into the unified pipeline.
    var onNewRateLimit: ((RateLimitEvent) -> Void)?

    private(set) var config: Config
    private let client: AppServerClient

    private let stateLock = NSLock()
    private var threads: [String: AppServerProtocol.ThreadSummary] = [:]
    private var watchedThreadIDs: Set<String> = []
    private var threadStates: [String: AgentSessionState] = [:]
    private var threadFlags: [String: [String]] = [:]
    private var pendingInterventions: [String: InterventionEvent] = [:]   // interventionId → event
    private var interventionByServerRequest: [String: String] = [:]       // serverRequestId → interventionId
    private var currentRateLimit: RateLimitEvent?
    private var relayClient: RelayClient?
    private let idleDetector = CodexIdleDetector()
    private var lastSnapshot: AgentBackendSnapshot
    private var started = false
    private var initializing = false

    init(config: Config = Config.load(), client: AppServerClient = AppServerClient()) {
        self.config = config
        self.client = client
        self.lastSnapshot = AgentBackendSnapshot(
            backendID: .codex,
            displayName: "Codex",
            sessions: [],
            wantsPowerAssertion: false,
            pendingInterventions: [],
            currentRateLimit: nil
        )
    }

    var currentSnapshot: AgentBackendSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastSnapshot
    }

    func start() {
        guard config.codexBackendEnabled else {
            Logger.shared.log("CodexBackend disabled in config — skipping start")
            return
        }
        guard !started else { return }
        started = true
        Logger.shared.log("CodexBackend starting (codexPath=\(config.codexPath))")
        client.onNotification = { [weak self] method, params in
            self?.handleNotification(method: method, params: params)
        }
        client.onUnexpectedExit = { [weak self] in
            Logger.shared.log("CodexBackend: app-server exited unexpectedly — will retry on next refresh")
            self?.started = false
        }
        idleDetector.onNewEvent = { [weak self] event in
            self?.handleNewIdleIntervention(event)
        }
        idleDetector.onResolved = { [weak self] id in
            self?.handleResolvedIdleIntervention(id)
        }
        configureRelayClient()
        Task { await self.bringUp() }
    }

    private func configureRelayClient() {
        relayClient?.stop()
        relayClient = nil
        guard config.relayEnabled, let wsURL = RelayClient.wsURL(from: config.relayURL) else {
            return
        }
        let client = RelayClient(url: wsURL, token: PairingTokenManager.currentToken())
        client.onReply = { [weak self] reply in
            self?.handleRelayReply(reply)
        }
        client.start()
        relayClient = client
    }

    private func handleRelayReply(_ reply: RelayClient.RelayReply) {
        // Both ClaudeBackend and CodexBackend keep their own RelayClient
        // and the Worker broadcasts replies to every mac socket. Each
        // backend must claim only the ids it owns; otherwise Codex would
        // swallow Claude replies (and vice versa). Codex intervention ids
        // are always prefixed `codex-` (see CodexIdleDetector).
        guard reply.interventionId.hasPrefix("codex-") else { return }

        // Resolve the target cwd and threadId. Prefer the live intervention
        // (we stored both when we opened the page); fall back to whatever
        // the Worker echoed back in the reply payload.
        let (cwd, threadId): (String, String) = {
            if let pending = stateLock.withLock({ pendingInterventions[reply.interventionId] }) {
                return (pending.cwd, pending.sessionId)
            }
            return (reply.cwd ?? "", reply.sessionId ?? "")
        }()
        let projectName = cwd.isEmpty ? "codex" : InterventionDetector.projectName(forCwd: cwd)
        let text = reply.text.isEmpty ? mapActionToPhrase(reply.action) : reply.text

        Logger.shared.log("CodexBackend: reply for \(reply.interventionId) — project=\(projectName) thread=\(threadId.prefix(8)) text=\(text.prefix(60))")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = InjectionExecutor.injectCodex(text: text, cwd: cwd, threadId: threadId)
            Logger.shared.log("CodexBackend.injection method=\(result.method.rawValue) success=\(result.success) for \(projectName)")
            self?.relayClient?.sendReplyInjected(
                interventionId: reply.interventionId,
                method: result.method.rawValue,
                success: result.success,
                output: result.output
            )
            // Close the intervention on the Worker so the iOS inbox clears.
            // Without this the page sticks around until something else
            // resolves it. Closing on success only — on failure the user
            // can retry from the phone.
            if result.success {
                self?.relayClient?.sendInterventionClosed(id: reply.interventionId, reason: "replied")
                self?.stateLock.withLock {
                    self?.pendingInterventions[reply.interventionId] = nil
                    self?.rebuildSnapshot()
                }
            }
        }
    }

    private func mapActionToPhrase(_ action: String?) -> String {
        switch action {
        case "approve": return "yes, proceed"
        case "deny":    return "no, stop"
        case "carry_on": return "carry on"
        default:        return "carry on"
        }
    }

    func refresh() {
        guard config.codexBackendEnabled else { return }
        // If the child died and we cleared `started`, try again. The
        // bringUp() path is idempotent against a still-running client.
        if !started {
            started = true
            Task { await self.bringUp() }
            return
        }
        Task {
            await self.reconcileWatchedThreads()
            self.scanIdle()
        }
    }

    private func scanIdle() {
        let watched: [CodexIdleDetector.WatchedThread] = stateLock.withLock {
            watchedThreadIDs.compactMap { id -> CodexIdleDetector.WatchedThread? in
                guard let t = threads[id], let path = t.path, !path.isEmpty,
                      let cwd = t.cwd, !cwd.isEmpty else { return nil }
                return CodexIdleDetector.WatchedThread(
                    threadId: id,
                    rolloutPath: path,
                    cwd: cwd,
                    source: mapSource(t.source)
                )
            }
        }
        idleDetector.scan(threads: watched)
    }

    private func handleNewIdleIntervention(_ event: InterventionEvent) {
        stateLock.withLock {
            pendingInterventions[event.id] = event
            rebuildSnapshot()
        }
        relayClient?.sendInterventionOpened(event)
    }

    private func handleResolvedIdleIntervention(_ id: String) {
        stateLock.withLock {
            pendingInterventions[id] = nil
            rebuildSnapshot()
        }
        relayClient?.sendInterventionClosed(id: id, reason: "session_resolved")
    }

    func reloadConfig(_ config: Config) {
        let wasEnabled = self.config.codexBackendEnabled
        let wasRelayEnabled = self.config.relayEnabled
        let wasRelayURL = self.config.relayURL
        self.config = config
        if wasEnabled && !config.codexBackendEnabled {
            Logger.shared.log("CodexBackend disabled via config — shutting down child")
            shutdown()
        } else if !wasEnabled && config.codexBackendEnabled {
            Logger.shared.log("CodexBackend enabled via config — starting up")
            start()
        } else if started, (config.relayEnabled != wasRelayEnabled || config.relayURL != wasRelayURL) {
            Logger.shared.log("CodexBackend: relay config changed — reconfiguring relay client")
            configureRelayClient()
        }
    }

    func shutdown() {
        client.shutdown()
        relayClient?.stop()
        relayClient = nil
        started = false
        stateLock.lock()
        threads.removeAll()
        watchedThreadIDs.removeAll()
        threadStates.removeAll()
        threadFlags.removeAll()
        pendingInterventions.removeAll()
        interventionByServerRequest.removeAll()
        currentRateLimit = nil
        lastSnapshot = AgentBackendSnapshot(
            backendID: .codex,
            displayName: displayName,
            sessions: [],
            wantsPowerAssertion: false,
            pendingInterventions: [],
            currentRateLimit: nil
        )
        stateLock.unlock()
    }

    // MARK: Bring-up

    private func bringUp() async {
        guard !initializing else { return }
        initializing = true
        defer { initializing = false }

        do {
            _ = try await client.start(clientName: "ClaudePowerMode", clientVersion: "0.1")
        } catch {
            Logger.shared.log("CodexBackend: handshake failed — \(error). Will retry on next refresh.")
            started = false
            return
        }

        do {
            let account: AppServerProtocol.AccountReadResult = try await client.call(
                method: "account/read",
                params: AppServerProtocol.AccountReadParams(refreshToken: false)
            )
            if let acc = account.account {
                Logger.shared.log("CodexBackend: account=\(acc.email ?? "?") plan=\(acc.planType ?? "?")")
            }
        } catch {
            Logger.shared.log("CodexBackend: account/read failed — \(error)")
        }

        await reconcileWatchedThreads()
    }

    // MARK: Thread reconciliation

    private func reconcileWatchedThreads() async {
        guard client.isRunning else { return }

        let listResult: AppServerProtocol.ThreadListResult
        do {
            listResult = try await client.call(
                method: "thread/list",
                params: AppServerProtocol.ThreadListParams(limit: 50)
            )
        } catch {
            Logger.shared.log("CodexBackend: thread/list failed — \(error)")
            return
        }

        let liveCwds = CodexProcessMonitor.liveCodexCwds()
        // Threads we've already paged the user about — keep watching them
        // regardless of staleness so the page stays visible on the phone
        // until the user acts on it. Without this, Codex Desktop pages
        // disappear ~5 min after they open because Desktop's app-server
        // process has cwd=/ (no per-project cwd to match liveCwds) and
        // the rollout's updatedAt naturally goes stale while waiting on
        // the user. The 4h ceiling in CodexIdleDetector still auto-resolves
        // truly abandoned ones.
        let stickyThreadIds: Set<String> = stateLock.withLock {
            Set(pendingInterventions.values.map(\.sessionId))
        }
        let watched = listResult.data.filter { thread in
            guard let cwd = thread.cwd else { return false }
            if stickyThreadIds.contains(thread.id) { return true }
            // Cwd match: the user has a running `codex` CLI in this dir.
            if liveCwds.contains(cwd) { return true }
            // Recency fallback: 30 min covers Codex Desktop / VS Code
            // sessions where the app-server's own cwd is `/` and isn't a
            // useful liveness signal. Original 5 min was too aggressive —
            // pages dropped before the user had time to react.
            if let updated = thread.updatedAt {
                let ageSeconds = Double(Int(Date().timeIntervalSince1970) - updated)
                if ageSeconds < 1800 { return true }
            }
            return false
        }

        let previousWatched = stateLock.withLock { watchedThreadIDs }
        let liveSet = liveCwds
        let newWatched = Set(watched.map(\.id))
        let added = newWatched.subtracting(previousWatched)
        let removed = previousWatched.subtracting(newWatched)

        if !added.isEmpty {
            Logger.shared.log("CodexBackend: now watching \(added.count) thread(s): \(added.map { String($0.prefix(8)) }.joined(separator: ", "))")
        }
        if !removed.isEmpty {
            Logger.shared.log("CodexBackend: dropped \(removed.count) thread(s): \(removed.map { String($0.prefix(8)) }.joined(separator: ", "))")
        }

        // Subscribe to newly-watched threads so we start receiving
        // notifications about them. `notLoaded` -> attached transition
        // happens server-side once we call `thread/read`.
        for id in added {
            do {
                let _: AppServerProtocol.JSON = try await client.call(
                    method: "thread/read",
                    params: AppServerProtocol.ThreadReadParams(threadId: id)
                )
            } catch {
                Logger.shared.log("CodexBackend: thread/read failed for \(id.prefix(8)) — \(error)")
            }
        }

        stateLock.withLock {
            threads = Dictionary(uniqueKeysWithValues: listResult.data.map { ($0.id, $0) })
            watchedThreadIDs = newWatched
            // Drop state for threads we no longer watch.
            for id in removed {
                threadStates[id] = nil
                threadFlags[id] = nil
            }
        }
        // Clean up idle interventions for threads we no longer watch.
        idleDetector.dropThreads(notIn: newWatched)
        stateLock.withLock {
            // Seed newly-watched threads. If their cwd has a live codex
            // process, default to .active (notifications will refine it).
            // Otherwise the thread was promoted by the "recent updatedAt"
            // fallback — default to .idle.
            for id in added {
                guard let t = threads[id] else { continue }
                let hasLive = t.cwd.map(liveSet.contains) ?? false
                threadStates[id] = hasLive ? .active : .idle
            }
            rebuildSnapshot()
        }
    }

    // MARK: Notifications

    private func handleNotification(method: String, params: AppServerProtocol.JSON) {
        switch method {
        case "thread/status/changed":
            let id = params["threadId"].stringValue ?? params["id"].stringValue
            let flags = params["activeFlags"].arrayValue?.compactMap(\.stringValue) ?? []
            Logger.shared.log("Codex thread/status/changed id=\(id?.prefix(8) ?? "?") flags=\(flags.joined(separator: ","))")
            if let id = id, stateLock.withLock({ watchedThreadIDs.contains(id) }) {
                updateThreadState(id: id, from: flags)
            }
        case "turn/started":
            let id = params["threadId"].stringValue
            Logger.shared.log("Codex turn/started thread=\(id?.prefix(8) ?? "?")")
            if let id = id { setState(id: id, to: .active) }
        case "turn/completed":
            let id = params["threadId"].stringValue
            Logger.shared.log("Codex turn/completed thread=\(id?.prefix(8) ?? "?")")
            if let id = id {
                // If a waiting flag is currently set, leave it — the server
                // sometimes emits turn/completed before the matching
                // thread/status/changed. Otherwise go idle.
                let currentFlags = stateLock.withLock { threadFlags[id] ?? [] }
                let stillWaiting = currentFlags.contains(where: isWaitingFlag)
                if !stillWaiting { setState(id: id, to: .idle) }
            }
        case "account/rateLimits/updated":
            handleRateLimitUpdate(params: params)
        case "item/commandExecution/requestApproval":
            openApprovalIntervention(params: params, kind: .permission, subtype: "command")
        case "item/fileChange/requestApproval":
            openApprovalIntervention(params: params, kind: .permission, subtype: "fileChange")
        case "tool/requestUserInput":
            openApprovalIntervention(params: params, kind: .question, subtype: nil)
        case "serverRequest/resolved":
            closeInterventionForServerRequest(params: params)
        default:
            // Useful for spec amendments — capture unknown methods so we
            // can decide whether to type them.
            Logger.shared.log("Codex notification (unhandled): \(method)")
        }
    }

    // MARK: Approval / input → InterventionEvent

    /// Build an InterventionEvent from a server-side approval or user-input
    /// request. We pluck whatever context the protocol gives us (command,
    /// file path, prompt text, reason) using the permissive JSON tree —
    /// any missing field just gets a sensible default. The server request
    /// id is captured so we can close the matching page when the server
    /// reports resolution.
    private func openApprovalIntervention(params: AppServerProtocol.JSON, kind: InterventionKind, subtype: String?) {
        let serverRequestId = params["requestId"].stringValue
            ?? params["id"].stringValue
            ?? UUID().uuidString
        let threadId = params["threadId"].stringValue
        let cwd: String = {
            if let tid = threadId, let t = stateLock.withLock({ threads[tid] }), let c = t.cwd { return c }
            return params["cwd"].stringValue ?? ""
        }()
        let projectName: String = {
            if cwd.isEmpty { return "Codex" }
            return InterventionDetector.projectName(forCwd: cwd)
        }()
        let context = buildContextSnippet(params: params, kind: kind)
        let sessionId = threadId ?? "codex"
        let source: AgentSessionSource = {
            if let tid = threadId, let t = stateLock.withLock({ threads[tid] }) {
                return mapSource(t.source)
            }
            return .unknown
        }()

        let event = InterventionEvent(
            id: "codex-\(serverRequestId)",
            sessionId: sessionId,
            cwd: cwd,
            projectName: projectName,
            kind: kind,
            openedAt: Date(),
            context: context,
            transcriptPath: "",
            backend: .codex,
            source: source,
            subtype: subtype
        )

        stateLock.withLock {
            pendingInterventions[event.id] = event
            interventionByServerRequest[serverRequestId] = event.id
            // If a turn is associated with this thread, mark it as waiting.
            if let tid = threadId, watchedThreadIDs.contains(tid) {
                threadStates[tid] = (kind == .permission) ? .waitingOnApproval : .waitingOnUser
            }
            rebuildSnapshot()
        }

        Logger.shared.log("CodexBackend: OPENED \(kind.rawValue) in \(projectName) (req=\(serverRequestId.prefix(8)))")
        relayClient?.sendInterventionOpened(event)
    }

    private func buildContextSnippet(params: AppServerProtocol.JSON, kind: InterventionKind) -> String {
        // Try a few likely shapes from the protocol docs. Order matters:
        // most-specific to most-generic.
        if let cmd = params["command"].stringValue { return "$ \(cmd)" }
        if let cmd = params["item"]["command"].stringValue { return "$ \(cmd)" }
        if let file = params["filePath"].stringValue {
            let reason = params["reason"].stringValue
            return reason.map { "Edit \(file) — \($0)" } ?? "Edit \(file)"
        }
        if let file = params["item"]["filePath"].stringValue {
            let reason = params["reason"].stringValue ?? params["item"]["reason"].stringValue
            return reason.map { "Edit \(file) — \($0)" } ?? "Edit \(file)"
        }
        if let prompt = params["prompt"].stringValue { return prompt }
        if let reason = params["reason"].stringValue { return reason }
        if let title = params["title"].stringValue { return title }
        return kind == .permission ? "Codex is asking for approval" : "Codex is asking for input"
    }

    private func closeInterventionForServerRequest(params: AppServerProtocol.JSON) {
        let requestId = params["requestId"].stringValue ?? params["id"].stringValue
        guard let rid = requestId else { return }
        let interventionId: String? = stateLock.withLock {
            let iid = interventionByServerRequest.removeValue(forKey: rid)
            if let iid {
                pendingInterventions[iid] = nil
                rebuildSnapshot()
            }
            return iid
        }
        guard let iid = interventionId else { return }
        Logger.shared.log("CodexBackend: serverRequest/resolved \(rid.prefix(8)) → closing intervention \(iid.prefix(20))")
        relayClient?.sendInterventionClosed(id: iid, reason: "session_resolved")
    }

    // MARK: Rate limit

    /// `account/rateLimits/updated` is emitted every time the server has
    /// new usage data, not only when you hit the wall. We only treat it
    /// as a `RateLimitEvent` when usage is at 100% — anything else is
    /// just usage telemetry we don't need to act on.
    private func handleRateLimitUpdate(params: AppServerProtocol.JSON) {
        let limitId = params["limitId"].stringValue ?? "default"
        let usedPercent: Double = {
            switch params["usedPercent"] {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: return 0
            }
        }()
        let resetsAtUnix = params["resetsAt"].intValue
        Logger.shared.log("Codex account/rateLimits/updated limit=\(limitId) used=\(usedPercent)% resetsAt=\(resetsAtUnix ?? -1)")

        guard usedPercent >= 100, let resetsAt = resetsAtUnix else { return }

        // Attribute the rate limit to whichever thread we currently watch is
        // freshest. ChatGPT account limits don't belong to a single thread,
        // but the UI needs *some* project name to render a useful page.
        let (sessionId, cwd, projectName) = stateLock.withLock {
            () -> (String, String, String) in
            let candidate = watchedThreadIDs
                .compactMap { threads[$0] }
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
                .first
            let sid = candidate?.id ?? "codex"
            let cwd = candidate?.cwd ?? ""
            let proj = cwd.isEmpty ? "Codex" : InterventionDetector.projectName(forCwd: cwd)
            return (sid, cwd, proj)
        }

        let resetDate = Date(timeIntervalSince1970: TimeInterval(resetsAt))
        let resetTimeText = Self.formatResetText(resetDate)
        let event = RateLimitEvent(
            sessionId: sessionId,
            cwd: cwd,
            projectName: projectName,
            eventTime: Date(),
            resetTime: resetDate,
            resetTimeText: resetTimeText,
            transcriptPath: ""
        )

        stateLock.withLock {
            currentRateLimit = event
            rebuildSnapshot()
        }

        Logger.shared.log("Codex rate-limit detected: limit=\(limitId) project=\(projectName) resetAt=\(resetDate)")
        onNewRateLimit?(event)
    }

    private static func formatResetText(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = .none
        df.timeStyle = .short
        return "resets \(df.string(from: d))"
    }

    private func updateThreadState(id: String, from flags: [String]) {
        let waiting = flags.first(where: isWaitingFlag)
        let newState: AgentSessionState
        switch waiting {
        case "waitingOnApproval":
            newState = .waitingOnApproval
        case "waitingOnUser":
            newState = .waitingOnUser
        case .some:
            newState = .waitingOnUser  // unknown waiting flag — treat as waiting on user
        case nil:
            // No waiting flags. If a turn is in flight we'd have seen
            // turn/started; default to idle until proven otherwise.
            newState = .idle
        }
        stateLock.withLock {
            threadFlags[id] = flags
            threadStates[id] = newState
            rebuildSnapshot()
        }
    }

    private func setState(id: String, to state: AgentSessionState) {
        stateLock.withLock {
            guard watchedThreadIDs.contains(id) else { return }
            threadStates[id] = state
            rebuildSnapshot()
        }
    }

    private func isWaitingFlag(_ f: String) -> Bool {
        f.hasPrefix("waitingOn")
    }

    // MARK: Snapshot building

    /// Caller must hold `stateLock`.
    private func rebuildSnapshot() {
        let sessions: [AgentSession] = watchedThreadIDs.compactMap { id in
            guard let t = threads[id] else { return nil }
            let source = mapSource(t.source)
            let lastActivity = t.updatedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let state = threadStates[id] ?? .idle
            return AgentSession(
                backend: .codex,
                sessionId: t.id,
                cwd: t.cwd,
                title: t.displayTitle,
                source: source,
                state: state,
                lastActivityAt: lastActivity,
                activeFlags: threadFlags[id] ?? [],
                supportsRemoteReply: false  // Phase 5.
            )
        }.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }

        // Hold the no-sleep assertion if any watched session is mid-turn
        // or waiting for human input, OR we have pending interventions on
        // the phone (someone needs to act, don't sleep on them).
        let wantsPowerFromSessions = sessions.contains { session in
            switch session.state {
            case .active, .waitingOnUser, .waitingOnApproval: return true
            case .idle, .rateLimited, .interrupted, .failed, .offline: return false
            }
        }
        let wantsPower = wantsPowerFromSessions || !pendingInterventions.isEmpty

        lastSnapshot = AgentBackendSnapshot(
            backendID: .codex,
            displayName: displayName,
            sessions: sessions,
            wantsPowerAssertion: wantsPower,
            pendingInterventions: Array(pendingInterventions.values),
            currentRateLimit: currentRateLimit
        )
    }

    private func mapSource(_ raw: String?) -> AgentSessionSource {
        switch raw?.lowercased() {
        case "cli": return .terminal
        case "vscode": return .vscode
        case "desktop", "appserver": return .desktop
        case "exec": return .exec
        case "remote": return .remote
        default: return .unknown
        }
    }
}

private extension NSLock {
    func withLock<R>(_ body: () -> R) -> R {
        lock()
        defer { unlock() }
        return body()
    }
}

/// Tails Codex rollout JSONL files for the watched threads to detect
/// "task complete, no follow-up" → the same idle / waiting-on-user state
/// the Claude path detects from transcripts.
///
/// Why this exists despite Phase 4 already wiring app-server notifications:
/// our `codex app-server` child is isolated from sibling `codex` CLI /
/// desktop processes — they each run their own embedded backend, so we
/// only see `turn/*` events for threads our app-server actually drives.
/// The rollout JSONL files, by contrast, are written by whichever process
/// owns the session and are observable by anyone with read access.
///
/// The Codex format is more explicit than Claude's: every line is
/// `{timestamp, type, payload}` and the unambiguous "I'm done, waiting on
/// you" marker is `event_msg` with `payload.type == "task_complete"` as
/// the latest event in the file.
final class CodexIdleDetector {
    var onNewEvent: ((InterventionEvent) -> Void)?
    var onResolved: ((String) -> Void)?

    private(set) var currentlyPending: [String: InterventionEvent] = [:]
    private let queue = DispatchQueue(label: "ClaudePowerMode.CodexIdleDetector")
    private let idleThresholdSeconds: TimeInterval = 90
    private let settleSeconds: TimeInterval = 8
    /// Don't keep paging the user about idle sessions they've clearly
    /// abandoned. If the rollout hasn't moved in this long, the page
    /// auto-resolves rather than being re-emitted every Mac restart.
    private let maxIdleAgeSeconds: TimeInterval = 4 * 3600
    /// (path → (mtime, last-eval)). Skips re-reading a rollout when
    /// its mtime is unchanged and we're past the settle threshold.
    private var evalCache: [String: (mtime: Date, event: InterventionEvent?)] = [:]

    struct WatchedThread {
        let threadId: String
        let rolloutPath: String
        let cwd: String
        let source: AgentSessionSource
    }

    func scan(threads: [WatchedThread]) {
        var nowEvents: [InterventionEvent] = []
        for t in threads {
            if let ev = checkForIdle(t) {
                nowEvents.append(ev)
            }
        }

        queue.sync {
            let nowIds = Set(nowEvents.map(\.id))
            let previousIds = Set(currentlyPending.keys)

            for e in nowEvents where currentlyPending[e.id] == nil {
                currentlyPending[e.id] = e
                onNewEvent?(e)
                Logger.shared.log("CodexBackend: OPENED idle in \(e.projectName) (thread \(e.sessionId.prefix(8)))")
            }

            for id in previousIds.subtracting(nowIds) {
                if let e = currentlyPending.removeValue(forKey: id) {
                    onResolved?(id)
                    Logger.shared.log("CodexBackend: RESOLVED idle in \(e.projectName)")
                }
            }
        }
    }

    /// Remove pending interventions for threads we no longer watch — and
    /// notify so the phone inbox can be cleaned up.
    func dropThreads(notIn keep: Set<String>) {
        let toRemove = queue.sync { () -> [InterventionEvent] in
            let stale = currentlyPending.values.filter { !keep.contains($0.sessionId) }
            for s in stale { currentlyPending[s.id] = nil }
            return Array(stale)
        }
        for e in toRemove {
            onResolved?(e.id)
            Logger.shared.log("CodexBackend: RESOLVED idle in \(e.projectName) (thread dropped)")
        }
    }

    private func checkForIdle(_ t: WatchedThread) -> InterventionEvent? {
        guard !t.rolloutPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: t.rolloutPath)
        guard let vals = try? url.resourceValues(forKeys: [
            .contentModificationDateKey, .isRegularFileKey
        ]),
              vals.isRegularFile == true,
              let mtime = vals.contentModificationDate else { return nil }

        let age = Date().timeIntervalSince(mtime)
        if age < settleSeconds { return nil }
        if age < idleThresholdSeconds { return nil }
        // Auto-resolve very old idle states. Without this, every Mac
        // restart re-emits historic "Codex is idle" pages from yesterday's
        // sessions because the IdleDetector's in-memory state is wiped and
        // the rollout file still matches the idle pattern.
        if age > maxIdleAgeSeconds { return nil }

        // mtime cache — if nothing's changed since last evaluation and
        // we're past the idle threshold, the answer can't change. Skip
        // the file read.
        if let cached = evalCache[t.rolloutPath], cached.mtime == mtime {
            return cached.event
        }

        // Tail-read: only the last 16 KB. The detector only walks
        // suffix(30) lines anyway.
        let text = Self.readTail(of: url, maxBytes: 16_384) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            evalCache[t.rolloutPath] = (mtime, nil)
            return nil
        }

        // Walk the tail; track the index of the latest `task_complete` and
        // the latest "meaningful" item (any response_item). Idle iff a
        // task_complete exists and no response_item appears after it.
        var taskCompleteIdx: Int?
        var lastMeaningfulIdx: Int?
        var lastAssistantText = ""

        for (i, line) in lines.suffix(30).enumerated() {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            let payload = obj["payload"] as? [String: Any] ?? [:]

            if type == "event_msg" {
                let pType = payload["type"] as? String
                if pType == "task_complete" {
                    taskCompleteIdx = i
                    if let lam = payload["last_agent_message"] as? String, !lam.isEmpty {
                        lastAssistantText = String(lam.prefix(280))
                    }
                }
            } else if type == "response_item" {
                lastMeaningfulIdx = i
                if let role = payload["role"] as? String, role == "assistant",
                   let content = payload["content"] as? [[String: Any]] {
                    for item in content {
                        if let txt = item["text"] as? String, !txt.isEmpty {
                            lastAssistantText = String(txt.prefix(280))
                        }
                    }
                }
            }
        }

        guard let tc = taskCompleteIdx else {
            evalCache[t.rolloutPath] = (mtime, nil)
            return nil
        }
        if let lm = lastMeaningfulIdx, lm > tc {
            evalCache[t.rolloutPath] = (mtime, nil)
            return nil
        }

        let project = InterventionDetector.projectName(forCwd: t.cwd)
        // ID derived from mtime so each fresh idle window gets a new id
        // (resolves cleanly when the user replies → new turn → new mtime).
        let id = "codex-idle-\(t.threadId.prefix(8))-\(Int(mtime.timeIntervalSince1970))"
        let evt = InterventionEvent(
            id: id,
            sessionId: t.threadId,
            cwd: t.cwd,
            projectName: project,
            kind: .idle,
            openedAt: mtime,
            context: lastAssistantText.isEmpty ? "Codex finished a turn — waiting for input" : lastAssistantText,
            transcriptPath: t.rolloutPath,
            backend: .codex,
            source: t.source
        )
        evalCache[t.rolloutPath] = (mtime, evt)
        return evt
    }

    /// Last `maxBytes` of a file. Drops the first partial line when we
    /// seek into the middle so the caller can split-by-newline safely.
    private static func readTail(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let seekedFromStart = size <= UInt64(maxBytes)
        let offset = seekedFromStart ? 0 : size - UInt64(maxBytes)
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else { return nil }
        if !seekedFromStart, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text
    }
}

/// Live-`codex` filter — analog of `liveClaudeSessionIds` from the Claude
/// path. For Codex we only need the cwds, since `thread/list` already
/// knows the thread→cwd mapping.
enum CodexProcessMonitor {
    static func liveCodexCwds() -> Set<String> {
        let pids = pgrepCodex()
        var cwds: Set<String> = []
        for pid in pids {
            if let cwd = lsofCwd(pid: pid) {
                cwds.insert(cwd)
            }
        }
        return cwds
    }

    private static func pgrepCodex() -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-fl", "codex"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do { try task.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        let myPid = ProcessInfo.processInfo.processIdentifier

        var pids: [Int32] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let pidStr = parts.first, let pid = Int32(pidStr), pid != myPid else { continue }
            let cmd = parts.count > 1 ? String(parts[1]) : ""
            // Only count processes whose actual executable basename is
            // `codex` — same logic as the Claude filter.
            let cmdParts = cmd.split(separator: " ", omittingEmptySubsequences: true)
            guard let exe = cmdParts.first else { continue }
            let exeBasename = (String(exe) as NSString).lastPathComponent
            guard exeBasename == "codex" else { continue }
            // Skip our own app-server child (we don't want to watch its cwd
            // as if it were a user-launched session).
            if cmd.contains("app-server") { continue }
            pids.append(pid)
        }
        return pids
    }

    private static func lsofCwd(pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-d", "cwd", "-p", String(pid), "-Fn"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do { try task.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        // `lsof -Fn` prints `n<path>` lines. The cwd line starts with "n/".
        for line in output.split(separator: "\n") {
            if line.hasPrefix("n/") {
                return String(line.dropFirst())
            }
        }
        return nil
    }
}
