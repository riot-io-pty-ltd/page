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

    /// The Card glow level after `--card-glow` (off, subtle, full); off without it.
    /// Pure.
    static func cardGlow(arguments: [String]) -> CardGlow {
        guard let i = arguments.firstIndex(of: "--card-glow"), arguments.indices.contains(i + 1),
              let level = CardGlow(rawValue: arguments[i + 1]) else { return .off }
        return level
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

    /// Renders through SwiftUI's own renderer, which (unlike `cacheDisplay`)
    /// captures Metal shader effects. It cannot draw AppKit-backed views (text
    /// fields, scroll views), so only surfaces without them use it.
    @discardableResult
    @MainActor
    static func renderImage<V: View>(_ view: V, width: CGFloat, height: CGFloat?, name: String, to dir: URL,
                                     scale: CGFloat = 2) -> URL? {
        guard #available(macOS 13, *) else { return nil }
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).frame(width: width, height: height))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        guard let cg = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = dir.appendingPathComponent(name + ".png")
        do { try png.write(to: url) } catch { return nil }
        return url
    }

    /// The argument after `flag`, if any. Pure.
    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), arguments.indices.contains(i + 1) else { return nil }
        return arguments[i + 1]
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
        let args = CommandLine.arguments
        let glow = cardGlow(arguments: args)
        TowerFixtures.cardGlow = glow
        // `--canvas`: every surface draws its Canvas fallback (what macOS 12/13 shows).
        NWShaders.forceCanvas = args.contains("--canvas")
        // `--live-check`: the panel on screen for a few seconds, gate and CPU printed.
        if args.contains("--live-check") { RenderLiveCheck.run() }
        // `--motion`: the signature-motion contact sheets instead of the still surfaces.
        let surfaces = args.contains("--motion") ? RenderSurfaces.motion() : RenderSurfaces.all()
        let only = value(after: "--only", in: args)
        for surface in surfaces where only.map({ surface.name.hasPrefix($0) }) ?? true {
            // One still frame per surface: pinned phase, so renders are deterministic
            // and double as the Reduce Motion fallback. Motion sheets pin each
            // frame's own clock instead.
            var view = AnyView(surface.view.environment(\.nwCardGlow, glow))
            if !surface.motion {
                view = AnyView(view.environment(\.nwFixedPhase, surface.phase).environment(\.nwReduceMotion, true))
            }
            let url: URL?
            switch surface.renderer {
            case .image:
                url = renderImage(view.environment(\.nwShaders, true), width: surface.width, height: surface.height,
                                  name: surface.name, to: dir)
            case .cache:
                // cacheDisplay can't capture shaders: these renders use the Canvas drawing.
                let still = view.environment(\.nwShaders, false)
                if let height = surface.height {
                    url = render(still, size: CGSize(width: surface.width, height: height), name: surface.name, to: dir)
                } else {
                    url = renderFitting(still, width: surface.width, name: surface.name, to: dir)
                }
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
        enum Renderer { case cache, image }
        let name: String
        let width: CGFloat
        var phase: Double = 3.0
        /// A fixed height (windows with a scroll view); nil fits the content.
        var height: CGFloat? = nil
        /// `.image` goes through ImageRenderer, which captures Metal shaders.
        var renderer: Renderer = .cache
        /// A motion sheet: its frames pin their own clocks (no forced still frame).
        var motion = false
        let view: AnyView
    }

    /// A surface on the stand-in wallpaper, with room around it.
    @MainActor
    private static func onBackdrop<V: View>(_ v: V, pad: CGFloat = 28) -> AnyView {
        AnyView(v.padding(pad).background(NWBackdrop()))
    }

    /// `tip`: a first-run panel (the tip not yet dismissed). Every other surface has seen it.
    /// The preferences are a throwaway suite: the harness never touches the real app's defaults.
    @MainActor
    private static func store(_ inputs: NowInputs, select: String? = nil, tip: Bool = false) -> NowStore {
        let prefs = NowPrefs.ephemeral()
        prefs.tipDismissed = !tip
        let st = NowStore(model: NowModel.build(inputs), prefs: prefs)
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

        // One waiting, two in flight: collapsed, pointed at, composing, receipts, the shortcuts, first run.
        let flightInputs = NightWatchFixtures.oneWaitingTwoInFlight()
        let pageRow = InFlightRow.idPrefix + "sess-page"
        let flightRest = store(flightInputs)
        let flightCollapsed = store(flightInputs)
        flightCollapsed.setInFlightCollapsed(true)
        let flightHover = store(flightInputs)
        flightHover.hoverFlight(pageRow)
        let flightComposer = store(flightInputs)
        flightComposer.hoverFlight(pageRow)
        flightComposer.handle(NowKeyPress(key: .char("t")))
        flightComposer.composerText = "also run the Terminals tests"
        let flightDigit = store(flightInputs)
        flightDigit.hoverFlight(pageRow)
        flightDigit.handle(NowKeyPress(key: .char("t")))
        flightDigit.composerText = "2 more cases please"
        let flightQueued = store(flightInputs)
        flightQueued.hoverFlight(pageRow)
        flightQueued.previewFlightReceipt(InFlightReceipt(outcome: .queued, route: "cmux › page", at: flightInputs.now),
                                          forSessionId: "sess-page")
        let flightTyped = store(flightInputs)
        flightTyped.hoverFlight(pageRow)
        flightTyped.previewFlightReceipt(InFlightReceipt(outcome: .typed, route: "cmux › page", at: flightInputs.now),
                                         forSessionId: "sess-page")
        let flightRefused = store(flightInputs)
        flightRefused.hoverFlight(pageRow)
        flightRefused.previewFlightReceipt(
            InFlightReceipt(outcome: .refused("A prompt is waiting — answer it first"), route: "cmux › page", at: flightInputs.now),
            forSessionId: "sess-page")
        let flightBlockedInputs = NightWatchFixtures.oneWaitingTwoInFlight(blocked: true)
        let flightBlocked = store(flightBlockedInputs)
        flightBlocked.hoverFlight(InFlightRow.idPrefix + "sess-payments-api")
        let flightLocal = store(flightBlockedInputs)
        flightLocal.setInFlightExpanded(true)   // the local row sits past the compact list
        flightLocal.hoverFlight(InFlightRow.idPrefix + "local-ollama")
        let flightMore = store(flightBlockedInputs)
        flightMore.setInFlightCollapsed(false)
        let flightKeys = store(flightInputs)
        flightKeys.select(flightInputs.snapshot.pendingInterventions[0].id)
        flightKeys.handle(NowKeyPress(key: .down))
        let flightSheet = store(flightInputs)
        flightSheet.toggleShortcuts()
        let flightFirstRun = store(flightInputs, tip: true)
        let flightDecisionSelected = store(flightInputs, select: flightInputs.snapshot.pendingInterventions[0].id)
        var flightQuietInputs = NightWatchFixtures.allQuiet()
        flightQuietInputs.hosts = flightInputs.hosts
        let flightQuiet = store(flightQuietInputs)
        flightQuiet.hoverFlight(InFlightRow.idPrefix + "sess-page")

        let quiet = store(NightWatchFixtures.allQuiet())
        let paused = store(NightWatchFixtures.pausedForBattery())
        let pausedWithRows = store(NightWatchFixtures.pausedForBattery(
            waiting: Array(needsInputs.snapshot.pendingInterventions.prefix(2))))
        let battery = store(NightWatchFixtures.onBattery())
        let starting = NowStore(model: NowModel.starting(macName: "Studio MBP"), prefs: .ephemeral())

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
            Surface(name: "popover-inflight-rest", width: w, view: onBackdrop(NWNowPopover(store: flightRest))),
            Surface(name: "popover-inflight-collapsed", width: w, view: onBackdrop(NWNowPopover(store: flightCollapsed))),
            Surface(name: "popover-inflight-hover", width: w, view: onBackdrop(NWNowPopover(store: flightHover))),
            Surface(name: "popover-inflight-composer", width: w, view: onBackdrop(NWNowPopover(store: flightComposer))),
            Surface(name: "popover-inflight-composer-digit", width: w, view: onBackdrop(NWNowPopover(store: flightDigit))),
            Surface(name: "popover-inflight-receipt-queued", width: w, view: onBackdrop(NWNowPopover(store: flightQueued))),
            Surface(name: "popover-inflight-receipt-typed", width: w, view: onBackdrop(NWNowPopover(store: flightTyped))),
            Surface(name: "popover-inflight-receipt-refused", width: w, view: onBackdrop(NWNowPopover(store: flightRefused))),
            Surface(name: "popover-inflight-blocked", width: w, view: onBackdrop(NWNowPopover(store: flightBlocked))),
            Surface(name: "popover-inflight-local", width: w, view: onBackdrop(NWNowPopover(store: flightLocal))),
            Surface(name: "popover-inflight-more", width: w, view: onBackdrop(NWNowPopover(store: flightMore))),
            Surface(name: "popover-inflight-keys", width: w, view: onBackdrop(NWNowPopover(store: flightKeys))),
            Surface(name: "popover-inflight-shortcuts", width: w, view: onBackdrop(NWNowPopover(store: flightSheet))),
            Surface(name: "popover-inflight-first-run", width: w, view: onBackdrop(NWNowPopover(store: flightFirstRun))),
            Surface(name: "popover-inflight-decision-selected", width: w, view: onBackdrop(NWNowPopover(store: flightDecisionSelected))),
            Surface(name: "popover-inflight-all-quiet", width: w, view: onBackdrop(NWNowPopover(store: flightQuiet))),
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
        ] + towerSurfaces() + legacySurfaces() + inFlightSurfaces() + [
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
        for section in [TowerSection.power, .budget, .macsPhones, .attention, .agents, .terminals] {
            out.append(Surface(name: "tower-\(section.rawValue)-tall", width: w + pad * 2, height: 1500 + pad * 2,
                               view: window(TowerFixtures.store(section: section), height: 1500)))
        }
        // The Terminals page before the first probe answers, and after setup: all good with a notice.
        let checking = TowerFixtures.store(section: .terminals)
        checking.preview(terminalsUnprobed: true)
        out.append(Surface(name: "tower-terminals-checking", width: w + pad * 2, height: h + pad * 2, view: window(checking)))
        let good = TowerFixtures.store(section: .terminals)
        var goodFacts = TowerFixtures.terminals()
        goodFacts.facts[.iTerm] = TerminalCatalog.Facts(installed: true, use: .init(typable: 1), setup: .done)
        goodFacts.facts[.cmux] = TerminalCatalog.Facts(installed: true, use: .init(typable: 2), setup: .done)
        goodFacts.facts[.kitty] = TerminalCatalog.Facts(installed: true, use: .init(typable: 1), setup: .done)
        goodFacts.pageAddedKittyLines = true
        good.preview(terminals: goodFacts, terminalNotice: TowerStatusLine(text: "Added to /Users/studio/.config/kitty/kitty.conf. Restart kitty to turn it on. Your old file is saved as kitty.conf.bak-page-20261027-091500.", tone: .good))
        out.append(Surface(name: "tower-terminals-good", width: w + pad * 2, height: h + pad * 2, view: window(good)))
        // kitty.conf has Page's lines but the running kitty hasn't been restarted; one wezterm window works, one doesn't.
        let restart = TowerFixtures.store(section: .terminals)
        var restartFacts = TowerFixtures.terminals()
        restartFacts.facts[.terminal] = TerminalCatalog.Facts(installed: true, use: .init(), setup: .done)
        restartFacts.facts[.kitty] = TerminalCatalog.Facts(installed: true, use: .init(typable: 0, blocked: 1, blocker: KittyBridge.remoteControlHint), setup: .done)
        restartFacts.facts[.wezterm] = TerminalCatalog.Facts(installed: true, use: .init(typable: 1, blocked: 1, blocker: "WezTerm’s command-line tool didn’t answer"), setup: .notNeeded)
        restartFacts.pageAddedKittyLines = true
        restart.preview(terminals: restartFacts)
        out.append(Surface(name: "tower-terminals-restart", width: w + pad * 2, height: h + pad * 2, view: window(restart)))
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
