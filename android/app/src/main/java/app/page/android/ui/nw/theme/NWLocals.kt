package app.page.android.ui.nw.theme

import android.content.Context
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalContext
import app.page.android.model.CardGlow
import app.page.android.model.DaypartWeights
import java.time.Instant

// The environment Night Watch surfaces read: the Card glow setting, Reduce Motion, the time of day, and the render
// harness's pins (iOS NWTheme.swift `EnvironmentValues`). Each is provided once at the root; nothing below draws its own.

/** The Card glow setting. The one place every glass surface reads it from; set once at the app root. Off unless the user turns it on. */
val LocalCardGlow = staticCompositionLocalOf { CardGlow.default }

/**
 * True when the system's "Remove animations" is on (the animator duration scale is 0): Android's Reduce Motion.
 * Compose does not follow this on its own, and the hand-driven aurora and pulse clocks would not either, so it
 * is read here and every clock honours it ([NWAnimated], [NWOneShot]).
 */
val LocalReduceMotion = staticCompositionLocalOf { false }

/** True while something covers the screen (a sheet): the aurora and pulse hold their last frame instead of redrawing under it. */
val LocalAnimationsPaused = staticCompositionLocalOf { false }

/** When set, aurora, pulse and stars use this time (seconds) instead of the clock: the render harness pins it so frames are deterministic. */
val LocalFixedPhase = staticCompositionLocalOf<Double?> { null }

/** When set, the arm ring and ages use this clock instead of the real one: the render harness pins it so a ring is drawn part-way. */
val LocalFixedNow = staticCompositionLocalOf<Instant?> { null }

/**
 * The render harness's script for the Workflows lens: the run as it was at each moment (seconds after the lens
 * appeared, the first at 0), so a frame pinned at [LocalFixedPhase] can be drawn part-way through an agent finishing or
 * the run completing. Null in the app, where the lens watches the run itself.
 */
val LocalWorkflowScript = staticCompositionLocalOf<List<Pair<Double, app.page.android.model.WorkflowRun>>?> { null }

/**
 * The time of day the Now and Lanes skies are drawn at. The root's ticker ([rememberDaypartTicker]) reads the local
 * clock every two minutes; anything without one (widgets, the gallery, previews) draws nighttime, today's aurora, and
 * the render harness pins it (`page_daytime`). Dynamic, so a tick recomposes only the skies that read it.
 */
val LocalDaypart = compositionLocalOf { DaypartWeights.NIGHTTIME }

/**
 * A signature motion pinned at one moment, for the render harness: the views that play [kind] draw the frame
 * [time] seconds after it began instead of following the clock.
 */
data class NWMotionPin(val kind: Kind, val time: Double) {
    enum class Kind(val raw: String) { EXHALE("exhale"), APPROACH("approach"), RECEIPT("receipt"), HOLD("hold"), DUSK("dusk"), DAWN("dawn"), BRIEF("brief") }
}

val LocalMotionPin = staticCompositionLocalOf<NWMotionPin?> { null }

/** The pinned seconds into [kind], or null when that motion is live. */
fun NWMotionPin?.pinned(kind: NWMotionPin.Kind): Double? = if (this != null && this.kind == kind) time else null

/** Observes `Settings.Global.ANIMATOR_DURATION_SCALE` and reports whether animations are removed. */
@Composable
fun rememberReduceMotion(): State<Boolean> {
    val context = LocalContext.current
    val state = remember { mutableStateOf(isReduceMotion(context)) }
    DisposableEffect(context) {
        val resolver = context.contentResolver
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                state.value = isReduceMotion(context)
            }
        }
        resolver.registerContentObserver(Settings.Global.getUriFor(Settings.Global.ANIMATOR_DURATION_SCALE), false, observer)
        state.value = isReduceMotion(context)
        onDispose { resolver.unregisterContentObserver(observer) }
    }
    return state
}

fun isReduceMotion(context: Context): Boolean = try {
    Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
} catch (_: Exception) {
    false
}
