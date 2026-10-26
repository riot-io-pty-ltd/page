import Foundation

// Presence and the day's ledger: the pure state machines behind the Welcome
// back panel and the three rings. The caller feeds them clock readings and
// snapshots; nothing here reads UserPresence, the Coordinator or the log.

/// Notices when the person has been away past the threshold and comes back.
struct PresenceTracker: Equatable {
    enum Event: Equatable {
        case none
        case wentAway
        /// Input again after `awayFor` seconds away.
        case returned(awayFor: TimeInterval)
    }

    /// Idle seconds that count as away (`config.idlePageOnlyWhenAwaySeconds`).
    /// 0 turns tracking off.
    var awayAfter: TimeInterval
    /// When the last input before the absence happened.
    private(set) var awaySince: Date?

    init(awayAfter: TimeInterval) {
        self.awayAfter = awayAfter
    }

    var isAway: Bool { awaySince != nil }

    /// Pure. Feed the idle time (seconds since the last real input) at `now`.
    /// An unreadable (infinite) idle time is ignored.
    mutating func observe(idle: TimeInterval, now: Date) -> Event {
        guard awayAfter > 0, idle.isFinite, idle >= 0 else { return .none }
        if idle >= awayAfter {
            if awaySince == nil {
                awaySince = now.addingTimeInterval(-idle)
                return .wentAway
            }
            return .none
        }
        guard let since = awaySince else { return .none }
        awaySince = nil
        // The return keystroke happened `idle` seconds ago.
        return .returned(awayFor: max(0, now.addingTimeInterval(-idle).timeIntervalSince(since)))
    }
}

/// What happened while the person was away, for the Welcome back panel.
struct AwayLedger: Equatable {
    /// `Coordinator.phoneReplyCount` when the absence began.
    var phoneRepliesAtStart: Int
    /// Finished turns that came up while away (review pages, not stuck ones).
    private(set) var finishedIds: Set<String> = []

    init(phoneRepliesAtStart: Int) {
        self.phoneRepliesAtStart = phoneRepliesAtStart
    }

    /// Pure. Remember the finished turns among the open pages.
    mutating func observe(pending: [InterventionEvent]) {
        for ev in pending where NowModel.section(of: ev) == .review {
            finishedIds.insert(ev.id)
        }
    }

    /// Pure. The handover on return. "Finished" counts finished turns Page saw
    /// come up; Page cannot tell whether their tests passed, so this is not
    /// verified green.
    func welcome(away: TimeInterval, needYou: Int, phoneRepliesNow: Int, rings: [RingStat]) -> WelcomeBack {
        WelcomeBack.build(away: away, finished: finishedIds.count, needYou: needYou,
                          handledOnPhone: max(0, phoneRepliesNow - phoneRepliesAtStart), rings: rings)
    }
}

/// Today's three rings, accumulated from snapshots: Unblocked (decisions you
/// answered within two minutes), Shipped (turns that finished, of those that
/// finished or got stuck) and Calm (time agents ran with nothing waiting on
/// you). In memory: it starts over when Page relaunches and at midnight.
struct DayLedger: Equatable {
    /// A decision answered inside this is "unblocked".
    static let fastWindow: TimeInterval = 120
    /// A gap between observations longer than this (sleep) is not counted as calm.
    static let maxGap: TimeInterval = 120

    private(set) var stats = DayStats()
    private(set) var dayStart: Date
    private var lastObserved: Date?
    /// Open decision pages and when they opened.
    private var open: [String: Date] = [:]
    private var finishedIds: Set<String> = []
    private var stuckIds: Set<String> = []

    init(now: Date, calendar: Calendar = .current) {
        dayStart = calendar.startOfDay(for: now)
    }

    /// Pure. One snapshot: `working` agents, the open `pending` pages.
    mutating func observe(pending: [InterventionEvent], working: Int, now: Date, calendar: Calendar = .current) {
        if calendar.startOfDay(for: now) != dayStart {
            self = DayLedger(now: now, calendar: calendar)
        }
        let decisions = pending.filter { NowModel.section(of: $0) == .decide }

        // A decision that left the list was answered (here, on the phone, or in the terminal).
        let nowIds = Set(decisions.map(\.id))
        for (id, opened) in open where !nowIds.contains(id) {
            stats.decisions += 1
            if (lastObserved ?? now).timeIntervalSince(opened) <= Self.fastWindow { stats.unblockedFast += 1 }
            open[id] = nil
        }
        for ev in decisions where open[ev.id] == nil { open[ev.id] = ev.openedAt }

        for ev in pending {
            switch NowModel.section(of: ev) {
            case .review? where !NowModel.isForecast(ev):
                if finishedIds.insert(ev.id).inserted { stats.finished += 1; stats.shipped += 1 }
            case .look? where !NowModel.isForecast(ev) && ev.kind == .idle:
                if stuckIds.insert(ev.id).inserted { stats.finished += 1 }
            default: break
            }
        }

        if let last = lastObserved, working > 0, decisions.isEmpty {
            stats.calmSeconds += min(max(0, now.timeIntervalSince(last)), Self.maxGap)
        }
        lastObserved = now
    }
}
