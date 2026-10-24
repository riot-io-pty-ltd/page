import XCTest
@testable import ClaudePowerMode

/// SESSIONS-PROTOCOL.md §4 `transcript`: what the phone sees of a session.
final class SessionTranscriptTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-transcript-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func line(_ obj: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func write(_ lines: [String], name: String = "t.jsonl") -> String {
        let path = dir.appendingPathComponent(name).path
        try! (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func append(_ lines: [String], to path: String) {
        let h = FileHandle(forWritingAtPath: path)!
        h.seekToEndOfFile()
        h.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        h.closeFile()
    }

    private func user(_ uuid: String, _ content: Any, extra: [String: Any] = [:]) -> String {
        var o: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": "2026-10-24T12:00:00.000Z",
                                "message": ["role": "user", "content": content]]
        o.merge(extra) { $1 }
        return line(o)
    }

    private func assistant(_ uuid: String, _ content: [[String: Any]], extra: [String: Any] = [:]) -> String {
        var o: [String: Any] = ["type": "assistant", "uuid": uuid, "timestamp": "2026-10-24T12:00:01.000Z",
                                "message": ["role": "assistant", "content": content]]
        o.merge(extra) { $1 }
        return line(o)
    }

    // MARK: Claude

    func testClaudeRowsSkipToolOutputSidechainsAndMeta() throws {
        let path = write([
            user("u1", "Please run the tests"),
            assistant("a1", [["type": "text", "text": "Running them now."],
                             ["type": "tool_use", "id": "t1", "name": "Bash",
                              "input": ["command": "npm test", "description": "Run the suite"]]]),
            user("u2", [["type": "tool_result", "tool_use_id": "t1", "content": "SECRET TEST OUTPUT 42 passing"]]),
            assistant("a2", [["type": "thinking", "thinking": "hmm"], ["type": "text", "text": "All green."]]),
            user("u3", "subagent prompt", extra: ["isSidechain": true]),
            assistant("a3", [["type": "text", "text": "subagent answer"]], extra: ["isSidechain": true]),
            user("u4", "Caveat: local command output", extra: ["isMeta": true]),
            line(["type": "attachment", "uuid": "q1", "timestamp": "2026-10-24T12:00:02Z",
                  "attachment": ["type": "queued_command", "prompt": "also update the README", "origin": ["kind": "human"]]]),
            line(["type": "attachment", "uuid": "q2", "attachment": ["type": "queued_command", "prompt": "task notification",
                                                                    "origin": ["kind": "task-notification"]]]),
            user("u5", [["type": "text", "text": "[Request interrupted by user]"]]),
            user("u6", "<local-command-stdout>ls output</local-command-stdout>"),
            user("u7", "<command-name>/model</command-name>\n<command-args>opus</command-args>"),
            line(["type": "system", "uuid": "s1", "subtype": "turn_duration"]),
            "not json at all",
        ])
        let snap = try XCTUnwrap(SessionTranscript.read(path: path, format: .claude))
        XCTAssertEqual(snap.entries.map(\.role), [.user, .assistant, .tool, .assistant, .user, .system, .user])
        XCTAssertEqual(snap.entries.map(\.text), ["Please run the tests", "Running them now.", "Bash: npm test", "All green.",
                                                  "also update the README", "Interrupted", "/model opus"])
        XCTAssertEqual(snap.entries.map(\.id), ["u1", "a1#0", "a1#1", "a2#1", "q1", "u5", "u7"])
        XCTAssertEqual(snap.entries[2].tool, "Bash")
        XCTAssertFalse(snap.truncated)
        XCTAssertFalse(snap.entries.contains { $0.text.contains("SECRET TEST OUTPUT") || $0.text.contains("subagent") })
        XCTAssertNotNil(snap.entries[0].at)
    }

    func testToolRowsAreOneLiners() {
        XCTAssertEqual(SessionTranscript.toolLine(InterventionDetector.describeToolUse(
            name: "Edit", input: ["file_path": "Sources/App.swift", "old_string": "a\nb", "new_string": "c"])), "Edit: Sources/App.swift")
        XCTAssertEqual(SessionTranscript.toolLine(InterventionDetector.describeToolUse(
            name: "Write", input: ["file_path": "x.txt", "content": "secret body\nmore"])), "Write: x.txt")
        XCTAssertEqual(SessionTranscript.toolLine("[TodoWrite]"), "TodoWrite")
    }

    func testRedactionHappensBeforeTruncation() throws {
        // A key straddling the 2000-character cut: clipping first would leave
        // "sk-abcdefg…", too short for the pattern, on the phone.
        let secret = "sk-" + String(repeating: "A1b2C3d4", count: 6)
        let text = String(repeating: "x", count: 1985) + " " + secret + " tail"
        // Clipped first, the key would leave "sk-A1b2C3d4A1" — too short to match.
        XCTAssertEqual(ContextRedactor.redact(String(text.prefix(2000))), String(text.prefix(2000)))
        let path = write([assistant("a1", [["type": "text", "text": text]])])
        let entry = try XCTUnwrap(SessionTranscript.read(path: path, format: .claude)?.entries.first)
        XCTAssertLessThanOrEqual(entry.text.count, 2000)
        XCTAssertFalse(entry.text.contains("sk-"), "no fragment of the key survives")
        XCTAssertFalse(entry.text.contains("A1b2C3d4"))
        XCTAssertTrue(entry.text.contains("[redacted]"))

        let tool = SessionTranscript.toolLine(InterventionDetector.describeToolUse(
            name: "Bash", input: ["command": "curl -H 'Authorization: Bearer abcdefghijklmnop1234' https://x"]))
        XCTAssertFalse(tool.contains("abcdefghijklmnop1234"))
    }

    func testCapsAtFortyEntriesAndMarksTruncated() throws {
        let path = write((0..<60).map { user("u\($0)", "message \($0)") })
        let snap = try XCTUnwrap(SessionTranscript.read(path: path, format: .claude))
        XCTAssertEqual(snap.entries.count, 40)
        XCTAssertEqual(snap.entries.first?.text, "message 20")
        XCTAssertEqual(snap.entries.last?.text, "message 59")
        XCTAssertTrue(snap.truncated)
    }

    func testEntryTextCappedAndPlaintextFitsIn48KiB() throws {
        let path = write((0..<40).map { assistant("a\($0)", [["type": "text", "text": String(repeating: "word ", count: 1000)]]) })
        let snap = try XCTUnwrap(SessionTranscript.read(path: path, format: .claude))
        XCTAssertTrue(snap.entries.allSatisfy { $0.text.count <= 2000 })
        let data = try XCTUnwrap(SessionTranscript.plaintext(header: ["kind": "transcript", "sessionId": "s"], snapshot: snap))
        XCTAssertLessThanOrEqual(data.count, 48 * 1024)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try XCTUnwrap(obj["entries"] as? [[String: Any]])
        XCTAssertLessThan(entries.count, 40)
        XCTAssertGreaterThan(entries.count, 15)
        XCTAssertEqual(obj["truncated"] as? Bool, true)
        XCTAssertEqual(entries.last?["id"] as? String, "a39#0", "the newest rows are the ones kept")
    }

    func testIdsAreStableAsTheFileGrows() throws {
        let path = write((0..<10).map { user("u\($0)", "m\($0)") })
        let before = try XCTUnwrap(SessionTranscript.read(path: path, format: .claude))
        append((10..<15).map { user("u\($0)", "m\($0)") }, to: path)
        let after = try XCTUnwrap(SessionTranscript.read(path: path, format: .claude))
        XCTAssertEqual(Array(after.entries.prefix(10)), before.entries)
    }

    func testRecordsWithoutUuidUseTheirAbsoluteOffset() throws {
        // Small windows so the read starts mid-file and drops a partial line.
        let lines = (0..<30).map { line(["type": "user", "timestamp": "2026-10-24T12:00:00Z",
                                         "message": ["role": "user", "content": "row \($0) " + String(repeating: "p", count: 40)]]) }
        let path = write(lines)
        let narrow = try XCTUnwrap(SessionTranscript.read(path: path, format: .claude, tailBytes: 600, extendTo: nil))
        let wide = try XCTUnwrap(SessionTranscript.read(path: path, format: .claude, tailBytes: 1 << 20, extendTo: nil))
        XCTAssertTrue(narrow.truncated)
        XCTAssertFalse(narrow.entries.isEmpty)
        // The same line has the same id however much of the file was read.
        for e in narrow.entries {
            XCTAssertEqual(wide.entries.first { $0.id == e.id }?.text, e.text)
        }
        XCTAssertTrue(narrow.entries.allSatisfy { $0.id.hasPrefix("o") })
    }

    func testPreview() {
        let rows = [
            SessionTranscriptEntry(id: "1", role: .assistant, text: "Plan:\nfirst\nNow running tests", at: nil),
            SessionTranscriptEntry(id: "2", role: .tool, text: "Bash: npm test", at: nil, tool: "Bash"),
        ]
        XCTAssertEqual(SessionTranscript.preview(rows, active: true), "Bash: npm test")
        XCTAssertEqual(SessionTranscript.preview(rows, active: false), "Now running tests")
        XCTAssertNil(SessionTranscript.preview([], active: false))
        let long = [SessionTranscriptEntry(id: "1", role: .assistant, text: String(repeating: "y", count: 400), at: nil)]
        XCTAssertEqual(SessionTranscript.preview(long, active: false)?.count, 160)
    }

    // MARK: Codex

    func testCodexRolloutRows() throws {
        func item(_ payload: [String: Any], type: String = "response_item") -> String {
            line(["timestamp": "2026-10-24T12:00:00.000Z", "type": type, "payload": payload])
        }
        let path = write([
            item(["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]]),
            item(["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix the build"]]]),
            item(["type": "reasoning", "summary": []]),
            item(["type": "function_call", "name": "shell", "call_id": "c1",
                  "arguments": #"{"command":["bash","-lc","npm test"],"workdir":"/x"}"#]),
            item(["type": "function_call_output", "call_id": "c1", "output": "TOP SECRET OUTPUT"]),
            item(["type": "custom_tool_call", "name": "apply_patch", "input": "*** Begin Patch\n*** Update File: Sources/App.swift\n@@\n-a\n+b\n*** End Patch"]),
            item(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "Fixed it."]]]),
            item(["type": "user_message", "message": "Fix the build"], type: "event_msg"),
            item(["type": "turn_aborted"], type: "event_msg"),
        ])
        let snap = try XCTUnwrap(SessionTranscript.read(path: path, format: .codex))
        XCTAssertEqual(snap.entries.map(\.role), [.user, .tool, .tool, .assistant, .system])
        XCTAssertEqual(snap.entries.map(\.text), ["Fix the build", "Shell: npm test", "Edit: Sources/App.swift", "Fixed it.", "Interrupted"])
        XCTAssertEqual(snap.entries[1].tool, "shell")
        XCTAssertFalse(snap.entries.contains { $0.text.contains("TOP SECRET") })
        XCTAssertTrue(snap.entries.allSatisfy { $0.id.hasPrefix("o") })
    }

    // MARK: safety

    func testNeverReadsPrivacyProtectedOrDevicePaths() {
        // Refused on the literal path, before any filesystem call.
        XCTAssertNil(BoundedFileRead.tail(NSHomeDirectory() + "/Documents/proj/t.jsonl", maxBytes: 1024))
        XCTAssertNil(BoundedFileRead.tail("/dev/zero", maxBytes: 1024))
        XCTAssertNil(SessionTranscript.read(path: NSHomeDirectory() + "/Desktop/t.jsonl", format: .claude))
        XCTAssertNil(SessionRemote.fileStamp(NSHomeDirectory() + "/Downloads/t.jsonl"))
    }

    func testTailReadIsBoundedAndRefusesAFifo() throws {
        let path = write([String(repeating: "z", count: 5000)])
        let t = try XCTUnwrap(BoundedFileRead.tail(path, maxBytes: 1000))
        XCTAssertEqual(t.data.count, 1000)
        XCTAssertTrue(t.truncated)
        XCTAssertEqual(t.offset, 5001 - 1000)
        let fifo = dir.appendingPathComponent("fifo").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertNil(BoundedFileRead.tail(fifo, maxBytes: 1000), "a FIFO must not hang the caller")
    }
}
