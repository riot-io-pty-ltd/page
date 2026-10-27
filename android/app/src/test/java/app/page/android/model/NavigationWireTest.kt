package app.page.android.model

import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Navigation (the Now and Sky pages, the sheet queue, deep links, the Sky mode) and wire compatibility for the Mac's
 * optional fields, ported from the "Navigation, sheets and links" checks in iOS/Tests/LogicTests.swift and the
 * decoding rules in iOS/Page/Models. Everything the Mac may or may not send is optional: an old Mac's payload
 * decodes, and a new one's extra fields are ignored.
 */
class NavigationWireTest {
    // MARK: navigation

    @Test fun `a leftward drag from Now reveals Sky, a rightward one from Sky returns to Now, and a vertical drag is a scroll`() {
        assertEquals(NWDestination.SKY, NWDestination.afterDrag(NWDestination.NOW, -60.0))
        assertEquals(NWDestination.NOW, NWDestination.afterDrag(NWDestination.NOW, 60.0))
        assertEquals(NWDestination.NOW, NWDestination.afterDrag(NWDestination.SKY, 60.0))
        assertEquals(NWDestination.SKY, NWDestination.afterDrag(NWDestination.SKY, -60.0))
        assertEquals(NWDestination.NOW, NWDestination.afterDrag(NWDestination.NOW, -60.0, vertical = 80.0))
        assertEquals("a drag of 45 with 40 down is not horizontal", NWDestination.NOW, NWDestination.afterDrag(NWDestination.NOW, -45.0, vertical = 40.0))
        assertEquals(NWDestination.SKY, NWDestination.afterDrag(NWDestination.NOW, -45.0))
        assertTrue(NWDestination.isHorizontal(60.0, 40.0))
        assertFalse(NWDestination.isHorizontal(50.0, 40.0))
        assertEquals(NWDestination.SKY, NWDestination.NOW.other)
        assertEquals(NWDestination.NOW, NWDestination.SKY.other)
    }

    @Test fun `a sheet waits for the one already up, a repeat changes nothing, and close clears both`() {
        var q = SheetQueue()
        q = q.request(NWSheet.Dispatch)
        assertEquals(NWSheet.Dispatch, q.current)
        assertNull(q.pending)
        q = q.request(NWSheet.Tower(null))
        assertNull(q.current)
        assertEquals(NWSheet.Tower(null), q.pending)
        q = q.dismissed()
        assertEquals(NWSheet.Tower(null), q.current)
        assertNull(q.pending)
        q = q.request(NWSheet.Tower(null))
        assertEquals(NWSheet.Tower(null), q.current)
        assertNull(q.pending)
        q = q.close()
        assertNull(q.current)
        assertNull(q.pending)
        q = SheetQueue().request(NWSheet.Dispatch).request(NWSheet.History).set(null)
        assertEquals("setting nil keeps a pending sheet", NWSheet.History, q.pending)
    }

    @Test fun `deep links open the decision, Sky, Now or the Tower, and anything else is nothing`() {
        assertEquals(NWDeepLink.Decision("abc"), NWDeepLink.parse("page://intervention/abc"))
        assertEquals(NWDeepLink.Sky, NWDeepLink.parse("page://sessions"))
        assertEquals(NWDeepLink.Sky, NWDeepLink.parse("page://sky"))
        assertEquals(NWDeepLink.Now, NWDeepLink.parse("page://now"))
        assertEquals(NWDeepLink.Tower, NWDeepLink.parse("page://tower"))
        assertNull(NWDeepLink.parse("https://x"))
        assertNull(NWDeepLink.parse("page://nonsense"))
    }

    @Test fun `the Sky mode is Sky when missing or unknown, and Lanes round-trips`() {
        assertEquals(SkyMode.SKY, SkyMode.stored(null))
        assertEquals(SkyMode.SKY, SkyMode.stored("bogus"))
        assertEquals(SkyMode.LANES, SkyMode.stored("lanes"))
        assertEquals("page.skyMode", SkyMode.storageKey)
    }

    // MARK: wire compatibility: an old Mac's payload and a new one's

    private fun obj(json: String): JsonObject = parseJsonObject(json)!!

    @Test fun `an intervention decodes from the minimal payload and ignores fields it does not know`() {
        val minimal = Intervention.decode(obj("""{"id":"a","sessionId":"s","kind":"approval","openedAt":"2026-10-24T01:02:03Z","context":"[Bash] ls"}"""))
        assertNotNull(minimal)
        assertNull(minimal!!.backend)
        assertNull(minimal.subtype)
        assertNull(minimal.deliveryStatus)
        assertFalse(minimal.hasUnknownBackend)
        val withFuture = Intervention.decode(
            obj("""{"id":"a","sessionId":"s","kind":"approval","openedAt":"2026-10-24T01:02:03Z","context":"[Bash] ls","futureField":{"x":1},"source":"vscode"}"""),
        )
        assertNotNull("unknown fields are ignored", withFuture)
        assertEquals(InterventionSource.VSCODE, withFuture!!.source)
    }

    @Test fun `an intervention with the new optional fields reads them, and a hook page reads as one`() {
        val full = Intervention.decode(
            obj(
                """{"id":"hook-9","sessionId":"s","kind":"approval","openedAt":"2026-10-24T01:02:03Z","context":"[Bash] ls",
                "backend":"codex","subtype":"plan","deliveryStatus":"sent","hookBlocking":true}""",
            ),
        )!!
        assertEquals(InterventionBackend.CODEX, full.backend)
        assertEquals("plan", full.subtype)
        assertEquals("sent", full.deliveryStatus)
        assertTrue(full.isBlockingHook)
        assertTrue(full.acceptsDecisionsOnly)
        val unknown = Intervention.decode(
            obj("""{"id":"g","sessionId":"s","kind":"approval","openedAt":"2026-10-24T01:02:03Z","context":"[Bash] ls","backend":"gemini"}"""),
        )!!
        assertTrue(unknown.hasUnknownBackend)
        assertEquals("gemini", unknown.backendRaw)
    }

    @Test fun `a session row decodes with no optional fields, and a malformed optional field is treated as missing`() {
        val old = LiveSession.decode(obj("""{"id":"s1","state":"waitingOnUser"}"""))!!
        assertNull(old.ask)
        assertNull(old.flight)
        assertEquals("s1", old.id)
        val bad = LiveSession.decode(obj("""{"id":"s1","state":"waitingOnUser","ask":{"id":5},"healthDetail":5}"""))!!
        assertNull("a malformed ask leaves the session intact", bad.ask)
        assertEquals("s1", bad.id)
        assertNull(LiveSession.decode(obj("""{"state":"active"}""")))
    }

    @Test fun `the health note reads healthDetail, falls back to healthNote, and healthDetail wins when both are sent`() {
        val detailOnly = LiveSession.decode(obj("""{"id":"s","health":"stuck","healthDetail":"no progress for 15 min"}"""))!!
        assertEquals("no progress for 15 min", detailOnly.flight?.healthNote)
        val noteOnly = LiveSession.decode(obj("""{"id":"s","health":"stuck","healthNote":"the same step 6 times"}"""))!!
        assertEquals("the same step 6 times", noteOnly.flight?.healthNote)
        val both = LiveSession.decode(obj("""{"id":"s","health":"stuck","healthDetail":"from the Mac","healthNote":"older name"}"""))!!
        assertEquals("from the Mac", both.flight?.healthNote)
    }

    @Test fun `the session commands carry the expectation only when it is known, and the Stop-all is the bare op`() {
        val withTarget = SessionCommand.Input("s1", "hi", SessionTarget("s1", "page", "page", "~/projects/page", "cmux", "M", "Claude"))
        val body = parseJsonObject(String(withTarget.plaintext("c", "v", CMD_NOW), Charsets.UTF_8))!!
        assertEquals("~/projects/page", (body["expectCwd"] as kotlinx.serialization.json.JsonPrimitive).content)
        val bare = parseJsonObject(String(SessionCommand.Input("s1", "hi").plaintext("c", "v", CMD_NOW), Charsets.UTF_8))!!
        assertNull(bare["expectCwd"])
        assertNull(bare["expectTitle"])
        val stopAll = parseJsonObject(String(SessionCommand.InterruptAll.plaintext("c", "v", CMD_NOW), Charsets.UTF_8))!!
        assertEquals("interruptAll", (stopAll["op"] as kotlinx.serialization.json.JsonPrimitive).content)
    }
}
