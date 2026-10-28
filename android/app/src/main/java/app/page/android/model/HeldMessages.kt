package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// Messages the Mac holds until a session's turn ends (docs/SESSIONS-PROTOCOL.md "Holding a message until the
// turn ends", `hold-v1`), and the pieces that make a held message honest on the phone: what the list's `held`
// says, how a receipt settles from it, and how a delete (`retract-v1`) reads back. Pure Kotlin, like the rest of
// model/.

/** What a Mac says it accepts beyond the ops in the protocol's section 5 (the list header's `caps`). */
object SessionCaps {
    const val HOLD = "hold-v1"
    const val RETRACT = "retract-v1"
    const val IMAGES = "images-v1"

    /** The relay's `GET /status` `features` name for `DELETE /reply/:id`. */
    const val RELAY_RETRACT = "reply-retract-v1"

    /** A phone offers "When it finishes" only where the Mac holds and this session can be typed into later. */
    fun canHold(caps: Set<String>, row: LiveSession): Boolean = HOLD in caps && row.canHold

    /** A phone offers Delete for a message the Mac holds only when the Mac can take it back. */
    fun canRetract(caps: Set<String>): Boolean = RETRACT in caps
}

/** One entry of a session row's `held` list: a message the Mac holds, or settled in the last 15 minutes. */
data class HeldMessage(
    /** The `clientId` of the `input` that asked to hold it; also the `heldId` a `retract` names. */
    val clientId: String,
    /** Redacted and clipped to 200 characters by the Mac: the phone that sent it has the full text. */
    val text: String,
    val heldAt: Instant?,
    val state: State,
    /** Settled entries only: when it settled. */
    val at: Instant?,
    /** Settled: the sentence the final result carried. Held: why the last try didn't type it, when it was refused for a passing reason. */
    val detail: String?,
) {
    enum class State(val wire: String) {
        HELD("held"), TYPING("typing"), TYPED("typed"), DELETED("deleted"), ENDED("ended"), EXPIRED("expired"), FAILED("failed"), UNCONFIRMED("unconfirmed"),

        /** A state this build doesn't know (a later Mac): the entry is kept, and changes nothing (iOS `.unknown`). */
        UNKNOWN("");

        /** Still the Mac's to type: waiting, or being typed right now. */
        val isWaiting: Boolean get() = this == HELD || this == TYPING

        companion object {
            fun fromWire(raw: String?): State = entries.firstOrNull { it != UNKNOWN && it.wire == raw?.trim() } ?: UNKNOWN
        }
    }

    val isWaiting: Boolean get() = state.isWaiting

    companion object {
        /**
         * An entry with no `clientId` is dropped. One whose state this build doesn't know is kept as [State.UNKNOWN], so
         * its message is not mistaken for one the Mac stopped holding (readers ignore what they don't know).
         */
        fun decode(element: JsonElement): HeldMessage? {
            val o = element as? JsonObject ?: return null
            val id = o.str("clientId")?.trim()?.takeIf { it.isNotEmpty() && it.length <= 200 } ?: return null
            val state = State.fromWire(o.str("state"))
            val text = (o.str("text") ?: "").capped(200)
            return HeldMessage(
                clientId = id, text = text, heldAt = PageDate.parseAny(o["heldAt"]), state = state,
                at = PageDate.parseAny(o["at"]), detail = o.str("detail")?.trim()?.takeIf { it.isNotEmpty() }?.capped(200),
            )
        }
    }
}

/** Reading and reconciling `held`. */
object HeldMessages {
    /** The copy a receipt falls back on when the Mac's own detail hasn't arrived. */
    const val HELD_HEADLINE = "Held — sends when Claude finishes"

    /** The Mac's own sentence for a hold ("Held — Page types it when Claude finishes this turn"), else ours. */
    fun heldHeadline(detail: String?, agent: String = "Claude"): String =
        detail?.takeIf { it.isNotBlank() } ?: "Held — sends when $agent finishes"

    const val NO_LONGER_HELD = "No longer held — check the session"

    /** A held message this phone never saw listed counts as gone once a list without it arrives this long after it was sent. */
    const val MISSING_AFTER: Double = 30.0
    const val UNCONFIRMED_COPY = "Page restarted while typing this and won't retype it. Check the session."
    const val DELETED_COPY = "Deleted — not sent"

    /**
     * Where a message the phone sent stands, given what the session row's `held` says about it. [entry] is the row's
     * entry for this `clientId` (null when absent) and [seen] whether this phone has ever read that entry in a list.
     * Only a message the Mac may still be holding settles here (Held; Sending and No answer, for an `input` whose
     * `result` this phone never got, when the Mac's list shows it). A `result` already read, or any other state,
     * is never undone by a list. An entry that is gone with no settled state reads "No longer held" when this phone
     * saw it first (a list built before the Mac accepted the message lacks it too), or when its session left the list
     * ([sessionListed] false: the row, and so its settled entry, is gone with it). A held message never seen in any list
     * reads it too once a list that names its session, and not it, arrives more than [MISSING_AFTER] s after [sentAt]
     * ([now]; not while the Mac's list is [macDisabled]: that list is empty on purpose). iOS `reconciled`. Pure.
     */
    fun settle(
        state: SessionDeliveryState, entry: HeldMessage?, seen: Boolean, sessionListed: Boolean = true,
        sentAt: Instant? = null, now: Instant? = null, macDisabled: Boolean = false,
    ): SessionDeliveryState {
        val open = state is SessionDeliveryState.Held || state == SessionDeliveryState.Sending || state == SessionDeliveryState.NoAnswer
        if (!open) return state
        if (entry == null) {
            if (state !is SessionDeliveryState.Held) return state
            val overdue = sessionListed && !macDisabled && sentAt != null && now != null && now.secondsSince(sentAt) > MISSING_AFTER
            return if (seen || !sessionListed || overdue) SessionDeliveryState.CheckSession(NO_LONGER_HELD) else state
        }
        return when (entry.state) {
            HeldMessage.State.HELD ->
                if (state is SessionDeliveryState.Held) state.copy(note = entry.detail, typing = false)
                else SessionDeliveryState.Held(null, entry.detail, typing = false)
            HeldMessage.State.TYPING ->
                if (state is SessionDeliveryState.Held) state.copy(note = null, typing = true)
                else SessionDeliveryState.Held(null, null, typing = true)
            HeldMessage.State.TYPED -> SessionDeliveryState.Typed(entry.detail)
            HeldMessage.State.DELETED -> SessionDeliveryState.Deleted(entry.detail ?: DELETED_COPY)
            HeldMessage.State.ENDED ->
                SessionDeliveryState.Refused("ended", entry.detail ?: "Not sent — the session ended")
            HeldMessage.State.EXPIRED ->
                SessionDeliveryState.Refused("expired", entry.detail ?: "Not sent — the turn didn't finish within 6 hours")
            HeldMessage.State.FAILED ->
                SessionDeliveryState.Failed(entry.detail ?: "Not sent — Page couldn't type it")
            HeldMessage.State.UNCONFIRMED -> SessionDeliveryState.CheckSession(entry.detail ?: UNCONFIRMED_COPY)
            HeldMessage.State.UNKNOWN -> state
        }
    }

    /**
     * Held messages that did not come from this phone (another device, or one sent before this app restarted), as
     * pending bubbles. Only the ones still waiting: a settled one is in the transcript or was deleted. [mine] are
     * the `clientId`s this phone knows. Pure.
     */
    fun foreign(session: LiveSession, mine: Set<String>): List<SentSessionCommand> =
        session.held.filter { it.isWaiting && it.clientId !in mine }.sortedBy { it.heldAt ?: Instant.EPOCH }.map {
            SentSessionCommand(
                clientId = it.clientId, sessionId = session.id, kind = SessionCommandKind.INPUT, text = it.text,
                sentAt = it.heldAt ?: Instant.EPOCH,
                state = SessionDeliveryState.Held(null, it.detail, it.state == HeldMessage.State.TYPING),
                fromOtherDevice = true,
            )
        }

    /** The held messages of a session as the room draws them: this phone's own and others', oldest first. Pure. */
    fun pending(session: LiveSession?, sent: List<SentSessionCommand>): List<SentSessionCommand> {
        if (session == null) return sent
        return (sent + foreign(session, sent.map { it.clientId }.toSet())).sortedBy { it.sentAt }
    }
}

/**
 * What a delete of a held message (or of a reply the Mac holds) reads like on the phone: the Mac's `retract`
 * answer, mapped to words, and the 20 s no-answer. Pure.
 */
object MacRetract {
    /** A retract's own answer is waited for this long (the same as every command's). */
    const val TIMEOUT: Double = SessionDeliveryState.RESULT_TIMEOUT
    const val UNCONFIRMED = "Couldn't confirm the delete — it may still be sent"
    const val OFFLINE = "Your Mac is offline — try again when it's back"

    sealed interface Outcome {
        val text: String

        /** Taken back; nothing was typed. */
        data class Deleted(val detail: String?) : Outcome {
            override val text: String get() = detail ?: HeldMessages.DELETED_COPY
        }

        /** Page had already started typing it (or typed it). */
        data class TooLate(val detail: String?) : Outcome {
            override val text: String get() = detail ?: "Too late — it was already typed"
        }

        /** The Mac isn't holding a message by that id. */
        data class NotFound(val detail: String?) : Outcome {
            override val text: String get() = detail ?: "Page isn't holding that message"
        }

        /** The Mac refused for another reason (stale clock, turned off, an error): its words. */
        data class Refused(override val text: String) : Outcome

        /** The relay didn't forward it, or no answer came in [TIMEOUT]. */
        data class Failed(override val text: String) : Outcome
    }

    /** The `result` for a retract. The `retract` field is the answer; `code` / `reason` back it up for a Mac that omits it. */
    fun outcome(r: CommandResult, agent: String = "Claude"): Outcome {
        when (r.retract) {
            CommandResult.Retract.DELETED -> return Outcome.Deleted(r.detail)
            CommandResult.Retract.TOO_LATE -> return Outcome.TooLate(r.detail)
            CommandResult.Retract.NOT_FOUND -> return Outcome.NotFound(r.detail)
            // A value this build doesn't know is not "deleted", whatever `code` says: refused, in the Mac's words.
            CommandResult.Retract.UNKNOWN -> return Outcome.Refused(SessionResultCopy.refusal(r.reason, r.detail, agent))
            null -> Unit
        }
        return when {
            r.code == CommandResult.Code.DELIVERED && r.ok -> Outcome.Deleted(r.detail)
            r.reason == "too_late" -> Outcome.TooLate(r.detail)
            r.reason == "not_found" -> Outcome.NotFound(r.detail)
            else -> Outcome.Refused(SessionResultCopy.refusal(r.reason, r.detail, agent))
        }
    }

    /** The relay's answer to the POST that carried the retract, when it is not "accepted". */
    fun relayFailure(o: SessionCommandOutcome): Outcome.Failed? = when (o) {
        SessionCommandOutcome.Accepted -> null
        SessionCommandOutcome.MacOffline -> Outcome.Failed(OFFLINE)
        else -> Outcome.Failed(o.failureMessage ?: UNCONFIRMED)
    }
}

/** Where a delete of one held message stands (the phone's view, keyed by the message's `clientId`). */
sealed interface HeldDelete {
    val retractId: String

    data class Deleting(override val retractId: String, val at: Instant) : HeldDelete
    data class Done(override val retractId: String, val outcome: MacRetract.Outcome) : HeldDelete

    /** 20 s with no answer. */
    data class Unconfirmed(override val retractId: String) : HeldDelete

    val text: String?
        get() = when (this) {
            is Deleting -> null
            is Done -> outcome.text
            is Unconfirmed -> MacRetract.UNCONFIRMED
        }

    /** A delete in flight can't be asked twice. */
    val isDeleting: Boolean get() = this is Deleting

    /** [timedOut]: no `result` within [MacRetract.TIMEOUT]. Only a delete still waiting changes. */
    fun timedOut(now: Instant): HeldDelete =
        if (this is Deleting && now.secondsSince(at) >= MacRetract.TIMEOUT) Unconfirmed(retractId) else this
}

/**
 * Delete, the one affordance for something queued and not yet sent: where it applies, and the one rule behind it
 * ("never offer a Delete that can't work"). Pure.
 */
object QueuedDelete {
    /** What a Delete would take back, by layer (design layers L0 to L5). */
    enum class Layer {
        /** A message the Mac holds until the turn ends (`held[]`): `retract {heldId}`. */
        MAC_HELD,

        /** A `/reply` waiting in the relay for an offline Mac: `DELETE /reply/:id`. */
        RELAY_QUEUE,

        /** A `/reply` the Mac holds until a rate limit resets: `retract {interventionId}`. */
        MAC_RATE_LIMIT,
    }

    /** A held message offers Delete while the Mac holds it and can take it back, and no delete is under way. */
    fun heldMessage(state: SessionDeliveryState, macCaps: Set<String>, delete: HeldDelete?): Boolean =
        state is SessionDeliveryState.Held && !state.typing && SessionCaps.canRetract(macCaps) && delete?.isDeleting != true

    /**
     * A reply offers Delete when it waits at the relay for an offline Mac (queued, the relay says it can, and the
     * page is not one a blocking hook polls) or when the Mac holds it for a rate limit (and says it can take it back).
     */
    fun reply(delivery: ReplyDelivery?, isBlockingHook: Boolean, relayFeatures: Set<String>?, macCaps: Set<String>): Layer? = when {
        delivery is ReplyDelivery.Sent && delivery.queued && !isBlockingHook && relayFeatures != null && SessionCaps.RELAY_RETRACT in relayFeatures -> Layer.RELAY_QUEUE
        delivery is ReplyDelivery.HeldOnMac && SessionCaps.canRetract(macCaps) -> Layer.MAC_RATE_LIMIT
        else -> null
    }

    /**
     * What a queued reply says when it can't be deleted from here, so nothing reads as deletable that isn't:
     * a hook-held page, an old relay (no `reply-retract-v1`), or an old Mac for a rate-limit hold. null when
     * there is nothing worth saying. The old-Mac line waits for [hasList]: until the first list arrives the Mac's
     * `caps` are simply not known yet, and nothing says the Mac is old. Likewise the old-relay line waits for
     * `/status` ([relayFeatures] null is "not known yet", as in [RelayClient.retractReply]; iOS `QueuedDelete.whyNot`).
     */
    fun whyNot(delivery: ReplyDelivery?, isBlockingHook: Boolean, relayFeatures: Set<String>?, macCaps: Set<String>, hasList: Boolean): String? = when {
        delivery is ReplyDelivery.Sent && delivery.queued && isBlockingHook ->
            "Waiting on the hook. It can't be deleted from here."
        delivery is ReplyDelivery.Sent && delivery.queued && relayFeatures != null && SessionCaps.RELAY_RETRACT !in relayFeatures ->
            "Update your relay to delete queued replies."
        delivery is ReplyDelivery.HeldOnMac && hasList && !SessionCaps.canRetract(macCaps) ->
            "Update Page on your Mac to delete a held reply."
        else -> null
    }

    /**
     * The one honest line for what is already in the agent's own queue: Claude Code took the text (`queued`), so
     * Page can't take it back (it never sends Esc, Ctrl+C or Up for a message).
     */
    fun alreadyWithAgent(agent: String): String = "Already with $agent — it reads it after this step"
}
