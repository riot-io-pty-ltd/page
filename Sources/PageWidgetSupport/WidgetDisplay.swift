import Foundation

/// What the widgets say, as plain strings from a snapshot. The views only draw these.
public enum WidgetFaceSize: String, CaseIterable, Equatable {
    case small, medium, large

    /// Points on the macOS 14 desktop (the sizes the Tower previews draw at).
    public var points: (width: Double, height: Double) {
        switch self {
        case .small: return (170, 170)
        case .medium: return (364, 170)
        case .large: return (364, 382)
        }
    }

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// The widgets Page offers.
public struct WidgetCatalogEntry: Equatable, Identifiable {
    public var kind: String
    public var name: String
    public var detail: String
    public var sizes: [WidgetFaceSize]
    public var id: String { kind }
}

public enum WidgetCatalog {
    public static let status = WidgetCatalogEntry(
        kind: PageWidgetConstants.statusKind, name: "Page",
        detail: "Who needs you, who is working, and how long the runway is clear.",
        sizes: [.small, .medium, .large])
    public static let usage = WidgetCatalogEntry(
        kind: PageWidgetConstants.usageKind, name: "Claude usage",
        detail: "Your 5-hour and 7-day limits, and when each resets.",
        sizes: [.small, .medium])
    public static let all = [status, usage]
}

public enum WidgetTone: Equatable {
    case needsYou, working, quiet, paused
    /// No snapshot, or Page isn't running.
    case asleep
}

public enum WidgetDisplay {
    /// Pure. "1 needs you" / "3 need you".
    public static func needsYouText(_ n: Int) -> String { n == 1 ? "1 needs you" : "\(n) need you" }

    public static func tone(_ s: WidgetSnapshot?, now: Date) -> WidgetTone {
        guard let s else { return .asleep }
        if s.freshness(now: now) == .notRunning { return .asleep }
        switch s.mood {
        case .dusk: return .paused
        case .needsYou: return .needsYou
        case .working: return .working
        case .quiet: return .quiet
        }
    }

    /// Pure. The big line: "2 need you", "5 working", "All quiet", "Paused for battery".
    public static func headline(_ s: WidgetSnapshot) -> String {
        if s.mood == .dusk { return "Paused for battery" }
        if s.attention > 0 { return needsYouText(s.attention) }
        if s.working > 0 { return "\(s.working) working" }
        return "All quiet"
    }

    /// Pure. The line under it: "5 working" beside a waiting page, else nothing.
    public static func secondLine(_ s: WidgetSnapshot) -> String? {
        if s.mood == .dusk { return s.working > 0 ? "\(s.working) held" : nil }
        return s.attention > 0 && s.working > 0 ? "\(s.working) working" : nil
    }

    /// Pure. 24-hour, as the popover's runway says it.
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// Pure. "Clear till 02:40", "Runway clear", "On battery · 62%", or the pause line.
    public static func runway(_ s: WidgetSnapshot, now: Date, timeZone: TimeZone = .current) -> String {
        if s.mood == .dusk { return s.subline.isEmpty ? "Plug in to resume" : s.subline }
        if let end = s.clearUntil, end > now { return "Clear till \(clock(end, timeZone: timeZone))" }
        if let b = s.battery, !b.onAC { return "On battery · \(b.percent)%" }
        return "Runway clear"
    }

    /// Pure. "62%" / "62% · charging" / "62% · plugged in"; nil without a battery.
    public static func battery(_ s: WidgetSnapshot) -> String? {
        guard let b = s.battery else { return nil }
        return "\(b.percent)%" + (b.charging ? " · charging" : (b.onAC ? " · plugged in" : ""))
    }

    /// Pure. What to say about a snapshot that is old or from a Page that quit; nil when it is fresh.
    public static func note(_ s: WidgetSnapshot, now: Date, timeZone: TimeZone = .current) -> String? {
        switch s.freshness(now: now) {
        case .fresh: return nil
        case .notRunning: return "Page isn’t running · open it to update"
        case .stale(let since): return "Last update \(clock(since, timeZone: timeZone)) · Page may be asleep"
        }
    }

    /// Pure. "Open Page to start": no snapshot at all.
    public static let missing = "Open Page to start"

    // MARK: - Chips

    /// Pure. The label and whether it is the loud (red) kind.
    public static func chip(_ raw: String) -> (title: String, tone: ChipTone) {
        switch raw {
        case "irreversible": return ("IRREVERSIBLE", .red)
        case "undoable": return ("UNDOABLE", .teal)
        case "considered": return ("CONSIDERED", .amber)
        case "looksStuck": return ("LOOKS STUCK", .amber)
        case "question": return ("QUESTION", .amber)
        case "forecast": return ("HEADS UP", .amber)
        case "rateLimited": return ("RATE LIMITED", .amber)
        case "review": return ("FINISHED", .teal)
        default: return (raw.uppercased(), .amber)
        }
    }

    public enum ChipTone: Equatable { case red, amber, teal }

    // MARK: - Large widget rows

    /// Pure. How many decision and in-flight rows the large widget draws. The room is counted in points,
    /// headers and "+N more" lines included: decisions come first (up to 4), and working rows give way
    /// until the whole stack fits `room`. A decision always keeps at least one row; working keeps at least
    /// one while any decision leaves room for it.
    ///
    /// `room` is what is left in the 364x382 large widget (350 inside the margins) after the headline
    /// (46), the footer (two lines, 28) and the 10-point gaps between blocks.
    public static func largeRows(decisions: Int, inFlight: Int, moreDecisions: Bool = false, moreWorking: Bool = false,
                                 room: Double = LargeLayout.room) -> (decisions: Int, inFlight: Int) {
        var d = min(decisions, 4)
        var f = min(inFlight, 5)
        func cost(_ d: Int, _ f: Int) -> Double {
            var total = 0.0
            var blocks = 0
            if d > 0 {
                blocks += 1
                total += LargeLayout.header + Double(d) * LargeLayout.row + ((moreDecisions || decisions > d) ? LargeLayout.more : 0)
            }
            if f > 0 {
                blocks += 1
                total += LargeLayout.header + Double(f) * LargeLayout.row + ((moreWorking || inFlight > f) ? LargeLayout.more : 0)
            }
            return total + Double(max(0, blocks - 1)) * LargeLayout.gap
        }
        while cost(d, f) > room {
            if f > 1 { f -= 1 } else if d > 1 { d -= 1 } else if f > 0 { f = 0 } else { break }
        }
        return (d, f)
    }

    /// The point sizes `largeRows` counts with (measured from the large face's own fonts).
    public enum LargeLayout {
        /// A section label ("NEEDS YOU") and its gap to the first row.
        public static let header = 18.0
        /// A two-line row and the gap below it.
        public static let row = 36.0
        /// "+N more" and the gap above it.
        public static let more = 20.0
        public static let gap = 10.0
        public static let room = 236.0
    }

    // MARK: - Usage

    public static func percent(_ g: WidgetSnapshot.Gauge) -> Int { Int(g.pct.rounded()) }

    /// Pure. "resets 03:00" within 12 hours, else "resets in 2d 4h".
    public static func resetText(_ g: WidgetSnapshot.Gauge, now: Date, timeZone: TimeZone = .current) -> String? {
        guard let r = g.resetsAt, r > now else { return nil }
        let left = r.timeIntervalSince(now)
        if left <= 12 * 3600 { return "resets \(clock(r, timeZone: timeZone))" }
        let hours = Int(left / 3600)
        return hours >= 48 ? "resets in \(hours / 24)d \(hours % 24)h" : "resets in \(hours)h"
    }

    /// Pure. Calm until 80%, then amber; red is kept for irreversible things.
    public static func usageIsHot(_ g: WidgetSnapshot.Gauge) -> Bool { g.pct >= 80 }

    /// Pure. The medium widget's sentence.
    public static func usageVerdict(_ u: WidgetSnapshot.Usage) -> (text: String, warning: Bool) {
        if let f = u.fiveHour, f.pct >= 95 { return ("5-hour limit almost used", true) }
        if let f = u.fiveHour, f.pct >= 80 { return ("5-hour limit getting close", true) }
        if let w = u.sevenDay, w.pct >= 90 { return ("7-day limit almost used", true) }
        if let w = u.sevenDay, w.pct >= 80 { return ("7-day limit getting close", true) }
        return ("Plenty of room left", false)
    }
}
