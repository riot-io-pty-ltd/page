import Foundation

// "Settled": what History becomes inside Now. Today's resolved pages read as
// short receipt lines; each earlier day collapses to one headline card
// ("Tue · 14 decided · 6 finished · 2 stuck · battery pause ×1"). Pure: the
// caller passes `now`, the calendar and the time zone.

struct SettledLine: Equatable, Identifiable {
    enum Tone: String, Equatable { case approved, sent, neutral }

    let id: String
    let tone: Tone
    /// "Approved npm test", "Sent “use the cache”", "Answered in the terminal".
    let text: String
    /// "12m", relative to now.
    let age: String
    /// "delivered ✓" only when the Mac confirmed it; "sent" until then; nil for pages Page did not answer.
    let status: String?
    let at: Date
}

struct SettledDay: Equatable, Identifiable {
    /// Start of that day.
    let day: Date
    let decided: Int
    let finished: Int
    let stuck: Int
    let batteryPauses: Int
    /// "Tue · 14 decided · 6 finished · 2 stuck · battery pause ×1".
    let headline: String
    var id: Date { day }
}

struct SettledLog: Equatable {
    var today: [SettledLine]
    var days: [SettledDay]

    /// Earlier days shown as headline cards.
    static let dayLimit = 14
    /// Lines shown for today.
    static let lineLimit = 12

    // MARK: classification

    /// A page the user answered from Page (a decision).
    static func isDecision(_ iv: Intervention) -> Bool {
        iv.repliedAt != nil && (iv.kind == .approval || iv.kind == .userInput || iv.repliedAction != nil)
    }
    static func isStuck(_ iv: Intervention) -> Bool { iv.kind == .idle && PageSubtype.isStuck(iv.subtype) }
    static func isBatteryPause(_ iv: Intervention) -> Bool { iv.kind == .idle && iv.subtype == "low_battery" }
    /// A finished turn: an idle page that is not a stuck or battery page.
    static func isFinishedTurn(_ iv: Intervention) -> Bool {
        iv.kind == .idle && !PageSubtype.isStuck(iv.subtype) && iv.subtype != "low_battery"
    }

    // MARK: build

    static func build(history: [Intervention], now: Date, calendar: Calendar, timeZone: TimeZone = .current) -> SettledLog {
        var cal = calendar
        cal.timeZone = timeZone
        let todayStart = cal.startOfDay(for: now)

        func settledAt(_ iv: Intervention) -> Date { iv.repliedAt ?? iv.closedAt ?? iv.openedAt }
        let items = history.sorted { settledAt($0) > settledAt($1) }

        let lines = items.filter { settledAt($0) >= todayStart }.prefix(lineLimit).map { line(for: $0, now: now) }

        var buckets: [Date: [Intervention]] = [:]
        for iv in items where settledAt(iv) < todayStart {
            buckets[cal.startOfDay(for: settledAt(iv)), default: []].append(iv)
        }
        let days = buckets.keys.sorted(by: >).prefix(dayLimit).map { day in
            card(day: day, items: buckets[day] ?? [], calendar: cal, timeZone: timeZone)
        }
        return SettledLog(today: Array(lines), days: Array(days))
    }

    static func line(for iv: Intervention, now: Date) -> SettledLine {
        let at = iv.repliedAt ?? iv.closedAt ?? iv.openedAt
        let age = RelativeTime.compact(seconds: Int(max(0, now.timeIntervalSince(at))))
        let delivered = iv.deliveryStatus == "delivered"
        let status: String? = iv.repliedAt == nil ? nil : (delivered ? "delivered ✓" : (iv.deliveryStatus == "failed" ? "not delivered" : "sent"))

        guard iv.repliedAt != nil else {
            return SettledLine(id: iv.id, tone: .neutral, text: CloseReason.description(iv.closeReason), age: age, status: nil, at: at)
        }
        let subject = NowRowBuilder.summaryLine(for: iv)
        switch iv.repliedAction {
        case "approve":
            return SettledLine(id: iv.id, tone: .approved, text: "Approved \(subject)", age: age, status: status, at: at)
        case "deny":
            return SettledLine(id: iv.id, tone: .neutral, text: (PageSubtype.canStop(iv.subtype) ? "Stopped " : "Denied ") + subject, age: age, status: status, at: at)
        case "carry_on":
            return SettledLine(id: iv.id, tone: .sent, text: "Carried on · \(iv.projectName)", age: age, status: status, at: at)
        default:
            let said = (iv.repliedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let clipped = said.count > 28 ? String(said.prefix(27)) + "…" : said
            return SettledLine(id: iv.id, tone: .sent, text: clipped.isEmpty ? "Replied · \(iv.projectName)" : "Sent \u{201C}\(clipped)\u{201D}", age: age, status: status, at: at)
        }
    }

    static func card(day: Date, items: [Intervention], calendar: Calendar, timeZone: TimeZone) -> SettledDay {
        let decided = items.filter(isDecision).count
        let finished = items.filter(isFinishedTurn).count
        let stuck = items.filter(isStuck).count
        let battery = items.filter(isBatteryPause).count
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = timeZone
        f.dateFormat = "EEE"
        let summary = summaryText(decided: decided, finished: finished, stuck: stuck, battery: battery)
        return SettledDay(day: day, decided: decided, finished: finished, stuck: stuck, batteryPauses: battery,
                          headline: [f.string(from: day), summary].joined(separator: " · "))
    }

    /// "14 decided · 6 finished · 2 stuck · battery pause ×1", or "quiet" for a day with none.
    static func summaryText(decided: Int, finished: Int, stuck: Int, battery: Int) -> String {
        var parts: [String] = []
        if decided > 0 { parts.append("\(decided) decided") }
        if finished > 0 { parts.append("\(finished) finished") }
        if stuck > 0 { parts.append("\(stuck) stuck") }
        if battery > 0 { parts.append("battery pause ×\(battery)") }
        return parts.isEmpty ? "quiet" : parts.joined(separator: " · ")
    }
}
