import AppKit
import SwiftUI

/// `--render-ui <dir> --live-check`: puts the Now panel on screen for a few
/// seconds, wired the way NowPanelController wires it (a non-activating
/// NWPanel, the motion gate, fixture data), and prints whether the gate let
/// the motion run and how much CPU each phase cost: shown and animating,
/// ordered out, and shown with nothing that moves. It runs inside the render
/// harness, so no Coordinator, session, hook or relay code is touched. Not
/// shipped behaviour; a check that the live path (Metal in a real window, the
/// occlusion gate, pausing when hidden) does what the offscreen renders can't
/// show.
enum RenderLiveCheck {
    @MainActor
    static func run() -> Never {
        NSApp.setActivationPolicy(.accessory)
        let store = NowStore(model: NowModel.build(NightWatchFixtures.needsYou()))
        let gate = NWMotionGate()
        let panel = NWPanel(allowsKey: false)
        let host = NSHostingView(rootView: AnyView(
            NWAppearanceRoot { NWMotionRoot(gate: gate) { NWNowPopover(store: store) } }.environment(\.colorScheme, .dark)))
        panel.contentView = host
        gate.attach(panel)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.place(content: host, width: NightWatch.Space.popoverWidth, centerX: screen.minX + 220,
                    top: screen.minY + 520, screen: NSScreen.main)

        func cpu() -> Double {
            var u = rusage()
            getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
                + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
        }
        func phase(_ name: String, seconds: Double) {
            let c0 = cpu(), t0 = Date()
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            let used = cpu() - c0, wall = Date().timeIntervalSince(t0)
            print(String(format: "live-check %@: gate.active=%@ visible=%@ occlusion=%lu cpu=%.1f%% (%.2fs cpu over %.2fs)",
                         name, gate.active ? "true" : "false", panel.isVisible ? "true" : "false",
                         panel.occlusionState.rawValue, 100 * used / wall, used, wall))
        }

        panel.orderFrontRegardless()
        store.animates = true
        gate.setShown(true)
        print("shaders usable: \(NWShaders.usable(true))")
        phase("shown, needs you (aurora + ripple)", seconds: 0.6)   // settle-in
        phase("shown, needs you (aurora + ripple)", seconds: 3)
        panel.orderOut(nil)
        gate.setShown(false)
        store.animates = false
        phase("ordered out", seconds: 3)
        store.update(NowModel.build(NightWatchFixtures.pausedForBattery()))
        panel.orderFrontRegardless()
        gate.setShown(true)
        phase("shown, paused (still dusk)", seconds: 0.6)
        phase("shown, paused (still dusk)", seconds: 2)
        panel.orderOut(nil)
        gate.setShown(false)
        exit(0)
    }
}
