import XCTest
@testable import ClaudePowerMode

/// Reversibility is decided at detection time from the structured tool call
/// (tool name and the full input), not from the page's display text, which is
/// redacted, clipped and carries Claude's description as a second line. The
/// context-based classifier stays as a conservative fallback.
final class StructuredReversibilityTests: XCTestCase {
    typealias F = TranscriptFixture
    private let cwd = "/Users/me/proj"

    private func bash(_ command: String, description: String? = nil) -> Reversibility.Verdict {
        var input: [String: Any] = ["command": command]
        if let description { input["description"] = description }
        return Reversibility.classify(toolName: "Bash", input: input, cwd: cwd)
    }

    // MARK: Bash from the command only

    func testADescriptionNeverMakesARoutineCommandConsidered() {
        XCTAssertEqual(bash("ls", description: "List the files").level, .undoable)
        XCTAssertEqual(bash("git status", description: "Show the working tree").level, .undoable)
        XCTAssertEqual(bash("swift test --filter Stuck", description: "Run the Stuck tests").level, .undoable)
        XCTAssertEqual(bash("ls", description: nil).level, .undoable)
    }

    func testTheDescriptionIsNotJudgedAsCommandText() {
        // Whatever the description says, only the command runs.
        XCTAssertEqual(bash("ls", description: "Find . -delete").level, .undoable)
        XCTAssertEqual(bash("ls", description: "rm -rf /").level, .undoable)
        XCTAssertEqual(bash("ls", description: "Mycli wipe").level, .undoable)
    }

    func testTheCommandIsJudgedInFullEvenWhenALaterLineIsDangerous() {
        XCTAssertEqual(bash("git status\nrm -rf foo", description: "Show status").level, .irreversible)
        XCTAssertEqual(bash("rm -rf Builds/Dev/*.app", description: "List the builds").level, .irreversible)
        XCTAssertEqual(bash("ls\npwd", description: "Look around").level, .undoable, "two harmless lines are still harmless")
        XCTAssertEqual(bash("ls\nmycli wipe", description: "x").level, .considered)
    }

    func testAMissingOrEmptyCommandIsConsidered() {
        XCTAssertEqual(Reversibility.classify(toolName: "Bash", input: [:], cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(toolName: "Bash", input: ["command": "  \n"], cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(toolName: "Bash", input: ["command": 42], cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(toolName: "Bash", input: ["description": "ls"], cwd: cwd).level, .considered)
    }

    func testRunningOutsideTheSandboxIsNeverUndoable() {
        let v = Reversibility.classify(toolName: "Bash", input: ["command": "ls", "dangerouslyDisableSandbox": true], cwd: cwd)
        XCTAssertEqual(v.level, .considered)
        let off = Reversibility.classify(toolName: "Bash", input: ["command": "ls", "dangerouslyDisableSandbox": false], cwd: cwd)
        XCTAssertEqual(off.level, .undoable)
    }

    // MARK: other tools from their fields

    func testFileToolsFromTheirFields() {
        func level(_ name: String, _ input: [String: Any]) -> Reversibility {
            Reversibility.classify(toolName: name, input: input, cwd: cwd).level
        }
        XCTAssertEqual(level("Read", ["file_path": "/Users/me/proj/a.swift"]), .undoable)
        XCTAssertEqual(level("Read", ["file_path": "Sources/a.swift"]), .undoable)
        XCTAssertEqual(level("Read", ["file_path": "/Users/me/.ssh/id_rsa"]), .considered)
        XCTAssertEqual(level("Read", ["file_path": "/Users/me/proj/../.ssh/id_rsa"]), .considered)
        XCTAssertEqual(level("Read", [:]), .considered)
        XCTAssertEqual(level("Grep", ["pattern": "x"]), .undoable)
        XCTAssertEqual(level("Glob", ["pattern": "*.swift"]), .undoable)
        for edit in ["Edit", "Write", "MultiEdit"] {
            XCTAssertEqual(level(edit, ["file_path": "/Users/me/proj/a.swift"]), .considered, edit)
            XCTAssertEqual(Reversibility.classify(toolName: edit, input: ["file_path": "/Users/me/proj/a.swift"], cwd: cwd).tags, [.editsInRepo])
            XCTAssertEqual(Reversibility.classify(toolName: edit, input: ["file_path": "/etc/hosts"], cwd: cwd).tags, [.networkOutside])
        }
        XCTAssertEqual(Reversibility.classify(toolName: "NotebookEdit", input: ["notebook_path": "n.ipynb"], cwd: cwd).tags, [.editsInRepo])
        XCTAssertEqual(Reversibility.classify(toolName: "NotebookEdit", input: ["notebook_path": "/tmp/n.ipynb"], cwd: cwd).tags, [.networkOutside])
    }

    func testNetworkSubagentAndUnknownToolsAreConsidered() {
        for name in ["WebFetch", "WebSearch", "Task", "Agent", "ExitPlanMode", "mcp__x__do", "TodoWrite"] {
            XCTAssertEqual(Reversibility.classify(toolName: name, input: [:], cwd: cwd).level, .considered, name)
        }
    }

    func testSeveralCallsTakeTheWorst() {
        let v = Reversibility.classify(calls: [("Bash", ["command": "ls"]), ("Bash", ["command": "rm -rf x"]),
                                               ("Read", ["file_path": "a"])], cwd: cwd)
        XCTAssertEqual(v?.level, .irreversible)
        let mild = Reversibility.classify(calls: [("Bash", ["command": "ls"]), ("Edit", ["file_path": "a"])], cwd: cwd)
        XCTAssertEqual(mild?.level, .considered)
        XCTAssertNil(Reversibility.classify(calls: [], cwd: cwd))
    }

    func testClassifierFieldsKeepOnlyWhatTheClassifierReads() {
        let fields = Reversibility.classifierFields(toolName: "Write", input: [
            "file_path": "/a", "content": String(repeating: "x", count: 100_000), "command": "c", "dangerouslyDisableSandbox": true,
            "notebook_path": "/n", "description": "d", "timeout": 5])
        XCTAssertEqual(fields, ["file_path": "/a", "command": "c", "dangerouslyDisableSandbox": "true", "notebook_path": "/n"])
        // The snapshot classifies the same as the original input.
        XCTAssertEqual(Reversibility.classify(toolName: "Bash", input: Reversibility.classifierFields(
            toolName: "Bash", input: ["command": "ls", "dangerouslyDisableSandbox": true]), cwd: cwd).level, .considered)
    }

    // MARK: make and cdk

    func testMakeDryRunsAndQuestionRunsAreConsidered() {
        for command in ["make -n deploy", "make --dry-run deploy", "make --just-print deploy", "make --recon deploy",
                        "make -q deploy", "make --question deploy", "make -n test", "make -nk test", "gmake -n all"] {
            XCTAssertEqual(bash(command).level, .considered, command)
            XCTAssertEqual(Reversibility.classify(context: "[Bash] \(command)", cwd: cwd).level, .considered, command)
        }
        // A plain test target is still routine.
        XCTAssertEqual(bash("make test").level, .undoable)
        XCTAssertEqual(bash("make -j4 check").level, .undoable)
    }

    func testCdkDiffAndSynthRunTheAppSoTheyAreConsidered() {
        for command in ["cdk diff", "cdk synth", "cdk synthesize", "cdk ls", "cdk list", "cdk diff MyStack",
                        "cdk --app 'node bin/x.js' diff", "cdk diff --profile p"] {
            XCTAssertEqual(bash(command).level, .considered, command)
            XCTAssertEqual(Reversibility.classify(context: "[Bash] \(command)", cwd: cwd).level, .considered, command)
        }
        XCTAssertEqual(bash("cdk deploy").level, .irreversible)
        XCTAssertEqual(bash("cdk destroy").level, .irreversible)
        XCTAssertEqual(bash("cdk --version").level, .undoable)
        // Other infra queries are unchanged.
        XCTAssertEqual(bash("kubectl get pods").level, .undoable)
        XCTAssertEqual(bash("terraform plan").level, .considered)
    }

    // MARK: the fallback on display text

    func testFallbackNeverCallsADescribedBashUndoable() {
        // "[Bash] <command>\n<description>": the two cannot be told apart in text.
        XCTAssertEqual(Reversibility.classify(context: "[Bash] ls\nList the files", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "[Bash] swift test\nRun", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "[Bash] ls\nFind . -delete", cwd: cwd).level, .irreversible)
        XCTAssertEqual(Reversibility.classify(context: "[Bash] ls", cwd: cwd).level, .undoable, "a lone line is what it says")
    }

    func testFallbackNeverCallsAClippedContextUndoable() {
        let clipped = InterventionDetector.clip("[Bash] ls " + String(repeating: "a", count: 2000) + "; rm -rf x", InterventionDetector.contextLimit)
        XCTAssertTrue(clipped.hasSuffix("…"))
        XCTAssertEqual(Reversibility.classify(context: clipped, cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "[Bash] ls …", cwd: cwd).level, .considered)
        // At the length limit even without the marker.
        let full = "[Bash] ls " + String(repeating: " ", count: 5) + String(repeating: "a", count: InterventionDetector.contextLimit)
        XCTAssertEqual(Reversibility.classify(context: full, cwd: cwd).level, .considered)
        // A parallel-call page whose last entry was clipped.
        let multi = "One of these is waiting for approval:\n• [Bash] ls\n• [Bash] ls " + String(repeating: "b", count: 200) + "…"
        XCTAssertEqual(Reversibility.classify(context: multi, cwd: cwd).level, .considered)
    }

    func testFallbackNeverCallsARedactedContextUndoable() {
        // A mask can swallow the clip marker: TOKEN=abcdef… becomes TOKEN=[redacted].
        let shown = ContextRedactor.redact("[Bash] ls API_TOKEN=abcdefghijkl…")
        XCTAssertTrue(shown.contains("[redacted"))
        XCTAssertFalse(shown.hasSuffix("…"))
        XCTAssertEqual(Reversibility.classify(context: shown, cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "[Bash] cat key.pem [redacted private key]", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "One of these is waiting for approval:\n• [Bash] ls\n• [Bash] echo Bearer [redacted]", cwd: cwd).level, .considered)
    }

    func testFallbackKeepsReadsAndOtherPagesAsBefore() {
        XCTAssertEqual(Reversibility.classify(context: "[Read] Sources/a.swift", cwd: cwd).level, .undoable)
        XCTAssertEqual(Reversibility.classify(context: "[Edit] Sources/a.swift\n- a\n+ b", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "Claude is waiting for your approval", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "[Bash] rm -rf x\nDelete", cwd: cwd).level, .irreversible)
    }

    func testHookFormattedPagesNeverReadAsUndoable() {
        // hooks/page-notify.sh writes "$ " + the command clipped at 1200 characters
        // with "…", then "\n# " + the description. Only the "$ " line is judged and
        // the text is never undoable; a visibly irreversible command is irreversible.
        let clipped = "$ ls " + String(repeating: "a", count: 1195) + "…\n# List"
        XCTAssertEqual(Reversibility.classify(context: clipped, cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "$ ls\n# List", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "$ rm -rf build\n# Clean", cwd: cwd).level, .irreversible)
    }

    func testHookPageDescriptionsNeverDecideTheVerdict() {
        // The "# " line is what the model says the command does. A frightening description
        // does not make a harmless command dangerous (it stays considered, never undoable), and
        // a benign one does not make a dangerous command safe.
        XCTAssertEqual(Reversibility.classify(context: "$ ls\n# rm -rf /", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "$ ls\n# Mycli wipe", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "$ rm -rf x\n# List", cwd: cwd).level, .irreversible)
        XCTAssertEqual(Reversibility.classify(context: "$ rm -rf x\n# Delete build output", cwd: cwd).level, .irreversible)
        XCTAssertEqual(Reversibility.classify(context: "$ git push --force origin main\n# push", cwd: cwd).level, .irreversible)
        XCTAssertEqual(Reversibility.classify(context: "$ terraform apply\n# a", cwd: cwd).level, .irreversible)
        XCTAssertEqual(Reversibility.classify(context: "$ swift test\n# Run tests", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "$ ls", cwd: cwd).level, .considered, "a lone command line is still a page's text")
    }

    func testHookPagesWithMoreThanOneCommandLineAreConsidered() {
        // The description and the activity tail are not command lines.
        let desc = Reversibility.classify(context: "$ ls\n# a\n# b", cwd: cwd)
        XCTAssertEqual(desc.level, .considered)
        XCTAssertEqual(desc.reason, "a hook page's command isn't confirmed")
        // A command that spans lines is judged whole, and is never undoable.
        let many = Reversibility.classify(context: "$ ls\nls -la\n# a", cwd: cwd)
        XCTAssertEqual(many.level, .considered)
        XCTAssertTrue(many.reason.contains("more than one line"), many.reason)
        XCTAssertEqual(Reversibility.classify(context: "$ echo hi\nrm -rf ~", cwd: cwd).level, .irreversible)
        XCTAssertEqual(Reversibility.classify(context: "$ ls\n$ rm -rf ~\n# x", cwd: cwd).level, .irreversible)
        XCTAssertEqual(Reversibility.classify(context: "$ ls\r\nrm -rf ~\r\n# x", cwd: cwd).level, .irreversible)
        // A recent-activity tail after the description: still a page, still considered, never read as commands.
        XCTAssertEqual(Reversibility.classify(context: "$ ls\n# List\n\n— recent activity —\n[Bash] ls", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "$ ls\n# List\n\n— recent activity —\n[Bash] rm -rf x", cwd: cwd).level, .considered)
        // A long tail does not make a complete command "cut short".
        let tail = "$ ls\n# List\n\n— recent activity —\n" + String(repeating: "x", count: 1500)
        XCTAssertEqual(Reversibility.classify(context: tail, cwd: cwd).reason, "a hook page's command isn't confirmed")
        // Only the description line ends the command: a line after a "# " line is not judged.
        XCTAssertNotEqual(Reversibility.classify(context: "$ ls\n# Delete\nrm -rf x", cwd: cwd).level, .undoable)
    }

    func testNoHookTextIsEverUndoable() {
        let commands = ["ls", "swift test", "git status", "cat README.md", "pwd", "rm -rf build", "echo hi", "(no command)", "",
                        "ls " + String(repeating: "a", count: 1195) + "…", "ls [redacted]", "ls \\\n-la", "git diff"]
        let descriptions = ["", "# List", "# rm -rf /", "# a\n# b", "# List\n\n— recent activity —\n[Bash] ls\n" + String(repeating: "t", count: 1500)]
        let seps = ["\n", "\r\n", "\n$ ", "\r\n$ ", "\n\n", "\r"]
        let prefixes = ["$ ", "$ \n", "$  ", "  $ ", "\n$ ", "$\t", "＄ ", "# $ ", "#\n$ ", "\u{2028}$ ", "\u{85}$ "]
        var texts: [String] = []
        for p in prefixes { for c in commands { for d in descriptions { for sep in seps {
            texts.append(p + c + (d.isEmpty ? "" : sep + d))
        } } } }
        texts += ["$ ls\n$ ls\n$ ls", "$ ls\r\n$ pwd", "$ " + String(repeating: "ls; ", count: 400), "[redacted", "$ [redacted]", "$ ls\u{2029}pwd"]
        XCTAssertGreaterThan(texts.count, 200)
        for t in texts {
            XCTAssertNotEqual(Reversibility.classify(context: t, cwd: cwd).level, .undoable, t)
        }
    }

    func testHookPageCommandsThatAreClippedHiddenOrLongAreConsidered() {
        let cut = Reversibility.classify(context: "$ ls …\n# x", cwd: cwd)
        XCTAssertEqual(cut.level, .considered)
        XCTAssertEqual(cut.reason, "the command was cut short")
        let clipped = "$ ls " + String(repeating: "a", count: 1195) + "…\n# List"
        XCTAssertEqual(Reversibility.classify(context: clipped, cwd: cwd).level, .considered)
        // At the length limit with no visible marker: the command may run past what is shown.
        let full = "$ ls" + String(repeating: " ", count: InterventionDetector.contextLimit) + "\n# List"
        let longVerdict = Reversibility.classify(context: full, cwd: cwd)
        XCTAssertEqual(longVerdict.level, .considered)
        XCTAssertEqual(longVerdict.reason, "the command was cut short")
        let hidden = Reversibility.classify(context: "$ ls [redacted]\n# x", cwd: cwd)
        XCTAssertEqual(hidden.level, .considered)
        XCTAssertEqual(hidden.reason, "part of the command was hidden")
        // A clipped command that is irreversible on what is visible stays irreversible.
        XCTAssertEqual(Reversibility.classify(context: "$ rm -rf build …\n# x", cwd: cwd).level, .irreversible)
    }

    func testHookPagesWithoutACommandAreConsidered() {
        XCTAssertEqual(Reversibility.classify(context: "$ \n# List", cwd: cwd).level, .considered)
        XCTAssertEqual(Reversibility.classify(context: "$ (no command)\n# List", cwd: cwd).level, .considered)
    }

    func testTofuPulumiAndTerraformPlansAreConsideredThroughTheCall() {
        XCTAssertEqual(bash("tofu validate").level, .considered)
        XCTAssertEqual(bash("pulumi preview", description: "Preview the stack").level, .considered)
        XCTAssertEqual(bash("terraform plan -destroy").level, .considered)
        XCTAssertEqual(bash("terraform version").level, .undoable)
        XCTAssertEqual(bash("pulumi whoami").level, .undoable)
    }

    // MARK: detection: the verdict comes from the call, and sits on the event

    private func tools(_ lines: [String]) -> [PendingToolUse] {
        InterventionDetector.parseTranscriptTail(lines.joined(separator: "\n")).pendingToolUses
    }

    func testParsedToolCallsKeepTheirClassifierFields() {
        let t = tools([F.toolUse("a", "Bash", ["command": "ls", "description": "List"])])
        XCTAssertEqual(t.first?.fields, ["command": "ls"])
        XCTAssertEqual(t.first?.summary, "[Bash] ls\nList")
    }

    func testDetectorVerdictIgnoresTheDescriptionAndTheClip() {
        let routine = tools([F.toolUse("a", "Bash", ["command": "swift test --filter Stuck", "description": "Run the Stuck tests"])])
        XCTAssertEqual(InterventionDetector.reversibility(of: routine, cwd: cwd)?.level, .undoable)

        // A command longer than the page limit with the danger past the cut: the
        // display text is clipped, the call is judged whole.
        let long = "ls " + String(repeating: "a", count: 3000) + "; rm -rf x"
        let hidden = tools([F.toolUse("b", "Bash", ["command": long, "description": "List"])])
        XCTAssertEqual(InterventionDetector.reversibility(of: hidden, cwd: cwd)?.level, .irreversible)
        XCTAssertTrue(hidden[0].summary.hasSuffix("…"))
        XCTAssertFalse(hidden[0].summary.contains("rm -rf"))

        // A long but harmless command is judged for what it is.
        let longHarmless = tools([F.toolUse("c", "Bash", ["command": "ls " + String(repeating: "a", count: 3000)])])
        XCTAssertEqual(InterventionDetector.reversibility(of: longHarmless, cwd: cwd)?.level, .undoable)
    }

    func testACommandFarPastTheDisplayClipIsJudgedWhole() {
        let harmless = "ls " + String(repeating: "a", count: 5000)
        XCTAssertEqual(bash(harmless).level, .undoable)
        XCTAssertEqual(bash(harmless + "; rm -rf ~").level, .irreversible)

        let t = tools([F.toolUse("a", "Bash", ["command": harmless + "; rm -rf ~", "description": "List"])])
        XCTAssertEqual(InterventionDetector.reversibility(of: t, cwd: cwd)?.level, .irreversible)
        XCTAssertTrue(t[0].summary.hasSuffix("…"), "the display text is clipped")
        XCTAssertFalse(t[0].summary.contains("rm -rf"), "the danger is only in the call")
    }

    func testDetectorVerdictSeesTheCommandThatRedactionMasked() {
        let masked = tools([F.toolUse("a", "Bash", ["command": "rm -rf build API_KEY=abcdefghijklmnop"])])
        XCTAssertTrue(masked[0].summary.contains("[redacted]"))
        XCTAssertEqual(InterventionDetector.reversibility(of: masked, cwd: cwd)?.level, .irreversible)
        let harmless = tools([F.toolUse("b", "Bash", ["command": "ls API_KEY=abcdefghijklmnop"])])
        XCTAssertEqual(InterventionDetector.reversibility(of: harmless, cwd: cwd)?.level, .undoable)
    }

    func testDetectorVerdictOfParallelCallsIsTheWorst() {
        let t = tools([F.toolUse("a", "Bash", ["command": "ls"]), F.toolUse("b", "Bash", ["command": "git push --force"])])
        XCTAssertEqual(InterventionDetector.reversibility(of: t, cwd: cwd)?.level, .irreversible)
    }

    func testDetectorVerdictIsNilWithoutACallOrItsInput() {
        XCTAssertNil(InterventionDetector.reversibility(of: [], cwd: cwd))
        XCTAssertNil(InterventionDetector.reversibility(of: [PendingToolUse(id: "t", name: "Bash", summary: "[Bash] ls")], cwd: cwd))
    }

    func testAStatusLessGuessIsNeverBetterThanConsidered() {
        let t = tools([F.toolUse("a", "Bash", ["command": "ls"])])
        XCTAssertEqual(InterventionDetector.reversibility(of: t, cwd: cwd, possibly: true)?.level, .considered)
        let bad = tools([F.toolUse("a", "Bash", ["command": "rm -rf x"])])
        XCTAssertEqual(InterventionDetector.reversibility(of: bad, cwd: cwd, possibly: true)?.level, .irreversible)
    }

    func testTheStoredReasonIsRedacted() {
        let t = tools([F.toolUse("a", "Bash", ["command": "git --api-key=abcdefghijklmnop status"])])
        // The classifier quotes the unknown option in its reason; the stored copy is masked.
        XCTAssertTrue(Reversibility.classify(toolName: "Bash", input: ["command": "git --api-key=abcdefghijklmnop status"], cwd: cwd)
            .reason.contains("abcdefghijklmnop"))
        let v = InterventionDetector.reversibility(of: t, cwd: cwd)
        XCTAssertNotNil(v)
        XCTAssertFalse(v?.reason.contains("abcdefghijklmnop") ?? true)
        XCTAssertTrue(v?.reason.contains("[redacted]") ?? false)
    }

    // MARK: scan: the event carries the verdict

    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("rev-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
    }

    private func scanWaiting(_ lines: [String]) throws -> InterventionEvent {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        let det = InterventionDetector(hookHoldsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("rev-holds-\(UUID().uuidString)"), isForeground: { _ in true })
        let session = ClaudeLiveSession(pid: 4242, sessionId: "455cd6af-046c-4468-9d9b-5de46c4d8194", cwd: cwd, status: .waiting,
                                        statusUpdatedAt: Date().addingTimeInterval(-30), tty: "ttys009", hasSessionFile: true)
        let r = det.scan(sessions: [session], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        return try XCTUnwrap(r.opened.first)
    }

    func testAScannedApprovalCarriesTheStructuredVerdictAndReturnApprovesIt() throws {
        let e = try scanWaiting([F.user("go"), F.toolUse("t1", "Bash", ["command": "ls", "description": "List the files"])])
        XCTAssertEqual(e.context, "[Bash] ls\nList the files")
        XCTAssertEqual(e.reversibility?.level, .undoable)
        let row = try XCTUnwrap(NowModel.row(for: e, macName: "Mac", route: nil))
        XCTAssertEqual(row.chip, .undoable)
        XCTAssertEqual(row.returnAction, .approve, "a described read-only command keeps Return-approve")
        XCTAssertEqual(row.keys.map(\.label), ["↵", "esc"])
    }

    func testAScannedDangerousApprovalIsHeld() throws {
        let e = try scanWaiting([F.user("go"), F.toolUse("t1", "Bash", ["command": "git push --force origin main", "description": "Push"])])
        XCTAssertEqual(e.reversibility?.level, .irreversible)
        let row = try XCTUnwrap(NowModel.row(for: e, macName: "Mac", route: nil))
        XCTAssertEqual(row.chip, .irreversible)
        XCTAssertEqual(row.keys.map(\.label), ["hold 1", "esc"])
        XCTAssertEqual(row.returnAction, .openTerminal)
    }

    func testAScannedEditAndAQuestionAndABareWaitCarryTheRightVerdict() throws {
        let edit = try scanWaiting([F.user("go"), F.toolUse("t1", "Edit", ["file_path": "Sources/a.swift", "old_string": "a", "new_string": "b"])])
        XCTAssertEqual(edit.reversibility?.level, .considered)
        XCTAssertEqual(edit.reversibility?.tags, [.editsInRepo])

        let question = try scanWaiting([F.user("go"), F.toolUse("t1", "AskUserQuestion", ["questions": [["question": "Which?", "options": []]]])])
        XCTAssertNil(question.reversibility, "questions have no class")
    }

    func testNoToolCallMeansNoStoredVerdict() throws {
        // Status says waiting but the call has not reached the transcript yet.
        try Data((F.user("go") + "\n").utf8).write(to: url)
        let det = InterventionDetector(hookHoldsDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("rev-holds-\(UUID().uuidString)"), isForeground: { _ in true })
        let session = ClaudeLiveSession(pid: 4243, sessionId: "455cd6af-046c-4468-9d9b-5de46c4d8195", cwd: cwd, status: .waiting,
                                        statusUpdatedAt: Date().addingTimeInterval(-30), tty: "ttys009", hasSessionFile: true)
        let r = det.scan(sessions: [session], transcriptFor: { _ in self.url }, settings: DetectorSettings())
        let e = try XCTUnwrap(r.opened.first)
        XCTAssertEqual(e.context, "Claude is waiting for your approval")
        XCTAssertNil(e.reversibility)
        XCTAssertEqual(NowModel.row(for: e, macName: "Mac", route: nil)?.chip, .considered, "falls back to the text: considered")
    }

    // MARK: NowModel: stored verdict first, text only without one

    private func event(context: String, verdict: Reversibility.Verdict?) -> InterventionEvent {
        InterventionEvent(id: "x-1", sessionId: "s", cwd: cwd, projectName: "p", kind: .permission,
                          openedAt: Date(timeIntervalSince1970: 1_761_300_000), context: context, transcriptPath: "",
                          reversibility: verdict)
    }

    func testNowModelPrefersTheStoredVerdict() {
        let undoable = Reversibility.classify(toolName: "Bash", input: ["command": "ls"], cwd: cwd)
        // The text alone would be considered; the stored verdict wins.
        let a = event(context: "[Bash] ls\nList the files", verdict: undoable)
        XCTAssertEqual(NowModel.row(for: a, macName: "Mac", route: nil)?.chip, .undoable)
        // And a stricter stored verdict wins over a benign-looking text.
        let strict = Reversibility.classify(toolName: "Bash", input: ["command": "git push -f"], cwd: cwd)
        let b = event(context: "[Bash] ls", verdict: strict)
        XCTAssertEqual(NowModel.row(for: b, macName: "Mac", route: nil)?.chip, .irreversible)
    }

    func testNowModelFallsBackToTheTextOnlyWithoutAVerdict() {
        XCTAssertEqual(NowModel.row(for: event(context: "[Bash] ls", verdict: nil), macName: "Mac", route: nil)?.chip, .undoable)
        for context in ["[Bash] ls\nList the files", "[Bash] ls …", "[Bash] ls API_KEY=[redacted]",
                        "[Bash] ls " + String(repeating: "a", count: 1600)] {
            XCTAssertEqual(NowModel.row(for: event(context: context, verdict: nil), macName: "Mac", route: nil)?.chip, .considered, context)
        }
    }

    func testHookOwnedPagesWithoutAStoredVerdictAreOpenOnly() {
        // hooks/page-notify.sh posts hookpre- pages itself, so Swift never sets a
        // verdict on them. Even a text that reads as undoable must not offer Return.
        func hookPage(_ context: String) -> InterventionEvent {
            InterventionEvent(id: "hookpre-1761300000-abcd", sessionId: "s", cwd: cwd, projectName: "p", kind: .permission,
                              openedAt: Date(timeIntervalSince1970: 1_761_300_000), context: context, transcriptPath: "")
        }
        for context in ["[Bash] ls", "[Bash] ls\nList the files", "[Bash] rm -rf build"] {
            let row = NowModel.row(for: hookPage(context), macName: "Mac", route: nil)
            XCTAssertEqual(row?.keys.map(\.label), ["O"], context)
            XCTAssertEqual(row?.returnAction, .openTerminal, context)
        }
    }

    // MARK: Mac-local, never on the wire, old events still decode

    func testTheVerdictIsNotOnTheWire() {
        let e = event(context: "[Bash] ls", verdict: Reversibility.classify(toolName: "Bash", input: ["command": "ls"], cwd: cwd))
        let payload = RelayClient.interventionOpenedPayload(e)
        XCTAssertEqual(Set(payload.keys), ["id", "sessionId", "cwd", "projectName", "kind", "context", "openedAt", "backend", "source"])
        XCTAssertFalse(String(describing: payload).contains("Read-only"))
    }

    func testTheVerdictRoundTripsAndOlderEventsDecodeWithoutIt() throws {
        let verdict = Reversibility.classify(toolName: "Bash", input: ["command": "git push -f"], cwd: cwd)
        let withVerdict = event(context: "[Bash] ls", verdict: verdict)
        let data = try JSONEncoder().encode(withVerdict)
        XCTAssertEqual(try JSONDecoder().decode(InterventionEvent.self, from: data), withVerdict)

        // A persisted event from before the field existed has no such key.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["reversibility"])
        object.removeValue(forKey: "reversibility")
        let old = try JSONDecoder().decode(InterventionEvent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.reversibility)
        XCTAssertEqual(old.context, withVerdict.context)

        let plain = try JSONEncoder().encode(event(context: "x", verdict: nil))
        XCTAssertNil(try JSONDecoder().decode(InterventionEvent.self, from: plain).reversibility)
    }
}
