import XCTest
@testable import ClaudePowerMode

final class ClaudeSessionRegistryTests: XCTestCase {
    typealias Reg = ClaudeSessionRegistry
    typealias Row = ProcessRunner.ProcessInfoRow

    let sid = "455cd6af-046c-4468-9d9b-5de46c4d8194"
    let sid2 = "b84356ec-c2dc-40b5-89f0-6948ea5c3815"

    // MARK: parsing

    func testParsesFullRecord() {
        let json = """
        {"pid":11686,"sessionId":"\(sid)","cwd":"/Users/me/proj","startedAt":1,"version":"2.1.310",
         "kind":"interactive","entrypoint":"cli","status":"waiting","updatedAt":2,"statusUpdatedAt":1792828664604,
         "peerFeatures":["a"],"unknownFutureField":{"x":1}}
        """
        let r = Reg.parseSessionFile(Data(json.utf8))
        XCTAssertEqual(r?.pid, 11686)
        XCTAssertEqual(r?.sessionId, sid)
        XCTAssertEqual(r?.cwd, "/Users/me/proj")
        XCTAssertEqual(r?.status, "waiting")
        XCTAssertEqual(r?.kind, "interactive")
        XCTAssertEqual(r?.entrypoint, "cli")
        XCTAssertEqual(r?.statusUpdatedAt?.timeIntervalSince1970 ?? 0, 1792828664.604, accuracy: 0.001)
    }

    func testParsesDefensively() {
        // Missing / wrongly typed fields are dropped, not fatal.
        let r = Reg.parseSessionFile(Data(#"{"pid":"12","sessionId":42,"status":true,"statusUpdatedAt":"soon","cwd":""}"#.utf8))
        XCTAssertNotNil(r)
        XCTAssertNil(r?.pid)
        XCTAssertNil(r?.sessionId)
        XCTAssertNil(r?.status)
        XCTAssertNil(r?.statusUpdatedAt)
        XCTAssertNil(r?.cwd)
        XCTAssertNil(Reg.parseSessionFile(Data("not json".utf8)))
        XCTAssertNil(Reg.parseSessionFile(Data("[1,2]".utf8)))
        XCTAssertNil(Reg.parseSessionFile(Data()))
        XCTAssertNotNil(Reg.parseSessionFile(Data("{}".utf8)))
    }

    func testStatusMapping() {
        XCTAssertEqual(ClaudeSessionStatus(raw: "busy"), .busy)
        XCTAssertEqual(ClaudeSessionStatus(raw: "WAITING"), .waiting)
        XCTAssertEqual(ClaudeSessionStatus(raw: "idle"), .idle)
        XCTAssertEqual(ClaudeSessionStatus(raw: "compacting"), .unknown)
        XCTAssertEqual(ClaudeSessionStatus(raw: nil), .unknown)
    }

    // MARK: liveness

    private func record(_ pid: Int32, _ sid: String, status: String = "idle", kind: String? = "interactive") -> ClaudeSessionRecord {
        ClaudeSessionRecord(pid: pid, sessionId: sid, cwd: "/p", status: status,
                            statusUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000), kind: kind, entrypoint: "cli")
    }

    func testLiveRequiresPidInTableWithClaudeCommand() {
        let table = [
            Row(pid: 100, ppid: 1, tty: "ttys001", command: "/Users/me/.local/bin/claude --session-id \(sid)"),
            Row(pid: 200, ppid: 1, tty: "ttys002", command: "/usr/bin/vim notes.txt"),   // pid reused after a crash
        ]
        let live = Reg.buildLiveSessions(
            records: [record(100, sid, status: "waiting"), record(200, sid2), record(300, sid2)],
            processTable: table, ownPid: 1, isAlive: { _ in true })
        XCTAssertEqual(live.map(\.pid), [100])
        XCTAssertEqual(live.first?.status, .waiting)
        XCTAssertEqual(live.first?.tty, "ttys001")
        XCTAssertEqual(live.first?.devTTY, "/dev/ttys001")
        XCTAssertEqual(live.first?.hasSessionFile, true)
    }

    func testFallsBackToKillCheckWhenPsFailed() {
        let live = Reg.buildLiveSessions(records: [record(100, sid), record(200, sid2)], processTable: [],
                                         ownPid: 1, isAlive: { $0 == 200 })
        XCTAssertEqual(live.map(\.pid), [200])
        XCTAssertNil(live.first?.tty)
    }

    func testSkipsNonInteractiveKindsAndInvalidIds() {
        let table = [Row(pid: 100, ppid: 1, tty: "ttys001", command: "claude"),
                     Row(pid: 101, ppid: 1, tty: "ttys002", command: "claude")]
        let live = Reg.buildLiveSessions(
            records: [record(100, sid, kind: "sdk"), record(101, "not-a-uuid")],
            processTable: table, ownPid: 1, isAlive: { _ in true })
        XCTAssertTrue(live.isEmpty)
    }

    func testMissingKindIsAccepted() {
        let table = [Row(pid: 100, ppid: 1, tty: "ttys001", command: "claude")]
        let live = Reg.buildLiveSessions(records: [record(100, sid, kind: nil)], processTable: table,
                                         ownPid: 1, isAlive: { _ in true })
        XCTAssertEqual(live.count, 1)
    }

    func testDuplicateSessionIdAcrossPidsKeptSeparately() {
        let table = [Row(pid: 10294, ppid: 1, tty: "??", command: "claude --session-id \(sid)"),
                     Row(pid: 77372, ppid: 1, tty: "ttys009", command: "claude --resume \(sid)")]
        let live = Reg.buildLiveSessions(records: [record(10294, sid, status: "idle"), record(77372, sid, status: "busy")],
                                         processTable: table, ownPid: 1, isAlive: { _ in true })
        XCTAssertEqual(live.map(\.pid), [10294, 77372])
        XCTAssertNil(live[0].tty)
        XCTAssertEqual(live[1].status, .busy)
    }

    func testArgvFallbackForOldClaudeCode() {
        let table = [
            Row(pid: 100, ppid: 1, tty: "ttys001", command: "/opt/homebrew/bin/claude --resume \(sid)"),
            // headless print run: no tty → not an interactive session
            Row(pid: 101, ppid: 1, tty: "??", command: "claude --resume \(sid2) --print hi"),
            // not the claude executable, only mentions it
            Row(pid: 102, ppid: 1, tty: "ttys003", command: "tail -F /tmp/claude-\(sid2)-cwd"),
            // our own app
            Row(pid: 7, ppid: 1, tty: "ttys004", command: "claude --resume \(sid2)"),
        ]
        let live = Reg.buildLiveSessions(records: [], processTable: table, ownPid: 7, isAlive: { _ in true })
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live[0].pid, 100)
        XCTAssertEqual(live[0].sessionId, sid)
        XCTAssertEqual(live[0].status, .unknown)
        XCTAssertFalse(live[0].hasSessionFile)
    }

    func testRecordWinsOverArgvForSamePid() {
        let table = [Row(pid: 100, ppid: 1, tty: "ttys001", command: "claude --resume \(sid)")]
        let live = Reg.buildLiveSessions(records: [record(100, sid2, status: "busy")], processTable: table,
                                         ownPid: 1, isAlive: { _ in true })
        // After /clear the file has the new id; argv still carries the old one.
        XCTAssertEqual(live.map(\.sessionId), [sid2])
    }

    // MARK: helpers

    func testSessionIdInArgv() {
        XCTAssertEqual(Reg.sessionIdInArgv("claude --resume \(sid)"), sid)
        XCTAssertEqual(Reg.sessionIdInArgv("claude -r \(sid) --model opus"), sid)
        XCTAssertEqual(Reg.sessionIdInArgv("claude --session-id=\(sid)"), sid)
        XCTAssertNil(Reg.sessionIdInArgv("claude --settings {\"id\":\"\(sid)\"}"))
        XCTAssertNil(Reg.sessionIdInArgv("claude"))
        XCTAssertNil(Reg.sessionIdInArgv("claude --resume"))
    }

    func testCommandChecks() {
        XCTAssertTrue(Reg.isClaudeExecutable("/Users/me/.local/bin/claude --resume x"))
        XCTAssertTrue(Reg.isClaudeExecutable("claude"))
        XCTAssertFalse(Reg.isClaudeExecutable("node /x/claude-code/cli.js"))
        XCTAssertFalse(Reg.isClaudeExecutable("/bin/zsh ~/.claude/hooks/page-notify.sh"))
        XCTAssertTrue(Reg.isClaudeCommand("node /x/claude-code/cli.js"))
        XCTAssertTrue(Reg.isClaudeCommand("Claude"))
        XCTAssertFalse(Reg.isClaudeCommand("/Applications/ClaudePowerMode.app/Contents/MacOS/ClaudePowerMode"))
        XCTAssertFalse(Reg.isClaudeCommand("vim"))
    }

    func testValidSessionId() {
        XCTAssertTrue(Reg.isValidSessionId(sid))
        XCTAssertFalse(Reg.isValidSessionId("--help"))
        XCTAssertFalse(Reg.isValidSessionId("../../etc/passwd"))
        XCTAssertFalse(Reg.isValidSessionId(sid + "x"))
        XCTAssertFalse(Reg.isValidSessionId(""))
    }

    func testNormalizedTTY() {
        XCTAssertEqual(Reg.normalizedTTY("ttys003"), "ttys003")
        XCTAssertEqual(Reg.normalizedTTY("/dev/ttys003"), "ttys003")
        XCTAssertNil(Reg.normalizedTTY("??"))
        XCTAssertNil(Reg.normalizedTTY("-"))
    }

    func testEncodedProjectDirName() {
        XCTAssertEqual(Reg.encodedProjectDirName(forCwd: "/Users/alex/projects/page-app"),
                       "-Users-alex-projects-page-app")
        XCTAssertEqual(Reg.encodedProjectDirName(forCwd: "/Users/me/my.app_v2"), "-Users-me-my-app-v2")
    }

    // MARK: IO against a temp directory

    func testRefreshAndTranscriptLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pagetest-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions")
        let projects = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let me = ProcessInfo.processInfo.processIdentifier
        // A record for a pid that's certainly alive and isn't us: launchd (pid 1)
        // doesn't mention claude, so it must be rejected.
        try Data(#"{"pid":1,"sessionId":"\#(sid)","status":"idle"}"#.utf8).write(to: sessions.appendingPathComponent("1.json"))
        try Data("garbage".utf8).write(to: sessions.appendingPathComponent("2.json"))
        try Data("{}".utf8).write(to: sessions.appendingPathComponent("3.key"))

        let reg = ClaudeSessionRegistry(projectsDirectory: projects.path, sessionsDirectory: sessions.path)
        let table = [Row(pid: 1, ppid: 0, tty: "??", command: "/sbin/launchd"),
                     Row(pid: me, ppid: 1, tty: "??", command: "xctest")]
        XCTAssertTrue(reg.refresh(processTable: table).isEmpty)
        XCTAssertEqual(reg.currentRecord(forPid: 1)?.sessionId, sid)
        XCTAssertNil(reg.currentRecord(forPid: 2))

        // Transcript lookup: guessed dir, then sweep, then cached.
        let cwd = "/Users/me/my.proj"
        let guessed = projects.appendingPathComponent(Reg.encodedProjectDirName(forCwd: cwd))
        try FileManager.default.createDirectory(at: guessed, withIntermediateDirectories: true)
        let t1 = guessed.appendingPathComponent("\(sid).jsonl")
        try Data("{}\n".utf8).write(to: t1)
        XCTAssertEqual(reg.transcriptURL(forSessionId: sid, cwdHint: cwd)?.path, t1.path)

        let other = projects.appendingPathComponent("-somewhere-else")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let t2 = other.appendingPathComponent("\(sid2).jsonl")
        try Data("{}\n".utf8).write(to: t2)
        XCTAssertEqual(reg.transcriptURL(forSessionId: sid2, cwdHint: cwd)?.path, t2.path)
        XCTAssertNil(reg.transcriptURL(forSessionId: "../../x", cwdHint: nil))
    }
}
