package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/SkyModel.swift. Lanes: the fleet as a list. Every live
// session is a row with its own star glyph; every project folder is a group.
// Hue and glyph shape come from a stable hash of the folder (never a per-launch
// hash), so a project always looks the same. The model is still built through
// `SkyModel` (the fleet, the Mac's battery and the pause), which `LanesModel`
// turns into groups. Pure.

// MARK: - Stable hashing

object StableHash {
    /** FNV-1a over the UTF-8 bytes. The same on every launch and every device. */
    fun fnv1a(s: String): ULong {
        var h: ULong = 0xcbf29ce484222325UL
        for (b in s.toByteArray(Charsets.UTF_8)) {
            h = h xor (b.toULong() and 0xFFUL)
            h *= 0x100000001b3UL
        }
        return h
    }

    /** A repeatable number in 0..<1 for a key and a salt. */
    fun unit(s: String, salt: Int = 0): Double {
        val h = fnv1a("$salt|$s")
        return (h % 1_000_003UL).toDouble() / 1_000_003.0
    }
}

/** A project's own colour. Amber is not one of them: amber means "needs you". */
enum class ProjectHue(val hex: Int) {
    TEAL(0x5EEAD4), SKY(0x38BDF8), LIME(0xBEF264), VIOLET(0xA78BFA), ROSE(0xF9A8D4), WHITE(0xE5E7EB);

    companion object {
        fun of(key: String): ProjectHue = entries[(StableHash.fnv1a(key) % entries.size.toULong()).toInt()]
    }
}

// MARK: - Stars

/** Why a session's star looks the way it does. Every attribute is a real signal. */
enum class StarState(val raw: String) {
    /** Teal, working. */
    WORKING("working"),

    /** Amber, waiting for you. */
    NEEDS_YOU("needsYou"),

    /** A dashed amber ring: stuck. */
    STUCK("stuck"),

    /** A hollow star: rate-limited. */
    RATE_LIMITED("rateLimited"),

    /** Grey and dimmed: paused at the battery cutoff. */
    PAUSED("paused"),

    /** Dim white: idle. */
    IDLE("idle"),

    /** Not answering. */
    OFFLINE("offline");

    /** Most urgent first, for ordering groups and rows. */
    val urgency: Int
        get() = when (this) {
            NEEDS_YOU -> 0
            STUCK -> 1
            RATE_LIMITED -> 2
            WORKING -> 3
            PAUSED -> 4
            IDLE -> 5
            OFFLINE -> 6
        }

    /** "WORKING", "NEEDS YOU": as drawn on a lane. */
    val label: String
        get() = when (this) {
            WORKING -> "WORKING"
            NEEDS_YOU -> "NEEDS YOU"
            STUCK -> "LOOKS STUCK"
            RATE_LIMITED -> "RATE LIMITED"
            PAUSED -> "PAUSED"
            IDLE -> "IDLE"
            OFFLINE -> "OFFLINE"
        }

    companion object {
        fun fromRaw(raw: String): StarState? = entries.firstOrNull { it.raw == raw }

        fun of(session: LiveSession, stuck: Boolean, paused: Boolean): StarState {
            if (stuck) return STUCK
            return when (session.state) {
                LiveSessionState.WAITING_ON_USER, LiveSessionState.WAITING_ON_APPROVAL -> NEEDS_YOU
                LiveSessionState.ACTIVE -> if (paused) PAUSED else WORKING
                LiveSessionState.RATE_LIMITED -> RATE_LIMITED
                LiveSessionState.IDLE -> IDLE
                LiveSessionState.INTERRUPTED, LiveSessionState.FAILED, LiveSessionState.OFFLINE, LiveSessionState.UNKNOWN ->
                    if (session.state == LiveSessionState.OFFLINE) OFFLINE else IDLE
            }
        }
    }
}

data class SkyStar(
    val id: String,
    val title: String,
    val state: StarState,
    /** What it is doing now, clipped: "swift test", "rm -rf ...". */
    val lastAction: String,
    /** The open page behind a waiting star. */
    val interventionId: String?,
    val agent: String,
    val canType: Boolean,
    /** Seed for the star's own shape. */
    val seed: ULong,
)

data class Constellation(
    /** The folder (cwd), which is also the stable-hash key. */
    val key: String,
    /** "page", "bottle-flip". */
    val name: String,
    val hue: ProjectHue,
    val stars: List<SkyStar>,
) {
    val id: String get() = key

    /** The most urgent state any star here is in. */
    val urgentState: StarState get() = stars.map { it.state }.minByOrNull { it.urgency } ?: StarState.IDLE
}

// MARK: - The moon (the Mac)

data class MoonModel(
    /** "41%", or "—" when the Mac doesn't report one. */
    val percent: String,
    /** "on battery · cutoff in about 1 h 50 min", "on power". */
    val detail: String,
    /** 0..1, null when unknown. */
    val fraction: Double?,
    val onAC: Boolean,
) {
    companion object {
        fun build(status: MacStatusSnapshot?): MoonModel {
            val pct = status?.batteryPercent
            val onAC = status?.onAC == true
            var detail: String
            val forecast = status?.forecast
            if (status == null) detail = "no reading from your Mac"
            else if (onAC) detail = "on power"
            else if (forecast != null && forecast.minutes > 0) detail = "on battery · cutoff in about ${BatteryForecast.duration(forecast.minutes)}"
            else if (status.onAC == false) detail = "on battery"
            else detail = "power unknown"
            if (forecast != null && !onAC && forecast.minutes == 0) detail = "on battery · at the ${forecast.cutoff}% cutoff"
            return MoonModel(pct?.let { "$it%" } ?: "—", detail, pct?.let { it / 100.0 }, onAC)
        }
    }
}

// MARK: - The fleet

data class SkyModel(
    val constellations: List<Constellation>,
    /** "7 sessions · 3 projects". */
    val headline: String,
    val moon: MoonModel,
    val rings: List<RingStat>,
    val macName: String,
    val paused: Boolean,
) {
    val starCount: Int get() = constellations.sumOf { it.stars.size }
    val isEmpty: Boolean get() = constellations.isEmpty()

    companion object {
        /**
         * The project's name: the folder's last component. A cwd of "/" or the home folder is never shown as a
         * bare slash: it is the session's name, or "~" ([ProjectLabel]).
         */
        fun projectName(cwd: String, fallback: String): String = ProjectLabel.name(cwd, fallback)

        /**
         * The fleet, grouped by project. [interventions] are the open pages (a stuck page makes its session's star
         * stuck); [paused] is the battery pause. Pure.
         */
        fun build(
            sessions: List<LiveSession>, interventions: List<Intervention>, status: MacStatusSnapshot?,
            rings: List<RingStat>, macName: String, paused: Boolean, now: Instant,
        ): SkyModel {
            val stuckSessions = interventions.filter { it.kind == InterventionKind.IDLE && PageSubtype.isStuck(it.subtype) }.map { it.sessionId }.toSet()
            val groups = LinkedHashMap<String, MutableList<LiveSession>>()
            for (s in sessions) groups.getOrPut(if (s.cwd.isEmpty()) s.title else s.cwd) { ArrayList() }.add(s)
            val keys = groups.keys.sortedWith { a, b ->
                val na = projectName(a, a).lowercase()
                val nb = projectName(b, b).lowercase()
                if (na == nb) a.compareTo(b) else na.compareTo(nb)
            }
            val out = ArrayList<Constellation>()
            for (key in keys) {
                val list = (groups[key] ?: emptyList<LiveSession>()).sortedBy { it.id }
                val stars = ArrayList<SkyStar>()
                for (s in list) {
                    val state = StarState.of(s, stuckSessions.contains(s.id), paused)
                    stars.add(
                        SkyStar(
                            id = s.id, title = s.title, state = state,
                            lastAction = clip(s.preview, 28), interventionId = s.openPageId, agent = s.backend.displayName,
                            canType = s.canType, seed = StableHash.fnv1a(if (s.cwd.isEmpty()) s.id else s.cwd + "|" + s.id),
                        ),
                    )
                }
                out.add(Constellation(key, projectName(key, key), ProjectHue.of(key), stars))
            }
            val n = sessions.size
            val headline = if (n == 0) "No live sessions"
            else "$n session${if (n == 1) "" else "s"} · ${out.size} project${if (out.size == 1) "" else "s"}"
            return SkyModel(out, headline, MoonModel.build(status), rings, macName, paused)
        }

        fun clip(s: String, limit: Int): String {
            val t = Sw.trimWsNl(s).replace("\n", " ")
            return if (Sw.count(t) <= limit) t else Sw.chars(t).take(limit - 1).joinToString("") + "…"
        }
    }
}

// MARK: - Lanes

data class LaneRow(
    val id: String,
    val title: String,
    val state: StarState,
    val strip: List<StripCell>,
    val interventionId: String?,
    val agent: String,
    val seed: ULong,
    val lastAction: String,
)

data class LaneGroup(
    val key: String,
    val name: String,
    val hue: ProjectHue,
    val rows: List<LaneRow>,
) {
    val id: String get() = key
    val urgentState: StarState get() = rows.map { it.state }.minByOrNull { it.urgency } ?: StarState.IDLE
}

data class LanesModel(
    val groups: List<LaneGroup>,
    /** "-4h", "-3h", "-2h", "-1h", "now". */
    val axis: List<String>,
    /** The strip is drawn from what this phone saw: say so, once. */
    val coverageNote: String?,
) {
    companion object {
        /** Groups ordered needs-you first, then working, then idle; rows the same way inside a group, then by title. Pure. */
        fun build(sky: SkyModel, log: ActivityLog, now: Instant, hours: Int = 4): LanesModel {
            val groups = ArrayList<LaneGroup>()
            for (c in sky.constellations) {
                val rows = ArrayList<LaneRow>()
                for (s in c.stars) {
                    val strip = log.strip(s.id, now, hours, s.state)
                    rows.add(LaneRow(s.id, s.title, s.state, strip, s.interventionId, s.agent, s.seed, s.lastAction))
                }
                rows.sortWith(::laneOrder)
                groups.add(LaneGroup(c.key, c.name, c.hue, rows))
            }
            groups.sortWith(::groupOrder)
            val axis = (0 until hours).map { "-${hours - it}h" } + listOf("now")
            val observed = log.observedSpan(now, hours)
            val note: String? = if (observed >= hours * 3600.0 * 0.95) null
            else "Drawn from what this phone has seen while Page was open. Earlier time is left blank."
            return LanesModel(groups, axis, note)
        }

        private fun laneOrder(a: LaneRow, b: LaneRow): Int {
            if (a.state.urgency != b.state.urgency) return a.state.urgency.compareTo(b.state.urgency)
            return a.title.lowercase().compareTo(b.title.lowercase())
        }

        private fun groupOrder(a: LaneGroup, b: LaneGroup): Int {
            if (a.urgentState.urgency != b.urgentState.urgency) return a.urgentState.urgency.compareTo(b.urgentState.urgency)
            return a.name.lowercase().compareTo(b.name.lowercase())
        }
    }
}
