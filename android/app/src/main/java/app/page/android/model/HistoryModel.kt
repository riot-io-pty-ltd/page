package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

// Port of iOS/Page/Models/HistoryModel.swift. The History screen: every
// settled page, one row each, grouped by day, plus the day's numbers. Pure: the
// caller passes `now` and the zone. It reads the same lines Now's Settled list
// does ([SettledLog.line]), so a page reads the same on both; only the 12-line
// and 14-day limits of the Now list are lifted here.

/** One settled page. */
data class HistoryRow(
    val id: String,
    val tone: SettledLine.Tone,
    /** "Approved npm test", "Sent “use the cache”", "Answered in the terminal". */
    val text: String,
    /** "12m", "delivered ✓": the same pair Settled shows. */
    val trailing: String,
    /** "page · APPROVAL · Answered in 8s". */
    val detail: String,
    /** Spoken for the whole row. */
    val spoken: String,
)

/** One day of settled pages, newest first. */
data class HistoryDay(
    val day: Instant,
    /** "Today", "Yesterday", "Tue 20 Oct". */
    val title: String,
    /** "14 decided · 6 finished · 2 stuck", or "quiet". */
    val summary: String,
    val rows: List<HistoryRow>,
)

data class HistoryScreenModel(
    val days: List<HistoryDay>,
    /** Pages in the list. */
    val total: Int,
    /** Today, this week, average response and the busiest projects. */
    val stats: PageStats,
    /** Open pages: the "pending now" tile. */
    val pending: Int,
    /** Today's three rings. */
    val rings: List<RingStat>,
) {
    companion object {
        fun build(history: List<Intervention>, inbox: List<Intervention>, now: Instant, zone: ZoneId = ZoneId.systemDefault()): HistoryScreenModel {
            val items = history.sortedByDescending { SettledLog.settledAt(it) }
            val order = ArrayList<Instant>()
            val buckets = HashMap<Instant, MutableList<Intervention>>()
            for (iv in items) {
                val d = startOfDay(SettledLog.settledAt(iv), zone)
                if (d !in buckets) order.add(d)
                buckets.getOrPut(d) { ArrayList() }.add(iv)
            }
            val today = startOfDay(now, zone)
            val days = order.map { d ->
                val list = buckets[d] ?: emptyList<Intervention>()
                val card = SettledLog.card(d, list, zone)
                HistoryDay(
                    d, dayTitle(d, today, zone),
                    SettledLog.summaryText(card.decided, card.finished, card.stuck, card.batteryPauses),
                    list.map { row(it, now) },
                )
            }
            return HistoryScreenModel(
                days = days, total = items.size,
                stats = PageStats.compute(history, inbox, now, zone),
                pending = inbox.size,
                rings = DayStats.today(history, now, zone).rings,
            )
        }

        fun row(iv: Intervention, now: Instant): HistoryRow {
            val line = SettledLog.line(iv, now)
            val detail = arrayListOf(iv.projectName, chipLabel(iv.kind, iv.subtype))
            iv.responseTimeSeconds?.let { detail.add("Answered in ${RelativeTime.compact(it)}") }
            val trailing = listOfNotNull(line.age, line.status).joinToString(" · ")
            val spoken = "${line.text}, ${iv.projectName}, $trailing"
            return HistoryRow(iv.id, line.tone, line.text, trailing, detail.joinToString(" · "), spoken)
        }

        fun dayTitle(day: Instant, today: Instant, zone: ZoneId): String {
            if (day == today) return "Today"
            val yesterday = today.atZone(zone).toLocalDate().minusDays(1).atStartOfDay(zone).toInstant()
            if (day == yesterday) return "Yesterday"
            return DateTimeFormatter.ofPattern("EEE d MMM", Locale.US).withZone(zone).format(day)
        }
    }
}

/** How the History screen reads while the list is empty. */
sealed interface HistoryEmpty {
    data object Loading : HistoryEmpty
    data class Failed(val why: String) : HistoryEmpty
    data object None : HistoryEmpty

    companion object {
        /** null when there are rows to show. [failure] is the load error, if any; [loaded] is true once a fetch has finished. */
        fun state(isEmpty: Boolean, loaded: Boolean, failure: String?): HistoryEmpty? {
            if (!isEmpty) return null
            if (failure != null) return Failed(failure)
            return if (loaded) None else Loading
        }
    }
}
