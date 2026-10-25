import Foundation

// Live sessions (docs/SESSIONS-PROTOCOL.md): what the Mac reports about each
// agent session, how the phone decides which updates to trust, and where a
// message typed on the phone stands. Foundation-only, like the rest of
// Page/Models, so all of it runs in the plain-swiftc logic tests.

// MARK: - Backend

/// The agent behind a session. Claude and Codex get their brand pill; any
/// other backend (a local model runner, a future agent) keeps its raw name
/// so it still renders, with a neutral tint.
enum AgentBackend: Hashable {
    case known(InterventionBackend)
    case other(String)

    init(wire raw: String?) {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let known = InterventionBackend(rawValue: trimmed.lowercased()) {
            self = .known(known)
        } else {
            self = .other(trimmed.isEmpty ? "unknown" : String(trimmed.prefix(24)))
        }
    }

    var badge: String {
        switch self {
        case .known(let b): return b.badge
        case .other(let raw): return raw.uppercased()
        }
    }

    /// "Claude", "Ollama"; "Your agent" when the Mac didn't say.
    var displayName: String {
        switch self {
        case .known(let b): return b.displayName
        case .other(let raw):
            guard raw != "unknown" else { return "Your agent" }
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

// MARK: - State

enum SessionGroup: Int, CaseIterable, Hashable {
    case needsYou, working, idle

    var title: String {
        switch self {
        case .needsYou: return "NEEDS YOU"
        case .working:  return "WORKING"
        case .idle:     return "IDLE"
        }
    }
}

/// The Mac's view of a session. Anything this build doesn't know becomes
/// `.unknown`, which groups with idle sessions and never offers Stop.
enum LiveSessionState: String, CaseIterable {
    case idle, active, waitingOnUser, waitingOnApproval, rateLimited, interrupted, failed, offline, unknown

    init(wire raw: String?) {
        self = LiveSessionState(rawValue: (raw ?? "").trimmingCharacters(in: .whitespaces)) ?? .unknown
    }

    var group: SessionGroup {
        switch self {
        case .waitingOnUser, .waitingOnApproval: return .needsYou
        case .active:                            return .working
        default:                                 return .idle
        }
    }

    var isWaiting: Bool { group == .needsYou }

    var label: String {
        switch self {
        case .idle:              return "Idle"
        case .active:            return "Working"
        case .waitingOnUser:     return "Waiting for you"
        case .waitingOnApproval: return "Needs approval"
        case .rateLimited:       return "Rate limited"
        case .interrupted:       return "Interrupted"
        case .failed:            return "Failed"
        case .offline:           return "Offline"
        case .unknown:           return "Unknown"
        }
    }
}

// MARK: - Session

struct LiveSession: Identifiable, Hashable {
    let id: String
    let backend: AgentBackend
    let title: String
    /// Home-abbreviated by the Mac.
    let cwd: String
    let state: LiveSessionState
    /// Raw host name ("cmux", "Ghostty", "unknown").
    let host: String
    let canType: Bool
    /// Why Page can't type here; only meaningful when `canType` is false.
    let typeBlocker: String?
    let canInterrupt: Bool
    let provider: String?
    let lastActivityAt: Date?
    /// The open page for this session, if any.
    let interventionId: String?
    let preview: String

    static let defaultBlocker = "Page can't type into this session."

    var hostLabel: String {
        let h = host.trimmingCharacters(in: .whitespaces)
        return h.isEmpty || h.lowercased() == "unknown" ? "Unknown host" : h
    }

    var blockerText: String { typeBlocker ?? Self.defaultBlocker }

    /// Stop is offered only where the Mac says Esc works and only mid-turn.
    var isStoppable: Bool { state == .active && canInterrupt }

    /// A waiting session whose prompt has a page: answer it there.
    var openPageId: String? { state.isWaiting ? interventionId : nil }
}

extension LiveSession: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, backend, title, cwd, state, host, canType, typeBlocker, canInterrupt
        case provider, lastActivityAt, interventionId, preview
    }

    /// Lenient like `Intervention`: only `id` is required. A malformed
    /// optional field is treated as missing, and the capabilities default to
    /// the safe side (can't type, can't stop).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawId = try c.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawId.isEmpty, rawId.count <= 200 else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Bad session id")
        }
        id = rawId
        backend = AgentBackend(wire: c.lenientString(.backend))
        cwd = String((c.lenientString(.cwd) ?? "").prefix(300))
        let rawTitle = (c.lenientString(.title) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawTitle.isEmpty {
            title = String(rawTitle.prefix(120))
        } else if let last = cwd.split(separator: "/").last, last != "~" {
            title = String(last)
        } else {
            title = "Session \(rawId.prefix(8))"
        }
        state = LiveSessionState(wire: c.lenientString(.state))
        host = String((c.lenientString(.host) ?? "unknown").prefix(40))
        canType = c.lenientBool(.canType) ?? false
        let blocker = (c.lenientString(.typeBlocker) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        typeBlocker = canType || blocker.isEmpty ? nil : String(blocker.prefix(200))
        canInterrupt = c.lenientBool(.canInterrupt) ?? false
        provider = c.lenientString(.provider)
        lastActivityAt = (try? c.decodeIfPresent(Date.self, forKey: .lastActivityAt)) ?? nil
        let iv = (c.lenientString(.interventionId) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        interventionId = iv.isEmpty || iv.count > 200 ? nil : iv
        preview = String((c.lenientString(.preview) ?? "").prefix(300))
    }
}

extension KeyedDecodingContainer {
    /// A bool if present and actually a bool; nil otherwise.
    func lenientBool(_ key: Key) -> Bool? {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil
    }
}

// MARK: - Transcript

enum TranscriptRole: String {
    case user, assistant, tool, system

    /// Unknown roles render as a neutral system marker, never as the user.
    init(wire raw: String?) {
        self = TranscriptRole(rawValue: raw ?? "") ?? .system
    }
}

struct TranscriptEntry: Identifiable, Hashable {
    let id: String
    let role: TranscriptRole
    let text: String
    let at: Date?
    /// Tool name for `tool` rows ("Bash").
    let tool: String?
}

extension TranscriptEntry: Decodable {
    private enum CodingKeys: String, CodingKey { case id, role, text, at, tool }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Offsets may arrive as numbers; either way it must be stable.
        if let s = c.lenientString(.id), !s.isEmpty {
            id = String(s.prefix(200))
        } else if let n = (try? c.decodeIfPresent(Int.self, forKey: .id)) ?? nil {
            id = String(n)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Missing entry id")
        }
        role = TranscriptRole(wire: c.lenientString(.role))
        text = String((c.lenientString(.text) ?? "").prefix(2400))
        at = (try? c.decodeIfPresent(Date.self, forKey: .at)) ?? nil
        tool = c.lenientString(.tool).flatMap { $0.isEmpty ? nil : String($0.prefix(40)) }
    }
}

struct SessionTranscript: Equatable {
    let sessionId: String
    let entries: [TranscriptEntry]
    /// Older entries were dropped to fit the snapshot.
    let truncated: Bool
    /// Set for a workflow agent's transcript (inside the session).
    var runId: String? = nil
    var agentId: String? = nil

    /// Where the store keeps it: the session, or one of its agents.
    var key: String { Self.key(sessionId: sessionId, runId: runId, agentId: agentId) }

    static func key(sessionId: String, runId: String?, agentId: String?) -> String {
        guard let runId, let agentId else { return sessionId }
        return "\(sessionId)|\(runId)|\(agentId)"
    }
}

// MARK: - Workflows

/// One dynamic workflow a session launched (the Mac's `workflows` kind),
/// as Claude Code's footer shows it: name, progress, phase, agents.
struct WorkflowRun: Equatable, Identifiable, Decodable {
    struct Agent: Equatable, Identifiable, Decodable {
        let id: String
        let label: String
        let phase: String?
        /// running, done, failed, stopped (its run ended first), or a newer
        /// value shown as not running.
        let state: String
        let lastActivityAt: Date?

        var running: Bool { state == "running" }

        private enum CodingKeys: String, CodingKey { case id, label, phase, state, lastActivityAt }

        init(id: String, label: String, phase: String?, state: String, lastActivityAt: Date?) {
            self.id = id; self.label = label; self.phase = phase; self.state = state; self.lastActivityAt = lastActivityAt
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.lenientString(.id), !id.isEmpty else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Missing agent id")
            }
            self.id = String(id.prefix(64))
            label = String((c.lenientString(.label) ?? "agent").prefix(160))
            phase = c.lenientString(.phase).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
            state = String((c.lenientString(.state) ?? "done").prefix(20))
            lastActivityAt = WorkflowRun.millisDate(c, .lastActivityAt)
        }
    }

    let id: String
    let name: String
    let summary: String?
    /// running, completed, failed, killed, stalled (anything else shown as is).
    let status: String
    let phase: String?
    let done: Int
    let total: Int
    let startedAt: Date?
    let endedAt: Date?
    let tokens: Int?
    let agents: [Agent]

    var isRunning: Bool { status == "running" }

    /// "28/30 · 2h34m", like the footer.
    var progressLabel: String { progress(now: Date()) }

    func progress(now: Date) -> String {
        var parts = ["\(done)/\(total)"]
        if let start = startedAt { parts.append(Self.duration((endedAt ?? now).timeIntervalSince(start))) }
        if let tokens { parts.append(Self.tokens(tokens)) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ s: TimeInterval) -> String {
        let m = max(0, Int(s) / 60)
        if m < 1 { return "\(max(0, Int(s)))s" }
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h\(String(format: "%02d", m % 60))m"
    }

    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fm tokens", Double(n) / 1e6)
            : n >= 1000 ? String(format: "%.1fk tokens", Double(n) / 1e3) : "\(n) tokens"
    }

    var statusLabel: String {
        switch status {
        case "running": return "Running"
        case "completed": return "Done"
        case "failed": return "Failed"
        case "killed": return "Stopped"
        case "stalled": return "No recent activity"
        default: return status.capitalized
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, status, phase, done, total, startedAt, endedAt, tokens, agents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lenientString(.id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Missing run id")
        }
        self.id = String(id.prefix(64))
        name = String((c.lenientString(.name) ?? id).prefix(80))
        summary = c.lenientString(.summary).flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        status = String((c.lenientString(.status) ?? "running").prefix(20))
        phase = c.lenientString(.phase).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
        done = max(0, (try? c.decodeIfPresent(Int.self, forKey: .done)) ?? 0 ?? 0)
        total = max(0, (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0 ?? 0)
        startedAt = Self.millisDate(c, .startedAt)
        endedAt = Self.millisDate(c, .endedAt)
        tokens = (try? c.decodeIfPresent(Int.self, forKey: .tokens)) ?? nil
        agents = Array(((try? c.decodeIfPresent(LossyList<Agent>.self, forKey: .agents)) ?? nil)?.elements.prefix(100) ?? [])
    }

    init(id: String, name: String, summary: String? = nil, status: String, phase: String? = nil, done: Int, total: Int,
         startedAt: Date? = nil, endedAt: Date? = nil, tokens: Int? = nil, agents: [Agent] = []) {
        self.id = id; self.name = name; self.summary = summary; self.status = status; self.phase = phase
        self.done = done; self.total = total; self.startedAt = startedAt; self.endedAt = endedAt
        self.tokens = tokens; self.agents = agents
    }

    static func millisDate<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        guard let ms = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil, ms.isFinite, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}

/// Which terminal rows name one of the session's workflows, so tapping the
/// footer's "○ design-pass-ch1-8-opus" row opens that run. Rows are matched
/// to running runs first, in screen order, so two runs with the same name
/// map to two rows. Pure.
enum TerminalRunLinks {
    static func match(lines: [String], runs: [WorkflowRun]) -> [Int: WorkflowRun] {
        guard !runs.isEmpty else { return [:] }
        let pool = runs.filter(\.isRunning) + runs.filter { !$0.isRunning }
        var left = Dictionary(grouping: pool, by: \.name).mapValues(\.count)
        // Bottom up: the footer is at the bottom, so it claims rows before any
        // conversation line above that happens to mention a name.
        var claimed: [String: [Int]] = [:]
        for i in lines.indices.reversed() {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            // Footer rows start with a status glyph and then the name.
            guard let first = trimmed.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) else { continue }
            let body = trimmed.drop { !$0.isLetter && !$0.isNumber }
            // Longest name first, so "a-b" isn't taken by a run named "a".
            guard let name = left.keys.sorted(by: { $0.count > $1.count }).first(where: { name in
                (left[name] ?? 0) > 0 && body.hasPrefix(name) && body.dropFirst(name.count).first.map { $0 == " " } ?? true
            }) else { continue }
            left[name, default: 0] -= 1
            claimed[name, default: []].append(i)
        }
        // Runs sharing a name go to their rows top to bottom, in list order.
        var out: [Int: WorkflowRun] = [:]
        for (name, rows) in claimed {
            for (row, run) in zip(rows.sorted(), pool.filter { $0.name == name }) { out[row] = run }
        }
        return out
    }
}

/// The bottom of a session's terminal (the Mac's `screen` kind): Claude
/// Code's footer — background workflows, shells, sub-agents — and whatever
/// else is on screen. Plain text, redacted on the Mac.
struct SessionScreen: Equatable {
    let sessionId: String
    let lines: [String]
    /// Mac clock.
    let at: Date

    static let maxLines = 80
    static let maxLineChars = 300
}

// MARK: - Command results

struct CommandResult: Equatable {
    enum Code: String {
        case delivered, queued, refused, failed
    }

    let clientId: String
    let ok: Bool
    let code: Code
    let reason: String?
    /// Short sentence from the Mac, at most 200 characters.
    let detail: String?
    let interventionId: String?
}

// MARK: - Plaintext kinds (Mac → phone)

enum SessionsUpdate: Equatable {
    case list(macName: String?, sessions: [LiveSession])
    case transcript(SessionTranscript)
    case screen(SessionScreen)
    case workflows(sessionId: String, runs: [WorkflowRun])
    case result(CommandResult)
    case diff(SessionDiff)
    case folders(StartFolders)
}

/// A session's changes (the `diff` kind): this turn's files, or the
/// repository's uncommitted changes, with a redacted unified patch.
struct SessionDiff: Equatable {
    struct File: Equatable, Identifiable {
        let path: String
        let added: Int?
        let removed: Int?
        /// modified | added | changed
        let status: String
        var id: String { path }
    }

    let sessionId: String
    let clientId: String?
    /// turn | uncommitted
    let scope: String
    let repo: String?
    let files: [File]
    let patch: String
    let truncated: Bool
    let note: String?

    var added: Int { files.compactMap(\.added).reduce(0, +) }
    var removed: Int { files.compactMap(\.removed).reduce(0, +) }

    /// The patch split per file ("diff --git" headers), for sections.
    var sections: [(path: String, lines: [String])] {
        var out: [(String, [String])] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                let path = line.split(separator: " ").last.map { String($0.dropFirst(2)) } ?? String(line)
                out.append((path, []))
            } else if !out.isEmpty {
                out[out.count - 1].1.append(String(line))
            } else if !line.isEmpty {
                out.append(("", [String(line)]))
            }
        }
        // Drop the patch header lines (index, ---/+++), keep hunks.
        return out.map { section in
            (section.0, section.1.filter { !$0.hasPrefix("index ") && !$0.hasPrefix("--- ") && !$0.hasPrefix("+++ ") && $0 != "new file" })
        }
    }

    static let maxFiles = 200
    static let maxPatch = 64 * 1024
}

/// Where the phone may start a session (the `folders` kind).
struct StartFolders: Equatable {
    struct Folder: Equatable, Identifiable {
        let path: String
        let name: String
        let lastUsedAt: Date?
        var id: String { path }
    }

    let clientId: String?
    let enabled: Bool
    let folders: [Folder]
}

/// One decrypted `sessions.update`.
struct SessionsPlaintext: Equatable {
    /// Random per Mac launch; "" from a Mac that doesn't send one.
    let boot: String
    let seq: Int
    /// Mac clock.
    let ts: Date
    let update: SessionsUpdate
    /// A `list` from a Mac with live sessions turned off in its settings
    /// (an optional field the Mac adds; others never send it).
    var macDisabled: Bool = false

    static let maxSessions = 100
    static let maxEntries = 40

    private struct Raw: Decodable {
        let kind: String
        let seq: Double
        let ts: Double
        let boot: String?
        let macName: String?
        let sessions: LossyList<LiveSession>?
        let sessionId: String?
        let entries: LossyList<TranscriptEntry>?
        let truncated: Bool?
        let clientId: String?
        let ok: Bool?
        let code: String?
        let reason: String?
        let detail: String?
        let interventionId: String?
        let disabled: Bool?
        let lines: [String]?
        let runs: LossyList<WorkflowRun>?
        let runId: String?
        let agentId: String?
        let scope: String?
        let repo: String?
        let patch: String?
        let note: String?
        let enabled: Bool?
        let files: [[String: AnyDecodable]]?
        let folders: [[String: AnyDecodable]]?

        private enum CodingKeys: String, CodingKey {
            case kind, seq, ts, boot, macName, sessions, sessionId, entries, truncated
            case clientId, ok, code, reason, detail, interventionId, disabled, lines, runs, runId, agentId
            case scope, repo, patch, note, enabled, files, folders
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(String.self, forKey: .kind)
            seq = try c.decode(Double.self, forKey: .seq)
            ts = try c.decode(Double.self, forKey: .ts)
            boot = c.lenientString(.boot)
            macName = c.lenientString(.macName)
            sessions = try? c.decodeIfPresent(LossyList<LiveSession>.self, forKey: .sessions)
            sessionId = c.lenientString(.sessionId)
            entries = try? c.decodeIfPresent(LossyList<TranscriptEntry>.self, forKey: .entries)
            truncated = c.lenientBool(.truncated)
            clientId = c.lenientString(.clientId)
            ok = c.lenientBool(.ok)
            code = c.lenientString(.code)
            reason = c.lenientString(.reason)
            detail = c.lenientString(.detail)
            interventionId = c.lenientString(.interventionId)
            disabled = c.lenientBool(.disabled)
            lines = try? c.decodeIfPresent([String].self, forKey: .lines)
            runs = try? c.decodeIfPresent(LossyList<WorkflowRun>.self, forKey: .runs)
            runId = c.lenientString(.runId)
            agentId = c.lenientString(.agentId)
            scope = c.lenientString(.scope)
            repo = c.lenientString(.repo)
            patch = c.lenientString(.patch)
            note = c.lenientString(.note)
            enabled = c.lenientBool(.enabled)
            files = try? c.decodeIfPresent([[String: AnyDecodable]].self, forKey: .files)
            folders = try? c.decodeIfPresent([[String: AnyDecodable]].self, forKey: .folders)
        }
    }

    /// Nil for anything malformed or of an unknown `kind` (ignored, as the
    /// protocol asks). A `list` without a `sessions` array is malformed, not
    /// empty, so a bad frame can never blank the screen.
    static func decode(_ data: Data) -> SessionsPlaintext? {
        guard let raw = try? JSONDecoder.page().decode(Raw.self, from: data),
              raw.seq.isFinite, raw.ts.isFinite, raw.ts > 0,
              abs(raw.seq) < 9e15 else { return nil }
        let update: SessionsUpdate
        switch raw.kind {
        case "list":
            guard let list = raw.sessions else { return nil }
            let name = raw.macName?.trimmingCharacters(in: .whitespacesAndNewlines)
            update = .list(macName: (name?.isEmpty ?? true) ? nil : String(name!.prefix(60)),
                           sessions: Array(list.elements.prefix(maxSessions)))
        case "transcript":
            guard let sid = raw.sessionId, !sid.isEmpty, let entries = raw.entries else { return nil }
            var t = SessionTranscript(sessionId: sid, entries: Array(entries.elements.suffix(maxEntries)),
                                      truncated: raw.truncated ?? false)
            if let run = raw.runId, !run.isEmpty, let agent = raw.agentId, !agent.isEmpty {
                t.runId = String(run.prefix(64))
                t.agentId = String(agent.prefix(64))
            }
            update = .transcript(t)
        case "workflows":
            guard let sid = raw.sessionId, !sid.isEmpty, let runs = raw.runs else { return nil }
            update = .workflows(sessionId: sid, runs: Array(runs.elements.prefix(12)))
        case "screen":
            guard let sid = raw.sessionId, !sid.isEmpty, let lines = raw.lines else { return nil }
            update = .screen(SessionScreen(sessionId: sid,
                                           lines: lines.suffix(SessionScreen.maxLines).map { String($0.prefix(SessionScreen.maxLineChars)) },
                                           at: Date(timeIntervalSince1970: raw.ts / 1000)))
        case "diff":
            guard let sid = raw.sessionId, !sid.isEmpty else { return nil }
            let files: [SessionDiff.File] = (raw.files ?? []).prefix(SessionDiff.maxFiles).compactMap { f in
                guard let path = f["path"]?.string, !path.isEmpty else { return nil }
                return SessionDiff.File(path: String(path.prefix(500)), added: f["added"]?.int, removed: f["removed"]?.int,
                                        status: f["status"]?.string ?? "changed")
            }
            update = .diff(SessionDiff(sessionId: sid, clientId: raw.clientId, scope: raw.scope ?? "turn",
                                       repo: raw.repo, files: files,
                                       patch: String((raw.patch ?? "").prefix(SessionDiff.maxPatch)),
                                       truncated: raw.truncated ?? false, note: raw.note))
        case "folders":
            let folders: [StartFolders.Folder] = (raw.folders ?? []).prefix(40).compactMap { f in
                guard let path = f["path"]?.string, path.hasPrefix("/") else { return nil }
                let name = f["name"]?.string ?? (path as NSString).lastPathComponent
                return StartFolders.Folder(path: String(path.prefix(1024)), name: String(name.prefix(80)),
                                           lastUsedAt: f["lastUsedAt"]?.double.map { Date(timeIntervalSince1970: $0 / 1000) })
            }
            update = .folders(StartFolders(clientId: raw.clientId, enabled: raw.enabled ?? false, folders: folders))
        case "result":
            guard let cid = raw.clientId, !cid.isEmpty else { return nil }
            let ok = raw.ok ?? false
            let code = raw.code.flatMap(CommandResult.Code.init(rawValue:)) ?? (ok ? .delivered : .failed)
            let detail = raw.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            update = .result(CommandResult(clientId: cid, ok: ok, code: code,
                                           reason: raw.reason.flatMap { $0.isEmpty ? nil : $0 },
                                           detail: (detail?.isEmpty ?? true) ? nil : String(detail!.prefix(200)),
                                           interventionId: raw.interventionId.flatMap { $0.isEmpty ? nil : $0 }))
        default:
            return nil
        }
        var out = SessionsPlaintext(boot: raw.boot ?? "", seq: Int(raw.seq),
                                    ts: Date(timeIntervalSince1970: raw.ts / 1000), update: update)
        if case .list = update { out.macDisabled = raw.disabled ?? false }
        return out
    }
}

// MARK: - Acceptance (§4)

/// Which decrypted updates the phone applies. The protocol's rules: drop
/// anything whose `ts` is more than 10 minutes old (replay guard), and drop a
/// `list` whose `seq` is at or below the last applied list from the same
/// `boot`. A new `boot` (the Mac relaunched) resets the tracking. Transcripts
/// get the same rule per session, since `seq` is one counter per Mac process.
struct SessionUpdateGate {
    static let maxAge: TimeInterval = 10 * 60

    enum Verdict: Equatable {
        case accept
        /// Older than `maxAge` by the phone's clock.
        case tooOld
        /// Same boot, `seq` not newer than what's already shown.
        case outOfOrder
    }

    private(set) var boot: String?
    private(set) var lastListSeq: Int?
    private var lastTranscriptSeq: [String: Int] = [:]
    private var lastScreenSeq: [String: Int] = [:]

    mutating func admit(_ p: SessionsPlaintext, now: Date) -> Verdict {
        // Age first: a stale frame from a new boot mustn't reset tracking.
        if now.timeIntervalSince(p.ts) > Self.maxAge { return .tooOld }
        if p.boot != boot {
            boot = p.boot
            lastListSeq = nil
            lastTranscriptSeq = [:]
            lastScreenSeq = [:]
        }
        switch p.update {
        case .list:
            if let last = lastListSeq, p.seq <= last { return .outOfOrder }
            lastListSeq = p.seq
        case .transcript(let t):
            if let last = lastTranscriptSeq[t.key], p.seq <= last { return .outOfOrder }
            if lastTranscriptSeq.count > 200 { lastTranscriptSeq = [:] }
            lastTranscriptSeq[t.key] = p.seq
        case .workflows(let sid, _):
            let key = "workflows|" + sid
            if let last = lastScreenSeq[key], p.seq <= last { return .outOfOrder }
            if lastScreenSeq.count > 200 { lastScreenSeq = [:] }
            lastScreenSeq[key] = p.seq
        case .screen(let s):
            if let last = lastScreenSeq[s.sessionId], p.seq <= last { return .outOfOrder }
            if lastScreenSeq.count > 200 { lastScreenSeq = [:] }
            lastScreenSeq[s.sessionId] = p.seq
        case .result, .diff, .folders:
            // Answers to one command each (keyed by clientId): no ordering.
            break
        }
        return .accept
    }

    mutating func reset() {
        boot = nil
        lastListSeq = nil
        lastTranscriptSeq = [:]
        lastScreenSeq = [:]
    }
}

// MARK: - Grouping

struct SessionSection: Identifiable, Equatable {
    let group: SessionGroup
    let sessions: [LiveSession]
    var id: SessionGroup { group }
}

enum SessionGrouping {
    /// "Needs you", "Working", "Idle", leaving out empty groups. Most recent
    /// activity first within a group, so the order never depends on how the
    /// Mac happened to sort its list.
    static func sections(_ sessions: [LiveSession]) -> [SessionSection] {
        let sorted = sessions.sorted { a, b in
            if a.state.group != b.state.group { return a.state.group.rawValue < b.state.group.rawValue }
            let ta = a.lastActivityAt ?? .distantPast, tb = b.lastActivityAt ?? .distantPast
            if ta != tb { return ta > tb }
            if a.title != b.title { return a.title < b.title }
            return a.id < b.id
        }
        return SessionGroup.allCases.compactMap { group in
            let members = sorted.filter { $0.state.group == group }
            return members.isEmpty ? nil : SessionSection(group: group, sessions: members)
        }
    }

    static func needsYouCount(_ sessions: [LiveSession]) -> Int {
        sessions.filter { $0.state.isWaiting }.count
    }
}

// MARK: - Commands (phone → Mac)

enum SessionCommand: Equatable {
    case watch(sessionId: String?)
    case refresh
    case input(sessionId: String, text: String)
    case interrupt(sessionId: String)
    /// Watch a workflow agent inside the session (its transcript).
    case watchAgent(sessionId: String, runId: String, agentId: String)
    /// The session's changes (answered by a `diff`).
    case diff(sessionId: String)
    /// Where a session may be started (answered by `folders`).
    case folders
    /// Start a new Claude session in `folder` with `prompt`.
    case start(folder: String, prompt: String)

    var op: String {
        switch self {
        case .watch, .watchAgent: return "watch"
        case .refresh:   return "refresh"
        case .input:     return "input"
        case .interrupt: return "interrupt"
        case .diff:      return "diff"
        case .folders:   return "folders"
        case .start:     return "start"
        }
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    /// The plaintext JSON. Keys are sorted so the bytes are deterministic.
    func plaintext(clientId: String, viewer: String, now: Date) -> Data {
        var body: [String: Any] = ["op": op, "clientId": clientId, "ts": NSNumber(value: Self.millis(now)), "viewer": viewer]
        switch self {
        case .watch(let sid):          body["sessionId"] = sid.map { $0 as Any } ?? NSNull()
        case .refresh:                 break
        case .input(let sid, let text): body["sessionId"] = sid; body["text"] = text
        case .interrupt(let sid):      body["sessionId"] = sid
        case .watchAgent(let sid, let run, let agent):
            body["sessionId"] = sid; body["runId"] = run; body["agentId"] = agent
        case .diff(let sid):           body["sessionId"] = sid
        case .folders:                 break
        case .start(let folder, let prompt): body["folder"] = folder; body["text"] = prompt
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// `{"e": <envelope>}`, the body of POST /sessions/command.
    static func requestBody(plaintext: Data, root: Data, nonce: Data? = nil) throws -> Data {
        let envelope = try SessionCrypto.seal(plaintext, root: root, direction: .phoneToMac,
                                              aad: SessionFrameType.command, nonce: nonce)
        return try JSONSerialization.data(withJSONObject: ["e": envelope.json], options: [.sortedKeys])
    }
}

/// What the composer accepts: 1–8000 characters after trimming, and a body
/// the relay will take (64 KiB, which multi-scalar emoji can exceed well
/// before 8000 characters once encrypted and base64-encoded).
enum SessionComposer {
    static let maxCharacters = 8000
    static let maxBodyBytes = 64 * 1024
    /// Show a counter once the draft gets close to the limit.
    static let counterFrom = 7000

    enum Problem: Error, Equatable {
        case empty
        case tooLong(count: Int)
        case tooLarge

        var message: String {
            switch self {
            case .empty:
                return "Type a message first."
            case .tooLong(let count):
                return "That's \(count) characters. Keep it to \(SessionComposer.maxCharacters) or fewer."
            case .tooLarge:
                return "That message is too large to send. Shorten it (emoji and symbols take more space)."
            }
        }
    }

    static func validate(_ raw: String) -> Result<String, Problem> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .failure(.empty) }
        if text.count > maxCharacters { return .failure(.tooLong(count: text.count)) }
        return .success(text)
    }

    static func fitsRelay(_ body: Data) -> Bool { body.count <= maxBodyBytes }
}

// MARK: - HTTP outcome of POST /sessions/command

enum SessionCommandOutcome: Equatable {
    /// 202: forwarded to the Mac. The `result` frame says what happened.
    case accepted
    /// 503 `mac_offline`: nothing was queued.
    case macOffline
    /// 400 `invalid_envelope`.
    case invalid
    /// 413 `too_large`.
    case tooLarge
    /// 429 `rate_limited`.
    case rateLimited
    /// 401/403: the relay rejected our token.
    case unauthorized
    /// 410 `token_retired`: re-pair. Carries the relay's explanation.
    case retired(String)
    /// 404: a relay that predates live sessions has no such route.
    case relayTooOld
    /// Transport error or anything else; the message is shown.
    case failed(String)

    static func from(status: Int, body: Data) -> SessionCommandOutcome {
        if let why = TokenRetirement.why(status: status, body: body) { return .retired(why) }
        switch status {
        case 200..<300: return .accepted
        case 503:       return .macOffline
        case 400:       return .invalid
        case 413:       return .tooLarge
        case 429:       return .rateLimited
        case 401, 403:  return .unauthorized
        case 404:       return .relayTooOld
        default:
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            if let err = json?["error"] as? String { return .failed("The relay refused it (\(err)).") }
            return .failed("The relay returned an error (HTTP \(status)).")
        }
    }

    /// What a sent message shows when the relay didn't forward it.
    var failureMessage: String? {
        switch self {
        case .accepted:     return nil
        case .macOffline:   return "Your Mac is offline, so nothing was sent. Try again when Page on your Mac is connected."
        case .invalid:      return "The relay couldn't read this message. Re-pair with your Mac if this keeps happening."
        case .tooLarge:     return SessionComposer.Problem.tooLarge.message
        case .rateLimited:  return "Too many messages in a minute. Wait a moment and try again."
        case .unauthorized: return "The relay no longer accepts this pairing. Re-pair with your Mac."
        case .retired(let why): return why
        case .relayTooOld:  return "Your relay doesn't support live sessions yet. Update your Cloudflare Worker."
        case .failed(let m): return m
        }
    }
}

// MARK: - Delivery of one command

enum SessionCommandKind: String {
    case input, interrupt, start
}

/// Where a message (or Stop) sent from the phone stands, keyed by its
/// `clientId`. Sending → Typed / Queued / Refused from the Mac's `result`;
/// Failed when the relay didn't forward it; No answer after 20 s of silence.
enum SessionDeliveryState: Equatable {
    case sending
    case typed(String?)
    case queued(String?)
    case refused(reason: String?, message: String)
    case failed(String)
    case noAnswer

    static let resultTimeout: TimeInterval = 20

    var isPending: Bool { self == .sending }

    /// A `result` is the Mac's word and beats anything the phone guessed
    /// (sending, a lost HTTP response, giving up). Once one result has
    /// landed, a second for the same `clientId` is ignored.
    func applying(_ result: CommandResult, agent: String) -> SessionDeliveryState {
        switch self {
        case .typed, .queued, .refused: return self
        case .sending, .failed, .noAnswer: break
        }
        switch result.code {
        case .delivered: return .typed(result.detail)
        case .queued:    return .queued(result.detail)
        case .refused:   return .refused(reason: result.reason,
                                         message: SessionResultCopy.refusal(reason: result.reason, detail: result.detail, agent: agent))
        case .failed:    return .failed(SessionResultCopy.failure(reason: result.reason, detail: result.detail))
        }
    }

    /// After the POST returns. Only a send still waiting changes: a result
    /// that beat the HTTP response is newer news.
    func afterPost(_ outcome: SessionCommandOutcome) -> SessionDeliveryState {
        guard self == .sending, let message = outcome.failureMessage else { return self }
        return .failed(message)
    }

    /// The phone stops waiting 20 s after sending.
    func timedOut(sentAt: Date, now: Date) -> SessionDeliveryState {
        guard self == .sending, now.timeIntervalSince(sentAt) >= Self.resultTimeout else { return self }
        return .noAnswer
    }

    /// Short status under a message bubble.
    func label(_ kind: SessionCommandKind) -> String {
        switch (self, kind) {
        case (.sending, .input):     return "Sending…"
        case (.sending, .interrupt): return "Stopping…"
        case (.sending, .start):     return "Starting…"
        case (.typed, .input):       return "Typed"
        case (.typed, .interrupt):   return "Stopped"
        case (.typed, .start):       return "Started"
        case (.queued, _):           return "Queued"
        case (.refused, _):          return "Refused"
        case (.failed, _):           return "Not sent"
        case (.noAnswer, _):         return "No answer from your Mac"
        }
    }

    /// The longer explanation, when there is one.
    func explanation(_ kind: SessionCommandKind, agent: String) -> String? {
        switch self {
        case .sending: return nil
        case .typed(let detail):
            return detail ?? (kind == .interrupt ? "Pressed Esc in the session." : nil)
        case .queued(let detail):
            return detail ?? "Queued — \(agent) reads it after the current step."
        case .refused(_, let message), .failed(let message):
            return message
        case .noAnswer:
            return "Your Mac didn't confirm this within \(Int(Self.resultTimeout)) seconds. It may still arrive; check the transcript before sending again."
        }
    }

    /// The explanation shown under a message bubble: only when there's
    /// something to act on or wait for, not a "Typed" detail.
    func bubbleExplanation(_ kind: SessionCommandKind, agent: String) -> String? {
        switch self {
        case .refused, .failed, .noAnswer, .queued: return explanation(kind, agent: agent)
        case .sending, .typed: return nil
        }
    }

    /// What VoiceOver reads for a message bubble's status: the same label
    /// and explanation the screen shows, so a refusal says why.
    func spokenBubbleStatus(_ kind: SessionCommandKind, agent: String) -> String {
        [label(kind), bubbleExplanation(kind, agent: agent)].compactMap { $0 }.joined(separator: ". ")
    }
}

struct SentSessionCommand: Identifiable, Equatable {
    let clientId: String
    let sessionId: String
    let kind: SessionCommandKind
    /// Kept in memory only, to show the bubble until the transcript echoes it.
    let text: String
    let sentAt: Date
    var state: SessionDeliveryState
    /// Transcript entry ids already on screen when this was sent (nil if no
    /// transcript had loaded). None of them can be its echo, which keeps an
    /// earlier identical "yes" from claiming this message's status.
    var priorEntryIds: Set<String>? = nil

    var id: String { clientId }
}

// MARK: - Reason copy

enum SessionResultCopy {
    /// What a refused command tells the user, with what to do about it.
    /// Known reasons get Page's own copy; anything newer falls back on the
    /// Mac's `detail`.
    static func refusal(reason: String?, detail: String?, agent: String) -> String {
        switch reason {
        case "waiting":
            return "\(agent) is showing a prompt on your Mac. Answer it from its page instead."
        case "unknown_state":
            return "Page can't tell what this session is doing right now, so it didn't type anything. Try again in a moment."
        case "not_typable":
            return detail ?? "Page can't type into this session's terminal."
        case "draft":
            return "There's unsent text in the session's input box on your Mac. Clear it there, then try again."
        case "digit_while_busy":
            return "Starts with a number: wait for \(agent) to finish, or add a word first."
        case "ended":
            return "This session has ended."
        case "codex_mid_turn":
            return "Codex is mid-turn — Page can type once the turn ends."
        case "disabled":
            return "Typing from your iPhone is turned off on your Mac. Turn it back on in Page's Preferences on the Mac."
        case "stale":
            return "Your Mac ignored this because its clock and your iPhone's differ by more than 5 minutes. Check Date & Time on both."
        case "replay":
            return "Your Mac already received this message."
        case "not_found":
            return "This session is no longer on your Mac's list."
        case "interrupt_unsupported":
            return "Page can't stop this session from here: it isn't mid-turn, or its terminal doesn't support it."
        case "error":
            return detail ?? "Something went wrong on your Mac. Try again."
        default:
            return detail ?? "Your Mac didn't type this."
        }
    }

    static func failure(reason: String?, detail: String?) -> String {
        detail ?? "Your Mac couldn't type this into the session."
    }
}

// MARK: - Transcript + sent messages

/// What the detail screen lists: the Mac's transcript, with each message
/// sent from this phone attached to the user entry that echoes it, and the
/// ones not echoed yet (or refused) as pending bubbles at the end.
enum TranscriptTimeline {
    enum Item: Identifiable, Equatable {
        case entry(TranscriptEntry, delivery: SentSessionCommand?)
        case pending(SentSessionCommand)

        var id: String {
            switch self {
            case .entry(let e, _): return "e:" + e.id
            case .pending(let s):  return "p:" + s.clientId
            }
        }
    }

    /// The Mac sanitises what it types (control characters stripped, a
    /// leading `!` guarded) and the transcript may be redacted, so compare
    /// loosely: no control characters, collapsed whitespace, no leading
    /// `!` or backslash.
    static func normalise(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        var t = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        while let first = t.first, first == "!" || first == "\\" || first == " " { t.removeFirst() }
        return t
    }

    /// An entry may be capped at 2000 characters, so a long message echoes
    /// as a prefix.
    static func echoes(_ entryText: String, _ sentText: String) -> Bool {
        let e = normalise(entryText), s = normalise(sentText)
        guard !e.isEmpty, !s.isEmpty else { return false }
        if e == s { return true }
        let head = 200
        return e.count >= head && s.count >= head && e.prefix(head) == s.prefix(head)
    }

    /// Clocks differ between Mac and phone; an echo can't predate the send
    /// by more than this.
    static let clockSlack: TimeInterval = 5 * 60

    static func merge(entries: [TranscriptEntry], sent: [SentSessionCommand]) -> [Item] {
        var matchedEntry: [String: SentSessionCommand] = [:]
        var unmatched: [SentSessionCommand] = []
        var used = Set<String>()
        for message in sent.filter({ $0.kind == .input }).sorted(by: { $0.sentAt < $1.sentAt }) {
            // Refused and failed messages never reach the session.
            let canEcho: Bool
            switch message.state {
            case .refused, .failed: canEcho = false
            default: canEcho = true
            }
            let prior = message.priorEntryIds ?? []
            let hit = canEcho ? entries.first { e in
                e.role == .user && !used.contains(e.id) && !prior.contains(e.id)
                    && (e.at.map { $0 >= message.sentAt.addingTimeInterval(-clockSlack) } ?? true)
                    && echoes(e.text, message.text)
            } : nil
            if let hit {
                used.insert(hit.id)
                matchedEntry[hit.id] = message
            } else {
                unmatched.append(message)
            }
        }
        return entries.map { .entry($0, delivery: matchedEntry[$0.id]) } + unmatched.map { .pending($0) }
    }
}

// MARK: - Availability (§6)

/// What the Sessions screen can show right now, most fundamental problem
/// first, so the copy always names the step that unblocks the user.
enum SessionAvailability: Equatable {
    /// The relay's /status has no `sessions-v1`: update the Worker.
    case relayTooOld
    /// No session key from pairing (older Mac, or paired before this
    /// shipped). `keyMismatch`: frames arrive but don't decrypt, so the
    /// Mac's key changed.
    case needsRepair(keyMismatch: Bool)
    case macOffline
    /// Frames decrypt but are all over 10 minutes old by this phone's clock.
    case clockSkew
    /// Connected; the first list should be along any second.
    case waiting
    /// The Mac is online but sent no list within 5 s: it predates live
    /// sessions (or has them turned off).
    case macTooOld
    /// The Mac says live sessions are turned off in its settings.
    case macDisabled
    case ready

    static let feature = "sessions-v1"
    static let listWait: TimeInterval = 5

    struct Inputs: Equatable {
        var hasKey: Bool
        /// From GET /status; nil until known. A relay without /status has none.
        var relayFeatures: Set<String>?
        var presence: MacPresence
        /// The relay just answered 503 `mac_offline`.
        var macOfflineHint: Bool = false
        var socketConnected: Bool
        /// When the socket opened or the Mac came online, whichever is later.
        var waitStartedAt: Date?
        var hasList: Bool
        /// Undecryptable frames arrived after the last good one.
        var keyMismatch: Bool = false
        /// Decrypted frames were dropped as too old, and none were applied.
        var onlyStaleFrames: Bool = false
        /// The last list said live sessions are turned off on the Mac.
        var macDisabled: Bool = false
    }

    static func evaluate(_ i: Inputs, now: Date) -> SessionAvailability {
        if let features = i.relayFeatures, !features.contains(feature) { return .relayTooOld }
        if !i.hasKey { return .needsRepair(keyMismatch: false) }
        if i.keyMismatch { return .needsRepair(keyMismatch: true) }
        switch i.presence {
        case .offline, .neverConnected, .stale: return .macOffline
        default: break
        }
        if i.macOfflineHint { return .macOffline }
        if i.hasList { return i.macDisabled ? .macDisabled : .ready }
        if i.onlyStaleFrames { return .clockSkew }
        guard i.socketConnected, let start = i.waitStartedAt,
              now.timeIntervalSince(start) >= listWait else { return .waiting }
        // Only an online Mac's silence says "too old"; while presence is
        // still unknown, keep waiting.
        return i.presence.isReachable ? .macTooOld : .waiting
    }
}
