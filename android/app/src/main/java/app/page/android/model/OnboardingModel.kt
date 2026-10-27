package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/OnboardingModel.swift. First-run, as plain values:
// what the Welcome and Scan screens say, what the Paired screen offers, and
// the problems Page can truly detect and the one obvious fix for each ("Never
// a false 'all quiet'").

// MARK: - Welcome and Scan

object OnboardingCopy {
    const val eyebrow = "PAGE"
    const val welcomeTitle = "Keep watch over your agents."
    const val welcomeBody = "Your Mac stays awake while they work, and pages you here the moment one needs you. Everything is end-to-end encrypted."
    const val pairButton = "Pair with your Mac"

    const val scanTitle = "Scan the code on your Mac"
    const val scanHint = "Page menu → Pair phone…"
    data class Fact(val symbol: String, val text: String)
    val scanFacts: List<Fact> = listOf(
        Fact("lock", "The code holds your relay address and an encryption key"),
        Fact("checkmark.shield", "Only this phone can read your sessions"),
    )
    const val pasteInstead = "Paste a pairing link instead"

    /** The warning that stays on the confirm step: whoever runs the relay sees pages and replies. */
    const val confirmWarning = "Only pair with a code from your own Mac: whoever runs this relay sees your pages and replies."
}

// MARK: - Paired

/** What the Paired screen shows, once a Mac has been saved. */
data class PairedWelcome(
    val title: String,
    val subtitle: String,
    val promiseTitle: String,
    val promises: List<String>,
    val action: Action,
    /** A quiet second choice under the button, when notifications are still undecided. */
    val skipTitle: String?,
) {
    /**
     * What the one big button does. Asking for notifications is a choice made here, once, never an
     * unprompted system dialog.
     */
    enum class Action(val title: String) {
        ALLOW_NOTIFICATIONS("Allow notifications"),
        OPEN_SETTINGS("Open Settings"),
        CONTINUE_TO_NOW("Open Now"),
    }

    companion object {
        val promiseLines = listOf(
            "Approvals and questions — always",
            "Looks stuck, finished turns — only when you're away",
            "Never to pull you back in",
        )

        /**
         * "Your first star. 14 sessions are live right now." The count is what the Mac has reported by now; with
         * none yet the line says what happens next.
         */
        fun subtitle(liveSessions: Int?, isFirstMac: Boolean): String {
            val lead = if (isFirstMac) "Your first star. " else ""
            return when (liveSessions) {
                null -> lead + "Sessions appear as soon as your Mac reports them."
                0 -> lead + "Start an agent on your Mac and it appears here."
                1 -> lead + "1 session is live right now."
                else -> lead + "$liveSessions sessions are live right now."
            }
        }

        fun build(macName: String, liveSessions: Int?, isFirstMac: Boolean, notifications: NotificationsState): PairedWelcome {
            val action = when (notifications) {
                NotificationsState.ALLOWED -> Action.CONTINUE_TO_NOW
                NotificationsState.OFF -> Action.OPEN_SETTINGS
                NotificationsState.NOT_SET, NotificationsState.CHECKING -> Action.ALLOW_NOTIFICATIONS
            }
            return PairedWelcome(
                title = "${DeliveryPreview.macLabel(macName).replace("your Mac", "Your Mac")} is paired",
                subtitle = subtitle(liveSessions, isFirstMac),
                promiseTitle = "Only when you're needed", promises = promiseLines, action = action,
                skipTitle = if (action == Action.ALLOW_NOTIFICATIONS) "Not now" else null,
            )
        }
    }
}

// MARK: - Problem states

/**
 * A thing Page can see is wrong, as a calm full statement: a hollow pulse, a sentence that tells the truth, what
 * it means, and one obvious fix. Red is reserved for the two hold rings, so even a replaced pairing is amber.
 */
data class ProblemState(
    val kind: Kind,
    val tone: Tone,
    val title: String,
    val subtitle: String,
    val details: List<Detail>,
    val actionTitle: String,
    val action: Action,
    /** A quieter second choice, when there is one (re-pair, for a Mac that has been gone a long time). */
    val secondaryTitle: String? = null,
    val secondaryAction: Action? = null,
    /** The banner ids this replaces, so the stream does not say it twice. */
    val replacesBanners: Set<String>,
) {
    enum class Kind(val raw: String) { MAC_ASLEEP("macAsleep"), RELAY_UNREACHABLE("relayUnreachable"), PAIRING_REPLACED("pairingReplaced") }
    enum class Tone { SLATE, AMBER }

    /** What the button does. The container routes each to an existing path. */
    enum class Action {
        /** Pull the lists again. */
        RECHECK,

        /** Unpair, then scan the new code. */
        REPAIR;

        val isRepair: Boolean get() = this == REPAIR
    }

    data class Detail(val symbol: String, val text: String) {
        val id: String get() = text
    }

    val id: String get() = kind.raw

    data class Inputs(
        val macName: String,
        val presence: MacPresence,
        val authRejected: Boolean,
        /** The relay refused as "token retired". */
        val retired: Boolean = false,
        /** The inbox failed to load, with the relay's reason. */
        val inboxFailure: String?,
        val connected: Boolean,
        val relayHost: String?,
        val battery: Int?,
        val onAC: Boolean?,
        val cutoff: Int?,
        /** Sessions Page paused at the cutoff (open "paused for battery" pages). */
        val pausedSessions: Int = 0,
        /** When the lists last loaded, for "Showing what we last knew". */
        val lastKnownAt: Instant?,
        val now: Instant,
    )

    companion object {
        /**
         * The most important thing wrong, or null. A rejected or replaced pairing beats an unreachable relay,
         * which beats a quiet Mac, because each of those makes the next one meaningless. Pure.
         */
        fun build(i: Inputs): ProblemState? {
            val mac = DeliveryPreview.macLabel(i.macName)
            val macTitle = if (mac == "your Mac") "Your Mac" else mac

            if (i.authRejected || i.retired || i.presence == MacPresence.NeverConnected) {
                val replaced = i.authRejected || i.retired
                return ProblemState(
                    kind = Kind.PAIRING_REPLACED, tone = Tone.AMBER,
                    title = if (replaced) "This pairing was replaced" else "Your Mac hasn't used this pairing",
                    subtitle = if (replaced) "Your Mac made a new pairing code" else "The relay has never seen it connect",
                    details = listOf(
                        Detail("key.slash", if (replaced) "The old code can't be used again" else "A code from an old screenshot, or a regenerated token, looks like this"),
                        Detail("qrcode", "On your Mac, open Page menu → Pair phone…"),
                    ),
                    actionTitle = "Scan the new code", action = Action.REPAIR, replacesBanners = setOf("auth", "never"),
                )
            }
            if (i.inboxFailure != null && !i.connected) {
                val details = arrayListOf(Detail("wifi.slash", "Your phone may be offline"), Detail("exclamationmark.bubble", i.inboxFailure))
                i.lastKnownAt?.let {
                    details.add(Detail("tray", "Showing what we last knew, ${RelativeTime.compact(maxOf(0.0, i.now.secondsSince(it)).toLong())} ago"))
                }
                return ProblemState(
                    kind = Kind.RELAY_UNREACHABLE, tone = Tone.AMBER, title = "Can't reach your relay",
                    subtitle = (i.relayHost?.let { "$it isn't answering" } ?: "The relay isn't answering") + " · retrying",
                    details = details, actionTitle = "Try again now", action = Action.RECHECK, replacesBanners = setOf("relay"),
                )
            }
            val seen: Instant?
            val stale: Boolean
            when (val p = i.presence) {
                is MacPresence.Offline -> { seen = p.lastSeen; stale = false }
                is MacPresence.Stale -> { seen = p.lastSeen; stale = true }
                else -> return null
            }
            val details = arrayListOf(
                Detail(
                    "moon.zzz",
                    if (stale) "Pages may be late until it checks in again" else "Pages can't reach you until it wakes or Page reconnects",
                ),
            )
            val b = i.battery
            if (i.onAC == false && b != null && b > 0 && b <= (i.cutoff ?: 10) + 3) {
                details.add(Detail("battery.25", "It was at $b% — probably the cutoff"))
            }
            if (i.pausedSessions > 0) {
                details.add(Detail("clock.arrow.circlepath", "Your ${i.pausedSessions} session${if (i.pausedSessions == 1) " was" else "s were"} paused with summaries"))
            }
            // Gone a long time: a regenerated token answers exactly like an offline Mac, so offer the re-pair.
            val repair = i.presence.suggestsRepair(i.now)
            if (repair) {
                details.add(Detail("key", "If you regenerated the token on your Mac, re-pair this phone"))
            }
            val whenText = seen?.let { "Last heartbeat ${RelativeTime.compact(maxOf(0.0, i.now.secondsSince(it)).toLong())} ago" }
            return ProblemState(
                kind = Kind.MAC_ASLEEP, tone = Tone.SLATE,
                title = if (stale) "$macTitle stopped checking in" else "$macTitle is offline",
                subtitle = whenText ?: "No heartbeat on record",
                details = details, actionTitle = "Check again", action = Action.RECHECK,
                secondaryTitle = if (repair) "Re-pair…" else null, secondaryAction = if (repair) Action.REPAIR else null,
                replacesBanners = setOf("offline", "stale"),
            )
        }
    }
}
