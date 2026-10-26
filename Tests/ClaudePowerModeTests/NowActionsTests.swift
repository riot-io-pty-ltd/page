import XCTest
@testable import ClaudePowerMode

/// The Now panel's keyboard reducer, press-and-hold gestures, the reply gate,
/// delivery results and receipts. Keystroke truth: approve types 1, deny
/// presses Esc, a written reply is Esc, text, Return, and nothing sends "2".
final class NowActionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_761_300_000)

    private func ev(_ id: String, kind: InterventionKind = .permission, context: String, subtype: String? = nil,
                    backend: AgentBackendID = .claude, openedAgo: TimeInterval = 60) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: "sess-x", cwd: "/Users/roy/projects/x", projectName: "x", kind: kind,
                          openedAt: now.addingTimeInterval(-openedAgo), context: context, transcriptPath: "",
                          backend: backend, source: .terminal, subtype: subtype)
    }

    private func row(_ e: InterventionEvent) -> DecideRow {
        NowModel.row(for: e, macName: "Studio MBP", route: "cmux › x")!
    }

    /// irreversible, undoable, considered, question, stuck look, forecast.
    private var rows: [DecideRow] {
        [
            row(ev("i-1", context: "[Bash] rm -rf Builds/Dev/*.app\nDelete the dev builds")),
            row(ev("u-1", context: "[Bash] swift test\nRun the tests")),
            row(ev("c-1", context: "[Edit] Sources/Foo.swift\n- a\n+ b")),
            row(ev("q-1", kind: .question, context: "Which file?")),
            row(ev("l-1", kind: .idle, context: "Looks stuck in a loop: this has failed 6 times.\ncargo test", subtype: "looping")),
            row(ev("page-mac-battery_forecast-1", kind: .idle, context: "Battery forecast.")),
        ]
    }

    private func key(_ k: NowKeyPress.Key, cmd: Bool = false, repeating: Bool = false,
                     phase: NowKeyPress.Phase = .down) -> NowKeyPress {
        NowKeyPress(key: k, phase: phase, command: cmd, option: false, control: false, isRepeat: repeating)
    }

    private func state(selected: String? = nil, hold: HoldGesture? = nil, composer: NowPanelState.Composer? = nil,
                       expanded: Bool = false) -> NowPanelState {
        var s = NowPanelState()
        s.selectedId = selected
        s.hold = hold
        s.composer = composer
        s.expanded = expanded
        return s
    }

    private func handle(_ k: NowKeyPress, _ s: NowPanelState, rows: [DecideRow]? = nil) -> (state: NowPanelState, effect: NowEffect) {
        NowKeys.handle(k, state: s, rows: rows ?? self.rows, now: now)
    }

    // MARK: nothing selected

    func testWithNothingSelectedOnlyEscapeDoesAnything() {
        XCTAssertEqual(handle(key(.esc), state()).effect, .close)
        XCTAssertEqual(handle(key(.char("1")), state()).effect, .none)
        XCTAssertEqual(handle(key(.ret), state()).effect, .none)
        XCTAssertEqual(handle(key(.char("t")), state()).effect, .none)
        XCTAssertEqual(handle(key(.char("o")), state()).effect, .none)
    }

    // MARK: moving

    func testDownWithNothingSelectedSelectsTheFirstRow() {
        XCTAssertEqual(handle(key(.down), state()).state.selectedId, "i-1")
    }

    func testUpWithNothingSelectedSelectsTheLastRow() {
        XCTAssertEqual(handle(key(.up), state()).state.selectedId, "page-mac-battery_forecast-1")
    }

    func testSelectionClampsAtTheEndsAndDoesNotWrap() {
        XCTAssertEqual(handle(key(.up), state(selected: "i-1")).state.selectedId, "i-1")
        let last = "page-mac-battery_forecast-1"
        XCTAssertEqual(handle(key(.down), state(selected: last)).state.selectedId, last)
    }

    func testMovingPastTheCompactListExpandsIt() {
        XCTAssertFalse(handle(key(.down), state(selected: "i-1")).state.expanded)
        XCTAssertTrue(handle(key(.down), state(selected: "c-1")).state.expanded, "row index 3 is past the first three")
    }

    func testMovingCancelsAHold() {
        let hold = HoldGesture(kind: .stopAll, startedAt: now)
        XCTAssertNil(handle(key(.down), state(selected: "i-1", hold: hold)).state.hold)
    }

    // MARK: Return

    func testReturnOnIrreversibleOpensTheTerminalAndNeverApproves() {
        let r = handle(key(.ret), state(selected: "i-1"))
        XCTAssertEqual(r.effect, .openTerminal(rowId: "i-1"))
        XCTAssertEqual(r.state.selectedId, "i-1", "opening the terminal keeps the row selected")
    }

    func testReturnOnUndoableApprovesAndClearsTheSelection() {
        let r = handle(key(.ret), state(selected: "u-1"))
        XCTAssertEqual(r.effect, .approve(rowId: "u-1"))
        XCTAssertNil(r.state.selectedId)
    }

    func testReturnOnConsideredOrQuestionDoesNothing() {
        XCTAssertEqual(handle(key(.ret), state(selected: "c-1")).effect, .none)
        XCTAssertEqual(handle(key(.ret), state(selected: "q-1")).effect, .none)
        XCTAssertEqual(handle(key(.ret), state(selected: "l-1")).effect, .none)
    }

    func testRepeatedReturnIsIgnored() {
        XCTAssertEqual(handle(key(.ret, repeating: true), state(selected: "u-1")).effect, .none)
    }

    // MARK: 1

    func testOneApprovesUndoableAndConsideredRows() {
        XCTAssertEqual(handle(key(.char("1")), state(selected: "u-1")).effect, .approve(rowId: "u-1"))
        XCTAssertEqual(handle(key(.char("1")), state(selected: "c-1")).effect, .approve(rowId: "c-1"))
    }

    func testOneOnAQuestionOrStuckRowDoesNothing() {
        XCTAssertEqual(handle(key(.char("1")), state(selected: "q-1")).effect, .none)
        XCTAssertEqual(handle(key(.char("1")), state(selected: "l-1")).effect, .none)
    }

    func testOneOnIrreversibleOnlyStartsAHold() {
        let r = handle(key(.char("1")), state(selected: "i-1"))
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state.hold, HoldGesture(kind: .approve(rowId: "i-1"), startedAt: now))
    }

    func testHeldOneCompletesAfterTheHoldTime() {
        let held = handle(key(.char("1")), state(selected: "i-1")).state
        XCTAssertEqual(NowKeys.tick(state: held, now: now.addingTimeInterval(0.6)).effect, .none, "not yet")
        XCTAssertNotNil(NowKeys.tick(state: held, now: now.addingTimeInterval(0.6)).state.hold)
        let done = NowKeys.tick(state: held, now: now.addingTimeInterval(1.2))
        XCTAssertEqual(done.effect, .approveAfterAuth(rowId: "i-1"))
        XCTAssertNil(done.state.hold)
        XCTAssertNil(done.state.selectedId)
    }

    func testReleasingOneEndsAnUnfinishedApproveHold() {
        let held = handle(key(.char("1")), state(selected: "i-1")).state
        let released = handle(key(.char("1"), phase: .up), held)
        XCTAssertNil(released.state.hold)
        XCTAssertEqual(released.effect, .none)
    }

    func testRepeatedOneDoesNotStartAHold() {
        XCTAssertNil(handle(key(.char("1"), repeating: true), state(selected: "i-1")).state.hold)
    }

    // MARK: Esc

    func testEscDeniesARowThatOffersDeny() {
        let r = handle(key(.esc), state(selected: "u-1"))
        XCTAssertEqual(r.effect, .deny(rowId: "u-1"))
        XCTAssertNil(r.state.selectedId)
        XCTAssertEqual(handle(key(.esc), state(selected: "q-1")).effect, .deny(rowId: "q-1"), "a question's Esc dismisses it")
    }

    func testEscOnARowWithoutDenyLetsGoOfIt() {
        let r = handle(key(.esc), state(selected: "l-1"))
        XCTAssertEqual(r.effect, .none, "a stuck agent has nothing to deny")
        XCTAssertNil(r.state.selectedId)
    }

    func testEscCancelsAHoldFirst() {
        let hold = HoldGesture(kind: .stopAll, startedAt: now)
        let r = handle(key(.esc), state(selected: "u-1", hold: hold))
        XCTAssertNil(r.state.hold)
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state.selectedId, "u-1")
    }

    func testRepeatedEscDoesNotDenyAgain() {
        XCTAssertEqual(handle(key(.esc, repeating: true), state(selected: "u-1")).effect, .none)
    }

    // MARK: T and the composer

    func testTellOpensTheComposerOnlyWhenTheRowOffersIt() {
        let stuck = handle(key(.char("t")), state(selected: "l-1")).state
        XCTAssertEqual(stuck.composer?.rowId, "l-1")
        XCTAssertEqual(handle(key(.char("t")), state(selected: "u-1")).state.composer?.rowId, "u-1")
        XCTAssertNil(handle(key(.char("t")), state(selected: "page-mac-battery_forecast-1")).state.composer)
        XCTAssertNil(handle(key(.char("t")), state()).state.composer)
    }

    func testTellIsNotOfferedOnACodexRow() {
        let codex = [row(ev("cx-1", context: "[Bash] ls", backend: .codex))]
        XCTAssertNil(handle(key(.char("t")), state(selected: "cx-1"), rows: codex).state.composer)
    }

    func testComposerOwnsTheKeyboard() {
        let open = state(selected: "u-1", composer: NowPanelState.Composer(rowId: "u-1", text: ""))
        let typed = handle(key(.char("1")), open)
        XCTAssertEqual(typed.effect, .none, "a typed 1 is text, not an approval")
        XCTAssertNotNil(typed.state.composer)
        XCTAssertEqual(handle(key(.esc), open).state.composer, nil)
        XCTAssertEqual(handle(key(.esc), open).effect, .none, "Esc closes the composer, it does not deny")
    }

    func testComposerSendsTrimmedTextThenClears() {
        let open = state(selected: "u-1", composer: NowPanelState.Composer(rowId: "u-1", text: "  ship it  "))
        let r = handle(key(.ret), open)
        XCTAssertEqual(r.effect, .send(rowId: "u-1", text: "ship it"))
        XCTAssertNil(r.state.composer)
        XCTAssertNil(r.state.selectedId)
    }

    func testEmptyComposerDoesNotSend() {
        let blank = state(selected: "u-1", composer: NowPanelState.Composer(rowId: "u-1", text: "   "))
        let r = handle(key(.ret), blank)
        XCTAssertEqual(r.effect, .none)
        XCTAssertNotNil(r.state.composer)
        XCTAssertEqual(handle(key(.ret, repeating: true), NowPanelState(selectedId: "u-1", expanded: false, composer: NowPanelState.Composer(rowId: "u-1", text: "hi"), hold: nil)).effect, .none)
    }

    // MARK: O

    func testOpensTheTerminalOnlyWhenOffered() {
        XCTAssertEqual(handle(key(.char("o")), state(selected: "i-1")).effect, .openTerminal(rowId: "i-1"))
        XCTAssertEqual(handle(key(.char("o")), state(selected: "page-mac-battery_forecast-1")).effect, .none)
        XCTAssertEqual(handle(key(.char("o"), repeating: true), state(selected: "i-1")).effect, .none)
    }

    // MARK: Command keys

    func testCommandNStartsANewSession() {
        XCTAssertEqual(handle(key(.char("n"), cmd: true), state()).effect, .newSession)
        XCTAssertEqual(handle(key(.char("n"), cmd: true, repeating: true), state()).effect, .none)
    }

    func testCommandPeriodStartsAStopHoldNotAnEsc() {
        let r = handle(key(.char("."), cmd: true), state(selected: "u-1"))
        XCTAssertEqual(r.effect, .none)
        XCTAssertEqual(r.state.hold?.kind, .stopAll)
        XCTAssertEqual(r.state.hold?.startedAt, now)
        XCTAssertEqual(r.state.selectedId, "u-1", "Command-period must not deny the selected row")
    }

    func testReleasingPeriodEndsAStopHold() {
        let held = handle(key(.char("."), cmd: true), state()).state
        let released = handle(key(.char("."), phase: .up), held)
        XCTAssertNil(released.state.hold)
    }

    func testOtherCommandCombinationsDoNothing() {
        XCTAssertEqual(handle(key(.char("x"), cmd: true), state(selected: "u-1")).effect, .none)
        let r = handle(key(.char("1"), cmd: true), state(selected: "i-1"))
        XCTAssertEqual(r.effect, .none)
        XCTAssertNil(r.state.hold, "Command-1 never starts an approval hold")
    }

    func testStopHoldIsNotStartedTwice() {
        let first = handle(key(.char("."), cmd: true), state()).state
        let again = handle(key(.char("."), cmd: true, repeating: true), first)
        XCTAssertEqual(again.state.hold?.startedAt, now)
    }

    // MARK: no key sends 2

    func testNoKeyOrClickSendsTwo() {
        var states = [state(), state(selected: "i-1"), state(selected: "u-1"), state(selected: "c-1"), state(selected: "q-1"), state(selected: "l-1")]
        states.append(state(selected: "u-1", composer: NowPanelState.Composer(rowId: "u-1", text: "")))
        for s in states {
            XCTAssertEqual(handle(key(.char("2")), s).effect, .none)
            XCTAssertEqual(handle(key(.char("2"), cmd: true), s).effect, .none)
        }
    }

    // MARK: reconcile

    func testReconcileDropsAVanishedSelectionWithoutMovingIt() {
        var s = state(selected: "u-1")
        s = NowKeys.reconcile(s, rows: rows.filter { $0.id != "u-1" })
        XCTAssertNil(s.selectedId, "never moved to a neighbour")
    }

    func testReconcileClosesComposerAndHoldForVanishedRows() {
        let s = state(selected: "u-1", hold: HoldGesture(kind: .approve(rowId: "i-1"), startedAt: now),
                      composer: NowPanelState.Composer(rowId: "c-1", text: "x"))
        let r = NowKeys.reconcile(s, rows: rows.filter { !["i-1", "c-1"].contains($0.id) })
        XCTAssertNil(r.hold)
        XCTAssertNil(r.composer)
    }

    func testReconcileKeepsAStopHoldAndExpandedOnlyWhenThereAreMoreRowsThanTheCompactList() {
        let stop = HoldGesture(kind: .stopAll, startedAt: now)
        XCTAssertEqual(NowKeys.reconcile(state(hold: stop, expanded: true), rows: rows).hold, stop)
        XCTAssertTrue(NowKeys.reconcile(state(expanded: true), rows: rows).expanded)
        XCTAssertFalse(NowKeys.reconcile(state(expanded: true), rows: Array(rows.prefix(3))).expanded)
    }

    // MARK: tick

    func testStopAllCompletesToStopAll() {
        let hold = HoldGesture(kind: .stopAll, startedAt: now)
        XCTAssertEqual(NowKeys.tick(state: state(hold: hold), now: now.addingTimeInterval(1.0)).effect, .none)
        let done = NowKeys.tick(state: state(hold: hold), now: now.addingTimeInterval(1.5))
        XCTAssertEqual(done.effect, .stopAll)
        XCTAssertNil(done.state.hold)
    }

    // MARK: clicks

    func testClickOnlyDoesWhatTheRowOffers() {
        let undo = rows[1], irr = rows[0], codex = row(ev("cx-1", context: "[Bash] ls", backend: .codex))
        XCTAssertEqual(NowKeys.effect(forClickOn: .approve, row: undo), .approve(rowId: "u-1"))
        XCTAssertEqual(NowKeys.effect(forClickOn: .deny, row: undo), .deny(rowId: "u-1"))
        XCTAssertEqual(NowKeys.effect(forClickOn: .openTerminal, row: irr), .openTerminal(rowId: "i-1"))
        XCTAssertEqual(NowKeys.effect(forClickOn: .approve, row: irr), .none, "an irreversible row has no plain approve")
        XCTAssertEqual(NowKeys.effect(forClickOn: .approveHold, row: irr), .none, "a click is not a hold")
        XCTAssertEqual(NowKeys.effect(forClickOn: .tellInstead, row: rows[4]), .none, "the store opens the composer")
        XCTAssertEqual(NowKeys.effect(forClickOn: .approve, row: codex), .none)
        XCTAssertEqual(NowKeys.effect(forClickOn: .deny, row: codex), .none)
    }

    // MARK: hold gestures

    func testApproveHoldTimings() {
        let h = HoldGesture(kind: .approve(rowId: "i-1"), startedAt: now)
        XCTAssertEqual(h.duration, 1.2, accuracy: 1e-9)
        XCTAssertEqual(h.deadZone, 0)
        XCTAssertEqual(h.progress(now: now.addingTimeInterval(0.6)), 0.5, accuracy: 1e-5)
        XCTAssertFalse(h.isComplete(now: now.addingTimeInterval(1.19)))
        XCTAssertTrue(h.isComplete(now: now.addingTimeInterval(1.2)))
    }

    func testStopHoldHasADeadZone() {
        let h = HoldGesture(kind: .stopAll, startedAt: now)
        XCTAssertEqual(h.progress(now: now.addingTimeInterval(0.2)), 0)
        XCTAssertEqual(h.progress(now: now.addingTimeInterval(0.9)), 0.5, accuracy: 1e-5)
        XCTAssertFalse(h.isComplete(now: now.addingTimeInterval(1.49)))
        XCTAssertTrue(h.isComplete(now: now.addingTimeInterval(1.5)))
    }

    func testProgressIsClampedAndRedOnlyInTheLastThird() {
        let h = HoldGesture(kind: .approve(rowId: "i-1"), startedAt: now)
        XCTAssertEqual(h.progress(now: now.addingTimeInterval(-5)), 0)
        XCTAssertEqual(h.progress(now: now.addingTimeInterval(50)), 1)
        XCTAssertTrue(HoldGesture.isRed(progress: 2.0 / 3.0))
        XCTAssertTrue(HoldGesture.isRed(progress: 1))
        XCTAssertFalse(HoldGesture.isRed(progress: 0.5))
    }

    // MARK: stop all

    func testStopScopeDescribesTheBusySessions() {
        XCTAssertEqual(StopScope.describe(working: 0), "No agents are working")
        XCTAssertEqual(StopScope.describe(working: 1), "Press Esc in 1 busy session")
        XCTAssertEqual(StopScope.describe(working: 4), "Press Esc in 4 busy sessions")
    }

    func testStopScopeResultLine() {
        XCTAssertEqual(StopScope.resultLine(detail: "  Stopped 4 agents  ", success: true), "Stopped 4 agents")
        XCTAssertEqual(StopScope.resultLine(detail: "", success: true), "Stopped your agents")
        XCTAssertEqual(StopScope.resultLine(detail: "   ", success: false), "Couldn't stop your agents")
        XCTAssertEqual(StopScope.resultLine(detail: "Nothing to stop", success: false), "Nothing to stop")
    }

    // MARK: reply gate

    func testOnlyApproveDenyAndCustomAreSent() {
        XCTAssertNil(MacReplyGate.refusal(forPageId: "sess-a-permission-1", action: "approve"))
        XCTAssertNil(MacReplyGate.refusal(forPageId: "sess-a-permission-1", action: "deny"))
        XCTAssertNil(MacReplyGate.refusal(forPageId: "sess-a-permission-1", action: "custom"))
        for action in ["2", "approve_always", "carry_on", ""] {
            XCTAssertEqual(MacReplyGate.refusal(forPageId: "sess-a-permission-1", action: action),
                           "Page only sends approve, deny or a written reply", action)
        }
    }

    func testHookPagesAndForecastsAreRefused() {
        XCTAssertNotNil(MacReplyGate.refusal(forPageId: "hookpre-1", action: "approve"))
        XCTAssertEqual(MacReplyGate.refusal(forPageId: "page-mac-battery_forecast-1", action: "approve"), "Nothing to answer here")
        XCTAssertEqual(MacReplyGate.refusal(forPageId: "page-mac-usage_forecast-1", action: "deny"), "Nothing to answer here")
        XCTAssertEqual(MacReplyGate.refusal(forPageId: "page-mac-low_battery-1", action: "approve"), "Nothing to answer here")
        XCTAssertEqual(MacReplyGate.refusal(forPageId: "ratelimit-sess-1", action: "custom"), "Nothing to answer here")
    }

    func testAnswerabilityMatchesApprove() {
        XCTAssertTrue(MacReplyGate.isAnswerable(pageId: "sess-a-permission-1"))
        XCTAssertFalse(MacReplyGate.isAnswerable(pageId: "hookpre-1"))
        XCTAssertFalse(MacReplyGate.isAnswerable(pageId: "ratelimit-x"))
    }

    // MARK: delivery results

    private func finished(_ detail: String, success: Bool = false, method: String = "keystroke") -> ReplyFinished {
        ReplyFinished(interventionId: "p", success: success, method: method, detail: detail)
    }

    func testTimeoutIsTimedOut() {
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("Didn't confirm in time", method: "timeout")), .timedOut)
    }

    func testSuccessIsDeliveredUnlessQueued() {
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("Typed into tmux pane %3", success: true)), .delivered)
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("", success: true)), .delivered)
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("Queued behind this turn", success: true)), .queued)
    }

    func testSessionEndedIsSessionEnded() {
        for text in ["The session ended", "the session has ended", "Looks like the session exited"] {
            XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished(text)), .sessionEnded, text)
        }
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("the session exited")), .sessionEnded)
    }

    func testAnsweredAtTheMac() {
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished(InjectionExecutor.promptGoneMessage)), .answeredAtMac)
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("That page already closed")), .answeredAtMac)
    }

    func testPromptClosedAndDigitAreTheSameOutcome() {
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("The prompt closed before the key")), .promptClosed)
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("Can't type a digit here")), .promptClosed)
    }

    func testNewerOrUnknownPromptIsUnknownState() {
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished(InjectionExecutor.staleMessage)), .unknownState)
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished(InjectionExecutor.newPageMessage)), .unknownState)
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("Can't confirm which prompt is open")), .unknownState)
    }

    func testNotTypableOutcomes() {
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished(InjectionExecutor.notForegroundMessage)), .notTypable)
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("This session isn't running in a terminal Page can type into")), .notTypable)
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("Please reply at the Mac")), .notTypable)
    }

    func testAnythingElseKeepsTheBackendsOwnWordsTrimmed() {
        XCTAssertEqual(ReplyOutcomeMapper.outcome(for: finished("  Something odd happened  ")), .other("Something odd happened"))
    }

    func testFailureSentencesMatchTheTrustModel() {
        XCTAssertEqual(DeliveryReceipt.Outcome.timedOut.failureMessage, "Didn't confirm in time · Check on Mac")
        XCTAssertEqual(DeliveryReceipt.Outcome.sessionEnded.failureMessage, "Session ended")
        XCTAssertEqual(DeliveryReceipt.Outcome.notTypable.failureMessage, "This terminal can't take input · Open on Mac")
        XCTAssertEqual(DeliveryReceipt.Outcome.queued.failureMessage, "Queued after this turn")
        XCTAssertEqual(DeliveryReceipt.Outcome.promptClosed.failureMessage, "Prompt closed before your answer")
        XCTAssertEqual(DeliveryReceipt.Outcome.answeredAtMac.failureMessage, "Already answered at the Mac")
        XCTAssertEqual(DeliveryReceipt.Outcome.unknownState.failureMessage, "Review again")
        XCTAssertEqual(DeliveryReceipt.Outcome.other("").failureMessage, "Couldn't deliver the reply")
        XCTAssertEqual(DeliveryReceipt.Outcome.other("Pane gone").failureMessage, "Pane gone")
        XCTAssertNil(DeliveryReceipt.Outcome.delivered.failureMessage)
    }

    // MARK: receipts

    func testVerbsFollowTheAction() {
        XCTAssertEqual(ReceiptFactory.verb(forAction: "approve"), .approved)
        XCTAssertEqual(ReceiptFactory.verb(forAction: "deny"), .denied)
        XCTAssertEqual(ReceiptFactory.verb(forAction: "custom"), .replied)
        XCTAssertEqual(ReceiptFactory.verb(forAction: "approve_always"), .replied)
    }

    func testReceiptNamesTheRouteOrTheProject() {
        let r = row(ev("u-9", context: "[Bash] npm test\nRun the tests"))
        let delivered = ReceiptFactory.receipt(action: "approve", row: r, route: "cmux › page",
                                               finished: finished("", success: true), at: now)
        XCTAssertEqual(delivered.verb, .approved)
        XCTAssertEqual(delivered.subject, "npm test")
        XCTAssertEqual(delivered.route, "cmux › page")
        XCTAssertEqual(delivered.outcome, .delivered)
        let noRoute = ReceiptFactory.receipt(action: "deny", row: r, route: nil, finished: finished("x"), at: now)
        XCTAssertEqual(noRoute.route, "x")
        XCTAssertEqual(noRoute.verb, .denied)
    }

    func testSubjectIsTheSummaryOrTheProjectAndIsCapped() {
        let r = row(ev("u-10", context: "[Bash] npm test\nRun the tests"))
        XCTAssertEqual(ReceiptFactory.subject(for: r), "npm test")
        let long = row(ev("u-11", context: "[Bash] " + String(repeating: "a", count: 80)))
        let s = ReceiptFactory.subject(for: long)
        XCTAssertEqual(s.count, 48)
        XCTAssertTrue(s.hasSuffix("…"))
        let empty = DecideRow(id: "e", sessionId: "s", projectName: "page", backend: .claude, section: .look, chip: .looksStuck,
                              summary: "  ", keys: [], moreKeys: [], returnAction: nil, approvePreview: nil, denyPreview: nil,
                              tellPreview: nil, waitingSince: now, reversibility: nil, tags: [], reason: "")
        XCTAssertEqual(ReceiptFactory.subject(for: empty), "page")
    }

    // MARK: dusk: did the summary land?

    func testPauseEvidenceNeedsAnAssistantRecordAfterThePause() {
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let assistant = "{\"type\":\"assistant\",\"timestamp\":\"\(stamp)\",\"message\":{\"role\":\"assistant\"}}"
        XCTAssertTrue(PauseEvidence.hasSummary(transcriptTail: assistant, after: now))
        XCTAssertFalse(PauseEvidence.hasSummary(transcriptTail: assistant, after: now.addingTimeInterval(3600)))
        XCTAssertFalse(PauseEvidence.hasSummary(transcriptTail: "", after: now))
        let roleOnly = "{\"timestamp\":\"\(stamp)\",\"message\":{\"role\":\"assistant\"}}"
        XCTAssertTrue(PauseEvidence.hasSummary(transcriptTail: roleOnly, after: now), "message.role counts too")
    }

    func testPauseEvidenceIgnoresUsersBadLinesAndTheEdgeOfTheTail() {
        let laterIso = ISO8601DateFormatter().string(from: now.addingTimeInterval(60))
        let user = "{\"type\":\"user\",\"timestamp\":\"\(laterIso)\"}"
        XCTAssertFalse(PauseEvidence.hasSummary(transcriptTail: user, after: now))
        let cutOff = "ssistant\",\"timestamp\":\"\(laterIso)\"}"
        XCTAssertFalse(PauseEvidence.hasSummary(transcriptTail: cutOff, after: now), "a first line cut mid-record")
        let garbage = "not json \"assistant\""
        XCTAssertFalse(PauseEvidence.hasSummary(transcriptTail: garbage, after: now))
        let atTheMoment = "{\"type\":\"assistant\",\"timestamp\":\"\(ISO8601DateFormatter().string(from: now))\"}"
        XCTAssertFalse(PauseEvidence.hasSummary(transcriptTail: atTheMoment, after: now), "at or before the pause does not count")
    }

    // MARK: keyboard translation

    func testKeyCodesTranslateToKeys() {
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 126, characters: nil), .up)
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 125, characters: nil), .down)
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 36, characters: "\r"), .ret)
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 76, characters: "\r"), .ret)
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 53, characters: "\u{1B}"), .esc)
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 47, characters: "."), .char("."))
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 47, characters: nil), .char("."), "no characters: the key code")
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 45, characters: "n"), .char("n"))
        // Dvorak: the key labelled N sits where QWERTY has L, and the key at QWERTY's period types E.
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 37, characters: "n"), .char("n"), "the key labelled N, whatever its code")
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 47, characters: "e"), .char("e"), "not period, just because of its code")
        XCTAssertEqual(NowKeyTranslator.key(keyCode: 0, characters: "A"), .char("a"))
        XCTAssertNil(NowKeyTranslator.key(keyCode: 0, characters: nil))
        XCTAssertNil(NowKeyTranslator.key(keyCode: 0, characters: ""))
    }

    func testCommandCommaOpensPreferencesAndMOpensMore() {
        XCTAssertEqual(handle(key(.char(","), cmd: true), state()).effect, .preferences)
        XCTAssertEqual(handle(key(.char("m")), state()).effect, .more)
    }

    func testStoreLeavesOtherCommandKeysToTheResponders() {
        let store = NowStore(model: NowModel.starting(macName: "Mac"))
        XCTAssertFalse(store.handle(NowKeyPress(key: .char("q"), command: true)), "⌘Q is not ours")
        XCTAssertFalse(store.handle(NowKeyPress(key: .char("c"), command: true)))
        XCTAssertTrue(store.handle(NowKeyPress(key: .char("n"), command: true)))
        XCTAssertTrue(store.handle(NowKeyPress(key: .char(","), command: true)))
    }
}
