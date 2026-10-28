package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Port of iOS/Page/Models/QuestionDraft.swift. Answering the terminal's
// questions from the phone.
//
// When a Claude session is blocked on an AskUserQuestion dialog, the Mac puts
// the questions on that session's list row (`ask`). The person ticks answers
// here, one question at a time, reviews them all, and submits once; the Mac
// replays them into the dialog (docs/SESSIONS-PROTOCOL.md §5 "Answering a
// question"), checking the screen before every key. Nothing is typed until
// "Submit all".
//
//   SessionAsk     the questions as the Mac sent them (redacted, clipped)
//   AnswerSheet    the draft: ticks, Other text, which step, Back / Next,
//                  review, `canSubmit`, the wire encoding, the delivery preview

// MARK: - The ask (Mac → phone)

data class AskOption(val label: String, val detail: String)

data class AskQuestion(
    val text: String,
    /** The short tab name ("Color"); empty when the question had none. */
    val header: String,
    val multi: Boolean,
    val options: List<AskOption>,
)

data class SessionAsk(
    /** The tool_use id of the question on screen: sent back with the answers, so the Mac refuses if it is no longer the one showing. */
    val id: String,
    val questions: List<AskQuestion>,
    /** Some option has a preview: a layout the Mac won't drive. */
    val hasPreview: Boolean,
) {
    /** The phone can offer the picker (a preview layout is answered at the Mac). */
    val isAnswerable: Boolean get() = !hasPreview && questions.isNotEmpty()

    companion object {
        const val maxQuestions = 4
        const val maxOptions = 7

        private class Bad : Exception()

        /** A string field that may be absent or null but, when present, must be a JSON string (Swift's synthesized `String?` decode). */
        private fun optString(o: JsonObject, key: String): String? {
            val v = o[key] ?: return null
            if (v is JsonNull) return null
            if (v !is JsonPrimitive || !v.isString) throw Bad()
            return v.content
        }

        private fun optBool(o: JsonObject, key: String): Boolean? {
            val v = o[key] ?: return null
            if (v is JsonNull) return null
            return v.asBool() ?: throw Bad()
        }

        /**
         * Strict about shape (a malformed `ask` is dropped whole, and the session simply has no picker), lenient
         * about extras. null when malformed.
         */
        fun decode(element: JsonElement?): SessionAsk? {
            val c = element as? JsonObject ?: return null
            return try {
                val idEl = c["id"]
                if (idEl !is JsonPrimitive || !idEl.isString) throw Bad()
                val id = Sw.trimWsNl(idEl.content)
                val rawQuestions = c["questions"] as? JsonArray ?: throw Bad()
                if (id.isEmpty() || Sw.count(id) > 128) throw Bad()
                if (rawQuestions.isEmpty() || rawQuestions.size > maxQuestions) throw Bad()
                val out = ArrayList<AskQuestion>()
                for (qe in rawQuestions) {
                    val q = qe as? JsonObject ?: throw Bad()
                    val question = optString(q, "question")
                    val header = optString(q, "header")
                    val multi = optBool(q, "multi")
                    val optionsEl = q["options"]
                    val opts: JsonArray? = when (optionsEl) {
                        null, JsonNull -> null
                        is JsonArray -> optionsEl
                        else -> throw Bad()
                    }
                    val text = Sw.trimWsNl(question ?: "")
                    if (text.isEmpty() || opts == null || opts.isEmpty() || opts.size > maxOptions) throw Bad()
                    val options = ArrayList<AskOption>()
                    for (oe in opts) {
                        val o = oe as? JsonObject ?: throw Bad()
                        val label = Sw.trimWsNl(optString(o, "label") ?: "")
                        val description = optString(o, "description")
                        if (label.isEmpty()) throw Bad()
                        options.add(AskOption(Sw.prefix(label, 160), Sw.prefix(Sw.trimWsNl(description ?: ""), 240)))
                    }
                    out.add(AskQuestion(Sw.prefix(text, 500), Sw.prefix(Sw.trimWsNl(header ?: ""), 40), multi ?: false, options))
                }
                SessionAsk(id, out, c["hasPreview"].asBool() ?: false)
            } catch (_: Bad) {
                null
            }
        }
    }
}

// MARK: - One answer on the wire (phone → Mac)

/** One question's answer: 0-based option indices and the "Other" text. The Mac matches indices against its own raw copy of the question. */
data class AnswerWire(val question: Int, val picks: List<Int>, val other: String?) {
    val json: JsonObject
        get() {
            val o = LinkedHashMap<String, JsonElement>()
            o["i"] = JsonPrimitive(question)
            o["picks"] = JsonArray(picks.map { JsonPrimitive(it) })
            other?.let { o["other"] = JsonPrimitive(it) }
            return JsonObject(o)
        }
}

// MARK: - The draft

/**
 * The answers being picked: a pure state machine behind the question card. A single-select tick is exclusive
 * (with Other) and moves on at once; a multi-select ticks any number and has a Next button; Other opens a text
 * field. A last step lists every answer and offers "Submit all", enabled only once every question is answered
 * with a real choice. Mutable (like the Swift struct's `mutating` methods); [copy] gives a snapshot to publish.
 */
class AnswerSheet(
    val ask: SessionAsk,
    /**
     * False when the answers travel as text through Claude's question hook (a page the hook is holding): the
     * hook can map an option number, not free text, so there is no Other.
     */
    val allowsOther: Boolean = true,
) {
    sealed interface Step {
        data class Question(val index: Int) : Step
        data object Review : Step
    }

    var step: Step = Step.Question(0)
        private set
    private val picks: MutableList<MutableSet<Int>> = MutableList(ask.questions.size) { HashSet() }

    /** null: Other isn't chosen. "": chosen, nothing typed yet. */
    private val other: MutableList<String?> = MutableList(ask.questions.size) { null }

    fun copy(): AnswerSheet {
        val c = AnswerSheet(ask, allowsOther)
        c.step = step
        for (i in picks.indices) c.picks[i].addAll(picks[i])
        for (i in other.indices) c.other[i] = other[i]
        return c
    }

    override fun equals(other: Any?): Boolean =
        other is AnswerSheet && ask == other.ask && allowsOther == other.allowsOther && step == other.step && picks == other.picks && this.other == other.other

    override fun hashCode(): Int = listOf(ask, allowsOther, step, picks, other).hashCode()

    // MARK: reading

    val count: Int get() = ask.questions.size

    /** The question being asked, null on the review step. */
    val currentIndex: Int? get() = (step as? Step.Question)?.index
    val current: AskQuestion? get() = currentIndex?.let { ask.questions[it] }
    val isReview: Boolean get() = step == Step.Review

    fun isPicked(q: Int, option: Int): Boolean = q in picks.indices && option in picks[q]

    fun otherChosen(q: Int): Boolean = q in other.indices && other[q] != null

    fun otherText(q: Int): String = if (q in other.indices) (other[q] ?: "") else ""

    private fun typedOther(q: Int): String? {
        val t = Sw.trimWsNl(otherText(q))
        return t.ifEmpty { null }
    }

    /** Answered with a real choice: an option, or Other with text. */
    fun isAnswered(q: Int): Boolean {
        if (q !in picks.indices) return false
        return picks[q].isNotEmpty() || typedOther(q) != null
    }

    /** Other is chosen but still empty: it can't be sent, and says so. */
    fun otherNeedsText(q: Int): Boolean = otherChosen(q) && typedOther(q) == null

    val answeredCount: Int get() = (0 until count).count { isAnswered(it) }
    val allAnswered: Boolean get() = answeredCount == count
    val canSubmit: Boolean get() = allAnswered && (0 until count).none { otherNeedsText(it) }

    /** A step can be opened when every question before it is answered. */
    fun isReachable(q: Int): Boolean = q >= 0 && q < count && (0 until q).all { isAnswered(it) }

    /** The answer as the review and the receipt read it: option labels in option order, then the Other text. */
    fun answerText(q: Int): String {
        val question = ask.questions[q]
        val parts = picks[q].sorted().map { question.options[it].label }.toMutableList()
        typedOther(q)?.let { parts.add(it) }
        return parts.joinToString(", ")
    }

    // MARK: acting

    /**
     * Ticks option [option] of the current question. A single-select picks it (clearing Other) and moves on; a
     * multi-select toggles it. Returns whether the step changed.
     */
    fun tap(option: Int): Boolean {
        val q = currentIndex ?: return false
        if (option < 0 || option >= ask.questions[q].options.size) return false
        if (ask.questions[q].multi) {
            if (option in picks[q]) picks[q].remove(option) else picks[q].add(option)
            return false
        }
        picks[q] = hashSetOf(option)
        other[q] = null
        advance(q)
        return true
    }

    /** Opens the Other text field. In a single-select it replaces any ticked option; in a multi-select it toggles (closing it forgets the text). */
    fun toggleOther() {
        val q = currentIndex ?: return
        if (!allowsOther) return
        if (ask.questions[q].multi) {
            other[q] = if (other[q] == null) "" else null
        } else {
            picks[q] = HashSet()
            other[q] = other[q] ?: ""
        }
    }

    /** The Other text, as one line (a newline would be a key on the Mac). */
    fun setOther(text: String) {
        val q = currentIndex ?: return
        if (other[q] == null) return
        val sb = StringBuilder()
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            sb.appendCodePoint(if (Sw.isNewline(cp)) ' '.code else cp)
            i += Character.charCount(cp)
        }
        other[q] = Sw.prefix(sb.toString(), maxOtherChars)
    }

    /** Return in the Other field: a single-select with text moves on. */
    fun commitOther(): Boolean {
        val q = currentIndex ?: return false
        if (ask.questions[q].multi || typedOther(q) == null) return false
        advance(q)
        return true
    }

    /** Next (multi-select): only once the question is answered. */
    fun next(): Boolean {
        val q = currentIndex ?: return false
        if (!isAnswered(q) || otherNeedsText(q)) return false
        advance(q)
        return true
    }

    /** Back one step; from the review, the last question. */
    fun back() {
        when (val s = step) {
            is Step.Question -> if (s.index > 0) step = Step.Question(s.index - 1)
            Step.Review -> step = Step.Question(count - 1)
        }
    }

    /** The progress strip: open question [q] (never past an unanswered one). */
    fun go(q: Int) {
        if (!isReachable(q)) return
        step = Step.Question(q)
    }

    /** The strip's last stop. */
    fun goToReview() {
        if (!canSubmit) return
        step = Step.Review
    }

    /** After answering [q]: the next unanswered question, else the review. */
    private fun advance(q: Int) {
        val next = ((q + 1) until count).firstOrNull { !isAnswered(it) } ?: (0 until q).firstOrNull { !isAnswered(it) }
        step = if (next != null) Step.Question(next) else Step.Review
    }

    // MARK: sending

    /** What goes to the Mac. null until every question has a real answer. */
    fun wire(): List<AnswerWire>? {
        if (!canSubmit) return null
        return (0 until count).map { q -> AnswerWire(q, picks[q].sorted(), typedOther(q)) }
    }

    data class ReviewRow(val index: Int, val header: String, val question: String, val answer: String)

    /** The review step's rows. */
    fun reviewRows(): List<ReviewRow> = (0 until count).map { q ->
        val question = ask.questions[q]
        ReviewRow(q, if (question.header.isEmpty()) "Question ${q + 1}" else question.header, question.text, if (isAnswered(q)) answerText(q) else "Not answered")
    }

    /**
     * "Will choose Green; Ham, Corn · cmux › page · Studio MBP": exactly what will be pressed, where. Through the
     * hook nothing is pressed: "Will answer through Claude's question hook: Green; Ham, Corn · Studio MBP".
     */
    fun previewLine(route: String?, mac: String, viaHook: Boolean = false): String {
        val chosen = (0 until count).joinToString("; ") { if (isAnswered(it)) answerText(it) else "—" }
        val clipped = if (Sw.count(chosen) > 160) Sw.prefix(chosen, 159) + "…" else chosen
        if (viaHook) return DeliveryPreview.line("Will answer through Claude's question hook: $clipped", null, mac)
        return DeliveryPreview.line("Will choose $clipped", route, mac)
    }

    /**
     * The reply text for a page Claude's question hook is holding: one line per question, the 1-based option
     * number (several, comma-separated, for a multi-select). The hook maps numbers to labels, so a label with a
     * comma can't be misread. null until every question is answered with an option (the hook can't take Other
     * text), and only for a sheet made for the hook ([allowsOther] false).
     */
    fun hookReply(): String? {
        if (allowsOther || !canSubmit || !(0 until count).all { picks[it].isNotEmpty() }) return null
        return (0 until count).joinToString("\n") { q -> picks[q].sorted().joinToString(", ") { (it + 1).toString() } }
    }

    /** The same, for the receipt under a delivered answer. */
    val summaryLine: String get() = (0 until count).joinToString("; ") { if (isAnswered(it)) answerText(it) else "—" }

    companion object {
        const val maxOtherChars = 300
    }
}

// MARK: - Whether to offer the picker

object AnswerPicker {
    /**
     * The session's question, when the phone should offer the picker for the page it shows: the Mac sent one (so
     * it accepts answers), the page is a question, and it can be answered by key (no previews).
     *
     * [hook]: the page is one Claude's question hook holds. There is no dialog on screen then (the session reads
     * working), the answers go as text through the hook, and the Mac sent `ask` because the hook wrote the call to
     * the transcript first. The hook applies option numbers by position to ITS question, so the page's own text
     * ([pageContext]) must show the very questions this `ask` has: otherwise a stale `ask` (the previous
     * question) could pick the wrong options. No match, no picker.
     *
     * A key-driven answer needs a terminal Page can type into (`canType`), as for any typed message.
     */
    fun ask(session: LiveSession?, pageIsQuestion: Boolean, hook: Boolean = false, pageContext: String? = null): SessionAsk? {
        val ask = session?.ask
        if (!pageIsQuestion || ask == null || !ask.isAnswerable) return null
        if (hook) return if (hookPageMatches(ask, pageContext)) ask else null
        if (session.state.isWaiting != true || !session.canType) return null
        return ask
    }

    private fun norm(s: String): String {
        val words = ArrayList<String>()
        val cur = StringBuilder()
        val lower = s.lowercase()
        var i = 0
        while (i < lower.length) {
            val cp = lower.codePointAt(i)
            if (Sw.isUnicodeWhitespace(cp)) { if (cur.isNotEmpty()) { words.add(cur.toString()); cur.setLength(0) } } else cur.appendCodePoint(cp)
            i += Character.charCount(cp)
        }
        if (cur.isNotEmpty()) words.add(cur.toString())
        return words.joinToString(" ")
    }

    /**
     * True when the hook page's text carries every question and option of `ask` (compared loosely: case and
     * spacing ignored, long text by its start, since the hook clips what it sends).
     */
    fun hookPageMatches(ask: SessionAsk, context: String?): Boolean {
        if (context == null) return false
        val page = norm(context)
        for (q in ask.questions) {
            if (!page.contains(Sw.prefix(norm(q.text), 60))) return false
            for (o in q.options) if (!page.contains(Sw.prefix(norm(o.label), 40))) return false
        }
        return true
    }

    /**
     * Where "Submit all" goes. A page Claude's question hook holds takes numbers as text, which the hook maps
     * (nothing is pressed); anything else is the Mac's `answer` command, which presses the keys.
     */
    sealed interface Submit {
        data class Hook(val text: String) : Submit
        data object Keys : Submit

        /** Nothing is sent; say why. */
        data class Refuse(val why: String) : Submit
    }

    fun submit(viaHook: Boolean, hasPage: Boolean, sheet: AnswerSheet): Submit {
        if (!viaHook) return Submit.Keys
        if (!hasPage) return Submit.Refuse("This prompt's page isn't loaded yet, so nothing was sent.")
        val text = sheet.hookReply() ?: return Submit.Refuse("Pick an option for every question first, so nothing was sent.")
        return Submit.Hook(text)
    }

    /** A page's own delivery outcome (the hook path has no `answer` command) as the card's delivery state. */
    fun delivery(outcome: CardOutcome, sessionId: String, promptKey: String, now: Instant): SentSessionCommand? {
        val state: SessionDeliveryState = when (outcome) {
            CardOutcome.None -> return null
            is CardOutcome.Arming, CardOutcome.Sending -> SessionDeliveryState.Sending
            is CardOutcome.Delivered -> SessionDeliveryState.Typed(outcome.detail)
            is CardOutcome.Problem -> SessionDeliveryState.Failed(outcome.why)
            is CardOutcome.Note -> SessionDeliveryState.Queued(outcome.text)
        }
        return SentSessionCommand(
            clientId = "page-$promptKey", sessionId = sessionId, kind = SessionCommandKind.ANSWER, text = "", sentAt = now, state = state,
            promptKey = promptKey,
        )
    }

    /** Where an answer stands: the newest `answer` sent for this very question. */
    fun delivery(commands: List<SentSessionCommand>, sessionId: String, promptKey: String): SentSessionCommand? =
        commands.filter { it.kind == SessionCommandKind.ANSWER && it.sessionId == sessionId && it.promptKey == promptKey }.maxByOrNull { it.sentAt }
}
