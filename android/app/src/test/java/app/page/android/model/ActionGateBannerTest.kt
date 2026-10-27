package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A banner action goes through the same backstop as the coordinator, ported from the "banner" checks in
 * iOS/Tests/LogicTests.swift (ActionGate.banner): a send the page's row doesn't offer opens the app instead.
 */
class ActionGateBannerTest {
    private val mac = "Studio MBP"
    private val ap = nwIv("a1", InterventionKind.APPROVAL, "[Bash] npm test", session = "s1")

    private val approve = NotificationDecision.decide(NotificationResponseKind.Action("APPROVE"), null, "permission", approveLevel = Reversibility.UNDOABLE)
    private val deny = NotificationDecision.decide(NotificationResponseKind.Action("DENY"), null, "permission", approveLevel = Reversibility.UNDOABLE)
    private val reply = NotificationDecision.decide(NotificationResponseKind.Action("REPLY"), "use v2", "permission", approveLevel = Reversibility.UNDOABLE)

    @Test fun `the fixtures really are sends`() {
        assertEquals(NotificationDecision.Send("", ReplyAction.APPROVE), approve)
        assertEquals(NotificationDecision.Send("", ReplyAction.DENY), deny)
        assertEquals(NotificationDecision.Send("use v2", ReplyAction.CUSTOM), reply)
    }

    @Test fun `a banner on a row Page cannot type into opens the app, never sends`() {
        val ghost = nwSession("s3", host = "Ghostty", canType = false, blocker = "Page can't type into Ghostty yet")
        val blocked = NowRowBuilder.row(ap, ghost, mac)
        assertEquals(NotificationDecision.Open, ActionGate.banner(approve, blocked))
        assertEquals(NotificationDecision.Open, ActionGate.banner(deny, blocked))
        assertEquals(NotificationDecision.Open, ActionGate.banner(reply, blocked))
    }

    @Test fun `a banner Approve for an unknown agent opens the app`() {
        val unknown = NowRowBuilder.row(ap, nwSession("s4", backend = "other"), mac)
        assertEquals(NotificationDecision.Open, ActionGate.banner(approve, unknown))
        // iOS's exact case: the relay names a backend Page has no adapter for, on an otherwise Undoable command,
        // with no live session to consult.
        val gem = pageFromJson("""{"id":"g2","sessionId":"s11","kind":"approval","openedAt":"2027-01-15T08:00:00Z","context":"[Bash] swift test","backend":"gemini"}""")
        assertEquals(NotificationDecision.Open, ActionGate.banner(approve, NowRowBuilder.row(gem, null, mac)))
    }

    @Test fun `a banner on a typeable row sends as before`() {
        val row = NowRowBuilder.row(ap, nwSession("s1"), mac)
        assertEquals(approve, ActionGate.banner(approve, row))
        assertEquals(deny, ActionGate.banner(deny, row))
        assertEquals(reply, ActionGate.banner(reply, row))
    }

    @Test fun `a page not in the inbox keeps the banner decision`() {
        assertEquals(deny, ActionGate.banner(deny, null))
        assertEquals(approve, ActionGate.banner(approve, null))
    }

    @Test fun `a decision that is not a send is never changed`() {
        val ghost = nwSession("s3", host = "Ghostty", canType = false, blocker = "Page can't type into Ghostty yet")
        val blocked = NowRowBuilder.row(ap, ghost, mac)
        assertEquals(NotificationDecision.Ignore, ActionGate.banner(NotificationDecision.Ignore, blocked))
        assertEquals(NotificationDecision.Open, ActionGate.banner(NotificationDecision.Open, blocked))
        val refuse = NotificationDecision.Refuse("no")
        assertEquals(refuse, ActionGate.banner(refuse, blocked))
    }

    @Test fun `a hook that takes decisions only opens a written reply but sends approve and deny`() {
        val hb = nwIv("hook-9", InterventionKind.APPROVAL, "[Bash] ls", session = "s1", hookBlocking = true)
        val row = NowRowBuilder.row(hb, nwSession("s1"), mac)
        assertEquals(approve, ActionGate.banner(approve, row))
        assertEquals(deny, ActionGate.banner(deny, row))
        assertEquals(NotificationDecision.Open, ActionGate.banner(reply, row))
    }

    @Test fun `stop counts as a deny and carry on needs a carry on`() {
        val stuck = nwIv("l", InterventionKind.IDLE, "Looks stuck in a loop: this has failed 6 times.\ncargo test", session = "s1", subtype = "looping")
        val row = NowRowBuilder.row(stuck, nwSession("s1"), mac)
        val stop = NotificationDecision.decide(NotificationResponseKind.Action("STOP"), null, "idle", "looping")
        assertEquals(NotificationDecision.Send("", ReplyAction.DENY), stop)
        assertEquals(stop, ActionGate.banner(stop, row))
        val ghost = nwSession("s3", host = "Ghostty", canType = false, blocker = "Page can't type into Ghostty yet")
        assertEquals(NotificationDecision.Open, ActionGate.banner(stop, NowRowBuilder.row(stuck, ghost, mac)))

        val done = nwIv("d", InterventionKind.IDLE, "Finished the refactor.", session = "s1")
        val carryOn = NotificationDecision.decide(NotificationResponseKind.Action("CARRY_ON"), null, "idle")
        assertEquals(NotificationDecision.Send("", ReplyAction.CARRY_ON), carryOn)
        assertEquals(carryOn, ActionGate.banner(carryOn, NowRowBuilder.row(done, nwSession("s1"), mac)))
        assertEquals(NotificationDecision.Open, ActionGate.banner(carryOn, NowRowBuilder.row(done, ghost, mac)))
        // The stuck row offers Stop and Steer but no Carry on, so a stray Carry on can't send there.
        assertEquals(NotificationDecision.Open, ActionGate.banner(NotificationDecision.Send("", ReplyAction.CARRY_ON), row))
    }
}
