package app.page.android.model

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionLogicTest {
    @Test
    fun groupingAndOrdering() {
        val sections = SessionGrouping.sections(
            listOf(
                ls("idle-old", LiveSessionState.IDLE, 10.0), ls("act", LiveSessionState.ACTIVE, 50.0),
                ls("wait-u", LiveSessionState.WAITING_ON_USER, 20.0), ls("rl", LiveSessionState.RATE_LIMITED, 90.0),
                ls("wait-a", LiveSessionState.WAITING_ON_APPROVAL, 30.0), ls("unk", LiveSessionState.UNKNOWN, null),
                ls("act2", LiveSessionState.ACTIVE, 60.0), ls("off", LiveSessionState.OFFLINE, 70.0),
            )
        )
        assertEquals(listOf(SessionGroup.NEEDS_YOU, SessionGroup.WORKING, SessionGroup.IDLE), sections.map { it.group })
        assertEquals(listOf("wait-a", "wait-u"), sections[0].sessions.map { it.id })
        assertEquals(listOf("act2", "act"), sections[1].sessions.map { it.id })
        assertEquals("idle by recency, undated last", listOf("rl", "off", "idle-old", "unk"), sections[2].sessions.map { it.id })
        assertEquals(listOf(SessionGroup.IDLE), SessionGrouping.sections(listOf(ls("a", LiveSessionState.IDLE, 1.0))).map { it.group })
        assertTrue(SessionGrouping.sections(emptyList()).isEmpty())
        assertEquals(2, SessionGrouping.needsYouCount(listOf(ls("a", LiveSessionState.WAITING_ON_USER, 1.0), ls("b", LiveSessionState.ACTIVE, 1.0), ls("c", LiveSessionState.WAITING_ON_APPROVAL, 1.0))))
        assertTrue(LiveSessionState.entries.all { it.label.isNotEmpty() })
        assertTrue("Stop only while active", ls("x", LiveSessionState.ACTIVE, 1.0).isStoppable && !ls("x", LiveSessionState.IDLE, 1.0).isStoppable)
        assertNull("open page only while waiting", ls("x", LiveSessionState.IDLE, 1.0).openPageId)
        assertTrue(AgentBackend.fromWire("  ") == AgentBackend.Other("unknown") && AgentBackend.fromWire("Claude") == AgentBackend.Known(InterventionBackend.CLAUDE))
    }

    private fun result(code: CommandResult.Code, reason: String? = null, detail: String? = null) =
        CommandResult("c", code == CommandResult.Code.DELIVERED || code == CommandResult.Code.QUEUED, code, reason, detail, null)

    @Test
    fun deliveryStateMachine() {
        val input = SessionCommandKind.INPUT
        val stop = SessionCommandKind.INTERRUPT
        val d = SessionDeliveryState.Sending
        assertTrue(d.isPending && d.label(input) == "Sending…" && d.label(stop) == "Stopping…")
        assertEquals(SessionDeliveryState.Sending, d.timedOut(CMD_NOW, CMD_NOW.plusSeconds(19.9)))
        assertEquals(SessionDeliveryState.NoAnswer, d.timedOut(CMD_NOW, CMD_NOW.plusSeconds(20.0)))
        assertEquals(SessionDeliveryState.Typed("Typed into cmux"), d.applying(result(CommandResult.Code.DELIVERED, detail = "Typed into cmux"), "Claude"))
        assertEquals(SessionDeliveryState.Queued(null), d.applying(result(CommandResult.Code.QUEUED), "Claude"))
        assertEquals("Queued — Claude reads it after the current step.", SessionDeliveryState.Queued(null).explanation(input, "Claude"))
        val refused = d.applying(result(CommandResult.Code.REFUSED, reason = "digit_while_busy"), "Claude") as SessionDeliveryState.Refused
        assertEquals("digit_while_busy", refused.reason)
        assertEquals("Starts with a number: wait for Claude to finish, or add a word first.", refused.message)
        assertEquals(SessionDeliveryState.Failed("tmux went away"), d.applying(result(CommandResult.Code.FAILED, detail = "tmux went away"), "Claude"))
        assertEquals("late result beats giving up", SessionDeliveryState.Typed(null), SessionDeliveryState.NoAnswer.applying(result(CommandResult.Code.DELIVERED), "Claude"))
        assertEquals("result beats a lost HTTP response", SessionDeliveryState.Queued(null), SessionDeliveryState.Failed("lost").applying(result(CommandResult.Code.QUEUED), "Claude"))
        assertEquals("first result wins", SessionDeliveryState.Typed(null), SessionDeliveryState.Typed(null).applying(result(CommandResult.Code.REFUSED, reason = "replay"), "Claude"))
        assertEquals(SessionDeliveryState.Typed(null), SessionDeliveryState.Typed(null).timedOut(CMD_NOW, CMD_NOW.plusSeconds(99.0)))
        assertEquals("202 keeps waiting", SessionDeliveryState.Sending, d.afterPost(SessionCommandOutcome.Accepted))
        assertEquals(SessionDeliveryState.Failed(SessionCommandOutcome.MacOffline.failureMessage!!), d.afterPost(SessionCommandOutcome.MacOffline))
        assertEquals(SessionDeliveryState.Typed(null), SessionDeliveryState.Typed(null).afterPost(SessionCommandOutcome.MacOffline))
        assertTrue(SessionDeliveryState.Typed(null).label(stop) == "Stopped" && SessionDeliveryState.NoAnswer.label(input) == "No answer from your Mac")
        assertTrue(SessionDeliveryState.NoAnswer.explanation(input, "Claude")!!.contains("20 seconds"))

        // TalkBack hears the same status and explanation the bubble shows.
        val draft = d.applying(result(CommandResult.Code.REFUSED, reason = "draft"), "Claude")
        assertEquals("Refused. " + SessionResultCopy.refusal("draft", null, "Claude"), draft.spokenBubbleStatus(input, "Claude"))
        val noAnswer = SessionDeliveryState.NoAnswer.spokenBubbleStatus(input, "Claude")
        assertTrue(noAnswer.startsWith("No answer from your Mac. ") && noAnswer.contains("check the transcript"))
        assertEquals("Not sent. tmux went away", SessionDeliveryState.Failed("tmux went away").spokenBubbleStatus(input, "Claude"))
        assertNull(SessionDeliveryState.Typed("Typed into cmux").bubbleExplanation(input, "Claude"))
        assertEquals("Typed", SessionDeliveryState.Typed("Typed into cmux").spokenBubbleStatus(input, "Claude"))
        assertEquals("Sending…", SessionDeliveryState.Sending.spokenBubbleStatus(input, "Claude"))
    }

    @Test
    fun commandOutcomes() {
        assertEquals(SessionCommandOutcome.Accepted, SessionCommandOutcome.from(202, """{"ok":true}"""))
        assertEquals(SessionCommandOutcome.MacOffline, SessionCommandOutcome.from(503, """{"error":"mac_offline"}"""))
        assertEquals(SessionCommandOutcome.Invalid, SessionCommandOutcome.from(400, """{"error":"invalid_envelope"}"""))
        assertEquals(SessionCommandOutcome.TooLarge, SessionCommandOutcome.from(413, """{"error":"too_large"}"""))
        assertEquals(SessionCommandOutcome.RateLimited, SessionCommandOutcome.from(429, """{"error":"rate_limited"}"""))
        assertEquals(SessionCommandOutcome.Unauthorized, SessionCommandOutcome.from(401, ""))
        assertEquals(SessionCommandOutcome.Retired("Replaced"), SessionCommandOutcome.from(410, """{"error":"token_retired","why":"Replaced"}"""))
        assertEquals(SessionCommandOutcome.RelayTooOld, SessionCommandOutcome.from(404, "Not found"))
        assertTrue(SessionCommandOutcome.from(500, "") is SessionCommandOutcome.Failed)
        assertNull(SessionCommandOutcome.Accepted.failureMessage)
    }

    @Test
    fun composer() {
        val vecRoot = bytes(0..31)
        assertEquals(SessionComposer.Validation.Bad(SessionComposer.Problem.Empty), SessionComposer.validate("  \n "))
        assertEquals(SessionComposer.Validation.Ok("hi"), SessionComposer.validate("  hi \n"))
        val a8000 = "a".repeat(8000)
        assertEquals(SessionComposer.Validation.Ok(a8000), SessionComposer.validate(a8000))
        assertEquals(SessionComposer.Validation.Bad(SessionComposer.Problem.TooLong(8001)), SessionComposer.validate("a".repeat(8001)))
        assertNotEquals("limit counts trimmed text", SessionComposer.Validation.Bad(SessionComposer.Problem.TooLong(8003)), SessionComposer.validate(" $a8000  "))
        val family = "👨‍👩‍👧‍👦".repeat(8000)
        assertEquals("8000 family emoji are 8000 characters", SessionComposer.Validation.Ok(family), SessionComposer.validate(family))
        val familyBody = SessionCommand.requestBody(SessionCommand.Input("s", family).plaintext(UUID.randomUUID().toString(), "v", CMD_NOW), vecRoot)
        assertFalse("but too large for the relay's 64 KiB body", SessionComposer.fitsRelay(familyBody))
        val asciiBody = SessionCommand.requestBody(
            SessionCommand.Input(UUID.randomUUID().toString(), a8000).plaintext(UUID.randomUUID().toString(), UUID.randomUUID().toString(), CMD_NOW), vecRoot,
        )
        assertTrue("8000 ASCII characters fit", SessionComposer.fitsRelay(asciiBody))
        assertTrue(SessionComposer.Problem.TooLarge.message.contains("too large"))
    }

    @Test
    fun reasonCopy() {
        val reasons = listOf("waiting", "unknown_state", "not_typable", "draft", "digit_while_busy", "ended", "codex_mid_turn",
            "disabled", "stale", "replay", "not_found", "interrupt_unsupported", "error")
        val fallback = SessionResultCopy.refusal("brand_new", null, "Claude")
        for (r in reasons) assertNotEquals("$r has its own copy", fallback, SessionResultCopy.refusal(r, null, "Claude"))
        assertEquals("reason copy is distinct", reasons.size, reasons.map { SessionResultCopy.refusal(it, null, "Claude") }.toSet().size)
        assertEquals("Mac says no", SessionResultCopy.refusal("brand_new", "Mac says no", "Claude"))
        assertTrue(SessionResultCopy.refusal("waiting", null, "Codex").startsWith("Codex"))
        assertEquals("Codex is mid-turn — Page can type once the turn ends.", SessionResultCopy.refusal("codex_mid_turn", null, "Codex"))
    }

    private fun te(id: String, role: TranscriptRole, text: String, at: Double? = null) =
        TranscriptEntry(id, role, text, at?.let { CMD_NOW.plusSeconds(it) }, null)

    private fun sent(cid: String, text: String, state: SessionDeliveryState, at: Double = 0.0, kind: SessionCommandKind = SessionCommandKind.INPUT) =
        SentSessionCommand(cid, "s", kind, text, CMD_NOW.plusSeconds(at), state)

    @Test
    fun transcriptTimeline() {
        assertEquals("run the tests", TranscriptTimeline.normalise("  !run\u0007  the\n\ntests "))
        assertTrue(TranscriptTimeline.echoes("run the tests", "!run  the tests"))
        assertFalse(TranscriptTimeline.echoes("run the tests", "run the test suite"))
        val longText = "word ".repeat(600)
        assertTrue("capped entry echoes by prefix", TranscriptTimeline.echoes(longText.take(2000) + "…", longText))

        val tl = TranscriptTimeline.merge(
            listOf(te("u0", TranscriptRole.USER, "yes", -600.0), te("a0", TranscriptRole.ASSISTANT, "ok"), te("u1", TranscriptRole.USER, "yes", 2.0), te("t1", TranscriptRole.TOOL, "Bash: ls")),
            listOf(
                sent("c1", "yes", SessionDeliveryState.Typed(null)), sent("c2", "nope", SessionDeliveryState.Refused("draft", "m")),
                sent("c3", "later", SessionDeliveryState.Sending, at = 5.0), sent("c4", "", SessionDeliveryState.Sending, kind = SessionCommandKind.INTERRUPT),
            ),
        )
        assertEquals(listOf("e:u0", "e:a0", "e:u1", "e:t1", "p:c2", "p:c3"), tl.map { it.id })
        assertEquals("echo attached to the entry after the send", "c1", (tl[2] as TranscriptTimeline.Item.Entry).delivery?.clientId)
        assertNull("older identical prompt not claimed", (tl[0] as TranscriptTimeline.Item.Entry).delivery)

        val refusedTwin = TranscriptTimeline.merge(listOf(te("u", TranscriptRole.USER, "nope")), listOf(sent("c", "nope", SessionDeliveryState.Refused(null, "m"))))
        assertEquals("refused message never claims an entry", listOf("e:u", "p:c"), refusedTwin.map { it.id })

        val twice = TranscriptTimeline.merge(
            listOf(te("u1", TranscriptRole.USER, "go"), te("u2", TranscriptRole.USER, "go")),
            listOf(sent("c1", "go", SessionDeliveryState.Typed(null), at = 0.0), sent("c2", "go", SessionDeliveryState.Typed(null), at = 1.0)),
        )
        assertEquals(2, twice.size)
        assertEquals("c1", (twice[0] as TranscriptTimeline.Item.Entry).delivery?.clientId)
        assertEquals("c2", (twice[1] as TranscriptTimeline.Item.Entry).delivery?.clientId)

        val redacted = TranscriptTimeline.merge(listOf(te("u", TranscriptRole.USER, "token [REDACTED]")), listOf(sent("c", "token sk-123", SessionDeliveryState.Typed(null))))
        assertEquals("unmatched echo shows a duplicate rather than losing the status", 2, redacted.size)

        // An identical message already on screen when this one was sent is never its echo.
        var yes = sent("c-yes", "yes", SessionDeliveryState.Sending).copy(priorEntryIds = setOf("old-yes", "old-undated"))
        val before = TranscriptTimeline.merge(listOf(te("old-yes", TranscriptRole.USER, "yes", -120.0), te("old-undated", TranscriptRole.USER, "yes")), listOf(yes))
        assertEquals(listOf("e:old-yes", "e:old-undated", "p:c-yes"), before.map { it.id })
        yes = yes.copy(state = SessionDeliveryState.Typed(null))
        val after = TranscriptTimeline.merge(
            listOf(te("old-yes", TranscriptRole.USER, "yes", -120.0), te("old-undated", TranscriptRole.USER, "yes"), te("new-yes", TranscriptRole.USER, "yes", 1.0)),
            listOf(yes),
        )
        val real = after[2] as TranscriptTimeline.Item.Entry
        assertTrue(real.entry.id == "new-yes" && real.delivery?.clientId == "c-yes" && after.size == 3)
        assertNull((after[0] as TranscriptTimeline.Item.Entry).delivery)
    }

    private val online = MacPresence.Online(CMD_NOW)

    private fun avail(now: java.time.Instant = CMD_NOW, f: (SessionAvailability.Inputs) -> SessionAvailability.Inputs = { it }): SessionAvailability {
        val base = SessionAvailability.Inputs(
            hasKey = true, relayFeatures = setOf("sessions-v1"), presence = online,
            socketConnected = true, waitStartedAt = CMD_NOW.plusSeconds(-1.0), hasList = false,
        )
        return SessionAvailability.evaluate(f(base), now)
    }

    @Test
    fun availability() {
        assertEquals(SessionAvailability.RelayTooOld, avail { it.copy(relayFeatures = emptySet()) })
        assertEquals("relay first", SessionAvailability.RelayTooOld, avail { it.copy(relayFeatures = emptySet(), hasKey = false) })
        assertEquals("features unknown yet: don't block", SessionAvailability.Waiting, avail { it.copy(relayFeatures = null) })
        assertEquals(SessionAvailability.NeedsRepair(false), avail { it.copy(hasKey = false) })
        assertEquals(SessionAvailability.NeedsRepair(true), avail { it.copy(keyMismatch = true, hasList = true) })
        assertEquals(SessionAvailability.MacOffline, avail { it.copy(presence = MacPresence.Offline(null)) })
        assertEquals("offline hides a stale list", SessionAvailability.MacOffline, avail { it.copy(presence = MacPresence.Offline(null), hasList = true) })
        assertEquals(SessionAvailability.MacOffline, avail { it.copy(presence = MacPresence.Stale(CMD_NOW)) })
        assertEquals("503 hint", SessionAvailability.MacOffline, avail { it.copy(macOfflineHint = true, hasList = true) })
        assertEquals(SessionAvailability.Ready, avail { it.copy(hasList = true) })
        assertEquals(SessionAvailability.MacDisabled, avail { it.copy(hasList = true, macDisabled = true) })
        assertEquals("disabled only counts once a list arrived", SessionAvailability.Waiting, avail { it.copy(macDisabled = true) })
        assertEquals(SessionAvailability.ClockSkew, avail { it.copy(onlyStaleFrames = true) })
        assertEquals("inside the 5 s window", SessionAvailability.Waiting, avail())
        assertEquals(SessionAvailability.MacTooOld, avail(CMD_NOW.plusSeconds(4.5)))
        assertEquals("presence unknown: keep waiting", SessionAvailability.Waiting, avail(CMD_NOW.plusSeconds(30.0)) { it.copy(presence = MacPresence.Unknown) })
        assertEquals("socket down", SessionAvailability.Waiting, avail(CMD_NOW.plusSeconds(30.0)) { it.copy(socketConnected = false) })
        assertEquals("no wait start yet", SessionAvailability.Waiting, avail(CMD_NOW.plusSeconds(30.0)) { it.copy(waitStartedAt = null) })
    }
}
