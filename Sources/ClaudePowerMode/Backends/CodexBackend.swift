import Foundation

/// Codex backend: watches Codex sessions (CLI, Desktop, VS Code), keeps the
/// Mac awake while they work, pages the phone when one finishes a turn and
/// sits waiting, and delivers the phone's replies.
///
/// How it sees sessions, and why it works this way:
///   - Discovery: a `codex app-server` child (`AppServerClient`) lists
///     threads (`thread/list`, newest first, a few pages) with their cwd,
///     source and rollout path.
///   - Live state: every Codex surface embeds its *own* app-server, so our
///     child never receives turn/approval notifications for the user's
///     sessions. The rollout JSONL that each session appends to is the one
///     signal all surfaces share, so state is re-derived from its tail on
///     every tick (`CodexRollout`): mid-turn → active, turn ended → idle,
///     ended and quiet for `idlePageDelaySeconds` while the user is away →
///     an idle page.
///   - Approval prompts of CLI/Desktop/VS Code sessions are NOT detected:
///     Codex doesn't write approval requests to the rollout. A session
///     blocked on one just looks mid-turn (active, until it's been quiet
///     for `stalledTurnSeconds`). Approval requests that do reach our own
///     child (only if a turn ever runs against it) are paged and answered
///     natively with a JSON-RPC decision.
///   - Rate limits: the `rate_limits` snapshot in rollout `token_count`
///     events and `account/rateLimits/updated`. Account-level, tagged
///     `.codex`; never resumable with `claude --resume`.
///   - Replies: `CodexInjector`, and only once the thread's latest turn has
///     ended — while a turn runs an approval overlay may be up, and it
///     treats typed letters as hotkeys.
///
/// Threading: all shared state lives behind `lock`. One refresh cycle runs
/// at a time (`cycleInFlight`); its blocking file/process work runs on
/// `scanQueue`, which also owns the rollout cache. Replies are serialised
/// on `replyQueue`, which only ever does short keystroke work (it is shared
/// with the low-battery pause and resume). A background `codex exec resume`
/// runs a whole agent turn, so it runs on `execQueue`, at most one per
/// thread (`execGate`).
final class CodexBackend: AgentBackend, @unchecked Sendable {
    typealias ThreadSummary = AppServerProtocol.ThreadSummary
    typealias JSON = AppServerProtocol.JSON

    let id: AgentBackendID = .codex
    let displayName = "Codex"

    var relay: RelaySink? {
        get { locked { _relay } }
        set { locked { _relay = newValue } }
    }
    var onNewIntervention: ((InterventionEvent) -> Void)? {
        get { locked { _onNewIntervention } }
        set { locked { _onNewIntervention = newValue } }
    }
    var onNewRateLimit: ((RateLimitEvent) -> Void)? {
        get { locked { _onNewRateLimit } }
        set { locked { _onNewRateLimit = newValue } }
    }

    // MARK: Tunables

    /// Threads updated this recently are watched even without a live
    /// process in their directory (Desktop / VS Code run from cwd `/`).
    static let recentThreadWindow: TimeInterval = 30 * 60
    /// Idle pages older than this auto-resolve instead of re-paging after
    /// every Mac restart.
    static let maxIdlePageAge: TimeInterval = 4 * 3600
    /// A turn with no rollout writes for this long is treated as stalled
    /// (crashed TUI, or a long-unanswered approval) and stops holding power.
    static let stalledTurnSeconds: TimeInterval = 15 * 60
    /// The same for a thread on a local model (Ollama, LM Studio): a long
    /// prompt evaluation or a slow generation on the Mac's own GPU can go
    /// many minutes between rollout writes without being stuck.
    static let localStalledTurnSeconds: TimeInterval = 60 * 60

    static func stalledTurnSeconds(isLocal: Bool) -> TimeInterval {
        isLocal ? localStalledTurnSeconds : stalledTurnSeconds
    }
    static let listPageSize = 50
    static let maxListPages = 4
    /// Rate-limit snapshots older than this aren't trusted to describe now.
    static let rateLimitLookback: TimeInterval = 6 * 3600

    // MARK: State (all behind `lock`)

    private let client: AppServerClient
    private let lock = NSLock()
    private var _config: Config
    private var _relay: RelaySink?
    private var _onNewIntervention: ((InterventionEvent) -> Void)?
    private var _onNewRateLimit: ((RateLimitEvent) -> Void)?

    private var started = false
    /// Bumped by start/stop: a cycle that started under an older generation
    /// throws its results away instead of resurrecting a disabled backend.
    private var generation = 0
    private var cycleInFlight = false
    private var startFailures = 0
    private var nextStartAttempt = Date.distantPast
    private var lastStartError: String?
    private var lastListError: String?
    private var readySince: Date?
    private var listSupportsSort = true
    private var _hasCompletedFirstScan = false

    private var threads: [String: ThreadSummary] = [:]
    private var watchedThreadIDs: Set<String> = []
    private var threadStates: [String: AgentSessionState] = [:]
    private var threadActivity: [String: Date] = [:]
    /// State reported by app-server notifications (only for turns our own
    /// child drives). Wins while it's newer than the rollout's last write.
    private var statusHints: [String: (state: AgentSessionState, at: Date)] = [:]
    private var pendingInterventions: [String: InterventionEvent] = [:]
    /// Threads paused for low battery; their idle page is held back until
    /// resumed so it can't replace the Coordinator's low-battery page.
    private var batteryPausedIds = Set<String>()
    /// Approval pages backed by a live server request (interventionId → request).
    private var serverRequests: [String: AppServerClient.ServerRequest] = [:]
    /// Idle pages answered from the phone: don't re-open them while the
    /// rollout still shows the same finished turn.
    private var suppressedIdleIds: Set<String> = []
    private var lastRolloutRateLimit: CodexRateLimitSnapshot?
    private var pushedRateLimit: CodexRateLimitSnapshot?
    private var currentRateLimit: RateLimitEvent?
    private var rateLimitFirstSeen: [String: Date] = [:]
    private var notifiedRateLimitKeys: Set<String> = []
    private var loggedUnhandledMethods: Set<String> = []
    private var lastSnapshot: AgentBackendSnapshot

    // MARK: Queue-confined

    private let scanQueue = DispatchQueue(label: "ClaudePowerMode.codex.scan", qos: .utility)
    private let replyQueue = DispatchQueue(label: "ClaudePowerMode.codex.replies", qos: .userInitiated)
    /// Background `codex exec resume` runs (up to 15 min each). Concurrent:
    /// different threads don't wait on each other; `execGate` keeps it to
    /// one run per thread.
    private let execQueue = DispatchQueue(label: "ClaudePowerMode.codex.exec", qos: .utility, attributes: .concurrent)
    private let execGate = CodexExecResumeGate()
    /// scanQueue only.
    private var rolloutCache: [String: CachedRollout] = [:]
    /// scanQueue only. pid → model provider of that codex process (from its
    /// argv, read once per pid and start time; argv itself is dropped).
    private var processProviders: [Int32: (start: Int?, provider: ModelProvider)] = [:]
    /// scanQueue only. Thread cwd → canonical path (realpath is disk I/O).
    private var canonicalCwds: [String: String] = [:]

    private struct CachedRollout {
        let mtime: Date
        let size: UInt64
        let summary: CodexRollout.Summary
    }

    init(config: Config, client: AppServerClient? = nil) {
        self._config = config
        self.client = client ?? AppServerClient(codexPath: config.codexPath)
        self.lastSnapshot = Self.emptySnapshot
        // Wired once: the client may call back from its own queue at any time.
        self.client.onNotification = { [weak self] method, params in
            self?.handleNotification(method: method, params: params)
        }
        self.client.onServerRequest = { [weak self] request in
            self?.handleServerRequest(request) ?? false
        }
        self.client.onUnexpectedExit = { [weak self] in
            self?.handleClientExit()
        }
    }

    private static let emptySnapshot = AgentBackendSnapshot(
        backendID: .codex,
        displayName: "Codex",
        sessions: [],
        wantsPowerAssertion: false,
        pendingInterventions: [],
        currentRateLimit: nil
    )

    var currentSnapshot: AgentBackendSnapshot {
        locked { lastSnapshot }
    }

    func openInterventionIds() -> [String] {
        locked { Array(pendingInterventions.keys) }
    }

    /// False until the first rollout scan since `start()` has finished.
    /// Before that `openInterventionIds()` is empty because nothing has been
    /// looked at yet, not because every Codex page was resolved.
    var hasCompletedFirstScan: Bool {
        locked { _hasCompletedFirstScan }
    }

    // MARK: Lifecycle

    func start() {
        let cfg = locked { _config }
        guard cfg.codexBackendEnabled else {
            Logger.shared.log("CodexBackend disabled in config — not starting")
            return
        }
        let fresh: Bool = locked {
            guard !started else { return false }
            started = true
            generation += 1
            startFailures = 0
            nextStartAttempt = .distantPast
            lastStartError = nil
            return true
        }
        guard fresh else { return }
        client.codexPath = cfg.codexPath
        Logger.shared.log("CodexBackend starting (codexPath=\(cfg.codexPath.isEmpty ? "auto" : cfg.codexPath))")
        refresh()
    }

    func shutdown() {
        stop(closingPages: false)
    }

    func reloadConfig(_ config: Config) {
        let old: Config = locked {
            let o = _config
            _config = config
            return o
        }
        client.codexPath = config.codexPath
        if old.codexBackendEnabled && !config.codexBackendEnabled {
            Logger.shared.log("CodexBackend disabled via config — shutting down")
            stop(closingPages: true)
        } else if !old.codexBackendEnabled && config.codexBackendEnabled {
            Logger.shared.log("CodexBackend enabled via config — starting")
            start()
        } else if config.codexBackendEnabled && old.codexPath != config.codexPath {
            Logger.shared.log("CodexBackend: codexPath changed — restarting app-server")
            let closed: (ids: [String], relay: RelaySink?) = locked {
                startFailures = 0
                nextStartAttempt = .distantPast
                lastStartError = nil
                readySince = nil
                let ids = dropServerRequestsLocked()
                rebuildSnapshotLocked()
                return (ids, _relay)
            }
            client.shutdown()   // the next cycle respawns with the new path
            for id in closed.ids { closed.relay?.sendInterventionClosed(id: id, reason: "session_resolved") }
        } else {
            locked { rebuildSnapshotLocked() }
        }
    }

    /// `closingPages`: tell the phone the pages are gone (the user turned
    /// Codex off). On app quit they stay — the next launch re-syncs them.
    private func stop(closingPages: Bool) {
        let (ids, relay): ([String], RelaySink?) = locked {
            started = false
            generation += 1
            let ids = Array(pendingInterventions.keys)
            threads.removeAll()
            watchedThreadIDs.removeAll()
            threadStates.removeAll()
            threadActivity.removeAll()
            statusHints.removeAll()
            pendingInterventions.removeAll()
            serverRequests.removeAll()
            suppressedIdleIds.removeAll()
            lastRolloutRateLimit = nil
            pushedRateLimit = nil
            currentRateLimit = nil
            readySince = nil
            _hasCompletedFirstScan = false
            lastSnapshot = Self.emptySnapshot
            return (ids, _relay)
        }
        client.shutdown()
        scanQueue.async { [weak self] in
            self?.rolloutCache.removeAll()
            self?.canonicalCwds.removeAll()
        }
        if closingPages {
            for id in ids { relay?.sendInterventionClosed(id: id, reason: "stale") }
        }
    }

    private func isCurrent(_ gen: Int) -> Bool {
        locked { started && generation == gen }
    }

    // MARK: Refresh cycle

    /// Called every tick. Starts one async cycle unless one is still running
    /// (a slow app-server must not stack up overlapping cycles).
    func refresh() {
        let job: (Config, Int)? = locked {
            guard _config.codexBackendEnabled, started, !cycleInFlight else { return nil }
            cycleInFlight = true
            return (_config, generation)
        }
        guard let (cfg, gen) = job else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runCycle(config: cfg, generation: gen)
            self.locked { self.cycleInFlight = false }
        }
    }

    private func runCycle(config cfg: Config, generation gen: Int) async {
        if !client.isReady {
            await bringUpIfDue(generation: gen)
        } else {
            locked {
                // Survived a minute: a later crash is a fresh failure, not
                // part of a crash loop.
                if let since = readySince, Date().timeIntervalSince(since) > 60 { startFailures = 0 }
            }
        }
        // Without the app-server we keep tracking the threads we already know.
        let listed: [ThreadSummary]? = client.isReady ? await listThreads(now: Date()) : nil
        guard isCurrent(gen) else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            scanQueue.async {
                self.scan(listed: listed, config: cfg, generation: gen)
                cont.resume()
            }
        }
    }

    /// Exponential restart backoff: 15s, 30s, 60s, … capped at 5 minutes.
    static func restartDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(15 * pow(2, Double(min(failures, 10) - 1)), 300)
    }

    private func bringUpIfDue(generation gen: Int) async {
        let due = locked { Date() >= nextStartAttempt }
        guard due, isCurrent(gen) else { return }
        do {
            _ = try await client.start(clientName: "Page", clientVersion: Self.clientVersion)
            guard isCurrent(gen) else {
                // Disabled while we were handshaking — don't leave it running.
                client.shutdown()
                return
            }
            locked {
                readySince = Date()
                lastStartError = nil
            }
        } catch {
            let (delay, firstOfKind): (TimeInterval, Bool) = locked {
                startFailures += 1
                let d = Self.restartDelay(afterFailures: startFailures)
                nextStartAttempt = Date().addingTimeInterval(d)
                let message = "\(error)"
                let changed = message != lastStartError
                lastStartError = message
                return (d, changed)
            }
            if firstOfKind {
                Logger.shared.log("CodexBackend: app-server unavailable — \(error). Retrying in \(Int(delay))s, backing off to 5 min (repeats of this error aren't logged).")
            }
        }
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func handleClientExit() {
        let (closed, delay, relay): ([String], TimeInterval, RelaySink?) = locked {
            let uptime = readySince.map { Date().timeIntervalSince($0) } ?? 0
            readySince = nil
            startFailures = uptime >= 60 ? 0 : startFailures + 1
            let d = Self.restartDelay(afterFailures: startFailures)
            nextStartAttempt = Date().addingTimeInterval(d)
            let ids = dropServerRequestsLocked()
            rebuildSnapshotLocked()
            return (ids, d, _relay)
        }
        Logger.shared.log("CodexBackend: app-server exited unexpectedly — restarting in \(Int(delay))s")
        // Requests from the dead child can never be answered now.
        for id in closed { relay?.sendInterventionClosed(id: id, reason: "session_resolved") }
    }

    /// Caller holds `lock`. Returns the closed intervention ids.
    private func dropServerRequestsLocked() -> [String] {
        let ids = Array(serverRequests.keys)
        for id in ids {
            serverRequests[id] = nil
            pendingInterventions[id] = nil
        }
        return ids
    }

    // MARK: Discovery

    private func listThreads(now: Date) async -> [ThreadSummary]? {
        var pages: [[ThreadSummary]] = []
        var cursor: String?
        var attempts = 0
        while pages.count < Self.maxListPages, attempts <= Self.maxListPages {
            attempts += 1
            let sorted = locked { listSupportsSort }
            let params = AppServerProtocol.ThreadListParams(
                limit: Self.listPageSize,
                cursor: cursor,
                sortKey: sorted ? "updated_at" : nil,
                sortDirection: sorted ? "desc" : nil
            )
            let page: AppServerProtocol.ThreadListResult
            do {
                page = try await client.call(method: "thread/list", params: params)
            } catch AppServerClient.ClientError.rpcFailed(let e) where sorted && cursor == nil {
                Logger.shared.log("CodexBackend: thread/list rejected sortKey (rpc \(e.code)) — listing unsorted from now on")
                locked { listSupportsSort = false }
                continue
            } catch {
                let message = "\(error)"
                let firstOfKind: Bool = locked {
                    defer { lastListError = message }
                    return lastListError != message
                }
                if firstOfKind { Logger.shared.log("CodexBackend: thread/list failed — \(error)") }
                return pages.isEmpty ? nil : Self.mergeThreadPages(pages)
            }
            locked { lastListError = nil }
            pages.append(page.data)
            guard let next = page.nextCursor, !next.isEmpty, next != cursor else { break }
            cursor = next
            // Newest-first: once a page ends past the oldest thing we'd page
            // about, later pages can't matter (only trusted if the page
            // really is in descending order).
            if sorted, Self.pageEnds(page.data, olderThan: now.addingTimeInterval(-Self.maxIdlePageAge)) { break }
        }
        return Self.mergeThreadPages(pages)
    }

    /// Dedupe across pages (a thread can move between pages while we page
    /// through), keeping the most recently updated copy, in first-seen order.
    static func mergeThreadPages(_ pages: [[ThreadSummary]]) -> [ThreadSummary] {
        var order: [String] = []
        var byId: [String: ThreadSummary] = [:]
        for thread in pages.joined() {
            if let existing = byId[thread.id] {
                if (thread.updatedAt ?? 0) > (existing.updatedAt ?? 0) { byId[thread.id] = thread }
            } else {
                order.append(thread.id)
                byId[thread.id] = thread
            }
        }
        return order.compactMap { byId[$0] }
    }

    static func pageEnds(_ page: [ThreadSummary], olderThan cutoff: Date) -> Bool {
        let stamps = page.compactMap { $0.updatedAt.map(epochSeconds) }
        guard stamps.count == page.count, let last = stamps.last else { return false }
        let descending = zip(stamps, stamps.dropFirst()).allSatisfy { $0 >= $1 }
        return descending && last < cutoff.timeIntervalSince1970
    }

    /// `updatedAt` is unix seconds; tolerate milliseconds.
    static func epochSeconds(_ raw: Int) -> TimeInterval {
        raw > 10_000_000_000 ? TimeInterval(raw) / 1000 : TimeInterval(raw)
    }

    /// Which threads to watch: recently updated ones, ones whose rollout we
    /// saw written recently (`updatedAt` may only move at turn boundaries,
    /// and freezes while the app-server is down — a long Desktop turn must
    /// not drop out mid-turn), ones with an open page, and — per directory
    /// with a live `codex` — that directory's newest thread (an open TUI,
    /// even if idle for hours). Older threads in the same directory are
    /// history, not sessions.
    static func selectWatched(threads: [ThreadSummary],
                              liveCwds: Set<String>,
                              sticky: Set<String>,
                              recentlyWritten: Set<String> = [],
                              now: Date,
                              canonical: (String) -> String = { $0 }) -> Set<String> {
        var watched = Set<String>()
        var newestPerLiveCwd: [String: ThreadSummary] = [:]
        for t in threads where !t.isSubAgent {
            guard let cwd = t.cwd, !cwd.isEmpty, let path = t.path, !path.isEmpty else { continue }
            if sticky.contains(t.id) || recentlyWritten.contains(t.id) { watched.insert(t.id) }
            if let u = t.updatedAt, now.timeIntervalSince1970 - epochSeconds(u) < recentThreadWindow {
                watched.insert(t.id)
            }
            let key = canonical(cwd)
            guard liveCwds.contains(key) else { continue }
            if let current = newestPerLiveCwd[key], (current.updatedAt ?? 0) >= (t.updatedAt ?? 0) { continue }
            newestPerLiveCwd[key] = t
        }
        watched.formUnion(newestPerLiveCwd.values.map(\.id))
        return watched
    }

    // MARK: Scan (scanQueue)

    private struct ScanEffects {
        var opened: [InterventionEvent] = []
        var closed: [String] = []
        var rateLimit: RateLimitEvent?
        var relay: RelaySink?
        var onNewIntervention: ((InterventionEvent) -> Void)?
        var onNewRateLimit: ((RateLimitEvent) -> Void)?
    }

    private func scan(listed: [ThreadSummary]?, config cfg: Config, generation gen: Int) {
        let now = Date()
        let processes = CodexProcessScanner.liveSessions()
        let liveCwds = Set(processes.compactMap(\.cwd))
        let (known, sticky, recentlyWritten, hints): ([String: ThreadSummary], Set<String>, Set<String>, [String: (state: AgentSessionState, at: Date)]) = locked {
            let stickyIds = Set(pendingInterventions.values.filter { $0.kind == .idle }.map(\.sessionId))
            let written = Set(threadActivity.filter { now.timeIntervalSince($0.value) < Self.recentThreadWindow }.keys)
            return (threads, stickyIds, written, statusHints)
        }

        var all = known
        if let listed {
            var fresh = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // A thread with an open page that fell off the capped listing
            // keeps its last known record rather than silently resolving.
            for id in sticky.union(recentlyWritten) where fresh[id] == nil { fresh[id] = known[id] }
            all = fresh
        }
        let watched = Self.selectWatched(threads: Array(all.values), liveCwds: liveCwds, sticky: sticky,
                                         recentlyWritten: recentlyWritten, now: now, canonical: canonicalCwd)

        var states: [String: AgentSessionState] = [:]
        var activity: [String: Date] = [:]
        var idleCandidates: [String: InterventionEvent] = [:]
        var newestRateLimit: CodexRateLimitSnapshot?
        var scannedPaths = Set<String>()
        for id in watched {
            guard let t = all[id], let path = t.path, !path.isEmpty else { continue }
            scannedPaths.insert(path)
            guard let rollout = rolloutState(path: path) else {
                states[id] = .idle
                continue
            }
            activity[id] = rollout.mtime
            let local = Self.threadIsLocal(t, rolloutPath: path, processes: processes, providerOf: processProvider)
            var state = Self.deriveState(summary: rollout.summary,
                                         rolloutAge: now.timeIntervalSince(rollout.mtime),
                                         activeWindow: cfg.transcriptActivityWindowSeconds,
                                         isLocal: local)
            if let hint = hints[id], hint.at > rollout.mtime { state = hint.state }
            states[id] = state
            if let page = Self.idlePage(thread: t, summary: rollout.summary, rolloutMtime: rollout.mtime,
                                        now: now, idleDelay: cfg.idlePageDelaySeconds),
               Self.shouldPageIdle(source: Self.mapSource(t.source), ownerAlive: {
                   guard let cwd = t.cwd else { return false }
                   return CodexInjector.resolveTarget(cwd: canonicalCwd(cwd), rolloutPath: path, processes: processes,
                                                      cwdFallback: .forSource(Self.mapSource(t.source))) != .none
               }) {
                idleCandidates[page.id] = page
            }
            if let rl = rollout.summary.rateLimit, now.timeIntervalSince(rl.observedAt) < Self.rateLimitLookback,
               rl.observedAt > (newestRateLimit?.observedAt ?? .distantPast) {
                newestRateLimit = rl
            }
        }
        rolloutCache = rolloutCache.filter { scannedPaths.contains($0.key) }
        let livePids = Set(processes.map(\.pid))
        processProviders = processProviders.filter { livePids.contains($0.key) }

        // Idle pages wait until the user has walked away from the Mac (they
        // can see the terminal themselves). Approvals never wait.
        let hasNewCandidate = locked {
            idleCandidates.keys.contains { pendingInterventions[$0] == nil && !suppressedIdleIds.contains($0) }
        }
        let userActive = hasNewCandidate && cfg.idlePageOnlyWhenAwaySeconds > 0
            && UserPresence.isActive(within: cfg.idlePageOnlyWhenAwaySeconds)

        let effects: ScanEffects? = locked {
            guard started, generation == gen else { return nil }
            threads = all
            watchedThreadIDs = watched
            threadStates = states
            threadActivity = activity
            statusHints = statusHints.filter { watched.contains($0.key) }
            _hasCompletedFirstScan = true

            var fx = ScanEffects(relay: _relay, onNewIntervention: _onNewIntervention, onNewRateLimit: _onNewRateLimit)
            for (pid, event) in pendingInterventions where event.kind == .idle && idleCandidates[pid] == nil {
                fx.closed.append(pid)
            }
            for pid in fx.closed { pendingInterventions[pid] = nil }
            suppressedIdleIds.formIntersection(idleCandidates.keys)
            if !userActive {
                for (cid, event) in idleCandidates.sorted(by: { $0.key < $1.key })
                where pendingInterventions[cid] == nil && !suppressedIdleIds.contains(cid) {
                    pendingInterventions[cid] = event
                    fx.opened.append(event)
                }
            }
            // Only a newer snapshot replaces the last one: the thread that hit
            // the wall may stop being watched while the account is still
            // blocked (no turn succeeds, so nothing newer gets written).
            if let fresh = newestRateLimit, fresh.observedAt > (lastRolloutRateLimit?.observedAt ?? .distantPast) {
                lastRolloutRateLimit = fresh
            }
            fx.rateLimit = applyRateLimitLocked(now: now)
            rebuildSnapshotLocked(now: now)
            return fx
        }
        guard let effects else { return }

        for id in effects.closed {
            Logger.shared.log("CodexBackend: RESOLVED idle \(id.prefix(48))")
            effects.relay?.sendInterventionClosed(id: id, reason: "session_resolved")
        }
        let held = effects.opened.isEmpty ? [] : HookHoldMarkers.heldSessions(in: HookHoldMarkers.defaultDirectory)
        let paused = locked { batteryPausedIds }
        for event in effects.opened {
            // A Page hook holding this thread already paged it (Codex Stop /
            // PermissionRequest hook); a battery-paused thread keeps the
            // Coordinator's low-battery page instead (one page per session).
            if held.contains(event.sessionId) || paused.contains(event.sessionId) {
                Logger.shared.log("CodexBackend: idle in \(event.projectName) not paged (\(held.contains(event.sessionId) ? "hook holds it" : "battery-paused"))")
                continue
            }
            Logger.shared.log("CodexBackend: OPENED idle in \(event.projectName) (thread \(event.sessionId.prefix(8)))")
            effects.relay?.sendInterventionOpened(event)
            effects.onNewIntervention?(event)
        }
        if let rl = effects.rateLimit { effects.onNewRateLimit?(rl) }
    }

    /// scanQueue only.
    private func canonicalCwd(_ cwd: String) -> String {
        if let c = canonicalCwds[cwd] { return c }
        let c = CodexProcessScanner.canonicalPath(cwd)
        if canonicalCwds.count > 2000 { canonicalCwds.removeAll() }
        canonicalCwds[cwd] = c
        return c
    }

    /// scanQueue only. The provider of one live codex process, classified
    /// from its argv the first time its (pid, start time) is seen.
    private func processProvider(_ pid: Int32) -> ModelProvider {
        let start = CmuxBridge.processStartSeconds(pid)
        if let hit = processProviders[pid], hit.start == start, start != nil { return hit.provider }
        let provider = ModelProviderClassifier.codex(argv: ProcArgs.read(pid: pid, envKeys: [])?.argv ?? [],
                                                     threadModelProvider: nil)
        if start != nil { processProviders[pid] = (start, provider) }
        return provider
    }

    /// Pure (given `providerOf`). Whether a thread runs on a local model:
    /// the thread's own `modelProvider`, else the argv of a codex process
    /// holding its rollout open.
    static func threadIsLocal(_ t: ThreadSummary, rolloutPath: String, processes: [CodexProcess],
                              providerOf: (Int32) -> ModelProvider) -> Bool {
        if ModelProviderClassifier.codex(argv: [], threadModelProvider: t.modelProvider).isLocal { return true }
        let name = (rolloutPath as NSString).lastPathComponent
        return processes.contains { p in
            p.openRollouts.contains { ($0 as NSString).lastPathComponent == name } && providerOf(p.pid).isLocal
        }
    }

    /// scanQueue only. Re-reads the tail only when the file changed.
    private func rolloutState(path: String) -> (mtime: Date, summary: CodexRollout.Summary)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.uint64Value else {
            rolloutCache[path] = nil
            return nil
        }
        if let cached = rolloutCache[path], cached.mtime == mtime, cached.size == size {
            return (mtime, cached.summary)
        }
        let summary = CodexRollout.summarizeTail(of: URL(fileURLWithPath: path))
        rolloutCache[path] = CachedRollout(mtime: mtime, size: size, summary: summary)
        return (mtime, summary)
    }

    // MARK: State derivation (pure)

    /// `isLocal`: the thread runs on a local model, so a quiet turn is given
    /// `localStalledTurnSeconds` before it stops counting as active.
    static func deriveState(summary: CodexRollout.Summary,
                            rolloutAge: TimeInterval,
                            activeWindow: TimeInterval,
                            isLocal: Bool = false) -> AgentSessionState {
        if let request = summary.pendingRequest, rolloutAge < maxIdlePageAge {
            switch request {
            case .approval: return .waitingOnApproval
            case .userInput: return .waitingOnUser
            }
        }
        switch summary.phase {
        case .inTurn:
            return rolloutAge <= stalledTurnSeconds(isLocal: isLocal) ? .active : .interrupted
        case .unknown:
            // No turn markers in view (brand-new session, or a giant tool
            // output filled the tail): fall back to plain write recency.
            return rolloutAge <= max(activeWindow, 30) ? .active : .idle
        case .completed, .aborted:
            return .idle
        }
    }

    static func idleInterventionId(threadId: String, endedAt: Date) -> String {
        "codex-idle-\(threadId)-\(Int(endedAt.timeIntervalSince1970))"
    }

    /// An idle page for a thread whose last turn completed (not aborted —
    /// the user interrupted it, so they're at the keyboard) at least
    /// `idleDelay` ago. The id is keyed on the turn's end, not the file's
    /// mtime: housekeeping lines (`thread_settings_applied`, …) can land
    /// after `task_complete` without starting a new turn.
    static func idlePage(thread t: ThreadSummary,
                         summary: CodexRollout.Summary,
                         rolloutMtime: Date,
                         now: Date,
                         idleDelay: TimeInterval) -> InterventionEvent? {
        guard summary.phase == .completed, summary.pendingRequest == nil,
              let cwd = t.cwd, !cwd.isEmpty else { return nil }
        let endedAt = summary.turnEndedAt ?? rolloutMtime
        let age = now.timeIntervalSince(endedAt)
        guard age >= max(idleDelay, 10), age <= maxIdlePageAge else { return nil }
        let context = summary.lastAgentMessage.map { String($0.prefix(280)) }
        return InterventionEvent(
            id: idleInterventionId(threadId: t.id, endedAt: endedAt),
            sessionId: t.id,
            cwd: cwd,
            projectName: CodexInjector.projectName(forCwd: cwd),
            kind: .idle,
            openedAt: endedAt,
            context: (context?.isEmpty == false) ? context! : "Codex finished a turn — waiting for input",
            transcriptPath: t.path ?? "",
            backend: .codex,
            source: mapSource(t.source)
        )
    }

    /// Whether a finished turn is worth a page. A terminal session whose
    /// `codex` has exited was closed on purpose; `codex exec` threads are
    /// scripts, not someone waiting. Desktop / VS Code expose no per-thread
    /// process, so they page on the rollout alone.
    static func shouldPageIdle(source: AgentSessionSource, ownerAlive: () -> Bool) -> Bool {
        switch source {
        case .exec: return false
        case .terminal: return ownerAlive()
        case .desktop, .vscode, .remote, .unknown: return true
        }
    }

    /// State hint from an app-server notification, if it carries one.
    /// `thread/status/changed` nests the flags: `{threadId, status: {type,
    /// activeFlags}}` (top-level `activeFlags` accepted for older builds).
    static func statusHint(method: String, params: JSON) -> (threadId: String, state: AgentSessionState)? {
        switch method {
        case "thread/status/changed":
            guard let id = params["threadId"].stringValue ?? params["id"].stringValue else { return nil }
            let status = params["status"]
            let flags = (status["activeFlags"].arrayValue ?? params["activeFlags"].arrayValue ?? [])
                .compactMap(\.stringValue)
            if flags.contains("waitingOnApproval") { return (id, .waitingOnApproval) }
            if flags.contains(where: { $0.hasPrefix("waitingOn") }) { return (id, .waitingOnUser) }
            switch status["type"].stringValue ?? status.stringValue {
            case "active": return (id, .active)
            case "idle", "notLoaded": return (id, .idle)
            case "systemError": return (id, .failed)
            default: return nil   // unknown: keep the rollout-derived state
            }
        case "turn/started":
            return params["threadId"].stringValue.map { ($0, .active) }
        case "turn/completed":
            return params["threadId"].stringValue.map { ($0, .idle) }
        default:
            return nil
        }
    }

    // MARK: Notifications & server requests (client callback queue)

    private func handleNotification(method: String, params: JSON) {
        if let hint = Self.statusHint(method: method, params: params) {
            locked {
                guard watchedThreadIDs.contains(hint.threadId) else { return }
                statusHints[hint.threadId] = (hint.state, Date())
                threadStates[hint.threadId] = hint.state
                rebuildSnapshotLocked()
            }
            return
        }
        switch method {
        case "account/rateLimits/updated":
            guard let snapshot = CodexRateLimitSnapshot.parse(notificationParams: params, observedAt: Date()) else { return }
            let (event, callback): (RateLimitEvent?, ((RateLimitEvent) -> Void)?) = locked {
                guard started else { return (nil, nil) }
                pushedRateLimit = snapshot
                let e = applyRateLimitLocked(now: Date())
                rebuildSnapshotLocked()
                return (e, _onNewRateLimit)
            }
            if let event { callback?(event) }
        case "serverRequest/resolved":
            closeResolvedServerRequest(params: params)
        default:
            let first = locked { loggedUnhandledMethods.insert(method).inserted }
            if first { Logger.shared.log("Codex notification (unhandled, logged once): \(method)") }
        }
    }

    /// Approval requests become `.permission` pages answered with a JSON-RPC
    /// decision. Anything else returns false → the client answers -32601.
    private func handleServerRequest(_ request: AppServerClient.ServerRequest) -> Bool {
        let subtype: String
        switch request.method {
        case AppServerProtocol.ServerRequestMethod.commandExecutionApproval: subtype = "command"
        case AppServerProtocol.ServerRequestMethod.fileChangeApproval: subtype = "fileChange"
        default: return false
        }
        let (cfg, relay, isStarted): (Config, RelaySink?, Bool) = locked { (_config, _relay, started) }
        guard isStarted, cfg.relayEnabled, let relay else {
            // No phone to ask: decline rather than leave the turn hanging.
            client.respond(to: request, result: AppServerProtocol.ApprovalResponse(decision: "decline"))
            Logger.shared.log("CodexBackend: declined \(request.method) — relay is off, nobody could answer it")
            return true
        }
        let threadId = request.params["threadId"].stringValue
        let thread = threadId.flatMap { tid in locked { threads[tid] } }
        let cwd = thread?.cwd ?? request.params["cwd"].stringValue ?? ""
        let token = "\(request.childToken)-\(Self.idSafe(request.id.description))"
        let event = InterventionEvent(
            id: "codex-req-\(token)",
            sessionId: threadId ?? "codex-unknown-\(token)",
            cwd: cwd,
            projectName: cwd.isEmpty ? "Codex" : CodexInjector.projectName(forCwd: cwd),
            kind: .permission,
            openedAt: Date(),
            context: Self.approvalContext(request.params),
            transcriptPath: thread?.path ?? "",
            backend: .codex,
            source: Self.mapSource(thread?.source),
            subtype: subtype
        )
        let callback: ((InterventionEvent) -> Void)? = locked {
            pendingInterventions[event.id] = event
            serverRequests[event.id] = request
            rebuildSnapshotLocked()
            return _onNewIntervention
        }
        Logger.shared.log("CodexBackend: OPENED approval (\(subtype)) in \(event.projectName) req=\(request.id)")
        relay.sendInterventionOpened(event)
        callback?(event)
        return true
    }

    private func closeResolvedServerRequest(params: JSON) {
        guard let rid = AppServerProtocol.RequestID(json: params.first("requestId", "id")) else { return }
        let (ids, relay): ([String], RelaySink?) = locked {
            let ids = serverRequests.filter { $0.value.id == rid }.map(\.key)
            for id in ids {
                serverRequests[id] = nil
                pendingInterventions[id] = nil
            }
            if !ids.isEmpty { rebuildSnapshotLocked() }
            return (ids, _relay)
        }
        for id in ids {
            Logger.shared.log("CodexBackend: server request \(rid) resolved elsewhere — closing \(id)")
            relay?.sendInterventionClosed(id: id, reason: "session_resolved")
        }
    }

    static func approvalContext(_ params: JSON) -> String {
        if let cmd = params["command"].stringValue { return "$ \(cmd)" }
        if let argv = params["command"].arrayValue?.compactMap(\.stringValue), !argv.isEmpty {
            return "$ \(argv.joined(separator: " "))"
        }
        if let reason = params["reason"].stringValue, !reason.isEmpty { return reason }
        return "Codex is asking for approval"
    }

    /// Keeps intervention ids within the Worker's charset/length limits.
    static func idSafe(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(String(mapped).prefix(64))
    }

    // MARK: Rate limits

    /// Caller holds `lock`. Applies the newest snapshot (rollout or pushed):
    /// it stays in force until a newer snapshot says otherwise or its reset
    /// passes. Returns an event only the first time a given limit is seen.
    private func applyRateLimitLocked(now: Date) -> RateLimitEvent? {
        let newest = [lastRolloutRateLimit, pushedRateLimit].compactMap { $0 }.max { $0.observedAt < $1.observedAt }
        guard let snapshot = newest, let until = snapshot.limitedUntil, until > now else {
            if let cleared = currentRateLimit {
                Logger.shared.log("Codex rate limit cleared (was \(cleared.resetTimeText))")
                currentRateLimit = nil
            }
            return nil
        }
        let key = "\(snapshot.limitId)-\(Int(until.timeIntervalSince1970) / 60)"
        let firstSeen = rateLimitFirstSeen[key] ?? snapshot.observedAt
        rateLimitFirstSeen = [key: firstSeen]
        // Account-level: not tied to a thread or project, and never resumable.
        let event = RateLimitEvent(
            sessionId: "codex-account",
            cwd: "",
            projectName: "Codex account",
            eventTime: firstSeen,
            resetTime: until,
            resetTimeText: Self.formatResetText(until),
            transcriptPath: "",
            backend: .codex
        )
        currentRateLimit = event
        guard notifiedRateLimitKeys.insert(key).inserted else { return nil }
        if notifiedRateLimitKeys.count > 100 { notifiedRateLimitKeys = [key] }
        Logger.shared.log("Codex rate limit reached: limit=\(snapshot.limitId) \(event.resetTimeText)")
        return event
    }

    private static func formatResetText(_ d: Date) -> String {
        let df = DateFormatter()
        df.dateStyle = Calendar.current.isDateInToday(d) ? .none : .medium
        df.timeStyle = .short
        return "resets \(df.string(from: d))"
    }

    // MARK: Replies (replyQueue)

    /// Called by the Coordinator on a background queue; deliveries are
    /// serialised here so keystrokes for two replies never interleave.
    func handleReply(_ reply: RelayReply) {
        if Thread.isMainThread {
            replyQueue.async { [weak self] in self?.deliver(reply) }
        } else {
            replyQueue.sync { deliver(reply) }
        }
    }

    private func deliver(_ reply: RelayReply) {
        let id = reply.interventionId
        // Blocking-hook replies are answered by the hook itself.
        guard !id.hasPrefix("hookpre-") else { return }
        // A repeat of a reply whose background resume is still running:
        // its result is reported when that run finishes.
        guard !execGate.isReplyInFlight(id) else {
            Logger.shared.log("CodexBackend: reply \(id.prefix(48)) ignored — background resume already running for it")
            return
        }
        let (request, pending, cfg): (AppServerClient.ServerRequest?, InterventionEvent?, Config) = locked {
            (serverRequests[id], pendingInterventions[id], _config)
        }
        if let request {
            finishReply(id, outcome: answerServerRequest(request, reply: reply))
            return
        }
        switch deliverToSession(reply: reply, pending: pending, config: cfg) {
        case .finished(let outcome):
            finishReply(id, outcome: outcome)
        case .needsExecResume(let job):
            startExecResume(job, interventionId: id)
        }
    }

    /// Hands a background resume to `execQueue` so `replyQueue` (and the
    /// low-battery pause/resume behind it) never waits on an agent turn.
    private func startExecResume(_ job: CodexInjector.ExecResumeJob, interventionId id: String) {
        switch execGate.begin(threadId: job.threadId, interventionId: id) {
        case .duplicateReply:
            Logger.shared.log("CodexBackend: reply \(id.prefix(48)) ignored — background resume already running for it")
            return
        case .threadBusy:
            finishReply(id, outcome: .failure("A background Codex resume is already running for this session — reply once it finishes",
                                              method: CodexInjector.Method.execResume))
            return
        case .started:
            break
        }
        Logger.shared.log("CodexBackend: reply \(id.prefix(48)) → background resume queued for thread \(job.threadId.prefix(8))")
        execQueue.async { [weak self] in
            guard let self else { return }
            defer { self.execGate.end(threadId: job.threadId, interventionId: id) }
            // Re-checked right before launching: the turn must still be over
            // (runExecResume re-checks that no live codex owns the thread).
            let outcome: CodexDeliveryOutcome
            let summary = job.rolloutPath.map { CodexRollout.summarizeTail(of: URL(fileURLWithPath: $0)) } ?? CodexRollout.Summary()
            if !Self.execResumeMayStart(summary: summary) {
                outcome = .failure("Codex started working on this session again — reply once the turn finishes",
                                   method: CodexInjector.Method.execResume)
            } else {
                outcome = CodexInjector.runExecResume(job)
            }
            self.finishReply(id, outcome: outcome)
        }
    }

    /// Pure. A queued background resume may still start only while the
    /// thread's latest turn is over and nothing waits on a prompt.
    static func execResumeMayStart(summary: CodexRollout.Summary) -> Bool {
        summary.pendingRequest == nil && (summary.phase == .completed || summary.phase == .aborted)
    }

    /// Reports one reply's result to the phone and, on success, closes its
    /// page. Any queue.
    private func finishReply(_ id: String, outcome: CodexDeliveryOutcome) {
        Logger.shared.log("CodexBackend: reply \(id.prefix(48)) → method=\(outcome.method) success=\(outcome.success) — \(outcome.detail)")
        let relay = self.relay
        relay?.sendReplyInjected(interventionId: id, method: outcome.method, success: outcome.success,
                                 detail: outcome.detail, output: outcome.output)
        guard outcome.success else { return }
        relay?.sendInterventionClosed(id: id, reason: "replied")
        locked {
            pendingInterventions[id] = nil
            serverRequests[id] = nil
            if id.hasPrefix("codex-idle-") { suppressedIdleIds.insert(id) }
            rebuildSnapshotLocked()
        }
    }

    private func answerServerRequest(_ request: AppServerClient.ServerRequest, reply: RelayReply) -> CodexDeliveryOutcome {
        let method = "codex_app_server"
        let hasText = !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let decision: String
        switch reply.action {
        case "approve": decision = "accept"
        case "deny": decision = "decline"
        case "carry_on": return .failure("This page needs Approve or Deny", method: method)
        default:
            // A typed answer to an approval means "no, do this instead"
            // (same as Claude's Esc + text); the protocol can't carry text.
            guard hasText else { return .failure("Empty reply — nothing to send", method: method) }
            decision = "decline"
        }
        guard client.respond(to: request, result: AppServerProtocol.ApprovalResponse(decision: decision)) else {
            return .failure("The Codex app-server restarted — that request is gone", method: method)
        }
        if decision == "accept" {
            return CodexDeliveryOutcome(method: method, success: true, detail: "Approved in Codex", output: nil)
        }
        let detail = (reply.action == "deny") ? "Declined in Codex" : "Declined in Codex (approvals can't carry a message)"
        return CodexDeliveryOutcome(method: method, success: true, detail: detail, output: nil)
    }

    private func deliverToSession(reply: RelayReply, pending: InterventionEvent?, config cfg: Config) -> CodexInjector.DeliveryStep {
        let threadId = pending?.sessionId ?? reply.sessionId ?? ""
        guard !threadId.isEmpty, let thread = lookupThread(threadId),
              let cwd = thread.cwd, !cwd.isEmpty else {
            return .finished(.failure("Page no longer knows this Codex session — reply on the Mac"))
        }
        // A background resume is writing to this thread (possibly before its
        // first rollout line): nothing else may type into it meanwhile.
        if execGate.isThreadBusy(thread.id) {
            return .finished(.failure("A background Codex resume is running for this session — reply once it finishes"))
        }
        // Fresh read (not the scan cache): the decision must reflect the
        // rollout as it is right now.
        let summary: CodexRollout.Summary = {
            guard let path = thread.path, !path.isEmpty else { return CodexRollout.Summary() }
            return CodexRollout.summarizeTail(of: URL(fileURLWithPath: path))
        }()
        let plan = Self.replyPlan(action: reply.action, text: reply.text,
                                  kind: pending?.kind.rawValue ?? reply.kind,
                                  summary: summary)
        switch plan {
        case .refuse(let why):
            return .finished(.failure(why))
        case .type(let text):
            return CodexInjector.deliver(text: text, threadId: thread.id, cwd: cwd,
                                         rolloutPath: thread.path, codexPath: cfg.codexPath,
                                         allowExecResume: cfg.headlessResumeFallbackEnabled,
                                         cwdFallback: .forSource(Self.mapSource(thread.source)))
        }
    }

    enum ReplyPlan: Equatable {
        case type(String)
        case refuse(String)
    }

    /// Whether (and what) to type into a Codex session. Typing is only safe
    /// once the latest turn has ended: mid-turn an approval overlay may be on
    /// screen, and it takes letters as hotkeys ("y" approves).
    static func replyPlan(action: String?, text: String, kind: String?, summary: CodexRollout.Summary) -> ReplyPlan {
        if let kind, ["permission", "plan", "approval"].contains(kind) {
            return .refuse("Answer Codex approval prompts on your Mac — Page can't approve them remotely yet")
        }
        if summary.pendingRequest != nil {
            return .refuse("Codex is waiting on a prompt — answer it on the Mac")
        }
        switch summary.phase {
        case .inTurn:
            return .refuse("Codex is still working — reply once the turn finishes")
        case .unknown:
            return .refuse("Couldn't confirm Codex is waiting for input — reply on the Mac")
        case .completed, .aborted:
            break
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return .type(trimmed) }
        switch action {
        case "approve": return .type("yes, proceed")
        case "deny": return .type("no, stop")
        case "carry_on": return .type("carry on")
        default: return .refuse("Empty reply — nothing to send")
        }
    }

    // MARK: Phone sessions view (SessionRemote)

    /// The thread's record from the last listing (cwd, source, rollout
    /// path, model provider), for the phone's list. Never asks the
    /// app-server.
    func remoteThread(_ id: String) -> ThreadSummary? {
        locked { threads[id] }
    }

    /// Text typed on the phone's Sessions screen, on `replyQueue` (one at a
    /// time with replies and the battery pause). After the turn: typed
    /// with the composer verified empty. Mid-turn: only into a cmux pane
    /// whose composer cmux reads as empty (the battery queue path). Never
    /// `exec resume`. `completion` runs on `replyQueue`.
    func remoteInput(threadId: String, text raw: String, interventionId: String?,
                     completion: @escaping (SessionCommandResult) -> Void) {
        replyQueue.async { [weak self] in
            guard let self else { return completion(.failed("Codex isn't being watched any more")) }
            let text: String
            switch SessionInputGate.validateText(raw) {
            case .failure(let refusal): return completion(refusal)
            case .success(let t): text = t
            }
            guard let t = self.locked({ self.threads[threadId] }), let cwd = t.cwd, !cwd.isEmpty,
                  let path = t.path, !path.isEmpty else {
                return completion(.refused(.notFound, "Page no longer knows this Codex session"))
            }
            let rollout = URL(fileURLWithPath: path)
            let summary = CodexRollout.summarizeTail(of: rollout)
            let reach = Self.remoteTerminal(thread: t, cwd: cwd, path: path)
            // Right before the keys (after the slow lookups above).
            let recheck = {
                SessionInputGate.codexRecheck(planned: summary.phase, now: CodexRollout.summarizeTail(of: rollout),
                                              interrupt: false, interventionId: interventionId)
            }
            let step = SessionInputGate.codexPlan(phase: summary.phase, hasPendingRequest: summary.pendingRequest != nil,
                                                  execResumeRunning: self.execGate.isThreadBusy(t.id),
                                                  terminal: reach.terminal, targetProblem: reach.problem,
                                                  interventionId: interventionId)
            let clean = CodexInjector.sanitize(text)
            switch step {
            case .refuse(let r):
                completion(r)
            case .deliverIdle:
                guard let terminal = reach.terminal else { return completion(.failed("Couldn't find the Codex session's terminal")) }
                if let why = CodexInjector.composerRefusal(terminal) {
                    return completion(SessionInputGate.codexResult(.failure(why, method: terminal.method), queued: false,
                                                                   interventionId: interventionId))
                }
                if let changed = recheck() { return completion(changed) }
                completion(SessionInputGate.codexResult(CodexInjector.type(clean, into: terminal), queued: false,
                                                        interventionId: interventionId))
            case .queueMidTurn:
                guard let terminal = reach.terminal, let pid = reach.pid, ProcessRunner.isForeground(pid: pid) == true else {
                    return completion(.refused(.notTypable, CodexInjector.notForegroundDetail))
                }
                if let changed = recheck() { return completion(changed) }
                completion(SessionInputGate.codexResult(CodexInjector.type(clean, into: terminal), queued: true,
                                                        interventionId: interventionId))
            }
        }
    }

    /// The phone's Stop button: Esc in a thread whose turn is running, in
    /// tmux or cmux (cmux refuses while a dialog is open).
    func remoteInterrupt(threadId: String, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
        replyQueue.async { [weak self] in
            guard let self else { return completion(.failed("Codex isn't being watched any more")) }
            guard let t = self.locked({ self.threads[threadId] }), let cwd = t.cwd, !cwd.isEmpty,
                  let path = t.path, !path.isEmpty else {
                return completion(.refused(.notFound, "Page no longer knows this Codex session"))
            }
            guard !self.execGate.isThreadBusy(t.id) else {
                return completion(.refused(.interruptUnsupported, "Page's background resume is driving this turn"))
            }
            let rollout = URL(fileURLWithPath: path)
            let summary = CodexRollout.summarizeTail(of: rollout)
            if summary.pendingRequest != nil {
                return completion(.refused(.waiting, SessionInputGate.codexWaitingMessage, interventionId: interventionId))
            }
            guard summary.phase == .inTurn else {
                return completion(.refused(.interruptUnsupported, SessionInputGate.notIdleMessage))
            }
            let reach = Self.remoteTerminal(thread: t, cwd: cwd, path: path)
            switch reach.terminal {
            case .tmux?, .cmux?:
                // Again right before Esc: tmux has no dialog check of its
                // own, and Esc on an approval overlay denies it.
                if let changed = SessionInputGate.codexRecheck(planned: summary.phase, now: CodexRollout.summarizeTail(of: rollout),
                                                               interrupt: true, interventionId: interventionId) {
                    return completion(changed)
                }
                let r = CodexInjector.interrupt(reach.terminal!)
                completion(r.success
                    ? SessionCommandResult(code: .delivered, reason: nil, detail: r.detail)
                    : (r.detail == "A prompt is open in that pane"
                        ? .refused(.waiting, r.detail, interventionId: interventionId)
                        : .failed(r.detail)))
            case .terminalApp?:
                completion(.refused(.interruptUnsupported, "Page can't press Esc in Terminal.app"))
            case .unavailable(let why)?:
                completion(.refused(.interruptUnsupported, why))
            case nil:
                completion(reach.problem ?? .refused(.interruptUnsupported, "Couldn't find the Codex session's terminal"))
            }
        }
    }

    /// Where a thread's codex can be reached right now. Fresh ps + lsof.
    private static func remoteTerminal(thread t: ThreadSummary, cwd: String, path: String)
        -> (terminal: CodexInjector.Terminal?, pid: Int32?, problem: SessionCommandResult?) {
        let table = ProcessRunner.processTable()
        guard !table.isEmpty else {
            return (nil, nil, .refused(.notTypable, "Couldn't check whether Codex is still open"))
        }
        let processes = CodexProcessScanner.liveSessions(table: table)
        let target = CodexInjector.resolveTarget(cwd: CodexProcessScanner.canonicalPath(cwd), rolloutPath: path,
                                                 processes: processes, cwdFallback: .forSource(mapSource(t.source)))
        guard case .tty(let tty, let pid) = target else {
            return (nil, nil, SessionInputGate.codexTargetProblem(target, project: CodexInjector.projectName(forCwd: cwd)))
        }
        return (CodexInjector.terminal(tty: tty, pid: pid, threadId: t.id, table: table), pid, nil)
    }

    /// Thread record from the last listing, else asked of the app-server.
    private func lookupThread(_ id: String) -> ThreadSummary? {
        if let t = locked({ threads[id] }) { return t }
        guard client.isReady else { return nil }
        let box = LockedBox<ThreadSummary>()
        let done = DispatchSemaphore(value: 0)
        let client = self.client
        Task.detached {
            let result: AppServerProtocol.ThreadReadResult? = try? await client.call(
                method: "thread/read",
                params: AppServerProtocol.ThreadReadParams(threadId: id),
                timeout: 5
            )
            box.value = result?.thread
            done.signal()
        }
        _ = done.wait(timeout: .now() + 7)
        return box.value
    }

    // MARK: Snapshot

    /// Caller holds `lock`.
    private func rebuildSnapshotLocked(now: Date = Date()) {
        let sessions: [AgentSession] = watchedThreadIDs.compactMap { id in
            guard let t = threads[id] else { return nil }
            let state = threadStates[id] ?? .idle
            return AgentSession(
                backend: .codex,
                sessionId: t.id,
                cwd: t.cwd,
                title: t.displayTitle,
                source: Self.mapSource(t.source),
                state: state,
                lastActivityAt: threadActivity[id] ?? t.updatedAt.map { Date(timeIntervalSince1970: Self.epochSeconds($0)) },
                activeFlags: state == .waitingOnApproval ? ["waitingOnApproval"] : [],
                supportsRemoteReply: !(t.cwd ?? "").isEmpty
            )
        }.sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }

        // Awake while a session works or waits, and for a bounded time while
        // a page waits for its reply (so the reply can still be delivered).
        let sessionsWantPower = sessions.contains { [.active, .waitingOnUser, .waitingOnApproval].contains($0.state) }
        let holdWindow = _config.holdAwakeForPendingPageMinutes * 60
        let pagesWantPower = holdWindow > 0
            && pendingInterventions.values.contains { now.timeIntervalSince($0.openedAt) < holdWindow }

        lastSnapshot = AgentBackendSnapshot(
            backendID: .codex,
            displayName: displayName,
            sessions: sessions,
            wantsPowerAssertion: sessionsWantPower || pagesWantPower,
            pendingInterventions: pendingInterventions.values.sorted { $0.openedAt < $1.openedAt },
            currentRateLimit: currentRateLimit
        )
    }

    static func mapSource(_ raw: String?) -> AgentSessionSource {
        switch raw?.lowercased() {
        case "cli": return .terminal
        case "vscode": return .vscode
        case "desktop", "appserver": return .desktop
        case "exec": return .exec
        case "remote": return .remote
        default: return .unknown
        }
    }

    @discardableResult
    private func locked<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// Tiny thread-safe slot for handing a value back from a Task.
private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

// MARK: - Rollout tail analysis

/// Reads the end of a Codex rollout JSONL and summarises where the session
/// is. Every line is `{timestamp, type, payload}`. Verified against real
/// rollouts (codex 0.13x–0.14x):
///   - a turn starts with `event_msg/task_started` and ends with
///     `event_msg/task_complete` (carries `last_agent_message`) or
///     `event_msg/turn_aborted` (the user interrupted);
///   - `response_item` lines (messages, tool calls, outputs) only occur
///     inside a turn;
///   - housekeeping can follow a turn's end without starting a new one
///     (`thread_settings_applied` when the user changes settings), and
///     `token_count`/`world_state`/`turn_context` carry no phase;
///   - approval requests are NOT persisted. The `*_approval_request` /
///     `request_user_input` handling below is forward-compatibility only.
enum CodexRollout {
    struct Summary: Equatable {
        enum Phase: Equatable {
            case unknown
            case inTurn
            case completed
            case aborted
        }
        enum PendingRequest: Equatable {
            case approval(String)
            case userInput(String)
        }

        var phase: Phase = .unknown
        /// Timestamp of the line that ended the latest turn.
        var turnEndedAt: Date?
        var lastAgentMessage: String?
        var pendingRequest: PendingRequest?
        /// Latest rate-limit snapshot (from `token_count`).
        var rateLimit: CodexRateLimitSnapshot?
    }

    static let tailBytes = 64 * 1024
    static let extendedTailBytes = 1024 * 1024

    static func summarizeTail(of url: URL) -> Summary {
        guard let tail = readTail(of: url, maxBytes: tailBytes) else { return Summary() }
        let summary = summarize(text: tail.text)
        // One huge tool output can fill the whole window with a partial line.
        if summary.phase == .unknown, tail.truncated,
           let wider = readTail(of: url, maxBytes: extendedTailBytes) {
            return summarize(text: wider.text)
        }
        return summary
    }

    static func summarize(text: String) -> Summary {
        var s = Summary()
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? decoder.decode(AppServerProtocol.JSON.self, from: Data(line.utf8)) else { continue }
            let timestamp = obj["timestamp"].stringValue.flatMap(parseTimestamp)
            let payload = obj["payload"]
            switch obj["type"].stringValue {
            case "event_msg":
                switch payload["type"].stringValue {
                case "task_started", "turn_started":
                    s.phase = .inTurn
                    s.pendingRequest = nil
                    s.lastAgentMessage = nil
                case "task_complete", "turn_complete":
                    s.phase = .completed
                    s.pendingRequest = nil
                    s.turnEndedAt = timestamp ?? epochDate(payload["completed_at"]) ?? s.turnEndedAt
                    if let message = payload["last_agent_message"].stringValue, !message.isEmpty {
                        s.lastAgentMessage = message
                    }
                case "turn_aborted":
                    s.phase = .aborted
                    s.pendingRequest = nil
                    s.turnEndedAt = timestamp ?? epochDate(payload["completed_at"]) ?? s.turnEndedAt
                case "exec_approval_request":
                    s.phase = .inTurn
                    s.pendingRequest = .approval(commandText(payload["command"]).map { "$ \($0)" } ?? "Codex wants to run a command")
                case "apply_patch_approval_request":
                    s.phase = .inTurn
                    s.pendingRequest = .approval("Codex wants to edit files")
                case "request_user_input":
                    s.phase = .inTurn
                    let question = payload["questions"].arrayValue?.first?["question"].stringValue
                    s.pendingRequest = .userInput(question ?? "Codex is asking a question")
                case "token_count":
                    let limits = payload["rate_limits"]
                    if !limits.isNull, let snapshot = CodexRateLimitSnapshot.parse(limits, observedAt: timestamp ?? Date()) {
                        s.rateLimit = snapshot
                    }
                default:
                    break   // housekeeping; carries no phase
                }
            case "response_item":
                // Activity: we're in a turn (even if its start scrolled out of
                // the tail), and any open request has been answered.
                s.phase = .inTurn
                s.pendingRequest = nil
                if payload["type"].stringValue == "message", payload["role"].stringValue == "assistant",
                   let parts = payload["content"].arrayValue {
                    let text = parts.compactMap { $0["text"].stringValue }.filter { !$0.isEmpty }.last
                    if let text { s.lastAgentMessage = text }
                }
            default:
                break
            }
        }
        return s
    }

    /// Last `maxBytes` of a file. When it starts mid-file, the partial first
    /// line is cut at the byte level *before* decoding, so a seek that lands
    /// inside a multi-byte character can't make the whole tail undecodable.
    static func readTail(of url: URL, maxBytes: Int) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let truncated = size > UInt64(maxBytes)
        do {
            try handle.seek(toOffset: truncated ? size - UInt64(maxBytes) : 0)
        } catch {
            return nil
        }
        let data = (try? handle.readToEnd()) ?? Data()
        return (tailText(from: data, droppingPartialFirstLine: truncated), truncated)
    }

    static func tailText(from data: Data, droppingPartialFirstLine: Bool) -> String {
        var slice = data[...]
        if droppingPartialFirstLine {
            guard let nl = slice.firstIndex(of: 0x0A) else { return "" }
            slice = slice[slice.index(after: nl)...]
        }
        // Lossy: a stray invalid byte costs one line, not the whole tail.
        return String(decoding: slice, as: UTF8.self)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    static func parseTimestamp(_ s: String) -> Date? {
        fractionalFormatter.date(from: s) ?? plainFormatter.date(from: s)
    }

    private static func epochDate(_ v: AppServerProtocol.JSON) -> Date? {
        guard let n = v.doubleValue, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }

    private static func commandText(_ v: AppServerProtocol.JSON) -> String? {
        if let s = v.stringValue { return s }
        if let argv = v.arrayValue?.compactMap(\.stringValue), !argv.isEmpty { return argv.joined(separator: " ") }
        return nil
    }
}

// MARK: - Rate limits

/// A Codex `RateLimitSnapshot`, in either spelling: snake_case in rollout
/// `token_count` events (`{limit_id, primary: {used_percent, resets_at},
/// secondary, rate_limit_reached_type}`), camelCase over the protocol
/// (`account/rateLimits/updated` → `{rateLimits: {limitId, primary: {usedPercent,
/// resetsAt}, …}}`), plus the flat `{limitId, usedPercent, resetsAt}` an
/// older spec described.
struct CodexRateLimitSnapshot: Equatable {
    struct Window: Equatable {
        let usedPercent: Double
        let resetsAt: Date?
    }

    let limitId: String
    let windows: [Window]
    let reachedType: String?
    let observedAt: Date

    /// When the account is blocked: the reset of the exhausted window(s)
    /// (the later one if several). Nil when not limited, or limited with no
    /// known reset (nothing useful to show or hold awake for).
    var limitedUntil: Date? {
        let exhausted = windows.filter { $0.usedPercent >= 100 }
        guard !exhausted.isEmpty || reachedType != nil else { return nil }
        let relevant = exhausted.isEmpty ? windows : exhausted
        return relevant.compactMap(\.resetsAt).max()
    }

    static func parse(_ snapshot: AppServerProtocol.JSON, observedAt: Date) -> CodexRateLimitSnapshot? {
        guard snapshot.objectValue != nil else { return nil }
        var windows: [Window] = []
        for key in ["primary", "secondary"] {
            let w = snapshot[key]
            guard w.objectValue != nil, let used = w.first("used_percent", "usedPercent").doubleValue else { continue }
            windows.append(Window(usedPercent: used, resetsAt: epochDate(w.first("resets_at", "resetsAt"))))
        }
        if windows.isEmpty, let used = snapshot.first("used_percent", "usedPercent").doubleValue {
            windows.append(Window(usedPercent: used, resetsAt: epochDate(snapshot.first("resets_at", "resetsAt"))))
        }
        let reached = snapshot.first("rate_limit_reached_type", "rateLimitReachedType").stringValue
        guard !windows.isEmpty || reached != nil else { return nil }
        return CodexRateLimitSnapshot(
            limitId: snapshot.first("limit_id", "limitId").stringValue ?? "codex",
            windows: windows,
            reachedType: reached,
            observedAt: observedAt
        )
    }

    static func parse(notificationParams params: AppServerProtocol.JSON, observedAt: Date) -> CodexRateLimitSnapshot? {
        let nested = params["rateLimits"]
        return parse(nested.isNull ? params : nested, observedAt: observedAt)
    }

    private static func epochDate(_ v: AppServerProtocol.JSON) -> Date? {
        guard let n = v.doubleValue, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 10_000_000_000 ? n / 1000 : n)
    }
}

// MARK: - Low-battery pause

extension CodexBackend: BatteryPausable {
    /// How one working Codex session is asked to pause.
    enum PauseStrategy: Equatable {
        /// Esc (interrupts the turn), then type the message once the
        /// rollout shows the turn ended.
        case interrupt
        /// Type the message mid-turn. Only into a cmux pane whose composer
        /// cmux reads as empty: an approval overlay takes letters as
        /// hotkeys, so blind mid-turn typing could approve something.
        case queue(reason: String)
        case skip(String)
    }

    /// Pure. A thread on a local model (`isLocal`) only ever gets Esc — no
    /// summary request for the local model to generate on battery — so it
    /// is skipped wherever Esc can't be pressed or the user chose "after
    /// the current step"; the Mac sleeps at the cutoff anyway.
    static func pauseStrategy(terminal: CodexInjector.Terminal, mode: LowBatteryAction,
                              isLocal: Bool = false) -> PauseStrategy {
        if isLocal, mode != .off {
            switch terminal {
            case .unavailable(let why): return .skip(why)
            case .tmux, .cmux:
                return mode == .pause ? .interrupt : .skip("local model — Page doesn't queue a summary request on battery")
            case .terminalApp:
                return .skip("local model, and Terminal.app can't press Esc")
            }
        }
        switch (mode, terminal) {
        case (.off, _):
            return .skip("low-battery action is off")
        case (_, .unavailable(let why)):
            return .skip(why)
        case (.pause, .tmux), (.pause, .cmux):
            return .interrupt
        case (.afterTurn, .cmux):
            return .queue(reason: "it stops after the current step")
        case (.afterTurn, .tmux), (.afterTurn, .terminalApp):
            return .skip("Codex can't be messaged mid-turn there without risking an approval hotkey")
        case (.pause, .terminalApp):
            return .skip("Terminal.app can't press Esc, and typing mid-turn could hit an approval hotkey")
        }
    }

    func pauseBusySessions(message: String) -> [PausedSession] {
        pauseBusySessions(message: message, mode: config.lowBatteryAction)
    }

    private var config: Config { locked { _config } }

    /// Asks every working Codex terminal session to stop. Serialised with
    /// phone replies on `replyQueue`; blocks the caller (never main).
    func pauseBusySessions(message: String, mode: LowBatteryAction) -> [PausedSession] {
        guard mode != .off else { return [] }
        guard !Thread.isMainThread else {
            Logger.shared.log("CodexBackend: low-battery pause refused on the main thread (would deadlock)")
            return []
        }
        let paused = replyQueue.sync { runPause(message: message, mode: mode) }
        locked { batteryPausedIds.formUnion(paused.map(\.sessionId)) }
        return paused
    }

    private struct PauseWork {
        let thread: ThreadSummary
        let path: String
        let cwd: String
        let pid: Int32
        let terminal: CodexInjector.Terminal
        var strategy: PauseStrategy
        var isLocal = false
        var pausedAt = Date()
        var escSent = false
        var turnEnded = false
    }

    /// replyQueue only.
    private func runPause(message: String, mode: LowBatteryAction) -> [PausedSession] {
        let (known, states) = locked { (threads, threadStates) }
        let table = ProcessRunner.processTable()
        guard !table.isEmpty else { return [] }
        let processes = CodexProcessScanner.liveSessions(table: table)
        var work: [PauseWork] = []
        for (id, state) in states where state == .active {
            guard let t = known[id], let path = t.path, !path.isEmpty, let cwd = t.cwd, !cwd.isEmpty else { continue }
            // Page's own background resume is driving this turn: it has no
            // terminal, and Esc must not land in some other codex.
            guard !execGate.isThreadBusy(id) else {
                Logger.shared.log("CodexBackend: low-battery pause skipped \(id.prefix(8)) — background resume running")
                continue
            }
            // Fresh read: the scan's state can be a tick old.
            let summary = CodexRollout.summarizeTail(of: URL(fileURLWithPath: path))
            guard summary.phase == .inTurn, summary.pendingRequest == nil else { continue }
            guard case .tty(let tty, let pid) = CodexInjector.resolveTarget(
                cwd: CodexProcessScanner.canonicalPath(cwd), rolloutPath: path, processes: processes,
                cwdFallback: .forSource(Self.mapSource(t.source))) else {
                Logger.shared.log("CodexBackend: low-battery pause skipped \(id.prefix(8)) — no terminal Page can reach")
                continue
            }
            let terminal = CodexInjector.terminal(tty: tty, pid: pid, threadId: t.id, table: table)
            let isLocal = ModelProviderClassifier.codex(argv: ProcArgs.read(pid: pid, envKeys: [])?.argv ?? [],
                                                        threadModelProvider: t.modelProvider).isLocal
            let strategy = Self.pauseStrategy(terminal: terminal, mode: mode, isLocal: isLocal)
            if case .skip(let why) = strategy {
                Logger.shared.log("CodexBackend: low-battery pause skipped \(id.prefix(8)) — \(why)")
                continue
            }
            work.append(PauseWork(thread: t, path: path, cwd: cwd, pid: pid, terminal: terminal, strategy: strategy,
                                  isLocal: isLocal))
        }
        guard !work.isEmpty else { return [] }

        // 1. Esc each session that gets interrupted.
        for i in work.indices where work[i].strategy == .interrupt {
            work[i].pausedAt = Date()
            let r = CodexInjector.interrupt(work[i].terminal)
            if r.success {
                work[i].escSent = true
            } else {
                Logger.shared.log("CodexBackend: low-battery Esc failed for \(work[i].thread.id.prefix(8)): \(r.detail)")
                work[i].strategy = .skip(r.detail)
            }
        }

        // 2. Wait (≤5 s, together) for the rollouts to show the turns ended.
        var waiting = Set(work.indices.filter { work[$0].escSent })
        let deadline = Date().addingTimeInterval(5)
        while !waiting.isEmpty {
            for i in waiting where Self.pauseTurnEnded(CodexRollout.summarizeTail(of: URL(fileURLWithPath: work[i].path)).phase) {
                work[i].turnEnded = true
                waiting.remove(i)
            }
            if waiting.isEmpty || Date() >= deadline { break }
            usleep(200_000)
        }

        // 3. Message them. Never type into a turn that may still be running
        //    behind an approval overlay (tmux can't see one).
        var paused: [PausedSession] = []
        for w in work {
            let label = w.terminal.label
            let detail: String
            switch w.strategy {
            case .skip(let why):
                Logger.shared.log("CodexBackend: low-battery pause skipped \(w.thread.id.prefix(8)) — \(why)")
                continue
            case .interrupt where w.isLocal:
                // Local model: the Esc was the whole pause — no message.
                detail = BatteryPauseSupport.localModelPauseDetail(stopped: w.turnEnded)
            case .interrupt where !w.turnEnded:
                detail = "Pressed Esc in \(label), but couldn't confirm Codex stopped — no pause message sent"
            case .interrupt where ProcessRunner.isForeground(pid: w.pid) != true:
                // Re-checked right before typing: if codex exited or was
                // suspended after the Esc, the text would reach the shell.
                detail = "Interrupted in \(label) — the pause message wasn't sent (Codex is no longer the terminal's active job)"
            case .interrupt:
                let r = CodexInjector.type(message, into: w.terminal)
                detail = r.success
                    ? "Interrupted in \(label) and sent the pause message"
                    : "Interrupted in \(label) — the pause message wasn't sent (\(r.detail))"
            case .queue(let reason):
                guard ProcessRunner.isForeground(pid: w.pid) == true else {
                    Logger.shared.log("CodexBackend: low-battery message not queued for \(w.thread.id.prefix(8)): not the foreground job")
                    continue
                }
                let r = CodexInjector.type(message, into: w.terminal)
                guard r.success else {
                    Logger.shared.log("CodexBackend: low-battery message not queued for \(w.thread.id.prefix(8)): \(r.detail)")
                    continue
                }
                detail = "Queued the pause message in \(label) — \(reason)"
            }
            Logger.shared.log("CodexBackend: low-battery pause \(w.thread.id.prefix(8)) — \(detail)")
            paused.append(PausedSession(
                backend: .codex,
                sessionId: w.thread.id,
                projectName: CodexInjector.projectName(forCwd: w.cwd),
                cwd: w.cwd,
                pausedAt: w.escSent ? w.pausedAt : Date(),
                detail: detail
            ))
        }
        return paused
    }

    /// Pure. Whether the rollout proves an interrupted turn has ended. Only
    /// an explicit end counts: `.unknown` (unreadable tail, no markers in
    /// view) may still be a running turn behind an approval overlay, where
    /// typed letters are hotkeys.
    static func pauseTurnEnded(_ phase: CodexRollout.Summary.Phase) -> Bool {
        phase == .completed || phase == .aborted
    }

    /// Types `message` into each paused Codex session that is still open in
    /// a terminal, finished with its turn, and untouched since the pause.
    func resumePausedSessions(_ sessions: [PausedSession], message: String) -> [String] {
        let mine = sessions.filter { $0.backend == .codex }
        guard !mine.isEmpty else { return [] }
        guard !Thread.isMainThread else {
            Logger.shared.log("CodexBackend: low-battery resume refused on the main thread (would deadlock)")
            return []
        }
        let cfg = config
        // Someone at the Mac may be typing in that very session (plugging
        // the charger in is what triggers an automatic resume): then the
        // composer must be seen to be empty, not merely "no draft seen".
        let requireEmpty = UserPresence.isActive(within: Self.resumePresenceWindow(cfg))
        if requireEmpty { Logger.shared.log("CodexBackend: low-battery resume — you're at the Mac, typing only into an empty composer") }
        let resumedIds: [String] = replyQueue.sync {
            let authored = BatteryPauseSupport.pageAuthoredMessages(extra: [message])
            var resumed: [String] = []
            for p in mine {
                let id = p.sessionId.prefix(8)
                guard let t = lookupThread(p.sessionId), let path = t.path, !path.isEmpty,
                      let cwd = t.cwd, !cwd.isEmpty else {
                    Logger.shared.log("CodexBackend: low-battery resume \(id) — thread unknown, skipped")
                    continue
                }
                let url = URL(fileURLWithPath: path)
                let summary = CodexRollout.summarizeTail(of: url)
                guard summary.phase == .completed || summary.phase == .aborted, summary.pendingRequest == nil else {
                    Logger.shared.log("CodexBackend: low-battery resume \(id) — not waiting for input, skipped")
                    continue
                }
                guard let tail = CodexRollout.readTail(of: url, maxBytes: 2 * 1024 * 1024) else { continue }
                let activity = Self.userActivity(since: p.pausedAt, rolloutTail: tail.text,
                                                 tailIsComplete: !tail.truncated, pageAuthored: authored)
                guard activity == .none else {
                    Logger.shared.log("CodexBackend: low-battery resume \(id) — user activity \(activity), skipped")
                    continue
                }
                // Live terminals only: a background exec resume of a closed
                // session isn't "carrying on where it left off".
                let r: CodexDeliveryOutcome
                switch CodexInjector.deliver(text: message, threadId: t.id, cwd: cwd, rolloutPath: path,
                                             codexPath: cfg.codexPath, allowExecResume: false,
                                             cwdFallback: .forSource(Self.mapSource(t.source)),
                                             requireEmptyComposer: requireEmpty) {
                case .finished(let outcome): r = outcome
                case .needsExecResume: r = .failure("Codex isn't open any more")  // unreachable: exec resume is off
                }
                Logger.shared.log("CodexBackend: low-battery resume \(id) success=\(r.success) — \(r.detail)")
                if r.success { resumed.append(p.sessionId) }
            }
            return resumed
        }
        locked { batteryPausedIds.subtract(resumedIds) }
        return resumedIds
    }

    /// How recently the user must have touched the Mac to count as "at the
    /// Mac" for a low-battery resume (same window as ClaudeBackend).
    static func resumePresenceWindow(_ cfg: Config) -> TimeInterval {
        max(120, cfg.idlePageOnlyWhenAwaySeconds)
    }

    /// Pure. Whether the user wrote to a Codex thread after `pausedAt`.
    /// Counts `user_message` events, completed UserMessage items and
    /// `role: user` messages — except the context Codex injects itself
    /// (`<environment_context>`, `<recommended_plugins>`, … all start with
    /// "<") and Page's own messages.
    static func userActivity(since pausedAt: Date, rolloutTail: String, tailIsComplete: Bool,
                             pageAuthored: Set<String>) -> BatteryPauseSupport.UserActivity {
        var earliest: Date?
        for line in rolloutTail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let ts = (obj["timestamp"] as? String).flatMap(BatteryPauseSupport.parseTimestamp)
            if let ts, earliest == nil || ts < earliest! { earliest = ts }
            guard let ts, ts > pausedAt, let payload = obj["payload"] as? [String: Any] else { continue }
            var texts: [String] = []
            switch (obj["type"] as? String, payload["type"] as? String) {
            case ("event_msg", "user_message"):
                if let m = payload["message"] as? String { texts = [m] }
            case ("event_msg", "item_completed"):
                let item = payload["item"] as? [String: Any]
                if let kind = item?["type"] as? String, kind.lowercased() == "usermessage" {
                    texts = Self.textParts(item?["content"])
                }
            case ("response_item", "message") where payload["role"] as? String == "user":
                texts = Self.textParts(payload["content"])
            default:
                continue
            }
            for text in texts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !text.isEmpty {
                if text.hasPrefix("<") { continue }
                if pageAuthored.contains(BatteryPauseSupport.normalize(text)) { continue }
                return .userActed
            }
        }
        if !tailIsComplete, (earliest.map { $0 > pausedAt } ?? true) { return .unknown }
        return .none
    }

    private static func textParts(_ content: Any?) -> [String] {
        if let s = content as? String { return [s] }
        guard let parts = content as? [[String: Any]] else { return [] }
        return parts.compactMap { $0["text"] as? String }
    }
}

/// One background `codex exec resume` per thread at a time, and one per
/// reply. Thread-safe.
final class CodexExecResumeGate: @unchecked Sendable {
    enum Begin: Equatable {
        case started
        /// The same reply is already being resumed (a re-sent reply).
        case duplicateReply
        /// Another reply's resume is running on this thread.
        case threadBusy
    }

    private let lock = NSLock()
    private var threads = Set<String>()
    private var replies = Set<String>()

    func begin(threadId: String, interventionId: String) -> Begin {
        lock.lock()
        defer { lock.unlock() }
        if replies.contains(interventionId) { return .duplicateReply }
        if threads.contains(threadId) { return .threadBusy }
        threads.insert(threadId)
        replies.insert(interventionId)
        return .started
    }

    func end(threadId: String, interventionId: String) {
        lock.lock()
        threads.remove(threadId)
        replies.remove(interventionId)
        lock.unlock()
    }

    func isThreadBusy(_ threadId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return threads.contains(threadId)
    }

    func isReplyInFlight(_ interventionId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return replies.contains(interventionId)
    }
}
