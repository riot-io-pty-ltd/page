package app.page.android.model

import java.time.Instant
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Port of iOS/Page/Models/PulseModel.swift. THE PULSE: one glyph on every surface (the Horizon, the nav bar's
 * button, Sky's stars, the widgets). Still star-white when all is quiet; a teal breath every 4 s while agents
 * work (a little faster with more of them); an amber ripple when something needs you, one ring per waiting
 * item, the rate rising with the longest wait and capped at one ring every 1.5 s; a low dusk glow while paused
 * for battery. When the last item clears, the pulse turns from amber to teal over 800 ms with one long exhale.
 *
 * Pure timing: the views ask it for a frame at a time in seconds, so the render harness can pin any moment and
 * the tests can check the board's. Every number is the Mac's and the iPhone's too, so the pulse keeps one
 * rhythm on every surface.
 */
class PulseModel(working: Int, waiting: Int, longestWait: Double = 0.0, paused: Boolean = false) {
    enum class Mode {
        /** Nothing running, nothing waiting: still, star-white. */
        QUIET,

        /** Agents working: the teal breath. */
        WORKING,

        /** Something needs you: the amber ripple. */
        WAITING,

        /** Paused at the battery cutoff: a low, still glow. */
        DUSK,
    }

    val working: Int = max(0, working)
    val waiting: Int = max(0, waiting)

    /** Seconds the oldest waiting item has waited. */
    val longestWait: Double = max(0.0, longestWait)

    /** Battery pause wins; then anything waiting; then anything working. */
    val mode: Mode = if (paused) Mode.DUSK else if (waiting > 0) Mode.WAITING else if (working > 0) Mode.WORKING else Mode.QUIET

    /** True while the pulse moves at all. Quiet and dusk are still, so they run no clock and cost nothing. */
    val isAnimated: Boolean get() = mode == Mode.WORKING || mode == Mode.WAITING

    /** The frame rate the pulse needs: a slow breath reads smoothly at 20, a ripple at 30. 0 when still. */
    val framesPerSecond: Double
        get() = when (mode) {
            Mode.WORKING -> 20.0
            Mode.WAITING -> 30.0
            Mode.QUIET, Mode.DUSK -> 0.0
        }

    /** Seconds per teal breath: 4 s with one agent, 0.15 s quicker for each further agent, never quicker than 3 s. */
    val breathPeriod: Double get() = max(fastestBreath, baseBreath - breathStep * max(0, working - 1).toDouble())

    /** Seconds between amber rings for one waiting item: 3 s for a fresh wait, falling linearly to the 1.5 s cap at ten minutes. */
    val rippleInterval: Double
        get() {
            val k = MotionCurve.clamp01(longestWait / rippleRamp)
            return slowestRipple - (slowestRipple - fastestRipple) * k
        }

    /** Rings on screen at once: one per waiting item, at most [maxRings]. */
    val ringCount: Int get() = if (mode == Mode.WAITING) min(waiting, maxRings) else 0

    /**
     * How long one ring takes to open fully. With [ringCount] rings evenly spaced through it a new one leaves
     * every `lifetime / count` seconds, never quicker than one every 1.5 s: more waiting items ripple faster, up
     * to the cap (board 07, "3 waiting · faster, capped").
     */
    val ringLifetime: Double get() = max(fastestRipple * max(1, ringCount).toDouble(), rippleInterval)

    /** Seconds between two rings leaving the core. */
    val emissionInterval: Double get() = ringLifetime / max(1, ringCount).toDouble()

    /** The breath at [t] seconds: 0 (in) .. 1 (out), a sine. 0.5 when not working. */
    fun breath(t: Double): Double {
        if (mode != Mode.WORKING) return 0.5
        return 0.5 + 0.5 * sin(t * 2 * PI / breathPeriod - PI / 2)
    }

    /** One amber ring. */
    data class Ripple(
        /** 0 (just left the core ring) .. 1 (fully open). */
        val progress: Double,
        /** Fades in over the first tenth (so it never pops), then out as it opens. */
        val opacity: Double,
    )

    /** The rings in flight at [t], the newest first. Empty unless waiting. Pure. */
    fun ripples(t: Double): List<Ripple> {
        val n = ringCount
        if (n <= 0) return emptyList()
        val phase = (max(0.0, t) / emissionInterval).rem(1.0)
        return (0 until n).map { j ->
            val p = (phase + j) / n
            Ripple(p, ringOpacity(p))
        }
    }

    /** Reduce Motion: a static ring with a count. The number of waiting items (null when nothing waits). */
    val staticCount: Int? get() = if (mode == Mode.WAITING) waiting else null

    /** A frame of the exhale, `elapsed` seconds after the last item cleared. */
    data class Exhale(
        /** 0 = amber .. 1 = the new colour (teal, or star-white when quiet). */
        val colour: Double,
        /** 0 .. 1 .. 0: the glow swells once and settles. */
        val swell: Double,
        /** The aurora settles from amber to the new palette with it: 0..1. */
        val aurora: Double,
        val finished: Boolean,
    )

    companion object {
        /** The breath with one agent working. */
        const val baseBreath: Double = 4.0

        /** The quickest the breath gets, however many agents work ("slightly faster"). */
        const val fastestBreath: Double = 3.0

        /** Each agent past the first takes this much off the breath. */
        const val breathStep: Double = 0.15

        /** One ring every 3 s for one item that has just started waiting... */
        const val slowestRipple: Double = 3.0

        /** ...rising to the cap of one ring every 1.5 s... */
        const val fastestRipple: Double = 1.5

        /** ...once the longest wait reaches ten minutes. */
        const val rippleRamp: Double = 600.0

        /** More rings than this read as noise, not a count. */
        const val maxRings = 4

        /** The colour turns from amber to teal over this long when the last item clears. */
        const val exhaleColour: Double = 0.8

        /** The one long exhale (the glow swells, then settles) lasts this long. */
        const val exhaleDuration: Double = 1.6

        /** The longest wait among the rows' `waitingSince`, at [now]. Pure. */
        fun longestWait(since: List<Instant>, now: Instant): Double = since.maxOfOrNull { max(0.0, now.secondsSince(it)) } ?: 0.0

        /** A ring's opacity at [progress], the Mac's curve. Pure. */
        fun ringOpacity(progress: Double): Double {
            val p = MotionCurve.clamp01(progress)
            return MotionCurve.smooth(p / 0.1) * (1 - p).pow(1.5)
        }

        /** The last waiting item just cleared (amber to anything but amber, and not into the battery pause, which has its own dusk). Pure. */
        fun exhales(old: Mode, new: Mode): Boolean = old == Mode.WAITING && (new == Mode.WORKING || new == Mode.QUIET)

        /**
         * The exhale at [elapsed] seconds: colour over 800 ms (smoothstep), one swell peaking at 35% of 1.6 s, the
         * aurora following over the whole 1.6 s. Pure.
         */
        fun exhale(elapsed: Double): Exhale {
            val c = MotionCurve.smooth(elapsed / exhaleColour)
            val x = MotionCurve.clamp01(elapsed / exhaleDuration)
            // A quick breath out, then a long settle.
            val swell = if (x < 0.35) MotionCurve.smooth(x / 0.35) else 1 - MotionCurve.smooth((x - 0.35) / 0.65)
            return Exhale(c, if (elapsed <= 0) 0.0 else swell, MotionCurve.smooth(x), elapsed >= exhaleDuration)
        }
    }
}
