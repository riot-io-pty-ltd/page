import SwiftUI
import Metal

// The clocks every Night Watch motion runs on, and the switches that stop
// them. Page's first promise is battery life, so: ambient motion (aurora,
// breath, ripple) ticks at most 30 times a second, a one-shot (approach,
// thread, exhale, dawn) at most 60 and only for its own length, and every
// timeline pauses while its surface can't be seen. Reduce Motion and the
// render harness get still frames.

private struct NWFixedNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

private struct NWMotionActiveKey: EnvironmentKey {
    static let defaultValue = true
}

private struct NWShadersKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// The render harness pins the clock: one-shot motions draw the frame at
    /// this instant (ambient ones use `nwFixedPhase`).
    var nwFixedNow: Date? {
        get { self[NWFixedNowKey.self] }
        set { self[NWFixedNowKey.self] = newValue }
    }
    /// False while the surface can't be seen (panel hidden or covered, screen
    /// asleep, another user session): every timeline pauses.
    var nwMotionActive: Bool {
        get { self[NWMotionActiveKey.self] }
        set { self[NWMotionActiveKey.self] = newValue }
    }
    /// Metal shaders may be used (they also need macOS 14 and a library that
    /// loaded). The harness turns them off for renders that can't capture them.
    var nwShaders: Bool {
        get { self[NWShadersKey.self] }
        set { self[NWShadersKey.self] = newValue }
    }
}

enum NWMotionRate {
    /// Continuous motion: aurora, breath, ripple.
    static let ambient: Double = 30
    /// Short one-shots (under ~1.5 s): approach, thread, burst.
    static let oneShot: Double = 60
}

/// Drives a one-shot motion: from `start` for `duration` seconds the content
/// gets the live time at up to 60 fps; after that it holds the end frame and
/// the timeline stops. With no `start`, under Reduce Motion or with the clock
/// pinned there is no timeline at all. `content` gets the time to draw.
struct NWOneShot<Content: View>: View {
    @Environment(\.nwFixedNow) private var fixedNow
    @Environment(\.nwReduceMotion) private var reduceMotion
    @Environment(\.nwMotionActive) private var active
    var start: Date?
    var duration: TimeInterval
    var fps: Double = NWMotionRate.oneShot
    var content: (Date) -> Content
    /// The end of the run that has finished, so the view stops ticking (a
    /// later end, as when a dawn waits for one more star, starts it again).
    @State private var finished: Date?

    init(start: Date?, duration: TimeInterval, fps: Double = NWMotionRate.oneShot,
         @ViewBuilder content: @escaping (Date) -> Content) {
        self.start = start
        self.duration = duration
        self.fps = fps
        self.content = content
    }

    var body: some View {
        if let fixedNow {
            content(fixedNow)
        } else if let start, !reduceMotion, finished != start.addingTimeInterval(duration),
                  Date() < start.addingTimeInterval(duration) {
            let end = start.addingTimeInterval(duration)
            TimelineView(.animation(minimumInterval: 1 / fps, paused: !active)) { tl in
                content(min(tl.date, end))
                    .onChange(of: tl.date >= end) { done in if done { finished = end } }
            }
        } else {
            content(start.map { max(Date(), $0.addingTimeInterval(duration)) } ?? Date())
        }
    }
}

// MARK: - Shaders

/// The precompiled Night Watch shaders (Tools/Shaders/NightWatch.metal),
/// embedded in the executable. Checked once: if the library will not load on
/// this Mac, every surface keeps its Canvas drawing.
enum NWShaders {
    /// Set by the harness's `--canvas` flag (and usable as a kill switch).
    static var forceCanvas = false

    private static let data: Data? = Data(base64Encoded: NWShaderBlob.metallib, options: .ignoreUnknownCharacters)

    /// True when the embedded metallib loads and has every function we call.
    static let libraryLoads: Bool = {
        guard let data, let device = MTLCreateSystemDefaultDevice() else { return false }
        let dispatchData = data.withUnsafeBytes { DispatchData(bytes: $0) }
        guard let lib = try? device.makeLibrary(data: dispatchData as __DispatchData) else { return false }
        return Set(["nwAurora", "nwPulse", "nwGlass"]).isSubset(of: Set(lib.functionNames))
    }()

    /// The library, on macOS 14 and later, when it loads.
    @available(macOS 14, *)
    static let library: ShaderLibrary? = {
        guard libraryLoads, let data else { return nil }
        return ShaderLibrary(data: data)
    }()

    /// Whether a view may draw with the shaders now.
    static func usable(_ allowed: Bool) -> Bool {
        guard allowed, !forceCanvas else { return false }
        if #available(macOS 14, *) { return library != nil }
        return false
    }
}

extension NightWatch.RGBA {
    /// The colour as a shader's float3 (sRGB 0...1).
    var shaderRGB: (Float, Float, Float) { (Float(r), Float(g), Float(b)) }
}
