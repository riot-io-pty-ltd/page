package app.page.android.data

import app.page.android.model.AnswerSheet
import app.page.android.model.SessionAsk
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * The question being answered, as the person is part-way through it, shared by the Story, the Screen lens and the
 * Decision sheet so all three show one draft. A draft lives only in memory; it is replaced when the question
 * changes. (iOS AnswerDraftStore.swift.)
 */
object AnswerDraftStore {
    private val _sheets = MutableStateFlow<Map<String, AnswerSheet>>(emptyMap())
    val sheets: StateFlow<Map<String, AnswerSheet>> = _sheets.asStateFlow()

    /** The draft for [ask]: kept while the question is unchanged, else fresh. */
    fun sheet(ask: SessionAsk, allowsOther: Boolean = true): AnswerSheet {
        val s = _sheets.value[ask.id]
        if (s != null && s.ask == ask && s.allowsOther == allowsOther) return s
        return AnswerSheet(ask, allowsOther)
    }

    /** Applies an edit to a copy of the draft (so observers see a new value) and keeps it. */
    fun edit(ask: SessionAsk, allowsOther: Boolean = true, change: (AnswerSheet) -> Unit) {
        val next = sheet(ask, allowsOther).copy()
        change(next)
        store(ask.id, next)
    }

    private fun store(id: String, sheet: AnswerSheet) {
        var m = _sheets.value
        // Bounded: a long-lived app never collects drafts.
        if (m.size > 30 && m[id] == null) m = emptyMap()
        _sheets.value = m + (id to sheet)
    }

    /** Puts a ready-made draft where the live screens read it (the render harness). */
    fun seed(ask: SessionAsk, allowsOther: Boolean, sheet: AnswerSheet) = store(ask.id, sheet)

    fun clear() {
        _sheets.value = emptyMap()
    }
}
