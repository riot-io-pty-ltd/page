import Foundation

/// How long until the battery reaches the low-battery cutoff, from how fast
/// it has been draining. Shown in the menu and on the phone (heartbeat
/// `forecast`), and behind the "cutoff soon" page and the opt-in early
/// pause. Pure apart from the samples it keeps; tick queue only.
///
/// The rate is a least-squares fit over the last `window` of readings on
/// battery. Plugging in (or the charge going up) starts over, and there's
/// no forecast until the readings span `minSpan` and show a real drop.
struct BatteryForecast: Equatable {
    struct Sample: Equatable {
        let at: Date
        let percent: Int
    }

    struct Estimate: Equatable {
        let percent: Int
        let cutoff: Int
        /// Percentage points per hour (positive = draining).
        let drainPerHour: Double
        /// Minutes until `cutoff` at this rate (0 when at or below it).
        let minutesToCutoff: Int

        var heartbeatPayload: [String: Any] {
            ["cutoff": cutoff, "minutes": minutesToCutoff, "drainPerHour": (drainPerHour * 10).rounded() / 10]
        }
    }

    static let window: TimeInterval = 20 * 60
    static let minSpan: TimeInterval = 4 * 60
    static let minDrop = 1
    static let maxSamples = 240

    private(set) var samples: [Sample] = []

    /// Records a reading. Resets on AC, on desktops, and when the charge
    /// rises (it was charging, or the reading jumped).
    mutating func observe(_ p: PowerSnapshot, now: Date) {
        guard p.hasBattery, !p.onAC, p.percent >= 0 else { samples.removeAll(); return }
        if let last = samples.last, p.percent > last.percent { samples.removeAll() }
        if let last = samples.last, last.percent == p.percent, now.timeIntervalSince(last.at) < 30 { return }
        samples.append(Sample(at: now, percent: p.percent))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.window }
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }

    /// The current estimate, or nil when there isn't enough to go on.
    func estimate(cutoff: Int, now: Date) -> Estimate? {
        guard let first = samples.first, let last = samples.last,
              last.at.timeIntervalSince(first.at) >= Self.minSpan,
              first.percent - last.percent >= Self.minDrop else { return nil }
        guard let perSecond = Self.slope(samples), perSecond < 0 else { return nil }
        let drainPerHour = -perSecond * 3600
        let left = Double(last.percent - cutoff)
        let minutes = left <= 0 ? 0 : Int((left / drainPerHour * 60).rounded())
        return Estimate(percent: last.percent, cutoff: cutoff, drainPerHour: drainPerHour, minutesToCutoff: minutes)
    }

    /// Least-squares slope of percent over time, per second.
    static func slope(_ s: [Sample]) -> Double? {
        guard s.count >= 2, let t0 = s.first?.at else { return nil }
        let xs = s.map { $0.at.timeIntervalSince(t0) }
        let ys = s.map { Double($0.percent) }
        let n = Double(s.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        return den > 0 ? num / den : nil
    }

    // MARK: copy

    static func duration(minutes: Int) -> String {
        if minutes < 60 { return "\(max(1, minutes)) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    /// One line for the menu: "Cutoff (10%) in about 1 h 5 min at this rate".
    static func menuLine(_ e: Estimate) -> String {
        e.minutesToCutoff == 0 ? "At the \(e.cutoff)% cutoff"
            : "Cutoff (\(e.cutoff)%) in about \(duration(minutes: e.minutesToCutoff)) at this rate"
    }

    // MARK: the "cutoff soon" page

    /// Pages when the cutoff is this close while agents are working...
    static let pageWithin = 15
    /// ...and closes it again only once the estimate is comfortably past
    /// that (hysteresis), or on AC.
    static let pageCloseAbove = 25
    /// The opt-in early pause trips this far ahead of the cutoff.
    static let earlyPauseWithin = 10

    static let pageSessionId = "page-mac"

    static func pageId(openedAt: Date) -> String { "page-mac-battery_forecast-\(Int(openedAt.timeIntervalSince1970))" }
    static func isPageId(_ id: String) -> Bool { id.hasPrefix("page-mac-battery_forecast-") }

    static func pageContext(_ e: Estimate, busy: Int, action: LowBatteryAction, earlyPause: Bool) -> String {
        var s = "Battery \(e.percent)% — at this rate it reaches the \(e.cutoff)% cutoff in about \(duration(minutes: e.minutesToCutoff))."
        let n = "\(busy) session\(busy == 1 ? " is" : "s are")"
        switch action {
        case .pause, .afterTurn:
            let when = earlyPause ? "about \(earlyPauseWithin) min before the cutoff" : "then"
            s += " \(n) mid-task; Page will ask \(busy == 1 ? "it" : "them") to pause \(when)."
        case .off:
            s += " \(n) mid-task; Page will stop keeping the Mac awake then."
        }
        return s + " Plug in to keep them going."
    }

    /// Whether the page should be open now. `open` is whether it is.
    static func wantsPage(_ e: Estimate?, open: Bool, busy: Int, onAC: Bool, tripped: Bool) -> Bool {
        guard let e, !onAC, !tripped, busy > 0 else { return false }
        return open ? e.minutesToCutoff <= pageCloseAbove : e.minutesToCutoff <= pageWithin
    }
}
