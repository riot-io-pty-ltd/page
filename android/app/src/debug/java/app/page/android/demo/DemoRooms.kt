package app.page.android.demo

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.foundation.layout.statusBarsPadding
import app.page.android.data.AnswerDraftStore
import app.page.android.model.AgentBackend
import app.page.android.model.AgentRoomModel
import app.page.android.model.AnswerSheet
import app.page.android.model.AskOption
import app.page.android.model.AskQuestion
import app.page.android.model.DecisionContent
import app.page.android.model.DecisionPhase
import app.page.android.model.DiffFile
import app.page.android.model.HeldMessage
import app.page.android.model.HeldMessages
import app.page.android.model.InterventionKind
import app.page.android.model.OutboxRestore
import app.page.android.model.PendingAction
import app.page.android.model.PhotoDraft
import app.page.android.model.PhotoFormat
import app.page.android.model.PhotoOffer
import app.page.android.model.PhotoProgress
import app.page.android.model.PhotoStatus
import app.page.android.model.PreparedPhoto
import app.page.android.model.RowAction
import app.page.android.model.ScheduledSend
import app.page.android.model.SendOutbox
import app.page.android.model.SendWhen
import app.page.android.model.SessionCaps
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.NowRowBuilder
import app.page.android.model.RoomLens
import app.page.android.model.SentSessionCommand
import app.page.android.model.SessionAsk
import app.page.android.model.SessionCommandKind
import app.page.android.model.SessionDeliveryState
import app.page.android.model.SessionDiff
import app.page.android.model.SessionScreen
import app.page.android.model.SessionTarget
import app.page.android.model.SessionTranscript
import app.page.android.model.TranscriptEntry
import app.page.android.model.TranscriptRole
import app.page.android.model.WorkflowOrbit
import app.page.android.model.WorkflowRun
import app.page.android.model.YesNoArm
import app.page.android.ui.nw.decision.DecisionScreenState
import app.page.android.ui.nw.decision.NWDecisionScreen
import app.page.android.ui.nw.decision.DecisionScreenActions
import app.page.android.ui.nw.decision.decisionBackground
import app.page.android.ui.nw.room.NWAgentRoomScreen
import app.page.android.ui.nw.room.NWSessionRoom
import app.page.android.ui.nw.room.RoomPhotoTray
import app.page.android.ui.nw.room.SessionRoomActions
import app.page.android.ui.nw.room.SessionRoomData
import java.time.Instant

/** The Session Room and the question card, drawn from fixtures (the Android side of iOS RenderFixtures3 and RenderHarnessAnswers). Pure views over in-memory values: nothing is sent. */
object DemoRooms {
    private val now: Instant = DemoFixtures.now
    private const val mac = DemoFixtures.mac

    fun ago(s: Number): Instant = now.minusMillis((s.toDouble() * 1000).toLong())

    fun session(
        id: String, title: String, backend: String = "claude", provider: String? = "anthropic", state: LiveSessionState, host: String = "cmux",
        canType: Boolean = true, blocker: String? = null, ago: Number = 4, preview: String = "", page: String? = null,
        canHold: Boolean = false, held: List<HeldMessage> = emptyList(), attach: String? = null, attachBlocker: String? = null,
    ) = LiveSession(
        id = id, backend = AgentBackend.fromWire(backend), title = title, cwd = "~/projects/$title", state = state, host = host, canType = canType, typeBlocker = blocker,
        canInterrupt = true, provider = provider, lastActivityAt = ago(ago), interventionId = page, preview = preview, canHold = canHold, held = held, attach = attach, attachBlocker = attachBlocker,
    )

    private fun entry(id: String, role: TranscriptRole, text: String, ago: Number, tool: String? = null) = TranscriptEntry(id, role, text, ago(ago), tool)

    val claudeEntries = listOf(
        entry("e1", TranscriptRole.USER, "Group the sessions list: needs you on top, then working, then idle.", 480),
        entry("e2", TranscriptRole.ASSISTANT, "I'll add section headers to the list and sort by state. Then I'll run the iOS logic tests.", 470),
        entry("e3", TranscriptRole.TOOL, "Read: SessionsView.swift", 460, "Read"),
        entry("e4", TranscriptRole.TOOL, "Grep: SessionGroup", 450, "Grep"),
        entry("e5", TranscriptRole.TOOL, "Edit: Views/SessionsView.swift", 400, "Edit"),
        entry("e6", TranscriptRole.TOOL, "Bash: swift build", 300, "Bash"),
        entry("e7", TranscriptRole.TOOL, "Bash: iOS/Tests/run-logic-tests.sh", 40, "Bash"),
    )
    val waitingEntries = claudeEntries.take(2) + entry("e8", TranscriptRole.ASSISTANT, "Tests pass. I'd like to push the branch so CI runs the UI tests.", 70)
    val codexEntries = listOf(
        entry("c1", TranscriptRole.USER, "Add idempotency keys to POST /charges and cover it with a test.", 200),
        entry("c2", TranscriptRole.TOOL, "Shell: rg -n 'POST /charges' src", 190, "shell"),
        entry("c3", TranscriptRole.TOOL, "Updated the plan", 180, "update_plan"),
        entry("c4", TranscriptRole.TOOL, "Edit: src/charges.ts", 150, "apply_patch"),
        entry("c5", TranscriptRole.TOOL, "Shell: npm test -- charges.idem", 60, "shell"),
    )
    val localEntries = listOf(
        entry("l1", TranscriptRole.USER, "Explain why the BPE merge order breaks round-trips.", 120),
        entry("l2", TranscriptRole.ASSISTANT, "Merges are applied before the byte fallback, so a rare byte pair can be merged into a token the decoder never emits back. Apply the fallback first, then merges in rank order.", 20),
    )

    val diff: SessionDiff = SessionDiff(
        sessionId = "room-claude", clientId = null, scope = "turn", repo = "mac-on-claude-code",
        files = listOf(DiffFile("Views/SessionsView.swift", 84, 6, "modified"), DiffFile("Models/LiveSessions.swift", 32, 8, "modified"), DiffFile("Tests/LogicTests.swift", 4, 0, "modified")),
        patch = listOf(
            "diff --git a/Views/SessionsView.swift b/Views/SessionsView.swift", "index 1a2b3c4..5d6e7f8 100644", "--- a/Views/SessionsView.swift", "+++ b/Views/SessionsView.swift",
            "@@ -40,6 +40,18 @@ struct SessionsView", "     var body: some View {", "-        List(sessions) { row(\$0) }", "+        ForEach(SessionGrouping.sections(sessions)) {",
            "+            SessionGroupHeader(\$0.group)", "+            ForEach(\$0.sessions) { row(\$0) }", "+        }", "     }",
            "diff --git a/Models/LiveSessions.swift b/Models/LiveSessions.swift", "@@ -12,3 +12,8 @@ enum SessionGroup", "+    var title: String { ... }",
            "diff --git a/Tests/LogicTests.swift b/Tests/LogicTests.swift", "@@ -1,3 +1,4 @@", "+check(SessionGrouping.sections([]).isEmpty)",
        ).joinToString("\n"),
        truncated = false, note = null,
    )

    val runs: List<WorkflowRun> = run {
        fun a(id: String, label: String, state: String, ago: Number, phase: String = "Verify") = WorkflowRun.Agent(id, label, phase, state, ago(ago))
        val running = WorkflowRun(
            id = "wf1", name = "review-changes", summary = "Reviews this turn's changes in seven passes.", status = "running", phase = "Verify", done = 4, total = 7,
            startedAt = ago(130), tokens = 184_000,
            agents = listOf(
                a("a1", "verify: SessionsView sort order", "running", 2), a("a2", "verify: iOS logic tests", "running", 12), a("a3", "verify: Android parity", "failed", 40),
                a("a4", "review: InterventionDetector", "done", 60, "Review"), a("a5", "review: SessionStore", "done", 80, "Review"), a("a6", "plan: split", "done", 110, "Plan"),
                a("a7", "plan: scope", "done", 120, "Plan"),
            ),
        )
        val done1 = WorkflowRun(id = "wf2", name = "design-pass", status = "completed", done = 12, total = 12, startedAt = ago(3_000), endedAt = ago(1_800))
        val done2 = WorkflowRun(id = "wf3", name = "port-android", status = "completed", done = 9, total = 9, startedAt = ago(2_400), endedAt = ago(900))
        listOf(running, done1, done2)
    }

    val screenLines = listOf(
        "╭────────────────────────────╮", "│ ✻ Claude Code  v2.1.310    │", "╰────────────────────────────╯", "", "● Update(Views/SessionsView.swift)", "  ⎿  42 additions, 6 removals",
        "● Bash(swift build)", "  ⎿  Build complete (18s)", "● Bash(iOS/Tests/run-logic-tests.sh)", "  ⎿  passes=402 …", "", "✻ Testing… (esc to interrupt · 3m 20s)",
        "────────────────────────────────", "❯ ", "────────────────────────────────", "  ⏵⏵ auto mode on · 1 workflow · 1 shell", "  ○ review-changes   4/7 agents   2m", "  → mac-on-claude-code  main | ctx 62%",
    )

    private val holdCaps = setOf(SessionCaps.HOLD, SessionCaps.RETRACT)
    private val photoCaps = holdCaps + SessionCaps.IMAGES

    private val photoSent = SentSessionCommand(
        "c-ph", "room-claude", SessionCommandKind.INPUT, "What's wrong with these two screens?", ago(30),
        SessionDeliveryState.Typed("Sent 2 photos to Claude in cmux", 2), photos = 2,
    )

    fun inputs(screen: String): SessionRoomData.Inputs {
        var i = SessionRoomData.Inputs(
            session = session("room-claude", "mac-on-claude-code", state = LiveSessionState.ACTIVE, preview = "Bash: iOS/Tests/run-logic-tests.sh"), macName = mac, now = now,
            zone = DemoFixtures.zone, transcript = SessionTranscript("room-claude", claudeEntries, false), fiveHourPct = DemoFixtures.status.usage?.fiveHour?.pct,
            screen = SessionScreen("room-claude", screenLines, ago(2)), runs = runs, diff = diff, diffRequestedAt = now,
            sent = listOf(SentSessionCommand("c-1", "room-claude", SessionCommandKind.INPUT, claudeEntries[0].text, ago(482), SessionDeliveryState.Typed("Typed into cmux"))),
        )
        when (screen) {
            "room-waiting" -> {
                val page = DemoFixtures.iv("c-push", "mac-on-claude-code", InterventionKind.APPROVAL, "[Bash] git push -u origin feat/sections\nPush this branch", 70, session = "room-claude")
                val s = session("room-claude", "mac-on-claude-code", state = LiveSessionState.WAITING_ON_APPROVAL, ago = 70, page = "c-push")
                i = i.copy(session = s, transcript = SessionTranscript("room-claude", waitingEntries, false), pageRow = NowRowBuilder.row(page, s, mac))
            }
            "room-codex" -> i = i.copy(
                session = session("room-codex", "payments-api", "codex", "unknown", LiveSessionState.ACTIVE, host = "Terminal", preview = "Shell: npm test -- charges.idem"),
                transcript = SessionTranscript("room-codex", codexEntries, false), screen = null, runs = emptyList(), fiveHourPct = null, sent = emptyList(),
                diff = SessionDiff("room-codex", null, "turn", "payments-api", listOf(DiffFile("src/charges.ts", 18, 2, "modified")), "", false, null),
            )
            "room-local" -> i = i.copy(
                session = session("room-local", "tokenizer-lab", "opencode", "ollama", LiveSessionState.ACTIVE, preview = "Generating…"),
                transcript = SessionTranscript("room-local", localEntries, false), screen = null, runs = emptyList(), fiveHourPct = null, sent = emptyList(), diff = null,
            )
            // Claude finished a turn and asked a yes/no question in plain words: Yes and No stand in for the generic replies.
            // The busy variant has the same last message, but the session is mid-turn, so nothing is offered.
            "room-yesno", "room-yesno-busy" -> i = i.copy(
                session = session("room-claude", "mac-on-claude-code", state = if (screen == "room-yesno") LiveSessionState.IDLE else LiveSessionState.ACTIVE, ago = 20),
                transcript = SessionTranscript("room-claude", claudeEntries.take(6) + entry("e9", TranscriptRole.ASSISTANT, "I've finished the refactor. Should I run the full test suite now?", 20), false),
                screen = null, runs = emptyList(), sent = emptyList(),
            )
            // A busy session on a Mac that holds messages: "Now" or "When it finishes", explained the first time.
            "room-choice", "room-choice-quiet" -> i = i.copy(
                session = session("room-claude", "mac-on-claude-code", state = LiveSessionState.ACTIVE, preview = "Bash: iOS/Tests/run-logic-tests.sh", canHold = true),
                caps = holdCaps, choiceExplained = screen == "room-choice-quiet", sendWhen = if (screen == "room-choice-quiet") SendWhen.WHEN_FINISHED else null,
            )
            // A busy Codex session outside cmux: nothing can be typed now, but the Mac can hold a message.
            "room-codex-hold" -> i = i.copy(
                session = session("room-codex", "payments-api", "codex", "unknown", LiveSessionState.ACTIVE, host = "Terminal", canType = false, canHold = true, preview = "Shell: npm test -- charges.idem"),
                transcript = SessionTranscript("room-codex", codexEntries, false), screen = null, runs = emptyList(), fiveHourPct = null, sent = emptyList(),
                caps = holdCaps, choiceExplained = false,
            )
            // "Now" to a busy session: 3 s into its 10 s countdown, with Undo.
            "room-countdown" -> {
                val s = session("room-claude", "mac-on-claude-code", state = LiveSessionState.ACTIVE, preview = "Bash: iOS/Tests/run-logic-tests.sh", canHold = true)
                i = i.copy(
                    session = s, caps = holdCaps, choiceExplained = true,
                    outbox = SendOutbox().schedule(ScheduledSend("o-1", s.id, "Run the tests, then stop", SessionTarget.of(s, mac), ago(3))),
                )
            }
            // A message the Mac holds until the turn ends (and one another device sent), each with Delete.
            "room-held", "room-held-note" -> {
                val s = session(
                    "room-claude", "mac-on-claude-code", state = LiveSessionState.ACTIVE, preview = "Bash: iOS/Tests/run-logic-tests.sh", canHold = true,
                    held = listOf(
                        HeldMessage("c-other", "Also update the changelog", ago(900), HeldMessage.State.HELD, null, null),
                        HeldMessage("c-held", "Then run the linter", ago(240), HeldMessage.State.HELD, null, null),
                    ),
                )
                val mine = SentSessionCommand(
                    "c-held", "room-claude", SessionCommandKind.INPUT, "Then run the linter", ago(240),
                    SessionDeliveryState.Held("Held — Page types it when Claude finishes this turn"), target = SessionTarget.of(s, mac),
                )
                i = i.copy(
                    session = s, caps = holdCaps, choiceExplained = true, sent = HeldMessages.pending(s, i.sent + mine), latestInput = mine,
                    restoredNote = if (screen == "room-held-note") OutboxRestore.NOTE_KILLED else null,
                )
            }
            // Yes tapped: the 1.2 s ring and Cancel, the same as the review sheet's.
            "room-yesno-arm" -> i = i.copy(
                session = session("room-claude", "mac-on-claude-code", state = LiveSessionState.IDLE, ago = 20),
                transcript = SessionTranscript("room-claude", claudeEntries.take(6) + entry("e9", TranscriptRole.ASSISTANT, "I've finished the refactor. Should I run the full test suite now?", 20), false),
                screen = null, runs = emptyList(), sent = emptyList(),
                yesNoArm = YesNoArm("Yes", ago(0.4)),
            )
            // Photos (images-v1): an idle session on a Mac that takes them. The tray is drawn by [tray].
            "room-photos", "room-photos-1", "room-photos-path" -> i = i.copy(
                session = session("room-claude", "mac-on-claude-code", state = LiveSessionState.IDLE, ago = 20, attach = if (screen == "room-photos-path") "path" else "image"),
                caps = photoCaps, screen = null, runs = emptyList(), sent = emptyList(),
            )
            // The button is there, dim: tapping it says why (the reason is on screen as it is after a tap).
            "room-photos-busy" -> i = i.copy(
                session = session("room-claude", "mac-on-claude-code", state = LiveSessionState.ACTIVE, preview = "Bash: iOS/Tests/run-logic-tests.sh", canHold = true, attach = "image"),
                caps = photoCaps, choiceExplained = true, composerProblem = PhotoOffer.WORKING,
            )
            // A Codex-style row: it can type but takes no photos, and the Mac said why.
            "room-photos-blocked" -> i = i.copy(
                session = session("room-codex", "payments-api", "codex", "unknown", LiveSessionState.IDLE, host = "tmux", attachBlocker = "Page can't send photos to Codex yet", ago = 30),
                transcript = SessionTranscript("room-codex", codexEntries, false), caps = photoCaps, screen = null, runs = emptyList(), fiveHourPct = null, sent = emptyList(),
            )
            // Photos going up: the receipt's ring fills as pieces are accepted, and the bubble says how far.
            "room-photos-uploading" -> {
                val s = session("room-claude", "mac-on-claude-code", state = LiveSessionState.IDLE, ago = 20, attach = "image")
                val sending = photoSent.copy(state = SessionDeliveryState.Sending, sentAt = ago(4), target = SessionTarget.of(s, mac))
                i = i.copy(
                    session = s, caps = photoCaps, screen = null, runs = emptyList(), sent = listOf(sending), latestInput = sending,
                    uploads = mapOf(sending.clientId to PhotoProgress(15, 36, PhotoProgress.Phase.UPLOADING)),
                )
            }
            // Sent: the Mac's own sentence, and the transcript's user entry carrying the count.
            "room-photos-sent" -> {
                val s = session("room-claude", "mac-on-claude-code", state = LiveSessionState.IDLE, ago = 20, attach = "image")
                val echoed = TranscriptEntry("e-ph", TranscriptRole.USER, "[Image #1] [Image #2]What's wrong with these two screens?", ago(28), null, images = 2)
                i = i.copy(
                    session = s, caps = photoCaps, screen = null, runs = emptyList(),
                    transcript = SessionTranscript("room-claude", claudeEntries.take(6) + echoed + entry("e-ph2", TranscriptRole.ASSISTANT, "The second screen's header overlaps the status bar; the first looks right.", 12), false),
                    sent = listOf(photoSent.copy(target = SessionTarget.of(s, mac))), latestInput = photoSent.copy(target = SessionTarget.of(s, mac)),
                )
            }
            "room-ended" -> i = i.copy(session = session("room-claude", "mac-on-claude-code", state = LiveSessionState.IDLE, ago = 400), ended = true)
            "room-blocked" -> i = i.copy(
                session = session("room-claude", "mac-on-claude-code", state = LiveSessionState.IDLE, host = "Ghostty", canType = false, blocker = "Page can't type into Ghostty yet", ago = 300),
                screen = null, runs = emptyList(),
            )
            "room-receipt", "room-receipt-refused" -> {
                val state: SessionDeliveryState = if (screen == "room-receipt") SessionDeliveryState.Queued(null)
                else SessionDeliveryState.Refused("target_mismatch", "Nothing was typed. The room showed riot-io-teltonika, but that session is now in mac-on-claude-code. Close the room and open it again.")
                i = i.copy(latestInput = SentSessionCommand("c-2", "room-claude", SessionCommandKind.INPUT, "Run the tests, then stop", ago(3), state, target = SessionTarget.of(i.session, mac)))
            }
            "room-changes", "room-review" -> {
                val s = session("room-claude", "mac-on-claude-code", state = LiveSessionState.IDLE, ago = 120)
                i = i.copy(session = s, pageRow = NowRowBuilder.row(DemoFixtures.open[3], s, mac))
            }
        }
        return i
    }

    fun lensFor(screen: String): RoomLens = when (screen) {
        "room-screen" -> RoomLens.SCREEN
        "room-changes", "room-review" -> RoomLens.CHANGES
        "room-workflows" -> RoomLens.WORKFLOWS
        else -> RoomLens.STORY
    }

    /** Colourful stand-ins for picked photos: a sky and a screenshot-like card, drawn here so no file is needed. */
    private fun thumb(kind: Int): androidx.compose.ui.graphics.ImageBitmap {
        val size = 192
        val bmp = android.graphics.Bitmap.createBitmap(size, size, android.graphics.Bitmap.Config.ARGB_8888)
        val c = android.graphics.Canvas(bmp)
        val p = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        if (kind == 0) {
            p.shader = android.graphics.LinearGradient(0f, 0f, 0f, size.toFloat(), intArrayOf(0xFF2B3A67.toInt(), 0xFFE0735C.toInt(), 0xFFF2C14E.toInt()), null, android.graphics.Shader.TileMode.CLAMP)
            c.drawRect(0f, 0f, size.toFloat(), size.toFloat(), p)
            p.shader = null
            p.color = 0xFF1A1F36.toInt()
            c.drawCircle(70f, 150f, 60f, p)
            c.drawCircle(150f, 160f, 48f, p)
        } else {
            p.color = 0xFFEFF2F7.toInt()
            c.drawRect(0f, 0f, size.toFloat(), size.toFloat(), p)
            p.color = 0xFF3366CC.toInt()
            c.drawRect(0f, 0f, size.toFloat(), 40f, p)
            p.color = 0xFFB9C2D3.toInt()
            for (n in 0 until 5) c.drawRoundRect(16f, 60f + n * 25f, size - 16f - (n % 3) * 30f, 76f + n * 25f, 6f, 6f, p)
        }
        return bmp.asImageBitmap()
    }

    private fun readyPhoto() = PhotoStatus.Ready(PreparedPhoto(ByteArray(420_000), PhotoFormat.JPEG, 2000, 1500, sha256 = "0".repeat(64)))

    /** The composer's tray for a photos screen: two thumbnails (one for "-1"/"-path"), none elsewhere. */
    fun tray(screen: String): RoomPhotoTray {
        val ids = when (screen) {
            "room-photos" -> listOf("a", "b")
            "room-photos-1", "room-photos-path" -> listOf("a")
            else -> return RoomPhotoTray()
        }
        val draft = ids.fold(PhotoDraft()) { d, id -> d.adding(listOf(id)).first.with(id, readyPhoto()) }
        return RoomPhotoTray(draft, ids.mapIndexed { n, id -> id to thumb(n) }.toMap())
    }

    @Composable
    fun Room(screen: String) {
        if (screen == "room-agent") {
            val run = runs[0]
            val agent = run.agents[2]
            NWAgentRoomScreen(
                "${run.name} › agent 7", agent.label, WorkflowOrbit.NodeState.FAILED,
                AgentRoomModel.build(
                    listOf(
                        entry("g1", TranscriptRole.USER, "Check the Android port matches iOS usage-card logic exactly; run ./gradlew test.", 200),
                        entry("g2", TranscriptRole.TOOL, "Read: UsageDisplay.swift", 190, "Read"), entry("g3", TranscriptRole.TOOL, "Read: UsageDisplay.kt", 180, "Read"),
                        entry("g4", TranscriptRole.TOOL, "Bash: ./gradlew --offline test", 100, "Bash"),
                        entry("g5", TranscriptRole.ASSISTANT, "Couldn't run the build without the SDK path, so I'm stopping here and reporting it.", 60),
                    ),
                    finished = true,
                ),
                onBack = {},
            )
            return
        }
        val base = SessionRoomData.make(inputs(screen))
        val data = if (screen == "room-stop") base.copy(fixedStop = 0.62) else base
        var lens by remember { mutableStateOf(RoomLens.resolve(lensFor(screen), data.lenses)) }
        var draft by remember { mutableStateOf(if (screen == "room-draft") "Run the tests, then stop" else if (screen.startsWith("room-photos") && tray(screen).draft.count > 0) "What's wrong with this screen?" else "") }
        var runId by remember { mutableStateOf<String?>("wf1") }
        NWSessionRoom(data, SessionRoomActions(), lens, { lens = it }, draft, { draft = it }, runId, { runId = it }, focusComposer = false, photos = remember(screen) { tray(screen) })
    }

    // region Answering the terminal's questions

    private fun isHook(screen: String) = screen.startsWith("ask-hook")

    val ask: SessionAsk = SessionAsk(
        "toolu_ask",
        listOf(
            AskQuestion("Which branch should I base this on?", "Branch", false, listOf(AskOption("main", "The released code."), AskOption("feat/relay-v2", "The relay rewrite, still in review."), AskOption("release/2.4", "Only fixes, no new features."))),
            AskQuestion(
                "Which checks should I run before pushing?", "Checks", true,
                listOf(AskOption("Unit tests", "swift test and the iOS logic tests."), AskOption("Simulator build", "xcodebuild for the iPhone simulator."), AskOption("Render harness", "Screenshots of every Night Watch screen."), AskOption("Lint", "")),
            ),
            AskQuestion("How should I name the commit?", "Commit", false, listOf(AskOption("feat: answer questions from the phone", ""), AskOption("fix: question picker", ""))),
        ),
        false,
    )

    /** The draft each screen shows, built with the real state machine. */
    fun sheet(screen: String): AnswerSheet {
        val s = AnswerSheet(ask, !isHook(screen))
        when (screen) {
            "ask-story-q1", "ask-decision", "ask-story-iterm", "ask-story-terminal" -> Unit
            "ask-story-q2", "ask-screen", "ask-hook-q2" -> { s.tap(1); s.tap(0); s.tap(2) }
            "ask-story-other" -> { s.toggleOther(); s.setOther("develop, but rebase onto main first") }
            else -> { s.tap(1); s.tap(0); s.tap(2); s.toggleOther(); s.setOther("also run the Mac tests"); s.next(); s.tap(0) }
        }
        return s
    }

    private fun delivery(screen: String): SentSessionCommand? {
        val state: SessionDeliveryState = when (screen) {
            "ask-story-sending" -> SessionDeliveryState.Sending
            "ask-story-refused" -> SessionDeliveryState.Refused("question_changed", "That question changed — look at your phone for the new one")
            // The Mac's own words for a question it would not answer in Terminal.app (AnswerDelivery.terminalAppMessage).
            "ask-story-refused-terminal" -> SessionDeliveryState.Refused("answer_unsupported", "Terminal.app adds a Return to every key Page types, which would skip or dismiss questions — answer at your Mac, or use tmux or iTerm2")
            "ask-story-answered" -> SessionDeliveryState.Typed("Answered 3 questions in tmux pane %1")
            else -> return null
        }
        return SentSessionCommand("ans-1", "room-claude", SessionCommandKind.ANSWER, "", ago(2), state, promptKey = "toolu_ask")
    }

    private val terminalLines = listOf(
        "● Before I push, a few questions.", "", "←  ☒ Branch  ☐ Checks  ☐ Commit  ✔ Submit  →", "Which checks should I run before pushing?", "❯ 1. [✔] Unit tests",
        "     swift test and the iOS logic tests.", "  2. [ ] Simulator build", "  3. [✔] Render harness", "  4. [ ] Lint", "  5. [ ] Type something", "     Next", "────────────────────────────────────────",
        "  6. Chat about this", "Enter to select · Tab/Arrow keys to navigate · Esc to cancel",
    )

    fun roomInputs(screen: String): SessionRoomData.Inputs {
        val base = inputs("room-waiting")
        val hook = isHook(screen)
        val page = DemoFixtures.iv(if (hook) "hookpre-q-ask" else "q-ask", "mac-on-claude-code", InterventionKind.USER_INPUT, "Which branch should I base this on?", 70, session = "room-claude")
        // The wire host the Mac names: a refused answer and the no-ask case are Terminal.app, "ask-story-iterm" is iTerm2.
        val host = when (screen) { "ask-story-refused-terminal", "ask-story-terminal" -> "Terminal"; "ask-story-iterm" -> "iTerm"; else -> "tmux" }
        // The Mac sends no `ask` for Terminal.app (it can't answer there), so its question has no answer sheet, only "Tell it instead".
        val s = session("room-claude", "mac-on-claude-code", state = if (hook) LiveSessionState.ACTIVE else LiveSessionState.WAITING_ON_USER, host = host, ago = 70, page = if (hook) null else "q-ask")
            .copy(ask = if (screen == "ask-story-terminal") null else ask)
        return base.copy(
            session = s, pageIsHook = hook,
            pageContext = if (hook) ask.questions.withIndex().joinToString("\n\n") { (n, q) -> "Q${n + 1}. ${q.text}\n" + q.options.withIndex().joinToString("\n") { (k, o) -> "${k + 1}. ${o.label}" } } else null,
            pageRow = NowRowBuilder.row(page, s, mac), screen = SessionScreen("room-claude", terminalLines, ago(2)), answerDelivery = delivery(screen),
        )
    }

    @Composable
    fun Ask(screen: String) {
        AnswerDraftStore.seed(ask, !isHook(screen), sheet(screen))
        if (screen == "ask-decision") {
            val page = DemoFixtures.iv(
                "q-ask", "mac-on-claude-code", InterventionKind.USER_INPUT,
                "Which branch should I base this on?\n1. main — The released code.\n2. feat/relay-v2 — The relay rewrite, still in review.\n3. release/2.4 — Only fixes, no new features.", 70, session = "room-claude",
            )
            val session = roomInputs("ask-decision").session
            val row = NowRowBuilder.row(page, session, mac)
            val content = DecisionContent.build(page, row, session, mac)
            val state = DecisionScreenState(content = content, row = row, phase = DecisionPhase.Open, now = now, hasSession = true, ask = ask, macName = mac)
            androidx.compose.foundation.layout.Box(Modifier.fillMaxSize().background(decisionBackground(row))) {
                androidx.compose.foundation.layout.Box(Modifier.androidxStatusPad()) {
                    NWDecisionScreen(state, DecisionScreenActions(), "", {}, false, {})
                }
            }
            return
        }
        val data = SessionRoomData.make(roomInputs(screen))
        var lens by remember { mutableStateOf(if (screen.startsWith("ask-screen")) RoomLens.SCREEN else RoomLens.STORY) }
        var draft by remember { mutableStateOf("") }
        var runId by remember { mutableStateOf<String?>(null) }
        NWSessionRoom(data, SessionRoomActions(), lens, { lens = it }, draft, { draft = it }, runId, { runId = it })
    }

    // endregion
}

private fun Modifier.androidxStatusPad(): Modifier = this.then(Modifier.statusBarsPadding())
