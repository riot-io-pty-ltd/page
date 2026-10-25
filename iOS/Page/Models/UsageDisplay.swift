import Foundation

/// What the usage gauges show for one Claude window (5-hour or 7-day):
/// how full it is, when it resets, and whether usage is running ahead of an
/// even pace through the window. Pure (Foundation only), so the logic
/// tests cover it; the views only draw it.
struct UsageGauge: Equatable {
    enum Tone: Equatable { case calm, warm, hot }

    let label: String
    /// 0...100.
    let pct: Double
    let resetsAt: Date?
    /// Share of the window already gone (0...1), nil without a reset time:
    /// where usage would be at an even pace.
    let elapsed: Double?

    var fraction: Double { min(1, max(0, pct / 100)) }

    /// Points ahead of an even pace (negative: behind).
    var paceDelta: Double? { elapsed.map { pct - $0 * 100 } }

    var tone: Tone {
        if pct >= 90 { return .hot }
        if pct >= 70 || (paceDelta ?? 0) >= 15 { return .warm }
        return .calm
    }

    init(label: String, pct: Double, resetsAt: Date?, window: TimeInterval, now: Date) {
        self.label = label
        self.pct = min(100, max(0, pct))
        self.resetsAt = resetsAt
        if let r = resetsAt, r > now {
            elapsed = min(1, max(0, 1 - r.timeIntervalSince(now) / window))
        } else {
            elapsed = nil
        }
    }

    static let fiveHourWindow: TimeInterval = 5 * 3600
    static let sevenDayWindow: TimeInterval = 7 * 24 * 3600

    /// "34m", "2h 05m", "1d 4h".
    static func countdown(to date: Date, now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        if s < 60 { return "<1m" }
        let m = s / 60, h = m / 60, d = h / 24
        if d > 0 { return h % 24 == 0 ? "\(d)d" : "\(d)d \(h % 24)h" }
        if h > 0 { return String(format: "%dh %02dm", h, m % 60) }
        return "\(m)m"
    }

    /// "Resets in 34m" (or "Resetting…" once it's due).
    func resetLine(now: Date) -> String? {
        guard let r = resetsAt else { return nil }
        return r > now ? "Resets in \(Self.countdown(to: r, now: now))" : "Resetting…"
    }

    /// "Ahead of pace" / "On pace" / "Under pace", nil when unknown.
    var paceLine: String? {
        guard let d = paceDelta else { return nil }
        if d >= 15 { return "Ahead of pace" }
        if d <= -15 { return "Plenty left" }
        return "On pace"
    }
}

/// The card's whole content from the Mac's `usage`.
struct UsageCardModel: Equatable {
    let fiveHour: UsageGauge?
    let sevenDay: UsageGauge?
    /// When the 5-hour limit is reached at the current pace (before reset).
    let hitAt: Date?
    /// The numbers are older than this many minutes (shown as "as of").
    let staleMinutes: Int?

    static let staleAfter: TimeInterval = 10 * 60
    static let hideAfter: TimeInterval = 6 * 3600

    init?(_ usage: MacUsage?, now: Date) {
        guard let u = usage else { return nil }
        if let updated = u.updatedAt, now.timeIntervalSince(updated) > Self.hideAfter { return nil }
        fiveHour = u.fiveHour.map { UsageGauge(label: "5-hour", pct: $0.pct, resetsAt: $0.resetsAt,
                                               window: UsageGauge.fiveHourWindow, now: now) }
        sevenDay = u.sevenDay.map { UsageGauge(label: "7-day", pct: $0.pct, resetsAt: $0.resetsAt,
                                               window: UsageGauge.sevenDayWindow, now: now) }
        if fiveHour == nil && sevenDay == nil { return nil }
        hitAt = u.hitAt.flatMap { $0 > now ? $0 : nil }
        staleMinutes = u.updatedAt.flatMap { now.timeIntervalSince($0) > Self.staleAfter ? Int(now.timeIntervalSince($0) / 60) : nil }
    }

    /// The one-line verdict under the gauges.
    func verdict(format: (Date) -> String) -> (text: String, warning: Bool) {
        if let hit = hitAt { return ("At this pace you'll hit the 5-hour limit around \(format(hit))", true) }
        if let s = sevenDay, s.pct >= 90 { return ("Only \(Int((100 - s.pct).rounded()))% of this week's usage left", true) }
        if let s = sevenDay, (s.paceDelta ?? 0) >= 15 { return ("Using this week's allowance faster than it resets", true) }
        if let f = fiveHour, f.pct >= 90 { return ("Close to the 5-hour limit", true) }
        return ("On track — both windows reset before you run out", false)
    }
}
