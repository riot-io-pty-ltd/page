package app.page.android.model

import java.time.Instant
import kotlin.math.ceil
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// How a message to a BUSY session goes, and the 10 s countdown in front of one that goes now. Pure Kotlin.
//
//   SendWhen       "Now" (Claude reads it mid-turn) or "When it finishes" (the Mac holds it, `hold-v1`)
//   SendChoice     whether the choice is offered, and which side is selected
//   ScheduledSend  one message counting down before its POST ("Sending in 10 s · Undo")
//   SendOutbox     the countdown state machine: schedule, undo, fire
//   OutboxRestore  what an app killed before 0 leaves behind: nothing sent, the text back in the box, with a note

/** When a message to a busy session reaches Claude. */
enum class SendWhen(val wire: String) {
    NOW("now"), WHEN_FINISHED("whenFinished");

    val title: String
        get() = when (this) {
            NOW -> "Now"
            WHEN_FINISHED -> "When it finishes"
        }

    /** One short line, said under the choice the first time it shows. */
    fun explanation(agent: String): String = when (this) {
        NOW -> "$agent reads it after its current step."
        WHEN_FINISHED -> "Held on your Mac and typed when $agent finishes. Delete it any time before."
    }

    companion object {
        fun fromWire(raw: String?): SendWhen? = entries.firstOrNull { it.wire == raw }
    }
}

/** The choice under a busy session's composer. */
object SendChoice {
    /**
     * [offered] is what the phone can do for this session right now; [selected] is one of them. With one option the
     * composer shows no choice, only what will happen ([holdOnly]: a busy Codex session outside cmux, where nothing
     * can be typed now but the Mac can hold it).
     */
    data class Plan(val offered: List<SendWhen>, val selected: SendWhen) {
        val isChoice: Boolean get() = offered.size > 1
        val holdOnly: Boolean get() = offered == listOf(SendWhen.WHEN_FINISHED)
    }

    /**
     * Null when the session is not busy (sending is immediate, nothing to choose) or when nothing could be sent.
     * "Now" needs Page to type into the terminal; "When it finishes" needs `hold-v1` in the Mac's caps and the
     * row's `canHold`. The last choice (kept per device) is the default while it is still on offer. Pure.
     */
    fun plan(busy: Boolean, canTypeNow: Boolean, canHold: Boolean, last: SendWhen?): Plan? {
        if (!busy) return null
        val offered = listOfNotNull(SendWhen.NOW.takeIf { canTypeNow }, SendWhen.WHEN_FINISHED.takeIf { canHold })
        if (offered.isEmpty()) return null
        return Plan(offered, if (last != null && last in offered) last else offered.first())
    }

    /** The plan for a live session row (its state, `canType`, `canHold`) and the Mac's caps. */
    fun forSession(session: LiveSession, ended: Boolean, caps: Set<String>, last: SendWhen?): Plan? =
        plan(session.state == LiveSessionState.ACTIVE && !ended, session.canType, SessionCaps.canHold(caps, session), last)
}

/** One message counting down before its POST. Its text lives in memory, and on disk only while it counts. */
data class ScheduledSend(
    val id: String,
    val sessionId: String,
    val text: String,
    val target: SessionTarget?,
    val startedAt: Instant,
    /**
     * A review or look page's Steer: when it fires it goes as that page's written reply (the page's own path),
     * not as session input. null for a message typed in a room.
     */
    val pageId: String? = null,
)

object SendCountdown {
    /** "Sending in 10 s · Undo": nothing has left the phone until this runs out. */
    const val SECONDS: Double = 10.0
    const val UNDO = "Undo"

    /**
     * A countdown the phone slept through by more than this is stale: its timer runs on uptime, which stops in deep
     * sleep, so it can wake minutes late. Then nothing is sent and the text goes back in the box (iOS `staleGrace`).
     */
    const val STALE_GRACE: Double = 30.0

    fun remaining(s: ScheduledSend, now: Instant): Double = maxOf(0.0, SECONDS - now.secondsSince(s.startedAt))
    fun isDue(s: ScheduledSend, now: Instant): Boolean = remaining(s, now) <= 0.0

    /** Ran out more than [STALE_GRACE] ago: the person did not see it go then, so it doesn't go now. */
    fun isStale(s: ScheduledSend, now: Instant): Boolean = now.secondsSince(s.startedAt) - SECONDS > STALE_GRACE

    /** Whole seconds left, rounded up so it never reads "0 s" before it sends. */
    fun secondsLeft(s: ScheduledSend, now: Instant): Int = ceil(remaining(s, now) - 1e-9).toInt().coerceIn(0, SECONDS.toInt())

    fun headline(s: ScheduledSend, now: Instant): String = "Sending in ${secondsLeft(s, now)} s"

    /** What TalkBack hears: the same words and the one thing it can do. */
    fun spoken(s: ScheduledSend, now: Instant): String = "Sending in ${secondsLeft(s, now)} seconds. Undo is available."

    /** What a countdown's live receipt says to TalkBack: once, not every second (iOS doesn't speak every tick either). */
    const val SPOKEN = "Sending in a few seconds. Undo puts your message back in the box."
}

/**
 * A Yes or No after its tap in the room: the 1.2 s arm ring the decision sheet uses. Nothing has been sent; Cancel puts
 * it away, and it sends when the ring is full. The same row as iOS `YesNoArm`: "Sending “Yes” in 0.8 s · Cancel".
 */
data class YesNoArm(val word: String, val startedAt: Instant) {
    val deadline: Instant get() = startedAt.plusSeconds(ArmSpec.duration)

    fun remaining(now: Instant): Double = maxOf(0.0, ArmSpec.duration - now.secondsSince(startedAt))

    /** 0..1: how much of the ring is drawn. */
    fun progress(now: Instant): Double = ArmSpec.progress(now.secondsSince(startedAt))

    fun isDue(now: Instant): Boolean = ArmSpec.isComplete(now.secondsSince(startedAt))

    /** "Sending “Yes” in 0.8 s". */
    fun label(now: Instant): String = "Sending “$word” in ${String.format(java.util.Locale.US, "%.1f", remaining(now))} s"

    companion object {
        const val CANCEL = "Cancel"
    }
}

/** The countdown state machine: pure and immutable, so the store holds it and the tests drive it. */
data class SendOutbox(val entries: List<ScheduledSend> = emptyList()) {
    val isEmpty: Boolean get() = entries.isEmpty()

    fun schedule(s: ScheduledSend): SendOutbox = SendOutbox(entries + s)

    /** Undo: the entry leaves the outbox and its text comes back; null when it already fired (or was undone). */
    fun undo(id: String): Pair<SendOutbox, ScheduledSend?> {
        val hit = entries.firstOrNull { it.id == id } ?: return this to null
        return SendOutbox(entries.filter { it.id != id }) to hit
    }

    /** What has run out by [now]; those leave the outbox and are sent, oldest first. */
    fun due(now: Instant): Pair<SendOutbox, List<ScheduledSend>> {
        val fired = entries.filter { SendCountdown.isDue(it, now) }.sortedBy { it.startedAt }
        if (fired.isEmpty()) return this to emptyList()
        val ids = fired.map { it.id }.toSet()
        return SendOutbox(entries.filter { it.id !in ids }) to fired
    }

    /** The one a session's receipt shows: the next to fire. */
    fun next(sessionId: String): ScheduledSend? = entries.filter { it.sessionId == sessionId }.minByOrNull { it.startedAt }

    fun forSession(sessionId: String): List<ScheduledSend> = entries.filter { it.sessionId == sessionId }.sortedBy { it.startedAt }

    fun dropSession(sessionId: String): SendOutbox = SendOutbox(entries.filter { it.sessionId != sessionId })
}

/** What the store does when a countdown reaches 0. */
object OutboxFire {
    enum class Action { SEND, RESTORE }

    /** Sends unless the session has left the Mac's list meanwhile (then the text goes back in the box, unsent). Pure. */
    fun decide(sessionStillListed: Boolean): Action = if (sessionStillListed) Action.SEND else Action.RESTORE
}

/** A message that did not go, back in the composer with the reason. */
data class RestoredDraft(val sessionId: String, val text: String, val note: String)

object OutboxRestore {
    const val NOTE_KILLED = "Not sent — Page closed before the countdown ended. Your message is back here."
    const val NOTE_GONE = "Not sent — that session isn't on your Mac's list any more. Your message is back here."
    const val NOTE_PAGE_GONE = "Not sent — the page was answered or closed on your Mac first. Your message is back here."
    const val NOTE_SLEPT = "Not sent — Page was asleep when the countdown ended. Your message is back here."
    const val NOTE_PAGE_BUSY = "Not sent — that page couldn't take your reply just then. Your message is back here."
    const val NOTE_REPLY_FAILED = "Not sent — your reply didn't go through. Your message is back here."

    /**
     * What an app killed before 0 leaves: every message that was still counting becomes a restored draft. Nothing is
     * ever sent after a restart (the person did not see it go). Same session, several messages: one draft, in order. Pure.
     */
    fun afterKill(persisted: List<ScheduledSend>): List<RestoredDraft> =
        persisted.sortedBy { it.startedAt }.filter { it.text.isNotBlank() }.groupBy { it.sessionId }.map { (sid, list) ->
            RestoredDraft(sid, list.joinToString("\n\n") { it.text.trim() }, NOTE_KILLED)
        }

    fun gone(s: ScheduledSend): RestoredDraft = RestoredDraft(s.sessionId, s.text, if (s.pageId != null) NOTE_PAGE_GONE else NOTE_GONE)

    /** The countdown woke too late ([SendCountdown.isStale]): nothing goes, the text is back. */
    fun slept(s: ScheduledSend): RestoredDraft = RestoredDraft(s.sessionId, s.text, NOTE_SLEPT)

    /** A page Steer whose page no longer takes a written reply, or has another on its way: nothing goes, the text is back. */
    fun pageBusy(s: ScheduledSend): RestoredDraft = RestoredDraft(s.sessionId, s.text, NOTE_PAGE_BUSY)

    /**
     * A page Steer's reply after its countdown: the text comes back unless the relay took it (the countdown already
     * emptied the box, so a refusal must not lose the words). Pure.
     */
    fun afterReply(s: ScheduledSend, outcome: ReplyOutcome): RestoredDraft? = when (outcome) {
        is ReplyOutcome.Accepted -> null
        ReplyOutcome.Gone -> RestoredDraft(s.sessionId, s.text, NOTE_PAGE_GONE)
        else -> RestoredDraft(s.sessionId, s.text, NOTE_REPLY_FAILED)
    }

    /**
     * Undo or a restore into a composer that already has words: the returned text first, then what was typed since.
     * Words already in the box (the same text, or it still starts with it) are not added twice. iOS `DraftRestore.merge`.
     */
    fun merge(returned: String, current: String): String {
        val back = returned.trim()
        val now = current.trim()
        if (back.isEmpty()) return current
        if (now.isEmpty()) return back
        if (now == back || now.startsWith(back)) return current
        return back + "\n\n" + now
    }

    /** The persisted form: only what a restore needs (session id, text, when). The target is rebuilt when it is sent, never replayed. */
    fun encode(entries: List<ScheduledSend>): String =
        JsonArray(entries.map { e ->
            JsonObject(
                mapOf(
                    "id" to JsonPrimitive(e.id), "sessionId" to JsonPrimitive(e.sessionId), "text" to JsonPrimitive(e.text),
                    "at" to JsonPrimitive(e.startedAt.toEpochMilli()),
                ),
            )
        }).toString()

    fun decode(json: String?): List<ScheduledSend> {
        val array = json?.let { parseJson(it) } as? JsonArray ?: return emptyList()
        return array.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val id = o.str("id")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val sid = o.str("sessionId")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val text = o.str("text")?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            ScheduledSend(id, sid, text, null, Instant.ofEpochMilli(o.long("at") ?: 0L))
        }
    }
}
