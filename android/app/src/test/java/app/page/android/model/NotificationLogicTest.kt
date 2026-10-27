package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationLogicTest {
    private fun decide(r: NotificationResponseKind, text: String? = null, kind: String?) = NotificationDecision.decide(r, text, kind, approveLevel = Reversibility.UNDOABLE)
    private fun action(id: String) = NotificationResponseKind.Action(id)

    @Test
    fun decisions() {
        assertEquals(NotificationDecision.Open, decide(NotificationResponseKind.Open, kind = "permission"))
        assertEquals(NotificationDecision.Ignore, decide(NotificationResponseKind.Dismiss, kind = "permission"))
        assertEquals(NotificationDecision.Send("", ReplyAction.APPROVE), decide(action("APPROVE"), kind = "permission"))
        assertEquals("legacy payload without kind", NotificationDecision.Send("", ReplyAction.APPROVE), decide(action("APPROVE"), kind = null))
        assertTrue("approve on idle refused", decide(action("APPROVE"), kind = "idle") is NotificationDecision.Refuse)
        assertTrue("deny on a question refused", decide(action("DENY"), kind = "user_input") is NotificationDecision.Refuse)
        assertTrue("carry on for an approval refused", decide(action("CARRY_ON"), kind = "plan") is NotificationDecision.Refuse)
        assertEquals(NotificationDecision.Send("", ReplyAction.CARRY_ON), decide(action("CARRY_ON"), kind = "idle"))
        assertEquals(NotificationDecision.Ignore, decide(action("REPLY"), "   ", "question"))
        assertEquals(NotificationDecision.Send("use v2", ReplyAction.CUSTOM), decide(action("REPLY"), " use v2 ", "question"))
        assertEquals(NotificationDecision.Ignore, decide(action("SOMETHING"), kind = "question"))
    }

    @Test
    fun canonicalKindsRoundTrip() {
        // Notifications carry the decoded kind's wire name; it must map back.
        for (k in InterventionKind.entries) assertEquals(k, InterventionKind.fromWire(k.wire))
    }

    @Test
    fun closedIdsFromPushes() {
        assertEquals(setOf("a", "b", "c"), PushPayload.closedIds(mapOf("interventionClosedId" to "a", "interventionClosedIds" to listOf("a", "b", "c"))))
        assertEquals(setOf("a"), PushPayload.closedIds(mapOf("interventionClosedId" to "a")))
        assertEquals(setOf("b"), PushPayload.closedIds(mapOf("interventionClosedIds" to listOf("", "b", 5))))
        assertEquals(setOf("old"), PushPayload.closedIds(mapOf("interventionId" to "new", "interventionClosedIds" to listOf("old", "new"))))
        assertTrue(PushPayload.closedIds(mapOf("aps" to mapOf("content-available" to 1))).isEmpty())
    }

    @Test
    fun projectNameForNotices() {
        assertEquals("acme-web", PushPayload.projectName(mapOf("projectName" to "acme-web"), "Reply to acme-web not delivered"))
        assertEquals("acme-web", PushPayload.projectName(emptyMap(), "acme-web paged you"))
        assertEquals("acme-web", PushPayload.projectName(emptyMap(), "Reply to acme-web not delivered"))
        assertEquals("", PushPayload.projectName(emptyMap(), "Something else"))
        assertEquals("x", PushPayload.projectName(mapOf("projectName" to "  "), "x paged you"))
        assertEquals("api", PushPayload.projectName(mapOf("projectName" to "api"), "web paged you"))
    }
}
