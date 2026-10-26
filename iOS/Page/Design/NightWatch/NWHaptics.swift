import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Haptic ticks for the hold ring and commits. A no-op where there is no
/// Taptic Engine (the simulator, the macOS proxy renderer).
@MainActor
enum NWHaptics {
    /// A tick at 33% and 66% of a hold.
    static func tick() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// The ring is full: a firmer tap, just before biometrics.
    static func full() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }

    /// A confirmed delivery.
    static func delivered() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// An outcome that is not a confirmed delivery.
    static func refused() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}
