package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Now in motion ([NowMotion]): the In flight arcs and bars, what ends, and the counts around them, number for number
 * with iOS/Tests/LogicTests.swift ("Now motion"). The table is the shared one: the same samples, the same values, on
 * both platforms.
 */
class NowMotionTest {
    private fun assertNear(msg: String, expected: Double, actual: Double, tol: Double = 1e-3) =
        assertTrue("$msg: expected $expected, got $actual", abs(actual - expected) <= tol)

    private val m = NowMotion

    private fun line(key: String, done: Int = 1, total: Int = 4, status: FlightLineStatus = FlightLineStatus.RUNNING) =
        FlightWorkflowLine(key, key, null, "$done/$total agents", done.toDouble() / total, key, status)

    // MARK: the shared table

    @Test fun `the shared table of sample values`() {
        // iOS/Tests/LogicTests.swift has these same rows, in this order (tolerance 1e-3).
        val table: List<Triple<String, Double, Double>> = listOf(
            Triple("arcEntrance(0.10, 0.6, 0)", 0.0, m.arcEntrance(0.10, 0.6, 0)),
            Triple("arcEntrance(0.375, 0.6, 0)", 0.0375, m.arcEntrance(0.375, 0.6, 0)),
            Triple("arcEntrance(0.60, 0.6, 0)", 0.30, m.arcEntrance(0.60, 0.6, 0)),
            Triple("arcEntrance(1.05, 0.6, 0)", 0.60, m.arcEntrance(1.05, 0.6, 0)),
            Triple("arcEntrance(2.0, 0.6, 0)", 0.60, m.arcEntrance(2.0, 0.6, 0)),
            Triple("entranceStart(strip 2)", 0.27, m.entranceStart(2, NowMotion.Place.STRIP)),
            Triple("entranceStart(card line 2)", 0.31, m.entranceStart(2, NowMotion.Place.CARD)),
            Triple("chipCount(0, 120)", 0.0, m.chipCount(0.0, 120).toDouble()),
            Triple("chipCount(0.19, 120)", 105.0, m.chipCount(0.19, 120).toDouble()),
            Triple("chipCount(0.38, 120)", 120.0, m.chipCount(0.38, 120).toDouble()),
            Triple("chipCount(1, 120)", 120.0, m.chipCount(1.0, 120).toDouble()),
            Triple("settledOpacity(0)", 1.0, m.settledOpacity(0.0)),
            Triple("settledOpacity(5)", 1.0, m.settledOpacity(5.0)),
            Triple("settledOpacity(62.5)", 0.775, m.settledOpacity(62.5)),
            Triple("settledOpacity(120)", 0.55, m.settledOpacity(120.0)),
            Triple("settledOpacity(600)", 0.55, m.settledOpacity(600.0)),
        )
        for ((name, expected, actual) in table) assertNear(name, expected, actual)
    }

    @Test fun `the badge bump peaks at 1·22 and is back to 1 by 0·6 s`() {
        val peak = (0..600).maxOf { m.badgeBump(it / 1000.0) }
        assertNear("peak", 1.22, peak)
        assertNear("t=0.6", 1.0, m.badgeBump(0.6), 0.01)
        assertNear("after", 1.0, m.badgeBump(2.0), 0.01)
        assertNear("before", 1.0, m.badgeBump(0.0), 0.01)
    }

    @Test fun `flight events come only from a line seen running that now says how it ended`() {
        val a = line("a")
        val b = line("b")
        // [running a,b] -> [running a, b done] = finished [b]
        val done = m.flightEvents(listOf(a, b), listOf(a, line("b", 4, 4, FlightLineStatus.DONE)))
        assertEquals(listOf("b"), done.finished.map { it.key })
        assertTrue(done.failed.isEmpty() && done.stopped.isEmpty())
        // [running a,b] -> [running a] (no status) = no events
        assertTrue(m.flightEvents(listOf(a, b), listOf(a)).isEmpty)
        // [] (first snapshot) -> [b done] = no events
        assertTrue(m.flightEvents(emptyList(), listOf(line("b", 4, 4, FlightLineStatus.DONE))).isEmpty)
        assertTrue(m.flightEvents(null, listOf(line("b", 4, 4, FlightLineStatus.DONE))).isEmpty)
        // Failed and stopped are told apart; a line that was already ended is not news again.
        val ev = m.flightEvents(listOf(a, b), listOf(line("a", status = FlightLineStatus.FAILED), line("b", status = FlightLineStatus.STOPPED)))
        assertEquals(listOf("a"), ev.failed.map { it.key })
        assertEquals(listOf("b"), ev.stopped.map { it.key })
        assertTrue(m.flightEvents(listOf(line("b", 4, 4, FlightLineStatus.DONE)), listOf(line("b", 4, 4, FlightLineStatus.DONE))).isEmpty)
    }

    // MARK: curves

    @Test fun `the entrance staggers by place and lands on the fraction`() {
        assertNear("strip 0", 0.15, m.entranceStart(0, NowMotion.Place.STRIP))
        assertNear("card 1", 0.23, m.entranceStart(1, NowMotion.Place.CARD))
        assertNear("strip 2 not started at 0.27", 0.0, m.arcEntrance(0.27, 0.6, 2, NowMotion.Place.STRIP))
        assertNear("card 2 lands", 0.6, m.arcEntrance(0.31 + 0.9, 0.6, 2, NowMotion.Place.CARD))
    }

    @Test fun `a moving fraction springs and flares`() {
        assertNear("spring starts at from", 0.6, m.spring(0.6, 0.8, 0.0))
        assertNear("spring settles exactly", 0.8, m.spring(0.6, 0.8, 1.0))
        val f0 = m.flare(0.0)!!
        assertNear("flare from radius", 1.0, f0.scale)
        assertNear("flare from opacity", 0.9, f0.opacity)
        val f1 = m.flare(0.5999)!!
        assertNear("flare to radius", 1.8, f1.scale, 1e-2)
        assertNear("flare to opacity", 0.4, f1.opacity, 1e-2)
        assertNull(m.flare(0.6))
        assertNull(m.flare(-0.01))
    }

    @Test fun `the glint runs every 2·4 s within the filled part and lags line by line`() {
        assertNear("start", 0.0, m.glint(0.0, 0))
        assertNear("half way", 0.5, m.glint(1.2, 0))
        assertNear("again", m.glint(0.3, 0), m.glint(2.7, 0), 1e-9)
        assertTrue("line 1 lags", m.glint(0.5, 1) < m.glint(0.5, 0))
        assertNear("enters before the start", -0.14, m.glintCentre(0.0, 0, 0.6))
        assertNear("leaves past the fill", 0.74, m.glintCentre(2.3999, 0, 0.6), 1e-3)
        // iOS's glint(1.2, 0).opacity: brightest half way, dark at either end.
        assertNear("brightest half way", 0.45, m.glintAlpha(1.2, 0))
        assertNear("dark at the start", 0.0, m.glintAlpha(0.0, 0))
    }

    @Test fun `the star breathes with the pulse and a stuck dot ripples every 3 s`() {
        assertNear("rest", 0.0, m.starBreath(0.0))
        assertNear("full", 1.0, m.starBreath(2.0))
        assertNear("tile 1 lags", 0.5 - 0.5 * kotlin.math.cos(-WorkflowMotion.phaseStep), m.starBreath(0.0, 1), 1e-9)
        assertNear("ripple starts", 0.0, m.healthRipple(0.0).progress)
        assertNear("ripple half open", 0.5, m.healthRipple(1.5).progress)
        assertNear("ripple again", 0.0, m.healthRipple(3.0).progress, 1e-9)
        // iOS's ring: from the dot's edge to 12 dp on easeOut, at 0.7 × the pulse's ring opacity.
        assertNear("ring from the dot", 3.5, m.healthRipple(0.0).radius)
        assertNear("ring half way out", 3.5 + 8.5 * 0.875, m.healthRipple(1.5).radius)
        assertNear("ring opacity", 0.7 * PulseModel.ringOpacity(0.5), m.healthRipple(1.5).opacity)
        assertTrue("never brighter than 0.7", (0..300).all { m.healthRipple(it / 100.0).opacity <= 0.7 + 1e-9 })
    }

    @Test fun `an ending closes, pulses once and folds, or turns amber, and under Reduce Motion only fades`() {
        val done = m.ghost(0.0, FlightLineStatus.DONE, 0.25)
        assertNear("from", 0.25, done.value)
        assertNull("no pulse before the arc closes", done.pulse)
        val closed = m.ghost(1.0, FlightLineStatus.DONE, 0.25)
        assertNear("closed", 1.0, closed.value)
        val p = m.ghost(WorkflowMotion.pulseDelay, FlightLineStatus.DONE, 0.25).pulse!!
        assertNear("pulse from the ring", 1.0, p.scale)
        assertNear("pulse opacity", 0.55, p.opacity)
        assertNear("whole until the fold", 1.0, m.ghost(1.5, FlightLineStatus.DONE, 0.25).height)
        assertNear("folded", 0.0, m.ghost(m.ghostDuration, FlightLineStatus.DONE, 0.25).height)
        // iOS's closing(1.775, done).fold: the fold eases out.
        assertNear("folding", 0.125, m.ghost(1.775, FlightLineStatus.DONE, 0.25).height)
        assertNear("about 2 s", 1.95, m.ghostDuration)
        val failed = m.ghost(WorkflowMotion.crossFade, FlightLineStatus.FAILED, 0.25)
        assertNear("failed holds", 0.25, failed.value)
        assertNear("failed amber", 1.0, failed.amber)
        assertNull("no pulse for a failure", m.ghost(0.6, FlightLineStatus.FAILED, 0.25).pulse)
        val reduced = m.ghost(0.1, FlightLineStatus.DONE, 0.25, reduce = true)
        assertNull(reduced.pulse)
        assertNear("reduce holds the value", 0.25, reduced.value)
        assertNear("reduce keeps the height", 1.0, reduced.height)
        assertEquals("✓ done", m.endedWord(FlightLineStatus.DONE))
        assertEquals("page: Docs sweep finished", m.announcement("page", "Docs sweep", FlightLineStatus.DONE))
        assertEquals("Docs sweep failed", m.announcement("page", "Docs sweep", FlightLineStatus.FAILED))
        assertEquals("Docs sweep stopped", m.announcement("page", "Docs sweep", FlightLineStatus.STOPPED))
    }

    // MARK: the grace window and the card

    private fun session(id: String = "w1", workflows: List<WorkflowBrief> = emptyList()) = LiveSession(
        id = id, backend = AgentBackend.fromWire("claude"), title = "relay", cwd = "~/projects/page", state = LiveSessionState.ACTIVE,
        host = "tmux", canType = true, typeBlocker = null, canInterrupt = true, provider = "anthropic", lastActivityAt = nwNow, interventionId = null,
        preview = "[Bash] vitest", flight = SessionFlight.make(null, null, null, listOf("Running vitest"), null, null, workflows),
    )

    private fun run(id: String, name: String, status: String, done: Int, total: Int) =
        WorkflowRun(id = id, name = name, status = status, done = done, total = total, endedAt = if (status == "running") null else nwNow)

    @Test fun `a run the phone saw end is kept a moment with how it ended, and only then`() {
        val book = FlightGraceBook()
        val s = listOf(session())
        val running = mapOf("w1" to listOf(run("wf_a", "Review", "running", 3, 5), run("wf_b", "Docs", "running", 1, 4)))
        val ended = mapOf("w1" to listOf(run("wf_a", "Review", "running", 3, 5), run("wf_b", "Docs", "completed", 4, 4)))
        // The first look keeps nothing, however recently a run finished.
        assertTrue(FlightGraceBook().observe(s, ended, nwNow).isEmpty())
        assertTrue(book.observe(s, running, nwNow).isEmpty())
        val kept = book.observe(s, ended, nwNow.plusMillis(500))
        assertEquals(mapOf("w1" to setOf("wf_b")), kept)
        val card = InFlightCard.build(s[0], ended["w1"]!!, now = nwNow, ended = kept["w1"]!!)
        assertEquals(listOf("wf_a", "wf_b"), card.workflows.map { it.key })
        assertEquals(FlightLineStatus.DONE, card.workflows[1].status)
        // Spoken words and the heading count what still runs.
        assertEquals("1 workflow running", card.workflowHeading)
        assertEquals(1, card.runningWorkflows.size)
        // Still kept within the grace, gone after it, and never again.
        assertEquals(mapOf("w1" to setOf("wf_b")), book.observe(s, ended, nwNow.plusMillis(2_400)))
        assertTrue(book.observe(s, ended, nwNow.plusMillis(2_600)).isEmpty())
        assertTrue(book.observe(s, ended, nwNow.plusMillis(3_000)).isEmpty())
        assertEquals(listOf("wf_a"), InFlightCard.build(s[0], ended["w1"]!!, now = nwNow).workflows.map { it.key })
    }

    @Test fun `a line that vanishes, a stalled run and an old finished run are never kept`() {
        val book = FlightGraceBook()
        val s = listOf(session())
        book.observe(s, mapOf("w1" to listOf(run("wf_a", "Review", "running", 3, 5), run("wf_b", "Docs", "running", 1, 4))), nwNow)
        val after = mapOf("w1" to listOf(run("wf_a", "Review", "stalled", 3, 5), run("wf_old", "Old", "completed", 2, 2)))
        assertTrue(book.observe(s, after, nwNow.plusSeconds(1)).isEmpty())
        assertTrue(InFlightCard.build(s[0], after["w1"]!!, now = nwNow).workflows.isEmpty())
    }

    @Test fun `the last run ending keeps the card on its runs, never a stale summary of the same name`() {
        val book = FlightGraceBook()
        val s = listOf(session(workflows = listOf(WorkflowBrief("Docs", null, 1, 4, "running"))))
        book.observe(s, mapOf("w1" to listOf(run("wf_b", "Docs", "running", 1, 4))), nwNow)
        val after = mapOf("w1" to listOf(run("wf_b", "Docs", "completed", 4, 4)))
        val kept = book.observe(s, after, nwNow.plusSeconds(1))
        val card = InFlightCard.build(s[0], after["w1"]!!, now = nwNow, ended = kept["w1"]!!)
        assertEquals(listOf("wf_b"), card.workflows.map { it.key })
        assertNull("nothing runs", card.workflowHeading)
        // After the grace the summary of the run that just ended is stale (the list has not caught up yet): it never
        // brings the finished workflow back as running, while a summary of another workflow still shows.
        assertTrue(InFlightCard.build(s[0], after["w1"]!!, now = nwNow).workflows.isEmpty())
        val other = session(workflows = listOf(WorkflowBrief("Docs", null, 1, 4, "running"), WorkflowBrief("Lint", null, 1, 2, "running")))
        assertEquals(listOf("Lint"), InFlightCard.build(other, after["w1"]!!, now = nwNow).workflows.map { it.key })
        // Long after it ended, a summary of the same name is a new run of it.
        assertEquals(listOf("Docs"), InFlightCard.build(s[0], after["w1"]!!, now = nwNow.plusSeconds(600)).workflows.map { it.key })
    }

    @Test fun `summaries are keyed by name, a repeated name numbered`() {
        val s = session(workflows = listOf(WorkflowBrief("Lint", null, 1, 2), WorkflowBrief("Lint", null, 0, 2), WorkflowBrief("Docs", null, 1, 4)))
        val card = InFlightCard.build(s, now = nwNow)
        assertEquals(listOf("Lint", "Lint#2", "Docs"), card.workflows.map { it.key })
        assertEquals(listOf("0-Lint", "1-Lint", "2-Docs"), card.workflows.map { it.id })
    }

    // MARK: the track

    private fun section(vararg runs: Pair<String, List<WorkflowRun>>, ended: Map<String, Set<String>> = emptyMap()): InFlightSection {
        val sessions = runs.map { session(it.first) }
        return InFlightSection.build(sessions, true, runs.toMap(), now = nwNow, ended = ended)
    }

    @Test fun `the track starts quiet, ghosts a line it saw end, and lets a vanished line go without a word`() {
        val books = NowMotion.Books()
        val a = run("wf_a", "Review", "running", 3, 5)
        val b = run("wf_b", "Docs", "running", 1, 4)
        val t0 = m.start(section("w1" to listOf(a, b)), 0.0, books)
        assertTrue(t0.ends.isEmpty())
        assertEquals(listOf("wf_a", "wf_b"), t0.slots["w1"])
        // Each line sweeps in from its first look.
        assertNear("sweeping", m.arcEntrance(0.5, 0.25, 1, NowMotion.Place.CARD), m.line(t0, t0.section.rows[0], t0.lines["w1"]!![1], 1, NowMotion.Place.CARD, 0.5, false).value)

        // b ends DONE at 2.0, and the Mac now lists it after the running one: it keeps its slot.
        val doneB = run("wf_b", "Docs", "completed", 4, 4)
        val t1 = m.observe(t0, section("w1" to listOf(a, doneB), ended = mapOf("w1" to setOf("wf_b"))), 2.0, books)
        assertEquals(setOf("w1|wf_b"), t1.ends.keys)
        assertEquals("page: Docs finished", m.said(t1, 2.1))
        assertEquals(listOf("wf_a", "wf_b"), m.drawn(t1, "w1", 2.5, false).map { it.key })
        val ghost = m.line(t1, t1.section.rows[0], doneB.let { t1.ends["w1|wf_b"]!!.line }, 1, NowMotion.Place.CARD, 3.5, false)
        assertNear("closed", 1.0, ghost.value)
        // The ghost plays on after the card's grace has dropped the line, then goes.
        val t2 = m.observe(t1, section("w1" to listOf(a)), 2.4, books)
        assertEquals(listOf("wf_a", "wf_b"), m.drawn(t2, "w1", 3.0, false).map { it.key })
        assertEquals(listOf("wf_a"), m.drawn(t2, "w1", 2.0 + m.ghostDuration + 0.01, false).map { it.key })

        // A line that just disappears: no ghost, no announcement.
        val v = m.observe(t0, section("w1" to listOf(a)), 2.0, books)
        assertTrue(v.ends.isEmpty())
        assertNull(m.said(v, 2.1))
        assertEquals(listOf("wf_a"), m.drawn(v, "w1", 2.2, false).map { it.key })
    }

    @Test fun `an ending plays once per run and not at all in a fresh start quiet window`() {
        val a = run("wf_a", "Review", "running", 3, 5)
        val done = run("wf_a", "Review", "completed", 5, 5)
        val books = NowMotion.Books()
        val t0 = m.start(section("w1" to listOf(a)), 0.0, books)
        val t1 = m.observe(t0, section("w1" to listOf(done), ended = mapOf("w1" to setOf("wf_a"))), 1.0, books)
        assertEquals(1, t1.ends.size)
        // The same run seen ending again (a rebuild of the section) is not a second ending.
        val again = m.observe(m.start(section("w1" to listOf(a)), 5.0, books), section("w1" to listOf(done), ended = mapOf("w1" to setOf("wf_a"))), 6.0, books)
        assertTrue(again.ends.isEmpty())
        // A resume's first snapshots are never news.
        val fresh = NowMotion.Books()
        val quiet = m.observe(m.start(section("w1" to listOf(a)), 0.0, fresh, quiet = 3.0), section("w1" to listOf(done), ended = mapOf("w1" to setOf("wf_a"))), 1.0, fresh)
        assertTrue(quiet.ends.isEmpty())
    }

    @Test fun `a new fraction springs with a flare and a line seen before shows at once`() {
        val books = NowMotion.Books()
        val t0 = m.start(section("w1" to listOf(run("wf_a", "Review", "running", 3, 5))), 0.0, books)
        val t1 = m.observe(t0, section("w1" to listOf(run("wf_a", "Review", "running", 4, 5))), 2.0, books)
        val row = t1.section.rows[0]
        val l = t1.lines["w1"]!![0]
        val f = m.line(t1, row, l, 0, NowMotion.Place.CARD, 2.0, false)
        assertNear("springs from the old", 0.6, f.value)
        assertNotNull(f.flare)
        assertNear("lands", 0.8, m.line(t1, row, l, 0, NowMotion.Place.CARD, 3.0, false).value)
        assertNull(m.line(t1, row, l, 0, NowMotion.Place.CARD, 3.0, false).flare)
        // A second look in the same process (a tab switch) shows the value at once.
        val back = m.start(section("w1" to listOf(run("wf_a", "Review", "running", 4, 5))), 10.0, books)
        assertNear("at once", 0.8, m.line(back, back.section.rows[0], back.lines["w1"]!![0], 0, NowMotion.Place.CARD, 10.0, false).value)
        assertTrue("no rise either", back.cardsIn.values.all { it < 10.0 })
        // Reduce Motion: the fraction at once, no loops.
        val r = m.line(t1, row, l, 0, NowMotion.Place.CARD, 2.0, true)
        assertNear("reduce", 0.8, r.value)
        assertFalse(r.live)
    }

    // MARK: the rest of Now: the Runway, the words, the badges, chips, Settled, the queued receipt

    @Test fun `the rest of Now's shared table`() {
        // iOS/Tests/LogicTests.swift ("Now motion, the rest of Now") has these same rows, in this order (tolerance 1e-3).
        val table: List<Triple<String, Double, Double>> = listOf(
            Triple("runwayLine(0)", m.runwayLine(0.0), 0.0), Triple("runwayLine(0.3)", m.runwayLine(0.3), 0.875), Triple("runwayLine(0.6)", m.runwayLine(0.6), 1.0),
            Triple("runwayReach(0.5)", m.runwayReach(0.5), 0.123790), Triple("runwayReach(1)", m.runwayReach(1.0), 0.6),
            Triple("markerStarts([0,0.5,0.52])[1]", m.markerStarts(listOf(0.0, 0.5, 0.52))[1], 0.123790), Triple("markerStarts([0,0.5,0.52])[2]", m.markerStarts(listOf(0.0, 0.5, 0.52))[2], 0.193790),
            Triple("markerStarts([0.5,0])[0]", m.markerStarts(listOf(0.5, 0.0))[0], 0.123790), Triple("markerStarts([0.5,0])[1]", m.markerStarts(listOf(0.5, 0.0))[1], 0.0),
            Triple("markerPop(0).scale", m.markerPop(0.0).scale, 0.6), Triple("markerPop(0).opacity", m.markerPop(0.0).opacity, 0.0),
            Triple("markerPop(0.0875).scale", m.markerPop(0.0875).scale, 0.89875), Triple("markerPop(0.0875).opacity", m.markerPop(0.0875).opacity, 0.980140),
            Triple("markerPop(0.175).scale", m.markerPop(0.175).scale, 1.01), Triple("markerPop(0.35).scale", m.markerPop(0.35).scale, 1.0),
            Triple("markerPop(0.35).opacity", m.markerPop(0.35).opacity, 1.0),
            Triple("markerGlide(0.2,0.4→0.3)", m.markerGlide(0.4, 0.3, 0.2), 0.39375), Triple("markerGlide(0.4,0.4→0.3)", m.markerGlide(0.4, 0.3, 0.4), 0.35),
            Triple("markerGlide(0.8,0.4→0.3)", m.markerGlide(0.4, 0.3, 0.8), 0.3),
            Triple("markerPassing(0.15).flash", m.markerPassing(0.15)?.flash ?: -1.0, 0.707107), Triple("markerPassing(0.15).opacity", m.markerPassing(0.15)?.opacity ?: -1.0, 0.84375),
            Triple("markerPassing(0.3).flash", m.markerPassing(0.3)?.flash ?: -1.0, 1.0), Triple("markerPassing(0.3).opacity", m.markerPassing(0.3)?.opacity ?: -1.0, 0.5),
            Triple("flashGlow(1).scale", m.flashGlow(1.0).scale, 1.8), Triple("flashGlow(0.5).opacity", m.flashGlow(0.5).opacity, 0.45),
            Triple("nowDot(0,4)", m.nowDot(0.0, 4.0), 0.0), Triple("nowDot(1,4)", m.nowDot(1.0, 4.0), 0.5), Triple("nowDot(2,4)", m.nowDot(2.0, 4.0), 1.0),
            Triple("reword(0.175).into.offset", m.reword(0.175)?.into?.offset ?: -1.0, 0.5), Triple("reword(0.175).into.opacity", m.reword(0.175)?.into?.opacity ?: -1.0, 0.875),
            Triple("reword(0.175).out.offset", m.reword(0.175)?.out?.offset ?: 1.0, -3.5), Triple("reword(0.175).out.opacity", m.reword(0.175)?.out?.opacity ?: -1.0, 0.125),
            Triple("reword(0.1,rm).into.offset", m.reword(0.1, reduce = true)?.into?.offset ?: -1.0, 0.0),
            Triple("reword(0.1,rm).into.opacity", m.reword(0.1, reduce = true)?.into?.opacity ?: -1.0, 0.875),
            Triple("chipCheck(0.38)", m.chipCheck(0.38), 0.0), Triple("chipCheck(0.53)", m.chipCheck(0.53), 0.875), Triple("chipCheck(0.68)", m.chipCheck(0.68), 1.0),
            Triple("receipt(0.175).offset", m.receipt(0.175).offset, -0.75), Triple("receipt(0.175).opacity", m.receipt(0.175).opacity, 0.875),
            Triple("receipt(0.175).height", m.receipt(0.175).height, 0.875), Triple("receipt(0.175).check", m.receipt(0.175).check, 0.0),
            Triple("receipt(0.5).check", m.receipt(0.5).check, 0.875), Triple("receipt(0.65).check", m.receipt(0.65).check, 1.0),
            Triple("receipt(0.1,rm).opacity", m.receipt(0.1, reduce = true).opacity, 0.875), Triple("receipt(0.1,rm).offset", m.receipt(0.1, reduce = true).offset, 0.0),
            Triple("badgeFrom", m.badgeFrom, 0.5), Triple("badgeResponse", m.badgeResponse, 0.35), Triple("badgeDamping", m.badgeDamping, 0.6),
            Triple("queuedFade", m.queuedFade, 0.3), Triple("queuedRise", m.queuedRise, 6.0), Triple("markerSlideMin", m.markerSlideMin, 0.003),
            Triple("receiptFresh", m.receiptFresh, 120.0),
        )
        for ((name, actual, expected) in table) assertNear(name, expected, actual)
        assertEquals("+105", m.chipText("+120", 0.19))
        assertEquals("0 files", m.chipText("3 files", 0.0))
        assertEquals("−14", m.chipText("−14", 0.38))
        assertEquals("tests ✓", m.chipText("tests ✓", 0.0))
        assertEquals("+120", m.chipText("+120", Double.POSITIVE_INFINITY))
        assertNull(m.markerPassing(0.6))
        assertNull(m.markerPassing(-0.01))
        assertNull(m.reword(0.35))
        assertNull(m.reword(0.2, reduce = true))
        assertFalse(m.rewords("2 need you", "3 need you"))
        assertTrue(m.rewords("1 needs you", "2 need you"))
        assertTrue(m.rewords("2 need you", "All quiet"))
        assertFalse(m.rewords("4 working · runway clear till 03:40", "5 working · runway clear till 03:10"))
        assertTrue(m.rewords("2 working · runway clear till 03:40", "2 working · on battery · 41%"))
        // The spec's numbers.
        assertTrue(m.runwayDraw == 0.6 && m.markerStagger == 0.07 && m.markerSlide == 0.8 && m.markerFlash == 0.6 && m.rewordDuration == WorkflowMotion.crossFade)
        assertTrue(m.rewordRise == 4.0 && m.receiptIn == 0.35 && m.receiptDrop == 6.0 && m.checkDraw == 0.3)
        // Android's own rows.
        val starts = m.markerStarts(listOf(0.244, 0.306, 0.411))
        assertNear("markerStarts[1] (the fixture's)", 0.1234, starts[1])
        assertNear("badge appears (0.1).scale", 0.8506, m.badge(NowMotion.Change(1, 0, 0.0), 0.1).scale)
        assertNear("badge leaves (0.25).scale", 0.5, m.badge(NowMotion.Change(0, 2, 0.0), 0.25).scale)
        assertNear("queuedIn(0.15).offset", 0.75, m.queuedIn(0.15).offset)
    }

    @Test fun `the Runway draws, pops its markers as the line reaches them, and is still under Reduce Motion`() {
        assertNear("not yet", 0.0, m.runwayLine(0.0))
        assertNear("reduce draws it whole", 1.0, m.runwayLine(0.0, reduce = true))
        // Left to right whatever order the markers come in, never closer than 0.07 s.
        val s = m.markerStarts(listOf(0.9, 0.1, 0.12))
        assertTrue(s[1] < s[2] && s[2] < s[0])
        assertNear("stagger", 0.07, s[2] - s[1])
        assertNear("reached when the line is there", m.runwayReach(0.9), s[0])
        val a = m.markerPop(-0.1)
        assertNear("before its start, small", 0.6, a.scale)
        assertNear("and unseen", 0.0, a.opacity)
        assertTrue("overshoots", (0..35).maxOf { m.markerPop(it / 100.0).scale } > 1.0)
        assertNear("lands", 1.0, m.markerPop(1.0).scale)
    }

    private fun marker(id: String, f: Double) = RunwayMarker(id, RunwayMarker.Kind.USAGE_RESET, "reset", nwNow, f, RunwayMarker.Tone.GREEN)

    @Test fun `a marker glides to a new place, drifts with the clock unanimated, and flashes as it reaches now`() {
        val t0 = m.runwayStart(listOf(marker("a", 0.2), marker("b", 0.5)), 0.0)
        assertNear("pops as the line reaches it", m.runwayReach(0.2), t0.pops["a"]!!)
        // The clock's drift: drawn at once, no glide, nothing to wait for.
        val drift = m.runwayObserve(t0, listOf(marker("a", 0.1995), marker("b", 0.4995)), 2.0)
        assertTrue(drift.glides.isEmpty())
        assertNear("drift settles with the entrance", m.runwaySettles(t0, false), m.runwaySettles(drift, false))
        // A jump glides over 0.8 s, easeInOut.
        val jump = m.runwayObserve(drift, listOf(marker("a", 0.1995), marker("b", 0.4)), 3.0)
        assertNear("from where it was", 0.4995, m.markerPlace(jump, "b", 3.0)!!)
        assertNear("half way", 0.44975, m.markerPlace(jump, "b", 3.4)!!)
        assertNear("there", 0.4, m.markerPlace(jump, "b", 3.8)!!)
        assertNear("settles", 3.8, m.runwaySettles(jump, false))
        // a reaches now (it was at the NOW dot) and flashes; b goes far out (the Mac went on power) and only fades.
        val near = m.runwayObserve(jump, listOf(marker("a", 0.004), marker("b", 0.4)), 5.0)
        val gone = m.runwayObserve(near, emptyList(), 6.0)
        assertTrue(gone.gone["a"]!!.reached)
        assertFalse(gone.gone["b"]!!.reached)
        assertNear("flash peaks", 1.0, m.markerLeave(0.3, true).flash)
        assertNear("gone after the flash", 0.0, m.markerLeave(m.markerFlash, true).opacity)
        assertNear("a fade has no flash", 0.0, m.markerLeave(0.1, false).flash)
        assertNear("faded", 0.0, m.markerLeave(m.markerGone, false).opacity)
        assertNear("all gone by", 6.0 + m.markerFlash, m.runwaySettles(gone, false))
        // The next of its kind under the same id (a reset that came round): the old one flashes at now, the new one pops, never a glide across.
        val at = m.runwayObserve(t0, listOf(marker("a", 0.001), marker("b", 0.5)), 2.0)
        val next = m.runwayObserve(at, listOf(marker("a", 0.8).copy(at = nwNow.plusSeconds(5 * 3600)), marker("b", 0.5)), 3.0)
        assertTrue(next.gone["a"]!!.reached)
        assertNull("no glide", next.glides["a"])
        assertNear("pops there", 0.8, m.markerPlace(next, "a", 3.0)!!)
        assertNear("pops now", 3.0, next.pops["a"]!!)
        // A newcomer pops in when it comes.
        val back = m.runwayObserve(gone, listOf(marker("c", 0.3)), 7.0)
        assertNear("c pops now", 7.0, back.pops["c"]!!)
        assertNear("c small", 0.6, m.marker(back, back.markers[0], 7.0).scale)
        // Reduce Motion: a jump is drawn at once, a newcomer fades in, nothing pops.
        val r = m.runwayObserve(t0, listOf(marker("a", 0.2), marker("b", 0.3), marker("c", 0.6)), 2.0, reduce = true)
        assertTrue(r.glides.isEmpty())
        assertNear("no pop", 1.0, m.marker(r, r.markers[2], 2.0, reduce = true).scale)
        assertNear("fades in", 0.0, m.marker(r, r.markers[2], 2.0, reduce = true).opacity)
        assertNear("faded in", 1.0, m.marker(r, r.markers[2], 2.2, reduce = true).opacity)
        // The live clock's drift: a marker whose time has come drops out.
        val model = RunwayModel(listOf(marker("x", 0.0).copy(at = nwNow.plusSeconds(60)), marker("y", 0.0).copy(at = nwNow.plusSeconds(3 * 3600))), false, null)
        assertEquals(listOf("y"), m.runwayAt(model, nwNow.plusSeconds(61)).map { it.id })
        assertNear("placed on the live clock", 0.5, m.runwayAt(model, nwNow).first { it.id == "y" }.fraction)
    }

    @Test fun `words roll their numbers and cross-fade a change of wording`() {
        fun roll(vararg runs: NowMotion.Run) = NowMotion.WordsChange.Roll(runs.toList())
        assertEquals(roll(NowMotion.Run(0, 1, "2", "3")), m.wordsChange("2 need you", "3 need you"))
        assertEquals(roll(NowMotion.Run(0, 2, "9", "10")), m.wordsChange("9 need you", "10 need you"))
        assertEquals(roll(NowMotion.Run(33, 35, "40", "55")), m.wordsChange("5 working · runway clear till 03:40", "5 working · runway clear till 03:55"))
        // Several numbers moving with the words the same all roll, each in its place (as iOS's numeric text does).
        assertEquals(roll(NowMotion.Run(0, 1, "5", "6"), NowMotion.Run(20, 22, "40", "55")), m.wordsChange("5 working · till 03:40", "6 working · till 03:55"))
        assertEquals(NowMotion.WordsChange.Fade, m.wordsChange("2 need you", "All quiet"))
        assertEquals(NowMotion.WordsChange.Fade, m.wordsChange("1 needs you", "2 need you"))
        assertNull(m.wordsChange("All quiet", "All quiet"))
        assertNear("rolled", 1.0, m.wordsProgress(0.35))
        assertNear("reduce fades in 0.2 s", 1.0, m.wordsProgress(0.2, reduce = true))
    }

    @Test fun `the working jump's two parts join back into the subline, so its count rolls`() {
        val s = "5 working · runway clear till 02:40"
        val (jump, rest) = HeaderJump.split(s, 5)!!
        assertEquals(s, jump + rest)
        assertEquals(NowMotion.WordsChange.Roll(listOf(NowMotion.Run(0, 1, "5", "6"))), m.wordsChange(s, "6" + s.drop(1)))
    }

    @Test fun `a change is played once and a script replays to the moment`() {
        val c = NowMotion.Change(2).observe(2, 1.0)
        assertNull(c.at)
        val d = c.observe(3, 2.0)
        assertEquals(NowMotion.Change(3, 2, 2.0), d)
        val script = listOf(0.0 to 2, 2.0 to 3)
        assertEquals(NowMotion.Change(2), m.replay(script, 1.9))
        assertEquals(NowMotion.Change(3, 2, 2.0), m.replay(script, 2.5))
        assertNull(m.replay(emptyList<Pair<Double, Int>>(), 1.0))
    }

    @Test fun `a badge bumps on a new count, scales in from nothing and out to nothing`() {
        val bump = m.badge(NowMotion.Change(3, 2, 0.0), 0.25)
        assertEquals(3, bump.count)
        assertEquals(2, bump.previous)
        assertNear("swells", 1.22, bump.scale)
        assertNull("rolled out", m.badge(NowMotion.Change(3, 2, 0.0), 0.4).previous)
        val inn = m.badge(NowMotion.Change(1, 0, 0.0), 0.0)
        assertNear("from half", 0.5, inn.scale)
        assertNear("unseen", 0.0, inn.opacity)
        assertNear("springs past 1", 1.0443, m.badge(NowMotion.Change(1, 0, 0.0), 0.2).scale)
        val out = m.badge(NowMotion.Change(0, 2, 0.0), 0.1)
        assertEquals("the old count while it goes", 2, out.count)
        assertTrue(out.scale < 1 && out.opacity < 1)
        assertNear("gone", 0.0, m.badge(NowMotion.Change(0, 2, 0.0), 1.0).opacity)
        val r = m.badge(NowMotion.Change(3, 2, 0.0), 0.1, reduce = true)
        assertNear("reduce: no swell", 1.0, r.scale)
        assertNear("reduce: a 0.2 s fade", 0.875, r.roll)
        assertNear("reduce: appears without scaling", 1.0, m.badge(NowMotion.Change(1, 0, 0.0), 0.1, reduce = true).scale)
    }

    @Test fun `chips count up and their check draws after`() {
        assertEquals("3 files", m.chipText("3 files", 0.38))
        assertEquals("reduce: at once", "+120", m.chipText("+120", 0.0, reduce = true))
        assertNear("no check during the count", 0.0, m.chipCheck(0.3))
        assertNear("drawn", 1.0, m.chipCheck(m.chipsLast))
        assertNear("reduce: whole", 1.0, m.chipCheck(0.0, reduce = true))
    }

    private fun settled(id: String, agoSeconds: Long) = SettledLine(id, SettledLine.Tone.APPROVED, "Approved $id", "now", "delivered ✓", nwNow.minusSeconds(agoSeconds))

    @Test fun `a new receipt slides in, a reload's old ones just appear, and receipts fade with age`() {
        val t0 = m.settledStart(listOf(settled("h1", 720), settled("h2", 1860)))
        assertTrue(t0.arrivals.isEmpty())
        val t1 = m.settledObserve(t0, listOf(settled("h0", 0), settled("h1", 720), settled("h2", 1860)), nwNow, 2.0)
        assertEquals(mapOf("h0" to 2.0), t1.arrivals)
        val r = m.receipt(0.0)
        assertNear("from above", -6.0, r.offset)
        assertNear("no room yet", 0.0, r.height)
        assertNear("check after the slide", 0.0, m.receipt(0.35).check)
        assertNear("check drawn", 1.0, m.receipt(0.65).check)
        // A reload that brings older lines: nothing arrives.
        val t2 = m.settledObserve(t1, listOf(settled("h0", 0), settled("h1", 720), settled("h2", 1860), settled("h3", 3600)), nwNow, 2.1)
        assertEquals(setOf("h0"), t2.arrivals.keys)
        assertTrue(m.settledObserve(t2, t2.ids.map { settled(it, 10) }.dropLast(1), nwNow, 9.0).arrivals.isEmpty())
        val reduce = m.receipt(0.1, reduce = true)
        assertNear("reduce: in place", 0.0, reduce.offset)
        assertNear("reduce: full height", 1.0, reduce.height)
    }
}
