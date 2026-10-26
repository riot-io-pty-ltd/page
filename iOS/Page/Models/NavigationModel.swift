import Foundation

// Navigation, as plain values: the two destinations (Now and Sky), the Sky
// mode that is remembered, and the one-at-a-time sheet queue. Sheets and
// rooms are never tabs. Foundation-only, so the logic tests cover it.

/// The two top-level destinations. Now is where you act; Sky is where you are
/// aware. Now is the launch default and the target of every deep link.
enum NWDestination: String, Equatable, CaseIterable {
    case now, sky

    /// A drag counts as horizontal only when it is clearly more sideways than
    /// vertical (|dx| at least 1.5 times |dy|), so scrolling a list that drifts a
    /// little sideways never swipes a card or switches place. Pure.
    static func isHorizontal(dx: Double, dy: Double) -> Bool { abs(dx) >= 1.5 * abs(dy) }

    /// The other one (the capsule's drag, a swipe on the Horizon).
    var other: NWDestination { self == .now ? .sky : .now }

    /// Where a horizontal drag of `translation` points lands. Sky lies to the
    /// right of Now, so dragging left reveals Sky and dragging right goes back
    /// to Now. Short drags stay where they are. Pure.
    static func afterDrag(from current: NWDestination, translation: Double, vertical: Double = 0, threshold: Double = 40) -> NWDestination {
        // A mostly-vertical drag is a scroll or a pull to refresh, never a switch.
        guard isHorizontal(dx: translation, dy: vertical) else { return current }
        if translation <= -threshold { return .sky }
        if translation >= threshold { return .now }
        return current
    }
}

/// Sky's two modes: constellations, and Lanes (the accessible list). The last
/// one used is remembered.
enum SkyMode: String, Equatable, CaseIterable, Identifiable {
    case sky, lanes

    var id: String { rawValue }
    static let `default`: SkyMode = .sky
    static let storageKey = "page.skyMode"

    var label: String { self == .sky ? "Sky" : "Lanes" }

    /// Anything unknown or missing is the default.
    init(stored: String?) { self = stored.flatMap(SkyMode.init(rawValue:)) ?? .default }

    static func load(from defaults: UserDefaults = .standard) -> SkyMode { SkyMode(stored: defaults.string(forKey: storageKey)) }
    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.storageKey) }
}

/// What a sheet is showing. Sessions are rooms you zoom into, never tabs.
enum NWSheet: Equatable, Identifiable {
    /// A page's Decision sheet.
    case decision(String)
    /// A live session's room.
    case session(String)
    /// The Tower, optionally scrolled to a section (the Runway opens Budget).
    case tower(TowerSection?)
    /// Dispatch: start new work.
    case dispatch
    /// Everything Page has settled, and the day stats.
    case history

    var id: String {
        switch self {
        case .decision(let i): return "decision:\(i)"
        case .session(let i): return "session:\(i)"
        case .tower(let s): return "tower:\(s?.rawValue ?? "-")"
        case .dispatch: return "dispatch"
        case .history: return "history"
        }
    }
}

/// One sheet at a time. Asking for another while one is up closes the first,
/// and the new one appears once the first has finished dismissing (SwiftUI
/// cannot present over a sheet that is still leaving). Pure.
struct SheetQueue: Equatable {
    private(set) var current: NWSheet?
    private(set) var pending: NWSheet?

    init(current: NWSheet? = nil) { self.current = current }

    /// Asks for a sheet. Asking for the one already up does nothing.
    mutating func request(_ sheet: NWSheet) {
        if current == sheet { pending = nil; return }
        if current != nil { pending = sheet; current = nil } else { current = sheet; pending = nil }
    }

    /// The system finished dismissing a sheet: bring up whatever was waiting.
    mutating func dismissed() {
        if let next = pending { pending = nil; current = next }
    }

    /// The user dismissed the sheet (a swipe down, a close button).
    mutating func close() { current = nil; pending = nil }

    /// Binds to `.sheet(item:)`: setting nil closes.
    mutating func set(_ sheet: NWSheet?) {
        if let sheet { request(sheet) } else if pending == nil { current = nil }
    }
}

/// Where a `page://` link goes.
enum NWDeepLink: Equatable {
    case now
    case sky
    case decision(String)
    case tower

    /// `page://intervention/<id>` opens that page's Decision sheet over Now;
    /// `page://sessions` (the widget) opens Sky, where sessions live;
    /// `page://now`, `page://sky` and `page://tower` open those. Anything else
    /// is nil. Pure.
    static func parse(_ url: URL) -> NWDeepLink? {
        guard url.scheme == "page" else { return nil }
        switch url.host {
        case "sessions", "sky": return .sky
        case "now": return .now
        case "tower": return .tower
        default:
            return DeepLink.interventionId(from: url).map(NWDeepLink.decision)
        }
    }
}
