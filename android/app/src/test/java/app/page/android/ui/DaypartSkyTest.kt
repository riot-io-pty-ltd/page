package app.page.android.ui

import app.page.android.model.Daypart
import app.page.android.model.DaypartTone
import app.page.android.model.DaypartWeights
import app.page.android.model.AuroraPhaseClock
import app.page.android.model.DuskDawnLog
import app.page.android.model.LaneGroup
import app.page.android.model.LaneRow
import app.page.android.model.LanesModel
import app.page.android.model.NowModel
import app.page.android.model.ProjectHue
import app.page.android.model.StarState
import app.page.android.ui.nw.components.nwAuroraPhase
import app.page.android.ui.nw.lanes.LanesDayBand
import app.page.android.ui.nw.lanes.LanesPowerStory
import app.page.android.ui.nw.lanes.lanesFleetMood
import app.page.android.ui.nw.shell.RenderHarness
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.PAUSED_STAR_FIELD
import app.page.android.ui.nw.theme.Rgba
import app.page.android.ui.nw.theme.starField
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs

/** The time of day on screen: the palettes the Now Horizon and Lanes draw from it, Lanes' power story over it, the harness pin, and the widgets that never read it. */
class DaypartSkyTest {
    private fun near(a: Double, b: Double, tol: Double = 1e-9) = abs(a - b) <= tol
    private val afternoon = DaypartWeights.at(Daypart.AFTERNOON.coreMinute)

    @Test fun `nighttime is today's palettes exactly, and dusk is never tinted`() {
        for (w in listOf(DaypartWeights.NIGHTTIME, DaypartWeights.at(1300.0), DaypartWeights.at(30.0))) {
            assertTrue(AuroraPalette.of(NowModel.Mood.NEEDS_YOU, w) === AuroraPalette.needsYou)
            assertTrue(AuroraPalette.of(NowModel.Mood.WORKING, w) === AuroraPalette.working)
            assertTrue(AuroraPalette.of(NowModel.Mood.QUIET, w) === AuroraPalette.quiet)
        }
        assertTrue("the default is nighttime", AuroraPalette.of(NowModel.Mood.WORKING) === AuroraPalette.working)
        for (m in listOf(0.0, 270.0, 345.0, 570.0, 720.0, 900.0, 1140.0)) {
            assertTrue("dusk returns the dusk itself at minute $m", AuroraPalette.of(NowModel.Mood.DUSK, DaypartWeights.at(m)) === AuroraPalette.dusk)
        }
    }

    @Test fun `any other hour builds the palette from that hour's tone`() {
        val tone = DaypartTone.blended(afternoon)
        val w = AuroraPalette.of(NowModel.Mood.WORKING, afternoon)
        assertEquals(Rgba.hex(0x5CE1BE), w.c1)
        assertEquals(Rgba.hex(0x113644), w.skyTop)
        assertTrue("working is half strength times the phase's", near(w.intensity, 0.4) && near(w.speed, 0.36))
        val q = AuroraPalette.of(NowModel.Mood.QUIET, afternoon)
        assertEquals("quiet takes the deeper top", Rgba.hex(0x0E2530), q.skyTop)
        assertTrue(near(q.intensity, 0.24) && near(q.speed, 0.27))
        val n = AuroraPalette.of(NowModel.Mood.NEEDS_YOU, afternoon)
        assertEquals("needs-you keeps its amber curtains at every hour", AuroraPalette.needsYou.c1, n.c1)
        assertEquals("only its sky takes the hour's hue", Rgba(tone.nyTop.r, tone.nyTop.g, tone.nyTop.b), n.skyTop)
        assertTrue(n.intensity == 1.0 && n.speed == 1.0)
        val blend = AuroraPalette.of(NowModel.Mood.WORKING, DaypartWeights.at(1140.0))
        assertNotEquals("the sunset is part way between afternoon and night", AuroraPalette.working, blend)
    }

    @Test fun `the star field falls from the hour's own to the same few stars at every hour`() {
        assertTrue("from the night it is today's", near(starField(0.0), 1.0) && near(starField(0.5), 1 - 0.95 * 0.5))
        assertTrue("from an afternoon with none it still settles on the paused few", near(starField(0.0, from = 0.0), 0.0) && near(starField(1.0, from = 0.0), PAUSED_STAR_FIELD))
        assertTrue(near(starField(1.0, from = 0.55), PAUSED_STAR_FIELD) && near(starField(1.0, from = 1.0), PAUSED_STAR_FIELD))
    }

    @Test fun `Lanes' power story falls from and rises back into the hour's sky, and a settled pause is the same at every hour`() {
        val base = AuroraPalette.of(NowModel.Mood.WORKING, afternoon)
        val day = LanesPowerStory(false, DuskDawnLog(), listOf("a"), base, afternoon.stars).skyLight(null, null)
        assertEquals("in the day the story's sky is the hour's", base, day.palette)
        assertTrue("with the hour's stars, and no cover (the day band shows)", day.stars == 0.0 && day.cover == 0.0)
        val night = LanesPowerStory(true, DuskDawnLog(), listOf("a")).skyLight(null, null)
        val settled = LanesPowerStory(true, DuskDawnLog(), listOf("a"), base, afternoon.stars).skyLight(null, null)
        assertEquals("a settled pause draws the same night from any hour", night.palette, settled.palette)
        assertTrue("and the same few stars", near(night.stars, PAUSED_STAR_FIELD) && near(settled.stars, PAUSED_STAR_FIELD) && settled.cover == 1.0)
    }

    private fun lanes(vararg states: StarState) = LanesModel(
        listOf(LaneGroup("p", "p", ProjectHue.TEAL, states.mapIndexed { i, s -> LaneRow("r$i", "r$i", s, emptyList(), null, "Claude", i.toULong(), "") })),
        emptyList(), null,
    )

    @Test fun `the day band is working while anything works or is paused, else quiet, and never amber`() {
        assertEquals(NowModel.Mood.WORKING, lanesFleetMood(lanes(StarState.IDLE, StarState.WORKING)))
        assertEquals("a lane paused for battery keeps the band's palette under the dusk", NowModel.Mood.WORKING, lanesFleetMood(lanes(StarState.PAUSED)))
        assertEquals("amber stays in the group heads", NowModel.Mood.QUIET, lanesFleetMood(lanes(StarState.NEEDS_YOU, StarState.STUCK, StarState.IDLE)))
        assertEquals(NowModel.Mood.QUIET, lanesFleetMood(LanesModel(emptyList(), emptyList(), null)))
    }

    @Test fun `the day band has iOS's geometry`() {
        assertEquals(280f, LanesDayBand.depth.value)
        assertTrue(LanesDayBand.opacity == 0.8 && LanesDayBand.scrimTop == 0.06)
        val ys = LanesDayBand.scrim.map { it.first }
        assertEquals(listOf(0f, 20f, 40f, 56f, 66f, 104f, 140f, 190f), ys)
        assertEquals(listOf(0.12, 0.24, 0.44, 0.64, 0.72, 0.72, 0.6, 0.36), LanesDayBand.scrim.map { it.second })
        assertTrue("every stop sits above the band's bottom", ys.all { it < LanesDayBand.depth.value })
    }

    @Test fun `a pinned frame keeps the plain phase, a live one accumulates it`() {
        val clock = AuroraPhaseClock()
        assertTrue("pinned at 2 s, working: 2 × 0.4 × 0.4, as before", near(nwAuroraPhase(2.0, AuroraPalette.working, clock, still = true), 0.32))
        val live = AuroraPhaseClock()
        val a = nwAuroraPhase(10_000.0, AuroraPalette.working, live, still = false)
        val b = nwAuroraPhase(10_000.1, AuroraPalette.of(NowModel.Mood.WORKING, afternoon), live, still = false)
        assertTrue("a time-of-day change moves the curtains at the new pace, never jumps them", near(b - a, 0.1 * 0.4 * 0.36, 1e-6))
    }

    @Test fun `the harness pins a local minute of the day`() {
        assertEquals(900.0, RenderHarness.minuteOfDay("afternoon")!!, 0.0)
        assertEquals(345.0, RenderHarness.minuteOfDay("earlyMorning")!!, 0.0)
        assertEquals(1140.0, RenderHarness.minuteOfDay("19:00")!!, 0.0)
        assertEquals(270.0, RenderHarness.minuteOfDay("270")!!, 0.0)
        assertEquals(330.0, RenderHarness.minuteOfDay("05:30")!!, 0.0)
        assertEquals(330.0, RenderHarness.minuteOfDay("5:30")!!, 0.0)
        for (bad in listOf(null, "24:00", "dusk", "1440", "7:5", "-1", "12:60", ":30", "12:", "abc")) assertNull(bad, RenderHarness.minuteOfDay(bad))
        assertNull("no pin draws 01:12", RenderHarness.Spec("now").dayTime)
        assertEquals("01:12 is nighttime's core", DaypartWeights.NIGHTTIME, DaypartWeights.at(Daypart.NIGHTTIME.coreMinute))
    }

    @Test fun `no widget reads the time of day`() {
        val root = listOf(File("src/main"), File("app/src/main")).firstOrNull { it.isDirectory }
        assertNotNull("the unit tests run from the app module", root)
        val widgets = File(root, "java/app/page/android/widget").listFiles()?.filter { it.extension == "kt" }.orEmpty()
        assertTrue("the scan reads the widget sources (${widgets.size})", widgets.size > 1)
        val readers = widgets.filter { f -> f.readText().let { "LocalDaypart" in it || "DaypartWeights.at(" in it || "rememberDaypartTicker" in it } }
        assertTrue("widgets stay at nighttime: $readers", readers.isEmpty())
    }
}
