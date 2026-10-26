import SwiftUI

extension RunwayMarker.Tone {
    var color: NightWatch.RGBA {
        switch self {
        case .amber: return NightWatch.Palette.amber
        case .green: return NightWatch.Palette.green
        case .blue: return NightWatch.Palette.sky
        }
    }
}

/// The Runway: a line across the next six hours with a "now" dot at the left
/// and a labelled tick per deadline or event (battery cutoff, 5h limit,
/// resets). On AC the line runs to the end unbroken with a "on AC" note, and
/// no cutoff. Sits on a glass card; a tap opens the Tower, scrolled to Budget.
struct NWRunwayBar: View {
    var model: RunwayModel
    private let labelRow: CGFloat = 16
    private let inset: CGFloat = 22
    private let labelWidth: CGFloat = 92

    var body: some View {
        let lanes = (model.markers.map(\.lane).max() ?? 0) + 1
        let lineY = CGFloat(lanes) * labelRow + 10
        GeometryReader { geo in
            let w = geo.size.width - inset * 2
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: [NightWatch.Palette.teal.opacity(model.onAC ? 0.55 : 0.5).color,
                                 NightWatch.Palette.teal.opacity(model.onAC ? 0.55 : 0.22).color],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: w, height: 2)
                    .offset(x: inset, y: lineY - 1)
                Circle().fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: Color.white.opacity(0.5), radius: 3)
                    .offset(x: inset - 6, y: lineY - 6)
                ForEach(model.markers) { m in
                    let x = inset + CGFloat(m.fraction) * w
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(m.tone.color.color)
                        .frame(width: 3, height: 16)
                        .offset(x: x - 1.5, y: lineY - 8)
                    // Labels sit right of their tick; near the end they flip to its left.
                    let flip = m.fraction > 0.72
                    Text(m.label)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundColor(m.tone.color.color)
                        .lineLimit(1)
                        .frame(width: labelWidth, alignment: flip ? .trailing : .leading)
                        .offset(x: flip ? x - 5 - labelWidth : x + 5, y: CGFloat(m.lane) * labelRow)
                }
                Text("NOW")
                    .font(NightWatch.Typo.label).kerning(0.8)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .offset(x: inset - 6, y: lineY + 11)
                if model.onAC {
                    HStack(spacing: 3) {
                        Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                        Text("on AC").font(.system(.caption2, weight: .medium))
                    }
                    .foregroundColor(NightWatch.Palette.teal.opacity(0.9).color)
                    .frame(width: 70, alignment: .trailing)
                    .offset(x: inset + w - 70, y: lineY + 10)
                }
            }
        }
        .frame(height: lineY + 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// What VoiceOver reads.
    var accessibilityText: String {
        let power = model.onAC ? "on power" : "on battery"
        return model.markers.isEmpty ? "Runway: nothing ahead in the next six hours, \(power)"
            : "Runway, \(power): " + model.markers.map(\.label).joined(separator: ", ")
    }
}
