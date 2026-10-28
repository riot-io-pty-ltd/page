package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/** The time of day: four phases across the local day, blended through windows; nighttime is today's aurora exactly. (iOS LogicTests "The time of day".) */
class DaypartTest {
    private fun dw(m: Double) = DaypartWeights.at(m)
    private fun near(a: Double, b: Double, eps: Double = 1e-9) = abs(a - b) <= eps
    private fun hex(h: Int) = DaypartTone.Colour.hex(h)

    private fun luminance(c: DaypartTone.Colour): Double {
        fun lin(x: Double) = if (x <= 0.04045) x / 12.92 else ((x + 0.055) / 1.055).pow(2.4)
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private fun whiteContrast(c: DaypartTone.Colour) = 1.05 / (luminance(c) + 0.05)

    private fun hue(c: DaypartTone.Colour): Double {
        val o = PerceptualMix.oklab(c.rgb)
        val h = Math.toDegrees(atan2(o.b, o.a))
        return if (h < 0) h + 360 else h
    }

    @Test fun `at most two phases have weight, the weights sum to 1 and they glide`() {
        var maxStep = 0.0
        var prev = dw(0.0)
        for (i in 1..1440 * 4) {
            val w = dw(i / 4.0)
            val ws = Daypart.entries.map { w.weight(it) }
            assertTrue("weights sum to 1 at ${i / 4.0}", abs(ws.sum() - 1) <= 1e-9)
            assertTrue("at most two at ${i / 4.0}", ws.count { it > 0 } <= 2 && ws.all { it in 0.0..1.0 })
            for (p in Daypart.entries) maxStep = max(maxStep, abs(w.weight(p) - prev.weight(p)))
            prev = w
        }
        assertTrue("no quarter minute moves a weight by 0.01 or more ($maxStep), across midnight too", maxStep < 0.01)
    }

    @Test fun `the windows are 04-05, 06h30-07h30, 11h30-12h30 and the two-hour sunset`() {
        assertTrue("01:12, the harness's clock, is nighttime's core", dw(72.0) == DaypartWeights.NIGHTTIME && DaypartWeights.NIGHTTIME.only == Daypart.NIGHTTIME)
        assertTrue("nighttime holds until 04:00, then blends", dw(239.9).only == Daypart.NIGHTTIME && dw(240.0).only == Daypart.NIGHTTIME && dw(241.0).only == null)
        assertTrue("04:30 is half night, half early morning", near(dw(270.0).weight(Daypart.NIGHTTIME), 0.5) && near(dw(270.0).weight(Daypart.EARLY_MORNING), 0.5))
        assertTrue("early morning's core is 05:00-06:30", dw(300.0).only == Daypart.EARLY_MORNING && dw(389.9).only == Daypart.EARLY_MORNING)
        assertTrue("07:00 is half way to morning", near(dw(420.0).weight(Daypart.EARLY_MORNING), 0.5) && near(dw(420.0).weight(Daypart.MORNING), 0.5))
        assertTrue("morning's core is 07:30-11:30", dw(450.0).only == Daypart.MORNING && dw(689.9).only == Daypart.MORNING)
        assertTrue("12:00 is half way to afternoon", near(dw(720.0).weight(Daypart.MORNING), 0.5) && near(dw(720.0).weight(Daypart.AFTERNOON), 0.5))
        assertTrue("afternoon's core is 12:30-18:00", dw(750.0).only == Daypart.AFTERNOON && dw(1079.9).only == Daypart.AFTERNOON)
        assertTrue(
            "the sunset runs a smoothstep over two hours: 18:15 has barely begun, 19:00 is half way",
            near(dw(1095.0).weight(Daypart.NIGHTTIME), MotionCurve.smooth(0.125)) && near(dw(1140.0).weight(Daypart.NIGHTTIME), 0.5),
        )
        assertTrue("nighttime from 20:00, across midnight", dw(1200.0).only == Daypart.NIGHTTIME && dw(1439.99).only == Daypart.NIGHTTIME && dw(0.0).only == Daypart.NIGHTTIME)
        assertTrue("the minute wraps round the day", dw(1440.0) == dw(0.0) && dw(-30.0) == dw(1410.0) && dw(1440.0 + 270) == dw(270.0))
        assertTrue("each phase's harness minute is in its own core", Daypart.entries.all { dw(it.coreMinute).only == it })
        assertTrue("two minutes in one core compare equal, so a tick there redraws nothing", dw(800.0) == dw(1000.0) && dw(800.0).hashCode() == dw(1000.0).hashCode())
    }

    @Test fun `the minute is the wall clock's, through DST and time zones`() {
        val ny = ZoneId.of("America/New_York")
        val spring = LocalDate.of(2026, 3, 8).atStartOfDay(ny).toInstant()
        assertEquals("spring forward: 4.5 hours after midnight the wall says 05:30, early morning, not 04:30", dw(330.0), DaypartWeights.at(spring.plusSeconds((4.5 * 3600).toLong()), ny))
        val fall = LocalDate.of(2026, 11, 1).atStartOfDay(ny).toInstant()
        assertEquals("fall back: 5.5 hours after midnight the wall says 04:30, the pre-dawn blend", dw(270.0), DaypartWeights.at(fall.plusSeconds((5.5 * 3600).toLong()), ny))
        // 14:13:20 UTC: 23:13 in Tokyo, 10:13 in New York.
        val instant = Instant.ofEpochSecond(1_790_000_000)
        assertTrue(
            "one instant is nighttime in Tokyo and morning in New York",
            DaypartWeights.at(instant, ZoneId.of("Asia/Tokyo")).only == Daypart.NIGHTTIME && DaypartWeights.at(instant, ny).only == Daypart.MORNING,
        )
    }

    @Test fun `nighttime is today's aurora byte for byte, and the stars are the clock's`() {
        val night = DaypartTone.blended(DaypartWeights.NIGHTTIME)
        assertTrue("at a core the table row comes back untouched", night === DaypartTone.nighttime)
        assertEquals(DaypartTone.Aurora(hex(0x5EEAD4), hex(0x38BDF8), hex(0x6D5BD0), hex(0x0B1B24), hex(0x05070D), 0.5, 0.4), night.working)
        assertEquals(DaypartTone.Aurora(hex(0x5EEAD4), hex(0x38BDF8), hex(0x6D5BD0), hex(0x0A141C), hex(0x05070D), 0.3, 0.3), night.quiet)
        assertEquals(DaypartTone.Aurora(hex(0xF5B14C), hex(0xF2C94C), hex(0xB45309), hex(0x1A1306), hex(0x05070D), 1.0, 1.0), night.needsYou)
        assertTrue(
            "all the stars at night, thinning through the morning, none in the afternoon",
            DaypartWeights.NIGHTTIME.stars == 1.0 && dw(330.0).stars == 0.55 && dw(570.0).stars == 0.2 && dw(900.0).stars == 0.0 && near(dw(270.0).stars, 0.775),
        )
    }

    @Test fun `every minute of the day needs-you still wins, white stays legible and amber never flashes red`() {
        var minTop = 99.0
        var minQuiet = 99.0
        var maxNeedsLum = 0.0
        for (m in 0 until 1440) {
            val t = DaypartTone.blended(dw(m.toDouble()))
            val w = t.working
            val q = t.quiet
            val n = t.needsYou
            assertTrue(
                "the moods hold at minute $m",
                n.intensity > w.intensity && near(q.intensity / w.intensity, 0.6) && q.c1 == w.c1 && q.c3 == w.c3 && n.c1 == hex(0xF5B14C) && n.speed == 1.0,
            )
            minTop = min(minTop, whiteContrast(w.skyTop))
            minQuiet = min(minQuiet, whiteContrast(q.skyTop))
            maxNeedsLum = max(maxNeedsLum, luminance(n.skyTop))
            val h1 = hue(w.c1)
            val h2 = hue(w.c2)
            assertTrue("c1 hue $h1 in (89, 250] and c2 $h2 in (105, 266] at minute $m", h1 > 89 && h1 <= 250 && h2 > 105 && h2 <= 266)
        }
        assertTrue("white on the working sky's top is at least 12.5:1 at every minute ($minTop)", minTop >= 12.5)
        assertTrue("the quiet sky is never brighter than working's ($minQuiet)", minQuiet >= 12.5 && minQuiet >= minTop)
        assertTrue("needs-you's sky takes the hour's hue, never its light ($maxNeedsLum)", maxNeedsLum < 0.00725 && luminance(DaypartTone.nighttime.nyTop) < 0.0071)
        assertTrue("the afternoon sky is brighter than the night's", whiteContrast(DaypartTone.afternoon.skyTop) < whiteContrast(DaypartTone.nighttime.skyTop))
    }

    @Test fun `the blend midpoints are the spec's`() {
        val predawn = DaypartTone.blended(dw(270.0))
        assertEquals("04:30: a teal-azure veil over violet, a plum haze rising", listOf("#5FCEE5", "#917CE8", "#1B0F1D"), listOf(predawn.c1, predawn.c3, predawn.skyBottom).map { it.hexString })
        val sunset = DaypartTone.blended(dw(1140.0))
        assertEquals("19:00: the gold haze sinks, c3 turns steel blue", listOf("#1E1712", "#6391BC"), listOf(sunset.skyBottom, sunset.c3).map { it.hexString })
    }

    @Test fun `the ticker steps on whole two minutes of the wall clock`() {
        assertEquals(Instant.ofEpochSecond(1080), DaypartClock.nextTick(Instant.ofEpochSecond(1000)))
        assertEquals("a tick exactly on the grid waits for the next one", Instant.ofEpochSecond(1200), DaypartClock.nextTick(Instant.ofEpochSecond(1080)))
        assertEquals(Instant.ofEpochSecond(1200), DaypartClock.nextTick(Instant.ofEpochSecond(1080, 500_000_000)))
    }

    @Test fun `the curtain phase accumulates, so a change of speed changes the pace, never the place`() {
        val wall = 815_000_000.5
        val pc = AuroraPhaseClock()
        val seed = pc.advance(wall, 0.4)
        assertTrue("the first call seeds from the clock", near(seed, (wall % 3600) * 0.4))
        val a1 = pc.advance(wall + 1.0 / 30, 0.4)
        val a2 = pc.advance(wall + 2.0 / 30, 0.44)
        assertTrue("a time-of-day tick moves the curtains one frame at the new pace, no jump", near(a1 - seed, 0.4 / 30, 1e-6) && near(a2 - a1, 0.44 / 30, 1e-6))
        assertTrue("(the old product would have jumped them by thousands)", abs((wall + 2.0 / 30) * 0.44 - a1) > 1000)
        val afterPause = pc.advance(wall + 600, 0.4)
        assertTrue("after a pause or a sheet it resumes where it left off", near(afterPause - a2, AuroraPhaseClock.maxStep * 0.4, 1e-6))
        assertEquals("a clock going back holds still", afterPause, pc.advance(wall, 0.4), 0.0)
        assertTrue("the shader's phase wraps, small values unchanged", AuroraPhaseClock.shaderPhase(3.0) == 3f && AuroraPhaseClock.shaderPhase(16_384.0 + 3) == 3f)
        assertTrue("a pinned frame's phase is the plain product (2 s at working speed)", AuroraPhaseClock.shaderPhase(2 * 0.4 * 0.4) == (0.32).toFloat())
    }

    @Test fun `the phases are named as on iOS`() {
        assertEquals(listOf("earlyMorning", "morning", "afternoon", "nighttime"), Daypart.entries.map { it.raw })
        assertEquals(Daypart.AFTERNOON, Daypart.of("afternoon"))
        assertNull(Daypart.of("dusk"))
    }
}
