import Foundation

/// The persisted Card glow setting. One instance lives at the app root; its
/// value goes into the environment (`\.nwCardGlow`) so every glass surface
/// reads the same thing, and the Settings picker writes it here.
@MainActor
final class CardGlowStore: ObservableObject {
    @Published var glow: CardGlow {
        didSet { if persists, glow != oldValue { glow.save(to: defaults) } }
    }

    private let defaults: UserDefaults
    private let persists: Bool

    /// Reads the saved value (Off when there is none).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.persists = true
        self.glow = CardGlow.load(from: defaults)
    }

    /// A fixed value that is never written to disk (the render harness).
    init(fixed: CardGlow) {
        self.defaults = .standard
        self.persists = false
        self.glow = fixed
    }
}
