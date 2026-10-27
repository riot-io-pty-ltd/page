import SwiftUI

/// History, live: every settled page and the day's numbers, from the API
/// client. The screen itself is `NWHistoryScreen`; this feeds it the history
/// and the inbox, refreshes on open and on pull, and ticks the ages over.
struct HistoryContainer: View {
    @EnvironmentObject var api: APIClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            NWHistoryScreen(data: data(now: context.date), actions: actions)
        }
        .background(NightWatch.Palette.backgroundDeep.color.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await api.refreshHistory() }
    }

    private func data(now: Date) -> HistoryScreenData {
        let model = HistoryScreenModel.build(history: api.history, inbox: api.inbox, now: now)
        let empty = HistoryEmpty.state(isEmpty: api.history.isEmpty, loaded: api.historyLoad == .loaded,
                                       failure: api.historyLoad.failureMessage)
        return HistoryScreenData(model: model, empty: empty)
    }

    private var actions: HistoryScreenActions {
        var a = HistoryScreenActions()
        a.close = { dismiss() }
        a.retry = { Task { await api.refreshHistory() } }
        a.refresh = { await api.refreshHistory() }
        return a
    }
}
