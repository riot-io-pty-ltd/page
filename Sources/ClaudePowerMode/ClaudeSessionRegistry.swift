import Foundation

/// What a live Claude Code process says it is doing, from
/// `~/.claude/sessions/<pid>.json`.
enum ClaudeSessionStatus: String, Equatable {
    /// A turn is running. Text + Enter queues a message; Esc would interrupt.
    case busy
    /// A permission / question select-menu is on screen. Letters are ignored
    /// and Enter accepts the highlighted option, so never send Enter here.
    case waiting
    /// Turn finished; the input box is focused.
    case idle
    /// Turn finished with a background shell still running (Claude Code
    /// 2.1.3xx writes "shell"). The input box is focused, so typing works as
    /// for idle; Claude may start a turn by itself when the shell ends.
    case shell
    /// No sessions file (older Claude Code) or a status value we don't know.
    case unknown

    init(raw: String?) {
        switch raw?.lowercased() {
        case "busy": self = .busy
        case "waiting": self = .waiting
        case "idle": self = .idle
        case "shell": self = .shell
        default: self = .unknown
        }
    }
}

/// One decoded `~/.claude/sessions/<pid>.json`. The format is undocumented,
/// so every field is optional and unknown fields are ignored.
struct ClaudeSessionRecord: Equatable {
    var pid: Int32?
    var sessionId: String?
    var cwd: String?
    var status: String?
    var statusUpdatedAt: Date?
    var kind: String?
    var entrypoint: String?
    /// When the Claude Code process started the session (`startedAt`, ms).
    var startedAt: Date?
    /// The session's own name (`name`): what Claude Code calls it, often the folder.
    var name: String?
}

/// A Claude Code process that is running right now, with the session it hosts.
struct ClaudeLiveSession: Equatable {
    let pid: Int32
    let sessionId: String
    let cwd: String?
    let status: ClaudeSessionStatus
    /// When `status` last changed. nil for argv-discovered sessions.
    let statusUpdatedAt: Date?
    /// Controlling terminal as ps prints it ("ttys003"), nil if none.
    let tty: String?
    /// False when found only by a UUID in argv (Claude Code too old to write
    /// a sessions file). Status is then `.unknown`.
    let hasSessionFile: Bool
    /// Model provider, from the process's environment and the session's
    /// settings files (`ModelProviderClassifier.claude`). `.unknown` until
    /// the registry fills it in, or when the environment can't be read.
    var provider: ModelProvider = .unknown
    /// When this Claude Code process started the session. nil without a sessions file.
    var startedAt: Date? = nil
    /// The session's own name from the sessions file, if it has one.
    var name: String? = nil

    var devTTY: String? { tty.map { "/dev/" + $0 } }
}

/// Discovers live Claude Code sessions and their transcripts.
///
/// Source of truth is `~/.claude/sessions/<pid>.json`, which interactive
/// Claude Code (v2.1+) keeps up to date with the session id, cwd and a
/// busy/waiting/idle status. Those files outlive a crash, and pids get
/// reused, so a record only counts when its pid is alive AND that pid's
/// command line mentions claude. Older Claude Code doesn't write the file;
/// for those we fall back to a `claude --resume <uuid>` / `--session-id <uuid>`
/// argv match (bare `claude` launches can't be identified that way).
///
/// Thread-safe: every method may be called from any queue.
final class ClaudeSessionRegistry {
    private let sessionsDirectory: String
    private let lock = NSLock()
    private var projectsDirectory: String
    private var lastSessions: [ClaudeLiveSession] = []
    /// sessionId → transcript path. Validated with a stat on every use.
    private var transcriptCache: [String: URL] = [:]
    /// sessionId → when a full search last failed, so a session whose
    /// transcript doesn't exist yet doesn't trigger a directory sweep per tick.
    private var transcriptMisses: [String: Date] = [:]
    private let missRetryInterval: TimeInterval = 60

    /// Provider of a live process (pid, cwd). Reads its environment
    /// (`ProcArgs`), so it runs once per process: see `providerCache`.
    typealias ProviderResolver = (_ pid: Int32, _ cwd: String?) -> ModelProvider
    private let resolveProvider: ProviderResolver
    private let startSeconds: (Int32) -> Int?
    private let recordProvider: (_ sessionId: String, _ provider: ModelProvider) -> Void
    /// pid → provider of the process with that pid and start time, and the
    /// session last recorded for it. A recycled pid has a new start time.
    private var providerCache: [Int32: (start: Int?, provider: ModelProvider, recordedSession: String?)] = [:]
    /// When set, providers are resolved here instead of on the caller's
    /// (tick) queue. Resolving reads settings files in the session's
    /// project, and a file read can block — on a network mount, or behind a
    /// macOS privacy prompt — which must never stall keep-awake. Until a
    /// result lands the session's provider is `.unknown` (fails closed).
    private let resolverQueue: DispatchQueue?
    /// (pid, start) resolutions queued or running (under `lock`).
    private var pendingResolutions: Set<String> = []

    init(projectsDirectory: String, sessionsDirectory: String = "~/.claude/sessions",
         resolveProvider: @escaping ProviderResolver = ClaudeSessionRegistry.liveProvider,
         startSeconds: @escaping (Int32) -> Int? = CmuxBridge.processStartSeconds,
         recordProvider: @escaping (String, ModelProvider) -> Void = { SessionProviderStore.record(sessionId: $0, provider: $1) },
         resolverQueue: DispatchQueue? = nil) {
        self.projectsDirectory = (projectsDirectory as NSString).expandingTildeInPath
        self.sessionsDirectory = (sessionsDirectory as NSString).expandingTildeInPath
        self.resolveProvider = resolveProvider
        self.startSeconds = startSeconds
        self.recordProvider = recordProvider
        self.resolverQueue = resolverQueue
    }

    /// Default resolver: the process's allowlisted environment and argv
    /// (`ProcArgs`; only a `--settings` value is looked at, then both are
    /// dropped) plus the settings files for its cwd. `.unknown` when the
    /// environment, the cwd or a `--settings` file can't be read.
    static func liveProvider(pid: Int32, cwd: String?) -> ModelProvider {
        guard let info = ProcArgs.read(pid: pid, envKeys: ModelProviderClassifier.claudeProcessEnvKeys) else { return .unknown }
        return ModelProviderClassifier.claudeLive(argv: info.argv, env: info.env, cwd: cwd)
    }

    /// Fills in `provider` for each session, classifying a process only the
    /// first time its (pid, start time) is seen, and records the provider
    /// in `SessionProviderStore` (once per session per process). An
    /// `.unknown` is recorded too: it clears what an earlier process of the
    /// same session left there, which no longer describes this run.
    /// `prune` drops cache entries for processes no longer in `sessions`.
    func annotateProviders(_ sessions: [ClaudeLiveSession], prune: Bool = false) -> [ClaudeLiveSession] {
        guard !sessions.isEmpty || prune else { return sessions }
        let starts = Dictionary(sessions.map { ($0.pid, startSeconds($0.pid)) }, uniquingKeysWith: { a, _ in a })
        lock.lock()
        let cache = providerCache
        lock.unlock()

        var updated = cache
        if prune { updated = updated.filter { starts[$0.key] != nil } }
        // Only what this pass decided is written back, so a background
        // resolution that lands meanwhile isn't overwritten by the snapshot.
        var changed: Set<Int32> = prune ? Set(cache.keys).subtracting(updated.keys) : []
        var toRecord: [(String, ModelProvider)] = []
        let result = sessions.map { s -> ClaudeLiveSession in
            let start = starts[s.pid] ?? nil
            var entry: (start: Int?, provider: ModelProvider, recordedSession: String?)
            if let hit = updated[s.pid], hit.start == start, start != nil {
                entry = hit
            } else if resolverQueue != nil {
                // Off the caller's queue; `.unknown` and nothing recorded
                // until the result is cached (a later pass records it).
                if let start { resolveInBackground(pid: s.pid, start: start, cwd: s.cwd) }
                var copy = s
                copy.provider = .unknown
                return copy
            } else {
                entry = (start, resolveProvider(s.pid, s.cwd), nil)
            }
            if entry.recordedSession != s.sessionId {
                toRecord.append((s.sessionId, entry.provider))
                entry.recordedSession = s.sessionId
            }
            // Without a start time a recycled pid can't be told apart, so
            // nothing is cached for it.
            if start != nil { updated[s.pid] = entry } else { updated[s.pid] = nil }
            changed.insert(s.pid)
            var copy = s
            copy.provider = entry.provider
            return copy
        }
        lock.lock()
        for pid in changed { providerCache[pid] = updated[pid] }
        // Bounded: one entry per live Claude process in practice.
        if providerCache.count > 256 { providerCache = [:] }
        lock.unlock()
        for (sid, provider) in toRecord { recordProvider(sid, provider) }
        return result
    }

    private func resolveInBackground(pid: Int32, start: Int, cwd: String?) {
        guard let queue = resolverQueue else { return }
        let key = "\(pid):\(start)"
        lock.lock()
        let inserted = pendingResolutions.insert(key).inserted
        lock.unlock()
        guard inserted else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let provider = self.resolveProvider(pid, cwd)
            self.lock.lock()
            self.pendingResolutions.remove(key)
            if self.providerCache.count > 256 { self.providerCache = [:] }
            self.providerCache[pid] = (start, provider, nil)
            self.lock.unlock()
        }
    }

    func setProjectsDirectory(_ dir: String) {
        let expanded = (dir as NSString).expandingTildeInPath
        lock.lock()
        defer { lock.unlock() }
        guard expanded != projectsDirectory else { return }
        projectsDirectory = expanded
        transcriptCache.removeAll()
        transcriptMisses.removeAll()
    }

    /// Sessions found by the most recent `refresh`.
    var sessions: [ClaudeLiveSession] {
        lock.lock()
        defer { lock.unlock() }
        return lastSessions
    }

    /// Re-reads the sessions directory and validates every record against
    /// `processTable` (one `ProcessRunner.processTable()` snapshot, shared
    /// with the rest of the tick).
    @discardableResult
    func refresh(processTable: [ProcessRunner.ProcessInfoRow]) -> [ClaudeLiveSession] {
        let live = annotateProviders(Self.buildLiveSessions(
            records: readRecords(),
            processTable: processTable,
            ownPid: ProcessInfo.processInfo.processIdentifier,
            isAlive: ProcessRunner.isAlive
        ), prune: true)
        lock.lock()
        lastSessions = live
        lock.unlock()
        return live
    }

    /// Fresh read (not the cached tick value) of the live processes hosting
    /// `sessionId`. Used right before injecting so we never act on a status
    /// that's up to a tick old. Normally one element; the same session can be
    /// open in two processes (e.g. a headless bridge plus a terminal).
    func liveSessions(forSessionId sessionId: String,
                      processTable: [ProcessRunner.ProcessInfoRow]? = nil) -> [ClaudeLiveSession] {
        let table = processTable ?? ProcessRunner.processTable()
        return annotateProviders(Self.buildLiveSessions(
            records: readRecords(),
            processTable: table,
            ownPid: ProcessInfo.processInfo.processIdentifier,
            isAlive: ProcessRunner.isAlive
        ).filter { $0.sessionId == sessionId })
    }

    /// Fresh read of every live session (does not replace the tick's
    /// cached `sessions`). Used by the low-battery pause, which must act on
    /// statuses as they are now.
    func allLiveSessions(processTable: [ProcessRunner.ProcessInfoRow]) -> [ClaudeLiveSession] {
        annotateProviders(Self.buildLiveSessions(
            records: readRecords(),
            processTable: processTable,
            ownPid: ProcessInfo.processInfo.processIdentifier,
            isAlive: ProcessRunner.isAlive
        ))
    }

    /// Pids of live Claude Code processes whose sessions file says they own
    /// `sessionId` but that aren't interactive (kind "bg", "daemon", …).
    /// They have no prompt to type into, so `liveSessions` leaves them out —
    /// but the session is not ended either: a background resume would be a
    /// second writer on the conversation.
    func liveBackgroundOwnerPids(forSessionId sessionId: String,
                                 processTable: [ProcessRunner.ProcessInfoRow]) -> [Int32] {
        Self.backgroundOwnerPids(records: readRecords(), sessionId: sessionId, processTable: processTable,
                                 ownPid: ProcessInfo.processInfo.processIdentifier, isAlive: ProcessRunner.isAlive)
    }

    /// Pure helper for `liveBackgroundOwnerPids` (unit-tested). Same
    /// liveness rule as `buildLiveSessions`: pid in the snapshot with a
    /// claude command line (or, with no snapshot, answering kill(pid, 0)).
    static func backgroundOwnerPids(records: [ClaudeSessionRecord],
                                    sessionId: String,
                                    processTable: [ProcessRunner.ProcessInfoRow],
                                    ownPid: Int32,
                                    isAlive: (Int32) -> Bool) -> [Int32] {
        var rowsByPid: [Int32: ProcessRunner.ProcessInfoRow] = [:]
        for row in processTable { rowsByPid[row.pid] = row }
        let sid = sessionId.lowercased()
        var pids: [Int32] = []
        for r in records {
            guard let pid = r.pid, pid > 0, pid != ownPid,
                  r.sessionId?.lowercased() == sid,
                  let kind = r.kind, !kind.isEmpty, kind != "interactive" else { continue }
            if processTable.isEmpty {
                guard isAlive(pid) else { continue }
            } else {
                guard let row = rowsByPid[pid], isClaudeCommand(row.command) else { continue }
            }
            if !pids.contains(pid) { pids.append(pid) }
        }
        return pids.sorted()
    }

    /// Current status of one pid, straight from its sessions file. Cheap
    /// (one small file read); used to confirm a keystroke took effect.
    func currentRecord(forPid pid: Int32) -> ClaudeSessionRecord? {
        let url = URL(fileURLWithPath: sessionsDirectory).appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.parseSessionFile(data)
    }

    // MARK: transcripts

    /// Locates `<projects>/<encoded-cwd>/<sessionId>.jsonl`. Tries the
    /// directory Claude Code derives from the cwd first, then sweeps every
    /// project directory (a session's cwd can differ from where it started).
    func transcriptURL(forSessionId sessionId: String, cwdHint: String?) -> URL? {
        guard Self.isValidSessionId(sessionId) else { return nil }
        let fm = FileManager.default
        lock.lock()
        let projects = projectsDirectory
        let cached = transcriptCache[sessionId]
        let lastMiss = transcriptMisses[sessionId]
        lock.unlock()

        if let cached, fm.fileExists(atPath: cached.path) { return cached }

        let fileName = sessionId + ".jsonl"
        let base = URL(fileURLWithPath: projects, isDirectory: true)
        var found: URL?
        if let cwd = cwdHint, !cwd.isEmpty {
            let guess = base.appendingPathComponent(Self.encodedProjectDirName(forCwd: cwd))
                .appendingPathComponent(fileName)
            if fm.fileExists(atPath: guess.path) { found = guess }
        }
        if found == nil {
            if let lastMiss, Date().timeIntervalSince(lastMiss) < missRetryInterval { return nil }
            let dirs = (try? fm.contentsOfDirectory(atPath: projects)) ?? []
            for dir in dirs where !dir.hasPrefix(".") {
                let candidate = base.appendingPathComponent(dir).appendingPathComponent(fileName)
                if fm.fileExists(atPath: candidate.path) { found = candidate; break }
            }
        }

        lock.lock()
        if let found {
            transcriptCache[sessionId] = found
            transcriptMisses.removeValue(forKey: sessionId)
        } else {
            transcriptCache.removeValue(forKey: sessionId)
            transcriptMisses[sessionId] = Date()
        }
        lock.unlock()
        return found
    }

    // MARK: IO

    private func readRecords() -> [ClaudeSessionRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDirectory) else { return [] }
        var records: [ClaudeSessionRecord] = []
        for name in names where name.hasSuffix(".json") {
            let url = URL(fileURLWithPath: sessionsDirectory).appendingPathComponent(name)
            // Files are ~1 KB; anything huge isn't a sessions record.
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.intValue > 256 * 1024 { continue }
            guard let data = try? Data(contentsOf: url),
                  var record = Self.parseSessionFile(data) else { continue }
            // The file name is the pid; trust it when the body omits one.
            if record.pid == nil, let pid = Int32(name.dropLast(5)) { record.pid = pid }
            records.append(record)
        }
        return records
    }

    // MARK: pure helpers (unit-tested)

    /// Decodes one sessions file. Returns nil only for non-JSON / non-object
    /// input; every field is optional and wrongly typed fields are dropped.
    static func parseSessionFile(_ data: Data) -> ClaudeSessionRecord? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var r = ClaudeSessionRecord()
        if let n = obj["pid"] as? NSNumber, !(obj["pid"] is Bool) { r.pid = Int32(truncatingIfNeeded: n.int64Value) }
        r.sessionId = (obj["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        r.cwd = (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        r.status = obj["status"] as? String
        if let ms = obj["statusUpdatedAt"] as? NSNumber, !(obj["statusUpdatedAt"] is Bool), ms.doubleValue > 0 {
            r.statusUpdatedAt = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        }
        r.kind = obj["kind"] as? String
        r.entrypoint = obj["entrypoint"] as? String
        if let ms = obj["startedAt"] as? NSNumber, !(obj["startedAt"] is Bool), ms.doubleValue > 0 {
            r.startedAt = Date(timeIntervalSince1970: ms.doubleValue / 1000)
        }
        r.name = (obj["name"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : String($0.prefix(120)) }
        return r
    }

    /// Joins sessions-file records with a process-table snapshot.
    ///
    /// A record is live when its pid is in the snapshot (or, if ps failed,
    /// answers kill(pid, 0)) and the command mentions claude — a crashed
    /// session's file plus a recycled pid must not resurrect it. Claude
    /// processes not covered by any record are matched by a session UUID in
    /// argv (older Claude Code).
    static func buildLiveSessions(records: [ClaudeSessionRecord],
                                  processTable: [ProcessRunner.ProcessInfoRow],
                                  ownPid: Int32,
                                  isAlive: (Int32) -> Bool) -> [ClaudeLiveSession] {
        var rowsByPid: [Int32: ProcessRunner.ProcessInfoRow] = [:]
        for row in processTable { rowsByPid[row.pid] = row }
        let haveTable = !processTable.isEmpty

        var result: [ClaudeLiveSession] = []
        var coveredPids = Set<Int32>()
        for r in records {
            guard let pid = r.pid, pid > 0, pid != ownPid,
                  let sid = r.sessionId, isValidSessionId(sid) else { continue }
            // Non-interactive kinds (background jobs: "bg", "daemon", …)
            // have no prompt to answer; `backgroundOwnerPids` reports them
            // so they still count as owning their session.
            if let kind = r.kind, !kind.isEmpty, kind != "interactive" { continue }
            guard !coveredPids.contains(pid) else { continue }
            let row = rowsByPid[pid]
            if haveTable {
                guard let row, isClaudeCommand(row.command) else { continue }
            } else {
                guard isAlive(pid) else { continue }
            }
            coveredPids.insert(pid)
            result.append(ClaudeLiveSession(
                pid: pid,
                sessionId: sid,
                cwd: r.cwd,
                status: ClaudeSessionStatus(raw: r.status),
                statusUpdatedAt: r.statusUpdatedAt,
                tty: row.flatMap { normalizedTTY($0.tty) },
                hasSessionFile: true,
                startedAt: r.startedAt,
                name: r.name
            ))
        }

        for row in processTable where !coveredPids.contains(row.pid) && row.pid != ownPid {
            // Only interactive CLIs: a headless `claude --print` has no tty
            // and no prompt to answer.
            guard let tty = normalizedTTY(row.tty),
                  isClaudeExecutable(row.command),
                  let sid = sessionIdInArgv(row.command) else { continue }
            coveredPids.insert(row.pid)
            result.append(ClaudeLiveSession(
                pid: row.pid,
                sessionId: sid,
                cwd: nil,
                status: .unknown,
                statusUpdatedAt: nil,
                tty: tty,
                hasSessionFile: false
            ))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// Loose check used to validate a sessions-file pid: the process's
    /// command line mentions claude (covers `claude`, `node …/claude-code/cli.js`
    /// and versioned binaries) and isn't one of our own helpers.
    static func isClaudeCommand(_ command: String) -> Bool {
        let lower = command.lowercased()
        guard lower.contains("claude") else { return false }
        return !(command.contains("ClaudePowerMode") || command.contains("page-notify"))
    }

    /// Strict check used for argv discovery: argv[0]'s basename is `claude`.
    /// `pgrep -f claude` style matching would also hit hook scripts and
    /// `tail -F /tmp/claude-…` shells.
    static func isClaudeExecutable(_ command: String) -> Bool {
        guard let exe = command.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first else {
            return false
        }
        return (String(exe) as NSString).lastPathComponent == "claude"
    }

    /// The session UUID passed via `--resume`/`-r`/`--session-id` (either
    /// `--flag value` or `--flag=value`). Other UUIDs in argv (e.g. inside
    /// `--settings {json}`) are ignored on purpose.
    static func sessionIdInArgv(_ command: String) -> String? {
        let tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let flags: Set<String> = ["--resume", "-r", "--session-id"]
        for (i, tok) in tokens.enumerated() {
            if flags.contains(tok), i + 1 < tokens.count, isValidSessionId(tokens[i + 1]) {
                return tokens[i + 1].lowercased()
            }
            if let eq = tok.firstIndex(of: "="), flags.contains(String(tok[..<eq])) {
                let value = String(tok[tok.index(after: eq)...])
                if isValidSessionId(value) { return value.lowercased() }
            }
        }
        return nil
    }

    private static let uuidRegex = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    )

    /// Session ids are UUIDs. Anything else (from a relay payload, say) is
    /// refused before it reaches a path or an argv.
    static func isValidSessionId(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: (s as NSString).length)
        return uuidRegex.firstMatch(in: s, range: range) != nil
    }

    /// ps prints "??" (or "-") for processes without a controlling terminal.
    static func normalizedTTY(_ raw: String) -> String? {
        let t = raw.hasPrefix("/dev/") ? String(raw.dropFirst(5)) : raw
        if t.isEmpty || t == "??" || t == "-" { return nil }
        return t
    }

    /// Claude Code's project directory name for a cwd: every character
    /// outside [A-Za-z0-9-] becomes "-" ("/Users/me/my.app" → "-Users-me-my-app").
    static func encodedProjectDirName(forCwd cwd: String) -> String {
        String(cwd.unicodeScalars.map { scalar -> Character in
            let v = scalar.value
            let isAlnum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            return (isAlnum || scalar == "-") ? Character(scalar) : "-"
        })
    }
}
