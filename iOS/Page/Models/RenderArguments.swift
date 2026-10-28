import Foundation

/// The DEBUG render harness's launch arguments: `-NWRender <screen>` shows
/// one fixture screen; `-NWGlow off|subtle|full` forces the Card glow for
/// that run (in memory only); `-NWTime <seconds>` pins the clock of the
/// screen's motion (the aurora, the pulse, and a signature motion's time
/// since it began), so one frame of an animation can be captured;
/// `-NWDaypart <earlyMorning|morning|afternoon|nighttime|minute|HH:MM>` (or
/// `-NWDayTime HH:MM`) pins the time of day the skies are drawn at, as a
/// local minute of the day, never an instant, so a simulator in any time zone
/// draws the same sky; `-NWGlass off` draws the chrome without Liquid Glass
/// (the look before iOS 26, and with Reduce Transparency on). Parsed here so
/// it is testable; only DEBUG builds act on it.
struct RenderArguments: Equatable {
    var screen: String
    var glow: CardGlow?
    /// Seconds into the screen's motion; nil draws the harness's usual still frame.
    var time: Double? = nil
    /// The local minute of the day (0 ..< 1440) the skies are drawn at; nil is
    /// 01:12, nighttime, so every frame without the flag is unchanged.
    var dayTime: Double? = nil
    /// False draws the chrome's fallback surfaces where Liquid Glass would be.
    var glass = true

    static let screenFlag = "-NWRender"
    static let glowFlag = "-NWGlow"
    static let timeFlag = "-NWTime"
    static let daypartFlag = "-NWDaypart"
    static let dayTimeFlag = "-NWDayTime"
    static let glassFlag = "-NWGlass"

    /// nil when `-NWRender` is absent or has no screen after it. A time that
    /// is not a finite, non-negative number is ignored. Pure.
    static func parse(_ args: [String]) -> RenderArguments? {
        guard let i = args.firstIndex(of: screenFlag), args.indices.contains(i + 1), !args[i + 1].hasPrefix("-") else { return nil }
        let glow = args.firstIndex(of: glowFlag).flatMap { args.indices.contains($0 + 1) ? CardGlow(argument: args[$0 + 1]) : nil }
        let time = args.firstIndex(of: timeFlag).flatMap { args.indices.contains($0 + 1) ? Double(args[$0 + 1]) : nil }
            .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let day = [daypartFlag, dayTimeFlag].lazy.compactMap { flag in
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? minuteOfDay(args[$0 + 1]) : nil }
        }.first
        // Only "off" turns the glass off; anything else leaves it as the system draws it.
        let glass = args.firstIndex(of: glassFlag).map { !(args.indices.contains($0 + 1) && args[$0 + 1] == "off") } ?? true
        return RenderArguments(screen: args[i + 1], glow: glow, time: time, dayTime: day, glass: glass)
    }

    /// A time of day as a minute: a phase's name (the middle of its core),
    /// "HH:MM" (00:00 to 23:59), or a plain minute 0 ..< 1440. Anything else
    /// is nil. Pure.
    static func minuteOfDay(_ s: String) -> Double? {
        if let p = Daypart(rawValue: s) { return p.coreMinute }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard parts[0].count <= 2, parts[1].count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
                  (0..<24).contains(h), (0..<60).contains(m) else { return nil }
            return Double(h * 60 + m)
        }
        guard let m = Double(s), m.isFinite, m >= 0, m < 1440 else { return nil }
        return m
    }
}
