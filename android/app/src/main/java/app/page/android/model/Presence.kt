package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonObject

/**
 * What the phone knows about the Mac, merged from GET /status, `mac.status`
 * frames and `heartbeat` frames. Every field is optional because old Workers
 * only ever send heartbeats.
 */
data class MacStatusSnapshot(
    val macConnected: Boolean? = null,
    val lastHeartbeatAt: Instant? = null,
    val activeSessions: Int? = null,
    val battery: Int? = null,
    val onAC: Boolean? = null,
    /**
     * v2 /status: whether any Mac has ever connected to the relay with this
     * pairing token. Absent on relays that predate it.
     */
    val macEverSeen: Boolean? = null,
    val pendingCount: Int? = null,
) {
    /**
     * A Mac has provably never used this pairing: the relay says so and has
     * no heartbeat on record. Requiring the missing heartbeat as well keeps a
     * merely sleeping Mac from being reported as "never connected".
     */
    val macNeverConnected: Boolean
        get() = macConnected == false && lastHeartbeatAt == null && macEverSeen == false

    /**
     * The pairing probe's looser check, which also covers relays that predate
     * `macEverSeen`: offline, no heartbeat ever stored, and nothing pending.
     * Typical of an old QR screenshot or a regenerated token.
     */
    val looksUnused: Boolean
        get() {
            if (macConnected != false || lastHeartbeatAt != null) return false
            macEverSeen?.let { return !it }
            return pendingCount == 0
        }

    /** Battery is only meaningful in 1..100: v2 Macs send -1 for unknown and older Macs hard-coded 0. */
    val batteryPercent: Int? get() = battery?.takeIf { it in 1..100 }

    companion object {
        fun from(json: JsonObject): MacStatusSnapshot = MacStatusSnapshot(
            macConnected = json.bool("macConnected"),
            lastHeartbeatAt = PageDate.parseAny(json["lastHeartbeatAt"]),
            activeSessions = json.num("activeSessions")?.toInt(),
            battery = json.num("battery")?.toInt(),
            onAC = json.bool("onAC"),
            macEverSeen = json.bool("macEverSeen"),
            pendingCount = json.num("pendingCount")?.toInt(),
        )
    }
}

sealed interface MacPresence {
    data object Unknown : MacPresence
    data class Online(val lastSeen: Instant?) : MacPresence

    /** The relay still has a socket but heartbeats stopped (asleep, wedged). */
    data class Stale(val lastSeen: Instant) : MacPresence
    data class Offline(val lastSeen: Instant?) : MacPresence

    /**
     * No Mac has ever connected with this pairing token: usually the Mac
     * regenerated its token, or the code came from an old screenshot.
     */
    data object NeverConnected : MacPresence

    val isReachable: Boolean get() = this is Online

    /**
     * Offline long enough (or with no heartbeat on record) that a token
     * regenerated on the Mac is a plausible cause worth offering a re-pair
     * for. The relay can't tell: an abandoned token still answers.
     */
    fun suggestsRepair(now: Instant): Boolean = when (this) {
        NeverConnected -> true
        is Offline -> lastSeen?.let { now.secondsSince(it) > REPAIR_HINT_AFTER } ?: true
        else -> false
    }

    companion object {
        /**
         * Heartbeats arrive roughly every 15 s while the Mac's relay is up;
         * several missed in a row means something is wrong.
         */
        const val STALE_AFTER: Double = 90.0
        const val REPAIR_HINT_AFTER: Double = 60 * 60.0

        fun evaluate(s: MacStatusSnapshot?, now: Instant): MacPresence {
            if (s == null) return Unknown
            val fresh: Boolean? = s.lastHeartbeatAt?.let { now.secondsSince(it) <= STALE_AFTER }
            return when (s.macConnected) {
                false -> if (s.macNeverConnected) NeverConnected else Offline(s.lastHeartbeatAt)
                true -> {
                    val seen = s.lastHeartbeatAt
                    if (fresh == false && seen != null) Stale(seen) else Online(seen)
                }
                null -> {
                    // Old Worker: heartbeats are the only signal.
                    val seen = s.lastHeartbeatAt ?: return Unknown
                    if (fresh == true) Online(seen) else Offline(seen)
                }
            }
        }
    }
}
