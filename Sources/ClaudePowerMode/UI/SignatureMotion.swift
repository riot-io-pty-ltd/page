import Foundation

// The timing and phase maths behind Night Watch's five signature motions
// (Designs/v4/07-signature-motion.png, spec "signatureAnimations"): the pulse,
// final approach, the receipt thread, the hold ring, and dusk and dawn. Pure
// and Foundation-only: the views and the status-bar animator pass elapsed
// seconds in and draw what comes out, and tests drive them with plain numbers.
// Nothing here reads a clock.

// MARK: - Curves

enum MotionCurve {
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

    /// 0 at or before `a`, 1 at or after `b`, a smooth Hermite step between.
    /// With `a == b` it is a hard step.
    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b > a else { return x < a ? 0 : 1 }
        let t = clamp01((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    /// Cubic ease-out on 0...1 (clamped).
    static func easeOut(_ x: Double) -> Double {
        let t = 1 - clamp01(x)
        return 1 - t * t * t
    }

    /// Cubic ease-in on 0...1 (clamped).
    static func easeIn(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * t
    }

    /// Cubic ease-in-out on 0...1 (clamped).
    static func easeInOut(_ x: Double) -> Double {
        let t = clamp01(x)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    /// 0...1 progress of a segment that starts `start` seconds in and lasts `duration`.
    static func segment(_ elapsed: Double, start: Double, duration: Double) -> Double {
        guard duration > 0 else { return elapsed >= start ? 1 : 0 }
        return clamp01((elapsed - start) / duration)
    }

    /// The fractional part, always 0..<1 (also for negative input).
    static func fract(_ x: Double) -> Double {
        let f = x - x.rounded(.down)
        return f >= 1 ? 0 : f
    }
}

/// Colour blends for the exhale, through OKLCH (lightness, chroma, hue) the
/// shorter way round the hue wheel. A plain sRGB blend between two colours
/// from opposite sides of the wheel, amber and teal, sinks through khaki and
/// grey half way; this one keeps its chroma, so amber turns to teal by way of
/// an aurora green. Pure; channels are sRGB 0...1. The phone has the same
/// function (iOS/Page/Models/MotionCurves.swift).
enum PerceptualMix {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// Below this chroma a colour has no hue worth keeping (greys, star-white):
    /// it takes the other colour's.
    static let achromatic = 0.02

    /// Pure. `t` (clamped to 0...1) of the way from `a` to `b`; exactly `a` at
    /// 0 and `b` at 1. Out-of-gamut results are clipped to 0...1. With
    /// `keepChroma` false it is a straight line through Oklab instead, which
    /// suits the near-black sky behind the curtains: a dark brown and a dark
    /// teal meet at a neutral night, not an olive one.
    static func mix(_ a: RGB, _ b: RGB, _ t: Double, keepChroma: Bool = true) -> RGB {
        let k = MotionCurve.clamp01(t)
        if k <= 0 { return a }
        if k >= 1 { return b }
        let p = oklab(a), q = oklab(b)
        if !keepChroma {
            return srgb(l: p.l + (q.l - p.l) * k, a: p.a + (q.a - p.a) * k, b: p.b + (q.b - p.b) * k)
        }
        let ca = (p.a * p.a + p.b * p.b).squareRoot(), cb = (q.a * q.a + q.b * q.b).squareRoot()
        var ha = atan2(p.b, p.a), hb = atan2(q.b, q.a)
        if ca < achromatic { ha = hb }
        if cb < achromatic { hb = ha }
        var dh = hb - ha
        if dh > .pi { dh -= 2 * .pi }
        if dh < -.pi { dh += 2 * .pi }
        let l = p.l + (q.l - p.l) * k, c = ca + (cb - ca) * k, h = ha + dh * k
        return srgb(l: l, a: c * cos(h), b: c * sin(h))
    }

    /// Pure. sRGB 0...1 to Oklab.
    static func oklab(_ c: RGB) -> (l: Double, a: Double, b: Double) {
        func lin(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = lin(c.r), g = lin(c.g), b = lin(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Pure. Oklab to sRGB 0...1, clipped to the gamut.
    static func srgb(l: Double, a: Double, b: Double) -> RGB {
        func enc(_ x: Double) -> Double {
            let v = MotionCurve.clamp01(x)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        let l3 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m3 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s3 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (enc(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
                enc(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
                enc(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3))
    }
}

/// SwiftUI's `.spring(response:dampingFraction:)` step response, evaluated in
/// closed form so a frame at any time is exact and repeatable: 0 at t = 0,
/// heading for 1, overshooting a little when the damping is under 1.
/// `response` is the period of the undamped spring, as in SwiftUI.
struct MotionSpring: Equatable {
    let response: Double
    let dampingFraction: Double

    /// Final approach: spring(response .5, damping .8), settled by ~520 ms.
    static let approach = MotionSpring(response: 0.5, dampingFraction: 0.8)

    func value(at t: Double) -> Double {
        guard t > 0, response > 0 else { return 0 }
        let w0 = 2 * Double.pi / response
        let z = max(0, dampingFraction)
        if z < 1 {
            let root = (1 - z * z).squareRoot()
            let wd = w0 * root
            return 1 - exp(-z * w0 * t) * (cos(wd * t) + z / root * sin(wd * t))
        }
        // Critically (or over-) damped: no overshoot.
        return 1 - exp(-w0 * t) * (1 + w0 * t)
    }
}

// MARK: - 1 · The pulse

/// The one glyph on every surface: still star-white when quiet, a teal breath
/// while agents work (4 s, a little faster with more), an amber ripple with
/// one ring per waiting item while something needs you, and a long exhale from
/// amber to teal when the last of those clears.
///
/// Every number here is the phone's too (iOS/Page/Models/PulseModel.swift),
/// so the pulse keeps one rhythm on every surface; both test suites pin the
/// same table of values, which is what catches one side drifting.
enum PulseModel {
    enum Mode: Equatable {
        case quiet
        case working(agents: Int)
        case waiting(count: Int)
        /// Paused for battery: a low glow.
        case paused
    }

    /// Pure. Paused wins, then waiting, then working, then quiet.
    static func mode(waiting: Int, working: Int, paused: Bool) -> Mode {
        if paused { return .paused }
        if waiting > 0 { return .waiting(count: waiting) }
        if working > 0 { return .working(agents: working) }
        return .quiet
    }

    // MARK: breath

    static let breathPeriodBase: TimeInterval = 4
    /// "Slightly faster" with more agents: never quicker than this.
    static let breathPeriodFloor: TimeInterval = 3
    /// Each agent past the first takes this much off the breath.
    static let breathStepPerAgent: TimeInterval = 0.15

    /// Pure. 4 s for one agent, 0.15 s quicker per extra agent, never under 3 s.
    static func breathPeriod(agents: Int) -> Double {
        max(breathPeriodFloor, breathPeriodBase - breathStepPerAgent * Double(max(0, agents - 1)))
    }

    /// Pure. 0 (out) ... 1 (in) through one breath, eased at both ends.
    static func breath(at t: Double, agents: Int) -> Double {
        let p = MotionCurve.fract(t / breathPeriod(agents: agents))
        return 0.5 - 0.5 * cos(p * 2 * .pi)
    }

    // MARK: ripple

    /// Never more than one new ring every 1.5 s.
    static let minRippleInterval: TimeInterval = 1.5
    /// One waiting item that has only just started waiting: a ring every 3 s.
    static let freshRippleInterval: TimeInterval = 3
    /// The longest wait at which the rate reaches its cap.
    static let rippleRamp: TimeInterval = 600
    /// Rings drawn at once: one per waiting item, up to this many.
    static let maxRings = 4

    /// Pure. Seconds between rings for one waiting item: 3 s fresh, falling
    /// evenly to the 1.5 s cap once the longest wait reaches ten minutes.
    static func rippleInterval(longestWait: TimeInterval) -> Double {
        let k = MotionCurve.clamp01(max(0, longestWait) / rippleRamp)
        return freshRippleInterval - (freshRippleInterval - minRippleInterval) * k
    }

    /// Pure. The oldest wait among the rows the pulse counts (the decisions,
    /// else the looks; never the finished turns), which sets the ripple's
    /// pace on every surface. The phone's `NowModel.pulseRows` picks the same rows.
    static func longestWait(rows: [DecideRow], now: Date) -> TimeInterval {
        let decide = rows.filter { $0.section == .decide }
        let counted = decide.isEmpty ? rows.filter { $0.section == .look } : decide
        return counted.map { max(0, now.timeIntervalSince($0.waitingSince)) }.max() ?? 0
    }

    /// Pure. One ring per waiting item, capped.
    static func ringCount(waiting: Int, cap: Int = maxRings) -> Int {
        min(max(0, cap), max(0, waiting))
    }

    /// Pure. How long one ring takes to travel out. With `n` rings evenly
    /// spaced through it, a new one leaves every `life / n` seconds, and that
    /// is never quicker than 1.5 s.
    static func ringLife(waiting: Int, longestWait: TimeInterval, cap: Int = maxRings) -> Double {
        let n = Double(max(1, ringCount(waiting: waiting, cap: cap)))
        return max(minRippleInterval * n, rippleInterval(longestWait: longestWait))
    }

    /// Pure. Seconds between two rings leaving the dot.
    static func emissionInterval(waiting: Int, longestWait: TimeInterval, cap: Int = maxRings) -> Double {
        ringLife(waiting: waiting, longestWait: longestWait, cap: cap) / Double(max(1, ringCount(waiting: waiting, cap: cap)))
    }

    struct Ring: Equatable {
        /// 0 = leaving the dot's own ring, 1 = fully out.
        let progress: Double
        let alpha: Double
    }

    /// Pure. A ring's opacity at `progress`: it fades in over the first tenth
    /// (so it never pops) and out as it grows.
    static func ringAlpha(_ progress: Double) -> Double {
        let p = MotionCurve.clamp01(progress)
        return MotionCurve.smoothstep(0, 0.1, p) * pow(1 - p, 1.5)
    }

    /// Pure. The rings at `t` seconds, evenly spaced through one ring's life.
    static func rings(at t: Double, waiting: Int, longestWait: TimeInterval, cap: Int = maxRings) -> [Ring] {
        let n = ringCount(waiting: waiting, cap: cap)
        guard n > 0 else { return [] }
        let life = ringLife(waiting: waiting, longestWait: longestWait, cap: cap)
        return (0..<n).map { i in
            let p = MotionCurve.fract(t / life + Double(i) / Double(n))
            return Ring(progress: p, alpha: ringAlpha(p))
        }
    }

    /// Pure. The same rings for a 0...1 `phase` through one ring's life (the
    /// status-bar animator quantises its phase so identical frames are skipped).
    static func rings(phase: Double, count: Int) -> [Ring] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            let p = MotionCurve.fract(phase + Double(i) / Double(count))
            return Ring(progress: p, alpha: ringAlpha(p))
        }
    }

    // MARK: the last one clears

    /// Amber to teal over 800 ms, with one long exhale.
    static let clearDuration: TimeInterval = 0.8
    /// The aurora settles a little after the dot.
    static let auroraSettleDuration: TimeInterval = 1.2
    /// With nothing left working, teal then cools to star-white.
    static let quietCoolDuration: TimeInterval = 0.6

    struct Exhale: Equatable {
        /// 0 = amber ... 1 = teal.
        let tealMix: Double
        /// 0 = teal ... 1 = star-white (only used when nothing is working).
        let starMix: Double
        /// Extra glow scale: the one long out-breath (rises, then settles to 0).
        let swell: Double
        /// What is left of the rings that were out when it cleared.
        let ringFade: Double
        /// 0 = the needs-you aurora ... 1 = settled into the new mood.
        let auroraSettle: Double
        let finished: Bool
    }

    /// Pure. The exhale `elapsed` seconds after the last Decide item cleared.
    static func exhale(elapsed: Double) -> Exhale {
        let e = max(0, elapsed)
        let u = MotionCurve.clamp01(e / clearDuration)
        let end = max(clearDuration + quietCoolDuration, auroraSettleDuration)
        return Exhale(
            tealMix: MotionCurve.easeInOut(u),
            starMix: MotionCurve.easeInOut(MotionCurve.segment(e, start: clearDuration, duration: quietCoolDuration)),
            swell: 0.24 * sin(Double.pi * u),
            ringFade: 1 - MotionCurve.easeOut(u),
            auroraSettle: MotionCurve.easeInOut(e / auroraSettleDuration),
            finished: e >= end)
    }

    /// The paused-for-battery glow, 0...1.
    static let pausedGlow = 0.15
}

// MARK: - 2 · Final approach

/// A new decision descends from the pulse into its ranked slot, trailing a
/// faint contrail: spring(.5, .8), about 520 ms. Only rows below the slot ease
/// down, by exactly one card height. In flight it is an empty outline (as
/// board 07 draws it), widening out from under the pulse; its words fade in
/// only as it lands, so they are never drawn over the header's or the
/// runway's. The phone's `ApproachModel` uses the same `content` curve.
enum ApproachModel {
    static let duration: TimeInterval = 0.52
    static let spring = MotionSpring.approach
    /// The card's content fades in over this stretch of its travel (about
    /// 200 to 290 ms): before it, the card is only its outline.
    static let contentFrom = 0.8
    static let contentTo = 0.97

    struct Frame: Equatable {
        /// 0 = top edge on the pulse ... 1 = in its slot (the spring may overshoot a hair).
        let travel: Double
        let opacity: Double
        /// Width scale, anchored under the pulse: 0.9 leaving it, 1 in the slot.
        let scale: Double
        /// 0...1 how far the outline has widened out from under the pulse to
        /// the card's full width (complete before any content shows).
        let reveal: Double
        /// 0...1 strength of the contrail from the pulse to the card's top edge.
        let contrail: Double
        /// 0...1 strength of the arrival glow round the card (off once it settles).
        let glow: Double
        /// 0...1 how far the rows below have eased down (1 = one full card height).
        let belowShift: Double
        /// 0...1 how much of the card's content (and its solid fill) shows.
        let content: Double
        /// 0...1 strength of the outline that stands in for the card in flight.
        let edge: Double
        let finished: Bool
    }

    /// Pure. How much of the card shows at `travel` (0 = on the pulse, 1 = in its slot).
    static func content(travel: Double) -> Double {
        MotionCurve.smoothstep(contentFrom, contentTo, travel)
    }

    /// Pure. The frame `elapsed` seconds after the card left the pulse.
    static func frame(elapsed: Double) -> Frame {
        let t = max(0, elapsed)
        if t >= duration {
            return Frame(travel: 1, opacity: 1, scale: 1, reveal: 1, contrail: 0, glow: 0, belowShift: 1,
                         content: 1, edge: 0, finished: true)
        }
        // The spring's last hair of overshoot is eased out over the final
        // 120 ms, so the card is exactly in its slot at 520 ms (no snap).
        let raw = spring.value(at: t)
        let travel = raw + (1 - raw) * MotionCurve.smoothstep(0.4, duration, t)
        let content = content(travel: travel)
        return Frame(
            travel: travel,
            opacity: 0.4 + 0.6 * MotionCurve.easeOut(t / 0.2),
            scale: 0.9 + 0.1 * MotionCurve.clamp01(travel),
            reveal: MotionCurve.easeOut(MotionCurve.clamp01(travel) / contentFrom),
            contrail: MotionCurve.smoothstep(0, 0.1, t) * (1 - MotionCurve.smoothstep(0.36, duration, t)),
            glow: MotionCurve.smoothstep(0, 0.3, t) * (1 - MotionCurve.smoothstep(0.38, duration, t)),
            belowShift: MotionCurve.easeOut(t / 0.34),
            content: content,
            edge: 0.6 * (1 - content),
            finished: false)
    }

    /// Pure. Points from the card's slot to where it is drawn: it starts with
    /// its top edge on the pulse (`pulseY`, same coordinate space as `slotTop`).
    static func cardOffset(pulseY: Double, slotTop: Double, elapsed: Double) -> Double {
        (pulseY - slotTop) * (1 - frame(elapsed: elapsed).travel)
    }

    /// Pure. Where a row below the slot is drawn relative to its new place:
    /// one card height up at first (where it was), easing down to 0.
    static func belowOffset(cardHeight: Double, elapsed: Double) -> Double {
        -cardHeight * (1 - frame(elapsed: elapsed).belowShift)
    }
}

/// A row is never re-sorted under the pointer. While the list is hovered, a
/// hold is on or the composer is open, the order you can see stays put: rows
/// that have gone drop out, rows already shown keep their place and their
/// latest content, and new arrivals wait behind a "New ↑ 1" pill. The Mac
/// port of the phone's `StableOrder`. Pure.
enum NowStableOrder {
    struct Result: Equatable {
        /// What to draw, in order.
        var rows: [DecideRow]
        /// Arrivals held back while frozen.
        var queuedNew: Int
    }

    /// `shown` is the ids on screen now (in order); `ranked` is the fresh
    /// ranking. Not frozen (or nothing shown yet): the fresh ranking.
    static func merge(shown: [String], ranked: [DecideRow], frozen: Bool) -> Result {
        guard frozen, !shown.isEmpty else { return Result(rows: ranked, queuedNew: 0) }
        let byId = Dictionary(ranked.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kept = shown.compactMap { byId[$0] }
        let known = Set(shown)
        return Result(rows: kept, queuedNew: ranked.filter { !known.contains($0.id) }.count)
    }
}

// MARK: - 3 · The receipt thread

/// Delivery truth made visible, in three phases: ARM (a local ring winds round
/// the card's dot; nothing sent, a tap cancels), SEND (a thread of light
/// leaves the card for the Mac and parks short of the next node; it can no
/// longer be cancelled), RESOLVE (only on the Mac's confirmation: the thread
/// completes, the dot turns teal, its rings contract into it, and the card
/// folds into a hairline that drifts into Settled). A failure snaps the thread
/// back, shakes the card once and says what happened. Success is never drawn
/// before the confirmed state reaches `frame`.
enum ReceiptThreadModel {
    /// The board's four labels, in order.
    enum Stage: Int, Equatable, CaseIterable {
        case arm, sent, typed, verified

        var label: String {
            switch self {
            case .arm: return "arm"
            case .sent: return "sent"
            case .typed: return "typed"
            case .verified: return "verified ✓"
            }
        }
    }

    /// What the Mac said.
    enum Resolution: Equatable {
        /// The keystroke landed and the screen confirmed it.
        case verified
        /// Accepted, but it will be typed after the agent's turn: nothing has landed yet.
        case queued
        /// It did not land, in words.
        case failed(String)
    }

    static let armDuration: TimeInterval = 1.2
    /// The thread runs from the card to where it parks.
    static let sendTravel: TimeInterval = 0.5
    /// Where the thread waits for the Mac: short of the "typed" node at 0.5.
    static let parkedAt = 0.42
    /// After the confirmation: the thread reaches "typed", then "verified".
    static let typedAfter: TimeInterval = 0.12
    static let verifiedAfter: TimeInterval = 0.3
    static let dotTurnStart: TimeInterval = 0.3
    static let dotTurnDuration: TimeInterval = 0.25
    static let ringsStart: TimeInterval = 0.35
    static let ringsDuration: TimeInterval = 0.3
    static let foldStart: TimeInterval = 0.7
    static let foldDuration: TimeInterval = 0.3
    static let driftStart: TimeInterval = 0.85
    static let driftDuration: TimeInterval = 0.45
    static var resolveDuration: TimeInterval { driftStart + driftDuration }
    static let snapBack: TimeInterval = 0.22
    static let shakeDuration: TimeInterval = 0.42
    static let shakeAmplitude = 5.0
    /// Reduce Motion: how long the still "verified ✓" stays before the row goes.
    static let reducedHold: TimeInterval = 0.8

    struct Frame: Equatable {
        /// The stage the label names; nil before anything is armed, and on failure.
        var stage: Stage?
        /// The words under the thread: a stage label, "queued", or what went wrong.
        var label: String
        /// 0...1 ring wound round the card's dot during ARM.
        var armRing: Double = 0
        /// 0...1 how far the thread has run from the card (0) through the
        /// middle node (0.5) to the end (1).
        var thread: Double = 0
        /// 0...1 brightness of the thread's head (it breathes while parked).
        var head: Double = 0
        /// 0 = in transit (sky) ... 1 = verified (green).
        var verifiedTint: Double = 0
        /// 0 = amber dot ... 1 = teal dot.
        var dotTeal: Double = 0
        /// 1 = rings out round the dot ... 0 = contracted into it.
        var rings: Double = 0
        /// 0 = the full card ... 1 = a hairline.
        var fold: Double = 0
        /// 0...1 the hairline drifting into Settled (and fading).
        var drift: Double = 0
        /// Horizontal offset in points: the one soft shake after a failure.
        var shake: Double = 0
        var failure: String? = nil
        /// True only during ARM.
        var cancellable: Bool = false
        /// Nothing left to animate.
        var finished: Bool = false
    }

    /// Pure. Where the thread is at `sentFor` seconds after it was sent, before any answer.
    static func parkedProgress(sentFor: Double) -> Double {
        parkedAt * MotionCurve.easeOut(max(0, sentFor) / sendTravel)
    }

    /// Pure. All times are seconds on one clock. `armedAt` is when a local arm
    /// began (nil when there is none, as for a key press at the Mac); `sentAt`
    /// when it was handed on; `resolvedAt` and `resolution` when the Mac
    /// answered and what it said. With `reduceMotion` nothing travels: each
    /// phase shows its end state.
    static func frame(now: Double, armedAt: Double? = nil, sentAt: Double?, resolvedAt: Double? = nil,
                      resolution: Resolution? = nil, reduceMotion: Bool = false) -> Frame {
        guard let sentAt else {
            guard let armedAt else { return Frame(stage: nil, label: "", finished: true) }
            let p = reduceMotion ? 0 : MotionCurve.clamp01((now - armedAt) / armDuration)
            return Frame(stage: .arm, label: Stage.arm.label, armRing: p, thread: 0.12 * p, head: p, cancellable: true)
        }
        let sentFor = max(0, now - sentAt)
        // Times arrive as differences of absolute clocks: a nanosecond of slack
        // keeps a frame exactly on a boundary on the right side of it.
        let eps = 1e-9
        guard let resolvedAt, let resolution else {
            // In flight: parked short of the Mac, breathing, never complete.
            let breath = 0.5 + 0.5 * sin(2 * Double.pi * sentFor / 1.2 - .pi / 2)
            return Frame(stage: .sent, label: Stage.sent.label, armRing: armedAt == nil ? 0 : 1,
                         thread: reduceMotion ? parkedAt : parkedProgress(sentFor: sentFor),
                         head: reduceMotion ? 1 : 0.55 + 0.45 * breath, rings: 1)
        }
        let e = max(0, now - resolvedAt) + eps
        let from = reduceMotion ? parkedAt : parkedProgress(sentFor: max(0, resolvedAt - sentAt))
        switch resolution {
        case .verified:
            if reduceMotion {
                return Frame(stage: .verified, label: Stage.verified.label, thread: 1, head: 1, verifiedTint: 1, dotTeal: 1,
                             rings: 0, finished: e >= reducedHold)
            }
            let thread: Double
            if e < typedAfter {
                thread = from + (0.5 - from) * MotionCurve.easeOut(e / typedAfter)
            } else {
                thread = 0.5 + 0.5 * MotionCurve.easeInOut((e - typedAfter) / (verifiedAfter - typedAfter))
            }
            let stage: Stage = e >= verifiedAfter ? .verified : (e >= typedAfter ? .typed : .sent)
            return Frame(
                stage: stage, label: stage.label, thread: thread, head: 1,
                verifiedTint: MotionCurve.smoothstep(verifiedAfter - 0.06, verifiedAfter + 0.1, e),
                dotTeal: MotionCurve.easeInOut(MotionCurve.segment(e, start: dotTurnStart, duration: dotTurnDuration)),
                rings: 1 - MotionCurve.easeIn(MotionCurve.segment(e, start: ringsStart, duration: ringsDuration)),
                fold: MotionCurve.easeInOut(MotionCurve.segment(e, start: foldStart, duration: foldDuration)),
                drift: MotionCurve.easeOut(MotionCurve.segment(e, start: driftStart, duration: driftDuration)),
                finished: e >= resolveDuration)
        case .queued:
            // Accepted, not landed: the thread stays parked and says so.
            return Frame(stage: .sent, label: "queued", thread: max(from, reduceMotion ? parkedAt : parkedProgress(sentFor: sentFor)),
                         head: 0.6, rings: 1, finished: e >= sendTravel)
        case .failed(let why):
            if reduceMotion {
                return Frame(stage: nil, label: why, failure: why, finished: true)
            }
            let snap = MotionCurve.easeIn(e / snapBack)
            let u = MotionCurve.segment(e, start: snapBack, duration: shakeDuration)
            let shake = (e > snapBack && u < 1) ? shakeAmplitude * sin(2 * Double.pi * u) * (1 - u) : 0
            return Frame(stage: nil, label: why, thread: from * (1 - snap), head: 1 - snap, rings: 1 - snap,
                         shake: shake, failure: why, finished: e >= snapBack + shakeDuration)
        }
    }
}

// MARK: - 4 · The hold ring

/// Deliberate commitment, for Irreversible approvals and Stop-all: the ring
/// appears after 300 ms, fills clockwise over 1.2 s, amber warming to red only
/// in its final third, with ticks at 25, 50 and 75 % and a last one when it is
/// full; letting go early unwinds it backwards. Then Touch ID, then a burst.
/// The same numbers as the phone's `HoldRingSpec` (the board's 25/50/75 %
/// ticks win over the spec text's 33/66/100 %, with 100 % kept as the commit).
enum HoldRingModel {
    static let deadZone: TimeInterval = 0.3
    static let fill: TimeInterval = 1.2
    /// Where the haptic ticks fall.
    static let ticks: [Double] = [0.25, 0.5, 0.75, 1.0]

    /// Pure. 0 = amber ... 1 = red. Red only in the final third.
    static func warmth(progress p: Double) -> Double {
        MotionCurve.clamp01((p - 2.0 / 3.0) * 3)
    }

    /// Pure. The ticks passed between two progress values (rising only).
    static func ticksCrossed(from: Double, to: Double) -> [Double] {
        guard to > from else { return [] }
        return ticks.filter { from < $0 - 1e-9 && to >= $0 - 1e-9 }
    }

    /// Pure. Progress while the ring unwinds after an early release: it runs
    /// back at the speed it filled. `released` is the progress at release.
    static func unwound(from released: Double, since: TimeInterval) -> Double {
        max(0, MotionCurve.clamp01(released) - max(0, since) / fill)
    }

    /// Pure. How long the unwind from `released` takes.
    static func unwindDuration(from released: Double) -> TimeInterval {
        MotionCurve.clamp01(released) * fill
    }

    static let burstDuration: TimeInterval = 0.5

    struct Burst: Equatable {
        /// Scale of the ring as it flares out.
        let scale: Double
        /// Opacity of the flaring ring.
        let alpha: Double
        /// 0...1 the core's flash, turning teal as it is confirmed.
        let flash: Double
        let finished: Bool
    }

    /// Pure. The burst `elapsed` seconds after Touch ID passed.
    static func burst(elapsed: Double) -> Burst {
        let u = MotionCurve.clamp01(max(0, elapsed) / burstDuration)
        return Burst(scale: 1 + 0.3 * MotionCurve.easeOut(u), alpha: 1 - MotionCurve.easeIn(u),
                     flash: sin(Double.pi * MotionCurve.easeOut(u)), finished: u >= 1)
    }
}

// MARK: - 5 · Dusk and dawn

/// Power, the original promise. At the battery cutoff the aurora fades to
/// dusk, every working star exhales and dims together, and a grey horizon band
/// holds. When power returns a dawn sweep rises from the horizon and relights
/// each star one by one, as each session's resume is confirmed. The same
/// sunrise, scaled to how much finished, opens Welcome back.
enum DuskDawnModel {
    // MARK: dusk

    static let duskDuration: TimeInterval = 2.4
    /// The stars swell once (the exhale) ...
    static let starSwellEnd: TimeInterval = 0.35
    /// ... then dim together to this: a faint speck, there to be relit (the
    /// paused sky is near-black, horizon only).
    static let starsDimmedTo = 0.1
    static let starDimEnd: TimeInterval = 1.4
    static let horizonStart: TimeInterval = 0.8
    static let horizonDuration: TimeInterval = 0.8

    struct Dusk: Equatable {
        /// 0 = the working aurora ... 1 = dusk.
        let duskMix: Double
        /// Brightness of the working stars (1 = lit; swells past 1 once).
        let stars: Double
        /// 0...1 the grey horizon band.
        let horizon: Double
        let finished: Bool
    }

    /// Pure. Dusk `elapsed` seconds after the cutoff paused the agents.
    static func dusk(elapsed: Double) -> Dusk {
        let e = max(0, elapsed)
        let stars: Double
        if e < starSwellEnd {
            stars = 1 + 0.25 * MotionCurve.easeOut(e / starSwellEnd)
        } else {
            let u = MotionCurve.segment(e, start: starSwellEnd, duration: starDimEnd - starSwellEnd)
            stars = 1.25 - (1.25 - starsDimmedTo) * MotionCurve.easeInOut(u)
        }
        return Dusk(duskMix: MotionCurve.easeInOut(e / duskDuration), stars: stars,
                    horizon: MotionCurve.easeOut(MotionCurve.segment(e, start: horizonStart, duration: horizonDuration)),
                    finished: e >= duskDuration)
    }

    // MARK: dawn

    static let dawnSweep: TimeInterval = 1.6
    static let relightStagger: TimeInterval = 0.16
    static let relightDuration: TimeInterval = 0.5
    static let dawnDuration: TimeInterval = 3.2

    /// One paused session's star.
    struct Star: Equatable {
        let id: String
        /// 0 = top of the sky ... 1 = on the horizon.
        let height: Double
        /// Seconds after dawn began that its resume was confirmed; nil = not
        /// confirmed, so it stays dim.
        let confirmedAt: TimeInterval?
    }

    /// Pure. 0 = at the horizon ... 1 = at the top of the sky.
    static func sweepFront(elapsed: Double) -> Double {
        MotionCurve.easeOut(max(0, elapsed) / dawnSweep)
    }

    /// Pure. When the rising front passes a star at `height` (inverse of `sweepFront`).
    static func sweepReach(height: Double) -> TimeInterval {
        let target = 1 - MotionCurve.clamp01(height)   // distance up from the horizon
        // easeOut(x) = 1 - (1 - x)^3  =>  x = 1 - (1 - target)^(1/3)
        return dawnSweep * (1 - pow(1 - target, 1.0 / 3.0))
    }

    /// Pure. When each confirmed star relights: not before its resume was
    /// confirmed, not before the sweep reaches it, and one by one (each at
    /// least `relightStagger` after the one before). Unconfirmed stars are absent.
    static func relightTimes(_ stars: [Star]) -> [String: TimeInterval] {
        let ready = stars.compactMap { s -> (String, TimeInterval)? in
            guard let c = s.confirmedAt else { return nil }
            return (s.id, max(c, sweepReach(height: s.height)))
        }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var out: [String: TimeInterval] = [:]
        var last = -Double.infinity
        for (id, t) in ready {
            let at = max(t, last + relightStagger)
            out[id] = at
            last = at
        }
        return out
    }

    /// Pure. A star's brightness: dim (`starsDimmedTo`) until it relights, then
    /// up to 1 with a small flare.
    static func starLight(elapsed: Double, relitAt: TimeInterval?) -> Double {
        guard let r = relitAt, elapsed > r else { return starsDimmedTo }
        let u = MotionCurve.clamp01((elapsed - r) / relightDuration)
        return starsDimmedTo + (1 - starsDimmedTo) * MotionCurve.easeOut(u) + 0.35 * sin(Double.pi * u)
    }

    struct Dawn: Equatable {
        /// 0 = at the horizon ... 1 = at the top.
        let front: Double
        /// 0...1 strength of the warm light (rises, then gives way to the day's aurora).
        let glow: Double
        /// 0...1 what is left of the horizon band.
        let horizon: Double
        /// 0 = dusk ... 1 = the working aurora back.
        let auroraReturn: Double
        let finished: Bool
    }

    /// Pure. Dawn `elapsed` seconds after power returned.
    static func dawn(elapsed: Double) -> Dawn {
        let e = max(0, elapsed)
        let glow: Double = e < 1.2 ? MotionCurve.easeOut(e / 1.2)
            : 1 - MotionCurve.easeInOut(MotionCurve.segment(e, start: 1.2, duration: dawnDuration - 1.2))
        return Dawn(front: sweepFront(elapsed: e), glow: glow,
                    horizon: 1 - MotionCurve.smoothstep(0.6, dawnSweep, e),
                    auroraReturn: MotionCurve.smoothstep(1.2, dawnDuration - 0.2, e),
                    finished: e >= dawnDuration)
    }

    // MARK: sunrise (Welcome back)

    static let sunriseDuration: TimeInterval = 2.2

    /// Pure. 0...1: how much of the absence finished well. Finished turns
    /// count fully, ones you handled from the phone half, and what still needs
    /// you counts against; a quiet absence still gets a low dawn (0.25).
    static func sunriseScale(finished: Int, needYou: Int, handledOnPhone: Int) -> Double {
        let f = Double(max(0, finished)), n = Double(max(0, needYou)), h = Double(max(0, handledOnPhone))
        let total = f + n + h
        guard total > 0 else { return 0.25 }
        return max(0.25, min(1, (f + 0.5 * h) / total))
    }

    struct Sunrise: Equatable {
        /// 0...1 height of the light's front over the panel, from the bottom edge.
        let front: Double
        /// 0...1 strength of the warm light; settles to a resting glow.
        let glow: Double
        let finished: Bool
    }

    /// Pure. The sunrise `elapsed` seconds after Welcome back opened, scaled
    /// by `scale` (see `sunriseScale`): a good absence rises higher and warmer.
    static func sunrise(elapsed: Double, scale: Double) -> Sunrise {
        let e = max(0, elapsed)
        let k = MotionCurve.clamp01(scale)
        let peak = 0.3 + 0.7 * k
        let strength = 0.35 + 0.65 * k
        let glow: Double = e < 1.0 ? MotionCurve.easeOut(e / 1.0)
            : 1 - 0.55 * MotionCurve.easeInOut(MotionCurve.segment(e, start: 1.0, duration: sunriseDuration - 1.0))
        return Sunrise(front: peak * MotionCurve.easeOut(e / 1.4), glow: strength * glow, finished: e >= sunriseDuration)
    }
}
