package app.page.android.model

import java.time.Instant

enum class SessionCommandKind(val wire: String) { INPUT("input"), INTERRUPT("interrupt") }

/**
 * Where a message (or Stop) sent from the phone stands, keyed by its
 * `clientId`. Sending → Typed / Queued / Refused from the Mac's `result`;
 * Failed when the relay didn't forward it; No answer after 20 s of silence.
 */
sealed interface SessionDeliveryState {
    data object Sending : SessionDeliveryState
    data class Typed(val detail: String?) : SessionDeliveryState
    data class Queued(val detail: String?) : SessionDeliveryState
    data class Refused(val reason: String?, val message: String) : SessionDeliveryState
    data class Failed(val message: String) : SessionDeliveryState
    data object NoAnswer : SessionDeliveryState

    val isPending: Boolean get() = this == Sending

    /**
     * A `result` is the Mac's word and beats anything the phone guessed
     * (sending, a lost HTTP response, giving up). Once one result has landed,
     * a second for the same `clientId` is ignored.
     */
    fun applying(result: CommandResult, agent: String): SessionDeliveryState {
        when (this) {
            is Typed, is Queued, is Refused -> return this
            Sending, is Failed, NoAnswer -> Unit
        }
        return when (result.code) {
            CommandResult.Code.DELIVERED -> Typed(result.detail)
            CommandResult.Code.QUEUED -> Queued(result.detail)
            CommandResult.Code.REFUSED -> Refused(result.reason, SessionResultCopy.refusal(result.reason, result.detail, agent))
            CommandResult.Code.FAILED -> Failed(SessionResultCopy.failure(result.reason, result.detail))
        }
    }

    /** After the POST returns. Only a send still waiting changes: a result that beat the HTTP response is newer news. */
    fun afterPost(outcome: SessionCommandOutcome): SessionDeliveryState {
        val message = outcome.failureMessage
        if (this != Sending || message == null) return this
        return Failed(message)
    }

    /** The phone stops waiting 20 s after sending. */
    fun timedOut(sentAt: Instant, now: Instant): SessionDeliveryState {
        if (this != Sending || now.secondsSince(sentAt) < RESULT_TIMEOUT) return this
        return NoAnswer
    }

    /** Short status under a message bubble. */
    fun label(kind: SessionCommandKind): String = when (this) {
        Sending -> if (kind == SessionCommandKind.INPUT) "Sending…" else "Stopping…"
        is Typed -> if (kind == SessionCommandKind.INPUT) "Typed" else "Stopped"
        is Queued -> "Queued"
        is Refused -> "Refused"
        is Failed -> "Not sent"
        NoAnswer -> "No answer from your Mac"
    }

    /** The longer explanation, when there is one. */
    fun explanation(kind: SessionCommandKind, agent: String): String? = when (this) {
        Sending -> null
        is Typed -> detail ?: if (kind == SessionCommandKind.INTERRUPT) "Pressed Esc in the session." else null
        is Queued -> detail ?: "Queued — $agent reads it after the current step."
        is Refused -> message
        is Failed -> message
        NoAnswer -> "Your Mac didn't confirm this within ${RESULT_TIMEOUT.toInt()} seconds. It may still arrive; check the transcript before sending again."
    }

    /** The explanation under a message bubble: only when there's something to act on or wait for. */
    fun bubbleExplanation(kind: SessionCommandKind, agent: String): String? = when (this) {
        is Refused, is Failed, NoAnswer, is Queued -> explanation(kind, agent)
        Sending, is Typed -> null
    }

    /** What TalkBack reads for a bubble's status: the same label and explanation the screen shows. */
    fun spokenBubbleStatus(kind: SessionCommandKind, agent: String): String =
        listOfNotNull(label(kind), bubbleExplanation(kind, agent)).joinToString(". ")

    companion object {
        const val RESULT_TIMEOUT: Double = 20.0
    }
}

data class SentSessionCommand(
    val clientId: String,
    val sessionId: String,
    val kind: SessionCommandKind,
    /** Kept in memory only, to show the bubble until the transcript echoes it. */
    val text: String,
    val sentAt: Instant,
    val state: SessionDeliveryState,
    /**
     * Transcript entry ids already on screen when this was sent (null if no
     * transcript had loaded). None of them can be its echo, which keeps an
     * earlier identical "yes" from claiming this message's status.
     */
    val priorEntryIds: Set<String>? = null,
)

object SessionResultCopy {
    /**
     * What a refused command tells the user, with what to do about it. Known
     * reasons get Page's own copy; anything newer falls back on the Mac's
     * `detail`.
     */
    fun refusal(reason: String?, detail: String?, agent: String): String = when (reason) {
        "waiting" -> "$agent is showing a prompt on your Mac. Answer it from its page instead."
        "unknown_state" -> "Page can't tell what this session is doing right now, so it didn't type anything. Try again in a moment."
        "not_typable" -> detail ?: "Page can't type into this session's terminal."
        "draft" -> "There's unsent text in the session's input box on your Mac. Clear it there, then try again."
        "digit_while_busy" -> "Starts with a number: wait for $agent to finish, or add a word first."
        "ended" -> "This session has ended."
        "codex_mid_turn" -> "Codex is mid-turn — Page can type once the turn ends."
        "disabled" -> "Typing from your phone is turned off on your Mac. Turn it back on in Page's Preferences on the Mac."
        "stale" -> "Your Mac ignored this because its clock and your phone's differ by more than 5 minutes. Check Date & Time on both."
        "replay" -> "Your Mac already received this message."
        "not_found" -> "This session is no longer on your Mac's list."
        "interrupt_unsupported" -> "Page can't stop this session from here: it isn't mid-turn, or its terminal doesn't support it."
        "error" -> detail ?: "Something went wrong on your Mac. Try again."
        else -> detail ?: "Your Mac didn't type this."
    }

    @Suppress("UNUSED_PARAMETER")
    fun failure(reason: String?, detail: String?): String = detail ?: "Your Mac couldn't type this into the session."
}

/**
 * What the detail screen lists: the Mac's transcript, with each message sent
 * from this phone attached to the user entry that echoes it, and the ones not
 * echoed yet (or refused) as pending bubbles at the end.
 */
object TranscriptTimeline {
    sealed interface Item {
        val id: String

        data class Entry(val entry: TranscriptEntry, val delivery: SentSessionCommand?) : Item {
            override val id: String get() = "e:" + entry.id
        }

        data class Pending(val command: SentSessionCommand) : Item {
            override val id: String get() = "p:" + command.clientId
        }
    }

    /**
     * The Mac sanitises what it types (control characters stripped, a
     * leading `!` guarded) and the transcript may be redacted, so compare
     * loosely: no control characters, collapsed whitespace, no leading `!`
     * or backslash.
     */
    fun normalise(s: String): String {
        val kept = StringBuilder()
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            val type = Character.getType(cp)
            val control = type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt()
            if (!control || cp == '\n'.code || cp == '\t'.code) kept.appendCodePoint(cp)
            i += Character.charCount(cp)
        }
        // Unicode whitespace, like Swift's Character.isWhitespace (Java's \s is ASCII only).
        val words = mutableListOf<String>()
        val word = StringBuilder()
        for (ch in kept) {
            if (ch.isWhitespace()) {
                if (word.isNotEmpty()) { words.add(word.toString()); word.clear() }
            } else {
                word.append(ch)
            }
        }
        if (word.isNotEmpty()) words.add(word.toString())
        return words.joinToString(" ").trimStart('!', '\\', ' ')
    }

    /** An entry may be capped at 2000 characters, so a long message echoes as a prefix. */
    fun echoes(entryText: String, sentText: String): Boolean {
        val e = normalise(entryText)
        val s = normalise(sentText)
        if (e.isEmpty() || s.isEmpty()) return false
        if (e == s) return true
        val head = 200
        return e.length >= head && s.length >= head && e.take(head) == s.take(head)
    }

    /** Clocks differ between Mac and phone; an echo can't predate the send by more than this. */
    const val CLOCK_SLACK: Double = 5 * 60.0

    fun merge(entries: List<TranscriptEntry>, sent: List<SentSessionCommand>): List<Item> {
        val matchedEntry = HashMap<String, SentSessionCommand>()
        val unmatched = mutableListOf<SentSessionCommand>()
        val used = HashSet<String>()
        for (message in sent.filter { it.kind == SessionCommandKind.INPUT }.sortedBy { it.sentAt }) {
            // Refused and failed messages never reach the session.
            val canEcho = message.state !is SessionDeliveryState.Refused && message.state !is SessionDeliveryState.Failed
            val prior = message.priorEntryIds ?: emptySet()
            val earliest = message.sentAt.plusSeconds(-CLOCK_SLACK)
            val hit = if (!canEcho) null else entries.firstOrNull { e ->
                e.role == TranscriptRole.USER && e.id !in used && e.id !in prior &&
                    (e.at?.let { it >= earliest } ?: true) && echoes(e.text, message.text)
            }
            if (hit != null) {
                used.add(hit.id)
                matchedEntry[hit.id] = message
            } else {
                unmatched.add(message)
            }
        }
        return entries.map { Item.Entry(it, matchedEntry[it.id]) } + unmatched.map { Item.Pending(it) }
    }
}
