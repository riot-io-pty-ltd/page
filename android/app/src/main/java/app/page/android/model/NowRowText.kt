package app.page.android.model

import java.time.Instant

/** "waiting 4m", "finished 2m" (iOS NowRow.waitingText). */
fun NowRow.waitingText(now: Instant): String {
    val t = RelativeTime.compact(maxOf(0.0, now.secondsSince(waitingSince)).toLong())
    return (if (section == NowRow.Section.REVIEW) "finished " else "waiting ") + t
}
