import XCTest
@testable import ClaudePowerMode

/// The detector stands down while one of Page's blocking hooks holds the
/// session's request (the hook already paged it), and resumes after.
final class HookHoldDetectorTests: XCTestCase {
    typealias F = TranscriptFixture

    let sid = "455cd6af-046c-4468-9d9b-5de46c4d8194"
    var dir: URL!
    var transcript: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("holds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        transcript = dir.appendingPathComponent("t.jsonl")
        let lines = [F.user("go"), F.toolUse("toolu_1", "Bash", ["command": "make deploy"])]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private var holds: URL { dir.appendingPathComponent("hook-holds", isDirectory: true) }

    private func writeMarker(sessionId: String, pid: Int32, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(at: holds, withIntermediateDirectories: true)
        let url = holds.appendingPathComponent("\(sessionId).\(pid)")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    private func session(_ status: ClaudeSessionStatus, since: Date) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 42, sessionId: sid, cwd: "/tmp", status: status,
                          statusUpdatedAt: since, tty: "ttys001", hasSessionFile: true)
    }

    func testMarkerNameParsing() {
        let p = HookHoldMarkers.parseMarkerName("\(sid).123")
        XCTAssertEqual(p?.sessionId, sid)
        XCTAssertEqual(p?.pid, 123)
        XCTAssertNil(HookHoldMarkers.parseMarkerName("\(sid).123.tmp"))
        XCTAssertNil(HookHoldMarkers.parseMarkerName("\(sid)"))
        XCTAssertNil(HookHoldMarkers.parseMarkerName(".123"))
        XCTAssertNil(HookHoldMarkers.parseMarkerName("\(sid).0"))
        XCTAssertNil(HookHoldMarkers.parseMarkerName("\(sid).-5"))
    }

    func testHeldSessionsNeedFreshMarkerAndLivePid() throws {
        let me = getpid()
        try writeMarker(sessionId: sid, pid: me)
        try writeMarker(sessionId: "stale-session", pid: me, age: 60)
        try writeMarker(sessionId: "dead-session", pid: 999_999)
        let held = HookHoldMarkers.heldSessions(in: holds, isAlive: { $0 == me })
        XCTAssertEqual(held, [sid])
        XCTAssertTrue(HookHoldMarkers.heldSessions(in: dir.appendingPathComponent("missing")).isEmpty)
    }

    func testHeldSessionDoesNotOpenThenOpensAfterRelease() throws {
        let det = InterventionDetector(hookHoldsDirectory: holds)
        let start = Date().addingTimeInterval(-10)
        try writeMarker(sessionId: sid, pid: getpid())

        let r1 = det.scan(sessions: [session(.waiting, since: start)], transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertTrue(r1.opened.isEmpty, "a hook already paged this prompt")
        XCTAssertTrue(det.currentlyPending.isEmpty)

        // Hook timed out and handed back to the dialog: page as normal.
        try FileManager.default.removeItem(at: holds)
        let r2 = det.scan(sessions: [session(.waiting, since: start)], transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertEqual(r2.opened.count, 1)
        XCTAssertEqual(r2.opened.first?.promptKey, "toolu_1")
    }

    func testStaleMarkerDoesNotSuppress() throws {
        let det = InterventionDetector(hookHoldsDirectory: holds)
        try writeMarker(sessionId: sid, pid: getpid(), age: HookHoldMarkers.freshness + 5)
        let r = det.scan(sessions: [session(.waiting, since: Date().addingTimeInterval(-10))],
                         transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertEqual(r.opened.count, 1)
    }

    func testOtherSessionsStillPage() throws {
        let det = InterventionDetector(hookHoldsDirectory: holds)
        try writeMarker(sessionId: "11111111-2222-3333-4444-555555555555", pid: getpid())
        let r = det.scan(sessions: [session(.waiting, since: Date().addingTimeInterval(-10))],
                         transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertEqual(r.opened.count, 1)
    }

    func testAlreadyOpenPageIsKeptWhileHeld() throws {
        let det = InterventionDetector(hookHoldsDirectory: holds)
        let start = Date().addingTimeInterval(-10)
        let r1 = det.scan(sessions: [session(.waiting, since: start)], transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertEqual(r1.opened.count, 1)
        // A hook starts holding afterwards: the open page neither flaps nor resolves.
        try writeMarker(sessionId: sid, pid: getpid())
        let r2 = det.scan(sessions: [session(.waiting, since: start)], transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertTrue(r2.opened.isEmpty)
        XCTAssertTrue(r2.resolved.isEmpty)
        XCTAssertEqual(det.currentlyPending.count, 1)
        // And busy still resolves it.
        let r3 = det.scan(sessions: [session(.busy, since: Date())], transcriptFor: { _ in self.transcript }, settings: DetectorSettings())
        XCTAssertEqual(r3.resolved.count, 1)
    }
}
