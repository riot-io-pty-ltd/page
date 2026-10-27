import XCTest
import PageWidgetSupport

/// The throttle between Page and WidgetKit: writes at most every 5 s, reloads
/// at most every 30 s, a heartbeat write every 10 min, and no change dropped.
/// Clocked by the test, so it runs without waiting.
final class WidgetPublishGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private func fp(_ n: Int) -> Data { Data("state-\(n)".utf8) }

    func testTheFirstOfferWritesAndReloads() {
        var gate = WidgetPublishGate()
        let a = gate.offer(fingerprint: fp(1), now: t0)
        XCTAssertTrue(a.write)
        XCTAssertTrue(a.reload)
    }

    func testAHeartbeatWritesButNeverReloads() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), urgent: fp(1), now: t0)
        let beat = gate.offer(fingerprint: fp(1), urgent: fp(1), now: t0.addingTimeInterval(10 * 60))
        XCTAssertTrue(beat.write)
        XCTAssertFalse(beat.reload, "a heartbeat must not spend a WidgetKit reload")
    }

    func testANonUrgentChangeIsWrittenAtOnceButReloadedOnlyEveryFifteenMinutes() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), urgent: fp(1), now: t0)
        let step = gate.offer(fingerprint: fp(2), urgent: fp(1), now: t0.addingTimeInterval(60))
        XCTAssertTrue(step.write)
        XCTAssertFalse(step.reload)
        XCTAssertEqual(step.recheckIn ?? -1, 14 * 60, accuracy: 0.001)
        let early = gate.offer(fingerprint: fp(2), urgent: fp(1), now: t0.addingTimeInterval(10 * 60))
        XCTAssertFalse(early.reload)
        let due = gate.offer(fingerprint: fp(2), urgent: fp(1), now: t0.addingTimeInterval(15 * 60))
        XCTAssertTrue(due.reload, "an owed reload happens, only later")
    }

    func testAnUrgentChangeReloadsWithinThirtySecondsEvenWhenALazyReloadIsOwed() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), urgent: fp(1), now: t0)
        _ = gate.offer(fingerprint: fp(2), urgent: fp(1), now: t0.addingTimeInterval(60))
        let urgent = gate.offer(fingerprint: fp(3), urgent: fp(3), now: t0.addingTimeInterval(70))
        XCTAssertTrue(urgent.write)
        XCTAssertTrue(urgent.reload)
    }

    /// The reviewer's case: on battery something changes every 15 s tick. Count what WidgetKit is asked.
    func testADayOfNonUrgentTicksStaysUnderTheReloadBudget() {
        var gate = WidgetPublishGate()
        var reloads = 0
        var n = 0
        for second in stride(from: 0, to: 24 * 3600, by: 15) {
            // The step text changes every minute; nothing that needs the person.
            n = second / 60
            if gate.offer(fingerprint: fp(n), urgent: fp(0), now: t0.addingTimeInterval(TimeInterval(second))).reload { reloads += 1 }
        }
        XCTAssertLessThanOrEqual(reloads, 100)
    }

    func testTheSameStateAgainWithinTheHeartbeatDoesNothing() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), now: t0)
        let a = gate.offer(fingerprint: fp(1), now: t0.addingTimeInterval(120))
        XCTAssertEqual(a, WidgetPublishGate.Action())
    }

    func testAChangeTooSoonAfterAWriteIsHeldAndAskedForAgain() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), now: t0)
        let held = gate.offer(fingerprint: fp(2), now: t0.addingTimeInterval(2))
        XCTAssertFalse(held.write)
        XCTAssertEqual(held.recheckIn ?? -1, 3, accuracy: 0.001)
    }

    func testAHeldChangeIsWrittenWhenTheWindowOpens() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), now: t0)
        _ = gate.offer(fingerprint: fp(2), now: t0.addingTimeInterval(2))
        let later = gate.offer(fingerprint: fp(2), now: t0.addingTimeInterval(5))
        XCTAssertTrue(later.write)
    }

    func testAChangeIsNeverDroppedOnlyDelayedBeyondTheReloadWindow() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), now: t0)
        // Written at once after 5 s, but the reload is owed until 30 s after the last reload.
        let w = gate.offer(fingerprint: fp(2), now: t0.addingTimeInterval(5))
        XCTAssertTrue(w.write)
        XCTAssertFalse(w.reload)
        XCTAssertEqual(w.recheckIn ?? -1, 25, accuracy: 0.001)
        let r = gate.offer(fingerprint: fp(2), now: t0.addingTimeInterval(30))
        XCTAssertTrue(r.reload, "the owed reload must happen, not be lost")
        XCTAssertFalse(r.write)
    }

    func testABurstOfChangesIsCappedAndEndsReloaded() {
        var gate = WidgetPublishGate()
        var writes = 0, reloads = 0
        var last = 0
        // A change every second for 58 s. The last one (58 s) falls inside the 5 s
        // write window that opened at 55 s, so it is held and must be offered again.
        for s in 0...58 {
            let a = gate.offer(fingerprint: fp(s), now: t0.addingTimeInterval(TimeInterval(s)))
            if a.write { writes += 1 }
            if a.reload { reloads += 1 }
            last = s
        }
        XCTAssertLessThanOrEqual(writes, 12, "at most one write per 5 s (0, 5, …, 55)")
        XCTAssertLessThanOrEqual(reloads, 2, "at most one reload per 30 s (0 and 30)")
        // Quiet afterwards: the held state is offered again and must reach the widgets within the windows.
        var firstWrite: Int?
        var firstReload: Int?
        for t in (last + 1)...(last + 120) {
            let a = gate.offer(fingerprint: fp(last), now: t0.addingTimeInterval(TimeInterval(t)))
            if a.write, firstWrite == nil { firstWrite = t }
            if a.reload, firstReload == nil { firstReload = t }
        }
        XCTAssertNotNil(firstWrite, "the held change was never written")
        XCTAssertNotNil(firstReload, "the held change was never reloaded")
        XCTAssertLessThanOrEqual((firstWrite ?? .max) - last, 5)
        XCTAssertLessThanOrEqual((firstReload ?? .max) - last, 30)
    }

    func testAHeartbeatWriteAfterTenMinutesWithNoChange() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), now: t0)
        XCTAssertFalse(gate.offer(fingerprint: fp(1), now: t0.addingTimeInterval(9 * 60)).write)
        let beat = gate.offer(fingerprint: fp(1), now: t0.addingTimeInterval(10 * 60))
        XCTAssertTrue(beat.write)
    }

    func testForceWritesAndReloadsWhateverTheThrottle() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), now: t0)
        let forced = gate.offer(fingerprint: fp(1), now: t0.addingTimeInterval(1), force: true)
        XCTAssertTrue(forced.write)
        XCTAssertTrue(forced.reload)
    }

    func testAClockThatWentBackwardsDoesNotFreezeTheWidgets() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), now: t0)
        let back = gate.offer(fingerprint: fp(2), now: t0.addingTimeInterval(-60))
        XCTAssertTrue(back.write, "a clock set back must not hold a change forever")
    }

    func testOnlyAChangeToWhatIsShownCountsAsAChange() {
        var gate = WidgetPublishGate()
        _ = gate.offer(fingerprint: fp(1), now: t0)
        // Same bytes, later time: not a change, so no reload.
        let a = gate.offer(fingerprint: fp(1), now: t0.addingTimeInterval(40))
        XCTAssertFalse(a.reload)
    }
}
