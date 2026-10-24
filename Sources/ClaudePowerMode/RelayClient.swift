import Foundation

/// Frames waiting for the relay while the socket is down. Pure value type so
/// the coalescing rules are unit-testable without a network.
///
/// Why coalesce: after an outage the old client replayed every queued frame
/// in order, so a page that opened *and* resolved while offline still
/// reached the Worker as `intervention.opened` and buzzed the phone for
/// something already handled.
struct OutboundQueue {
    struct Frame: Equatable {
        let type: String
        /// Intervention id for opened/closed/reply.injected, backend for sync.
        let key: String?
        let data: Data
        let enqueuedAt: Date
    }

    private(set) var frames: [Frame] = []
    let capacity: Int
    /// Status frames (`heartbeat`, `sync`) older than this are dropped: they
    /// are regenerated on every connect, and a stale one is misleading.
    /// Intervention and delivery frames are NOT aged out. Coalescing already
    /// removed every queued open whose page closed, so a queued open is a
    /// page that is still waiting — dropping it after a long outage would
    /// leave an approval blocked with the phone never told (`sync` only
    /// closes cards, it never re-opens them). Likewise a dropped close would
    /// strand a `hook-` card forever, and a dropped failure result would
    /// leave the phone unable to retry. The capacity cap bounds them instead.
    let ttl: TimeInterval

    init(capacity: Int = 200, ttl: TimeInterval = 600) {
        self.capacity = max(1, capacity)
        self.ttl = ttl
    }

    var count: Int { frames.count }
    var isEmpty: Bool { frames.isEmpty }

    /// Adds a frame produced while disconnected, applying the coalescing rules:
    /// - `intervention.closed` X removes a still-queued `intervention.opened` X
    ///   (the closed frame itself is kept: harmless if the Worker never saw
    ///   the page, and correct if an "unsent" open actually got through).
    /// - only the newest `intervention.opened` / `closed` per id is kept;
    /// - only the newest `heartbeat`, and the newest `sync` per backend.
    mutating func enqueue(_ frame: Frame) {
        coalesce(for: frame)
        frames.append(frame)
        expire(now: frame.enqueuedAt)
        enforceCapacity()
    }

    /// Puts back a frame whose send failed. It was produced before anything
    /// queued since, so it goes back in timestamp order — unless something
    /// newer already supersedes it (e.g. its page was closed meanwhile).
    mutating func requeueFailed(_ frame: Frame, now: Date) {
        if supersedes(existingFor: frame) { return }
        let index = frames.firstIndex { $0.enqueuedAt > frame.enqueuedAt } ?? frames.endIndex
        frames.insert(frame, at: index)
        expire(now: now)
        enforceCapacity()
    }

    /// Returns everything still worth sending, oldest first, and empties the queue.
    mutating func drain(now: Date) -> [Frame] {
        expire(now: now)
        let out = frames
        frames.removeAll()
        return out
    }

    mutating func removeAll() { frames.removeAll() }

    // MARK: rules

    private mutating func coalesce(for frame: Frame) {
        switch frame.type {
        case "intervention.opened":
            frames.removeAll { $0.type == "intervention.opened" && $0.key == frame.key }
        case "intervention.closed":
            frames.removeAll {
                ($0.type == "intervention.opened" || $0.type == "intervention.closed") && $0.key == frame.key
            }
        case "heartbeat":
            frames.removeAll { $0.type == "heartbeat" }
        case "sync":
            frames.removeAll { $0.type == "sync" && $0.key == frame.key }
        default:
            break
        }
    }

    /// True when the queue already holds something that makes a failed
    /// `frame` redundant or wrong to resend.
    private func supersedes(existingFor frame: Frame) -> Bool {
        switch frame.type {
        case "intervention.opened":
            return frames.contains {
                ($0.type == "intervention.opened" || $0.type == "intervention.closed") && $0.key == frame.key
            }
        case "intervention.closed":
            return frames.contains { $0.type == "intervention.closed" && $0.key == frame.key }
        case "heartbeat":
            return frames.contains { $0.type == "heartbeat" }
        case "sync":
            return frames.contains { $0.type == "sync" && $0.key == frame.key }
        default:
            return false
        }
    }

    private mutating func expire(now: Date) {
        frames.removeAll {
            ($0.type == "heartbeat" || $0.type == "sync") && now.timeIntervalSince($0.enqueuedAt) > ttl
        }
    }

    /// Evicts the least valuable frames first: status frames (regenerated
    /// on connect), then close frames (the post-connect `sync` also clears
    /// stale cards), then the oldest opens, and delivery results last.
    private mutating func enforceCapacity() {
        let order: [(Frame) -> Bool] = [
            { $0.type == "heartbeat" || $0.type == "sync" },
            { $0.type == "intervention.closed" },
            { $0.type == "intervention.opened" },
            { _ in true }
        ]
        while frames.count > capacity {
            for matches in order {
                if let i = frames.firstIndex(where: matches) {
                    frames.remove(at: i)
                    break
                }
            }
        }
    }
}

/// Long-lived WebSocket client that talks to the Cloudflare Worker. There is
/// exactly one per app, owned by the Coordinator and shared by every backend
/// through `RelaySink`.
/// - Sends `intervention.opened/closed`, `heartbeat`, `sync`, `reply.injected`
/// - Receives `reply` frames from the user's phone
/// - Reconnects with jittered exponential backoff; detects dead sockets
///   with a ping every 25 s
///
/// Threading: every piece of mutable state is confined to `queue`, and the
/// URLSession delegate queue is backed by that same queue, so delegate
/// callbacks never race the send path. Public methods may be called from
/// any thread and never block. Callbacks (`onReply`, `onConnect`,
/// `onConnectionChange`) run on `queue`; set them before `start()` and
/// don't block in them.
///
/// Lifecycle: `stop()` invalidates the URLSession (breaking its strong
/// reference to us), so a stopped client is finished — build a new one to
/// reconnect with a different URL or token.
final class RelayClient: NSObject, RelaySink, URLSessionWebSocketDelegate {
    typealias ReplyHandler = (RelayReply) -> Void

    static let pingInterval: TimeInterval = 25
    static let pongTimeout: TimeInterval = 10
    static let connectTimeout: TimeInterval = 20
    static let backoffBase: TimeInterval = 1
    static let backoffCap: TimeInterval = 60
    /// How long `retire` waits for the frame to go out before giving up.
    static let retireTimeout: TimeInterval = 2

    private let url: URL
    private let token: String
    private let queue = DispatchQueue(label: "ClaudePowerMode.relay", qos: .utility)
    private var session: URLSession!

    // Confined to `queue`.
    private var task: URLSessionWebSocketTask?
    private var connected = false
    private var started = false
    private var stopped = false
    private var attempt = 0
    private var reconnectTimer: DispatchSourceTimer?
    private var connectTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var pongTimer: DispatchSourceTimer?
    private var outbound = OutboundQueue()
    private var loggedUnknownTypes: Set<String> = []
    /// The Worker refused the upgrade with 410: this token was retired
    /// (regenerated on this or another Mac). Reconnects back off to the cap.
    private var tokenRetired = false

    /// Readable from any thread (including from inside our own callbacks,
    /// where `queue.sync` would deadlock).
    private let mirrorLock = NSLock()
    private var connectedMirror = false
    var isConnected: Bool {
        mirrorLock.lock(); defer { mirrorLock.unlock() }
        return connectedMirror
    }

    var onReply: ReplyHandler?
    /// Fired after every successful (re)connect, after queued frames were
    /// flushed. The Coordinator sends a heartbeat and `sync` frames here.
    var onConnect: (() -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private static let isoFormatter = ISO8601DateFormatter()

    /// Must contain "page-mac": the Worker tags the socket as the Mac's by
    /// User-Agent, which decides where replies are routed.
    static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "page-mac/\(version) (macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion))"
    }()

    /// `configuration` is for tests (a stub URLProtocol); production uses
    /// the default.
    init(url: URL, token: String, configuration: URLSessionConfiguration = .default) {
        self.url = url
        self.token = token
        super.init()
        let config = configuration
        // Generous: the 25 s ping keeps traffic flowing well inside it.
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = false
        let delegateQueue = OperationQueue()
        delegateQueue.underlyingQueue = queue
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "ClaudePowerMode.relay.delegate"
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }

    /// Derives the WebSocket URL from a relay base URL like
    /// `https://your-worker.workers.dev`. Returns nil for anything
    /// `Config.validatedRelayURL` rejects (including the placeholder).
    static func wsURL(from base: String) -> URL? {
        guard let https = try? Config.validatedRelayURL(base).get() else { return nil }
        return wsURL(fromBase: https)
    }

    /// `https://host/path` → `wss://host/path/ws` (http → ws for local dev).
    static func wsURL(fromBase base: URL) -> URL? {
        guard var comps = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = comps.scheme?.lowercased() == "http" ? "ws" : "wss"
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path + "/ws"
        return comps.url
    }

    /// Jittered exponential backoff ("equal jitter": a random point in the
    /// upper half of the exponential step). `random` is in 0...1 —
    /// injected so tests are deterministic. The jitter keeps a fleet of
    /// Macs from reconnecting in lockstep after a Worker deploy.
    static func backoffDelay(attempt: Int, random: Double,
                             base: TimeInterval = backoffBase, cap: TimeInterval = backoffCap) -> TimeInterval {
        let step = min(cap, base * pow(2, Double(min(max(attempt, 0), 20))))
        let r = min(1, max(0, random))
        return step * (0.5 + 0.5 * r)
    }

    func start() {
        queue.async {
            guard !self.started, !self.stopped else { return }
            self.started = true
            self.connect()
        }
    }

    /// Drops the current socket (if any) and reconnects immediately,
    /// keeping queued frames. For moments when the socket is known to be
    /// stale before a ping could notice — e.g. right after the Mac wakes.
    func reconnectNow() {
        queue.async {
            guard self.started, !self.stopped else { return }
            self.attempt = 0
            self.reconnectTimer?.cancel()
            self.reconnectTimer = nil
            if let t = self.task {
                self.taskEnded(t, reason: "reconnect requested", reconnect: false)
            }
            self.connect()
        }
    }

    // MARK: token retirement

    /// The Worker HTTP endpoint for `path` next to the socket URL `ws`:
    /// `wss://host/ws` → `https://host/intervention` (ws → http for local
    /// dev). The same mapping as the hook's `normalise_relay_url`.
    static func httpURL(fromWS ws: URL, path: String) -> URL? {
        guard var comps = URLComponents(url: ws, resolvingAgainstBaseURL: false) else { return nil }
        switch comps.scheme?.lowercased() {
        case "wss", "https": comps.scheme = "https"
        case "ws", "http": comps.scheme = "http"
        default: return nil
        }
        var p = comps.path
        while p.hasSuffix("/") { p.removeLast() }
        if p.hasSuffix("/ws") { p.removeLast(3) }
        comps.path = p + (path.hasPrefix("/") ? path : "/" + path)
        comps.query = nil
        comps.fragment = nil
        return comps.url
    }

    /// `{"type":"relay.retire","payload":{"reason":…}}`
    static func retireEnvelope(reason: String) -> Data {
        let envelope: [String: Any] = ["type": "relay.retire", "payload": ["reason": reason]]
        return (try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])) ?? Data()
    }

    /// The POST /intervention fallback used when the socket isn't up.
    static func retireRequest(wsURL: URL, token: String, reason: String, timeout: TimeInterval) -> URLRequest? {
        guard let http = httpURL(fromWS: wsURL, path: "/intervention") else { return nil }
        var request = URLRequest(url: http)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.5, timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = retireEnvelope(reason: reason)
        return request
    }

    /// Whether a POST of `relay.retire` took effect: 2xx, or 410 (this
    /// token is already retired). Anything else (an older Worker answers
    /// 400 for the unknown frame type) did not.
    static func retireAccepted(status: Int) -> Bool {
        (200..<300).contains(status) || status == 410
    }

    /// One-shot `POST /intervention {type: relay.retire}` for a token no
    /// client holds any more (PendingRetirements' retry path). `completion`
    /// gets true only for 2xx / 410 — a confirmed retirement.
    static func postRetire(wsURL: URL, token: String, reason: String,
                           timeout: TimeInterval = 15, completion: @escaping (Bool) -> Void) {
        guard let request = retireRequest(wsURL: wsURL, token: token, reason: reason, timeout: timeout) else {
            completion(false)
            return
        }
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion(retireAccepted(status: (response as? HTTPURLResponse)?.statusCode ?? 0))
        }.resume()
    }

    /// Tells the Worker this client's token is being replaced, so it stops
    /// accepting it and tells phones still paired with it to re-pair. Sent
    /// on the open socket; if there is none (or the send fails), as a POST
    /// /intervention with this token. Never queued: a stopped client drops
    /// its queue, and the frame must not wait for a reconnect.
    ///
    /// `completion` runs exactly once, on the client's queue, with true
    /// when the frame was sent (socket) or accepted (HTTP) — or false after
    /// `timeout`. Doesn't stop the client; the caller does that next.
    func retire(reason: String, timeout: TimeInterval = RelayClient.retireTimeout,
                completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { completion(false); return }
            let once = RetireOnce(completion)
            let timer = self.makeTimer(after: timeout) {
                if once.fire(false) { Logger.shared.log("RelayClient: relay.retire not confirmed within \(timeout)s") }
            }
            once.timer = timer
            let viaHTTP: () -> Void = { [weak self] in
                guard let self, !once.done else { return }
                guard let request = Self.retireRequest(wsURL: self.url, token: self.token, reason: reason, timeout: timeout) else {
                    once.fire(false)
                    return
                }
                self.session.dataTask(with: request) { [weak self] _, response, error in
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self?.queue.async {
                        let ok = Self.retireAccepted(status: status)
                        if once.fire(ok) {
                            Logger.shared.log("RelayClient: relay.retire over HTTP → \(status == 0 ? (error?.localizedDescription ?? "no response") : "HTTP \(status)")")
                        }
                    }
                }.resume()
            }
            if self.connected, let t = self.task {
                t.send(.data(Self.retireEnvelope(reason: reason))) { [weak self] err in
                    self?.queue.async {
                        if err == nil {
                            if once.fire(true) { Logger.shared.log("RelayClient: relay.retire sent on the socket") }
                        } else {
                            viaHTTP()
                        }
                    }
                }
            } else {
                viaHTTP()
            }
        }
    }

    func stop() {
        setMirror(false)
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.cancelTimers()
            self.reconnectTimer?.cancel()
            self.reconnectTimer = nil
            let t = self.task
            self.task = nil
            t?.cancel(with: .goingAway, reason: nil)
            self.outbound.removeAll()
            self.setMirror(false)
            if self.connected {
                self.connected = false
                self.onConnectionChange?(false)
            }
            // Releases the session's strong reference to us. Callbacks still
            // in flight see `stopped` / a nil task and do nothing.
            self.session.invalidateAndCancel()
            Logger.shared.log("RelayClient stopped")
        }
    }

    // MARK: connection lifecycle (on `queue`)

    private func connect() {
        guard !stopped, task == nil else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let t = session.webSocketTask(with: request)
        task = t
        t.resume()
        receive(on: t)
        connectTimer = makeTimer(after: Self.connectTimeout) { [weak self] in
            guard let self, self.task === t, !self.connected else { return }
            self.taskEnded(t, reason: "connect timed out")
        }
        Logger.shared.log("RelayClient connecting to \(url.absoluteString)")
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === t, !self.stopped else { return }
                switch result {
                case .failure(let err):
                    self.taskEnded(t, reason: "receive failed: \(err.localizedDescription)")
                case .success(let msg):
                    switch msg {
                    case .data(let d): self.handleIncoming(d)
                    case .string(let s): self.handleIncoming(Data(s.utf8))
                    @unknown default: break
                    }
                    self.receive(on: t)
                }
            }
        }
    }

    private func didOpen(_ t: URLSessionWebSocketTask) {
        guard task === t, !stopped, !connected else { return }
        connectTimer?.cancel()
        connectTimer = nil
        connected = true
        setMirror(true)
        attempt = 0
        Logger.shared.log("RelayClient connected")
        startPinging(t)
        for frame in outbound.drain(now: Date()) {
            transmit(frame, on: t)
        }
        onConnectionChange?(true)
        onConnect?()
    }

    /// The single reconnect path. Receive failure, close, completion with
    /// error, connect timeout, ping failure and pong timeout all land here;
    /// only the first call per task does anything.
    private func taskEnded(_ t: URLSessionWebSocketTask, reason: String, reconnect: Bool = true) {
        guard task === t else { return }
        task = nil
        cancelTimers()
        t.cancel(with: .goingAway, reason: nil)
        let wasConnected = connected
        connected = false
        setMirror(false)
        if wasConnected { onConnectionChange?(false) }
        guard !stopped else { return }
        Logger.shared.log("RelayClient disconnected (\(reason))")
        if reconnect { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        guard !stopped, reconnectTimer == nil else { return }
        // A retired token stays retired; don't hammer the Worker with it.
        if tokenRetired { attempt = max(attempt, 20) }
        let delay = Self.backoffDelay(attempt: attempt, random: Double.random(in: 0...1))
        attempt += 1
        Logger.shared.log(String(format: "RelayClient reconnecting in %.1fs", delay))
        reconnectTimer = makeTimer(after: delay) { [weak self] in
            guard let self else { return }
            self.reconnectTimer = nil
            self.connect()
        }
    }

    private func startPinging(_ t: URLSessionWebSocketTask) {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.ping(t) }
        timer.resume()
        pingTimer = timer
    }

    private func ping(_ t: URLSessionWebSocketTask) {
        guard task === t, connected, pongTimer == nil else { return }
        pongTimer = makeTimer(after: Self.pongTimeout) { [weak self] in
            guard let self, self.task === t else { return }
            self.taskEnded(t, reason: "no pong within \(Int(Self.pongTimeout))s")
        }
        t.sendPing { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard self.task === t else { return }
                self.pongTimer?.cancel()
                self.pongTimer = nil
                if let error {
                    self.taskEnded(t, reason: "ping failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func cancelTimers() {
        for timer in [connectTimer, pingTimer, pongTimer] { timer?.cancel() }
        connectTimer = nil
        pingTimer = nil
        pongTimer = nil
    }

    private func makeTimer(after delay: TimeInterval, _ handler: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay, leeway: .milliseconds(250))
        timer.setEventHandler(handler: handler)
        timer.resume()
        return timer
    }

    private func setMirror(_ value: Bool) {
        mirrorLock.lock()
        connectedMirror = value
        mirrorLock.unlock()
    }

    // MARK: inbound (on `queue`)

    private func handleIncoming(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            Logger.shared.log("RelayClient: ignoring unparseable frame (\(data.count) bytes)")
            return
        }
        switch type {
        case "reply":
            guard var payload = obj["payload"] as? [String: Any] else {
                Logger.shared.log("RelayClient: reply frame without payload")
                return
            }
            // An action-only reply may arrive with text null/missing; the
            // reply is still valid and must not be dropped.
            if !(payload["text"] is String) { payload["text"] = "" }
            guard let pdata = try? JSONSerialization.data(withJSONObject: payload),
                  let reply = try? JSONDecoder().decode(RelayReply.self, from: pdata) else {
                Logger.shared.log("RelayClient: couldn't decode reply payload (keys: \(payload.keys.sorted().joined(separator: ",")))")
                return
            }
            onReply?(reply)
        // Expected traffic we don't act on: echoes of our own frames (the
        // Worker broadcasts to every socket, including the sender), the v2
        // delivery results and Mac-presence frames meant for phones, and
        // keepalives. Logging these used to be ~50% of all log volume.
        case "reply.result", "mac.status", "ack", "ping", "pong", "heartbeat", "sync", "relay.retired":
            break
        default:
            if type.hasPrefix("intervention.") { break }
            if loggedUnknownTypes.insert(type).inserted {
                Logger.shared.log("RelayClient: ignoring unknown frame type \(type)")
            }
        }
    }

    // MARK: outbound

    func sendInterventionOpened(_ event: InterventionEvent) {
        // Wire-level kind/subtype mapping. iOS canonicalises `permission` →
        // `approval`, but loses the plan-mode distinction unless we send it
        // as a subtype. Translate here so callers don't need to know.
        let wireKind: String
        var wireSubtype: String? = event.subtype
        switch event.kind {
        case .plan:
            wireKind = "permission"
            if wireSubtype == nil { wireSubtype = "plan" }
        default:
            wireKind = event.kind.rawValue
        }
        var payload: [String: Any] = [
            "id": event.id,
            "sessionId": event.sessionId,
            "cwd": event.cwd,
            "projectName": event.projectName,
            "kind": wireKind,
            "context": Self.wireContext(event.context),
            "openedAt": Self.isoFormatter.string(from: event.openedAt),
            "backend": event.backend.rawValue,
            "source": event.source.rawValue
        ]
        if let subtype = wireSubtype { payload["subtype"] = subtype }
        send(type: "intervention.opened", key: event.id, payload: payload)
    }

    /// The context as sent: secrets redacted (every backend's text passes
    /// through here, whatever it did itself; redacting twice is harmless),
    /// before the cut, so a clip can't leave a secret fragment too short to
    /// recognise. The Worker truncates to 4000 too; trimming here keeps
    /// frames small.
    static func wireContext(_ context: String) -> String {
        String(ContextRedactor.redactedPrefix(context, 4000).prefix(4000))
    }

    func sendInterventionClosed(id: String, reason: String) {
        send(type: "intervention.closed", key: id, payload: ["id": id, "reason": reason])
    }

    /// `battery` is the real percentage, or -1 when unknown / no battery.
    /// `onAC` is optional only so pre-v2 call sites keep compiling.
    func sendHeartbeat(activeSessions: Int, battery: Int, onAC: Bool? = nil) {
        var payload: [String: Any] = [
            "ts": Self.isoFormatter.string(from: Date()),
            "activeSessions": activeSessions,
            "battery": battery
        ]
        if let onAC { payload["onAC"] = onAC }
        send(type: "heartbeat", key: nil, payload: payload)
    }

    /// Tells the Worker which of this backend's interventions are still
    /// open, so it can retire cards for pages that ended while the Mac was
    /// away (v2; older Workers log and ignore it).
    func sendSync(backend: AgentBackendID, openIds: [String]) {
        send(type: "sync", key: backend.rawValue, payload: [
            "backend": backend.rawValue,
            "openIds": openIds
        ])
    }

    /// `detail` is shown on the phone (short, human, no secrets); empty is
    /// omitted. `output` is for the Worker log only and is capped.
    func sendReplyInjected(interventionId: String, method: String, success: Bool,
                           detail: String = "", output: String?) {
        var payload: [String: Any] = [
            "interventionId": interventionId,
            "method": method,
            "success": success
        ]
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDetail.isEmpty { payload["detail"] = String(trimmedDetail.prefix(200)) }
        if let output { payload["output"] = String(output.prefix(2000)) }
        send(type: "reply.injected", key: interventionId, payload: payload)
    }

    private func send(type: String, key: String?, payload: [String: Any]) {
        let envelope: [String: Any] = ["type": type, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else {
            Logger.shared.log("RelayClient: couldn't encode \(type) frame")
            return
        }
        let frame = OutboundQueue.Frame(type: type, key: key, data: data, enqueuedAt: Date())
        queue.async {
            guard !self.stopped else { return }
            if self.connected, let t = self.task {
                self.transmit(frame, on: t)
            } else {
                self.outbound.enqueue(frame)
            }
        }
    }

    /// On `queue`.
    private func transmit(_ frame: OutboundQueue.Frame, on t: URLSessionWebSocketTask) {
        t.send(.data(frame.data)) { [weak self] err in
            guard let self, let err else { return }
            self.queue.async {
                guard !self.stopped else { return }
                Logger.shared.log("RelayClient send of \(frame.type) failed: \(err.localizedDescription) — will retry after reconnect")
                self.outbound.requeueFailed(frame, now: Date())
                self.taskEnded(t, reason: "send failed")
            }
        }
    }

    // MARK: URLSessionWebSocketDelegate (delivered on `queue`)

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        didOpen(webSocketTask)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        taskEnded(webSocketTask, reason: "closed by server (code \(closeCode.rawValue))")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ws = task as? URLSessionWebSocketTask else { return }
        var reason = error?.localizedDescription ?? "completed"
        if let http = task.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode), http.statusCode != 101 {
            reason = "HTTP \(http.statusCode) — \(reason)"
            if http.statusCode == 410 && !tokenRetired {
                tokenRetired = true
                Logger.shared.log("RelayClient: the relay says this pairing token was retired (regenerated on a Mac) — regenerate the token here and re-pair the phone")
            }
        }
        taskEnded(ws, reason: reason)
    }
}

/// Completes a `RelayClient.retire` exactly once (send, HTTP answer or
/// timeout, whichever comes first). Used only on the client's queue.
private final class RetireOnce {
    private let completion: (Bool) -> Void
    private(set) var done = false
    var timer: DispatchSourceTimer?

    init(_ completion: @escaping (Bool) -> Void) { self.completion = completion }

    /// Returns whether this call was the one that completed.
    @discardableResult
    func fire(_ ok: Bool) -> Bool {
        guard !done else { return false }
        done = true
        timer?.cancel()
        timer = nil
        completion(ok)
        return true
    }
}
