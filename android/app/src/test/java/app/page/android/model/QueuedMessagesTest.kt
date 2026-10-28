package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Queued messages (docs/SESSIONS-PROTOCOL.md "Holding a message until the turn ends", "Taking a message back";
 * docs/PROTOCOL.md `DELETE /reply/:id`): choosing how a message to a busy session goes, the 10 s Undo, held
 * messages and how they settle, and Delete for everything queued and not yet sent. Every decision is pure.
 */
class QueuedMessagesTest {
    private val t0 = at(1_000_000.0)

    private fun row(extra: String = "", state: String = "active", canType: Boolean = true, canHold: Boolean = true): LiveSession =
        LiveSession.decode(
            parseJson(
                """{"id":"s1","backend":"claude","title":"page","cwd":"~/projects/page","state":"$state","host":"cmux","canType":$canType,
                    "canHold":$canHold $extra}""",
            )!!,
        )!!

    private fun result(json: String): CommandResult =
        (SessionsPlaintext.decode("""{"kind":"result","seq":1,"ts":1761300000000,"clientId":"c1",$json}""")!!.update as SessionsUpdate.Result).result

    // MARK: wire

    @Test fun `the list header's caps, a row's canHold and held entries decode, and a Mac without them reads as empty`() {
        val p = SessionsPlaintext.decode(
            """{"kind":"list","boot":"b","seq":1,"ts":1761300000000,"caps":["hold-v1","retract-v1","images-v1","future-v9"],
                "sessions":[{"id":"s1","state":"active","canHold":true,"held":[
                  {"clientId":"c7","text":"Then run the linter","heldAt":"2026-10-24T12:00:00Z","state":"held"},
                  {"clientId":"c8","text":"x","heldAt":"2026-10-24T12:01:00Z","state":"deleted","at":"2026-10-24T12:02:00Z","detail":"Deleted — not sent"},
                  {"clientId":"c9","text":"y","state":"someFutureState"},
                  {"text":"no id","state":"held"}]}]}""",
        )!!
        val list = p.update as SessionsUpdate.ListUpdate
        assertEquals(setOf("hold-v1", "retract-v1", "images-v1", "future-v9"), list.caps)
        val s = list.sessions.single()
        assertTrue(s.canHold)
        assertEquals("only entries with an id survive; an unknown state is kept (iOS .unknown)", listOf("c7", "c8", "c9"), s.held.map { it.clientId })
        assertEquals(HeldMessage.State.UNKNOWN, s.held[2].state)
        assertFalse(s.held[2].isWaiting)
        assertEquals(HeldMessage.State.HELD, s.held[0].state)
        assertTrue(s.held[0].isWaiting)
        assertEquals("Deleted — not sent", s.held[1].detail)
        assertNotNull(s.held[1].at)

        val old = SessionsPlaintext.decode("""{"kind":"list","boot":"b","seq":1,"ts":1761300000000,"sessions":[{"id":"s1","state":"active"}]}""")!!.update as SessionsUpdate.ListUpdate
        assertEquals(emptySet<String>(), old.caps)
        assertFalse(old.sessions.single().canHold)
        assertEquals(emptyList<HeldMessage>(), old.sessions.single().held)
    }

    @Test fun `a result's held, fromHold and retract fields decode, and cancelled is a code of its own`() {
        val held = result(""""ok":true,"code":"queued","held":true,"detail":"Held — Page types it when Claude finishes this turn"""")
        assertTrue(held.held)
        assertFalse(held.fromHold)
        val fin = result(""""ok":false,"code":"cancelled","reason":"cancelled","fromHold":true,"detail":"Deleted — not sent"""")
        assertEquals(CommandResult.Code.CANCELLED, fin.code)
        assertTrue(fin.fromHold)
        assertEquals(CommandResult.Retract.DELETED, result(""""ok":true,"code":"delivered","retract":"deleted"""").retract)
        assertEquals(CommandResult.Retract.TOO_LATE, result(""""ok":false,"code":"refused","reason":"too_late","retract":"too_late"""").retract)
        assertEquals(CommandResult.Retract.NOT_FOUND, result(""""ok":false,"code":"refused","reason":"not_found","retract":"not_found"""").retract)
        assertNull(result(""""ok":true,"code":"delivered"""").retract)
        // An unknown code with ok:false still reads as failed (older apps, newer Macs).
        assertEquals(CommandResult.Code.FAILED, result(""""ok":false,"code":"somethingNew"""").code)
    }

    @Test fun `input carries hold only when true, retract names exactly the message, and an old Mac sees the same input bytes`() {
        fun obj(c: SessionCommand) = parseJsonObject(String(c.plaintext("c", "v", CMD_NOW), Charsets.UTF_8))!!
        assertNull("not held: the same bytes as before", obj(SessionCommand.Input("s1", "hi"))["hold"])
        assertNull(obj(SessionCommand.Input("s1", "hi", hold = false))["hold"])
        assertEquals(JsonPrimitive(true), obj(SessionCommand.Input("s1", "hi", hold = true))["hold"])
        val byHeld = obj(SessionCommand.Retract(heldId = "c7"))
        assertEquals("retract", (byHeld["op"] as JsonPrimitive).content)
        assertEquals("c7", (byHeld["heldId"] as JsonPrimitive).content)
        assertNull(byHeld["interventionId"])
        val byPage = obj(SessionCommand.Retract(interventionId = "p9"))
        assertEquals("p9", (byPage["interventionId"] as JsonPrimitive).content)
        assertNull(byPage["heldId"])
    }

    // MARK: choice availability

    @Test fun `an idle session offers no choice and sends at once`() {
        assertNull(SendChoice.plan(busy = false, canTypeNow = true, canHold = true, last = null))
        assertNull(SendChoice.forSession(row(state = "idle"), ended = false, caps = setOf("hold-v1"), last = null))
    }

    @Test fun `busy with hold-v1 and canHold offers both, defaulting to the last choice`() {
        val caps = setOf("hold-v1")
        val first = SendChoice.forSession(row(), false, caps, null)!!
        assertEquals(listOf(SendWhen.NOW, SendWhen.WHEN_FINISHED), first.offered)
        assertEquals(SendWhen.NOW, first.selected)
        assertTrue(first.isChoice)
        assertEquals(SendWhen.WHEN_FINISHED, SendChoice.forSession(row(), false, caps, SendWhen.WHEN_FINISHED)!!.selected)
    }

    @Test fun `without hold-v1 or canHold only Now is offered, which still counts down`() {
        val noCaps = SendChoice.forSession(row(), false, emptySet(), SendWhen.WHEN_FINISHED)!!
        assertEquals(listOf(SendWhen.NOW), noCaps.offered)
        assertEquals("a remembered hold is not selected when it can't be offered", SendWhen.NOW, noCaps.selected)
        assertFalse(noCaps.isChoice)
        val noRow = SendChoice.forSession(row(canHold = false), false, setOf("hold-v1"), null)!!
        assertEquals(listOf(SendWhen.NOW), noRow.offered)
    }

    @Test fun `a busy session Page can't type into but the Mac can hold for offers only When it finishes`() {
        val codex = row(canType = false, canHold = true)
        val plan = SendChoice.forSession(codex, false, setOf("hold-v1"), SendWhen.NOW)!!
        assertEquals(listOf(SendWhen.WHEN_FINISHED), plan.offered)
        assertEquals(SendWhen.WHEN_FINISHED, plan.selected)
        assertTrue(plan.holdOnly)
        assertNull("no hold-v1: nothing can be sent", SendChoice.forSession(codex, false, emptySet(), null))
        assertNull("an ended session offers nothing", SendChoice.forSession(codex, true, setOf("hold-v1"), null))
    }

    @Test fun `the composer is HoldOnly for that Codex row, Blocked without hold, and Steer when Page can type`() {
        fun mode(canType: Boolean, canHold: Boolean, state: LiveSessionState = LiveSessionState.ACTIVE) = RoomComposerMode.resolve(
            RoomComposerMode.Inputs(state = state, canType = canType, typeBlocker = "Page can't type into Codex yet", canHold = canHold),
        )
        assertEquals(RoomComposerMode.HoldOnly, mode(canType = false, canHold = true))
        assertTrue(mode(canType = false, canHold = false) is RoomComposerMode.Blocked)
        assertTrue("an idle session that can't be typed into stays blocked", mode(canType = false, canHold = true, state = LiveSessionState.IDLE) is RoomComposerMode.Blocked)
        assertEquals(RoomComposerMode.Steer, mode(canType = true, canHold = true))
        assertTrue(RoomComposerMode.HoldOnly.acceptsText)
        assertTrue(RoomComposerMode.HoldOnly.usesSessionInput)
    }

    @Test fun `Send follows the choice, and HoldOnly can only hold`() {
        val s = row()
        val plan = SendChoice.Plan(listOf(SendWhen.NOW, SendWhen.WHEN_FINISHED), SendWhen.WHEN_FINISHED)
        fun decide(mode: RoomComposerMode, choice: SendChoice.Plan?) = RoomSend.decide(mode, "hi", s, "s1", s, false, true, "Mac", choice)
        assertEquals(SendWhen.WHEN_FINISHED, (decide(RoomComposerMode.Steer, plan) as RoomSend.Decision.Input).sendWhen)
        assertEquals(SendWhen.NOW, (decide(RoomComposerMode.Steer, plan.copy(selected = SendWhen.NOW)) as RoomSend.Decision.Input).sendWhen)
        assertEquals("no plan: now", SendWhen.NOW, (decide(RoomComposerMode.Steer, null) as RoomSend.Decision.Input).sendWhen)
        assertEquals(SendWhen.WHEN_FINISHED, (decide(RoomComposerMode.HoldOnly, null) as RoomSend.Decision.Input).sendWhen)
        assertEquals(SendWhen.NOW, (decide(RoomComposerMode.NextTask, plan) as RoomSend.Decision.Input).sendWhen)
        assertTrue(decide(RoomComposerMode.Disabled("x"), plan) is RoomSend.Decision.Refuse)
    }

    @Test fun `the delivery preview follows the selected side`() {
        val c = AgentCharacter.from(AgentBackend.fromWire("claude"), null)
        assertEquals("Your message, then Return · queues after this step · cmux › page · Mac", RoomComposerMode.Steer.preview(c, "cmux › page", "Mac"))
        assertEquals("Held on your Mac · typed when Claude finishes · cmux › page · Mac", RoomComposerMode.Steer.preview(c, "cmux › page", "Mac", sendWhen = SendWhen.WHEN_FINISHED))
        assertEquals("Held on your Mac · typed when Claude finishes · cmux › page · Mac", RoomComposerMode.HoldOnly.preview(c, "cmux › page", "Mac"))
    }

    // MARK: the 10 s countdown

    private fun scheduled(id: String = "a", session: String = "s1", text: String = "hello", at: Instant = t0) = ScheduledSend(id, session, text, null, at)

    @Test fun `the countdown reads 10 s, counts down, and is due at 0`() {
        val s = scheduled()
        assertEquals(10.0, SendCountdown.SECONDS, 0.0)
        assertEquals("Sending in 10 s", SendCountdown.headline(s, t0))
        assertEquals("Sending in 10 s", SendCountdown.headline(s, t0.plusSeconds(0.2)))
        assertEquals("Sending in 5 s", SendCountdown.headline(s, t0.plusSeconds(5.5)))
        assertEquals("Sending in 1 s", SendCountdown.headline(s, t0.plusSeconds(9.99)))
        assertFalse(SendCountdown.isDue(s, t0.plusSeconds(9.99)))
        assertTrue(SendCountdown.isDue(s, t0.plusSeconds(10.0)))
        assertEquals("never negative", 0.0, SendCountdown.remaining(s, t0.plusSeconds(60.0)), 0.0)
    }

    @Test fun `Undo takes the entry out and gives its text back, after it fired there is nothing to undo`() {
        val box = SendOutbox().schedule(scheduled("a", text = "first")).schedule(scheduled("b", text = "second", at = t0.plusSeconds(3.0)))
        val (afterUndo, hit) = box.undo("a")
        assertEquals("first", hit?.text)
        assertEquals(listOf("b"), afterUndo.entries.map { it.id })
        val (again, nothing) = afterUndo.undo("a")
        assertNull(nothing)
        assertEquals(afterUndo, again)
        val (afterFire, fired) = box.due(t0.plusSeconds(10.5))
        assertEquals(listOf("a"), fired.map { it.id })
        assertEquals("the second is still counting", listOf("b"), afterFire.entries.map { it.id })
        assertNull("undo after it fired", afterFire.undo("a").second)
        assertEquals(listOf("a", "b"), box.due(t0.plusSeconds(20.0)).second.map { it.id })
        assertTrue(box.due(t0.plusSeconds(1.0)).second.isEmpty())
    }

    @Test fun `a session's receipt shows the next to fire, and leaving a session's room cancels nothing`() {
        val box = SendOutbox().schedule(scheduled("b", text = "later", at = t0.plusSeconds(2.0))).schedule(scheduled("a", at = t0)).schedule(scheduled("c", session = "s2"))
        assertEquals("a", box.next("s1")?.id)
        assertEquals(listOf("a", "b"), box.forSession("s1").map { it.id })
        // The outbox is the app's, not a screen's: nothing here is keyed on a room being open.
        assertEquals(3, box.entries.size)
    }

    @Test fun `when the countdown ends it sends, unless the session has left the list, then the text goes back unsent`() {
        assertEquals(OutboxFire.Action.SEND, OutboxFire.decide(sessionStillListed = true))
        assertEquals(OutboxFire.Action.RESTORE, OutboxFire.decide(sessionStillListed = false))
        val d = OutboxRestore.gone(scheduled(text = "keep me"))
        assertEquals("keep me", d.text)
        assertEquals(OutboxRestore.NOTE_GONE, d.note)
    }

    @Test fun `a countdown the phone slept through is not sent - the text goes back with why`() {
        val s = scheduled(text = "keep me")
        assertFalse("on time", SendCountdown.isStale(s, t0.plusSeconds(10.0)))
        assertFalse("a little late is still the send the person saw", SendCountdown.isStale(s, t0.plusSeconds(10.0 + SendCountdown.STALE_GRACE)))
        assertTrue("woke well past its end", SendCountdown.isStale(s, t0.plusSeconds(10.0 + SendCountdown.STALE_GRACE + 1)))
        val d = OutboxRestore.slept(s)
        assertEquals("keep me", d.text)
        assertEquals("s1", d.sessionId)
        assertEquals(OutboxRestore.NOTE_SLEPT, d.note)
    }

    @Test fun `a page Steer whose reply can't go after its countdown comes back to the box - never lost`() {
        val s = ScheduledSend("a", "s1", "steer it", null, t0, pageId = "p1")
        assertNull("the relay took it", OutboxRestore.afterReply(s, ReplyOutcome.Accepted(queued = false)))
        assertNull(OutboxRestore.afterReply(s, ReplyOutcome.Accepted(queued = true)))
        assertEquals(RestoredDraft("s1", "steer it", OutboxRestore.NOTE_PAGE_GONE), OutboxRestore.afterReply(s, ReplyOutcome.Gone))
        for (o in listOf(ReplyOutcome.AlreadyReplied, ReplyOutcome.InFlight, ReplyOutcome.Unauthorized, ReplyOutcome.Retired("why"), ReplyOutcome.Failed("no network"))) {
            assertEquals(o.toString(), RestoredDraft("s1", "steer it", OutboxRestore.NOTE_REPLY_FAILED), OutboxRestore.afterReply(s, o))
        }
        assertEquals(RestoredDraft("s1", "steer it", OutboxRestore.NOTE_PAGE_BUSY), OutboxRestore.pageBusy(s))
    }

    @Test fun `an app killed before 0 sends nothing - the drafts come back, per session, with a note`() {
        val persisted = OutboxRestore.decode(
            OutboxRestore.encode(listOf(scheduled("a", "s1", "one"), scheduled("b", "s1", "two", t0.plusSeconds(1.0)), scheduled("c", "s2", "three"))),
        )
        assertEquals(3, persisted.size)
        val drafts = OutboxRestore.afterKill(persisted).associateBy { it.sessionId }
        assertEquals("one\n\ntwo", drafts["s1"]?.text)
        assertEquals("three", drafts["s2"]?.text)
        assertTrue(drafts.values.all { it.note == OutboxRestore.NOTE_KILLED })
        assertEquals("Not sent — Page closed before the countdown ended. Your message is back here.", OutboxRestore.NOTE_KILLED)
        assertEquals(emptyList<ScheduledSend>(), OutboxRestore.decode(null))
        assertEquals(emptyList<ScheduledSend>(), OutboxRestore.decode("not json"))
        assertEquals("a blank text is not a draft", emptyList<ScheduledSend>(), OutboxRestore.decode("""[{"id":"a","sessionId":"s","text":"  ","at":1}]"""))
    }

    @Test fun `Undo into a box that already has words puts the returned text first`() {
        assertEquals("sent text", OutboxRestore.merge("sent text", ""))
        assertEquals("sent text", OutboxRestore.merge("sent text", "   "))
        assertEquals("typed since", OutboxRestore.merge("", "typed since"))
        assertEquals("sent text\n\ntyped since", OutboxRestore.merge("sent text", "typed since"))
        assertEquals("already in the box: not added twice (iOS DraftRestore.merge)", "sent text and more", OutboxRestore.merge("sent text", "sent text and more"))
        assertEquals("sent text", OutboxRestore.merge("  sent text \n", "sent text"))
    }

    @Test fun `the countdown receipt says Sending in N s with Undo, and beats an older message's receipt`() {
        val s = scheduled(text = "x")
        val r = SendReceipt.build(null, "Claude", t0.plusSeconds(2.0), scheduled = s)!!
        assertEquals("Sending in 8 s", r.headline)
        assertEquals(SendReceipt.Action.UNDO, r.action)
        assertEquals("Undo", r.action?.label)
        assertEquals(SendReceipt.Tone.WORKING, r.tone)
        val old = SentSessionCommand("c0", "s1", SessionCommandKind.INPUT, "old", t0, SessionDeliveryState.Typed(null))
        assertEquals("Sending in 8 s", SendReceipt.build(old, "Claude", t0.plusSeconds(2.0), scheduled = s)?.headline)
        assertTrue(SendCountdown.spoken(s, t0).contains("Undo"))
    }

    @Test fun `what TalkBack hears for a ticking receipt stays the same while it ticks`() {
        val s = scheduled(text = "x")
        val early = SendReceipt.build(null, "Claude", t0.plusSeconds(1.0), scheduled = s)!!
        val late = SendReceipt.build(null, "Claude", t0.plusSeconds(7.0), scheduled = s)!!
        assertTrue(early.headline != late.headline)
        assertEquals(early.spoken, late.spoken)
        assertTrue(early.spoken!!.contains("Undo"))
        val photo = SentSessionCommand("c1", "s1", SessionCommandKind.INPUT, "", t0, SessionDeliveryState.Sending, photos = 2)
        val a = SendReceipt.build(photo, "Claude", t0, uploading = PhotoProgress(1, 20, PhotoProgress.Phase.UPLOADING))!!
        val b = SendReceipt.build(photo, "Claude", t0, uploading = PhotoProgress(15, 20, PhotoProgress.Phase.UPLOADING))!!
        assertTrue(a.detail != b.detail)
        assertEquals(a.spoken, b.spoken)
        assertNull("a settled receipt reads its own words", SendReceipt.build(held(SessionDeliveryState.Typed(null)), "Claude", t0)?.spoken)
    }

    // MARK: held messages: receipts settle from results and rows

    private fun held(state: SessionDeliveryState = SessionDeliveryState.Sending, id: String = "c7", at: Instant = t0) =
        SentSessionCommand(id, "s1", SessionCommandKind.INPUT, "Then run the linter", at, state)

    @Test fun `a held ack is Held, and exactly one more result, the fromHold one, settles it`() {
        val ack = result(""""ok":true,"code":"queued","held":true,"detail":"Held — Page types it when Claude finishes this turn"""")
        val heldState = SessionDeliveryState.Sending.applying(ack, "Claude")
        assertEquals(SessionDeliveryState.Held("Held — Page types it when Claude finishes this turn"), heldState)
        assertFalse(heldState.isPending)
        assertEquals("a repeat of the ack changes nothing", heldState, heldState.applying(ack, "Claude"))
        assertEquals("a result that is not the final one changes nothing", heldState, heldState.applying(result(""""ok":true,"code":"delivered","detail":"Typed into cmux""""), "Claude"))
        val typed = heldState.applying(result(""""ok":true,"code":"delivered","fromHold":true,"detail":"Typed into tmux pane %3""""), "Claude")
        assertEquals(SessionDeliveryState.Typed("Typed into tmux pane %3"), typed)
        val deleted = heldState.applying(result(""""ok":false,"code":"cancelled","reason":"cancelled","fromHold":true,"detail":"Deleted — not sent""""), "Claude")
        assertEquals(SessionDeliveryState.Deleted("Deleted — not sent"), deleted)
        val ended = heldState.applying(result(""""ok":false,"code":"refused","reason":"ended","fromHold":true,"detail":"Not sent — the session ended""""), "Claude")
        assertEquals(SessionDeliveryState.Refused("ended", "Not sent — the session ended"), ended)
        val expired = heldState.applying(result(""""ok":false,"code":"refused","reason":"expired","fromHold":true,"detail":"Not sent — the turn didn't finish within 6 hours""""), "Claude")
        assertEquals("Not sent — the turn didn't finish within 6 hours", (expired as SessionDeliveryState.Refused).message)
        val failed = heldState.applying(result(""""ok":false,"code":"failed","reason":"error","fromHold":true,"detail":"Not sent — it failed""""), "Claude")
        assertEquals(SessionDeliveryState.Failed("Not sent — it failed"), failed)
        // A final result that beat the ack still wins, and the late ack is dropped.
        assertEquals(typed, typed.applying(ack, "Claude"))
        assertEquals("cancelled is never typed or failed", "Deleted", deleted.label(SessionCommandKind.INPUT))
    }

    @Test fun `a plain queued result is still the agent's own queue, and says Page can't take it back`() {
        val q = SessionDeliveryState.Sending.applying(result(""""ok":true,"code":"queued","detail":"Queued — Claude reads it after the current step""""), "Claude")
        assertTrue(q is SessionDeliveryState.Queued)
        assertEquals("Already with Claude — it reads it after this step", q.bubbleExplanation(SessionCommandKind.INPUT, "Claude"))
        assertFalse(QueuedDelete.heldMessage(q, setOf("retract-v1"), null))
    }

    @Test fun `the list settles a held receipt from the row's held entry`() {
        val h = SessionDeliveryState.Held("Held — Page types it when Claude finishes this turn")
        fun entry(state: HeldMessage.State, detail: String? = null) = HeldMessage("c7", "t", t0, state, null, detail)
        assertEquals(h.copy(note = "Someone is typing at the Mac"), HeldMessages.settle(h, entry(HeldMessage.State.HELD, "Someone is typing at the Mac"), true))
        assertEquals(h.copy(typing = true), HeldMessages.settle(h, entry(HeldMessage.State.TYPING), true))
        assertEquals(SessionDeliveryState.Typed("Typed into tmux"), HeldMessages.settle(h, entry(HeldMessage.State.TYPED, "Typed into tmux"), true))
        assertEquals(SessionDeliveryState.Deleted("Deleted — not sent"), HeldMessages.settle(h, entry(HeldMessage.State.DELETED), true))
        assertEquals(SessionDeliveryState.Refused("ended", "Not sent — the session ended"), HeldMessages.settle(h, entry(HeldMessage.State.ENDED), true))
        assertEquals("expired", (HeldMessages.settle(h, entry(HeldMessage.State.EXPIRED), true) as SessionDeliveryState.Refused).reason)
        assertEquals(SessionDeliveryState.Failed("Not sent — it broke"), HeldMessages.settle(h, entry(HeldMessage.State.FAILED, "Not sent — it broke"), true))
        assertEquals("an unknown state changes nothing", h, HeldMessages.settle(h, entry(HeldMessage.State.UNKNOWN), true))
        val unconfirmed = HeldMessages.settle(h, entry(HeldMessage.State.UNCONFIRMED), true) as SessionDeliveryState.CheckSession
        assertEquals(HeldMessages.UNCONFIRMED_COPY, unconfirmed.message)
    }

    @Test fun `an entry that vanished reads No longer held, but only if this phone saw it listed first`() {
        val h = SessionDeliveryState.Held(null)
        assertEquals(SessionDeliveryState.CheckSession("No longer held — check the session"), HeldMessages.settle(h, null, seen = true))
        assertEquals("a list built before the Mac took it lacks it too", h, HeldMessages.settle(h, null, seen = false))
        assertEquals("a settled state is never undone by a list", SessionDeliveryState.Typed("x"), HeldMessages.settle(SessionDeliveryState.Typed("x"), null, true))
        assertEquals(SessionDeliveryState.Queued("q"), HeldMessages.settle(SessionDeliveryState.Queued("q"), null, true))
    }

    @Test fun `a held message whose session left the list reads No longer held, never Held forever`() {
        val h = SessionDeliveryState.Held("Held — Page types it when Claude finishes this turn")
        val gone = SessionDeliveryState.CheckSession(HeldMessages.NO_LONGER_HELD)
        assertEquals("seen or not, the row and its settled entry are gone", gone, HeldMessages.settle(h, null, seen = false, sessionListed = false))
        assertEquals(gone, HeldMessages.settle(h, null, seen = true, sessionListed = false))
        assertEquals("one still sending simply hasn't reached a list", SessionDeliveryState.Sending, HeldMessages.settle(SessionDeliveryState.Sending, null, seen = false, sessionListed = false))
        assertEquals(SessionDeliveryState.Typed("x"), HeldMessages.settle(SessionDeliveryState.Typed("x"), null, seen = false, sessionListed = false))
    }

    @Test fun `a send whose result never arrived is found held in the list`() {
        val e = HeldMessage("c7", "t", t0, HeldMessage.State.HELD, null, null)
        assertEquals(SessionDeliveryState.Held(null), HeldMessages.settle(SessionDeliveryState.Sending, e, false))
        assertEquals(SessionDeliveryState.Held(null), HeldMessages.settle(SessionDeliveryState.NoAnswer, e, true))
        assertEquals(SessionDeliveryState.Sending, HeldMessages.settle(SessionDeliveryState.Sending, null, true))
    }

    @Test fun `held messages show in the room as pending bubbles, oldest first, with other devices' ones included`() {
        val s = row(
            ""","held":[{"clientId":"c1","text":"older","heldAt":"2026-10-24T12:00:00Z","state":"held"},
                         {"clientId":"c2","text":"mine","heldAt":"2026-10-24T12:05:00Z","state":"held"},
                         {"clientId":"c3","text":"typed","heldAt":"2026-10-24T12:06:00Z","state":"typed"}]""",
        )
        val mine = held(SessionDeliveryState.Held(null), id = "c2", at = Instant.parse("2026-10-24T12:05:00Z"))
        val shown = HeldMessages.pending(s, listOf(mine))
        assertEquals(listOf("c1", "c2"), shown.map { it.clientId })
        assertTrue(shown[0].fromOtherDevice)
        assertTrue(shown[0].state is SessionDeliveryState.Held)
        assertFalse("a settled entry is in the transcript, not a bubble", shown.any { it.clientId == "c3" })
        val timeline = TranscriptTimeline.merge(emptyList(), shown)
        assertEquals(2, timeline.size)
        assertTrue(timeline.all { it is TranscriptTimeline.Item.Pending })
    }

    @Test fun `a held message never claims a transcript echo, a deleted one neither`() {
        val entry = TranscriptEntry("u1", TranscriptRole.USER, "Then run the linter", t0.plusSeconds(1.0), null)
        for (st in listOf(SessionDeliveryState.Held(null), SessionDeliveryState.Deleted("x"))) {
            val items = TranscriptTimeline.merge(listOf(entry), listOf(held(st)))
            assertTrue(items.last() is TranscriptTimeline.Item.Pending)
        }
        val typed = TranscriptTimeline.merge(listOf(entry), listOf(held(SessionDeliveryState.Typed(null))))
        assertEquals(1, typed.size)
    }

    @Test fun `the held receipt uses the Mac's sentence, else ours, stays, and offers Delete only when it can work`() {
        val withMac = SessionDeliveryState.Held("Held — Page types it when Claude finishes this turn")
        val r = SendReceipt.build(held(withMac), "Claude", t0.plusSeconds(3600.0), canDelete = true)!!
        assertEquals("Held — Page types it when Claude finishes this turn", r.headline)
        assertEquals(SendReceipt.Tone.HELD, r.tone)
        assertEquals(SendReceipt.Action.DELETE, r.action)
        assertEquals("Held — sends when Claude finishes", SendReceipt.build(held(SessionDeliveryState.Held(null)), "Claude", t0, canDelete = false)?.headline)
        assertNull("old Mac: no Delete", SendReceipt.build(held(withMac), "Claude", t0, canDelete = false)?.action)
        assertEquals("Held — sends when Claude finishes", HeldMessages.HELD_HEADLINE)
        assertEquals("Deleting…", SendReceipt.build(held(withMac), "Claude", t0, delete = HeldDelete.Deleting("r1", t0), canDelete = false)?.headline)
        val tooLate = SendReceipt.build(held(withMac), "Claude", t0, delete = HeldDelete.Done("r1", MacRetract.Outcome.TooLate(null)), canDelete = true)!!
        assertEquals("Too late — it was already typed", tooLate.detail)
        assertEquals("Deleted — not sent", SendReceipt.build(held(SessionDeliveryState.Deleted("Deleted — not sent")), "Claude", t0.plusSeconds(5.0))?.headline)
    }

    // MARK: Delete a held message (retract)

    @Test fun `a retract answer maps to deleted, too late or not found with the Mac's own copy`() {
        val del = MacRetract.outcome(result(""""ok":true,"code":"delivered","retract":"deleted","detail":"Deleted — not sent""""))
        assertEquals(MacRetract.Outcome.Deleted("Deleted — not sent"), del)
        assertEquals("Already deleted — not sent", MacRetract.outcome(result(""""ok":true,"code":"delivered","retract":"deleted","detail":"Already deleted — not sent"""")).text)
        val late = MacRetract.outcome(result(""""ok":false,"code":"refused","reason":"too_late","retract":"too_late","detail":"Too late — Page had started typing it; check the session""""))
        assertEquals("Too late — Page had started typing it; check the session", late.text)
        assertTrue(late is MacRetract.Outcome.TooLate)
        val nf = MacRetract.outcome(result(""""ok":false,"code":"refused","reason":"not_found","retract":"not_found","detail":"Page isn't holding that message""""))
        assertEquals("Page isn't holding that message", nf.text)
        // Defaults when the Mac sends no detail.
        assertEquals("Deleted — not sent", MacRetract.Outcome.Deleted(null).text)
        assertEquals("Too late — it was already typed", MacRetract.Outcome.TooLate(null).text)
        assertEquals("Page isn't holding that message", MacRetract.Outcome.NotFound(null).text)
        // A Mac that omits `retract` is read from code and reason.
        assertTrue(MacRetract.outcome(result(""""ok":true,"code":"delivered"""")) is MacRetract.Outcome.Deleted)
        assertTrue(MacRetract.outcome(result(""""ok":false,"code":"refused","reason":"too_late"""")) is MacRetract.Outcome.TooLate)
        assertTrue(MacRetract.outcome(result(""""ok":false,"code":"refused","reason":"disabled"""")) is MacRetract.Outcome.Refused)
    }

    @Test fun `no retract answer in 20 s reads Couldn't confirm the delete, and the relay's failures read in words`() {
        val d = HeldDelete.Deleting("r1", t0)
        assertEquals(20.0, MacRetract.TIMEOUT, 0.0)
        assertEquals(d, d.timedOut(t0.plusSeconds(19.0)))
        val un = d.timedOut(t0.plusSeconds(20.0))
        assertEquals(HeldDelete.Unconfirmed("r1"), un)
        assertEquals("Couldn't confirm the delete — it may still be sent", un.text)
        assertEquals("a settled delete is never timed out", un, un.timedOut(t0.plusSeconds(99.0)))
        assertTrue(d.isDeleting)
        assertNull(d.text)
        assertEquals("Your Mac is offline — try again when it's back", MacRetract.relayFailure(SessionCommandOutcome.MacOffline)?.text)
        assertNull(MacRetract.relayFailure(SessionCommandOutcome.Accepted))
        assertEquals(SessionCommandOutcome.RateLimited.failureMessage, MacRetract.relayFailure(SessionCommandOutcome.RateLimited)?.text)
    }

    @Test fun `Delete is offered only where it can work`() {
        val heldState = SessionDeliveryState.Held(null)
        val caps = setOf("hold-v1", "retract-v1")
        assertTrue(QueuedDelete.heldMessage(heldState, caps, null))
        assertFalse("old Mac: no retract-v1", QueuedDelete.heldMessage(heldState, setOf("hold-v1"), null))
        assertFalse("being typed right now", QueuedDelete.heldMessage(heldState.copy(typing = true), caps, null))
        assertFalse("a delete is already in flight", QueuedDelete.heldMessage(heldState, caps, HeldDelete.Deleting("r", t0)))
        assertTrue("a failed delete may be tried again", QueuedDelete.heldMessage(heldState, caps, HeldDelete.Unconfirmed("r")))
        assertFalse(QueuedDelete.heldMessage(SessionDeliveryState.Typed(null), caps, null))
        assertFalse(QueuedDelete.heldMessage(SessionDeliveryState.Queued(null), caps, null))
    }

    // MARK: L2: replies queued at the relay

    private val features = setOf("sessions-v1", "reply-retract-v1")

    @Test fun `a pending reply with no forward time on a non-hook page is queued at the relay, also after a relaunch`() {
        val repAt = at(60_000.0)
        assertEquals(ReplyDelivery.Sent(true, repAt), ReplyDelivery.synced(null, "pending", null, repAt, NOW, forwardedAt = null, hookBlocking = false))
        assertEquals(ReplyDelivery.Sent(false, repAt), ReplyDelivery.synced(null, "pending", null, repAt, NOW, forwardedAt = at(61_000.0), hookBlocking = false))
        assertEquals("a hook's page is pending with no forward, and nothing was queued", ReplyDelivery.Sent(false, repAt), ReplyDelivery.synced(null, "pending", null, repAt, NOW, forwardedAt = null, hookBlocking = true))
        // The queue flushing takes Delete away; the reverse never makes up a queue.
        assertEquals(ReplyDelivery.Sent(false, repAt), ReplyDelivery.synced(ReplyDelivery.Sent(true, repAt), "pending", null, repAt, NOW, forwardedAt = at(61_000.0)))
        assertEquals(ReplyDelivery.Sent(true, repAt), ReplyDelivery.synced(ReplyDelivery.Sent(true, repAt), "pending", null, repAt, NOW, forwardedAt = null))
    }

    @Test fun `Delete on a queued reply needs the relay feature, the Sent-queued state and no hook`() {
        val queued = ReplyDelivery.Sent(true, t0)
        assertEquals(QueuedDelete.Layer.RELAY_QUEUE, QueuedDelete.reply(queued, false, features, emptySet()))
        assertNull("old relay", QueuedDelete.reply(queued, false, setOf("sessions-v1"), emptySet()))
        assertNull("features not known yet", QueuedDelete.reply(queued, false, null, emptySet()))
        assertNull("hook-held", QueuedDelete.reply(queued, true, features, emptySet()))
        assertNull("forwarded", QueuedDelete.reply(ReplyDelivery.Sent(false, t0), false, features, emptySet()))
        assertNull(QueuedDelete.reply(ReplyDelivery.Delivered("x"), false, features, emptySet()))
        assertNull(QueuedDelete.reply(null, false, features, emptySet()))
        assertEquals("Update your relay to delete queued replies.", QueuedDelete.whyNot(queued, false, setOf("sessions-v1"), emptySet(), hasList = true))
        assertEquals("Waiting on the hook. It can't be deleted from here.", QueuedDelete.whyNot(queued, true, features, emptySet(), hasList = true))
        assertNull(QueuedDelete.whyNot(queued, false, features, emptySet(), hasList = true))
    }

    @Test fun `the relay's DELETE answers map to the copy the user sees`() {
        fun out(status: Int, body: String) = ReplyRetract.from(status, body)
        assertEquals(ReplyRetract.Outcome.Deleted(), out(200, """{"ok":true,"retracted":true}"""))
        assertEquals("Deleted — not sent", ReplyRetract.Outcome.Deleted().text)
        assertEquals(ReplyRetract.Outcome.NothingToDelete, out(200, """{"ok":true,"retracted":false,"nothing":true}"""))
        assertEquals("Nothing to delete", ReplyRetract.Outcome.NothingToDelete.text)
        for (stage in listOf("forwarded", "delivered")) {
            val o = out(409, """{"error":"too_late","stage":"$stage"}""")
            assertEquals(ReplyRetract.Outcome.TooLate(stage), o)
            assertEquals("Too late — your Mac already has it", o.text)
        }
        assertEquals(ReplyRetract.Outcome.CouldntTakeBack, out(409, """{"error":"too_late","stage":"not_held"}"""))
        assertEquals(ReplyRetract.Outcome.CouldntTakeBack, out(409, """{"error":"too_late","stage":"somethingNew"}"""))
        assertEquals(ReplyRetract.Outcome.CouldntTakeBack, out(409, """{"error":"too_late"}"""))
        assertEquals("Couldn't take it back — it may still be sent", ReplyRetract.Outcome.CouldntTakeBack.text)
        assertEquals(ReplyRetract.Outcome.HookHeld, out(409, """{"error":"hook_held"}"""))
        assertTrue(ReplyRetract.Outcome.HookHeld.text.contains("hook"))
        assertEquals("an old relay's 404 not_found", ReplyRetract.Outcome.RelayTooOld, out(404, """{"error":"not_found"}"""))
        assertEquals("Update your relay to delete queued replies", ReplyRetract.Outcome.RelayTooOld.text)
        assertEquals("the new relay's 404 is a gone page, never an old relay", ReplyRetract.Outcome.PageGone, out(404, """{"error":"no_such_intervention"}"""))
        assertEquals("a 404 with no error string is not called an old relay (keyed on the error string, as iOS)", ReplyRetract.Outcome.Failed(ReplyRetract.COULDNT), out(404, ""))
        assertEquals(ReplyRetract.Outcome.Unauthorized, out(401, "{}"))
        assertTrue(out(410, """{"error":"token_retired","why":"replaced"}""") is ReplyRetract.Outcome.Retired)
        assertEquals("the relay answered something else: it may still be sent", ReplyRetract.COULDNT, (out(502, "bad gateway") as ReplyRetract.Outcome.Failed).text)
        assertEquals("It's waiting on the hook, so it can't be deleted.", ReplyRetract.Outcome.HookHeld.text)
        assertEquals("Couldn't reach your relay — it may still be sent", ReplyRetract.TRANSPORT)
        assertFalse(ReplyRetract.available(null))
        assertFalse(ReplyRetract.available(setOf("sessions-v1")))
        assertTrue(ReplyRetract.available(features))
    }

    @Test fun `a delete leaves the reply where the relay's answer says, and allows a fresh reply after Deleted`() {
        val queued = ReplyDelivery.Sent(true, t0)
        val deleted = ReplyDelivery.afterRetract(queued, ReplyRetract.Outcome.Deleted(), NOW)
        assertEquals(ReplyDelivery.Retracted("Deleted — not sent") to null, deleted)
        assertTrue("the sheet takes a fresh reply", DecisionPhase.derive(phaseInputs(deleted.first!!)).acceptsInput)
        // Too late: the Mac has it, so it is no longer queued, with the relay's words as the note.
        val late = ReplyDelivery.afterRetract(ReplyDelivery.Retracting, ReplyRetract.Outcome.TooLate("forwarded"), NOW)
        assertEquals(ReplyDelivery.Sent(true, NOW).copy(queued = false) to "Too late — your Mac already has it", late)
        assertEquals(queued to "Couldn't take it back — it may still be sent", ReplyDelivery.afterRetract(queued, ReplyRetract.Outcome.CouldntTakeBack, NOW))
        assertEquals(queued to "Update your relay to delete queued replies", ReplyDelivery.afterRetract(queued, ReplyRetract.Outcome.RelayTooOld, NOW))
        assertEquals(queued to "Nothing to delete", ReplyDelivery.afterRetract(queued, ReplyRetract.Outcome.NothingToDelete, NOW))
        assertEquals(queued to ReplyRetract.TRANSPORT, ReplyDelivery.afterRetract(queued, ReplyRetract.Outcome.Failed(ReplyRetract.TRANSPORT), NOW))
        assertEquals(ReplyDelivery.Gone to null, ReplyDelivery.afterRetract(queued, ReplyRetract.Outcome.PageGone, NOW))
    }

    private fun phaseInputs(d: ReplyDelivery?) = DecisionPhase.Inputs(
        delivery = d, isLive = true, hasSnapshot = true, lookupFinished = true, closeReason = null, closeLookupFinished = true, now = NOW, legacyRelay = false,
    )

    @Test fun `the reply result frame and the stored method read retracted as deleted, held_until_reset as held`() {
        assertEquals(ReplyDelivery.Retracted("Deleted — not sent"), ReplyResultFrame.delivery(false, "retracted", "Deleted — not sent", cancelled = true))
        assertEquals("method retracted without cancelled", ReplyDelivery.Retracted("Deleted — not sent"), ReplyResultFrame.delivery(false, "retracted", null))
        assertEquals("cancelled without a method", ReplyDelivery.Retracted("x"), ReplyResultFrame.delivery(false, null, "x", cancelled = true))
        assertEquals(ReplyDelivery.HeldOnMac("Will send it when the limit resets at 3:00 PM"), ReplyResultFrame.delivery(true, "held_until_reset", "Will send it when the limit resets at 3:00 PM"))
        assertEquals(ReplyDelivery.Delivered("Typed"), ReplyResultFrame.delivery(true, "tmux", "Typed"))
        assertEquals(ReplyDelivery.Failed("Your Mac couldn't deliver the reply."), ReplyResultFrame.delivery(false, "none", null))
        // The relay's record after a relaunch.
        assertEquals(ReplyDelivery.Retracted("Deleted — not sent"), ReplyDelivery.synced(null, "failed", "Deleted — not sent", null, NOW, deliveryMethod = "retracted"))
        assertEquals(ReplyDelivery.HeldOnMac("Will send it when the limit resets at 3:00 PM"), ReplyDelivery.synced(null, "delivered", "Will send it when the limit resets at 3:00 PM", NOW, NOW, deliveryMethod = "held_until_reset"))
        assertEquals(ReplyDelivery.Delivered("Typed"), ReplyDelivery.synced(null, "delivered", "Typed", NOW, NOW, deliveryMethod = "tmux"))
        assertEquals("a deleted reply on another device frees a fresh one", ReplyDelivery.Sent(false, NOW), ReplyDelivery.synced(ReplyDelivery.Retracted("x"), "pending", null, NOW, NOW, forwardedAt = NOW))
    }

    @Test fun `a rate-limit hold reads Held on your Mac until the time, and Delete asks the Mac to retract the page`() {
        val d = ReplyDelivery.HeldOnMac("Will send it when the limit resets at 3:00 PM")
        assertEquals("3:00 PM", d.until)
        assertEquals("Held on your Mac until 3:00 PM", HeldUntilReset.line(d.detail))
        assertEquals("Held on your Mac until the limit resets", HeldUntilReset.line("Will send it later"))
        assertEquals("Held on your Mac until 11:45 PM", HeldUntilReset.line("Will send it when the limit resets at 11:45 PM."))
        assertEquals("no time in the sentence (iOS's case)", "Held on your Mac until the limit resets", HeldUntilReset.line("something at the shop"))
        assertEquals("Held on your Mac until the limit resets", HeldUntilReset.line(null))
        assertEquals(QueuedDelete.Layer.MAC_RATE_LIMIT, QueuedDelete.reply(d, false, features, setOf("retract-v1")))
        assertNull("old Mac: no Delete", QueuedDelete.reply(d, false, features, emptySet()))
        assertEquals("Update Page on your Mac to delete a held reply.", QueuedDelete.whyNot(d, false, features, emptySet(), hasList = true))
        assertEquals(DecisionPhase.HeldOnMac(d.detail), DecisionPhase.derive(phaseInputs(d)))
        assertFalse("held is not a delivery: the sheet must not close itself", DecisionPhase.derive(phaseInputs(d)).isDelivered)
        assertNull(DecisionPhase.derive(phaseInputs(d)).autoCloseDelay)
        assertEquals(CardOutcome.Note("Held on your Mac until 3:00 PM"), CardOutcome.from(null, d, NOW))
        // The Mac's answers.
        assertEquals(ReplyDelivery.Retracted("Deleted — not sent. Nothing will be typed at reset") to null,
            ReplyDelivery.afterMacRetract(ReplyDelivery.Retracting, MacRetract.Outcome.Deleted("Deleted — not sent. Nothing will be typed at reset")))
        assertEquals(d to "Too late — Page was already typing it after the limit reset",
            ReplyDelivery.afterMacRetract(d, MacRetract.Outcome.TooLate("Too late — Page was already typing it after the limit reset")))
        assertEquals(d to MacRetract.UNCONFIRMED, ReplyDelivery.afterMacRetract(d, MacRetract.Outcome.Failed(MacRetract.UNCONFIRMED)))
    }

    @Test fun `the sheet's phases for a delete read Deleting, Deleted — not sent, and keep the page open`() {
        assertEquals(DecisionPhase.Retracting, DecisionPhase.derive(phaseInputs(ReplyDelivery.Retracting)))
        assertEquals("Deleting…", DecisionPhase.Retracting.statusLine(false)?.text)
        assertFalse(DecisionPhase.Retracting.acceptsInput)
        val gone = DecisionPhase.derive(phaseInputs(ReplyDelivery.Retracted("Deleted — not sent")))
        assertEquals(DecisionPhase.Retracted("Deleted — not sent"), gone)
        assertEquals("Deleted — not sent. Nothing was typed.", gone.statusLine(false)?.text)
        assertEquals(DecisionPhase.Tone.NEUTRAL, gone.statusLine(false)?.tone)
        assertNull("the sheet stays open", gone.autoCloseDelay)
        assertEquals("a Mac's longer sentence is kept", "Deleted — not sent. Nothing will be typed at reset", DecisionPhase.Retracted("Deleted — not sent. Nothing will be typed at reset").statusLine(false)?.text)
        assertEquals(CardOutcome.None, CardOutcome.from(null, ReplyDelivery.Retracted("x"), NOW))
        assertEquals(CardOutcome.Sending, CardOutcome.from(null, ReplyDelivery.Retracting, NOW))
    }

    @Test fun `the receipt thread draws a delete, a deletion and a hold in words`() {
        assertEquals("deleting", ReceiptThread.derive(null, ReplyDelivery.Retracting, null, t0, t0).word)
        assertEquals(ReceiptThread.Stage.Deleting, ReceiptThread.derive(null, ReplyDelivery.Retracting, null, t0, t0).stage)
        val deleted = ReceiptThread.derive(null, ReplyDelivery.Retracted("x"), null, t0, t0.plusSeconds(5.0))
        assertEquals("deleted · not sent", deleted.word)
        assertFalse("nothing went wrong, so no failure", deleted.isFailure)
        assertEquals("held on your Mac", ReceiptThread.derive(null, ReplyDelivery.HeldOnMac("x"), null, t0, t0).word)
    }

    // MARK: notifications (L1) and the sheet's one-tap Steer

    @Test fun `a notification's Delete is a known action, and each relay answer reads in its own words`() {
        assertTrue(NotificationActionUri.knownActions.contains(NotificationActionId.DELETE))
        assertEquals(NotificationActionUri.Parsed("p 1", "DELETE"), NotificationActionUri.parse(NotificationActionUri.build("p 1", NotificationActionId.DELETE)))
        val deleted = QueuedReplyNotification.after(ReplyRetract.Outcome.Deleted())
        assertNull("the page's own actions are back", deleted.status)
        assertEquals("Deleted — not sent", deleted.note)
        assertEquals("Nothing to delete", QueuedReplyNotification.after(ReplyRetract.Outcome.NothingToDelete).note)
        assertEquals("Too late — your Mac already has it", QueuedReplyNotification.after(ReplyRetract.Outcome.TooLate("forwarded")).status)
        assertEquals("Couldn't take it back — it may still be sent", QueuedReplyNotification.after(ReplyRetract.Outcome.CouldntTakeBack).status)
        assertEquals("Update your relay to delete queued replies", QueuedReplyNotification.after(ReplyRetract.Outcome.RelayTooOld).status)
        val transport = QueuedReplyNotification.after(ReplyRetract.Outcome.Failed(ReplyRetract.TRANSPORT))
        assertEquals("Couldn't reach your relay — it may still be sent", transport.status)
        assertTrue("a delete that never reached the relay can be tried again", transport.deleteAgain)
        assertFalse(QueuedReplyNotification.after(ReplyRetract.Outcome.TooLate("delivered")).deleteAgain)
        assertEquals("Sending your reply…", QueuedReplyNotification.SENDING)
        assertEquals("Queued — your Mac is offline. It'll be typed in when it reconnects.", QueuedReplyNotification.QUEUED)
    }

    @Test fun `the queued notification offers Delete only when the relay can take it back`() {
        assertTrue(QueuedReplyNotification.offersDelete(true, features, hookBlocking = false))
        assertFalse("old relay", QueuedReplyNotification.offersDelete(true, setOf("sessions-v1"), false))
        assertFalse("features unknown", QueuedReplyNotification.offersDelete(true, null, false))
        assertFalse("a hook's page", QueuedReplyNotification.offersDelete(true, features, true))
        assertFalse("forwarded, not queued", QueuedReplyNotification.offersDelete(false, features, false))
    }

    @Test fun `Steer on a card opens its sheet with the composer up, once, for that page only`() {
        app.page.android.data.AppRouter.open("p4", switchTab = false, composer = true)
        assertFalse("another page", app.page.android.data.AppRouter.takeSheetComposer("p9"))
        app.page.android.data.AppRouter.open("p4", switchTab = false, composer = true)
        assertTrue(app.page.android.data.AppRouter.takeSheetComposer("p4"))
        assertFalse("read once", app.page.android.data.AppRouter.takeSheetComposer("p4"))
        app.page.android.data.AppRouter.open("p4", switchTab = false)
        assertFalse("a plain open has no composer", app.page.android.data.AppRouter.takeSheetComposer("p4"))
        app.page.android.data.AppRouter.requestSheetComposer("p5")
        assertFalse("an old request belongs to an earlier opening", app.page.android.data.AppRouter.takeSheetComposer("p5", Instant.now().plusSeconds(6)))
        app.page.android.data.AppRouter.reset()
    }

    @Test fun `a page's Steer countdown that fires after its page closed puts the text back, with that reason`() {
        val d = OutboxRestore.gone(scheduled(text = "keep", at = t0).copy(pageId = "p4"))
        assertEquals(OutboxRestore.NOTE_PAGE_GONE, d.note)
        assertEquals("keep", d.text)
        assertEquals("Not sent — the page was answered or closed on your Mac first. Your message is back here.", OutboxRestore.NOTE_PAGE_GONE)
    }

    // MARK: the wire is untouched for anything not queued

    @Test fun `a plain result still reads as before`() {
        assertEquals(SessionDeliveryState.Typed("ok"), SessionDeliveryState.Sending.applying(result(""""ok":true,"code":"delivered","detail":"ok""""), "Claude"))
        assertEquals(SessionDeliveryState.Queued("q"), SessionDeliveryState.Sending.applying(result(""""ok":true,"code":"queued","detail":"q""""), "Claude"))
        assertTrue(SessionDeliveryState.Sending.applying(result(""""ok":false,"code":"refused","reason":"draft""""), "Claude") is SessionDeliveryState.Refused)
        assertEquals(SessionDeliveryState.Typed("a"), SessionDeliveryState.Typed("a").applying(result(""""ok":false,"code":"failed""""), "Claude"))
        assertTrue(JsonObject(emptyMap()).isEmpty())
    }
}
