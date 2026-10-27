package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/NowStream.swift. Two small pieces of the Now stream:
// the order that never re-sorts under a finger, and the In-flight ribbon (one
// strand per working session).

/**
 * A card is never re-sorted under a finger. While the stream is being touched, scrolled or has a sheet up, the
 * order you can see stays put: rows that have gone drop out, rows already shown keep their place and their
 * latest content, and new arrivals wait behind a "New ↑ 1" pill until you let go. Pure.
 */
object StableOrder {
    data class Result(
        /** What to draw, in order. */
        val rows: List<NowRow>,
        /** Arrivals held back while frozen. */
        val queuedNew: Int,
    )

    /** [shown] is the ids on screen now (in order); [ranked] is the fresh ranking. Not frozen: the fresh ranking, nothing queued. */
    fun merge(shown: List<String>, ranked: List<NowRow>, frozen: Boolean): Result {
        if (!frozen || shown.isEmpty()) return Result(ranked, 0)
        val byId = LinkedHashMap<String, NowRow>()
        for (r in ranked) if (r.id !in byId) byId[r.id] = r
        val kept = shown.mapNotNull { byId[it] }
        val known = shown.toSet()
        val fresh = ranked.filter { it.id !in known }
        return Result(kept, fresh.size)
    }
}

/** One working session as a strand in the ribbon. */
data class InFlightStrand(
    val id: String,
    val project: String,
    /** What it is doing, clipped: "vitest · 212 passed". */
    val lastAction: String,
    /** "4m", how long since it last did something; null when unknown. */
    val age: String?,
    val seed: ULong,
    val hue: ProjectHue,
    /** A workflow's progress, when the phone has it: 4 of 7. */
    val workflow: Pair<Int, Int>?,
) {
    companion object {
        /** Working sessions, the most recently active first. Pure. */
        fun build(sessions: List<LiveSession>, workflows: Map<String, List<WorkflowRun>>, now: Instant, limit: Int = 12): List<InFlightStrand> =
            sessions.filter { it.state == LiveSessionState.ACTIVE }
                .sortedWith { a, b -> (b.lastActivityAt ?: Instant.MIN).compareTo(a.lastActivityAt ?: Instant.MIN) }
                .take(limit)
                .map { s ->
                    val run = workflows[s.id]?.firstOrNull { it.isRunning }
                    InFlightStrand(
                        id = s.id, project = SkyModel.projectName(s.cwd, s.title),
                        lastAction = if (s.preview.isEmpty()) "working" else SkyModel.clip(s.preview, 34),
                        age = s.lastActivityAt?.let { RelativeTime.compact(maxOf(0.0, now.secondsSince(it)).toLong()) },
                        seed = StableHash.fnv1a(if (s.cwd.isEmpty()) s.id else s.cwd + "|" + s.id),
                        hue = ProjectHue.of(if (s.cwd.isEmpty()) s.title else s.cwd),
                        workflow = run?.let { Pair(it.done, it.total) },
                    )
                }
    }
}

// MARK: - The day's rings, in words

object RingSummary {
    /** "Two rings closed ✦", or "Tonight" while none is closed. Pure. */
    fun title(rings: List<RingStat>): String = when (rings.count { it.progress >= 1 }) {
        1 -> "One ring closed ✦"
        2 -> "Two rings closed ✦"
        in 3..Int.MAX_VALUE -> "All three rings closed ✦"
        else -> "Tonight"
    }

    /** "Unblocked 12/12 · Shipped 7/10 · Calm not tracked". Pure. */
    fun detail(rings: List<RingStat>): String = rings.joinToString(" · ") { "${it.kind.raw} ${it.detail}" }
}
