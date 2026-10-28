package app.page.android.demo

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.page.android.model.DuskDawnLog
import app.page.android.model.FlightGraceBook
import app.page.android.model.InFlightSection
import app.page.android.model.HoldRingSpec
import app.page.android.model.Intervention
import app.page.android.model.InterventionKind
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.MacStatusSnapshot
import app.page.android.model.NowInputs
import app.page.android.model.NowModel
import app.page.android.model.NowMotion
import app.page.android.model.SettledLog
import app.page.android.model.PendingAction
import app.page.android.model.ReplyDelivery
import app.page.android.model.RowAction
import app.page.android.model.CommitGesture
import app.page.android.model.WorkflowBrief
import app.page.android.model.WorkflowRun
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWDeliveryPreview
import app.page.android.ui.nw.components.NWHoldRing
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.NWMotionPin
import java.time.Instant

/**
 * The signature motions, one moment at a time, for the render harness (iOS RenderHarnessMotion.swift):
 * `--es page_render motion-<name> --ef page_time <seconds>` draws the real screen (the shell, Now, Lanes, the Decision
 * sheet) with that motion pinned `seconds` in, so a contact sheet can be built frame by frame
 * (android/tools/render-motion.sh). In-memory fixtures only, like the rest of the harness.
 */
object DemoMotion {
    fun isMotion(screen: String) = screen.startsWith("motion-")

    /** The board's moment for each screen, when `page_time` is not given (the same as iOS). */
    fun defaultTime(screen: String): Double = when (screen) {
        "motion-approach" -> 0.18
        "motion-pulse-exhale" -> 0.4
        "motion-receipt-arm" -> 0.6
        "motion-receipt-sending" -> 0.3
        "motion-receipt-sent" -> 0.8
        "motion-receipt-typed" -> 0.45
        "motion-receipt-verified", "motion-receipt-sheet" -> 0.95
        "motion-receipt-fold" -> 1.25
        "motion-receipt-failed" -> 0.12
        "motion-hold" -> 0.9
        "motion-hold-burst" -> 0.2
        "motion-dusk", "motion-dusk-now" -> 0.8
        "motion-dawn", "motion-dawn-now" -> 1.2
        "motion-brief" -> 0.9
        "motion-inflight-enter" -> 0.6
        "motion-inflight-advance", "motion-inflight-complete", "motion-inflight-vanish" -> 2.5
        "motion-now-enter", "motion-now-enter-review" -> 0.35
        "motion-now-change", "motion-now-change-settled" -> 2.2
        else -> 3.0
    }

    fun time(screen: String, given: Double?): Double = given ?: defaultTime(screen)

    /** The aurora's and the pulse's clock: the pinned time for a motion screen (so its ripples sit where the board's do), else `page_time` or 2 s. */
    fun phase(screen: String, given: Double?): Double = if (isMotion(screen)) time(screen, given) else (given ?: 2.0)

    /** Which motion the pinned time belongs to. The pulses run on the phase, the receipts on the fixed clock, so they get none. */
    fun pin(screen: String, given: Double?): NWMotionPin? {
        val t = time(screen, given)
        return when (screen) {
            "motion-approach" -> NWMotionPin(NWMotionPin.Kind.APPROACH, t)
            "motion-pulse-exhale" -> NWMotionPin(NWMotionPin.Kind.EXHALE, t)
            "motion-hold-burst" -> NWMotionPin(NWMotionPin.Kind.HOLD, t)
            "motion-dusk", "motion-dusk-now" -> NWMotionPin(NWMotionPin.Kind.DUSK, t)
            "motion-dawn", "motion-dawn-now" -> NWMotionPin(NWMotionPin.Kind.DAWN, t)
            "motion-brief" -> NWMotionPin(NWMotionPin.Kind.BRIEF, t)
            else -> if (isFlight(screen)) NWMotionPin(NWMotionPin.Kind.FLIGHT, t) else if (isNow(screen)) NWMotionPin(NWMotionPin.Kind.NOW, t) else null
        }
    }

    /** Drawn outside the shell (the hold ring, centred as the Decision sheet draws it). */
    fun isStandalone(screen: String) = screen == "motion-hold" || screen == "motion-hold-burst"

    /** The ordinary harness screen whose fixtures a motion screen starts from. */
    fun base(screen: String): String = when (screen) {
        "motion-dusk-now" -> "now-dusk"
        "motion-brief" -> "now-brief-quiet"
        "motion-receipt-sheet" -> "decision-considered"
        "motion-dusk", "motion-dawn" -> "lanes"
        else -> if (isFlight(screen)) "now-inflight" else "now"
    }

    private fun idle(s: LiveSession) = if (s.state == LiveSessionState.ACTIVE || s.state == LiveSessionState.WAITING_ON_APPROVAL) s.copy(state = LiveSessionState.IDLE) else s
    private val working: List<LiveSession> get() = DemoFixtures.sessions.filter { it.state != LiveSessionState.WAITING_ON_APPROVAL }

    /** Who has been seen working again since power came back, in order (seconds after the dawn). */
    private val resumes = listOf("w1" to 0.3, "w5" to 0.5, "w2" to 1.1)

    /** The open pages a motion screen draws [time] seconds in, or null for its base screen's. */
    fun inbox(screen: String, time: Double = 0.0): List<Intervention>? {
        val o = DemoFixtures.open
        if (isNow(screen)) return nowInbox(screen, time)
        return when (screen) {
            "motion-pulse-quiet", "motion-pulse-working", "motion-pulse-exhale", "motion-dawn-now" -> emptyList()
            "motion-pulse-waiting1" -> listOf(o[0])
            // Three decisions (the stock fixture's third page is a Look), so the headline says "3 need you" over the
            // three rings the pulse draws for them.
            "motion-pulse-waiting3" -> listOf(o[0], o[1], DemoFixtures.iv("p5", "sate-t", InterventionKind.APPROVAL, "[Bash] pio run -t upload\nFlash the board", 90, session = "w2"))
            // Paused for battery: the Mac's low-battery page is what pauses the fleet.
            "motion-dusk" -> o + DemoFixtures.iv("pz", "bottle-flip", InterventionKind.IDLE, "Page paused your agents at 10% battery.", 30, sub = "low_battery")
            "motion-dawn" -> o
            else -> null
        }
    }

    /** The live sessions a motion screen draws [time] seconds in, or null for its base screen's. */
    fun sessions(screen: String, time: Double = 0.0): List<LiveSession>? = if (isFlight(screen)) flightSessions(screen, time) else if (isNow(screen)) nowSessions(screen) else when (screen) {
        "motion-pulse-quiet" -> DemoFixtures.sessions.map(::idle)
        "motion-pulse-working", "motion-pulse-exhale", "motion-dawn-now", "motion-pulse-waiting1", "motion-pulse-waiting3" -> working
        "motion-dusk" -> DemoFixtures.sessions
        // The rest have not confirmed a resume yet: they stay dim, and say so by being idle.
        "motion-dawn" -> resumes.map { it.first }.toSet().let { back -> DemoFixtures.sessions.map { if (it.state == LiveSessionState.ACTIVE && it.id !in back) it.copy(state = LiveSessionState.IDLE) else it } }
        else -> null
    }

    // region In flight in motion

    /** The In flight motion screens: Now scrolled to In flight, its section scripted ([flightScript]) and pinned by time. */
    fun isFlight(screen: String) = screen.startsWith("motion-inflight-")

    /** When the scripted change happens: a count moves, the NOW step changes, a workflow ends or vanishes. */
    private const val FLIGHT_CHANGE = 2.0

    /** w1 at work with its steps (the last is the NOW step), and the working sessions around it. */
    private fun flightSessions(screen: String, time: Double): List<LiveSession> {
        val base = DemoFixtures.sessionsWithFlight
        fun pick(vararg ids: String) = ids.mapNotNull { id -> base.firstOrNull { it.id == id } }
        if (screen == "motion-inflight-stuck") return pick("sess-p3", "w2")
        val advanced = (screen == "motion-inflight-advance" && time >= FLIGHT_CHANGE) || (screen == "motion-inflight-live" && time >= 4.0)
        val steps = listOf("Reading Session.swift", "Editing SessionRoom.swift", "Running swift build") + (if (advanced) listOf("Running swift test") else emptyList())
        // The list's summaries follow the runs, as a Mac's do (it lists the running ones).
        val briefs = (workflows(screen, time)?.get("w1") ?: emptyList()).filter { it.isRunning }.map { WorkflowBrief(it.name, it.phase, it.done, it.total, "running") }
        return pick("sess-p1", "w1", "w2").map { s ->
            if (s.id == "w1") s.copy(flight = s.flight?.copy(recentSteps = steps, workflows = briefs, workflowsRunning = briefs.size.takeIf { it > 0 })) else s
        }
    }

    /** The runs behind the cards' workflow lines [time] seconds in, with stable ids, or null for the base screen's. */
    fun workflows(screen: String, time: Double): Map<String, List<WorkflowRun>>? {
        if (!isFlight(screen)) return null
        val now = DemoFixtures.now
        val review = WorkflowRun(id = "wf_review", name = "Review changes", status = "running", phase = "Reviewing", done = 3, total = 5, startedAt = now.minusSeconds(600))
        val docs = WorkflowRun(id = "wf_docs", name = "Docs sweep", status = "running", phase = "Writing", done = 1, total = 4, startedAt = now.minusSeconds(420))
        val after = time >= FLIGHT_CHANGE
        return when (screen) {
            // w1's 3/5 line becomes 4/5.
            "motion-inflight-advance" -> mapOf("w1" to listOf(if (after) review.copy(done = 4) else review, docs))
            // The 1/4 line ends done (the Mac lists finished runs after the running ones).
            "motion-inflight-complete" -> mapOf("w1" to if (after) listOf(review, docs.copy(status = "completed", done = 4, endedAt = now)) else listOf(review, docs))
            // The 1/4 line disappears with no word of how it ended: nothing may celebrate it.
            "motion-inflight-vanish" -> mapOf("w1" to if (after) listOf(review) else listOf(review, docs))
            // A stuck session with a running workflow: its arc must hold still.
            "motion-inflight-stuck" -> mapOf("sess-p3" to listOf(WorkflowRun(id = "wf_fix", name = "Fix tests", status = "running", phase = "Fixing", done = 2, total = 6, startedAt = now.minusSeconds(900))))
            // The live script (seconds after launch): 4/5 at 4 s, the docs run finishes at 8 s, the review run vanishes at 14 s.
            "motion-inflight-live" -> mapOf(
                "w1" to when {
                    time >= 14.0 -> listOf(docs.copy(status = "completed", done = 4, endedAt = java.time.Instant.now()))
                    time >= 8.0 -> listOf(review.copy(done = 4), docs.copy(status = "completed", done = 4, endedAt = java.time.Instant.now()))
                    time >= 4.0 -> listOf(review.copy(done = 4), docs)
                    else -> listOf(review, docs)
                },
            )
            else -> mapOf("w1" to listOf(review, docs))
        }
    }

    /**
     * The In flight section as Now saw it, Now appearing at 0 and the change at [FLIGHT_CHANGE], built as NowStore
     * builds it (the grace book too, so a finish reaches the card the way it does live).
     */
    fun flightScript(screen: String): List<Pair<Double, InFlightSection>>? {
        if (!isFlight(screen)) return null
        val grace = FlightGraceBook()
        fun at(t: Double): InFlightSection {
            val sessions = flightSessions(screen, t)
            val runs = workflows(screen, t) ?: emptyMap()
            val ended = grace.observe(sessions, runs, DemoFixtures.now.plusMillis((t * 1000).toLong()))
            return InFlightSection.build(sessions, true, runs, now = DemoFixtures.now, zone = DemoFixtures.zone, ended = ended)
        }
        val first = at(0.0)
        return if (screen == "motion-inflight-enter" || screen == "motion-inflight-stuck") listOf(0.0 to first) else listOf(0.0 to first, FLIGHT_CHANGE to at(FLIGHT_CHANGE))
    }

    // endregion

    // region The rest of Now in motion

    /**
     * The rest of Now's motion screens (the Runway, the Horizon's words, the tab badges, Review chips, Settled): Now on
     * the board's stream, scripted ([nowScript]) and pinned by time, Now appearing at 0. `-enter` is its first look (the
     * Runway draws, the chips count up; `-enter-review` scrolled to the Review card); `-change` has, at [NOW_CHANGE], a
     * third decision ("2 need you" → "3 need you", the Now badge 2 → 3), a receipt settling and the battery cutoff moving
     * on the Runway (`-change-settled` scrolled to Settled); `-quiet` is the first look with no agent at work, which must
     * come to rest.
     */
    fun isNow(screen: String) = screen.startsWith("motion-now-")

    private const val NOW_CHANGE = 2.0

    private fun nowChanges(screen: String) = screen.startsWith("motion-now-change")

    private fun nowInbox(screen: String, time: Double): List<Intervention> {
        val o = DemoFixtures.open
        if (!nowChanges(screen) || time < NOW_CHANGE) return o
        return o + DemoFixtures.iv("p6", "relay", InterventionKind.APPROVAL, "[Bash] npm run deploy:staging\nDeploy the relay to staging", 1)
    }

    private fun nowSessions(screen: String): List<LiveSession> =
        if (screen == "motion-now-quiet") DemoFixtures.sessionsWithFlight.map(::idle) else DemoFixtures.nowSessions("now")

    /**
     * The Mac's status a Now motion screen draws [time] seconds in, or null for its base screen's. The battery cutoff
     * moves half an hour later (the drain eased), clear of the other labels, so no label changes lane as it glides.
     */
    fun status(screen: String, time: Double): MacStatusSnapshot? {
        if (!isNow(screen)) return null
        val st = DemoFixtures.status
        if (screen == "motion-now-quiet") return st.copy(working = 0)
        if (!nowChanges(screen) || time < NOW_CHANGE) return st
        return st.copy(forecast = st.forecast?.copy(minutes = 178))
    }

    /** The settled pages a Now motion screen draws [time] seconds in (a push just approved and delivered), or null for the stock ones. */
    fun history(screen: String, time: Double): List<Intervention>? {
        if (!isNow(screen)) return null
        val h = DemoFixtures.history
        if (!nowChanges(screen) || time < NOW_CHANGE) return h
        val now = DemoFixtures.now
        val push = DemoFixtures.iv("h0", "page", InterventionKind.APPROVAL, "[Bash] git push\nPush the branch", 30).copy(
            closedAt = now, repliedAt = now, repliedAction = "approve", deliveryStatus = "delivered", closeReason = "replied",
        )
        return listOf(push) + h
    }

    /** What Now's motion follows as Now saw it, Now appearing at 0 and the change at [NOW_CHANGE], built with the builders NowStore uses. */
    fun nowScript(screen: String): List<Pair<Double, NowMotion.Look>>? {
        if (!isNow(screen)) return null
        fun at(t: Double): NowMotion.Look {
            val history = history(screen, t) ?: DemoFixtures.history
            val model = NowModel.build(
                NowInputs(
                    interventions = nowInbox(screen, t), sessions = nowSessions(screen), hasSessionList = true, status = status(screen, t), history = history,
                    now = DemoFixtures.now, macName = DemoFixtures.mac, zone = DemoFixtures.zone,
                ),
            )
            return NowMotion.Look.of(model, SettledLog.build(history, DemoFixtures.now, DemoFixtures.zone))
        }
        return if (nowChanges(screen)) listOf(0.0 to at(0.0), NOW_CHANGE to at(NOW_CHANGE)) else listOf(0.0 to at(0.0))
    }

    // endregion

    /** The power story behind Lanes' dusk and dawn, built with the same observations the live app makes. */
    fun power(screen: String): DuskDawnLog? {
        if (screen != "motion-dusk" && screen != "motion-dawn") return null
        val now = DemoFixtures.now
        val active = DemoFixtures.sessions.filter { it.state == LiveSessionState.ACTIVE }.map { it.id }.toSet()
        val log = DuskDawnLog()
        log.observe(false, active, now.minusSeconds(900))
        if (screen == "motion-dawn") {
            log.observe(true, emptySet(), now.minusSeconds(600))
            log.observe(false, emptySet(), now)
            val back = HashSet<String>()
            for ((id, at) in resumes) { back.add(id); log.observe(false, back.toSet(), now.plusMillis((at * 1000).toLong())) }
        } else {
            log.observe(true, active, now)
        }
        return log
    }

    /** The row that arrives (Final approach), the rows folding away, and where to scroll. */
    fun pinnedArrival(screen: String): String? = if (screen == "motion-approach") "p1" else null
    fun ghosts(screen: String): Set<String> = if (screen == "motion-receipt-fold") setOf(UNDOABLE) else emptySet()
    fun scrollTo(screen: String): String? = if (screen.startsWith("motion-receipt") && screen != "motion-receipt-sheet") "row-$UNDOABLE" else null
    fun scrollTop(screen: String): String? = when (screen) {
        "motion-brief" -> "brief"
        "motion-now-enter-review" -> "section-review"
        "motion-now-change-settled" -> "settled"
        else -> null
    }

    /** The Undoable row (the swipe-to-run `swift test` page) whose receipt the thread screens draw. */
    private const val UNDOABLE = "p2"

    /** The delivery state, its time, and the pending action behind a receipt screen, `time` seconds into its stage. */
    data class Receipt(val deliveries: Map<String, ReplyDelivery>, val times: Map<String, Instant>, val pending: Map<String, PendingAction>)

    fun receipt(screen: String, time: Double, preview: String?): Receipt? {
        val now = DemoFixtures.now
        val at = now.minusMillis((time * 1000).toLong())
        val id = UNDOABLE
        return when (screen) {
            "motion-receipt-arm" -> Receipt(emptyMap(), emptyMap(), mapOf(id to PendingAction(id, RowAction.Kind.APPROVE, "", CommitGesture.SWIPE, at, true, preview)))
            "motion-receipt-sending" -> Receipt(mapOf(id to ReplyDelivery.Sending), mapOf(id to at), emptyMap())
            "motion-receipt-sent" -> Receipt(mapOf(id to ReplyDelivery.Sent(false, at)), mapOf(id to at), emptyMap())
            "motion-receipt-typed", "motion-receipt-verified", "motion-receipt-fold" -> Receipt(mapOf(id to ReplyDelivery.Delivered("Typed into cmux › page")), mapOf(id to at), emptyMap())
            "motion-receipt-failed" -> Receipt(mapOf(id to ReplyDelivery.Failed("Prompt changed before your answer · Review again")), mapOf(id to at), emptyMap())
            "motion-receipt-sheet" -> Receipt(mapOf("c1" to ReplyDelivery.Delivered("typed into cmux › page")), mapOf("c1" to at), emptyMap())
            else -> null
        }
    }

    /** The hold ring and the controls round it, as the Decision sheet draws them, centred. */
    @Composable
    fun Hold(screen: String, time: Double) {
        val burst = screen == "motion-hold-burst"
        val p = if (burst) 1.0 else HoldRingSpec.irreversible.progress(time)
        val biometry = "fingerprint"
        Box(Modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color), contentAlignment = Alignment.Center) {
            Column(
                Modifier.padding(horizontal = 16.dp).fillMaxWidth()
                    .background(NW.Palette.surface.mixed(NW.Palette.red, 0.10).color, RoundedCornerShape(28.dp))
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                NWDeliveryPreview("Will type 1 · cmux › builds · Studio MBP")
                NWHoldRing(HoldRingSpec.irreversible, onComplete = {}, fixedProgress = p)
                Text(
                    if (burst) "Approved with $biometry" else HoldRingSpec.prompt(p, biometry).replaceFirstChar { it.uppercase() },
                    style = NW.Typo.bodyStrong,
                    color = (if (burst) NW.Palette.textSecondary else NW.Palette.red.mixed(NW.Palette.white, 0.35)).color,
                )
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    NWButton("Deny", {}, Modifier.weight(1f))
                    NWButton("Tell it instead…", {}, Modifier.weight(1f))
                }
            }
        }
    }
}
