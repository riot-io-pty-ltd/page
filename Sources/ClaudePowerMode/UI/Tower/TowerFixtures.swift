import Foundation

/// Tower scenes for the render harness (and for tests): real
/// `Coordinator.Snapshot` and `NowModel` values, a form from a real `Config`,
/// and no environment, so nothing is read or written.
enum TowerFixtures {
    static let day = DayStats(unblockedFast: 11, decisions: 12, shipped: 7, finished: 10, calmSeconds: 4 * 3600 + 10 * 60)

    static func backends(codex: Bool = false) -> [Coordinator.BackendInfo] {
        [Coordinator.BackendInfo(id: .claude, displayName: "Claude Code", enabled: true, sessionCount: 7, activeCount: 5, waitingCount: 2),
         Coordinator.BackendInfo(id: .codex, displayName: "Codex", enabled: codex, sessionCount: codex ? 2 : 0, activeCount: 0, waitingCount: 0)]
    }

    static func usage(now: Date) -> UsageSnapshot {
        UsageSnapshot(fiveHour: .init(pct: 62, resetsAt: NightWatchFixtures.at(now, hour: 3, minute: 0)),
                      sevenDay: .init(pct: 30, resetsAt: NightWatchFixtures.at(now, hour: 23, minute: 0).addingTimeInterval(3 * 86400)),
                      updatedAt: now.addingTimeInterval(-60))
    }

    /// Board 41: 41% on battery, cutoff in 1 h 50 min, lid closed and awake, five working, two need you.
    static func board(now: Date = NightWatchFixtures.boardNow()) -> (snapshot: Coordinator.Snapshot, model: NowModel) {
        let pending = [
            NightWatchFixtures.event("bottle-flip", kind: .permission, context: "[Bash] rm -rf Builds/Dev/*.app\nDelete the dev builds",
                                     openedAt: now.addingTimeInterval(-4 * 60)),
            NightWatchFixtures.event("page", kind: .permission, context: "[Bash] swift test --filter Stuck\nRun the Stuck tests",
                                     openedAt: now.addingTimeInterval(-90))
        ]
        let snap = NightWatchFixtures.snapshot(
            sessions: NightWatchFixtures.working5,
            power: PowerSnapshot(percent: 41, onAC: false, hasBattery: true, isCharging: false),
            awake: AwakeAssertions(preventIdleSleep: true, preventSystemSleep: false),
            pending: pending,
            forecast: BatteryForecast.Estimate(percent: 41, cutoff: 10, drainPerHour: 17, minutesToCutoff: 110),
            lidClosedOnBattery: true, backends: backends(codex: true), usage: usage(now: now),
            usageHitAt: NightWatchFixtures.at(now, hour: 2, minute: 40))
        var i = NowInputs(snapshot: snap, now: now, macName: "Studio MBP", idleSeconds: 5)
        i.usage = snap.usage
        i.usageHitAt = snap.usageHitAt
        i.day = day
        i.route = NightWatchFixtures.route
        return (snap, NowModel.build(i))
    }

    /// The board's settings: cutoff 10%, pause, hold 1 h, both lid options on, resume on power at 25%.
    static func boardConfig() -> Config {
        var c = Config()
        c.lowBatteryCutoff = 10
        c.lowBatteryAction = .pause
        c.holdAwakeForPendingPageMinutes = 60
        c.keepAwakeLidClosedOnAC = true
        c.keepAwakeLidClosedOnBattery = true
        c.earlyBatteryPause = false
        c.resumeAfterBatteryRecovery = true
        c.recoveryThreshold = 25
        c.relayEnabled = true
        c.relayURL = "https://page-relay.roy.workers.dev"
        c.codexBackendEnabled = true
        return c
    }

    @MainActor
    static func store(section: TowerSection, config: Config = boardConfig(),
                      scene: (snapshot: Coordinator.Snapshot, model: NowModel) = board()) -> TowerStore {
        let st = TowerStore(config: config, macName: "Studio MBP")
        st.selection = section
        st.update(snapshot: scene.snapshot, model: scene.model)
        st.now = { NightWatchFixtures.boardNow() }
        st.preview(helper: .available, localLines: ["Ollama — generating · exact", "LM Studio — idle"],
                   usageCapture: TowerStore.UsageCaptureStatus(on: true))
        return st
    }

    /// Plugged in, odd values that no preset matches, the helper missing and wanted, Pause off.
    @MainActor
    static func acCustom(section: TowerSection) -> TowerStore {
        var c = boardConfig()
        c.lowBatteryCutoff = 12
        c.recoveryThreshold = 40
        c.recoveryRequiresAC = false
        c.holdAwakeForPendingPageMinutes = 90
        c.lowBatteryAction = .off
        let now = NightWatchFixtures.boardNow()
        let snap = NightWatchFixtures.snapshot(
            sessions: NightWatchFixtures.working5,
            power: PowerSnapshot(percent: 88, onAC: true, hasBattery: true, isCharging: true),
            backends: backends())
        var i = NowInputs(snapshot: snap, now: now, macName: "Studio MBP", idleSeconds: 5)
        i.day = day
        let st = store(section: section, config: c, scene: (snap, NowModel.build(i)))
        st.preview(helper: .missing)
        return st
    }
}
