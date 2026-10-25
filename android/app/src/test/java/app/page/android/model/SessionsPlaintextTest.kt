package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionsPlaintextTest {
    private fun decode(s: String) = SessionsPlaintext.decode(s)

    @Test
    fun specVectorListDecodes() {
        val p = decode("""{"kind":"list","seq":1,"ts":1761300000000,"sessions":[]}""")!!
        assertTrue(p.seq == 1L && p.boot == "" && p.ts == CMD_NOW)
        assertEquals(SessionsUpdate.ListUpdate(null, emptyList()), p.update)
    }

    private val listJson = """
        {"kind":"list","boot":"b1","seq":12,"ts":1761300000000,"macName":"Roy's MacBook","futureField":{"x":1},
         "sessions":[
          {"id":"s-claude","backend":"claude","title":"mac-on-claude-code","cwd":"~/projects/mac-on-claude-code","state":"waitingOnApproval","host":"cmux","canType":true,"typeBlocker":"ignored when typable","canInterrupt":true,"provider":"anthropic","lastActivityAt":"2026-10-24T12:00:00Z","interventionId":"iv-1","preview":"Bash: npm test"},
          {"id":"s-ollama","backend":"ollama","cwd":"~/code/llm-play","state":"thinkingHard","host":"Ghostty","canType":false,"typeBlocker":"Page can't type into Ghostty yet","canInterrupt":"yes","lastActivityAt":"bad"},
          {"id":"s-min"},
          {"id":""},
          {"title":"no id"},
          {"id":"s-codex","backend":"CODEX","title":5,"cwd":"~","state":"active","canType":true,"canInterrupt":false,"lastActivityAt":"2026-10-24T11:00:00.123Z","interventionId":""}
         ]}
    """.trimIndent()

    @Test
    fun listDecodesLeniently() {
        val p = decode(listJson)!!
        val u = p.update as SessionsUpdate.ListUpdate
        assertTrue(p.boot == "b1" && p.seq == 12L)
        assertEquals("Roy's MacBook", u.macName)
        val ss = u.sessions
        assertEquals(listOf("s-claude", "s-ollama", "s-min", "s-codex"), ss.map { it.id })
        val (a, b, m, x) = ss
        assertTrue(a.backend == AgentBackend.Known(InterventionBackend.CLAUDE) && a.state == LiveSessionState.WAITING_ON_APPROVAL && a.canType && a.typeBlocker == null)
        assertTrue(a.openPageId == "iv-1" && a.lastActivityAt == PageDate.parse("2026-10-24T12:00:00Z") && a.preview == "Bash: npm test")
        assertTrue(b.backend == AgentBackend.Other("ollama") && b.backend.badge == "OLLAMA" && b.backend.displayName == "Ollama")
        assertTrue("unknown state grouped idle", b.state == LiveSessionState.UNKNOWN && b.state.group == SessionGroup.IDLE)
        assertEquals("title from cwd", "llm-play", b.title)
        assertTrue(!b.canType && b.blockerText == "Page can't type into Ghostty yet")
        assertTrue("non-bool canInterrupt -> false", !b.canInterrupt && !b.isStoppable)
        assertNull("bad date tolerated", b.lastActivityAt)
        assertTrue(m.title == "Session s-min" && !m.canType && m.blockerText == LiveSession.DEFAULT_BLOCKER && m.host == "unknown" && m.hostLabel == "Unknown host")
        assertTrue(m.backend == AgentBackend.Other("unknown") && m.backend.displayName == "Your agent")
        assertTrue(x.backend == AgentBackend.Known(InterventionBackend.CODEX) && x.title == "Session s-codex" && x.interventionId == null)
        assertTrue(!x.isStoppable && x.state == LiveSessionState.ACTIVE)
    }

    @Test
    fun malformedFramesAreIgnored() {
        assertNull("list without sessions is malformed, not empty", decode("""{"kind":"list","seq":1,"ts":1761300000000}"""))
        assertNull("unknown kind ignored", decode("""{"kind":"sparkles","seq":1,"ts":1761300000000}"""))
        assertNull("future kind ignored", decode("""{"kind":"hologram","seq":1,"ts":1761300000000,"sessionId":"s"}"""))
        assertNull(decode("""{"kind":"list","ts":1761300000000,"sessions":[]}"""))
        assertNull(decode("""{"kind":"list","seq":1,"sessions":[]}"""))
        assertNull("seq must be a number", decode("""{"kind":"list","seq":"1","ts":1761300000000,"sessions":[]}"""))
        assertNull(decode("not json"))
        val many = "{\"kind\":\"list\",\"seq\":1,\"ts\":1761300000000,\"sessions\":[" + (0 until 150).joinToString(",") { "{\"id\":\"s$it\"}" } + "]}"
        assertEquals(100, (decode(many)!!.update as SessionsUpdate.ListUpdate).sessions.size)
    }

    @Test
    fun transcripts() {
        val json = """
            {"kind":"transcript","boot":"b1","seq":13,"ts":1761300000000,"sessionId":"s-claude","truncated":true,
             "entries":[{"id":"u1","role":"user","text":"run the tests","at":"2026-10-24T12:00:00Z"},
                        {"id":42,"role":"tool","text":"Bash: npm test","tool":"Bash"},
                        {"id":"a1","role":"assistant","text":"All green."},
                        {"id":"x1","role":"narrator","text":"odd role"},
                        {"role":"user","text":"no id"}]}
        """.trimIndent()
        val t = (decode(json)!!.update as SessionsUpdate.Transcript).transcript
        assertTrue(t.sessionId == "s-claude" && t.truncated)
        assertEquals(listOf("u1", "42", "a1", "x1"), t.entries.map { it.id })
        assertTrue(t.entries[0].role == TranscriptRole.USER && t.entries[0].at != null)
        assertTrue(t.entries[1].role == TranscriptRole.TOOL && t.entries[1].tool == "Bash")
        assertEquals("unknown role -> system, never user", TranscriptRole.SYSTEM, t.entries[3].role)
        assertNull(decode("""{"kind":"transcript","seq":1,"ts":1761300000000,"entries":[]}"""))
        val agent = (decode("""{"kind":"transcript","seq":21,"ts":1761300000000,"sessionId":"S","runId":"wf_1","agentId":"a1","entries":[]}""")!!.update as SessionsUpdate.Transcript).transcript
        assertTrue(agent.key == "S|wf_1|a1" && agent.runId == "wf_1")
    }

    @Test
    fun results() {
        val r = (decode("""{"kind":"result","boot":"b1","seq":14,"ts":1761300000000,"clientId":"c1","ok":false,"code":"refused","reason":"waiting","detail":"Answer the prompt","interventionId":"iv-1"}""")!!.update as SessionsUpdate.Result).result
        assertEquals(CommandResult("c1", false, CommandResult.Code.REFUSED, "waiting", "Answer the prompt", "iv-1"), r)
        val unknown = (decode("""{"kind":"result","seq":1,"ts":1761300000000,"clientId":"c2","ok":true,"code":"teleported"}""")!!.update as SessionsUpdate.Result).result
        assertEquals(CommandResult.Code.DELIVERED, unknown.code)
        assertNull(decode("""{"kind":"result","seq":1,"ts":1761300000000,"ok":true}"""))
    }

    @Test
    fun screens() {
        val sc = (decode("""{"kind":"screen","seq":3,"ts":1761300000000,"sessionId":"S","lines":["❯ hi","  ○ wf 11/23"]}""")!!.update as SessionsUpdate.Screen).screen
        assertTrue(sc.sessionId == "S" && sc.lines == listOf("❯ hi", "  ○ wf 11/23"))
        assertNull(decode("""{"kind":"screen","seq":3,"ts":1761300000000,"lines":["x"]}"""))
        assertNull(decode("""{"kind":"screen","seq":3,"ts":1761300000000,"sessionId":"S"}"""))
        assertNull("a non-string line makes the frame malformed", decode("""{"kind":"screen","seq":3,"ts":1761300000000,"sessionId":"S","lines":["x",5]}"""))
        val long = "{\"kind\":\"screen\",\"seq\":3,\"ts\":1761300000000,\"sessionId\":\"S\",\"lines\":[" +
            (0 until 200).joinToString(",") { "\"${"a".repeat(500)}$it\"" } + "]}"
        val capped = (decode(long)!!.update as SessionsUpdate.Screen).screen
        assertTrue(capped.lines.size == SessionScreen.MAX_LINES && capped.lines.all { it.length <= SessionScreen.MAX_LINE_CHARS })
    }

    private val wfJson = """{"kind":"workflows","seq":20,"ts":1761300000000,"sessionId":"S","runs":[{"id":"wf_1","name":"design-pass-ch1-8-opus","status":"running","phase":"Fix B","done":28,"total":30,"startedAt":1761290000000,"endedAt":null,"tokens":null,"agents":[{"id":"a1","label":"ch5: fix","phase":"Fix B","state":"running","lastActivityAt":1761299990000},{"label":"no id"}]},{"id":"wf_2","name":"finish-act-opus","status":"running","done":0,"total":1},{"id":"wf_3","name":"finish-act-opus","status":"running","done":0,"total":1},{"name":"no id"}]}"""

    @Test
    fun workflowsAndTerminalLinks() {
        val u = decode(wfJson)!!.update as SessionsUpdate.Workflows
        val runs = u.runs
        assertTrue(u.sessionId == "S" && runs.map { it.id } == listOf("wf_1", "wf_2", "wf_3"))
        assertTrue(runs[0].agents.map { it.id } == listOf("a1") && runs[0].agents[0].running)
        assertTrue(runs[0].progress(at(1_761_300_000.0)).startsWith("28/30 · 2h46m"))
        val footer = listOf("  ○ design-pass-ch1-8-opus      28/30 · 2h34m", "  ○ finish-act-opus   0/1", "  ○ finish-act-opus   0/1", "plain text design-pass-ch1-8-opus", "  ○ design-pass-ch1-8-opus-extra")
        val links = TerminalRunLinks.match(footer, runs)
        assertTrue(links[0]?.id == "wf_1" && links[1]?.id == "wf_2" && links[2]?.id == "wf_3")
        assertTrue("only footer-style rows, whole names", links[3] == null && links[4] == null)
        val chatty = listOf("● design-pass-ch1-8-opus is going well", "  ○ design-pass-ch1-8-opus      28/30")
        val l2 = TerminalRunLinks.match(chatty, runs)
        assertTrue("the footer row (bottom) takes the run", l2[1]?.id == "wf_1" && l2[0] == null)

        val killed = decode("""{"kind":"workflows","seq":22,"ts":1761300000000,"sessionId":"S","runs":[{"id":"wf_k","name":"k","status":"killed","done":1,"total":3,"agents":[{"id":"a1","label":"x","state":"failed"},{"id":"a2","label":"y","state":"stopped"},{"id":"a3","label":"z","state":"done"},{"id":"a4","label":"w"}]}]}""")!!.update as SessionsUpdate.Workflows
        assertFalse(killed.runs[0].agents.any { it.running })
        assertEquals(listOf("failed", "stopped", "done", "done"), killed.runs[0].agents.map { it.state })
        assertTrue(WorkflowRun.duration(45.0) == "45s" && WorkflowRun.duration(23 * 60.0 + 8) == "23m" && WorkflowRun.duration(9240.0) == "2h34m")
        assertTrue(WorkflowRun.tokens(6_300_000) == "6.3m tokens" && WorkflowRun.tokens(985_100) == "985.1k tokens")
    }

    @Test
    fun disabledFlag() {
        assertTrue(decode("""{"kind":"list","seq":5,"ts":1761300000000,"boot":"b","sessions":[],"disabled":true}""")!!.macDisabled)
        assertFalse(decode("""{"kind":"list","seq":6,"ts":1761300000000,"boot":"b","sessions":[]}""")!!.macDisabled)
    }

    private fun pt(update: SessionsUpdate, boot: String = "b1", seq: Long, age: Double = 0.0) =
        SessionsPlaintext(boot, seq, CMD_NOW.plusSeconds(-age), update)

    @Test
    fun seqGating() {
        val emptyList = SessionsUpdate.ListUpdate(null, emptyList())
        val g = SessionUpdateGate()
        val A = SessionUpdateGate.Verdict.ACCEPT
        val OLD = SessionUpdateGate.Verdict.TOO_OLD
        val OOO = SessionUpdateGate.Verdict.OUT_OF_ORDER
        assertEquals(A, g.admit(pt(emptyList, seq = 5), CMD_NOW))
        assertEquals(OOO, g.admit(pt(emptyList, seq = 5), CMD_NOW))
        assertEquals(OOO, g.admit(pt(emptyList, seq = 4), CMD_NOW))
        assertEquals(A, g.admit(pt(emptyList, seq = 6), CMD_NOW))
        assertEquals(OLD, g.admit(pt(emptyList, seq = 7, age = 601.0), CMD_NOW))
        assertEquals(A, g.admit(pt(emptyList, seq = 7, age = 599.0), CMD_NOW))
        assertEquals("Mac clock ahead is not a replay", A, g.admit(pt(emptyList, seq = 99, age = -3600.0), CMD_NOW))
        assertEquals(OLD, g.admit(pt(emptyList, boot = "b2", seq = 900, age = 700.0), CMD_NOW))
        assertEquals("stale frame from a new boot doesn't reset tracking", "b1", g.boot)
        assertEquals(A, g.admit(pt(emptyList, boot = "b2", seq = 1), CMD_NOW))
        assertEquals("b2", g.boot)
        assertEquals(A, g.admit(pt(emptyList, boot = "b2", seq = 2), CMD_NOW))

        val tA = SessionsUpdate.Transcript(SessionTranscript("A", emptyList(), false))
        val tB = SessionsUpdate.Transcript(SessionTranscript("B", emptyList(), false))
        assertEquals(A, g.admit(pt(tA, boot = "b2", seq = 10), CMD_NOW))
        assertEquals("transcripts tracked per session", A, g.admit(pt(tB, boot = "b2", seq = 8), CMD_NOW))
        assertEquals(OOO, g.admit(pt(tA, boot = "b2", seq = 9), CMD_NOW))
        assertEquals("list seq independent of transcripts", A, g.admit(pt(emptyList, boot = "b2", seq = 3), CMD_NOW))
        val res = SessionsUpdate.Result(CommandResult("c", true, CommandResult.Code.DELIVERED, null, null, null))
        assertEquals("results aren't seq-gated", A, g.admit(pt(res, boot = "b2", seq = 1), CMD_NOW))
        assertEquals("results are age-gated", OLD, g.admit(pt(res, boot = "b2", seq = 1, age = 1200.0), CMD_NOW))
        assertEquals(A, g.admit(pt(tA, boot = "b3", seq = 1), CMD_NOW))

        val scrA = SessionsUpdate.Screen(SessionScreen("A", listOf("x"), CMD_NOW))
        assertEquals("screen independent of transcript", A, g.admit(pt(scrA, boot = "b3", seq = 1), CMD_NOW))
        assertEquals(OOO, g.admit(pt(scrA, boot = "b3", seq = 1), CMD_NOW))
        assertEquals(A, g.admit(pt(scrA, boot = "b3", seq = 2), CMD_NOW))

        val agentT = SessionsUpdate.Transcript(SessionTranscript("S", emptyList(), false, "wf_1", "a1"))
        val sessionT = SessionsUpdate.Transcript(SessionTranscript("S", emptyList(), false))
        assertEquals(A, g.admit(pt(agentT, boot = "b3", seq = 30), CMD_NOW))
        assertEquals("agent and session transcripts have separate seq", A, g.admit(pt(sessionT, boot = "b3", seq = 29), CMD_NOW))

        val wf = SessionsUpdate.Workflows("S", emptyList())
        assertEquals(A, g.admit(pt(wf, boot = "b3", seq = 40), CMD_NOW))
        assertEquals(OOO, g.admit(pt(wf, boot = "b3", seq = 40), CMD_NOW))

        g.reset()
        assertTrue(g.boot == null && g.lastListSeq == null)
        assertEquals(A, g.admit(pt(emptyList, boot = "b3", seq = 1), CMD_NOW))
    }
}
