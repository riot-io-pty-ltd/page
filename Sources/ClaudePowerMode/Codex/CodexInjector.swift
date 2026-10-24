import Foundation

/// Outcome of one reply delivery, shaped for `RelaySink.sendReplyInjected`.
/// `detail` is shown on the phone — short, human, no command output.
struct CodexDeliveryOutcome: Equatable {
    let method: String
    let success: Bool
    let detail: String
    /// Longer diagnostic for the Worker log (never shown as-is on the phone).
    let output: String?

    static func failure(_ detail: String, method: String = CodexInjector.Method.none, output: String? = nil) -> CodexDeliveryOutcome {
        CodexDeliveryOutcome(method: method, success: false, detail: detail, output: output)
    }
}

/// A live interactive `codex` process, as seen by one ps + lsof snapshot.
struct CodexProcess: Equatable {
    let pid: Int32
    let ppid: Int32
    /// "ttys004", or nil when the process has no controlling terminal.
    let tty: String?
    let cwd: String?
    /// Rollout JSONL files the process holds open. Codex keeps the active
    /// thread's rollout open for appending, which — when present — tells us
    /// exactly which thread a process owns, not just which directory.
    let openRollouts: Set<String>
    let command: String
}

/// Finds live interactive Codex sessions. Shared by the backend (which
/// threads are open right now) and the injector (where to type).
enum CodexProcessScanner {
    /// Subcommands that are not an interactive TUI session.
    private static let nonInteractiveSubcommands: Set<String> = [
        "app-server", "exec", "e", "mcp", "mcp-server", "login", "logout",
        "completion", "debug", "sandbox", "apply", "a", "proto", "cloud", "doctor",
    ]

    /// True for the user-facing `codex` TUI: the native binary, or the Node
    /// wrapper (`node …/bin/codex[.js]`). Page's own `codex app-server` child,
    /// `codex exec` runs and the like are excluded.
    static func isInteractiveCodexCommand(_ command: String) -> Bool {
        let argv = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let exe = argv.first else { return false }
        var rest = argv.dropFirst()
        let exeName = (exe as NSString).lastPathComponent
        if exeName == "node" {
            guard let script = rest.first else { return false }
            let scriptName = (script as NSString).lastPathComponent
            guard scriptName == "codex" || scriptName == "codex.js" else { return false }
            rest = rest.dropFirst()
        } else if !isNativeCodexExecutable(exeName) {
            return false
        }
        // A server is never a TUI, wherever the subcommand sits (Codex
        // Desktop runs `codex -c key=value … app-server …`).
        if rest.prefix(16).contains(where: { serverSubcommands.contains($0) }) { return false }
        // First positional argument (skipping flags and the values of flags
        // that take one) decides the subcommand. Only look a few tokens in:
        // a prompt can contain any word.
        var skipValue = false
        for token in rest.prefix(8) {
            if skipValue { skipValue = false; continue }
            if token.hasPrefix("-") {
                skipValue = valueFlags.contains(token)
                continue
            }
            return !nonInteractiveSubcommands.contains(token)
        }
        return true
    }

    /// Subcommands that run a server rather than a session.
    private static let serverSubcommands: Set<String> = ["app-server", "mcp-server"]

    /// Global flags whose value is the next argument (`-c key=value`).
    private static let valueFlags: Set<String> = [
        "-c", "--config", "-m", "--model", "-p", "--profile", "-s", "--sandbox",
        "-a", "--ask-for-approval", "-C", "--cd", "-i", "--image", "--enable", "--disable",
        "--add-dir", "--local-provider",
    ]

    /// Any codex executable — TUI, app-server, exec, the npm Node wrapper —
    /// whatever the subcommand. Used to find every process that might hold
    /// a thread's rollout, not just interactive sessions.
    static func isCodexFamilyCommand(_ command: String) -> Bool {
        let argv = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let exe = argv.first else { return false }
        let exeName = (exe as NSString).lastPathComponent
        if exeName == "node", let script = argv.dropFirst().first {
            let scriptName = (script as NSString).lastPathComponent
            return scriptName == "codex" || scriptName == "codex.js"
        }
        return isNativeCodexExecutable(exeName)
    }

    /// `codex`, or the vendored native binary older npm builds spawn under
    /// its target triple (`codex-aarch64-apple-darwin`). That child is the
    /// one holding the thread's rollout open; missing it would make its
    /// Node wrapper look like a codex attached to no thread.
    static func isNativeCodexExecutable(_ name: String) -> Bool {
        name == "codex" || (name.hasPrefix("codex-") && name.hasSuffix("-apple-darwin"))
    }

    struct LsofEntry: Equatable {
        var cwd: String?
        var rollouts: Set<String> = []
    }

    /// Parses `lsof -F fn` output (`p<pid>`, `f<fd>`, `n<name>` lines).
    static func parseLsof(_ output: String) -> [Int32: LsofEntry] {
        var result: [Int32: LsofEntry] = [:]
        var pid: Int32?
        var fd = ""
        for raw in output.split(separator: "\n") {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value)
                fd = ""
                if let pid, result[pid] == nil { result[pid] = LsofEntry() }
            case "f":
                fd = value
            case "n":
                guard let pid else { continue }
                if fd == "cwd" {
                    result[pid, default: LsofEntry()].cwd = value
                } else if value.hasSuffix(".jsonl"), (value as NSString).lastPathComponent.hasPrefix("rollout-") {
                    result[pid, default: LsofEntry()].rollouts.insert(value)
                }
            default:
                continue
            }
        }
        return result
    }

    /// One ps snapshot plus (only if any codex is running) one lsof call.
    static func liveSessions(table: [ProcessRunner.ProcessInfoRow]? = nil) -> [CodexProcess] {
        let rows = (table ?? ProcessRunner.processTable()).filter { isInteractiveCodexCommand($0.command) }
        guard !rows.isEmpty else { return [] }
        let pids = rows.map { String($0.pid) }.joined(separator: ",")
        // Exit status is non-zero when a pid vanished mid-scan; the output for
        // the others is still valid, so parse regardless.
        let lsof = ProcessRunner.run("/usr/sbin/lsof", ["-a", "-p", pids, "-F", "fn"], timeout: 5)
        let entries = parseLsof(lsof.stdout)
        return rows.map { row in
            let entry = entries[row.pid]
            return CodexProcess(
                pid: row.pid,
                ppid: row.ppid,
                tty: (row.tty == "??" || row.tty.isEmpty) ? nil : row.tty,
                cwd: entry?.cwd,
                openRollouts: entry?.rollouts ?? [],
                command: row.command
            )
        }
    }

    /// Canonical form for comparing a thread's cwd with lsof's (which is
    /// always the resolved path, e.g. /private/tmp rather than /tmp).
    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Delivers phone replies into live Codex sessions. Targeting is exact or it
/// fails: Page never types into "some codex in that folder".
///
///   1. The thread's process: the codex holding the thread's rollout open.
///      Only for a terminal (CLI) thread, and only when nothing holds its
///      rollout, the single terminal whose codex runs in the thread's
///      folder and is attached to no thread at all (a terminal where any
///      codex process holds another rollout, or that lsof couldn't read,
///      is never a candidate). Two candidate terminals → refuse as
///      ambiguous. The codex must be the terminal's foreground job.
///   2. tmux: the pane whose tty is that process's tty — literal text (or a
///      bracketed paste for multi-line), a pause, then an Enter key.
///   2b. cmux: the process's cmux pane (CmuxBridge) — only while cmux reads
///      Codex's composer as empty, then a paste plus cmux's submit key.
///   3. Terminal.app: AppleScript types into the tab with that tty, brings
///      it to the front, re-checks Terminal is frontmost with that tab
///      selected, and only then sends Return via System Events (Codex's TUI
///      treats a typed newline as "newline in the composer"; submitting
///      needs a real Return key event).
///   4. No live codex owns the thread (Codex Desktop / VS Code, or a closed
///      TUI): `codex exec resume <thread> <text>` in the background, if
///      enabled. Never while a live process owns it — two writers on one
///      thread would fork the conversation — and never while any other
///      process holds the thread's rollout open (a foreign `codex
///      app-server` in the Codex app or an editor extension, a `codex exec`
///      run), or when either can't be ruled out (ps or lsof came back
///      incomplete). `deliver` only plans
///      it (`.needsExecResume`); the backend runs `runExecResume` off its
///      reply queue, because the run takes a whole agent turn.
///
/// The caller (CodexBackend) decides *whether* typing is safe at all (the
/// turn must have ended — an approval overlay treats letters as hotkeys).
enum CodexInjector {
    enum Method {
        static let tmux = "tmux"
        static let terminal = "terminal_applescript"
        static let execResume = "codex_exec_resume"
        static let cmux = "cmux"
        static let none = "none"
    }

    /// Where a reply for one thread can go.
    enum Target: Equatable {
        case tty(String, pid: Int32)
        /// No live interactive codex owns the thread or its directory.
        case none
        /// Several terminals run codex in that directory; we can't tell which.
        case ambiguous(count: Int)
        /// A codex owns it but has no terminal Page could type into.
        case noTerminal
        /// Nothing holds the thread's rollout, but an unattached codex runs
        /// in its folder and Page can't tell whether it's this thread's.
        case unconfirmed
    }

    /// Whether a thread with no rollout owner may be matched by folder.
    enum CwdFallback: Equatable {
        /// Terminal (CLI) threads: the folder's single unattached codex.
        case allowed
        /// Unknown source: a candidate in the folder means "can't tell"
        /// (`.unconfirmed`) — neither typed into nor ruled out.
        case refuse
        /// Desktop / VS Code / exec / remote threads never live in a TUI
        /// that doesn't hold their rollout; ignore the folder entirely.
        case never

        static func forSource(_ source: AgentSessionSource) -> CwdFallback {
            switch source {
            case .terminal: return .allowed
            case .unknown: return .refuse
            case .desktop, .vscode, .exec, .remote: return .never
            }
        }
    }

    /// `cwd` must already be canonical (`CodexProcessScanner.canonicalPath`).
    static func resolveTarget(cwd: String, rolloutPath: String?, processes: [CodexProcess],
                              cwdFallback: CwdFallback = .allowed) -> Target {
        // The Node wrapper and the native binary it spawns share one tty, so
        // count terminals, not pids.
        func target(for procs: [CodexProcess]) -> Target {
            let ttys = Set(procs.compactMap(\.tty))
            if ttys.count > 1 { return .ambiguous(count: ttys.count) }
            if let tty = ttys.first, let p = procs.first(where: { $0.tty == tty }) {
                return .tty(tty, pid: p.pid)
            }
            return procs.isEmpty ? .none : .noTerminal
        }

        if let rolloutPath, !rolloutPath.isEmpty {
            let rolloutName = (rolloutPath as NSString).lastPathComponent
            let owners = processes.filter { p in
                p.openRollouts.contains { ($0 as NSString).lastPathComponent == rolloutName }
            }
            if !owners.isEmpty { return target(for: owners) }
        }
        if cwdFallback == .never { return .none }

        // Fall back to the directory. Nothing holds our rollout, so every
        // rollout still held belongs to another thread — and a whole codex
        // session is attached to it, not just the process holding the file:
        // the npm Node wrapper holds nothing while its native child (same
        // tty, parent/child) holds the rollout. Exclude per terminal and per
        // parent/child pair, and also exclude a terminal with a process lsof
        // couldn't read (it might hold anything).
        let unsure = processes.filter { !$0.openRollouts.isEmpty || $0.cwd == nil }
        let unsureTTYs = Set(unsure.compactMap(\.tty))
        let unsurePids = Set(unsure.map(\.pid))
        let inCwd = processes.filter { p in
            guard let pcwd = p.cwd, CodexProcessScanner.canonicalPath(pcwd) == cwd else { return false }
            guard p.openRollouts.isEmpty else { return false }
            if let tty = p.tty, unsureTTYs.contains(tty) { return false }
            if unsurePids.contains(p.ppid) { return false }
            if processes.contains(where: { $0.ppid == p.pid && unsurePids.contains($0.pid) }) { return false }
            return true
        }
        if cwdFallback == .refuse, !inCwd.isEmpty { return .unconfirmed }
        return target(for: inCwd)
    }

    /// Terminal host of a process, found by walking its ancestors.
    enum Host: Equatable {
        case terminalApp
        case tmux
        case app(String)
        case unknown
    }

    static func host(ofPid pid: Int32, table: [ProcessRunner.ProcessInfoRow]) -> Host {
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var current = byPid[pid]?.ppid ?? 0
        var hops = 0
        while current > 1, hops < 40, let row = byPid[current] {
            let exe = row.command.split(separator: " ").first.map(String.init) ?? ""
            let exeName = (exe as NSString).lastPathComponent
            if exeName == "tmux" || exeName.hasPrefix("tmux:") { return .tmux }
            if let app = appName(fromCommand: row.command) {
                return app == "Terminal" ? .terminalApp : .app(app)
            }
            current = row.ppid
            hops += 1
        }
        return .unknown
    }

    /// "/Applications/iTerm.app/Contents/MacOS/iTerm2" → "iTerm". Uses the
    /// outermost bundle, so helper processes nested inside an app
    /// ("Visual Studio Code.app/…/Code Helper.app/…") name the app itself.
    static func appName(fromCommand command: String) -> String? {
        guard let range = command.range(of: ".app/Contents/") else { return nil }
        let prefix = command[..<range.lowerBound]
        guard let slash = prefix.lastIndex(of: "/") else { return nil }
        let name = prefix[prefix.index(after: slash)...]
        return name.isEmpty ? nil : String(name)
    }

    /// Strips control characters (keeping newlines) and defuses a leading
    /// `!` (Codex's local-shell prefix) and `-` (would be parsed as a flag by
    /// `codex exec resume`).
    static func sanitize(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let scalars = normalized.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        var cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("!") || cleaned.hasPrefix("-") { cleaned = " " + cleaned }
        return cleaned
    }

    static func projectName(forCwd cwd: String) -> String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "Codex" : name
    }

    // MARK: Delivery

    /// A background `codex exec resume` that `deliver` decided on but did
    /// not run. Text is already sanitised.
    struct ExecResumeJob: Equatable {
        let text: String
        let threadId: String
        let cwd: String
        let rolloutPath: String?
        let codexPath: String
        let cwdFallback: CwdFallback
    }

    /// What `deliver` did, or what it leaves to the caller.
    enum DeliveryStep: Equatable {
        case finished(CodexDeliveryOutcome)
        /// No live codex owns the thread and a background resume may run.
        /// It takes a whole agent turn (up to 15 min): run it with
        /// `runExecResume` on a queue of its own, never the reply queue.
        case needsExecResume(ExecResumeJob)
    }

    /// Synchronous and short: resolves the target and types into it (a
    /// few hundred ms, or up to the AppleScript timeouts for Terminal.app).
    /// Never runs the background exec resume itself.
    static func deliver(text rawText: String,
                        threadId: String,
                        cwd: String,
                        rolloutPath: String?,
                        codexPath: String,
                        allowExecResume: Bool,
                        cwdFallback: CwdFallback,
                        requireEmptyComposer: Bool = false) -> DeliveryStep {
        let table = ProcessRunner.processTable()
        let processes = CodexProcessScanner.liveSessions(table: table)
        let step = plan(text: rawText, threadId: threadId, cwd: cwd, rolloutPath: rolloutPath, codexPath: codexPath,
                        allowExecResume: allowExecResume, cwdFallback: cwdFallback,
                        table: table, processes: processes, canonicalCwd: CodexProcessScanner.canonicalPath(cwd),
                        rolloutHolders: { rolloutHolders(rolloutPath: rolloutPath, threadId: threadId, table: table) })
        switch step {
        case .finished(let outcome):
            return .finished(outcome)
        case .needsExecResume(let job):
            return .needsExecResume(job)
        case .type(let text, let tty, let pid):
            let term = terminal(tty: tty, pid: pid, threadId: threadId, table: table)
            // The user is at the Mac (automatic low-battery resume): they may
            // be typing in that very composer, so it must be seen to be
            // empty, not merely "no draft seen".
            if requireEmptyComposer, let why = composerRefusal(term) {
                Logger.shared.log("CodexInjector: thread=\(threadId.prefix(8)) not typing — \(why)")
                return .finished(.failure(why, method: term.method))
            }
            return .finished(type(text, into: term))
        }
    }

    /// Pure decision behind `deliver`.
    enum PlannedStep: Equatable {
        case finished(CodexDeliveryOutcome)
        case needsExecResume(ExecResumeJob)
        case type(String, tty: String, pid: Int32)
    }

    static func plan(text rawText: String,
                     threadId: String,
                     cwd: String,
                     rolloutPath: String?,
                     codexPath: String,
                     allowExecResume: Bool,
                     cwdFallback: CwdFallback,
                     table: [ProcessRunner.ProcessInfoRow],
                     processes: [CodexProcess],
                     canonicalCwd: String,
                     rolloutHolders: () -> RolloutHolders = { .none }) -> PlannedStep {
        let text = sanitize(rawText)
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .finished(.failure("Empty reply — nothing to send"))
        }
        let project = projectName(forCwd: cwd)
        let target = resolveTarget(cwd: canonicalCwd, rolloutPath: rolloutPath, processes: processes,
                                   cwdFallback: cwdFallback)
        Logger.shared.log("CodexInjector: thread=\(threadId.prefix(8)) project=\(project) target=\(target)")

        switch target {
        case .ambiguous(let count):
            return .finished(.failure("\(count) Codex sessions are open in \(project) — reply on the Mac"))
        case .noTerminal:
            return .finished(.failure("Codex is running in \(project) without a terminal Page can type into"))
        case .unconfirmed:
            return .finished(.failure("Codex is open in \(project), but Page can't tell if it's this session — reply on the Mac"))
        case .none:
            guard allowExecResume else {
                return .finished(.failure("Codex isn't open in \(project) any more (background resume is off)"))
            }
            // Only now (exec resume is the next step) pay for the lsof that
            // finds non-TUI holders such as a foreign app-server.
            if let why = execResumeBlocker(table: table, processes: processes, project: project,
                                           holders: rolloutHolders()) {
                return .finished(.failure(why))
            }
            return .needsExecResume(ExecResumeJob(text: text, threadId: threadId, cwd: cwd, rolloutPath: rolloutPath,
                                                  codexPath: codexPath, cwdFallback: cwdFallback))
        case .tty(let tty, let pid):
            return .type(text, tty: tty, pid: pid)
        }
    }

    /// Runs a planned background resume. Blocks for the whole agent turn
    /// (up to 15 min) — call it on a queue of its own. Re-checks right
    /// before launching that still no live codex owns the thread (the user
    /// may have reopened it while the job waited).
    static func runExecResume(_ job: ExecResumeJob) -> CodexDeliveryOutcome {
        let project = projectName(forCwd: job.cwd)
        let table = ProcessRunner.processTable()
        let processes = CodexProcessScanner.liveSessions(table: table)
        let target = resolveTarget(cwd: CodexProcessScanner.canonicalPath(job.cwd), rolloutPath: job.rolloutPath,
                                   processes: processes, cwdFallback: job.cwdFallback)
        guard target == .none else {
            return .failure("Codex is open in \(project) again — reply again to type into it", method: Method.execResume)
        }
        let holders = rolloutHolders(rolloutPath: job.rolloutPath, threadId: job.threadId, table: table)
        if let why = execResumeBlocker(table: table, processes: processes, project: project, holders: holders) {
            return .failure(why, method: Method.execResume)
        }
        return execResume(text: job.text, threadId: job.threadId, cwd: job.cwd, codexPath: job.codexPath)
    }

    /// Why a background `codex exec resume` can't run, or nil. "No live
    /// codex owns the thread" is only trustworthy when ps worked and lsof
    /// reported every running codex (a process with an unknown cwd might be
    /// the owner).
    ///
    /// `holders` covers every other process with the thread's rollout open —
    /// above all a foreign app-server (the Codex app, an editor extension)
    /// that has the thread loaded: it keeps appending to that rollout, so a
    /// second writer would fork the conversation under it.
    static func execResumeBlocker(table: [ProcessRunner.ProcessInfoRow], processes: [CodexProcess], project: String,
                                  holders: RolloutHolders = .none) -> String? {
        if table.isEmpty { return "Couldn't check whether Codex is still open in \(project) — reply on the Mac" }
        if processes.contains(where: { $0.cwd == nil }) {
            return "Couldn't confirm Codex isn't still open in \(project) — reply on the Mac"
        }
        switch holders {
        case .none:
            return nil
        case .unknown:
            return "Couldn't check whether another Codex app has this session open — reply on the Mac"
        case .held(let list):
            return heldDetail(list, table: table)
        }
    }

    // MARK: Rollout holders (any codex, not just TUIs)

    /// A process other than Page with a thread's rollout file open.
    struct RolloutHolder: Equatable {
        let pid: Int32
        /// lsof's (short) command name; the ps table has the full one.
        let command: String
    }

    enum RolloutHolders: Equatable {
        case none
        case held([RolloutHolder])
        /// lsof failed, timed out or couldn't read a candidate.
        case unknown
    }

    /// Every process except Page itself (`ownPid`) that holds the thread's
    /// rollout open, whatever it is — a TUI, `codex exec`, a foreign
    /// `codex app-server` (Codex app, VS Code). With a rollout path, lsof is
    /// asked about that file directly (matched by inode, so every process
    /// counts regardless of its name). Without one (or if the file is gone),
    /// every codex-family process is scanned for a rollout named after the
    /// thread.
    static func rolloutHolders(rolloutPath: String?, threadId: String, table: [ProcessRunner.ProcessInfoRow],
                               ownPid: Int32 = getpid(),
                               lsof: ([String]) -> ProcessRunner.Result = { ProcessRunner.run("/usr/sbin/lsof", $0, timeout: 10) }) -> RolloutHolders {
        if let rolloutPath, !rolloutPath.isEmpty, FileManager.default.fileExists(atPath: rolloutPath) {
            let r = lsof(["-w", "-F", "pc", "--", rolloutPath])
            guard r.launched, !r.timedOut else { return .unknown }
            let found = parseLsofHolders(r.stdout).filter { $0.pid != ownPid }
            if !found.isEmpty { return .held(found) }
            // Exit 1 with nothing on stderr is lsof's "nobody has it open".
            if r.status == 0 || r.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .none }
            return .unknown
        }
        guard !threadId.isEmpty else { return .unknown }
        let candidates = table.filter { $0.pid != ownPid && CodexProcessScanner.isCodexFamilyCommand($0.command) }
        guard !candidates.isEmpty else { return .none }
        let r = lsof(["-w", "-a", "-p", candidates.map { String($0.pid) }.joined(separator: ","), "-F", "fn"])
        guard r.launched, !r.timedOut else { return .unknown }
        let entries = CodexProcessScanner.parseLsof(r.stdout)
        var held: [RolloutHolder] = []
        for row in candidates {
            // A candidate lsof reported nothing for might hold anything.
            guard let entry = entries[row.pid] else { return .unknown }
            if entry.rollouts.contains(where: { ($0 as NSString).lastPathComponent.contains(threadId) }) {
                held.append(RolloutHolder(pid: row.pid, command: row.command))
            }
        }
        return held.isEmpty ? .none : .held(held)
    }

    /// Parses `lsof -F pc` output (`p<pid>` then `c<command>` per process).
    static func parseLsofHolders(_ output: String) -> [RolloutHolder] {
        var result: [RolloutHolder] = []
        var pid: Int32?
        var command = ""
        func flush() {
            if let pid, !result.contains(where: { $0.pid == pid }) { result.append(RolloutHolder(pid: pid, command: command)) }
        }
        for raw in output.split(separator: "\n") {
            guard let tag = raw.first else { continue }
            let value = String(raw.dropFirst())
            switch tag {
            case "p":
                flush()
                pid = Int32(value)
                command = ""
            case "c":
                command = value
            default:
                continue
            }
        }
        flush()
        return result
    }

    /// Phone-facing refusal naming what holds the thread.
    static func heldDetail(_ holders: [RolloutHolder], table: [ProcessRunner.ProcessInfoRow]) -> String {
        let names = holders.map { holderName($0, table: table) }
        if let first = names.first, names.allSatisfy({ $0 == first }), first != otherCodexName {
            return "This Codex session is open in \(first) — reply there"
        }
        return "Another Codex process has this session open — reply there or on the Mac"
    }

    static let otherCodexName = "another Codex process"

    /// "the Codex app", "Visual Studio Code", "a background codex exec run"…
    static func holderName(_ holder: RolloutHolder, table: [ProcessRunner.ProcessInfoRow]) -> String {
        let command = table.first(where: { $0.pid == holder.pid })?.command ?? holder.command
        if let app = appName(fromCommand: command) ?? {
            if case .app(let name) = host(ofPid: holder.pid, table: table) { return name }
            return nil
        }() {
            switch app {
            case "Codex", "ChatGPT", "CodexCLI": return "the Codex app"
            case "Code", "Code Helper", "Code Helper (Plugin)": return "Visual Studio Code"
            default: return app
            }
        }
        if command.contains("/.vscode/extensions/") { return "Visual Studio Code" }
        if command.contains("/.cursor/extensions/") { return "Cursor" }
        let argv = command.split(separator: " ").map(String.init)
        if argv.prefix(6).contains("exec") || argv.prefix(6).contains("e") { return "a background codex exec run" }
        return otherCodexName
    }

    // MARK: Terminals

    /// Where to type for one live Codex process.
    enum Terminal: Equatable {
        case tmux(pane: String)
        case cmux(CmuxBridge.Target)
        case terminalApp(tty: String)
        /// Phone-safe reason Page can't type there.
        case unavailable(String)

        var label: String {
            switch self {
            case .tmux(let pane): return "tmux pane \(pane)"
            case .cmux(let target): return target.label
            case .terminalApp(let tty): return "Terminal tab \((tty as NSString).lastPathComponent)"
            case .unavailable: return "unknown terminal"
            }
        }

        var method: String {
            switch self {
            case .tmux: return Method.tmux
            case .cmux: return Method.cmux
            case .terminalApp: return Method.terminal
            case .unavailable: return Method.none
            }
        }
    }

    // MARK: Composer check (user at the Mac)

    static let terminalComposerUnverifiedDetail =
        "You're at the Mac and Page can't check Codex's input box in Terminal.app — carry on there yourself"
    static let composerUnverifiedDetail = "Couldn't confirm Codex's input box is empty — carry on at the Mac"

    /// Why Page must not type into `terminal` while the user is at the Mac,
    /// or nil when its composer is verifiably empty. tmux is read with
    /// colours (Codex's placeholder and key hints are drawn dim); cmux is
    /// left to `typeIntoCmux`, which only pastes into an input box cmux
    /// reads as empty; Terminal.app's text can't tell the placeholder from
    /// a draft, so it is never verifiable.
    static func composerRefusal(_ terminal: Terminal,
                                capture: (String) -> String? = { capturePane($0) }) -> String? {
        switch terminal {
        case .tmux(let pane):
            switch capture(pane).map({ codexComposer(screen: $0) }) ?? .unknown {
            case .empty: return nil
            case .draft: return CmuxBridge.draftDetail
            case .unknown: return composerUnverifiedDetail
            }
        case .cmux, .unavailable:
            return nil
        case .terminalApp:
            return terminalComposerUnverifiedDetail
        }
    }

    /// `tmux capture-pane -p -e` of `pane` (SGR escapes kept), or nil.
    static func capturePane(_ pane: String) -> String? {
        let r = tmux(["capture-pane", "-p", "-e", "-t", pane])
        return r.succeeded ? r.stdout : nil
    }

    /// Codex's composer as read off the screen.
    enum ComposerState: Equatable {
        case empty
        case draft
        /// Not found, or something below it that isn't a known key hint.
        case unknown
    }

    /// Key-hint / status fragments Codex draws under its composer.
    private static let footerHints = ["for shortcuts", "context left", "% context", "⏎", "⌃", "ctrl +", "esc to", "tab to"]

    /// Pure. Finds Codex's composer — the bottom-most line whose first
    /// character (after frame / padding) is a prompt glyph (`›`, `▌`, `❯`,
    /// `>`) followed by a space or the line's end — in `screen` (`tmux
    /// capture-pane -e` output) and says whether the user typed anything
    /// in it. Dim / grey characters (the placeholder, key hints) never
    /// count as typed. Fail-closed: typed text on the prompt line is a
    /// draft; anything typed below it other than a known key hint (a
    /// continuation line, an unfamiliar layout) is `.unknown`; no prompt
    /// line is `.unknown`. A history line that happens to be the bottom-most
    /// `›` line reads as a draft or unknown — never as empty.
    static func codexComposer(screen: String) -> ComposerState {
        let rows = screen.components(separatedBy: "\n").suffix(40).map(styledCells)
        let plain = rows.map { String($0.map(\.char)) }
        let frame = CharacterSet(charactersIn: "│┃║▌▎▍").union(.whitespaces).union(CharacterSet(charactersIn: "\u{00A0}"))
        let glyphs: Set<Character> = ["›", "▌", "❯", ">"]

        func promptOffset(_ s: String) -> Int? {
            let chars = Array(s)
            var i = 0
            while i < chars.count, chars[i] == " " || chars[i] == "\u{00A0}" || chars[i] == "│" || chars[i] == "┃" { i += 1 }
            guard i < chars.count, glyphs.contains(chars[i]) else { return nil }
            let next = i + 1
            guard next == chars.count || chars[next] == " " || chars[next] == "\u{00A0}" else { return nil }
            return next
        }
        func typed(_ cells: [StyledCell], from: Int) -> String {
            String(cells.dropFirst(from).filter { !$0.faint }.map(\.char))
                .trimmingCharacters(in: frame)
        }

        guard let i = plain.indices.reversed().first(where: { promptOffset(plain[$0]) != nil }),
              let offset = promptOffset(plain[i]) else { return .unknown }
        if !typed(rows[i], from: offset).isEmpty { return .draft }
        for j in plain.indices where j > i {
            let rest = typed(rows[j], from: 0)
            guard !rest.isEmpty else { continue }
            let lower = rest.lowercased()
            if footerHints.contains(where: { lower.contains($0) }) { continue }
            return .unknown
        }
        return .empty
    }

    struct StyledCell: Equatable {
        let char: Character
        /// Drawn dim or grey: placeholder / hint text, never typed input.
        let faint: Bool
    }

    /// Splits one line of `tmux capture-pane -e` output into characters,
    /// each flagged when drawn dim or in a grey foreground. Escape sequences
    /// are dropped. Extended colours (`38;5;n`, `38;2;r;g;b`, and the same
    /// for background 48 / underline 58) are consumed whole, so a
    /// background's parameters are never misread as attributes (the `2`
    /// in `48;2;…` is not "dim").
    static func styledCells(_ line: String) -> [StyledCell] {
        var out: [StyledCell] = []
        var dim = false
        var grey = false
        var chars = Array(line)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            guard c == "\u{1B}" else {
                out.append(StyledCell(char: c, faint: dim || grey))
                continue
            }
            guard let kind = chars.first else { break }
            chars = chars.dropFirst()
            guard kind == "[" else {
                // OSC (ESC ]) runs to BEL or ST; other escapes are two bytes.
                if kind == "]" {
                    while let p = chars.first {
                        chars = chars.dropFirst()
                        if p == "\u{07}" { break }
                        if p == "\u{1B}" { chars = chars.dropFirst(); break }
                    }
                }
                continue
            }
            var params = ""
            while let p = chars.first, !(p.isASCII && p.isLetter) && p != "~" { params.append(p); chars = chars.dropFirst() }
            let final = chars.first
            chars = chars.dropFirst()
            guard final == "m" else { continue }
            let codes = params.split(whereSeparator: { $0 == ";" || $0 == ":" }).map { Int($0) ?? 0 }
            if codes.isEmpty { dim = false; grey = false; continue }
            var k = 0
            while k < codes.count {
                let code = codes[k]
                switch code {
                case 0: dim = false; grey = false
                case 2: dim = true
                case 22: dim = false
                case 39: grey = false
                case 90: grey = true
                case 30...37, 91...97: grey = false
                case 38, 48, 58:
                    var isGrey: Bool?
                    if k + 2 < codes.count, codes[k + 1] == 5 {
                        let n = codes[k + 2]
                        isGrey = n == 8 || (232...250).contains(n)
                        k += 2
                    } else if k + 4 < codes.count, codes[k + 1] == 2 {
                        let (r, g, b) = (codes[k + 2], codes[k + 3], codes[k + 4])
                        isGrey = max(r, g, b) - min(r, g, b) <= 16 && (64...190).contains(r)
                        k += 4
                    }
                    if code == 38, let isGrey { grey = isGrey }
                default: break
                }
                k += 1
            }
        }
        return out
    }

    static let notForegroundDetail = "Codex is suspended or in the background in its terminal — reply on the Mac"

    /// tmux pane by tty first (Codex in tmux inside cmux types into the
    /// pane, not the cmux surface), then the nearest app ancestor. Only
    /// while codex is the terminal's running foreground job: after ^Z, or
    /// behind another job, keystrokes reach the shell (which would run the
    /// reply as a command) or that job instead. Unknown counts as no.
    static func terminal(tty: String, pid: Int32, threadId: String?, table: [ProcessRunner.ProcessInfoRow],
                         isForeground: (Int32) -> Bool? = { ProcessRunner.isForeground(pid: $0) }) -> Terminal {
        guard isForeground(pid) == true else {
            Logger.shared.log("CodexInjector: pid \(pid) on \(tty) is not the foreground job — not typing")
            return .unavailable(notForegroundDetail)
        }
        if let pane = tmuxPane(forTTY: tty) { return .tmux(pane: pane) }
        switch host(ofPid: pid, table: table) {
        case .terminalApp:
            return .terminalApp(tty: tty)
        case .tmux:
            return .unavailable("Codex is in a tmux session Page couldn't reach")
        case .app(let name):
            if let command = appAncestorCommand(ofPid: pid, table: table),
               let bundle = CmuxBridge.bundlePath(fromAppCommand: command) {
                switch CmuxBridge.locateSurface(pid: pid, sessionId: threadId, agent: .codex, bundlePath: bundle) {
                case .success(let target): return .cmux(target)
                case .failure(let f):
                    Logger.shared.log("CodexInjector: cmux pane not found: \(f.output)")
                    return .unavailable(f.detail)
                }
            }
            return .unavailable("Page can't type into \(name) yet — use tmux or Terminal.app")
        case .unknown:
            return .unavailable("Couldn't find the Codex session's terminal")
        }
    }

    /// Command line of the app ancestor `host(ofPid:)` stops at (nil when it
    /// stops at tmux or finds nothing).
    static func appAncestorCommand(ofPid pid: Int32, table: [ProcessRunner.ProcessInfoRow]) -> String? {
        let byPid = Dictionary(table.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var current = byPid[pid]?.ppid ?? 0
        var hops = 0
        while current > 1, hops < 40, let row = byPid[current] {
            let exe = row.command.split(separator: " ").first.map(String.init) ?? ""
            let exeName = (exe as NSString).lastPathComponent
            if exeName == "tmux" || exeName.hasPrefix("tmux:") { return nil }
            if appName(fromCommand: row.command) != nil { return row.command }
            current = row.ppid
            hops += 1
        }
        return nil
    }

    /// Types `text` and submits it. The caller has established that the
    /// turn ended (or, for cmux, cmux confirms the composer is empty).
    static func type(_ text: String, into terminal: Terminal) -> CodexDeliveryOutcome {
        switch terminal {
        case .tmux(let pane): return typeIntoTmux(pane: pane, text: text)
        case .cmux(let target): return typeIntoCmux(target, text: text)
        case .terminalApp(let tty): return typeIntoTerminal(tty: tty, text: text)
        case .unavailable(let why): return .failure(why)
        }
    }

    /// A lone Esc — interrupts a running Codex turn (low-battery pause).
    /// tmux and cmux only: Terminal.app can't send a key without Return.
    static func interrupt(_ terminal: Terminal) -> CodexDeliveryOutcome {
        switch terminal {
        case .tmux(let pane):
            let r = tmux(["send-keys", "-t", pane, "Escape"])
            return r.succeeded
                ? CodexDeliveryOutcome(method: Method.tmux, success: true, detail: "Pressed Esc in tmux pane \(pane)", output: nil)
                : .failure("Couldn't press Esc in tmux pane \(pane)", method: Method.tmux, output: r.stderr)
        case .cmux(let target):
            let client: CmuxBridge.Client
            switch CmuxBridge.connect(cliPath: target.cliPath) {
            case .failure(let f): return .failure(f.detail, method: Method.cmux, output: f.output)
            case .success(let c): client = c
            }
            switch client.inputState(surface: target.surfaceId) {
            case .failure(let f): return .failure(f.detail, method: Method.cmux, output: f.output)
            case .success(let state) where state == .dialog || state == .unknown:
                // A dialog: Codex is waiting on the user, and Esc would
                // answer it. Unknown: can't tell what Esc would hit.
                return .failure(state == .dialog ? "A prompt is open in that pane" : CmuxBridge.noInputBoxDetail,
                                method: Method.cmux, output: "input state \(state.rawValue)")
            case .success:
                break
            }
            if case .failure(let f) = client.sendKey(surface: target.surfaceId, key: "escape", force: false) {
                return .failure(f.detail, method: Method.cmux, output: f.output)
            }
            return CodexDeliveryOutcome(method: Method.cmux, success: true, detail: "Pressed Esc in cmux pane", output: nil)
        case .terminalApp, .unavailable:
            return .failure("Page can't press Esc in \(terminal.label)")
        }
    }

    // MARK: cmux

    private static func typeIntoCmux(_ target: CmuxBridge.Target, text: String) -> CodexDeliveryOutcome {
        let client: CmuxBridge.Client
        switch CmuxBridge.connect(cliPath: target.cliPath) {
        case .failure(let f): return .failure(f.detail, method: Method.cmux, output: f.output)
        case .success(let c): client = c
        }
        switch client.inputState(surface: target.surfaceId) {
        case .failure(let f):
            return .failure(f.detail, method: Method.cmux, output: f.output)
        case .success(let state):
            // Typing over an approval overlay would trigger its hotkeys;
            // typing into a draft would mangle the user's own message.
            if let why = CmuxBridge.refusalForTyping(state) {
                return .failure(why, method: Method.cmux, output: "input state \(state.rawValue)")
            }
        }
        if case .failure(let f) = client.pasteAndSubmit(surface: target.surfaceId, text: text) {
            return .failure(f.detail, method: Method.cmux, output: f.output)
        }
        return CodexDeliveryOutcome(method: Method.cmux, success: true, detail: "Typed into cmux pane", output: nil)
    }

    // MARK: tmux

    /// Extra leading tmux arguments (e.g. `["-L", "pagetest"]`). Only tests
    /// touch this; production uses the default server.
    static var tmuxServerArgs: [String] = []

    private static func tmux(_ args: [String], stdin: Data? = nil) -> ProcessRunner.Result {
        guard let bin = ProcessRunner.findExecutable("tmux") else { return .notLaunched }
        return ProcessRunner.run(bin, tmuxServerArgs + args, timeout: 5, stdin: stdin)
    }

    /// Pane id (e.g. "%3") whose tty is `/dev/<tty>`, on the default server.
    static func tmuxPane(forTTY tty: String) -> String? {
        let r = tmux(["list-panes", "-a", "-F", "#{pane_id} #{pane_tty}"])
        guard r.succeeded else { return nil }
        return parseTmuxPane(r.stdout, tty: tty)
    }

    static func parseTmuxPane(_ output: String, tty: String) -> String? {
        let wanted = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2, parts[1] == wanted { return String(parts[0]) }
        }
        return nil
    }

    private static func typeIntoTmux(pane: String, text: String) -> CodexDeliveryOutcome {
        if text.contains("\n") {
            // Bracketed paste keeps the newlines as text in the composer.
            let buffer = "page-\(UUID().uuidString.prefix(8))"
            let load = tmux(["load-buffer", "-b", buffer, "-"], stdin: Data(text.utf8))
            guard load.succeeded else {
                return .failure("Couldn't type into tmux pane \(pane)", method: Method.tmux, output: load.stderr)
            }
            let paste = tmux(["paste-buffer", "-p", "-d", "-b", buffer, "-t", pane])
            guard paste.succeeded else {
                return .failure("Couldn't type into tmux pane \(pane)", method: Method.tmux, output: paste.stderr)
            }
        } else {
            // Shared splitter: tmux reads a trailing ";" in an argument as a
            // command separator, so trailing semicolons go as raw bytes.
            for args in ProcessRunner.tmuxLiteralSendKeys(target: pane, text: text) {
                let typed = tmux(args)
                guard typed.succeeded else {
                    return .failure("Couldn't type into tmux pane \(pane)", method: Method.tmux, output: typed.stderr)
                }
            }
        }
        // Codex folds an Enter that arrives within a burst of typed
        // characters into the text (paste-burst detection), so give it a
        // moment before submitting.
        Thread.sleep(forTimeInterval: 0.4)
        let enter = tmux(["send-keys", "-t", pane, "Enter"])
        guard enter.succeeded else {
            return .failure("Typed into tmux pane \(pane) but couldn't press Enter — press it on the Mac",
                            method: Method.tmux, output: enter.stderr)
        }
        return CodexDeliveryOutcome(method: Method.tmux, success: true, detail: "Typed into tmux pane \(pane)", output: nil)
    }

    // MARK: Terminal.app

    /// Seconds each Terminal / System Events Apple event may take. The
    /// scripts run on the main thread (NSAppleScript), so a hung Terminal
    /// would otherwise freeze Page's UI for the 2-minute default per event.
    static let appleScriptTimeoutSeconds = 10

    /// AppleScript's "event timed out" error number.
    static let appleEventTimeoutError = "-1712"

    private static func typeIntoTerminal(tty: String, text: String) -> CodexDeliveryOutcome {
        let devTTY = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        let shortTTY = (devTTY as NSString).lastPathComponent
        // `do script` can't carry newlines without them being typed; Codex
        // would keep them as composer newlines, but keep it one line like the
        // Claude path so the result is predictable.
        let oneLine = text.split(separator: "\n").joined(separator: " ")

        // Step 1: type into the tab and bring exactly that tab to the front.
        let typed = runAppleScript(terminalTypeScript(devTTY: devTTY, text: oneLine))
        if typed.result != "typed" {
            if typed.result == "no_match" {
                return .failure("Couldn't find the Terminal tab for \(shortTTY)", method: Method.terminal)
            }
            return .failure(appleScriptFailureDetail(typed.error), method: Method.terminal, output: typed.error)
        }

        // Let Terminal come forward and Codex absorb the text (see the tmux
        // note on paste bursts).
        Thread.sleep(forTimeInterval: 0.4)

        // Step 2: verify, then press Return.
        // Activation can take longer than the pause (window on another
        // Space, full screen): re-run the verify-then-Return script briefly.
        // Each run re-checks immediately before its own Return. Each run may
        // post Page's own Return key event, so it's recorded first — the
        // hook's "user is back at the Mac" check must not mistake it for
        // the user (SyntheticInput).
        let enterScript = terminalEnterScript(devTTY: devTTY)
        SyntheticInput.record()
        var entered = runAppleScript(enterScript)
        var retries = 0
        while ["not_frontmost", "tab_not_selected"].contains(entered.result), retries < 12 {
            Thread.sleep(forTimeInterval: 0.1)
            SyntheticInput.record()
            entered = runAppleScript(enterScript)
            retries += 1
        }
        if entered.result == "ok" { SyntheticInput.record() }
        return terminalEnterOutcome(result: entered.result, error: entered.error, shortTTY: shortTTY)
    }

    /// Types `text` into the Terminal tab whose tty is `devTTY` and brings
    /// that tab to the front. `do script … in tab` goes through Terminal's
    /// own scripting dictionary (Automation permission), not synthetic
    /// keystrokes. Every Apple event is bounded by the timeout, and a
    /// timeout inside the per-tab `try` is re-raised so a hung Terminal
    /// fails once rather than once per remaining tab.
    static func terminalTypeScript(devTTY: String, text: String) -> String {
        let ttyLiteral = ProcessRunner.appleScriptQuote(devTTY)
        return """
        with timeout of \(appleScriptTimeoutSeconds) seconds
            tell application "Terminal"
                set targetWindowId to missing value
                set targetTabIndex to 0
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        try
                            if (tty of t as string) is \(ttyLiteral) then
                                set targetWindowId to id of w
                                set targetTabIndex to i
                                exit repeat
                            end if
                        on error errMsg number errNum
                            if errNum is \(appleEventTimeoutError) then error errMsg number errNum
                        end try
                    end repeat
                    if targetWindowId is not missing value then exit repeat
                end repeat
                if targetWindowId is missing value then return "no_match"
                set targetWindow to window id targetWindowId
                set targetTab to tab targetTabIndex of targetWindow
                do script \(ProcessRunner.appleScriptQuote(text)) in targetTab
                set selected tab of targetWindow to targetTab
                set index of targetWindow to 1
                activate
                return "typed"
            end tell
        end timeout
        """
    }

    /// Checks Terminal is frontmost with the `devTTY` tab selected, then
    /// presses Return via System Events. System Events keystrokes go to
    /// whatever is frontmost, so the check runs immediately before sending —
    /// never a blind keystroke. Timeouts are re-raised (not read as "tab
    /// not selected", which would retry, or as a missing permission).
    static func terminalEnterScript(devTTY: String) -> String {
        let ttyLiteral = ProcessRunner.appleScriptQuote(devTTY)
        return """
        with timeout of \(appleScriptTimeoutSeconds) seconds
            tell application "Terminal"
                if not frontmost then return "not_frontmost"
                try
                    if (tty of selected tab of front window as string) is not \(ttyLiteral) then return "tab_not_selected"
                on error errMsg number errNum
                    if errNum is \(appleEventTimeoutError) then error errMsg number errNum
                    return "tab_not_selected"
                end try
            end tell
            try
                tell application "System Events" to tell process "Terminal" to key code 36
            on error errMsg number errNum
                if errNum is \(appleEventTimeoutError) then error errMsg number errNum
                return "ok_no_enter " & errNum & ": " & errMsg
            end try
            return "ok"
        end timeout
        """
    }

    /// Phone-facing outcome of the verify-then-Return script.
    static func terminalEnterOutcome(result: String, error: String, shortTTY: String) -> CodexDeliveryOutcome {
        switch result {
        case "ok":
            return CodexDeliveryOutcome(method: Method.terminal, success: true,
                                        detail: "Typed into Terminal tab \(shortTTY)", output: nil)
        case "not_frontmost", "tab_not_selected":
            return .failure("Typed into Terminal tab \(shortTTY), but another window took focus before Return — press Return on the Mac",
                            method: Method.terminal, output: result)
        case "" where error.hasPrefix(appleEventTimeoutError):
            return .failure("Typed into Terminal tab \(shortTTY), but Terminal didn't respond before Return — check it on the Mac",
                            method: Method.terminal, output: error)
        default:
            // "ok_no_enter …" is a failure: the text sits in the composer
            // unsent. Most often Accessibility permission is missing.
            return .failure("Typed into Terminal tab \(shortTTY), but Page needs Accessibility permission to press Return — press it on the Mac",
                            method: Method.terminal, output: result.isEmpty ? error : result)
        }
    }

    static func appleScriptFailureDetail(_ error: String) -> String {
        if error.hasPrefix("-1743") {
            return "Page isn't allowed to control Terminal — allow it in System Settings › Privacy & Security › Automation"
        }
        if error.hasPrefix(appleEventTimeoutError) {
            return "Terminal didn't respond — check it on the Mac before replying again"
        }
        return "Couldn't type into Terminal"
    }

    /// NSAppleScript runs in-process so TCC attributes Automation and
    /// Accessibility to Page itself (a spawned `osascript` would be the
    /// subject instead, ignoring the user's grant). It isn't thread-safe, so
    /// run it on the main thread; the scripts are short and every Apple
    /// event in them is bounded by `appleScriptTimeoutSeconds` (the pause
    /// between them happens on the caller's queue).
    private static func runAppleScript(_ source: String) -> (result: String, error: String) {
        let work = { () -> (String, String) in
            guard let script = NSAppleScript(source: source) else { return ("", "NSAppleScript init failed") }
            var errorDict: NSDictionary?
            let descriptor = script.executeAndReturnError(&errorDict)
            if let err = errorDict {
                let msg = (err[NSAppleScript.errorMessage] as? String) ?? "\(err)"
                let num = (err[NSAppleScript.errorNumber] as? Int) ?? 0
                return ("", "\(num): \(msg)")
            }
            return ((descriptor.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    // MARK: exec resume

    /// Marker in `codex exec`'s refusal outside a trusted git repo. Seeing it
    /// also proves this codex build knows `--skip-git-repo-check`, so we only
    /// add the flag when the CLI itself asks for it.
    static let gitRepoCheckMarker = "--skip-git-repo-check"

    static func execResumeArguments(threadId: String, text: String, skipGitRepoCheck: Bool) -> [String] {
        // `--skip-git-repo-check` is an `exec` option, so it goes before the
        // `resume` subcommand.
        (skipGitRepoCheck ? ["exec", gitRepoCheckMarker] : ["exec"]) + ["resume", threadId, text]
    }

    private static func execResume(text: String, threadId: String, cwd: String, codexPath: String) -> CodexDeliveryOutcome {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return .failure("The Codex session's folder no longer exists", method: Method.execResume)
        }
        guard let codex = ProcessRunner.findExecutable("codex", configured: codexPath) else {
            return .failure("Couldn't find the codex CLI to resume the session", method: Method.execResume)
        }
        let env = ProcessRunner.augmentedEnvironment()
        Logger.shared.log("CodexInjector: exec resume thread=\(threadId.prefix(8)) cwd=\(cwd)")
        var result = ProcessRunner.run(codex, execResumeArguments(threadId: threadId, text: text, skipGitRepoCheck: false),
                                       timeout: 15 * 60, environment: env, currentDirectory: cwd)
        if !result.succeeded, (result.stderr + result.stdout).contains(gitRepoCheckMarker) {
            Logger.shared.log("CodexInjector: exec refused outside a trusted repo — retrying with \(gitRepoCheckMarker)")
            result = ProcessRunner.run(codex, execResumeArguments(threadId: threadId, text: text, skipGitRepoCheck: true),
                                       timeout: 15 * 60, environment: env, currentDirectory: cwd)
        }
        let logName = writeExecLog(threadId: threadId, result: result)
        Logger.shared.log("CodexInjector: exec resume status=\(result.status) timedOut=\(result.timedOut) log=\(logName ?? "-")")
        if result.succeeded {
            return CodexDeliveryOutcome(method: Method.execResume, success: true,
                                        detail: "Codex wasn't open — sent via background resume",
                                        output: logName.map { "log: \($0)" })
        }
        let why = result.timedOut ? "timed out" : (result.launched ? "exit \(result.status)" : "couldn't launch codex")
        return .failure("Background Codex resume failed (\(why))", method: Method.execResume,
                        output: String((result.stderr.isEmpty ? result.stdout : result.stderr).suffix(280)))
    }

    private static func writeExecLog(threadId: String, result: ProcessRunner.Result) -> String? {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Page-codex-replies", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("\(df.string(from: Date()))-\(threadId.prefix(8)).log")
        let body = "status=\(result.status) timedOut=\(result.timedOut)\n--- stdout ---\n\(result.stdout)\n--- stderr ---\n\(result.stderr)\n"
        do {
            try Data(body.utf8).write(to: url)
            return url.lastPathComponent
        } catch {
            return nil
        }
    }
}
