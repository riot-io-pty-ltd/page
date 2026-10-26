import Foundation

/// Claude Squad (`cs`, smtg-ai/claude-squad) support.
///
/// Each Claude Squad agent is an ordinary tmux session on the default tmux
/// server (`claudesquad_<title>`), so Page's tmux path already finds it and
/// types into the right pane. What Claude Squad adds is its own state in
/// `~/.claude-squad/`:
///
///   - `state.json`: the instances (title, status, program, auto_yes and the
///     git worktree each one runs in). Written only when something is saved,
///     not live.
///   - `config.json`: its settings.
///   - `daemon.pid`: a hidden `cs --daemon` that, while alive, forces
///     auto-yes on every instance and presses Enter on permission prompts.
///
/// Page uses it for three things: label the pane "Claude Squad", leave a
/// paused instance alone (Claude Squad deletes its worktree but the agent
/// process keeps running in a folder that no longer exists), and not page for
/// an approval Claude Squad is about to give by itself.
///
/// Everything that decides is pure; the small I/O wrappers at the bottom read
/// the files and never throw (missing or garbled file: nil).
enum ClaudeSquad {
    /// What the phone shows as the session's host.
    static let hostName = "Claude Squad"
    /// The phone's reason for a paused instance (typing is refused).
    static let pausedMessage = "Paused in Claude Squad"
    /// tmux session names of the agents; the shell tabs add `term_`.
    static let sessionPrefix = "claudesquad_"
    static let shellPrefix = "claudesquad_term_"
    /// `Instance.status` for a paused instance (0 running, 1 ready, 2 loading).
    static let pausedStatus = 3

    /// Where Claude Squad keeps its files (tests point this at a temp dir).
    static var directory: String = NSHomeDirectory() + "/.claude-squad"
    /// Where it puts the git worktrees its agents run in.
    static var worktreesRoot: String { directory + "/worktrees" }

    // MARK: model

    struct Instance: Equatable {
        var title: String
        var path: String
        var branch: String
        var status: Int
        var program: String
        var autoYes: Bool
        /// `worktree.worktree_path`: the folder the agent was started in.
        var worktreePath: String
        /// `worktree.session_name`.
        var sessionName: String
    }

    struct Config: Equatable {
        var autoYes: Bool
        var defaultProgram: String
    }

    /// Everything read from `~/.claude-squad/`.
    struct Snapshot: Equatable {
        var instances: [Instance]
        var config: Config?
        /// `cs --daemon` is running (so every instance is on auto-yes).
        var daemonAlive: Bool
        /// A `claude-squad` terminal UI is running (it presses Enter for instances
        /// that have auto-yes on, while it is open).
        var tuiRunning: Bool
    }

    /// What Page knows about a session that belongs to Claude Squad.
    struct Standing: Equatable {
        var instance: Instance?
        var paused: Bool
        /// Claude Squad will approve this session's permission prompts itself.
        var autoApproves: Bool
    }

    // MARK: parsing (pure)

    /// Pure. `state.json` → its instances. nil when the file isn't JSON of
    /// the expected shape; an instance without a title is skipped.
    static func parseState(_ data: Data?) -> [Instance]? {
        guard let data,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = root["instances"] as? [Any] else { return nil }
        var out: [Instance] = []
        for item in list {
            guard let d = item as? [String: Any], let title = d["title"] as? String, !title.isEmpty else { continue }
            let worktree = d["worktree"] as? [String: Any] ?? [:]
            out.append(Instance(
                title: title,
                path: d["path"] as? String ?? "",
                branch: d["branch"] as? String ?? "",
                status: (d["status"] as? NSNumber)?.intValue ?? -1,
                program: d["program"] as? String ?? "",
                autoYes: (d["auto_yes"] as? NSNumber)?.boolValue ?? false,
                worktreePath: worktree["worktree_path"] as? String ?? "",
                sessionName: worktree["session_name"] as? String ?? ""))
        }
        return out
    }

    /// Pure. `config.json` → the two settings Page cares about. nil when the
    /// file isn't a JSON object.
    static func parseConfig(_ data: Data?) -> Config? {
        guard let data, let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return Config(autoYes: (root["auto_yes"] as? NSNumber)?.boolValue ?? false,
                      defaultProgram: root["default_program"] as? String ?? "")
    }

    /// Pure. `daemon.pid` → a pid worth checking (a plain number above 1).
    static func parseDaemonPid(_ data: Data?) -> Int32? {
        guard let data, let text = String(data: data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else { return nil }
        return pid
    }

    // MARK: sessions and instances (pure)

    /// Pure. Whether a tmux session name is a Claude Squad agent. The shell
    /// tabs (`claudesquad_term_<title>`) are plain shells, not agents.
    static func isSquadSession(_ name: String) -> Bool {
        name.hasPrefix(sessionPrefix) && name.count > sessionPrefix.count && !name.hasPrefix(shellPrefix)
    }

    /// Pure. The tmux session Claude Squad names for a title: whitespace
    /// removed, "." (and ":", which tmux also rewrites) turned into "_".
    static func tmuxName(forTitle title: String) -> String {
        let cleaned = title.components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return sessionPrefix + cleaned
    }

    /// Pure. The instance behind a tmux session name. Matches the name
    /// Claude Squad derives from the title, or the one stored in the
    /// worktree record (with or without the prefix).
    static func instance(forSession name: String, in instances: [Instance]) -> Instance? {
        guard isSquadSession(name) else { return nil }
        return instances.first { i in
            if tmuxName(forTitle: i.title) == name { return true }
            guard !i.sessionName.isEmpty else { return false }
            return i.sessionName == name || tmuxName(forTitle: i.sessionName) == name
        }
    }

    /// Pure. The instance whose worktree is `cwd` (or a folder inside it).
    static func instance(forCwd cwd: String, in instances: [Instance]) -> Instance? {
        let dir = normalized(cwd)
        guard !dir.isEmpty else { return nil }
        return instances.first { i in
            guard !i.worktreePath.isEmpty else { return false }
            let wt = normalized(i.worktreePath)
            return dir == wt || dir.hasPrefix(wt + "/")
        }
    }

    /// Pure. Whether `cwd` is inside Claude Squad's worktrees folder (a path
    /// component match: `worktrees-old/x` is not).
    static func isInWorktrees(_ cwd: String, root: String? = nil) -> Bool {
        let dir = normalized(cwd)
        let base = normalized(root ?? worktreesRoot)
        let resolved = (base as NSString).resolvingSymlinksInPath
        return [base, resolved].contains { dir.hasPrefix($0 + "/") && dir.count > $0.count + 1 }
    }

    /// Pure. A paused instance. Pausing deletes the worktree and leaves the
    /// agent process running in a folder that no longer exists, so for a
    /// session inside the worktrees folder the folder decides: gone is
    /// paused, there is not (`state.json` is only written on save events, so
    /// a stale "paused" can outlive a resume). Claude Squad's own status 3
    /// is only used when the folder can't say (working folder unknown or
    /// outside the worktrees folder).
    static func isPaused(cwd: String?, instance: Instance?, cwdExists: (String) -> Bool,
                         worktreesRoot: String? = nil) -> Bool {
        if let cwd, !cwd.isEmpty, isInWorktrees(cwd, root: worktreesRoot) { return !cwdExists(cwd) }
        return instance?.status == pausedStatus
    }

    /// Pure. Whether Claude Squad types the approval itself for this
    /// instance: it matches the prompt only when the program is exactly
    /// `claude` (or starts with `aider` / `gemini`), so `claude --model x`
    /// is not approved. Someone has to be pressing Enter: the daemon (which
    /// switches auto-yes on for every instance), or an open `cs` terminal UI
    /// for an instance saved with auto-yes. Anything unknown is false: Page
    /// then pages, which is the safe side.
    static func autoApproves(instance: Instance?, daemonAlive: Bool, tuiRunning: Bool = false) -> Bool {
        guard let instance, instance.status != pausedStatus, programAutoApproves(instance.program) else { return false }
        return daemonAlive || (instance.autoYes && tuiRunning)
    }

    /// Pure. The programs Claude Squad's prompt matching covers.
    static func programAutoApproves(_ program: String) -> Bool {
        let p = program.trimmingCharacters(in: .whitespaces)
        return p == "claude" || p.hasPrefix("aider") || p.hasPrefix("gemini")
    }

    /// Pure. What Page knows about a session, from its tmux session name
    /// (the pane's, when known) and its working folder. nil: not Claude
    /// Squad's. A session counts when its tmux session is a squad agent, or
    /// it runs inside the squad worktrees folder.
    static func standing(sessionName: String?, cwd: String?, snapshot: Snapshot?, cwdExists: (String) -> Bool,
                         worktreesRoot: String? = nil) -> Standing? {
        let named = sessionName.map(isSquadSession) ?? false
        let inWorktrees = cwd.map { isInWorktrees($0, root: worktreesRoot) } ?? false
        guard named || inWorktrees else { return nil }
        let instances = snapshot?.instances ?? []
        var found: Instance?
        if named, let sessionName { found = instance(forSession: sessionName, in: instances) }
        if found == nil, let cwd { found = instance(forCwd: cwd, in: instances) }
        let paused = isPaused(cwd: cwd, instance: found, cwdExists: cwdExists, worktreesRoot: worktreesRoot)
        let approves = !paused && autoApproves(instance: found, daemonAlive: snapshot?.daemonAlive ?? false,
                                               tuiRunning: snapshot?.tuiRunning ?? false)
        return Standing(instance: found, paused: paused, autoApproves: approves)
    }

    /// Pure. Which process a `ps` command line is: the hidden daemon
    /// (`cs --daemon`), the terminal UI, or neither. `cs` is also the name
    /// of other tools (Scala's coursier), so a bare `cs` is never taken for
    /// the terminal UI; only `claude-squad` is. (The daemon is also checked
    /// against `daemon.pid`.)
    enum ProcessKind: Equatable { case daemon, interactive }
    static func processKind(command: String) -> ProcessKind? {
        let words = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first else { return nil }
        let exe = (first as NSString).lastPathComponent
        guard exe == "cs" || exe == "claude-squad" else { return nil }
        if words.dropFirst().contains("--daemon") { return .daemon }
        return exe == "claude-squad" ? .interactive : nil
    }

    /// Pure. The daemon is alive when the pid in `daemon.pid` is a running
    /// `cs --daemon` in the process table (a recycled pid isn't).
    static func daemonIsRunning(pid: Int32?, table: [ProcessRunner.ProcessInfoRow]) -> Bool {
        guard let pid, let row = table.first(where: { $0.pid == pid }) else { return false }
        return processKind(command: row.command) == .daemon
    }

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: files (I/O)

    /// Reads `~/.claude-squad/`. nil when Claude Squad isn't set up (no
    /// folder), so people without it pay one stat. A file that is missing or
    /// garbled just leaves its part empty. `table`: this tick's process
    /// table, to tell a running daemon from a stale pid.
    static func loadSnapshot(table: [ProcessRunner.ProcessInfoRow]) -> Snapshot? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else { return nil }
        let instances = parseState(BoundedFileRead.read(directory + "/state.json")) ?? []
        let config = parseConfig(BoundedFileRead.read(directory + "/config.json"))
        let pid = parseDaemonPid(BoundedFileRead.read(directory + "/daemon.pid", maxBytes: 64))
        let daemon = pid.map { kill($0, 0) == 0 || errno == EPERM } == true && daemonIsRunning(pid: pid, table: table)
        let tui = table.contains { processKind(command: $0.command) == .interactive }
        return Snapshot(instances: instances, config: config, daemonAlive: daemon, tuiRunning: tui)
    }

    /// Pure. Whether `tty` is the pane of `instance`'s own agent tmux
    /// session in a `list-panes -F tmuxPaneListFormat` listing. A shell tab
    /// (`claudesquad_term_<title>`) or any other pane in the same worktree is
    /// not: Claude Squad only presses Enter in the agent's session.
    static func isAgentPane(of instance: Instance, tty: String?, listing: String) -> Bool {
        guard let tty, let name = InjectionExecutor.tmuxPane(forTTY: tty, listing: listing)?.session else { return false }
        return self.instance(forSession: name, in: [instance]) != nil
    }

    /// Where each session stands, by pid, for the sessions in Claude Squad's
    /// worktrees folder. Matches by working folder (Claude Squad starts the
    /// agent with `-c <worktree>`), so it costs no tmux call per tick; and
    /// nothing at all unless a session is in that folder. A session that
    /// would be auto-approved is trusted only when it is that instance's own
    /// agent pane (one tmux listing per tick, taken lazily): the same folder
    /// can hold a shell tab or another terminal running `claude`, and nothing
    /// presses Enter there. `paneListing`: tests pass a fake.
    static func liveStandings(sessions: [ClaudeLiveSession], table: [ProcessRunner.ProcessInfoRow],
                              paneListing: () -> String? = tmuxPaneListing) -> [Int32: Standing] {
        let candidates = sessions.filter { $0.cwd.map { isInWorktrees($0) } ?? false }
        guard !candidates.isEmpty, let snapshot = loadSnapshot(table: table) else { return [:] }
        var listing: String??
        var out: [Int32: Standing] = [:]
        for s in candidates {
            guard var st = standing(sessionName: nil, cwd: s.cwd, snapshot: snapshot, cwdExists: directoryExists) else { continue }
            if st.autoApproves, let instance = st.instance {
                if listing == nil { listing = .some(paneListing()) }
                if let text = listing ?? nil, isAgentPane(of: instance, tty: s.devTTY, listing: text) {
                    // Its own agent pane: Claude Squad answers there.
                } else {
                    st.autoApproves = false
                }
            }
            out[s.pid] = st
        }
        return out
    }

    /// `tmux list-panes -a` for `tmuxPaneListFormat`; nil without tmux or a
    /// running server.
    static func tmuxPaneListing() -> String? {
        guard let tmux = ProcessRunner.findExecutable("tmux") else { return nil }
        let r = ProcessRunner.run(tmux, ["list-panes", "-a", "-F", InjectionExecutor.tmuxPaneListFormat], timeout: 3)
        return r.succeeded ? r.stdout : nil
    }

    /// Whether this session's pane is a paused Claude Squad instance, read
    /// fresh. For the phone's host label and the typing gate.
    static func isPausedLive(session: ClaudeLiveSession, host: InjectionExecutor.TerminalHost) -> Bool {
        guard case .tmux(_, _, _, let name?) = host, isSquadSession(name) else { return false }
        let instances = parseState(BoundedFileRead.read(directory + "/state.json")) ?? []
        let snapshot = Snapshot(instances: instances, config: nil, daemonAlive: false, tuiRunning: false)
        return standing(sessionName: name, cwd: session.cwd, snapshot: snapshot, cwdExists: directoryExists)?.paused ?? false
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
