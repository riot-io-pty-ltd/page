import Foundation

/// WezTerm and kitty: terminals with a real control API, so Page can type
/// into one exact pane and read its screen, like tmux. Both are found the
/// same way: the agent process's own environment names its pane/window
/// (`WEZTERM_PANE`, `KITTY_WINDOW_ID`), and the terminal's own listing must
/// agree before anything is typed (WezTerm: the pane's tty is the
/// session's; kitty: the window's shell is an ancestor of the session).
/// Exact or nothing, as everywhere else.

// MARK: - WezTerm

enum WezTermBridge {
    struct Target: Equatable {
        let cliPath: String
        let paneId: String
        /// `WEZTERM_UNIX_SOCKET` from the session's environment, when set,
        /// so the CLI talks to the GUI that owns the pane.
        let socket: String?

        var label: String { "WezTerm pane \(paneId)" }
    }

    struct Pane: Equatable {
        let paneId: String
        let tty: String?
    }

    static func cliPath(forBundlePath bundle: String?) -> String? {
        var candidates: [String] = []
        if let bundle { candidates.append(bundle + "/Contents/MacOS/wezterm") }
        candidates += ["/Applications/WezTerm.app/Contents/MacOS/wezterm",
                       NSHomeDirectory() + "/Applications/WezTerm.app/Contents/MacOS/wezterm"]
        if let onPath = ProcessRunner.findExecutable("wezterm") { candidates.append(onPath) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Pure. `wezterm cli list --format json` → panes.
    static func parseList(_ json: String) -> [Pane] {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = (row["pane_id"] as? NSNumber)?.stringValue ?? row["pane_id"] as? String else { return nil }
            return Pane(paneId: id, tty: row["tty_name"] as? String)
        }
    }

    /// Pure. The session's pane: the one its environment names, and only if
    /// WezTerm reports the session's own tty for it. Without the variable,
    /// the single pane on that tty.
    static func pane(for tty: String, envPane: String?, in panes: [Pane]) -> Pane? {
        let onTTY = panes.filter { $0.tty == tty }
        if let envPane { return onTTY.first { $0.paneId == envPane } }
        return onTTY.count == 1 ? onTTY[0] : nil
    }

    static func environment(socket: String?) -> [String: String]? {
        guard let socket else { return nil }
        var env = ProcessInfo.processInfo.environment
        env["WEZTERM_UNIX_SOCKET"] = socket
        return env
    }

    static func locate(tty: String, pid: Int32, bundlePath: String?) -> Result<Target, CmuxBridge.Failure> {
        guard let cli = cliPath(forBundlePath: bundlePath) else {
            return .failure(.init("Couldn't find WezTerm's command-line tool", output: "no wezterm CLI"))
        }
        let env = ProcArgs.read(pid: pid, envKeys: ["WEZTERM_PANE", "WEZTERM_UNIX_SOCKET"])?.env ?? [:]
        let socket = env["WEZTERM_UNIX_SOCKET"]
        let r = ProcessRunner.run(cli, ["cli", "list", "--format", "json"], timeout: 3, environment: environment(socket: socket))
        guard r.succeeded else {
            return .failure(.init("Couldn't reach WezTerm", output: "wezterm cli list: \(r.stderr.prefix(200))"))
        }
        guard let pane = pane(for: tty, envPane: env["WEZTERM_PANE"], in: parseList(r.stdout)) else {
            return .failure(.init("Couldn't find the session's WezTerm pane", output: "no pane for \(tty)"))
        }
        return .success(Target(cliPath: cli, paneId: pane.paneId, socket: socket))
    }

    /// One CLI call. `stdin` carries text so nothing in it is read as flags.
    static func run(_ target: Target, _ args: [String], stdin: Data? = nil) -> ProcessRunner.Result {
        ProcessRunner.run(target.cliPath, ["cli"] + args, timeout: 3,
                          environment: environment(socket: target.socket), stdin: stdin)
    }

    /// Pure. The CLI arguments for one keystroke (text comes on stdin).
    /// Single-line text and keys are sent as typed (`--no-paste`) so "1"
    /// picks a menu option; multi-line text is one bracketed paste so its
    /// newlines don't submit.
    static func sendArgs(paneId: String, key: Keystroke) -> (args: [String], stdin: Data)? {
        let base = ["send-text", "--pane-id", paneId]
        switch key {
        case .text(let s) where s.contains("\n"): return (base, Data(s.utf8))
        case .text(let s): return (base + ["--no-paste"], Data(s.utf8))
        case .enter: return (base + ["--no-paste"], Data("\r".utf8))
        case .escape: return (base + ["--no-paste"], Data("\u{1B}".utf8))
        case .pause, .awaitPromptClosed: return nil
        }
    }

    static func screen(_ target: Target, styled: Bool) -> String? {
        let r = run(target, ["get-text", "--pane-id", target.paneId] + (styled ? ["--escapes"] : []))
        return r.succeeded ? r.stdout : nil
    }
}

// MARK: - kitty

enum KittyBridge {
    struct Target: Equatable {
        let kittenPath: String
        /// `KITTY_LISTEN_ON`, e.g. "unix:/tmp/kitty-1234".
        let socket: String
        let windowId: String

        var label: String { "kitty window \(windowId)" }
    }

    struct Window: Equatable {
        let id: String
        let pid: Int32?
        let foregroundPids: [Int32]
    }

    static let remoteControlHint = "Turn on kitty remote control: add “allow_remote_control socket-only” and “listen_on unix:/tmp/kitty-{kitty_pid}” to kitty.conf, then restart kitty"

    static func kittenPath(forBundlePath bundle: String?) -> String? {
        var candidates: [String] = []
        if let bundle { candidates.append(bundle + "/Contents/MacOS/kitten") }
        candidates += ["/Applications/kitty.app/Contents/MacOS/kitten",
                       NSHomeDirectory() + "/Applications/kitty.app/Contents/MacOS/kitten"]
        if let onPath = ProcessRunner.findExecutable("kitten") { candidates.append(onPath) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Pure. Only local unix sockets are accepted (a tcp listen address
    /// would let Page type across the network).
    static func isLocalSocket(_ s: String) -> Bool {
        s.hasPrefix("unix:") && s.count > 5
    }

    /// Pure. `kitten @ ls` → every window, across OS windows and tabs.
    static func parseLs(_ json: String) -> [Window] {
        guard let data = json.data(using: .utf8),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var out: [Window] = []
        for os in osWindows {
            for tab in os["tabs"] as? [[String: Any]] ?? [] {
                for w in tab["windows"] as? [[String: Any]] ?? [] {
                    guard let id = (w["id"] as? NSNumber)?.stringValue else { continue }
                    let fg = (w["foreground_processes"] as? [[String: Any]] ?? []).compactMap { ($0["pid"] as? NSNumber)?.int32Value }
                    out.append(Window(id: id, pid: (w["pid"] as? NSNumber)?.int32Value, foregroundPids: fg))
                }
            }
        }
        return out
    }

    /// Pure. The window the session's environment names, and only if kitty
    /// says the session runs in it: the session is one of its foreground
    /// processes, or its shell is one of the session's ancestors.
    static func window(id: String, sessionPid: Int32, ancestors: Set<Int32>, in windows: [Window]) -> Window? {
        guard let w = windows.first(where: { $0.id == id }) else { return nil }
        if w.foregroundPids.contains(sessionPid) { return w }
        if let pid = w.pid, ancestors.contains(pid) { return w }
        return nil
    }

    static func ancestors(of pid: Int32, processTable: [ProcessRunner.ProcessInfoRow]) -> Set<Int32> {
        var byPid: [Int32: Int32] = [:]
        for row in processTable { byPid[row.pid] = row.ppid }
        var out = Set<Int32>()
        var current = byPid[pid]
        var hops = 0
        while let p = current, p > 1, hops < 32 {
            out.insert(p)
            current = byPid[p]
            hops += 1
        }
        return out
    }

    static func locate(pid: Int32, bundlePath: String?, processTable: [ProcessRunner.ProcessInfoRow]) -> Result<Target, CmuxBridge.Failure> {
        guard let kitten = kittenPath(forBundlePath: bundlePath) else {
            return .failure(.init("Couldn't find kitty's kitten tool", output: "no kitten"))
        }
        let env = ProcArgs.read(pid: pid, envKeys: ["KITTY_WINDOW_ID", "KITTY_LISTEN_ON"])?.env ?? [:]
        guard let socket = env["KITTY_LISTEN_ON"], isLocalSocket(socket) else {
            return .failure(.init(remoteControlHint, output: "no KITTY_LISTEN_ON (\(env["KITTY_LISTEN_ON"] ?? "unset"))"))
        }
        guard let windowId = env["KITTY_WINDOW_ID"] else {
            return .failure(.init("Couldn't find the session's kitty window", output: "no KITTY_WINDOW_ID"))
        }
        let r = ProcessRunner.run(kitten, ["@", "--to", socket, "ls"], timeout: 3)
        guard r.succeeded else {
            return .failure(.init(remoteControlHint, output: "kitten @ ls: \(r.stderr.prefix(200))"))
        }
        guard window(id: windowId, sessionPid: pid, ancestors: ancestors(of: pid, processTable: processTable),
                     in: parseLs(r.stdout)) != nil else {
            return .failure(.init("Couldn't confirm the session's kitty window", output: "window \(windowId) doesn't own pid \(pid)"))
        }
        return .success(Target(kittenPath: kitten, socket: socket, windowId: windowId))
    }

    /// Pure. The kitten arguments for one keystroke (text comes on stdin,
    /// taken literally). Single-line text is typed so "1" picks a menu
    /// option; multi-line text is one bracketed paste.
    static func sendArgs(target: Target, key: Keystroke) -> (args: [String], stdin: Data?)? {
        let base = ["@", "--to", target.socket]
        let match = ["--match", "id:\(target.windowId)"]
        switch key {
        case .text(let s) where s.contains("\n"):
            return (base + ["send-text"] + match + ["--bracketed-paste", "enable", "--stdin"], Data(s.utf8))
        case .text(let s):
            return (base + ["send-text"] + match + ["--bracketed-paste", "disable", "--stdin"], Data(s.utf8))
        case .enter: return (base + ["send-key"] + match + ["enter"], nil)
        case .escape: return (base + ["send-key"] + match + ["escape"], nil)
        case .pause, .awaitPromptClosed: return nil
        }
    }

    static func run(_ target: Target, _ args: [String], stdin: Data? = nil) -> ProcessRunner.Result {
        ProcessRunner.run(target.kittenPath, args, timeout: 3, stdin: stdin)
    }

    static func screen(_ target: Target, styled: Bool) -> String? {
        let r = run(target, ["@", "--to", target.socket, "get-text", "--match", "id:\(target.windowId)", "--extent", "screen"]
                    + (styled ? ["--ansi"] : []))
        return r.succeeded ? r.stdout : nil
    }
}
