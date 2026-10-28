package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.atan2

/**
 * The differential gate for the time of day: every row of `daypart-golden.tsv` was produced by compiling
 * iOS/Page/Models/Daypart.swift (see tools/daypart-golden.sh), and the iOS logic tests read the same file. The
 * Kotlin port must agree on every row: the four weights and the numbers within 0.0001, every colour within one level
 * a channel (Oklab's cbrt and pow on two VMs). A table edit that is not regenerated fails on both platforms.
 */
class DaypartGoldenTest {
    private fun rows(): List<List<String>> {
        val text = javaClass.classLoader!!.getResourceAsStream("daypart-golden.tsv")!!.bufferedReader(Charsets.UTF_8).readText()
        return text.split("\n").filter { it.isNotEmpty() && !it.startsWith("#") }.map { it.split("\t") }
    }

    private fun hexNear(cell: String, c: DaypartTone.Colour): Boolean {
        if (cell.length != 7 || cell[0] != '#') return false
        val g = DaypartTone.Colour.hex(cell.substring(1).toIntOrNull(16) ?: return false)
        return abs(g.r - c.r) * 255 <= 1.01 && abs(g.g - c.g) * 255 <= 1.01 && abs(g.b - c.b) * 255 <= 1.01
    }

    private fun hue(c: DaypartTone.Colour): Double {
        val o = PerceptualMix.oklab(c.rgb)
        val h = Math.toDegrees(atan2(o.b, o.a))
        return if (h < 0) h + 360 else h
    }

    @Test fun `every golden row matches the Swift model`() {
        val rows = rows()
        assertEquals("every 5 minutes, each window edge and edge ±1, 23:59 and 01:12", 306, rows.size)
        val mismatches = ArrayList<String>()
        for (r in rows) {
            assertEquals("18 columns at ${r.firstOrNull()}", 18, r.size)
            val (hh, mm) = r[0].split(":").map { it.toInt() }
            val w = DaypartWeights.at(hh * 60.0 + mm)
            val t = DaypartTone.blended(w)
            val nums = Daypart.entries.map { w.weight(it) } + listOf(t.working.intensity, t.working.speed, t.quiet.intensity, t.quiet.speed, w.stars)
            val cells = r.subList(1, 5) + r.subList(13, 18)
            val colours = listOf(t.working.c1, t.working.c2, t.working.c3, t.working.skyTop, t.working.skyBottom, t.quiet.skyTop, t.needsYou.skyTop, t.needsYou.skyBottom)
            val numbersOK = cells.zip(nums).all { (cell, want) -> cell.toDoubleOrNull()?.let { abs(it - want) <= 1e-4 } ?: false }
            val coloursOK = r.subList(5, 13).zip(colours).all { (cell, c) -> hexNear(cell, c) }
            if (!numbersOK || !coloursOK) mismatches += "${r[0]}: golden ${r.joinToString(" ")} | kotlin ${nums.joinToString(" ") { "%.4f".format(java.util.Locale.ROOT, it) }} ${colours.joinToString(" ") { it.hexString }}"
        }
        assertEquals("Kotlin disagrees with Daypart.swift on ${mismatches.size} rows (rerun android/tools/daypart-golden.sh after a table edit):\n" + mismatches.take(8).joinToString("\n"), 0, mismatches.size)
    }

    @Test fun `every golden row keeps the invariants`() {
        for (r in rows()) {
            val weights = r.subList(1, 5).map { it.toDouble() }
            assertTrue("${r[0]}: the weights sum to 1", abs(weights.sum() - 1) <= 1e-3)
            assertTrue("${r[0]}: at most two phases have weight", weights.count { it > 0 } <= 2)
            val wI = r[13].toDouble()
            val qI = r[15].toDouble()
            assertTrue("${r[0]}: needs-you (1.0) outshines working", 1.0 > wI)
            assertTrue("${r[0]}: quiet is three fifths of working", abs(qI / wI - 0.6) <= 1e-3)
            if (r[4] == "1.0000") {
                assertEquals("${r[0]}: nighttime is today's sky", listOf("#5EEAD4", "#38BDF8", "#6D5BD0", "#0B1B24", "#05070D", "#0A141C", "#1A1306", "#05070D"), r.subList(5, 13))
            }
            val c1 = hue(DaypartTone.Colour.hex(r[5].substring(1).toInt(16)))
            val c2 = hue(DaypartTone.Colour.hex(r[6].substring(1).toInt(16)))
            assertTrue("${r[0]}: c1 hue $c1 in (89, 250] and c2 $c2 in (105, 266], so the exhale's amber turns away from red", c1 > 89 && c1 <= 250.5 && c2 > 105 && c2 <= 266.5)
        }
    }
}
