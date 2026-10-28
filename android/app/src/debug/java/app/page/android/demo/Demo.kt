package app.page.android.demo

import android.os.Bundle
import app.page.android.data.ActionCoordinator
import app.page.android.data.ActivityStore
import app.page.android.data.AppRouter
import app.page.android.data.AwayStore
import app.page.android.data.CardGlowStore
import app.page.android.data.NowStore
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.data.StopCoordinator
import app.page.android.data.TipStore
import app.page.android.model.Absence
import app.page.android.model.Base64Url
import app.page.android.model.CardGlow
import app.page.android.model.Intervention
import app.page.android.model.InterventionKind
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.MacStatusSnapshot
import app.page.android.model.NowModel
import app.page.android.model.NowRowBuilder
import app.page.android.model.PairedMac
import app.page.android.model.PendingAction
import app.page.android.model.RoomEntry
import app.page.android.model.RowAction
import app.page.android.model.StopFlowPhase
import app.page.android.model.StopOutcome
import app.page.android.model.TipBook
import app.page.android.model.TowerSection
import app.page.android.model.ValidatedPairing
import app.page.android.ui.nw.shell.RenderHarness
import app.page.android.ui.nw.theme.NWMotionPin
import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Debug-only demo mode and render harness (the Android side of iOS DevBypass.swift and RenderHarness.swift):
 * fills the app with sample pages, history, live sessions, transcripts and a terminal screen, so every screen can
 * be seen without a Mac. It never writes credentials, starts the background connection or touches the network,
 * and a relaunch returns to the pairing screen.
 *
 * Scriptable (android/tools/screens.sh does this for every screen in [screens]):
 * `adb shell am start -S -W -n app.page.android.debug/app.page.android.MainActivity --ez page_demo true
 *   --es page_render <screen> [--es page_glow off|subtle|full] [--ef page_time <seconds>] [--ez page_canvas true]
 *   [--es page_daytime <earlyMorning|morning|afternoon|nighttime|HH:MM|minute>]`
 * `page_render` pins the aurora phase (default 2.0 s, or `page_time`) and the clock (Tue 27 Oct 2026, 01:12 UTC)
 * so a screen is the same every time; without it the demo is live. `page_daytime` (or `page_daypart`) pins the time
 * of day the skies are drawn at, as a local minute ([RenderHarness.minuteOfDay]); without it they are drawn at 01:12. On a `motion-*` screen `page_time` is the
 * seconds into that signature motion ([DemoMotion]; android/tools/render-motion.sh builds the contact sheets).
 * `page_canvas` draws with the Canvas fallbacks a device below Android 13 gets, instead of the AGSL shaders, and
 * `page_noblur` the Canvas aurora as a device below Android 12 draws it (no blur).
 */
object Demo {
    const val available = true

    /** Every screen name, in the order the render script captures them (the same names as iOS RenderHarness.screens). */
    val screens = listOf(
        "now", "now-quiet", "now-still", "now-working", "now-dusk", "now-brief", "now-brief-quiet", "now-arming", "now-swipe",
        "now-receipt", "now-banner", "now-new",
        "now-inflight", "now-inflight-long", "now-tip-undoable", "now-tip-irreversible", "now-tip-inflight",
        "now-flight", "now-flight-two", "now-flight-old", "now-flight-header", "now-flight-jump", "now-flight-quiet",
        "decision-irreversible", "decision-hold", "decision-considered", "decision-undoable", "decision-question", "decision-stuck",
        "decision-review", "decision-yesno", "decision-plan", "decision-standing", "decision-unknown", "decision-composer", "decision-delivered",
        "decision-failed", "decision-tip",
        "hold-stop", "stop-confirm", "stop-result", "stop-none",
        "lanes", "lanes-crowded", "lanes-empty", "lanes-problem", "lanes-paused",
        "tower", "tower-budget", "tower-glow", "tower-terminals", "tower-gestures",
        "dispatch", "dispatch-sending", "dispatch-off",
        "runway", "settled", "gallery", "glow-compare",
        "room-story", "room-screen", "room-changes", "room-workflows", "room-waiting", "room-codex", "room-local", "room-agent",
        "room-workflows-running", "room-workflows-finish", "room-workflows-complete", "room-workflows-done", "room-agent-live",
        "room-yesno", "room-yesno-busy", "room-ended", "room-blocked", "room-stop", "room-draft", "room-receipt", "room-receipt-refused",
        "room-choice", "room-choice-quiet", "room-codex-hold", "room-countdown", "room-held", "room-held-note", "room-yesno-arm",
        "room-photos", "room-photos-1", "room-photos-path", "room-photos-busy", "room-photos-blocked", "room-photos-uploading", "room-photos-sent",
        "decision-queued", "decision-held",
        "welcome", "welcome-notice", "scan", "scan-hint", "pair-checking", "pair-confirm", "pair-problem", "paired", "paired-denied",
        "problem-asleep", "problem-gone", "problem-stale", "problem-relay", "problem-pairing",
        "widgets",
        "ask-story-q1", "ask-story-q2", "ask-story-other", "ask-story-review", "ask-story-sending", "ask-story-refused", "ask-story-refused-terminal", "ask-story-iterm", "ask-story-terminal",
        "ask-story-answered", "ask-screen", "ask-screen-review", "ask-decision", "ask-hook-q2", "ask-hook-review",
        "motion-pulse-quiet", "motion-pulse-working", "motion-pulse-waiting1", "motion-pulse-waiting3", "motion-pulse-exhale",
        "motion-approach",
        "motion-receipt-arm", "motion-receipt-sending", "motion-receipt-sent", "motion-receipt-typed", "motion-receipt-verified",
        "motion-receipt-fold", "motion-receipt-failed", "motion-receipt-sheet",
        "motion-hold", "motion-hold-burst",
        "motion-dusk", "motion-dawn", "motion-dusk-now", "motion-dawn-now", "motion-brief",
        "history", "history-stats", "history-empty", "history-loading", "history-failed", "history-large", "history-stats-large",
        "gallery-lower",
    )

    /** Screens drawn outside the shell (components on their own). */
    private fun isStandalone(screen: String) = screen in setOf("gallery", "gallery-lower", "glow-compare", "runway", "settled", "widgets") || screen.startsWith("room-") || screen.startsWith("ask-") || isUnpaired(screen) || DemoMotion.isStandalone(screen)

    /** Screens with no Mac paired (the first-run flow). */
    private fun isUnpaired(screen: String) = screen.startsWith("welcome") || screen.startsWith("scan") || screen.startsWith("pair") || screen == "paired" || screen == "paired-denied"

    /** The default demo (the pairing screen's "Try the demo"): the board scenario, live. */
    @OptIn(kotlinx.coroutines.DelicateCoroutinesApi::class)
    fun start() {
        // Never over a real pairing: seeding resets the relay client, which would clear the real session key.
        if (PairingStore.isPaired && !PairingStore.isDemoPairing) return
        // The fixtures' timestamps are on the harness clock; live, the Mac's status is stamped against the real one
        // and kept fresh, or the demo opens on "Studio MBP stopped checking in".
        seed(
            open = DemoFixtures.openAt(Instant.now()), status = DemoFixtures.statusAt(Instant.now()), sessions = DemoFixtures.sessionsWithFlight,
        )
        kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.Main) {
            while (PairingStore.isDemoPairing) {
                delay(60_000)
                if (PairingStore.isDemoPairing) RelayClient.seedDemoStatus(DemoFixtures.statusAt(Instant.now()))
            }
        }
    }

    /** The fixture pages as real notifications, plus the live one, for looking at them in the shade. */
    private fun postDemoNotifications() {
        val ctx = app.page.android.data.AppGraph.app
        app.page.android.notify.PageNotifications.createChannels(ctx)
        for (iv in DemoFixtures.open) app.page.android.notify.PageNotifications.post(app.page.android.notify.PageInfo.of(iv), silent = true, status = null)
        val nm = androidx.core.app.NotificationManagerCompat.from(ctx)
        val screen = NowStore.screen.value
        val off = android.app.PendingIntent.getActivity(ctx, 1, android.content.Intent(), android.app.PendingIntent.FLAG_IMMUTABLE)
        val n = app.page.android.notify.LiveNotification.build(
            ctx, app.page.android.notify.PageNotifications.CHANNEL_CONNECTION,
            app.page.android.notify.LiveNotification.status(screen.model.headline, screen.model.subline, screen.model.runway, true), off,
        )
        @Suppress("MissingPermission") nm.notify(42, n)
    }

    private fun seed(open: List<Intervention>, status: MacStatusSnapshot?, sessions: List<LiveSession>) {
        PairingStore.adoptDemo(PairedMac(DemoFixtures.mac, DemoFixtures.now.minusSeconds(26 * 86_400)))
        RelayClient.seedDemoInbox(open)
        RelayClient.seedDemoHistory(DemoFixtures.history)
        status?.let { RelayClient.seedDemoStatus(it) }
        // Sessions are seeded after the inbox, whose reset clears them.
        SessionStore.seedDemo(DemoFixtures.mac, sessions, DemoFixtures.transcripts(), DemoFixtures.screens(), DemoFixtures.workflows())
        SessionStore.seedDemoExtras(sessions.associate { it.id to DemoFixtures.diff(it.id) }, DemoFixtures.folders)
    }

    fun handleLaunchExtras(extras: Bundle?) {
        // Exercises the real, non-demo path (Keystore, adopt, socket failure, Stay connected) against a relay that
        // can't resolve. Unpaired only.
        if (extras?.getBoolean("page_test_pair") == true && !PairingStore.isPaired) {
            val random = java.security.SecureRandom()
            val token = Base64Url.encode(ByteArray(32).also(random::nextBytes))
            PairingStore.adopt(ValidatedPairing(token, "https://relay.invalid", "Test Mac", ByteArray(32).also(random::nextBytes)))
            return
        }
        if (extras?.getBoolean("page_demo") != true) return
        if (extras.getBoolean("page_notify")) {
            // Posts the board-34 notifications for the fixture pages (a debug aid for looking at the shade).
            start()
            postDemoNotifications()
            return
        }
        if (extras.getBoolean("page_live_motion")) {
            // The signature motions on their real, unpinned paths (android/tools/render-motion.sh --live records it).
            start()
            if (extras.getString("page_live_script") == "arrivals") liveArrivals() else liveMotion()
            // On Lanes instead, to see its power story (and that nothing redraws while a pause holds still).
            if (extras.getBoolean("page_live_lanes")) AppRouter.selectDestination(app.page.android.model.NWDestination.LANES)
            return
        }
        val render = extras.getString("page_render")
        if (render == null) {
            start()
            return
        }
        app.page.android.ui.nw.components.NWShaders.forceCanvas = extras.getBoolean("page_canvas")
        app.page.android.ui.nw.components.NWShaders.forceNoBlur = extras.getBoolean("page_noblur")
        renderScreen(
            render, CardGlow.argument(extras.getString("page_glow")) ?: CardGlow.OFF, if (extras.containsKey("page_time")) extras.getFloat("page_time").toDouble() else null,
            RenderHarness.minuteOfDay(extras.getString("page_daytime") ?: extras.getString("page_daypart")),
        )
    }

    /**
     * A scripted run of the live demo that plays the signature motions through the real app paths, not the harness
     * pins: the swipe-to-run page is approved (its arm, the demo relay's sent and confirmed, the fold), a page arrives
     * (Final approach), the last decisions clear (the exhale), the battery cutoff falls (dusk) and power comes back
     * (dawn). Times are seconds after launch.
     */
    @OptIn(kotlinx.coroutines.DelicateCoroutinesApi::class)
    private fun liveMotion() {
        val o = DemoFixtures.open
        val paused = DemoFixtures.iv("pz", "bottle-flip", app.page.android.model.InterventionKind.IDLE, "Page paused your agents at 10% battery.", 5, sub = "low_battery")
        // The fixtures' heartbeat is on the harness clock; live, the Mac must look present or the Horizon goes hollow.
        fun beat() = RelayClient.seedDemoStatus(DemoFixtures.status.copy(macConnected = true, lastHeartbeatAt = Instant.now()))
        beat()
        RelayClient.replaceDemoInbox(listOf(o[1], o[2], o[3]))
        kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.Main) {
            delay(2_000)
            NowStore.screen.value.rows.firstOrNull { it.id == "p2" }?.let { ActionCoordinator.begin(it, RowAction.Kind.APPROVE) }
            delay(5_000)
            beat()
            // p2 was answered and has gone; p1 arrives.
            RelayClient.replaceDemoInbox(listOf(o[0], o[2], o[3]))
            delay(4_000)
            beat()
            RelayClient.replaceDemoInbox(listOf(o[3]))
            delay(3_000)
            beat()
            RelayClient.replaceDemoInbox(listOf(o[3], paused))
            delay(3_500)
            beat()
            RelayClient.replaceDemoInbox(listOf(o[3]))
        }
    }

    /**
     * Arrivals on the real path: the first page into an empty, quiet stream (the Horizon gives up its room as the card
     * comes down), then a second page while a finger is on the stream (android/tools/live-motion.sh --arrivals holds
     * one down), which waits behind the "New" pill until it is tapped.
     */
    @OptIn(kotlinx.coroutines.DelicateCoroutinesApi::class)
    private fun liveArrivals() {
        val o = DemoFixtures.open
        fun beat() = RelayClient.seedDemoStatus(DemoFixtures.status.copy(macConnected = true, lastHeartbeatAt = Instant.now()))
        beat()
        RelayClient.replaceDemoInbox(emptyList())
        kotlinx.coroutines.GlobalScope.launch(kotlinx.coroutines.Dispatchers.Main) {
            delay(3_000)
            beat()
            RelayClient.replaceDemoInbox(listOf(o[0]))
            delay(4_500)
            beat()
            RelayClient.replaceDemoInbox(listOf(o[0], o[1]))
        }
    }

    // region The render harness

    private fun inboxFor(screen: String): List<Intervention> {
        val o = DemoFixtures.open
        return when {
            screen in setOf("now-flight", "now-flight-two", "now-flight-old", "now-flight-header", "now-flight-jump", "now-inflight", "now-tip-irreversible") -> listOf(o[0])
            screen in setOf("now-inflight-long", "now-tip-undoable") -> listOf(o[1])
            screen in setOf("now-quiet", "now-still", "now-brief-quiet", "now-working", "now-flight-quiet", "now-tip-inflight") -> emptyList()
            screen.startsWith("problem-") || screen == "lanes-empty" -> emptyList()
            screen == "lanes-paused" -> listOf(DemoFixtures.iv("pz", "bottle-flip", InterventionKind.IDLE, "Page paused your agents at 10% battery.", 600, sub = "low_battery"))
            screen == "now-dusk" -> listOf(DemoFixtures.iv("pz", "bottle-flip", InterventionKind.IDLE, "Page paused your agents at 10% battery.", 600, sub = "low_battery"))
            screen.startsWith("decision") -> o + listOfNotNull(DemoFixtures.page(screen).takeIf { p -> o.none { it.id == p.id } })
            else -> o
        }
    }

    private fun statusFor(screen: String): MacStatusSnapshot {
        val st = DemoFixtures.status
        val now = DemoFixtures.now
        return when (screen) {
            "now-quiet", "now-still", "now-brief-quiet" -> st.copy(working = 0, forecast = null, usage = null, onAC = true)
            "now-working", "now-flight-quiet", "now-tip-inflight" -> st.copy(onAC = true, forecast = null)
            "problem-asleep", "now-banner" -> st.copy(macConnected = false, lastHeartbeatAt = now.minusSeconds(1_500))
            "problem-gone" -> st.copy(macConnected = false, lastHeartbeatAt = now.minusSeconds(3 * 3600 + 600), onAC = false, battery = 12)
            "problem-stale" -> st.copy(macConnected = true, lastHeartbeatAt = now.minusSeconds(8 * 60))
            "lanes-empty" -> st.copy(working = 0)
            else -> st
        }
    }

    private fun sessionsFor(screen: String): List<LiveSession> = when {
        screen == "lanes-empty" || screen == "stop-none" -> emptyList()
        screen == "lanes-crowded" -> DemoFixtures.crowdedSessions
        screen in setOf("now-quiet", "now-brief-quiet", "now-working") -> DemoFixtures.sessions.filter { it.state != LiveSessionState.WAITING_ON_APPROVAL }
        // Truly quiet: nothing running and nothing waiting, so the Horizon draws the quiet sky (now-quiet keeps its working sessions).
        screen == "now-still" -> DemoFixtures.sessions.filter { it.state != LiveSessionState.ACTIVE && it.state != LiveSessionState.WAITING_ON_APPROVAL }
        screen.startsWith("now") -> DemoFixtures.nowSessions(screen)
        screen.startsWith("problem-") -> DemoFixtures.sessions
        else -> DemoFixtures.sessionsWithFlight
    }

    private fun renderScreen(asked: String, glow: CardGlow, time: Double?, dayTime: Double?) {
        // A motion screen is drawn on its base screen's fixtures, with the motion pinned (DemoMotion).
        val motion = asked
        val screen = if (DemoMotion.isMotion(asked)) DemoMotion.base(asked) else asked
        val phase = DemoMotion.phase(asked, time)
        val pin: NWMotionPin? = DemoMotion.pin(asked, time)
        RenderHarness.standalone = { name -> standalone(name, time) }
        CardGlowStore.overrideForRender(glow)
        TipStore.overrideForRender(TipBook())
        NowStore.clock = { DemoFixtures.now }
        NowStore.zone = DemoFixtures.zone
        val jumpTop = if (screen in setOf("now-flight", "now-flight-old", "now-flight-jump", "now-inflight", "now-tip-inflight", "now-flight-two", "now-flight-header", "now-flight-quiet", "now-inflight-long", "now-working")) "section-in flight" else null
        val scrollTo = when (screen) {
            "now-swipe", "now-receipt", "now-tip-undoable" -> "row-p2"
            "now-arming" -> "row-p2"
            else -> null
        }
        RenderHarness.set(
            RenderHarness.Spec(
                motion, glow, phase, DemoFixtures.now, pin, scrollTo = DemoMotion.scrollTo(motion) ?: scrollTo,
                scrollTop = DemoMotion.scrollTop(motion) ?: (if (screen == "now-working") null else if (screen == "now-brief") "brief" else jumpTop),
                pinnedArrival = DemoMotion.pinnedArrival(motion), ghosts = DemoMotion.ghosts(motion),
                dragDp = if (screen == "now-swipe") 84f else null, queuedNew = if (screen == "now-new") 1 else 0,
                hold = if (screen == "now-hold" || screen == "decision-hold") 0.55 else null, dispatchSending = screen == "dispatch-sending",
                lanesAvailability = if (screen == "lanes-problem") app.page.android.model.SessionAvailability.NeedsRepair(keyMismatch = false) else null,
                dayTime = dayTime,
            ),
        )
        if (isStandalone(motion) || isUnpaired(screen)) return

        val open = DemoMotion.inbox(motion) ?: inboxFor(screen)
        seed(open, statusFor(screen), DemoMotion.sessions(motion) ?: sessionsFor(screen))
        ActivityStore.overridePowerForRender(DemoMotion.power(motion))
        val extra: Map<String, app.page.android.model.ReplyDelivery> = when (screen) {
            "decision-delivered" -> mapOf("p1" to app.page.android.model.ReplyDelivery.Delivered("typed into tmux pane %3"))
            "decision-failed" -> mapOf("p1" to app.page.android.model.ReplyDelivery.Failed("The Mac didn't confirm in time. Check the session before answering again."))
            "decision-queued" -> mapOf("p4" to app.page.android.model.ReplyDelivery.Sent(true, DemoFixtures.now.minusSeconds(40)))
            "decision-held" -> mapOf("rl1" to app.page.android.model.ReplyDelivery.HeldOnMac("Will send it when the limit resets at 3:00 PM"))
            else -> emptyMap()
        }
        val receipt = DemoMotion.receipt(motion, DemoMotion.time(motion, time), open.firstOrNull { it.id == "p2" }?.let { NowRowBuilder.row(it, null, DemoFixtures.mac).action(RowAction.Kind.APPROVE)?.preview })
        RelayClient.seedDemoDeliveries(
            mapOf("h1" to app.page.android.model.ReplyDelivery.Delivered(null)) + extra + (receipt?.deliveries ?: emptyMap()),
            mapOf("h1" to DemoFixtures.now.minusSeconds(12 * 60)) + extra.mapValues { DemoFixtures.now.minusSeconds(30) } + (receipt?.times ?: emptyMap()),
        )
        receipt?.pending?.takeIf { it.isNotEmpty() }?.let { ActionCoordinator.seedForRender(it) }
        if (screen == "dispatch-off") SessionStore.seedDemoExtras(emptyMap(), DemoFixtures.folders.copy(enabled = false))
        ActivityStore.overrideForRender(DemoFixtures.activity)
        AppRouter.reset()
        when (screen) {
            "problem-relay" -> RelayClient.seedDemoProblem(inboxLoad = RelayClient.LoadState.Failed("The relay didn't answer."), connection = RelayClient.ConnectionState.DISCONNECTED)
            "problem-pairing" -> RelayClient.seedDemoProblem(authRejected = true)
            "history-empty" -> RelayClient.seedDemoHistory(emptyList())
            "history-loading" -> { RelayClient.seedDemoHistory(emptyList()); RelayClient.seedDemoProblem(historyLoad = RelayClient.LoadState.Loading) }
            "history-failed" -> { RelayClient.seedDemoHistory(emptyList()); RelayClient.seedDemoProblem(historyLoad = RelayClient.LoadState.Failed("The network connection was lost.")) }
        }
        // The tapped state of some screens.
        val rows = open.map { NowRowBuilder.row(it, null, DemoFixtures.mac) }
        when {
            // A productive night (as iOS's motion-brief), so the sunrise is drawn at its brightest.
            motion == "motion-brief" -> AwayStore.overrideForRender(Absence(DemoFixtures.now.minusSeconds(18 * 3600), DemoFixtures.now))
            else -> when (screen) {
            "now-brief" -> AwayStore.overrideForRender(Absence(DemoFixtures.now.minusSeconds(13 * 3600 + 5 * 60), DemoFixtures.now))
            "now-brief-quiet" -> AwayStore.overrideForRender(Absence(DemoFixtures.now.minusSeconds(13 * 3600 + 5 * 60), DemoFixtures.now))
            else -> AwayStore.overrideForRender(null)
            }
        }
        if (screen == "now-arming") {
            rows.firstOrNull { it.chip == app.page.android.model.ChipKind.CONSIDERED || it.chip == app.page.android.model.ChipKind.UNDOABLE }?.let { r ->
                ActionCoordinator.seedForRender(mapOf(r.id to PendingAction(r.id, RowAction.Kind.APPROVE, "", r.commit, DemoFixtures.now.minusMillis(500), true, r.action(RowAction.Kind.APPROVE)?.preview)))
            }
        }
        if (screen == "now-receipt") {
            rows.firstOrNull { it.section == app.page.android.model.NowRow.Section.REVIEW }?.let { r ->
                ActionCoordinator.seedForRender(emptyMap(), mapOf(r.id to "Didn't confirm in time · Check on Mac"))
            }
        }
        // Where the screen sits.
        when {
            screen.startsWith("lanes") -> AppRouter.selectDestination(app.page.android.model.NWDestination.LANES)
            screen.startsWith("decision") -> AppRouter.open(DemoFixtures.page(screen).id)
            screen.startsWith("tower") -> AppRouter.openTower(
                when (screen) { "tower-budget" -> TowerSection.BUDGET; "tower-glow" -> TowerSection.APPEARANCE; "tower-terminals" -> TowerSection.TERMINALS; "tower-gestures" -> TowerSection.GESTURES; else -> null },
            )
            screen.startsWith("dispatch") -> AppRouter.openDispatch()
            screen.startsWith("history") -> AppRouter.openHistory()
            screen.startsWith("room-") || screen.startsWith("ask-") ->
                AppRouter.openSession("w1", when (screen) { "room-screen", "ask-screen", "ask-screen-review" -> RoomEntry.SCREEN; "room-draft" -> RoomEntry.TYPE; "room-stop" -> RoomEntry.STOP; else -> RoomEntry.STORY })
        }
        when (screen) {
            "hold-stop" -> RenderHarness.pinHeld(0.3 + 0.7 * 1.2)
            "stop-confirm" -> StopCoordinator.overrideForRender(StopFlowPhase.Authenticating)
            "stop-result" -> StopCoordinator.overrideForRender(StopFlowPhase.Result(StopOutcome.Asked))
            "stop-none" -> StopCoordinator.overrideForRender(StopFlowPhase.Result(StopOutcome.NothingBusy))
        }
    }

    /** The screens drawn outside the shell. */
    private fun standalone(screen: String, time: Double?): (@androidx.compose.runtime.Composable () -> Unit)? = when (screen) {
        "motion-hold", "motion-hold-burst" -> ({ DemoMotion.Hold(screen, DemoMotion.time(screen, time)) })
        "gallery" -> ({ DemoGallery() })
        "gallery-lower" -> ({ DemoGallery(lower = true) })
        "glow-compare" -> ({ DemoGlowCompare() })
        "runway" -> ({ DemoRunway() })
        "settled" -> ({ DemoSettled() })
        "widgets" -> ({ DemoGallery(widgetsPlaceholder = true) })
        else -> when {
            screen.startsWith("room-") -> ({ DemoRooms.Room(screen) })
            screen.startsWith("ask-") -> ({ DemoRooms.Ask(screen) })
            isUnpaired(screen) -> ({ DemoOnboarding.Screen(screen) })
            else -> null
        }
    }

    // endregion
}
