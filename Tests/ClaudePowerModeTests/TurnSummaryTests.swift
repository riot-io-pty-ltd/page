import XCTest
@testable import ClaudePowerMode

final class TurnSummaryTests: XCTestCase {
    func testHeadline() {
        XCTAssertNil(TurnSummary.headline(fileCount: 0, added: nil, removed: nil, test: nil))
        XCTAssertEqual(TurnSummary.headline(fileCount: 1, added: nil, removed: nil, test: nil), "Changed 1 file")
        XCTAssertEqual(TurnSummary.headline(fileCount: 3, added: 120, removed: 14, test: (true, "x")),
                       "Changed 3 files (+120 −14) · tests passed")
        XCTAssertEqual(TurnSummary.headline(fileCount: 0, added: nil, removed: nil, test: (false, "x")), "tests failed")
    }

    func testContextKeepsTheHeadlineAndTheEndOfTheReply() {
        let reply = String(repeating: "a", count: 2000) + " What next?"
        let c = TurnSummary.context(headline: "Changed 1 file", reply: reply, limit: 200)
        XCTAssertTrue(c.hasPrefix("Changed 1 file\n\n…"))
        XCTAssertTrue(c.hasSuffix("What next?"))
        XCTAssertLessThanOrEqual(c.count, 200)
        XCTAssertEqual(TurnSummary.context(headline: nil, reply: "hi"), "hi")
    }

    func testParseNumstat() {
        let m = TurnSummary.parseNumstat("12\t3\tSources/a.swift\u{0}-\t-\timg.png\u{0}0\t5\tb c.txt\u{0}")
        XCTAssertEqual(m["Sources/a.swift"]?.0, 12)
        XCTAssertEqual(m["Sources/a.swift"]?.1, 3)
        XCTAssertNil(m["img.png"]?.0 ?? nil)
        XCTAssertEqual(m["b c.txt"]?.1, 5)
    }

    func testRelative() {
        XCTAssertEqual(TurnSummary.relative("/r/x/y.swift", to: "/r"), "x/y.swift")
        XCTAssertNil(TurnSummary.relative("/other/y.swift", to: "/r"))
        XCTAssertNil(TurnSummary.relative("/rr/y.swift", to: "/r"))
    }

    func testCappedCutsAtALine() {
        let (s, t) = TurnSummary.capped("aaaa\nbbbb\ncccc\n", maxBytes: 12)
        XCTAssertEqual(s, "aaaa\nbbbb\n")
        XCTAssertTrue(t)
        XCTAssertFalse(TurnSummary.capped("x", maxBytes: 12).1)
    }

    // MARK: git

    private func sh(_ args: [String], in dir: URL) {
        let r = ProcessRunner.run(TurnSummary.git, ["-C", dir.path] + args, timeout: 10)
        XCTAssertTrue(r.succeeded, "git \(args): \(r.stderr)")
    }

    private func makeRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turnsum-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sh(["init", "-q"], in: dir)
        sh(["config", "user.email", "t@example.com"], in: dir)
        sh(["config", "user.name", "T"], in: dir)
        try "one\ntwo\nthree\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        sh(["add", "."], in: dir)
        sh(["commit", "-q", "-m", "init"], in: dir)
        return dir.resolvingSymlinksInPath()
    }

    func testChangesFromGit() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one\n2\nthree\nfour\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\nfile\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let changes = TurnSummary.changes(cwd: dir.path, files: [dir.appendingPathComponent("a.txt").path,
                                                                 dir.appendingPathComponent("b.txt").path,
                                                                 "/elsewhere/c.txt"])
        XCTAssertEqual(changes.files, [
            .init(path: "a.txt", added: 2, removed: 1, status: "modified"),
            .init(path: "b.txt", added: 2, removed: 0, status: "added"),
            .init(path: "c.txt", added: nil, removed: nil, status: "changed"),
        ])
        XCTAssertEqual(changes.added, 4)
        XCTAssertEqual(changes.removed, 1)

        let patch = TurnSummary.patch(changes)
        XCTAssertTrue(patch.text.contains("-two\n+2\n"), patch.text)
        XCTAssertTrue(patch.text.contains("+++ b/b.txt\n@@ -0,0 +1,2 @@\n+new\n+file\n"), patch.text)
        XCTAssertFalse(patch.truncated)

        let all = TurnSummary.uncommitted(cwd: dir.path)
        XCTAssertEqual(all?.files.map(\.path), ["a.txt", "b.txt"])
    }

    func testPatchIsRedacted() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one\nKEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789ABCD\n".write(
            to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let p = TurnSummary.patch(TurnSummary.changes(cwd: dir.path, files: [dir.appendingPathComponent("a.txt").path]))
        XCTAssertFalse(p.text.contains("abcdefghijklmnop"), p.text)
    }

    func testNotARepo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("norepo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = TurnSummary.changes(cwd: dir.path, files: [dir.appendingPathComponent("x.swift").path])
        XCTAssertNil(c.root)
        XCTAssertEqual(c.files.map(\.path), ["x.swift"])
        XCTAssertNil(TurnSummary.uncommitted(cwd: dir.path))
        let fields = TurnSummary.diffFields(transcript: nil, cwd: dir.path)
        XCTAssertEqual(fields["scope"] as? String, "uncommitted")
        XCTAssertNotNil(fields["note"])
    }

    func testDiffFieldsFitTheBudget() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        let big = (0..<20000).map { "line \($0) " + String(repeating: "x", count: 40) }.joined(separator: "\n")
        try big.write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let fields = TurnSummary.diffFields(transcript: nil, cwd: dir.path)
        let data = try JSONSerialization.data(withJSONObject: fields)
        XCTAssertLessThanOrEqual(data.count, TurnSummary.maxPlaintextBytes - 1024)
        XCTAssertEqual(fields["truncated"] as? Bool, true)
        XCTAssertEqual(fields["repo"] as? String, dir.lastPathComponent)
    }

    func testHeadlineFromATranscript() throws {
        let dir = try makeRepo()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "one\ntwo\nthree\nfour\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let path = dir.appendingPathComponent("a.txt").path
        let lines = [
            #"{"type":"user","message":{"content":"go"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"e","name":"Edit","input":{"file_path":"\#(path)","old_string":"x","new_string":"y"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"e","is_error":false}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false}]}}"#,
        ]
        let t = dir.appendingPathComponent("t.jsonl")
        try lines.joined(separator: "\n").write(to: t, atomically: true, encoding: .utf8)
        XCTAssertEqual(TurnSummary.headline(transcript: t, cwd: dir.path), "Changed 1 file (+1 −0) · tests passed")
    }
}
