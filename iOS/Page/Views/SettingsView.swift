import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var pairing: PairingStore
    @EnvironmentObject var api: APIClient
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Space.xxl) {
                    HStack {
                        Text("Settings")
                            .font(Theme.Font.display28)
                            .foregroundStyle(Theme.Colour.text)
                        Spacer()
                    }

                    section(title: "PAIRED MACS") {
                        if let mac = pairing.pairedMac {
                            macCard(mac)
                        }
                        Button {
                            // Take user to PairMacView (presented as sheet)
                        } label: {
                            HStack(spacing: Theme.Space.s) {
                                Image(systemName: "plus")
                                Text("Pair another Mac")
                            }
                            .font(Theme.Font.bodyEm)
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.button)
                                .strokeBorder(Theme.Colour.hairline, lineWidth: 1))
                            .foregroundStyle(Theme.Colour.text)
                        }
                        .buttonStyle(.plain)
                    }

                    section(title: "ABOUT") {
                        infoRow("Version", value: appVersion)
                        infoRow("Help & feedback", value: "")
                    }
                    Spacer().frame(height: 120)
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
            }
        }
    }

    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(title)
                .font(Theme.Font.caption12)
                .tracking(0.5)
                .foregroundStyle(Theme.Colour.textMuted)
            content()
        }
    }

    private func macCard(_ mac: PairedMac) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                Text(mac.name)
                    .font(Theme.Font.bodyEm)
                    .foregroundStyle(Theme.Colour.text)
                Spacer()
                HStack(spacing: 6) {
                    PulseMark(size: 10, pulsing: api.connected)
                    Text(api.connected ? "Connected" : "Offline")
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                }
            }
            HStack {
                Text(mac.hostname)
                    .font(Theme.Font.mono13)
                    .foregroundStyle(Theme.Colour.textMuted)
                Spacer()
                let liveSessions = api.activeSessions > 0 ? api.activeSessions : mac.activeSessions
                Text("\(liveSessions) active session\(liveSessions == 1 ? "" : "s")")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
            Button("UNPAIR", role: .destructive) { pairing.unpair() }
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(Theme.Colour.destructive)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colour.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.Colour.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(Theme.Font.mono13)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colour.textMuted)
        }
    }
}

// MARK: - History

struct HistoryView: View {
    @EnvironmentObject var api: APIClient

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Space.xxl) {
                    headerRow
                    if api.history.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: Theme.Space.m) {
                            ForEach(api.history) { item in
                                HistoryCard(intervention: item)
                            }
                        }
                    }
                    Spacer().frame(height: 120)
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
            Spacer()
            Text("\(api.history.count)")
                .font(Theme.Font.caption12)
                .tracking(0.5)
                .foregroundStyle(Theme.Colour.textMuted)
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Space.l) {
            Spacer().frame(height: 80)
            PulseMark(size: 64, pulsing: false)
            Text("No history yet")
                .font(Theme.Font.title17)
                .foregroundStyle(Theme.Colour.textMuted)
            Text("Pages you've resolved will appear here.")
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.textMuted)
                .multilineTextAlignment(.center)
        }
    }
}

private struct HistoryCard: View {
    let intervention: Intervention

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Text(intervention.projectName)
                    .font(Theme.Font.mono13)
                    .foregroundStyle(Theme.Colour.textMuted)
                Spacer()
                kindChip
            }
            Text(intervention.context)
                .font(Theme.Font.body15)
                .foregroundStyle(Theme.Colour.text)
                .lineLimit(2)
            if let reply = intervention.repliedText, !reply.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colour.textMuted)
                    Text(reply)
                        .font(Theme.Font.body15)
                        .italic()
                        .foregroundStyle(Theme.Colour.textMuted)
                        .lineLimit(2)
                }
            } else if let action = intervention.repliedAction {
                Text(action.uppercased())
                    .font(Theme.Font.caption12)
                    .tracking(0.5)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
            HStack {
                Text(intervention.closedAgo ?? intervention.pagedAgo)
                    .font(Theme.Font.caption12)
                    .tracking(0.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Colour.textMuted)
                Spacer()
                if let rt = intervention.responseTimeSeconds {
                    Text(formatResponseTime(rt))
                        .font(Theme.Font.caption12)
                        .foregroundStyle(Theme.Colour.textMuted)
                }
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colour.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.Colour.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var kindChip: some View {
        Text(intervention.kind.label)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(Theme.Colour.hairline, lineWidth: 1))
            .foregroundStyle(Theme.Colour.textMuted)
    }

    private func formatResponseTime(_ s: Int) -> String {
        if s < 60 { return "\(s)s response" }
        if s < 3600 { return "\(s / 60)m response" }
        return "\(s / 3600)h response"
    }
}

// MARK: - Stats

struct StatsView: View {
    @EnvironmentObject var api: APIClient

    var body: some View {
        ZStack {
            Theme.Colour.surface.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Theme.Space.xxl) {
                    HStack {
                        Text("Stats")
                            .font(Theme.Font.display28)
                            .foregroundStyle(Theme.Colour.text)
                        Spacer()
                    }
                    summaryGrid
                    topProjects
                    Spacer().frame(height: 120)
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xxl)
            }
            .refreshable { await api.refreshHistory() }
        }
        .task { await api.refreshHistory() }
    }

    // MARK: stat computations

    private var pagesToday: Int {
        let start = Calendar.current.startOfDay(for: Date())
        return api.history.filter { $0.openedAt >= start }.count + api.inbox.filter { $0.openedAt >= start }.count
    }

    private var pagesThisWeek: Int {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date.distantPast
        return api.history.filter { $0.openedAt >= start }.count + api.inbox.filter { $0.openedAt >= start }.count
    }

    private var avgResponseTimeSeconds: Int? {
        let times = api.history.compactMap { $0.responseTimeSeconds }
        guard !times.isEmpty else { return nil }
        return times.reduce(0, +) / times.count
    }

    private var projectCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for iv in api.history { counts[iv.projectName, default: 0] += 1 }
        for iv in api.inbox  { counts[iv.projectName, default: 0] += 1 }
        return counts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    private var summaryGrid: some View {
        VStack(spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                statCard(label: "TODAY", value: "\(pagesToday)", sub: pagesToday == 1 ? "page" : "pages")
                statCard(label: "THIS WEEK", value: "\(pagesThisWeek)", sub: "")
            }
            HStack(spacing: Theme.Space.m) {
                statCard(label: "AVG RESPONSE", value: avgResponseTimeSeconds.map { formatSeconds($0) } ?? "—", sub: "")
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
            if !sub.isEmpty {
                Text(sub)
                    .font(Theme.Font.caption12)
                    .foregroundStyle(Theme.Colour.textMuted)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colour.surfaceRaised)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
            .strokeBorder(Theme.Colour.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private var topProjects: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text("TOP PROJECTS")
                .font(Theme.Font.caption12)
                .tracking(0.5)
                .foregroundStyle(Theme.Colour.textMuted)
            if projectCounts.isEmpty {
                Text("Nothing yet")
                    .font(Theme.Font.body15)
                    .foregroundStyle(Theme.Colour.textMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(projectCounts.prefix(5).enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.name)
                                .font(Theme.Font.body15)
                                .foregroundStyle(Theme.Colour.text)
                            Spacer()
                            Text("\(row.count)")
                                .font(Theme.Font.bodyEm)
                                .foregroundStyle(Theme.Colour.textMuted)
                        }
                        .padding(.vertical, Theme.Space.s)
                        Divider().opacity(0.4)
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .padding(.vertical, Theme.Space.s)
                .background(Theme.Colour.surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(Theme.Colour.hairline, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            }
        }
    }

    private func formatSeconds(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}
