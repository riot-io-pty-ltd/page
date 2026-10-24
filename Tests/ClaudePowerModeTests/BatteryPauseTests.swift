import XCTest
@testable import ClaudePowerMode

final class ClaudeBatteryPauseTests: XCTestCase {
    typealias Host = InjectionExecutor.TerminalHost
    private let cmuxTarget = CmuxBridge.Target(surfaceId: "5FA66D62-4F2B-4F19-90BE-80319216DE70", workspaceId: nil,
                                               cliPath: "/Applications/cmux.app/Contents/Resources/bin/cmux", source: "environment")

    func testLoneEscapeCapability() {
        XCTAssertTrue(Host.tmux(tmuxPath: "/t", paneId: "%1", inMode: false).canSendLoneEscape)
        XCTAssertTrue(Host.iTerm(tty: "/dev/ttys001").canSendLoneEscape)
        XCTAssertTrue(Host.cmux(cmuxTarget).canSendLoneEscape)
        XCTAssertFalse(Host.terminalApp(tty: "/dev/ttys001").canSendLoneEscape)
        XCTAssertFalse(Host.unsupported("Warp").canSendLoneEscape)
        XCTAssertEqual(Host.cmux(cmuxTarget).label, "cmux pane")
    }

    func testPauseInterruptsWhereEscIsPossible() {
        for host in [Host.tmux(tmuxPath: "/t", paneId: "%1", inMode: false), .iTerm(tty: "/dev/ttys001"), .cmux(cmuxTarget)] {
            XCTAssertEqual(ClaudeBackend.pauseStrategy(status: .busy, host: host, mode: .pause), .interrupt, host.label)
        }
    }

    func testTerminalAppQueuesBecauseItCantPressEsc() {
        guard case .queue(let reason) = ClaudeBackend.pauseStrategy(status: .busy, host: .terminalApp(tty: "/dev/ttys004"), mode: .pause) else {
            return XCTFail("Terminal.app must queue, never Esc")
        }
        XCTAssertTrue(reason.contains("Terminal.app"))
    }

    func testAfterTurnNeverInterrupts() {
        for host in [Host.tmux(tmuxPath: "/t", paneId: "%1", inMode: false), .iTerm(tty: "/dev/ttys001"), .cmux(cmuxTarget), .terminalApp(tty: "/dev/x")] {
            guard case .queue = ClaudeBackend.pauseStrategy(status: .busy, host: host, mode: .afterTurn) else {
                return XCTFail("afterTurn must queue in \(host.label)")
            }
        }
    }

    func testOnlyBusySessionsArePaused() {
        let tmux = Host.tmux(tmuxPath: "/t", paneId: "%1", inMode: false)
        for status in [ClaudeSessionStatus.waiting, .idle, .unknown] {
            guard case .skip = ClaudeBackend.pauseStrategy(status: status, host: tmux, mode: .pause) else {
                return XCTFail("\(status) must be left alone (Esc on a menu would deny it)")
            }
        }
        guard case .skip = ClaudeBackend.pauseStrategy(status: .busy, host: tmux, mode: .off) else { return XCTFail() }
        guard case .skip = ClaudeBackend.pauseStrategy(status: .busy, host: .unsupported("Warp"), mode: .pause) else { return XCTFail() }
        guard case .skip = ClaudeBackend.pauseStrategy(status: .busy, host: .unknown, mode: .pause) else { return XCTFail() }
        guard case .skip = ClaudeBackend.pauseStrategy(status: .busy, host: .unreachable("x"), mode: .pause) else { return XCTFail() }
    }

    // MARK: resume: did the user touch the session?

    private let pausedAt = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!
    private lazy var pauseText = BatteryPolicy.pauseMessage(percent: 9, mode: .pause)
    private lazy var authored = BatteryPauseSupport.pageAuthoredMessages(extra: [BatteryPolicy.recoveryMessage])

    private func line(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func user(_ ts: String, _ content: Any, extra: [String: Any] = [:]) -> String {
        var o: [String: Any] = ["type": "user", "timestamp": ts, "message": ["role": "user", "content": content]]
        o.merge(extra) { $1 }
        return line(o)
    }

    private func assistant(_ ts: String) -> String {
        line(["type": "assistant", "timestamp": ts, "message": ["role": "assistant", "content": [["type": "text", "text": "Stopped at step 3."]]]])
    }

    func testOwnPauseTrafficIsNotUserActivity() {
        let tail = [
            user("2027-01-15T07:59:00Z", "earlier request"),
            user("2027-01-15T08:00:01Z", [["type": "text", "text": "[Request interrupted by user]"]]),
            user("2027-01-15T08:00:03Z", pauseText),
            assistant("2027-01-15T08:00:09Z"),
            user("2027-01-15T08:00:10Z", [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]),
            user("2027-01-15T08:00:11Z", "Caveat: local command output", extra: ["isMeta": true]),
            user("2027-01-15T08:00:12Z", "subagent prompt", extra: ["isSidechain": true]),
        ].joined(separator: "\n")
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: tail, tailIsComplete: false, pageAuthored: authored), .none)
    }

    func testRealUserMessageAfterPauseBlocksResume() {
        let tail = [
            user("2027-01-15T07:59:00Z", "earlier"),
            user("2027-01-15T08:00:03Z", pauseText),
            user("2027-01-15T08:20:00Z", [["type": "text", "text": "actually, stop and revert"]]),
        ].joined(separator: "\n")
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: tail, tailIsComplete: true, pageAuthored: authored), .userActed)
    }

    private func queued(_ ts: String, _ prompt: String, origin: [String: Any]? = ["kind": "human"]) -> String {
        var a: [String: Any] = ["type": "queued_command", "prompt": prompt, "commandMode": "prompt"]
        if let origin { a["origin"] = origin }
        return line(["type": "attachment", "timestamp": ts, "attachment": a])
    }

    func testMessageTypedMidTurnCountsUnlessItIsPages() {
        let own = queued("2027-01-15T08:00:03Z", pauseText)
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: own, tailIsComplete: true, pageAuthored: authored), .none)
        let human = queued("2027-01-15T08:05:00Z", "wait, also update the docs")
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: human, tailIsComplete: true, pageAuthored: authored), .userActed)
        let legacy = queued("2027-01-15T08:05:00Z", "no origin recorded", origin: nil)
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: legacy, tailIsComplete: true, pageAuthored: authored), .userActed)
        let subagent = queued("2027-01-15T08:05:00Z", "[Subagent hand-back] report", origin: ["kind": "peer"])
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: subagent, tailIsComplete: true, pageAuthored: authored), .none)
        let task = line(["type": "attachment", "timestamp": "2027-01-15T08:05:00Z",
                         "attachment": ["type": "queued_command", "prompt": "task done", "commandMode": "task-notification",
                                        "origin": ["kind": "task-notification"]]])
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: task, tailIsComplete: true, pageAuthored: authored), .none)
    }

    func testLateInterruptIsTheUsers() {
        let tail = user("2027-01-15T08:10:00Z", [["type": "text", "text": "[Request interrupted by user]"]])
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: tail, tailIsComplete: true, pageAuthored: authored), .userActed)
    }

    func testMessagesBeforeThePauseDontCount() {
        let tail = user("2027-01-15T07:00:00Z", "old message")
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: tail, tailIsComplete: true, pageAuthored: authored), .none)
    }

    func testTruncatedTailThatStartsAfterThePauseIsUnknown() {
        let tail = assistant("2027-01-15T09:00:00Z")
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: tail, tailIsComplete: false, pageAuthored: authored), .unknown)
        XCTAssertEqual(ClaudeBackend.userActivity(since: pausedAt, transcriptTail: tail, tailIsComplete: true, pageAuthored: authored), .none)
    }

    func testPageAuthoredCoversEveryPauseMessage() {
        let set = BatteryPauseSupport.pageAuthoredMessages()
        XCTAssertTrue(set.contains(BatteryPauseSupport.normalize(BatteryPolicy.pauseMessage(percent: 3, mode: .afterTurn))))
        XCTAssertTrue(set.contains(BatteryPauseSupport.normalize(BatteryPolicy.manualResumeMessage)))
        XCTAssertFalse(set.contains(BatteryPauseSupport.normalize("please continue")))
    }
}

final class CodexBatteryPauseTests: XCTestCase {
    private let cmux = CodexInjector.Terminal.cmux(CmuxBridge.Target(surfaceId: "5FA66D62-4F2B-4F19-90BE-80319216DE70", workspaceId: nil,
                                                                     cliPath: "/x/cmux", source: "environment"))

    func testPauseStrategy() {
        XCTAssertEqual(CodexBackend.pauseStrategy(terminal: .tmux(pane: "%2"), mode: .pause), .interrupt)
        XCTAssertEqual(CodexBackend.pauseStrategy(terminal: cmux, mode: .pause), .interrupt)
        guard case .queue = CodexBackend.pauseStrategy(terminal: cmux, mode: .afterTurn) else { return XCTFail() }
        // Blind mid-turn typing could hit an approval overlay's hotkeys.
        guard case .skip = CodexBackend.pauseStrategy(terminal: .tmux(pane: "%2"), mode: .afterTurn) else { return XCTFail() }
        guard case .skip = CodexBackend.pauseStrategy(terminal: .terminalApp(tty: "ttys004"), mode: .pause) else { return XCTFail() }
        guard case .skip = CodexBackend.pauseStrategy(terminal: .terminalApp(tty: "ttys004"), mode: .afterTurn) else { return XCTFail() }
        guard case .skip = CodexBackend.pauseStrategy(terminal: .unavailable("x"), mode: .pause) else { return XCTFail() }
        guard case .skip = CodexBackend.pauseStrategy(terminal: .tmux(pane: "%2"), mode: .off) else { return XCTFail() }
    }

    private let pausedAt = ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z")!

    private func line(_ ts: String, _ type: String, _ payload: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["timestamp": ts, "type": type, "payload": payload]), encoding: .utf8)!
    }

    func testInjectedContextAndOwnMessagesDontCount() {
        let pause = BatteryPolicy.pauseMessage(percent: 8, mode: .pause)
        let tail = [
            line("2027-01-15T08:00:02Z", "event_msg", ["type": "turn_aborted"]),
            line("2027-01-15T08:00:03Z", "response_item", ["type": "message", "role": "user",
                                                          "content": [["type": "input_text", "text": "<environment_context>\n</environment_context>"]]]),
            line("2027-01-15T08:00:03Z", "response_item", ["type": "message", "role": "user",
                                                          "content": [["type": "input_text", "text": pause]]]),
            line("2027-01-15T08:00:04Z", "event_msg", ["type": "item_completed", "item": ["type": "UserMessage", "content": [["type": "text", "text": pause]]]]),
            line("2027-01-15T08:00:09Z", "event_msg", ["type": "task_complete"]),
        ].joined(separator: "\n")
        XCTAssertEqual(CodexBackend.userActivity(since: pausedAt, rolloutTail: tail, tailIsComplete: true,
                                                 pageAuthored: BatteryPauseSupport.pageAuthoredMessages()), .none)
    }

    func testUserMessageAfterPauseCounts() {
        let tail = [
            line("2027-01-15T08:30:00Z", "event_msg", ["type": "user_message", "message": "keep going but skip tests"]),
        ].joined(separator: "\n")
        XCTAssertEqual(CodexBackend.userActivity(since: pausedAt, rolloutTail: tail, tailIsComplete: true,
                                                 pageAuthored: BatteryPauseSupport.pageAuthoredMessages()), .userActed)
        let item = line("2027-01-15T08:30:00Z", "event_msg", ["type": "item_completed", "item": ["type": "UserMessage", "content": [["type": "text", "text": "hi"]]]])
        XCTAssertEqual(CodexBackend.userActivity(since: pausedAt, rolloutTail: item, tailIsComplete: true,
                                                 pageAuthored: BatteryPauseSupport.pageAuthoredMessages()), .userActed)
    }
}

final class HeadlessGuardTests: XCTestCase {
    private let sid = "d0abd528-7aba-468b-828e-a153fef21a02"

    private func row(_ pid: Int32, _ cmd: String) -> ProcessRunner.ProcessInfoRow {
        ProcessRunner.ProcessInfoRow(pid: pid, ppid: 1, tty: "??", command: cmd)
    }

    func testNoProcessTableBlocks() {
        XCTAssertNotNil(InjectionExecutor.headlessBlocker(sessionId: sid, processTable: [], transcript: nil))
    }

    func testAnotherClaudeOnTheSessionBlocks() {
        let table = [row(1, "/sbin/launchd"), row(50, "/Users/me/.local/bin/claude --resume \(sid) --print carry on")]
        XCTAssertEqual(InjectionExecutor.headlessBlocker(sessionId: sid, processTable: table, transcript: nil),
                       "The session is still running — reply at the Mac")
    }

    func testLiveCmuxRecordedProcessBlocks() {
        let table = [row(1, "/sbin/launchd"), row(77, "node something")]
        let entry = CmuxBridge.HookSession(sessionId: sid, surfaceId: "5FA66D62-4F2B-4F19-90BE-80319216DE70", workspaceId: nil,
                                           pid: 77, pidStartSeconds: 1000)
        XCTAssertNotNil(InjectionExecutor.headlessBlocker(sessionId: sid, processTable: table, transcript: nil,
                                                          cmuxEntry: entry, startSeconds: { _ in 1000 }))
        // pid reused by an unrelated process: not a live owner.
        XCTAssertNil(InjectionExecutor.headlessBlocker(sessionId: sid, processTable: table, transcript: nil,
                                                       cmuxEntry: entry, startSeconds: { _ in 2000 }))
    }

    func testRecentlyWrittenTranscriptBlocks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(sid)-\(UUID().uuidString).jsonl")
        try Data("{}\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let table = [row(1, "/sbin/launchd")]
        XCTAssertNotNil(InjectionExecutor.headlessBlocker(sessionId: sid, processTable: table, transcript: url))
        XCTAssertNil(InjectionExecutor.headlessBlocker(sessionId: sid, processTable: table, transcript: url,
                                                       now: Date().addingTimeInterval(600)))
    }

    func testCodexExecResumeNeedsCompleteScan() {
        let table = [row(1, "/sbin/launchd")]
        let unknownCwd = CodexProcess(pid: 9, ppid: 1, tty: "ttys001", cwd: nil, openRollouts: [], command: "codex")
        XCTAssertNotNil(CodexInjector.execResumeBlocker(table: [], processes: [], project: "p"))
        XCTAssertNotNil(CodexInjector.execResumeBlocker(table: table, processes: [unknownCwd], project: "p"))
        let known = CodexProcess(pid: 9, ppid: 1, tty: "ttys001", cwd: "/elsewhere", openRollouts: [], command: "codex")
        XCTAssertNil(CodexInjector.execResumeBlocker(table: table, processes: [known], project: "p"))
    }
}

/// The low-battery Esc against a throwaway private tmux server
/// (`-L pagetest-transport-*`) whose pane runs `cat -v`, so the bytes that
/// arrive are visible. Never touches the user's default tmux server.
final class BatteryInterruptTmuxTests: XCTestCase {
    private var socket = ""
    private var dir: URL!
    private var wrapper = ""

    override func setUpWithError() throws {
        guard let tmux = ProcessRunner.findExecutable("tmux") else { throw XCTSkip("tmux not installed") }
        socket = "pagetest-transport-\(UUID().uuidString.prefix(8))"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wrapper = dir.appendingPathComponent("tmux").path
        try "#!/bin/bash\nexec \(ProcessRunner.shellQuote(tmux)) -L \(socket) \"$@\"\n".write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
        let start = ProcessRunner.run(wrapper, ["-f", "/dev/null", "new-session", "-d", "-s", "t", "-x", "120", "-y", "20",
                                                "sh -c 'stty raw -echo; exec cat -v'"], timeout: 5)
        guard start.succeeded else { throw XCTSkip("couldn't start private tmux server: \(start.stderr)") }
        usleep(400_000)
    }

    override func tearDown() {
        CodexInjector.tmuxServerArgs = []
        if !wrapper.isEmpty {
            let socketPath = ProcessRunner.run(wrapper, ["display-message", "-p", "#{socket_path}"], timeout: 3).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ProcessRunner.run(wrapper, ["kill-server"], timeout: 5)
            if socketPath.contains("pagetest-transport-") { try? FileManager.default.removeItem(atPath: socketPath) }
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func paneId() throws -> String {
        let r = ProcessRunner.run(wrapper, ["list-panes", "-a", "-F", "#{pane_id}"], timeout: 3)
        return try XCTUnwrap(r.stdout.split(separator: "\n").first.map(String.init))
    }

    private func screen(_ pane: String) -> String {
        usleep(300_000)
        return ProcessRunner.run(wrapper, ["capture-pane", "-p", "-t", pane], timeout: 3).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testClaudeInterruptIsOneLoneEscape() throws {
        let pane = try paneId()
        let r = InjectionExecutor.sendInterrupt(host: .tmux(tmuxPath: wrapper, paneId: pane, inMode: false))
        XCTAssertTrue(r.success, r.output)
        XCTAssertEqual(screen(pane), "^[", "exactly one ESC, no Return")
    }

    func testCodexInterruptIsOneLoneEscape() throws {
        let pane = try paneId()
        CodexInjector.tmuxServerArgs = ["-L", socket]
        let r = CodexInjector.interrupt(.tmux(pane: pane))
        XCTAssertTrue(r.success, r.output ?? "")
        XCTAssertEqual(screen(pane), "^[")
    }

    func testTerminalAppCannotBeInterrupted() {
        XCTAssertFalse(InjectionExecutor.sendInterrupt(host: .terminalApp(tty: "/dev/ttys999")).success)
        XCTAssertFalse(CodexInjector.interrupt(.terminalApp(tty: "ttys999")).success)
    }
}
