import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

struct PowerSnapshot {
    let percent: Int
    let onAC: Bool
}

final class PowerManager {
    private var assertionID: IOPMAssertionID = 0
    private(set) var isBoosting = false

    func snapshot() -> PowerSnapshot {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sourcesArr = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as Array
        for src in sourcesArr {
            guard let desc = IOPSGetPowerSourceDescription(blob, src)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let current = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let max = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? kIOPSACPowerValue
            let pct = max > 0 ? Int((Double(current) / Double(max)) * 100.0) : 100
            return PowerSnapshot(percent: pct, onAC: state == kIOPSACPowerValue)
        }
        return PowerSnapshot(percent: 100, onAC: true)
    }

    func setBoost(_ on: Bool, reason: String) {
        if on && !isBoosting {
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &assertionID
            )
            if result == kIOReturnSuccess {
                isBoosting = true
                Logger.shared.log("Boost ON — \(reason)")
            } else {
                Logger.shared.log("IOPMAssertionCreateWithName failed: \(result)")
            }
        } else if !on && isBoosting {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isBoosting = false
            Logger.shared.log("Boost OFF")
        }
    }
}
