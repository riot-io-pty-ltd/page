package app.page.android.model

import java.time.DayOfWeek
import java.time.Instant
import java.time.ZoneId
import java.time.temporal.TemporalAdjusters
import java.time.temporal.WeekFields
import java.util.Locale

data class PageStats(
    val today: Int,
    val thisWeek: Int,
    val avgResponseSeconds: Long?,
    val repliedCount: Int,
    val topProjects: List<ProjectCount>,
) {
    data class ProjectCount(val name: String, val count: Int)

    companion object {
        /**
         * "This week" is the calendar week containing [now] (the locale's
         * first weekday). Average response only counts pages the user
         * actually answered. History and inbox are de-duplicated by id.
         */
        fun compute(
            history: List<Intervention>,
            inbox: List<Intervention>,
            now: Instant,
            zone: ZoneId = ZoneId.systemDefault(),
            firstDayOfWeek: DayOfWeek = WeekFields.of(Locale.getDefault()).firstDayOfWeek,
        ): PageStats {
            val byId = LinkedHashMap<String, Intervention>()
            for (iv in history) byId[iv.id] = iv
            for (iv in inbox) if (iv.id !in byId) byId[iv.id] = iv
            val all = byId.values.toList()

            val day = now.atZone(zone).toLocalDate()
            val dayStart = day.atStartOfDay(zone).toInstant()
            val weekStart = day.with(TemporalAdjusters.previousOrSame(firstDayOfWeek)).atStartOfDay(zone).toInstant()
            val times = all.mapNotNull { it.responseTimeSeconds }

            val top = all.groupingBy { it.projectName }.eachCount()
                .map { ProjectCount(it.key, it.value) }
                .sortedWith(compareByDescending<ProjectCount> { it.count }.thenBy { it.name })

            return PageStats(
                today = all.count { it.openedAt >= dayStart },
                thisWeek = all.count { it.openedAt >= weekStart },
                avgResponseSeconds = if (times.isEmpty()) null else times.sum() / times.size,
                repliedCount = times.size,
                topProjects = top.take(5),
            )
        }
    }
}
