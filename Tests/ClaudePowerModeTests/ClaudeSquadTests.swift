import XCTest
@testable import ClaudePowerMode

/// Claude Squad support: the pure parsers and decisions in ClaudeSquad.swift,
/// its file readers against a temp folder, and the host, input gate, detector
/// and backend changes that use it, with fakes. Nothing here types into a
/// real terminal or reads the real ~/.claude-squad.
final class ClaudeSquadTests: XCTestCase {
    typealias CS = ClaudeSquad
    private let sid = "455cd6af-046c-4468-9d9b-5de46c4d8194"

    /// `ClaudeSquad.directory` points here for the file tests.
    private var root = ""
    private var savedDirectory = ""
    private var holdsDir: URL!
    private var transcript: URL!

    override func setUpWithError() throws {
        savedDirectory = CS.directory
        root = FileManager.default.temporaryDirectory.appendingPathComponent("squad-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        CS.directory = root
        holdsDir = FileManager.default.temporaryDirectory.appendingPathComponent("squad-holds-\(UUID().uuidString)")
        transcript = FileManager.default.temporaryDirectory.appendingPathComponent("squad-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        CS.directory = savedDirectory
        try? FileManager.default.removeItem(atPath: root)
        try? FileManager.default.removeItem(at: transcript)
        super.tearDown()
    }

    // MARK: helpers

    private func data(_ s: String) -> Data { Data(s.utf8) }

    private func inst(_ title: String, path: String = "", status: Int = 0, program: String = "claude",
                      autoYes: Bool = false, worktree: String = "", session: String = "") -> CS.Instance {
        CS.Instance(title: title, path: path, branch: "", status: status, program: program,
                    autoYes: autoYes, worktreePath: worktree, sessionName: session)
    }

    private func snapshot(_ instances: [CS.Instance], daemon: Bool = false, tui: Bool = false) -> CS.Snapshot {
        CS.Snapshot(instances: instances, config: nil, daemonAlive: daemon, tuiRunning: tui)
    }

    private func live(pid: Int32 = 4242, cwd: String?, tty: String? = "ttys009",
                      status: ClaudeSessionStatus = .busy) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: pid, sessionId: sid, cwd: cwd, status: status, statusUpdatedAt: nil,
                          tty: tty, hasSessionFile: true)
    }

    private func proc(_ pid: Int32, _ command: String, ppid: Int32 = 1) -> ProcessRunner.ProcessInfoRow {
        ProcessRunner.ProcessInfoRow(pid: pid, ppid: ppid, tty: "ttys001", command: command)
    }

    private func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(name))
    }

    private func writeTranscript(_ lines: [String]) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: transcript)
    }

    private func detector() -> InterventionDetector {
        InterventionDetector(hookHoldsDirectory: holdsDir, isForeground: { _ in true })
    }

    private let stateJSON = """
    {"instances":[
      {"title":"fix_bug","path":"/Users/me/proj","branch":"cs/fix_bug","status":0,"auto_yes":true,"program":"claude",
       "worktree":{"repo_path":"/Users/me/proj","worktree_path":"/wt/fix_bug_1a2b","session_name":"fix_bug","branch_name":"cs/fix_bug"}},
      {"title":"","path":"/nowhere"},
      {"path":"/no-title"},
      {"title":"paused_one","path":"/p","status":3,"program":"aider --x","worktree":{"worktree_path":"/wt/p_1","session_name":"paused_one"}}
    ],"other":1}
    """

    // MARK: parseState

    func testParseStateReadsEveryField() throws {
        let parsed = try XCTUnwrap(CS.parseState(data(stateJSON)))
        XCTAssertEqual(parsed.count, 2, "the empty and the missing titles are skipped")
        XCTAssertEqual(parsed[0], CS.Instance(title: "fix_bug", path: "/Users/me/proj", branch: "cs/fix_bug", status: 0,
                                              program: "claude", autoYes: true, worktreePath: "/wt/fix_bug_1a2b",
                                              sessionName: "fix_bug"))
        XCTAssertEqual(parsed[1].status, 3, "paused status is kept")
        XCTAssertEqual(parsed[1].program, "aider --x")
        XCTAssertFalse(parsed[1].autoYes, "missing auto_yes is false")
    }

    func testParseStateDefaultsMissingFields() throws {
        let parsed = try XCTUnwrap(CS.parseState(data(#"{"instances":[{"title":"bare"}]}"#)))
        XCTAssertEqual(parsed, [CS.Instance(title: "bare", path: "", branch: "", status: -1, program: "",
                                            autoYes: false, worktreePath: "", sessionName: "")],
                       "no worktree key: no crash, empty worktree fields")
    }

    func testParseStateRejectsWhatIsNotAStateFile() {
        XCTAssertNil(CS.parseState(nil))
        XCTAssertNil(CS.parseState(data("not json")))
        XCTAssertNil(CS.parseState(data(#"{"other":[]}"#)), "no instances array")
        XCTAssertNil(CS.parseState(data(#"{"instances":"x"}"#)), "instances is not an array")
        XCTAssertNil(CS.parseState(data("[]")), "a bare array is not a state file")
        XCTAssertEqual(CS.parseState(data(#"{"instances":[]}"#)), [], "an empty list is a valid state")
    }

    // MARK: parseConfig

    func testParseConfigReadsBothKeys() {
        XCTAssertEqual(CS.parseConfig(data(#"{"auto_yes":true,"default_program":"claude"}"#)),
                       CS.Config(autoYes: true, defaultProgram: "claude"))
    }

    func testParseConfigDefaultsMissingKeys() {
        XCTAssertEqual(CS.parseConfig(data("{}")), CS.Config(autoYes: false, defaultProgram: ""))
    }

    func testParseConfigRejectsGarbledAndArrays() {
        XCTAssertNil(CS.parseConfig(nil))
        XCTAssertNil(CS.parseConfig(data("{garbled")))
        XCTAssertNil(CS.parseConfig(data("[1,2]")), "an array is not a config object")
    }

    // MARK: parseDaemonPid

    func testParseDaemonPidOnlyAcceptsARealPid() {
        XCTAssertEqual(CS.parseDaemonPid(data("1234\n")), 1234, "trailing newline is trimmed")
        XCTAssertNil(CS.parseDaemonPid(data("")))
        XCTAssertNil(CS.parseDaemonPid(data("abc")))
        XCTAssertNil(CS.parseDaemonPid(data("0")))
        XCTAssertNil(CS.parseDaemonPid(data("1")), "pid 1 is launchd, never the daemon")
        XCTAssertNil(CS.parseDaemonPid(data("-5")))
        XCTAssertNil(CS.parseDaemonPid(nil))
    }

    // MARK: session names

    func testSquadSessionNames() {
        XCTAssertTrue(CS.isSquadSession("claudesquad_fix_bug"))
        XCTAssertFalse(CS.isSquadSession("claudesquad_term_fix_bug"), "a shell tab, not an agent")
        XCTAssertFalse(CS.isSquadSession("claudesquad_"), "empty title")
        XCTAssertFalse(CS.isSquadSession("tmux"))
        XCTAssertFalse(CS.isSquadSession("0"))
        XCTAssertFalse(CS.isSquadSession("other_claudesquad_x"))
    }

    func testTmuxNameForTitle() {
        XCTAssertEqual(CS.tmuxName(forTitle: "my task v1.2"), "claudesquad_mytaskv1_2", "spaces removed, dot becomes _")
        XCTAssertEqual(CS.tmuxName(forTitle: "a:b"), "claudesquad_a_b", "colon becomes _")
    }

    func testInstanceForSessionByTitle() {
        let a = inst("fix bug")
        let b = inst("other")
        XCTAssertEqual(CS.instance(forSession: "claudesquad_fixbug", in: [b, a]), a)
    }

    func testInstanceForSessionByStoredSessionNameBareOrPrefixed() {
        let a = inst("renamed", session: "claudesquad_wt_name")
        let b = inst("other", session: "wt_bare")
        XCTAssertEqual(CS.instance(forSession: "claudesquad_wt_name", in: [a, b]), a, "prefixed session_name")
        XCTAssertEqual(CS.instance(forSession: "claudesquad_wt_bare", in: [a, b]), b, "bare session_name gets the prefix")
    }

    func testInstanceForSessionRefusesShellsNonSquadsAndNoMatch() {
        let shell = inst("term_fix_bug")
        XCTAssertNil(CS.instance(forSession: "claudesquad_term_fix_bug", in: [shell]), "shell tabs are never an agent")
        XCTAssertNil(CS.instance(forSession: "tmux", in: [inst("tmux")]), "not a squad session")
        XCTAssertNil(CS.instance(forSession: "claudesquad_nomatch", in: [inst("fix_bug")]))
    }

    func testInstanceForSessionFirstMatchWins() {
        let first = inst("dup", path: "/first")
        let second = inst("d up", path: "/second")
        XCTAssertEqual(CS.instance(forSession: "claudesquad_dup", in: [first, second])?.path, "/first",
                       "two titles map to the same tmux name: the first one wins")
    }

    // MARK: cwd and worktrees

    func testInstanceForCwdMatchesWorktreeAndSubfolders() {
        let a = inst("a", worktree: "/wt/a_1")
        XCTAssertEqual(CS.instance(forCwd: "/wt/a_1", in: [a]), a)
        XCTAssertEqual(CS.instance(forCwd: "/wt/a_1/src/deep", in: [a]), a)
        XCTAssertEqual(CS.instance(forCwd: "/wt/a_1/", in: [a]), a, "trailing slash ignored")
        XCTAssertNil(CS.instance(forCwd: "/wt/a_10", in: [a]), "a sibling with a shared prefix is not inside")
        XCTAssertNil(CS.instance(forCwd: "", in: [a]))
        XCTAssertNil(CS.instance(forCwd: "/wt/a_1", in: [inst("empty")]), "an empty worktree path never matches")
    }

    func testIsInWorktreesIsAPathComponentMatch() {
        XCTAssertTrue(CS.isInWorktrees("/wt/x_1", root: "/wt"))
        XCTAssertTrue(CS.isInWorktrees("/wt/x_1/sub", root: "/wt"))
        XCTAssertFalse(CS.isInWorktrees("/wt", root: "/wt"), "the root itself")
        XCTAssertFalse(CS.isInWorktrees("/wt-old/x", root: "/wt"), "worktrees-old is not worktrees")
        XCTAssertFalse(CS.isInWorktrees("/Users/me/proj", root: "/wt"))
        XCTAssertFalse(CS.isInWorktrees("", root: "/wt"))
    }

    func testIsPaused() {
        let root = "/wt"
        let gone = { (_: String) -> Bool in false }
        let here = { (_: String) -> Bool in true }
        XCTAssertFalse(CS.isPaused(cwd: "/wt/x_1", instance: inst("x"), cwdExists: here, worktreesRoot: root),
                       "running instance with its folder")
        XCTAssertFalse(CS.isPaused(cwd: "/wt/x_1", instance: inst("x", status: 3), cwdExists: here, worktreesRoot: root),
                       "a stale status 3 after a resume: the worktree folder is back, so it is running")
        XCTAssertTrue(CS.isPaused(cwd: "/wt/x_1", instance: inst("x", status: 3), cwdExists: gone, worktreesRoot: root),
                      "status 3 and the folder is gone")
        XCTAssertTrue(CS.isPaused(cwd: "/elsewhere/x", instance: inst("x", status: 3), cwdExists: here, worktreesRoot: root),
                      "status 3 decides when the folder can't say (outside the worktrees)")
        XCTAssertTrue(CS.isPaused(cwd: nil, instance: inst("x", status: 3), cwdExists: here, worktreesRoot: root),
                      "status 3 decides when the working folder is unknown")
        XCTAssertTrue(CS.isPaused(cwd: "/wt/x_1", instance: nil, cwdExists: gone, worktreesRoot: root),
                      "worktree folder gone, no instance")
        XCTAssertFalse(CS.isPaused(cwd: "/wt/x_1", instance: nil, cwdExists: here, worktreesRoot: root))
        XCTAssertFalse(CS.isPaused(cwd: "/elsewhere/x", instance: nil, cwdExists: gone, worktreesRoot: root),
                       "missing folder outside the worktrees is not a pause")
        XCTAssertFalse(CS.isPaused(cwd: nil, instance: nil, cwdExists: gone, worktreesRoot: root))
        XCTAssertFalse(CS.isPaused(cwd: "", instance: nil, cwdExists: gone, worktreesRoot: root))
    }

    // MARK: auto-approval

    func testProgramAutoApproves() {
        XCTAssertTrue(CS.programAutoApproves("claude"))
        XCTAssertTrue(CS.programAutoApproves(" claude "), "surrounding spaces trimmed")
        XCTAssertTrue(CS.programAutoApproves("aider --x"))
        XCTAssertTrue(CS.programAutoApproves("gemini"))
        XCTAssertFalse(CS.programAutoApproves("claude --model x"), "Claude Squad's match is exact")
        XCTAssertFalse(CS.programAutoApproves("codex"))
        XCTAssertFalse(CS.programAutoApproves(""))
        XCTAssertFalse(CS.programAutoApproves("/usr/bin/claude"))
    }

    func testAutoApprovesNeedsTheProgramAndSomeoneToPressEnter() {
        XCTAssertTrue(CS.autoApproves(instance: inst("a"), daemonAlive: true), "daemon forces auto-yes")
        XCTAssertTrue(CS.autoApproves(instance: inst("a", autoYes: true), daemonAlive: false, tuiRunning: true),
                      "instance auto-yes with an open cs UI")
        XCTAssertFalse(CS.autoApproves(instance: inst("a", autoYes: true), daemonAlive: false, tuiRunning: false),
                       "auto-yes saved, but nothing is running to press Enter")
        XCTAssertFalse(CS.autoApproves(instance: nil, daemonAlive: true), "no instance")
        XCTAssertFalse(CS.autoApproves(instance: inst("a", status: 3), daemonAlive: true), "paused")
        XCTAssertFalse(CS.autoApproves(instance: inst("a", program: "claude --model x"), daemonAlive: true),
                       "program Claude Squad doesn't match")
    }

    // MARK: standing

    func testStandingIsNilForAnythingElse() {
        XCTAssertNil(CS.standing(sessionName: "tmux", cwd: "/elsewhere", snapshot: nil,
                                 cwdExists: { _ in true }, worktreesRoot: "/wt"))
        XCTAssertNil(CS.standing(sessionName: "claudesquad_term_x", cwd: "/elsewhere", snapshot: nil,
                                 cwdExists: { _ in true }, worktreesRoot: "/wt"),
                     "a shell tab outside the worktrees is not Claude Squad's")
    }

    func testStandingByNameAloneWithoutASnapshot() throws {
        let s = try XCTUnwrap(CS.standing(sessionName: "claudesquad_fix", cwd: nil, snapshot: nil,
                                          cwdExists: { _ in true }, worktreesRoot: "/wt"))
        XCTAssertNil(s.instance)
        XCTAssertFalse(s.paused)
        XCTAssertFalse(s.autoApproves, "unknown instance: Page pages")
    }

    func testStandingFindsTheInstanceByNameThenByCwd() throws {
        let snap = snapshot([inst("fix", program: "claude", worktree: "/wt/fix_1")], daemon: true)
        let byName = try XCTUnwrap(CS.standing(sessionName: "claudesquad_fix", cwd: "/wt/fix_1", snapshot: snap,
                                               cwdExists: { _ in true }, worktreesRoot: "/wt"))
        XCTAssertEqual(byName.instance?.title, "fix")
        XCTAssertTrue(byName.autoApproves)
        XCTAssertFalse(byName.paused)

        let byCwd = try XCTUnwrap(CS.standing(sessionName: "claudesquad_unknown", cwd: "/wt/fix_1/src", snapshot: snap,
                                              cwdExists: { _ in true }, worktreesRoot: "/wt"),
                                  "a squad name with no match still counts through the folder")
        XCTAssertEqual(byCwd.instance?.title, "fix", "found by cwd when the name matches nothing")
    }

    func testPausedInstanceNeverAutoApprovesEvenWithDaemon() throws {
        let snap = snapshot([inst("p", status: 3, worktree: "/wt/p_1")], daemon: true)
        let s = try XCTUnwrap(CS.standing(sessionName: "claudesquad_p", cwd: "/wt/p_1", snapshot: snap,
                                          cwdExists: { _ in false }, worktreesRoot: "/wt"))
        XCTAssertTrue(s.paused, "status 3 and the worktree is gone")
        XCTAssertFalse(s.autoApproves)
        // A stale status 3 with the folder back (resumed): running, but
        // still not trusted to be auto-approved until Claude Squad saves.
        let stale = try XCTUnwrap(CS.standing(sessionName: "claudesquad_p", cwd: "/wt/p_1", snapshot: snap,
                                              cwdExists: { _ in true }, worktreesRoot: "/wt"))
        XCTAssertFalse(stale.paused)
        XCTAssertFalse(stale.autoApproves)
    }

    func testStandingWithGarbledSnapshotAndExistingWorktreeIsNotPaused() throws {
        let garbled = CS.Snapshot(instances: CS.parseState(data("{garbled")) ?? [], config: nil,
                                  daemonAlive: true, tuiRunning: false)
        let s = try XCTUnwrap(CS.standing(sessionName: "claudesquad_fix", cwd: "/wt/fix_1", snapshot: garbled,
                                          cwdExists: { _ in true }, worktreesRoot: "/wt"))
        XCTAssertNil(s.instance)
        XCTAssertFalse(s.paused, "the worktree exists, so the instance isn't paused")
        XCTAssertFalse(s.autoApproves, "no instance: nothing to auto-approve")
    }

    // MARK: processes

    func testProcessKind() {
        XCTAssertEqual(CS.processKind(command: "/usr/local/bin/cs --daemon"), CS.ProcessKind.daemon)
        XCTAssertEqual(CS.processKind(command: "claude-squad --daemon"), CS.ProcessKind.daemon)
        XCTAssertEqual(CS.processKind(command: "claude-squad -y"), CS.ProcessKind.interactive)
        XCTAssertNil(CS.processKind(command: "/opt/homebrew/bin/cs"),
                     "a bare cs could be coursier: not taken for the terminal UI")
        XCTAssertNil(CS.processKind(command: "cs launch scalafmt"))
        XCTAssertNil(CS.processKind(command: "claude --daemon"), "not Claude Squad")
        XCTAssertNil(CS.processKind(command: "csh"), "a different program named like cs")
        XCTAssertNil(CS.processKind(command: ""))
    }

    func testDaemonIsRunningNeedsTheSamePidRunningTheDaemon() {
        let table = [proc(300, "/usr/local/bin/cs --daemon"), proc(301, "claude")]
        XCTAssertTrue(CS.daemonIsRunning(pid: 300, table: table))
        XCTAssertFalse(CS.daemonIsRunning(pid: 301, table: table), "pid recycled to another program")
        XCTAssertFalse(CS.daemonIsRunning(pid: 999, table: table), "pid not in the table")
        XCTAssertFalse(CS.daemonIsRunning(pid: nil, table: table))
    }

    // MARK: files (temp folder)

    func testLoadSnapshotIsNilWithoutTheFolder() {
        CS.directory = root + "/missing"
        XCTAssertNil(CS.loadSnapshot(table: []), "no Claude Squad: one stat, nothing else")
    }

    func testLoadSnapshotSurvivesGarbledOrMissingFiles() throws {
        XCTAssertEqual(CS.loadSnapshot(table: []), snapshot([]), "folder with no files")
        try write("{garbled", to: "state.json")
        try write("nope", to: "config.json")
        try write("abc", to: "daemon.pid")
        let s = try XCTUnwrap(CS.loadSnapshot(table: []))
        XCTAssertEqual(s.instances, [])
        XCTAssertNil(s.config)
        XCTAssertFalse(s.daemonAlive)
    }

    func testLoadSnapshotReadsStateConfigAndLiveDaemon() throws {
        try write(stateJSON, to: "state.json")
        try write(#"{"auto_yes":true,"default_program":"claude"}"#, to: "config.json")
        try write("\(getpid())\n", to: "daemon.pid")
        let table = [proc(getpid(), "/usr/local/bin/cs --daemon")]
        let s = try XCTUnwrap(CS.loadSnapshot(table: table))
        XCTAssertEqual(s.instances.map(\.title), ["fix_bug", "paused_one"])
        XCTAssertEqual(s.config, CS.Config(autoYes: true, defaultProgram: "claude"))
        XCTAssertTrue(s.daemonAlive, "pid in daemon.pid is a running cs --daemon")
        XCTAssertFalse(s.tuiRunning, "the daemon is not the terminal UI")
    }

    func testStaleDaemonPidIsNotAlive() throws {
        try write("\(getpid())", to: "daemon.pid")
        let s = try XCTUnwrap(CS.loadSnapshot(table: [proc(getpid(), "claude")]))
        XCTAssertFalse(s.daemonAlive, "the pid now runs something else")
    }

    func testTerminalUIIsReadFromTheProcessTable() throws {
        let ui = try XCTUnwrap(CS.loadSnapshot(table: [proc(55, "/opt/homebrew/bin/claude-squad")]))
        XCTAssertTrue(ui.tuiRunning)
        XCTAssertFalse(ui.daemonAlive)
        let coursier = try XCTUnwrap(CS.loadSnapshot(table: [proc(57, "/opt/homebrew/bin/cs setup")]))
        XCTAssertFalse(coursier.tuiRunning, "another tool named cs")
        let none = try XCTUnwrap(CS.loadSnapshot(table: [proc(56, "/usr/local/bin/cs --daemon")]))
        XCTAssertFalse(none.tuiRunning, "a daemon alone is not a terminal UI")
    }

    func testLiveStandingsSkipsSessionsOutsideWorktrees() throws {
        try write(stateJSON, to: "state.json")
        let outside = live(pid: 1, cwd: "/Users/me/proj")
        XCTAssertEqual(CS.liveStandings(sessions: [outside], table: [proc(getpid(), "/usr/local/bin/cs --daemon")]), [:])
    }

    func testLiveStandingsPausesAMissingWorktreeFolder() throws {
        let gone = root + "/worktrees/gone_1"
        let out = CS.liveStandings(sessions: [live(pid: 9, cwd: gone)], table: [])
        XCTAssertEqual(out[9]?.paused, true, "worktree folder is gone: paused")
        XCTAssertEqual(out[9]?.autoApproves, false)
    }

    func testLiveStandingsAutoApprovesAnInstanceUnderALiveDaemon() throws {
        let wt = root + "/worktrees/x_1"
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try write(#"{"instances":[{"title":"x","program":"claude","worktree":{"worktree_path":"\#(wt)"}}]}"#,
                  to: "state.json")
        try write("\(getpid())", to: "daemon.pid")
        let table = [proc(getpid(), "/usr/local/bin/cs --daemon")]
        let out = CS.liveStandings(sessions: [live(pid: 77, cwd: wt)], table: table,
                                   paneListing: { "%1\t/dev/ttys009\t0\tclaudesquad_x\n" })
        XCTAssertEqual(out[77]?.instance?.title, "x")
        XCTAssertEqual(out[77]?.paused, false, "the worktree exists")
        XCTAssertEqual(out[77]?.autoApproves, true, "claude in its own agent pane under a live daemon is approved by Claude Squad")
    }

    /// An instance "x" running claude in an existing worktree, with a live
    /// daemon: the setup the pane checks below share.
    private func daemonWorld() throws -> (wt: String, table: [ProcessRunner.ProcessInfoRow]) {
        let wt = root + "/worktrees/x_1"
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try write(#"{"instances":[{"title":"x","program":"claude","worktree":{"worktree_path":"\#(wt)"}}]}"#,
                  to: "state.json")
        try write("\(getpid())", to: "daemon.pid")
        return (wt, [proc(getpid(), "/usr/local/bin/cs --daemon")])
    }

    func testLiveStandingsDoesNotTrustAnotherPaneInTheSameWorktree() throws {
        let (wt, table) = try daemonWorld()
        // Same worktree, but the claude runs in the instance's shell tab.
        let shellTab = CS.liveStandings(sessions: [live(pid: 77, cwd: wt)], table: table,
                                        paneListing: { "%2\t/dev/ttys009\t0\tclaudesquad_term_x\n" })
        XCTAssertEqual(shellTab[77]?.instance?.title, "x")
        XCTAssertEqual(shellTab[77]?.autoApproves, false, "the daemon only presses Enter in claudesquad_x")
        // Another instance's agent pane.
        let other = CS.liveStandings(sessions: [live(pid: 77, cwd: wt)], table: table,
                                     paneListing: { "%2\t/dev/ttys009\t0\tclaudesquad_y\n" })
        XCTAssertEqual(other[77]?.autoApproves, false)
        // A plain tmux session, a different tty, no pane at all, no tmux.
        XCTAssertEqual(CS.liveStandings(sessions: [live(pid: 77, cwd: wt)], table: table,
                                        paneListing: { "%2\t/dev/ttys009\t0\twork\n" })[77]?.autoApproves, false)
        XCTAssertEqual(CS.liveStandings(sessions: [live(pid: 77, cwd: wt)], table: table,
                                        paneListing: { "%2\t/dev/ttys010\t0\tclaudesquad_x\n" })[77]?.autoApproves, false)
        XCTAssertEqual(CS.liveStandings(sessions: [live(pid: 77, cwd: wt)], table: table,
                                        paneListing: { "" })[77]?.autoApproves, false)
        XCTAssertEqual(CS.liveStandings(sessions: [live(pid: 77, cwd: wt)], table: table,
                                        paneListing: { nil })[77]?.autoApproves, false, "no tmux server: page")
        XCTAssertEqual(CS.liveStandings(sessions: [live(pid: 77, cwd: wt, tty: nil)], table: table,
                                        paneListing: { "%2\t/dev/ttys009\t0\tclaudesquad_x\n" })[77]?.autoApproves, false,
                       "a session without a tty can't be matched to a pane")
    }

    func testLiveStandingsTrustsOnlyTheSessionInTheAgentPane() throws {
        let (wt, table) = try daemonWorld()
        let listing = "%1\t/dev/ttys009\t0\tclaudesquad_x\n%2\t/dev/ttys010\t0\tclaudesquad_term_x\n"
        let out = CS.liveStandings(sessions: [live(pid: 1, cwd: wt, tty: "ttys009"), live(pid: 2, cwd: wt, tty: "ttys010")],
                                   table: table, paneListing: { listing })
        XCTAssertEqual(out[1]?.autoApproves, true)
        XCTAssertEqual(out[2]?.autoApproves, false)
    }

    func testLiveStandingsListsPanesOnlyWhenSomethingWouldBeApproved() throws {
        var calls = 0
        // No daemon, nobody pressing Enter: nothing to verify.
        let wt = root + "/worktrees/x_1"
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try write(#"{"instances":[{"title":"x","program":"claude","worktree":{"worktree_path":"\#(wt)"}}]}"#,
                  to: "state.json")
        _ = CS.liveStandings(sessions: [live(cwd: wt)], table: [], paneListing: { calls += 1; return "" })
        XCTAssertEqual(calls, 0)
        // Two candidates under a daemon: one listing for the tick.
        try write("\(getpid())", to: "daemon.pid")
        _ = CS.liveStandings(sessions: [live(pid: 1, cwd: wt), live(pid: 2, cwd: wt)],
                             table: [proc(getpid(), "cs --daemon")], paneListing: { calls += 1; return "" })
        XCTAssertEqual(calls, 1)
    }

    func testIsAgentPane() {
        let x = inst("x")
        let listing = "%1\t/dev/ttys009\t0\tclaudesquad_x\n%2\t/dev/ttys010\t0\tclaudesquad_term_x\n"
        XCTAssertTrue(CS.isAgentPane(of: x, tty: "/dev/ttys009", listing: listing))
        XCTAssertFalse(CS.isAgentPane(of: x, tty: "/dev/ttys010", listing: listing), "the shell tab")
        XCTAssertFalse(CS.isAgentPane(of: inst("y"), tty: "/dev/ttys009", listing: listing), "another instance")
        XCTAssertFalse(CS.isAgentPane(of: x, tty: nil, listing: listing))
        XCTAssertFalse(CS.isAgentPane(of: x, tty: "/dev/ttys009", listing: "%1\t/dev/ttys009\t0\n"), "no session column")
    }

    // MARK: tmux pane listing (InjectionExecutor)

    func testTmuxPaneParsesASquadSession() throws {
        let r = try XCTUnwrap(InjectionExecutor.tmuxPane(forTTY: "/dev/ttys004",
                                                         listing: "%3\t/dev/ttys004\t1\tclaudesquad_fix"))
        XCTAssertEqual(r.id, "%3")
        XCTAssertTrue(r.inMode)
        XCTAssertEqual(r.session, "claudesquad_fix")
    }

    func testTmuxPaneWithoutTheSessionColumnStillParses() throws {
        let r = try XCTUnwrap(InjectionExecutor.tmuxPane(forTTY: "/dev/ttys004", listing: "%3\t/dev/ttys004\t0"))
        XCTAssertEqual(r.id, "%3")
        XCTAssertFalse(r.inMode)
        XCTAssertNil(r.session)
    }

    func testTmuxPaneEmptySessionColumnIsNil() throws {
        let r = try XCTUnwrap(InjectionExecutor.tmuxPane(forTTY: "/dev/ttys004", listing: "%3\t/dev/ttys004\t0\t"))
        XCTAssertNil(r.session)
    }

    func testTmuxPaneKeepsTabsInTheSessionName() throws {
        let r = try XCTUnwrap(InjectionExecutor.tmuxPane(forTTY: "/dev/ttys004",
                                                         listing: "%3\t/dev/ttys004\t0\tclaudesquad_a\tb"))
        XCTAssertEqual(r.session, "claudesquad_a\tb")
    }

    func testTmuxPaneMatchesTheExactTTYOnly() {
        let listing = "%3\t/dev/ttys0040\t0\tclaudesquad_other"
        XCTAssertNil(InjectionExecutor.tmuxPane(forTTY: "/dev/ttys004", listing: listing), "ttys0040 is not ttys004")
        let both = listing + "\n%4\t/dev/ttys004\t0\tclaudesquad_fix"
        XCTAssertEqual(InjectionExecutor.tmuxPane(forTTY: "/dev/ttys004", listing: both)?.id, "%4")
    }

    func testTmuxPaneNoServerIsNil() {
        XCTAssertNil(InjectionExecutor.tmuxPane(forTTY: "/dev/ttys004",
                                                listing: "no server running on /private/tmp/tmux-501/default"))
    }

    func testTmuxPaneListFormatCarriesTheSessionName() {
        XCTAssertEqual(InjectionExecutor.tmuxPaneListFormat, "#{pane_id}\t#{pane_tty}\t#{pane_in_mode}\t#{session_name}")
    }

    // MARK: host label (SessionRemote)

    private let squadPane = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/t", paneId: "%3", inMode: false,
                                                                session: "claudesquad_x")

    func testSquadPaneIsLabelledClaudeSquad() {
        let info = LiveSessionBackends.claudeHostInfo(squadPane, provider: .anthropic)
        XCTAssertEqual(info, SessionHostInfo(host: "Claude Squad", canType: true, typeBlocker: nil,
                                             canInterrupt: true, provider: .anthropic))
    }

    func testPausedSquadPaneIsBlocked() {
        let info = LiveSessionBackends.claudeHostInfo(squadPane, provider: .anthropic, squadPaused: true)
        XCTAssertEqual(info.host, "Claude Squad")
        XCTAssertFalse(info.canType)
        XCTAssertEqual(info.typeBlocker, "Paused in Claude Squad")
        XCTAssertFalse(info.canInterrupt)
        XCTAssertEqual(info.provider, .anthropic, "provider carried through when blocked")
    }

    func testPlainTmuxSessionsIgnoreThePausedFlag() {
        for name in ["claudesquad_term_x", "work", nil] as [String?] {
            let host = InjectionExecutor.TerminalHost.tmux(tmuxPath: "/t", paneId: "%3", inMode: false, session: name)
            let info = LiveSessionBackends.claudeHostInfo(host, provider: .unknown, squadPaused: true)
            XCTAssertEqual(info, SessionHostInfo(host: "tmux", canType: true, typeBlocker: nil, canInterrupt: true, provider: .unknown),
                           "session \(name ?? "nil"): not a Claude Squad agent")
        }
    }

    func testOtherHostsAreUnchangedBySquad() {
        XCTAssertEqual(LiveSessionBackends.claudeHostInfo(.terminalApp(tty: "/dev/ttys1"), provider: .unknown, squadPaused: true).host, "Terminal")
        XCTAssertEqual(LiveSessionBackends.claudeHostInfo(.iTerm(tty: "/dev/ttys1"), provider: .unknown, squadPaused: true).host, "iTerm")
        XCTAssertEqual(LiveSessionBackends.claudeHostInfo(.wezterm(WezTermBridge.Target(cliPath: "/wezterm", paneId: "3", socket: nil)), provider: .unknown, squadPaused: true).host, "WezTerm")
    }

    func testClaudeHostPicksTheSquadPaneAndAsksAboutIt() throws {
        let s = live(cwd: "/wt/fix_1")
        var askedSession: ClaudeLiveSession?
        var askedHost: InjectionExecutor.TerminalHost?
        let info = LiveSessionBackends.claudeHost(
            candidates: [s], table: [],
            resolveHost: { _, _ in self.squadPane },
            squadPaused: { session, host in
                askedSession = session
                askedHost = host
                return true
            })
        XCTAssertEqual(info.typeBlocker, "Paused in Claude Squad")
        XCTAssertFalse(info.canType)
        XCTAssertEqual(askedSession, s, "asked about the chosen session")
        XCTAssertEqual(askedHost, squadPane, "and the host it resolved to")
    }

    func testClaudeHostWithSquadNotPausedIsTypable() {
        let info = LiveSessionBackends.claudeHost(
            candidates: [live(cwd: "/wt/fix_1")], table: [],
            resolveHost: { _, _ in self.squadPane },
            squadPaused: { _, _ in false })
        XCTAssertEqual(info, SessionHostInfo(host: "Claude Squad", canType: true, typeBlocker: nil,
                                             canInterrupt: true, provider: .unknown))
    }

    // MARK: input gate (SessionInputGate)

    func testPlanRefusesAPausedSquadPane() {
        let step = SessionInputGate.claudePlan(target: .live, status: .idle, hasSessionFile: true,
                                               host: squadPane, text: "hi", interventionId: nil, squadPaused: true)
        XCTAssertEqual(step, .refuse(.refused(.notTypable, "Paused in Claude Squad")))
    }

    func testPlanUnchangedWhenNotPaused() {
        let step = SessionInputGate.claudePlan(target: .live, status: .idle, hasSessionFile: true,
                                               host: squadPane, text: "hi", interventionId: nil)
        XCTAssertEqual(step, .deliver(queued: false), "squadPaused defaults to false")
    }

    func testEarlierRefusalsWinOverPaused() {
        XCTAssertEqual(SessionInputGate.claudePlan(target: .ended, status: .idle, hasSessionFile: true,
                                                   host: squadPane, text: "hi", interventionId: nil, squadPaused: true),
                       .refuse(.refused(.ended, SessionInputGate.endedMessage)))
        XCTAssertEqual(SessionInputGate.claudePlan(target: .live, status: .unknown, hasSessionFile: true,
                                                   host: squadPane, text: "hi", interventionId: nil, squadPaused: true),
                       .refuse(.refused(.unknownState, SessionInputGate.unknownStateMessage)))
        XCTAssertEqual(SessionInputGate.claudePlan(target: .live, status: .waiting, hasSessionFile: true,
                                                   host: squadPane, text: "hi", interventionId: "p1", squadPaused: true),
                       .refuse(.refused(.waiting, SessionInputGate.waitingMessage, interventionId: "p1")))
    }

    func testRunClaudeInputRefusesAPausedSquadPaneWithoutTyping() {
        let world = SquadGateWorld(sid: sid, status: "idle", host: squadPane, paused: true)
        let r = SessionInputGate.runClaudeInput(sessionId: sid, clientId: "c1", text: "run the tests",
                                                interventionId: nil, io: world.io)
        XCTAssertEqual(r, .refused(.notTypable, "Paused in Claude Squad"))
        XCTAssertEqual(world.delivered, 0, "deliver is never called")
    }

    func testRunClaudeInputDeliversWhenSquadIsNotPaused() {
        let world = SquadGateWorld(sid: sid, status: "idle", host: squadPane, paused: false)
        let r = SessionInputGate.runClaudeInput(sessionId: sid, clientId: "c1", text: "run the tests",
                                                interventionId: nil, io: world.io)
        XCTAssertEqual(r.code, .delivered)
        XCTAssertEqual(world.delivered, 1)
    }

    func testRunClaudeInterruptRefusesAPausedSquadPaneWithoutEsc() {
        let world = SquadGateWorld(sid: sid, status: "busy", host: squadPane, paused: true)
        let r = SessionInputGate.runClaudeInterrupt(sessionId: sid, interventionId: nil, io: world.io)
        XCTAssertEqual(r, .refused(.interruptUnsupported, "Paused in Claude Squad"))
        XCTAssertEqual(world.interrupts, 0, "sendInterrupt is never called")
    }

    func testClaudeIOSquadPausedDefaultsToFalse() {
        let world = SquadGateWorld(sid: sid, status: "idle", host: squadPane, paused: nil)
        XCTAssertFalse(world.io.squadPaused(world.session, squadPane), "existing ClaudeIO constructions unchanged")
    }

    // MARK: approval auto-approval (InterventionDetector)

    func testIsAutoApprovedOnlyForAPlainApproval() {
        func approved(_ kind: InterventionKind, _ subtype: String? = nil, _ auto: Bool = true,
                      waitingFor: TimeInterval = 3) -> Bool {
            InterventionDetector.isAutoApproved(kind: kind, subtype: subtype, sessionAutoApproves: auto,
                                                waitingFor: waitingFor, grace: 15)
        }
        XCTAssertTrue(approved(.permission))
        XCTAssertFalse(approved(.permission, "plan"), "plan approvals always page")
        XCTAssertFalse(approved(.question))
        XCTAssertFalse(approved(.idle))
        XCTAssertFalse(approved(.rateLimit))
        XCTAssertFalse(approved(.permission, nil, false))
    }

    func testAutoApprovalOnlyHoldsForTheGraceWindow() {
        func approved(_ waitingFor: TimeInterval) -> Bool {
            InterventionDetector.isAutoApproved(kind: .permission, subtype: nil, sessionAutoApproves: true,
                                                waitingFor: waitingFor, grace: 15)
        }
        XCTAssertTrue(approved(0))
        XCTAssertTrue(approved(14.9))
        XCTAssertFalse(approved(15), "the grace is over")
        XCTAssertFalse(approved(600))
        XCTAssertTrue(approved(-5), "a clock that went backwards doesn't page early")
        XCTAssertTrue(InterventionDetector.autoApproveGrace >= 10 && InterventionDetector.autoApproveGrace <= 15)
    }

    private func waitingSession(since: Date) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 4242, sessionId: sid, cwd: "/tmp", status: .waiting, statusUpdatedAt: since,
                          tty: "ttys009", hasSessionFile: true)
    }

    private func finishedTurnSession(since: Date) -> ClaudeLiveSession {
        ClaudeLiveSession(pid: 4242, sessionId: sid, cwd: "/tmp", status: .idle, statusUpdatedAt: since,
                          tty: "ttys009", hasSessionFile: true)
    }

    func testAutoApprovedSessionOpensNoApprovalPage() throws {
        try writeTranscript([TranscriptFixture.user("deploy"),
                             TranscriptFixture.toolUse("toolu_1", "Bash", ["command": "make deploy"])])
        let r = detector().scan(sessions: [waitingSession(since: Date().addingTimeInterval(-3))],
                                transcriptFor: { _ in self.transcript }, settings: DetectorSettings(),
                                autoApproves: { _ in true })
        XCTAssertTrue(r.opened.isEmpty, "Claude Squad presses Enter itself: no page")
    }

    func testAutoApprovedApprovalPagesOnceClaudeSquadHasNotAnsweredInTime() throws {
        try writeTranscript([TranscriptFixture.user("deploy"),
                             TranscriptFixture.toolUse("toolu_1", "Bash", ["command": "make deploy"])])
        let det = detector()
        let began = Date()
        let session = waitingSession(since: began)
        let early = det.scan(sessions: [session], transcriptFor: { _ in self.transcript }, settings: DetectorSettings(),
                             autoApproves: { _ in true }, now: began.addingTimeInterval(3))
        XCTAssertTrue(early.opened.isEmpty, "inside the grace window: Claude Squad is about to answer")
        let late = det.scan(sessions: [session], transcriptFor: { _ in self.transcript }, settings: DetectorSettings(),
                            autoApproves: { _ in true }, now: began.addingTimeInterval(20))
        XCTAssertEqual(late.opened.map(\.kind), [.permission], "still waiting after the grace: page it")
        let again = det.scan(sessions: [session], transcriptFor: { _ in self.transcript }, settings: DetectorSettings(),
                             autoApproves: { _ in true }, now: began.addingTimeInterval(25))
        XCTAssertTrue(again.opened.isEmpty && again.resolved.isEmpty, "the page stays open, not re-opened")
        XCTAssertEqual(det.currentlyPending.count, 1)
    }

    func testSameApprovalPagesWhenNotAutoApproved() throws {
        try writeTranscript([TranscriptFixture.user("deploy"),
                             TranscriptFixture.toolUse("toolu_1", "Bash", ["command": "make deploy"])])
        let r = detector().scan(sessions: [waitingSession(since: Date().addingTimeInterval(-3))],
                                transcriptFor: { _ in self.transcript }, settings: DetectorSettings(),
                                autoApproves: { _ in false })
        XCTAssertEqual(r.opened.map(\.kind), [.permission])
    }

    func testPlanApprovalStillPagesWhenAutoApproved() throws {
        try writeTranscript([TranscriptFixture.user("plan it"),
                             TranscriptFixture.toolUse("toolu_1", "ExitPlanMode", ["plan": "Ship it"])])
        let r = detector().scan(sessions: [waitingSession(since: Date().addingTimeInterval(-3))],
                                transcriptFor: { _ in self.transcript }, settings: DetectorSettings(),
                                autoApproves: { _ in true })
        XCTAssertEqual(r.opened.map(\.kind), [.permission])
        XCTAssertEqual(r.opened.first?.subtype, "plan")
    }

    func testIdlePageStillOpensWhenAutoApproved() throws {
        try writeTranscript([TranscriptFixture.user("add a test"),
                             TranscriptFixture.assistantText("Done. Want me to run the suite?"),
                             TranscriptFixture.turnDuration()])
        let r = detector().scan(sessions: [finishedTurnSession(since: Date().addingTimeInterval(-120))],
                                transcriptFor: { _ in self.transcript }, settings: DetectorSettings(),
                                autoApproves: { _ in true })
        XCTAssertEqual(r.opened.map(\.kind), [.idle])
    }

    func testOpenPageStaysWhenTheSessionBecomesAutoApproved() throws {
        try writeTranscript([TranscriptFixture.user("deploy"),
                             TranscriptFixture.toolUse("toolu_1", "Bash", ["command": "make deploy"])])
        let det = detector()
        let session = waitingSession(since: Date().addingTimeInterval(-3))
        let r1 = det.scan(sessions: [session], transcriptFor: { _ in self.transcript }, settings: DetectorSettings(),
                          autoApproves: { _ in false })
        let page = try XCTUnwrap(r1.opened.first)

        let r2 = det.scan(sessions: [session], transcriptFor: { _ in self.transcript }, settings: DetectorSettings(),
                          autoApproves: { _ in true })
        XCTAssertTrue(r2.opened.isEmpty && r2.resolved.isEmpty, "a page already open is not touched")
        XCTAssertEqual(det.currentlyPending.keys.sorted(), [page.id])
    }

    // MARK: backend activity (ClaudeBackend)

    func testAttendedSessionsDropsOnlyPausedSquadInstances() {
        let paused = live(pid: 1, cwd: nil, tty: nil, status: .busy)
        let running = live(pid: 2, cwd: nil, tty: nil, status: .busy)
        let unknown = live(pid: 3, cwd: nil, tty: nil, status: .busy)
        let standings: [Int32: CS.Standing] = [
            1: CS.Standing(instance: nil, paused: true, autoApproves: false),
            2: CS.Standing(instance: nil, paused: false, autoApproves: true),
        ]
        XCTAssertEqual(ClaudeBackend.attendedSessions(sessions: [paused, running, unknown], standings: standings).map(\.pid), [2, 3])
        XCTAssertEqual(ClaudeBackend.attendedSessions(sessions: [paused], standings: [:]).map(\.pid), [1], "no standings: all attended")
    }

    func testPausedSquadInstanceDoesNotKeepTheMacActive() throws {
        // A real worktree for the running instance, none for the paused one.
        let runningWt = root + "/worktrees/run_1"
        try FileManager.default.createDirectory(atPath: runningWt, withIntermediateDirectories: true)
        let pausedWt = root + "/worktrees/gone_1"
        try write(#"{"instances":[{"title":"run","program":"claude","worktree":{"worktree_path":"\#(runningWt)"}},{"title":"gone","status":3,"program":"claude","worktree":{"worktree_path":"\#(pausedWt)"}}]}"#,
                  to: "state.json")
        let pausedBusy = live(pid: 1, cwd: pausedWt, status: .busy)
        let runningBusy = live(pid: 2, cwd: runningWt, status: .busy)
        func active(_ sessions: [ClaudeLiveSession]) -> Bool {
            ClaudeBackend.isActive(sessions: sessions, unidentifiedInteractive: 0, claudeRunning: true,
                                   secondsSinceTranscript: 1, requireRecentActivity: true, activityWindow: 90)
        }
        func attended(_ sessions: [ClaudeLiveSession]) -> [ClaudeLiveSession] {
            let standings = CS.liveStandings(sessions: sessions, table: [], paneListing: { nil })
            return ClaudeBackend.attendedSessions(sessions: sessions, standings: standings)
        }
        XCTAssertFalse(active(attended([pausedBusy])), "the lone busy session is a paused instance")
        XCTAssertEqual(attended([pausedBusy, runningBusy]).map(\.pid), [2])
        XCTAssertTrue(active(attended([pausedBusy, runningBusy])), "another busy session still counts")
    }
}

/// A fake Mac for the Claude input runners: one live session, its terminal
/// host, and a count of what was typed or interrupted. Nothing is sent.
private final class SquadGateWorld {
    let session: ClaudeLiveSession
    let host: InjectionExecutor.TerminalHost
    let status: String
    let paused: Bool?
    var delivered = 0
    var interrupts = 0

    init(sid: String, status: String, host: InjectionExecutor.TerminalHost, paused: Bool?) {
        self.session = ClaudeLiveSession(pid: 4242, sessionId: sid, cwd: "/wt/fix_1", status: .idle,
                                         statusUpdatedAt: nil, tty: "ttys009", hasSessionFile: true)
        self.status = status
        self.host = host
        self.paused = paused
    }

    var io: SessionInputGate.ClaudeIO {
        var io = SessionInputGate.ClaudeIO(
            resolve: { _ in .live(self.session, [ProcessRunner.ProcessInfoRow(pid: 4242, ppid: 1, tty: "ttys009", command: "claude")]) },
            currentRecord: { pid in ClaudeSessionRecord(pid: pid, status: self.status) },
            resolveHost: { _, _ in self.host },
            deliver: { _, _, _ in
                self.delivered += 1
                return InjectionResult(method: .tmux, success: true, output: "ok", detail: "Typed into tmux pane %3")
            },
            isForeground: { _ in true },
            sendInterrupt: { _ in
                self.interrupts += 1
                return InjectionResult(method: .tmux, success: true, output: "ok")
            })
        if let paused {
            io.squadPaused = { _, _ in paused }
        }
        return io
    }
}
