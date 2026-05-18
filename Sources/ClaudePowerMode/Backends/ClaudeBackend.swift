import Foundation

final class ClaudeBackend: AgentBackend {
    struct State: Equatable {
        let sessions: [AgentSession]
        let claudeRunning: Bool
        let claudeActive: Bool
        let secondsSinceTranscript: Double?
        let activeRateLimit: RateLimitEvent?
        let scheduledResumes: [ScheduledResume]
        let pendingInterventions: [InterventionEvent]
        let relayConnected: Bool
        let wantsPowerAssertion: Bool

        static let empty = State(
            sessions: [],
            claudeRunning: false,
            claudeActive: false,
            secondsSinceTranscript: nil,
            activeRateLimit: nil,
            scheduledResumes: [],
            pendingInterventions: [],
            relayConnected: false,
            wantsPowerAssertion: false
        )
    }

    let id: AgentBackendID = .claude
    let displayName = "Claude"

    var onNewRateLimit: ((RateLimitEvent) -> Void)?
    var onNewIntervention: ((InterventionEvent) -> Void)?

    var currentSnapshot: AgentBackendSnapshot {
        AgentBackendSnapshot(
            backendID: id,
            displayName: displayName,
            sessions: latestState.sessions,
            wantsPowerAssertion: latestState.wantsPowerAssertion,
            pendingInterventions: latestState.pendingInterventions,
            currentRateLimit: latestState.activeRateLimit
        )
    }

    private(set) var config: Config
    private(set) var latestState: State = .empty

    private let rateWatcher = RateLimitWatcher()
    private let scheduler = ResumeScheduler()
    private let interventionDetector = InterventionDetector()
    private var relayClient: RelayClient?
    private var latestRateLimit: RateLimitEvent?

    init(config: Config = Config.load()) {
        self.config = config
    }

    func start() {
        Logger.shared.log("ClaudeBackend starting (transcripts=\(config.transcriptDirectory), processPattern=\(config.claudeProcessPattern))")
        scheduler.purgeStale()
        if config.rateLimitWatcherEnabled {
            rateWatcher.primeWithExistingEvents(transcriptDirectory: config.transcriptDirectory)
            rateWatcher.onNewEvent = { [weak self] event in
                self?.handleNewRateLimit(event)
            }
        } else {
            rateWatcher.onNewEvent = nil
        }
        if config.interventionDetectionEnabled {
            interventionDetector.onNewEvent = { [weak self] event in
                self?.handleNewIntervention(event)
            }
            interventionDetector.onResolved = { [weak self] id in
                self?.handleResolvedIntervention(id: id)
            }
        } else {
            interventionDetector.onNewEvent = nil
            interventionDetector.onResolved = nil
        }
        configureRelayClient()
    }

    func refresh() {
        let claudeCount = ProcessMonitor.countClaudeRunning(
            pattern: config.claudeProcessPattern,
            exclude: config.excludePatterns
        )
        let claude = claudeCount > 0
        let secondsSince = ActivityMonitor.secondsSinceLastTranscriptWrite(directory: config.transcriptDirectory)
        let claudeActive: Bool
        if !claude {
            claudeActive = false
        } else if !config.requireRecentTranscriptActivity {
            claudeActive = true
        } else if let s = secondsSince {
            claudeActive = s <= config.transcriptActivityWindowSeconds
        } else {
            claudeActive = true
        }

        if config.rateLimitWatcherEnabled {
            _ = rateWatcher.scan(transcriptDirectory: config.transcriptDirectory)
            refreshLatestRateLimit()
        } else {
            latestRateLimit = nil
        }

        if config.interventionDetectionEnabled {
            interventionDetector.scan(transcriptDirectory: config.transcriptDirectory)
        }

        let inActiveRateLimit = latestRateLimit != nil
        let holdForReset = config.holdAssertionUntilReset && inActiveRateLimit
        let pendingInterventions = config.interventionDetectionEnabled
            ? Array(interventionDetector.currentlyPending.values)
            : []
        let hasPendingIntervention = !pendingInterventions.isEmpty
        let wantsPowerAssertion = claudeActive || holdForReset || hasPendingIntervention
        let sessions = makeSessions(
            claudeRunning: claude,
            claudeActive: claudeActive,
            secondsSinceTranscript: secondsSince,
            activeRateLimit: latestRateLimit,
            pendingInterventions: pendingInterventions
        )

        latestState = State(
            sessions: sessions,
            claudeRunning: claude,
            claudeActive: claudeActive,
            secondsSinceTranscript: secondsSince,
            activeRateLimit: latestRateLimit,
            scheduledResumes: scheduler.listScheduled(),
            pendingInterventions: pendingInterventions,
            relayConnected: relayClient?.isConnected ?? false,
            wantsPowerAssertion: wantsPowerAssertion
        )

        // Send a heartbeat so the iOS app sees how many Claude sessions are
        // currently alive. Throttled to avoid flooding when refresh() runs fast.
        sendHeartbeatIfNeeded(activeSessions: claudeCount)
    }

    private var lastHeartbeatAt: Date = .distantPast
    private let heartbeatInterval: TimeInterval = 15

    private func sendHeartbeatIfNeeded(activeSessions: Int) {
        guard let relay = relayClient, relay.isConnected else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHeartbeatAt) >= heartbeatInterval else { return }
        lastHeartbeatAt = now
        relay.sendHeartbeat(activeSessions: activeSessions, battery: 0)
    }

    func reloadConfig(_ config: Config) {
        self.config = config
        Logger.shared.log("ClaudeBackend config reloaded")
    }

    func shutdown() {
        relayClient?.stop()
    }

    @discardableResult
    func scheduleResumeManually(for event: RateLimitEvent, prompt: String? = nil) throws -> ScheduledResume {
        try scheduler.schedule(
            event: event,
            prompt: prompt ?? config.carryOnPrompt,
            wakeViaPmset: config.wakeViaPmsetEnabled
        )
    }

    func cancelResume(_ scheduled: ScheduledResume) {
        scheduler.cancel(scheduled)
    }

    private func makeSessions(
        claudeRunning: Bool,
        claudeActive: Bool,
        secondsSinceTranscript: Double?,
        activeRateLimit: RateLimitEvent?,
        pendingInterventions: [InterventionEvent]
    ) -> [AgentSession] {
        let lastActivityAt = secondsSinceTranscript.map { Date().addingTimeInterval(-$0) }

        let baseState: AgentSessionState? = {
            if !pendingInterventions.isEmpty {
                return .waitingOnUser
            }
            if activeRateLimit != nil {
                return .rateLimited
            }
            if claudeActive {
                return .active
            }
            if claudeRunning {
                return .idle
            }
            return nil
        }()

        guard let state = baseState else { return [] }

        let activeFlags: [String] = {
            var flags: [String] = []
            if activeRateLimit != nil { flags.append("rateLimited") }
            if !pendingInterventions.isEmpty { flags.append("waitingOnUser") }
            if claudeActive { flags.append("recentTranscriptActivity") }
            return flags
        }()

        return [
            AgentSession(
                backend: id,
                sessionId: "claude-cli",
                cwd: nil,
                title: "Claude CLI",
                source: .terminal,
                state: state,
                lastActivityAt: lastActivityAt,
                activeFlags: activeFlags,
                supportsRemoteReply: true
            )
        ]
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

    private func handleNewIntervention(_ event: InterventionEvent) {
        onNewIntervention?(event)
        relayClient?.sendInterventionOpened(event)
    }

    private func handleResolvedIntervention(id: String) {
        relayClient?.sendInterventionClosed(id: id, reason: "user_resolved_in_terminal")
    }

    private func handleRelayReply(_ reply: RelayClient.RelayReply) {
        // CodexBackend's RelayClient also receives broadcast replies — let
        // it handle codex-prefixed ids and ignore them here so we don't
        // try to inject a Codex reply through a Claude TTY.
        if reply.interventionId.hasPrefix("codex-") { return }

        // Resolve sessionId/cwd from three sources in order of preference:
        //   1. The InterventionDetector's currentlyPending map (matches our
        //      own idle-detection events).
        //   2. A session-id match in currentlyPending (different intervention,
        //      same session — still a valid target).
        //   3. The reply payload itself — the Worker echoes back sessionId
        //      and cwd from the stored intervention. This is how hook-
        //      generated interventions (created by the bash hook script
        //      posting directly to the Worker, never tracked locally) still
        //      get their replies routed.
        let sessionId: String
        let cwd: String
        let projectName: String

        if let pending = interventionDetector.currentlyPending[reply.interventionId] {
            sessionId = pending.sessionId
            cwd = pending.cwd
            projectName = pending.projectName
        } else if let sidMatch = interventionDetector.currentlyPending.values
            .first(where: { $0.sessionId == reply.sessionId }) {
            sessionId = sidMatch.sessionId
            cwd = sidMatch.cwd
            projectName = sidMatch.projectName
        } else if let sid = reply.sessionId, let c = reply.cwd, !sid.isEmpty, !c.isEmpty {
            sessionId = sid
            cwd = c
            projectName = URL(fileURLWithPath: c).lastPathComponent
            Logger.shared.log("Reply for non-tracked intervention \(reply.interventionId) — using payload (session \(sid.prefix(8)), \(projectName))")
        } else {
            Logger.shared.log("Reply received for unknown intervention \(reply.interventionId) — no sessionId/cwd in payload either")
            return
        }

        let text = reply.text.isEmpty ? mapActionToPhrase(reply.action) : reply.text
        DispatchQueue.global(qos: .userInitiated).async {
            let result = InjectionExecutor.inject(
                text: text,
                sessionId: sessionId,
                cwd: cwd,
                action: reply.action
            )
            Logger.shared.log("Injection \(result.method.rawValue) success=\(result.success) for \(projectName)")
            self.relayClient?.sendReplyInjected(
                interventionId: reply.interventionId,
                method: result.method.rawValue,
                success: result.success,
                output: result.output
            )
            // Tell the Worker the page is resolved so the iOS inbox clears.
            // The Worker's /reply endpoint only marks repliedAt; it doesn't
            // close the intervention. Without this the card sticks around
            // on the phone forever. Close on success only — failure leaves
            // it open so the user can retry from the phone.
            if result.success {
                self.relayClient?.sendInterventionClosed(id: reply.interventionId, reason: "replied")
            }
        }
    }

    private func mapActionToPhrase(_ action: String?) -> String {
        switch action {
        case "approve": return "yes, proceed"
        case "deny": return "no, stop"
        case "carry_on": return "carry on"
        default: return "carry on"
        }
    }

    private func refreshLatestRateLimit() {
        let events = TranscriptParser.findRateLimitEvents(
            directory: config.transcriptDirectory,
            lookbackHours: 6
        )
        let now = Date()
        latestRateLimit = events
            .filter { $0.resetTime > now }
            .sorted { $0.eventTime > $1.eventTime }
            .first
    }

    private func handleNewRateLimit(_ event: RateLimitEvent) {
        Logger.shared.log("Rate-limit detected: session=\(event.sessionId.prefix(8)) project=\(event.projectName) resetAt=\(event.resetTime) text=\"\(event.resetTimeText)\"")
        onNewRateLimit?(event)
        if config.autoResumeEnabled {
            do {
                try scheduler.schedule(
                    event: event,
                    prompt: config.carryOnPrompt,
                    wakeViaPmset: config.wakeViaPmsetEnabled
                )
            } catch {
                Logger.shared.log("Failed to schedule resume: \(error)")
            }
        }
    }
}
