import Foundation

/// THE PULSE: one glyph on every surface (the Horizon, the capsule, Sky's
/// stars, the widgets). Still star-white when all is quiet; a teal breath
/// every 4 s while agents work (a little faster with more of them); an
/// amber ripple when something needs you, one ring per waiting item, the
/// rate rising with the longest wait and capped at one ring every 1.5 s; a
/// low dusk glow while paused for battery. When the last item clears, the
/// pulse turns from amber to teal over 800 ms with one long exhale.
///
/// Pure timing: the views ask it for a frame at a time in seconds, so the
/// render harness can pin any moment and the tests can check the board's.
/// Every number is the Mac's too (Sources/ClaudePowerMode/UI/
/// SignatureMotion.swift), so the pulse keeps one rhythm on every surface;
/// both test suites pin the same table of values.
struct PulseModel: Equatable {
    enum Mode: String, Equatable {
        /// Nothing running, nothing waiting: still, star-white.
        case quiet
        /// Agents working: the teal breath.
        case working
        /// Something needs you: the amber ripple.
        case waiting
        /// Paused at the battery cutoff: a low, still glow.
        case dusk
    }

    let mode: Mode
    let working: Int
    let waiting: Int
    /// Seconds the oldest waiting item has waited.
    let longestWait: TimeInterval

    /// The breath with one agent working.
    static let baseBreath: TimeInterval = 4
    /// The quickest the breath gets, however many agents work ("slightly faster").
    static let fastestBreath: TimeInterval = 3
    /// Each agent past the first takes this much off the breath.
    static let breathStep: TimeInterval = 0.15
    /// One ring every 3 s for one item that has just started waiting...
    static let slowestRipple: TimeInterval = 3
    /// ...rising to the cap of one ring every 1.5 s...
    static let fastestRipple: TimeInterval = 1.5
    /// ...once the longest wait reaches ten minutes.
    static let rippleRamp: TimeInterval = 600
    /// More rings than this read as noise, not a count.
    static let maxRings = 4
    /// The colour turns from amber to teal over this long when the last item clears.
    static let exhaleColour: TimeInterval = 0.8
    /// The one long exhale (the glow swells, then settles) lasts this long.
    static let exhaleDuration: TimeInterval = 1.6

    /// Battery pause wins; then anything waiting; then anything working. Pure.
    init(working: Int, waiting: Int, longestWait: TimeInterval = 0, paused: Bool = false) {
        self.working = max(0, working)
        self.waiting = max(0, waiting)
        self.longestWait = max(0, longestWait)
        if paused { mode = .dusk }
        else if waiting > 0 { mode = .waiting }
        else if working > 0 { mode = .working }
        else { mode = .quiet }
    }

    /// The longest wait among the rows' `waitingSince`, at `now`. Pure.
    static func longestWait(since dates: [Date], now: Date) -> TimeInterval {
        dates.map { max(0, now.timeIntervalSince($0)) }.max() ?? 0
    }

    /// True while the pulse moves at all. Quiet and dusk are still, so they
    /// run no clock and cost nothing.
    var isAnimated: Bool { mode == .working || mode == .waiting }

    /// The frame rate the pulse needs: a slow breath reads smoothly at 20,
    /// a ripple at 30. 0 when still.
    var framesPerSecond: Double {
        switch mode {
        case .working: return 20
        case .waiting: return 30
        case .quiet, .dusk: return 0
        }
    }

    /// Seconds per teal breath: 4 s with one agent, 0.15 s quicker for each
    /// further agent, never quicker than 3 s.
    var breathPeriod: TimeInterval {
        max(Self.fastestBreath, Self.baseBreath - Self.breathStep * Double(max(0, working - 1)))
    }

    /// Seconds between amber rings for one waiting item: 3 s for a fresh
    /// wait, falling linearly to the 1.5 s cap at ten minutes.
    var rippleInterval: TimeInterval {
        let k = MotionCurve.clamp01(longestWait / Self.rippleRamp)
        return Self.slowestRipple - (Self.slowestRipple - Self.fastestRipple) * k
    }

    /// Rings on screen at once: one per waiting item, at most `maxRings`.
    var ringCount: Int { mode == .waiting ? min(waiting, Self.maxRings) : 0 }

    /// How long one ring takes to open fully. With `ringCount` rings evenly
    /// spaced through it a new one leaves every `lifetime / count` seconds,
    /// never quicker than one every 1.5 s: more waiting items ripple faster,
    /// up to the cap (board 07, "3 waiting · faster, capped").
    var ringLifetime: TimeInterval { max(Self.fastestRipple * Double(max(1, ringCount)), rippleInterval) }

    /// Seconds between two rings leaving the core.
    var emissionInterval: TimeInterval { ringLifetime / Double(max(1, ringCount)) }

    /// The breath at `t` seconds: 0 (in) ... 1 (out), a sine. 0.5 when not working.
    func breath(at t: Double) -> Double {
        guard mode == .working else { return 0.5 }
        return 0.5 + 0.5 * sin(t * 2 * Double.pi / breathPeriod - Double.pi / 2)
    }

    /// One amber ring.
    struct Ripple: Equatable {
        /// 0 (just left the core ring) ... 1 (fully open).
        let progress: Double
        /// Fades in over the first tenth (so it never pops), then out as it opens.
        let opacity: Double
    }

    /// A ring's opacity at `progress`, the Mac's curve. Pure.
    static func ringOpacity(_ progress: Double) -> Double {
        let p = MotionCurve.clamp01(progress)
        return MotionCurve.smooth(p / 0.1) * pow(1 - p, 1.5)
    }

    /// The rings in flight at `t`, the newest first. Empty unless waiting. Pure.
    func ripples(at t: Double) -> [Ripple] {
        let n = ringCount
        guard n > 0 else { return [] }
        let phase = (max(0, t) / emissionInterval).truncatingRemainder(dividingBy: 1)
        return (0..<n).map { j in
            let p = (phase + Double(j)) / Double(n)
            return Ripple(progress: p, opacity: Self.ringOpacity(p))
        }
    }

    /// Reduce Motion: a static ring with a count. The number of waiting items
    /// (nil when nothing waits).
    var staticCount: Int? { mode == .waiting ? waiting : nil }

    // MARK: the exhale

    /// The last waiting item just cleared (amber to anything but amber, and
    /// not into the battery pause, which has its own dusk). Pure.
    static func exhales(from old: Mode, to new: Mode) -> Bool {
        old == .waiting && (new == .working || new == .quiet)
    }

    /// A frame of the exhale, `elapsed` seconds after the last item cleared.
    struct Exhale: Equatable {
        /// 0 = amber ... 1 = the new colour (teal, or star-white when quiet).
        let colour: Double
        /// 0 ... 1 ... 0: the glow swells once and settles.
        let swell: Double
        /// The aurora settles from amber to the new palette with it: 0...1.
        let aurora: Double
        let finished: Bool
    }

    /// The exhale at `elapsed` seconds: colour over 800 ms (smoothstep), one
    /// swell peaking at 35% of 1.6 s, the aurora following over the whole
    /// 1.6 s. Pure.
    static func exhale(elapsed: TimeInterval) -> Exhale {
        let c = MotionCurve.smooth(elapsed / exhaleColour)
        let x = MotionCurve.clamp01(elapsed / exhaleDuration)
        // A quick breath out, then a long settle.
        let swell = x < 0.35 ? MotionCurve.smooth(x / 0.35) : 1 - MotionCurve.smooth((x - 0.35) / 0.65)
        return Exhale(colour: c, swell: elapsed <= 0 ? 0 : swell, aurora: MotionCurve.smooth(x), finished: elapsed >= exhaleDuration)
    }
}
