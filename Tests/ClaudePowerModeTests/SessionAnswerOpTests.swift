import XCTest
@testable import ClaudePowerMode

/// The `answer` op and the list row's `ask` field (SESSIONS-PROTOCOL.md §4, §6),
/// through `SessionRemote` with the relay socket and the backends faked.
final class SessionAnswerOpTests: XCTestCase {
    private let root = Data((0...31).map { UInt8($0 &* 7) })
    private lazy var keys = SessionKeys(root: root)!
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)

    private final class Sink: SessionsUpdateSink {
        private let lock = NSLock()
        private var _sent: [SessionEnvelope] = []
        var isConnected = true
        var sent: [SessionEnvelope] { lock.lock(); defer { lock.unlock() }; return _sent }
        func sendSessionsUpdate(_ envelope: SessionEnvelope) { lock.lock(); _sent.append(envelope); lock.unlock() }
    }

    private final class Backends: SessionRemoteBackends {
        var files: [String: SessionTranscriptFile] = [:]
        var answers: [(sessionId: String, request: AnswerRequest)] = []
        var answerResult = SessionCommandResult(code: .delivered, reason: nil, detail: "Answered 2 questions in tmux pane %3")
        /// Where every session runs, by id (tmux unless a test says otherwise).
        var hostFor: [String: SessionHostInfo] = [:]
        func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo] {
            Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, hostFor[$0.sessionId] ?? SessionHostInfo(host: "tmux", canType: true, canInterrupt: true)) })
        }
        func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus] { [:] }
        func transcriptFile(for session: AgentSession) -> SessionTranscriptFile? { files[session.sessionId] }
        func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?,
                   completion: @escaping (SessionCommandResult) -> Void) { completion(.refused(.notTypable, "n/a")) }
        func interrupt(_ session: AgentSession, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {
            completion(.refused(.notTypable, "n/a"))
        }
        func answer(_ session: AgentSession, request: AnswerRequest, completion: @escaping (SessionCommandResult) -> Void) {
            answers.append((session.sessionId, request))
            completion(answerResult)
        }
    }

    private var held = Set<String>()
    private var clock = Date(timeIntervalSince1970: 1_761_300_000)
    private var sink: Sink!
    private var backends: Backends!
    private var remote: SessionRemote!
    private var dir: URL!

    override func setUpWithError() throws {
        sink = Sink()
        backends = Backends()
        clock = t0
        remote = SessionRemote(backends: backends, now: { [unowned self] in self.clock }, autoTimer: false, macName: { "Test Mac" }, heldSessions: { [unowned self] in self.held })
        remote.attach(sink: sink, rootKey: root)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-answer-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        remote?.stop()
        remote?.waitUntilIdle()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func session(_ id: String, _ state: AgentSessionState, backend: AgentBackendID = .claude) -> AgentSession {
        AgentSession(backend: backend, sessionId: id, cwd: NSHomeDirectory() + "/projects/\(id)", title: id, source: .terminal,
                     state: state, lastActivityAt: t0, activeFlags: [], supportsRemoteReply: true)
    }

    /// A transcript whose last record is an assistant AskUserQuestion with no result yet.
    private func pendingQuestionTranscript(extraPending: Bool = false) throws -> SessionTranscriptFile {
        var content: [[String: Any]] = [["type": "tool_use", "id": "toolu_q", "name": "AskUserQuestion",
            "input": ["questions": [["question": "Pick a color", "header": "Color", "multiSelect": false,
                                     "options": [["label": "Red", "description": "warm"], ["label": "Green", "description": ""]]]]]]]
        if extraPending { content.append(["type": "tool_use", "id": "toolu_b", "name": "Bash", "input": ["command": "ls"]]) }
        let line: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": content]]
        let url = dir.appendingPathComponent("t-\(UUID().uuidString.prefix(6)).jsonl")
        try (String(data: try JSONSerialization.data(withJSONObject: line), encoding: .utf8)! + "\n").write(to: url, atomically: true, encoding: .utf8)
        return SessionTranscriptFile(path: url.path, format: .claude)
    }

    private func decoded(_ e: SessionEnvelope) -> [String: Any]? {
        SessionCrypto.open(e, key: keys.macToPhone, aad: SessionCrypto.updateAAD)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    private func rows() throws -> [[String: Any]] {
        remote.setPhones(1, from: sink)
        remote.waitUntilIdle()
        // The first list goes out before the terminals are probed; the next one knows them.
        clock = clock.addingTimeInterval(10)
        remote.step()
        remote.waitUntilIdle()
        let list = try XCTUnwrap(sink.sent.compactMap(decoded).last { $0["kind"] as? String == "list" })
        return try XCTUnwrap(list["sessions"] as? [[String: Any]])
    }

    private func run(_ cmd: SessionCommand) -> SessionCommandResult? {
        let done = expectation(description: "answered")
        var result: SessionCommandResult?
        remote.performLocal(cmd) { r in result = r; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result
    }

    private func answerCommand(session id: String = "s1", promptKey: String? = "toolu_q", answers: [AnswerPick]? = [AnswerPick(question: 0, picks: [1], other: nil)],
                               expectCwd: String? = nil) -> SessionCommand {
        var c = SessionCommand(op: "answer", clientId: "c-\(UUID().uuidString.prefix(6))", ts: t0.timeIntervalSince1970 * 1000, viewer: "v1", sessionId: id, text: nil)
        c.promptKey = promptKey
        c.answers = answers
        c.expectCwd = expectCwd
        return c
    }

    // MARK: the ask on the row

    func testAWaitingSessionWithAPendingQuestionCarriesIt() throws {
        backends.files["s1"] = try pendingQuestionTranscript()
        remote.update(sessions: [session("s1", .waitingOnUser)], pending: [])
        let row = try XCTUnwrap(rows().first)
        let ask = try XCTUnwrap(row["ask"] as? [String: Any])
        XCTAssertEqual(ask["id"] as? String, "toolu_q")
        let q = try XCTUnwrap((ask["questions"] as? [[String: Any]])?.first)
        XCTAssertEqual(q["question"] as? String, "Pick a color")
        XCTAssertEqual((q["options"] as? [[String: Any]])?.map { $0["label"] as? String }, ["Red", "Green"])
    }

    func testNoAskWhenNotWaitingOrWhenOtherToolsArePendingToo() throws {
        backends.files["s1"] = try pendingQuestionTranscript()
        backends.files["s2"] = try pendingQuestionTranscript(extraPending: true)
        remote.update(sessions: [session("s1", .active), session("s2", .waitingOnApproval)], pending: [])
        let all = try rows()
        XCTAssertNil(all.first { $0["id"] as? String == "s1" }?["ask"], "an active session has no dialog on screen")
        XCTAssertNil(all.first { $0["id"] as? String == "s2" }?["ask"], "several pending calls: which prompt is showing is unclear")
    }

    func testASessionHeldByPagesHookCarriesTheAskToo() throws {
        // The hook holds the tool: no dialog, the session reads "active". The phone answers that page by text.
        backends.files["s1"] = try pendingQuestionTranscript()
        backends.files["s2"] = try pendingQuestionTranscript()
        held = ["s1"]
        remote.update(sessions: [session("s1", .active), session("s2", .active)], pending: [])
        let all = try rows()
        XCTAssertEqual((all.first { $0["id"] as? String == "s1" }?["ask"] as? [String: Any])?["id"] as? String, "toolu_q")
        XCTAssertNil(all.first { $0["id"] as? String == "s2" }?["ask"], "an active session no hook holds has no question")
    }

    func testNoAskWhenPageCannotPressKeysThere() throws {
        // Terminal.app, a paused Squad instance, an unsupported terminal: the phone keeps "Tell it instead"
        // rather than offer a picker whose Submit would always be refused. Every measured terminal carries it.
        for id in ["cmux1", "term1", "blocked1", "ghostty1", "tmux1"] { backends.files[id] = try pendingQuestionTranscript() }
        backends.hostFor["cmux1"] = SessionHostInfo(host: "cmux", canType: true, canInterrupt: true)
        backends.hostFor["term1"] = SessionHostInfo(host: "Terminal", canType: true, canInterrupt: false)
        backends.hostFor["blocked1"] = .blocked(ClaudeSquad.hostName, ClaudeSquad.pausedMessage)
        backends.hostFor["ghostty1"] = .blocked("Ghostty", "Page can't type into Ghostty yet")
        remote.update(sessions: ["cmux1", "term1", "blocked1", "ghostty1", "tmux1"].map { session($0, .waitingOnUser) }, pending: [])
        let all = try rows()
        for id in ["term1", "blocked1", "ghostty1"] { XCTAssertNil(all.first { $0["id"] as? String == id }?["ask"], id) }
        for id in ["cmux1", "tmux1"] { XCTAssertNotNil(all.first { $0["id"] as? String == id }?["ask"], id) }
    }

    func testAHookHeldQuestionKeepsItsAskOnAnyTerminal() throws {
        // The hook maps the numbers itself; nothing is pressed, so the terminal doesn't matter.
        backends.files["s1"] = try pendingQuestionTranscript()
        backends.hostFor["s1"] = SessionHostInfo(host: "cmux", canType: true, canInterrupt: true)
        held = ["s1"]
        remote.update(sessions: [session("s1", .active)], pending: [])
        XCTAssertNotNil(try rows().first?["ask"])
    }

    func testNoAskForCodex() throws {
        backends.files["c1"] = try pendingQuestionTranscript()
        remote.update(sessions: [session("c1", .waitingOnUser, backend: .codex)], pending: [])
        XCTAssertNil(try rows().first?["ask"])
    }

    // MARK: the answer op

    func testAnswerReachesTheBackendWithTheRequest() throws {
        remote.update(sessions: [session("s1", .waitingOnUser)], pending: [])
        let r = try XCTUnwrap(run(answerCommand()))
        XCTAssertEqual(r.code, .delivered)
        XCTAssertEqual(backends.answers.count, 1)
        XCTAssertEqual(backends.answers[0].request, AnswerRequest(promptKey: "toolu_q", answers: [AnswerPick(question: 0, picks: [1], other: nil)]))
    }

    func testAnswerRefusalsNeverReachTheBackend() throws {
        remote.update(sessions: [session("s1", .waitingOnUser), session("c1", .waitingOnUser, backend: .codex)], pending: [])
        XCTAssertEqual(run(answerCommand(session: "nope"))?.reason, .notFound)
        XCTAssertEqual(run(answerCommand(promptKey: nil))?.reason, .answerUnsupported)
        XCTAssertEqual(run(answerCommand(answers: nil))?.reason, .answerUnsupported)
        XCTAssertEqual(run(answerCommand(session: "c1"))?.reason, .answerUnsupported, "Codex questions aren't answered by keys")
        XCTAssertEqual(run(answerCommand(expectCwd: "~/projects/some-other-folder"))?.reason, .targetMismatch,
                       "the room showed another folder: nothing is pressed")
        XCTAssertTrue(backends.answers.isEmpty)
    }

    func testDefaultBackendRefusesAnswers() {
        final class Bare: SessionRemoteBackends {
            func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo] { [:] }
            func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus] { [:] }
            func transcriptFile(for session: AgentSession) -> SessionTranscriptFile? { nil }
            func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {}
            func interrupt(_ session: AgentSession, interventionId: String?, completion: @escaping (SessionCommandResult) -> Void) {}
        }
        var got: SessionCommandResult?
        Bare().answer(session("s1", .waitingOnUser), request: AnswerRequest(promptKey: "k", answers: []), completion: { got = $0 })
        XCTAssertEqual(got?.reason, .answerUnsupported)
    }

    func testResultFieldsCarryTheNewReasons() {
        let f = SessionCommandResult.refused(.questionChanged, "That question changed").fields(clientId: "c")
        XCTAssertEqual(f["reason"] as? String, "question_changed")
        XCTAssertEqual(f["ok"] as? Bool, false)
        XCTAssertEqual(SessionCommandResult.refused(.answerUnsupported, "x").fields(clientId: "c")["reason"] as? String, "answer_unsupported")
    }
}
