import XCTest
@testable import ClaudePowerMode

/// `hold-v1` and `retract-v1` end to end through `SessionRemote`
/// (SESSIONS-PROTOCOL.md §5): the phone's sealed commands in, the sealed
/// results and list rows out, with the backends faked. Nothing types.
final class SessionHoldTests: XCTestCase {
    private let root = Data((0...31).map { UInt8($0 &* 7) })
    private lazy var keys = SessionKeys(root: root)!
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)

    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private final class Sink: SessionsUpdateSink {
        private let lock = NSLock()
        private var _sent: [SessionEnvelope] = []
        var isConnected = true
        var sent: [SessionEnvelope] { lock.lock(); defer { lock.unlock() }; return _sent }
        func sendSessionsUpdate(_ envelope: SessionEnvelope) {
            lock.lock(); _sent.append(envelope); lock.unlock()
        }
    }

    /// A held message's try, as the backend got it.
    struct Try {
        let sessionId: String
        let clientId: String
        let text: String
        let claim: HeldClaim
        let completion: (SessionCommandResult) -> Void
    }

    private final class Backends: SessionRemoteBackends {
        var hosts: [String: SessionHostInfo] = [:]
        var statuses: [String: ClaudeSessionStatus] = [:]
        var inputs: [String] = []
        /// What a held try does: given its switch, the result (nil: park it for the test to finish).
        var typeHeldResult: (HeldClaim) -> SessionCommandResult? = { claim in
            claim.commit() ? SessionCommandResult(code: .delivered, reason: nil, detail: "Typed into tmux pane %3")
                           : .refused(.cancelled, HeldOutbox.deletedDetail)
        }
        var tries: [Try] = []
        var parked: [Try] = []
        var retractAnswer: HeldRetract = .notFound
        var retracted: [String] = []

        func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo] {
            hosts.filter { id, _ in sessions.contains { $0.sessionId == id } }
        }
        func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus] {
            statuses.filter { id, _ in sessions.contains { $0.sessionId == id } }
        }
        func transcriptFile(for session: AgentSession) -> SessionTranscriptFile? { nil }
        func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?,
                   completion: @escaping (SessionCommandResult) -> Void) {
            inputs.append(clientId)
            completion(SessionCommandResult(code: .queued, reason: nil, detail: SessionInputGate.queuedMessage))
        }
        func interrupt(_ session: AgentSession, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
            completion(SessionCommandResult(code: .delivered, reason: nil, detail: "Pressed Esc"))
        }
        func typeHeld(_ session: AgentSession, clientId: String, text: String, claim: HeldClaim,
                      completion: @escaping (SessionCommandResult) -> Void) {
            let t = Try(sessionId: session.sessionId, clientId: clientId, text: text, claim: claim, completion: completion)
            tries.append(t)
            if let r = typeHeldResult(claim) { completion(r) } else { parked.append(t) }
        }
        func retractReply(interventionId: String) -> HeldRetract {
            retracted.append(interventionId)
            return retractAnswer
        }
    }

    private var clock: Clock!
    private var sink: Sink!
    private var backends: Backends!
    private var remote: SessionRemote!
    private var dir: URL!

    override func setUpWithError() throws {
        clock = Clock(t0)
        sink = Sink()
        backends = Backends()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-hold-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        remote = makeRemote()
    }

    override func tearDown() {
        remote?.stop()
        remote?.waitUntilIdle()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func makeRemote(store: URL? = nil, rootKey: Data? = nil) -> SessionRemote {
        let c = clock!
        let r = SessionRemote(backends: backends, now: { c.now }, autoTimer: false, macName: { "Test Mac" }, outboxStore: store,
                              heldSessions: { [] })
        r.attach(sink: sink, rootKey: rootKey ?? root)
        r.waitUntilIdle()
        return r
    }

    // MARK: helpers

    private func session(_ id: String, _ state: AgentSessionState, backend: AgentBackendID = .claude) -> AgentSession {
        AgentSession(backend: backend, sessionId: id, cwd: NSHomeDirectory() + "/projects/\(id)", title: id,
                     source: .terminal, state: state, lastActivityAt: t0, activeFlags: [], supportsRemoteReply: true)
    }

    private func decoded(_ e: SessionEnvelope) -> [String: Any]? {
        SessionCrypto.open(e, key: keys.macToPhone, aad: SessionCrypto.updateAAD)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private var frames: [[String: Any]] { sink.sent.compactMap(decoded) }
    private func results(_ clientId: String) -> [[String: Any]] {
        frames.filter { $0["kind"] as? String == "result" && $0["clientId"] as? String == clientId }
    }

    private func send(_ fields: [String: Any]) {
        var obj = fields
        if obj["ts"] == nil { obj["ts"] = clock.now.timeIntervalSince1970 * 1000 }
        if obj["clientId"] == nil { obj["clientId"] = UUID().uuidString }
        if obj["viewer"] == nil { obj["viewer"] = "v1" }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        remote.handleCommand(SessionCrypto.seal(data, key: keys.phoneToMac, aad: SessionCrypto.commandAAD)!)
        remote.waitUntilIdle()
    }

    private func hold(_ clientId: String, _ text: String = "then run the linter", session: String = "s1") {
        send(["op": "input", "sessionId": session, "text": text, "hold": true, "clientId": clientId])
    }

    private func setSessions(_ s: [AgentSession]) {
        remote.update(sessions: s, pending: [])
        remote.waitUntilIdle()
    }

    private func advance(_ s: TimeInterval, tick: Bool = false) {
        clock.now = clock.now.addingTimeInterval(s)
        remote.stepOutbox(tick: tick)
        remote.waitUntilIdle()
    }

    private func lastList() -> [String: Any]? {
        remote.setPhones(1, from: sink)
        remote.waitUntilIdle()
        send(["op": "refresh"])
        return frames.last { $0["kind"] as? String == "list" }
    }

    private func heldRow(_ id: String = "s1") -> [[String: Any]] {
        let rows = lastList()?["sessions"] as? [[String: Any]] ?? []
        return rows.first { $0["id"] as? String == id }?["held"] as? [[String: Any]] ?? []
    }

    // MARK: caps

    func testTheListAdvertisesHoldAndRetract() {
        setSessions([session("s1", .idle)])
        let list = lastList()
        XCTAssertEqual(list?["caps"] as? [String], ["hold-v1", "retract-v1", "images-v1"])
        XCTAssertEqual(SessionRemote.capabilities, ["hold-v1", "retract-v1", "images-v1"])
    }

    // MARK: holding

    func testHoldWhileBusyAnswersHeldAndTheRowListsIt() throws {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        let r = try XCTUnwrap(results("c1").last)
        XCTAssertEqual(r["code"] as? String, "queued")
        XCTAssertEqual(r["ok"] as? Bool, true)
        XCTAssertEqual(r["held"] as? Bool, true)
        XCTAssertEqual(r["detail"] as? String, "Held — Page types it when Claude finishes this turn")
        XCTAssertTrue(backends.inputs.isEmpty, "not typed at once")
        XCTAssertTrue(backends.tries.isEmpty)
        let held = heldRow()
        XCTAssertEqual(held.map { $0["clientId"] as? String }, ["c1"])
        XCTAssertEqual(held.first?["state"] as? String, "held")
        XCTAssertEqual(held.first?["text"] as? String, "then run the linter")
        XCTAssertEqual(remote.heldMessages().map(\.clientId), ["c1"], "the Mac's panel sees it too")
    }

    func testItIsTypedWhenTheTurnEndsWithNoPhoneLooking() throws {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        remote.setPhones(0, from: sink)
        remote.waitUntilIdle()
        advance(2)
        XCTAssertTrue(backends.tries.isEmpty, "still busy")
        // The turn ends; the list still says active (the tick is slow): the sessions file decides.
        backends.statuses = ["s1": .idle]
        advance(2)
        XCTAssertEqual(backends.tries.map(\.clientId), ["c1"])
        XCTAssertEqual(backends.tries.first?.text, "then run the linter")
        let final = try XCTUnwrap(results("c1").last)
        XCTAssertEqual(final["code"] as? String, "delivered")
        XCTAssertEqual(final["fromHold"] as? Bool, true)
        XCTAssertEqual(final["detail"] as? String, "Typed into tmux pane %3")
        XCTAssertEqual(results("c1").count, 2, "held, then typed: exactly one final result")
        XCTAssertEqual(heldRow().first?["state"] as? String, "typed")
        XCTAssertTrue(remote.heldMessages().isEmpty)
    }

    func testAnIdlePageDoesNotCountAsBusyButAPromptWaits() {
        backends.statuses = ["s1": .waiting]
        setSessions([session("s1", .waitingOnApproval)])
        hold("c1")
        advance(3)
        XCTAssertTrue(backends.tries.isEmpty, "never typed into a prompt")
        // Claude's idle page keeps the list state at waitingOnUser after every turn.
        backends.statuses = ["s1": .idle]
        setSessions([session("s1", .waitingOnUser)])
        XCTAssertEqual(backends.tries.count, 1)
    }

    func testHoldOnAnIdleSessionTypesNowWithOneOrdinaryResult() throws {
        backends.statuses = ["s1": .idle]
        setSessions([session("s1", .idle)])
        hold("c1")
        XCTAssertEqual(backends.tries.count, 1)
        let all = results("c1")
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?["code"] as? String, "delivered")
        XCTAssertNil(all.first?["held"])
        XCTAssertNil(all.first?["fromHold"])
        XCTAssertTrue(heldRow().isEmpty)
    }

    func testHoldOnIdleThatFindsItBusyAgainIsHeld() throws {
        backends.statuses = ["s1": .idle]
        backends.typeHeldResult = { _ in .refused(.busy, InjectionExecutor.busyAgainMessage) }
        setSessions([session("s1", .idle)])
        hold("c1")
        let r = try XCTUnwrap(results("c1").last)
        XCTAssertEqual(r["held"] as? Bool, true)
        XCTAssertEqual(heldRow().first?["state"] as? String, "held")
    }

    func testWithoutHoldItIsTypedAtOnceAsBefore() {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        send(["op": "input", "sessionId": "s1", "text": "now please", "clientId": "c1"])
        XCTAssertEqual(backends.inputs, ["c1"])
        XCTAssertEqual(results("c1").last?["code"] as? String, "queued")
        XCTAssertNil(results("c1").last?["held"])
    }

    func testTheMacsOwnPanelNeverHolds() {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        var cmd = SessionCommand(op: "input", clientId: "mac-1", ts: clock.now.timeIntervalSince1970 * 1000, viewer: nil,
                                 sessionId: "s1", text: "go")
        cmd.hold = true
        let done = expectation(description: "result")
        remote.performLocal(cmd) { r in
            XCTAssertFalse(r.held)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(backends.inputs, ["mac-1"])
    }

    func testHoldIsRefusedWhereTypingIsImpossible() {
        backends.hosts = ["s1": .blocked("Ghostty", "Page can't type into Ghostty yet")]
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        _ = lastList()   // runs the host probe
        remote.waitUntilIdle()
        hold("c1")
        let r = results("c1").last
        XCTAssertEqual(r?["reason"] as? String, "not_typable")
        XCTAssertEqual(r?["detail"] as? String, "Page can't type into Ghostty yet")
        XCTAssertTrue(remote.heldMessages().isEmpty)
    }

    func testCodexMidTurnInTmuxCanBeHeld() {
        // The composer is blocked mid-turn outside cmux; holding is exactly what helps.
        backends.hosts = ["c1": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: .unknown)]
        setSessions([session("c1", .active, backend: .codex)])
        _ = lastList()
        remote.waitUntilIdle()
        hold("m1", session: "c1")
        XCTAssertEqual(results("m1").last?["detail"] as? String, "Held — Page types it when Codex finishes this turn")
        advance(3)
        XCTAssertTrue(backends.tries.isEmpty)
        setSessions([session("c1", .idle, backend: .codex)])
        XCTAssertEqual(backends.tries.map(\.clientId), ["m1"])
    }

    func testRowsSayWhereHoldingIsPossible() throws {
        backends.hosts = [
            "s1": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: .anthropic),
            "c1": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: .unknown),
            "g1": .blocked("Ghostty", "Page can't type into Ghostty yet"),
        ]
        setSessions([session("s1", .active), session("c1", .active, backend: .codex), session("g1", .active), session("u1", .active)])
        _ = lastList()   // runs the host probe
        remote.waitUntilIdle()
        let rows = try XCTUnwrap(lastList()?["sessions"] as? [[String: Any]])
        func row(_ id: String) -> [String: Any]? { rows.first { $0["id"] as? String == id } }
        XCTAssertEqual(row("s1")?["canHold"] as? Bool, true)
        // Codex mid-turn in tmux: no composer for "Send now", but it can be held.
        XCTAssertEqual(row("c1")?["canType"] as? Bool, false)
        XCTAssertEqual(row("c1")?["canHold"] as? Bool, true)
        XCTAssertNil(row("g1")?["canHold"], "a terminal Page can't type into")
        XCTAssertNil(row("u1")?["canHold"], "not probed yet")
    }

    func testCodexInTerminalIsNeverHeldBecauseTypingWouldTakeFocus() {
        let terminal = SessionHostInfo(host: "Terminal", canType: true, canInterrupt: false, provider: .unknown)
        XCTAssertFalse(SessionRemote.canHold(backend: .codex, probed: terminal))
        XCTAssertTrue(SessionRemote.canHold(backend: .claude, probed: terminal))
        backends.hosts = ["c1": terminal]
        setSessions([session("c1", .active, backend: .codex)])
        _ = lastList()
        remote.waitUntilIdle()
        hold("m1", session: "c1")
        XCTAssertEqual(results("m1").last?["reason"] as? String, "not_typable")
        setSessions([session("c1", .idle, backend: .codex)])
        XCTAssertTrue(backends.tries.isEmpty)
    }

    func testNotWhileRateLimitedNorWhileLiveSessionsAreOff() {
        backends.statuses = ["s1": .idle]
        setSessions([session("s1", .rateLimited)])
        hold("c1")
        advance(3)
        XCTAssertTrue(backends.tries.isEmpty, "rate limited: wait for the reset")
        remote.setEnabled(false)
        setSessions([session("s1", .idle)])
        advance(3)
        XCTAssertTrue(backends.tries.isEmpty, "the kill switch stops held typing too")
        remote.setEnabled(true)
        advance(1)
        XCTAssertEqual(backends.tries.count, 1)
    }

    func testTheSessionEndingSettlesItHonestly() throws {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        setSessions([])
        advance(31)
        XCTAssertEqual(results("c1").count, 1, "one tick isn't proof")
        clock.now = clock.now.addingTimeInterval(15)
        setSessions([])
        let final = try XCTUnwrap(results("c1").last)
        XCTAssertEqual(final["reason"] as? String, "ended")
        XCTAssertEqual(final["detail"] as? String, "Not sent — the session ended")
        XCTAssertEqual(final["fromHold"] as? Bool, true)
        XCTAssertTrue(backends.tries.isEmpty)
    }

    func testTheFolderIsCheckedAgainBeforeTyping() throws {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        send(["op": "input", "sessionId": "s1", "text": "go", "hold": true, "clientId": "c1",
              "expectCwd": "~/projects/s1"])
        XCTAssertEqual(results("c1").last?["held"] as? Bool, true)
        backends.statuses = ["s1": .idle]
        let moved = AgentSession(backend: .claude, sessionId: "s1", cwd: NSHomeDirectory() + "/projects/elsewhere", title: "s1",
                                 source: .terminal, state: .idle, lastActivityAt: t0, activeFlags: [], supportsRemoteReply: true)
        setSessions([moved])
        XCTAssertTrue(backends.tries.isEmpty)
        let final = try XCTUnwrap(results("c1").last)
        XCTAssertEqual(final["reason"] as? String, "target_mismatch")
        XCTAssertEqual(final["fromHold"] as? Bool, true)
    }

    // MARK: retract

    func testDeleteWhileHeld() throws {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        send(["op": "retract", "heldId": "c1", "clientId": "r1"])
        let r = try XCTUnwrap(results("r1").last)
        XCTAssertEqual(r["retract"] as? String, "deleted")
        XCTAssertEqual(r["code"] as? String, "delivered")
        XCTAssertEqual(r["detail"] as? String, "Deleted — not sent")
        let final = try XCTUnwrap(results("c1").last)
        XCTAssertEqual(final["code"] as? String, "cancelled")
        XCTAssertEqual(final["ok"] as? Bool, false)
        XCTAssertEqual(final["fromHold"] as? Bool, true)
        backends.statuses = ["s1": .idle]
        advance(3)
        XCTAssertTrue(backends.tries.isEmpty, "never typed")
        XCTAssertEqual(heldRow().first?["state"] as? String, "deleted")
        send(["op": "retract", "heldId": "c1", "clientId": "r2"])
        XCTAssertEqual(results("r2").last?["detail"] as? String, "Already deleted — not sent")
    }

    func testTypedWhileTheDeleteIsInFlightIsTooLateAndNeverBoth() throws {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        // The try reaches its keys (the switch goes to the delivery), then waits.
        backends.typeHeldResult = { claim in XCTAssertTrue(claim.commit()); return nil }
        backends.statuses = ["s1": .idle]
        advance(2)
        let attempt = try XCTUnwrap(backends.parked.first)
        send(["op": "retract", "heldId": "c1", "clientId": "r1"])
        XCTAssertTrue(results("r1").isEmpty, "answered when the try finishes, not before")
        attempt.completion(SessionCommandResult(code: .delivered, reason: nil, detail: "Typed into tmux pane %3"))
        remote.waitUntilIdle()
        XCTAssertEqual(results("r1").last?["retract"] as? String, "too_late")
        XCTAssertEqual(results("r1").last?["reason"] as? String, "too_late")
        let finals = results("c1").filter { $0["fromHold"] as? Bool == true }
        XCTAssertEqual(finals.map { $0["code"] as? String }, ["delivered"], "typed, and not also deleted")
    }

    func testADeleteThatBeatsTheKeysMeansNothingIsTyped() throws {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        backends.typeHeldResult = { _ in nil }   // the try is still checking the session
        backends.statuses = ["s1": .idle]
        advance(2)
        let attempt = try XCTUnwrap(backends.parked.first)
        send(["op": "retract", "heldId": "c1", "clientId": "r1"])
        XCTAssertEqual(results("r1").last?["retract"] as? String, "deleted", "answered at once")
        XCTAssertFalse(attempt.claim.commit(), "the try reaches its keys too late: no key is sent")
        attempt.completion(.refused(.cancelled, HeldOutbox.deletedDetail))
        remote.waitUntilIdle()
        let finals = results("c1").filter { $0["fromHold"] as? Bool == true }
        XCTAssertEqual(finals.map { $0["code"] as? String }, ["cancelled"])
    }

    func testDeleteOfAnUnknownMessage() {
        send(["op": "retract", "heldId": "nope", "clientId": "r1"])
        XCTAssertEqual(results("r1").last?["retract"] as? String, "not_found")
    }

    func testRetractNamesExactlyOneMessage() {
        send(["op": "retract", "clientId": "r1"])
        send(["op": "retract", "heldId": "a", "interventionId": "b", "clientId": "r2"])
        XCTAssertEqual(results("r1").last?["reason"] as? String, "error")
        XCTAssertEqual(results("r2").last?["reason"] as? String, "error")
        XCTAssertTrue(backends.retracted.isEmpty)
    }

    func testRetractOfAReplyGoesToTheBackends() {
        backends.retractAnswer = .deleted(HeldRetract.resetDeletedWithCarryOn)
        send(["op": "retract", "interventionId": "ratelimit-abc", "clientId": "r1"])
        XCTAssertEqual(backends.retracted, ["ratelimit-abc"])
        XCTAssertEqual(results("r1").last?["retract"] as? String, "deleted")
        XCTAssertEqual(results("r1").last?["detail"] as? String, HeldRetract.resetDeletedWithCarryOn)
        backends.retractAnswer = .tooLate(HeldRetract.resetTooLate)
        send(["op": "retract", "interventionId": "ratelimit-abc", "clientId": "r2"])
        XCTAssertEqual(results("r2").last?["retract"] as? String, "too_late")
    }

    func testTheMacPanelDeletesThroughTheSameOp() {
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        var cmd = SessionCommand(op: "retract", clientId: "mac-r", ts: clock.now.timeIntervalSince1970 * 1000, viewer: nil,
                                 sessionId: nil, text: nil)
        cmd.heldId = "c1"
        let done = expectation(description: "deleted")
        remote.performLocal(cmd) { r in
            XCTAssertEqual(r.retract, "deleted")
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(results("c1").last?["code"] as? String, "cancelled", "the phone that sent it hears too")
    }

    // MARK: restarts and pairing

    func testHeldMessagesSurviveARestart() throws {
        let store = dir.appendingPathComponent("held_outbox.json")
        remote.stop()
        remote = makeRemote(store: store)
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        let mode = try FileManager.default.attributesOfItem(atPath: store.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        remote.stop()
        remote.waitUntilIdle()
        remote = makeRemote(store: store)
        XCTAssertEqual(remote.heldMessages().map(\.clientId), ["c1"])
        backends.statuses = ["s1": .idle]
        setSessions([session("s1", .idle)])
        XCTAssertEqual(backends.tries.map(\.clientId), ["c1"])
    }

    func testARestartMidTryNeverRetypes() throws {
        let store = dir.appendingPathComponent("held_outbox.json")
        remote.stop()
        remote = makeRemote(store: store)
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        backends.typeHeldResult = { claim in _ = claim.commit(); return nil }   // Page "quits" mid-try
        backends.statuses = ["s1": .idle]
        advance(2)
        XCTAssertEqual(backends.tries.count, 1)
        remote.stop()
        remote.waitUntilIdle()
        remote = makeRemote(store: store)
        setSessions([session("s1", .idle)])
        advance(10)
        XCTAssertEqual(backends.tries.count, 1, "not typed a second time")
        XCTAssertEqual(heldRow().first?["state"] as? String, "unconfirmed")
    }

    func testANewPairingDropsHeldMessages() {
        let store = dir.appendingPathComponent("held_outbox.json")
        remote.stop()
        remote = makeRemote(store: store)
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        remote.attach(sink: sink, rootKey: Data(repeating: 9, count: 32))
        remote.waitUntilIdle()
        XCTAssertTrue(remote.heldMessages().isEmpty)
        XCTAssertTrue(HeldOutboxStore(url: store).load(now: t0).isEmpty, "and from disk")
    }

    func testThePanelHearsOfChanges() {
        let heard = expectation(description: "changed")
        heard.assertForOverFulfill = false
        remote.onHeldChanged = { heard.fulfill() }
        backends.statuses = ["s1": .busy]
        setSessions([session("s1", .active)])
        hold("c1")
        wait(for: [heard], timeout: 2)
    }

    // MARK: readiness (pure)

    func testReadinessTable() {
        typealias R = SessionRemote
        XCTAssertEqual(R.heldReadiness(backend: .claude, state: .waitingOnUser, fresh: .idle, rateLimitedUntil: nil, now: t0), .ready)
        XCTAssertEqual(R.heldReadiness(backend: .claude, state: .active, fresh: .shell, rateLimitedUntil: nil, now: t0), .ready)
        for s in [ClaudeSessionStatus.busy, .waiting, .unknown] {
            XCTAssertEqual(R.heldReadiness(backend: .claude, state: .idle, fresh: s, rateLimitedUntil: nil, now: t0), .wait)
        }
        XCTAssertEqual(R.heldReadiness(backend: .claude, state: .idle, fresh: nil, rateLimitedUntil: nil, now: t0), .wait)
        XCTAssertEqual(R.heldReadiness(backend: .claude, state: .idle, fresh: .idle, rateLimitedUntil: t0.addingTimeInterval(60), now: t0), .wait)
        XCTAssertEqual(R.heldReadiness(backend: .claude, state: .idle, fresh: .idle, rateLimitedUntil: t0.addingTimeInterval(-1), now: t0), .ready)
        XCTAssertEqual(R.heldReadiness(backend: .claude, state: .rateLimited, fresh: .idle, rateLimitedUntil: nil, now: t0), .wait)
        for s in [AgentSessionState.idle, .interrupted, .failed] {
            XCTAssertEqual(R.heldReadiness(backend: .codex, state: s, fresh: nil, rateLimitedUntil: nil, now: t0), .ready)
        }
        for s in [AgentSessionState.active, .waitingOnApproval, .waitingOnUser, .offline] {
            XCTAssertEqual(R.heldReadiness(backend: .codex, state: s, fresh: nil, rateLimitedUntil: nil, now: t0), .wait)
        }
    }

    func testParseReadsHoldAndRetractTargets() throws {
        let cmd = try XCTUnwrap(SessionCommand.parse(try JSONSerialization.data(withJSONObject: [
            "op": "input", "clientId": "c", "ts": 1, "hold": true, "heldId": "h", "interventionId": "p"])))
        XCTAssertTrue(cmd.hold)
        XCTAssertEqual(cmd.heldId, "h")
        XCTAssertEqual(cmd.interventionId, "p")
        let loose = try XCTUnwrap(SessionCommand.parse(try JSONSerialization.data(withJSONObject: [
            "op": "input", "clientId": "c", "ts": 1, "hold": "yes", "heldId": ""])))
        XCTAssertFalse(loose.hold, "only a JSON true holds")
        XCTAssertNil(loose.heldId)
    }
}
