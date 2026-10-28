package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RepliesTest {
    @Test
    fun replyOutcomes() {
        assertEquals(ReplyOutcome.Accepted(true), ReplyOutcome.from(200, """{"ok":true,"queued":true}"""))
        assertEquals(ReplyOutcome.Accepted(false), ReplyOutcome.from(200, ""))
        assertEquals(ReplyOutcome.AlreadyReplied, ReplyOutcome.from(409, ""))
        assertEquals(ReplyOutcome.Gone, ReplyOutcome.from(410, ""))
        assertEquals(ReplyOutcome.Gone, ReplyOutcome.from(404, "Not found"))
        assertEquals(ReplyOutcome.Unauthorized, ReplyOutcome.from(401, ""))
        assertTrue(ReplyOutcome.from(500, "") is ReplyOutcome.Failed)
        assertNotNull("empty custom refused", ReplyOutcome.validate("  ", ReplyAction.CUSTOM))
        assertNull(ReplyOutcome.validate("", ReplyAction.APPROVE))
    }

    @Test
    fun conflictBodies() {
        // A reply still waiting on the Mac is not "already answered".
        assertEquals(ReplyOutcome.InFlight, ReplyOutcome.from(409, """{"error":"already_replied","repliedAt":"2026-10-24T01:02:03Z","deliveryStatus":"pending"}"""))
        assertEquals(ReplyOutcome.InFlight, ReplyOutcome.from(409, """{"error":"reply_in_flight","deliveryStatus":"pending"}"""))
        assertEquals(ReplyOutcome.AlreadyReplied, ReplyOutcome.from(409, """{"error":"already_replied","deliveryStatus":"delivered"}"""))
        assertEquals(ReplyOutcome.AlreadyReplied, ReplyOutcome.from(409, """{"error":"already_replied"}"""))
    }

    @Test
    fun retiredVersusGone() {
        val retiredBody = """{"error":"token_retired","why":"This pairing was replaced on your Mac — scan the new QR code"}"""
        assertEquals(ReplyOutcome.Retired("This pairing was replaced on your Mac — scan the new QR code"), ReplyOutcome.from(410, retiredBody))
        assertEquals(ReplyOutcome.Gone, ReplyOutcome.from(410, """{"error":"gone","why":"prompt_closed","closeReason":"replied"}"""))
        assertEquals(ReplyOutcome.Gone, ReplyOutcome.from(410, """{"error":"gone","why":"expired"}"""))
    }

    @Test
    fun approveOrDenyOnly() {
        val v1Why = "This page comes from an older Page hook that can only apply Approve or Deny. Update it in Page → Phone approvals."
        assertEquals(ReplyOutcome.Failed(v1Why), ReplyOutcome.from(422, """{"error":"approve_or_deny_only","why":"$v1Why"}"""))
        assertEquals(ReplyOutcome.Failed(ReplyOutcome.DECISIONS_ONLY_MESSAGE), ReplyOutcome.from(422, """{"error":"approve_or_deny_only"}"""))
        assertEquals(ReplyOutcome.Failed(ReplyOutcome.DECISIONS_ONLY_MESSAGE), ReplyOutcome.from(422, """{"error":"approve_or_deny_only","why":"  "}"""))
        assertEquals(ReplyOutcome.Failed("The relay refused the reply (something_new)."), ReplyOutcome.from(422, """{"error":"something_new"}"""))
        assertEquals(ReplyOutcome.Failed("The relay returned an error (HTTP 422)."), ReplyOutcome.from(422, ""))
        val m = (ReplyOutcome.from(422, """{"error":"approve_or_deny_only"}""") as ReplyOutcome.Failed).message
        assertFalse("no raw error code in UI copy", m.contains("approve_or_deny_only"))
    }

    private val sentAt = at(50_000.0)

    @Test
    fun confirmationWindowMatchesTheWorker() {
        assertFalse(ReplyConfirmation.isUnconfirmed(sentAt, false, sentAt.plusSeconds(61.0), false))
        assertFalse(ReplyConfirmation.isUnconfirmed(sentAt, false, sentAt.plusSeconds(19 * 60.0), false))
        assertTrue(ReplyConfirmation.isUnconfirmed(sentAt, false, sentAt.plusSeconds(20 * 60.0 + 1), false))
        assertTrue("legacy relay: 60s", ReplyConfirmation.isUnconfirmed(sentAt, false, sentAt.plusSeconds(61.0), true))
        assertFalse("queued never unconfirmed", ReplyConfirmation.isUnconfirmed(sentAt, true, sentAt.plusSeconds(3 * 3600.0), false))
        assertEquals(1200.0, ReplyConfirmation.WORKER_ACK_TIMEOUT, 0.0)
    }

    @Test
    fun deliveryStateMerges() {
        assertEquals(ReplyDelivery.Sent(true, sentAt), ReplyDelivery.afterAccepted(ReplyDelivery.Sending, true, sentAt))
        assertEquals(ReplyDelivery.Failed("The prompt is no longer showing"), ReplyDelivery.afterAccepted(ReplyDelivery.Failed("The prompt is no longer showing"), false, sentAt))
        assertEquals(ReplyDelivery.Delivered("x"), ReplyDelivery.afterAccepted(ReplyDelivery.Delivered("x"), false, sentAt))
        val repAt = at(60_000.0)
        assertEquals(ReplyDelivery.Sent(false, repAt), ReplyDelivery.synced(ReplyDelivery.Failed("Couldn't reach your relay"), "pending", null, repAt, NOW, forwardedAt = repAt))
        assertEquals(ReplyDelivery.Sent(false, repAt), ReplyDelivery.synced(ReplyDelivery.AlreadyReplied, "pending", null, repAt, NOW, forwardedAt = repAt))
        assertEquals(ReplyDelivery.Sent(true, sentAt), ReplyDelivery.synced(ReplyDelivery.Sent(true, sentAt), "pending", null, repAt, NOW))
        assertEquals(ReplyDelivery.Sent(false, NOW), ReplyDelivery.synced(null, "pending", null, null, NOW, forwardedAt = NOW))
        assertEquals("failed never clobbers an in-progress send", ReplyDelivery.Sending, ReplyDelivery.synced(ReplyDelivery.Sending, "failed", "no", null, NOW))
        assertEquals("not even a retracted record (iOS order)", ReplyDelivery.Sending, ReplyDelivery.synced(ReplyDelivery.Sending, "failed", "Deleted — not sent", null, NOW, deliveryMethod = "retracted"))
        assertEquals(ReplyDelivery.Failed("Your Mac couldn't deliver the reply."), ReplyDelivery.synced(ReplyDelivery.Sent(false, sentAt), "failed", null, null, NOW))
        assertEquals(ReplyDelivery.Delivered("Typed"), ReplyDelivery.synced(ReplyDelivery.Sent(false, sentAt), "delivered", "Typed", repAt, NOW))
        assertNull(ReplyDelivery.synced(null, null, null, null, NOW))
        assertEquals(ReplyDelivery.Sent(false, repAt), ReplyDelivery.synced(null, null, null, repAt, NOW))
    }

    @Test
    fun closedReplyScreen() {
        assertEquals(ClosedReplyPhase.Checking, ClosedReplyPhase.decide(null, true, false))
        assertEquals(ClosedReplyPhase.Resolved("Resolved on your Mac."), ClosedReplyPhase.decide(null, true, true))
        assertEquals(ClosedReplyPhase.Delivered, ClosedReplyPhase.decide("replied", true, false))
        assertEquals(ClosedReplyPhase.Resolved("Resolved on your Mac."), ClosedReplyPhase.decide(null, false, false))
        assertEquals(ClosedReplyPhase.Resolved("Answered in the terminal."), ClosedReplyPhase.decide("user_resolved_in_terminal", true, false))
        assertEquals(ClosedReplyPhase.Resolved(CloseReason.description("hook_lost") + "."), ClosedReplyPhase.decide("hook_lost", true, false))
        assertEquals(ClosedReplyPhase.Resolved(CloseReason.description("agent_exited") + "."), ClosedReplyPhase.decide("agent_exited", false, true))
    }
}
