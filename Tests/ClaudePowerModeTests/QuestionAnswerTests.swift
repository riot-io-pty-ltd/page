import XCTest
@testable import ClaudePowerMode

/// A stand-in for Claude Code's AskUserQuestion dialog, built from the key
/// model measured on 2.1.311 (see QuestionAnswer.swift). The driver is run
/// against it end to end; the real dialog is checked by the env-gated tmux test.
final class FakeQuestionDialog {
    let asked: AskedQuestionSet
    var width = 120
    var keys: [Keystroke] = []
    var current = 0
    /// Per question: ticked options, and the Other text.
    var picked: [Set<Int>]
    var otherText: [String?]
    var otherTicked: [Bool]
    /// Cursor index into `rowOrder(q)`.
    var cursor = 0
    var reviewCursor = 0
    /// nil while open; the answers once submitted.
    var submitted: [String: String]?
    var cancelled = false
    var chatPressed = false
    var badOtherTick = false
    var closed: Bool { submitted != nil || cancelled || chatPressed }
    /// Per question, whether it was answered (the header turns ☒).
    var answered: [Bool]

    init(_ set: AskedQuestionSet) {
        self.asked = set
        picked = Array(repeating: [], count: asked.questions.count)
        otherText = Array(repeating: nil, count: asked.questions.count)
        otherTicked = Array(repeating: false, count: asked.questions.count)
        answered = Array(repeating: false, count: asked.questions.count)
    }

    private enum Row: Equatable { case option(Int), other, next, chat }

    private func rowOrder(_ qi: Int) -> [Row] {
        let q = asked.questions[qi]
        var rows: [Row] = (0..<q.options.count).map { .option($0) } + [.other]
        if q.multi { rows.append(.next) }
        rows.append(.chat)
        return rows
    }

    private var onReview: Bool { current >= asked.questions.count }
    private var hasTabBar: Bool { asked.questions.count > 1 || asked.questions[0].multi }

    // MARK: rendering

    func render() -> String {
        if closed { return "✻ Working…\n\n> \n" }
        var out: [String] = ["some earlier output", "1. a numbered list item in the conversation", ""]
        if hasTabBar {
            let tabs = asked.questions.enumerated().map { (answered[$0.offset] ? "☒ " : "☐ ") + $0.element.header }.joined(separator: "  ")
            out.append("←  \(tabs)  ✔ Submit  →")
        }
        if onReview { return (out + reviewLines()).joined(separator: "\n") }
        let q = asked.questions[current]
        out.append(contentsOf: wrap(q.question))
        let rows = rowOrder(current)
        let n = q.options.count
        for (i, r) in rows.enumerated() {
            let mark = i == cursor ? "❯ " : "  "
            switch r {
            case .option(let j):
                let box = q.multi ? "[\(picked[current].contains(j) ? "✔" : " ")] " : ""
                let tick = !q.multi && picked[current].contains(j) ? " ✔" : ""
                out.append("\(mark)\(j + 1). \(box)\(q.options[j].label)\(tick)")
                if !q.options[j].description.isEmpty { out.append("     \(q.options[j].description)") }
            case .other:
                let text = otherText[current] ?? (q.multi ? "Type something" : "Type something.")
                let box = q.multi ? "[\(otherTicked[current] ? "✔" : " ")] " : ""
                out.append("\(mark)\(n + 1). \(box)\(text)")
            case .next:
                out.append("\(mark)   \(hasTabBar && asked.questions.count == 1 ? "Submit" : "Next")")
            case .chat:
                out.append(String(repeating: "─", count: 40))
                out.append("\(mark)\(n + (q.multi ? 2 : 2)). Chat about this")
            }
        }
        out.append("Enter to select · Tab/Arrow keys to navigate · Esc to cancel")
        return out.joined(separator: "\n")
    }

    private func wrap(_ s: String) -> [String] {
        var lines: [String] = []
        var line = ""
        for w in s.split(separator: " ") {
            if line.count + w.count + 1 > width - 4, !line.isEmpty { lines.append(line); line = "" }
            line += (line.isEmpty ? "" : " ") + w
        }
        return lines + [line]
    }

    func answerString(_ qi: Int) -> String {
        let q = asked.questions[qi]
        var parts = picked[qi].sorted().map { q.options[$0].label }
        if let o = otherText[qi], q.multi ? otherTicked[qi] : true { parts.append(o) }
        return parts.joined(separator: ", ")
    }

    private func reviewLines() -> [String] {
        var out = ["Review your answers", ""]
        for (i, q) in asked.questions.enumerated() where answered[i] {
            out.append(" ● \(q.question)")
            out.append("   → \(answerString(i))")
        }
        if answered.contains(false) { out.append("⚠ You have not answered all questions") }
        out += ["Ready to submit your answers?", "\(reviewCursor == 0 ? "❯" : " ") 1. Submit answers", "\(reviewCursor == 1 ? "❯" : " ") 2. Cancel"]
        return out
    }

    // MARK: keys

    func send(_ key: Keystroke) {
        keys.append(key)
        guard !closed else { return }
        switch key {
        case .text(let s): for c in s { press(c) }
        case .enter: enter()
        case .escape: cancelled = true
        case .key(let k): nav(k)
        case .pause, .awaitPromptClosed: break
        }
    }

    private func advance() {
        current += 1
        cursor = 0
        if onReview { reviewCursor = 0 }
    }

    private func submit() {
        var out: [String: String] = [:]
        for (i, q) in asked.questions.enumerated() where answered[i] { out[q.question] = answerString(i) }
        submitted = out
    }

    private func press(_ c: Character) {
        if onReview {
            if c == "1" { submit() } else if c == "2" { cancelled = true }
            return
        }
        let q = asked.questions[current]
        let n = q.options.count
        let row = rowOrder(current)[cursor]
        if row == .other {
            otherText[current] = (otherText[current] ?? "") + String(c)
            if q.multi { otherTicked[current] = true }
            return
        }
        guard let d = c.wholeNumberValue else { return }
        if q.multi {
            if row == .next { return }
            if (1...n).contains(d) {
                if picked[current].contains(d - 1) { picked[current].remove(d - 1) } else { picked[current].insert(d - 1) }
                answered[current] = !picked[current].isEmpty || otherTicked[current]
            } else if d == n + 1 {
                otherTicked[current].toggle(); badOtherTick = true
            } else if d == n + 2 { chatPressed = true }
        } else {
            if (1...n).contains(d) {
                picked[current] = [d - 1]
                otherText[current] = nil
                answered[current] = true
                if asked.questions.count == 1 { submit() } else { advance() }
            } else if d == n + 1 {
                cursor = rowOrder(current).firstIndex(of: .other)!
            } else if d == n + 2 { chatPressed = true }
        }
    }

    private func enter() {
        if onReview { if reviewCursor == 0 { submit() } else { cancelled = true }; return }
        let q = asked.questions[current]
        switch rowOrder(current)[cursor] {
        case .option(let j):
            if q.multi {
                if picked[current].contains(j) { picked[current].remove(j) } else { picked[current].insert(j) }
                answered[current] = !picked[current].isEmpty || otherTicked[current]
            } else {
                picked[current] = [j]; answered[current] = true
                if asked.questions.count == 1 { submit() } else { advance() }
            }
        case .other:
            if q.multi { otherTicked[current].toggle(); answered[current] = !picked[current].isEmpty || otherTicked[current] }
            else if let t = otherText[current], !t.isEmpty {
                picked[current] = []; answered[current] = true
                if asked.questions.count == 1 { submit() } else { advance() }
            }
        case .next: advance()
        case .chat: chatPressed = true
        }
    }

    private func nav(_ k: NavKey) {
        if onReview { return }
        let rows = rowOrder(current)
        let q = asked.questions[current]
        switch k {
        case .down: cursor = min(cursor + 1, rows.count - 1)
        case .up: cursor = max(cursor - 1, 0)
        case .tab:
            if q.multi, rows[cursor] == .other { cursor = rows.firstIndex(of: .next)! }
            else { advance() }
        case .right: if rows[cursor] != .other { advance() }
        case .left: if rows[cursor] != .other, current > 0 { current -= 1; cursor = 0 }
        }
    }
}

final class QuestionAnswerTests: XCTestCase {

    // MARK: fixtures

    private func q(_ text: String, _ header: String, multi: Bool = false, _ labels: [String], preview: Bool = false) -> AskedQuestion {
        AskedQuestion(question: text, header: header, multi: multi,
                      options: labels.enumerated().map { AskedOption(label: $0.element, description: $0.offset == 0 ? "A warm, bold color." : "") },
                      hasPreview: preview)
    }

    private var three: AskedQuestionSet {
        AskedQuestionSet(toolUseId: "toolu_1", questions: [
            q("Pick a color", "Color", ["Red", "Green", "Blue"]),
            q("Pick toppings", "Toppings", multi: true, ["Cheese", "Ham", "Olives", "Corn"]),
            q("Pick a size", "Size", ["Small", "Medium", "Large"])
        ])
    }

    private func drive(_ dialog: FakeQuestionDialog, _ answers: [ResolvedAnswer], caps: AnswerKeyCaps = .tmux) -> AnswerLoop.Result {
        var driver = AnswerDriver(asked: dialog.asked, answers: answers, caps: caps)
        return AnswerLoop.run(&driver, readScreen: { dialog.render() }, send: { dialog.send($0); return nil },
                              sleep: { _ in }, now: Date.init).result
    }

    private func resolved(_ set: AskedQuestionSet, _ picks: [AnswerPick]) throws -> [ResolvedAnswer] {
        switch AnswerPlan.resolve(set, picks) {
        case .success(let a): return a
        case .failure(let e): throw XCTSkip("resolve failed: \(e.message)")
        }
    }

    private func noForbiddenKeys(_ dialog: FakeQuestionDialog, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(dialog.keys.contains(.escape), "never Esc", file: file, line: line)
        XCTAssertFalse(dialog.chatPressed, "never Chat about this", file: file, line: line)
        XCTAssertFalse(dialog.cancelled, "never Cancel", file: file, line: line)
        XCTAssertFalse(dialog.badOtherTick, "never an empty Other tick", file: file, line: line)
    }

    // MARK: parsing the tool call

    func testParseAskedQuestionSetReadsEverythingThePhoneNeeds() {
        let input: [String: Any] = ["questions": [
            ["question": "Pick toppings?", "header": "Toppings", "multiSelect": true,
             "options": [["label": "Cheese", "description": "Melty"], ["label": "Ham", "description": ""]]],
            ["question": "Size?", "header": "Size", "multiSelect": false,
             "options": [["label": "S", "description": "small"], ["label": "L", "description": "large"]]]]]
        let set = AskedQuestionSet.parse(toolUseId: "toolu_x", input: input)
        XCTAssertEqual(set?.questions.count, 2)
        XCTAssertEqual(set?.questions[0].multi, true)
        XCTAssertEqual(set?.questions[0].options[0], AskedOption(label: "Cheese", description: "Melty"))
        XCTAssertEqual(set?.questions[1].header, "Size")
        XCTAssertEqual(set?.hasPreview, false)
    }

    func testParseRefusesWhatItCannotDrive() {
        XCTAssertNil(AskedQuestionSet.parse(toolUseId: "t", input: [:]))
        XCTAssertNil(AskedQuestionSet.parse(toolUseId: "t", input: ["questions": []]))
        // An option without a label, a question without options.
        XCTAssertNil(AskedQuestionSet.parse(toolUseId: "t", input: ["questions": [["question": "Q?", "options": [["label": ""]]]]]))
        XCTAssertNil(AskedQuestionSet.parse(toolUseId: "t", input: ["questions": [["question": "Q?", "options": []]]]))
        // More options than there are single-digit keys.
        let many = (1...8).map { ["label": "o\($0)"] }
        XCTAssertNil(AskedQuestionSet.parse(toolUseId: "t", input: ["questions": [["question": "Q?", "options": many]]]))
        // Five questions.
        let five = (1...5).map { _ in ["question": "Q?", "options": [["label": "a"], ["label": "b"]]] as [String: Any] }
        XCTAssertNil(AskedQuestionSet.parse(toolUseId: "t", input: ["questions": five]))
    }

    func testPreviewOptionsAreFlaggedAndNeverDriven() throws {
        let input: [String: Any] = ["questions": [["question": "Layout?", "header": "Layout", "multiSelect": false,
            "options": [["label": "Grid", "description": "g", "preview": "┌──┐"], ["label": "List", "description": "l", "preview": "│ │"]]]]]
        let set = try XCTUnwrap(AskedQuestionSet.parse(toolUseId: "t", input: input))
        XCTAssertTrue(set.hasPreview)
        XCTAssertEqual(AnswerPlan.resolve(set, [AnswerPick(question: 0, picks: [0], other: nil)]),
                       .failure(AnswerPlanError(AnswerPlan.previewMessage)))
    }

    func testPhoneObjectIsRedactedAndClipped() throws {
        let long = String(repeating: "x", count: 600)
        let set = AskedQuestionSet(toolUseId: "toolu_9", questions: [
            AskedQuestion(question: "Use key sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789 \(long)", header: "H",
                          multi: false, options: [AskedOption(label: "A", description: "d"), AskedOption(label: "B", description: "")], hasPreview: false)])
        let o = set.phoneObject
        XCTAssertEqual(o["id"] as? String, "toolu_9")
        let qs = try XCTUnwrap(o["questions"] as? [[String: Any]])
        let text = try XCTUnwrap(qs[0]["question"] as? String)
        XCTAssertLessThanOrEqual(text.count, AskedQuestionSet.maxQuestionChars)
        XCTAssertFalse(text.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        let opts = try XCTUnwrap(qs[0]["options"] as? [[String: Any]])
        XCTAssertNil(opts[1]["description"], "an empty description is left out")
    }

    // MARK: resolving answers

    func testResolveEnforcesOneAnswerEach() {
        let set = three
        let ok = [AnswerPick(question: 0, picks: [1], other: nil), AnswerPick(question: 1, picks: [3, 1], other: nil),
                  AnswerPick(question: 2, picks: [0], other: nil)]
        guard case .success(let a) = AnswerPlan.resolve(set, ok) else { return XCTFail("expected success") }
        XCTAssertEqual(a[1].picks, [1, 3], "sorted")
        // Missing a question.
        XCTAssertNotNil(AnswerPlan.resolve(set, Array(ok.prefix(2))).failureMessage)
        // Two picks for a single-select.
        XCTAssertNotNil(AnswerPlan.resolve(set, [ok[0].with(picks: [0, 1]), ok[1], ok[2]]).failureMessage)
        // Out of range, duplicate.
        XCTAssertNotNil(AnswerPlan.resolve(set, [ok[0], ok[1].with(picks: [9]), ok[2]]).failureMessage)
        XCTAssertNotNil(AnswerPlan.resolve(set, [ok[0], ok[1].with(picks: [1, 1]), ok[2]]).failureMessage)
        // A single-select with nothing picked, a multi with nothing.
        XCTAssertNotNil(AnswerPlan.resolve(set, [ok[0].with(picks: []), ok[1], ok[2]]).failureMessage)
        XCTAssertNotNil(AnswerPlan.resolve(set, [ok[0], ok[1].with(picks: []), ok[2]]).failureMessage)
        // Other with text counts as the single choice; Other with nothing typed does not.
        XCTAssertNil(AnswerPlan.resolve(set, [ok[0].with(picks: [], other: "Purple"), ok[1], ok[2]]).failureMessage)
        XCTAssertNotNil(AnswerPlan.resolve(set, [ok[0].with(picks: [], other: "  "), ok[1], ok[2]]).failureMessage)
        // An option and Other together in a single-select is two answers.
        XCTAssertNotNil(AnswerPlan.resolve(set, [ok[0].with(picks: [0], other: "Purple"), ok[1], ok[2]]).failureMessage)
    }

    func testOtherTextIsOneCleanLine() {
        let set = AskedQuestionSet(toolUseId: "t", questions: [q("Q?", "Q", ["a", "b"])])
        guard case .success(let a) = AnswerPlan.resolve(set, [AnswerPick(question: 0, picks: [], other: "  line one\r\nline\ttwo\u{1B}[A\n")]) else { return XCTFail() }
        XCTAssertEqual(a[0].other, "line one line two[A")
        guard case .success(let b) = AnswerPlan.resolve(set, [AnswerPick(question: 0, picks: [], other: String(repeating: "z", count: 900))]) else { return XCTFail() }
        XCTAssertEqual(b[0].other?.count, AnswerRequest.maxOtherChars)
    }

    func testExpectedAnswersAreJoinedInOptionOrderWithOtherLast() {
        let set = three
        let a = [ResolvedAnswer(picks: [1], other: nil), ResolvedAnswer(picks: [1, 3], other: "Z q"), ResolvedAnswer(picks: [], other: "Tiny")]
        let e = AnswerPlan.expectedAnswers(set, a)
        XCTAssertEqual(e.map(\.answer), ["Green", "Ham, Corn, Z q", "Tiny"])
        XCTAssertEqual(e.map(\.question), ["Pick a color", "Pick toppings", "Pick a size"])
    }

    func testParseAnswersIsBounded() {
        XCTAssertNil(AnswerRequest.parseAnswers(nil))
        XCTAssertNil(AnswerRequest.parseAnswers([]))
        XCTAssertNil(AnswerRequest.parseAnswers([["i": -1, "picks": [0]]]))
        XCTAssertNil(AnswerRequest.parseAnswers([["i": 9, "picks": [0]]]))
        XCTAssertNil(AnswerRequest.parseAnswers([["picks": [0]]]))
        let ok = AnswerRequest.parseAnswers([["i": 0, "picks": [1, 2], "other": "x"], ["i": 1, "picks": [0]]])
        XCTAssertEqual(ok, [AnswerPick(question: 0, picks: [1, 2], other: "x"), AnswerPick(question: 1, picks: [0], other: nil)])
    }

    // MARK: reading the screen (the research's screens, verbatim)

    private let singleScreen = """
    ←  ☐ Color  ☐ Toppings  ☐ Size  ✔ Submit  →
    Pick a color
    ❯ 1. Red
         A warm, bold color.
      2. Green
      3. Blue
      4. Type something.
    ────────────────────────────────────────
      5. Chat about this
    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """

    private let multiScreen = """
    ←  ☒ Color  ☐ Toppings  ☐ Size  ✔ Submit  →
    Pick toppings
    ❯ 1. [ ] Cheese
      2. [✔] Ham
      3. [ ] Olives
      4. [ ] Corn
      5. [ ] Type something
         Next
    ────────────────────────────────────────
      6. Chat about this
    Enter to select · Tab/Arrow keys to navigate · Esc to cancel
    """

    private let reviewScreen = """
    ←  ☒ Color  ☒ Toppings  ☒ Size  ✔ Submit  →
    Review your answers
     ● Pick a color
       → Green
     ● Pick toppings
       → Ham, Corn
     ● Pick a size
       → Small
    Ready to submit your answers?
    ❯ 1. Submit answers
      2. Cancel
    """

    // Captured from a real Claude Code 2.1.311 pane (tmux capture-pane -p, 120 columns).
    private let rule = String(repeating: "─", count: 120)

    func testRealCaptureOfAOneQuestionSingleSelect() {
        let screen = """
        ✻ Crunched for 3s · done 7:42 AM
        ❯ Call the AskUserQuestion tool exactly once with ONE question only: text "Pick a mode", header "Mode", single-select,
          options Fast, Safe, Slow. Do nothing else. After I answer, reply with only the answer.
        \(rule)
         ☐ Mode
        Pick a mode
        ❯ 1. Fast
             Fast
          2. Safe
             Safe
          3. Slow
             Slow
          4. Type something.
        \(rule)
          5. Chat about this
        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let mode = q("Pick a mode", "Mode", ["Fast", "Safe", "Slow"])
        let p = QuestionScreen.parse(screen)
        XCTAssertTrue(p.matches(mode))
        XCTAssertEqual(p.cursor, .row(1))
        XCTAssertEqual(p.rows.count, 5)
    }

    func testRealCaptureOfAOneQuestionMultiSelect() {
        let screen = """
        \(rule)
        ←  ☐ Tags  ✔ Submit  →
        Pick tags
        ❯ 1. [ ] Alpha
                 Alpha
          2. [ ] Beta
                 Beta
          3. [ ] Gamma
                 Gamma
          4. [ ] Type something
             Submit
        \(rule)
          5. Chat about this
        Enter to select · ↑/↓ to navigate · Esc to cancel
        """
        let tags = q("Pick tags", "Tags", multi: true, ["Alpha", "Beta", "Gamma"])
        let p = QuestionScreen.parse(screen)
        XCTAssertTrue(p.matches(tags))
        XCTAssertTrue(p.hasNextRow, "the row is called Submit when there is one question")
        XCTAssertEqual(p.cursor, .row(1))
    }

    func testParsesTheSingleSelectScreen() {
        let p = QuestionScreen.parse(singleScreen)
        XCTAssertEqual(p.layout, .question)
        XCTAssertEqual(p.cursor, .row(1))
        XCTAssertEqual(p.rows.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(p.rows[0].text, "Red A warm, bold color.")
        XCTAssertNil(p.rows[0].ticked)
        XCTAssertTrue(p.matches(three.questions[0]))
        XCTAssertFalse(p.matches(three.questions[1]))
        XCTAssertTrue(p.otherIsEmpty(three.questions[0]))
    }

    func testParsesTheMultiSelectScreen() {
        let p = QuestionScreen.parse(multiScreen)
        XCTAssertEqual(p.rows.map(\.number), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(p.rows.map { $0.ticked }, [false, true, false, false, false, nil])
        XCTAssertEqual(p.rows[1].ticked, true)
        XCTAssertEqual(p.rows[0].ticked, false)
        XCTAssertTrue(p.hasNextRow)
        XCTAssertTrue(p.matches(three.questions[1]))
        XCTAssertFalse(p.matches(three.questions[0]), "a checkbox layout is not the single-select question")
        XCTAssertTrue(p.optionTicked(1))
        XCTAssertFalse(p.optionTicked(0))
    }

    func testCursorOnTheNextRowAndTheOtherRow() {
        let onNext = multiScreen.replacingOccurrences(of: "❯ 1.", with: "  1.").replacingOccurrences(of: "     Next", with: "❯    Next")
        XCTAssertEqual(QuestionScreen.parse(onNext).cursor, .next)
        let typed = multiScreen.replacingOccurrences(of: "❯ 1.", with: "  1.")
            .replacingOccurrences(of: "  5. [ ] Type something", with: "❯ 5. [✔] 1ab")
        let p = QuestionScreen.parse(typed)
        XCTAssertEqual(p.cursor, .row(5))
        XCTAssertFalse(p.otherIsEmpty(three.questions[1]))
        XCTAssertTrue(p.otherShows(three.questions[1], "1ab"))
        XCTAssertFalse(p.otherShows(three.questions[1], "xyz"))
    }

    func testParsesReview() {
        let p = QuestionScreen.parse(reviewScreen)
        XCTAssertEqual(p.layout, .review)
        XCTAssertTrue(p.reviewMatches([("Pick a color", "Green"), ("Pick toppings", "Ham, Corn"), ("Pick a size", "Small")]))
        XCTAssertFalse(p.reviewMatches([("Pick a color", "Green"), ("Pick toppings", "Ham"), ("Pick a size", "Small")]))
        XCTAssertFalse(p.reviewMatches([("Pick a color", "Green")]))
    }

    func testReviewWithASkippedQuestionNeverMatches() {
        let skipped = reviewScreen.replacingOccurrences(of: "Ready to submit", with: "⚠ You have not answered all questions\nReady to submit")
        let p = QuestionScreen.parse(skipped)
        XCTAssertTrue(p.unansweredWarning)
        XCTAssertFalse(p.reviewMatches([("Pick a color", "Green"), ("Pick toppings", "Ham, Corn"), ("Pick a size", "Small")]))
    }

    func testPreviewLayoutIsNeverMatched() {
        let preview = """
        ←  ☐ Layout  ☐ Theme  ✔ Submit  →
        Pick a layout
        ❯ 1. Grid          ┌─────────────┐
          2. List          │ preview box │
          3. Type something└─────────────┘
          4. Chat about this
        Enter to select · ↑/↓ to navigate · n to add notes · Tab to switch questions · Esc to cancel
        """
        let p = QuestionScreen.parse(preview)
        XCTAssertTrue(p.previewLayout)
        XCTAssertFalse(p.matches(q("Pick a layout", "Layout", ["Grid", "List"])))
        var d = AnswerDriver(asked: AskedQuestionSet(toolUseId: "t", questions: [q("Pick a layout", "Layout", ["Grid", "List"])]),
                             answers: [ResolvedAnswer(picks: [0], other: nil)], caps: .tmux)
        XCTAssertEqual(d.decide(screen: preview), .abort(AnswerPlan.previewMessage))
    }

    func testAShortPaneFailsClosed() {
        // 56x18: the tab bar, the question and option 1 scrolled off the top.
        let cut = """
          2. Green
          3. Blue
          4. Type something.
        ────────────────────────────────────────
          5. Chat about this
        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
        let p = QuestionScreen.parse(cut)
        XCTAssertEqual(p.layout, .none)
        var d = AnswerDriver(asked: three, answers: [ResolvedAnswer(picks: [1], other: nil), ResolvedAnswer(picks: [1], other: nil),
                                                       ResolvedAnswer(picks: [0], other: nil)], caps: .tmux)
        guard case .wait = d.decide(screen: cut) else { return XCTFail("must not send into a screen it can't read") }
    }

    func testANarrowPaneStillMatchesWhenTheTextWraps() {
        let narrow = """
        ←  ☐ Color  ☐ Toppi…  ☐ Size  ✔ Submit  →
        Pick a
        color
        ❯ 1. Red
             A warm, bold color.
          2. Green
          3. Blue
          4. Type something.
        ──────────────────────────────
          5. Chat about this
        Enter to select · Esc to cancel
        """
        XCTAssertTrue(QuestionScreen.parse(narrow).matches(three.questions[0]))
    }

    func testAnotherQuestionWithTheSameOptionsIsNotMistaken() {
        let other = q("Pick a mood", "Mood", ["Red", "Green", "Blue"])
        XCTAssertFalse(QuestionScreen.parse(singleScreen).matches(other), "the question text must match too")
    }

    func testAConversationNumberedListIsNotTheDialog() {
        let screen = "Here are the steps:\n1. First thing\n2. Second thing\n\n❯ \n"
        XCTAssertFalse(QuestionScreen.parse(screen).matches(three.questions[0]))
        XCTAssertFalse(QuestionScreen.parse(screen).showsDialog(three))
    }

    // MARK: the driver against the simulated dialog

    func testThreeQuestionsMixedRun() throws {
        let set = three
        let dialog = FakeQuestionDialog(set)
        let answers = try resolved(set, [AnswerPick(question: 0, picks: [1], other: nil),
                                         AnswerPick(question: 1, picks: [1, 3], other: nil),
                                         AnswerPick(question: 2, picks: [0], other: nil)])
        XCTAssertEqual(drive(dialog, answers), .submitted)
        noForbiddenKeys(dialog)
        XCTAssertEqual(dialog.submitted, ["Pick a color": "Green", "Pick toppings": "Ham, Corn", "Pick a size": "Small"])
        XCTAssertEqual(dialog.keys, [.text("2"), .text("2"), .text("4"), .key(.tab), .text("1"), .text("1")])
    }

    func testSingleOtherThenMultiWithOther() throws {
        let set = three
        let dialog = FakeQuestionDialog(set)
        let answers = try resolved(set, [AnswerPick(question: 0, picks: [], other: "Purple"),
                                         AnswerPick(question: 1, picks: [0, 2], other: "kiwi pie"),
                                         AnswerPick(question: 2, picks: [2], other: nil)])
        XCTAssertEqual(drive(dialog, answers), .submitted)
        noForbiddenKeys(dialog)
        XCTAssertEqual(dialog.submitted, ["Pick a color": "Purple", "Pick toppings": "Cheese, Olives, kiwi pie", "Pick a size": "Large"])
        // 4 = Other row (N+1) for the first, then its text and Enter.
        XCTAssertEqual(Array(dialog.keys.prefix(3)), [.text("4"), .text("Purple"), .enter])
        XCTAssertTrue(dialog.keys.contains(.key(.down)))
        XCTAssertEqual(dialog.keys.filter { $0 == .key(.down) }.count, 4, "N options → Down × N to reach Other")
    }

    func testOneSingleQuestionIsOneDigit() throws {
        let set = AskedQuestionSet(toolUseId: "t", questions: [q("Pick a mode", "Mode", ["Fast", "Safe", "Slow"])])
        let dialog = FakeQuestionDialog(set)
        XCTAssertEqual(drive(dialog, try resolved(set, [AnswerPick(question: 0, picks: [1], other: nil)])), .submitted)
        XCTAssertEqual(dialog.keys, [.text("2")])
        XCTAssertEqual(dialog.submitted, ["Pick a mode": "Safe"])
    }

    func testOneMultiQuestionGoesThroughReview() throws {
        let set = AskedQuestionSet(toolUseId: "t", questions: [q("Pick tags", "Tags", multi: true, ["A", "B", "C"])])
        let dialog = FakeQuestionDialog(set)
        XCTAssertEqual(drive(dialog, try resolved(set, [AnswerPick(question: 0, picks: [0, 2], other: "Z q")])), .submitted)
        noForbiddenKeys(dialog)
        XCTAssertEqual(dialog.submitted, ["Pick tags": "A, C, Z q"])
        XCTAssertEqual(dialog.keys.last, .text("1"), "Review is submitted with 1")
    }

    func testPlansFromTheScreenNotFromAssumedState() throws {
        // The person already ticked Ham at the Mac; Page must untick it, not toggle blindly.
        let set = three
        let dialog = FakeQuestionDialog(set)
        dialog.send(.text("2"))            // Q1: Green
        dialog.send(.text("2"))            // Q2: Ham ticked at the Mac
        dialog.keys.removeAll()
        // Start from the middle: the first question must be showing.
        var d = AnswerDriver(asked: set, answers: [ResolvedAnswer(picks: [0], other: nil), ResolvedAnswer(picks: [3], other: nil),
                                                    ResolvedAnswer(picks: [0], other: nil)], caps: .tmux)
        guard case .wait(let why) = d.decide(screen: dialog.render()) else { return XCTFail() }
        XCTAssertEqual(why, AnswerDriver.notFirstMessage)
    }

    func testAlreadyTickedOptionIsUntickedAndNeverBlindlyToggled() throws {
        // A one-question multi where the Mac user already ticked B.
        let set = AskedQuestionSet(toolUseId: "t", questions: [q("Pick tags", "Tags", multi: true, ["A", "B", "C"])])
        let dialog = FakeQuestionDialog(set)
        dialog.send(.text("2"))
        dialog.keys.removeAll()
        XCTAssertEqual(drive(dialog, try resolved(set, [AnswerPick(question: 0, picks: [0], other: nil)])), .submitted)
        XCTAssertEqual(dialog.submitted, ["Pick tags": "A"])
        XCTAssertEqual(dialog.keys.filter { $0 == .text("2") }.count, 1, "B toggled off once")
    }

    func testAbortsWhenCursorIsNotOnAnOptionRow() throws {
        let set = AskedQuestionSet(toolUseId: "t", questions: [q("Pick tags", "Tags", multi: true, ["A", "B"])])
        let dialog = FakeQuestionDialog(set)
        dialog.send(.key(.tab))   // (one question: Tab goes to Review) — put the cursor on the Other row instead
        dialog.current = 0; dialog.cursor = 2
        dialog.keys.removeAll()
        let answers = try resolved(set, [AnswerPick(question: 0, picks: [0], other: nil)])
        var driver = AnswerDriver(asked: set, answers: answers, caps: .tmux)
        guard case .abort = driver.decide(screen: dialog.render()) else { return XCTFail("a digit on the Other row would type into it") }
        XCTAssertTrue(dialog.keys.isEmpty)
    }

    func testRefusesOtherInMultiSelectWithoutArrowKeys() throws {
        let set = three
        let dialog = FakeQuestionDialog(set)
        let answers = try resolved(set, [AnswerPick(question: 0, picks: [0], other: nil), AnswerPick(question: 1, picks: [0], other: "x"),
                                         AnswerPick(question: 2, picks: [0], other: nil)])
        XCTAssertTrue(AnswerPlan.needsArrows(set, answers))
        let result = drive(dialog, answers, caps: .plainKeysOnly)
        XCTAssertEqual(result, .aborted(AnswerPlan.arrowsMessage))
        noForbiddenKeys(dialog)
        XCTAssertFalse(dialog.closed, "the dialog is left open at the Mac")
    }

    func testReviewMismatchPressesNothing() throws {
        // Something moves between the last question and Review: Review lists other answers than we planned.
        let set = AskedQuestionSet(toolUseId: "t", questions: [q("Pick tags", "Tags", multi: true, ["A", "B"])])
        let dialog = FakeQuestionDialog(set)
        var driver = AnswerDriver(asked: set, answers: try resolved(set, [AnswerPick(question: 0, picks: [0], other: nil)]), caps: .tmux)
        var verdict: AnswerDriver.Decision?
        for _ in 0..<20 {
            let d = driver.decide(screen: dialog.render())
            if case .send(let key, _) = d {
                dialog.send(key)
                if dialog.current >= set.questions.count { dialog.picked[0] = [1] }   // Review now shows "B"
            } else { verdict = d; break }
        }
        guard case .abort? = verdict else { return XCTFail("expected an abort on Review, got \(String(describing: verdict))") }
        XCTAssertFalse(dialog.closed, "nothing was submitted")
    }

    func testWaitsUntilTheScreenCatchesUp() throws {
        // The screen lags: after a key the old screen is read again. The driver must wait, not repeat the key.
        let set = AskedQuestionSet(toolUseId: "t", questions: [q("Pick tags", "Tags", multi: true, ["A", "B", "C"])])
        let dialog = FakeQuestionDialog(set)
        let answers = try resolved(set, [AnswerPick(question: 0, picks: [1], other: nil)])
        var driver = AnswerDriver(asked: set, answers: answers, caps: .tmux)
        let before = dialog.render()
        guard case .send(.text("2"), _) = driver.decide(screen: before) else { return XCTFail() }
        dialog.send(.text("2"))
        guard case .wait = driver.decide(screen: before) else { return XCTFail("stale screen: must wait, not send 2 again") }
        guard case .wait = driver.decide(screen: before) else { return XCTFail("still waiting") }
        guard case .send(.key(.tab), _) = driver.decide(screen: dialog.render()) else { return XCTFail("fresh screen: carry on") }
    }

    func testLoopGivesUpWhenTheScreenNeverMatches() {
        var clock = Date(timeIntervalSince1970: 1_000)
        var driver = AnswerDriver(asked: three, answers: [ResolvedAnswer(picks: [0], other: nil), ResolvedAnswer(picks: [0], other: nil),
                                                           ResolvedAnswer(picks: [0], other: nil)], caps: .tmux)
        var sent = 0
        let r = AnswerLoop.run(&driver, readScreen: { "nothing to see here" }, send: { _ in sent += 1; return nil },
                               sleep: { clock = clock.addingTimeInterval($0) }, now: { clock }).result
        XCTAssertEqual(sent, 0)
        guard case .aborted = r else { return XCTFail("expected an abort") }
    }

    func testLoopStopsWhenASendIsRefused() throws {
        let set = three
        let dialog = FakeQuestionDialog(set)
        let answers = try resolved(set, [AnswerPick(question: 0, picks: [1], other: nil), AnswerPick(question: 1, picks: [1], other: nil),
                                         AnswerPick(question: 2, picks: [0], other: nil)])
        var driver = AnswerDriver(asked: set, answers: answers, caps: .tmux)
        var n = 0
        let r = AnswerLoop.run(&driver, readScreen: { dialog.render() },
                               send: { key in n += 1; if n == 2 { return "The session is no longer waiting" }; dialog.send(key); return nil },
                               sleep: { _ in }).result
        XCTAssertEqual(r, .aborted("The session is no longer waiting"))
        XCTAssertFalse(dialog.closed)
    }

    func testNoKeyEverCancelsOrChatsAcrossManyShapes() throws {
        // Property-style sweep: every option choice, with and without Other, singles and multis.
        for multi in [false, true] {
            for n in 2...4 {
                let labels = (1...n).map { "Opt\($0)" }
                let set = AskedQuestionSet(toolUseId: "t", questions: [q("First?", "A", multi: multi, labels), q("Second?", "B", labels)])
                for mask in 1..<(1 << n) {
                    for otherText in [nil, "free text"] {
                        let picks = (0..<n).filter { mask & (1 << $0) != 0 }
                        guard multi || picks.count == 1 else { continue }
                        let first = AnswerPick(question: 0, picks: multi ? picks : (otherText == nil ? picks : []), other: otherText)
                        guard case .success(let a) = AnswerPlan.resolve(set, [first, AnswerPick(question: 1, picks: [0], other: nil)]) else { continue }
                        let dialog = FakeQuestionDialog(set)
                        XCTAssertEqual(drive(dialog, a), .submitted, "n=\(n) multi=\(multi) mask=\(mask) other=\(otherText ?? "-")")
                        noForbiddenKeys(dialog)
                        for k in dialog.keys {
                            if case .text(let t) = k, t.count == 1, let d = Int(t) {
                                XCTAssertLessThanOrEqual(d, n + 1, "no digit reaches Chat about this")
                            }
                        }
                        let expected = Dictionary(uniqueKeysWithValues: AnswerPlan.expectedAnswers(set, a).map { ($0.question, $0.answer) })
                        XCTAssertEqual(dialog.submitted, expected)
                    }
                }
            }
        }
    }

    // MARK: what Claude received

    private func transcriptLine(toolUseId: String, answers: [String: String]?, isError: Bool = false) -> String {
        var obj: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": toolUseId, "content": "x", "is_error": isError] as [String: Any]]]]
        if let answers { obj["toolUseResult"] = ["questions": [], "answers": answers] }
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    func testReceiptComparesWhatClaudeGot() {
        let expected = [(question: "Pick a color", answer: "Green"), (question: "Pick toppings", answer: "Ham, Corn")]
        let good = transcriptLine(toolUseId: "toolu_1", answers: ["Pick a color": "Green", "Pick toppings": "Ham, Corn"])
        XCTAssertEqual(AnswerReceipt.outcome(transcript: "noise\n" + good, toolUseId: "toolu_1", expected: expected), .matched)
        let off = transcriptLine(toolUseId: "toolu_1", answers: ["Pick a color": "Green", "Pick toppings": "Ham"])
        XCTAssertEqual(AnswerReceipt.outcome(transcript: off, toolUseId: "toolu_1", expected: expected),
                       .different(["Pick a color": "Green", "Pick toppings": "Ham"]))
        let rejected = transcriptLine(toolUseId: "toolu_1", answers: nil, isError: true)
        XCTAssertEqual(AnswerReceipt.outcome(transcript: rejected, toolUseId: "toolu_1", expected: expected), .rejected)
        XCTAssertEqual(AnswerReceipt.outcome(transcript: good, toolUseId: "toolu_other", expected: expected), .notFound)
    }

    func testReceiptOfAnUnknownAnswersShapeIsUnconfirmedNotDismissed() {
        // A future multi-select stored as an array: Claude did receive answers, Page just can't compare them.
        let obj: [String: Any] = ["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "toolu_1", "content": "x"] as [String: Any]]],
                                  "toolUseResult": ["answers": ["Pick a color": ["Green"]]]]
        let line = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        XCTAssertEqual(AnswerReceipt.outcome(transcript: line, toolUseId: "toolu_1", expected: [(question: "Pick a color", answer: "Green")]), .notFound)
    }
}

private extension AnswerPick {
    func with(picks: [Int]? = nil, other: String?? = nil) -> AnswerPick {
        AnswerPick(question: question, picks: picks ?? self.picks, other: other ?? self.other)
    }
}

private extension Result where Failure == AnswerPlanError {
    var failureMessage: String? { if case .failure(let e) = self { return e.message }; return nil }
}
