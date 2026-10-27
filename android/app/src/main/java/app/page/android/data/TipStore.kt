package app.page.android.data

import app.page.android.model.NWTip
import app.page.android.model.TipBook
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Which first-time tips this phone has already shown or used ([TipBook]); each is shown once, never blocks
 * anything, and is remembered here (`page.tip.<name>`).
 */
object TipStore {
    private val _book = MutableStateFlow(TipBook())
    val book: StateFlow<TipBook> = _book.asStateFlow()

    fun init() {
        val seen = NWTip.entries.filter { AppGraph.prefs.boolean(TipBook.key(it)) }.toSet()
        _book.value = TipBook(seen)
    }

    /** The tip is dismissed, or its gesture was used. */
    fun retire(tip: NWTip) {
        val b = _book.value
        if (b.hasSeen(tip)) return
        AppGraph.prefs.putBoolean(TipBook.key(tip), true)
        _book.value = b.retire(tip)
    }

    /** Every tip comes back (the Tower's "Show the tips again"). */
    fun reset() {
        for (t in NWTip.entries) AppGraph.prefs.putBoolean(TipBook.key(t), false)
        _book.value = TipBook()
    }

    /** The render harness shows every tip fresh. */
    fun overrideForRender(book: TipBook) {
        _book.value = book
    }
}
