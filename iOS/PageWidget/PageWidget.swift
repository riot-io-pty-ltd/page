import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widgets: how many sessions need you, how
/// many are working, the Mac's battery forecast and Claude usage. Reads the
/// relay's `GET /status` with the credentials the app shares
/// (`SharedWidgetStore`); refreshes every 15 minutes and whenever the app
/// asks (WidgetCenter).
@main
struct PageWidgetBundle: WidgetBundle {
    var body: some Widget { MacStatusWidget() }
}

struct MacStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "page.mac-status", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(Theme.Colour.surface, for: .widget)
                .widgetURL(URL(string: "page://sessions"))
        }
        .configurationDisplayName("Page")
        .description("Sessions that need you, agents at work, and your Mac's battery.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct StatusEntry: TimelineEntry {
    let date: Date
    /// nil: not paired, or the relay couldn't be reached.
    let status: WidgetStatus?
    var problem: String? = nil
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: Date(), status: .placeholder) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        if context.isPreview { return completion(StatusEntry(date: Date(), status: .placeholder)) }
        Task { completion(await Self.fetch()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Task {
            let entry = await Self.fetch()
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
        }
    }

    static func fetch() async -> StatusEntry {
        guard let creds = SharedWidgetStore.load(), let base = URL(string: creds.url) else {
            return StatusEntry(date: Date(), status: nil, problem: "Open Page to pair")
        }
        var req = URLRequest(url: base.appendingPathComponent("status"), timeoutInterval: 10)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("page-ios-widget/1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return StatusEntry(date: Date(), status: nil, problem: "Relay unavailable")
            }
            let status = WidgetStatus.from(json: json, macName: creds.macName, now: Date(),
                                           format: { $0.formatted(date: .omitted, time: .shortened) })
            return StatusEntry(date: Date(), status: status)
        } catch {
            return StatusEntry(date: Date(), status: nil, problem: "No connection")
        }
    }
}

struct StatusWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemMedium: medium
        default: small
        }
    }

    private var presenceColor: Color {
        switch entry.status?.presence {
        case .online: return Theme.Colour.success
        case .stale: return Theme.Colour.warning
        case .offline: return Theme.Colour.destructiveText
        default: return Theme.Colour.textMuted
        }
    }

    private var presenceText: String {
        switch entry.status?.presence {
        case .online: return "Online"
        case .stale: return "Not responding"
        case .offline: return "Offline"
        default: return "—"
        }
    }

    private func macRow(_ s: WidgetStatus) -> some View {
        HStack(spacing: 5) {
            Circle().fill(presenceColor).frame(width: 7, height: 7)
            Text(s.macName).font(.caption2.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Colour.textMuted)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(s.macName), \(presenceText)")
    }

    private var problemView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Page").font(.headline).foregroundStyle(Theme.Colour.text)
            Text(entry.problem ?? "—").font(.caption).foregroundStyle(Theme.Colour.textMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var small: some View {
        if let s = entry.status {
            VStack(alignment: .leading, spacing: 6) {
                macRow(s)
                Spacer(minLength: 0)
                Text(s.headline)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(s.needsYou > 0 ? Theme.Colour.warning : Theme.Colour.text)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                if let d = s.detail { Text(d).font(.caption).foregroundStyle(Theme.Colour.textMuted).lineLimit(1) }
                if let b = s.batteryLine { Text(b).font(.caption2).foregroundStyle(Theme.Colour.textMuted).lineLimit(2) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            problemView
        }
    }

    @ViewBuilder
    private var medium: some View {
        if let s = entry.status {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    macRow(s)
                    Spacer(minLength: 0)
                    Text(s.headline)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(s.needsYou > 0 ? Theme.Colour.warning : Theme.Colour.text)
                        .lineLimit(1)
                    if let d = s.detail { Text(d).font(.caption).foregroundStyle(Theme.Colour.textMuted) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let b = s.batteryLine { Label(b, systemImage: "battery.25") }
                    if let u = s.usageLine { Label(u, systemImage: "gauge.with.dots.needle.67percent") }
                    if s.batteryLine == nil && s.usageLine == nil {
                        Text("Updated \(s.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(Theme.Colour.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            problemView
        }
    }

    @ViewBuilder
    private var rectangular: some View {
        if let s = entry.status {
            VStack(alignment: .leading, spacing: 1) {
                Text("Page · \(presenceText)").font(.caption2.weight(.semibold))
                Text(s.headline).font(.headline).widgetAccentable()
                if let d = s.detail { Text(d).font(.caption2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(entry.problem ?? "Page").font(.caption)
        }
    }

    @ViewBuilder
    private var circular: some View {
        if let s = entry.status {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text("\(s.needsYou)").font(.title2.weight(.bold)).widgetAccentable()
                    Text("need").font(.system(size: 9))
                }
            }
            .accessibilityLabel(s.headline)
        } else {
            ZStack { AccessoryWidgetBackground(); Image(systemName: "bell.slash") }
        }
    }

    private var inline: some View {
        Text(entry.status.map { "Page: \($0.headline)" + ($0.working.map { ", \($0) working" } ?? "") } ?? "Page")
    }
}
