package app.page.android.model

import java.time.Instant
import java.util.Locale

// Port of iOS/Page/Models/ActionFlow.swift. How an action leaves a card: the
// three phases of the Receipt thread (Arm, Send, Resolve) as pure decisions,
// and the mapping from a row's action to the reply the relay already
// understands. Nothing here sends anything; the live coordinator calls
// `RelayClient.reply`, the only path to the Mac.

/**
 * ARM: a local 1.2 s ring after a tap or a swipe. Nothing has left the phone, and tapping the ring cancels.
 * Once SEND begins there is no cancel, because keystrokes cannot be taken back.
 */
object ArmSpec {
    const val duration: Double = 1.2

    /** 0..1 after [elapsed]. Pure. */
    fun progress(elapsed: Double): Double = minOf(1.0, maxOf(0.0, elapsed / duration))
    fun isComplete(elapsed: Double): Boolean = elapsed >= duration

    /** Seconds left to cancel, never negative. */
    fun remaining(elapsed: Double): Double = maxOf(0.0, duration - elapsed)
}

/** What a commit gesture needs before the send. */
object ActionGate {
    /**
     * Every action runs Arm, then Send, then Resolve: a 1.2 s local ring during which nothing has left the
     * phone and Cancel works. The one exception is an Irreversible approve, where the press-and-hold plus
     * biometrics *is* the arm. Deny (Esc), Stop, carry on and a written reply arm like the rest, and the ring
     * names exactly what will be typed. Pure.
     */
    fun requiresArm(kind: RowAction.Kind, commit: CommitGesture?): Boolean {
        if (!isSendable(kind)) return false
        return !requiresBiometrics(kind, commit)
    }

    /** Only an Irreversible approve asks for the fingerprint / face / device credential. */
    fun requiresBiometrics(kind: RowAction.Kind, commit: CommitGesture?): Boolean =
        kind == RowAction.Kind.APPROVE && commit == CommitGesture.HOLD

    /** An action that exists on the row and can be sent from the phone. */
    fun isSendable(kind: RowAction.Kind): Boolean = kind != RowAction.Kind.OPEN_ON_MAC
}

/** The relay reply for a row action. */
data class ReplyRequest(
    val action: ReplyAction,
    /** Empty for approve, deny and carry on. The user's own words for a written reply. */
    val text: String,
)

object ReplyMapping {
    /**
     * approve is option 1; deny (and Stop it) is Esc; a written reply is Esc, then the text, then Return (the
     * Mac's reply planner); carry on is the configured carry-on message. Never "2", never a standing
     * permission. null for an action that is not sent from the phone, and for a written reply with no words. Pure.
     */
    fun request(kind: RowAction.Kind, text: String = ""): ReplyRequest? = when (kind) {
        RowAction.Kind.APPROVE -> ReplyRequest(ReplyAction.APPROVE, "")
        RowAction.Kind.DENY, RowAction.Kind.STOP -> ReplyRequest(ReplyAction.DENY, "")
        RowAction.Kind.CARRY_ON -> ReplyRequest(ReplyAction.CARRY_ON, "")
        RowAction.Kind.TELL_INSTEAD -> {
            val t = Sw.trimWsNl(text)
            if (t.isEmpty()) null else ReplyRequest(ReplyAction.CUSTOM, t)
        }
        RowAction.Kind.OPEN_ON_MAC -> null
    }

    /**
     * A quick action never carries a half-typed note (the Mac uses non-empty text in place of the action, so
     * Deny would silently become a prompt). With a draft present, ask first.
     */
    fun needsDraftDecision(draft: String): Boolean = Sw.trimWsNl(draft).isNotEmpty()
}

/** One action in flight from a card. */
data class PendingAction(
    val rowId: String,
    val kind: RowAction.Kind,
    val text: String,
    val commit: CommitGesture?,
    val startedAt: Instant,
    /** The 1.2 s cancel ring is running (false once sent, or when none applies). */
    val armed: Boolean,
    /** What will be typed, where, on which Mac ("Will press Esc · cmux › builds · Studio MBP"). */
    val preview: String? = null,
) {
    /** The local phase at a moment. */
    sealed interface Phase {
        /** Ring running, 0..1. Tapping it cancels. */
        data class Arming(val progress: Double) : Phase

        /** The arm time is up: the coordinator sends now. */
        data object Ready : Phase
    }

    fun phase(now: Instant): Phase {
        if (!armed) return Phase.Ready
        val e = now.secondsSince(startedAt)
        return if (ArmSpec.isComplete(e)) Phase.Ready else Phase.Arming(ArmSpec.progress(e))
    }

    /** What the card says while the ring runs. */
    fun armLabel(now: Instant): String {
        if (phase(now) !is Phase.Arming) return "Sending…"
        val left = ArmSpec.remaining(now.secondsSince(startedAt))
        return "Sending in ${String.format(Locale.US, "%.1f", left)} s · tap to cancel"
    }
}

/** Which word a row's card should use for the receipt after a send. */
sealed interface CardOutcome {
    data object None : CardOutcome
    data class Arming(val progress: Double) : CardOutcome
    data object Sending : CardOutcome

    /** The Mac confirmed the keystroke landed. The only success. */
    data class Delivered(val detail: String) : CardOutcome

    /** Anything else, in words, with a next step. */
    data class Problem(val why: String) : CardOutcome

    companion object {
        fun from(pending: PendingAction?, delivery: ReplyDelivery?, now: Instant): CardOutcome {
            val phase = pending?.phase(now)
            if (phase is PendingAction.Phase.Arming) return Arming(phase.progress)
            return when (delivery) {
                null -> if (pending == null) None else Sending
                ReplyDelivery.Sending -> Sending
                is ReplyDelivery.Sent -> Sending
                is ReplyDelivery.Delivered -> Delivered(delivery.detail ?: "typed into the session on your Mac")
                is ReplyDelivery.Failed -> Problem(delivery.message)
                ReplyDelivery.AlreadyReplied -> Problem("Already answered at the Mac")
                ReplyDelivery.Gone -> Problem("Prompt closed before your answer")
            }
        }
    }
}
