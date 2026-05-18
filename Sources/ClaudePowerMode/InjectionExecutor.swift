import Foundation

/// Delivers a user's reply back to the right Claude Code session.
/// Method picked at runtime, in order of preference:
///   1. tmux send-keys (if the session is hosted in a tmux pane)
///   2. AppleScript keystroke into Terminal.app (matches by TTY)
///   3. Headless `claude --resume <uuid> --print "<text>"` (always works,
///      but the reply runs in a hidden background invocation rather than
///      typing into the live terminal — output goes to a log file)
enum InjectionMethod: String {
    case tmux
    case terminalAppleScript = "terminal_applescript"
    case headlessResume = "claude_resume_print"
    case codexExecResume = "codex_exec_resume"
}

struct InjectionResult {
    let method: InjectionMethod
    let success: Bool
    let output: String
}

enum InjectionExecutor {
    /// Attempt to deliver `text` to the session identified by `sessionId` in
    /// `cwd`. Synchronous; returns when the injection has completed.
    static func inject(text: String, sessionId: String, cwd: String, action: String? = nil) -> InjectionResult {
        Logger.shared.log("Injection.start session=\(sessionId.prefix(8)) cwd=\(cwd)")
        if let tmuxTarget = locateTmuxTarget(sessionId: sessionId) {
            Logger.shared.log("Injection.path=tmux target=\(tmuxTarget)")
            return injectViaTmux(target: tmuxTarget, text: text)
        }
        Logger.shared.log("Injection.no-tmux — checking TTY")
        if let tty = findClaudeTTY(sessionId: sessionId) {
            Logger.shared.log("Injection.tty=\(tty) — checking host app")
            let host = hostingApp(forTTY: tty)
            Logger.shared.log("Injection.host=\(host ?? "unknown")")
            if host == "Terminal" {
                Logger.shared.log("Injection.path=applescript — calling osascript")
                let result = injectViaAppleScriptTerminal(text: text, tty: tty)
                Logger.shared.log("Injection.applescript returned success=\(result.success) output=\(result.output.prefix(120))")
                if result.success { return result }
            }
        } else {
            Logger.shared.log("Injection.no-tty-found")
        }
        Logger.shared.log("Injection.path=headless — running claude --resume --print")
        return injectViaHeadlessResume(sessionId: sessionId, cwd: cwd, text: text)
    }

    // MARK: tmux

    /// Walks process trees looking for a `claude --resume <sessionId>` (or fresh
    /// `claude` in a directory we know hosts that session) whose ancestor is a
    /// `tmux` server. Returns the tmux target as "session:window".
    private static func locateTmuxTarget(sessionId: String) -> String? {
        // Cheap detection: list tmux panes with their PIDs and current commands.
        let panes = runReadingStdout(
            "/usr/local/bin/tmux",
            args: ["list-panes", "-a", "-F", "#{session_name}:#{window_index} #{pane_pid} #{pane_current_command}"]
        ) ?? runReadingStdout(
            "/opt/homebrew/bin/tmux",
            args: ["list-panes", "-a", "-F", "#{session_name}:#{window_index} #{pane_pid} #{pane_current_command}"]
        ) ?? ""
        if panes.isEmpty { return nil }

        for line in panes.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            let target = String(parts[0])
            let pid = String(parts[1])
            // Check if this pane's PID tree contains a claude session matching sessionId
            if processTreeMentions(rootPid: pid, sessionFragment: sessionId) {
                return target
            }
        }
        return nil
    }

    /// True if any descendant of rootPid has a command containing sessionId,
    /// or is a `claude` process at all (then we assume it's the one we want).
    private static func processTreeMentions(rootPid: String, sessionFragment: String) -> Bool {
        guard let ps = runReadingStdout("/bin/ps", args: ["-axo", "pid,ppid,command"]) else { return false }
        var children: [String: [String]] = [:]   // ppid -> [child pid]
        var commands: [String: String] = [:]
        for line in ps.split(separator: "\n").dropFirst() {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            let cols = cleaned.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count == 3 else { continue }
            let pid = String(cols[0])
            let ppid = String(cols[1])
            let cmd = String(cols[2])
            commands[pid] = cmd
            children[ppid, default: []].append(pid)
        }

        var stack = [rootPid]
        let prefix8 = String(sessionFragment.prefix(8))
        while let pid = stack.popLast() {
            if let cmd = commands[pid] {
                if cmd.contains(sessionFragment) || cmd.contains(prefix8) { return true }
                if cmd.contains("claude") && !cmd.contains("ClaudePowerMode") { return true }
            }
            stack.append(contentsOf: children[pid] ?? [])
        }
        return false
    }

    private static func injectViaTmux(target: String, text: String) -> InjectionResult {
        // tmux send-keys -t target "<text>" Enter
        // Note: tmux expects shell-quoted text; using -l (literal) plus separate Enter avoids escaping pain.
        let tmuxBin = ["/usr/local/bin/tmux", "/opt/homebrew/bin/tmux"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/usr/local/bin/tmux"
        let result = runReadingStdout(tmuxBin, args: ["send-keys", "-t", target, "-l", text]) ?? ""
        _ = runReadingStdout(tmuxBin, args: ["send-keys", "-t", target, "Enter"])
        return InjectionResult(method: .tmux, success: true, output: result)
    }

    // MARK: AppleScript into Terminal.app

    /// Walks `ps` to find the claude process matching this session id and
    /// returns its controlling TTY (e.g. "/dev/ttys003"), or nil if it can't
    /// be located.
    static func findClaudeTTY(sessionId: String) -> String? {
        guard let ps = runReadingStdout("/bin/ps", args: ["-axo", "pid,tty,command"]) else { return nil }
        let prefix8 = String(sessionId.prefix(8))
        for line in ps.split(separator: "\n").dropFirst() {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            let parts = cleaned.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let tty = String(parts[1])
            let cmd = String(parts[2])
            if tty == "??" { continue }
            // Match on the explicit session id OR a `claude` binary that
            // has a controlling terminal we can address.
            if cmd.contains(sessionId) || cmd.contains(prefix8) {
                return "/dev/" + tty
            }
        }
        // Fallback: any claude process with a TTY (best effort if we have one
        // claude session and the id-based match misses).
        for line in ps.split(separator: "\n").dropFirst() {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            let parts = cleaned.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let tty = String(parts[1])
            let cmd = String(parts[2])
            if tty == "??" { continue }
            if cmd.hasPrefix("claude") || cmd.contains(" claude ") || cmd.contains("/claude") {
                return "/dev/" + tty
            }
        }
        return nil
    }

    /// Returns the bundle id (or process name) of the terminal app hosting this
    /// TTY. Currently we only know how to handle "Terminal" (Terminal.app).
    /// Other apps like iTerm/Warp need their own AppleScript dialects.
    static func hostingApp(forTTY tty: String) -> String? {
        // lsof -t /dev/ttysXXX gives the PIDs that have it open. Walk up to find
        // the GUI app (the controlling terminal application).
        guard let lsofOut = runReadingStdout("/usr/sbin/lsof", args: ["-t", tty]) else { return nil }
        let pids = lsofOut.split(separator: "\n").map(String.init)
        for pid in pids {
            // Walk ancestors to find one whose command starts with /Applications/
            var current: String? = pid
            for _ in 0..<12 {
                guard let p = current,
                      let info = runReadingStdout("/bin/ps", args: ["-o", "ppid=,command=", "-p", p])?
                        .trimmingCharacters(in: .whitespaces) else { break }
                let cols = info.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard cols.count == 2 else { break }
                let ppid = String(cols[0])
                let cmd = String(cols[1])
                if cmd.contains("Terminal.app/Contents/MacOS/Terminal") { return "Terminal" }
                if cmd.contains("iTerm.app/Contents/MacOS/iTerm") { return "iTerm" }
                if cmd.contains("Warp.app/Contents/MacOS/Warp") { return "Warp" }
                if cmd.contains("Ghostty.app/Contents/MacOS/Ghostty") { return "Ghostty" }
                // VS Code spawns terminal shells under "Code Helper" renderer
                // processes whose ancestry chains up to Electron in the app
                // bundle. Same shape for Cursor (a VS Code fork).
                if cmd.contains("Visual Studio Code.app/Contents/") || cmd.contains("/Code Helper") {
                    return "VS Code"
                }
                if cmd.contains("Cursor.app/Contents/") || cmd.contains("/Cursor Helper") {
                    return "Cursor"
                }
                if ppid == "1" || ppid.isEmpty { break }
                current = ppid
            }
        }
        return nil
    }

    /// Map a terminal host-app name to the normalised session source the
    /// relay protocol uses. VS Code & Cursor are reported as `.vscode` so
    /// the phone shows them as "VS Code" surfaces. Everything else maps
    /// to `.terminal`.
    static func source(forSessionId sessionId: String) -> AgentSessionSource {
        guard let tty = findClaudeTTY(sessionId: sessionId),
              let host = hostingApp(forTTY: tty) else {
            return .terminal
        }
        switch host {
        case "VS Code", "Cursor": return .vscode
        default: return .terminal
        }
    }

    // MARK: Codex injection

    /// Deliver `text` to a `codex` CLI session running in `cwd`. The session
    /// is identified by matching cwd — Codex CLI doesn't carry a thread id
    /// in argv the way Claude does. Two paths:
    ///   1. tmux — if a pane's `pane_current_path` matches and is running
    ///      `codex`/`node` we can send-keys to it. Works in VS Code's
    ///      integrated terminal too if the user is in tmux.
    ///   2. AppleScript Terminal — find the matching codex PID, look up its
    ///      TTY, and `do script in t` to the Terminal tab hosting that TTY.
    ///
    /// Surfaces we don't (yet) handle: Codex Desktop (its own native UI)
    /// and bare VS Code terminals without tmux. Those fail with a clear
    /// log line so the user knows why.
    static func injectCodex(text: String, cwd: String, threadId: String) -> InjectionResult {
        Logger.shared.log("CodexInjection.start cwd=\(cwd) threadId=\(threadId.prefix(8)) text=\(text.prefix(80))")

        // 1) tmux send-keys — works in Terminal AND VS Code's embedded
        //    terminal when the user is in tmux.
        if let tmuxTarget = locateCodexTmuxTarget(cwd: cwd) {
            Logger.shared.log("CodexInjection.path=tmux target=\(tmuxTarget)")
            return injectViaTmux(target: tmuxTarget, text: text)
        }

        // 2) AppleScript Terminal — direct typing into the live codex CLI's
        //    tab. Only viable when the CLI is hosted by Terminal.app.
        if let tty = findCodexTTY(forCwd: cwd) {
            Logger.shared.log("CodexInjection.tty=\(tty) — checking host app")
            let host = hostingApp(forTTY: tty)
            Logger.shared.log("CodexInjection.host=\(host ?? "unknown")")
            if host == "Terminal" {
                let result = injectViaAppleScriptTerminal(text: text, tty: tty, pressEnterAfter: true)
                Logger.shared.log("CodexInjection.applescript returned success=\(result.success) output=\(result.output.prefix(140))")
                if result.success { return result }
                Logger.shared.log("CodexInjection.applescript failed — falling back to headless")
            } else {
                Logger.shared.log("CodexInjection.host=\(host ?? "nil") — not a Terminal tab, using headless")
            }
        } else {
            Logger.shared.log("CodexInjection.no-tty — using headless (codex exec resume)")
        }

        // 3) Headless — `codex exec resume <threadId> <prompt>`. Works for
        //    any surface that owns the thread (Codex Desktop, VS Code, CLI)
        //    because it talks to the on-disk rollout, not the live TTY.
        //    The owning app picks up the new turn on its next file-watch.
        return injectCodexViaExecResume(text: text, cwd: cwd, threadId: threadId)
    }

    private static func injectCodexViaExecResume(text: String, cwd: String, threadId: String) -> InjectionResult {
        let codexBin = discoverCodexBinary()
        let logDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Page-codex-replies", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("\(timestamp())-\(threadId.prefix(8)).log")

        // Inherit PATH-augmenting so `node` resolves under LaunchAgent
        // context (same fix as the app-server spawn).
        var env = ProcessInfo.processInfo.environment
        let pathDirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(NSHomeDirectory())/.nvm/versions/node/current/bin"
        ]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (pathDirs + existing.split(separator: ":").map(String.init))
            .reduce(into: [String]()) { acc, dir in if !acc.contains(dir) { acc.append(dir) } }
            .joined(separator: ":")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.environment = env
        proc.arguments = ["-lc", """
            cd \(shellEscape(cwd)) || exit 1
            \(shellEscape(codexBin)) exec resume \(shellEscape(threadId)) \(shellEscape(text)) 2>&1
        """]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        Logger.shared.log("CodexInjection.path=exec_resume threadId=\(threadId.prefix(8)) cwd=\(cwd)")
        do {
            try proc.run()
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? out.data(using: .utf8)?.write(to: logURL)
            let success = proc.terminationStatus == 0
            Logger.shared.log("CodexInjection.exec_resume success=\(success) exit=\(proc.terminationStatus) log=\(logURL.lastPathComponent)")
            return InjectionResult(
                method: .codexExecResume,
                success: success,
                output: success ? "ok (log: \(logURL.lastPathComponent))" : String(out.suffix(280))
            )
        } catch {
            Logger.shared.log("CodexInjection.exec_resume threw: \(error)")
            return InjectionResult(method: .codexExecResume, success: false, output: "\(error)")
        }
    }

    private static func discoverCodexBinary() -> String {
        let candidates = [
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "\(NSHomeDirectory())/.npm-global/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "codex"
    }

    /// Locate the TTY for the codex CLI process whose cwd matches `cwd`.
    /// codex on macOS launches as `node /usr/local/bin/codex` (the user-
    /// facing wrapper) or the vendored native binary. We match either.
    static func findCodexTTY(forCwd cwd: String) -> String? {
        guard let ps = runReadingStdout("/bin/ps", args: ["-axo", "pid,tty,command"]) else { return nil }
        for line in ps.split(separator: "\n").dropFirst() {
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            let parts = cleaned.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let pid = String(parts[0])
            let tty = String(parts[1])
            let cmd = String(parts[2])
            if tty == "??" { continue }

            let cmdParts = cmd.split(separator: " ", omittingEmptySubsequences: true)
            guard let exe = cmdParts.first else { continue }
            let exeBasename = (String(exe) as NSString).lastPathComponent
            // Match the user-facing codex CLI (a node script) and the
            // vendored native codex binary. Skip our own app-server child
            // — its cwd doesn't represent a user session.
            let isCodexCli =
                (exeBasename == "codex" && !cmd.contains("app-server")) ||
                (exeBasename == "node" && cmd.contains("/codex") && !cmd.contains("app-server"))
            guard isCodexCli else { continue }

            // Check this PID's cwd via lsof.
            guard let lsofOut = runReadingStdout("/usr/sbin/lsof", args: ["-a", "-d", "cwd", "-p", pid, "-Fn"]) else { continue }
            for lsofLine in lsofOut.split(separator: "\n") {
                if lsofLine.hasPrefix("n/") {
                    let processCwd = String(lsofLine.dropFirst())
                    if processCwd == cwd {
                        return "/dev/" + tty
                    }
                }
            }
        }
        return nil
    }

    private static func locateCodexTmuxTarget(cwd: String) -> String? {
        let panes = runReadingStdout(
            "/usr/local/bin/tmux",
            args: ["list-panes", "-a", "-F", "#{session_name}:#{window_index} #{pane_current_command} #{pane_current_path}"]
        ) ?? runReadingStdout(
            "/opt/homebrew/bin/tmux",
            args: ["list-panes", "-a", "-F", "#{session_name}:#{window_index} #{pane_current_command} #{pane_current_path}"]
        ) ?? ""
        if panes.isEmpty { return nil }
        for line in panes.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            let target = String(parts[0])
            let cmd = String(parts[1])
            let paneCwd = String(parts[2])
            let cmdLower = cmd.lowercased()
            let isCodex = cmdLower.contains("codex") || cmdLower == "node"
            if isCodex && paneCwd == cwd {
                return target
            }
        }
        return nil
    }

    private static func injectViaAppleScriptTerminal(text: String, tty: String, pressEnterAfter: Bool = false) -> InjectionResult {
        // The text gets embedded inside an AppleScript string literal — escape
        // backslashes and double-quotes.
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Uses Terminal's native `do script in <tab>` which writes the command
        // to the matched tab's TTY and executes it. This goes through
        // Terminal's Apple Event Automation API (TCC service: AppleEvents)
        // rather than System Events keystrokes (TCC service: Accessibility).
        // Automation prompts the user with a clear "ClaudePowerMode wants to
        // control Terminal" dialog and the grant survives ad-hoc re-signs in
        // a way Accessibility doesn't.
        //
        // For Claude's readline-style input that's enough — `\n` is submit.
        // For Codex's multi-line raw-mode TUI it isn't: `\n` (and even an
        // explicit `\r` injected via `(ASCII character 13)`) is treated as
        // "newline inside input field." Real submit requires a Return key
        // event, which only the Accessibility API (System Events `key code
        // 36`) can synthesise. We do that as a follow-up step when
        // `pressEnterAfter` is true.
        let enterStep = pressEnterAfter ? """

                delay 0.12
                try
                    tell application "System Events" to key code 36
                    return "ok"
                on error errMsg number errNum
                    return "ok_no_enter " & errNum & ": " & errMsg
                end try
        """ : """

                return "ok"
        """
        let script = """
        tell application "Terminal"
            set targetTTY to "\(tty)"
            repeat with w in windows
                repeat with t in tabs of w
                    set tabTTY to ""
                    try
                        set tabTTY to (tty of t as string)
                    end try
                    if tabTTY is targetTTY then
                        set selected tab of w to t
                        do script "\(escaped)" in t
                        activate\(enterStep)
                    end if
                end repeat
            end repeat
        end tell
        return "no_match"
        """

        // Run in-process via NSAppleScript instead of spawning osascript.
        // When we shell out to /usr/bin/osascript, TCC treats osascript as
        // the subject of any Accessibility check (System Events keystroke),
        // so even a granted ClaudePowerMode entry is ignored. NSAppleScript
        // executes within our process, so TCC sees ClaudePowerMode as the
        // responsible app — matching what the user grants in System Settings.
        let (stdout, stderr) = runAppleScriptInProcess(script)
        let success = stdout.hasPrefix("ok")
        if !success {
            Logger.shared.log("AppleScript Terminal injection failed: stdout=\(stdout.prefix(200)) stderr=\(stderr.prefix(200))")
        }
        return InjectionResult(method: .terminalAppleScript, success: success, output: success ? stdout : "stdout=\(stdout) stderr=\(stderr)")
    }

    /// Execute an AppleScript source string in-process and return
    /// (stringValue, errorMessage). NSAppleScript runs the script inside
    /// our binary so TCC checks resolve against ClaudePowerMode rather
    /// than a spawned `osascript` process.
    private static func runAppleScriptInProcess(_ source: String) -> (stdout: String, stderr: String) {
        guard let script = NSAppleScript(source: source) else {
            return ("", "NSAppleScript init failed")
        }
        var errorDict: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorDict)
        if let err = errorDict {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "\(err)"
            let num = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            return ("", "\(num): \(msg)")
        }
        let value = descriptor.stringValue ?? ""
        return (value.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// Same as runReadingStdout but returns both streams. Needed for osascript
    /// because the real error message ends up on stderr.
    private static func runReadingBothStreams(_ path: String, args: [String]) -> (stdout: String, stderr: String)? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return (
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? ""
            )
        } catch {
            return nil
        }
    }

    // MARK: headless resume

    private static func injectViaHeadlessResume(sessionId: String, cwd: String, text: String) -> InjectionResult {
        let claudeBin = discoverClaudeBinary()
        let logDir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ClaudePowerMode-resumes", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let logURL = logDir.appendingPathComponent("\(Self.timestamp())-\(sessionId.prefix(8)).log")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-lc", """
            cd \(shellEscape(cwd)) || exit 1
            \(shellEscape(claudeBin)) --resume \(shellEscape(sessionId)) --print \(shellEscape(text)) 2>&1
        """]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            try? out.data(using: .utf8)?.write(to: logURL)
            let success = proc.terminationStatus == 0
            return InjectionResult(method: .headlessResume, success: success, output: out)
        } catch {
            return InjectionResult(method: .headlessResume, success: false, output: "\(error)")
        }
    }

    private static func discoverClaudeBinary() -> String {
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude",
            "\(NSHomeDirectory())/.npm-global/bin/claude"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "claude"
    }

    private static func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }

    private static func runReadingStdout(_ path: String, args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do {
            try proc.run()
            // CRITICAL: drain the pipes BEFORE waitUntilExit. If the child
            // writes more than ~16-64KB and we don't read, the pipe buffer
            // fills, the child blocks on write, and waitUntilExit hangs
            // forever. `readDataToEndOfFile()` blocks until the child closes
            // stdout (which happens on exit), so the order here is safe.
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
