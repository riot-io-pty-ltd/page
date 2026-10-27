import SwiftUI

/// The Horizon: the top of the Now screen. Aurora behind, the pulse in the
/// middle, the one honest sentence below it. It fades into the page, so it
/// has no edge of its own to look cut off.
///
/// It plays three of the signature motions on one clock: the pulse itself;
/// the exhale when the last waiting item clears (the pulse turns amber to
/// teal over 800 ms and the aurora settles with it); and dusk and dawn (the
/// aurora fades to dusk at the battery cutoff and a grey band holds under
/// the pulse; when power returns a gold dawn rises from that band). Each
/// change is noticed here as it happens; the render harness pins a moment
/// with `\.nwMotion`. Reduce Motion: every change is a cut.
struct NWHorizon: View {
    var palette: NightWatch.AuroraPalette
    var pulse: NWPulseOrb.Style
    var headline: String
    var subline: String
    /// A third, quieter line ("Page is keeping watch. Go to sleep.").
    var footnote: String? = nil
    var height: CGFloat = 330
    /// Space kept clear at the top for the status bar and the Mac chip.
    var topInset: CGFloat = 0
    /// The counts behind the pulse (its breath and rings); the style's
    /// default when nil.
    var model: PulseModel? = nil

    @Environment(\.nwMotion) private var pin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the exhale, dusk or dawn began (reference-date seconds, the clock `NWAnimated` runs on).
    @State private var exhaleAt: Double?
    @State private var duskAt: Double?
    @State private var dawnAt: Double?
    /// The palette the sky was on when it started changing.
    @State private var fromPalette: NightWatch.AuroraPalette?

    private var orbSize: CGFloat { min(150, max(96, height - 112)) }
    private var pulseModel: PulseModel { model ?? pulse.defaultModel }
    private var isDusk: Bool { pulse == .dusk }
    private var bandY: CGFloat { topInset + 38 + orbSize + 4 }

    var body: some View {
        ZStack(alignment: .top) {
            // A pause that has settled is a still night: no clock.
            NWAnimated(active: !(isDusk && duskAt == nil)) { t in sky(t) }
            VStack(spacing: 6) {
                // The orb shrinks with a short Horizon so the headline never rides over it.
                NWAnimated(fps: orbFPS, active: orbActive) { t in orb(t) }
                    .frame(width: orbSize, height: orbSize)
                    .padding(.top, topInset + 38)
                Spacer(minLength: 0)
                Text(headline)
                    .font(NightWatch.Typo.hero)
                    .kerning(NightWatch.Typo.heroTracking)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .lineLimit(2)
                Text(subline)
                    .font(NightWatch.Typo.subline)
                    .foregroundColor(NightWatch.Palette.textSecondary.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.bottom, footnote == nil ? 14 : 0)
                if let footnote {
                    Text(footnote).font(NightWatch.Typo.subline)
                        .foregroundColor(NightWatch.Palette.textTertiary.color)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2).padding(.bottom, 14)
                }
            }
            .padding(.horizontal, NightWatch.Space.xl)
        }
        .frame(height: height + topInset)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(headline). \(subline)"))
        .accessibilityAddTraits(.isHeader)
        .onChange(of: pulseModel.mode) { old, new in
            guard !reduceMotion, PulseModel.exhales(from: old, to: new) else { return }
            exhaleAt = Date().timeIntervalSinceReferenceDate
        }
        .onChange(of: isDusk) { was, now in
            guard !reduceMotion else { return }
            let t = Date().timeIntervalSinceReferenceDate
            if now { duskAt = t; dawnAt = nil }
            else if was { dawnAt = t; duskAt = nil }
        }
        .onChange(of: palette) { old, _ in if old != .dusk { fromPalette = old } }
        // A one-shot ends: back to the still or steady frame, and its clock stops.
        .task(id: exhaleAt) {
            guard exhaleAt != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64(PulseModel.exhaleDuration * 1_000_000_000))
            if !Task.isCancelled { exhaleAt = nil }
        }
        .task(id: duskAt) {
            // Once the dusk has fallen the night is drawn settled, and its clock stops.
            guard duskAt != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64((DawnModel.duskDuration + 0.1) * 1_000_000_000))
            if !Task.isCancelled { duskAt = nil }
        }
        .task(id: dawnAt) {
            guard dawnAt != nil else { return }
            try? await Task.sleep(nanoseconds: UInt64((DawnModel.sweepDuration + DawnModel.settle) * 1_000_000_000))
            if !Task.isCancelled { dawnAt = nil }
        }
    }

    // MARK: the clock

    /// Seconds into a motion at clock time `t`: pinned by the harness, or
    /// since it began here; nil when it is not playing.
    private func elapsed(_ kind: NWMotionPin.Kind, since start: Double?, at t: Double) -> Double? {
        if let pin, pin.kind == kind { return pin.time }
        return start.map { max(0, t - $0) }
    }

    private var exhalePinned: Bool { pin?.kind == .exhale }
    private var orbActive: Bool { pulseModel.isAnimated || exhaleAt != nil }
    private var orbFPS: Double { exhaleAt != nil ? 30 : pulseModel.framesPerSecond }

    // MARK: sky

    private func sky(_ t: Double) -> some View {
        var pal = palette
        var stars = 1.0
        var band = 0.0
        var dawn: DawnModel.Dawn?
        if let e = elapsed(.exhale, since: exhaleAt, at: t) {
            let x = PulseModel.exhale(elapsed: e)
            if !x.finished { pal = NightWatch.AuroraPalette.needsYou.mixedPerceptual(with: palette, x.aurora) }
        }
        if isDusk {
            // A pause already under way when the Horizon appeared is drawn settled:
            // through the purple dusk to a near-black night, the stars all but gone.
            let d = DawnModel.dusk(elapsed: elapsed(.dusk, since: duskAt, at: t) ?? DawnModel.duskDuration)
            pal = (fromPalette ?? .working).towardNight(d.aurora)
            stars = DawnModel.starField(duskMix: d.aurora)
            band = d.band
        } else if let w = elapsed(.dawn, since: dawnAt, at: t) {
            let d = DawnModel.dawn(elapsed: w, lastRelight: nil)
            if !d.finished {
                // The night, through the gold of the sunrise, into the live palette.
                // The sweep carries the gold; the sky behind it only warms a little.
                let sunrise = NightWatch.AuroraPalette.night.mixed(with: .dawn, 0.35 * d.warmth)
                pal = sunrise.mixed(with: palette, 1 - d.aurora)
                stars = DawnModel.starField(duskMix: d.aurora)
                band = d.band
                dawn = d
            }
        }
        return ZStack(alignment: .top) {
            NWLivingAurora(palette: pal, seconds: t, stars: stars)
            if let dawn {
                NWDawnLight(sweep: dawn.sweep, warmth: dawn.warmth)
                    .frame(height: bandY)
            }
            // Fade into the page.
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: NightWatch.Palette.backgroundDeep.opacity(0.0).color, location: 0.35),
                                   .init(color: NightWatch.Palette.backgroundDeep.opacity(0.85).color, location: 0.88),
                                   .init(color: NightWatch.Palette.backgroundDeep.color, location: 1)],
                           startPoint: .top, endPoint: .bottom)
            // Over the fade, so the line holds at full strength (it is all a paused sky shows).
            NWHorizonBand(opacity: band)
                .offset(y: bandY - 6)
        }
    }

    // MARK: pulse

    @ViewBuilder private func orb(_ t: Double) -> some View {
        let e = elapsed(.exhale, since: exhaleAt, at: t).flatMap { PulseModel.exhale(elapsed: $0).finished && !exhalePinned ? nil : $0 }
        let hollow = pulse == .hollowSlate || pulse == .hollowAmber
        if NWShaders.available && !hollow && !reduceMotion {
            ZStack {
                NWPulseLight(color: NWPulseOrb.color(style: pulse, pulse: pulseModel, exhale: e),
                             ripples: Array((pulseModel.ripples(at: t) + farewell(e)).prefix(4)),
                             glow: glow(e, t), seconds: t)
                    .frame(width: orbSize * 1.3, height: orbSize * 1.3)
                NWPulseOrb(style: pulse, model: pulseModel, exhale: e, halo: false, time: t)
            }
        } else {
            NWPulseOrb(style: pulse, model: pulseModel, exhale: e, time: t)
        }
    }

    /// The exhale lets one last ring go as the pulse turns teal.
    private func farewell(_ exhale: Double?) -> [PulseModel.Ripple] {
        guard let e = exhale, e < PulseModel.exhaleDuration else { return [] }
        let p = MotionCurve.easeOut(e / PulseModel.exhaleDuration)
        return [PulseModel.Ripple(progress: p, opacity: 1 - p)]
    }

    /// The light behind the glyph: dim at dusk and when quiet, breathing
    /// while agents work, swelling once on the exhale.
    private func glow(_ exhale: Double?, _ t: Double) -> Double {
        let swell = exhale.map { PulseModel.exhale(elapsed: $0).swell } ?? 0
        switch pulseModel.mode {
        case .dusk: return 0.35
        case .quiet: return 0.7 + 0.5 * swell
        case .working: return 0.85 + 0.15 * pulseModel.breath(at: t) + 0.5 * swell
        case .waiting: return 1
        }
    }
}
