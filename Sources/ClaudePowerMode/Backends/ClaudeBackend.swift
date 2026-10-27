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

    // Everything mutable is guarded by `lock`: refresh() runs on the
    // Coordinator's tick queue, replies arrive on a background queue, and
    // config reloads / manual resumes come from the main thread.
    private let lock = NSLock()

    private var _relay: RelaySink?
    /// The Coordinator's shared relay connection (nil while the relay is off).
    var relay: RelaySink? {
        get { lock.lock(); defer { lock.unlock() }; return _relay }
        set { lock.lock(); _relay = newValue; lock.unlock() }
    }

    private var _onNewRateLimit: ((RateLimitEvent) -> Void)?
    private var _onNewIntervention: ((InterventionEvent) -> Void)?
    private var _onReplyFinished: ((ReplyFinished) -> Void)?
    /// Called when a reply delivery ends, never while a lock is held.
    var onReplyFinished: ((ReplyFinished) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onReplyFinished }
        set { lock.lock(); _onReplyFinished = newValue; lock.unlock() }
    }
    /// Called on the tick queue, never while a lock is held.
    var onNewRateLimit: ((RateLimitEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onNewRateLimit }
        set { lock.lock(); _onNewRateLimit = newValue; lock.unlock() }
    }
    /// Called on the tick queue, never while a lock is held.
    var onNewIntervention: ((InterventionEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onNewIntervention }
        set { lock.lock(); _onNewIntervention = newValue; lock.unlock() }
    }

    var currentSnapshot: AgentBackendSnapshot {
        let s = latestState
        return AgentBackendSnapshot(
            backendID: id,
            displayName: displayName,
            sessions: s.sessions,
            wantsPowerAssertion: s.wantsPowerAssertion,
            pendingInterventions: s.pendingInterventions,
            currentRateLimit: s.activeRateLimit
        )
    }

    private var _config: Config
    private var _latestState: State = .empty
    var config: Config { lock.lock(); defer { lock.unlock() }; return _config }
    var latestState: State { lock.lock(); defer { lock.unlock() }; return _latestState }

    private let rateWatcher = RateLimitWatcher()
    private let scheduler = ResumeScheduler()
    /// Outcomes of scheduled (launchd) resumes, reported once each.
    var onResumeResult: ((ResumeResult) -> Void)?
    private var lastPurgeAt = Date()
    private let interventionDetector = InterventionDetector()
    /// Busy-but-getting-nowhere pages (tick queue only; `stuckPages` is the
    /// locked copy replies and sync read).
    private let stuckMonitor = StuckMonitor()
    private var stuckPages: [String: InterventionEvent] = [:]
    private let registry: ClaudeSessionRegistry

    /// Every keystroke injection runs here, one at a time, so two replies
    /// can never interleave keys in a terminal.
    private let injectionQueue = DispatchQueue(label: "ClaudePowerMode.ClaudeBackend.injection", qos: .userInitiated)
    /// Background `claude --resume --print` runs (up to 15 min each) get their
    /// own queue so they don't hold up live-terminal replies. They type no keys.
    private let headlessQueue = DispatchQueue(label: "ClaudePowerMode.ClaudeBackend.headless", qos: .utility)

    // Page bookkeeping (guarded by `lock`).
    /// Ids opened on the relay and not yet closed by us.
    private var sentPageIds = Set<String>()
    /// Sessions paused for low battery. Their idle page is held back until
    /// they're resumed (or the user gets them going again): the Worker keeps
    /// one page per session, and an idle page would replace the Coordinator's
    /// low-battery page — losing the "plug in to continue" context.
    private var batteryPausedIds = Set<String>()
    /// Ids closed by a delivered reply — the detector resolving them later
    /// must not send a second close.
    private var repliedIds = Set<String>()
    /// Reply ids currently being injected (a lock-screen action and an
    /// in-app reply can both arrive for one page).
    private var inFlightReplies = Set<String>()
    /// Replies typed at this Mac's panel (`RelayReply.source == "mac"`): the
    /// phone never made them, so it is told the page was resolved on the Mac
    /// instead of being sent a reply result.
    private var macOriginReplies = Set<String>()
    /// Reply ids already delivered, oldest first (bounded). A replayed reply
    /// must never be typed a second time — by then the session has moved
    /// on and "approve" would become a typed "yes, proceed".
    private var deliveredReplies = Set<String>()
    private var deliveredOrder: [String] = []
    /// Open rate-limit pages, by intervention id.
    private var rateLimitPages: [String: InterventionEvent] = [:]
    private var rateLimitEventsByPage: [String: RateLimitEvent] = [:]
    /// Rate limits to auto-resume in the live session once they reset.
    private var pendingAutoResumes: [String: RateLimitEvent] = [:]
    /// Text the phone asked to send when a limit resets (a reply to its
    /// rate-limit page), by event id. Typed instead of the carry-on prompt,
    /// even with auto-resume off.
    private var queuedResetMessages: [String: String] = [:]
    /// Prime the rate-limit watcher before the next scan (watcher just
    /// enabled), so the backlog of old events doesn't fire at once.
    private var needsRateLimitPrime = false

    /// Grace after the parsed reset time before typing the carry-on prompt
    /// (reset texts are minute-granular and the API can lag).
    private let autoResumeGrace: TimeInterval = 60
    /// Auto-resume is abandoned this long after reset (the Mac slept; the
    /// launchd job owns it then).
    private let autoResumeExpiry: TimeInterval = 2 * 3600

    init(config: Config = Config.load()) {
        self._config = config
        self.registry = ClaudeSessionRegistry(projectsDirectory: config.transcriptDirectory,
                                              resolverQueue: DispatchQueue(label: "ClaudePowerMode.providerResolver", qos: .utility))
        // Wired once, unconditionally; the handlers check the live config,
        // so toggling a feature in Preferences takes effect without restart.
        rateWatcher.onNewEvent = { [weak self] event in
            self?.handleNewRateLimit(event)
        }
    }

    func start() {
        let cfg = config
        Logger.shared.log("ClaudeBackend starting (transcripts=\(cfg.transcriptDirectory), processPattern=\(cfg.claudeProcessPattern))")
        scheduler.purgeStale()
        // Priming reads every recent transcript; do it on the tick queue.
        lock.lock()
        needsRateLimitPrime = cfg.rateLimitWatcherEnabled
        lock.unlock()
    }

    func reloadConfig(_ config: Config) {
        lock.lock()
        let old = _config
        _config = config
        if !old.rateLimitWatcherEnabled && config.rateLimitWatcherEnabled { needsRateLimitPrime = true }
        lock.unlock()
        registry.setProjectsDirectory(config.transcriptDirectory)
        Logger.shared.log("ClaudeBackend config reloaded")
    }

    func shutdown() {
        // Don't wait on the injection queue: it may be blocked on
        // DispatchQueue.main.sync (AppleScript), and shutdown runs on main.
        Self.removeDetectorAliveMarker()
    }

    // MARK: tick

    func refresh() {
        let cfg = config
        let now = Date()

        lock.lock()
        let prime = needsRateLimitPrime && cfg.rateLimitWatcherEnabled
        needsRateLimitPrime = false
        lock.unlock()

        // One process-table snapshot for the whole tick.
        let table = ProcessRunner.processTable()
        let sessions = registry.refresh(processTable: table)
        // After the registry has recorded live sessions' providers: the
        // index classifies (and caches) limits against them on first read.
        if prime { rateWatcher.primeWithExistingEvents(transcriptDirectory: cfg.transcriptDirectory) }
        // A battery-paused session that's busy again was resumed by someone
        // (the user, or a phone reply) — its idle pages are fair game again.
        let busyIds = Set(sessions.filter { $0.status == .busy }.map(\.sessionId))
        lock.lock()
        batteryPausedIds.subtract(busyIds)
        lock.unlock()
        let claudeProcs = ProcessMonitor.claudeProcesses(in: table, pattern: cfg.claudeProcessPattern, exclude: cfg.excludePatterns)
        let identifiedPids = Set(sessions.map(\.pid))
        let unidentifiedInteractive = claudeProcs.filter {
            !identifiedPids.contains($0.pid) && ClaudeSessionRegistry.normalizedTTY($0.tty) != nil
        }.count
        let claudeRunning = !sessions.isEmpty || !claudeProcs.isEmpty

        var transcripts: [String: URL] = [:]
        for s in sessions where transcripts[s.sessionId] == nil {
            if let url = registry.transcriptURL(forSessionId: s.sessionId, cwdHint: s.cwd) { transcripts[s.sessionId] = url }
        }
        let secondsSince = ActivityMonitor.secondsSinceLastWrite(of: Array(transcripts.values), now: now)
        // Claude Squad: a paused instance's agent is still running, but in a
        // deleted worktree, so it neither keeps the Mac awake nor gets paged.
        let squad = ClaudeSquad.liveStandings(sessions: sessions, table: table)
        let attended = Self.attendedSessions(sessions: sessions, standings: squad)
        let claudeActive = Self.isActive(
            sessions: attended,
            unidentifiedInteractive: unidentifiedInteractive,
            claudeRunning: claudeRunning,
            secondsSinceTranscript: secondsSince,
            requireRecentActivity: cfg.requireRecentTranscriptActivity,
            activityWindow: cfg.transcriptActivityWindowSeconds
        )

        // Rate limits. scan() fires handleNewRateLimit for new events.
        var activeLimit: RateLimitEvent?
        if cfg.rateLimitWatcherEnabled {
            _ = rateWatcher.scan(transcriptDirectory: cfg.transcriptDirectory)
            if let limit = rateWatcher.activeLimit(now: now),
               !Self.rateLimitCleared(limit, sessions: sessions) {
                activeLimit = limit
            }
        }
        refreshRateLimitPages(sessions: sessions, now: now, cfg: cfg)

        // Interventions.
        var opened: [InterventionEvent] = []
        if cfg.interventionDetectionEnabled {
            let settings = DetectorSettings(idleDelay: max(0, cfg.idlePageDelaySeconds))
            interventionDetector.turnHeadline = cfg.turnSummaryEnabled ? { TurnSummary.headline(transcript: $0, cwd: $1) } : nil
            let result = interventionDetector.scan(
                sessions: attended,
                transcriptFor: { transcripts[$0.sessionId] },
                settings: settings,
                sourceFor: { InjectionExecutor.sessionSource(pid: $0.pid, processTable: table) },
                autoApproves: { squad[$0.pid]?.autoApproves ?? false },
                now: now
            )
            opened = result.opened
            let livePids = Set(attended.map(\.pid))
            for e in result.resolved {
                closePage(e.id, reason: (e.pid.map(livePids.contains) ?? false) ? "user_resolved_in_terminal" : "session_resolved")
            }
        } else {
            for e in interventionDetector.reset() { closePage(e.id, reason: "session_resolved") }
        }
        let pending = cfg.interventionDetectionEnabled ? Array(interventionDetector.currentlyPending.values) : []
        opened += refreshStuckPages(sessions: attended, transcripts: transcripts, pending: pending, now: now, cfg: cfg)
        let callback = onNewIntervention
        for e in opened { callback?(e) }

        sendDuePages(pending + rateLimitPagesSnapshot() + stuckPagesSnapshot(), cfg: cfg)
        updateDetectorAliveMarker(cfg: cfg)

        // Scheduled-resume housekeeping: surface finished jobs, and purge
        // stale plists hourly (not just at launch — the app runs for weeks).
        for result in scheduler.collectResults() where result.outcome != .skippedLive {
            Logger.shared.log("Scheduled resume \(result.sessionId.prefix(8)): \(result.outcome.rawValue) \(result.detail ?? "")")
            onResumeResult?(result)
        }
        if now.timeIntervalSince(lastPurgeAt) >= 3600 {
            lastPurgeAt = now
            scheduler.purgeStale()
        }
        // The registry has just recorded live sessions' providers.
        for job in ResumeProviderGate.jobsToCancel(scheduler.listScheduled(), evidence: resumeEvidence) {
            Logger.shared.log("Cancelling the background resume for \(job.sessionId.prefix(8)): \(ResumeProviderGate.message(resumeEvidence(job)))")
            scheduler.cancel(job)
        }

        let relayAvailable = cfg.relayEnabled && relay != nil
        let holdForReset = cfg.holdAssertionUntilReset && activeLimit != nil
        let holdForPages = Self.shouldHoldForPages(
            pending: pending, relayAvailable: relayAvailable,
            holdMinutes: cfg.holdAwakeForPendingPageMinutes, now: now
        )
        let wantsPowerAssertion = claudeActive || holdForReset || holdForPages

        let state = State(
            sessions: makeSessions(sessions: sessions, transcripts: transcripts, claudeRunning: claudeRunning,
                                   claudeActive: claudeActive, secondsSince: secondsSince,
                                   activeLimit: activeLimit, pending: pending),
            claudeRunning: claudeRunning,
            claudeActive: claudeActive,
            secondsSinceTranscript: secondsSince,
            activeRateLimit: activeLimit,
            scheduledResumes: scheduler.listScheduled(),
            pendingInterventions: pending.sorted { $0.openedAt < $1.openedAt },
            relayConnected: relay?.isConnected ?? false,
            wantsPowerAssertion: wantsPowerAssertion
        )
        lock.lock()
        _latestState = state
        lock.unlock()
    }

    // MARK: decision helpers (pure, unit-tested)

    /// Pure. The sessions this tick looks after: everything except paused
    /// Claude Squad instances (agent running in a deleted worktree), which
    /// neither keep the Mac awake nor get paged. `standings`: by pid.
    static func attendedSessions(sessions: [ClaudeLiveSession], standings: [Int32: ClaudeSquad.Standing]) -> [ClaudeLiveSession] {
        sessions.filter { standings[$0.pid]?.paused != true }
    }

    /// Whether Claude is doing work right now. Sessions with a status are
    /// exact (`busy`); status-less ones (older Claude Code) fall back to
    /// "transcript written within the activity window".
    static func isActive(sessions: [ClaudeLiveSession],
                         unidentifiedInteractive: Int,
                         claudeRunning: Bool,
                         secondsSinceTranscript: Double?,
                         requireRecentActivity: Bool,
                         activityWindow: Double) -> Bool {
        guard claudeRunning else { return false }
        if sessions.contains(where: { $0.status == .busy }) { return true }
        // A background shell may be real work (a build) or a dev server that
        // never ends: judged by recent transcript activity, as status-less.
        let hasStatusless = unidentifiedInteractive > 0 || sessions.contains { $0.status == .unknown || $0.status == .shell }
        guard hasStatusless else { return false }
        if !requireRecentActivity { return true }
        if let s = secondsSinceTranscript { return s <= activityWindow }
        // Nothing to measure (no transcript found): behave as before and
        // assume a running CLI is working.
        return true
    }

    /// Keep the Mac awake while a page is waiting for a reply — a sleeping
    /// Mac can't deliver it — but only for a bounded time, and only when a
    /// phone can actually answer.
    static func shouldHoldForPages(pending: [InterventionEvent], relayAvailable: Bool,
                                   holdMinutes: Double, now: Date) -> Bool {
        guard relayAvailable, holdMinutes > 0 else { return false }
        return pending.contains { now.timeIntervalSince($0.openedAt) < holdMinutes * 60 }
    }

    /// A limit no longer applies once its session has started a new state
    /// well after the error (the user retried successfully, switched model,
    /// bought more usage), or is busy right now.
    static func rateLimitCleared(_ limit: RateLimitEvent, sessions: [ClaudeLiveSession]) -> Bool {
        sessions.contains { s in
            guard s.sessionId == limit.sessionId else { return false }
            if s.status == .busy { return true }
            if let since = s.statusUpdatedAt, since.timeIntervalSince(limit.eventTime) > 60 { return true }
            return false
        }
    }

    /// Idle and rate-limit pages wait while the user is at the Mac (they can
    /// see the terminal); approvals and questions block the agent and go now.
    static func pageNeedsAway(_ kind: InterventionKind) -> Bool {
        kind == .idle || kind == .rateLimit
    }

    static func replyKind(for kind: InterventionKind) -> ReplyPromptKind {
        switch kind {
        case .permission, .plan: return .approval
        case .question: return .question
        case .idle: return .idle
        case .rateLimit: return .other
        }
    }

    // MARK: pages → relay

    /// Sends every pending page not yet on the relay whose time has come.
    private func sendDuePages(_ pages: [InterventionEvent], cfg: Config) {
        guard cfg.relayEnabled, let relay else { return }
        lock.lock()
        let unsent = pages.filter {
            !sentPageIds.contains($0.id) && !repliedIds.contains($0.id)
                && !($0.kind == .idle && batteryPausedIds.contains($0.sessionId))
        }
        lock.unlock()
        guard !unsent.isEmpty else { return }
        let userAtMac = cfg.idlePageOnlyWhenAwaySeconds > 0
            && UserPresence.isActive(within: cfg.idlePageOnlyWhenAwaySeconds)
        for page in unsent where !(Self.pageNeedsAway(page.kind) && userAtMac) {
            relay.sendInterventionOpened(page)
            lock.lock()
            sentPageIds.insert(page.id)
            lock.unlock()
        }
    }

    /// Closes a page on the relay if (and only if) we opened it there and a
    /// reply hasn't already closed it.
    private func closePage(_ id: String, reason: String) {
        lock.lock()
        let wasSent = sentPageIds.remove(id) != nil
        let replied = repliedIds.remove(id) != nil
        let relay = _relay
        lock.unlock()
        if wasSent && !replied { relay?.sendInterventionClosed(id: id, reason: reason) }
    }

    // MARK: stuck watch

    /// Runs the stuck watch and closes what resolved. Returns new pages.
    private func refreshStuckPages(sessions: [ClaudeLiveSession], transcripts: [String: URL],
                                   pending: [InterventionEvent], now: Date, cfg: Config) -> [InterventionEvent] {
        guard cfg.interventionDetectionEnabled, cfg.stuckAlertsEnabled else {
            for e in stuckMonitor.reset() { closePage(e.id, reason: "session_resolved") }
            lock.lock(); stuckPages.removeAll(); lock.unlock()
            return []
        }
        lock.lock()
        // Another open page for the session: a stuck page would supersede
        // it on the relay.
        var blocked = Set(pending.map(\.sessionId)).union(batteryPausedIds)
        blocked.formUnion(rateLimitPages.values.map(\.sessionId))
        lock.unlock()
        var settings = StuckWatch.Settings()
        settings.quietAfter = cfg.stuckAfterMinutes * 60
        let update = stuckMonitor.scan(sessions: sessions, transcripts: transcripts, blocked: blocked,
                                       settings: settings, now: now)
        let snapshot = Dictionary(uniqueKeysWithValues: stuckMonitor.pages.values.map { ($0.id, $0) })
        lock.lock(); stuckPages = snapshot; lock.unlock()
        for e in update.resolved { closePage(e.id, reason: "session_resolved") }
        return update.opened
    }

    private func stuckPagesSnapshot() -> [InterventionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(stuckPages.values)
    }

    /// Stop on a looping/stuck page: Esc through the phone's Stop path (the
    /// same gate), reported back as the reply's delivery result.
    private func stopFromStuckPage(_ id: String, page: InterventionEvent) {
        remoteInterrupt(sessionId: page.sessionId, interventionId: nil) { [weak self] r in
            let ok = r.code == .delivered || r.code == .queued
            self?.finishReply(id, InjectionResult(method: .none, success: ok,
                                                  output: "stuck stop: \(r.code.rawValue) \(r.reason?.rawValue ?? "")",
                                                  detail: ok ? "Stopped it" : r.detail))
        }
    }

    // MARK: rate limits

    private func handleNewRateLimit(_ event: RateLimitEvent) {
        let cfg = config
        guard cfg.rateLimitWatcherEnabled, event.backend == .claude else { return }
        Logger.shared.log("Rate-limit detected: session=\(event.sessionId.prefix(8)) project=\(event.projectName) resetAt=\(event.resetTime) text=\"\(event.resetTimeText)\"")
        onNewRateLimit?(event)

        if event.resetTime > Date() {
            let page = Self.rateLimitPage(for: event)
            lock.lock()
            rateLimitPages[page.id] = page
            rateLimitEventsByPage[page.id] = event
            if cfg.autoResumeEnabled { pendingAutoResumes[event.uniqueId] = event }
            lock.unlock()
        }

        if cfg.autoResumeEnabled {
            // The launchd job covers the Mac being asleep or the session
            // having exited at reset time; it skips sessions that are still
            // live, which this backend resumes itself (refreshRateLimitPages).
            // It runs without the session's environment, so only for
            // sessions known to run on Anthropic.
            if let why = ResumeProviderGate.refusal(for: event) {
                Logger.shared.log("Not scheduling a background resume for \(event.sessionId.prefix(8)): \(why)")
                // An earlier job for this session (armed when the evidence
                // still said Anthropic) would otherwise stay armed.
                scheduler.cancel(sessionId: event.sessionId)
                return
            }
            do {
                try scheduler.schedule(event: event, prompt: cfg.carryOnPrompt, wakeViaPmset: cfg.wakeViaPmsetEnabled)
            } catch {
                Logger.shared.log("Failed to schedule resume: \(error)")
            }
        }
    }

    /// Last-model reads per transcript, keyed by file and modification
    /// time, so checking armed resumes every tick doesn't re-read a 2 MB
    /// tail per job (tick queue only).
    private var transcriptModelCache: [String: (modified: Date?, model: String?)] = [:]

    /// The schedule-time evidence for an armed job. Sidecars from older
    /// builds may lack the transcript path; the registry finds it.
    private func resumeEvidence(_ job: ScheduledResume) -> ResumeProviderGate.Evidence {
        let url = job.transcriptPath.map { URL(fileURLWithPath: $0) }
            ?? registry.transcriptURL(forSessionId: job.sessionId, cwdHint: job.cwd)
        var model: String?
        if let url {
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if let hit = transcriptModelCache[url.path], hit.modified == modified {
                model = hit.model
            } else {
                model = TranscriptParser.lastAssistantModel(transcript: url)
                if transcriptModelCache.count > 64 { transcriptModelCache = [:] }
                transcriptModelCache[url.path] = (modified, model)
            }
        }
        return ResumeProviderGate.Evidence(stored: SessionProviderStore.provider(for: job.sessionId), lastAssistantModel: model)
    }

    static func rateLimitPage(for event: RateLimitEvent) -> InterventionEvent {
        let df = DateFormatter()
        df.dateStyle = Calendar.current.isDateInToday(event.resetTime) ? .none : .short
        df.timeStyle = .short
        return InterventionEvent(
            id: "\(event.sessionId)-rate_limit-\(Int(event.eventTime.timeIntervalSince1970))",
            sessionId: event.sessionId,
            cwd: event.cwd,
            projectName: event.projectName,
            kind: .rateLimit,
            openedAt: event.eventTime,
            context: "Usage limit reached — resets at \(df.string(from: event.resetTime))",
            transcriptPath: event.transcriptPath,
            backend: .claude,
            source: .terminal
        )
    }

    private func rateLimitPagesSnapshot() -> [InterventionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return Array(rateLimitPages.values)
    }

    /// Closes rate-limit pages whose limit has reset or cleared, and types
    /// the carry-on prompt into still-live limited sessions after reset.
    private func refreshRateLimitPages(sessions: [ClaudeLiveSession], now: Date, cfg: Config) {
        lock.lock()
        let pages = rateLimitEventsByPage
        let resumes = pendingAutoResumes
        lock.unlock()

        for (pageId, event) in pages where now >= event.resetTime || Self.rateLimitCleared(event, sessions: sessions) {
            // The session got going again on its own (the user replied, or
            // the limit lifted early): the scheduled headless resume would
            // now fork a second conversation turn, so drop it.
            if now < event.resetTime { scheduler.cancel(sessionId: event.sessionId) }
            lock.lock()
            rateLimitPages.removeValue(forKey: pageId)
            rateLimitEventsByPage.removeValue(forKey: pageId)
            lock.unlock()
            closePage(pageId, reason: "session_resolved")
        }

        for (key, event) in resumes {
            let due = event.resetTime.addingTimeInterval(autoResumeGrace)
            guard now >= due else { continue }
            let expired = now >= event.resetTime.addingTimeInterval(autoResumeExpiry)
            // Typing into an idle session while the user is at the Mac could
            // land in a half-written message; wait until they step away
            // (they can see the session themselves meanwhile).
            if !expired && UserPresence.isActive(within: max(120, cfg.idlePageOnlyWhenAwaySeconds)) { continue }
            lock.lock()
            pendingAutoResumes.removeValue(forKey: key)
            let queued = queuedResetMessages.removeValue(forKey: key)
            lock.unlock()
            guard cfg.autoResumeEnabled || queued != nil, !expired,
                  !Self.rateLimitCleared(event, sessions: sessions) else { continue }
            guard let live = sessions.first(where: { $0.sessionId == event.sessionId }) else {
                Logger.shared.log("Auto-resume: session \(event.sessionId.prefix(8)) no longer running — leaving it to the scheduled job")
                continue
            }
            guard live.status == .idle || live.status == .shell || live.status == .unknown else {
                Logger.shared.log("Auto-resume: session \(event.sessionId.prefix(8)) is \(live.status.rawValue) — not typing")
                continue
            }
            autoResumeLiveSession(event, prompt: queued ?? cfg.carryOnPrompt)
        }
    }

    /// A written reply to a rate-limit page while the limit is still on:
    /// typed into the session once it resets (`refreshRateLimitPages`).
    /// nil when it doesn't apply (no text, or the limit already reset).
    private func queueForReset(_ reply: RelayReply, page: InterventionEvent) -> InjectionResult? {
        let text = InjectionExecutor.sanitize(reply.text)
        lock.lock()
        defer { lock.unlock() }
        guard !text.isEmpty, let event = rateLimitEventsByPage[page.id], event.resetTime > Date() else { return nil }
        queuedResetMessages[event.uniqueId] = text
        pendingAutoResumes[event.uniqueId] = event
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(event.resetTime) ? .none : .short
        Logger.shared.log("Rate limit: queued a \(text.count)-char message for \(event.sessionId.prefix(8)) at reset")
        return InjectionResult(method: .none, success: true, output: "queued for reset",
                               detail: "Will send it when the limit resets at \(f.string(from: event.resetTime))")
    }

    private func autoResumeLiveSession(_ event: RateLimitEvent, prompt: String) {
        let req = InjectionExecutor.ClaudeReplyRequest(
            interventionId: "\(event.sessionId)-autoresume", sessionId: event.sessionId,
            action: "custom", text: prompt, kind: .idle,
            pagePid: nil, pageStateStart: nil, pagePromptKey: nil, hookCreatedAt: nil
        )
        let registry = self.registry
        let scheduler = self.scheduler
        injectionQueue.async {
            guard case .live(let session, let table) = InjectionExecutor.resolveClaudeTarget(req, registry: registry) else {
                Logger.shared.log("Auto-resume: session \(event.sessionId.prefix(8)) gone before typing")
                return
            }
            // Re-checked on the injection queue: only type into an idle
            // session, never over a prompt or a turn the user started.
            guard session.status == .idle || session.status == .shell || session.status == .unknown else {
                Logger.shared.log("Auto-resume: session \(event.sessionId.prefix(8)) became \(session.status.rawValue) — skipped")
                return
            }
            let r = InjectionExecutor.deliverToLiveSession(req, session: session, processTable: table, registry: registry)
            Logger.shared.log("Auto-resume into live session \(event.sessionId.prefix(8)): success=\(r.success) \(r.detail)")
            // Resumed live — make sure the launchd fallback can't also fire
            // (e.g. if the terminal is closed before its run time).
            if r.success { scheduler.cancel(sessionId: event.sessionId) }
        }
    }

    // MARK: replies

    func handleReply(_ reply: RelayReply) {
        let id = reply.interventionId
        // The blocking PreToolUse hook polls for its own replies.
        if id.hasPrefix("hookpre-") { return }
        guard reply.owningBackend == .claude else { return }

        lock.lock()
        let duplicate = inFlightReplies.contains(id) || deliveredReplies.contains(id)
        if !duplicate {
            inFlightReplies.insert(id)
            if reply.source == "mac" {
                if macOriginReplies.count > 200 { macOriginReplies.removeAll() }
                macOriginReplies.insert(id)
            }
        }
        let page = rateLimitPages[id]
        let stuck = stuckPages[id]
        let cfg = _config
        lock.unlock()
        if duplicate {
            Logger.shared.log("Reply for \(id) ignored — already delivered or in flight")
            return
        }

        // No action and no text: an old phone's plain banner tap, forwarded
        // by an old Worker. It asks for nothing — never "carry on", never a
        // background resume.
        if Self.isEmptyReply(reply) {
            finishReply(id, InjectionResult(method: .none, success: false, output: "empty reply",
                                            detail: InjectionExecutor.emptyReplyMessage))
            return
        }

        if let page, let queued = queueForReset(reply, page: page) {
            finishReply(id, queued)
            return
        }
        if let stuck, reply.action == "deny", stuck.subtype != "workflow_stalled" {
            stopFromStuckPage(id, page: stuck)
            return
        }

        guard let req = buildRequest(for: reply, rateLimitPage: page, stuckPage: stuck) else {
            Logger.shared.log("Reply for \(id) has no resolvable session")
            finishReply(id, InjectionResult(method: .none, success: false, output: "no session",
                                            detail: "Couldn't identify the session"))
            return
        }
        Logger.shared.log("Reply for \(id) (session \(req.sessionId.prefix(8)), action=\(reply.action ?? "nil"))")

        let registry = self.registry
        injectionQueue.async { [weak self] in
            switch InjectionExecutor.resolveClaudeTarget(req, registry: registry) {
            case .live(let session, let table):
                let r = InjectionExecutor.deliverToLiveSession(req, session: session, processTable: table, registry: registry)
                self?.finishReply(id, r)
            case .failed(let f):
                self?.finishReply(id, InjectionResult(method: .none, success: false, output: "target: \(f.detail)", detail: f.detail))
            case .ended:
                if reply.action == "approve" || reply.action == "deny" {
                    self?.finishReply(id, InjectionResult(method: .none, success: false, output: "session ended",
                                                          detail: "Session ended — approvals can't be delivered"))
                } else if !cfg.headlessResumeFallbackEnabled {
                    self?.finishReply(id, InjectionResult(method: .none, success: false, output: "session ended",
                                                          detail: "Session has ended"))
                } else if let text = Self.headlessText(for: reply) {
                    self?.headlessQueue.async {
                        // Re-checked here, right before launching: the queue
                        // may have waited behind another 15-minute resume,
                        // and the user may have reopened the session since.
                        guard case .ended = InjectionExecutor.resolveClaudeTarget(req, registry: registry) else {
                            self?.finishReply(id, InjectionResult(method: .none, success: false, output: "session live again",
                                                                  detail: "The session is running again — reply again to type into it"))
                            return
                        }
                        let transcript = registry.transcriptURL(forSessionId: req.sessionId, cwdHint: nil)
                        let table = ProcessRunner.processTable()
                        if let why = InjectionExecutor.headlessBlocker(
                            sessionId: req.sessionId, processTable: table, transcript: transcript,
                            cmuxEntry: CmuxBridge.readHookSessions(agent: .claude)?.entries[req.sessionId.lowercased()],
                            backgroundOwnerPids: registry.liveBackgroundOwnerPids(forSessionId: req.sessionId, processTable: table),
                            providerEvidence: ResumeProviderGate.evidence(sessionId: req.sessionId, transcript: transcript)) {
                            self?.finishReply(id, InjectionResult(method: .none, success: false, output: "headless blocked: \(why)", detail: why))
                            return
                        }
                        let r = InjectionExecutor.injectHeadless(sessionId: req.sessionId, text: text, transcript: transcript)
                        self?.finishReply(id, r)
                    }
                } else {
                    self?.finishReply(id, InjectionResult(method: .none, success: false, output: "empty reply",
                                                          detail: InjectionExecutor.emptyReplyMessage))
                }
            }
        }
    }

    /// Pure. A reply with no action (or "custom") and nothing to type.
    static func isEmptyReply(_ reply: RelayReply) -> Bool {
        switch reply.action {
        case nil, "", "custom": return InjectionExecutor.sanitize(reply.text).isEmpty
        default: return false
        }
    }

    /// Pure. What a background resume sends for a reply to an ended
    /// session: the user's text, else the phrase of an explicit
    /// "carry_on" (approve / deny are refused before this). nil when
    /// there's nothing to send.
    static func headlessText(for reply: RelayReply) -> String? {
        if !InjectionExecutor.sanitize(reply.text).isEmpty { return reply.text }
        return reply.action == "carry_on" ? InjectionExecutor.phrase(for: "carry_on") : nil
    }

    /// Works out which session/page a reply answers from our own records.
    /// The payload's cwd is never used; its sessionId only for pages we
    /// didn't raise (notification-hook pages), and injection still requires
    /// a live session or an existing transcript for it.
    private func buildRequest(for reply: RelayReply, rateLimitPage: InterventionEvent?,
                              stuckPage: InterventionEvent? = nil) -> InjectionExecutor.ClaudeReplyRequest? {
        let id = reply.interventionId
        let pending = interventionDetector.pendingEvent(id: id)
        let parsed = InterventionDetector.parseInterventionId(id)
        let hook = Self.parseHookId(id)

        var sessionId = pending?.sessionId ?? rateLimitPage?.sessionId ?? stuckPage?.sessionId ?? parsed?.sessionId
        if sessionId == nil, let sid = reply.sessionId, ClaudeSessionRegistry.isValidSessionId(sid) {
            // Hook ids embed the first 8 chars of the session id; require a match.
            if let hook, !sid.hasPrefix(hook.sid8) { return nil }
            sessionId = sid
        }
        guard let sessionId else { return nil }

        let kind = pending.map { Self.replyKind(for: $0.kind) }
            ?? rateLimitPage.map { _ in ReplyPromptKind.other }
            ?? stuckPage.map { _ in ReplyPromptKind.idle }
            ?? ReplyPromptKind.from(wireKind: reply.kind)
            ?? ReplyPromptKind.from(wireKind: parsed?.kind)

        return InjectionExecutor.ClaudeReplyRequest(
            interventionId: id,
            sessionId: sessionId,
            action: reply.action,
            text: reply.text,
            kind: kind,
            pagePid: pending?.pid,
            pageStateStart: pending?.stateStartedAt ?? parsed.map { Date(timeIntervalSince1970: $0.epoch) },
            // Notification-hook pages: the prompt key their hook sent, as
            // echoed by the Worker (nil from older hooks / Workers).
            pagePromptKey: pending?.promptKey ?? reply.promptKey.flatMap { $0.isEmpty ? nil : $0 },
            hookCreatedAt: hook.map { Date(timeIntervalSince1970: $0.epoch) },
            closedPage: reply.closed == true
        )
    }

    /// `hook-<sid8>-<epoch>-<pid>` → (sid8, epoch). The pid is the hook
    /// script's own (`$$`), not Claude's, so it isn't used.
    static func parseHookId(_ id: String) -> (sid8: String, epoch: TimeInterval)? {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 4, parts[0] == "hook", !parts[1].isEmpty,
              let epoch = TimeInterval(parts[2]) else { return nil }
        return (parts[1], epoch)
    }

    private func finishReply(_ id: String, _ result: InjectionResult) {
        Logger.shared.log("Injection \(result.method.rawValue) success=\(result.success) for \(id): \(result.detail) [\(result.output.prefix(200))]")
        lock.lock()
        inFlightReplies.remove(id)
        if result.success {
            repliedIds.insert(id)
            sentPageIds.remove(id)
            // Bounded: ids also leave when the detector resolves the page.
            if repliedIds.count > 500 { repliedIds.removeFirst() }
            if deliveredReplies.insert(id).inserted { deliveredOrder.append(id) }
            if deliveredOrder.count > 1000 { deliveredReplies.remove(deliveredOrder.removeFirst()) }
        }
        let relay = _relay
        let finished = _onReplyFinished
        let viaMac = macOriginReplies.remove(id) != nil
        lock.unlock()

        finished?(ReplyFinished(interventionId: id, success: result.success, method: result.method.rawValue,
                                detail: result.detail.isEmpty ? (result.success ? "Delivered" : "Couldn't deliver the reply") : result.detail))
        if viaMac {
            // "Resolved on your Mac" on the phone; no reply result for a reply it never sent.
            if result.success { relay?.sendInterventionClosed(id: id, reason: "session_resolved") }
            return
        }
        relay?.sendReplyInjected(
            interventionId: id,
            method: result.method.rawValue,
            success: result.success,
            detail: result.detail.isEmpty ? (result.success ? "Delivered" : "Couldn't deliver the reply") : result.detail,
            output: String(result.output.prefix(500))
        )
        // The Worker's /reply only marks repliedAt; closing clears the card.
        // Failures leave it open so the user can retry from the phone.
        if result.success {
            relay?.sendInterventionClosed(id: id, reason: "replied")
        }
    }

    func openInterventionIds() -> [String] {
        let detectorIds = config.interventionDetectionEnabled ? Array(interventionDetector.currentlyPending.keys) : []
        lock.lock()
        let rl = Array(rateLimitPages.keys) + Array(stuckPages.keys)
        lock.unlock()
        return (detectorIds + rl).filter { !$0.hasPrefix("hook") }
    }

    // MARK: phone sessions view (SessionRemote)

    /// Live sessions as of the last tick (pid, tty, provider), for the
    /// phone's list. Never used to type: the gate re-reads everything.
    var remoteLiveSessions: [ClaudeLiveSession] { registry.sessions }

    /// The session's transcript file, if Page knows it.
    func remoteTranscriptURL(sessionId: String, cwd: String?) -> URL? {
        registry.transcriptURL(forSessionId: sessionId, cwdHint: cwd)
    }

    /// Fresh status of one live process (one small file read).
    func remoteStatus(pid: Int32) -> ClaudeSessionStatus? {
        registry.currentRecord(forPid: pid).map { ClaudeSessionStatus(raw: $0.status) }
    }

    private func remoteIO() -> SessionInputGate.ClaudeIO {
        let registry = self.registry
        return SessionInputGate.ClaudeIO(
            resolve: { InjectionExecutor.resolveClaudeTarget($0, registry: registry) },
            currentRecord: { registry.currentRecord(forPid: $0) },
            resolveHost: { InjectionExecutor.resolveHost(for: $0, processTable: $1) },
            deliver: { InjectionExecutor.deliverToLiveSession($0, session: $1, processTable: $2, registry: registry) },
            isForeground: { ProcessRunner.isForeground(pid: $0) },
            sendInterrupt: { InjectionExecutor.sendInterrupt(host: $0) },
            squadPaused: { ClaudeSquad.isPausedLive(session: $0, host: $1) }
        )
    }

    /// Text typed on the phone's Sessions screen. Runs the input gate and
    /// delivers on the injection queue (one at a time with replies and the
    /// battery pause). Never a background resume. `completion` runs on
    /// the injection queue.
    func remoteInput(sessionId: String, clientId: String, text: String, interventionId: String?,
                     completion: @escaping (SessionCommandResult) -> Void) {
        let io = remoteIO()
        injectionQueue.async {
            completion(SessionInputGate.runClaudeInput(sessionId: sessionId, clientId: clientId, text: text,
                                                       interventionId: interventionId, io: io))
        }
    }

    /// The phone's answers to a pending AskUserQuestion dialog (or the Mac
    /// panel's): the keys come from `AnswerDriver`, one at a time, each after
    /// a screen check. `completion` runs on the injection queue.
    func remoteAnswer(sessionId: String, request: AnswerRequest, completion: @escaping (SessionCommandResult) -> Void) {
        let io = AnswerDelivery.liveIO(registry: registry)
        injectionQueue.async {
            completion(AnswerDelivery.run(sessionId: sessionId, request: request, io: io))
        }
    }

    /// The phone's Stop button: Esc in a busy session.
    func remoteInterrupt(sessionId: String, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
        let io = remoteIO()
        injectionQueue.async {
            completion(SessionInputGate.runClaudeInterrupt(sessionId: sessionId, interventionId: interventionId, io: io))
        }
    }

    // MARK: manual resume

    struct NonAnthropicResumeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @discardableResult
    func scheduleResumeManually(for event: RateLimitEvent, prompt: String? = nil) throws -> ScheduledResume {
        let cfg = config
        if let why = ResumeProviderGate.refusal(for: event) { throw NonAnthropicResumeError(message: why) }
        return try scheduler.schedule(
            event: event,
            prompt: prompt ?? cfg.carryOnPrompt,
            wakeViaPmset: cfg.wakeViaPmsetEnabled
        )
    }

    func cancelResume(_ scheduled: ScheduledResume) {
        scheduler.cancel(scheduled)
    }

    // MARK: menu sessions

    private func makeSessions(sessions: [ClaudeLiveSession],
                              transcripts: [String: URL],
                              claudeRunning: Bool,
                              claudeActive: Bool,
                              secondsSince: Double?,
                              activeLimit: RateLimitEvent?,
                              pending: [InterventionEvent]) -> [AgentSession] {
        if sessions.isEmpty {
            // Claude running but no identifiable session (bare launch of an
            // old Claude Code): one aggregate row, as before.
            guard claudeRunning else { return [] }
            return [AgentSession(
                backend: id, sessionId: "claude-cli", cwd: nil, title: "Claude CLI", source: .terminal,
                state: claudeActive ? .active : .idle,
                lastActivityAt: nil, activeFlags: claudeActive ? ["recentTranscriptActivity"] : [],
                supportsRemoteReply: false
            )]
        }
        return sessions.map { s in
            let pages = pending.filter { $0.pid == s.pid }
            let state: AgentSessionState
            if pages.contains(where: { $0.kind == .permission || $0.kind == .plan }) {
                state = .waitingOnApproval
            } else if !pages.isEmpty {
                state = .waitingOnUser
            } else if activeLimit?.sessionId == s.sessionId {
                state = .rateLimited
            } else {
                switch s.status {
                case .busy: state = .active
                case .waiting: state = .waitingOnApproval
                case .idle, .shell: state = .idle
                case .unknown: state = claudeActive ? .active : .idle
                }
            }
            var flags: [String] = []
            if activeLimit?.sessionId == s.sessionId { flags.append("rateLimited") }
            if !pages.isEmpty { flags.append("waitingOnUser") }
            if s.status == .busy { flags.append("busy") }
            let mtime = transcripts[s.sessionId].flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
            }
            return AgentSession(
                backend: id,
                sessionId: s.sessionId,
                cwd: s.cwd,
                title: s.cwd.map { InterventionDetector.projectName(forCwd: $0, fallback: s.name) } ?? s.name ?? "Claude",
                source: .terminal,
                state: state,
                lastActivityAt: s.statusUpdatedAt ?? mtime,
                activeFlags: flags,
                supportsRemoteReply: s.tty != nil
            )
        }
    }

    // MARK: detector liveness marker

    /// The notification hook skips posting while this file is fresh (< 90s),
    /// because the app pages those prompts itself.
    static var detectorAliveMarkerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudePowerMode", isDirectory: true)
            .appendingPathComponent("detector.alive")
    }

    private func updateDetectorAliveMarker(cfg: Config) {
        if cfg.interventionDetectionEnabled && cfg.relayEnabled {
            let url = Self.detectorAliveMarkerURL
            let fm = FileManager.default
            if fm.fileExists(atPath: url.path) {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } else {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: Data())
            }
        } else {
            Self.removeDetectorAliveMarker()
        }
    }

    static func removeDetectorAliveMarker() {
        let path = detectorAliveMarkerURL.path
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

// MARK: - low-battery pause

/// Shared by the Claude and Codex pause paths: what counts as Page's own
/// text in a transcript (so it isn't mistaken for the user touching the
/// session), and timestamp parsing for transcript lines.
enum BatteryPauseSupport {
    /// Every message Page itself types for a low-battery pause or resume,
    /// normalised. `extra` adds the message being sent right now.
    static func pageAuthoredMessages(extra: [String] = []) -> Set<String> {
        var texts = extra
        for percent in 0...100 {
            texts.append(BatteryPolicy.pauseMessage(percent: percent, mode: .pause))
            texts.append(BatteryPolicy.pauseMessage(percent: percent, mode: .afterTurn))
        }
        texts.append(BatteryPolicy.recoveryMessage)
        texts.append(BatteryPolicy.manualResumeMessage)
        // Sessions paused by an older build got the digit wording; it's
        // still Page's own text, not the user's.
        texts.append(contentsOf: BatteryPolicy.legacyPauseMessages())
        return Set(texts.map(normalize))
    }

    static func normalize(_ text: String) -> String {
        InjectionExecutor.flattenLines(InjectionExecutor.sanitize(text))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    enum UserActivity: Equatable {
        /// Nothing from the user since the pause.
        case none
        case userActed
        /// The transcript tail doesn't reach back to the pause; can't tell.
        case unknown
    }

    /// How long after the pause an "[Request interrupted by user]" marker
    /// is taken to be Page's own Esc rather than the user's.
    static let ownInterruptWindow: TimeInterval = 30
}

extension ClaudeBackend: BatteryPausable {
    /// How one busy session is asked to pause.
    enum PauseStrategy: Equatable {
        /// Esc (interrupts the turn), then type the message once it's idle.
        case interrupt
        /// Type the message while it's busy; Claude delivers it when the
        /// current turn ends. `reason` says why it wasn't interrupted.
        case queue(reason: String)
        case skip(String)
    }

    /// Pure. Interrupt only where a lone Esc can be pressed and the user
    /// chose "pause now"; otherwise queue the message behind the turn.
    ///
    /// A session on a local model (`isLocal`) only ever gets Esc: asking it
    /// for a summary would have the local model generate one on battery.
    /// Where Esc can't be pressed (Terminal.app), or the user chose "after
    /// the current step", it is left alone — the Mac sleeps at the cutoff.
    static func pauseStrategy(status: ClaudeSessionStatus, host: InjectionExecutor.TerminalHost,
                              mode: LowBatteryAction, isLocal: Bool = false) -> PauseStrategy {
        guard mode != .off else { return .skip("low-battery action is off") }
        // Waiting (a prompt on screen) and idle sessions are left alone:
        // they aren't burning battery, and Esc on a menu would deny it.
        guard status == .busy else { return .skip("not busy (\(status.rawValue))") }
        switch host {
        case .unsupported(let app): return .skip("Page can't type into \(app)")
        case .unreachable(let detail): return .skip(detail)
        case .unknown: return .skip("terminal not found")
        case .tmux, .terminalApp, .iTerm, .cmux, .wezterm, .kitty, .herdr: break
        }
        if isLocal {
            if mode == .afterTurn { return .skip("local model — Page doesn't queue a summary request on battery") }
            if !host.canSendLoneEscape { return .skip("local model, and \(host.label) can't press Esc") }
            return .interrupt
        }
        if mode == .afterTurn { return .queue(reason: "it stops after the current step") }
        if host.canSendLoneEscape { return .interrupt }
        return .queue(reason: "Terminal.app can't press Esc, so it stops after this turn")
    }

    func pauseBusySessions(message: String) -> [PausedSession] {
        pauseBusySessions(message: message, mode: config.lowBatteryAction)
    }

    /// Asks every busy session to stop. Runs on the injection queue (so it
    /// never interleaves with a phone reply) and blocks the caller; the
    /// waiting is done for all sessions at once, not one after another.
    func pauseBusySessions(message: String, mode: LowBatteryAction) -> [PausedSession] {
        guard mode != .off else { return [] }
        // AppleScript transports hop to the main thread synchronously; from
        // main this would deadlock against the injection queue.
        guard !Thread.isMainThread else {
            Logger.shared.log("Low-battery pause: refused on the main thread (would deadlock)")
            return []
        }
        let registry = self.registry
        let paused = injectionQueue.sync { Self.runPause(message: message, mode: mode, registry: registry) }
        lock.lock()
        batteryPausedIds.formUnion(paused.map(\.sessionId))
        lock.unlock()
        return paused
    }

    private struct PauseWork {
        let session: ClaudeLiveSession
        let host: InjectionExecutor.TerminalHost
        var strategy: PauseStrategy
        var pausedAt = Date()
        var escSent = false
        var stillBusyAfterEsc = false
    }

    private static func runPause(message: String, mode: LowBatteryAction, registry: ClaudeSessionRegistry) -> [PausedSession] {
        let table = ProcessRunner.processTable()
        guard !table.isEmpty else {
            Logger.shared.log("Low-battery pause: no process table — nothing paused")
            return []
        }
        var work: [PauseWork] = []
        for s in registry.allLiveSessions(processTable: table) where s.status == .busy {
            let host = InjectionExecutor.resolveHost(for: s, processTable: table)
            let strategy = pauseStrategy(status: s.status, host: host, mode: mode, isLocal: s.provider.isLocal)
            if case .skip(let why) = strategy {
                Logger.shared.log("Low-battery pause: skipped \(s.sessionId.prefix(8)) — \(why)")
                continue
            }
            work.append(PauseWork(session: s, host: host, strategy: strategy))
        }
        guard !work.isEmpty else { return [] }

        // 1. Esc every session that gets interrupted. Status is re-read
        //    right before each key: a prompt that opened since would be
        //    *denied* by Esc.
        for i in work.indices where work[i].strategy == .interrupt {
            let pid = work[i].session.pid
            guard let rec = registry.currentRecord(forPid: pid), ClaudeSessionStatus(raw: rec.status) == .busy else {
                work[i].strategy = .skip("no longer busy")
                continue
            }
            // Suspended (^Z) or behind another job: Esc would go to that job
            // (and the message after it, to a shell).
            guard ProcessRunner.isForeground(pid: pid) == true else {
                work[i].strategy = .skip("suspended or in the background")
                continue
            }
            work[i].pausedAt = Date()
            let r = InjectionExecutor.sendInterrupt(host: work[i].host)
            if r.success {
                work[i].escSent = true
            } else {
                Logger.shared.log("Low-battery pause: Esc failed for \(work[i].session.sessionId.prefix(8)): \(r.detail) [\(r.output.prefix(160))]")
                // Local model: Esc only, never a queued summary request.
                work[i].strategy = work[i].session.provider.isLocal
                    ? .skip("local model, and Page couldn't press Esc there")
                    : .queue(reason: "Page couldn't press Esc there, so it stops after this turn")
            }
        }

        // 2. Wait (≤5 s, all sessions together) for interrupted turns to end.
        var waiting = Set(work.indices.filter { work[$0].escSent })
        let deadline = Date().addingTimeInterval(5)
        while !waiting.isEmpty {
            for i in waiting {
                let rec = registry.currentRecord(forPid: work[i].session.pid)
                if rec == nil || ClaudeSessionStatus(raw: rec?.status) != .busy { waiting.remove(i) }
            }
            if waiting.isEmpty || Date() >= deadline { break }
            usleep(100_000)
        }
        for i in waiting { work[i].stillBusyAfterEsc = true }

        // 3. Type the message through the normal reply path: idle → typed
        //    and submitted; still busy → queued; a prompt now on screen →
        //    refused (Enter there would accept it).
        var paused: [PausedSession] = []
        for w in work {
            if case .skip(let why) = w.strategy {
                Logger.shared.log("Low-battery pause: skipped \(w.session.sessionId.prefix(8)) — \(why)")
                continue
            }
            let pausedAt = w.escSent ? w.pausedAt : Date()
            let cwd = w.session.cwd ?? ""
            let projectName = cwd.isEmpty ? (w.session.name ?? "Claude") : InterventionDetector.projectName(forCwd: cwd, fallback: w.session.name)
            // Local model: the Esc was the whole pause — no message typed,
            // so the model doesn't spend battery writing a summary.
            if w.session.provider.isLocal {
                guard w.escSent else { continue }
                let detail = BatteryPauseSupport.localModelPauseDetail(stopped: !w.stillBusyAfterEsc)
                Logger.shared.log("Low-battery pause: \(w.session.sessionId.prefix(8)) — \(detail)")
                paused.append(PausedSession(backend: .claude, sessionId: w.session.sessionId, projectName: projectName,
                                            cwd: cwd, pausedAt: pausedAt, detail: detail))
                continue
            }
            let req = InjectionExecutor.ClaudeReplyRequest(
                interventionId: "\(w.session.sessionId)-low_battery_pause", sessionId: w.session.sessionId,
                action: "custom", text: message, kind: .idle,
                pagePid: w.session.pid, pageStateStart: nil, pagePromptKey: nil, hookCreatedAt: nil
            )
            let typed: InjectionResult
            switch InjectionExecutor.resolveClaudeTarget(req, registry: registry) {
            case .live(let s, let t):
                typed = InjectionExecutor.deliverToLiveSession(req, session: s, processTable: t, registry: registry)
            case .ended:
                typed = InjectionResult(method: .none, success: false, output: "exited", detail: "the session exited")
            case .failed(let f):
                typed = InjectionResult(method: .none, success: false, output: f.detail, detail: f.detail)
            }
            let label = w.host.label
            let detail: String
            if w.escSent && !w.stillBusyAfterEsc {
                detail = typed.success
                    ? "Interrupted in \(label) and sent the pause message"
                    : "Interrupted in \(label) — the pause message wasn't sent (\(typed.detail))"
            } else if w.escSent {
                detail = typed.success
                    ? "Pressed Esc in \(label) but it kept working — queued the pause message"
                    : "Pressed Esc in \(label) but it kept working, and the pause message wasn't sent (\(typed.detail))"
            } else if case .queue(let reason) = w.strategy, typed.success {
                detail = "Queued the pause message in \(label) — \(reason)"
            } else {
                Logger.shared.log("Low-battery pause: couldn't message \(w.session.sessionId.prefix(8)): \(typed.detail) [\(typed.output.prefix(160))]")
                continue
            }
            Logger.shared.log("Low-battery pause: \(w.session.sessionId.prefix(8)) — \(detail)")
            paused.append(PausedSession(
                backend: .claude,
                sessionId: w.session.sessionId,
                projectName: projectName,
                cwd: cwd,
                pausedAt: pausedAt,
                detail: detail
            ))
        }
        return paused
    }

    /// Types `message` into each paused session that is still running,
    /// idle, and untouched by the user since it was paused.
    func resumePausedSessions(_ sessions: [PausedSession], message: String) -> [String] {
        let mine = sessions.filter { $0.backend == .claude }
        guard !mine.isEmpty else { return [] }
        guard !Thread.isMainThread else {
            Logger.shared.log("Low-battery resume: refused on the main thread (would deadlock)")
            return []
        }
        let registry = self.registry
        // Someone at the Mac may be typing in that very session (plugging
        // the charger in is what triggers an automatic resume): then the
        // input box must be seen to be empty, not merely "no draft seen".
        let userPresent = UserPresence.isActive(within: max(120, config.idlePageOnlyWhenAwaySeconds))
        let resumedIds: [String] = injectionQueue.sync {
            let authored = BatteryPauseSupport.pageAuthoredMessages(extra: [message])
            var resumed: [String] = []
            for p in mine {
                let sid = p.sessionId.prefix(8)
                let req = InjectionExecutor.ClaudeReplyRequest(
                    interventionId: "\(p.sessionId)-low_battery_resume", sessionId: p.sessionId,
                    action: "custom", text: message, kind: .idle,
                    pagePid: nil, pageStateStart: nil, pagePromptKey: nil, hookCreatedAt: nil,
                    requireEmptyInput: userPresent
                )
                guard case .live(let s, let table) = InjectionExecutor.resolveClaudeTarget(req, registry: registry) else {
                    Logger.shared.log("Low-battery resume: \(sid) isn't running (or is ambiguous) — skipped")
                    continue
                }
                guard s.status == .idle || s.status == .shell else {
                    Logger.shared.log("Low-battery resume: \(sid) is \(s.status.rawValue) — skipped")
                    continue
                }
                guard let transcript = registry.transcriptURL(forSessionId: p.sessionId, cwdHint: s.cwd),
                      let tail = CodexRollout.readTail(of: transcript, maxBytes: 2 * 1024 * 1024) else {
                    Logger.shared.log("Low-battery resume: \(sid) transcript unreadable — skipped")
                    continue
                }
                let activity = Self.userActivity(since: p.pausedAt, transcriptTail: tail.text,
                                                 tailIsComplete: !tail.truncated, pageAuthored: authored)
                guard activity == .none else {
                    Logger.shared.log("Low-battery resume: \(sid) — \(activity == .userActed ? "the user has been in it since" : "can't tell whether the user touched it") — skipped")
                    continue
                }
                let r = InjectionExecutor.deliverToLiveSession(req, session: s, processTable: table, registry: registry)
                Logger.shared.log("Low-battery resume: \(sid) success=\(r.success) \(r.detail)")
                if r.success { resumed.append(p.sessionId) }
            }
            return resumed
        }
        lock.lock()
        batteryPausedIds.subtract(resumedIds)
        lock.unlock()
        return resumedIds
    }

    /// Pure. Whether a human wrote to the session after `pausedAt`, from its
    /// transcript tail. Counts user turns and messages typed while Claude was
    /// busy (recorded as `queued_command` attachments with a human origin).
    /// Tool results, meta and sidechain (subagent) records, task / peer
    /// notifications, Page's own messages, and the interrupt marker Page's
    /// own Esc produced are ignored.
    static func userActivity(since pausedAt: Date, transcriptTail: String, tailIsComplete: Bool,
                             pageAuthored: Set<String>) -> BatteryPauseSupport.UserActivity {
        var earliest: Date?
        for line in transcriptTail.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let ts = (obj["timestamp"] as? String).flatMap(BatteryPauseSupport.parseTimestamp)
            if let ts, earliest == nil || ts < earliest! { earliest = ts }
            guard let ts, ts > pausedAt else { continue }
            if obj["isMeta"] as? Bool == true || obj["isSidechain"] as? Bool == true
                || obj["isCompactSummary"] as? Bool == true { continue }
            var texts: [String] = []
            switch obj["type"] as? String {
            case "user":
                let content = (obj["message"] as? [String: Any])?["content"]
                if let s = content as? String {
                    texts = [s]
                } else if let parts = content as? [[String: Any]] {
                    texts = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                }
            case "attachment":
                // A message typed mid-turn. Only a human origin counts (or
                // none, from builds that didn't record one); subagent
                // hand-backs and task notifications use this shape too.
                guard let a = obj["attachment"] as? [String: Any], a["type"] as? String == "queued_command",
                      (a["commandMode"] as? String).map({ $0 == "prompt" }) ?? true else { continue }
                let origin = (a["origin"] as? [String: Any])?["kind"] as? String
                guard origin == nil || origin == "human" else { continue }
                if let prompt = a["prompt"] as? String { texts = [prompt] }
            default:
                continue
            }
            let text = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }   // tool results only
            if pageAuthored.contains(BatteryPauseSupport.normalize(text)) { continue }
            if text.hasPrefix("[Request interrupted by user"),
               ts.timeIntervalSince(pausedAt) <= BatteryPauseSupport.ownInterruptWindow { continue }
            return .userActed
        }
        if !tailIsComplete, (earliest.map { $0 > pausedAt } ?? true) { return .unknown }
        return .none
    }
}
