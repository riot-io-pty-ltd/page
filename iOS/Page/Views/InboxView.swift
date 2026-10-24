import SwiftUI

struct InboxView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var notifications: NotificationService
    @EnvironmentObject var router: AppRouter

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            ScrollView {
                // Relative times, Mac presence and banners re-evaluate every
                // 15s even when no data changes.
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(spacing: Theme.Space.xl) {
                        headerRow
                        InboxBanners(now: context.date)
                        statusLine(now: context.date)
                        content(now: context.date)
                        Spacer().frame(height: 120)  // tab-bar padding
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
            }
            .refreshable { await api.refreshAll() }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Page")
                .font(Theme.Font.display28)
                .foregroundStyle(Theme.Colour.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            PulseMark(size: 24, pulsing: !api.inbox.isEmpty)
        }
    }

    private func statusLine(now: Date) -> some View {
        HStack {
            Text(statusText(now: now))
                .font(Theme.Font.caption12)
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colour.textMuted)
            Spacer()
        }
    }

    private func statusText(now: Date) -> String {
        let n = api.inbox.count
        if n > 0 { return "\(n) page\(n == 1 ? "" : "s") waiting" }
        switch api.inboxLoad {
        case .idle, .loading: return "Checking…"
        case .failed: return "Inbox may be out of date"
        case .loaded:
            return MacPresence.evaluate(api.macStatus, now: now).isReachable ? "All quiet" : "Nothing waiting"
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if api.inbox.isEmpty {
            if api.inboxLoad == .loaded || api.inboxLoad.failureMessage != nil {
                emptyState(now: now)
            } else {
                ProgressView("Loading pages…")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .padding(.top, 80)
            }
        } else {
            let urgentId = api.inbox.first.flatMap { $0.kind == .approval || $0.kind == .userInput ? $0.id : nil }
            VStack(spacing: Theme.Space.m) {
                ForEach(api.inbox) { item in
                    Button { router.open(interventionId: item.id) } label: {
                        InterventionCard(intervention: item,
                                         isMostUrgent: item.id == urgentId,
                                         delivery: api.deliveries[item.id],
                                         now: now)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the reply screen")
                }
            }
        }
    }

    private func emptyState(now: Date) -> some View {
        let macOK = MacPresence.evaluate(api.macStatus, now: now).isReachable
        let pushOK = notifications.authorization == .authorized
        let detail: String
        if api.inboxLoad.failureMessage != nil {
            detail = "Page couldn't load your inbox. Pull down to try again."
        } else if !macOK {
            detail = "Nothing is waiting right now, but your Mac isn't connected, so new pages can't reach you yet."
        } else if !pushOK {
            detail = "Your agents are working. Turn on notifications so Page can buzz you when one needs you."
        } else {
            detail = "Your agents are working away. We'll buzz you the moment one needs you."
        }
        return VStack(spacing: Theme.Space.l) {
            Spacer().frame(height: 48)
            PulseMark(size: 96, pulsing: false)
            Text("Nothing to handle.")
                .font(Theme.Font.title17)
                .foregroundStyle(Theme.Colour.text)
            Text(detail)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.l)
        }
        .frame(maxWidth: .infinity)
    }
}

struct InterventionCard: View {
    let intervention: Intervention
    /// The top card when it blocks an agent: gets the pulse-gradient edge.
    let isMostUrgent: Bool
    let delivery: APIClient.DeliveryState?
    let now: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(intervention.projectName)
                .font(Theme.Font.mono13)
                .foregroundStyle(Theme.Colour.textMuted)
                .lineLimit(1)

            HStack(spacing: 6) {
                KindChip(kind: intervention.kind, subtype: intervention.subtype)
                if let backend = intervention.backend {
                    BackendPill(backend: backend, source: intervention.source)
                }
            }

            Text(intervention.context.isEmpty ? ReplyCopy.headline(for: intervention) : intervention.context)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
                .lineSpacing(2)
                .lineLimit(3)
                .multilineTextAlignment(.leading)

            HStack(alignment: .center, spacing: Theme.Space.s) {
                Text(RelativeTime.string("Paged", since: intervention.openedAt, now: now))
                    .font(Theme.Font.caption12)
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colour.textMuted)
                Spacer()
                if let status = deliveryBadge {
                    Text(status.text)
                        .font(Theme.Font.chip11)
                        .tracking(0.5)
                        .foregroundStyle(status.color)
                }
                StatusDot(color: intervention.kind.color)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colour.surfaceRaised)
        .overlay(alignment: .leading) {
            if isMostUrgent {
                Rectangle()
                    .fill(Theme.Colour.pulseGradient(scheme))
                    .frame(width: 4)
                    .accessibilityHidden(true)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Colour.hairline, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var deliveryBadge: (text: String, color: Color)? {
        switch delivery {
        case .sending?: return ("SENDING", Theme.Colour.textMuted)
        case .sent(let queued, _)?: return (queued ? "QUEUED" : "SENT", Theme.Colour.textMuted)
        case .delivered?: return ("DELIVERED", Theme.Colour.success)
        case .failed?: return ("DELIVERY FAILED", Theme.Colour.destructiveText)
        case .alreadyReplied?: return ("ANSWERED", Theme.Colour.textMuted)
        case .gone?, nil: return nil
        }
    }

    private var accessibilityText: String {
        var parts = [intervention.kind.accessibilityName, "from \(intervention.projectName)"]
        if let backend = intervention.backend { parts.append(backend.displayName) }
        if !intervention.context.isEmpty { parts.append(intervention.context) }
        parts.append(RelativeTime.string("Paged", since: intervention.openedAt, now: now))
        if let status = deliveryBadge { parts.append(status.text.capitalized) }
        return parts.joined(separator: ". ")
    }
}
