import SwiftUI

/// Settled: today's receipt lines, then a headline card per earlier day. This
/// is where History went. "See all" opens every settled page and the day
/// stats (the full list is longer than the 12 lines and 14 days shown here).
/// A new receipt comes down from the top as its row opens, then its ✓
/// draws (`NowMotion.receipt`), on a clock that runs only while one lands;
/// receipts fade with age (1 under 5 min, 0.55 by 2 h), on Now's own tick.
struct NWSettledList: View {
    var log: SettledLog
    var onSeeAll: (() -> Void)? = nil
    /// Now's scene and moment (`NWNowMotion`); bare (the harness's lists), every receipt has landed.
    var motion = NWNowMotion()
    /// The clock the receipts age on; nil: they are not faded.
    var now: Date? = nil

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
            if !log.today.isEmpty {
                let s = motion.scene, rm = motion.reduceMotion
                NWWorkflowClock(origin: 0, until: s.receiptsSettle(reduceMotion: rm), pinned: motion.pinned) { t in
                    // The gap under each line opens with it, so the lines below move down smoothly.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(log.today) { line in
                            todayLine(line, gap: line.id == log.today.last?.id ? 0 : 14, arriving: s.receipt(line.id, at: t, reduceMotion: rm))
                                .transition(.identity)
                        }
                    }
                }
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
        // A receipt arriving is drawn by the model: in the update that brings one, the list (header and lines
        // together) takes its place at once rather than also springing with a change above it. Otherwise it
        // moves as a whole with what is above (the queued line coming and going, the stream's spring).
        .animation(nil, value: log.today.map(\.id))
    }

    /// A receipt line, landing if it has just arrived, as faded as it is old.
    private func todayLine(_ line: SettledLine, gap: CGFloat, arriving r: NowMotion.Receipt?) -> some View {
        let status = [line.age, line.status].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 10) {
            Circle().fill(color(line.tone).color).frame(width: 7, height: 7)
            Text(line.text).lineLimit(1)
            Spacer(minLength: 4)
            Group {
                if status.hasSuffix("✓") {
                    NWDrawnCheck.over(status, progress: r?.check ?? 1, color: NightWatch.Palette.textTertiary)
                } else {
                    Text(status)
                }
            }
            .foregroundColor(NightWatch.Palette.textTertiary.color).lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(status))
        }
        .font(NightWatch.Typo.monoSmall)
        .foregroundColor(NightWatch.Palette.textSecondary.color)
        .opacity(now.map { NowMotion.settledOpacity(ageMinutes: $0.timeIntervalSince(line.at) / 60) } ?? 1)
        .accessibilityElement(children: .combine)
        .padding(.bottom, gap)
        .modifier(NWFold(fraction: r?.height ?? 1, fades: false))
        .offset(y: CGFloat(r?.offset ?? 0))
        .opacity(r?.opacity ?? 1)
    }

    private func color(_ t: SettledLine.Tone) -> NightWatch.RGBA {
        switch t {
        case .approved: return NightWatch.Palette.green
        case .sent: return NightWatch.Palette.sky
        case .neutral: return NightWatch.Palette.textQuiet
        }
    }
}
