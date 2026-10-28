package app.page.android.model

import java.time.Instant

enum class SessionCommandKind(val wire: String) { INPUT("input"), INTERRUPT("interrupt"), START("start"), ANSWER("answer"), RETRACT("retract") }

/**
 * Where a message (or Stop) sent from the phone stands, keyed by its
 * `clientId`. Sending → Typed / Queued / Refused from the Mac's `result`;
 * Failed when the relay didn't forward it; No answer after 20 s of silence.
 */
sealed interface SessionDeliveryState {
    data object Sending : SessionDeliveryState
    data class Typed(val detail: String?, /** A photo message: how many photos Claude received as images (`attached`); null when the Mac couldn't tell. */ val attached: Int? = null) : SessionDeliveryState

    /** Typed into the agent's own queue: Claude Code reads it at its next step, and Page can't take it back. */
    data class Queued(val detail: String?) : SessionDeliveryState

    /**
     * The Mac holds it until the session's turn ends (`hold-v1`), and can still be asked to delete it. [detail] is
     * the Mac's own sentence; [note] why the last try didn't type it; [typing] it is being typed right now.
     */
    data class Held(val detail: String?, val note: String? = null, val typing: Boolean = false) : SessionDeliveryState

    /** Deleted (`retract-v1`) before it was typed: nothing reached the session. */
    data class Deleted(val detail: String?) : SessionDeliveryState

    /** The Mac can't say what became of it (it restarted while typing, or the entry is gone): check the session. */
    data class CheckSession(val message: String) : SessionDeliveryState {
        /** "No longer held": a guess from the list, so the Mac's own final `result` for the message (`fromHold`) still replaces it. */
        val isNoLongerHeld: Boolean get() = message == HeldMessages.NO_LONGER_HELD
    }
    data class Refused(val reason: String?, val message: String) : SessionDeliveryState
    data class Failed(val message: String) : SessionDeliveryState
    data object NoAnswer : SessionDeliveryState

    val isPending: Boolean get() = this == Sending

    /** A message the Mac still holds: it may be typed later, so it is never settled news. */
    val isHeld: Boolean get() = this is Held

    /**
     * A `result` is the Mac's word and beats anything the phone guessed
     * (sending, a lost HTTP response, giving up). Once one result has landed,
     * a second for the same `clientId` is ignored.
     */
    fun applying(result: CommandResult, agent: String): SessionDeliveryState {
        when (this) {
            is Typed, is Queued, is Refused, is Deleted -> return this
            // A held message gets exactly one more result: the final one (`fromHold`). Anything else is a repeat.
            is Held -> if (!result.fromHold) return this
            // "No longer held" is only the list's guess: the final result for the message (typed, deleted, ended,
            // expired...) replaces it. The other check-the-session states are the Mac's own word and stay.
            is CheckSession -> if (!(isNoLongerHeld && result.fromHold)) return this
            Sending, is Failed, NoAnswer -> Unit
        }
        return when (result.code) {
            CommandResult.Code.DELIVERED -> Typed(result.detail, result.attached)
            CommandResult.Code.QUEUED -> if (result.held) Held(result.detail) else Queued(result.detail)
            // Deleted before it was typed. Never read as typed or failed.
            CommandResult.Code.CANCELLED -> Deleted(result.detail ?: HeldMessages.DELETED_COPY)
            CommandResult.Code.REFUSED ->
                // The Mac's own sentence for a held message that ended ("Not sent — the session ended").
                Refused(result.reason, if (result.fromHold) result.detail ?: SessionResultCopy.refusal(result.reason, null, agent) else SessionResultCopy.refusal(result.reason, result.detail, agent))
            CommandResult.Code.FAILED -> Failed(SessionResultCopy.failure(result.reason, result.detail))
        }
    }

    /**
     * The `result` of a photo message's `inputImages` that came after the phone gave up on it (30 s with no answer, or a
     * POST whose answer was lost): the Mac's word settles the bubble. Only a bubble still waiting, or one the phone
     * marked as unanswered or failed, changes; one that has an answer keeps it. Pure.
     */
    fun afterLatePhotoResult(result: CommandResult, agent: String): SessionDeliveryState {
        val open = this == Sending || this is Failed || this == NoAnswer || (this is CheckSession && message == PhotoUploader.NO_ANSWER)
        return if (open) Sending.applying(result, agent) else this
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

    /** The status of a message with [photos] photos: "Sent" where text says "Typed" (a photo isn't typed). */
    fun label(kind: SessionCommandKind, photos: Int): String =
        if (photos > 0 && kind == SessionCommandKind.INPUT) when (this) {
            Sending -> "Sending photos…"
            is Typed -> "Sent"
            else -> label(kind)
        } else label(kind)

    /** Short status under a message bubble. */
    fun label(kind: SessionCommandKind): String = when (this) {
        Sending -> when (kind) {
            SessionCommandKind.INPUT -> "Sending…"
            SessionCommandKind.INTERRUPT -> "Stopping…"
            SessionCommandKind.START -> "Starting…"
            SessionCommandKind.ANSWER -> "Sending your answers…"
            SessionCommandKind.RETRACT -> "Deleting…"
        }
        is Typed -> when (kind) {
            SessionCommandKind.INPUT -> "Typed"
            SessionCommandKind.INTERRUPT -> "Stopped"
            SessionCommandKind.START -> "Started"
            SessionCommandKind.ANSWER -> "Answered"
            SessionCommandKind.RETRACT -> "Deleted"
        }
        is Queued -> "Queued"
        is Held -> if (typing) "Typing it now" else "Held"
        is Deleted -> "Deleted"
        is CheckSession -> "Check the session"
        is Refused -> "Refused"
        is Failed -> "Not sent"
        NoAnswer -> "No answer from your Mac"
    }

    /** The longer explanation, when there is one. */
    fun explanation(kind: SessionCommandKind, agent: String): String? = when (this) {
        Sending -> null
        is Typed -> detail ?: if (kind == SessionCommandKind.INTERRUPT) "Pressed Esc in the session." else null
        is Queued -> detail ?: "Queued — $agent reads it after the current step."
        is Held -> if (typing) "Page is typing it into the session now." else HeldMessages.heldHeadline(detail, agent) + (note?.let { " · $it" } ?: "")
        is Deleted -> detail ?: HeldMessages.DELETED_COPY
        is CheckSession -> message
        is Refused -> message
        is Failed -> message
        NoAnswer -> "Your Mac didn't confirm this within ${RESULT_TIMEOUT.toInt()} seconds. It may still arrive; check the transcript before sending again."
    }

    /** The explanation under a message bubble: only when there's something to act on or wait for. */
    fun bubbleExplanation(kind: SessionCommandKind, agent: String): String? = when (this) {
        is Refused, is Failed, NoAnswer, is Held, is Deleted, is CheckSession -> explanation(kind, agent)
        // Already typed into the agent's own queue: Page can't take it back, and says so.
        is Queued -> QueuedDelete.alreadyWithAgent(agent)
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
    /** What the room showed when this was sent: names the receipt. */
    val target: SessionTarget? = null,
    /** `answer` only: the question (the ask's id) these answers were for. */
    val promptKey: String? = null,
    /** A held message another device sent (the Mac's list names it, this phone never sent it): a bubble, with Delete. */
    val fromOtherDevice: Boolean = false,
    /** Photos sent with this message (`inputImages`); 0 for text. [text] is then the caption, which may be empty. */
    val photos: Int = 0,
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
        "question_changed" -> detail ?: "That question changed on your Mac, so nothing was pressed. Open it again to see the new one."
        "answer_unsupported" -> detail ?: "Page can't answer this question from here. Answer it on your Mac."
        "target_mismatch" -> detail ?: "This room doesn't match the session on your Mac any more, so nothing was typed. Close it and open the session again."
        // Photos (images-v1): the Mac's own sentence when it sent one.
        "attach_busy" -> detail ?: PhotoOffer.WORKING
        "attachment_missing" -> detail ?: "Part of a photo didn't reach your Mac — send it again"
        "attachment_invalid" -> detail ?: "Your Mac couldn't use the photo."
        "attach_unsupported" -> detail ?: "This terminal can't take photos from Page."
        "cancelled" -> detail ?: HeldMessages.DELETED_COPY
        "expired" -> detail ?: "Not sent — the turn didn't finish within 6 hours."
        "too_late" -> detail ?: "Too late — it was already typed."
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

    /**
     * Whether a user entry is this message. A photo message reads as Claude Code wrote it ("[Image #1] [Image #2]caption",
     * or "[Image]" / "[2 images]" with no words, or the caption and "Photo from my phone: <path>" lines), so the chips
     * and file lines are dropped before the words are compared; with no caption, the first unused entry that carries
     * photos is the echo. A text message is compared as before.
     */
    fun echoesMessage(e: TranscriptEntry, m: SentSessionCommand): Boolean {
        if (m.photos == 0) return echoes(e.text, m.text)
        if (PhotoText.count(e.text, e.images) == 0) return false
        val words = PhotoText.caption(e.text)
        return if (m.text.isBlank()) words.isEmpty() else echoes(words, m.text)
    }

    /** Clocks differ between Mac and phone; an echo can't predate the send by more than this. */
    const val CLOCK_SLACK: Double = 5 * 60.0

    fun merge(entries: List<TranscriptEntry>, sent: List<SentSessionCommand>): List<Item> {
        val matchedEntry = HashMap<String, SentSessionCommand>()
        val unmatched = mutableListOf<SentSessionCommand>()
        val used = HashSet<String>()
        for (message in sent.filter { it.kind == SessionCommandKind.INPUT }.sortedBy { it.sentAt }) {
            // Refused and failed messages never reach the session.
            // A message the Mac still holds, or deleted, isn't in the session either.
            val canEcho = message.state !is SessionDeliveryState.Refused && message.state !is SessionDeliveryState.Failed &&
                message.state !is SessionDeliveryState.Held && message.state !is SessionDeliveryState.Deleted
            val prior = message.priorEntryIds ?: emptySet()
            val earliest = message.sentAt.plusSeconds(-CLOCK_SLACK)
            val hit = if (!canEcho) null else entries.firstOrNull { e ->
                e.role == TranscriptRole.USER && e.id !in used && e.id !in prior &&
                    (e.at?.let { it >= earliest } ?: true) && echoesMessage(e, message)
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
