package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Notification actions, ported from the NotificationDecision checks in iOS/Tests/LogicTests.swift. Approve from a
 * notification is sent only for an UNDOABLE page; Considered and Irreversible, and pages the phone cannot read,
 * open the app on the Decision sheet instead. Deny is always safe from a banner.
 */
class NotificationDecisionTest {
    @Test fun `tapping opens and dismissing ignores`() {
        assertEquals(NotificationDecision.Open, NotificationDecision.decide(NotificationResponseKind.Open, null, "permission", approveLevel = null))
        assertEquals(NotificationDecision.Ignore, NotificationDecision.decide(NotificationResponseKind.Dismiss, null, "permission", approveLevel = null))
    }

    @Test fun `approve is sent only when the page is undoable`() {
        val approve = NotificationResponseKind.Action("APPROVE")
        assertEquals(
            NotificationDecision.Send("", ReplyAction.APPROVE),
            NotificationDecision.decide(approve, null, "permission", approveLevel = Reversibility.UNDOABLE),
        )
        assertEquals(
            "approve of an undoable page from a legacy payload with no kind",
            NotificationDecision.Send("", ReplyAction.APPROVE),
            NotificationDecision.decide(approve, null, null, approveLevel = Reversibility.UNDOABLE),
        )
        assertEquals(NotificationDecision.Open, NotificationDecision.decide(approve, null, "permission", approveLevel = Reversibility.CONSIDERED))
        assertEquals(NotificationDecision.Open, NotificationDecision.decide(approve, null, "permission", approveLevel = Reversibility.IRREVERSIBLE))
        assertEquals(
            "approve of a page not in the inbox opens the app",
            NotificationDecision.Open,
            NotificationDecision.decide(approve, null, "permission", approveLevel = null),
        )
    }

    @Test fun `deny is always allowed from a banner, even for an irreversible page`() {
        assertEquals(
            NotificationDecision.Send("", ReplyAction.DENY),
            NotificationDecision.decide(NotificationResponseKind.Action("DENY"), null, "permission", approveLevel = Reversibility.IRREVERSIBLE),
        )
    }

    @Test fun `approve on an idle page and carry on for an approval are refused`() {
        assertTrue(NotificationDecision.decide(NotificationResponseKind.Action("APPROVE"), null, "idle", approveLevel = Reversibility.UNDOABLE) is NotificationDecision.Refuse)
        assertTrue(NotificationDecision.decide(NotificationResponseKind.Action("CARRY_ON"), null, "plan", approveLevel = null) is NotificationDecision.Refuse)
    }

    @Test fun `a stale approve on an idle page never types yes into a session that never asked`() {
        val refused = NotificationDecision.decide(NotificationResponseKind.Action("APPROVE"), null, "idle", approveLevel = Reversibility.UNDOABLE)
        assertTrue(refused !is NotificationDecision.Send)
    }
}
