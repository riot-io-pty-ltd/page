import Foundation

// Answering Claude Code's AskUserQuestion dialog from the phone.
//
// Everything here is pure (no I/O) and unit-tested, built on a key model
// measured on Claude Code 2.1.311 in tmux (docs/SESSIONS-PROTOCOL.md §5 "Answering a question"):
//
//   - single-select: a digit picks that option and advances (on the last
//     question: straight to Review; with one question: submits). The "Other"
//     row is number N+1: its digit only focuses it, then text and Enter.
//   - multi-select: a digit toggles that option, Tab (or Right) goes to the
//     next question. The Other row must be reached with Down (its digit ticks
//     an empty box); then text, Tab to "Next", Enter.
//   - Review: "1" submits, "2" cancels. Esc anywhere cancels everything.
//   - "Chat about this" is row N+2 and rejects the whole dialog.
//   - a question whose options carry `preview` lays out differently (digits
//     only move the cursor): never driven.
//
// `status` can't say which question or row is showing, so the screen is
// read before every key and the plan is derived from what is on it, never
// from assumed state. Anything unexpected stops with a reason and leaves the
// dialog open for the person at the Mac.

// MARK: - The questions

struct AskedOption: Equatable, Hashable {
    let label: String
    let description: String
}

struct AskedQuestion: Equatable, Hashable {
    let question: String
    let header: String
    let multi: Bool
    let options: [AskedOption]
    /// Some option carries a `preview` (a different dialog layout).
    let hasPreview: Bool
}

/// The pending AskUserQuestion tool call, as Claude wrote it (raw, unredacted:
/// the Mac matches the screen against it; the phone gets `phoneObject`).
struct AskedQuestionSet: Equatable, Hashable {
    let toolUseId: String
    let questions: [AskedQuestion]

    var hasPreview: Bool { questions.contains { $0.hasPreview } }

    static let maxQuestions = 4
    /// Digits are the keys: N options put Other at N+1 and "Chat about this" at N+2, all single digits.
    static let maxOptions = 7

    /// nil unless every question has text and between one and `maxOptions` options.
    static func parse(toolUseId: String, input: [String: Any]) -> AskedQuestionSet? {
        guard let raw = input["questions"] as? [[String: Any]], !raw.isEmpty, raw.count <= maxQuestions else { return nil }
        var out: [AskedQuestion] = []
        for q in raw {
            guard let text = (q["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let opts = q["options"] as? [[String: Any]], !opts.isEmpty, opts.count <= maxOptions else { return nil }
            var options: [AskedOption] = []
            var preview = false
            for o in opts {
                guard let label = (o["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                options.append(AskedOption(label: label, description: (o["description"] as? String) ?? ""))
                if let p = o["preview"] as? String, !p.isEmpty { preview = true }
            }
            out.append(AskedQuestion(question: text, header: ((q["header"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                     multi: (q["multiSelect"] as? Bool) ?? false, options: options, hasPreview: preview))
        }
        return AskedQuestionSet(toolUseId: toolUseId, questions: out)
    }

    static let maxQuestionChars = 400
    static let maxHeaderChars = 40
    static let maxLabelChars = 120
    static let maxDescriptionChars = 200

    /// The list row's `ask` (SESSIONS-PROTOCOL.md §4): redacted and clipped, the
    /// tool_use id as `id`. The phone answers by index; the Mac re-reads the raw call.
    var phoneObject: [String: Any] {
        func clean(_ s: String, _ n: Int) -> String {
            InterventionDetector.clip(ContextRedactor.redactedPrefix(s, n + 50), n)
        }
        return [
            "id": toolUseId,
            "hasPreview": hasPreview,
            "questions": questions.map { q -> [String: Any] in
                var o: [String: Any] = [
                    "question": clean(q.question, Self.maxQuestionChars),
                    "multi": q.multi,
                    "options": q.options.map { opt -> [String: Any] in
                        var d: [String: Any] = ["label": clean(opt.label, Self.maxLabelChars)]
                        if !opt.description.isEmpty { d["description"] = clean(opt.description, Self.maxDescriptionChars) }
                        return d
                    }
                ]
                if !q.header.isEmpty { o["header"] = clean(q.header, Self.maxHeaderChars) }
                return o
            }
        ]
    }
}

// MARK: - The phone's answers

/// One question's answer as the phone sent it: 0-based option indices (and
/// the Other text, which is the one thing typed). Indices are into the Mac's
/// own raw copy of the question, never labels from the wire.
struct AnswerPick: Equatable {
    let question: Int
    let picks: [Int]
    let other: String?
}

struct AnswerRequest: Equatable {
    let promptKey: String
    let answers: [AnswerPick]

    static let maxOtherChars = 300

    /// nil unless `obj` is a bounded array of {i, picks, other?}.
    static func parseAnswers(_ obj: Any?) -> [AnswerPick]? {
        guard let raw = obj as? [[String: Any]], !raw.isEmpty, raw.count <= AskedQuestionSet.maxQuestions else { return nil }
        var out: [AnswerPick] = []
        for a in raw {
            guard let i = (a["i"] as? NSNumber)?.intValue, i >= 0, i < AskedQuestionSet.maxQuestions else { return nil }
            let picks = ((a["picks"] as? [NSNumber]) ?? []).map(\.intValue)
            guard picks.count <= AskedQuestionSet.maxOptions + 1 else { return nil }
            let other = (a["other"] as? String).flatMap { $0.count > 4000 ? nil : $0 }
            out.append(AnswerPick(question: i, picks: picks, other: other))
        }
        return out
    }
}

/// A question's validated answer: sorted unique option indices and the
/// Other text, flattened to one line and stripped of control characters (a
/// newline or Tab would select or navigate).
struct ResolvedAnswer: Equatable {
    let picks: [Int]
    let other: String?
}

struct AnswerPlanError: Error, Equatable {
    /// Phone-safe.
    let message: String
    init(_ message: String) { self.message = message }
}

enum AnswerPlan {
    static let previewMessage = "These options have previews, which Page can't choose — answer at your Mac"
    static let incompleteMessage = "Answer every question first — Page only submits complete answers"
    static let arrowsMessage = "Other in a multi-select needs arrow keys, which Page only sends through tmux — answer at your Mac"

    /// Checks `picks` against the raw question set: every question answered
    /// once, indices in range, a single-select exactly one choice (an option
    /// or Other), a multi-select at least one.
    static func resolve(_ set: AskedQuestionSet, _ picks: [AnswerPick]) -> Result<[ResolvedAnswer], AnswerPlanError> {
        if set.hasPreview { return .failure(.init(previewMessage)) }
        guard picks.count == set.questions.count, Set(picks.map(\.question)) == Set(0..<set.questions.count) else {
            return .failure(.init(incompleteMessage))
        }
        var out: [ResolvedAnswer] = []
        for (qi, q) in set.questions.enumerated() {
            guard let a = picks.first(where: { $0.question == qi }) else { return .failure(.init(incompleteMessage)) }
            let unique = Array(Set(a.picks)).sorted()
            guard unique.count == a.picks.count, unique.allSatisfy({ $0 >= 0 && $0 < q.options.count }) else {
                return .failure(.init("An answer doesn't match the question on your Mac — close the question and open it again"))
            }
            let other = a.other.map(cleanOther).flatMap { $0.isEmpty ? nil : $0 }
            // "Other" chosen with nothing typed, and nothing else picked.
            if a.other != nil, other == nil, unique.isEmpty { return .failure(.init("Type your \"Other\" answer first")) }
            if q.multi {
                guard !unique.isEmpty || other != nil else { return .failure(.init(incompleteMessage)) }
            } else {
                guard unique.count + (other == nil ? 0 : 1) == 1 else {
                    return .failure(.init(unique.isEmpty ? incompleteMessage : "Choose one answer for each single-choice question"))
                }
            }
            out.append(ResolvedAnswer(picks: unique, other: other))
        }
        return .success(out)
    }

    /// One line, no control characters, no longer than `maxOtherChars`.
    static func cleanOther(_ raw: String) -> String {
        let one = InjectionExecutor.flattenLines(InjectionExecutor.sanitize(raw))
        let t = String(one.prefix(AnswerRequest.maxOtherChars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }

    /// What Claude Code stores per question: the picked labels in option
    /// order, joined with ", " (Other text last), keyed by question text.
    static func expectedAnswers(_ set: AskedQuestionSet, _ answers: [ResolvedAnswer]) -> [(question: String, answer: String)] {
        zip(set.questions, answers).map { q, a in
            var parts = a.picks.map { q.options[$0].label }
            if let o = a.other { parts.append(o) }
            return (q.question, parts.joined(separator: ", "))
        }
    }

    /// Whether the plan needs arrow keys (an Other row in a multi-select).
    static func needsArrows(_ set: AskedQuestionSet, _ answers: [ResolvedAnswer]) -> Bool {
        zip(set.questions, answers).contains { $0.multi && $1.other != nil }
    }
}

// MARK: - Reading the screen

/// Claude Code's question dialog as read off the terminal. Parsing is
/// deliberately narrow: anything that does not fit is `.none`, and the
/// driver treats `.none` as "not showing what I expect" and stops.
struct QuestionScreen: Equatable {
    enum Layout: Equatable { case none, question, review }
    enum Cursor: Equatable { case none, row(Int), next }

    struct Row: Equatable {
        let number: Int
        /// The label and what wraps or follows it (descriptions), whitespace
        /// collapsed, checkbox and trailing tick removed.
        var text: String
        /// nil in a single-select (no checkbox drawn).
        let ticked: Bool?
    }

    var layout: Layout = .none
    /// Lines above the first option (tab bar, question), collapsed.
    var region = ""
    var rows: [Row] = []
    var cursor: Cursor = .none
    var hasNextRow = false
    var previewLayout = false
    /// Review only: the answers listed above "Ready to submit", markers removed, collapsed.
    var reviewText = ""
    var unansweredWarning = false

    static let otherPlaceholder = "type something"
    static let chatRow = "chat about this"

    // MARK: normalising

    /// Collapses whitespace (and drops markdown marks the dialog doesn't draw).
    static func norm(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        return cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func squash(_ s: String) -> String { String(s.filter { !$0.isWhitespace }) }

    private static func isRule(_ t: String) -> Bool {
        t.filter { $0 == "─" || $0 == "━" || $0 == "═" }.count >= 8
    }

    // MARK: parsing

    static func parse(_ screen: String) -> QuestionScreen {
        var lines = screen.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.removeLast() }
        lines = Array(lines.suffix(60))
        var out = QuestionScreen()
        guard !lines.isEmpty else { return out }

        /// (cursor on this line, text after the cursor glyph, trimmed)
        func body(_ line: String) -> (Bool, String) {
            var t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            var cursor = false
            if t.hasPrefix("❯") { cursor = true; t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
            return (cursor, t)
        }
        func rowStart(_ t: String) -> (Int, String)? {
            guard let r = t.range(of: #"^\d{1,2}\.\s+"#, options: .regularExpression) else { return nil }
            let head = t[r]
            guard let n = Int(head.prefix { $0.isNumber }) else { return nil }
            return (n, String(t[r.upperBound...]))
        }
        /// Collects numbered rows (and the unnumbered Next/Submit row) from `range`.
        func collect(_ range: Range<Int>) {
            for i in range {
                let (cur, t) = body(lines[i])
                if t.isEmpty || isRule(t) { continue }
                if let (n, rest) = rowStart(t), n == (out.rows.last?.number ?? 0) + 1 {
                    var text = rest
                    var ticked: Bool?
                    if text.hasPrefix("["), let close = text.firstIndex(of: "]"), text.distance(from: text.startIndex, to: close) <= 2 {
                        let mark = text[text.index(after: text.startIndex)..<close]
                        ticked = mark == "✔" || mark == "✓" || mark.lowercased() == "x"
                        text = String(text[text.index(after: close)...])
                    }
                    text = norm(text)
                    for tick in [" ✔", " ✓"] where text.hasSuffix(tick) { text.removeLast(tick.count) }
                    out.rows.append(Row(number: n, text: text, ticked: ticked))
                    if cur { out.cursor = .row(n) }
                } else if t == "Next" || t == "Submit" {
                    out.hasNextRow = true
                    if cur { out.cursor = .next }
                } else if !out.rows.isEmpty {
                    out.rows[out.rows.count - 1].text = norm(out.rows[out.rows.count - 1].text + " " + t)
                }
            }
        }

        // Review: "Review your answers" … "Ready to submit your answers?" then 1. Submit / 2. Cancel.
        if let r = lines.lastIndex(where: { $0.contains("Review your answers") }) {
            let ready = lines[r...].firstIndex { $0.contains("Ready to submit") }
            out.layout = .review
            let end = ready ?? lines.count
            var kept: [String] = []
            for l in lines[(r + 1)..<end] {
                let (_, t) = body(l)
                if t.contains("not answered all questions") { out.unansweredWarning = true; continue }
                kept.append(t.replacingOccurrences(of: "●", with: " ").replacingOccurrences(of: "→", with: " ")
                                .replacingOccurrences(of: "⚠", with: " "))
            }
            out.reviewText = norm(kept.joined(separator: " "))
            if let ready { collect((ready + 1)..<lines.count) }
            return out
        }

        let footer = lines.lastIndex { $0.contains("Esc to cancel") } ?? lines.count
        guard let start = (0..<min(footer, lines.count)).last(where: {
            let (_, t) = body(lines[$0]); if let (n, _) = rowStart(t) { return n == 1 } else { return false }
        }) else { return out }
        out.layout = .question
        out.region = norm(lines[max(0, start - 14)..<start].map { body($0).1 }.joined(separator: " "))
        collect(start..<footer)
        if lines.contains(where: { $0.contains("n to add notes") })
            || lines[start..<footer].contains(where: { $0.contains("┌") || $0.contains("└") }) {
            out.previewLayout = true
        }
        return out
    }

    // MARK: matching

    /// The rows number N options, then Other, then "Chat about this"; the
    /// labels, the question text and the single/multi layout all agree.
    func matches(_ q: AskedQuestion) -> Bool {
        guard layout == .question, !previewLayout else { return false }
        let n = q.options.count
        guard rows.count == n + 2, rows[n + 1].text.lowercased().hasPrefix(Self.chatRow) else { return false }
        for (i, opt) in q.options.enumerated() {
            guard rows[i].number == i + 1, rows[i].text.hasPrefix(Self.norm(opt.label)) else { return false }
        }
        guard rows[n].number == n + 1, rows[n + 1].number == n + 2 else { return false }
        let boxed = rows[0...n].map { $0.ticked != nil }
        guard boxed.allSatisfy({ $0 == q.multi }) else { return false }
        return region.contains(Self.norm(q.question))
    }

    func showsDialog(_ set: AskedQuestionSet) -> Bool {
        layout == .review || set.questions.contains { matches($0) }
    }

    func optionTicked(_ i: Int) -> Bool { rows.indices.contains(i) ? (rows[i].ticked ?? false) : false }

    /// The Other row still holds its placeholder (nothing typed, not ticked).
    func otherIsEmpty(_ q: AskedQuestion) -> Bool {
        let n = q.options.count
        guard rows.indices.contains(n) else { return false }
        return rows[n].text.lowercased().hasPrefix(Self.otherPlaceholder) && rows[n].ticked != true
    }

    /// The Other row shows (the start of) `text`.
    func otherShows(_ q: AskedQuestion, _ text: String) -> Bool {
        let n = q.options.count
        guard rows.indices.contains(n), !rows[n].text.lowercased().hasPrefix(Self.otherPlaceholder) else { return false }
        let want = Self.squash(text).prefix(24)
        return Self.squash(rows[n].text).hasPrefix(String(want))
    }

    /// Review shows exactly these answers, with Submit as row 1 and Cancel as row 2.
    func reviewMatches(_ expected: [(question: String, answer: String)]) -> Bool {
        guard layout == .review, !unansweredWarning, rows.count == 2,
              rows[0].text.lowercased().hasPrefix("submit answers"), rows[1].text.lowercased().hasPrefix("cancel") else { return false }
        let want = Self.norm(expected.map { "\($0.question) \($0.answer)" }.joined(separator: " "))
        return reviewText == want
    }
}

// MARK: - The driver

/// What a host can send. Arrow keys are measured on tmux only; elsewhere an
/// ESC split from its "[" could be read as a bare Esc, which cancels the dialog.
struct AnswerKeyCaps: Equatable {
    var arrows: Bool
    static let tmux = AnswerKeyCaps(arrows: true)
    static let plainKeysOnly = AnswerKeyCaps(arrows: false)
}

/// The step driver: given the screen, the next key (or why to stop). It owns
/// no I/O; the executor reads the screen, calls `decide`, checks the session,
/// sends the key, and calls `decide` again with a fresh screen. After a key
/// the driver answers `.wait` until the screen shows its effect, so a key is
/// never repeated because the screen has not caught up.
///
/// It can never produce Esc, a digit above N+1 (that is "Chat about this"),
/// or "2" on Review: those are not reachable from `decide`.
struct AnswerDriver {
    enum Decision: Equatable {
        case send(Keystroke, why: String)
        /// The screen is not (yet) what the plan needs; the executor polls and gives up after a while.
        case wait(String)
        case done
        case abort(String)
    }

    private enum Settle: Equatable {
        case tick(option: Int, to: Bool)
        case cursor(row: Int)
        case cursorNext
        case otherShown
        case left
        case closed
    }

    let asked: AskedQuestionSet
    let answers: [ResolvedAnswer]
    let caps: AnswerKeyCaps
    private(set) var current = 0
    private(set) var keysSent = 0
    private var awaiting: Settle?
    private let expected: [(question: String, answer: String)]

    init(asked: AskedQuestionSet, answers: [ResolvedAnswer], caps: AnswerKeyCaps) {
        self.asked = asked
        self.answers = answers
        self.caps = caps
        expected = AnswerPlan.expectedAnswers(asked, answers)
    }

    static let notFirstMessage = "The terminal isn't showing the first question — answer it at your Mac"
    static let mismatchMessage = "The question on screen isn't the one on your phone — answer it at your Mac"

    /// A single-select with one question submits on its own: no Review screen.
    private var submitsWithoutReview: Bool { asked.questions.count == 1 && !asked.questions[0].multi }

    mutating func decide(screen: String?) -> Decision {
        guard let screen else { return .wait("Couldn't read the terminal") }
        let p = QuestionScreen.parse(screen)
        if p.previewLayout { return .abort(AnswerPlan.previewMessage) }

        if let a = awaiting {
            let q = current < asked.questions.count ? asked.questions[current] : nil
            guard settled(a, p, q) else { return .wait("Waiting for the terminal to catch up") }
            awaiting = nil
            switch a {
            case .left: current += 1
            case .closed: return .done
            default: break
            }
        }
        if current >= asked.questions.count { return review(p) }
        return question(p)
    }

    private func settled(_ a: Settle, _ p: QuestionScreen, _ q: AskedQuestion?) -> Bool {
        switch a {
        case .tick(let option, let to): return q.map { p.matches($0) && p.optionTicked(option) == to } ?? false
        case .cursor(let row): return q.map { p.matches($0) && p.cursor == .row(row) } ?? false
        case .cursorNext: return q.map { p.matches($0) && p.cursor == .next } ?? false
        case .otherShown:
            guard let q, p.matches(q), let o = answers[current].other else { return false }
            return p.otherShows(q, o)
        case .left: return q.map { !p.matches($0) } ?? false
        case .closed: return !p.showsDialog(asked)
        }
    }

    private mutating func send(_ key: Keystroke, _ settle: Settle, _ why: String) -> Decision {
        awaiting = settle
        keysSent += 1
        return .send(key, why: why)
    }

    private mutating func question(_ p: QuestionScreen) -> Decision {
        let q = asked.questions[current]
        let a = answers[current]
        let n = q.options.count
        guard p.matches(q) else {
            return .wait(current == 0 && keysSent == 0 ? Self.notFirstMessage : Self.mismatchMessage)
        }
        // After this question the dialog goes to the next, to Review, or (one single-select) closes.
        let leave: Settle = submitsWithoutReview ? .closed : .left

        // Digits mean "that option" only with the cursor on a real option row.
        func onOption() -> Bool { if case .row(let c) = p.cursor { return (1...n).contains(c) }; return false }
        func cursorRow() -> Int? { if case .row(let c) = p.cursor { return c }; return nil }

        if !q.multi {
            if let other = a.other {
                if p.cursor == .row(n + 1) {
                    if p.otherIsEmpty(q) { return send(.text(other), .otherShown, "Type the Other answer") }
                    guard p.otherShows(q, other) else { return .abort("The Other field holds different text — answer at your Mac") }
                    return send(.enter, leave, "Submit the Other answer")
                }
                guard onOption() else { return cursorProblem(p) }
                guard p.otherIsEmpty(q) else { return .abort("The Other field already has text — answer at your Mac") }
                return send(.text(String(n + 1)), .cursor(row: n + 1), "Focus the Other row")
            }
            guard onOption() else { return cursorProblem(p) }
            return send(.text(String(a.picks[0] + 1)), leave, "Pick option \(a.picks[0] + 1)")
        }

        // Multi-select: make every tick match first, from what is on screen.
        for j in 0..<n where p.optionTicked(j) != a.picks.contains(j) {
            guard onOption() else { return cursorProblem(p) }
            return send(.text(String(j + 1)), .tick(option: j, to: !p.optionTicked(j)), "Toggle option \(j + 1)")
        }
        guard let other = a.other else {
            if p.rows[n].ticked == true { return .abort("Other is already ticked — answer at your Mac") }
            if onOption() { return send(.key(.tab), .left, "Next question") }
            if p.cursor == .next { return send(.enter, .left, "Next question") }
            return cursorProblem(p)
        }
        if p.otherIsEmpty(q) {
            if p.cursor == .row(n + 1) { return send(.text(other), .otherShown, "Type the Other answer") }
            guard caps.arrows else { return .abort(AnswerPlan.arrowsMessage) }
            guard let c = cursorRow(), c <= n else { return cursorProblem(p) }
            return send(.key(.down), .cursor(row: c + 1), "Move to the Other row")
        }
        guard p.otherShows(q, other) else { return .abort("The Other field holds different text — answer at your Mac") }
        if p.cursor == .row(n + 1) { return send(.key(.tab), .cursorNext, "Move to Next") }
        if p.cursor == .next { return send(.enter, .left, "Next question") }
        return cursorProblem(p)
    }

    private func cursorProblem(_ p: QuestionScreen) -> Decision {
        p.cursor == .none ? .wait("Can't see the cursor in the question") : .abort("The cursor isn't on an answer row — answer at your Mac")
    }

    private mutating func review(_ p: QuestionScreen) -> Decision {
        guard p.layout == .review else {
            if submitsWithoutReview, !p.showsDialog(asked) { return .done }
            return .wait("Waiting for the Review screen")
        }
        guard p.reviewMatches(expected) else {
            return .abort("The Review screen doesn't match your answers — nothing was submitted; check it at your Mac")
        }
        return send(.text("1"), .closed, "Submit the answers")
    }
}

// MARK: - The loop

/// Runs a driver against a terminal: read the screen, ask the driver, send
/// one key, repeat. Every I/O is a closure, so the live executor and the
/// tests (a simulated dialog) run the same loop.
enum AnswerLoop {
    enum Result: Equatable {
        case submitted
        case aborted(String)
    }

    /// How a run ended, and how many keys were really typed (a key the host refused isn't one).
    struct Run: Equatable {
        let result: Result
        let typed: Int
    }

    static let maxKeys = 60
    /// How long a screen may fail to show what the driver expects before the run stops.
    static let waitLimit: TimeInterval = 1.5
    /// Under the phone's 20 s result timeout together with the 4 s read-back, so the phone never
    /// says "no answer" while keys are still going in.
    static let overallLimit: TimeInterval = 12
    static let pollInterval: TimeInterval = 0.1

    /// `send` returns nil once the key is typed, or the reason it was not (a
    /// failed precheck, a host that can't type it). `sleep` and `now` are
    /// injected for tests.
    static func run(_ driver: inout AnswerDriver,
                    readScreen: () -> String?,
                    send: (Keystroke) -> String?,
                    sleep: (TimeInterval) -> Void = { usleep(useconds_t($0 * 1_000_000)) },
                    now: () -> Date = Date.init) -> Run {
        let start = now()
        var waitingSince: Date?
        var typed = 0
        while true {
            if now().timeIntervalSince(start) > overallLimit { return Run(result: .aborted("This took too long — finish at your Mac"), typed: typed) }
            switch driver.decide(screen: readScreen()) {
            case .done:
                return Run(result: .submitted, typed: typed)
            case .abort(let why):
                return Run(result: .aborted(why), typed: typed)
            case .wait(let why):
                let since = waitingSince ?? now()
                waitingSince = since
                if now().timeIntervalSince(since) > waitLimit { return Run(result: .aborted(why), typed: typed) }
                sleep(pollInterval)
            case .send(let key, _):
                waitingSince = nil
                if typed >= maxKeys { return Run(result: .aborted("Too many keys — finish at your Mac"), typed: typed) }
                if let why = send(key) { return Run(result: .aborted(why), typed: typed) }
                typed += 1
                sleep(0.05)
            }
        }
    }
}

// MARK: - Checking what Claude received

enum AnswerReceipt {
    enum Outcome: Equatable {
        /// Claude received exactly these answers.
        case matched
        /// Claude received other answers (a Claude Code quirk, or something moved).
        case different([String: String])
        /// The dialog was rejected (Esc, Cancel, "Chat about this").
        case rejected
        case notFound
    }

    /// Reads `toolUseResult.answers` of the user record that answers `toolUseId`
    /// in transcript text (JSONL), and compares it with what was asked for.
    static func outcome(transcript text: String, toolUseId: String, expected: [(question: String, answer: String)]) -> Outcome {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard line.first == "{", line.contains(toolUseId),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "user",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]],
                  let result = content.first(where: { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == toolUseId })
            else { continue }
            guard result["is_error"] as? Bool != true, let tur = obj["toolUseResult"] as? [String: Any], tur["answers"] != nil else { return .rejected }
            // An answers value of a shape Page doesn't know (say a future array) was still received by Claude: unconfirmed, not dismissed.
            guard let got = tur["answers"] as? [String: String] else { return .notFound }
            let want = Dictionary(expected.map { ($0.question, QuestionScreen.norm($0.answer)) }, uniquingKeysWith: { a, _ in a })
            let have = got.mapValues(QuestionScreen.norm)
            return want == have ? .matched : .different(got)
        }
        return .notFound
    }
}
