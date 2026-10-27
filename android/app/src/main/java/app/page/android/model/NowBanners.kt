package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/NowBanners.swift. The problems the Now stream
// surfaces above everything else, and the session-availability copy Lanes shows
// when live sessions can't load. These are the inbox banners and the Sessions
// availability cards, as pure values. Android has no push provider, so the
// push banner and the other-Macs banners (one pairing only) are not here.

/** Whether Android lets Page notify you (mapped from `NotificationAccess.Authorization`). */
enum class NotificationsState {
    ALLOWED, OFF, NOT_SET, CHECKING;

    val text: String
        get() = when (this) {
            ALLOWED -> "Allowed"
            OFF -> "Off — you won't be paged"
            NOT_SET -> "Not set up yet"
            CHECKING -> "Checking…"
        }
}

/** "Connected", "Connecting…", "Reconnecting…" or "Offline — <why>". */
object RelayConnectionText {
    fun text(connected: Boolean, connecting: Boolean, failure: String?): String {
        if (connected) return "Connected"
        if (connecting) return "Connecting…"
        if (failure != null) return "Offline — $failure"
        return "Reconnecting…"
    }
}

data class NowBanner(
    val id: String,
    val tone: Tone,
    /** A semantic icon name (the views map it to an icon). */
    val symbol: String,
    val title: String,
    val message: String,
    val actionTitle: String?,
    val action: Action?,
) {
    enum class Tone { ERROR, WARNING, INFO }

    enum class Action {
        /** Unpair, then scan a new code on the Mac. */
        REPAIR,

        /** Pull the lists again. */
        RETRY,
        OPEN_NOTIFICATION_SETTINGS,
    }

    data class Inputs(
        val authRejected: Boolean,
        /** The inbox failed to load, with the relay's reason. */
        val inboxFailure: String?,
        val connected: Boolean,
        val presence: MacPresence,
        val notifications: NotificationsState,
        val now: Instant,
    )

    companion object {
        /** Most important first. Pure. */
        fun build(i: Inputs): List<NowBanner> {
            val out = ArrayList<NowBanner>()
            if (i.authRejected) {
                out.add(
                    NowBanner(
                        "auth", Tone.ERROR, "key.slash", "This pairing no longer works",
                        "Your relay rejected this phone's pairing token. The Mac probably generated a new one. Unpair and scan the new code.",
                        "Re-pair…", Action.REPAIR,
                    ),
                )
            } else if (i.inboxFailure != null && !i.connected) {
                out.add(
                    NowBanner(
                        "relay", Tone.ERROR, "wifi.exclamationmark", "Can't reach your relay",
                        "${i.inboxFailure} The list may be out of date.", "Try again", Action.RETRY,
                    ),
                )
            } else {
                when (val p = i.presence) {
                    MacPresence.NeverConnected -> out.add(
                        NowBanner(
                            "never", Tone.ERROR, "key.slash", "Your Mac hasn't connected with this pairing",
                            "The relay has never seen Page on your Mac use this pairing code, so no pages can reach this phone. If you regenerated the token on your Mac, re-pair with the new code.",
                            "Re-pair…", Action.REPAIR,
                        ),
                    )
                    is MacPresence.Offline -> {
                        val repair = i.presence.suggestsRepair(i.now)
                        val last = p.lastSeen?.let { "Last seen ${RelativeTime.ago(it, i.now)}. " } ?: ""
                        out.add(
                            NowBanner(
                                "offline", Tone.WARNING, "desktopcomputer.trianglebadge.exclamationmark", "Your Mac is offline",
                                last + "New pages can't reach you until Page on your Mac reconnects to the relay." +
                                    (if (repair) " If you regenerated the token on your Mac, re-pair this phone." else ""),
                                if (repair) "Re-pair…" else null, if (repair) Action.REPAIR else null,
                            ),
                        )
                    }
                    is MacPresence.Stale -> out.add(
                        NowBanner(
                            "stale", Tone.WARNING, "desktopcomputer.trianglebadge.exclamationmark", "Your Mac stopped checking in",
                            "Last heartbeat ${RelativeTime.ago(p.lastSeen, i.now)}. It may be asleep or busy; pages may be delayed.",
                            null, null,
                        ),
                    )
                    else -> Unit
                }
            }
            if (i.notifications == NotificationsState.OFF) {
                out.add(
                    NowBanner(
                        "notifications", Tone.WARNING, "bell.slash", "Notifications are off",
                        "You won't be paged while Page is closed.", "Open Settings", Action.OPEN_NOTIFICATION_SETTINGS,
                    ),
                )
            }
            return out
        }
    }
}

/** What Lanes says when live sessions can't load, and the step that fixes it. */
data class SessionAvailabilityCopy(
    val systemImage: String,
    val tone: Tone,
    val title: String,
    val message: String,
    val actionTitle: String?,
    val action: Action?,
    /** For the status line. */
    val shortStatus: String,
) {
    enum class Action { REPAIR, RETRY }
    enum class Tone { WARNING, ERROR, INFO }

    companion object {
        fun of(availability: SessionAvailability): SessionAvailabilityCopy = when (availability) {
            SessionAvailability.RelayTooOld -> SessionAvailabilityCopy(
                "arrow.triangle.2.circlepath", Tone.WARNING, "Update your relay",
                "Your relay (the Cloudflare Worker) doesn't support live sessions yet. Redeploy it from the latest Page release, then pull down to refresh. Pages keep working meanwhile.",
                "Check again", Action.RETRY, "Relay needs an update",
            )
            is SessionAvailability.NeedsRepair ->
                if (availability.keyMismatch) SessionAvailabilityCopy(
                    "key.slash", Tone.ERROR, "Re-pair with your Mac",
                    "Live updates from your Mac can't be unlocked with this phone's key, so the pairing was probably regenerated on the Mac. Unpair, then on your Mac open Page → Pair phone… and scan the code.",
                    "Re-pair…", Action.REPAIR, "Pairing key changed",
                ) else SessionAvailabilityCopy(
                    "key", Tone.WARNING, "Re-pair with your Mac to see live sessions",
                    "This pairing has no session key: it came from an older Page on your Mac, or was made before live sessions existed. Update Page on your Mac, unpair here, then open Page → Pair phone… on the Mac and scan the new code. Pages keep working meanwhile.",
                    "Re-pair…", Action.REPAIR, "Re-pair needed",
                )
            SessionAvailability.MacOffline -> SessionAvailabilityCopy(
                "desktopcomputer.trianglebadge.exclamationmark", Tone.WARNING, "Your Mac is offline",
                "Live sessions show up while Page on your Mac is connected to the relay. Wake the Mac, or check that Page is running there.",
                "Try again", Action.RETRY, "Mac offline",
            )
            SessionAvailability.ClockSkew -> SessionAvailabilityCopy(
                "clock.badge.exclamationmark", Tone.WARNING, "Your clocks disagree",
                "Updates from your Mac arrive more than 10 minutes old by this phone's clock, so they're ignored. Turn on automatic date and time on both your phone and your Mac.",
                "Try again", Action.RETRY, "Clock mismatch",
            )
            SessionAvailability.MacTooOld -> SessionAvailabilityCopy(
                "arrow.down.app", Tone.WARNING, "Update Page on your Mac",
                "Your Mac is online but isn't sending live sessions. Update Page on your Mac to the latest version, and check that remote sessions are turned on in its Preferences.",
                "Check again", Action.RETRY, "Mac needs an update",
            )
            SessionAvailability.MacDisabled -> SessionAvailabilityCopy(
                "eye.slash", Tone.WARNING, "Live sessions are off on your Mac",
                "Page on your Mac isn't sharing its sessions. Turn them back on in Page → Preferences → Phone on the Mac.",
                "Check again", Action.RETRY, "Off on your Mac",
            )
            SessionAvailability.Waiting -> SessionAvailabilityCopy("hourglass", Tone.INFO, "Connecting to your Mac…", "", null, null, "Connecting…")
            SessionAvailability.Ready -> SessionAvailabilityCopy("checkmark.circle", Tone.INFO, "Live", "", null, null, "Live")
        }
    }
}
