package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// v4 heartbeat (and GET /status) extras: the battery's time to the cutoff and
// Claude subscription usage (PROTOCOL.md §5). Each is validated on its own
// and a malformed one is dropped, like the Worker does.

/** Time to the Mac's low-battery cutoff at the current drain (sent on battery only). */
data class BatteryForecast(val cutoff: Int, val minutes: Int, val drainPerHour: Double) {
    companion object {
        fun from(element: JsonElement?): BatteryForecast? {
            val o = element as? JsonObject ?: return null
            val cutoff = o.num("cutoff") ?: return null
            val minutes = o.num("minutes") ?: return null
            val drain = o.num("drainPerHour") ?: return null
            return BatteryForecast(
                cutoff.coerceIn(0.0, 100.0).toInt(),
                minutes.coerceIn(0.0, 7 * 24 * 60.0).toInt(),
                drain.coerceIn(0.0, 1000.0),
            )
        }
    }
}

data class UsageWindow(val pct: Double, val resetsAt: Instant?) {
    companion object {
        fun from(element: JsonElement?): UsageWindow? {
            val o = element as? JsonObject ?: return null
            val pct = o.num("pct") ?: return null
            return UsageWindow(pct.coerceIn(0.0, 100.0), o.str("resetsAt")?.let(PageDate::parse))
        }
    }
}

/** Claude usage the Mac read, with `hitAt` the forecast time the 5-hour limit is reached. */
data class ClaudeUsage(val fiveHour: UsageWindow?, val sevenDay: UsageWindow?, val hitAt: Instant?, val updatedAt: Instant?) {
    companion object {
        fun from(element: JsonElement?): ClaudeUsage? {
            val o = element as? JsonObject ?: return null
            val five = UsageWindow.from(o["fiveHour"])
            val seven = UsageWindow.from(o["sevenDay"])
            if (five == null && seven == null) return null
            return ClaudeUsage(five, seven, o.str("hitAt")?.let(PageDate::parse), o.str("updatedAt")?.let(PageDate::parse))
        }
    }
}

/**
 * The compact Mac status strip at the top of Sessions: presence, the battery
 * forecast and Claude usage, one short line each. Pure; [clock] formats a
 * time of day in the phone's locale ("5:00 PM").
 */
object MacStatusStrip {
    data class Line(val kind: Kind, val text: String)

    enum class Kind { PRESENCE, BATTERY, USAGE }

    fun lines(snapshot: MacStatusSnapshot?, presence: MacPresence, now: Instant, clock: (Instant) -> String): List<Line> {
        val out = mutableListOf<Line>()
        out.add(Line(Kind.PRESENCE, presenceText(presence, snapshot, now)))
        if (!presence.isReachable || snapshot == null) return out
        val forecast = snapshot.forecast
        // A forecast only means something on battery.
        if (forecast != null && snapshot.onAC != true) {
            val battery = snapshot.batteryPercent?.let { "Battery $it% · " } ?: ""
            out.add(Line(Kind.BATTERY, "${battery}cutoff in ~${duration(forecast.minutes)}"))
        }
        snapshot.usage?.let { usage ->
            val window = usage.fiveHour?.let { "5-hour" to it } ?: usage.sevenDay?.let { "7-day" to it }
            if (window != null) {
                var text = "Claude ${window.first} ${window.second.pct.toInt()}%"
                window.second.resetsAt?.let { text += " · resets ${clock(it)}" }
                usage.hitAt?.let { text += " · limit ~${clock(it)}" }
                out.add(Line(Kind.USAGE, text))
            }
        }
        return out
    }

    private fun presenceText(presence: MacPresence, snapshot: MacStatusSnapshot?, now: Instant): String = when (presence) {
        is MacPresence.Online -> {
            val working = snapshot?.working
            if (working != null && working > 0) "Mac online · $working working" else "Mac online"
        }
        is MacPresence.Stale -> "Mac not responding · last heartbeat ${RelativeTime.ago(presence.lastSeen, now)}"
        is MacPresence.Offline -> presence.lastSeen?.let { "Mac offline · last seen ${RelativeTime.ago(it, now)}" } ?: "Mac offline"
        MacPresence.NeverConnected -> "Mac never connected with this pairing"
        MacPresence.Unknown -> "Checking your Mac…"
    }

    /** "35 min", "1 h 20 min". */
    fun duration(minutes: Int): String {
        val m = maxOf(0, minutes)
        return if (m < 60) "$m min" else if (m % 60 == 0) "${m / 60} h" else "${m / 60} h ${m % 60} min"
    }
}
