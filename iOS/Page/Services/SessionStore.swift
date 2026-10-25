import Foundation
import Combine

/// Live sessions on the paired Mac (docs/SESSIONS-PROTOCOL.md): the list,
/// the transcript of the session being viewed, and where each message typed
/// on this phone stands.
///
/// Kept apart from `APIClient` on purpose: session updates arrive every
/// second while the Mac is busy, and the inbox screens shouldn't re-render
/// for them. `APIClient` forwards `sessions.update` frames here and carries
/// commands to POST /sessions/command; everything else lives in this store.
///
/// All content is end-to-end encrypted with the pairing's session key. It is
/// held in memory only, and never logged: logs carry sizes and outcomes.
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [LiveSession] = []
    /// A `list` has arrived since the last reset.
    @Published private(set) var hasList = false
    /// The last list said live sessions are turned off on the Mac.
    @Published private(set) var macDisabled = false
    @Published private(set) var macName: String?
    @Published private(set) var lastListAt: Date?
    @Published private(set) var transcripts: [String: SessionTranscript] = [:]
    /// The watched session's terminal, from Macs that send it.
    @Published private(set) var screens: [String: SessionScreen] = [:]
    /// Each watched session's dynamic workflows, from Macs that send them.
    @Published private(set) var workflows: [String: [WorkflowRun]] = [:]
    /// The latest `diff` per session, and why the last request failed.
    @Published private(set) var diffs: [String: SessionDiff] = [:]
    @Published private(set) var diffErrors: [String: String] = [:]
    /// Where a session may be started (`folders`), nil until asked.
    @Published private(set) var startFolders: StartFolders?
    @Published private(set) var startFoldersError: String?
    /// Messages and Stops sent from this phone, by `clientId`.
    @Published private(set) var commands: [String: SentSessionCommand] = [:]
    /// From GET /status; nil until known.
    @Published private(set) var relayFeatures: Set<String>?
    @Published private(set) var hasKey = false
    @Published private(set) var macOfflineHint = false
    @Published private(set) var waitStartedAt: Date?
    @Published private(set) var keyMismatch = false
    @Published private(set) var onlyStaleFrames = false
    /// Bumped when the first-list wait runs out, so screens re-evaluate.
    @Published private(set) var waitTick = 0

    /// The session whose detail screen is open, re-sent as `watch`.
    private(set) var watchedSessionId: String?
    /// The workflow agent open on top of the watched session, if any.
    private(set) var watchedAgent: (runId: String, agentId: String)?

    private var gate = SessionUpdateGate()
    private var rootKey: Data?
    private var undecryptableInARow = 0
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    private var waitTask: Task<Void, Never>?

    #if DEBUG
    /// "Skip pairing (DEV)": mock sessions, simulated results, no network.
    private(set) var isDevMode = false
    #endif

    private static let viewerKey = "page.sessions.viewer"
    /// Random per install, persisted: the Mac keeps one watched session per
    /// viewer. Not a secret.
    let viewer: String = {
        if let saved = UserDefaults.standard.string(forKey: SessionStore.viewerKey), !saved.isEmpty { return saved }
        let fresh = UUID().uuidString.lowercased()
        UserDefaults.standard.set(fresh, forKey: SessionStore.viewerKey)
        return fresh
    }()

    private init() {
        reloadKey()
    }

    // MARK: Lookup

    func session(_ id: String) -> LiveSession? {
        sessions.first { $0.id == id }
    }

    /// Messages typed into this session from the phone, oldest first.
    func sentMessages(for sessionId: String) -> [SentSessionCommand] {
        commands.values.filter { $0.sessionId == sessionId && $0.kind == .input }.sorted { $0.sentAt < $1.sentAt }
    }

    /// The most recent Stop for this session, while it's worth showing.
    func latestInterrupt(for sessionId: String, now: Date) -> SentSessionCommand? {
        commands.values
            .filter { $0.sessionId == sessionId && $0.kind == .interrupt }
            .max { $0.sentAt < $1.sentAt }
            .flatMap { $0.state.isPending || now.timeIntervalSince($0.sentAt) < 60 ? $0 : nil }
    }

    func availability(presence: MacPresence, socketConnected: Bool, now: Date) -> SessionAvailability {
        #if DEBUG
        if isDevMode { return .ready }
        #endif
        return SessionAvailability.evaluate(SessionAvailability.Inputs(
            hasKey: hasKey, relayFeatures: relayFeatures, presence: presence,
            macOfflineHint: macOfflineHint, socketConnected: socketConnected,
            waitStartedAt: waitStartedAt, hasList: hasList,
            keyMismatch: keyMismatch, onlyStaleFrames: onlyStaleFrames, macDisabled: macDisabled), now: now)
    }

    // MARK: Lifecycle

    /// Re-reads the session key. The Keychain is unreadable until the first
    /// unlock after a reboot, so this runs again when the app becomes active.
    func reloadKey() {
        #if DEBUG
        if isDevMode { return }
        #endif
        rootKey = SessionKeyStore.current()
        hasKey = rootKey != nil
    }

    /// Clears everything tied to the current pairing. Called from
    /// `APIClient.reset()`, so it runs on unpair, re-pair, retirement and
    /// DEV seeding alike.
    func reset() {
        #if DEBUG
        isDevMode = false
        #endif
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks = [:]
        waitTask?.cancel()
        waitTask = nil
        gate.reset()
        sessions = []
        hasList = false
        macDisabled = false
        macName = nil
        lastListAt = nil
        transcripts = [:]
        screens = [:]
        diffs = [:]
        diffErrors = [:]
        diffClients = [:]
        startFolders = nil
        startFoldersError = nil
        commands = [:]
        relayFeatures = nil
        macOfflineHint = false
        waitStartedAt = nil
        keyMismatch = false
        onlyStaleFrames = false
        undecryptableInARow = 0
        watchedSessionId = nil
        watchedAgent = nil
        workflows = [:]
        reloadKey()
    }

    /// GET /status answered. A relay without /status (404) has no features.
    func relayFeaturesUpdated(_ features: [String]) {
        let next = Set(features)
        if relayFeatures != next { relayFeatures = next }
    }

    /// The phone socket (re)opened: the Mac sends a list when the phone
    /// count goes above zero; also ask for one, and re-arm the watch the
    /// Mac may have expired while we were away.
    func socketOpened() {
        startWaitingForList()
        guard canSend else { return }
        if let id = watchedSessionId { post(watchCommand(id)) }
        post(.refresh)
    }

    /// The Mac just connected to the relay (`mac.status`): a list should
    /// follow within seconds.
    func macCameOnline() {
        macOfflineHint = false
        if !hasList { startWaitingForList() }
    }

    /// Pull to refresh / "Try again".
    func refresh() {
        macOfflineHint = false
        if !hasList { startWaitingForList() }
        guard canSend else { return }
        post(.refresh)
    }

    private func startWaitingForList() {
        waitStartedAt = Date()
        waitTask?.cancel()
        waitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((SessionAvailability.listWait + 0.2) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.waitTick += 1
        }
    }

    // MARK: Watching

    /// The detail screen re-sends this every 30 s while visible and sends
    /// nil when it goes away. Only goes out over a live socket: the Mac
    /// sends nothing while no phone is connected anyway, and the watch is
    /// re-armed on reconnect.
    func watch(_ sessionId: String?) {
        let changed = watchedSessionId != sessionId
        watchedSessionId = sessionId
        if changed || sessionId == nil { watchedAgent = nil }
        guard canSend, APIClient.shared.connection == .connected else { return }
        // Leaving a screen that never watched anything needs no message.
        if sessionId == nil && !changed { return }
        post(sessionId.map(watchCommand) ?? .watch(sessionId: nil))
    }

    /// The agent screen opened (or closed, nil) on top of the session's.
    /// The session screen's periodic re-watch carries it along.
    func watchAgent(sessionId: String, runId: String?, agentId: String?) {
        if let runId, let agentId {
            watchedAgent = (runId, agentId)
            watchedSessionId = sessionId
        } else {
            // Closing the agent screen: back to the session only if its screen
            // is still open (it may have closed first and watched nil).
            guard watchedSessionId == sessionId, watchedAgent != nil else { return }
            watchedAgent = nil
        }
        guard canSend, APIClient.shared.connection == .connected else { return }
        post(watchCommand(sessionId))
    }

    private func watchCommand(_ sessionId: String) -> SessionCommand {
        if let a = watchedAgent { return .watchAgent(sessionId: sessionId, runId: a.runId, agentId: a.agentId) }
        return .watch(sessionId: sessionId)
    }

    /// A workflow agent's transcript, if the Mac sent it.
    func agentTranscript(sessionId: String, runId: String, agentId: String) -> SessionTranscript? {
        transcripts[SessionTranscript.key(sessionId: sessionId, runId: runId, agentId: agentId)]
    }

    // MARK: Incoming

    /// A `sessions.update` frame's payload: `{"e": <envelope>}`.
    func handleUpdate(payload: [String: Any]) {
        #if DEBUG
        if isDevMode { return }
        #endif
        guard let raw = payload["e"] as? [String: Any], let envelope = SessionCrypto.Envelope(json: raw) else {
            print("[SessionStore] dropped malformed update")
            return
        }
        if rootKey == nil { reloadKey() }
        guard let root = rootKey else { return }
        guard let data = SessionCrypto.open(envelope, root: root, direction: .macToPhone, aad: SessionFrameType.update) else {
            undecryptableInARow += 1
            // One bad frame could be noise; a run of them means the Mac's
            // key no longer matches ours.
            if undecryptableInARow >= 2 { keyMismatch = true }
            print("[SessionStore] dropped undecryptable update (\(envelope.sealed.count) bytes)")
            return
        }
        undecryptableInARow = 0
        if keyMismatch { keyMismatch = false }
        guard let plaintext = SessionsPlaintext.decode(data) else { return }  // unknown kind or malformed
        switch gate.admit(plaintext, now: Date()) {
        case .tooOld:
            if !hasList { onlyStaleFrames = true }
            print("[SessionStore] dropped update older than \(Int(SessionUpdateGate.maxAge))s")
            return
        case .outOfOrder:
            return
        case .accept:
            if onlyStaleFrames { onlyStaleFrames = false }
        }
        if case .list = plaintext.update { macDisabled = plaintext.macDisabled }
        apply(plaintext.update)
    }

    private func apply(_ update: SessionsUpdate) {
        switch update {
        case .list(let name, let list):
            sessions = list
            if name != nil { macName = name }
            hasList = true
            lastListAt = Date()
            macOfflineHint = false
            waitTask?.cancel()
            // Transcripts only for sessions that still exist (plus the one on
            // screen, which shows "ended" over its last transcript).
            let live = Set(list.map(\.id))
            let stale = transcripts.filter { !live.contains($0.value.sessionId) && $0.value.sessionId != watchedSessionId }.keys
            for id in stale { transcripts[id] = nil }
            for id in screens.keys where !live.contains(id) && id != watchedSessionId { screens[id] = nil }
            for id in workflows.keys where !live.contains(id) && id != watchedSessionId { workflows[id] = nil }
        case .workflows(let sid, let runs):
            workflows[sid] = runs
            if workflows.count > 4 {
                for id in workflows.keys where id != sid && id != watchedSessionId { workflows[id] = nil; break }
            }
        case .screen(let s):
            screens[s.sessionId] = s
            if screens.count > 4 {
                for id in screens.keys where id != s.sessionId && id != watchedSessionId { screens[id] = nil; break }
            }
        case .transcript(let t):
            transcripts[t.key] = t
            // Keep what's on screen (the session's and the open agent's).
            var keep: Set<String> = [t.key]
            if let sid = watchedSessionId {
                keep.insert(sid)
                if let a = watchedAgent { keep.insert(SessionTranscript.key(sessionId: sid, runId: a.runId, agentId: a.agentId)) }
            }
            while transcripts.count > 12, let victim = transcripts.keys.first(where: { !keep.contains($0) }) {
                transcripts[victim] = nil
            }
        case .diff(let d):
            diffs[d.sessionId] = d
            diffErrors[d.sessionId] = nil
            if diffs.count > 4 {
                for id in diffs.keys where id != d.sessionId && id != watchedSessionId { diffs[id] = nil; break }
            }
        case .folders(let f):
            startFolders = f
            startFoldersError = nil
        case .result(let r):
            if let sid = diffClients.removeValue(forKey: r.clientId) {
                diffErrors[sid] = r.detail ?? "Your Mac couldn't read the changes."
                return
            }
            guard var cmd = commands[r.clientId] else { return }
            cmd.state = cmd.state.applying(r, agent: agentName(cmd.sessionId))
            commands[r.clientId] = cmd
            print("[SessionStore] \(cmd.kind.rawValue) \(r.clientId.prefix(8)) -> \(r.code.rawValue)\(r.reason.map { "/\($0)" } ?? "")")
            if !cmd.state.isPending {
                timeoutTasks[r.clientId]?.cancel()
                timeoutTasks[r.clientId] = nil
            }
        }
    }

    private func agentName(_ sessionId: String) -> String {
        session(sessionId)?.backend.displayName ?? "Your agent"
    }

    // MARK: Outgoing

    private var canSend: Bool {
        #if DEBUG
        if isDevMode { return false }
        #endif
        return rootKey != nil
    }

    /// Types `text` into the session. Returns the problem to show instead
    /// when the text can't be sent; otherwise the message's delivery state
    /// appears in `commands` under a fresh `clientId`.
    func sendInput(sessionId: String, text: String) -> SessionComposer.Problem? {
        let clean: String
        switch SessionComposer.validate(text) {
        case .failure(let problem): return problem
        case .success(let t): clean = t
        }
        #if DEBUG
        if isDevMode {
            simulateDevCommand(.input, sessionId: sessionId, text: clean)
            return nil
        }
        #endif
        let clientId = UUID().uuidString.lowercased()
        guard let body = encrypt(.input(sessionId: sessionId, text: clean), clientId: clientId) else {
            record(clientId: clientId, sessionId: sessionId, kind: .input, text: clean,
                   state: .failed("This iPhone has no session key. Re-pair with your Mac."))
            return nil
        }
        guard SessionComposer.fitsRelay(body) else { return .tooLarge }
        record(clientId: clientId, sessionId: sessionId, kind: .input, text: clean, state: .sending)
        deliver(body, clientId: clientId, op: "input")
        return nil
    }

    /// Stop: the Mac presses Esc in the session.
    func interrupt(sessionId: String) {
        #if DEBUG
        if isDevMode {
            simulateDevCommand(.interrupt, sessionId: sessionId, text: "")
            return
        }
        #endif
        let clientId = UUID().uuidString.lowercased()
        guard let body = encrypt(.interrupt(sessionId: sessionId), clientId: clientId) else {
            record(clientId: clientId, sessionId: sessionId, kind: .interrupt, text: "",
                   state: .failed("This iPhone has no session key. Re-pair with your Mac."))
            return
        }
        record(clientId: clientId, sessionId: sessionId, kind: .interrupt, text: "", state: .sending)
        deliver(body, clientId: clientId, op: "interrupt")
    }

    /// `diff` requests in flight, by clientId → session (a refusal comes back
    /// as a `result`).
    private var diffClients: [String: String] = [:]

    /// Asks the Mac for the session's changes (answered by a `diff`).
    func requestDiff(sessionId: String) {
        diffErrors[sessionId] = nil
        let clientId = UUID().uuidString.lowercased()
        guard let body = encrypt(.diff(sessionId: sessionId), clientId: clientId) else {
            diffErrors[sessionId] = "This iPhone has no session key. Re-pair with your Mac."
            return
        }
        diffClients[clientId] = sessionId
        if diffClients.count > 20 { diffClients.removeAll() ; diffClients[clientId] = sessionId }
        Task {
            let outcome = await APIClient.shared.postSessionCommand(body: body)
            noteOutcome(outcome)
            if let why = outcome.failureMessage { diffErrors[sessionId] = why; diffClients[clientId] = nil }
        }
    }

    /// Asks where a session may be started (answered by `folders`).
    func requestFolders() {
        startFoldersError = nil
        guard let body = encrypt(.folders, clientId: UUID().uuidString.lowercased()) else {
            startFoldersError = "This iPhone has no session key. Re-pair with your Mac."
            return
        }
        Task {
            let outcome = await APIClient.shared.postSessionCommand(body: body)
            noteOutcome(outcome)
            if let why = outcome.failureMessage { startFoldersError = why }
        }
    }

    /// Starts a new Claude session. Returns the clientId whose delivery
    /// state appears in `commands`.
    @discardableResult
    func startSession(folder: String, prompt: String) -> String {
        let clientId = UUID().uuidString.lowercased()
        let key = "new:" + folder
        guard let body = encrypt(.start(folder: folder, prompt: prompt), clientId: clientId) else {
            record(clientId: clientId, sessionId: key, kind: .start, text: prompt,
                   state: .failed("This iPhone has no session key. Re-pair with your Mac."))
            return clientId
        }
        record(clientId: clientId, sessionId: key, kind: .start, text: prompt, state: .sending)
        deliver(body, clientId: clientId, op: "start")
        return clientId
    }

    /// Siri / Shortcuts: Esc in every working session. Returns what the
    /// relay said (the Mac's own answer comes over the socket, which may be
    /// closed while the app is in the background).
    func interruptAll() async -> SessionCommandOutcome {
        let clientId = UUID().uuidString.lowercased()
        guard let body = encrypt(.interruptAll, clientId: clientId) else {
            return .failed("This iPhone has no session key. Re-pair with your Mac.")
        }
        let outcome = await APIClient.shared.postSessionCommand(body: body)
        noteOutcome(outcome)
        return outcome
    }

    private func encrypt(_ command: SessionCommand, clientId: String) -> Data? {
        if rootKey == nil { reloadKey() }
        guard let root = rootKey else { return nil }
        let plaintext = command.plaintext(clientId: clientId, viewer: viewer, now: Date())
        return try? SessionCommand.requestBody(plaintext: plaintext, root: root)
    }

    private func record(clientId: String, sessionId: String, kind: SessionCommandKind, text: String,
                        state: SessionDeliveryState) {
        let sentAt = Date()
        commands[clientId] = SentSessionCommand(clientId: clientId, sessionId: sessionId, kind: kind,
                                                text: text, sentAt: sentAt, state: state,
                                                priorEntryIds: transcripts[sessionId].map { Set($0.entries.map(\.id)) })
        pruneCommands()
        guard state.isPending else { return }
        timeoutTasks[clientId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(SessionDeliveryState.resultTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, var cmd = self.commands[clientId] else { return }
            let next = cmd.state.timedOut(sentAt: sentAt, now: Date())
            if next != cmd.state {
                cmd.state = next
                self.commands[clientId] = cmd
                print("[SessionStore] \(kind.rawValue) \(clientId.prefix(8)) -> no answer")
            }
            self.timeoutTasks[clientId] = nil
        }
    }

    /// Bounded: settled commands older than an hour go first.
    private func pruneCommands() {
        guard commands.count > 200 else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        commands = commands.filter { $0.value.state.isPending || $0.value.sentAt > cutoff }
        if commands.count > 200 {
            let keep = commands.values.sorted { $0.sentAt > $1.sentAt }.prefix(200).map(\.clientId)
            commands = commands.filter { keep.contains($0.key) }
        }
    }

    private func deliver(_ body: Data, clientId: String, op: String) {
        Task {
            let outcome = await APIClient.shared.postSessionCommand(body: body)
            noteOutcome(outcome)
            guard var cmd = commands[clientId] else { return }  // reset meanwhile
            let next = cmd.state.afterPost(outcome)
            print("[SessionStore] \(op) \(clientId.prefix(8)) post -> \(Self.describe(outcome)) (\(body.count) bytes)")
            if next != cmd.state {
                cmd.state = next
                commands[clientId] = cmd
                timeoutTasks[clientId]?.cancel()
                timeoutTasks[clientId] = nil
            }
        }
    }

    /// watch / refresh: fire and forget, no `result` comes back.
    private func post(_ command: SessionCommand) {
        guard let body = encrypt(command, clientId: UUID().uuidString.lowercased()) else { return }
        Task {
            let outcome = await APIClient.shared.postSessionCommand(body: body)
            noteOutcome(outcome)
        }
    }

    /// What a relay answer says about availability.
    private func noteOutcome(_ outcome: SessionCommandOutcome) {
        switch outcome {
        case .macOffline: macOfflineHint = true
        case .relayTooOld: relayFeaturesUpdated([])
        default: break
        }
    }

    private static func describe(_ outcome: SessionCommandOutcome) -> String {
        switch outcome {
        case .accepted: return "accepted"
        case .macOffline: return "mac_offline"
        case .invalid: return "invalid"
        case .tooLarge: return "too_large"
        case .rateLimited: return "rate_limited"
        case .unauthorized: return "unauthorized"
        case .retired: return "token_retired"
        case .relayTooOld: return "no_route"
        case .failed: return "failed"
        }
    }

    // MARK: DEV

    #if DEBUG
    func seedDev(macName: String, sessions list: [LiveSession], transcripts seeded: [SessionTranscript]) {
        reset()
        isDevMode = true
        hasKey = true
        relayFeatures = [SessionAvailability.feature]
        self.macName = macName
        sessions = list
        hasList = true
        lastListAt = Date()
        for t in seeded { transcripts[t.sessionId] = t }
    }

    /// Walks a DEV command through the states a real one goes through,
    /// using the same refusal rules as the Mac's input gate where they're
    /// visible from here.
    private func simulateDevCommand(_ kind: SessionCommandKind, sessionId: String, text: String) {
        let clientId = UUID().uuidString.lowercased()
        record(clientId: clientId, sessionId: sessionId, kind: kind, text: text, state: .sending)
        let target = session(sessionId)
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard self.isDevMode, let target else { return }
            let result: CommandResult
            switch kind {
            case .start:
                result = CommandResult(clientId: clientId, ok: true, code: .delivered, reason: nil,
                                       detail: "Started Claude (simulated)", interventionId: nil)
            case .interrupt:
                result = target.isStoppable
                    ? CommandResult(clientId: clientId, ok: true, code: .delivered, reason: nil, detail: "Pressed Esc in \(target.host) (simulated)", interventionId: nil)
                    : CommandResult(clientId: clientId, ok: false, code: .refused, reason: "interrupt_unsupported", detail: nil, interventionId: nil)
                if target.isStoppable { self.replaceDevSession(target, state: .interrupted) }
            case .input:
                let busy = target.state == .active
                if target.state.isWaiting {
                    result = CommandResult(clientId: clientId, ok: false, code: .refused, reason: "waiting", detail: nil, interventionId: target.interventionId)
                } else if busy, text.first?.isNumber == true {
                    result = CommandResult(clientId: clientId, ok: false, code: .refused, reason: "digit_while_busy", detail: nil, interventionId: nil)
                } else {
                    result = CommandResult(clientId: clientId, ok: true, code: busy ? .queued : .delivered, reason: nil,
                                           detail: busy ? nil : "Typed into \(target.host) (simulated)", interventionId: nil)
                }
            }
            self.apply(.result(result))
            guard kind == .input, result.ok else { return }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard self.isDevMode else { return }
            let old = self.transcripts[sessionId]
            let entry = TranscriptEntry(id: "dev-\(clientId)", role: .user, text: text, at: Date(), tool: nil)
            self.transcripts[sessionId] = SessionTranscript(sessionId: sessionId,
                                                            entries: (old?.entries ?? []) + [entry],
                                                            truncated: old?.truncated ?? false)
        }
    }

    private func replaceDevSession(_ s: LiveSession, state: LiveSessionState) {
        let next = LiveSession(id: s.id, backend: s.backend, title: s.title, cwd: s.cwd, state: state, host: s.host,
                               canType: s.canType, typeBlocker: s.typeBlocker, canInterrupt: s.canInterrupt,
                               provider: s.provider, lastActivityAt: Date(), interventionId: nil, preview: "Interrupted")
        sessions = sessions.map { $0.id == s.id ? next : $0 }
    }
    #endif
}
