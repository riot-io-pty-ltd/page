import Foundation

/// Owns a `codex app-server` child process and exposes a small async API
/// over its newline-delimited JSON-RPC protocol.
///
/// What Page uses it for today: thread discovery (`thread/list`,
/// `thread/read`) and account-level notifications. Each Codex surface (CLI,
/// Desktop, VS Code) embeds its *own* app-server, so this child can list
/// every thread on disk but never sees their turn/approval traffic — the
/// live signal comes from the rollout files (see `CodexBackend`). Server
/// requests are still routed properly so the client is correct the day
/// sessions run against a shared server (`codex --remote`).
///
/// Design notes:
///   - Stdio transport only. WebSocket is documented as "experimental and
///     unsupported" in the Codex docs.
///   - One serial queue (`stateQueue`) owns every mutable field: the child,
///     its stdin, the pending-call map, the line framer and `generation`.
///     Writes are funnelled through `writeQueue`; reads happen on a
///     dedicated reader thread per child.
///   - `generation` increments on every spawn and shutdown. Reader threads,
///     termination handlers and queued writes carry the generation they
///     were created for and become no-ops once it's stale, so a late exit
///     of an old child can never fail the new child's calls.
///   - The stdin pipe has F_SETNOSIGPIPE: writing to a dead child returns
///     EPIPE (logged) instead of killing the whole menu-bar app.
///   - Server-overload errors (code -32001) trigger automatic retry with
///     exponential backoff + jitter (up to 3 attempts).
final class AppServerClient: @unchecked Sendable {

    typealias JSON = AppServerProtocol.JSON
    typealias RequestID = AppServerProtocol.RequestID
    typealias NotificationHandler = (_ method: String, _ params: JSON) -> Void

    /// A request the server sent us. Answer it with `respond(to:result:)` or
    /// `respondError(to:code:message:)`; the answer is dropped if the child
    /// that asked has since exited.
    struct ServerRequest {
        let id: RequestID
        let method: String
        let params: JSON
        /// Identifies the child process that sent it. Request ids restart at
        /// zero with every child, so anything keyed by them (intervention ids)
        /// must include this.
        let childToken: String
        fileprivate let generation: UInt64
    }

    enum ClientError: Error, CustomStringConvertible {
        case notRunning
        case notReady
        case spawnFailed(String)
        case timeout(method: String)
        case rpcFailed(AppServerProtocol.RPCError)
        case decodeFailed(method: String, underlying: Error)

        var description: String {
            switch self {
            case .notRunning: return "app-server is not running"
            case .notReady: return "app-server handshake hasn't finished"
            case .spawnFailed(let s): return "failed to spawn codex app-server: \(s)"
            case .timeout(let m): return "timed out waiting for \(m) reply"
            case .rpcFailed(let e): return "rpc \(e.code): \(e.message ?? "(no message)")"
            case .decodeFailed(let m, let u): return "decode failed for \(m): \(u)"
            }
        }
    }

    /// Callbacks are delivered on `callbackQueue` (serial, never main) so
    /// the reader thread stays responsive. Set them before `start()`.
    var onNotification: NotificationHandler?
    /// Return true to take ownership of the request (you must answer it);
    /// false (or no handler) makes the client answer -32601 straight away so
    /// the server never blocks on Page.
    var onServerRequest: ((ServerRequest) -> Bool)?
    /// Fired when the current child exits without `shutdown()` asking it to.
    var onUnexpectedExit: (() -> Void)?

    private let callbackQueue = DispatchQueue(label: "ClaudePowerMode.codex.callbacks")
    private let stateQueue = DispatchQueue(label: "ClaudePowerMode.codex.state")
    private let writeQueue = DispatchQueue(label: "ClaudePowerMode.codex.write")

    // All below: stateQueue only.
    private var configuredPath: String
    private var process: Process?
    private var stdin: FileHandle?
    private var generation: UInt64 = 0
    private var childToken = ""
    private var framer = JSONLineFramer()
    private var nextID: Int64 = 0
    private var pending: [Int64: (Result<JSON, Error>) -> Void] = [:]
    private var ready = false
    private var shuttingDown = false

    /// `codexPath` is the user's configured path; empty means auto-discover
    /// via `ProcessRunner.findExecutable` at each spawn.
    init(codexPath: String = "") {
        self.configuredPath = codexPath
    }

    /// Takes effect on the next spawn. The backend restarts the client when
    /// the configured path changes.
    var codexPath: String {
        get { stateQueue.sync { configuredPath } }
        set { stateQueue.sync { configuredPath = newValue } }
    }

    /// The child is alive (it may still be handshaking).
    var isRunning: Bool {
        stateQueue.sync { process?.isRunning ?? false }
    }

    /// The child is alive and the initialize handshake completed.
    var isReady: Bool {
        stateQueue.sync { ready && (process?.isRunning ?? false) }
    }

    // MARK: Lifecycle

    /// Spawn `codex app-server` (replacing any previous child), do the
    /// `initialize` + `initialized` handshake, and return the server's
    /// initialize result. A failed handshake terminates the child it
    /// spawned, so retries never accumulate orphans.
    func start(clientName: String = "Page",
               clientVersion: String = "0.1") async throws -> AppServerProtocol.InitializeResult {
        let gen = try spawn()
        do {
            let initParams = AppServerProtocol.InitializeParams(
                clientInfo: .init(name: clientName, title: clientName, version: clientVersion),
                capabilities: .init(experimentalApi: true)
            )
            // Cold `node` + Rust start can be slow on a busy Mac.
            let raw = try await sendAndAwait(method: "initialize", params: initParams,
                                             timeout: 20, requireReady: false)
            let initResult: AppServerProtocol.InitializeResult = try decode(raw, method: "initialize")
            let notified = stateQueue.sync { () -> Bool in
                guard gen == generation, let handle = stdin else { return false }
                guard let data = try? jsonEncoder.encode(OutboundNotification(method: "initialized", params: EmptyParams())) else { return false }
                enqueueWrite(data, to: handle, generation: gen)
                ready = true
                return true
            }
            guard notified else { throw ClientError.notRunning }
            Logger.shared.log("Codex app-server initialized: userAgent=\(initResult.userAgent ?? "?") codexHome=\(initResult.codexHome ?? "?")")
            return initResult
        } catch {
            terminateChild(generation: gen)
            throw error
        }
    }

    /// Stop the child (SIGTERM, SIGKILL after 2s) and fail in-flight calls.
    /// Safe to call repeatedly; a later `start()` works normally.
    func shutdown() {
        let proc: Process? = stateQueue.sync {
            shuttingDown = true
            generation &+= 1   // stale-ify the exit handler and reader thread
            return detachChildLocked(failPendingWith: .notRunning)
        }
        Self.terminate(proc)
    }

    // MARK: Calls

    /// Send a request and await the typed result. Requires a completed
    /// handshake. Retries automatically on `-32001 server overloaded`.
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
                let raw = try await sendAndAwait(method: method, params: params,
                                                 timeout: timeout, requireReady: true)
                return try decode(raw, method: method)
            } catch ClientError.rpcFailed(let e)
                where e.code == AppServerProtocol.errorCodeServerOverloaded && attempt < maxAttempts {
                let delay = backoffDelay(attempt: attempt)
                Logger.shared.log("Codex \(method) overloaded (attempt \(attempt)) — retrying in \(String(format: "%.2f", delay))s")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Answer a server request. Returns false if the child that asked is
    /// gone (the answer would reach a different process, so it's dropped).
    @discardableResult
    func respond<R: Encodable>(to request: ServerRequest, result: R) -> Bool {
        guard let data = try? jsonEncoder.encode(OutboundResult(id: request.id, result: result)) else { return false }
        return write(data, forGeneration: request.generation)
    }

    @discardableResult
    func respondError(to request: ServerRequest, code: Int, message: String) -> Bool {
        let body = OutboundError(id: request.id, error: .init(code: code, message: message))
        guard let data = try? jsonEncoder.encode(body) else { return false }
        return write(data, forGeneration: request.generation)
    }

    // MARK: Internals — process

    /// Spawns a fresh child, tearing down any previous one first. Returns the
    /// new generation.
    private func spawn() throws -> UInt64 {
        let configured = stateQueue.sync { configuredPath }
        guard let exe = ProcessRunner.findExecutable("codex", configured: configured) else {
            throw ClientError.spawnFailed(configured.isEmpty
                ? "codex not found in ~/.local/bin, Homebrew, /usr/local/bin, npm-global or nvm — set codexPath in config.json"
                : "codex not found or not executable at \(configured)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["app-server"]
        // `codex` is often a Node script (`#!/usr/bin/env node`); under a
        // LaunchAgent PATH is the sparse system default and `node` wouldn't
        // resolve.
        p.environment = ProcessRunner.augmentedEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        // Writes to a dead child must fail with EPIPE, not raise SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let (gen, previous): (UInt64, Process?) = stateQueue.sync {
            let old = detachChildLocked(failPendingWith: .notRunning)
            generation &+= 1
            shuttingDown = false
            ready = false
            framer = JSONLineFramer()
            process = p
            stdin = stdinPipe.fileHandleForWriting
            childToken = String(Int(Date().timeIntervalSince1970))
            return (generation, old)
        }
        Self.terminate(previous)

        p.terminationHandler = { [weak self] proc in
            self?.handleProcessExit(generation: gen, status: proc.terminationStatus)
        }

        do {
            try p.run()
        } catch {
            stateQueue.sync {
                if generation == gen { _ = detachChildLocked(failPendingWith: .notRunning) }
            }
            throw ClientError.spawnFailed(error.localizedDescription)
        }
        Logger.shared.log("Codex app-server spawned: \(exe) pid=\(p.processIdentifier)")

        let out = stdoutPipe.fileHandleForReading
        let err = stderrPipe.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            Self.drain(out) { chunk in
                guard let self else { return false }
                return self.ingest(chunk, generation: gen)
            }
        }
        Thread.detachNewThread {
            var framer = JSONLineFramer()
            Self.drain(err) { chunk in
                for line in framer.append(chunk) {
                    Logger.shared.log("Codex[stderr]: \(String(decoding: line.prefix(500), as: UTF8.self))")
                }
                return true
            }
        }
        return gen
    }

    /// Clears the current child's state and returns it for termination.
    /// stateQueue only.
    private func detachChildLocked(failPendingWith error: ClientError) -> Process? {
        let proc = process
        process = nil
        ready = false
        if let handle = stdin {
            stdin = nil
            // Close after any writes already queued for it.
            writeQueue.async { try? handle.close() }
        }
        let handlers = pending.values
        pending.removeAll()
        for h in handlers { h(.failure(error)) }
        framer = JSONLineFramer()
        return proc
    }

    /// Handshake failed: kill the child we just spawned without reporting it
    /// as an unexpected exit (the caller already knows).
    private func terminateChild(generation gen: UInt64) {
        let proc: Process? = stateQueue.sync {
            guard gen == generation else { return nil }
            generation &+= 1
            return detachChildLocked(failPendingWith: .notRunning)
        }
        Self.terminate(proc)
    }

    private static func terminate(_ proc: Process?) {
        guard let proc, proc.isRunning else { return }
        proc.terminate()
        let pid = proc.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if proc.isRunning {
                Logger.shared.log("Codex app-server pid=\(pid) ignored SIGTERM — sending SIGKILL")
                kill(pid, SIGKILL)
            }
        }
    }

    private func handleProcessExit(generation gen: UInt64, status: Int32) {
        let (current, intentional): (Bool, Bool) = stateQueue.sync {
            guard gen == generation else { return (false, true) }
            _ = detachChildLocked(failPendingWith: .notRunning)
            return (true, shuttingDown)
        }
        guard current else { return }
        Logger.shared.log("Codex app-server exited (status=\(status), intentional=\(intentional))")
        if !intentional {
            callbackQueue.async { [weak self] in self?.onUnexpectedExit?() }
        }
    }

    /// Blocking read loop. `body` returns false to stop early.
    private static func drain(_ handle: FileHandle, _ body: (Data) -> Bool) {
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 64 * 1024)
            } catch {
                return
            }
            guard let chunk, !chunk.isEmpty else { return }   // EOF
            if !body(chunk) { return }
        }
    }

    // MARK: Internals — I/O

    /// Returns false once this reader's child is stale.
    private func ingest(_ chunk: Data, generation gen: UInt64) -> Bool {
        stateQueue.sync {
            guard gen == generation else { return false }
            let lines = framer.append(chunk)
            if framer.droppedOversizedLine {
                Logger.shared.log("Codex: dropped an oversized line (> \(JSONLineFramer.maxLineBytes) bytes without a newline)")
            }
            for line in lines { handleIncomingLine(line, generation: gen) }
            return true
        }
    }

    /// stateQueue only.
    private func handleIncomingLine(_ line: Data, generation gen: UInt64) {
        switch AppServerProtocol.InboundMessage.classify(line) {
        case let .response(id, result, error):
            guard case .int(let n) = id, let handler = pending.removeValue(forKey: n) else {
                Logger.shared.log("Codex: response for unknown id=\(id) — dropped")
                return
            }
            if let error {
                handler(.failure(ClientError.rpcFailed(error)))
            } else {
                handler(.success(result))
            }

        case let .serverRequest(id, method, params):
            let request = ServerRequest(id: id, method: method, params: params,
                                        childToken: childToken, generation: gen)
            callbackQueue.async { [weak self] in
                guard let self else { return }
                if self.onServerRequest?(request) != true {
                    Logger.shared.log("Codex: answering unsupported server request \(method) (id=\(id)) with -32601")
                    self.respondError(to: request, code: AppServerProtocol.errorCodeMethodNotFound,
                                      message: "Page does not handle \(method)")
                }
            }

        case let .notification(method, params):
            callbackQueue.async { [weak self] in
                self?.onNotification?(method, params)
            }

        case .invalid(let reason):
            Logger.shared.log("Codex[unparseable: \(reason)]: \(String(decoding: line.prefix(200), as: UTF8.self))")
        }
    }

    private func sendAndAwait<P: Encodable>(
        method: String,
        params: P,
        timeout: TimeInterval,
        requireReady: Bool
    ) async throws -> JSON {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSON, Error>) in
            stateQueue.async {
                guard let proc = self.process, proc.isRunning, let handle = self.stdin else {
                    cont.resume(throwing: ClientError.notRunning)
                    return
                }
                guard self.ready || !requireReady else {
                    cont.resume(throwing: ClientError.notReady)
                    return
                }
                self.nextID += 1
                let id = self.nextID
                let data: Data
                do {
                    data = try self.jsonEncoder.encode(OutboundRequest(id: id, method: method, params: params))
                } catch {
                    cont.resume(throwing: error)
                    return
                }
                self.pending[id] = { result in cont.resume(with: result) }
                self.enqueueWrite(data, to: handle, generation: self.generation)

                self.stateQueue.asyncAfter(deadline: .now() + timeout) {
                    if let handler = self.pending.removeValue(forKey: id) {
                        handler(.failure(ClientError.timeout(method: method)))
                    }
                }
            }
        }
    }

    /// Write a line for a specific child. Returns false if it's gone.
    private func write(_ data: Data, forGeneration gen: UInt64) -> Bool {
        stateQueue.sync {
            guard gen == generation, let handle = stdin else { return false }
            enqueueWrite(data, to: handle, generation: gen)
            return true
        }
    }

    /// Callable from stateQueue (it only hops to writeQueue asynchronously).
    private func enqueueWrite(_ data: Data, to handle: FileHandle, generation gen: UInt64) {
        var line = data
        line.append(0x0A)
        writeQueue.async { [weak self] in
            guard let self, self.stateQueue.sync(execute: { self.generation == gen && self.stdin != nil }) else { return }
            do {
                try handle.write(contentsOf: line)
            } catch {
                // EPIPE when the child died between the check and the write;
                // its termination handler does the cleanup.
                Logger.shared.log("Codex write failed: \(error)")
            }
        }
    }

    private func decode<R: Decodable>(_ json: JSON, method: String) throws -> R {
        if let same = json as? R { return same }
        do {
            let data = try jsonEncoder.encode(json)
            return try jsonDecoder.decode(R.self, from: data)
        } catch {
            throw ClientError.decodeFailed(method: method, underlying: error)
        }
    }

    private func backoffDelay(attempt: Int) -> TimeInterval {
        let base = pow(2.0, Double(attempt - 1)) * 0.5  // 0.5s, 1s, 2s, ...
        let jitter = Double.random(in: 0...0.25)
        return min(base + jitter, 10)
    }

    // MARK: Codecs

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

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

    private struct OutboundResult<R: Encodable>: Encodable {
        let id: RequestID
        let result: R
    }

    private struct OutboundError: Encodable {
        struct Body: Encodable {
            let code: Int
            let message: String
        }
        let id: RequestID
        let error: Body
    }

    private struct EmptyParams: Encodable {}
}

/// Splits a byte stream into newline-terminated lines. Partial lines are
/// buffered until their newline arrives; `\r\n` endings and blank lines are
/// tolerated. A line that grows past `maxLineBytes` without a newline is
/// dropped (the stream is corrupt; better to resync than to grow forever).
struct JSONLineFramer {
    static let maxLineBytes = 32 * 1024 * 1024

    private var buffer = Data()
    /// Set by the last `append` if it had to discard an oversized line.
    private(set) var droppedOversizedLine = false

    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ chunk: Data) -> [Data] {
        droppedOversizedLine = false
        buffer.append(chunk)
        var lines: [Data] = []
        var start = buffer.startIndex
        while let nl = buffer[start...].firstIndex(of: 0x0A) {
            var end = nl
            if end > start, buffer[end - 1] == 0x0D { end -= 1 }
            if end > start { lines.append(Data(buffer[start..<end])) }
            start = buffer.index(after: nl)
        }
        if start > buffer.startIndex {
            buffer = Data(buffer[start...])
        }
        if buffer.count > Self.maxLineBytes {
            buffer = Data()
            droppedOversizedLine = true
        }
        return lines
    }
}
