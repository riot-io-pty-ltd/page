import Foundation

// What the Mac knows about a working session, for the In-flight card on the
// Mac and on the phone: its current step in plain words and the few before
// it, when this turn and the session began, its model, the workflows running
// in it, and whether it looks well. The derivations here are pure (no clock,
// file or host inside); `FlightProbe` at the bottom is the one place that
// reads files, and only on a background queue.

// MARK: - Steps in plain words

enum StepPhrasing {
    static let maxChars = 64
    static let working = "Working"

    /// Pure. A transcript tool one-liner ("Bash: swift test", "Edit:
    /// /a/b/SessionRoom.swift", "Grep: TODO in Sources") as the words a person
    /// would use: "Running swift test", "Editing SessionRoom.swift",
    /// "Searching for TODO". Text it doesn't recognise is kept as it is.
    static func phrase(_ line: String, max limit: Int = maxChars) -> String {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return working }
        guard let colon = t.range(of: ": ") else { return clip(t, limit) }
        let tool = String(t[..<colon.lowerBound])
        let arg = String(t[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !arg.isEmpty else { return clip(tool, limit) }
        switch tool {
        case "Bash", "Shell":
            return clip("Running " + firstLine(arg), limit)
        case "Edit", "MultiEdit", "NotebookEdit":
            return clip("Editing " + files(arg), limit)
        case "Write":
            return clip("Writing " + files(arg), limit)
        case "Read":
            return clip("Reading " + files(arg), limit)
        case "Grep":
            return clip("Searching for " + beforeIn(arg), limit)
        case "Glob":
            return clip("Finding files " + beforeIn(arg), limit)
        case "WebFetch":
            return clip("Fetching " + host(arg), limit)
        case "WebSearch", "Search":
            return clip("Searching the web for " + arg, limit)
        case "Task", "Agent":
            return clip("Running a subagent: " + arg, limit)
        default:
            return clip(t, limit)
        }
    }

    /// Pure. Steps oldest first, with the same step repeated back to back
    /// folded into one: "Running cargo test" ×3 → "Running cargo test ×3". The
    /// base is clipped so the count still fits `limit`.
    static func collapse(_ steps: [String], max limit: Int = maxChars) -> [String] {
        var out: [(text: String, count: Int)] = []
        for s in steps {
            if let last = out.last, last.text == s { out[out.count - 1].count += 1 } else { out.append((s, 1)) }
        }
        return out.map { e in
            guard e.count > 1 else { return e.text }
            let suffix = " ×\(e.count)"
            return clip(e.text, Swift.max(1, limit - suffix.count)) + suffix
        }
    }

    /// "/a/b/SessionRoom.swift (2 edits)" → "SessionRoom.swift (2 edits)";
    /// "a.swift, b.swift and 2 more" keeps its shape with bare names.
    static func files(_ arg: String) -> String {
        var rest = arg
        var suffix = ""
        if rest.hasSuffix(")"), let open = rest.range(of: " (", options: .backwards) {
            suffix = String(rest[open.lowerBound...])
            rest = String(rest[..<open.lowerBound])
        }
        var more = ""
        if let r = rest.range(of: " and ", options: .backwards), rest[r.upperBound...].hasSuffix(" more") {
            more = String(rest[r.lowerBound...])
            rest = String(rest[..<r.lowerBound])
        }
        let names = rest.components(separatedBy: ", ").map { part -> String in
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let last = (trimmed as NSString).lastPathComponent
            return last.isEmpty ? trimmed : last
        }
        return names.joined(separator: ", ") + more + suffix
    }

    private static func beforeIn(_ arg: String) -> String {
        if let r = arg.range(of: " in ") { return String(arg[..<r.lowerBound]) }
        return arg
    }

    private static func host(_ url: String) -> String {
        guard let h = URL(string: url)?.host, !h.isEmpty else { return url }
        return h
    }

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? s
    }

    private static func clip(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(Swift.max(1, limit - 1))) + "…"
    }
}

// MARK: - Model names

enum ModelNaming {
    /// Pure. "claude-opus-4-7" → "Opus 4.7", "claude-sonnet-4-5-20250929" →
    /// "Sonnet 4.5", "claude-3-5-haiku-20241022" → "Haiku 3.5". Anything else
    /// is kept (clipped); an empty or synthetic name is nil.
    static func short(_ raw: String?) -> String? {
        guard var id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, id != "<synthetic>" else { return nil }
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        let lower = id.lowercased()
        let parts = lower.split(separator: "-").map(String.init)
        guard parts.first == "claude",
              let family = parts.first(where: { ["opus", "sonnet", "haiku"].contains($0) }) else {
            return String(id.prefix(32))
        }
        // Version numbers on either side of the family, never the 8-digit date.
        let numbers = parts.compactMap { Int($0) != nil && $0.count <= 2 ? Int($0) : nil }
        let version = numbers.prefix(2).map(String.init).joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }
}

// MARK: - Facts

/// One tool call from a transcript tail, as its redacted one-liner.
struct InFlightStep: Equatable {
    let text: String
    let at: Date?
}

/// A running workflow in a session, as the card and the wire show it.
struct InFlightWorkflow: Equatable {
    static let maxName = 60
    static let maxPhase = 40

    let name: String
    let phase: String?
    let done: Int
    let total: Int
    /// Agents running right now.
    let agentsRunning: Int

    init(name: String, phase: String?, done: Int, total: Int, agentsRunning: Int) {
        self.name = name
        self.phase = phase
        self.done = done
        self.total = total
        self.agentsRunning = agentsRunning
    }

    /// Redacted, then clipped: workflow names and phases are free text.
    init(run: WorkflowRunInfo) {
        let name = SessionTranscript.clean(run.name.isEmpty ? "Workflow" : run.name, max: Self.maxName)
        let phase = run.phase.map { SessionTranscript.clean($0, max: Self.maxPhase) }.flatMap { $0.isEmpty ? nil : $0 }
        self.init(name: name, phase: phase, done: max(0, run.done), total: max(0, run.total),
                  agentsRunning: run.agents.filter(\.isRunning).count)
    }

    /// "Reviewing · 3/5 agents".
    var detail: String {
        [phase, total > 0 ? "\(min(done, total))/\(total) agents" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// 0...1, nil when the run has no known size.
    var fraction: Double? { total > 0 ? min(1, Double(done) / Double(total)) : nil }

    /// Pure. The runs that are running, longest-running first, as workflows.
    static func running(from runs: [WorkflowRunInfo]) -> [InFlightWorkflow] {
        runs.filter(\.isRunning)
            .sorted { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }
            .map(InFlightWorkflow.init(run:))
    }
}

/// Everything read for one working session (the raw facts; `InFlightCardInfo`
/// and `InFlightWire` turn them into words).
struct InFlightFacts: Equatable {
    /// The last few tool calls, oldest first (the last is the current step).
    var steps: [InFlightStep] = []
    /// The newest thing in the transcript tail is that tool call: nothing has
    /// been said since, so the step is the one still going.
    var currentStepIsNewest = false
    /// The model the conversation runs on, as the transcript names it.
    var model: String?
    /// When this Claude Code process started the session (sessions file).
    var startedAt: Date?
    /// When the running turn began (sessions file busy-since), if it says.
    var busySince: Date?
    var workflows: [InFlightWorkflow] = []

    /// Read from the tail: more than a card lists, so a run of one repeated
    /// step can fold without emptying the earlier steps.
    static let maxSteps = 12

    var currentStep: InFlightStep? { steps.last }
}

// MARK: - Health

enum InFlightHealth: Equatable {
    case normal
    /// The current step has been going a while (a long test run, a build).
    case longStep(since: Date)
    /// Page's stuck watch has a page open for it (looping, or no progress).
    case looksStuck(String)
    case rateLimited(resetsAt: Date)

    /// A step running longer than this reads as a long one.
    static let longStepAfter: TimeInterval = 180

    /// Pure. Rate limit first (it explains everything else), then the stuck
    /// watch's finding, then a long step, else normal. A rate limit whose
    /// reset has passed no longer counts.
    static func classify(stuckDetail: String?, rateLimitResetsAt: Date?, step: InFlightStep?,
                         stepIsNewest: Bool, now: Date) -> InFlightHealth {
        if let reset = rateLimitResetsAt, reset > now { return .rateLimited(resetsAt: reset) }
        if let stuck = stuckDetail?.trimmingCharacters(in: .whitespacesAndNewlines), !stuck.isEmpty {
            return .looksStuck(stuck)
        }
        if stepIsNewest, let at = step?.at, now.timeIntervalSince(at) >= longStepAfter { return .longStep(since: at) }
        return .normal
    }

    /// The wire name: "normal", "longRunning", "stuck", "rateLimited".
    var wireName: String {
        switch self {
        case .normal: return "normal"
        case .longStep: return "longRunning"
        case .looksStuck: return "stuck"
        case .rateLimited: return "rateLimited"
        }
    }

    var needsAttention: Bool { self != .normal }

    /// "Normal", "Long step · 4m", "Looks stuck · cargo test failed 6×",
    /// "Rate limited · resets 03:00".
    func line(now: Date, timeZone: TimeZone = .current) -> String {
        switch self {
        case .normal: return "Running normally"
        case .longStep(let since): return "Long step · \(InFlightRows.elapsed(since: since, now: now))"
        case .looksStuck(let why): return "Looks stuck · \(why)"
        case .rateLimited(let at): return "Rate limited · resets \(NowModel.clock(at, timeZone: timeZone))"
        }
    }
}

// MARK: - The card's words

/// A workflow as a card line: its name and "Reviewing · 3/5 agents".
struct InFlightWorkflowLine: Equatable {
    let name: String
    let detail: String
    let fraction: Double?
}

/// The In-flight card's content for one working session: the same words on
/// the Mac's card and, from `InFlightWire`, the phone's.
struct InFlightCardInfo: Equatable {
    /// "Claude", "Codex".
    var backendName: String?
    /// "Opus 4.7".
    var model: String?
    /// The current step in plain words: "Running swift test".
    var now: String
    /// The steps before it, newest first (at most `earlierCount`).
    var earlier: [String]
    /// "12m": this turn's time. nil when the session file doesn't say.
    var workingFor: String?
    /// "2h 10m".
    var sessionAge: String?
    var workflows: [InFlightWorkflowLine]
    var health: InFlightHealth
    /// `health` as a line, worded when the card was built (its clock), so it
    /// is the same wherever it is read. nil while the session runs normally.
    var healthLine: String?

    /// How many steps before the current one a card lists.
    static let earlierCount = 3

    /// "working 12m · session 2h 10m", or whichever half is known.
    var timeLine: String? {
        let parts = [workingFor.map { "working \($0)" }, sessionAge.map { "session \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2 workflows running" / "1 workflow running".
    var workflowsHeading: String? {
        workflows.isEmpty ? nil : "\(workflows.count) workflow\(workflows.count == 1 ? "" : "s") running"
    }

    static let empty = InFlightCardInfo(backendName: nil, model: nil, now: StepPhrasing.working, earlier: [],
                                        workingFor: nil, sessionAge: nil, workflows: [], health: .normal, healthLine: nil)

    /// Pure. `fallbackStep` is the raw step the older probe found ("Bash: swift
    /// test"), used when there are no facts.
    static func make(facts: InFlightFacts?, backend: AgentBackendID?, stuckDetail: String?, rateLimitResetsAt: Date?,
                     fallbackStep: String? = nil, now: Date) -> InFlightCardInfo {
        let steps = facts?.steps ?? []
        let phrased = StepPhrasing.collapse(steps.map { StepPhrasing.phrase($0.text, max: StepPhrasing.maxChars) })
        let current = phrased.last ?? fallbackStep.map { StepPhrasing.phrase($0) } ?? StepPhrasing.working
        let before = Array(phrased.dropLast().reversed().prefix(earlierCount))
        let health = InFlightHealth.classify(stuckDetail: stuckDetail, rateLimitResetsAt: rateLimitResetsAt,
                                             step: facts?.currentStep, stepIsNewest: facts?.currentStepIsNewest ?? false,
                                             now: now)
        return InFlightCardInfo(
            backendName: backend.map { AppDelegate.agentName($0) },
            model: ModelNaming.short(facts?.model),
            now: current, earlier: before,
            workingFor: facts?.busySince.map { InFlightRows.elapsed(since: $0, now: now) },
            sessionAge: facts?.startedAt.map { InFlightRows.elapsed(since: $0, now: now) },
            workflows: (facts?.workflows ?? []).map {
                InFlightWorkflowLine(name: $0.name, detail: $0.detail, fraction: $0.fraction)
            },
            health: health, healthLine: health.needsAttention ? health.line(now: now) : nil)
    }
}

// MARK: - On the wire

/// The optional fields a working session's row in the encrypted session list
/// carries (docs/SESSIONS-PROTOCOL.md, "Working-session fields"). Absolute
/// dates only (ISO 8601, as `lastActivityAt`), never "12m" text: the list is
/// resent when its body changes, and a text that ticks would resend it every
/// minute. Old phones ignore every key; a key with nothing to say is left out.
enum InFlightWire {
    static let maxSteps = 4
    static let maxStepChars = 100
    static let maxWorkflows = 3
    static let maxDetail = 120

    static func fields(facts: InFlightFacts?, stuckDetail: String?, rateLimitResetsAt: Date?, now: Date) -> [String: Any] {
        var o: [String: Any] = [:]
        let iso = SessionTranscript.isoFormatter
        if let f = facts {
            if let d = f.busySince { o["busySince"] = iso.string(from: d) }
            if let d = f.startedAt { o["startedAt"] = iso.string(from: d) }
            if let m = ModelNaming.short(f.model) { o["model"] = m }
            // Oldest first; the last is the current step, in the Mac's words, repeats folded.
            let steps = StepPhrasing.collapse(f.steps.map { StepPhrasing.phrase($0.text, max: maxStepChars) },
                                              max: maxStepChars).suffix(maxSteps)
            if !steps.isEmpty { o["recentSteps"] = Array(steps) }
            if !f.workflows.isEmpty {
                o["workflowsRunning"] = f.workflows.count
                o["workflows"] = f.workflows.prefix(maxWorkflows).map { w -> [String: Any] in
                    var d: [String: Any] = ["name": w.name, "done": w.done, "total": w.total, "running": w.agentsRunning]
                    if let p = w.phase { d["phase"] = p }
                    return d
                }
            }
        }
        let health = InFlightHealth.classify(stuckDetail: stuckDetail, rateLimitResetsAt: rateLimitResetsAt,
                                             step: facts?.currentStep, stepIsNewest: facts?.currentStepIsNewest ?? false,
                                             now: now)
        // Said whenever there is anything else to say, so a phone can tell a Mac
        // that judged "normal" from an older Mac that sends no judgement at all.
        guard health != .normal else {
            if !o.isEmpty { o["health"] = health.wireName }
            return o
        }
        o["health"] = health.wireName
        switch health {
        case .looksStuck(let why): o["healthDetail"] = String(why.prefix(maxDetail))
        case .longStep(let since): o["stepSince"] = iso.string(from: since)
        case .rateLimited(let at): o["resetsAt"] = iso.string(from: at)
        case .normal: break
        }
        return o
    }
}

// MARK: - Reading it

/// Reads the facts for working sessions: transcript tails (cached by size and
/// mtime), the sessions file's times (already in `ClaudeLiveSession`), the
/// model (re-read rarely) and running workflows (only when a run has no end
/// record yet). Blocking: one serial background queue per instance, never main.
final class FlightProbe {
    private var steps: [String: (stamp: SessionRemote.FileStamp, steps: [InFlightStep], newest: Bool)] = [:]
    private var models: [String: (model: String?, at: Date)] = [:]
    private var workflows: [String: (at: Date, runs: [InFlightWorkflow])] = [:]
    private let scanner = SessionWorkflowScanner()

    /// The model is re-read this often (it only changes with /model).
    static let modelInterval: TimeInterval = 120
    static let modelRetry: TimeInterval = 15
    /// Workflows are re-scanned this often per session.
    static let workflowInterval: TimeInterval = 6
    static let modelTailBytes = 128 * 1024

    func facts(for sessions: [AgentSession], live: [ClaudeLiveSession],
               transcriptFile: (AgentSession) -> SessionTranscriptFile?, now: Date = Date()) -> [String: InFlightFacts] {
        var out: [String: InFlightFacts] = [:]
        var keepSteps: [String: (stamp: SessionRemote.FileStamp, steps: [InFlightStep], newest: Bool)] = [:]
        for s in sessions {
            var f = InFlightFacts()
            if s.backend == .claude, let l = live.first(where: { $0.sessionId == s.sessionId && $0.hasSessionFile }) {
                f.startedAt = l.startedAt
                if l.status == .busy { f.busySince = l.statusUpdatedAt }
            }
            if let file = transcriptFile(s), let stamp = SessionRemote.fileStamp(file.path) {
                let read: (steps: [InFlightStep], newest: Bool)
                if let cached = steps[s.sessionId], cached.stamp == stamp {
                    read = (cached.steps, cached.newest)
                } else {
                    let entries = SessionTranscript.read(path: file.path, format: file.format,
                                                         tailBytes: SessionTranscript.previewTailBytes, extendTo: nil)?.entries ?? []
                    let tools = entries.filter { $0.role == .tool }.suffix(InFlightFacts.maxSteps)
                    read = (tools.map { InFlightStep(text: $0.text, at: $0.at) }, entries.last?.role == .tool)
                }
                keepSteps[s.sessionId] = (stamp, read.steps, read.newest)
                f.steps = read.steps
                f.currentStepIsNewest = read.newest
                if s.backend == .claude {
                    f.model = model(for: s.sessionId, path: file.path, now: now)
                    f.workflows = runningWorkflows(for: s.sessionId, path: file.path, now: now)
                }
            }
            out[s.sessionId] = f
        }
        steps = keepSteps
        let ids = Set(sessions.map(\.sessionId))
        models = models.filter { ids.contains($0.key) }
        for gone in workflows.keys where !ids.contains(gone) { workflows[gone] = nil }
        return out
    }

    private func model(for id: String, path: String, now: Date) -> String? {
        // A hit holds for the interval; a miss (a fresh transcript) is retried soon.
        if let c = models[id], now.timeIntervalSince(c.at) < (c.model == nil ? Self.modelRetry : Self.modelInterval) { return c.model }
        let m = TranscriptParser.lastAssistantModel(transcript: URL(fileURLWithPath: path), maxBytes: Self.modelTailBytes)
        models[id] = (m ?? models[id]?.model, now)
        return models[id]?.model
    }

    private func runningWorkflows(for id: String, path: String, now: Date) -> [InFlightWorkflow] {
        if let c = workflows[id], now.timeIntervalSince(c.at) < Self.workflowInterval { return c.runs }
        let runs: [InFlightWorkflow] = StuckMonitor.hasUnfinishedRun(transcript: path)
            ? InFlightWorkflow.running(from: scanner.runs(transcript: path, now: now)) : []
        workflows[id] = (now, runs)
        return runs
    }
}
