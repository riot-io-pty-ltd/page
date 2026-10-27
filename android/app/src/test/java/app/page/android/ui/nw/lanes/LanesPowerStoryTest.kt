package app.page.android.ui.nw.lanes

import app.page.android.model.ActivityLog
import app.page.android.model.DawnModel
import app.page.android.model.DuskDawnLog
import app.page.android.model.LanesModel
import app.page.android.model.SkyModel
import app.page.android.model.StarState
import app.page.android.model.InterventionKind
import app.page.android.model.nwIv
import app.page.android.model.nwNow
import app.page.android.model.nwSession
import app.page.android.ui.nw.theme.NWMotionPin
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Dusk and dawn on Lanes (the moment the moon opened on iOS): a pause dusks the lanes and holds, and the power's
 * return dawns them, each paused lane relighting once its own resume is confirmed. Lanes rows route by what the
 * model gives them: a row with a decision opens the decision, the rest open the session.
 */
class LanesPowerStoryTest {
    private val t0: Instant = Instant.parse("2026-10-24T10:00:00Z")
    private val ids = listOf("a", "b", "c")

    private fun near(a: Double, b: Double, eps: Double = 1e-6) = kotlin.math.abs(a - b) < eps

    /** A pause that began at t0+10, with a and b working when it began. */
    private fun paused(): DuskDawnLog {
        val log = DuskDawnLog()
        log.observe(false, setOf("a", "b"), t0)
        log.observe(true, emptySet(), t0.plusSeconds(10))
        return log
    }

    /** A pause that has ended: the dawn began at t0+30 and a and b were seen working again at t0+31. */
    private fun dawning(): DuskDawnLog {
        val log = paused()
        log.observe(false, emptySet(), t0.plusSeconds(30))
        log.observe(false, setOf("a", "b"), t0.plusSeconds(31))
        return log
    }

    @Test fun `a pause dusks the lanes behind the list and the aurora holds`() {
        val story = LanesPowerStory(true, paused(), ids)
        assertTrue("the power story shows during a pause", story.isShown(t0.plusSeconds(12), null))
        val dusk = story.skyLight(t0.plusSeconds(12), NWMotionPin(NWMotionPin.Kind.DUSK, 1.6))
        assertTrue("the dusk has settled: the aurora is fully there", near(dusk.cover, 1.0) && near(dusk.band, 1.0))
        assertNull("no dawn is drawn during the dusk", dusk.dawn)
        assertTrue("the stars dim with the dusk", story.starLight("a", StarState.WORKING, t0.plusSeconds(12), NWMotionPin(NWMotionPin.Kind.DUSK, 1.6)).first < 1.0)
    }

    @Test fun `a settled pause holds still and draws the same dusk for as long as it lasts`() {
        val story = LanesPowerStory(true, paused(), ids)
        val later = t0.plusSeconds(3600)
        assertFalse("a settled pause needs no clock", story.isMoving(later, null))
        assertTrue("a settled pause is still shown", story.isShown(later, null))
        assertEquals(1.0, story.skyLight(later, null).cover, 1e-9)
        val until = story.movingUntil()
        assertNotNull("the dusk's end is a time to stop the clock", until)
        assertFalse("that time has passed, so the caller waits nothing", until!!.isAfter(later))
    }

    @Test fun `the power's return dawns the lanes up from the bottom and relights each lane only once its resume is confirmed`() {
        val log = dawning()
        val story = LanesPowerStory(false, log, ids)
        val now = t0.plusSeconds(31)
        assertTrue("the dawn plays", story.isMoving(now, null) && story.isShown(now, null))
        val light = story.skyLight(now, NWMotionPin(NWMotionPin.Kind.DAWN, 1.1))
        assertNotNull("the gold sweep is drawn during the dawn", light.dawn)
        assertTrue("a lane is dim until its own confirmed resume", story.starLight("a", StarState.WORKING, now, NWMotionPin(NWMotionPin.Kind.DAWN, 0.0)).first < 1.0)
        assertEquals("a session that was not paused is never dimmed by the dawn", 1.0, story.starLight("c", StarState.IDLE, now, NWMotionPin(NWMotionPin.Kind.DAWN, 0.0)).first, 1e-9)
        val full = story.starLight("a", StarState.WORKING, now, NWMotionPin(NWMotionPin.Kind.DAWN, 5.0)).first
        assertEquals("once the dawn has gone past its relight, the lane is full", 1.0, full, 1e-3)
    }

    @Test fun `the dawn ends and the lanes are back to the day, and the clock can stop`() {
        val story = LanesPowerStory(false, dawning(), ids)
        val end = story.movingUntil()
        assertNotNull("a dawn has an end to wait for", end)
        val after = end!!.plusSeconds(1)
        assertFalse(story.isMoving(after, null))
        val day = story.skyLight(after, null)
        assertEquals("the day draws nothing behind the list", 0.0, day.cover, 1e-9)
        assertNull(day.dawn)
        assertFalse("the day shows no power story", story.isShown(after, null))
    }

    @Test fun `Lanes rows open the decision when they have one and the session when they do not`() {
        val needs = nwSession("n1", title = "needs", state = "waitingOnApproval", cwd = "~/a/needs", interventionId = "p1")
        val work = nwSession("w1", title = "work", state = "active", cwd = "~/a/work")
        val sky = SkyModel.build(
            listOf(needs, work),
            listOf(nwIv("p1", InterventionKind.APPROVAL, "x", session = "n1")),
            null, emptyList(), "M", false, nwNow,
        )
        val rows = LanesModel.build(sky, ActivityLog(), nwNow).groups.flatMap { it.rows }.associateBy { it.id }
        assertEquals("p1", rows.getValue("n1").interventionId)
        assertNull("a working lane has no decision, so it opens the session", rows.getValue("w1").interventionId)
    }
}
