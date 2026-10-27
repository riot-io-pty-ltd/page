import SwiftUI

// DUSK AND DAWN, drawn (`DawnModel` for the timing): the grey horizon band
// that holds while agents are paused for battery, and the dawn's gold light
// rising from it when power comes back. Shared by the Horizon, Lanes and the
// Return Brief's sunrise.

extension NightWatch.AuroraPalette {
    /// The sunrise the dawn sweeps in: gold over a warm brown, no curtains of
    /// its own (the light is the sweep). Board 07, "power · dawn".
    static let dawn = NightWatch.AuroraPalette(
        c1: NightWatch.RGBA(hex: 0xF5B14C), c2: NightWatch.RGBA(hex: 0xF2C94C), c3: NightWatch.RGBA(hex: 0x8A5A22),
        skyTop: NightWatch.RGBA(hex: 0x6B4F2A), skyBottom: NightWatch.RGBA(hex: 0x0B0A0C), intensity: 0.25, speed: 0.3)

    /// Paused for battery, settled: the dusk gone to near-black, horizon only
    /// (board 07, "paused · horizon only"). The same values as the Mac's.
    static let night = NightWatch.AuroraPalette(
        c1: NightWatch.RGBA(hex: 0x2A2440), c2: NightWatch.RGBA(hex: 0x16131F), c3: NightWatch.RGBA(hex: 0x16131F),
        skyTop: NightWatch.RGBA(hex: 0x0B0B14), skyBottom: NightWatch.RGBA(hex: 0x07080D), intensity: 0, speed: 0)

    /// The sky `duskMix` (0...1) of the way from this palette into the night:
    /// the purple dusk half way (board 07, "cutoff · dusk falls"), near-black
    /// by the end. The Mac's is the same.
    func towardNight(_ duskMix: Double) -> NightWatch.AuroraPalette {
        let d = max(0, min(1, duskMix))
        return d < 0.5 ? mixed(with: .dusk, d * 2) : NightWatch.AuroraPalette.dusk.mixed(with: .night, (d - 0.5) * 2)
    }
}

extension DawnModel {
    /// What is left of the background star field once paused (it fades with the dusk).
    static let pausedStarField = 0.05

    /// The background star field `duskMix` (0...1) into the dusk.
    static func starField(duskMix: Double) -> Double {
        1 - (1 - pausedStarField) * max(0, min(1, duskMix))
    }
}

/// The horizon band of a battery pause: a fine grey line with a soft glow
/// either side, across the sky. Over the near-black night it is the one thing
/// left to see, so it is crisp and light. `opacity` 0 draws nothing.
struct NWHorizonBand: View {
    var opacity: Double
    var inset: CGFloat = 24

    var body: some View {
        if opacity > 0.001 {
            ZStack {
                Capsule().fill(Color(white: 0.7).opacity(0.3 * opacity)).frame(height: 7).blur(radius: 5)
                Capsule().fill(LinearGradient(stops: [.init(color: Color(white: 0.82).opacity(0), location: 0),
                                                      .init(color: Color(white: 0.82).opacity(0.95 * opacity), location: 0.1),
                                                      .init(color: Color(white: 0.82).opacity(0.95 * opacity), location: 0.9),
                                                      .init(color: Color(white: 0.82).opacity(0), location: 1)],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1.2)
            }
            .padding(.horizontal, inset)
            .frame(height: 12)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The dawn's light: gold rising from the horizon (the bottom of this view)
/// to `sweep` of its height, brightest at the climbing front and warm
/// behind it; `warmth` scales it all (0 draws nothing).
struct NWDawnLight: View {
    var sweep: Double
    var warmth: Double

    var body: some View {
        if warmth > 0.001 && sweep > 0 {
            Canvas { ctx, size in
                let h = size.height, w = size.width
                let front = h * CGFloat(1 - MotionCurve.clamp01(sweep))
                let gold = NightWatch.RGBA(hex: 0xF5B14C)
                let ember = NightWatch.RGBA(hex: 0xB0702A)
                // The lit sky behind the front: warm, brightest just behind the front, which
                // feathers out above it (no edge anywhere), settling to a low glow at the horizon.
                let feather: CGFloat = 70
                let top = front - feather
                let lit = CGRect(x: 0, y: top, width: w, height: h - top)
                let f = Double(feather / max(1, h - top))
                ctx.fill(Path(lit), with: .linearGradient(
                    Gradient(stops: [.init(color: gold.opacity(0).color, location: 0),
                                     .init(color: gold.opacity(0.42 * warmth).color, location: f),
                                     .init(color: ember.opacity(0.24 * warmth).color, location: f + (1 - f) * 0.55),
                                     .init(color: ember.opacity(0.12 * warmth).color, location: f + (1 - f) * 0.85),
                                     .init(color: ember.opacity(0).color, location: 1)]),
                    startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: h)))
                // The front itself: a soft bright edge that climbs (fading as it nears the top).
                var edge = ctx
                edge.addFilter(.blur(radius: 14))
                edge.blendMode = .plusLighter
                let band = CGRect(x: -20, y: front - 10, width: w + 40, height: 20)
                edge.fill(Path(ellipseIn: band), with: .color(gold.opacity(0.55 * warmth * (1 - 0.6 * sweep)).color))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Lanes

/// What Lanes' power story looks like at one moment.
struct NWLanesLight {
    var palette: NightWatch.AuroraPalette
    /// The grey band: 0 ... 1.
    var band: Double
    /// The dawn's sweep and gold, while it plays.
    var dawn: DawnModel.Dawn?
    /// How much of the background star field shows (it fades with the dusk).
    var stars: Double = 1
    /// How much of the aurora behind the list shows: it fades in with the dusk, holds
    /// through the night of a pause, and fades out as the dawn settles. 0 in the day.
    var cover: Double = 0
}

extension LanesScreenData {
    /// `t` is a real clock (reference-date seconds), not the still frame
    /// `NWAnimated` hands out under Reduce Motion: then every change is
    /// drawn as it ends.
    private static func isClock(_ t: Double) -> Bool { t > 1_000_000 }

    /// Seconds into the dusk at clock time `t` (reference-date seconds, or the
    /// harness's pinned moment); a pause already under way when Page opened
    /// is drawn settled. nil when not paused.
    func duskElapsed(at t: Double, pin: NWMotionPin?) -> Double? {
        guard fleet.paused else { return nil }
        if let pin, pin.kind == .dusk { return pin.time }
        guard let at = duskDawn.duskAt, at != .distantPast, Self.isClock(t) else { return DawnModel.duskDuration }
        return max(0, t - at.timeIntervalSinceReferenceDate)
    }

    /// Seconds into the dawn, while one plays.
    func dawnElapsed(at t: Double, pin: NWMotionPin?) -> Double? {
        guard !fleet.paused else { return nil }
        if let pin, pin.kind == .dawn { return pin.time }
        guard Self.isClock(t) else { return nil }
        return duskDawn.dawnAt.map { max(0, t - $0.timeIntervalSinceReferenceDate) }
    }

    /// Every lane in the order it is drawn, as a height in the list: 0 the top lane ... 1 the
    /// bottom one. The dawn rises from the bottom, so the lower lanes relight first.
    private var laneHeights: [String: Double] {
        let ids = lanes.groups.flatMap(\.rows).map(\.id)
        let n = Double(max(1, ids.count))
        return Dictionary(ids.enumerated().map { ($0.element, (Double($0.offset) + 0.5) / n) }, uniquingKeysWith: { a, _ in a })
    }

    /// When each paused lane relights: its own confirmed resume, one by one.
    var relights: [String: TimeInterval] { DawnModel.relightTimes(duskDawn.dawnStars(ys: laneHeights)) }

    /// True while the power story moves and so needs a clock: the dusk
    /// falling, or the dawn rising. A pause that has settled holds still.
    func powerStoryMoving(pin: NWMotionPin?, now: Date = Date()) -> Bool {
        if pin?.kind == .dusk || pin?.kind == .dawn { return true }
        if fleet.paused, let at = duskDawn.duskAt, at != .distantPast { return now.timeIntervalSince(at) < DawnModel.duskDuration }
        guard !fleet.paused, let dawn = duskDawn.dawnAt else { return false }
        return !DawnModel.dawn(elapsed: now.timeIntervalSince(dawn), lastRelight: relights.values.max()).finished
    }

    /// True when the power story has anything to draw behind the list: a pause (settled
    /// or falling) or a dawn that is still playing.
    func powerStoryShown(pin: NWMotionPin?, now: Date = Date()) -> Bool {
        fleet.paused || powerStoryMoving(pin: pin, now: now)
    }

    /// The sky at `t`: fading to dusk with the band holding; or the gold dawn
    /// rising back into the day. In the day `cover` is 0 and only the shell's sky shows.
    func skyLight(at t: Double, pin: NWMotionPin?) -> NWLanesLight {
        if let d = duskElapsed(at: t, pin: pin) {
            let f = DawnModel.dusk(elapsed: d)
            return NWLanesLight(palette: NightWatch.AuroraPalette.working.towardNight(f.aurora), band: f.band, dawn: nil,
                                stars: DawnModel.starField(duskMix: f.aurora), cover: f.aurora)
        }
        if let w = dawnElapsed(at: t, pin: pin) {
            let f = DawnModel.dawn(elapsed: w, lastRelight: relights.values.max())
            if !f.finished {
                // Up from the night; the sweep carries the gold, the sky behind it only warms a little.
                let sunrise = NightWatch.AuroraPalette.night.mixed(with: .dawn, 0.35 * f.warmth)
                return NWLanesLight(palette: sunrise.mixed(with: .working, 1 - f.aurora), band: f.band, dawn: f,
                                    stars: DawnModel.starField(duskMix: f.aurora), cover: f.aurora)
            }
        }
        return NWLanesLight(palette: .working, band: 0, dawn: nil)
    }

    /// A lane's light in the power story: at dusk every working (or paused)
    /// lane exhales and dims together; at dawn each paused lane stays dim
    /// until its own resume is confirmed, then relights. (1, 1) otherwise.
    func starLight(id: String, state: StarState, at t: Double, pin: NWMotionPin?, relights: [String: TimeInterval]) -> (brightness: Double, scale: Double) {
        if let d = duskElapsed(at: t, pin: pin) {
            guard state == .paused || state == .working || duskDawn.affected.contains(id) else { return (1, 1) }
            let f = DawnModel.dusk(elapsed: d)
            return (f.stars, f.starScale)
        }
        if let w = dawnElapsed(at: t, pin: pin), duskDawn.affected.contains(id) {
            return (DawnModel.starBrightness(elapsed: w, relightAt: relights[id]), 1)
        }
        return (1, 1)
    }
}
