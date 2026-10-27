package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Night Watch rows, delivery previews and prompt options, ported from iOS/Tests/LogicTests.swift
 * ("row actions, previews, sections, ranking, copy" and "Delivery previews and prompt options").
 */
class NowRowBuilderTest {
    private val mac = "Studio MBP"

    @Test fun `a Claude terminal approval types 1, Esc denies, a written reply is Esc then text then Return`() {
        val term = nwSession("s1", title = "bottle-flip", host = "Terminal", canType = true)
        val ap = nwIv("a1", InterventionKind.APPROVAL, "[Bash] npm test", session = "s1")
        val row = NowRowBuilder.row(ap, term, mac)
        assertEquals("Will type 1 · Terminal › bottle-flip · Studio MBP", row.action(RowAction.Kind.APPROVE)?.preview)
        assertEquals("Will press Esc · Terminal › bottle-flip · Studio MBP", row.action(RowAction.Kind.DENY)?.preview)
        assertEquals("Esc, then your message · Terminal › bottle-flip · Studio MBP", row.action(RowAction.Kind.TELL_INSTEAD)?.preview)
        val cmux = nwSession("s2", title = "page", host = "cmux", canType = true)
        assertEquals("Will type 1 · cmux › page · Studio MBP", NowRowBuilder.row(ap, cmux, mac).action(RowAction.Kind.APPROVE)?.preview)
        assertEquals(NowRow.Section.DECIDE, row.section)
        assertEquals(ChipKind.UNDOABLE, row.chip)
        assertEquals(CommitGesture.SWIPE, row.commit)
    }

    @Test fun `a pane Page cannot type into offers only Open on Mac and no commit`() {
        val ap = nwIv("a1", InterventionKind.APPROVAL, "[Bash] npm test", session = "s1")
        val ghost = nwSession("s3", title = "api", host = "Ghostty", canType = false, blocker = "Page can't type into Ghostty yet")
        val blocked = NowRowBuilder.row(ap, ghost, mac)
        assertEquals(listOf(RowAction.Kind.OPEN_ON_MAC), blocked.actions.map { it.kind })
        assertEquals("Can't type here · Page can't type into Ghostty yet · Studio MBP", blocked.action(RowAction.Kind.OPEN_ON_MAC)?.preview)
        assertNull("blocked row has no commit gesture", blocked.commit)
    }

    @Test fun `an Undoable row the phone cannot type into is not swipeable and nothing can begin an approve on it`() {
        val ap = nwIv("a1", InterventionKind.APPROVAL, "[Bash] npm test", session = "s1")
        val ghost = nwSession("s3", title = "api", host = "Ghostty", canType = false, blocker = "Page can't type into Ghostty yet")
        val blocked = NowRowBuilder.row(ap, ghost, mac)
        assertEquals("the chip stays Undoable", ChipKind.UNDOABLE, blocked.chip)
        assertFalse("but there is no swipe", blocked.canSwipeApprove)
        assertNull(blocked.action(RowAction.Kind.APPROVE))
        assertFalse(app.page.android.data.ActionCoordinator.canBegin(blocked, RowAction.Kind.APPROVE))
        assertFalse(app.page.android.data.ActionCoordinator.canBegin(blocked, RowAction.Kind.DENY))

        val other = nwSession("s4", backend = "other")
        val unknown = NowRowBuilder.row(ap, other, mac)
        assertFalse("an agent Page has no adapter for is not swipeable", unknown.canSwipeApprove)
        assertFalse(app.page.android.data.ActionCoordinator.canBegin(unknown, RowAction.Kind.APPROVE))

        val ok = NowRowBuilder.row(ap, nwSession("s1"), mac)
        assertTrue(ok.canSwipeApprove)
        assertTrue(app.page.android.data.ActionCoordinator.canBegin(ok, RowAction.Kind.APPROVE))
        assertFalse("a row with no carry-on never sends one", app.page.android.data.ActionCoordinator.canBegin(ok, RowAction.Kind.CARRY_ON))
    }

    @Test fun `hook-owned pages never type 1 and a decisions-only hook has no written reply`() {
        val term = nwSession("s1")
        val hook = nwIv("hookpre-1", InterventionKind.APPROVAL, "[Bash] ls", session = "s1")
        val hr = NowRowBuilder.row(hook, term, mac)
        assertEquals("Will allow it through Claude's permission hook · Studio MBP", hr.action(RowAction.Kind.APPROVE)?.preview)
        assertEquals("Will deny it through Claude's permission hook · Studio MBP", hr.action(RowAction.Kind.DENY)?.preview)
        assertTrue("hook never types 1", hr.actions.all { !(it.preview ?: "").contains("Will type") })

        val hb = nwIv("hook-9", InterventionKind.APPROVAL, "[Bash] ls", session = "s1", hookBlocking = true)
        val hbr = NowRowBuilder.row(hb, term, mac)
        assertNull("decisions-only hook has no written reply", hbr.action(RowAction.Kind.TELL_INSTEAD))
        assertTrue(hbr.action(RowAction.Kind.APPROVE) != null && hbr.action(RowAction.Kind.DENY) != null)
    }

    @Test fun `a blank Mac name is never omitted from a preview`() {
        val ap = nwIv("a1", InterventionKind.APPROVAL, "[Bash] npm test", session = "s1")
        val blank = NowRowBuilder.row(ap, nwSession("s1"), "  ")
        assertEquals("Will type 1 · Terminal › bottle-flip · your Mac", blank.action(RowAction.Kind.APPROVE)?.preview)
    }

    @Test fun `every preview names the Mac and nothing ever types 2`() {
        val term = nwSession("s1")
        val ghost = nwSession("s3", host = "Ghostty", canType = false, blocker = "Page can't type into Ghostty yet")
        val hook = nwIv("hookpre-1", InterventionKind.APPROVAL, "[Bash] ls", session = "s1")
        val hb = nwIv("hook-9", InterventionKind.APPROVAL, "[Bash] ls", session = "s1", hookBlocking = true)
        val pages = listOf(
            nwIv("a1", InterventionKind.APPROVAL, "[Bash] npm test", session = "s1"), hook, hb,
            nwIv("u", InterventionKind.USER_INPUT, "Which file?", session = "s1"),
            nwIv("l", InterventionKind.IDLE, "Looks stuck in a loop: this has failed 6 times.\ncargo test", session = "s1", subtype = "looping"),
            nwIv("r", InterventionKind.IDLE, "Changed 2 files · tests passed", session = "s1"),
            nwIv("rl", InterventionKind.RATE_LIMIT, "Limit", subtype = "usage_forecast"),
            nwIv("c", InterventionKind.APPROVAL, "[Bash] ls", session = "s1", backend = InterventionBackend.CODEX),
            nwIv("p", InterventionKind.APPROVAL, "[Bash] ls", session = "s2"),
        )
        for (p in pages) for (session in listOf<LiveSession?>(term, ghost, null)) {
            for (a in NowRowBuilder.row(p, session, mac).actions) {
                val text = a.preview ?: continue
                assertTrue("preview names the Mac: $text", text.contains(mac))
                assertFalse("never types 2: $text", text.contains("Will type 2"))
            }
        }
    }

    @Test fun `Codex answers through its own adapter and never types 1`() {
        val codex = NowRowBuilder.row(
            nwIv("c2", InterventionKind.APPROVAL, "[Bash] ls", session = "s1", backend = InterventionBackend.CODEX),
            nwSession("s1"), mac,
        )
        assertEquals("Asks Codex to accept · Studio MBP", codex.action(RowAction.Kind.APPROVE)?.preview)
        assertEquals("Asks Codex to decline · Studio MBP", codex.action(RowAction.Kind.DENY)?.preview)
        assertNull("codex offers no written reply here", codex.action(RowAction.Kind.TELL_INSTEAD))
    }

    @Test fun `sections put approvals and questions in DECIDE, stuck and forecast pages in LOOK, finished turns in REVIEW`() {
        assertEquals(NowRow.Section.DECIDE, NowRowBuilder.section(nwIv("q", InterventionKind.USER_INPUT, "x")))
        assertEquals(NowRow.Section.DECIDE, NowRowBuilder.section(nwIv("a", InterventionKind.APPROVAL, "x")))
        for (sub in listOf("looping", "stuck", "workflow_stalled", "low_battery")) {
            assertEquals("idle $sub is look", NowRow.Section.LOOK, NowRowBuilder.section(nwIv("i", InterventionKind.IDLE, "x", subtype = sub)))
        }
        assertEquals(NowRow.Section.REVIEW, NowRowBuilder.section(nwIv("i", InterventionKind.IDLE, "x")))
        assertEquals(NowRow.Section.LOOK, NowRowBuilder.section(nwIv("rl", InterventionKind.RATE_LIMIT, "x")))
    }

    @Test fun `chips for questions, forecasts, rate limits, stuck pages and finished turns`() {
        assertEquals(ChipKind.QUESTION, NowRowBuilder.row(nwIv("q", InterventionKind.USER_INPUT, "Which?"), null, mac).chip)
        assertEquals(ChipKind.FORECAST, NowRowBuilder.row(nwIv("bf", InterventionKind.RATE_LIMIT, "x", subtype = "battery_forecast"), null, mac).chip)
        assertEquals(ChipKind.FORECAST, NowRowBuilder.row(nwIv("uf", InterventionKind.RATE_LIMIT, "x", subtype = "usage_forecast"), null, mac).chip)
        assertEquals(ChipKind.RATE_LIMITED, NowRowBuilder.row(nwIv("rl", InterventionKind.RATE_LIMIT, "x"), null, mac).chip)
        val looping = NowRowBuilder.row(nwIv("l", InterventionKind.IDLE, "Looks stuck", subtype = "looping"), null, mac)
        assertEquals(ChipKind.LOOKS_STUCK, looping.chip)
        assertTrue("looping offers Stop", looping.action(RowAction.Kind.STOP) != null)
        assertNull("stalled workflow has no Stop", NowRowBuilder.row(nwIv("w", InterventionKind.IDLE, "x", subtype = "workflow_stalled"), null, mac).action(RowAction.Kind.STOP))
        assertTrue("stuck offers Stop", NowRowBuilder.row(nwIv("s", InterventionKind.IDLE, "x", subtype = "stuck"), null, mac).action(RowAction.Kind.STOP) != null)
        assertEquals(ChipKind.REVIEW, NowRowBuilder.row(nwIv("i", InterventionKind.IDLE, "Done"), null, mac).chip)
    }

    @Test fun `ranking is Decide first with Irreversible, then Considered or question, then Undoable, then longest wait`() {
        val term = nwSession("s1")
        val rIrr = NowRowBuilder.row(nwIv("A", InterventionKind.APPROVAL, "[Bash] rm -rf x\nDelete it", t = 300.0, session = "s1"), term, mac)
        val rQ = NowRowBuilder.row(nwIv("C", InterventionKind.USER_INPUT, "Which?", t = 50.0, session = "s1"), term, mac)
        val rCons = NowRowBuilder.row(nwIv("B", InterventionKind.APPROVAL, "Claude is waiting for your approval", t = 100.0, session = "s1"), term, mac)
        val rUndo = NowRowBuilder.row(nwIv("D", InterventionKind.APPROVAL, "[Bash] ls", t = 10.0, session = "s1"), term, mac)
        val rLook = NowRowBuilder.row(nwIv("E", InterventionKind.IDLE, "Looks stuck", t = 5.0, session = "s1", subtype = "looping"), term, mac)
        val rReview = NowRowBuilder.row(nwIv("F", InterventionKind.IDLE, "Done", t = 1.0, session = "s1"), term, mac)
        assertEquals(listOf("A", "C", "B", "D", "E", "F"), NowRowBuilder.ranked(listOf(rReview, rLook, rUndo, rCons, rQ, rIrr)).map { it.id })
        assertEquals(listOf("A", "D"), NowRowBuilder.ranked(listOf(rUndo, rIrr)).map { it.id })
    }

    @Test fun `headlines and one-line summaries`() {
        assertEquals("rm -rf x", NowRowBuilder.summaryLine(nwIv("s1", InterventionKind.APPROVAL, "[Bash] rm -rf x\nDelete it")))
        assertEquals("Delete it?", NowRowBuilder.headline(nwIv("h1", InterventionKind.APPROVAL, "[Bash] rm -rf x\nDelete it")))
        assertEquals("edit a.swift", NowRowBuilder.summaryLine(nwIv("s2", InterventionKind.APPROVAL, "[Edit] a.swift")))
        assertEquals(
            "cargo test failed 6×",
            NowRowBuilder.summaryLine(nwIv("s3", InterventionKind.IDLE, "Looks stuck in a loop: this has failed 6 times.\ncargo test", subtype = "looping")),
        )
        assertEquals("Claude looks stuck", NowRowBuilder.headline(nwIv("h2", InterventionKind.IDLE, "Looks stuck in a loop", subtype = "looping")))
        assertEquals(
            "no progress for 15 min",
            NowRowBuilder.summaryLine(nwIv("s4", InterventionKind.IDLE, "No progress for 15 min — the last step returned nothing", subtype = "stuck")),
        )
        assertEquals(
            "2 tool calls waiting",
            NowRowBuilder.summaryLine(nwIv("s5", InterventionKind.APPROVAL, "One of these is waiting for approval:\n• [Bash] ls\n• [Edit] a.swift")),
        )
        assertEquals("Paused for battery", NowRowBuilder.headline(nwIv("h3", InterventionKind.IDLE, "Paused", subtype = "low_battery")))
        assertEquals("Claude finished a turn", NowRowBuilder.headline(nwIv("h4", InterventionKind.IDLE, "Changed 1 file · tests passed")))
        assertEquals("Claude looks stuck", NowRowBuilder.headline(nwIv("h5", InterventionKind.IDLE, "Looks stuck", subtype = "looping")))
        assertEquals("Paused for battery", NowRowBuilder.headline(nwIv("h6", InterventionKind.IDLE, "x", subtype = "low_battery")))
        // An older Mac's page with no backend reads as Claude everywhere.
        assertEquals("Claude finished a turn", NowRowBuilder.headline(nwIv("h7", InterventionKind.IDLE, "Done", backend = null)))
        val long = NowRowBuilder.summaryLine(nwIv("long", InterventionKind.IDLE, "x".repeat(200)))
        assertEquals(96, long.length)
        assertTrue(long.endsWith("…"))
        assertEquals("ls …", NowRowBuilder.summaryLine(nwIv("cl", InterventionKind.APPROVAL, "[Bash] ls …")))
    }

    @Test fun `an agent Page has no adapter for is never typed into and says so`() {
        val gem = pageFromJson("""{"id":"g1","sessionId":"s9","kind":"approval","openedAt":"2027-01-15T08:00:00Z","context":"[Bash] ls","backend":"gemini"}""")
        assertNull(gem.backend)
        assertEquals("gemini", gem.backendRaw)
        assertTrue(gem.hasUnknownBackend)
        val gemRow = NowRowBuilder.row(gem, null, mac)
        assertEquals(listOf(RowAction.Kind.OPEN_ON_MAC), gemRow.actions.map { it.kind })
        assertEquals("Couldn't tell what's on screen · Studio MBP", gemRow.action(RowAction.Kind.OPEN_ON_MAC)?.preview)
        assertNull(gemRow.commit)
        assertEquals(Reversibility.CONSIDERED, gemRow.reversibility)
        val plain = pageFromJson("""{"id":"n1","sessionId":"s1","kind":"approval","openedAt":"2027-01-15T08:00:00Z","context":"[Bash] ls"}""")
        assertNull(plain.backend)
        assertFalse("missing backend is an older Claude page, not unknown", plain.hasUnknownBackend)
        val cdx = pageFromJson("""{"id":"c1","sessionId":"s1","kind":"approval","openedAt":"2027-01-15T08:00:00Z","context":"[Bash] ls","backend":"codex"}""")
        assertEquals(InterventionBackend.CODEX, cdx.backend)
        assertEquals("Codex", cdx.agentName)
    }

    @Test fun `a delivery preview route drops an unknown host and a blank route is nil`() {
        assertEquals("cmux › page", DeliveryPreview.route("cmux", "page"))
        assertEquals("page", DeliveryPreview.route("unknown", "page"))
        assertNull(DeliveryPreview.route("  ", ""))
        assertEquals("Will type 1 · cmux › page · Studio MBP", DeliveryPreview.typeOne("cmux › page", "Studio MBP"))
        assertEquals("your Mac", DeliveryPreview.macLabel("  "))
        assertEquals("Open in terminal to choose this", DeliveryPreview.openInTerminal)
        assertEquals("Will allow it through Claude's permission hook · M", DeliveryPreview.hookAllow("M"))
    }

    @Test fun `standing permission options are recognised and plain yes is not`() {
        assertTrue(DeliveryPreview.isStandingPermissionOption("Yes, and don't ask again for npm"))
        assertTrue(DeliveryPreview.isStandingPermissionOption("Yes, allow all edits during this session"))
        assertTrue(DeliveryPreview.isStandingPermissionOption("Always allow"))
        assertFalse(DeliveryPreview.isStandingPermissionOption("Yes"))
        assertFalse(DeliveryPreview.isStandingPermissionOption("No, and tell Claude what to do differently"))
    }

    @Test fun `prompt options are read from the page text, standing ones shown not offered`() {
        val opts = PromptOption.parse("1. Yes\n2. Yes, and don't ask again for npm\n3. No")
        assertEquals(3, opts.size)
        assertTrue(opts[1].isStanding)
        assertEquals(DeliveryPreview.openInTerminal, opts[1].instead)
        assertFalse(opts[0].isStanding)
        assertFalse(opts[2].isStanding)
        assertNull(opts[0].instead)
        assertTrue("non-consecutive numbering is not a prompt", PromptOption.parse("1. Yes\n3. No").isEmpty())
        assertEquals(listOf(1, 2), PromptOption.parse("❯ 1. Yes\n  2. No").map { it.number })
        assertEquals(2, PromptOption.parse("1) Yes\n2) No").size)
    }

    @Test fun `the focused row previews its approve line, else the first action that sends something`() {
        val term = nwSession("s1")
        val row = NowRowBuilder.row(nwIv("a1", InterventionKind.APPROVAL, "[Bash] npm test", session = "s1"), term, mac)
        assertEquals("Will type 1 · Terminal › bottle-flip · Studio MBP", row.focusPreview)
        val look = NowRowBuilder.row(nwIv("rl", InterventionKind.RATE_LIMIT, "x", subtype = "battery_forecast"), null, mac)
        assertNull(look.focusPreview)
    }
}
