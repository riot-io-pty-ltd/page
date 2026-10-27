import Foundation

// The In flight card: everything a working session shows on Now, built from
// what the Mac's list says. Every richer field is OPTIONAL on the wire
// (docs/SESSIONS-PROTOCOL.md, "In-flight fields"): an older Mac sends none of
// them and the card shows what it has (project, route, the step, "active 4m
// ago") and leaves the rest out, never an empty heading. Foundation only, no
// clock inside, so the logic tests feed any situation.

// MARK: - Wire

/// The optional per-session fields behind an In flight card.
///
/// Wire names (all optional, on a `sessions[]` row of the `list`):
/// `busySince` and `startedAt` (when this turn and the session began),
/// `model` ("Opus 4.7"), `recentSteps` (oldest first, the last the current
/// step, in the Mac's plain words; tool one-liners and {"text": …} objects
/// are read too), `health` (normal | longRunning | stuck | rateLimited, left
/// out by the Mac when normal), `healthDetail` (`healthNote` is the same),
/// `resetsAt` (rate limit), `stepSince` (the current step began), and
/// `workflows` (up to 3 running ones, as {name, phase, done, total}) with
/// `workflowsRunning`, how many run in all.
struct SessionFlight: Hashable {
    let busySince: Date?
    let startedAt: Date?
    let model: String?
    let recentSteps: [String]
    let health: String?
    let healthNote: String?
    let workflows: [WorkflowBrief]
    /// How many workflows run in all; the list carries at most 3 of them.
    let workflowsRunning: Int?
    let resetsAt: Date?
    let stepSince: Date?

    struct Step: Decodable {
        let text: String
        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                text = s
                return
            }
            enum K: String, CodingKey { case text, step, label, summary }
            let c = try decoder.container(keyedBy: K.self)
            guard let t = c.lenientString(.text) ?? c.lenientString(.step) ?? c.lenientString(.label) ?? c.lenientString(.summary) else {
                throw DecodingError.dataCorruptedError(forKey: .text, in: c, debugDescription: "Empty step")
            }
            text = t
        }
    }

    static let maxSteps = 6
    static let maxWorkflows = 6

    /// nil when the Mac sent none of it (an older Mac), so "no detail" and
    /// a real value are told apart.
    static func make(busySince: Date?, startedAt: Date?, model: String?, recentSteps: [String], health: String?, healthNote: String?,
                     workflows: [WorkflowBrief], workflowsRunning: Int? = nil, resetsAt: Date? = nil, stepSince: Date? = nil) -> SessionFlight? {
        let clean = { (s: String?, n: Int) -> String? in
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return String(t.prefix(n))
        }
        let steps = recentSteps.compactMap { clean($0, 200) }.suffix(maxSteps)
        let f = SessionFlight(busySince: busySince, startedAt: startedAt, model: clean(model, 60), recentSteps: Array(steps),
                              health: clean(health, 24), healthNote: clean(healthNote, 160),
                              workflows: Array(workflows.prefix(maxWorkflows)), workflowsRunning: workflowsRunning.flatMap { $0 > 0 ? $0 : nil },
                              resetsAt: resetsAt, stepSince: stepSince)
        return f.isEmpty ? nil : f
    }

    var isEmpty: Bool {
        busySince == nil && startedAt == nil && model == nil && recentSteps.isEmpty && health == nil && healthNote == nil
            && workflows.isEmpty && workflowsRunning == nil && resetsAt == nil && stepSince == nil
    }
}

/// A running workflow, as the list summarises it.
struct WorkflowBrief: Hashable, Decodable {
    let name: String
    let phase: String?
    let done: Int
    let total: Int
    /// Older phones' word for it; the Mac sends none (every row it lists is running).
    let status: String?
    /// The Mac's `running`: how many of its agents run right now (an Int; the
    /// workflow itself is running whatever it says). nil when not sent.
    let agentsRunning: Int?

    var running: Bool { status == nil || status == "running" }

    private enum CodingKeys: String, CodingKey { case name, phase, done, total, status, running }

    init(name: String, phase: String? = nil, done: Int = 0, total: Int = 0, status: String? = nil, agentsRunning: Int? = nil) {
        self.name = name; self.phase = phase; self.done = done; self.total = total; self.status = status; self.agentsRunning = agentsRunning
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let n = c.lenientString(.name)?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .name, in: c, debugDescription: "Missing workflow name")
        }
        name = String(n.prefix(80))
        phase = c.lenientString(.phase).flatMap { $0.isEmpty ? nil : String($0.prefix(60)) }
        done = max(0, (try? c.decodeIfPresent(Int.self, forKey: .done)) ?? 0)
        total = max(0, (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0)
        status = c.lenientString(.status).flatMap { $0.isEmpty ? nil : String($0.prefix(20)) }
        // `running` is an Int on the Mac's wire; anything else (a bool, text) is not read as a count.
        agentsRunning = ((try? c.decodeIfPresent(Int.self, forKey: .running)) ?? nil).map { max(0, $0) }
    }
}

/// A date the Mac may send as an ISO string (like `lastActivityAt`) or as
/// epoch milliseconds or seconds (like the workflows kind). Anything else is nil.
enum LenientDate {
    static func decode<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Date? {
        if let d = (try? c.decodeIfPresent(Date.self, forKey: key)) ?? nil { return d }
        if let n = (try? c.decodeIfPresent(Double.self, forKey: key)) ?? nil { return fromNumber(n) }
        if let s = (try? c.decodeIfPresent(String.self, forKey: key)) ?? nil { return fromString(s) }
        return nil
    }

    /// Above 1e11 it is milliseconds (1e11 s is year 5138); below, seconds.
    static func fromNumber(_ n: Double) -> Date? {
        guard n.isFinite, n > 0 else { return nil }
        return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n)
    }

    static func fromString(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let n = Double(t) { return fromNumber(n) }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: t) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: t)
    }
}

// MARK: - Words

/// "12m", "2h 10m", "40s": how long, short.
enum FlightClock {
    static func duration(_ seconds: TimeInterval) -> String {
        let t = max(0, Int(seconds))
        if t < 60 { return "\(t)s" }
        let m = t / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60, rest = m % 60
        if h < 48 { return rest == 0 ? "\(h)h" : "\(h)h \(rest)m" }
        return "\(h / 24)d"
    }

    /// "working 12m": this turn. nil when the Mac did not say when it began
    /// (never a guess, and never from the last step).
    static func turn(since: Date?, now: Date) -> String? {
        since.map { "working \(duration(now.timeIntervalSince($0)))" }
    }

    /// "session 2h 10m".
    static func session(since: Date?, now: Date) -> String? {
        since.map { "session \(duration(now.timeIntervalSince($0)))" }
    }

    /// "active 4m ago", "active just now": what an older Mac can say.
    static func quiet(since: Date?, now: Date) -> String? {
        guard let since else { return nil }
        let s = Int(max(0, now.timeIntervalSince(since)))
        return s < 5 ? "active just now" : "active \(RelativeTime.compact(seconds: s)) ago"
    }
}

/// A tool one-liner in plain words: "[Bash] swift test" is "Running swift
/// test", "[Edit] Sources/a/SessionRoom.swift" is "Editing SessionRoom.swift".
/// The Mac writes `[Tool] text`; `Tool: text` reads the same. Words that are
/// not a tool call (the agent's last line) pass through.
enum StepPhrase {
    static func plain(_ raw: String, limit: Int = 90) -> String {
        let line = raw.split(separator: "\n", omittingEmptySubsequences: true).first.map { String($0) } ?? raw
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        guard let (tool, rest) = split(text) else { return clip(text, limit) }
        switch tool {
        case "Bash", "BashOutput": return rest.isEmpty ? "Running a command" : clip("Running \(rest)", limit)
        case "Edit", "MultiEdit", "NotebookEdit": return rest.isEmpty ? "Editing a file" : clip("Editing \(leaf(rest))", limit)
        case "Write": return rest.isEmpty ? "Writing a file" : clip("Writing \(leaf(rest))", limit)
        case "Read": return rest.isEmpty ? "Reading a file" : clip("Reading \(leaf(rest))", limit)
        case "Grep", "Glob": return rest.isEmpty ? "Searching the code" : clip("Searching \(rest)", limit)
        case "WebFetch": return rest.isEmpty ? "Fetching a page" : clip("Fetching \(rest)", limit)
        case "WebSearch": return rest.isEmpty ? "Searching the web" : clip("Searching the web for \(rest)", limit)
        case "Task", "Agent": return rest.isEmpty ? "Running a sub-agent" : clip("Sub-agent: \(rest)", limit)
        case "TodoWrite": return "Updating its to-do list"
        default: return rest.isEmpty ? "Using \(tool)" : clip("\(tool): \(rest)", limit)
        }
    }

    private static let known: Set<String> = ["Bash", "BashOutput", "Edit", "MultiEdit", "NotebookEdit", "Write", "Read", "Grep", "Glob",
                                             "WebFetch", "WebSearch", "Task", "Agent", "TodoWrite"]

    /// ("Bash", "swift test") from "[Bash] swift test" or "Bash: swift test".
    private static func split(_ text: String) -> (String, String)? {
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let tool = String(text[text.index(after: text.startIndex)..<close])
            guard !tool.isEmpty, tool.count <= 32, !tool.contains(" ") else { return nil }
            return (tool, String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces))
        }
        if let colon = text.firstIndex(of: ":") {
            let tool = String(text[..<colon])
            guard known.contains(tool) else { return nil }
            return (tool, String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        if known.contains(text) { return (text, "") }
        return nil
    }

    /// The file's own name: "a/b/SessionRoom.swift (2 edits)" is "SessionRoom.swift (2 edits)".
    private static func leaf(_ path: String) -> String {
        let first = path.split(separator: " ", maxSplits: 1).first.map(String.init) ?? path
        guard first.contains("/"), let name = first.split(separator: "/").last else { return path }
        return String(name) + path.dropFirst(first.count)
    }

    private static func clip(_ s: String, _ n: Int) -> String { SkyModel.clip(s, n) }
}

// MARK: - Health

/// How a working session is going, in the card's four words.
enum FlightHealth: Equatable {
    case normal, longRunning, stuck, rateLimited

    /// No new step for this long while "working": a long-running command. Only
    /// the phone's own guess for a Mac that sends no working fields; a newer
    /// Mac says "longRunning" itself (after 3 minutes).
    static let quietAfter: TimeInterval = 5 * 60

    var label: String? {
        switch self {
        case .normal: return nil
        case .longRunning: return "Long-running command"
        case .stuck: return "Looks stuck"
        case .rateLimited: return "Rate limited"
        }
    }

    var needsAttention: Bool { self == .stuck || self == .rateLimited }

    /// The Mac's word when it sent one, else what the phone can tell: an open
    /// stuck or looping page for this session (as Lanes does), a rate limit. A
    /// Mac that sends working fields but no `health` says "normal" (it leaves
    /// the word out then), so the phone does not guess a long silence over it;
    /// only a Mac that sends nothing gets that guess. Pure.
    static func classify(state: LiveSessionState, flight: SessionFlight?, hasStuckPage: Bool, lastActivityAt: Date?, now: Date) -> FlightHealth {
        if let raw = flight?.health, let macs = from(wire: raw) {
            // A stuck page is a fact about the page: it still wins over a Mac that says "normal".
            return macs == .normal && hasStuckPage ? .stuck : macs
        }
        if hasStuckPage { return .stuck }
        if state == .rateLimited { return .rateLimited }
        if flight != nil { return .normal }
        if let at = lastActivityAt, now.timeIntervalSince(at) >= quietAfter { return .longRunning }
        return .normal
    }

    static func from(wire raw: String) -> FlightHealth? {
        switch raw.lowercased().filter({ $0.isLetter }) {
        case "normal", "ok", "healthy", "fine": return .normal
        case "longrunning", "slow", "longcommand": return .longRunning
        case "stuck", "looksstuck", "looping", "loop", "stalled": return .stuck
        case "ratelimited", "ratelimit", "limited": return .rateLimited
        default: return nil
        }
    }

    /// Sessions with an open stuck or looping page (the same test Lanes uses).
    static func stuckSessionIds(_ interventions: [Intervention]) -> Set<String> {
        Set(interventions.filter { $0.kind == .idle && PageSubtype.isStuck($0.subtype) }.map(\.sessionId))
    }
}

// MARK: - Card

/// One workflow line on a card: "Review changes · 3/5 agents".
struct FlightWorkflowLine: Equatable, Identifiable {
    let id: String
    let name: String
    let phase: String?
    /// "3/5 agents"; nil when the run has no total yet.
    let progress: String?
    /// 0...1 for the thin bar; nil with no total.
    let fraction: Double?

    var text: String { [name, phase, progress].compactMap { $0 }.joined(separator: " · ") }
}

/// What a working session shows beyond its row: the step in words, the
/// steps before it, the clocks, the workflows, the health.
struct InFlightCard: Equatable {
    /// "Running swift test".
    var now: String
    /// The 2 or 3 steps before it, newest first, in the same words.
    var previous: [String] = []
    /// "working 12m": this turn; nil from an older Mac.
    var turn: String? = nil
    /// "session 2h 10m"; nil from an older Mac.
    var session: String? = nil
    /// "active 4m ago": what an older Mac can say, kept only when `turn` is missing.
    var quiet: String? = nil
    var model: String? = nil
    var health: FlightHealth = .normal
    /// "Looks stuck · the same step 6 times": the Mac's note when it sent one.
    var healthLine: String? = nil
    var workflows: [FlightWorkflowLine] = []
    /// How many workflows run in all; the list sends at most 3 lines of them.
    var workflowTotal: Int = 0

    /// The time line's text: "working 12m · session 2h 10m" or "active 4m ago".
    var timeText: String? {
        let parts = [turn ?? quiet, session].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2 workflows running", "1 workflow running"; nil with none. Counts what
    /// the Mac says run in all, not just the lines it sent.
    var workflowHeading: String? {
        let n = max(workflowTotal, workflows.count)
        return n == 0 ? nil : "\(n) \(n == 1 ? "workflow" : "workflows") running"
    }

    /// Earlier steps on a card: the same two as the Mac's.
    static let earlierSteps = 2

    /// Pure. `runs` are the watched session's full workflow runs when the
    /// phone has them (richer than the list's summaries, so they win).
    static func build(session s: LiveSession, runs: [WorkflowRun] = [], hasStuckPage: Bool = false, now: Date) -> InFlightCard {
        let f = s.flight
        // The Mac's steps end with the current one, in its words: they are the whole
        // story, so the card reads the same here as on the Mac. An older Mac sends
        // none, and the preview (a tool one-liner) is put into words here.
        var steps = (f?.recentSteps ?? []).map { StepPhrase.plain($0, limit: 100) }.filter { !$0.isEmpty }
        if steps.isEmpty { steps = [StepPhrase.plain(s.preview)].filter { !$0.isEmpty } }
        let nowLine = steps.last ?? "Working"
        var previous: [String] = []
        for p in steps.dropLast().reversed() {
            guard p != nowLine, !previous.contains(p) else { continue }
            previous.append(p)
            if previous.count == earlierSteps { break }
        }
        let health = FlightHealth.classify(state: s.state, flight: f, hasStuckPage: hasStuckPage, lastActivityAt: s.lastActivityAt, now: now)
        let running = runs.filter(\.isRunning)
        let lines: [FlightWorkflowLine] = running.isEmpty
            ? (f?.workflows ?? []).filter(\.running).enumerated().map { i, w in line(id: "\(i)-\(w.name)", name: w.name, phase: w.phase, done: w.done, total: w.total) }
            : running.map { r in line(id: r.id, name: r.name, phase: r.phase, done: r.done, total: r.total) }
        let turn = FlightClock.turn(since: f?.busySince, now: now)
        return InFlightCard(
            now: nowLine, previous: previous, turn: turn, session: FlightClock.session(since: f?.startedAt, now: now),
            quiet: turn == nil ? FlightClock.quiet(since: s.lastActivityAt, now: now) : nil,
            model: f?.model.map(modelName), health: health,
            healthLine: healthLine(health, note: f?.healthNote, quietFor: (f?.stepSince ?? s.lastActivityAt).map { now.timeIntervalSince($0) },
                                   resetsAt: f?.resetsAt, now: now, explicitQuiet: f?.stepSince != nil),
            workflows: lines, workflowTotal: running.isEmpty ? (f?.workflowsRunning ?? 0) : 0)
    }

    private static func line(id: String, name: String, phase: String?, done: Int, total: Int) -> FlightWorkflowLine {
        FlightWorkflowLine(id: id, name: name, phase: phase, progress: total > 0 ? "\(min(done, total))/\(total) agents" : nil,
                           fraction: total > 0 ? min(1, Double(done) / Double(total)) : nil)
    }

    /// "Looks stuck · no progress for 15 min", "Rate limited · resets 03:00",
    /// "Long-running command · no new step for 4m". `explicitQuiet`: the
    /// quiet time is the Mac's own (`stepSince`), so a minute is enough to name;
    /// the phone's guess from `lastActivityAt` waits for the long silence.
    static func healthLine(_ h: FlightHealth, note: String?, quietFor: TimeInterval?, resetsAt: Date? = nil, now: Date = Date(),
                           explicitQuiet: Bool = false, timeZone: TimeZone = .current) -> String? {
        guard let label = h.label else { return nil }
        if let note, !note.isEmpty { return "\(label) · \(note)" }
        if h == .rateLimited, let r = resetsAt, r > now { return "\(label) · resets \(NowFormat.clock(r, timeZone: timeZone))" }
        if h == .longRunning, let q = quietFor, q >= (explicitQuiet ? 60 : FlightHealth.quietAfter) { return "\(label) · no new step for \(FlightClock.duration(q))" }
        return label
    }

    /// "claude-opus-4-5-20251101" is "Opus 4.5"; a name that already reads
    /// "Opus 4.7" (what the Mac sends) and anything unfamiliar are shown as sent.
    static func modelName(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.range(of: #"^(opus|sonnet|haiku) \d+(\.\d+)*( |$)"#, options: .regularExpression) != nil { return raw }
        for family in ["opus", "sonnet", "haiku"] where lower.contains(family) {
            let digits = lower.components(separatedBy: CharacterSet(charactersIn: "-_ ")).compactMap { Int($0) }.filter { $0 < 100 }
            let version = digits.prefix(2).map(String.init).joined(separator: ".")
            return family.capitalized + (version.isEmpty ? "" : " \(version)")
        }
        return raw
    }
}

// MARK: - Project label

/// The project a session goes by. A cwd of "/" (or an empty or slash-only
/// name) is never shown as "/": it falls back to the session's own name, then
/// "root" (the Mac's word). The home folder reads "~" whatever the session is
/// called, as on the Mac.
enum ProjectLabel {
    static func isBare(_ s: String) -> Bool {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "/ \t\n")).isEmpty
    }

    static func isHome(_ cwd: String) -> Bool {
        let t = cwd.trimmingCharacters(in: .whitespaces)
        if t == "~" || t == "~/" { return true }
        return t.range(of: #"^/(Users|home)/[^/]+/?$"#, options: .regularExpression) != nil
    }

    /// "~" for the home folder; else the folder's own name; else the session's
    /// name; else "root" for the root folder ("Unknown project" with no cwd at all).
    static func name(cwd: String, fallback: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespaces)
        let path = trimmed.hasSuffix("/") && trimmed.count > 1 ? String(trimmed.dropLast()) : trimmed
        if isHome(path) { return "~" }
        if let last = path.split(separator: "/").last, last != "~" { return String(last) }
        let fb = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isBare(fb) { return fb }
        return trimmed.isEmpty ? "Unknown project" : "root"
    }

    /// A name the Mac sent, fixed up when it is "/" or empty.
    static func clean(_ given: String, cwd: String, fallback: String = "") -> String {
        let g = given.trimmingCharacters(in: .whitespacesAndNewlines)
        return isBare(g) ? name(cwd: cwd, fallback: fallback) : g
    }
}

// MARK: - Header jump

/// "2 working" in the Horizon's subline goes to the In flight cards.
enum HeaderJump {
    static let sectionId = "section-in flight"
    static let accessibilityName = "Show what is working"

    /// The scroll target, or nil when there is nothing to jump to (no working
    /// session on screen).
    static func target(working: Int, inFlightShown: Int) -> String? {
        working > 0 && inFlightShown > 0 ? sectionId : nil
    }

    /// "2 working · 4:12 PM runway" split after the count: the part that
    /// jumps and the rest. nil when the subline does not start with the count.
    static func split(subline: String, working: Int) -> (jump: String, rest: String)? {
        let head = "\(working) working"
        guard working > 0, subline.hasPrefix(head) else { return nil }
        return (head, String(subline.dropFirst(head.count)))
    }
}
