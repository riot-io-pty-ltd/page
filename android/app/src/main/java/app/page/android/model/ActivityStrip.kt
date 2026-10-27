package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Port of iOS/Page/Models/ActivityStrip.swift. The 4-hour activity strip on a
// lane. The Mac does not keep a per-session state history, so the phone draws
// what it has seen itself: it samples the session list while Page is open,
// five minutes to a bucket, and keeps the most urgent state it saw in each.
// Time it never saw is blank. It is never filled in with invented activity.

/** One five-minute bucket on a strip. `level` null means the phone did not see it. */
data class StripCell(var level: StarState?)

class ActivityLog {
    /** session id -> bucket index -> StarState raw value. */
    private val samples: MutableMap<String, MutableMap<Int, String>> = HashMap()

    /** The first sample ever recorded, to say how much of the strip was observed. */
    var firstSampleAt: Instant? = null
        private set
    var lastSampleAt: Instant? = null
        private set

    val sessionCount: Int get() = samples.size

    /**
     * Records the states seen at [at]. A bucket keeps the most urgent state seen in it, so a prompt that
     * appeared and cleared within five minutes still shows.
     */
    fun record(states: Map<String, StarState>, at: Instant) {
        val b = bucketIndex(at)
        for ((id, state) in states) {
            val row = samples.getOrPut(id) { HashMap() }
            val old = row[b]?.let { StarState.fromRaw(it) }
            if (old != null && old.urgency < state.urgency) {
                // Already holds something more urgent: keep it.
            } else {
                row[b] = state.raw
            }
        }
        if (firstSampleAt == null) firstSampleAt = at
        lastSampleAt = at
        prune(at)
    }

    /** Drops samples older than a day, and sessions with none left. */
    fun prune(now: Instant) {
        val oldest = bucketIndex(now.plusSeconds(-keep))
        val it = samples.entries.iterator()
        while (it.hasNext()) {
            val e = it.next()
            e.value.keys.removeAll { k -> k < oldest }
            if (e.value.isEmpty()) it.remove()
        }
    }

    /**
     * The strip for a session: `hours * 12` buckets, oldest first, ending with the bucket of [now]. The last
     * bucket is the session's state right now ([current]), which the phone has just been told.
     */
    fun strip(id: String, now: Instant, hours: Int = 4, current: StarState? = null): List<StripCell> {
        val count = hours * 12
        val end = bucketIndex(now)
        val row = samples[id] ?: emptyMap()
        val cells = (0 until count).map { i ->
            val b = end - (count - 1) + i
            StripCell(row[b]?.let { StarState.fromRaw(it) })
        }
        if (current != null && cells.isNotEmpty()) cells.last().level = current
        return cells
    }

    /** How much of the window this phone has watched, in seconds. */
    fun observedSpan(now: Instant, hours: Int = 4): Double {
        val first = firstSampleAt ?: return 0.0
        return minOf(hours * 3600.0, maxOf(0.0, now.secondsSince(first)))
    }

    // MARK: persistence (the phone's own preference; never synced)

    /** Compact JSON for SharedPreferences: {"first": ms, "last": ms, "s": {id: {bucket: state}}}. */
    fun toJson(): String {
        val s = JsonObject(samples.mapValues { (_, row) -> JsonObject(row.entries.associate { it.key.toString() to JsonPrimitive(it.value) }) })
        val o = LinkedHashMap<String, kotlinx.serialization.json.JsonElement>()
        firstSampleAt?.let { o["first"] = JsonPrimitive(it.toEpochMilli()) }
        lastSampleAt?.let { o["last"] = JsonPrimitive(it.toEpochMilli()) }
        o["s"] = s
        return JsonObject(o).toString()
    }

    companion object {
        /** Bucket length. */
        const val bucket: Double = 5 * 60.0

        /** How long samples are kept. */
        const val keep: Double = 24 * 3600.0
        const val storageKey = "page.activityLog"

        fun bucketIndex(at: Instant): Int = Math.floor(at.toEpochMilli() / 1000.0 / bucket).toInt()

        fun fromJson(text: String?): ActivityLog {
            val o = text?.let { parseJsonObject(it) } ?: return ActivityLog()
            val log = ActivityLog()
            log.firstSampleAt = o.num("first")?.let { PageDate.ofEpochMillis(it) }
            log.lastSampleAt = o.num("last")?.let { PageDate.ofEpochMillis(it) }
            val s = o.obj("s") ?: return log
            for ((id, rowEl) in s) {
                val row = rowEl as? JsonObject ?: continue
                val m = HashMap<Int, String>()
                for ((k, v) in row) {
                    val b = k.toIntOrNull() ?: continue
                    val raw = v.asString() ?: continue
                    if (StarState.fromRaw(raw) != null) m[b] = raw
                }
                if (m.isNotEmpty()) log.samples[id] = m
            }
            return log
        }
    }
}
