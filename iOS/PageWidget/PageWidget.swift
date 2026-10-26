import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widgets: how many sessions need you, how
/// many are working, the Mac's battery forecast and Claude usage. Reads the
/// relay's `GET /status` with the credentials the app shares
/// (`SharedWidgetStore`); refreshes every 15 minutes and whenever the app
/// asks (WidgetCenter).
@main
struct PageWidgetBundle: WidgetBundle {
    var body: some Widget {
        MacStatusWidget()
        UsageWidget()
    }
}

struct MacStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "page.mac-status", provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    NWWidgetBackground(palette: entry.status?.facePalette ?? .asleep)
                }
                // Opens Now, where the decisions are.
                .widgetURL(URL(string: "page://now"))
        }
        .configurationDisplayName("Page")
        .description("Sessions that need you, agents at work, and the Runway: when your Mac's battery or your usage will stop the work.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryCircular, .accessoryInline])
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
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemMedium: face(.medium)
            case .systemLarge: face(.large)
            default: face(.small)
            }
        }
        // A widget is one still frame: the pulse and aurora hold a pose instead of animating.
        .environment(\.nwFixedPhase, 2.0)
    }

    private func face(_ size: NWWidgetSize) -> some View {
        NWWidgetStatusFace(status: entry.status, problem: entry.problem, size: size, now: entry.date)
    }

    private var presenceText: String {
        switch entry.status?.presence {
        case .online: return "Online"
        case .stale: return "Not responding"
        case .offline: return "Offline"
        default: return "—"
        }
    }

    @ViewBuilder
    private var rectangular: some View {
        if let s = entry.status {
            VStack(alignment: .leading, spacing: 1) {
                Text("Page · \(presenceText)").font(.caption2.weight(.semibold))
                Text(s.faceHeadline).font(.headline).widgetAccentable()
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
                if s.presence == .offline || s.presence == .stale {
                    Image(systemName: "moon.zzz").font(.title3).widgetAccentable()
                } else {
                    VStack(spacing: 0) {
                        Text("\(s.needsYou)").font(.title2.weight(.bold)).widgetAccentable()
                        Text("need").font(.system(size: 9))
                    }
                }
            }
            .accessibilityLabel(s.faceHeadline)
        } else {
            ZStack { AccessoryWidgetBackground(); Image(systemName: "bell.slash") }
        }
    }

    private var inline: some View {
        Text(entry.status.map { "Page: \($0.faceHeadline)" + ($0.presence == .online ? ($0.working.map { ", \($0) working" } ?? "") : "") } ?? "Page")
    }
}

// MARK: - Claude usage

/// The 5-hour and 7-day windows as rings, with their resets.
struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "page.claude-usage", provider: StatusProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(for: .widget) { NWWidgetBackground(palette: .quiet, strength: 0.5) }
                // Opens the Tower (Power and Budget live there).
                .widgetURL(URL(string: "page://tower"))
        }
        .configurationDisplayName("Claude usage")
        .description("Your 5-hour and 7-day Claude usage and when each resets. Turn on usage tracking in Page on your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct UsageWidgetView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    private var model: UsageCardModel? { UsageCardModel(entry.status?.usage, now: entry.date) }

    var body: some View {
        Group {
            if let m = model, family == .accessoryCircular || family == .accessoryRectangular {
                if family == .accessoryCircular { circular(m) } else { rectangular(m) }
            } else {
                NWWidgetUsageFace(model: model, problem: entry.problem, size: family == .systemSmall ? .small : .medium, now: entry.date)
            }
        }
        .environment(\.nwFixedPhase, 2.0)
    }

    private func circular(_ m: UsageCardModel) -> some View {
        let g = m.fiveHour ?? m.sevenDay!
        return Gauge(value: g.fraction) {
            Text(g.label == "5-hour" ? "5h" : "7d")
        } currentValueLabel: {
            Text("\(Int(g.pct.rounded()))")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }

    private func rectangular(_ m: UsageCardModel) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach([m.fiveHour, m.sevenDay].compactMap { $0 }, id: \.label) { g in
                HStack(spacing: 4) {
                    Text(g.label == "5-hour" ? "5h" : "7d").font(.caption2.weight(.semibold)).frame(width: 18, alignment: .leading)
                    Gauge(value: g.fraction) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
                    Text("\(Int(g.pct.rounded()))%").font(.caption2).monospacedDigit()
                }
            }
            if let r = m.fiveHour?.resetsAt, r > entry.date {
                Text("5h resets \(r.formatted(date: .omitted, time: .shortened))").font(.system(size: 10))
            }
        }
    }
}
