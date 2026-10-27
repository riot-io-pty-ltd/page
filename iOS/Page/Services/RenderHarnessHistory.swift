#if DEBUG
import SwiftUI

// Render-harness screens for History: the same NWHistoryScreen the app opens
// from Settled's "See all" and the Tower, on in-memory fixtures. History is
// the fixture history of the other harness screens (today's two pages, then a
// busy yesterday), so a row here is the line Settled shows there.

enum RenderHarnessHistory {
    static let screens = ["history", "history-stats", "history-empty", "history-loading", "history-failed", "history-large", "history-stats-large"]

    static func data(_ screen: String) -> HistoryScreenData {
        let now = RenderHarness.now
        let open = screen.contains("stats") || screen == "history" ? RenderFixtures.open : []
        switch screen {
        case "history-empty", "history-loading", "history-failed":
            let model = HistoryScreenModel.build(history: [], inbox: [], now: now, calendar: RenderHarness.calendar, timeZone: RenderHarness.timeZone)
            let empty: HistoryEmpty = screen == "history-empty" ? .none : (screen == "history-loading" ? .loading : .failed("The relay didn't answer."))
            return HistoryScreenData(model: model, empty: empty)
        default:
            let model = HistoryScreenModel.build(history: richHistory, inbox: open, now: now, calendar: RenderHarness.calendar,
                                                 timeZone: RenderHarness.timeZone)
            return HistoryScreenData(model: model, empty: nil)
        }
    }

    /// The shared fixture history plus a few older days, so the grouping and the day titles show.
    static var richHistory: [Intervention] {
        var list = RenderFixtures.history
        func older(_ id: String, _ project: String, _ ctx: String, action: String?, ago: TimeInterval, sub: String? = nil, kind: InterventionKind = .approval) {
            var x = RenderFixtures.iv(id, project, kind, ctx, ago: ago + 45, sub: sub)
            x.closedAt = RenderFixtures.now.addingTimeInterval(-ago)
            if let action {
                x.repliedAt = x.closedAt
                x.repliedAction = action
                x.deliveryStatus = "delivered"
                x.closeReason = "replied"
            }
            list.append(x)
        }
        let d = 86_400.0
        older("o1", "bottle-flip", "[Bash] rm -rf Builds/Dev/*.app\nDelete every Dev build", action: "deny", ago: d * 1.2)
        older("o2", "llm-play", "Looks stuck in a loop: this has failed 6 times.", action: nil, ago: d * 2.3, sub: "looping", kind: .idle)
        older("o3", "page", "[Edit] /Users/you/projects/page/Sources/Relay/Router.swift\nRoute replies", action: "approve", ago: d * 2.4)
        older("o4", "mac-on-claude-code", "Changed 3 files (+120 −14) · tests passed\n\nAll done.", action: nil, ago: d * 4.1, kind: .idle)
        return list
    }
}

struct HarnessHistory: View {
    let screen: String
    var body: some View {
        NWHistoryScreen(data: RenderHarnessHistory.data(screen), segment: screen.contains("stats") ? .stats : .history)
            .environment(\.dynamicTypeSize, screen.hasSuffix("large") ? .accessibility2 : .large)
    }
}
#endif
