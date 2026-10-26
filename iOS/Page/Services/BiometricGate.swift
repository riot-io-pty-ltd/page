import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// The Face ID / Touch ID / passcode check behind the two deliberate
/// actions: an Irreversible approve and Stop-all. It only answers "did the
/// owner confirm"; what happens next goes through the existing services.
/// The owner-authentication policy lets the device passcode stand in when
/// biometrics fail or are not enrolled.
enum BiometricGate {
    enum Outcome: Equatable {
        case passed
        /// The owner cancelled or failed the check: nothing is sent.
        case cancelled
        /// This device has no passcode or biometrics to check against.
        case unavailable(String)
    }

    /// `methodName()`, asked once per launch: views read it on every render.
    static let displayName: String = methodName()

    /// "Face ID", "Touch ID" or "passcode", for the line under the hold ring.
    static func methodName() -> String {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return "passcode" }
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        default: return "passcode"
        }
        #else
        return "passcode"
        #endif
    }

    /// Asks the owner to confirm. `reason` names the scope ("Stop 4 busy
    /// sessions"), because the sheet is the last thing they read.
    static func confirm(reason: String) async -> Outcome {
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable("Set a passcode on this iPhone to confirm this.")
        }
        do {
            let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .passed : .cancelled
        } catch {
            return .cancelled
        }
        #else
        return .unavailable("Confirmation isn't available here.")
        #endif
    }
}
