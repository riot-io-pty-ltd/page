import SwiftUI

/// Settled: today's receipt lines, then a headline card per earlier day. This
/// is where History went. "See all" opens every settled page and the day
/// stats (the full list is longer than the 12 lines and 14 days shown here).
struct NWSettledList: View {
    var log: SettledLog
    var onSeeAll: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SETTLED").font(NightWatch.Typo.labelLarge).kerning(1.2)
                    .foregroundColor(NightWatch.Palette.textTertiary.color)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let onSeeAll {
                    Button(action: onSeeAll) {
                        HStack(spacing: 4) {
                            Text("See all")
                            Image(systemName: "chevron.right").font(.system(.caption2, weight: .bold))
                        }
                        .font(NightWatch.Typo.captionStrong)
                        .foregroundColor(NightWatch.Palette.textSecondary.color)
                        .frame(minHeight: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
            if log.today.isEmpty && log.days.isEmpty {
                Text("Nothing settled yet. Every decision you make, and every turn that finishes, lands here.")
                    .font(NightWatch.Typo.caption)
                    .foregroundColor(NightWatch.Palette.textQuiet.color)
            }
            ForEach(log.today) { line in
                HStack(spacing: 10) {
                    Circle().fill(color(line.tone).color).frame(width: 7, height: 7)
                    Text(line.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text([line.age, line.status].compactMap { $0 }.joined(separator: " · "))
                        .foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
                }
                .font(NightWatch.Typo.monoSmall)
                .foregroundColor(NightWatch.Palette.textSecondary.color)
                .accessibilityElement(children: .combine)
            }
            ForEach(log.days) { day in
                HStack(spacing: 10) {
                    Circle().fill(NightWatch.Palette.textQuiet.color).frame(width: 7, height: 7)
                    Text(day.headline).lineLimit(2)
                }
                .font(NightWatch.Typo.monoSmall)
                .foregroundColor(NightWatch.Palette.textSecondary.color)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func color(_ t: SettledLine.Tone) -> NightWatch.RGBA {
        switch t {
        case .approved: return NightWatch.Palette.green
        case .sent: return NightWatch.Palette.sky
        case .neutral: return NightWatch.Palette.textQuiet
        }
    }
}
