package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.roundToInt

// Ported from iOS Models/UsageDisplay.swift. Pure (java.time only), so the
// unit tests cover it; the composables only draw it.

/**
 * What the usage gauges show for one Claude window (5-hour or 7-day): how
 * full it is, when it resets, and whether usage is running ahead of an even
 * pace through the window.
 */
class UsageGauge(
    val label: String,
    pct: Double,
    val resetsAt: Instant?,
    /** The window's length in seconds. */
    window: Double,
    now: Instant,
) {
    enum class Tone { CALM, WARM, HOT }

    /** 0...100. */
    val pct: Double = pct.coerceIn(0.0, 100.0)

    /**
     * Share of the window already gone (0...1), null without a future reset
     * time: where usage would be at an even pace.
     */
    val elapsed: Double? = resetsAt?.takeIf { it.isAfter(now) }?.let {
        (1 - seconds(now, it) / window).coerceIn(0.0, 1.0)
    }

    val fraction: Double get() = (pct / 100).coerceIn(0.0, 1.0)

    /** Points ahead of an even pace (negative: behind). */
    val paceDelta: Double? get() = elapsed?.let { pct - it * 100 }

    val tone: Tone
        get() = when {
            pct >= 90 -> Tone.HOT
            pct >= 70 || (paceDelta ?: 0.0) >= 15 -> Tone.WARM
            else -> Tone.CALM
        }

    /** The percentage as shown: "57". */
    val percentText: String get() = pct.roundToInt().toString()

    /** "Resets in 34m" (or "Resetting…" once it's due). */
    fun resetLine(now: Instant): String? {
        val r = resetsAt ?: return null
        return if (r.isAfter(now)) "Resets in ${countdown(r, now)}" else "Resetting…"
    }

    /** "Ahead of pace" / "On pace" / "Plenty left", null when unknown. */
    val paceLine: String?
        get() {
            val d = paceDelta ?: return null
            return when {
                d >= 15 -> "Ahead of pace"
                d <= -15 -> "Plenty left"
                else -> "On pace"
            }
        }

    override fun equals(other: Any?): Boolean =
        other is UsageGauge && label == other.label && pct == other.pct && resetsAt == other.resetsAt && elapsed == other.elapsed

    override fun hashCode(): Int = listOf(label, pct, resetsAt, elapsed).hashCode()

    override fun toString(): String = "UsageGauge($label, $pct%, resetsAt=$resetsAt, elapsed=$elapsed)"

    companion object {
        const val FIVE_HOUR_WINDOW: Double = 5 * 3600.0
        const val SEVEN_DAY_WINDOW: Double = 7 * 24 * 3600.0

        private fun seconds(from: Instant, to: Instant): Double = (to.toEpochMilli() - from.toEpochMilli()) / 1000.0

        /** "34m", "2h 05m", "1d 4h". */
        fun countdown(to: Instant, now: Instant): String {
            val s = maxOf(0, seconds(now, to).toLong())
            if (s < 60) return "<1m"
            val m = s / 60
            val h = m / 60
            val d = h / 24
            if (d > 0) return if (h % 24 == 0L) "${d}d" else "${d}d ${h % 24}h"
            if (h > 0) return "${h}h ${(m % 60).toString().padStart(2, '0')}m"
            return "${m}m"
        }
    }
}

/** The usage card's whole content from the Mac's `usage`. */
data class UsageCardModel(
    val fiveHour: UsageGauge?,
    val sevenDay: UsageGauge?,
    /** When the 5-hour limit is reached at the current pace (before reset). */
    val hitAt: Instant?,
    /** The numbers are older than this many minutes (shown as "as of"). */
    val staleMinutes: Int?,
) {
    data class Verdict(val text: String, val warning: Boolean)

    /** The one-line verdict under the gauges; [format] gives a time of day. */
    fun verdict(format: (Instant) -> String): Verdict {
        hitAt?.let { return Verdict("At this pace you'll hit the 5-hour limit around ${format(it)}", true) }
        sevenDay?.let { s -> if (s.pct >= 90) return Verdict("Only ${(100 - s.pct).roundToInt()}% of this week's usage left", true) }
        sevenDay?.let { s -> if ((s.paceDelta ?: 0.0) >= 15) return Verdict("Using this week's allowance faster than it resets", true) }
        fiveHour?.let { f -> if (f.pct >= 90) return Verdict("Close to the 5-hour limit", true) }
        return Verdict("On track — both windows reset before you run out", false)
    }

    /** "as of 20m ago" / "as of 2h ago", null while fresh. */
    val staleText: String?
        get() = staleMinutes?.let { m -> "as of ${if (m < 60) "${m}m" else "${m / 60}h"} ago" }

    companion object {
        const val STALE_AFTER_SECONDS: Long = 10 * 60
        const val HIDE_AFTER_SECONDS: Long = 6 * 3600

        /** Null when there's nothing worth showing (no usage, or numbers older than 6 h). */
        fun from(usage: ClaudeUsage?, now: Instant): UsageCardModel? {
            val u = usage ?: return null
            val age = u.updatedAt?.let { (now.toEpochMilli() - it.toEpochMilli()) / 1000.0 }
            if (age != null && age > HIDE_AFTER_SECONDS) return null
            val five = u.fiveHour?.let { UsageGauge("5-hour", it.pct, it.resetsAt, UsageGauge.FIVE_HOUR_WINDOW, now) }
            val seven = u.sevenDay?.let { UsageGauge("7-day", it.pct, it.resetsAt, UsageGauge.SEVEN_DAY_WINDOW, now) }
            if (five == null && seven == null) return null
            return UsageCardModel(
                fiveHour = five,
                sevenDay = seven,
                hitAt = u.hitAt?.takeIf { it.isAfter(now) },
                staleMinutes = age?.takeIf { it > STALE_AFTER_SECONDS }?.let { (it / 60).toInt() },
            )
        }
    }
}

/** Reset times and the spoken ring summary, in the phone's zone and locale. */
object UsageText {
    /** "at 20:40" today, "Mon 20:00" another day. */
    fun resetTime(at: Instant, now: Instant, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String {
        val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(locale).withZone(zone).format(at)
        val sameDay = at.atZone(zone).toLocalDate() == now.atZone(zone).toLocalDate()
        return if (sameDay) "at $time" else DateTimeFormatter.ofPattern("EEE", locale).withZone(zone).format(at) + " " + time
    }

    /** "5-hour usage 57 percent, resets at 20:40, on pace". */
    fun spoken(g: UsageGauge, now: Instant, zone: ZoneId = ZoneId.systemDefault(), locale: Locale = Locale.getDefault()): String {
        var s = "${g.label} usage ${g.percentText} percent"
        g.resetsAt?.let { s += ", resets ${resetTime(it, now, zone, locale)}" }
        g.paceLine?.let { s += ", ${it.lowercase()}" }
        return s
    }
}
