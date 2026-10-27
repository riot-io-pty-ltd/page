package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import java.util.regex.Pattern

// Port of iOS/Page/Models/ReturnBrief.swift. The Return Brief: one honest
// summary of an absence, built only from what Page already has (the page and
// reply history, turn summaries, the Mac's battery and usage readings). No
// model call. Pure. (Persistence of the two timestamps is `AwayStore`.)

/** When the Brief appears, and whether you have dismissed it. */
object AwayTracker {
    const val lastActiveKey = "page.lastActiveAt"
    const val dismissedKey = "page.briefDismissedFor"

    /** Away this long (judged by when Page last went to the background) and the Brief appears. */
    const val briefAfter: Double = 45 * 60.0

    /** Away this long and the Horizon sentence is phrased as a handover. */
    const val handoverAfter: Double = 10 * 60.0

    /** The time away, or null when there is no earlier record. */
    fun away(lastActive: Instant?, now: Instant): Double? = lastActive?.let { maxOf(0.0, now.secondsSince(it)) }

    /**
     * Show the Brief: away long enough, and not already dismissed for this absence (the dismissal stores the
     * `lastActive` it dismissed). Pure.
     */
    fun shouldShowBrief(lastActive: Instant?, dismissedFor: Instant?, now: Instant): Boolean {
        val away = away(lastActive, now) ?: return false
        if (away < briefAfter) return false
        return dismissedFor != lastActive
    }
}

/**
 * One absence, fixed when Page comes back: from when it went to the background to the moment it returned.
 * Everything about the absence (the Brief's window, its counts, the handover sentence) is measured over
 * [since, returnedAt], so it does not keep growing while you are back.
 */
data class Absence(val since: Instant, val returnedAt: Instant) {
    val duration: Double get() = maxOf(0.0, returnedAt.secondsSince(since))

    /** The handover phrasing stays for ten minutes after you are back. Pure. */
    fun showsHandover(now: Instant): Boolean = now.secondsSince(returnedAt) < AwayTracker.handoverAfter

    /** The Brief appears for absences of 45 minutes or more, unless dismissed. Pure. */
    fun shouldShowBrief(dismissedFor: Instant?): Boolean = duration >= AwayTracker.briefAfter && dismissedFor != since

    companion object {
        /** An absence only exists if it was long enough for a handover (10 min). Pure. */
        fun make(lastActive: Instant?, returnedAt: Instant): Absence? {
            if (lastActive == null || returnedAt.secondsSince(lastActive) < AwayTracker.handoverAfter) return null
            return Absence(lastActive, returnedAt)
        }
    }
}

data class ReturnBrief(
    /** "1h 52m". */
    val awayText: String,
    /** "While you were away · 1h 52m". */
    val title: String,
    /** "23:20 to 01:12". */
    val window: String,
    val counts: List<Count>,
    val lines: List<Line>,
    /** 0..1: how bright the sunrise is, in proportion to what finished. */
    val sunrise: Double,
    /** Open pages (Decide or Look): the Brief collapses to one line in that case. */
    val hasUrgent: Boolean,
) {
    enum class Tone(val raw: String) { GOOD("good"), NEUTRAL("neutral"), WARN("warn") }

    data class Count(val kind: Kind, val value: Int) {
        enum class Kind(val raw: String) { FINISHED("Finished"), IN_FLIGHT("In flight"), NEED_YOU("Need you") }

        val id: String get() = kind.raw
    }

    data class Line(
        val id: String,
        /** A semantic icon name (the views map it to an icon). */
        val symbol: String,
        val title: String,
        val detail: String?,
        val tone: Tone,
    )

    val finished: Int get() = counts.firstOrNull { it.kind == Count.Kind.FINISHED }?.value ?: 0

    /** A short line for the collapsed form: "While you were away · 1h 52m ›". */
    val collapsedTitle: String get() = title

    companion object {
        private val changedFiles = Rx.compile("""Changed (\d+) files?""")

        /** The Brief's content. [history] is the resolved pages; [open] the pages still waiting. Pure. */
        fun build(
            since: Instant, now: Instant, history: List<Intervention>, open: List<Intervention>, sessions: List<LiveSession>,
            hasSessionList: Boolean, status: MacStatusSnapshot?, zone: ZoneId = ZoneId.systemDefault(),
        ): ReturnBrief {
            val away = maxOf(0.0, now.secondsSince(since))
            val awayText = brief(away)
            val inWindow = history.filter { SettledLog.settledAt(it) >= since && SettledLog.settledAt(it) <= now }

            val decisions = inWindow.filter { SettledLog.isDecision(it) }
            val approved = decisions.count { it.repliedAction == "approve" }
            val denied = decisions.count { it.repliedAction == "deny" }
            val said = decisions.size - approved - denied
            val finishedTurns = inWindow.filter { SettledLog.isFinishedTurn(it) }
            val recovered = inWindow.filter { SettledLog.isStuck(it) }
            val pauses = inWindow.count { SettledLog.isBatteryPause(it) } + open.count { it.kind == InterventionKind.IDLE && it.subtype == "low_battery" }

            val needYou = open.count { NowRowBuilder.section(it) == NowRow.Section.DECIDE }
            val look = open.count { NowRowBuilder.section(it) == NowRow.Section.LOOK }
            val working = if (hasSessionList) sessions.count { it.state == LiveSessionState.ACTIVE } else (status?.working ?: 0)

            val lines = ArrayList<Line>()
            if (decisions.isNotEmpty()) {
                val parts = ArrayList<String>()
                if (approved > 0) parts.add("$approved approved")
                if (denied > 0) parts.add("$denied denied")
                if (said > 0) parts.add("$said answered in words")
                lines.add(Line("decided", "hand.tap", "Decided ${decisions.size}", parts.joinToString(" · "), Tone.NEUTRAL))
            }
            if (finishedTurns.isNotEmpty()) {
                var files = 0
                var passing = 0
                var failing = 0
                for (t in finishedTurns) {
                    val summary = TurnSummaryLine.split(InterventionKind.IDLE, t.context).summary ?: ""
                    val m = changedFiles.matcher(summary)
                    if (m.find()) files += Sw.chars(m.group()).filter { Sw.isNumber(it) }.joinToString("").toIntOrNull() ?: 0
                    if (summary.contains("tests passed")) passing += 1
                    if (summary.contains("tests failed")) failing += 1
                }
                val parts = arrayListOf("${finishedTurns.size} turn${if (finishedTurns.size == 1) "" else "s"}")
                if (files > 0) parts.add("$files file${if (files == 1) "" else "s"}")
                if (passing + failing > 0) parts.add("tests passing in $passing of ${passing + failing}")
                lines.add(Line("finished", "checkmark.circle", "Finished", parts.joinToString(" · "), if (failing > 0) Tone.WARN else Tone.GOOD))
            }
            if (recovered.isNotEmpty()) {
                lines.add(Line("stuck", "arrow.triangle.2.circlepath", "Looked stuck: ${recovered.size}", "cleared by the time you came back", Tone.WARN))
            }
            val usage = status?.usage?.fiveHour
            if (usage != null && (status.usage.updatedAt?.let { now.secondsSince(it) <= 6 * 3600 } ?: true)) {
                val parts = arrayListOf("5h ${Math.round(usage.pct).toInt()}%")
                val hit = status.usage.hitAt
                if (hit != null && hit > now) parts.add("on pace to hit ${NowFormat.clock(hit, zone = zone)}")
                val r = usage.resetsAt
                if (r != null && r > now) parts.add("resets ${NowFormat.clock(r, zone = zone)}")
                lines.add(Line("usage", "gauge.with.needle", "Usage", parts.joinToString(" · "), if (status.usage.hitAt != null) Tone.WARN else Tone.NEUTRAL))
            }
            val b = status?.batteryPercent
            if (b != null) {
                val parts = arrayListOf("$b%", if (status.onAC == true) "on power" else "on battery")
                parts.add("paused at the cutoff ${if (pauses == 0) "0 times" else if (pauses == 1) "once" else "$pauses times"}")
                lines.add(Line("battery", "battery.50", "Battery", parts.joinToString(" · "), if (pauses > 0) Tone.WARN else Tone.NEUTRAL))
            }
            // A grown sunrise: a long productive absence is a bright dawn, an idle one stays dim.
            val sunrise = minOf(1.0, finishedTurns.size / 6.0)
            return ReturnBrief(
                awayText = awayText, title = "While you were away · $awayText",
                window = "${NowFormat.clock(since, zone = zone)} to ${NowFormat.clock(now, zone = zone)}",
                counts = listOf(
                    Count(Count.Kind.FINISHED, finishedTurns.size), Count(Count.Kind.IN_FLIGHT, working),
                    Count(Count.Kind.NEED_YOU, needYou + look),
                ),
                lines = lines, sunrise = sunrise, hasUrgent = needYou + look > 0,
            )
        }

        /** "1h 52m", "45m", "2h". */
        fun brief(seconds: Double): String {
            val total = maxOf(0, Math.floor(seconds / 60 + 0.5).toInt())
            val h = total / 60
            val m = total % 60
            if (h == 0) return "${maxOf(1, m)}m"
            return if (m == 0) "${h}h" else "${h}h ${m}m"
        }

        /**
         * The Horizon sentence when you have been away 10 minutes or more: "While you were away (1h 52m) · 3
         * finished · 2 need you". null when short of that, or when nothing finished and nothing waits (the normal
         * sentence is then truer). Pure.
         */
        fun handoverSentence(away: Double, finished: Int, needYou: Int): String? {
            if (!(away >= AwayTracker.handoverAfter && finished + needYou > 0)) return null
            val parts = arrayListOf("While you were away (${brief(away)})")
            if (finished > 0) parts.add("$finished finished")
            if (needYou > 0) parts.add("$needYou ${if (needYou == 1) "needs" else "need"} you")
            return parts.joinToString(" · ")
        }
    }
}
