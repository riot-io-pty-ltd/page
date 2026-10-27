import Foundation

// The Tower's Widgets page, as pure values. Apple gives an app no way to put a
// widget on the Home Screen or Lock Screen: the person adds it. So Page gets
// everything ready (the widgets exist, the data is shared) and this page shows
// the steps and what each widget looks like. Foundation only: the widget
// extension and the logic tests both compile this folder, and WidgetKit's
// families do not exist on macOS, so the view layer turns WidgetCenter's
// answer into `PlacedWidget` and everything below is testable.

enum TowerWidgets {
    // MARK: The widgets

    /// One of Page's widgets. `kind` is the string the extension registers
    /// (PageWidget.swift); the sizes are its `supportedFamilies`.
    struct Widget: Equatable, Identifiable {
        enum Kind: String, CaseIterable { case macStatus = "page.mac-status", claudeUsage = "page.claude-usage" }
        let kind: Kind
        let name: String
        /// What it shows, in a line.
        let detail: String
        let homeSizes: [Size]
        let lockSizes: [Size]
        var id: String { kind.rawValue }

        /// "Home Screen: small, medium" and "Lock Screen: circular, rectangular", one per line.
        var sizesLine: String {
            "Home Screen: " + homeSizes.map(\.word).joined(separator: ", ") + "\nLock Screen: " + lockSizes.map(\.word).joined(separator: ", ")
        }
    }

    /// A widget size, by the word a person would use.
    enum Size: String, Equatable, CaseIterable {
        case small, medium, large, circular, rectangular, inline
        var word: String { rawValue }
        var isLockScreen: Bool { self == .circular || self == .rectangular || self == .inline }

        /// WidgetKit's family name ("systemMedium", "accessoryCircular"), as a string so this file needs no WidgetKit.
        init?(family: String) {
            switch family {
            case "systemSmall": self = .small
            case "systemMedium": self = .medium
            case "systemLarge": self = .large
            case "accessoryCircular": self = .circular
            case "accessoryRectangular": self = .rectangular
            case "accessoryInline": self = .inline
            default: return nil
            }
        }
    }

    /// Mirrors the extension's `supportedFamilies` and display names (PageWidget.swift); a logic test pins the kinds.
    static let widgets: [Widget] = [
        Widget(kind: .macStatus, name: "Page",
               detail: "Sessions that need you, agents at work, and the Runway: when your Mac’s battery or your usage will stop the work.",
               homeSizes: [.small, .medium, .large], lockSizes: [.rectangular, .circular, .inline]),
        Widget(kind: .claudeUsage, name: "Claude usage",
               detail: "Your 5-hour and 7-day Claude usage and when each resets.",
               homeSizes: [.small, .medium], lockSizes: [.circular, .rectangular]),
    ]

    // MARK: What is placed

    /// One widget the person has placed, as WidgetCenter reports it.
    struct PlacedWidget: Equatable {
        let kind: String
        /// WidgetKit's family name, e.g. "systemMedium".
        let family: String
    }

    /// Where the placed widgets are, in words.
    struct Status: Equatable {
        /// nil while WidgetCenter has not answered.
        let placed: Bool?
        /// "On your Home Screen: Page (medium), Claude usage (small)" and "On your Lock Screen: …", or "Not added yet".
        let lines: [String]

        var text: String { lines.joined(separator: "\n") }
        var isPlaced: Bool { placed == true }
        static let checking = Status(placed: nil, lines: ["Checking…"])
    }

    /// Pure. Which of Page's widgets are on the Home Screen and the Lock Screen, from WidgetCenter's configurations.
    /// Other apps' kinds and families this file does not know are ignored; the same kind and size placed twice reads once.
    static func status(placed: [PlacedWidget]) -> Status {
        func line(lockScreen: Bool) -> String? {
            var parts: [String] = []
            for w in widgets {
                // Only the sizes this widget comes in: a family it does not support is not a placement of it.
                let supported = w.homeSizes + w.lockSizes
                let sizes = Size.allCases.filter { size in
                    size.isLockScreen == lockScreen && supported.contains(size)
                        && placed.contains { $0.kind == w.kind.rawValue && Size(family: $0.family) == size }
                }
                if !sizes.isEmpty { parts.append("\(w.name) (\(sizes.map(\.word).joined(separator: ", ")))") }
            }
            guard !parts.isEmpty else { return nil }
            return "On your \(lockScreen ? "Lock Screen" : "Home Screen"): " + parts.joined(separator: ", ")
        }
        let lines = [line(lockScreen: false), line(lockScreen: true)].compactMap { $0 }
        return lines.isEmpty ? Status(placed: false, lines: ["Not added yet"]) : Status(placed: true, lines: lines)
    }

    // MARK: Show me how

    struct Step: Equatable, Identifiable {
        var number: Int
        var title: String
        var detail: String
        var id: Int { number }
    }

    enum Place: String, CaseIterable, Equatable {
        case homeScreen, lockScreen
        var label: String { self == .homeScreen ? "Home Screen" : "Lock Screen" }
    }

    /// Pure. The steps for one place.
    static func steps(_ place: Place) -> [Step] {
        switch place {
        case .homeScreen:
            return [
                Step(number: 1, title: "Touch and hold an empty spot",
                     detail: "On your Home Screen, press on a gap between the icons until they start to wiggle."),
                Step(number: 2, title: "Tap Edit, then Add Widget",
                     detail: "Edit is at the top left. Choose Add Widget from the menu."),
                Step(number: 3, title: "Search for Page",
                     detail: "Type Page in the search field. Page and Claude usage show up."),
                Step(number: 4, title: "Pick a size",
                     detail: "Swipe sideways to see small, medium and large, and stop on the one you like."),
                Step(number: 5, title: "Tap Add Widget",
                     detail: "Then drag it where you want it and tap Done. It keeps itself up to date."),
            ]
        case .lockScreen:
            return [
                Step(number: 1, title: "Touch and hold the Lock Screen",
                     detail: "Wake your iPhone and unlock it with Face ID, but don’t swipe up. Then press and hold on the screen."),
                Step(number: 2, title: "Tap Customize, then Lock Screen",
                     detail: "Customize is at the bottom. Choose the Lock Screen side, not the Home Screen."),
                Step(number: 3, title: "Tap the row of widgets",
                     detail: "It is just under the time, or above it for the small line."),
                Step(number: 4, title: "Choose Page",
                     detail: "Search for Page or find it in the list, then tap the widget you want. Tap Done."),
            ]
        }
    }

    // MARK: Words

    static let addTitle = "Add them to your iPhone"
    static let showLabel = "Show me how"
    static let hideLabel = "Hide the steps"

    /// The honest line: Apple does not let an app place widgets.
    static let honestLine = "iPhone only lets you place a widget yourself, so Page gets everything ready and shows you the steps."

    /// What the status row says underneath, by state.
    static func hint(_ status: Status) -> String {
        switch status.placed {
        case nil: return "Asking your iPhone which Page widgets are on your screens."
        case true?: return "They keep themselves up to date. Touch and hold one to change it or remove it."
        case false?: return "Page can’t put one there for you. Tap “Show me how” and it takes a minute."
        }
    }

    static let previewsTitle = "What you’ll get"
    static let lockScreenTitle = "On the Lock Screen"
    static let examplesNote = "Example data. Yours show your Mac right now, with secrets masked. Tap a widget to open Page."
    static let lockNote = "The Lock Screen draws these in your wallpaper’s tint, so they look a little different there."

    /// Your Mac can show these too, and has its own.
    static let macNote = "Your Mac can show iPhone widgets as well: in System Settings ▸ Desktop & Dock, turn on “Use iPhone widgets”. The Mac also has widgets of its own, set up in Page ▸ Tower ▸ Widgets on the Mac."

    // MARK: Example data for the previews

    /// A calm, believable reading for the preview faces: two sessions need you, five are working, 41% on battery, usage at 62% and 87%.
    static func exampleStatus(now: Date) -> WidgetStatus {
        var snap = MacStatusSnapshot(macConnected: true, lastHeartbeatAt: now, activeSessions: 9, battery: 41, onAC: false, pendingCount: 2, working: 5)
        snap.forecast = MacBatteryForecast(cutoff: 10, minutes: 148, drainPerHour: 12)
        snap.usage = MacUsage(fiveHour: .init(pct: 62, resetsAt: now.addingTimeInterval(110 * 60)),
                              sevenDay: .init(pct: 87, resetsAt: now.addingTimeInterval(3 * 86_400)),
                              hitAt: now.addingTimeInterval(88 * 60), updatedAt: now)
        return WidgetStatus(macName: "Studio MBP", presence: .online, needsYou: 2, working: 5, live: 9, batteryLine: nil, usageLine: nil,
                            fetchedAt: now, usage: snap.usage, snapshot: snap)
    }
}
