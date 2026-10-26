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
/// resets, scheduled resumes). On AC the line runs to the end unbroken, with
/// no cutoff.
struct NWRunwayBar: View {
    var model: RunwayModel
    /// Height of one label row above the line.
    private let labelRow: CGFloat = 12
    private let inset: CGFloat = 20
    private let labelWidth: CGFloat = 80

    var body: some View {
        let lanes = (model.markers.map(\.lane).max() ?? 0) + 1
        let lineY = CGFloat(lanes) * labelRow + 9
        GeometryReader { geo in
            let w = geo.size.width - inset * 2
            ZStack(alignment: .topLeading) {
                // The line.
                Capsule()
                    .fill(LinearGradient(
                        colors: [NightWatch.Palette.teal.opacity(model.onAC ? 0.5 : 0.42).color,
                                 NightWatch.Palette.teal.opacity(model.onAC ? 0.5 : 0.22).color],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: w, height: 2)
                    .offset(x: inset, y: lineY - 1)
                // Now.
                Circle().fill(Color.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: Color.white.opacity(0.5), radius: 3)
                    .offset(x: inset - 5.5, y: lineY - 5.5)
                // Markers.
                ForEach(model.markers) { m in
                    let x = inset + CGFloat(m.fraction) * w
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(m.tone.color.color)
                        .frame(width: 3, height: 15)
                        .offset(x: x - 1.5, y: lineY - 7.5)
                    // Labels sit right of their tick; near the end they flip to its left.
                    let flip = m.fraction > 0.78
                    Text(m.label)
                        .font(Font.system(size: 9.5, weight: .medium))
                        .foregroundColor(m.tone.color.color)
                        .lineLimit(1)
                        .frame(width: labelWidth, alignment: flip ? .trailing : .leading)
                        .offset(x: flip ? x - 5 - labelWidth : x + 5, y: CGFloat(m.lane) * labelRow)
                }
            }
        }
        .frame(height: lineY + 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// Pure enough: what VoiceOver reads.
    var accessibilityText: String {
        model.markers.isEmpty ? "Runway: nothing ahead in the next six hours"
            : "Runway: " + model.markers.map(\.label).joined(separator: ", ")
    }
}
