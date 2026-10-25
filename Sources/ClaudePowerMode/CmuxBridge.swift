import AppKit
import Darwin
import Foundation
import Security

/// Page's bridge into cmux (com.cmuxterm.app), the terminal most of the
/// user's agent sessions run in.
///
/// How it reaches a session, and why:
///   - Which pane: cmux records `sessionId → surfaceId` for Claude in
///     `~/.cmuxterm/claude-hook-sessions.json` (with the pid and its start
///     time, so a recycled pid can't match). Sessions missing from that file
///     still carry `CMUX_SURFACE_ID` in their environment, which a same-user
///     process can read without privileges (KERN_PROCARGS2). Either way the
///     process must descend from the cmux app itself.
///   - Talking to cmux: only through its bundled CLI (never cmux code — cmux
///     is GPL-3.0, Page is Apache-2.0), spawned via ProcessRunner with a
///     timeout. Every command names its surface explicitly and runs with all
///     inherited `CMUX_*` variables stripped, so nothing ever falls back to
///     "the surface Page happened to be launched from".
///   - Access: cmux's default socket mode (cmuxOnly) refuses apps launched
///     by macOS, as Page is. `cmux socket-status --json` reports the mode
///     without connecting; Page works in automation / allowAll mode, or in
///     password mode with the password the user stored in the Keychain
///     (service "local.Page.cmux"). The password goes to the CLI in
///     `CMUX_SOCKET_PASSWORD` — the documented env var — never on argv,
///     which any local user can read with ps — and only to a CLI whose
///     code signature is cmux's own (see `isTrustedCLI`).
///   - Approvals: while cmux's PermissionRequest hook holds a request (up
///     to ~120 s) Claude's own menu isn't on screen, so typed "1"/Esc would
///     land in the input box. Those are answered through cmux's Feed
///     (`feed.permission.reply` / `feed.exit_plan.reply`).
///   - Typing: guarded by cmux's own reading of the agent's input row
///     (`surface.input_state`: empty / draft / dialog). Menu keys only into
///     a dialog; text only into an empty prompt.
///
/// Thread-safe: stateless apart from a small locked socket-status cache.
enum CmuxBridge {
    static let keychainService = "local.Page.cmux"
    static let keychainAccount = "socket-password"
    static let bundleIdentifier = "com.cmuxterm.app"

    // Phone-facing details (short, human, no command output).
    static let blockedDetail = "cmux blocks Page — open Page ▸ Integrations ▸ Set up cmux…"
    static let needsPasswordDetail = "Page needs your cmux socket password — open Page ▸ Integrations ▸ Set up cmux…"
    static let passwordRejectedDetail = "cmux rejected Page's password — open Page ▸ Integrations ▸ Set up cmux…"
    static let notRunningDetail = "cmux isn't running"
    static let draftDetail = "You have a half-typed message in that pane"
    static let dialogOpenDetail = "A prompt is open in that pane — answer it first"
    static let noInputBoxDetail = "Couldn't see the agent's input box in that cmux pane — reply at the Mac"
    static let paneNotFoundDetail = "Couldn't find the session's cmux pane"

    struct Failure: Error, Equatable {
        /// Phone-safe.
        let detail: String
        /// Diagnostic for the Mac / Worker log.
        let output: String
        init(_ detail: String, output: String = "") {
            self.detail = detail
            self.output = output.isEmpty ? detail : output
        }
    }

    enum Agent: String {
        case claude
        case codex
        var hookSessionsFileName: String { "\(rawValue)-hook-sessions.json" }
    }

    /// A cmux pane hosting one agent process.
    struct Target: Equatable {
        let surfaceId: String
        let workspaceId: String?
        /// The CLI shipped inside the cmux app that hosts the session (each
        /// cmux channel — stable, NEXT, nightly — has its own socket).
        let cliPath: String
        /// "hook-sessions" or "environment"; for the log.
        let source: String

        var label: String { "cmux pane" }
    }

    // MARK: - detection

    /// True for a cmux app's main executable
    /// ("/Applications/cmux.app/Contents/MacOS/cmux", "cmux NEXT.app", …).
    static func isCmuxAppCommand(_ command: String) -> Bool {
        bundlePath(fromAppCommand: command) != nil
    }

    /// "/Applications/cmux.app/Contents/MacOS/cmux -x" → "/Applications/cmux.app",
    /// nil unless the bundle is a cmux app.
    static func bundlePath(fromAppCommand command: String) -> String? {
        guard let r = command.range(of: ".app/Contents/MacOS/") else { return nil }
        let bundleBase = String(command[..<r.lowerBound])
        let name = (bundleBase as NSString).lastPathComponent.lowercased()
        guard name == "cmux" || name.hasPrefix("cmux ") else { return nil }
        return bundleBase + ".app"
    }

    /// The cmux CLI to use for a session hosted by the app at `bundlePath`:
    /// that bundle's own CLI first, then the installed app's. Never the PATH
    /// shims cmux puts in its own terminals.
    static func cliPath(forBundlePath bundlePath: String?) -> String? {
        var candidates: [String] = []
        if let bundlePath { candidates.append(bundlePath + "/Contents/Resources/bin/cmux") }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            candidates.append(url.path + "/Contents/Resources/bin/cmux")
        }
        candidates.append("/Applications/cmux.app/Contents/Resources/bin/cmux")
        candidates.append(NSHomeDirectory() + "/Applications/cmux.app/Contents/Resources/bin/cmux")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Finds the cmux pane of `pid` (already known to descend from the cmux
    /// app at `bundlePath`). Exact or it fails.
    static func locateSurface(pid: Int32, sessionId: String?, agent: Agent, bundlePath: String?) -> Result<Target, Failure> {
        guard let cli = cliPath(forBundlePath: bundlePath) else {
            return .failure(Failure("Couldn't find cmux's command-line tool", output: "no cmux CLI for bundle \(bundlePath ?? "?")"))
        }
        let start = processStartSeconds(pid)
        let sessions = readHookSessions(agent: agent)
        if let sessionId, let sessions, let entry = sessions.entries[sessionId.lowercased()] {
            switch verify(entry, pid: pid, startSeconds: start, activeBySurface: sessions.activeBySurface) {
            case .match:
                return .success(Target(surfaceId: entry.surfaceId, workspaceId: entry.workspaceId, cliPath: cli, source: "hook-sessions"))
            case .surfaceTaken:
                return .failure(Failure("Another session is in front in that cmux pane — reply at the Mac",
                                        output: "surface \(entry.surfaceId) active session differs"))
            case .mismatch:
                break   // stale entry (pid reused / restarted): fall back to the process environment
            }
        }
        let env = environmentValues(ofPid: pid, keys: ["CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID"])
        if let surface = env["CMUX_SURFACE_ID"], ClaudeSessionRegistry.isValidSessionId(surface) {
            // Same rule as a hook-sessions entry: if cmux says another
            // session is in front in that surface (this one suspended, a
            // new one started), keys would reach that one.
            if surfaceTaken(surface: surface, by: sessionId, activeBySurface: sessions?.activeBySurface ?? [:]) {
                return .failure(Failure("Another session is in front in that cmux pane — reply at the Mac",
                                        output: "surface \(surface) (environment) active session differs"))
            }
            let ws = env["CMUX_WORKSPACE_ID"].flatMap { ClaudeSessionRegistry.isValidSessionId($0) ? $0 : nil }
            return .success(Target(surfaceId: surface, workspaceId: ws, cliPath: cli, source: "environment"))
        }
        return .failure(Failure(paneNotFoundDetail, output: "pid \(pid): no verified hook-sessions entry and no CMUX_SURFACE_ID"))
    }

    // MARK: hook-sessions file

    struct HookSession: Equatable {
        let sessionId: String
        let surfaceId: String
        let workspaceId: String?
        let pid: Int32?
        let pidStartSeconds: Int?
    }

    struct HookSessions: Equatable {
        /// Keyed by lowercased session id.
        var entries: [String: HookSession] = [:]
        /// surfaceId (uppercased) → session id currently in front there.
        var activeBySurface: [String: String] = [:]
    }

    /// Directory holding cmux's hook state. Tests point it elsewhere.
    static var stateDirectory: String = NSHomeDirectory() + "/.cmuxterm"

    /// Reads `<agent>-hook-sessions.json`. cmux rewrites it while hooks run,
    /// so a read that lands mid-write is retried once.
    static func readHookSessions(agent: Agent) -> HookSessions? {
        let url = URL(fileURLWithPath: stateDirectory).appendingPathComponent(agent.hookSessionsFileName)
        for attempt in 0..<2 {
            if let data = try? Data(contentsOf: url), data.count < 16 * 1024 * 1024,
               let parsed = parseHookSessions(data) {
                return parsed
            }
            if attempt == 0 { usleep(50_000) }
        }
        return nil
    }

    /// Undocumented cmux format; decoded defensively (every field optional).
    static func parseHookSessions(_ data: Data) -> HookSessions? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var out = HookSessions()
        if let sessions = root["sessions"] as? [String: Any] {
            for (key, value) in sessions {
                guard let e = value as? [String: Any] else { continue }
                let sid = (e["sessionId"] as? String) ?? key
                guard !sid.isEmpty,
                      let surface = e["surfaceId"] as? String, ClaudeSessionRegistry.isValidSessionId(surface) else { continue }
                let ws = (e["workspaceId"] as? String).flatMap { ClaudeSessionRegistry.isValidSessionId($0) ? $0 : nil }
                out.entries[sid.lowercased()] = HookSession(
                    sessionId: sid,
                    surfaceId: surface,
                    workspaceId: ws,
                    pid: intValue(e["pid"]).map { Int32(truncatingIfNeeded: $0) },
                    pidStartSeconds: intValue(e["pidStartSeconds"])
                )
            }
        }
        if let active = root["activeSessionsBySurface"] as? [String: Any] {
            for (surface, value) in active {
                if let v = value as? [String: Any], let sid = v["sessionId"] as? String {
                    out.activeBySurface[surface.uppercased()] = sid
                }
            }
        }
        return out
    }

    enum EntryCheck: Equatable { case match, mismatch, surfaceTaken }

    /// An entry counts only for the exact live process (pid + start time —
    /// pids get reused) and only while no other session is in front in its
    /// surface (e.g. one suspended with ^Z and another started).
    static func verify(_ e: HookSession, pid: Int32, startSeconds: Int?,
                       activeBySurface: [String: String]) -> EntryCheck {
        guard e.pid == pid, let recorded = e.pidStartSeconds, let actual = startSeconds,
              abs(recorded - actual) <= 1 else { return .mismatch }
        if let front = activeBySurface[e.surfaceId.uppercased()], front.lowercased() != e.sessionId.lowercased() {
            return .surfaceTaken
        }
        return .match
    }

    /// Pure. Whether cmux records a session other than `sessionId` in front
    /// of `surface`. Unknown (no record, or no session id to compare) is
    /// not "taken": the input-state gate still guards every key.
    static func surfaceTaken(surface: String, by sessionId: String?, activeBySurface: [String: String]) -> Bool {
        guard let sessionId, let front = activeBySurface[surface.uppercased()] else { return false }
        return front.lowercased() != sessionId.lowercased()
    }

    private static func intValue(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber, !(v is Bool) else { return nil }
        return n.intValue
    }

    // MARK: process introspection (no privileges, no subprocess)

    /// Process start time in epoch seconds (kinfo_proc.p_starttime).
    static func processStartSeconds(_ pid: Int32) -> Int? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return Int(info.kp_proc.p_starttime.tv_sec)
    }

    /// Selected environment variables of a same-user process. Only `keys`
    /// are kept; everything else (cmux's socket capability token, auth
    /// tokens, …) is dropped on the spot and never stored or logged.
    static func environmentValues(ofPid pid: Int32, keys: Set<String>) -> [String: String] {
        guard pid > 0 else { return [:] }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0, size < 4 * 1024 * 1024 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [:] }
        return parseProcArgsEnvironment(Array(buffer.prefix(size)), keys: keys)
    }

    /// KERN_PROCARGS2 layout: argc (Int32), exec path, NUL padding, argc
    /// argument strings, then the environment strings, each NUL-terminated.
    static func parseProcArgsEnvironment(_ bytes: [UInt8], keys: Set<String>) -> [String: String] {
        guard bytes.count > 4 else { return [:] }
        let argc = Int(Int32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
        guard argc >= 0, argc < 100_000 else { return [:] }
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }      // exec path
        while i < bytes.count, bytes[i] == 0 { i += 1 }      // padding
        var skipped = 0
        while i < bytes.count, skipped < argc {              // argv
            while i < bytes.count, bytes[i] != 0 { i += 1 }
            i += 1
            skipped += 1
        }
        guard skipped == argc else { return [:] }
        var out: [String: String] = [:]
        while i < bytes.count {
            var j = i
            while j < bytes.count, bytes[j] != 0 { j += 1 }
            if j == i { break }                              // end of environment
            if let eq = bytes[i..<j].firstIndex(of: UInt8(ascii: "=")) {
                let name = String(decoding: bytes[i..<eq], as: UTF8.self)
                if keys.contains(name) {
                    out[name] = String(decoding: bytes[(eq + 1)..<j], as: UTF8.self)
                }
            }
            i = j + 1
        }
        return out
    }

    // MARK: - socket access

    enum SocketMode: Equatable {
        case off, cmuxOnly, automation, password, allowAll
        case unknown(String)

        init(raw: String) {
            switch raw {
            case "off": self = .off
            case "cmuxOnly": self = .cmuxOnly
            case "automation": self = .automation
            case "password": self = .password
            case "allowAll": self = .allowAll
            default: self = .unknown(raw)
            }
        }

        /// Whether a process launched outside cmux (Page) can connect.
        var admitsExternalClients: Bool {
            switch self {
            case .automation, .password, .allowAll: return true
            case .off, .cmuxOnly, .unknown: return false
            }
        }

        /// Human name, as cmux's Settings shows it.
        var displayName: String {
            switch self {
            case .off: return "Off"
            case .cmuxOnly: return "cmux processes only"
            case .automation: return "Automation mode"
            case .password: return "Password mode"
            case .allowAll: return "Full open access"
            case .unknown(let raw): return raw.isEmpty ? "unknown" : raw
            }
        }
    }

    struct SocketStatus: Equatable {
        let effectiveMode: SocketMode
        let configuredMode: SocketMode?
        let socketPath: String?
        let socketPathState: String?
    }

    /// Parses `cmux socket-status --json`.
    static func parseSocketStatus(_ text: String) -> SocketStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let effective = obj["effective_mode"] as? String else { return nil }
        return SocketStatus(
            effectiveMode: SocketMode(raw: effective),
            configuredMode: (obj["configured_mode"] as? String).map(SocketMode.init(raw:)),
            socketPath: obj["socket_path"] as? String,
            socketPathState: obj["socket_path_state"] as? String
        )
    }

    private static let statusLock = NSLock()
    private static var statusCache: [String: (status: SocketStatus, at: Date)] = [:]
    private static let statusCacheTTL: TimeInterval = 10

    /// Socket mode, without connecting to the socket. Cached briefly: a
    /// burst of replies shouldn't spawn one CLI per keystroke.
    static func socketStatus(cliPath: String, runner: @escaping Runner = defaultRunner, useCache: Bool = true) -> SocketStatus? {
        if useCache {
            statusLock.lock()
            let cached = statusCache[cliPath]
            statusLock.unlock()
            if let cached, Date().timeIntervalSince(cached.at) < statusCacheTTL { return cached.status }
        }
        let r = runner(cliPath, ["socket-status", "--json"], nil, cliEnvironment(password: nil), 5)
        guard r.succeeded, let status = parseSocketStatus(r.stdout) else { return nil }
        statusLock.lock()
        statusCache[cliPath] = (status, Date())
        statusLock.unlock()
        return status
    }

    /// Forget cached modes (the setup window calls this after the user
    /// changes something).
    static func invalidateStatusCache() {
        statusLock.lock()
        statusCache.removeAll()
        statusLock.unlock()
    }

    /// Opens a client if cmux's socket mode lets Page in. Fails closed with
    /// a detail that sends the user to the setup window.
    /// `allowKeychainUI` only from the setup window (the user is there to
    /// answer a Keychain prompt); background delivery never prompts.
    ///
    /// The CLI path comes from the session's ancestor process, which any
    /// same-user program can fake (a planted "cmux.app" that reports
    /// password mode). So the Keychain password is only read, and only
    /// handed over, when `verifyCLI` confirms the CLI is cmux's own,
    /// signed by cmux's developer.
    static func connect(cliPath: String,
                        runner: @escaping Runner = defaultRunner,
                        secrets: SecretStore = KeychainSecretStore.cmuxSocketPassword,
                        allowKeychainUI: Bool = false,
                        verifyCLI: (String) -> Bool = CmuxBridge.isTrustedCLI) -> Result<Client, Failure> {
        guard let status = socketStatus(cliPath: cliPath, runner: runner) else {
            return .failure(Failure("Couldn't check whether cmux lets Page in", output: "socket-status failed"))
        }
        switch status.effectiveMode {
        case .automation, .allowAll:
            return .success(Client(cliPath: cliPath, password: nil, runner: runner))
        case .password:
            guard verifyCLI(cliPath) else {
                return .failure(Failure(unverifiedCLIDetail, output: "password mode, CLI signature not cmux's: \(cliPath)"))
            }
            switch secrets.read(allowUI: allowKeychainUI) {
            case .found(let pw):
                return .success(Client(cliPath: cliPath, password: pw, runner: runner))
            case .notFound, .interactionRequired:
                return .failure(Failure(needsPasswordDetail, output: "password mode, no readable Keychain item"))
            case .failed(let s):
                return .failure(Failure(needsPasswordDetail, output: "Keychain read failed: \(s)"))
            }
        case .off, .cmuxOnly, .unknown:
            return .failure(Failure(blockedDetail, output: "socket mode \(status.effectiveMode.displayName)"))
        }
    }

    // MARK: - CLI signature

    /// Team ID of cmux's developer (Manaflow, Inc.), as signed on every
    /// channel's app and bundled CLI.
    static let cmuxTeamIdentifier = "7WLXT3NR37"
    static let unverifiedCLIDetail = "Page couldn't verify this copy of cmux, so it won't send it your socket password — reinstall cmux from its official download"

    private static let trustLock = NSLock()
    private static var trustCache: [String: (key: String, trusted: Bool)] = [:]

    /// Whether the executable at `path` carries a valid code signature
    /// from cmux's developer (Apple-anchored Developer ID with cmux's Team
    /// ID; any channel — stable, NEXT, nightly). Cached per file identity
    /// (inode, size, mtime), so a swapped file is checked again.
    static func isTrustedCLI(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path) else { return false }
        let identity = "\((attrs[.systemFileNumber] as? NSNumber)?.int64Value ?? -1):\((attrs[.size] as? NSNumber)?.int64Value ?? -1):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1)"
        trustLock.lock()
        let cached = trustCache[resolved.path]
        trustLock.unlock()
        if let cached, cached.key == identity { return cached.trusted }

        let trusted = codeSignatureMatches(path: resolved.path, teamIdentifier: cmuxTeamIdentifier)
        trustLock.lock()
        trustCache[resolved.path] = (identity, trusted)
        trustLock.unlock()
        return trusted
    }

    /// Strict static signature check of the code at `path` against an
    /// Apple-anchored certificate whose leaf OU is `teamIdentifier`.
    static func codeSignatureMatches(path: String, teamIdentifier: String) -> Bool {
        guard teamIdentifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    // MARK: - CLI

    /// Runs the cmux CLI: (cliPath, args, stdin, environment, timeout).
    /// Injected so unit tests never reach a real cmux.
    typealias Runner = (_ cliPath: String, _ args: [String], _ stdin: Data?, _ environment: [String: String], _ timeout: TimeInterval) -> ProcessRunner.Result

    /// Commands that never connect to the socket.
    static let offlineCommands: Set<String> = ["socket-status", "--version", "version", "--help"]

    static let defaultRunner: Runner = { cli, args, stdin, env, timeout in
        // Belt and braces: a unit test must never reach the live cmux (the
        // developer's own shell may run inside it and be admitted).
        if NSClassFromString("XCTestCase") != nil, let verb = args.first, !offlineCommands.contains(verb) {
            return .notLaunched
        }
        return ProcessRunner.run(cli, args, timeout: timeout, environment: env, stdin: stdin)
    }

    /// Environment for every cmux CLI call: Page's augmented PATH with every
    /// inherited `CMUX_*` variable removed (a Page started from a cmux
    /// terminal would otherwise default to that terminal's surface and carry
    /// its capability token), plus the socket password when one is in use.
    static func cliEnvironment(password: String?) -> [String: String] {
        var env = ProcessRunner.augmentedEnvironment().filter { !$0.key.hasPrefix("CMUX_") }
        if let password, !password.isEmpty { env["CMUX_SOCKET_PASSWORD"] = password }
        return env
    }

    /// Phone-safe classification of a failed CLI run. `fallback` describes
    /// what was being attempted.
    static func classify(_ r: ProcessRunner.Result, fallback: String) -> Failure {
        let raw = (r.stderr + "\n" + r.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let output = "exit \(r.status)\(r.timedOut ? " (timed out)" : ""): \(raw.prefix(300))"
        if !r.launched { return Failure("Couldn't run cmux's command-line tool", output: "not launched") }
        if r.timedOut { return Failure("cmux didn't respond", output: output) }
        let lower = raw.lowercased()
        if lower.contains("access denied") || lower.contains("only processes started inside cmux")
            || lower.contains("broken pipe") {
            return Failure(blockedDetail, output: output)
        }
        if lower.contains("authentication required") || lower.contains("auth.login")
            || lower.contains("invalid password") || lower.contains("incorrect password")
            || lower.contains("authentication failed") {
            return Failure(passwordRejectedDetail, output: output)
        }
        if lower.contains("connection refused") || lower.contains("not running")
            || (lower.contains("no such file") && lower.contains("sock")) {
            return Failure(notRunningDetail, output: output)
        }
        return Failure(fallback, output: output)
    }

    /// `cmux rpc` prints the reply; accept both the full envelope
    /// (`{id, ok, result}`) and a bare result object.
    static func unwrapRPC(_ text: String) -> Result<[String: Any], Failure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return .failure(Failure("cmux sent an unexpected reply", output: "non-JSON rpc output: \(trimmed.prefix(200))"))
        }
        if let ok = obj["ok"] as? Bool {
            if !ok {
                let err = obj["error"] as? [String: Any]
                let message = (err?["message"] as? String) ?? (err?["code"] as? String) ?? "error"
                return .failure(Failure("cmux refused the request", output: "rpc error: \(message.prefix(200))"))
            }
            return .success((obj["result"] as? [String: Any]) ?? [:])
        }
        return .success(obj)
    }

    // MARK: input state

    enum InputState: String, Equatable {
        case empty, draft, dialog, unknown
    }

    static func parseInputState(_ obj: [String: Any]) -> InputState {
        guard let raw = obj["state"] as? String else { return .unknown }
        return InputState(rawValue: raw) ?? .unknown
    }

    /// Why typing a *message* into a prompt in `state` is refused, or nil
    /// when it's safe (the input box is visible and empty).
    static func refusalForTyping(_ state: InputState) -> String? {
        switch state {
        case .empty: return nil
        case .draft: return draftDetail
        case .dialog: return dialogOpenDetail
        case .unknown: return noInputBoxDetail
        }
    }

    // MARK: feed

    struct FeedItem: Equatable {
        let requestId: String
        /// "permissionRequest" | "exitPlan" | "question" | informational kinds.
        let kind: String
        let status: String
        let source: String?
        let sessionId: String?
        let createdAt: Date?
    }

    static let actionableFeedKinds: Set<String> = ["permissionRequest", "exitPlan", "question"]

    static func parseFeedItems(_ obj: [String: Any]) -> [FeedItem] {
        guard let items = obj["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { raw in
            guard let requestId = raw["request_id"] as? String, !requestId.isEmpty,
                  let kind = raw["kind"] as? String,
                  let status = raw["status"] as? String else { return nil }
            let decoded = (raw["workstream_id"] as? String).flatMap(decodeWorkstreamId)
            let direct = (raw["session_id"] as? String) ?? (raw["sessionId"] as? String)
            return FeedItem(
                requestId: requestId,
                kind: kind,
                status: status,
                source: (raw["source"] as? String) ?? decoded?.source,
                sessionId: direct ?? decoded?.sessionId,
                createdAt: dateValue(raw["created_at"] ?? raw["createdAt"] ?? raw["timestamp"])
            )
        }
    }

    /// cmux names a Feed workstream "cmux-feed-v1:<base64 source>:<base64
    /// session id>" (observed on cmux 0.65; undocumented).
    static func decodeWorkstreamId(_ id: String) -> (source: String, sessionId: String)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "cmux-feed-v1",
              let source = base64Decode(parts[1]), let session = base64Decode(parts[2]),
              !source.isEmpty, !session.isEmpty else { return nil }
        return (source, session)
    }

    private static func base64Decode(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let data = Data(base64Encoded: t) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func dateValue(_ v: Any?) -> Date? {
        if let n = v as? NSNumber, !(v is Bool) {
            let d = n.doubleValue
            return Date(timeIntervalSince1970: d > 1e11 ? d / 1000 : d)   // ms or s
        }
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// What to do with a Claude reply given cmux's pending Feed items.
    enum FeedDecision: Equatable {
        /// Nothing held in Feed for this session: use the screen.
        case none
        /// `feed.permission.reply`; then type `thenType` (deny + message).
        case permission(requestId: String, mode: String, thenType: String?)
        /// `feed.exit_plan.reply` (its deny carries the text as feedback).
        case exitPlan(requestId: String, mode: String, feedback: String?)
        case refuse(String)
    }

    static let feedAmbiguousDetail = "Several prompts are waiting in cmux — answer at the Mac"
    static let feedUnmatchedDetail = "Couldn't match this page to the prompt cmux is holding — answer at the Mac, or try again in two minutes"
    static let feedQuestionDetail = "cmux is holding this question — answer it at the Mac, or reply again in two minutes"

    /// Pure. Picks the single pending Feed request for `sessionId` and maps
    /// the phone's action onto it. Never chooses "always", "all" or
    /// "bypass" — the phone's Approve means this once. A request newer than
    /// the page (`pageStart` + 5 s) is a different prompt than the one the
    /// user saw, so it's refused rather than answered.
    static func claudeFeedDecision(items: [FeedItem], sessionId: String, action rawAction: String?,
                                   text: String, pageStart: Date?) -> FeedDecision {
        let sid = sessionId.lowercased()
        let held = items.filter {
            $0.status == "pending" && actionableFeedKinds.contains($0.kind)
                && ($0.source == nil || $0.source == "claude")
                && $0.sessionId?.lowercased() == sid
        }
        guard !held.isEmpty else { return .none }
        guard held.count == 1, let item = held.first else { return .refuse(feedAmbiguousDetail) }

        let clean = InjectionExecutor.sanitize(text)
        let action: String
        switch rawAction {
        case "approve", "deny", "carry_on", "custom": action = rawAction!
        // No action and no text (an old phone's banner tap) asks for nothing.
        case nil, "": action = "custom"
        default: action = "custom"
        }
        if action == "custom" && clean.isEmpty { return .refuse(InjectionExecutor.emptyReplyMessage) }

        if item.kind == "question" {
            if action == "approve" { return .refuse("This is a question — reply with your answer instead") }
            return .refuse(feedQuestionDetail)
        }
        guard let pageStart, let created = item.createdAt else { return .refuse(feedUnmatchedDetail) }
        if created.timeIntervalSince(pageStart) > 5 { return .refuse(InjectionExecutor.staleMessage) }

        switch (item.kind, action) {
        case ("permissionRequest", "approve"): return .permission(requestId: item.requestId, mode: "once", thenType: nil)
        case ("permissionRequest", "deny"): return .permission(requestId: item.requestId, mode: "deny", thenType: nil)
        case ("permissionRequest", "custom"): return .permission(requestId: item.requestId, mode: "deny", thenType: clean)
        case ("exitPlan", "approve"): return .exitPlan(requestId: item.requestId, mode: "manual", feedback: nil)
        case ("exitPlan", "deny"): return .exitPlan(requestId: item.requestId, mode: "deny", feedback: nil)
        case ("exitPlan", "custom"): return .exitPlan(requestId: item.requestId, mode: "deny", feedback: clean)
        default: return .refuse("This page needs approve, deny or a written reply")
        }
    }

    // MARK: - client

    /// One authorised conversation with cmux's CLI. Cheap; create per reply.
    final class Client {
        let cliPath: String
        private let password: String?
        private let runner: Runner

        init(cliPath: String, password: String?, runner: @escaping Runner) {
            self.cliPath = cliPath
            self.password = password
            self.runner = runner
        }

        /// Runs one command; retries once if cmux reports it's overloaded.
        func run(_ args: [String], stdin: Data? = nil, timeout: TimeInterval = 8, fallback: String) -> Result<String, Failure> {
            let env = CmuxBridge.cliEnvironment(password: password)
            var r = runner(cliPath, args, stdin, env, timeout)
            if !r.succeeded, let delay = CmuxBridge.overloadRetryDelay(r) {
                usleep(useconds_t(delay * 1_000_000))
                r = runner(cliPath, args, stdin, env, timeout)
            }
            return r.succeeded ? .success(r.stdout) : .failure(CmuxBridge.classify(r, fallback: fallback))
        }

        /// Raw v2 call; params go on stdin (`-`) to stay out of argv.
        func rpc(_ method: String, _ params: [String: Any], fallback: String) -> Result<[String: Any], Failure> {
            guard let body = try? JSONSerialization.data(withJSONObject: params) else {
                return .failure(Failure(fallback, output: "unencodable params"))
            }
            return run(["rpc", method, "-"], stdin: body, fallback: fallback).flatMap(CmuxBridge.unwrapRPC)
        }

        func ping() -> Result<String, Failure> {
            run(["ping"], timeout: 5, fallback: "cmux didn't answer")
        }

        /// A read-only call cmux only answers for an admitted client (in
        /// Password mode `ping` is answered before login, so it proves
        /// nothing about access).
        func verifyAccess() -> Result<String, Failure> {
            run(["list-workspaces"], timeout: 5, fallback: "cmux didn't answer")
        }

        func inputState(surface: String) -> Result<InputState, Failure> {
            guard ClaudeSessionRegistry.isValidSessionId(surface) else { return .failure(Failure(paneNotFoundDetail)) }
            return rpc("surface.input_state", ["surface_id": surface],
                       fallback: "Couldn't read that cmux pane — update cmux, or reply at the Mac")
                .map(CmuxBridge.parseInputState)
        }

        func pendingFeedItems() -> Result<[FeedItem], Failure> {
            rpc("feed.list", ["pending_only": true], fallback: "Couldn't read cmux's Feed")
                .map(CmuxBridge.parseFeedItems)
        }

        func replyPermission(requestId: String, mode: String) -> Result<Void, Failure> {
            rpc("feed.permission.reply", ["request_id": requestId, "mode": mode],
                fallback: InjectionExecutor.promptGoneMessage).map { _ in () }
        }

        func replyExitPlan(requestId: String, mode: String, feedback: String?) -> Result<Void, Failure> {
            var params: [String: Any] = ["request_id": requestId, "mode": mode]
            if let feedback, !feedback.isEmpty { params["feedback"] = feedback }
            return rpc("feed.exit_plan.reply", params, fallback: InjectionExecutor.promptGoneMessage).map { _ in () }
        }

        /// One named key ("escape", "enter"). `force` only after Page itself
        /// saw the dialog it is answering — cmux refuses keys into a dialog
        /// otherwise, which is the guard we want everywhere else.
        func sendKey(surface: String, key: String, force: Bool) -> Result<Void, Failure> {
            guard ClaudeSessionRegistry.isValidSessionId(surface) else { return .failure(Failure(paneNotFoundDetail)) }
            var args = ["send-key", "--surface", surface]
            if force { args.append("--force") }
            args += ["--", key]
            return run(args, fallback: "Couldn't press \(key) in that cmux pane").map { _ in () }
        }

        /// A single menu digit into an open dialog. `cmux send` interprets
        /// \n / \r / \t escapes, so it's only ever used for one digit —
        /// replies go through `paste`, which doesn't.
        func sendDialogDigit(surface: String, digit: Character) -> Result<Void, Failure> {
            guard ClaudeSessionRegistry.isValidSessionId(surface), digit.isNumber, digit.isASCII else {
                return .failure(Failure(paneNotFoundDetail))
            }
            return run(["send", "--surface", surface, "--force", "--", String(digit)],
                       fallback: "Couldn't answer the prompt in that cmux pane").map { _ in () }
        }

        /// Pastes `text` (stdin, not argv) and presses the agent's submit
        /// key. Never `--force`: cmux re-checks for a draft or dialog at the
        /// moment of typing, closing the gap after Page's own check.
        func pasteAndSubmit(surface: String, text: String) -> Result<Void, Failure> {
            guard ClaudeSessionRegistry.isValidSessionId(surface) else { return .failure(Failure(paneNotFoundDetail)) }
            return run(["paste", "--surface", surface, "--submit", "-"], stdin: Data(text.utf8),
                       fallback: "Couldn't type into that cmux pane").map { _ in () }
        }

        /// Polls the input row until it leaves `dialog` (a dismissed menu
        /// takes a redraw to disappear), up to `timeout`.
        func waitForInputState(surface: String, notEqualTo unwanted: InputState, timeout: TimeInterval) -> Result<InputState, Failure> {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                switch inputState(surface: surface) {
                case .failure(let f): return .failure(f)
                case .success(let s):
                    if s != unwanted || Date() >= deadline { return .success(s) }
                }
                usleep(150_000)
            }
        }

        /// Polls Feed until `requestId` is no longer pending (proof the hook
        /// got the decision), up to `timeout`.
        func waitForFeedResolution(requestId: String, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                if case .success(let items) = pendingFeedItems(),
                   !items.contains(where: { $0.requestId == requestId && $0.status == "pending" }) {
                    return true
                }
                usleep(200_000)
            } while Date() < deadline
            return false
        }
    }

    /// cmux's admission control answers `overloaded` with `retry_after_ms`.
    static func overloadRetryDelay(_ r: ProcessRunner.Result) -> TimeInterval? {
        let text = r.stderr + r.stdout
        guard text.lowercased().contains("overloaded") else { return nil }
        if let range = text.range(of: #"retry_after_ms"?\s*[:=]\s*(\d+)"#, options: .regularExpression) {
            let digits = text[range].filter(\.isNumber)
            if let ms = Double(digits) { return min(max(ms / 1000, 0.05), 2) }
        }
        return 0.25
    }
}
