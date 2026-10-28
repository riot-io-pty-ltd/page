import SwiftUI

/// The frame of the app: the night sky behind, Now or Lanes in front (Lanes lies
/// to the right of Now, and they slide as one), the floating capsule at
/// the bottom, and the Stop ring over everything while the pulse is held.
/// Pure: the live container and the render harness both fill it in.
struct NWShell<NowContent: View, LanesContent: View>: View {
    @Binding var destination: NWDestination
    var decideCount: Int
    var workingCount: Int
    /// The capsule pulse's count (`NowModel.pulseWaiting`); the Decide count when nil.
    var pulseWaiting: Int? = nil
    /// The oldest wait among them (the ripple's pace).
    var pulseLongestWait: TimeInterval = 0
    var stop: StopFlowPhase = .idle
    var stopPlan: StopPlan
    var biometry = "Face ID"
    @Binding var held: TimeInterval?
    var onPulseTap: () -> Void = {}
    var onPulseHold: () -> Void = {}
    @ViewBuilder var now: () -> NowContent
    @ViewBuilder var lanes: () -> LanesContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            NWBackdrop()
            ZStack {
                // A third of the width, fading: the arriving one in over the whole 320 ms, the leaving one out in 200.
                if destination == .now {
                    now().transition(reduceMotion ? .opacity : Self.slide(thirds: -1))
                } else {
                    lanes().transition(reduceMotion ? .opacity : Self.slide(thirds: 1))
                }
            }
            // Android's tween(320): fast out, slow in.
            .animation(reduceMotion ? nil : .timingCurve(0.4, 0, 0.2, 1, duration: 0.32), value: destination)
            NWNavCapsule(selection: Binding(get: { destination == .now ? .now : .lanes },
                                            set: { destination = $0 == .now ? .now : .lanes }),
                         decideCount: decideCount, workingCount: workingCount, pulseWaiting: pulseWaiting,
                         pulseLongestWait: pulseLongestWait, held: $held,
                         onPulseTap: onPulseTap, onPulseHold: onPulseHold)
                .padding(.horizontal, NightWatch.Space.gutter)
                .padding(.bottom, 8)
            NWStopOverlay(phase: shownStop, plan: stopPlan, biometry: biometry)
        }
        .animation(.easeOut(duration: 0.15), value: shownStop.isActive)
    }

    /// Now sits a third of the width to the left (-1), Lanes a third to the
    /// right (1), whichever way the change goes.
    private static func slide(thirds: CGFloat) -> AnyTransition {
        let shift = AnyTransition.modifier(active: NWThirdSlide(thirds: thirds), identity: NWThirdSlide(thirds: 0))
        return .asymmetric(insertion: shift.combined(with: .opacity),
                           removal: shift.combined(with: .opacity.animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.2))))
    }

    /// While the pulse is held past its dead zone and no Stop flow is running,
    /// the ring follows the hold.
    private var shownStop: StopFlowPhase {
        if stop.isActive { return stop }
        if let h = held, HoldRingSpec.stopAll.isVisible(elapsed: h) { return .holding(progress: HoldRingSpec.stopAll.progress(elapsed: h)) }
        return .idle
    }
}

/// Moves a view sideways by thirds of its own width (the destination slide).
/// A geometry effect, so it knows the width without a GeometryReader and
/// animates as one number.
private struct NWThirdSlide: GeometryEffect {
    var thirds: CGFloat

    var animatableData: CGFloat {
        get { thirds }
        set { thirds = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: thirds * size.width / 3, y: 0))
    }
}
