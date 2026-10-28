import XCTest
@testable import ClaudePowerMode

/// The pure timing and phase models behind Night Watch's signature motions
/// (SignatureMotion.swift), and the glyph's colour and frame-rate rules.
/// Plain numbers in, frames out: nothing here reads a clock.
final class SignatureMotionTests: XCTestCase {
    private func near(_ a: Double, _ b: Double, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: 1e-3, msg, file: file, line: line)
    }

    // MARK: curves and the spring

    func testCurvesClampAndEase() {
        XCTAssertEqual(MotionCurve.clamp01(-1), 0)
        XCTAssertEqual(MotionCurve.clamp01(2), 1)
        near(MotionCurve.smoothstep(0, 1, 0.5), 0.5)
        XCTAssertEqual(MotionCurve.smoothstep(0, 1, -3), 0)
        XCTAssertEqual(MotionCurve.smoothstep(0, 1, 9), 1)
        // A zero-width smoothstep is a hard step.
        XCTAssertEqual(MotionCurve.smoothstep(0.5, 0.5, 0.4), 0)
        XCTAssertEqual(MotionCurve.smoothstep(0.5, 0.5, 0.6), 1)
        near(MotionCurve.easeOut(0.5), 0.875)
        near(MotionCurve.easeIn(0.5), 0.125)
        near(MotionCurve.easeInOut(0.25), 0.0625)
        near(MotionCurve.easeInOut(0.75), 0.9375)
        near(MotionCurve.segment(0.5, start: 0, duration: 1), 0.5)
        XCTAssertEqual(MotionCurve.segment(0.1, start: 0.2, duration: 1), 0)
        XCTAssertEqual(MotionCurve.segment(0.3, start: 0.2, duration: 0), 1, "a zero-length segment is done at its start")
        near(MotionCurve.fract(-0.25), 0.75)
        near(MotionCurve.fract(1.25), 0.25)
    }

    func testApproachSpringStepsFromZeroAndOvershootsThenSettles() {
        XCTAssertEqual(MotionSpring.approach.value(at: 0), 0)
        XCTAssertEqual(MotionSpring.approach.value(at: -1), 0)
        near(MotionSpring.approach.value(at: 0.18), 0.7519)
        near(MotionSpring.approach.value(at: 0.36), 1.0096)
        XCTAssertGreaterThan(MotionSpring.approach.value(at: 0.36), 1, "an underdamped spring overshoots a little")
        near(MotionSpring.approach.value(at: 10), 1, "and settles on 1")
    }

    func testCriticallyDampedSpringNeverOvershoots() {
        let s = MotionSpring(response: 0.5, dampingFraction: 1)
        near(s.value(at: 0.3), 0.8900)
        for t in stride(from: 0.0, through: 2.0, by: 0.02) {
            XCTAssertLessThanOrEqual(s.value(at: t), 1 + 1e-9, "no overshoot at \(t)")
        }
    }

    // MARK: the pulse

    func testPulseModeChoosesPausedThenWaitingThenWorkingThenQuiet() {
        XCTAssertEqual(PulseModel.mode(waiting: 2, working: 3, paused: true), .paused, "a battery pause wins")
        XCTAssertEqual(PulseModel.mode(waiting: 2, working: 3, paused: false), .waiting(count: 2))
        XCTAssertEqual(PulseModel.mode(waiting: 0, working: 3, paused: false), .working(agents: 3))
        XCTAssertEqual(PulseModel.mode(waiting: 0, working: 0, paused: false), .quiet)
    }

    func testBreathPeriodQuickensWithAgentsButNeverBelowThreeSeconds() {
        near(PulseModel.breathPeriod(agents: 1), 4)
        near(PulseModel.breathPeriod(agents: 0), 4, "no agents counts as one")
        near(PulseModel.breathPeriod(agents: 5), 3.4, "0.15 s quicker per extra agent")
        near(PulseModel.breathPeriod(agents: 11), 3)
        near(PulseModel.breathPeriod(agents: 1000), 3, "the floor holds: only slightly faster")
        XCTAssertLessThan(PulseModel.breathPeriod(agents: 2), PulseModel.breathPeriod(agents: 1))
        for n in 1...50 {
            XCTAssertGreaterThanOrEqual(PulseModel.breathPeriod(agents: n), 3 - 1e-9)
        }
    }

    func testBreathIsEasedBetweenOutAndIn() {
        near(PulseModel.breath(at: 0, agents: 1), 0, "out at the start")
        near(PulseModel.breath(at: 2, agents: 1), 1, "in at half a breath")
        near(PulseModel.breath(at: 4, agents: 1), 0, "and out again after one period")
        for i in 0...100 {
            let b = PulseModel.breath(at: Double(i) * 0.07, agents: 3)
            XCTAssertTrue(b >= -1e-9 && b <= 1 + 1e-9, "breath stays in 0...1")
        }
    }

    func testRippleIntervalShortensWithTheWaitAndNeverGoesBelowOneAndAHalf() {
        near(PulseModel.rippleInterval(longestWait: 0), 3, "a fresh wait: one ring every 3 s")
        near(PulseModel.rippleInterval(longestWait: 300), 2.25)
        near(PulseModel.rippleInterval(longestWait: 600), 1.5, "the cap, at ten minutes")
        near(PulseModel.rippleInterval(longestWait: 3600), 1.5, "and it holds")
        near(PulseModel.rippleInterval(longestWait: -50), 3, "a negative wait counts as none")
    }

    func testRingCountIsOnePerWaitingItemCappedAtFour() {
        XCTAssertEqual(PulseModel.ringCount(waiting: 1), 1)
        XCTAssertEqual(PulseModel.ringCount(waiting: 3), 3)
        XCTAssertEqual(PulseModel.ringCount(waiting: 9), 4)
        XCTAssertEqual(PulseModel.ringCount(waiting: 9, cap: 3), 3, "the menu-bar glyph caps at three")
        XCTAssertEqual(PulseModel.ringCount(waiting: -2), 0)
    }

    func testRingLifeGrowsWithRingsButIsNeverQuickerThanOneAndAHalfPerRing() {
        near(PulseModel.ringLife(waiting: 1, longestWait: 0), 3)
        near(PulseModel.ringLife(waiting: 2, longestWait: 0), 3)
        near(PulseModel.ringLife(waiting: 3, longestWait: 0), 4.5)
        near(PulseModel.ringLife(waiting: 5, longestWait: 0), 6, "five waiting still draws four rings")
        near(PulseModel.ringLife(waiting: 1, longestWait: 3600), 1.5)
        near(PulseModel.emissionInterval(waiting: 3, longestWait: 600), 1.5, "a new ring leaves every life/n")
    }

    /// The pulse keeps one rhythm on every surface: this table is pinned word
    /// for word by the phone's logic tests (testPulseTimingsMatchTheMac in
    /// iOS/Tests/LogicTests.swift). Change a number here and there together.
    func testPulseTimingsMatchThePhone() {
        // Breath period by agents working.
        for (agents, period) in [(1, 4.0), (5, 3.4), (20, 3.0)] {
            near(PulseModel.breathPeriod(agents: agents), period, "breath with \(agents) working")
        }
        // Seconds between two rings leaving the dot, by items waiting and the longest wait.
        let emission: [(Int, Double, Double)] = [(1, 0, 3), (1, 300, 2.25), (1, 3600, 1.5),
                                                 (3, 0, 1.5), (3, 300, 1.5), (3, 3600, 1.5)]
        for (waiting, wait, interval) in emission {
            near(PulseModel.emissionInterval(waiting: waiting, longestWait: wait), interval, "\(waiting) waiting, \(wait) s")
        }
        // How long one ring takes to travel out.
        for (waiting, wait, life) in [(1, 0.0, 3.0), (3, 0, 4.5), (4, 3600, 6)] {
            near(PulseModel.ringLife(waiting: waiting, longestWait: wait), life, "ring life, \(waiting) waiting")
        }
        near(PulseModel.ringAlpha(0.05), 0.46297)
        near(PulseModel.ringAlpha(0.5), 0.35355)
    }

    func testThePulsePaceComesOnlyFromTheRowsItCounts() {
        let model = NowModel.build(NightWatchFixtures.needsYou())
        let now = NWMotionFixtures.t0.addingTimeInterval(3600)
        func oldest(_ rows: [DecideRow]) -> Double { rows.map { now.timeIntervalSince($0.waitingSince) }.max() ?? 0 }
        let decide = model.rows.filter { $0.section == .decide }
        XCTAssertFalse(decide.isEmpty)
        near(PulseModel.longestWait(rows: model.rows, now: now), oldest(decide), "decisions waiting: only their wait counts")
        let rest = model.rows.filter { $0.section != .decide }
        near(PulseModel.longestWait(rows: rest, now: now), oldest(rest.filter { $0.section == .look }),
             "no decisions: the looks' wait, never a finished turn's")
        XCTAssertEqual(PulseModel.longestWait(rows: [], now: now), 0)
    }

    func testRingsAreEvenlySpacedAndFadeInAndOut() {
        let rings = PulseModel.rings(at: 0, waiting: 2, longestWait: 0)
        XCTAssertEqual(rings.map(\.progress).count, 2)
        near(rings[0].progress, 0)
        near(rings[1].progress, 0.5)
        near(rings[0].alpha, 0, "a ring leaving the dot starts invisible")
        near(rings[1].alpha, 0.35355, "half way out it is a third visible")
        near(PulseModel.ringAlpha(0.05), 0.46297, "it fades in over the first tenth so it never pops")
        near(PulseModel.ringAlpha(1), 0, "and is gone when fully out")
        XCTAssertTrue(PulseModel.rings(at: 0, waiting: 0, longestWait: 0).isEmpty, "nothing waiting, no rings")
        for i in 0...200 {
            for r in PulseModel.rings(at: Double(i) * 0.05, waiting: 4, longestWait: 300) {
                XCTAssertTrue(r.progress >= 0 && r.progress < 1, "progress wraps into 0..<1")
                XCTAssertTrue(r.alpha >= -1e-9 && r.alpha <= 1 + 1e-9)
            }
        }
    }

    func testExhaleTurnsAmberToTealOverEightHundredMilliseconds() {
        let start = PulseModel.exhale(elapsed: 0)
        near(start.tealMix, 0)
        near(start.ringFade, 1)
        near(start.swell, 0)
        XCTAssertFalse(start.finished)
        let mid = PulseModel.exhale(elapsed: 0.4)
        near(mid.tealMix, 0.5)
        near(mid.swell, 0.24, "one swell at its peak")
        near(mid.ringFade, 0.125)
        near(mid.auroraSettle, 0.14815)
        let end = PulseModel.exhale(elapsed: 0.8)
        near(end.tealMix, 1)
        near(end.ringFade, 0, "the rings that were out are gone")
        near(end.auroraSettle, 0.85185)
        XCTAssertFalse(PulseModel.exhale(elapsed: 1.39).finished)
        let done = PulseModel.exhale(elapsed: 1.4)
        near(done.starMix, 1, "nothing working: it cools to star-white")
        XCTAssertTrue(done.finished)
    }

    // MARK: the glyph

    func testGlyphDotIsAmberAtTheStartOfTheExhaleAndTealAtTheEnd() {
        let working = GlyphState(mode: .working(agents: 1))
        func same(_ a: NightWatch.RGBA, _ b: NightWatch.RGBA) -> Bool {
            abs(a.r - b.r) < 1e-9 && abs(a.g - b.g) < 1e-9 && abs(a.b - b.b) < 1e-9 && abs(a.a - b.a) < 1e-9
        }
        let start = GlyphDrawing.make(working, exhale: PulseModel.exhale(elapsed: 0)).dotColor
        XCTAssertTrue(same(start, NightWatch.Palette.amber), "the exhale starts amber")
        let end = GlyphDrawing.make(working, exhale: PulseModel.exhale(elapsed: 0.8)).dotColor
        XCTAssertTrue(same(end, NightWatch.Palette.teal), "and is teal once the colour has turned")
        XCTAssertTrue(same(GlyphDrawing.make(working).dotColor, NightWatch.Palette.teal), "no exhale: the working colour")
    }

    func testGlyphFrameRatesStayUnderTheBatteryCeiling() {
        XCTAssertLessThanOrEqual(GlyphAnimator.framesPerSecond, 30)
        XCTAssertLessThanOrEqual(GlyphAnimator.exhaleFramesPerSecond, 30)
        XCTAssertEqual(GlyphAnimator.framesPerSecond, 8)
        XCTAssertEqual(GlyphAnimator.exhaleFramesPerSecond, 15)
        // The panel's clocks: continuous motion (aurora, breath, ripple) at most 30 fps,
        // a short one-shot at most 60 and only for its own length.
        XCTAssertLessThanOrEqual(NWMotionRate.ambient, 30)
        XCTAssertLessThanOrEqual(NWMotionRate.oneShot, 60)
    }

    func testOnlyMovingGlyphStatesAnimateAndTheExhaleFollowsWorkingOrQuiet() {
        XCTAssertTrue(GlyphAnimator.animates(.working(agents: 1)))
        XCTAssertTrue(GlyphAnimator.animates(.needsYou(count: 1)))
        XCTAssertFalse(GlyphAnimator.animates(.quiet))
        XCTAssertFalse(GlyphAnimator.animates(.paused))
        XCTAssertFalse(GlyphAnimator.animates(.off))
        XCTAssertTrue(GlyphAnimator.exhalesInto(.working(agents: 1)))
        XCTAssertTrue(GlyphAnimator.exhalesInto(.quiet))
        XCTAssertFalse(GlyphAnimator.exhalesInto(.paused))
        XCTAssertFalse(GlyphAnimator.exhalesInto(.needsYou(count: 1)))
        XCTAssertFalse(GlyphAnimator.exhalesInto(.off))
    }

    func testQuantisedPhaseSnapsToSteps() {
        near(GlyphAnimator.quantised(0.26, steps: 4), 0.25)
        near(GlyphAnimator.quantised(0.5), 0.5)
        near(GlyphAnimator.quantised(0.49), 0.458333, "phase 0.49 falls in step 11 of 24")
        near(GlyphAnimator.quantised(0.3, steps: 0), 0.3, "no steps: the phase is unchanged")
    }

    // MARK: final approach

    func testApproachLandsAtFiveHundredAndTwentyMillisecondsWithNoGlowLeft() {
        let start = ApproachModel.frame(elapsed: 0)
        near(start.travel, 0, "it leaves the pulse")
        near(start.opacity, 0.4)
        near(start.scale, 0.9, "it leaves the pulse small")
        near(start.reveal, 0)
        near(start.belowShift, 0)
        XCTAssertFalse(start.finished)

        let mid = ApproachModel.frame(elapsed: 0.18)
        near(mid.travel, 0.75195)
        near(mid.contrail, 1, "the contrail trails it out of the pulse")
        near(mid.glow, 0.648)

        let landed = ApproachModel.frame(elapsed: 0.52)
        XCTAssertEqual(landed, ApproachModel.Frame(travel: 1, opacity: 1, scale: 1, reveal: 1, contrail: 0, glow: 0, belowShift: 1,
                                                   content: 1, edge: 0, finished: true))
        XCTAssertEqual(ApproachModel.frame(elapsed: 9), landed, "a settled card holds its end frame")
    }

    func testApproachContrailAndGlowFadeOutAfterLanding() {
        let f = ApproachModel.frame(elapsed: 0.45)
        near(f.contrail, 0.40674, "the contrail fades from the landing to the settle")
        near(f.glow, 0.5)
        for i in 0..<52 {
            let x = ApproachModel.frame(elapsed: Double(i) * 0.01)
            XCTAssertGreaterThanOrEqual(x.opacity, 0.4 - 1e-9)
            XCTAssertLessThanOrEqual(x.opacity, 1 + 1e-9)
            XCTAssertLessThanOrEqual(x.travel, 1.02, "the spring's overshoot is a hair, and it is eased out")
        }
    }

    func testTheCardFliesAsAnEmptyOutlineAndShowsItsWordsOnlyAsItLands() {
        let start = ApproachModel.frame(elapsed: 0)
        near(start.content, 0, "no words on the pulse")
        near(start.edge, 0.6, "only the outline")
        let early = ApproachModel.frame(elapsed: 0.09)
        near(early.content, 0, "at 90 ms it is still over the header and the runway: still empty")
        XCTAssertLessThan(early.reveal, 1, "and still widening out from under the pulse")
        let contrail = ApproachModel.frame(elapsed: 0.18)
        near(contrail.content, 0, "180 ms, the board's contrail frame: an empty card")
        for i in 0...52 {
            let f = ApproachModel.frame(elapsed: Double(i) * 0.01)
            if f.content > 0 { near(f.reveal, 1, "the outline is full width before any words show (\(i) ms x10)") }
        }
        let lands = ApproachModel.frame(elapsed: 0.36)
        near(lands.content, 1, "in its slot with its words by 360 ms")
        near(lands.edge, 0)
        // The phone uses the same curve (ApproachModel.content in iOS/Page/Models).
        near(ApproachModel.content(travel: 0.8), 0)
        near(ApproachModel.content(travel: 0.885), 0.5)
        near(ApproachModel.content(travel: 0.97), 1)
    }

    func testTheCardStartsOnThePulseAndTheRowsBelowMoveByOneCardHeight() {
        near(ApproachModel.cardOffset(pulseY: 40, slotTop: 200, elapsed: 0), -160, "from the pulse to the slot")
        near(ApproachModel.cardOffset(pulseY: 40, slotTop: 200, elapsed: 0.52), 0, "and in the slot once landed")
        near(ApproachModel.belowOffset(cardHeight: 61, elapsed: 0), -61, "the rows below start one card height up")
        near(ApproachModel.belowOffset(cardHeight: 61, elapsed: 0.34), 0, "and have eased down by the time they land")
        near(ApproachModel.belowOffset(cardHeight: 61, elapsed: 9), 0)
    }

    // MARK: the stable order (the phone's StableOrder, on the Mac)

    func testAFrozenListKeepsItsOrderAndHoldsNewArrivalsBehindThePill() {
        // Before: the page approval has not arrived. After: it has, and the ranking puts it first.
        let before = NowModel.build(NWMotionFixtures.needsYouBefore()).rows.map(\.id)
        let ranked = NowModel.build(NightWatchFixtures.needsYou()).rows
        let after = ranked.map(\.id)
        let newIds = after.filter { !before.contains($0) }
        XCTAssertFalse(newIds.isEmpty, "there is a genuinely new row")

        let frozen = NowStableOrder.merge(shown: before, ranked: ranked.reversed(), frozen: true)
        XCTAssertEqual(frozen.rows.map(\.id), before.filter { after.contains($0) },
                       "nothing re-sorts under the pointer: the shown order holds, reversed ranking or not")
        XCTAssertEqual(frozen.queuedNew, newIds.count, "the new rows wait behind the pill")

        let released = NowStableOrder.merge(shown: before, ranked: ranked, frozen: false)
        XCTAssertEqual(released.rows.map(\.id), after, "unfrozen, the fresh ranking shows")
        XCTAssertEqual(released.queuedNew, 0)
    }

    func testAFrozenListWithNothingShownTakesTheRanking() {
        let rows = NowModel.build(NightWatchFixtures.needsYou()).rows
        let result = NowStableOrder.merge(shown: [], ranked: rows, frozen: true)
        XCTAssertEqual(result.rows.map(\.id), rows.map(\.id))
        XCTAssertEqual(result.queuedNew, 0)
    }

    // MARK: receipt thread

    func testReceiptThreadArmsThenSendsAndNothingMovesWithoutAnArm() {
        XCTAssertEqual(ReceiptThreadModel.frame(now: 5, sentAt: nil), ReceiptThreadModel.Frame(stage: nil, label: "", finished: true),
                       "nothing armed or sent: nothing to draw")
        let armed = ReceiptThreadModel.frame(now: 0.6, armedAt: 0, sentAt: nil)
        XCTAssertEqual(armed.stage, .arm)
        near(armed.armRing, 0.5)
        near(armed.thread, 0.06)
        XCTAssertTrue(armed.cancellable, "a tap cancels during the arm")
        let sent = ReceiptThreadModel.frame(now: 0.25, sentAt: 0)
        XCTAssertEqual(sent.stage, .sent)
        near(sent.thread, 0.3675)
        XCTAssertFalse(sent.cancellable, "once sent it cannot be cancelled")
        near(ReceiptThreadModel.frame(now: 100, sentAt: 0).thread, 0.42, "parked short of the Mac")
    }

    func testAPendingSendThatNeverHearsBackStaysParked() {
        let f = ReceiptThreadModel.frame(now: 60, sentAt: 0)
        XCTAssertEqual(f.stage, .sent)
        XCTAssertEqual(f.label, "sent")
        XCTAssertFalse(f.finished, "still waiting on the Mac")
        near(f.thread, ReceiptThreadModel.parkedAt)
    }

    /// The contract the board was drawn to: a success is drawn from a confirmed
    /// delivery, never from the send, a queued reply, a failure or a clock.
    /// The parked point is compared with 1e-6: the frame's slack of 1e-9 s on
    /// the clock eases the thread a hair past it.
    func testSuccessIsNeverDrawnWithoutAConfirmedDelivery() {
        let sentAt: Double = 10
        let offsets = stride(from: 0.0, through: 6.0, by: 0.05).map { $0 }
        let parked = ReceiptThreadModel.parkedAt + 1e-6

        for o in offsets {
            let now = sentAt + o
            // In flight, nothing confirmed: with no resolution, and with a verified
            // resolution whose time was never set.
            for frame in [ReceiptThreadModel.frame(now: now, sentAt: sentAt, resolvedAt: nil, resolution: .verified),
                          ReceiptThreadModel.frame(now: now, sentAt: sentAt, resolvedAt: nil, resolution: nil)] {
                XCTAssertEqual(frame.stage, .sent, "in flight at +\(o)")
                XCTAssertEqual(frame.label, "sent")
                XCTAssertEqual(frame.verifiedTint, 0)
                XCTAssertLessThanOrEqual(frame.thread, parked)
            }
            // Queued: accepted, never landed, parked with the word "queued".
            let q = ReceiptThreadModel.frame(now: now, sentAt: sentAt, resolvedAt: sentAt + 0.5, resolution: .queued)
            XCTAssertEqual(q.label, "queued", "queued at +\(o)")
            XCTAssertNotEqual(q.stage, .verified)
            XCTAssertNotEqual(q.stage, .typed)
            XCTAssertEqual(q.verifiedTint, 0)
            XCTAssertLessThanOrEqual(q.thread, parked)
            // Failed: snaps back to nothing, never a success.
            let x = ReceiptThreadModel.frame(now: now, sentAt: sentAt, resolvedAt: sentAt + 0.5, resolution: .failed("nope"))
            XCTAssertNil(x.stage)
            XCTAssertEqual(x.verifiedTint, 0)
            XCTAssertLessThanOrEqual(x.thread, parked)
        }

        // A verified resolution is not a success before its own time: the stage
        // follows the Mac's confirmation, not the send.
        let resolvedAt = sentAt + 3
        for o in offsets where o < 2.99 {
            let f = ReceiptThreadModel.frame(now: sentAt + o, sentAt: sentAt, resolvedAt: resolvedAt, resolution: .verified)
            XCTAssertEqual(f.stage, .sent, "not yet confirmed at +\(o)")
            XCTAssertEqual(f.verifiedTint, 0)
            XCTAssertLessThanOrEqual(f.thread, parked)
        }
        // And after the confirmation, typed then verified come in order.
        let typed = ReceiptThreadModel.frame(now: resolvedAt + 0.25, sentAt: sentAt, resolvedAt: resolvedAt, resolution: .verified)
        XCTAssertEqual(typed.stage, .typed)
        let verified = ReceiptThreadModel.frame(now: resolvedAt + 0.31, sentAt: sentAt, resolvedAt: resolvedAt, resolution: .verified)
        XCTAssertEqual(verified.stage, .verified)
        XCTAssertEqual(verified.label, "verified ✓")
    }

    func testVerifiedRunsTypedThenVerifiedThenFoldsAndDrifts() {
        let sentAt: Double = 0, resolvedAt: Double = 2
        func at(_ e: Double) -> ReceiptThreadModel.Frame {
            ReceiptThreadModel.frame(now: resolvedAt + e, sentAt: sentAt, resolvedAt: resolvedAt, resolution: .verified)
        }
        XCTAssertEqual(at(0).stage, .sent)
        near(at(0).thread, 0.42, "the thread waits at its parked point until the Mac answers")
        XCTAssertEqual(at(0.13).stage, .typed)
        near(at(0.13).thread, 0.5, "typed: the thread has reached the middle node")
        XCTAssertEqual(at(0.25).stage, .typed)
        XCTAssertEqual(at(0.4).stage, .verified)
        near(at(0.4).thread, 1)
        near(at(0.4).verifiedTint, 1)
        near(at(0.55).dotTeal, 1, "the dot has turned teal")
        near(at(0.65).rings, 0, "its rings have contracted into it")
        near(at(1.0).fold, 1, "the card has folded to a hairline")
        near(at(1.3).drift, 1, "and drifted into Settled")
        XCTAssertFalse(at(1.25).finished)
        XCTAssertTrue(at(1.31).finished)
    }

    func testFailureSnapsBackAndShakesOnceThenIsFinished() {
        // Failed two seconds after the send, so the thread had parked at 0.42 first.
        func failed(_ e: Double) -> ReceiptThreadModel.Frame {
            ReceiptThreadModel.frame(now: 2 + e, sentAt: 0, resolvedAt: 2, resolution: .failed("X"))
        }
        near(failed(0).thread, 0.42, "nothing has moved yet")
        XCTAssertEqual(failed(0).failure, "X")
        XCTAssertNil(failed(0).stage)
        near(failed(0.22).thread, 0, "the thread has snapped back")
        near(failed(0.325).shake, 3.75, "the shake swings out")
        XCTAssertFalse(failed(0.5).finished)
        XCTAssertTrue(failed(0.7).finished)
    }

    func testQueuedNeverBecomesVerifiedAndFinishesWithItsWords() {
        let q = ReceiptThreadModel.frame(now: 1, sentAt: 0, resolvedAt: 0, resolution: .queued)
        XCTAssertEqual(q.label, "queued")
        XCTAssertEqual(q.stage, .sent)
        XCTAssertEqual(q.verifiedTint, 0)
        near(q.thread, 0.42)
        XCTAssertTrue(q.finished)
    }

    func testReduceMotionShowsTheEndStateAtOnce() {
        let v = ReceiptThreadModel.frame(now: 0, sentAt: 0, resolvedAt: 0, resolution: .verified, reduceMotion: true)
        near(v.thread, 1)
        near(v.dotTeal, 1)
        XCTAssertEqual(v.stage, .verified)
        XCTAssertFalse(v.finished)
        XCTAssertTrue(ReceiptThreadModel.frame(now: 0.9, sentAt: 0, resolvedAt: 0, resolution: .verified, reduceMotion: true).finished)
        let failed = ReceiptThreadModel.frame(now: 0, sentAt: 0, resolvedAt: 0, resolution: .failed("no"), reduceMotion: true)
        XCTAssertEqual(failed.shake, 0, "no shake under Reduce Motion")
        XCTAssertEqual(failed.failure, "no")
    }

    func testResolutionMapsTheMacsOutcome() {
        XCTAssertEqual(NowMotion.resolution(for: .delivered), .verified)
        XCTAssertEqual(NowMotion.resolution(for: .queued), .queued)
        XCTAssertEqual(NowMotion.resolution(for: .timedOut), .failed("Didn't confirm in time · Check on Mac"))
    }

    func testAGhostOnlyLivesThroughItsMotion() {
        func thread(sentAt: Date?, resolvedAt: Date?, resolution: ReceiptThreadModel.Resolution?) -> NowMotion.Thread {
            var t = NowMotion.Thread(row: nil, index: 0)
            t.sentAt = sentAt
            t.resolvedAt = resolvedAt
            t.resolution = resolution
            return t
        }
        let sent = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertFalse(NowMotion.keepsGhost(thread(sentAt: nil, resolvedAt: nil, resolution: nil), now: sent), "never sent: no ghost")
        XCTAssertTrue(NowMotion.keepsGhost(thread(sentAt: sent, resolvedAt: nil, resolution: nil), now: sent.addingTimeInterval(500)),
                      "still waiting on the Mac: the row stays")
        let verified = thread(sentAt: sent, resolvedAt: sent, resolution: .verified)
        XCTAssertTrue(NowMotion.keepsGhost(verified, now: sent.addingTimeInterval(1.29)))
        XCTAssertFalse(NowMotion.keepsGhost(verified, now: sent.addingTimeInterval(1.31)), "gone once folded")
        let failed = thread(sentAt: sent, resolvedAt: sent, resolution: .failed("x"))
        XCTAssertTrue(NowMotion.keepsGhost(failed, now: sent.addingTimeInterval(3.9)))
        XCTAssertFalse(NowMotion.keepsGhost(failed, now: sent.addingTimeInterval(4.1)), "words stay for four seconds")
    }

    // MARK: the hold ring

    func testHoldRingWarmsOnlyInItsFinalThird() {
        near(HoldRingModel.warmth(progress: 0.5), 0, "amber")
        near(HoldRingModel.warmth(progress: 2.0 / 3), 0)
        near(HoldRingModel.warmth(progress: 5.0 / 6), 0.5)
        near(HoldRingModel.warmth(progress: 1), 1, "red when full")
    }

    func testHoldRingTicksAtQuartersAndCountsOnlyRisingCrossings() {
        XCTAssertEqual(HoldRingModel.ticks, [0.25, 0.5, 0.75, 1.0])
        XCTAssertEqual(HoldRingModel.ticksCrossed(from: 0.2, to: 0.6), [0.25, 0.5])
        XCTAssertEqual(HoldRingModel.ticksCrossed(from: 0.9, to: 1), [1.0])
        XCTAssertEqual(HoldRingModel.ticksCrossed(from: 0.5, to: 0.4), [], "unwinding crosses nothing")
        XCTAssertEqual(HoldRingModel.ticksCrossed(from: 0.5, to: 0.5), [], "standing still crosses nothing")
        XCTAssertEqual(HoldRingModel.ticksCrossed(from: 0.25, to: 0.5), [0.5], "a tick the ring stood on is not passed again")
    }

    func testReleasingEarlyUnwindsAtTheFillSpeed() {
        near(HoldRingModel.unwound(from: 0.6, since: 0.36), 0.3)
        XCTAssertEqual(HoldRingModel.unwound(from: 0.6, since: 10), 0, "it never unwinds past empty")
        near(HoldRingModel.unwindDuration(from: 0.6), 0.72)
    }

    func testBurstFlaresOutAndFades() {
        let start = HoldRingModel.burst(elapsed: 0)
        near(start.scale, 1)
        near(start.alpha, 1)
        XCTAssertFalse(start.finished)
        let mid = HoldRingModel.burst(elapsed: 0.25)
        near(mid.scale, 1.2625)
        let end = HoldRingModel.burst(elapsed: 0.5)
        near(end.scale, 1.3)
        near(end.alpha, 0)
        XCTAssertTrue(end.finished)
    }

    func testApproveHoldKeepsTheBoardTimingAndStopAllHoldsForTenSeconds() {
        let start = Date(timeIntervalSinceReferenceDate: 500)
        let approve = HoldGesture(kind: .approve(rowId: "r"), startedAt: start)
        XCTAssertEqual(approve.deadZone, 0.3, accuracy: 1e-9, "a 0.3 s dead zone")
        XCTAssertEqual(approve.duration, 1.5, accuracy: 1e-9, "a 1.2 s fill after it")
        XCTAssertEqual(approve.progress(now: start.addingTimeInterval(0.2)), 0, "nothing before the dead zone")
        near(approve.progress(now: start.addingTimeInterval(0.9)), 0.5)
        XCTAssertTrue(approve.isComplete(now: start.addingTimeInterval(1.5)))
        let stop = HoldGesture(kind: .stopAll, startedAt: start)
        XCTAssertEqual(stop.deadZone, 0.3, accuracy: 1e-9, "the same dead zone")
        XCTAssertEqual(stop.duration, 10, accuracy: 1e-9, "Esc in every session takes a 10 s hold")
        XCTAssertFalse(stop.isComplete(now: start.addingTimeInterval(1.5)))
        XCTAssertTrue(stop.isComplete(now: start.addingTimeInterval(10)))
    }

    // MARK: dusk and dawn

    func testDuskFadesTheAuroraAndDimsTheStarsTogetherThenHoldsAHorizon() {
        let start = DuskDawnModel.dusk(elapsed: 0)
        near(start.duskMix, 0)
        near(start.stars, 1)
        near(start.horizon, 0)
        XCTAssertFalse(start.finished)
        near(DuskDawnModel.dusk(elapsed: 0.35).stars, 1.25, "each star swells once")
        near(DuskDawnModel.dusk(elapsed: 1.4).stars, 0.1, "then all dim together, to a faint speck")
        near(DuskDawnModel.dusk(elapsed: 1.6).horizon, 1, "the grey horizon holds")
        near(DuskDawnModel.dusk(elapsed: 2.5).duskMix, 1)
        XCTAssertTrue(DuskDawnModel.dusk(elapsed: 2.5).finished)
        XCTAssertFalse(DuskDawnModel.dusk(elapsed: 2.39).finished)
    }

    func testSweepReachesEachHeightInOrder() {
        near(DuskDawnModel.sweepReach(height: 1), 0, "on the horizon: at once")
        near(DuskDawnModel.sweepReach(height: 0), 1.6, "at the top: when the sweep ends")
        near(DuskDawnModel.sweepReach(height: 0.5), 0.33008)
        near(DuskDawnModel.sweepFront(elapsed: 0), 0)
        near(DuskDawnModel.sweepFront(elapsed: 1.6), 1)
    }

    func testStarsRelightOneByOneOnlyWhenTheirResumeIsConfirmed() {
        let times = DuskDawnModel.relightTimes([
            .init(id: "a", height: 1, confirmedAt: 0.3),
            .init(id: "b", height: 1, confirmedAt: 0.3),
            .init(id: "c", height: 0, confirmedAt: 0.1),
            .init(id: "d", height: 0.5, confirmedAt: nil),
        ])
        XCTAssertNil(times["d"], "an unconfirmed star stays dim")
        near(times["a"] ?? -1, 0.3)
        near(times["b"] ?? -1, 0.46, "one stagger after a")
        near(times["c"] ?? -1, 1.6, "the top star waits for the sweep to reach it")
        let sorted = ["a", "b", "c"].compactMap { times[$0] }.sorted()
        for (x, y) in zip(sorted, sorted.dropFirst()) {
            XCTAssertGreaterThanOrEqual(y - x, DuskDawnModel.relightStagger - 1e-9, "never two at once")
        }
    }

    func testStarBrightnessDimsUntilRelitThenFlaresUp() {
        near(DuskDawnModel.starLight(elapsed: 1, relitAt: nil), 0.1, "never relit: dim")
        near(DuskDawnModel.starLight(elapsed: 0.5, relitAt: 0), 1)
        near(DuskDawnModel.starLight(elapsed: 0.25, relitAt: 0), 1.2375, "the small flare passes 1")
        near(DuskDawnModel.starLight(elapsed: 0, relitAt: 0), 0.1, "before its moment it is still dim")
    }

    func testDawnRisesWarmthHoldsThenAuroraReturns() {
        let start = DuskDawnModel.dawn(elapsed: 0)
        near(start.front, 0)
        near(start.glow, 0)
        near(start.horizon, 1)
        near(DuskDawnModel.dawn(elapsed: 1.2).glow, 1)
        near(DuskDawnModel.dawn(elapsed: 1.6).horizon, 0, "the horizon band has gone")
        let end = DuskDawnModel.dawn(elapsed: 3.2)
        near(end.glow, 0, "the warmth settles back")
        near(end.auroraReturn, 1, "the working aurora is back")
        XCTAssertTrue(DuskDawnModel.dawn(elapsed: 3.3).finished)
        XCTAssertFalse(DuskDawnModel.dawn(elapsed: 3.19).finished)
    }

    func testThePausedSkySettlesToNearBlackWithOnlyTheHorizon() {
        let t0 = NWMotionFixtures.t0
        let model = NowModel.build(NWMotionFixtures.pausedSix())
        var m = NowMotion()
        m.duskAt = t0.addingTimeInterval(-10)
        let look = NowSky.look(model: model, motion: m, now: t0, reduceMotion: false)
        XCTAssertEqual(look.palette, NightWatch.AuroraPalette.night, "the dusk goes all the way to night")
        XCTAssertEqual(look.palette.intensity, 0, "no curtains")
        let top = look.palette.skyTop
        XCTAssertLessThan(max(top.r, top.g, top.b), 0.08, "near-black, not a purple dusk")
        XCTAssertLessThan(look.sky.starField, 0.15, "the star field has all but gone")
        near(look.sky.horizon, 1, "the horizon holds")
        XCTAssertFalse(look.sky.stars.isEmpty, "the paused stars are still there to be relit")
        XCTAssertTrue(look.sky.stars.allSatisfy { $0.light <= DuskDawnModel.starsDimmedTo + 1e-9 })
        let midway = NowSky.look(model: model, motion: m, now: t0.addingTimeInterval(-10 + 1.2), reduceMotion: false)
        XCTAssertGreaterThan(midway.palette.skyTop.b, top.b, "half way it is still the purple dusk (board: cutoff · dusk falls)")
    }

    func testTheDawnHeaderCountsOnlyAgentsWhoseStarsHaveRelit() {
        let t0 = NWMotionFixtures.t0
        let paused = NowModel.build(NWMotionFixtures.pausedSix())
        let model = NowModel.build(NWMotionFixtures.workingSix())
        var dawn = NowMotion.Dawn(stars: paused.paused, startedAt: t0)
        for (n, s) in paused.paused.enumerated() where n < 5 {
            dawn.confirmed[s.id] = t0.addingTimeInterval(n < 3 ? 0.3 : 1.0)
        }
        var m = NowMotion()
        m.dawn = dawn
        let early = NowSky.lines(model: model, motion: m, now: t0.addingTimeInterval(0.05), reduceMotion: false)
        XCTAssertEqual(early.headline, "All quiet")
        XCTAssertEqual(early.subline, "resuming after the pause", "nothing has relit: no claim that anything is working")
        let lastLit = NowSky.relightTimes(dawn).values.max() ?? 0
        let late = NowSky.lines(model: model, motion: m, now: t0.addingTimeInterval(lastLit + 0.01), reduceMotion: false)
        XCTAssertEqual(late.subline, "5 working · resuming the rest", "the one never confirmed is not counted")
        XCTAssertEqual(NowSky.lines(model: model, motion: m, now: t0, reduceMotion: true).subline, "5 working · resuming the rest",
                       "Reduce Motion counts every confirmed resume at once")
        let none = NowSky.lines(model: model, motion: NowMotion(), now: t0, reduceMotion: false)
        XCTAssertEqual(none.subline, model.subline, "no dawn: the model's own words")
        XCTAssertEqual(none.headline, model.headline)
    }

    // MARK: the exhale's colours

    func testPerceptualMixKeepsItsEndsAndItsColourHalfWay() {
        let amber = NightWatch.Palette.amber, teal = NightWatch.Palette.teal
        let a: PerceptualMix.RGB = (amber.r, amber.g, amber.b), b: PerceptualMix.RGB = (teal.r, teal.g, teal.b)
        let start = PerceptualMix.mix(a, b, 0), end = PerceptualMix.mix(a, b, 1)
        XCTAssertTrue(start == a && end == b, "exactly amber at 0 and teal at 1")
        func chroma(_ c: PerceptualMix.RGB) -> Double {
            let lab = PerceptualMix.oklab(c)
            return (lab.a * lab.a + lab.b * lab.b).squareRoot()
        }
        let mid = PerceptualMix.mix(a, b, 0.5)
        let plain = amber.mixed(with: teal, 0.5)
        XCTAssertGreaterThan(chroma(mid), 1.3 * chroma((plain.r, plain.g, plain.b)), "an sRGB blend goes khaki half way; this one does not")
        XCTAssertGreaterThan(chroma(mid), 0.9 * min(chroma(a), chroma(b)), "it keeps the chroma of its ends")
        XCTAssertGreaterThan(mid.g, mid.r, "amber to teal passes through green, not grey")
        let lab = PerceptualMix.oklab(a)
        let back = PerceptualMix.srgb(l: lab.l, a: lab.a, b: lab.b)
        near(back.r, a.r); near(back.g, a.g); near(back.b, a.b)
        for i in 0...20 {
            let c = PerceptualMix.mix(a, b, Double(i) / 20)
            XCTAssertTrue([c.r, c.g, c.b].allSatisfy { $0 >= 0 && $0 <= 1 }, "always a drawable colour")
        }
        XCTAssertTrue(amber.mixedPerceptual(with: teal, 1) == teal && amber.mixedPerceptual(with: teal, -1) == amber)
    }

    func testSunriseIsBrighterTheMoreFinishedTheAbsence() {
        near(DuskDawnModel.sunriseScale(finished: 0, needYou: 0, handledOnPhone: 0), 0.25, "a quiet absence still gets a low dawn")
        near(DuskDawnModel.sunriseScale(finished: 4, needYou: 0, handledOnPhone: 0), 1)
        near(DuskDawnModel.sunriseScale(finished: 0, needYou: 0, handledOnPhone: 6), 0.5, "handled from the phone counts half")
        near(DuskDawnModel.sunriseScale(finished: 1, needYou: 2, handledOnPhone: 0), 0.3333)
        near(DuskDawnModel.sunriseScale(finished: 0, needYou: 3, handledOnPhone: 0), 0.25, "what still needs you counts against")
        near(DuskDawnModel.sunriseScale(finished: -5, needYou: 0, handledOnPhone: 0), 0.25, "negative counts are nothing")
        let full = DuskDawnModel.sunrise(elapsed: 2.25, scale: 1)
        near(full.front, 1)
        near(full.glow, 0.45, "it settles to a resting glow")
        XCTAssertTrue(full.finished)
        near(DuskDawnModel.sunrise(elapsed: 1.4, scale: 0).front, 0.3, "a quiet absence rises only so far")
    }
}
