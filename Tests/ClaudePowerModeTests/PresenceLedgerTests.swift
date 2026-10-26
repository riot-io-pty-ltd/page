import XCTest
@testable import ClaudePowerMode

/// Away and return detection, the Welcome back ledger, and today's rings.
final class PresenceLedgerTests: XCTestCase {
    private let t = Date(timeIntervalSince1970: 1_761_300_000)
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func decision(_ id: String, openedAt: Date) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: "s", cwd: "/x/p", projectName: "p", kind: .permission, openedAt: openedAt,
                          context: "[Bash] swift test\nRun the tests", transcriptPath: "", backend: .claude, source: .terminal, subtype: nil)
    }

    private func review(_ id: String) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: "s", cwd: "/x/p", projectName: "p", kind: .idle, openedAt: t,
                          context: "Done. All green.", transcriptPath: "", backend: .claude, source: .terminal, subtype: nil)
    }

    private func stuck(_ id: String) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: "s", cwd: "/x/p", projectName: "p", kind: .idle, openedAt: t,
                          context: "No progress for 15 min — it may be hung.", transcriptPath: "", backend: .claude,
                          source: .terminal, subtype: "stuck")
    }

    private func forecast(_ id: String) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: "s", cwd: "/x/p", projectName: "p", kind: .idle, openedAt: t,
                          context: "Battery forecast.", transcriptPath: "", backend: .claude, source: .terminal, subtype: nil)
    }

    // MARK: PresenceTracker

    func testAtTheDeskNothingHappens() {
        var p = PresenceTracker(awayAfter: 120)
        XCTAssertEqual(p.observe(idle: 5, now: t), .none)
        XCTAssertFalse(p.isAway)
    }

    func testFirstReadingPastTheThresholdIsWentAwayAtTheLastInput() {
        var p = PresenceTracker(awayAfter: 120)
        XCTAssertEqual(p.observe(idle: 130, now: t.addingTimeInterval(130)), .wentAway)
        XCTAssertEqual(p.awaySince, t)
        XCTAssertTrue(p.isAway)
        XCTAssertEqual(p.observe(idle: 140, now: t.addingTimeInterval(140)), .none, "later idle readings are quiet")
    }

    func testReturnReportsHowLongTheAbsenceWas() {
        var p = PresenceTracker(awayAfter: 120)
        _ = p.observe(idle: 130, now: t.addingTimeInterval(130))
        let back = p.observe(idle: 2, now: t.addingTimeInterval(3300))
        guard case .returned(let awayFor) = back else { return XCTFail("expected .returned, got \(back)") }
        XCTAssertEqual(awayFor, 3298, accuracy: 0.5)
        XCTAssertFalse(p.isAway)
        XCTAssertNil(p.awaySince)
    }

    func testUnreadableOrNegativeIdleIsIgnored() {
        var p = PresenceTracker(awayAfter: 120)
        XCTAssertEqual(p.observe(idle: .infinity, now: t), .none)
        XCTAssertEqual(p.observe(idle: -1, now: t), .none)
        XCTAssertEqual(p.observe(idle: .nan, now: t), .none)
        XCTAssertFalse(p.isAway)
    }

    func testZeroThresholdTurnsTrackingOff() {
        var p = PresenceTracker(awayAfter: 0)
        XCTAssertEqual(p.observe(idle: 10_000, now: t), .none)
        XCTAssertFalse(p.isAway)
    }

    // MARK: AwayLedger

    func testAwayLedgerCountsFinishedTurnsOnly() {
        var ledger = AwayLedger(phoneRepliesAtStart: 3)
        ledger.observe(pending: [review("r1"), stuck("s1"), forecast("page-mac-battery_forecast-1"), decision("d1", openedAt: t)])
        ledger.observe(pending: [review("r1")])
        XCTAssertEqual(ledger.welcome(away: 52 * 60, needYou: 0, phoneRepliesNow: 9, rings: []).headline,
                       "You handled 6 from your phone.", "with nothing left needing you, phone work leads")
        XCTAssertEqual(ledger.welcome(away: 52 * 60, needYou: 1, phoneRepliesNow: 3, rings: []).headline,
                       "1 finished, 1 needs you.", "one finished turn, the stuck and forecast pages not counted")
    }

    func testAwayLedgerHeadlineCountsFinishedAndNeedsYou() {
        var ledger = AwayLedger(phoneRepliesAtStart: 3)
        ledger.observe(pending: [review("r1"), review("r2"), stuck("s1")])
        let w = ledger.welcome(away: 52 * 60, needYou: 1, phoneRepliesNow: 3, rings: [])
        XCTAssertEqual(w.headline, "2 finished, 1 needs you.")
        XCTAssertEqual(w.eyebrow, "WELCOME BACK · AWAY 52 MIN")
    }

    func testAwayLedgerNeverReportsNegativePhoneReplies() {
        let ledger = AwayLedger(phoneRepliesAtStart: 10)
        let w = ledger.welcome(away: 900, needYou: 0, phoneRepliesNow: 4, rings: [])
        XCTAssertEqual(w.headline, "Nothing needed you.")
    }

    // MARK: DayLedger

    func testAnsweredDecisionWithinTwoMinutesIsUnblocked() {
        var day = DayLedger(now: t, calendar: utc)
        day.observe(pending: [decision("d1", openedAt: t)], working: 1, now: t.addingTimeInterval(10), calendar: utc)
        day.observe(pending: [], working: 1, now: t.addingTimeInterval(60), calendar: utc)
        XCTAssertEqual(day.stats.decisions, 1)
        XCTAssertEqual(day.stats.unblockedFast, 1)
    }

    func testSlowDecisionIsCountedButNotUnblocked() {
        var day = DayLedger(now: t, calendar: utc)
        day.observe(pending: [decision("d2", openedAt: t)], working: 1, now: t.addingTimeInterval(200), calendar: utc)
        day.observe(pending: [], working: 1, now: t.addingTimeInterval(260), calendar: utc)
        XCTAssertEqual(day.stats.decisions, 1)
        XCTAssertEqual(day.stats.unblockedFast, 0, "open 200 s at the last look, past the two-minute window")
    }

    func testFinishedTurnIsCountedOnceAsShipped() {
        var day = DayLedger(now: t, calendar: utc)
        day.observe(pending: [review("r1")], working: 0, now: t, calendar: utc)
        day.observe(pending: [review("r1")], working: 0, now: t.addingTimeInterval(10), calendar: utc)
        XCTAssertEqual(day.stats.finished, 1)
        XCTAssertEqual(day.stats.shipped, 1)
    }

    func testStuckPageIsFinishedButNotShipped() {
        var day = DayLedger(now: t, calendar: utc)
        day.observe(pending: [stuck("s1")], working: 1, now: t, calendar: utc)
        day.observe(pending: [stuck("s1")], working: 1, now: t.addingTimeInterval(10), calendar: utc)
        XCTAssertEqual(day.stats.finished, 1)
        XCTAssertEqual(day.stats.shipped, 0)
    }

    func testForecastPagesAreNotCounted() {
        var day = DayLedger(now: t, calendar: utc)
        day.observe(pending: [forecast("page-mac-battery_forecast-1")], working: 1, now: t, calendar: utc)
        day.observe(pending: [], working: 1, now: t.addingTimeInterval(10), calendar: utc)
        XCTAssertEqual(day.stats.finished, 0)
        XCTAssertEqual(day.stats.shipped, 0)
    }

    func testCalmGrowsWhileAgentsWorkWithNothingWaiting() {
        var day = DayLedger(now: t, calendar: utc)
        day.observe(pending: [], working: 2, now: t, calendar: utc)
        day.observe(pending: [], working: 2, now: t.addingTimeInterval(60), calendar: utc)
        XCTAssertEqual(day.stats.calmSeconds, 60, accuracy: 0.001)
    }

    func testCalmGapIsCappedSoSleepDoesNotCount() {
        var day = DayLedger(now: t, calendar: utc)
        day.observe(pending: [], working: 2, now: t, calendar: utc)
        day.observe(pending: [], working: 2, now: t.addingTimeInterval(3600), calendar: utc)
        XCTAssertEqual(day.stats.calmSeconds, DayLedger.maxGap, accuracy: 0.001)
    }

    func testCalmStopsWhileADecisionIsOpenOrNothingWorks() {
        var waiting = DayLedger(now: t, calendar: utc)
        waiting.observe(pending: [decision("d3", openedAt: t)], working: 2, now: t, calendar: utc)
        waiting.observe(pending: [decision("d3", openedAt: t)], working: 2, now: t.addingTimeInterval(60), calendar: utc)
        XCTAssertEqual(waiting.stats.calmSeconds, 0)

        var idle = DayLedger(now: t, calendar: utc)
        idle.observe(pending: [], working: 0, now: t, calendar: utc)
        idle.observe(pending: [], working: 0, now: t.addingTimeInterval(60), calendar: utc)
        XCTAssertEqual(idle.stats.calmSeconds, 0)
    }

    func testStatsStartOverAtLocalMidnight() {
        var day = DayLedger(now: t, calendar: utc)
        day.observe(pending: [review("r1")], working: 0, now: t, calendar: utc)
        XCTAssertEqual(day.stats.shipped, 1)
        let nextDay = t.addingTimeInterval(24 * 3600)
        day.observe(pending: [], working: 0, now: nextDay, calendar: utc)
        XCTAssertEqual(day.stats.shipped, 0)
        XCTAssertEqual(day.stats.finished, 0)
        XCTAssertEqual(day.dayStart, utc.startOfDay(for: nextDay))
    }
}
