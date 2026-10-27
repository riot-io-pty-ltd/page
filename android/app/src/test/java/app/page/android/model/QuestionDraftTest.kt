package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The question card: decoding a Mac's `ask`, the answer state machine, the answers payload, the hook reply, and
 * whether the picker is offered. Ported from the "Answering the terminal's questions (QuestionDraft)" checks in
 * iOS/Tests/LogicTests.swift.
 */
class QuestionDraftTest {
    private val askJson = """
        {"id":"toolu_1","hasPreview":false,"questions":[
          {"question":"Pick a color","header":"Color","multi":false,"options":[{"label":"Red","description":"warm"},{"label":"Green"},{"label":"Blue"}]},
          {"question":"Pick toppings","header":"Toppings","multi":true,"options":[{"label":"Cheese"},{"label":"Ham"},{"label":"Olives"},{"label":"Corn"}]},
          {"question":"Pick a size","multi":false,"options":[{"label":"Small"},{"label":"Large"}]}]}
    """.trimIndent()

    private fun ask(): SessionAsk = SessionAsk.decode(parseJson(askJson))!!

    private fun decodes(json: String): Boolean = SessionAsk.decode(parseJson(json)) != null

    @Test fun `a Mac's ask decodes, a missing header is empty and the ask is answerable`() {
        val ask = ask()
        assertEquals("toolu_1", ask.id)
        assertEquals(3, ask.questions.size)
        assertTrue(ask.questions[1].multi)
        assertEquals("warm", ask.questions[0].options[0].detail)
        assertEquals("", ask.questions[2].header)
        assertTrue(ask.isAnswerable)
    }

    @Test fun `a malformed ask is dropped whole, and unknown fields are ignored`() {
        assertFalse("an empty id is refused", decodes("""{"id":"","questions":[{"question":"Q","options":[{"label":"a"}]}]}"""))
        assertFalse("no questions is refused", decodes("""{"id":"x","questions":[]}"""))
        assertFalse("a question without options is refused", decodes("""{"id":"x","questions":[{"question":"Q","options":[]}]}"""))
        assertFalse("an option without a label is refused", decodes("""{"id":"x","questions":[{"question":"Q","options":[{"label":""}]}]}"""))
        assertFalse(
            "more options than keys is refused",
            decodes("""{"id":"x","questions":[{"question":"Q","options":[{"label":"a"},{"label":"b"},{"label":"c"},{"label":"d"},{"label":"e"},{"label":"f"},{"label":"g"},{"label":"h"}]}]}"""),
        )
        assertTrue(
            "unknown fields are ignored",
            decodes("""{"id":"x","extra":1,"questions":[{"question":"Q","future":true,"options":[{"label":"a","preview":"p"}]}]}"""),
        )
    }

    @Test fun `a preview layout is answered at the Mac`() {
        val withPreview = SessionAsk.decode(parseJson("""{"id":"x","hasPreview":true,"questions":[{"question":"Q","options":[{"label":"a"}]}]}"""))!!
        assertFalse(withPreview.isAnswerable)
    }

    @Test fun `the session row carries the ask, a malformed ask leaves the session intact, an old Mac sends none`() {
        val row = LiveSession.decode(parseJson("""{"id":"s1","backend":"claude","title":"page","state":"waitingOnUser","host":"tmux","canType":true,"canInterrupt":true,"interventionId":"p1","ask":$askJson}""")!!)!!
        assertEquals("toolu_1", row.ask?.id)
        val bad = LiveSession.decode(parseJson("""{"id":"s1","state":"waitingOnUser","ask":{"id":5}}""")!!)!!
        assertNull(bad.ask)
        assertEquals("s1", bad.id)
        val old = LiveSession.decode(parseJson("""{"id":"s1","state":"waitingOnUser"}""")!!)!!
        assertNull(old.ask)
    }

    @Test fun `single-select tick moves on at once and the answer is recorded`() {
        val sheet = AnswerSheet(ask())
        assertEquals(AnswerSheet.Step.Question(0), sheet.step)
        assertFalse(sheet.canSubmit)
        assertNull(sheet.wire())
        assertTrue(sheet.tap(1))
        assertEquals(AnswerSheet.Step.Question(1), sheet.step)
        assertTrue(sheet.isAnswered(0))
        assertEquals("Green", sheet.answerText(0))
    }

    @Test fun `multi-select ticks stay, Next moves on, Back goes one question back, answers are in option order`() {
        val sheet = AnswerSheet(ask())
        sheet.tap(1)
        assertFalse(sheet.tap(1))
        assertTrue(sheet.isPicked(1, 1))
        assertTrue(sheet.next())
        assertEquals(AnswerSheet.Step.Question(2), sheet.step)
        sheet.back()
        assertEquals(AnswerSheet.Step.Question(1), sheet.step)
        sheet.tap(3)
        assertEquals("Ham, Corn", sheet.answerText(1))
        sheet.tap(1)
        assertEquals("Corn", sheet.answerText(1))
        sheet.tap(1)
        assertTrue(sheet.next())
        assertEquals(AnswerSheet.Step.Question(2), sheet.step)
        assertTrue(sheet.tap(0))
        assertTrue(sheet.isReview)
        assertTrue(sheet.canSubmit)
    }

    @Test fun `the wire is indices, sorted, and the review rows and preview name what will be pressed`() {
        val sheet = answeredSheet()
        assertEquals(
            listOf(AnswerWire(0, listOf(1), null), AnswerWire(1, listOf(1, 3), null), AnswerWire(2, listOf(0), null)),
            sheet.wire(),
        )
        val rows = sheet.reviewRows()
        assertEquals(listOf("Green", "Ham, Corn", "Small"), rows.map { it.answer })
        assertEquals("Question 3", rows[2].header)
        assertEquals(
            "Will choose Green; Ham, Corn; Small · cmux › page · Studio MBP",
            sheet.previewLine("cmux › page", "Studio MBP"),
        )
        assertTrue(sheet.previewLine(null, "").endsWith("· your Mac"))
        sheet.back()
        assertEquals(AnswerSheet.Step.Question(2), sheet.step)
    }

    @Test fun `Next cannot skip an unanswered question and the strip cannot pass one`() {
        val fresh = AnswerSheet(ask())
        assertFalse(fresh.next())
        assertEquals(AnswerSheet.Step.Question(0), fresh.step)
        fresh.go(2)
        assertEquals(AnswerSheet.Step.Question(0), fresh.step)
        assertFalse(fresh.isReachable(1))
        fresh.goToReview()
        assertFalse("no review until everything is answered", fresh.isReview)
    }

    @Test fun `revisiting an answered question returns to the review and keeps the change`() {
        val sheet = answeredSheet()
        sheet.go(0)
        assertEquals(AnswerSheet.Step.Question(0), sheet.step)
        assertTrue(sheet.tap(2))
        assertTrue(sheet.isReview)
        assertEquals("Blue", sheet.answerText(0))
    }

    @Test fun `Other on a single-select needs text, Return with text moves on, a tick replaces Other`() {
        val o = AnswerSheet(ask())
        o.toggleOther()
        assertTrue(o.otherChosen(0))
        assertFalse(o.isAnswered(0))
        assertTrue(o.otherNeedsText(0))
        assertFalse("Return on an empty Other does nothing", o.commitOther())
        assertEquals(AnswerSheet.Step.Question(0), o.step)
        o.setOther("Pur\nple")
        assertEquals("Pur ple", o.otherText(0))
        assertTrue(o.commitOther())
        assertEquals(AnswerSheet.Step.Question(1), o.step)
        assertEquals("Pur ple", o.answerText(0))
        assertNull("Other text is the answer; not complete yet", o.wire())
        o.go(0)
        o.tap(0)
        assertFalse(o.otherChosen(0))
        assertEquals("Red", o.answerText(0))
    }

    @Test fun `Other on a multi-select joins the ticks, closing it forgets the text, an empty Other blocks Next`() {
        val m = AnswerSheet(ask())
        m.tap(0)
        m.tap(0)
        m.toggleOther()
        m.setOther("kiwi")
        assertEquals("Cheese, kiwi", m.answerText(1))
        assertTrue(m.isAnswered(1))
        assertTrue(m.next())
        assertEquals(AnswerSheet.Step.Question(2), m.step)
        m.go(1)
        m.toggleOther()
        assertFalse(m.otherChosen(1))
        assertEquals("Cheese", m.answerText(1))
        m.toggleOther()
        assertTrue(m.otherNeedsText(1))
        assertFalse(m.next())
        m.setOther("x".repeat(900))
        assertEquals(AnswerSheet.maxOtherChars, m.otherText(1).length)
    }

    @Test fun `a multi-select with a tick and Other is answered, and Other travels as text next to the picks`() {
        val mo = AnswerSheet(ask())
        mo.tap(0)
        mo.tap(0)
        mo.toggleOther()
        mo.setOther("only me")
        assertTrue(mo.isAnswered(1))
        assertNull(mo.wire())
        assertTrue(mo.next())
        assertFalse(mo.isReview)
        mo.tap(1)
        assertEquals(
            listOf(AnswerWire(0, listOf(0), null), AnswerWire(1, listOf(0), "only me"), AnswerWire(2, listOf(1), null)),
            mo.wire(),
        )
        assertEquals("only me", mo.wire()!![1].json["other"]?.let { (it as kotlinx.serialization.json.JsonPrimitive).content })
        assertNull(mo.wire()!![0].json["other"])
    }

    @Test fun `out-of-range taps do nothing`() {
        val r = AnswerSheet(ask())
        assertFalse(r.tap(9))
        assertFalse(r.tap(-1))
        assertEquals(0, r.answeredCount)
    }

    @Test fun `through Claude's question hook there is no Other and the reply is one numbered line per question`() {
        val h = AnswerSheet(ask(), allowsOther = false)
        h.toggleOther()
        assertFalse("the hook can't take Other text", h.otherChosen(0))
        assertNull("nothing to send until every question is answered", h.hookReply())
        h.tap(1); h.tap(3); h.tap(1); h.next(); h.tap(0)
        assertTrue(h.isReview)
        assertEquals("2\n2, 4\n1", h.hookReply())
        assertNull("a sheet made for the keys never sends hook text", answeredSheet().hookReply())
        assertEquals(
            "Will answer through Claude's question hook: Green; Ham, Corn; Small · Studio MBP",
            h.previewLine("cmux › page", "Studio MBP", viaHook = true),
        )
        assertFalse("nothing is typed in a terminal, so no terminal is named", h.previewLine("cmux › page", "Studio MBP", viaHook = true).contains("cmux"))
    }

    @Test fun `a label with a comma is sent as its number`() {
        val one = AnswerSheet(
            SessionAsk(
                id = "t",
                questions = listOf(AskQuestion("Tags?", "", true, listOf(AskOption("a, b", ""), AskOption("c", ""), AskOption("d", "")))),
                hasPreview = false,
            ),
            allowsOther = false,
        )
        one.tap(2)
        one.tap(0)
        assertEquals("1, 3", one.hookReply())
    }

    @Test fun `answer deliveries follow the card outcome, and the newest answer for that question wins`() {
        assertNull(AnswerPicker.delivery(CardOutcome.None, "s1", "k", at(100.0)))
        assertEquals(SessionDeliveryState.Sending, AnswerPicker.delivery(CardOutcome.Sending, "s1", "k", at(100.0))?.state)
        assertEquals(SessionDeliveryState.Sending, AnswerPicker.delivery(CardOutcome.Arming(0.4), "s1", "k", at(100.0))?.state)
        assertEquals(
            SessionDeliveryState.Typed("Answered — Claude has your choice"),
            AnswerPicker.delivery(CardOutcome.Delivered("Answered — Claude has your choice"), "s1", "k", at(100.0))?.state,
        )
        assertEquals(
            SessionDeliveryState.Failed("Prompt closed"),
            AnswerPicker.delivery(CardOutcome.Problem("Prompt closed"), "s1", "k", at(100.0))?.state,
        )
    }

    @Test fun `the picker is offered only for a waiting question the Mac can key, or a hook page with matching text`() {
        val ask = ask()
        val waiting = session("waitingOnUser", canType = true, ask = ask)
        assertEquals("toolu_1", AnswerPicker.ask(waiting, pageIsQuestion = true)?.id)
        assertNull("not for an approval page", AnswerPicker.ask(waiting, pageIsQuestion = false))
        assertNull("not without a session", AnswerPicker.ask(null, pageIsQuestion = true))
        val working = session("active", canType = true, ask = ask)
        assertNull("a working session with no hook has no dialog to answer", AnswerPicker.ask(working, pageIsQuestion = true))
        val hookText = ask.questions.mapIndexed { i, q ->
            "Q${i + 1}. ${q.text}\n" + q.options.mapIndexed { j, o -> "${j + 1}. ${o.label}" }.joinToString("\n")
        }.joinToString("\n\n")
        assertEquals("toolu_1", AnswerPicker.ask(working, pageIsQuestion = true, hook = true, pageContext = hookText)?.id)
        assertNull("a hook page whose text isn't known gets no picker", AnswerPicker.ask(working, pageIsQuestion = true, hook = true))
        assertNull(
            "a hook page about a different question gets no picker",
            AnswerPicker.ask(working, pageIsQuestion = true, hook = true, pageContext = "Which database should I use?\n1. Postgres\n2. SQLite"),
        )
        assertTrue(AnswerPicker.hookPageMatches(ask, hookText.uppercase().replace("\n", "  \n ")))
        val blocked = session("waitingOnUser", canType = false, ask = ask, blocker = "Checking where this session runs…")
        assertNull("no keys can be pressed there: no picker, Tell it instead", AnswerPicker.ask(blocked, pageIsQuestion = true))
        val noAsk = session("waitingOnUser", canType = true, ask = null)
        assertNull("not from a Mac that sent no ask", AnswerPicker.ask(noAsk, pageIsQuestion = true))
    }

    @Test fun `submit sends keys without a hook, numbers as text through a hook page, and refuses with a reason otherwise`() {
        val done = AnswerSheet(ask(), allowsOther = false)
        done.tap(1); done.tap(0); done.next(); done.tap(0); done.tap(0)
        val unfinished = AnswerSheet(ask(), allowsOther = false)
        unfinished.tap(1)
        assertEquals(AnswerPicker.Submit.Keys, AnswerPicker.submit(viaHook = false, hasPage = false, sheet = done))
        assertEquals(AnswerPicker.Submit.Hook(done.hookReply()!!), AnswerPicker.submit(viaHook = true, hasPage = true, sheet = done))
        assertTrue("a hook answer with no page says so", AnswerPicker.submit(viaHook = true, hasPage = false, sheet = done) is AnswerPicker.Submit.Refuse)
        assertTrue("an unfinished hook answer is refused with a reason", AnswerPicker.submit(viaHook = true, hasPage = true, sheet = unfinished) is AnswerPicker.Submit.Refuse)
    }

    @Test fun `the answer command's delivery is the newest answer for that very question`() {
        val sent = listOf(
            answerCmd("a", 1, SessionDeliveryState.Sending, "toolu_1"),
            answerCmd("b", 2, SessionDeliveryState.Typed(null), "toolu_1"),
            answerCmd("c", 3, SessionDeliveryState.Typed(null), "toolu_2"),
            SentSessionCommand("d", "s1", SessionCommandKind.INPUT, "x", at(4.0), SessionDeliveryState.Typed(null)),
        )
        assertEquals("b", AnswerPicker.delivery(sent, "s1", "toolu_1")?.clientId)
        assertNull(AnswerPicker.delivery(sent, "s1", "toolu_9"))
    }

    private fun answerCmd(id: String, t: Long, state: SessionDeliveryState, key: String) = SentSessionCommand(
        clientId = id, sessionId = "s1", kind = SessionCommandKind.ANSWER, text = "x", sentAt = at(t.toDouble()),
        state = state, promptKey = key,
    )

    private fun session(state: String, canType: Boolean, ask: SessionAsk?, blocker: String? = null): LiveSession {
        val base = nwSession("s1", title = "page", state = state, host = "tmux", canType = canType, blocker = blocker, interventionId = "p1")
        return base.copy(ask = ask)
    }

    private fun answeredSheet(): AnswerSheet {
        val sheet = AnswerSheet(ask())
        sheet.tap(1)   // q1 Green, which moves on
        sheet.tap(1)   // q2 Ham
        sheet.tap(3)   // q2 Corn
        sheet.next()
        sheet.tap(0)   // q3 Small, which goes to the review
        assertTrue(sheet.isReview)
        return sheet
    }
}
