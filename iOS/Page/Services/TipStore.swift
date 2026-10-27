import Foundation

/// Which first-time tips this phone has shown (`TipBook`), remembered in
/// UserDefaults. One lives at the app root; Now, the Decision sheet and the
/// Tower share it.
@MainActor
final class TipStore: ObservableObject {
    @Published private(set) var book: TipBook
    private let defaults: UserDefaults
    private let persists: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.persists = true
        self.book = TipBook.load(from: defaults)
    }

    /// A fixed book that is never written to disk (the render harness).
    init(fixed: TipBook) {
        self.defaults = .standard
        self.persists = false
        self.book = fixed
    }

    /// Dismissed, or its gesture was used: never shown again.
    func retire(_ tip: NWTip) {
        guard book.retire(tip) else { return }
        if persists { book.save(to: defaults) }
    }

    func resetAll() {
        book.reset()
        if persists { book.save(to: defaults) }
    }
}
