import XCTest
@testable import ClaudePowerMode

/// Regression tests for the Codex targeting / delivery hardening.
final class CodexHardeningTests: XCTestCase {
    private let ours = "/s/rollout-1-ours.jsonl"
    private let other = "/s/rollout-2-other.jsonl"

    private func proc(_ pid: Int32, ppid: Int32 = 1, tty: String?, cwd: String?,
                      rollouts: Set<String> = [], command: String = "codex") -> CodexProcess {
        CodexProcess(pid: pid, ppid: ppid, tty: tty, cwd: cwd, openRollouts: rollouts, command: command)
    }

    /// npm install: `node …/bin/codex.js` (no rollout) + its native child
    /// (holds the rollout of the thread it is on), both on one tty.
    private func npmPair(tty: String?, childRollouts: Set<String>) -> [CodexProcess] {
        [proc(10, tty: tty, cwd: "/p", command: "node /usr/local/lib/node_modules/@openai/codex/bin/codex.js"),
         proc(11, ppid: 10, tty: tty, cwd: "/p", rollouts: childRollouts,
              command: "/usr/local/lib/node_modules/@openai/codex/vendor/codex")]
    }

    // MARK: F1 — cwd fallback must not pick another session's wrapper

    func testWrapperOfSessionOnAnotherThreadIsNotATarget() {
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours,
                                                   processes: npmPair(tty: "ttys001", childRollouts: [other])),
                       .none)
        // Without a rollout path to match, the attached pair is still excluded.
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: nil,
                                                   processes: npmPair(tty: "ttys001", childRollouts: [other])),
                       .none)
    }

    func testTtylessWrapperOfAttachedChildIsNotATarget() {
        // No tty to group by: the parent/child link still excludes it.
        let procs = [proc(10, tty: nil, cwd: "/p", command: "node /x/bin/codex.js"),
                     proc(11, ppid: 10, tty: nil, cwd: "/p", rollouts: [other])]
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours, processes: procs), .none)
    }

    func testPairHoldingOurRolloutIsTheTarget() {
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours,
                                                   processes: npmPair(tty: "ttys001", childRollouts: [ours])),
                       .tty("ttys001", pid: 11))
    }

    func testUnattachedPairStillResolvesByFolder() {
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours,
                                                   processes: npmPair(tty: "ttys001", childRollouts: [])),
                       .tty("ttys001", pid: 10))
    }

    func testAttachedPairDoesNotHideAnUnattachedTerminal() {
        let procs = npmPair(tty: "ttys001", childRollouts: [other]) + [proc(20, tty: "ttys002", cwd: "/p")]
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours, processes: procs),
                       .tty("ttys002", pid: 20))
    }

    func testTerminalWithUnreadableProcessIsNotATarget() {
        // lsof couldn't read one process on the tty: it might hold anything.
        let procs = [proc(10, tty: "ttys001", cwd: "/p"), proc(11, ppid: 10, tty: "ttys001", cwd: nil)]
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours, processes: procs), .none)
    }

    func testDesktopThreadsNeverFallBackToTheFolder() {
        let lone = [proc(10, tty: "ttys001", cwd: "/p")]
        for source in [AgentSessionSource.desktop, .vscode, .exec, .remote] {
            XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours, processes: lone,
                                                       cwdFallback: .forSource(source)), .none, "\(source)")
        }
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours, processes: lone,
                                                   cwdFallback: .forSource(.terminal)), .tty("ttys001", pid: 10))
        // Unknown source: a folder match can't be confirmed either way.
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours, processes: lone,
                                                   cwdFallback: .forSource(.unknown)), .unconfirmed)
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours, processes: [],
                                                   cwdFallback: .forSource(.unknown)), .none)
        // The rollout owner is found whatever the source.
        let owner = [proc(10, tty: "ttys001", cwd: "/", rollouts: [ours])]
        XCTAssertEqual(CodexInjector.resolveTarget(cwd: "/p", rolloutPath: ours, processes: owner,
                                                   cwdFallback: .never), .tty("ttys001", pid: 10))
    }

    func testUnconfirmedFolderMatchIsNeverTypedOrResumed() {
        let step = CodexInjector.plan(text: "go on", threadId: "t1", cwd: "/p", rolloutPath: ours, codexPath: "",
                                      allowExecResume: true, cwdFallback: .refuse,
                                      table: [ProcessRunner.ProcessInfoRow(pid: 10, ppid: 1, tty: "ttys001", command: "codex")],
                                      processes: [proc(10, tty: "ttys001", cwd: "/p")], canonicalCwd: "/p")
        guard case .finished(let outcome) = step else { return XCTFail("expected a refusal, got \(step)") }
        XCTAssertFalse(outcome.success)
    }

    func testTripleNamedNativeBinaryIsScanned() {
        XCTAssertTrue(CodexProcessScanner.isInteractiveCodexCommand(
            "/usr/local/lib/node_modules/@openai/codex/bin/codex-aarch64-apple-darwin"))
        XCTAssertFalse(CodexProcessScanner.isInteractiveCodexCommand(
            "/x/bin/codex-x86_64-apple-darwin exec resume t hi"))
        XCTAssertFalse(CodexProcessScanner.isInteractiveCodexCommand("/x/bin/codex-helper"))
    }

    // MARK: Foreground — never type into a suspended / backgrounded codex

    func testSuspendedOrBackgroundCodexIsNotTypedInto() {
        let table = [ProcessRunner.ProcessInfoRow(pid: 10, ppid: 1, tty: "ttys001", command: "codex")]
        for answer: Bool? in [false, nil] {
            XCTAssertEqual(CodexInjector.terminal(tty: "ttys001", pid: 10, threadId: "t1", table: table,
                                                  isForeground: { _ in answer }),
                           .unavailable(CodexInjector.notForegroundDetail), "\(String(describing: answer))")
        }
        // An unavailable terminal is skipped by the low-battery pause too.
        XCTAssertEqual(CodexBackend.pauseStrategy(terminal: .unavailable(CodexInjector.notForegroundDetail), mode: .pause),
                       .skip(CodexInjector.notForegroundDetail))
    }

    // MARK: CONC-1 — exec resume is planned, never run on the reply queue

    func testPlanHandsExecResumeBackInsteadOfRunningIt() {
        let table = [ProcessRunner.ProcessInfoRow(pid: 1, ppid: 0, tty: "??", command: "/sbin/launchd")]
        let step = CodexInjector.plan(text: " carry on ", threadId: "t1", cwd: "/p", rolloutPath: ours, codexPath: "/x/codex",
                                      allowExecResume: true, cwdFallback: .allowed,
                                      table: table, processes: [], canonicalCwd: "/p")
        XCTAssertEqual(step, .needsExecResume(CodexInjector.ExecResumeJob(
            text: "carry on", threadId: "t1", cwd: "/p", rolloutPath: ours, codexPath: "/x/codex", cwdFallback: .allowed)))
    }

    func testPlanRefusesExecResumeWhenOffOrUnsure() {
        let table = [ProcessRunner.ProcessInfoRow(pid: 1, ppid: 0, tty: "??", command: "/sbin/launchd")]
        let off = CodexInjector.plan(text: "x", threadId: "t1", cwd: "/p", rolloutPath: ours, codexPath: "",
                                     allowExecResume: false, cwdFallback: .allowed,
                                     table: table, processes: [], canonicalCwd: "/p")
        guard case .finished(let o1) = off else { return XCTFail("\(off)") }
        XCTAssertFalse(o1.success)
        // A codex lsof couldn't read might own the thread.
        let unsure = CodexInjector.plan(text: "x", threadId: "t1", cwd: "/p", rolloutPath: ours, codexPath: "",
                                        allowExecResume: true, cwdFallback: .allowed,
                                        table: table, processes: [proc(5, tty: "ttys009", cwd: nil)], canonicalCwd: "/p")
        guard case .finished(let o2) = unsure else { return XCTFail("\(unsure)") }
        XCTAssertFalse(o2.success)
    }

    func testPlanTypesIntoTheOwner() {
        let step = CodexInjector.plan(text: "hi", threadId: "t1", cwd: "/p", rolloutPath: ours, codexPath: "",
                                      allowExecResume: true, cwdFallback: .allowed,
                                      table: [], processes: npmPair(tty: "ttys001", childRollouts: [ours]), canonicalCwd: "/p")
        XCTAssertEqual(step, .type("hi", tty: "ttys001", pid: 11))
    }

    func testExecGateAllowsOneRunPerThread() {
        let gate = CodexExecResumeGate()
        XCTAssertEqual(gate.begin(threadId: "t1", interventionId: "a"), .started)
        XCTAssertTrue(gate.isThreadBusy("t1"))
        XCTAssertTrue(gate.isReplyInFlight("a"))
        XCTAssertEqual(gate.begin(threadId: "t1", interventionId: "a"), .duplicateReply)
        XCTAssertEqual(gate.begin(threadId: "t1", interventionId: "b"), .threadBusy)
        // Other threads don't wait.
        XCTAssertEqual(gate.begin(threadId: "t2", interventionId: "c"), .started)
        gate.end(threadId: "t1", interventionId: "a")
        XCTAssertFalse(gate.isThreadBusy("t1"))
        XCTAssertFalse(gate.isReplyInFlight("a"))
        XCTAssertEqual(gate.begin(threadId: "t1", interventionId: "b"), .started)
    }

    func testQueuedExecResumeOnlyStartsAfterTheTurn() {
        var s = CodexRollout.Summary()
        XCTAssertFalse(CodexBackend.execResumeMayStart(summary: s))  // unknown
        s.phase = .inTurn
        XCTAssertFalse(CodexBackend.execResumeMayStart(summary: s))
        s.phase = .completed
        XCTAssertTrue(CodexBackend.execResumeMayStart(summary: s))
        s.phase = .aborted
        XCTAssertTrue(CodexBackend.execResumeMayStart(summary: s))
    }

    // MARK: F9 — only an explicit end lets the pause message be typed

    func testPauseOnlyTrustsAnExplicitTurnEnd() {
        XCTAssertTrue(CodexBackend.pauseTurnEnded(.completed))
        XCTAssertTrue(CodexBackend.pauseTurnEnded(.aborted))
        XCTAssertFalse(CodexBackend.pauseTurnEnded(.inTurn))
        XCTAssertFalse(CodexBackend.pauseTurnEnded(.unknown))
    }

    // MARK: CONC-4 — bounded AppleScript, timeouts reported as such

    func testTerminalScriptsAreBoundedAndReraiseTimeouts() {
        let type = CodexInjector.terminalTypeScript(devTTY: "/dev/ttys004", text: "hello")
        let enter = CodexInjector.terminalEnterScript(devTTY: "/dev/ttys004")
        for script in [type, enter] {
            XCTAssertTrue(script.hasPrefix("with timeout of 10 seconds"), script)
            XCTAssertTrue(script.hasSuffix("end timeout"), script)
            XCTAssertTrue(script.contains("if errNum is -1712 then error errMsg number errNum"), script)
        }
        // The per-tab try and the tab check and System Events each re-raise.
        XCTAssertEqual(enter.components(separatedBy: "if errNum is -1712").count - 1, 2)
        XCTAssertTrue(type.contains("do script \"hello\" in targetTab"))
    }

    func testTimeoutIsNotReportedAsMissingPermission() {
        let timedOut = CodexInjector.terminalEnterOutcome(result: "", error: "-1712: AppleEvent timed out.", shortTTY: "ttys004")
        XCTAssertFalse(timedOut.success)
        XCTAssertTrue(timedOut.detail.contains("didn't respond"), timedOut.detail)
        XCTAssertFalse(timedOut.detail.contains("Accessibility"))

        let noPermission = CodexInjector.terminalEnterOutcome(result: "ok_no_enter -25211: not allowed", error: "", shortTTY: "ttys004")
        XCTAssertTrue(noPermission.detail.contains("Accessibility"))
        XCTAssertTrue(CodexInjector.terminalEnterOutcome(result: "ok", error: "", shortTTY: "ttys004").success)

        XCTAssertTrue(CodexInjector.appleScriptFailureDetail("-1712: AppleEvent timed out.").contains("didn't respond"))
        XCTAssertTrue(CodexInjector.appleScriptFailureDetail("-1743: not authorised").contains("Automation"))
    }

    // MARK: L6 — Page's own Return is recorded for presence checks

    func testSyntheticInputMarker() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("page-synth-\(UUID().uuidString)")
        let saved = SyntheticInput.directory
        SyntheticInput.directory = dir
        defer {
            SyntheticInput.directory = saved
            try? FileManager.default.removeItem(at: dir)
        }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        SyntheticInput.record(now: at)
        XCTAssertEqual(SyntheticInput.lastAt, at)
        let body = try String(contentsOf: dir.appendingPathComponent("synthetic-input"), encoding: .utf8)
        XCTAssertEqual(body, "1800000000\n")
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("synthetic-input").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)

        // Input 1 s after Page's keystroke, seen 30 s later: Page's.
        XCTAssertTrue(SyntheticInput.explainsIdleReset(idleSeconds: 29, now: at.addingTimeInterval(30)))
        // Input 20 s after it: the user's.
        XCTAssertFalse(SyntheticInput.explainsIdleReset(idleSeconds: 10, now: at.addingTimeInterval(30)))
    }
}
