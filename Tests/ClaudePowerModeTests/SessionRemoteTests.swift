import XCTest
@testable import ClaudePowerMode

/// The Mac side of the live-sessions view (SESSIONS-PROTOCOL.md §4–§5),
/// with the relay socket and the agent backends faked.
final class SessionRemoteTests: XCTestCase {
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

    private final class Backends: SessionRemoteBackends {
        var hosts: [String: SessionHostInfo] = [:]
        var statuses: [String: ClaudeSessionStatus] = [:]
        var files: [String: SessionTranscriptFile] = [:]
        var inputResult = SessionCommandResult(code: .delivered, reason: nil, detail: "Typed into tmux pane %3")
        var inputs: [(sessionId: String, clientId: String, text: String, page: String?)] = []
        var interrupts: [String] = []
        var probes = 0

        func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo] {
            probes += 1
            return hosts.filter { id, _ in sessions.contains { $0.sessionId == id } }
        }
        func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus] { statuses }
        func transcriptFile(for session: AgentSession) -> SessionTranscriptFile? { files[session.sessionId] }
        func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?,
                   completion: @escaping (SessionCommandResult) -> Void) {
            inputs.append((session.sessionId, clientId, text, interventionId))
            completion(inputResult)
        }
        func interrupt(_ session: AgentSession, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
            interrupts.append(session.sessionId)
            completion(SessionCommandResult(code: .delivered, reason: nil, detail: "Pressed Esc in tmux pane %3"))
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
        let c = clock!
        remote = SessionRemote(backends: backends, now: { c.now }, autoTimer: false, macName: { "Test Mac" })
        remote.attach(sink: sink, rootKey: root)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-remote-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        remote?.stop()
        remote?.waitUntilIdle()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    // MARK: helpers

    private func session(_ id: String, _ state: AgentSessionState, backend: AgentBackendID = .claude,
                         at: TimeInterval = 0, cwd: String? = nil) -> AgentSession {
        AgentSession(backend: backend, sessionId: id, cwd: cwd ?? NSHomeDirectory() + "/projects/\(id)", title: id,
                     source: .terminal, state: state, lastActivityAt: t0.addingTimeInterval(at), activeFlags: [],
                     supportsRemoteReply: true)
    }

    private func decoded(_ e: SessionEnvelope) -> [String: Any]? {
        SessionCrypto.open(e, key: keys.macToPhone, aad: SessionCrypto.updateAAD)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private var frames: [[String: Any]] { sink.sent.compactMap(decoded) }
    private func frames(_ kind: String) -> [[String: Any]] { frames.filter { $0["kind"] as? String == kind } }

    private func command(_ fields: [String: Any], key: SymmetricKeyChoice = .phoneToMac, aad: String = SessionCrypto.commandAAD) -> SessionEnvelope {
        var obj = fields
        if obj["ts"] == nil { obj["ts"] = clock.now.timeIntervalSince1970 * 1000 }
        if obj["clientId"] == nil { obj["clientId"] = UUID().uuidString }
        if obj["viewer"] == nil { obj["viewer"] = "v1" }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return SessionCrypto.seal(data, key: key == .phoneToMac ? keys.phoneToMac : keys.macToPhone, aad: aad)!
    }

    private enum SymmetricKeyChoice { case phoneToMac, macToPhone }

    private func send(_ e: SessionEnvelope) {
        remote.handleCommand(e)
        remote.waitUntilIdle()
    }

    private func advance(_ s: TimeInterval) {
        clock.now = clock.now.addingTimeInterval(s)
        remote.step()
    }

    private func lookingPhone() {
        remote.setPhones(1, from: sink)
        remote.waitUntilIdle()
    }

    // MARK: only while someone is looking

    func testNothingIsSentWhileNoPhoneIsLooking() {
        remote.update(sessions: [session("s1", .active)], pending: [])
        remote.step()
        advance(30)
        XCTAssertTrue(sink.sent.isEmpty)
        XCTAssertEqual(backends.probes, 0, "no host probes either")
        // Another client's phone count is ignored.
        remote.setPhones(3, from: Sink())
        remote.waitUntilIdle()
        advance(1)
        XCTAssertTrue(sink.sent.isEmpty)
    }

    func testListThrottleAndLiveness() {
        backends.hosts = ["s1": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: .anthropic)]
        remote.update(sessions: [session("s1", .idle)], pending: [])
        lookingPhone()
        XCTAssertEqual(frames("list").count, 1, "a list as soon as a phone looks")
        XCTAssertEqual(backends.probes, 1)

        // The probe's result changes the list: re-sent, but not within 1 s.
        advance(0.5)
        XCTAssertEqual(frames("list").count, 1)
        advance(0.5)
        XCTAssertEqual(frames("list").count, 2)
        XCTAssertEqual((frames("list").last?["sessions"] as? [[String: Any]])?.first?["host"] as? String, "tmux")

        // Unchanged: nothing until the 20 s liveness refresh.
        advance(5)
        XCTAssertEqual(frames("list").count, 2)
        remote.update(sessions: [session("s1", .active)], pending: [])
        advance(1)
        XCTAssertEqual(frames("list").count, 3, "a change goes out within a second")
        advance(19.5)
        XCTAssertEqual(frames("list").count, 3)
        advance(0.5)
        XCTAssertEqual(frames("list").count, 4, "liveness refresh after 20 s")

        // Phone gone: silence.
        remote.setPhones(0, from: sink)
        remote.waitUntilIdle()
        remote.update(sessions: [session("s1", .idle)], pending: [])
        advance(60)
        XCTAssertEqual(frames("list").count, 4)

        // Disconnected socket also means no phone.
        lookingPhone()
        XCTAssertEqual(frames("list").count, 5)
        remote.connectionChanged(false, from: sink)
        remote.waitUntilIdle()
        advance(30)
        XCTAssertEqual(frames("list").count, 5)
    }

    func testListContentOrderAndFields() throws {
        let page = InterventionEvent(id: "s3-permission-1", sessionId: "s3", cwd: "/x", projectName: "s3", kind: .permission,
                                     openedAt: t0, context: "", transcriptPath: "")
        backends.hosts = [
            "s1": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: .anthropic),
            "s2": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: .ollama),
            "s3": .blocked("Ghostty", "Page can't type into Ghostty yet"),
            "c1": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: .unknown),
        ]
        remote.update(sessions: [
            session("s1", .idle, at: -100),
            session("s2", .active, at: -50),
            session("s3", .waitingOnApproval, at: -500),
            session("s4", .idle, at: -10),
            session("c1", .active, backend: .codex, at: -20),
        ], pending: [page])
        lookingPhone()
        advance(1)
        let list = try XCTUnwrap(frames("list").last)
        XCTAssertEqual(list["macName"] as? String, "Test Mac")
        XCTAssertEqual(list["boot"] as? String, remote.boot)
        XCTAssertNotNil(list["seq"] as? Int)
        XCTAssertEqual(list["ts"] as? Int64, Int64(clock.now.timeIntervalSince1970 * 1000))
        let rows = try XCTUnwrap(list["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["s3", "c1", "s2", "s4", "s1"], "needs-you, then working, then recent")

        let s3 = rows[0]
        XCTAssertEqual(s3["interventionId"] as? String, "s3-permission-1")
        XCTAssertEqual(s3["canType"] as? Bool, false)
        XCTAssertEqual(s3["typeBlocker"] as? String, "Page can't type into Ghostty yet")
        XCTAssertEqual(s3["state"] as? String, "waitingOnApproval")
        XCTAssertEqual(s3["cwd"] as? String, "~/projects/s3", "home-abbreviated")

        let c1 = rows[1]
        XCTAssertEqual(c1["backend"] as? String, "codex")
        XCTAssertEqual(c1["canType"] as? Bool, false, "Codex mid-turn in tmux can't be typed into")
        XCTAssertEqual(c1["typeBlocker"] as? String, SessionInputGate.codexMidTurnMessage)

        let s2 = rows[2]
        XCTAssertEqual(s2["provider"] as? String, "ollama")
        XCTAssertEqual(s2["canType"] as? Bool, true)
        XCTAssertNil(s2["typeBlocker"], "typeBlocker only when canType is false")
        XCTAssertEqual(s2["canInterrupt"] as? Bool, true)
        XCTAssertNotNil(s2["lastActivityAt"] as? String)

        let seqs = frames.compactMap { $0["seq"] as? Int }
        XCTAssertEqual(seqs, seqs.sorted())
        XCTAssertEqual(Set(seqs).count, seqs.count)
    }

    func testFreshClaudeStatusOverridesTheTickSnapshot() throws {
        backends.statuses = ["s1": .busy]
        remote.update(sessions: [session("s1", .idle)], pending: [])
        lookingPhone()
        let rows = try XCTUnwrap(frames("list").last?["sessions"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["state"] as? String, "active")
    }

    func testDisabledSendsAnEmptyListAndRefusesCommands() throws {
        remote.setEnabled(false)
        remote.update(sessions: [session("s1", .idle)], pending: [])
        lookingPhone()
        let list = try XCTUnwrap(frames("list").last)
        XCTAssertEqual((list["sessions"] as? [Any])?.count, 0)
        XCTAssertEqual(list["disabled"] as? Bool, true)
        send(command(["op": "input", "sessionId": "s1", "text": "hi", "clientId": "c-off"]))
        let result = try XCTUnwrap(frames("result").last)
        XCTAssertEqual(result["clientId"] as? String, "c-off")
        XCTAssertEqual(result["reason"] as? String, "disabled")
        XCTAssertTrue(backends.inputs.isEmpty)
    }

    func testListCappedAt100() {
        remote.update(sessions: (0..<130).map { session("s\($0)", .idle, at: Double($0)) }, pending: [])
        lookingPhone()
        let rows = frames("list").last?["sessions"] as? [[String: Any]]
        XCTAssertEqual(rows?.count, 100)
        XCTAssertEqual(rows?.first?["id"] as? String, "s129")
    }

    /// The Worker rejects a `sessions.update` over 256 KiB: the list drops
    /// its least urgent rows until it fits the plaintext budget.
    func testListTrimmedToTheByteBudget() throws {
        let wide = String(repeating: "\u{1F9EA}", count: SessionRemote.maxTitle)   // 4 bytes each
        let rows = (0..<100).map { i in
            RemoteSessionRow(id: "s\(i)", backend: "claude", title: wide, cwd: "~/" + String(repeating: "\u{00E9}/", count: 250),
                             state: .idle, host: .blocked("Ghostty", String(repeating: "\u{2014}", count: 300)),
                             lastActivityAt: t0, interventionId: nil, preview: String(repeating: "\u{1F680}", count: 160))
        }
        let head: [String: Any] = ["kind": "list", "boot": "b", "seq": 1, "ts": 1, "macName": "Test Mac"]
        let full = try JSONSerialization.data(withJSONObject: ["sessions": rows.map(\.jsonObject)])
        XCTAssertGreaterThan(full.count, SessionRemote.maxListPlaintextBytes, "the fixture must overflow")
        let out = try XCTUnwrap(SessionRemote.listPlaintext(header: head, rows: rows))
        XCTAssertLessThanOrEqual(out.data.count, SessionRemote.maxListPlaintextBytes)
        XCTAssertGreaterThan(out.kept, 0)
        XCTAssertLessThan(out.kept, rows.count)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: out.data) as? [String: Any])
        let ids = (obj["sessions"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, rows.prefix(out.kept).map(\.id), "the most urgent rows, in order")
        XCTAssertEqual(obj["macName"] as? String, "Test Mac")
        // Sealed and wrapped, it fits the Worker's frame limit.
        let e = try XCTUnwrap(SessionCrypto.seal(out.data, key: keys.macToPhone, aad: SessionCrypto.updateAAD))
        let frame = try JSONSerialization.data(withJSONObject: ["type": "sessions.update", "payload": ["e": e.jsonObject]])
        XCTAssertLessThanOrEqual(frame.count, 256 * 1024)

        // One row too big on its own: an empty list, never no list.
        let one = try XCTUnwrap(SessionRemote.listPlaintext(header: head, rows: [rows[0]], maxBytes: 1024))
        XCTAssertEqual(one.kept, 0)
        // Small lists are untouched.
        XCTAssertEqual(SessionRemote.listPlaintext(header: head, rows: Array(rows.prefix(3)))?.kept, 3)
    }

    // MARK: acceptance

    func testStaleCommandIsRefused() throws {
        remote.update(sessions: [session("s1", .idle)], pending: [])
        send(command(["op": "input", "sessionId": "s1", "text": "hi", "clientId": "old",
                      "ts": (clock.now.timeIntervalSince1970 - 301) * 1000]))
        send(command(["op": "input", "sessionId": "s1", "text": "hi", "clientId": "future",
                      "ts": (clock.now.timeIntervalSince1970 + 301) * 1000]))
        XCTAssertEqual(frames("result").map { $0["reason"] as? String }, ["stale", "stale"])
        XCTAssertEqual(frames("result").map { $0["clientId"] as? String }, ["old", "future"])
        XCTAssertTrue(backends.inputs.isEmpty)
        // Within ±5 min is fine.
        send(command(["op": "input", "sessionId": "s1", "text": "hi", "ts": (clock.now.timeIntervalSince1970 - 299) * 1000]))
        XCTAssertEqual(backends.inputs.count, 1)
    }

    func testReplayIsDroppedSilently() {
        remote.update(sessions: [session("s1", .idle)], pending: [])
        let e = command(["op": "input", "sessionId": "s1", "text": "hi", "clientId": "once"])
        send(e)
        send(e)
        // A different envelope reusing the id is a replay too.
        send(command(["op": "input", "sessionId": "s1", "text": "again", "clientId": "once"]))
        XCTAssertEqual(backends.inputs.count, 1)
        XCTAssertEqual(frames("result").count, 1)
    }

    func testUndecryptableCommandsAreDroppedSilently() throws {
        remote.update(sessions: [session("s1", .idle)], pending: [])
        let fields: [String: Any] = ["op": "input", "sessionId": "s1", "text": "hi"]
        send(command(fields, key: .macToPhone))                      // reflected Mac key
        send(command(fields, aad: SessionCrypto.updateAAD))          // relabelled
        let other = SessionKeys(root: Data(repeating: 9, count: 32))!
        send(SessionCrypto.seal(try JSONSerialization.data(withJSONObject: fields.merging(["clientId": "x", "ts": 1.0]) { $1 }),
                                key: other.phoneToMac, aad: SessionCrypto.commandAAD)!)
        send(SessionEnvelope(json: ["v": 1, "n": "AAAA", "c": "BBBB"])!)
        send(SessionCrypto.seal(Data("not json".utf8), key: keys.phoneToMac, aad: SessionCrypto.commandAAD)!)
        XCTAssertTrue(sink.sent.isEmpty)
        XCTAssertTrue(backends.inputs.isEmpty)

        // Without a key nothing is accepted at all.
        remote.attach(sink: sink, rootKey: nil)
        send(command(fields))
        XCTAssertTrue(sink.sent.isEmpty)
        XCTAssertTrue(backends.inputs.isEmpty)
    }

    /// A regenerate detaches at once (Coordinator), then attaches the new
    /// key: the old key is dead from the detach on.
    func testDetachCutsTheOldKeyOffAtOnce() {
        remote.update(sessions: [session("s1", .idle)], pending: [])
        lookingPhone()
        let before = sink.sent.count
        remote.attach(sink: nil, rootKey: nil)
        send(command(["op": "input", "sessionId": "s1", "text": "hi"]))
        advance(30)
        XCTAssertEqual(sink.sent.count, before, "nothing sent while detached")
        XCTAssertTrue(backends.inputs.isEmpty)

        let newRoot = Data(repeating: 5, count: 32)
        remote.attach(sink: sink, rootKey: newRoot)
        send(command(["op": "input", "sessionId": "s1", "text": "hi"]))
        XCTAssertTrue(backends.inputs.isEmpty, "the old key stays dead")
        let newKeys = SessionKeys(root: newRoot)!
        let fields: [String: Any] = ["op": "input", "sessionId": "s1", "text": "hi", "clientId": "new",
                                     "ts": clock.now.timeIntervalSince1970 * 1000]
        send(SessionCrypto.seal(try! JSONSerialization.data(withJSONObject: fields), key: newKeys.phoneToMac,
                                aad: SessionCrypto.commandAAD)!)
        XCTAssertEqual(backends.inputs.count, 1)
    }

    func testAcceptanceOrderIsPure() {
        var guardSet = SessionReplayGuard()
        let e = command(["op": "refresh", "clientId": "c1"])
        XCTAssertEqual(SessionRemote.accept(e, keys: nil, enabled: true, now: clock.now, replay: &guardSet), .drop("no session key"))
        guard case .accept(let cmd) = SessionRemote.accept(e, keys: keys, enabled: true, now: clock.now, replay: &guardSet) else {
            return XCTFail("fresh command should be accepted")
        }
        XCTAssertEqual(cmd.op, "refresh")
        XCTAssertEqual(SessionRemote.accept(e, keys: keys, enabled: true, now: clock.now, replay: &guardSet), .drop("replay"))
        // A stale command is refused before the replay check (and not remembered).
        let stale = command(["op": "refresh", "clientId": "c2", "ts": 0])
        guard case .reply(let id, let r) = SessionRemote.accept(stale, keys: keys, enabled: false, now: clock.now, replay: &guardSet) else {
            return XCTFail()
        }
        XCTAssertEqual(id, "c2")
        XCTAssertEqual(r.reason, .stale)
        XCTAssertEqual(guardSet.count, 1)
    }

    func testReplayGuardWindowAndCapacity() {
        var g = SessionReplayGuard()
        XCTAssertTrue(g.admit("a", now: t0))
        XCTAssertFalse(g.admit("a", now: t0.addingTimeInterval(14 * 60)))
        XCTAssertTrue(g.admit("a", now: t0.addingTimeInterval(15 * 60 + 1)), "forgotten after 15 minutes")
        var big = SessionReplayGuard()
        for i in 0..<2100 { XCTAssertTrue(big.admit("id\(i)", now: t0)) }
        XCTAssertEqual(big.count, 2000)
        XCTAssertFalse(big.admit("id2099", now: t0))
    }

    /// A command captured before a restart is still refused after it: the
    /// seen ids survive on disk (0600, ids and times only), and expire.
    func testReplayGuardSurvivesARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("replay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session_replay.json")

        var before = SessionReplayGuard(storeURL: url, now: t0)
        XCTAssertTrue(before.admit("captured", now: t0))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("text"))

        var after = SessionReplayGuard(storeURL: url, now: t0.addingTimeInterval(60))
        XCTAssertFalse(after.admit("captured", now: t0.addingTimeInterval(60)), "replay after restart refused")
        XCTAssertTrue(after.admit("new", now: t0.addingTimeInterval(60)))

        let later = SessionReplayGuard(storeURL: url, now: t0.addingTimeInterval(16 * 60))
        XCTAssertEqual(later.count, 1, "entries older than 15 minutes are dropped on load")

        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(SessionReplayGuard(storeURL: url, now: t0).count, 0, "a corrupt file starts empty")
    }

    // MARK: commands

    func testInputGoesThroughTheBackendAndAlwaysGetsAResult() throws {
        let page = InterventionEvent(id: "s1-idle-5", sessionId: "s1", cwd: "/x", projectName: "s1", kind: .idle,
                                     openedAt: t0, context: "", transcriptPath: "")
        remote.update(sessions: [session("s1", .idle)], pending: [page])
        send(command(["op": "input", "sessionId": "s1", "text": "run the tests", "clientId": "c-in"]))
        XCTAssertEqual(backends.inputs.first?.clientId, "c-in")
        XCTAssertEqual(backends.inputs.first?.text, "run the tests")
        XCTAssertEqual(backends.inputs.first?.page, "s1-idle-5")
        var result = try XCTUnwrap(frames("result").last)
        XCTAssertEqual(result["clientId"] as? String, "c-in")
        XCTAssertEqual(result["code"] as? String, "delivered")
        XCTAssertEqual(result["ok"] as? Bool, true)

        backends.inputResult = .refused(.draft, CmuxBridge.draftDetail)
        send(command(["op": "input", "sessionId": "s1", "text": "x", "clientId": "c-draft"]))
        result = try XCTUnwrap(frames("result").last)
        XCTAssertEqual(result["reason"] as? String, "draft")
        XCTAssertEqual(result["ok"] as? Bool, false)

        // Not in the Mac's current list: the phone's copy is never trusted.
        send(command(["op": "input", "sessionId": "gone", "text": "x", "clientId": "c-gone"]))
        XCTAssertEqual(frames("result").last?["reason"] as? String, "not_found")
        send(command(["op": "input", "sessionId": "s1", "text": "   ", "clientId": "c-empty"]))
        XCTAssertEqual(frames("result").last?["code"] as? String, "refused")
        XCTAssertEqual(backends.inputs.count, 2)
    }

    func testInterruptOnlyForActiveSessionsWhereEscWorks() {
        backends.hosts = ["s2": .blocked("Terminal", "x"),
                          "s3": SessionHostInfo(host: "tmux", canType: true, canInterrupt: true)]
        remote.update(sessions: [session("s1", .idle), session("s2", .active), session("s3", .active)], pending: [])
        lookingPhone()   // probes hosts
        send(command(["op": "interrupt", "sessionId": "s1", "clientId": "i1"]))
        send(command(["op": "interrupt", "sessionId": "s2", "clientId": "i2"]))
        send(command(["op": "interrupt", "sessionId": "s3", "clientId": "i3"]))
        let results = frames("result")
        XCTAssertEqual(results.map { $0["clientId"] as? String }, ["i1", "i2", "i3"])
        XCTAssertEqual(results.map { $0["reason"] as? String }, ["interrupt_unsupported", "interrupt_unsupported", nil])
        XCTAssertEqual(backends.interrupts, ["s3"])
    }

    func testUnknownOpIsIgnored() {
        send(command(["op": "selfDestruct", "sessionId": "s1"]))
        XCTAssertTrue(sink.sent.isEmpty)
    }

    // MARK: transcripts

    private func writeTranscript(_ id: String, _ texts: [String]) -> String {
        let path = dir.appendingPathComponent("\(id).jsonl").path
        let lines = texts.enumerated().map { i, t in
            String(data: try! JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "\(id)-\(i)",
                                                                       "message": ["role": "user", "content": t]]), encoding: .utf8)!
        }
        try! (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        backends.files[id] = SessionTranscriptFile(path: path, format: .claude)
        return path
    }

    func testWatchSendsTheTranscriptAndThenOnlyChanges() throws {
        remote.update(sessions: [session("s1", .active)], pending: [])
        _ = writeTranscript("s1", ["first"])
        lookingPhone()
        send(command(["op": "watch", "sessionId": "s1", "viewer": "v1"]))
        var t = try XCTUnwrap(frames("transcript").last)
        XCTAssertEqual(t["sessionId"] as? String, "s1")
        XCTAssertEqual((t["entries"] as? [[String: Any]])?.map { $0["text"] as? String }, ["first"])
        XCTAssertEqual(t["truncated"] as? Bool, false)
        XCTAssertEqual(frames("result").count, 0, "watch gets no result")

        advance(2)
        XCTAssertEqual(frames("transcript").count, 1, "unchanged: not re-sent")
        _ = writeTranscript("s1", ["first", "second"])
        advance(1.6)
        t = try XCTUnwrap(frames("transcript").last)
        XCTAssertEqual(frames("transcript").count, 2)
        XCTAssertEqual((t["entries"] as? [[String: Any]])?.count, 2)

        // A second phone watching the same session gets it at once.
        send(command(["op": "watch", "sessionId": "s1", "viewer": "v2"]))
        XCTAssertEqual(frames("transcript").count, 3)

        // Both stop viewing: no more transcripts.
        send(command(["op": "watch", "sessionId": NSNull(), "viewer": "v1"]))
        send(command(["op": "watch", "sessionId": NSNull(), "viewer": "v2"]))
        _ = writeTranscript("s1", ["first", "second", "third"])
        advance(2)
        XCTAssertEqual(frames("transcript").count, 3)
    }

    func testWatchExpiresAfter90Seconds() {
        remote.update(sessions: [session("s1", .active)], pending: [])
        _ = writeTranscript("s1", ["a"])
        lookingPhone()
        send(command(["op": "watch", "sessionId": "s1", "viewer": "v1"]))
        XCTAssertEqual(frames("transcript").count, 1)
        advance(91)
        _ = writeTranscript("s1", ["a", "b"])
        advance(2)
        XCTAssertEqual(frames("transcript").count, 1)
    }

    func testRefreshSendsListAndTheViewersTranscript() {
        remote.update(sessions: [session("s1", .active)], pending: [])
        _ = writeTranscript("s1", ["a"])
        lookingPhone()
        send(command(["op": "watch", "sessionId": "s1", "viewer": "v1"]))
        let lists = frames("list").count
        send(command(["op": "refresh", "viewer": "v1"]))
        XCTAssertEqual(frames("list").count, lists + 1)
        XCTAssertEqual(frames("transcript").count, 2)
        XCTAssertEqual(frames("result").count, 0)
    }

    func testTranscriptsNotSentWithoutAPhone() {
        remote.update(sessions: [session("s1", .active)], pending: [])
        _ = writeTranscript("s1", ["a"])
        send(command(["op": "watch", "sessionId": "s1", "viewer": "v1"]))
        advance(5)
        XCTAssertTrue(frames("transcript").isEmpty)
    }

    func testOfflineSinkSendsNothing() {
        sink.isConnected = false
        remote.update(sessions: [session("s1", .idle)], pending: [])
        lookingPhone()
        send(command(["op": "input", "sessionId": "s1", "text": "hi"]))
        XCTAssertTrue(sink.sent.isEmpty)
    }
}

/// Pure pieces of the list (no queues).
final class SessionListPureTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)

    private func row(_ id: String, _ state: AgentSessionState, _ at: TimeInterval?) -> RemoteSessionRow {
        RemoteSessionRow(id: id, backend: "claude", title: id, cwd: nil, state: state, host: .checking,
                         lastActivityAt: at.map { t0.addingTimeInterval($0) }, interventionId: nil, preview: nil)
    }

    func testOrdering() {
        let rows = [row("idle-old", .idle, -100), row("active", .active, -300), row("question", .waitingOnUser, -400),
                    row("idle-new", .idle, -1), row("approval", .waitingOnApproval, -50), row("limited", .rateLimited, nil)]
        XCTAssertEqual(SessionRemote.ordered(rows).map(\.id), ["approval", "question", "active", "idle-new", "idle-old", "limited"])
    }

    func testOverlay() {
        XCTAssertEqual(SessionRemote.overlay(.idle, fresh: .busy), .active)
        XCTAssertEqual(SessionRemote.overlay(.rateLimited, fresh: .busy), .active)
        XCTAssertEqual(SessionRemote.overlay(.idle, fresh: .waiting), .waitingOnApproval)
        XCTAssertEqual(SessionRemote.overlay(.active, fresh: .shell), .idle, "background shell: the prompt is open")
        XCTAssertEqual(SessionRemote.overlay(.waitingOnUser, fresh: .waiting), .waitingOnUser)
        XCTAssertEqual(SessionRemote.overlay(.active, fresh: .idle), .idle)
        XCTAssertEqual(SessionRemote.overlay(.waitingOnUser, fresh: .idle), .waitingOnUser, "an idle page still needs the user")
        XCTAssertEqual(SessionRemote.overlay(.active, fresh: .unknown), .active)
        XCTAssertEqual(SessionRemote.overlay(.active, fresh: nil), .active)
    }

    func testHomeAbbreviation() {
        XCTAssertEqual(SessionRemote.homeAbbreviated("/Users/r/projects/x", home: "/Users/r"), "~/projects/x")
        XCTAssertEqual(SessionRemote.homeAbbreviated("/Users/r", home: "/Users/r"), "~")
        XCTAssertEqual(SessionRemote.homeAbbreviated("/Users/rx/y", home: "/Users/r"), "/Users/rx/y")
        XCTAssertEqual(SessionRemote.homeAbbreviated("/tmp/x", home: "/Users/r"), "/tmp/x")
    }

    func testRowJSON() throws {
        let ok = RemoteSessionRow(id: "s", backend: "claude", title: "t", cwd: "~/p", state: .active,
                                  host: SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: .anthropic),
                                  lastActivityAt: t0, interventionId: nil, preview: "Bash: ls")
        let o = ok.jsonObject
        XCTAssertNil(o["typeBlocker"])
        XCTAssertNil(o["interventionId"])
        XCTAssertEqual(o["provider"] as? String, "anthropic")
        XCTAssertEqual(o["lastActivityAt"] as? String, "2025-10-24T10:00:00Z")
        XCTAssertEqual(o["preview"] as? String, "Bash: ls")
        let blocked = RemoteSessionRow(id: "s", backend: "codex", title: "t", cwd: nil, state: .idle,
                                       host: SessionHostInfo(host: "unknown", canType: false, typeBlocker: nil, canInterrupt: false),
                                       lastActivityAt: nil, interventionId: "p", preview: nil).jsonObject
        XCTAssertNotNil(blocked["typeBlocker"] as? String)
        XCTAssertEqual(blocked["interventionId"] as? String, "p")
        XCTAssertNil(blocked["cwd"])
    }

    func testEffectiveHostForCodexMidTurn() {
        let tmux = SessionHostInfo(host: "tmux", canType: true, canInterrupt: true)
        let cmux = SessionHostInfo(host: "cmux", canType: true, canInterrupt: true)
        XCTAssertFalse(SessionRemote.effectiveHost(tmux, backend: .codex, state: .active).canType)
        XCTAssertTrue(SessionRemote.effectiveHost(cmux, backend: .codex, state: .active).canType)
        XCTAssertTrue(SessionRemote.effectiveHost(tmux, backend: .codex, state: .idle).canType)
        XCTAssertTrue(SessionRemote.effectiveHost(tmux, backend: .claude, state: .active).canType)
    }

    func testSchedule() {
        XCTAssertFalse(SessionsSchedule.listDue(phones: 0, changed: true, lastSentAt: nil, now: t0))
        XCTAssertTrue(SessionsSchedule.listDue(phones: 1, changed: false, lastSentAt: nil, now: t0))
        XCTAssertFalse(SessionsSchedule.listDue(phones: 1, changed: true, lastSentAt: t0, now: t0.addingTimeInterval(0.9)))
        XCTAssertTrue(SessionsSchedule.listDue(phones: 1, changed: true, lastSentAt: t0, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(SessionsSchedule.listDue(phones: 2, changed: false, lastSentAt: t0, now: t0.addingTimeInterval(19)))
        XCTAssertTrue(SessionsSchedule.listDue(phones: 2, changed: false, lastSentAt: t0, now: t0.addingTimeInterval(20)))
        XCTAssertFalse(SessionsSchedule.transcriptDue(phones: 0, lastCheckedAt: nil, now: t0))
        XCTAssertFalse(SessionsSchedule.transcriptDue(phones: 1, lastCheckedAt: t0, now: t0.addingTimeInterval(1.4)))
        XCTAssertTrue(SessionsSchedule.transcriptDue(phones: 1, lastCheckedAt: t0, now: t0.addingTimeInterval(1.5)))
    }

    func testWatchers() {
        var w = SessionWatchers()
        w.set(viewer: "a", sessionId: "s1", now: t0)
        w.set(viewer: "b", sessionId: "s1", now: t0)
        w.set(viewer: "c", sessionId: "s2", now: t0.addingTimeInterval(60))
        XCTAssertEqual(w.watched(now: t0.addingTimeInterval(1)), ["s1", "s2"])
        XCTAssertEqual(w.watched(now: t0.addingTimeInterval(91)), ["s2"])
        w.set(viewer: "c", sessionId: nil, now: t0)
        XCTAssertNil(w.session(forViewer: "c", now: t0))
        for i in 0..<50 { w.set(viewer: "v\(i)", sessionId: "s", now: t0.addingTimeInterval(Double(i))) }
        XCTAssertNil(w.session(forViewer: "v0", now: t0.addingTimeInterval(49)), "bounded: the stalest viewer goes")
        XCTAssertEqual(w.session(forViewer: "v49", now: t0.addingTimeInterval(49)), "s")
    }

    func testCommandParsing() {
        func parse(_ o: [String: Any]) -> SessionCommand? { SessionCommand.parse(try! JSONSerialization.data(withJSONObject: o)) }
        XCTAssertNil(parse(["op": "input", "ts": 1]), "no clientId")
        XCTAssertNil(parse(["op": "input", "clientId": "", "ts": 1]))
        XCTAssertNil(parse(["op": "input", "clientId": "c", "ts": "soon"]))
        XCTAssertNil(parse(["clientId": "c", "ts": 1]))
        XCTAssertEqual(parse(["op": "watch", "clientId": "c", "ts": 1, "sessionId": NSNull(), "viewer": "v", "extra": true]),
                       SessionCommand(op: "watch", clientId: "c", ts: 1, viewer: "v", sessionId: nil, text: nil))
    }
}

/// Where a session runs, as the list reports it.
final class SessionHostMappingTests: XCTestCase {
    private let cmuxTarget = CmuxBridge.Target(surfaceId: "5FA66D62-4F2B-4F19-90BE-80319216DE70", workspaceId: nil,
                                               cliPath: "/Applications/cmux.app/Contents/Resources/bin/cmux", source: "environment")

    func testClaudeHosts() {
        typealias L = LiveSessionBackends
        XCTAssertEqual(L.claudeHostInfo(.tmux(tmuxPath: "/t", paneId: "%1", inMode: false), provider: .anthropic),
                       SessionHostInfo(host: "tmux", canType: true, canInterrupt: true, provider: .anthropic))
        XCTAssertEqual(L.claudeHostInfo(.terminalApp(tty: "/dev/ttys1"), provider: .unknown).canInterrupt, false,
                       "Terminal.app can't press a lone Esc")
        XCTAssertTrue(L.claudeHostInfo(.terminalApp(tty: "/dev/ttys1"), provider: .unknown).canType)
        XCTAssertEqual(L.claudeHostInfo(.iTerm(tty: "/dev/ttys1"), provider: .unknown).host, "iTerm")
        XCTAssertEqual(L.claudeHostInfo(.cmux(cmuxTarget), provider: .unknown).host, "cmux")
        let ghostty = L.claudeHostInfo(.unsupported("Ghostty"), provider: .unknown)
        XCTAssertEqual(ghostty.host, "Ghostty")
        XCTAssertFalse(ghostty.canType)
        XCTAssertEqual(ghostty.typeBlocker, "Page can't type into Ghostty yet")
        XCTAssertEqual(L.claudeHostInfo(.unsupported("Warp"), provider: .unknown).host, "unknown")
        XCTAssertEqual(L.claudeHostInfo(.unsupported("VS Code"), provider: .unknown).host, "VS Code")
        XCTAssertEqual(L.claudeHostInfo(.unreachable(CmuxBridge.paneNotFoundDetail), provider: .unknown).typeBlocker,
                       CmuxBridge.paneNotFoundDetail)
    }

    func testClaudeCandidates() {
        let a = ClaudeLiveSession(pid: 1, sessionId: "s", cwd: nil, status: .idle, statusUpdatedAt: nil, tty: "ttys1", hasSessionFile: true)
        let b = ClaudeLiveSession(pid: 2, sessionId: "s", cwd: nil, status: .idle, statusUpdatedAt: nil, tty: "ttys2", hasSessionFile: true)
        let headless = ClaudeLiveSession(pid: 3, sessionId: "s", cwd: nil, status: .idle, statusUpdatedAt: nil, tty: nil, hasSessionFile: true)
        let tmux = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/t", paneId: "%1", inMode: false)
        XCTAssertFalse(LiveSessionBackends.claudeHost(candidates: [], table: [], resolveHost: { _, _ in tmux }).canType)
        XCTAssertTrue(LiveSessionBackends.claudeHost(candidates: [a], table: [], resolveHost: { _, _ in tmux }).canType)
        XCTAssertFalse(LiveSessionBackends.claudeHost(candidates: [a, b], table: [], resolveHost: { _, _ in tmux }).canType,
                       "open in two terminals: can't tell which")
        XCTAssertFalse(LiveSessionBackends.claudeHost(candidates: [headless], table: [], resolveHost: { _, _ in tmux }).canType)
    }

    func testCodexHosts() {
        typealias L = LiveSessionBackends
        XCTAssertTrue(L.codexHost(.tmux(pane: "%1"), appHost: .tmux, provider: .unknown).canType)
        XCTAssertTrue(L.codexHost(.cmux(cmuxTarget), appHost: .app("cmux"), provider: .unknown).canInterrupt)
        let terminal = L.codexHost(.terminalApp(tty: "/dev/ttys1"), appHost: .terminalApp, provider: .unknown)
        XCTAssertEqual(terminal.host, "Terminal")
        XCTAssertFalse(terminal.canType, "its composer can't be verified empty")
        let gone = L.codexHost(.unavailable(CodexInjector.notForegroundDetail), appHost: .app("Ghostty"), provider: .unknown)
        XCTAssertEqual(gone.host, "Ghostty")
        XCTAssertEqual(gone.typeBlocker, CodexInjector.notForegroundDetail)
        XCTAssertEqual(L.codexHostForSource(.desktop, provider: .unknown)?.host, "desktop")
        XCTAssertEqual(L.codexHostForSource(.vscode, provider: .unknown)?.host, "VS Code")
        XCTAssertFalse(L.codexHostForSource(.exec, provider: .unknown)?.canType ?? true)
        XCTAssertNil(L.codexHostForSource(.terminal, provider: .unknown))
        XCTAssertEqual(L.wireHost(app: "cmux NEXT"), "cmux")
        XCTAssertEqual(L.wireHost(app: "iTerm2"), "iTerm")
    }
}
