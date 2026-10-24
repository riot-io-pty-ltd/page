import SwiftUI

/// The brand mark. A glowing dot with two concentric asymmetric rings that
/// ripple outward while `pulsing`.
///
/// Driven by a TimelineView rather than a repeatForever animation, so it
/// stops cleanly the moment `pulsing` goes false (a repeating animation keeps
/// running after its trigger flips back) and stays still under Reduce Motion.
/// Purely decorative: hidden from VoiceOver; callers convey state in text.
struct PulseMark: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var size: CGFloat = 64
    /// Whether the mark should actively ripple. False = at-rest dot + faint rings.
    var pulsing: Bool = true

    private static let period: TimeInterval = 2.4

    var body: some View {
        let animate = pulsing && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { context in
            let phase = animate
                ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                : 0
            mark(phase: phase)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func mark(phase: Double) -> some View {
        let active = pulsing && !reduceMotion
        let middle = (phase + 0.35).truncatingRemainder(dividingBy: 1)
        return ZStack {
            // Outer ring (fades + scales)
            ringView(scale: 0.6 + CGFloat(phase) * 0.5,
                     opacity: max(0.0, (1.0 - phase) * (active ? 0.5 : 0.18)),
                     thickness: active ? 1.5 : 1)
            // Middle ring (offset phase for asymmetry)
            ringView(scale: 0.5 + CGFloat(middle) * 0.45,
                     opacity: max(0.0, (1.0 - middle) * (active ? 0.6 : 0.22)),
                     thickness: active ? 2 : 1)
            // Inner halo (soft glow)
            Circle()
                .fill(Theme.Colour.pulseGradient(scheme))
                .frame(width: size * 0.45, height: size * 0.45)
                .blur(radius: size * 0.12)
                .opacity(0.55)
            // Solid dot
            Circle()
                .fill(Theme.Colour.pulseGradient(scheme))
                .frame(width: size * 0.32, height: size * 0.32)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
                )
        }
    }

    private func ringView(scale: CGFloat, opacity: Double, thickness: CGFloat) -> some View {
        Circle()
            .stroke(Theme.Colour.pulseGradient(scheme), lineWidth: thickness)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .opacity(opacity)
    }
}
