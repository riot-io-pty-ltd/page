import Foundation
import Combine

/// Thin client over the Cloudflare Worker:
/// - REST: list interventions, post reply, register APNs token
/// - WebSocket: live state updates (intervention.opened / closed / heartbeat)
@MainActor
final class APIClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    static let shared = APIClient()

    @Published private(set) var inbox: [Intervention] = []
    @Published private(set) var history: [Intervention] = []
    @Published private(set) var connected: Bool = false
    @Published private(set) var activeSessions: Int = 0
    @Published private(set) var lastHeartbeatAt: Date?
    @Published var lastError: String?

    private var wsTask: URLSessionWebSocketTask?
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()
    private var reconnectBackoff: TimeInterval = 1
    private var reconnectScheduled = false

    private override init() {
        super.init()
    }

    var relayURL: URL? {
        guard let s = PairingStoreShared.relayURL else { return nil }
        return URL(string: APIClient.normalizedHTTPS(from: s))
    }
    var relayToken: String? { PairingStoreShared.relayToken }

    /// Pairing payload might carry `wss://` or `https://` — REST needs HTTPS.
    private static func normalizedHTTPS(from raw: String) -> String {
        guard var comps = URLComponents(string: raw) else { return raw }
        switch comps.scheme?.lowercased() {
        case "wss": comps.scheme = "https"
        case "ws":  comps.scheme = "http"
        default: break
        }
        if comps.path.hasSuffix("/ws") {
            comps.path = String(comps.path.dropLast(3))
        }
        return comps.url?.absoluteString ?? raw
    }

    /// WebSocket URL derived from the same base.
    private static func wsURL(from raw: String) -> URL? {
        guard var comps = URLComponents(string: raw) else { return nil }
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        case "http":  comps.scheme = "ws"
        default: break
        }
        if !comps.path.hasSuffix("/ws") {
            comps.path = comps.path.hasSuffix("/") ? comps.path + "ws" : comps.path + "/ws"
        }
        return comps.url
    }

    #if DEBUG
    /// Inject mock interventions for development. Bypasses the network entirely.
    func seedDevInbox(_ list: [Intervention]) {
        inbox = list
        connected = true
    }
    #endif

    // MARK: REST

    func refreshInbox() async {
        guard let url = relayURL?.appendingPathComponent("interventions"),
              let token = relayToken else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let list = try JSONDecoder.iso.decode([Intervention].self, from: data)
            inbox = list.sorted { $0.openedAt > $1.openedAt }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshHistory() async {
        guard let url = relayURL?.appendingPathComponent("history"),
              let token = relayToken else { return }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            history = try JSONDecoder.iso.decode([Intervention].self, from: data)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reply(interventionId: String, text: String, action: String?) async {
        guard let base = relayURL,
              let token = relayToken else { return }
        let url = base.appendingPathComponent("reply").appendingPathComponent(interventionId)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "text": text,
            "action": action ?? NSNull()
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await URLSession.shared.data(for: req)
            inbox.removeAll(where: { $0.id == interventionId })
        } catch {
            lastError = error.localizedDescription
        }
    }

    func registerAPNs(deviceToken: String) async {
        guard let url = relayURL?.appendingPathComponent("device/register"),
              let token = relayToken else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "apnsToken": deviceToken,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "0.1"
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: WebSocket lifecycle

    /// Idempotent — safe to call from any `.task` modifier. If there's already
    /// an open or in-flight WS task, this is a no-op.
    func connectWebSocket() {
        if let existing = wsTask, existing.state == .running || existing.state == .suspended {
            return
        }
        guard let raw = PairingStoreShared.relayURL,
              let url = APIClient.wsURL(from: raw),
              let token = relayToken else {
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("page-ios/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: req)
        wsTask = task
        task.resume()
        receive()
        // `connected` is NOT set here — it flips true only when the delegate
        // confirms the handshake (urlSession:webSocketTask:didOpenWithProtocol:).
    }

    private func receive() {
        let task = wsTask
        task?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .failure(let err):
                    print("[APIClient] WS receive error: \(err.localizedDescription)")
                    self.handleClose()
                case .success(let msg):
                    self.handleMessage(msg)
                    self.receive()
                }
            }
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) {
        let data: Data
        switch msg {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = envelope["type"] as? String else { return }
        switch type {
        case "intervention.opened":
            if let payload = envelope["payload"] as? [String: Any],
               let pdata = try? JSONSerialization.data(withJSONObject: payload),
               let ev = try? JSONDecoder.iso.decode(Intervention.self, from: pdata) {
                if !inbox.contains(where: { $0.id == ev.id }) {
                    inbox.insert(ev, at: 0)
                }
            }
        case "intervention.closed":
            if let payload = envelope["payload"] as? [String: Any],
               let id = payload["id"] as? String {
                inbox.removeAll(where: { $0.id == id })
            }
        case "heartbeat":
            if let payload = envelope["payload"] as? [String: Any],
               let activeSessions = payload["activeSessions"] as? Int {
                self.activeSessions = activeSessions
                self.lastHeartbeatAt = Date()
            }
        default:
            break
        }
    }

    private func handleClose() {
        connected = false
        wsTask = nil
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        let delay = reconnectBackoff
        reconnectBackoff = min(reconnectBackoff * 2, 30)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.reconnectScheduled = false
            self.connectWebSocket()
        }
    }

    // MARK: URLSessionWebSocketDelegate

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            print("[APIClient] WS opened")
            self.connected = true
            self.reconnectBackoff = 1
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                                reason: Data?) {
        Task { @MainActor in
            print("[APIClient] WS closed code=\(closeCode.rawValue)")
            self.handleClose()
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("[APIClient] task completed with error: \(error.localizedDescription)")
                self.handleClose()
            }
        }
    }
}

// Bridges so APIClient can read the latest pairing state without retain cycles.
enum PairingStoreShared {
    static var relayURL: String?
    static var relayToken: String?
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
