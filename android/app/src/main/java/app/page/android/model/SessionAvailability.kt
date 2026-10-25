package app.page.android.model

import java.time.Instant

/**
 * What the Sessions screen can show right now (§6), most fundamental problem
 * first, so the copy always names the step that unblocks the user.
 */
sealed interface SessionAvailability {
    /** The relay's /status has no `sessions-v1`: update the Worker. */
    data object RelayTooOld : SessionAvailability

    /**
     * No session key from pairing (older Mac, or paired before this shipped).
     * [keyMismatch]: frames arrive but don't decrypt, so the Mac's key changed.
     */
    data class NeedsRepair(val keyMismatch: Boolean) : SessionAvailability
    data object MacOffline : SessionAvailability

    /** Frames decrypt but are all over 10 minutes old by this phone's clock. */
    data object ClockSkew : SessionAvailability

    /** Connected; the first list should be along any second. */
    data object Waiting : SessionAvailability

    /** The Mac is online but sent no list within 5 s: it predates live sessions. */
    data object MacTooOld : SessionAvailability

    /** The Mac says live sessions are turned off in its settings. */
    data object MacDisabled : SessionAvailability
    data object Ready : SessionAvailability

    data class Inputs(
        val hasKey: Boolean,
        /** From GET /status; null until known. A relay without /status has none. */
        val relayFeatures: Set<String>?,
        val presence: MacPresence,
        /** The relay just answered 503 `mac_offline`. */
        val macOfflineHint: Boolean = false,
        val socketConnected: Boolean,
        /** When the socket opened or the Mac came online, whichever is later. */
        val waitStartedAt: Instant?,
        val hasList: Boolean,
        /** Undecryptable frames arrived after the last good one. */
        val keyMismatch: Boolean = false,
        /** Decrypted frames were dropped as too old, and none were applied. */
        val onlyStaleFrames: Boolean = false,
        /** The last list said live sessions are turned off on the Mac. */
        val macDisabled: Boolean = false,
    )

    companion object {
        const val FEATURE = "sessions-v1"
        const val LIST_WAIT: Double = 5.0

        fun evaluate(i: Inputs, now: Instant): SessionAvailability {
            if (i.relayFeatures != null && FEATURE !in i.relayFeatures) return RelayTooOld
            if (!i.hasKey) return NeedsRepair(keyMismatch = false)
            if (i.keyMismatch) return NeedsRepair(keyMismatch = true)
            when (i.presence) {
                is MacPresence.Offline, MacPresence.NeverConnected, is MacPresence.Stale -> return MacOffline
                else -> Unit
            }
            if (i.macOfflineHint) return MacOffline
            if (i.hasList) return if (i.macDisabled) MacDisabled else Ready
            if (i.onlyStaleFrames) return ClockSkew
            val start = i.waitStartedAt
            if (!i.socketConnected || start == null || now.secondsSince(start) < LIST_WAIT) return Waiting
            // Only an online Mac's silence says "too old"; while presence is
            // still unknown, keep waiting.
            return if (i.presence.isReachable) MacTooOld else Waiting
        }
    }
}
