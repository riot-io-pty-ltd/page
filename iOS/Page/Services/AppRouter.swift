import Foundation
import SwiftUI

/// App-wide navigation state, so a notification tap, a widget tap or a
/// `page://` link can open a specific card whether the app was running,
/// suspended or cold-launched. On a cold launch the notification delegate
/// fires before any view exists; the request simply sits here until the root
/// view appears and presents it.
///
/// There are exactly two destinations (Now and Lanes). Everything else is a sheet
/// or a room, and only one sheet can be up at a time: asking for another while
/// one is showing closes the first, and the new one comes up from
/// `sheetDismissed()` (`SheetQueue`). A deep link always lands on Now with the
/// card's Decision sheet over it, never on a tab.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()

    /// Kept for the session room, which presents a page's Decision sheet over itself.
    struct PresentedIntervention: Identifiable, Equatable {
        let id: String
    }

    @Published var destination: NWDestination = .now
    @Published private(set) var sheets = SheetQueue()
    /// The unpair confirmation, asked for by Now, Lanes and the Tower alike.
    @Published var confirmingUnpair = false
    /// The Paired screen is up after a first pairing. While it is, nothing else
    /// asks iOS for notification permission: that choice is made on that screen.
    @Published var pairedWelcome = false

    private init() {}

    /// What `.sheet(item:)` binds to.
    var sheetBinding: Binding<NWSheet?> {
        Binding(get: { self.sheets.current }, set: { self.sheets.set($0) })
    }

    /// Opens a page's Decision sheet over Now. `composer` is Steer: the sheet comes up with its message box open.
    func open(interventionId: String, switchTab: Bool = true, composer: Bool = false) {
        if switchTab { destination = .now }
        composerEntry = composer ? DecisionEntry(id: interventionId, at: Date()) : nil
        sheets.request(.decision(interventionId))
    }

    /// Which page's sheet was asked to open with its composer, read once by that sheet.
    private var composerEntry: DecisionEntry?

    /// Whether this page's sheet should open with its composer up, once: a request older than a few
    /// seconds belongs to an earlier opening and is dropped.
    func takeComposerEntry(for interventionId: String, now: Date = Date()) -> Bool {
        defer { composerEntry = nil }
        return DecisionEntry.wantsComposer(composerEntry, for: interventionId, now: now)
    }

    /// How the next room opens (Screen, Type, Stop), read once by that room.
    private var roomEntry: (sessionId: String, entry: RoomEntry, at: Date)?

    /// Opens a live session's room, on Story unless the caller says how.
    func openSession(_ sessionId: String, entry: RoomEntry = .story) {
        roomEntry = entry == .story ? nil : (sessionId, entry, Date())
        sheets.request(.session(sessionId))
    }

    /// The entry asked for this session's room, once: a request older than a
    /// few seconds belongs to an earlier opening and is dropped.
    func takeRoomEntry(for sessionId: String, now: Date = Date()) -> RoomEntry {
        defer { roomEntry = nil }
        guard let e = roomEntry, e.sessionId == sessionId, now.timeIntervalSince(e.at) < 5 else { return .story }
        return e.entry
    }

    /// Opens the Tower, optionally scrolled to a section.
    func openTower(_ section: TowerSection? = nil) { sheets.request(.tower(section)) }
    func openDispatch() { sheets.request(.dispatch) }
    func openHistory() { sheets.request(.history) }
    func requestUnpair() { confirmingUnpair = true }

    /// A sheet finished dismissing: present whatever was waiting.
    func sheetDismissed() { sheets.dismissed() }

    /// The open sheet holds a message its writer hasn't sent. A deep link, a notification tap or any other
    /// request for a sheet then waits for the person's answer instead of closing it over the text.
    func setSheetDraft(_ held: Bool) {
        guard sheets.draftHeld != nil || held else { return }
        sheets.setDraft(held)
    }

    /// The answer to "Discard your message?" for a sheet asked for meanwhile.
    func resolveDeferredSheet(discard: Bool) { sheets.resolveDeferred(discard: discard) }

    /// Handles `page://intervention/<id>`, `page://sessions` (the widget),
    /// `page://now`, `page://lanes` (and its old name `page://sky`) and
    /// `page://tower`. Returns false for
    /// anything else.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard let link = NWDeepLink.parse(url) else { return false }
        switch link {
        case .now: destination = .now
        case .lanes: destination = .lanes
        case .tower: openTower()
        case .decision(let id): open(interventionId: id)
        }
        return true
    }

    func reset() {
        destination = .now
        roomEntry = nil
        composerEntry = nil
        sheets.close()
        confirmingUnpair = false
    }
}
