import XCTest
@testable import ClaudePowerMode

final class StuckWatchTests: XCTestCase {
    private let sid = "11111111-2222-3333-4444-555555555555"

    private func ts(_ seconds: Int) -> String {
        let f = ISO8601DateFormatter()
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + seconds)))
    }

    private func user(_ text: String, at s: Int) -> String {
        #"{"type":"user","timestamp":"\#(ts(s))","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func call(_ id: String, _ name: String, _ input: String, at s: Int) -> String {
        #"{"type":"assistant","timestamp":"\#(ts(s))","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }

    private func result(_ id: String, error: Bool, at s: Int) -> String {
        #"{"type":"user","timestamp":"\#(ts(s))","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","is_error":\#(error),"content":"x"}]}}"#
    }

    private func bash(_ cmd: String) -> String { #"{"command":"\#(cmd)","description":"d"}"# }

    // MARK: TurnDigest

    func testDigestStartsAtTheLastUserMessage() {
        let text = [
            user("first", at: 0),
            call("a", "Bash", bash("ls"), at: 1), result("a", error: false, at: 2),
            user("second", at: 10),
            call("b", "Edit", #"{"file_path":"/p/x.swift","old_string":"a","new_string":"b"}"#, at: 11),
            result("b", error: false, at: 12),
            call("c", "Bash", bash("swift test"), at: 13), result("c", error: true, at: 14),
            call("d", "Write", #"{"file_path":"/p/y.swift","content":"z"}"#, at: 15),
        ].joined(separator: "\n")
        let d = TurnDigest.parse(text)
        XCTAssertFalse(d.truncated)
        XCTAssertEqual(d.turnStartedAt, Date(timeIntervalSince1970: 1_800_000_010))
        XCTAssertEqual(d.steps.map(\.id), ["b", "c", "d"])
        XCTAssertEqual(d.steps.map(\.failed), [false, true, nil])
        XCTAssertEqual(d.filesTouched, ["/p/x.swift", "/p/y.swift"])
        XCTAssertEqual(d.lastTestRun?.passed, false)
        XCTAssertEqual(d.lastTestRun?.label, "[Bash] swift test")
    }

    func testDigestIgnoresSidechainAndMetaRecords() {
        let side = #"{"type":"user","isSidechain":true,"message":{"content":"sub"}}"#
        let meta = #"{"type":"user","isMeta":true,"message":{"content":"caveat"}}"#
        let text = [user("go", at: 0), call("a", "Bash", bash("ls"), at: 1), side, meta].joined(separator: "\n")
        XCTAssertEqual(TurnDigest.parse(text).steps.map(\.id), ["a"])
    }

    func testDigestWithoutAUserMessageIsTruncated() {
        let d = TurnDigest.parse(call("a", "Bash", bash("ls"), at: 1))
        XCTAssertTrue(d.truncated)
        XCTAssertNil(d.turnStartedAt)
    }

    func testBashKeyIgnoresDescriptionAndSpacing() {
        let a = TurnDigest.step(id: "1", name: "Bash", input: ["command": "swift  build", "description": "one"], at: nil)
        let b = TurnDigest.step(id: "2", name: "Bash", input: ["command": "swift build", "description": "two"], at: nil)
        XCTAssertEqual(a.key, b.key)
    }

    func testStepLabelIsRedacted() {
        let s = TurnDigest.step(id: "1", name: "Bash",
                                input: ["command": "curl -H 'Authorization: Bearer sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789'"], at: nil)
        XCTAssertFalse(s.label.contains("abcdefghijklmnop"), s.label)
    }

    func testLooksLikeTests() {
        for cmd in ["swift test", "cd x && swift test --filter Foo", "npm test", "pnpm run test:unit", "pytest -q",
                    "python3 -m pytest tests", "go test ./...", "cargo test", "./gradlew test",
                    "xcodebuild -scheme Page -destination x test", "iOS/Tests/run-logic-tests.sh"] {
            XCTAssertTrue(TurnDigest.looksLikeTests(cmd), cmd)
        }
        for cmd in ["swift build", "xcodebuild -scheme Page build", "ls tests", "cat test.txt", "git status"] {
            XCTAssertFalse(TurnDigest.looksLikeTests(cmd), cmd)
        }
    }

    // MARK: looping

    private func steps(_ spec: [(String, Bool?)]) -> [TurnDigest.Step] {
        spec.enumerated().map { i, s in
            TurnDigest.Step(id: "\(i)", name: "Bash", key: "Bash:" + s.0, label: "[Bash] " + s.0, failed: s.1,
                            at: Date(timeIntervalSince1970: TimeInterval(1000 + i)), filePath: nil, command: s.0)
        }
    }

    func testThreeIdenticalFailuresInARowIsALoop() {
        let f = StuckWatch.looping(steps([("ls", false), ("make", true), ("make", true), ("make", true)]),
                                   settings: .init())
        XCTAssertEqual(f, .looping(label: "[Bash] make", count: 3, since: Date(timeIntervalSince1970: 1001)))
    }

    func testTwoFailuresIsNotALoop() {
        XCTAssertNil(StuckWatch.looping(steps([("make", true), ("make", true)]), settings: .init()))
    }

    func testALoopEndsWhenTheCallSucceeds() {
        XCTAssertNil(StuckWatch.looping(steps([("make", true), ("make", true), ("make", true), ("make", false)]),
                                        settings: .init()))
    }

    func testAPendingCallAfterTheStreakStillCounts() {
        let f = StuckWatch.looping(steps([("make", true), ("make", true), ("make", true), ("make", nil)]),
                                   settings: .init())
        XCTAssertNotNil(f)
    }

    func testFixRetestCycleFailingFiveTimesIsALoop() {
        var spec: [(String, Bool?)] = []
        for _ in 0..<5 { spec += [("edit", false), ("swift test", true)] }
        XCTAssertEqual(StuckWatch.looping(steps(spec), settings: .init()),
                       .looping(label: "[Bash] swift test", count: 5, since: Date(timeIntervalSince1970: 1001)))
    }

    func testFixRetestCycleFailingFourTimesIsNot() {
        var spec: [(String, Bool?)] = []
        for _ in 0..<4 { spec += [("edit", false), ("swift test", true)] }
        XCTAssertNil(StuckWatch.looping(steps(spec), settings: .init()))
    }

    // MARK: quiet

    func testQuietBusySessionIsStuck() {
        let now = Date(timeIntervalSince1970: 10_000)
        let d = TurnDigest(turnStartedAt: nil, steps: steps([("ls", false), ("npm run build", nil)]), truncated: false)
        let f = StuckWatch.evaluateBusy(digest: d, statusUpdatedAt: now.addingTimeInterval(-3600),
                                        lastProgressAt: now.addingTimeInterval(-16 * 60), now: now, settings: .init())
        XCTAssertEqual(f, .quiet(lastStep: "[Bash] npm run build", since: now.addingTimeInterval(-16 * 60)))
        XCTAssertEqual(StuckWatch.context(for: f!, now: now), "No progress for 16 min — it may be hung.\nLast step: [Bash] npm run build")
    }

    func testRecentProgressIsNotStuck() {
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(StuckWatch.evaluateBusy(digest: nil, statusUpdatedAt: now.addingTimeInterval(-3600),
                                             lastProgressAt: now.addingTimeInterval(-60), now: now, settings: .init()))
    }

    func testAFreshTurnIsNotStuckEvenIfTheFileIsOld() {
        // The transcript is old because the turn only just started.
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertNil(StuckWatch.evaluateBusy(digest: nil, statusUpdatedAt: now.addingTimeInterval(-30),
                                             lastProgressAt: now.addingTimeInterval(-3600), now: now, settings: .init()))
    }

    func testLoopWinsOverQuiet() {
        let now = Date(timeIntervalSince1970: 10_000)
        let d = TurnDigest(turnStartedAt: nil, steps: steps([("make", true), ("make", true), ("make", true)]), truncated: false)
        let f = StuckWatch.evaluateBusy(digest: d, statusUpdatedAt: .distantPast,
                                        lastProgressAt: now.addingTimeInterval(-3600), now: now, settings: .init())
        XCTAssertEqual(f?.subtype, "looping")
    }

    // MARK: workflows

    private func run(status: String, last: Date?) -> WorkflowRunInfo {
        WorkflowRunInfo(id: "wf_1", name: "review", summary: nil, status: status, phase: nil, done: 2, total: 5,
                        startedAt: Date(timeIntervalSince1970: 0), endedAt: nil, tokens: nil,
                        agents: [.init(id: "a", label: "x", phase: nil, state: "stopped", lastActivityAt: last)])
    }

    func testStalledWorkflowPages() {
        let now = Date(timeIntervalSince1970: 100_000)
        let f = StuckWatch.evaluateWorkflows([run(status: "stalled", last: now.addingTimeInterval(-25 * 60))], now: now, settings: .init())
        XCTAssertEqual(f, .workflowStalled(runId: "wf_1", name: "review", done: 2, total: 5, since: now.addingTimeInterval(-25 * 60)))
        XCTAssertEqual(StuckWatch.context(for: f!, now: now),
                       "Workflow review stopped making progress: nothing written for 25 min (2/5 agents done).")
    }

    func testAbandonedOrRunningWorkflowsDoNot() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertNil(StuckWatch.evaluateWorkflows([run(status: "stalled", last: now.addingTimeInterval(-5 * 3600))], now: now, settings: .init()))
        XCTAssertNil(StuckWatch.evaluateWorkflows([run(status: "running", last: now)], now: now, settings: .init()))
        XCTAssertNil(StuckWatch.evaluateWorkflows([run(status: "completed", last: now)], now: now, settings: .init()))
    }

    // MARK: pages

    func testPageShapeAndIdRoundTrip() {
        let session = ClaudeLiveSession(pid: 42, sessionId: sid, cwd: "/tmp/proj", status: .busy,
                                        statusUpdatedAt: Date(timeIntervalSince1970: 5), tty: "ttys001", hasSessionFile: true)
        let since = Date(timeIntervalSince1970: 1_800_000_000)
        let page = StuckWatch.page(for: .looping(label: "[Bash] make", count: 3, since: since), session: session,
                                   cwd: "/tmp/proj", transcriptPath: "/t.jsonl", now: since.addingTimeInterval(60))
        XCTAssertEqual(page.id, "\(sid)-looping-1800000000")
        XCTAssertEqual(page.kind, .idle)
        XCTAssertEqual(page.subtype, "looping")
        XCTAssertEqual(page.pid, 42)
        XCTAssertTrue(StuckWatch.isStuckId(page.id))
        XCTAssertEqual(InterventionDetector.parseInterventionId(page.id)?.sessionId, sid)
        XCTAssertFalse(StuckWatch.isStuckId("\(sid)-idle-1800000000"))
        let wf = StuckWatch.page(for: .workflowStalled(runId: "wf_1", name: "n", done: 0, total: 1, since: since),
                                 session: session, cwd: "/tmp/proj", transcriptPath: "", now: since)
        XCTAssertEqual(InterventionDetector.parseInterventionId(wf.id)?.kind, "workflow_stalled")
    }

    // MARK: monitor (files on disk)

    func testMonitorOpensKeepsAndResolvesALoopPage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stuck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(sid).jsonl")
        var lines = [user("go", at: 0)]
        for i in 0..<3 { lines += [call("c\(i)", "Bash", bash("make"), at: 1 + i * 2), result("c\(i)", error: true, at: 2 + i * 2)] }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)

        let session = ClaudeLiveSession(pid: 7, sessionId: sid, cwd: dir.path, status: .busy,
                                        statusUpdatedAt: Date(), tty: nil, hasSessionFile: true)
        let m = StuckMonitor()
        let first = m.scan(sessions: [session], transcripts: [sid: url], blocked: [], settings: .init())
        XCTAssertEqual(first.opened.map(\.subtype), ["looping"])
        let again = m.scan(sessions: [session], transcripts: [sid: url], blocked: [], settings: .init())
        XCTAssertTrue(again.opened.isEmpty && again.resolved.isEmpty)
        // Blocked by another page: resolves rather than superseding it.
        let blocked = m.scan(sessions: [session], transcripts: [sid: url], blocked: [sid], settings: .init())
        XCTAssertEqual(blocked.resolved.map(\.id), first.opened.map(\.id))

        _ = m.scan(sessions: [session], transcripts: [sid: url], blocked: [], settings: .init())
        lines += [call("ok", "Bash", bash("make"), at: 20), result("ok", error: false, at: 21)]
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        let fixed = m.scan(sessions: [session], transcripts: [sid: url], blocked: [], settings: .init())
        XCTAssertEqual(fixed.resolved.count, 1)
        XCTAssertTrue(m.pages.isEmpty)
        // Gone sessions resolve too.
        _ = m.reset()
    }
}
