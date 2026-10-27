package app.page.android.ui

import app.page.android.model.ApproachModel
import app.page.android.model.DawnModel
import app.page.android.model.DuskDawnLog
import app.page.android.model.SkyStar
import app.page.android.model.StarState
import app.page.android.data.NowTicker
import app.page.android.ui.nw.components.nwClockSleepMillis
import app.page.android.ui.nw.components.nwClockStepNanos
import app.page.android.ui.nw.now.ArrivalBook
import app.page.android.ui.nw.sky.SkyPowerStory
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.PAUSED_STAR_FIELD
import app.page.android.ui.nw.theme.starField
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import kotlin.math.abs

/** The pure halves of the signature-motion views: Sky's power story, the dusk palettes and the arrival book. */
class MotionViewsTest {
    private val t0: Instant = Instant.ofEpochSecond(1_793_063_520)
    private fun at(s: Double): Instant = t0.plusMillis((s * 1000).toLong())
    private fun near(a: Double, b: Double, tol: Double = 1e-6) = abs(a - b) <= tol

    private fun star(id: String, state: StarState, y: Double) = SkyStar(id, id, state, 0.5, y, 1.0, "", null, "Claude", true, 1UL)

    // region The dusk palettes

    @Test
    fun theSkyGoesThroughThePurpleDuskToTheNight() {
        val w = AuroraPalette.working
        assertEquals("no dusk yet is the working sky", w, w.towardNight(0.0))
        assertEquals("half way is the purple dusk (board 07, cutoff · dusk falls)", AuroraPalette.dusk, w.towardNight(0.5))
        assertEquals("then near-black night, horizon only", AuroraPalette.night, w.towardNight(1.0))
        assertEquals("clamped", AuroraPalette.night, w.towardNight(3.0))
        assertTrue("the star field fades with the dusk", near(starField(0.0), 1.0) && near(starField(1.0), PAUSED_STAR_FIELD))
        assertTrue("the Brief's sunrise is as bright as the absence was finished", near(AuroraPalette.brief(0.0).intensity, 0.25) && near(AuroraPalette.brief(1.0).intensity, 1.0))
    }

    // endregion

    // region Sky's power story

    @Test
    fun aPauseFallsAndIsDrawnSettledWhenStill() {
        val log = DuskDawnLog()
        log.observe(false, setOf("a", "b"), t0)
        log.observe(true, emptySet(), at(10.0))
        val stars = listOf(star("a", StarState.PAUSED, 0.3), star("b", StarState.PAUSED, 0.6), star("c", StarState.IDLE, 0.5))
        val story = SkyPowerStory(true, log, stars)
        assertTrue("dusk is falling 0.8 s in", near(story.duskElapsed(at(10.8), null)!!, 0.8, 1e-3))
        assertTrue("still moving while it falls", story.isMoving(at(10.8), null))
        assertFalse("and still once it has fallen: no clock", story.isMoving(at(12.0), null))
        assertEquals("drawn still (Remove animations) a pause is settled", DawnModel.duskDuration, story.duskElapsed(null, null)!!, 0.0)
        val light = story.skyLight(null, null)
        assertTrue("settled: the night, the band held, the stars all but gone", light.palette == AuroraPalette.night && near(light.band, 1.0) && near(light.stars, PAUSED_STAR_FIELD))
        assertNull("no dawn while paused", story.dawnElapsed(at(11.0), null))
        val (dim, scale) = story.starLight(stars[0], at(11.2), null)
        assertTrue("a paused star has exhaled and dimmed with the others", near(dim, DawnModel.dimTo, 1e-3) && near(scale, 0.9, 1e-3))
        assertEquals("an idle star that was not working stays as it is", 1.0 to 1.0, story.starLight(stars[2], at(11.2), null))
        assertTrue("the harness pins a moment", near(story.duskElapsed(at(99.0), NWMotionPin(NWMotionPin.Kind.DUSK, 0.7))!!, 0.7))
        assertEquals("its clocks stop when the dusk has fallen", at(10.0 + DawnModel.duskDuration), story.movingUntil())
    }

    @Test
    fun aPauseAlreadyUnderWayIsNotReplayed() {
        val log = DuskDawnLog()
        log.observe(true, setOf("a"), t0)
        val story = SkyPowerStory(true, log, listOf(star("a", StarState.PAUSED, 0.5)))
        assertEquals(DawnModel.duskDuration, story.duskElapsed(at(0.2), null)!!, 0.0)
        assertFalse("no clock for an old pause", story.isMoving(at(0.2), null))
        assertNull("and nothing to stop", story.movingUntil())
    }

    @Test
    fun theDawnRelightsOnlyConfirmedStarsOneByOne() {
        val log = DuskDawnLog()
        log.observe(false, setOf("a", "b", "c"), t0)
        log.observe(true, emptySet(), at(10.0))
        log.observe(false, emptySet(), at(20.0))
        log.observe(false, setOf("a"), at(20.3))
        log.observe(false, setOf("a", "b"), at(20.3))
        val stars = listOf(star("a", StarState.WORKING, 0.9), star("b", StarState.WORKING, 0.9), star("c", StarState.IDLE, 0.4))
        val story = SkyPowerStory(false, log, stars)
        assertNotNull("a confirmed star relights", story.relights["a"])
        assertNull("an unconfirmed star stays dim", story.relights["c"])
        assertTrue("one by one", (story.relights["b"]!! - story.relights["a"]!!) >= DawnModel.stagger - 1e-9)
        assertTrue("the dawn is playing", near(story.dawnElapsed(at(21.0), null)!!, 1.0, 1e-3) && story.isMoving(at(21.0), null))
        val light = story.skyLight(at(20.6), null)
        assertNotNull("the gold sweep is drawn", light.dawn)
        assertTrue("c is still dim at 2 s", near(story.starLight(stars[2], at(22.0), null).first, DawnModel.dimTo))
        assertTrue("a is back up by 2 s", story.starLight(stars[0], at(22.0), null).first > 0.95)
        assertNull("drawn still, no dawn plays", story.skyLight(null, null).dawn)
        assertFalse("and the dawn ends", story.isMoving(at(60.0), null))
        val until = story.movingUntil()!!
        assertTrue("its clocks stop as the dawn settles", story.isMoving(until.minusMillis(20), null) && !story.isMoving(until.plusMillis(20), null))
        assertEquals("then the working sky", AuroraPalette.working, story.skyLight(at(60.0), null).palette)
    }

    // endregion

    // region Final approach: which rows arrive

    @Test
    fun nothingArrivesOnTheFirstLookAndAFloodJustAppears() {
        val book = ArrivalBook()
        book.observe(emptyList(), loaded = false, animate = true, now = 100.0)
        book.observe(listOf("a", "b"), loaded = true, animate = true, now = 100.0)
        assertNull("the first look at a loaded inbox is no news", book.start("a"))
        book.observe(listOf("c", "a", "b"), loaded = true, animate = true, now = 101.0)
        assertEquals("a new row leaves the pulse now", 101.0, book.start("c")!!, 0.0)
        book.observe(listOf("d", "e", "c", "a", "b"), loaded = true, animate = true, now = 102.0)
        assertTrue("two together leave a stagger apart", near(book.start("d")!!, 102.0) && near(book.start("e")!!, 102.0 + ApproachModel.stagger))
        book.observe(listOf("f", "g", "h", "i", "d", "e", "c", "a", "b"), loaded = true, animate = true, now = 103.0)
        assertNull("more than three at once just appear", book.start("f"))
        book.observe(listOf("j", "f"), loaded = true, animate = false, now = 104.0)
        assertNull("Remove animations: nothing flies", book.start("j"))
        book.observe(listOf("j", "f"), loaded = true, animate = true, now = 120.0)
        assertNull("old starts are forgotten", book.start("c"))
    }

    // endregion

    // region The clocks' pacing

    @Test
    fun theClockSleepsBetweenTicksOnAGridEveryClockShares() {
        val ms = 1_000_000L
        val step30 = nwClockStepNanos(30.0)
        assertEquals("30 fps at the most", nwClockStepNanos(120.0), step30)
        assertEquals("at least 1 fps", 1_000_000_000L, nwClockStepNanos(0.0))
        val g = 1_000L * step30 // a grid line
        // Drawn late in a 60 Hz frame: sleeps to 4 ms before the next line, not one vsync.
        assertEquals(16L, nwClockSleepMillis(g + 12 * ms + 700_000, step30))
        // Drawn just before a line: that was the line's tick, so it sleeps to the one after (no tick drawn twice).
        assertEquals((step30 - 4 * ms + 2 * ms) / ms, nwClockSleepMillis(g - 2 * ms, step30))
        // Never negative, never a busy loop at the display's rate.
        for (off in 0 until step30 step ms) {
            val sleep = nwClockSleepMillis(g + off, step30)
            assertTrue("sleep $sleep ms at +${off / ms} ms", sleep in 0..(step30 / ms))
            // It always wakes before the next line and after this one has passed.
            val wake = g + off + sleep * ms
            assertTrue(wake <= g + 2 * step30 - 4 * ms + ms && wake >= g + off)
        }
        // A 20 fps and a 30 fps clock share lines every 100 ms (both wake for the same frame).
        val step20 = nwClockStepNanos(20.0)
        val t = 100 * ms * 7 + 13 * ms
        assertEquals(t + nwClockSleepMillis(t, step20) * ms + 4 * ms, 100 * ms * 7 + 50 * ms)
        assertEquals(t + nwClockSleepMillis(t, step30) * ms + 4 * ms, 100 * ms * 7 + 33 * ms)
    }

    @Test
    fun nowsClockTicksOnlyWhileSomeoneCanSeeIt() {
        assertEquals(15_000L, NowTicker.waitMillis(visible = true))
        assertEquals("off screen, once a minute", 60_000L, NowTicker.waitMillis(visible = false))
        assertTrue("the app is up", NowTicker.ticks(visible = true, holdingSocket = false))
        assertTrue("Stay connected's notification shows Now", NowTicker.ticks(visible = false, holdingSocket = true))
        assertFalse("nothing live shows it: no rebuilds", NowTicker.ticks(visible = false, holdingSocket = false))
    }

    // endregion
}
