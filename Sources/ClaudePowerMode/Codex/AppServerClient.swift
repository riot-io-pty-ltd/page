import Foundation

/// Owns a `codex app-server` child process and exposes a small async-y API
/// over its newline-delimited JSON protocol.
///
/// Design notes:
///   - Stdio transport only. WebSocket is documented as "experimental and
///     unsupported" in the Codex docs.
///   - One serial queue (`stateQueue`) protects the pending-call map and
///     the next-id counter. Reads happen on a `readerThread`; writes can
///     come from any thread but are funnelled through `writeQueue`.
///   - Permissive decoding: results are decoded as the caller's expected
///     Codable type with `keyDecodingStrategy = .useDefaultKeys`. Unknown
///     fields are ignored. Decode failures surface as `Error` to the
///     caller, not as crashes.
///   - Server-overload errors (code -32001) trigger automatic retry with
///     exponential backoff + jitter (up to 3 attempts).
final class AppServerClient: @unchecked Sendable {

    typealias NotificationHandler = (_ method: String, _ params: AppServerProtocol.JSON) -> Void

    enum ClientError: Error, CustomStringConvertible {
        case notRunning
        case spawnFailed(String)
        case timeout(method: String)
        case rpcFailed(AppServerProtocol.RPCError)
        case decodeFailed(method: String, underlying: Error)

        var description: String {
            switch self {
            case .notRunning: return "app-server client is not running"
            case .spawnFailed(let s): return "failed to spawn codex app-server: \(s)"
            case .timeout(let m): return "timed out waiting for \(m) reply"
            case .rpcFailed(let e): return "rpc \(e.code): \(e.message ?? "(no message)")"
            case .decodeFailed(let m, let u): return "decode failed for \(m): \(u)"
            }
        }
    }

    /// Fired for any message that has no `id` (i.e., a notification from
    /// the server). Delivered on `notificationQueue` to keep the reader
    /// thread responsive.
    var onNotification: NotificationHandler?

    /// Fired once when the child process exits unexpectedly.
    var onUnexpectedExit: (() -> Void)?

    private let codexPath: String
    private let notificationQueue = DispatchQueue(label: "ClaudePowerMode.codex.notifications")
    private let stateQueue = DispatchQueue(label: "ClaudePowerMode.codex.state")
    private let writeQueue = DispatchQueue(label: "ClaudePowerMode.codex.write")

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var readBuffer = Data()
    private var nextID: Int64 = 0
    private var pending: [Int64: (Result<Data, Error>) -> Void] = [:]
    private var initialized = false
    private var shuttingDown = false

    init(codexPath: String = "/usr/local/bin/codex") {
        self.codexPath = codexPath
    }

    // MARK: Lifecycle

    /// Spawn `codex app-server`, do the `initialize` + `initialized`
    /// handshake, and return the server's initialize result.
    func start(clientName: String = "ClaudePowerMode",
               clientVersion: String = "0.1") async throws -> AppServerProtocol.InitializeResult {
        guard FileManager.default.isExecutableFile(atPath: codexPath) else {
            throw ClientError.spawnFailed("codex not found or not executable at \(codexPath)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: codexPath)
        p.arguments = ["app-server"]

        // The `codex` CLI is a Node script (`#!/usr/bin/env node`). When
        // we're launched by a LaunchAgent, the inherited PATH is the
        // sparse `/usr/bin:/bin:/usr/sbin:/sbin` and `node` won't resolve.
        // Inject a PATH that includes the common Node install locations
        // (Homebrew on both Intel and ARM, the system fallback, NVM/nvm).
        var env = ProcessInfo.processInfo.environment
        let nodePathDirs = [
            "/opt/homebrew/bin",          // Apple-silicon Homebrew
            "/usr/local/bin",             // Intel Homebrew + manual installs
            "/usr/bin", "/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/current/bin"
        ]
        let existingPath = env["PATH"] ?? ""
        let merged = (nodePathDirs + existingPath.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { acc, dir in
                if !acc.contains(dir) { acc.append(dir) }
            }
            .joined(separator: ":")
        env["PATH"] = merged
        p.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe

        p.terminationHandler = { [weak self] proc in
            self?.handleProcessExit(status: proc.terminationStatus)
        }

        do {
            try p.run()
        } catch {
            throw ClientError.spawnFailed(error.localizedDescription)
        }

        self.process = p
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderr = stderrPipe.fileHandleForReading

        // Reader thread — synchronous reads, posts decoded lines back via
        // the state queue.
        Thread.detachNewThread { [weak self] in
            self?.readerLoop()
        }
        Thread.detachNewThread { [weak self] in
            self?.stderrLoop()
        }

        let initParams = AppServerProtocol.InitializeParams(
            clientInfo: .init(name: clientName, title: clientName, version: clientVersion),
            capabilities: .init(experimentalApi: true)
        )
        let initResult: AppServerProtocol.InitializeResult = try await call(
            method: "initialize",
            params: initParams
        )
        try notify(method: "initialized", params: EmptyParams())
        stateQueue.sync { self.initialized = true }
        Logger.shared.log("Codex app-server initialized: userAgent=\(initResult.userAgent ?? "?") codexHome=\(initResult.codexHome ?? "?")")
        return initResult
    }

    func shutdown() {
        stateQueue.sync { self.shuttingDown = true }
        try? stdin?.close()
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
        stderr = nil
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: Calls

    /// Send a JSON-RPC-ish request and await the typed result.
    /// Retries automatically on `-32001 server overloaded` (up to 3 attempts).
    func call<P: Encodable, R: Decodable>(
        method: String,
        params: P,
        timeout: TimeInterval = 10,
        maxAttempts: Int = 3
    ) async throws -> R {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let data = try await sendAndAwait(method: method, params: params, timeout: timeout)
                do {
                    return try jsonDecoder.decode(R.self, from: data)
                } catch {
                    throw ClientError.decodeFailed(method: method, underlying: error)
                }
            } catch ClientError.rpcFailed(let e)
                where e.code == AppServerProtocol.errorCodeServerOverloaded && attempt < maxAttempts {
                let delay = backoffDelay(attempt: attempt)
                Logger.shared.log("Codex \(method) overloaded (attempt \(attempt)) — retrying in \(String(format: "%.2f", delay))s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
        }
    }

    /// Fire-and-forget notification (no `id`, no reply).
    func notify<P: Encodable>(method: String, params: P) throws {
        let envelope = OutboundNotification(method: method, params: params)
        let data = try jsonEncoder.encode(envelope)
        writeLine(data)
    }

    // MARK: Internals

    private func sendAndAwait<P: Encodable>(
        method: String,
        params: P,
        timeout: TimeInterval
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            stateQueue.async {
                guard self.process?.isRunning == true else {
                    cont.resume(throwing: ClientError.notRunning)
                    return
                }
                self.nextID += 1
                let id = self.nextID
                self.pending[id] = { result in
                    switch result {
                    case .success(let data): cont.resume(returning: data)
                    case .failure(let err): cont.resume(throwing: err)
                    }
                }

                let envelope = OutboundRequest(id: id, method: method, params: params)
                let data: Data
                do {
                    data = try self.jsonEncoder.encode(envelope)
                } catch {
                    self.pending[id] = nil
                    cont.resume(throwing: error)
                    return
                }
                self.writeLine(data)

                // Timeout — if we still have a pending continuation when
                // the deadline hits, fail it.
                self.stateQueue.asyncAfter(deadline: .now() + timeout) {
                    if let pending = self.pending.removeValue(forKey: id) {
                        pending(.failure(ClientError.timeout(method: method)))
                    }
                }
            }
        }
    }

    private func writeLine(_ data: Data) {
        writeQueue.async { [weak self] in
            guard let self, let stdin = self.stdin else { return }
            do {
                try stdin.write(contentsOf: data)
                try stdin.write(contentsOf: Data([0x0A]))
            } catch {
                Logger.shared.log("Codex write failed: \(error)")
            }
        }
    }

    private func readerLoop() {
        guard let stdout else { return }
        while true {
            let chunk = stdout.availableData
            if chunk.isEmpty {
                // EOF — child closed stdout.
                return
            }
            stateQueue.sync {
                self.readBuffer.append(chunk)
                while let nl = self.readBuffer.firstIndex(of: 0x0A) {
                    let line = self.readBuffer.subdata(in: self.readBuffer.startIndex..<nl)
                    self.readBuffer.removeSubrange(self.readBuffer.startIndex...nl)
                    if !line.isEmpty {
                        self.handleIncomingLine(line)
                    }
                }
            }
        }
    }

    private func stderrLoop() {
        guard let stderr else { return }
        var buf = Data()
        while true {
            let chunk = stderr.availableData
            if chunk.isEmpty { return }
            buf.append(chunk)
            while let nl = buf.firstIndex(of: 0x0A) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                if !line.isEmpty, let s = String(data: line, encoding: .utf8) {
                    Logger.shared.log("Codex[stderr]: \(s)")
                }
            }
        }
    }

    /// Always called inside `stateQueue.sync`.
    private func handleIncomingLine(_ data: Data) {
        // Try to peek the envelope: id + (result|error|method).
        guard let envelope = try? jsonDecoder.decode(InboundEnvelope.self, from: data) else {
            if let s = String(data: data, encoding: .utf8) {
                Logger.shared.log("Codex[unparseable]: \(s.prefix(200))")
            }
            return
        }

        if let id = envelope.id {
            guard let handler = self.pending.removeValue(forKey: id) else {
                Logger.shared.log("Codex: response for unknown id=\(id) — dropped")
                return
            }
            if let err = envelope.error {
                handler(.failure(ClientError.rpcFailed(err)))
            } else {
                // Re-extract the raw `result` blob from the line so the
                // caller can decode into a typed struct.
                let resultData = extractField(name: "result", from: data) ?? Data("null".utf8)
                handler(.success(resultData))
            }
            return
        }

        // Notification (no id).
        guard let method = envelope.method else {
            Logger.shared.log("Codex: unrecognised inbound message — no id, no method")
            return
        }
        let params = envelope.params ?? .null
        notificationQueue.async { [weak self] in
            self?.onNotification?(method, params)
        }
    }

    private func handleProcessExit(status: Int32) {
        let wasShuttingDown: Bool = stateQueue.sync {
            let was = self.shuttingDown
            // Cancel pending continuations so we don't leak.
            for (_, handler) in self.pending {
                handler(.failure(ClientError.notRunning))
            }
            self.pending.removeAll()
            return was
        }
        Logger.shared.log("Codex app-server exited (status=\(status), shuttingDown=\(wasShuttingDown))")
        if !wasShuttingDown {
            DispatchQueue.main.async { [weak self] in
                self?.onUnexpectedExit?()
            }
        }
    }

    private func backoffDelay(attempt: Int) -> TimeInterval {
        let base = pow(2.0, Double(attempt - 1)) * 0.5  // 0.5s, 1s, 2s, ...
        let jitter = Double.random(in: 0...0.25)
        return min(base + jitter, 10)
    }

    // MARK: Codecs

    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    // MARK: Wire types

    private struct OutboundRequest<P: Encodable>: Encodable {
        let id: Int64
        let method: String
        let params: P
    }

    private struct OutboundNotification<P: Encodable>: Encodable {
        let method: String
        let params: P
    }

    private struct EmptyParams: Encodable {}

    /// Loose envelope for decoding *anything* the server sends. We deliberately
    /// don't try to type the `result` or `params` field at this layer — we
    /// just pluck them back out of the raw line for the typed call site.
    private struct InboundEnvelope: Decodable {
        let id: Int64?
        let method: String?
        let params: AppServerProtocol.JSON?
        let error: AppServerProtocol.RPCError?
    }
}

/// Re-extract a top-level JSON field from a raw line as Data, so we can
/// hand it back to the caller for typed decoding. Cheaper than re-encoding
/// a fully-decoded `JSON` tree.
private func extractField(name: String, from data: Data) -> Data? {
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let field = obj[name] else { return nil }
    return try? JSONSerialization.data(withJSONObject: field, options: [.fragmentsAllowed])
}
