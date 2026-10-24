import XCTest
@testable import ClaudePowerMode

// MARK: - JSON-RPC classification & framing

final class CodexProtocolTests: XCTestCase {
    private func classify(_ s: String) -> AppServerProtocol.InboundMessage {
        AppServerProtocol.InboundMessage.classify(Data(s.utf8))
    }

    func testResponseWithIntegerId() {
        guard case let .response(id, result, error) = classify(#"{"id":7,"result":{"data":[]}}"#) else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(id, .int(7))
        XCTAssertNil(error)
        XCTAssertEqual(result["data"], .array([]))
    }

    func testErrorResponse() {
        guard case let .response(id, _, error) = classify(#"{"id":3,"error":{"code":-32001,"message":"busy"}}"#) else {
            return XCTFail("expected response")
        }
        XCTAssertEqual(id, .int(3))
        XCTAssertEqual(error?.code, -32001)
    }

    func testServerRequestHasIdAndMethod() {
        // Must not be mistaken for a response to our own request id 0.
        let line = #"{"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":"t1","command":"rm -rf build"}}"#
        guard case let .serverRequest(id, method, params) = classify(line) else {
            return XCTFail("expected server request")
        }
        XCTAssertEqual(id, .int(0))
        XCTAssertEqual(method, AppServerProtocol.ServerRequestMethod.commandExecutionApproval)
        XCTAssertEqual(params["threadId"].stringValue, "t1")
    }

    func testServerRequestWithStringId() {
        guard case let .serverRequest(id, method, _) = classify(#"{"id":"req-9","method":"item/tool/requestUserInput","params":{}}"#) else {
            return XCTFail("expected server request")
        }
        XCTAssertEqual(id, .string("req-9"))
        XCTAssertEqual(id.description, "req-9")
        XCTAssertEqual(method, "item/tool/requestUserInput")
    }

    func testNotification() {
        guard case let .notification(method, params) = classify(#"{"method":"thread/status/changed","params":{"threadId":"a"}}"#) else {
            return XCTFail("expected notification")
        }
        XCTAssertEqual(method, "thread/status/changed")
        XCTAssertEqual(params["threadId"].stringValue, "a")
    }

    func testInvalidMessages() {
        if case .invalid = classify("not json") {} else { XCTFail("garbage should be invalid") }
        if case .invalid = classify(#"{"foo":1}"#) {} else { XCTFail("no id/method should be invalid") }
        if case .invalid = classify(#"{"id":{"x":1},"result":1}"#) {} else { XCTFail("object id should be invalid") }
    }

    func testRequestIdRoundTripsExactly() throws {
        let encoder = JSONEncoder()
        XCTAssertEqual(String(decoding: try encoder.encode(AppServerProtocol.RequestID.int(42)), as: UTF8.self), "42")
        XCTAssertEqual(String(decoding: try encoder.encode(AppServerProtocol.RequestID.string("x")), as: UTF8.self), #""x""#)
        XCTAssertEqual(AppServerProtocol.RequestID(json: .double(5)), .int(5))
        XCTAssertNil(AppServerProtocol.RequestID(json: .null))
    }

    func testFramerBuffersPartialLines() {
        var framer = JSONLineFramer()
        XCTAssertEqual(framer.append(Data(#"{"id":1,"res"#.utf8)), [])
        let lines = framer.append(Data("ult\":2}\r\n\n{\"method\":\"a\"}\n{\"par".utf8))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, [#"{"id":1,"result":2}"#, #"{"method":"a"}"#])
        XCTAssertEqual(framer.bufferedByteCount, 5)
        XCTAssertEqual(framer.append(Data("ams\":1}\n".utf8)).map { String(decoding: $0, as: UTF8.self) }, [#"{"params":1}"#])
        XCTAssertEqual(framer.bufferedByteCount, 0)
    }

    func testThreadListDecodingIsLossy() throws {
        let json = #"""
        {"data":[
          {"id":"a","cwd":"/p","path":"/r/a.jsonl","source":"cli","updatedAt":100},
          {"cwd":"/missing-id"},
          {"id":"b","cwd":"/p","source":{"subAgent":{"parent":"a"}},"updatedAt":90.0},
          {"id":"c","parentThreadId":"a"}
        ],"nextCursor":"next"}
        """#
        let result = try JSONDecoder().decode(AppServerProtocol.ThreadListResult.self, from: Data(json.utf8))
        XCTAssertEqual(result.data.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(result.nextCursor, "next")
        XCTAssertFalse(result.data[0].isSubAgent)
        XCTAssertTrue(result.data[1].isSubAgent)
        XCTAssertNil(result.data[1].source)
        XCTAssertEqual(result.data[1].updatedAt, 90)
        XCTAssertTrue(result.data[2].isSubAgent)
    }
}

// MARK: - Rollout analysis

final class CodexRolloutTests: XCTestCase {
    private func line(_ ts: String, _ type: String, _ payload: String) -> String {
        #"{"timestamp":"\#(ts)","type":"\#(type)","payload":\#(payload)}"#
    }

    private var completedTurn: [String] {
        [
            line("2026-06-17T17:16:02.022Z", "session_meta", #"{"id":"t","cwd":"/p"}"#),
            line("2026-06-17T17:16:02.023Z", "event_msg", #"{"type":"task_started","turn_id":"x"}"#),
            line("2026-06-17T17:16:02.024Z", "turn_context", #"{"approval_policy":"on-request"}"#),
            line("2026-06-17T17:16:10.087Z", "response_item", #"{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Working on it"}]}"#),
            line("2026-06-17T17:16:10.090Z", "response_item", #"{"type":"function_call","name":"exec_command","call_id":"c1"}"#),
            line("2026-06-17T17:16:10.240Z", "response_item", #"{"type":"function_call_output","call_id":"c1","output":"ok"}"#),
            line("2026-06-17T17:16:11.000Z", "event_msg", #"{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1784308562},"secondary":null,"rate_limit_reached_type":null}}"#),
            line("2026-06-17T17:16:12.500Z", "event_msg", #"{"type":"task_complete","last_agent_message":"All done — tests pass."}"#),
        ]
    }

    func testCompletedTurn() {
        let s = CodexRollout.summarize(text: completedTurn.joined(separator: "\n"))
        XCTAssertEqual(s.phase, .completed)
        XCTAssertEqual(s.lastAgentMessage, "All done — tests pass.")
        XCTAssertEqual(s.turnEndedAt, CodexRollout.parseTimestamp("2026-06-17T17:16:12.500Z"))
        XCTAssertNil(s.pendingRequest)
        XCTAssertEqual(s.rateLimit?.limitId, "codex")
        XCTAssertNil(s.rateLimit?.limitedUntil)
    }

    func testHousekeepingAfterTurnEndKeepsPhaseAndEndTime() {
        let lines = completedTurn + [
            line("2026-06-17T17:20:00.000Z", "event_msg", #"{"type":"thread_settings_applied"}"#),
            line("2026-06-17T17:20:00.100Z", "world_state", #"{}"#),
        ]
        let s = CodexRollout.summarize(text: lines.joined(separator: "\n"))
        XCTAssertEqual(s.phase, .completed)
        XCTAssertEqual(s.turnEndedAt, CodexRollout.parseTimestamp("2026-06-17T17:16:12.500Z"))
    }

    func testInTurnWhenStartScrolledOutOfTail() {
        // Tail begins mid-turn: only response items, no task_started.
        let lines = Array(completedTurn[3...5])
        let s = CodexRollout.summarize(text: lines.joined(separator: "\n"))
        XCTAssertEqual(s.phase, .inTurn)
        XCTAssertEqual(s.lastAgentMessage, "Working on it")
    }

    func testNewTurnAfterCompletion() {
        let lines = completedTurn + [line("2026-06-17T17:30:00.000Z", "event_msg", #"{"type":"task_started"}"#)]
        let s = CodexRollout.summarize(text: lines.joined(separator: "\n"))
        XCTAssertEqual(s.phase, .inTurn)
        XCTAssertNil(s.lastAgentMessage)
    }

    func testAbortedTurn() {
        let lines = Array(completedTurn[0...4]) + [
            line("2026-06-17T17:16:45.033Z", "event_msg", #"{"type":"turn_aborted","reason":"interrupted","completed_at":1781716605}"#),
        ]
        let s = CodexRollout.summarize(text: lines.joined(separator: "\n"))
        XCTAssertEqual(s.phase, .aborted)
        XCTAssertEqual(s.turnEndedAt, CodexRollout.parseTimestamp("2026-06-17T17:16:45.033Z"))
    }

    func testExplicitApprovalRequestIsPendingUntilActivity() {
        let request = line("2026-06-17T17:16:20.000Z", "event_msg", #"{"type":"exec_approval_request","command":["git","push"]}"#)
        var s = CodexRollout.summarize(text: (Array(completedTurn[0...5]) + [request]).joined(separator: "\n"))
        XCTAssertEqual(s.pendingRequest, .approval("$ git push"))
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: 30, activeWindow: 90), .waitingOnApproval)

        let after = line("2026-06-17T17:16:30.000Z", "response_item", #"{"type":"function_call_output","call_id":"c2"}"#)
        s = CodexRollout.summarize(text: (Array(completedTurn[0...5]) + [request, after]).joined(separator: "\n"))
        XCTAssertNil(s.pendingRequest)
    }

    func testRateLimitReachedFromTokenCount() {
        let lines = [line("2026-06-17T17:16:11.000Z", "event_msg", #"{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"resets_at":1784308562},"secondary":{"used_percent":40,"resets_at":1784900000}}}"#)]
        let s = CodexRollout.summarize(text: lines.joined(separator: "\n"))
        XCTAssertEqual(s.rateLimit?.limitedUntil, Date(timeIntervalSince1970: 1784308562))
        XCTAssertEqual(s.rateLimit?.observedAt, CodexRollout.parseTimestamp("2026-06-17T17:16:11.000Z"))
    }

    func testDeriveState() {
        var s = CodexRollout.Summary()
        s.phase = .inTurn
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: 5, activeWindow: 90), .active)
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: 600, activeWindow: 90), .active)
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: CodexBackend.stalledTurnSeconds + 1, activeWindow: 90), .interrupted)
        s.phase = .completed
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: 1, activeWindow: 90), .idle)
        s.phase = .aborted
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: 1, activeWindow: 90), .idle)
        s.phase = .unknown
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: 20, activeWindow: 90), .active)
        XCTAssertEqual(CodexBackend.deriveState(summary: s, rolloutAge: 200, activeWindow: 90), .idle)
    }

    func testIdlePageGatingAndStableId() {
        let thread = AppServerProtocol.ThreadSummary(id: "019ed694-d82d", cwd: "/Users/me/proj", path: "/r/x.jsonl",
                                                     source: "cli", updatedAt: nil)
        var s = CodexRollout.Summary()
        s.phase = .completed
        let ended = Date(timeIntervalSince1970: 1_800_000_000)
        s.turnEndedAt = ended
        s.lastAgentMessage = "Done"

        XCTAssertNil(CodexBackend.idlePage(thread: thread, summary: s, rolloutMtime: ended,
                                           now: ended.addingTimeInterval(30), idleDelay: 60), "too soon")
        let page = CodexBackend.idlePage(thread: thread, summary: s, rolloutMtime: ended,
                                         now: ended.addingTimeInterval(61), idleDelay: 60)
        XCTAssertEqual(page?.id, "codex-idle-019ed694-d82d-1800000000")
        XCTAssertEqual(page?.kind, .idle)
        XCTAssertEqual(page?.backend, .codex)
        XCTAssertEqual(page?.context, "Done")
        XCTAssertEqual(page?.projectName, "proj")

        // A later housekeeping write bumps mtime but not the id.
        let later = CodexBackend.idlePage(thread: thread, summary: s, rolloutMtime: ended.addingTimeInterval(500),
                                          now: ended.addingTimeInterval(600), idleDelay: 60)
        XCTAssertEqual(later?.id, page?.id)

        XCTAssertNil(CodexBackend.idlePage(thread: thread, summary: s, rolloutMtime: ended,
                                           now: ended.addingTimeInterval(CodexBackend.maxIdlePageAge + 1), idleDelay: 60), "too old")
        s.phase = .aborted
        XCTAssertNil(CodexBackend.idlePage(thread: thread, summary: s, rolloutMtime: ended,
                                           now: ended.addingTimeInterval(120), idleDelay: 60), "aborted turns don't page")
    }

    func testTailTextCutsPartialFirstLineAtByteLevel() {
        // "—" is 3 bytes (E2 80 94); start the slice inside it.
        let full = Data("x—y\n{\"a\":1}\n{\"b\":2}\n".utf8)
        let sliced = full.subdata(in: 2..<full.count)
        XCTAssertNil(String(data: sliced, encoding: .utf8), "precondition: strict decoding fails")
        XCTAssertEqual(CodexRollout.tailText(from: sliced, droppingPartialFirstLine: true), "{\"a\":1}\n{\"b\":2}\n")
        XCTAssertEqual(CodexRollout.tailText(from: Data("no newline".utf8), droppingPartialFirstLine: true), "")
        XCTAssertEqual(CodexRollout.tailText(from: Data("whole\n".utf8), droppingPartialFirstLine: false), "whole\n")
    }

    func testReadTailOnFileWithMultibyteBoundary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-tail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rollout-test.jsonl")
        let filler = String(repeating: "—", count: 400)   // 1200 bytes of 3-byte chars
        let last = completedTurn.last!
        try Data(("{\"f\":\"\(filler)\"}\n" + last + "\n").utf8).write(to: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        // Land the seek one byte into a multi-byte character inside the
        // filler: offset 307 = 6 bytes of `{"f":"` + 100 whole "—" + 1.
        let maxBytes = size - 307
        let tail = try XCTUnwrap(CodexRollout.readTail(of: url, maxBytes: maxBytes))
        XCTAssertTrue(tail.truncated)
        XCTAssertEqual(tail.text, last + "\n")
        XCTAssertEqual(CodexRollout.summarize(text: tail.text).phase, .completed)
    }
}

// MARK: - Discovery, rate limits, lifecycle

final class CodexPolicyTests: XCTestCase {
    private func thread(_ id: String, cwd: String = "/p", updated: Int?, subAgent: Bool = false) -> AppServerProtocol.ThreadSummary {
        AppServerProtocol.ThreadSummary(id: id, cwd: cwd, path: "/r/\(id).jsonl", updatedAt: updated, isSubAgent: subAgent)
    }

    func testMergeThreadPagesDedupesKeepingNewest() {
        let merged = CodexBackend.mergeThreadPages([
            [thread("a", updated: 100), thread("b", updated: 90)],
            [thread("b", updated: 95), thread("c", updated: 80), thread("a", updated: 50)],
        ])
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(merged.map(\.updatedAt), [100, 95, 80])
    }

    func testPageEndsOnlyTrustsDescendingPages() {
        let cutoff = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(CodexBackend.pageEnds([thread("a", updated: 2000), thread("b", updated: 500)], olderThan: cutoff))
        XCTAssertFalse(CodexBackend.pageEnds([thread("a", updated: 500), thread("b", updated: 2000)], olderThan: cutoff))
        XCTAssertFalse(CodexBackend.pageEnds([thread("a", updated: 2000), thread("b", updated: 1500)], olderThan: cutoff))
        XCTAssertFalse(CodexBackend.pageEnds([], olderThan: cutoff))
    }

    func testSelectWatched() {
        let now = Date(timeIntervalSince1970: 100_000)
        let recent = Int(now.timeIntervalSince1970) - 60
        let old = Int(now.timeIntervalSince1970) - 10 * 3600
        let threads = [
            thread("recent", cwd: "/x", updated: recent),
            thread("oldInLiveDir", cwd: "/live", updated: old),
            thread("olderInLiveDir", cwd: "/live", updated: old - 100),
            thread("oldElsewhere", cwd: "/y", updated: old),
            thread("stickyOld", cwd: "/z", updated: old - 500),
            thread("sub", cwd: "/x", updated: recent, subAgent: true),
        ]
        let watched = CodexBackend.selectWatched(threads: threads, liveCwds: ["/live"],
                                                 sticky: ["stickyOld"], now: now)
        XCTAssertEqual(watched, ["recent", "oldInLiveDir", "stickyOld"])

        // A long turn whose list entry went stale stays watched while its
        // rollout keeps being written.
        let stillWriting = CodexBackend.selectWatched(threads: threads, liveCwds: [], sticky: [],
                                                      recentlyWritten: ["oldElsewhere", "sub"], now: now)
        XCTAssertEqual(stillWriting, ["recent", "oldElsewhere"])
    }

    func testRateLimitParsingAllShapes() {
        let now = Date()
        let camel: AppServerProtocol.JSON = .object(["rateLimits": .object([
            "limitId": .string("codex"),
            "primary": .object(["usedPercent": .int(100), "resetsAt": .int(1_900_000_000)]),
            "secondary": .object(["usedPercent": .double(100), "resetsAt": .int(1_900_500_000)]),
        ])])
        let a = CodexRateLimitSnapshot.parse(notificationParams: camel, observedAt: now)
        XCTAssertEqual(a?.limitedUntil, Date(timeIntervalSince1970: 1_900_500_000), "later of two exhausted windows")

        let flat: AppServerProtocol.JSON = .object(["limitId": .string("x"), "usedPercent": .int(55), "resetsAt": .int(1_900_000_000)])
        let b = CodexRateLimitSnapshot.parse(notificationParams: flat, observedAt: now)
        XCTAssertEqual(b?.limitId, "x")
        XCTAssertNil(b?.limitedUntil)

        let reached: AppServerProtocol.JSON = .object([
            "limit_id": .string("codex"),
            "primary": .object(["used_percent": .double(97), "resets_at": .int(1_900_000_000)]),
            "rate_limit_reached_type": .string("primary"),
        ])
        XCTAssertEqual(CodexRateLimitSnapshot.parse(reached, observedAt: now)?.limitedUntil,
                       Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertNil(CodexRateLimitSnapshot.parse(.object(["foo": .int(1)]), observedAt: now))
    }

    func testStatusHintReadsNestedStatus() {
        let waiting: AppServerProtocol.JSON = .object([
            "threadId": .string("t"),
            "status": .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnApproval")])]),
        ])
        XCTAssertEqual(CodexBackend.statusHint(method: "thread/status/changed", params: waiting)?.state, .waitingOnApproval)
        let input: AppServerProtocol.JSON = .object([
            "threadId": .string("t"),
            "status": .object(["type": .string("active"), "activeFlags": .array([.string("waitingOnUserInput")])]),
        ])
        XCTAssertEqual(CodexBackend.statusHint(method: "thread/status/changed", params: input)?.state, .waitingOnUser)
        let active: AppServerProtocol.JSON = .object(["threadId": .string("t"), "status": .object(["type": .string("active")])])
        XCTAssertEqual(CodexBackend.statusHint(method: "thread/status/changed", params: active)?.state, .active)
        let unknown: AppServerProtocol.JSON = .object(["threadId": .string("t"), "status": .object(["type": .string("weird")])])
        XCTAssertNil(CodexBackend.statusHint(method: "thread/status/changed", params: unknown))
        XCTAssertNil(CodexBackend.statusHint(method: "account/rateLimits/updated", params: active))
    }

    func testRestartBackoff() {
        XCTAssertEqual(CodexBackend.restartDelay(afterFailures: 0), 0)
        XCTAssertEqual(CodexBackend.restartDelay(afterFailures: 1), 15)
        XCTAssertEqual(CodexBackend.restartDelay(afterFailures: 2), 30)
        XCTAssertEqual(CodexBackend.restartDelay(afterFailures: 3), 60)
        XCTAssertEqual(CodexBackend.restartDelay(afterFailures: 6), 300)
        XCTAssertEqual(CodexBackend.restartDelay(afterFailures: 50), 300)
    }

    func testReplyPlanOnlyTypesAfterTurnEnds() {
        var s = CodexRollout.Summary()
        s.phase = .inTurn
        XCTAssertEqual(CodexBackend.replyPlan(action: "custom", text: "hi", kind: "idle", summary: s),
                       .refuse("Codex is still working — reply once the turn finishes"))
        s.phase = .unknown
        if case .type = CodexBackend.replyPlan(action: "custom", text: "hi", kind: "idle", summary: s) { XCTFail("unknown phase must refuse") }
        s.phase = .completed
        XCTAssertEqual(CodexBackend.replyPlan(action: "custom", text: "  run the tests \n", kind: "idle", summary: s), .type("run the tests"))
        XCTAssertEqual(CodexBackend.replyPlan(action: "approve", text: "", kind: "idle", summary: s), .type("yes, proceed"))
        XCTAssertEqual(CodexBackend.replyPlan(action: "carry_on", text: "", kind: nil, summary: s), .type("carry on"))
        if case .type = CodexBackend.replyPlan(action: nil, text: "", kind: "idle", summary: s) { XCTFail("empty must refuse") }
        if case .type = CodexBackend.replyPlan(action: "approve", text: "", kind: "permission", summary: s) {
            XCTFail("approval pages can't be answered by typing")
        }
        s.pendingRequest = .approval("$ ls")
        if case .type = CodexBackend.replyPlan(action: "custom", text: "x", kind: "idle", summary: s) { XCTFail("pending prompt must refuse") }
    }

    func testShouldPageIdle() {
        XCTAssertTrue(CodexBackend.shouldPageIdle(source: .terminal, ownerAlive: { true }))
        XCTAssertFalse(CodexBackend.shouldPageIdle(source: .terminal, ownerAlive: { false }), "closed TUI")
        XCTAssertFalse(CodexBackend.shouldPageIdle(source: .exec, ownerAlive: { true }), "scripted exec run")
        XCTAssertTrue(CodexBackend.shouldPageIdle(source: .desktop, ownerAlive: { false }))
        XCTAssertTrue(CodexBackend.shouldPageIdle(source: .vscode, ownerAlive: { false }))
    }

    func testIdSafe() {
        XCTAssertEqual(CodexBackend.idSafe("42"), "42")
        XCTAssertEqual(CodexBackend.idSafe("a b/c"), "a_b_c")
        XCTAssertEqual(CodexBackend.idSafe(String(repeating: "x", count: 100)).count, 64)
    }
}

// MARK: - Injector targeting (pure parts only; never touches real sessions)

final class CodexInjectorTests: XCTestCase {
    func testInteractiveCommandDetection() {
        XCTAssertTrue(CodexProcessScanner.isInteractiveCodexCommand("/usr/local/bin/codex"))
        XCTAssertTrue(CodexProcessScanner.isInteractiveCodexCommand("node /usr/local/bin/codex --model gpt-5"))
        XCTAssertTrue(CodexProcessScanner.isInteractiveCodexCommand("/opt/x/vendor/aarch64-apple-darwin/codex/codex resume"))
        XCTAssertTrue(CodexProcessScanner.isInteractiveCodexCommand("node /usr/local/lib/node_modules/@openai/codex/bin/codex.js"))
        XCTAssertFalse(CodexProcessScanner.isInteractiveCodexCommand("/usr/local/bin/codex app-server"))
        XCTAssertFalse(CodexProcessScanner.isInteractiveCodexCommand("node /usr/local/bin/codex exec resume abc hi"))
        XCTAssertFalse(CodexProcessScanner.isInteractiveCodexCommand("/usr/bin/vim codex.md"))
        XCTAssertFalse(CodexProcessScanner.isInteractiveCodexCommand("node server.js"))
    }

    func testParseLsof() {
        let out = "p100\nfcwd\nn/Users/me/proj\nf12\nn/Users/me/.codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-abc.jsonl\nf13\nn/dev/ttys004\np200\nfcwd\nn/tmp\n"
        let parsed = CodexProcessScanner.parseLsof(out)
        XCTAssertEqual(parsed[100]?.cwd, "/Users/me/proj")
        XCTAssertEqual(parsed[100]?.rollouts, ["/Users/me/.codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-abc.jsonl"])
        XCTAssertEqual(parsed[200]?.cwd, "/tmp")
        XCTAssertEqual(parsed[200]?.rollouts, [])
    }

    private func proc(_ pid: Int32, tty: String?, cwd: String, rollouts: Set<String> = []) -> CodexProcess {
        CodexProcess(pid: pid, ppid: 1, tty: tty, cwd: cwd, openRollouts: rollouts, command: "codex")
    }

    func testResolveTarget() {
        // Wrapper + native child share a tty → one target.
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: nil,
                                                   processes: [proc(1, tty: "ttys001", cwd: "/p"), proc(2, tty: "ttys001", cwd: "/p")]),
                       .tty("ttys001", pid: 1))
        // Two terminals in the same folder → ambiguous.
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: nil,
                                                   processes: [proc(1, tty: "ttys001", cwd: "/p"), proc(3, tty: "ttys002", cwd: "/p")]),
                       .ambiguous(count: 2))
        // ...unless the rollout pins it down.
        let ours = "/s/rollout-1-ours.jsonl"
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours,
                                                   processes: [proc(1, tty: "ttys001", cwd: "/p", rollouts: [ours]),
                                                               proc(3, tty: "ttys002", cwd: "/p", rollouts: ["/s/rollout-2-other.jsonl"])]),
                       .tty("ttys001", pid: 1))
        // The only codex in the folder is on another thread → nobody owns ours.
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours,
                                                   processes: [proc(3, tty: "ttys002", cwd: "/p", rollouts: ["/s/rollout-2-other.jsonl"])]),
                       .none)
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: nil, processes: [proc(1, tty: nil, cwd: "/p")]),
                       .noTerminal)
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: nil, processes: [proc(1, tty: "ttys001", cwd: "/q")]),
                       .none)
    }

    func testHostDetection() {
        let table = [
            ProcessRunner.ProcessInfoRow(pid: 10, ppid: 1, tty: "??", command: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            ProcessRunner.ProcessInfoRow(pid: 11, ppid: 10, tty: "ttys001", command: "login -pf me"),
            ProcessRunner.ProcessInfoRow(pid: 12, ppid: 11, tty: "ttys001", command: "-zsh"),
            ProcessRunner.ProcessInfoRow(pid: 13, ppid: 12, tty: "ttys001", command: "node /usr/local/bin/codex"),
            ProcessRunner.ProcessInfoRow(pid: 20, ppid: 1, tty: "??", command: "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"),
            ProcessRunner.ProcessInfoRow(pid: 21, ppid: 20, tty: "ttys002", command: "/usr/local/bin/codex"),
            ProcessRunner.ProcessInfoRow(pid: 30, ppid: 1, tty: "??", command: "tmux new -s work"),
            ProcessRunner.ProcessInfoRow(pid: 31, ppid: 30, tty: "ttys003", command: "/usr/local/bin/codex"),
        ]
        XCTAssertEqual(CodexInjector.host(ofPid: 13, table: table), .terminalApp)
        XCTAssertEqual(CodexInjector.host(ofPid: 21, table: table), .app("Visual Studio Code"))
        XCTAssertEqual(CodexInjector.host(ofPid: 31, table: table), .tmux)
        XCTAssertEqual(CodexInjector.host(ofPid: 99, table: table), .unknown)
    }

    func testTmuxPaneParsing() {
        let out = "%1 /dev/ttys001\n%7 /dev/ttys004\n"
        XCTAssertEqual(CodexInjector.parseTmuxPane(out, tty: "ttys004"), "%7")
        XCTAssertEqual(CodexInjector.parseTmuxPane(out, tty: "/dev/ttys001"), "%1")
        XCTAssertNil(CodexInjector.parseTmuxPane(out, tty: "ttys009"))
    }

    func testSanitize() {
        XCTAssertEqual(CodexInjector.sanitize("hello\u{1B}[31m world\r\n"), "hello[31m world")
        XCTAssertEqual(CodexInjector.sanitize("!rm -rf /"), " !rm -rf /")
        XCTAssertEqual(CodexInjector.sanitize("--help"), " --help")
        XCTAssertEqual(CodexInjector.sanitize("a\r\nb"), "a\nb")
    }

    func testExecResumeArguments() {
        XCTAssertEqual(CodexInjector.execResumeArguments(threadId: "t", text: "go", skipGitRepoCheck: false),
                       ["exec", "resume", "t", "go"])
        XCTAssertEqual(CodexInjector.execResumeArguments(threadId: "t", text: "go", skipGitRepoCheck: true),
                       ["exec", "--skip-git-repo-check", "resume", "t", "go"])
    }
}
