package app.page.android.model

import java.time.Instant

// "In flight": the working sessions the Inbox lists under the pages waiting for
// you, so you can see what is running and jump straight into it. Pure Kotlin,
// like the rest of model/, so all of it runs in plain JVM tests.

/** Which terminals the Mac can read a screen from. */
object SessionHosts {
    /**
     * Hosts whose visible screen the Mac mirrors (`screen`, SESSIONS-PROTOCOL
     * §4). The protocol doc says "tmux and cmux", but the Mac's
     * SessionScreen.source(for:) also reads WezTerm, kitty and Herdr, and
     * Claude Squad runs in tmux. Terminal.app, iTerm2, VS Code, Ghostty and an
     * unknown host aren't mirrored, so a "Screen" action there would only open
     * an empty Conversation.
     */
    private val mirrored = setOf("tmux", "cmux", "wezterm", "kitty", "herdr", "claude squad")

    fun canMirror(host: String): Boolean = host.trim().lowercase() in mirrored
}

/** One working session as the Inbox's "In flight" section shows it. */
data class LegacyInFlightRow(
    val session: LiveSession,
    /** The current step: the Mac's one-line activity ("Bash: ./gradlew test"). */
    val step: String,
    /** Page can show this session's screen (a mirrored host, or one already received). */
    val canShowScreen: Boolean,
) {
    /** Type is offered only where Page can type; otherwise the row says "view only". */
    val canType: Boolean get() = session.canType

    /** "Active 12s ago". The Mac sends the last activity time, not when the turn began. */
    fun activity(now: Instant): String =
        session.lastActivityAt?.let { RelativeTime.string("Active", it, now) } ?: session.state.label
}

object InFlight {
    const val NO_STEP = "Working…"

    /**
     * Sessions mid-turn (state `active`), in a stable order: title, then id
     * (the same as iOS). Rows never reshuffle as activity ticks, so a tap
     * lands on the row that was aimed at. [screenIds] are sessions whose
     * screen has already arrived.
     */
    fun rows(sessions: List<LiveSession>, screenIds: Set<String> = emptySet()): List<LegacyInFlightRow> =
        sessions
            .filter { it.state == LiveSessionState.ACTIVE }
            .sortedWith(
                compareBy<LiveSession, String>(String.CASE_INSENSITIVE_ORDER) { it.title }
                    .thenBy { it.id }
            )
            .map { s ->
                LegacyInFlightRow(
                    session = s,
                    step = s.preview.ifBlank { NO_STEP },
                    canShowScreen = SessionHosts.canMirror(s.host) || s.id in screenIds,
                )
            }

    /** "In flight · 2". */
    fun title(count: Int): String = "In flight · $count"
}

/** What opening a session's detail should land on, from a row's "Screen" or "Type" action. */
enum class SessionIntent { NONE, SCREEN, TYPE }
