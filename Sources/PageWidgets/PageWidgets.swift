import SwiftUI
import WidgetKit
import PageWidgetSupport

// Page's widgets for macOS: "Page" (who needs you, who is working, the runway)
// and "Claude usage" (the 5-hour and 7-day rings). The extension is sandboxed
// and only reads the snapshot the app writes into the shared app-group
// container (WidgetSnapshot); it never touches Page's files, the relay or the
// Keychain. The app asks WidgetKit to reload when the snapshot changes.

@main
struct PageWidgetBundle: WidgetBundle {
    var body: some Widget {
        PageStatusWidget()
        ClaudeUsageWidget()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// nil: Page has not written one yet ("Open Page to start").
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: WidgetFixtures.sample())
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let now = Date()
        completion(SnapshotEntry(date: now, snapshot: context.isPreview ? WidgetFixtures.sample(now: now) : Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = Self.load()
        var entries = [SnapshotEntry(date: now, snapshot: snapshot)]
        // The moment the numbers age out, the same widget says so by itself.
        if let s = snapshot, s.running, s.staleAt > now {
            entries.append(SnapshotEntry(date: s.staleAt.addingTimeInterval(1), snapshot: s))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }

    static func load() -> WidgetSnapshot? {
        guard let dir = WidgetSnapshotStore.containerURL() else { return nil }
        return WidgetSnapshotStore.load(from: dir)
    }
}

// MARK: - Container

extension View {
    /// The Night Watch backdrop as the widget's container background (macOS 14
    /// and later); before that, the same backdrop behind the content.
    @ViewBuilder
    func pageBackground(tone: WidgetTone, glow: Double) -> some View {
        if #available(macOS 14.0, *) {
            self.containerBackground(for: .widget) { WidgetBackdrop(tone: tone, glow: glow) }
        } else {
            self.padding(16).background(WidgetBackdrop(tone: tone, glow: glow))
        }
    }
}

// MARK: - Page

struct PageStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PageWidgetConstants.statusKind, provider: SnapshotProvider()) { entry in
            PageStatusEntryView(entry: entry)
                .pageBackground(tone: WidgetDisplay.tone(entry.snapshot, now: entry.date),
                                glow: entry.snapshot?.glowIntensity ?? 0)
                .widgetURL(WidgetRoute.now.url)
        }
        .configurationDisplayName(WidgetCatalog.status.name)
        .description(WidgetCatalog.status.detail)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct PageStatusEntryView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        PageStatusWidgetView(snapshot: entry.snapshot, size: size, now: entry.date)
    }

    private var size: WidgetFaceSize {
        switch family {
        case .systemMedium: return .medium
        case .systemLarge: return .large
        default: return .small
        }
    }
}

// MARK: - Claude usage

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: PageWidgetConstants.usageKind, provider: SnapshotProvider()) { entry in
            ClaudeUsageEntryView(entry: entry)
                .pageBackground(tone: WidgetDisplay.tone(entry.snapshot, now: entry.date),
                                glow: entry.snapshot?.glowIntensity ?? 0)
                .widgetURL(WidgetRoute.now.url)
        }
        .configurationDisplayName(WidgetCatalog.usage.name)
        .description(WidgetCatalog.usage.detail)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ClaudeUsageEntryView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ClaudeUsageWidgetView(snapshot: entry.snapshot, size: family == .systemMedium ? .medium : .small, now: entry.date)
    }
}
