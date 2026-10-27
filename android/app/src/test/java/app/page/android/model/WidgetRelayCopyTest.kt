package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The widget's face, the Mac line and the relay and notification copy, ported from the widget and copy checks in
 * iOS/Tests/LogicTests.swift ("widget copy", "several Macs" copy, "notification copy", "relay copy").
 */
class WidgetRelayCopyTest {
    private fun ws(presence: WidgetStatus.Presence, needsYou: Int, snapshot: MacStatusSnapshot? = null) = WidgetStatus(
        macName = "Studio MBP", presence = presence, needsYou = needsYou, working = null, live = null,
        batteryLine = null, usageLine = null, fetchedAt = nwNow, usage = null, snapshot = snapshot,
    )

    @Test fun `an offline or silent Mac is never All quiet on the widget face`() {
        assertEquals("Mac offline", ws(WidgetStatus.Presence.OFFLINE, 0).faceHeadline)
        assertEquals("Not checking in", ws(WidgetStatus.Presence.STALE, 0).faceHeadline)
        assertEquals("All quiet", ws(WidgetStatus.Presence.ONLINE, 0).faceHeadline)
        assertEquals("2 need you", ws(WidgetStatus.Presence.ONLINE, 2).faceHeadline)
        assertTrue(ws(WidgetStatus.Presence.OFFLINE, 0).isUnreachable)
        assertTrue(ws(WidgetStatus.Presence.STALE, 0).isUnreachable)
        assertFalse(ws(WidgetStatus.Presence.ONLINE, 0).isUnreachable)
    }

    @Test fun `the Mac line names the power state and the battery, and names only the Mac without a snapshot`() {
        assertEquals(
            "Studio MBP · on battery 41%",
            ws(WidgetStatus.Presence.ONLINE, 0, nwStatus(connected = true, age = 5.0, battery = 41, onAC = false)).macLine,
        )
        assertEquals(
            "Studio MBP · on power",
            ws(WidgetStatus.Presence.ONLINE, 0, nwStatus(connected = true, age = 5.0, onAC = true)).macLine,
        )
        assertEquals("Studio MBP", ws(WidgetStatus.Presence.ONLINE, 0).macLine)
    }

    @Test fun `no snapshot means no runway, and a battery forecast puts the cutoff on the widget's runway`() {
        assertTrue(ws(WidgetStatus.Presence.ONLINE, 0).runway(nwNow, NW_ZONE).onAC)
        assertTrue(ws(WidgetStatus.Presence.ONLINE, 0).runway(nwNow, NW_ZONE).markers.isEmpty())
        val withForecast = ws(
            WidgetStatus.Presence.ONLINE, 0,
            nwStatus(connected = true, age = 5.0, battery = 41, onAC = false, forecast = BatteryForecast(10, 148, 0.0)),
        )
        assertTrue(withForecast.runway(nwNow, NW_ZONE).markers.any { it.id == "battery-cutoff" })
    }

    @Test fun `the relay connection copy reads connected, connecting, offline with the reason, and reconnecting`() {
        assertEquals("Connected", RelayConnectionText.text(connected = true, connecting = false, failure = null))
        assertEquals("Connecting…", RelayConnectionText.text(connected = false, connecting = true, failure = null))
        assertEquals("Offline — no route", RelayConnectionText.text(connected = false, connecting = false, failure = "no route"))
        assertEquals("Reconnecting…", RelayConnectionText.text(connected = false, connecting = false, failure = null))
    }

    @Test fun `the notification state copy`() {
        assertEquals("Off — you won't be paged", NotificationsState.OFF.text)
        assertEquals("Not set up yet", NotificationsState.NOT_SET.text)
        assertEquals("Allowed", NotificationsState.ALLOWED.text)
    }
}
