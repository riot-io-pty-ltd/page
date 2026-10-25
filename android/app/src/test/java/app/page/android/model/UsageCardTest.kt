package app.page.android.model

import java.time.ZoneOffset
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// iOS LogicTests.swift "usage card + started session".
class UsageCardTest {
    private val uNow = at(1_800_000_000.0)

    private val usageCard = UsageCardModel.from(
        ClaudeUsage(
            fiveHour = UsageWindow(57.0, uNow.plusSeconds(34 * 60)),
            sevenDay = UsageWindow(87.0, uNow.plusSeconds(24 * 3600)),
            hitAt = null,
            updatedAt = uNow.plusSeconds(-60),
        ),
        uNow,
    )!!

    @Test
    fun countdowns() {
        assertEquals("5h countdown", "Resets in 34m", usageCard.fiveHour?.resetLine(uNow))
        assertEquals("7d countdown", "Resets in 1d", usageCard.sevenDay?.resetLine(uNow))
        assertEquals("h m countdown", "2h 05m", UsageGauge.countdown(uNow.plusSeconds(2 * 3600 + 5 * 60), uNow))
        assertEquals("1d 4h", UsageGauge.countdown(uNow.plusSeconds(28 * 3600 + 59), uNow))
        assertEquals("<1m", UsageGauge.countdown(uNow.plusSeconds(59), uNow))
        assertEquals("Resetting…", UsageGauge("5-hour", 10.0, uNow, UsageGauge.FIVE_HOUR_WINDOW, uNow).resetLine(uNow))
    }

    @Test
    fun paceAndTone() {
        assertEquals("5h elapsed share", 1 - 34.0 / 300, usageCard.fiveHour?.elapsed ?: 0.0, 0.001)
        // 7d 87% with 6/7 of the week gone: on pace, warm.
        assertEquals("On pace", usageCard.sevenDay?.paceLine)
        assertEquals(UsageGauge.Tone.WARM, usageCard.sevenDay?.tone)
        // 5h 57% near the end: plenty left.
        assertEquals("Plenty left", usageCard.fiveHour?.paceLine)
        assertEquals(UsageGauge.Tone.CALM, usageCard.fiveHour?.tone)
        assertNull("fresh", usageCard.staleMinutes)
        assertFalse("on track", usageCard.verdict { "t" }.warning)
        // 60% two days in: ahead of pace.
        val ahead = UsageGauge("7-day", 60.0, uNow.plusSeconds(5 * 24 * 3600), UsageGauge.SEVEN_DAY_WINDOW, uNow)
        assertEquals("Ahead of pace", ahead.paceLine)
        assertEquals(UsageGauge.Tone.WARM, ahead.tone)
        assertEquals("95% hot", UsageGauge.Tone.HOT, UsageGauge("x", 95.0, null, 1.0, uNow).tone)
        assertNull("no reset, no pace", UsageGauge("x", 95.0, null, 1.0, uNow).paceLine)
    }

    @Test
    fun verdictsAndStaleness() {
        val hitCard = UsageCardModel.from(ClaudeUsage(UsageWindow(80.0, null), null, uNow.plusSeconds(600), null), uNow)!!
        assertEquals("hit verdict", UsageCardModel.Verdict("At this pace you'll hit the 5-hour limit around T", true), hitCard.verdict { "T" })
        assertNull("old numbers hidden", UsageCardModel.from(ClaudeUsage(UsageWindow(1.0, null), null, null, uNow.plusSeconds(-7 * 3600)), uNow))
        val stale = UsageCardModel.from(ClaudeUsage(UsageWindow(1.0, null), null, null, uNow.plusSeconds(-20 * 60)), uNow)
        assertEquals("as of 20m", 20, stale?.staleMinutes)
        assertEquals("as of 20m ago", stale?.staleText)
        assertNull("nothing to show", UsageCardModel.from(null, uNow))
        assertNull("past hitAt dropped", UsageCardModel.from(ClaudeUsage(UsageWindow(1.0, null), null, uNow.plusSeconds(-1), null), uNow)?.hitAt)
        val week = UsageCardModel.from(ClaudeUsage(null, UsageWindow(93.0, null), null, null), uNow)!!
        assertEquals(UsageCardModel.Verdict("Only 7% of this week's usage left", true), week.verdict { "" })
        assertEquals("On track — both windows reset before you run out", usageCard.verdict { "" }.text)
    }

    @Test
    fun resetTimeAndSpokenSummary() {
        val now = PageDate.parse("2026-10-25T18:00:00Z")!!
        val utc = ZoneOffset.UTC
        assertEquals("at 20:40", UsageText.resetTime(PageDate.parse("2026-10-25T20:40:00Z")!!, now, utc, Locale.UK))
        assertEquals("Mon 20:00", UsageText.resetTime(PageDate.parse("2026-10-26T20:00:00Z")!!, now, utc, Locale.UK))
        val g = UsageGauge("5-hour", 57.0, PageDate.parse("2026-10-25T20:40:00Z")!!, UsageGauge.FIVE_HOUR_WINDOW, now)
        assertEquals("5-hour usage 57 percent, resets at 20:40, on pace", UsageText.spoken(g, now, utc, Locale.UK))
    }

    private fun liveS(id: String, cwd: String) = LiveSession(
        id = id, backend = AgentBackend.Known(InterventionBackend.CLAUDE), title = "t", cwd = cwd, state = LiveSessionState.IDLE,
        host = "cmux", canType = true, typeBlocker = null, canInterrupt = false, provider = null,
        lastActivityAt = null, interventionId = null, preview = "",
    )

    @Test
    fun startedSessionMatch() {
        assertEquals("abbreviate home", "~/Documents/P", StartedSessionMatch.abbreviated("/Users/roy/Documents/P"))
        assertEquals("not home", "/opt/x", StartedSessionMatch.abbreviated("/opt/x"))
        val list = listOf(liveS("old", "~/Documents/P"), liveS("new", "~/Documents/P"), liveS("other", "~/x"))
        assertEquals("finds the new session in that folder", "new", StartedSessionMatch.find(list, "/Users/roy/Documents/P", setOf("old"))?.id)
        assertNull("not another folder", StartedSessionMatch.find(list, "/Users/roy/Documents/Q", emptySet()))
        assertTrue("trailing slash", StartedSessionMatch.find(list, "/Users/roy/x/", emptySet())?.id == "other")
    }
}
