import Foundation

/// The one place the app spawns helper processes (pgrep, ps, lsof, tmux,
/// claude, codex, pmset, launchctl, ...).
///
/// Every previous call site had its own copy of "Process + Pipe +
/// waitUntilExit", and several read stdout only *after* waitUntilExit — which
/// deadlocks as soon as the child writes more than the ~64 KB pipe buffer
/// (pgrep -fl on a busy Mac is already ~45 KB). None had a timeout, so a hung
/// `claude --print` or `lsof` on a stalled network mount would wedge the tick
/// queue forever.
///
/// `run` drains stdout and stderr concurrently on background threads and
/// enforces a hard deadline (SIGTERM, then SIGKILL after a grace period).
enum ProcessRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        /// False when the executable couldn't be launched at all.
        let launched: Bool

        var succeeded: Bool { launched && !timedOut && status == 0 }

        static let notLaunched = Result(status: -1, stdout: "", stderr: "", timedOut: false, launched: false)
    }

    /// Runs `path` with `args` and returns once it exits or `timeout` elapses.
    /// Safe to call from any thread except the main thread for long timeouts
    /// (it blocks the caller).
    @discardableResult
    static func run(
        _ path: String,
        _ args: [String] = [],
        timeout: TimeInterval = 10,
        environment: [String: String]? = nil,
        currentDirectory: String? = nil,
        stdin: Data? = nil
    ) -> Result {
        guard FileManager.default.isExecutableFile(atPath: path) else { return .notLaunched }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        if let environment { proc.environment = environment }
        if let currentDirectory { proc.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        if let inPipe { proc.standardInput = inPipe } else { proc.standardInput = FileHandle.nullDevice }

        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }

        do {
            try proc.run()
        } catch {
            return .notLaunched
        }

        // Drain both pipes concurrently so a chatty child can never block on
        // a full pipe while we wait for it.
        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = d; lock.unlock()
            drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = d; lock.unlock()
            drained.leave()
        }

        if let inPipe, let stdin {
            // Writing to a child that already exited raises SIGPIPE; the app
            // ignores SIGPIPE globally (see main.swift), and the pipe is also
            // marked no-SIGPIPE (tests don't run main.swift), so this just fails.
            _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            try? inPipe.fileHandleForWriting.close()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            proc.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        // Grandchildren can keep the pipes open after the child dies; don't
        // wait on them forever.
        _ = drained.wait(timeout: .now() + 2)
        lock.lock()
        defer { lock.unlock() }

        return Result(
            status: proc.isRunning ? -1 : proc.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut,
            launched: true
        )
    }

    /// Convenience: stdout of a successful (exit 0) run, else nil.
    static func stdout(_ path: String, _ args: [String] = [], timeout: TimeInterval = 10) -> String? {
        let r = run(path, args, timeout: timeout)
        return r.succeeded ? r.stdout : nil
    }

    // MARK: executable discovery

    /// Directories GUI apps / LaunchAgents don't have on PATH but where
    /// developer CLIs commonly live. Order matters: native installers
    /// (~/.local/bin, the Claude Code default) beat Homebrew beat npm-global.
    static var developerBinDirectories: [String] {
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "/usr/bin",
            "/bin",
        ]
        // nvm doesn't create `current` by default; add every installed
        // version's bin, newest first.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                dirs.append("\(nvm)/\(v)/bin")
            }
        }
        return dirs
    }

    /// Resolves a CLI by name. `configured` (a user-supplied absolute path)
    /// wins when it exists and is executable.
    static func findExecutable(_ name: String, configured: String? = nil) -> String? {
        let fm = FileManager.default
        if let configured, !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) { return expanded }
        }
        for dir in developerBinDirectories {
            let candidate = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// PATH value for spawning developer CLIs (node-based CLIs need `node`
    /// on PATH even when launched by absolute path).
    static func augmentedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = (developerBinDirectories + existing)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
        return env
    }

    // MARK: quoting

    /// Single-quotes `s` for safe interpolation into a POSIX shell command.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes `s` for use inside an AppleScript double-quoted string literal.
    static func appleScriptQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    // MARK: process table

    struct ProcessInfoRow {
        let pid: Int32
        let ppid: Int32
        let tty: String      // "ttys003" or "??"
        let command: String
    }

    /// One `ps` snapshot of every process. Callers should take one snapshot
    /// per operation and query it, instead of spawning ps per pid.
    static func processTable() -> [ProcessInfoRow] {
        guard let out = stdout("/bin/ps", ["-axww", "-o", "pid=,ppid=,tty=,command="], timeout: 5) else { return [] }
        var rows: [ProcessInfoRow] = []
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard cols.count >= 3, let pid = Int32(cols[0]), let ppid = Int32(cols[1]) else { continue }
            rows.append(ProcessInfoRow(
                pid: pid,
                ppid: ppid,
                tty: String(cols[2]),
                command: cols.count > 3 ? String(cols[3]) : ""
            ))
        }
        return rows
    }

    /// True if `pid` refers to a live process (owned by anyone).
    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: job control

    /// Where a process stands on its controlling terminal.
    enum ForegroundState: Equatable {
        /// Running, and its process group is the terminal's foreground
        /// group: keystrokes typed into the terminal reach it.
        case foreground
        /// Running, but another process group (a shell after ^Z / `&`, an
        /// editor it spawned, another agent) owns the terminal's input.
        case background
        /// Stopped (^Z / SIGSTOP) or exited: the terminal's input goes to
        /// whatever took over (usually the shell).
        case stopped
        /// No such process, no controlling terminal, or the kernel didn't say.
        case unknown
    }

    /// Pure classification of kinfo_proc fields (unit-tested).
    /// `stat` is `p_stat` (SSTOP = 4, SZOMB = 5); `hasTTY` is false when
    /// `e_tdev` is NODEV.
    static func foregroundState(stat: Int32, pgid: Int32, tpgid: Int32, hasTTY: Bool) -> ForegroundState {
        if stat == 4 || stat == 5 { return .stopped }
        guard hasTTY, pgid > 0, tpgid > 0 else { return .unknown }
        return pgid == tpgid ? .foreground : .background
    }

    /// Fresh (one sysctl, no subprocess) job-control state of `pid`.
    static func foregroundState(pid: Int32) -> ForegroundState {
        guard pid > 0 else { return .unknown }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return .unknown }
        return foregroundState(stat: Int32(info.kp_proc.p_stat),
                               pgid: info.kp_eproc.e_pgid,
                               tpgid: info.kp_eproc.e_tpgid,
                               hasTTY: info.kp_eproc.e_tdev != -1)
    }

    /// Whether keystrokes typed into `pid`'s terminal would reach `pid`:
    /// true when it is running and its process group is the terminal's
    /// foreground group; false when it is stopped (^Z), exited, or behind
    /// another job (the shell, an editor, a second agent) — typing then
    /// goes to that job instead; nil when it can't be told (no such
    /// process, no controlling terminal). Callers that type must treat
    /// anything but `true` as "don't type". Cheap: one sysctl, so call it
    /// right before each keystroke.
    static func isForeground(pid: Int32) -> Bool? {
        switch foregroundState(pid: pid) {
        case .foreground: return true
        case .background, .stopped: return false
        case .unknown: return nil
        }
    }

    // MARK: tmux

    /// The tmux argument lists (one `tmux` run each, in order) that type
    /// `text` literally into pane `target`.
    ///
    /// tmux parses its own argv: an argument ending in ";" is a command
    /// separator, so `send-keys -l -- "return;"` types "return" — and how
    /// backslashes before that ";" are unescaped differs between tmux
    /// versions (3.6a turns `a\\;` into `a;`). So trailing semicolons are
    /// never passed as text: the rest goes through `send-keys -l --` (it
    /// can't end in ";" any more, and no other position is parsed) and
    /// each ";" is sent as the raw byte with `send-keys -H 3b`.
    static func tmuxLiteralSendKeys(target: String, text: String) -> [[String]] {
        var body = Substring(text)
        var semicolons = 0
        while body.hasSuffix(";") { body = body.dropLast(); semicolons += 1 }
        var runs: [[String]] = []
        if !body.isEmpty { runs.append(["send-keys", "-t", target, "-l", "--", String(body)]) }
        if semicolons > 0 { runs.append(["send-keys", "-t", target, "-H"] + Array(repeating: "3b", count: semicolons)) }
        return runs
    }
}
