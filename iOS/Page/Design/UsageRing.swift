import SwiftUI

/// One usage window as a ring: a gradient arc for how much is used, a faint
/// track, and a small tick where usage would be at an even pace through
/// the window. Shared by the Sessions card and the widget.
struct UsageRing: View {
    let gauge: UsageGauge
    var lineWidth: CGFloat = 10
    /// Draw the percentage in the middle.
    var showsValue = true
    var valueFont: Font = .system(size: 26, weight: .bold, design: .rounded)

    static func color(_ tone: UsageGauge.Tone) -> Color {
        switch tone {
        case .calm: return Theme.Colour.success
        case .warm: return Theme.Colour.warning
        case .hot: return Theme.Colour.destructiveText
        }
    }

    var body: some View {
        let tint = Self.color(gauge.tone)
        ZStack {
            Circle()
                .stroke(Theme.Colour.hairline.opacity(0.9), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.005, gauge.fraction))
                .stroke(AngularGradient(colors: [tint.opacity(0.45), tint],
                                        center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(360 * max(0.05, gauge.fraction))),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.35), radius: lineWidth / 2)
                .animation(.spring(response: 0.8, dampingFraction: 0.85), value: gauge.fraction)
            if let elapsed = gauge.elapsed {
                // Even-pace tick on the track.
                Capsule()
                    .fill(Theme.Colour.text.opacity(0.75))
                    .frame(width: max(2, lineWidth / 4), height: lineWidth * 1.5)
                    .modifier(RingPosition(fraction: elapsed, lineWidth: lineWidth))
            }
            if showsValue {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(gauge.pct.rounded()))").font(valueFont)
                    Text("%").font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Theme.Colour.text)
                .contentTransition(.numericText())
            }
        }
        .padding(lineWidth / 2)
    }
}

/// Places a view on the ring at `fraction` of a full turn, from 12 o'clock.
private struct RingPosition: ViewModifier {
    let fraction: Double
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            let angle = Angle.degrees(360 * fraction - 90)
            content
                .rotationEffect(.degrees(360 * fraction))
                .position(x: geo.size.width / 2 + CGFloat(cos(angle.radians)) * r,
                          y: geo.size.height / 2 + CGFloat(sin(angle.radians)) * r)
        }
    }
}
