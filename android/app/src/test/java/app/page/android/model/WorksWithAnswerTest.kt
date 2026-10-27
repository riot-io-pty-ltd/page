package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Answering a question, per terminal: the Works with list says what the Mac's `TerminalCatalog` says (the Mac drove
 * a real question dialog in every terminal but Terminal.app), and whether the answer sheet is offered for one
 * session is decided by the Mac's `ask` alone: there is no host list on the phone to drift from the Mac's.
 * Ported from the answer checks in iOS/Tests/LogicTests.swift.
 */
class WorksWithAnswerTest {
    @Test fun `only Terminal can't answer questions yet, and the other seven can, in the Mac's order`() {
        val notYet = TowerHosts.hosts.filter { it.answer is TowerHosts.Answer.NotYet }.map { it.name }
        assertEquals(listOf("Terminal"), notYet)
        val yes = TowerHosts.hosts.filter { it.answer == TowerHosts.Answer.Yes }.map { it.name }
        assertEquals(listOf("iTerm2", "tmux", "cmux", "WezTerm", "kitty", "Herdr", "Claude Squad"), yes)
        assertEquals(8, TowerHosts.hosts.size)
    }

    @Test fun `the Works with rows say what iOS says, name by name, in the same order`() {
        assertEquals(
            listOf(
                "Terminal" to "reply and approve; the Mac asks macOS for permission once",
                "iTerm2" to "reply, approve and stop; the Mac asks macOS for permission once",
                "tmux" to "reply, approve, stop and see the screen, in any terminal app",
                "cmux" to "everything, and start new sessions from here",
                "WezTerm" to "reply, approve, stop and see the screen; nothing to set up",
                "kitty" to "reply, approve, stop and see the screen; one click turns on remote control",
                "Herdr" to "reply, approve, stop and see the screen; nothing to set up",
                "Claude Squad" to "each agent is a tmux pane, so it works like tmux",
            ),
            TowerHosts.hosts.map { it.name to it.line },
        )
    }

    @Test fun `the three answer lines read as the Mac's Terminals page does`() {
        assertEquals("Answer questions: yes", TowerHosts.Answer.Yes.line)
        assertEquals("Answer questions: with limits — a", TowerHosts.Answer.Limited("a").line)
        assertEquals("Answer questions: not yet — x", TowerHosts.Answer.NotYet("x").line)
    }

    @Test fun `Terminal's reason is the Mac's word for word, and names tmux and iTerm2 as the way round`() {
        val terminal = TowerHosts.hosts.first { it.name == "Terminal" }
        assertEquals(TowerHosts.Answer.NotYet("Terminal adds a Return to every key Page types; use tmux or iTerm2"), terminal.answer)
        assertEquals("Answer questions: not yet — Terminal adds a Return to every key Page types; use tmux or iTerm2", terminal.answer.line)
    }

    // The phone never decides by host: the Mac sends `ask` for a terminal that takes answer keys, and the sheet is offered for exactly that.
    private val askJson = """{"id":"toolu_1","hasPreview":false,"questions":[{"question":"Pick a color","multi":false,"options":[{"label":"Red"},{"label":"Green"}]}]}"""

    private fun waiting(host: String, withAsk: Boolean): LiveSession {
        val base = nwSession("s1", title = "page", state = "waitingOnUser", host = host, canType = true, interventionId = "p1")
        return base.copy(ask = if (withAsk) SessionAsk.decode(parseJson(askJson)) else null)
    }

    @Test fun `the answer sheet is offered in every terminal the Mac advertises an ask for, whatever its name`() {
        // The wire host names the Mac uses (TerminalCatalog wireHost), including Claude Squad's.
        for (host in listOf("tmux", "Claude Squad", "iTerm", "cmux", "WezTerm", "kitty", "Herdr")) {
            assertNotNull("$host with an ask", AnswerPicker.ask(waiting(host, withAsk = true), pageIsQuestion = true))
        }
    }

    @Test fun `no ask from the Mac means no answer sheet, for Terminal and for any host without one`() {
        assertNull("Terminal.app: the Mac sends no ask, so Tell it instead", AnswerPicker.ask(waiting("Terminal", withAsk = false), pageIsQuestion = true))
        for (host in listOf("tmux", "iTerm", "cmux", "WezTerm", "kitty", "Herdr", "Claude Squad")) {
            assertNull("$host without an ask", AnswerPicker.ask(waiting(host, withAsk = false), pageIsQuestion = true))
        }
    }

    @Test fun `a refused answer shows the Mac's own words, and an old Mac's falls back on the phone's line`() {
        val why = "Terminal.app adds a Return to every key Page types, which would skip or dismiss questions — answer at your Mac, or use tmux or iTerm2"
        assertEquals(why, SessionResultCopy.refusal("answer_unsupported", why, "Claude"))
        assertEquals("Page can't answer this question from here. Answer it on your Mac.", SessionResultCopy.refusal("answer_unsupported", null, "Claude"))
    }
}
