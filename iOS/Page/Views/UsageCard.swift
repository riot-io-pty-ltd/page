import SwiftUI

/// Claude subscription usage on the Sessions tab: the 5-hour and 7-day
/// windows as rings, when each resets, how usage compares with an even
/// pace, and one line saying whether you'll run out. From the Mac's
/// heartbeat (`usage`), which needs usage tracking on in Page on the Mac.
struct UsageCard: View {
    let model: UsageCardModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("CLAUDE USAGE")
                    .font(Theme.Font.chip11)
                    .tracking(0.8)
                    .foregroundStyle(Theme.Colour.textMuted)
                Spacer()
                if let m = model.staleMinutes {
                    Text("as of \(m < 60 ? "\(m)m" : "\(m / 60)h") ago")
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                }
            }
            HStack(alignment: .top, spacing: Theme.Space.l) {
                if let g = model.fiveHour { column(g) }
                if let g = model.sevenDay { column(g) }
            }
            let verdict = model.verdict(format: { $0.formatted(date: .omitted, time: .shortened) })
            HStack(spacing: 6) {
                Image(systemName: verdict.warning ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                Text(verdict.text).fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.Font.caption12.weight(.semibold))
            .foregroundStyle(verdict.warning ? Theme.Colour.warning : Theme.Colour.success)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((verdict.warning ? Theme.Colour.warning : Theme.Colour.success).opacity(0.10)))
        }
        .padding(Theme.Space.l)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Theme.Colour.surfaceRaised, Theme.Colour.surfaceInset],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.Colour.hairline, lineWidth: 1))
    }

    private func column(_ g: UsageGauge) -> some View {
        VStack(spacing: 8) {
            UsageRing(gauge: g, lineWidth: 11)
                .frame(width: 104, height: 104)
            Text(g.label)
                .font(Theme.Font.bodyEm)
                .foregroundStyle(Theme.Colour.text)
            VStack(spacing: 2) {
                if let line = g.resetLine(now: now) {
                    Text(line)
                        .font(Theme.Font.caption12.weight(.semibold))
                        .foregroundStyle(Theme.Colour.text)
                        .monospacedDigit()
                }
                if let r = g.resetsAt {
                    Text(Self.resetTime(r, now: now))
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                }
                if let pace = g.paceLine {
                    Text(pace)
                        .font(Theme.Font.chip11)
                        .tracking(0.4)
                        .foregroundStyle(UsageRing.color(g.tone))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(UsageRing.color(g.tone).opacity(0.5), lineWidth: 1))
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(g, now: now))
    }

    /// "at 20:40" today, "Mon 20:00" another day.
    static func resetTime(_ d: Date, now: Date) -> String {
        Calendar.current.isDate(d, inSameDayAs: now)
            ? "at " + d.formatted(date: .omitted, time: .shortened)
            : d.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func spoken(_ g: UsageGauge, now: Date) -> String {
        var s = "\(g.label) usage \(Int(g.pct.rounded())) percent"
        if let r = g.resetsAt { s += ", resets \(resetTime(r, now: now))" }
        if let p = g.paceLine { s += ", \(p.lowercased())" }
        return s
    }
}
