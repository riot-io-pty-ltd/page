import Foundation

/// Watches the live session list while Page is open and remembers, five
/// minutes to a bucket, what each session was doing: the data behind the
/// 4-hour strip on a lane. The Mac keeps no such history, so time Page was
/// closed stays blank. Saved to UserDefaults at most once a minute.
@MainActor
final class ActivityStore: ObservableObject {
    @Published private(set) var log: ActivityLog
    /// The last battery pause as the phone saw it: the dusk and the dawn.
    @Published private(set) var duskDawn = DuskDawnLog()
    private var lastSaved = Date.distantPast
    private var lastStates: [String: StarState] = [:]
    private var lastBucket = 0
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.log = ActivityLog.load(from: defaults)
    }

    /// Records the states seen now. Cheap when nothing changed inside a bucket.
    func observe(sessions: [LiveSession], interventions: [Intervention], paused: Bool, now: Date = Date()) {
        guard !sessions.isEmpty else { return }
        let stuck = Set(interventions.filter { $0.kind == .idle && PageSubtype.isStuck($0.subtype) }.map(\.sessionId))
        var states: [String: StarState] = [:]
        for s in sessions { states[s.id] = StarState(session: s, stuck: stuck.contains(s.id), paused: paused) }
        let bucket = ActivityLog.bucketIndex(now)
        guard states != lastStates || bucket != lastBucket else { return }
        lastStates = states
        lastBucket = bucket
        log.record(states, at: now)
        if now.timeIntervalSince(lastSaved) > 60 {
            lastSaved = now
            log.save(to: defaults)
        }
    }

    /// Records the power story: the pause, the dawn, and each session seen
    /// working again after it (a star relights only on that).
    func observePower(paused: Bool, sessions: [LiveSession], now: Date = Date()) {
        var next = duskDawn
        next.observe(paused: paused, working: Set(sessions.filter { $0.state == .active }.map(\.id)), at: now)
        if next != duskDawn { duskDawn = next }
    }

    /// Writes what is held (the app is going to the background).
    func flush() { log.save(to: defaults); lastSaved = Date() }

    /// Forgets everything (another Mac's sessions are different sessions).
    func reset() {
        log = ActivityLog()
        duskDawn = DuskDawnLog()
        lastStates = [:]
        log.save(to: defaults)
    }
}
