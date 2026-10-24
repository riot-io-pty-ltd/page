import XCTest
@testable import ClaudePowerMode

/// Idle pages are only raised for sessions that own their terminal
/// (ProcessRunner.isForeground, injected here): a stopped (^Z) or
/// backgrounded session can't take a typed reply.
final class DetectorForegroundTests: XCTestCase {
    typealias F = TranscriptFixture

    let sid = "455cd6af-046c-4468-9d9b-5de46c4d8194"
    var url: URL!

    /// What the injected isForeground returns, and which pids it was asked about.
    final class Probe {
        var answer: Bool? = true
        var asked: [Int32] = []
    }

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("fg-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
    }

    private func detector(_ probe: Probe) -> InterventionDetector {
        let holds = FileManager.default.temporaryDirectory.appendingPathComponent("fg-holds-\(UUID().uuidString)")
        return InterventionDetector(hookHoldsDirectory: holds, isForeground: { pid in
            probe.asked.append(pid)
            return probe.answer
        })
    }

    private func session(_ status: ClaudeSessionStatus, since: Date, pid: Int32 = 4242) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: pid, sessionId: sid, cwd: "/tmp", status: status,
                          statusUpdatedAt: since, tty: "ttys009", hasSessionFile: status != .unknown)
    }

    private func finishedTurn() throws {
        try write([F.user("add a test"), F.assistantText("Done. Want me to run the suite?"), F.turnDuration()])
    }

    func testStoppedOrBackgroundedSessionGetsNoIdlePage() throws {
        try finishedTurn()
        let probe = Probe()
        probe.answer = false
        let det = detector(probe)
        let r = det.scan(sessions: [session(.idle, since: Date().addingTimeInterval(-120))],
                         transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertTrue(r.opened.isEmpty)
        XCTAssertTrue(det.currentlyPending.isEmpty)
        XCTAssertEqual(probe.asked, [4242])
    }

    func testForegroundOrUnknownStillPages() throws {
        try finishedTurn()
        for answer in [true, nil] as [Bool?] {
            let probe = Probe()
            probe.answer = answer
            let det = detector(probe)
            let r = det.scan(sessions: [session(.idle, since: Date().addingTimeInterval(-120))],
                             transcriptFor: { _ in self.url }, settings: DetectorSettings())
            XCTAssertEqual(r.opened.map(\.kind), [.idle], "isForeground = \(String(describing: answer))")
        }
    }

    func testAnOpenIdlePageStaysWhenTheSessionIsStopped() throws {
        try finishedTurn()
        let probe = Probe()
        let det = detector(probe)
        let since = Date().addingTimeInterval(-120)
        let s = DetectorSettings()

        let r1 = det.scan(sessions: [session(.idle, since: since)], transcriptFor: { _ in self.url }, settings: s)
        let page = try XCTUnwrap(r1.opened.first)
        probe.asked = []

        // ^Z: kept (resolving would tombstone the id on the relay, and the
        // same state re-proposed after `fg` would be dropped there).
        probe.answer = false
        let r2 = det.scan(sessions: [session(.idle, since: since)], transcriptFor: { _ in self.url }, settings: s)
        XCTAssertTrue(r2.opened.isEmpty && r2.resolved.isEmpty)
        XCTAssertEqual(det.currentlyPending.keys.sorted(), [page.id])
        XCTAssertEqual(probe.asked, [], "only probed when a new idle page would open")
    }

    func testIdlePageOpensOnceTheStoppedSessionIsBackInTheForeground() throws {
        try finishedTurn()
        let probe = Probe()
        probe.answer = false                 // stopped before the idle delay passed
        let det = detector(probe)
        let since = Date().addingTimeInterval(-120)
        let s = DetectorSettings()

        for _ in 0..<2 {
            let r = det.scan(sessions: [session(.idle, since: since)], transcriptFor: { _ in self.url }, settings: s)
            XCTAssertTrue(r.opened.isEmpty)
        }
        probe.answer = true                  // fg
        let r = det.scan(sessions: [session(.idle, since: since)], transcriptFor: { _ in self.url }, settings: s)
        XCTAssertEqual(r.opened.map(\.kind), [.idle])
        XCTAssertEqual(r.opened.first?.id,
                       InterventionDetector.interventionId(sessionId: sid, kind: .idle, stateStart: since))
    }

    func testApprovalPagesAreNotGatedAndDontProbe() throws {
        try write([F.user("deploy"), F.toolUse("toolu_1", "Bash", ["command": "make deploy"])])
        let probe = Probe()
        probe.answer = false
        let det = detector(probe)
        let r = det.scan(sessions: [session(.waiting, since: Date().addingTimeInterval(-3))],
                         transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertEqual(r.opened.map(\.kind), [.permission])
        XCTAssertEqual(probe.asked, [], "only an idle proposal asks (one sysctl per idle session per scan)")
    }

    func testStatuslessIdleIsGatedToo() throws {
        let old = Date().addingTimeInterval(-300)
        let ts = ISO8601DateFormatter().string(from: old)
        try write([F.user("add a test", ts: ts), F.assistantText("Done. Want me to run the suite?", ts: ts)])
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let probe = Probe()
        probe.answer = false
        let det = detector(probe)
        let r = det.scan(sessions: [session(.unknown, since: old)], transcriptFor: { _ in self.url },
                         settings: DetectorSettings(), now: Date())
        XCTAssertTrue(r.opened.isEmpty)
        XCTAssertEqual(probe.asked, [4242])

        probe.answer = nil
        let r2 = det.scan(sessions: [session(.unknown, since: old)], transcriptFor: { _ in self.url },
                          settings: DetectorSettings(), now: Date())
        XCTAssertEqual(r2.opened.map(\.kind), [.idle])
    }

    func testBusySessionsNeverProbe() throws {
        try finishedTurn()
        let probe = Probe()
        let det = detector(probe)
        _ = det.scan(sessions: [session(.busy, since: Date())], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        XCTAssertEqual(probe.asked, [])
    }
}
