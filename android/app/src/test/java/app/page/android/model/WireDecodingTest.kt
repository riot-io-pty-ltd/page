package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WireDecodingTest {
    @Test
    fun datesAcceptEveryProducersFormat() {
        assertNotNull(PageDate.parse("2026-10-24T01:02:03.456Z"))
        assertNotNull(PageDate.parse("2026-10-24T01:02:03Z"))
        assertEquals(PageDate.parse("2026-10-24T01:02:03Z"), PageDate.parse("2026-10-24T11:02:03+10:00"))
        assertNull(PageDate.parse("garbage"))
        assertEquals(at(1_700_000_000.0), PageDate.parseAny(kotlinx.serialization.json.JsonPrimitive(1_700_000_000_000.0)))
        assertEquals(at(1_700_000_000.0), PageDate.parseAny(kotlinx.serialization.json.JsonPrimitive(1_700_000_000)))
    }

    private val lossyJson = """
        [
         {"id":"a","sessionId":"s1","cwd":"/Users/x/p","projectName":"p","kind":"permission","openedAt":"2026-10-24T01:02:03.456Z","context":"Bash: ls"},
         {"id":"b","sessionId":"s2","kind":"weird_new_kind","openedAt":"2026-10-24T01:02:04Z","context":5,"backend":"gemini","source":"phone"},
         {"id":"c","kind":"question","openedAt":"2026-10-24T01:02:04Z"},
         {"id":"d","sessionId":"s4","kind":"idle","openedAt":"not a date"},
         null,
         {"id":"e","sessionId":"s5","kind":"question","openedAt":"2026-10-24T01:02:05Z","closedAt":"bad","deliveryStatus":"failed","deliveryDetail":"nope","cwd":"/Users/me/code/thing"}
        ]
    """.trimIndent()

    @Test
    fun lossyListDropsOnlyTheBadPages() {
        val lossy = Intervention.decodeList(lossyJson)!!
        assertEquals(listOf("a", "b", "e"), lossy.elements.map { it.id })
        assertEquals(3, lossy.droppedCount)
        assertEquals(InterventionKind.APPROVAL, lossy.elements[0].kind)
        assertEquals("unknown kind -> user input", InterventionKind.USER_INPUT, lossy.elements[1].kind)
        assertEquals("non-string context defaults", "", lossy.elements[1].context)
        assertNull("unknown backend", lossy.elements[1].backend)
        assertEquals(InterventionSource.UNKNOWN, lossy.elements[1].source)
        assertEquals("Unknown project", lossy.elements[1].projectName)
        assertEquals("project from cwd", "thing", lossy.elements[2].projectName)
        assertNull("bad optional date tolerated", lossy.elements[2].closedAt)
        assertEquals("failed", lossy.elements[2].deliveryStatus)
        assertNull("not an array", Intervention.decodeList("""{"error":"x"}"""))
    }

    @Test
    fun urgencyOrdering() {
        val sorted = Intervention.urgencySorted(
            listOf(
                iv("i1", InterventionKind.IDLE, 100.0), iv("q1", InterventionKind.USER_INPUT, 50.0),
                iv("a1", InterventionKind.APPROVAL, 10.0), iv("a2", InterventionKind.APPROVAL, 20.0),
                iv("r", InterventionKind.RATE_LIMIT, 999.0),
            )
        )
        assertEquals(listOf("a2", "a1", "q1", "i1", "r"), sorted.map { it.id })
    }

    @Test
    fun blockingHookPages() {
        val hb = Intervention.decode(parseJson("""{"id":"hook-1","sessionId":"s","kind":"permission","openedAt":"2026-10-24T01:02:03Z","hookBlocking":true}""")!!)!!
        assertTrue(hb.hookBlocking == true && hb.isBlockingHook && hb.acceptsDecisionsOnly)
        val hbBad = Intervention.decode(parseJson("""{"id":"hook-2","sessionId":"s","kind":"permission","openedAt":"2026-10-24T01:02:03Z","hookBlocking":"yes"}""")!!)!!
        assertTrue("malformed hookBlocking ignored", hbBad.hookBlocking == null && !hbBad.acceptsDecisionsOnly)
        val hp = Intervention.decode(parseJson("""{"id":"hookpre-1","sessionId":"s","kind":"question","openedAt":"2026-10-24T01:02:03Z"}""")!!)!!
        assertTrue("v2 hookpre pages keep text replies", hp.isBlockingHook && !hp.acceptsDecisionsOnly)
        val ordinary = Intervention.decodeList(lossyJson)!!.elements[0]
        assertFalse(ordinary.acceptsDecisionsOnly || ordinary.isBlockingHook)
    }

    @Test
    fun numericStringsAreNotNumbersAndStringBoolsAreNotBools() {
        val o = parseJsonObject("""{"n":"5","b":"true","realN":5,"realB":true,"nul":null}""")!!
        assertNull(o.num("n"))
        assertNull(o.bool("b"))
        assertEquals(5.0, o.num("realN")!!, 0.0)
        assertEquals(true, o.bool("realB"))
        assertNull(o.str("realN"))
        assertNull(o.str("nul"))
        assertNull(o.num("realB"))
    }

    @Test
    fun graphemesAndCaps() {
        assertEquals(1, "👨‍👩‍👧‍👦".graphemeCount())
        assertEquals("ab", "abc".capped(2))
        // Never split a surrogate pair.
        assertEquals("a", "a😀".capped(2))
    }
}
