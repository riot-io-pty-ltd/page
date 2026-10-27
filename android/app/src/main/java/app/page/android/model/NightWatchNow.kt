package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import kotlin.math.roundToInt

// Port of iOS/Page/Models/NightWatchNow.swift. The model behind Night Watch's
// Now screen on the phone: the headline, the Runway, the ranked rows, the
// day's rings and the receipt line. Built from what the phone already holds
// (inbox pages, live sessions, the Mac's status and history) with no clock,
// calendar or service calls inside: callers pass `now`, the zone and
// everything else, so tests can feed any situation.

// MARK: - Receipts

/** The receipt for a keystroke Page delivered (or could not). */
data class DeliveryReceipt(
    val verb: Verb,
    /** "npm test". */
    val subject: String,
    /** "cmux › page". */
    val route: String,
    val at: Instant,
    val outcome: Outcome = Outcome.Delivered,
) {
    enum class Verb(val raw: String) { APPROVED("Approved"), DENIED("Denied"), REPLIED("Replied to"), STOPPED("Stopped") }

    /** What happened, in the words the trust model fixes for each outcome. */
    sealed interface Outcome {
        data object Delivered : Outcome
        data object TimedOut : Outcome
        data object SessionEnded : Outcome
        data object NotTypable : Outcome
        data object Queued : Outcome
        data object PromptClosed : Outcome
        data object AnsweredAtMac : Outcome
        data object UnknownState : Outcome

        /** The Mac was offline: the relay holds the reply until it is back. */
        data object MacOffline : Outcome

        /** A failure the Mac described in its own words. */
        data class Other(val why: String) : Outcome

        /** The sentence for anything but a confirmed delivery; null for [Delivered]. */
        val failureMessage: String?
            get() = when (this) {
                Delivered -> null
                TimedOut -> "Didn't confirm in time · Check on Mac"
                SessionEnded -> "Session ended"
                NotTypable -> "This terminal can't take input · Open on Mac"
                Queued -> "Queued after this turn"
                PromptClosed -> "Prompt closed before your answer"
                AnsweredAtMac -> "Already answered at the Mac"
                UnknownState -> "Review again"
                MacOffline -> "Waiting for your Mac to come back online"
                is Other -> if (why.isEmpty()) "Couldn't deliver the reply" else why
            }
    }

    /**
     * "Approved npm test → cmux › page · verified 23:47:12"; anything but a confirmed delivery reads
     * "<subject> · <what went wrong and what to do>".
     */
    fun line(zone: ZoneId = ZoneId.systemDefault()): String {
        outcome.failureMessage?.let { return "$subject · $it" }
        val to = if (route.isEmpty()) "" else " → $route"
        return "${verb.raw} $subject$to · verified ${NowFormat.clock(at, seconds = true, zone = zone)}"
    }
}

object ReceiptBuilder {
    /**
     * The receipt for a page's reply, or null while it is still in flight: "sent" is not "delivered", so success
     * is only ever a confirmed Delivered. Pure.
     *
     * [changedAt] is when the phone last saw this delivery change state. A failure, an answered-at-the-Mac or a
     * closed prompt is stamped with it (or the page's own reply time) rather than the rebuild time, so it ages
     * out of Now like a delivered receipt does.
     */
    fun receipt(iv: Intervention, delivery: ReplyDelivery, route: String?, now: Instant, changedAt: Instant? = null): DeliveryReceipt? {
        val verb = when (iv.repliedAction) {
            "approve" -> DeliveryReceipt.Verb.APPROVED
            "deny" -> if (PageSubtype.canStop(iv.subtype)) DeliveryReceipt.Verb.STOPPED else DeliveryReceipt.Verb.DENIED
            else -> DeliveryReceipt.Verb.REPLIED
        }
        val subject = if (verb == DeliveryReceipt.Verb.REPLIED && iv.kind != InterventionKind.APPROVAL) iv.projectName else NowRowBuilder.summaryLine(iv)
        fun make(outcome: DeliveryReceipt.Outcome, at: Instant) = DeliveryReceipt(verb, subject, route ?: "", at, outcome)
        val stamp = iv.repliedAt ?: changedAt ?: now
        return when (delivery) {
            ReplyDelivery.Sending -> null
            is ReplyDelivery.Sent -> if (delivery.queued) make(DeliveryReceipt.Outcome.MacOffline, delivery.at) else null
            is ReplyDelivery.Delivered -> make(DeliveryReceipt.Outcome.Delivered, iv.repliedAt ?: now)
            is ReplyDelivery.Failed -> make(DeliveryReceipt.Outcome.Other(delivery.message), stamp)
            ReplyDelivery.AlreadyReplied -> make(DeliveryReceipt.Outcome.AnsweredAtMac, stamp)
            ReplyDelivery.Gone -> make(DeliveryReceipt.Outcome.PromptClosed, stamp)
        }
    }
}

// MARK: - Runway

/** A deadline or event on the next six hours. */
data class RunwayMarker(
    val id: String,
    val kind: Kind,
    /** "5h 02:40", "reset 03:00", "resume 04:10", "cutoff 03:40". */
    val label: String,
    val at: Instant,
    /** 0 (now) .. 1 (end of the window), clamped. */
    val fraction: Double,
    val tone: Tone,
    /** 0, 1 or 2: another row when two labels would overlap. */
    val lane: Int = 0,
) {
    enum class Kind(val raw: String) { BATTERY_CUTOFF("batteryCutoff"), USAGE_LIMIT("usageLimit"), USAGE_RESET("usageReset"), WEEKLY_RESET("weeklyReset"), RESUME("resume") }
    enum class Tone(val raw: String) { AMBER("amber"), GREEN("green"), BLUE("blue") }
}

data class RunwayModel(
    val markers: List<RunwayMarker>,
    /** On AC (or no battery) the runway is a full horizon line: no cutoff. */
    val onAC: Boolean,
    /** Earliest deadline (battery cutoff or 5h limit hit), if any. */
    val clearUntil: Instant?,
) {
    companion object {
        /** How far ahead the runway looks. */
        const val window: Double = 6 * 3600.0

        /** What the phone does not know and so does not draw (scheduled resumes, which the Mac does not report to the phone yet). */
        val empty = RunwayModel(emptyList(), true, null)

        /** Position of [at] across the window: 0 now, 1 at the end; null when it is already past or beyond the window. Pure. */
        fun fraction(at: Instant, now: Instant, window: Double = RunwayModel.window): Double? {
            val dt = at.secondsSince(now)
            if (!(dt >= 0 && dt <= window)) return null
            return dt / window
        }

        /**
         * Gives a marker whose label would overlap the previous one in lane 0 a second lane, or a third when
         * both are taken. [minGap] is the least fraction between labels in a lane: about one label width on a
         * phone (92 dp of roughly 330). Pure.
         */
        fun assignLanes(markers: List<RunwayMarker>, minGap: Double = 0.28): List<RunwayMarker> {
            val lastInLane = HashMap<Int, Double>()
            val out = ArrayList<RunwayMarker>()
            for (m0 in markers.sortedBy { it.fraction }) {
                fun free(lane: Int): Boolean = lastInLane[lane]?.let { m0.fraction - it >= minGap } ?: true
                // The first lane with room; with none, the one whose last label is furthest away.
                val lane = (0 until 3).firstOrNull { free(it) }
                    ?: (0 until 3).maxByOrNull { m0.fraction - (lastInLane[it] ?: -1.0) } ?: 0
                lastInLane[lane] = m0.fraction
                out.add(m0.copy(lane = lane))
            }
            return out
        }

        /**
         * The Runway from the Mac's status: battery cutoff (only on battery), the 5-hour limit hit and resets.
         * Usage older than six hours is ignored (the same rule as the usage card). Pure.
         */
        fun build(status: MacStatusSnapshot?, now: Instant, zone: ZoneId = ZoneId.systemDefault()): RunwayModel {
            val s = status ?: return empty
            val markers = ArrayList<RunwayMarker>()
            val deadlines = ArrayList<Instant>()

            fun add(id: String, kind: RunwayMarker.Kind, prefix: String, at: Instant, tone: RunwayMarker.Tone) {
                val f = fraction(at, now) ?: return
                markers.add(RunwayMarker(id, kind, "$prefix ${NowFormat.clock(at, zone = zone)}", at, f, tone))
            }

            val onAC = s.onAC != false
            val forecast = s.forecast
            if (!onAC && forecast != null) {
                val at = now.plusSeconds(forecast.minutes * 60.0)
                deadlines.add(at)
                add("battery-cutoff", RunwayMarker.Kind.BATTERY_CUTOFF, "cutoff", at, RunwayMarker.Tone.AMBER)
            }
            val u = s.usage
            if (u != null && !(u.updatedAt?.let { now.secondsSince(it) > UsageCardModel.HIDE_AFTER_SECONDS } ?: false)) {
                val hit = u.hitAt
                if (hit != null && hit > now) {
                    deadlines.add(hit)
                    add("usage-limit", RunwayMarker.Kind.USAGE_LIMIT, "5h", hit, RunwayMarker.Tone.AMBER)
                }
                u.fiveHour?.resetsAt?.let { add("usage-reset", RunwayMarker.Kind.USAGE_RESET, "reset", it, RunwayMarker.Tone.GREEN) }
                u.sevenDay?.resetsAt?.let { add("weekly-reset", RunwayMarker.Kind.WEEKLY_RESET, "7d reset", it, RunwayMarker.Tone.GREEN) }
            }
            return RunwayModel(assignLanes(markers), onAC, deadlines.minOrNull())
        }
    }
}

// MARK: - Day rings

/** "Unblocked, Shipped, Calm": three daily rings. */
data class RingStat(
    val kind: Kind,
    /** 0..1. */
    val progress: Double,
    /** "11 / 12", "7 / 10", "4 h 10 min". */
    val detail: String,
) {
    enum class Kind(val raw: String) { UNBLOCKED("Unblocked"), SHIPPED("Shipped"), CALM("Calm") }

    val id: String get() = kind.raw
}

/** What the day's pages say. */
data class DayStats(
    /** Decisions answered in under two minutes, of all decisions. */
    val unblockedFast: Int = 0,
    val decisions: Int = 0,
    /** Turns that finished, of all finished or stuck turns. */
    val shipped: Int = 0,
    val finished: Int = 0,
    /** Seconds agents ran without you. The Mac does not report this to the phone, so it is null there and the ring reads "not tracked". */
    val calmSeconds: Double? = null,
    val calmGoal: Double = 4 * 3600.0,
) {
    val rings: List<RingStat>
        get() {
            fun frac(a: Int, b: Int): Double = if (b > 0) minOf(1.0, a.toDouble() / b) else 0.0
            return listOf(
                RingStat(RingStat.Kind.UNBLOCKED, frac(unblockedFast, decisions), if (decisions > 0) "$unblockedFast / $decisions" else "none yet"),
                RingStat(RingStat.Kind.SHIPPED, frac(shipped, finished), if (finished > 0) "$shipped / $finished" else "none yet"),
                RingStat(
                    RingStat.Kind.CALM,
                    calmSeconds?.let { if (calmGoal > 0) minOf(1.0, maxOf(0.0, it / calmGoal)) else 0.0 } ?: 0.0,
                    calmSeconds?.let { NowFormat.duration(it) } ?: "not tracked",
                ),
            )
        }

    companion object {
        /** Fast means answered within this many seconds. */
        const val fastSeconds = 120

        /** Today's rings from the archived pages and the open ones. [history] is the Mac's resolved pages. Pure. */
        fun today(history: List<Intervention>, now: Instant, zone: ZoneId = ZoneId.systemDefault()): DayStats {
            val start = startOfDay(now, zone)
            var unblockedFast = 0
            var decisions = 0
            var shipped = 0
            var finished = 0
            for (iv in history) {
                if (!SettledLog.isDecision(iv)) continue
                val at = iv.repliedAt ?: continue
                if (at < start) continue
                decisions += 1
                val t = iv.responseTimeSeconds
                if (t != null && t < fastSeconds) unblockedFast += 1
            }
            for (iv in history) {
                if (!(SettledLog.isFinishedTurn(iv) || SettledLog.isStuck(iv))) continue
                if ((iv.closedAt ?: iv.openedAt) < start) continue
                finished += 1
                if (SettledLog.isFinishedTurn(iv)) shipped += 1
            }
            return DayStats(unblockedFast = unblockedFast, decisions = decisions, shipped = shipped, finished = finished)
        }
    }
}

/** `Calendar.startOfDay(for:)` in a zone. */
fun startOfDay(at: Instant, zone: ZoneId): Instant = at.atZone(zone).toLocalDate().atStartOfDay(zone).toInstant()

// MARK: - Now

data class NowInputs(
    /** Open pages (`RelayClient.inbox`). */
    val interventions: List<Intervention> = emptyList(),
    val inbox: InboxState = InboxState.LOADED,
    /** Live sessions, when the list has arrived. */
    val sessions: List<LiveSession> = emptyList(),
    val hasSessionList: Boolean = false,
    val status: MacStatusSnapshot? = null,
    /** Resolved pages (`RelayClient.history`). */
    val history: List<Intervention> = emptyList(),
    /** Where each reply stands (`RelayClient.deliveries`). */
    val deliveries: Map<String, ReplyDelivery> = emptyMap(),
    /** When each delivery last changed on this phone. */
    val deliveryTimes: Map<String, Instant> = emptyMap(),
    val now: Instant,
    /** "Studio MBP": every action names the Mac it will act on. */
    val macName: String,
    val zone: ZoneId = ZoneId.systemDefault(),
) {
    /** How the inbox stands: "All quiet" is only true after a successful load. */
    enum class InboxState { LOADING, LOADED, FAILED }
}

data class NowModel(
    /** Which aurora and pulse colour the header uses. */
    val mood: Mood,
    /** "2 need you", "All quiet", "Paused for battery". */
    val headline: String,
    /** "5 working · runway clear till 03:40", "nothing needs you". */
    val subline: String,
    val needYouCount: Int,
    val lookCount: Int,
    val reviewCount: Int,
    val workingCount: Int,
    /** Decide rows first (Irreversible first), then Look, then Review. */
    val rows: List<NowRow>,
    val runway: RunwayModel,
    /** The latest receipt, as a line; null when none is recent. */
    val receiptLine: String?,
    /** The latest receipt is not a confirmed delivery (drawn amber, not teal). */
    val receiptFailed: Boolean,
    /** An open "paused for battery" page: agents are paused at the cutoff. */
    val paused: Boolean,
    val rings: List<RingStat>,
    val macName: String,
    /** Spoken for the header. */
    val accessibilityLabel: String,
) {
    enum class Mood(val raw: String) { NEEDS_YOU("needsYou"), WORKING("working"), QUIET("quiet"), DUSK("dusk") }

    val attentionCount: Int get() = needYouCount + lookCount

    /**
     * What the pulse counts, one ring per item, on every surface (the Horizon, the nav bar, the Mac's popover and
     * menu-bar glyph): the decisions, else the looks, which is the count the headline names.
     */
    val pulseWaiting: Int get() = pulseWaiting(needYouCount, lookCount)

    /**
     * The rows the pulse counts (the decisions, else the looks; never the finished turns): their oldest wait
     * sets the ripple's pace, as on the Mac.
     */
    val pulseRows: List<NowRow>
        get() {
            val decide = rows.filter { it.section == NowRow.Section.DECIDE }
            return decide.ifEmpty { rows.filter { it.section == NowRow.Section.LOOK } }
        }

    companion object {
        /** The pulse's count from the two section counts. Pure. */
        fun pulseWaiting(need: Int, look: Int): Int = if (need > 0) maxOf(0, need) else maxOf(0, look)

        data class Pulse(val waiting: Int, val longestWait: Double)

        /**
         * The pulse straight from the open pages, for the nav bar, which has no model of its own: how many it
         * counts and the oldest wait among them. The same rule as [pulseWaiting] and [pulseRows]. Pure.
         */
        fun pulse(inbox: List<Intervention>, now: Instant): Pulse {
            val decide = inbox.filter { NowRowBuilder.section(it) == NowRow.Section.DECIDE }
            val counted = decide.ifEmpty { inbox.filter { NowRowBuilder.section(it) == NowRow.Section.LOOK } }
            return Pulse(counted.size, PulseModel.longestWait(counted.map { it.openedAt }, now))
        }

        /** Receipts older than this are not shown. */
        const val receiptWindow: Double = 15 * 60.0

        /**
         * Counts follow the board: "need you" is approvals, plans and questions (the agent is blocked); "look"
         * is stuck agents, rate limits and forecasts; "review" is finished turns. "Working" is the live sessions
         * the Mac reports as active, or its heartbeat count before the list arrives. Pure.
         */
        fun build(i: NowInputs): NowModel {
            val tz = i.zone
            val rows = NowRowBuilder.ranked(i.interventions.map { iv -> NowRowBuilder.row(iv, i.sessions.firstOrNull { it.id == iv.sessionId }, i.macName) })
            val need = rows.count { it.section == NowRow.Section.DECIDE }
            val look = rows.count { it.section == NowRow.Section.LOOK }
            val review = rows.count { it.section == NowRow.Section.REVIEW }
            val working = if (i.hasSessionList) i.sessions.count { it.state == LiveSessionState.ACTIVE } else (i.status?.working ?: 0)

            val runway = RunwayModel.build(i.status, i.now, tz)
            val paused = i.interventions.any { it.kind == InterventionKind.IDLE && it.subtype == "low_battery" }
            val reachable = MacPresence.evaluate(i.status, i.now).isReachable

            val mood = if (paused) Mood.DUSK else if (need + look > 0) Mood.NEEDS_YOU else if (working > 0) Mood.WORKING else Mood.QUIET

            val headline: String
            val subline: String
            if (paused) {
                headline = "Paused for battery"
                subline = if (i.status?.onAC == true) "plugged in · agents resume soon" else "plug the Mac in to resume"
            } else if (need > 0) {
                headline = "$need ${if (need == 1) "needs" else "need"} you"
                subline = listOfNotNull(if (working > 0) "$working working" else null, runwayLine(i.status, runway, tz)).joinToString(" · ")
            } else if (look > 0) {
                headline = "$look ${if (look == 1) "needs" else "need"} a look"
                subline = listOfNotNull(if (working > 0) "$working working" else null, runwayLine(i.status, runway, tz)).joinToString(" · ")
            } else if (i.inbox == NowInputs.InboxState.LOADING) {
                headline = "Checking…"
                subline = "asking ${DeliveryPreview.macLabel(i.macName)} what's happening"
            } else if (i.inbox == NowInputs.InboxState.FAILED || !reachable) {
                // Silence has to be earned: an unreachable Mac or a failed load is not "All quiet".
                headline = "Nothing waiting"
                subline = if (i.inbox == NowInputs.InboxState.FAILED) "the list may be out of date" else "${DeliveryPreview.macLabel(i.macName)} isn't connected"
            } else {
                headline = "All quiet"
                subline = if (working > 0) "$working working · nothing needs you" else "no agents running · nothing needs you"
            }

            // Receipt: the newest page whose reply has a verdict.
            val receipts = ArrayList<Pair<DeliveryReceipt, Instant>>()
            val seen = HashSet<String>()
            for (iv in i.history + i.interventions) {
                if (!seen.add(iv.id)) continue
                val d = i.deliveries[iv.id] ?: continue
                val session = i.sessions.firstOrNull { it.id == iv.sessionId }
                val route = DeliveryPreview.route(session?.host, session?.title ?: iv.projectName)
                val r = ReceiptBuilder.receipt(iv, d, route, i.now, i.deliveryTimes[iv.id])
                if (r != null && i.now.secondsSince(r.at) < receiptWindow && r.at <= i.now.plusSeconds(60.0)) receipts.add(Pair(r, r.at))
            }
            val latest = receipts.maxByOrNull { it.second }?.first

            return NowModel(
                mood = mood, headline = headline, subline = subline,
                needYouCount = need, lookCount = look, reviewCount = review, workingCount = working,
                rows = rows, runway = runway, receiptLine = latest?.line(tz),
                receiptFailed = latest?.let { it.outcome != DeliveryReceipt.Outcome.Delivered } ?: false, paused = paused,
                rings = DayStats.today(i.history, i.now, tz).rings,
                macName = i.macName, accessibilityLabel = "Page, $headline",
            )
        }

        /**
         * The Mac chip above the headline already says the battery ("Studio MBP · on battery · 41%"), so the subline
         * drops its own trailing " · 41%" when the chip carries the same figure. Pure.
         */
        fun sublineBesideChip(subline: String, chipText: String): String {
            val tail = Regex(""" · (\d{1,3}%)$""").find(subline) ?: return subline
            return if (chipText.endsWith(" · " + tail.groupValues[1])) subline.removeRange(tail.range) else subline
        }

        /** "runway clear till 03:40 · 41%", "on battery · 41%", "runway clear". */
        fun runwayLine(status: MacStatusSnapshot?, runway: RunwayModel, zone: ZoneId = ZoneId.systemDefault()): String {
            val parts = ArrayList<String>()
            val onBattery = status?.onAC == false
            val end = runway.clearUntil
            if (end != null) {
                parts.add("runway clear till ${NowFormat.clock(end, zone = zone)}")
                status?.batteryPercent?.let { if (onBattery) parts.add("$it%") }
            } else if (onBattery) {
                parts.add("on battery" + (status?.batteryPercent?.let { " · $it%" } ?: ""))
            } else {
                parts.add("runway clear")
            }
            return parts.joinToString(" · ")
        }
    }
}

// MARK: - Time

object NowFormat {
    /** 24-hour "03:40" (or "23:47:12" with seconds), as the boards show. Pure. */
    fun clock(date: Instant, seconds: Boolean = false, zone: ZoneId = ZoneId.systemDefault()): String {
        val t = date.atZone(zone)
        val hm = String.format(Locale.US, "%02d:%02d", t.hour, t.minute)
        return if (seconds) hm + String.format(Locale.US, ":%02d", t.second) else hm
    }

    /** "52 min", "1 h 52 min", "4 h": minutes under an hour, else hours and minutes. [upper] gives "52 MIN" for labels. Pure. */
    fun duration(seconds: Double, upper: Boolean = false): String {
        val total = maxOf(0, (seconds / 60).roundHalfAwayFromZero())
        val h = total / 60
        val m = total % 60
        val text = if (h == 0) "${maxOf(1, m)} min" else if (m == 0) "$h h" else "$h h $m min"
        return if (upper) text.uppercase() else text
    }

    /** Swift's `.rounded()`: half away from zero (Kotlin's roundToInt is half up). */
    private fun Double.roundHalfAwayFromZero(): Int = if (this >= 0) Math.floor(this + 0.5).toInt() else -Math.floor(-this + 0.5).toInt()
}
