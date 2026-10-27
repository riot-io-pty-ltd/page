package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/SessionTarget.swift. Steer safety, as plain values.
// Typing into the wrong session is the worst thing this app can do, so three
// small decisions live here where the logic tests can see them:
//
//   SessionTarget  what a room showed the user: the session, its folder, its
//                  terminal and Mac. Sent with every message and Stop so the
//                  Mac can refuse if the session behind the id is not that one.
//   RoomSend       what Send does for a given room, including every refusal:
//                  no Send path returns without a reason.
//   SendReceipt    the line under the room that names exactly where a message
//                  went (or why it did not).
//   DraftSubmit    the keyboard's Return/Send key.

// MARK: - Target

/** What a room showed the user about the session it types into. */
data class SessionTarget(
    val sessionId: String,
    /** The folder's last component ("riot-io-teltonika"); the title when the folder says nothing. */
    val project: String,
    val title: String,
    /** As the Mac listed it (home-abbreviated), verbatim: this is what travels. */
    val cwd: String,
    /** The terminal, "cmux"; empty when unknown. */
    val host: String,
    val macName: String,
    val agent: String,
) {
    /** First four characters of the id: tells two sessions in one project apart. */
    val shortId: String get() = Sw.prefix(sessionId, 4)

    /** "~/projects/riot-io-teltonika · #d8a3": the room's header line, so no two rooms read alike. */
    val whereLine: String
        get() {
            val folder = Sw.trimWsNl(cwd)
            return if (folder.isEmpty()) "#$shortId" else "$folder · #$shortId"
        }

    /** What goes on the wire as `expectCwd`: only a folder the Mac really listed. */
    val expectCwd: String?
        get() {
            val c = Sw.trimWsNl(cwd)
            return if (c.isEmpty()) null else c
        }

    /** What goes on the wire as `expectTitle`: the title the Mac sent (not one this phone made up). */
    val expectTitle: String?
        get() {
            val t = Sw.trimWsNl(title)
            return if (t.isEmpty() || t == "Session ${Sw.prefix(sessionId, 8)}") null else t
        }

    /** "riot-io-teltonika · cmux · Studio MBP": what a receipt and a preview name. */
    val route: String
        get() = listOfNotNull(project, if (host.isEmpty()) null else host, DeliveryPreview.macLabel(macName)).joinToString(" · ")

    companion object {
        fun of(s: LiveSession, macName: String = ""): SessionTarget {
            val h = Sw.trimWsNl(s.host)
            return SessionTarget(
                sessionId = s.id,
                project = SkyModel.projectName(s.cwd, s.title),
                title = s.title,
                cwd = s.cwd,
                host = if (h.lowercase() == "unknown") "" else h,
                macName = macName,
                agent = s.backend.displayName,
            )
        }
    }
}

// MARK: - What Send does

object RoomSend {
    sealed interface Decision {
        /** Type into this session (text plus Return), carrying what the room showed. */
        data class Input(val target: SessionTarget) : Decision

        /** The page's own path: Esc, then the text, then Return. */
        data object TellInstead : Decision

        /** Nothing is sent; say why. */
        data class Refuse(val why: String) : Decision
    }

    /**
     * One pure decision for Send, from the keyboard or the button. [shown] is the session the header drew;
     * [routeSessionId] is the id the room was opened for. They are always the same unless something is badly
     * wrong, and then nothing is typed. Every outcome that is not a send carries its reason.
     */
    fun decide(
        mode: RoomComposerMode, text: String, shown: LiveSession, routeSessionId: String,
        live: LiveSession?, ended: Boolean, hasReplyAction: Boolean, macName: String,
    ): Decision {
        if (shown.id != routeSessionId) {
            return Decision.Refuse("This room is showing a different session than it would type into, so nothing was sent. Close it and open the session again.")
        }
        return when (mode) {
            is RoomComposerMode.Locked -> Decision.Refuse(mode.why)
            is RoomComposerMode.Blocked -> Decision.Refuse(mode.why)
            is RoomComposerMode.Disabled -> Decision.Refuse(mode.why)
            is RoomComposerMode.TellInstead -> {
                if (!hasReplyAction) Decision.Refuse("This prompt's page isn't loaded yet, so nothing was sent. Answer on your Mac, or try again in a moment.")
                else if (Sw.trimWsNl(text).isEmpty()) Decision.Refuse(SessionComposer.Problem.Empty.message) else Decision.TellInstead
            }
            RoomComposerMode.Steer, RoomComposerMode.NextTask -> {
                if (ended || live == null) return Decision.Refuse("This session isn't on your Mac's list any more, so nothing was sent.")
                val v = SessionComposer.validate(text)
                if (v is SessionComposer.Validation.Bad) return Decision.Refuse(v.problem.message)
                Decision.Input(SessionTarget.of(shown, macName))
            }
        }
    }
}

// MARK: - The keyboard's Send key

object DraftSubmit {
    /**
     * True when a draft change is exactly one Return typed at the end: how the keyboard's Send key reaches a
     * multi-line field. A paste (more than one character) or a newline in the middle is not a send.
     */
    fun isReturnKey(old: String, new: String): Boolean = new == old + "\n"

    /**
     * One Return can reach `send` twice (the field's submit and the trailing newline): the same text again
     * within this window is that echo, not a second message.
     */
    const val duplicateWindow: Double = 1.0

    data class Last(val text: String, val at: Instant)

    fun isDuplicate(text: String, last: Last?, now: Instant): Boolean {
        if (last == null) return false
        val a = Sw.trimWsNl(text)
        val dt = now.secondsSince(last.at)
        return a == Sw.trimWsNl(last.text) && dt >= 0 && dt < duplicateWindow
    }

    /** The draft without that trailing Return. */
    fun withoutReturn(s: String): String = if (Sw.hasSuffix(s, "\n")) Sw.dropLast(s) else s
}

// MARK: - The receipt

/**
 * The line under the room after a send: where the message went, in the project's own name, on which terminal and
 * Mac, or why it did not.
 */
data class SendReceipt(
    val id: String,
    val headline: String,
    /** The target (or what was not done to it), as a second line. */
    val detail: String?,
    val tone: Tone,
) {
    enum class Tone { WORKING, GOOD, PROBLEM }

    companion object {
        /** Typed and queued fade after this long; a problem stays until dismissed or replaced. */
        const val goodVisibleFor: Double = 60.0
        const val problemVisibleFor: Double = 10 * 60.0

        /** The receipt for the newest message sent from this room, null once it is no longer news. Pure. */
        fun build(c: SentSessionCommand?, agent: String, now: Instant): SendReceipt? {
            if (c == null || c.kind != SessionCommandKind.INPUT) return null
            val age = now.secondsSince(c.sentAt)
            val route = c.target?.route
            val place = route ?: "the session"
            return when (val s = c.state) {
                SessionDeliveryState.Sending -> SendReceipt(c.clientId, "Sending to $place…", null, Tone.WORKING)
                is SessionDeliveryState.Typed -> if (age < goodVisibleFor) SendReceipt(c.clientId, "Typed into $place", null, Tone.GOOD) else null
                is SessionDeliveryState.Queued -> if (age < goodVisibleFor) SendReceipt(c.clientId, "Queued — $agent reads it after this step", route, Tone.GOOD) else null
                is SessionDeliveryState.Refused -> if (age < problemVisibleFor) SendReceipt(c.clientId, "Refused: ${s.message}", "Target: $place", Tone.PROBLEM) else null
                is SessionDeliveryState.Failed -> if (age < problemVisibleFor) SendReceipt(c.clientId, "Not sent: ${s.message}", "Target: $place", Tone.PROBLEM) else null
                SessionDeliveryState.NoAnswer -> if (age < problemVisibleFor) {
                    SendReceipt(
                        c.clientId, "No answer from ${DeliveryPreview.macLabel(c.target?.macName ?: "")}",
                        "It may still arrive in $place. Check the story before sending again.", Tone.PROBLEM,
                    )
                } else null
            }
        }

        /** Stop's line: names the same target. */
        fun stopLine(c: SentSessionCommand, agent: String): String? {
            if (c.kind != SessionCommandKind.INTERRUPT) return null
            val place = c.target?.route ?: "the session"
            return when (c.state) {
                SessionDeliveryState.Sending -> "Stopping $place…"
                is SessionDeliveryState.Typed, is SessionDeliveryState.Queued -> "Stopped · pressed Esc in $place"
                is SessionDeliveryState.Refused, is SessionDeliveryState.Failed, SessionDeliveryState.NoAnswer ->
                    "Couldn't stop $place: ${c.state.explanation(SessionCommandKind.INTERRUPT, agent) ?: ""}"
            }
        }
    }
}
