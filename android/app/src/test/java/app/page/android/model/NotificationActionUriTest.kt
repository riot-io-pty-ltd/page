package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The action URI is the only trusted source of a notification action's page and action. */
class NotificationActionUriTest {
    @Test
    fun roundTripsEveryIdShape() {
        for (id in listOf("dev-1", "7f3a9c2b-1111-aaaa-bbbb-cccccccccccc-permission-1761300000", "hook-ab/cd?x=1&y", "ünï cødé 😀", "a%2Fb")) {
            for (action in NotificationActionUri.knownActions) {
                val uri = NotificationActionUri.build(id, action)
                assertEquals(NotificationActionUri.Parsed(id, action), NotificationActionUri.parse(uri))
            }
        }
    }

    @Test
    fun encodedIdCannotInjectAPathOrAction() {
        val uri = NotificationActionUri.build("x/APPROVE", "DENY")
        assertEquals("page-action://x%2FAPPROVE/DENY", uri)
        assertEquals(NotificationActionUri.Parsed("x/APPROVE", "DENY"), NotificationActionUri.parse(uri))
    }

    @Test
    fun rejectsAnythingMalformed() {
        assertNull(NotificationActionUri.parse(null))
        assertNull(NotificationActionUri.parse(""))
        assertNull("wrong scheme", NotificationActionUri.parse("page://dev-1/APPROVE"))
        assertNull("no action", NotificationActionUri.parse("page-action://dev-1"))
        assertNull("empty id", NotificationActionUri.parse("page-action:///APPROVE"))
        assertNull("unknown action", NotificationActionUri.parse("page-action://dev-1/LAUNCH"))
        assertNull("lower-case action", NotificationActionUri.parse("page-action://dev-1/approve"))
        assertNull("extra segment", NotificationActionUri.parse("page-action://dev-1/x/APPROVE"))
        assertNull("raw reserved char in id", NotificationActionUri.parse("page-action://de?v/APPROVE"))
        assertNull("bad escape", NotificationActionUri.parse("page-action://de%zzv/APPROVE"))
        assertNull("truncated escape", NotificationActionUri.parse("page-action://dev%2/APPROVE"))
        assertNull("invalid UTF-8", NotificationActionUri.parse("page-action://%FF%FE/APPROVE"))
        assertNull("too long", NotificationActionUri.parse(NotificationActionUri.build("x".repeat(201), "APPROVE")))
        assertNull("query", NotificationActionUri.parse("page-action://dev-1/APPROVE?x=1"))
    }

    @Test
    fun stuckAndForecastDecisions() {
        val stop = NotificationResponseKind.Action(NotificationActionId.STOP)
        val carry = NotificationResponseKind.Action(NotificationActionId.CARRY_ON)
        val reply = NotificationResponseKind.Action(NotificationActionId.REPLY)
        assertEquals(NotificationDecision.Send("", ReplyAction.DENY), NotificationDecision.decide(stop, null, "idle", "looping"))
        assertEquals(NotificationDecision.Send("", ReplyAction.DENY), NotificationDecision.decide(stop, null, "idle", "stuck"))
        org.junit.Assert.assertTrue(NotificationDecision.decide(stop, null, "idle", "workflow_stalled") is NotificationDecision.Refuse)
        org.junit.Assert.assertTrue(NotificationDecision.decide(stop, null, "idle", null) is NotificationDecision.Refuse)
        org.junit.Assert.assertTrue(NotificationDecision.decide(stop, null, "approval", null) is NotificationDecision.Refuse)
        org.junit.Assert.assertTrue(NotificationDecision.decide(carry, null, "idle", "stuck") is NotificationDecision.Refuse)
        assertEquals(NotificationDecision.Send("", ReplyAction.CARRY_ON), NotificationDecision.decide(carry, null, "idle", "low_battery"))
        assertEquals(NotificationDecision.Send("try X", ReplyAction.CUSTOM), NotificationDecision.decide(reply, "try X", "idle", "workflow_stalled"))
        assertEquals(NotificationDecision.Send("later", ReplyAction.CUSTOM), NotificationDecision.decide(reply, "later", "rate_limit", null))
        org.junit.Assert.assertTrue(NotificationDecision.decide(reply, "hi", "rate_limit", "battery_forecast") is NotificationDecision.Refuse)
        // Deny on a stuck page is never reachable through the approval buttons.
        org.junit.Assert.assertTrue(NotificationDecision.decide(NotificationResponseKind.Action(NotificationActionId.DENY), null, "idle", "stuck") is NotificationDecision.Refuse)
        assertEquals(NotificationCategory.STUCK, NotificationCategory.forPage(InterventionKind.IDLE, "looping"))
        assertEquals(NotificationCategory.STALLED, NotificationCategory.forPage(InterventionKind.IDLE, "workflow_stalled"))
        assertEquals(NotificationCategory.IDLE, NotificationCategory.forPage(InterventionKind.IDLE, "low_battery"))
        assertEquals(NotificationCategory.INFO, NotificationCategory.forPage(InterventionKind.RATE_LIMIT, "usage_forecast"))
        assertEquals(NotificationCategory.LIMIT, NotificationCategory.forPage(InterventionKind.RATE_LIMIT, null))
    }
}
