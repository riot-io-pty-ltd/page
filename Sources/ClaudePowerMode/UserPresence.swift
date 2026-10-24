import Foundation
import CoreGraphics

/// Is the user physically at this Mac right now?
///
/// Used to avoid buzzing the phone about an idle Claude turn while the user
/// is sitting in front of the terminal anyway, and to hold the automatic
/// low-battery resume while they might be typing. Approval prompts and
/// questions still page immediately — those block the agent.
///
/// Page's own synthetic input (the System Events Return the Codex
/// Terminal.app path posts while delivering a phone reply) resets the same
/// idle counter as a real key press. `SyntheticInput` is the single record
/// of it (in memory and in the marker file the Page hook reads); an idle
/// reset it explains is not taken as "the user is back", here or in the
/// hook (same rule, same `SyntheticInput.toleranceSeconds`).
enum UserPresence {
    /// Seconds since the last keyboard/mouse/trackpad event in the login
    /// session that wasn't Page's own synthetic input. When the last input
    /// was Page's, this is the user's idle time from just before Page's
    /// keystroke plus the time since (SyntheticInput keeps that baseline
    /// in-process); only when no baseline is known — e.g. a keystroke from
    /// before a relaunch — does it fall back to `.infinity` ("away"), which
    /// is what the hook, with no baseline at all, always does. Returns
    /// `.infinity` if the idle time can't be read.
    static func secondsSinceLastInput() -> TimeInterval {
        SyntheticInput.adjustedIdle(raw: rawSecondsSinceLastInput())
    }

    /// True when the user has touched the Mac within `threshold` seconds.
    static func isActive(within threshold: TimeInterval) -> Bool {
        guard threshold > 0 else { return false }
        return secondsSinceLastInput() < threshold
    }

    /// Pure: the no-baseline rule — what the hook applies, and the fallback
    /// when SyntheticInput has no pre-keystroke baseline. An idle reset that
    /// `SyntheticInput.explainsIdleReset` attributes to Page means "away".
    static func effectiveIdle(raw: TimeInterval, now: Date, syntheticAt: Date?) -> TimeInterval {
        guard raw.isFinite, let at = syntheticAt else { return raw }
        return SyntheticInput.explainsIdleReset(idleSeconds: raw, now: now, at: at) ? .infinity : raw
    }

    private static func rawSecondsSinceLastInput() -> TimeInterval {
        // `kCGAnyInputEventType` is ~0 as UInt32; build it explicitly because
        // the Swift overlay doesn't export the constant.
        let anyInput = CGEventType(rawValue: ~0)!
        let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return s.isFinite && s >= 0 ? s : .infinity
    }
}
