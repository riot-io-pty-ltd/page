import Foundation

final class Coordinator {
    struct Snapshot {
        let sessions: [AgentSession]
        let battery: Int
        let onAC: Bool
        let claudeRunning: Bool
        let claudeActive: Bool
        let secondsSinceTranscript: Double?
        let boosting: Bool
        let tripped: Bool
        let activeRateLimit: RateLimitEvent?
        let scheduledResumes: [ScheduledResume]
        let pendingInterventions: [InterventionEvent]
        let relayConnected: Bool

        var statusLine: String {
            if tripped { return "Low-battery lockout" }
            if !pendingInterventions.isEmpty {
                return "\(pendingInterventions.count) page(s) waiting"
            }
            if activeRateLimit != nil { return "Rate-limited — waiting for reset" }
            let activeCount = sessions.filter { $0.state == .active }.count
            if boosting {
                if activeCount > 0 { return "Boosting (\(activeCount) active)" }
                return "Boosting"
            }
            if claudeRunning && !claudeActive { return "Claude idle (no recent output)" }
            if claudeRunning { return "Claude running" }
            let codexCount = sessions.filter { $0.backend == .codex }.count
            if codexCount > 0 { return "Codex: \(codexCount) session\(codexCount == 1 ? "" : "s")" }
            return "Idle"
        }
    }

    var onStateChange: ((Snapshot) -> Void)?
    var onNewRateLimit: ((RateLimitEvent) -> Void)?
    var onNewIntervention: ((InterventionEvent) -> Void)?

    private(set) var config: Config = Config.load()
    private let power = PowerManager()
    private let claudeBackend = ClaudeBackend()
    private lazy var codexBackend: CodexBackend = CodexBackend(
        config: config,
        client: AppServerClient(codexPath: config.codexPath)
    )
    private lazy var backends: [AgentBackend] = [claudeBackend, codexBackend]
    private var timer: Timer?
    private var tripped = false
    private var latestBackendSnapshots: [AgentBackendID: AgentBackendSnapshot] = [:]
    /// All tick work runs on this serial queue so the main thread stays
    /// free for menu bar interaction. Each tick spawns pgrep + lsof and
    /// walks transcript trees — running that on the main run loop was
    /// making the menu bar item take 20-30 clicks to open.
    private let tickQueue = DispatchQueue(label: "ClaudePowerMode.coordinator.tick", qos: .utility)

    func start() {
        Logger.shared.log("ClaudePowerMode starting (cutoff=\(config.lowBatteryCutoff)% recovery=\(config.recoveryThreshold)% recoveryRequiresAC=\(config.recoveryRequiresAC) interval=\(config.checkIntervalSeconds)s)")
        claudeBackend.onNewRateLimit = { [weak self] event in
            self?.handleNewRateLimit(event)
        }
        claudeBackend.onNewIntervention = { [weak self] event in
            self?.handleNewIntervention(event)
        }
        codexBackend.onNewRateLimit = { [weak self] event in
            self?.handleNewRateLimit(event)
        }
        backends.forEach { $0.start() }
        scheduleTimer()
        tickQueue.async { [weak self] in self?.tick() }
    }

    func reloadConfig() {
        config = Config.load()
        Logger.shared.log("Config reloaded")
        backends.forEach { $0.reloadConfig(config) }
        scheduleTimer()
        tickQueue.async { [weak self] in self?.tick() }
    }

    func shutdown() {
        timer?.invalidate()
        backends.forEach { $0.shutdown() }
        power.setBoost(false, reason: "shutdown")
    }

    private func scheduleTimer() {
        timer?.invalidate()
        // Timer fires on the main run loop, but the actual work hops to
        // tickQueue so we never block UI events.
        timer = Timer.scheduledTimer(withTimeInterval: config.checkIntervalSeconds, repeats: true) { [weak self] _ in
            self?.tickQueue.async { self?.tick() }
        }
    }

    private func tick() {
        let p = power.snapshot()
        backends.forEach { backend in
            backend.refresh()
            logBackendSnapshotChange(for: backend)
        }
        let claudeState = claudeBackend.latestState

        if tripped {
            let recovered: Bool = {
                if config.recoveryRequiresAC {
                    return p.onAC && p.percent >= config.recoveryThreshold
                }
                return p.percent >= config.recoveryThreshold
            }()
            if recovered {
                tripped = false
                Logger.shared.log("Recovery: lockout cleared (battery=\(p.percent)% onAC=\(p.onAC))")
            }
        }

        if !tripped && p.percent < config.lowBatteryCutoff {
            tripped = true
            Logger.shared.log("Tripped: battery low at \(p.percent)% (cutoff=\(config.lowBatteryCutoff)%)")
        }

        let shouldBoost = !tripped && backends.contains { $0.currentSnapshot.wantsPowerAssertion }

        if shouldBoost != power.isBoosting {
            let reason: String
            if let rl = claudeState.activeRateLimit {
                reason = "Holding through rate-limit reset (\(rl.projectName), battery \(p.percent)%)"
            } else {
                reason = "Agent active (battery \(p.percent)%, \(p.onAC ? "AC" : "battery"))"
            }
            power.setBoost(shouldBoost, reason: reason)
        }

        // Merge active rate-limit across backends. If multiple backends are
        // limited at once (rare), pick the one that fires soonest — that's
        // the wall the user will hit first.
        let mergedRateLimit = backends.compactMap { $0.currentSnapshot.currentRateLimit }
            .min(by: { $0.resetTime < $1.resetTime })

        let snap = Snapshot(
            sessions: backends.flatMap { $0.currentSnapshot.sessions },
            battery: p.percent,
            onAC: p.onAC,
            claudeRunning: claudeState.claudeRunning,
            claudeActive: claudeState.claudeActive,
            secondsSinceTranscript: claudeState.secondsSinceTranscript,
            boosting: power.isBoosting,
            tripped: tripped,
            activeRateLimit: mergedRateLimit,
            scheduledResumes: claudeState.scheduledResumes,
            pendingInterventions: backends.flatMap { $0.currentSnapshot.pendingInterventions },
            relayConnected: claudeState.relayConnected
        )
        onStateChange?(snap)
    }

    private func handleNewRateLimit(_ event: RateLimitEvent) {
        onNewRateLimit?(event)
    }

    private func handleNewIntervention(_ event: InterventionEvent) {
        onNewIntervention?(event)
    }

    func scheduleResumeManually(for event: RateLimitEvent, prompt: String? = nil) throws -> ScheduledResume {
        try claudeBackend.scheduleResumeManually(for: event, prompt: prompt)
    }

    func cancelResume(_ scheduled: ScheduledResume) {
        claudeBackend.cancelResume(scheduled)
    }

    private func logBackendSnapshotChange(for backend: AgentBackend) {
        let snapshot = backend.currentSnapshot
        let previous = latestBackendSnapshots[backend.id]
        guard previous != snapshot else { return }
        latestBackendSnapshots[backend.id] = snapshot
        Logger.shared.log(
            "Backend snapshot updated: \(backend.displayName) sessions=\(snapshot.sessions.count) wantsPower=\(snapshot.wantsPowerAssertion) pendingInterventions=\(snapshot.pendingInterventions.count)"
        )
    }
}
