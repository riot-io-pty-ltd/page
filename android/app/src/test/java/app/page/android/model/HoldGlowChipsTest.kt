package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Card glow, the hold ring, and the turn-summary chips, ported from the "card glow, render arguments, turn chips"
 * and "Hold ring" checks in iOS/Tests/LogicTests.swift. (The iOS render-argument parser is the Android render
 * harness's intent extras, which are tested through the screens script, so it is not repeated here.)
 */
class HoldGlowChipsTest {
    private fun near(a: Double, b: Double, eps: Double = 1e-6) = abs(a - b) < eps

    // MARK: card glow

    @Test fun `glow defaults to Off and a missing or unknown stored value is Off`() {
        assertEquals(CardGlow.OFF, CardGlow.default)
        assertEquals("page.cardGlow", CardGlow.storageKey)
        assertEquals(CardGlow.OFF, CardGlow.stored(null))
        assertEquals(CardGlow.OFF, CardGlow.stored(""))
        assertEquals(CardGlow.OFF, CardGlow.stored("bogus"))
        assertEquals(CardGlow.SUBTLE, CardGlow.stored("subtle"))
        assertEquals(CardGlow.FULL, CardGlow.stored("full"))
        assertEquals(CardGlow.OFF, CardGlow.stored("off"))
    }

    @Test fun `strengths are 0, 0_5 and 1 and only Subtle and Full are on`() {
        assertEquals(0.0, CardGlow.OFF.strength, 0.0)
        assertEquals(0.5, CardGlow.SUBTLE.strength, 0.0)
        assertEquals(1.0, CardGlow.FULL.strength, 0.0)
        assertFalse(CardGlow.OFF.isOn)
        assertTrue(CardGlow.SUBTLE.isOn)
        assertTrue(CardGlow.FULL.isOn)
    }

    @Test fun `the argument is case-insensitive and a bad or missing one is null`() {
        assertEquals(CardGlow.FULL, CardGlow.argument("FULL"))
        assertNull(CardGlow.argument("x"))
        assertNull(CardGlow.argument(null))
    }

    @Test fun `the rim and the light follow the iOS curve for Subtle and Full`() {
        for (g in listOf(CardGlow.SUBTLE, CardGlow.FULL)) {
            assertEquals("$g rim is zero over the top half", 0.0, g.rimAlpha(0.0), 0.0)
            assertEquals("$g rim is zero at the midpoint", 0.0, g.rimAlpha(0.5), 0.0)
            assertTrue(near(g.rimAlpha(1.0), 0.42 * g.strength))
            var prev = -1.0
            var monotonic = true
            for (k in 0..100) {
                val v = g.rimAlpha(k / 100.0)
                if (v + 1e-12 < prev) monotonic = false
                prev = v
            }
            assertTrue("$g rim rises monotonically", monotonic)
            assertTrue("$g rim has no jump at the midpoint", g.rimAlpha(0.5 + 1e-4) < 1e-4)
            assertTrue("$g light starts at zero", near(g.lightAlpha(0.0), 0.0))
            assertTrue("$g light ends at bottomAlpha", near(g.lightAlpha(1.0), g.bottomAlpha))
            assertEquals("$g light is clamped below 0", 0.0, g.lightAlpha(-3.0), 0.0)
            assertTrue("$g light is clamped above 1", near(g.lightAlpha(9.0), g.bottomAlpha))
        }
        assertTrue(near(CardGlow.SUBTLE.bottomAlpha, 0.17))
        assertTrue(near(CardGlow.FULL.bottomAlpha, 0.34))
        assertEquals(0.0, CardGlow.OFF.rimAlpha(0.9), 0.0)
        assertEquals(0.0, CardGlow.OFF.lightAlpha(1.0), 0.0)
        assertEquals(0.0, CardGlow.OFF.bottomAlpha, 0.0)
        for (k in 1..100) {
            val t = k / 100.0
            assertTrue("full light is above subtle at $t", CardGlow.FULL.lightAlpha(t) > CardGlow.SUBTLE.lightAlpha(t))
        }
        assertTrue(CardGlow.FULL.rimAlpha(0.75) > CardGlow.SUBTLE.rimAlpha(0.75))
    }

    // MARK: the hold ring

    @Test fun `the Stop-all ring is hidden for the dead zone, half at 900 ms and complete at 1_5 s`() {
        val stop = HoldRingSpec.stopAll
        assertEquals(0.0, stop.progress(0.3), 0.0)
        assertFalse(stop.isVisible(0.3))
        assertTrue(near(stop.progress(0.9), 0.5))
        assertTrue("completes at 1.5 s", stop.isComplete(1.5))
        assertFalse("not yet at 1.49 s", stop.isComplete(1.49))
    }

    @Test fun `the irreversible ring fills over 1_2 s after the dead zone`() {
        val irr = HoldRingSpec.irreversible
        assertEquals(0.0, irr.progress(0.3), 0.0)
        assertFalse(irr.isVisible(0.3))
        assertTrue(near(irr.progress(0.9), 0.5))
        assertTrue(irr.isComplete(1.5))
    }

    @Test fun `ticks fall at 25, 50 and 75 percent, a firm one when full, and unwinding crosses none`() {
        val ticks = HoldRingSpec.ticksCrossed(0.2, 0.8)
        assertEquals(3, ticks.size)
        assertTrue(near(ticks[0], 0.25) && near(ticks[1], 0.5) && near(ticks[2], 0.75))
        assertEquals(listOf(1.0), HoldRingSpec.ticksCrossed(0.9, 1.0))
        assertTrue(HoldRingSpec.ticksCrossed(0.7, 0.3).isEmpty())
    }

    @Test fun `warmth is amber until two thirds, red at full, halfway at five sixths`() {
        assertTrue(near(HoldRingSpec.warmth(2.0 / 3), 0.0))
        assertTrue(near(HoldRingSpec.warmth(1.0), 1.0))
        assertTrue(near(HoldRingSpec.warmth(5.0 / 6), 0.5))
    }

    @Test fun `unwinding runs at the fill speed and is floored at zero`() {
        val stop = HoldRingSpec.stopAll
        assertTrue(near(stop.unwound(1.0, 0.6), 0.5))
        assertEquals(0.0, stop.unwound(0.2, 5.0), 0.0)
    }

    @Test fun `the Stop-all scope and the hold prompt read as the iOS copy`() {
        assertEquals("Press Esc in 4 busy sessions", HoldRingSpec.stopScope(4))
        assertEquals("Press Esc in 1 busy session", HoldRingSpec.stopScope(1))
        assertEquals("No busy sessions to stop", HoldRingSpec.stopScope(0))
        assertEquals("Hold to confirm", HoldRingSpec.prompt(0.0, "Face ID"))
        assertEquals("Keep holding · Face ID next", HoldRingSpec.prompt(0.5, "Face ID"))
        assertEquals("Face ID next", HoldRingSpec.prompt(1.0, "Face ID"))
    }

    @Test fun `the burst is committed sending, never delivered, and ends after its duration`() {
        val start = HoldRingSpec.burst(0.0)
        assertTrue(near(start.scale, 1.0))
        assertTrue(near(start.flash, 0.0))
        val mid = HoldRingSpec.burst(HoldRingSpec.burstDuration / 2)
        assertTrue("the ring opens out as it fades", mid.scale > 1.0 && mid.scale < 1.45)
        assertTrue("and is partly faded", mid.opacity in 0.01..0.9)
        val done = HoldRingSpec.burst(HoldRingSpec.burstDuration + 0.01)
        assertEquals(0.0, done.opacity, 0.0)
        assertEquals(1.0, done.scale, 0.0)
        assertEquals(0.0, done.flash, 0.0)
    }

    // MARK: turn-summary chips

    @Test fun `a turn summary becomes files, added, removed and tests chips in iOS order and tone`() {
        val s = TurnSummaryChips.parse("Changed 3 files (+120 −14) · tests passed")
        assertEquals(listOf("3 files", "+120", "−14", "tests ✓"), s.map { it.text })
        assertEquals(
            listOf(TurnChip.Tone.NEUTRAL, TurnChip.Tone.ADDED, TurnChip.Tone.REMOVED, TurnChip.Tone.PASS),
            s.map { it.tone },
        )
        assertEquals(listOf("1 file"), TurnSummaryChips.parse("Changed 1 file").map { it.text })
        assertEquals(listOf(TurnChip("tests ✗", TurnChip.Tone.FAIL)), TurnSummaryChips.parse("tests failed"))
        assertTrue(TurnSummaryChips.parse(null).isEmpty())
        assertTrue(TurnSummaryChips.parse("").isEmpty())
    }
}
