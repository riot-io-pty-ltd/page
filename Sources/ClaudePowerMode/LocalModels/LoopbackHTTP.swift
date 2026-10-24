import Foundation

/// What one `/slots` probe says about a llama.cpp-style server.
enum SlotsState: String, Equatable {
    /// Some slot `is_processing`.
    case busy
    /// Every slot idle (or no slots).
    case idle
    /// The server answered but won't say (404/501/401/403, unparseable
    /// body). For this poll only — retried next poll, never permanent.
    case unavailable
    /// No usable answer (timeout, refused, 5xx, redirect). Must never read
    /// as idle: the caller keeps its last observation until it goes stale.
    case noObservation
}

/// Pure decoding of llama.cpp `GET /slots`. Unverified (from llama.cpp's
/// server README, no server installed here): the endpoint returns an array
/// of slot objects each with a boolean `is_processing`, and answers 503
/// while a model is loading.
///
/// Privacy: slot objects can carry prompt text. Only `is_processing` is
/// decoded; nothing else is read into a value, stored or logged.
enum SlotsDecoder {
    private struct Slot: Decodable {
        let isProcessing: Bool
        enum CodingKeys: String, CodingKey { case isProcessing = "is_processing" }
    }

    /// true if any slot is processing, false if none (or no slots), nil
    /// when the body isn't an array of slots with `is_processing`.
    static func anyProcessing(_ data: Data) -> Bool? {
        guard let slots = try? JSONDecoder().decode([Slot].self, from: data) else { return nil }
        return slots.contains { $0.isProcessing }
    }

    /// Pure HTTP outcome mapping. `status` nil = timeout / connection error.
    static func state(status: Int?, body: Data?) -> SlotsState {
        guard let status else { return .noObservation }
        switch status {
        case 200:
            guard let body, let busy = anyProcessing(body) else { return .unavailable }
            return busy ? .busy : .idle
        case 401, 403, 404, 501:
            return .unavailable
        default:
            // 503 while a model loads, 5xx, a refused redirect: not an answer.
            return .noObservation
        }
    }
}

/// A deliberately narrow HTTP GET for loopback model servers.
///
/// Only `http://127.0.0.1:<port>` (an IP literal: no DNS, no proxy, no
/// `localhost` resolving elsewhere), ephemeral session (no cookies, no
/// cache), proxies disabled, redirects refused, 3 s timeout, bodies over
/// 1 MB dropped. One session per instance with its own delegate queue, so
/// callbacks never need the caller's queue; call `invalidate()` when done
/// (the session retains its delegate).
final class LoopbackHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let maxBodyBytes = 1 << 20

    private let timeout: TimeInterval
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Every probe goes to 127.0.0.1: a low per-host limit would queue them
        // past the poll budget instead of running them concurrently.
        config.httpMaximumConnectionsPerHost = 16
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ClaudePowerMode.loopbackHTTP"
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    init(timeout: TimeInterval = 3) {
        self.timeout = timeout
        super.init()
    }

    /// Pure: plain http to the 127.0.0.1 literal with an explicit port.
    static func isAllowed(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && url.host == "127.0.0.1" && url.port != nil
            && url.user == nil && url.password == nil
    }

    static func url(port: Int, path: String) -> URL? {
        guard (1...65535).contains(port), path.hasPrefix("/") else { return nil }
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    /// `completion(status, body)` on the session's queue; `(nil, nil)` for a
    /// refused URL, timeout or connection error.
    func get(_ url: URL, completion: @escaping (Int?, Data?) -> Void) {
        guard Self.isAllowed(url) else { completion(nil, nil); return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil, let http = response as? HTTPURLResponse else { completion(nil, nil); return }
            if let data, data.count > Self.maxBodyBytes { completion(http.statusCode, nil); return }
            completion(http.statusCode, data)
        }
        task.resume()
    }

    func slots(port: Int, completion: @escaping (SlotsState) -> Void) {
        guard let url = Self.url(port: port, path: "/slots") else { completion(.noObservation); return }
        get(url) { status, body in completion(SlotsDecoder.state(status: status, body: body)) }
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
