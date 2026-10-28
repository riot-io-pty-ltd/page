import Foundation

/// The press-and-hold ring that commits the two deliberate actions: an
/// Irreversible approve and Stop-all (the pulse's long press). Pure timing and
/// copy, so the views only draw it and the tests drive it with elapsed times.
///
/// Trust model (board 07, "The hold ring"): nothing is drawn for 300 ms, then
/// the ring fills clockwise over 1.2 s, amber warming to red only in its
/// final third, with haptic ticks at 25%, 50% and 75% and a firmer one when
/// full; then biometrics, and a burst once they pass. Letting go early
/// unwinds the ring backwards and nothing is sent. (The spec's prose says
/// ticks at 33/66/100%; the board's 25/50/75% wins, with 100% kept as the
/// completion haptic.)
struct HoldRingSpec: Equatable {
    /// Nothing happens (and nothing is drawn) for this long, so a slow tap
    /// never starts a ring.
    let deadZone: TimeInterval
    /// Time to fill from empty to full once the dead zone has passed.
    let fill: TimeInterval

    /// Hold the pulse (Stop-all): appears after 300 ms, fills over 9.7 s, full
    /// at 10 s. Esc in every session is never something to do by accident.
    static let stopAll = HoldRingSpec(deadZone: 0.3, fill: 9.7)
    /// Hold to approve an Irreversible action: the same ring, the same timing.
    static let irreversible = HoldRingSpec(deadZone: 0.3, fill: 1.2)

    /// Where the haptic ticks fall: 25%, 50%, 75%, and the full one at 100%.
    static let ticks: [Double] = [0.25, 0.5, 0.75, 1.0]

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
    /// at the speed it filled, but never slower than an empty-to-full in
    /// `maxUnwind` (a 10 s Stop ring lets go in about a second, not ten).
    /// `released` is the progress at release. Pure.
    func unwound(from released: Double, since: TimeInterval) -> Double {
        max(0, released - since / min(fill, Self.maxUnwind))
    }

    /// The longest an unwind from full takes.
    static let maxUnwind: TimeInterval = 1.2

    // MARK: the burst

    /// How long the burst lasts once biometrics pass.
    static let burstDuration: TimeInterval = 0.6

    /// The burst after biometrics pass, `elapsed` seconds in: a ring of light
    /// leaves the full ring and opens out (scale 1 ... 1.45) as it fades, and
    /// the core flashes once. It means "committed, sending", never
    /// "delivered": the receipt thread says that. Pure.
    static func burst(elapsed t: TimeInterval) -> (scale: Double, opacity: Double, flash: Double) {
        guard t >= 0, t < burstDuration else { return (1, 0, 0) }
        let x = t / burstDuration
        let flash = x < 0.25 ? MotionCurve.smooth(x / 0.25) : 1 - MotionCurve.smooth((x - 0.25) / 0.75)
        return (1 + 0.45 * MotionCurve.easeOut(x), 0.9 * (1 - MotionCurve.easeIn(x)), flash)
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
