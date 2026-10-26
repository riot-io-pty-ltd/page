import XCTest
@testable import ClaudePowerMode

/// The rows of the Now popover: which keys each page offers (by trust class
/// and backend), where a page sits, how rows rank and how a row is named.
/// The one invariant that runs through all of it: nothing ever offers "2".
final class NowRowTests: XCTestCase {
    private let now = NightWatchFixtures.boardNow()

    private func ev(_ id: String, kind: InterventionKind = .permission, context: String, subtype: String? = nil,
                    backend: AgentBackendID = .claude, openedAgo: TimeInterval = 60,
                    reversibility: Reversibility.Verdict? = nil) -> InterventionEvent {
        InterventionEvent(id: id, sessionId: "sess-x", cwd: "/Users/roy/projects/x", projectName: "x", kind: kind,
                          openedAt: now.addingTimeInterval(-openedAgo), context: context, transcriptPath: "",
                          backend: backend, source: .terminal, subtype: subtype, reversibility: reversibility)
    }

    /// What the detector stores for a Bash call: the verdict of the structured
    /// command, with the description kept out of it (the display context is
    /// "[Bash] <command>\n<description>").
    private func bash(_ command: String, _ description: String) -> Reversibility.Verdict {
        Reversibility.classify(toolName: "Bash", input: ["command": command, "description": description],
                               cwd: "/Users/roy/projects/x")
    }

    private func row(_ e: InterventionEvent, blocker: String? = nil) -> DecideRow {
        NowModel.row(for: e, macName: "Studio MBP", route: "cmux › x", blocker: blocker)!
    }

    private var undoable: InterventionEvent {
        ev("u-1", context: "[Bash] swift test\nRun the tests", reversibility: bash("swift test", "Run the tests"))
    }
    private var irreversible: InterventionEvent { ev("i-1", context: "[Bash] rm -rf Builds/Dev/*.app\nDelete the dev builds") }
    private var considered: InterventionEvent { ev("c-1", context: "[Edit] Sources/Foo.swift\n- a\n+ b") }
    private var question: InterventionEvent { ev("q-1", kind: .question, context: "Which file should I change?") }
    private var looping: InterventionEvent {
        ev("l-1", kind: .idle, context: "Looks stuck in a loop: this has failed 6 times.\ncargo test", subtype: "looping")
    }

    // MARK: keys by trust class (Claude)

    func testUndoablePermissionReturnApproves() {
        let r = row(undoable)
        XCTAssertEqual(r.chip, .undoable)
        XCTAssertEqual(r.keys.map(\.label), ["↵", "esc"])
        XCTAssertEqual(r.returnAction, .approve)
        XCTAssertEqual(r.approvePreview, "Will type 1 · cmux › x · Studio MBP")
        XCTAssertEqual(r.denyPreview, "Will press Esc · cmux › x · Studio MBP")
        XCTAssertEqual(r.focusPreview, r.approvePreview)
    }

    func testConsideredPermissionOffersOneButNoReturn() {
        let r = row(considered)
        XCTAssertEqual(r.chip, .considered)
        XCTAssertEqual(r.keys.map(\.label), ["1", "esc"])
        XCTAssertNil(r.returnAction, "Return never approves a considered row")
    }

    func testIrreversiblePermissionIsHeldAndOpensOnReturn() {
        let r = row(irreversible)
        XCTAssertEqual(r.chip, .irreversible)
        XCTAssertEqual(r.keys.map(\.label), ["hold 1", "esc"])
        XCTAssertEqual(r.keys.first?.action, .approveHold)
        XCTAssertEqual(r.returnAction, .openTerminal)
        XCTAssertEqual(r.moreKeys.map(\.label), ["T", "O"])
    }

    func testClaudeQuestionOffersTellAndEsc() {
        let r = row(question)
        XCTAssertEqual(r.chip, .question)
        XCTAssertEqual(r.keys.map(\.label), ["T", "esc"])
        XCTAssertEqual(r.moreKeys.map(\.label), ["O"])
        XCTAssertNil(r.approvePreview, "a question has nothing to approve")
        XCTAssertEqual(r.denyPreview, "Will press Esc · cmux › x · Studio MBP")
        XCTAssertEqual(r.tellPreview, "Esc, then your message · cmux › x · Studio MBP")
        XCTAssertNil(r.returnAction)
    }

    func testStuckLoopOffersOpenAndTell() {
        let r = row(looping)
        XCTAssertEqual(r.section, .look)
        XCTAssertEqual(r.chip, .looksStuck)
        XCTAssertEqual(r.keys.map(\.label), ["O", "T"])
        XCTAssertNil(r.returnAction)
        XCTAssertEqual(r.tellPreview, "Your message, then Return · cmux › x · Studio MBP")
        XCTAssertNil(r.approvePreview)
    }

    func testFinishedTurnIsReviewWithOpenAndTell() {
        let r = row(ev("r-1", kind: .idle, context: "Done. All green."))
        XCTAssertEqual(r.section, .review)
        XCTAssertEqual(r.chip, .review)
        XCTAssertEqual(r.keys.map(\.label), ["O", "T"])
    }

    // MARK: keys by backend

    func testCodexPermissionIsOpenOnly() {
        let r = row(ev("cx-1", context: "[Bash] swift test\nRun the tests", backend: .codex))
        XCTAssertEqual(r.keys.map(\.label), ["O"])
        XCTAssertEqual(r.returnAction, .openTerminal)
        XCTAssertNil(r.tellPreview)
        XCTAssertTrue(r.approvePreview?.contains("Page can't approve") ?? false, r.approvePreview ?? "nil")
    }

    func testCodexQuestionIsOpenOnly() {
        let r = row(ev("cx-2", kind: .question, context: "Pick one", backend: .codex))
        XCTAssertEqual(r.keys.map(\.label), ["O"])
        XCTAssertNil(r.returnAction)
        XCTAssertNil(r.tellPreview)
    }

    func testCodexReviewIsOpenOnly() {
        let r = row(ev("cx-3", kind: .idle, context: "Done", backend: .codex))
        XCTAssertEqual(r.keys.map(\.label), ["O"])
    }

    // MARK: blocked terminals and the hook

    func testBlockedTerminalOffersOpenOnly() {
        let r = row(undoable, blocker: "Terminal.app can't take input")
        XCTAssertEqual(r.keys.map(\.label), ["O"])
        XCTAssertEqual(r.returnAction, .openTerminal)
        XCTAssertEqual(r.approvePreview, "Can't type here · Terminal.app can't take input")
        XCTAssertNil(r.denyPreview)
        XCTAssertNil(r.tellPreview)
        XCTAssertTrue(r.moreKeys.isEmpty)
    }

    func testHookOwnedPromptOffersOpenOnly() {
        let r = row(ev("hookpre-9", context: "[Bash] swift test\nRun the tests"))
        XCTAssertEqual(r.keys.map(\.label), ["O"])
        XCTAssertEqual(r.returnAction, .openTerminal)
        XCTAssertTrue(r.approvePreview?.contains("Page's hook is handling this prompt") ?? false, r.approvePreview ?? "nil")
    }

    func testForecastPagesOfferNoKeys() {
        let battery = row(ev("page-mac-battery_forecast-1", kind: .idle, context: "Battery forecast: 110 min to the cutoff."))
        let usage = row(ev("page-mac-usage_forecast-1", kind: .idle, context: "At this pace the 5-hour limit is near."))
        for r in [battery, usage] {
            XCTAssertEqual(r.section, .look)
            XCTAssertEqual(r.chip, .forecast)
            XCTAssertTrue(r.keys.isEmpty)
            XCTAssertTrue(r.moreKeys.isEmpty)
            XCTAssertNil(r.tellPreview)
        }
    }

    func testRateLimitIsNotARow() {
        XCTAssertNil(NowModel.row(for: ev("rl-1", kind: .rateLimit, context: "limit"), macName: "Mac", route: nil))
    }

    // MARK: sections

    func testSectionOfEachKind() {
        XCTAssertEqual(NowModel.section(of: ev("p", kind: .permission, context: "[Bash] ls")), .decide)
        XCTAssertEqual(NowModel.section(of: ev("pl", kind: .plan, context: "Plan ready for review")), .decide)
        XCTAssertEqual(NowModel.section(of: ev("q", kind: .question, context: "?")), .decide)
        for sub in ["looping", "stuck", "workflow_stalled"] {
            XCTAssertEqual(NowModel.section(of: ev("s-\(sub)", kind: .idle, context: "x", subtype: sub)), .look, sub)
        }
        XCTAssertEqual(NowModel.section(of: ev("page-mac-battery_forecast-2", kind: .idle, context: "x")), .look)
        XCTAssertEqual(NowModel.section(of: ev("idle", kind: .idle, context: "x")), .review)
        XCTAssertNil(NowModel.section(of: ev("rl", kind: .rateLimit, context: "x")))
    }

    // MARK: ranking

    func testRankingDecideIrreversibleThenConsideredThenUndoable() {
        let b = ev("b-irr", context: "[Bash] rm -rf x\nDelete", openedAgo: 10)
        let c = ev("c-cons", context: "[Edit] Sources/Foo.swift\n- a\n+ b", openedAgo: 300)
        let q = ev("q-question", kind: .question, context: "Which?", openedAgo: 200)
        let a = ev("a-undo", context: "[Bash] swift test\nRun", openedAgo: 100, reversibility: bash("swift test", "Run"))
        let l = ev("l-look", kind: .idle, context: "No progress for 15 min — it may be hung.", subtype: "stuck", openedAgo: 900)
        let r = ev("r-review", kind: .idle, context: "Done", openedAgo: 1000)
        let rows = [r, l, a, q, c, b].compactMap { NowModel.row(for: $0, macName: "Mac", route: nil) }
        XCTAssertEqual(NowModel.ranked(rows).map(\.id), ["b-irr", "c-cons", "q-question", "a-undo", "l-look", "r-review"])
    }

    func testRankingTiesGoToTheLongestWaitThenTheId() {
        let x = ev("zz", context: "[Bash] swift test\nRun", openedAgo: 50, reversibility: bash("swift test", "Run"))
        let y = ev("aa", context: "[Bash] swift test\nRun", openedAgo: 50, reversibility: bash("swift test", "Run"))
        let z = ev("mm", context: "[Bash] swift test\nRun", openedAgo: 500, reversibility: bash("swift test", "Run"))
        let rows = [x, y, z].compactMap { NowModel.row(for: $0, macName: "Mac", route: nil) }
        XCTAssertEqual(NowModel.ranked(rows).map(\.id), ["mm", "aa", "zz"])
    }

    func testBuildRanksTheRowsItReturns() {
        var i = NowInputs(snapshot: NightWatchFixtures.snapshot(pending: [undoable, irreversible, looping]),
                          now: now, macName: "Studio MBP", idleSeconds: 5)
        i.route = NightWatchFixtures.route
        let m = NowModel.build(i)
        XCTAssertEqual(m.rows.map(\.chip), [.irreversible, .undoable, .looksStuck])
        XCTAssertEqual(m.overflowRows, 0)
    }

    func testOverflowCountsRowsPastTheCompactList() {
        let pages = (0..<8).map { ev("p\($0)", context: "[Bash] swift test\nRun", openedAgo: Double(60 + $0)) }
        var i = NowInputs(snapshot: NightWatchFixtures.snapshot(pending: pages), now: now, macName: "Studio MBP", idleSeconds: 5)
        i.route = NightWatchFixtures.route
        let m = NowModel.build(i)
        XCTAssertEqual(m.rows.count, 8)
        XCTAssertEqual(NowModel.visibleRows, 3)
        XCTAssertEqual(m.overflowRows, 5)
    }

    func testChipTitlesAreAllCaps() {
        for chip in ChipKind.allCases {
            XCTAssertEqual(chip.title, chip.title.uppercased())
        }
        XCTAssertEqual(ChipKind(.irreversible).title, "IRREVERSIBLE")
        XCTAssertEqual(ChipKind(.considered).title, "CONSIDERED")
        XCTAssertEqual(ChipKind(.undoable).title, "UNDOABLE")
    }

    // MARK: naming a row

    func testSummaryStripsTheToolName() {
        XCTAssertEqual(NowModel.summaryLine(for: ev("s1", context: "[Bash] rm -rf x\ndesc")), "rm -rf x")
        XCTAssertEqual(NowModel.summaryLine(for: ev("s2", context: "[Edit] a.swift")), "edit a.swift")
        XCTAssertEqual(NowModel.summaryLine(for: ev("s3", context: "[Write] b.swift")), "write b.swift")
        XCTAssertEqual(NowModel.summaryLine(for: ev("s4", context: "[Read] c.swift")), "read c.swift")
    }

    func testLoopSummaryCountsTheFailures() {
        XCTAssertEqual(NowModel.summaryLine(for: looping), "cargo test failed 6×")
    }

    func testStuckSummaryDropsTheDash() {
        let e = ev("s5", kind: .idle, context: "No progress for 15 min — it may be hung.\n[Bash] cargo test", subtype: "stuck")
        XCTAssertEqual(NowModel.summaryLine(for: e), "no progress for 15 min")
    }

    func testMultiToolSummaryCountsCalls() {
        let two = ev("m2", context: "One of these is waiting for approval:\n• [Bash] ls\nList files\n• [Bash] rm x\nDelete")
        XCTAssertEqual(NowModel.summaryLine(for: two), "2 tool calls waiting")
        let three = ev("m3", context: "One of these is waiting for approval:\n• [Bash] ls\n• [Bash] rm x\n• [Bash] pwd")
        XCTAssertEqual(NowModel.summaryLine(for: three), "3 tool calls waiting")
    }

    func testPlanAndSubagentAndBareHookSummaries() {
        XCTAssertEqual(NowModel.summaryLine(for: ev("p1", kind: .plan, context: "Plan ready for review\n…")), "plan ready for review")
        XCTAssertEqual(NowModel.summaryLine(for: ev("p2", context: "A subagent is asking for approval\n[Task] x")), "task x")
        XCTAssertEqual(NowModel.summaryLine(for: ev("p3", context: "Claude is waiting for your approval")), "waiting for your approval")
        XCTAssertEqual(NowModel.summaryLine(for: ev("p4", context: "")), "waiting for you")
    }

    func testLongSummariesAreClippedWithAnEllipsis() {
        let long = "[Bash] " + String(repeating: "x", count: 120)
        let s = NowModel.summaryLine(for: ev("long", context: long))
        XCTAssertEqual(s.count, 96)
        XCTAssertTrue(s.hasSuffix("…"))
    }

    // MARK: no key ever sends "2"

    func testNoRowOffersTwoOrDontAskAgain() {
        let pages: [InterventionEvent] = [undoable, irreversible, considered, question, looping,
                                          ev("cx", context: "[Bash] ls", backend: .codex),
                                          ev("hookpre-2", context: "[Bash] ls"),
                                          ev("page-mac-battery_forecast-3", kind: .idle, context: "x")]
        var rows = pages.compactMap { NowModel.row(for: $0, macName: "Mac", route: nil) }
        rows += pages.compactMap { NowModel.row(for: $0, macName: "Mac", route: nil, blocker: "blocked") }
        for r in rows {
            for k in r.keys + r.moreKeys {
                XCTAssertNotEqual(k.label, "2", "row \(r.id)")
                XCTAssertFalse(k.label.lowercased().contains("always"), "row \(r.id)")
            }
            for text in [r.approvePreview, r.denyPreview, r.tellPreview].compactMap({ $0 }) {
                XCTAssertFalse(text.contains("'2'") || text.contains("“2”") || text.hasPrefix("2 ") || text.contains("don't ask"),
                               "row \(r.id): \(text)")
            }
        }
    }
}
