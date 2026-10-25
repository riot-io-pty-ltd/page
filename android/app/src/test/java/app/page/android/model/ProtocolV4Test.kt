package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Protocol v4: stuck and forecast pages, turn summaries, diff/folders/start, heartbeat forecasts. */
class ProtocolV4Test {
    private fun page(kind: String, subtype: String?, context: String = "", backend: String = "claude"): Intervention {
        val sub = subtype?.let { ""","subtype":"$it"""" } ?: ""
        val ctx = PageJson.encodeToString(kotlinx.serialization.json.JsonPrimitive.serializer(), kotlinx.serialization.json.JsonPrimitive(context))
        return Intervention.decode(parseJson("""{"id":"x","sessionId":"s","kind":"$kind","openedAt":"2026-10-25T12:00:00Z","backend":"$backend","context":$ctx$sub}""")!!)!!
    }

    @Test
    fun stuckPages() {
        val looping = page("idle", "looping")
        assertEquals("LOOKS STUCK", looping.chipLabel())
        assertEquals("Claude looks stuck", ReplyCopy.headline(looping))
        assertTrue(PageSubtype.isStuck(looping.kind, looping.subtype) && PageSubtype.canStop(looping.kind, looping.subtype))
        val stalled = page("idle", "workflow_stalled")
        assertEquals("WORKFLOW STALLED", stalled.chipLabel())
        assertEquals("Claude looks stuck", ReplyCopy.headline(stalled))
        assertFalse("no Stop for a stalled workflow", PageSubtype.canStop(stalled.kind, stalled.subtype))
        assertEquals("Claude is waiting for you", ReplyCopy.headline(page("idle", "low_battery")))
        // A stuck subtype on another kind means nothing.
        assertFalse(PageSubtype.isStuck(InterventionKind.APPROVAL, "stuck"))
        assertEquals("IDLE", page("idle", "something_new").chipLabel())
    }

    @Test
    fun forecastPages() {
        val battery = page("rate_limit", "battery_forecast")
        assertEquals("Battery cutoff soon", ReplyCopy.headline(battery))
        assertTrue(PageSubtype.isForecast(battery.kind, battery.subtype))
        assertEquals("Claude limit soon", ReplyCopy.headline(page("rate_limit", "usage_forecast")))
        val plain = page("rate_limit", null)
        assertEquals("Rate limit reached", ReplyCopy.headline(plain))
        assertFalse(PageSubtype.isForecast(plain.kind, plain.subtype))
    }

    @Test
    fun turnSummaryLine() {
        val s = TurnSummaryLine.split(InterventionKind.IDLE, "Changed 3 files (+120 −14) · tests passed\n\nAll done. Next?")
        assertEquals("Changed 3 files (+120 −14) · tests passed", s.summary)
        assertEquals("All done. Next?", s.message)
        assertEquals("tests failed", TurnSummaryLine.split(InterventionKind.IDLE, "tests failed\n\nHelp").summary)
        assertNull("ordinary text", TurnSummaryLine.split(InterventionKind.IDLE, "Finished.\n\nWaiting.").summary)
        assertNull("a message that happens to start with Changed", TurnSummaryLine.split(InterventionKind.IDLE, "Changed my mind about X\n\nOK?").summary)
        assertNull("no blank line", TurnSummaryLine.split(InterventionKind.IDLE, "Changed 2 files").summary)
        assertEquals("Changed 1 file", TurnSummaryLine.split(InterventionKind.IDLE, "Changed 1 file\n\nDone").summary)
        assertNull("only idle pages", TurnSummaryLine.split(InterventionKind.APPROVAL, "Changed 1 file\n\nx").summary)
        assertEquals("summary only", "", TurnSummaryLine.split(InterventionKind.IDLE, "Changed 1 file\n\n").message)
    }

    @Test
    fun diffDecodesLeniently() {
        val json = """{"kind":"diff","seq":16,"ts":1761300000000,"sessionId":"S","clientId":"c9","scope":"turn","repo":"page",
            "files":[{"path":"Sources/a.swift","added":12,"removed":3,"status":"modified"},{"path":"docs/new.md","added":40,"removed":0,"status":"added"},
                     {"path":"notes.txt","status":"changed"},{"status":"modified"},{"path":"x","added":"7"}],
            "patch":"diff --git a/Sources/a.swift b/Sources/a.swift\n--- a/Sources/a.swift\n+++ b/Sources/a.swift\n@@ -1,2 +1,2 @@\n-old\n+new\n same\n","truncated":false,"future":1}"""
        val d = (SessionsPlaintext.decode(json)!!.update as SessionsUpdate.Diff).diff
        assertEquals(listOf("Sources/a.swift", "docs/new.md", "notes.txt", "x"), d.files.map { it.path })
        assertNull("string counts ignored", d.files[3].added)
        assertEquals(52, d.added)
        assertEquals(3, d.removed)
        assertEquals("This turn", d.scopeLabel)
        assertEquals("c9", d.clientId)
        val sections = PatchParser.sections(d.patch)
        assertEquals(1, sections.size)
        assertEquals("Sources/a.swift", sections[0].path)
        val kinds = sections[0].lines.map { it.kind }
        assertEquals(
            listOf(PatchParser.LineKind.FILE_HEADER, PatchParser.LineKind.META, PatchParser.LineKind.META, PatchParser.LineKind.HUNK,
                PatchParser.LineKind.REMOVED, PatchParser.LineKind.ADDED, PatchParser.LineKind.CONTEXT),
            kinds,
        )
        val empty = (SessionsPlaintext.decode("""{"kind":"diff","seq":1,"ts":1761300000000,"sessionId":"S","scope":"uncommitted","note":"Not a git repository"}""")!!.update as SessionsUpdate.Diff).diff
        assertTrue(empty.files.isEmpty() && empty.patch.isEmpty() && empty.note == "Not a git repository" && empty.scopeLabel == "Uncommitted changes")
        assertNull("diff needs a session", SessionsPlaintext.decode("""{"kind":"diff","seq":1,"ts":1761300000000}"""))
    }

    @Test
    fun foldersDecodeNewestFirst() {
        val json = """{"kind":"folders","seq":17,"ts":1761300000000,"clientId":"c1","enabled":true,"agents":["claude",5],
            "folders":[{"path":"/Users/me/old","name":"old","lastUsedAt":1761200000000},{"path":"/Users/me/projects/page","name":"page","lastUsedAt":1761290000000},{"name":"no path"}]}"""
        val f = (SessionsPlaintext.decode(json)!!.update as SessionsUpdate.Folders).folders
        assertTrue(f.enabled && f.agents == listOf("claude") && f.clientId == "c1")
        assertEquals(listOf("page", "old"), f.folders.map { it.name })
        val off = (SessionsPlaintext.decode("""{"kind":"folders","seq":1,"ts":1761300000000,"enabled":false,"folders":[{"path":"/x"}]}""")!!.update as SessionsUpdate.Folders).folders
        assertTrue("off means no folders", !off.enabled && off.folders.isEmpty())
    }

    @Test
    fun answersAreAgeGatedNotSeqGated() {
        val g = SessionUpdateGate()
        val d = SessionsUpdate.Diff(SessionDiff("S", "c", "turn", null, emptyList(), "", false, null))
        assertEquals(SessionUpdateGate.Verdict.ACCEPT, g.admit(SessionsPlaintext("b", 5, CMD_NOW, d), CMD_NOW))
        assertEquals(SessionUpdateGate.Verdict.ACCEPT, g.admit(SessionsPlaintext("b", 5, CMD_NOW, d), CMD_NOW))
        assertEquals(SessionUpdateGate.Verdict.TOO_OLD, g.admit(SessionsPlaintext("b", 6, CMD_NOW.plusSeconds(-700.0), d), CMD_NOW))
    }

    @Test
    fun newOps() {
        val diff = parseJsonObject(SessionCommand.Diff("S").plaintext("c", "v", CMD_NOW).toString(Charsets.UTF_8))!!
        assertTrue(diff.str("op") == "diff" && diff.str("sessionId") == "S")
        val folders = parseJsonObject(SessionCommand.Folders.plaintext("c", "v", CMD_NOW).toString(Charsets.UTF_8))!!
        assertTrue(folders.str("op") == "folders" && folders["sessionId"] == null)
        val start = parseJsonObject(SessionCommand.Start("/Users/me/p", "fix the tests").plaintext("c", "v", CMD_NOW).toString(Charsets.UTF_8))!!
        assertTrue(start.str("op") == "start" && start.str("folder") == "/Users/me/p" && start.str("text") == "fix the tests")
        assertNull(StartPrompt.problem(""))
        assertNull(StartPrompt.problem("a".repeat(4000)))
        assertTrue(StartPrompt.problem("a".repeat(4001)) != null)
    }

    @Test
    fun heartbeatForecastAndUsage() {
        val hb = parseJsonObject(
            """{"ts":"2026-10-25T12:00:00Z","activeSessions":4,"battery":42,"onAC":false,"working":2,
               "forecast":{"cutoff":10,"minutes":35,"drainPerHour":55},
               "usage":{"fiveHour":{"pct":62,"resetsAt":"2026-10-25T17:00:00Z"},"sevenDay":{"pct":"high"},"hitAt":"2026-10-25T16:10:00Z"}}"""
        )!!
        val now = PageDate.parse("2026-10-25T12:00:10Z")!!
        val s = MacStatusSnapshot.applyingHeartbeat(MacStatusSnapshot(macConnected = true), hb, now, statusEndpointKnown = true)
        assertEquals(2, s.working)
        assertEquals(BatteryForecast(10, 35, 55.0), s.forecast)
        assertEquals(62.0, s.usage!!.fiveHour!!.pct, 0.0)
        assertNull("malformed window dropped", s.usage!!.sevenDay)
        // Usage is the usage card now, not a strip line.
        val lines = MacStatusStrip.lines(s, MacPresence.evaluate(s, now), now)
        assertEquals(listOf("Mac online · 2 working", "Battery 42% · cutoff in ~35 min"), lines.map { it.text })
        val card = UsageCardModel.from(s.usage, now)!!
        assertEquals("5-hour", card.fiveHour?.label)
        assertNull(card.sevenDay)
        assertEquals("Resets in 4h 59m", card.fiveHour?.resetLine(now))
        assertEquals(UsageCardModel.Verdict("At this pace you'll hit the 5-hour limit around 4:10 PM", true), card.verdict { "4:10 PM" })
        // Next heartbeat on power: no forecast; bad shapes are dropped, not trusted.
        val onAC = parseJsonObject("""{"ts":"2026-10-25T12:00:25Z","activeSessions":1,"battery":90,"onAC":true,"working":"two","usage":{"fiveHour":{"pct":"x"}}}""")!!
        val s2 = MacStatusSnapshot.applyingHeartbeat(s, onAC, now, true)
        assertTrue(s2.forecast == null && s2.usage == null && s2.working == null)
        assertEquals(listOf("Mac online"), MacStatusStrip.lines(s2, MacPresence.evaluate(s2, now), now).map { it.text })
        // /status carries them too.
        val st = MacStatusSnapshot.from(parseJsonObject("""{"macConnected":false,"forecast":{"cutoff":10,"minutes":12,"drainPerHour":40},"usage":{"sevenDay":{"pct":80}}}""")!!)
        assertEquals(12, st.forecast?.minutes)
        assertEquals(80.0, st.usage?.sevenDay?.pct ?: 0.0, 0.0)
        assertEquals(listOf("Mac offline"), MacStatusStrip.lines(st, MacPresence.evaluate(st, now), now).map { it.text })
        assertEquals("1 h 20 min", MacStatusStrip.duration(80))
        assertEquals("2 h", MacStatusStrip.duration(120))
    }
}
