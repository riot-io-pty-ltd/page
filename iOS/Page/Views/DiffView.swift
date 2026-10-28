import SwiftUI
import UIKit

/// A session's changes as a sheet: this turn's files (or the repository's
/// uncommitted changes) with the redacted diff, asked from the Mac when the
/// screen opens (`diff` op). Read-only. The Session Room's Changes lens
/// draws the same panel; this is for the turn summary on a Decision sheet.
struct DiffView: View {
    let sessionId: String
    let title: String

    @EnvironmentObject var sessions: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var requestedAt = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let load = ChangesModel.load(hasDiff: sessions.diffs[sessionId] != nil, error: sessions.diffErrors[sessionId],
                                         requestedAt: requestedAt, now: context.date)
            ZStack {
                NWBackdrop()
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.system(.body, weight: .semibold))
                                .foregroundColor(NightWatch.Palette.textPrimary.color)
                                .frame(width: 48, height: 48).nwChromeGlass(in: Circle()) { Circle().fill(Color.white.opacity(0.09)) }
                        }
                        .buttonStyle(.plain).accessibilityLabel(Text("Close"))
                        Text(title).font(.system(.title3, design: .monospaced, weight: .semibold))
                            .foregroundColor(NightWatch.Palette.textPrimary.color).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, NightWatch.Space.lg).padding(.top, 14).padding(.bottom, 6)
                    NWChangesPanel(model: sessions.diffs[sessionId].map(ChangesModel.build), load: load,
                                   onRefresh: request, onCopy: { UIPasteboard.general.string = $0 }) { EmptyView() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { request() }
    }

    private func request() {
        requestedAt = Date()
        sessions.requestDiff(sessionId: sessionId)
    }
}
