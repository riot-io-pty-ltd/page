import XCTest
@testable import ClaudePowerMode

// MARK: - helpers

private func battery(_ percent: Int, ac: Bool = false) -> PowerSnapshot {
    PowerSnapshot(percent: percent, onAC: ac, hasBattery: true, isCharging: ac)
}

private func settings(cutoff: Int = 10, recovery: Int = 25, requiresAC: Bool = true,
                      action: LowBatteryAction = .pause, grace: TimeInterval = 90,
                      resume: Bool = true) -> BatteryPolicy.Settings {
    BatteryPolicy.Settings(cutoff: cutoff, recovery: recovery, recoveryRequiresAC: requiresAC,
                           action: action, graceSeconds: grace, resumeAfterRecovery: resume)
}

private func session(_ id: String, backend: AgentBackendID = .claude, at: Date) -> PausedSession {
    PausedSession(backend: backend, sessionId: id, projectName: "proj-\(id)", cwd: "/tmp/\(id)",
                  pausedAt: at, detail: "Interrupted in tmux pane %1")
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

// MARK: - BatteryPolicy

final class BatteryPolicyTests: XCTestCase {
    func testNeverTripsOnACOrDesktop() {
        var p = BatteryPolicy()
        XCTAssertEqual(p.observe(battery(3, ac: true), settings: settings(), now: t0), [])
        XCTAssertEqual(p.phase, .normal)
        XCTAssertEqual(p.observe(.noBattery, settings: settings(), now: t0), [])
        XCTAssertEqual(p.phase, .normal)
        XCTAssertEqual(p.boostDirective(.noBattery), .followAgents)
        // Charging below the cutoff is "on AC" too.
        XCTAssertFalse(BatteryPolicy.shouldTrip(PowerSnapshot(percent: 5, onAC: true, hasBattery: true, isCharging: true), cutoff: 10))
        // A nonsense -1 reading with a battery never trips.
        XCTAssertFalse(BatteryPolicy.shouldTrip(PowerSnapshot(percent: -1, onAC: false, hasBattery: true, isCharging: false), cutoff: 10))
    }

    func testCutoffEdgeIsInclusive() {
        var p = BatteryPolicy()
        XCTAssertEqual(p.observe(battery(11), settings: settings(), now: t0), [])
        XCTAssertEqual(p.phase, .normal)
        let effects = p.observe(battery(10), settings: settings(), now: t0)
        XCTAssertEqual(p.phase, .grace)
        XCTAssertEqual(effects.count, 1)
        guard case let .pauseSessions(message, mode, percent) = effects[0] else { return XCTFail("\(effects)") }
        XCTAssertEqual(mode, .pause)
        XCTAssertEqual(percent, 10)
        XCTAssertTrue(message.hasPrefix("Battery is at ten percent and the Mac is about to sleep. Pause now"), message)
        XCTAssertTrue(message.contains("two-line summary"))
        XCTAssertTrue(p.pauseInFlight)
        XCTAssertEqual(p.graceEndsAt, t0.addingTimeInterval(90))
    }

    func testAfterTurnMessageAsksToFinishTheStep() {
        var p = BatteryPolicy()
        let effects = p.observe(battery(8), settings: settings(action: .afterTurn), now: t0)
        guard case let .pauseSessions(message, mode, _) = effects.first else { return XCTFail() }
        XCTAssertEqual(mode, .afterTurn)
        XCTAssertTrue(message.contains("Finish the step you're on, then stop"), message)
        XCTAssertEqual(p.mode, .afterTurn)
    }

    func testOffModeJustStopsKeepingAwake() {
        var p = BatteryPolicy()
        let effects = p.observe(battery(9), settings: settings(action: .off), now: t0)
        XCTAssertEqual(effects, [.trippedWithoutPause(percent: 9)])
        XCTAssertEqual(p.phase, .drained)
        XCTAssertFalse(p.pauseInFlight)
        XCTAssertEqual(p.boostDirective(battery(9)), .block)
        XCTAssertEqual(p.boostDirective(battery(9, ac: true)), .followAgents, "plugged in: no reason to let it sleep")
    }

    func testGraceHoldsThenReleasesAtDeadline() {
        var p = BatteryPolicy()
        let s = settings(grace: 60)
        _ = p.observe(battery(10), settings: s, now: t0)
        let paused = [session("a", at: t0)]
        let effects = p.pauseFinished(paused, settings: s, now: t0.addingTimeInterval(5))
        XCTAssertEqual(effects.count, 1)
        guard case let .pageSessions(entries, percent) = effects[0] else { return XCTFail("\(effects)") }
        XCTAssertEqual(percent, 10)
        XCTAssertEqual(entries.map(\.pageId), ["a-low_battery-\(Int(t0.timeIntervalSince1970))"])
        XCTAssertTrue(entries[0].pageOpen)

        XCTAssertEqual(p.boostDirective(battery(10)), .hold)
        XCTAssertEqual(p.observe(battery(9), settings: s, now: t0.addingTimeInterval(59)), [])
        XCTAssertEqual(p.phase, .grace)
        XCTAssertEqual(p.observe(battery(9), settings: s, now: t0.addingTimeInterval(60)), [.graceEnded(pausedCount: 1)])
        XCTAssertEqual(p.phase, .drained)
        XCTAssertEqual(p.boostDirective(battery(9)), .block)
        // Further readings don't re-pause or re-announce.
        XCTAssertEqual(p.observe(battery(7), settings: s, now: t0.addingTimeInterval(200)), [])
    }

    func testDeadlineWinsOverAHungPause() {
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(grace: 30), now: t0)
        XCTAssertTrue(p.pauseInFlight)
        XCTAssertEqual(p.observe(battery(10), settings: settings(grace: 30), now: t0.addingTimeInterval(31)),
                       [.graceEnded(pausedCount: 0)])
        XCTAssertEqual(p.boostDirective(battery(10)), .block)
        // The late result is still recorded and paged.
        let late = p.pauseFinished([session("a", at: t0)], settings: settings(), now: t0.addingTimeInterval(40))
        XCTAssertEqual(late.count, 1)
        XCTAssertEqual(p.entries.count, 1)
        XCTAssertEqual(p.phase, .drained)
    }

    func testNothingPausedEndsGraceImmediately() {
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(), now: t0)
        let effects = p.pauseFinished([], settings: settings(), now: t0.addingTimeInterval(2))
        XCTAssertEqual(effects, [.graceEnded(pausedCount: 0)])
        XCTAssertEqual(p.phase, .drained)
        XCTAssertEqual(p.boostDirective(battery(10)), .block)
    }

    func testDuplicateSessionsAreDeduplicated() {
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(), now: t0)
        let effects = p.pauseFinished([session("a", at: t0), session("a", at: t0), session("a", backend: .codex, at: t0)],
                                      settings: settings(), now: t0)
        guard case let .pageSessions(entries, _) = effects.first else { return XCTFail() }
        XCTAssertEqual(entries.count, 2, "same id on two backends is two sessions")
        XCTAssertEqual(p.entries.count, 2)
    }

    func testRecoveryRequiresACWhenConfigured() {
        var p = BatteryPolicy()
        let s = settings(recovery: 25, requiresAC: true)
        _ = p.observe(battery(10), settings: s, now: t0)
        _ = p.pauseFinished([session("a", at: t0)], settings: s, now: t0)
        _ = p.observe(battery(10), settings: s, now: t0.addingTimeInterval(100))
        XCTAssertEqual(p.phase, .drained)

        XCTAssertEqual(p.observe(battery(24, ac: false), settings: s, now: t0.addingTimeInterval(200)), [], "battery only, below recovery: not recovered")
        XCTAssertEqual(p.observe(battery(24, ac: true), settings: s, now: t0.addingTimeInterval(300)), [], "AC but below recovery")
        XCTAssertEqual(p.boostDirective(battery(24, ac: true)), .followAgents, "on AC the lockout doesn't block")

        let effects = p.observe(battery(25, ac: true), settings: s, now: t0.addingTimeInterval(400))
        XCTAssertEqual(effects.count, 1)
        guard case let .recovered(sessions, resume, message, closing) = effects[0] else { return XCTFail() }
        XCTAssertEqual(sessions.map(\.sessionId), ["a"])
        XCTAssertTrue(resume)
        XCTAssertEqual(message, "Power is back — carry on where you left off.")
        XCTAssertEqual(closing, ["a-low_battery-\(Int(t0.timeIntervalSince1970))"])
        XCTAssertEqual(p.phase, .normal)
        // The entries stay until the backends confirm the resume: the
        // Coordinator may hold it while the user is at the Mac (F5).
        XCTAssertEqual(p.pausedSessions.map(\.sessionId), ["a"])
        XCTAssertTrue(p.openPageIds.isEmpty, "the page is closed")
        XCTAssertTrue(p.awaitingAutoResume)
        XCTAssertNil(p.trippedAt)
        // One-shot: once attempted it is never owed again (the Coordinator
        // also removes every session it attempted automatically).
        p.autoResumeStarted()
        XCTAssertFalse(p.awaitingAutoResume)
        XCTAssertEqual(p.pausedSessions.map(\.sessionId), ["a"])
    }

    // PWR-3: charged while Page wasn't watching (asleep on a charger, then
    // unplugged) must leave the drained state even though recovery needs AC,
    // but without auto-resuming (that still needs AC).
    func testChargedWhileAwayLeavesDrainedWithoutResuming() {
        var p = BatteryPolicy()
        let s = settings(recovery: 25, requiresAC: true)
        _ = p.observe(battery(9), settings: s, now: t0)
        _ = p.pauseFinished([session("a", at: t0)], settings: s, now: t0)
        _ = p.observe(battery(9), settings: s, now: t0.addingTimeInterval(100))
        XCTAssertEqual(p.phase, .drained)
        // Relaunch, then the first reading is 100% on battery.
        p.restoredAfterLaunch(now: t0.addingTimeInterval(8 * 3600))
        let effects = p.observe(battery(100), settings: s, now: t0.addingTimeInterval(8 * 3600 + 1))
        guard case let .recovered(sessions, resume, _, closing) = effects.first else { return XCTFail("\(effects)") }
        XCTAssertFalse(resume, "recoveryRequiresAC: no auto-resume on battery")
        XCTAssertEqual(sessions.map(\.sessionId), ["a"])
        XCTAssertEqual(closing.count, 1, "the low-battery page is closed")
        XCTAssertEqual(p.phase, .normal)
        XCTAssertEqual(p.boostDirective(battery(100)), .followAgents, "agents can keep a charged Mac awake again")
        XCTAssertEqual(p.pausedSessions.map(\.sessionId), ["a"], "still listed for “Resume paused sessions now”")

        // A small rebound after load drops is not evidence of charging, even
        // when recovery == cutoff (allowed when AC is required).
        var q = BatteryPolicy()
        let tight = settings(cutoff: 10, recovery: 10, requiresAC: true)
        _ = q.observe(battery(10), settings: tight, now: t0)
        _ = q.pauseFinished([], settings: tight, now: t0)
        XCTAssertEqual(q.observe(battery(12), settings: tight, now: t0.addingTimeInterval(5)), [])
        XCTAssertEqual(q.phase, .drained)
        XCTAssertEqual(q.observe(battery(15), settings: tight, now: t0.addingTimeInterval(10)).count, 1)
        XCTAssertEqual(q.phase, .normal)
    }

    func testRecoveryWithoutACNeedsToBeAboveTheCutoff() {
        // Equal thresholds without the AC requirement would trip and recover
        // on the same reading; the policy refuses to recover at the cutoff.
        let s = settings(cutoff: 10, recovery: 10, requiresAC: false)
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: s, now: t0)
        XCTAssertEqual(p.phase, .grace)
        XCTAssertEqual(p.observe(battery(10), settings: s, now: t0.addingTimeInterval(1)), [])
        XCTAssertNotEqual(p.phase, .normal)
        let effects = p.observe(battery(11), settings: s, now: t0.addingTimeInterval(2))
        XCTAssertEqual(p.phase, .normal)
        guard case .recovered = effects.first else { return XCTFail("\(effects)") }

        // Normal hysteresis on battery.
        var q = BatteryPolicy()
        let s2 = settings(recovery: 30, requiresAC: false)
        _ = q.observe(battery(10), settings: s2, now: t0)
        XCTAssertEqual(q.observe(battery(29), settings: s2, now: t0.addingTimeInterval(1)), [])
        XCTAssertEqual(q.observe(battery(30), settings: s2, now: t0.addingTimeInterval(2)).count, 1)
        XCTAssertEqual(q.phase, .normal)
    }

    func testRecoveryWithoutResumeKeepsSessionsListedAndClosesPages() {
        var p = BatteryPolicy()
        let s = settings(resume: false)
        _ = p.observe(battery(10), settings: s, now: t0)
        _ = p.pauseFinished([session("a", at: t0), session("b", at: t0)], settings: s, now: t0)
        let effects = p.observe(battery(80, ac: true), settings: s, now: t0.addingTimeInterval(500))
        guard case let .recovered(sessions, resume, _, closing) = effects.first else { return XCTFail() }
        XCTAssertFalse(resume)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(closing.count, 2)
        XCTAssertEqual(p.entries.count, 2)
        XCTAssertTrue(p.openPageIds.isEmpty)
        // Resuming from the menu later clears them, with no pages to close.
        XCTAssertEqual(p.removeSessions(keys: [BatteryPolicy.key(sessions[0])]), [])
        XCTAssertEqual(p.pausedSessions.map(\.sessionId), ["b"])
    }

    func testRecoveredDuringGraceBeforePauseFinished() {
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(), now: t0)
        // Plugged in seconds later, before the backends reported back.
        let effects = p.observe(battery(30, ac: true), settings: settings(), now: t0.addingTimeInterval(3))
        guard case let .recovered(sessions, resume, _, _) = effects.first else { return XCTFail() }
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertFalse(resume, "nothing to resume yet")
        // The pause result arrives: resume those sessions straight away.
        let late = p.pauseFinished([session("a", at: t0)], settings: settings(), now: t0.addingTimeInterval(5))
        XCTAssertEqual(late, [.recovered(sessions: [session("a", at: t0)], resume: true,
                                         message: BatteryPolicy.recoveryMessage, closePageIds: [])])
        XCTAssertEqual(p.pausedSessions.map(\.sessionId), ["a"], "listed until the resume is confirmed")
        XCTAssertTrue(p.openPageIds.isEmpty)
        XCTAssertTrue(p.awaitingAutoResume)
        XCTAssertEqual(p.removeSessions(keys: ["claude|a"]), [])
        XCTAssertFalse(p.awaitingAutoResume, "nothing left to resume")
        XCTAssertEqual(p.phase, .normal)
    }

    func testCrashRecoveryFromPersistedState() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-battery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BatteryPauseStore(url: dir.appendingPathComponent("battery-paused.json"))

        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(grace: 90), now: t0)
        _ = p.pauseFinished([session("a", at: t0)], settings: settings(), now: t0.addingTimeInterval(4))
        XCTAssertTrue(store.save(p))

        // Page crashed; the Mac slept; it relaunches 2 hours later, still low.
        var restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored, p, "round-trips exactly")
        restored.restoredAfterLaunch(now: t0.addingTimeInterval(7200))
        XCTAssertEqual(restored.phase, .drained)
        XCTAssertFalse(restored.pauseInFlight)
        XCTAssertEqual(restored.observe(battery(8), settings: settings(), now: t0.addingTimeInterval(7201)), [],
                       "never re-pauses or re-pages after a relaunch")
        XCTAssertEqual(restored.openPageIds, ["a-low_battery-\(Int(t0.timeIntervalSince1970))"])

        // Woken on AC with a full battery: resumes the remembered sessions.
        let effects = restored.observe(battery(90, ac: true), settings: settings(), now: t0.addingTimeInterval(9000))
        guard case let .recovered(sessions, resume, _, closing) = effects.first else { return XCTFail() }
        XCTAssertEqual(sessions.map(\.sessionId), ["a"])
        XCTAssertTrue(resume)
        XCTAssertEqual(closing.count, 1)

        // A cleared state removes the file.
        XCTAssertTrue(store.save(BatteryPolicy()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        XCTAssertNil(store.load())
    }

    func testRelaunchMidGraceKeepsHoldingUntilTheDeadline() {
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(grace: 90), now: t0)
        p.restoredAfterLaunch(now: t0.addingTimeInterval(30))
        XCTAssertEqual(p.phase, .grace)
        XCTAssertFalse(p.pauseInFlight)
        XCTAssertEqual(p.boostDirective(battery(10)), .hold)
        XCTAssertEqual(p.observe(battery(10), settings: settings(), now: t0.addingTimeInterval(91)), [.graceEnded(pausedCount: 0)])
    }

    func testCorruptStoreIsIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-battery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("battery-paused.json")
        try Data("{not json".utf8).write(to: url)
        XCTAssertNil(BatteryPauseStore(url: url).load())
    }

    func testStaleEntriesArePrunedAndRetripReplacesEntry() {
        var p = BatteryPolicy()
        let s = settings(resume: false)
        _ = p.observe(battery(10), settings: s, now: t0)
        _ = p.pauseFinished([session("a", at: t0)], settings: s, now: t0)
        _ = p.observe(battery(50, ac: true), settings: s, now: t0.addingTimeInterval(60))
        XCTAssertEqual(p.entries.count, 1)

        // Trips again an hour later and pauses the same session: one entry,
        // new page id, page open.
        let t1 = t0.addingTimeInterval(3600)
        _ = p.observe(battery(10), settings: s, now: t1)
        let effects = p.pauseFinished([session("a", at: t1)], settings: s, now: t1)
        guard case let .pageSessions(entries, _) = effects.first else { return XCTFail() }
        XCTAssertEqual(entries.first?.pageId, "a-low_battery-\(Int(t1.timeIntervalSince1970))")
        XCTAssertEqual(p.entries.count, 1)
        XCTAssertEqual(p.phase, .grace)

        // A third trip that pauses nothing ends grace at once, even though
        // an old (closed-page) entry is still listed.
        _ = p.observe(battery(60, ac: true), settings: s, now: t1.addingTimeInterval(10))
        let t2 = t1.addingTimeInterval(600)
        _ = p.observe(battery(10), settings: s, now: t2)
        XCTAssertEqual(p.pauseFinished([], settings: s, now: t2), [.graceEnded(pausedCount: 0)])

        // A day later, back to normal: the entry is forgotten.
        _ = p.observe(battery(60, ac: true), settings: s, now: t2.addingTimeInterval(10))
        _ = p.observe(battery(60, ac: true), settings: s, now: t1.addingTimeInterval(BatteryPolicy.staleEntryAge + 1))
        XCTAssertTrue(p.entries.isEmpty)
    }

    func testPageBookkeeping() {
        var p = BatteryPolicy()
        _ = p.observe(battery(10), settings: settings(), now: t0)
        _ = p.pauseFinished([session("a", at: t0), session("b", at: t0)], settings: settings(), now: t0)
        let idA = BatteryPolicy.pageId(sessionId: "a", trippedAt: t0)
        XCTAssertTrue(BatteryPolicy.isLowBatteryPageId(idA))
        XCTAssertFalse(BatteryPolicy.isLowBatteryPageId("a-idle-123"))
        XCTAssertEqual(p.entry(forPageId: idA)?.session.sessionId, "a")
        p.markPageClosed(idA)
        XCTAssertEqual(p.openPageIds, [BatteryPolicy.pageId(sessionId: "b", trippedAt: t0)])
        XCTAssertEqual(p.pausedSessions.count, 2, "deny leaves it paused")
        let closing = p.removeSessions(keys: ["claude|a", "claude|b"])
        XCTAssertEqual(closing, [BatteryPolicy.pageId(sessionId: "b", trippedAt: t0)])
        XCTAssertTrue(p.entries.isEmpty)
    }

    func testReplyDecision() {
        XCTAssertEqual(BatteryPolicy.replyDecision(action: "deny", text: "no", stillTripped: true), .leavePaused)
        XCTAssertEqual(BatteryPolicy.replyDecision(action: "carry_on", text: "carry on", stillTripped: true),
                       .resume(message: "Carry on where you left off."))
        XCTAssertEqual(BatteryPolicy.replyDecision(action: "approve", text: "", stillTripped: false),
                       .resume(message: "Power is back — carry on where you left off."))
        XCTAssertEqual(BatteryPolicy.replyDecision(action: "custom", text: "  commit what you have\n", stillTripped: true),
                       .resume(message: "commit what you have"))
        XCTAssertEqual(BatteryPolicy.replyDecision(action: nil, text: "push it", stillTripped: false), .resume(message: "push it"))
        XCTAssertEqual(BatteryPolicy.replyDecision(action: "custom", text: "   ", stillTripped: true), .reject(detail: "Empty reply"))
    }

    func testPageContextCopy() {
        XCTAssertEqual(BatteryPolicy.pageContext(percent: 10),
                       "Battery 10% — Page paused this session. Plug in to continue, or reply to send instructions.")
    }

    func testLegacyLockoutPolicyUsesTheSameRules() {
        XCTAssertTrue(LockoutPolicy.nextTripped(current: false, power: battery(10), cutoff: 10, recovery: 25, recoveryRequiresAC: true))
        XCTAssertFalse(LockoutPolicy.nextTripped(current: false, power: battery(10, ac: true), cutoff: 10, recovery: 25, recoveryRequiresAC: true))
        XCTAssertFalse(LockoutPolicy.nextTripped(current: true, power: battery(10), cutoff: 10, recovery: 10, recoveryRequiresAC: false) == false,
                       "at the cutoff on battery it must stay tripped")
    }
}

// MARK: - Assertions

final class AwakeAssertionTests: XCTestCase {
    func testPlan() {
        XCTAssertEqual(AwakeAssertions.plan(boost: false, power: battery(80, ac: true), lidClosedOnAC: true), .none)
        XCTAssertEqual(AwakeAssertions.plan(boost: true, power: battery(80, ac: true), lidClosedOnAC: true),
                       AwakeAssertions(preventIdleSleep: true, preventSystemSleep: true))
        XCTAssertEqual(AwakeAssertions.plan(boost: true, power: battery(80, ac: true), lidClosedOnAC: false),
                       AwakeAssertions(preventIdleSleep: true, preventSystemSleep: false))
        XCTAssertEqual(AwakeAssertions.plan(boost: true, power: battery(80), lidClosedOnAC: true),
                       AwakeAssertions(preventIdleSleep: true, preventSystemSleep: false),
                       "PreventSystemSleep is AC-only; don't claim it on battery")
        XCTAssertEqual(AwakeAssertions.plan(boost: true, power: .noBattery, lidClosedOnAC: true).preventIdleSleep, true)
    }
}

// MARK: - SleepGuard

final class SleepGuardPolicyTests: XCTestCase {
    private func inputs(_ mutate: (inout SleepGuardPolicy.Inputs) -> Void = { _ in }) -> SleepGuardPolicy.Inputs {
        var i = SleepGuardPolicy.Inputs(enabled: true, boosting: true, agentsWorking: true, power: battery(50), cutoff: 10,
                                        thermal: .nominal, helperAvailable: true, batteryPhase: .normal,
                                        currentlyActive: false, watchdogLoaded: true)
        mutate(&i)
        return i
    }

    func testAllConditionsMustHold() {
        XCTAssertTrue(SleepGuardPolicy.shouldDisableSleep(inputs()))
        XCTAssertTrue(SleepGuardPolicy.shouldDisableSleep(inputs { $0.thermal = .fair }))
        XCTAssertFalse(SleepGuardPolicy.shouldDisableSleep(inputs { $0.enabled = false }))
        XCTAssertFalse(SleepGuardPolicy.shouldDisableSleep(inputs { $0.boosting = false }))
        XCTAssertFalse(SleepGuardPolicy.shouldDisableSleep(inputs { $0.power = battery(50, ac: true) }), "AC uses the assertion instead")
        XCTAssertFalse(SleepGuardPolicy.shouldDisableSleep(inputs { $0.power = .noBattery }))
        XCTAssertFalse(SleepGuardPolicy.shouldDisableSleep(inputs { $0.power = battery(15) }), "needs strictly above cutoff+5")
        XCTAssertTrue(SleepGuardPolicy.shouldDisableSleep(inputs { $0.power = battery(16) }))
        XCTAssertFalse(SleepGuardPolicy.shouldDisableSleep(inputs { $0.thermal = .serious }))
        XCTAssertFalse(SleepGuardPolicy.shouldDisableSleep(inputs { $0.thermal = .critical }))
        XCTAssertFalse(SleepGuardPolicy.shouldDisableSleep(inputs { $0.helperAvailable = false }))
        XCTAssertEqual(SleepGuardPolicy.blocker(inputs { $0.power = battery(12) }), "battery at 12% (needs above 15%)")
        XCTAssertFalse(SleepGuardPolicy.shouldDisableSleep(inputs { $0.watchdogLoaded = false }), "never without the safety net")
    }

    // PWR-1: a rate-limit / pending-page / waiting hold keeps the assertion
    // but must not keep a closed Mac awake.
    func testHoldsWithoutWorkingAgentsBlock() {
        let held = inputs { $0.agentsWorking = false }
        XCTAssertEqual(SleepGuardPolicy.blocker(held), "agents aren’t working")
        XCTAssertNotNil(SleepGuardPolicy.blocker(inputs { $0.agentsWorking = false; $0.currentlyActive = true }),
                        "an active flag is cleared when the agents stop")
    }

    // PWR-4: the margin is for switching on; once on, the flag holds down to
    // the cutoff (where the battery pause trips) and through grace.
    func testHysteresisAndGraceHandOff() {
        XCTAssertNotNil(SleepGuardPolicy.blocker(inputs { $0.power = battery(12) }), "not turned on below cutoff+5")
        XCTAssertNil(SleepGuardPolicy.blocker(inputs { $0.power = battery(12); $0.currentlyActive = true }),
                     "kept on between the cutoff and cutoff+5")
        XCTAssertNotNil(SleepGuardPolicy.blocker(inputs { $0.power = battery(10); $0.currentlyActive = true }),
                        "in the normal phase the cutoff itself clears it")
        // Grace: tripped at the cutoff — keep it (agents may be idle after
        // their summary; the hold is bounded by the grace period).
        XCTAssertNil(SleepGuardPolicy.blocker(inputs {
            $0.power = battery(10); $0.batteryPhase = .grace; $0.currentlyActive = true; $0.agentsWorking = false
        }))
        XCTAssertNotNil(SleepGuardPolicy.blocker(inputs { $0.power = battery(10); $0.batteryPhase = .grace }),
                        "never turned on during grace")
        XCTAssertNotNil(SleepGuardPolicy.blocker(inputs { $0.power = battery(9); $0.batteryPhase = .drained; $0.currentlyActive = true }),
                        "cleared once grace is over")
        XCTAssertNotNil(SleepGuardPolicy.blocker(inputs {
            $0.power = battery(SleepGuardPolicy.hardFloor); $0.batteryPhase = .grace; $0.currentlyActive = true
        }), "hard floor")
        XCTAssertNotNil(SleepGuardPolicy.blocker(inputs {
            $0.cutoff = 0; $0.power = battery(4); $0.currentlyActive = true
        }), "hard floor applies with a 0% cutoff too")
        // Grace keeps the unconditional checks.
        XCTAssertNotNil(SleepGuardPolicy.blocker(inputs {
            $0.power = battery(10); $0.batteryPhase = .grace; $0.currentlyActive = true; $0.thermal = .serious
        }))
        XCTAssertNotNil(SleepGuardPolicy.blocker(inputs {
            $0.power = battery(10, ac: true); $0.batteryPhase = .grace; $0.currentlyActive = true
        }))
    }

    /// Walks the evaluatePower order (observe, then the policy) from 30% down
    /// through the trip: the flag must still be on when the pause starts.
    func testFlagSurvivesUntilThePauseTrips() {
        var policy = BatteryPolicy()
        let s = settings(cutoff: 10)
        var active = false
        var trippedWhileActive = false
        for (i, pct) in [30, 20, 16, 15, 12, 11, 10].enumerated() {
            let p = battery(pct)
            let effects = policy.observe(p, settings: s, now: t0.addingTimeInterval(Double(i) * 60))
            let want = SleepGuardPolicy.shouldDisableSleep(inputs {
                $0.power = p; $0.batteryPhase = policy.phase; $0.currentlyActive = active
            })
            if effects.contains(where: { if case .pauseSessions = $0 { return true }; return false }) {
                trippedWhileActive = active && want
            }
            active = want
        }
        XCTAssertTrue(trippedWhileActive, "pause trips at the cutoff while disablesleep is still on")
    }
}

/// Records every command instead of running it. Nothing here ever reaches
/// sudo, pmset or launchctl.
private final class FakeRunner {
    var calls: [[String]] = []
    var markerExistedAtEnable: Bool?
    var failPmset: Set<String> = []   // "0" / "1"
    var helperOK = true
    var launchctlPrintOK = false
    /// Consumed before falling back to `launchctlPrintOK`.
    var launchctlPrintQueue: [Bool] = []
    var bootstrapFailuresLeft = 0
    /// What `pmset -g` prints ("" = unparseable, i.e. unknown).
    var pmsetGOutput = ""
    let marker: URL

    init(marker: URL) { self.marker = marker }

    func run(_ path: String, _ args: [String], _ timeout: TimeInterval) -> ProcessRunner.Result {
        calls.append([path] + args)
        func result(_ ok: Bool) -> ProcessRunner.Result {
            ProcessRunner.Result(status: ok ? 0 : 1, stdout: "", stderr: ok ? "" : "denied", timedOut: false, launched: true)
        }
        if path == SleepGuard.sudo, args.contains("-l") { return result(helperOK) }
        if path == SleepGuard.pmset, args == ["-g"] {
            return ProcessRunner.Result(status: 0, stdout: pmsetGOutput, stderr: "", timedOut: false, launched: true)
        }
        if path == SleepGuard.sudo, let value = args.last {
            if value == "1" { markerExistedAtEnable = FileManager.default.fileExists(atPath: marker.path) }
            return result(!failPmset.contains(value))
        }
        if path == SleepGuard.launchctl, args.first == "print" {
            if !launchctlPrintQueue.isEmpty { return result(launchctlPrintQueue.removeFirst()) }
            return result(launchctlPrintOK)
        }
        if path == SleepGuard.launchctl, args.first == "bootstrap", bootstrapFailuresLeft > 0 {
            bootstrapFailuresLeft -= 1
            return result(false)
        }
        return result(true)
    }
}

final class SleepGuardTests: XCTestCase {
    private var dir: URL!
    private var paths: SleepGuard.Paths!
    private var fake: FakeRunner!
    private var clock = t0
    private var sleeps: [TimeInterval] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-sleepguard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        paths = SleepGuard.Paths(
            marker: dir.appendingPathComponent("support/disablesleep.active"),
            script: dir.appendingPathComponent("support/sleepguard.sh"),
            launchAgent: dir.appendingPathComponent("LaunchAgents/\(SleepGuardWatchdog.label).plist"),
            log: dir.appendingPathComponent("Logs/Page.sleepguard.log"))
        fake = FakeRunner(marker: paths.marker)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeGuard() -> SleepGuard {
        let f = fake!
        return SleepGuard(paths: paths, uid: 501, now: { [unowned self] in self.clock },
                          sleeper: { [unowned self] in self.sleeps.append($0) }, runner: f.run)
    }

    private var pmsetCalls: [[String]] { fake.calls.filter { $0.first == SleepGuard.sudo && !$0.contains("-l") } }

    func testEnableWritesMarkerFirstAndDisableRemovesIt() {
        let g = makeGuard()
        g.update(shouldDisableSleep: true, reason: "test")
        XCTAssertTrue(g.isActive)
        XCTAssertEqual(fake.markerExistedAtEnable, true, "marker must exist before disablesleep 1")
        XCTAssertEqual(pmsetCalls, [[SleepGuard.sudo, "-n", "/usr/bin/pmset", "-a", "disablesleep", "1"]])

        g.update(shouldDisableSleep: true, reason: "again")
        XCTAssertEqual(pmsetCalls.count, 1, "idempotent")

        g.update(shouldDisableSleep: false, reason: "agents stopped")
        XCTAssertFalse(g.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marker.path))
        XCTAssertEqual(pmsetCalls.last, [SleepGuard.sudo, "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"])
    }

    func testFailedDisableKeepsMarkerAndRetries() {
        let g = makeGuard()
        g.update(shouldDisableSleep: true, reason: "test")
        fake.failPmset = ["0"]
        g.update(shouldDisableSleep: false, reason: "stop")
        XCTAssertTrue(g.cleanupPending, "may still be on — keep retrying")
        XCTAssertFalse(g.isActive, "the menu must not claim the lid can be closed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.marker.path))
        g.update(shouldDisableSleep: false, reason: "stop")
        XCTAssertEqual(pmsetCalls.filter { $0.last == "0" }.count, 2)
        fake.failPmset = []
        g.update(shouldDisableSleep: false, reason: "stop")
        XCTAssertFalse(g.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marker.path))
    }

    func testFailedEnableUndoesAndMarksHelperMissing() {
        let g = makeGuard()
        fake.failPmset = ["1"]
        g.update(shouldDisableSleep: true, reason: "test")
        XCTAssertFalse(g.isActive)
        XCTAssertEqual(pmsetCalls.map { $0.last }, ["1", "0"], "a failed enable is followed by a defensive disable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marker.path))
        XCTAssertEqual(g.cachedHelperStatus, .missing)
        // Cached: no sudo -l until the cache expires or a refresh is asked for.
        XCTAssertEqual(g.helperStatus(), .missing)
        XCTAssertFalse(fake.calls.contains { $0.contains("-l") })
    }

    func testForceDisableOnlyWhenSomethingToUndo() {
        let g = makeGuard()
        XCTAssertTrue(g.forceDisable(reason: "launch"))
        XCTAssertTrue(fake.calls.isEmpty, "no marker, not active: nothing to run")

        // Left over from a crashed run.
        try? FileManager.default.createDirectory(at: paths.marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.marker.path, contents: Data("pid 1".utf8))
        XCTAssertTrue(g.forceDisable(reason: "found on launch"))
        XCTAssertEqual(pmsetCalls, [[SleepGuard.sudo, "-n", "/usr/bin/pmset", "-a", "disablesleep", "0"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marker.path))
    }

    func testFailedLaunchResetKeepsRetryingOnTicks() {
        try? FileManager.default.createDirectory(at: paths.marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.marker.path, contents: Data("pid 1".utf8))
        let g = makeGuard()
        fake.failPmset = ["0"]
        XCTAssertFalse(g.forceDisable(reason: "found on launch"))
        XCTAssertTrue(g.cleanupPending, "a leftover that couldn't be cleared must be retried")
        XCTAssertFalse(g.isActive)
        fake.failPmset = []
        g.update(shouldDisableSleep: false, reason: "tick")
        XCTAssertFalse(g.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marker.path))
        XCTAssertEqual(pmsetCalls.map { $0.last }, ["0", "0"])
    }

    func testHelperStatusIsCachedAndChecksBothCommands() {
        let g = makeGuard()
        XCTAssertEqual(g.cachedHelperStatus, .unknown)
        XCTAssertEqual(g.helperStatus(), .available)
        let checks = fake.calls.filter { $0.contains("-l") }
        XCTAssertEqual(checks, [
            [SleepGuard.sudo, "-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"],
            [SleepGuard.sudo, "-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"]
        ])
        _ = g.helperStatus()
        XCTAssertEqual(fake.calls.filter { $0.contains("-l") }.count, 2, "cached")
        fake.helperOK = false
        clock = t0.addingTimeInterval(SleepGuard.helperCacheSeconds + 1)
        XCTAssertEqual(g.helperStatus(), .missing, "re-checked after the cache expires")
        fake.helperOK = true
        XCTAssertEqual(g.helperStatus(refresh: true), .available)
    }

    func testWatchdogInstallUninstall() throws {
        let g = makeGuard()
        try g.installWatchdog()
        let fm = FileManager.default
        XCTAssertTrue(fm.isExecutableFile(atPath: paths.script.path))
        let perms = try fm.attributesOfItem(atPath: paths.launchAgent.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o644)
        let launchctl = fake.calls.filter { $0.first == SleepGuard.launchctl }
        XCTAssertEqual(launchctl.map { $0[1] }, ["bootout", "print", "bootstrap"],
                       "fresh files: no need to ask launchd first; wait for the bootout to finish")
        XCTAssertTrue(g.watchdogLoaded)
        XCTAssertEqual(launchctl.last, [SleepGuard.launchctl, "bootstrap", "gui/501", paths.launchAgent.path])

        // Plist content.
        let data = try Data(contentsOf: paths.launchAgent)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, "local.Page.sleepguard")
        XCTAssertEqual(plist["StartInterval"] as? Int, 60)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], ["/bin/sh", paths.script.path])

        // Unchanged and loaded: no reload.
        fake.calls = []
        fake.launchctlPrintOK = true
        try g.installWatchdog()
        XCTAssertEqual(fake.calls.map { $0[1] }, ["print"])

        // Turning the option off while the flag might still be on keeps it.
        FileManager.default.createFile(atPath: paths.marker.path, contents: Data())
        g.syncWatchdog(enabled: false)
        XCTAssertTrue(fm.fileExists(atPath: paths.launchAgent.path))
        try fm.removeItem(at: paths.marker)
        g.syncWatchdog(enabled: false)
        XCTAssertFalse(fm.fileExists(atPath: paths.launchAgent.path))
        XCTAssertFalse(fm.fileExists(atPath: paths.script.path))
        XCTAssertEqual(fake.calls.last, [SleepGuard.launchctl, "bootout", "gui/501/local.Page.sleepguard"])
    }

    func testWatchdogScriptAndPlistAreValid() throws {
        let marker = "/Users/x/Library/Application Support/ClaudePowerMode/disablesleep.active"
        let script = SleepGuardWatchdog.script(markerPath: marker)
        XCTAssertTrue(script.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(script.contains("MARKER='\(marker)'"), "path with spaces is single-quoted")
        XCTAssertTrue(script.contains("/usr/bin/sudo -n /usr/bin/pmset -a disablesleep 0"))
        XCTAssertFalse(script.contains("-a disablesleep 1"), "the watchdog only ever turns it off")
        XCTAssertTrue(script.contains("/usr/bin/pgrep -U \"$ME\" -x ClaudePowerMode"))

        // Syntax-check (sh -n parses without executing anything) and lint
        // the plist, both in the temp dir.
        let scriptURL = dir.appendingPathComponent("check.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(ProcessRunner.run("/bin/sh", ["-n", scriptURL.path]).succeeded)
        let plistURL = dir.appendingPathComponent("check.plist")
        try SleepGuardWatchdog.plist(scriptPath: "/tmp/x y/sleepguard.sh", logPath: "/tmp/l.log").write(to: plistURL)
        XCTAssertTrue(ProcessRunner.run("/usr/bin/plutil", ["-lint", "-s", plistURL.path]).succeeded)
    }

    func testWatchdogScriptBehaviourWithStubbedCommands() throws {
        // Run the generated logic against a marker in the temp dir with the
        // system paths swapped for stubs, so nothing real is invoked: the
        // stub "sudo" just records its arguments.
        let marker = dir.appendingPathComponent("m.active")
        let log = dir.appendingPathComponent("sudo.log")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try stub("sudo", "echo \"$@\" >> \(ProcessRunner.shellQuote(log.path))")
        try stub("pgrep", "exit 1")   // Page not running
        try stub("id", "echo 501")
        try stub("rm", "/bin/rm \"$@\"")
        try stub("date", "echo now")
        var script = SleepGuardWatchdog.script(markerPath: marker.path)
        for cmd in ["/usr/bin/sudo", "/usr/bin/pgrep", "/usr/bin/id", "/bin/rm", "/bin/date"] {
            let name = (cmd as NSString).lastPathComponent
            script = script.replacingOccurrences(of: cmd + " ", with: bin.appendingPathComponent(name).path + " ")
            script = script.replacingOccurrences(of: cmd + ")", with: bin.appendingPathComponent(name).path + ")")
        }
        // Fail closed: never execute the script if any real command survived.
        guard !script.contains("/usr/bin/sudo"), !script.contains("/usr/bin/pmset -a disablesleep 0;") || script.contains(bin.path + "/sudo -n /usr/bin/pmset"),
              !script.contains("/usr/bin/pgrep") else {
            return XCTFail("stub substitution failed:\n\(script)")
        }
        let scriptURL = dir.appendingPathComponent("wd.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        // No marker: does nothing.
        XCTAssertTrue(ProcessRunner.run("/bin/sh", [scriptURL.path]).succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))

        // Marker and Page gone: clears the flag and the marker.
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        XCTAssertTrue(ProcessRunner.run("/bin/sh", [scriptURL.path]).succeeded)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "-n /usr/bin/pmset -a disablesleep 0\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        // Marker but Page running: leaves it alone.
        try stub("pgrep", "exit 0")
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        XCTAssertTrue(ProcessRunner.run("/bin/sh", [scriptURL.path]).succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }.count, 1)
    }
}

extension SleepGuardTests {
    // PWR-6: enable denied and the defensive clear denied too (rule removed
    // inside the helper cache window). pmset 1 never ran, so the menu must
    // not say the lid can be closed — but the clear stays pending.
    func testFailedEnableWithFailedCleanupIsNotActive() {
        let g = makeGuard()
        fake.failPmset = ["0", "1"]
        g.update(shouldDisableSleep: true, reason: "test")
        XCTAssertFalse(g.isActive)
        XCTAssertTrue(g.cleanupPending)
        // Never re-enables over a failing clear, even if the policy says yes.
        fake.failPmset = []
        clock = t0.addingTimeInterval(SleepGuard.missingHelperRetrySeconds + 1)
        fake.helperOK = true
        g.update(shouldDisableSleep: true, reason: "tick")
        XCTAssertEqual(pmsetCalls.map { $0.last }, ["1", "0", "0"], "retries the clear, doesn't enable")
        XCTAssertFalse(g.cleanupPending)
        g.update(shouldDisableSleep: true, reason: "tick")
        XCTAssertTrue(g.isActive, "enables again only once the clear went through")
    }

    func testRetryBacksOffWhileHelperMissing() {
        let g = makeGuard()
        fake.failPmset = ["0", "1"]
        fake.helperOK = false
        g.update(shouldDisableSleep: true, reason: "test")   // 1, 0 (helper marked missing)
        for i in 1...3 {
            clock = t0.addingTimeInterval(Double(i) * 15)
            g.update(shouldDisableSleep: false, reason: "tick")
        }
        XCTAssertEqual(pmsetCalls.count, 2, "no sudo storm every 15 s while the rule is gone")
        clock = t0.addingTimeInterval(SleepGuard.missingHelperRetrySeconds + 1)
        g.update(shouldDisableSleep: false, reason: "tick")
        XCTAssertEqual(pmsetCalls.count, 3, "but it keeps retrying")
        XCTAssertFalse(g.forceDisable(reason: "quit"), "quit always tries")
        XCTAssertEqual(pmsetCalls.count, 4)
    }

    // PWR-6 / PWR-2: the user ran the menu's `sudo pmset -a disablesleep 0`
    // by hand (the rule is gone, so Page's own clear can never succeed): the
    // pending clear and its warning go away.
    func testPendingClearEndsWhenTheFlagReadsOff() {
        let g = makeGuard()
        g.update(shouldDisableSleep: true, reason: "working")
        fake.failPmset = ["0", "1"]
        fake.helperOK = false
        g.update(shouldDisableSleep: false, reason: "stop")
        XCTAssertTrue(g.cleanupPending)
        // Still on, or unparseable output: keep it pending (fail closed).
        fake.pmsetGOutput = "System-wide power settings:\n SleepDisabled\t\t1\nCurrently in use:\n sleep 1\n"
        g.update(shouldDisableSleep: false, reason: "tick")
        XCTAssertTrue(g.cleanupPending)
        fake.pmsetGOutput = "garbage"
        g.update(shouldDisableSleep: false, reason: "tick")
        XCTAssertTrue(g.cleanupPending)
        // Off (no SleepDisabled line, as macOS prints it).
        fake.pmsetGOutput = "System-wide power settings:\nCurrently in use:\n standby              1\n sleep                0 (sleep prevented by Page)\n"
        g.update(shouldDisableSleep: false, reason: "tick")
        XCTAssertFalse(g.cleanupPending)
        XCTAssertFalse(g.isActive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marker.path))
    }

    func testSleepDisabledParsing() {
        XCTAssertTrue(SleepGuard.sleepDisabledIsOff(pmsetOutput: "System-wide power settings:\nCurrently in use:\n sleep 0\n"))
        XCTAssertTrue(SleepGuard.sleepDisabledIsOff(pmsetOutput: "System-wide power settings:\n SleepDisabled\t0\nCurrently in use:\n"))
        XCTAssertFalse(SleepGuard.sleepDisabledIsOff(pmsetOutput: "System-wide power settings:\n SleepDisabled\t\t1\n"))
        XCTAssertFalse(SleepGuard.sleepDisabledIsOff(pmsetOutput: "System-wide power settings:\n SleepDisabled\n"))
        XCTAssertFalse(SleepGuard.sleepDisabledIsOff(pmsetOutput: ""))
    }

    // PWR-7 / CONC-3: after the quit/signal clear, a racing tick must not be
    // able to turn disablesleep back on.
    func testSealedGuardNeverReEnables() {
        let g = makeGuard()
        g.update(shouldDisableSleep: true, reason: "working")
        XCTAssertTrue(g.sealAndDisable(reason: "signal 15"))
        XCTAssertFalse(g.isActive)
        XCTAssertTrue(g.isSealed)
        g.update(shouldDisableSleep: true, reason: "late tick")
        XCTAssertFalse(g.isActive)
        XCTAssertEqual(pmsetCalls.map { $0.last }, ["1", "0"], "no pmset 1 after the seal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.marker.path))
        // A plain forceDisable (launch) does not seal.
        let fresh = makeGuard()
        fresh.forceDisable(reason: "found on launch")
        fresh.update(shouldDisableSleep: true, reason: "working")
        XCTAssertTrue(fresh.isActive)
    }

    // PWR-8: Page refreshes the marker for the watchdog's hung check, and a
    // marker removed outside Page means the flag is off now.
    func testMarkerHeartbeatAndExternalClear() throws {
        let g = makeGuard()
        g.update(shouldDisableSleep: true, reason: "working")
        let old = Date().addingTimeInterval(-600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: paths.marker.path)
        g.update(shouldDisableSleep: true, reason: "still working")
        let mtime = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: paths.marker.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(mtime, Date().addingTimeInterval(-60), "heartbeat refreshed the mtime")
        XCTAssertEqual(pmsetCalls.count, 1)

        try FileManager.default.removeItem(at: paths.marker)   // watchdog cleared it
        g.update(shouldDisableSleep: false, reason: "stopped")
        XCTAssertFalse(g.isActive)
        XCTAssertEqual(pmsetCalls.count, 1, "nothing to clear")
        g.update(shouldDisableSleep: true, reason: "working again")
        XCTAssertTrue(g.isActive, "can be set again after an external clear")
        XCTAssertEqual(pmsetCalls.map { $0.last }, ["1", "1"])
    }

    func testWatchdogReloadWaitsForBootoutAndRetriesBootstrap() throws {
        let g = makeGuard()
        fake.launchctlPrintQueue = [true, true, false]   // still loaded twice after bootout
        fake.bootstrapFailuresLeft = 1
        try g.installWatchdog()
        let verbs = fake.calls.filter { $0.first == SleepGuard.launchctl }.map { $0[1] }
        XCTAssertEqual(verbs, ["bootout", "print", "print", "print", "bootstrap", "bootstrap"])
        XCTAssertEqual(sleeps, [0.5, 0.5, 1])
        XCTAssertTrue(g.watchdogLoaded)

        // Bootstrap keeps failing: reported as not loaded (the policy then
        // keeps lid-closed-on-battery off).
        let h = makeGuard()
        try? FileManager.default.removeItem(at: paths.launchAgent)
        fake.bootstrapFailuresLeft = 10
        try h.installWatchdog()
        XCTAssertFalse(h.watchdogLoaded)
        h.uninstallWatchdog()
        XCTAssertFalse(h.watchdogLoaded)
    }

    func testWatchdogClearsAStaleMarkerEvenWhilePageRuns() throws {
        let script = SleepGuardWatchdog.script(markerPath: "/tmp/m")
        XCTAssertTrue(script.contains("/usr/bin/find \"$MARKER\" -mmin +\(SleepGuardWatchdog.staleMarkerMinutes)"))

        let marker = dir.appendingPathComponent("stale.active")
        let log = dir.appendingPathComponent("sudo2.log")
        let bin = dir.appendingPathComponent("bin2")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        func stub(_ name: String, _ body: String) throws {
            let url = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try stub("sudo", "echo \"$@\" >> \(ProcessRunner.shellQuote(log.path))")
        try stub("pgrep", "exit 0")   // Page IS running
        try stub("id", "echo 501")
        try stub("rm", "/bin/rm \"$@\"")
        try stub("date", "echo now")
        var body = SleepGuardWatchdog.script(markerPath: marker.path)
        for cmd in ["/usr/bin/sudo", "/usr/bin/pgrep", "/usr/bin/id", "/bin/rm", "/bin/date"] {
            let name = (cmd as NSString).lastPathComponent
            body = body.replacingOccurrences(of: cmd + " ", with: bin.appendingPathComponent(name).path + " ")
            body = body.replacingOccurrences(of: cmd + ")", with: bin.appendingPathComponent(name).path + ")")
        }
        guard !body.contains("/usr/bin/sudo"), !body.contains("/usr/bin/pgrep") else {
            return XCTFail("stub substitution failed:\n\(body)")
        }
        let url = dir.appendingPathComponent("wd2.sh")
        try body.write(to: url, atomically: true, encoding: .utf8)

        // Fresh marker, Page running: left alone.
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        XCTAssertTrue(ProcessRunner.run("/bin/sh", [url.path]).succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))

        // Not refreshed for 10 minutes: Page is hung — clear it anyway.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: marker.path)
        XCTAssertTrue(ProcessRunner.run("/bin/sh", [url.path]).succeeded)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "-n /usr/bin/pmset -a disablesleep 0\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
}

// MARK: - Config / Preferences

final class PowerConfigTests: XCTestCase {
    func testDefaults() {
        let c = Config()
        XCTAssertTrue(c.keepAwakeLidClosedOnAC)
        XCTAssertFalse(c.keepAwakeLidClosedOnBattery)
        XCTAssertEqual(c.lowBatteryAction, .pause)
        XCTAssertEqual(c.lowBatteryPauseGraceSeconds, 90)
        XCTAssertTrue(c.resumeAfterBatteryRecovery)
    }

    func testDecodingNewKeysAndBadValues() throws {
        let json = """
        {"lowBatteryAction": "afterTurn", "keepAwakeLidClosedOnBattery": true,
         "lowBatteryPauseGraceSeconds": 120, "resumeAfterBatteryRecovery": false,
         "keepAwakeLidClosedOnAC": false}
        """
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.lowBatteryAction, .afterTurn)
        XCTAssertTrue(c.keepAwakeLidClosedOnBattery)
        XCTAssertFalse(c.keepAwakeLidClosedOnAC)
        XCTAssertEqual(c.lowBatteryPauseGraceSeconds, 120)
        XCTAssertFalse(c.resumeAfterBatteryRecovery)

        let issues = Config.DecodeIssues()
        let decoder = JSONDecoder()
        decoder.userInfo[Config.decodeIssuesKey] = issues
        let bad = try decoder.decode(Config.self, from: Data(#"{"lowBatteryAction": "hibernate", "relayEnabled": true}"#.utf8))
        XCTAssertEqual(bad.lowBatteryAction, .pause, "unknown action falls back to the default")
        XCTAssertTrue(bad.relayEnabled, "the rest of the file survives")
        XCTAssertEqual(issues.messages.count, 1)

        // Encodes and round-trips.
        var out = Config()
        out.lowBatteryAction = .off
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(out))
        XCTAssertEqual(back, out)
    }

    func testValidation() {
        var c = Config()
        c.lowBatteryPauseGraceSeconds = 1
        XCTAssertEqual(c.validated().config.lowBatteryPauseGraceSeconds, Config.Limits.lowBatteryPauseGrace.lowerBound)
        c.lowBatteryPauseGraceSeconds = .nan
        XCTAssertEqual(c.validated().config.lowBatteryPauseGraceSeconds, 90)

        c = Config()
        c.recoveryRequiresAC = false
        c.lowBatteryCutoff = 20
        c.recoveryThreshold = 20
        let v = c.validated()
        XCTAssertEqual(v.config.recoveryThreshold, 21, "without AC, recovery must be above the cutoff")
        XCTAssertEqual(v.adjustments.count, 1)
        c.recoveryRequiresAC = true
        XCTAssertTrue(c.validated().adjustments.isEmpty, "equal is fine when recovery needs AC")
    }

    func testPreferencesMergeNewFields() {
        let onDisk = Config()
        let baseline = PreferencesForm(onDisk)
        var form = baseline
        form.keepAwakeLidClosedOnBattery = true
        form.lowBatteryAction = .afterTurn
        form.lowBatteryPauseGraceSeconds = 120
        var fresh = onDisk
        fresh.resumeAfterBatteryRecovery = false   // hand-edited meanwhile
        let merged = form.merged(onto: fresh, changedFrom: baseline)
        XCTAssertTrue(merged.keepAwakeLidClosedOnBattery)
        XCTAssertEqual(merged.lowBatteryAction, .afterTurn)
        XCTAssertEqual(merged.lowBatteryPauseGraceSeconds, 120)
        XCTAssertFalse(merged.resumeAfterBatteryRecovery, "untouched control doesn't clobber a hand edit")
        XCTAssertTrue(merged.keepAwakeLidClosedOnAC)
    }
}

// MARK: - Menu copy

final class PowerMenuTests: XCTestCase {
    private func snapshot(power: PowerSnapshot, awake: AwakeAssertions, lidOnBattery: Bool = false,
                          blocker: String? = nil, phase: BatteryPolicy.Phase = .normal) -> Coordinator.Snapshot {
        Coordinator.Snapshot(
            sessions: [], power: power, awake: awake, lidClosedOnBattery: lidOnBattery,
            lidClosedOnBatteryBlocker: blocker,
            battery: Coordinator.BatteryStatus(phase: phase, paused: [], graceEndsAt: nil, mode: nil),
            activeRateLimit: nil, scheduledResumes: [], pendingInterventions: [],
            relayState: .off, backends: [], configProblem: nil)
    }

    func testAwakeLines() {
        let both = AwakeAssertions(preventIdleSleep: true, preventSystemSleep: true)
        let idle = AwakeAssertions(preventIdleSleep: true, preventSystemSleep: false)
        XCTAssertEqual(AppDelegate.awakeLines(snapshot(power: battery(80, ac: true), awake: both), cutoff: 10),
                       ["Keeping Mac awake — lid can be closed (on AC)"])
        XCTAssertEqual(AppDelegate.awakeLines(snapshot(power: battery(80), awake: idle), cutoff: 10),
                       ["Keeping Mac awake — keep the lid open on battery"])
        XCTAssertEqual(AppDelegate.awakeLines(snapshot(power: battery(80), awake: idle, lidOnBattery: true), cutoff: 10),
                       ["Keeping Mac awake — lid can be closed (on battery, while agents work, down to 10%)"])
        XCTAssertEqual(AppDelegate.awakeLines(snapshot(power: battery(80), awake: idle, blocker: "the Mac is running hot"), cutoff: 10).last,
                       "   Lid-closed on battery is off: the Mac is running hot")
        XCTAssertEqual(AppDelegate.awakeLines(snapshot(power: .noBattery, awake: both), cutoff: 10), ["Keeping Mac awake"])
        XCTAssertEqual(AppDelegate.awakeLines(snapshot(power: battery(80), awake: .none), cutoff: 10), [])
        XCTAssertEqual(AppDelegate.awakeLines(snapshot(power: battery(8), awake: .none, phase: .drained), cutoff: 10),
                       ["Low battery — not keeping the Mac awake (plug in to continue)"])
        XCTAssertTrue(AppDelegate.awakeLines(snapshot(power: battery(9), awake: idle, phase: .grace), cutoff: 10)[0]
            .hasPrefix("Low battery — keeping awake briefly"))
    }

    // PWR-6: a failing clear is surfaced with the manual fix, and the menu
    // never claims the lid can be closed then (isActive is false).
    func testCleanupFailureWarning() {
        let idle = AwakeAssertions(preventIdleSleep: true, preventSystemSleep: false)
        var s = snapshot(power: battery(80), awake: idle)
        s.lidClosedCleanupFailed = true
        let lines = AppDelegate.awakeLines(s, cutoff: 10)
        XCTAssertTrue(lines[0].contains("sudo pmset -a disablesleep 0"), "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("lid can be closed") })
        var off = snapshot(power: battery(80), awake: .none)
        off.lidClosedCleanupFailed = true
        XCTAssertEqual(AppDelegate.awakeLines(off, cutoff: 10).count, 1, "shown even when not keeping awake")
    }

    func testStatusLineAndRuleLine() {
        XCTAssertEqual(snapshot(power: battery(9), awake: .none, phase: .grace).statusLine, "Low battery — agents are pausing")
        XCTAssertEqual(snapshot(power: battery(9), awake: .none, phase: .drained).statusLine, "Low battery — not keeping awake")
        var c = Config()
        XCTAssertEqual(AppDelegate.batteryRuleLine(c), "At 10% on battery: ask agents to pause · resume at 25% on AC")
        c.lowBatteryAction = .off
        c.resumeAfterBatteryRecovery = false
        c.recoveryRequiresAC = false
        XCTAssertEqual(AppDelegate.batteryRuleLine(c), "At 10% on battery: stop keeping awake · recover at 25%")
    }
}
