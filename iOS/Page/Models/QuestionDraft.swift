import Foundation

// Answering the terminal's questions from the phone.
//
// When a Claude session is blocked on an AskUserQuestion dialog, the Mac puts
// the questions on that session's list row (`ask`). The person ticks answers
// here, one question at a time, reviews them all, and submits once; the Mac
// replays them into the dialog (docs/SESSIONS-PROTOCOL.md §5 "Answering a question"), checking the
// screen before every key. Nothing is typed until "Submit all".
//
//   SessionAsk     the questions as the Mac sent them (redacted, clipped)
//   AnswerSheet    the draft: ticks, Other text, which step, Back / Next,
//                  review, `canSubmit`, the wire encoding, the delivery preview
//
// Foundation-only, so the logic tests cover all of it.

// MARK: - The ask (Mac → phone)

struct AskOption: Equatable, Hashable {
    let label: String
    let detail: String
}

struct AskQuestion: Equatable, Hashable {
    let text: String
    /// The short tab name ("Color"); empty when the question had none.
    let header: String
    let multi: Bool
    let options: [AskOption]
}

struct SessionAsk: Equatable, Hashable, Identifiable {
    /// The tool_use id of the question on screen: sent back with the answers,
    /// so the Mac refuses if it is no longer the one showing.
    let id: String
    let questions: [AskQuestion]
    /// Some option has a preview: a layout the Mac won't drive.
    let hasPreview: Bool

    static let maxQuestions = 4
    static let maxOptions = 7

    /// The phone can offer the picker (a preview layout is answered at the Mac).
    var isAnswerable: Bool { !hasPreview && !questions.isEmpty }
}

extension SessionAsk: Decodable {
    private enum CodingKeys: String, CodingKey { case id, questions, hasPreview }
    private struct RawOption: Decodable {
        let label: String?
        let description: String?
    }
    private struct RawQuestion: Decodable {
        let question: String?
        let header: String?
        let multi: Bool?
        let options: [RawOption]?
    }

    /// Strict about shape (a malformed `ask` is dropped whole, and the session
    /// simply has no picker), lenient about extras.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id).trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = try c.decode([RawQuestion].self, forKey: .questions)
        func bad(_ why: String) -> DecodingError { .dataCorruptedError(forKey: .questions, in: c, debugDescription: why) }
        guard !id.isEmpty, id.count <= 128 else { throw bad("Bad ask id") }
        guard !raw.isEmpty, raw.count <= Self.maxQuestions else { throw bad("Bad question count") }
        var out: [AskQuestion] = []
        for q in raw {
            let text = (q.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let opts = q.options, !opts.isEmpty, opts.count <= Self.maxOptions else { throw bad("Bad question") }
            var options: [AskOption] = []
            for o in opts {
                let label = (o.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { throw bad("Bad option") }
                options.append(AskOption(label: String(label.prefix(160)),
                                         detail: String((o.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))))
            }
            out.append(AskQuestion(text: String(text.prefix(500)),
                                   header: String((q.header ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)),
                                   multi: q.multi ?? false, options: options))
        }
        self.id = id
        questions = out
        hasPreview = (try? c.decodeIfPresent(Bool.self, forKey: .hasPreview)) ?? false
    }
}

// MARK: - One answer on the wire (phone → Mac)

/// One question's answer: 0-based option indices and the "Other" text. The
/// Mac matches indices against its own raw copy of the question.
struct AnswerWire: Equatable {
    let question: Int
    let picks: [Int]
    let other: String?

    var json: [String: Any] {
        var o: [String: Any] = ["i": question, "picks": picks]
        if let other { o["other"] = other }
        return o
    }
}

// MARK: - The draft

/// The answers being picked: a pure state machine behind the question card.
/// A single-select tick is exclusive (with Other) and moves on at once; a
/// multi-select ticks any number and has a Next button; Other opens a text
/// field. A last step lists every answer and offers "Submit all", enabled
/// only once every question is answered with a real choice.
struct AnswerSheet: Equatable {
    enum Step: Equatable, Hashable {
        case question(Int)
        case review
    }

    let ask: SessionAsk
    /// False when the answers travel as text through Claude's question hook (a page the hook is
    /// holding): the hook can map an option number, not free text, so there is no Other.
    let allowsOther: Bool
    private(set) var step: Step = .question(0)
    private(set) var picks: [Set<Int>]
    /// nil: Other isn't chosen. "" : chosen, nothing typed yet.
    private(set) var other: [String?]

    static let maxOtherChars = 300

    init(ask: SessionAsk, allowsOther: Bool = true) {
        self.ask = ask
        self.allowsOther = allowsOther
        picks = Array(repeating: [], count: ask.questions.count)
        other = Array(repeating: nil, count: ask.questions.count)
    }

    // MARK: reading

    var count: Int { ask.questions.count }

    /// The question being asked, nil on the review step.
    var currentIndex: Int? { if case .question(let i) = step { return i } else { return nil } }
    var current: AskQuestion? { currentIndex.map { ask.questions[$0] } }
    var isReview: Bool { step == .review }

    func isPicked(_ q: Int, option: Int) -> Bool { picks.indices.contains(q) && picks[q].contains(option) }

    func otherChosen(_ q: Int) -> Bool { other.indices.contains(q) && other[q] != nil }

    func otherText(_ q: Int) -> String { other.indices.contains(q) ? (other[q] ?? "") : "" }

    private func typedOther(_ q: Int) -> String? {
        let t = otherText(q).trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Answered with a real choice: an option, or Other with text.
    func isAnswered(_ q: Int) -> Bool {
        guard picks.indices.contains(q) else { return false }
        return !picks[q].isEmpty || typedOther(q) != nil
    }

    /// Other is chosen but still empty: it can't be sent, and says so.
    func otherNeedsText(_ q: Int) -> Bool { otherChosen(q) && typedOther(q) == nil }

    var answeredCount: Int { (0..<count).filter(isAnswered).count }
    var allAnswered: Bool { answeredCount == count }
    var canSubmit: Bool { allAnswered && !(0..<count).contains(where: otherNeedsText) }

    /// A step can be opened when every question before it is answered.
    func isReachable(_ q: Int) -> Bool { q >= 0 && q < count && (0..<q).allSatisfy(isAnswered) }

    /// The answer as the review and the receipt read it: option labels in
    /// option order, then the Other text.
    func answerText(_ q: Int) -> String {
        let question = ask.questions[q]
        var parts = picks[q].sorted().map { question.options[$0].label }
        if let t = typedOther(q) { parts.append(t) }
        return parts.joined(separator: ", ")
    }

    // MARK: acting

    /// Ticks option `option` of the current question. A single-select picks it
    /// (clearing Other) and moves on; a multi-select toggles it. Returns whether
    /// the step changed.
    @discardableResult
    mutating func tap(option: Int) -> Bool {
        guard case .question(let q) = step, option >= 0, option < ask.questions[q].options.count else { return false }
        if ask.questions[q].multi {
            if picks[q].contains(option) { picks[q].remove(option) } else { picks[q].insert(option) }
            return false
        }
        picks[q] = [option]
        other[q] = nil
        advance(from: q)
        return true
    }

    /// Opens the Other text field. In a single-select it replaces any ticked
    /// option; in a multi-select it toggles (closing it forgets the text).
    mutating func toggleOther() {
        guard allowsOther, case .question(let q) = step else { return }
        if ask.questions[q].multi {
            other[q] = other[q] == nil ? "" : nil
        } else {
            picks[q] = []
            other[q] = other[q] ?? ""
        }
    }

    /// The Other text, as one line (a newline would be a key on the Mac).
    mutating func setOther(_ text: String) {
        guard case .question(let q) = step, other[q] != nil else { return }
        let oneLine = text.components(separatedBy: .newlines).joined(separator: " ")
        other[q] = String(oneLine.prefix(Self.maxOtherChars))
    }

    /// Return in the Other field: a single-select with text moves on.
    @discardableResult
    mutating func commitOther() -> Bool {
        guard case .question(let q) = step, !ask.questions[q].multi, typedOther(q) != nil else { return false }
        advance(from: q)
        return true
    }

    /// Next (multi-select): only once the question is answered.
    @discardableResult
    mutating func next() -> Bool {
        guard case .question(let q) = step, isAnswered(q), !otherNeedsText(q) else { return false }
        advance(from: q)
        return true
    }

    /// Back one step; from the review, the last question.
    mutating func back() {
        switch step {
        case .question(let q): if q > 0 { step = .question(q - 1) }
        case .review: step = .question(count - 1)
        }
    }

    /// The progress strip: open question `q` (never past an unanswered one).
    mutating func go(to q: Int) {
        guard isReachable(q) else { return }
        step = .question(q)
    }

    /// The strip's last stop.
    mutating func goToReview() {
        guard canSubmit else { return }
        step = .review
    }

    /// After answering `q`: the next unanswered question, else the review.
    private mutating func advance(from q: Int) {
        if let next = ((q + 1)..<count).first(where: { !isAnswered($0) }) ?? (0..<q).first(where: { !isAnswered($0) }) {
            step = .question(next)
        } else {
            step = .review
        }
    }

    // MARK: sending

    /// What goes to the Mac. nil until every question has a real answer.
    func wire() -> [AnswerWire]? {
        guard canSubmit else { return nil }
        return (0..<count).map { q in
            AnswerWire(question: q, picks: picks[q].sorted(), other: typedOther(q))
        }
    }

    /// The review step's rows.
    func reviewRows() -> [(index: Int, header: String, question: String, answer: String)] {
        (0..<count).map { q in
            let question = ask.questions[q]
            return (q, question.header.isEmpty ? "Question \(q + 1)" : question.header, question.text,
                    isAnswered(q) ? answerText(q) : "Not answered")
        }
    }

    /// "Will choose Green; Ham, Corn · cmux › page · Studio MBP": exactly what will be pressed, where.
    /// Through the hook nothing is pressed: "Will answer through Claude's question hook: Green; Ham, Corn · Studio MBP".
    func previewLine(route: String?, mac: String, viaHook: Bool = false) -> String {
        let chosen = (0..<count).map { isAnswered($0) ? answerText($0) : "—" }.joined(separator: "; ")
        let clipped = chosen.count > 160 ? String(chosen.prefix(159)) + "…" : chosen
        if viaHook { return DeliveryPreview.line("Will answer through Claude's question hook: \(clipped)", route: nil, mac: mac) }
        return DeliveryPreview.line("Will choose \(clipped)", route: route, mac: mac)
    }

    /// The reply text for a page Claude's question hook is holding: one line per question, the 1-based
    /// option number (several, comma-separated, for a multi-select). The hook maps numbers to labels
    /// (`map_answers` in hooks/page-notify.sh), so a label with a comma can't be misread. nil until
    /// every question is answered with an option (the hook can't take Other text), and only for a sheet
    /// made for the hook (`allowsOther` false).
    func hookReply() -> String? {
        guard !allowsOther, canSubmit, (0..<count).allSatisfy({ !picks[$0].isEmpty }) else { return nil }
        return (0..<count).map { q in picks[q].sorted().map { String($0 + 1) }.joined(separator: ", ") }.joined(separator: "\n")
    }

    /// The same, for the receipt under a delivered answer.
    var summaryLine: String { (0..<count).map { isAnswered($0) ? answerText($0) : "—" }.joined(separator: "; ") }
}

// MARK: - Whether to offer the picker

enum AnswerPicker {
    /// The session's question, when the phone should offer the picker for the
    /// page it shows: the Mac sent one (so it accepts answers), the page is a
    /// question, and it can be answered by key (no previews).
    ///
    /// `hook`: the page is one Claude's question hook holds. There is no dialog on screen then (the
    /// session reads working), the answers go as text through the hook, and the Mac sent `ask` because
    /// the hook wrote the call to the transcript first. The hook applies option numbers by position to
    /// ITS question, so the page's own text (`pageContext`) must show the very questions this `ask` has:
    /// otherwise a stale `ask` (the previous question) could pick the wrong options. No match, no picker.
    ///
    /// A key-driven answer needs a terminal Page can type into (`canType`), as for any typed message.
    static func ask(for session: LiveSession?, pageIsQuestion: Bool, hook: Bool = false, pageContext: String? = nil) -> SessionAsk? {
        guard pageIsQuestion, let ask = session?.ask, ask.isAnswerable else { return nil }
        if hook { return hookPageMatches(ask: ask, context: pageContext) ? ask : nil }
        guard session?.state.isWaiting == true, session?.canType == true else { return nil }
        return ask
    }

    /// True when the hook page's text carries every question and option of `ask` (compared loosely:
    /// case and spacing ignored, long text by its start, since the hook clips what it sends).
    static func hookPageMatches(ask: SessionAsk, context: String?) -> Bool {
        guard let context else { return false }
        func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        let page = norm(context)
        for q in ask.questions {
            guard page.contains(String(norm(q.text).prefix(60))) else { return false }
            for o in q.options where !page.contains(String(norm(o.label).prefix(40))) { return false }
        }
        return true
    }

    /// Where "Submit all" goes. A page Claude's question hook holds takes numbers as text, which the hook
    /// maps (nothing is pressed); anything else is the Mac's `answer` command, which presses the keys.
    enum Submit: Equatable {
        case hook(String)
        case keys
        /// Nothing is sent; say why.
        case refuse(String)
    }

    static func submit(viaHook: Bool, hasPage: Bool, sheet: AnswerSheet) -> Submit {
        guard viaHook else { return .keys }
        guard hasPage else { return .refuse("This prompt's page isn't loaded yet, so nothing was sent.") }
        guard let text = sheet.hookReply() else { return .refuse("Pick an option for every question first, so nothing was sent.") }
        return .hook(text)
    }

    /// A page's own delivery outcome (the hook path has no `answer` command) as the card's delivery state.
    static func delivery(from outcome: CardOutcome, sessionId: String, promptKey: String, now: Date) -> SentSessionCommand? {
        let state: SessionDeliveryState
        switch outcome {
        case .none: return nil
        case .arming, .sending: state = .sending
        case .delivered(let detail): state = .typed(detail)
        case .problem(let why): state = .failed(why)
        }
        return SentSessionCommand(clientId: "page-\(promptKey)", sessionId: sessionId, kind: .answer, text: "", sentAt: now, state: state,
                                  promptKey: promptKey)
    }

    /// Where an answer stands: the newest `answer` sent for this very question.
    static func delivery(_ commands: [SentSessionCommand], sessionId: String, promptKey: String) -> SentSessionCommand? {
        commands.filter { $0.kind == .answer && $0.sessionId == sessionId && $0.promptKey == promptKey }.max { $0.sentAt < $1.sentAt }
    }
}
