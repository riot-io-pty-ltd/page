import Foundation

final class Coordinator {
    enum RelayState: Equatable {
        /// `relayEnabled` is false.
        case off
        /// Enabled, but the URL is missing / the placeholder / invalid.
        case misconfigured(String)
        case connecting
        case connected
    }

    /// Per-agent summary for the menu.
    struct BackendInfo: Equatable {
        let id: AgentBackendID
        let displayName: String
        let enabled: Bool
        let sessionCount: Int
        let activeCount: Int
        let waitingCount: Int
        /// Why this agent can't be watched, if Page can tell (e.g. no codex binary).
        var problem: String? = nil
    }

    /// Low-battery pause state for the menu.
    struct BatteryStatus: Equatable {
        let phase: BatteryPolicy.Phase
        let paused: [PausedSession]
        let graceEndsAt: Date?
        let mode: LowBatteryAction?

        static let normal = BatteryStatus(phase: .normal, paused: [], graceEndsAt: nil, mode: nil)
    }

    /// A Mac banner about the battery pause (posted by AppDelegate).
    struct BatteryNotice: Equatable {
        let title: String
        let body: String
    }

    struct Snapshot {
        let sessions: [AgentSession]
        let power: PowerSnapshot
        /// Assertions actually held this tick.
        let awake: AwakeAssertions
        /// Page has `pmset disablesleep 1` in force (lid closed on battery).
        let lidClosedOnBattery: Bool
        /// Why lid-closed-on-battery isn't active while the option is on and
        /// agents are working on battery (nil otherwise).
        let lidClosedOnBatteryBlocker: String?
        /// Clearing `pmset disablesleep` keeps failing: the Mac may not sleep
        /// with the lid closed (the menu shows the manual fix).
        var lidClosedCleanupFailed: Bool = false
        let battery: BatteryStatus
        let activeRateLimit: RateLimitEvent?
        let scheduledResumes: [ScheduledResume]
        let pendingInterventions: [InterventionEvent]
        let relayState: RelayState
        let backends: [BackendInfo]
        /// Shown at the top of the menu when config.json is broken or had
        /// values that were corrected.
        let configProblem: String?

        var relayConnected: Bool { relayState == .connected }
        var boosting: Bool { awake.preventIdleSleep }
        var tripped: Bool { battery.phase != .normal }

        var statusLine: String {
            switch battery.phase {
            case .grace: return "Low battery — agents are pausing"
            case .drained:
                if !battery.paused.isEmpty {
                    let n = battery.paused.count
                    return "Low battery — \(n) session\(n == 1 ? "" : "s") paused"
                }
                return "Low battery — not keeping awake"
            case .normal: break
            }
            if !pendingInterventions.isEmpty {
                let n = pendingInterventions.count
                return "\(n) page\(n == 1 ? "" : "s") waiting"
            }
            if activeRateLimit != nil { return "Rate-limited — waiting for reset" }
            let activeCount = sessions.filter { $0.state == .active }.count
            if boosting {
                if activeCount > 0 { return "Keeping awake (\(activeCount) active)" }
                return "Keeping awake"
            }
            if sessions.isEmpty { return "Idle" }
            let n = sessions.count
            return "\(n) session\(n == 1 ? "" : "s"), none active"
        }
    }

    /// A rate-limit event plus what Page actually did about it, so the
    /// notification never claims a resume that wasn't scheduled.
    struct RateLimitNotice {
        let event: RateLimitEvent
        /// A resume Page has scheduled for this session's reset, if any.
        let scheduledResume: ScheduledResume?
        /// Whether "Auto-resume" can be offered: only Claude sessions with a
        /// real session id and project directory can be resumed.
        let canResume: Bool
    }

    enum ResumeError: LocalizedError {
        case unsupportedBackend(AgentBackendID)
        case missingSession

        var errorDescription: String? {
            switch self {
            case .unsupportedBackend(let b):
                return "\(b == .codex ? "Codex" : b.rawValue) sessions can’t be auto-resumed yet"
            case .missingSession:
                return "This rate limit has no session or project directory to resume"
            }
        }
    }

    /// Called on the tick queue; hop to main for UI.
    var onStateChange: ((Snapshot) -> Void)?
    var onNewRateLimit: ((RateLimitNotice) -> Void)?
    var onNewIntervention: ((InterventionEvent) -> Void)?
    var onResumeResult: ((ResumeResult) -> Void)?
    var onBatteryNotice: ((BatteryNotice) -> Void)?

    // MARK: config (UI-facing copy)

    // `tickConfig` (below) is what the tick queue uses; this is a copy for
    // the main thread, published under a lock. Both are replaced together in
    // reloadConfig, so the UI never reads a value the backends haven't been
    // given — and the tick queue never reads a struct main is mutating
    // (Config holds Strings and Arrays; an unsynchronised copy is a real
    // use-after-free risk, not just a stale read).
    private let configLock = NSLock()
    private var publishedConfig: Config
    private var publishedConfigProblem: String?

    /// Thread-safe snapshot of the current config.
    var config: Config {
        configLock.lock(); defer { configLock.unlock() }
        return publishedConfig
    }

    /// Non-nil while config.json is unreadable (the last good config, or
    /// defaults, is in use) or had values corrected.
    var configProblem: String? {
        configLock.lock(); defer { configLock.unlock() }
        return publishedConfigProblem
    }

    // MARK: tick-queue state

    /// All tick work — backend refresh, power decisions, relay lifecycle,
    /// config changes — runs on this serial queue so the main thread stays
    /// free for menu bar interaction (each tick spawns pgrep + lsof and
    /// walks transcript trees; on the main run loop that made the menu bar
    /// item take 20-30 clicks to open), and so backend start/reload/shutdown
    /// can never race a refresh.
    private let tickQueue = DispatchQueue(label: "ClaudePowerMode.coordinator.tick", qos: .utility)

    private var tickConfig: Config
    private let power = PowerManager()
    /// Lid-closed-on-battery (pmset disablesleep). Has its own lock and is
    /// safe to call from a signal handler without touching `tickQueue`.
    private let sleepGuard = SleepGuard()
    /// Low-battery pause state machine (tick queue only), persisted after
    /// every change so a crash or the Mac sleeping never loses it.
    private var battery = BatteryPolicy()
    private var savedBattery = BatteryPolicy()
    private let batteryStore = BatteryPauseStore()
    /// Pausing and resuming type into terminals and can block for seconds;
    /// never on `tickQueue` (shutdown waits on it).
    private let batteryQueue = DispatchQueue(label: "ClaudePowerMode.battery", qos: .userInitiated)
    /// A battery resume (automatic or from the menu) is typing into
    /// sessions on `batteryQueue` (tick queue only). Keeps a held automatic
    /// resume and the menu from both typing "carry on" into a session.
    private var batteryResumeInFlight = false
    /// Last per-backend snapshots seen by a tick, for re-evaluating power
    /// without a full refresh (after a pause finishes).
    private var lastSnapshots: [AgentBackendSnapshot] = []
    private let claudeBackend: ClaudeBackend
    private let codexBackend: CodexBackend
    /// Immutable after init, so the relay queue may read it to route replies.
    private let backends: [AgentBackend]
    /// One serial queue per backend: replies to the same agent stay in
    /// arrival order, and a slow Claude delivery can't hold up Codex.
    private let replyQueues: [AgentBackendID: DispatchQueue]

    private var relay: RelayClient?
    private var relayIdentity: RelayIdentity?
    /// A regenerated-away token to retire on the Worker before the relay
    /// switches to the new one (tick queue only).
    private var tokenToRetire: String?
    /// The old client while its `relay.retire` goes out (≤ ~2 s). Relay
    /// reconfiguration waits for it; its completion does the switch.
    private var retiringRelay: RelayClient?
    private var tickTimer: DispatchSourceTimer?
    private var housekeepingTimer: DispatchSourceTimer?
    private var lastPower = PowerSnapshot.noBattery
    /// Debounces transient "no battery" readings (tick queue only).
    private var powerFilter = PowerReadingFilter()
    private var lidBlocker: String?
    /// When the last full tick (backend refresh) ran, so housekeeping can
    /// refresh stale snapshots while lid-closed-on-battery depends on them.
    private var lastTickAt: Date = .distantPast
    private var lastWatchdogSyncAt: Date = .distantPast
    /// The last relay channel pages were sent on (never cleared when the
    /// relay is turned off), so a new token or Worker URL re-sends them.
    private var lastRelayIdentity: RelayIdentity?
    /// Pages the phone answered recently (tick queue only). Not re-sent on a
    /// new relay channel: a fresh Worker inbox would accept a second answer.
    private var recentlyRepliedIds: [String: Date] = [:]
    private var loggedSummaries: [AgentBackendID: BackendSummary] = [:]
    private var notifiedRateLimitKeys: Set<String> = []
    /// `sync` waits for the first completed tick: before it, backends report
    /// no open interventions and the Worker would close every card — then
    /// re-open (and re-buzz) them a tick later.
    private var hasTicked = false
    private var lastSyncAt: Date = .distantPast
    private var lastHeartbeatAt: Date = .distantPast
    private var isShutDown = false
    /// Set (from any thread) the moment Page starts quitting — SIGTERM/SIGINT
    /// or `shutdown()` — before the tick queue is drained, so no tick in
    /// between re-takes assertions or touches the sleep flag.
    private let terminatingLock = NSLock()
    private var _terminating = false
    private var isTerminating: Bool {
        terminatingLock.lock(); defer { terminatingLock.unlock() }
        return _terminating
    }
    private var tokenObserver: NSObjectProtocol?

    static let heartbeatInterval: TimeInterval = 15
    static let syncInterval: TimeInterval = 60
    /// While lid-closed-on-battery is on, the backend snapshots it depends on
    /// are refreshed at least this often, whatever `checkIntervalSeconds` is.
    static let lidClosedMaxSnapshotAge: TimeInterval = 60
    static let watchdogRetryInterval: TimeInterval = 60
    static let recentReplyMemory: TimeInterval = 30 * 60

    struct RelayIdentity: Equatable {
        let url: URL
        let token: String
    }

    /// What the "snapshot changed" log line compares. Comparing the whole
    /// snapshot logged on every tick (lastActivityAt drifts by microseconds),
    /// which was 80% of a 12 MB log.
    private struct BackendSummary: Equatable {
        let sessionStates: [String]
        let wantsPower: Bool
        let pendingIds: Set<String>
        let rateLimitId: String?
    }

    init() {
        let loaded = Config.loadResult()
        let cfg = loaded.config ?? Config()
        publishedConfig = cfg
        publishedConfigProblem = loaded.problem
        tickConfig = cfg
        claudeBackend = ClaudeBackend(config: cfg)
        codexBackend = CodexBackend(config: cfg)
        backends = [claudeBackend, codexBackend]
        var queues: [AgentBackendID: DispatchQueue] = [:]
        for b in backends {
            queues[b.id] = DispatchQueue(label: "ClaudePowerMode.reply.\(b.id.rawValue)", qos: .userInitiated)
        }
        replyQueues = queues
    }

    // MARK: lifecycle

    func start() {
        tokenObserver = NotificationCenter.default.addObserver(
            forName: PairingTokenManager.tokenDidChange, object: nil, queue: nil
        ) { [weak self] note in
            let previous = note.userInfo?[PairingTokenManager.previousTokenKey] as? String
            self?.reconnectRelay(retiring: previous)
        }
        tickQueue.async { [weak self] in
            guard let self else { return }
            let cfg = self.tickConfig
            Logger.shared.log("Page starting (cutoff=\(cfg.lowBatteryCutoff)% recovery=\(cfg.recoveryThreshold)% recoveryRequiresAC=\(cfg.recoveryRequiresAC) interval=\(cfg.checkIntervalSeconds)s relay=\(cfg.relayEnabled ? (cfg.relayBaseURL?.host ?? "misconfigured") : "off") codex=\(cfg.codexBackendEnabled))")
            for backend in self.backends {
                backend.onNewIntervention = { [weak self] event in
                    self?.onNewIntervention?(event)
                }
                backend.onNewRateLimit = { [weak self] event in
                    self?.handleNewRateLimit(event)
                }
            }
            self.claudeBackend.onResumeResult = { [weak self] result in
                self?.onResumeResult?(result)
            }
            self.restorePowerStateAfterLaunch(cfg)
            // Relay first, so backends have their sink before they start.
            self.configureRelay(force: false)
            // A regenerate the last run couldn't confirm (offline, crash).
            self.retryPendingRetirements()
            self.backends.forEach { $0.start() }
            self.scheduleTimers()
            self.tick()
        }
    }

    /// Re-reads config.json and applies it. Safe from any thread; the UI
    /// copy is updated before this returns, the backends shortly after on
    /// the tick queue. A malformed file keeps the last good config running
    /// (a typo made while the app is up must not turn paging off) and
    /// surfaces the problem in the menu.
    func reloadConfig() {
        let loaded = Config.loadResult()
        configLock.lock()
        if let cfg = loaded.config { publishedConfig = cfg }
        publishedConfigProblem = loaded.problem
        configLock.unlock()
        if loaded.config == nil {
            Logger.shared.log("Config reload failed — keeping the previous settings")
        }
        tickQueue.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            if let cfg = loaded.config { self.apply(cfg) }
            self.tick()
        }
    }

    /// Drops the relay connection and reconnects with the current URL and
    /// pairing token. Called automatically when the token is regenerated;
    /// `retiring` is then the replaced token, which is retired on the Worker
    /// (`relay.retire` on its socket, or POST) before the switch, so phones
    /// still paired with it are told to re-pair.
    func reconnectRelay(retiring oldToken: String? = nil) {
        tickQueue.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            if let oldToken {
                self.tokenToRetire = oldToken
                // Durable record first: the immediate retire below can fail
                // silently (offline, half-dead socket); the housekeeping
                // pass retries until the Worker confirms.
                if let url = self.relayIdentity?.url ?? self.desiredRelayWSURL() {
                    PendingRetirements.add(token: oldToken, wsURL: url)
                }
            }
            self.configureRelay(force: true)
            self.publishSnapshot()
        }
    }

    /// Pure: whether switching from `current` to `desired` must first retire
    /// `current`'s token. Only for the token a regenerate replaced, only on
    /// the same Worker, and never when the "new" token is that same token
    /// (a failed token write leaves the old one in use).
    static func shouldRetire(current: RelayIdentity?, desired: RelayIdentity?, tokenToRetire: String?) -> Bool {
        guard let current, let retire = tokenToRetire, current.token == retire else { return false }
        guard let desired else { return false }
        return desired.token != retire && desired.url == current.url
    }

    /// Reconnects the existing relay socket now, keeping anything queued
    /// (used after wake from sleep, when the old socket is silently dead).
    func nudgeRelay() {
        tickQueue.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.relay?.reconnectNow()
            self.tick()
        }
    }

    func shutdown() {
        if let tokenObserver { NotificationCenter.default.removeObserver(tokenObserver) }
        tokenObserver = nil
        // Clear and seal the sleep flag first, without waiting behind an
        // in-flight tick (SleepGuard and PowerManager have their own locks).
        releaseSleepOverrides(reason: "Page quitting")
        // Synchronous so the assertion is released and the app-server child
        // is gone before the process exits. Nothing on the tick queue ever
        // waits on main, so this can't deadlock.
        tickQueue.sync {
            guard !isShutDown else { return }
            isShutDown = true
            tickTimer?.cancel()
            tickTimer = nil
            housekeepingTimer?.cancel()
            housekeepingTimer = nil
            relay?.stop()
            relay = nil
            backends.forEach { $0.relay = nil }
            backends.forEach { $0.shutdown() }
            // Second pass: the sealed guard can't have re-enabled, but a
            // clear that failed above gets one more try.
            power.releaseAll()
            sleepGuard.forceDisable(reason: "Page quitting")
            persistBattery()
        }
    }

    /// Quit / SIGTERM / SIGINT: clears `disablesleep` and seals the guard so
    /// nothing can set it again, stops ticks from acting, and drops the
    /// assertions — all without going through `tickQueue` (which may be
    /// busy). Safe from any thread, idempotent; the normal `shutdown()` may
    /// follow.
    func releaseSleepOverrides(reason: String) {
        terminatingLock.lock()
        _terminating = true
        terminatingLock.unlock()
        sleepGuard.sealAndDisable(reason: reason)
        power.releaseAll()
    }

    /// Whether the sudo rule for lid-closed-on-battery is installed. Runs
    /// `sudo -n -l` off the main thread; `completion` on main.
    func checkPowerHelper(refresh: Bool, completion: @escaping (SleepGuard.HelperStatus) -> Void) {
        let guardRef = sleepGuard
        DispatchQueue.global(qos: .userInitiated).async {
            let status = guardRef.helperStatus(refresh: refresh)
            DispatchQueue.main.async { completion(status) }
        }
    }

    // MARK: config application (tick queue)

    private func apply(_ cfg: Config) {
        let old = tickConfig
        tickConfig = cfg
        guard cfg != old else { return }
        Logger.shared.log("Config reloaded")
        backends.forEach { $0.reloadConfig(cfg) }
        if cfg.keepAwakeLidClosedOnBattery != old.keepAwakeLidClosedOnBattery {
            Logger.shared.log("Lid closed on battery: \(cfg.keepAwakeLidClosedOnBattery ? "enabled" : "disabled")")
            if cfg.keepAwakeLidClosedOnBattery {
                // The user may just have run install.sh; don't trust a stale "missing".
                _ = sleepGuard.helperStatus(refresh: true)
            } else {
                sleepGuard.update(shouldDisableSleep: false, reason: "option turned off")
            }
            lastWatchdogSyncAt = Date()
            sleepGuard.syncWatchdog(enabled: cfg.keepAwakeLidClosedOnBattery)
        }
        if cfg.checkIntervalSeconds != old.checkIntervalSeconds { scheduleTimers() }
        configureRelay(force: false)
    }

    // MARK: relay (tick queue)

    /// Creates, replaces or removes the shared RelayClient so it matches the
    /// config and the current pairing token. A no-op when nothing relevant
    /// changed, unless `force`.
    /// The relay's WebSocket URL per the current config, or nil when the
    /// relay is off or misconfigured.
    private func desiredRelayWSURL() -> URL? {
        guard tickConfig.relayEnabled, let base = tickConfig.relayBaseURL else { return nil }
        return RelayClient.wsURL(fromBase: base)
    }

    /// Retries confirming retirement of replaced pairing tokens (see
    /// PendingRetirements). Cheap when there's nothing pending: one small
    /// file read.
    private func retryPendingRetirements() {
        let due = PendingRetirements.claimDue(currentToken: PairingTokenManager.currentToken())
        for entry in due {
            RelayClient.postRetire(wsURL: entry.wsURL, token: entry.token, reason: "token_regenerated") { ok in
                if ok {
                    PendingRetirements.remove(token: entry.token)
                    Logger.shared.log("Replaced pairing token retired on the relay (attempt \(entry.attempts + 1))")
                }
            }
        }
    }

    private func configureRelay(force: Bool) {
        // The old client is sending relay.retire; its completion switches
        // to whatever the identity is by then.
        if retiringRelay != nil { return }
        let desired: RelayIdentity? = {
            guard tickConfig.relayEnabled,
                  let base = tickConfig.relayBaseURL,
                  let ws = RelayClient.wsURL(fromBase: base) else { return nil }
            return RelayIdentity(url: ws, token: PairingTokenManager.currentToken())
        }()
        if !force && desired == relayIdentity { return }
        if let old = relay, Self.shouldRetire(current: relayIdentity, desired: desired, tokenToRetire: tokenToRetire) {
            tokenToRetire = nil
            retiringRelay = old
            Logger.shared.log("Retiring the replaced pairing token on the relay before switching")
            old.retire(reason: "token_regenerated") { [weak self] sent in
                guard let self else { return }
                self.tickQueue.async {
                    self.retiringRelay = nil
                    if !sent { Logger.shared.log("The relay didn't confirm retiring the old pairing token — phones paired with it may not be told to re-pair") }
                    guard !self.isShutDown else { return }
                    self.configureRelay(force: true)
                    self.publishSnapshot()
                }
            }
            return
        }
        // Not retiring now (relay off, Worker URL changed, or the token
        // didn't actually change): forget it rather than retire later.
        tokenToRetire = nil
        // A different token is a different Worker inbox (one Durable Object
        // per token), and a different URL may be a different Worker: pages
        // already sent on the old channel never reach the new phone unless
        // they're sent again.
        let channelChanged = desired != nil && lastRelayIdentity != nil && desired != lastRelayIdentity

        if let old = relay {
            old.stop()
            relay = nil
            relayIdentity = nil
        }
        guard let desired else {
            backends.forEach { $0.relay = nil }
            if tickConfig.relayEnabled, let problem = tickConfig.relayURLProblem {
                Logger.shared.log("Relay enabled but not usable: \(problem.message)")
            }
            return
        }
        let client = RelayClient(url: desired.url, token: desired.token)
        client.onReply = { [weak self] reply in
            self?.route(reply)
        }
        // Weak: the client owns these closures; a strong capture would keep
        // every replaced client alive forever.
        client.onConnect = { [weak self, weak client] in
            guard let self, let client else { return }
            self.tickQueue.async { self.relayDidConnect(client) }
        }
        client.onConnectionChange = { [weak self] _ in
            self?.tickQueue.async { self?.publishSnapshot() }
        }
        relay = client
        relayIdentity = desired
        lastRelayIdentity = desired
        backends.forEach { $0.relay = client }
        if channelChanged { resendOpenPages(on: client) }
        client.start()
    }

    /// Re-sends the pages that are still open to a new relay channel. The
    /// client queues them until it connects. Backends keep treating them as
    /// sent (their bookkeeping is theirs), which is right: they are open on
    /// the new channel now.
    private func resendOpenPages(on client: RelayClient) {
        let now = Date()
        recentlyRepliedIds = recentlyRepliedIds.filter { now.timeIntervalSince($0.value) < Self.recentReplyMemory }
        let cfg = tickConfig
        let userAtMac = cfg.idlePageOnlyWhenAwaySeconds > 0
            && UserPresence.isActive(within: cfg.idlePageOnlyWhenAwaySeconds)
        let pages = Self.pagesToResend(
            backends.filter { isEnabled($0.id) }.map { $0.currentSnapshot },
            excludedIds: Set(recentlyRepliedIds.keys),
            pausedSessionKeys: Set(battery.entries.map(\.key)),
            hookHeldSessionIds: HookHoldMarkers.heldSessions(in: HookHoldMarkers.defaultDirectory),
            userAtMac: userAtMac)
        for page in pages { client.sendInterventionOpened(page) }
        let lowBattery = battery.entries.filter(\.pageOpen)
        if !lowBattery.isEmpty {
            sendLowBatteryPages(lowBattery, percent: battery.trippedPercent ?? lastPower.percent, via: client)
        }
        if !pages.isEmpty || !lowBattery.isEmpty {
            Logger.shared.log("Relay channel changed — re-sent \(pages.count + lowBattery.count) open page(s)")
        }
    }

    /// Which open pages to re-send on a new relay channel. Applies the same
    /// gates the backends apply before a first send: idle / rate-limit pages
    /// wait while the user is at the Mac, a battery-paused session keeps only
    /// its low-battery page, a Codex thread a Page hook is holding was paged
    /// by the hook, and hook-owned ids are the hook's to post. Pages answered
    /// recently are skipped so a fresh inbox can't take a second answer.
    static func pagesToResend(_ snapshots: [AgentBackendSnapshot],
                              excludedIds: Set<String>,
                              pausedSessionKeys: Set<String>,
                              hookHeldSessionIds: Set<String>,
                              userAtMac: Bool) -> [InterventionEvent] {
        var seen = Set<String>()
        var out: [InterventionEvent] = []
        for snap in snapshots {
            for page in snap.pendingInterventions {
                guard !page.id.hasPrefix("hook"), !excludedIds.contains(page.id),
                      !BatteryPolicy.isLowBatteryPageId(page.id) else { continue }
                if userAtMac && ClaudeBackend.pageNeedsAway(page.kind) { continue }
                if page.kind == .idle {
                    if pausedSessionKeys.contains("\(snap.backendID.rawValue)|\(page.sessionId)") { continue }
                    if snap.backendID == .codex && hookHeldSessionIds.contains(page.sessionId) { continue }
                }
                guard seen.insert(page.id).inserted else { continue }
                out.append(page)
            }
        }
        return out
    }

    /// On the relay queue. `hookpre-` pages belong to the blocking
    /// PreToolUse hook, which polls the Worker itself; injecting them too
    /// would answer the prompt twice.
    private func route(_ reply: RelayReply) {
        if reply.interventionId.hasPrefix("hookpre-") {
            Logger.shared.log("Ignoring reply for hook-owned page \(reply.interventionId)")
            return
        }
        // Low-battery pages are the Coordinator's own, not a backend's.
        if BatteryPolicy.isLowBatteryPageId(reply.interventionId) {
            tickQueue.async { [weak self] in self?.handleLowBatteryReply(reply) }
            return
        }
        let repliedId = reply.interventionId
        tickQueue.async { [weak self] in
            guard let self else { return }
            self.recentlyRepliedIds[repliedId] = Date()
            if self.recentlyRepliedIds.count > 500 {
                let cutoff = Date().addingTimeInterval(-Self.recentReplyMemory)
                self.recentlyRepliedIds = self.recentlyRepliedIds.filter { $0.value > cutoff }
            }
        }
        let owner = reply.owningBackend
        guard let backend = backends.first(where: { $0.id == owner }),
              let queue = replyQueues[owner] else {
            Logger.shared.log("No backend for reply \(reply.interventionId) (\(owner.rawValue))")
            return
        }
        Logger.shared.log("Reply for \(reply.interventionId) → \(backend.displayName) (action=\(reply.action ?? "none"), \(reply.text.count) chars)")
        queue.async { backend.handleReply(reply) }
    }

    private func relayDidConnect(_ client: RelayClient) {
        guard client === relay, !isShutDown else { return }
        lastPower = readPower()
        // Heartbeat first: older Workers only tag the socket as the Mac's
        // (and flush queued replies to it) on a heartbeat/intervention
        // frame, and don't know `sync`.
        sendHeartbeat(force: true)
        lastSyncAt = .distantPast
        maybeSync()
        publishSnapshot()
    }

    private func sendHeartbeat(force: Bool) {
        guard let relay, relay.isConnected else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastHeartbeatAt) >= Self.heartbeatInterval - 1 else { return }
        lastHeartbeatAt = now
        let p = lastPower
        let live = backends.flatMap { $0.currentSnapshot.sessions }.filter { $0.state != .offline }.count
        relay.sendHeartbeat(activeSessions: live, battery: p.hasBattery ? p.percent : -1, onAC: p.onAC)
    }

    private func maybeSync() {
        guard hasTicked, let relay, relay.isConnected else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSyncAt) >= Self.syncInterval else { return }
        lastSyncAt = now
        for backend in backends where isEnabled(backend.id) {
            // Codex discovers its pages asynchronously after start; until its
            // first scan is done an empty list means "don't know yet", and
            // syncing it would close (then re-open and re-buzz) every card.
            if backend.id == .codex && !codexBackend.hasCompletedFirstScan { continue }
            // Union with the pages the backend reports as pending, so a
            // backend that under-reports open ids can't make the Worker
            // close a card that is still waiting. Unknown ids are ignored.
            var ids = Set(backend.openInterventionIds())
            ids.formUnion(backend.currentSnapshot.pendingInterventions.map(\.id))
            // Low-battery pages belong to the Coordinator; without this the
            // Worker would close them as stale within a minute.
            ids.formUnion(battery.entries.filter { $0.pageOpen && $0.session.backend == backend.id }.map(\.pageId))
            relay.sendSync(backend: backend.id, openIds: ids.sorted())
        }
    }

    private func isEnabled(_ id: AgentBackendID) -> Bool {
        switch id {
        case .claude: return true
        case .codex: return tickConfig.codexBackendEnabled
        }
    }

    // MARK: timers (tick queue)

    private func scheduleTimers() {
        tickTimer?.cancel()
        let interval = tickConfig.checkIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: tickQueue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        tickTimer = t

        if housekeepingTimer == nil {
            // Heartbeat/sync cadence is independent of the check interval
            // (which may be minutes) — the phone shows "Mac offline" when
            // heartbeats stop.
            let h = DispatchSource.makeTimerSource(queue: tickQueue)
            h.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval, leeway: .seconds(1))
            h.setEventHandler { [weak self] in
                guard let self, !self.isShutDown, !self.isTerminating else { return }
                // Lid-closed-on-battery must follow real work: with a long
                // check interval, refresh the backends here rather than
                // judge "agents working" from minutes-old snapshots.
                if self.hasTicked, self.sleepGuard.isActive,
                   Date().timeIntervalSince(self.lastTickAt) >= Self.lidClosedMaxSnapshotAge {
                    self.tick()
                } else {
                    self.lastPower = self.readPower()
                    if self.hasTicked, self.evaluatePower(self.lastPower, cfg: self.tickConfig) {
                        self.publishSnapshot()
                    }
                }
                self.sendHeartbeat(force: false)
                self.maybeSync()
                self.retryPendingRetirements()
            }
            h.resume()
            housekeepingTimer = h
        }
    }

    // MARK: tick (tick queue)

    private func readPower() -> PowerSnapshot {
        powerFilter.filter(power.snapshot())
    }

    private func tick() {
        guard !isShutDown, !isTerminating else { return }
        let cfg = tickConfig
        let p = readPower()
        lastPower = p
        lastTickAt = Date()
        backends.forEach { backend in
            backend.refresh()
            logBackendSnapshotChange(for: backend)
        }

        lastSnapshots = backends.map { $0.currentSnapshot }
        evaluatePower(p, cfg: cfg)

        hasTicked = true
        maybeSync()
        publishSnapshot()
    }

    // MARK: keeping awake (tick queue)

    /// Battery policy + assertions + lid-closed flag for one power reading,
    /// using the last backend snapshots. Runs on every tick and on the 15 s
    /// housekeeping timer, so the low-battery trip, the grace deadline and
    /// the disablesleep safety checks never wait for a long check interval.
    /// Returns whether anything the menu shows changed.
    @discardableResult
    private func evaluatePower(_ p: PowerSnapshot, cfg: Config) -> Bool {
        guard !isTerminating else { return false }
        let before = (battery, power.held, sleepGuard.isActive, sleepGuard.cleanupPending)
        let effects = battery.observe(p, settings: BatteryPolicy.Settings(cfg), now: Date())
        handleBatteryEffects(effects, power: p, agentsWereKeptAwake: power.isBoosting)
        // An automatic resume held while the user was at the Mac runs once
        // they step away (checked every tick and every housekeeping pass).
        runOwedAutoResume(justRecovered: false)
        persistBattery()
        applyPower(p, snapshots: lastSnapshots)
        return before.0 != battery || before.1 != power.held || before.2 != sleepGuard.isActive
            || before.3 != sleepGuard.cleanupPending
    }

    /// Some session is actually mid-turn. Not the same as wanting the
    /// assertion: backends also hold it through a rate-limit reset, for a
    /// pending page and (Codex) while waiting on the user — reasons to keep
    /// an open Mac from idle-sleeping, not to keep a closed one awake.
    static func agentsWorking(_ snapshots: [AgentBackendSnapshot]) -> Bool {
        snapshots.contains { snap in
            snap.sessions.contains { $0.state == .active && !$0.activeFlags.contains { $0.hasPrefix("waitingOn") } }
        }
    }

    /// Decides and applies this tick's assertions and the lid-closed-on-
    /// battery flag. Called after every tick and whenever battery state
    /// changes between ticks.
    private func applyPower(_ p: PowerSnapshot, snapshots: [AgentBackendSnapshot]) {
        guard !isTerminating else { return }
        let cfg = tickConfig
        let agentsWant = snapshots.contains { $0.wantsPowerAssertion }
        let boost: Bool
        switch battery.boostDirective(p) {
        case .followAgents: boost = agentsWant
        case .hold: boost = true
        case .block: boost = false
        }
        let plan = AwakeAssertions.plan(boost: boost, power: p, lidClosedOnAC: cfg.keepAwakeLidClosedOnAC)
        if plan != power.held {
            let batteryText = p.hasBattery ? "battery \(p.percent)%, \(p.onAC ? "AC" : "on battery")" : "AC power"
            let reason: String
            if battery.phase == .grace {
                reason = "Low battery — giving agents time to write their summary (\(batteryText))"
            } else if let rl = mergedRateLimit(snapshots) {
                reason = "Holding through rate-limit reset (\(rl.projectName), \(batteryText))"
            } else {
                reason = "Agent active (\(batteryText))"
            }
            power.apply(plan, reason: reason)
        }
        updateSleepGuard(boosting: power.isBoosting, agentsWorking: Self.agentsWorking(snapshots), power: p, cfg: cfg)
    }

    private func updateSleepGuard(boosting: Bool, agentsWorking: Bool, power p: PowerSnapshot, cfg: Config) {
        // A watchdog that failed to load (e.g. launchd still tearing down the
        // old job) heals itself instead of keeping the option off all run.
        if cfg.keepAwakeLidClosedOnBattery, !sleepGuard.watchdogLoaded,
           Date().timeIntervalSince(lastWatchdogSyncAt) >= Self.watchdogRetryInterval {
            lastWatchdogSyncAt = Date()
            sleepGuard.syncWatchdog(enabled: true)
        }
        var inputs = SleepGuardPolicy.Inputs(
            enabled: cfg.keepAwakeLidClosedOnBattery, boosting: boosting, agentsWorking: agentsWorking,
            power: p, cutoff: cfg.lowBatteryCutoff, thermal: ProcessInfo.processInfo.thermalState,
            helperAvailable: true, batteryPhase: battery.phase, currentlyActive: sleepGuard.isActive,
            watchdogLoaded: sleepGuard.watchdogLoaded)
        // Only ask sudo (cached) once everything else says yes.
        if SleepGuardPolicy.blocker(inputs) == nil {
            inputs.helperAvailable = sleepGuard.helperStatus() == .available
        }
        let blocker = SleepGuardPolicy.blocker(inputs)
        sleepGuard.update(shouldDisableSleep: blocker == nil,
                          reason: blocker ?? (battery.phase == .grace
                                              ? "agents pausing on low battery, \(p.percent)%"
                                              : "agents working on battery, \(p.percent)%"))
        let relevant = cfg.keepAwakeLidClosedOnBattery && boosting && p.hasBattery && !p.onAC
        lidBlocker = relevant ? blocker : nil
    }

    // MARK: low battery (tick queue)

    private func restorePowerStateAfterLaunch(_ cfg: Config) {
        // Never leave `disablesleep 1` behind from a crashed run.
        sleepGuard.forceDisable(reason: "found on launch")
        lastWatchdogSyncAt = Date()
        sleepGuard.syncWatchdog(enabled: cfg.keepAwakeLidClosedOnBattery)
        if var restored = batteryStore.load() {
            restored.restoredAfterLaunch(now: Date())
            battery = restored
            savedBattery = restored
            if restored.isTripped || !restored.entries.isEmpty {
                Logger.shared.log("Restored low-battery state: phase=\(restored.phase.rawValue) paused=\(restored.entries.count)")
            }
        }
    }

    private func persistBattery() {
        guard battery != savedBattery else { return }
        if batteryStore.save(battery) { savedBattery = battery }
    }

    private func batteryTargets() -> [(AgentBackendID, BatteryPausable)] {
        backends.filter { isEnabled($0.id) }.compactMap { b in
            (b as? BatteryPausable).map { (b.id, $0) }
        }
    }

    private func handleBatteryEffects(_ effects: [BatteryPolicy.Effect], power p: PowerSnapshot, agentsWereKeptAwake: Bool) {
        for effect in effects {
            switch effect {
            case let .pauseSessions(message, mode, percent):
                let targets = batteryTargets()
                Logger.shared.log("Battery at \(percent)% on battery (cutoff \(tickConfig.lowBatteryCutoff)%) — asking \(targets.count) agent backend(s) to pause (\(mode.rawValue))")
                batteryQueue.async { [weak self] in
                    var paused: [PausedSession] = []
                    for (_, target) in targets { paused += target.pauseBusySessions(message: message) }
                    self?.tickQueue.async { self?.batteryPauseFinished(paused) }
                }

            case let .trippedWithoutPause(percent):
                Logger.shared.log("Battery at \(percent)% on battery — low-battery action is off; no longer keeping the Mac awake")
                if agentsWereKeptAwake {
                    onBatteryNotice?(BatteryNotice(
                        title: "Battery \(percent)% — letting the Mac sleep",
                        body: "Page stopped keeping the Mac awake. Plug in to keep your agents running."))
                }

            case let .graceEnded(count):
                Logger.shared.log("Low-battery grace period over (\(count) paused) — releasing keep-awake so the Mac can sleep")

            case let .pageSessions(entries, percent):
                sendLowBatteryPages(entries, percent: percent)
                let names = Self.projectList(entries.map(\.session))
                let grace = Int(tickConfig.lowBatteryPauseGraceSeconds)
                onBatteryNotice?(BatteryNotice(
                    title: "Battery \(percent)% — paused \(entries.count) session\(entries.count == 1 ? "" : "s")",
                    body: "Asked \(names) to stop and summarise. The Mac can sleep in about \(grace) s — plug in to keep going."))

            case let .recovered(sessions, resume, _, closePageIds):
                Logger.shared.log("Power back (battery \(p.percent)%, onAC=\(p.onAC)) — \(sessions.count) paused session(s), resume=\(resume)")
                for id in closePageIds { relay?.sendInterventionClosed(id: id, reason: "session_resolved") }
                if resume {
                    // The policy keeps the entries; this runs the resume now,
                    // or holds it while the user is at the Mac.
                    runOwedAutoResume(justRecovered: true)
                } else if !sessions.isEmpty {
                    let n = sessions.count
                    onBatteryNotice?(BatteryNotice(
                        title: "Power restored — \(n) session\(n == 1 ? " is" : "s are") paused",
                        body: "Choose “Resume paused sessions now” in Page’s menu, or reply “carry on” from your phone."))
                }
            }
        }
    }

    /// How recently the user must have touched the Mac for the automatic
    /// battery resume to wait: at least two minutes, longer when the user
    /// asked for idle pages only after a longer absence.
    static func autoResumePresenceWindow(_ cfg: Config) -> TimeInterval {
        max(120, cfg.idlePageOnlyWhenAwaySeconds)
    }

    /// What to do about an automatic resume the policy says is owed.
    enum AutoResumeDecision: Equatable {
        /// Nothing owed, or a resume is already typing.
        case nothing
        /// `resumeAfterBatteryRecovery` was turned off meanwhile: drop it.
        case cancel
        /// The user is at the Mac: keep it owed, try again later.
        case hold
        case run
    }

    static func autoResumeDecision(owed: Bool, enabled: Bool, inFlight: Bool, userPresent: Bool) -> AutoResumeDecision {
        guard owed else { return .nothing }
        guard enabled else { return .cancel }
        if inFlight { return .nothing }
        return userPresent ? .hold : .run
    }

    /// Runs the automatic resume the policy owes, unless the user is at the
    /// Mac: typing "carry on" into a session they may be typing in (or
    /// reading) could submit their half-written draft or answer a prompt.
    /// Held, the entries stay listed: the next tick or housekeeping pass
    /// after the user steps away runs it, or the menu does it right away.
    private func runOwedAutoResume(justRecovered: Bool) {
        let decision = Self.autoResumeDecision(
            owed: battery.awaitingAutoResume, enabled: tickConfig.resumeAfterBatteryRecovery,
            inFlight: batteryResumeInFlight,
            userPresent: battery.awaitingAutoResume
                && UserPresence.isActive(within: Self.autoResumePresenceWindow(tickConfig)))
        switch decision {
        case .nothing:
            return
        case .cancel:
            battery.autoResumeStarted()
            Logger.shared.log("Automatic resume after power came back is off — leaving \(battery.pausedSessions.count) session(s) paused")
        case .hold:
            guard justRecovered else { return }
            let n = battery.pausedSessions.count
            Logger.shared.log("Power back — holding the automatic resume of \(n) session(s) while you're at the Mac")
            onBatteryNotice?(BatteryNotice(
                title: "Power is back — \(n) session\(n == 1 ? "" : "s") will resume when you step away",
                body: "Page doesn’t type into sessions while you’re using the Mac. Choose “Resume paused sessions now” to resume them now."))
        case .run:
            battery.autoResumeStarted()
            resumeSessions(battery.pausedSessions, message: BatteryPolicy.recoveryMessage, automatic: true)
        }
    }

    private func batteryPauseFinished(_ paused: [PausedSession]) {
        guard !isShutDown else { return }
        Logger.shared.log("Low-battery pause finished: \(paused.count) session(s) paused\(paused.isEmpty ? "" : " — " + paused.map { "\($0.projectName) (\($0.detail))" }.joined(separator: "; "))")
        let effects = battery.pauseFinished(paused, settings: BatteryPolicy.Settings(tickConfig), now: Date())
        handleBatteryEffects(effects, power: lastPower, agentsWereKeptAwake: power.isBoosting)
        persistBattery()
        applyPower(lastPower, snapshots: lastSnapshots)
        publishSnapshot()
    }

    private func sendLowBatteryPages(_ entries: [BatteryPolicy.Entry], percent: Int, via client: RelayClient? = nil) {
        guard let relay = client ?? relay else {
            Logger.shared.log("Low-battery pages not sent — the phone relay is off")
            return
        }
        for e in entries {
            let s = e.session
            relay.sendInterventionOpened(InterventionEvent(
                id: e.pageId,
                sessionId: s.sessionId,
                cwd: s.cwd,
                projectName: s.projectName,
                kind: .idle,
                openedAt: s.pausedAt,
                context: BatteryPolicy.pageContext(percent: percent),
                transcriptPath: "",
                backend: s.backend,
                source: .terminal,
                subtype: "low_battery"
            ))
        }
    }

    /// Types `message` into `sessions` (on `batteryQueue`), then removes the
    /// resumed ones from the paused list and closes their pages.
    private func resumeSessions(_ sessions: [PausedSession], message: String, automatic: Bool) {
        guard !sessions.isEmpty else { return }
        let targets = Dictionary(batteryTargets(), uniquingKeysWith: { a, _ in a })
        batteryResumeInFlight = true
        batteryQueue.async { [weak self] in
            var resumedKeys = Set<String>()
            var attemptedKeys = Set<String>()
            for (backendID, group) in Dictionary(grouping: sessions, by: \.backend) {
                attemptedKeys.formUnion(group.map(BatteryPolicy.key))
                guard let target = targets[backendID] else { continue }
                let ids = Set(target.resumePausedSessions(group, message: message))
                for s in group where ids.contains(s.sessionId) { resumedKeys.insert(BatteryPolicy.key(s)) }
            }
            self?.tickQueue.async {
                guard let self else { return }
                self.batteryResumeInFlight = false
                guard !self.isShutDown else { return }
                // Automatic resume is one-shot: what a backend refused (the
                // user already typed there, it isn't idle) is reported, not
                // kept "paused" for a day. The menu only drops what resumed,
                // so it can be tried again.
                let closing = self.battery.removeSessions(keys: automatic ? attemptedKeys : resumedKeys)
                for id in closing { self.relay?.sendInterventionClosed(id: id, reason: "session_resolved") }
                self.persistBattery()
                let total = sessions.count
                let done = resumedKeys.count
                Logger.shared.log("Resumed \(done) of \(total) battery-paused session(s)")
                let title = automatic ? "Power is back — resumed \(done) of \(total) session\(total == 1 ? "" : "s")"
                                      : "Resumed \(done) of \(total) paused session\(total == 1 ? "" : "s")"
                let body = done == total
                    ? "Told \(Self.projectList(sessions)) to carry on."
                    : "\(total - done) couldn’t be resumed (not idle, or you’d already typed in it)."
                self.onBatteryNotice?(BatteryNotice(title: title, body: body))
                self.publishSnapshot()
            }
        }
    }

    /// Menu: "Resume paused sessions now".
    func resumePausedSessionsNow() {
        tickQueue.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            let sessions = self.battery.pausedSessions
            guard !sessions.isEmpty else { return }
            guard !self.batteryResumeInFlight else {
                Logger.shared.log("Resume paused sessions: a resume is already running")
                return
            }
            // The user chose to resume (the presence hold doesn't apply):
            // this is the one attempt an owed automatic resume would make.
            self.battery.autoResumeStarted()
            self.persistBattery()
            let message = self.battery.isTripped ? BatteryPolicy.manualResumeMessage : BatteryPolicy.recoveryMessage
            self.resumeSessions(sessions, message: message, automatic: false)
        }
    }

    /// A phone reply to a low-battery page. approve / carry_on resume the
    /// session, custom text is typed into it, deny leaves it paused.
    private func handleLowBatteryReply(_ reply: RelayReply) {
        let id = reply.interventionId
        guard let entry = battery.entry(forPageId: id) else {
            relay?.sendReplyInjected(interventionId: id, method: "battery", success: false,
                                     detail: "This session is no longer paused", output: nil)
            relay?.sendInterventionClosed(id: id, reason: "session_resolved")
            return
        }
        let message: String
        switch BatteryPolicy.replyDecision(action: reply.action, text: reply.text, stillTripped: battery.isTripped) {
        case .leavePaused:
            battery.markPageClosed(id)
            persistBattery()
            relay?.sendReplyInjected(interventionId: id, method: "battery", success: true,
                                     detail: "Left paused", output: nil)
            relay?.sendInterventionClosed(id: id, reason: "replied")
            publishSnapshot()
            return
        case .reject(let detail):
            relay?.sendReplyInjected(interventionId: id, method: "battery", success: false,
                                     detail: detail, output: nil)
            return
        case .resume(let text):
            message = text
        }
        let session = entry.session
        guard let target = batteryTargets().first(where: { $0.0 == session.backend })?.1 else {
            relay?.sendReplyInjected(interventionId: id, method: "battery", success: false,
                                     detail: "Page can’t resume this agent", output: nil)
            return
        }
        let stillLow = battery.isTripped && !lastPower.onAC
        batteryQueue.async { [weak self] in
            let ok = target.resumePausedSessions([session], message: message).contains(session.sessionId)
            self?.tickQueue.async {
                guard let self else { return }
                if ok {
                    self.battery.removeSessions(keys: [BatteryPolicy.key(session)])
                    self.persistBattery()
                    let detail = stillLow ? "Sent — the battery is still low, plug in or the Mac will sleep" : "Sent to the session"
                    self.relay?.sendReplyInjected(interventionId: id, method: "battery", success: true, detail: detail, output: nil)
                    self.relay?.sendInterventionClosed(id: id, reason: "replied")
                } else {
                    self.relay?.sendReplyInjected(interventionId: id, method: "battery", success: false,
                                                  detail: "The session isn’t idle — check the Mac", output: nil)
                }
                self.publishSnapshot()
            }
        }
    }

    private static func projectList(_ sessions: [PausedSession]) -> String {
        let names = Array(NSOrderedSet(array: sessions.map(\.projectName))) as? [String] ?? []
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
    }

    /// Soonest-resetting limit that is still in the future. Expired limits
    /// are ignored so a backend that never clears its state can't pin the
    /// menu on "Rate-limited" forever.
    private func mergedRateLimit(_ snapshots: [AgentBackendSnapshot]) -> RateLimitEvent? {
        let now = Date()
        return snapshots.compactMap { $0.currentRateLimit }
            .filter { $0.resetTime > now }
            .min(by: { $0.resetTime < $1.resetTime })
    }

    private func publishSnapshot() {
        let cfg = tickConfig
        let snapshots = backends.map { $0.currentSnapshot }
        let infos: [BackendInfo] = snapshots.map { s in
            BackendInfo(
                id: s.backendID,
                displayName: s.displayName,
                enabled: isEnabled(s.backendID),
                sessionCount: s.sessions.count,
                activeCount: s.sessions.filter { $0.state == .active }.count,
                waitingCount: s.sessions.filter { $0.state == .waitingOnUser || $0.state == .waitingOnApproval }.count,
                problem: s.backendID == .codex && cfg.codexBackendEnabled
                    && ProcessRunner.findExecutable("codex", configured: cfg.codexPath.isEmpty ? nil : cfg.codexPath) == nil
                    ? "codex not found — set its path in Preferences → Agents"
                    : nil
            )
        }
        let relayState: RelayState = {
            guard cfg.relayEnabled else { return .off }
            if let problem = cfg.relayURLProblem { return .misconfigured(problem.message) }
            return relay?.isConnected == true ? .connected : .connecting
        }()
        let snap = Snapshot(
            sessions: snapshots.flatMap { $0.sessions },
            power: lastPower,
            awake: power.held,
            lidClosedOnBattery: sleepGuard.isActive,
            lidClosedOnBatteryBlocker: lidBlocker,
            lidClosedCleanupFailed: sleepGuard.cleanupPending,
            battery: BatteryStatus(phase: battery.phase, paused: battery.pausedSessions,
                                   graceEndsAt: battery.graceEndsAt, mode: battery.mode),
            activeRateLimit: mergedRateLimit(snapshots),
            scheduledResumes: claudeBackend.latestState.scheduledResumes,
            pendingInterventions: snapshots.flatMap { $0.pendingInterventions },
            relayState: relayState,
            backends: infos,
            configProblem: configProblem
        )
        onStateChange?(snap)
    }

    private func logBackendSnapshotChange(for backend: AgentBackend) {
        let s = backend.currentSnapshot
        let summary = BackendSummary(
            sessionStates: s.sessions.map { "\($0.sessionId.prefix(8)):\($0.state.rawValue)" }.sorted(),
            wantsPower: s.wantsPowerAssertion,
            pendingIds: Set(s.pendingInterventions.map(\.id)),
            rateLimitId: s.currentRateLimit?.uniqueId
        )
        guard loggedSummaries[backend.id] != summary else { return }
        loggedSummaries[backend.id] = summary
        Logger.shared.log(
            "Backend snapshot updated: \(backend.displayName) sessions=\(s.sessions.count) wantsPower=\(s.wantsPowerAssertion) pendingInterventions=\(s.pendingInterventions.count)"
        )
    }

    // MARK: rate limits

    /// Backends call this from wherever they detect the limit (Claude: the
    /// tick queue mid-refresh; Codex: its app-server reader). Deferring to
    /// the tick queue lets the current refresh finish first, so the notice
    /// can report whether ClaudeBackend actually scheduled a resume.
    private func handleNewRateLimit(_ event: RateLimitEvent) {
        tickQueue.async { [weak self] in
            guard let self, !self.isShutDown else { return }
            // One notice per (agent, session, reset minute): Codex re-reports
            // the same limit on every rate-limit update.
            let key = "\(event.backend.rawValue)|\(event.sessionId)|\(Int(event.resetTime.timeIntervalSince1970 / 60))"
            guard self.notifiedRateLimitKeys.insert(key).inserted else { return }
            if self.notifiedRateLimitKeys.count > 500 { self.notifiedRateLimitKeys = [key] }

            let scheduled = event.backend == .claude
                ? self.claudeBackend.latestState.scheduledResumes.first {
                    $0.sessionId == event.sessionId && abs($0.resetTime.timeIntervalSince(event.resetTime)) < 300
                }
                : nil
            let notice = RateLimitNotice(event: event, scheduledResume: scheduled,
                                         canResume: Coordinator.canResume(event))
            self.onNewRateLimit?(notice)
        }
    }

    /// Only Claude limits that name a real session and project can be
    /// resumed with `claude --resume`. Codex thread ids (or the "codex"
    /// fallback) passed to it would fail — or run in the wrong directory.
    static func canResume(_ event: RateLimitEvent) -> Bool {
        event.backend == .claude
            && UUID(uuidString: event.sessionId) != nil
            && !event.cwd.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Schedules a resume at the event's reset time. Runs on the tick queue
    /// (where ClaudeBackend lives); `completion` is called on main.
    func scheduleResumeManually(for event: RateLimitEvent, prompt: String? = nil,
                                completion: @escaping (Result<ScheduledResume, Error>) -> Void) {
        guard event.backend == .claude else {
            DispatchQueue.main.async { completion(.failure(ResumeError.unsupportedBackend(event.backend))) }
            return
        }
        guard Coordinator.canResume(event) else {
            DispatchQueue.main.async { completion(.failure(ResumeError.missingSession)) }
            return
        }
        tickQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.claudeBackend.scheduleResumeManually(for: event, prompt: prompt) }
            DispatchQueue.main.async { completion(result) }
            self.tick()
        }
    }

    func cancelResume(_ scheduled: ScheduledResume) {
        tickQueue.async { [weak self] in
            guard let self else { return }
            self.claudeBackend.cancelResume(scheduled)
            Logger.shared.log("Cancelled scheduled resume for \(scheduled.projectName) at \(scheduled.resetTime)")
            self.tick()
        }
    }
}
