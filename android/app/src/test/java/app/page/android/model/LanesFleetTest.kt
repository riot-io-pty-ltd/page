package app.page.android.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Lanes: the fleet grouped by project, session states, the hash and hue, the activity strip, the Mac chip and the
 * Tower's power, ported from the "Night Watch (iOS): Lanes, the activity strip, Tower..." checks in
 * iOS/Tests/LogicTests.swift. (The constellation layout, label placement and hit-target tests went with the
 * constellations: Lanes is a list.)
 */
class LanesFleetTest {
    private fun near(a: Double, b: Double, eps: Double = 1e-6) = abs(a - b) < eps

    private val s1 = nwSession("s1", title = "page", state = "active", cwd = "~/projects/page", activeAt = NW_T0 - 20)
    private val s2 = nwSession("s2", title = "page-2", state = "waitingOnApproval", cwd = "~/projects/page", interventionId = "a1", activeAt = NW_T0 - 60)
    private val s3 = nwSession("s3", title = "bottle", state = "idle", cwd = "~/projects/bottle-flip")

    private fun sky(sessions: List<LiveSession>, interventions: List<Intervention> = emptyList(), paused: Boolean = false): SkyModel =
        SkyModel.build(sessions, interventions, null, emptyList(), "M", paused, nwNow)

    private fun byId(s: SkyModel): Map<String, SkyStar> = s.constellations.flatMap { it.stars }.associateBy { it.id }

    // MARK: the fleet

    @Test fun `projects are ordered by name and the headline counts sessions and projects`() {
        val s = sky(listOf(s1, s2, s3))
        assertEquals(listOf("bottle-flip", "page"), s.constellations.map { it.name })
        assertEquals("3 sessions · 2 projects", s.headline)
        assertEquals(3, s.starCount)
    }

    @Test fun `sessions in one repo share a project and a project shows its most urgent session`() {
        val s = sky(listOf(s1, s2, s3))
        val page = s.constellations.first { it.name == "page" }
        assertEquals(2, page.stars.size)
        assertEquals(StarState.NEEDS_YOU, page.urgentState)
        val stars = byId(s)
        assertEquals(StarState.NEEDS_YOU, stars["s2"]?.state)
        assertEquals(StarState.WORKING, stars["s1"]?.state)
        assertEquals(StarState.IDLE, stars["s3"]?.state)
    }

    @Test fun `equal input gives an equal fleet`() {
        assertEquals(sky(listOf(s1, s2, s3)), sky(listOf(s1, s2, s3)))
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

    @Test fun `an empty fleet says so`() {
        val empty = sky(emptyList())
        assertEquals("No live sessions", empty.headline)
        assertTrue(empty.isEmpty)
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
}
