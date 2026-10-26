import Foundation

/// The last absence of 10 minutes or more, fixed when Page came back, and
/// whether its Return Brief is showing. It lives above Now and Sky so that
/// switching between them never restarts the absence or re-opens a dismissed Brief.
@MainActor
final class AwayStore: ObservableObject {
    @Published private(set) var absence: Absence?
    @Published var briefShowing = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Page has come back (a launch, or from the background). The absence is
    /// measured from when Page last went to the background to now; the Brief
    /// shows if it was 45 minutes or more and has not been dismissed.
    func returned(now: Date = Date()) {
        let stored = AwayTracker.load(defaults)
        guard let fresh = Absence.make(lastActive: stored.lastActive, returnedAt: now) else { return }
        // The same absence seen again (a view reappearing) keeps its original return time.
        if absence?.since != fresh.since { absence = fresh }
        briefShowing = fresh.shouldShowBrief(dismissedFor: stored.dismissedFor)
    }

    func dismissBrief() {
        if let a = absence { AwayTracker.markDismissed(for: a.since, defaults) }
        briefShowing = false
    }

    /// Pull-to-refresh after a long absence re-opens the last Brief.
    func reopenBrief() { if absence != nil { briefShowing = true } }
}
