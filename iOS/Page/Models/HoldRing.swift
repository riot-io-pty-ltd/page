import Foundation

/// The press-and-hold ring that commits the two deliberate actions: an
/// Irreversible approve and Stop-all (the pulse's long press). Pure timing and
/// copy, so the views only draw it and the tests drive it with elapsed times.
///
/// Trust model: the ring fills clockwise, amber warming to red only in its
/// final third, with haptic ticks at 33%, 66% and 100%, then biometrics.
/// Letting go early unwinds the ring and nothing is sent.
struct HoldRingSpec: Equatable {
    /// Nothing happens (and nothing is drawn) for this long, so a slow tap
    /// never starts a ring.
    let deadZone: TimeInterval
    /// Time to fill from empty to full once the dead zone has passed.
    let fill: TimeInterval

    /// Hold the pulse: appears after 300 ms, fills over 1.5 s.
    static let stopAll = HoldRingSpec(deadZone: 0.3, fill: 1.5)
    /// Hold to approve an Irreversible action: fills over 1.2 s.
    static let irreversible = HoldRingSpec(deadZone: 0, fill: 1.2)

    /// Where the haptic ticks fall.
    static let ticks: [Double] = [1.0 / 3.0, 2.0 / 3.0, 1.0]

    /// Progress 0...1 after holding for `elapsed`. Pure.
    func progress(elapsed: TimeInterval) -> Double {
        guard elapsed > deadZone else { return 0 }
        return min(1, (elapsed - deadZone) / fill)
    }

    /// True once the ring is drawn at all.
    func isVisible(elapsed: TimeInterval) -> Bool { elapsed > deadZone }

    func isComplete(elapsed: TimeInterval) -> Bool { elapsed >= deadZone + fill }

    /// The ticks passed between two progress values (rising only).
    static func ticksCrossed(from: Double, to: Double) -> [Double] {
        guard to > from else { return [] }
        return ticks.filter { from < $0 - 1e-9 && to >= $0 - 1e-9 }
    }

    /// 0 = amber ... 1 = red. Red only in the final third. Pure.
    static func warmth(progress p: Double) -> Double {
        max(0, min(1, (p - 2.0 / 3.0) * 3))
    }

    /// Progress while the ring unwinds after an early release: it runs back
    /// at the speed it filled. `released` is the progress at release. Pure.
    func unwound(from released: Double, since: TimeInterval) -> Double {
        max(0, released - since / fill)
    }

    // MARK: copy

    /// The line under the ring: "Keep holding · Face ID next".
    static func prompt(progress p: Double, biometry: String) -> String {
        if p >= 1 { return "\(biometry) next" }
        if p > 0 { return "Keep holding · \(biometry) next" }
        return "Hold to confirm"
    }

    /// The scope Stop-all names before biometrics: "Press Esc in 4 busy sessions".
    static func stopScope(busy: Int) -> String {
        switch busy {
        case ...0: return "No busy sessions to stop"
        case 1: return "Press Esc in 1 busy session"
        default: return "Press Esc in \(busy) busy sessions"
        }
    }

    /// The same scope, naming the Mac it will act on: "Press Esc in 4 busy
    /// sessions on Studio MBP". With nothing busy there is no Mac to name.
    static func stopScope(busy: Int, mac: String) -> String {
        busy > 0 ? "\(stopScope(busy: busy)) on \(DeliveryPreview.macLabel(mac))" : stopScope(busy: busy)
    }

    /// The reason shown in the biometric sheet: it names the scope and the
    /// Mac, and says what will be pressed.
    static func biometricReason(stopping busy: Int, mac: String) -> String {
        "Stop \(busy) busy session\(busy == 1 ? "" : "s") on \(DeliveryPreview.macLabel(mac)). Presses Esc in each."
    }
    static func biometricReason(approving subject: String, mac: String) -> String {
        "Approve \(subject) on \(DeliveryPreview.macLabel(mac))"
    }
}
