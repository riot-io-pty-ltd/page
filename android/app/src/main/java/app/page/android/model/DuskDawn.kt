package app.page.android.model

import java.time.Instant
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin

/**
 * Port of iOS/Page/Models/DuskDawn.swift. DUSK AND DAWN: power, the original promise.
 *
 * When Page pauses agents at the battery cutoff the aurora fades to dusk, every working star exhales and dims
 * together, and a grey horizon band holds across the sky. When power returns a dawn sweep rises from the horizon
 * and relights each star one by one, each only once that session's own resume is confirmed (it is seen working
 * again): the sweep may be early, a star never is. The same sunrise, scaled to how much finished, opens the
 * Return Brief after an absence.
 *
 * Pure frames over elapsed seconds, so the harness can pin any moment.
 */
object DawnModel {
    /** The aurora fades to dusk over this long. */
    const val duskDuration: Double = 1.6

    /** The working stars exhale and dim together over this long... */
    const val exhale: Double = 1.2

    /** ...to this brightness. */
    const val dimTo = 0.3

    /** The dawn sweep takes this long to rise from the horizon to the top. */
    const val sweepDuration: Double = 1.8

    /** Stars confirmed together still relight one by one, this far apart. */
    const val stagger: Double = 0.16

    /** A star takes this long to come back up (with a small flare). */
    const val relight: Double = 0.5

    /** Once every confirmed star is lit, the gold settles back into the working aurora. */
    const val settle: Double = 1.2

    /** Past this long a dawn is over whatever is still unconfirmed (it shows as it is). */
    const val dawnLimit: Double = 90.0

    data class Dusk(
        /** 0 the working palette .. 1 the dusk palette. */
        val aurora: Double,
        /** Star brightness multiplier: 1 .. [dimTo]. */
        val stars: Double,
        /** The exhale: the stars shrink a touch as they breathe out (1 .. 0.9). */
        val starScale: Double,
        /** The grey horizon band: 0 .. 1, then holds. */
        val band: Double,
    )

    /** Dusk, [t] seconds after the pause began. Pure. */
    fun dusk(t: Double): Dusk {
        val a = MotionCurve.smooth(t / duskDuration)
        val x = MotionCurve.clamp01(t / exhale)
        // One breath out: a slight swell first, then down together.
        val swell = if (x < 0.2) MotionCurve.smooth(x / 0.2) * 0.12 else 0.12 * (1 - MotionCurve.smooth((x - 0.2) / 0.3))
        val dim = MotionCurve.smooth(MotionCurve.progress(t, exhale * 0.2, exhale))
        val stars = (1 + swell) * (1 - (1 - dimTo) * dim)
        val band = MotionCurve.smooth(MotionCurve.progress(t, 0.5, duskDuration))
        return Dusk(a, stars, 1 + swell * 0.5 - 0.1 * dim, band)
    }

    /** Height of the dawn's light front: 0 at the horizon .. 1 at the top. Pure. */
    fun sweep(t: Double): Double = MotionCurve.easeOut(t / sweepDuration)

    /** When the sweep passes a star [y] down the sky (0 top .. 1 bottom). Pure. */
    fun sweepReaches(y: Double): Double {
        val h = MotionCurve.clamp01(1 - y)
        // Inverse of the ease-out: 1 - (1 - x)^3 = h.
        return sweepDuration * (1 - (1 - h).pow(1.0 / 3.0))
    }

    data class StarInput(
        val id: String,
        /** 0 top .. 1 bottom of the sky. */
        val y: Double,
        /** Seconds after dawn began that its resume was confirmed; null while unconfirmed. */
        val confirmedAt: Double?,
    )

    /**
     * When each star relights, in seconds after dawn began: its own confirmation, not before the sweep reaches
     * it, and at least [stagger] after the star before it (one by one). Unconfirmed stars are absent: they stay
     * dim. Ties go to the earlier confirmation, then the lower star (the sweep comes from below), then the id. Pure.
     */
    fun relightTimes(stars: List<StarInput>): Map<String, Double> {
        val ready = stars.mapNotNull { s ->
            val c = s.confirmedAt ?: return@mapNotNull null
            Pair(s, maxOf(c, sweepReaches(s.y)))
        }.sortedWith { a, b ->
            if (a.second != b.second) return@sortedWith a.second.compareTo(b.second)
            if (a.first.confirmedAt != b.first.confirmedAt) return@sortedWith (a.first.confirmedAt ?: 0.0).compareTo(b.first.confirmedAt ?: 0.0)
            if (a.first.y != b.first.y) return@sortedWith b.first.y.compareTo(a.first.y)
            a.first.id.compareTo(b.first.id)
        }
        val out = LinkedHashMap<String, Double>()
        var last = Double.NEGATIVE_INFINITY
        for ((s, earliest) in ready) {
            val at = maxOf(earliest, last + stagger)
            out[s.id] = at
            last = at
        }
        return out
    }

    /** A star's brightness multiplier during dawn: [dimTo] until it relights, then up to 1 over [relight] with a 15% flare at two thirds. Pure. */
    fun starBrightness(t: Double, relightAt: Double?): Double {
        if (relightAt == null || !(t > relightAt)) return dimTo
        val x = MotionCurve.clamp01((t - relightAt) / relight)
        val rise = dimTo + (1 - dimTo) * MotionCurve.easeOut(x / 0.66)
        val flare = if (x < 0.66) 0.0 else 0.15 * sin((x - 0.66) / 0.34 * PI)
        return min(1.15, rise + flare)
    }

    data class Dawn(
        /** The light front: 0 horizon .. 1 top. */
        val sweep: Double,
        /** The gold of the sunrise: rises with the sweep, holds while stars relight, then settles away. 0 .. 1. */
        val warmth: Double,
        /** The grey band fades as the sweep leaves it: 1 .. 0. */
        val band: Double,
        /** 1 the dusk palette .. 0 the working palette. */
        val aurora: Double,
        val finished: Boolean,
    )

    /**
     * Dawn, [t] seconds after power came back. [lastRelight] is the latest relight time (null when no star has
     * been confirmed: the gold settles after the sweep alone). Pure.
     */
    fun dawn(t: Double, lastRelight: Double?): Dawn {
        val s = sweep(t)
        val lit = maxOf(sweepDuration, (lastRelight ?: 0.0) + relight)
        val rise = MotionCurve.smooth(t / (sweepDuration * 0.6))
        val fade = MotionCurve.smooth(MotionCurve.progress(t, lit, lit + settle))
        val band = 1 - MotionCurve.smooth(MotionCurve.progress(t, 0.0, sweepDuration * 0.5))
        val aurora = 1 - MotionCurve.smooth(MotionCurve.progress(t, sweepDuration * 0.3, lit + settle))
        return Dawn(s, rise * (1 - fade), band, aurora, t >= lit + settle)
    }

    data class BriefSunrise(val sweep: Double, val strength: Double)

    /** The Return Brief's sunrise: the same sweep, as bright as the absence was productive ([share] 0..1 finished). Pure. */
    fun briefSunrise(t: Double, share: Double): BriefSunrise = BriefSunrise(sweep(t), 0.25 + 0.75 * MotionCurve.clamp01(share))
}

/**
 * What the phone saw of the last battery pause, for the dusk and dawn: when it began, which sessions it stopped,
 * when power came back and when each of those sessions was seen working again. Fed from the live session list;
 * pure (a value you mutate), so the tests drive it with plain sets.
 */
class DuskDawnLog {
    /** When the pause began; [DISTANT_PAST] when Page opened onto a pause already in progress (drawn settled, not replayed). */
    var duskAt: Instant? = null
        private set

    /** When the pause ended: the dawn. null while paused or once the dawn is over. */
    var dawnAt: Instant? = null
        private set

    /** Sessions that were working when the pause began. */
    var affected: Set<String> = emptySet()
        private set

    /** When each affected session was first seen working after the dawn. */
    var resumedAt: Map<String, Instant> = emptyMap()
        private set
    private var wasPaused: Boolean? = null
    private var lastWorking: Set<String> = emptySet()

    val isPaused: Boolean get() = wasPaused == true

    /** Everything the dusk and dawn are drawn from: equal keys draw the same sky. */
    data class Key(val duskAt: Instant?, val dawnAt: Instant?, val affected: Set<String>, val resumedAt: Map<String, Instant>, val paused: Boolean?)

    val key: Key get() = Key(duskAt, dawnAt, affected, resumedAt, wasPaused)

    /** An independent copy, for handing a stable value to a view while the original keeps observing. */
    fun copy(): DuskDawnLog {
        val c = DuskDawnLog()
        c.duskAt = duskAt
        c.dawnAt = dawnAt
        c.affected = affected
        c.resumedAt = resumedAt
        c.wasPaused = wasPaused
        c.lastWorking = lastWorking
        return c
    }

    /** Records one look at the fleet. [working] is the ids of the sessions working now. */
    fun observe(paused: Boolean, working: Set<String>, now: Instant) {
        try {
            val was = wasPaused
            if (was == null) {
                // First look: a pause already under way is drawn as it is.
                if (paused) { duskAt = DISTANT_PAST; affected = working }
                return
            }
            if (paused && !was) {
                duskAt = now
                dawnAt = null
                resumedAt = emptyMap()
                // What was working the moment before (the Mac may already have stopped them).
                affected = lastWorking + working
            } else if (paused) {
                affected = affected + working
            } else if (was) {
                dawnAt = now
                duskAt = null
            }
            val dawn = dawnAt
            if (!paused && dawn != null) {
                val next = LinkedHashMap(resumedAt)
                for (id in working.intersect(affected)) if (id !in next) next[id] = now
                resumedAt = next
                val allBack = affected.isNotEmpty() && resumedAt.size == affected.size
                val since = now.secondsSince(dawn)
                if (since > DawnModel.dawnLimit || (allBack && since > DawnModel.sweepDuration + DawnModel.settle + 2)) dawnAt = null
            }
        } finally {
            wasPaused = paused
            if (!paused) lastWorking = working
        }
    }

    /** The dawn's star inputs: each affected star's confirmation, in seconds after the dawn. [ys] gives each star's height in the sky. Pure. */
    fun dawnStars(ys: Map<String, Double>): List<DawnModel.StarInput> {
        val dawn = dawnAt ?: return emptyList()
        return affected.sorted().map { id ->
            DawnModel.StarInput(id, ys[id] ?: 0.5, resumedAt[id]?.let { maxOf(0.0, it.secondsSince(dawn)) })
        }
    }

    companion object {
        /** Swift's `Date.distantPast` (0001-01-01), safe for `toEpochMilli`. */
        val DISTANT_PAST: Instant = Instant.ofEpochSecond(-62135769600L)
    }
}
