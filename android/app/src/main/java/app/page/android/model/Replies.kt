package app.page.android.model

import java.time.Instant

// Replies to a page: what the phone sends, what the relay answered, and where
// the reply stands. Ported from iOS PageLogic.swift; every rule here is a
// safety rule (never make the Mac guess, never undo newer news).

/** What the phone can send to POST /reply/:id. [wire] is the wire vocab. */
enum class ReplyAction(val wire: String) {
    APPROVE("approve"),
    DENY("deny"),
    CARRY_ON("carry_on"),
    CUSTOM("custom"),
}

sealed interface ReplyOutcome {
    /** 200: the Worker stored it and forwarded (or queued) it for the Mac. */
    data class Accepted(val queued: Boolean) : ReplyOutcome

    /**
     * 409: something already answered this page (e.g. a notification action)
     * and the Mac confirmed it, or the relay is too old to say.
     */
    data object AlreadyReplied : ReplyOutcome

    /**
     * 409 while an earlier reply is still on its way: the Worker has
     * forwarded or queued it but the Mac hasn't confirmed it yet
     * (`deliveryStatus: "pending"`). Nothing new was sent, and nothing is
     * known to have been delivered either, so this must not read as "done".
     */
    data object InFlight : ReplyOutcome

    /** 404/410: the page is gone (resolved, superseded or expired). */
    data object Gone : ReplyOutcome

    /** 401/403: the relay rejected our token. */
    data object Unauthorized : ReplyOutcome

    /** 410 `token_retired`: the Mac replaced this pairing; re-pair. */
    data class Retired(val why: String) : ReplyOutcome

    /** Transport error, 5xx, or a client-side refusal; the message is shown. */
    data class Failed(val message: String) : ReplyOutcome

    companion object {
        /** Fallback for a 422 `approve_or_deny_only` without a `why`. */
        const val DECISIONS_ONLY_MESSAGE =
            "This page comes from an older Page hook that can only apply Approve or Deny. Use one of those, or update the hook in Page → Phone approvals on your Mac."

        fun from(status: Int, body: String): ReplyOutcome {
            // Before the 410 arm below: a retired token also answers 410.
            TokenRetirement.why(status, body)?.let { return Retired(it) }
            val json = parseJsonObject(body)
            return when (status) {
                in 200..299 -> Accepted(queued = json?.bool("queued") ?: false)
                409 -> {
                    if (json?.str("error") == "reply_in_flight" || json?.str("deliveryStatus") == "pending") {
                        InFlight
                    } else {
                        AlreadyReplied
                    }
                }
                404, 410 -> Gone
                401, 403 -> Unauthorized
                422 -> {
                    // The relay explains what it can't do (e.g. a v1 blocking
                    // hook that only applies Approve/Deny); show that, not the code.
                    val why = json?.str("why")?.trim()
                    val error = json?.str("error")
                    when {
                        !why.isNullOrEmpty() -> Failed(why)
                        error == "approve_or_deny_only" -> Failed(DECISIONS_ONLY_MESSAGE)
                        error != null -> Failed("The relay refused the reply ($error).")
                        else -> Failed("The relay returned an error (HTTP 422).")
                    }
                }
                else -> {
                    val error = json?.str("error")
                    if (error != null) Failed("The relay refused the reply ($error).")
                    else Failed("The relay returned an error (HTTP $status).")
                }
            }
        }

        /**
         * A reply that would make the Mac guess (empty text with no explicit
         * action used to become "carry on"). Never send these.
         */
        fun validate(text: String, action: ReplyAction): String? {
            if (action == ReplyAction.CUSTOM && text.isBlank()) return "Type a reply first."
            return null
        }
    }
}

/** Where a reply to one intervention stands, as far as the phone knows. */
sealed interface ReplyDelivery {
    data object Sending : ReplyDelivery

    /** The Worker accepted it at [at]; [queued] means the Mac was offline. */
    data class Sent(val queued: Boolean, val at: Instant) : ReplyDelivery

    /** The Mac reported success (`reply.result`), or closed the page as "replied". */
    data class Delivered(val detail: String?) : ReplyDelivery

    /**
     * Transport/HTTP failure or the Mac reported a failed injection. The page
     * is still open, so the user can retry.
     */
    data class Failed(val message: String) : ReplyDelivery

    data object AlreadyReplied : ReplyDelivery
    data object Gone : ReplyDelivery

    companion object {
        /**
         * State after the relay accepted our POST. Only a send still in
         * progress becomes Sent: a `reply.result` that beat the HTTP response
         * (delivered *or* failed) is newer news and is kept.
         */
        fun afterAccepted(current: ReplyDelivery?, queued: Boolean, at: Instant): ReplyDelivery = when (current) {
            null, Sending -> Sent(queued, at)
            else -> current
        }

        /**
         * Folds the Worker's view of a reply (v2 `deliveryStatus`, or v1
         * `repliedAt`) into local state. The caller must skip ids whose local
         * state changed after the fetch started, so a stale list can't undo a
         * newer local event.
         */
        fun synced(
            local: ReplyDelivery?,
            deliveryStatus: String?,
            deliveryDetail: String?,
            repliedAt: Instant?,
            now: Instant,
        ): ReplyDelivery? = when (deliveryStatus) {
            "failed" -> if (local == Sending) local else Failed(deliveryDetail ?: "Your Mac couldn't deliver the reply.")
            "delivered" -> Delivered(deliveryDetail)
            "pending" -> when (local) {
                // The Worker clears repliedAt when a delivery fails, so
                // "pending" means a reply newer than any local failure exists
                // (a retry from another device, or a POST whose response we
                // lost). A local "already answered" is likewise just a reply in
                // flight, and must not stay terminal on a page that's still open.
                null, is Failed, AlreadyReplied -> Sent(queued = false, at = repliedAt ?: now)
                else -> local
            }
            else -> if (local == null && repliedAt != null) Sent(queued = false, at = repliedAt) else local
        }
    }
}

/** When a reply the relay accepted but the Mac never confirmed may be answered again. */
object ReplyConfirmation {
    /**
     * The Worker's DELIVERY_ACK_TIMEOUT_MS (Cloudflare/src/logic.ts): a reply
     * it forwarded stays "taken" — a second answer gets 409 — until the Mac
     * reports a result or this much time passes.
     */
    const val WORKER_ACK_TIMEOUT: Double = 20 * 60.0

    /**
     * Relays that predate delivery reporting (no /status, no
     * `deliveryStatus`) never report failures and have no ack window, so
     * input re-opens after a minute rather than leaving the page stuck.
     */
    const val LEGACY_TIMEOUT: Double = 60.0

    /** After this long without confirmation the "waiting" copy explains that a retry opens up later. */
    const val SLOW_AFTER: Double = 60.0

    fun timeout(legacyRelay: Boolean): Double = if (legacyRelay) LEGACY_TIMEOUT else WORKER_ACK_TIMEOUT

    /**
     * Queued replies (Mac offline) are never "unconfirmed": the Worker fails
     * them itself when its queue TTL runs out.
     */
    fun isUnconfirmed(sentAt: Instant, queued: Boolean, now: Instant, legacyRelay: Boolean): Boolean =
        !queued && now.secondsSince(sentAt) > timeout(legacyRelay)
}

/** What a reply screen shows once its page has closed. */
sealed interface ClosedReplyPhase {
    data object Delivered : ClosedReplyPhase
    data class Resolved(val why: String) : ClosedReplyPhase

    /**
     * The close arrived without a reason (the close happened while the socket
     * was down) and we had sent a reply: look the archived record up before
     * claiming the Mac resolved it some other way.
     */
    data object Checking : ClosedReplyPhase

    companion object {
        fun decide(reason: String?, hadOwnReply: Boolean, lookupFinished: Boolean): ClosedReplyPhase {
            if (reason == "replied") return Delivered
            if (reason == null && hadOwnReply && !lookupFinished) return Checking
            return Resolved(CloseReason.description(reason) + ".")
        }
    }
}
