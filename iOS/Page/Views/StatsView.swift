import SwiftUI

/// Stats, shown as the second segment of the History tab (a fifth tab
/// wouldn't fit the Dynamic Type cap).
struct StatsContent: View {
    @EnvironmentObject var api: APIClient
    let now: Date

    var body: some View {
        let stats = PageStats.compute(history: api.history, inbox: api.inbox, now: now)
        VStack(alignment: .leading, spacing: Theme.Space.xxl) {
            if let failure = api.historyLoad.failureMessage, api.history.isEmpty {
                StatusBanner(tone: .error, systemImage: "wifi.exclamationmark",
                             title: "Couldn't load history",
                             message: "\(failure) Stats only include pages on this screen.",
                             actionTitle: "Try again") { Task { await api.refreshHistory() } }
            }
            summaryGrid(stats)
            topProjects(stats)
        }
    }

    private func summaryGrid(_ stats: PageStats) -> some View {
        VStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                statCard(label: "TODAY", value: "\(stats.today)", sub: stats.today == 1 ? "page" : "pages")
                statCard(label: "THIS WEEK", value: "\(stats.thisWeek)", sub: stats.thisWeek == 1 ? "page" : "pages")
            }
            HStack(spacing: Theme.Space.m) {
                statCard(label: "AVG RESPONSE",
                         value: stats.avgResponseSeconds.map { RelativeTime.compact(seconds: $0) } ?? "—",
                         sub: stats.repliedCount == 0 ? "no replies yet" : "across \(stats.repliedCount) repl\(stats.repliedCount == 1 ? "y" : "ies")")
                statCard(label: "PENDING NOW", value: "\(api.inbox.count)", sub: "")
            }
        }
    }

    private func statCard(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(label)
                .font(Theme.Font.caption12)
                .tracking(0.5)
                .foregroundStyle(Theme.Colour.textMuted)
            Text(value)
                .font(Theme.Font.display28)
                .foregroundStyle(Theme.Colour.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !sub.isEmpty {
                Text(sub)
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private func topProjects(_ stats: PageStats) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionTitle("TOP PROJECTS")
            if stats.topProjects.isEmpty {
                Text("Nothing yet")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stats.topProjects.enumerated()), id: \.offset) { index, row in
                        HStack {
                            Text(row.name)
                                .font(Theme.Font.body15)
                                .foregroundStyle(Theme.Colour.text)
                                .lineLimit(1)
                            Spacer()
                            Text("\(row.count)")
                                .font(Theme.Font.bodyEm)
                                .foregroundStyle(Theme.Colour.textMuted)
                        }
                        .padding(.vertical, Theme.Space.s)
                        .accessibilityElement(children: .combine)
                        if index < stats.topProjects.count - 1 {
                            Divider().opacity(0.4)
                        }
                    }
                }
                .cardStyle(padding: Theme.Space.m)
            }
        }
    }
}
