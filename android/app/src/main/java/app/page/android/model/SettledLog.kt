package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Locale

// Port of iOS/Page/Models/SettledLog.swift. "Settled": what History becomes
// inside Now. Today's resolved pages read as short receipt lines; each earlier
// day collapses to one headline card ("Tue · 14 decided · 6 finished · 2 stuck
// · battery pause ×1"). Pure: the caller passes `now` and the zone.

data class SettledLine(
    val id: String,
    val tone: Tone,
    /** "Approved npm test", "Sent “use the cache”", "Answered in the terminal". */
    val text: String,
    /** "12m", relative to now. */
    val age: String,
    /** "delivered ✓" only when the Mac confirmed it; "sent" until then; null for pages Page did not answer. */
    val status: String?,
    val at: Instant,
) {
    enum class Tone(val raw: String) { APPROVED("approved"), SENT("sent"), NEUTRAL("neutral") }
}

data class SettledDay(
    /** Start of that day. */
    val day: Instant,
    val decided: Int,
    val finished: Int,
    val stuck: Int,
    val batteryPauses: Int,
    /** "Tue · 14 decided · 6 finished · 2 stuck · battery pause ×1". */
    val headline: String,
)

data class SettledLog(val today: List<SettledLine>, val days: List<SettledDay>) {
    companion object {
        /** Earlier days shown as headline cards. */
        const val dayLimit = 14

        /** Lines shown for today. */
        const val lineLimit = 12

        // MARK: classification

        /** A page the user answered from Page (a decision). */
        fun isDecision(iv: Intervention): Boolean =
            iv.repliedAt != null && (iv.kind == InterventionKind.APPROVAL || iv.kind == InterventionKind.USER_INPUT || iv.repliedAction != null)

        fun isStuck(iv: Intervention): Boolean = iv.kind == InterventionKind.IDLE && PageSubtype.isStuck(iv.subtype)
        fun isBatteryPause(iv: Intervention): Boolean = iv.kind == InterventionKind.IDLE && iv.subtype == "low_battery"

        /** A finished turn: an idle page that is not a stuck or battery page. */
        fun isFinishedTurn(iv: Intervention): Boolean =
            iv.kind == InterventionKind.IDLE && !PageSubtype.isStuck(iv.subtype) && iv.subtype != "low_battery"

        fun settledAt(iv: Intervention): Instant = iv.repliedAt ?: iv.closedAt ?: iv.openedAt

        // MARK: build

        fun build(history: List<Intervention>, now: Instant, zone: ZoneId = ZoneId.systemDefault()): SettledLog {
            val todayStart = startOfDay(now, zone)
            val items = history.sortedByDescending { settledAt(it) }
            val lines = items.filter { settledAt(it) >= todayStart }.take(lineLimit).map { line(it, now) }
            val buckets = LinkedHashMap<Instant, MutableList<Intervention>>()
            for (iv in items) {
                if (settledAt(iv) < todayStart) buckets.getOrPut(startOfDay(settledAt(iv), zone)) { ArrayList() }.add(iv)
            }
            val days = buckets.keys.sortedDescending().take(dayLimit).map { day -> card(day, buckets[day] ?: emptyList(), zone) }
            return SettledLog(lines, days)
        }

        fun line(iv: Intervention, now: Instant): SettledLine {
            val at = settledAt(iv)
            val age = RelativeTime.compact(maxOf(0.0, now.secondsSince(at)).toLong())
            val delivered = iv.deliveryStatus == "delivered"
            val status: String? = if (iv.repliedAt == null) null else (if (delivered) "delivered ✓" else (if (iv.deliveryStatus == "failed") "not delivered" else "sent"))

            if (iv.repliedAt == null) {
                return SettledLine(iv.id, SettledLine.Tone.NEUTRAL, CloseReason.description(iv.closeReason), age, null, at)
            }
            val subject = NowRowBuilder.summaryLine(iv)
            return when (iv.repliedAction) {
                "approve" -> SettledLine(iv.id, SettledLine.Tone.APPROVED, "Approved $subject", age, status, at)
                "deny" -> SettledLine(iv.id, SettledLine.Tone.NEUTRAL, (if (PageSubtype.canStop(iv.subtype)) "Stopped " else "Denied ") + subject, age, status, at)
                "carry_on" -> SettledLine(iv.id, SettledLine.Tone.SENT, "Carried on · ${iv.projectName}", age, status, at)
                else -> {
                    val said = Sw.trimWsNl(iv.repliedText ?: "")
                    val clipped = if (Sw.count(said) > 28) Sw.prefix(said, 27) + "…" else said
                    SettledLine(iv.id, SettledLine.Tone.SENT, if (clipped.isEmpty()) "Replied · ${iv.projectName}" else "Sent “$clipped”", age, status, at)
                }
            }
        }

        fun card(day: Instant, items: List<Intervention>, zone: ZoneId = ZoneId.systemDefault()): SettledDay {
            val decided = items.count { isDecision(it) }
            val finished = items.count { isFinishedTurn(it) }
            val stuck = items.count { isStuck(it) }
            val battery = items.count { isBatteryPause(it) }
            val dow = day.atZone(zone).dayOfWeek.getDisplayName(TextStyle.SHORT, Locale.US)
            val summary = summaryText(decided, finished, stuck, battery)
            return SettledDay(day, decided, finished, stuck, battery, listOf(dow, summary).joinToString(" · "))
        }

        /** "14 decided · 6 finished · 2 stuck · battery pause ×1", or "quiet" for a day with none. */
        fun summaryText(decided: Int, finished: Int, stuck: Int, battery: Int): String {
            val parts = ArrayList<String>()
            if (decided > 0) parts.add("$decided decided")
            if (finished > 0) parts.add("$finished finished")
            if (stuck > 0) parts.add("$stuck stuck")
            if (battery > 0) parts.add("battery pause ×$battery")
            return if (parts.isEmpty()) "quiet" else parts.joinToString(" · ")
        }
    }
}
