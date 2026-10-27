package app.page.android.model

import java.time.Instant
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

// Port of iOS/Page/Models/SkyModel.swift. Sky and Lanes: the fleet as
// constellations, and the same fleet as an accessible list. Every session is a
// star; every project folder is a constellation. Layout and hue come from a
// stable hash of the folder (never a per-launch hash), so a project always
// looks and sits the same. Pure.

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

/** Why a star looks the way it does. Every attribute is a real signal. */
enum class StarState(val raw: String) {
    /** Teal, working. */
    WORKING("working"),

    /** Amber, waiting for you. */
    NEEDS_YOU("needsYou"),

    /** A dashed amber orbit: stuck. */
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
    /** Where it sits in the sky: 0..1 across, 0..1 down. */
    val x: Double,
    val y: Double,
    /** 0.35..1: how recently it did something. Stillness is the signal. */
    val brightness: Double,
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
    /** Index pairs: stars in the same repository are joined by faint lines. */
    val links: List<List<Int>>,
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

// MARK: - Sky

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
        /** Past this many minutes of silence a star is as dim as it gets. */
        const val dimAfter: Double = 10 * 60.0
        const val brightFor: Double = 30.0

        /**
         * How bright a star is: full for 30 s after it last did something, then easing to 0.35 over ten
         * minutes. Idle and unknown activity sit at the floor. Pure.
         */
        fun brightness(lastActivityAt: Instant?, state: StarState, now: Instant): Double {
            if (lastActivityAt == null) return if (state == StarState.NEEDS_YOU) 1.0 else 0.35
            val age = maxOf(0.0, now.secondsSince(lastActivityAt))
            if (age <= brightFor) return 1.0
            val t = minOf(1.0, (age - brightFor) / (dimAfter - brightFor))
            val floor = if (state == StarState.NEEDS_YOU || state == StarState.STUCK) 0.8 else 0.35
            return maxOf(floor, 1 - t * 0.65)
        }

        /**
         * The project's name: the folder's last component. A cwd of "/" or the home folder is never shown as a
         * bare slash: it is the session's name, or "~" ([ProjectLabel]).
         */
        fun projectName(cwd: String, fallback: String): String = ProjectLabel.name(cwd, fallback)

        /**
         * The fleet as constellations. [interventions] are the open pages (a stuck page makes its session's star
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
            val rows = maxOf(1, (keys.size + 1) / 2)
            val out = ArrayList<Constellation>()
            for ((i, key) in keys.withIndex()) {
                val list = (groups[key] ?: emptyList<LiveSession>()).sortedBy { it.id }
                val col = i % 2
                val row = i / 2
                // A cell of the sky, with a repeatable nudge, so two projects never stack.
                val cellW = 0.5
                val cellH = 0.9 / rows.toDouble()
                val ax = (col + 0.5) * cellW + (StableHash.unit(key, 1) - 0.5) * 0.14
                val ay = 0.06 + (row + 0.5) * cellH + (StableHash.unit(key, 2) - 0.5) * cellH * 0.28
                val stars = ArrayList<SkyStar>()
                var angle = StableHash.unit(key, 3) * 2 * PI
                for ((k, s) in list.withIndex()) {
                    val state = StarState.of(s, stuckSessions.contains(s.id), paused)
                    val radius = if (k == 0) 0.0 else 0.09 + 0.07 * StableHash.unit(s.id, 4)
                    angle += 1.9 + StableHash.unit(s.id, 5)
                    val x = minOf(0.9, maxOf(0.1, ax + cos(angle) * radius * (if (k == 0) 0.0 else 1.0)))
                    val y = minOf(0.94, maxOf(0.05, ay + sin(angle) * radius * 1.3))
                    stars.add(
                        SkyStar(
                            id = s.id, title = s.title, state = state, x = x, y = y,
                            brightness = brightness(s.lastActivityAt, state, now),
                            lastAction = clip(s.preview, 28), interventionId = s.openPageId, agent = s.backend.displayName,
                            canType = s.canType, seed = StableHash.fnv1a(if (s.cwd.isEmpty()) s.id else s.cwd + "|" + s.id),
                        ),
                    )
                }
                val links = if (stars.size > 1) (1 until stars.size).map { listOf(it - 1, it) } else emptyList()
                val name = projectName(key, key)
                out.add(Constellation(key, name, ProjectHue.of(key), stars, links))
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

        // MARK: Label layout

        /** The sky is drawn below [labelTopPad] and over this share of the height; the Tonight card owns the rest. */
        const val labelTopPad: Double = 54.0
        const val labelSkyShare: Double = 0.58

        /** The Tonight card and the capsule's clearance hang from the bottom: labels stay above them. */
        const val labelBottomReserve: Double = 214.0

        /** The lowest a star may be drawn, and the height of the span a star's y runs over, in a sky of this size. */
        private fun starSpan(size: SkySize): Pair<Double, Double> {
            val lowest = maxOf(labelTopPad + 60, size.height - labelBottomReserve - 20)
            return Pair(lowest, minOf(size.height * labelSkyShare, (lowest - labelTopPad) / 0.94))
        }

        /**
         * Where a star is drawn in a sky of this size, before stars are kept apart. A short sky squeezes its stars
         * together rather than let them run under the Tonight card. Pure.
         */
        fun starPoint(s: SkyStar, size: SkySize): SkyPoint = SkyPoint(s.x * size.width, labelTopPad + s.y * starSpan(size).second)

        /**
         * Where every star is drawn, by id: [starPoint], then pushed apart until no two drawings overlap (a short
         * sky squeezes stars together) and kept on the sky. Deterministic. Pure.
         */
        fun starPoints(constellations: List<Constellation>, size: SkySize): Map<String, SkyPoint> {
            val stars = constellations.flatMap { it.stars }
            val pts = stars.map { starPoint(it, size).let { p -> doubleArrayOf(p.x, p.y) } }
            val radii = stars.map { nodeRadius(it.state) }
            val lowest = starSpan(size).first
            fun clamp(i: Int) {
                pts[i][0] = minOf(maxOf(pts[i][0], 8 + radii[i]), maxOf(8 + radii[i], size.width - 8 - radii[i]))
                pts[i][1] = minOf(maxOf(pts[i][1], labelTopPad), maxOf(labelTopPad, lowest))
            }
            for (pass in 0 until 24) {
                var moved = false
                for (i in stars.indices) {
                    for (j in stars.indices) {
                        if (j <= i) continue
                        var dx = pts[j][0] - pts[i][0]
                        var dy = pts[j][1] - pts[i][1]
                        var d = hypot(dx, dy)
                        val need = radii[i] + radii[j]
                        if (d >= need - 0.01) continue
                        if (d < 0.001) {
                            // On top of each other: split along a repeatable direction.
                            val a = ((i * 7 + j * 3 + pass) % 12).toDouble() * PI / 6
                            dx = cos(a); dy = sin(a); d = 1.0
                        }
                        val push = (need - hypot(dx, dy) + 0.5) / 2
                        pts[i][0] -= dx / d * push; pts[i][1] -= dy / d * push
                        pts[j][0] += dx / d * push; pts[j][1] += dy / d * push
                        clamp(i); clamp(j)
                        moved = true
                    }
                }
                if (!moved) break
            }
            val out = LinkedHashMap<String, SkyPoint>()
            for ((i, s) in stars.withIndex()) if (s.id !in out) out[s.id] = SkyPoint(pts[i][0], pts[i][1])
            return out
        }

        /** The most a star's tap target reaches (the drawn glyph is at most 38 dp). */
        const val maxHitRadius: Double = 28.0

        /**
         * The radius of each star's tap target, by id: at most [maxHitRadius], and at most half the distance to
         * the nearest other star, so no two targets can overlap and a tap always belongs to exactly the star drawn
         * under the finger. Pure.
         */
        fun hitRadii(constellations: List<Constellation>, size: SkySize): Map<String, Double> {
            val points = starPoints(constellations, size)
            val ids = constellations.flatMap { it.stars }.map { it.id }
            val out = LinkedHashMap<String, Double>()
            for (id in ids) {
                if (id in out) continue
                val p = points[id] ?: continue
                var nearest = Double.POSITIVE_INFINITY
                for (other in ids) {
                    if (other == id) continue
                    points[other]?.let { q -> nearest = minOf(nearest, hypot(p.x - q.x, p.y - q.y)) }
                }
                out[id] = minOf(maxHitRadius, nearest / 2)
            }
            return out
        }

        /** The star under a point, or null. Never ambiguous: the targets do not overlap. Pure. */
        fun hitTest(point: SkyPoint, constellations: List<Constellation>, size: SkySize): String? {
            val points = starPoints(constellations, size)
            val radii = hitRadii(constellations, size)
            return points.filter { (id, p) -> hypot(point.x - p.x, point.y - p.y) <= (radii[id] ?: 0.0) }
                .minByOrNull { hypot(point.x - it.value.x, point.y - it.value.y) }?.key
        }

        /** How far a star's drawing reaches: the orbit of a stuck star, the larger glyph of one that needs you. */
        fun nodeRadius(state: StarState): Double = when (state) {
            StarState.NEEDS_YOU -> 22.0
            StarState.STUCK -> 24.0
            StarState.RATE_LIMITED -> 14.0
            else -> 17.0
        }

        /**
         * Shortens from the end with "…": at a word edge ("-", "_", "/", ".", space) when that keeps at least half
         * the room, never leaving a space or separator in front of the dots. Pure.
         */
        fun ellipsize(s: String, maxChars: Int): String {
            val t = Sw.trimWsNl(s).replace("\n", " ")
            if (maxChars <= 0) return ""
            val chars = Sw.chars(t)
            if (chars.size <= maxChars) return t
            if (maxChars == 1) return "…"
            val budget = maxChars - 1
            val probe = chars.take(budget + 1)
            val edge = probe.indexOfLast { it in edgeChars }
            if (edge > 0 && edge >= (budget + 1) / 2) {
                return Sw.trimWs(probe.subList(0, edge).joinToString("")) + "…"
            }
            val head = Sw.trimWs(probe.take(budget).joinToString(""))
            return if (head.isEmpty()) "…" else "$head…"
        }

        private val edgeChars: Set<String> = " -_/.".map { it.toString() }.toSet()

        /**
         * Places labels so that none overlaps another, a node, an `avoid` rect, or leaves [canvas]. Captions (what
         * a star is doing) go first and sit beside their star; project names then take the nearest free spot
         * around any of their stars: above, below, beside, then a little further out. A label with no room at
         * full length is shortened from the end; one with no room at all is left out (the star still says what it
         * is when tapped). Deterministic: the same input gives the same rects. Pure.
         */
        fun layoutLabels(
            nodes: List<SkyLabelNode>, requests: List<SkyLabelRequest>, canvas: SkyRect, avoid: List<SkyRect> = emptyList(),
            metrics: SkyLabelMetrics = SkyLabelMetrics(),
        ): List<SkyLabelPlacement> {
            if (canvas.width <= 0 || canvas.height <= 0) return emptyList()
            val byId = LinkedHashMap<String, SkyLabelNode>()
            for (n in nodes) if (n.id !in byId) byId[n.id] = n
            val blocked = avoid.toMutableList()
            for (n in nodes) blocked.add(SkyRect(n.center.x - n.radius, n.center.y - n.radius, n.radius * 2, n.radius * 2))
            val placed = LinkedHashMap<String, SkyLabelPlacement>()
            val order = requests.filter { it.kind == SkyLabelKind.CAPTION } + requests.filter { it.kind == SkyLabelKind.PROJECT }
            for (req in order) {
                val anchors = req.anchors.mapNotNull { byId[it] }
                if (anchors.isEmpty() || key(req) in placed) continue
                val foreign = nodes.filter { it.id !in req.anchors }
                val texts = candidateTexts(req, requests, canvas, metrics)
                for ((i, text) in texts.withIndex()) {
                    val size = metrics.size(req.kind, Sw.count(text))
                    // The grid search is the slow one: only the shortest form gets it.
                    val rect = firstFit(req, anchors, foreign, size, canvas, blocked, metrics, grid = i == texts.size - 1)
                    if (rect != null) {
                        placed[key(req)] = SkyLabelPlacement(req.id, req.kind, text, rect)
                        blocked.add(rect)
                        break
                    }
                }
            }
            return requests.mapNotNull { placed[key(it)] }
        }

        private fun key(r: SkyLabelRequest): String = (if (r.kind == SkyLabelKind.PROJECT) "p|" else "c|") + r.id

        /**
         * The forms of a label to try, full length first, then ever shorter. Each form appears once. A project
         * name is never cut below 11 characters, and never to a stub that is also the start of another project's
         * name (`PAYM…`): it keeps its full form or goes without a name.
         */
        private fun candidateTexts(r: SkyLabelRequest, requests: List<SkyLabelRequest>, canvas: SkyRect, m: SkyLabelMetrics): List<String> {
            val widest: Int
            val floor: Int
            when (r.kind) {
                SkyLabelKind.PROJECT -> { widest = ((minOf(m.maxProjectWidth, canvas.width) - m.projectPadding * 2) / m.projectCharWidth).toInt(); floor = 11 }
                SkyLabelKind.CAPTION -> { widest = m.captionChars; floor = 1 }
            }
            val whole = ellipsize(r.text, maxOf(1, Sw.count(r.text)))
            val out = ArrayList<String>()
            for (c in listOf(widest, 18, 14, 11, 8, 5)) {
                if (!(c <= widest && c >= floor)) continue
                val text = ellipsize(r.text, c)
                if (text.isEmpty() || text in out) continue
                val size = m.size(r.kind, Sw.count(text))
                if (size.width > canvas.width || size.height > canvas.height) continue
                if (r.kind == SkyLabelKind.PROJECT && text != whole) {
                    val stem = Sw.dropLast(text)
                    if (requests.any { it.kind == SkyLabelKind.PROJECT && it.id != r.id && Sw.hasPrefix(it.text, stem) }) continue
                }
                out.add(text)
            }
            return out
        }

        /** How far a point is from a rectangle (0 inside it). */
        private fun distance(p: SkyPoint, rect: SkyRect): Double =
            hypot(maxOf(rect.minX - p.x, 0.0, p.x - rect.maxX), maxOf(rect.minY - p.y, 0.0, p.y - rect.maxY))

        private fun firstFit(
            r: SkyLabelRequest, anchors: List<SkyLabelNode>, foreign: List<SkyLabelNode>, size: SkySize, canvas: SkyRect,
            blocked: List<SkyRect>, m: SkyLabelMetrics, grid: Boolean,
        ): SkyRect? {
            val pad = m.clearance
            fun free(rect: SkyRect): Boolean {
                if (!canvas.contains(rect)) return false
                if (blocked.any { it.insetBy(-pad, -pad).intersects(rect) }) return false
                // A project's name reads as belonging to the nearest star: never to another project's.
                if (!(r.kind == SkyLabelKind.PROJECT && foreign.isNotEmpty())) return true
                val own = anchors.minOfOrNull { distance(it.center, rect) } ?: Double.POSITIVE_INFINITY
                return !foreign.any { distance(it.center, rect) < own - 0.5 }
            }
            fun inside(x: Double, y: Double): SkyRect =
                SkyRect(minOf(maxOf(x, canvas.minX), canvas.maxX - size.width), minOf(maxOf(y, canvas.minY), canvas.maxY - size.height), size.width, size.height)
            val w = size.width
            val h = size.height
            // Closest first; each step out is another try at every position.
            for (ring in listOf(0.0, 10.0, 24.0, 42.0)) {
                for (a in anchors) {
                    val c = a.center
                    val d = a.radius + m.gap + ring
                    val spots: List<SkyRect> = when (r.kind) {
                        SkyLabelKind.CAPTION -> {
                            val right = inside(c.x + d, c.y - h / 2)
                            val left = inside(c.x - d - w, c.y - h / 2)
                            (if (r.preferLeft) listOf(left, right) else listOf(right, left)) +
                                listOf(inside(c.x - w / 2, c.y - d - h), inside(c.x - w / 2, c.y + d))
                        }
                        SkyLabelKind.PROJECT -> listOf(
                            inside(c.x - w / 2, c.y - d - h), inside(c.x - w / 2, c.y + d),
                            inside(c.x + d, c.y - h / 2), inside(c.x - d - w, c.y - h / 2),
                            inside(c.x - 8, c.y - d - h), inside(c.x + 8 - w, c.y - d - h),
                            inside(c.x - 8, c.y + d), inside(c.x + 8 - w, c.y + d),
                        )
                    }
                    spots.firstOrNull { free(it) }?.let { return it }
                }
            }
            // Still nothing: the nearest free spot anywhere within reach of a star, on a coarse grid.
            if (!grid) return null
            var bestDistance = Double.POSITIVE_INFINITY
            var bestRect: SkyRect? = null
            var y = canvas.minY
            while (y + size.height <= canvas.maxY) {
                var x = canvas.minX
                while (x + size.width <= canvas.maxX) {
                    val rect = SkyRect(x, y, size.width, size.height)
                    val near = anchors.minOfOrNull { distance(it.center, rect) } ?: Double.POSITIVE_INFINITY
                    if (near <= m.reach && near < bestDistance && free(rect)) { bestDistance = near; bestRect = rect }
                    x += 4
                }
                y += 4
            }
            return bestRect
        }

        /**
         * Every label of a sky of this size: each project's name, and what the stars that need you (or look
         * stuck) are doing. This is what the views draw. Pure.
         */
        fun labelLayout(constellations: List<Constellation>, size: SkySize, metrics: SkyLabelMetrics = SkyLabelMetrics()): List<SkyLabelPlacement> {
            val nodes = ArrayList<SkyLabelNode>()
            val requests = ArrayList<SkyLabelRequest>()
            val points = starPoints(constellations, size)
            // Most urgent first, so the labels that matter keep their place when the sky is full.
            for (c in constellations.sortedBy { it.urgentState.urgency }) {
                val ordered = c.stars.sortedWith { a, b -> if (a.y == b.y) a.x.compareTo(b.x) else a.y.compareTo(b.y) }
                for (s in c.stars) {
                    nodes.add(SkyLabelNode(s.id, points[s.id] ?: starPoint(s, size), nodeRadius(s.state)))
                    if ((s.state == StarState.NEEDS_YOU || s.state == StarState.STUCK) && s.lastAction.isNotEmpty()) {
                        requests.add(SkyLabelRequest(s.id, SkyLabelKind.CAPTION, s.lastAction, listOf(s.id), preferLeft = s.x > 0.55))
                    }
                }
                requests.add(SkyLabelRequest(c.key, SkyLabelKind.PROJECT, c.name.uppercase(), ordered.map { it.id }))
            }
            val bottom = minOf(labelTopPad + size.height * labelSkyShare + 6, size.height - labelBottomReserve)
            val canvas = SkyRect(8.0, 8.0, maxOf(0.0, size.width - 16), maxOf(0.0, bottom - 8))
            // The moon (the Mac's battery) sits top right.
            val moon = SkyRect(size.width - 64 - 70, 34.0 - 26, 140.0, 52.0)
            return layoutLabels(nodes, requests, canvas, listOf(moon), metrics)
        }
    }
}

// MARK: - Label geometry

/** Plain geometry for the layout (no UI framework types, so it runs in JVM tests). */
data class SkyPoint(val x: Double, val y: Double)
data class SkySize(val width: Double, val height: Double)
data class SkyRect(val x: Double, val y: Double, val width: Double, val height: Double) {
    val minX: Double get() = x
    val minY: Double get() = y
    val maxX: Double get() = x + width
    val maxY: Double get() = y + height
    val midX: Double get() = x + width / 2
    val midY: Double get() = y + height / 2

    /** Rectangles that only share an edge do not intersect. */
    fun intersects(o: SkyRect): Boolean = x < o.maxX && o.x < maxX && y < o.maxY && o.y < maxY

    fun contains(o: SkyRect): Boolean {
        val e = 1e-9
        return o.x >= x - e && o.y >= y - e && o.maxX <= maxX + e && o.maxY <= maxY + e
    }

    fun insetBy(dx: Double, dy: Double): SkyRect = SkyRect(x + dx, y + dy, width - 2 * dx, height - 2 * dy)
}

enum class SkyLabelKind { PROJECT, CAPTION }

/** A star as an obstacle: where it is and how far its drawing reaches. */
data class SkyLabelNode(val id: String, val center: SkyPoint, val radius: Double)

/** A label to place. [anchors] are the nodes it may sit beside, the preferred one first. */
data class SkyLabelRequest(
    val id: String,
    val kind: SkyLabelKind,
    /** As it should read; layout shortens it from the end, with "…", only when it has no room. */
    val text: String,
    val anchors: List<String>,
    /** Captions: try the left side of the node first. */
    val preferLeft: Boolean = false,
)

data class SkyLabelPlacement(
    val id: String,
    val kind: SkyLabelKind,
    /** What to draw: the request's text, or its shortened form. */
    val text: String,
    val rect: SkyRect,
)

/**
 * Estimated label boxes. Layout cannot measure text, so the views draw each label in exactly the box it was
 * given (at most font scale 1.3 on Android: the sky layer caps it).
 */
data class SkyLabelMetrics(
    val projectCharWidth: Double = 7.8,
    val projectPadding: Double = 10.0,
    val projectHeight: Double = 24.0,
    val captionCharWidth: Double = 6.6,
    val captionHeight: Double = 14.0,
    /** Between a label and its node. */
    val gap: Double = 5.0,
    /** Nothing else comes closer to a label than this. */
    val clearance: Double = 3.0,
    val maxProjectWidth: Double = 220.0,
    /** The furthest a project name's nearest edge may sit from one of its own stars, on the grid fallback. */
    val reach: Double = 80.0,
    val captionChars: Int = 12,
) {
    fun size(kind: SkyLabelKind, chars: Int): SkySize = when (kind) {
        SkyLabelKind.PROJECT -> SkySize(chars * projectCharWidth + projectPadding * 2, projectHeight)
        SkyLabelKind.CAPTION -> SkySize(chars * captionCharWidth, captionHeight)
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
