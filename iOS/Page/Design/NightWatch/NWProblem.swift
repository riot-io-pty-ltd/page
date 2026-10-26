import SwiftUI

/// What is wrong, what it means, and the one obvious fix. It sits first in
/// the Now stream under a Horizon that has gone hollow, so the screen never
/// says "all quiet" while Page cannot see your Mac.
struct NWProblemCard: View {
    var problem: ProblemState
    var onAction: (ProblemState.Action) -> Void = { _ in }

    var body: some View {
        let tone: NightWatch.RGBA = problem.tone == .slate ? NightWatch.RGBA(hex: 0x8A93A8) : NightWatch.Palette.amber
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(problem.details) { d in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: d.symbol).font(.system(.body)).foregroundColor(tone.color).frame(width: 24)
                        Text(d.text).font(NightWatch.Typo.body).foregroundColor(NightWatch.Palette.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Button { onAction(problem.action) } label: { Text(problem.actionTitle) }
                .buttonStyle(NWButtonStyle(kind: problem.tone == .slate ? .quiet : .amber))
            if let title = problem.secondaryTitle, let action = problem.secondaryAction {
                Button { onAction(action) } label: { Text(title) }.buttonStyle(NWButtonStyle(kind: .quiet))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NWGlassBackground(radius: 24, tint: problem.tone == .amber ? NightWatch.Palette.amber : nil))
        .accessibilityElement(children: .contain)
    }
}
