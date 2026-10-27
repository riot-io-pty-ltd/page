package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * Now banners, session availability copy, the Settled log, the History screen, Mac presence copy and the Now
 * stream's frozen order and in-flight strands, ported from the "Now banners and Settled", "History screen",
 * "History and presence copy, edge cases", and "Now stream" checks in iOS/Tests/LogicTests.swift.
 */
class SettledHistoryBannerTest {
    private fun banner(
        auth: Boolean = false,
        failure: String? = null,
        connected: Boolean = true,
        presence: MacPresence = MacPresence.Online(null),
        notifications: NotificationsState = NotificationsState.ALLOWED,
    ): List<NowBanner> = NowBanner.build(NowBanner.Inputs(auth, failure, connected, presence, notifications, nwNow))

    // MARK: banners

    @Test fun `a rejected pairing is the first banner and repairs`() {
        val first = banner(auth = true).first()
        assertEquals("This pairing no longer works", first.title)
        assertEquals(NowBanner.Action.REPAIR, first.action)
    }

    @Test fun `a relay that cannot be reached retries`() {
        val relay = banner(failure = "timeout", connected = false).first()
        assertEquals("Can't reach your relay", relay.title)
        assertEquals(NowBanner.Action.RETRY, relay.action)
    }

    @Test fun `a fresh offline Mac offers no re-pair, an offline one for over an hour does`() {
        assertNull(banner(presence = MacPresence.Offline(nwNow.minusSeconds(300))).first().action)
        assertEquals(NowBanner.Action.REPAIR, banner(presence = MacPresence.Offline(nwNow.minusSeconds(7200))).first().action)
        assertEquals("Your Mac is offline", banner(presence = MacPresence.Offline(nwNow.minusSeconds(300))).first().title)
    }

    @Test fun `notifications off opens settings, and a healthy page has no banners`() {
        assertEquals(NowBanner.Action.OPEN_NOTIFICATION_SETTINGS, banner(notifications = NotificationsState.OFF).first().action)
        assertTrue(banner().isEmpty())
    }

    @Test fun `session availability copy names the repair, retry and the old Mac`() {
        assertEquals("Live", SessionAvailabilityCopy.of(SessionAvailability.Ready).shortStatus)
        assertEquals(SessionAvailabilityCopy.Action.REPAIR, SessionAvailabilityCopy.of(SessionAvailability.NeedsRepair(keyMismatch = true)).action)
        assertEquals(SessionAvailabilityCopy.Action.RETRY, SessionAvailabilityCopy.of(SessionAvailability.MacOffline).action)
        assertEquals("Update Page on your Mac", SessionAvailabilityCopy.of(SessionAvailability.MacTooOld).title)
    }

    // MARK: Settled

    private fun settled(id: String, kind: InterventionKind, context: String, ago: Double, action: String?, subtype: String? = null): Intervention {
        val base = nwIv(id, kind, context, t = NW_T0 - ago - 60, session = "w1", subtype = subtype)
        return base.copy(repliedAt = if (action == null) null else nwNow.minusSeconds(ago.toLong()), repliedAction = action)
    }

    private val approve = settled("s1", InterventionKind.APPROVAL, "[Bash] npm test", 120.0, "approve").copy(deliveryStatus = "delivered")
    private val failedDeny = settled("s2", InterventionKind.APPROVAL, "[Bash] rm -rf x", 300.0, "deny").copy(deliveryStatus = "failed")
    private val custom = settled("s3", InterventionKind.USER_INPUT, "Which?", 400.0, "custom").copy(repliedText = "use the cache")
    private val longReply = settled("s4", InterventionKind.USER_INPUT, "Which?", 500.0, "custom").copy(repliedText = "a".repeat(40))
    private val sent = settled("s5", InterventionKind.APPROVAL, "[Bash] npm test", 600.0, "approve").copy(deliveryStatus = "sent")

    @Test fun `the Settled lines read like the iOS log, with status and quotes`() {
        val log = SettledLog.build(listOf(approve, failedDeny, custom, longReply, sent), nwNow, NW_ZONE)
        val byId = log.today.associateBy { it.id }
        assertEquals("Approved npm test", byId["s1"]?.text)
        assertEquals(SettledLine.Tone.APPROVED, byId["s1"]?.tone)
        assertEquals("delivered ✓", byId["s1"]?.status)
        assertEquals("sent", byId["s5"]?.status)
        assertEquals("Denied rm -rf x", byId["s2"]?.text)
        assertEquals("not delivered", byId["s2"]?.status)
        assertEquals("Sent “use the cache”", byId["s3"]?.text)
        assertEquals("Sent “" + "a".repeat(27) + "…”", byId["s4"]?.text)
        assertEquals("s1", log.today.first().id)
    }

    @Test fun `today is capped at twelve lines`() {
        val many = (0 until 14).map { settled("m$it", InterventionKind.APPROVAL, "[Bash] ls", (it * 60 + 60).toDouble(), "approve") }
        assertEquals(SettledLog.lineLimit, SettledLog.build(many, nwNow, NW_ZONE).today.size)
    }

    @Test fun `yesterday's card counts decided, finished, stuck and battery pauses in headline order`() {
        val yesterday = listOf(
            settled("y1", InterventionKind.APPROVAL, "[Bash] ls", 86_400.0, "approve"),
            settled("y2", InterventionKind.APPROVAL, "[Bash] ls", 86_460.0, "deny"),
            settled("y3", InterventionKind.USER_INPUT, "Which?", 86_520.0, "custom"),
            settled("y4", InterventionKind.IDLE, "Done", 86_580.0, null),
            settled("y5", InterventionKind.IDLE, "Done", 86_640.0, null),
            settled("y6", InterventionKind.IDLE, "Looks stuck", 86_700.0, null, subtype = "stuck"),
            settled("y7", InterventionKind.IDLE, "Paused", 86_760.0, null, subtype = "low_battery"),
        )
        val card = SettledLog.build(yesterday, nwNow, NW_ZONE).days.first()
        assertEquals(3, card.decided)
        assertEquals(2, card.finished)
        assertEquals(1, card.stuck)
        assertEquals(1, card.batteryPauses)
        assertTrue(card.headline, card.headline.endsWith(" · 3 decided · 2 finished · 1 stuck · battery pause ×1"))
        val quiet = SettledLog.build(listOf(nwIv("q", InterventionKind.RATE_LIMIT, "Limit", t = NW_T0 - 86_400, session = "w1")), nwNow, NW_ZONE)
        assertTrue(quiet.days.first().headline.endsWith(" · quiet"))
    }

    @Test fun `decisions are answered pages only`() {
        assertTrue(SettledLog.isDecision(approve))
        assertFalse(SettledLog.isDecision(nwIv("x", InterventionKind.APPROVAL, "x", session = "w1")))
    }

    @Test fun `the summary text and the empty day`() {
        assertEquals("quiet", SettledLog.summaryText(0, 0, 0, 0))
        assertEquals("battery pause ×2", SettledLog.summaryText(0, 0, 0, 2))
        assertEquals("14 decided · 6 finished · 2 stuck · battery pause ×1", SettledLog.summaryText(14, 6, 2, 1))
    }

    // MARK: History

    private fun hItem(id: String, kind: InterventionKind, context: String, ago: Double, action: String?, subtype: String? = null, project: String = "page"): Intervention {
        val base = nwIv(id, kind, context, t = NW_T0 - ago - 60, session = "w1", project = project, subtype = subtype)
        return base.copy(
            repliedAt = if (action == null) null else nwNow.minusSeconds(ago.toLong()),
            repliedAction = action,
            closedAt = nwNow.minusSeconds(ago.toLong()),
        )
    }

    private fun historyItems(): List<Intervention> {
        val items = ArrayList<Intervention>()
        for (i in 0 until 20) items.add(hItem("t$i", InterventionKind.APPROVAL, "[Bash] ls", (i * 30 + 30).toDouble(), "approve"))
        items.add(hItem("y1", InterventionKind.APPROVAL, "[Bash] ls", 86_400.0, "approve", project = "relay"))
        items.add(hItem("y2", InterventionKind.IDLE, "Done", 86_460.0, null, project = "relay"))
        items.add(hItem("y3", InterventionKind.IDLE, "Looks stuck", 86_520.0, null, subtype = "stuck"))
        items.add(hItem("old", InterventionKind.APPROVAL, "[Bash] ls", 40.0 * 86_400, "deny"))
        return items
    }

    @Test fun `History lists every settled page, today in full, yesterday titled, old days kept`() {
        val m = HistoryScreenModel.build(historyItems(), listOf(nwIv("open", InterventionKind.APPROVAL, "[Bash] ls", session = "w1")), nwNow, NW_ZONE)
        assertEquals(24, m.total)
        assertEquals(1, m.pending)
        assertEquals("Today", m.days.first().title)
        assertEquals("today shows all twenty lines, not Settled's twelve", 20, m.days.first().rows.size)
        assertEquals("Yesterday", m.days[1].title)
        assertEquals("1 decided · 1 finished · 1 stuck", m.days[1].summary)
        assertEquals(listOf("old"), m.days.last().rows.map { it.id })
        assertTrue(m.days.last().title.contains(" "))
        assertTrue(m.days.last().title != "Today")
        assertEquals(m.days.map { it.day }.sortedDescending(), m.days.map { it.day })
        assertEquals("t0", m.days.first().rows.first().id)
    }

    @Test fun `a History row reads like its Settled line plus project and kind`() {
        val row = HistoryScreenModel.build(historyItems(), emptyList(), nwNow, NW_ZONE).days.first().rows.first()
        assertEquals("Approved ls", row.text)
        assertEquals(SettledLine.Tone.APPROVED, row.tone)
        assertTrue(row.detail, row.detail.startsWith("page · APPROVAL"))
    }

    @Test fun `the tiles count the open page too, and the rings the settled ones`() {
        val m = HistoryScreenModel.build(historyItems(), listOf(nwIv("open", InterventionKind.APPROVAL, "[Bash] ls", session = "w1")), nwNow, NW_ZONE)
        assertEquals(3, m.rings.size)
        assertEquals(21, m.stats.today)
        assertEquals("page", m.stats.topProjects.first().name)
    }

    @Test fun `the empty state, loading, failed and nothing settled`() {
        assertNull(HistoryEmpty.state(isEmpty = false, loaded = true, failure = "x"))
        assertEquals(HistoryEmpty.Loading, HistoryEmpty.state(isEmpty = true, loaded = false, failure = null))
        assertEquals(HistoryEmpty.None, HistoryEmpty.state(isEmpty = true, loaded = true, failure = null))
        assertEquals(HistoryEmpty.Failed("offline"), HistoryEmpty.state(isEmpty = true, loaded = false, failure = "offline"))
        assertTrue(HistoryScreenModel.build(emptyList(), emptyList(), nwNow, NW_ZONE).days.isEmpty())
    }

    private val dayStart: Instant = startOfDay(nwNow, NW_ZONE)
    private val dayOffset: Double = dayStart.epochSecond.toDouble() - NW_T0

    private fun hcPage(id: String, replied: Double?, closed: Double? = null, delivery: String? = null): Intervention {
        val offset = replied ?: closed ?: 0.0
        val base = nwIv(id, InterventionKind.APPROVAL, "[Bash] ls", t = NW_T0 + offset - 60, session = "w1", project = "page")
        var x = base
        if (replied != null) x = x.copy(repliedAt = nwNow.plusSeconds(replied.toLong()), repliedAction = "approve", deliveryStatus = delivery)
        if (closed != null) x = x.copy(closedAt = nwNow.plusSeconds(closed.toLong()))
        return x
    }

    @Test fun `a page is filed under the day its zone says, so one page can be yesterday in UTC and today at plus two`() {
        val late = hcPage("late", replied = dayOffset - 1800)
        val noon = hcPage("noon", replied = dayOffset - 43_200)
        val utc = HistoryScreenModel.build(listOf(late, noon), emptyList(), nwNow, ZoneOffset.UTC)
        assertEquals(1, utc.days.size)
        assertEquals(listOf("late", "noon"), utc.days[0].rows.map { it.id })
        assertEquals("Yesterday", utc.days[0].title)
        val east = HistoryScreenModel.build(listOf(late, noon), emptyList(), nwNow, ZoneId.of("UTC+02:00"))
        assertEquals(listOf(listOf("late"), listOf("noon")), east.days.map { d -> d.rows.map { it.id } })
        assertEquals("Today", east.days[0].title)
    }

    @Test fun `an unanswered page sorts by its close time`() {
        val closed = hcPage("closed", replied = null, closed = -60.0)
        val answered = hcPage("answered", replied = -600.0)
        val order = HistoryScreenModel.build(listOf(answered, closed), emptyList(), nwNow, ZoneOffset.UTC)
        assertEquals(listOf("closed", "answered"), order.days.first().rows.map { it.id })
    }

    @Test fun `History row copy - a delivered reply reads its age and delivery, and an unanswered one only its age`() {
        val row = HistoryScreenModel.row(hcPage("r", replied = -120.0, delivery = "delivered"), nwNow)
        assertEquals("2m · delivered ✓", row.trailing)
        assertEquals("Approved ls, page, 2m · delivered ✓", row.spoken)
        assertTrue(row.detail, row.detail.contains("Answered in 1m"))
        val quiet = HistoryScreenModel.row(hcPage("q", replied = null, closed = -300.0), nwNow)
        assertEquals("5m", quiet.trailing)
        assertFalse(quiet.detail.contains("Answered in"))
    }

    @Test fun `a day title is Today, Yesterday, or the weekday, day and month`() {
        assertEquals("Tue 20 Oct", HistoryScreenModel.dayTitle(Instant.parse("2026-10-20T00:00:00Z"), dayStart, ZoneOffset.UTC))
        assertEquals("Today", HistoryScreenModel.dayTitle(dayStart, dayStart, ZoneOffset.UTC))
    }

    @Test fun `every Mac presence line reads as the iOS copy`() {
        assertEquals("Checking…", MacPresence.Unknown.summary(nwNow))
        assertEquals("Online · heartbeat just now", MacPresence.Online(nwNow.minusSeconds(2)).summary(nwNow))
        assertEquals("Online · heartbeat 12s ago", MacPresence.Online(nwNow.minusSeconds(12)).summary(nwNow))
        assertEquals("Not responding · last heartbeat 3m ago", MacPresence.Stale(nwNow.minusSeconds(200)).summary(nwNow))
        assertEquals("Offline", MacPresence.Offline(null).summary(nwNow))
        assertEquals("Offline · last seen 2h ago", MacPresence.Offline(nwNow.minusSeconds(7200)).summary(nwNow))
        assertEquals("Online", MacPresence.Online(null).summary(nwNow))
        assertEquals("Never connected with this pairing", MacPresence.NeverConnected.summary(nwNow))
    }

    // MARK: the Now stream

    @Test fun `a frozen list keeps what is shown and queues the new, unfrozen takes the fresh order`() {
        val rowA = NowRowBuilder.row(nwIv("a", InterventionKind.APPROVAL, "[Bash] ls", session = "w1"), null, "M")
        val rowB = NowRowBuilder.row(nwIv("b", InterventionKind.APPROVAL, "[Bash] ls", session = "w1"), null, "M")
        val rowD = NowRowBuilder.row(nwIv("d", InterventionKind.APPROVAL, "[Bash] ls", session = "w1"), null, "M")
        val frozen = StableOrder.merge(listOf("a", "b", "c"), listOf(rowD, rowA), frozen = true)
        assertEquals(listOf("a"), frozen.rows.map { it.id })
        assertEquals(1, frozen.queuedNew)
        assertEquals(listOf("d", "b", "a"), StableOrder.merge(listOf("a", "b"), listOf(rowD, rowB, rowA), frozen = false).rows.map { it.id })
        assertEquals(listOf("a", "b"), StableOrder.merge(emptyList(), listOf(rowA, rowB), frozen = true).rows.map { it.id })
    }

    @Test fun `only working sessions are strands, most recent first, with compact ages and a project name`() {
        val act1 = nwSession("i1", title = "bottle-flip", state = "active", activeAt = NW_T0 - 10, canInterrupt = true)
        val act2 = nwSession("i2", title = "page", state = "active", cwd = "~/projects/page", activeAt = NW_T0 - 100)
        val idle = nwSession("i3", title = "idle", state = "idle")
        val strands = InFlightStrand.build(listOf(idle, act2, act1), emptyMap(), nwNow)
        assertEquals(listOf("i1", "i2"), strands.map { it.id })
        assertEquals("10s", strands[0].age)
        assertEquals("1m", strands[1].age)
        assertEquals("page", strands[1].project)
        assertEquals("working", strands[0].lastAction)
        assertEquals(12, InFlightStrand.build((0 until 20).map { nwSession("x$it", state = "active") }, emptyMap(), nwNow).size)
    }
}
