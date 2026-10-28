package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// Live sessions (docs/SESSIONS-PROTOCOL.md): what the Mac reports about each
// agent session. Pure Kotlin, like the rest of model/, so all of it runs in
// plain JVM tests.

/**
 * The agent behind a session. Claude and Codex get their brand pill; any
 * other backend (a local model runner, a future agent) keeps its raw name so
 * it still renders, with a neutral tint.
 */
sealed interface AgentBackend {
    data class Known(val backend: InterventionBackend) : AgentBackend
    data class Other(val raw: String) : AgentBackend

    val badge: String
        get() = when (this) {
            is Known -> backend.badge
            is Other -> raw.uppercase()
        }

    /** "Claude", "Ollama"; "Your agent" when the Mac didn't say. */
    val displayName: String
        get() = when (this) {
            is Known -> backend.displayName
            is Other -> if (raw == "unknown") "Your agent" else raw.take(1).uppercase() + raw.drop(1)
        }

    companion object {
        fun fromWire(raw: String?): AgentBackend {
            val trimmed = (raw ?: "").trim()
            InterventionBackend.fromWire(trimmed.lowercase())?.let { return Known(it) }
            return Other(if (trimmed.isEmpty()) "unknown" else trimmed.capped(24))
        }
    }
}

enum class SessionGroup {
    NEEDS_YOU, WORKING, IDLE;

    val title: String
        get() = when (this) {
            NEEDS_YOU -> "NEEDS YOU"
            WORKING -> "WORKING"
            IDLE -> "IDLE"
        }
}

/**
 * The Mac's view of a session. Anything this build doesn't know becomes
 * UNKNOWN, which groups with idle sessions and never offers Stop.
 */
enum class LiveSessionState(val wire: String) {
    IDLE("idle"),
    ACTIVE("active"),
    WAITING_ON_USER("waitingOnUser"),
    WAITING_ON_APPROVAL("waitingOnApproval"),
    RATE_LIMITED("rateLimited"),
    INTERRUPTED("interrupted"),
    FAILED("failed"),
    OFFLINE("offline"),
    UNKNOWN("unknown");

    val group: SessionGroup
        get() = when (this) {
            WAITING_ON_USER, WAITING_ON_APPROVAL -> SessionGroup.NEEDS_YOU
            ACTIVE -> SessionGroup.WORKING
            else -> SessionGroup.IDLE
        }

    val isWaiting: Boolean get() = group == SessionGroup.NEEDS_YOU

    val label: String
        get() = when (this) {
            IDLE -> "Idle"
            ACTIVE -> "Working"
            WAITING_ON_USER -> "Waiting for you"
            WAITING_ON_APPROVAL -> "Needs approval"
            RATE_LIMITED -> "Rate limited"
            INTERRUPTED -> "Interrupted"
            FAILED -> "Failed"
            OFFLINE -> "Offline"
            UNKNOWN -> "Unknown"
        }

    companion object {
        fun fromWire(raw: String?): LiveSessionState {
            val t = (raw ?: "").trim()
            return entries.firstOrNull { it.wire == t } ?: UNKNOWN
        }
    }
}

data class LiveSession(
    val id: String,
    val backend: AgentBackend,
    val title: String,
    /** Home-abbreviated by the Mac. */
    val cwd: String,
    val state: LiveSessionState,
    /** Raw host name ("cmux", "Ghostty", "unknown"). */
    val host: String,
    val canType: Boolean,
    /** Why Page can't type here; only meaningful when [canType] is false. */
    val typeBlocker: String?,
    val canInterrupt: Boolean,
    val provider: String?,
    val lastActivityAt: Instant?,
    /** The open page for this session, if any. */
    val interventionId: String?,
    val preview: String,
    /**
     * The AskUserQuestion this session is blocked on, when the Mac sent it (a Mac that sends it also accepts
     * `answer`).
     */
    val ask: SessionAsk? = null,
    /**
     * What a working session is doing, for the In flight card. Every one is an optional field of the Mac's list
     * (docs/SESSIONS-PROTOCOL.md); an older Mac sends none and the card shows what it has.
     */
    val flight: SessionFlight? = null,
    /**
     * Page can type into this terminal once the turn ends, so the phone may offer "When it finishes" (needs `hold-v1`
     * in the list's caps too). A busy Codex session outside cmux is `canType` false with this true.
     */
    val canHold: Boolean = false,
    /** What the Mac holds for this session until its turn ends, and entries settled in the last 15 minutes. Oldest first. */
    val held: List<HeldMessage> = emptyList(),
    /**
     * `images-v1`: how a photo sent from the room reaches this session. [ATTACH_IMAGE]: pasted, so Claude attaches it as
     * an image. [ATTACH_PATH]: the file's location is typed and Claude opens it itself. null: no photos here.
     */
    val attach: String? = null,
    /** Why a session Page can type into takes no photos ("Page can't send photos to Codex yet"). */
    val attachBlocker: String? = null,
) {
    val hostLabel: String
        get() {
            val h = host.trim()
            return if (h.isEmpty() || h.lowercase() == "unknown") "Unknown host" else h
        }

    val blockerText: String get() = typeBlocker ?: DEFAULT_BLOCKER

    /** Stop is offered only where the Mac says Esc works and only mid-turn. */
    val isStoppable: Boolean get() = state == LiveSessionState.ACTIVE && canInterrupt

    /** A waiting session whose prompt has a page: answer it there. */
    val openPageId: String? get() = if (state.isWaiting) interventionId else null

    companion object {
        const val DEFAULT_BLOCKER = "Page can't type into this session."
        const val ATTACH_IMAGE = "image"
        const val ATTACH_PATH = "path"

        /**
         * Lenient like [Intervention]: only `id` is required. A malformed
         * optional field is treated as missing, and the capabilities default
         * to the safe side (can't type, can't stop).
         */
        fun decode(element: JsonElement): LiveSession? {
            val c = element as? JsonObject ?: return null
            val rawId = c.str("id")?.trim() ?: return null
            if (rawId.isEmpty() || rawId.length > 200) return null
            val cwd = (c.str("cwd") ?: "").capped(300)
            val rawTitle = (c.str("title") ?: "").trim()
            val last = cwd.split('/').lastOrNull { it.isNotEmpty() }
            val title = when {
                rawTitle.isNotEmpty() -> rawTitle.capped(120)
                last != null && last != "~" -> last
                else -> "Session ${rawId.take(8)}"
            }
            val canType = c.bool("canType") ?: false
            val blocker = (c.str("typeBlocker") ?: "").trim()
            val iv = (c.str("interventionId") ?: "").trim()
            return LiveSession(
                id = rawId,
                backend = AgentBackend.fromWire(c.str("backend")),
                title = title,
                cwd = cwd,
                state = LiveSessionState.fromWire(c.str("state")),
                host = (c.str("host") ?: "unknown").capped(40),
                canType = canType,
                typeBlocker = if (canType || blocker.isEmpty()) null else blocker.capped(200),
                canInterrupt = c.bool("canInterrupt") ?: false,
                provider = c.str("provider"),
                lastActivityAt = PageDate.parseAny(c["lastActivityAt"]),
                interventionId = if (iv.isEmpty() || iv.length > 200) null else iv,
                preview = (c.str("preview") ?: "").capped(300),
                ask = SessionAsk.decode(c["ask"]),
                flight = SessionFlight.decode(c),
                canHold = c.bool("canHold") ?: false,
                held = lossyList(c["held"], HeldMessage::decode)?.elements?.take(20) ?: emptyList(),
                // A value this build doesn't know is no photo route at all, never a guess.
                attach = c.str("attach")?.trim()?.takeIf { it == ATTACH_IMAGE || it == ATTACH_PATH },
                attachBlocker = c.str("attachBlocker")?.trim()?.takeIf { it.isNotEmpty() }?.capped(200),
            )
        }
    }
}

data class SessionSection(val group: SessionGroup, val sessions: List<LiveSession>)

object SessionGrouping {
    /**
     * "Needs you", "Working", "Idle", leaving out empty groups. Most recent
     * activity first within a group, so the order never depends on how the
     * Mac happened to sort its list.
     */
    fun sections(sessions: List<LiveSession>): List<SessionSection> {
        val sorted = sessions.sortedWith(
            compareBy<LiveSession> { it.state.group.ordinal }
                .thenByDescending { it.lastActivityAt ?: Instant.MIN }
                .thenBy { it.title }
                .thenBy { it.id }
        )
        return SessionGroup.entries.mapNotNull { group ->
            val members = sorted.filter { it.state.group == group }
            if (members.isEmpty()) null else SessionSection(group, members)
        }
    }

    fun needsYouCount(sessions: List<LiveSession>): Int = sessions.count { it.state.isWaiting }
}

/**
 * Finds the session a `start` created, once it shows up in the list: new
 * since the request, in the requested folder (the list's cwd is
 * home-abbreviated by the Mac, the folder absolute). iOS StartedSessionMatch.
 */
object StartedSessionMatch {
    private val home = Regex("^/Users/[^/]+")

    /** `/Users/roy/x` -> `~/x`, as the Mac abbreviates the list's cwd. */
    fun abbreviated(path: String): String {
        val m = home.find(path) ?: return path
        return "~" + path.substring(m.range.last + 1)
    }

    fun find(sessions: List<LiveSession>, folder: String, existing: Set<String>): LiveSession? {
        val want = listOf(folder, abbreviated(folder)).map { it.removeSuffix("/") }
        return sessions.firstOrNull { it.id !in existing && it.cwd in want }
    }
}
