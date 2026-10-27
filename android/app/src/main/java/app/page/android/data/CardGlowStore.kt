package app.page.android.data

import app.page.android.model.CardGlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The "Card glow" setting (Off, Subtle, Full; Off by default), the phone's own preference. Every glass surface
 * reads it through `LocalCardGlow`, provided once at the root from here. Anything stored that is unknown reads
 * as Off, never a glow.
 */
object CardGlowStore {
    private val _glow = MutableStateFlow(CardGlow.default)
    val glow: StateFlow<CardGlow> = _glow.asStateFlow()

    fun init() {
        _glow.value = CardGlow.stored(AppGraph.prefs.string(CardGlow.storageKey))
    }

    fun set(value: CardGlow) {
        AppGraph.prefs.putString(CardGlow.storageKey, value.raw)
        _glow.value = value
    }

    /** The render harness's `page_glow` extra: shown, not saved. */
    fun overrideForRender(value: CardGlow) {
        _glow.value = value
    }
}
