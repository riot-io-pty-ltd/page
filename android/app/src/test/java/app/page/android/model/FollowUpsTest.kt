package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The follow-ups to queued messages and photos: Delete after the relay forwarded a reply (and asking the Mac), a
 * final result replacing "No longer held", the 30 s fallback for a held message never seen listed, an unknown
 * `retract` value, the old-Mac note after the first list, a late `inputImages` result, the photo button when the Mac
 * stops offering photos, the Yes/No arm row, and a notification Delete during the POST. Every decision is pure.
 */
class FollowUpsTest {
    private val t0 = at(1_000_000.0)
    private val features = setOf("sessions-v1", "reply-retract-v1")

    private fun result(json: String, clientId: String = "c1"): CommandResult =
        (SessionsPlaintext.decode("""{"kind":"result","seq":1,"ts":1761300000000,"clientId":"$clientId",$json}""")!!.update as SessionsUpdate.Result).result

    // MARK: 1 and 2. Delete once the relay has forwarded a reply

    @Test fun `a pending reply the relay has forwarded is no longer queued, so Delete is not offered for it`() {
        val fwd = at(61_000.0)
        val queued = ReplyDelivery.synced(null, "pending", null, at(60_000.0), NOW, forwardedAt = null)
        val forwarded = ReplyDelivery.synced(null, "pending", null, at(60_000.0), NOW, forwardedAt = fwd)
        assertEquals(ReplyDelivery.Sent(true, at(60_000.0)), queued)
        assertEquals(ReplyDelivery.Sent(false, at(60_000.0)), forwarded)
        assertEquals(QueuedDelete.Layer.RELAY_QUEUE, QueuedDelete.reply(queued, false, features, emptySet()))
        assertNull(QueuedDelete.reply(forwarded, false, features, emptySet()))
        // The same news arriving for a reply that was queued a moment ago.
        assertEquals(forwarded, ReplyDelivery.synced(queued, "pending", null, at(60_000.0), NOW, forwardedAt = fwd))
    }

    @Test fun `409 forwarded asks the Mac when it advertises retract-v1, and nothing else does`() {
        val forwarded = ReplyRetract.Outcome.TooLate("forwarded")
        val caps = setOf("hold-v1", "retract-v1")
        assertTrue(ReplyRetract.chainsToMac(forwarded, caps))
        assertFalse("an older Mac ignores the op", ReplyRetract.chainsToMac(forwarded, setOf("hold-v1")))
        assertFalse("no list yet, no caps", ReplyRetract.chainsToMac(forwarded, emptySet()))
        assertFalse("delivered never chains: the Mac reported it typed", ReplyRetract.chainsToMac(ReplyRetract.Outcome.TooLate("delivered"), caps))
        for (o in listOf(ReplyRetract.Outcome.Deleted(), ReplyRetract.Outcome.NothingToDelete, ReplyRetract.Outcome.CouldntTakeBack, ReplyRetract.Outcome.HookHeld, ReplyRetract.Outcome.RelayTooOld, ReplyRetract.Outcome.PageGone)) {
            assertFalse(o.toString(), ReplyRetract.chainsToMac(o, caps))
        }
        assertEquals("Asking your Mac…", ReplyRetract.ASKING_MAC)
        // The relay's own answer to the DELETE still decodes to the chained case.
        assertEquals(forwarded, ReplyRetract.from(409, """{"error":"too_late","stage":"forwarded"}"""))
    }

    @Test fun `the Mac's answer to the follow-up retract becomes the delete's outcome, in the existing copy`() {
        // Deleted keeps the Mac's sentence, which may say what still happens at reset (iOS `ForwardedRetract.note`).
        assertEquals(
            "Deleted — not sent. Page will type your carry-on prompt when the limit resets",
            ReplyRetract.afterMac(MacRetract.Outcome.Deleted("Deleted — not sent. Page will type your carry-on prompt when the limit resets")).text,
        )
        assertEquals("Deleted — not sent", ReplyRetract.afterMac(MacRetract.Outcome.Deleted(null)).text)
        for (answer in listOf<MacRetract.Outcome?>(
            MacRetract.Outcome.TooLate("Too late — it was already typed"), MacRetract.Outcome.NotFound(null),
            MacRetract.Outcome.Failed(MacRetract.UNCONFIRMED), MacRetract.Outcome.Failed(MacRetract.OFFLINE), null,
        )) {
            assertEquals(answer.toString(), ReplyRetract.Outcome.TooLate("forwarded"), ReplyRetract.afterMac(answer))
        }
        // A refusal for another reason decided nothing: the Mac's own words, not "too late".
        assertEquals(
            ReplyRetract.Outcome.Failed("Typing from your phone is turned off"),
            ReplyRetract.afterMac(MacRetract.Outcome.Refused("Typing from your phone is turned off")),
        )
        assertEquals("Too late — your Mac already has it", ReplyRetract.afterMac(null).text)
        // Through the same mapping a plain DELETE goes through: deleted frees the page, too late is no longer queued.
        val queued = ReplyDelivery.Sent(true, t0)
        assertEquals(ReplyDelivery.Retracted("Deleted — not sent") to null, ReplyDelivery.afterRetract(queued, ReplyRetract.afterMac(MacRetract.Outcome.Deleted(null)), NOW))
        assertEquals(
            ReplyDelivery.Sent(false, t0) to "Too late — your Mac already has it",
            ReplyDelivery.afterRetract(queued, ReplyRetract.afterMac(null), NOW),
        )
        // The Mac's answer to a retract for a page, as the wire sends it.
        assertEquals(ReplyRetract.Outcome.Deleted("Deleted — not sent"), ReplyRetract.afterMac(MacRetract.outcome(result(""""ok":true,"code":"delivered","retract":"deleted","detail":"Deleted — not sent""""))))
        assertEquals(
            ReplyRetract.Outcome.TooLate("forwarded"),
            ReplyRetract.afterMac(MacRetract.outcome(result(""""ok":false,"code":"refused","reason":"not_found","retract":"not_found","detail":"Page isn't holding that message""""))),
        )
    }

    @Test fun `after the wait on the Mac a reply that moved on keeps its newer news`() {
        val queued = ReplyDelivery.Sent(true, t0)
        val late = ReplyRetract.Outcome.TooLate("forwarded")
        // Still being deleted: the ordinary mapping.
        assertEquals(ReplyDelivery.Sent(false, t0) to "Too late — your Mac already has it", ReplyDelivery.afterMacFollowUp(ReplyDelivery.Retracting, queued, late, NOW).let { (n, t) -> n?.let { it } to t })
        assertEquals(ReplyDelivery.Retracted("Deleted — not sent") to null, ReplyDelivery.afterMacFollowUp(ReplyDelivery.Retracting, queued, ReplyRetract.Outcome.Deleted(), NOW))
        // The Mac typed it and said so while it was asked: Delivered stays, with no "too late" over it.
        assertEquals(null to null, ReplyDelivery.afterMacFollowUp(ReplyDelivery.Delivered("Typed into tmux"), queued, late, NOW))
        // Its own `retracted` frame came first: the Mac's detail stays.
        assertEquals(null to null, ReplyDelivery.afterMacFollowUp(ReplyDelivery.Retracted("Deleted — not sent. Nothing will be typed at reset"), queued, ReplyRetract.Outcome.Deleted(), NOW))
        assertEquals(null to null, ReplyDelivery.afterMacFollowUp(ReplyDelivery.Failed("Your Mac couldn't deliver the reply."), queued, late, NOW))
        // Still on its way: a too late is noted, and it is no longer queued.
        assertEquals(ReplyDelivery.Sent(false, t0) to "Too late — your Mac already has it", ReplyDelivery.afterMacFollowUp(queued, queued, late, NOW))
        assertEquals("already not queued: only the note", null to "Too late — your Mac already has it", ReplyDelivery.afterMacFollowUp(ReplyDelivery.Sent(false, t0), queued, late, NOW))
        assertEquals(null to null, ReplyDelivery.afterMacFollowUp(ReplyDelivery.Sent(false, t0), queued, ReplyRetract.Outcome.Deleted(), NOW))
        // The Mac's refusal: its words as the note, and the reply is no longer queued (the relay already handed it over).
        val refused = ReplyRetract.Outcome.Failed("Typing from your phone is turned off")
        assertEquals(ReplyDelivery.Sent(false, t0) to refused.text, ReplyDelivery.afterMacFollowUp(ReplyDelivery.Retracting, queued, refused, NOW))
        assertEquals(ReplyDelivery.Sent(false, t0) to refused.text, ReplyDelivery.afterMacFollowUp(queued, queued, refused, NOW))
        // The notification reads the Mac's sentence for a delete it made.
        assertEquals(QueuedReplyNotification.Plan(null, "Deleted — not sent. Nothing will be typed at reset"),
            QueuedReplyNotification.after(ReplyRetract.Outcome.Deleted("Deleted — not sent. Nothing will be typed at reset")))
    }

    // MARK: 3. A final fromHold result replaces "No longer held"

    @Test fun `a final fromHold result replaces No longer held, and nothing else does`() {
        val gone = SessionDeliveryState.CheckSession(HeldMessages.NO_LONGER_HELD)
        val typed = result(""""ok":true,"code":"delivered","fromHold":true,"detail":"Typed into tmux pane %3"""")
        assertEquals(SessionDeliveryState.Typed("Typed into tmux pane %3"), gone.applying(typed, "Claude"))
        assertEquals(
            SessionDeliveryState.Deleted("Deleted — not sent"),
            gone.applying(result(""""ok":false,"code":"cancelled","reason":"cancelled","fromHold":true,"detail":"Deleted — not sent""""), "Claude"),
        )
        assertEquals(
            SessionDeliveryState.Refused("ended", "Not sent — the session ended"),
            gone.applying(result(""""ok":false,"code":"refused","reason":"ended","fromHold":true,"detail":"Not sent — the session ended""""), "Claude"),
        )
        assertEquals(
            "Not sent — the turn didn't finish within 6 hours",
            (gone.applying(result(""""ok":false,"code":"refused","reason":"expired","fromHold":true,"detail":"Not sent — the turn didn't finish within 6 hours""""), "Claude") as SessionDeliveryState.Refused).message,
        )
        assertTrue(gone.applying(result(""""ok":false,"code":"failed","reason":"error","fromHold":true,"detail":"Not sent — it failed""""), "Claude") is SessionDeliveryState.Failed)
        // A result that isn't the held message's final one is a repeat, as before.
        assertEquals(gone, gone.applying(result(""""ok":true,"code":"delivered","detail":"Typed into cmux""""), "Claude"))
        // The other check-the-session states are the Mac's own word, or a photo send's no-answer: they stay.
        val restarted = SessionDeliveryState.CheckSession(HeldMessages.UNCONFIRMED_COPY)
        assertEquals(restarted, restarted.applying(typed, "Claude"))
        val noAnswer = SessionDeliveryState.CheckSession(PhotoUploader.NO_ANSWER)
        assertEquals(noAnswer, noAnswer.applying(typed, "Claude"))
        assertTrue(gone.isNoLongerHeld)
        assertFalse(restarted.isNoLongerHeld)
    }

    // MARK: 4. A held message never seen listed

    @Test fun `a held message a later list lacks, more than 30 s after it was sent, reads No longer held`() {
        val h = SessionDeliveryState.Held(null)
        val gone = SessionDeliveryState.CheckSession(HeldMessages.NO_LONGER_HELD)
        val sent = t0
        fun settle(secondsLater: Double, seen: Boolean = false, listed: Boolean = true, disabled: Boolean = false, state: SessionDeliveryState = h) =
            HeldMessages.settle(state, null, seen = seen, sessionListed = listed, sentAt = sent, now = sent.plusSeconds(secondsLater), macDisabled = disabled)
        assertEquals(30.0, HeldMessages.MISSING_AFTER, 0.0)
        assertEquals("a list built before the Mac took it lacks it too", h, settle(5.0))
        assertEquals("exactly 30 s is not yet more than 30 s", h, settle(30.0))
        assertEquals(gone, settle(30.5))
        assertEquals(gone, settle(600.0))
        assertEquals("a Mac with live sessions turned off sends an empty list on purpose", h, settle(600.0, disabled = true))
        // The other ways in are as before.
        assertEquals(gone, settle(1.0, seen = true))
        assertEquals(gone, settle(1.0, listed = false))
        // Only a held message: anything else is never undone by a list.
        assertEquals(SessionDeliveryState.Sending, settle(600.0, state = SessionDeliveryState.Sending))
        assertEquals(SessionDeliveryState.Typed("x"), settle(600.0, state = SessionDeliveryState.Typed("x")))
        // Callers that pass no clock get the old behaviour.
        assertEquals(h, HeldMessages.settle(h, null, seen = false))
        // The entry is there: it settles as it always did, however late.
        val entry = HeldMessage("c7", "t", t0, HeldMessage.State.HELD, null, null)
        assertEquals(h, HeldMessages.settle(h, entry, seen = false, sessionListed = true, sentAt = sent, now = sent.plusSeconds(600.0)))
    }

    // MARK: 5. Held detail as a secondary note

    @Test fun `a held entry that carries a detail shows it as a note under the headline`() {
        val h = SessionDeliveryState.Held("Held — Page types it when Claude finishes this turn")
        val entry = HeldMessage("c7", "t", t0, HeldMessage.State.HELD, null, "Someone is typing at the Mac")
        val noted = HeldMessages.settle(h, entry, seen = true)
        assertEquals(h.copy(note = "Someone is typing at the Mac"), noted)
        // From a bare Sending (the result never arrived), the list alone gives the headline and the note.
        assertEquals(SessionDeliveryState.Held(null, "Someone is typing at the Mac"), HeldMessages.settle(SessionDeliveryState.Sending, entry, seen = true))
        assertEquals("Held — sends when Claude finishes", HeldMessages.heldHeadline(null))
        val sent = SentSessionCommand("c7", "s1", SessionCommandKind.INPUT, "Then run the linter", t0, noted)
        val receipt = SendReceipt.build(sent, "Claude", t0.plusSeconds(5.0))!!
        assertEquals("Held — Page types it when Claude finishes this turn", receipt.headline)
        assertEquals("Someone is typing at the Mac", receipt.detail)
        assertEquals(SendReceipt.Tone.HELD, receipt.tone)
        // The words a screen reader gets carry both.
        assertTrue(noted.spokenBubbleStatus(SessionCommandKind.INPUT, "Claude").contains("Someone is typing at the Mac"))
    }

    // MARK: 6. An unknown retract value

    @Test fun `an unknown retract value is a refusal in the Mac's words, never a delete`() {
        val r = result(""""ok":true,"code":"delivered","retract":"deferred","detail":"Page will delete it when the turn ends"""")
        assertEquals(CommandResult.Retract.UNKNOWN, r.retract)
        assertEquals(MacRetract.Outcome.Refused("Page will delete it when the turn ends"), MacRetract.outcome(r))
        val bare = result(""""ok":true,"code":"delivered","retract":"deferred"""")
        assertTrue("no detail: the refusal copy a refused result has", MacRetract.outcome(bare) is MacRetract.Outcome.Refused)
        // An empty or missing value is no value: code and ok still speak (as iOS).
        assertNull(result(""""ok":true,"code":"delivered","retract":""""").retract)
        assertEquals(MacRetract.Outcome.Deleted("Deleted — not sent"), MacRetract.outcome(result(""""ok":true,"code":"delivered","retract":"","detail":"Deleted — not sent"""")))
        // The three known values read as before.
        assertEquals(CommandResult.Retract.DELETED, result(""""ok":true,"code":"delivered","retract":"deleted"""").retract)
        assertEquals(CommandResult.Retract.TOO_LATE, result(""""ok":false,"code":"refused","retract":"too_late"""").retract)
        assertEquals(CommandResult.Retract.NOT_FOUND, result(""""ok":false,"code":"refused","retract":"not_found"""").retract)
    }

    // MARK: 7. The old-Mac note, after the first list

    @Test fun `the Update Page on your Mac note waits for the first list, the others do not`() {
        val held = ReplyDelivery.HeldOnMac("Will send it when the limit resets at 3:00 PM")
        assertNull("caps are unknown until a list arrives", QueuedDelete.whyNot(held, false, features, emptySet(), hasList = false))
        assertEquals("Update Page on your Mac to delete a held reply.", QueuedDelete.whyNot(held, false, features, emptySet(), hasList = true))
        assertNull("a Mac that can retract has nothing to say", QueuedDelete.whyNot(held, false, features, setOf("retract-v1"), hasList = true))
        val queued = ReplyDelivery.Sent(true, t0)
        assertEquals("Update your relay to delete queued replies.", QueuedDelete.whyNot(queued, false, setOf("sessions-v1"), emptySet(), hasList = false))
        assertEquals("Waiting on the hook. It can't be deleted from here.", QueuedDelete.whyNot(queued, true, features, emptySet(), hasList = false))
        // Before `/status` answers, the relay's age is not known: nothing is said (iOS), and no Delete is offered either.
        assertNull("relay features not known yet", QueuedDelete.whyNot(queued, false, null, emptySet(), hasList = true))
        assertNull(QueuedDelete.reply(queued, false, null, emptySet()))
    }

    // MARK: 8. A late inputImages result

    @Test fun `a late inputImages result is kept for 5 minutes, once, and forgotten when it came the ordinary way`() {
        val late = LatePhotoResults()
        late.remember("c9", LatePhotoResults.Entry("bubble1", 2, "image", t0))
        assertEquals(1, late.size)
        assertNull("another command", late.take("c10", t0))
        assertEquals("bubble1", late.take("c9", t0.plusSeconds(299.0))?.bubbleId)
        assertNull("once", late.take("c9", t0.plusSeconds(300.0)))
        late.remember("c9", LatePhotoResults.Entry("bubble1", 2, "image", t0))
        assertEquals(5 * 60.0, LatePhotoResults.KEEP_SECONDS, 0.0)
        assertNull("older than 5 minutes", late.take("c9", t0.plusSeconds(301.0)))
        late.remember("c8", LatePhotoResults.Entry("bubble2", 1, null, t0))
        late.forget("c8")
        assertNull(late.take("c8", t0))
        // Bounded.
        repeat(LatePhotoResults.MAX_ENTRIES + 10) { late.remember("x$it", LatePhotoResults.Entry("b$it", 1, null, t0)) }
        assertEquals(LatePhotoResults.MAX_ENTRIES, late.size)
        assertNull("the oldest went first", late.take("x0", t0))
        assertNotNull(late.take("x${LatePhotoResults.MAX_ENTRIES + 9}", t0))
        late.clear()
        assertEquals(0, late.size)
    }

    @Test fun `a late result settles a photo bubble the phone had given up on, and only that`() {
        val ok = result(""""ok":true,"code":"delivered","attached":2,"detail":"Sent 2 photos to Claude in tmux pane %3"""")
        val settled = SessionDeliveryState.Typed("Sent 2 photos to Claude in tmux pane %3", 2)
        // 30 s without an answer.
        assertEquals(settled, SessionDeliveryState.CheckSession(PhotoUploader.NO_ANSWER).afterLatePhotoResult(ok, "Claude"))
        assertEquals(settled, SessionDeliveryState.NoAnswer.afterLatePhotoResult(ok, "Claude"))
        // A POST whose answer was lost.
        assertEquals(settled, SessionDeliveryState.Failed("Couldn't reach your relay: timeout").afterLatePhotoResult(ok, "Claude"))
        assertEquals(settled, SessionDeliveryState.Sending.afterLatePhotoResult(ok, "Claude"))
        // A refusal is a result too.
        val refused = result(""""ok":false,"code":"refused","reason":"attach_busy","detail":"Claude is working — send the photo when it finishes"""")
        assertEquals(
            SessionDeliveryState.Refused("attach_busy", "Claude is working — send the photo when it finishes"),
            SessionDeliveryState.CheckSession(PhotoUploader.NO_ANSWER).afterLatePhotoResult(refused, "Claude"),
        )
        // A bubble that already has the Mac's word keeps it.
        val typed = SessionDeliveryState.Typed("Sent 1 photo", 1)
        assertEquals(typed, typed.afterLatePhotoResult(ok, "Claude"))
        val other = SessionDeliveryState.CheckSession(HeldMessages.UNCONFIRMED_COPY)
        assertEquals(other, other.afterLatePhotoResult(ok, "Claude"))
        assertEquals(SessionDeliveryState.Deleted("x"), SessionDeliveryState.Deleted("x").afterLatePhotoResult(ok, "Claude"))
    }

    // MARK: 9. The words of a photo send

    @Test fun `once inputImages is out the line says where the Mac is typing, with the host`() {
        assertEquals("Typing into tmux…", PhotoCopy.typing("tmux"))
        assertEquals("Typing into cmux…", PhotoCopy.typing(" cmux "))
        assertEquals("Typing into the session…", PhotoCopy.typing(null))
        assertEquals("Typing into the session…", PhotoCopy.typing(""))
        assertEquals("Uploading 3 of 8", PhotoCopy.uploading(3, 8))
        val photo = SentSessionCommand(
            "c1", "s1", SessionCommandKind.INPUT, "", t0, SessionDeliveryState.Sending, photos = 2,
            target = SessionTarget("s1", "page", "page", "~/p", "tmux", "Mac", "Claude"),
        )
        val waiting = PhotoProgress(8, 8, PhotoProgress.Phase.WAITING)
        assertEquals("Typing into tmux…", SendReceipt.build(photo, "Claude", t0, uploading = waiting)!!.detail)
        assertEquals("Uploading 3 of 8", SendReceipt.build(photo, "Claude", t0, uploading = PhotoProgress(3, 8, PhotoProgress.Phase.UPLOADING))!!.detail)
    }

    // MARK: 11. A notification's Delete during the POST

    @Test fun `a Delete pressed while the POST was in flight says why nothing was deleted`() {
        // The relay forwarded it at once: the Mac has it.
        val forwarded = QueuedReplyNotification.afterDeleteDuringSend(queued = false, relayFeatures = features, hookBlocking = false)!!
        assertEquals("Too late — your Mac already has it", forwarded.status)
        assertFalse("nothing left to delete", forwarded.deleteAgain)
        // The relay queued it and can take it back: ask it.
        assertNull(QueuedReplyNotification.afterDeleteDuringSend(queued = true, relayFeatures = features, hookBlocking = false))
        // The relay queued it and is too old to delete: say so.
        assertEquals("Update your relay to delete queued replies", QueuedReplyNotification.afterDeleteDuringSend(queued = true, relayFeatures = setOf("sessions-v1"), hookBlocking = false)!!.status)
        assertEquals("Update your relay to delete queued replies", QueuedReplyNotification.afterDeleteDuringSend(queued = true, relayFeatures = null, hookBlocking = false)!!.status)
        // A hook polls the page.
        assertEquals(ReplyRetract.Outcome.HookHeld.text, QueuedReplyNotification.afterDeleteDuringSend(queued = true, relayFeatures = features, hookBlocking = true)!!.status)
    }

    // MARK: 12. The Yes/No arm row

    @Test fun `a tapped Yes reads Sending Yes in 0_8 s with Cancel, and runs out after 1_2 s`() {
        val arm = YesNoArm("Yes", t0)
        assertEquals("Sending “Yes” in 1.2 s", arm.label(t0))
        assertEquals("Sending “Yes” in 0.8 s", arm.label(t0.plusMillis(400)))
        assertEquals("Sending “No” in 0.0 s", YesNoArm("No", t0).label(t0.plusSeconds(5.0)))
        assertEquals("Cancel", YesNoArm.CANCEL)
        assertEquals(0.0, arm.progress(t0), 1e-9)
        assertEquals(0.5, arm.progress(t0.plusMillis(600)), 1e-9)
        assertEquals(1.0, arm.progress(t0.plusSeconds(9.0)), 1e-9)
        assertFalse(arm.isDue(t0.plusMillis(1100)))
        assertTrue(arm.isDue(t0.plusMillis(1200)))
        assertEquals(ArmSpec.duration, arm.remaining(t0), 1e-9)
        assertEquals(t0.plusMillis(1200), arm.deadline)
        // A locale with a decimal comma still says "0.8".
        val saved = java.util.Locale.getDefault()
        try {
            java.util.Locale.setDefault(java.util.Locale.GERMANY)
            assertEquals("Sending “Yes” in 0.8 s", arm.label(t0.plusMillis(400)))
        } finally {
            java.util.Locale.setDefault(saved)
        }
    }
}
