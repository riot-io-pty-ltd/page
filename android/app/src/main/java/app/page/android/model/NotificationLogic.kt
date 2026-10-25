package app.page.android.model

// Notification actions and payloads. Pure, so the decision that gates every
// notification action (Approve/Deny only for approval kinds) is unit tested.

object NotificationActionId {
    const val APPROVE = "APPROVE"
    const val DENY = "DENY"
    const val REPLY = "REPLY"
    const val CARRY_ON = "CARRY_ON"
}

/** The relay's per-kind categories (PROTOCOL.md §11); Android maps each to its actions. */
enum class NotificationCategory {
    APPROVAL, INPUT, IDLE, INFO;

    companion object {
        /** The category the relay would pick for this page's raw wire kind. */
        fun forKind(kind: InterventionKind): NotificationCategory = when (kind) {
            InterventionKind.APPROVAL -> APPROVAL
            InterventionKind.USER_INPUT -> INPUT
            InterventionKind.IDLE -> IDLE
            InterventionKind.RATE_LIMIT -> INFO
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
         * type "yes, proceed" into a session that never asked.
         */
        fun decide(response: NotificationResponseKind, userText: String?, rawKind: String?): NotificationDecision {
            val kind = rawKind?.let(InterventionKind::fromWire)
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
                    NotificationActionId.CARRY_ON -> {
                        if (kind == InterventionKind.APPROVAL) {
                            Refuse("This session is waiting for an approval. Open Page to approve or deny it.")
                        } else {
                            Send("", ReplyAction.CARRY_ON)
                        }
                    }
                    NotificationActionId.REPLY -> {
                        val text = (userText ?: "").trim()
                        if (text.isEmpty()) Ignore else Send(text, ReplyAction.CUSTOM)
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
