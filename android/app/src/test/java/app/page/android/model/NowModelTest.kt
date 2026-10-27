package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The Now header, the receipts, the runway, the day rings and their copy, ported from the "Night Watch (iOS): the
 * Now model, Runway, day rings, receipts" checks in iOS/Tests/LogicTests.swift.
 */
class NowModelTest {
    private fun near(a: Double, b: Double, eps: Double = 1e-6) = abs(a - b) < eps

    private val working5 = (1..5).map { nwSession("w$it", title = "w$it", state = "active", activeAt = NW_T0 - 5) }
    private val reachable = nwStatus(connected = true, age = 5.0)

    // MARK: the header

    @Test fun `two decisions and five working read as two need you with the working count`() {
        val m = NowModel.build(
            nwNowInputs(
                listOf(nwIv("a", InterventionKind.APPROVAL, "[Bash] ls", session = "w1"), nwIv("b", InterventionKind.USER_INPUT, "Which?", session = "w2")),
                sessions = working5, hasList = true, status = reachable,
            ),
        )
        assertEquals("2 need you", m.headline)
        assertTrue(m.subline.startsWith("5 working · runway clear"))
        assertEquals(NowModel.Mood.NEEDS_YOU, m.mood)
        assertEquals(2, m.needYouCount)
    }

    @Test fun `one decision reads singular, and a stuck page reads as a look with the working sessions`() {
        assertEquals("1 needs you", NowModel.build(nwNowInputs(listOf(nwIv("a", InterventionKind.APPROVAL, "[Bash] ls", session = "w1")), status = reachable)).headline)
        val look = NowModel.build(
            nwNowInputs(
                listOf(nwIv("s", InterventionKind.IDLE, "Looks stuck", session = "w1", subtype = "looping")),
                sessions = working5.take(2), hasList = true, status = reachable,
            ),
        )
        assertEquals("1 needs a look", look.headline)
        assertTrue(look.subline.startsWith("2 working · "))
        assertEquals(NowModel.Mood.NEEDS_YOU, look.mood)
    }

    @Test fun `a reachable Mac with nothing open is All quiet, and with working sessions it is working`() {
        val quiet = NowModel.build(nwNowInputs(status = reachable))
        assertEquals("All quiet", quiet.headline)
        assertEquals(NowModel.Mood.QUIET, quiet.mood)
        val busyQuiet = NowModel.build(nwNowInputs(sessions = working5.take(3), hasList = true, status = reachable))
        assertEquals("All quiet", busyQuiet.headline)
        assertEquals(NowModel.Mood.WORKING, busyQuiet.mood)
    }

    @Test fun `the working count falls back to the status count before the list arrives`() {
        val m = NowModel.build(nwNowInputs(status = nwStatus(connected = true, age = 5.0, working = 3)))
        assertEquals(3, m.workingCount)
        assertEquals("3 working · nothing needs you", m.subline)
    }

    @Test fun `no status or an offline Mac is never All quiet`() {
        val none = NowModel.build(nwNowInputs(status = null))
        assertEquals("Nothing waiting", none.headline)
        assertEquals("Studio MBP isn't connected", none.subline)
        assertEquals(NowModel.Mood.QUIET, none.mood)
        assertEquals("Nothing waiting", NowModel.build(nwNowInputs(status = nwStatus(connected = false, age = 5.0))).headline)
    }

    @Test fun `a loading inbox reads Checking, a failed one says it may be stale`() {
        assertEquals("Checking…", NowModel.build(nwNowInputs(inbox = NowInputs.InboxState.LOADING)).headline)
        val failed = NowModel.build(nwNowInputs(status = reachable, inbox = NowInputs.InboxState.FAILED))
        assertEquals("Nothing waiting", failed.headline)
        assertEquals("the list may be out of date", failed.subline)
    }

    @Test fun `a battery pause is dusk, and says how to resume`() {
        val paused = NowModel.build(
            nwNowInputs(
                listOf(nwIv("lb", InterventionKind.IDLE, "Paused", subtype = "low_battery")),
                status = nwStatus(connected = true, age = 5.0, battery = 12, onAC = false),
            ),
        )
        assertEquals(NowModel.Mood.DUSK, paused.mood)
        assertEquals("Paused for battery", paused.headline)
        assertTrue(paused.paused)
        assertEquals("plug the Mac in to resume", paused.subline)
    }

    // MARK: receipts

    private val replied: Intervention = nwIv("rp", InterventionKind.APPROVAL, "[Bash] npm test\nRun the tests", session = "w1").copy(
        repliedAction = "approve", repliedAt = nwNow.minusSeconds(60),
    )

    @Test fun `a delivered reply shows its verified receipt, and a confirmed delivery is not a failure`() {
        val m = NowModel.build(nwNowInputs(status = reachable, history = listOf(replied), deliveries = mapOf("rp" to ReplyDelivery.Delivered(null))))
        assertEquals("Approved npm test → page · verified 07:59:00", m.receiptLine)
        assertFalse(m.receiptFailed)
    }

    @Test fun `delivered and failed receipts older than fifteen minutes are not shown`() {
        val later = nwNow.plusSeconds(20.0 * 60)
        assertNull(NowModel.build(nwNowInputs(status = reachable, history = listOf(replied), deliveries = mapOf("rp" to ReplyDelivery.Delivered(null)), now = later)).receiptLine)
        assertNull(NowModel.build(nwNowInputs(status = reachable, history = listOf(replied), deliveries = mapOf("rp" to ReplyDelivery.Failed("x")), now = later)).receiptLine)
    }

    @Test fun `a failure with no reply time ages by when the phone saw it fail`() {
        val unreplied = replied.copy(repliedAction = null, repliedAt = null)
        val oldFail = NowModel.build(
            nwNowInputs(
                status = reachable, history = listOf(unreplied), deliveries = mapOf("rp" to ReplyDelivery.Failed("x")),
                deliveryTimes = mapOf("rp" to nwNow.minusSeconds(20L * 60)),
            ),
        )
        assertNull("a failure the phone saw 20 minutes ago is dropped", oldFail.receiptLine)
        val freshFail = NowModel.build(
            nwNowInputs(
                status = reachable, history = listOf(unreplied), deliveries = mapOf("rp" to ReplyDelivery.Failed("x")),
                deliveryTimes = mapOf("rp" to nwNow.minusSeconds(30)),
            ),
        )
        assertTrue("a failure seen 30 seconds ago still shows", freshFail.receiptLine != null && freshFail.receiptFailed)
    }

    @Test fun `a failed receipt is flagged and names what went wrong`() {
        val m = NowModel.build(nwNowInputs(status = reachable, history = listOf(replied), deliveries = mapOf("rp" to ReplyDelivery.Failed("Mac said no"))))
        assertTrue(m.receiptFailed)
        assertEquals("npm test · Mac said no", m.receiptLine)
    }

    private val base = nwIv("rc", InterventionKind.APPROVAL, "[Bash] npm test\nRun", session = "w1").copy(
        repliedAction = "approve", repliedAt = nwNow,
    )

    private fun rec(d: ReplyDelivery): DeliveryReceipt? = ReceiptBuilder.receipt(base, d, "cmux › page", nwNow)

    @Test fun `a receipt is only ever a confirmed delivery as success, with the iOS lines`() {
        assertNull("sending has no receipt", rec(ReplyDelivery.Sending))
        assertNull("sent is not delivered", rec(ReplyDelivery.Sent(queued = false, at = nwNow)))
        assertEquals(DeliveryReceipt.Outcome.MacOffline, rec(ReplyDelivery.Sent(queued = true, at = nwNow))?.outcome)
        assertEquals("Approved npm test → cmux › page · verified 08:00:00", rec(ReplyDelivery.Delivered(null))?.line(NW_ZONE))
        assertEquals("npm test · x", rec(ReplyDelivery.Failed("x"))?.line(NW_ZONE))
        assertEquals("npm test · Already answered at the Mac", rec(ReplyDelivery.AlreadyReplied)?.line(NW_ZONE))
        assertEquals("npm test · Prompt closed before your answer", rec(ReplyDelivery.Gone)?.line(NW_ZONE))
    }

    @Test fun `deny reads Denied, deny on a stuck page reads Stopped`() {
        val denied = base.copy(repliedAction = "deny")
        assertEquals(DeliveryReceipt.Verb.DENIED, ReceiptBuilder.receipt(denied, ReplyDelivery.Delivered(null), "r", nwNow)?.verb)
        val stopped = nwIv("st", InterventionKind.IDLE, "x", session = "w1", subtype = "looping").copy(repliedAction = "deny", repliedAt = nwNow)
        assertEquals(DeliveryReceipt.Verb.STOPPED, ReceiptBuilder.receipt(stopped, ReplyDelivery.Delivered(null), "r", nwNow)?.verb)
    }

    @Test fun `the failure copy for each outcome`() {
        assertEquals("Didn't confirm in time · Check on Mac", DeliveryReceipt.Outcome.TimedOut.failureMessage)
        assertEquals("Session ended", DeliveryReceipt.Outcome.SessionEnded.failureMessage)
        assertEquals("Couldn't deliver the reply", DeliveryReceipt.Outcome.Other("").failureMessage)
        assertNull(DeliveryReceipt.Outcome.Delivered.failureMessage)
    }

    // MARK: runway

    @Test fun `no status is an empty runway and on AC there is no cutoff`() {
        assertEquals(RunwayModel.empty, RunwayModel.build(null, nwNow, NW_ZONE))
        val ac = RunwayModel.build(nwStatus(connected = true, age = 5.0, onAC = true), nwNow, NW_ZONE)
        assertTrue(ac.onAC)
        assertTrue(ac.markers.isEmpty())
        assertNull(ac.clearUntil)
    }

    @Test fun `on battery the cutoff is the clear-until deadline at 148 of 360 minutes, amber`() {
        val batt = BatteryForecast(cutoff = 10, minutes = 148, drainPerHour = 20.0)
        val run = RunwayModel.build(nwStatus(connected = true, age = 5.0, battery = 41, onAC = false, forecast = batt), nwNow, NW_ZONE)
        assertFalse(run.onAC)
        assertEquals(nwNow.plusSeconds(148.0 * 60), run.clearUntil)
        val cut = run.markers.first { it.kind == RunwayMarker.Kind.BATTERY_CUTOFF }
        assertEquals("cutoff 10:28", cut.label)
        assertTrue(near(cut.fraction, 148.0 / 360))
        assertEquals(RunwayMarker.Tone.AMBER, cut.tone)
    }

    @Test fun `usage markers read the 5h limit, the resets, and the weekly reset, limit amber and resets green`() {
        val usage = ClaudeUsage(
            fiveHour = UsageWindow(62.0, nwNow.plusSeconds(3.0 * 3600)),
            sevenDay = UsageWindow(40.0, nwNow.plusSeconds(5.0 * 3600)),
            hitAt = nwNow.plusSeconds(2.0 * 3600),
            updatedAt = nwNow.minusSeconds(60),
        )
        val run = RunwayModel.build(nwStatus(connected = true, age = 5.0, usage = usage), nwNow, NW_ZONE)
        val labels = run.markers.map { it.label }.toSet()
        assertTrue(labels.toString(), labels.containsAll(listOf("5h 10:00", "reset 11:00", "7d reset 13:00")))
        assertEquals(RunwayMarker.Tone.AMBER, run.markers.first { it.kind == RunwayMarker.Kind.USAGE_LIMIT }.tone)
        assertEquals(RunwayMarker.Tone.GREEN, run.markers.first { it.kind == RunwayMarker.Kind.USAGE_RESET }.tone)
    }

    @Test fun `usage older than six hours is ignored`() {
        val stale = ClaudeUsage(fiveHour = UsageWindow(62.0, nwNow.plusSeconds(3.0 * 3600)), sevenDay = null, hitAt = null, updatedAt = nwNow.minusSeconds(7L * 3600))
        assertTrue(RunwayModel.build(nwStatus(connected = true, age = 5.0, usage = stale), nwNow, NW_ZONE).markers.isEmpty())
    }

    @Test fun `past or beyond six hours has no fraction, three hours is halfway`() {
        assertNull(RunwayModel.fraction(nwNow.minusSeconds(1), nwNow))
        assertNull(RunwayModel.fraction(nwNow.plusSeconds(7L * 3600), nwNow))
        assertTrue(near(RunwayModel.fraction(nwNow.plusSeconds(3L * 3600), nwNow) ?: -1.0, 0.5))
    }

    @Test fun `labels that crowd each other move to later lanes and markers stay sorted`() {
        val lanes = RunwayModel.assignLanes(
            listOf(0.10, 0.20, 0.30, 0.40, 0.50).mapIndexed { i, f ->
                RunwayMarker(id = "m$i", kind = RunwayMarker.Kind.USAGE_RESET, label = "x", at = nwNow, fraction = f, tone = RunwayMarker.Tone.GREEN)
            },
        )
        assertEquals(listOf(0, 1, 2, 0, 1), lanes.map { it.lane })
        assertEquals(lanes.map { it.fraction }.sorted(), lanes.map { it.fraction })
    }

    @Test fun `far apart labels share a lane`() {
        val lanes = RunwayModel.assignLanes(
            listOf(
                RunwayMarker("a", RunwayMarker.Kind.USAGE_RESET, "a", nwNow, 0.1, RunwayMarker.Tone.GREEN),
                RunwayMarker("b", RunwayMarker.Kind.USAGE_RESET, "b", nwNow, 0.6, RunwayMarker.Tone.GREEN),
            ),
        )
        assertTrue(lanes.all { it.lane == 0 })
    }

    @Test fun `the subline drops a battery figure the Mac chip already shows`() {
        val chip = "Studio MBP · on battery · 41%"
        assertEquals("5 working · runway clear till 10:40", NowModel.sublineBesideChip("5 working · runway clear till 10:40 · 41%", chip))
        assertEquals("5 working · on battery", NowModel.sublineBesideChip("5 working · on battery · 41%", chip))
        assertEquals("a different figure stays", "5 working · runway clear till 10:40 · 40%", NowModel.sublineBesideChip("5 working · runway clear till 10:40 · 40%", chip))
        assertEquals("a chip with no figure keeps it", "2 working · on battery · 41%", NowModel.sublineBesideChip("2 working · on battery · 41%", "Studio MBP · offline"))
    }

    @Test fun `the runway line reads the deadline, the battery and the AC state`() {
        assertEquals(
            "runway clear till 10:40 · 41%",
            NowModel.runwayLine(
                nwStatus(connected = true, age = 5.0, battery = 41, onAC = false),
                RunwayModel(emptyList(), onAC = false, clearUntil = nwNow.plusSeconds(160.0 * 60)),
                NW_ZONE,
            ),
        )
        assertEquals(
            "on battery · 41%",
            NowModel.runwayLine(nwStatus(connected = true, age = 5.0, battery = 41, onAC = false), RunwayModel.empty, NW_ZONE),
        )
        assertEquals("runway clear", NowModel.runwayLine(nwStatus(connected = true, age = 5.0, onAC = true), RunwayModel.empty, NW_ZONE))
    }

    // MARK: day rings

    @Test fun `today's rings count decisions, fast answers, finished turns and the calm ring`() {
        val fast1 = nwIv("d1", InterventionKind.APPROVAL, "[Bash] ls", t = NW_T0 - 60, session = "w1").copy(repliedAt = nwNow, repliedAction = "approve")
        val fast2 = nwIv("d2", InterventionKind.USER_INPUT, "Which?", t = NW_T0 - 30, session = "w1").copy(repliedAt = nwNow, repliedText = "x", repliedAction = "custom")
        val slow = nwIv("d3", InterventionKind.APPROVAL, "[Bash] ls", t = NW_T0 - 300, session = "w1").copy(repliedAt = nwNow, repliedAction = "deny")
        val yesterday = nwIv("d4", InterventionKind.APPROVAL, "[Bash] ls", t = NW_T0 - 86_400 - 60, session = "w1")
            .copy(repliedAt = nwNow.minusSeconds(86_400), repliedAction = "approve")
        val turn = nwIv("t1", InterventionKind.IDLE, "Done", t = NW_T0 - 600, session = "w1").copy(closedAt = nwNow)
        val turn2 = nwIv("t2", InterventionKind.IDLE, "Done", t = NW_T0 - 600, session = "w1").copy(closedAt = nwNow)
        val stuckDone = nwIv("t3", InterventionKind.IDLE, "Looks stuck", t = NW_T0 - 600, session = "w1", subtype = "looping").copy(closedAt = nwNow)
        val day = DayStats.today(listOf(fast1, fast2, slow, yesterday, turn, turn2, stuckDone), nwNow, NW_ZONE)
        assertEquals(3, day.decisions)
        assertEquals(2, day.unblockedFast)
        assertEquals(3, day.finished)
        assertEquals(2, day.shipped)
        val rings = day.rings
        assertEquals(listOf(RingStat.Kind.UNBLOCKED, RingStat.Kind.SHIPPED, RingStat.Kind.CALM), rings.map { it.kind })
        assertEquals("2 / 3", rings[0].detail)
        assertTrue(near(rings[0].progress, 2.0 / 3))
        assertEquals("2 / 3", rings[1].detail)
        assertTrue(near(rings[1].progress, 2.0 / 3))
        assertEquals("not tracked", rings[2].detail)
        assertEquals(0.0, rings[2].progress, 0.0)
    }

    @Test fun `no decisions reads none yet, and calm from seconds reads its duration`() {
        val empty = DayStats.today(emptyList(), nwNow, NW_ZONE).rings
        assertEquals("none yet", empty[0].detail)
        assertEquals("none yet", empty[1].detail)
        assertEquals(0.0, empty[0].progress, 0.0)
        val calm = DayStats(calmSeconds = 7200.0).rings[2]
        assertTrue(near(calm.progress, 0.5))
        assertEquals("2 h", calm.detail)
    }

    @Test fun `the ring summary title and the detail line`() {
        val rings = DayStats.today(
            listOf(
                nwIv("d1", InterventionKind.APPROVAL, "[Bash] ls", t = NW_T0 - 60, session = "w1").copy(repliedAt = nwNow, repliedAction = "approve"),
                nwIv("d2", InterventionKind.USER_INPUT, "Which?", t = NW_T0 - 30, session = "w1").copy(repliedAt = nwNow, repliedText = "x", repliedAction = "custom"),
                nwIv("d3", InterventionKind.APPROVAL, "[Bash] ls", t = NW_T0 - 300, session = "w1").copy(repliedAt = nwNow, repliedAction = "deny"),
                nwIv("t1", InterventionKind.IDLE, "Done", t = NW_T0 - 600, session = "w1").copy(closedAt = nwNow),
                nwIv("t2", InterventionKind.IDLE, "Done", t = NW_T0 - 600, session = "w1").copy(closedAt = nwNow),
                nwIv("t3", InterventionKind.IDLE, "Looks stuck", t = NW_T0 - 600, session = "w1", subtype = "looping").copy(closedAt = nwNow),
            ),
            nwNow, NW_ZONE,
        ).rings
        assertEquals("Tonight", RingSummary.title(rings))
        assertEquals("One ring closed ✦", RingSummary.title(listOf(RingStat(RingStat.Kind.CALM, 1.0, "x"))))
        assertEquals("All three rings closed ✦", RingSummary.title(rings.map { RingStat(it.kind, 1.0, "x") }))
        assertEquals("Unblocked 2 / 3 · Shipped 2 / 3 · Calm not tracked", RingSummary.detail(rings))
    }
}
