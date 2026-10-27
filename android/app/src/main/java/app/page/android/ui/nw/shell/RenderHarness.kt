package app.page.android.ui.nw.shell

import androidx.compose.runtime.Composable
import app.page.android.model.CardGlow
import app.page.android.ui.nw.theme.NWMotionPin
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * What the debug render harness (the demo's `page_render` launch extra) tells the app to pin, so a screenshot of
 * one Night Watch screen is the same every time: a fixed aurora phase, a fixed "now", a glow setting, a motion
 * pinned at one moment. Plain state: nothing here is ever set outside the debug build's Demo (a release build has
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
        /** Sky: the star whose tooltip is open. */
        val selectedStar: String? = null,
        /** Dispatch: drawn as a start that is on its way. */
        val dispatchSending: Boolean = false,
        /** Now: this row is the one arriving (Final approach), drawn [pin]'s seconds in, with the rows below making room. */
        val pinnedArrival: String? = null,
        /** Now: these rows are drawn folding away (their reply confirmed), as if their pages had just closed. */
        val ghosts: Set<String> = emptySet(),
    )

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
