package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class TipsTest {
    @Test
    fun everyTipShowsUntilDismissedThenNeverAgain() {
        var ledger = TipLedger.EMPTY
        for (tip in Tip.entries) assertTrue(tip.name, ledger.shouldShow(tip))
        ledger = ledger.dismiss(Tip.IN_FLIGHT)
        assertFalse(ledger.shouldShow(Tip.IN_FLIGHT))
        assertTrue(ledger.shouldShow(Tip.PAGE_ACTIONS))
        assertTrue(ledger.shouldShow(Tip.COMPOSER))
        // Dismissing twice changes nothing.
        assertSame(ledger, ledger.dismiss(Tip.IN_FLIGHT))
    }

    @Test
    fun theLedgerSurvivesBeingSavedAndReloaded() {
        val saved = TipLedger.EMPTY.dismiss(Tip.COMPOSER).dismiss(Tip.PAGE_ACTIONS).encode()
        val loaded = TipLedger.decode(saved)
        assertFalse(loaded.shouldShow(Tip.COMPOSER))
        assertFalse(loaded.shouldShow(Tip.PAGE_ACTIONS))
        assertTrue(loaded.shouldShow(Tip.IN_FLIGHT))
        assertEquals(saved, loaded.encode())
    }

    @Test
    fun nothingSavedOrGarbledMeansEveryTipShows() {
        for (raw in listOf(null, "", "\n\n", "nonsense", "not-a-tip\nalso-not")) {
            val ledger = TipLedger.decode(raw)
            for (tip in Tip.entries) assertTrue("$raw ${tip.name}", ledger.shouldShow(tip))
        }
    }

    @Test
    fun aNewerBuildsUnknownTipIsIgnoredButTheKnownOnesStay() {
        val ledger = TipLedger.decode("inFlight\nsomeFutureTip\n")
        assertFalse(ledger.shouldShow(Tip.IN_FLIGHT))
        assertTrue(ledger.shouldShow(Tip.COMPOSER))
        assertEquals("inFlight", ledger.encode())
    }

    @Test
    fun savedEntriesSurviveCarriageReturnsAndDuplicates() {
        val ledger = TipLedger.decode("inFlight\r\n  composerDelivery  \r\ninFlight")
        assertFalse(ledger.shouldShow(Tip.IN_FLIGHT))
        assertFalse(ledger.shouldShow(Tip.COMPOSER))
        assertTrue(ledger.shouldShow(Tip.PAGE_ACTIONS))
    }

    @Test
    fun aTipIsNeverDismissedUnderItsWireNameTwice() {
        // Wire names are the stored keys; the saved form must stay one line per tip.
        val saved = Tip.entries.fold(TipLedger.EMPTY) { acc, t -> acc.dismiss(t).dismiss(t) }.encode()
        assertEquals(Tip.entries.size, saved.split('\n').size)
        assertFalse(TipLedger.decode(saved).shouldShow(Tip.PAGE_ACTIONS))
    }

    @Test
    fun tipsHaveCopyAndDistinctKeys() {
        assertEquals(Tip.entries.size, Tip.entries.map { it.wire }.toSet().size)
        for (t in Tip.entries) {
            assertTrue(t.name, t.title.isNotBlank() && t.body.isNotBlank())
            assertFalse("no gesture jargon without saying what it does: ${t.name}", t.title.contains("swipe", ignoreCase = true))
        }
    }
}
