import Foundation

// The pulse: one verb. A tap starts Dispatch; a long press is the Stop ring.
// These are the pure decisions behind it. The hold ring itself is
// `HoldRingSpec.stopAll` (300 ms dead zone, 1.2 s fill, ticks at 25/50/75% and
// a firm one at full, then biometrics); this adds what a press means and what
// Stop-all will do.

/// What a press on the pulse means, judged by how long it was held.
enum PulsePress: Equatable {
    /// Released inside the dead zone: a tap, which opens Dispatch.
    case tap
    /// Held past the dead zone but let go before the ring filled: the ring
    /// unwinds, nothing is sent, and Dispatch does not open either.
    case abandonedHold
    /// The ring filled: ask for Face ID / Touch ID / passcode next.
    case completedHold

    /// The outcome of a press released after `held` seconds. Pure.
    static func onRelease(held: TimeInterval, spec: HoldRingSpec = .stopAll) -> PulsePress {
        if spec.isComplete(elapsed: held) { return .completedHold }
        return spec.isVisible(elapsed: held) ? .abandonedHold : .tap
    }
}

/// What Stop-all will do right now: press Esc in every busy session. The
/// scope is named on the ring and again in the biometric sheet, so a mis-hold
/// costs two deliberate steps. With nothing busy, nothing can be sent.
struct StopPlan: Equatable {
    /// Sessions the Mac reports as working (Esc interrupts a turn).
    let busy: Int
    /// "Press Esc in 4 busy sessions on Studio MBP".
    let scope: String
    /// The reason shown in the biometric sheet.
    let biometricReason: String
    /// Nothing busy, or the Mac cannot be reached: the ring says so instead of arming.
    let canStop: Bool
    /// Why Stop is unavailable, when it is.
    let blocker: String?
    /// Names of up to three busy sessions, for the confirmation ("bottle-flip, relay, +2").
    let names: String

    static func build(sessions: [LiveSession], hasSessionList: Bool, workingFromStatus: Int? = nil, macName: String = "") -> StopPlan {
        let busy = sessions.filter { $0.state == .active }
        // Before the list arrives, the heartbeat's working count is the only
        // scope there is, and Stop-all still reaches them.
        let count = hasSessionList ? busy.count : (workingFromStatus ?? 0)
        var names = busy.prefix(3).map(\.title).joined(separator: ", ")
        if busy.count > 3 { names += ", +\(busy.count - 3)" }
        return StopPlan(
            busy: count, scope: HoldRingSpec.stopScope(busy: count, mac: macName),
            biometricReason: HoldRingSpec.biometricReason(stopping: count, mac: macName),
            canStop: count > 0, blocker: count > 0 ? nil : "Nothing is working right now", names: names)
    }
}

/// The result of a Stop-all, in words.
enum StopOutcome: Equatable {
    case asked
    case nothingBusy
    case cancelled
    case unavailable(String)
    case failed(String)

    var message: String {
        switch self {
        case .asked: return "Asked your Mac to stop your working agents."
        case .nothingBusy: return "Nothing was working, so nothing was sent."
        case .cancelled: return "Cancelled. Nothing was sent."
        case .unavailable(let why): return why
        case .failed(let why): return why
        }
    }

    /// Only a send the relay accepted is "asked"; the Mac's own answer comes later.
    var isSuccess: Bool { self == .asked }
}

/// What the Stop overlay is showing. The ring appears after 300 ms, fills over
/// 1.2 s, then Face ID / Touch ID / passcode asks, naming the scope.
enum StopFlowPhase: Equatable {
    case idle
    /// The ring is drawn, 0...1.
    case holding(progress: Double)
    /// The ring filled; the owner is being asked.
    case authenticating
    case sending
    case result(StopOutcome)

    var isActive: Bool { self != .idle }
}
