package app.page.android.ui.nw.shell

import androidx.compose.runtime.Composable
import app.page.android.model.CardGlow
import app.page.android.model.Daypart
import app.page.android.ui.nw.theme.NWMotionPin
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * What the debug render harness (the demo's `page_render` launch extra) tells the app to pin, so a screenshot of
 * one Night Watch screen is the same every time: a fixed aurora phase, a fixed "now", a glow setting, a motion
 * pinned at one moment, the time of day. Plain state: nothing here is ever set outside the debug build's Demo (a release build has
 * no way to set it), and nothing here sends or stores anything. (iOS RenderHarness.swift `-NWRender`.)
 */
object RenderHarness {
    data class Spec(
        val screen: String,
        val glow: CardGlow? = null,
        /** Seconds the aurora, pulse and stars are pinned at. */
        val phase: Double? = null,
        /** The clock the arm ring and ages use. */
        val now: Instant? = null,
        val pin: NWMotionPin? = null,
        /** Now: scroll this item (a row's id, or "section-..." key) to the middle once drawn. */
        val scrollTo: String? = null,
        /** Now: scroll this section key to the top. */
        val scrollTop: String? = null,
        /** Now: draw the first Undoable row this far through a swipe (dp). */
        val dragDp: Float? = null,
        /** Now: the "New up N" pill count. */
        val queuedNew: Int = 0,
        /** The hold ring pinned at this progress (0..1), for the Irreversible hold button. */
        val hold: Double? = null,
        /** Lanes: drawn as if live sessions can't load, for this reason (a demo is always ready, so the live check can't show it). */
        val lanesAvailability: app.page.android.model.SessionAvailability? = null,
        /** Dispatch: drawn as a start that is on its way. */
        val dispatchSending: Boolean = false,
        /** Now: this row is the one arriving (Final approach), drawn [pin]'s seconds in, with the rows below making room. */
        val pinnedArrival: String? = null,
        /** Now: these rows are drawn folding away (their reply confirmed), as if their pages had just closed. */
        val ghosts: Set<String> = emptySet(),
        /**
         * The local minute of the day (0 ..< 1440) the Now and Lanes skies are drawn at, never an instant, so an
         * emulator in any time zone draws the same sky. null is 01:12, nighttime, so every frame without it is unchanged.
         */
        val dayTime: Double? = null,
        /** Now: the In flight section's script for a `motion-inflight-*` screen ([app.page.android.ui.nw.theme.LocalFlightScript]). */
        val flightScript: List<Pair<Double, app.page.android.model.InFlightSection>>? = null,
        /** Now: the rest of Now's script for a `motion-now-*` screen ([app.page.android.ui.nw.theme.LocalNowScript]). */
        val nowScript: List<Pair<Double, app.page.android.model.NowMotion.Look>>? = null,
        /** Drawn as under Reduce Motion (the demo's `page_reduce`), whatever the system says. */
        val reduce: Boolean = false,
    )

    /**
     * A time of day as a minute (the demo's `page_daytime`): a phase's name (the middle of its core: earlyMorning,
     * morning, afternoon, nighttime), "HH:MM" (00:00 to 23:59), or a plain minute 0 ..< 1440. Anything else is null.
     * (iOS RenderArguments.minuteOfDay.) Pure.
     */
    fun minuteOfDay(s: String?): Double? {
        if (s == null) return null
        Daypart.of(s)?.let { return it.coreMinute }
        val parts = s.split(":")
        if (parts.size == 2) {
            val (hh, mm) = parts
            if (hh.isEmpty() || hh.length > 2 || mm.length != 2 || !hh.all { it.isDigit() } || !mm.all { it.isDigit() }) return null
            val h = hh.toInt()
            val m = mm.toInt()
            if (h !in 0..23 || m !in 0..59) return null
            return (h * 60 + m).toDouble()
        }
        val m = s.toDoubleOrNull() ?: return null
        return if (m.isFinite() && m >= 0 && m < 1440) m else null
    }

    private val _spec = MutableStateFlow<Spec?>(null)
    val spec: StateFlow<Spec?> = _spec.asStateFlow()

    fun set(spec: Spec?) {
        _spec.value = spec
    }

    /** A hold ring pinned part-way (the Stop overlay's progress). */
    private val _heldProgress = MutableStateFlow<Double?>(null)
    val heldProgress: StateFlow<Double?> = _heldProgress.asStateFlow()

    fun pinHeld(seconds: Double?) {
        _heldProgress.value = seconds
    }

    /**
     * Content shown in place of the shell for a harness screen that is not part of it (the component gallery),
     * supplied by the debug Demo. In a release build this stays a function that returns null.
     */
    @Volatile var standalone: (String) -> (@Composable () -> Unit)? = { null }
}
