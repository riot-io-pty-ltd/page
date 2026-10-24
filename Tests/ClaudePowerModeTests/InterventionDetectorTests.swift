import XCTest
@testable import ClaudePowerMode

/// Builders for transcript JSONL lines (the shapes Claude Code 2.1 writes).
enum TranscriptFixture {
    static func json(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
    }
    static func user(_ text: String, cwd: String = "/Users/me/proj", ts: String = "2026-10-24T10:00:00.000Z") -> String {
        json(["type": "user", "cwd": cwd, "timestamp": ts, "isSidechain": false,
              "message": ["role": "user", "content": text]])
    }
    static func assistantText(_ text: String, ts: String = "2026-10-24T10:00:05.000Z") -> String {
        json(["type": "assistant", "timestamp": ts, "isSidechain": false,
              "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }
    static func toolUse(_ id: String, _ name: String, _ input: [String: Any], sidechain: Bool = false) -> String {
        json(["type": "assistant", "timestamp": "2026-10-24T10:00:06.000Z", "isSidechain": sidechain,
              "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name, "input": input]]]])
    }
    static func toolResult(_ id: String) -> String {
        json(["type": "user", "timestamp": "2026-10-24T10:00:07.000Z", "isSidechain": false,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]]])
    }
    static func turnDuration() -> String {
        json(["type": "system", "subtype": "turn_duration", "durationMs": 1000, "timestamp": "2026-10-24T10:00:09.000Z"])
    }
    static func permissionMode(_ mode: String) -> String {
        json(["type": "permission-mode", "permissionMode": mode])
    }
}

final class TranscriptTailParsingTests: XCTestCase {
    typealias D = InterventionDetector
    typealias F = TranscriptFixture

    func testFinishedTurnIsAssistantWithFinalText() {
        let text = [
            F.user("add a test"),
            F.assistantText("Let me look."),
            F.toolUse("toolu_1", "Read", ["file_path": "/a.swift"]),
            F.toolResult("toolu_1"),
            F.assistantText("Done. Want me to run the suite?"),
            F.turnDuration(),
            F.permissionMode("default"),
        ].joined(separator: "\n")
        let tail = D.parseTranscriptTail(text)
        XCTAssertEqual(tail.lastMeaningfulRole, .assistant)
        XCTAssertEqual(tail.lastAssistantText, "Done. Want me to run the suite?")
        XCTAssertTrue(tail.pendingToolUses.isEmpty)
        XCTAssertEqual(tail.cwd, "/Users/me/proj")
        XCTAssertNotNil(tail.lastEventAt)
    }

    func testPendingToolUseWithFullCommand() {
        let text = [
            F.user("install deps"),
            F.toolUse("toolu_9", "Bash", ["command": "npm install bcrypt", "description": "Install deps"]),
        ].joined(separator: "\n")
        let tail = D.parseTranscriptTail(text)
        XCTAssertEqual(tail.pendingToolUses.map(\.id), ["toolu_9"])
        XCTAssertEqual(tail.pendingToolUses.first?.summary, "[Bash] npm install bcrypt\nInstall deps")
        XCTAssertNil(tail.lastAssistantText)
    }

    func testRealUserMessageClearsPending() {
        let text = [F.toolUse("toolu_1", "Bash", ["command": "ls"]), F.user("[Request interrupted by user]")].joined(separator: "\n")
        let tail = D.parseTranscriptTail(text)
        XCTAssertTrue(tail.pendingToolUses.isEmpty)
        XCTAssertEqual(tail.lastMeaningfulRole, .user)
    }

    func testSidechainAndGarbageIgnored() {
        let text = [
            #"artial line from a mid-file seek","x":1}"#,
            F.assistantText("final"),
            F.toolUse("toolu_s", "Bash", ["command": "subagent stuff"], sidechain: true),
            "not json",
        ].joined(separator: "\n")
        let tail = D.parseTranscriptTail(text)
        XCTAssertTrue(tail.pendingToolUses.isEmpty)
        XCTAssertEqual(tail.lastAssistantText, "final")
    }

    func testParallelToolCallsOrdered() {
        let text = [
            F.toolUse("a", "Bash", ["command": "one"]),
            F.toolUse("b", "Bash", ["command": "two"]),
            F.toolUse("c", "Bash", ["command": "three"]),
            F.toolResult("a"),
        ].joined(separator: "\n")
        let tail = D.parseTranscriptTail(text)
        XCTAssertEqual(tail.pendingToolUses.map(\.id), ["b", "c"])
        XCTAssertEqual(D.approvalContext(tail.pendingToolUses), "One of these is waiting for approval:\n• [Bash] two\n• [Bash] three")
        XCTAssertTrue(D.approvalContext([PendingToolUse(id: "t", name: "Task", summary: "[Task] refactor")])
            .hasPrefix("A subagent is asking for approval\n[Task] refactor"))
    }

    func testDescribeTools() {
        XCTAssertEqual(D.describeToolUse(name: "Edit", input: ["file_path": "/a", "old_string": "x", "new_string": "y"]), "[Edit] /a\n- x\n+ y")
        XCTAssertEqual(D.describeToolUse(name: "MultiEdit", input: ["file_path": "/a", "edits": [1, 2]]), "[MultiEdit] /a (2 edits)")
        XCTAssertEqual(D.describeToolUse(name: "WebFetch", input: ["url": "https://x"]), "[WebFetch] https://x")
        XCTAssertTrue(D.describeToolUse(name: "ExitPlanMode", input: ["plan": "# Plan\nStep 1"]).hasPrefix("Plan ready for review:\n# Plan"))
        XCTAssertEqual(D.describeToolUse(name: "mcp__db__query", input: ["sql": "select 1"]), #"[mcp__db__query] {"sql":"select 1"}"#)
        let long = D.describeToolUse(name: "Bash", input: ["command": String(repeating: "a", count: 5000)])
        XCTAssertEqual(long.count, D.contextLimit)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testDescribeQuestion() {
        let input: [String: Any] = ["questions": [[
            "question": "Which database?", "header": "DB", "multiSelect": false,
            "options": [["label": "Postgres", "description": "Server"], ["label": "SQLite", "description": ""]],
        ]]]
        XCTAssertEqual(D.describeToolUse(name: "AskUserQuestion", input: input), "Which database?\n1. Postgres — Server\n2. SQLite")
    }

    func testIdleContextKeepsEnd() {
        var tail = TranscriptTail()
        tail.lastAssistantText = String(repeating: "x", count: 3000) + " Shall I continue?"
        let ctx = D.idleContext(tail)
        XCTAssertEqual(ctx.count, D.contextLimit)
        XCTAssertTrue(ctx.hasPrefix("…"))
        XCTAssertTrue(ctx.hasSuffix("Shall I continue?"))
        XCTAssertEqual(D.idleContext(TranscriptTail()), "Claude finished its turn")
    }

    func testReadTailDropsPartialFirstLineAndSurvivesTruncatedUTF8() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data((String(repeating: "x", count: 1000) + "\n" + F.assistantText("héllo") + "\n").utf8)
        data.append(contentsOf: [0xC3])   // write cut mid-sequence
        try data.write(to: url)
        let r = D.readTail(of: url, maxBytes: 200)
        XCTAssertEqual(r?.truncated, true)
        XCTAssertFalse(r?.text.hasPrefix("xxx") ?? true)
        XCTAssertEqual(D.readTranscriptTail(url)?.lastAssistantText, "héllo")
    }
}

final class InterventionDecisionTests: XCTestCase {
    typealias D = InterventionDetector
    typealias F = TranscriptFixture

    let sid = "455cd6af-046c-4468-9d9b-5de46c4d8194"
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let settings = DetectorSettings(idleDelay: 60, maxOpenAge: 4 * 3600, waitingGrace: 5)

    private func session(_ status: ClaudeSessionStatus, since: Date?, file: Bool = true) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 42, sessionId: sid, cwd: "/Users/me/proj", status: status,
                          statusUpdatedAt: since, tty: "ttys001", hasSessionFile: file)
    }

    private func tail(_ lines: [String]) -> TranscriptTail { D.parseTranscriptTail(lines.joined(separator: "\n")) }

    private func proposal(_ d: DetectorDecision) -> DetectorDecision.Proposal? {
        if case .open(let p) = d { return p }
        return nil
    }

    func testBusyNeverPages() {
        let t = tail([F.toolUse("x", "Bash", ["command": "ls"])])
        XCTAssertEqual(D.decide(session: session(.busy, since: t0), tail: t, transcriptModifiedAt: t0,
                                now: t0.addingTimeInterval(9999), settings: settings), .none)
    }

    func testWaitingOnBashIsPermissionWithCommand() {
        let t = tail([F.toolUse("toolu_1", "Bash", ["command": "rm -rf build", "description": "Clean"])])
        let p = proposal(D.decide(session: session(.waiting, since: t0), tail: t, transcriptModifiedAt: t0,
                                  now: t0.addingTimeInterval(1), settings: settings))
        XCTAssertEqual(p?.kind, .permission)
        XCTAssertNil(p?.subtype)
        XCTAssertEqual(p?.context, "[Bash] rm -rf build\nClean")
        XCTAssertEqual(p?.stateStart, t0)   // openedAt = when waiting began
        XCTAssertEqual(p?.promptKey, "toolu_1")
    }

    func testWaitingOnExitPlanModeIsPlanSubtype() {
        let t = tail([F.toolUse("p", "ExitPlanMode", ["plan": "do it"])])
        let p = proposal(D.decide(session: session(.waiting, since: t0), tail: t, transcriptModifiedAt: t0, now: t0, settings: settings))
        XCTAssertEqual(p?.kind, .permission)
        XCTAssertEqual(p?.subtype, "plan")
    }

    func testWaitingOnAskUserQuestionIsQuestion() {
        let t = tail([F.toolUse("q", "AskUserQuestion", ["questions": [["question": "A or B?", "options": [["label": "A"], ["label": "B"]]]]])])
        let p = proposal(D.decide(session: session(.waiting, since: t0), tail: t, transcriptModifiedAt: t0, now: t0, settings: settings))
        XCTAssertEqual(p?.kind, .question)
        XCTAssertEqual(p?.context, "A or B?\n1. A\n2. B")
    }

    func testWaitingWithoutToolWaitsForGraceThenPagesGeneric() {
        let t = tail([F.assistantText("hm")])
        XCTAssertEqual(D.decide(session: session(.waiting, since: t0), tail: t, transcriptModifiedAt: t0,
                                now: t0.addingTimeInterval(2), settings: settings), .notYet)
        let p = proposal(D.decide(session: session(.waiting, since: t0), tail: t, transcriptModifiedAt: t0,
                                  now: t0.addingTimeInterval(10), settings: settings))
        XCTAssertEqual(p?.kind, .permission)
    }

    func testIdlePagesOnlyAfterDelayAndWhenAssistantSpokeLast() {
        let done = tail([F.user("go"), F.assistantText("All done — anything else?"), F.turnDuration()])
        XCTAssertEqual(D.decide(session: session(.idle, since: t0), tail: done, transcriptModifiedAt: t0,
                                now: t0.addingTimeInterval(30), settings: settings), .notYet)
        let p = proposal(D.decide(session: session(.idle, since: t0), tail: done, transcriptModifiedAt: t0,
                                  now: t0.addingTimeInterval(61), settings: settings))
        XCTAssertEqual(p?.kind, .idle)
        XCTAssertEqual(p?.context, "All done — anything else?")
        XCTAssertEqual(p?.stateStart, t0)

        let interrupted = tail([F.assistantText("working"), F.user("[Request interrupted by user]")])
        XCTAssertEqual(D.decide(session: session(.idle, since: t0), tail: interrupted, transcriptModifiedAt: t0,
                                now: t0.addingTimeInterval(600), settings: settings), .none)
        XCTAssertEqual(D.decide(session: session(.idle, since: t0), tail: nil, transcriptModifiedAt: nil,
                                now: t0.addingTimeInterval(600), settings: settings), .none)
    }

    func testStatuslessFallback() {
        let done = tail([F.user("go"), F.assistantText("done")])
        let s = session(.unknown, since: nil, file: false)
        XCTAssertEqual(D.decide(session: s, tail: done, transcriptModifiedAt: t0, now: t0.addingTimeInterval(10), settings: settings), .notYet)
        XCTAssertEqual(proposal(D.decide(session: s, tail: done, transcriptModifiedAt: t0, now: t0.addingTimeInterval(100), settings: settings))?.kind, .idle)
        let pendingTool = tail([F.toolUse("t", "Bash", ["command": "make"])])
        let p = proposal(D.decide(session: s, tail: pendingTool, transcriptModifiedAt: t0, now: t0.addingTimeInterval(100), settings: settings))
        XCTAssertEqual(p?.kind, .permission)
        XCTAssertTrue(p?.context.hasPrefix("Possibly waiting for approval") ?? false)
    }

    func testMayOpenCapsOnlyNonWaitingStates() {
        let old = t0.addingTimeInterval(-9 * 86400)
        XCTAssertFalse(D.mayOpen(kind: .idle, status: .idle, stateStart: old, now: t0, settings: settings))
        XCTAssertTrue(D.mayOpen(kind: .permission, status: .waiting, stateStart: old, now: t0, settings: settings))
        XCTAssertTrue(D.mayOpen(kind: .idle, status: .idle, stateStart: t0.addingTimeInterval(-120), now: t0, settings: settings))
    }

    func testInterventionIdRoundTrip() {
        let id = D.interventionId(sessionId: sid, kind: .rateLimit, stateStart: t0)
        XCTAssertEqual(id, "\(sid)-rate_limit-1800000000")
        let parsed = D.parseInterventionId(id)
        XCTAssertEqual(parsed?.sessionId, sid)
        XCTAssertEqual(parsed?.kind, "rate_limit")
        XCTAssertEqual(parsed?.epoch, 1_800_000_000)
        XCTAssertNil(D.parseInterventionId("hook-455cd6af-1800000000-123"))
        XCTAssertNil(D.parseInterventionId("codex-abc-idle-1"))
    }
}

/// End-to-end detector behaviour against a real transcript file.
final class InterventionDetectorScanTests: XCTestCase {
    typealias F = TranscriptFixture

    let sid = "455cd6af-046c-4468-9d9b-5de46c4d8194"
    var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func session(_ status: ClaudeSessionStatus, since: Date) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 42, sessionId: sid, cwd: "/tmp", status: status,
                          statusUpdatedAt: since, tty: "ttys001", hasSessionFile: true)
    }

    func testOpenStableThenResolveOnBusy() throws {
        let det = InterventionDetector()
        let start = Date().addingTimeInterval(-3)
        try write([F.user("go"), F.toolUse("toolu_1", "Bash", ["command": "make deploy"])])
        let s = DetectorSettings()

        let r1 = det.scan(sessions: [session(.waiting, since: start)], transcriptFor: { _ in self.url }, settings: s)
        XCTAssertEqual(r1.opened.count, 1)
        let e = try XCTUnwrap(r1.opened.first)
        XCTAssertEqual(e.kind, .permission)
        XCTAssertEqual(e.openedAt, start)
        XCTAssertEqual(e.pid, 42)
        XCTAssertEqual(e.promptKey, "toolu_1")
        XCTAssertEqual(e.id, InterventionDetector.interventionId(sessionId: sid, kind: .permission, stateStart: start))
        XCTAssertEqual(det.pendingEvent(id: e.id)?.context, "[Bash] make deploy")

        let r2 = det.scan(sessions: [session(.waiting, since: start)], transcriptFor: { _ in self.url }, settings: s)
        XCTAssertTrue(r2.opened.isEmpty)
        XCTAssertTrue(r2.resolved.isEmpty)

        let r3 = det.scan(sessions: [session(.busy, since: Date())], transcriptFor: { _ in self.url }, settings: s)
        XCTAssertEqual(r3.resolved.map(\.id), [e.id])
        XCTAssertTrue(det.currentlyPending.isEmpty)
    }

    func testProcessExitResolves() throws {
        let det = InterventionDetector()
        try write([F.toolUse("toolu_1", "Bash", ["command": "x"])])
        _ = det.scan(sessions: [session(.waiting, since: Date())], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        let r = det.scan(sessions: [], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertEqual(r.resolved.count, 1)
    }

    func testNextPromptInSameWaitingStateIsNewPage() throws {
        let det = InterventionDetector()
        let start = Date().addingTimeInterval(-30)
        try write([F.toolUse("a", "Bash", ["command": "one"]), F.toolUse("b", "Bash", ["command": "two"])])
        let first = det.scan(sessions: [session(.waiting, since: start)], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertEqual(first.opened.first?.promptKey, "a")

        // "a" approved; status file not rewritten yet, "b" now on screen.
        try write([F.toolUse("a", "Bash", ["command": "one"]), F.toolUse("b", "Bash", ["command": "two"]), F.toolResult("a")])
        let second = det.scan(sessions: [session(.waiting, since: start)], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertEqual(second.resolved.map(\.promptKey), ["a"])
        XCTAssertEqual(second.opened.map(\.promptKey), ["b"])
        XCTAssertNotEqual(second.opened.first?.id, first.opened.first?.id)
        XCTAssertEqual(second.opened.first?.stateStartedAt, start)
    }

    func testIdleOnLaunchForDaysOldStateDoesNotPage() throws {
        let det = InterventionDetector()
        try write([F.user("go"), F.assistantText("done")])
        let r = det.scan(sessions: [session(.idle, since: Date().addingTimeInterval(-5 * 86400))],
                         transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertTrue(r.opened.isEmpty)
    }

    func testIdleNotYetDoesNotKeepEarlierApprovalPage() throws {
        let det = InterventionDetector()
        try write([F.toolUse("a", "Bash", ["command": "one"])])
        _ = det.scan(sessions: [session(.waiting, since: Date().addingTimeInterval(-20))], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertEqual(det.currentlyPending.count, 1)
        // Approved at the Mac, turn finished seconds ago (< idle delay).
        try write([F.toolUse("a", "Bash", ["command": "one"]), F.toolResult("a"), F.assistantText("done")])
        let r = det.scan(sessions: [session(.idle, since: Date().addingTimeInterval(-2))], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertEqual(r.resolved.count, 1)
        XCTAssertTrue(det.currentlyPending.isEmpty)
    }

    func testResetReturnsOpenPages() throws {
        let det = InterventionDetector()
        try write([F.toolUse("a", "Bash", ["command": "one"])])
        _ = det.scan(sessions: [session(.waiting, since: Date())], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertEqual(det.reset().count, 1)
        XCTAssertTrue(det.currentlyPending.isEmpty)
    }
}

final class ClaudeBackendLogicTests: XCTestCase {
    let sid = "455cd6af-046c-4468-9d9b-5de46c4d8194"

    private func s(_ status: ClaudeSessionStatus, since: Date? = nil) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 1, sessionId: sid, cwd: nil, status: status, statusUpdatedAt: since, tty: nil, hasSessionFile: status != .unknown)
    }

    func testIsActive() {
        typealias B = ClaudeBackend
        XCTAssertFalse(B.isActive(sessions: [], unidentifiedInteractive: 0, claudeRunning: false, secondsSinceTranscript: 1, requireRecentActivity: true, activityWindow: 90))
        XCTAssertTrue(B.isActive(sessions: [s(.busy), s(.idle)], unidentifiedInteractive: 0, claudeRunning: true, secondsSinceTranscript: 9999, requireRecentActivity: true, activityWindow: 90))
        // Idle/waiting sessions with a known status are not "active", whatever the transcript says.
        XCTAssertFalse(B.isActive(sessions: [s(.idle), s(.waiting)], unidentifiedInteractive: 0, claudeRunning: true, secondsSinceTranscript: 1, requireRecentActivity: true, activityWindow: 90))
        // Status-less: transcript activity window.
        XCTAssertTrue(B.isActive(sessions: [s(.unknown)], unidentifiedInteractive: 0, claudeRunning: true, secondsSinceTranscript: 10, requireRecentActivity: true, activityWindow: 90))
        XCTAssertFalse(B.isActive(sessions: [s(.unknown)], unidentifiedInteractive: 0, claudeRunning: true, secondsSinceTranscript: 100, requireRecentActivity: true, activityWindow: 90))
        XCTAssertTrue(B.isActive(sessions: [s(.unknown)], unidentifiedInteractive: 0, claudeRunning: true, secondsSinceTranscript: 100, requireRecentActivity: false, activityWindow: 90))
        XCTAssertTrue(B.isActive(sessions: [], unidentifiedInteractive: 1, claudeRunning: true, secondsSinceTranscript: nil, requireRecentActivity: true, activityWindow: 90))
    }

    func testHoldForPages() {
        let now = Date()
        let page = InterventionEvent(id: "x", sessionId: sid, cwd: "", projectName: "p", kind: .idle,
                                     openedAt: now.addingTimeInterval(-30 * 60), context: "", transcriptPath: "")
        XCTAssertTrue(ClaudeBackend.shouldHoldForPages(pending: [page], relayAvailable: true, holdMinutes: 60, now: now))
        XCTAssertFalse(ClaudeBackend.shouldHoldForPages(pending: [page], relayAvailable: true, holdMinutes: 20, now: now))
        XCTAssertFalse(ClaudeBackend.shouldHoldForPages(pending: [page], relayAvailable: false, holdMinutes: 60, now: now))
        XCTAssertFalse(ClaudeBackend.shouldHoldForPages(pending: [page], relayAvailable: true, holdMinutes: 0, now: now))
        XCTAssertFalse(ClaudeBackend.shouldHoldForPages(pending: [], relayAvailable: true, holdMinutes: 60, now: now))
    }

    func testRateLimitCleared() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let ev = RateLimitEvent(sessionId: sid, cwd: "/p", projectName: "p", eventTime: t,
                                resetTime: t.addingTimeInterval(3600), resetTimeText: "5pm", transcriptPath: "")
        XCTAssertFalse(ClaudeBackend.rateLimitCleared(ev, sessions: [s(.idle, since: t.addingTimeInterval(2))]))
        XCTAssertTrue(ClaudeBackend.rateLimitCleared(ev, sessions: [s(.busy, since: t.addingTimeInterval(2))]))
        XCTAssertTrue(ClaudeBackend.rateLimitCleared(ev, sessions: [s(.idle, since: t.addingTimeInterval(600))]))
        XCTAssertFalse(ClaudeBackend.rateLimitCleared(ev, sessions: []))

        let page = ClaudeBackend.rateLimitPage(for: ev)
        XCTAssertEqual(page.id, "\(sid)-rate_limit-1800000000")
        XCTAssertEqual(page.kind, .rateLimit)
        XCTAssertTrue(page.context.hasPrefix("Usage limit reached — resets at "))
    }

    func testPageNeedsAwayOnlyForInformationalKinds() {
        XCTAssertTrue(ClaudeBackend.pageNeedsAway(.idle))
        XCTAssertTrue(ClaudeBackend.pageNeedsAway(.rateLimit))
        XCTAssertFalse(ClaudeBackend.pageNeedsAway(.permission))
        XCTAssertFalse(ClaudeBackend.pageNeedsAway(.question))
    }

    func testParseHookId() {
        let h = ClaudeBackend.parseHookId("hook-455cd6af-1800000000-4242")
        XCTAssertEqual(h?.sid8, "455cd6af")
        XCTAssertEqual(h?.epoch, 1_800_000_000)
        XCTAssertNil(ClaudeBackend.parseHookId("hookpre-455cd6af-1800000000-1"))
        XCTAssertNil(ClaudeBackend.parseHookId("\(sid)-idle-1800000000"))
    }

    func testProcessMonitorFiltersSnapshot() {
        let rows = [
            ProcessRunner.ProcessInfoRow(pid: 10, ppid: 1, tty: "ttys001", command: "/Users/me/.local/bin/claude --resume x"),
            ProcessRunner.ProcessInfoRow(pid: 11, ppid: 1, tty: "??", command: "/bin/zsh ~/.claude/hooks/page-notify.sh"),
            ProcessRunner.ProcessInfoRow(pid: 12, ppid: 1, tty: "??", command: "/Applications/ClaudePowerMode.app/Contents/MacOS/claude"),
            ProcessRunner.ProcessInfoRow(pid: 13, ppid: 1, tty: "??", command: "python serve.py"),
        ]
        let found = ProcessMonitor.claudeProcesses(in: rows, pattern: "claude", exclude: ["ClaudePowerMode"])
        XCTAssertEqual(found.map(\.pid), [10])
    }
}
