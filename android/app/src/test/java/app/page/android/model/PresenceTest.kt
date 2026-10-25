package app.page.android.model

import java.time.DayOfWeek
import java.time.LocalDateTime
import java.time.ZoneOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PresenceTest {
    @Test
    fun presence() {
        val hbOld = MacStatusSnapshot(macConnected = null, lastHeartbeatAt = NOW.plusSeconds(-200.0))
        assertEquals(MacPresence.Unknown, MacPresence.evaluate(null, NOW))
        assertEquals("old worker stale -> offline", MacPresence.Offline(NOW.plusSeconds(-200.0)), MacPresence.evaluate(hbOld, NOW))
        assertTrue(MacPresence.evaluate(MacStatusSnapshot(lastHeartbeatAt = NOW.plusSeconds(-10.0)), NOW).isReachable)
        assertEquals(MacPresence.Stale(NOW.plusSeconds(-200.0)), MacPresence.evaluate(MacStatusSnapshot(macConnected = true, lastHeartbeatAt = NOW.plusSeconds(-200.0)), NOW))
        assertEquals(MacPresence.Online(null), MacPresence.evaluate(MacStatusSnapshot(macConnected = true), NOW))
        assertEquals(MacPresence.Offline(NOW), MacPresence.evaluate(MacStatusSnapshot(macConnected = false, lastHeartbeatAt = NOW), NOW))
        assertTrue(MacStatusSnapshot(battery = 0).batteryPercent == null && MacStatusSnapshot(battery = -1).batteryPercent == null)
        assertEquals(54, MacStatusSnapshot(battery = 54).batteryPercent)
        val st = MacStatusSnapshot.from(parseJsonObject("""{"macConnected":true,"lastHeartbeatAt":"2026-10-24T01:02:03.456Z","battery":80,"onAC":false,"activeSessions":3}""")!!)
        assertTrue(st.macConnected == true && st.lastHeartbeatAt != null && st.activeSessions == 3 && st.onAC == false)
    }

    @Test
    fun neverConnectedPairing() {
        val unseen = MacStatusSnapshot.from(parseJsonObject("""{"macConnected":false,"macEverSeen":false,"pendingCount":0}""")!!)
        assertTrue(unseen.macEverSeen == false && unseen.pendingCount == 0)
        assertEquals(MacPresence.NeverConnected, MacPresence.evaluate(unseen, NOW))
        assertTrue(MacPresence.evaluate(unseen, NOW).suggestsRepair(NOW))
        assertTrue(unseen.looksUnused)
        val seenOffline = MacStatusSnapshot(macConnected = false, lastHeartbeatAt = NOW.plusSeconds(-600.0), macEverSeen = true)
        assertEquals(MacPresence.Offline(NOW.plusSeconds(-600.0)), MacPresence.evaluate(seenOffline, NOW))
        assertFalse("short offline: no re-pair hint", MacPresence.evaluate(seenOffline, NOW).suggestsRepair(NOW))
        assertTrue(MacPresence.evaluate(MacStatusSnapshot(macConnected = false, lastHeartbeatAt = NOW.plusSeconds(-7200.0)), NOW).suggestsRepair(NOW))
        assertEquals(
            "heartbeat on record overrides macEverSeen=false",
            MacPresence.Offline(NOW.plusSeconds(-60.0)),
            MacPresence.evaluate(MacStatusSnapshot(macConnected = false, lastHeartbeatAt = NOW.plusSeconds(-60.0), macEverSeen = false), NOW),
        )
        assertEquals(MacPresence.Offline(null), MacPresence.evaluate(MacStatusSnapshot(macConnected = false), NOW))
        assertTrue(MacStatusSnapshot(macConnected = false, pendingCount = 0).looksUnused)
        assertFalse(MacStatusSnapshot(macConnected = false, pendingCount = 2).looksUnused)
        assertFalse(MacStatusSnapshot(macConnected = false).looksUnused)
        assertFalse(MacStatusSnapshot(macConnected = true, macEverSeen = false).looksUnused)
        val everSeen = MacStatusSnapshot.from(parseJsonObject("""{"macConnected":false,"macEverSeen":true,"pendingCount":0}""")!!)
        assertEquals(MacPresence.Offline(null), MacPresence.evaluate(everSeen, NOW))
        assertFalse(everSeen.looksUnused)
    }

    @Test
    fun stats() {
        fun utc(y: Int, m: Int, d: Int, h: Int) = LocalDateTime.of(y, m, d, h, 0).toInstant(ZoneOffset.UTC)
        val wed = utc(2026, 10, 21, 12)
        val mon = utc(2026, 10, 19, 1)
        val lastSun = utc(2026, 10, 18, 23)
        val t = wed.epochSecond.toDouble()
        val hist = listOf(
            iv("h1", InterventionKind.APPROVAL, t - 60, replied = t - 30, project = "a"),
            iv("h2", InterventionKind.IDLE, mon.epochSecond.toDouble(), project = "a"),
            iv("h3", InterventionKind.IDLE, lastSun.epochSecond.toDouble(), project = "b"),
        )
        val inbox = listOf(iv("h1", InterventionKind.APPROVAL, t - 60, project = "a"), iv("n1", InterventionKind.USER_INPUT, t - 5, project = "c"))
        val stats = PageStats.compute(hist, inbox, wed, ZoneOffset.UTC, DayOfWeek.MONDAY)
        assertEquals(2, stats.today)
        assertEquals(3, stats.thisWeek)
        assertEquals(30L, stats.avgResponseSeconds)
        assertEquals(PageStats.ProjectCount("a", 2), stats.topProjects.first())
        assertNull(PageStats.compute(emptyList(), emptyList(), wed, ZoneOffset.UTC, DayOfWeek.MONDAY).avgResponseSeconds)
    }
}
