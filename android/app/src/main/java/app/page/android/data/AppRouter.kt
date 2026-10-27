package app.page.android.data

import app.page.android.model.DeepLink
import app.page.android.model.NWDeepLink
import app.page.android.model.NWDestination
import app.page.android.model.NWSheet
import app.page.android.model.RoomEntry
import app.page.android.model.SessionIntent
import app.page.android.model.SheetQueue
import app.page.android.model.LegacySkyMode
import app.page.android.model.TowerSection
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** The first-generation tabs, kept only so the retired tab bar still compiles until the screens stage removes it. */
enum class AppTab { SESSIONS, INBOX, HISTORY, SETTINGS }

/**
 * App-wide navigation state, so a notification tap, a widget or Quick Settings tap or a `page://` link can open
 * a specific card whether the app was running, in the background or cold-started (the Android side of iOS
 * AppRouter.swift). A request made before any screen exists simply waits here until the shell appears and
 * shows it.
 *
 * There are exactly two destinations (Now and Lanes). Everything else is a sheet or a room, and only one sheet can
 * be up at a time: asking for another while one is showing closes the first, and the new one comes up from
 * [sheetDismissed] ([SheetQueue]). A deep link always lands on Now with the card's Decision sheet over it, never
 * on a tab.
 */
object AppRouter {
    data class State(
        val destination: NWDestination = NWDestination.NOW,
        val sheets: SheetQueue = SheetQueue(),
        /** The unpair confirmation, asked for by Now, Lanes and the Tower alike. */
        val confirmingUnpair: Boolean = false,
        /** The Paired screen is up after a first pairing; while it is, nothing else asks for notification permission. */
        val pairedWelcome: Boolean = false,
    )

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private inline fun update(block: (State) -> State) {
        _state.value = block(_state.value)
    }

    /**
     * Call once the preferences exist. Nothing is remembered by the router now: the old Sky/Lanes toggle is gone, so
     * what it stored (an old "sky" meant constellations, which no longer exist) is cleared and ignored.
     */
    fun restore() {
        LegacySkyMode.forget(
            stored = { AppGraph.prefs.string(LegacySkyMode.storageKey) },
            clear = { AppGraph.prefs.putString(LegacySkyMode.storageKey, null) },
        )
    }

    fun selectDestination(d: NWDestination) = update { it.copy(destination = d) }

    /** Opens a page's Decision sheet over Now. */
    fun open(interventionId: String, switchTab: Boolean = true) = update {
        it.copy(destination = if (switchTab) NWDestination.NOW else it.destination, sheets = it.sheets.request(NWSheet.Decision(interventionId)))
    }

    /** How the next room opens (Screen, Type, Stop), read once by that room. */
    private data class PendingEntry(val sessionId: String, val entry: RoomEntry, val at: Instant)

    private var roomEntry: PendingEntry? = null

    /** Opens a live session's room, on Story unless the caller says how. */
    fun openSession(sessionId: String, entry: RoomEntry = RoomEntry.STORY) {
        roomEntry = if (entry == RoomEntry.STORY) null else PendingEntry(sessionId, entry, Instant.now())
        update { it.copy(sheets = it.sheets.request(NWSheet.Session(sessionId))) }
    }

    /**
     * The entry asked for this session's room, once: a request older than a few seconds belongs to an earlier
     * opening and is dropped.
     */
    fun takeRoomEntry(sessionId: String, now: Instant = Instant.now()): RoomEntry {
        val e = roomEntry
        roomEntry = null
        if (e == null || e.sessionId != sessionId || now.toEpochMilli() - e.at.toEpochMilli() >= 5000) return RoomEntry.STORY
        return e.entry
    }

    /** Opens the Tower, optionally scrolled to a section. */
    fun openTower(section: TowerSection? = null) = update { it.copy(sheets = it.sheets.request(NWSheet.Tower(section))) }

    fun openDispatch() = update { it.copy(sheets = it.sheets.request(NWSheet.Dispatch)) }
    fun openHistory() = update { it.copy(sheets = it.sheets.request(NWSheet.History)) }
    fun requestUnpair() = update { it.copy(confirmingUnpair = true) }
    fun clearUnpairRequest() = update { it.copy(confirmingUnpair = false) }
    fun setPairedWelcome(on: Boolean) = update { it.copy(pairedWelcome = on) }

    /** The user closed the sheet (back, scrim, a close button). */
    fun closeSheet() = update { it.copy(sheets = it.sheets.close()) }

    /** A sheet finished dismissing: present whatever was waiting. */
    fun sheetDismissed() = update { it.copy(sheets = it.sheets.dismissed()) }

    /**
     * Handles `page://intervention/<id>`, `page://sessions` (the widget), `page://now`, `page://lanes` (and its old
     * name `page://sky`) and `page://tower`. Returns false for anything else.
     */
    fun handle(url: String): Boolean {
        val link = NWDeepLink.parse(url) ?: return false
        when (link) {
            NWDeepLink.Now -> selectDestination(NWDestination.NOW)
            NWDeepLink.Lanes -> selectDestination(NWDestination.LANES)
            NWDeepLink.Tower -> openTower()
            is NWDeepLink.Decision -> open(link.pageId)
        }
        return true
    }

    fun reset() {
        roomEntry = null
        update { it.copy(destination = NWDestination.NOW, sheets = SheetQueue(), confirmingUnpair = false) }
    }

    // region Legacy entry points (the first-generation screens, until the screens stage replaces them)

    /** `AppRouter.openSession(id, switchTab, intent)` of the old Sessions/Inbox screens. */
    fun openSession(sessionId: String, switchTab: Boolean, intent: SessionIntent = SessionIntent.NONE) {
        openSession(
            sessionId,
            when (intent) {
                SessionIntent.NONE -> RoomEntry.STORY
                SessionIntent.SCREEN -> RoomEntry.SCREEN
                SessionIntent.TYPE -> RoomEntry.TYPE
            },
        )
    }

    fun openNewSession() = openDispatch()
    fun closeNewSession() = closeSheet()
    fun closeReply() = closeSheet()
    fun closeSession() = closeSheet()

    // endregion
}

/**
 * One-shot hints for the first screen shown after launch (set by the debug demo's launch extras for scripted
 * screenshots; never set in release).
 */
object LaunchHints {
    /** "terminal" or "workflows": the session detail opens on that pane. */
    var sessionPane: String? = null

    /** A workflow run to open on top of the session detail. */
    var workflowRunId: String? = null
}
