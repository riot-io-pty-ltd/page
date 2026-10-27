import Foundation

/// The DEBUG render harness's launch arguments: `-NWRender <screen>` shows
/// one fixture screen; `-NWGlow off|subtle|full` forces the Card glow for
/// that run (in memory only); `-NWTime <seconds>` pins the clock of the
/// screen's motion (the aurora, the pulse, and a signature motion's time
/// since it began), so one frame of an animation can be captured. Parsed
/// here so it is testable; only DEBUG builds act on it.
struct RenderArguments: Equatable {
    var screen: String
    var glow: CardGlow?
    /// Seconds into the screen's motion; nil draws the harness's usual still frame.
    var time: Double? = nil

    static let screenFlag = "-NWRender"
    static let glowFlag = "-NWGlow"
    static let timeFlag = "-NWTime"

    /// nil when `-NWRender` is absent or has no screen after it. A time that
    /// is not a finite, non-negative number is ignored. Pure.
    static func parse(_ args: [String]) -> RenderArguments? {
        guard let i = args.firstIndex(of: screenFlag), args.indices.contains(i + 1), !args[i + 1].hasPrefix("-") else { return nil }
        let glow = args.firstIndex(of: glowFlag).flatMap { args.indices.contains($0 + 1) ? CardGlow(argument: args[$0 + 1]) : nil }
        let time = args.firstIndex(of: timeFlag).flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil }
            .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return RenderArguments(screen: args[i + 1], glow: glow, time: time)
    }
}
