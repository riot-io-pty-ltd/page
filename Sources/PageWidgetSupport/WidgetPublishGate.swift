import Foundation

/// When the app may write the snapshot and ask WidgetKit to reload. Pure and
/// clocked by the caller, so the throttle is testable.
///
/// WidgetKit gives an app a limited number of reloads (tens a day), and a
/// widget that runs out of them freezes. So reloads are rationed by what
/// changed:
///  - what needs the person (the counts, the mood, the decisions waiting,
///    running or not) is urgent: reload within `minReloadInterval`;
///  - any other change to what is shown (a step's text, the working count,
///    the battery percentage) is written to the file, and the reload waits
///    for `minLazyReloadInterval`; the widget also refreshes itself every
///    15 minutes and reads the file then;
///  - the heartbeat write (an unchanged snapshot, every
///    `WidgetSnapshot.heartbeat`) never reloads: it keeps the file's
///    timestamp honest for the next time the widget looks.
/// The file is rewritten when what is visible changes, at most every
/// `minWriteInterval`. A reload that is owed is never dropped, only delayed.
public struct WidgetPublishGate {
    public var minWriteInterval: TimeInterval = 5
    public var minReloadInterval: TimeInterval = 30
    public var minLazyReloadInterval: TimeInterval = 15 * 60

    public struct Action: Equatable {
        public var write = false
        public var reload = false
        /// Offer the newest snapshot again after this long (a change or a reload is waiting).
        public var recheckIn: TimeInterval?
        public init(write: Bool = false, reload: Bool = false, recheckIn: TimeInterval? = nil) {
            self.write = write; self.reload = reload; self.recheckIn = recheckIn
        }
    }

    private var lastFingerprint: Data?
    private var lastUrgent: Data?
    private var lastWriteAt: Date?
    private var lastReloadAt: Date?
    private var reloadOwed = false
    private var reloadUrgent = false

    public init() {}

    /// `urgent` is `WidgetSnapshot.urgentFingerprint()`; without it every change counts as urgent.
    /// `force` (wake, quit): write and reload now, whatever the throttle says.
    public mutating func offer(fingerprint: Data, urgent: Data? = nil, now: Date, force: Bool = false) -> Action {
        var action = Action()
        let changed = fingerprint != lastFingerprint
        let urgentNow = urgent ?? fingerprint
        let sinceWrite = lastWriteAt.map { now.timeIntervalSince($0) }
        // A clock that went backwards counts as "long ago".
        let writeDue = force || sinceWrite == nil || sinceWrite! >= minWriteInterval || sinceWrite! < 0
        if changed {
            if writeDue {
                action.write = true
                if urgentNow != lastUrgent { reloadUrgent = true }
                lastFingerprint = fingerprint
                lastUrgent = urgentNow
                lastWriteAt = now
                reloadOwed = true
            } else {
                action.recheckIn = minWriteInterval - (sinceWrite ?? 0)
            }
        } else if force || (sinceWrite ?? .infinity) >= WidgetSnapshot.heartbeat || (sinceWrite ?? 0) < 0 {
            // The heartbeat: a fresh timestamp in the file, no reload of its own.
            action.write = true
            lastWriteAt = now
            if force { reloadOwed = true; reloadUrgent = true }
        }
        if reloadOwed {
            let sinceReload = lastReloadAt.map { now.timeIntervalSince($0) }
            let needed = reloadUrgent ? minReloadInterval : minLazyReloadInterval
            if force || sinceReload == nil || sinceReload! >= needed || sinceReload! < 0 {
                action.reload = true
                lastReloadAt = now
                reloadOwed = false
                reloadUrgent = false
            } else {
                let wait = needed - sinceReload!
                action.recheckIn = min(action.recheckIn ?? wait, wait)
            }
        }
        return action
    }
}
