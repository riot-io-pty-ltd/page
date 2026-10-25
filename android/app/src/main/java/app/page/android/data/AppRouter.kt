package app.page.android.data

import app.page.android.model.DeepLink
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Four tabs: Stats lives inside History as a segment. Sessions first: the live list is home. */
enum class AppTab { SESSIONS, INBOX, HISTORY, SETTINGS }

/**
 * App-wide navigation state, so a notification tap or a `page://` link can
 * open a specific page whether the app was running, in the background or
 * cold-started. A request made before any screen exists simply waits here
 * until the main screen appears and shows it.
 *
 * A page's reply screen and a session's detail screen are both full-screen
 * overlays on the tabs, and only one is up at a time: opening one replaces
 * the other.
 */
object AppRouter {
    data class Route(
        val tab: AppTab = AppTab.SESSIONS,
        val interventionId: String? = null,
        val sessionId: String? = null,
        /** v4: the "New session" sheet. */
        val newSession: Boolean = false,
    )

    private val _route = MutableStateFlow(Route())
    val route: StateFlow<Route> = _route.asStateFlow()

    fun selectTab(tab: AppTab) {
        _route.value = _route.value.copy(tab = tab)
    }

    /**
     * Opens a page's reply screen. `switchTab = false` keeps the current tab
     * (the Sessions list's "Open page").
     */
    fun open(interventionId: String, switchTab: Boolean = true) {
        val r = _route.value
        _route.value = r.copy(tab = if (switchTab) AppTab.INBOX else r.tab, interventionId = interventionId, sessionId = null, newSession = false)
    }

    /** Opens a live session's detail screen (the reply screen's "Open session", or a tap in the list). */
    fun openSession(sessionId: String) {
        _route.value = _route.value.copy(tab = AppTab.SESSIONS, interventionId = null, sessionId = sessionId, newSession = false)
    }

    fun openNewSession() {
        _route.value = _route.value.copy(tab = AppTab.SESSIONS, interventionId = null, sessionId = null, newSession = true)
    }

    fun closeNewSession() {
        _route.value = _route.value.copy(newSession = false)
    }

    fun closeReply() {
        _route.value = _route.value.copy(interventionId = null)
    }

    fun closeSession() {
        _route.value = _route.value.copy(sessionId = null)
    }

    /** Handles `page://intervention/<id>`. Returns false for anything else. */
    fun handle(url: String): Boolean {
        val id = DeepLink.interventionId(url) ?: return false
        open(id)
        return true
    }

    fun reset() {
        _route.value = Route()
    }
}

/**
 * One-shot hints for the first screen shown after launch (set by the debug
 * demo's launch extras for scripted screenshots; never set in release).
 */
object LaunchHints {
    /** "terminal" or "workflows": the session detail opens on that pane. */
    var sessionPane: String? = null

    /** A workflow run to open on top of the session detail. */
    var workflowRunId: String? = null
}
