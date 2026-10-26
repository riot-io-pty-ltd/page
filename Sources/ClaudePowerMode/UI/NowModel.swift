import Foundation

// The pure model behind the menu-bar popover ("Now"): built from what the
// Coordinator already publishes, with no clock, config, host or bridge calls
// inside. Views only draw it; tests feed it values.

// MARK: - Chips, keys, receipts

/// The label on a row: how reversible a pending action is, or why it is here.
enum ChipKind: String, Equatable, CaseIterable {
    case irreversible, considered, undoable
    case looksStuck, question, forecast, rateLimited, review

    /// All caps, as drawn.
    var title: String {
        switch self {
        case .irreversible: return "IRREVERSIBLE"
        case .considered: return "CONSIDERED"
        case .undoable: return "UNDOABLE"
        case .looksStuck: return "LOOKS STUCK"
        case .question: return "QUESTION"
        case .forecast: return "HEADS UP"
        case .rateLimited: return "RATE LIMITED"
        case .review: return "FINISHED"
        }
    }

    init(_ r: Reversibility) {
        switch r {
        case .undoable: self = .undoable
        case .considered: self = .considered
        case .irreversible: self = .irreversible
        }
    }
}

/// One key a row answers to, and what it does. The keystroke truth is fixed
/// here and in the Mac reply planner: approve types option 1, deny presses
/// Esc, "tell it instead" is Esc then text then Return; there is no key that
/// sends 2, and none that approves "and don't ask again".
struct KeyHint: Equatable {
    enum Action: String, Equatable {
        /// Type option 1.
        case approve
        /// Type option 1, behind a press-and-hold (and Touch ID).
        case approveHold
        /// Press Esc.
        case deny
        /// Esc, then the user's text, then Return.
        case tellInstead
        /// Focus the exact terminal, iTerm2 or cmux pane.
        case openTerminal
    }

    let label: String
    let action: Action
    var isHold: Bool { action == .approveHold }
}

/// The receipt for a keystroke Page delivered (or could not).
struct DeliveryReceipt: Equatable {
    enum Verb: String, Equatable { case approved = "Approved", denied = "Denied", replied = "Replied to", stopped = "Stopped" }

    /// What happened, in the words the trust model fixes for each outcome.
    enum Outcome: Equatable {
        case delivered
        case timedOut
        case sessionEnded
        case notTypable
        case queued
        case promptClosed
        case answeredAtMac
        case unknownState
        /// A failure the backend described in its own words.
        case other(String)

        /// The sentence for a failure; nil for `.delivered`.
        var failureMessage: String? {
            switch self {
            case .delivered: return nil
            case .timedOut: return "Didn't confirm in time · Check on Mac"
            case .sessionEnded: return "Session ended"
            case .notTypable: return "This terminal can't take input · Open on Mac"
            case .queued: return "Queued after this turn"
            case .promptClosed: return "Prompt closed before your answer"
            case .answeredAtMac: return "Already answered at the Mac"
            case .unknownState: return "Review again"
            case .other(let why): return why.isEmpty ? "Couldn't deliver the reply" : why
            }
        }
    }

    let verb: Verb
    /// "npm test".
    let subject: String
    /// "cmux › page".
    let route: String
    let at: Date
    var outcome: Outcome = .delivered

    /// Pure. "Approved npm test → cmux › page · verified 23:47:12"; a failure
    /// reads "<subject> · <what went wrong and what to do>".
    func line(timeZone: TimeZone = .current) -> String {
        if let why = outcome.failureMessage { return "\(subject) · \(why)" }
        return "\(verb.rawValue) \(subject) → \(route) · verified \(NowModel.clock(at, seconds: true, timeZone: timeZone))"
    }
}

// MARK: - Rows

/// One line in the Now stream: something that needs a decision, a look, or a
/// review.
struct DecideRow: Equatable, Identifiable {
    enum Section: Int, Equatable, Comparable {
        /// Approvals, plan approvals, questions: the agent is blocked on you.
        case decide = 0
        /// Stuck, rate-limited, forecasts that need a choice.
        case look = 1
        /// A finished turn waiting for you.
        case review = 2
        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let sessionId: String
    let projectName: String
    let backend: AgentBackendID
    let section: Section
    let chip: ChipKind
    /// The command, or a one-line summary: "rm -rf Builds/Dev/*.app".
    let summary: String
    /// Keys drawn on the row.
    let keys: [KeyHint]
    /// Keys that work but are not drawn (T and O on an approval).
    let moreKeys: [KeyHint]
    /// What Return does: only ever approve on an Undoable item, otherwise
    /// nothing, or O on an Irreversible one.
    let returnAction: KeyHint.Action?
    /// "Will type 1 · cmux › page · Studio MBP"; nil when Page cannot type here.
    let approvePreview: String?
    /// "Will press Esc · cmux › page · Studio MBP".
    let denyPreview: String?
    /// "Esc, then your message · cmux › page · Studio MBP".
    let tellPreview: String?
    let waitingSince: Date
    let reversibility: Reversibility?
    let tags: [Reversibility.Tag]
    let reason: String

    /// The line shown under the focused row.
    var focusPreview: String? { approvePreview ?? tellPreview ?? denyPreview }
}

// MARK: - Runway

/// A deadline or event on the next six hours.
struct RunwayMarker: Equatable, Identifiable {
    enum Kind: String, Equatable { case batteryCutoff, usageLimit, usageReset, weeklyReset, resume }
    enum Tone: String, Equatable { case amber, green, blue }

    let id: String
    let kind: Kind
    /// "5h 02:40", "reset 03:00", "resume 04:10", "cutoff 03:40".
    let label: String
    let at: Date
    /// 0 (now) ... 1 (end of the window), clamped.
    let fraction: Double
    let tone: Tone
    /// 0 or 1: a second row when two labels would overlap.
    var lane: Int = 0
}

struct RunwayModel: Equatable {
    /// How far ahead the runway looks.
    static let window: TimeInterval = 6 * 3600

    var markers: [RunwayMarker]
    /// On AC (or no battery) the runway is a full horizon line: no cutoff.
    var onAC: Bool
    /// Earliest deadline (battery cutoff or 5h limit hit), if any.
    var clearUntil: Date?

    /// Pure. Position of `at` across the window: 0 now, 1 at the end,
    /// clamped. nil when it is already past or beyond the window.
    static func fraction(of at: Date, now: Date, window: TimeInterval = RunwayModel.window) -> Double? {
        let dt = at.timeIntervalSince(now)
        guard dt >= 0, dt <= window else { return nil }
        return dt / window
    }

    /// Pure. Gives a marker whose label would overlap the previous one in its
    /// lane a second lane. `minGap` is the least fraction between labels in a
    /// lane (about one label width).
    static func assignLanes(_ markers: [RunwayMarker], minGap: Double = 0.15) -> [RunwayMarker] {
        var lastInLane: [Int: Double] = [:]
        var out: [RunwayMarker] = []
        for var m in markers.sorted(by: { $0.fraction < $1.fraction }) {
            let lane = (lastInLane[0].map { m.fraction - $0 < minGap } ?? false) ? 1 : 0
            m.lane = lane
            lastInLane[lane] = m.fraction
            out.append(m)
        }
        return out
    }
}

// MARK: - Day rings

/// "Unblocked, Shipped, Calm": three daily rings.
struct RingStat: Equatable, Identifiable {
    enum Kind: String, Equatable { case unblocked = "Unblocked", shipped = "Shipped", calm = "Calm" }
    let kind: Kind
    /// 0...1.
    let progress: Double
    /// "11 / 12", "7 / 10", "4 h 10 m".
    let detail: String
    var id: String { kind.rawValue }
}

/// What the day's log says; built by the caller from the audit log.
struct DayStats: Equatable {
    /// Decisions answered in under two minutes, of all decisions.
    var unblockedFast: Int = 0
    var decisions: Int = 0
    /// Turns that finished, of all finished or stuck turns.
    var shipped: Int = 0
    var finished: Int = 0
    /// Seconds agents ran without you.
    var calmSeconds: TimeInterval = 0
    /// What counts as a full Calm ring.
    var calmGoal: TimeInterval = 4 * 3600

    /// Pure.
    var rings: [RingStat] {
        func frac(_ a: Int, _ b: Int) -> Double { b > 0 ? min(1, Double(a) / Double(b)) : 0 }
        return [
            RingStat(kind: .unblocked, progress: frac(unblockedFast, decisions),
                     detail: decisions > 0 ? "\(unblockedFast) / \(decisions)" : "none yet"),
            RingStat(kind: .shipped, progress: frac(shipped, finished),
                     detail: finished > 0 ? "\(shipped) / \(finished)" : "none yet"),
            RingStat(kind: .calm, progress: calmGoal > 0 ? min(1, max(0, calmSeconds / calmGoal)) : 0,
                     detail: NowModel.duration(seconds: calmSeconds))
        ]
    }
}

// MARK: - Welcome back

/// The panel that drops for a few seconds when you sit back down.
struct WelcomeBack: Equatable {
    /// "WELCOME BACK · AWAY 52 MIN"
    let eyebrow: String
    /// "2 finished, 1 needs you."
    let headline: String
    let rings: [RingStat]
    /// Something needs you (the headline says so; the panel stays teal, as on the board).
    var needsYou = false

    /// Short absences are not worth a panel.
    static let minimumAway: TimeInterval = 10 * 60
    /// How long the panel stays up.
    static let displayDuration: TimeInterval = 8

    static func isWorthShowing(away: TimeInterval) -> Bool { away >= minimumAway }

    /// Pure. `handledOnPhone` is how many pages you answered from the phone
    /// while away.
    static func build(away: TimeInterval, finished: Int, needYou: Int, handledOnPhone: Int,
                      rings: [RingStat]) -> WelcomeBack {
        let eyebrow = "WELCOME BACK · AWAY \(NowModel.duration(seconds: away, upper: true))"
        let headline: String
        if needYou == 0 && handledOnPhone > 0 {
            headline = "You handled \(handledOnPhone) from your phone."
        } else if finished == 0 && needYou == 0 {
            headline = "Nothing needed you."
        } else {
            let fin = finished > 0 ? "\(finished) finished" : nil
            let need = needYou > 0 ? (needYou == 1 ? "1 needs you" : "\(needYou) need you") : nil
            headline = [fin, need].compactMap { $0 }.joined(separator: ", ") + "."
        }
        return WelcomeBack(eyebrow: eyebrow, headline: headline, rings: rings, needsYou: needYou > 0)
    }
}

// MARK: - Inputs

/// Everything `NowModel.build` reads. Plain values, so the harness and tests
/// can supply any situation.
struct NowInputs {
    var snapshot: Coordinator.Snapshot
    /// `config.lowBatteryCutoff`.
    var cutoff: Int = 10
    /// `config.recoveryThreshold`.
    var recoveryThreshold: Int = 25
    var now: Date
    /// "Studio MBP": every action names the Mac it will act on.
    var macName: String
    /// Seconds since the last real keyboard/mouse input (UserPresence).
    var idleSeconds: TimeInterval = 0
    /// `config.idlePageOnlyWhenAwaySeconds`: past this idle time the phone is
    /// paged for finished turns. 0 means the check is off.
    var awayAfter: TimeInterval = 120
    /// Claude's 5-hour / 7-day usage, when captured.
    var usage: UsageSnapshot?
    /// When the 5-hour window hits 100% at the current pace (UsageForecast).
    var usageHitAt: Date?
    var receipts: [DeliveryReceipt] = []
    var day: DayStats?
    /// "cmux › page" for the pane Page would type into, nil when unknown.
    var route: (InterventionEvent) -> String? = { _ in nil }
    /// Why Page cannot type into the session's terminal (a blocked host), if
    /// it knows. nil: unknown or typable.
    var blocker: (InterventionEvent) -> String? = { _ in nil }
    /// Paused sessions whose transcript shows the summary Page asked for.
    var summarised: Set<String> = []
    var timeZone: TimeZone = .current
}

// MARK: - The model

struct NowModel: Equatable {
    /// Which aurora and pulse colour the header uses.
    enum Mood: String, Equatable { case needsYou, working, quiet, dusk }

    struct PausedAgent: Equatable, Identifiable {
        let id: String
        let project: String
        /// "Claude · paused 02:14".
        let detail: String
        /// The transcript shows the summary Page asked for ("summary ✓").
        var summaryWritten: Bool = false
    }

    /// An agent working right now, for the In-flight strip.
    struct InFlightAgent: Equatable, Identifiable {
        let id: String
        let project: String
        let backend: AgentBackendID
    }

    var mood: Mood
    /// "2 need you · 5 working", "All quiet", "Paused at 10%".
    var headline: String
    /// "runway clear till 03:40 · lid can close".
    var subline: String
    var needYouCount: Int
    var lookCount: Int
    var reviewCount: Int
    var workingCount: Int
    /// Decide rows first (Irreversible first), then Look, then Review.
    var rows: [DecideRow]
    var runway: RunwayModel
    /// The latest receipt, as a line; nil when none is recent.
    var receiptLine: String?
    /// The latest receipt is a failure (drawn amber, not teal).
    var receiptFailed = false
    /// Set while agents are paused (or being paused) for battery.
    var paused: [PausedAgent]
    var canResumeNow: Bool
    /// "Phone paging armed · you're away"; nil when the relay is off.
    var phoneLine: String?
    var rings: [RingStat]
    var glyph: GlyphState
    var macName: String
    /// Sessions working now (the In-flight strip), longest-running first is unknown, so by name.
    var inFlight: [InFlightAgent] = []
    /// Sessions Stop all would press Esc in.
    var stoppableCount: Int = 0
    /// Spoken by VoiceOver on the status item.
    var accessibilityLabel: String
    var footerHints: String = "⌘N new · ⌘. hold to stop all"
    var shortcutHint: String = "⌥⌘P"
    /// config.json is unreadable or had values corrected: Page is using safe
    /// values. Drawn as an amber line with "Open config…".
    var configProblem: String? = nil

    /// Rows on the compact popover before "+N more".
    static let visibleRows = 3

    var attentionCount: Int { needYouCount + lookCount }
    var overflowRows: Int { max(0, rows.count - Self.visibleRows) }

    // MARK: build

    /// Pure. Counts follow the board: "need you" is permission, plan and
    /// question pages (the agent is blocked); "look" is stuck agents,
    /// rate limits and forecasts; "review" is finished turns. "Working" is
    /// sessions the backends report as active, plus busy local models.
    static func build(_ i: NowInputs) -> NowModel {
        let s = i.snapshot
        let tz = i.timeZone

        // Rows.
        var rows: [DecideRow] = []
        for ev in s.pendingInterventions {
            if let row = row(for: ev, macName: i.macName, route: i.route(ev), blocker: i.blocker(ev)) { rows.append(row) }
        }
        if let rl = s.activeRateLimit {
            rows.append(rateLimitRow(rl, timeZone: tz))
        }
        rows = ranked(rows)

        let need = rows.filter { $0.section == .decide }.count
        let look = rows.filter { $0.section == .look }.count
        let review = rows.filter { $0.section == .review }.count
        let working = s.sessions.filter { $0.state == .active }.count + s.localModels.filter(\.busy).count

        // Runway.
        let runway = runwayModel(s, now: i.now, usage: i.usage, usageHitAt: i.usageHitAt, timeZone: tz)

        // Battery pause.
        let phase = s.battery.phase
        let pausing = phase != .normal
        let pausedAgents = s.battery.paused.sorted { $0.pausedAt > $1.pausedAt }.map {
            PausedAgent(id: $0.sessionId, project: $0.projectName,
                        detail: "\(AppDelegate.agentName($0.backend)) · paused \(clock($0.pausedAt, timeZone: tz))",
                        summaryWritten: i.summarised.contains($0.sessionId))
        }

        let mood: Mood = pausing ? .dusk : (need + look > 0 ? .needsYou : (working > 0 ? .working : .quiet))

        let headline: String
        let subline: String
        if pausing {
            (headline, subline) = pauseLines(s, cutoff: i.cutoff, recovery: i.recoveryThreshold, now: i.now, timeZone: tz,
                                             summarised: i.summarised)
        } else if need > 0 {
            headline = working > 0 ? "\(need) \(need == 1 ? "needs" : "need") you · \(working) working"
                                    : "\(need) \(need == 1 ? "needs" : "need") you"
            subline = runwayLine(s, runway: runway, timeZone: tz)
        } else if look > 0 {
            headline = working > 0 ? "\(look) \(look == 1 ? "needs" : "need") a look · \(working) working"
                                    : "\(look) \(look == 1 ? "needs" : "need") a look"
            subline = runwayLine(s, runway: runway, timeZone: tz)
        } else {
            headline = "All quiet"
            subline = working > 0 ? "\(working) working · nothing needs you" : "no agents running · nothing needs you"
        }

        // Presence and the phone.
        let atDesk = i.awayAfter > 0 && i.idleSeconds < i.awayAfter
        let armed = s.relayConnected && !atDesk
        let phoneLine: String?
        switch s.relayState {
        case .connected:
            phoneLine = armed ? "Phone paging armed · you're away" : "Phone quiet · you're at the Mac"
        case .connecting: phoneLine = "Phone relay connecting…"
        case .misconfigured: phoneLine = "Phone relay not set up"
        case .off: phoneLine = nil
        }

        let latestReceipt = i.receipts.filter { i.now.timeIntervalSince($0.at) < 15 * 60 && $0.at <= i.now.addingTimeInterval(60) }
            .max(by: { $0.at < $1.at })
        let receipt = latestReceipt?.line(timeZone: tz)

        // Glyph.
        let mode = GlyphState.mode(paused: pausing, needYou: need > 0 ? need : look,
                                   working: working, keepingAwake: s.boosting)
        let glyph = GlyphState(
            mode: mode,
            lidClosedAwake: s.awake.preventSystemSleep || s.lidClosedOnBattery,
            headroom: GlyphState.headroom(power: s.power, cutoff: i.cutoff),
            phoneArmed: armed,
            waiting: pausing ? (need > 0 ? need : look) : 0)

        return NowModel(
            mood: mood, headline: headline, subline: subline,
            needYouCount: need, lookCount: look, reviewCount: review, workingCount: working,
            rows: rows, runway: runway, receiptLine: receipt, receiptFailed: latestReceipt.map { $0.outcome != .delivered } ?? false,
            paused: pausedAgents, canResumeNow: !s.battery.paused.isEmpty,
            phoneLine: phoneLine, rings: i.day?.rings ?? [], glyph: glyph, macName: i.macName,
            inFlight: inFlight(s), stoppableCount: s.sessions.filter { $0.state == .active }.count,
            accessibilityLabel: "Page — \(headline)", configProblem: s.configProblem)
    }

    /// Pure. Working sessions by project name, one entry per session.
    static func inFlight(_ s: Coordinator.Snapshot) -> [InFlightAgent] {
        s.sessions.filter { $0.state == .active }.map { a in
            let name = a.cwd.map { InterventionDetector.projectName(forCwd: $0) } ?? a.title ?? a.sessionId
            return InFlightAgent(id: a.sessionId, project: name, backend: a.backend)
        }.sorted { ($0.project, $0.id) < ($1.project, $1.id) }
    }

    /// The panel before the first snapshot: "Starting…".
    static func starting(macName: String) -> NowModel {
        NowModel(mood: .quiet, headline: "Starting…", subline: "checking your agents", needYouCount: 0, lookCount: 0,
                 reviewCount: 0, workingCount: 0, rows: [], runway: RunwayModel(markers: [], onAC: true, clearUntil: nil),
                 receiptLine: nil, paused: [], canResumeNow: false, phoneLine: nil, rings: [],
                 glyph: GlyphState(mode: .off), macName: macName, accessibilityLabel: "Page — starting")
    }

    // MARK: lines

    /// Pure. "runway clear till 03:40 · lid can close".
    static func runwayLine(_ s: Coordinator.Snapshot, runway: RunwayModel, timeZone: TimeZone) -> String {
        var parts: [String] = []
        if let end = runway.clearUntil {
            parts.append("runway clear till \(clock(end, timeZone: timeZone))")
        } else if s.power.hasBattery && !s.power.onAC {
            parts.append("on battery · \(s.power.percent)%")
        } else {
            parts.append("runway clear")
        }
        if runway.clearUntil != nil, s.power.hasBattery, !s.power.onAC { parts.append("\(s.power.percent)%") }
        // Only what Page knows: the lid-closed assertion is held, not that the lid is shut.
        if s.awake.preventSystemSleep || s.lidClosedOnBattery { parts.append("lid can close") }
        return parts.joined(separator: " · ")
    }

    /// Pure. The headline and subline while paused or pausing for battery.
    static func pauseLines(_ s: Coordinator.Snapshot, cutoff: Int, recovery: Int, now: Date,
                           timeZone: TimeZone, summarised: Set<String> = []) -> (String, String) {
        let n = s.battery.paused.count
        switch s.battery.phase {
        case .grace:
            var sub = "agents are asked to summarise"
            if let end = s.battery.graceEndsAt, end > now { sub += " · awake till \(clock(end, timeZone: timeZone))" }
            return ("Pausing at \(cutoff)%", sub)
        case .drained:
            guard n > 0 else {
                return ("Low battery", "not keeping the Mac awake · plug in to continue")
            }
            // "summarised" only when every paused session's transcript shows its summary.
            let all = s.battery.paused.allSatisfy { summarised.contains($0.sessionId) }
            let who = "\(n) agent\(n == 1 ? "" : "s") \(all ? "summarised" : "paused")"
            return ("Paused at \(cutoff)%", s.power.onAC ? "\(who) · resumes at \(recovery)%" : "\(who) · plug in to resume")
        case .normal:
            return ("", "")
        }
    }

    // MARK: runway

    /// Pure.
    static func runwayModel(_ s: Coordinator.Snapshot, now: Date, usage: UsageSnapshot?, usageHitAt: Date?,
                            timeZone: TimeZone) -> RunwayModel {
        var markers: [RunwayMarker] = []
        var deadlines: [Date] = []

        func add(_ id: String, _ kind: RunwayMarker.Kind, _ prefix: String, _ at: Date, _ tone: RunwayMarker.Tone) {
            guard let f = RunwayModel.fraction(of: at, now: now) else { return }
            markers.append(RunwayMarker(id: id, kind: kind, label: "\(prefix) \(clock(at, timeZone: timeZone))",
                                        at: at, fraction: f, tone: tone))
        }

        let onAC = !s.power.hasBattery || s.power.onAC
        if !onAC, let e = s.batteryForecast {
            let at = now.addingTimeInterval(TimeInterval(e.minutesToCutoff) * 60)
            deadlines.append(at)
            add("battery-cutoff", .batteryCutoff, "cutoff", at, .amber)
        }
        if let hit = usageHitAt, hit > now {
            deadlines.append(hit)
            add("usage-limit", .usageLimit, "5h", hit, .amber)
        }
        if let reset = usage?.fiveHour?.resetsAt { add("usage-reset", .usageReset, "reset", reset, .green) }
        if let weekly = usage?.sevenDay?.resetsAt { add("weekly-reset", .weeklyReset, "7d reset", weekly, .green) }
        for sr in s.scheduledResumes {
            add("resume-\(sr.sessionId)", .resume, "resume", sr.effectiveRunAt, .blue)
        }
        return RunwayModel(markers: RunwayModel.assignLanes(markers), onAC: onAC, clearUntil: deadlines.min())
    }

    // MARK: rows

    /// Pure. Decide rows first, Irreversible before anything else, then the
    /// longest wait first; then Look, then Review, each longest wait first.
    static func ranked(_ rows: [DecideRow]) -> [DecideRow] {
        rows.sorted { a, b in
            if a.section != b.section { return a.section < b.section }
            // A question has no class; it ranks with the Considered items.
            let ra = a.reversibility?.rawValue ?? (a.chip == .question ? Reversibility.considered.rawValue : -1)
            let rb = b.reversibility?.rawValue ?? (b.chip == .question ? Reversibility.considered.rawValue : -1)
            if ra != rb { return ra > rb }
            if a.waitingSince != b.waitingSince { return a.waitingSince < b.waitingSince }
            return a.id < b.id
        }
    }

    /// Pure. Which section a page belongs to; nil for pages that are not rows.
    static func section(of ev: InterventionEvent) -> DecideRow.Section? {
        switch ev.kind {
        case .permission, .plan, .question: return .decide
        case .rateLimit: return nil // shown from the snapshot's active rate limit
        case .idle:
            if let sub = ev.subtype, ["looping", "stuck", "workflow_stalled"].contains(sub) { return .look }
            if isForecast(ev) { return .look }
            return .review
        }
    }

    static func isForecast(_ ev: InterventionEvent) -> Bool {
        BatteryForecast.isPageId(ev.id) || ev.id.hasPrefix("page-mac-usage_forecast-")
    }

    /// Pure. The row for a page, with the keys and previews its trust class allows.
    static func row(for ev: InterventionEvent, macName: String, route: String?, blocker: String? = nil) -> DecideRow? {
        guard let section = section(of: ev) else { return nil }
        // Pages another part of Page owns (the phone-approval hook) are answered at the Mac.
        let hookOwned = !MacReplyGate.isAnswerable(pageId: ev.id) && !isForecast(ev)

        func preview(_ action: String) -> String {
            [action, route, macName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let open = KeyHint(label: "O", action: .openTerminal)
        let tell = KeyHint(label: "T", action: .tellInstead)
        let esc = KeyHint(label: "esc", action: .deny)

        var chip: ChipKind
        var verdict: Reversibility.Verdict?
        var keys: [KeyHint]
        var more: [KeyHint] = []
        var returnAction: KeyHint.Action?
        var approve: String?
        var deny: String?
        var tellPreview: String? = preview("Esc, then your message")

        switch section {
        case .decide:
            if ev.kind == .question {
                chip = .question
                if ev.backend == .claude {
                    // A written answer is Esc, then the text, then Return; Esc alone dismisses it.
                    keys = [tell, esc]
                    more = [open]
                    deny = preview("Will press Esc")
                } else {
                    // Codex refuses a reply while a prompt is pending: answer it at the Mac.
                    keys = [open]
                    tellPreview = nil
                }
            } else if ev.backend != .claude {
                // Codex approvals are answered at the Mac; Page does not type them.
                chip = .considered
                keys = [open]
                returnAction = .openTerminal
                tellPreview = nil
                approve = "Answer in the terminal · Page can't approve \(AppDelegate.agentName(ev.backend)) prompts"
            } else {
                let v = Reversibility.classify(context: ev.context, cwd: ev.cwd)
                verdict = v
                chip = ChipKind(v.level)
                approve = preview("Will type 1")
                deny = preview("Will press Esc")
                more = [tell, open]
                switch v.level {
                case .undoable:
                    keys = [KeyHint(label: "↵", action: .approve), esc]
                    returnAction = .approve
                case .considered:
                    keys = [KeyHint(label: "1", action: .approve), esc]
                case .irreversible:
                    keys = [KeyHint(label: "hold 1", action: .approveHold), esc]
                    returnAction = .openTerminal
                }
            }
        case .look, .review:
            chip = section == .review ? .review : (isForecast(ev) ? .forecast : .looksStuck)
            if isForecast(ev) {
                // Forecasts belong to Page itself (no session to type into); their
                // actions come with the Tower.
                keys = []
                tellPreview = nil
            } else if ev.backend != .claude {
                keys = [open]
                tellPreview = nil
            } else {
                keys = [open, tell]
                // The reply planner types a message to a busy or finished session
                // (queued behind the turn); it never sends Esc or 1 here.
                tellPreview = preview("Your message, then Return")
            }
        }

        // Page cannot type into this terminal (or the page is the hook's): the
        // only honest key is O, and the preview says why instead of promising keystrokes.
        let why = hookOwned ? "Answer at the Mac · Page's hook is handling this prompt" : blocker.map { "Can't type here · \($0)" }
        if let why, !isForecast(ev), !keys.isEmpty {
            keys = [open]
            more = []
            returnAction = section == .decide ? .openTerminal : nil
            approve = section == .decide ? why : nil
            deny = nil
            tellPreview = nil
        }

        return DecideRow(
            id: ev.id, sessionId: ev.sessionId, projectName: ev.projectName, backend: ev.backend,
            section: section, chip: chip, summary: summaryLine(for: ev), keys: keys, moreKeys: more,
            returnAction: returnAction, approvePreview: approve, denyPreview: deny, tellPreview: tellPreview,
            waitingSince: ev.openedAt, reversibility: verdict?.level, tags: verdict?.tags ?? [],
            reason: verdict?.reason ?? "")
    }

    static func rateLimitRow(_ rl: RateLimitEvent, timeZone: TimeZone) -> DecideRow {
        DecideRow(
            id: "ratelimit-\(rl.uniqueId)", sessionId: rl.sessionId, projectName: rl.projectName, backend: rl.backend,
            section: .look, chip: .rateLimited,
            summary: "resets \(clock(rl.resetTime, timeZone: timeZone))",
            keys: [KeyHint(label: "O", action: .openTerminal)], moreKeys: [], returnAction: nil,
            approvePreview: nil, denyPreview: nil, tellPreview: nil, waitingSince: rl.eventTime,
            reversibility: nil, tags: [], reason: "")
    }

    /// Pure. The one line a row shows: the command for a Bash approval, the
    /// file for an edit, "cargo test failed 6×" for a loop, and so on.
    static func summaryLine(for ev: InterventionEvent) -> String {
        let text = ev.context.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let first = lines.first ?? ""

        if let sub = ev.subtype {
            switch sub {
            case "looping":
                // "Looks stuck in a loop: this has failed 6 times.\n<label>"
                let count = first.range(of: #"failed (\d+) times"#, options: .regularExpression)
                    .flatMap { Int(first[$0].filter(\.isNumber)) }
                let label = lines.dropFirst().first
                if let label, let count { return clip("\(label) failed \(count)×") }
                if let label { return clip(label) }
            case "stuck":
                // "No progress for 15 min — it may be hung."
                if let r = first.range(of: #"^No progress for \d+ min"#, options: .regularExpression) {
                    return "no progress for" + first[r].dropFirst("No progress for".count)
                }
            default: break
            }
        }
        if ev.kind == .idle { return clip(first) }

        if first.hasPrefix("One of these is waiting for approval") {
            let n = text.components(separatedBy: "\n• ").count - 1
            return "\(max(n, 2)) tool calls waiting"
        }
        if first.hasPrefix("Plan ready for review") { return "plan ready for review" }
        if first.hasPrefix("A subagent is asking for approval") {
            return clip(lines.dropFirst().first.map { stripTool($0) } ?? "a subagent is asking")
        }
        if first.hasPrefix("["), first.contains("]") {
            return clip(stripTool(first))
        }
        if first.isEmpty { return "waiting for you" }
        if first == "Claude is waiting for your approval" { return "waiting for your approval" }
        return clip(first)
    }

    /// "[Bash] rm -rf x" becomes "rm -rf x"; "[Edit] a.swift" becomes "edit a.swift".
    private static func stripTool(_ line: String) -> String {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        let name = String(line[line.index(after: line.startIndex)..<close])
        let rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        switch name {
        case "Bash": return rest
        case "Edit": return "edit \(rest)"
        case "MultiEdit": return "edit \(rest)"
        case "Write": return "write \(rest)"
        case "NotebookEdit": return "edit \(rest)"
        case "Read": return "read \(rest)"
        case "WebFetch", "WebSearch": return rest
        default: return "\(name.lowercased()) \(rest)".trimmingCharacters(in: .whitespaces)
        }
    }

    private static func clip(_ s: String, _ limit: Int = 96) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)) + "…"
    }

    // MARK: time

    /// Pure. 24-hour "03:40" (or "23:47:12" with seconds), as the boards show.
    static func clock(_ date: Date, seconds: Bool = false, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        let hm = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return seconds ? hm + String(format: ":%02d", c.second ?? 0) : hm
    }

    /// Pure. "52 min", "1 h 52 min", "4 h 10 m" style: minutes under an hour,
    /// else hours and minutes. `upper` gives "52 MIN" for labels.
    static func duration(seconds: TimeInterval, upper: Bool = false) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        let h = total / 60, m = total % 60
        let text: String
        if h == 0 { text = "\(max(1, m)) min" }
        else if m == 0 { text = "\(h) h" }
        else { text = "\(h) h \(m) min" }
        return upper ? text.uppercased() : text
    }
}
