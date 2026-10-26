import AppKit
import SwiftUI

// macOS PROXY renderer for the Night Watch views. When no iOS Simulator
// runtime is installed, this draws the same SwiftUI views (RenderHarnessRoot,
// built from the real Page/Design and Page/Models sources) into PNGs with
// AppKit, at an iPhone 15 Pro's point size. It is a stand-in, not the app:
// no UIKit behaviour, system fonts resolve to the macOS SF, and safe areas
// are not applied. Usage: render-proxy-macos.sh <out-dir> [screen...].

@MainActor
func render(_ args: RenderArguments, size: CGSize, to url: URL) {
    let host = NSHostingView(rootView: RenderHarnessRoot(args: args).environment(\.colorScheme, .dark))
    host.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    host.layoutSubtreeIfNeeded()
    host.display()
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = size
    host.cacheDisplay(in: host.bounds, to: rep)
    if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { print("usage: render-proxy <out-dir> [screen[:glow]...]"); exit(2) }
let out = URL(fileURLWithPath: argv[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let requested = Array(argv.dropFirst(2))
let screens = requested.isEmpty ? RenderHarness.screens : requested

MainActor.assumeIsolated {
    _ = NSApplication.shared
    for entry in screens {
        let parts = entry.split(separator: ":").map(String.init)
        let name = parts[0]
        let glows: [CardGlow] = parts.count > 1 ? [CardGlow(argument: parts[1]) ?? .off] : [.off, .subtle, .full]
        // Tall screens get the whole scroll content in one frame.
        let h: CGFloat = name.hasPrefix("now") ? 2200 : (name.hasPrefix("tower") ? 2300 : (name == "settled" || name == "gallery" ? 1400 : 852))
        for g in glows {
            let a = RenderArguments(screen: name, glow: g)
            render(a, size: CGSize(width: 393, height: h), to: out.appendingPathComponent("\(name)-glow-\(g.rawValue).png"))
            print("rendered \(name) glow=\(g.rawValue)")
        }
    }
}
