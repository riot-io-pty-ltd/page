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

    /** A delete (`DELETE /reply/:id`, or the Mac's `retract`) is waiting for its answer. */
    data object Retracting : ReplyDelivery

    /** Deleted before anything was typed (method `retracted`): the page accepts a fresh reply. [detail] is the sentence the relay or Mac gave. */
    data class Retracted(val detail: String?) : ReplyDelivery

    /**
     * The Mac took it and holds it until a rate limit resets (`reply.injected` method `held_until_reset`): not
     * delivered, and not lost. [detail] is the Mac's sentence ("Will send it when the limit resets at 3:00 PM").
     */
    data class HeldOnMac(val detail: String?) : ReplyDelivery {
        /** "3:00 PM", read from the Mac's sentence; null when it names no time. */
        val until: String? get() = HeldUntilReset.until(detail)
    }

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
            /** `deliveryMethod`: "retracted" (deleted), "held_until_reset" (the Mac holds it for a rate limit). */
            deliveryMethod: String? = null,
            /** `deliveryForwardedAt`: the relay handed it to a Mac socket. */
            forwardedAt: Instant? = null,
            /** A blocking hook polls this page's reply itself; the relay never queues it. */
            hookBlocking: Boolean = false,
        ): ReplyDelivery? {
            // Waiting at the relay for an offline Mac: pending, never handed to a Mac socket, and not a hook's page
            // (a hook's reply is also pending with no forward, but nothing was queued).
            val queued = forwardedAt == null && !hookBlocking
            return when (deliveryStatus) {
                // Deleted (by this phone or another): nothing was sent, a fresh reply is welcome. Never a failure.
                "failed" -> when {
                    // A send or a delete still under way is newer than the record (iOS checks `.sending` first too).
                    local == Sending || local == Retracting -> local
                    deliveryMethod == ReplyResultFrame.RETRACTED -> Retracted(deliveryDetail ?: HeldMessages.DELETED_COPY)
                    else -> Failed(deliveryDetail ?: "Your Mac couldn't deliver the reply.")
                }
                // Held on the Mac until the limit resets: it is not typed yet, so it is not a delivery.
                "delivered" -> if (deliveryMethod == ReplyResultFrame.HELD_UNTIL_RESET) HeldOnMac(deliveryDetail) else Delivered(deliveryDetail)
                "pending" -> when (local) {
                    // The Worker clears repliedAt when a delivery fails, so
                    // "pending" means a reply newer than any local failure exists
                    // (a retry from another device, or a POST whose response we
                    // lost). A local "already answered" is likewise just a reply in
                    // flight, and must not stay terminal on a page that's still open.
                    null, is Failed, AlreadyReplied, is Retracted -> Sent(queued = queued, at = repliedAt ?: now)
                    // Queued or forwarded, whichever the relay says now: the queue flushing takes Delete away.
                    is Sent -> if (local.queued == queued) local else local.copy(queued = queued)
                    else -> local
                }
                else -> if (local == null && repliedAt != null) Sent(queued = false, at = repliedAt) else local
            }
        }

        /**
         * Where a delete leaves a reply, and the note to show. [prev] is where it stood before the delete began (the
         * state is restored when the relay says it could not be taken back, so a queued reply stays queued).
         * Pure.
         */
        fun afterRetract(prev: ReplyDelivery?, outcome: ReplyRetract.Outcome, now: Instant): Pair<ReplyDelivery?, String?> = when (outcome) {
            is ReplyRetract.Outcome.Deleted -> Retracted(outcome.text) to null
            // Nothing was live: the next fetch says what the reply became; nothing is claimed here.
            ReplyRetract.Outcome.NothingToDelete -> restored(prev, now) to outcome.text
            is ReplyRetract.Outcome.PageGone -> Gone to null
            // The relay says the Mac has it: it is no longer waiting at the relay, whatever the phone thought.
            is ReplyRetract.Outcome.TooLate -> (restored(prev, now).let { if (it is Sent) it.copy(queued = false) else it }) to outcome.text
            else -> restored(prev, now) to outcome.text
        }

        /**
         * Where a delete of a reply the Mac holds leaves it (the Mac's `retract` answer): deleted is
         * [Retracted]; anything else puts the hold back with the Mac's words as the note, since a Mac that says
         * "too late" is typing it and one that can't be reached may still send it. Pure.
         */
        fun afterMacRetract(prev: ReplyDelivery?, outcome: MacRetract.Outcome): Pair<ReplyDelivery?, String?> = when (outcome) {
            is MacRetract.Outcome.Deleted -> Retracted(outcome.text) to null
            else -> (if (prev == Retracting) null else prev) to outcome.text
        }

        /**
         * Where a delete leaves a reply once the Mac has answered the follow-up `retract` (after the relay's "forwarded"):
         * up to 20 s passed since the delete began, so what the reply is now is looked at first. Still [Retracting]: as
         * [afterRetract]. Newer news landed meanwhile (the Mac typed it and reported it, or its own `retracted` frame
         * came): that is kept, and a "too late" (or the Mac's refusal) is only noted under a reply that is still on its
         * way. Whatever the Mac said short of deleted, the relay already handed the reply over, so it is no longer queued.
         * A null state means "leave it as it is". Pure.
         */
        fun afterMacFollowUp(current: ReplyDelivery?, prev: ReplyDelivery?, outcome: ReplyRetract.Outcome, now: Instant): Pair<ReplyDelivery?, String?> {
            val deleted = outcome is ReplyRetract.Outcome.Deleted
            return when {
                current == Retracting -> afterRetract(prev, outcome, now).let { (d, n) -> (if (!deleted && d is Sent) d.copy(queued = false) else d) to n }
                !deleted && current is Sent -> current.copy(queued = false).takeIf { it != current } to outcome.text
                else -> null to null
            }
        }

        private fun restored(prev: ReplyDelivery?, now: Instant): ReplyDelivery? = when (prev) {
            Retracting -> Sent(queued = true, at = now)
            else -> prev
        }
    }
}

/** What a `reply.result` frame (or a stored `deliveryMethod`) says, as a delivery. */
object ReplyResultFrame {
    const val RETRACTED = "retracted"
    const val HELD_UNTIL_RESET = "held_until_reset"

    /**
     * `method: "retracted"` (with or without `cancelled`) is a delete, never a failure; `success` with
     * `held_until_reset` is a hold, never a delivery. Everything else is as before. Pure.
     */
    fun delivery(success: Boolean, method: String?, detail: String?, cancelled: Boolean = false): ReplyDelivery = when {
        method == RETRACTED || cancelled -> ReplyDelivery.Retracted(detail ?: HeldMessages.DELETED_COPY)
        success && method == HELD_UNTIL_RESET -> ReplyDelivery.HeldOnMac(detail)
        success -> ReplyDelivery.Delivered(detail)
        else -> ReplyDelivery.Failed(detail ?: "Your Mac couldn't deliver the reply.")
    }
}

/** "Held on your Mac until 3:00 PM": the time out of the Mac's "Will send it when the limit resets at 3:00 PM". */
object HeldUntilReset {
    /**
     * The words after the sentence's last " at ", when they read as a time (a digit, at most 12 characters): the same
     * rule as iOS `HeldUntilReset.headline`.
     */
    fun until(detail: String?): String? {
        val d = detail ?: return null
        val at = d.lastIndexOf(" at ").takeIf { it >= 0 } ?: return null
        val t = d.substring(at + 4).trim(' ', '.').trim()
        return t.takeIf { it.isNotEmpty() && it.length <= 12 && it.any(Char::isDigit) }
    }

    /** The status line for a reply the Mac holds for a rate limit. */
    fun line(detail: String?): String = until(detail)?.let { "Held on your Mac until $it" } ?: "Held on your Mac until the limit resets"
}

/**
 * `DELETE /reply/:id` (`reply-retract-v1`): takes back a reply still waiting in the relay's queue for an offline
 * Mac. The answer is keyed on the body's `error` string, never on the status alone: an old relay's `404 not_found`
 * (an unknown path) and the new relay's `404 no_such_intervention` (a page that is gone) are different news.
 */
object ReplyRetract {
    sealed interface Outcome {
        val text: String

        /**
         * `200 retracted:true`: the queue entry was deleted. Nothing was sent. [detail] is the Mac's own sentence when it
         * was the Mac that took it back after the relay's "forwarded" ("Deleted — not sent. Page will type your carry-on
         * prompt when the limit resets"); the relay gives none.
         */
        data class Deleted(val detail: String? = null) : Outcome {
            override val text: String get() = detail ?: "Deleted — not sent"
        }

        /** `200 nothing:true`: the relay holds no live reply (it failed, expired, or was already deleted). */
        data object NothingToDelete : Outcome {
            override val text: String get() = "Nothing to delete"
        }

        /** `409 too_late`, the Mac has it ("forwarded") or already delivered it. */
        data class TooLate(val stage: String) : Outcome {
            override val text: String get() = "Too late — your Mac already has it"
        }

        /** `409 too_late` with `not_held` or a stage this build doesn't know: the relay can't vouch it wasn't sent. */
        data object CouldntTakeBack : Outcome {
            override val text: String get() = COULDNT
        }

        /** `409 hook_held`: a blocking hook may already have read it. */
        data object HookHeld : Outcome {
            override val text: String get() = "It's waiting on the hook, so it can't be deleted."
        }

        /** `404 not_found`: an old relay with no such route (keyed on the error string, never the status alone). */
        data object RelayTooOld : Outcome {
            override val text: String get() = "Update your relay to delete queued replies"
        }

        /** `404 no_such_intervention`: the relay no longer knows the page (not pending, archived or tombstoned). */
        data object PageGone : Outcome {
            override val text: String get() = "Your relay no longer has that page"
        }

        data object Unauthorized : Outcome {
            override val text: String get() = "The relay no longer accepts this pairing. Re-pair with your Mac."
        }
        data class Retired(val why: String) : Outcome {
            override val text: String get() = why
        }

        /** A transport error, or anything unexpected: the delete may or may not have happened. */
        data class Failed(override val text: String) : Outcome
    }

    /** The relay's `error` for a pair of `too_late` stages the Mac holds. */
    private val macHasIt = setOf("forwarded", "delivered")

    const val TRANSPORT = "Couldn't reach your relay — it may still be sent"

    /** The relay answered, but not with anything that says the reply was taken back. */
    const val COULDNT = "Couldn't take it back — it may still be sent"

    fun from(status: Int, body: String): Outcome {
        TokenRetirement.why(status, body)?.let { return Outcome.Retired(it) }
        val json = parseJsonObject(body)
        val error = json?.str("error")
        return when (status) {
            in 200..299 -> if (json?.bool("retracted") == true) Outcome.Deleted() else Outcome.NothingToDelete
            409 -> when (error) {
                "too_late" -> if (json?.str("stage") in macHasIt) Outcome.TooLate(json?.str("stage") ?: "") else Outcome.CouldntTakeBack
                "hook_held" -> Outcome.HookHeld
                else -> Outcome.CouldntTakeBack
            }
            404 -> when (error) {
                "not_found" -> Outcome.RelayTooOld
                "no_such_intervention" -> Outcome.PageGone
                else -> Outcome.Failed(COULDNT)
            }
            401, 403 -> Outcome.Unauthorized
            else -> Outcome.Failed(COULDNT)
        }
    }

    /** What a delete shows while the relay's "forwarded" is being checked with the Mac (`retract {interventionId}`). */
    const val ASKING_MAC = "Asking your Mac…"

    /** The relay's `stage` for a reply it handed to a Mac socket: only this one is worth asking the Mac about. */
    const val FORWARDED = "forwarded"

    /**
     * After `409 too_late` with stage "forwarded" the Mac may still hold the reply (a rate-limit or resume queue), so a
     * Mac that advertises `retract-v1` is asked with the sessions op `retract {interventionId}`. Stage "delivered" never
     * chains: the Mac reported it typed. Pure.
     */
    fun chainsToMac(outcome: Outcome, macCaps: Set<String>): Boolean =
        outcome is Outcome.TooLate && outcome.stage == FORWARDED && SessionCaps.canRetract(macCaps)

    /**
     * The delete's final outcome once the Mac has answered the follow-up, in the existing retract copy: deleted is
     * [Outcome.Deleted] with the Mac's sentence (else "Deleted — not sent"); too late and not holding it are "Too late —
     * your Mac already has it", and so is no answer at all ([answer] null: 20 s, a POST that failed, or a Mac that doesn't
     * advertise `retract-v1`). A refusal for another reason (a stale clock, typing turned off) is the Mac's own words:
     * nothing was decided, so it is not "too late". iOS `ForwardedRetract.note(for:)`. Pure.
     */
    fun afterMac(answer: MacRetract.Outcome?): Outcome = when (answer) {
        is MacRetract.Outcome.Deleted -> Outcome.Deleted(answer.detail)
        is MacRetract.Outcome.Refused -> Outcome.Failed(answer.text)
        else -> Outcome.TooLate(FORWARDED)
    }

    /** The relay is known to have `DELETE /reply/:id`: its `/status` features say so. */
    fun available(relayFeatures: Set<String>?): Boolean = relayFeatures != null && SessionCaps.RELAY_RETRACT in relayFeatures
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
