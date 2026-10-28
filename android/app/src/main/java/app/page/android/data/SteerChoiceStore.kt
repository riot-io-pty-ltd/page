package app.page.android.data

import app.page.android.model.SendWhen
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The busy-session choice, "Now" or "When it finishes": the last one picked on this device (the default next time,
 * where it is still on offer) and whether the one-line explanations under it have been shown once. The phone's own
 * preference, never synced.
 */
object SteerChoiceStore {
    private const val KEY_LAST = "page.steer.sendWhen"
    private const val KEY_EXPLAINED = "page.steer.choiceExplained"

    private val _last = MutableStateFlow<SendWhen?>(null)
    val last: StateFlow<SendWhen?> = _last.asStateFlow()

    private val _explained = MutableStateFlow(false)
    val explained: StateFlow<Boolean> = _explained.asStateFlow()

    private var loaded = false

    /** Reads the saved values once (the first screen that needs them). */
    fun ensureLoaded() {
        if (loaded) return
        loaded = true
        _last.value = SendWhen.fromWire(AppGraph.prefs.string(KEY_LAST))
        _explained.value = AppGraph.prefs.boolean(KEY_EXPLAINED)
    }

    fun select(value: SendWhen) {
        ensureLoaded()
        _last.value = value
        AppGraph.prefs.putString(KEY_LAST, value.wire)
    }

    /** The explanations were seen: say them once only. */
    fun markExplained() {
        ensureLoaded()
        if (_explained.value) return
        _explained.value = true
        AppGraph.prefs.putBoolean(KEY_EXPLAINED, true)
    }

    /** The render harness: show a state without saving it. */
    fun overrideForRender(last: SendWhen?, explained: Boolean) {
        loaded = true
        _last.value = last
        _explained.value = explained
    }
}
