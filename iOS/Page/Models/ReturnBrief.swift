import Foundation

// The Return Brief: one honest summary of an absence, built only from what
// Page already has (the page and reply history, turn summaries, the Mac's
// battery and usage readings). No model call. Pure and Foundation-only.

/// When the Brief appears, and whether you have dismissed it.
enum AwayTracker {
    static let lastActiveKey = "page.lastActiveAt"
    static let dismissedKey = "page.briefDismissedFor"

    /// Away this long (judged by when Page last went to the background) and
    /// the Brief appears.
    static let briefAfter: TimeInterval = 45 * 60
    /// Away this long and the Horizon sentence is phrased as a handover.
    static let handoverAfter: TimeInterval = 10 * 60

    /// The time away, or nil when there is no earlier record.
    static func away(since lastActive: Date?, now: Date) -> TimeInterval? {
        lastActive.map { max(0, now.timeIntervalSince($0)) }
    }

    /// Show the Brief: away long enough, and not already dismissed for this
    /// absence (the dismissal stores the `lastActive` it dismissed). Pure.
    static func shouldShowBrief(lastActive: Date?, dismissedFor: Date?, now: Date) -> Bool {
        guard let away = away(since: lastActive, now: now), away >= briefAfter else { return false }
        return dismissedFor != lastActive
    }

    static func load(_ defaults: UserDefaults = .standard) -> (lastActive: Date?, dismissedFor: Date?) {
        func date(_ key: String) -> Date? { (defaults.object(forKey: key) as? Double).map { Date(timeIntervalSince1970: $0) } }
        return (date(lastActiveKey), date(dismissedKey))
    }

    static func markActive(_ at: Date, _ defaults: UserDefaults = .standard) {
        defaults.set(at.timeIntervalSince1970, forKey: lastActiveKey)
    }

    static func markDismissed(for lastActive: Date, _ defaults: UserDefaults = .standard) {
        defaults.set(lastActive.timeIntervalSince1970, forKey: dismissedKey)
    }
}

/// One absence, fixed when Page comes back: from when it went to the
/// background to the moment it returned. Everything about the absence (the
/// Brief's window, its counts, the handover sentence) is measured over
/// [since, returnedAt], so it does not keep growing while you are back.
struct Absence: Equatable {
    let since: Date
    let returnedAt: Date

    var duration: TimeInterval { max(0, returnedAt.timeIntervalSince(since)) }

    /// An absence only exists if it was long enough for a handover (10 min). Pure.
    static func make(lastActive: Date?, returnedAt: Date) -> Absence? {
        guard let last = lastActive, returnedAt.timeIntervalSince(last) >= AwayTracker.handoverAfter else { return nil }
        return Absence(since: last, returnedAt: returnedAt)
    }

    /// The handover phrasing stays for ten minutes after you are back. Pure.
    func showsHandover(now: Date) -> Bool { now.timeIntervalSince(returnedAt) < AwayTracker.handoverAfter }

    /// The Brief appears for absences of 45 minutes or more, unless dismissed. Pure.
    func shouldShowBrief(dismissedFor: Date?) -> Bool { duration >= AwayTracker.briefAfter && dismissedFor != since }
}

struct ReturnBrief: Equatable {
    enum Tone: String, Equatable { case good, neutral, warn }

    struct Count: Equatable, Identifiable {
        enum Kind: String, Equatable { case finished = "Finished", inFlight = "In flight", needYou = "Need you" }
        let kind: Kind
        let value: Int
        var id: String { kind.rawValue }
    }

    struct Line: Equatable, Identifiable {
        let id: String
        /// SF Symbol name.
        let symbol: String
        let title: String
        let detail: String?
        let tone: Tone
    }

    /// "1h 52m".
    let awayText: String
    /// "While you were away · 1h 52m".
    let title: String
    /// "23:20 to 01:12".
    let window: String
    let counts: [Count]
    let lines: [Line]
    /// 0...1: how bright the sunrise is, in proportion to what finished.
    let sunrise: Double
    /// Open pages (Decide or Look): the Brief collapses to one line in that case.
    let hasUrgent: Bool

    var finished: Int { counts.first { $0.kind == .finished }?.value ?? 0 }

    /// A short line for the collapsed form: "While you were away · 1h 52m ›".
    var collapsedTitle: String { title }

    /// The Brief's content. `history` is the resolved pages; `open` the
    /// pages still waiting. Pure.
    static func build(since: Date, now: Date, history: [Intervention], open: [Intervention], sessions: [LiveSession],
                      hasSessionList: Bool, status: MacStatusSnapshot?, timeZone: TimeZone) -> ReturnBrief {
        let away = max(0, now.timeIntervalSince(since))
        let awayText = brief(away)
        func settledAt(_ iv: Intervention) -> Date { iv.repliedAt ?? iv.closedAt ?? iv.openedAt }
        let inWindow = history.filter { settledAt($0) >= since && settledAt($0) <= now }

        let decisions = inWindow.filter(SettledLog.isDecision)
        let approved = decisions.filter { $0.repliedAction == "approve" }.count
        let denied = decisions.filter { $0.repliedAction == "deny" }.count
        let said = decisions.count - approved - denied
        let finishedTurns = inWindow.filter(SettledLog.isFinishedTurn)
        let recovered = inWindow.filter(SettledLog.isStuck)
        let pauses = inWindow.filter(SettledLog.isBatteryPause).count + open.filter { $0.kind == .idle && $0.subtype == "low_battery" }.count

        let needYou = open.filter { NowRowBuilder.section(of: $0) == .decide }.count
        let look = open.filter { NowRowBuilder.section(of: $0) == .look }.count
        let working = hasSessionList ? sessions.filter { $0.state == .active }.count : (status?.working ?? 0)

        var lines: [Line] = []
        if !decisions.isEmpty {
            var parts: [String] = []
            if approved > 0 { parts.append("\(approved) approved") }
            if denied > 0 { parts.append("\(denied) denied") }
            if said > 0 { parts.append("\(said) answered in words") }
            lines.append(Line(id: "decided", symbol: "hand.tap", title: "Decided \(decisions.count)",
                              detail: parts.joined(separator: " · "), tone: .neutral))
        }
        if !finishedTurns.isEmpty {
            var files = 0, passing = 0, failing = 0
            for t in finishedTurns {
                let summary = TurnSummaryLine.split(t.context).summary ?? ""
                if let r = summary.range(of: #"Changed (\d+) files?"#, options: .regularExpression) { files += Int(summary[r].filter(\.isNumber)) ?? 0 }
                if summary.contains("tests passed") { passing += 1 }
                if summary.contains("tests failed") { failing += 1 }
            }
            var parts = ["\(finishedTurns.count) turn\(finishedTurns.count == 1 ? "" : "s")"]
            if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
            if passing + failing > 0 { parts.append("tests passing in \(passing) of \(passing + failing)") }
            lines.append(Line(id: "finished", symbol: "checkmark.circle", title: "Finished", detail: parts.joined(separator: " · "), tone: failing > 0 ? .warn : .good))
        }
        if !recovered.isEmpty {
            lines.append(Line(id: "stuck", symbol: "arrow.triangle.2.circlepath", title: "Looked stuck: \(recovered.count)",
                              detail: "cleared by the time you came back", tone: .warn))
        }
        if let usage = status?.usage?.fiveHour, status?.usage?.updatedAt.map({ now.timeIntervalSince($0) <= 6 * 3600 }) ?? true {
            var parts = ["5h \(Int(usage.pct.rounded()))%"]
            if let hit = status?.usage?.hitAt, hit > now { parts.append("on pace to hit \(NowFormat.clock(hit, timeZone: timeZone))") }
            if let r = usage.resetsAt, r > now { parts.append("resets \(NowFormat.clock(r, timeZone: timeZone))") }
            lines.append(Line(id: "usage", symbol: "gauge.with.needle", title: "Usage", detail: parts.joined(separator: " · "),
                              tone: status?.usage?.hitAt != nil ? .warn : .neutral))
        }
        if let b = status?.batteryPercent {
            var parts = ["\(b)%", status?.onAC == true ? "on power" : "on battery"]
            parts.append("paused at the cutoff \(pauses == 0 ? "0 times" : pauses == 1 ? "once" : "\(pauses) times")")
            lines.append(Line(id: "battery", symbol: "battery.50", title: "Battery", detail: parts.joined(separator: " · "), tone: pauses > 0 ? .warn : .neutral))
        }
        // A grown sunrise: a long productive absence is a bright dawn, an idle one stays dim.
        let sunrise = min(1, Double(finishedTurns.count) / 6)
        return ReturnBrief(
            awayText: awayText, title: "While you were away · \(awayText)",
            window: "\(NowFormat.clock(since, timeZone: timeZone)) to \(NowFormat.clock(now, timeZone: timeZone))",
            counts: [Count(kind: .finished, value: finishedTurns.count), Count(kind: .inFlight, value: working),
                     Count(kind: .needYou, value: needYou + look)],
            lines: lines, sunrise: sunrise, hasUrgent: needYou + look > 0)
    }

    /// "1h 52m", "45m", "2h".
    static func brief(_ seconds: TimeInterval) -> String {
        let total = max(0, Int((seconds / 60).rounded()))
        let h = total / 60, m = total % 60
        if h == 0 { return "\(max(1, m))m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    /// The Horizon sentence when you have been away 10 minutes or more:
    /// "While you were away (1h 52m) · 3 finished · 2 need you". nil when
    /// short of that, or when nothing finished and nothing waits (the normal
    /// sentence is then truer). Pure.
    static func handoverSentence(away: TimeInterval, finished: Int, needYou: Int) -> String? {
        guard away >= AwayTracker.handoverAfter, finished + needYou > 0 else { return nil }
        var parts = ["While you were away (\(brief(away)))"]
        if finished > 0 { parts.append("\(finished) finished") }
        if needYou > 0 { parts.append("\(needYou) \(needYou == 1 ? "needs" : "need") you") }
        return parts.joined(separator: " · ")
    }
}
