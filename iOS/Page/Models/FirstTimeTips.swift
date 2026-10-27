import Foundation

// First-time tips and the "Gestures & shortcuts" page. One list of gestures
// (`GestureGuide`) is the single source of their copy: the Tower prints all of
// it, and each tip is the one line of one entry. A tip is shown once, never
// blocks anything, and is remembered on the phone (`TipBook`). Pure, so the
// logic tests cover it.

// MARK: - Gestures

/// The tips Page can show, in the order of `TipBook.priority`.
enum NWTip: String, CaseIterable, Equatable, Identifiable {
    case swipeToApprove, holdToApprove, inFlight, willType

    var id: String { rawValue }

    /// The tip's line, from the gesture list. `biometry` is how this phone
    /// confirms ("Face ID", "Touch ID", "passcode").
    func text(biometry: String = "Face ID") -> String {
        (GestureGuide.entry(for: self)?.tipText ?? "").replacingOccurrences(of: "{biometry}", with: biometry)
    }

    var symbol: String { GestureGuide.entry(for: self)?.symbol ?? "lightbulb" }
}

/// One gesture and what it does.
struct GestureEntry: Equatable, Identifiable {
    let id: String
    /// SF Symbol that exists on iOS 17.
    let symbol: String
    /// "Swipe right".
    let gesture: String
    /// Where: "On an undoable row".
    let context: String
    /// What it does: "Approves it. You can undo it for a moment."
    let effect: String
    /// The tip this entry is the source of, and its line (`{biometry}` is filled in).
    var tip: NWTip? = nil
    var tipText: String? = nil
}

enum GestureGuide {
    static let title = "Gestures & shortcuts"

    static let entries: [GestureEntry] = [
        GestureEntry(id: "swipe", symbol: "arrow.right", gesture: "Swipe right", context: "on an undoable row",
                     effect: "Approves it. Nothing is sent for 1.2 seconds, and Cancel stops it.",
                     tip: .swipeToApprove, tipText: "Swipe right to approve — it can be undone"),
        GestureEntry(id: "hold", symbol: "hand.tap", gesture: "Hold", context: "on an irreversible approval",
                     effect: "Fill the ring, then your phone confirms it. Only then is it approved.",
                     tip: .holdToApprove, tipText: "Hold to approve — {biometry} confirms"),
        GestureEntry(id: "tap-card", symbol: "rectangle.and.hand.point.up.left", gesture: "Tap a card", context: "in Decide, Look or Review",
                     effect: "Opens the full decision, with exactly what will be typed."),
        GestureEntry(id: "in-flight", symbol: "waveform", gesture: "Tap a card", context: "in In flight",
                     effect: "See what it is doing, how long, and what it ran. Open shows its terminal; Steer types to it.",
                     tip: .inFlight, tipText: "Tap to watch it work · Steer to guide it"),
        GestureEntry(id: "touch-hold", symbol: "hand.point.up.left", gesture: "Touch and hold", context: "an In flight card",
                     effect: "Open, Steer or Stop. Stop opens the session, where you hold the stop button."),
        GestureEntry(id: "will-type", symbol: "keyboard", gesture: "Will type …", context: "on a decision",
                     effect: "Says exactly what lands on your Mac, in which terminal.",
                     tip: .willType, tipText: "Will type … shows exactly what lands on your Mac"),
        GestureEntry(id: "cancel", symbol: "xmark.circle", gesture: "Tap Cancel", context: "while the ring runs",
                     effect: "Takes an approval back before anything leaves the phone."),
        GestureEntry(id: "stop", symbol: "stop.circle", gesture: "Hold Stop", context: "in a session",
                     effect: "Presses Esc in that session after a 0.6 second hold."),
        GestureEntry(id: "plus", symbol: "plus.circle", gesture: "Tap +", context: "on the bottom bar",
                     effect: "Starts new work on your Mac."),
        GestureEntry(id: "stop-all", symbol: "stop.circle.fill", gesture: "Hold +", context: "on the bottom bar",
                     effect: "Stops every working agent, once your phone confirms it."),
        GestureEntry(id: "sides", symbol: "arrow.left.arrow.right", gesture: "Swipe sideways", context: "on the top or the bottom bar",
                     effect: "Goes between Now and Lanes."),
        GestureEntry(id: "pull", symbol: "arrow.down", gesture: "Pull down", context: "on Now",
                     effect: "Checks in with your Mac again."),
        GestureEntry(id: "chip", symbol: "bolt.horizontal", gesture: "Tap the Mac chip or the Runway", context: "on Now",
                     effect: "Opens this Tower, at Budget for the Runway."),
    ]

    /// What Siri and Shortcuts answer to, from `PageShortcuts`.
    static let shortcuts: [GestureEntry] = [
        GestureEntry(id: "siri-status", symbol: "waveform", gesture: "“What are my agents doing in Page”", context: "Siri or Shortcuts",
                     effect: "Says what needs you and what is working."),
        GestureEntry(id: "siri-stop", symbol: "stop.circle", gesture: "“Stop my agents with Page”", context: "Siri or Shortcuts",
                     effect: "Asks first, then stops every working agent."),
        GestureEntry(id: "siri-sessions", symbol: "rectangle.stack", gesture: "“Open Page sessions”", context: "Siri or Shortcuts",
                     effect: "Opens Lanes."),
    ]

    static func entry(for tip: NWTip) -> GestureEntry? { entries.first { $0.tip == tip } }

    static let showAgainLabel = "Show the tips again"
}

// MARK: - The tip that shows

/// Where a tip points: the row it sits under.
struct NowTipTarget: Equatable {
    let tip: NWTip
    /// The row it explains: a Now row's id, or an In flight session's id.
    let anchorId: String
}

/// What the rows say, for `TipBook.nowTip`.
struct NowTipInputs {
    /// The rows in the order drawn. The swipe tip points only at a row that can really be swiped
    /// (`canSwipeApprove`), never at an Undoable row that offers only Open on Mac.
    var rows: [NowRow] = []
    /// The In flight rows, in the order drawn.
    var inFlight: [String] = []
    /// Rows with an arm ring, a send or a result on them: no tip points at them.
    var busy: Set<String> = []
}

/// Which tips this phone has already shown or used. Each is shown once.
struct TipBook: Equatable {
    /// The one that shows when several could: the safest explanation first.
    static let priority: [NWTip] = [.holdToApprove, .swipeToApprove, .inFlight, .willType]
    static let keyPrefix = "page.tip."

    private(set) var seen: Set<NWTip>

    init(seen: Set<NWTip> = []) { self.seen = seen }

    static func key(_ tip: NWTip) -> String { keyPrefix + tip.rawValue }

    /// What is remembered (nothing, on a fresh install).
    static func load(from defaults: UserDefaults = .standard) -> TipBook {
        TipBook(seen: Set(NWTip.allCases.filter { defaults.bool(forKey: key($0)) }))
    }

    func save(to defaults: UserDefaults = .standard) {
        for tip in NWTip.allCases { defaults.set(seen.contains(tip), forKey: Self.key(tip)) }
    }

    func hasSeen(_ tip: NWTip) -> Bool { seen.contains(tip) }

    /// The tip is dismissed, or its gesture was used. Reports whether that was news.
    @discardableResult
    mutating func retire(_ tip: NWTip) -> Bool { seen.insert(tip).inserted }

    /// Every tip comes back (the Tower's "Show the tips again").
    mutating func reset() { seen = [] }

    /// The one tip Now shows, and the row it points at: at most one at a time,
    /// in `priority` order, on the first row of its kind that has nothing
    /// under way. A tip already seen never returns. Pure.
    func nowTip(_ i: NowTipInputs) -> NowTipTarget? {
        for tip in Self.priority where !seen.contains(tip) {
            let anchor: String?
            switch tip {
            case .holdToApprove: anchor = i.rows.first { $0.chip == .irreversible && $0.action(.approve) != nil && !i.busy.contains($0.id) }?.id
            case .swipeToApprove: anchor = i.rows.first { $0.canSwipeApprove && !i.busy.contains($0.id) }?.id
            case .inFlight: anchor = i.inFlight.first { !i.busy.contains($0) }
            case .willType: anchor = nil
            }
            if let anchor { return NowTipTarget(tip: tip, anchorId: anchor) }
        }
        return nil
    }

    /// The Decision sheet's tip: only while the sheet has a delivery preview to point at. Pure.
    func decisionTip(hasPreview: Bool) -> NWTip? {
        hasPreview && !seen.contains(.willType) ? .willType : nil
    }
}
