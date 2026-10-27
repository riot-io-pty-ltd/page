package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Health words read leniently, the stuck session ids, the Tower's scroll targets, the activity log's JSON round trip,
 * and the Now tips (one at a time, in priority order, retired once), ported from the "In flight", "Navigation" and
 * tips checks in iOS/Tests/LogicTests.swift.
 */
class ActivityTipsHealthTest {
    // MARK: health words

    @Test fun `health words are read leniently and an unknown word is nothing`() {
        assertEquals(FlightHealth.RATE_LIMITED, FlightHealth.from("rate_limited"))
        assertEquals(FlightHealth.STUCK, FlightHealth.from("looks-stuck"))
        assertEquals(FlightHealth.LONG_RUNNING, FlightHealth.from("longRunning"))
        assertNull(FlightHealth.from("weird"))
    }

    @Test fun `only an idle looping or stuck or stalled page marks its session as stuck`() {
        val ids = FlightHealth.stuckSessionIds(
            listOf(
                nwIv("a", InterventionKind.IDLE, "x", session = "s1", subtype = "looping"),
                nwIv("b", InterventionKind.IDLE, "x", session = "s2"),
                nwIv("c", InterventionKind.APPROVAL, "x", session = "s3", subtype = "stuck"),
            ),
        )
        assertEquals(setOf("s1"), ids)
    }

    // MARK: Tower scroll targets

    @Test fun `the runway opens the Tower at Budget, the moon at Power, and the chip opens nothing in particular`() {
        assertEquals(TowerSection.BUDGET, TowerScroll.target(TowerScroll.Source.RUNWAY))
        assertEquals(TowerSection.POWER, TowerScroll.target(TowerScroll.Source.MOON))
        assertNull(TowerScroll.target(TowerScroll.Source.CHIP))
    }

    // MARK: the activity log round trip

    @Test fun `the activity log round-trips through JSON and an unknown state is dropped on the way back`() {
        val log = ActivityLog()
        log.record(mapOf("s" to StarState.WORKING), nwNow)
        log.record(mapOf("s" to StarState.NEEDS_YOU), nwNow.plusSeconds(400))
        val back = ActivityLog.fromJson(log.toJson())
        assertEquals(log.strip("s", nwNow.plusSeconds(400), 4), back.strip("s", nwNow.plusSeconds(400), 4))
        assertEquals(log.observedSpan(nwNow.plusSeconds(400)), back.observedSpan(nwNow.plusSeconds(400)), 0.0)
        assertEquals(log.sessionCount, back.sessionCount)
        val garbled = ActivityLog.fromJson("""{"first":${nwNow.toEpochMilli()},"s":{"s":{"${ActivityLog.bucketIndex(nwNow)}":"weird","${ActivityLog.bucketIndex(nwNow) + 1}":"working"}}}""")
        val cells = garbled.strip("s", nwNow.plusSeconds(300), 4)
        assertNull("an unknown state is dropped on the way back", cells[cells.size - 2].level)
        assertEquals(StarState.WORKING, garbled.strip("s", nwNow.plusSeconds(300), 4).last().level)
        assertTrue(ActivityLog.fromJson(null).strip("s", nwNow, 4).all { it.level == null })
        assertFalse(ActivityLog.storageKey.isEmpty())
    }

    // MARK: the Now tips

    private fun row(id: String, ctx: String): NowRow = NowRowBuilder.row(nwIv(id, InterventionKind.APPROVAL, ctx, session = "w1"), null, "M")

    private val irrev = row("irr", "[Bash] rm -rf Builds/Dev/*.app\nDelete every Dev build")
    private val undo = row("und", "[Bash] swift test --filter StuckTests")

    private fun inputs(rows: List<NowRow>, inFlight: List<String> = emptyList(), busy: Set<String> = emptySet()) =
        NowTipInputs(rows = rows.map { it.id to it.chip }, inFlight = inFlight, busy = busy)

    @Test fun `the fixtures are one irreversible and one undoable row`() {
        assertEquals(ChipKind.IRREVERSIBLE, irrev.chip)
        assertEquals(ChipKind.UNDOABLE, undo.chip)
    }

    @Test fun `one tip at a time in priority order, each on the first row of its kind, never two at once`() {
        var book = TipBook()
        assertNull(book.nowTip(inputs(emptyList())))
        assertEquals(NowTipTarget(NWTip.SWIPE_TO_APPROVE, "und"), book.nowTip(inputs(listOf(undo))))
        assertEquals(NowTipTarget(NWTip.HOLD_TO_APPROVE, "irr"), book.nowTip(inputs(listOf(irrev))))
        assertEquals(
            "hold first, then swipe, then in flight: never two at once",
            NowTipTarget(NWTip.HOLD_TO_APPROVE, "irr"),
            book.nowTip(inputs(listOf(undo, irrev), inFlight = listOf("s-a"))),
        )
        assertEquals(NowTipTarget(NWTip.IN_FLIGHT, "s-a"), book.nowTip(inputs(emptyList(), inFlight = listOf("s-a", "s-b"))))
        assertNull("no tip points at a row with an action under way", book.nowTip(inputs(listOf(undo), busy = setOf("und"))))
        assertEquals(
            "it moves to the next row of its kind",
            "und2",
            book.nowTip(inputs(listOf(undo, row("und2", "[Bash] swift build")), busy = setOf("und")))?.anchorId,
        )
        assertEquals(NWTip.WILL_TYPE, book.decisionTip(hasPreview = true))
        assertNull(book.decisionTip(hasPreview = false))

        book = book.retire(NWTip.HOLD_TO_APPROVE)
        assertEquals("after the hold tip, the swipe tip", NowTipTarget(NWTip.SWIPE_TO_APPROVE, "und"), book.nowTip(inputs(listOf(undo, irrev))))
        book = book.retire(NWTip.SWIPE_TO_APPROVE).retire(NWTip.IN_FLIGHT)
        assertNull("every Now tip seen: none returns", book.nowTip(inputs(listOf(undo, irrev), inFlight = listOf("s-a"))))
        book = book.retire(NWTip.WILL_TYPE)
        assertNull("the Decision tip is shown once", book.decisionTip(hasPreview = true))
        book = book.reset()
        assertTrue(book.seen.isEmpty())
        assertEquals(NWTip.HOLD_TO_APPROVE, book.nowTip(inputs(listOf(irrev)))?.tip)
    }

    @Test fun `the tip copy names the phone's own check, and every tip has one gesture entry`() {
        assertEquals("Swipe right to approve — it can be undone", NWTip.SWIPE_TO_APPROVE.text())
        assertEquals("Hold to approve — fingerprint confirms", NWTip.HOLD_TO_APPROVE.text())
        assertEquals("Hold to approve — screen lock confirms", NWTip.HOLD_TO_APPROVE.text("screen lock"))
        assertEquals("Tap to watch it work · Steer to guide it", NWTip.IN_FLIGHT.text())
        assertEquals("Will type … shows exactly what lands on your Mac", NWTip.WILL_TYPE.text())
        for (tip in NWTip.entries) {
            assertTrue(GestureGuide.entry(tip) != null)
            assertFalse(tip.text().contains("{"))
        }
        assertEquals(NWTip.entries.size, GestureGuide.entries.count { it.tip != null })
        assertTrue(GestureGuide.entries.all { it.effect.isNotEmpty() && it.gesture.isNotEmpty() })
        assertEquals("Gestures & shortcuts", GestureGuide.title)
        assertEquals(3, GestureGuide.shortcuts.size)
    }

}
