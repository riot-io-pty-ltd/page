import XCTest
@testable import ClaudePowerMode

/// The signature motions as the Now store records them: what flies in and what
/// waits behind the pill, the exhale when the last item clears, dusk and dawn,
/// a reply's receipt thread, a hold's unwind and the Touch ID burst. The clock
/// is pinned, so every boundary is an exact number of seconds.
@MainActor
final class NowMotionStoreTests: XCTestCase {
    private var clock = NWMotionFixtures.t0

    private func store(_ inputs: NowInputs) -> NowStore {
        let st = NowStore(model: NowModel.build(inputs))
        st.now = { self.clock }
        st.animates = true
        return st
    }

    private func later(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
    }

    /// The needs-you fixture before and after the page approval arrives.
    private var before: NowModel { NowModel.build(NWMotionFixtures.needsYouBefore()) }
    private var after: NowModel { NowModel.build(NightWatchFixtures.needsYou(now: clock)) }

    private var newIds: Set<String> {
        Set(after.rows.map(\.id)).subtracting(before.rows.map(\.id))
    }

    // MARK: arrivals (the Final approach)

    func testANewRowFliesInFromThePulseAndOnlyNewRowsDo() {
        XCTAssertFalse(newIds.isEmpty, "the fixture adds a row")
        let st = store(NWMotionFixtures.needsYouBefore())
        st.update(after)
        XCTAssertEqual(Set(st.motion.arrivals.keys), newIds, "only the genuinely new rows approach")
        XCTAssertTrue(newIds.isSubset(of: Set(st.shownRows.map(\.id))), "and they are drawn")
        // The first arrival leaves the pulse now; the next one a stagger after it.
        let times = newIds.compactMap { st.motion.arrivals[$0] }.sorted()
        XCTAssertEqual(times.first, clock)
    }

    func testNothingFliesInWhenThePanelIsNotOnScreen() {
        let st = store(NWMotionFixtures.needsYouBefore())
        st.animates = false
        st.update(after)
        XCTAssertTrue(st.motion.arrivals.isEmpty, "a closed panel plays nothing")
        XCTAssertTrue(newIds.isSubset(of: Set(st.shownRows.map(\.id))), "the new row is simply there")
    }

    func testWhileThePointerIsOnTheListNewRowsWaitBehindThePill() {
        let st = store(NWMotionFixtures.needsYouBefore())
        st.pointerInList = true
        st.update(after)
        XCTAssertEqual(st.queuedNew, newIds.count, "the pill counts what is waiting")
        XCTAssertTrue(Set(st.shownRows.map(\.id)).isDisjoint(with: newIds), "nothing re-sorts under the pointer")
        XCTAssertTrue(st.motion.arrivals.isEmpty, "and nothing flies in under it")

        st.pointerInList = false
        XCTAssertEqual(st.queuedNew, 0)
        XCTAssertTrue(newIds.isSubset(of: Set(st.shownRows.map(\.id))), "released, the rows come in")
        XCTAssertFalse(st.motion.arrivals.isEmpty, "and fly in from the pulse")
    }

    func testThePillLetsTheHeldRowsInWithoutWaitingForTheDeferral() {
        let st = store(NWMotionFixtures.needsYouBefore())
        st.pointerInList = true
        st.update(after)
        st.showNew()
        XCTAssertEqual(st.queuedNew, 0)
        XCTAssertTrue(newIds.isSubset(of: Set(st.shownRows.map(\.id))))
    }

    // MARK: the exhale and dusk and dawn

    func testTheLastItemClearingStartsTheExhaleFromThatMoment() {
        let inputs = NightWatchFixtures.needsYou(now: clock)
        let old = NowModel.build(inputs)
        let waiting = old.needYouCount > 0 ? old.needYouCount : old.lookCount
        XCTAssertGreaterThan(waiting, 0)
        let st = store(inputs)
        st.update(NowModel.build(NightWatchFixtures.allQuiet(now: clock)))
        XCTAssertEqual(st.motion.clearedAt, clock, "the amber exhales from here")
        XCTAssertEqual(st.motion.clearedRings, PulseModel.ringCount(waiting: waiting), "one ring per item that cleared")
    }

    func testAPanelClosedWhenTheLastItemClearsDoesNotExhale() {
        let st = store(NightWatchFixtures.needsYou(now: clock))
        st.animates = false
        st.update(NowModel.build(NightWatchFixtures.allQuiet(now: clock)))
        XCTAssertNil(st.motion.clearedAt)
    }

    func testThePowerPauseDimsTheSkyAndTheResumeRelightsOnlyConfirmedStars() throws {
        let st = store(NWMotionFixtures.workingSix(now: clock))
        st.update(NowModel.build(NWMotionFixtures.pausedSix(now: clock)))
        XCTAssertEqual(st.motion.duskAt, clock, "the cutoff began the dusk")
        XCTAssertNil(st.motion.dawn)

        later(30)
        st.update(NowModel.build(NWMotionFixtures.workingSix(now: clock)))
        XCTAssertNil(st.motion.duskAt, "power is back")
        let dawn = try XCTUnwrap(st.motion.dawn)
        XCTAssertEqual(dawn.stars.count, 6, "one star per paused agent")
        XCTAssertEqual(dawn.startedAt, clock)

        st.confirmResumed(sessionIds: ["sess-page"])
        XCTAssertEqual(st.motion.dawn?.confirmed["sess-page"], clock, "a confirmed resume lights its star")
        XCTAssertNil(st.motion.dawn?.confirmed["sess-docs"], "the others stay dim until they are seen working")
        st.confirmResumed(sessionIds: [])
        XCTAssertEqual(st.motion.dawn?.confirmed.count, 1, "an empty confirmation changes nothing")
    }

    // MARK: the hold

    func testLettingGoEarlyUnwindsTheRingAndThePassedTicksBuzzOnce() throws {
        let st = store(NightWatchFixtures.needsYou(now: clock))
        var ticks: [Double] = []
        st.haptic = { ticks.append($0) }
        st.beginHold(.stopAll)
        // 5.5 s in: 0.3 s dead zone, then (5.5 - 0.3) / 9.7 of the 10 s Stop-all
        // fill. Off the exact tick so the Date's rounding cannot decide the crossing.
        later(5.5)
        st.tick()
        XCTAssertEqual(ticks, [0.25, 0.5], "the quarter and half ticks have passed")
        XCTAssertEqual(st.holdProgress, 5.2 / 9.7, accuracy: 1e-3)

        st.endHold()
        let unwind = try XCTUnwrap(st.motion.unwind, "letting go unwinds the ring")
        XCTAssertEqual(unwind.from, 5.2 / 9.7, accuracy: 1e-3, "from where it was let go")
        XCTAssertEqual(ticks, [0.25, 0.5], "an unwind buzzes nothing")
    }

    // MARK: a reply's receipt thread

    /// The page row in the needs-you fixture: the one that a before/after pair toggles.
    private func pageRow(_ model: NowModel) throws -> DecideRow {
        try XCTUnwrap(model.rows.first { $0.projectName == "page" })
    }

    func testAVerifiedReplyFoldsAwayAndStaysHiddenUntilItsPageCloses() throws {
        let model = after
        let row = try pageRow(model)
        let st = store(NightWatchFixtures.needsYou(now: clock))
        st.select(row.id)
        st.handle(NowKeyPress(key: .char("1")))
        XCTAssertTrue(st.sending.contains(row.id), "the row is busy while its reply is on its way")

        later(0.2)
        st.markSent(rowId: row.id)
        XCTAssertEqual(st.motion.threads[row.id]?.sentAt, clock)
        st.finishSending(rowId: row.id, outcome: .delivered)
        XCTAssertEqual(st.motion.threads[row.id]?.resolution, .verified, "only a confirmed delivery is verified")
        XCTAssertFalse(st.sending.contains(row.id))
        XCTAssertTrue(st.shownRows.contains { $0.id == row.id }, "it stays in place while the thread plays")

        later(1.4)
        st.update(model)
        XCTAssertFalse(st.shownRows.contains { $0.id == row.id }, "folded: hidden while its page is still open")

        st.update(before)   // the page closes
        XCTAssertNil(st.motion.threads[row.id], "once its page has closed the thread is gone")
    }

    func testAQueuedOrFailedReplyIsNeverDrawnAsVerified() throws {
        let row = try pageRow(after)
        let st = store(NightWatchFixtures.needsYou(now: clock))
        st.select(row.id)
        st.handle(NowKeyPress(key: .char("1")))
        st.markSent(rowId: row.id)
        st.finishSending(rowId: row.id, outcome: .queued)
        XCTAssertEqual(st.motion.threads[row.id]?.resolution, .queued, "accepted is not landed")
        XCTAssertNotEqual(st.motion.threads[row.id]?.resolution, .verified)
    }

    func testAClosedPageKeepsItsRowAsAGhostUntilTheMacAnswers() throws {
        let row = try pageRow(after)
        let st = store(NightWatchFixtures.needsYou(now: clock))
        st.select(row.id)
        st.handle(NowKeyPress(key: .char("1")))
        st.markSent(rowId: row.id)
        st.update(before)   // the page closed while the reply was out
        XCTAssertTrue(st.shownRows.contains { $0.id == row.id }, "a ghost in its old place")

        later(20)
        st.update(before)
        XCTAssertTrue(st.shownRows.contains { $0.id == row.id }, "still waiting on the Mac: it stays however long")

        st.finishSending(rowId: row.id, outcome: .timedOut)
        later(1)
        st.update(before)
        XCTAssertTrue(st.shownRows.contains { $0.id == row.id }, "the failure is said in words for a few seconds")
        later(4)
        st.update(before)
        XCTAssertFalse(st.shownRows.contains { $0.id == row.id }, "then the row goes")
    }

    func testAnIrreversibleApproveBurstsOnceTouchIDPassesAndNothingIsSentWithoutIt() throws {
        let model = NowModel.build(NightWatchFixtures.needsYou(now: clock))
        let row = try XCTUnwrap(model.rows.first { $0.keys.contains { $0.action == .approveHold } },
                                "the fixture has an irreversible row")
        let st = store(NightWatchFixtures.needsYou(now: clock))
        st.select(row.id)
        st.handle(NowKeyPress(key: .char("1")))
        later(1.5)
        st.tick()
        XCTAssertEqual(st.motion.threads[row.id]?.authenticating, true, "the hold passed: Touch ID is next")
        XCTAssertNil(st.motion.threads[row.id]?.sentAt, "nothing has been sent yet")

        st.markSent(rowId: row.id)
        XCTAssertEqual(st.motion.burst?.rowId, row.id, "the burst plays for the row Touch ID passed")
        XCTAssertEqual(st.motion.threads[row.id]?.authenticating, false)
        XCTAssertNotNil(st.motion.threads[row.id]?.sentAt)

        st.finishSending(rowId: row.id, outcome: nil)
        XCTAssertNil(st.motion.threads[row.id], "nothing was confirmed, so the thread simply drops")
    }
}
