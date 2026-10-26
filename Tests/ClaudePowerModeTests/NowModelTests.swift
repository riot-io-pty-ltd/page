import XCTest
@testable import ClaudePowerMode

/// The Now popover's model: headlines, sublines, runway markers, rings,
/// receipts, the welcome-back summary and the clock and duration text.
final class NowModelTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var utcCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = utc
        return c
    }
    private var now: Date { NightWatchFixtures.boardNow() }

    private func utcDate(_ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 26
        comps.hour = h; comps.minute = m; comps.second = s
        return utcCalendar.date(from: comps)!
    }

    private func inputs(relay: Coordinator.RelayState = .connected, idle: TimeInterval = 5,
                        sessions: [AgentSession] = [], pending: [InterventionEvent] = []) -> NowInputs {
        NowInputs(snapshot: NightWatchFixtures.snapshot(sessions: sessions, pending: pending, relay: relay),
                  now: now, macName: "Studio MBP", idleSeconds: idle)
    }

    // MARK: needs you (board 05)

    func testNeedsYouHeadlineAndSubline() {
        let m = NowModel.build(NightWatchFixtures.needsYou())
        XCTAssertEqual(m.headline, "2 need you · 5 working")
        XCTAssertEqual(m.subline, "runway clear till 02:40 · lid can close")
        XCTAssertEqual(m.mood, .needsYou)
        XCTAssertEqual(m.needYouCount, 2)
        XCTAssertEqual(m.lookCount, 1)
        XCTAssertEqual(m.workingCount, 5)
        XCTAssertEqual(m.attentionCount, 3)
        XCTAssertEqual(m.accessibilityLabel, "Page — 2 need you · 5 working")
        XCTAssertEqual(m.macName, "Studio MBP")
    }

    func testNeedsYouGlyphCountsTheBlockedRows() {
        let m = NowModel.build(NightWatchFixtures.needsYou())
        XCTAssertEqual(m.glyph.mode, .needsYou(count: 2))
        XCTAssertTrue(m.glyph.lidClosedAwake, "preventSystemSleep is held, so the lid can close")
        XCTAssertNil(m.glyph.headroom, "on AC there is no headroom arc")
        XCTAssertFalse(m.glyph.phoneArmed, "at the desk (idle 5 s), so the phone is not paged")
    }

    func testNeedsYouRunwayLabels() {
        let m = NowModel.build(NightWatchFixtures.needsYou())
        XCTAssertEqual(m.runway.markers.map(\.label), ["5h 02:40", "reset 03:00", "resume 04:10"])
        XCTAssertTrue(m.runway.onAC)
        XCTAssertNil(m.runway.markers.first { $0.kind == .batteryCutoff }, "no cutoff marker on AC")
        XCTAssertEqual(m.runway.clearUntil, NightWatchFixtures.at(now, hour: 2, minute: 40))
    }

    func testNeedsYouReceiptLine() {
        let m = NowModel.build(NightWatchFixtures.needsYou())
        XCTAssertEqual(m.receiptLine, "Approved npm test → cmux › page · verified 23:47:12")
        XCTAssertFalse(m.receiptFailed)
    }

    func testFailedReceiptIsFlaggedAndWorded() {
        let m = NowModel.build(NightWatchFixtures.needsYouWithFailedReceipt())
        XCTAssertEqual(m.receiptLine, "swift test · Didn't confirm in time · Check on Mac")
        XCTAssertTrue(m.receiptFailed)
    }

    func testReceiptOlderThanFifteenMinutesIsHidden() {
        var i = NightWatchFixtures.needsYou()
        i.receipts = [DeliveryReceipt(verb: .approved, subject: "npm test", route: "cmux › page", at: now.addingTimeInterval(-16 * 60))]
        XCTAssertNil(NowModel.build(i).receiptLine)
    }

    func testReceiptFromTheFutureBeyondAMinuteIsHidden() {
        var i = NightWatchFixtures.needsYou()
        i.receipts = [DeliveryReceipt(verb: .approved, subject: "npm test", route: "cmux › page", at: now.addingTimeInterval(120))]
        XCTAssertNil(NowModel.build(i).receiptLine)
    }

    func testNewestReceiptWins() {
        var i = NightWatchFixtures.needsYou()
        i.receipts = [
            DeliveryReceipt(verb: .denied, subject: "old", route: "cmux › page", at: now.addingTimeInterval(-300)),
            DeliveryReceipt(verb: .approved, subject: "npm test", route: "cmux › page", at: now.addingTimeInterval(-48)),
        ]
        XCTAssertEqual(NowModel.build(i).receiptLine, "Approved npm test → cmux › page · verified 23:47:12")
    }

    func testLookOnlyHeadlineAndMood() {
        var i = inputs(pending: [NightWatchFixtures.event("llm-play", kind: .idle,
                                                          context: "Looks stuck in a loop: this has failed 6 times.\ncargo test",
                                                          openedAt: now.addingTimeInterval(-600), subtype: "looping")])
        i.route = NightWatchFixtures.route
        let m = NowModel.build(i)
        XCTAssertEqual(m.headline, "1 needs a look")
        XCTAssertEqual(m.mood, .needsYou)
        XCTAssertEqual(m.needYouCount, 0)
        XCTAssertEqual(m.lookCount, 1)
    }

    func testLookWithWorkingAgentsSaysSo() {
        var i = inputs(sessions: NightWatchFixtures.working5, pending: [NightWatchFixtures.event("llm-play", kind: .idle,
                                                          context: "Looks stuck in a loop: this has failed 6 times.\ncargo test",
                                                          openedAt: now.addingTimeInterval(-600), subtype: "looping")])
        i.route = NightWatchFixtures.route
        XCTAssertEqual(NowModel.build(i).headline, "1 needs a look · 5 working")
    }

    func testSingularNeedYou() {
        var i = inputs(sessions: NightWatchFixtures.working5, pending: [NightWatchFixtures.event("page", kind: .permission,
                                                          context: "[Bash] swift test\nRun the tests", openedAt: now.addingTimeInterval(-30))])
        i.route = NightWatchFixtures.route
        XCTAssertEqual(NowModel.build(i).headline, "1 needs you · 5 working")
    }

    // MARK: all quiet (board 42, middle)

    func testAllQuietHeadlineSublineAndPhone() {
        let m = NowModel.build(NightWatchFixtures.allQuiet())
        XCTAssertEqual(m.headline, "All quiet")
        XCTAssertEqual(m.subline, "5 working · nothing needs you")
        XCTAssertEqual(m.phoneLine, "Phone paging armed · you're away")
        XCTAssertEqual(m.mood, .working)
        XCTAssertEqual(m.rings.map(\.kind), [.unblocked, .shipped, .calm])
    }

    func testAllQuietWithNoAgentsReadsNoAgentsRunning() {
        var i = NightWatchFixtures.allQuiet()
        i.snapshot = NightWatchFixtures.snapshot(awake: .none)
        let m = NowModel.build(i)
        XCTAssertEqual(m.headline, "All quiet")
        XCTAssertEqual(m.subline, "no agents running · nothing needs you")
        XCTAssertEqual(m.mood, .quiet)
        XCTAssertEqual(m.glyph.mode, .off, "nothing is kept awake, so the glyph is hollow")
    }

    func testPhoneLineFollowsRelayAndPresence() {
        XCTAssertNil(NowModel.build(inputs(relay: .off)).phoneLine)
        XCTAssertEqual(NowModel.build(inputs(relay: .connected, idle: 5)).phoneLine, "Phone quiet · you're at the Mac")
        XCTAssertEqual(NowModel.build(inputs(relay: .connected, idle: 600)).phoneLine, "Phone paging armed · you're away")
        XCTAssertEqual(NowModel.build(inputs(relay: .connecting)).phoneLine, "Phone relay connecting…")
        XCTAssertEqual(NowModel.build(inputs(relay: .misconfigured("no url"))).phoneLine, "Phone relay not set up")
    }

    func testStartingModel() {
        let m = NowModel.starting(macName: "Studio MBP")
        XCTAssertEqual(m.headline, "Starting…")
        XCTAssertEqual(m.mood, .quiet)
        XCTAssertTrue(m.rows.isEmpty)
        XCTAssertEqual(m.glyph.mode, .off)
    }

    // MARK: paused for battery (board 42, right)

    func testPausedForBatteryHeadlineAndPausedAgents() {
        let m = NowModel.build(NightWatchFixtures.pausedForBattery())
        XCTAssertEqual(m.headline, "Paused at 10%")
        XCTAssertEqual(m.subline, "2 agents paused · plug in to resume")
        XCTAssertEqual(m.glyph.mode, .paused)
        XCTAssertTrue(m.canResumeNow)
        XCTAssertEqual(m.mood, .dusk)
        XCTAssertEqual(m.paused.map(\.id), ["sess-mac-on-claude-code", "sess-page-relay"], "most recently paused first")
        XCTAssertTrue(m.paused[0].summaryWritten)
        XCTAssertFalse(m.paused[1].summaryWritten)
        XCTAssertTrue(m.paused[0].detail.hasPrefix("Claude · paused "))
    }

    func testGracePhaseSaysPausing() {
        let grace = Coordinator.BatteryStatus(phase: .grace, paused: [], graceEndsAt: now.addingTimeInterval(120), mode: .pause)
        var i = inputs()
        i.snapshot = NightWatchFixtures.snapshot(power: PowerSnapshot(percent: 10, onAC: false, hasBattery: true, isCharging: false),
                                                 battery: grace)
        let m = NowModel.build(i)
        XCTAssertEqual(m.headline, "Pausing at 10%")
        XCTAssertTrue(m.subline.hasPrefix("agents are asked to summarise · awake till "), m.subline)
        XCTAssertEqual(m.mood, .dusk)
    }

    func testDrainedWithNothingPausedIsLowBattery() {
        let drained = Coordinator.BatteryStatus(phase: .drained, paused: [], graceEndsAt: nil, mode: .pause)
        var i = inputs()
        i.snapshot = NightWatchFixtures.snapshot(power: PowerSnapshot(percent: 9, onAC: false, hasBattery: true, isCharging: false),
                                                 battery: drained)
        let m = NowModel.build(i)
        XCTAssertEqual(m.headline, "Low battery")
        XCTAssertEqual(m.subline, "not keeping the Mac awake · plug in to continue")
    }

    func testPausedOnACSaysWhenItResumes() {
        let paused = [PausedSession(backend: .claude, sessionId: "sess-a", projectName: "a", cwd: "/x/a",
                                    pausedAt: now.addingTimeInterval(-60), detail: "Interrupted in cmux")]
        let drained = Coordinator.BatteryStatus(phase: .drained, paused: paused, graceEndsAt: nil, mode: .pause)
        var i = inputs()
        i.snapshot = NightWatchFixtures.snapshot(battery: drained)
        XCTAssertEqual(NowModel.build(i).subline, "1 agent paused · resumes at 25%")
    }

    func testPauseLinesReadSummarisedOnlyWhenEveryPausedSessionHasOne() {
        let paused = ["sess-a", "sess-b"].map {
            PausedSession(backend: .claude, sessionId: $0, projectName: $0, cwd: "/x/\($0)", pausedAt: now, detail: "")
        }
        let drained = Coordinator.BatteryStatus(phase: .drained, paused: paused, graceEndsAt: nil, mode: .pause)
        let s = NightWatchFixtures.snapshot(power: PowerSnapshot(percent: 10, onAC: false, hasBattery: true, isCharging: false),
                                            battery: drained)
        let both = NowModel.pauseLines(s, cutoff: 10, recovery: 25, now: now, timeZone: utc, summarised: ["sess-a", "sess-b"])
        XCTAssertEqual(both.0, "Paused at 10%")
        XCTAssertEqual(both.1, "2 agents summarised · plug in to resume")
        let one = NowModel.pauseLines(s, cutoff: 10, recovery: 25, now: now, timeZone: utc, summarised: ["sess-a"])
        XCTAssertEqual(one.1, "2 agents paused · plug in to resume")
        let none = NowModel.pauseLines(s, cutoff: 10, recovery: 25, now: now, timeZone: utc)
        XCTAssertEqual(none.1, "2 agents paused · plug in to resume")
    }

    // MARK: on battery (runway and cutoff)

    func testOnBatteryRunwayHasACutoffMarkerAndArc() {
        let m = NowModel.build(NightWatchFixtures.onBattery())
        XCTAssertFalse(m.runway.onAC)
        XCTAssertEqual(m.runway.markers.map(\.kind), [.batteryCutoff])
        XCTAssertEqual(m.runway.markers.first?.label, "cutoff " + NowModel.clock(now.addingTimeInterval(110 * 60), timeZone: .current))
        XCTAssertEqual(m.runway.clearUntil, now.addingTimeInterval(110 * 60))
        XCTAssertEqual(m.subline, "runway clear till " + NowModel.clock(now.addingTimeInterval(110 * 60), timeZone: .current) + " · 41%")
        XCTAssertEqual(m.glyph.headroom ?? -1, 31.0 / 90.0, accuracy: 0.0001)
    }

    func testRunwayModelEarliestDeadlineWins() {
        let s = NightWatchFixtures.snapshot(
            power: PowerSnapshot(percent: 41, onAC: false, hasBattery: true, isCharging: false),
            forecast: BatteryForecast.Estimate(percent: 41, cutoff: 10, drainPerHour: 17, minutesToCutoff: 110))
        let hit = now.addingTimeInterval(60 * 60)
        let r = NowModel.runwayModel(s, now: now, usage: nil, usageHitAt: hit, timeZone: .current)
        XCTAssertEqual(r.clearUntil, hit, "the 5-hour limit comes before the cutoff")
        XCTAssertEqual(Set(r.markers.map(\.kind)), [.batteryCutoff, .usageLimit])
    }

    func testRunwayDropsPastHitsAndFarResets() {
        let s = NightWatchFixtures.snapshot()
        let usage = UsageSnapshot(fiveHour: .init(pct: 10, resetsAt: now.addingTimeInterval(7 * 3600)),
                                  sevenDay: nil, updatedAt: now)
        let r = NowModel.runwayModel(s, now: now, usage: usage, usageHitAt: now.addingTimeInterval(-300), timeZone: .current)
        XCTAssertTrue(r.markers.isEmpty, "a past 5-hour hit and a reset beyond six hours are not on the runway")
        XCTAssertNil(r.clearUntil)
    }

    func testScheduledResumeUsesEffectiveRunAt() {
        let resume = ScheduledResume(sessionId: "sess-x", cwd: "/x", projectName: "x",
                                     resetTime: now.addingTimeInterval(2 * 3600), prompt: "carry on",
                                     plistPath: "", logPath: "", label: "resume", createdAt: now)
        let r = NowModel.runwayModel(NightWatchFixtures.snapshot(scheduledResumes: [resume]), now: now,
                                     usage: nil, usageHitAt: nil, timeZone: .current)
        XCTAssertEqual(r.markers.count, 1)
        XCTAssertEqual(r.markers.first?.at, now.addingTimeInterval(2 * 3600 + 60), "no runAt: reset plus a minute")
        XCTAssertEqual(r.markers.first?.kind, .resume)
        XCTAssertNil(r.clearUntil, "a resume is not a deadline")
    }

    // MARK: runway geometry

    func testFractionAcrossTheWindow() {
        XCTAssertEqual(RunwayModel.fraction(of: now.addingTimeInterval(3 * 3600), now: now) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(RunwayModel.fraction(of: now.addingTimeInterval(7 * 3600), now: now))
        XCTAssertNil(RunwayModel.fraction(of: now.addingTimeInterval(-60), now: now))
        XCTAssertEqual(RunwayModel.fraction(of: now, now: now), 0.0)
        XCTAssertEqual(RunwayModel.fraction(of: now.addingTimeInterval(6 * 3600), now: now), 1.0)
    }

    func testAssignLanesMovesCloseLabelsToTheSecondLane() {
        func marker(_ id: String, _ f: Double) -> RunwayMarker {
            RunwayMarker(id: id, kind: .usageReset, label: id, at: now, fraction: f, tone: .green)
        }
        let lanes = RunwayModel.assignLanes([marker("b", 0.53), marker("a", 0.48), marker("c", 0.70)])
        XCTAssertEqual(lanes.map(\.id), ["a", "b", "c"], "sorted by position")
        XCTAssertEqual(lanes.map(\.lane), [0, 1, 0])
    }

    // MARK: day rings

    func testUnblockedRingFromDecisions() {
        let r = DayStats(unblockedFast: 11, decisions: 12, shipped: 7, finished: 10, calmSeconds: 4 * 3600 + 10 * 60).rings
        XCTAssertEqual(r[0].kind, .unblocked)
        XCTAssertEqual(r[0].progress, 11.0 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(r[0].detail, "11 / 12")
        XCTAssertEqual(r[1].kind, .shipped)
        XCTAssertEqual(r[1].progress, 0.7, accuracy: 0.0001)
        XCTAssertEqual(r[1].detail, "7 / 10")
    }

    func testCalmRingCapsAtItsGoal() {
        let r = DayStats(calmSeconds: 4 * 3600 + 10 * 60).rings[2]
        XCTAssertEqual(r.kind, .calm)
        XCTAssertEqual(r.progress, 1.0)
        XCTAssertEqual(r.detail, "4 h 10 min")
        XCTAssertEqual(DayStats(calmSeconds: 3600).rings[2].progress, 0.25, accuracy: 0.0001)
    }

    func testZeroDenominatorsGiveNoneYet() {
        let r = DayStats().rings
        XCTAssertEqual(r[0].progress, 0)
        XCTAssertEqual(r[0].detail, "none yet")
        XCTAssertEqual(r[1].progress, 0)
        XCTAssertEqual(r[1].detail, "none yet")
        XCTAssertEqual(r[2].progress, 0)
    }

    // MARK: welcome back

    func testWelcomeBackWithFinishedAndNeedsYou() {
        let w = WelcomeBack.build(away: 52 * 60, finished: 2, needYou: 1, handledOnPhone: 0, rings: [])
        XCTAssertEqual(w.eyebrow, "WELCOME BACK · AWAY 52 MIN")
        XCTAssertEqual(w.headline, "2 finished, 1 needs you.")
        XCTAssertTrue(w.needsYou)
    }

    func testWelcomeBackHoursInTheEyebrow() {
        let w = WelcomeBack.build(away: 112 * 60, finished: 0, needYou: 0, handledOnPhone: 0, rings: [])
        XCTAssertEqual(w.eyebrow, "WELCOME BACK · AWAY 1 H 52 MIN")
    }

    func testWelcomeBackPhoneAndNothing() {
        XCTAssertEqual(WelcomeBack.build(away: 900, finished: 0, needYou: 0, handledOnPhone: 6, rings: []).headline,
                       "You handled 6 from your phone.")
        XCTAssertEqual(WelcomeBack.build(away: 900, finished: 0, needYou: 0, handledOnPhone: 0, rings: []).headline,
                       "Nothing needed you.")
        XCTAssertFalse(WelcomeBack.build(away: 900, finished: 0, needYou: 0, handledOnPhone: 0, rings: []).needsYou)
    }

    func testWelcomeBackNeedsYouCountWording() {
        let w = WelcomeBack.build(away: 900, finished: 0, needYou: 2, handledOnPhone: 0, rings: [])
        XCTAssertTrue(w.headline.contains("2 need you"), w.headline)
        XCTAssertTrue(w.needsYou)
        XCTAssertEqual(WelcomeBack.build(away: 900, finished: 0, needYou: 1, handledOnPhone: 0, rings: []).headline,
                       "1 needs you.")
    }

    func testWelcomeBackOnlyShowsAfterTenMinutesAway() {
        XCTAssertFalse(WelcomeBack.isWorthShowing(away: 9 * 60))
        XCTAssertTrue(WelcomeBack.isWorthShowing(away: 10 * 60))
    }

    // MARK: receipts and the in-flight strip

    func testReceiptLinesForEachFailureUseTheSpecWords() {
        let at = utcDate(23, 47, 12)
        func line(_ outcome: DeliveryReceipt.Outcome) -> String {
            DeliveryReceipt(verb: .approved, subject: "npm test", route: "cmux › page", at: at, outcome: outcome).line(timeZone: utc)
        }
        XCTAssertEqual(line(.delivered), "Approved npm test → cmux › page · verified 23:47:12")
        XCTAssertEqual(line(.sessionEnded), "npm test · Session ended")
        XCTAssertEqual(line(.queued), "npm test · Queued after this turn")
        XCTAssertEqual(line(.other("")), "npm test · Couldn't deliver the reply")
        XCTAssertEqual(line(.notTypable), "npm test · This terminal can't take input · Open on Mac")
    }

    func testInFlightListsOnlyWorkingSessionsByProjectThenId() {
        let idle = NightWatchFixtures.session("docs", state: .idle)
        let snap = NightWatchFixtures.snapshot(sessions: NightWatchFixtures.working5 + [idle])
        let flight = NowModel.inFlight(snap)
        XCTAssertEqual(flight.map(\.project), ["bottle-flip", "llm-play", "mac-on-claude-code", "page", "page-relay"])
        XCTAssertFalse(flight.contains { $0.project == "docs" })
        var i = NowInputs(snapshot: snap, now: now, macName: "Studio MBP", idleSeconds: 5)
        i.route = NightWatchFixtures.route
        XCTAssertEqual(NowModel.build(i).stoppableCount, 5, "Stop all counts working sessions only")
        XCTAssertEqual(NowModel.build(i).inFlight.count, 5)
    }

    // MARK: clock and duration

    func testClockIsTwentyFourHourInTheGivenZone() {
        XCTAssertEqual(NowModel.clock(utcDate(3, 40), timeZone: utc), "03:40")
        XCTAssertEqual(NowModel.clock(utcDate(23, 47, 12), seconds: true, timeZone: utc), "23:47:12")
        XCTAssertEqual(NowModel.clock(utcDate(0, 5), timeZone: utc), "00:05")
    }

    func testDurationFormatting() {
        XCTAssertEqual(NowModel.duration(seconds: 3120), "52 min")
        XCTAssertEqual(NowModel.duration(seconds: 6720), "1 h 52 min")
        XCTAssertEqual(NowModel.duration(seconds: 7200), "2 h")
        XCTAssertEqual(NowModel.duration(seconds: 3120, upper: true), "52 MIN")
        XCTAssertEqual(NowModel.duration(seconds: 30), "1 min", "under a minute reads one minute")
        XCTAssertEqual(NowModel.duration(seconds: 0), "1 min")
    }
}
