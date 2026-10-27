import SwiftUI
import PageWidgetSupport

private typealias P = NightWatch.Palette

// MARK: - The words (pure)

/// The steps the Widgets page draws. macOS gives an app no way to place a
/// widget: the user drags it out of the widget gallery. So Page gets everything
/// ready (the extension, the data, the preview) and makes the last step obvious.
enum WidgetGuide {
    struct Step: Equatable, Identifiable {
        var number: Int
        var title: String
        var detail: String
        var id: Int { number }
    }

    /// Pure. The steps for this macOS: desktop widgets from macOS 14, Notification Center only before.
    static func steps(osMajor: Int) -> [Step] {
        if WidgetRegistration.hasDesktopWidgets(osMajor: osMajor) {
            return [
                Step(number: 1, title: "Right-click the desktop",
                     detail: "On an empty spot (or hold Control and click), then choose Edit Widgets."),
                Step(number: 2, title: "Search for Page",
                     detail: "Type Page in the search field. Page and Claude usage show up, each in a few sizes."),
                Step(number: 3, title: "Drag one out",
                     detail: "Drag it onto the desktop, or click the + on it. Put it anywhere: it keeps itself up to date."),
            ]
        }
        return [
            Step(number: 1, title: "Open Notification Center",
                 detail: "Click the date and time at the right of the menu bar."),
            Step(number: 2, title: "Click Edit Widgets",
                 detail: "It is at the bottom of the panel. Type Page in the search field."),
            Step(number: 3, title: "Add one",
                 detail: "Click the + on Page or Claude usage, or drag it into the panel."),
        ]
    }

    /// Pure. The other place, for macOS 14 and later.
    static func notificationCenterLine(osMajor: Int) -> String? {
        WidgetRegistration.hasDesktopWidgets(osMajor: osMajor)
            ? "Or in Notification Center: click the date and time in the menu bar, then Edit Widgets at the bottom."
            : nil
    }

    /// Pure. The iPhone note: only macOS 14 and later can show iPhone widgets.
    static func iPhoneNote(osMajor: Int) -> String? {
        guard WidgetRegistration.hasDesktopWidgets(osMajor: osMajor) else { return nil }
        return "Your iPhone’s Page widgets can also appear on this Mac. In \(WidgetRegistration.settingsPath(osMajor: osMajor)), turn on “Use iPhone widgets” (the iPhone has to be nearby and signed in to the same Apple ID). They show what your iPhone knows. Page’s own Mac widgets above work without it."
    }

    /// Pure. The line under "Show me how".
    static func addDetail(osMajor: Int) -> String {
        WidgetRegistration.hasDesktopWidgets(osMajor: osMajor)
            ? "macOS only lets you place a widget yourself, so Page gets everything ready and shows you the three steps."
            : "macOS only lets you place a widget yourself, so Page gets everything ready and shows you the three steps. Before macOS 14 widgets live in Notification Center."
    }

    /// Pure. The line under "Widget settings", or nil when this macOS has no such switches (before macOS 14).
    static func settingsDetail(osMajor: Int) -> String? {
        guard WidgetRegistration.hasDesktopWidgets(osMajor: osMajor) else { return nil }
        return "System Settings has the switches for showing widgets on the desktop and for using your iPhone’s widgets. You can’t add a widget there."
    }
}

// MARK: - Page

struct NWWidgetsPage: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        let os = store.env.osMajor
        NWPage(section: .widgets) {
            NWCard(title: "SET UP") {
                NWWidgetStatusRow(store: store)
                NWDivider()
                NWRow(title: "Add them to your Mac", detail: WidgetGuide.addDetail(osMajor: os)) {
                    NWButton(title: store.widgetGuideOpen ? "Hide the steps" : "Show me how", kind: .primary) { store.toggleWidgetGuide() }
                }
                if let detail = WidgetGuide.settingsDetail(osMajor: os) {
                    NWDivider()
                    NWRow(title: "Desktop and iPhone widgets", detail: detail) {
                        NWButton(title: "Widget settings", kind: .secondary) { store.openWidgetSettings() }
                    }
                }
            }
            if store.widgetGuideOpen {
                NWWidgetGuideCard(osMajor: os, snapshot: store.widgetPreviewSnapshot, now: store.now(), timeZone: store.timeZone)
            }
            NWWidgetPreviews(store: store)
            if let note = WidgetGuide.iPhoneNote(osMajor: os) {
                NWNote(text: note).padding(.horizontal, 4)
            }
        }
    }
}

/// "macOS sees Page's widgets", or what is wrong and the one button for it.
struct NWWidgetStatusRow: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        let status = store.widgetStatus
        let line = WidgetRegistration.line(status)
        let tint: NightWatch.RGBA = line.good ? P.green : (status == .checking ? P.textSecondary : P.amber)
        HStack(spacing: 12) {
            Image(systemName: line.good ? "checkmark.circle.fill" : (status == .checking ? "circle.dotted" : "exclamationmark.triangle.fill"))
                .font(Font.system(size: 15, weight: .medium))
                .foregroundColor(tint.color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.text)
                    .font(Font.system(size: 13.5, weight: .semibold))
                    .foregroundColor(P.textPrimary.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = Self.hint(status) {
                    Text(hint)
                        .font(Font.system(size: 11.5))
                        .foregroundColor(P.textTertiary.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if Self.canRegister(status) {
                NWButton(title: store.widgetRegistering ? "Asking…" : "Ask macOS to find them", kind: .secondary,
                         enabled: !store.widgetRegistering) { store.registerWidgets() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 60)
    }

    /// Pure. The buttons that can fix the state.
    static func canRegister(_ s: WidgetRegistration.Status) -> Bool {
        switch s {
        case .notRegistered, .elsewhere: return true
        default: return false
        }
    }

    /// Pure. What to do when it is not fine.
    static func hint(_ s: WidgetRegistration.Status) -> String? {
        switch s {
        case .notRegistered: return "Page asks on every launch. If it still isn’t found, move Page.app into /Applications and open it once."
        case .elsewhere: return "Move or delete the other copy, then ask again."
        case .disabled: return "Switch Page’s widgets back on there, and they appear in the gallery."
        case .unavailable(let reason):
            switch reason {
            case WidgetSetup.Unavailable.notAnApp: return "Open the installed Page (in Applications) to get the widgets."
            case WidgetSetup.Unavailable.noExtension: return "This build doesn’t include the widget extension. Update Page to a build that has it."
            case WidgetSetup.Unavailable.noTeam: return "Widgets need a copy of Page signed with an Apple developer certificate. This copy isn’t, so it can’t have them."
            case WidgetSetup.Unavailable.noAnswer: return "Open this page again in a moment."
            default: return nil
            }
        case .checking, .registered: return nil
        }
    }
}

// MARK: - Previews

/// Every widget in every size, drawn by the widgets' own views.
struct NWWidgetPreviews: View {
    @ObservedObject var store: TowerStore

    var body: some View {
        let snapshot = store.widgetPreviewSnapshot
        let now = store.now()
        let tz = store.timeZone
        let tone = WidgetDisplay.tone(snapshot, now: now)
        let glow = snapshot.glowIntensity
        VStack(alignment: .leading, spacing: 12) {
            Text("WHAT YOU’LL GET").nwLabel().padding(.leading, 4)
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 24) {
                        captioned("Page · Small") {
                            WidgetPreviewFrame(size: .small, tone: tone, glow: glow) {
                                PageStatusWidgetView(snapshot: snapshot, size: .small, now: now, timeZone: tz, interactive: false)
                            }
                        }
                        captioned("Claude usage · Small") {
                            WidgetPreviewFrame(size: .small, tone: tone, glow: glow) {
                                ClaudeUsageWidgetView(snapshot: snapshot, size: .small, now: now, timeZone: tz)
                            }
                        }
                    }
                    captioned("Page · Medium") {
                        WidgetPreviewFrame(size: .medium, tone: tone, glow: glow) {
                            PageStatusWidgetView(snapshot: snapshot, size: .medium, now: now, timeZone: tz, interactive: false)
                        }
                    }
                    captioned("Claude usage · Medium") {
                        WidgetPreviewFrame(size: .medium, tone: tone, glow: glow) {
                            ClaudeUsageWidgetView(snapshot: snapshot, size: .medium, now: now, timeZone: tz)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    captioned("Page · Large") {
                        WidgetPreviewFrame(size: .large, tone: tone, glow: glow) {
                            PageStatusWidgetView(snapshot: snapshot, size: .large, now: now, timeZone: tz, interactive: false)
                        }
                    }
                    HStack(spacing: 10) {
                        Text(store.widgetPreviewsExample ? "Example data" : "Your Mac right now")
                            .font(Font.system(size: 11.5, weight: .medium)).foregroundColor(P.textTertiary.color)
                        Spacer(minLength: 0)
                        NWButton(title: store.widgetPreviewsExample ? "Show my Mac" : "Show an example", kind: .quiet) {
                            store.widgetPreviewsExample.toggle()
                        }
                    }
                    .frame(width: CGFloat(WidgetFaceSize.large.points.width))
                    NWNote(text: "Click a widget to open Page’s popover. On the large one, click a row to land on that page. Widgets show what Page shows in its popover, with secrets masked; nothing else leaves Page.")
                        .frame(width: CGFloat(WidgetFaceSize.large.points.width), alignment: .leading)
                }
            }
        }
    }

    private func captioned<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
            Text(title).font(Font.system(size: 11.5, weight: .medium)).foregroundColor(P.textTertiary.color).padding(.leading, 4)
        }
    }
}

// MARK: - Show me how

/// Three small pictures and the words under them: the right-click, the search, the drag.
struct NWWidgetGuideCard: View {
    var osMajor: Int
    var snapshot: WidgetSnapshot
    var now: Date
    var timeZone: TimeZone

    var body: some View {
        let steps = WidgetGuide.steps(osMajor: osMajor)
        let desktop = WidgetRegistration.hasDesktopWidgets(osMajor: osMajor)
        NWCard(title: "SHOW ME HOW") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: 8) {
                            illustration(step.number, desktop: desktop)
                                .frame(height: 124)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.10)))
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("\(step.number)")
                                    .font(Font.system(size: 11, weight: .bold))
                                    .foregroundColor(Color(red: 0.02, green: 0.10, blue: 0.10))
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(P.teal.color))
                                Text(step.title).font(Font.system(size: 13, weight: .semibold)).foregroundColor(P.textPrimary.color)
                            }
                            Text(step.detail).font(Font.system(size: 11.5)).foregroundColor(P.textTertiary.color)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let line = WidgetGuide.notificationCenterLine(osMajor: osMajor) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock").font(Font.system(size: 12)).foregroundColor(P.textSecondary.color)
                        Text(line).font(Font.system(size: 11.5)).foregroundColor(P.textSecondary.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: pictures

    @ViewBuilder
    private func illustration(_ n: Int, desktop: Bool) -> some View {
        switch n {
        case 1: desktop ? AnyView(contextMenuPicture) : AnyView(menuBarPicture)
        case 2: AnyView(galleryPicture)
        default: AnyView(dragPicture)
        }
    }

    private var wallpaper: some View {
        LinearGradient(colors: [P.violet.opacity(0.30).color, P.sky.opacity(0.16).color, P.background.color],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Right-click on the desktop: the menu with Edit Widgets lit.
    private var contextMenuPicture: some View {
        ZStack(alignment: .topLeading) {
            wallpaper
            VStack(alignment: .leading, spacing: 0) {
                menuRow("New Folder", lit: false)
                menuRow("Change Wallpaper…", lit: false)
                menuRow("Edit Widgets…", lit: true)
                menuRow("Use Stacks", lit: false)
            }
            .padding(4)
            .frame(width: 128)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.72)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            .offset(x: 34, y: 14)
            Image(systemName: "cursorarrow").font(Font.system(size: 16)).foregroundColor(.white)
                .shadow(color: .black.opacity(0.6), radius: 2).offset(x: 22, y: 8)
        }
    }

    private func menuRow(_ text: String, lit: Bool) -> some View {
        Text(text).font(Font.system(size: 9.5, weight: lit ? .semibold : .regular))
            .foregroundColor(lit ? Color(red: 0.02, green: 0.10, blue: 0.10) : P.textSecondary.color)
            .padding(.horizontal, 6).frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(lit ? P.teal.color : Color.clear))
    }

    /// Before macOS 14: the menu bar, with the clock lit.
    private var menuBarPicture: some View {
        ZStack(alignment: .topTrailing) {
            wallpaper
            HStack(spacing: 8) {
                Spacer()
                Image(systemName: "wifi").font(Font.system(size: 9))
                Text("Tue 9:41").font(Font.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(P.teal.opacity(0.9).color))
                    .foregroundColor(Color(red: 0.02, green: 0.10, blue: 0.10))
            }
            .foregroundColor(P.textSecondary.color)
            .padding(.horizontal, 8).frame(height: 20).background(Color.black.opacity(0.55))
        }
    }

    /// The gallery: a search field reading Page, and the two widgets as tiles.
    private var galleryPicture: some View {
        ZStack {
            P.background.color
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(Font.system(size: 9))
                    Text("Page").font(Font.system(size: 10, weight: .medium))
                    Spacer()
                }
                .foregroundColor(P.textPrimary.color)
                .padding(.horizontal, 7).frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.10)))
                HStack(spacing: 10) {
                    tile(AnyView(PageStatusWidgetView(snapshot: snapshot, size: .small, now: now, timeZone: timeZone, interactive: false)), "Page")
                    tile(AnyView(ClaudeUsageWidgetView(snapshot: snapshot, size: .small, now: now, timeZone: timeZone)), "Claude usage")
                }
            }
            .padding(10)
        }
    }

    private func tile(_ face: AnyView, _ name: String) -> some View {
        let tone = WidgetDisplay.tone(snapshot, now: now)
        return VStack(spacing: 3) {
            WidgetPreviewFrame(size: .small, tone: tone, glow: 0) { face }
                .scaleEffect(0.36, anchor: .topLeading)
                .frame(width: 61, height: 61)
            Text(name).font(Font.system(size: 8.5, weight: .medium)).foregroundColor(P.textSecondary.color).lineLimit(1)
        }
    }

    /// The drag: a dashed arrow from the gallery tile to a widget on the desktop.
    private var dragPicture: some View {
        let tone = WidgetDisplay.tone(snapshot, now: now)
        return ZStack(alignment: .topLeading) {
            wallpaper
            WidgetPreviewFrame(size: .small, tone: tone, glow: 0) {
                PageStatusWidgetView(snapshot: snapshot, size: .small, now: now, timeZone: timeZone, interactive: false)
            }
            .scaleEffect(0.42, anchor: .topLeading)
            .frame(width: 72, height: 72)
            .offset(x: 128, y: 16)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(P.teal.opacity(0.7).color, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .frame(width: 72, height: 72).offset(x: 128, y: 16)
            Image(systemName: "arrow.right").font(Font.system(size: 18, weight: .semibold)).foregroundColor(P.teal.color)
                .offset(x: 78, y: 42)
            Image(systemName: "hand.point.up.left.fill").font(Font.system(size: 14)).foregroundColor(.white)
                .shadow(color: .black.opacity(0.6), radius: 2).offset(x: 36, y: 44)
        }
    }
}
