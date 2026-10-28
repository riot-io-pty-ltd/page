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
/// Drawn at one moment of its motion (`NowMotion.RunwayFrame`: the line
/// drawing in, markers popping, gliding and reaching now, the NOW dot's
/// breath); Now runs the clock (`NWNowRunway`), and without a frame (the
/// widgets, Dispatch) it is drawn settled. Its height never changes as it
/// moves, and nothing it draws leaves its card.
struct NWRunwayBar: View {
    var model: RunwayModel
    var frame: NowMotion.RunwayFrame? = nil
    private let labelRow: CGFloat = 16
    private let inset: CGFloat = 22
    private let labelWidth: CGFloat = 92

    var body: some View {
        let lanes = (model.markers.map(\.lane).max() ?? 0) + 1
        let lineY = CGFloat(lanes) * labelRow + 10
        let f = frame ?? NowMotion.RunwayFrame.settled(model)
        GeometryReader { geo in
            let w = geo.size.width - inset * 2
            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(LinearGradient(
                        colors: [NightWatch.Palette.teal.opacity(model.onAC ? 0.55 : 0.5).color,
                                 NightWatch.Palette.teal.opacity(model.onAC ? 0.55 : 0.22).color],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: w, height: 2)
                    // It draws in from the NOW dot, the gradient staying where it lies.
                    .mask(alignment: .leading) { Rectangle().frame(width: max(0, w * CGFloat(min(1, f.line)))) }
                    .offset(x: inset, y: lineY - 1)
                nowDot(breath: f.breath)
                    .offset(x: inset - 6, y: lineY - 6)
                ForEach(f.markers, id: \.key) { mf in
                    let m = mf.marker
                    let x = inset + CGFloat(mf.x) * w
                    if let g = mf.flash {
                        Circle().fill(m.tone.color.opacity(g.opacity).color)
                            .frame(width: 12 * CGFloat(g.scale), height: 12 * CGFloat(g.scale)).blur(radius: 3)
                            .offset(x: x - 6 * CGFloat(g.scale), y: lineY - 6 * CGFloat(g.scale))
                    }
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(m.tone.color.color)
                        .frame(width: 3, height: 16)
                        .scaleEffect(CGFloat(mf.scale))
                        .opacity(mf.opacity)
                        .offset(x: x - 1.5, y: lineY - 8)
                    // Labels sit right of their tick; near the end they flip to its left. A
                    // marker on its way out keeps to the lanes there are.
                    let flip = mf.x > 0.72
                    Text(m.label)
                        .font(.system(.caption2, weight: .medium))
                        .foregroundColor(m.tone.color.color)
                        .lineLimit(1)
                        .frame(width: labelWidth, alignment: flip ? .trailing : .leading)
                        .opacity(mf.opacity)
                        .offset(x: flip ? x - 5 - labelWidth : x + 5, y: CGFloat(min(m.lane, lanes - 1)) * labelRow)
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
                    .opacity(f.line)
                    .offset(x: inset + w - 70, y: lineY + 10)
                }
            }
        }
        .frame(height: lineY + 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
    }

    /// The white NOW dot; while agents work it breathes with the pulse (the lens's scale and halo).
    private func nowDot(breath: Double?) -> some View {
        ZStack {
            if let b = breath {
                Circle().fill(Color.white.opacity(WorkflowMotion.haloLow + (WorkflowMotion.haloHigh - WorkflowMotion.haloLow) * b))
                    .frame(width: 22, height: 22).blur(radius: 4)
            }
            Circle().fill(Color.white)
                .frame(width: 12, height: 12)
                .shadow(color: Color.white.opacity(0.5), radius: 3)
                .scaleEffect(1 + CGFloat(WorkflowMotion.breathScale * (breath ?? 0)))
        }
        .frame(width: 12, height: 12)
    }

    /// What VoiceOver reads.
    var accessibilityText: String {
        let power = model.onAC ? "on power" : "on battery"
        return model.markers.isEmpty ? "Runway: nothing ahead in the next six hours, \(power)"
            : "Runway, \(power): " + model.markers.map(\.label).joined(separator: ", ")
    }
}
