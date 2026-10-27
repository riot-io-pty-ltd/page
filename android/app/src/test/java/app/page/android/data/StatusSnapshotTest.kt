package app.page.android.data

import app.page.android.model.MacStatusSnapshot
import app.page.android.model.RunwayModel
import java.time.Instant
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** What the home-screen widget and the Quick Settings tile may show: counts and a sentence, never a project or a command. */
class StatusSnapshotTest {
    private val now = Instant.ofEpochSecond(1_800_000_000)
    private fun status(connected: Boolean?) = MacStatusSnapshot(macConnected = connected, lastHeartbeatAt = now, activeSessions = 9, battery = 41, onAC = false, working = 5)

    @Test fun `round trips and survives unknown fields`() {
        val s = StatusSnapshot.of("Studio MBP", status(true), 2, 5, "2 need you", "5 working", RunwayModel.empty, now)
        assertEquals(s, StatusSnapshot.decode(StatusSnapshot.encode(s)))
        assertNull(StatusSnapshot.decode("not json"))
        assertEquals("2 need you", StatusSnapshot.decode(StatusSnapshot.encode(s).dropLast(1) + ",\"future\":1}")?.headline)
    }

    @Test fun `silence is earned`() {
        val offline = StatusSnapshot.of("Studio MBP", status(false), 0, 0, "All quiet", "", RunwayModel.empty, now)
        assertTrue(offline.isUnreachable)
        assertEquals("Mac offline", offline.faceHeadline)
        val online = StatusSnapshot.of("Studio MBP", status(true), 0, 0, "All quiet", "", RunwayModel.empty, now)
        assertFalse(online.isUnreachable)
        assertEquals("All quiet", online.faceHeadline)
    }

    @Test fun `carries counts and power only`() {
        val s = StatusSnapshot.of("Studio MBP", status(true), 2, 5, "2 need you", "5 working", RunwayModel.empty, now)
        assertEquals("5 working · 9 live", s.detail)
        val json = StatusSnapshot.encode(s)
        assertFalse(json.contains("cwd"))
        assertFalse(json.contains("context"))
    }
}
