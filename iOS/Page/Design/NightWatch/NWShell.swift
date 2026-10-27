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
                if destination == .now {
                    now().transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
                } else {
                    lanes().transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: destination)
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

    /// While the pulse is held past its dead zone and no Stop flow is running,
    /// the ring follows the hold.
    private var shownStop: StopFlowPhase {
        if stop.isActive { return stop }
        if let h = held, HoldRingSpec.stopAll.isVisible(elapsed: h) { return .holding(progress: HoldRingSpec.stopAll.progress(elapsed: h)) }
        return .idle
    }
}
