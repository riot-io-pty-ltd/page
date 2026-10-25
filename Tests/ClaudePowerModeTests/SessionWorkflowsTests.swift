import XCTest
@testable import ClaudePowerMode

/// A session's dynamic workflows, read from files laid out the way Claude
/// Code writes them (temp dirs only).
final class SessionWorkflowsTests: XCTestCase {
    private var dir: URL!
    private var transcript: String { dir.appendingPathComponent("sess.jsonl").path }
    private let now = Date(timeIntervalSince1970: 1_792_900_000)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-wf-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func launchLine(_ runId: String, summary: String, script: String, at: String = "2026-10-25T07:46:00.000Z") -> String {
        let text = "Workflow launched in background. Task ID: w8tdxhqoc\nSummary: \(summary)\nTranscript dir: \(dir.path)/sess/subagents/workflows/\(runId)\nScript file: \(script) (Edit this file with Write/Edit and re-invoke Workflow)"
        let obj: [String: Any] = ["type": "user", "timestamp": at,
                                  "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": text]]]]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func write(_ path: String, _ text: String) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeRun(_ runId: String, started: [(String, String, String)], finished: [String]) throws {
        let base = "\(dir.path)/sess/subagents/workflows/\(runId)"
        var lines = [#"{"type":"launched"}"#]
        for (id, label, phase) in started {
            lines.append(#"{"type":"started","key":"k","agentId":"\#(id)","label":"\#(label)","phase":"\#(phase)"}"#)
            try write("\(base)/agent-\(id).jsonl", "")
        }
        for id in finished { lines.append(#"{"type":"result","key":"k","agentId":"\#(id)","result":"{'big': 'output'}"}"#) }
        try write("\(base)/journal.jsonl", lines.joined(separator: "\n") + "\n")
    }

    // MARK: pure

    func testLaunchRecordParsing() throws {
        let line = launchLine("wf_5efbb134-a4c", summary: "Capture every level", script: "/x/scripts/design-pass-wf_0f6.js")
        let l = try XCTUnwrap(SessionWorkflows.launches(inTranscriptLines: Data(line.utf8)).first)
        XCTAssertEqual(l.runId, "wf_5efbb134-a4c")
        XCTAssertEqual(l.summary, "Capture every level")
        XCTAssertEqual(l.scriptPath, "/x/scripts/design-pass-wf_0f6.js")
        XCTAssertNotNil(l.at)
        XCTAssertNil(SessionWorkflows.launch(fromToolResult: "Workflow launched. Transcript dir: /x/../../etc", at: nil),
                     "a run id that isn't a plain id is ignored")
    }

    func testJournalAndScriptName() {
        let j = SessionWorkflows.journal(Data("""
        {"type":"launched"}
        {"type":"started","agentId":"a1","label":"capture","phase":"Capture"}
        {"type":"started","agentId":"a2","label":"fix ch5","phase":"Fix B"}
        {"type":"result","agentId":"a1","result":"…"}
        not json
        {"type":"started","agentId":"../x","label":"evil"}
        """.utf8))
        XCTAssertEqual(j.agents.map(\.id), ["a1", "a2"])
        XCTAssertEqual(j.finished, ["a1"])
        XCTAssertEqual(SessionWorkflows.scriptName("// x\nexport const meta = {\n  name: 'design-pass-ch1-8-opus',\n  phases: []\n}"),
                       "design-pass-ch1-8-opus")
        XCTAssertNil(SessionWorkflows.scriptName("const name = 'nope'"))
    }

    func testRunAssemblyStatusAndOrder() {
        var j = SessionWorkflows.Journal()
        j.agents = [("a1", "capture", "Capture"), ("a2", "fix sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789", "Fix B"), ("a3", "review", "Fix B")]
        j.finished = ["a1"]
        let activity = ["a1": now.addingTimeInterval(-600), "a2": now.addingTimeInterval(-30), "a3": now.addingTimeInterval(-5)]
        let run = SessionWorkflows.run(id: "wf_1", launch: nil, scriptName: "design-pass", journal: j, end: nil,
                                       agentActivity: activity, runStartedAt: now.addingTimeInterval(-3600), now: now)
        XCTAssertEqual(run.name, "design-pass")
        XCTAssertEqual(run.status, "running")
        XCTAssertEqual(run.done, 1)
        XCTAssertEqual(run.total, 3)
        XCTAssertEqual(run.phase, "Fix B")
        XCTAssertEqual(run.agents.map(\.id), ["a3", "a2", "a1"], "running first, newest first, then done")
        XCTAssertFalse(run.agents.map(\.label).joined().contains("abcdefghijklmnop"), "labels are redacted")

        let quiet = SessionWorkflows.run(id: "wf_2", launch: nil, scriptName: nil, journal: j, end: nil,
                                         agentActivity: activity.mapValues { $0.addingTimeInterval(-3600) },
                                         runStartedAt: nil, now: now)
        XCTAssertEqual(quiet.status, "stalled", "no end record and nothing written for 20 min")
        XCTAssertEqual(quiet.name, "wf_2", "no name anywhere: the run id")

        var end = SessionWorkflows.EndRecord()
        end.status = "killed"; end.name = "finish-chapters"; end.tokens = 1_383_902
        let ended = SessionWorkflows.run(id: "wf_3", launch: nil, scriptName: "other", journal: j, end: end,
                                         agentActivity: [:], runStartedAt: nil, now: now)
        XCTAssertEqual(ended.status, "killed")
        XCTAssertEqual(ended.name, "finish-chapters", "the end record's name wins")
        XCTAssertEqual(ended.tokens, 1_383_902)
    }

    /// Real journals record "failed" agents, and a killed run leaves agents
    /// that never finished: none of them shows as running.
    func testFailedAndCutOffAgentsAreNotRunning() {
        let j = SessionWorkflows.journal(Data("""
        {"type":"started","agentId":"a1","label":"build","phase":"Act 4"}
        {"type":"started","agentId":"a2","label":"review","phase":"Act 4"}
        {"type":"started","agentId":"a3","label":"review 2","phase":"Act 4"}
        {"type":"failed","agentId":"a1","error":"x"}
        {"type":"result","agentId":"a2","result":"ok"}
        """.utf8))
        var end = SessionWorkflows.EndRecord(); end.status = "killed"
        let killed = SessionWorkflows.run(id: "wf_k", launch: nil, scriptName: nil, journal: j, end: end,
                                          agentActivity: [:], runStartedAt: nil, now: now)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: killed.agents.map { ($0.id, $0.state) }),
                       ["a1": "failed", "a2": "done", "a3": "stopped"])
        XCTAssertEqual(killed.done, 1)
        let live = SessionWorkflows.run(id: "wf_l", launch: nil, scriptName: nil, journal: j, end: nil,
                                        agentActivity: ["a3": now], runStartedAt: now, now: now)
        XCTAssertEqual(live.agents.first?.id, "a3")
        XCTAssertEqual(live.agents.first?.state, "running")
        XCTAssertEqual(live.agents.first { $0.id == "a1" }?.state, "failed")
    }

    func testUnreadableEndRecordStillEndsTheRun() throws {
        try makeRun("wf_big", started: [("b1", "x", "P")], finished: [])
        try write("\(dir.path)/sess/workflows/wf_big.json", "{ not json")
        try write(transcript, "{}\n")
        let run = try XCTUnwrap(SessionWorkflowScanner().runs(transcript: transcript, now: now).first)
        XCTAssertEqual(run.status, "completed", "an end record exists: never running or stalled forever")
        XCTAssertFalse(run.agents.contains { $0.isRunning })
    }

    /// A single transcript line of 8 MB or more doesn't stall the backward
    /// scan: it's stepped over and the launch before it is still found.
    func testBackwardScanStepsOverAGiantLine() throws {
        let script = dir.appendingPathComponent("s.js").path
        try write(script, "export const meta = { name: 'before-giant' }")
        let giant = #"{"type":"assistant","x":""# + String(repeating: "g", count: 9 << 20) + "\"}"
        try write(transcript, launchLine("wf_g", summary: "s", script: script) + "\n" + giant + "\n")
        try makeRun("wf_g", started: [("g1", "x", "P")], finished: [])
        let scanner = SessionWorkflowScanner()
        var name: String?
        for _ in 0..<3 { name = scanner.runs(transcript: transcript, now: now).first?.name }
        XCTAssertEqual(name, "before-giant")
    }

    func testListingAndSizeCap() throws {
        func r(_ id: String, _ status: String, started: TimeInterval, ended: TimeInterval? = nil, agents: Int = 0) -> WorkflowRunInfo {
            WorkflowRunInfo(id: id, name: id, summary: nil, status: status, phase: nil, done: 0, total: agents,
                            startedAt: now.addingTimeInterval(started), endedAt: ended.map { now.addingTimeInterval($0) }, tokens: nil,
                            agents: (0..<agents).map { .init(id: "a\($0)", label: String(repeating: "x", count: 150), phase: "p", state: "running", lastActivityAt: now) })
        }
        let listed = SessionWorkflows.listed([r("old", "completed", started: -200_000, ended: -100_000),
                                              r("done", "completed", started: -7200, ended: -3600),
                                              r("live", "running", started: -60),
                                              r("live2", "running", started: -30)], now: now)
        XCTAssertEqual(listed.map(\.id), ["live2", "live", "done"], "running first, then finished from the last day")

        let big = (0..<12).map { r("wf_\($0)", "running", started: Double(-$0), agents: 100) }
        let data = try XCTUnwrap(SessionWorkflows.plaintext(header: ["kind": "workflows"], runs: big))
        XCTAssertLessThanOrEqual(data.count, SessionWorkflows.maxPlaintextBytes, "agents trimmed to fit")
    }

    func testAgentPathsRejectUnsafeIds() {
        XCTAssertEqual(SessionWorkflows.agentTranscript(transcript: "/p/s.jsonl", runId: "wf_1", agentId: "a5"),
                       "/p/s/subagents/workflows/wf_1/agent-a5.jsonl")
        XCTAssertNil(SessionWorkflows.agentTranscript(transcript: "/p/s.jsonl", runId: "../../etc", agentId: "a5"))
        XCTAssertNil(SessionWorkflows.agentTranscript(transcript: "/p/s.jsonl", runId: "wf_1", agentId: "a/../b"))
        XCTAssertNil(SessionWorkflows.agentTranscript(transcript: "/p/s.jsonl", runId: "wf_1", agentId: ""))
    }

    // MARK: scanner (files)

    func testScannerFindsRunsNamesAndProgress() throws {
        let script = dir.appendingPathComponent("design-pass-wf_old.js").path
        try write(script, "export const meta = {\n  name: 'design-pass-ch1-8-opus',\n}\n")
        var lines = (0..<50).map { _ in #"{"type":"assistant","message":{"content":[{"type":"text","text":"filler"}]}}"# }
        lines.append(launchLine("wf_aaa", summary: "Capture and fix", script: script))
        try write(transcript, lines.joined(separator: "\n") + "\n")
        try makeRun("wf_aaa", started: [("a1", "capture", "Capture"), ("a2", "fix", "Fix B")], finished: ["a1"])
        try makeRun("wf_bbb", started: [("b1", "build", "Build")], finished: ["b1"])
        try write("\(dir.path)/sess/workflows/wf_bbb.json",
                  #"{"status":"completed","workflowName":"finish-act","totalTokens":5000,"startTime":\#(Int(now.timeIntervalSince1970 * 1000) - 60000),"durationMs":30000}"#)

        let scanner = SessionWorkflowScanner()
        let runs = scanner.runs(transcript: transcript, now: now)
        XCTAssertEqual(Set(runs.map(\.id)), ["wf_aaa", "wf_bbb"])
        let a = try XCTUnwrap(runs.first { $0.id == "wf_aaa" })
        XCTAssertEqual(a.name, "design-pass-ch1-8-opus", "from the launch record's script")
        XCTAssertEqual(a.summary, "Capture and fix")
        XCTAssertEqual("\(a.done)/\(a.total)", "1/2")
        let b = try XCTUnwrap(runs.first { $0.id == "wf_bbb" })
        XCTAssertEqual(b.name, "finish-act")
        XCTAssertEqual(b.status, "completed")
        XCTAssertEqual(b.tokens, 5000)

        // Progress moves: picked up on the next call.
        try makeRun("wf_aaa", started: [("a1", "capture", "Capture"), ("a2", "fix", "Fix B")], finished: ["a1", "a2"])
        XCTAssertEqual(scanner.runs(transcript: transcript, now: now).first { $0.id == "wf_aaa" }?.done, 2)
    }

    /// Session transcripts run to hundreds of MB: a launch far back is found
    /// by reading backwards from the end, and a new one by reading appended
    /// bytes, without re-reading the whole file.
    func testScannerReadsBackwardsAndForwardsInChunks() throws {
        let script = dir.appendingPathComponent("s.js").path
        try write(script, "export const meta = { name: 'far-back' }")
        let filler = String(repeating: #"{"type":"assistant","message":{"content":[{"type":"text","text":"\#(String(repeating: "z", count: 1000))"}]}}"# + "\n", count: 20_000)
        try write(transcript, launchLine("wf_far", summary: "old", script: script) + "\n" + filler)   // ~20 MB after it
        try makeRun("wf_far", started: [("f1", "x", "P")], finished: [])

        let scanner = SessionWorkflowScanner()
        XCTAssertEqual(scanner.runs(transcript: transcript, now: now).first?.name, "far-back")

        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: transcript))
        try h.seekToEnd()
        try h.write(contentsOf: Data((launchLine("wf_new", summary: "new", script: script) + "\n").utf8))
        try h.close()
        try makeRun("wf_new", started: [("n1", "y", "P")], finished: [])
        let runs = scanner.runs(transcript: transcript, now: now)
        XCTAssertEqual(runs.first { $0.id == "wf_new" }?.summary, "new")
    }

    func testNoWorkflowsDirIsEmpty() throws {
        try write(transcript, "{}\n")
        XCTAssertTrue(SessionWorkflowScanner().runs(transcript: transcript, now: now).isEmpty)
    }
}
