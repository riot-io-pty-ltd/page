import XCTest
@testable import ClaudePowerMode

final class BatteryForecastTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func battery(_ pct: Int, ac: Bool = false) -> PowerSnapshot {
        PowerSnapshot(percent: pct, onAC: ac, hasBattery: true, isCharging: ac)
    }

    /// One reading a minute, dropping `perMinute` points each minute.
    private func drained(from start: Int, minutes: Int, perMinute: Double) -> BatteryForecast {
        var f = BatteryForecast()
        for m in 0...minutes {
            f.observe(battery(start - Int((Double(m) * perMinute).rounded(.down))), now: t0.addingTimeInterval(TimeInterval(m * 60)))
        }
        return f
    }

    func testSteadyDrainEstimate() {
        // 0.5 %/min = 30 %/h; from 40% down to 33% over 14 min.
        let f = drained(from: 40, minutes: 14, perMinute: 0.5)
        let e = f.estimate(cutoff: 10, now: t0.addingTimeInterval(14 * 60))
        XCTAssertNotNil(e)
        XCTAssertEqual(e!.percent, 33)
        XCTAssertEqual(e!.drainPerHour, 30, accuracy: 3)
        XCTAssertEqual(Double(e!.minutesToCutoff), 46, accuracy: 6)
        XCTAssertEqual(e!.heartbeatPayload["cutoff"] as? Int, 10)
    }

    func testNotEnoughToGoOn() {
        XCTAssertNil(drained(from: 40, minutes: 2, perMinute: 0.5).estimate(cutoff: 10, now: t0), "span too short")
        XCTAssertNil(drained(from: 40, minutes: 10, perMinute: 0).estimate(cutoff: 10, now: t0), "no drop")
        XCTAssertNil(BatteryForecast().estimate(cutoff: 10, now: t0))
    }

    func testACChargingAndDesktopsReset() {
        var f = drained(from: 40, minutes: 10, perMinute: 0.5)
        f.observe(battery(35, ac: true), now: t0.addingTimeInterval(11 * 60))
        XCTAssertTrue(f.samples.isEmpty)
        f = drained(from: 40, minutes: 10, perMinute: 0.5)
        f.observe(battery(50), now: t0.addingTimeInterval(11 * 60))
        XCTAssertEqual(f.samples.count, 1, "the charge went up: start over")
        f.observe(.noBattery, now: t0.addingTimeInterval(12 * 60))
        XCTAssertTrue(f.samples.isEmpty)
    }

    func testOldSamplesAgeOut() {
        let f = drained(from: 90, minutes: 60, perMinute: 0.5)
        XCTAssertLessThanOrEqual(f.samples.count, 22)
        XCTAssertGreaterThanOrEqual(f.samples.first!.at, t0.addingTimeInterval(40 * 60))
    }

    func testAtTheCutoff() {
        let f = drained(from: 14, minutes: 10, perMinute: 0.5)
        XCTAssertEqual(f.estimate(cutoff: 10, now: t0)?.minutesToCutoff, 0)
    }

    func testCopy() {
        XCTAssertEqual(BatteryForecast.duration(minutes: 5), "5 min")
        XCTAssertEqual(BatteryForecast.duration(minutes: 65), "1 h 5 min")
        XCTAssertEqual(BatteryForecast.duration(minutes: 120), "2 h")
        let e = BatteryForecast.Estimate(percent: 18, cutoff: 10, drainPerHour: 40, minutesToCutoff: 12)
        XCTAssertEqual(BatteryForecast.menuLine(e), "Cutoff (10%) in about 12 min at this rate")
        XCTAssertEqual(BatteryForecast.pageContext(e, busy: 3, action: .pause, earlyPause: false),
                       "Battery 18% — at this rate it reaches the 10% cutoff in about 12 min. 3 sessions are mid-task; Page will ask them to pause then. Plug in to keep them going.")
        XCTAssertTrue(BatteryForecast.pageContext(e, busy: 1, action: .pause, earlyPause: true).contains("1 session is mid-task; Page will ask it to pause about 10 min before the cutoff"))
    }

    func testPageHysteresis() {
        func e(_ m: Int) -> BatteryForecast.Estimate { .init(percent: 20, cutoff: 10, drainPerHour: 30, minutesToCutoff: m) }
        XCTAssertTrue(BatteryForecast.wantsPage(e(15), open: false, busy: 1, onAC: false, tripped: false))
        XCTAssertFalse(BatteryForecast.wantsPage(e(16), open: false, busy: 1, onAC: false, tripped: false))
        XCTAssertTrue(BatteryForecast.wantsPage(e(24), open: true, busy: 1, onAC: false, tripped: false), "stays open")
        XCTAssertFalse(BatteryForecast.wantsPage(e(26), open: true, busy: 1, onAC: false, tripped: false))
        XCTAssertFalse(BatteryForecast.wantsPage(e(5), open: true, busy: 0, onAC: false, tripped: false), "no agents working")
        XCTAssertFalse(BatteryForecast.wantsPage(e(5), open: true, busy: 1, onAC: true, tripped: false))
        XCTAssertFalse(BatteryForecast.wantsPage(e(5), open: true, busy: 1, onAC: false, tripped: true), "the pause took over")
        XCTAssertFalse(BatteryForecast.wantsPage(nil, open: true, busy: 1, onAC: false, tripped: false))
        XCTAssertTrue(BatteryForecast.isPageId(BatteryForecast.pageId(openedAt: t0)))
    }

    // MARK: early pause (Coordinator.batterySettings)

    func testDefaultSettingsAreUnchanged() {
        var cfg = Config()
        cfg.lowBatteryCutoff = 10
        let e = BatteryForecast.Estimate(percent: 13, cutoff: 10, drainPerHour: 30, minutesToCutoff: 6)
        XCTAssertEqual(Coordinator.batterySettings(cfg, power: battery(13), estimate: e), BatteryPolicy.Settings(cfg),
                       "early pause is opt-in")
    }

    func testEarlyPauseRaisesTheCutoffToTheCurrentCharge() {
        var cfg = Config()
        cfg.lowBatteryCutoff = 10
        cfg.recoveryThreshold = 25
        cfg.earlyBatteryPause = true
        let soon = BatteryForecast.Estimate(percent: 13, cutoff: 10, drainPerHour: 30, minutesToCutoff: 6)
        XCTAssertEqual(Coordinator.batterySettings(cfg, power: battery(13), estimate: soon).cutoff, 13)
        XCTAssertTrue(BatteryPolicy.shouldTrip(battery(13), cutoff: 13))
        let later = BatteryForecast.Estimate(percent: 20, cutoff: 10, drainPerHour: 30, minutesToCutoff: 20)
        XCTAssertEqual(Coordinator.batterySettings(cfg, power: battery(20), estimate: later).cutoff, 10)
        // Never at/above recovery (it would recover at once), never when off.
        let fast = BatteryForecast.Estimate(percent: 30, cutoff: 10, drainPerHour: 300, minutesToCutoff: 4)
        XCTAssertEqual(Coordinator.batterySettings(cfg, power: battery(30), estimate: fast).cutoff, 10)
        cfg.lowBatteryAction = .off
        XCTAssertEqual(Coordinator.batterySettings(cfg, power: battery(13), estimate: soon).cutoff, 10)
    }
}
