package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import kotlinx.serialization.json.JsonObject

/**
 * Port of the pure part of iOS/Page/Models/SharedWidgetStore.swift: what the widget (and the Quick Settings
 * tile) show, from a `GET /status` body. The iOS credential sharing through a keychain group is not ported: the
 * Android widget reads a small non-secret snapshot the app keeps in preferences (counts, headline, runway
 * markers, Mac name, usage; no project names and no commands on the home screen).
 */
data class WidgetStatus(
    val macName: String,
    val presence: Presence,
    val needsYou: Int,
    val working: Int?,
    val live: Int?,
    val batteryLine: String?,
    val usageLine: String?,
    val fetchedAt: Instant,
    /** The raw usage, for the rings (null without usage tracking). */
    val usage: ClaudeUsage? = null,
    /** The whole reading, for the Runway on the medium widget. */
    val snapshot: MacStatusSnapshot? = null,
) {
    enum class Presence { ONLINE, STALE, OFFLINE, UNKNOWN }

    /** The next six hours as the app's Runway shows them: battery cutoff, 5-hour limit and resets. Empty when the relay sent no forecast or usage. */
    fun runway(now: Instant, zone: ZoneId = ZoneId.systemDefault()): RunwayModel = RunwayModel.build(snapshot, now, zone)

    /** "Studio MBP · on battery 41%": the Mac's name and its power, whatever is known. */
    val macLine: String
        get() {
            val parts = arrayListOf(macName)
            snapshot?.let { s ->
                if (s.onAC == true) parts.add("on power")
                else if (s.onAC == false) parts.add(s.batteryPercent?.let { "on battery $it%" } ?: "on battery")
            }
            return parts.joinToString(" · ")
        }

    /** "2 need you" / "All quiet". */
    val headline: String get() = if (needsYou == 0) "All quiet" else "$needsYou need${if (needsYou == 1) "s" else ""} you"

    /** What the widget's first line says. Silence has to be earned: a Mac that is offline or not checking in is never "All quiet". */
    val faceHeadline: String
        get() = when (presence) {
            Presence.OFFLINE -> "Mac offline"
            Presence.STALE -> "Not checking in"
            else -> headline
        }

    /** The Mac cannot be reached right now (offline or not checking in). */
    val isUnreachable: Boolean get() = presence == Presence.OFFLINE || presence == Presence.STALE

    /** "3 working · 9 live" (whatever is known). */
    val detail: String?
        get() {
            val parts = ArrayList<String>()
            working?.let { parts.add("$it working") }
            live?.let { parts.add("$it live") }
            return if (parts.isEmpty()) null else parts.joinToString(" · ")
        }

    companion object {
        fun from(json: JsonObject, macName: String?, now: Instant, format: (Instant) -> String): WidgetStatus {
            val snap = MacStatusSnapshot.from(json)
            val presence = when (MacPresence.evaluate(snap, now)) {
                is MacPresence.Online -> Presence.ONLINE
                is MacPresence.Stale -> Presence.STALE
                is MacPresence.Offline, MacPresence.NeverConnected -> Presence.OFFLINE
                MacPresence.Unknown -> Presence.UNKNOWN
            }
            return WidgetStatus(
                macName ?: "Your Mac", presence, snap.pendingCount ?: 0, snap.working, snap.activeSessions,
                snap.batteryLine, snap.usageLine(now, format), now, snap.usage, snap,
            )
        }

        fun placeholder(now: Instant = Instant.EPOCH) = WidgetStatus("Your Mac", Presence.ONLINE, 1, 2, 5, null, null, now)
    }
}
