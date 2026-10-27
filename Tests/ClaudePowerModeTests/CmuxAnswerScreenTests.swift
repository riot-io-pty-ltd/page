import XCTest
@testable import ClaudePowerMode

/// Trimmed real captures: the screens cmux's `read-screen` returned for a two-question AskUserQuestion dialog
/// (Claude Code 2.1.311, cmux answer probe run, log `answer-probe/cmux/run5.log`). Only the dialog region is
/// kept; the shell, the prompt text above it and the probe's log gutter are removed, and the rule line is 120
/// columns wide, not the pane's real width. cmux reads these as plain text, the same as tmux, so the same
/// parser must read them.
final class CmuxAnswerScreenTests: XCTestCase {
    private let rule = String(repeating: "─", count: 120)

    /// Question 1 of 2, single-select, nothing picked yet; the cursor is on Apple.
    private var fruitScreen: String {
        """
        \(rule)
        ←  ☐ Fruit  ☐ Toppings  ✔ Submit  →

        Which fruit do you want?

        ❯ 1. Apple
             Red and crisp
          2. Banana
             Yellow and soft
          3. Cherry
             Small and sweet
          4. Type something.
        \(rule)
          5. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
    }

    /// Question 2 of 2, multi-select; Fruit is answered (☒) and the cursor is on Cream.
    private var toppingsScreen: String {
        """
        \(rule)
        ←  ☒ Fruit  ☐ Toppings  ✔ Submit  →

        Which toppings do you want?

        ❯ 1. [ ] Cream
                 Whipped
          2. [ ] Nuts
                 Crunchy
          3. [ ] Honey
                 Sticky
          4. [ ] Type something
             Submit
        \(rule)
          5. Chat about this

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        """
    }

    /// The final "Review your answers" screen, where `1` submits.
    private var reviewScreen: String {
        """
        \(rule)
        ←  ☒ Fruit  ☒ Toppings  ✔ Submit  →

        Review your answers

         ● Which fruit do you want?
           → Banana
         ● Which toppings do you want?
           → Cream, probe-other

        Ready to submit your answers?

        ❯ 1. Submit answers
          2. Cancel
        """
    }

    private let fruit = AskedQuestion(question: "Which fruit do you want?", header: "Fruit", multi: false,
                                      options: [AskedOption(label: "Apple", description: "Red and crisp"),
                                                AskedOption(label: "Banana", description: "Yellow and soft"),
                                                AskedOption(label: "Cherry", description: "Small and sweet")],
                                      hasPreview: false)
    private let toppings = AskedQuestion(question: "Which toppings do you want?", header: "Toppings", multi: true,
                                         options: [AskedOption(label: "Cream", description: "Whipped"),
                                                   AskedOption(label: "Nuts", description: "Crunchy"),
                                                   AskedOption(label: "Honey", description: "Sticky")],
                                         hasPreview: false)

    func testTheFirstQuestionScreenIsReadAsItsSingleSelect() {
        let p = QuestionScreen.parse(fruitScreen)
        XCTAssertEqual(p.layout, .question)
        XCTAssertFalse(p.previewLayout)
        XCTAssertEqual(p.cursor, .row(1), "the cursor is on Apple")
        XCTAssertEqual(p.rows.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(p.rows.map(\.ticked), [nil, nil, nil, nil, nil], "single-select draws no checkboxes")
        XCTAssertTrue(p.matches(fruit))
        XCTAssertFalse(p.matches(toppings), "a different question is not this screen")
        XCTAssertFalse(CmuxBridge.isReviewScreen(fruitScreen))
    }

    func testTheSecondQuestionScreenIsReadAsItsMultiSelectWithNothingTicked() {
        let p = QuestionScreen.parse(toppingsScreen)
        XCTAssertEqual(p.layout, .question)
        XCTAssertEqual(p.cursor, .row(1), "the cursor is on Cream")
        XCTAssertEqual(p.rows.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(p.rows.map(\.ticked), [false, false, false, false, nil])
        XCTAssertTrue(p.matches(toppings))
        XCTAssertFalse(p.matches(fruit), "a checkbox layout is not the single-select question")
        XCTAssertFalse(p.optionTicked(0))
        XCTAssertFalse(CmuxBridge.isReviewScreen(toppingsScreen))
    }

    func testTheReviewScreenIsReadAndIsTheOnlyOneCmuxSubmitsFrom() {
        let p = QuestionScreen.parse(reviewScreen)
        XCTAssertEqual(p.layout, .review)
        XCTAssertTrue(p.reviewMatches([("Which fruit do you want?", "Banana"),
                                       ("Which toppings do you want?", "Cream, probe-other")]))
        XCTAssertFalse(p.reviewMatches([("Which fruit do you want?", "Apple"),
                                        ("Which toppings do you want?", "Cream, probe-other")]))
        XCTAssertTrue(CmuxBridge.isReviewScreen(reviewScreen))
        XCTAssertFalse(CmuxBridge.isReviewScreen(fruitScreen))
        XCTAssertFalse(CmuxBridge.isReviewScreen(toppingsScreen))
    }
}
