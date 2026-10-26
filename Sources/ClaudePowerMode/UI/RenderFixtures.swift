import Foundation

/// Fixture situations for the render harness (and for tests): the scenes the
/// v4 boards show, built as Coordinator snapshots so they run through the same
/// `NowModel.build` as live data.
enum NightWatchFixtures {
    /// 23:48:00 today, local time (the clock in board 05).
    static func boardNow(calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 23, minute: 48, second: 0, of: Date(timeIntervalSinceReferenceDate: 800_000_000)) ?? Date()
    }

    static func at(_ now: Date, hour: Int, minute: Int, calendar: Calendar = .current) -> Date {
        var d = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if d <= now { d = calendar.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }

    static func session(_ name: String, state: AgentSessionState = .active, backend: AgentBackendID = .claude) -> AgentSession {
        AgentSession(backend: backend, sessionId: "sess-\(name)", cwd: "/Users/roy/projects/\(name)", title: nil,
                     source: .terminal, state: state, lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
    }

    static func event(_ project: String, kind: InterventionKind, context: String, openedAt: Date,
                      subtype: String? = nil, backend: AgentBackendID = .claude) -> InterventionEvent {
        InterventionEvent(
            id: "sess-\(project)-\(subtype ?? kind.rawValue)-\(Int(openedAt.timeIntervalSince1970))",
            sessionId: "sess-\(project)", cwd: "/Users/roy/projects/\(project)", projectName: project,
            kind: kind, openedAt: openedAt, context: context, transcriptPath: "", backend: backend,
            source: .terminal, subtype: subtype)
    }

    static func snapshot(
        sessions: [AgentSession] = [],
        power: PowerSnapshot = PowerSnapshot(percent: 100, onAC: true, hasBattery: true, isCharging: false),
        awake: AwakeAssertions = AwakeAssertions(preventIdleSleep: true, preventSystemSleep: true),
        battery: Coordinator.BatteryStatus = .normal,
        activeRateLimit: RateLimitEvent? = nil,
        scheduledResumes: [ScheduledResume] = [],
        pending: [InterventionEvent] = [],
        relay: Coordinator.RelayState = .connected,
        forecast: BatteryForecast.Estimate? = nil,
        lidClosedOnBattery: Bool = false,
        backends: [Coordinator.BackendInfo] = [],
        usage: UsageSnapshot? = nil,
        usageHitAt: Date? = nil,
        configProblem: String? = nil
    ) -> Coordinator.Snapshot {
        Coordinator.Snapshot(
            sessions: sessions, power: power, awake: awake, lidClosedOnBattery: lidClosedOnBattery, lidClosedOnBatteryBlocker: nil,
            battery: battery, activeRateLimit: activeRateLimit, scheduledResumes: scheduledResumes,
            pendingInterventions: pending, relayState: relay, backends: backends, configProblem: configProblem,
            batteryForecast: forecast, usage: usage, usageHitAt: usageHitAt)
    }

    static let working5: [AgentSession] = ["bottle-flip", "page", "llm-play", "page-relay", "mac-on-claude-code"].map { session($0) }

    static func route(_ ev: InterventionEvent) -> String? { "cmux › \(ev.projectName)" }

    /// Board 05: two need you, one looks stuck, five working, AC, lid-closed awake.
    static func needsYou(now: Date = boardNow()) -> NowInputs {
        let pending = [
            event("bottle-flip", kind: .permission,
                  context: "[Bash] rm -rf Builds/Dev/*.app\nDelete the dev builds", openedAt: now.addingTimeInterval(-4 * 60)),
            event("page", kind: .permission,
                  context: "[Bash] swift test --filter Stuck\nRun the Stuck tests", openedAt: now.addingTimeInterval(-90)),
            event("llm-play", kind: .idle,
                  context: "Looks stuck in a loop: this has failed 6 times.\ncargo test", openedAt: now.addingTimeInterval(-12 * 60),
                  subtype: "looping")
        ]
        let resume = ScheduledResume(
            sessionId: "sess-llm-play", cwd: "/Users/roy/projects/llm-play", projectName: "llm-play",
            resetTime: at(now, hour: 4, minute: 9), prompt: "carry on", plistPath: "", logPath: "", label: "resume",
            createdAt: now, runAt: at(now, hour: 4, minute: 10))
        var i = NowInputs(
            snapshot: snapshot(sessions: working5, scheduledResumes: [resume], pending: pending),
            now: now, macName: "Studio MBP", idleSeconds: 5,
            usage: UsageSnapshot(fiveHour: .init(pct: 62, resetsAt: at(now, hour: 3, minute: 0)),
                                 sevenDay: .init(pct: 30, resetsAt: at(now, hour: 23, minute: 0).addingTimeInterval(3 * 86400)),
                                 updatedAt: now.addingTimeInterval(-60)),
            usageHitAt: at(now, hour: 2, minute: 40),
            receipts: [DeliveryReceipt(verb: .approved, subject: "npm test", route: "cmux › page",
                                       at: now.addingTimeInterval(-48))])
        i.route = route
        return i
    }

    /// Board 42, middle: five working, nothing needs you, you are away, rings.
    static func allQuiet(now: Date = boardNow()) -> NowInputs {
        var i = NowInputs(snapshot: snapshot(sessions: working5), now: now, macName: "Studio MBP",
                          idleSeconds: 20 * 60)
        i.day = DayStats(unblockedFast: 11, decisions: 12, shipped: 7, finished: 10, calmSeconds: 4 * 3600 + 10 * 60)
        i.route = route
        return i
    }

    /// Board 42, right: paused for battery at the 10% cutoff.
    static func pausedForBattery(now: Date = boardNow(), waiting: [InterventionEvent] = []) -> NowInputs {
        let paused = ["mac-on-claude-code", "page-relay"].enumerated().map { n, name in
            PausedSession(backend: .claude, sessionId: "sess-\(name)", projectName: name,
                          cwd: "/Users/roy/projects/\(name)", pausedAt: now.addingTimeInterval(-Double(3 + n) * 60),
                          detail: "Interrupted in cmux")
        }
        var i = NowInputs(
            snapshot: snapshot(
                power: PowerSnapshot(percent: 10, onAC: false, hasBattery: true, isCharging: false),
                awake: .none,
                battery: Coordinator.BatteryStatus(phase: .drained, paused: paused, graceEndsAt: nil, mode: .pause),
                pending: waiting),
            now: now, macName: "Studio MBP", idleSeconds: 30)
        i.route = route
        // One agent's transcript shows its summary; the other's does not (yet).
        i.summarised = ["sess-mac-on-claude-code"]
        return i
    }

    /// Board 05 with the last delivery having failed.
    static func needsYouWithFailedReceipt(now: Date = boardNow()) -> NowInputs {
        var i = needsYou(now: now)
        i.receipts = [DeliveryReceipt(verb: .approved, subject: "swift test", route: "cmux › page",
                                      at: now.addingTimeInterval(-30), outcome: .timedOut)]
        return i
    }

    /// Eight pages, to exercise the long list.
    static func manyPages(now: Date = boardNow()) -> NowInputs {
        let names = ["bottle-flip", "page", "llm-play", "page-relay", "mac-on-claude-code", "payments-api", "docs", "infra"]
        let contexts = ["[Bash] rm -rf Builds/Dev/*.app\nDelete the dev builds", "[Bash] swift test\nRun the tests",
                        "[Edit] Sources/Foo.swift\n- a\n+ b", "[Bash] git push origin feat", "[Read] Package.swift",
                        "[Bash] npm publish", "[Bash] ls -la\nList files", "[Bash] terraform apply"]
        let pending = zip(names, contexts).enumerated().map { n, pair in
            event(pair.0, kind: .permission, context: pair.1, openedAt: now.addingTimeInterval(-Double(60 * (n + 1))))
        }
        var i = NowInputs(snapshot: snapshot(sessions: working5, pending: pending), now: now, macName: "Studio MBP", idleSeconds: 5)
        i.route = route
        return i
    }

    /// Folders for the Dispatch panel.
    static let folders: [SessionStarter.Folder] = ["page", "bottle-flip", "llm-play"].map {
        SessionStarter.Folder(path: "/Users/roy/projects/\($0)", name: $0, lastUsedAt: nil)
    }

    /// On battery at 41% with a forecast: the cutoff marker, the arc, no lid-closed.
    static func onBattery(now: Date = boardNow()) -> NowInputs {
        let pending = [event("page", kind: .permission, context: "[Bash] git push --force origin main",
                             openedAt: now.addingTimeInterval(-60))]
        var i = NowInputs(
            snapshot: snapshot(
                sessions: working5,
                power: PowerSnapshot(percent: 41, onAC: false, hasBattery: true, isCharging: false),
                awake: AwakeAssertions(preventIdleSleep: true, preventSystemSleep: false),
                pending: pending,
                forecast: BatteryForecast.Estimate(percent: 41, cutoff: 10, drainPerHour: 17, minutesToCutoff: 110)),
            now: now, macName: "Studio MBP", idleSeconds: 3)
        i.route = route
        return i
    }
}
