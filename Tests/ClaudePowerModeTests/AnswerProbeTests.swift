#if DEBUG
import XCTest
@testable import ClaudePowerMode

/// The DEBUG-only `--probe-answer` tool's pure parts: its safety gate and argument parsing.
final class AnswerProbeTests: XCTestCase {
    private let root = AnswerProbe.allowedRoot

    func testOnlyCwdsStrictlyUnderTheProbeRootAreAllowed() {
        XCTAssertTrue(AnswerProbe.cwdAllowed(root + "/tmux"))
        XCTAssertTrue(AnswerProbe.cwdAllowed(root + "/iterm/deeper"))
        XCTAssertFalse(AnswerProbe.cwdAllowed(root), "the root itself is not a host dir")
        XCTAssertFalse(AnswerProbe.cwdAllowed(root + "-evil/tmux"), "a sibling sharing the prefix")
        XCTAssertFalse(AnswerProbe.cwdAllowed(root + "/../../.."), "dot-dot escapes")
        XCTAssertFalse(AnswerProbe.cwdAllowed(NSHomeDirectory()))
        XCTAssertFalse(AnswerProbe.cwdAllowed("/Users/roysinclair/projects/mac-on-claude-code"))
        XCTAssertFalse(AnswerProbe.cwdAllowed(nil))
        XCTAssertFalse(AnswerProbe.cwdAllowed(""))
        XCTAssertFalse(AnswerProbe.cwdAllowed("answer-probe/tmux"), "relative paths")
    }

    func testSymlinkedTmpSpellingIsTheSameFolder() {
        // /tmp is /private/tmp; both spellings of the probe root must be accepted, and a symlink out is not.
        if root.hasPrefix("/private/tmp/") {
            XCTAssertTrue(AnswerProbe.cwdAllowed(String(root.dropFirst("/private".count)) + "/tmux", root: root))
        }
        let scratch = NSTemporaryDirectory() + "probe-guard-\(UUID().uuidString)"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: scratch + "/root", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: scratch + "/outside", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: scratch) }
        try? fm.createSymbolicLink(atPath: scratch + "/root/link", withDestinationPath: scratch + "/outside")
        XCTAssertFalse(AnswerProbe.cwdAllowed(scratch + "/root/link", root: scratch + "/root"))
    }

    func testParseAnswerMode() throws {
        let args = ["x", "--probe-answer", "--session", "abc", "--answers", "[{\"i\":0,\"picks\":[1]}]",
                    "--caps", "plain", "--tmux-socket", "answerprobe", "--dry-run"]
        let o = try AnswerProbe.parse(args).get()
        XCTAssertEqual(o.sessionId, "abc")
        XCTAssertEqual(o.answersJSON, "[{\"i\":0,\"picks\":[1]}]")
        XCTAssertEqual(o.caps, .plain)
        XCTAssertEqual(o.tmuxSocket, "answerprobe")
        XCTAssertTrue(o.dryRun)
        XCTAssertFalse(o.screenOnly)
    }

    func testParseScreenModeAndErrors() throws {
        let o = try AnswerProbe.parse(["x", "--probe-screen", "--session", "abc"]).get()
        XCTAssertTrue(o.screenOnly)
        XCTAssertNil(o.caps)
        XCTAssertThrowsError(try AnswerProbe.parse(["x", "--probe-answer", "--answers", "[]"]).get(), "no session")
        XCTAssertThrowsError(try AnswerProbe.parse(["x", "--probe-answer", "--session", "a"]).get(), "no answers")
        XCTAssertThrowsError(try AnswerProbe.parse(["x", "--probe-answer", "--session", "a", "--answers", "[]", "--caps", "wild"]).get())
        XCTAssertThrowsError(try AnswerProbe.parse(["x", "--probe-answer", "--session", "a", "--answers", "[]", "--tmux-socket", "a/b"]).get())
        XCTAssertThrowsError(try AnswerProbe.parse(["x", "--probe-answer", "--probe-screen", "--session", "a"]).get())
        XCTAssertThrowsError(try AnswerProbe.parse(["x", "--probe-answer", "--session", "a", "--answers", "[]", "--bogus"]).get())
    }

    func testParseImageMode() throws {
        let a = ["ClaudePowerMode", "--probe-image", "--session", "s1", "--image", root + "/assets/red.png",
                 "--image", root + "/assets/blue.jpg", "--caption", "", "--attach", "paste", "--early-return", "--keep",
                 "--tmux-socket", "pageimgprobe"]
        let o = try AnswerProbe.parseImage(a).get()
        XCTAssertEqual(o.sessionId, "s1")
        XCTAssertEqual(o.images.count, 2)
        XCTAssertEqual(o.caption, "", "an empty caption is a caption")
        XCTAssertEqual(o.attach, .paste)
        XCTAssertTrue(o.earlyReturn)
        XCTAssertTrue(o.keep)
        XCTAssertEqual(o.tmuxSocket, "pageimgprobe")
        XCTAssertTrue(AnswerProbe.isRequested(a))
    }

    func testParseImageModeErrors() {
        func fails(_ extra: [String]) -> Bool {
            if case .failure = AnswerProbe.parseImage(["ClaudePowerMode", "--probe-image"] + extra) { return true }
            return false
        }
        XCTAssertTrue(fails(["--image", "/a.png"]), "--session is required")
        XCTAssertTrue(fails(["--session", "s1"]), "at least one --image")
        XCTAssertTrue(fails(["--session", "s1", "--image", "rel.png"]), "absolute image paths only")
        XCTAssertTrue(fails(["--session", "s1", "--image", "/a.png", "--attach", "maybe"]))
        XCTAssertTrue(fails(["--session", "s1", "--image", "/a.png", "--store", "/tmp/elsewhere"]), "the store stays under the probe root")
        XCTAssertTrue(fails(["--session", "s1", "--image", "/a.png", "--tmux-socket", "a b"]))
        XCTAssertTrue(fails(["--session", "s1"] + (0..<5).flatMap { ["--image", "/a\($0).png"] }), "4 images at most")
        XCTAssertTrue(fails(["--session", "s1", "--image", "/a.png", "--probe-answer"]))
        XCTAssertEqual(AnswerProbe.visibleEscapes("\u{1B}[39mx"), "␛[39mx")
    }

    func testCapsOverrideChangesOnlyTheGate() {
        let iterm = InjectionExecutor.TerminalHost.iTerm(tty: "/dev/ttys001")
        // Page's own gate refuses Terminal.app; --caps overrides it, and nothing else about the host.
        if case .success = AnswerProbe.caps(for: nil, host: .terminalApp(tty: "/dev/ttys001")) { XCTFail("Terminal.app must stay gated without --caps") }
        XCTAssertEqual(try? AnswerProbe.caps(for: nil, host: iterm).get(), .withArrows, "no --caps: Page's own gate")
        XCTAssertEqual(try? AnswerProbe.caps(for: .plain, host: iterm).get(), .plainKeysOnly)
        XCTAssertEqual(try? AnswerProbe.caps(for: .arrows, host: iterm).get(), AnswerKeyCaps(arrows: true))
        XCTAssertEqual(try? AnswerProbe.caps(for: .terminalReturn, host: .terminalApp(tty: "/dev/ttys001")).get(), .plainKeysOnly)
    }

    func testTranscriptAnswersReadsTheMatchingToolResult() {
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1"}]},"toolUseResult":{"answers":{"Q?":"A, B"}}}"#
        XCTAssertEqual(AnswerProbe.transcriptAnswers(transcript: "{\"type\":\"assistant\"}\n" + line + "\n", toolUseId: "toolu_1"), #"{"Q?":"A, B"}"#)
        XCTAssertNil(AnswerProbe.transcriptAnswers(transcript: line, toolUseId: "toolu_2"))
    }

    /// `--caps terminalReturn` (Terminal.app's `do script`, which adds a Return to every key) may press only
    /// the one shape measured on a stand-in; every other shape is refused before a key is sent.
    func testTerminalReturnPlansOnlyTheOneSingleSelectShape() {
        func set(_ questions: [(multi: Bool, labels: [String])]) -> AskedQuestionSet {
            AskedQuestionSet(toolUseId: "toolu_t", questions: questions.enumerated().map { i, q in
                AskedQuestion(question: "Q\(i)?", header: "H\(i)", multi: q.multi,
                              options: q.labels.map { AskedOption(label: $0, description: "") }, hasPreview: false)
            })
        }
        let single = set([(false, ["a", "b", "c"])])
        XCTAssertNil(AnswerProbe.terminalReturnRefusal(single, [AnswerPick(question: 0, picks: [1], other: nil)]), "the proven shape")

        let refused: [(String, AskedQuestionSet, [AnswerPick])] = [
            ("multi-select", set([(true, ["a", "b"])]), [AnswerPick(question: 0, picks: [0, 1], other: nil)]),
            ("single-select with Other", single, [AnswerPick(question: 0, picks: [], other: "Purple")]),
            ("multi-select with Other", set([(true, ["a", "b"])]), [AnswerPick(question: 0, picks: [0], other: "x")]),
            ("two questions", set([(false, ["a", "b"]), (false, ["c", "d"])]),
             [AnswerPick(question: 0, picks: [0], other: nil), AnswerPick(question: 1, picks: [1], other: nil)]),
            ("no pick", single, [AnswerPick(question: 0, picks: [], other: nil)]),
            ("two picks for one single-select", single, [AnswerPick(question: 0, picks: [0, 1], other: nil)]),
            ("pick for another question", single, [AnswerPick(question: 1, picks: [0], other: nil)]),
            ("no answers at all", single, []),
        ]
        for (name, asked, picks) in refused {
            XCTAssertNotNil(AnswerProbe.terminalReturnRefusal(asked, picks), name)
        }
    }

    func testIoCapabilitiesDefaultsToPagesOwnGate() {
        let io = AnswerDelivery.liveIO(registry: ClaudeSessionRegistry(projectsDirectory: "/nonexistent"))
        let host = InjectionExecutor.TerminalHost.terminalApp(tty: "/dev/ttys001")
        XCTAssertEqual(io.capabilities(host).failureMessage, AnswerDelivery.capabilities(of: host).failureMessage)
    }
}

private extension Swift.Result where Failure == AnswerPlanError {
    var failureMessage: String? { if case .failure(let e) = self { return e.message } else { return nil } }
}
#endif
