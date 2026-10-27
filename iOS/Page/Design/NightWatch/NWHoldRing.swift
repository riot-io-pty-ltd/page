import SwiftUI

/// Tracks a press-and-hold against a `HoldRingSpec` and hands the progress to
/// its content. Fills as the finger stays down, ticks the haptics at 25%,
/// 50% and 75% and firmly when full, calls `onComplete` once (the caller then asks
/// for Face ID / Touch ID / passcode), and unwinds backwards on an early
/// release with nothing sent. Under Reduce Motion the unwind is instant.
/// `held` (optional) reports the seconds held while pressed, nil otherwise,
/// for a caller that needs the elapsed time (the pulse tells a tap from a hold).
struct NWHoldSurface<Content: View>: View {
    var spec: HoldRingSpec
    /// Draws this progress instead of tracking a press (the render harness).
    var fixedProgress: Double? = nil
    var held: Binding<TimeInterval?>? = nil
    var onComplete: () -> Void
    /// Released before the dead zone ended: a tap.
    var onTap: (() -> Void)? = nil
    @ViewBuilder var content: (Double) -> Content

    @State private var progress = 0.0
    @State private var pressStart: Date?
    @State private var completed = false
    @State private var driver: Task<Void, Never>?
    /// True while a finger is down. A `GestureState` resets itself when the
    /// system cancels the touch (a scroll view takes it, a call comes in), a
    /// case `onEnded` never sees, so a cancelled hold cannot keep filling.
    @GestureState private var fingerDown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Double { fixedProgress ?? progress }

    var body: some View {
        content(shown)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($fingerDown) { _, down, _ in down = true }
                .onChanged { _ in if pressStart == nil, fixedProgress == nil { begin() } }
                .onEnded { _ in end() })
            .onChange(of: fingerDown) { _, down in
                // Cancelled, not lifted: unwind with nothing sent and no tap.
                // A normal lift runs `onEnded` too, so give it the first go.
                if !down, pressStart != nil {
                    Task { @MainActor in
                        await Task.yield()
                        if pressStart != nil { end(cancelled: true) }
                    }
                }
            }
            .onDisappear { driver?.cancel(); held?.wrappedValue = nil }
    }

    private func begin() {
        guard !completed else { return }
        let start = Date()
        pressStart = start
        var last = 0.0
        driver?.cancel()
        driver = Task { @MainActor in
            while !Task.isCancelled, let start = pressStart {
                let elapsed = Date().timeIntervalSince(start)
                let p = spec.progress(elapsed: elapsed)
                for t in HoldRingSpec.ticksCrossed(from: last, to: p) { t >= 1 ? NWHaptics.full() : NWHaptics.tick() }
                last = p
                progress = p
                held?.wrappedValue = elapsed
                if spec.isComplete(elapsed: elapsed) {
                    completed = true
                    pressStart = nil
                    onComplete()
                    // Ready again for the next time (after biometrics).
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    completed = false
                    progress = 0
                    held?.wrappedValue = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
        }
    }

    private func end(cancelled: Bool = false) {
        guard let start = pressStart, !completed else { return }
        let elapsed = Date().timeIntervalSince(start)
        pressStart = nil
        driver?.cancel()
        held?.wrappedValue = nil
        if !spec.isVisible(elapsed: elapsed) {
            // A tap, not a hold (a cancelled touch is neither).
            progress = 0
            if !cancelled { onTap?() }
            return
        }
        let from = progress
        // Back the way it came, at the speed it filled; nothing was sent.
        if reduceMotion || from <= 0 { progress = 0 }
        else { withAnimation(.linear(duration: from * spec.fill)) { progress = 0 } }
    }
}

/// The big press-and-hold ring (`HoldRingSpec` for the timing), board 07's
/// "hold ring": the red button alone at first; after 300 ms a ring appears
/// and fills clockwise over 1.2 s, amber warming to red only in its final
/// third, with haptic ticks at 25%, 50% and 75% (firm at 100%); full, the
/// core turns to Face ID; once biometrics pass (`burstStart`), a burst of
/// light leaves the ring. The burst means committed, never delivered: the
/// Receipt thread below says that. Letting go early unwinds the ring
/// backwards. VoiceOver users get a "Confirm" action instead of a hold (the
/// biometric check still follows).
struct NWHoldRing: View {
    var spec: HoldRingSpec
    /// Shown in the core when the ring is full (the biometric next).
    var symbol = "faceid"
    /// Shown in the core while holding.
    var holdSymbol = "hand.raised"
    var size: CGFloat = 132
    /// Draws this progress instead of tracking a press (the render harness).
    var fixedProgress: Double? = nil
    /// Biometrics passed at this moment: the burst plays and the ring stays full.
    var burstStart: Date? = nil
    var onComplete: () -> Void

    @Environment(\.nwMotion) private var pin

    var body: some View {
        NWHoldSurface(spec: spec, fixedProgress: burstStart != nil ? 1 : fixedProgress, onComplete: onComplete) { shown in
            ZStack {
                ringBody(shown)
                if burstStart != nil || pin?.kind == .hold {
                    NWOneShot(start: burstStart?.timeIntervalSinceReferenceDate, duration: HoldRingSpec.burstDuration,
                              pinned: pin.flatMap { $0.kind == .hold ? $0.time : nil }) { e in
                        burst(e.map { HoldRingSpec.burst(elapsed: $0) } ?? (1, 0, 0))
                    }
                }
            }
        }
        .frame(width: size + 20, height: size + 20)
        .allowsHitTesting(burstStart == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(burstStart == nil ? "Hold to confirm" : "Confirmed"))
        .accessibilityHint(Text(burstStart == nil ? "Then confirm with your device" : ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Confirm")) { if burstStart == nil { onComplete() } }
    }

    private func ringBody(_ shown: Double) -> some View {
        let warmth = HoldRingSpec.warmth(progress: shown)
        let tone = NightWatch.Palette.amber.mixed(with: NightWatch.Palette.red, warmth)
        let full = shown >= 1
        // Red is the class colour of the button; green-teal once it is full and biometrics are next.
        let core = full ? NightWatch.Palette.green.mixed(with: NightWatch.Palette.teal, 0.25) : NightWatch.Palette.red
        return ZStack {
            // The track appears only once the ring does (after the dead zone).
            Circle().stroke(Color.white.opacity(shown > 0 ? 0.08 : 0), lineWidth: 14)
                .frame(width: size, height: size)
            Circle()
                .trim(from: 0, to: CGFloat(shown))
                .stroke(tone.color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: size, height: size)
                .shadow(color: tone.opacity((full ? 0.75 : 0.5) * shown).color, radius: full ? 16 : 10)
            Circle()
                .fill(RadialGradient(colors: [core.opacity(0.98).color, core.opacity(0.82).color],
                                     center: .center, startRadius: 0, endRadius: size * 0.36))
                .frame(width: size * 0.62, height: size * 0.62)
                .scaleEffect(1 + 0.04 * shown)
                .shadow(color: core.opacity(full ? 0.5 : 0.25).color, radius: full ? 14 : 8)
            Image(systemName: full ? symbol : holdSymbol)
                .font(.system(size: size * 0.24, weight: .regular))
                .foregroundColor(NightWatch.Palette.onBright.color)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: size + 20, height: size + 20)
    }

    /// The burst: a ring of light leaves the full ring and opens as it fades;
    /// the core flashes once.
    private func burst(_ b: (scale: Double, opacity: Double, flash: Double)) -> some View {
        ZStack {
            Circle().stroke(NightWatch.Palette.red.mixed(with: .init(1, 1, 1), 0.3).opacity(b.opacity).color, lineWidth: 6)
                .frame(width: size, height: size)
                .scaleEffect(b.scale)
                .blur(radius: 1.5)
            Circle().fill(Color.white.opacity(0.35 * b.flash))
                .frame(width: size * 0.62, height: size * 0.62)
                .blur(radius: 6)
        }
        .allowsHitTesting(false)
    }
}

/// "Hold to approve" as a button on a card: a small ring fills beside the
/// label while the finger stays down (an Irreversible approve is 1.2 s, then
/// Face ID / Touch ID / passcode). A tap does nothing but say how to use it.
struct NWHoldButton: View {
    var label = "Hold to approve"
    var fixedProgress: Double? = nil
    var onComplete: () -> Void

    var body: some View {
        NWHoldSurface(spec: .irreversible, fixedProgress: fixedProgress, onComplete: onComplete) { p in
            let tone = NightWatch.Palette.amber.mixed(with: NightWatch.Palette.red, HoldRingSpec.warmth(progress: p))
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(NightWatch.Palette.red.opacity(0.3).color, lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(max(0.02, p)))
                        .stroke(p > 0 ? tone.color : NightWatch.Palette.red.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 24, height: 24)
                Text(label)
                    .font(NightWatch.Typo.button)
                    .foregroundColor(NightWatch.Palette.textPrimary.color)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous)
                .fill(NightWatch.Palette.red.opacity(0.14 + 0.10 * p).color))
            .overlay(RoundedRectangle(cornerRadius: NightWatch.Radius.button, style: .continuous)
                .strokeBorder(NightWatch.Palette.red.opacity(0.45).color, lineWidth: 1))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityHint(Text("Hold, then confirm with your device"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Confirm")) { onComplete() }
    }
}
