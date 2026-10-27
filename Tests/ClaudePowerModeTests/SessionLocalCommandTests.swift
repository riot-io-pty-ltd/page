import XCTest
@testable import ClaudePowerMode

/// Commands typed or clicked at this Mac (`SessionRemote.performLocal`): they
/// run through the same code as a phone command, answer the caller once, and
/// never seal or send anything to the relay.
final class SessionLocalCommandTests: XCTestCase {
    private let root = Data((0...31).map { UInt8($0 &* 7) })
    private let t0 = Date(timeIntervalSince1970: 1_761_300_000)

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
        var folders: [SessionStarter.Folder] = []
        var starts: [(folder: String, prompt: String)] = []
        var interrupts: [String] = []
        /// Every `input` the backend was asked to type: (session, text).
        var inputs: [(session: String, text: String)] = []

        func probeHosts(_ sessions: [AgentSession]) -> [String: SessionHostInfo] { [:] }
        func liveStatuses(_ sessions: [AgentSession]) -> [String: ClaudeSessionStatus] { [:] }
        func transcriptFile(for session: AgentSession) -> SessionTranscriptFile? { nil }
        func screenSource(for session: AgentSession) -> SessionScreen.Source? { nil }
        func readScreen(_ source: SessionScreen.Source) -> String? { nil }
        func input(_ session: AgentSession, clientId: String, text: String, interventionId: String?,
                   completion: @escaping (SessionCommandResult) -> Void) {
            inputs.append((session.sessionId, text))
            completion(SessionCommandResult(code: .queued, reason: nil, detail: SessionInputGate.queuedMessage))
        }
        func interrupt(_ session: AgentSession, interventionId: String?,
                       completion: @escaping (SessionCommandResult) -> Void) {
            interrupts.append(session.sessionId)
            completion(SessionCommandResult(code: .delivered, reason: nil, detail: "Pressed Esc"))
        }
        func knownFolders(live: [AgentSession]) -> [SessionStarter.Folder] { folders }
        func startSession(folder: SessionStarter.Folder, prompt: String) -> SessionCommandResult {
            starts.append((folder.path, prompt))
            return SessionCommandResult(code: .delivered, reason: nil, detail: "Started Claude in \(folder.name)")
        }
    }

    private var sink: Sink!
    private var backends: Backends!
    private var remote: SessionRemote!
    private var dir: URL!

    override func setUpWithError() throws {
        sink = Sink()
        backends = Backends()
        let t = t0
        remote = SessionRemote(backends: backends, now: { t }, autoTimer: false, macName: { "Test Mac" })
        remote.attach(sink: sink, rootKey: root)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-local-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        remote?.stop()
        remote?.waitUntilIdle()
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func run(_ cmd: SessionCommand) -> SessionCommandResult? {
        let done = expectation(description: "local command answered")
        var result: SessionCommandResult?
        remote.performLocal(cmd) { r in
            result = r
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return result
    }

    func testParseNeverMarksACommandAsLocal() {
        let json = #"{"op":"interruptAll","clientId":"c1","ts":1761300000000,"local":true}"#
        let cmd = SessionCommand.parse(Data(json.utf8))
        XCTAssertEqual(cmd?.op, "interruptAll")
        XCTAssertEqual(cmd?.local, false, "a phone cannot claim to be local")
    }

    func testInterruptAllWithNothingWorkingAnswersOnceAndSendsNothing() {
        let cmd = SessionCommand(op: "interruptAll", clientId: "local-1", ts: 0, viewer: nil, sessionId: nil, text: nil)
        let r = run(cmd)
        XCTAssertEqual(r?.code, .delivered)
        XCTAssertEqual(r?.detail, "No agents were working")
        remote.waitUntilIdle()
        XCTAssertTrue(sink.sent.isEmpty, "nothing is sealed or sent for a local command")
    }

    func testStartInAKnownFolderReachesTheBackendWithStartOff() {
        backends.folders = [.init(path: dir.path, name: "proj", lastUsedAt: nil)]
        let cmd = SessionCommand(op: "start", clientId: "local-2", ts: 0, viewer: nil, sessionId: nil,
                                 text: "fix the flaky test", folder: dir.path)
        let r = run(cmd)
        XCTAssertEqual(r?.code, .delivered)
        XCTAssertEqual(r?.detail, "Started Claude in proj")
        XCTAssertEqual(backends.starts.count, 1)
        XCTAssertEqual(backends.starts.first?.prompt, "fix the flaky test")
        remote.waitUntilIdle()
        XCTAssertTrue(sink.sent.isEmpty)
    }

    func testStartInAnUnlistedFolderIsRefused() {
        backends.folders = [.init(path: dir.path, name: "proj", lastUsedAt: nil)]
        let cmd = SessionCommand(op: "start", clientId: "local-3", ts: 0, viewer: nil, sessionId: nil,
                                 text: "hello", folder: NSHomeDirectory() + "/not-listed")
        let r = run(cmd)
        XCTAssertEqual(r?.code, .refused)
        XCTAssertTrue(backends.starts.isEmpty)
    }

    func testStartWithAnEmptyPromptStillOpensClaude() {
        backends.folders = [.init(path: dir.path, name: "proj", lastUsedAt: nil)]
        let cmd = SessionCommand(op: "start", clientId: "local-4", ts: 0, viewer: nil, sessionId: nil,
                                 text: "", folder: dir.path)
        XCTAssertEqual(run(cmd)?.code, .delivered)
        XCTAssertEqual(backends.starts.first?.prompt, "")
    }

    // MARK: typing from an In-flight row

    private func working(_ cwd: String) -> AgentSession {
        AgentSession(backend: .claude, sessionId: "sess-page", cwd: cwd, title: nil, source: .terminal,
                     state: .active, lastActivityAt: nil, activeFlags: [], supportsRemoteReply: true)
    }

    func testTypingFromAnInFlightRowReachesTheInputGateAsAPlainMessageAndNeverInterrupts() {
        let s = working("/Users/roy/projects/page")
        remote.update(sessions: [s], pending: [])
        let target = InFlightTarget(session: s)
        let r = run(target.command(text: "also run the Stuck tests", ts: 0))
        XCTAssertEqual(r?.code, .queued)
        XCTAssertEqual(backends.inputs.count, 1)
        XCTAssertEqual(backends.inputs.first?.session, "sess-page")
        XCTAssertEqual(backends.inputs.first?.text, "also run the Stuck tests")
        XCTAssertTrue(backends.interrupts.isEmpty, "typing to a busy session must never press Esc")
        remote.waitUntilIdle()
        XCTAssertTrue(sink.sent.isEmpty, "nothing is sealed or sent for a local command")
    }

    func testTypingIsRefusedWhenTheSessionMovedToAnotherFolder() {
        let shown = working("/Users/roy/projects/page")
        remote.update(sessions: [working("/Users/roy/projects/other")], pending: [])
        let r = run(InFlightTarget(session: shown).command(text: "hello", ts: 0))
        XCTAssertEqual(r?.reason, .targetMismatch)
        XCTAssertTrue(backends.inputs.isEmpty, "nothing is typed into a session that no longer matches the row")
    }

    func testTypingIntoASessionThatHasEndedIsRefusedAndTypesNothing() {
        let r = run(InFlightTarget(session: working("/Users/roy/projects/page")).command(text: "hello", ts: 0))
        XCTAssertEqual(r?.reason, .notFound)
        XCTAssertTrue(backends.inputs.isEmpty)
    }
}
