import Foundation

/// DUSK AND DAWN: power, the original promise.
///
/// When Page pauses agents at the battery cutoff the aurora fades to dusk,
/// every working star exhales and dims together, and a grey horizon band
/// holds across the sky. When power returns a dawn sweep rises from the
/// horizon and relights each star one by one, each only once that session's
/// own resume is confirmed (it is seen working again): the sweep may be early,
/// a star never is. The same sunrise, scaled to how much finished, opens the
/// Return Brief after an absence.
///
/// Pure frames over elapsed seconds, so the harness can pin any moment.
enum DawnModel {
    /// The aurora fades to dusk over this long.
    static let duskDuration: TimeInterval = 1.6
    /// The working stars exhale and dim together over this long...
    static let exhale: TimeInterval = 1.2
    /// ...to this brightness.
    static let dimTo = 0.3
    /// The dawn sweep takes this long to rise from the horizon to the top.
    static let sweepDuration: TimeInterval = 1.8
    /// Stars confirmed together still relight one by one, this far apart.
    static let stagger: TimeInterval = 0.16
    /// A star takes this long to come back up (with a small flare).
    static let relight: TimeInterval = 0.5
    /// Once every confirmed star is lit, the gold settles back into the working aurora.
    static let settle: TimeInterval = 1.2
    /// Past this long a dawn is over whatever is still unconfirmed (it shows as it is).
    static let dawnLimit: TimeInterval = 90

    struct Dusk: Equatable {
        /// 0 the working palette ... 1 the dusk palette.
        let aurora: Double
        /// Star brightness multiplier: 1 ... `dimTo`.
        let stars: Double
        /// The exhale: the stars shrink a touch as they breathe out (1 ... 0.9).
        let starScale: Double
        /// The grey horizon band: 0 ... 1, then holds.
        let band: Double
    }

    /// Dusk, `elapsed` seconds after the pause began. Pure.
    static func dusk(elapsed t: TimeInterval) -> Dusk {
        let a = MotionCurve.smooth(t / duskDuration)
        let x = MotionCurve.clamp01(t / exhale)
        // One breath out: a slight swell first, then down together.
        let swell = x < 0.2 ? MotionCurve.smooth(x / 0.2) * 0.12 : 0.12 * (1 - MotionCurve.smooth((x - 0.2) / 0.3))
        let dim = MotionCurve.smooth(MotionCurve.progress(t, from: exhale * 0.2, to: exhale))
        let stars = (1 + swell) * (1 - (1 - dimTo) * dim)
        let band = MotionCurve.smooth(MotionCurve.progress(t, from: 0.5, to: duskDuration))
        return Dusk(aurora: a, stars: stars, starScale: 1 + swell * 0.5 - 0.1 * dim, band: band)
    }

    /// Height of the dawn's light front: 0 at the horizon ... 1 at the top. Pure.
    static func sweep(elapsed t: TimeInterval) -> Double { MotionCurve.easeOut(t / sweepDuration) }

    /// When the sweep passes a star `y` down the sky (0 top ... 1 bottom). Pure.
    static func sweepReaches(y: Double) -> TimeInterval {
        let h = MotionCurve.clamp01(1 - y)
        // Inverse of the ease-out: 1 - (1 - x)^3 = h.
        return sweepDuration * (1 - pow(1 - h, 1.0 / 3.0))
    }

    struct StarInput: Equatable {
        let id: String
        /// 0 top ... 1 bottom of the sky.
        let y: Double
        /// Seconds after dawn began that its resume was confirmed; nil while unconfirmed.
        let confirmedAt: TimeInterval?
    }

    /// When each star relights, in seconds after dawn began: its own
    /// confirmation, not before the sweep reaches it, and at least `stagger`
    /// after the star before it (one by one). Unconfirmed stars are absent:
    /// they stay dim. Ties go to the earlier confirmation, then the lower
    /// star (the sweep comes from below), then the id. Pure.
    static func relightTimes(_ stars: [StarInput]) -> [String: TimeInterval] {
        let ready = stars.compactMap { s -> (StarInput, TimeInterval)? in
            guard let c = s.confirmedAt else { return nil }
            return (s, max(c, sweepReaches(y: s.y)))
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 < b.1 }
            if a.0.confirmedAt != b.0.confirmedAt { return (a.0.confirmedAt ?? 0) < (b.0.confirmedAt ?? 0) }
            if a.0.y != b.0.y { return a.0.y > b.0.y }
            return a.0.id < b.0.id
        }
        var out: [String: TimeInterval] = [:]
        var last = -Double.infinity
        for (s, earliest) in ready {
            let at = max(earliest, last + stagger)
            out[s.id] = at
            last = at
        }
        return out
    }

    /// A star's brightness multiplier during dawn: `dimTo` until it relights,
    /// then up to 1 over `relight` with a 15% flare at two thirds. Pure.
    static func starBrightness(elapsed t: TimeInterval, relightAt: TimeInterval?) -> Double {
        guard let at = relightAt, t > at else { return dimTo }
        let x = MotionCurve.clamp01((t - at) / relight)
        let rise = dimTo + (1 - dimTo) * MotionCurve.easeOut(x / 0.66)
        let flare = x < 0.66 ? 0 : 0.15 * sin((x - 0.66) / 0.34 * Double.pi)
        return min(1.15, rise + flare)
    }

    struct Dawn: Equatable {
        /// The light front: 0 horizon ... 1 top.
        let sweep: Double
        /// The gold of the sunrise: rises with the sweep, holds while stars
        /// relight, then settles away. 0 ... 1.
        let warmth: Double
        /// The grey band fades as the sweep leaves it: 1 ... 0.
        let band: Double
        /// 1 the dusk palette ... 0 the working palette.
        let aurora: Double
        let finished: Bool
    }

    /// Dawn, `elapsed` seconds after power came back. `lastRelight` is the
    /// latest relight time (nil when no star has been confirmed: the gold
    /// settles after the sweep alone). Pure.
    static func dawn(elapsed t: TimeInterval, lastRelight: TimeInterval?) -> Dawn {
        let s = sweep(elapsed: t)
        let lit = max(sweepDuration, (lastRelight ?? 0) + relight)
        let rise = MotionCurve.smooth(t / (sweepDuration * 0.6))
        let fade = MotionCurve.smooth(MotionCurve.progress(t, from: lit, to: lit + settle))
        let band = 1 - MotionCurve.smooth(MotionCurve.progress(t, from: 0, to: sweepDuration * 0.5))
        let aurora = 1 - MotionCurve.smooth(MotionCurve.progress(t, from: sweepDuration * 0.3, to: lit + settle))
        return Dawn(sweep: s, warmth: rise * (1 - fade), band: band, aurora: aurora, finished: t >= lit + settle)
    }

    /// The Return Brief's sunrise: the same sweep, as bright as the absence
    /// was productive (`share` 0...1 finished). Pure.
    static func briefSunrise(elapsed t: TimeInterval, share: Double) -> (sweep: Double, strength: Double) {
        (sweep(elapsed: t), 0.25 + 0.75 * MotionCurve.clamp01(share))
    }
}

/// What the phone saw of the last battery pause, for the dusk and dawn:
/// when it began, which sessions it stopped, when power came back and when
/// each of those sessions was seen working again. Fed from the live session
/// list; pure (mutating a value), so the tests drive it with plain sets.
struct DuskDawnLog: Equatable {
    /// When the pause began; distant past when Page opened onto a pause
    /// already in progress (drawn settled, not replayed).
    private(set) var duskAt: Date?
    /// When the pause ended: the dawn. nil while paused or once the dawn is over.
    private(set) var dawnAt: Date?
    /// Sessions that were working when the pause began.
    private(set) var affected: Set<String> = []
    /// When each affected session was first seen working after the dawn.
    private(set) var resumedAt: [String: Date] = [:]
    private var wasPaused: Bool?
    private var lastWorking: Set<String> = []

    init() {}

    var isPaused: Bool { wasPaused == true }

    /// Records one look at the fleet. `working` is the ids of the sessions
    /// working now. Pure (mutating).
    mutating func observe(paused: Bool, working: Set<String>, at now: Date) {
        defer { wasPaused = paused; if !paused { lastWorking = working } }
        guard let was = wasPaused else {
            // First look: a pause already under way is drawn as it is.
            if paused { duskAt = .distantPast; affected = working }
            return
        }
        if paused && !was {
            duskAt = now
            dawnAt = nil
            resumedAt = [:]
            // What was working the moment before (the Mac may already have stopped them).
            affected = lastWorking.union(working)
        } else if paused {
            affected.formUnion(working)
        } else if was {
            dawnAt = now
            duskAt = nil
        }
        if !paused, let dawn = dawnAt {
            for id in working.intersection(affected) where resumedAt[id] == nil { resumedAt[id] = now }
            let allBack = !affected.isEmpty && resumedAt.count == affected.count
            if now.timeIntervalSince(dawn) > DawnModel.dawnLimit || (allBack && now.timeIntervalSince(dawn) > DawnModel.sweepDuration + DawnModel.settle + 2) {
                dawnAt = nil
            }
        }
    }

    /// The dawn's star inputs: each affected star's confirmation, in seconds
    /// after the dawn. `ys` gives each star's height in the sky. Pure.
    func dawnStars(ys: [String: Double]) -> [DawnModel.StarInput] {
        guard let dawn = dawnAt else { return [] }
        return affected.sorted().map { id in
            DawnModel.StarInput(id: id, y: ys[id] ?? 0.5, confirmedAt: resumedAt[id].map { max(0, $0.timeIntervalSince(dawn)) })
        }
    }
}
