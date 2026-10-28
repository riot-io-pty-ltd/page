package app.page.android.model

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * The Workflows lens in motion (board 13, and the spec's "Workflow nodes fill teal one by one, and the ring closes with
 * one soft pulse when every agent is done"), as plain maths of time, so any frame can be computed, tested and pinned by
 * the render harness. iOS has the same numbers (WorkflowMotion.swift), and WorkflowMotionTest's table is shared.
 *
 * Two clocks: `t` is seconds since the lens (or the picked run) appeared, for the entrance; `now` is the clock the live
 * loops and the one-shots run on (nwClockSeconds in the app, the pinned time in the harness). Constants marked
 * "Chosen" are the ones the spec leaves open.
 */
object WorkflowMotion {
    // MARK: - The entrance

    /** The orbit track and the progress track fade in over this, easeOut. */
    const val trackFade = 0.35
    const val nodeFirst = 0.08
    const val nodeStaggerMax = 0.06
    /** The stagger shrinks so the last node never starts later than this after the first. */
    const val nodeStaggerSpan = 0.6
    const val nodeDuration = 0.42
    const val nodeFromScale = 0.4
    /** easeOutBack's overshoot. */
    const val overshoot = 1.2
    /** A node's opacity is a smoothstep over this share of its pop. */
    const val nodeFadeShare = 0.6
    const val sweepStart = 0.15
    const val sweepDuration = 0.9
    const val sweepEnd = sweepStart + sweepDuration
    const val rowFirst = 0.2
    const val rowStagger = 0.04
    /** Chosen curve: a row's rise and fade are both easeOut over this. */
    const val rowDuration = 0.25
    /** dp (pt on iOS) a row rises as it fades in. */
    const val rowRise = 8.0
    /** Only the first rows stagger; the rest appear with the last of these. */
    const val rowsStaggered = 8

    // MARK: - Live (a running run only)

    /** Chosen waveform: 0.5 − 0.5·cos, so a breath starts at rest; each node lags the one before (a wave that travels clockwise, like the comet). */
    const val breathPeriod = 1.8
    const val breathScale = 0.12
    const val haloFrom = 0.25
    const val haloTo = 0.5
    /** Radians each node's breath and ripple lag the one before it. */
    const val phaseStep = 0.37
    const val ripplePeriod = 2.4
    const val rippleFrom = 10.0
    const val rippleTo = 26.0
    const val rippleOpacity = 0.35
    const val cometPeriod = 8.0
    /** Degrees of the comet's tail behind its head. */
    const val cometSpan = 40.0
    const val cometOpacity = 0.35

    // MARK: - State changes

    /** Chosen curve: easeOut. The done disc fills over the same time, on the same curve. */
    const val crossFade = 0.35
    const val burstDuration = 0.7
    const val burstFrom = 8.0
    const val burstTo = 34.0
    const val burstOpacity = 0.5
    const val springResponse = 0.6
    const val springDamping = 0.85
    /** Chosen: the arc's spring (and a node's glide, on the same spring) is drawn settled, exactly on its target, after this. */
    const val arcSettle = 1.0
    /** Chosen: the centre number's roll, easeOut. */
    const val rollDuration = 0.35

    // MARK: - Completion

    /** Chosen: the pulse starts this long after the run completes, once the arc's spring has closed the ring (to within 0.4 %). */
    const val pulseDelay = 0.5
    const val pulseDuration = 1.1
    const val pulseGrow = 0.35
    const val pulseOpacity = 0.55
    /** Chosen shape: 1 + 0.06·sin(π·x). */
    const val textBumpDuration = 0.5
    const val textBump = 0.06

    /** Reduce Motion: the entrance and every state change are a cross-fade this long, easeOut. */
    const val reducedFade = 0.2

    // MARK: - Curves

    /** Ease out past 1 and back ([s] 1.2 overshoots by about 7 %): 1 + (s+1)(x−1)³ + s(x−1)². Pure. */
    fun easeOutBack(x: Double, s: Double = overshoot): Double {
        val u = MotionCurve.clamp01(x) - 1
        return 1 + (s + 1) * u * u * u + s * u * u
    }

    /** Cubic ease in and out. Pure. */
    fun easeInOutCubic(x: Double): Double {
        val t = MotionCurve.clamp01(x)
        if (t < 0.5) return 4 * t * t * t
        val u = -2 * t + 2
        return 1 - u * u * u / 2
    }

    private fun frac(x: Double): Double = x - floor(x)

    // MARK: - The entrance, [t] seconds after the lens appeared

    fun trackOpacity(t: Double): Double = MotionCurve.easeOut(t / trackFade)

    fun nodeStagger(n: Int): Double = min(nodeStaggerMax, nodeStaggerSpan / max(1, n))

    /** Node [i] of [n] pops in at this, clockwise from 12 o'clock in slot order. */
    fun nodeStart(i: Int, n: Int): Double = nodeFirst + i * nodeStagger(n)

    data class Pop(val scale: Double, val opacity: Double)

    /** A node popping in, [local] seconds after it starts: scale 0.4 → 1 with easeOutBack, opacity a smoothstep over the first 60 %. Pure. */
    fun pop(local: Double): Pop {
        val x = MotionCurve.clamp01(local / nodeDuration)
        return Pop(nodeFromScale + (1 - nodeFromScale) * easeOutBack(x), MotionCurve.smooth(x / nodeFadeShare))
    }

    fun nodeEntrance(t: Double, i: Int, n: Int): Pop = pop(t - nodeStart(i, n))

    /** How far the progress arc has swept towards done/total: 0.15 s in, over 0.9 s, easeInOutCubic. Pure. */
    fun sweep(t: Double): Double = easeInOutCubic((t - sweepStart) / sweepDuration)

    /** The centre number while the arc sweeps: "0/7" up to "4/7" in step with it, rounded half up as Swift's rounded() does. Pure. */
    fun shownDone(done: Int, t: Double): Int = floor(done * sweep(t) + 0.5).toInt()

    fun rowStart(i: Int): Double = rowFirst + min(max(0, i), rowsStaggered - 1) * rowStagger

    data class Rise(val offset: Double, val opacity: Double)

    /** A row rising in, [local] seconds after it starts: 8 → 0 dp and opacity 0 → 1. Pure. */
    fun rise(local: Double): Rise {
        val e = MotionCurve.easeOut(local / rowDuration)
        return Rise(rowRise * (1 - e), e)
    }

    /** Agent row [i] (down the list) at [t]. Reduce Motion: no rise, a 0.2 s fade. Pure. */
    fun row(t: Double, i: Int, reduce: Boolean = false): Rise = if (reduce) Rise(0.0, MotionCurve.easeOut(t / reducedFade)) else rise(t - rowStart(i))

    /** When the last of the entrance has landed, for [n] nodes. */
    fun entranceDuration(n: Int): Double =
        max(sweepEnd, max(nodeStart(max(0, n - 1), n) + nodeDuration, rowStart(rowsStaggered - 1) + rowDuration))

    // MARK: - Live, on [now]

    /** 0 (rest) up to 1 and back over 1.8 s, node [index] lagging index·0.37 rad. Pure. */
    fun breath(now: Double, index: Int = 0): Double = 0.5 - 0.5 * cos(2 * PI * now / breathPeriod - index * phaseStep)

    data class Ring(val radius: Double, val opacity: Double)

    /** A running node's ripple: one every 2.4 s, 10 → 26 dp as its opacity goes 0.35 → 0, easeOut, staggered by the node's phase. Pure. */
    fun ripple(now: Double, index: Int): Ring {
        val e = MotionCurve.easeOut(frac(now / ripplePeriod - index * phaseStep / (2 * PI)))
        return Ring(rippleFrom + (rippleTo - rippleFrom) * e, rippleOpacity * (1 - e))
    }

    /** Where the comet's head is, in radians clockwise from 12 o'clock: once round every 8 s. Pure. */
    fun cometAngle(now: Double): Double = 2 * PI * frac(now / cometPeriod)

    // MARK: - What changed

    data class Events(
        val finished: List<String>,
        val failed: List<String>,
        val stopped: List<String>,
        /** Agents that were not in the old snapshot. */
        val added: List<String>,
        /** The run has just completed: every agent done, failed or stopped, and the run no longer running. */
        val completed: Boolean,
    ) {
        val isEmpty: Boolean get() = finished.isEmpty() && failed.isEmpty() && stopped.isEmpty() && added.isEmpty() && !completed

        companion object {
            val none = Events(emptyList(), emptyList(), emptyList(), emptyList(), false)
        }
    }

    /**
     * Every agent has finished (done, failed or stopped) and the run has ended. With every agent listed this is
     * done + failed + stopped == total (the Mac counts `done` as the finished agents, and an ended run has none running);
     * asked as "none running", it also holds for a run of more than the 100 agents the Mac lists (running ones first), as
     * on iOS. A stalled run has not ended (its unfinished agents read as stopped, but it may go on). Pure.
     */
    fun isComplete(o: WorkflowOrbit): Boolean = !o.isRunning && o.status != "stalled" && o.total > 0 && o.running == 0

    /** What changed between two snapshots of one run, by agent id: who finished, failed or stopped (each was running), who is new, and whether the run has just completed. Pure. */
    fun events(old: WorkflowOrbit, new: WorkflowOrbit): Events {
        val before = old.nodes.associate { it.id to it.state }
        fun turned(to: WorkflowOrbit.NodeState) = new.nodes.filter { before[it.id] == WorkflowOrbit.NodeState.RUNNING && it.state == to }.map { it.id }
        return Events(
            turned(WorkflowOrbit.NodeState.DONE), turned(WorkflowOrbit.NodeState.FAILED), turned(WorkflowOrbit.NodeState.STOPPED),
            new.nodes.filter { it.id !in before }.map { it.id }, !isComplete(old) && isComplete(new),
        )
    }

    /** The orbit in one sentence, for TalkBack: "4 of 7 agents done, 2 running, 1 failed". Pure. */
    fun summary(o: WorkflowOrbit): String {
        val parts = mutableListOf("${o.done} of ${o.total} agent${if (o.total == 1) "" else "s"} done")
        if (o.running > 0) parts.add("${o.running} running")
        if (o.failed > 0) parts.add("${o.failed} failed")
        if (o.stopped > 0) parts.add("${o.stopped} didn't finish")
        return parts.joinToString(", ")
    }

    /**
     * The one polite announcement a change earns while the lens is open, as iOS words it: "review-changes: all 7 agents
     * done" when the run completes, else "verify: iOS logic tests finished" (or "2 agents finished"), else the same for a
     * failure. Null when there is nothing worth saying. Pure.
     */
    fun announcement(new: WorkflowOrbit, events: Events): String? {
        fun label(id: String) = new.nodes.firstOrNull { it.id == id }?.label ?: "An agent"
        if (events.completed) {
            val didnt = new.failed + new.stopped
            return if (didnt == 0) "${new.name}: all ${new.total} agents done" else "${new.name}: finished, ${new.done} of ${new.total} agents done, $didnt didn't"
        }
        return when {
            events.finished.size == 1 -> "${label(events.finished[0])} finished"
            events.finished.size > 1 -> "${events.finished.size} agents finished"
            events.failed.size == 1 -> "${label(events.failed[0])} failed"
            events.failed.size > 1 -> "${events.failed.size} agents failed"
            else -> null
        }
    }

    // MARK: - One change, one pulse

    enum class Change { FINISHED, FAILED, STOPPED, ADDED, TURNED }

    /** A node [e] seconds after it changed: how far its colour has crossed, the done disc filling (finished only, then null), and the one ring it sends (finished or failed). */
    data class Turn(val mix: Double, val fill: Double?, val burst: Ring?)

    /** A node [e] seconds after a [change]. Reduce Motion: a 0.2 s cross-fade only. Pure. */
    fun change(e: Double, change: Change, reduce: Boolean = false): Turn {
        if (reduce) return Turn(MotionCurve.easeOut(e / reducedFade), null, null)
        val mix = MotionCurve.easeOut(e / crossFade)
        val fill = if (change == Change.FINISHED && e < crossFade) nodeFromScale + (1 - nodeFromScale) * mix else null
        val burst = if ((change == Change.FINISHED || change == Change.FAILED) && e >= 0 && e < burstDuration) {
            val q = MotionCurve.easeOut(e / burstDuration)
            Ring(burstFrom + (burstTo - burstFrom) * q, burstOpacity * (1 - q))
        } else null
        return Turn(mix, fill, burst)
    }

    data class Glow(val scale: Double, val opacity: Double)

    /** The completion glow [e] seconds in: the progress ring's radius × 1 → 1.35 as its opacity goes 0.55 → 0, easeOut over 1.1 s; null before and after. Pure. */
    fun pulse(e: Double): Glow? {
        if (e < 0 || e >= pulseDuration) return null
        val k = MotionCurve.easeOut(e / pulseDuration)
        return Glow(1 + pulseGrow * k, pulseOpacity * (1 - k))
    }

    /** The centre text's one swell with the glow: 1 → 1.06 → 1 over 0.5 s. Pure. */
    fun bump(e: Double): Double = if (e > 0 && e < textBumpDuration) 1 + textBump * sin(PI * e / textBumpDuration) else 1.0

    // MARK: - The track: what the lens has seen of one run

    /** The latest change to one agent while the lens was open: what happened, the state it turned from, and when. */
    data class Mark(val change: Change, val from: WorkflowOrbit.NodeState, val at: Double)

    /**
     * What the lens has seen of one run since it appeared. The slots are fixed while it is open (the first snapshot's
     * order, newcomers after), so an agent that finishes fills in place instead of the ring re-sorting under it.
     */
    data class Track(
        val openedAt: Double,
        val orbit: WorkflowOrbit,
        /** Agent ids, clockwise from 12 o'clock. */
        val slots: List<String>,
        val marks: Map<String, Mark> = emptyMap(),
        /** Where each node was drawn when the ring last re-spaced (radians), and when. */
        val angles: Map<String, Double> = emptyMap(),
        val spacedAt: Double? = null,
        /** The arc springs from [arcFrom] to the run's fraction from [arcAt]; null while it is still the entrance's sweep. */
        val arcFrom: Double = 0.0,
        val arcAt: Double? = null,
        val countFrom: Int = 0,
        val countAt: Double? = null,
        /** The run as it was before its status last changed, for the chip's cross-fade. */
        val statusFrom: WorkflowOrbit? = null,
        val statusAt: Double? = null,
        /** When the completion pulse starts (once per run per process), or null. */
        val completedAt: Double? = null,
        /** The last change seen, for the announcement; null for the first snapshot, which says nothing. */
        val events: Events? = null,
    )

    /** The first snapshot, as the lens appears at [now]. A run that is already complete pulses as the sweep closes its ring, the first time it is ever opened. */
    fun start(orbit: WorkflowOrbit, now: Double, book: OneShotBook): Track =
        Track(now, orbit, orbit.nodes.map { it.id }, completedAt = if (isComplete(orbit)) book.start(orbit.runId, now + sweepEnd) else null)

    private fun sameMotion(a: WorkflowOrbit, b: WorkflowOrbit): Boolean =
        a.nodes.map { Triple(it.id, it.label, it.state) } == b.nodes.map { Triple(it.id, it.label, it.state) } &&
            a.done == b.done && a.total == b.total && a.status == b.status && a.isRunning == b.isRunning &&
            a.running == b.running && a.failed == b.failed && a.stopped == b.stopped

    /** The run as it is at [now]. When nothing the lens animates has changed (only the meta line), the marks and clocks are kept. Pure but for [book]. */
    fun observe(track: Track, orbit: WorkflowOrbit, now: Double, book: OneShotBook): Track {
        val old = track.orbit
        if (old == orbit) return track
        if (sameMotion(old, orbit)) return track.copy(orbit = orbit)
        val ev = events(old, orbit)
        val ids = orbit.nodes.map { it.id }
        val kept = track.slots.filter { it in ids }
        val slots = kept + ids.filter { it !in kept }
        val respaced = slots != track.slots
        val before = old.nodes.associate { it.id to it.state }
        val marks = track.marks.filterKeys { it in ids }.toMutableMap()
        for (node in orbit.nodes) {
            val was = before[node.id]
            when {
                was == null -> marks[node.id] = Mark(Change.ADDED, node.state, now)
                was == node.state -> Unit
                was == WorkflowOrbit.NodeState.RUNNING && node.state == WorkflowOrbit.NodeState.DONE -> marks[node.id] = Mark(Change.FINISHED, was, now)
                was == WorkflowOrbit.NodeState.RUNNING && node.state == WorkflowOrbit.NodeState.FAILED -> marks[node.id] = Mark(Change.FAILED, was, now)
                was == WorkflowOrbit.NodeState.RUNNING && node.state == WorkflowOrbit.NodeState.STOPPED -> marks[node.id] = Mark(Change.STOPPED, was, now)
                else -> marks[node.id] = Mark(Change.TURNED, was, now)
            }
        }
        val arcMoves = fraction(orbit) != fraction(old)
        val arcAt = if (arcMoves) now else track.arcAt
        val statusTurns = orbit.status != old.status || orbit.isRunning != old.isRunning
        return Track(
            openedAt = track.openedAt, orbit = orbit, slots = slots, marks = marks,
            angles = if (respaced) track.slots.associateWith { angle(track, it, now) } else track.angles,
            spacedAt = if (respaced) now else track.spacedAt,
            arcFrom = if (arcMoves) arc(track, now, false) else track.arcFrom, arcAt = arcAt,
            countFrom = if (orbit.done != old.done) count(track, now, false).value else track.countFrom,
            countAt = if (orbit.done != old.done) now else track.countAt,
            statusFrom = if (statusTurns) old else track.statusFrom, statusAt = if (statusTurns) now else track.statusAt,
            // The pulse follows the arc closing, once per run.
            completedAt = if (ev.completed) book.start(orbit.runId, now + pulseDelay) else track.completedAt,
            events = ev,
        )
    }

    // MARK: - A frame of the track at [now]

    fun fraction(o: WorkflowOrbit): Double = if (o.total > 0) MotionCurve.clamp01(o.done.toDouble() / o.total) else 0.0

    /**
     * The progress arc's fraction: the entrance sweep, then a spring (0.6 s, 0.85) to each new fraction, exactly on it once
     * settled (so a settled frame is the same frame every time). Reduce Motion: the fraction, at once. Pure.
     */
    fun arc(track: Track, now: Double, reduce: Boolean): Double {
        val target = fraction(track.orbit)
        if (reduce) return target
        val at = track.arcAt ?: return target * sweep(now - track.openedAt)
        if (now - at >= arcSettle) return target
        return MotionCurve.clamp01(track.arcFrom + (target - track.arcFrom) * MotionCurve.spring(now - at, springResponse, springDamping))
    }

    /** The centre number: [value], with [previous] rolling up and out as [roll] goes 0 → 1 (null once it has gone). */
    data class Count(val value: Int, val previous: Int?, val roll: Double)

    /** The centre number: counting up with the sweep, then rolling to each new count (a plain cross-fade under Reduce Motion). Pure. */
    fun count(track: Track, now: Double, reduce: Boolean): Count {
        val done = track.orbit.done
        val at = track.countAt ?: return Count(if (reduce) done else shownDone(done, now - track.openedAt), null, 1.0)
        val x = (now - at) / (if (reduce) reducedFade else rollDuration)
        if (x >= 1) return Count(done, null, 1.0)
        return Count(done, track.countFrom, MotionCurve.easeOut(x))
    }

    fun slotAngle(slot: Int, n: Int): Double = slot.toDouble() / max(1, n) * 2 * PI

    /** Where an agent's node is drawn: its slot's angle, gliding there the shorter way on the arc's spring when the ring re-spaces for a newcomer. Pure. */
    fun angle(track: Track, id: String, now: Double, reduce: Boolean = false): Double {
        val i = track.slots.indexOf(id)
        if (i < 0) return 0.0
        val target = slotAngle(i, track.slots.size)
        val at = track.spacedAt ?: return target
        val from = track.angles[id] ?: return target
        if (reduce || now - at >= arcSettle) return target
        var d = target - from
        while (d > PI) d -= 2 * PI
        while (d < -PI) d += 2 * PI
        return from + d * MotionCurve.spring(now - at, springResponse, springDamping)
    }

    data class NodeFrame(
        val node: WorkflowOrbit.Node,
        val slot: Int,
        /** Radians clockwise from 12 o'clock, where it is drawn now. */
        val angle: Double,
        val scale: Double,
        val opacity: Double,
        /** The state it is turning from, and how far (1: settled on the node's own state). */
        val from: WorkflowOrbit.NodeState,
        val mix: Double,
        /** The done disc filling in (0.4 → 1) while an agent that has just finished fills; else null. */
        val fill: Double?,
        /** The one ring a finish or a failure sends out, while it is out. */
        val burst: Ring?,
        /** 0 .. 1 while running (0 under Reduce Motion). */
        val breath: Double,
        val ripple: Ring?,
    )

    /** Every node as drawn at [now], in slot order. Pure. */
    fun nodes(track: Track, now: Double, reduce: Boolean): List<NodeFrame> {
        val byId = track.orbit.nodes.associateBy { it.id }
        val n = track.slots.size
        val t = now - track.openedAt
        return track.slots.mapIndexedNotNull { i, id ->
            val node = byId[id] ?: return@mapIndexedNotNull null
            val mark = track.marks[id]
            val since = mark?.let { now - it.at } ?: 0.0
            val joined = mark?.change == Change.ADDED
            val pop = when {
                reduce -> Pop(1.0, MotionCurve.easeOut((if (joined) since else t) / reducedFade))
                joined -> pop(since)
                else -> nodeEntrance(t, i, n)
            }
            // A change: the colour crosses over, a finished disc fills, a finish or failure sends its ring; then plain.
            val turn = when {
                mark == null || joined || mark.from == node.state -> null
                since < 0 -> Turn(0.0, null, null) // a frame drawn on a clock reading from just before the change
                else -> change(since, mark.change, reduce)
            }
            val crossing = turn != null && turn.mix < 1
            val live = !reduce && node.state == WorkflowOrbit.NodeState.RUNNING
            NodeFrame(
                node, i, angle(track, id, now, reduce), pop.scale, pop.opacity, if (crossing) mark!!.from else node.state, if (crossing) turn!!.mix else 1.0,
                turn?.fill, turn?.burst?.let { Ring(it.radius, it.opacity * pop.opacity) },
                if (live) breath(now, i) else 0.0, if (live) ripple(now, i) else null,
            )
        }
    }

    data class Pulse(val ringScale: Double, val ringOpacity: Double, val textScale: Double)

    /** The ring closing: a glow grows from the progress ring to 1.35× as it fades (1.1 s, easeOut), and the centre text swells 1 → 1.06 → 1 (0.5 s). Null outside it and under Reduce Motion. Pure. */
    fun pulse(track: Track, now: Double, reduce: Boolean): Pulse? {
        val start = track.completedAt ?: return null
        if (reduce) return null
        val g = pulse(now - start) ?: return null
        return Pulse(g.scale, g.opacity, bump(now - start))
    }

    /** How far the status chip has turned from [Track.statusFrom] to the run's status: 0 .. 1 (1 with nothing to turn from). Pure. */
    fun statusMix(track: Track, now: Double, reduce: Boolean): Double {
        val at = track.statusAt ?: return 1.0
        return MotionCurve.easeOut((now - at) / if (reduce) reducedFade else crossFade)
    }

    /** When the last one-shot on the track lands. Pure. */
    fun settlesAt(track: Track, reduce: Boolean): Double {
        var end = track.openedAt + if (reduce) reducedFade else entranceDuration(track.slots.size)
        fun until(at: Double?, d: Double) { if (at != null) end = max(end, at + d) }
        for (m in track.marks.values) {
            until(m.at, if (reduce) reducedFade else when (m.change) { Change.ADDED -> nodeDuration; Change.FINISHED, Change.FAILED -> burstDuration; else -> crossFade })
        }
        until(track.arcAt, if (reduce) 0.0 else arcSettle)
        until(track.countAt, if (reduce) reducedFade else rollDuration)
        until(track.statusAt, if (reduce) reducedFade else crossFade)
        until(track.spacedAt, if (reduce) 0.0 else arcSettle)
        if (!reduce) until(track.completedAt, pulseDuration)
        return end
    }

    /**
     * True while anything on the lens moves at [now]: always while the run is running (the breath, ripples and comet),
     * else until the last one-shot lands, so a finished, settled run draws with no clock at all. Reduce Motion has no
     * loops. Pure.
     */
    fun animating(track: Track, now: Double, reduce: Boolean): Boolean = (!reduce && track.orbit.isRunning) || now < settlesAt(track, reduce)

    // MARK: - A workflow agent's screen

    /**
     * When each item of a workflow agent's transcript starts rising in, as the agent rows do (iOS: NWAgentRoomScreen).
     * What is there when the screen opens rises staggered from the opening, like the rows (the first eight); a transcript
     * that loads after an empty opening rises staggered from when it came; anything added later rises as it comes.
     * Seconds on the caller's clock.
     */
    class Arrivals {
        private var seen: Set<String>? = null
        private var at: Map<String, Double> = emptyMap()

        fun observe(ids: List<String>, now: Double): Map<String, Double> {
            val before = seen
            if (before == null) {
                seen = ids.toSet()
                at = ids.mapIndexed { k, id -> id to now + rowStart(k) }.toMap()
                return at
            }
            val fresh = ids.filter { it !in before && it !in at }
            if (fresh.isEmpty()) return at
            at = at + fresh.mapIndexed { k, id -> id to now + if (before.isEmpty()) rowStart(k) - rowFirst else 0.0 }
            seen = before + fresh
            return at
        }
    }
}
