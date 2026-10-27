package app.page.android.ui.nw.lanes

import app.page.android.model.DawnModel
import app.page.android.model.DuskDawnLog
import app.page.android.model.StarState
import app.page.android.model.secondsSince
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.pinned
import app.page.android.ui.nw.theme.starField
import java.time.Instant
import kotlin.math.max

/** What Lanes' power story looks like at one moment. */
data class NWLanesLight(
    val palette: AuroraPalette,
    /** The grey band: 0..1. */
    val band: Double,
    /** The dawn's sweep and gold, while it plays. */
    val dawn: DawnModel.Dawn?,
    /** How much of the background star field shows (it fades with the dusk). */
    val stars: Double = 1.0,
    /**
     * How much of the aurora behind the list shows: it fades in with the dusk, holds through the night of a pause,
     * and fades out as the dawn settles. 0 in the day, when only the shell's own sky shows.
     */
    val cover: Double = 0.0,
)

/**
 * Lanes' power story at any moment (iOS NWDuskDawn.swift's `LanesScreenData` extension): the aurora fading to dusk
 * with the band holding; or the gold dawn rising back into the day, each paused lane relighting only once its own
 * resume is confirmed. Pure, so the harness and the tests can draw any moment.
 *
 * [laneIds] are the lanes in the order they are drawn. The dawn rises from the bottom of the screen, so a lane's
 * place in the list is its height: the lower lanes relight first.
 *
 * `now` is the wall clock while the screen is live, and null when it is drawn still (Remove animations, a harness
 * frame with no motion pinned): then a pause is drawn settled and no dawn plays, every change a cut.
 */
class LanesPowerStory(private val paused: Boolean, private val log: DuskDawnLog, laneIds: List<String>) {
    /** Every lane as a height in the list: 0 the top lane .. 1 the bottom one. */
    private val laneHeights: Map<String, Double> = run {
        val n = max(1, laneIds.size).toDouble()
        val out = LinkedHashMap<String, Double>()
        laneIds.forEachIndexed { i, id -> if (id !in out) out[id] = (i + 0.5) / n }
        out
    }

    /** When each paused lane relights: its own confirmed resume, one by one (empty unless a dawn is under way). */
    val relights: Map<String, Double> = DawnModel.relightTimes(log.dawnStars(laneHeights))

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

    /** True when the power story has anything to draw behind the list: a pause (settled or falling) or a dawn that is still playing. */
    fun isShown(now: Instant, pin: NWMotionPin?): Boolean = paused || isMoving(now, pin)

    /**
     * When the power story stops moving and its clocks can stop: the end of the dusk, or of the dawn's settle (later
     * if a late relight holds it open). null when there is no clock to stop: a pause already under way when Page
     * opened, or no dawn. A dusk that has already ended gives a time in the past, and the caller then waits nothing. Pure.
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

    /** The light at [now]: the day (nothing drawn behind the list), the dusk falling with the band holding, or the gold dawn. */
    fun skyLight(now: Instant?, pin: NWMotionPin?): NWLanesLight {
        duskElapsed(now, pin)?.let { d ->
            val f = DawnModel.dusk(d)
            return NWLanesLight(AuroraPalette.working.towardNight(f.aurora), f.band, null, starField(f.aurora), cover = f.aurora)
        }
        dawnElapsed(now, pin)?.let { w ->
            val f = DawnModel.dawn(w, lastRelight)
            if (!f.finished) {
                // Up from the night; the sweep carries the gold, the sky behind it only warms a little.
                val sunrise = AuroraPalette.night.mixed(AuroraPalette.dawn, 0.35 * f.warmth)
                return NWLanesLight(sunrise.mixed(AuroraPalette.working, 1 - f.aurora), f.band, f, starField(f.aurora), cover = f.aurora)
            }
        }
        return NWLanesLight(AuroraPalette.working, 0.0, null)
    }

    /**
     * A lane's light in the power story, as (brightness, scale): at dusk every working (or paused) lane exhales and
     * dims together; at dawn each paused lane stays dim until its own resume is confirmed, then relights. (1, 1)
     * otherwise.
     */
    fun starLight(id: String, state: StarState, now: Instant?, pin: NWMotionPin?): Pair<Double, Double> {
        duskElapsed(now, pin)?.let { d ->
            if (!(state == StarState.PAUSED || state == StarState.WORKING || id in log.affected)) return 1.0 to 1.0
            val f = DawnModel.dusk(d)
            return f.stars to f.starScale
        }
        val w = dawnElapsed(now, pin)
        if (w != null && id in log.affected) return DawnModel.starBrightness(w, relights[id]) to 1.0
        return 1.0 to 1.0
    }
}
