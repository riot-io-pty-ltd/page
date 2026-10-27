package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the decision sheet says about a page, ported from the "decision content" checks in iOS/Tests/LogicTests.swift.
 */
class DecisionContentTest {
    private val mac = "Studio MBP"
    private val term = nwSession("s1", title = "bottle-flip", host = "Terminal", canType = true)

    private fun content(iv: Intervention, session: LiveSession? = term): DecisionContent =
        DecisionContent.build(iv, NowRowBuilder.row(iv, session, mac), session, mac)

    @Test fun `an irreversible command is asked in full with its blurb, undo note and chip, and the footer names the Mac`() {
        val rm = nwIv("x", InterventionKind.APPROVAL, "[Bash] rm -rf Builds/Dev/*.app\nDelete every Dev build", session = "s1")
        val c = content(rm)
        assertEquals(DecisionContent.AskKind.COMMAND, c.askKind)
        assertEquals("rm -rf Builds/Dev/*.app", c.ask)
        assertEquals("Delete every Dev build", c.detail)
        assertEquals("Claude wants to do this. It can't be undone from your phone.", c.blurb)
        assertEquals("No undo from your phone.", c.undoNote)
        assertEquals(ChipKind.IRREVERSIBLE, c.chip)
        assertTrue(c.footer.contains(mac))
    }

    @Test fun `a page from an agent Page cannot read gets the screen note`() {
        val gem = pageFromJson("""{"id":"g2","sessionId":"s9","kind":"approval","openedAt":"2027-01-15T08:00:00Z","context":"[Bash] ls","backend":"gemini"}""")
        val c = content(gem, session = null)
        assertEquals("Couldn't tell what's on screen · Open on Mac", c.screenNote)
    }

    @Test fun `a plan page asks for a plan`() {
        val plan = nwIv("pl", InterventionKind.APPROVAL, "Plan ready for review\n1. Refactor", session = "s1", subtype = "plan")
        assertEquals(DecisionContent.AskKind.PLAN, content(plan).askKind)
    }

    @Test fun `an undoable command has the easy-undo note and a normal prompt can be answered in words`() {
        val ls = nwIv("ls", InterventionKind.APPROVAL, "[Bash] ls", session = "s1")
        val c = content(ls)
        assertEquals("Read-only, or easy to take back.", c.undoNote)
        assertFalse(c.decisionsOnly)
        assertTrue(c.canTell)
    }

    @Test fun `a numbered prompt lists its options and flags the standing one`() {
        val prompt = nwIv("pr", InterventionKind.APPROVAL, "[Bash] npm test\n1. Yes\n2. Yes, and don't ask again for npm\n3. No", session = "s1")
        val c = content(prompt)
        assertEquals(3, c.options.size)
        assertTrue(c.options[1].isStanding)
    }

    @Test fun `a hook page names the hook and the Mac, and a decisions-only hook cannot take words`() {
        val hookPage = nwIv("hookpre-7", InterventionKind.APPROVAL, "[Bash] ls", session = "s1")
        val hookC = content(hookPage)
        assertTrue(hookC.isHook)
        assertTrue(hookC.footer.contains("permission hook"))
        assertTrue(hookC.footer.contains(mac))
        val decisionsOnly = nwIv("hk", InterventionKind.APPROVAL, "[Bash] ls", session = "s1", hookBlocking = true)
        val doC = content(decisionsOnly)
        assertTrue(doC.decisionsOnly)
        assertFalse(doC.canTell)
    }

    @Test fun `a forecast or a battery pause is informational, with nothing to answer`() {
        val batt = nwIv("bf", InterventionKind.RATE_LIMIT, "Battery", subtype = "battery_forecast")
        assertNotNull(content(batt, session = null).informational)
        val paused = nwIv("lb", InterventionKind.IDLE, "Paused", subtype = "low_battery")
        assertNotNull(content(paused, session = null).informational)
    }

    @Test fun `a finished turn splits its summary from the reply`() {
        val done = nwIv("dn", InterventionKind.IDLE, "Changed 3 files (+120 −14) · tests passed\n\nAll done.", session = "s1")
        val c = content(done)
        assertEquals("Changed 3 files (+120 −14) · tests passed", c.turnSummary)
        assertEquals("All done.", c.ask)
    }

    @Test fun `the undo note follows the reversibility class, and no class means no note`() {
        assertNull(DecisionContent.undoNote(null, emptyList()))
        assertEquals("Read-only, or easy to take back.", DecisionContent.undoNote(Reversibility.UNDOABLE, emptyList()))
        assertEquals("No undo from your phone.", DecisionContent.undoNote(Reversibility.IRREVERSIBLE, emptyList()))
        assertEquals(
            "Reaches outside the project. Check where.",
            DecisionContent.undoNote(Reversibility.CONSIDERED, listOf(Reversibility.Tag.NETWORK_OUTSIDE)),
        )
        assertEquals(
            "Changes files in your project. git can usually recover them.",
            DecisionContent.undoNote(Reversibility.CONSIDERED, listOf(Reversibility.Tag.EDITS_IN_REPO)),
        )
    }
}
