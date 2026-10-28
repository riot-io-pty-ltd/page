import Foundation

// Does Claude's last message end by asking the user a plain yes/no question
// ("Should I go ahead and commit?")? If so the room and the review sheet
// offer two taps, Yes and No, which send exactly those words through the same
// path a typed message takes.
//
// Pure, and deliberately conservative: a false negative only costs the user a
// keyboard, a false positive puts words in their mouth. So it only says yes
// for a question that is the very last sentence of the very last line, that
// opens with a recognised auxiliary ("should I", "do you want me to", "want
// me to", "ready to", "sound good"), and that is not an open question (what,
// which, how …), a choice ("A or B?", "A vs B?"), one of two questions on
// the line, an "anything else?" closer, a list item, a quote or code.
//
// The same steps, word lists and answers as the Android app
// (`model/YesNoQuestion.kt`); the table in `YesNoQuestionTest.kt` and in
// `LogicTests.swift` is the same strings with the same expected results.
// Change one and change the other. Plain string steps, no regular
// expressions: ICU and Java disagree about the edges.

enum YesNoQuestion {
    /// The longest sentence worth asking about. Beyond it the "question" is a paragraph.
    static let maxSentence = 300

    /// The final question of `message`, as a sentence ("Should I run the tests?"), when it is a plain yes/no one. Nil otherwise.
    static func detect(_ message: String) -> String? {
        guard let sentence = lastSentence(message) else { return nil }
        return isYesNo(sentence) ? sentence : nil
    }

    /// What the room offers Yes and No for: the question the story ends on. The latest thing in the story must be
    /// Claude's message (a tool step, a note, or anything the user sent after it means the moment has passed). Pure.
    static func endingStory(_ items: [TranscriptTimeline.Item]) -> String? {
        guard case .entry(let entry, _)? = items.last, entry.role == .assistant else { return nil }
        return detect(entry.text)
    }

    /// Words for a screen reader's hint: the question, shortened.
    static func brief(_ question: String, limit: Int = 90) -> String {
        let t = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > limit else { return t }
        return String(t.prefix(limit - 1)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    // MARK: Finding the sentence

    private static func isSpace(_ c: Character) -> Bool { c == " " || c == "\t" }

    /// The text after the last sentence boundary in the last non-blank line, when that line is a question and is plain prose.
    static func lastSentence(_ message: String) -> String? {
        let lines = message.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        // Walk the lines tracking fences: the last non-blank line must be prose, not code or a fence.
        var inFence = false
        var last: String?
        var lastIsProse = false
        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("```") || t.hasPrefix("~~~") {
                inFence.toggle()
                if !t.isEmpty { last = t; lastIsProse = false }
                continue
            }
            if t.isEmpty { continue }
            last = t
            lastIsProse = !inFence
        }
        if inFence || !lastIsProse { return nil }
        guard var line = last else { return nil }
        // A list item, heading or quote is part of something bigger: not a standalone question.
        if isStructural(line) { return nil }
        // Emphasis around the whole line ("**Should I commit?**") is not part of the question.
        let emphasis: Set<Character> = ["*", "_", "~"]
        while let c = line.last, emphasis.contains(c) || isSpace(c) { line.removeLast() }
        while let c = line.first, emphasis.contains(c) { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !line.hasSuffix("?") { return nil }
        // Unbalanced quotes or inline code: the question may be inside one.
        if line.filter({ $0 == "\"" }).count % 2 != 0 || line.filter({ $0 == "`" }).count % 2 != 0 { return nil }
        if line.contains(where: { $0 == "\u{201C}" || $0 == "\u{201D}" }) { return nil }
        // Drop the run of question marks, then walk back to the sentence start.
        var body = Array(line)
        while let c = body.last, c == "?" { body.removeLast() }
        if body.isEmpty { return nil }
        var start = 0
        var i = body.count - 1
        while i >= 0 {
            let c = body[i]
            let next: Character = i + 1 < body.count ? body[i + 1] : " "
            let boundary: Bool
            switch c {
            case ".", "!", "?", ":", ";": boundary = isSpace(next)
            case "—", "–", "…": boundary = true
            case "-": boundary = next == " " && i > 0 && body[i - 1] == " "
            default: boundary = false
            }
            // A second question just before it ("Should I test? Should I commit?"): one Yes cannot answer both.
            if boundary { if c == "?" { return nil }; start = i + 1; break }
            i -= 1
        }
        let sentence = String(body[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if sentence.isEmpty || sentence.count > maxSentence { return nil }
        // The marks went with the run: put one back, so the sentence reads as the question it is.
        return sentence + "?"
    }

    private static func isStructural(_ line: String) -> Bool {
        let chars = Array(line)
        guard let first = chars.first else { return false }
        if first == "#" || first == ">" || first == "|" { return true }
        if chars.count >= 2, chars[1] == " ", first == "-" || first == "*" || first == "+" || first == "•" { return true }
        var d = 0
        while d < chars.count, chars[d] >= "0", chars[d] <= "9" { d += 1 }
        return (1...3).contains(d) && d + 1 < chars.count && (chars[d] == "." || chars[d] == ")") && chars[d + 1] == " "
    }

    // MARK: Reading it

    private static let openQuestion: Set<String> = ["what", "which", "how", "why", "where", "when", "who", "whom", "whose", "whether"]
    /// A choice between things ("A or B?", "A vs B?"): neither Yes nor No answers it.
    private static let choice: Set<String> = ["or", "either", "vs", "versus"]
    private static let fillersAlways: Set<String> = ["so", "and", "now", "also", "then"]
    private static let fillersComma: Set<String> = ["ok", "okay", "alright", "great", "cool", "perfect", "done", "sure", "right", "anyway", "btw"]
    private static let subject: Set<String> = ["i", "we"]
    private static let wantVerbs: Set<String> = ["want", "wish", "like", "need"]
    private static let agreeable: Set<String> = ["ok", "okay", "fine", "good", "alright", "right", "correct"]
    private static let ready: Set<String> = ["ready", "happy", "ok", "okay", "good", "fine"]

    /// The words of a sentence: lowercase, apostrophes straightened, edge punctuation off, "'s" dropped.
    static func words(_ sentence: String) -> [String] {
        var out: [String] = []
        for raw in sentence.replacingOccurrences(of: "\u{2019}", with: "'").split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " || $0 == "\t" }) {
            var chars = Array(raw.lowercased())
            while let c = chars.first, !(c.isLetter || c.isNumber) { chars.removeFirst() }
            while let c = chars.last, !(c.isLetter || c.isNumber) { chars.removeLast() }
            var w = String(chars)
            if w.hasSuffix("'s") { w = String(w.dropLast(2)) }
            if !w.isEmpty { out.append(w) }
        }
        return out
    }

    static func isYesNo(_ sentence: String) -> Bool {
        // "Ok, should I …" and "So do you want me to …": the lead-in is not the question.
        var body = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix("?") { body.removeLast() }
        var raw = body.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        while raw.count > 1 {
            let t = raw[0].lowercased()
            if fillersAlways.contains(t) || (t.hasSuffix(",") && fillersComma.contains(String(t.dropLast()))) { raw.removeFirst() } else { break }
        }
        let w = words(raw.joined(separator: " "))
        if w.isEmpty { return false }
        // Open questions and choices are not yes/no, wherever the word sits ("Should I commit, and with which message?").
        if w.contains(where: { openQuestion.contains($0) || choice.contains($0) }) { return false }
        // "Anything else?" and "any other changes?": a bare Yes answers nothing, the user has to say what.
        if w.contains(where: { $0 == "anything" || $0 == "else" }) || zip(w, w.dropFirst()).contains(where: { $0 == "any" && $1 == "other" }) { return false }
        func at(_ i: Int) -> String { i < w.count ? w[i] : "" }
        switch at(0) {
        case "should", "shall", "can", "could", "may":
            return subject.contains(at(1))
        case "do", "does", "did":
            if at(1) == "you" { return wantVerbs.contains(at(2)) }
            if ["that", "this", "it"].contains(at(1)) { return ["sound", "sounds", "work", "works", "look", "looks"].contains(at(2)) }
            return false
        case "would":
            if at(1) == "you" { return at(2) == "like" || at(2) == "want" }
            if at(1) == "it" || at(1) == "that" { return at(2) == "be" && agreeable.contains(at(3)) }
            return false
        case "is":
            return ["that", "it", "this"].contains(at(1)) && agreeable.contains(at(2))
        case "are":
            return (at(1) == "you" && ready.contains(at(2))) || (at(1) == "we" && ready.contains(at(2)))
        case "want": return at(1) == "me" && at(2) == "to"
        case "ok", "okay": return at(1) == "to"
        case "ready": return at(1) == "to" || at(1) == "for"
        case "sound", "sounds": return agreeable.contains(at(1))
        case "proceed": return true
        case "go": return at(1) == "ahead"
        default: return false
        }
    }
}

// MARK: - Where it is offered

/// The two replies, and the rules for when a screen offers them. One pure
/// decision per screen, so the room, the review sheet and the Steer box agree
/// (and agree with Android).
enum YesNoReply {
    static let yes = "Yes"
    static let no = "No"

    /// The room: the session is idle and takes a plain next message (no prompt, no question picker, Mac
    /// reachable), and the last thing in its story is Claude's message ending on a yes/no question. Anything after
    /// that message (a tool step, the user's own reply, a message just sent from here) takes the offer away.
    static func roomOffer(mode: RoomComposerMode, state: LiveSessionState, ended: Bool, ready: Bool, hasAsk: Bool,
                          items: [TranscriptTimeline.Item]) -> String? {
        guard !ended, ready, mode == .nextTask, state == .idle, !hasAsk else { return nil }
        return YesNoQuestion.endingStory(items)
    }

    /// A finished-turn page (the review sheet): the page's question, when it takes a written reply (the same path
    /// as Steer, so the same gate decides) and nothing is on its way.
    static func reviewOffer(question: String?, takesReply: Bool, open: Bool) -> String? {
        takesReply && open ? question : nil
    }
}
