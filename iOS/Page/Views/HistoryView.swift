import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var api: APIClient

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: Theme.Space.xxl) {
                        headerRow
                        if api.history.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(spacing: Theme.Space.m) {
                                ForEach(api.history) { item in
                                    HistoryCard(intervention: item, now: context.date)
                                }
                            }
                        }
                        Spacer().frame(height: 120)
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
            }
            .refreshable { await api.refreshHistory() }
        }
        .task { await api.refreshHistory() }
    }

    private var headerRow: some View {
        HStack {
            Text("History")
                .font(Theme.Font.display28)
                .foregroundStyle(Theme.Colour.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if !api.history.isEmpty {
                Text("\(api.history.count)")
                    .font(Theme.Font.caption12)
                    .tracking(0.5)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .accessibilityLabel("\(api.history.count) resolved pages")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer().frame(height: 80)
            switch api.historyLoad {
            case .idle, .loading:
                ProgressView("Loading history…")
            case .failed(let message):
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(.largeTitle))
                    .foregroundStyle(Theme.Colour.textMuted)
                    .accessibilityHidden(true)
                Text("Couldn't load history")
                    .font(Theme.Font.title17)
                    .foregroundStyle(Theme.Colour.text)
                Text(message)
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .multilineTextAlignment(.center)
                Button("Try again") { Task { await api.refreshHistory() } }
                    .font(Theme.Font.bodyEm)
            case .loaded:
                PulseMark(size: 64, pulsing: false)
                Text("No history yet")
                    .font(Theme.Font.title17)
                    .foregroundStyle(Theme.Colour.text)
                Text("Pages you've resolved will appear here.")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HistoryCard: View {
    let intervention: Intervention
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(intervention.projectName)
                    .font(Theme.Font.mono13)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .lineLimit(1)
                Spacer()
                KindChip(kind: intervention.kind, subtype: intervention.subtype)
            }
            Text(intervention.context.isEmpty ? ReplyCopy.headline(for: intervention) : intervention.context)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
                .lineLimit(2)
            outcomeLine
            HStack {
                Text(timeText)
                    .font(Theme.Font.caption12)
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colour.textMuted)
                Spacer()
                if let rt = intervention.responseTimeSeconds {
                    Text("Answered in \(RelativeTime.compact(seconds: rt))")
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                }
            }
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }

    private var timeText: String {
        if let closed = intervention.closedAt {
            return RelativeTime.string("Closed", since: closed, now: now)
        }
        return RelativeTime.string("Paged", since: intervention.openedAt, now: now)
    }

    @ViewBuilder
    private var outcomeLine: some View {
        if let reply = intervention.repliedText, !reply.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .accessibilityLabel("You replied")
                Text(reply)
                    .font(Theme.Font.body15)
                    .italic()
                    .foregroundStyle(Theme.Colour.textMuted)
                    .lineLimit(2)
            }
        } else if let label = ReplyCopy.actionLabel(intervention.repliedAction) {
            Text(label.uppercased())
                .font(Theme.Font.caption12)
                .tracking(0.5)
                .foregroundStyle(Theme.Colour.textMuted)
        } else {
            Text(CloseReason.description(intervention.closeReason))
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.textMuted)
        }
    }
}
