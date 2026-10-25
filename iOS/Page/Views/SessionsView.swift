import SwiftUI

/// Every live agent session on the Mac, grouped "Needs you", "Working" and
/// "Idle". Tapping a card opens its transcript and composer; a session with
/// an open page also offers that page directly.
struct SessionsView: View {
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var sessions: SessionStore
    @EnvironmentObject var router: AppRouter
    @EnvironmentObject var pairing: PairingStore
    @State private var confirmingRepair = false
    @State private var startingSession = false

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            ScrollView {
                // Ages and presence re-evaluate every 5s. The store bumps
                // `waitTick` when the first-list wait runs out, which
                // re-renders this view through the environment object.
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    let availability = currentAvailability()
                    VStack(spacing: Theme.Space.xl) {
                        headerRow(availability)
                        statusLine(availability, now: context.date)
                        macStrip(now: context.date)
                        OtherMacsBanner()
                        content(availability, now: context.date)
                        Spacer().frame(height: 120)  // tab-bar padding
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
            }
            .refreshable {
                sessions.refresh()
                await api.refreshAll()
                await pairing.refreshOthers()
            }
            .task {
                while !Task.isCancelled, pairing.savedMacs.count > 1 {
                    await pairing.refreshOthers()
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
        }
        .confirmationDialog("Unpair this Mac?", isPresented: $confirmingRepair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { pairing.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll go back to the pairing screen. On your Mac, open Page → Pair phone… and scan the new code.")
        }
    }

    /// Evaluated against the wall clock, not the timeline's last tick, so
    /// the 5-second wait for a first list ends on time.
    private func currentAvailability() -> SessionAvailability {
        sessions.availability(presence: MacPresence.evaluate(api.macStatus, now: Date()),
                              socketConnected: api.connection == .connected, now: Date())
    }

    private func headerRow(_ availability: SessionAvailability) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Sessions")
                .font(Theme.Font.display28)
                .foregroundStyle(Theme.Colour.text)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if pairing.savedMacs.count > 1 { MacSwitcher() }
            if availability == .ready {
                Button { startingSession = true } label: {
                    Image(systemName: "plus")
                        .font(.system(.body, design: .default, weight: .semibold))
                        .foregroundStyle(Theme.Colour.text)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("New session")
            }
            PulseMark(size: 24, pulsing: sessions.sessions.contains { $0.state == .active })
        }
        .sheet(isPresented: $startingSession) { NewSessionView().environmentObject(sessions) }
    }

    /// The Mac's battery forecast and Claude usage, when it sends them.
    @ViewBuilder
    private func macStrip(now: Date) -> some View {
        let status = api.macStatus
        let battery = status?.batteryLine
        let usage = status?.usageLine(now: now, format: { $0.formatted(date: .omitted, time: .shortened) })
        if battery != nil || usage != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let battery {
                    Label(battery, systemImage: "battery.25")
                        .foregroundStyle((status?.forecast?.minutes ?? 99) <= 15 ? Theme.Colour.warning : Theme.Colour.textMuted)
                }
                if let usage {
                    Label(usage, systemImage: "gauge.with.dots.needle.67percent")
                        .foregroundStyle(status?.usage?.hitAt != nil ? Theme.Colour.warning : Theme.Colour.textMuted)
                }
            }
            .font(Theme.Font.caption12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func statusLine(_ availability: SessionAvailability, now: Date) -> some View {
        HStack {
            Text(statusText(availability, now: now))
                .font(Theme.Font.caption12)
                .tracking(0.5)
                .textCase(.uppercase)
                .foregroundStyle(Theme.Colour.textMuted)
                .lineLimit(1)
            Spacer()
        }
    }

    private func statusText(_ availability: SessionAvailability, now: Date) -> String {
        guard availability == .ready else { return SessionAvailabilityCopy(availability).shortStatus }
        let n = sessions.sessions.count
        let mac = sessions.macName ?? pairing.pairedMac?.name ?? "Your Mac"
        var text = "\(mac) · \(n) live"
        // The Mac refreshes the list at least every 20s; say so when it's late.
        if let at = sessions.lastListAt, now.timeIntervalSince(at) > 45 {
            text += " · updated \(RelativeTime.ago(since: at, now: now))"
        }
        return text
    }

    @ViewBuilder
    private func content(_ availability: SessionAvailability, now: Date) -> some View {
        switch availability {
        case .ready:
            if sessions.sessions.isEmpty {
                emptyState
            } else {
                list(now: now)
            }
        case .waiting:
            ProgressView("Connecting to your Mac…")
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.textMuted)
                .padding(.top, 80)
        default:
            let copy = SessionAvailabilityCopy(availability)
            SessionAvailabilityCard(copy: copy) { perform(copy.action) }
        }
    }

    private func perform(_ action: SessionAvailabilityCopy.Action?) {
        switch action {
        case .repair?: confirmingRepair = true
        case .retry?:
            sessions.refresh()
            Task { await api.refreshAll() }
        case nil: break
        }
    }

    private func list(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xl) {
            ForEach(SessionGrouping.sections(sessions.sessions)) { section in
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    SessionGroupHeader(group: section.group, count: section.sessions.count)
                    ForEach(section.sessions) { session in
                        SessionCard(session: session, now: now,
                                    onOpen: { router.openSession(session.id) },
                                    // Any open page, idle ones included.
                                    onOpenPage: session.interventionId.map { id in
                                        { router.open(interventionId: id, switchTab: false) }
                                    })
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer().frame(height: 48)
            PulseMark(size: 96, pulsing: false)
            Text("No live sessions")
                .font(Theme.Font.title17)
                .foregroundStyle(Theme.Colour.text)
            Text("Start Claude Code or Codex on your Mac and it shows up here, with what it's doing right now.")
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.l)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Group header

/// Separator above each group: the group's colour dot, its name and count,
/// and a hairline across the rest of the row, so Needs you / Working / Idle
/// read as distinct blocks at a glance.
struct SessionGroupHeader: View {
    let group: SessionGroup
    let count: Int

    private var color: Color {
        switch group {
        case .needsYou: return LiveSessionState.waitingOnApproval.color
        case .working: return LiveSessionState.active.color
        case .idle: return Theme.Colour.textMuted
        }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            StatusDot(color: color)
            Text(group.title)
                .font(Theme.Font.chip11)
                .tracking(0.8)
                .foregroundStyle(group == .idle ? Theme.Colour.textMuted : color)
            Text("\(count)")
                .font(Theme.Font.chip11)
                .foregroundStyle(Theme.Colour.textMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.Colour.surfaceInset))
            Rectangle()
                .fill(Theme.Colour.hairline)
                .frame(height: 1)
        }
        .padding(.top, Theme.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(group.title.capitalized), \(count)")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Card

/// One session, modelled on the inbox's InterventionCard: project, backend
/// and host, state, what it's doing, and how long ago.
struct SessionCard: View {
    let session: LiveSession
    let now: Date
    let onOpen: () -> Void
    let onOpenPage: (() -> Void)?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(session.title)
                        .font(Theme.Font.mono13)
                        .foregroundStyle(Theme.Colour.textMuted)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        BackendPill(agent: session.backend, host: session.hostLabel)
                        SessionStateChip(state: session.state)
                    }
                    Text(previewText)
                        .font(Theme.Font.body15)
                        .foregroundStyle(session.preview.isEmpty ? Theme.Colour.textMuted : Theme.Colour.text)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(alignment: .center, spacing: Theme.Space.s) {
                        Text(ageText)
                            .font(Theme.Font.caption12)
                            .tracking(0.5)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.Colour.textMuted)
                        Spacer()
                        if !session.canType {
                            Image(systemName: "keyboard.badge.ellipsis")
                                .font(Theme.Font.caption12)
                                .foregroundStyle(Theme.Colour.textMuted)
                                .accessibilityHidden(true)
                        }
                        StatusDot(color: session.state.color)
                    }
                }
                .padding(Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityHint("Opens the session's transcript")

            if let onOpenPage {
                Rectangle().fill(Theme.Colour.hairline).frame(height: 1).accessibilityHidden(true)
                Button(action: onOpenPage) {
                    HStack {
                        Label("Open page", systemImage: "bell.badge")
                            .font(Theme.Font.bodyEm)
                            .foregroundStyle(session.state.color)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(Theme.Font.caption12)
                            .foregroundStyle(Theme.Colour.textMuted)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, Theme.Space.l)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the reply screen for this session's prompt")
            }
        }
        .background(Theme.Colour.surfaceRaised)
        .overlay(alignment: .leading) {
            if session.state.isWaiting {
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
    }

    private var previewText: String {
        if !session.preview.isEmpty { return session.preview }
        return session.cwd.isEmpty ? "No recent activity" : session.cwd
    }

    private var ageText: String {
        guard let at = session.lastActivityAt else { return session.state.label }
        return RelativeTime.string("Active", since: at, now: now)
    }

    private var accessibilityText: String {
        var parts = [session.title, session.backend.displayName, session.hostLabel, session.state.label]
        if !session.preview.isEmpty { parts.append(session.preview) }
        if let at = session.lastActivityAt { parts.append(RelativeTime.string("Active", since: at, now: now)) }
        if !session.canType { parts.append("Page can't type here") }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Availability copy

/// What each availability state tells the user, and the step that fixes it.
struct SessionAvailabilityCopy: Equatable {
    enum Action: Equatable { case repair, retry }

    let systemImage: String
    let tone: StatusBanner.Tone
    let title: String
    let message: String
    let actionTitle: String?
    let action: Action?
    /// For the uppercase status line.
    let shortStatus: String

    init(_ availability: SessionAvailability) {
        switch availability {
        case .relayTooOld:
            self.init("arrow.triangle.2.circlepath", .warning, "Update your relay",
                      "Your relay (the Cloudflare Worker) doesn't support live sessions yet. Redeploy it from the latest Page release, then pull down to refresh. Pages keep working meanwhile.",
                      "Check again", .retry, "Relay needs an update")
        case .needsRepair(let mismatch):
            if mismatch {
                self.init("key.slash", .error, "Re-pair with your Mac",
                          "Live updates from your Mac can't be unlocked with this iPhone's key, so the pairing was probably regenerated on the Mac. Unpair, then on your Mac open Page → Pair phone… and scan the code.",
                          "Re-pair…", .repair, "Pairing key changed")
            } else {
                self.init("key", .warning, "Re-pair with your Mac to see live sessions",
                          "This pairing has no session key: it came from an older Page on your Mac, or was made before live sessions existed. Update Page on your Mac, unpair here, then open Page → Pair phone… on the Mac and scan the new code. Pages keep working meanwhile.",
                          "Re-pair…", .repair, "Re-pair needed")
            }
        case .macOffline:
            self.init("desktopcomputer.trianglebadge.exclamationmark", .warning, "Your Mac is offline",
                      "Live sessions show up while Page on your Mac is connected to the relay. Wake the Mac, or check that Page is running there.",
                      "Try again", .retry, "Mac offline")
        case .clockSkew:
            self.init("clock.badge.exclamationmark", .warning, "Your clocks disagree",
                      "Updates from your Mac arrive more than 10 minutes old by this iPhone's clock, so they're ignored. Turn on Set Automatically in Date & Time on both your iPhone and your Mac.",
                      "Try again", .retry, "Clock mismatch")
        case .macTooOld:
            self.init("arrow.down.app", .warning, "Update Page on your Mac",
                      "Your Mac is online but isn't sending live sessions. Update Page on your Mac to the latest version, and check that remote sessions are turned on in its Preferences.",
                      "Check again", .retry, "Mac needs an update")
        case .macDisabled:
            self.init("eye.slash", .warning, "Live sessions are off on your Mac",
                      "Page on your Mac isn't sharing its sessions. Turn them back on in Page → Preferences → Phone on the Mac.",
                      "Check again", .retry, "Off on your Mac")
        case .waiting:
            self.init("hourglass", .info, "Connecting to your Mac…", "", nil, nil, "Connecting…")
        case .ready:
            self.init("checkmark.circle", .info, "Live", "", nil, nil, "Live")
        }
    }

    private init(_ image: String, _ tone: StatusBanner.Tone, _ title: String, _ message: String,
                 _ actionTitle: String?, _ action: Action?, _ shortStatus: String) {
        systemImage = image
        self.tone = tone
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.shortStatus = shortStatus
    }
}

/// A full availability problem, as the Sessions list shows it.
struct SessionAvailabilityCard: View {
    let copy: SessionAvailabilityCopy
    let onAction: () -> Void

    var body: some View {
        StatusBanner(tone: copy.tone, systemImage: copy.systemImage, title: copy.title, message: copy.message,
                     actionTitle: copy.actionTitle, action: copy.action == nil ? nil : onAction)
    }
}
