package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant
import kotlin.math.PI
import kotlin.math.abs

/**
 * The Session Room: the agent's character and lenses, the header chips, the composer's modes and previews, the
 * room's plan and banners, the story, workflows, changes and the terminal, ported from the "Night Watch (iOS): the
 * Session Room, Story, workflows, Changes, terminal" checks in iOS/Tests/LogicTests.swift.
 */
class SessionRoomTest {
    private fun near(a: Double, b: Double, eps: Double = 1e-6) = abs(a - b) < eps

    private val claude = AgentCharacter.from(AgentBackend.Known(InterventionBackend.CLAUDE), null)
    private val codex = AgentCharacter.from(AgentBackend.Known(InterventionBackend.CODEX), null)
    private val other = AgentCharacter.from(AgentBackend.Other("gemini"), null)
    private val ollama = AgentCharacter.from(AgentBackend.Known(InterventionBackend.CLAUDE), "ollama")
    private val opencode = AgentCharacter.from(AgentBackend.Other("opencode"), "ollama")

    // MARK: character and lenses

    @Test fun `the Claude, Codex and unknown agents keep their own names and the local model has its privacy line`() {
        assertEquals(AgentCharacter.Kind.CLAUDE, claude.kind)
        assertEquals("Claude", claude.name)
        assertEquals(AgentCharacter.Kind.CODEX, codex.kind)
        assertEquals("Codex", codex.name)
        assertEquals(AgentCharacter.Kind.OTHER, other.kind)
        assertEquals("Gemini", other.name)
        assertEquals(AgentCharacter.Kind.LOCAL, ollama.kind)
        assertEquals("Ollama", ollama.runtime)
        assertEquals("Private · nothing leaves this Mac", ollama.privacyTitle)
        assertEquals("LM Studio", AgentCharacter.from(AgentBackend.Known(InterventionBackend.CLAUDE), "lmStudio").runtime)
        assertEquals("A local model", AgentCharacter.from(AgentBackend.Known(InterventionBackend.CLAUDE), "otherLocal").runtime)
    }

    @Test fun `subtitles name the agent, the local runtime and the terminal, and an unknown host is omitted`() {
        assertEquals("Claude · cmux", claude.subtitle(AgentBackend.Known(InterventionBackend.CLAUDE), null, "cmux"))
        assertEquals("Claude · on Ollama · cmux", ollama.subtitle(AgentBackend.Known(InterventionBackend.CLAUDE), "ollama", "cmux"))
        assertEquals("Ollama · via Opencode · cmux", opencode.subtitle(AgentBackend.Other("opencode"), "ollama", "cmux"))
        assertEquals("Claude", claude.subtitle(AgentBackend.Known(InterventionBackend.CLAUDE), null, "unknown"))
    }

    @Test fun `Claude gets every lens with something behind it, and the others get fewer`() {
        val offer = RoomLens.available(RoomLens.Inputs(claude, hasScreen = true, workflowCount = 2, canAskForChanges = true))
        assertEquals(listOf(RoomLens.STORY, RoomLens.SCREEN, RoomLens.CHANGES, RoomLens.WORKFLOWS), offer)
        assertEquals(
            listOf(RoomLens.STORY, RoomLens.SCREEN, RoomLens.CHANGES),
            RoomLens.available(RoomLens.Inputs(codex, hasScreen = true, workflowCount = 2, canAskForChanges = true)),
        )
        assertEquals(listOf(RoomLens.STORY), RoomLens.available(RoomLens.Inputs(other, hasScreen = true, workflowCount = 2, canAskForChanges = true)))
        assertEquals(
            listOf(RoomLens.STORY, RoomLens.SCREEN, RoomLens.CHANGES),
            RoomLens.available(RoomLens.Inputs(ollama, hasScreen = true, workflowCount = 0, canAskForChanges = true)),
        )
    }

    @Test fun `an unoffered lens falls back to Story and an offered one is kept`() {
        val offer = RoomLens.available(RoomLens.Inputs(claude, hasScreen = true, workflowCount = 2, canAskForChanges = true))
        assertEquals(RoomLens.STORY, RoomLens.resolve(RoomLens.SCREEN, listOf(RoomLens.STORY)))
        assertEquals(RoomLens.STORY, RoomLens.resolve(null, offer))
        assertEquals(RoomLens.CHANGES, RoomLens.resolve(RoomLens.CHANGES, offer))
    }

    @Test fun `the changes badge counts files and the workflows badge counts running ones`() {
        assertEquals(3, RoomLens.badge(RoomLens.CHANGES, changedFiles = 3, runningWorkflows = 0))
        assertNull(RoomLens.badge(RoomLens.CHANGES, changedFiles = null, runningWorkflows = 0))
        assertEquals(2, RoomLens.badge(RoomLens.WORKFLOWS, changedFiles = null, runningWorkflows = 2))
        assertNull(RoomLens.badge(RoomLens.STORY, changedFiles = 5, runningWorkflows = 5))
    }

    // MARK: the header chips

    private fun chips(
        s: LiveSession, c: AgentCharacter = claude, ended: Boolean = false, waiting: Instant? = null,
        review: Boolean = false, fiveHour: Double? = null,
    ) = RoomHeader.chips(s, c, ended, waiting, review, fiveHour, nwNow)

    @Test fun `a working room reads its quiet time and the Mac's five-hour use`() {
        val fresh = nwSession("r1", title = "page", state = "active", cwd = "~/projects/page", activeAt = NW_T0 - 45)
        assertEquals(listOf("WORKING · last step 45s ago", "5h 62%"), chips(fresh, fiveHour = 62.0).map { it.text })
        assertEquals("WORKING · last step 45s ago", chips(nwSession("r1", state = "active", activeAt = NW_T0 - 45)).first().text)
        assertEquals(RoomChip.Tone.WARM, chips(fresh, fiveHour = 85.0).last().tone)
    }

    @Test fun `a waiting room says needs you with the wait, a finished one with a review page is finished`() {
        val waiting = nwSession("r2", state = "waitingOnApproval", activeAt = NW_T0 - 600)
        assertEquals("NEEDS YOU · 1m", chips(waiting, waiting = nwNow.minusSeconds(60)).first().text)
        val idle = nwSession("r3", state = "idle", activeAt = NW_T0 - 120)
        assertEquals("FINISHED · 2m ago", chips(idle, review = true).first().text)
        assertEquals("IDLE · 2m ago", chips(idle, review = false).first().text)
        assertEquals("ENDED", chips(nwSession("r5", state = "active", activeAt = NW_T0 - 45), ended = true).first().text)
    }

    @Test fun `a local model says generating and on-device`() {
        val local = nwSession("r4", state = "active", activeAt = NW_T0 - 1)
        val c = chips(local, ollama, fiveHour = 90.0)
        assertEquals("GENERATING", c.first().text)
        assertEquals("on-device", c.last().text)
    }

    // MARK: the composer

    private fun mode(i: RoomComposerMode.Inputs) = RoomComposerMode.resolve(i)

    @Test fun `a busy session steers, an idle or unknown one takes the next task, a waiting one answers through its page`() {
        assertEquals(RoomComposerMode.Steer, mode(RoomComposerMode.Inputs(LiveSessionState.ACTIVE, canType = true)))
        assertEquals(RoomComposerMode.NextTask, mode(RoomComposerMode.Inputs(LiveSessionState.IDLE, canType = true)))
        assertEquals(RoomComposerMode.NextTask, mode(RoomComposerMode.Inputs(LiveSessionState.UNKNOWN, canType = true)))
        assertEquals(
            RoomComposerMode.TellInstead("p1"),
            mode(RoomComposerMode.Inputs(LiveSessionState.WAITING_ON_APPROVAL, canType = true, pageId = "p1")),
        )
        assertEquals(
            "a decision pinned while active is never steer",
            RoomComposerMode.TellInstead("p1"),
            mode(RoomComposerMode.Inputs(LiveSessionState.ACTIVE, canType = true, pageId = "p1", pageIsDecide = true)),
        )
    }

    @Test fun `a waiting page with no reply, a decision still arriving, and a waiting session with no page are locked with a reason`() {
        val noReply = mode(RoomComposerMode.Inputs(LiveSessionState.WAITING_ON_USER, canType = true, pageId = "p1", pageAcceptsReply = false))
        assertEquals(RoomComposerMode.Locked("Answer this prompt from its decision above."), noReply)
        val arriving = mode(RoomComposerMode.Inputs(LiveSessionState.WAITING_ON_APPROVAL, canType = true, pageArriving = true))
        assertTrue((arriving as RoomComposerMode.Locked).why.contains("still arriving"))
        val noPage = mode(RoomComposerMode.Inputs(LiveSessionState.WAITING_ON_APPROVAL, canType = true))
        assertTrue((noPage as RoomComposerMode.Locked).why.contains("on your Mac"))
    }

    @Test fun `a session that cannot be typed into is blocked with its reason, and the default reason when there is none`() {
        assertEquals(
            RoomComposerMode.Blocked("Ghostty can't take input"),
            mode(RoomComposerMode.Inputs(LiveSessionState.IDLE, canType = false, typeBlocker = "Ghostty can't take input")),
        )
        assertEquals(RoomComposerMode.Blocked(LiveSession.DEFAULT_BLOCKER), mode(RoomComposerMode.Inputs(LiveSessionState.IDLE, canType = false)))
    }

    @Test fun `an ended session is never steerable, a room not ready is disabled, and ended beats waiting`() {
        assertFalse(mode(RoomComposerMode.Inputs(LiveSessionState.ACTIVE, canType = true, ended = true)) == RoomComposerMode.Steer)
        assertEquals(
            RoomComposerMode.Disabled("Waiting for your Mac."),
            mode(RoomComposerMode.Inputs(LiveSessionState.ACTIVE, canType = true, ready = false)),
        )
        assertEquals(
            RoomComposerMode.Disabled("This session has ended."),
            mode(RoomComposerMode.Inputs(LiveSessionState.WAITING_ON_USER, canType = true, ended = true)),
        )
    }

    @Test fun `a waiting session is never steered or given a task`() {
        for (s in listOf(LiveSessionState.WAITING_ON_USER, LiveSessionState.WAITING_ON_APPROVAL)) {
            val m = mode(RoomComposerMode.Inputs(s, canType = true, pageId = "p"))
            assertTrue(m != RoomComposerMode.Steer && m != RoomComposerMode.NextTask)
        }
    }

    @Test fun `the previews name the route and the Mac, and the agent's own wording`() {
        assertEquals(
            "Your message, then Return · queues after this step · cmux › page · Studio MBP",
            RoomComposerMode.Steer.preview(claude, "cmux › page", "Studio MBP"),
        )
        assertEquals(
            "Your message, then Return · delivered when this turn ends · M",
            RoomComposerMode.Steer.preview(codex, null, "M"),
        )
        assertEquals(
            "Your message, then Return · sent when generation stops · M",
            RoomComposerMode.Steer.preview(ollama, null, "M"),
        )
        assertEquals("Your message, then Return · cmux › page · M", RoomComposerMode.NextTask.preview(claude, "cmux › page", "M"))
        assertEquals("Esc, then your message · cmux › page · M", RoomComposerMode.TellInstead("p").preview(claude, "cmux › page", "M"))
        assertEquals(
            "Deny, with your message, through the hook · M",
            RoomComposerMode.TellInstead("p").preview(claude, null, "M", pagePreview = "Deny, with your message, through the hook · M"),
        )
        assertEquals("Can't type here · why · M", RoomComposerMode.Blocked("why").preview(claude, null, "M"))
        assertNull(RoomComposerMode.Locked("x").preview(claude, null, "M"))
        assertNull(RoomComposerMode.Disabled("x").preview(claude, null, "M"))
    }

    @Test fun `the composer copy, and which modes take text, route through the page, use session input or offer quick replies`() {
        assertEquals("Tell it instead…", RoomComposerMode.TellInstead("p").copy(claude).placeholder)
        assertTrue(RoomComposerMode.TellInstead("p").copy(claude).hint.contains("sends Esc first"))
        assertEquals("Steer Claude…", RoomComposerMode.Steer.copy(claude).placeholder)
        assertEquals("queues after the current step", RoomComposerMode.Steer.copy(claude).hint)
        assertEquals("Message Codex…", RoomComposerMode.Steer.copy(codex).placeholder)
        assertEquals("delivered when this turn ends", RoomComposerMode.Steer.copy(codex).hint)
        assertEquals("Message the model…", RoomComposerMode.Steer.copy(ollama).placeholder)
        assertEquals("sent when generation stops", RoomComposerMode.Steer.copy(ollama).hint)
        assertTrue(RoomComposerMode.TellInstead("p").routesThroughPage)
        assertFalse(RoomComposerMode.Steer.routesThroughPage)
        assertTrue(RoomComposerMode.Steer.usesSessionInput && RoomComposerMode.NextTask.usesSessionInput)
        assertFalse(RoomComposerMode.TellInstead("p").usesSessionInput)
        assertFalse(RoomComposerMode.Locked("x").acceptsText || RoomComposerMode.Blocked("x").acceptsText || RoomComposerMode.Disabled("x").acceptsText)
        assertTrue(RoomComposerMode.Steer.offersQuickReplies && RoomComposerMode.NextTask.offersQuickReplies)
        assertFalse(RoomComposerMode.TellInstead("p").offersQuickReplies)
        assertTrue(RoomComposerMode.timingNote(codex, busy = true) != null)
        assertNull(RoomComposerMode.timingNote(codex, busy = false))
    }

    // MARK: the room's plan and banners

    private val waitingWithPage = nwSession("p1", title = "bottle-flip", state = "waitingOnApproval", host = "Terminal", canType = true, interventionId = "a1")

    @Test fun `a decision is pinned in the story and answers in words, with the route and the Mac in the preview`() {
        val pageRow = NowRowBuilder.row(nwIv("a1", InterventionKind.APPROVAL, "[Bash] npm test\nRun the tests", session = "p1"), waitingWithPage, "Studio MBP")
        val plan = RoomPlan.build(RoomPlan.Inputs(waitingWithPage, claude, pageRow, ended = false, ready = true, macName = "Studio MBP"))
        assertEquals("a1", plan.pinned?.id)
        assertNull(plan.review)
        assertEquals(RoomComposerMode.TellInstead("a1"), plan.mode)
        assertEquals("Esc, then your message · Terminal › bottle-flip · Studio MBP", plan.preview)
    }

    @Test fun `a finished turn is reviewed not pinned, a waiting session without its page is locked, and a hook preview never types`() {
        val reviewRow = NowRowBuilder.row(nwIv("r1", InterventionKind.IDLE, "Changed 1 file · tests passed\n\nDone", session = "p2"), null, "M")
        val idleSession = nwSession("p2", title = "page", state = "idle", host = "cmux", canType = true, interventionId = "r1")
        val reviewPlan = RoomPlan.build(RoomPlan.Inputs(idleSession, claude, reviewRow, ended = false, ready = true, macName = "M"))
        assertEquals("r1", reviewPlan.review?.id)
        assertNull(reviewPlan.pinned)
        assertEquals(RoomComposerMode.NextTask, reviewPlan.mode)

        val arriving = RoomPlan.build(RoomPlan.Inputs(waitingWithPage, claude, null, ended = false, ready = true, macName = "M"))
        assertTrue((arriving.mode as RoomComposerMode.Locked).why.contains("still arriving"))

        val hookRow = NowRowBuilder.row(nwIv("hookpre-z", InterventionKind.APPROVAL, "[Bash] ls", session = "p1"), waitingWithPage, "M")
        val hookPlan = RoomPlan.build(RoomPlan.Inputs(waitingWithPage, claude, hookRow, ended = false, ready = true, macName = "M"))
        assertTrue(hookPlan.preview!!.contains("hook"))
        assertFalse(hookPlan.preview!!.contains("type"))
    }

    @Test fun `the room's stop previews Esc, names the folder, and only a mid-turn session that can be interrupted can stop`() {
        val stopS = nwSession("q1", title = "bottle-flip", state = "active", host = "Terminal", canInterrupt = true)
        val stop = SessionStopPlan.build(stopS, ready = true, ended = false, macName = "Studio MBP")
        assertTrue(stop.canStop)
        assertEquals("Press Esc in bottle-flip", stop.scope)
        assertEquals("Will press Esc · Terminal › bottle-flip · Studio MBP", stop.preview)
        assertFalse(SessionStopPlan.build(stopS, ready = true, ended = true, macName = "M").canStop)
        assertFalse(SessionStopPlan.build(nwSession("q2", state = "active", canInterrupt = false), ready = true, ended = false, macName = "M").canStop)
        assertFalse(SessionStopPlan.build(nwSession("q3", state = "idle", canInterrupt = true), ready = true, ended = false, macName = "M").canStop)
    }

    @Test fun `the room holds for 10 s to stop`() {
        assertEquals(HoldRingSpec(0.0, 10.0), SessionStopPlan.spec)
    }

    @Test fun `the room banners - ended, offline Mac, an open decision, a prompt with no page, and a pinned decision needs none`() {
        val fresh = nwSession("r1", title = "page", state = "active", cwd = "~/projects/page", activeAt = NW_T0 - 45)
        assertEquals(listOf("This session has ended"), RoomBanner.build(true, SessionAvailability.Ready, fresh, "Claude", false).map { it.title })
        val mac = RoomBanner.build(false, SessionAvailability.MacOffline, fresh, "Claude", false).first()
        assertEquals(RoomBanner.Action.Retry, mac.action)
        assertEquals("Try again", mac.actionTitle)
        val openPage = nwSession("p9", title = "t", state = "waitingOnApproval", interventionId = "a9")
        val page = RoomBanner.build(false, SessionAvailability.Ready, openPage, "Claude", false).first()
        assertEquals("Claude needs your approval", page.title)
        assertEquals(RoomBanner.Action.OpenDecision("a9"), page.action)
        assertTrue(RoomBanner.build(false, SessionAvailability.Ready, openPage, "Claude", true).isEmpty())
        val promptOnly = nwSession("p8", title = "t", state = "waitingOnUser")
        assertEquals("Claude is showing a prompt", RoomBanner.build(false, SessionAvailability.Ready, promptOnly, "Claude", false).first().title)
    }

    @Test fun `the screen's freshness reads live, slow, quiet, or how long ago`() {
        assertEquals(ScreenFreshness(ScreenFreshness.Tone.LIVE, "LIVE · 2s"), ScreenFreshness.evaluate(nwNow.minusSeconds(2), nwNow, busy = true))
        assertEquals(ScreenFreshness(ScreenFreshness.Tone.SLOW, "SLOW · 34s"), ScreenFreshness.evaluate(nwNow.minusSeconds(34), nwNow, busy = true))
        assertEquals(ScreenFreshness(ScreenFreshness.Tone.QUIET, "LIVE · 12s"), ScreenFreshness.evaluate(nwNow.minusSeconds(12), nwNow, busy = true))
        assertEquals(ScreenFreshness(ScreenFreshness.Tone.QUIET, "1m ago"), ScreenFreshness.evaluate(nwNow.minusSeconds(90), nwNow, busy = false))
    }

    // MARK: the story

    @Test fun `a tool line becomes a step of the right kind, with the words kept`() {
        val bash = StoryStep.parse("1", "Bash: swift build", null)
        assertEquals(StoryStep.Kind.SHELL, bash.kind)
        assertEquals("swift build", bash.title)
        assertTrue(bash.mono)
        val read = StoryStep.parse("2", "Read: SessionsView.swift", null)
        assertEquals(StoryStep.Kind.READ, read.kind)
        assertEquals("Read SessionsView.swift", read.title)
        assertEquals(StoryStep.Kind.SEARCH, StoryStep.parse("3", "Grep: SessionGroup", null).kind)
        val edit = StoryStep.parse("4", "Edit: a.swift", null)
        assertEquals(StoryStep.Kind.EDIT, edit.kind)
        assertEquals("Edit a.swift", edit.title)
        assertEquals("Write a.swift", StoryStep.parse("5", "Write: a.swift", null).title)
        val plan = StoryStep.parse("6", "Updated the plan", "update_plan")
        assertEquals(StoryStep.Kind.PLAN, plan.kind)
        assertEquals("Updated the plan", plan.title)
        assertEquals(StoryStep.Kind.WEB, StoryStep.parse("7", "fetch: https://x", "WebFetch").kind)
        assertEquals(StoryStep.Kind.OTHER, StoryStep.parse("8", "thing", "Frobnicate").kind)
        assertEquals("just words no colon", StoryStep.parse("9", "just words no colon", null).title)
    }

    private val u = TranscriptEntry("u1", TranscriptRole.USER, "fix the tests", nwNow, null)
    private val t1 = TranscriptEntry("t1", TranscriptRole.TOOL, "Bash: swift test", null, "Bash")
    private val t2 = TranscriptEntry("t2", TranscriptRole.TOOL, "Read: a.swift", null, "Read")
    private val asst = TranscriptEntry("a1", TranscriptRole.ASSISTANT, "Done", null, null)
    private val t3 = TranscriptEntry("t3", TranscriptRole.TOOL, "Edit: a.swift", null, "Edit")
    private val sysE = TranscriptEntry("x1", TranscriptRole.SYSTEM, "Interrupted", null, null)

    private fun entry(e: TranscriptEntry) = TranscriptTimeline.Item.Entry(e, null)

    @Test fun `a story groups consecutive tool calls, puts a time divider on a user turn, and turns system lines into markers`() {
        val blocks = StoryBuilder.build(
            listOf(entry(u), entry(t1), entry(t2), entry(asst), entry(t3), entry(sysE)), active = true, zone = NW_ZONE,
        )
        assertEquals(6, blocks.size)
        assertEquals("08:00", (blocks[0] as StoryBlock.Divider).label)
        val steps = blocks[2] as StoryBlock.Steps
        assertEquals(2, steps.steps.size)
        assertFalse(steps.live)
        assertEquals("Interrupted", (blocks[5] as StoryBlock.Marker).text)
        assertFalse("a story that ends in a marker has no live steps", blocks.any { it is StoryBlock.Steps && it.live })
    }

    @Test fun `trailing steps are live while busy, and an idle story has none`() {
        val live = StoryBuilder.build(listOf(entry(u), entry(t3)), active = true, zone = NW_ZONE).last() as StoryBlock.Steps
        assertEquals(1, live.steps.size)
        assertTrue(live.live)
        val quiet = StoryBuilder.build(listOf(entry(t1)), active = false, zone = NW_ZONE).last() as StoryBlock.Steps
        assertFalse(quiet.live)
    }

    @Test fun `a message from the phone is marked, and a pending message becomes a pending block`() {
        val sent = SentSessionCommand("c1", "p1", SessionCommandKind.INPUT, "hi there", nwNow, SessionDeliveryState.Sending)
        val phone = StoryBuilder.build(listOf(TranscriptTimeline.Item.Entry(u, sent)), active = false, zone = NW_ZONE)
        // iOS says "from iPhone"; on Android the same mark reads "from phone" (the device noun is the only difference).
        assertEquals("08:00 · from phone", (phone[0] as StoryBlock.Divider).label)
        val pending = StoryBuilder.build(listOf(TranscriptTimeline.Item.Pending(sent)), active = false, zone = NW_ZONE)
        assertTrue(pending.any { it is StoryBlock.Pending })
    }

    @Test fun `the live line is the preview, or Working or Generating while steps run, and nothing unless active`() {
        assertEquals("vitest · 212 passed", StoryBuilder.liveLine(nwSession("l1", state = "active", preview = "vitest · 212 passed"), claude))
        assertEquals("Working…", StoryBuilder.liveLine(nwSession("l2", state = "active", preview = "x"), claude, trailingStepsAreLive = true))
        assertEquals("Generating…", StoryBuilder.liveLine(nwSession("l3", state = "active", preview = "x"), ollama, trailingStepsAreLive = true))
        assertEquals("Working…", StoryBuilder.liveLine(nwSession("l4", state = "active", preview = ""), claude))
        assertNull(StoryBuilder.liveLine(nwSession("l5", state = "idle", preview = "x"), claude))
    }

    @Test fun `an agent room takes the first user entry as the task, keeps later messages, and is live only while running`() {
        val userTask = TranscriptEntry("k1", TranscriptRole.USER, "port the app", null, null)
        val later = TranscriptEntry("k2", TranscriptRole.USER, "also the widget", null, null)
        val agent = AgentRoomModel.build(listOf(userTask, t1, later, asst), finished = true)
        assertEquals("port the app", agent.task)
        assertEquals(listOf("also the widget"), agent.blocks.mapNotNull { (it as? StoryBlock.User)?.entry?.text })
        assertFalse(agent.blocks.any { it is StoryBlock.Steps && it.live })
        assertTrue(AgentRoomModel.build(listOf(userTask, t1), finished = false).blocks.any { it is StoryBlock.Steps && it.live })
        val oddOrder = AgentRoomModel.build(listOf(t1, userTask), finished = true)
        assertFalse("the task is not repeated even when a tool call came first", oddOrder.blocks.any { it is StoryBlock.User })
        assertTrue(AgentRoomModel.readOnlyNote.contains("read-only"))
    }

    // MARK: workflows

    private fun wr(
        id: String, name: String, status: String, done: Int, total: Int, agents: List<WorkflowRun.Agent> = emptyList(),
        endedAt: java.time.Instant? = null, startedAt: java.time.Instant? = null, tokens: Long? = null, phase: String? = null,
    ) = WorkflowRun(id = id, name = name, status = status, phase = phase, done = done, total = total, startedAt = startedAt,
        endedAt = endedAt, tokens = tokens, agents = agents)

    private fun agent(id: String, label: String, state: String) = WorkflowRun.Agent(id = id, label = label, phase = null, state = state, lastActivityAt = null)

    @Test fun `the workflow orbit shows its centre, meta and nodes, running ones first, and at most twenty-four nodes`() {
        val agents = listOf(agent("a1", "scan", "done"), agent("a2", "verify", "running"), agent("a3", "port", "failed"), agent("a4", "lint", "weird"))
        val run = wr("r1", "design-pass", "running", 4, 7, agents, startedAt = nwNow.minusSeconds(120), tokens = 184_000, phase = "Verify")
        val orbit = WorkflowOrbit.build(run, nwNow)
        assertEquals("4/7", orbit.centre)
        assertEquals("agents done", orbit.caption)
        assertEquals("phase Verify · 2m · 184.0k tokens", orbit.meta)
        assertTrue(orbit.isRunning)
        assertEquals(4, orbit.nodes.size)
        assertEquals(WorkflowOrbit.NodeState.RUNNING, orbit.nodes.first().state)
        assertEquals("verify", orbit.nodes.first().label)
        assertTrue(orbit.nodes.map { it.state }.containsAll(listOf(WorkflowOrbit.NodeState.STOPPED, WorkflowOrbit.NodeState.FAILED, WorkflowOrbit.NodeState.DONE)))
        assertTrue("nodes are spaced clockwise from twelve o'clock", near(orbit.nodes[1].angle, PI / 2))
        val big = (0 until 30).map { agent("x$it", "a", "done") }
        assertEquals(WorkflowOrbit.maxNodes, WorkflowOrbit.build(wr("r2", "big", "running", 0, 30, big), nwNow).nodes.size)
    }

    @Test fun `the finished-today line counts today's runs, and no finished runs means no line`() {
        val finishedToday = listOf(
            wr("f1", "design-pass", "completed", 7, 7, endedAt = nwNow.minusSeconds(60)),
            wr("f2", "port-android", "completed", 3, 3, endedAt = nwNow.minusSeconds(120)),
            wr("f3", "old", "completed", 1, 1, endedAt = nwNow.minusSeconds(86_400L * 2)),
        )
        assertEquals("2 finished today · design-pass ✓ · port-android ✓", WorkflowOrbit.finishedLine(finishedToday, nwNow, NW_ZONE))
        assertNull(WorkflowOrbit.finishedLine(emptyList(), nwNow, NW_ZONE))
    }

    @Test fun `the workflow groups run in order and empty groups are left out`() {
        val agents = listOf(agent("a1", "scan", "done"), agent("a2", "verify", "running"), agent("a3", "port", "failed"), agent("a4", "lint", "weird"))
        val run = wr("r1", "design-pass", "running", 4, 7, agents)
        assertEquals(listOf("Running", "Failed or didn't finish", "Done"), WorkflowOrbit.groups(run).map { it.first })
        assertEquals(listOf("Done"), WorkflowOrbit.groups(wr("d", "d", "completed", 1, 1, listOf(agents[0]))).map { it.first })
        assertEquals("2m", WorkflowRun.duration(120.0))
        assertEquals("1.5k tokens", WorkflowRun.tokens(1500))
        assertEquals("12 tokens", WorkflowRun.tokens(12))
        assertEquals("Stopped", wr("s", "s", "killed", 0, 0).statusLabel)
        assertEquals("No recent activity", wr("s", "s", "stalled", 0, 0).statusLabel)
    }

    // MARK: changes

    @Test fun `the changes model totals a turn's diff, shares the bar, and keeps a patch section with no file row`() {
        val base = SessionDiff(
            sessionId = "p1", clientId = null, scope = "turn", repo = null,
            files = listOf(DiffFile("x.swift", 120, 14, "modified")),
            patch = "diff --git a/x.swift b/x.swift\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/y.swift b/y.swift\n+more\n",
            truncated = false, note = null,
        )
        val model = ChangesModel.build(base)
        assertEquals("THIS TURN", model.scopeLabel)
        assertEquals(120, model.added)
        assertEquals(14, model.removed)
        assertTrue(near(model.addedFraction, 120.0 / 134))
        assertEquals("1 file", model.fileCountText)
        assertEquals(listOf("y.swift"), model.unmatchedSections.map { it.path })
    }

    @Test fun `the empty copy for uncommitted and quiet turns, and the line kinds`() {
        val uncommitted = ChangesModel.build(SessionDiff("p1", null, "uncommitted", null, emptyList(), "", false, null))
        assertEquals("UNCOMMITTED CHANGES", uncommitted.scopeLabel)
        assertEquals("No uncommitted changes.", uncommitted.emptyText)
        val quietTurn = ChangesModel.build(SessionDiff("p1", null, "turn", null, emptyList(), "", false, null))
        assertEquals("This turn didn't change any files.", quietTurn.emptyText)
        assertTrue(near(quietTurn.addedFraction, 1.0))
        assertEquals(ChangesModel.LineKind.HUNK, ChangesModel.lineKind("@@ -1 +1 @@"))
        assertEquals(ChangesModel.LineKind.ADDED, ChangesModel.lineKind("+x"))
        assertEquals(ChangesModel.LineKind.REMOVED, ChangesModel.lineKind("-x"))
        assertEquals(ChangesModel.LineKind.CONTEXT, ChangesModel.lineKind("+++ b/x"))
        assertEquals(ChangesModel.LineKind.CONTEXT, ChangesModel.lineKind("--- a/x"))
        assertEquals(ChangesModel.LineKind.CONTEXT, ChangesModel.lineKind(" y"))
    }

    @Test fun `the ask-about copy, and the load states for a diff, an error, a wait and no answer`() {
        assertEquals("Why did you change Sources/A.swift?", ChangesModel.question("Sources/A.swift"))
        assertEquals("Why did you make these changes?", ChangesModel.question(null))
        assertEquals(ChangesModel.Load.Loaded, ChangesModel.load(hasDiff = true, error = null, requestedAt = nwNow, now = nwNow))
        assertEquals(ChangesModel.Load.Failed("x"), ChangesModel.load(hasDiff = false, error = "x", requestedAt = nwNow, now = nwNow))
        assertEquals(ChangesModel.Load.Loading, ChangesModel.load(hasDiff = false, error = null, requestedAt = nwNow.minusSeconds(5), now = nwNow))
        assertEquals(ChangesModel.Load.NoAnswer, ChangesModel.load(hasDiff = false, error = null, requestedAt = nwNow.minusSeconds(25), now = nwNow))
    }

    // MARK: the terminal

    @Test fun `the terminal mirror tones tool lines, spinners, footers, prompts, rules and plain text`() {
        assertEquals(TerminalTone.TOOL, TerminalTone.classify("● Bash(x)"))
        assertEquals(TerminalTone.TOOL, TerminalTone.classify("⏺ Reading"))
        assertEquals(TerminalTone.BUSY, TerminalTone.classify("✻ Testing… (esc to interrupt)"))
        assertEquals(TerminalTone.FOOTER, TerminalTone.classify("⏵⏵ auto mode on"))
        assertEquals(TerminalTone.PROMPT, TerminalTone.classify("❯ "))
        assertEquals(TerminalTone.QUIET, TerminalTone.classify("────────────"))
        assertEquals(TerminalTone.QUIET, TerminalTone.classify("⎿  Done"))
        assertEquals(TerminalTone.PLAIN, TerminalTone.classify("hello"))
        assertEquals(TerminalTone.PLAIN, TerminalTone.classify(""))
    }
}
