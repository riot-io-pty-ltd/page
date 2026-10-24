import Foundation

/// Periodically scans Claude transcripts for rate-limit events. Emits
/// `onNewEvent` once per limit "wall" that is still in effect, and answers
/// "is the user blocked right now?" without touching the disk.
///
/// Scanning is incremental (see `RateLimitTranscriptIndex`): after the first
/// pass only bytes appended to transcripts are read, so calling `scan` every
/// tick is cheap.
final class RateLimitWatcher {
    var onNewEvent: ((RateLimitEvent) -> Void)?

    private let index: RateLimitTranscriptIndex
    private let queue = DispatchQueue(label: "ClaudePowerMode.RateLimitWatcher")
    // State below is confined to `queue`.
    private var state = NotifyState()
    private var lastScanEvents: [RateLimitEvent] = []
    private var lastSuccessfulReply: [String: Date] = [:]

    init(index: RateLimitTranscriptIndex = .shared) {
        self.index = index
    }

    /// What has already been handled. Pruned to the events the index still
    /// reports, so it can't grow over days of uptime.
    struct NotifyState: Equatable {
        var seen: Set<String> = []
        var notifiedWalls: Set<String> = []
    }

    /// Scans, emits `onNewEvent` for newly-seen walls, and returns every
    /// event currently known (lookback window + older ones still in effect).
    @discardableResult
    func scan(transcriptDirectory: String, lookbackHours: Double = 6, now: Date = Date()) -> [RateLimitEvent] {
        let result = index.scan(directory: transcriptDirectory, lookbackHours: lookbackHours, now: now)
        let toNotify: [RateLimitEvent] = queue.sync {
            lastScanEvents = result.events
            lastSuccessfulReply = result.lastSuccessfulReply
            let (notify, next) = Self.eventsToNotify(
                result.events,
                state: state,
                lastSuccessfulReply: result.lastSuccessfulReply,
                now: now
            )
            state = next
            return notify
        }
        for e in toNotify { onNewEvent?(e) }
        return result.events
    }

    /// The rate limit the user is currently blocked on, if any: the newest
    /// event whose reset is still ahead and whose session hasn't replied
    /// successfully since. Cheap — callers may invoke it every tick (it must
    /// not re-read transcripts itself).
    func activeLimit(now: Date = Date()) -> RateLimitEvent? {
        activeLimits(now: now).max(by: { $0.eventTime < $1.eventTime })
    }

    /// Like `activeLimit`, but one (the newest) event per blocked session.
    func activeLimits(now: Date = Date()) -> [RateLimitEvent] {
        let (events, replies) = queue.sync { (lastScanEvents, lastSuccessfulReply) }
        return Self.activeLimits(events, lastSuccessfulReply: replies, now: now)
    }

    /// True once the event's session has produced a real reply after the
    /// limit — the limit is over (Claude Code reset early, the user switched
    /// model, ...). A scheduled resume for it should be cancelled.
    func isCleared(_ event: RateLimitEvent) -> Bool {
        let replies = queue.sync { lastSuccessfulReply }
        return Self.isCleared(event, lastSuccessfulReply: replies)
    }

    /// Marks pre-existing events as already handled so a launch doesn't
    /// re-announce history — but only events that are over (reset passed or
    /// session replied since). A limit still in effect stays unseen, so the
    /// first scan after a restart / reinstall / crash still notifies and
    /// (re)schedules its resume; ResumeScheduler makes that idempotent.
    /// Also warms the incremental index, so the first tick is cheap.
    func primeWithExistingEvents(transcriptDirectory: String, lookbackHours: Double = 6, now: Date = Date()) {
        let result = index.scan(directory: transcriptDirectory, lookbackHours: lookbackHours, now: now)
        queue.sync {
            lastScanEvents = result.events
            lastSuccessfulReply = result.lastSuccessfulReply
            state = Self.primed(state, with: result.events, lastSuccessfulReply: result.lastSuccessfulReply, now: now)
        }
        let active = Self.activeLimits(result.events, lastSuccessfulReply: result.lastSuccessfulReply, now: now)
        Logger.shared.log("RateLimitWatcher primed with \(result.events.count) event(s); \(active.count) session(s) still rate-limited")
    }

    // MARK: - Pure decision logic

    static func isCleared(_ event: RateLimitEvent, lastSuccessfulReply: [String: Date]) -> Bool {
        guard let reply = lastSuccessfulReply[event.transcriptPath] else { return false }
        return reply > event.eventTime
    }

    static func activeLimits(_ events: [RateLimitEvent], lastSuccessfulReply: [String: Date], now: Date) -> [RateLimitEvent] {
        var newest: [String: RateLimitEvent] = [:]
        for e in events where e.resetTime > now && !isCleared(e, lastSuccessfulReply: lastSuccessfulReply) {
            if let current = newest[e.sessionId], current.eventTime >= e.eventTime { continue }
            newest[e.sessionId] = e
        }
        return newest.values.sorted { $0.eventTime < $1.eventTime }
    }

    /// Which events to announce, oldest first: unseen, still in effect, not
    /// cleared by a later reply, and the first event of their wall.
    static func eventsToNotify(
        _ events: [RateLimitEvent],
        state: NotifyState,
        lastSuccessfulReply: [String: Date],
        now: Date
    ) -> (notify: [RateLimitEvent], state: NotifyState) {
        var next = state
        var notify: [RateLimitEvent] = []
        for e in events.sorted(by: { $0.eventTime < $1.eventTime }) where !next.seen.contains(e.uniqueId) {
            next.seen.insert(e.uniqueId)
            guard e.resetTime > now, !isCleared(e, lastSuccessfulReply: lastSuccessfulReply) else { continue }
            guard next.notifiedWalls.insert(e.wallKey).inserted else { continue }
            notify.append(e)
        }
        // Forget ids the index no longer reports (aged out of the window);
        // they can't come back.
        let present = Set(events.map(\.uniqueId))
        let presentWalls = Set(events.map(\.wallKey))
        next.seen.formIntersection(present)
        next.notifiedWalls.formIntersection(presentWalls)
        return (notify, next)
    }

    static func primed(
        _ state: NotifyState,
        with events: [RateLimitEvent],
        lastSuccessfulReply: [String: Date],
        now: Date
    ) -> NotifyState {
        var next = state
        for e in events where e.resetTime <= now || isCleared(e, lastSuccessfulReply: lastSuccessfulReply) {
            next.seen.insert(e.uniqueId)
        }
        return next
    }
}
