package app.page.android.ui

import app.page.android.model.GestureGuide
import app.page.android.model.LegacySkyMode
import app.page.android.model.NWDeepLink
import app.page.android.model.NWDestination
import app.page.android.model.NWTip
import app.page.android.model.MacPresence
import app.page.android.model.NotificationsState
import app.page.android.model.NowBanner
import app.page.android.model.nwNow
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lanes only: the second destination is Lanes, and nothing the user reads says Sky. Ported from "Lanes only (iOS):
 * no Sky left" in iOS/Tests/LogicTests.swift.
 */
class LanesOnlyTest {
    private fun saysSky(s: String) = Regex("(?<![A-Za-z])sky(?![A-Za-z])", RegexOption.IGNORE_CASE).containsMatchIn(s)

    @Test fun `the Sky word test tells the word from its neighbours`() {
        assertTrue(saysSky("Open Sky") && saysSky("sky") && saysSky("Goes to sky."))
        assertFalse(saysSky("page.skyMode") || saysSky("Skyline") || saysSky("skyTop"))
    }

    @Test fun `there are two destinations and every old Sky link lands on Lanes`() {
        assertEquals(listOf("now", "lanes"), NWDestination.entries.map { it.raw })
        for (link in listOf("page://lanes", "page://sky", "page://sessions")) assertEquals(link, NWDeepLink.Lanes, NWDeepLink.parse(link))
        assertEquals(NWDeepLink.Now, NWDeepLink.parse("page://now"))
        assertNull(NWDeepLink.parse("page://constellations"))
    }

    @Test fun `an old stored Sky mode is forgotten once, whatever it held, and nothing else is touched`() {
        var stored: String? = "sky"
        var clears = 0
        assertTrue(LegacySkyMode.forget({ stored }, { clears++; stored = null }))
        assertNull("the old value is gone", stored)
        assertEquals(1, clears)
        assertFalse("forgetting again is harmless and writes nothing", LegacySkyMode.forget({ stored }, { clears++ }))
        assertEquals(1, clears)
        stored = "lanes"
        assertTrue("an old Lanes value is forgotten the same way", LegacySkyMode.forget({ stored }, { stored = null }))
        assertEquals("the key is the old one, so the right preference is cleared", "page.skyMode", LegacySkyMode.storageKey)
    }

    @Test fun `no tip, shortcut or banner line says Sky`() {
        val copy = ArrayList<String>()
        copy += listOf(GestureGuide.title, GestureGuide.showAgainLabel)
        for (e in GestureGuide.entries + GestureGuide.shortcuts) copy += listOf(e.gesture, e.context, e.effect, e.tipText ?: "")
        copy += NWTip.entries.map { it.text("fingerprint") }
        val inputs = listOf(
            NowBanner.Inputs(true, null, true, MacPresence.Online(null), NotificationsState.ALLOWED, nwNow),
            NowBanner.Inputs(false, "timeout", false, MacPresence.Online(null), NotificationsState.ALLOWED, nwNow),
            NowBanner.Inputs(false, null, true, MacPresence.Offline(nwNow.minusSeconds(7200)), NotificationsState.OFF, nwNow),
        )
        for (i in inputs) for (b in NowBanner.build(i)) copy += listOf(b.title, b.message, b.actionTitle ?: "")
        assertTrue("the copy check reads the tips (${copy.size} lines)", copy.size > 20)
        assertTrue("no line says Sky: ${copy.filter(::saysSky)}", copy.none(::saysSky))
        assertTrue("a gesture tip names Lanes", GestureGuide.entries.any { "Lanes" in it.effect })
    }

    /** Every string literal in the app's Kotlin source, read with a small tokenizer (comments and char literals skipped). */
    private fun literals(src: String): List<String> {
        val out = ArrayList<String>()
        var i = 0
        while (i < src.length) {
            val c = src[i]
            when {
                src.startsWith("//", i) -> { while (i < src.length && src[i] != '\n') i++ }
                src.startsWith("/*", i) -> { val e = src.indexOf("*/", i + 2); i = if (e < 0) src.length else e + 2 }
                src.startsWith("\"\"\"", i) -> { val e = src.indexOf("\"\"\"", i + 3); out += src.substring(i + 3, if (e < 0) src.length else e); i = if (e < 0) src.length else e + 3 }
                c == '"' -> {
                    val sb = StringBuilder(); i++
                    while (i < src.length && src[i] != '"') { if (src[i] == '\\' && i + 1 < src.length) { sb.append(src[i + 1]); i += 2 } else { sb.append(src[i]); i++ } }
                    out += sb.toString(); i++
                }
                c == '\'' -> { i++; if (i < src.length && src[i] == '\\') i++; i += 2 }
                else -> i++
            }
        }
        return out
    }

    @Test fun `no string in the app source or its resources says Sky except the route key and the old link`() {
        val root = listOf(File("src/main"), File("app/src/main")).firstOrNull { it.isDirectory }
        assertNotNull("the unit tests run from the app module", root)
        val kt = root!!.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()
        assertTrue("the scan reads the app's sources (${kt.size} files)", kt.size > 100)
        val allowed = setOf("sky", "page://sky")
        val bad = ArrayList<String>()
        for (f in kt) for (lit in literals(f.readText())) if (saysSky(lit) && lit !in allowed) bad += "${f.name}: ${lit.take(80)}"
        assertTrue("user-facing strings that say Sky: $bad", bad.isEmpty())
        val values = File(root, "res/values").listFiles()?.filter { it.extension == "xml" }.orEmpty()
        assertTrue("no resource string says Sky: ${values.filter { saysSky(it.readText()) }}", values.none { saysSky(it.readText()) })
    }
}
