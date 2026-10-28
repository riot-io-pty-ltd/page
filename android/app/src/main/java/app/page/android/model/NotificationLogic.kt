package app.page.android.model

// Notification actions and payloads. Pure, so the decision that gates every
// notification action (Approve/Deny only for approval kinds) is unit tested.

object NotificationActionId {
    const val APPROVE = "APPROVE"
    const val DENY = "DENY"
    const val REPLY = "REPLY"
    const val CARRY_ON = "CARRY_ON"

    /** v4 "looks stuck" pages: Stop it (sent as deny; the Mac presses Esc). */
    const val STOP = "STOP"

    /** Takes back a reply that is queued and not yet sent (the "Sending…" or "Queued — your Mac is offline" notification). */
    const val DELETE = "DELETE"
}

/**
 * What a page notification says while a reply from it is on its way, and after a delete: the copy and whether the
 * page's own actions come back. Pure, so every outcome of a delete reads the same here as in the app. Delete is
 * offered only on "Sending your reply…" (where it stops the send if it hasn't started) and on the queued line (where
 * it asks the relay to take the reply back); never on anything the relay couldn't take back.
 */
object QueuedReplyNotification {
    const val SENDING = "Sending your reply…"
    const val QUEUED = "Queued — your Mac is offline. It'll be typed in when it reconnects."
    const val DELETING = "Deleting…"
    const val NOT_SENT = "Deleted — not sent"

    /**
     * [status] replaces the page's actions with a line (null: the page's actions are back, with [note] as the line);
     * [deleteAgain] keeps a Delete on it (a delete that never reached the relay can be tried again).
     */
    data class Plan(val status: String?, val note: String?, val deleteAgain: Boolean = false)

    fun after(outcome: ReplyRetract.Outcome): Plan = when (outcome) {
        // "Deleted — not sent", or the Mac's longer sentence when it took the reply back after the relay's "forwarded".
        is ReplyRetract.Outcome.Deleted -> Plan(null, outcome.text)
        ReplyRetract.Outcome.NothingToDelete -> Plan(null, outcome.text)
        is ReplyRetract.Outcome.Failed -> Plan(outcome.text, null, deleteAgain = true)
        // The rest are final: the page closed, or the relay said it can't be taken back, in its own words.
        else -> Plan(outcome.text, null)
    }

    /**
     * A Delete pressed while the reply's POST was already on its way couldn't call it back; once the relay has answered
     * the POST, this says what the notification becomes. null: the relay holds the reply and can take it back, so ask
     * it ([ReplyRetract]). Otherwise the notification says why nothing was deleted: the Mac already has it (the relay
     * forwarded it at once), or the relay is too old to delete queued replies, or a hook polls the page. [queued] is the
     * relay's own answer to the POST. Pure.
     */
    fun afterDeleteDuringSend(queued: Boolean, relayFeatures: Set<String>?, hookBlocking: Boolean): Plan? = when {
        !queued -> after(ReplyRetract.Outcome.TooLate(ReplyRetract.FORWARDED))
        offersDelete(true, relayFeatures, hookBlocking) -> null
        hookBlocking -> after(ReplyRetract.Outcome.HookHeld)
        else -> after(ReplyRetract.Outcome.RelayTooOld)
    }

    /** Delete is on the queued line only when the relay says it can take it back (and no hook polls the page). */
    fun offersDelete(queued: Boolean, relayFeatures: Set<String>?, hookBlocking: Boolean): Boolean =
        queued && !hookBlocking && ReplyRetract.available(relayFeatures)
}

/**
 * Which actions a page notification offers. The relay's per-kind categories
 * (PROTOCOL.md §11), refined by the v4 subtypes: a stuck session gets Stop it
 * and a reply but never Carry on, a plain rate limit takes a reply to send
 * when it resets, and forecasts take nothing.
 */
enum class NotificationCategory {
    APPROVAL, INPUT, IDLE, STUCK, STALLED, LIMIT, INFO;

    companion object {
        fun forPage(kind: InterventionKind, subtype: String?): NotificationCategory = when {
            kind == InterventionKind.APPROVAL -> APPROVAL
            kind == InterventionKind.USER_INPUT -> INPUT
            PageSubtype.canStop(kind, subtype) -> STUCK
            PageSubtype.isStuck(kind, subtype) -> STALLED
            kind == InterventionKind.IDLE -> IDLE
            PageSubtype.isForecast(kind, subtype) -> INFO
            else -> LIMIT
        }
    }
}

/** How a notification response was triggered, already mapped by the caller. */
sealed interface NotificationResponseKind {
    /** Tap on the notification body. */
    data object Open : NotificationResponseKind
    data object Dismiss : NotificationResponseKind
    data class Action(val id: String) : NotificationResponseKind
}

sealed interface NotificationDecision {
    /** Open the app on this intervention. Never sends anything. */
    data object Open : NotificationDecision
    data object Ignore : NotificationDecision
    data class Send(val text: String, val action: ReplyAction) : NotificationDecision

    /** The action doesn't make sense for this page; tell the user why. */
    data class Refuse(val why: String) : NotificationDecision

    companion object {
        /**
         * [rawKind] is the raw wire kind carried with the notification (may
         * be null for payloads from very old relays). Approve/Deny are only
         * honoured for approval kinds, so a stale action on an idle page can't
         * type "yes, proceed" into a session that never asked. [subtype]
         * refines the v4 pages: Stop only for a stuck session, no Carry on for
         * one, and nothing at all for a forecast.
         *
         * [approveLevel] is how reversible the page's action is, as the phone classifies it, or null when the
         * page is not in the inbox (a cold start, another Mac). Approve is sent from a notification only for
         * UNDOABLE: a Considered action is a tap and an Irreversible one is a hold plus biometrics, neither of
         * which a notification can offer, so those open the app on the Decision sheet instead. Deny and replies
         * are safe from a notification. (iOS NotificationDecision.decide, `approveLevel`.)
         */
        fun decide(
            response: NotificationResponseKind, userText: String?, rawKind: String?, subtype: String? = null,
            approveLevel: Reversibility? = null,
        ): NotificationDecision {
            val kind = rawKind?.let(InterventionKind::fromWire)
            val forecast = kind != null && PageSubtype.isForecast(kind, subtype)
            return when (response) {
                NotificationResponseKind.Open -> Open
                NotificationResponseKind.Dismiss -> Ignore
                is NotificationResponseKind.Action -> when (response.id) {
                    NotificationActionId.APPROVE, NotificationActionId.DENY -> {
                        if (kind != null && kind != InterventionKind.APPROVAL) {
                            Refuse("Approve and Deny only apply to approval requests. Open Page to answer this one.")
                        } else if (response.id == NotificationActionId.APPROVE && approveLevel != Reversibility.UNDOABLE) {
                            Open
                        } else {
                            Send("", if (response.id == NotificationActionId.APPROVE) ReplyAction.APPROVE else ReplyAction.DENY)
                        }
                    }
                    NotificationActionId.STOP -> {
                        if (kind != null && PageSubtype.canStop(kind, subtype)) {
                            Send("", ReplyAction.DENY)
                        } else {
                            Refuse("Stop only applies to a session that looks stuck. Open Page to answer this one.")
                        }
                    }
                    NotificationActionId.CARRY_ON -> when {
                        kind == InterventionKind.APPROVAL ->
                            Refuse("This session is waiting for an approval. Open Page to approve or deny it.")
                        kind != null && PageSubtype.isStuck(kind, subtype) ->
                            Refuse("This session looks stuck, so carrying on won't help. Open Page to tell it what to do.")
                        forecast -> Refuse("Nothing to answer: this is a heads-up from your Mac.")
                        else -> Send("", ReplyAction.CARRY_ON)
                    }
                    NotificationActionId.REPLY -> {
                        val text = (userText ?: "").trim()
                        when {
                            text.isEmpty() -> Ignore
                            forecast -> Refuse("Nothing to answer: this is a heads-up from your Mac.")
                            else -> Send(text, ReplyAction.CUSTOM)
                        }
                    }
                    else -> Ignore
                }
            }
        }
    }
}

/**
 * Keys of the relay's push payloads (PROTOCOL.md §11). Android has no push
 * provider yet; these are read by whichever provider is added later, and by
 * the tests that pin the payload contract.
 */
object PushPayload {
    /**
     * Every page id a push says is closed: the v2 `interventionClosedIds`
     * array plus the v1 `interventionClosedId`. Never includes the push's
     * own `interventionId`, so an alert can't close the page it announces.
     */
    fun closedIds(userInfo: Map<String, Any?>): Set<String> {
        val ids = mutableSetOf<String>()
        (userInfo["interventionClosedIds"] as? List<*>)?.forEach { id ->
            if (id is String && id.isNotEmpty() && id.length <= 200) ids.add(id)
        }
        (userInfo["interventionClosedId"] as? String)?.let { if (it.isNotEmpty() && it.length <= 200) ids.add(it) }
        (userInfo["interventionId"] as? String)?.let { ids.remove(it) }
        return ids
    }

    /**
     * The project a push is about, for local notices. Prefers the
     * `projectName` key; older Workers only put it in the title ("<project>
     * paged you", "Reply to <project> not delivered"). Anything else yields
     * "" so callers say "your Mac" instead of quoting a title.
     */
    fun projectName(userInfo: Map<String, Any?>, title: String): String {
        (userInfo["projectName"] as? String)?.trim()?.let { if (it.isNotEmpty()) return it }
        val pagedSuffix = " paged you"
        if (title.endsWith(pagedSuffix)) return title.dropLast(pagedSuffix.length).trim()
        val failedPrefix = "Reply to "
        val failedSuffix = " not delivered"
        if (title.startsWith(failedPrefix) && title.endsWith(failedSuffix) &&
            title.length > failedPrefix.length + failedSuffix.length
        ) {
            return title.drop(failedPrefix.length).dropLast(failedSuffix.length).trim()
        }
        return ""
    }
}
