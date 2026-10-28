import XCTest
@testable import ClaudePowerMode

/// The input gate for a held message (`hold-v1`): only into an idle session,
/// never queued behind a turn or typed into a prompt, and only if the
/// typing/delete switch is still the delivery's right before the keys.
final class SessionHeldGateTests: XCTestCase {
    typealias Gate = SessionInputGate
    private let sid = "6f1f2b2e-6a54-4b52-9d2c-3f1f7d7b8a90"

    private final class World {
        var status: String? = "idle"
        var delivered: [InjectionExecutor.ClaudeReplyRequest] = []
        var deliverResult = InjectionResult(method: .tmux, success: true, output: "ok", detail: "Typed into tmux pane %3")
        let session: ClaudeLiveSession

        init(sid: String) {
            session = ClaudeLiveSession(pid: 4242, sessionId: sid, cwd: "/tmp/p", status: .idle, statusUpdatedAt: nil,
                                        tty: "ttys003", hasSessionFile: true)
        }

        var io: SessionInputGate.ClaudeIO {
            SessionInputGate.ClaudeIO(
                resolve: { _ in .live(self.session, []) },
                currentRecord: { pid in self.status.map { ClaudeSessionRecord(pid: pid, status: $0) } },
                resolveHost: { _, _ in .tmux(tmuxPath: "/t", paneId: "%3", inMode: false) },
                deliver: { req, _, _ in self.delivered.append(req); return self.deliverResult },
                isForeground: { _ in true },
                sendInterrupt: { _ in InjectionResult(method: .tmux, success: true, output: "ok") }
            )
        }
    }

    private func held(_ w: World, claim: HeldClaim, text: String = "then lint") -> SessionCommandResult {
        Gate.runClaudeInput(sessionId: sid, clientId: "c1", text: text, interventionId: nil, io: w.io, held: claim)
    }

    func testIdleIsTypedAfterTheSwitchGoesToTheDelivery() throws {
        let w = World(sid: sid)
        let claim = HeldClaim()
        let r = held(w, claim: claim)
        XCTAssertEqual(r.code, .delivered)
        XCTAssertEqual(claim.state, .committed)
        let req = try XCTUnwrap(w.delivered.first)
        XCTAssertTrue(req.refuseWhileBusy, "and refused before every key once Claude is busy")
        XCTAssertTrue(req.requireEmptyInput)
        XCTAssertTrue(req.closedPage, "never a prompt answer")
    }

    func testBusyIsRefusedNeverQueued() {
        let w = World(sid: sid)
        w.status = "busy"
        let claim = HeldClaim()
        let r = held(w, claim: claim)
        XCTAssertEqual(r.reason, .busy)
        XCTAssertTrue(w.delivered.isEmpty)
        XCTAssertEqual(claim.state, .open, "nothing was about to be typed: a delete still wins")
        // Without hold, the same busy session queues the text, as before.
        XCTAssertEqual(Gate.runClaudeInput(sessionId: sid, clientId: "c2", text: "x", interventionId: nil, io: w.io).code, .queued)
    }

    func testAPromptWaitsAndIsNeverTypedInto() {
        let w = World(sid: sid)
        w.status = "waiting"
        XCTAssertEqual(held(w, claim: HeldClaim()).reason, .waiting)
        XCTAssertTrue(w.delivered.isEmpty)
    }

    func testADeleteThatGotThereFirstMeansNoKeys() {
        let w = World(sid: sid)
        let claim = HeldClaim()
        XCTAssertTrue(claim.cancel())
        let r = held(w, claim: claim)
        XCTAssertEqual(r.reason, .cancelled)
        XCTAssertEqual(r.detail, HeldOutbox.deletedDetail)
        XCTAssertTrue(w.delivered.isEmpty)
    }

    func testABusyRefusalFromThePerKeyCheckMapsToBusy() {
        let w = World(sid: sid)
        w.deliverResult = InjectionResult(method: .tmux, success: false, output: "busy", detail: InjectionExecutor.busyAgainMessage)
        XCTAssertEqual(held(w, claim: HeldClaim()).reason, .busy)
        XCTAssertEqual(HeldOutbox.verdict(held(w, claim: HeldClaim())), .keep)
        // Part typed: final, never retried.
        w.deliverResult = InjectionResult(method: .tmux, success: false, output: "busy",
                                          detail: InjectionExecutor.busyAgainMessage + " (part of the reply was typed)")
        XCTAssertEqual(HeldOutbox.verdict(held(w, claim: HeldClaim())), .final)
    }

    func testPlanRefusesBusyOnlyWhenIdleIsRequired() {
        let host = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/t", paneId: "%3", inMode: false)
        XCTAssertEqual(Gate.claudePlan(target: .live, status: .busy, hasSessionFile: true, host: host, text: "go",
                                       interventionId: nil, requireIdle: true),
                       .refuse(.refused(.busy, HeldOutbox.stillBusyMessage)))
        XCTAssertEqual(Gate.claudePlan(target: .live, status: .busy, hasSessionFile: true, host: host, text: "go",
                                       interventionId: nil), .deliver(queued: true))
        XCTAssertEqual(Gate.claudePlan(target: .live, status: .shell, hasSessionFile: true, host: host, text: "go",
                                       interventionId: nil, requireIdle: true), .deliver(queued: false))
        // A permanent problem is reported before "still busy".
        XCTAssertEqual(Gate.claudePlan(target: .live, status: .busy, hasSessionFile: true, host: .unsupported("Ghostty"), text: "go",
                                       interventionId: nil, requireIdle: true).refusal?.reason, .notTypable)
    }

    func testThePerKeyCheckRefusesBusyOnlyForHeldMessages() {
        XCTAssertEqual(InjectionExecutor.busyAgainRefusal(status: .busy, enabled: true), InjectionExecutor.busyAgainMessage)
        for s in [ClaudeSessionStatus.idle, .shell, .waiting, .unknown] {
            XCTAssertNil(InjectionExecutor.busyAgainRefusal(status: s, enabled: true))
        }
        XCTAssertNil(InjectionExecutor.busyAgainRefusal(status: .busy, enabled: false), "Send now still queues into a turn")
    }

    func testTheRequestFlagIsOnlyForHeldMessages() {
        XCTAssertFalse(Gate.claudeRequest(sessionId: sid, clientId: "c", text: "x").refuseWhileBusy)
        XCTAssertTrue(Gate.claudeRequest(sessionId: sid, clientId: "c", text: "x", requireIdle: true).refuseWhileBusy)
    }

    func testResultFieldsCarryTheHoldExtrasOnlyWhenSet() {
        let plain = SessionCommandResult(code: .delivered, reason: nil, detail: "Typed").fields(clientId: "c")
        XCTAssertNil(plain["held"])
        XCTAssertNil(plain["fromHold"])
        XCTAssertNil(plain["retract"])
        var r = SessionCommandResult(code: .cancelled, reason: .cancelled, detail: HeldOutbox.deletedDetail)
        r.fromHold = true
        let f = r.fields(clientId: "c")
        XCTAssertEqual(f["code"] as? String, "cancelled")
        XCTAssertEqual(f["reason"] as? String, "cancelled")
        XCTAssertEqual(f["ok"] as? Bool, false)
        XCTAssertEqual(f["fromHold"] as? Bool, true)
        XCTAssertEqual(SessionCommandResult.Reason.tooLate.rawValue, "too_late")
    }
}

private extension SessionInputGate.ClaudeStep {
    var refusal: SessionCommandResult? {
        if case .refuse(let r) = self { return r }
        return nil
    }
}
