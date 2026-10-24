import XCTest
@testable import ClaudePowerMode

/// SESSIONS-PROTOCOL.md §5 "Mac input gate": every refusal reason, and the
/// idle-deliver / busy-queue plans, with the registry and terminal faked.
/// Nothing here types into a real terminal.
final class SessionInputGateTests: XCTestCase {
    typealias Gate = SessionInputGate
    private let sid = "6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90"
    private let tmux = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/t", paneId: "%3", inMode: false)
    private let cmuxTarget = CmuxBridge.Target(surfaceId: "5FA66D62-4F2B-4F19-90BE-80319216DE70", workspaceId: nil,
                                               cliPath: "/Applications/cmux.app/Contents/Resources/bin/cmux", source: "environment")

    private func session(status: ClaudeSessionStatus = .idle, hasSessionFile: Bool = true, tty: String? = "ttys003") -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 4242, sessionId: sid, cwd: "/tmp/p", status: status, statusUpdatedAt: nil,
                          tty: tty, hasSessionFile: hasSessionFile)
    }

    /// A fake world: what the registry, ps and the terminal say, and a log
    /// of what was typed.
    private final class World {
        var target: InjectionExecutor.ClaudeTarget = .ended
        var status: String? = "idle"
        var host: InjectionExecutor.TerminalHost = .unknown
        var deliverResult = InjectionResult(method: .tmux, success: true, output: "ok", detail: "Typed into tmux pane %3")
        var foreground: Bool? = true
        /// Answers for the next foreground checks, in order; then `foreground`.
        var foregroundAnswers: [Bool?] = []
        var delivered: [InjectionExecutor.ClaudeReplyRequest] = []
        var interrupts: [InjectionExecutor.TerminalHost] = []
        var interruptResult = InjectionResult(method: .tmux, success: true, output: "ok")

        var io: SessionInputGate.ClaudeIO {
            SessionInputGate.ClaudeIO(
                resolve: { _ in self.target },
                currentRecord: { pid in self.status.map { ClaudeSessionRecord(pid: pid, status: $0) } },
                resolveHost: { _, _ in self.host },
                deliver: { req, _, _ in self.delivered.append(req); return self.deliverResult },
                isForeground: { _ in self.foregroundAnswers.isEmpty ? self.foreground : self.foregroundAnswers.removeFirst() },
                sendInterrupt: { self.interrupts.append($0); return self.interruptResult }
            )
        }
    }

    private func world(_ s: ClaudeLiveSession?, status: String? = "idle", host: InjectionExecutor.TerminalHost? = nil) -> World {
        let w = World()
        if let s { w.target = .live(s, [ProcessRunner.ProcessInfoRow(pid: s.pid, ppid: 1, tty: "ttys003", command: "claude")]) }
        w.status = status
        w.host = host ?? tmux
        return w
    }

    private func input(_ w: World, _ text: String = "run the tests", page: String? = nil) -> SessionCommandResult {
        Gate.runClaudeInput(sessionId: sid, clientId: "c1", text: text, interventionId: page, io: w.io)
    }

    // MARK: Claude refusals (nothing typed)

    func testEndedSession() {
        let w = world(nil)
        XCTAssertEqual(input(w).reason, .ended)
        XCTAssertEqual(input(w).code, .refused)
        XCTAssertTrue(w.delivered.isEmpty)
    }

    func testAmbiguousOrBackgroundTargetIsNotTypable() {
        let w = world(nil)
        w.target = .failed(.init(InjectionExecutor.backgroundJobMessage))
        let r = input(w)
        XCTAssertEqual(r.reason, .notTypable)
        XCTAssertEqual(r.detail, InjectionExecutor.backgroundJobMessage)
        XCTAssertTrue(w.delivered.isEmpty)
    }

    func testNoSessionsFileOrUnknownStatusIsUnknownState() {
        for w in [world(session(hasSessionFile: false)), world(session(), status: "thinking"), world(session(), status: nil)] {
            XCTAssertEqual(input(w).reason, .unknownState)
            XCTAssertTrue(w.delivered.isEmpty)
        }
    }

    func testWaitingRefusesWithTheOpenPage() {
        let w = world(session(), status: "waiting")
        let r = input(w, page: "\(sid)-permission-1761300000")
        XCTAssertEqual(r.reason, .waiting)
        XCTAssertEqual(r.interventionId, "\(sid)-permission-1761300000")
        XCTAssertEqual(r.fields(clientId: "c1")["interventionId"] as? String, "\(sid)-permission-1761300000")
        XCTAssertTrue(w.delivered.isEmpty)
    }

    func testUnsupportedHostsAreNotTypable() {
        for host in [InjectionExecutor.TerminalHost.unsupported("Ghostty"), .unknown, .unreachable(CmuxBridge.paneNotFoundDetail)] {
            let w = world(session(), status: "idle", host: host)
            XCTAssertEqual(input(w).reason, .notTypable, host.label)
            XCTAssertTrue(w.delivered.isEmpty)
        }
    }

    func testDigitFirstWhileBusyIsRefused() {
        for text in ["1", "  2 please", "3. do it"] {
            let w = world(session(), status: "busy")
            let r = input(w, text)
            XCTAssertEqual(r.reason, .digitWhileBusy, text)
            XCTAssertEqual(r.detail, Gate.digitWhileBusyMessage)
            XCTAssertTrue(w.delivered.isEmpty)
        }
        // Idle: a digit is just a message (no menu can be up).
        let idle = world(session(), status: "idle")
        XCTAssertEqual(input(idle, "1").code, .delivered)
    }

    func testEmptyOrOversizedTextIsRefused() {
        let w = world(session(), status: "idle")
        XCTAssertEqual(input(w, "   \n ").code, .refused)
        XCTAssertEqual(input(w, String(repeating: "a", count: 8001)).code, .refused)
        XCTAssertEqual(input(w, String(repeating: "a", count: 8000)).code, .delivered)
        XCTAssertEqual(w.delivered.count, 1)
    }

    // MARK: Claude delivery plans

    func testIdleDeliversThroughTheReplySeamWithAnEmptyInputBox() throws {
        let w = world(session(), status: "idle")
        let r = input(w)
        XCTAssertEqual(r.code, .delivered)
        XCTAssertEqual(r.detail, "Typed into tmux pane %3")
        let req = try XCTUnwrap(w.delivered.first)
        XCTAssertEqual(req.interventionId, "\(sid)-phone-c1")
        XCTAssertEqual(req.sessionId, sid)
        XCTAssertEqual(req.kind, .idle)
        XCTAssertEqual(req.action, "custom")
        XCTAssertEqual(req.text, "run the tests")
        XCTAssertTrue(req.requireEmptyInput, "a half-typed draft is never appended to")
        XCTAssertTrue(req.closedPage, "never Esc, never a prompt answer")
        XCTAssertTrue(req.refuseDigitWhileBusy, "the digit rule is checked again at the text key")
    }

    /// The gate's status read comes before the host lookups and the draft
    /// read; the digit rule is applied again right before the text key.
    func testDigitRuleIsCheckedAgainAtTheTextKey() {
        let refuse = InjectionExecutor.digitWhileBusyRefusal
        XCTAssertEqual(refuse(.text("1 more thing"), .busy, true), Gate.digitWhileBusyMessage)
        XCTAssertEqual(refuse(.text("  2"), .busy, true), Gate.digitWhileBusyMessage)
        XCTAssertNil(refuse(.text("1 more thing"), .idle, true), "idle: no menu can be up")
        XCTAssertNil(refuse(.text("one more thing"), .busy, true))
        XCTAssertNil(refuse(.enter, .busy, true), "the digit is already in the input box")
        XCTAssertNil(refuse(.text("1 more thing"), .busy, false), "inbox replies keep their own rules")
        // An inbox-style request leaves it off.
        let inbox = InjectionExecutor.ClaudeReplyRequest(interventionId: "i", sessionId: sid, action: "custom", text: "1",
                                                         kind: .idle, pagePid: nil, pageStateStart: nil, pagePromptKey: nil,
                                                         hookCreatedAt: nil)
        XCTAssertFalse(inbox.refuseDigitWhileBusy)
    }

    func testBusyQueuesNeverEscapes() throws {
        let w = world(session(), status: "busy", host: .cmux(cmuxTarget))
        let r = input(w, "also fix lint")
        XCTAssertEqual(r.code, .queued)
        XCTAssertEqual(r.detail, Gate.queuedMessage)
        XCTAssertEqual(w.delivered.count, 1)
        XCTAssertTrue(w.interrupts.isEmpty)
        // The plan the reply path makes for it: text + Enter, no Esc.
        let req = try XCTUnwrap(w.delivered.first)
        XCTAssertEqual(InjectionExecutor.plan(action: req.action, kind: req.kind ?? .other, status: .busy, text: req.text),
                       .send([.text("also fix lint"), .enter], summary: "Queued your reply"))
    }

    func testDeliveryFailuresMapToReasons() {
        let cases: [(String, SessionCommandResult.Reason?)] = [
            (CmuxBridge.draftDetail, .draft),
            (InjectionExecutor.inputUnverifiedMessage, .draft),
            (InjectionExecutor.newPageMessage, .waiting),
            (InjectionExecutor.notForegroundMessage, .notTypable),
            (InjectionExecutor.sessionExitedMessage, .ended),
            (Gate.digitWhileBusyMessage, .digitWhileBusy),
            ("Couldn't type into tmux pane %3", .error),
        ]
        for (detail, reason) in cases {
            let w = world(session(), status: "idle")
            w.deliverResult = InjectionResult(method: .tmux, success: false, output: "x", detail: detail)
            let r = input(w)
            XCTAssertEqual(r.reason, reason, detail)
            XCTAssertEqual(r.code, reason == .error ? .failed : .refused, detail)
            XCTAssertEqual(r.detail, detail)
        }
    }

    func testPurePlanTable() {
        XCTAssertEqual(Gate.claudePlan(target: .live, status: .idle, hasSessionFile: true, host: tmux, text: "hi", interventionId: nil),
                       .deliver(queued: false))
        XCTAssertEqual(Gate.claudePlan(target: .live, status: .busy, hasSessionFile: true, host: .terminalApp(tty: "/dev/ttys1"),
                                       text: "hi", interventionId: nil), .deliver(queued: true))
        XCTAssertEqual(Gate.claudePlan(target: .live, status: .busy, hasSessionFile: true, host: .iTerm(tty: "/dev/x"),
                                       text: "9 lives", interventionId: nil),
                       .refuse(.refused(.digitWhileBusy, Gate.digitWhileBusyMessage)))
        XCTAssertEqual(Gate.claudePlan(target: .live, status: .unknown, hasSessionFile: true, host: tmux, text: "hi", interventionId: nil),
                       .refuse(.refused(.unknownState, Gate.unknownStateMessage)))
        XCTAssertEqual(Gate.claudePlan(target: .ended, status: .idle, hasSessionFile: true, host: tmux, text: "hi", interventionId: nil),
                       .refuse(.refused(.ended, Gate.endedMessage)))
    }

    // MARK: Claude interrupt

    func testInterruptOnlyABusySessionInAnEscCapableHost() {
        let busy = world(session(), status: "busy")
        XCTAssertEqual(Gate.runClaudeInterrupt(sessionId: sid, interventionId: nil, io: busy.io).code, .delivered)
        XCTAssertEqual(busy.interrupts, [tmux])

        let idle = world(session(), status: "idle")
        XCTAssertEqual(Gate.runClaudeInterrupt(sessionId: sid, interventionId: nil, io: idle.io).reason, .interruptUnsupported)
        let waiting = world(session(), status: "waiting")
        XCTAssertEqual(Gate.runClaudeInterrupt(sessionId: sid, interventionId: "p", io: waiting.io).reason, .waiting,
                       "Esc on a menu would deny it")
        let terminal = world(session(), status: "busy", host: .terminalApp(tty: "/dev/ttys004"))
        XCTAssertEqual(Gate.runClaudeInterrupt(sessionId: sid, interventionId: nil, io: terminal.io).reason, .interruptUnsupported)
        let suspended = world(session(), status: "busy")
        suspended.foreground = false
        XCTAssertEqual(Gate.runClaudeInterrupt(sessionId: sid, interventionId: nil, io: suspended.io).reason, .notTypable)
        // In front when first checked, behind another job by the time Esc
        // would go out.
        let backgrounded = world(session(), status: "busy")
        backgrounded.foregroundAnswers = [true, false]
        XCTAssertEqual(Gate.runClaudeInterrupt(sessionId: sid, interventionId: nil, io: backgrounded.io).reason, .notTypable)
        for w in [idle, waiting, terminal, suspended, backgrounded] { XCTAssertTrue(w.interrupts.isEmpty) }
        XCTAssertEqual(Gate.runClaudeInterrupt(sessionId: sid, interventionId: nil, io: world(nil).io).reason, .ended)
    }

    // MARK: Codex

    func testCodexPlanTable() {
        let problem = SessionCommandResult.refused(.ended, "Codex isn't open in p any more")
        func plan(_ phase: CodexRollout.Summary.Phase, pending: Bool = false, exec: Bool = false,
                  _ terminal: CodexInjector.Terminal?, problem: SessionCommandResult? = nil) -> SessionInputGate.CodexStep {
            Gate.codexPlan(phase: phase, hasPendingRequest: pending, execResumeRunning: exec, terminal: terminal,
                           targetProblem: problem, interventionId: "codex-idle-x")
        }
        XCTAssertEqual(plan(.completed, .tmux(pane: "%1")), .deliverIdle)
        XCTAssertEqual(plan(.aborted, .cmux(cmuxTarget)), .deliverIdle)
        XCTAssertEqual(plan(.inTurn, .cmux(cmuxTarget)), .queueMidTurn)
        XCTAssertEqual(plan(.inTurn, .tmux(pane: "%1")), .refuse(.refused(.codexMidTurn, Gate.codexMidTurnMessage)))
        XCTAssertEqual(plan(.inTurn, .terminalApp(tty: "/dev/ttys1")), .refuse(.refused(.codexMidTurn, Gate.codexMidTurnMessage)))
        XCTAssertEqual(plan(.inTurn, nil), .refuse(.refused(.codexMidTurn, Gate.codexMidTurnMessage)))
        guard case .refuse(let waiting) = plan(.inTurn, pending: true, .cmux(cmuxTarget)) else { return XCTFail() }
        XCTAssertEqual(waiting.reason, .waiting)
        XCTAssertEqual(waiting.interventionId, "codex-idle-x")
        guard case .refuse(let unknown) = plan(.unknown, .tmux(pane: "%1")) else { return XCTFail() }
        XCTAssertEqual(unknown.reason, .unknownState)
        guard case .refuse(let exec) = plan(.completed, exec: true, .tmux(pane: "%1")) else { return XCTFail() }
        XCTAssertEqual(exec.reason, .notTypable)
        guard case .refuse(let terminal) = plan(.completed, .terminalApp(tty: "/dev/ttys1")) else { return XCTFail() }
        XCTAssertEqual(terminal.reason, .notTypable, "Terminal.app's composer can't be verified empty")
        XCTAssertEqual(plan(.completed, nil, problem: problem), .refuse(problem))
        guard case .refuse(let unavailable) = plan(.completed, .unavailable(CodexInjector.notForegroundDetail)) else { return XCTFail() }
        XCTAssertEqual(unavailable.detail, CodexInjector.notForegroundDetail)
    }

    /// The rollout read again right before the keys.
    func testCodexRecheck() {
        func summary(_ phase: CodexRollout.Summary.Phase, pending: Bool = false) -> CodexRollout.Summary {
            CodexRollout.Summary(phase: phase, pendingRequest: pending ? .approval("call-1") : nil)
        }
        func recheck(_ planned: CodexRollout.Summary.Phase, _ now: CodexRollout.Summary, interrupt: Bool = false) -> SessionCommandResult? {
            Gate.codexRecheck(planned: planned, now: now, interrupt: interrupt, interventionId: "p")
        }
        // Still as planned.
        XCTAssertNil(recheck(.completed, summary(.completed)))
        XCTAssertNil(recheck(.completed, summary(.aborted)), "still between turns")
        XCTAssertNil(recheck(.inTurn, summary(.inTurn)))
        XCTAssertNil(recheck(.inTurn, summary(.inTurn), interrupt: true))
        // A prompt opened since: never typed into, never Esc'd.
        for (planned, interrupt) in [(CodexRollout.Summary.Phase.completed, false), (.inTurn, false), (.inTurn, true)] {
            let r = recheck(planned, summary(planned, pending: true), interrupt: interrupt)
            XCTAssertEqual(r?.reason, .waiting)
            XCTAssertEqual(r?.interventionId, "p")
        }
        // A turn started (text) or ended (Stop) since.
        XCTAssertEqual(recheck(.completed, summary(.inTurn))?.reason, .codexMidTurn)
        XCTAssertEqual(recheck(.completed, summary(.unknown))?.reason, .unknownState)
        XCTAssertEqual(recheck(.inTurn, summary(.completed))?.reason, .unknownState)
        XCTAssertEqual(recheck(.inTurn, summary(.completed), interrupt: true),
                       .refused(.interruptUnsupported, Gate.notIdleMessage))
        XCTAssertEqual(recheck(.inTurn, summary(.unknown), interrupt: true)?.reason, .interruptUnsupported)
    }

    func testCodexTargetProblems() {
        XCTAssertNil(Gate.codexTargetProblem(.tty("/dev/ttys1", pid: 1), project: "p"))
        XCTAssertEqual(Gate.codexTargetProblem(.none, project: "p")?.reason, .ended)
        for t in [CodexInjector.Target.ambiguous(count: 2), .noTerminal, .unconfirmed] {
            XCTAssertEqual(Gate.codexTargetProblem(t, project: "p")?.reason, .notTypable)
        }
    }

    func testCodexResults() {
        XCTAssertEqual(Gate.codexResult(CodexDeliveryOutcome(method: "tmux", success: true, detail: "Typed into tmux pane %1", output: nil),
                                        queued: false, interventionId: nil),
                       SessionCommandResult(code: .delivered, reason: nil, detail: "Typed into tmux pane %1"))
        XCTAssertEqual(Gate.codexResult(CodexDeliveryOutcome(method: "cmux", success: true, detail: "Typed into cmux pane", output: nil),
                                        queued: true, interventionId: nil).code, .queued)
        XCTAssertEqual(Gate.codexResult(.failure(CmuxBridge.draftDetail), queued: false, interventionId: nil).reason, .draft)
        XCTAssertEqual(Gate.codexResult(.failure(CodexInjector.composerUnverifiedDetail), queued: false, interventionId: nil).reason, .draft)
        XCTAssertEqual(Gate.codexResult(.failure(CmuxBridge.dialogOpenDetail), queued: true, interventionId: "p").reason, .waiting)
        XCTAssertEqual(Gate.codexResult(.failure(CmuxBridge.noInputBoxDetail), queued: true, interventionId: nil).reason, .codexMidTurn)
        XCTAssertEqual(Gate.codexResult(.failure("boom"), queued: false, interventionId: nil).code, .failed)
    }

    // MARK: result fields

    func testResultFieldsAreBoundedAndOmitEmptyOptionals() {
        let long = String(repeating: "x", count: 500)
        let f = SessionCommandResult.failed(long).fields(clientId: "c9")
        XCTAssertEqual(f["kind"] as? String, "result")
        XCTAssertEqual(f["clientId"] as? String, "c9")
        XCTAssertEqual(f["ok"] as? Bool, false)
        XCTAssertEqual(f["code"] as? String, "failed")
        XCTAssertEqual(f["reason"] as? String, "error")
        XCTAssertEqual((f["detail"] as? String)?.count, 200)
        XCTAssertNil(f["interventionId"])
        let ok = SessionCommandResult(code: .queued, reason: nil, detail: "Queued").fields(clientId: "c")
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertNil(ok["reason"])
        // interventionId only accompanies `waiting`.
        XCTAssertNil(SessionCommandResult.refused(.draft, "d", interventionId: "p").fields(clientId: "c")["interventionId"])
    }
}
