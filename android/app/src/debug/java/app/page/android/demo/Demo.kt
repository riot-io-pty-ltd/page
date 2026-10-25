package app.page.android.demo

import android.os.Bundle
import app.page.android.data.AppRouter
import app.page.android.data.AppTab
import app.page.android.data.LaunchHints
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.model.AgentBackend
import app.page.android.model.Base64Url
import app.page.android.model.ValidatedPairing
import app.page.android.notify.PageInfo
import app.page.android.notify.PageNotifications
import app.page.android.model.BatteryForecast
import app.page.android.model.ClaudeUsage
import app.page.android.model.DiffFile
import app.page.android.model.MacStatusSnapshot
import app.page.android.model.SessionDiff
import app.page.android.model.StartFolder
import app.page.android.model.StartFolders
import app.page.android.model.UsageWindow
import app.page.android.model.Intervention
import app.page.android.model.InterventionBackend
import app.page.android.model.InterventionKind
import app.page.android.model.InterventionSource
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.PairedMac
import app.page.android.model.SessionScreen
import app.page.android.model.SessionTranscript
import app.page.android.model.TranscriptEntry
import app.page.android.model.TranscriptRole
import app.page.android.model.WorkflowRun
import java.time.Instant

/**
 * Debug-only demo mode (the Android side of iOS DevBypass.swift): fills the
 * app with sample pages, history, live sessions, transcripts, a terminal
 * screen and workflows, so every screen can be seen without a Mac. It never
 * writes credentials, starts the background connection or touches the
 * network, and a relaunch returns to the pairing screen.
 *
 * Scriptable for screenshots:
 * `adb shell am start -n app.page.android.debug/app.page.android.MainActivity --ez page_demo true
 *   [--es page_demo_tab inbox|sessions|history|settings] [--es page_demo_open dev-1]
 *   [--es page_demo_session active|<id>] [--es page_demo_pane terminal|workflows] [--es page_demo_run <runId>]`
 */
object Demo {
    const val available = true

    fun start() {
        // Never over a real pairing: seeding resets the relay client, which
        // would clear the real session key.
        if (PairingStore.isPaired && !PairingStore.isDemoPairing) return
        PairingStore.adoptDemo(PairedMac("MacBook Pro (demo)", Instant.now()))
        RelayClient.seedDemoInbox(interventions())
        RelayClient.seedDemoHistory(history())
        // Sessions are seeded after the inbox, whose reset clears them.
        SessionStore.seedDemo("MacBook Pro (demo)", sessions(), transcripts(), screens(), workflows())
        SessionStore.seedDemoExtras(mapOf(ACTIVE_SESSION_ID to diff(), "99999999-4444-dddd-eeee-ffffffffffff" to diff()), folders())
        // On battery with a forecast, and Claude usage captured (v4 heartbeat fields).
        RelayClient.seedDemoStatus(
            MacStatusSnapshot(
                macConnected = true, lastHeartbeatAt = Instant.now(), activeSessions = 7, battery = 42, onAC = false,
                working = 2, forecast = BatteryForecast(cutoff = 10, minutes = 35, drainPerHour = 55.0),
                usage = ClaudeUsage(
                    fiveHour = UsageWindow(62.0, Instant.now().plusSeconds(2 * 3600)), sevenDay = UsageWindow(31.0, Instant.now().plusSeconds(3 * 24 * 3600 + 5 * 3600)),
                    hitAt = Instant.now().plusSeconds(80 * 60), updatedAt = Instant.now(),
                ),
            )
        )
    }

    fun handleLaunchExtras(extras: Bundle?) {
        // Exercises the real, non-demo path (Keystore, adopt, socket failure,
        // Stay connected) against a relay that can't resolve. Unpaired only.
        if (extras?.getBoolean("page_test_pair") == true && !PairingStore.isPaired) {
            val random = java.security.SecureRandom()
            val token = Base64Url.encode(ByteArray(32).also(random::nextBytes))
            PairingStore.adopt(ValidatedPairing(token, "https://relay.invalid", "Test Mac", ByteArray(32).also(random::nextBytes)))
            return
        }
        if (extras?.getBoolean("page_demo") != true) return
        start()
        if (!PairingStore.isDemoPairing) return
        when (extras.getString("page_demo_tab")) {
            "inbox" -> AppRouter.selectTab(AppTab.INBOX)
            "history" -> AppRouter.selectTab(AppTab.HISTORY)
            "settings" -> AppRouter.selectTab(AppTab.SETTINGS)
            "sessions" -> AppRouter.selectTab(AppTab.SESSIONS)
        }
        extras.getString("page_demo_open")?.let { AppRouter.open(it) }
        extras.getString("page_demo_session")?.let { AppRouter.openSession(if (it == "active") ACTIVE_SESSION_ID else it) }
        if (extras.getBoolean("page_demo_new")) AppRouter.openNewSession()
        // Posts sample page notifications (approval, stuck, idle) to check how
        // they render; their actions find no pairing and say so in a notice.
        if (extras.getBoolean("page_demo_notify")) {
            interventions().filter { it.id in setOf("dev-1", "dev-5", "dev-4") }.forEach {
                PageNotifications.post(PageInfo.of(it), silent = false, status = null)
            }
        }
        LaunchHints.sessionPane = extras.getString("page_demo_pane")
        LaunchHints.workflowRunId = extras.getString("page_demo_run")
    }

    const val ACTIVE_SESSION_ID = "5e551011-5555-eeee-ffff-000000000000"

    private fun ago(seconds: Long): Instant = Instant.now().minusSeconds(seconds)

    fun interventions(): List<Intervention> = listOf(
        Intervention(
            id = "dev-1", sessionId = "7f3a9c2b-1111-aaaa-bbbb-cccccccccccc", cwd = "/Users/you/projects/acme-web",
            projectName = "acme-web", kind = InterventionKind.APPROVAL, openedAt = ago(12),
            context = "Bash command needs approval: `npm install bcrypt@5.1.1`",
            backend = InterventionBackend.CLAUDE, source = InterventionSource.TERMINAL,
        ),
        Intervention(
            id = "dev-2", sessionId = "abcdef12-2222-bbbb-cccc-dddddddddddd", cwd = "/Users/you/projects/nova-firmware",
            projectName = "nova-firmware", kind = InterventionKind.USER_INPUT, openedAt = ago(130),
            context = "Should I retry the cert download at 9600 baud instead of 38400?",
            backend = InterventionBackend.CODEX, source = InterventionSource.VSCODE,
        ),
        Intervention(
            id = "dev-3", sessionId = "12345678-3333-cccc-dddd-eeeeeeeeeeee", cwd = "/Users/you/projects/helix-mobile",
            projectName = "helix-mobile", kind = InterventionKind.APPROVAL, openedAt = ago(310),
            context = "4-step plan for the Reply screen is ready — review before implementation?",
            backend = InterventionBackend.CLAUDE, source = InterventionSource.TERMINAL, subtype = "plan",
        ),
        Intervention(
            id = "dev-4", sessionId = "99999999-4444-dddd-eeee-ffffffffffff", cwd = "/Users/you/projects/orbit-api",
            projectName = "orbit-api", kind = InterventionKind.IDLE, openedAt = ago(900),
            context = "Changed 3 files (+120 −14) · tests passed\n\nFinished the migration and all tests pass. Waiting for your next instruction.",
            backend = InterventionBackend.CLAUDE, source = InterventionSource.TERMINAL,
        ),
        // v4 pages: a stuck session, a stalled workflow, a plain rate limit and a usage forecast.
        Intervention(
            id = "dev-5", sessionId = "0110a4a1-6666-ffff-0000-111111111111", cwd = "/Users/you/projects/llm-play",
            projectName = "llm-play", kind = InterventionKind.IDLE, openedAt = ago(60),
            context = "The same failing call ran 6 times: Bash: cargo test tokenizer::tests::bpe_roundtrip",
            backend = InterventionBackend.CLAUDE, source = InterventionSource.TERMINAL, subtype = "looping",
        ),
        Intervention(
            id = "dev-6", sessionId = ACTIVE_SESSION_ID, cwd = "/Users/you/projects/page-android",
            projectName = "page-android", kind = InterventionKind.IDLE, openedAt = ago(400),
            context = "Workflow design-pass-ch1-8-opus has made no progress for 20 minutes (28/30 agents done).",
            backend = InterventionBackend.CLAUDE, source = InterventionSource.TERMINAL, subtype = "workflow_stalled",
        ),
        Intervention(
            id = "dev-7", sessionId = "ra7e1111-7777-0000-1111-222222222222", cwd = "/Users/you/projects/docs-site",
            projectName = "docs-site", kind = InterventionKind.RATE_LIMIT, openedAt = ago(1800),
            context = "Codex hit its usage limit. It resets at 3:00 PM.", backend = InterventionBackend.CODEX,
        ),
        Intervention(
            id = "dev-8", sessionId = "page-mac-usage", cwd = "", projectName = "Your Mac", kind = InterventionKind.RATE_LIMIT,
            openedAt = ago(30), context = "At the current pace the Claude 5-hour limit is reached in about 30 minutes (at 4:10 PM).",
            backend = InterventionBackend.CLAUDE, subtype = "usage_forecast",
        ),
    )

    fun history(): List<Intervention> = listOf(
        Intervention(
            id = "h-1", sessionId = "7f3a9c2b-1111-aaaa-bbbb-cccccccccccc", cwd = "/Users/you/projects/acme-web",
            projectName = "acme-web", kind = InterventionKind.APPROVAL, openedAt = ago(3_700),
            context = "Bash: npm run test -- --coverage", closedAt = ago(3_640), closeReason = "replied",
            repliedAt = ago(3_650), repliedAction = "approve", backend = InterventionBackend.CLAUDE,
        ),
        Intervention(
            id = "h-2", sessionId = "abcdef12-2222-bbbb-cccc-dddddddddddd", cwd = "/Users/you/projects/nova-firmware",
            projectName = "nova-firmware", kind = InterventionKind.USER_INPUT, openedAt = ago(7_300),
            context = "Which board revision are you flashing?", closedAt = ago(7_100), closeReason = "replied",
            repliedAt = ago(7_150), repliedText = "Rev C, the one with the blue silkscreen", backend = InterventionBackend.CODEX,
        ),
        Intervention(
            id = "h-3", sessionId = "99999999-4444-dddd-eeee-ffffffffffff", cwd = "/Users/you/projects/orbit-api",
            projectName = "orbit-api", kind = InterventionKind.IDLE, openedAt = ago(20_000),
            context = "Refactor done. Anything else?", closedAt = ago(19_000), closeReason = "user_resolved_in_terminal",
            backend = InterventionBackend.CLAUDE,
        ),
        Intervention(
            id = "h-4", sessionId = "ra7e1111-7777-0000-1111-222222222222", cwd = "/Users/you/projects/docs-site",
            projectName = "docs-site", kind = InterventionKind.RATE_LIMIT, openedAt = ago(90_000),
            context = "Usage limit reached until 3pm.", closedAt = ago(80_000), closeReason = "session_resolved",
            backend = InterventionBackend.CODEX,
        ),
    )

    /**
     * Mixed on purpose: every group, a non-typable host, a local-model
     * backend, and sessions whose pages are in the sample inbox.
     */
    fun sessions(): List<LiveSession> {
        fun s(
            id: String, backend: String, title: String, state: LiveSessionState, host: String,
            canType: Boolean = true, blocker: String? = null, canInterrupt: Boolean = true, provider: String? = "anthropic",
            ago: Long, page: String? = null, preview: String,
        ) = LiveSession(
            id = id, backend = AgentBackend.fromWire(backend), title = title, cwd = "~/projects/$title", state = state,
            host = host, canType = canType, typeBlocker = if (canType) null else blocker, canInterrupt = canInterrupt,
            provider = provider, lastActivityAt = ago(ago), interventionId = page, preview = preview,
        )
        return listOf(
            s("7f3a9c2b-1111-aaaa-bbbb-cccccccccccc", "claude", "acme-web", LiveSessionState.WAITING_ON_APPROVAL, "cmux",
                ago = 12, page = "dev-1", preview = "Bash: npm install bcrypt@5.1.1"),
            s("abcdef12-2222-bbbb-cccc-dddddddddddd", "codex", "nova-firmware", LiveSessionState.WAITING_ON_USER, "VS Code",
                canType = false, blocker = "Page can't type into VS Code yet", canInterrupt = false, provider = "cloudGateway",
                ago = 130, page = "dev-2", preview = "Should I retry the cert download at 9600 baud instead of 38400?"),
            s(ACTIVE_SESSION_ID, "claude", "page-android", LiveSessionState.ACTIVE, "tmux",
                ago = 3, preview = "Bash: ./gradlew :app:assembleDebug test lint"),
            s("0110a4a1-6666-ffff-0000-111111111111", "ollama", "llm-play", LiveSessionState.ACTIVE, "Ghostty",
                canType = false, blocker = "Page can't type into Ghostty yet", canInterrupt = false, provider = "ollama",
                ago = 40, preview = "Edit: src/tokenizer.rs"),
            s("12345678-3333-cccc-dddd-eeeeeeeeeeee", "claude", "helix-mobile", LiveSessionState.WAITING_ON_APPROVAL, "Terminal",
                canType = false, blocker = "Page can't type into Terminal yet", canInterrupt = false,
                ago = 310, page = "dev-3", preview = "4-step plan for the Reply screen is ready"),
            s("99999999-4444-dddd-eeee-ffffffffffff", "claude", "orbit-api", LiveSessionState.IDLE, "iTerm",
                ago = 900, preview = "Finished the migration and all tests pass."),
            s("ra7e1111-7777-0000-1111-222222222222", "codex", "docs-site", LiveSessionState.RATE_LIMITED, "cmux",
                provider = "cloudGateway", ago = 1800, preview = "Rate limited until 3pm"),
        )
    }

    private fun e(id: String, role: TranscriptRole, text: String, ago: Long, tool: String? = null) =
        TranscriptEntry(id, role, text, ago(ago), tool)

    fun transcripts(): List<SessionTranscript> = listOf(
        SessionTranscript(
            ACTIVE_SESSION_ID,
            listOf(
                e("1", TranscriptRole.USER, "Port the phone app to Android with feature parity.", 600),
                e("2", TranscriptRole.ASSISTANT, "I'll start with the models so the logic is testable, then the relay client, then the screens.", 590),
                e("3", TranscriptRole.TOOL, "Read: iOS/Page/Models/LiveSessions.swift", 585, "Read"),
                e("4", TranscriptRole.TOOL, "Write: android/app/src/main/java/app/page/android/model/LiveSession.kt", 400, "Write"),
                e("5", TranscriptRole.ASSISTANT, "Models are in and the AES-GCM test vector passes. Running the full build before touching the UI.", 120),
                e("6", TranscriptRole.USER, "Also check dark mode please", 60),
                e("7", TranscriptRole.TOOL, "Bash: ./gradlew :app:assembleDebug test lint", 3, "Bash"),
            ),
            truncated = true,
        ),
        SessionTranscript(
            "7f3a9c2b-1111-aaaa-bbbb-cccccccccccc",
            listOf(
                e("1", TranscriptRole.USER, "Switch password hashing to bcrypt.", 300),
                e("2", TranscriptRole.ASSISTANT, "I'll add bcrypt and migrate the hash helper.", 280),
                e("3", TranscriptRole.TOOL, "Bash: npm install bcrypt@5.1.1", 12, "Bash"),
                e("4", TranscriptRole.SYSTEM, "Waiting for approval", 12),
            ),
            truncated = false,
        ),
        SessionTranscript(
            "99999999-4444-dddd-eeee-ffffffffffff",
            listOf(
                e("1", TranscriptRole.USER, "Run the migration and fix whatever breaks.", 2400),
                e("2", TranscriptRole.TOOL, "Bash: npm run migrate", 2300, "Bash"),
                e("3", TranscriptRole.TOOL, "Edit: src/db/schema.ts", 1500, "Edit"),
                e("4", TranscriptRole.ASSISTANT, "Finished the migration and all tests pass. Waiting for your next instruction.", 900),
            ),
            truncated = false,
        ),
        // A workflow agent's own transcript (keyed apart from the session's).
        SessionTranscript(
            ACTIVE_SESSION_ID,
            listOf(
                e("a1", TranscriptRole.USER, "Fix the contrast findings in chapter 5 of the design pass.", 900),
                e("a2", TranscriptRole.TOOL, "Read: ui/theme/Theme.kt", 880, "Read"),
                e("a3", TranscriptRole.ASSISTANT, "The light-mode chip text was 3.9:1; darkening the teal to #0F766E brings it to 5.4:1.", 600),
                e("a4", TranscriptRole.TOOL, "Edit: ui/theme/Theme.kt", 590, "Edit"),
            ),
            truncated = false, runId = "wf_5efbb134-a4c", agentId = "a501def47993d54be",
        ),
    )

    fun diff(): SessionDiff = SessionDiff(
        sessionId = ACTIVE_SESSION_ID, clientId = null, scope = "turn", repo = "page",
        files = listOf(
            DiffFile("android/app/src/main/java/app/page/android/ui/theme/Theme.kt", 12, 3, "modified"),
            DiffFile("android/README.md", 40, 0, "added"),
            DiffFile("notes.txt", null, null, "changed"),
        ),
        patch = listOf(
            "diff --git a/android/app/src/main/java/app/page/android/ui/theme/Theme.kt b/android/app/src/main/java/app/page/android/ui/theme/Theme.kt",
            "index 3f2a1c0..9b8e7d1 100644",
            "--- a/android/app/src/main/java/app/page/android/ui/theme/Theme.kt",
            "+++ b/android/app/src/main/java/app/page/android/ui/theme/Theme.kt",
            "@@ -18,9 +18,12 @@ data class PageColors(",
            "     val text: Color,",
            "-    val kindApproval: Color = Color(0xFF14B8A6),",
            "+    // Darker in light mode so 11sp chip text stays above 4.5:1.",
            "+    val kindApproval: Color = Color(0xFF0F766E),",
            "     val kindUserInput: Color,",
            "diff --git a/android/README.md b/android/README.md",
            "new file mode 100644",
            "--- /dev/null",
            "+++ b/android/README.md",
            "@@ -0,0 +1,3 @@",
            "+# Page for Android",
            "+",
            "+Build with ./gradlew :app:assembleDebug",
        ).joinToString("\n"),
        truncated = false, note = null,
    )

    fun folders(): StartFolders = StartFolders(
        clientId = null, enabled = true, agents = listOf("claude"),
        folders = listOf(
            StartFolder("/Users/you/projects/page", "page", ago(300)),
            StartFolder("/Users/you/projects/acme-web", "acme-web", ago(7_200)),
            StartFolder("/Users/you/projects/orbit-api", "orbit-api", ago(90_000)),
        ),
    )

    fun screens(): List<SessionScreen> = listOf(
        SessionScreen(
            ACTIVE_SESSION_ID,
            listOf(
                "● Running the build before touching the UI.",
                "",
                "⏺ Bash(./gradlew :app:assembleDebug test lint)",
                "  ⎿  > Task :app:testDebugUnitTest",
                "     BUILD SUCCESSFUL in 1m 12s",
                "     58 tests completed, 0 failed",
                "",
                "────────────────────────────────────────────────────────────────────────",
                "❯ ",
                "────────────────────────────────────────────────────────────────────────",
                "  ⏵⏵ auto mode on (shift+tab to cycle) · 1 shell · ctrl+t to hide todos",
                "  ○ design-pass-ch1-8-opus        28/30 · 2h34m · 6.3m tokens",
                "  ○ finish-act-opus                0/1 · 4m",
            ),
            Instant.now(),
        ),
    )

    fun workflows(): Map<String, List<WorkflowRun>> {
        val now = Instant.now()
        return mapOf(
            ACTIVE_SESSION_ID to listOf(
                WorkflowRun(
                    id = "wf_5efbb134-a4c", name = "design-pass-ch1-8-opus",
                    summary = "Review chapters 1–8 of the design spec for contrast, spacing and copy; fix what's found.",
                    status = "running", phase = "Fix B", done = 28, total = 30,
                    startedAt = now.minusSeconds(9_240), tokens = 6_300_000,
                    agents = listOf(
                        WorkflowRun.Agent("a501def47993d54be", "ch5: fix contrast findings", "Fix B", "running", now.minusSeconds(10)),
                        WorkflowRun.Agent("a502", "ch7: fix spacing findings", "Fix B", "running", now.minusSeconds(45)),
                        WorkflowRun.Agent("a503", "ch3: review copy", "Review", "failed", now.minusSeconds(3_000)),
                        WorkflowRun.Agent("a504", "ch1: review", "Review", "done", now.minusSeconds(8_000)),
                        WorkflowRun.Agent("a505", "ch2: review", "Review", "done", now.minusSeconds(7_800)),
                    ),
                ),
                WorkflowRun(
                    id = "wf_7a1c", name = "finish-act-opus", status = "running", phase = "Draft",
                    done = 0, total = 1, startedAt = now.minusSeconds(240),
                    agents = listOf(WorkflowRun.Agent("b1", "act 3: draft", "Draft", "running", now.minusSeconds(5))),
                ),
                WorkflowRun(
                    id = "wf_0ld", name = "lint-sweep", status = "completed", done = 12, total = 12,
                    startedAt = now.minusSeconds(30_000), endedAt = now.minusSeconds(28_000), tokens = 985_100,
                ),
            ),
        )
    }
}
