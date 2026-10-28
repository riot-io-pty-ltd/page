import XCTest
@testable import ClaudePowerMode

/// SESSIONS-PROTOCOL.md §5 "Holding a message until the turn ends" and
/// "Taking a message back": the pure outbox, the typing/delete switch, the
/// file it survives restarts in, and the replies a backend holds.
final class HeldOutboxTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)

    private func message(_ id: String, session: String = "s1", backend: AgentBackendID = .claude, text: String = "then lint",
                         at: TimeInterval = 0) -> HeldOutbox.Message {
        HeldOutbox.Message(clientId: id, sessionId: session, backend: backend, text: text, heldAt: t0.addingTimeInterval(at))
    }

    private func outbox(_ messages: HeldOutbox.Message...) -> HeldOutbox {
        var box = HeldOutbox()
        for m in messages { XCTAssertNil(box.add(m)) }
        return box
    }

    /// The `.type` steps' message ids and claims.
    private func typed(_ steps: [HeldOutbox.Step]) -> [(String, HeldClaim)] {
        steps.compactMap { if case .type(let m, let c) = $0 { return (m.clientId, c) } else { return nil } }
    }

    private func settled(_ steps: [HeldOutbox.Step]) -> [(String, SessionCommandResult)] {
        steps.compactMap { if case .settle(let m, let r) = $0 { return (m.clientId, r) } else { return nil } }
    }

    private let typedResult = SessionCommandResult(code: .delivered, reason: nil, detail: "Typed into tmux pane %3")
    private let busy = SessionCommandResult.refused(.busy, HeldOutbox.stillBusyMessage)

    // MARK: arrival

    func testBoundsPerSessionAndInAll() {
        var box = HeldOutbox()
        for i in 0..<HeldOutbox.maxPerSession { XCTAssertNil(box.add(message("a\(i)"))) }
        let refused = box.add(message("a-extra"))
        XCTAssertEqual(refused?.code, .refused)
        XCTAssertEqual(refused?.detail, HeldOutbox.tooManyDetail)
        XCTAssertNotNil(box.add(message("a0", session: "s9")), "a clientId is held once")
        for i in 0..<(HeldOutbox.maxTotal - HeldOutbox.maxPerSession) {
            XCTAssertNil(box.add(message("b\(i)", session: "s\(i / HeldOutbox.maxPerSession + 2)")))
        }
        XCTAssertEqual(box.add(message("z", session: "s99"))?.detail, HeldOutbox.tooManyInAllDetail)
    }

    func testHeldResultIsQueuedAndMarkedHeld() {
        let r = HeldOutbox.heldResult(backend: .claude)
        XCTAssertEqual(r.code, .queued)
        XCTAssertTrue(r.held)
        XCTAssertEqual(r.detail, "Held — Page types it when Claude finishes this turn")
        XCTAssertEqual(HeldOutbox.heldResult(backend: .codex).detail, "Held — Page types it when Codex finishes this turn")
        let f = r.fields(clientId: "c1")
        XCTAssertEqual(f["held"] as? Bool, true)
        XCTAssertEqual(f["ok"] as? Bool, true)
        XCTAssertNil(f["fromHold"])
    }

    // MARK: the drain

    func testNothingIsTypedUntilTheTurnIsOver() {
        var box = outbox(message("c1"))
        XCTAssertTrue(box.plan(readiness: ["s1": .wait], tick: false, now: t0.addingTimeInterval(5)).isEmpty)
        let steps = box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(9))
        XCTAssertEqual(typed(steps).map(\.0), ["c1"])
        XCTAssertTrue(box.messages[0].typing)
        XCTAssertTrue(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(10)).isEmpty,
                      "one try at a time")
    }

    func testOldestFirstOnePerIdlePeriod() {
        var box = outbox(message("c1"), message("c2", at: 1))
        let first = typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(5)))
        XCTAssertEqual(first.map(\.0), ["c1"], "the oldest first, and only it")
        let done = box.finish(clientId: "c1", result: typedResult, now: t0.addingTimeInterval(6))
        XCTAssertEqual(done.result?.clientId, "c1")
        XCTAssertEqual(done.result?.result.code, .delivered)
        XCTAssertTrue(done.result?.result.fromHold ?? false)
        // The session reads idle again at once (the new turn not yet in the file): the gap holds the next.
        XCTAssertTrue(typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(10))).isEmpty)
        XCTAssertTrue(typed(box.plan(readiness: ["s1": .wait], tick: false, now: t0.addingTimeInterval(30))).isEmpty,
                      "busy with the first one's turn")
        XCTAssertEqual(typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(60))).map(\.0), ["c2"])
    }

    func testSessionsDrainIndependently() {
        var box = outbox(message("a", session: "s1"), message("b", session: "s2"))
        let steps = typed(box.plan(readiness: ["s1": .ready, "s2": .ready], tick: false, now: t0))
        XCTAssertEqual(Set(steps.map(\.0)), ["a", "b"])
    }

    func testExpiresAfterSixHoursWithAnHonestResult() {
        var box = outbox(message("c1"))
        XCTAssertTrue(box.plan(readiness: ["s1": .wait], tick: false, now: t0.addingTimeInterval(HeldOutbox.lifetime - 1)).isEmpty)
        let steps = settled(box.plan(readiness: ["s1": .wait], tick: false, now: t0.addingTimeInterval(HeldOutbox.lifetime)))
        XCTAssertEqual(steps.map(\.0), ["c1"])
        let r = steps[0].1
        XCTAssertEqual(r.code, .refused)
        XCTAssertEqual(r.reason, .expired)
        XCTAssertEqual(r.detail, "Not sent — the turn didn't finish within 6 hours")
        XCTAssertTrue(r.fromHold)
        XCTAssertTrue(box.isEmpty)
        XCTAssertEqual(box.settled.map(\.outcome), [.expired])
    }

    func testAMessageBeingTypedNeverExpiresUnderTheTry() {
        var box = outbox(message("c1"))
        _ = box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(HeldOutbox.lifetime - 1))
        XCTAssertTrue(settled(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(HeldOutbox.lifetime + 5))).isEmpty)
    }

    func testSessionEndedOnlyAfterThirtySecondsAndTwoTicks() {
        var box = outbox(message("c1"))
        // A failed ps can drop a session from one tick: that is not "ended".
        XCTAssertTrue(box.plan(readiness: [:], tick: true, now: t0).isEmpty)
        XCTAssertTrue(box.plan(readiness: [:], tick: false, now: t0.addingTimeInterval(31)).isEmpty, "one tick isn't enough")
        XCTAssertTrue(box.plan(readiness: ["s1": .wait], tick: true, now: t0.addingTimeInterval(32)).isEmpty, "back: the count restarts")
        XCTAssertTrue(box.plan(readiness: [:], tick: true, now: t0.addingTimeInterval(40)).isEmpty)
        XCTAssertTrue(box.plan(readiness: [:], tick: true, now: t0.addingTimeInterval(60)).isEmpty, "two ticks, but only 20 s")
        let steps = settled(box.plan(readiness: [:], tick: false, now: t0.addingTimeInterval(71)))
        XCTAssertEqual(steps.map(\.0), ["c1"])
        XCTAssertEqual(steps.first?.1.reason, .ended)
        XCTAssertEqual(steps.first?.1.detail, "Not sent — the session ended")
        XCTAssertTrue(steps.first?.1.fromHold ?? false)
    }

    // MARK: what a try's result means

    func testVerdictTable() {
        let keep: [SessionCommandResult] = [
            busy,
            .refused(.waiting, SessionInputGate.waitingMessage),
            .refused(.unknownState, SessionInputGate.unknownStateMessage),
            .refused(.draft, CmuxBridge.draftDetail),
            .refused(.codexMidTurn, SessionInputGate.codexMidTurnMessage),
            .refused(.digitWhileBusy, SessionInputGate.digitWhileBusyMessage),
            .refused(.notTypable, InjectionExecutor.notForegroundMessage),
            .refused(.notTypable, CodexInjector.notForegroundDetail),
        ]
        for r in keep { XCTAssertEqual(HeldOutbox.verdict(r), .keep, r.detail) }
        let final: [SessionCommandResult] = [
            .refused(.ended, SessionInputGate.endedMessage),
            .refused(.notFound, "gone"),
            .refused(.targetMismatch, "moved"),
            .refused(.notTypable, "Page can't type into Ghostty yet"),
            .refused(.error, "The message was empty"),
            .failed("Typed part of it (part of the reply was typed)"),
            .refused(.cancelled, HeldOutbox.deletedDetail),
        ]
        for r in final { XCTAssertEqual(HeldOutbox.verdict(r), .final, r.detail) }
        XCTAssertEqual(HeldOutbox.verdict(typedResult), .typed)
        XCTAssertEqual(HeldOutbox.verdict(SessionCommandResult(code: .queued, reason: nil, detail: "q")), .typed)
    }

    func testAPassingRefusalKeepsItHeldAndBacksOff() {
        var box = outbox(message("c1"))
        _ = box.plan(readiness: ["s1": .ready], tick: false, now: t0)
        let f = box.finish(clientId: "c1", result: .refused(.draft, CmuxBridge.draftDetail), now: t0.addingTimeInterval(1))
        XCTAssertNil(f.result, "still held: no result yet")
        XCTAssertFalse(box.messages[0].typing)
        XCTAssertEqual(box.messages[0].tries, 1)
        XCTAssertEqual(box.rowEntries(sessionId: "s1", now: t0).first?["detail"] as? String, CmuxBridge.draftDetail, "the row says why")
        XCTAssertTrue(typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(5))).isEmpty, "5 s later at the earliest")
        _ = box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(6))
        _ = box.finish(clientId: "c1", result: busy, now: t0.addingTimeInterval(7))
        XCTAssertTrue(typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(16))).isEmpty, "then 10 s")
        XCTAssertEqual(typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(17.5))).count, 1)
        XCTAssertEqual(HeldOutbox.retryDelay(tries: 100), HeldOutbox.maxRetryDelay)
    }

    func testAFinalRefusalIsNeverRetried() {
        var box = outbox(message("c1"))
        _ = box.plan(readiness: ["s1": .ready], tick: false, now: t0)
        let f = box.finish(clientId: "c1", result: .failed("Couldn't press Return (part of the reply was typed)"), now: t0)
        XCTAssertEqual(f.result?.result.code, .failed)
        XCTAssertEqual(f.result?.result.detail, "Not sent — couldn't press Return (part of the reply was typed)")
        XCTAssertTrue(f.result?.result.fromHold ?? false)
        XCTAssertTrue(box.isEmpty)
        XCTAssertEqual(box.settled.map(\.outcome), [.failed])
        XCTAssertTrue(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(60)).isEmpty)
    }

    func testTheGateSayingEndedSettlesAsEnded() {
        var box = outbox(message("c1"))
        _ = box.plan(readiness: ["s1": .ready], tick: false, now: t0)
        let f = box.finish(clientId: "c1", result: .refused(.ended, SessionInputGate.endedMessage), now: t0)
        XCTAssertEqual(f.result?.result.detail, HeldOutbox.endedDetail)
        XCTAssertEqual(box.settled.map(\.outcome), [.ended])
    }

    // MARK: the try made on arrival

    func testFirstTryTypedGivesOneOrdinaryResult() throws {
        var box = outbox(message("c1"))
        let (m, claim) = try XCTUnwrap(box.claimFirstTry("c1", now: t0))
        XCTAssertTrue(m.firstTry)
        XCTAssertTrue(claim.commit())
        let f = box.finish(clientId: "c1", result: typedResult, now: t0)
        XCTAssertEqual(f.result?.result, typedResult, "no held, no fromHold: it was never held")
        XCTAssertTrue(box.settled.isEmpty)
        XCTAssertTrue(box.rowEntries(sessionId: "s1", now: t0).isEmpty)
    }

    func testFirstTryFindingItBusyHoldsIt() throws {
        var box = outbox(message("c1"))
        _ = try XCTUnwrap(box.claimFirstTry("c1", now: t0))
        XCTAssertTrue(box.rowEntries(sessionId: "s1", now: t0).isEmpty, "a first try isn't listed")
        let f = box.finish(clientId: "c1", result: busy, now: t0)
        XCTAssertEqual(f.result?.result.held, true)
        XCTAssertEqual(f.result?.result.code, .queued)
        XCTAssertFalse(box.messages[0].firstTry)
        XCTAssertEqual(box.rowEntries(sessionId: "s1", now: t0).count, 1)
    }

    func testFirstTryRefusedGivesThatRefusal() throws {
        var box = outbox(message("c1"))
        _ = try XCTUnwrap(box.claimFirstTry("c1", now: t0))
        let refusal = SessionCommandResult.refused(.notTypable, "Page can't type into Ghostty yet")
        XCTAssertEqual(box.finish(clientId: "c1", result: refusal, now: t0).result?.result, refusal)
        XCTAssertTrue(box.isEmpty)
    }

    func testFirstTryWaitsBehindAnOlderMessageOrAJustTypedOne() {
        var box = outbox(message("c1"), message("c2", at: 1))
        XCTAssertNil(box.claimFirstTry("c2", now: t0), "c1 goes first")
        var fresh = outbox(message("c1"))
        _ = fresh.plan(readiness: ["s1": .ready], tick: false, now: t0)
        _ = fresh.finish(clientId: "c1", result: typedResult, now: t0)
        XCTAssertNil(fresh.add(message("c3", at: 2)))
        XCTAssertNil(fresh.claimFirstTry("c3", now: t0.addingTimeInterval(2)), "c1 was typed 2 s ago")
        XCTAssertNotNil(fresh.claimFirstTry("c3", now: t0.addingTimeInterval(HeldOutbox.typedGap)))
    }

    // MARK: deleting, and the race with typing

    func testDeleteWhileWaiting() throws {
        var box = outbox(message("c1"))
        guard case .deleted(let final) = box.retract(heldId: "c1", by: "r1", now: t0) else { return XCTFail("not deleted") }
        XCTAssertEqual(final.clientId, "c1")
        XCTAssertEqual(final.result.code, .cancelled)
        XCTAssertEqual(final.result.reason, .cancelled)
        XCTAssertEqual(final.result.detail, "Deleted — not sent")
        XCTAssertTrue(final.result.fromHold)
        XCTAssertEqual(final.result.fields(clientId: "c1")["ok"] as? Bool, false)
        XCTAssertTrue(box.isEmpty)
        XCTAssertTrue(box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(1)).isEmpty, "never typed")
        guard case .alreadyDeleted = box.retract(heldId: "c1", by: "r2", now: t0) else { return XCTFail("second delete") }
        XCTAssertEqual(box.rowEntries(sessionId: "s1", now: t0).first?["state"] as? String, "deleted")
    }

    func testDeleteBeforeTheKeysWinsAndTheTryTypesNothing() {
        var box = outbox(message("c1"))
        let (_, claim) = typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0))[0]
        guard case .deleted(let final) = box.retract(heldId: "c1", by: "r1", now: t0) else { return XCTFail("not deleted") }
        XCTAssertEqual(final.result.code, .cancelled)
        XCTAssertFalse(claim.commit(), "the try reaches its keys after the delete: it must not type")
        let f = box.finish(clientId: "c1", result: .refused(.cancelled, HeldOutbox.deletedDetail), now: t0)
        XCTAssertNil(f.result, "the delete already answered for it")
        XCTAssertTrue(f.retracts.isEmpty)
        XCTAssertEqual(box.settled.map(\.outcome), [.deleted])
    }

    func testTypedWhileTheDeleteWasInFlightIsTooLateNeverBoth() {
        var box = outbox(message("c1"))
        let (_, claim) = typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0))[0]
        XCTAssertTrue(claim.commit(), "the keys are going")
        guard case .waits = box.retract(heldId: "c1", by: "r1", now: t0) else { return XCTFail("should wait for the try") }
        let f = box.finish(clientId: "c1", result: typedResult, now: t0)
        XCTAssertEqual(f.result?.result.code, .delivered, "the input: typed")
        XCTAssertEqual(f.retracts.map(\.clientId), ["r1"])
        XCTAssertEqual(f.retracts.first?.result.reason, .tooLate)
        XCTAssertEqual(f.retracts.first?.result.retract, "too_late")
        XCTAssertEqual(f.retracts.first?.result.detail, "Too late — it was already typed")
        XCTAssertEqual(box.settled.map(\.outcome), [.typed], "typed, not deleted")
        guard case .tooLate = box.retract(heldId: "c1", by: "r2", now: t0) else { return XCTFail("a later delete") }
    }

    func testDeleteAfterTheSwitchButRefusedBeforeAnyKeyIsDeleted() {
        var box = outbox(message("c1"))
        let (_, claim) = typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0))[0]
        XCTAssertTrue(claim.commit())
        guard case .waits = box.retract(heldId: "c1", by: "r1", now: t0) else { return XCTFail("should wait") }
        // Claude turned busy again before the first key: nothing typed.
        let f = box.finish(clientId: "c1", result: .refused(.busy, InjectionExecutor.busyAgainMessage), now: t0)
        XCTAssertEqual(f.result?.result.code, .cancelled, "not put back: it was deleted")
        XCTAssertEqual(f.retracts.first?.result.retract, "deleted")
        XCTAssertTrue(box.isEmpty)
    }

    func testAFailedTryWithADeleteWaitingIsTooLateNotDeleted() {
        var box = outbox(message("c1"))
        let (_, claim) = typed(box.plan(readiness: ["s1": .ready], tick: false, now: t0))[0]
        XCTAssertTrue(claim.commit())
        guard case .waits = box.retract(heldId: "c1", by: "r1", now: t0) else { return XCTFail("should wait") }
        // The text went in, then the check before Return found Claude busy: part of it may sit in the box.
        let partial = SessionCommandResult.failed(InjectionExecutor.busyAgainMessage + " (part of the reply was typed)")
        let f = box.finish(clientId: "c1", result: partial, now: t0)
        XCTAssertEqual(f.result?.result.code, .failed, "never reported as deleted")
        XCTAssertEqual(f.result?.result.fromHold, true)
        XCTAssertEqual(f.retracts.map(\.clientId), ["r1"])
        XCTAssertEqual(f.retracts.first?.result.retract, "too_late")
        XCTAssertEqual(f.retracts.first?.result.detail, HeldOutbox.tooLateFailedDetail)
        XCTAssertEqual(box.settled.map(\.outcome), [.failed])
        XCTAssertTrue(box.isEmpty, "never retried")
    }

    func testDeleteOfSomethingNeverHeld() {
        var box = HeldOutbox()
        guard case .notFound = box.retract(heldId: "nope", by: "r1", now: t0) else { return XCTFail("not found") }
        let r = HeldOutbox.retractResult(.notFound)
        XCTAssertEqual(r.reason, .notFound)
        XCTAssertEqual(r.retract, "not_found")
        XCTAssertEqual(r.detail, "Page isn't holding that message")
        let ok = HeldOutbox.retractResult(.deleted).fields(clientId: "r1")
        XCTAssertEqual(ok["ok"] as? Bool, true)
        XCTAssertEqual(ok["code"] as? String, "delivered")
        XCTAssertEqual(ok["retract"] as? String, "deleted")
    }

    func testTheSwitchHasExactlyOneWinnerUnderContention() {
        for _ in 0..<200 {
            let claim = HeldClaim()
            let lock = NSLock()
            var wins = 0
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                let won = i == 0 ? claim.commit() : claim.cancel()
                if won { lock.lock(); wins += 1; lock.unlock() }
            }
            XCTAssertEqual(wins, 1)
            XCTAssertNotEqual(claim.state, .open)
        }
    }

    // MARK: the row

    func testRowEntriesAreClippedRedactedAndSettleForFifteenMinutes() {
        let long = String(repeating: "word ", count: 100)
        var box = outbox(message("c1", text: long), message("c2", text: "key sk-ant-api03-\(String(repeating: "x", count: 40))", at: 1))
        _ = box.plan(readiness: ["s1": .ready], tick: false, now: t0.addingTimeInterval(2))
        var rows = box.rowEntries(sessionId: "s1", now: t0)
        XCTAssertEqual(rows.map { $0["state"] as? String }, ["typing", "held"])
        XCTAssertLessThanOrEqual((rows[0]["text"] as? String ?? "").count, HeldOutbox.rowTextLimit + 1)
        XCTAssertFalse((rows[1]["text"] as? String ?? "").contains("xxxxxxxxxx"), "redacted like a transcript entry")
        XCTAssertNotNil(rows[0]["heldAt"] as? String)
        XCTAssertNil(rows[0]["at"])
        _ = box.finish(clientId: "c1", result: typedResult, now: t0.addingTimeInterval(3))
        rows = box.rowEntries(sessionId: "s1", now: t0.addingTimeInterval(3))
        XCTAssertEqual(rows.map { $0["state"] as? String }, ["typed", "held"])
        XCTAssertEqual(rows[0]["detail"] as? String, "Typed into tmux pane %3")
        XCTAssertNotNil(rows[0]["at"] as? String)
        XCTAssertTrue(box.rowEntries(sessionId: "s2", now: t0).isEmpty)
        let later = t0.addingTimeInterval(3 + HeldOutbox.settledKept)
        XCTAssertEqual(box.rowEntries(sessionId: "s1", now: later).map { $0["state"] as? String }, ["held"])
    }

    func testPanelItemsAreTheWaitingMessages() {
        var box = outbox(message("c1"), message("c2", session: "s2"))
        _ = box.plan(readiness: ["s2": .ready], tick: false, now: t0)
        XCTAssertEqual(box.panelItems().map(\.clientId), ["c1", "c2"])
        XCTAssertEqual(box.panelItems().map(\.typing), [false, true])
    }

    // MARK: pairing

    func testANewPairingDropsEverythingHeld() {
        let a = HeldOutbox.keyTag(root: Data(repeating: 1, count: 32))
        let b = HeldOutbox.keyTag(root: Data(repeating: 2, count: 32))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 16)
        var box = outbox(message("c1"))
        XCTAssertEqual(box.adopt(keyTag: a), 0, "the first pairing seen is adopted")
        XCTAssertEqual(box.adopt(keyTag: a), 0)
        XCTAssertEqual(box.messages.count, 1)
        XCTAssertEqual(box.adopt(keyTag: b), 1)
        XCTAssertTrue(box.isEmpty)
        XCTAssertEqual(box.keyTag, b)
    }

    // MARK: on disk

    func testRoundTripAndATryUnderWayIsNeverRetyped() throws {
        var box = outbox(message("c1"), message("c2", session: "s2"))
        _ = box.adopt(keyTag: "abcd")
        _ = box.plan(readiness: ["s2": .ready], tick: false, now: t0)   // c2 is being typed when Page quits
        let data = try XCTUnwrap(HeldOutboxStore.encode(box))
        let back = HeldOutboxStore.decode(data, now: t0.addingTimeInterval(60))
        XCTAssertEqual(back.messages.map(\.clientId), ["c1"])
        XCTAssertEqual(back.messages.first?.text, "then lint")
        XCTAssertEqual(back.keyTag, "abcd")
        XCTAssertEqual(back.settled.map(\.clientId), ["c2"])
        XCTAssertEqual(back.settled.first?.outcome, .unconfirmed)
        XCTAssertEqual(back.settled.first?.detail, HeldOutbox.unconfirmedDetail)
        var restored = back
        XCTAssertTrue(typed(restored.plan(readiness: ["s2": .ready], tick: false, now: t0.addingTimeInterval(61))).isEmpty,
                      "never typed a second time")
        guard case .tooLate = restored.retract(heldId: "c2", by: "r", now: t0) else { return XCTFail("it may have been typed") }
    }

    func testDecodeSkipsJunkAndOldSettledEntries() {
        let obj: [String: Any] = ["v": 1, "messages": [
            ["clientId": "ok", "sessionId": "s1", "backend": "claude", "text": "  hi  ", "heldAt": 1_761_300_000.0],
            ["clientId": "", "sessionId": "s1", "backend": "claude", "text": "x", "heldAt": 1.0],
            ["clientId": "nob", "sessionId": "s1", "backend": "gemini", "text": "x", "heldAt": 1.0],
            ["clientId": "empty", "sessionId": "s1", "backend": "claude", "text": "   ", "heldAt": 1.0],
        ], "settled": [
            ["clientId": "old", "sessionId": "s1", "text": "t", "heldAt": 1.0, "outcome": "typed", "detail": "d",
             "at": t0.timeIntervalSince1970 - HeldOutbox.settledKept - 1],
            ["clientId": "new", "sessionId": "s1", "text": "t", "heldAt": 1.0, "outcome": "typed", "detail": "d",
             "at": t0.timeIntervalSince1970 - 10],
        ]]
        let box = HeldOutboxStore.decode(try! JSONSerialization.data(withJSONObject: obj), now: t0)
        XCTAssertEqual(box.messages.map(\.clientId), ["ok"])
        XCTAssertEqual(box.messages.first?.text, "hi")
        XCTAssertEqual(box.settled.map(\.clientId), ["new"])
        XCTAssertTrue(HeldOutboxStore.decode(Data("{\"v\":2}".utf8), now: t0).isEmpty)
        XCTAssertTrue(HeldOutboxStore.decode(Data("nonsense".utf8), now: t0).isEmpty)
    }

    func testTheFileIsWrittenOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-held-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HeldOutboxStore(url: dir.appendingPathComponent("held_outbox.json"))
        store.save(outbox(message("c1")))
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(store.load(now: t0).messages.map(\.clientId), ["c1"])
        XCTAssertTrue(HeldOutboxStore(url: dir.appendingPathComponent("missing.json")).load(now: t0).isEmpty)
    }
}

/// Replies a backend holds for a relay page (`HeldReplies`): the rate-limit
/// hold and a reply waiting for its background run, against a delete.
final class HeldRepliesTests: XCTestCase {
    func testAResetMessageDeletedBeforeTheResetIsNeverTyped() {
        var h = HeldReplies()
        h.holdForReset(eventId: "e1", text: "carry on with the docs", interventionId: "ratelimit-1")
        XCTAssertEqual(h.retract("ratelimit-1"), .resetDeleted(eventId: "e1"))
        XCTAssertNil(h.takeForReset(eventId: "e1"), "the reset finds nothing to type")
        XCTAssertEqual(h.retract("ratelimit-1"), .notHeld)
    }

    func testTakenByTheResetFirstMeansTooLate() {
        var h = HeldReplies()
        h.holdForReset(eventId: "e1", text: "go", interventionId: "ratelimit-1")
        XCTAssertEqual(h.takeForReset(eventId: "e1"), HeldReplies.ResetMessage(text: "go", interventionId: "ratelimit-1"))
        XCTAssertEqual(h.retract("ratelimit-1"), .resetTaken)
    }

    func testALaunchDeletedBeforeItStartsNeverRuns() {
        var h = HeldReplies()
        h.queueLaunch("p1")
        XCTAssertTrue(h.isWaitingToLaunch("p1"))
        XCTAssertEqual(h.retract("p1"), .launchDeleted)
        XCTAssertFalse(h.claimLaunch("p1"), "the run checks before it starts, and stands down")
    }

    func testALaunchThatStartedFirstCantBeDeleted() {
        var h = HeldReplies()
        h.queueLaunch("p1")
        XCTAssertTrue(h.claimLaunch("p1"))
        XCTAssertEqual(h.retract("p1"), .notHeld)
    }

    func testRetractResultsCarryTheirCopy() {
        XCTAssertEqual(HeldRetract.deleted(HeldRetract.resetDeletedNothing).result.retract, "deleted")
        XCTAssertEqual(HeldRetract.deleted(HeldRetract.resetDeletedNothing).result.detail, "Deleted — not sent. Nothing will be typed at reset")
        XCTAssertEqual(HeldRetract.tooLate(HeldRetract.alreadyRunning).result.reason, .tooLate)
        XCTAssertEqual(HeldRetract.tooLate(HeldRetract.alreadyRunning).result.detail, "Too late — it's already running")
        XCTAssertEqual(HeldRetract.notFound.result.retract, "not_found")
    }
}
