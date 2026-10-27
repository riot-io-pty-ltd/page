package app.page.android.ui.nw.sky

import app.page.android.model.DawnModel
import app.page.android.model.DuskDawnLog
import app.page.android.model.SkyStar
import app.page.android.model.StarState
import app.page.android.model.secondsSince
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.pinned
import app.page.android.ui.nw.theme.starField
import java.time.Instant
import kotlin.math.max

/** What Sky's power story looks like at one moment. */
data class NWSkyLight(
    val palette: AuroraPalette,
    /** The grey band: 0..1. */
    val band: Double,
    /** The dawn's sweep and gold, while it plays. */
    val dawn: DawnModel.Dawn?,
    /** How much of the background star field shows (it fades with the dusk). */
    val stars: Double = 1.0,
)

/**
 * Sky's power story at any moment (iOS NWDuskDawn.swift's `SkyScreenData` extension): the working aurora; fading to
 * dusk with the band holding; or the gold dawn rising back into it, each paused star relighting only once its own
 * resume is confirmed. Pure, so the harness and the tests can draw any moment.
 *
 * `now` is the wall clock while the sky is live, and null when it is drawn still (Remove animations, a harness frame
 * with no motion pinned): then a pause is drawn settled and no dawn plays, every change a cut.
 */
class SkyPowerStory(private val paused: Boolean, private val log: DuskDawnLog, stars: List<SkyStar>) {
    /** When each paused star relights: its own confirmed resume, one by one (empty unless a dawn is under way). */
    val relights: Map<String, Double> = DawnModel.relightTimes(log.dawnStars(stars.associate { it.id to it.y }))

    private val lastRelight: Double? = relights.values.maxOrNull()

    /** Seconds into the dusk; a pause already under way when Page opened is drawn settled. null when not paused. */
    fun duskElapsed(now: Instant?, pin: NWMotionPin?): Double? {
        if (!paused) return null
        pin.pinned(NWMotionPin.Kind.DUSK)?.let { return it }
        val at = log.duskAt
        if (at == null || at == DuskDawnLog.DISTANT_PAST || now == null) return DawnModel.duskDuration
        return max(0.0, now.secondsSince(at))
    }

    /** Seconds into the dawn, while one plays. */
    fun dawnElapsed(now: Instant?, pin: NWMotionPin?): Double? {
        if (paused) return null
        pin.pinned(NWMotionPin.Kind.DAWN)?.let { return it }
        if (now == null) return null
        return log.dawnAt?.let { max(0.0, now.secondsSince(it)) }
    }

    /** True while the power story moves and so needs a clock: the dusk falling, or the dawn rising. A pause that has settled holds still. */
    fun isMoving(now: Instant, pin: NWMotionPin?): Boolean {
        if (pin?.kind == NWMotionPin.Kind.DUSK || pin?.kind == NWMotionPin.Kind.DAWN) return true
        if (paused) {
            val at = log.duskAt ?: return false
            return at != DuskDawnLog.DISTANT_PAST && now.secondsSince(at) < DawnModel.duskDuration
        }
        val dawn = log.dawnAt ?: return false
        return !DawnModel.dawn(now.secondsSince(dawn), lastRelight).finished
    }

    /**
     * When the power story stops moving and its clocks can stop: the end of the dusk, or of the dawn's settle (later
     * if a late relight holds it open). null when nothing moves (a settled pause, an old one, no dawn). Pure.
     */
    fun movingUntil(): Instant? {
        if (paused) {
            val at = log.duskAt ?: return null
            if (at == DuskDawnLog.DISTANT_PAST) return null
            return at.plusMillis((DawnModel.duskDuration * 1000).toLong())
        }
        val dawn = log.dawnAt ?: return null
        val lit = maxOf(DawnModel.sweepDuration, (lastRelight ?: 0.0) + DawnModel.relight)
        return dawn.plusMillis(((lit + DawnModel.settle) * 1000).toLong())
    }

    /** The sky at [now]. */
    fun skyLight(now: Instant?, pin: NWMotionPin?): NWSkyLight {
        duskElapsed(now, pin)?.let { d ->
            val f = DawnModel.dusk(d)
            return NWSkyLight(AuroraPalette.working.towardNight(f.aurora), f.band, null, starField(f.aurora))
        }
        dawnElapsed(now, pin)?.let { w ->
            val f = DawnModel.dawn(w, lastRelight)
            if (!f.finished) {
                // Up from the night; the sweep carries the gold, the sky behind it only warms a little.
                val sunrise = AuroraPalette.night.mixed(AuroraPalette.dawn, 0.35 * f.warmth)
                return NWSkyLight(sunrise.mixed(AuroraPalette.working, 1 - f.aurora), f.band, f, starField(f.aurora))
            }
        }
        return NWSkyLight(AuroraPalette.working, 0.0, null)
    }

    /**
     * A star's light in the power story, as (brightness, scale): at dusk every working (or paused) star exhales and
     * dims together; at dawn each paused star stays dim until its own resume is confirmed, then relights. (1, 1)
     * otherwise.
     */
    fun starLight(s: SkyStar, now: Instant?, pin: NWMotionPin?): Pair<Double, Double> {
        duskElapsed(now, pin)?.let { d ->
            if (!(s.state == StarState.PAUSED || s.state == StarState.WORKING || s.id in log.affected)) return 1.0 to 1.0
            val f = DawnModel.dusk(d)
            return f.stars to f.starScale
        }
        val w = dawnElapsed(now, pin)
        if (w != null && s.id in log.affected) return DawnModel.starBrightness(w, relights[s.id]) to 1.0
        return 1.0 to 1.0
    }
}
