package app.page.android.model

import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import kotlin.math.abs

/**
 * In-flight cards, the optional list fields a Mac may or may not send, the step wording, the clocks, the health
 * words, the project fallback, and the Mac's golden wire rows, ported from the "In flight cards" and "golden wire
 * rows" checks in iOS/Tests/LogicTests.swift. Every field is optional on the wire: an older Mac's row decodes and
 * the card still has words.
 */
class InFlightWireTest {
    private val nowT0 = NW_T0
    private val goldenNow: Instant = at(1_790_000_000.0)

    private val baseRow = """{"id":"s1","backend":"claude","title":"page","cwd":"~/projects/page","state":"active",
        "host":"cmux","canType":true,"canInterrupt":true,"preview":"[Bash] swift test","lastActivityAt":"${nwISOAt(nowT0 - 20)}"}"""

    private fun nwISOAt(seconds: Double): String = at(seconds).toString()

    /** A list row: the base fields with [extra] (a JSON object body, without braces) merged over them. */
    private fun row(extra: String = "", preview: String? = null): LiveSession {
        val base = parseJsonObject(baseRow)!!
        val more = parseJsonObject("{$extra}") ?: JsonObject(emptyMap())
        val merged = LinkedHashMap<String, kotlinx.serialization.json.JsonElement>(base)
        merged.putAll(more)
        if (preview != null) merged["preview"] = kotlinx.serialization.json.JsonPrimitive(preview)
        return LiveSession.decode(JsonObject(merged))!!
    }

    /** The Mac's golden row (the same literals as the Mac's InFlightCoverageTests), with the list fields merged in. */
    private fun golden(extra: String, preview: String = "Bash: swift test", drop: Set<String> = emptySet()): LiveSession {
        val base = parseJsonObject(
            """{"id":"s1","backend":"claude","title":"page","cwd":"/Users/roy/projects/page","state":"active","host":"cmux",
            "canType":true,"canInterrupt":true,"preview":"$preview","lastActivityAt":"2026-09-21T14:13:00Z"}""",
        )!!
        val merged = LinkedHashMap<String, kotlinx.serialization.json.JsonElement>(base)
        merged.putAll(parseJsonObject("{$extra}") ?: JsonObject(emptyMap()))
        for (k in drop) merged.remove(k)
        return LiveSession.decode(JsonObject(merged))!!
    }

    private val goldenStuck = """"busySince":"2026-09-21T14:01:20Z","health":"stuck","healthDetail":"no progress for 15 min",
        "model":"Opus 4.7","recentSteps":["Running swift test"],"startedAt":"2026-09-21T12:03:20Z""""
    private val goldenRateLimited = """"busySince":"2026-09-21T14:01:20Z","health":"rateLimited",
        "recentSteps":["Reading Package.swift"],"resetsAt":"2026-09-21T14:28:20Z""""
    private val goldenLongRunning = """"busySince":"2026-09-21T14:01:20Z","health":"longRunning",
        "recentSteps":["Running make all"],"stepSince":"2026-09-21T14:06:40Z""""
    private val goldenSixWorkflows = """"workflows":[{"done":3,"name":"Review changes","phase":"Reviewing","running":2,"total":5},
        {"done":1,"name":"Lint","running":1,"total":2},{"done":0,"name":"Docs","running":0,"total":4}],"workflowsRunning":6"""

    // MARK: an older Mac

    @Test fun `an older Mac's row carries no flight detail and the card still has words and the last-active time`() {
        val old = row()
        assertNull(old.flight)
        val card = InFlightCard.build(old, now = nwNow)
        assertEquals("Running swift test", card.now)
        assertTrue(card.previous.isEmpty())
        assertNull(card.turn)
        assertNull(card.session)
        assertEquals("active 20s ago", card.quiet)
        assertEquals("active 20s ago", card.timeText)
        assertTrue(card.workflows.isEmpty())
        assertNull(card.workflowHeading)
        assertNull(card.model)
        assertEquals(FlightHealth.NORMAL, card.health)
        assertNull(card.healthLine)
    }

    // MARK: a Mac that sends everything

    @Test fun `a Mac that sends everything gives the clocks, the steps in words, the model, the health and the running workflows`() {
        val rich = row(
            """"busySince":"${at(nowT0 - 720).toString()}","startedAt":${(nowT0 - 7800) * 1000},"model":"claude-opus-4-5-20251101",
            "recentSteps":["[Read] Sources/App/Room.swift",{"text":"[Edit] Sources/App/SessionRoom.swift"},42,"[Bash] swift test"],
            "health":"longRunning","workflows":[{"name":"Review changes","phase":"Reviewing","done":3,"total":5,"status":"running"},
            {"name":"Old run","done":2,"total":2,"status":"completed"},{"phase":"no name"}]""",
        )
        assertEquals(at(nowT0 - 720), rich.flight?.busySince)
        assertEquals(at(nowT0 - 7800), rich.flight?.startedAt)
        assertEquals(listOf("[Read] Sources/App/Room.swift", "[Edit] Sources/App/SessionRoom.swift", "[Bash] swift test"), rich.flight?.recentSteps)
        assertEquals(2, rich.flight?.workflows?.size)
        val card = InFlightCard.build(rich, now = nwNow)
        assertEquals("working 12m", card.turn)
        assertEquals("session 2h 10m", card.session)
        assertEquals("working 12m · session 2h 10m", card.timeText)
        assertNull("with a start time the quiet line is not also shown", card.quiet)
        assertEquals("Running swift test", card.now)
        assertEquals(listOf("Editing SessionRoom.swift", "Reading Room.swift"), card.previous)
        assertEquals("Opus 4.5", card.model)
        assertEquals(FlightHealth.LONG_RUNNING, card.health)
        assertEquals("Long-running command", card.healthLine)
        assertEquals(1, card.workflows.size)
        assertEquals("Review changes · Reviewing · 3/5 agents", card.workflows[0].text)
        assertEquals("1 workflow running", card.workflowHeading)
        assertTrue(abs((card.workflows[0].fraction ?: 0.0) - 0.6) < 0.0001)
        val spoken = InFlightSection.build(listOf(rich), hasSessionList = true, now = nwNow).rows[0].spoken
        assertEquals(
            "page, Claude in cmux › page, Running swift test, Long-running command, working 12m · session 2h 10m, 1 workflow running",
            spoken,
        )
    }

    @Test fun `epoch seconds decode, and garbage in every field is the same as none`() {
        assertEquals(at(nowT0 - 90), row(""""busySince":${nowT0 - 90}""").flight?.busySince)
        assertNull(row(""""busySince":"soon","model":7,"recentSteps":"nope","workflows":3""").flight)
    }

    @Test fun `the Mac's full runs win over the list's summaries, and a total of none shows no progress`() {
        val rich = row(
            """"workflows":[{"name":"Review changes","done":3,"total":5,"status":"running"}]""",
        )
        val run = WorkflowRun(id = "r1", name = "Design pass", status = "running", phase = "Draft", done = 1, total = 4)
        val viaRuns = InFlightCard.build(rich, runs = listOf(run, WorkflowRun(id = "r2", name = "Done one", status = "completed", done = 3, total = 3)), now = nwNow)
        assertEquals(listOf("Design pass"), viaRuns.workflows.map { it.name })
        assertEquals("1 workflow running", viaRuns.workflowHeading)
        val old = row()
        val twoRuns = InFlightCard.build(old, runs = listOf(run, WorkflowRun(id = "r3", name = "Lint", status = "running", done = 0, total = 0)), now = nwNow)
        assertEquals("2 workflows running", twoRuns.workflowHeading)
        assertNull(twoRuns.workflows[1].progress)
        assertNull(twoRuns.workflows[1].fraction)
    }

    // MARK: health

    @Test fun `the health word, a stuck page, and a silence are read in the iOS order`() {
        val rich = row(""""health":"longRunning","busySince":"${at(nowT0 - 720).toString()}"""")
        assertEquals(FlightHealth.STUCK, FlightHealth.classify(LiveSessionState.ACTIVE, null, true, nwNow, nwNow))
        assertEquals("the Mac's health word beats a guess", FlightHealth.LONG_RUNNING, FlightHealth.classify(LiveSessionState.ACTIVE, rich.flight, true, nwNow, nwNow))
        assertEquals(FlightHealth.STUCK, FlightHealth.classify(LiveSessionState.ACTIVE, row(""""health":"normal"""").flight, true, nwNow, nwNow))
        assertEquals(FlightHealth.LONG_RUNNING, FlightHealth.classify(LiveSessionState.ACTIVE, null, false, nwNow.minusSeconds(6L * 60), nwNow))
        assertEquals(FlightHealth.NORMAL, FlightHealth.classify(LiveSessionState.ACTIVE, null, false, nwNow.minusSeconds(60), nwNow))
        assertEquals(FlightHealth.RATE_LIMITED, FlightHealth.classify(LiveSessionState.RATE_LIMITED, null, false, null, nwNow))
        val silent = InFlightCard.build(row(""""lastActivityAt":"${at(nowT0 - 6 * 60).toString()}""""), now = nwNow)
        assertEquals("Long-running command · no new step for 6m", silent.healthLine)
        val noted = InFlightCard.build(row(""""health":"stuck","healthNote":"the same step 6 times""""), now = nwNow)
        assertEquals("Looks stuck · the same step 6 times", noted.healthLine)
        assertTrue(noted.health.needsAttention)
    }

    @Test fun `an open stuck page makes the row look stuck, and the section takes the open stuck pages`() {
        val stuckRow = InFlightSection.build(listOf(row()), hasSessionList = true, stuck = setOf("s1"), now = nwNow).rows[0]
        assertEquals(FlightHealth.STUCK, stuckRow.card.health)
    }

    // MARK: the step wording

    @Test fun `the plain-words step phrases read as the iOS copy`() {
        assertEquals("Running swift test", StepPhrase.plain("[Bash] swift test"))
        assertEquals("Running swift test --filter A", StepPhrase.plain("Bash: swift test --filter A"))
        assertEquals("Editing SessionRoom.swift", StepPhrase.plain("[Edit] /Users/me/p/Sources/SessionRoom.swift"))
        assertEquals("Writing c.txt", StepPhrase.plain("[Write] a/b/c.txt"))
        assertEquals("Reading x.swift", StepPhrase.plain("[Read] x.swift"))
        assertEquals("Searching TODO", StepPhrase.plain("[Grep] TODO"))
        assertEquals("Sub-agent: audit the docs", StepPhrase.plain("[Task] audit the docs"))
        assertEquals("Frobnicate: now", StepPhrase.plain("[Frobnicate] now"))
        assertEquals("Running a command", StepPhrase.plain("[Bash]"))
        assertEquals("Done. All tests pass.", StepPhrase.plain("Done. All tests pass."))
        assertEquals("Note: remember this", StepPhrase.plain("Note: remember this"))
        assertEquals(40, StepPhrase.plain("[Bash] " + "x".repeat(300), limit = 40).length)
        assertEquals("", StepPhrase.plain("   "))
        assertEquals("Working", InFlightCard.build(row(preview = ""), now = nwNow).now)
    }

    @Test fun `the clocks read in short and long forms, a backwards clock reads zero, and no start time means no clock`() {
        assertEquals("5s", FlightClock.duration(5.0))
        assertEquals("59s", FlightClock.duration(59.0))
        assertEquals("1m", FlightClock.duration(60.0))
        assertEquals("59m", FlightClock.duration(3599.0))
        assertEquals("1h", FlightClock.duration(3600.0))
        assertEquals("2h 10m", FlightClock.duration(7800.0))
        assertEquals("3d", FlightClock.duration(86_400.0 * 3))
        assertEquals("0s", FlightClock.duration(-5.0))
        assertNull(FlightClock.turn(null, nwNow))
        assertNull(FlightClock.session(null, nwNow))
        assertNull(FlightClock.quiet(null, nwNow))
        assertEquals("active just now", FlightClock.quiet(nwNow, nwNow))
    }

    @Test fun `model names read the Mac's names as sent and raw ids as short names`() {
        assertEquals("Sonnet 4.5", InFlightCard.modelName("claude-sonnet-4-5"))
        assertEquals("Haiku 3.5", InFlightCard.modelName("claude-3-5-haiku-20241022"))
        assertEquals("llama3:8b", InFlightCard.modelName("llama3:8b"))
        assertEquals("Opus 4.7", InFlightCard.modelName("Opus 4.7"))
        assertEquals("Sonnet 4.5", InFlightCard.modelName("Sonnet 4.5"))
        assertEquals("Haiku 4.5", InFlightCard.modelName("Haiku 4.5"))
        assertEquals("Opus 4.7", InFlightCard.modelName("claude-opus-4-7"))
    }

    // MARK: the rows, the strip and the room's entries

    private fun section(vararg sessions: LiveSession, expanded: Boolean = false) =
        InFlightSection.build(sessions.toList(), hasSessionList = true, now = nwNow, expanded = expanded)

    @Test fun `only working sessions are in flight, in a steady project order, and the count counts them all`() {
        val a = nwSession("s-a", title = "relay", state = "active", host = "tmux", cwd = "~/projects/relay", preview = "[Bash] vitest · 212 passed", activeAt = NW_T0 - 9, canInterrupt = true)
        val b = nwSession("s-b", title = "Page", state = "active", host = "cmux", canType = false, cwd = "~/projects/page", activeAt = NW_T0 - 130)
        val c = nwSession("s-c", title = "alpha", state = "active", host = "Ghostty", backend = "codex", cwd = "~/projects/alpha")
        val d = nwSession("s-d", title = "delta", state = "active", host = "Terminal", cwd = "~/projects/delta")
        val waiting = nwSession("s-w", title = "wait", state = "waitingOnApproval", cwd = "~/projects/wait")
        val idle = nwSession("s-i", title = "idle", state = "idle", cwd = "~/projects/idle")
        val all = listOf(d, waiting, b, idle, a, c)
        val sec = InFlightSection.build(all, hasSessionList = true, now = nwNow)
        assertEquals(listOf("s-c", "s-d", "s-b"), sec.rows.map { it.id })
        assertEquals(4, sec.total)
        assertEquals(1, sec.hidden)
        assertTrue(sec.isCapped)
        assertEquals("Show all 4", sec.showAllLabel)
        assertFalse(sec.isExpanded)
        val shuffled = InFlightSection.build(all.reversed(), hasSessionList = true, now = nwNow.plusSeconds(60))
        assertEquals("a refresh or a reordered list never swaps rows", sec.rows.map { it.id }, shuffled.rows.map { it.id })
        val open = InFlightSection.build(all, hasSessionList = true, now = nwNow, expanded = true)
        assertEquals(listOf("s-c", "s-d", "s-b", "s-a"), open.rows.map { it.id })
        assertEquals(0, open.hidden)
        assertTrue(open.isExpanded)
        val few = InFlightSection.build(listOf(a, b), hasSessionList = true, now = nwNow, expanded = true)
        assertFalse(few.isCapped)
        assertFalse(few.isExpanded)
        assertEquals(2, few.rows.size)
        assertEquals("no list yet: nothing is drawn as in flight", InFlightSection.empty, InFlightSection.build(all, hasSessionList = false, now = nwNow))
        assertEquals(0, InFlightSection.build(listOf(waiting, idle), hasSessionList = true, now = nwNow).total)
        assertEquals(
            "N is the Horizon's working count",
            NowModel.build(nwNowInputs(sessions = all, hasList = true)).workingCount,
            InFlightSection.build(all, hasSessionList = true, now = nwNow).total,
        )
    }

    @Test fun `a row names its project, character and host route, its step and age, and what the Mac says it can do`() {
        val a = nwSession("s-a", title = "relay", state = "active", host = "tmux", cwd = "~/projects/relay", preview = "[Bash] vitest · 212 passed", activeAt = NW_T0 - 9, canInterrupt = true)
        val b = nwSession("s-b", title = "Page", state = "active", host = "cmux", canType = false, cwd = "~/projects/page", activeAt = NW_T0 - 130)
        val c = nwSession("s-c", title = "alpha", state = "active", host = "Ghostty", backend = "codex", cwd = "~/projects/alpha")
        val open = section(a, b, c, expanded = true)
        val relay = open.rows.first { it.id == "s-a" }
        assertEquals("relay", relay.project)
        assertEquals("Claude", relay.character)
        assertEquals("tmux › relay", relay.route)
        assertEquals("[Bash] vitest · 212 passed", relay.step)
        assertEquals("9s", relay.age)
        assertEquals("tmux", relay.host)
        assertEquals("Ghostty", open.rows.first { it.id == "s-c" }.host)
        assertTrue(relay.canType && relay.canStop && relay.canMirror)
        val cmux = open.rows.first { it.id == "s-b" }
        assertEquals("working", cmux.step)
        assertEquals("2m", cmux.age)
        assertFalse(cmux.canType)
        assertFalse(cmux.canStop)
        assertTrue(cmux.canMirror)
        val codex = open.rows.first { it.id == "s-c" }
        assertEquals("Codex", codex.character)
        assertFalse(codex.canMirror)
        assertNull(codex.age)
        assertEquals("relay, Claude in tmux › relay, Running vitest · 212 passed, active 9s ago", relay.spoken)
    }

    @Test fun `a room opens on the lens its entry names, only Type takes the keyboard, and only Stop shows the hint`() {
        assertEquals(RoomLens.STORY, RoomEntry.STORY.lens)
        assertEquals(RoomLens.SCREEN, RoomEntry.SCREEN.lens)
        assertEquals(RoomLens.STORY, RoomEntry.TYPE.lens)
        assertEquals(RoomLens.STORY, RoomEntry.STOP.lens)
        assertEquals(listOf(RoomEntry.TYPE), RoomEntry.entries.filter { it.focusesComposer })
        assertEquals(listOf(RoomEntry.STOP), RoomEntry.entries.filter { it.showsStopHint })
        assertEquals(RoomLens.STORY, RoomLens.resolve(RoomEntry.SCREEN.lens, listOf(RoomLens.STORY)))
        assertEquals(RoomLens.SCREEN, RoomLens.resolve(RoomEntry.SCREEN.lens, listOf(RoomLens.STORY, RoomLens.SCREEN)))
    }

    @Test fun `the header jump shows only when there is something working to show`() {
        assertEquals(HeaderJump.sectionId, HeaderJump.target(working = 2, inFlightShown = 1))
        assertNull(HeaderJump.target(working = 0, inFlightShown = 1))
        assertNull(HeaderJump.target(working = 2, inFlightShown = 0))
    }

    // MARK: project names

    @Test fun `a root folder falls back to the session's name, and the home folder reads tilde`() {
        assertEquals("builds", ProjectLabel.name("/", "builds"))
        assertEquals("builds", ProjectLabel.name("", "builds"))
        assertEquals("root", ProjectLabel.name("/", ""))
        assertEquals("root", ProjectLabel.name("//", " / "))
        assertEquals("Unknown project", ProjectLabel.name("", ""))
        assertEquals("~", ProjectLabel.name("~", ""))
        assertEquals("~", ProjectLabel.name("/Users/roy", ""))
        assertEquals("~", ProjectLabel.name("/Users/roy/", "docs"))
        assertEquals("page", ProjectLabel.name("~/projects/page/", "x"))
        assertEquals("page", ProjectLabel.name("/Users/roy/projects/page", "x"))
        assertEquals("page", ProjectLabel.clean("/", "/Users/roy/projects/page"))
        assertEquals("web", ProjectLabel.clean(" ", "/", "web"))
        assertEquals("page", ProjectLabel.clean("page", "/"))
        assertEquals("tokenizer", SkyModel.projectName("/", "tokenizer"))
    }

    // MARK: the Mac's golden wire rows

    @Test fun `the golden stuck row reads as stuck with the Mac's detail, model and clocks`() {
        val stuck = golden(goldenStuck)
        val card = InFlightCard.build(stuck, now = goldenNow)
        assertEquals(at(1_790_000_000.0 - 720), stuck.flight?.busySince)
        assertEquals(FlightHealth.STUCK, card.health)
        assertEquals("Running swift test", card.now)
        assertEquals("working 12m", card.turn)
        assertEquals("session 2h 10m", card.session)
        assertEquals("Opus 4.7", card.model)
        assertNotNull(card.healthLine)
        assertTrue("the Mac's healthDetail reaches the line", card.healthLine!!.contains("no progress for 15 min"))
    }

    @Test fun `the golden rate-limited and long-running rows read their health words, and a rate limit names its reset`() {
        val limited = InFlightCard.build(golden(goldenRateLimited), now = goldenNow)
        assertEquals(FlightHealth.RATE_LIMITED, limited.health)
        assertEquals("Rate limited · resets ${NowFormat.clock(at(1_790_000_000.0 + 900))}", limited.healthLine)
        val longRun = InFlightCard.build(golden(goldenLongRunning, preview = "Bash: make all"), now = goldenNow)
        assertEquals(FlightHealth.LONG_RUNNING, longRun.health)
        assertEquals("Long-running command · no new step for 6m", longRun.healthLine)
    }

    @Test fun `six workflows running reads six, not the three the Mac sent`() {
        val six = InFlightCard.build(golden(goldenSixWorkflows), now = goldenNow)
        assertEquals(3, six.workflows.size)
        assertEquals("Review changes · Reviewing · 3/5 agents", six.workflows.first().text)
        assertEquals("6 workflows running", six.workflowHeading)
    }

    @Test fun `a current step is never repeated as an earlier one, whichever words each side used`() {
        val grep = InFlightCard.build(golden(""""recentSteps":["Reading Package.swift","Searching for TODO"]""", preview = "Grep: TODO in Sources"), now = goldenNow)
        assertFalse(grep.previous.contains("Searching for TODO"))
        val fetch = InFlightCard.build(golden(""""recentSteps":["Reading Package.swift","Fetching example.com"]""", preview = "WebFetch: https://example.com/a/b"), now = goldenNow)
        assertFalse(fetch.previous.contains("Fetching example.com"))
        val task = InFlightCard.build(golden(""""recentSteps":["Running a subagent: review the diff"]""", preview = "Task: review the diff"), now = goldenNow)
        assertFalse(task.previous.contains("Running a subagent: review the diff"))
        val edit = InFlightCard.build(golden(""""recentSteps":["Editing SessionRoom.swift"]""", preview = "Edit: /a/b/SessionRoom.swift"), now = goldenNow)
        assertEquals("Editing SessionRoom.swift", edit.now)
        assertTrue(edit.previous.isEmpty())
    }

    @Test fun `the Mac's last step is now and the rest follow newest first, and a Mac that sends fields but no health says normal`() {
        val wording = InFlightCard.build(
            golden(""""recentSteps":["Reading Package.swift","Running swift test","Searching TODO in Sources"]""", preview = "Grep: TODO in Sources"),
            now = goldenNow,
        )
        assertEquals("Searching TODO in Sources", wording.now)
        assertEquals(listOf("Running swift test", "Reading Package.swift"), wording.previous)
        val calm = InFlightCard.build(
            golden(""""busySince":"2026-09-21T14:01:20Z","recentSteps":["Running swift test"],"lastActivityAt":"2026-09-21T14:07:20Z"""", preview = "Bash: swift test"),
            now = goldenNow,
        )
        assertEquals(FlightHealth.NORMAL, calm.health)
        assertNull(calm.healthLine)
    }

    @Test fun `the legacy fields read the same with and without the new keys, and an older phone decoder accepts the whole row`() {
        val newKeys = listOf("busySince", "startedAt", "model", "recentSteps", "workflows", "workflowsRunning", "health", "healthDetail", "resetsAt", "stepSince")
        val full = golden(goldenStuck)
        val bare = golden(goldenStuck, drop = newKeys.toSet())
        assertEquals(full.id, bare.id)
        assertEquals(full.title, bare.title)
        assertEquals(full.state, bare.state)
        assertEquals(full.preview, bare.preview)
        assertEquals(full.host, bare.host)
        assertEquals(full.canType, bare.canType)
        assertEquals(full.lastActivityAt, bare.lastActivityAt)
        assertNull(bare.flight)
        assertEquals("an open stuck page still says stuck with no flight detail", FlightHealth.STUCK, InFlightCard.build(bare, hasStuckPage = true, now = goldenNow).health)
        assertEquals("s1", bare.id)
        assertEquals("Bash: swift test", golden(goldenSixWorkflows).preview)
    }

    @Test fun `FlightClock three days reads 3d where the Mac says 72h, a stated clock difference`() {
        assertEquals("3d", FlightClock.duration(86_400.0 * 3))
    }
}
