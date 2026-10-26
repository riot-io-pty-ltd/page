import AppKit
import SwiftUI

/// Side-effect-free renderer for the new UI: `ClaudePowerMode --render-ui <dir>`
/// draws every surface with fixture data to PNGs (dark, 2x) and exits. It runs
/// before anything else in main.swift, so no Coordinator, config, backend,
/// relay, hook or notification code is ever touched.
enum RenderHarness {
    static let flag = "--render-ui"

    /// The directory after `--render-ui`, if the flag is present.
    /// Pure.
    static func outputDirectory(arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
    }

    /// Renders a SwiftUI view to `<dir>/<name>.png` at `scale`x. Returns the path.
    @discardableResult
    @MainActor
    static func render<V: View>(_ view: V, size: CGSize, name: String, to dir: URL, scale: CGFloat = 2) -> URL? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI finish its first layout / drawing pass.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        host.display()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = dir.appendingPathComponent(name + ".png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    /// Renders at the view's natural height for `width`.
    @discardableResult
    @MainActor
    static func renderFitting<V: View>(_ view: V, width: CGFloat, name: String, to dir: URL, scale: CGFloat = 2) -> URL? {
        let probe = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        probe.frame = CGRect(x: 0, y: 0, width: width, height: 10)
        probe.layoutSubtreeIfNeeded()
        let fit = probe.fittingSize
        return render(view, size: CGSize(width: width, height: max(10, ceil(fit.height))), name: name, to: dir, scale: scale)
    }

    /// Entry point from main.swift. Never returns.
    @MainActor
    static func run(outputDirectory path: String) -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let dir = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var failures = 0
        for surface in RenderSurfaces.all() {
            // One still frame per surface: pinned phase, so renders are deterministic
            // and double as the Reduce Motion fallback.
            let view = surface.view
                .environment(\.nwFixedPhase, surface.phase)
                .environment(\.nwReduceMotion, true)
            let url: URL?
            if let height = surface.height {
                url = render(view, size: CGSize(width: surface.width, height: height), name: surface.name, to: dir)
            } else {
                url = renderFitting(view, width: surface.width, name: surface.name, to: dir)
            }
            if let url {
                print("rendered \(url.path)")
            } else {
                print("FAILED \(surface.name)")
                failures += 1
            }
        }
        exit(failures == 0 ? 0 : 1)
    }
}

/// The surfaces the harness renders. Later stages append theirs.
enum RenderSurfaces {
    struct Surface {
        let name: String
        let width: CGFloat
        var phase: Double = 3.0
        /// A fixed height (windows with a scroll view); nil fits the content.
        var height: CGFloat? = nil
        let view: AnyView
    }

    /// A surface on the stand-in wallpaper, with room around it.
    @MainActor
    private static func onBackdrop<V: View>(_ v: V, pad: CGFloat = 28) -> AnyView {
        AnyView(v.padding(pad).background(NWBackdrop()))
    }

    @MainActor
    private static func store(_ inputs: NowInputs, select: String? = nil) -> NowStore {
        let st = NowStore(model: NowModel.build(inputs))
        // The harness pins the clock so holds and receipts are deterministic.
        st.now = { inputs.now }
        if let select { st.select(select) }
        return st
    }

    @MainActor
    static func all() -> [Surface] {
        let needsInputs = NightWatchFixtures.needsYou()
        let w = NightWatch.Space.popoverWidth + 56
        let rings = NightWatchFixtures.allQuiet().day?.rings ?? []

        // Opens with nothing selected, as it does live.
        let needs = store(needsInputs)
        let selected = store(needsInputs, select: "sess-bottle-flip-permission-\(Int(needsInputs.snapshot.pendingInterventions[0].openedAt.timeIntervalSince1970))")
        let composer = store(needsInputs, select: needsInputs.snapshot.pendingInterventions[1].id)
        composer.handle(NowKeyPress(key: .char("t")))
        composer.composerText = "use the in-memory store for this"
        let holding = store(needsInputs, select: needsInputs.snapshot.pendingInterventions[0].id)
        holding.previewHold(.approve(rowId: needsInputs.snapshot.pendingInterventions[0].id), progress: 0.82)
        let stopping = store(needsInputs)
        stopping.previewHold(.stopAll, progress: 0.5)
        let failed = store(NightWatchFixtures.needsYouWithFailedReceipt())
        let overflow = store(NightWatchFixtures.manyPages(), select: NightWatchFixtures.manyPages().snapshot.pendingInterventions[4].id)
        overflow.setExpanded(true)
        var configInputs = NightWatchFixtures.needsYou()
        configInputs.snapshot = NightWatchFixtures.snapshot(
            sessions: NightWatchFixtures.working5, pending: needsInputs.snapshot.pendingInterventions,
            configProblem: "values corrected")
        let configProblem = store(configInputs)
        let stopped = store(NightWatchFixtures.allQuiet())
        stopped.notice = NowStore.Notice(text: "Stopped 5 agents", failed: false)

        let quiet = store(NightWatchFixtures.allQuiet())
        let paused = store(NightWatchFixtures.pausedForBattery())
        let pausedWithRows = store(NightWatchFixtures.pausedForBattery(
            waiting: Array(needsInputs.snapshot.pendingInterventions.prefix(2))))
        let battery = store(NightWatchFixtures.onBattery())
        let starting = NowStore(model: NowModel.starting(macName: "Studio MBP"))

        let calm = WelcomeBack.build(away: 52 * 60, finished: 2, needYou: 0, handledOnPhone: 0, rings: rings)
        let amber = WelcomeBack.build(away: 52 * 60, finished: 2, needYou: 1, handledOnPhone: 0, rings: rings)
        let phone = WelcomeBack.build(away: 112 * 60, finished: 0, needYou: 0, handledOnPhone: 6, rings: rings)

        let dispatch = DispatchStore(model: DispatchModel(
            prompt: "Make History collapse into Settled days in Now",
            folders: NightWatchFixtures.folders, folderIndex: 0))
        let dispatchFailed = DispatchStore(model: DispatchModel(
            prompt: "Add a dark mode to the settings", folders: NightWatchFixtures.folders, folderIndex: 1,
            phase: .failed("Starting a session needs cmux, and it isn't installed on your Mac")))

        return [
            Surface(name: "popover-needs-you", width: w, view: onBackdrop(NWNowPopover(store: needs))),
            Surface(name: "popover-selected", width: w, view: onBackdrop(NWNowPopover(store: selected))),
            Surface(name: "popover-composer", width: w, view: onBackdrop(NWNowPopover(store: composer))),
            Surface(name: "popover-hold", width: w, view: onBackdrop(NWNowPopover(store: holding))),
            Surface(name: "popover-stop-hold", width: w, view: onBackdrop(NWNowPopover(store: stopping))),
            Surface(name: "popover-failed-receipt", width: w, view: onBackdrop(NWNowPopover(store: failed))),
            Surface(name: "popover-overflow", width: w, view: onBackdrop(NWNowPopover(store: overflow))),
            Surface(name: "popover-config-problem", width: w, view: onBackdrop(NWNowPopover(store: configProblem))),
            Surface(name: "popover-all-quiet", width: w, view: onBackdrop(NWNowPopover(store: quiet))),
            Surface(name: "popover-stopped", width: w, view: onBackdrop(NWNowPopover(store: stopped))),
            Surface(name: "popover-paused", width: w, view: onBackdrop(NWNowPopover(store: paused))),
            Surface(name: "popover-paused-waiting", width: w, view: onBackdrop(NWNowPopover(store: pausedWithRows))),
            Surface(name: "popover-on-battery", width: w, view: onBackdrop(NWNowPopover(store: battery))),
            Surface(name: "popover-starting", width: w, view: onBackdrop(NWNowPopover(store: starting))),
            Surface(name: "dispatch", width: 560 + 56, view: onBackdrop(NWDispatchView(store: dispatch))),
            Surface(name: "dispatch-failed", width: 560 + 56, view: onBackdrop(NWDispatchView(store: dispatchFailed))),
            Surface(name: "welcome-back", width: 380 + 56, view: onBackdrop(NWWelcomeBackView(model: amber))),
            Surface(name: "welcome-back-calm", width: 380 + 56, view: onBackdrop(NWWelcomeBackView(model: calm))),
            Surface(name: "welcome-back-phone", width: 380 + 56, view: onBackdrop(NWWelcomeBackView(model: phone))),
        ] + towerSurfaces() + [
            Surface(name: "components", width: 760, view: AnyView(NWComponentSheet())),
            Surface(name: "glyphs", width: 1140, view: AnyView(NWGlyphSheet()))
        ]
    }

    /// Every Tower section, in the board's window size, plus taller renders
    /// of the pages that scroll and a few unusual states.
    @MainActor
    private static func towerSurfaces() -> [Surface] {
        let pad: CGFloat = 28
        let w = NWTowerWindow.size.width, h = NWTowerWindow.size.height
        func window(_ store: TowerStore, height: CGFloat = h) -> AnyView {
            AnyView(NWTowerWindow(store: store, height: height).padding(pad).background(NWBackdrop()))
        }
        var out: [Surface] = []
        for section in TowerSection.allCases {
            out.append(Surface(name: "tower-\(section.rawValue)", width: w + pad * 2, height: h + pad * 2,
                               view: window(TowerFixtures.store(section: section))))
        }
        for section in [TowerSection.power, .budget, .macsPhones, .attention, .agents] {
            out.append(Surface(name: "tower-\(section.rawValue)-tall", width: w + pad * 2, height: 1500 + pad * 2,
                               view: window(TowerFixtures.store(section: section), height: 1500)))
        }
        // Plugged in, values no preset matches, helper missing.
        out.append(Surface(name: "tower-power-ac-custom-tall", width: w + pad * 2, height: 1500 + pad * 2,
                           view: window(TowerFixtures.acCustom(section: .power), height: 1500)))
        // Relay misconfigured, no usage captured.
        var bad = TowerFixtures.boardConfig()
        bad.relayURL = "http://example.com"
        let badStore = TowerFixtures.store(section: .macsPhones, config: bad)
        badStore.preview(usageCapture: TowerStore.UsageCaptureStatus(on: false), problem: "relayURL: Use https:// — plain http would send your pairing token unencrypted.")
        out.append(Surface(name: "tower-macs-phones-problem", width: w + pad * 2, height: h + pad * 2, view: window(badStore)))
        let empty = TowerFixtures.store(section: .budget, scene: (NightWatchFixtures.snapshot(), NowModel.starting(macName: "Studio MBP")))
        empty.preview(usageCapture: TowerStore.UsageCaptureStatus(on: false))
        out.append(Surface(name: "tower-budget-empty", width: w + pad * 2, height: h + pad * 2, view: window(empty)))
        return out
    }
}
