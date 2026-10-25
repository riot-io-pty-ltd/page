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
         */
        fun decide(response: NotificationResponseKind, userText: String?, rawKind: String?, subtype: String? = null): NotificationDecision {
            val kind = rawKind?.let(InterventionKind::fromWire)
            val forecast = kind != null && PageSubtype.isForecast(kind, subtype)
            return when (response) {
                NotificationResponseKind.Open -> Open
                NotificationResponseKind.Dismiss -> Ignore
                is NotificationResponseKind.Action -> when (response.id) {
                    NotificationActionId.APPROVE, NotificationActionId.DENY -> {
                        if (kind != null && kind != InterventionKind.APPROVAL) {
                            Refuse("Approve and Deny only apply to approval requests. Open Page to answer this one.")
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
