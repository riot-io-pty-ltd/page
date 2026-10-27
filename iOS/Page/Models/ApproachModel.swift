import Foundation

/// FINAL APPROACH: a new decision descends from the pulse into its ranked
/// slot on spring(response 0.5, damping 0.8), trailing a faint contrail; it
/// lands at about 360 ms and by 520 ms has settled and its glow is off. In
/// flight it is an empty outline (as board 07 draws it), growing out of the
/// pulse; its words fade in only as it lands, so they are never drawn over
/// the Horizon's headline or the Runway. The Mac's `ApproachModel` uses the
/// same `content` curve.
/// Only the cards below its slot move, easing down by exactly one card
/// height on the same spring; nothing above moves. While a finger is on the
/// stream nothing arrives at all: new rows wait behind the "New ↑ 1" pill
/// (`StableOrder`), and the approach plays when the pill is tapped.
///
/// Pure: `frame(elapsed:)` is the whole choreography at any moment.
enum ApproachModel {
    static let response = 0.5
    static let damping = 0.8
    /// Board 07: leaves the pulse at 0, contrail at 180, lands at 360, settled at 520.
    static let lands: TimeInterval = 0.36
    static let duration: TimeInterval = 0.52
    /// When several rows arrive together, each leaves this long after the last.
    static let stagger: TimeInterval = 0.09
    /// More than this many arrivals at once just appear (a flood is not news).
    static let maxAnimated = 3
    /// The card's content fades in over this stretch of its travel (about
    /// 200 to 290 ms): before it, the card is only its outline.
    static let contentFrom = 0.8
    static let contentTo = 0.97
    /// The outline leaves the pulse this small and has grown to the card's
    /// size by the time its content starts to show.
    static let startScale = 0.35

    struct Frame: Equatable {
        /// 0 at the pulse ... 1 in the slot (the spring; overshoots a hair).
        let travel: Double
        /// The outline grows from `startScale` as it comes down (it leaves the
        /// pulse small), and is full size before any content shows.
        let scale: Double
        /// The whole arrival's alpha: it fades up as it leaves the pulse.
        let opacity: Double
        /// 0...1 how much of the card's content shows.
        let content: Double
        /// 0...1 strength of the outline that stands in for the card in flight.
        let edge: Double
        /// The contrail from the pulse to the card's top edge: 0...1 alpha.
        let contrail: Double
        /// The amber glow round the card: up as it leaves, off once settled.
        let glow: Double
        let finished: Bool
    }

    /// How much of the card shows at `travel` (0 = on the pulse, 1 = in its slot). Pure.
    static func content(travel: Double) -> Double {
        MotionCurve.smooth(MotionCurve.progress(travel, from: contentFrom, to: contentTo))
    }

    /// The arriving card at `elapsed` seconds. Pure.
    static func frame(elapsed t: TimeInterval) -> Frame {
        guard t < duration else { return Frame(travel: 1, scale: 1, opacity: 1, content: 1, edge: 0, contrail: 0, glow: 0, finished: true) }
        let x = MotionCurve.spring(t, response: response, damping: damping)
        let fadeIn = MotionCurve.easeOut(t / 0.12)
        let content = content(travel: x)
        let grown = MotionCurve.easeOut(MotionCurve.clamp01(x) / contentFrom)
        // The contrail draws in as the card leaves and fades from landing to settled.
        let contrail = min(MotionCurve.easeOut(t / 0.12), 1 - MotionCurve.smooth(MotionCurve.progress(t, from: lands, to: duration)))
        let glow = min(MotionCurve.easeOut(t / 0.18), 1 - MotionCurve.smooth(MotionCurve.progress(t, from: lands, to: duration)))
        // Faint but there as it leaves the pulse (board 07, "0 ms · leaves pulse").
        return Frame(travel: x, scale: startScale + (1 - startScale) * grown, opacity: 0.4 + 0.6 * fadeIn,
                     content: content, edge: 0.6 * (1 - content),
                     contrail: max(0, contrail) * 0.8, glow: max(0, glow), finished: false)
    }

    /// Vertical offset of the arriving card from its slot (negative is up),
    /// `distance` points below the pulse. Pure.
    static func offset(distance: Double, elapsed: TimeInterval) -> Double {
        -distance * (1 - frame(elapsed: elapsed).travel)
    }

    /// Offset of a card below the slot: it starts one card height up (where
    /// it was) and eases down on the same spring. `height` is the arriving
    /// card's height plus the stack's spacing. Pure.
    static func pushOffset(height: Double, elapsed: TimeInterval) -> Double {
        guard elapsed < duration else { return 0 }
        return -height * (1 - MotionCurve.spring(elapsed, response: response, damping: damping))
    }

    /// The ids that just arrived: in `current` but not in `previous`. Nothing
    /// arrives on the first look (`previous` nil), so a launch is not a
    /// flood of approaches. Order follows `current`. Pure.
    static func arrivals(previous: [String]?, current: [String]) -> [String] {
        guard let previous else { return [] }
        let known = Set(previous)
        return current.filter { !known.contains($0) }
    }

    /// When each arrival leaves the pulse, `stagger` apart from `start`, in
    /// rank order. Beyond `maxAnimated` they get no approach (nil). Pure.
    static func schedule(_ ids: [String], start: TimeInterval) -> [String: TimeInterval] {
        guard ids.count <= maxAnimated else { return [:] }
        var out: [String: TimeInterval] = [:]
        for (i, id) in ids.enumerated() { out[id] = start + Double(i) * stagger }
        return out
    }
}
