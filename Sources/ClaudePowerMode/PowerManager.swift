import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

struct PowerSnapshot: Equatable {
    /// Charge percentage, or -1 when the Mac has no battery (Mac mini,
    /// Studio, iMac without a UPS). -1 is also what the heartbeat sends.
    let percent: Int
    let onAC: Bool
    /// False on desktops: no battery line in the menu, and the low-battery
    /// lockout never trips.
    let hasBattery: Bool
    let isCharging: Bool

    static let noBattery = PowerSnapshot(percent: -1, onAC: true, hasBattery: false, isCharging: false)

    /// Picks the source that represents "this Mac's battery" from the IOPS
    /// source descriptions. Pure so it can be tested with plain dictionaries.
    ///
    /// The internal battery wins. A UPS is used only when there is no
    /// internal battery: on a desktop the UPS is the thing that runs out, so
    /// the lockout should follow it. (The old code took whichever source was
    /// listed first, so a USB UPS could drive a laptop's lockout.)
    static func from(descriptions: [[String: Any]]) -> PowerSnapshot {
        func isType(_ desc: [String: Any], _ type: String) -> Bool {
            (desc[kIOPSTypeKey as String] as? String) == type
        }
        let present = descriptions.filter { ($0[kIOPSIsPresentKey as String] as? Bool) ?? true }
        let chosen = present.first { isType($0, kIOPSInternalBatteryType) }
            ?? present.first { isType($0, kIOPSUPSType) }
        guard let desc = chosen else { return .noBattery }

        let current = desc[kIOPSCurrentCapacityKey as String] as? Int
        let max = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
        let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? kIOPSACPowerValue
        guard let current else { return .noBattery }
        let pct = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        return PowerSnapshot(
            percent: Swift.min(100, Swift.max(0, pct)),
            onAC: state == kIOPSACPowerValue,
            hasBattery: true,
            isCharging: (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
        )
    }
}

/// Smooths over a transient "no battery" reading on a Mac that has a
/// battery. IOPS can fail, or list the internal battery without a charge,
/// for a moment around wake or a power-source change; `snapshot()` then
/// reads as a desktop on AC. Taken at face value that counts as low-battery
/// recovery (pages closed, "Power is back" typed into paused sessions on a
/// nearly flat battery, then a re-trip) and clears lid-closed-on-battery.
/// So the last battery reading stands in until `readingsToTrust` no-battery
/// readings in a row (about 45 s at the 15 s cadence) say the battery — on a
/// desktop, its UPS — really is gone. Never persisted.
struct PowerReadingFilter {
    static let readingsToTrust = 3

    private(set) var lastBattery: PowerSnapshot?
    private(set) var missingStreak = 0

    mutating func filter(_ p: PowerSnapshot) -> PowerSnapshot {
        if p.hasBattery {
            lastBattery = p
            missingStreak = 0
            return p
        }
        guard let last = lastBattery else { return p }
        missingStreak += 1
        guard missingStreak >= Self.readingsToTrust else { return last }
        lastBattery = nil
        missingStreak = 0
        return p
    }
}

/// Which keep-awake assertions Page holds. Pure value so the plan is
/// testable and the menu can say exactly what's in force.
struct AwakeAssertions: Equatable {
    /// `PreventUserIdleSystemSleep`: stops idle sleep. Held whenever agents
    /// are working, on AC or battery.
    var preventIdleSleep: Bool
    /// `PreventSystemSleep`: additionally keeps the Mac awake with the lid
    /// closed. macOS honours it on AC only, so it's only taken there.
    var preventSystemSleep: Bool

    static let none = AwakeAssertions(preventIdleSleep: false, preventSystemSleep: false)

    var any: Bool { preventIdleSleep || preventSystemSleep }

    /// What to hold this tick. On battery `PreventSystemSleep` is released:
    /// the system ignores it there, and the menu shouldn't claim the lid can
    /// be closed (that's the separate, opt-in `SleepGuard`).
    static func plan(boost: Bool, power: PowerSnapshot, lidClosedOnAC: Bool) -> AwakeAssertions {
        guard boost else { return .none }
        return AwakeAssertions(preventIdleSleep: true, preventSystemSleep: lidClosedOnAC && power.onAC)
    }
}

/// Holds and releases the keep-awake assertions.
///
/// `PreventUserIdleSystemSleep` stops idle sleep only. With
/// `keepAwakeLidClosedOnAC` Page also holds `PreventSystemSleep` while on
/// AC, which keeps a closed laptop awake. On battery no assertion survives
/// closing the lid; that needs the opt-in `SleepGuard` (pmset disablesleep).
/// The menu says which case applies; keep README copy consistent.
final class PowerManager {
    private let lock = NSLock()
    private var idleID: IOPMAssertionID = 0
    private var systemID: IOPMAssertionID = 0
    private var _held = AwakeAssertions.none

    /// What is actually held (an assertion that failed to create is false).
    var held: AwakeAssertions {
        lock.lock(); defer { lock.unlock() }
        return _held
    }

    var isBoosting: Bool { held.preventIdleSleep }

    func snapshot() -> PowerSnapshot {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return .noBattery
        }
        let descriptions: [[String: Any]] = list.compactMap { src in
            IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any]
        }
        return PowerSnapshot.from(descriptions: descriptions)
    }

    /// Reconciles the held assertions with `want`, creating or releasing
    /// each one independently (so plugging in mid-run adds the lid-closed
    /// assertion without dropping the idle one). Idempotent; call every
    /// tick. Thread-safe: the tick queue and app shutdown can both call it.
    func apply(_ want: AwakeAssertions, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        let before = _held
        reconcile(kIOPMAssertionTypePreventUserIdleSystemSleep, want: want.preventIdleSleep,
                  held: &_held.preventIdleSleep, id: &idleID, reason: reason)
        reconcile(kIOPMAssertionTypePreventSystemSleep, want: want.preventSystemSleep,
                  held: &_held.preventSystemSleep, id: &systemID, reason: reason + " — lid may be closed on AC")
        guard _held != before else { return }
        switch (_held.preventIdleSleep, _held.preventSystemSleep) {
        case (false, false): Logger.shared.log("Keep-awake OFF")
        case (true, true): Logger.shared.log("Keep-awake ON (idle + lid closed on AC) — \(reason)")
        case (true, false): Logger.shared.log("Keep-awake ON (idle only; keep the lid open) — \(reason)")
        case (false, true): Logger.shared.log("Keep-awake: lid-closed assertion only — \(reason)")
        }
    }

    /// Releases everything (quit, battery drained).
    func releaseAll() { apply(.none, reason: "release") }

    private func reconcile(_ type: String, want: Bool, held: inout Bool, id: inout IOPMAssertionID, reason: String) {
        if want && !held {
            var newID: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &newID
            )
            if result == kIOReturnSuccess {
                id = newID
                held = true
            } else {
                Logger.shared.log("IOPMAssertionCreateWithName(\(type)) failed: \(result)")
            }
        } else if !want && held {
            IOPMAssertionRelease(id)
            id = 0
            held = false
        }
    }
}

/// Low-battery lockout hysteresis, as a single bool. Kept for callers that
/// only need "is the lockout engaged"; the full behaviour (pausing agents,
/// grace period, recovery) is `BatteryPolicy`, which uses the same rules.
enum LockoutPolicy {
    /// Returns whether the lockout should be engaged after this reading.
    /// - Desktops (no battery) never lock out.
    /// - Trips only while running on battery, at or below the cutoff: a
    ///   laptop plugged in at 8% is charging, and dropping the no-sleep
    ///   assertion there would let it idle-sleep mid-run for no benefit.
    /// - Clears once the charge reaches the recovery threshold (and, if
    ///   configured, only while on AC).
    static func nextTripped(current tripped: Bool, power p: PowerSnapshot,
                            cutoff: Int, recovery: Int, recoveryRequiresAC: Bool) -> Bool {
        guard p.hasBattery else { return false }
        if tripped {
            let s = BatteryPolicy.Settings(cutoff: cutoff, recovery: recovery, recoveryRequiresAC: recoveryRequiresAC,
                                           action: .off, graceSeconds: 0, resumeAfterRecovery: false)
            return !BatteryPolicy.hasRecovered(p, s)
        }
        return BatteryPolicy.shouldTrip(p, cutoff: cutoff)
    }
}
