package app.page.android.notify

import app.page.android.model.Intervention
import app.page.android.model.InterventionBackend
import app.page.android.model.InterventionKind
import app.page.android.model.NotificationDecision
import app.page.android.model.NotificationActionId
import app.page.android.model.NotificationResponseKind
import app.page.android.model.PhoneReversibility
import app.page.android.model.Reversibility
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The notification's one-tap Approve is judged from the page's FULL text when it is posted, never from the shortened record. */
class PageInfoTest {
    private fun page(context: String, kind: InterventionKind = InterventionKind.APPROVAL, sub: String? = null) = Intervention(
        id = "p", sessionId = "s", cwd = "/Users/you/projects/page", projectName = "page", kind = kind, openedAt = Instant.EPOCH, context = context,
        backend = InterventionBackend.CLAUDE, subtype = sub,
    )

    @Test fun `an undoable command is classified at post time`() {
        val info = PageInfo.of(page("[Bash] swift test --filter StuckTests"))
        assertEquals(Reversibility.UNDOABLE.name, info.level)
        assertEquals("page", info.projectName)
        assertTrue(info.summary.contains("swift test"))
    }

    @Test fun `an irreversible command is not undoable and never gets one-tap approve`() {
        val info = PageInfo.of(page("[Bash] rm -rf Builds/Dev/*.app\nDelete every Dev build"))
        assertEquals(Reversibility.IRREVERSIBLE.name, info.level)
        // At action time the live classification decides: not undoable means the decision sheet opens.
        val decision = NotificationDecision.decide(NotificationResponseKind.Action(NotificationActionId.APPROVE), null, "approval", null, Reversibility.IRREVERSIBLE)
        assertEquals(NotificationDecision.Open, decision)
    }

    @Test fun `a long context keeps its classification even though the record is clipped`() {
        val long = "[Bash] ls\n" + "x".repeat(900) + "\nrm -rf /tmp/stuff"
        val info = PageInfo.of(page(long))
        // The full text was classified when it was posted; the stored context is only 500 characters.
        assertEquals(PhoneReversibility.verdict(page(long))?.level?.name, info.level)
        assertTrue(info.toJson().toString().length < 1200)
    }

    @Test fun `a page with nothing to approve has no level`() {
        assertNull(PageInfo.of(page("Changed 3 files (+120 −14) · tests passed", InterventionKind.IDLE)).level)
    }

    @Test fun `the record round trips`() {
        val info = PageInfo.of(page("[Bash] swift build"))
        assertEquals(info, PageInfo.fromJson(info.toJson()))
    }
}
