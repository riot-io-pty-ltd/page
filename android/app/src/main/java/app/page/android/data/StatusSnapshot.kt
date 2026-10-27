package app.page.android.data

import app.page.android.model.MacPresence
import app.page.android.model.MacStatusSnapshot
import app.page.android.model.RunwayMarker
import app.page.android.model.RunwayModel
import java.time.Instant
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * What the home-screen widget and the Quick Settings tile show: counts, the one honest sentence, the Mac's name
 * and the runway's markers. Nothing secret and nothing about any project: no project names, no commands, no
 * page text, so a locked phone's home screen never says what an agent is doing. The app keeps it up to date
 * ([NowStore]) and the 15-minute check refreshes it while the app is closed, so a widget can lag the app by that
 * long and no more. (The Android side of iOS SharedWidgetStore's status.)
 */
@Serializable
data class StatusSnapshot(
    val macName: String,
    /** online, stale, offline or unknown. */
    val presence: String,
    val needsYou: Int,
    val working: Int? = null,
    val live: Int? = null,
    val headline: String,
    val subline: String = "",
    val markers: List<Marker> = emptyList(),
    val onAC: Boolean? = null,
    val battery: Int? = null,
    /** 0..100, when usage tracking is on. */
    val fiveHourPct: Double? = null,
    val sevenDayPct: Double? = null,
    val atMillis: Long,
) {
    @Serializable
    data class Marker(val fraction: Double, val tone: String)

    val isUnreachable: Boolean get() = presence == "offline" || presence == "stale"

    /** What the first line says. Silence has to be earned: a Mac that is offline or not checking in is never "All quiet". */
    val faceHeadline: String
        get() = when (presence) {
            "offline" -> "Mac offline"
            "stale" -> "Not checking in"
            else -> headline
        }

    /** "3 working · 9 live". */
    val detail: String?
        get() = listOfNotNull(working?.let { "$it working" }, live?.let { "$it live" }).takeIf { it.isNotEmpty() }?.joinToString(" · ")

    fun runwayMarkers(): List<RunwayMarker.Tone> = markers.map { RunwayMarker.Tone.entries.firstOrNull { t -> t.raw == it.tone } ?: RunwayMarker.Tone.GREEN }

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun of(
            macName: String, status: MacStatusSnapshot?, needsYou: Int, working: Int?, headline: String, subline: String, runway: RunwayModel, now: Instant,
        ): StatusSnapshot {
            val presence = when (MacPresence.evaluate(status, now)) {
                is MacPresence.Online -> "online"
                is MacPresence.Stale -> "stale"
                is MacPresence.Offline, MacPresence.NeverConnected -> "offline"
                MacPresence.Unknown -> "unknown"
            }
            return StatusSnapshot(
                macName = macName.ifBlank { "Your Mac" }, presence = presence, needsYou = needsYou, working = working, live = status?.activeSessions,
                headline = headline, subline = subline, markers = runway.markers.map { Marker(it.fraction, it.tone.raw) },
                onAC = status?.onAC, battery = status?.batteryPercent, fiveHourPct = status?.usage?.fiveHour?.pct, sevenDayPct = status?.usage?.sevenDay?.pct,
                atMillis = now.toEpochMilli(),
            )
        }

        fun decode(text: String?): StatusSnapshot? = text?.let { runCatching { json.decodeFromString<StatusSnapshot>(it) }.getOrNull() }
        fun encode(s: StatusSnapshot): String = json.encodeToString(s)
    }
}

/** Keeps the [StatusSnapshot] in the app's preferences and tells the widget and the tile when it changes. */
object StatusSnapshotStore {
    private const val KEY = "page.statusSnapshot"
    private var lastPushAt = 0L

    fun read(): StatusSnapshot? = StatusSnapshot.decode(AppGraph.prefs.string(KEY))

    fun clear() {
        AppGraph.prefs.putString(KEY, null)
        notifySurfaces(force = true)
    }

    /** Stores [s] and refreshes the widget and tile, at most every 20 s unless it changed what they say. */
    fun write(s: StatusSnapshot) {
        val old = read()
        val same = old != null && old.copy(atMillis = 0) == s.copy(atMillis = 0)
        if (same && s.atMillis - old.atMillis < 10 * 60_000) return
        AppGraph.prefs.putString(KEY, StatusSnapshot.encode(s))
        notifySurfaces(force = !same)
    }

    private fun notifySurfaces(force: Boolean) {
        val now = System.currentTimeMillis()
        if (!force && now - lastPushAt < 20_000) return
        lastPushAt = now
        app.page.android.widget.PageSurfaces.refresh(AppGraph.app)
    }
}
