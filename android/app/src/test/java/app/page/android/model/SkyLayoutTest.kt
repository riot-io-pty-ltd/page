package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.hypot

/**
 * The Sky: constellations and star states, brightness, the hash and hue, ellipsis and label layout at phone
 * sizes, and hit targets, ported from the "Night Watch (iOS): Sky, Lanes..." and "Sky labels" and "Steer safety:
 * tap targets" checks in iOS/Tests/LogicTests.swift.
 */
class SkyLayoutTest {
    private fun near(a: Double, b: Double, eps: Double = 1e-6) = abs(a - b) < eps

    private val s1 = nwSession("s1", title = "page", state = "active", cwd = "~/projects/page", activeAt = NW_T0 - 20)
    private val s2 = nwSession("s2", title = "page-2", state = "waitingOnApproval", cwd = "~/projects/page", interventionId = "a1", activeAt = NW_T0 - 60)
    private val s3 = nwSession("s3", title = "bottle", state = "idle", cwd = "~/projects/bottle-flip")

    private fun sky(sessions: List<LiveSession>, interventions: List<Intervention> = emptyList(), paused: Boolean = false): SkyModel =
        SkyModel.build(sessions, interventions, null, emptyList(), "M", paused, nwNow)

    private fun byId(s: SkyModel): Map<String, SkyStar> = s.constellations.flatMap { it.stars }.associateBy { it.id }

    // MARK: constellations and stars

    @Test fun `constellations are ordered by project name and the headline counts sessions and projects`() {
        val s = sky(listOf(s1, s2, s3))
        assertEquals(listOf("bottle-flip", "page"), s.constellations.map { it.name })
        assertEquals("3 sessions · 2 projects", s.headline)
        assertEquals(3, s.starCount)
    }

    @Test fun `stars in one repo are linked and a constellation shows its most urgent star`() {
        val s = sky(listOf(s1, s2, s3))
        val page = s.constellations.first { it.name == "page" }
        assertEquals(1, page.links.size)
        assertEquals(2, page.stars.size)
        assertEquals(StarState.NEEDS_YOU, page.urgentState)
        val stars = byId(s)
        assertEquals(StarState.NEEDS_YOU, stars["s2"]?.state)
        assertEquals(StarState.WORKING, stars["s1"]?.state)
        assertEquals(StarState.IDLE, stars["s3"]?.state)
    }

    @Test fun `a star that just acted is full bright and a star waiting on you is never dim`() {
        val stars = byId(sky(listOf(s1, s2, s3)))
        assertTrue(near(stars["s1"]!!.brightness, 1.0))
        assertTrue(stars["s2"]!!.brightness >= 0.8)
    }

    @Test fun `star positions stay on the sky and equal input gives an equal sky`() {
        val s = sky(listOf(s1, s2, s3))
        assertTrue(s.constellations.flatMap { it.stars }.all { it.x in 0.05..0.95 && it.y in 0.05..0.95 })
        assertEquals(s, sky(listOf(s1, s2, s3)))
    }

    @Test fun `a stuck page makes its session's star stuck`() {
        val stuck = sky(
            listOf(s1),
            listOf(nwIv("l", InterventionKind.IDLE, "x", session = "s1", subtype = "looping")),
        )
        assertEquals(StarState.STUCK, stuck.constellations.first().stars.first().state)
    }

    @Test fun `a battery pause dims working stars and not the waiting ones`() {
        val paused = byId(sky(listOf(s1, s2, s3), paused = true))
        assertEquals(StarState.PAUSED, paused["s1"]?.state)
        assertEquals(StarState.NEEDS_YOU, paused["s2"]?.state)
    }

    @Test fun `an empty sky says so`() {
        val empty = sky(emptyList())
        assertEquals("No live sessions", empty.headline)
        assertTrue(empty.isEmpty)
    }

    @Test fun `brightness is full for 30 s, dims to 0 35 at ten minutes, and needs-you has a 0 8 floor`() {
        assertEquals(1.0, SkyModel.brightness(nwNow.minusSeconds(30), StarState.WORKING, nwNow), 0.0)
        assertTrue(near(SkyModel.brightness(nwNow.minusSeconds(600), StarState.WORKING, nwNow), 0.35))
        assertEquals(1.0, SkyModel.brightness(null, StarState.NEEDS_YOU, nwNow), 0.0)
        assertTrue(near(SkyModel.brightness(null, StarState.IDLE, nwNow), 0.35))
        assertTrue(SkyModel.brightness(nwNow.minusSeconds(600), StarState.NEEDS_YOU, nwNow) >= 0.8)
    }

    @Test fun `the project name is the folder, ignores a trailing slash, and home reads tilde`() {
        assertEquals("page", SkyModel.projectName("~/projects/page", "x"))
        assertEquals("page", SkyModel.projectName("~/projects/page/", "x"))
        assertEquals("~", SkyModel.projectName("~", "fb"))
    }

    @Test fun `the FNV-1a hash matches its published values and the unit draw stays in range`() {
        assertEquals(0xcbf29ce484222325uL, StableHash.fnv1a(""))
        assertEquals(0xaf63dc4c8601ec8cuL, StableHash.fnv1a("a"))
        assertEquals(StableHash.unit("page", 2), StableHash.unit("page", 2), 0.0)
        val u = StableHash.unit("page", 2)
        assertTrue(u >= 0.0 && u < 1.0)
    }

    @Test fun `a project hue is stable and never amber`() {
        assertEquals(ProjectHue.of("~/projects/page"), ProjectHue.of("~/projects/page"))
        val amber = listOf(0xF59E0B, 0xFBBF24, 0xFFB020, 0xF5A524)
        assertFalse(ProjectHue.entries.any { it.hex in amber })
    }

    // MARK: lanes and the activity strip

    @Test fun `lane groups are needs you, working, idle, with the axis and the coverage note`() {
        val needs = nwSession("n1", title = "needs", state = "waitingOnApproval", cwd = "~/a/needs", interventionId = "x1")
        val work = nwSession("w1", title = "work", state = "active", cwd = "~/a/work", activeAt = NW_T0 - 10)
        val idle = nwSession("i1", title = "idle", state = "idle", cwd = "~/a/idle")
        val sky2 = sky(listOf(idle, work, needs))
        val lanes = LanesModel.build(sky2, ActivityLog(), nwNow)
        assertEquals(listOf("needs", "work", "idle"), lanes.groups.map { it.name })
        assertEquals(listOf("-4h", "-3h", "-2h", "-1h", "now"), lanes.axis)
        assertNotNull("an empty log says what is blank", lanes.coverageNote)
        val seen = ActivityLog()
        seen.record(mapOf(needs.id to StarState.NEEDS_YOU, work.id to StarState.WORKING, idle.id to StarState.IDLE), nwNow.minusSeconds(4L * 3600))
        seen.record(mapOf(needs.id to StarState.NEEDS_YOU, work.id to StarState.WORKING, idle.id to StarState.IDLE), nwNow)
        assertNull("four hours watched is full coverage", LanesModel.build(sky2, seen, nwNow).coverageNote)
        assertEquals(needs.id, LanesModel.build(sky2, seen, nwNow).groups.first().rows.first().id)
        val brandNew = ActivityLog()
        brandNew.record(mapOf(needs.id to StarState.NEEDS_YOU), nwNow)
        assertNotNull("a just-started watch says the strip is partial", LanesModel.build(sky2, brandNew, nwNow).coverageNote)
    }

    @Test fun `the strip is 48 blank cells for an unseen session and ends with the current state`() {
        val log = ActivityLog()
        val cells = log.strip("s", nwNow, 4, null)
        assertEquals(48, cells.size)
        assertTrue(cells.all { it.level == null })
        log.record(mapOf("s" to StarState.WORKING), nwNow)
        assertEquals(StarState.NEEDS_YOU, log.strip("s", nwNow, 4, StarState.NEEDS_YOU).last().level)
        assertEquals(StarState.WORKING, log.strip("s", nwNow, 4).last().level)
        assertNull("unobserved cells stay blank", log.strip("s", nwNow, 4).first().level)
    }

    @Test fun `one five-minute bucket keeps the more urgent state seen in it`() {
        val same = ActivityLog()
        same.record(mapOf("s" to StarState.WORKING), nwNow)
        same.record(mapOf("s" to StarState.NEEDS_YOU), nwNow.plusSeconds(10))
        same.record(mapOf("s" to StarState.WORKING), nwNow.plusSeconds(20))
        assertEquals(StarState.NEEDS_YOU, same.strip("s", nwNow.plusSeconds(20), 4).last().level)
    }

    @Test fun `samples older than a day are pruned and the observed span is capped at the window`() {
        val old = ActivityLog()
        old.record(mapOf("old" to StarState.WORKING), nwNow.minusSeconds(25L * 3600))
        old.record(mapOf("new" to StarState.IDLE), nwNow)
        assertEquals("the old session's samples are gone", 1, old.sessionCount)
        val span = ActivityLog()
        span.record(mapOf("s" to StarState.IDLE), nwNow.minusSeconds(10L * 3600))
        assertEquals(4.0 * 3600, span.observedSpan(nwNow), 0.0)
        val short = ActivityLog()
        short.record(mapOf("s" to StarState.IDLE), nwNow.minusSeconds(60))
        assertEquals(60.0, short.observedSpan(nwNow), 0.0)
        assertEquals(ActivityLog.bucketIndex(nwNow), ActivityLog.bucketIndex(nwNow.plusSeconds(299)))
    }

    // MARK: the Mac chip and the Tower's power

    @Test fun `the Mac chip reads the battery, the cutoff warning and the offline states`() {
        val mac = "Studio MBP"
        assertEquals(MacChipModel("Studio MBP · on battery · 41%", MacChipModel.Tone.OK), MacChipModel.build(mac, nwStatus(connected = true, age = 5.0, battery = 41, onAC = false), nwNow))
        val soon = nwStatus(connected = true, age = 5.0, battery = 41, onAC = false, forecast = BatteryForecast(10, 20, 0.0))
        assertEquals(MacChipModel.Tone.WARN, MacChipModel.build(mac, soon, nwNow).tone)
        assertEquals(MacChipModel("Studio MBP · offline", MacChipModel.Tone.OFFLINE), MacChipModel.build(mac, nwStatus(connected = false, age = 5.0), nwNow))
        assertEquals(MacChipModel("Studio MBP · not checking in", MacChipModel.Tone.OFFLINE), MacChipModel.build(mac, nwStatus(connected = true, age = 300.0), nwNow))
        assertEquals(MacChipModel("Studio MBP", MacChipModel.Tone.OK), MacChipModel.build(mac, null, nwNow))
    }

    @Test fun `the Tower power reads the cutoff in words, on power, and no reading`() {
        val fc = BatteryForecast(10, 148, 20.0)
        val tp = TowerPower.build(nwStatus(connected = true, age = 5.0, battery = 41, onAC = false, forecast = fc))
        assertEquals("41% · cutoff in about 2 h 28 min", tp.headline)
        assertEquals("on battery", tp.state)
        assertFalse(tp.warn)
        assertTrue(near(tp.fraction ?: -1.0, 0.41) && near(tp.cutoffFraction ?: -1.0, 0.10))
        assertTrue(TowerPower.build(nwStatus(connected = true, age = 5.0, battery = 41, onAC = false, forecast = BatteryForecast(10, 20, 0.0))).warn)
        val ac = TowerPower.build(nwStatus(connected = true, age = 5.0, battery = 82, onAC = true))
        assertEquals("82% · agents keep running on power", ac.headline)
        assertEquals("on power", ac.state)
        assertEquals("No reading from your Mac", TowerPower.build(null).headline)
    }

    @Test fun `the Tower's one Mac row is active and says live and the pairing date`() {
        val rows = TowerMacRow.build("Studio MBP", at(NW_T0 - 86_400.0 * 15), nwStatus(connected = true, age = 5.0), nwNow, NW_ZONE)
        assertEquals(1, rows.size)
        assertTrue(rows[0].isActive)
        assertEquals("Active", rows[0].trailing)
        assertTrue(rows[0].subtitle, rows[0].subtitle.startsWith("live · paired "))
        assertEquals("31 Dec", TowerMacRow.pairedDate(at(NW_T0 - 86_400.0 * 15), NW_ZONE))
    }

    // MARK: ellipsis and star placement

    @Test fun `ellipsis cuts from the end at a word edge when that keeps half the room, always with dots`() {
        assertEquals("mac-on-claude-code…", SkyModel.ellipsize("mac-on-claude-code-extra-long", 20))
        assertEquals("rm -rf…", SkyModel.ellipsize("rm -rf Builds/Dev/*.app", 12))
        assertEquals("cargo test…", SkyModel.ellipsize("cargo test ×6", 12))
        assertEquals("a very…", SkyModel.ellipsize("a very long label here", 9))
        assertEquals("foo…", SkyModel.ellipsize("foo bar", 5))
        assertEquals("ab…", SkyModel.ellipsize("abcdef", 3))
        assertEquals("averyve…", SkyModel.ellipsize("averyveryverylongword", 8))
        assertEquals("…", SkyModel.ellipsize("abc", 1))
        assertEquals("hi", SkyModel.ellipsize("  hi  ", 5))
        assertEquals("", SkyModel.ellipsize("anything", 0))
        assertEquals("line break", SkyModel.ellipsize("line\nbreak", 20))
    }

    @Test fun `ellipsis never runs past its budget or leaves a separator before the dots`() {
        for (n in 1..25) for (s in listOf("mac-on-claude-code-extra-long", "rm -rf Builds/Dev/*.app", "cargo test ×6", "a-b-c-d-e-f-g", "x")) {
            val t = SkyModel.ellipsize(s, n)
            assertTrue("$t over $n", t.length <= n)
            assertFalse(t.contains(" …"))
            assertFalse(t.contains("-…"))
        }
    }

    private fun star(y: Double, x: Double = 0.5) = SkyStar(
        id = "s", title = "s", state = StarState.WORKING, x = x, y = y, brightness = 1.0, lastAction = "",
        interventionId = null, agent = "Claude", canType = true, seed = 0uL,
    )

    @Test fun `a short sky keeps its lowest star above the Tonight card and a tall sky keeps the old spacing`() {
        val shortSky = SkySize(393.0, 548.0)
        assertTrue(SkyModel.starPoint(star(0.94), shortSky).y <= shortSky.height - SkyModel.labelBottomReserve - 20 + 1e-6)
        val tallSky = SkySize(393.0, 740.0)
        assertTrue(near(SkyModel.starPoint(star(0.94), tallSky).y, 54 + 0.94 * 740 * 0.58))
        assertTrue(near(SkyModel.starPoint(star(0.5, x = 0.25), tallSky).x, 0.25 * 393))
        assertEquals(SkyModel.starPoint(star(0.94), shortSky), SkyModel.starPoint(star(0.94), shortSky))
    }

    @Test fun `node radii are the iOS radii`() {
        assertEquals(22.0, SkyModel.nodeRadius(StarState.NEEDS_YOU), 0.0)
        assertEquals(24.0, SkyModel.nodeRadius(StarState.STUCK), 0.0)
        assertEquals(14.0, SkyModel.nodeRadius(StarState.RATE_LIMITED), 0.0)
        assertEquals(17.0, SkyModel.nodeRadius(StarState.WORKING), 0.0)
        assertEquals(17.0, SkyModel.nodeRadius(StarState.IDLE), 0.0)
    }

    @Test fun `rectangles touching at an edge do not intersect and contains tolerates rounding`() {
        val box = SkyRect(0.0, 0.0, 10.0, 10.0)
        assertFalse(box.intersects(SkyRect(10.0, 0.0, 10.0, 10.0)))
        assertTrue(box.intersects(SkyRect(9.5, 9.5, 10.0, 10.0)))
        assertTrue(box.contains(box))
        assertFalse(box.contains(SkyRect(1.0, 1.0, 10.0, 10.0)))
        assertTrue(box.contains(SkyRect(0.0, 0.0, 10.0 + 1e-10, 10.0)))
    }

    // MARK: label layout

    /** What the Sky's labels must never do: overlap each other, cover a star or the moon, or leave the canvas. */
    private fun labelProblems(placed: List<SkyLabelPlacement>, nodes: List<SkyLabelNode>, canvas: SkyRect, avoid: List<SkyRect> = emptyList()): List<String> {
        val out = ArrayList<String>()
        for ((i, p) in placed.withIndex()) {
            if (!canvas.contains(p.rect)) out.add("${p.text} leaves the canvas")
            for (n in nodes) {
                val star = SkyRect(n.center.x - n.radius, n.center.y - n.radius, n.radius * 2, n.radius * 2)
                if (p.rect.intersects(star)) out.add("${p.text} covers ${n.id}")
            }
            for (r in avoid) if (p.rect.intersects(r)) out.add("${p.text} covers an avoided rect")
            for (q in placed.subList(i + 1, placed.size)) if (p.rect.intersects(q.rect)) out.add("${p.text} overlaps ${q.text}")
        }
        return out
    }

    @Test fun `two close names overlap nothing, keep request order, and a canvas too short gives none`() {
        val canvas = SkyRect(8.0, 8.0, 377.0, 600.0)
        val near = listOf(SkyLabelNode("a", SkyPoint(100.0, 200.0), 17.0), SkyLabelNode("b", SkyPoint(110.0, 200.0), 17.0))
        val pair = listOf(
            SkyLabelRequest("a", SkyLabelKind.PROJECT, "PAGE", listOf("a")),
            SkyLabelRequest("b", SkyLabelKind.PROJECT, "BOTTLE-FLIP", listOf("b")),
        )
        val placed = SkyModel.layoutLabels(near, pair, canvas)
        assertEquals(listOf("a", "b"), placed.map { it.id })
        assertEquals(emptyList<String>(), labelProblems(placed, near, canvas))
        assertEquals(
            listOf("b", "a"),
            SkyModel.layoutLabels(near, listOf(pair[1], SkyLabelRequest("z", SkyLabelKind.PROJECT, "NOWHERE", listOf("missing")), pair[0]), canvas).map { it.id },
        )
        assertTrue(SkyModel.layoutLabels(near, listOf(SkyLabelRequest("z", SkyLabelKind.PROJECT, "NOWHERE", listOf("missing"))), canvas).isEmpty())
        assertTrue(SkyModel.layoutLabels(near, pair, SkyRect(8.0, 8.0, 300.0, 20.0)).isEmpty())
        assertTrue(SkyModel.layoutLabels(near, pair, SkyRect(0.0, 0.0, 0.0, 100.0)).isEmpty())
        assertEquals(placed, SkyModel.layoutLabels(near, pair, canvas))
    }

    @Test fun `a name too long for a narrow canvas is shortened with dots and stays on the canvas`() {
        val near = listOf(SkyLabelNode("a", SkyPoint(100.0, 200.0), 17.0))
        val longName = SkyLabelRequest("long", SkyLabelKind.PROJECT, "A-VERY-LONG-PROJECT-NAME-THAT-GOES-ON-AND-ON-FOREVER", listOf("a"))
        val narrow = SkyRect(8.0, 8.0, 304.0, 600.0)
        val shortened = SkyModel.layoutLabels(near, listOf(longName), narrow)
        assertEquals(1, shortened.size)
        assertTrue(shortened[0].text.endsWith("…"))
        assertTrue(shortened.all { narrow.contains(it.rect) })
    }

    /** A fleet over named projects: each project gets [perProject] sessions, every third one waiting on you. */
    private fun skyFleet(projects: List<String>, perProject: Int): List<LiveSession> {
        val out = ArrayList<LiveSession>()
        for ((p, name) in projects.withIndex()) for (k in 0 until perProject) {
            val waiting = (p + k) % 3 == 0
            out.add(
                nwSession(
                    "s$p-$k", title = name, state = if (waiting) "waitingOnApproval" else "active", cwd = "~/code/$name",
                    preview = "swift test $k", interventionId = if (waiting) "i$p-$k" else null,
                    activeAt = if (waiting) null else NW_T0 - 20,
                ),
            )
        }
        return out
    }

    private val names = listOf("page", "bottle-flip", "llm-play", "sate-t", "payments", "widget", "dotfiles", "cargo", "notes")
    private val crowdedNames = listOf(
        "a-very-long-project-name-that-keeps-going-on-and-on", "llm-play", "page", "sate-t", "mac-on-claude-code",
        "ios-widget-kit-experiments", "payments-service-v2", "bottle-flip", "x", "cargo-tools", "dotfiles-and-more-config-stuff",
    )
    private val fleets = listOf(
        "nine" to skyFleet(names, 2),
        "crowded" to skyFleet(crowdedNames, 2),
        "one long" to skyFleet(listOf("a-very-long-project-name-that-keeps-going-on-and-on-and-on"), 3),
    )
    private val sizes = listOf(320.0 to 540.0, 320.0 to 568.0, 360.0 to 640.0, 393.0 to 600.0, 393.0 to 852.0, 430.0 to 740.0, 466.0 to 668.0)

    private data class Laid(val placed: List<SkyLabelPlacement>, val nodes: List<SkyLabelNode>, val canvas: SkyRect, val moon: SkyRect)

    private fun layoutAt(sessions: List<LiveSession>, width: Double, height: Double): Laid {
        val size = SkySize(width, height)
        val s = sky(sessions)
        val points = SkyModel.starPoints(s.constellations, size)
        val nodes = s.constellations.flatMap { it.stars }.map {
            SkyLabelNode(it.id, points[it.id] ?: SkyModel.starPoint(it, size), SkyModel.nodeRadius(it.state))
        }
        val bottom = minOf(SkyModel.labelTopPad + height * SkyModel.labelSkyShare + 6, height - SkyModel.labelBottomReserve)
        val canvas = SkyRect(8.0, 8.0, maxOf(0.0, width - 16), maxOf(0.0, bottom - 8))
        val moon = SkyRect(width - 134, 8.0, 140.0, 52.0)
        return Laid(SkyModel.labelLayout(s.constellations, size), nodes, canvas, moon)
    }

    private fun starOverlaps(r: Laid): List<String> {
        val out = ArrayList<String>()
        for ((i, a) in r.nodes.withIndex()) for (b in r.nodes.subList(i + 1, r.nodes.size)) {
            if (hypot(a.center.x - b.center.x, a.center.y - b.center.y) < a.radius + b.radius - 1) out.add("${a.id} overlaps ${b.id}")
        }
        return out
    }

    private fun ownershipProblems(sessions: List<LiveSession>, width: Double, height: Double): List<String> {
        val size = SkySize(width, height)
        val s = sky(sessions)
        val points = SkyModel.starPoints(s.constellations, size)
        val layout = SkyModel.labelLayout(s.constellations, size)
        fun dist(p: SkyPoint, r: SkyRect): Double = hypot(
            maxOf(r.minX - p.x, 0.0, p.x - r.maxX), maxOf(r.minY - p.y, 0.0, p.y - r.maxY),
        )
        val out = ArrayList<String>()
        for (l in layout.filter { it.kind == SkyLabelKind.PROJECT }) {
            val c = s.constellations.firstOrNull { it.key == l.id } ?: continue
            val own = c.stars.mapNotNull { points[it.id] }.minOfOrNull { dist(it, l.rect) } ?: Double.POSITIVE_INFINITY
            val other = s.constellations.filter { it.key != c.key }.flatMap { it.stars }.mapNotNull { points[it.id] }
                .minOfOrNull { dist(it, l.rect) } ?: Double.POSITIVE_INFINITY
            if (other < own - 0.5) out.add("${l.text} is nearer another project's star (${other.toInt()} < ${own.toInt()})")
            if (l.text.endsWith("…")) {
                val stem = l.text.dropLast(1)
                if (s.constellations.any { it.key != c.key && it.name.uppercase().startsWith(stem) }) out.add("${l.text} could be another project")
            }
        }
        return out
    }

    @Test fun `every sky layout keeps its labels apart, off the stars and the moon, and on the canvas`() {
        val problems = ArrayList<String>()
        for ((w, h) in sizes) for ((label, fleet) in fleets) {
            val r = layoutAt(fleet, w, h)
            val p = labelProblems(r.placed, r.nodes, r.canvas, listOf(r.moon))
            if (p.isNotEmpty()) problems.add("$label ${w.toInt()}x${h.toInt()}: ${p.take(3).joinToString("; ")}")
        }
        assertEquals("label problems: ${problems.take(3)}", emptyList<String>(), problems)
    }

    @Test fun `a project's name sits nearer one of its own stars, and stars are kept apart`() {
        val seven = skyFleet(listOf("payments-api", "payments-gateway", "payments-worker", "page", "docs-site", "docs-api", "notes"), 3)
        val owners = ArrayList<String>()
        val overlaps = ArrayList<String>()
        for ((w, h) in sizes) for ((label, fleet) in fleets + listOf("seven" to seven)) {
            val o = ownershipProblems(fleet, w, h)
            if (o.isNotEmpty()) owners.add("$label ${w.toInt()}x${h.toInt()}: ${o.take(2).joinToString("; ")}")
            val so = starOverlaps(layoutAt(fleet, w, h))
            if (so.isNotEmpty()) overlaps.add("$label ${w.toInt()}x${h.toInt()}: ${so.take(2).joinToString("; ")}")
        }
        assertEquals("ownership: ${owners.take(3)}", emptyList<String>(), owners)
        assertEquals("star overlaps: ${overlaps.take(3)}", emptyList<String>(), overlaps)
    }

    @Test fun `at 393 pt every project of nine is placed, the waiting stars get captions, and a long name fits a 320 pt screen`() {
        val nine = layoutAt(fleets[0].second, 393.0, 852.0)
        assertEquals(9, nine.placed.count { it.kind == SkyLabelKind.PROJECT })
        assertTrue(nine.placed.any { it.kind == SkyLabelKind.CAPTION })
        val longOnly = layoutAt(fleets[2].second, 320.0, 540.0)
        assertTrue(longOnly.placed.filter { it.kind == SkyLabelKind.PROJECT }.all { it.text.endsWith("…") && it.rect.width <= 320 - 16 })
    }

    // MARK: hit targets

    @Test fun `no two star tap targets overlap and each star's centre taps itself, at three phone sizes`() {
        val fleet = skyFleet(listOf("page", "riot-io-teltonika", "payments", "bottle-flip", "tokenizer-lab"), 4)
        val s = sky(fleet)
        for ((w, h) in listOf(393.0 to 852.0, 375.0 to 667.0, 430.0 to 932.0)) {
            val size = SkySize(w, h)
            val pts = SkyModel.starPoints(s.constellations, size)
            val radii = SkyModel.hitRadii(s.constellations, size)
            val ids = s.constellations.flatMap { it.stars }.map { it.id }
            var overlaps = 0
            var misses = 0
            for ((i, a) in ids.withIndex()) {
                if ((radii[a] ?: 0.0) > SkyModel.maxHitRadius) overlaps++
                if (SkyModel.hitTest(pts[a]!!, s.constellations, size) != a) misses++
                for (b in ids.subList(i + 1, ids.size)) {
                    val d = hypot(pts[a]!!.x - pts[b]!!.x, pts[a]!!.y - pts[b]!!.y)
                    if ((radii[a] ?: 0.0) + (radii[b] ?: 0.0) > d + 1e-9) overlaps++
                }
            }
            assertEquals("overlapping tap targets at ${w}x$h", 0, overlaps)
            assertEquals("centres that miss themselves at ${w}x$h", 0, misses)
            assertNull("a tap on empty sky opens nothing", SkyModel.hitTest(SkyPoint(-50.0, -50.0), s.constellations, size))
        }
        val lone = sky(listOf(nwSession("only", cwd = "~/code/only")))
        assertEquals(SkyModel.maxHitRadius, SkyModel.hitRadii(lone.constellations, SkySize(393.0, 852.0))["only"]!!, 0.0)
    }
}
