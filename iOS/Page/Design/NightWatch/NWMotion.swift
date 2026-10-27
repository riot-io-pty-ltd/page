import SwiftUI

// Two pieces of motion plumbing the signature motions share: a one-shot
// that plays on the display's clock and then stops for good, and the
// clock a card reads (pinned by the render harness, live otherwise).

/// Plays a short one-shot from `start` (reference-date seconds) for
/// `duration`, handing `content` the seconds elapsed (negative while a
/// staggered start is still to come), then holds the final
/// frame with no clock at all (`content(nil)`). Short, so it may run at the
/// display's full rate. `pinned` draws one moment (the render harness);
/// Reduce Motion skips straight to the end.
struct NWOneShot<Content: View>: View {
    var start: Double?
    var duration: Double
    var pinned: Double? = nil
    @ViewBuilder var content: (Double?) -> Content
    @State private var finished: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let pinned {
            content(pinned)
        } else if let s = start, !reduceMotion, finished != s, scenePhase == .active,
                  Date().timeIntervalSinceReferenceDate - s < duration {
            TimelineView(.animation(minimumInterval: 1.0 / 60)) { tl in
                content(min(duration, tl.date.timeIntervalSinceReferenceDate - s))
            }
            .task(id: s) {
                let left = max(0, duration - (Date().timeIntervalSinceReferenceDate - s))
                try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
                if !Task.isCancelled { finished = s }
            }
        } else {
            content(nil)
        }
    }
}

/// Redraws `content` on the display clock until `until` (capped at 30 fps:
/// a thread of light is thin and slow), then once more and never again
/// until something changes. The render harness's `\.nwFixedNow` pins the clock.
struct NWLiveClock<Content: View>: View {
    var until: Date?
    @ViewBuilder var content: (Date) -> Content
    @State private var stopped: Date?
    @Environment(\.nwFixedNow) private var fixedNow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.nwAnimationsPaused) private var covered
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if let fixedNow {
            content(fixedNow)
        } else if let u = until, stopped != u, u > Date() {
            // Reduce Motion still needs the arm countdown to tick, just not smoothly.
            TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : 1.0 / 30, paused: covered || scenePhase != .active)) { tl in
                content(tl.date)
            }
            .task(id: u) {
                try? await Task.sleep(nanoseconds: UInt64(max(0, u.timeIntervalSinceNow) * 1_000_000_000))
                if !Task.isCancelled { stopped = u }
            }
        } else {
            content(Date())
        }
    }
}
