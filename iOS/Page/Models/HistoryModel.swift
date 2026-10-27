import Foundation

// The History screen: every settled page, one row each, grouped by day, plus
// the day's numbers. Pure: the caller passes `now`, the calendar and the time
// zone. It reads the same lines Now's Settled list does (`SettledLog.line`),
// so a page reads the same on both; only the 12-line and 14-day limits of the
// Now list are lifted here.

/// One settled page.
struct HistoryRow: Equatable, Identifiable {
    let id: String
    let tone: SettledLine.Tone
    /// "Approved npm test", "Sent “use the cache”", "Answered in the terminal".
    let text: String
    /// "12m", "delivered ✓": the same pair Settled shows.
    let trailing: String
    /// "page · APPROVAL · Answered in 8s".
    let detail: String
    /// Spoken for the whole row.
    let spoken: String
}

/// One day of settled pages, newest first.
struct HistoryDay: Equatable, Identifiable {
    let day: Date
    /// "Today", "Yesterday", "Tue 20 Oct".
    let title: String
    /// "14 decided · 6 finished · 2 stuck", or "quiet".
    let summary: String
    let rows: [HistoryRow]
    var id: Date { day }
}

struct HistoryScreenModel: Equatable {
    var days: [HistoryDay]
    /// Pages in the list.
    var total: Int
    /// Today, this week, average response and the busiest projects.
    var stats: PageStats
    /// Open pages: the "pending now" tile.
    var pending: Int
    /// Today's three rings.
    var rings: [RingStat]

    static func build(history: [Intervention], inbox: [Intervention], now: Date, calendar: Calendar = .current,
                      timeZone: TimeZone = .current) -> HistoryScreenModel {
        var cal = calendar
        cal.timeZone = timeZone
        func settledAt(_ iv: Intervention) -> Date { iv.repliedAt ?? iv.closedAt ?? iv.openedAt }
        let items = history.sorted { settledAt($0) > settledAt($1) }

        var order: [Date] = []
        var buckets: [Date: [Intervention]] = [:]
        for iv in items {
            let d = cal.startOfDay(for: settledAt(iv))
            if buckets[d] == nil { order.append(d) }
            buckets[d, default: []].append(iv)
        }
        let today = cal.startOfDay(for: now)
        let days = order.map { d -> HistoryDay in
            let list = buckets[d] ?? []
            let card = SettledLog.card(day: d, items: list, calendar: cal, timeZone: timeZone)
            return HistoryDay(day: d, title: dayTitle(d, today: today, calendar: cal, timeZone: timeZone),
                              summary: SettledLog.summaryText(decided: card.decided, finished: card.finished, stuck: card.stuck,
                                                              battery: card.batteryPauses),
                              rows: list.map { row(for: $0, now: now) })
        }
        return HistoryScreenModel(
            days: days, total: items.count,
            stats: PageStats.compute(history: history, inbox: inbox, now: now, calendar: cal),
            pending: inbox.count,
            rings: DayStats.today(history: history, now: now, calendar: cal).rings)
    }

    static func row(for iv: Intervention, now: Date) -> HistoryRow {
        let line = SettledLog.line(for: iv, now: now)
        var detail = [iv.projectName, PageSubtype.chip(kind: iv.kind, subtype: iv.subtype)]
        if let rt = iv.responseTimeSeconds { detail.append("Answered in \(RelativeTime.compact(seconds: rt))") }
        let trailing = [line.age, line.status].compactMap { $0 }.joined(separator: " · ")
        let spoken = "\(line.text), \(iv.projectName), \(trailing)"
        return HistoryRow(id: iv.id, tone: line.tone, text: line.text, trailing: trailing,
                          detail: detail.joined(separator: " · "), spoken: spoken)
    }

    static func dayTitle(_ day: Date, today: Date, calendar: Calendar, timeZone: TimeZone) -> String {
        if day == today { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: today), day == y { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = timeZone
        f.dateFormat = "EEE d MMM"
        return f.string(from: day)
    }
}

/// How the History screen reads while the list is empty.
enum HistoryEmpty: Equatable {
    case loading
    case failed(String)
    case none

    /// nil when there are rows to show. `failure` is the load error, if any;
    /// `loaded` is true once a fetch has finished.
    static func state(isEmpty: Bool, loaded: Bool, failure: String?) -> HistoryEmpty? {
        guard isEmpty else { return nil }
        if let failure { return .failed(failure) }
        return loaded ? HistoryEmpty.none : .loading
    }
}
