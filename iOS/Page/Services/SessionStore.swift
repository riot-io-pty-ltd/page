import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

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
    /// A session started from the phone that has now appeared in the list.
    @Published private(set) var startedSessionId: String?
    /// The started session didn't show up within 90 s.
    @Published private(set) var startWaitExpired = false
    /// The start waiting for its session to show up (folder, sessions that
    /// existed before, when).
    private var pendingStart: (folder: String, existing: Set<String>, at: Date)?
    /// Messages and Stops sent from this phone, by `clientId`.
    @Published private(set) var commands: [String: SentSessionCommand] = [:]
    /// What the Mac accepts beyond the basic ops (the last `list`'s `caps`): `hold-v1`, `retract-v1`, `images-v1`.
    /// Empty from an older Mac, so nothing newer is offered to it.
    @Published private(set) var macCaps: Set<String> = []
    /// Where each Delete stands, by what it takes back (a held message's clientId, or a reply's page id).
    @Published private(set) var retractNotes: [String: RetractNote] = [:]
    /// Drafts a countdown the app was killed on, back for their screen (see `takeRestoredDraft`).
    @Published private(set) var restoredDrafts: [String: RestoredDraft] = [:]
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
    /// Messages waiting out their countdown. App-level on purpose: leaving the room doesn't cancel one.
    private var outbox: [String: QueuedSend] = [:]
    private var outboxTasks: [String: Task<Void, Never>] = [:]
    #if canImport(UIKit)
    private var outboxBackground: [String: UIBackgroundTaskIdentifier] = [:]
    #endif
    /// Held messages (clientIds) seen in a list, so a later absence means the Mac let go of it.
    private var heldSeen: Set<String> = []
    /// retract clientId -> what it takes back.
    private var retractSubjects: [String: String] = [:]
    /// The retracts Page sent because the relay said "forwarded" (see `ForwardedRetract`): they read in the relay's words.
    private var chainedRetracts: Set<String> = []
    /// The outbox file's entries from before this launch, which never went out.
    private var restoredFromFile: [PersistedSend] = []
    /// Photo messages (`images-v1`), by the message's clientId: the re-encoded photos and where the upload stands.
    /// In memory only (never written to disk); gone once the message is delivered or the phone is unpaired.
    private var photoPayloads: [String: PhotoPayload] = [:]
    /// Which bubble each `inputImages` clientId answers for: a resend after `attachment_missing` has a new clientId,
    /// and an answer after the 30 s wait (or a failed POST) still settles the bubble, for 5 minutes.
    private var photoRoutes = PhotoResultRoutes()

    private struct PhotoPayload {
        let sessionId: String
        let caption: String
        let photos: [PreparedPhoto]
        var machine: PhotoUploadMachine
    }

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
        restoredFromFile = OutboxFile.load()
        for d in OutboxRestore.restore(restoredFromFile) { restoredDrafts[d.scope] = d }
    }

    // MARK: Lookup

    func session(_ id: String) -> LiveSession? {
        sessions.first { $0.id == id }
    }

    /// Messages typed into this session from the phone, oldest first.
    func sentMessages(for sessionId: String) -> [SentSessionCommand] {
        commands.values.filter { $0.sessionId == sessionId && $0.kind == .input }.sorted { $0.sentAt < $1.sentAt }
    }

    /// The newest message typed from this phone into this session (its receipt).
    func latestInput(for sessionId: String) -> SentSessionCommand? {
        commands.values.filter { $0.sessionId == sessionId && $0.kind == .input }.max { $0.sentAt < $1.sentAt }
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
        for task in outboxTasks.values { task.cancel() }
        outboxTasks = [:]
        for id in outbox.keys { endBackground(id); OutboxFile.remove(id: id) }
        outbox = [:]
        for id in photoPayloads.keys { endBackground(id) }
        photoPayloads = [:]
        photoRoutes.removeAll()
        heldSeen = []
        retractSubjects = [:]
        chainedRetracts = []
        retractNotes = [:]
        macCaps = []
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
        startedSessionId = nil
        pendingStart = nil
        commands = [:]
        AnswerDraftStore.shared.clear()
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
        if case .list = plaintext.update {
            macDisabled = plaintext.macDisabled
            let caps = plaintext.caps ?? []
            if macCaps != caps { macCaps = caps }
        }
        apply(plaintext.update)
    }

    private func apply(_ update: SessionsUpdate) {
        switch update {
        case .list(let name, let list):
            sessions = list
            if let p = pendingStart {
                if Date().timeIntervalSince(p.at) > 90 {
                    pendingStart = nil
                } else if let s = StartedSessionMatch.find(in: list, folder: p.folder, existing: p.existing) {
                    pendingStart = nil
                    startedSessionId = s.id
                }
            }
            reconcileHeld(list)
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
            // An `inputImages` sent again after `attachment_missing`, or answered late, belongs to the first message.
            let key = photoRoutes.bubble(for: r.clientId, now: Date()) ?? r.clientId
            if let sid = diffClients.removeValue(forKey: r.clientId) {
                diffErrors[sid] = r.detail ?? "Your Mac couldn't read the changes."
                return
            }
            if let subject = retractSubjects.removeValue(forKey: r.clientId) {
                retractAnswered(r, subject: subject)
                return
            }
            guard var cmd = commands[key] else { return }
            // Pieces that never arrived: one resend of those photos, then a new `inputImages`. The second time is final.
            if cmd.photos != nil, cmd.state == .sending, r.reason == "attachment_missing", resendMissingPhotos(key, r) { return }
            // A refused start won't create a session: stop waiting for one.
            if cmd.kind == .start, !r.ok { pendingStart = nil }
            cmd.state = cmd.state.applying(r, agent: agentName(cmd.sessionId))
            if cmd.photos != nil { cmd.photos?.attached = r.attached }
            commands[key] = cmd
            print("[SessionStore] \(cmd.kind.rawValue) \(r.clientId.prefix(8)) -> \(r.code.rawValue)\(r.reason.map { "/\($0)" } ?? "")")
            if !cmd.state.isPending {
                timeoutTasks[key]?.cancel()
                timeoutTasks[key] = nil
                if cmd.photos != nil { settlePhotos(key, cmd.state) }
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
    ///
    /// `hold`: the Mac types it when the turn ends (`hold-v1`), and it can be deleted until then.
    /// `countdown`: wait this many seconds before anything leaves the phone (Undo works until then).
    /// The wait lives here, not in a screen, so leaving the room doesn't cancel the send.
    func sendInput(sessionId: String, text: String, target: SessionTarget? = nil, hold: Bool = false,
                   countdown: TimeInterval? = nil) -> SessionComposer.Problem? {
        let clean: String
        switch SessionComposer.validate(text) {
        case .failure(let problem): return problem
        case .success(let t): clean = t
        }
        #if DEBUG
        if isDevMode {
            simulateDevCommand(.input, sessionId: sessionId, text: clean, target: target, hold: hold)
            return nil
        }
        #endif
        let clientId = UUID().uuidString.lowercased()
        let command = SessionCommand.input(sessionId: sessionId, text: clean, target: target, hold: hold)
        guard let body = encrypt(command, clientId: clientId) else {
            record(clientId: clientId, sessionId: sessionId, kind: .input, text: clean,
                   state: .failed("This iPhone has no session key. Re-pair with your Mac."), target: target)
            return nil
        }
        guard SessionComposer.fitsRelay(body) else { return .tooLarge }
        if let seconds = countdown, seconds > 0, !hold {
            let cd = SendCountdown(startedAt: Date(), duration: seconds)
            outbox[clientId] = QueuedSend(id: clientId, sessionId: sessionId, text: clean, countdown: cd)
            record(clientId: clientId, sessionId: sessionId, kind: .input, text: clean, state: .counting(cd), target: target)
            OutboxFile.add(PersistedSend(id: clientId, scope: OutboxRestore.scope(sessionId: sessionId), text: clean,
                                         startedAt: cd.startedAt.timeIntervalSince1970))
            scheduleFire(clientId)
            return nil
        }
        record(clientId: clientId, sessionId: sessionId, kind: .input, text: clean, state: .sending, target: target)
        deliver(body, clientId: clientId, op: "input")
        return nil
    }

    // MARK: Outbox (the Undo before a send)

    /// Undo: nothing was sent, the message is gone from the outbox and its text is returned for the
    /// composer. Nil once the send has begun.
    func undoSend(clientId: String) -> String? {
        guard var q = outbox[clientId], q.undo(now: Date()) else { return nil }
        outboxTasks[clientId]?.cancel()
        outboxTasks[clientId] = nil
        outbox[clientId] = nil
        commands[clientId] = nil
        OutboxFile.remove(id: clientId)
        endBackground(clientId)
        return q.text
    }

    /// The app came back to the foreground: a countdown that ran out meanwhile fires (or, if the app
    /// slept through it, comes back as a draft).
    func appBecameActive() {
        for id in Array(outbox.keys) { fireOutbox(id) }
    }

    private func scheduleFire(_ id: String) {
        guard let q = outbox[id] else { return }
        beginBackground(id)
        outboxTasks[id]?.cancel()
        outboxTasks[id] = Task { [weak self] in
            let wait = max(0, q.countdown.remaining(now: Date())) + 0.02
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.fireOutbox(id)
        }
    }

    private func fireOutbox(_ id: String) {
        guard var q = outbox[id] else { return }
        let verdict = q.fire(now: Date())
        switch verdict {
        case .wait:
            // Woke early (a clock step): sleep the rest.
            scheduleFire(id)
        case .stale:
            outbox[id] = nil
            outboxTasks[id] = nil
            commands[id] = nil
            OutboxFile.remove(id: id)
            endBackground(id)
            restoreDraft(scope: OutboxRestore.scope(sessionId: q.sessionId), text: q.text, note: RestoredDraft.slept)
        case .send:
            outbox[id] = nil
            outboxTasks[id] = nil
            OutboxFile.remove(id: id)
            guard var cmd = commands[id] else { endBackground(id); return }
            // Encrypted now, so the Mac's replay guard sees a fresh timestamp.
            guard let body = encrypt(.input(sessionId: q.sessionId, text: q.text, target: cmd.target), clientId: id) else {
                cmd.state = .failed("This iPhone has no session key. Re-pair with your Mac.")
                commands[id] = cmd
                endBackground(id)
                return
            }
            cmd.sentAt = Date()
            cmd.state = .sending
            commands[id] = cmd
            startTimeout(clientId: id, kind: .input, sentAt: cmd.sentAt)
            deliver(body, clientId: id, op: "input")
        }
    }

    /// Words that didn't go out (the page closed while they waited), kept for their screen.
    func restoreDraft(scope: String, text: String, note: String = RestoredDraft.answeredNote) {
        restoredDrafts[scope] = RestoredDraft(scope: scope, text: text, note: note)
    }

    /// A draft a killed countdown left, for the screen it belongs to (consumed on reading).
    func takeRestoredDraft(scope: String) -> RestoredDraft? {
        guard let d = restoredDrafts.removeValue(forKey: scope) else { return nil }
        for item in restoredFromFile where item.scope == scope { OutboxFile.remove(id: item.id) }
        restoredFromFile.removeAll { $0.scope == scope }
        return d
    }

    /// Holds the app awake long enough to send what the countdown promised if the person leaves Page.
    private func beginBackground(_ id: String) {
        #if canImport(UIKit)
        guard outboxBackground[id] == nil else { return }
        outboxBackground[id] = UIApplication.shared.beginBackgroundTask(withName: "page-outbox") { [weak self] in
            Task { @MainActor in self?.endBackground(id) }
        }
        #endif
    }

    private func endBackground(_ id: String) {
        #if canImport(UIKit)
        if let t = outboxBackground.removeValue(forKey: id), t != .invalid { UIApplication.shared.endBackgroundTask(t) }
        #endif
    }

    // MARK: Photos (images-v1)

    /// Sends the photos with a caption into the session: each photo in pieces (every piece its own sealed
    /// `imagePart`, at most 3 in flight), then one `inputImages` once every piece got its 202. Returns the problem
    /// to show instead when nothing could be started; otherwise the message appears in `commands` under a fresh
    /// `clientId` and its state walks Uploading → Typing → the Mac's result.
    func sendPhotos(sessionId: String, text: String, photos: [PreparedPhoto], target: SessionTarget? = nil, attach: String? = nil) -> String? {
        guard macCaps.contains(PhotoLimits.capability) else { return PhotoOffer.goneReason }
        let total = photos.reduce(0) { $0 + $1.bytes }
        guard !photos.isEmpty, photos.count <= PhotoLimits.maxPhotos, total <= PhotoLimits.maxBytesTotal else {
            return PhotoEncoder.Failure.overTotal.message
        }
        let caption = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let why = PhotoCaption.problem(caption) { return why }
        let pieces = photos.reduce(0) { $0 + $1.pieceCount }
        #if DEBUG
        if isDevMode {
            simulateDevPhotos(sessionId: sessionId, text: caption, count: photos.count, pieces: pieces, target: target, attach: attach)
            return nil
        }
        #endif
        let id = UUID().uuidString.lowercased()
        // The wait for the Mac's result starts with `inputImages`, not now.
        record(clientId: id, sessionId: sessionId, kind: .input, text: caption, state: .sending, target: target, timeout: nil)
        commands[id]?.photos = PhotoSend(count: photos.count, attach: attach, phase: .uploading(done: 0, total: pieces), attached: nil)
        releasePhotos(except: id)
        photoPayloads[id] = PhotoPayload(sessionId: sessionId, caption: caption, photos: photos,
                                         machine: PhotoUploadMachine(counts: photos.map(\.pieceCount)))
        // The upload takes a moment: keep the app awake for it if the person leaves Page.
        beginBackground(id)
        Task { await uploadPhotos(id) }
        return nil
    }

    /// Posts every piece of the message's photos (3 at a time) until the machine says all were accepted, or stops.
    private func uploadPhotos(_ id: String) async {
        guard let payload = photoPayloads[id] else { return }
        var machine = payload.machine
        func body(_ ref: PhotoPieceRef) -> Data? {
            let p = payload.photos[ref.photo]
            let range = PhotoPieces.range(index: ref.index, bytes: p.bytes)
            // A new clientId for every post, so a retried piece is a new command to the Mac and the relay.
            return encrypt(.imagePart(sessionId: payload.sessionId, photo: PhotoRef(p), index: ref.index, total: p.pieceCount,
                                      data: p.data.subdata(in: range)), clientId: UUID().uuidString.lowercased())
        }
        guard body(PhotoPieceRef(photo: 0, index: 0)) != nil else {
            failPhotos(id, "This iPhone has no session key. Re-pair with your Mac.")
            return
        }
        await withTaskGroup(of: (PhotoPieceRef, SessionCommandOutcome).self) { group in
            var inFlight = 0
            while true {
                guard photoPayloads[id] != nil else { group.cancelAll(); return }
                for ref in machine.startable(now: Date()) {
                    guard let data = body(ref) else { machine.finished(ref, .failed("This iPhone has no session key. Re-pair with your Mac."), now: Date()); continue }
                    inFlight += 1
                    group.addTask { @MainActor in (ref, await APIClient.shared.postSessionCommand(body: data)) }
                }
                if inFlight == 0 {
                    guard machine.phase == .uploading else { return }
                    // Backing off after a 429: nothing is in flight to wait for.
                    try? await Task.sleep(nanoseconds: UInt64((machine.wait(now: Date()) + 0.02) * 1_000_000_000))
                    continue
                }
                guard let (ref, outcome) = await group.next() else { return }
                inFlight -= 1
                noteOutcome(outcome)
                machine.finished(ref, outcome, now: Date())
                commands[id]?.photos?.phase = .uploading(done: machine.doneCount, total: machine.total)
            }
        }
        guard photoPayloads[id] != nil else { return }
        photoPayloads[id]?.machine = machine
        switch machine.phase {
        case .ready: sendInputImages(id)
        case .stopped(let why): failPhotos(id, why)
        case .uploading: break
        }
    }

    /// Every piece was accepted: the one `inputImages` that names the photos and carries the caption.
    private func sendInputImages(_ id: String) {
        guard let payload = photoPayloads[id], var cmd = commands[id], cmd.state == .sending else { return }
        // After a resend the first command's id was spent: the new one answers for the same message.
        let clientId = payload.machine.resent ? UUID().uuidString.lowercased() : id
        let command = SessionCommand.inputImages(sessionId: payload.sessionId, text: payload.caption,
                                                 photos: payload.photos.map(PhotoRef.init), target: cmd.target)
        guard let data = encrypt(command, clientId: clientId) else {
            failPhotos(id, "This iPhone has no session key. Re-pair with your Mac.")
            return
        }
        photoRoutes.record(clientId: clientId, bubble: id, now: Date())
        cmd.photos?.phase = .typing
        cmd.sentAt = Date()
        commands[id] = cmd
        startTimeout(clientId: id, kind: .input, sentAt: cmd.sentAt, timeout: PhotoLimits.resultTimeout)
        deliver(data, clientId: id, op: "inputImages")
    }

    /// `attachment_missing`: send the named photos' pieces again, once, then a new `inputImages`. False when it
    /// was already done (the second time is the answer) or the ids named no photo.
    private func resendMissingPhotos(_ id: String, _ r: CommandResult) -> Bool {
        guard var payload = photoPayloads[id] else { return false }
        let which = r.missing.compactMap { m in payload.photos.firstIndex { $0.id == m } }
        guard payload.machine.resend(photos: which) else { return false }
        photoPayloads[id] = payload
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        commands[id]?.photos?.phase = .uploading(done: payload.machine.doneCount, total: payload.machine.total)
        beginBackground(id)
        Task { await uploadPhotos(id) }
        return true
    }

    private func failPhotos(_ id: String, _ why: String) {
        guard var cmd = commands[id] else { return }
        cmd.state = .failed(why)
        commands[id] = cmd
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        endBackground(id)
        settlePhotos(id, cmd.state)
    }

    /// A photo message that has settled: delivered, so the bytes go; refused or failed, so the photos can be put
    /// back (the latest one only); no answer, so nothing is held that might be sent twice.
    private func settlePhotos(_ id: String, _ state: SessionDeliveryState) {
        switch state {
        case .refused, .failed: releasePhotos(except: id)
        default: photoPayloads[id] = nil
        }
        endBackground(id)
    }

    private func releasePhotos(except id: String) {
        for key in photoPayloads.keys where key != id { photoPayloads[key] = nil }
    }

    /// The message whose photos are still held after a refusal, so the composer can take them back.
    func puttableBackPhotoMessage(sessionId: String) -> String? {
        photoPayloads.first { key, value in
            guard value.sessionId == sessionId, let c = commands[key] else { return false }
            switch c.state { case .refused, .failed: return true; default: return false }
        }?.key
    }

    /// Puts a refused photo message back: its caption and photos return to the composer and the bubble goes.
    func takeBackPhotos(clientId: String) -> (text: String, photos: [PreparedPhoto])? {
        guard let payload = photoPayloads[clientId], let c = commands[clientId] else { return nil }
        switch c.state { case .refused, .failed: break; default: return nil }
        photoPayloads[clientId] = nil
        commands[clientId] = nil
        return (payload.caption, payload.photos)
    }

    // MARK: Held messages and Delete

    /// Settles held messages from the list's `held` entries, which reach phones that were not connected
    /// for the `result`. A message is "no longer held" only once it was seen held and then isn't, or
    /// when its session left the list: a list built just before the Mac accepted it names nothing yet.
    private func reconcileHeld(_ list: [LiveSession]) {
        for (id, cmd) in commands where cmd.kind == .input {
            switch cmd.state {
            case .held, .sending, .noAnswer: break
            default: continue
            }
            let session = list.first { $0.id == cmd.sessionId }
            // A Mac with live sessions turned off lists nothing: that isn't the session ending, or a message gone.
            if macDisabled { continue }
            let next = cmd.state.reconciled(entry: session?.held.first { $0.clientId == id },
                                            seen: heldSeen.contains(id), sessionListed: session != nil,
                                            sentAt: cmd.sentAt, now: Date())
            if next != cmd.state {
                var c = cmd
                c.state = next
                commands[id] = c
                if !next.isPending { timeoutTasks[id]?.cancel(); timeoutTasks[id] = nil }
            }
        }
        for s in list { for h in s.held { heldSeen.insert(h.clientId) } }
        if heldSeen.count > 400 && !macDisabled { heldSeen = Set(list.flatMap { $0.held.map(\.clientId) }) }
    }

    /// Delete a message the Mac holds (`retract` with `heldId`). Only a Mac that says `retract-v1` is asked.
    func deleteHeld(clientId heldId: String, sessionId: String) {
        sendRetract(subject: heldId, sessionId: sessionId, command: .retract(heldId: heldId, interventionId: nil))
    }

    /// Delete a reply the Mac holds until a rate limit resets (`retract` with `interventionId`).
    func deleteHeldReply(interventionId: String, sessionId: String) {
        sendRetract(subject: interventionId, sessionId: sessionId, command: .retract(heldId: nil, interventionId: interventionId))
    }

    /// The relay said it already handed this reply to the Mac (`DELETE /reply` answered 409 `too_late`, stage
    /// `forwarded`): the Mac may still hold it, so ask it to take it back. The line reads "Asking your Mac…" meanwhile,
    /// then the Mac's answer in the relay's words (`ForwardedRetract`).
    func askMacToRetractForwarded(interventionId: String, sessionId: String) {
        guard macCaps.contains(SendChoicePlan.retractCap) else { noteRelayRetract(id: interventionId, ForwardedRetract.timeoutNote); return }
        sendRetract(subject: interventionId, sessionId: sessionId, command: .retract(heldId: nil, interventionId: interventionId), chained: true)
    }

    private func sendRetract(subject: String, sessionId: String, command: SessionCommand, chained: Bool = false) {
        // The chained ask follows a Delete that was busy a moment ago: it sets the busy note itself.
        guard macCaps.contains(SendChoicePlan.retractCap), chained || retractNotes[subject]?.isBusy != true else { return }
        #if DEBUG
        if isDevMode {
            retractNotes[subject] = chained ? .askingMac : .deleting
            Task {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard self.isDevMode else { return }
                self.retractNotes[subject] = .deleted(SessionDeliveryState.deletedCopy)
                if var c = self.commands[subject] { c.state = .deleted(SessionDeliveryState.deletedCopy); self.commands[subject] = c }
            }
            return
        }
        #endif
        let rid = UUID().uuidString.lowercased()
        guard let body = encrypt(command, clientId: rid) else {
            retractNotes[subject] = chained ? ForwardedRetract.timeoutNote : .failed("This iPhone has no session key. Re-pair with your Mac.")
            return
        }
        retractNotes[subject] = chained ? .askingMac : .deleting
        retractSubjects[rid] = subject
        if chained { chainedRetracts.insert(rid) }
        record(clientId: rid, sessionId: sessionId, kind: .retract, text: "", state: .sending, subject: subject)
        deliver(body, clientId: rid, op: "retract")
    }

    /// The Mac answered a Delete. Keyed on `retract`, never on `code`: a delete arrives as `delivered`.
    private func retractAnswered(_ r: CommandResult, subject: String) {
        timeoutTasks[r.clientId]?.cancel()
        timeoutTasks[r.clientId] = nil
        commands[r.clientId] = nil
        let note = chainedRetracts.remove(r.clientId) != nil ? ForwardedRetract.note(for: r) : RetractOutcome.note(for: r)
        retractNotes[subject] = note
        print("[SessionStore] retract \(r.clientId.prefix(8)) -> \(note)")
        guard case .deleted(let why) = note else { return }
        // A held message's own final result (`cancelled`) follows; this settles it at once.
        if var c = commands[subject], c.state.isHeld { c.state = .deleted(why); commands[subject] = c }
        // A held reply: the page is free for a new answer.
        APIClient.shared.markRetracted(interventionId: subject, detail: why)
    }

    /// The relay answered DELETE /reply/<id> (or it never got there).
    func noteRelayRetract(id: String, _ note: RetractNote?) {
        if let note { retractNotes[id] = note } else { retractNotes[id] = nil }
    }

    /// The newest answers sent for this very question (the ask's id), for the card's receipt.
    func latestAnswer(for sessionId: String, promptKey: String) -> SentSessionCommand? {
        AnswerPicker.delivery(Array(commands.values), sessionId: sessionId, promptKey: promptKey)
    }

    /// Answers the question dialog the session is blocked on. `sheet` holds
    /// the draft; only a complete one is sent (the Mac replays it key by key
    /// and refuses if the question on screen is no longer this one). The
    /// delivery state appears in `commands` like a message's.
    func sendAnswer(sessionId: String, sheet: AnswerSheet, target: SessionTarget? = nil) {
        guard let answers = sheet.wire() else { return }
        let summary = sheet.summaryLine
        #if DEBUG
        if isDevMode {
            simulateDevCommand(.answer, sessionId: sessionId, text: summary, target: target, promptKey: sheet.ask.id)
            return
        }
        #endif
        let clientId = UUID().uuidString.lowercased()
        let command = SessionCommand.answer(sessionId: sessionId, promptKey: sheet.ask.id, answers: answers, target: target)
        guard let body = encrypt(command, clientId: clientId) else {
            record(clientId: clientId, sessionId: sessionId, kind: .answer, text: summary,
                   state: .failed("This iPhone has no session key. Re-pair with your Mac."), target: target, promptKey: sheet.ask.id)
            return
        }
        record(clientId: clientId, sessionId: sessionId, kind: .answer, text: summary, state: .sending, target: target, promptKey: sheet.ask.id)
        deliver(body, clientId: clientId, op: "answer")
    }

    /// Stop: the Mac presses Esc in the session.
    func interrupt(sessionId: String, target: SessionTarget? = nil) {
        #if DEBUG
        if isDevMode {
            simulateDevCommand(.interrupt, sessionId: sessionId, text: "", target: target)
            return
        }
        #endif
        let clientId = UUID().uuidString.lowercased()
        guard let body = encrypt(.interrupt(sessionId: sessionId, target: target), clientId: clientId) else {
            record(clientId: clientId, sessionId: sessionId, kind: .interrupt, text: "",
                   state: .failed("This iPhone has no session key. Re-pair with your Mac."), target: target)
            return
        }
        record(clientId: clientId, sessionId: sessionId, kind: .interrupt, text: "", state: .sending, target: target)
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

    func clearStartedSession() { startedSessionId = nil }

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
        startedSessionId = nil
        startWaitExpired = false
        let at = Date()
        pendingStart = (folder, Set(sessions.map(\.id)), at)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard let self, let p = self.pendingStart, p.at == at else { return }
            self.pendingStart = nil
            self.startWaitExpired = true
        }
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
                        state: SessionDeliveryState, target: SessionTarget? = nil, promptKey: String? = nil, subject: String? = nil,
                        timeout: TimeInterval? = SessionDeliveryState.resultTimeout) {
        let sentAt = Date()
        commands[clientId] = SentSessionCommand(clientId: clientId, sessionId: sessionId, kind: kind,
                                                text: text, sentAt: sentAt, state: state,
                                                priorEntryIds: transcripts[sessionId].map { Set($0.entries.map(\.id)) },
                                                target: target, promptKey: promptKey, subject: subject)
        pruneCommands()
        guard state.isPending, let timeout else { return }
        startTimeout(clientId: clientId, kind: kind, sentAt: sentAt, timeout: timeout)
    }

    /// The 20 s wait for the Mac's `result`, counted from when the send began.
    private func startTimeout(clientId: String, kind: SessionCommandKind, sentAt: Date,
                              timeout: TimeInterval = SessionDeliveryState.resultTimeout) {
        timeoutTasks[clientId]?.cancel()
        timeoutTasks[clientId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, var cmd = self.commands[clientId] else { return }
            let next = cmd.state.timedOut(sentAt: sentAt, now: Date(), timeout: timeout)
            if next != cmd.state {
                cmd.state = next
                self.commands[clientId] = cmd
                print("[SessionStore] \(kind.rawValue) \(clientId.prefix(8)) -> no answer")
                if cmd.photos != nil { self.settlePhotos(clientId, next) }
                // A Delete the Mac never answered (an older Mac ignores the op).
                if kind == .retract, let subject = cmd.subject {
                    self.retractNotes[subject] = self.chainedRetracts.remove(clientId) != nil ? ForwardedRetract.timeoutNote : .unconfirmed
                    self.retractSubjects[clientId] = nil
                }
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
                if cmd.kind == .retract, let subject = cmd.subject, case .failed(let why) = next {
                    // The relay already said the Mac has it: a retract that didn't get through leaves that as the word.
                    retractNotes[subject] = chainedRetracts.remove(clientId) != nil ? ForwardedRetract.timeoutNote
                        : RetractNote.postFailure(outcome) ?? .failed(why)
                    retractSubjects[clientId] = nil
                }
            }
            endBackground(clientId)
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
        macCaps = [SendChoicePlan.holdCap, SendChoicePlan.retractCap, PhotoLimits.capability]
        lastListAt = Date()
        for t in seeded { transcripts[t.sessionId] = t }
    }

    /// Walks a DEV command through the states a real one goes through,
    /// using the same refusal rules as the Mac's input gate where they're
    /// visible from here.
    private func simulateDevCommand(_ kind: SessionCommandKind, sessionId: String, text: String, target shown: SessionTarget? = nil,
                                    promptKey: String? = nil, hold: Bool = false) {
        let clientId = UUID().uuidString.lowercased()
        record(clientId: clientId, sessionId: sessionId, kind: kind, text: text, state: .sending, target: shown, promptKey: promptKey)
        let target = session(sessionId)
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard self.isDevMode, let target else { return }
            let result: CommandResult
            switch kind {
            case .start:
                result = CommandResult(clientId: clientId, ok: true, code: .delivered, reason: nil,
                                       detail: "Started Claude (simulated)", interventionId: nil)
            case .answer:
                result = CommandResult(clientId: clientId, ok: true, code: .delivered, reason: nil,
                                       detail: "Answered in \(target.host) (simulated)", interventionId: nil)
            case .interrupt:
                result = target.isStoppable
                    ? CommandResult(clientId: clientId, ok: true, code: .delivered, reason: nil, detail: "Pressed Esc in \(target.host) (simulated)", interventionId: nil)
                    : CommandResult(clientId: clientId, ok: false, code: .refused, reason: "interrupt_unsupported", detail: nil, interventionId: nil)
                if target.isStoppable { self.replaceDevSession(target, state: .interrupted) }
            case .retract:
                return
            case .input:
                let busy = target.state == .active
                if hold && busy {
                    self.apply(.result(CommandResult(clientId: clientId, ok: true, code: .queued, reason: nil,
                                                     detail: "Held — Page types it when Claude finishes this turn (simulated)", interventionId: nil, held: true)))
                    return
                }
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

    /// A photo message in DEV mode: the upload walks its pieces, then the Mac "types" them.
    private func simulateDevPhotos(sessionId: String, text: String, count: Int, pieces: Int, target: SessionTarget?, attach: String?) {
        let clientId = UUID().uuidString.lowercased()
        record(clientId: clientId, sessionId: sessionId, kind: .input, text: text, state: .sending, target: target, timeout: nil)
        commands[clientId]?.photos = PhotoSend(count: count, attach: attach, phase: .uploading(done: 0, total: pieces), attached: nil)
        Task {
            for done in stride(from: 0, through: pieces, by: max(1, pieces / 4)) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard self.isDevMode else { return }
                self.commands[clientId]?.photos?.phase = .uploading(done: done, total: pieces)
            }
            guard self.isDevMode else { return }
            self.commands[clientId]?.photos?.phase = .typing
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard self.isDevMode, var c = self.commands[clientId] else { return }
            c.photos?.attached = count
            c.state = .typed("Sent \(PhotoDraft.countLabel(count)) to Claude in \(c.target?.host ?? "the terminal") (simulated)")
            self.commands[clientId] = c
            let old = self.transcripts[sessionId]
            let entry = TranscriptEntry(id: "dev-\(clientId)", role: .user,
                                        text: (0..<count).map { "[Image #\($0 + 1)]" }.joined(separator: " ") + text, at: Date(), tool: nil, images: count)
            self.transcripts[sessionId] = SessionTranscript(sessionId: sessionId, entries: (old?.entries ?? []) + [entry], truncated: old?.truncated ?? false)
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

/// The messages waiting out a countdown, kept on disk only while they wait, so one the app was killed
/// on isn't lost: it is removed the moment it is sent or undone, and what is left at the next launch
/// comes back as a draft (`OutboxRestore`). The only place a typed message touches disk: encrypted at
/// rest by the device, never logged, and gone within seconds.
///
/// The protection is "until first unlock", not "complete": a countdown that runs out while the phone is
/// locked still sends (under its background task), and the entry must be removable then. With complete
/// protection the file can't be read once the phone locks, the entry would stay, and the next launch
/// would give back as "not sent" a message that was sent, inviting a second send.
enum OutboxFile {
    private static var url: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("page-outbox.json")
    }

    static func load() -> [PersistedSend] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PersistedSend].self, from: data)) ?? []
    }

    private static func save(_ items: [PersistedSend]) {
        guard let url else { return }
        if items.isEmpty { try? FileManager.default.removeItem(at: url); return }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func add(_ item: PersistedSend) {
        var items = load().filter { $0.id != item.id }
        items.append(item)
        save(items)
    }

    static func remove(id: String) {
        guard let url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? Data(contentsOf: url) else {
            // There but unreadable: drop it whole. Losing a restore is better than one that says
            // "not sent" about a message that went.
            try? FileManager.default.removeItem(at: url)
            return
        }
        let items = (try? JSONDecoder().decode([PersistedSend].self, from: data)) ?? []
        let kept = items.filter { $0.id != id }
        if kept.count != items.count { save(kept) }
    }
}

/// The last "Now" / "When it finishes" choice, kept per device, and whether its one-line explanations
/// have been seen (they show until a message has gone out with the choice in front of the person).
enum SendChoiceMemory {
    private static let lastKey = "page.sendChoice.last"
    private static let explainedKey = "page.sendChoice.explained"

    static var last: SendChoice? {
        UserDefaults.standard.string(forKey: lastKey).flatMap(SendChoice.init(rawValue:))
    }

    static func remember(_ choice: SendChoice) { UserDefaults.standard.set(choice.rawValue, forKey: lastKey) }

    static var explained: Bool { UserDefaults.standard.bool(forKey: explainedKey) }

    static func markExplained() { UserDefaults.standard.set(true, forKey: explainedKey) }
}
