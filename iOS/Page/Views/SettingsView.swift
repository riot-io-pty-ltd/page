import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var api: APIClient
    @EnvironmentObject var notifications: NotificationService
    @State private var confirmingUnpair = false

    static let feedbackURL = URL(string: "https://github.com/riot-io-pty-ltd/page/issues")!

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            ScrollView {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                        Text("Settings")
                            .font(Theme.Font.display28)
                            .foregroundStyle(Theme.Colour.text)
                            .accessibilityAddTraits(.isHeader)

                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            SectionTitle("YOUR MAC")
                            if let mac = pairing.pairedMac {
                                macCard(mac, now: context.date)
                            }
                        }

                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            SectionTitle("CONNECTION")
                            connectionCard
                        }

                        VStack(alignment: .leading, spacing: Theme.Space.m) {
                            SectionTitle("ABOUT")
                            aboutCard
                        }
                        Spacer().frame(height: 120)
                    }
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
            }
            .refreshable {
                await api.refreshAll()
                await notifications.refreshAuthorization()
            }
        }
        .task {
            await api.refreshStatus()
            await notifications.refreshAuthorization()
        }
        .confirmationDialog("Unpair \(pairing.pairedMac?.name ?? "this Mac")?",
                            isPresented: $confirmingUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { pairing.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This iPhone will stop receiving pages until you scan a pairing code again.")
        }
    }

    // MARK: Mac

    private func macCard(_ mac: PairedMac, now: Date) -> some View {
        let presence = MacPresence.evaluate(api.macStatus, now: now)
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(mac.name)
                    .font(Theme.Font.bodyEm)
                    .foregroundStyle(Theme.Colour.text)
                Spacer()
            }
            HStack(spacing: Theme.Space.s) {
                StatusDot(color: presence.dotColor)
                Text(presence.summary(now: now))
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Mac status: \(presence.summary(now: now))")

            if let details = macDetails(presence) {
                Text(details)
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
            if let host = pairing.relayHost {
                Text("Relay: \(host)")
                    .font(Theme.Font.mono13)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button(role: .destructive) { confirmingUnpair = true } label: {
                Text("Unpair")
                    .font(Theme.Font.bodyEm)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .foregroundStyle(Theme.Colour.destructiveText)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button)
                        .strokeBorder(Theme.Colour.destructiveText.opacity(0.4), lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Space.xs)
        }
        .cardStyle()
    }

    /// "3 active sessions · Battery 54%, on power" — only real values, and
    /// only while the Mac is reporting (a stale count would mislead).
    private func macDetails(_ presence: MacPresence) -> String? {
        guard presence.isReachable, let status = api.macStatus else { return nil }
        var parts: [String] = []
        if let n = status.activeSessions {
            parts.append("\(n) active session\(n == 1 ? "" : "s")")
        }
        if let pct = status.batteryPercent {
            var battery = "Battery \(pct)%"
            if status.onAC == true { battery += ", on power" }
            parts.append(battery)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Connection

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            row("Relay", value: relayText)
            Divider().opacity(0.4)
            HStack {
                row("Notifications", value: notificationsText)
                if notifications.authorization == .denied {
                    Button("Open Settings") { InboxBanners.openNotificationSettings() }
                        .font(Theme.Font.bodyEm)
                } else if notifications.authorization == .notDetermined {
                    Button("Turn on") { Task { await notifications.requestAuthorizationIfNeeded() } }
                        .font(Theme.Font.bodyEm)
                }
            }
            Divider().opacity(0.4)
            row("Push", value: pushText)
        }
        .cardStyle()
    }

    private var relayText: String {
        switch api.connection {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .disconnected:
            if let failure = api.inboxLoad.failureMessage { return "Offline — \(failure)" }
            return "Reconnecting…"
        }
    }

    private var notificationsText: String {
        switch notifications.authorization {
        case .authorized: return "Allowed"
        case .denied: return "Off — you won't be paged"
        case .notDetermined: return "Not set up yet"
        case .unknown: return "Checking…"
        }
    }

    private var pushText: String {
        switch notifications.push {
        case .registered: return "Registered with your relay"
        case .registering: return "Registering…"
        case .failed(let why), .unavailable(let why): return why
        case .unknown:
            return notifications.authorization == .authorized ? "Waiting for Apple…" : "Needs notifications"
        }
    }

    private func row(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
            Text(value)
                .font(Theme.Font.caption12)
                .foregroundStyle(Theme.Colour.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: About

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack {
                Text("Version")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.text)
                Spacer()
                Text(Self.versionString)
                    .font(Theme.Font.mono13)
                    .foregroundStyle(Theme.Colour.textMuted)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            Divider().opacity(0.4)
            Link(destination: Self.feedbackURL) {
                HStack {
                    Text("Help & feedback")
                        .font(Theme.Font.body15)
                        .foregroundStyle(Theme.Colour.text)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .accessibilityHint("Opens the Page issue tracker on GitHub")
        }
        .cardStyle()
    }

    /// "0.1.0 (1)" from the bundle, which XcodeGen fills from
    /// MARKETING_VERSION / CURRENT_PROJECT_VERSION.
    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
