package app.page.android.data

import app.page.android.model.Absence
import app.page.android.model.AwayTracker
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Remembers when Page last went to the background and which absence's Brief was dismissed, so the Return Brief
 * and the "While you were away" Horizon sentence can be built when you come back ([Absence]). Two timestamps in
 * the phone's own preferences; nothing else.
 */
object AwayStore {
    data class State(
        /** The absence just ended (null when short, or on a first launch). */
        val absence: Absence? = null,
        /** The `since` of the absence whose Brief was dismissed. */
        val dismissedFor: Instant? = null,
    ) {
        /** The Brief shows for a long absence that has not been dismissed. */
        val showsBrief: Boolean get() = absence?.shouldShowBrief(dismissedFor) == true
    }

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private fun date(key: String): Instant? = AppGraph.prefs.long(key)?.let { Instant.ofEpochMilli(it) }

    /** Set by the render harness: its fixture absence is not replaced when the activity comes to the foreground. */
    @Volatile private var pinnedForRender = false

    /** Page came to the foreground at [now]: the absence is from when it left to now. */
    fun onForeground(now: Instant = Instant.now()) {
        if (pinnedForRender) return
        val last = date(AwayTracker.lastActiveKey)
        _state.value = State(Absence.make(last, now), date(AwayTracker.dismissedKey))
        AppGraph.prefs.putLong(AwayTracker.lastActiveKey, now.toEpochMilli())
    }

    /** Page went to the background at [now]. */
    fun onBackground(now: Instant = Instant.now()) {
        AppGraph.prefs.putLong(AwayTracker.lastActiveKey, now.toEpochMilli())
    }

    /** The Brief was dismissed for this absence. */
    fun dismissBrief() {
        val a = _state.value.absence ?: return
        AppGraph.prefs.putLong(AwayTracker.dismissedKey, a.since.toEpochMilli())
        _state.value = _state.value.copy(dismissedFor = a.since)
    }

    /** The render harness's fixture: an absence ending now. */
    fun overrideForRender(absence: Absence?, dismissedFor: Instant? = null) {
        pinnedForRender = true
        _state.value = State(absence, dismissedFor)
    }
}
