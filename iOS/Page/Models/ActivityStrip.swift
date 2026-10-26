import Foundation

// The 4-hour activity strip on a lane. The Mac does not keep a per-session
// state history (that log is v4 work on the Mac), so the phone draws what it
// has seen itself: it samples the session list while Page is open, five
// minutes to a bucket, and keeps the most urgent state it saw in each. Time
// it never saw is blank. It is never filled in with invented activity.

/// One five-minute bucket on a strip. `level` nil means the phone did not see it.
struct StripCell: Equatable {
    var level: StarState?
}

struct ActivityLog: Equatable, Codable {
    /// Bucket length.
    static let bucket: TimeInterval = 5 * 60
    /// How long samples are kept.
    static let keep: TimeInterval = 24 * 3600
    static let storageKey = "page.activityLog"

    /// session id -> bucket index -> StarState raw value.
    private(set) var samples: [String: [Int: String]] = [:]
    /// The first sample ever recorded, to say how much of the strip was observed.
    private(set) var firstSampleAt: Date?
    private(set) var lastSampleAt: Date?

    init() {}

    static func bucketIndex(_ at: Date) -> Int { Int((at.timeIntervalSince1970 / bucket).rounded(.down)) }

    /// Records the states seen at `at`. A bucket keeps the most urgent state
    /// seen in it, so a prompt that appeared and cleared within five minutes
    /// still shows. Pure (mutating a value).
    mutating func record(_ states: [String: StarState], at: Date) {
        let b = Self.bucketIndex(at)
        for (id, state) in states {
            var row = samples[id] ?? [:]
            if let old = row[b].flatMap(StarState.init(rawValue:)), old.urgency < state.urgency {
                // Already holds something more urgent: keep it.
            } else {
                row[b] = state.rawValue
            }
            samples[id] = row
        }
        if firstSampleAt == nil { firstSampleAt = at }
        lastSampleAt = at
        prune(now: at)
    }

    /// Drops samples older than a day, and sessions with none left.
    mutating func prune(now: Date) {
        let oldest = Self.bucketIndex(now.addingTimeInterval(-Self.keep))
        for (id, row) in samples {
            let kept = row.filter { $0.key >= oldest }
            if kept.isEmpty { samples[id] = nil } else { samples[id] = kept }
        }
    }

    /// The strip for a session: `hours * 12` buckets, oldest first, ending
    /// with the bucket of `now`. The last bucket is the session's state right
    /// now (`current`), which the phone has just been told. Pure.
    func strip(for id: String, now: Date, hours: Int = 4, current: StarState? = nil) -> [StripCell] {
        let count = hours * 12
        let end = Self.bucketIndex(now)
        let row = samples[id] ?? [:]
        var cells = (0..<count).map { i -> StripCell in
            let b = end - (count - 1) + i
            return StripCell(level: row[b].flatMap(StarState.init(rawValue:)))
        }
        if let current, !cells.isEmpty { cells[cells.count - 1].level = current }
        return cells
    }

    /// How much of the window this phone has watched, in seconds.
    func observedSpan(now: Date, hours: Int = 4) -> TimeInterval {
        guard let first = firstSampleAt else { return 0 }
        return min(Double(hours) * 3600, max(0, now.timeIntervalSince(first)))
    }

    // MARK: persistence

    static func load(from defaults: UserDefaults = .standard) -> ActivityLog {
        guard let data = defaults.data(forKey: storageKey), let log = try? JSONDecoder().decode(ActivityLog.self, from: data) else { return ActivityLog() }
        return log
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}
