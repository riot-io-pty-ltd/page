package app.page.android.model

import java.util.regex.Pattern

// Port of iOS/Page/Models/TurnSummaryChips.swift. The little chips on a Review
// card, read from the Mac's turn-summary line ("Changed 3 files (+120 −14) ·
// tests passed"). Anything the line does not say is simply not drawn: no chip
// is ever invented.

data class TurnChip(val text: String, val tone: Tone) {
    enum class Tone(val raw: String) { NEUTRAL("neutral"), ADDED("added"), REMOVED("removed"), PASS("pass"), FAIL("fail") }
}

object TurnSummaryChips {
    private val files = Rx.compile("""Changed (\d+) files?""")
    private val plus = Rx.compile("""\+(\d+)""")
    private val minus = Rx.compile("""[−-](\d+)\)""")

    private fun digits(s: String): String = Sw.chars(s).filter { Sw.isNumber(it) }.joinToString("")

    /** "3 files", "+120", "−14", "tests ✓" / "tests ✗". Pure. */
    fun parse(summary: String?): List<TurnChip> {
        val s = summary?.let { Sw.trimWsNl(it) }?.takeIf { it.isNotEmpty() } ?: return emptyList()
        val chips = ArrayList<TurnChip>()
        files.matcher(s).let { m ->
            if (m.find()) {
                val n = digits(m.group()).toIntOrNull() ?: 0
                chips.add(TurnChip("$n file${if (n == 1) "" else "s"}", TurnChip.Tone.NEUTRAL))
            }
        }
        plus.matcher(s).let { m -> if (m.find()) chips.add(TurnChip(m.group(), TurnChip.Tone.ADDED)) }
        minus.matcher(s).let { m -> if (m.find()) chips.add(TurnChip("−" + digits(m.group()), TurnChip.Tone.REMOVED)) }
        if (s.contains("tests passed")) chips.add(TurnChip("tests ✓", TurnChip.Tone.PASS))
        else if (s.contains("tests failed")) chips.add(TurnChip("tests ✗", TurnChip.Tone.FAIL))
        return chips
    }
}
