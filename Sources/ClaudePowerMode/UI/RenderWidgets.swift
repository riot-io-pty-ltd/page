import SwiftUI
import PageWidgetSupport

/// Render-harness surfaces for the Widgets page (every status row, the guide, the older macOS) and the
/// widget faces themselves in every state. Fixture data only; nothing asks macOS anything.
extension RenderSurfaces {
    @MainActor
    static func widgetSurfaces() -> [Surface] {
        let pad: CGFloat = 28
        let w = NWTowerWindow.size.width, h = NWTowerWindow.size.height
        let now = NightWatchFixtures.boardNow()
        let appex = "/Applications/Page.app/Contents/PlugIns/PageWidgets.appex"
        func window(_ status: WidgetRegistration.Status, guide: Bool = false, os: Int = 14, example: Bool = false,
                    height: CGFloat = h) -> AnyView {
            let store = TowerFixtures.store(section: .widgets)
            store.env.osMajor = os
            store.preview(widgetStatus: status, widgetGuideOpen: guide, widgetPreviewsExample: example)
            return AnyView(NWTowerWindow(store: store, height: height).padding(pad).background(NWBackdrop()))
        }
        var out: [Surface] = []
        func tower(_ name: String, _ view: AnyView, height: CGFloat = h) {
            out.append(Surface(name: name, width: w + pad * 2, height: height + pad * 2, view: view))
        }
        tower("widgets-registered-guide", window(.registered(path: appex), guide: true, height: 1500), height: 1500)
        tower("widgets-registered", window(.registered(path: appex)))
        tower("widgets-disabled", window(.disabled(path: appex)))
        tower("widgets-not-registered", window(.notRegistered))
        tower("widgets-elsewhere", window(.elsewhere(path: "/Users/studio/projects/page/build/Page.app/Contents/PlugIns/PageWidgets.appex")))
        tower("widgets-unavailable-no-team", window(.unavailable(reason: WidgetSetup.Unavailable.noTeam)))
        tower("widgets-unavailable-build-folder", window(.unavailable(reason: WidgetSetup.Unavailable.notAnApp)))
        tower("widgets-macos13-guide", window(.registered(path: appex), guide: true, os: 13, height: 1500), height: 1500)

        // The faces: Small, Medium and Large of the Page widget and the two sizes of Claude usage, per state.
        let tz = TimeZone(identifier: "UTC") ?? .current
        func states() -> [(String, WidgetSnapshot?)] {
            var stale = WidgetFixtures.needsYou(now: now)
            stale.writtenAt = now.addingTimeInterval(-50 * 60)
            var quit = WidgetFixtures.working(now: now)
            quit.running = false
            // The reviewer's overflow case: 2 decisions, 4 working, one more working.
            var busy = WidgetFixtures.needsYou(now: now)
            busy.decisions = Array(busy.decisions.prefix(2)); busy.needYou = 2; busy.look = 0
            busy.inFlight = (1...4).map { .init(id: "f\($0)", project: ["harbor", "kestrel", "meadow", "quarry"][$0 - 1],
                                                 doing: $0 == 4 ? "" : "Bash: swift test --filter Suite\($0)") }
            busy.working = 5
            var many = WidgetFixtures.needsYou(now: now)
            many.needYou = 6; many.look = 2
            many.decisions = (1...5).map { .init(id: "d\($0)", project: "project-\($0)", chip: "considered", summary: "Edit src/file\($0).ts (+12 −3)") }
            many.inFlight = (1...5).map { .init(id: "f\($0)", project: "worker-\($0)", doing: "Reading \($0 * 3) files") }
            many.working = 9
            return [("needs you", WidgetFixtures.needsYou(now: now)), ("busy (overflow case)", busy), ("many", many),
                    ("working", WidgetFixtures.working(now: now)), ("quiet", WidgetFixtures.quiet(now: now)),
                    ("paused for battery", WidgetFixtures.dusk(now: now)), ("stale", stale), ("page not running", quit),
                    ("no snapshot yet", nil)]
        }
        for (index, entry) in states().enumerated() {
            let (label, snapshot) = entry
            let tone = WidgetDisplay.tone(snapshot, now: now)
            let glow = snapshot?.glowIntensity ?? 0
            func face(_ size: WidgetFaceSize, usage: Bool, caption: String) -> some View {
                VStack(alignment: .leading, spacing: 6) {
                    WidgetPreviewFrame(size: size, tone: tone, glow: glow) {
                        if usage {
                            ClaudeUsageWidgetView(snapshot: snapshot, size: size, now: now, timeZone: tz)
                        } else {
                            PageStatusWidgetView(snapshot: snapshot, size: size, now: now, timeZone: tz, interactive: false)
                        }
                    }
                    Text(caption).font(Font.system(size: 11.5, weight: .medium)).foregroundColor(.white.opacity(0.55))
                }
            }
            let sheet = VStack(alignment: .leading, spacing: 14) {
                Text("WIDGET FACES · \(label.uppercased())").font(Font.system(size: 11, weight: .heavy)).foregroundColor(.white.opacity(0.6))
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 18) {
                            face(.small, usage: false, caption: "Page · Small")
                            face(.small, usage: true, caption: "Claude usage · Small")
                        }
                        face(.medium, usage: false, caption: "Page · Medium")
                        face(.medium, usage: true, caption: "Claude usage · Medium")
                    }
                    face(.large, usage: false, caption: "Page · Large")
                }
            }
            .padding(24)
            .background(NWBackdrop())
            out.append(Surface(name: String(format: "widgets-faces-%02d", index + 1), width: 800, view: AnyView(sheet)))
        }

        out += widgetFitSurfaces(now: now, tz: tz, states: states())
        return out
    }

    /// Overflow check at the real desktop sizes. Each face is drawn inside its content rectangle (the cyan
    /// outline) and NOT clipped, so anything that would be cut off by the widget's edge sits outside the
    /// outline here. Vibrant sheets simulate the dimmed desktop: system grey backdrop, colour flattened.
    @MainActor
    static func widgetFitSurfaces(now: Date, tz: TimeZone, states: [(String, WidgetSnapshot?)]) -> [Surface] {
        var out: [Surface] = []
        let picks = ["needs you", "many", "busy (overflow case)", "working", "quiet", "paused for battery", "stale", "no snapshot yet"]
        func widget<Content: View>(_ w: CGFloat, _ h: CGFloat, margin: CGFloat, tone: WidgetTone, glow: Double, vibrant: Bool,
                                   caption: String, @ViewBuilder _ content: () -> Content) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    Group {
                        if vibrant {
                            LinearGradient(colors: [Color(white: 0.34), Color(white: 0.22)], startPoint: .top, endPoint: .bottom)
                        } else {
                            WidgetBackdrop(tone: tone, glow: glow)
                        }
                    }
                    .frame(width: w, height: h)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    content()
                        .padding(margin)
                        .frame(width: w, height: h, alignment: .topLeading)
                        .saturation(vibrant ? 0 : 1)
                    Rectangle().strokeBorder(Color.cyan.opacity(0.55), lineWidth: 1)
                        .frame(width: w - margin * 2, height: h - margin * 2)
                        .offset(x: margin, y: margin)
                    RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                        .frame(width: w, height: h)
                }
                .frame(width: w, height: h, alignment: .topLeading)
                Text(caption).font(Font.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.55))
            }
        }
        var index = 0
        for vibrant in [false, true] {
            for margin in [CGFloat(16), 12] where !(vibrant && margin == 12) {
                for label in picks {
                    guard let entry = states.first(where: { $0.0 == label }) else { continue }
                    if margin == 12 && label != "needs you" && label != "many" && label != "stale" { continue }
                    let snapshot = entry.1
                    let tone = WidgetDisplay.tone(snapshot, now: now)
                    let glow = snapshot?.glowIntensity ?? 0
                    let mode: WidgetFaceMode = vibrant ? .vibrant : .fullColor
                    func page(_ size: WidgetFaceSize, _ w: CGFloat, _ h: CGFloat) -> some View {
                        widget(w, h, margin: margin, tone: tone, glow: glow, vibrant: vibrant,
                               caption: "Page \(size.title) \(Int(w))x\(Int(h))") {
                            PageStatusWidgetView(snapshot: snapshot, size: size, now: now, timeZone: tz, interactive: false, mode: mode)
                        }
                    }
                    func usage(_ size: WidgetFaceSize, _ w: CGFloat, _ h: CGFloat) -> some View {
                        widget(w, h, margin: margin, tone: tone, glow: glow, vibrant: vibrant,
                               caption: "Usage \(size.title) \(Int(w))x\(Int(h))") {
                            ClaudeUsageWidgetView(snapshot: snapshot, size: size, now: now, timeZone: tz, mode: mode)
                        }
                    }
                    let sheet = VStack(alignment: .leading, spacing: 14) {
                        Text("FIT · \(label.uppercased()) · \(vibrant ? "VIBRANT" : "FULL COLOUR") · MARGIN \(Int(margin))")
                            .font(Font.system(size: 11, weight: .heavy)).foregroundColor(.white.opacity(0.6))
                        HStack(alignment: .top, spacing: 16) {
                            page(.small, 170, 170); page(.small, 158, 158); page(.medium, 364, 170); page(.medium, 329, 155)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            usage(.small, 170, 170); usage(.small, 158, 158); usage(.medium, 364, 170); usage(.medium, 329, 155)
                        }
                        HStack(alignment: .top, spacing: 16) {
                            page(.large, 364, 382); page(.large, 329, 345)
                        }
                    }
                    .padding(24)
                    .background(NWBackdrop())
                    index += 1
                    out.append(Surface(name: String(format: "widgets-fit-%02d-", index) + label.prefix(while: { $0 != " " }) +
                                       (vibrant ? "-vibrant" : "") + (margin == 12 ? "-m12" : ""),
                                       width: 1140, view: AnyView(sheet)))
                }
            }
        }
        return out
    }
}
