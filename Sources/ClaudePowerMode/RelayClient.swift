import Foundation

/// Long-lived WebSocket client that talks to the Cloudflare Worker.
/// - Sends `intervention.opened/closed/heartbeat/reply.injected`
/// - Receives `reply` messages from the user's phone
/// - Auto-reconnects with exponential backoff
final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    typealias ReplyHandler = (RelayReply) -> Void

    struct RelayReply: Codable {
        let interventionId: String
        let text: String
        let action: String?       // "approve" | "deny" | "carry_on" | "custom" | nil
        let sessionId: String?    // optional hint
        let cwd: String?
    }

    private let url: URL
    private let token: String
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var backoff: TimeInterval = 1
    private let maxBackoff: TimeInterval = 60
    private var reconnectTimer: Timer?
    private var stopped = false
    private var pendingOutbound: [Data] = []
    private(set) var isConnected: Bool = false

    var onReply: ReplyHandler?
    var onConnectionChange: ((Bool) -> Void)?

    init(url: URL, token: String) {
        self.url = url
        self.token = token
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    /// Derives the WebSocket URL from a relay base URL like
    /// `https://your-worker.workers.dev`. Swaps the scheme to wss/ws
    /// and appends `/ws`.
    static func wsURL(from base: String) -> URL? {
        guard var comps = URLComponents(string: base) else { return nil }
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        case "http":  comps.scheme = "ws"
        case "wss", "ws": break
        default: comps.scheme = "wss"
        }
        var path = comps.path
        if !path.hasSuffix("/ws") {
            if path.hasSuffix("/") { path += "ws" } else { path += "/ws" }
        }
        comps.path = path
        return comps.url
    }

    func start() {
        stopped = false
        connect()
    }

    func stop() {
        stopped = true
        reconnectTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        setConnected(false)
    }

    private func connect() {
        guard !stopped else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("page-mac/1.0", forHTTPHeaderField: "User-Agent")
        let t = session.webSocketTask(with: request)
        t.resume()
        task = t
        receive()
        Logger.shared.log("RelayClient connecting to \(url.absoluteString)")
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                Logger.shared.log("RelayClient receive error: \(err.localizedDescription)")
                self.handleDisconnect()
            case .success(let msg):
                switch msg {
                case .data(let d): self.handleIncoming(d)
                case .string(let s): self.handleIncoming(Data(s.utf8))
                @unknown default: break
                }
                self.receive()
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "reply":
            if let payload = obj["payload"] as? [String: Any],
               let pdata = try? JSONSerialization.data(withJSONObject: payload),
               let reply = try? JSONDecoder().decode(RelayReply.self, from: pdata) {
                onReply?(reply)
            }
        // Expected echoes of our own outbound traffic — the Worker
        // broadcasts these to every connected socket including the
        // originator. Silently ignore; logging them caused ~50% of all
        // log volume on a busy Mac.
        case "ack", "ping", "heartbeat", "intervention.opened", "intervention.closed":
            break
        default:
            Logger.shared.log("RelayClient unknown msg type: \(type)")
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
            "context": event.context,
            "openedAt": ISO8601DateFormatter().string(from: event.openedAt),
            "backend": event.backend.rawValue,
            "source": event.source.rawValue
        ]
        if let subtype = wireSubtype { payload["subtype"] = subtype }
        send(type: "intervention.opened", payload: payload)
    }

    func sendInterventionClosed(id: String, reason: String) {
        send(type: "intervention.closed", payload: ["id": id, "reason": reason])
    }

    func sendHeartbeat(activeSessions: Int, battery: Int) {
        send(type: "heartbeat", payload: [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "activeSessions": activeSessions,
            "battery": battery
        ])
    }

    func sendReplyInjected(interventionId: String, method: String, success: Bool, output: String?) {
        var payload: [String: Any] = [
            "interventionId": interventionId,
            "method": method,
            "success": success
        ]
        if let output { payload["output"] = output }
        send(type: "reply.injected", payload: payload)
    }

    private func send(type: String, payload: [String: Any]) {
        let envelope: [String: Any] = ["type": type, "payload": payload]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        if isConnected, let task {
            task.send(.data(data)) { [weak self] err in
                if let err {
                    Logger.shared.log("RelayClient send error: \(err.localizedDescription)")
                    self?.queueForRetry(data)
                }
            }
        } else {
            queueForRetry(data)
        }
    }

    private func queueForRetry(_ data: Data) {
        // Keep at most 100 messages queued; drop oldest beyond that.
        if pendingOutbound.count > 100 { pendingOutbound.removeFirst() }
        pendingOutbound.append(data)
    }

    private func flushOutbound() {
        guard isConnected, let task else { return }
        let buffer = pendingOutbound
        pendingOutbound.removeAll()
        for data in buffer {
            task.send(.data(data)) { _ in }
        }
    }

    // MARK: connection lifecycle

    private func handleDisconnect() {
        setConnected(false)
        guard !stopped else { return }
        let delay = backoff
        backoff = min(backoff * 2, maxBackoff)
        Logger.shared.log("RelayClient disconnected — reconnecting in \(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    private func setConnected(_ value: Bool) {
        isConnected = value
        onConnectionChange?(value)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        setConnected(true)
        backoff = 1
        Logger.shared.log("RelayClient connected")
        flushOutbound()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Logger.shared.log("RelayClient closed (code=\(closeCode.rawValue))")
        handleDisconnect()
    }
}
