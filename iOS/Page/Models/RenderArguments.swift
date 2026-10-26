import Foundation

/// The DEBUG render harness's launch arguments: `-NWRender <screen>` shows
/// one fixture screen; `-NWGlow off|subtle|full` forces the Card glow for
/// that run (in memory only). Parsed here so it is testable; only DEBUG
/// builds act on it.
struct RenderArguments: Equatable {
    var screen: String
    var glow: CardGlow?

    static let screenFlag = "-NWRender"
    static let glowFlag = "-NWGlow"

    /// nil when `-NWRender` is absent or has no screen after it. Pure.
    static func parse(_ args: [String]) -> RenderArguments? {
        guard let i = args.firstIndex(of: screenFlag), args.indices.contains(i + 1), !args[i + 1].hasPrefix("-") else { return nil }
        let glow = args.firstIndex(of: glowFlag).flatMap { args.indices.contains($0 + 1) ? CardGlow(argument: args[$0 + 1]) : nil }
        return RenderArguments(screen: args[i + 1], glow: glow)
    }
}
