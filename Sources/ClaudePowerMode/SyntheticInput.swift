import Foundation
import CoreGraphics

/// Page's own synthetic input — the single source of truth for "was that
/// idle reset Page, or the user?".
///
/// The Codex Terminal.app path presses Return through System Events, which
/// posts a real key event: it resets the HID idle time that every "is the
/// user at the Mac?" check reads (the Page hook's `hid_idle_seconds`,
/// `UserPresence`). Each such keystroke is recorded here, in memory and in a
/// marker file, so those checks can tell an idle reset caused by Page from
/// the user coming back. Code that posts synthetic input calls `record()`
/// just before posting (and again after it lands); readers call
/// `explainsIdleReset(idleSeconds:)`, or `adjustedIdle(raw:)` for an idle
/// time with Page's own keystrokes taken out.
///
/// Marker: `~/Library/Application Support/ClaudePowerMode/synthetic-input`,
/// mode 0600, written atomically, holding the Unix time in whole seconds
/// (one line) of Page's most recent synthetic keystroke. Rule for readers
/// (the hook applies the same one): an idle reset at `now - idle` within
/// `toleranceSeconds` of the marker's time is Page's, not the user's.
enum SyntheticInput {
    static let markerName = "synthetic-input"
    /// Slack for whole-second marker times, the gap between writing the
    /// marker and the event, and AppleScript retries.
    static let toleranceSeconds: TimeInterval = 3

    /// Tests point this at a temp directory.
    static var directory: URL {
        get { lock.lock(); defer { lock.unlock() }; return _directory }
        set { lock.lock(); _directory = newValue; _markerLoaded = false; lock.unlock() }
    }

    static var markerURL: URL { directory.appendingPathComponent(markerName) }

    /// When Page last posted (or was about to post) a synthetic key event.
    /// In memory; before the first `record()` of this run, the marker file
    /// left by an earlier run (read once).
    static var lastAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return lastAtLocked()
    }

    /// Records a synthetic keystroke about to be (or just) posted. `rawIdle`
    /// is the HID idle time right now (read from the system when nil): it
    /// becomes the user's own idle baseline unless the last input was
    /// already one of Page's keystrokes (a retry, or the "after" record),
    /// so a burst of Page's input keeps the user's original baseline.
    static func record(now: Date = Date(), rawIdle: TimeInterval? = nil) {
        let raw = rawIdle ?? rawIdleSeconds()
        lock.lock()
        let previous = lastAtLocked()
        if let previous, raw.isFinite, matches(idleSeconds: raw, now: now, at: previous), _burstStart != nil {
            // Keep `_idleBefore` / `_burstStart`: that input was Page's.
        } else {
            _idleBefore = raw
            _burstStart = now
        }
        _lastAt = now
        _markerLoaded = true
        let url = _directory.appendingPathComponent(markerName)
        lock.unlock()
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = Data("\(Int(now.timeIntervalSince1970))\n".utf8)
        do {
            try body.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Logger.shared.log("SyntheticInput: couldn't write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// True when the last input `idleSeconds` ago lines up with Page's own
    /// synthetic keystroke (`at`, default: the last one recorded) rather
    /// than with the user.
    static func explainsIdleReset(idleSeconds: TimeInterval, now: Date = Date(), at: Date? = nil) -> Bool {
        guard idleSeconds.isFinite, let at = at ?? lastAt else { return false }
        return matches(idleSeconds: idleSeconds, now: now, at: at)
    }

    /// The idle time to report given the raw HID idle time: `raw` itself,
    /// unless the last input was Page's own keystroke — then the user's idle
    /// time from before Page's input plus the time since (or `.infinity`
    /// when that baseline isn't known, e.g. a marker from an earlier run).
    static func adjustedIdle(raw: TimeInterval, now: Date = Date()) -> TimeInterval {
        guard raw.isFinite else { return raw }
        lock.lock()
        let at = lastAtLocked()
        let before = _idleBefore
        let start = _burstStart
        lock.unlock()
        guard let at, matches(idleSeconds: raw, now: now, at: at) else { return raw }
        guard let before, let start else { return .infinity }
        return before + max(0, now.timeIntervalSince(start))
    }

    /// Seconds since the last keyboard / mouse / trackpad event in the login
    /// session, synthetic events included. `.infinity` when unknown.
    static func rawIdleSeconds() -> TimeInterval {
        // `kCGAnyInputEventType` is ~0 as UInt32; the overlay doesn't export it.
        guard let anyInput = CGEventType(rawValue: ~0) else { return .infinity }
        let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        return s.isFinite && s >= 0 ? s : .infinity
    }

    /// Parses the marker's body: whole Unix seconds on the first line.
    static func parseMarker(_ body: String) -> Date? {
        guard let first = body.split(separator: "\n", omittingEmptySubsequences: false).first,
              let secs = Int(first.trimmingCharacters(in: .whitespaces)), secs > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(secs))
    }

    /// Tests only: forget everything recorded in memory.
    static func resetForTesting() {
        lock.lock()
        _lastAt = nil
        _idleBefore = nil
        _burstStart = nil
        _markerLoaded = true
        lock.unlock()
    }

    private static func matches(idleSeconds: TimeInterval, now: Date, at: Date) -> Bool {
        let lastInput = now.addingTimeInterval(-idleSeconds)
        return abs(lastInput.timeIntervalSince(at)) <= toleranceSeconds
    }

    /// Caller holds `lock`.
    private static func lastAtLocked() -> Date? {
        if _lastAt == nil, !_markerLoaded {
            _markerLoaded = true
            let url = _directory.appendingPathComponent(markerName)
            if let body = try? String(contentsOf: url, encoding: .utf8) { _lastAt = parseMarker(body) }
        }
        return _lastAt
    }

    private static let lock = NSLock()
    private static var _lastAt: Date?
    /// The user's idle time just before the current burst of Page's input.
    private static var _idleBefore: TimeInterval?
    private static var _burstStart: Date?
    private static var _markerLoaded = false
    private static var _directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudePowerMode", isDirectory: true)
}
