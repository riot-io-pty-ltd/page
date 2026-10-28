package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs

/**
 * The Workflows lens's motion ([WorkflowMotion]), number for number with iOS/Tests/LogicTests.swift ("Workflow motion").
 * The table is the shared one: the same samples, the same values, on both platforms.
 */
class WorkflowMotionTest {
    private fun assertNear(msg: String, expected: Double, actual: Double, tol: Double = 1e-9) =
        assertTrue("$msg: expected $expected, got $actual", abs(actual - expected) <= tol)

    private val m = WorkflowMotion

    // MARK: the shared table

    @Test fun `the shared table of sample values`() {
        // iOS/Tests/LogicTests.swift has these same rows, in this order.
        val table: List<Triple<String, Double, Double>> = listOf(
            Triple("easeOutBack(0.25)", 0.746875, m.easeOutBack(0.25)),
            Triple("easeOutBack(0.5)", 1.025, m.easeOutBack(0.5)),
            Triple("easeOutBack(0.75)", 1.040625, m.easeOutBack(0.75)),
            Triple("easeInOutCubic(0.25)", 0.0625, m.easeInOutCubic(0.25)),
            Triple("easeInOutCubic(0.75)", 0.9375, m.easeInOutCubic(0.75)),
            Triple("nodeStart(3,7)", 0.26, m.nodeStart(3, 7)),
            Triple("nodeStart(6,7)", 0.44, m.nodeStart(6, 7)),
            Triple("nodeStart(5,24)", 0.205, m.nodeStart(5, 24)),
            Triple("nodeEntrance(0.21).scale", 1.015, m.pop(0.21).scale),
            Triple("nodeEntrance(0.21).opacity", 0.925925926, m.pop(0.21).opacity),
            Triple("nodeEntrance(0.1).scale", 0.834143181, m.pop(0.1).scale),
            Triple("nodeEntrance(0.1).opacity", 0.347434682, m.pop(0.1).opacity),
            Triple("sweep(0.375)", 0.0625, m.sweep(0.375)),
            Triple("sweep(0.6)", 0.5, m.sweep(0.6)),
            Triple("sweep(0.9)", 0.981481481, m.sweep(0.9)),
            Triple("shownDone(0.45,4)", 1.0, m.shownDone(4, 0.45).toDouble()),
            Triple("shownDone(0.6,4)", 2.0, m.shownDone(4, 0.6).toDouble()),
            Triple("shownDone(0.75,4)", 3.0, m.shownDone(4, 0.75).toDouble()),
            Triple("shownDone(1.05,4)", 4.0, m.shownDone(4, 1.05).toDouble()),
            Triple("row(0.325,0).offset", 1.0, m.row(0.325, 0).offset),
            Triple("row(0.325,0).opacity", 0.875, m.row(0.325, 0).opacity),
            Triple("row(0.5,9).offset", 6.229504, m.row(0.5, 9).offset),
            Triple("breath(0.45,0)", 0.5, m.breath(0.45, 0)),
            Triple("breath(0.9,0)", 1.0, m.breath(0.9, 0)),
            Triple("breath(0,1)", 0.033836327, m.breath(0.0, 1)),
            Triple("breath(1.0,3)", 0.862096069, m.breath(1.0, 3)),
            Triple("ripple(1.2,0).radius", 24.0, m.ripple(1.2, 0).radius),
            Triple("ripple(1.2,0).opacity", 0.04375, m.ripple(1.2, 0).opacity),
            Triple("ripple(0.6,2).radius", 15.544594724, m.ripple(0.6, 2).radius),
            Triple("ripple(0.6,2).opacity", 0.22871199, m.ripple(0.6, 2).opacity),
            Triple("comet(2)", PI / 2, m.cometAngle(2.0)),
            Triple("comet(10)", PI / 2, m.cometAngle(10.0)),
            Triple("change(0.175,finished).mix", 0.875, m.change(0.175, WorkflowMotion.Change.FINISHED).mix),
            Triple("change(0.175,finished).fill", 0.925, m.change(0.175, WorkflowMotion.Change.FINISHED).fill ?: -1.0),
            Triple("change(0.175,finished).ring.radius", 23.03125, m.change(0.175, WorkflowMotion.Change.FINISHED).burst?.radius ?: -1.0),
            Triple("change(0.175,finished).ring.opacity", 0.2109375, m.change(0.175, WorkflowMotion.Change.FINISHED).burst?.opacity ?: -1.0),
            Triple("change(0.35,failed).ring.radius", 30.75, m.change(0.35, WorkflowMotion.Change.FAILED).burst?.radius ?: -1.0),
            Triple("change(0.35,failed).ring.opacity", 0.0625, m.change(0.35, WorkflowMotion.Change.FAILED).burst?.opacity ?: -1.0),
            Triple("pulse(0.55).scale", 1.30625, m.pulse(0.55)?.scale ?: -1.0),
            Triple("pulse(0.55).opacity", 0.06875, m.pulse(0.55)?.opacity ?: -1.0),
            Triple("bump(0.125)", 1.042426407, m.bump(0.125)),
            Triple("bump(0.25)", 1.06, m.bump(0.25)),
        )
        for ((name, expected, actual) in table) assertNear("workflow motion $name", expected, actual, 1e-6)
        assertTrue("a node enters from 0.4, unseen, and lands at 1", abs(m.pop(0.0).scale - 0.4) < 1e-9 && m.pop(0.0).opacity == 0.0 && abs(m.pop(0.42).scale - 1) < 1e-9 && m.pop(0.42).opacity == 1.0 && m.pop(-1.0).opacity == 0.0)
        assertTrue(
            "only a finished node fills; one ring, finished or failed",
            m.change(0.175, WorkflowMotion.Change.FAILED).fill == null && m.change(0.35, WorkflowMotion.Change.FINISHED).fill == null &&
                m.change(0.7, WorkflowMotion.Change.FINISHED).burst == null && m.change(0.1, WorkflowMotion.Change.STOPPED).burst == null,
        )
        val calm = m.change(0.1, WorkflowMotion.Change.FINISHED, reduce = true)
        assertTrue("Reduce Motion: a 0.2 s cross-fade, no fill, no ring", abs(calm.mix - 0.875) < 1e-9 && calm.fill == null && calm.burst == null)
        assertTrue("the pulse and the bump play once, then nothing", m.pulse(-0.01) == null && m.pulse(1.1) == null && m.bump(0.0) == 1.0 && m.bump(0.5) == 1.0)
        assertTrue("Reduce Motion rows fade in place", m.row(0.0, 0, true) == WorkflowMotion.Rise(0.0, 0.0) && m.row(0.2, 30, true) == WorkflowMotion.Rise(0.0, 1.0))
        assertEquals("rows after the eighth appear with it", m.rowStart(7), m.rowStart(20), 0.0)
        // Android's own extras on the same curves.
        assertNear("entranceDuration(7)", 1.05, m.entranceDuration(7))
        assertNear("entranceDuration(24)", 1.075, m.entranceDuration(24))
        assertNear("trackOpacity(0.175)", 0.875, m.trackOpacity(0.175))
        assertNear("spring(0.5)", 1.0037800704149629, MotionCurve.spring(0.5, m.springResponse, m.springDamping))
    }

    // MARK: fixtures: the board's run, 4/7 with 2 running and 1 failed

    private fun agent(id: String, label: String, state: String) = WorkflowRun.Agent(id, label, "Verify", state, null)

    private val board = WorkflowRun(
        id = "wf1", name = "review-changes", status = "running", done = 4, total = 7,
        agents = listOf(
            agent("a1", "verify: SessionsView sort order", "running"), agent("a2", "verify: iOS logic tests", "running"),
            agent("a3", "verify: Android parity", "failed"), agent("a4", "review: InterventionDetector", "done"),
            agent("a5", "review: SessionStore", "done"), agent("a6", "plan: split", "done"), agent("a7", "plan: scope", "done"),
        ),
    )
    private val finished = board.copy(done = 5, agents = board.agents.map { if (it.id == "a2") it.copy(state = "done") else it })
    private val lastOne = board.copy(done = 6, agents = board.agents.map { if (it.id == "a1") it else it.copy(state = "done") })
    private val complete = lastOne.copy(status = "completed", done = 7, agents = lastOne.agents.map { it.copy(state = "done") })

    private fun orbit(r: WorkflowRun) = WorkflowOrbit.build(r, nwNow)

    // MARK: events

    @Test fun `events name who finished, failed, stopped or joined, and when the run completes`() {
        val e = m.events(orbit(board), orbit(finished))
        assertEquals(listOf("a2"), e.finished)
        assertTrue(e.failed.isEmpty() && e.stopped.isEmpty() && e.added.isEmpty() && !e.completed)
        val failed = m.events(orbit(board), orbit(board.copy(agents = board.agents.map { if (it.id == "a1") it.copy(state = "failed") else it })))
        assertEquals(listOf("a1"), failed.failed)
        val stopped = m.events(orbit(board), orbit(board.copy(status = "killed", agents = board.agents.map { if (it.running) it.copy(state = "stopped") else it })))
        assertEquals(setOf("a1", "a2"), stopped.stopped.toSet())
        assertTrue("4 done, 1 failed, 2 stopped of 7, killed: complete", stopped.completed)
        val grew = m.events(orbit(board), orbit(board.copy(total = 8, agents = board.agents + agent("a8", "verify: Mac", "running"))))
        assertEquals(listOf("a8"), grew.added)
        val done = m.events(orbit(lastOne), orbit(complete))
        assertEquals(listOf("a1"), done.finished)
        assertTrue(done.completed)
        assertTrue("nothing changed", m.events(orbit(board), orbit(board)).isEmpty)
        assertFalse("a running run is never complete", m.isComplete(orbit(board.copy(done = 7))))
        // The Mac lists at most 100 agents, running first: a big run whose unlisted agents failed still completes.
        val big = WorkflowRun(id = "big", name = "big", status = "completed", done = 140, total = 150, agents = (1..100).map { agent("b$it", "b$it", "done") })
        assertTrue("a run of 150 agents, 100 listed, completes", m.isComplete(orbit(big)))
        assertFalse("nor an empty one", m.isComplete(orbit(board.copy(status = "completed", done = 0, total = 0, agents = emptyList()))))
        // A stall marks its unfinished agents stopped, but the run may go on: no completion, no pulse spent.
        val stalled = m.events(orbit(board), orbit(board.copy(status = "stalled", agents = board.agents.map { if (it.running) it.copy(state = "stopped") else it })))
        assertEquals(setOf("a1", "a2"), stalled.stopped.toSet())
        assertFalse("a stalled run has not ended", stalled.completed)
        // A done agent that was never seen running is not a finish (it is a newcomer or nothing).
        assertTrue(m.events(orbit(board.copy(agents = board.agents.take(6))), orbit(board)).finished.isEmpty())
    }

    @Test fun `the orbit is one sentence for TalkBack and a change is announced once, politely`() {
        assertEquals("4 of 7 agents done, 2 running, 1 failed", m.summary(orbit(board)))
        assertEquals("7 of 7 agents done", m.summary(orbit(complete)))
        assertEquals("verify: iOS logic tests finished", m.announcement(orbit(finished), m.events(orbit(board), orbit(finished))))
        assertEquals("review-changes: all 7 agents done", m.announcement(orbit(complete), m.events(orbit(lastOne), orbit(complete))))
        val both = board.copy(agents = board.agents.map { when (it.id) { "a1" -> it.copy(state = "done"); "a2" -> it.copy(state = "failed"); else -> it } })
        assertEquals("a finish is said before a failure", "verify: SessionsView sort order finished", m.announcement(orbit(both), m.events(orbit(board), orbit(both))))
        val killed = board.copy(status = "killed", agents = board.agents.map { if (it.running) it.copy(state = "stopped") else it })
        assertEquals("review-changes: finished, 4 of 7 agents done, 3 didn't", m.announcement(orbit(killed), m.events(orbit(board), orbit(killed))))
        assertNull("a newcomer is not announced", m.announcement(orbit(board), WorkflowMotion.Events(emptyList(), emptyList(), emptyList(), listOf("a9"), false)))
    }

    // MARK: the entrance

    @Test fun `the entrance sweeps the arc and counts the centre up with it, then settles`() {
        val track = m.start(orbit(board), 0.0, OneShotBook())
        assertNear("no arc before the sweep", 0.0, m.arc(track, 0.1, false))
        assertNear("half way at 0.6 s", 4.0 / 7 * 0.5, m.arc(track, 0.6, false))
        assertNear("done/total once swept", 4.0 / 7, m.arc(track, 1.2, false))
        assertEquals(0, m.count(track, 0.1, false).value)
        assertEquals(2, m.count(track, 0.6, false).value)
        assertEquals(4, m.count(track, 1.2, false).value)
        val first = m.nodes(track, 0.0, false).first()
        assertEquals("slot 0 is 12 o'clock", 0.0, first.angle, 0.0)
        assertNear("nothing drawn at 0", 0.0, first.opacity)
        assertTrue("every node has landed by 1.05 s", m.nodes(track, 1.05, false).all { abs(it.scale - 1) < 1e-9 && abs(it.opacity - 1) < 1e-9 })
        assertNull("a running run has no pulse", m.pulse(track, 1.5, false))
    }

    @Test fun `running nodes breathe and ripple, each on its own phase, and finished ones are still`() {
        val track = m.start(orbit(board), 0.0, OneShotBook())
        val frames = m.nodes(track, 2.0, false)
        val running = frames.filter { it.node.state == WorkflowOrbit.NodeState.RUNNING }
        assertEquals(2, running.size)
        assertNear("slot 1 breathes 0.37 rad ahead", m.breath(2.0, 1), running[1].breath)
        assertNotNull(running[0].ripple)
        assertTrue(frames.filter { it.node.state != WorkflowOrbit.NodeState.RUNNING }.all { it.breath == 0.0 && it.ripple == null })
    }

    // MARK: changes while open

    @Test fun `an agent finishing cross-fades, fills in place and sends one ring, and the arc springs to the new fraction`() {
        val book = OneShotBook()
        val t0 = m.start(orbit(board), 0.0, book)
        val t1 = m.observe(t0, orbit(finished), 2.0, book)
        assertEquals("the slots stay put", t0.slots, t1.slots)
        val node = { now: Double -> m.nodes(t1, now, false).first { it.node.id == "a2" } }
        assertEquals(WorkflowOrbit.NodeState.RUNNING, node(2.0).from)
        assertNear("cross-fade starts", 0.0, node(2.0).mix)
        assertNear("easeOut, 0.875 at 0.175 s", 0.875, node(2.175).mix)
        assertNear("the disc fills, easeOut", 0.925, node(2.175).fill!!)
        assertNear("the ring, 8 → 34 dp", 8 + 26 * 0.578125, node(2.175).burst!!.radius)
        assertNull("filled by 0.35 s", node(2.35).fill)
        assertNull("the ring has gone by 0.7 s", node(2.7).burst)
        assertNear("the arc starts where it was", 4.0 / 7, m.arc(t1, 2.0, false))
        assertNear("and springs to 5/7 (the shared table)", 0.668737999, m.arc(t1, 2.2, false), 1e-6)
        assertNear("the shared table", 0.714825724, m.arc(t1, 2.5, false), 1e-6)
        assertEquals("exactly 5/7 once settled", 5.0 / 7, m.arc(t1, 3.0, false), 0.0)
        val roll = m.count(t1, 2.175, false)
        assertEquals(5, roll.value)
        assertEquals(4, roll.previous)
        assertNear("the count rolls, easeOut", 0.875, roll.roll)
        assertNull("rolled by 0.35 s", m.count(t1, 2.35, false).previous)
        assertEquals("verify: iOS logic tests finished", m.announcement(t1.orbit, t1.events!!))
    }

    @Test fun `the last agent fills where it was, though the orbit would sort it elsewhere`() {
        val book = OneShotBook()
        val t0 = m.start(orbit(lastOne), 0.0, book)
        assertEquals("the running agent leads", "a1", t0.slots.first())
        val t1 = m.observe(t0, orbit(complete), 2.0, book)
        assertEquals("a1", t1.slots.first())
        assertEquals("a1", m.nodes(t1, 3.0, false).first().node.id)
    }

    @Test fun `a newcomer joins at the end, pops in, and the ring re-spaces smoothly`() {
        val book = OneShotBook()
        val t0 = m.start(orbit(board), 0.0, book)
        val grown = board.copy(total = 8, agents = board.agents + agent("a8", "verify: Mac", "running"))
        val t1 = m.observe(t0, orbit(grown), 3.0, book)
        assertEquals("a8", t1.slots.last())
        val joined = { now: Double -> m.nodes(t1, now, false).first { it.node.id == "a8" } }
        assertNear("pops in from 0.4", 0.4, joined(3.0).scale)
        assertNear("landed", 1.0, joined(3.42).scale)
        val second = { now: Double -> m.nodes(t1, now, false)[1].angle }
        assertNear("slot 1 starts at 1/7 of the ring", 2 * PI / 7, second(3.0))
        assertNear("and glides to 1/8 on the arc's spring", 2 * PI / 7 + (2 * PI / 8 - 2 * PI / 7) * MotionCurve.spring(0.3, 0.6, 0.85), second(3.3))
        assertEquals("exactly there once settled", 2 * PI / 8, second(4.0), 0.0)
        assertEquals("at once with Reduce Motion", 2 * PI / 8, m.nodes(t1, 3.0, true)[1].angle, 0.0)
        assertNear("the arc re-scales to 4/8", 0.5, m.arc(t1, 4.0, false), 1e-3)
    }

    // MARK: completion

    @Test fun `the ring closes with one pulse, once per run, after the arc has closed`() {
        val book = OneShotBook()
        val t1 = m.observe(m.start(orbit(lastOne), 0.0, book), orbit(complete), 2.0, book)
        assertEquals(2.5, t1.completedAt!!, 1e-12)
        assertNull("not before the arc has closed", m.pulse(t1, 2.4, false))
        val p = m.pulse(t1, 2.75, false)!!
        assertNear("ring", 1.1885095792637115, p.ringScale)
        assertNear("opacity", 0.2537706611570248, p.ringOpacity)
        assertNear("the text swells to 1.06", 1.06, p.textScale)
        assertNear("ring at 0.55 s", 1.30625, m.pulse(t1, 3.05, false)!!.ringScale)
        assertNear("opacity at 0.55 s", 0.06875, m.pulse(t1, 3.05, false)!!.ringOpacity)
        assertNull("over by 1.1 s", m.pulse(t1, 3.6, false))
        assertEquals("review-changes: all 7 agents done", m.announcement(t1.orbit, t1.events!!))
        // Opened again later in the same process: no second pulse.
        val again = m.start(orbit(complete), 50.0, book)
        assertEquals(2.5, again.completedAt!!, 1e-12)
        assertNull(m.pulse(again, 51.05 + 0.2, false))
    }

    @Test fun `a run already complete pulses at the end of the sweep the first time it is opened`() {
        val book = OneShotBook()
        val track = m.start(orbit(complete), 10.0, book)
        assertEquals(10.0 + m.sweepEnd, track.completedAt!!, 1e-12)
        assertNotNull(m.pulse(track, 11.5, false))
        assertNull("the first snapshot is never announced", track.events)
    }

    // MARK: cost and Reduce Motion

    @Test fun `only a running run loops, and a finished one stops its clock once it settles`() {
        val book = OneShotBook()
        assertTrue(m.animating(m.start(orbit(board), 0.0, book), 100.0, false))
        val t1 = m.observe(m.start(orbit(lastOne), 0.0, book), orbit(complete), 2.0, book)
        assertTrue("the pulse is still out at 3.5 s", m.animating(t1, 3.5, false))
        assertEquals("settled when the pulse ends", 3.6, m.settlesAt(t1, false), 1e-9)
        assertFalse(m.animating(t1, 3.61, false))
        val done = m.start(orbit(complete), 0.0, OneShotBook())
        assertEquals("an already-complete run settles after its pulse", m.sweepEnd + m.pulseDuration, m.settlesAt(done, false), 1e-9)
    }

    @Test fun `Reduce Motion draws the final state with a short fade and nothing that loops`() {
        val book = OneShotBook()
        val track = m.start(orbit(board), 0.0, book)
        assertNear("the arc at once", 4.0 / 7, m.arc(track, 0.0, true))
        assertEquals(4, m.count(track, 0.0, true).value)
        val n = m.nodes(track, 0.1, true)
        assertTrue("all fading in together, full size", n.all { abs(it.opacity - 0.875) < 1e-9 && it.scale == 1.0 })
        assertTrue("no breath, no ripples", m.nodes(track, 2.0, true).all { it.breath == 0.0 && it.ripple == null })
        assertFalse("still after 0.2 s, even running", m.animating(track, 0.21, true))
        val t1 = m.observe(m.start(orbit(lastOne), 0.0, book), orbit(complete), 2.0, book)
        assertNull("no pulse", m.pulse(t1, 2.75, true))
        val a1 = m.nodes(t1, 2.1, true).first { it.node.id == "a1" }
        assertNear("a 0.2 s cross-fade", 0.875, a1.mix)
        assertTrue("no fill or ring", a1.fill == null && a1.burst == null)
        assertNear("the arc at once", 1.0, m.arc(t1, 2.0, true))
    }

    @Test fun `a meta-only change keeps the marks and clocks`() {
        val book = OneShotBook()
        val t1 = m.observe(m.start(orbit(board), 0.0, book), orbit(finished), 2.0, book)
        val later = m.observe(t1, WorkflowOrbit.build(finished, nwNow.plusSeconds(5)).copy(meta = "phase Verify · 2m 15s"), 2.1, book)
        assertEquals(t1.marks, later.marks)
        assertEquals(t1.arcAt, later.arcAt)
        assertEquals(t1.events, later.events)
    }

    // MARK: the agent screen

    @Test fun `what an agent screen shows as it opens rises staggered, and what arrives later rises as it comes`() {
        val a = WorkflowMotion.Arrivals()
        val opened = a.observe(listOf("task", "s1", "a1"), 0.0)
        assertNear("the first from 0.2 s, like the rows", 0.2, opened.getValue("task"))
        assertNear("each 0.04 s after the one before", 0.28, opened.getValue("a1"))
        val later = a.observe(listOf("task", "s1", "a1", "s2", "s3"), 3.0)
        assertTrue("later ones rise at once, together", later.getValue("s2") == 3.0 && later.getValue("s3") == 3.0)
        val loaded = WorkflowMotion.Arrivals()
        assertTrue("opened while loading", loaded.observe(emptyList(), 0.0).isEmpty())
        val at = loaded.observe((1..10).map { "b$it" }, 1.0)
        assertNear("staggered like the rows", 1.04, at.getValue("b2"))
        assertNear("only the first eight", 1.28, at.getValue("b10"))
    }
}
