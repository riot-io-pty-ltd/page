package app.page.android.ui.nw.components

import android.os.SystemClock
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import java.time.Instant
import kotlinx.coroutines.delay
import androidx.lifecycle.Lifecycle
import app.page.android.ui.nw.theme.LocalAnimationsPaused
import app.page.android.ui.nw.theme.LocalFixedPhase
import app.page.android.ui.nw.theme.LocalReduceMotion
import androidx.lifecycle.compose.LocalLifecycleOwner as LifecycleOwnerLocal
import androidx.lifecycle.repeatOnLifecycle
import kotlin.math.max
import kotlin.math.min

// Two pieces of motion plumbing every Night Watch animation shares (iOS NWAurora.swift `NWAnimated`, NWMotion.swift
// `NWOneShot`): a clock for things that move all the time (the aurora, the pulse), and a one-shot that plays
// and then stops for good.

/** Seconds on a monotonic clock, the base the aurora and pulse run on. */
fun nwClockSeconds(): Double = SystemClock.elapsedRealtimeNanos() / 1e9

/**
 * The [nwClockSeconds] reading that corresponds to the wall-clock [instant], so a moment the stores record as an
 * `Instant` (a delivery confirmed, biometrics passed) can start a one-shot. The one-shots must never be handed epoch
 * seconds: on the monotonic base those lie decades in the future, and the frame loop would never end.
 */
fun nwClockAt(instant: Instant): Double = nwClockSeconds() - (System.currentTimeMillis() - instant.toEpochMilli()) / 1000.0

/**
 * The clock as state: seconds, redrawn at most [fps] times a second (30 at the most: the aurora's slow ribbons
 * are costly at 120 Hz). Holds one still frame when Reduce Motion is on, the render harness pins a time, or
 * [active] is false (a still pulse runs no clock at all); nothing redraws while the app is in the background
 * or the screen is covered.
 *
 * Between ticks it sleeps ([nwClockSleepMillis]) rather than asking for every display frame (up to 120 a second)
 * only to skip most of them, so the CPU wakes about [fps] times a second, not at the display's rate. The ticks
 * sit on one grid every clock shares, so the aurora at 30 and the pulse and nav at 20 wake together.
 */
@Composable
fun rememberNWClock(fps: Double = 30.0, active: Boolean = true): State<Double> {
    val reduce = LocalReduceMotion.current
    val fixed = LocalFixedPhase.current
    val covered = LocalAnimationsPaused.current
    val lifecycle = LifecycleOwnerLocal.current.lifecycle
    val seconds = remember { mutableStateOf(fixed ?: 2.0) }
    val still = reduce || fixed != null || !active
    if (still) seconds.value = fixed ?: 2.0
    LaunchedEffect(still, covered, fps, lifecycle) {
        if (still || covered) return@LaunchedEffect
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            val step = nwClockStepNanos(fps)
            while (true) {
                withFrameNanos { seconds.value = nwClockSeconds() }
                delay(nwClockSleepMillis(SystemClock.elapsedRealtimeNanos(), step))
            }
        }
    }
    return seconds
}

/** One tick of a clock that runs at [fps], capped at 30 (and at least 1). */
internal fun nwClockStepNanos(fps: Double): Long = (1e9 / max(1.0, min(fps, 30.0))).toLong()

/**
 * How long a clock that has just drawn at [nowNanos] (the [nwClockSeconds] base) sleeps before it asks for its next
 * frame: until [slackNanos] before the next multiple of [stepNanos], so the display frame that follows is the one on
 * the grid. A frame that landed just before a grid line counts as that line's tick (the slack), so no tick is drawn
 * twice. Pure.
 */
internal fun nwClockSleepMillis(nowNanos: Long, stepNanos: Long, slackNanos: Long = 4_000_000L): Long {
    val next = ((nowNanos + slackNanos) / stepNanos + 1) * stepNanos
    return max(0L, (next - slackNanos - nowNanos) / 1_000_000L)
}

/**
 * Drives an animation from the clock. [content] gets seconds. See [rememberNWClock].
 */
@Composable
fun NWAnimated(fps: Double = 30.0, active: Boolean = true, content: @Composable (Double) -> Unit) {
    val seconds by rememberNWClock(fps, active)
    content(seconds)
}

/**
 * Plays a short one-shot from [startSeconds] (the [nwClockSeconds] base) for [duration], handing [content] the
 * seconds elapsed (negative while a staggered start is still to come), then holds the final frame with no clock at
 * all (`content(null)`). Short, so it may run at the display's full rate. [pinned] draws one moment (the render
 * harness); Reduce Motion skips straight to the end.
 */
@Composable
fun NWOneShot(startSeconds: Double?, duration: Double, pinned: Double? = null, content: @Composable (Double?) -> Unit) {
    val reduce = LocalReduceMotion.current
    val lifecycle = LifecycleOwnerLocal.current.lifecycle
    val elapsed = remember(startSeconds) { mutableStateOf<Double?>(null) }
    if (pinned != null) {
        content(pinned)
        return
    }
    val playing = startSeconds != null && !reduce && nwClockSeconds() - startSeconds < duration
    LaunchedEffect(startSeconds, reduce) {
        val s = startSeconds ?: return@LaunchedEffect
        if (reduce) { elapsed.value = null; return@LaunchedEffect }
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            while (nwClockSeconds() - s < duration) {
                withFrameNanos { elapsed.value = min(duration, nwClockSeconds() - s) }
            }
            elapsed.value = null
        }
    }
    content(if (playing) elapsed.value ?: (nwClockSeconds() - startSeconds!!).coerceAtMost(duration) else null)
}

/**
 * A small spinner for a step that is running: three quarters of a ring that turns on the clock. Under Remove
 * animations it holds still, still reading as a spinner (Material's own indicator collapses to a dot when the
 * system animator scale is zero).
 */
@Composable
fun NWSpinner(color: androidx.compose.ui.graphics.Color, modifier: androidx.compose.ui.Modifier = androidx.compose.ui.Modifier, size: androidx.compose.ui.unit.Dp = 16.dp, strokeWidth: androidx.compose.ui.unit.Dp = 2.dp) {
    NWAnimated { t ->
        androidx.compose.foundation.Canvas(modifier.size(size)) {
            val lw = strokeWidth.toPx()
            val d = this.size.width - lw
            val track = androidx.compose.ui.graphics.drawscope.Stroke(lw, cap = androidx.compose.ui.graphics.StrokeCap.Round)
            drawArc(color.copy(alpha = 0.18f), 0f, 360f, false, topLeft = androidx.compose.ui.geometry.Offset(lw / 2, lw / 2), size = androidx.compose.ui.geometry.Size(d, d), style = track)
            drawArc(color, ((t * 300.0) % 360.0).toFloat() - 90f, 270f, false, topLeft = androidx.compose.ui.geometry.Offset(lw / 2, lw / 2), size = androidx.compose.ui.geometry.Size(d, d), style = track)
        }
    }
}
