package app.page.android.model

// Port of iOS/Page/Models/YesNoQuestion.swift. Does Claude's last message end by asking the user a plain
// yes/no question ("Should I go ahead and commit?")? If so the room and the review sheet offer two taps, Yes
// and No, which send exactly those words through the same path a typed message takes.
//
// Pure, and deliberately conservative: a false negative only costs the user a keyboard, a false positive puts
// words in their mouth. So it only says yes for a question that is the very last sentence of the very last
// line, that opens with a recognised auxiliary ("should I", "do you want me to", "want me to", "ready to",
// "sound good"), and that is not an open question (what, which, how...), a choice ("A or B?", "A vs B?"), one of
// two questions on the line, an "anything else?" closer, a list item, a quote or code. The same words and the same answers as the Swift version; the shared vectors pin both.

object YesNoQuestion {
    /** The longest sentence worth asking about. Beyond it the "question" is a paragraph. */
    const val MAX_SENTENCE = 300

    /** The final question of [message], as a sentence ("Should I run the tests?"), when it is a plain yes/no one. Null otherwise. */
    fun detect(message: String): String? {
        val sentence = lastSentence(message) ?: return null
        return if (isYesNo(sentence)) sentence else null
    }

    /**
     * What the room offers Yes and No for: the question the story ends on. The latest thing in the story must be Claude's
     * message (a tool step, a note, or anything the user sent after it means the moment has passed). Pure.
     */
    fun endingStory(items: List<TranscriptTimeline.Item>): String? {
        val last = items.lastOrNull() as? TranscriptTimeline.Item.Entry ?: return null
        return if (last.entry.role == TranscriptRole.ASSISTANT) detect(last.entry.text) else null
    }

    /** Words for a screen reader's hint: the question, shortened. */
    fun brief(question: String, limit: Int = 90): String {
        val t = question.trim()
        return if (t.length <= limit) t else t.take(limit - 1).trimEnd() + "…"
    }

    // MARK: - Finding the sentence

    /** The text after the last sentence boundary in the last non-blank line, when that line is a question and is plain prose. */
    internal fun lastSentence(message: String): String? {
        val lines = message.replace("\r\n", "\n").replace('\r', '\n').split("\n")
        // Walk the lines tracking fences: the last non-blank line must be prose, not code or a fence.
        var inFence = false
        var last: String? = null
        var lastIsProse = false
        for (raw in lines) {
            val t = raw.trim()
            if (t.startsWith("```") || t.startsWith("~~~")) { inFence = !inFence; if (t.isNotEmpty()) { last = t; lastIsProse = false }; continue }
            if (t.isEmpty()) continue
            last = t
            lastIsProse = !inFence
        }
        if (inFence || !lastIsProse) return null
        var line = last ?: return null
        // A list item, heading or quote is part of something bigger: not a standalone question.
        if (isStructural(line)) return null
        // Emphasis around the whole line ("**Should I commit?**") is not part of the question.
        line = line.trimEnd { it == '*' || it == '_' || it == '~' || it == ' ' || it == '\t' }.trimStart { it == '*' || it == '_' || it == '~' }.trim()
        if (!line.endsWith("?")) return null
        // Unbalanced quotes or inline code: the question may be inside one.
        if (line.count { it == '"' } % 2 != 0 || line.count { it == '`' } % 2 != 0) return null
        if (line.any { it == '“' || it == '”' }) return null
        // Drop the run of question marks, then walk back to the sentence start.
        var end = line.length
        while (end > 0 && line[end - 1] == '?') end--
        if (end == 0) return null
        val body = line.substring(0, end)
        var start = 0
        var i = body.length - 1
        while (i >= 0) {
            val c = body[i]
            val next = if (i + 1 < body.length) body[i + 1] else ' '
            val boundary = when (c) {
                '.', '!', '?', ':', ';' -> next == ' ' || next == '\t'
                '—', '–', '…' -> true
                '-' -> next == ' ' && i > 0 && body[i - 1] == ' '
                else -> false
            }
            // A second question just before it ("Should I test? Should I commit?"): one Yes cannot answer both.
            if (boundary) { if (c == '?') return null; start = i + 1; break }
            i--
        }
        val sentence = body.substring(start).trim()
        if (sentence.isEmpty() || sentence.length > MAX_SENTENCE) return null
        // The marks went with the run: put one back, so the sentence reads as the question it is.
        return "$sentence?"
    }

    private fun isStructural(line: String): Boolean {
        if (line.startsWith("#") || line.startsWith(">") || line.startsWith("|")) return true
        if (line.length >= 2 && line[1] == ' ' && (line[0] == '-' || line[0] == '*' || line[0] == '+' || line[0] == '•')) return true
        var d = 0
        while (d < line.length && line[d] in '0'..'9') d++
        return d in 1..3 && d + 1 < line.length && (line[d] == '.' || line[d] == ')') && line[d + 1] == ' '
    }

    // MARK: - Reading it

    private val openQuestion = setOf("what", "which", "how", "why", "where", "when", "who", "whom", "whose", "whether")
    /** A choice between things ("A or B?", "A vs B?"): neither Yes nor No answers it. */
    private val choice = setOf("or", "either", "vs", "versus")
    private val fillersAlways = setOf("so", "and", "now", "also", "then")
    private val fillersComma = setOf("ok", "okay", "alright", "great", "cool", "perfect", "done", "sure", "right", "anyway", "btw")
    private val subject = setOf("i", "we")
    private val wantVerbs = setOf("want", "wish", "like", "need")
    private val agreeable = setOf("ok", "okay", "fine", "good", "alright", "right", "correct")
    private val ready = setOf("ready", "happy", "ok", "okay", "good", "fine")

    /** The words of a sentence: lowercase, apostrophes straightened, edge punctuation off, "'s" dropped. */
    internal fun words(sentence: String): List<String> {
        val out = ArrayList<String>()
        for (raw in sentence.replace('’', '\'').split(' ', '\t')) {
            var w = raw.lowercase().trim { !it.isLetterOrDigit() }
            if (w.endsWith("'s")) w = w.dropLast(2)
            if (w.isNotEmpty()) out.add(w)
        }
        return out
    }

    internal fun isYesNo(sentence: String): Boolean {
        // "Ok, should I..." and "So do you want me to...": the lead-in is not the question.
        val raw = sentence.trim().removeSuffix("?").trim().split(' ', '\t').filter { it.isNotEmpty() }.toMutableList()
        while (raw.size > 1) {
            val t = raw[0].lowercase()
            if (t in fillersAlways || (t.endsWith(",") && t.dropLast(1) in fillersComma)) raw.removeAt(0) else break
        }
        val w = words(raw.joinToString(" "))
        if (w.isEmpty()) return false
        // Open questions and choices are not yes/no, wherever the word sits ("Should I commit, and with which message?").
        if (w.any { it in openQuestion || it in choice }) return false
        // "Anything else?" and "any other changes?": a bare Yes answers nothing, the user has to say what.
        if (w.any { it == "anything" || it == "else" } || w.zipWithNext().any { (a, b) -> a == "any" && b == "other" }) return false
        fun at(i: Int): String = w.getOrNull(i) ?: ""
        return when (at(0)) {
            "should", "shall", "can", "could", "may" -> at(1) in subject
            "do", "does", "did" -> when {
                at(1) == "you" -> at(2) in wantVerbs
                at(1) in setOf("that", "this", "it") -> at(2) in setOf("sound", "sounds", "work", "works", "look", "looks")
                else -> false
            }
            "would" -> when {
                at(1) == "you" -> at(2) == "like" || at(2) == "want"
                at(1) in setOf("it", "that") -> at(2) == "be" && at(3) in agreeable
                else -> false
            }
            "is" -> at(1) in setOf("that", "it", "this") && at(2) in agreeable
            "are" -> (at(1) == "you" && at(2) in ready) || (at(1) == "we" && at(2) in ready)
            "want" -> at(1) == "me" && at(2) == "to"
            "ok", "okay" -> at(1) == "to"
            "ready" -> at(1) == "to" || at(1) == "for"
            "sound", "sounds" -> at(1) in agreeable
            "proceed" -> true
            "go" -> at(1) == "ahead"
            else -> false
        }
    }
}

/**
 * The two replies, and the rules for when a screen offers them. One pure decision per screen, so the room, the review
 * sheet and the Steer box agree (and agree with iOS's `YesNoReply`).
 */
object YesNoReply {
    const val YES = "Yes"
    const val NO = "No"

    /**
     * The room: the session is idle and takes a plain next message (no prompt, no question picker, Mac reachable), and
     * the last thing in its story is Claude's message ending on a yes/no question. Anything after that message (a tool
     * step, the user's own reply, a message just sent from here) takes the offer away.
     */
    fun roomOffer(mode: RoomComposerMode, state: LiveSessionState, ended: Boolean, ready: Boolean, hasAsk: Boolean, items: List<TranscriptTimeline.Item>): String? {
        if (ended || !ready || mode != RoomComposerMode.NextTask || state != LiveSessionState.IDLE || hasAsk) return null
        return YesNoQuestion.endingStory(items)
    }

    /**
     * A finished-turn page (the review sheet): the page's question, when it takes a written reply (the same path as
     * Steer, so the same gate decides) and nothing is on its way (a reply sent, unconfirmed or resolved hides the pair).
     */
    fun reviewOffer(question: String?, takesReply: Boolean, open: Boolean): String? = if (takesReply && open) question else null
}
