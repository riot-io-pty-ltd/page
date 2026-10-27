import Foundation

/// Herdr (herdrdev/herdr), an agent-focused terminal multiplexer. Its
/// agents run in a PTY owned by `herdr server`, often a launchd job with no
/// GUI app above it, so Page talks to Herdr's own socket API instead: the
/// agent's environment names its pane (`HERDR_PANE_ID`) and the server
/// (`HERDR_SOCKET_PATH`), and Herdr's own process listing must put the
/// session in front in that pane before anything is typed. Pane ids belong
/// to one server, so the default socket is never used as a fallback.
/// Exact or nothing, as everywhere else.
///
/// Transport: newline-delimited JSON over a Unix socket, one request per
/// line (`{"id":"1","method":"ping","params":{}}`). Success is
/// `{"id","result":{"type":…}}`, failure `{"id","error":{"code","message"}}`.
/// Checked against the v0.9.5 socket API schema.
enum HerdrBridge {
    struct Target: Equatable {
        let socketPath: String
        let paneId: String
        /// Herdr's id for the terminal in the pane; a pane id can be reused
        /// for another terminal, so this is re-checked before every key.
        let terminalId: String
        /// The session verified in front in the pane. Kept here so every
        /// sender can re-verify without being handed the session.
        let sessionPid: Int32

        var label: String { "Herdr pane \(paneId)" }
    }

    /// The fields of `pane.get` Page uses.
    struct PaneInfo: Equatable {
        let paneId: String
        let terminalId: String
        let workspaceId: String?
    }

    /// The fields of `pane.process_info` Page uses.
    struct ProcessInfo: Equatable {
        let paneId: String?
        let shellPid: Int32?
        /// The foreground job's processes (Herdr 0.9.5 gives no tty).
        let foregroundPids: [Int32]
    }

    enum RPCError: Error, Equatable {
        /// Couldn't connect, send or read in time.
        case transport(String)
        /// The reply isn't a response to this request.
        case malformed(String)
        /// A well-formed reply, but to a different request.
        case idMismatch
        /// A success reply of another type than the request's.
        case wrongType(String)
        /// Herdr said no (`error.code` / `error.message`).
        case server(code: String, message: String)
    }

    /// Environment variables read from the session.
    static let envKeys: Set<String> = ["HERDR_ENV", "HERDR_SOCKET_PATH", "HERDR_PANE_ID", "HERDR_WORKSPACE_ID"]

    static let timeout: TimeInterval = 3
    /// A reply larger than this is refused rather than buffered.
    static let maxReplyBytes = 4 * 1024 * 1024
    /// `sun_path` holds 104 bytes on macOS, including the terminator.
    static let maxSocketPathBytes = 103

    // MARK: finding the session's pane

    enum Plan: Equatable {
        /// Nothing says this session runs in Herdr.
        case notHerdr
        case target(socketPath: String, paneId: String, workspaceId: String?)
        /// Herdr, but the pane can't be named (phone-safe reason).
        case refuse(String)
    }

    static let missingPaneReason = "Couldn't find the session's Herdr pane — it wasn't started with Herdr's pane variables"

    /// Pure. Whether the session runs in Herdr (its environment says so, or
    /// a `herdr` process is among its ancestors) and, if so, the pane and
    /// socket its own environment names. A missing or odd value refuses:
    /// the default socket is never guessed.
    static func plan(env: [String: String], ancestorCommands: [String]) -> Plan {
        guard isHerdr(env: env, ancestorCommands: ancestorCommands) else { return .notHerdr }
        guard let socket = env["HERDR_SOCKET_PATH"], let pane = env["HERDR_PANE_ID"] else {
            return .refuse(missingPaneReason)
        }
        guard isUsableSocketPath(socket) else { return .refuse("Herdr's socket path looks wrong — answer at the Mac") }
        guard isValidPaneId(pane) else { return .refuse(missingPaneReason) }
        let workspace = env["HERDR_WORKSPACE_ID"].flatMap { $0.isEmpty ? nil : $0 }
        return .target(socketPath: socket, paneId: pane, workspaceId: workspace)
    }

    /// Pure. `HERDR_ENV` is set in every pane process; the ancestor check
    /// covers an environment that was scrubbed on the way (the server is
    /// `herdr server`).
    static func isHerdr(env: [String: String], ancestorCommands: [String]) -> Bool {
        if env["HERDR_ENV"] != nil { return true }
        return ancestorCommands.contains { command in
            let exe = command.split(separator: " ").first.map(String.init) ?? command
            return (exe as NSString).lastPathComponent.lowercased() == "herdr"
        }
    }

    /// Pure. Public pane ids look like "w1:p2".
    static func isValidPaneId(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= 64 else { return false }
        return id.unicodeScalars.allSatisfy { s in
            (s.value < 128) && (CharacterSet.alphanumerics.contains(s) || ":_-.".unicodeScalars.contains(s))
        }
    }

    /// Pure. Absolute, no NUL, short enough for `sockaddr_un`.
    static func isUsableSocketPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= maxSocketPathBytes
    }

    /// Pure. Only a socket the user owns that no one else can write to.
    static func isTrustedSocket(mode: mode_t, ownerUid: uid_t, currentUid: uid_t) -> Bool {
        (mode & S_IFMT) == S_IFSOCK && ownerUid == currentUid && (mode & (S_IWGRP | S_IWOTH)) == 0
    }

    /// Why the socket at `path` can't be trusted (nil: it can). `lstat`, so
    /// a symlink is refused rather than followed.
    static func socketTrustFailure(path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return "Herdr isn't running (no socket) — answer at the Mac" }
        guard isTrustedSocket(mode: st.st_mode, ownerUid: st.st_uid, currentUid: getuid()) else {
            return "Herdr's socket isn't safe to use — answer at the Mac"
        }
        return nil
    }

    /// Pure. Why the session can't be typed into through `pane`, from
    /// Herdr's own answers (nil: it can). The session must be among the
    /// foreground job's processes: a shell that is merely an ancestor isn't
    /// enough, since a program started from it would be in front and the
    /// keys would go to that. `expectTerminalId` is set once the terminal
    /// is known, to catch a pane id reused for another terminal.
    static func verification(pane: PaneInfo, processes: ProcessInfo, paneId: String, workspaceId: String?,
                             expectTerminalId: String?, pid: Int32) -> String? {
        guard pane.paneId == paneId else { return "Herdr moved the session's pane — answer at the Mac" }
        if let workspaceId, let actual = pane.workspaceId, actual != workspaceId {
            return "Herdr moved the session's pane — answer at the Mac"
        }
        if let expectTerminalId, pane.terminalId != expectTerminalId {
            return "The Herdr pane now holds a different terminal — answer at the Mac"
        }
        if let processPane = processes.paneId, processPane != paneId {
            return "Herdr moved the session's pane — answer at the Mac"
        }
        guard pid > 0, processes.foregroundPids.contains(pid) else {
            return "Couldn't confirm the session is in front in its Herdr pane"
        }
        return nil
    }

    static func locate(socketPath: String, paneId: String, workspaceId: String?, pid: Int32) -> Result<Target, CmuxBridge.Failure> {
        if let why = socketTrustFailure(path: socketPath) {
            return .failure(.init(why, output: "socket \(socketPath) not trusted"))
        }
        switch snapshot(socketPath: socketPath, paneId: paneId) {
        case .failure(let e):
            return .failure(.init("Couldn't reach Herdr — answer at the Mac", output: "herdr: \(describe(e))"))
        case .success(let (pane, processes)):
            if let why = verification(pane: pane, processes: processes, paneId: paneId, workspaceId: workspaceId,
                                      expectTerminalId: nil, pid: pid) {
                return .failure(.init(why, output: "pane \(paneId) doesn't hold pid \(pid)"))
            }
            return .success(Target(socketPath: socketPath, paneId: paneId, terminalId: pane.terminalId, sessionPid: pid))
        }
    }

    /// Why keys must not go to `target` right now (nil: still the same
    /// terminal, with the session in front). Run before every key.
    static func recheck(_ target: Target) -> String? {
        switch snapshot(socketPath: target.socketPath, paneId: target.paneId) {
        case .failure: return "Couldn't reach Herdr — answer at the Mac"
        case .success(let (pane, processes)):
            return verification(pane: pane, processes: processes, paneId: target.paneId, workspaceId: nil,
                                expectTerminalId: target.terminalId, pid: target.sessionPid)
        }
    }

    private static func snapshot(socketPath: String, paneId: String) -> Swift.Result<(PaneInfo, ProcessInfo), RPCError> {
        switch call(socketPath, method: "pane.get", params: ["pane_id": paneId], parse: parsePaneInfo) {
        case .failure(let e): return .failure(e)
        case .success(let pane):
            switch call(socketPath, method: "pane.process_info", params: ["pane_id": paneId], parse: parseProcessInfo) {
            case .failure(let e): return .failure(e)
            case .success(let processes): return .success((pane, processes))
            }
        }
    }

    static func describe(_ error: RPCError) -> String {
        switch error {
        case .transport(let s): return "transport: \(s)"
        case .malformed(let s): return "malformed reply: \(s)"
        case .idMismatch: return "reply for another request"
        case .wrongType(let t): return "unexpected reply type \(t)"
        case .server(let code, let message): return "\(code): \(message.prefix(200))"
        }
    }

    // MARK: requests

    /// Pure. One request line (with its newline). Built with the JSON
    /// encoder so no text can break the one-request-per-line framing.
    static func request(id: String, method: String, params: [String: Any]) -> String {
        let object: [String: Any] = ["id": id, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return "" }
        return line + "\n"
    }

    /// Pure. The request that types one keystroke into `paneId`. Single-line
    /// text is sent as typed (`pane.send_text`: no paste, no Enter) so "1"
    /// picks a menu option; multi-line text goes through `pane.send_input`,
    /// which pastes it when the app asked for bracketed paste, so its
    /// newlines don't submit. Enter and Esc are keys of their own. Never
    /// `agent.prompt`: it refuses while the agent is blocked.
    static func sendRequest(id: String, paneId: String, key: Keystroke) -> String? {
        switch key {
        case .text(let s) where s.contains("\n"):
            return request(id: id, method: "pane.send_input", params: ["pane_id": paneId, "text": s])
        case .text(let s):
            return request(id: id, method: "pane.send_text", params: ["pane_id": paneId, "text": s])
        case .enter:
            return request(id: id, method: "pane.send_keys", params: ["pane_id": paneId, "keys": ["enter"]])
        case .escape:
            return request(id: id, method: "pane.send_keys", params: ["pane_id": paneId, "keys": ["esc"]])
        case .key(let k):
            // Herdr's key names are unverified: the answer plan only reaches here after a screen check per key.
            return request(id: id, method: "pane.send_keys", params: ["pane_id": paneId, "keys": [k.rawValue]])
        case .pause, .awaitPromptClosed:
            return nil
        }
    }

    /// Pure. The visible screen, with colours when `styled` (Herdr strips
    /// escapes by default, so that is switched off too).
    static func readRequest(id: String, paneId: String, styled: Bool) -> String {
        request(id: id, method: "pane.read",
                params: ["pane_id": paneId, "source": "visible", "format": styled ? "ansi" : "text", "strip_ansi": !styled])
    }

    // MARK: responses

    /// Pure. The `result` object of a reply to request `id`, when it has
    /// type `type`. An error reply carries Herdr's code and message (its
    /// `id` may be empty when the request wasn't valid JSON). Unknown
    /// fields are ignored.
    static func result(from line: String, id: String, type: String) -> Swift.Result<[String: Any], RPCError> {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.malformed("not a JSON object"))
        }
        let replyId = object["id"] as? String
        if let error = object["error"] as? [String: Any] {
            if let replyId, !replyId.isEmpty, replyId != id { return .failure(.idMismatch) }
            return .failure(.server(code: error["code"] as? String ?? "unknown", message: error["message"] as? String ?? ""))
        }
        guard replyId == id else { return .failure(replyId == nil ? .malformed("no id") : .idMismatch) }
        guard let result = object["result"] as? [String: Any] else { return .failure(.malformed("no result")) }
        guard let actual = result["type"] as? String else { return .failure(.malformed("no result type")) }
        guard actual == type else { return .failure(.wrongType(actual)) }
        return .success(result)
    }

    /// Pure. `pane.get` → `{"type":"pane_info","pane":{…}}`.
    static func parsePaneInfo(_ line: String, id: String) -> Swift.Result<PaneInfo, RPCError> {
        result(from: line, id: id, type: "pane_info").flatMap { result in
            guard let pane = result["pane"] as? [String: Any],
                  let paneId = pane["pane_id"] as? String, !paneId.isEmpty,
                  let terminalId = pane["terminal_id"] as? String, !terminalId.isEmpty else {
                return .failure(.malformed("pane_info without pane_id / terminal_id"))
            }
            return .success(PaneInfo(paneId: paneId, terminalId: terminalId, workspaceId: pane["workspace_id"] as? String))
        }
    }

    /// Pure. `pane.process_info` → `{"type":"pane_process_info","process_info":{…}}`.
    static func parseProcessInfo(_ line: String, id: String) -> Swift.Result<ProcessInfo, RPCError> {
        result(from: line, id: id, type: "pane_process_info").flatMap { result in
            guard let info = result["process_info"] as? [String: Any] else {
                return .failure(.malformed("pane_process_info without process_info"))
            }
            let processes = info["foreground_processes"] as? [[String: Any]] ?? []
            let pids = processes.compactMap { ($0["pid"] as? NSNumber)?.int32Value }
            return .success(ProcessInfo(paneId: info["pane_id"] as? String,
                                        shellPid: (info["shell_pid"] as? NSNumber)?.int32Value,
                                        foregroundPids: pids))
        }
    }

    /// Pure. `pane.read` → `{"type":"pane_read","read":{"text":…}}`, with
    /// CRLF line ends made LF (the input-box reader splits on LF).
    static func parseRead(_ line: String, id: String) -> Swift.Result<String, RPCError> {
        result(from: line, id: id, type: "pane_read").flatMap { result in
            guard let read = result["read"] as? [String: Any], let text = read["text"] as? String else {
                return .failure(.malformed("pane_read without text"))
            }
            return .success(text.replacingOccurrences(of: "\r\n", with: "\n"))
        }
    }

    /// Pure. A send → `{"type":"ok"}`.
    static func parseAck(_ line: String, id: String) -> Swift.Result<Void, RPCError> {
        result(from: line, id: id, type: "ok").map { _ in () }
    }

    /// Pure. The first line in `buffer` (without its newline), once a
    /// complete one has arrived.
    static func firstLine(in buffer: Data) -> String? {
        guard let end = buffer.firstIndex(of: 0x0A) else { return nil }
        return String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self)
    }

    // MARK: transport

    /// One request, one reply, on a fresh connection.
    static func call<T>(_ socketPath: String, method: String, params: [String: Any],
                        parse: (String, String) -> Swift.Result<T, RPCError>) -> Swift.Result<T, RPCError> {
        let id = "page-" + UUID().uuidString.prefix(8)
        return exchange(socketPath: socketPath, line: request(id: id, method: method, params: params))
            .flatMap { parse($0, id) }
    }

    /// Writes `line` and reads one reply line, all within `timeout`.
    static func exchange(socketPath: String, line: String, timeout: TimeInterval = HerdrBridge.timeout) -> Swift.Result<String, RPCError> {
        guard isUsableSocketPath(socketPath) else { return .failure(.transport("bad socket path")) }
        guard !line.isEmpty else { return .failure(.transport("empty request")) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.transport("socket: errno \(errno)")) }
        defer { close(fd) }
        // A server that just died must not kill Page with SIGPIPE.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let deadline = Date().addingTimeInterval(timeout)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() { raw[i] = b }
            raw[pathBytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS, wait(fd, events: Int16(POLLOUT), until: deadline) else {
                return .failure(.transport("connect: errno \(errno)"))
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            guard soError == 0 else { return .failure(.transport("connect: errno \(soError)")) }
        }

        let out = Array(line.utf8)
        var sent = 0
        while sent < out.count {
            let n = out.withUnsafeBytes { write(fd, $0.baseAddress! + sent, out.count - sent) }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EINTR { continue }
            guard n < 0, errno == EAGAIN, wait(fd, events: Int16(POLLOUT), until: deadline) else {
                return .failure(.transport("write: errno \(errno)"))
            }
        }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            guard wait(fd, events: Int16(POLLIN), until: deadline) else { return .failure(.transport("timed out")) }
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(chunk, count: n)
                if buffer.count > maxReplyBytes { return .failure(.transport("reply too large")) }
                // Look for the newline in the new bytes only: rescanning the
                // whole buffer each time makes a large reply quadratic.
                if memchr(chunk, 0x0A, n) != nil, let reply = firstLine(in: buffer) { return .success(reply) }
            } else if n == 0 {
                // Closed after the reply, without a final newline.
                return buffer.isEmpty ? .failure(.transport("closed without a reply")) : .success(String(decoding: buffer, as: UTF8.self))
            } else if errno != EINTR && errno != EAGAIN {
                return .failure(.transport("read: errno \(errno)"))
            }
        }
    }

    private static func wait(_ fd: Int32, events: Int16, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var p = pollfd(fd: fd, events: events, revents: 0)
            let r = poll(&p, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if r > 0 { return true }
            if r < 0, errno != EINTR { return false }
        }
    }

    // MARK: typing and reading

    /// Types one keystroke. The result is shaped like a CLI run so
    /// `sendViaControlCLI` can drive it; the caller re-verifies first.
    static func send(_ target: Target, key: Keystroke) -> ProcessRunner.Result? {
        let id = "page-" + UUID().uuidString.prefix(8)
        guard let line = sendRequest(id: id, paneId: target.paneId, key: key) else { return nil }
        let reply = exchange(socketPath: target.socketPath, line: line).flatMap { parseAck($0, id: id) }
        switch reply {
        case .success:
            return ProcessRunner.Result(status: 0, stdout: "", stderr: "", timedOut: false, launched: true)
        case .failure(let e):
            return ProcessRunner.Result(status: 1, stdout: "", stderr: describe(e), timedOut: false, launched: true)
        }
    }

    /// The visible screen of the target's pane. Checks the pane still holds
    /// the same terminal first, so another pane is never read as this one.
    static func screen(_ target: Target, styled: Bool) -> String? {
        guard case .success(let pane) = call(target.socketPath, method: "pane.get", params: ["pane_id": target.paneId], parse: parsePaneInfo),
              pane.paneId == target.paneId, pane.terminalId == target.terminalId else { return nil }
        let id = "page-" + UUID().uuidString.prefix(8)
        let reply = exchange(socketPath: target.socketPath, line: readRequest(id: id, paneId: target.paneId, styled: styled))
            .flatMap { parseRead($0, id: id) }
        if case .success(let text) = reply { return text }
        return nil
    }
}
