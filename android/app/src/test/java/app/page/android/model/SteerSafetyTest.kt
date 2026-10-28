package app.page.android.model

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Steer safety, ported from the "Steer safety: tap targets, targets on the wire, Send, receipts" checks in
 * iOS/Tests/LogicTests.swift: what a room showed travels with every message, Send refuses with a reason, the
 * Return key, and the receipt names exactly where a message went.
 */
class SteerSafetyTest {
    private val busy = nwSession("s-busy", title = "page", state = "active", host = "cmux", cwd = "~/projects/page")
    private val other = nwSession("s-other", title = "riot", state = "active", host = "cmux", cwd = "~/projects/riot")

    private fun decide(
        mode: RoomComposerMode,
        text: String = "hello",
        shown: LiveSession = busy,
        route: String = "s-busy",
        live: LiveSession? = busy,
        ended: Boolean = false,
        reply: Boolean = true,
    ): RoomSend.Decision = RoomSend.decide(
        mode = mode, text = text, shown = shown, routeSessionId = route, live = live, ended = ended,
        hasReplyAction = reply, macName = "Studio MBP",
    )

    private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.contentOrNull

    private fun wireObj(c: SessionCommand): JsonObject =
        parseJsonObject(String(c.plaintext("c", "v", CMD_NOW), Charsets.UTF_8))!!

    // MARK: the target

    @Test fun `a target names the folder, the id's start, the route and what travels`() {
        val page = nwSession("d8a3f555-8774-4e26-a687-32b9f92815bc", title = "riot-io-teltonika", state = "active", host = "cmux", cwd = "~/projects/riot-io-teltonika")
        val target = SessionTarget.of(page, "Studio MBP")
        assertEquals("riot-io-teltonika", target.project)
        assertEquals("d8a3", target.shortId)
        assertEquals("riot-io-teltonika · cmux · Studio MBP", target.route)
        assertEquals("~/projects/riot-io-teltonika", target.expectCwd)
        assertEquals("riot-io-teltonika", target.expectTitle)
        assertEquals("~/projects/riot-io-teltonika · #d8a3", target.whereLine)
    }

    @Test fun `an unknown terminal and a blank Mac name drop out of the route, and the home folder reads tilde`() {
        assertEquals("b · your Mac", SessionTarget.of(nwSession("x1", host = "unknown", cwd = "~/a/b"), "").route)
        assertEquals("~", SessionTarget.of(nwSession("zz", title = "Some thread", cwd = "~"), "M").project)
        assertEquals("#abcd", SessionTarget.of(nwSession("abcd1234", cwd = ""), "M").whereLine)
    }

    @Test fun `a title this phone made up is never sent as an expectation`() {
        val blank = nwSession("abcdef123456", title = "", cwd = "")
        val t = SessionTarget.of(blank, "M")
        assertNull(t.expectCwd)
        assertNull(t.expectTitle)
    }

    @Test fun `the Stop line and the input carry the target and an old Mac sees the same bytes`() {
        val page = nwSession("d8a3f555-8774-4e26-a687-32b9f92815bc", title = "riot-io-teltonika", state = "active", host = "cmux", cwd = "~/projects/riot-io-teltonika")
        val target = SessionTarget.of(page, "Studio MBP")
        val plain = SessionCommand.Input("s1", "hi").plaintext("c1", "v1", CMD_NOW)
        val plainTarget = SessionCommand.Input("s1", "hi", target = null).plaintext("c1", "v1", CMD_NOW)
        assertArrayEquals("no target: the same bytes as before", plain, plainTarget)
        assertNull(wireObj(SessionCommand.Input("s1", "hi")).str("expectCwd"))
        val withTarget = wireObj(SessionCommand.Input(page.id, "hi", target))
        assertEquals("~/projects/riot-io-teltonika", withTarget.str("expectCwd"))
        assertEquals("riot-io-teltonika", withTarget.str("expectTitle"))
        assertEquals(page.id, withTarget.str("sessionId"))
        assertEquals("input", withTarget.str("op"))
        val stop = wireObj(SessionCommand.Interrupt(page.id, target))
        assertEquals("~/projects/riot-io-teltonika", stop.str("expectCwd"))
        assertEquals("interrupt", stop.str("op"))
        assertNull(wireObj(SessionCommand.Interrupt("s9")).str("expectCwd"))
    }

    @Test fun `a mismatch refusal shows the Mac's own words, or words of its own`() {
        assertEquals("Nothing was typed. X", SessionResultCopy.refusal("target_mismatch", "Nothing was typed. X", "Claude"))
        assertTrue(SessionResultCopy.refusal("target_mismatch", null, "Claude").contains("nothing was typed"))
    }

    // MARK: Send

    @Test fun `steer types into the session the header drew`() {
        val d = decide(RoomComposerMode.Steer)
        assertTrue(d is RoomSend.Decision.Input)
        val t = (d as RoomSend.Decision.Input).target
        assertEquals("s-busy", t.sessionId)
        assertEquals("page", t.project)
        assertTrue(decide(RoomComposerMode.NextTask) is RoomSend.Decision.Input)
    }

    @Test fun `a room whose header is another session than its route sends nothing`() {
        assertEquals(
            RoomSend.Decision.Refuse("This room is showing a different session than it would type into, so nothing was sent. Close it and open the session again."),
            decide(RoomComposerMode.Steer, shown = other),
        )
    }

    @Test fun `an ended session and a session that left the list are refused with a reason`() {
        assertTrue(decide(RoomComposerMode.Steer, ended = true) is RoomSend.Decision.Refuse)
        assertTrue(decide(RoomComposerMode.Steer, live = null) is RoomSend.Decision.Refuse)
    }

    @Test fun `empty and too long text say so`() {
        assertEquals(RoomSend.Decision.Refuse(SessionComposer.Problem.Empty.message), decide(RoomComposerMode.Steer, "   "))
        assertEquals(
            RoomSend.Decision.Refuse(SessionComposer.Problem.TooLong(8001).message),
            decide(RoomComposerMode.Steer, "x".repeat(8001)),
        )
    }

    @Test fun `locked, blocked and disabled rooms say why`() {
        assertEquals(RoomSend.Decision.Refuse("Answer the prompt on your Mac."), decide(RoomComposerMode.Locked("Answer the prompt on your Mac.")))
        assertEquals(RoomSend.Decision.Refuse("Ghostty can't be typed into"), decide(RoomComposerMode.Blocked("Ghostty can't be typed into")))
        assertEquals(RoomSend.Decision.Refuse("Waiting for your Mac."), decide(RoomComposerMode.Disabled("Waiting for your Mac.")))
    }

    @Test fun `tell-instead goes through the page, and without its page it is refused with a reason`() {
        assertEquals(RoomSend.Decision.TellInstead, decide(RoomComposerMode.TellInstead("p"), reply = true))
        assertTrue(decide(RoomComposerMode.TellInstead("p"), reply = false) is RoomSend.Decision.Refuse)
    }

    @Test fun `every refusal carries words`() {
        val modes = listOf(
            RoomComposerMode.Steer, RoomComposerMode.NextTask, RoomComposerMode.TellInstead("p"),
            RoomComposerMode.Locked("a"), RoomComposerMode.Blocked("b"), RoomComposerMode.Disabled("c"),
        )
        for (mode in modes) for (text in listOf("", "  ", "hi")) for (ended in listOf(false, true)) {
            val d = decide(mode, text, ended = ended)
            if (d is RoomSend.Decision.Refuse) assertFalse("refusal has words for $mode", d.why.isEmpty())
        }
    }

    // MARK: the keyboard's Send key

    @Test fun `one Return at the end is the Send key and a paste or a middle newline is not`() {
        assertTrue(DraftSubmit.isReturnKey("run tests", "run tests\n"))
        assertFalse(DraftSubmit.isReturnKey("run", "run\nthe tests"))
        assertFalse(DraftSubmit.isReturnKey("ab", "a\nb"))
        assertTrue("a second Return after a newline is again a Return", DraftSubmit.isReturnKey("a\n", "a\n\n"))
        assertEquals("hi", DraftSubmit.withoutReturn("hi\n"))
        assertEquals("hi", DraftSubmit.withoutReturn("hi"))
    }

    @Test fun `the same message again within a second is one Return, later or different text is new`() {
        val t10 = at(10.0)
        assertTrue(DraftSubmit.isDuplicate("go on ", DraftSubmit.Last("go on", t10), at(10.3)))
        assertFalse(DraftSubmit.isDuplicate("go on", DraftSubmit.Last("go on", t10), at(12.0)))
        assertFalse(DraftSubmit.isDuplicate("stop", DraftSubmit.Last("go on", t10), at(10.3)))
        assertFalse(DraftSubmit.isDuplicate("go on", null, at(10.0)))
    }

    // MARK: the receipt

    private val target = SessionTarget.of(
        nwSession("d8a3f555", title = "riot-io-teltonika", state = "active", host = "cmux", cwd = "~/projects/riot-io-teltonika"),
        "Studio MBP",
    )

    private fun cmd(
        state: SessionDeliveryState,
        kind: SessionCommandKind = SessionCommandKind.INPUT,
        target: SessionTarget? = this.target,
    ) = SentSessionCommand(
        clientId = "c1", sessionId = "d8a3f555", kind = kind, text = "hi", sentAt = nwNow, state = state, target = target,
    )

    private fun receipt(c: SentSessionCommand?, seconds: Double): SendReceipt? = SendReceipt.build(c, "Claude", at(NW_T0 + seconds))

    @Test fun `sending, typed and queued name the target and the Mac`() {
        assertEquals("Sending to riot-io-teltonika · cmux · Studio MBP…", receipt(cmd(SessionDeliveryState.Sending), 1.0)?.headline)
        assertEquals(SendReceipt.Tone.WORKING, receipt(cmd(SessionDeliveryState.Sending), 1.0)?.tone)
        assertEquals("Typed into riot-io-teltonika · cmux · Studio MBP", receipt(cmd(SessionDeliveryState.Typed(null)), 2.0)?.headline)
        assertEquals(SendReceipt.Tone.GOOD, receipt(cmd(SessionDeliveryState.Typed(null)), 2.0)?.tone)
        assertEquals("Already with Claude — it reads it after this step", receipt(cmd(SessionDeliveryState.Queued(null)), 2.0)?.headline)
        assertEquals("riot-io-teltonika · cmux · Studio MBP", receipt(cmd(SessionDeliveryState.Queued(null)), 2.0)?.detail)
    }

    @Test fun `refused and failed say why and which target they were for`() {
        val refused = receipt(cmd(SessionDeliveryState.Refused("target_mismatch", "Nothing was typed.")), 2.0)
        assertEquals("Refused: Nothing was typed.", refused?.headline)
        assertEquals(SendReceipt.Tone.PROBLEM, refused?.tone)
        assertEquals("Target: riot-io-teltonika · cmux · Studio MBP", refused?.detail)
        assertEquals("Not sent: Your Mac is offline.", receipt(cmd(SessionDeliveryState.Failed("Your Mac is offline.")), 2.0)?.headline)
        assertEquals(SendReceipt.Tone.PROBLEM, receipt(cmd(SessionDeliveryState.Failed("x")), 2.0)?.tone)
    }

    @Test fun `no answer names the Mac and the target`() {
        val r = receipt(cmd(SessionDeliveryState.NoAnswer), 25.0)
        assertEquals("No answer from Studio MBP", r?.headline)
        assertTrue(r?.detail?.contains("riot-io-teltonika") == true)
    }

    @Test fun `good news fades after a minute, a refusal stays for ten, a send still waiting is always shown`() {
        assertNull(receipt(cmd(SessionDeliveryState.Typed(null)), 61.0))
        assertNull(receipt(cmd(SessionDeliveryState.Queued(null)), 61.0))
        assertNotNull(receipt(cmd(SessionDeliveryState.Refused(null, "no")), 300.0))
        assertNull(receipt(cmd(SessionDeliveryState.Refused(null, "no")), 601.0))
        assertNotNull(receipt(cmd(SessionDeliveryState.Sending), 3000.0))
    }

    @Test fun `no command or a Stop is no message receipt, and a missing target still never says nothing`() {
        assertNull(receipt(null, 0.0))
        assertNull(receipt(cmd(SessionDeliveryState.Typed(null), kind = SessionCommandKind.INTERRUPT), 1.0))
        assertEquals("Typed into the session", receipt(cmd(SessionDeliveryState.Typed(null), target = null), 1.0)?.headline)
    }

    @Test fun `the Stop line names the same target as the message receipt`() {
        val stopped = cmd(SessionDeliveryState.Typed(null), kind = SessionCommandKind.INTERRUPT)
        assertEquals("Stopped · pressed Esc in riot-io-teltonika · cmux · Studio MBP", SendReceipt.stopLine(stopped, "Claude"))
        assertEquals(
            "Stopping riot-io-teltonika · cmux · Studio MBP…",
            SendReceipt.stopLine(cmd(SessionDeliveryState.Sending, kind = SessionCommandKind.INTERRUPT), "Claude"),
        )
        assertTrue(
            SendReceipt.stopLine(cmd(SessionDeliveryState.Refused(null, "Page can't stop this."), kind = SessionCommandKind.INTERRUPT), "Claude")
                ?.startsWith("Couldn't stop riot-io-teltonika") == true,
        )
        assertNull(SendReceipt.stopLine(cmd(SessionDeliveryState.Typed(null)), "Claude"))
    }

    @Test fun `answer labels and the question_changed copy`() {
        assertEquals("Sending your answers…", SessionDeliveryState.Sending.label(SessionCommandKind.ANSWER))
        assertEquals("Answered", SessionDeliveryState.Typed(null).label(SessionCommandKind.ANSWER))
        assertTrue(SessionResultCopy.refusal("question_changed", null, "Claude").contains("changed"))
        assertEquals(
            "Terminal.app can't press keys",
            SessionResultCopy.refusal("answer_unsupported", "Terminal.app can't press keys", "Claude"),
        )
    }

    // MARK: the wire, for the other commands

    @Test fun `the answer command carries the prompt key, the answers and the folder the room showed`() {
        val answers = listOf(AnswerWire(0, listOf(0), null), AnswerWire(1, listOf(0), "only me"))
        val t = SessionTarget.of(nwSession("d8a3f555", title = "page", state = "waitingOnUser", host = "tmux", cwd = "~/projects/page"), "M")
        val obj = wireObj(SessionCommand.Answer("s1", "toolu_1", answers, t))
        assertEquals("answer", obj.str("op"))
        assertEquals("toolu_1", obj.str("promptKey"))
        assertEquals("s1", obj.str("sessionId"))
        val wire = obj["answers"] as kotlinx.serialization.json.JsonArray
        assertEquals(2, wire.size)
        val second = wire[1] as JsonObject
        assertEquals("1", (second["i"] as JsonPrimitive).content)
        assertEquals("only me", second.str("other"))
        assertNull("no other key when none", (wire[0] as JsonObject).str("other"))
        assertEquals("~/projects/page", obj.str("expectCwd"))
    }

    @Test fun `the Stop-all command is the bare interruptAll op`() {
        val obj = wireObj(SessionCommand.InterruptAll)
        assertEquals("interruptAll", obj.str("op"))
        assertNull(obj.str("sessionId"))
    }
}
