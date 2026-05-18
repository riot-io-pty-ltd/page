import SwiftUI

struct InboxView: View {
    @EnvironmentObject var api: APIClient
    @State private var selection: Intervention?

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Space.xxl) {
                    headerRow
                    statusLine
                    if api.inbox.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: Theme.Space.m) {
                            ForEach(Array(api.inbox.enumerated()), id: \.element.id) { idx, item in
                                Button { selection = item } label: {
                                    InterventionCard(
                                        intervention: item,
                                        isMostUrgent: idx == 0 && item.kind == .approval
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Spacer().frame(height: 120)  // tab-bar padding
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
            }
            .refreshable { await api.refreshInbox() }
        }
        .task {
            await api.refreshInbox()
            api.connectWebSocket()
        }
        .sheet(item: $selection) { intervention in
            ReplyView(intervention: intervention) { selection = nil }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Page")
                .font(Theme.Font.display28)
                .foregroundStyle(Theme.Colour.text)
            Spacer()
            PulseMark(size: 24, pulsing: !api.inbox.isEmpty)
        }
    }

    private var statusLine: some View {
        HStack {
            Text(api.inbox.isEmpty ? "All quiet" : "\(api.inbox.count) page\(api.inbox.count == 1 ? "" : "s") waiting")
                .font(Theme.Font.caption12)
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colour.textMuted)
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer().frame(height: 80)
            PulseMark(size: 96, pulsing: false)
            Text("Nothing to handle.")
                .font(Theme.Font.title17)
                .foregroundStyle(Theme.Colour.textMuted)
            Text("Your AI agents are working away. We'll buzz you the moment one needs you.")
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.xxl)
        }
    }
}

struct InterventionCard: View {
    let intervention: Intervention
    let isMostUrgent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(intervention.projectName)
                .font(Theme.Font.mono13)
                .foregroundStyle(Theme.Colour.textMuted)

            HStack(spacing: 6) {
                kindChip
                if let backend = intervention.backend {
                    backendPill(backend, source: intervention.source)
                }
            }

            Text(intervention.context)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colour.text.opacity(0.85))
                .lineSpacing(2)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            HStack(alignment: .center) {
                Text(intervention.pagedAgo)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colour.textMuted)
                Spacer()
                Circle()
                    .fill(intervention.kind.color)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colour.surfaceRaised)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colour.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var kindChip: some View {
        let color = intervention.kind.color
        return Text(intervention.kind.label)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(color, lineWidth: 1))
            .foregroundStyle(color)
            .opacity(0.85)
    }

    private func backendPill(_ backend: InterventionBackend, source: InterventionSource?) -> some View {
        let tint = backend.tint
        return HStack(spacing: 6) {
            Text(backend.badge)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(tint)
            Text(source?.label ?? InterventionSource.unknown.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1))
    }
}
