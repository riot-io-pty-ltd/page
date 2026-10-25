import XCTest
@testable import ClaudePowerMode

/// F6 (Codex half): a background `codex exec resume` never runs while any
/// other process — above all a foreign `codex app-server` (the Codex app,
/// an editor extension) — has the thread's rollout open.
final class CodexRolloutHolderTests: XCTestCase {
    private let desktopAppServer = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c features.code_mode_host=true app-server --analytics-default-enabled"

    private func result(_ stdout: String, status: Int32 = 0, stderr: String = "", timedOut: Bool = false,
                        launched: Bool = true) -> ProcessRunner.Result {
        ProcessRunner.Result(status: status, stdout: stdout, stderr: stderr, timedOut: timedOut, launched: launched)
    }

    private func row(_ pid: Int32, _ command: String, ppid: Int32 = 1, tty: String = "??") -> ProcessRunner.ProcessInfoRow {
        ProcessRunner.ProcessInfoRow(pid: pid, ppid: ppid, tty: tty, command: command)
    }

    private func tempRollout(threadId: String = "019a-thread") throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pagetest-holders-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("rollout-2026-10-24T10-00-00-\(threadId).jsonl").path
        try "{}\n".write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testDesktopAppServerIsNotAnInteractiveSession() {
        // `-c key=value` used to be read as the subcommand, making Codex
        // Desktop's app-server look like a TUI with no terminal.
        XCTAssertFalse(CodexProcessScanner.isInteractiveCodexCommand(desktopAppServer))
        XCTAssertFalse(CodexProcessScanner.isInteractiveCodexCommand("/x/bin/codex -m gpt-5 exec resume t hi"))
        XCTAssertFalse(CodexProcessScanner.isInteractiveCodexCommand("/x/bin/codex --config a=b mcp-server"))
        XCTAssertTrue(CodexProcessScanner.isInteractiveCodexCommand("/x/bin/codex -c model=o3 resume abc"))
        XCTAssertTrue(CodexProcessScanner.isInteractiveCodexCommand("/x/bin/codex -c model=o3"))
        XCTAssertTrue(CodexProcessScanner.isInteractiveCodexCommand("node /usr/local/bin/codex --model gpt-5"))

        XCTAssertTrue(CodexProcessScanner.isCodexFamilyCommand(desktopAppServer))
        XCTAssertTrue(CodexProcessScanner.isCodexFamilyCommand("node /usr/local/bin/codex app-server"))
        XCTAssertTrue(CodexProcessScanner.isCodexFamilyCommand("/v/aarch64-apple-darwin/bin/codex-aarch64-apple-darwin exec x"))
        XCTAssertFalse(CodexProcessScanner.isCodexFamilyCommand("/usr/bin/vim codex.md"))
        XCTAssertFalse(CodexProcessScanner.isCodexFamilyCommand("node server.js"))
    }

    func testParseLsofHolders() {
        let holders = CodexInjector.parseLsofHolders("p61999\nccodex\nf27\np400\ncsleep\nf3\n")
        XCTAssertEqual(holders, [.init(pid: 61999, command: "codex"), .init(pid: 400, command: "sleep")])
        XCTAssertEqual(CodexInjector.parseLsofHolders(""), [])
    }

    func testHoldersByPath() throws {
        let path = try tempRollout()
        var seenArgs: [String] = []
        let held = CodexInjector.rolloutHolders(rolloutPath: path, threadId: "019a-thread", table: [], ownPid: 7) {
            seenArgs = $0
            return self.result("p61999\nccodex\np7\ncPage\n")
        }
        XCTAssertEqual(held, .held([.init(pid: 61999, command: "codex")]), "Page's own pid never counts")
        XCTAssertEqual(seenArgs.last, path)
        XCTAssertTrue(seenArgs.contains("--"))

        // lsof's "nobody has it open": exit 1, nothing on stderr.
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: path, threadId: "t", table: [], ownPid: 7) { _ in
            self.result("", status: 1)
        }, CodexInjector.RolloutHolders.none)
        // Only Page itself: nobody else.
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: path, threadId: "t", table: [], ownPid: 7) { _ in
            self.result("p7\ncPage\n")
        }, CodexInjector.RolloutHolders.none)
        // Errors, timeouts and launch failures are "can't tell".
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: path, threadId: "t", table: [], ownPid: 7) { _ in
            self.result("", status: 1, stderr: "lsof: status error")
        }, .unknown)
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: path, threadId: "t", table: [], ownPid: 7) { _ in
            self.result("", timedOut: true)
        }, .unknown)
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: path, threadId: "t", table: [], ownPid: 7) { _ in
            .notLaunched
        }, .unknown)
    }

    func testHoldersByThreadNameWhenThePathIsUnknown() {
        let table = [row(61999, desktopAppServer), row(500, "/usr/bin/vim codex.md"), row(7, "node /usr/local/bin/codex app-server")]
        var asked: [String] = []
        let held = CodexInjector.rolloutHolders(rolloutPath: nil, threadId: "019a-thread", table: table, ownPid: 7) {
            asked = $0
            return self.result("p61999\nfcwd\nn/Users/me/p\nf30\nn/Users/me/.codex/sessions/2026/10/24/rollout-2026-10-24T10-00-00-019a-thread.jsonl\n")
        }
        XCTAssertEqual(held, .held([.init(pid: 61999, command: desktopAppServer)]))
        XCTAssertEqual(asked[asked.firstIndex(of: "-p")! + 1], "61999", "only codex-family processes other than Page")

        // Another thread's rollout: not ours.
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: nil, threadId: "019a-thread", table: table, ownPid: 7) { _ in
            self.result("p61999\nfcwd\nn/p\nf30\nn/s/rollout-2026-10-24T09-00-00-019b-other.jsonl\n")
        }, CodexInjector.RolloutHolders.none)
        // A candidate lsof couldn't read might hold it.
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: nil, threadId: "019a-thread", table: table, ownPid: 7) { _ in
            self.result("", status: 1)
        }, .unknown)
        // No codex at all: nothing to ask.
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: nil, threadId: "019a-thread",
                                                    table: [row(500, "/usr/bin/vim x")], ownPid: 7) { _ in
            XCTFail("lsof must not run without candidates"); return .notLaunched
        }, CodexInjector.RolloutHolders.none)
        // A missing rollout file falls back to the name scan.
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: "/nonexistent/rollout-x-019a-thread.jsonl", threadId: "019a-thread",
                                                    table: table, ownPid: 7) { args in
            XCTAssertTrue(args.contains("-p"))
            return self.result("p61999\nfcwd\nn/p\n")
        }, CodexInjector.RolloutHolders.none)
    }

    func testBlockerNamesTheHolder() {
        let table = [row(1, "/sbin/launchd"), row(61999, desktopAppServer)]
        let desktop = CodexInjector.execResumeBlocker(table: table, processes: [], project: "p",
                                                      holders: .held([.init(pid: 61999, command: "codex")]))
        XCTAssertEqual(desktop, "This Codex session is open in the Codex app — reply there")

        let vscodeTable = [
            row(10, "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
            row(11, "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)", ppid: 10),
            row(12, "/Users/me/.vscode/extensions/openai.chatgpt-1.0/bin/macos-aarch64/codex app-server", ppid: 11),
        ]
        let vscode = CodexInjector.execResumeBlocker(table: vscodeTable, processes: [], project: "p",
                                                     holders: .held([.init(pid: 12, command: "codex")]))
        XCTAssertEqual(vscode, "This Codex session is open in Visual Studio Code — reply there")

        let exec = CodexInjector.execResumeBlocker(table: [row(1, "x"), row(20, "/x/codex exec resume t hi")], processes: [], project: "p",
                                                   holders: .held([.init(pid: 20, command: "codex")]))
        XCTAssertEqual(exec, "This Codex session is open in a background codex exec run — reply there")

        let unnamed = CodexInjector.execResumeBlocker(table: [row(1, "x")], processes: [], project: "p",
                                                      holders: .held([.init(pid: 30, command: "python3")]))
        XCTAssertEqual(unnamed, "Another Codex process has this session open — reply there or on the Mac")

        XCTAssertNotNil(CodexInjector.execResumeBlocker(table: table, processes: [], project: "p", holders: .unknown))
        XCTAssertNil(CodexInjector.execResumeBlocker(table: table, processes: [], project: "p", holders: .none))
    }

    func testPlanRefusesExecResumeWhileAForeignAppServerHoldsTheThread() {
        let table = [row(1, "/sbin/launchd"), row(61999, desktopAppServer)]
        var asked = 0
        let step = CodexInjector.plan(text: "carry on", threadId: "t1", cwd: "/p", rolloutPath: "/r/rollout-x-t1.jsonl",
                                      codexPath: "", allowExecResume: true, cwdFallback: .never,
                                      table: table, processes: [], canonicalCwd: "/p",
                                      rolloutHolders: { asked += 1; return .held([.init(pid: 61999, command: "codex")]) })
        guard case .finished(let outcome) = step else { return XCTFail("expected a refusal, got \(step)") }
        XCTAssertFalse(outcome.success)
        XCTAssertTrue(outcome.detail.contains("Codex app"), outcome.detail)
        XCTAssertEqual(asked, 1)

        // Nobody else holds it: the resume is planned.
        let free = CodexInjector.plan(text: "carry on", threadId: "t1", cwd: "/p", rolloutPath: "/r/rollout-x-t1.jsonl",
                                      codexPath: "", allowExecResume: true, cwdFallback: .never,
                                      table: table, processes: [], canonicalCwd: "/p", rolloutHolders: { .none })
        guard case .needsExecResume = free else { return XCTFail("expected exec resume, got \(free)") }
    }

    func testHolderCheckOnlyRunsWhenExecResumeIsNext() {
        let ours = "/r/rollout-x-t1.jsonl"
        let tui = CodexProcess(pid: 42, ppid: 1, tty: "ttys004", cwd: "/p", openRollouts: [ours], command: "/x/codex")
        let typed = CodexInjector.plan(text: "hi", threadId: "t1", cwd: "/p", rolloutPath: ours, codexPath: "",
                                       allowExecResume: true, cwdFallback: .allowed,
                                       table: [ProcessRunner.ProcessInfoRow(pid: 42, ppid: 1, tty: "ttys004", command: "/x/codex")],
                                       processes: [tui], canonicalCwd: "/p",
                                       rolloutHolders: { XCTFail("no lsof for a live TUI target"); return .unknown })
        XCTAssertEqual(typed, .type("hi", tty: "ttys004", pid: 42))

        let off = CodexInjector.plan(text: "hi", threadId: "t1", cwd: "/p", rolloutPath: ours, codexPath: "",
                                     allowExecResume: false, cwdFallback: .never, table: [row(1, "x")], processes: [],
                                     canonicalCwd: "/p",
                                     rolloutHolders: { XCTFail("no lsof when resume is off"); return .unknown })
        guard case .finished(let o) = off else { return XCTFail() }
        XCTAssertFalse(o.success)
    }

    /// Real lsof: a process holding the rollout open (as a foreign
    /// app-server does) is found by path; once it exits, nobody is.
    func testRealLsofFindsAProcessHoldingTheRollout() throws {
        let path = try tempRollout()
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sh")
        holder.arguments = ["-c", "exec 3>>\"$0\"; exec /bin/sleep 30", path]
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        usleep(400_000)

        let held = CodexInjector.rolloutHolders(rolloutPath: path, threadId: "019a-thread", table: [])
        guard case .held(let list) = held else { return XCTFail("expected the sleeping holder, got \(held)") }
        XCTAssertTrue(list.contains { $0.pid == holder.processIdentifier }, "\(list)")

        holder.terminate()
        holder.waitUntilExit()
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: path, threadId: "019a-thread", table: []),
                       CodexInjector.RolloutHolders.none)
    }

    /// Real lsof, no rollout path: the name scan finds the codex-family
    /// process (by the ps table) that has the thread's rollout open. The
    /// holder is a plain shell; the table row names it as a codex, since a
    /// copied system binary can't be launched under another name.
    func testRealLsofNameScanFindsACodexNamedHolder() throws {
        let path = try tempRollout(threadId: "019c-namescan")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sh")
        holder.arguments = ["-c", "exec 3>>\"$0\"; exec /bin/sleep 30", path]
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        usleep(400_000)

        let command = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server"
        let table = [ProcessRunner.ProcessInfoRow(pid: holder.processIdentifier, ppid: getpid(), tty: "??", command: command)]
        let held = CodexInjector.rolloutHolders(rolloutPath: nil, threadId: "019c-namescan", table: table)
        XCTAssertEqual(held, .held([.init(pid: holder.processIdentifier, command: command)]))
        XCTAssertEqual(CodexInjector.rolloutHolders(rolloutPath: nil, threadId: "019d-other", table: table),
                       CodexInjector.RolloutHolders.none)
    }
}

/// Presence/draft gate on the Codex low-battery resume: while the user is
/// at the Mac, Page only types into a composer it can see is empty.
final class CodexComposerGateTests: XCTestCase {
    private let esc = "\u{1B}"
    private var bg: String { "\(esc)[48;2;40;40;40m" }
    private var dim: String { "\(esc)[2m" }
    private var reset: String { "\(esc)[0m" }

    private func screen(composer: String, below: [String] = []) -> String {
        (["\(esc)[1m• Worked for 12s\(reset)", "", "Done — tests pass.", "", composer, ""] + below).joined(separator: "\n")
    }

    func testEmptyComposerWithDimPlaceholderOnATintedBackground() {
        let s = screen(composer: "\(esc)[1m\(bg)›\(reset)\(bg) \(dim)Ask Codex to do anything\(reset)",
                       below: ["  \(dim)? for shortcuts\(reset)                  \(dim)100% context left\(reset)"])
        XCTAssertEqual(CodexInjector.codexComposer(screen: s), .empty)
    }

    func testDraftOnATintedBackgroundIsADraft() {
        // `48;2;…` carries a literal 2: it must not be read as "dim", or
        // every draft on Codex's tinted composer would look empty.
        let s = screen(composer: "\(bg)› fix the flaky test\(reset)", below: ["  \(dim)? for shortcuts\(reset)"])
        XCTAssertEqual(CodexInjector.codexComposer(screen: s), .draft)
        let palette = screen(composer: "\(esc)[48;5;2m› half typed\(reset)")
        XCTAssertEqual(CodexInjector.codexComposer(screen: palette), .draft)
    }

    func testKeyHintsDrawnNormallyStillCountAsEmpty() {
        let s = screen(composer: "› \(dim)Ask Codex to do anything\(reset)", below: ["", "  ⏎ send   ⌃J newline   ⌃T transcript   ⌃C quit"])
        XCTAssertEqual(CodexInjector.codexComposer(screen: s), .empty)
    }

    func testAnythingElseBelowAnEmptyPromptIsUnknown() {
        let continuation = screen(composer: "› ", below: ["  second line of a draft"])
        XCTAssertEqual(CodexInjector.codexComposer(screen: continuation), .unknown)
    }

    func testNoComposerIsUnknown() {
        XCTAssertEqual(CodexInjector.codexComposer(screen: "Allow command?\n  1. Yes\n  2. No\n"), .unknown)
        XCTAssertEqual(CodexInjector.codexComposer(screen: ""), .unknown)
    }

    func testLegacyBarComposer() {
        XCTAssertEqual(CodexInjector.codexComposer(screen: screen(composer: "▌ \(dim)Ask Codex to do anything\(reset)")), .empty)
        XCTAssertEqual(CodexInjector.codexComposer(screen: screen(composer: "▌ refactor the parser")), .draft)
    }

    func testStyledCellsConsumesExtendedColoursWhole() {
        let cells = CodexInjector.styledCells("\(esc)[38;2;128;128;128mg\(esc)[39mn\(esc)[48;2;2;2;2mb\(esc)[2md\(esc)[22mx")
        XCTAssertEqual(cells.map(\.char), ["g", "n", "b", "d", "x"])
        XCTAssertEqual(cells.map(\.faint), [true, false, false, true, false])
        // OSC hyperlinks are dropped, not typed.
        let link = CodexInjector.styledCells("\(esc)]8;;https://x\u{07}a\(esc)]8;;\u{07}")
        XCTAssertEqual(link.map(\.char), ["a"])
    }

    func testComposerRefusalPerTerminal() {
        XCTAssertEqual(CodexInjector.composerRefusal(.terminalApp(tty: "ttys004")),
                       CodexInjector.terminalComposerUnverifiedDetail)
        XCTAssertNil(CodexInjector.composerRefusal(.cmux(CmuxBridge.Target(surfaceId: "s", workspaceId: nil, cliPath: "/x", source: "environment"))),
                     "typeIntoCmux already requires cmux's input state to read empty")
        XCTAssertNil(CodexInjector.composerRefusal(.unavailable("x")))
        XCTAssertEqual(CodexInjector.composerRefusal(.tmux(pane: "%1"), capture: { _ in nil }),
                       CodexInjector.composerUnverifiedDetail)
        XCTAssertEqual(CodexInjector.composerRefusal(.tmux(pane: "%1"), capture: { _ in "› half typed\n" }),
                       CmuxBridge.draftDetail)
        XCTAssertNil(CodexInjector.composerRefusal(.tmux(pane: "%1"), capture: { _ in "› \u{1B}[2mAsk Codex\u{1B}[0m\n" }))
    }

    func testPresenceWindowMatchesClaude() {
        var cfg = Config()
        cfg.idlePageOnlyWhenAwaySeconds = 30
        XCTAssertEqual(CodexBackend.resumePresenceWindow(cfg), 120)
        cfg.idlePageOnlyWhenAwaySeconds = 600
        XCTAssertEqual(CodexBackend.resumePresenceWindow(cfg), 600)
    }
}

/// The composer check against a real (private, throwaway) tmux server whose
/// pane only prints a fixture screen — nothing is typed anywhere.
final class CodexComposerTmuxTests: XCTestCase {
    private var socket = ""
    private var dir: URL!
    private var tmuxPath = ""

    override func setUpWithError() throws {
        guard let tmux = ProcessRunner.findExecutable("tmux") else { throw XCTSkip("tmux not installed") }
        tmuxPath = tmux
        socket = "pagetest-codexseam-\(UUID().uuidString.prefix(8))"
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        CodexInjector.tmuxServerArgs = []
        if !tmuxPath.isEmpty {
            let socketPath = ProcessRunner.run(tmuxPath, ["-L", socket, "display-message", "-p", "#{socket_path}"], timeout: 3).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ProcessRunner.run(tmuxPath, ["-L", socket, "kill-server"], timeout: 5)
            if socketPath.contains("pagetest-codexseam-") { try? FileManager.default.removeItem(atPath: socketPath) }
        }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Starts a pane running `script` and waits (up to 5 s) until it shows
    /// `marker`: a fixed sleep loses the race when the machine is busy.
    private func pane(printing script: String, showing marker: String) throws -> String {
        let file = dir.appendingPathComponent("screen-\(UUID().uuidString.prefix(6)).sh").path
        try "#!/bin/sh\n\(script)\nexec sleep 30\n".write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
        let r = ProcessRunner.run(tmuxPath, ["-L", socket, "-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{pane_id}",
                                             "-x", "100", "-y", "12", file], timeout: 5)
        guard r.succeeded else { throw XCTSkip("couldn't start private tmux server: \(r.stderr)") }
        let id = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        CodexInjector.tmuxServerArgs = ["-L", socket]
        for _ in 0..<50 {
            if ProcessRunner.run(tmuxPath, ["-L", socket, "capture-pane", "-p", "-t", id], timeout: 3).stdout.contains(marker) { return id }
            usleep(100_000)
        }
        XCTFail("pane never showed \(marker)")
        return id
    }

    func testRealCaptureOfAnEmptyComposer() throws {
        let p = try pane(printing: """
        printf '\\033[1mWorked for 12s\\033[0m\\n\\n'
        printf '\\033[48;2;40;40;40m\\033[1m\\342\\200\\272\\033[22m \\033[2mAsk Codex to do anything\\033[0m\\n\\n'
        printf '  \\033[2m? for shortcuts\\033[22m      \\033[2m100%% context left\\033[0m\\n'
        """, showing: "context left")
        XCTAssertNil(CodexInjector.composerRefusal(.tmux(pane: p)), CodexInjector.capturePane(p) ?? "no capture")
    }

    func testRealCaptureOfADraft() throws {
        let p = try pane(printing: """
        printf 'Done.\\n\\n'
        printf '\\033[48;2;40;40;40m\\033[1m\\342\\200\\272\\033[22m fix the flaky test\\033[0m\\n\\n'
        printf '  \\033[2m? for shortcuts\\033[0m\\n'
        """, showing: "for shortcuts")
        XCTAssertEqual(CodexInjector.composerRefusal(.tmux(pane: p)), CmuxBridge.draftDetail)
    }

    func testMissingPaneIsUnverified() throws {
        _ = try pane(printing: "printf 'x\\n'", showing: "x")
        XCTAssertEqual(CodexInjector.composerRefusal(.tmux(pane: "%999")), CodexInjector.composerUnverifiedDetail)
    }
}

/// SyntheticInput is the one record of Page's own keystrokes.
final class SyntheticInputSourceOfTruthTests: XCTestCase {
    private var dir: URL!
    private var savedDir: URL!

    override func setUp() {
        savedDir = SyntheticInput.directory
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pagetest-synth-\(UUID().uuidString.prefix(8))")
        SyntheticInput.resetForTesting()
        SyntheticInput.directory = dir
    }

    override func tearDown() {
        SyntheticInput.directory = savedDir
        SyntheticInput.resetForTesting()
        try? FileManager.default.removeItem(at: dir)
    }

    func testBurstKeepsTheUsersBaseline() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // User idle 600 s; Page records before its Return…
        SyntheticInput.record(now: t0, rawIdle: 600)
        // …retries 0.5 s later (the last input is Page's own Return)…
        SyntheticInput.record(now: t0.addingTimeInterval(0.5), rawIdle: 0.4)
        // …and records again once it landed.
        SyntheticInput.record(now: t0.addingTimeInterval(1), rawIdle: 0.3)

        let later = t0.addingTimeInterval(31)
        XCTAssertTrue(SyntheticInput.explainsIdleReset(idleSeconds: 30.4, now: later))
        XCTAssertEqual(SyntheticInput.adjustedIdle(raw: 30.4, now: later), 631, accuracy: 0.001)
        // The user touches the Mac 20 s after Page's input: their own.
        XCTAssertFalse(SyntheticInput.explainsIdleReset(idleSeconds: 10, now: later))
        XCTAssertEqual(SyntheticInput.adjustedIdle(raw: 10, now: later), 10)
        XCTAssertEqual(SyntheticInput.adjustedIdle(raw: .infinity, now: later), .infinity)
    }

    func testAFreshBurstAfterUserInputTakesANewBaseline() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        SyntheticInput.record(now: t0, rawIdle: 600)
        // 60 s later the user had typed 5 s before Page's next keystroke.
        let t1 = t0.addingTimeInterval(60)
        SyntheticInput.record(now: t1, rawIdle: 5)
        XCTAssertEqual(SyntheticInput.adjustedIdle(raw: 1, now: t1.addingTimeInterval(2)), 7, accuracy: 0.001)
    }

    func testMarkerFromAnEarlierRunIsReadOnce() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "1800000000\n".write(to: dir.appendingPathComponent(SyntheticInput.markerName), atomically: true, encoding: .utf8)
        SyntheticInput.directory = dir  // re-arms the one-time marker read
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(SyntheticInput.lastAt, at)
        XCTAssertTrue(SyntheticInput.explainsIdleReset(idleSeconds: 10, now: at.addingTimeInterval(11)))
        // No baseline from an earlier run: the reset is Page's, so "away".
        XCTAssertEqual(SyntheticInput.adjustedIdle(raw: 10, now: at.addingTimeInterval(11)), .infinity)
    }

    func testMarkerParsing() {
        XCTAssertEqual(SyntheticInput.parseMarker("1800000000\n"), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(SyntheticInput.parseMarker("1800000000"), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(SyntheticInput.parseMarker(""))
        XCTAssertNil(SyntheticInput.parseMarker("abc\n"))
        XCTAssertNil(SyntheticInput.parseMarker("-5\n"))
    }

    func testRecordWritesTheMarkerTheHookReads() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_123)
        SyntheticInput.record(now: at, rawIdle: 50)
        let body = try String(contentsOf: SyntheticInput.markerURL, encoding: .utf8)
        XCTAssertEqual(body, "1800000123\n")
        let perms = try FileManager.default.attributesOfItem(atPath: SyntheticInput.markerURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        XCTAssertEqual(SyntheticInput.toleranceSeconds, 3, "the hook uses the same 3 s rule")
    }
}
