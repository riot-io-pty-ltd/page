import SwiftUI

/// The brand mark. A glowing dot with two-to-three concentric asymmetric rings
/// that ripple outward. Animates whenever a new page lands.
///
/// Used as the logo, in the menu tab icon, on the lock-screen notification,
/// and as the hero on the Welcome screen.
struct PulseMark: View {
    @Environment(\.colorScheme) private var scheme

    var size: CGFloat = 64
    /// Whether the mark should actively ripple. False = at-rest dot + faint rings.
    var pulsing: Bool = true

    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            // Outer ring (fades + scales)
            ringView(scale: 0.6 + phase * 0.5,
                     opacity: max(0, (1 - phase) * (pulsing ? 0.5 : 0.18)),
                     thickness: pulsing ? 1.5 : 1)
            // Middle ring (offset phase for asymmetry)
            ringView(scale: 0.5 + ((phase + 0.35).truncatingRemainder(dividingBy: 1)) * 0.45,
                     opacity: max(0, (1 - ((phase + 0.35).truncatingRemainder(dividingBy: 1))) * (pulsing ? 0.6 : 0.22)),
                     thickness: pulsing ? 2 : 1)
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
        .frame(width: size, height: size)
        .onAppear { startAnimating() }
        .onChange(of: pulsing) { _, newValue in
            if newValue { startAnimating() }
        }
    }

    private func ringView(scale: CGFloat, opacity: Double, thickness: CGFloat) -> some View {
        Circle()
            .stroke(Theme.Colour.pulseGradient(scheme), lineWidth: thickness)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .opacity(opacity)
    }

    private func startAnimating() {
        guard pulsing else { return }
        withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) {
            phase = 1
        }
    }
}
