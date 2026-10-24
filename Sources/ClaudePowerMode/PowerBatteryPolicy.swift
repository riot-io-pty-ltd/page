import Foundation

/// What Page does when the battery runs low — the "ask the AI to pause"
/// half of Page's core job.
///
/// A pure state machine: the Coordinator feeds it power readings and the
/// results of the work it asked for, and carries out the `Effect`s it
/// returns. Nothing here touches IOKit, the relay or the backends, so every
/// branch (AC vs battery, desktops, the cutoff edge, the grace period, a
/// crash mid-pause, recovery with and without AC) is unit-tested.
///
/// The whole value is Codable and persisted after every change
/// (`BatteryPauseStore`), so a crash — or the Mac going to sleep, which is
/// the point — never forgets which sessions Page paused or re-pauses them.
struct BatteryPolicy: Codable, Equatable {
    enum Phase: String, Codable, Equatable {
        /// Battery fine (or on AC / no battery). Agents drive the assertion.
        case normal
        /// Tripped; the agents have been asked to pause and the Mac is held
        /// awake until `graceEndsAt` so they can write their summary.
        case grace
        /// Tripped and the grace period is over: Page no longer keeps the
        /// Mac awake on battery, so it can sleep.
        case drained
    }

    struct Settings: Equatable {
        var cutoff: Int
        var recovery: Int
        var recoveryRequiresAC: Bool
        var action: LowBatteryAction
        var graceSeconds: TimeInterval
        var resumeAfterRecovery: Bool

        init(cutoff: Int, recovery: Int, recoveryRequiresAC: Bool, action: LowBatteryAction,
             graceSeconds: TimeInterval, resumeAfterRecovery: Bool) {
            self.cutoff = cutoff
            self.recovery = recovery
            self.recoveryRequiresAC = recoveryRequiresAC
            self.action = action
            self.graceSeconds = graceSeconds
            self.resumeAfterRecovery = resumeAfterRecovery
        }

        init(_ c: Config) {
            self.init(cutoff: c.lowBatteryCutoff, recovery: c.recoveryThreshold,
                      recoveryRequiresAC: c.recoveryRequiresAC, action: c.lowBatteryAction,
                      graceSeconds: c.lowBatteryPauseGraceSeconds,
                      resumeAfterRecovery: c.resumeAfterBatteryRecovery)
        }
    }

    /// A session Page paused, plus the phone page it raised for it.
    struct Entry: Codable, Equatable {
        let session: PausedSession
        /// `<sessionId>-low_battery-<trip epoch>`. Derived from the trip time
        /// so a relaunch mid-pause re-derives (and never duplicates) it.
        let pageId: String
        /// False once the page has been closed (power came back). The entry
        /// itself stays until the session is resumed or goes stale.
        var pageOpen: Bool

        var key: String { BatteryPolicy.key(session) }
    }

    enum Effect: Equatable {
        /// Ask every enabled `BatteryPausable` backend to pause its busy
        /// sessions with `message`, then report back via `pauseFinished`.
        case pauseSessions(message: String, mode: LowBatteryAction, percent: Int)
        /// Tripped with `lowBatteryAction == .off`: nothing is messaged; the
        /// Mac just stops being held awake on battery.
        case trippedWithoutPause(percent: Int)
        /// The grace period ended; the Mac may sleep now.
        case graceEnded(pausedCount: Int)
        /// New entries to page the phone about (one relay page each).
        case pageSessions([Entry], percent: Int)
        /// Power is back. Close `closePageIds`; if `resume`, type `message`
        /// into `sessions` (and report via `sessionsResumed`).
        case recovered(sessions: [PausedSession], resume: Bool, message: String, closePageIds: [String])
    }

    /// How the battery state constrains the keep-awake assertion this tick.
    enum BoostDirective: Equatable {
        /// Follow the agents (`wantsPowerAssertion`).
        case followAgents
        /// Hold the Mac awake regardless (grace period: let them summarise).
        case hold
        /// Don't hold it, whatever the agents want (drained, on battery).
        case block
    }

    /// Paused sessions older than this are forgotten: a day later nobody
    /// expects "Resume paused sessions" to type into them.
    static let staleEntryAge: TimeInterval = 24 * 3600

    /// Typed into sessions: no ASCII digits (see `pauseMessage`).
    static let recoveryMessage = "Power is back — carry on where you left off."
    static let manualResumeMessage = "Carry on where you left off."

    private(set) var phase: Phase = .normal
    /// Mode in force for the current trip (settings can change mid-trip).
    private(set) var mode: LowBatteryAction?
    private(set) var trippedAt: Date?
    private(set) var trippedPercent: Int?
    private(set) var graceEndsAt: Date?
    /// True between `.pauseSessions` and `pauseFinished`. Not meaningful
    /// across a relaunch (see `restoredAfterLaunch`).
    private(set) var pauseInFlight = false
    private(set) var entries: [Entry] = []
    /// Power came back with `resumeAfterRecovery` on, and the automatic
    /// resume hasn't been attempted yet: the Coordinator holds it while the
    /// user is at the Mac (typing "carry on" into a session they may be
    /// using is worse than waiting) and runs it once they step away. The
    /// entries stay listed meanwhile, so "Resume paused sessions now" works.
    /// Optional so a battery-paused.json written by an older build (no such
    /// key) still decodes.
    private(set) var autoResumePending: Bool?

    init() {}

    /// An automatic resume is owed and there is something to resume.
    var awaitingAutoResume: Bool {
        autoResumePending == true && phase == .normal && !entries.isEmpty
    }

    /// The Coordinator is about to attempt the automatic resume (or the
    /// user resumed from the menu). One-shot: whatever can't be resumed
    /// stays listed for the menu, but is never retried automatically.
    mutating func autoResumeStarted() {
        autoResumePending = nil
    }

    /// Clears the pending auto-resume when there is nothing left to resume.
    private mutating func dropPendingIfEmpty() {
        if entries.isEmpty { autoResumePending = nil }
    }

    var isTripped: Bool { phase != .normal }
    var pausedSessions: [PausedSession] { entries.map(\.session) }
    var openPageIds: [String] { entries.filter(\.pageOpen).map(\.pageId) }

    func entry(forPageId id: String) -> Entry? { entries.first { $0.pageId == id } }

    static func key(_ s: PausedSession) -> String { "\(s.backend.rawValue)|\(s.sessionId)" }

    static func isLowBatteryPageId(_ id: String) -> Bool { id.contains("-low_battery-") }

    static func pageId(sessionId: String, trippedAt: Date) -> String {
        "\(sessionId)-low_battery-\(Int(trippedAt.timeIntervalSince1970))"
    }

    // MARK: predicates

    /// Trip only on battery power at or below the cutoff. Never while on AC
    /// (a laptop plugged in at 8% is charging — pausing it helps nobody),
    /// never on desktops (no battery; percent is -1).
    static func shouldTrip(_ p: PowerSnapshot, cutoff: Int) -> Bool {
        p.hasBattery && !p.onAC && p.percent >= 0 && p.percent <= cutoff
    }

    /// Recovery: charge back at `recovery` and on AC, or — when AC isn't
    /// required — strictly above the cutoff too, so a reading can never
    /// both trip and recover (that would message the agents every tick).
    /// A battery that disappears (desktop reading) counts as recovered.
    static func hasRecovered(_ p: PowerSnapshot, _ s: Settings) -> Bool {
        guard p.hasBattery else { return true }
        guard p.percent >= s.recovery else { return false }
        if p.onAC { return true }
        return !s.recoveryRequiresAC && p.percent > s.cutoff
    }

    /// How far above the trip level a battery-only reading must be before it
    /// counts as "was charged" (a battery rebounds a point or two once load
    /// drops; it can't climb further without a charger).
    static let chargeEvidenceMargin = 5

    /// A battery-only reading that can only mean the Mac was charged while
    /// Page wasn't watching (asleep or off on a charger, then unplugged):
    /// back at the recovery level, above the cutoff, and well above where it
    /// tripped. Leaves the low-battery state even when recovery requires AC
    /// — otherwise a full Mac stays "drained" and agents can't keep it
    /// awake until it's plugged in again — but without auto-resuming (that
    /// promise is still "only when plugged in").
    static func wasChargedMeanwhile(_ p: PowerSnapshot, _ s: Settings, trippedPercent: Int?) -> Bool {
        guard p.hasBattery, !p.onAC, p.percent >= s.recovery, p.percent > s.cutoff else { return false }
        return p.percent >= (trippedPercent ?? s.cutoff) + chargeEvidenceMargin
    }

    /// Typed into the agent's terminal, so it contains no ASCII digit: if a
    /// numbered menu (a permission prompt) appears while it is being typed,
    /// a digit would pick an option. The level is spelled out in words.
    static func pauseMessage(percent: Int, mode: LowBatteryAction) -> String {
        let level = spelledPercent(percent).map { "Battery is at \($0)" } ?? "Battery is low"
        switch mode {
        case .afterTurn:
            return "\(level) and the Mac will sleep soon. Finish the step you're on, then stop: don't start anything new, and reply with a two-line summary of where you stopped and what's next."
        case .pause, .off:
            return "\(level) and the Mac is about to sleep. Pause now: don't start anything new, and reply with a two-line summary of where you stopped and what's next."
        }
    }

    /// The wording older builds typed (with digits). Sessions paused before
    /// an upgrade carry it in their transcripts; a resume filter that wants
    /// to recognise Page's own text should include these too.
    static func legacyPauseMessages() -> [String] {
        (0...100).flatMap { percent in [
            "Battery is at \(percent)% and the Mac will sleep soon. Finish the step you're on, then stop: don't start anything new, and reply with a two-line summary of where you stopped and what's next.",
            "Battery is at \(percent)% and the Mac is about to sleep. Pause now: don't start anything new, and reply with a two-line summary of where you stopped and what's next."
        ] }
    }

    /// "nine percent", "twenty-three percent", "one hundred percent"; nil
    /// outside 0...100. Never contains an ASCII digit.
    static func spelledPercent(_ n: Int) -> String? {
        spelledNumber(n).map { "\($0) percent" }
    }

    static func spelledNumber(_ n: Int) -> String? {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                    "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                    "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        switch n {
        case 0..<20: return ones[n]
        case 20..<100: return n % 10 == 0 ? tens[n / 10] : "\(tens[n / 10])-\(ones[n % 10])"
        case 100: return "one hundred"
        default: return nil
        }
    }

    static func pageContext(percent: Int) -> String {
        "Battery \(percent)% — Page paused this session. Plug in to continue, or reply to send instructions."
    }

    /// What a phone reply to a low-battery page asks for.
    enum ReplyDecision: Equatable {
        /// "deny": acknowledge, close the page, keep the session paused.
        case leavePaused
        /// Type `message` into the session.
        case resume(message: String)
        /// Nothing usable to send; report `detail` to the phone.
        case reject(detail: String)
    }

    /// approve / carry_on resume with the standard wording (which says
    /// power is back only if it is), custom text is passed through as the
    /// user's instructions, deny leaves the session paused.
    static func replyDecision(action: String?, text: String, stillTripped: Bool) -> ReplyDecision {
        switch action {
        case "deny":
            return .leavePaused
        case "approve", "carry_on":
            return .resume(message: stillTripped ? manualResumeMessage : recoveryMessage)
        default:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .reject(detail: "Empty reply") : .resume(message: trimmed)
        }
    }

    // MARK: transitions

    /// Feed one power reading. Returns what the Coordinator must do.
    mutating func observe(_ p: PowerSnapshot, settings: Settings, now: Date) -> [Effect] {
        switch phase {
        case .normal:
            entries.removeAll { now.timeIntervalSince($0.session.pausedAt) > Self.staleEntryAge }
            dropPendingIfEmpty()
            guard Self.shouldTrip(p, cutoff: settings.cutoff) else { return [] }
            // A new trip: whatever was owed from the last recovery is
            // superseded (the sessions get paused, and resumed, afresh).
            autoResumePending = nil
            trippedAt = now
            trippedPercent = p.percent
            mode = settings.action
            if settings.action == .off {
                phase = .drained
                graceEndsAt = nil
                pauseInFlight = false
                return [.trippedWithoutPause(percent: p.percent)]
            }
            phase = .grace
            graceEndsAt = now.addingTimeInterval(max(0, settings.graceSeconds))
            pauseInFlight = true
            return [.pauseSessions(message: Self.pauseMessage(percent: p.percent, mode: settings.action),
                                   mode: settings.action, percent: p.percent)]

        case .grace, .drained:
            if Self.hasRecovered(p, settings) {
                return [recover(settings: settings, allowResume: true)]
            }
            if Self.wasChargedMeanwhile(p, settings, trippedPercent: trippedPercent) {
                return [recover(settings: settings, allowResume: !settings.recoveryRequiresAC)]
            }
            // The deadline wins even if a backend is still busy pausing: a
            // hung pause must not keep a 10% battery awake.
            if phase == .grace, let end = graceEndsAt, now >= end {
                phase = .drained
                return [.graceEnded(pausedCount: entries.filter(\.pageOpen).count)]
            }
            return []
        }
    }

    /// The backends finished pausing. Records the sessions and returns the
    /// pages to send — or, if power already came back meanwhile, resumes
    /// them straight away.
    mutating func pauseFinished(_ sessions: [PausedSession], settings: Settings, now: Date) -> [Effect] {
        pauseInFlight = false
        let stamp = trippedAt ?? now
        var fresh: [Entry] = []
        var seen = Set<String>()
        for s in sessions where seen.insert(Self.key(s)).inserted {
            fresh.append(Entry(session: s, pageId: Self.pageId(sessionId: s.sessionId, trippedAt: stamp),
                               pageOpen: phase != .normal))
        }
        // A session still listed from an earlier trip (never resumed) was
        // paused again: the new entry, with its new page, replaces it.
        entries.removeAll { seen.contains($0.key) }

        if phase == .normal {
            // Plugged in before the pause even finished: nothing to page.
            guard !fresh.isEmpty else { return [] }
            // Listed either way: an automatic resume may be held while the
            // user is at the Mac, and the menu can resume them meanwhile.
            entries.append(contentsOf: fresh)
            if settings.resumeAfterRecovery {
                autoResumePending = true
                return [.recovered(sessions: fresh.map(\.session), resume: true,
                                   message: Self.recoveryMessage, closePageIds: [])]
            }
            return [.recovered(sessions: fresh.map(\.session), resume: false,
                               message: Self.recoveryMessage, closePageIds: [])]
        }

        entries.append(contentsOf: fresh)
        var effects: [Effect] = []
        if !fresh.isEmpty {
            effects.append(.pageSessions(fresh, percent: trippedPercent ?? 0))
        }
        // Nothing was paused this time: no summary to wait for, let the Mac
        // sleep now. (Entries left over from an earlier trip have no open page.)
        if phase == .grace && !entries.contains(where: \.pageOpen) {
            phase = .drained
            effects.append(.graceEnded(pausedCount: 0))
        }
        return effects
    }

    /// Sessions that were resumed (automatically, from the menu or by a
    /// phone reply). Returns the page ids that were still open, to close.
    @discardableResult
    mutating func removeSessions(keys: Set<String>) -> [String] {
        let removed = entries.filter { keys.contains($0.key) }
        entries.removeAll { keys.contains($0.key) }
        dropPendingIfEmpty()
        return removed.filter(\.pageOpen).map(\.pageId)
    }

    /// The user answered a page without resuming (e.g. "leave it paused").
    mutating func markPageClosed(_ pageId: String) {
        for i in entries.indices where entries[i].pageId == pageId { entries[i].pageOpen = false }
    }

    /// After a relaunch: nothing can be in flight any more, and a grace
    /// period that ran out while Page was down is over.
    mutating func restoredAfterLaunch(now: Date) {
        pauseInFlight = false
        if phase == .grace, let end = graceEndsAt, now >= end {
            phase = .drained
        }
        if phase == .normal {
            entries.removeAll { now.timeIntervalSince($0.session.pausedAt) > Self.staleEntryAge }
        }
        dropPendingIfEmpty()
    }

    func boostDirective(_ p: PowerSnapshot) -> BoostDirective {
        switch phase {
        case .normal: return .followAgents
        case .grace: return .hold
        // Plugged in but not yet "recovered": there's no reason to let it
        // sleep on AC, so agents the user resumed by hand keep it awake.
        case .drained: return p.onAC ? .followAgents : .block
        }
    }

    private mutating func recover(settings: Settings, allowResume: Bool) -> Effect {
        let sessions = entries.map(\.session)
        let closing = openPageIds
        let resume = allowResume && settings.resumeAfterRecovery && !sessions.isEmpty
        phase = .normal
        mode = nil
        trippedAt = nil
        trippedPercent = nil
        graceEndsAt = nil
        pauseInFlight = false
        // The pages close either way. With `resume` the entries stay until
        // the backends confirm each resume (`removeSessions`): the
        // Coordinator may hold the automatic resume while the user is at
        // the Mac. It is still one-shot: `autoResumeStarted()` clears the
        // pending flag on the first attempt, and the Coordinator then removes
        // every attempted session, so what can't be resumed (the user already
        // typed there, it isn't idle) is reported, never retried forever.
        for i in entries.indices { entries[i].pageOpen = false }
        autoResumePending = resume ? true : nil
        return .recovered(sessions: sessions, resume: resume, message: Self.recoveryMessage, closePageIds: closing)
    }
}

/// Persists `BatteryPolicy` to
/// `~/Library/Application Support/ClaudePowerMode/battery-paused.json`.
/// Atomic writes; an unreadable file is logged and treated as "nothing
/// paused" (never a crash, never a re-pause).
struct BatteryPauseStore {
    let url: URL

    static var defaultURL: URL {
        Config.configURL.deletingLastPathComponent().appendingPathComponent("battery-paused.json")
    }

    init(url: URL = BatteryPauseStore.defaultURL) {
        self.url = url
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    func load() -> BatteryPolicy? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        do {
            return try d.decode(BatteryPolicy.self, from: data)
        } catch {
            Logger.shared.log("Ignoring unreadable \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func save(_ policy: BatteryPolicy) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if policy == BatteryPolicy() {
                // Nothing worth remembering — don't leave an empty file around.
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                return true
            }
            try Self.encoder().encode(policy).write(to: url, options: .atomic)
            return true
        } catch {
            Logger.shared.log("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
            return false
        }
    }
}
