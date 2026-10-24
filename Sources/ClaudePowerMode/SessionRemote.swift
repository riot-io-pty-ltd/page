import Foundation

/// Where sealed live-sessions updates go: the relay socket. Thread-safe;
/// `sendSessionsUpdate` drops the frame when the socket is down (never
/// queued, see `RelayClient.sendSessionsUpdate`).
protocol SessionsUpdateSink: AnyObject {
    var isConnected: Bool { get }
    func sendSessionsUpdate(_ envelope: SessionEnvelope)
}

/// Where a session runs, as the phone's list shows it.
struct SessionHostInfo: Equatable {
    /// Wire value: "cmux" | "tmux" | "Terminal" | "iTerm" | "Ghostty" |
    /// "VS Code" | "desktop" | "unknown".
    var host: String
    var canType: Bool
    /// Why not, when `canType` is false (shown instead of the composer).
    var typeBlocker: String?
    var canInterrupt: Bool
    var provider: ModelProvider = .unknown

    /// Not probed yet.
    static let checking = SessionHostInfo(host: "unknown", canType: false,
                                          typeBlocker: "Checking where this session runs…", canInterrupt: false)

    static func blocked(_ host: String, _ why: String, provider: ModelProvider = .unknown) -> SessionHostInfo {
        SessionHostInfo(host: host, canType: false, typeBlocker: why, canInterrupt: false, provider: provider)
    }
}

struct SessionTranscriptFile: Equatable {
    let path: String
    let format: SessionTranscript.Format
}

/// What `SessionRemote` needs from the agent backends. The live
/// implementation is `LiveSessionBackends`; tests use a fake.
protocol SessionRemoteBackends: AnyObject {
    /// Where each session runs. Blocking (ps, tmux, lsof); called only on
    /// the probe queue, only while a phone is looking.
    func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo]
    /// Fresh Claude statuses by session id (one small file read each), so
    /// the list doesn't lag a long check interval.
    func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus]
    func transcriptFile(for session: AgentSession) -> SessionTranscriptFile?
    /// Runs the input gate and delivers, on the backend's own queue.
    /// `completion` may run on any queue.
    func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?,
               completion: @escaping (SessionCommandResult) -> Void)
    func interrupt(_ session: AgentSession, interventionId: String?,
                   completion: @escaping (SessionCommandResult) -> Void)
}

/// One phone → Mac command, decrypted (SESSIONS-PROTOCOL.md §5).
struct SessionCommand: Equatable {
    let op: String
    let clientId: String
    /// ms since 1970, phone clock.
    let ts: Double
    let viewer: String?
    let sessionId: String?
    let text: String?

    static let maxIdLength = 128

    /// nil unless the plaintext has a string `op`, a non-empty `clientId`
    /// and a numeric `ts`. Unknown fields are ignored.
    static func parse(_ data: Data) -> SessionCommand? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = obj["op"] as? String,
              let clientId = obj["clientId"] as? String, !clientId.isEmpty, clientId.count <= maxIdLength,
              let ts = (obj["ts"] as? NSNumber)?.doubleValue, ts.isFinite else { return nil }
        let viewer = (obj["viewer"] as? String).flatMap { $0.isEmpty || $0.count > maxIdLength ? nil : $0 }
        let sessionId = (obj["sessionId"] as? String).flatMap { $0.isEmpty || $0.count > 256 ? nil : $0 }
        return SessionCommand(op: op, clientId: clientId, ts: ts, viewer: viewer, sessionId: sessionId,
                              text: obj["text"] as? String)
    }
}

/// Client ids seen in the last 15 minutes (at most 2000): a replayed
/// command is dropped, never acted on twice.
struct SessionReplayGuard {
    static let window: TimeInterval = 15 * 60
    static let capacity = 2000

    private var seen: [String: Date] = [:]
    private var order: [String] = []

    var count: Int { seen.count }

    /// True (and remembers `clientId`) the first time; false for a replay.
    mutating func admit(_ clientId: String, now: Date) -> Bool {
        while let oldest = order.first, let at = seen[oldest], now.timeIntervalSince(at) > Self.window {
            order.removeFirst()
            seen.removeValue(forKey: oldest)
        }
        guard seen[clientId] == nil else { return false }
        seen[clientId] = now
        order.append(clientId)
        while order.count > Self.capacity { seen.removeValue(forKey: order.removeFirst()) }
        return true
    }
}

/// Which session each phone viewer is looking at, each for 90 s unless
/// re-sent (the phone re-sends every 30 s while the screen is open).
struct SessionWatchers {
    static let ttl: TimeInterval = 90
    static let maxViewers = 32

    private var byViewer: [String: (sessionId: String, expires: Date)] = [:]

    mutating func set(viewer: String, sessionId: String?, now: Date) {
        guard let sessionId else {
            byViewer.removeValue(forKey: viewer)
            return
        }
        byViewer[viewer] = (sessionId, now.addingTimeInterval(Self.ttl))
        if byViewer.count > Self.maxViewers, let oldest = byViewer.min(by: { $0.value.expires < $1.value.expires })?.key {
            byViewer.removeValue(forKey: oldest)
        }
    }

    mutating func prune(now: Date) {
        byViewer = byViewer.filter { $0.value.expires > now }
    }

    func session(forViewer viewer: String, now: Date) -> String? {
        guard let w = byViewer[viewer], w.expires > now else { return nil }
        return w.sessionId
    }

    func watched(now: Date) -> Set<String> {
        Set(byViewer.values.filter { $0.expires > now }.map(\.sessionId))
    }
}

/// When to send (pure; SESSIONS-PROTOCOL.md §4, §7).
enum SessionsSchedule {
    static let listThrottle: TimeInterval = 1
    static let liveness: TimeInterval = 20
    static let transcriptThrottle: TimeInterval = 1.5

    /// Nothing while no phone is looking. Otherwise: the first list right
    /// away, a changed list at most once a second, and the same list again
    /// every 20 s.
    static func listDue(phones: Int, changed: Bool, lastSentAt: Date?, now: Date) -> Bool {
        guard phones > 0 else { return false }
        guard let last = lastSentAt else { return true }
        let since = now.timeIntervalSince(last)
        return since >= liveness || (changed && since >= listThrottle)
    }

    /// A watched session's transcript is re-checked at most every 1.5 s.
    static func transcriptDue(phones: Int, lastCheckedAt: Date?, now: Date) -> Bool {
        guard phones > 0 else { return false }
        guard let last = lastCheckedAt else { return true }
        return now.timeIntervalSince(last) >= transcriptThrottle
    }
}

/// What the Mac does with an incoming `sessions.command` envelope, decided
/// in the spec's order (§5 Acceptance).
enum SessionCommandAcceptance: Equatable {
    /// Dropped without a reply; the string is for the log (no content).
    case drop(String)
    case reply(clientId: String, SessionCommandResult)
    case accept(SessionCommand)
}

/// One row of the phone's list (SESSIONS-PROTOCOL.md §4 `list`).
struct RemoteSessionRow: Equatable {
    let id: String
    let backend: String
    let title: String
    let cwd: String?
    let state: AgentSessionState
    let host: SessionHostInfo
    let lastActivityAt: Date?
    let interventionId: String?
    let preview: String?

    var jsonObject: [String: Any] {
        var o: [String: Any] = [
            "id": id, "backend": backend, "title": title, "state": state.rawValue,
            "host": host.host, "canType": host.canType, "canInterrupt": host.canInterrupt,
            "provider": host.provider.rawValue
        ]
        if let cwd { o["cwd"] = cwd }
        if !host.canType { o["typeBlocker"] = host.typeBlocker ?? "Page can't type into this session" }
        if let lastActivityAt { o["lastActivityAt"] = SessionTranscript.isoFormatter.string(from: lastActivityAt) }
        if let interventionId { o["interventionId"] = interventionId }
        if let preview, !preview.isEmpty { o["preview"] = preview }
        return o
    }
}

/// The Mac side of the phone's **Active sessions** view
/// (docs/SESSIONS-PROTOCOL.md): sends the encrypted session list and the
/// transcripts phones are watching, and acts on the phone's encrypted
/// commands through the input gate.
///
/// Only while someone is looking: nothing is built or sent while the
/// Worker reports no phone socket (old Workers never report one, so they
/// never see the feature). Host probes (ps, tmux, lsof) run on their own
/// queue and are cached per session; transcripts are read bounded and
/// cached by size and mtime. Nothing here ever runs on the Coordinator's
/// tick queue: the tick only hands over a value copy of the sessions.
///
/// Logs carry a session id prefix, the op, the outcome and lengths —
/// never titles, paths, transcript text or typed text.
///
/// Threading: all state is confined to `queue`. Public methods may be
/// called from any thread and never block.
final class SessionRemote {
    static let maxSessions = 100
    static let freshness: TimeInterval = 5 * 60
    static let hostTTL: TimeInterval = 30
    static let stepInterval: TimeInterval = 0.5
    /// A session's preview is re-read at most this often.
    static let previewInterval: TimeInterval = 2
    static let liveStatusInterval: TimeInterval = 1
    static let maxTitle = 200
    static let maxCwd = 500
    /// The list plaintext's budget: sealed and base64url-encoded (×4/3 plus
    /// the envelope) it stays under the Worker's 256 KiB frame limit.
    static let maxListPlaintextBytes = 180 * 1024

    let boot: String
    private let backends: SessionRemoteBackends
    private let now: () -> Date
    private let autoTimer: Bool
    private let queue = DispatchQueue(label: "ClaudePowerMode.sessions", qos: .utility)
    private let probeQueue = DispatchQueue(label: "ClaudePowerMode.sessions.probe", qos: .utility)
    private let macNameProvider: () -> String

    // Confined to `queue`.
    private var sink: SessionsUpdateSink?
    private var keys: SessionKeys?
    private var enabled = true
    private var phones = 0
    private var sessions: [AgentSession] = []
    private var pending: [InterventionEvent] = []
    private var statuses: [String: ClaudeSessionStatus] = [:]
    private var statusesAt: Date?
    private var hosts: [String: (info: SessionHostInfo, at: Date)] = [:]
    private var probing = false
    private var previews: [String: (stamp: FileStamp?, checkedAt: Date, entries: [SessionTranscriptEntry])] = [:]
    private var transcripts: [String: (stamp: FileStamp, snapshot: SessionTranscript.Snapshot)] = [:]
    private var watchers = SessionWatchers()
    private var replay = SessionReplayGuard()
    private var seq: Int64 = 0
    private var lastListAt: Date?
    private var lastListBody: Data?
    private var lastTranscriptCheck: [String: Date] = [:]
    private var lastTranscriptBody: [String: Data] = [:]
    private var timer: DispatchSourceTimer?
    private var macName: String?
    private var stopped = false

    struct FileStamp: Equatable {
        let size: UInt64
        let mtime: Date
    }

    /// `autoTimer` false (tests) leaves the periodic work to `step()`.
    init(backends: SessionRemoteBackends, now: @escaping () -> Date = Date.init, autoTimer: Bool = true,
         macName: @escaping () -> String = { Host.current().localizedName ?? "Mac" }) {
        self.backends = backends
        self.now = now
        self.autoTimer = autoTimer
        self.macNameProvider = macName
        var bytes = [UInt8](repeating: 0, count: 8)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<8).map { _ in UInt8.random(in: 0...255) }
        }
        boot = SessionCrypto.base64URLEncode(Data(bytes))
    }

    // MARK: inputs (any thread)

    /// The relay client (or nil when the relay is off) and the pairing's
    /// root key. A new client hasn't reported any phones yet.
    func attach(sink: SessionsUpdateSink?, rootKey: Data?) {
        queue.async {
            self.sink = sink
            self.keys = rootKey.flatMap(SessionKeys.init(root:))
            if sink != nil && self.keys == nil { Logger.shared.log("Sessions: no session key — the live sessions view is off") }
            self.setPhonesLocked(0)
        }
    }

    func setEnabled(_ on: Bool) {
        queue.async {
            guard self.enabled != on else { return }
            self.enabled = on
            Logger.shared.log("Sessions: live sessions view \(on ? "enabled" : "disabled")")
            self.lastListBody = nil   // re-send at once in the new form
        }
    }

    /// `phones.status` from the Worker, via `sink`. Ignored from a client
    /// that has since been replaced (its frames can land late).
    func setPhones(_ n: Int, from sink: SessionsUpdateSink) {
        queue.async {
            guard self.sink === sink else { return }
            self.setPhonesLocked(max(0, n))
        }
    }

    /// `sink`'s socket went up or down. Down means no phone can see us.
    func connectionChanged(_ connected: Bool, from sink: SessionsUpdateSink) {
        guard !connected else { return }
        queue.async {
            guard self.sink === sink else { return }
            self.setPhonesLocked(0)
        }
    }

    /// The merged sessions and open pages after a tick (value copies).
    func update(sessions: [AgentSession], pending: [InterventionEvent]) {
        queue.async {
            self.sessions = sessions
            self.pending = pending
            let ids = Set(sessions.map(\.sessionId))
            self.hosts = self.hosts.filter { ids.contains($0.key) }
            self.previews = self.previews.filter { ids.contains($0.key) }
            self.statuses = self.statuses.filter { ids.contains($0.key) }
            self.lastTranscriptCheck = self.lastTranscriptCheck.filter { ids.contains($0.key) }
            self.lastTranscriptBody = self.lastTranscriptBody.filter { ids.contains($0.key) }
        }
    }

    func handleCommand(_ envelope: SessionEnvelope) {
        queue.async { self.handleCommandLocked(envelope) }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.timer?.cancel()
            self.timer = nil
            self.sink = nil
        }
    }

    /// Runs the periodic work once (tests; production uses the timer).
    func step() {
        queue.sync { self.stepLocked() }
    }

    /// Waits until queued work, including a host probe, has run (tests).
    func waitUntilIdle() {
        queue.sync {}
        probeQueue.sync {}
        queue.sync {}
    }

    // MARK: acceptance (pure)

    /// The spec's order: decrypt (else drop), fresh (else `stale`), not a
    /// replay (else drop), enabled (else `disabled`).
    static func accept(_ envelope: SessionEnvelope, keys: SessionKeys?, enabled: Bool, now: Date,
                       replay: inout SessionReplayGuard) -> SessionCommandAcceptance {
        guard let keys else { return .drop("no session key") }
        guard let plain = SessionCrypto.open(envelope, key: keys.phoneToMac, aad: SessionCrypto.commandAAD) else {
            return .drop("undecryptable")
        }
        guard let cmd = SessionCommand.parse(plain) else { return .drop("malformed") }
        let age = now.timeIntervalSince1970 - cmd.ts / 1000
        guard abs(age) <= freshness else {
            return .reply(clientId: cmd.clientId, .refused(.stale, "That command is too old — check your phone's clock"))
        }
        guard replay.admit(cmd.clientId, now: now) else { return .drop("replay") }
        guard enabled else {
            return .reply(clientId: cmd.clientId, .refused(.disabled, "Live sessions are turned off in Page's settings on your Mac"))
        }
        return .accept(cmd)
    }

    // MARK: list (pure parts)

    /// Needs-you first, then working, then most recent activity.
    static func ordered(_ rows: [RemoteSessionRow]) -> [RemoteSessionRow] {
        func rank(_ s: AgentSessionState) -> Int {
            switch s {
            case .waitingOnUser, .waitingOnApproval: return 0
            case .active: return 1
            default: return 2
            }
        }
        return rows.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element.state), rank(b.element.state))
            if ra != rb { return ra < rb }
            let (ta, tb) = (a.element.lastActivityAt ?? .distantPast, b.element.lastActivityAt ?? .distantPast)
            if ta != tb { return ta > tb }
            return a.offset < b.offset
        }.map(\.element).prefix(maxSessions).map { $0 }
    }

    /// The list state with a fresh Claude status laid over the tick's.
    static func overlay(_ state: AgentSessionState, fresh: ClaudeSessionStatus?) -> AgentSessionState {
        switch fresh {
        case .busy?: return .active
        case .waiting?: return state == .waitingOnUser || state == .waitingOnApproval ? state : .waitingOnApproval
        case .idle?: return state == .active || state == .waitingOnApproval ? .idle : state
        case .unknown?, nil: return state
        }
    }

    /// Codex can only be typed into mid-turn in cmux; elsewhere the phone
    /// says why instead of offering a composer that will be refused.
    static func effectiveHost(_ info: SessionHostInfo, backend: AgentBackendID, state: AgentSessionState) -> SessionHostInfo {
        guard backend == .codex, state == .active, info.canType, info.host != "cmux" else { return info }
        var out = info
        out.canType = false
        out.typeBlocker = SessionInputGate.codexMidTurnMessage
        return out
    }

    static func homeAbbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: periodic work (queue)

    private func setPhonesLocked(_ n: Int) {
        let before = phones
        phones = n
        if n > 0 && before == 0 {
            Logger.shared.log("Sessions: \(n) phone(s) looking — sending the session list")
            lastListAt = nil
            lastListBody = nil
            lastTranscriptCheck = [:]
            lastTranscriptBody = [:]
            startTimer()
            stepLocked()
        } else if n == 0 && before > 0 {
            Logger.shared.log("Sessions: no phone looking — stopped sending")
            timer?.cancel()
            timer = nil
        }
    }

    private func startTimer() {
        guard autoTimer, timer == nil, !stopped else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.stepInterval, repeating: Self.stepInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.stepLocked() }
        t.resume()
        timer = t
    }

    private func stepLocked() {
        guard !stopped, phones > 0, sink != nil, keys != nil else { return }
        let t = now()
        watchers.prune(now: t)
        if enabled {
            refreshStatuses(t)
            probeIfNeeded(t)
        }
        let rows = enabled ? currentRows(t) : []
        let body = Self.listBody(rows, enabled: enabled)
        if SessionsSchedule.listDue(phones: phones, changed: body != lastListBody, lastSentAt: lastListAt, now: t) {
            sendList(rows, body: body, at: t)
        }
        guard enabled else { return }
        for sid in watchers.watched(now: t)
        where SessionsSchedule.transcriptDue(phones: phones, lastCheckedAt: lastTranscriptCheck[sid], now: t) {
            sendTranscript(sid, force: false, at: t)
        }
    }

    private func refreshStatuses(_ t: Date) {
        if let at = statusesAt, t.timeIntervalSince(at) < Self.liveStatusInterval { return }
        statusesAt = t
        statuses = backends.liveStatuses(sessions.filter { $0.backend == .claude })
    }

    private func probeIfNeeded(_ t: Date) {
        guard !probing else { return }
        let due = sessions.filter { s in hosts[s.sessionId].map { t.timeIntervalSince($0.at) >= Self.hostTTL } ?? true }
        guard !due.isEmpty else { return }
        probing = true
        let backends = self.backends
        probeQueue.async { [weak self] in
            let found = backends.probeHosts(due)
            guard let self else { return }
            self.queue.async {
                self.probing = false
                let at = self.now()
                let live = Set(self.sessions.map(\.sessionId))
                for s in due where live.contains(s.sessionId) {
                    self.hosts[s.sessionId] = (found[s.sessionId] ?? .blocked("unknown", "Couldn't find the session's terminal"), at)
                }
            }
        }
    }

    private func state(of s: AgentSession) -> AgentSessionState {
        s.backend == .claude ? Self.overlay(s.state, fresh: statuses[s.sessionId]) : s.state
    }

    private func currentRows(_ t: Date) -> [RemoteSessionRow] {
        var seen = Set<String>()
        var rows: [RemoteSessionRow] = []
        for s in sessions where seen.insert(s.sessionId).inserted {
            let st = state(of: s)
            let host = Self.effectiveHost(hosts[s.sessionId]?.info ?? .checking, backend: s.backend, state: st)
            rows.append(RemoteSessionRow(
                id: s.sessionId,
                backend: s.backend.rawValue,
                title: String((s.title ?? s.cwd.map { ($0 as NSString).lastPathComponent } ?? s.backend.rawValue).prefix(Self.maxTitle)),
                cwd: s.cwd.map { String(Self.homeAbbreviated($0).prefix(Self.maxCwd)) },
                state: st,
                host: host,
                lastActivityAt: s.lastActivityAt,
                interventionId: openPage(for: s)?.id,
                preview: preview(for: s, state: st, at: t)
            ))
        }
        return Self.ordered(rows)
    }

    private func openPage(for s: AgentSession) -> InterventionEvent? {
        pending.filter { $0.sessionId == s.sessionId && $0.backend == s.backend }.max { $0.openedAt < $1.openedAt }
    }

    private func preview(for s: AgentSession, state: AgentSessionState, at t: Date) -> String? {
        if let cached = previews[s.sessionId], t.timeIntervalSince(cached.checkedAt) < Self.previewInterval {
            return SessionTranscript.preview(cached.entries, active: state == .active)
        }
        let file = backends.transcriptFile(for: s)
        let stamp = file.flatMap { Self.fileStamp($0.path) }
        var entries = previews[s.sessionId]?.entries ?? []
        if let file, let stamp, stamp != previews[s.sessionId]?.stamp {
            entries = SessionTranscript.read(path: file.path, format: file.format,
                                             tailBytes: SessionTranscript.previewTailBytes, extendTo: nil)?.entries ?? []
        } else if stamp == nil {
            entries = []
        }
        previews[s.sessionId] = (stamp, t, entries)
        return SessionTranscript.preview(entries, active: state == .active)
    }

    /// Size and mtime, or nil — never for a privacy-protected path (even a
    /// stat there can raise the macOS prompt).
    static func fileStamp(_ path: String) -> FileStamp? {
        guard !path.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(path) else { return nil }
        // A symlink into a protected folder counts as inside it (stat follows it).
        let resolved = (path as NSString).resolvingSymlinksInPath
        guard !resolved.hasPrefix("/dev/"), !PrivacyProtectedPaths.contains(resolved) else { return nil }
        var st = stat()
        guard stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        return FileStamp(size: UInt64(max(0, st.st_size)), mtime: mtime)
    }

    static func listBody(_ rows: [RemoteSessionRow], enabled: Bool) -> Data {
        let obj: [String: Any] = ["sessions": rows.map(\.jsonObject), "disabled": !enabled]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    // MARK: sending (queue)

    private func header(_ kind: String, at t: Date) -> [String: Any] {
        seq += 1
        return ["kind": kind, "boot": boot, "seq": seq, "ts": Int64((t.timeIntervalSince1970 * 1000).rounded())]
    }

    private func seal(_ plaintext: Data) -> Bool {
        guard let sink, let keys, sink.isConnected,
              let envelope = SessionCrypto.seal(plaintext, key: keys.macToPhone, aad: SessionCrypto.updateAAD) else { return false }
        sink.sendSessionsUpdate(envelope)
        return true
    }

    private func sendList(_ rows: [RemoteSessionRow], body: Data, at t: Date) {
        if macName == nil { macName = macNameProvider() }
        var head = header("list", at: t)
        head["macName"] = macName ?? "Mac"
        // Not in the spec: tells a phone that knows it why the list is
        // empty (others ignore unknown fields).
        if !enabled { head["disabled"] = true }
        guard let out = Self.listPlaintext(header: head, rows: rows) else { return }
        if out.kept < rows.count { Logger.shared.log("Sessions: list trimmed to fit (\(out.kept) of \(rows.count) rows)") }
        guard seal(out.data) else { return }
        lastListAt = t
        // The full list: a change in a trimmed-off row still counts.
        lastListBody = body
    }

    /// The `list` plaintext: `header` plus the rows, dropping the last
    /// (least urgent, `rows` is ordered) until it fits in `maxBytes`. A
    /// single row isn't byte-bounded (titles are capped in characters), so
    /// this can end at an empty list — never at no list. `kept` is the
    /// number of rows sent.
    static func listPlaintext(header: [String: Any], rows: [RemoteSessionRow],
                              maxBytes: Int = maxListPlaintextBytes) -> (data: Data, kept: Int)? {
        var objects = rows.map(\.jsonObject)
        while true {
            var obj = header
            obj["sessions"] = objects
            guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
            if data.count <= maxBytes || objects.isEmpty { return (data, objects.count) }
            // Drop a share proportional to the overshoot (at least one row).
            let excess = Double(data.count - maxBytes) / Double(data.count)
            objects.removeLast(max(1, min(objects.count, Int((Double(objects.count) * excess).rounded(.up)))))
        }
    }

    private func sendTranscript(_ sessionId: String, force: Bool, at t: Date) {
        lastTranscriptCheck[sessionId] = t
        guard phones > 0, let s = sessions.first(where: { $0.sessionId == sessionId }),
              let file = backends.transcriptFile(for: s), let stamp = Self.fileStamp(file.path) else { return }
        let snapshot: SessionTranscript.Snapshot
        if let cached = transcripts[file.path], cached.stamp == stamp {
            snapshot = cached.snapshot
        } else {
            guard let fresh = SessionTranscript.read(path: file.path, format: file.format) else { return }
            snapshot = fresh
            transcripts[file.path] = (stamp, fresh)
            // Only watched sessions' transcripts are kept.
            let watchedPaths = Set(watchers.watched(now: t).compactMap { sid in
                sessions.first { $0.sessionId == sid }.flatMap { backends.transcriptFile(for: $0)?.path }
            })
            transcripts = transcripts.filter { watchedPaths.contains($0.key) || $0.key == file.path }
        }
        let body = (try? JSONSerialization.data(withJSONObject: ["e": snapshot.entries.map(\.jsonObject), "t": snapshot.truncated],
                                                options: [.sortedKeys])) ?? Data()
        if !force && body == lastTranscriptBody[sessionId] { return }
        var head = header("transcript", at: t)
        head["sessionId"] = sessionId
        guard let data = SessionTranscript.plaintext(header: head, snapshot: snapshot), seal(data) else { return }
        lastTranscriptBody[sessionId] = body
    }

    private func sendResult(_ clientId: String, _ result: SessionCommandResult) {
        var obj = header("result", at: now())
        obj.merge(result.fields(clientId: clientId)) { $1 }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        _ = seal(data)
    }

    // MARK: commands (queue)

    private func handleCommandLocked(_ envelope: SessionEnvelope) {
        guard !stopped else { return }
        let t = now()
        switch Self.accept(envelope, keys: keys, enabled: enabled, now: t, replay: &replay) {
        case .drop(let why):
            Logger.shared.log("Sessions: command dropped (\(why))")
        case .reply(let clientId, let result):
            Logger.shared.log("Sessions: command refused (\(result.reason?.rawValue ?? result.code.rawValue))")
            sendResult(clientId, result)
        case .accept(let cmd):
            perform(cmd, at: t)
        }
    }

    private func perform(_ cmd: SessionCommand, at t: Date) {
        let sid = cmd.sessionId.map { String($0.prefix(8)) } ?? "-"
        switch cmd.op {
        case "watch":
            guard let viewer = cmd.viewer else { return }
            watchers.set(viewer: viewer, sessionId: cmd.sessionId, now: t)
            if let id = cmd.sessionId { sendTranscript(id, force: true, at: t) }
        case "refresh":
            if phones > 0 {
                let rows = enabled ? currentRows(t) : []
                sendList(rows, body: Self.listBody(rows, enabled: enabled), at: t)
            }
            if let viewer = cmd.viewer, let id = watchers.session(forViewer: viewer, now: t) {
                sendTranscript(id, force: true, at: t)
            }
        case "input":
            let length = cmd.text?.count ?? 0
            guard let id = cmd.sessionId, let s = sessions.first(where: { $0.sessionId == id }) else {
                Logger.shared.log("Sessions: input \(sid) → refused/not_found (\(length) chars)")
                return sendResult(cmd.clientId, .refused(.notFound, "That session isn't running any more"))
            }
            if case .failure(let refusal) = SessionInputGate.validateText(cmd.text ?? "") {
                Logger.shared.log("Sessions: input \(sid) → refused/\(refusal.reason?.rawValue ?? "error") (\(length) chars)")
                return sendResult(cmd.clientId, refusal)
            }
            Logger.shared.log("Sessions: input \(sid) (\(length) chars)")
            let clientId = cmd.clientId
            backends.input(s, clientId: clientId, text: cmd.text ?? "", interventionId: openPage(for: s)?.id) { [weak self] r in
                guard let self else { return }
                self.queue.async {
                    Logger.shared.log("Sessions: input \(sid) → \(r.code.rawValue)\(r.reason.map { "/\($0.rawValue)" } ?? "") (\(length) chars)")
                    self.sendResult(clientId, r)
                }
            }
        case "interrupt":
            guard let id = cmd.sessionId, let s = sessions.first(where: { $0.sessionId == id }) else {
                Logger.shared.log("Sessions: interrupt \(sid) → refused/not_found")
                return sendResult(cmd.clientId, .refused(.notFound, "That session isn't running any more"))
            }
            let st = state(of: s)
            if st != .active || hosts[id]?.info.canInterrupt == false {
                let r: SessionCommandResult = st == .active
                    ? .refused(.interruptUnsupported, "Page can't press Esc where this session runs")
                    : .refused(.interruptUnsupported, SessionInputGate.notIdleMessage)
                Logger.shared.log("Sessions: interrupt \(sid) → refused/interrupt_unsupported")
                return sendResult(cmd.clientId, r)
            }
            Logger.shared.log("Sessions: interrupt \(sid)")
            let clientId = cmd.clientId
            backends.interrupt(s, interventionId: openPage(for: s)?.id) { [weak self] r in
                guard let self else { return }
                self.queue.async {
                    Logger.shared.log("Sessions: interrupt \(sid) → \(r.code.rawValue)\(r.reason.map { "/\($0.rawValue)" } ?? "")")
                    self.sendResult(clientId, r)
                }
            }
        default:
            // Unknown ops are ignored (forward compatibility).
            Logger.shared.log("Sessions: ignoring unknown op")
        }
    }
}

// MARK: - live backends

/// `SessionRemoteBackends` over the real Claude and Codex backends.
final class LiveSessionBackends: SessionRemoteBackends {
    private let claude: ClaudeBackend
    private let codex: CodexBackend

    init(claude: ClaudeBackend, codex: CodexBackend) {
        self.claude = claude
        self.codex = codex
    }

    func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo] {
        let table = ProcessRunner.processTable()
        guard !table.isEmpty else { return [:] }
        let live = Dictionary(grouping: claude.remoteLiveSessions, by: \.sessionId)
        var codexProcesses: [CodexProcess]?
        var out: [String: SessionHostInfo] = [:]
        for s in sessions {
            switch s.backend {
            case .claude:
                out[s.sessionId] = Self.claudeHost(candidates: live[s.sessionId] ?? [], table: table)
            case .codex:
                guard let t = codex.remoteThread(s.sessionId) else {
                    out[s.sessionId] = .blocked("unknown", "Page no longer knows this Codex session")
                    continue
                }
                let provider = ModelProviderClassifier.codex(argv: [], threadModelProvider: t.modelProvider)
                let source = CodexBackend.mapSource(t.source)
                if let fixed = Self.codexHostForSource(source, provider: provider) {
                    out[s.sessionId] = fixed
                    continue
                }
                guard let cwd = t.cwd, !cwd.isEmpty else {
                    out[s.sessionId] = .blocked("unknown", "Codex didn't say where this session runs", provider: provider)
                    continue
                }
                if codexProcesses == nil { codexProcesses = CodexProcessScanner.liveSessions(table: table) }
                let target = CodexInjector.resolveTarget(cwd: CodexProcessScanner.canonicalPath(cwd), rolloutPath: t.path,
                                                         processes: codexProcesses ?? [], cwdFallback: .forSource(source))
                guard case .tty(let tty, let pid) = target else {
                    let why = SessionInputGate.codexTargetProblem(target, project: CodexInjector.projectName(forCwd: cwd))?.detail
                    out[s.sessionId] = .blocked("unknown", why ?? "Couldn't find the Codex session's terminal", provider: provider)
                    continue
                }
                let terminal = CodexInjector.terminal(tty: tty, pid: pid, threadId: t.id, table: table)
                out[s.sessionId] = Self.codexHost(terminal, appHost: CodexInjector.host(ofPid: pid, table: table), provider: provider)
            }
        }
        return out
    }

    /// Pure given the host resolver. One process with a terminal, or the
    /// phone is told why not.
    static func claudeHost(candidates: [ClaudeLiveSession], table: [ProcessRunner.ProcessInfoRow],
                           resolveHost: (ClaudeLiveSession, [ProcessRunner.ProcessInfoRow]) -> InjectionExecutor.TerminalHost
                               = { InjectionExecutor.resolveHost(for: $0, processTable: $1) }) -> SessionHostInfo {
        guard !candidates.isEmpty else { return .blocked("unknown", "Page can't tell which Claude session this is") }
        switch InjectionExecutor.pickSession(candidates, pagePid: nil, pageStateStart: nil) {
        case .failure(let f):
            return .blocked("unknown", f.detail)
        case .success(let s):
            guard s.tty != nil else { return .blocked("unknown", "This session isn't running in a terminal Page can type into", provider: s.provider) }
            return claudeHostInfo(resolveHost(s, table), provider: s.provider)
        }
    }

    static func claudeHostInfo(_ host: InjectionExecutor.TerminalHost, provider: ModelProvider) -> SessionHostInfo {
        switch host {
        case .tmux: return SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: provider)
        case .terminalApp: return SessionHostInfo(host: "Terminal", canType: true, canInterrupt: false, provider: provider)
        case .iTerm: return SessionHostInfo(host: "iTerm", canType: true, canInterrupt: true, provider: provider)
        case .cmux: return SessionHostInfo(host: "cmux", canType: true, canInterrupt: true, provider: provider)
        case .unreachable(let why): return .blocked("cmux", why, provider: provider)
        case .unsupported(let app): return .blocked(wireHost(app: app), "Page can't type into \(app) yet", provider: provider)
        case .unknown: return .blocked("unknown", "Couldn't find the session's terminal", provider: provider)
        }
    }

    /// Desktop / editor / exec threads have no terminal to type into.
    static func codexHostForSource(_ source: AgentSessionSource, provider: ModelProvider) -> SessionHostInfo? {
        switch source {
        case .desktop: return .blocked("desktop", "Page can't type into the Codex app — use the Codex CLI in tmux or cmux", provider: provider)
        case .vscode: return .blocked("VS Code", "Page can't type into Codex in VS Code yet", provider: provider)
        case .exec: return .blocked("unknown", "A background codex exec run — there's nothing to type into", provider: provider)
        case .remote: return .blocked("unknown", "This session runs somewhere else", provider: provider)
        case .terminal, .unknown: return nil
        }
    }

    static func codexHost(_ terminal: CodexInjector.Terminal, appHost: CodexInjector.Host, provider: ModelProvider) -> SessionHostInfo {
        switch terminal {
        case .tmux: return SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: provider)
        case .cmux: return SessionHostInfo(host: "cmux", canType: true, canInterrupt: true, provider: provider)
        case .terminalApp: return .blocked("Terminal", SessionInputGate.codexTerminalAppBlocker, provider: provider)
        case .unavailable(let why):
            let host: String
            switch appHost {
            case .tmux: host = "tmux"
            case .terminalApp: host = "Terminal"
            case .app(let name): host = wireHost(app: name)
            case .unknown: host = "unknown"
            }
            return .blocked(host, why, provider: provider)
        }
    }

    /// The spec's host values; anything else is "unknown" (the blocker
    /// names the app).
    static func wireHost(app: String) -> String {
        let lower = app.lowercased()
        if lower == "cmux" || lower.hasPrefix("cmux ") { return "cmux" }
        switch app {
        case "Terminal": return "Terminal"
        case "iTerm2", "iTerm": return "iTerm"
        case "Ghostty": return "Ghostty"
        case "VS Code", "Code", "Visual Studio Code": return "VS Code"
        default: return "unknown"
        }
    }

    func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus] {
        let wanted = Set(sessions.map(\.sessionId))
        var out: [String: ClaudeSessionStatus] = [:]
        for s in claude.remoteLiveSessions where wanted.contains(s.sessionId) && s.hasSessionFile && out[s.sessionId] == nil {
            if let status = claude.remoteStatus(pid: s.pid) { out[s.sessionId] = status }
        }
        return out
    }

    func transcriptFile(for session: AgentSession) -> SessionTranscriptFile? {
        switch session.backend {
        case .claude:
            return claude.remoteTranscriptURL(sessionId: session.sessionId, cwd: session.cwd)
                .map { SessionTranscriptFile(path: $0.path, format: .claude) }
        case .codex:
            return codex.remoteThread(session.sessionId)?.path
                .flatMap { $0.isEmpty ? nil : SessionTranscriptFile(path: $0, format: .codex) }
        }
    }

    func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?,
               completion: @escaping (SessionCommandResult) -> Void) {
        switch session.backend {
        case .claude:
            claude.remoteInput(sessionId: session.sessionId, clientId: clientId, text: text,
                               interventionId: interventionId, completion: completion)
        case .codex:
            codex.remoteInput(threadId: session.sessionId, text: text, interventionId: interventionId, completion: completion)
        }
    }

    func interrupt(_ session: AgentSession, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
        switch session.backend {
        case .claude:
            claude.remoteInterrupt(sessionId: session.sessionId, interventionId: interventionId, completion: completion)
        case .codex:
            codex.remoteInterrupt(threadId: session.sessionId, interventionId: interventionId, completion: completion)
        }
    }
}
