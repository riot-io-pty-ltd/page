import Foundation

enum InterventionKind: String, Codable {
    case permission   // tool call awaiting approval — iOS decodes as .approval (subtype "plan" for ExitPlanMode)
    case plan         // legacy plan-mode kind; RelayClient sends it as permission + subtype "plan"
    case question     // AskUserQuestion / Codex requestUserInput / hook Notification — iOS decodes as .userInput
    case idle         // turn finished and the session is waiting for the next message
    case rateLimit = "rate_limit"   // usage limit hit; informational, resolves at reset
}

struct InterventionEvent: Equatable, Hashable, Codable {
    let id: String                 // "<sessionId>-<kind>-<state-start epoch>" (stable per state)
    let sessionId: String
    let cwd: String
    let projectName: String
    let kind: InterventionKind
    let openedAt: Date
    var context: String            // what the phone shows: command / question / last reply
    let transcriptPath: String
    /// Which agent fired this. Defaults to `.claude` so existing call sites
    /// don't need to change.
    var backend: AgentBackendID = .claude
    var source: AgentSessionSource = .terminal
    /// Optional sub-tag — e.g. `"plan"` for plan-mode approvals.
    var subtype: String?

    // Mac-local bookkeeping (not sent on the wire; RelayClient builds the
    // payload field by field).
    /// Claude process the page was raised for.
    var pid: Int32?
    /// Raw `statusUpdatedAt` of the state that raised the page. A reply is
    /// only applied to a prompt if the session is still in this state.
    var stateStartedAt: Date?
    /// tool_use id of the prompt on screen when the page opened, if known.
    var promptKey: String?
    /// How hard the pending tool call is to take back, classified at
    /// detection time from the structured call (tool name and full input,
    /// before the display text was redacted and clipped). Mac-local: never on
    /// the wire. nil when it wasn't classified from a tool call (older
    /// persisted events, hook or Codex pages); readers then fall back to
    /// `Reversibility.classify(context:cwd:)`, which is conservative.
    var reversibility: Reversibility.Verdict?
}

// MARK: - Secret redaction

/// Masks credentials in text that leaves the Mac. A page's context goes to
/// the relay's storage and history, through APNs, and into the phone's
/// notification banner; commands and file writes are exactly where tokens
/// and passwords turn up. A port of `_SECRET_PATTERNS` in
/// hooks/page-extract-context.py — same patterns, same order, same
/// replacements — so a detector page hides what a hook page hides
/// (ContextRedactorTests checks the two agree). Masks only the secret value,
/// so the user can still see what they are approving.
enum ContextRedactor {
    private static let rules: [(NSRegularExpression, String)] = {
        let specs: [(String, NSRegularExpression.Options, String)] = [
            // PEM private keys (multi-line, so collapse the whole block; a
            // block cut short has no END line, hence `|$`).
            (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----.*?(-----END [A-Z0-9 ]*PRIVATE KEY(?: BLOCK)?-----|$)"#,
             [.dotMatchesLineSeparators], "[redacted private key]"),
            // Authorization headers / bearer tokens. "Basic"/"token" are
            // ordinary words too, so their value must look like a credential.
            (#"\b(bearer)\s+[A-Za-z0-9._~+/=-]{12,}"#, [.caseInsensitive], "$1 [redacted]"),
            (#"\b(basic|token)\s+(?=[A-Za-z0-9._~+/=-]*[0-9+/=])[A-Za-z0-9._~+/=-]{12,}"#,
             [.caseInsensitive], "$1 [redacted]"),
            // NAME=value / NAME: value where NAME looks secret-ish.
            (#"\b([A-Z0-9_.-]*(?:api[_-]?key|secret|token|passw(?:or)?d|pwd|credential|private[_-]?key|access[_-]?key)[A-Z0-9_.-]*)(["']?\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s"',;]{6,})"#,
             [.caseInsensitive], "$1$2[redacted]"),
            // URLs with inline credentials: scheme://user:pass@host
            (#"\b([a-z][a-z0-9+.-]*://)[^\s/:@]+:[^\s/@]+@"#, [.caseInsensitive], "$1[redacted]@"),
            // Well-known key formats.
            (#"\bsk-[A-Za-z0-9_-]{16,}"#, [], "[redacted]"),
            (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, [], "[redacted]"),
            (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, [], "[redacted]"),
            (#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#, [], "[redacted]"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, [], "[redacted]"),
            (#"\bAIza[0-9A-Za-z_-]{30,}"#, [], "[redacted]"),
        ]
        // Constant patterns, exercised by the tests: a typo must fail loudly
        // rather than silently drop a rule.
        return specs.map { (try! NSRegularExpression(pattern: $0.0, options: $0.1), $0.2) }
    }()

    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for (regex, template) in rules {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                                 withTemplate: template)
        }
        return out
    }

    /// Redacts before clipping: a clip can leave a fragment of a secret too
    /// short for its pattern to recognise. Only the head (`max` + slack) is
    /// scanned; anything later is clipped away anyway.
    static func redactedPrefix(_ text: String, _ max: Int) -> String {
        redact(String(text.prefix(max + 200)))
    }

    static func redactedSuffix(_ text: String, _ max: Int) -> String {
        redact(String(text.suffix(max + 200)))
    }
}

// MARK: - Transcript tail

/// A tool call that has no tool_result yet.
struct PendingToolUse: Equatable {
    let id: String
    let name: String
    /// Human-readable description for the phone (command, path, question…).
    let summary: String
    /// The input fields the reversibility check reads (`Reversibility
    /// .classifierFields`): the full, unredacted command or path, kept apart
    /// from `summary`, which is redacted and clipped. nil when not known.
    var fields: [String: String]? = nil
    /// An AskUserQuestion's structured questions (raw, for answering from the phone).
    var asked: AskedQuestionSet? = nil
}

/// What the end of a transcript says about the conversation.
struct TranscriptTail: Equatable {
    enum Role: Equatable { case assistant, user }

    /// Role of the last assistant/user message, ignoring system, attachment,
    /// permission-mode and other bookkeeping records. After a turn ends the
    /// file's literal last line is a `system`/`turn_duration` record, so the
    /// raw last line can't answer "who spoke last".
    var lastMeaningfulRole: Role?
    /// Text Claude wrote after its last tool call (the final answer of the
    /// turn), nil if it ended on a tool call or nothing was said.
    var lastAssistantText: String?
    /// Tool calls without a result, in call order.
    var pendingToolUses: [PendingToolUse] = []
    /// Last `cwd` seen in the tail.
    var cwd: String?
    var lastEventAt: Date?
}

/// Detector tuning; built from Config by the backend.
struct DetectorSettings: Equatable {
    /// How long a session must sit idle before it pages.
    var idleDelay: TimeInterval = 60
    /// Idle (and status-less) states older than this when first seen don't
    /// page: on launch we must not page every session idling for days.
    var maxOpenAge: TimeInterval = 4 * 3600
    /// A `waiting` status can land a moment before the tool call reaches the
    /// transcript; hold off this long before paging without one.
    var waitingGrace: TimeInterval = 5
}

/// What the detector wants for one live process.
enum DetectorDecision: Equatable {
    /// Nothing to page; any open page for this process resolves.
    case none
    /// Too early to tell: keep what's open, open nothing new.
    case notYet
    case open(Proposal)

    struct Proposal: Equatable {
        let kind: InterventionKind
        let subtype: String?
        let context: String
        /// When the state began — the page's `openedAt` and id epoch.
        let stateStart: Date
        let promptKey: String?
    }
}

/// Markers written by Page's blocking hooks (hooks/page-notify.sh) while
/// they hold a request open waiting for the phone: one file per hook process,
/// `<hook-holds>/<sessionId>.<pid>`, touched every couple of seconds and
/// removed when the hook exits. A fresh marker means "this session's prompt
/// is already paged" — the detector must not page it a second time.
enum HookHoldMarkers {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudePowerMode/hook-holds", isDirectory: true)
    }

    /// The hook touches its marker every poll (~2 s, plus up to 5 s for a
    /// slow relay request); a marker older than this belongs to a hook that
    /// was killed without running its exit trap.
    static let freshness: TimeInterval = 20

    /// Session ids with at least one fresh marker whose hook process is alive.
    static func heldSessions(in directory: URL, now: Date = Date(),
                             isAlive: (Int32) -> Bool = ProcessRunner.isAlive,
                             fileManager: FileManager = .default) -> Set<String> {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        var held = Set<String>()
        for name in names.prefix(1000) {
            guard let parsed = parseMarkerName(name), !held.contains(parsed.sessionId) else { continue }
            let path = directory.appendingPathComponent(name).path
            guard let attrs = try? fileManager.attributesOfItem(atPath: path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let mtime = attrs[.modificationDate] as? Date,
                  now.timeIntervalSince(mtime) < freshness,
                  isAlive(parsed.pid) else { continue }
            held.insert(parsed.sessionId)
        }
        return held
    }

    /// "<sessionId>.<pid>" -> (sessionId, pid). Temp files ("….tmp") and
    /// anything else that doesn't end in a numeric pid are ignored.
    static func parseMarkerName(_ name: String) -> (sessionId: String, pid: Int32)? {
        guard let dot = name.lastIndex(of: ".") else { return nil }
        let sid = String(name[..<dot])
        guard !sid.isEmpty, !sid.hasPrefix("."),
              let pid = Int32(name[name.index(after: dot)...]), pid > 0 else { return nil }
        return (sid, pid)
    }
}

/// Raises "needs you" pages for live Claude Code sessions.
///
/// Primary signal is the session's own status (`~/.claude/sessions/<pid>.json`
/// via ClaudeSessionRegistry): `waiting` → an approval or question is on
/// screen; `idle` for `idleDelay` after a finished turn → idle page; `busy` →
/// nothing (open pages resolve). The transcript tail only supplies context
/// (command, question, last reply). Sessions without a sessions file (older
/// Claude Code) fall back to the transcript-tail heuristic.
///
/// While one of Page's blocking hooks holds a session's request (a fresh
/// HookHoldMarkers file), the hook has already paged it: the detector opens
/// nothing new for that session and keeps what it had open for the current
/// state. Once the marker goes, detection resumes as normal (e.g. the hook
/// timed out and handed back to the dialog, which still needs an answer).
///
/// Idle pages are only raised for sessions that own their terminal: a
/// session stopped with ^Z or running behind another job can't take a typed
/// reply (the reply path refuses it), so paging it would only invite an
/// answer that fails. Approval pages are unaffected.
///
/// Thread-safe. `scan` is meant for the tick queue; `currentlyPending` and
/// the lookups may be called from reply threads.
final class InterventionDetector {
    /// Where blocking hooks leave their hold markers (tests use a temp dir).
    let hookHoldsDirectory: URL
    /// pid → owns its terminal (true), stopped / behind another job
    /// (false), or can't tell (nil: no tty, e.g. Desktop or IDE sessions).
    /// Only an explicit false holds back an idle page. Tests inject it.
    private let isForeground: (Int32) -> Bool?
    /// "Changed 3 files (+12 −4) · tests passed" for a finished turn
    /// (`TurnSummary.headline`), put on top of a new idle page. Blocking;
    /// called once per page, when it opens. nil = off (tests).
    var turnHeadline: ((_ transcript: URL?, _ cwd: String?) -> String?)?

    init(hookHoldsDirectory: URL = HookHoldMarkers.defaultDirectory,
         isForeground: @escaping (Int32) -> Bool? = { ProcessRunner.isForeground(pid: $0) }) {
        self.hookHoldsDirectory = hookHoldsDirectory
        self.isForeground = isForeground
    }

    private let lock = NSLock()
    private var pending: [String: InterventionEvent] = [:]
    /// Serialises scans and guards `tailCache` / `promptStarts`.
    private let scanLock = NSLock()
    /// Transcript path → parsed tail, keyed by (size, mtime) so an unchanged
    /// transcript is never re-read.
    private var tailCache: [String: (size: UInt64, mtime: Date, tail: TranscriptTail)] = [:]
    /// pid → the prompt currently on screen. When a second prompt follows
    /// without a status change (parallel tool calls), it gets a fresh state
    /// start so it pages as a new intervention.
    private var promptStarts: [Int32: (statusStart: Date, promptKey: String, effectiveStart: Date)] = [:]
    /// Proposals held back last scan because a hook holds the session (only
    /// so the log says so once per prompt, not every tick).
    private var heldBackIds = Set<String>()
    /// pids whose idle page was held back last scan because the session
    /// doesn't own its terminal (log once, not every tick).
    private var notForegroundPids = Set<Int32>()
    /// Ids of approvals not paged because Claude Squad approves them (log
    /// once per prompt, not every tick).
    private var autoApprovedIds = Set<String>()

    struct ScanResult {
        var opened: [InterventionEvent] = []
        var resolved: [InterventionEvent] = []
    }

    var currentlyPending: [String: InterventionEvent] {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    func pendingEvent(id: String) -> InterventionEvent? {
        lock.lock()
        defer { lock.unlock() }
        return pending[id]
    }

    /// Drops every open page (detection switched off). Returns them so the
    /// caller can close them on the relay.
    @discardableResult
    func reset() -> [InterventionEvent] {
        scanLock.lock()
        tailCache.removeAll()
        promptStarts.removeAll()
        heldBackIds.removeAll()
        notForegroundPids.removeAll()
        autoApprovedIds.removeAll()
        scanLock.unlock()
        lock.lock()
        defer { lock.unlock() }
        let all = Array(pending.values)
        pending.removeAll()
        return all
    }

    /// Diffs the live sessions against the open pages. `transcriptFor`
    /// returns a session's transcript (nil if unknown). Only sessions that
    /// aren't busy get their transcript tail read, and only when it changed.
    func scan(sessions: [ClaudeLiveSession],
              transcriptFor: (ClaudeLiveSession) -> URL?,
              settings: DetectorSettings,
              sourceFor: (ClaudeLiveSession) -> AgentSessionSource = { _ in .terminal },
              autoApproves: (ClaudeLiveSession) -> Bool = { _ in false },
              now: Date = Date()) -> ScanResult {
        scanLock.lock()
        defer { scanLock.unlock() }

        let previous = currentlyPending
        var desired: [String: InterventionEvent] = [:]
        var seenPaths = Set<String>()
        var livePids = Set<Int32>()
        // Read the hold markers at most once per scan, and only when a page
        // is about to open.
        var heldCache: Set<String>?
        func isHeld(_ sessionId: String) -> Bool {
            if heldCache == nil { heldCache = HookHoldMarkers.heldSessions(in: hookHoldsDirectory, now: now) }
            return heldCache?.contains(sessionId) ?? false
        }
        var heldBack = Set<String>()
        var notForeground = Set<Int32>()
        var autoApproved = Set<String>()

        for session in sessions {
            livePids.insert(session.pid)
            if session.status == .busy {
                promptStarts.removeValue(forKey: session.pid)
                continue
            }
            let url = transcriptFor(session)
            var tail: TranscriptTail?
            var mtime: Date?
            if let url {
                seenPaths.insert(url.path)
                (tail, mtime) = cachedTail(url)
            }

            switch Self.decide(session: session, tail: tail, transcriptModifiedAt: mtime,
                               now: now, settings: settings) {
            case .none:
                promptStarts.removeValue(forKey: session.pid)
            case .notYet:
                // Keep only pages raised for this very state; a page from an
                // earlier state (approved at the Mac, turn since ended) goes.
                for e in previous.values where e.pid == session.pid
                    && e.stateStartedAt != nil && e.stateStartedAt == session.statusUpdatedAt {
                    desired[e.id] = e
                }
            case .open(let p):
                let start = effectiveStart(for: session, proposal: p, now: now)
                let event = makeEvent(session: session, proposal: p, start: start,
                                      tail: tail, transcriptPath: url?.path ?? "")
                if previous[event.id] != nil {
                    desired[event.id] = previous[event.id]
                } else if isHeld(session.sessionId) {
                    // A blocking Page hook already paged this prompt and is
                    // waiting for the phone. Same as .notYet: keep pages for
                    // this very state, open nothing new.
                    heldBack.insert(event.id)
                    if !heldBackIds.contains(event.id) {
                        Logger.shared.log("Intervention held back: a Page hook is already paging session \(session.sessionId.prefix(8))")
                    }
                    for e in previous.values where e.pid == session.pid
                        && e.stateStartedAt != nil && e.stateStartedAt == session.statusUpdatedAt {
                        desired[e.id] = e
                    }
                } else if p.kind == .idle && isForeground(session.pid) == false {
                    // Stopped (^Z) or behind another job: a reply can't be
                    // typed into it, so don't invite one. An idle page that
                    // is already open stays (resolving it would tombstone
                    // its id on the relay, and the same state re-proposed
                    // after `fg` would then be dropped there); a reply to it
                    // gets the delivery path's "suspended" refusal.
                    notForeground.insert(session.pid)
                    if !notForegroundPids.contains(session.pid) {
                        Logger.shared.log("Idle page held back: session \(session.sessionId.prefix(8)) (pid \(session.pid)) is stopped or in the background")
                    }
                } else if Self.isAutoApproved(kind: p.kind, subtype: p.subtype, sessionAutoApproves: autoApproves(session),
                                              waitingFor: now.timeIntervalSince(start)) {
                    // Claude Squad presses Enter on this prompt itself; a
                    // page would only invite a second answer. Only for a
                    // grace window: if it hasn't answered by then (its prompt
                    // matching broke), the prompt is paged like any other.
                    autoApproved.insert(event.id)
                    if !autoApprovedIds.contains(event.id) {
                        Logger.shared.log("Approval page skipped: Claude Squad auto-approves session \(session.sessionId.prefix(8)) (pid \(session.pid))")
                    }
                } else if Self.mayOpen(kind: p.kind, status: session.status,
                                       stateStart: p.stateStart, now: now, settings: settings) {
                    if p.kind == .permission, p.subtype == nil, autoApproves(session) {
                        Logger.shared.log("Claude Squad didn't answer the approval for session \(session.sessionId.prefix(8)) (pid \(session.pid)); paging")
                    }
                    var event = event
                    event.source = sourceFor(session)
                    if event.kind == .idle, event.subtype == nil, let headline = turnHeadline?(url, session.cwd ?? tail?.cwd) {
                        event.context = TurnSummary.context(headline: headline, reply: event.context)
                    }
                    desired[event.id] = event
                }
            }
        }

        heldBackIds = heldBack
        notForegroundPids = notForeground
        autoApprovedIds = autoApproved
        for path in tailCache.keys where !seenPaths.contains(path) { tailCache.removeValue(forKey: path) }
        for pid in promptStarts.keys where !livePids.contains(pid) { promptStarts.removeValue(forKey: pid) }

        var result = ScanResult()
        lock.lock()
        for (id, e) in desired where pending[id] == nil { result.opened.append(e) }
        for (id, e) in pending where desired[id] == nil { result.resolved.append(e) }
        pending = desired
        lock.unlock()

        for e in result.opened {
            Logger.shared.log("Intervention OPENED: \(e.kind.rawValue)\(e.subtype.map { "/\($0)" } ?? "") in \(e.projectName) (session \(e.sessionId.prefix(8)), pid \(e.pid ?? 0))")
        }
        for e in result.resolved {
            Logger.shared.log("Intervention RESOLVED: \(e.kind.rawValue) in \(e.projectName) (session \(e.sessionId.prefix(8)))")
        }
        return result
    }

    // MARK: decision logic (pure, unit-tested)

    static func decide(session: ClaudeLiveSession,
                       tail: TranscriptTail?,
                       transcriptModifiedAt: Date?,
                       now: Date,
                       settings: DetectorSettings) -> DetectorDecision {
        switch session.status {
        case .busy:
            return .none

        case .waiting:
            let start = session.statusUpdatedAt ?? now
            let pendingTools = tail?.pendingToolUses ?? []
            guard let primary = pendingTools.first else {
                // Status can flip before the tool call is flushed to disk.
                if now.timeIntervalSince(start) < settings.waitingGrace { return .notYet }
                return .open(.init(kind: .permission, subtype: nil,
                                   context: "Claude is waiting for your approval",
                                   stateStart: start, promptKey: nil))
            }
            let (kind, subtype) = classify(primary)
            return .open(.init(kind: kind, subtype: subtype,
                               context: approvalContext(pendingTools),
                               stateStart: start, promptKey: primary.id))

        case .idle, .shell:
            let start = session.statusUpdatedAt ?? now
            guard let tail, tail.lastMeaningfulRole == .assistant, tail.pendingToolUses.isEmpty else {
                // User spoke last (interrupt, slash command, typed message):
                // they're at the keyboard; nothing to page.
                return .none
            }
            guard now.timeIntervalSince(start) >= settings.idleDelay else { return .notYet }
            return .open(.init(kind: .idle, subtype: nil,
                               context: idleContext(tail),
                               stateStart: start, promptKey: nil))

        case .unknown:
            // No sessions file: older Claude Code. Infer from the transcript
            // and how long it has been quiet.
            guard let tail, let mtime = transcriptModifiedAt else { return .none }
            guard now.timeIntervalSince(mtime) >= settings.idleDelay else { return .notYet }
            let start = tail.lastEventAt ?? mtime
            if let primary = tail.pendingToolUses.first {
                // Can't tell an approval prompt from a long-running tool
                // without a status. Paging it as an approval keeps replies
                // on the safe keystrokes ("1" / Esc, never a bare Enter).
                let (kind, subtype) = classify(primary)
                return .open(.init(kind: kind, subtype: subtype,
                                   context: "Possibly waiting for approval:\n" + approvalContext(tail.pendingToolUses),
                                   stateStart: start, promptKey: primary.id))
            }
            guard tail.lastMeaningfulRole == .assistant else { return .none }
            return .open(.init(kind: .idle, subtype: nil, context: idleContext(tail),
                               stateStart: start, promptKey: nil))
        }
    }

    /// How long Claude Squad gets to answer an approval before Page pages
    /// it anyway (several of its poll intervals).
    static let autoApproveGrace: TimeInterval = 15

    /// Pure. An ordinary approval prompt in a session something else
    /// answers (Claude Squad's auto-yes) doesn't page, for `grace` seconds
    /// from when it began waiting (`waitingFor`). After that it pages: the
    /// answer isn't coming. Plan approvals (ExitPlanMode) and questions
    /// always page: an Enter isn't an answer.
    static func isAutoApproved(kind: InterventionKind, subtype: String?, sessionAutoApproves: Bool,
                               waitingFor: TimeInterval, grace: TimeInterval = autoApproveGrace) -> Bool {
        sessionAutoApproves && kind == .permission && subtype == nil && waitingFor < grace
    }

    /// Whether a page that isn't open yet may open. Approvals for a session
    /// that is waiting right now always page (the agent is blocked); idle and
    /// status-less pages must be fresh so a relaunch doesn't page every
    /// session that has been sitting idle for days.
    static func mayOpen(kind: InterventionKind, status: ClaudeSessionStatus,
                        stateStart: Date, now: Date, settings: DetectorSettings) -> Bool {
        if status == .waiting { return true }
        return now.timeIntervalSince(stateStart) <= settings.maxOpenAge
    }

    static func classify(_ tool: PendingToolUse) -> (InterventionKind, String?) {
        switch tool.name {
        case "AskUserQuestion": return (.question, nil)
        case "ExitPlanMode": return (.permission, "plan")
        default: return (.permission, nil)
        }
    }

    static let contextLimit = 1500

    /// Pure. How hard the pending tool calls are to take back, from their
    /// structured input (never the display text); the worst of them when
    /// several wait at once. `possibly` is a status-less guess that a prompt
    /// is showing at all, so it is never better than Considered. nil when
    /// there is no call, or one without its input.
    static func reversibility(of tools: [PendingToolUse], cwd: String, possibly: Bool = false) -> Reversibility.Verdict? {
        guard !tools.isEmpty else { return nil }
        var calls: [(name: String, input: [String: Any])] = []
        for t in tools {
            guard let fields = t.fields else { return nil }
            calls.append((t.name, fields))
        }
        guard var v = Reversibility.classify(calls: calls, cwd: cwd.isEmpty ? nil : cwd) else { return nil }
        if possibly, v.level < .considered {
            v = Reversibility.Verdict(level: .considered, tags: v.tags, reason: "may not be waiting for approval")
        }
        // The reason can quote the command; it is shown, so it is redacted.
        v.reason = ContextRedactor.redact(v.reason)
        return v
    }

    /// With several tool calls in flight (parallel calls), some may already
    /// be running auto-approved, so we can't know which one the menu is
    /// for: list them all rather than present one as "the" prompt.
    static func approvalContext(_ tools: [PendingToolUse]) -> String {
        guard let first = tools.first else { return "" }
        if tools.count == 1 { return clip(labelled(first), contextLimit) }
        let each = max(120, (contextLimit - 40) / tools.count)
        let lines = tools.map { "• " + clip(labelled($0), each) }
        return clip("One of these is waiting for approval:\n" + lines.joined(separator: "\n"), contextLimit)
    }

    /// A Task/Agent call that's pending means its subagent is the one
    /// asking; the Task description itself isn't what's being approved.
    private static func labelled(_ tool: PendingToolUse) -> String {
        (tool.name == "Task" || tool.name == "Agent") ? "A subagent is asking for approval\n" + tool.summary : tool.summary
    }

    static func idleContext(_ tail: TranscriptTail) -> String {
        guard let text = tail.lastAssistantText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return "Claude finished its turn" }
        // The end of a reply is where Claude asks for the next step.
        return clipKeepingEnd(ContextRedactor.redactedSuffix(text, contextLimit), contextLimit)
    }

    // MARK: transcript parsing (pure, unit-tested)

    /// Parses JSONL transcript text (typically the last few hundred KB).
    /// Lines that aren't JSON objects — including a partial first line from a
    /// mid-file seek — are skipped. Sidechain (subagent) records are ignored.
    static func parseTranscriptTail(_ text: String) -> TranscriptTail {
        var tail = TranscriptTail()
        var pendingOrder: [String] = []
        var pendingById: [String: PendingToolUse] = [:]
        var textsSinceLastTool: [String] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.first == "{",
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if obj["isSidechain"] as? Bool == true { continue }
            if let c = obj["cwd"] as? String, !c.isEmpty { tail.cwd = c }
            if let ts = obj["timestamp"] as? String, let d = TranscriptParser.parseISODate(ts) { tail.lastEventAt = d }

            guard let type = obj["type"] as? String, type == "assistant" || type == "user",
                  let message = obj["message"] as? [String: Any] else { continue }
            let content = message["content"]

            if type == "assistant" {
                tail.lastMeaningfulRole = .assistant
                if let s = content as? String, !s.isEmpty { textsSinceLastTool.append(s) }
                for item in (content as? [[String: Any]]) ?? [] {
                    switch item["type"] as? String {
                    case "text":
                        if let t = item["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            textsSinceLastTool.append(t)
                        }
                    case "tool_use":
                        guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
                        let input = item["input"] as? [String: Any] ?? [:]
                        if pendingById[id] == nil { pendingOrder.append(id) }
                        pendingById[id] = PendingToolUse(id: id, name: name,
                                                         summary: describeToolUse(name: name, input: input),
                                                         fields: Reversibility.classifierFields(toolName: name, input: input),
                                                         asked: name == "AskUserQuestion" ? AskedQuestionSet.parse(toolUseId: id, input: input) : nil)
                        // Text before a tool call is narration, not the answer.
                        textsSinceLastTool.removeAll()
                    default:
                        break
                    }
                }
            } else {
                tail.lastMeaningfulRole = .user
                var sawToolResult = false
                for item in (content as? [[String: Any]]) ?? [] where item["type"] as? String == "tool_result" {
                    sawToolResult = true
                    if let id = item["tool_use_id"] as? String { pendingById.removeValue(forKey: id) }
                }
                textsSinceLastTool.removeAll()
                if !sawToolResult {
                    // A real user message: nothing from before it is pending.
                    pendingById.removeAll()
                }
            }
        }

        tail.pendingToolUses = pendingOrder.compactMap { pendingById[$0] }
        if tail.lastMeaningfulRole == .assistant, !textsSinceLastTool.isEmpty {
            tail.lastAssistantText = textsSinceLastTool.joined(separator: "\n\n")
        }
        return tail
    }

    /// One-glance description of a tool call: the full command / path /
    /// question, which is what the user needs to approve safely. Every input
    /// value is redacted (ContextRedactor) before it is clipped.
    static func describeToolUse(name: String, input: [String: Any]) -> String {
        func str(_ k: String) -> String? {
            (input[k] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil : ContextRedactor.redactedPrefix($0, contextLimit)
            }
        }
        switch name {
        case "Bash":
            var s = "[Bash] " + (str("command") ?? "(no command)")
            if let d = str("description") { s += "\n" + d }
            return clip(s, contextLimit)
        case "Edit":
            var s = "[Edit] " + (str("file_path") ?? "?")
            if let old = str("old_string") { s += "\n- " + clip(old, 500) }
            if let new = str("new_string") { s += "\n+ " + clip(new, 500) }
            return clip(s, contextLimit)
        case "MultiEdit":
            let n = (input["edits"] as? [Any])?.count ?? 0
            return "[MultiEdit] " + (str("file_path") ?? "?") + " (\(n) edit\(n == 1 ? "" : "s"))"
        case "Write":
            var s = "[Write] " + (str("file_path") ?? "?")
            if let c = str("content") { s += "\n" + clip(c, 800) }
            return clip(s, contextLimit)
        case "NotebookEdit":
            return "[NotebookEdit] " + (str("notebook_path") ?? "?")
        case "Read":
            return "[Read] " + (str("file_path") ?? "?")
        case "Glob", "Grep":
            var s = "[\(name)] " + (str("pattern") ?? "?")
            if let p = str("path") { s += " in " + p }
            return clip(s, contextLimit)
        case "WebFetch":
            return clip("[WebFetch] " + (str("url") ?? "?"), contextLimit)
        case "WebSearch":
            return clip("[WebSearch] " + (str("query") ?? "?"), contextLimit)
        case "Task", "Agent":
            var s = "[\(name)] " + (str("description") ?? "subagent")
            if let p = str("prompt") { s += "\n" + clip(p, 800) }
            return clip(s, contextLimit)
        case "ExitPlanMode":
            return clip("Plan ready for review:\n" + (str("plan") ?? "(plan not in transcript)"), contextLimit)
        case "AskUserQuestion":
            return clip(ContextRedactor.redactedPrefix(describeQuestions(input), contextLimit), contextLimit)
        default:
            var s = "[\(name)]"
            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8), json != "{}" {
                s += " " + ContextRedactor.redactedPrefix(json, contextLimit)
            }
            return clip(s, contextLimit)
        }
    }

    /// "Question?\n1. Label — description\n2. …" for each question.
    static func describeQuestions(_ input: [String: Any]) -> String {
        let questions = input["questions"] as? [[String: Any]] ?? []
        guard !questions.isEmpty else { return "Claude has a question" }
        return questions.map { q in
            var lines = [(q["question"] as? String) ?? (q["header"] as? String) ?? "Question"]
            for (i, opt) in ((q["options"] as? [[String: Any]]) ?? []).enumerated() {
                var line = "\(i + 1). " + ((opt["label"] as? String) ?? "?")
                if let d = opt["description"] as? String, !d.isEmpty { line += " — " + clip(d, 160) }
                lines.append(line)
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    static func clip(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    static func clipKeepingEnd(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : "…" + String(s.suffix(max - 1))
    }

    // MARK: IO

    private func cachedTail(_ url: URL) -> (TranscriptTail?, Date?) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              let mtime = attrs[.modificationDate] as? Date else { return (nil, nil) }
        if let c = tailCache[url.path], c.size == size, c.mtime == mtime { return (c.tail, mtime) }
        guard let tail = Self.readTranscriptTail(url) else { return (nil, mtime) }
        tailCache[url.path] = (size, mtime, tail)
        return (tail, mtime)
    }

    /// Reads and parses the end of a transcript: 256 KB first, then 2 MB if
    /// that window held no assistant/user message (a single tool result or
    /// API record can be tens of KB).
    static func readTranscriptTail(_ url: URL) -> TranscriptTail? {
        guard let first = readTail(of: url, maxBytes: 256 * 1024) else { return nil }
        let tail = parseTranscriptTail(first.text)
        if tail.lastMeaningfulRole == nil, first.truncated,
           let bigger = readTail(of: url, maxBytes: 2 * 1024 * 1024) {
            return parseTranscriptTail(bigger.text)
        }
        return tail
    }

    /// Reads the last `maxBytes` of a file. Drops the first (possibly
    /// partial) line when the read starts mid-file, and decodes leniently so
    /// a write that ends mid-UTF-8-sequence doesn't discard the whole tail.
    static func readTail(of url: URL, maxBytes: Int) -> (text: String, truncated: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let truncated = size > UInt64(maxBytes)
        let offset = truncated ? size - UInt64(maxBytes) : 0
        do { try handle.seek(toOffset: offset) } catch { return nil }
        guard let data = try? handle.readToEnd() else { return ("", truncated) }
        var text = String(decoding: data, as: UTF8.self)
        if truncated, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return (text, truncated)
    }

    // MARK: event construction

    private func effectiveStart(for session: ClaudeLiveSession, proposal p: DetectorDecision.Proposal, now: Date) -> Date {
        guard session.status == .waiting, let key = p.promptKey else { return p.stateStart }
        if let rec = promptStarts[session.pid], rec.statusStart == p.stateStart {
            if rec.promptKey == key { return rec.effectiveStart }
            // Same waiting period, different prompt: a new intervention.
            let start = max(now, rec.effectiveStart.addingTimeInterval(1))
            promptStarts[session.pid] = (p.stateStart, key, start)
            return start
        }
        promptStarts[session.pid] = (p.stateStart, key, p.stateStart)
        return p.stateStart
    }

    private func makeEvent(session: ClaudeLiveSession, proposal p: DetectorDecision.Proposal,
                           start: Date, tail: TranscriptTail?, transcriptPath: String) -> InterventionEvent {
        let cwd = session.cwd ?? tail?.cwd ?? ""
        return InterventionEvent(
            id: Self.interventionId(sessionId: session.sessionId, kind: p.kind, stateStart: start),
            sessionId: session.sessionId,
            cwd: cwd,
            projectName: cwd.isEmpty ? "Claude" : Self.projectName(forCwd: cwd),
            kind: p.kind,
            openedAt: start,
            // Parts were redacted before clipping; this pass covers anything
            // composed around them (idempotent).
            context: p.context.isEmpty ? "Session waiting for input" : ContextRedactor.redact(p.context),
            transcriptPath: transcriptPath,
            backend: .claude,
            source: .terminal,
            subtype: p.subtype,
            pid: session.pid,
            stateStartedAt: p.stateStart,
            promptKey: p.promptKey,
            // Only an approval raised for a tool call (it has a prompt key) is classified.
            reversibility: (p.kind == .permission || p.kind == .plan) && p.promptKey != nil
                ? Self.reversibility(of: tail?.pendingToolUses ?? [], cwd: cwd, possibly: session.status == .unknown)
                : nil
        )
    }

    static func interventionId(sessionId: String, kind: InterventionKind, stateStart: Date) -> String {
        "\(sessionId)-\(kind.rawValue)-\(Int(stateStart.timeIntervalSince1970))"
    }

    /// Inverse of `interventionId` for detector-owned ids: (sessionId, kind,
    /// state-start epoch). nil for hook-/codex-/other ids.
    static func parseInterventionId(_ id: String) -> (sessionId: String, kind: String, epoch: TimeInterval)? {
        let parts = id.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7, let epoch = TimeInterval(parts[6]) else { return nil }
        let sid = parts[0..<5].joined(separator: "-")
        guard ClaudeSessionRegistry.isValidSessionId(sid) else { return nil }
        return (sid, parts[5], epoch)
    }

    private static let projectNameLock = NSLock()
    private static var projectNameCache: [String: String] = [:]

    /// Walks up from `cwd` looking for any common project marker (`.git`,
    /// `Package.swift`, `package.json`, etc.) and returns that folder's name.
    /// If nothing matches and the cwd's basename looks like a generic
    /// subdirectory (`iOS`, `src`, ...), backs up one level. Otherwise
    /// returns the basename as-is. Cached per cwd (it stats up to ~400 paths).
    static func projectName(forCwd cwd: String) -> String {
        projectNameLock.lock()
        if let cached = projectNameCache[cwd] { projectNameLock.unlock(); return cached }
        projectNameLock.unlock()

        let markers = [".git", "Package.swift", "package.json", "Cargo.toml",
                       "pyproject.toml", "go.mod", "pom.xml", "platformio.ini",
                       "Gemfile", "build.gradle", "build.gradle.kts", "wrangler.toml"]
        let genericSubdirs: Set<String> = [
            "iOS", "android", "src", "test", "tests", "app", "lib",
            "Sources", "Cloudflare", "frontend", "backend",
            "hooks", "Tools", "Resources", "Designs"
        ]
        let fm = FileManager.default
        var name: String?
        var current = URL(fileURLWithPath: cwd)
        search: for _ in 0..<32 where current.path != "/" {
            for marker in markers where fm.fileExists(atPath: current.appendingPathComponent(marker).path) {
                name = current.lastPathComponent
                break search
            }
            current = current.deletingLastPathComponent()
        }
        if name == nil {
            let base = URL(fileURLWithPath: cwd)
            name = genericSubdirs.contains(base.lastPathComponent)
                ? base.deletingLastPathComponent().lastPathComponent
                : base.lastPathComponent
        }
        let result = name ?? cwd
        projectNameLock.lock()
        if projectNameCache.count > 500 { projectNameCache.removeAll() }
        projectNameCache[cwd] = result
        projectNameLock.unlock()
        return result
    }
}

extension TranscriptParser {
    private static let isoWithFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO8601 timestamp parser for transcript lines (with or without
    /// fractional seconds). ISO8601DateFormatter is thread-safe, so the
    /// formatters are shared rather than allocated per line.
    static func parseISODate(_ s: String) -> Date? {
        isoWithFractions.date(from: s) ?? isoPlain.date(from: s)
    }
}
