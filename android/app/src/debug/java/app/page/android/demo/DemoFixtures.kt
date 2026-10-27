package app.page.android.demo

import app.page.android.model.ActivityLog
import app.page.android.model.AgentBackend
import app.page.android.model.BatteryForecast
import app.page.android.model.ClaudeUsage
import app.page.android.model.DiffFile
import app.page.android.model.Intervention
import app.page.android.model.InterventionBackend
import app.page.android.model.InterventionKind
import app.page.android.model.InterventionSource
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.MacStatusSnapshot
import app.page.android.model.SessionDiff
import app.page.android.model.SessionFlight
import app.page.android.model.SessionScreen
import app.page.android.model.SessionTranscript
import app.page.android.model.StableHash
import app.page.android.model.StarState
import app.page.android.model.StartFolder
import app.page.android.model.StartFolders
import app.page.android.model.TranscriptEntry
import app.page.android.model.TranscriptRole
import app.page.android.model.UsageWindow
import app.page.android.model.WorkflowBrief
import app.page.android.model.WorkflowRun
import java.time.Instant
import java.time.ZoneId

/**
 * Fixtures in the real wire shape, mirroring iOS RenderFixtures (the scenario of the v4 boards): a Mac called
 * Studio MBP at 41% on battery, a bottle-flip page that deletes Dev builds (irreversible), a `swift test` page
 * (undoable), llm-play looking stuck, a finished review, and working sessions with the optional in-flight fields.
 * A page's `context` is what the Mac's `describeToolUse` writes ("[Bash] command" then a description line).
 */
object DemoFixtures {
    const val mac = "Studio MBP"

    /** The clock the fixtures pretend it is: Tue 27 Oct 2026, 01:12 UTC (the same as the iOS harness). */
    val now: Instant = Instant.ofEpochSecond(1_793_063_520)
    val zone: ZoneId = ZoneId.of("UTC")

    private fun ago(seconds: Number): Instant = now.minusMillis((seconds.toDouble() * 1000).toLong())

    fun iv(
        id: String, project: String, kind: InterventionKind, ctx: String, ago: Number, sub: String? = null,
        backend: InterventionBackend? = InterventionBackend.CLAUDE, session: String? = null, backendRaw: String? = null,
    ): Intervention = Intervention(
        id = id, sessionId = session ?: "sess-$id", cwd = "/Users/you/projects/$project", projectName = project, kind = kind,
        openedAt = ago(ago), context = ctx, backend = backend, backendRaw = backendRaw ?: backend?.wire, source = InterventionSource.TERMINAL, subtype = sub,
    )

    val open: List<Intervention> = listOf(
        iv("p1", "bottle-flip", InterventionKind.APPROVAL, "[Bash] rm -rf Builds/Dev/*.app\nDelete every Dev build", 240),
        // A bare command: the Mac cannot tell a description line from more command, so a page that carries one is
        // Considered. This one is the swipe-to-run row.
        iv("p2", "page", InterventionKind.APPROVAL, "[Bash] swift test --filter StuckTests", 40),
        iv("p3", "llm-play", InterventionKind.IDLE, "Looks stuck in a loop: this has failed 6 times.\ncargo test", 800, sub = "looping"),
        iv("p4", "mac-on-claude-code", InterventionKind.IDLE, "Changed 3 files (+120 −14) · tests passed\n\nAll done.", 120),
    )

    /** One page per Decision sheet variant. */
    fun page(screen: String): Intervention = when (screen) {
        "decision-considered" -> iv("c1", "page", InterventionKind.APPROVAL, "[Edit] /Users/you/projects/page/Sources/Relay/Router.swift\nRoute replies through the planner", 95)
        "decision-question" -> iv("q1", "page", InterventionKind.USER_INPUT, "Which branch should I base this on: main or feat/relay-v2?", 70)
        "decision-plan" -> iv("pl1", "page", InterventionKind.APPROVAL, "Plan ready for review\n1. Migrate the relay to v2\n2. Update the Worker routes\n3. Add the migration tests", 130, sub = "plan")
        "decision-standing" -> iv(
            "s1", "page", InterventionKind.APPROVAL,
            "[Bash] npm install\nInstall the packages\n1. Yes\n2. Yes, and don't ask again for npm commands in this project\n3. No, and tell Claude what to do differently", 50,
        )
        "decision-unknown" -> iv("u1", "payments-api", InterventionKind.APPROVAL, "Run the migration?", 33, backend = null, backendRaw = "gemini")
        "decision-stuck" -> open[2]
        "decision-review" -> open[3]
        "decision-undoable" -> open[1]
        else -> open[0]
    }

    private fun s(
        id: String, title: String, project: String, state: LiveSessionState, host: String = "cmux", ago: Number,
        preview: String = "", iv: String? = null, canType: Boolean = true,
    ) = LiveSession(
        id = id, backend = AgentBackend.fromWire("claude"), title = title, cwd = "~/projects/$project", state = state, host = host,
        canType = canType, typeBlocker = null, canInterrupt = true, provider = "anthropic", lastActivityAt = ago(ago), interventionId = iv, preview = preview,
    )

    val sessions: List<LiveSession> = listOf(
        s("sess-p1", "builds", "bottle-flip", LiveSessionState.WAITING_ON_APPROVAL, ago = 240, preview = "rm -rf Builds/Dev/*.app", iv = "p1"),
        s("sess-p2", "SessionsView", "page", LiveSessionState.WAITING_ON_APPROVAL, ago = 40, preview = "swift test", iv = "p2"),
        s("sess-p3", "tokenizer", "llm-play", LiveSessionState.ACTIVE, ago = 700, preview = "cargo test ×6"),
        s("sess-p4", "docs", "mac-on-claude-code", LiveSessionState.IDLE, ago = 120),
        s("w1", "relay", "page", LiveSessionState.ACTIVE, host = "tmux", ago = 9, preview = "[Bash] vitest · 212 passed"),
        s("w2", "pio run", "sate-t", LiveSessionState.ACTIVE, ago = 20, preview = "pio run"),
        s("w3", "flash", "sate-t", LiveSessionState.ACTIVE, host = "tmux", ago = 70, preview = "esptool write"),
        s("w4", "charges", "payments-api", LiveSessionState.IDLE, ago = 3_000),
        s("w5", "web", "bottle-flip", LiveSessionState.ACTIVE, host = "Ghostty", ago = 31, preview = "npm run build"),
    )

    /** A full sky: 17 sessions over 11 projects, long names, several that need you, one stuck. */
    val crowdedSessions: List<LiveSession> = sessions + listOf(
        s("c1", "deploy", "relay-worker-edge-router-service", LiveSessionState.WAITING_ON_APPROVAL, ago = 90, preview = "wrangler deploy --env production"),
        s("c2", "tests", "relay-worker-edge-router-service", LiveSessionState.ACTIVE, ago = 12, preview = "vitest"),
        s("c3", "audit", "a-very-long-project-name-for-the-fleet-dashboard", LiveSessionState.ACTIVE, ago = 25, preview = "npm audit"),
        s("c4", "migrate", "a-very-long-project-name-for-the-fleet-dashboard", LiveSessionState.WAITING_ON_APPROVAL, ago = 200, preview = "psql -f migrate.sql"),
        s("c5", "widgets", "ios-widgets", LiveSessionState.ACTIVE, ago = 40, preview = "xcodebuild"),
        s("c6", "notes", "docs-site", LiveSessionState.IDLE, ago = 1_800),
        s("c7", "scratch", "x", LiveSessionState.ACTIVE, ago = 15, preview = "ls"),
        s("c8", "lint", "mac-on-claude-code", LiveSessionState.ACTIVE, ago = 8, preview = "swiftlint"),
    )

    /** The Mac's richer list rows for the two working sessions: one with workflows, one it calls stuck. */
    val sessionsWithFlight: List<LiveSession> = sessions.map { s ->
        when (s.id) {
            "w1" -> s.copy(
                flight = SessionFlight.make(
                    busySince = ago(12 * 60), startedAt = ago(2 * 3600 + 10 * 60), model = "Opus 4.7",
                    recentSteps = listOf("Reading Session.swift", "Editing SessionRoom.swift", "Running swift build"),
                    health = null, healthNote = null,
                    workflows = listOf(
                        WorkflowBrief("Review changes", "Reviewing", 3, 5, "running"),
                        WorkflowBrief("Docs sweep", "Writing", 1, 4, "running"),
                    ),
                    workflowsRunning = 2,
                ),
            )
            "sess-p3" -> s.copy(
                flight = SessionFlight.make(
                    busySince = ago(41 * 60), startedAt = ago(5 * 3600), model = "Sonnet 4.5",
                    recentSteps = listOf("Reading lib.rs", "Running cargo test", "Running cargo test"), health = "stuck",
                    healthNote = "the same test failed 6 times", workflows = emptyList(),
                ),
            )
            else -> s
        }
    }

    fun nowSessions(screen: String): List<LiveSession> {
        fun pick(ids: List<String>, from: List<LiveSession>) = ids.mapNotNull { id -> from.firstOrNull { it.id == id } }
        return when (screen) {
            "now-flight", "now-flight-two", "now-flight-header", "now-flight-jump" -> pick(listOf("sess-p1", "w1", "sess-p3"), sessionsWithFlight)
            "now-flight-old" -> pick(listOf("sess-p1", "w1", "sess-p3"), sessions)
            "now-flight-quiet" -> pick(listOf("w1", "sess-p3"), sessionsWithFlight)
            "now-inflight", "now-tip-irreversible" -> pick(listOf("sess-p1", "w1", "w2"), sessions)
            "now-inflight-long" -> pick(listOf("sess-p2", "w1", "w2", "w3", "w5", "c2", "c3", "c5", "c7"), crowdedSessions)
            "now-tip-undoable" -> pick(listOf("sess-p2"), sessions)
            "now-tip-inflight" -> pick(listOf("w1", "w2"), sessions)
            else -> sessionsWithFlight
        }
    }

    val status: MacStatusSnapshot = MacStatusSnapshot(
        macConnected = true, lastHeartbeatAt = now, activeSessions = 9, battery = 41, onAC = false, working = 5,
        forecast = BatteryForecast(cutoff = 10, minutes = 148, drainPerHour = 12.0),
        usage = ClaudeUsage(
            fiveHour = UsageWindow(62.0, now.plusSeconds(110 * 60)), sevenDay = UsageWindow(87.0, now.plusSeconds(3 * 86_400)),
            hitAt = now.plusSeconds(88 * 60), updatedAt = now,
        ),
    )

    /**
     * The status as the live demo shows it: stamped relative to the real clock, not the fixture clock, so a demo
     * opened today does not open on "Mac stopped checking in". The usage windows move by the same amount.
     */
    fun statusAt(real: Instant): MacStatusSnapshot {
        val shift = java.time.Duration.between(now, real)
        fun w(u: UsageWindow?) = u?.copy(resetsAt = u.resetsAt?.plus(shift))
        return status.copy(
            lastHeartbeatAt = real,
            usage = status.usage?.copy(
                fiveHour = w(status.usage.fiveHour), sevenDay = w(status.usage.sevenDay),
                hitAt = status.usage.hitAt?.plus(shift), updatedAt = real,
            ),
        )
    }

    /** The open pages with their wait measured from the real clock ("waiting 4m", not hours). */
    fun openAt(real: Instant): List<Intervention> {
        val shift = java.time.Duration.between(now, real)
        return open.map { it.copy(openedAt = it.openedAt.plus(shift)) }
    }

    val history: List<Intervention> = run {
        fun done(id: String, kind: InterventionKind, ctx: String, action: String?, text: String? = null, ago: Double, sub: String? = null, delivered: Boolean = true): Intervention {
            val base = iv(id, "page", kind, ctx, ago + 60, sub = sub)
            return base.copy(
                closedAt = now.minusMillis((ago * 1000).toLong()),
                repliedAt = if (action != null) now.minusMillis((ago * 1000).toLong()) else null,
                repliedAction = action, repliedText = text,
                deliveryStatus = if (action != null) (if (delivered) "delivered" else "pending") else null,
                closeReason = if (action != null) "replied" else null,
            )
        }
        val day = 86_400.0 * 0.5 // yesterday afternoon, clear of midnight
        val list = arrayListOf(
            done("h1", InterventionKind.APPROVAL, "[Bash] npm test\nRun the tests", "approve", ago = 12.0 * 60),
            done("h2", InterventionKind.USER_INPUT, "Should I use the cache?", "custom", "use the cache", ago = 31.0 * 60),
        )
        // Yesterday: a headline card.
        for (i in 0 until 14) list.add(done("y$i", InterventionKind.APPROVAL, "[Bash] ls\nList", "approve", ago = day + i * 600.0))
        for (i in 0 until 6) list.add(done("f$i", InterventionKind.IDLE, "Changed 2 files (+10 −2) · tests passed\n\nDone", null, ago = day + 9_000 + i * 700.0))
        for (i in 0 until 2) list.add(done("s$i", InterventionKind.IDLE, "No progress for 15 min", null, ago = day + 20_000 + i * 300.0, sub = "stuck"))
        list.add(done("b0", InterventionKind.IDLE, "Paused for battery", null, ago = day + 30_000, sub = "low_battery"))
        list
    }

    /** Four hours of sampled lanes, as if Page had been open all night. */
    val activity: ActivityLog = run {
        val log = ActivityLog()
        for (step in 48 downTo 0) {
            val at = now.minusSeconds(step * 300L)
            val states = HashMap<String, StarState>()
            for ((i, s) in sessions.withIndex()) {
                val seed = StableHash.unit(s.id, step)
                when (s.state) {
                    LiveSessionState.ACTIVE -> {
                        // Working with the odd quiet bucket; llm-play stalls near the end.
                        states[s.id] = if (s.id == "sess-p3" && step < 14) StarState.STUCK else (if (seed > 0.18) StarState.WORKING else StarState.IDLE)
                        if (step > 40 - (i % 4) * 4) states.remove(s.id)
                    }
                    LiveSessionState.WAITING_ON_APPROVAL -> states[s.id] = if (step < 6) StarState.NEEDS_YOU else (if (seed > 0.25) StarState.WORKING else StarState.IDLE)
                    LiveSessionState.IDLE -> states[s.id] = if (step > 24) (if (seed > 0.4) StarState.WORKING else StarState.IDLE) else StarState.IDLE
                    else -> Unit
                }
            }
            log.record(states, at)
        }
        log
    }

    val folders: StartFolders = StartFolders(
        clientId = null, enabled = true, agents = listOf("claude"),
        folders = listOf("page" to 2, "bottle-flip" to 18, "llm-play" to 60, "sate-t-production" to 300, "payments-api" to 1_400).map { (name, minutes) ->
            StartFolder("/Users/you/projects/$name", name, now.minusSeconds(minutes * 60L))
        },
    )

    private fun e(id: String, role: TranscriptRole, text: String, ago: Number, tool: String? = null) = TranscriptEntry(id, role, text, ago(ago), tool)

    fun transcripts(): List<SessionTranscript> = listOf(
        SessionTranscript(
            "w1",
            listOf(
                e("1", TranscriptRole.USER, "Make the relay stop dropping replies when the Mac is offline.", 3_600),
                e("2", TranscriptRole.ASSISTANT, "I'll read the router first, then queue replies and test it.", 3_560),
                e("3", TranscriptRole.TOOL, "Read: Sources/Relay/Router.swift", 3_540, "Read"),
                e("4", TranscriptRole.TOOL, "Edit: Sources/Relay/Router.swift", 3_000, "Edit"),
                e("5", TranscriptRole.ASSISTANT, "Replies now wait in a queue until the Mac reconnects. Running the tests.", 600),
                e("6", TranscriptRole.TOOL, "Bash: vitest", 9, "Bash"),
            ),
            truncated = false,
        ),
        SessionTranscript(
            "sess-p1",
            listOf(
                e("1", TranscriptRole.USER, "Clean up old builds.", 600),
                e("2", TranscriptRole.ASSISTANT, "These are the Dev builds; they can all go.", 300),
                e("3", TranscriptRole.TOOL, "Bash: rm -rf Builds/Dev/*.app", 240, "Bash"),
                e("4", TranscriptRole.SYSTEM, "Waiting for approval", 240),
            ),
            truncated = false,
        ),
    )

    fun screens(): List<SessionScreen> = listOf(
        SessionScreen(
            "w1",
            listOf(
                "⏺ Bash(vitest)", "  ⎿  ✓ 212 passed", "", "────────────────────────────────────────────────", "❯ ",
                "────────────────────────────────────────────────", "  ⏵⏵ auto mode on (shift+tab to cycle)",
            ),
            now,
        ),
    )

    fun workflows(): Map<String, List<WorkflowRun>> = mapOf(
        "w1" to listOf(
            WorkflowRun(
                id = "wf_review", name = "Review changes", status = "running", phase = "Reviewing", done = 3, total = 5, startedAt = ago(600),
                agents = listOf(
                    WorkflowRun.Agent("a1", "review: relay router", "Reviewing", "running", ago(10)),
                    WorkflowRun.Agent("a2", "review: queue", "Reviewing", "done", ago(300)),
                ),
            ),
        ),
    )

    fun diff(sessionId: String): SessionDiff = SessionDiff(
        sessionId = sessionId, clientId = null, scope = "turn", repo = "page",
        files = listOf(DiffFile("Sources/Relay/Router.swift", 42, 6, "modified"), DiffFile("Tests/RouterTests.swift", 30, 0, "added")),
        patch = listOf(
            "diff --git a/Sources/Relay/Router.swift b/Sources/Relay/Router.swift", "@@ -10,6 +10,9 @@",
            " func route() {", "-    send(now)", "+    queue.append(reply)", "+    flushWhenOnline()", " }",
        ).joinToString("\n"),
        truncated = false, note = null,
    )
}
