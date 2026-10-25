package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DisplayCopyTest {
    @Test
    fun relativeTime() {
        assertEquals("Paged just now", RelativeTime.string("Paged", NOW.plusSeconds(3.0), NOW))
        assertEquals("Paged 12s ago", RelativeTime.string("Paged", NOW.plusSeconds(-12.0), NOW))
        assertEquals("Paged 5m ago", RelativeTime.string("Paged", NOW.plusSeconds(-300.0), NOW))
        assertEquals("1d", RelativeTime.compact(90_000))
    }

    @Test
    fun paths() {
        assertEquals("~/projects/x", PathDisplay.abbreviatingHome("/Users/roy/projects/x"))
        assertEquals("~", PathDisplay.abbreviatingHome("/Users/roy"))
        assertEquals("/opt/x", PathDisplay.abbreviatingHome("/opt/x"))
    }

    @Test
    fun headlines() {
        val base = Intervention("x", "s", "", "p", InterventionKind.APPROVAL, NOW, "Bash command needs approval")
        assertEquals("Run this command?", ReplyCopy.headline(base))
        assertEquals(
            "Codex needs your input",
            ReplyCopy.headline(base.copy(kind = InterventionKind.USER_INPUT, context = "?", backend = InterventionBackend.CODEX)),
        )
        assertEquals("Approve the plan?", ReplyCopy.headline(iv("x", InterventionKind.APPROVAL, 0.0).copy(subtype = "plan")))
    }

    @Test
    fun deepLinks() {
        assertEquals("abc-123", DeepLink.interventionId("page://intervention/abc-123"))
        assertNull(DeepLink.interventionId("page://pair?x=1"))
        assertNull(DeepLink.interventionId("page://intervention/"))
    }

    @Test
    fun backoff() {
        assertEquals(0.5, ReconnectBackoff.delaySeconds(0, 0.0), 0.0)
        assertEquals(30.0, ReconnectBackoff.delaySeconds(10, 1.0), 0.0)
        assertEquals(6.0, ReconnectBackoff.delaySeconds(3, 0.5), 0.0)
    }

    @Test
    fun closeReasons() {
        for (r in listOf("hook_lost", "expired", "agent_exited", "too_late", "token_retired")) {
            assertNotEquals("$r has its own label", CloseReason.description(null), CloseReason.description(r))
            assertFalse("$r takes the reply screen's period", CloseReason.description(r).endsWith("."))
        }
        for (r in listOf("hook_lost", "expired", "agent_exited", "too_late")) {
            assertTrue(r in CloseReason.historyWorthy && CloseReason.isHistoryWorthy(r))
        }
        assertFalse("token_retired" in CloseReason.historyWorthy || CloseReason.isHistoryWorthy("token_retired"))
        for (r in listOf("stale", "superseded", "evicted")) assertFalse(CloseReason.isHistoryWorthy(r))
        assertTrue(CloseReason.historyWorthy.all(CloseReason::isHistoryWorthy))
        assertTrue(CloseReason.historyWorthy.intersect(CloseReason.hiddenFromHistory).isEmpty())
        assertTrue("unknown archived reasons still show", CloseReason.isHistoryWorthy("some_future_reason"))
        assertFalse(CloseReason.isHistoryWorthy(""))
        assertTrue(CloseReason.description("too_late").contains("too late"))
        assertFalse(CloseReason.description("too_late").lowercase().contains("answered"))
    }

    private val retiredBody = """{"error":"token_retired","why":"This pairing was replaced on your Mac — scan the new QR code"}"""

    @Test
    fun tokenRetirement() {
        assertEquals("This pairing was replaced on your Mac — scan the new QR code", TokenRetirement.why(410, retiredBody))
        assertEquals(TokenRetirement.DEFAULT_WHY, TokenRetirement.why(410, """{"error":"token_retired"}"""))
        assertEquals(TokenRetirement.DEFAULT_WHY, TokenRetirement.why(410, """{"error":"token_retired","why":"   "}"""))
        assertEquals(TokenRetirement.DEFAULT_WHY, TokenRetirement.why(410, """{"error":"token_retired","why":5}"""))
        assertNull("410 gone is a closed page", TokenRetirement.why(410, """{"error":"gone","why":"superseded"}"""))
        assertNull(TokenRetirement.why(410, ""))
        assertNull(TokenRetirement.why(410, "token_retired"))
        assertNull(TokenRetirement.why(401, retiredBody))
        assertNull(TokenRetirement.why(200, retiredBody))
        val long = "x".repeat(1000)
        val capped = TokenRetirement.why(410, """{"error":"token_retired","why":"$long"}""")!!
        assertTrue(capped.length <= TokenRetirement.MAX_WHY_LENGTH + 1)
        val empty = kotlinx.serialization.json.JsonObject(emptyMap())
        assertEquals(TokenRetirement.DEFAULT_WHY, TokenRetirement.whyFromFrame("relay.retired", empty))
        assertEquals("Replaced on Roy's Mac", TokenRetirement.whyFromFrame("relay.retired", parseJsonObject("""{"why":"Replaced on Roy's Mac"}""")!!))
        assertNull(TokenRetirement.whyFromFrame("intervention.closed", parseJsonObject("""{"why":"x"}""")!!))
        assertNull(TokenRetirement.whyFromFrame("mac.status", parseJsonObject("""{"reason":"token_retired"}""")!!))
        assertTrue(TokenRetirement.handshakeNeedsCheck(410) && TokenRetirement.handshakeNeedsCheck(401) && TokenRetirement.handshakeNeedsCheck(403))
        assertFalse(TokenRetirement.handshakeNeedsCheck(101) || TokenRetirement.handshakeNeedsCheck(404) || TokenRetirement.handshakeNeedsCheck(502))
        assertTrue(TokenRetirement.socketCloseNeedsCheck(4410, null))
        assertTrue(TokenRetirement.socketCloseNeedsCheck(1000, "token_retired"))
        assertFalse(TokenRetirement.socketCloseNeedsCheck(1001, null) || TokenRetirement.socketCloseNeedsCheck(1006, "bye"))
        assertEquals("Scan the new code.", TokenRetirement.sentence("Scan the new code"))
        assertEquals("Done.", TokenRetirement.sentence("Done."))
    }
}
