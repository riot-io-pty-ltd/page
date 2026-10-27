package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/DecisionPhase.swift. What a Decision sheet is
// showing, derived from live state on every render: sending, sent, slow,
// unconfirmed, checking a close, delivered, failed, already answered and
// resolved, with the sheet closing itself after a result.

sealed interface DecisionPhase {
    data object Loading : DecisionPhase
    data object Missing : DecisionPhase
    data object Open : DecisionPhase
    data object Sending : DecisionPhase

    /** [slow]: past `ReplyConfirmation.SLOW_AFTER` without confirmation. */
    data class Sent(val queued: Boolean, val slow: Boolean) : DecisionPhase

    /**
     * Accepted by the relay but never confirmed by the Mac within the relay's ack window, so a second answer
     * is accepted again. Input re-opens so the page can't get stuck.
     */
    data object Unconfirmed : DecisionPhase

    /** Closed with no reason known yet while a reply was out: checking the archive before saying what happened. */
    data object CheckingClose : DecisionPhase
    data class Delivered(val detail: String?) : DecisionPhase
    data class Failed(val message: String) : DecisionPhase
    data object AlreadyReplied : DecisionPhase
    data class Resolved(val why: String) : DecisionPhase

    val acceptsInput: Boolean get() = this == Open || this is Failed || this == Unconfirmed

    /** States after which the sheet closes on its own. */
    val autoCloseDelay: Double?
        get() = when (this) {
            is Delivered -> 1.4
            is Resolved, AlreadyReplied -> 2.2
            else -> null
        }

    /** A confirmed delivery is the only success. */
    val isDelivered: Boolean get() = this is Delivered

    data class Inputs(
        val delivery: ReplyDelivery?,
        /** The page is in the live inbox. */
        val isLive: Boolean,
        /** A last known copy exists (so the content stays readable after it closes). */
        val hasSnapshot: Boolean,
        val lookupFinished: Boolean,
        val closeReason: String?,
        val closeLookupFinished: Boolean,
        val now: Instant,
        val legacyRelay: Boolean,
    )

    enum class Tone { NEUTRAL, GOOD, WARN, PROBLEM }

    data class StatusLine(val text: String, val tone: Tone)

    /** The strip under the ask, in the trust model's words. null while open. */
    fun statusLine(legacyRelay: Boolean): StatusLine? = when (this) {
        Open, Loading, Missing -> null
        Sending -> StatusLine("Sending…", Tone.NEUTRAL)
        is Sent -> when {
            queued -> StatusLine("Queued · your Mac is offline. It'll be typed in when the Mac reconnects (within an hour).", Tone.WARN)
            slow -> StatusLine(
                if (legacyRelay) "Sent · waiting for your Mac to confirm…"
                else "Sent · waiting for your Mac. It hasn't confirmed this yet; if it reports a failure, or hasn't confirmed within 20 minutes, you can answer again.",
                Tone.NEUTRAL,
            )
            else -> StatusLine("Sent · waiting for your Mac to confirm…", Tone.NEUTRAL)
        }
        CheckingClose -> StatusLine("This page closed · checking whether your reply landed…", Tone.NEUTRAL)
        is Delivered -> StatusLine("Delivered · ${detail ?: "typed into the session on your Mac"}.", Tone.GOOD)
        is Failed -> StatusLine(message, Tone.PROBLEM)
        Unconfirmed -> StatusLine("Your Mac never confirmed this. If the session is still waiting, you can answer again.", Tone.WARN)
        AlreadyReplied -> StatusLine("Already answered at the Mac", Tone.NEUTRAL)
        is Resolved -> StatusLine("Resolved · $why", Tone.NEUTRAL)
    }

    companion object {
        /** Pure. */
        fun derive(i: Inputs): DecisionPhase {
            fun closed(hadOwnReply: Boolean): DecisionPhase = when (val p = ClosedReplyPhase.decide(i.closeReason, hadOwnReply, i.closeLookupFinished)) {
                ClosedReplyPhase.Delivered -> Delivered(null)
                is ClosedReplyPhase.Resolved -> Resolved(p.why)
                ClosedReplyPhase.Checking -> CheckingClose
            }
            return when (val d = i.delivery) {
                ReplyDelivery.Sending -> Sending
                is ReplyDelivery.Sent -> {
                    if (!i.isLive) closed(true)
                    else if (ReplyConfirmation.isUnconfirmed(d.at, d.queued, i.now, i.legacyRelay)) Unconfirmed
                    else Sent(d.queued, i.now.secondsSince(d.at) > ReplyConfirmation.SLOW_AFTER)
                }
                is ReplyDelivery.Delivered -> Delivered(d.detail)
                is ReplyDelivery.Failed -> if (i.isLive) Failed(d.message) else closed(true)
                ReplyDelivery.AlreadyReplied -> AlreadyReplied
                ReplyDelivery.Gone -> Resolved("This page was already resolved.")
                null -> {
                    if (i.isLive) Open
                    else if (i.hasSnapshot) closed(false)
                    else if (i.lookupFinished) Missing else Loading
                }
            }
        }
    }
}

/**
 * The text of the discard-draft question: a quick action never carries a half-typed note, so with a draft
 * present Page asks what to do with it.
 */
object DraftQuestion {
    fun title(action: ReplyAction): String = when (action) {
        ReplyAction.APPROVE -> "Approve without your note?"
        ReplyAction.DENY -> "Deny with your note?"
        ReplyAction.CARRY_ON -> "Send your note instead?"
        ReplyAction.CUSTOM -> ""
    }
}
