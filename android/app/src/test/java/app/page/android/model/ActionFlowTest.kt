package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The pulse press, Stop-all's plan and outcome, the action flow (arm, gates, reply mapping, the card's outcome)
 * and the decision phases, ported from the "Pulse and Stop-all" and "action flow, decision phases and content"
 * checks in iOS/Tests/LogicTests.swift.
 */
class ActionFlowTest {
    private fun near(a: Double, b: Double, eps: Double = 1e-6) = abs(a - b) < eps

    // MARK: pulse and Stop-all

    @Test fun `a pulse press is a tap, an abandoned hold or a completed hold by how long it was held`() {
        assertEquals(PulsePress.TAP, PulsePress.onRelease(0.1))
        assertEquals("dead zone is exclusive", PulsePress.TAP, PulsePress.onRelease(0.3))
        assertEquals(PulsePress.ABANDONED_HOLD, PulsePress.onRelease(0.31))
        assertEquals(PulsePress.ABANDONED_HOLD, PulsePress.onRelease(1.49))
        assertEquals("a full ring completes", PulsePress.COMPLETED_HOLD, PulsePress.onRelease(1.5))
    }

    private val nine: List<LiveSession> = (1..9).map { i ->
        nwSession("p$i", title = if (i <= 4) "t$i" else "idle$i", state = if (i <= 4) "active" else "idle", canInterrupt = true)
    }

    @Test fun `Stop-all names the busy scope and the Mac and can stop`() {
        val plan = StopPlan.build(nine, hasSessionList = true, macName = "Studio MBP")
        assertEquals(4, plan.busy)
        assertEquals("Press Esc in 4 busy sessions on Studio MBP", plan.scope)
        assertEquals("Stop 4 busy sessions on Studio MBP. Presses Esc in each.", plan.biometricReason)
        assertTrue(plan.canStop)
        assertEquals("t1, t2, t3, +1", plan.names)
        assertEquals("Press Esc in 4 busy sessions on your Mac", StopPlan.build(nine, hasSessionList = true).scope)
    }

    @Test fun `nothing busy cannot stop, and a status count stands in before the list arrives`() {
        val none = StopPlan.build(emptyList(), hasSessionList = true)
        assertEquals(0, none.busy)
        assertFalse(none.canStop)
        assertEquals("Nothing is working right now", none.blocker)
        assertEquals(3, StopPlan.build(emptyList(), hasSessionList = false, workingFromStatus = 3).busy)
    }

    @Test fun `only an asked Stop-all is a success, and the nothing-busy copy is the iOS copy`() {
        assertTrue(StopOutcome.Asked.isSuccess)
        assertFalse(StopOutcome.NothingBusy.isSuccess)
        assertFalse(StopOutcome.Cancelled.isSuccess)
        assertEquals("Nothing was working, so nothing was sent.", StopOutcome.NothingBusy.message)
    }

    // MARK: the action flow

    @Test fun `the arm lasts 1_2 s, is halfway at 0_6 s, and its progress and remaining time clamp`() {
        assertEquals(1.2, ArmSpec.duration, 0.0)
        assertTrue(near(ArmSpec.progress(0.6), 0.5))
        assertTrue(ArmSpec.isComplete(1.2))
        assertTrue(near(ArmSpec.remaining(0.3), 0.9))
        assertEquals(0.0, ArmSpec.remaining(5.0), 0.0)
        assertEquals(1.0, ArmSpec.progress(5.0), 0.0)
        assertEquals(0.0, ArmSpec.progress(-1.0), 0.0)
    }

    @Test fun `swipe and tap approve and deny, stop, carry on and a written reply arm, hold does not`() {
        assertTrue(ActionGate.requiresArm(RowAction.Kind.APPROVE, CommitGesture.SWIPE))
        assertTrue(ActionGate.requiresArm(RowAction.Kind.APPROVE, CommitGesture.TAP))
        assertTrue(ActionGate.requiresArm(RowAction.Kind.DENY, null))
        assertTrue(ActionGate.requiresArm(RowAction.Kind.STOP, null))
        assertTrue(ActionGate.requiresArm(RowAction.Kind.CARRY_ON, null))
        assertTrue(ActionGate.requiresArm(RowAction.Kind.TELL_INSTEAD, null))
        assertFalse("hold approve does not arm (the hold is the arm)", ActionGate.requiresArm(RowAction.Kind.APPROVE, CommitGesture.HOLD))
        assertFalse(ActionGate.requiresArm(RowAction.Kind.OPEN_ON_MAC, null))
    }

    @Test fun `only a hold approve asks for biometrics, and only open on Mac is not sendable`() {
        assertTrue(ActionGate.requiresBiometrics(RowAction.Kind.APPROVE, CommitGesture.HOLD))
        assertFalse(ActionGate.requiresBiometrics(RowAction.Kind.APPROVE, CommitGesture.SWIPE))
        assertFalse(ActionGate.requiresBiometrics(RowAction.Kind.APPROVE, CommitGesture.TAP))
        assertFalse(ActionGate.requiresBiometrics(RowAction.Kind.DENY, CommitGesture.HOLD))
        assertFalse(ActionGate.isSendable(RowAction.Kind.OPEN_ON_MAC))
        assertTrue(ActionGate.isSendable(RowAction.Kind.APPROVE))
        assertTrue(ActionGate.isSendable(RowAction.Kind.TELL_INSTEAD))
    }

    @Test fun `approve is option 1, deny and stop are Esc, a written reply is trimmed and blank is nil`() {
        assertEquals(ReplyRequest(ReplyAction.APPROVE, ""), ReplyMapping.request(RowAction.Kind.APPROVE))
        assertEquals(ReplyRequest(ReplyAction.DENY, ""), ReplyMapping.request(RowAction.Kind.DENY))
        assertEquals(ReplyRequest(ReplyAction.DENY, ""), ReplyMapping.request(RowAction.Kind.STOP))
        assertEquals(ReplyRequest(ReplyAction.CARRY_ON, ""), ReplyMapping.request(RowAction.Kind.CARRY_ON))
        assertEquals(ReplyRequest(ReplyAction.CUSTOM, "hi"), ReplyMapping.request(RowAction.Kind.TELL_INSTEAD, "  hi "))
        assertNull(ReplyMapping.request(RowAction.Kind.TELL_INSTEAD, "  "))
        assertNull(ReplyMapping.request(RowAction.Kind.OPEN_ON_MAC))
        assertFalse(ReplyMapping.needsDraftDecision("  "))
        assertTrue(ReplyMapping.needsDraftDecision("x"))
        assertEquals("Approve without your note?", DraftQuestion.title(ReplyAction.APPROVE))
    }

    @Test fun `an armed action counts down and turns ready, an unarmed one is ready at once`() {
        val pend = PendingAction("r", RowAction.Kind.APPROVE, "", CommitGesture.SWIPE, nwNow, armed = true)
        val p = pend.phase(nwNow.plusMillis(600))
        assertTrue(p is PendingAction.Phase.Arming)
        assertTrue(near((p as PendingAction.Phase.Arming).progress, 0.5))
        assertEquals("Sending in 0.6 s · tap to cancel", pend.armLabel(nwNow.plusMillis(600)))
        assertEquals(PendingAction.Phase.Ready, pend.phase(nwNow.plusMillis(1300)))
        assertEquals(
            PendingAction.Phase.Ready,
            PendingAction("r", RowAction.Kind.DENY, "", null, nwNow, armed = false).phase(nwNow),
        )
    }

    @Test fun `the card shows arming before anything, then sending, then the confirmed delivery or the problem`() {
        val pend = PendingAction("r", RowAction.Kind.APPROVE, "", CommitGesture.SWIPE, nwNow, armed = true)
        val arming = CardOutcome.from(pend, ReplyDelivery.Delivered(null), nwNow.plusMillis(600))
        assertTrue("card shows arming before anything", arming is CardOutcome.Arming)
        assertTrue(near((arming as CardOutcome.Arming).progress, 0.5))
        assertEquals(CardOutcome.None, CardOutcome.from(null, null, nwNow))
        assertEquals("sent is sending, never success", CardOutcome.Sending, CardOutcome.from(null, ReplyDelivery.Sent(queued = false, at = nwNow), nwNow))
        assertEquals(CardOutcome.Sending, CardOutcome.from(null, ReplyDelivery.Sending, nwNow))
        assertEquals(
            CardOutcome.Delivered("typed into the session on your Mac"),
            CardOutcome.from(null, ReplyDelivery.Delivered(null), nwNow),
        )
        assertEquals(CardOutcome.Delivered("x"), CardOutcome.from(null, ReplyDelivery.Delivered("x"), nwNow))
        assertEquals(CardOutcome.Problem("x"), CardOutcome.from(null, ReplyDelivery.Failed("x"), nwNow))
        assertEquals(CardOutcome.Problem("Already answered at the Mac"), CardOutcome.from(null, ReplyDelivery.AlreadyReplied, nwNow))
        assertEquals(CardOutcome.Problem("Prompt closed before your answer"), CardOutcome.from(null, ReplyDelivery.Gone, nwNow))
    }

    // MARK: decision phases

    private fun inputs(
        delivery: ReplyDelivery? = null,
        live: Boolean = true,
        snapshot: Boolean = false,
        lookup: Boolean = false,
        reason: String? = null,
        closeLookup: Boolean = false,
        legacy: Boolean = false,
        now: java.time.Instant = nwNow,
    ) = DecisionPhase.Inputs(
        delivery = delivery, isLive = live, hasSnapshot = snapshot, lookupFinished = lookup,
        closeReason = reason, closeLookupFinished = closeLookup, now = now, legacyRelay = legacy,
    )

    @Test fun `a live page with no delivery is open, and a page not live is loading or missing`() {
        assertEquals(DecisionPhase.Open, DecisionPhase.derive(inputs()))
        assertEquals(DecisionPhase.Loading, DecisionPhase.derive(inputs(live = false)))
        assertEquals(DecisionPhase.Missing, DecisionPhase.derive(inputs(live = false, lookup = true)))
    }

    @Test fun `a snapshot closed as replied is delivered`() {
        assertEquals(
            DecisionPhase.Delivered(null),
            DecisionPhase.derive(inputs(ReplyDelivery.Delivered(null), live = false, snapshot = true, reason = "replied", closeLookup = true)),
        )
    }

    @Test fun `a sent reply is slow after 60 s, unconfirmed after the ack window, and a queued one is never unconfirmed`() {
        assertEquals(DecisionPhase.Sent(queued = false, slow = false), DecisionPhase.derive(inputs(ReplyDelivery.Sent(false, nwNow.minusSeconds(30)))))
        assertEquals(DecisionPhase.Sent(queued = false, slow = true), DecisionPhase.derive(inputs(ReplyDelivery.Sent(false, nwNow.minusSeconds(90)))))
        assertEquals(DecisionPhase.Unconfirmed, DecisionPhase.derive(inputs(ReplyDelivery.Sent(false, nwNow.minusSeconds(21L * 60)))))
        assertEquals(
            "legacy relay unconfirmed after 61 s",
            DecisionPhase.Unconfirmed,
            DecisionPhase.derive(inputs(ReplyDelivery.Sent(false, nwNow.minusSeconds(61)), legacy = true)),
        )
        assertEquals(
            "queued is never unconfirmed",
            DecisionPhase.Sent(queued = true, slow = true),
            DecisionPhase.derive(inputs(ReplyDelivery.Sent(true, nwNow.minusSeconds(3600)))),
        )
    }

    @Test fun `a live failure shows the failure, gone is resolved, sending and already-replied are themselves`() {
        assertEquals(DecisionPhase.Failed("x"), DecisionPhase.derive(inputs(ReplyDelivery.Failed("x"))))
        assertEquals(DecisionPhase.Resolved("This page was already resolved."), DecisionPhase.derive(inputs(ReplyDelivery.Gone)))
        assertEquals(DecisionPhase.Sending, DecisionPhase.derive(inputs(ReplyDelivery.Sending)))
        assertEquals(DecisionPhase.AlreadyReplied, DecisionPhase.derive(inputs(ReplyDelivery.AlreadyReplied)))
    }

    @Test fun `auto-close delays, which phases take input, and where the copy and tone sit`() {
        assertEquals(1.4, DecisionPhase.Delivered(null).autoCloseDelay!!, 0.0)
        assertEquals(2.2, DecisionPhase.Resolved("x").autoCloseDelay!!, 0.0)
        assertEquals(2.2, DecisionPhase.AlreadyReplied.autoCloseDelay!!, 0.0)
        assertNull(DecisionPhase.Open.autoCloseDelay)
        assertTrue(listOf(DecisionPhase.Open, DecisionPhase.Failed("x"), DecisionPhase.Unconfirmed).all { it.acceptsInput })
        assertFalse(
            listOf(DecisionPhase.Sending, DecisionPhase.Delivered(null), DecisionPhase.AlreadyReplied, DecisionPhase.Loading, DecisionPhase.Missing, DecisionPhase.Resolved("x"))
                .any { it.acceptsInput },
        )
        assertEquals("Already answered at the Mac", DecisionPhase.AlreadyReplied.statusLine(false)?.text)
        assertNull(DecisionPhase.Open.statusLine(false))
        assertEquals(DecisionPhase.Tone.GOOD, DecisionPhase.Delivered(null).statusLine(false)?.tone)
        assertEquals(DecisionPhase.Tone.NEUTRAL, DecisionPhase.Sent(false, false).statusLine(false)?.tone)
        assertTrue(DecisionPhase.Delivered(null).isDelivered)
        assertFalse(DecisionPhase.Sent(false, false).isDelivered)
    }
}
