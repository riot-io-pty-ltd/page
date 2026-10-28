package app.page.android.model

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sin

/**
 * Now in motion (board 07, "Light says what changed. Springs say it's real."): the In flight section's arcs and bars,
 * its cards and strip tiles, and the small counts and receipts around them, as plain maths of time so any frame can be
 * computed, tested and pinned by the render harness. The numbers are the Workflows lens's ([WorkflowMotion]) and the
 * pulse's ([PulseModel]) wherever the spec repeats them, so Now and the Session Room move as one system. iOS has the
 * same numbers (NowMotion.swift), and NowMotionTest's table is shared.
 *
 * Two clocks, as in the room: `t` is seconds since a thing appeared (an entrance); `now` is the clock the live loops
 * and the one-shots run on (nwClockSeconds in the app, the pinned time in the harness). Constants marked "Chosen" are
 * the ones the spec leaves open.
 */
object NowMotion {
    // MARK: - An arc or bar arriving (the first time a line is shown this process)

    /** The sweep starts this long after the line appears and takes this long, easeInOutCubic: the lens's sweep. */
    const val entranceDelay = WorkflowMotion.sweepStart
    const val entranceDuration = WorkflowMotion.sweepDuration

    /** Seconds between strip tiles' sweeps, by position, and between the workflow lines of one card. */
    const val stripStagger = 0.06
    const val cardStagger = 0.08

    /** Where a line is drawn: as the strip tile's ring, or as a bar on its card. */
    enum class Place(val stagger: Double) { STRIP(stripStagger), CARD(cardStagger) }

    /** When line [index] (a tile's position in the strip, or a line's on its card) starts to sweep, after it appears. Pure. */
    fun entranceStart(index: Int, place: Place): Double = entranceDelay + max(0, index) * place.stagger

    /** The arc or bar sweeping 0 → [fraction], [t] seconds after it appeared. Pure. */
    fun arcEntrance(t: Double, fraction: Double, staggerIndex: Int = 0, place: Place = Place.STRIP): Double =
        fraction * WorkflowMotion.easeInOutCubic((t - entranceStart(staggerIndex, place)) / entranceDuration)

    // MARK: - A fraction that moves

    /** The leading end flares as the arc springs on: its glow 1 → 1.8 × its radius as its opacity goes 0.9 → 0.4, easeOut. */
    const val flareDuration = 0.6
    const val flareGrow = 0.8
    const val flareFrom = 0.9
    const val flareTo = 0.4

    /** The head's flare [e] seconds after the fraction changed; null before and after. Pure. */
    fun flare(e: Double): WorkflowMotion.Glow? {
        if (e < 0 || e >= flareDuration) return null
        val k = MotionCurve.easeOut(e / flareDuration)
        return WorkflowMotion.Glow(1 + flareGrow * k, flareFrom + (flareTo - flareFrom) * k)
    }

    /** From [from] to [to] on the lens's arc spring (0.6 s, 0.85), exactly on [to] once settled, within 0..1. Pure. */
    fun spring(from: Double, to: Double, e: Double): Double {
        if (e >= WorkflowMotion.arcSettle) return to
        return MotionCurve.clamp01(from + (to - from) * MotionCurve.spring(max(0.0, e), WorkflowMotion.springResponse, WorkflowMotion.springDamping))
    }

    // MARK: - Live (a running line on a session that is working normally)

    /** A soft glint runs along a bar's filled part once every 2.4 s (the lens's ripple beat), easeInOut. */
    const val glintPeriod = WorkflowMotion.ripplePeriod
    /** Its length, as a share of the whole track. */
    const val glintLength = 0.28
    const val glintOpacity = 0.45

    private fun frac(x: Double): Double = x - floor(x)

    /** How far through its run the glint is, 0..1 (eased), line [index] lagging the one above by the lens's phase step (radians of the cycle, as its ripples do). Pure. */
    fun glint(now: Double, index: Int = 0): Double =
        WorkflowMotion.easeInOutCubic(frac(now / glintPeriod - index * WorkflowMotion.phaseStep / (2 * PI)))

    /** The glint's middle along the track (0: its start, 1: its whole length) with [filled] of it filled: it comes in from before the start and leaves past the filled end. Pure. */
    fun glintCentre(now: Double, index: Int, filled: Double): Double = -glintLength / 2 + glint(now, index) * (max(0.0, filled) + glintLength)

    /** How bright the glint is: 0 at either end of its run, 0.45 half way (a sine), as on iOS. Pure. */
    fun glintAlpha(now: Double, index: Int = 0): Double =
        glintOpacity * sin(PI * frac(now / glintPeriod - index * WorkflowMotion.phaseStep / (2 * PI)))

    /** A working session's star glyph breathes with the pulse (4 s): 1 → 1.04, its glow 0.3 → 0.55. */
    const val starPeriod = PulseModel.baseBreath
    const val starScale = 0.04
    const val starGlowFrom = 0.3
    const val starGlowTo = 0.55

    /** 0 (rest) up to 1 and back over 4 s, the pulse's waveform; strip tile [index] lags by the lens's phase step. Pure. */
    fun starBreath(now: Double, index: Int = 0): Double = 0.5 - 0.5 * cos(2 * PI * now / starPeriod - index * WorkflowMotion.phaseStep)

    /** The health dot: green breathes on the pulse's 4 s, sky (long-running) slower; amber sends a slow ripple, as a waiting item does. */
    const val healthyBreath = PulseModel.baseBreath
    /** Chosen: "slower". */
    const val longBreath = 6.0
    const val stuckRipple = PulseModel.slowestRipple

    fun dotBreath(now: Double, period: Double): Double = 0.5 - 0.5 * cos(2 * PI * now / period)

    /** The ring opens from the dot's edge (3.5 dp) to 12 dp on easeOut, at 0.7 × the pulse's ring opacity: iOS's numbers, a quiet signal. */
    const val rippleFrom = 3.5
    const val rippleTo = 12.0
    const val rippleOpacity = 0.7

    /** A stuck dot's ring: how far through its 3 s it is (0..1), its radius in dp and its opacity. */
    data class HealthRing(val progress: Double, val radius: Double, val opacity: Double)

    /** One amber ring off a stuck session's dot, every 3 s. Pure. */
    fun healthRipple(now: Double): HealthRing {
        val p = frac(now / stuckRipple)
        return HealthRing(p, rippleFrom + (rippleTo - rippleFrom) * MotionCurve.easeOut(p), rippleOpacity * PulseModel.ringOpacity(p))
    }

    /** A session's health tint turning (amber as it gets stuck, back as it recovers): a cross-fade over 0.5 s, easeOut. */
    const val healthFade = 0.5

    /** How amber a row is drawn, [e] seconds after its health turned from [from] to [to] (the target when nothing turned). Reduce Motion: a 0.2 s fade. Pure. */
    fun amber(from: FlightHealth?, to: FlightHealth, e: Double, reduce: Boolean = false): Double {
        val target = if (to.needsAttention) 1.0 else 0.0
        if (from == null) return target
        val start = if (from.needsAttention) 1.0 else 0.0
        return start + (target - start) * MotionCurve.easeOut(e / if (reduce) WorkflowMotion.reducedFade else healthFade)
    }

    // MARK: - The NOW step changing

    /** The old step slides up 6 dp and fades over 0.25 s; the new one rises in on a 0.35 s spring. */
    const val stepOut = 0.25
    const val stepIn = 0.35
    const val stepRise = 6.0
    /** The stream's spring (the cards below an arrival make room on it): the earlier steps shift down on it. */
    const val streamResponse = 0.5
    const val streamDamping = 0.8
    /** A step change is drawn settled, exactly at rest, after this (the arc's settle, as on iOS). */
    const val stepSettle = WorkflowMotion.arcSettle

    /** An offset in dp (negative is up) and an opacity. */
    data class Slide(val offset: Double, val opacity: Double)

    /** The step that was current, [e] seconds after the change. Reduce Motion: a 0.2 s fade, in place. Pure. */
    fun stepOld(e: Double, reduce: Boolean = false): Slide {
        if (reduce) return Slide(0.0, 1 - MotionCurve.easeOut(e / WorkflowMotion.reducedFade))
        val k = MotionCurve.easeOut(e / stepOut)
        return Slide(-stepRise * k, 1 - k)
    }

    /** The new current step rising in. Pure. */
    fun stepNew(e: Double, reduce: Boolean = false): Slide {
        if (reduce) return Slide(0.0, MotionCurve.easeOut(e / WorkflowMotion.reducedFade))
        if (e >= stepSettle) return Slide(0.0, 1.0)
        val s = MotionCurve.spring(max(0.0, e), stepIn, WorkflowMotion.springDamping)
        return Slide(stepRise * (1 - s), MotionCurve.easeOut(e / stepIn))
    }

    /** How far the earlier steps have shifted down to their new places, 0 → 1 on the stream's spring (1 at once under Reduce Motion). Pure. */
    fun stepShift(e: Double, reduce: Boolean = false): Double =
        if (reduce || e >= stepSettle) 1.0 else MotionCurve.spring(max(0.0, e), streamResponse, streamDamping)

    // MARK: - Cards and strip tiles arriving and leaving

    /** A card or tile rises 12 dp as it fades in, on a spring (0.5 s, 0.85); the first look staggers them 0.05 s apart. */
    const val riseBy = 12.0
    const val riseResponse = 0.5
    const val riseDamping = 0.85
    const val riseStagger = 0.05
    /** Chosen: the fade's length (easeOut), and when the rise is drawn settled. */
    const val riseFade = 0.3
    const val riseSettle = 1.0
    /** A card or tile leaving: it fades as it folds away. */
    const val leaveDuration = 0.3

    /** A card or tile rising in, [e] seconds after its start (negative: still to come). Reduce Motion: a 0.2 s fade. Pure. */
    fun rise(e: Double, reduce: Boolean = false): Slide {
        if (reduce) return Slide(0.0, MotionCurve.easeOut(e / WorkflowMotion.reducedFade))
        if (e >= riseSettle) return Slide(0.0, 1.0)
        val s = MotionCurve.spring(max(0.0, e), riseResponse, riseDamping)
        return Slide(riseBy * (1 - s), MotionCurve.easeOut(e / riseFade))
    }

    /** How far a leaving card or tile has gone, 0 → 1 (smoothstep over 0.3 s; a 0.2 s fade under Reduce Motion). Pure. */
    fun leave(e: Double, reduce: Boolean = false): Double =
        if (reduce) MotionCurve.easeOut(e / WorkflowMotion.reducedFade) else MotionCurve.smooth(e / leaveDuration)

    fun leaveLasts(reduce: Boolean): Double = if (reduce) WorkflowMotion.reducedFade else leaveDuration

    // MARK: - A line that ends

    /** A done line closes (the arc's spring), its glow grows and fades (the lens's pulse, 0.5 s after), then it folds away. */
    const val ghostCollapseAt = WorkflowMotion.pulseDelay + WorkflowMotion.pulseDuration
    const val ghostCollapse = WorkflowMotion.crossFade
    const val ghostDuration = ghostCollapseAt + ghostCollapse

    /**
     * How long the card keeps a line after the phone saw it end ("≈2 s"), carrying how it ended, so the card can tell
     * a finish from a line that merely vanished. The card keeps its own ghost for as long as it plays.
     */
    const val endedGrace = 2.0

    /** How long a ghost is drawn: the whole close, pulse and fold; under Reduce Motion only the 0.2 s fade. */
    fun ghostLasts(reduce: Boolean): Double = if (reduce) WorkflowMotion.reducedFade else ghostDuration

    data class Ghost(
        /** The fraction as drawn: springing to 1 for a finish, held for a failure or a stop. */
        val value: Double,
        /** The one soft pulse a finish sends (ring radius or bar glow × 1 → 1.35, opacity 0.55 → 0), while it is out. */
        val pulse: WorkflowMotion.Glow?,
        /** How far a failure or a stop has turned amber, 0..1. */
        val amber: Double,
        val opacity: Double,
        /** The line's height as it folds away, 1 → 0. */
        val height: Double,
    )

    /**
     * A line [e] seconds after the phone saw it end with [status], from [from]. Reduce Motion skips the ghost: the line
     * fades out over 0.2 s where it is. Pure.
     */
    fun ghost(e: Double, status: FlightLineStatus, from: Double, reduce: Boolean = false): Ghost {
        val x = max(0.0, e)
        if (reduce) return Ghost(from, null, 0.0, 1 - MotionCurve.easeOut(x / WorkflowMotion.reducedFade), 1.0)
        val done = status == FlightLineStatus.DONE
        val fold = MotionCurve.easeOut((x - ghostCollapseAt) / ghostCollapse)
        return Ghost(
            value = if (done) spring(from, 1.0, x) else from,
            pulse = if (done) WorkflowMotion.pulse(x - WorkflowMotion.pulseDelay) else null,
            amber = if (done) 0.0 else MotionCurve.easeOut(x / WorkflowMotion.crossFade),
            opacity = 1 - fold, height = 1 - fold,
        )
    }

    /** What an ended line says in place of its progress: "✓ done", "failed", "stopped". */
    fun endedWord(status: FlightLineStatus): String? = when (status) {
        FlightLineStatus.RUNNING -> null
        FlightLineStatus.DONE -> "✓ done"
        FlightLineStatus.FAILED -> "failed"
        FlightLineStatus.STOPPED -> "stopped"
    }

    /** The one polite announcement an ending earns: "page: Docs sweep finished", "Docs sweep failed", "Docs sweep stopped". */
    fun announcement(project: String, workflow: String, status: FlightLineStatus): String? = when (status) {
        FlightLineStatus.RUNNING -> null
        FlightLineStatus.DONE -> "$project: $workflow finished"
        FlightLineStatus.FAILED -> "$workflow failed"
        FlightLineStatus.STOPPED -> "$workflow stopped"
    }

    // MARK: - What ended

    data class FlightEvents(val finished: List<FlightWorkflowLine>, val failed: List<FlightWorkflowLine>, val stopped: List<FlightWorkflowLine>) {
        val all: List<FlightWorkflowLine> get() = finished + failed + stopped
        val isEmpty: Boolean get() = finished.isEmpty() && failed.isEmpty() && stopped.isEmpty()

        companion object {
            val none = FlightEvents(emptyList(), emptyList(), emptyList())
        }
    }

    /**
     * One card's lines that have just ended: running in [old] and done, failed or stopped in [new], by key. Never
     * inferred from a line disappearing (a workflow that failed or stopped, a collapsed card, a capped row and a
     * reconnect's partial snapshot all make a line vanish), and nothing for the first snapshot ([old] null or empty). Pure.
     */
    fun flightEvents(old: List<FlightWorkflowLine>?, new: List<FlightWorkflowLine>): FlightEvents {
        if (old.isNullOrEmpty()) return FlightEvents.none
        val running = old.filter { it.status == FlightLineStatus.RUNNING }.map { it.key }.toSet()
        fun turned(to: FlightLineStatus) = new.filter { it.status == to && it.key in running }
        return FlightEvents(turned(FlightLineStatus.DONE), turned(FlightLineStatus.FAILED), turned(FlightLineStatus.STOPPED))
    }

    // MARK: - The track: what the In flight section has seen since it appeared

    /** A line that has just ended, drawn as its ghost while it plays. */
    data class End(val rowId: String, val project: String, val line: FlightWorkflowLine, val from: Double, val at: Double)

    /** A line's fraction changed at [at]: it springs on from [from]. */
    data class Move(val from: Double, val at: Double)

    /** A card's NOW step changed at [at], from [now] (with [previous] under it). */
    data class Step(val now: String, val previous: List<String>, val at: Double)

    /** A card's health turned at [at], from [from]. */
    data class Turn(val from: FlightHealth, val at: Double)

    /** A card or tile leaving: the row as it was drawn, where, and since when. */
    data class Leave(val row: InFlightRow, val index: Int, val at: Double)

    /**
     * What the section has seen since it appeared. Line slots are fixed while it shows (the first look's order,
     * newcomers after), so a line never swaps places under a finger and a ghost keeps its place while it plays.
     */
    data class Track(
        val openedAt: Double,
        val section: InFlightSection,
        /** Each working session's lines as last seen, by row id (every one, not only the cards drawn). */
        val lines: Map<String, List<FlightWorkflowLine>>,
        /** Each row's line keys in drawing order. */
        val slots: Map<String, List<String>>,
        /** When each line was first shown this process, by "row|name" (the card's bar and the strip's ring share it). */
        val shown: Map<String, Double> = emptyMap(),
        /** By "row|key". */
        val moves: Map<String, Move> = emptyMap(),
        val ends: Map<String, End> = emptyMap(),
        /** By row id. */
        val steps: Map<String, Step> = emptyMap(),
        val turns: Map<String, Turn> = emptyMap(),
        val cardsIn: Map<String, Double> = emptyMap(),
        val tilesIn: Map<String, Double> = emptyMap(),
        val cardsOut: Map<String, Leave> = emptyMap(),
        val tilesOut: Map<String, Leave> = emptyMap(),
        /** Endings are ignored until this (a fresh start's first snapshots are never news). */
        val quietUntil: Double = openedAt,
        /** The last announcement and when it was made; kept a moment so it is read whole, then cleared. */
        val said: String? = null,
        val saidAt: Double? = null,
    )

    /** The once-per-process memory behind the entrances and the endings; a fresh set for every pinned harness frame. */
    class Books {
        val cards = OneShotBook()
        val tiles = OneShotBook()
        val lines = OneShotBook()
        val ends = OneShotBook()
    }

    /** The strip's rows when it is drawn (two or more working sessions); none otherwise. */
    private fun tiles(s: InFlightSection): List<InFlightRow> = if (s.showsStrip) s.strip else emptyList()

    /** Every working session's row ([InFlightSection.strip] holds all of them even when the strip is not drawn). */
    private fun everyRow(s: InFlightSection): List<InFlightRow> = s.strip.ifEmpty { s.rows }

    /**
     * The first snapshot, as the section appears at [now]: nothing ends and nothing moves; a card or tile seen for the
     * first time this process rises in (staggered), and every line seen for the first time sweeps in. [quiet]: seconds
     * from now during which endings are not news (a resume or a reconnect, whose first snapshots carry old changes).
     * Reduce Motion: no stagger.
     */
    fun start(section: InFlightSection, now: Double, books: Books, quiet: Double = 0.0, reduce: Boolean = false): Track {
        val rows = everyRow(section)
        val lines = rows.associate { it.id to it.card.workflows }
        val slots = lines.mapValues { (_, ls) -> ls.filter { it.status == FlightLineStatus.RUNNING }.map { it.key } }
        val stagger = if (reduce) 0.0 else riseStagger
        val track = Track(
            now, section, lines, slots,
            cardsIn = section.rows.withIndex().associate { (i, r) -> r.id to books.cards.start(r.id, now + i * stagger) },
            tilesIn = tiles(section).withIndex().associate { (i, r) -> r.id to books.tiles.start(r.id, now + i * stagger) },
            quietUntil = now + quiet,
        )
        return track.copy(shown = book(track, now, books, emptyMap()))
    }

    /** When each drawn line is first shown (a card's bar and its strip tile's ring alike): what [prior] knew, and the process's books for the rest. */
    private fun book(track: Track, now: Double, books: Books, prior: Map<String, Double>): Map<String, Double> {
        val m = HashMap(prior)
        fun note(key: String, at: Double) { if (key !in m) m[key] = books.lines.start(key, at) }
        for (row in track.section.rows) for (line in drawn(track, row.id, now, false)) {
            if (line.status == FlightLineStatus.RUNNING) note("${row.id}|${line.name}", now)
        }
        for (row in tiles(track.section)) {
            // The tile shows one line: the first running one, once any ghost ahead of it has played.
            var after = now
            for (key in track.slots[row.id] ?: emptyList()) {
                val end = track.ends["${row.id}|$key"]
                if (end != null) { after = max(after, end.at + ghostDuration); continue }
                val line = track.lines[row.id]?.firstOrNull { it.key == key && it.status == FlightLineStatus.RUNNING } ?: continue
                note("${row.id}|${line.name}", after)
                break
            }
        }
        return m
    }

    /**
     * The section as it is at [now]. Lines that ended (running before, done, failed or stopped now) start their ghosts,
     * once per run; fractions that changed spring; a changed NOW step or health turns; cards and tiles that arrive
     * rise and those that leave fold away. Pure but for [books].
     */
    fun observe(track: Track, section: InFlightSection, now: Double, books: Books, reduce: Boolean = false): Track {
        if (section == track.section) return track
        val old = track.section
        val oldRows = everyRow(old).associateBy { it.id }
        val rows = everyRow(section)
        val lines = rows.associate { it.id to it.card.workflows }
        val moves = track.moves.filterValues { now - it.at < WorkflowMotion.arcSettle }.toMutableMap()
        val ends = track.ends.filterValues { now - it.at < ghostDuration }.toMutableMap()
        val steps = track.steps.filterValues { now - it.at < stepSettle }.toMutableMap()
        val turns = track.turns.filterValues { now - it.at < healthFade }.toMutableMap()
        val slots = HashMap<String, List<String>>()
        val said = ArrayList<String>()
        for (row in rows) {
            val before = track.lines[row.id]
            val new = row.card.workflows
            val events = flightEvents(before, new)
            if (now >= track.quietUntil) for (line in events.all) {
                val k = "${row.id}|${line.key}"
                // Once per run, however often the section is rebuilt.
                if (books.ends.start(k, now) != now) continue
                val from = before?.firstOrNull { it.key == line.key }?.fraction ?: 0.0
                ends[k] = End(row.id, row.project, line, from, now)
                announcement(row.project, line.name, line.status)?.let(said::add)
            }
            if (before != null) {
                val was = before.associateBy { it.key }
                for (l in new) {
                    val w = was[l.key] ?: continue
                    if (w.status == FlightLineStatus.RUNNING && l.status == FlightLineStatus.RUNNING && l.fraction != w.fraction) {
                        moves["${row.id}|${l.key}"] = Move(w.fraction ?: 0.0, now)
                    }
                }
            }
            oldRows[row.id]?.let { o ->
                if (o.card.now != row.card.now) steps[row.id] = Step(o.card.now, o.card.previous, now)
                if (o.card.health != row.card.health) turns[row.id] = Turn(o.card.health, now)
            }
            val running = new.filter { it.status == FlightLineStatus.RUNNING }.map { it.key }
            val kept = (track.slots[row.id] ?: emptyList()).filter { it in running || "${row.id}|$it" in ends }
            slots[row.id] = kept + running.filter { it !in kept }
        }

        fun arrivals(was: List<InFlightRow>, next: List<InFlightRow>, starts: Map<String, Double>, book: OneShotBook): Map<String, Double> {
            val before = was.map { it.id }.toSet()
            val m = starts.filterKeys { id -> next.any { it.id == id } }.toMutableMap()
            var k = 0
            for (r in next) if (r.id !in before) {
                // Anything that comes into the set while it shows rises (a new session, Show all), the first look's
                // stagger only for several at once.
                m[r.id] = now + k++ * (if (reduce) 0.0 else riseStagger)
                book.start(r.id, now)
            }
            return m
        }

        fun departures(was: List<InFlightRow>, next: List<InFlightRow>, out: Map<String, Leave>): Map<String, Leave> {
            val ids = next.map { it.id }.toSet()
            val m = out.filterValues { now - it.at < leaveDuration && it.row.id !in ids }.toMutableMap()
            was.forEachIndexed { i, r -> if (r.id !in ids) m[r.id] = Leave(r, i, now) }
            return m
        }

        // The strip's tiles come and go only while it stays; it appears and goes whole with its second session.
        val keepTiles = old.showsStrip && section.showsStrip
        val next = Track(
            openedAt = track.openedAt, section = section, lines = lines, slots = slots, shown = track.shown,
            moves = moves, ends = ends, steps = steps, turns = turns,
            cardsIn = arrivals(old.rows, section.rows, track.cardsIn, books.cards),
            tilesIn = arrivals(tiles(old), tiles(section), track.tilesIn, books.tiles),
            cardsOut = departures(old.rows, section.rows, track.cardsOut),
            tilesOut = if (keepTiles) departures(tiles(old), tiles(section), track.tilesOut) else emptyMap(),
            quietUntil = track.quietUntil,
            said = if (said.isNotEmpty()) said.joinToString(". ") else track.said.takeIf { track.saidAt != null && now - track.saidAt < ghostDuration },
            saidAt = if (said.isNotEmpty()) now else track.saidAt.takeIf { track.said != null && it != null && now - it < ghostDuration },
        )
        return next.copy(shown = book(next, now, books, track.shown))
    }

    // MARK: - A frame of the track at [now]

    /** The lines a card or tile draws at [now], in slot order: what is running, and each ghost while it plays. Pure. */
    fun drawn(track: Track, rowId: String, now: Double, reduce: Boolean): List<FlightWorkflowLine> {
        val current = track.lines[rowId] ?: return emptyList()
        return (track.slots[rowId] ?: emptyList()).mapNotNull { key ->
            val end = track.ends["$rowId|$key"]
            if (end != null) end.line.takeIf { now - end.at < ghostLasts(reduce) }
            else current.firstOrNull { it.key == key && it.status == FlightLineStatus.RUNNING }
        }
    }

    /** The one line a strip tile shows at [now]: the first drawn. */
    fun tileLine(track: Track, rowId: String, now: Double, reduce: Boolean): FlightWorkflowLine? = drawn(track, rowId, now, reduce).firstOrNull()

    /** How amber row [row]'s tint and lines are drawn at [now]. Pure. */
    fun rowAmber(track: Track, row: InFlightRow, now: Double, reduce: Boolean): Double {
        val turn = track.turns[row.id]
        return amber(turn?.from, row.card.health, turn?.let { now - it.at } ?: 1e9, reduce)
    }

    /** True while row [row]'s lines, star and dot keep their live loops: running normally (or long-running), and never under Reduce Motion. */
    fun live(row: InFlightRow, reduce: Boolean): Boolean = !reduce && !row.card.health.needsAttention

    /** One line as drawn at [now]. */
    data class LineFrame(
        val value: Double,
        val amber: Double,
        val flare: WorkflowMotion.Glow?,
        val pulse: WorkflowMotion.Glow?,
        val opacity: Double,
        val height: Double,
        /** The head breathes and the glint and comet run. */
        val live: Boolean,
    )

    /**
     * [line] (drawn [index]-th: a tile's place in the strip, or a line's on its card) of [row] at [now]: the entrance
     * sweep, then a spring to each new fraction with its flare; a ghost once it has ended. Reduce Motion: the fraction
     * at once, no loops. Pure.
     */
    fun line(track: Track, row: InFlightRow, line: FlightWorkflowLine, index: Int, place: Place, now: Double, reduce: Boolean): LineFrame {
        val tint = rowAmber(track, row, now, reduce)
        val end = track.ends["${row.id}|${line.key}"]
        if (end != null) {
            val g = ghost(now - end.at, end.line.status, end.from, reduce)
            return LineFrame(g.value, max(tint, g.amber), null, g.pulse, g.opacity, g.height, false)
        }
        val target = line.fraction ?: 0.0
        if (reduce) return LineFrame(target, tint, null, null, 1.0, 1.0, false)
        val move = track.moves["${row.id}|${line.key}"]
        val value = if (move != null && now >= move.at) {
            spring(move.from, target, now - move.at)
        } else {
            val appeared = track.shown["${row.id}|${line.name}"] ?: (track.openedAt - 100)
            arcEntrance(now - appeared, target, index, place)
        }
        return LineFrame(value, tint, move?.let { flare(now - it.at) }, null, 1.0, 1.0, live(row, false))
    }

    /** A card's NOW step change and how long ago it was, while it is still moving. Pure. */
    fun step(track: Track, rowId: String, now: Double, reduce: Boolean): Pair<Step, Double>? {
        val s = track.steps[rowId] ?: return null
        val e = now - s.at
        return if (e < 0 || e >= (if (reduce) WorkflowMotion.reducedFade else stepSettle)) null else s to e
    }

    /** The cards drawn at [now], in order, each with the time its exit began (null for a card that stays). Pure. */
    fun cards(track: Track, now: Double, reduce: Boolean): List<Pair<InFlightRow, Double?>> = withLeaving(track.section.rows, track.cardsOut, now, reduce)

    /** The strip tiles drawn at [now], likewise. Pure. */
    fun stripTiles(track: Track, now: Double, reduce: Boolean): List<Pair<InFlightRow, Double?>> = withLeaving(tiles(track.section), track.tilesOut, now, reduce)

    private fun withLeaving(rows: List<InFlightRow>, out: Map<String, Leave>, now: Double, reduce: Boolean): List<Pair<InFlightRow, Double?>> {
        val list: MutableList<Pair<InFlightRow, Double?>> = rows.map { it to null }.toMutableList()
        for (l in out.values.sortedBy { it.index }) {
            if (now - l.at >= leaveLasts(reduce) || rows.any { it.id == l.row.id }) continue
            list.add(minOf(l.index, list.size), l.row to l.at)
        }
        return list
    }

    /** When the last one-shot on the track lands. Pure. */
    fun settlesAt(track: Track, reduce: Boolean): Double {
        var end = track.openedAt
        fun until(at: Double?, d: Double) { if (at != null) end = max(end, at + d) }
        val sweep = if (reduce) 0.0 else entranceStart(8, Place.CARD) + entranceDuration
        for (s in track.shown.values) until(s, sweep)
        for (m in track.moves.values) until(m.at, if (reduce) 0.0 else max(WorkflowMotion.arcSettle, flareDuration))
        for (e in track.ends.values) until(e.at, ghostLasts(reduce))
        for (s in track.steps.values) until(s.at, if (reduce) WorkflowMotion.reducedFade else stepSettle)
        for (t in track.turns.values) until(t.at, if (reduce) WorkflowMotion.reducedFade else healthFade)
        for (c in track.cardsIn.values + track.tilesIn.values) until(c, if (reduce) WorkflowMotion.reducedFade else riseSettle)
        for (l in track.cardsOut.values + track.tilesOut.values) until(l.at, leaveLasts(reduce))
        return end
    }

    /** The announcement to read now, if any. */
    fun said(track: Track, now: Double): String? = track.said?.takeIf { track.saidAt != null && now - track.saidAt < ghostDuration }

    // MARK: - Counts, receipts and badges

    /** The brief's numbers count up in under 400 ms: easeOutCubic over 0.38 s, rounded half up (as Swift's rounded()). */
    const val countDuration = 0.38

    /** A count climbing to [total], [t] seconds in. Pure. */
    fun chipCount(t: Double, total: Int): Int = floor(total * MotionCurve.easeOut(t / countDuration) + 0.5).toInt()

    /** Settled's hairline receipts fade with age: full for 5 minutes, then linearly to 0.55 at two hours, and no further. */
    const val settledFresh = 5.0
    const val settledOld = 120.0
    const val settledFloor = 0.55

    /** A receipt's opacity at [ageMinutes]. Pure. */
    fun settledOpacity(ageMinutes: Double): Double = 1 - (1 - settledFloor) * MotionCurve.progress(ageMinutes, settledFresh, settledOld)

    /** A tab badge's count changing: one swell to 1.22 and back. Chosen shape: 1 + 0.22·sin(π·t/0.5), the lens's text bump. */
    const val badgePeak = 1.22
    const val badgeDuration = 0.5

    /** The badge's scale [t] seconds after its count changed. Pure. */
    fun badgeBump(t: Double): Double = if (t > 0 && t < badgeDuration) 1 + (badgePeak - 1) * sin(PI * t / badgeDuration) else 1.0

    // MARK: - The rest of Now: the Runway, the Horizon's words, the tab badges, Review chips, Settled, the queued receipt

    // MARK: A change, and a script of them

    /** A value and the one change it plays: what it was before and when it changed (both null: nothing to play). */
    data class Change<T>(val value: T, val from: T? = null, val at: Double? = null) {
        /** [next] seen at [now]: a new change when it differs, else this one. Pure. */
        fun observe(next: T, now: Double): Change<T> = if (next == value) this else Change(next, value, now)
    }

    /** A script's values (the first at its own time, as the first look: never a change) folded up to [time]. Pure. */
    fun <T> replay(script: List<Pair<Double, T>>, time: Double): Change<T>? {
        if (script.isEmpty()) return null
        return script.drop(1).filter { it.first <= time }.fold(Change(script[0].second)) { c, (at, v) -> c.observe(v, at) }
    }

    /**
     * What the rest of Now's motion follows, as one value: the Horizon's headline, the two tab badges' counts, today's
     * Settled receipts and the Runway. The render harness scripts Now as a list of these ([app.page.android.ui.nw.theme.LocalNowScript]).
     */
    data class Look(val headline: String, val decide: Int, val working: Int, val settled: List<SettledLine>, val runway: RunwayModel) {
        companion object {
            fun of(model: NowModel, settled: SettledLog): Look = Look(model.headline, model.needYouCount, model.workingCount, settled.today, model.runway)
        }
    }

    // MARK: The Runway

    /** On its first appearance in a process the line draws left to right over 0.6 s, easeOut. */
    const val runwayDraw = 0.6
    /** Each marker pops in as the line reaches it, at least 0.07 s after the one to its left: scale 0.6 → 1 on easeOutBack (1.2), the lens's pop. */
    const val markerStagger = 0.07
    const val markerFrom = 0.6
    /** Chosen: a pop's length, and its fade (easeOut) over the first part of it. */
    const val markerPop = 0.35
    const val markerFade = 0.12
    /** A marker whose place changes glides there over 0.8 s, easeInOut. */
    const val markerSlide = 0.8
    /**
     * Chosen: a move smaller than this share of the line (about 1 dp) is the clock's own drift and is drawn at once, with
     * no clock: the whole line is six hours, so ten seconds moves a marker 0.05 % of the way.
     */
    const val markerSlideMin = 0.003
    /** A marker that reaches now flashes once (a glow up and down over 0.6 s, as big and bright as a line's flare) as it fades out. */
    const val markerFlash = flareDuration
    /** Chosen: within this share of the line (about 4 minutes) a marker that goes is one that reached now; further out it only fades. */
    const val markerNear = 0.012
    /** Chosen: a marker that goes for any other reason (the Mac on power, a forecast withdrawn) fades over 0.3 s. */
    const val markerGone = 0.3
    /**
     * The NOW dot breathes with the pulse while agents work (its period, 4 s for one session): its halo grows by the
     * room's 0.12 as its opacity goes 0.25 → 0.5.
     */
    const val nowDotPeriod = PulseModel.baseBreath

    /** How much of the line is drawn, [t] seconds after it began. Pure. */
    fun runwayLine(t: Double, reduce: Boolean = false): Double = if (reduce) 1.0 else MotionCurve.easeOut(t / runwayDraw)

    /** When the drawing line reaches [fraction] (0: the NOW dot, 1: its end): its easeOut, inverted. Pure. */
    fun runwayReach(fraction: Double): Double = runwayDraw * (1 - Math.cbrt(1 - MotionCurve.clamp01(fraction)))

    /** When each marker pops in, by [fractions] in their own order: as the line reaches it, and at least 0.07 s after the one to its left. Pure. */
    fun markerStarts(fractions: List<Double>): List<Double> {
        val out = DoubleArray(fractions.size)
        var last = Double.NEGATIVE_INFINITY
        for (i in fractions.indices.sortedBy { fractions[it] }) {
            out[i] = max(runwayReach(fractions[i]), last + markerStagger)
            last = out[i]
        }
        return out.toList()
    }

    /** A marker popping in, [e] seconds after its start (negative: still to come). Pure. */
    fun markerPop(e: Double): WorkflowMotion.Pop =
        WorkflowMotion.Pop(markerFrom + (1 - markerFrom) * WorkflowMotion.easeOutBack(e / markerPop), MotionCurve.easeOut(e / markerFade))

    /** A marker gliding from [from] to [to], [e] seconds after its place changed. Pure. */
    fun markerGlide(from: Double, to: Double, e: Double): Double = from + (to - from) * WorkflowMotion.easeInOutCubic(e / markerSlide)

    /** A marker leaving: how much of it is left, and the one flash of a marker that reached now (0 → 1 → 0). */
    data class MarkerLeave(val opacity: Double, val flash: Double)

    /** A marker [e] seconds after it went; [reached]: it went because its time came. Reduce Motion: a 0.2 s fade, no flash. Pure. */
    fun markerLeave(e: Double, reached: Boolean, reduce: Boolean = false): MarkerLeave {
        if (reduce) return MarkerLeave(1 - MotionCurve.easeOut(e / WorkflowMotion.reducedFade), 0.0)
        if (!reached) return MarkerLeave(1 - MotionCurve.easeOut(e / markerGone), 0.0)
        return markerPassing(e) ?: MarkerLeave(if (e < 0) 1.0 else 0.0, 0.0)
    }

    /** A marker that reached now, [e] seconds on: its one flash (0 → 1 → 0, a sine) and what is left of its tick (1 → 0, smoothly); null outside it. Pure. */
    fun markerPassing(e: Double): MarkerLeave? {
        if (e < 0 || e >= markerFlash) return null
        val p = e / markerFlash
        return MarkerLeave(1 - MotionCurve.smooth(p), sin(PI * p))
    }

    /** The glow a flash of [k] (0..1) draws round its tick: at its height as big and bright as a line's flare (1.8 × its radius, 0.9). Pure. */
    fun flashGlow(k: Double): WorkflowMotion.Glow = WorkflowMotion.Glow(1 + flareGrow * k, flareFrom * k)

    fun markerLeaves(reached: Boolean, reduce: Boolean): Double = if (reduce) WorkflowMotion.reducedFade else if (reached) markerFlash else markerGone

    /** The NOW dot's breath at [now], 0 (rest) up to 1 and back over the pulse's [period]: the pulse's own waveform. Pure. */
    fun nowDot(now: Double, period: Double = nowDotPeriod): Double = 0.5 - 0.5 * cos(2 * PI * now / max(0.1, period))

    /** [model]'s markers placed at [now] (the live clock), dropping any whose time has come: the line's own drift. Pure. */
    fun runwayAt(model: RunwayModel, now: java.time.Instant): List<RunwayMarker> =
        model.markers.mapNotNull { m -> RunwayModel.fraction(m.at, now)?.let { m.copy(fraction = it) } }

    /** A marker's place changing: from where it was drawn, since when. */
    data class Glide(val from: Double, val at: Double)

    /** A marker that went: as it was, where it was drawn, since when, and whether its time came. */
    data class Gone(val marker: RunwayMarker, val fraction: Double, val at: Double, val reached: Boolean)

    /** What the Runway has seen since it appeared. */
    data class RunwayTrack(
        /** When the line began to draw: its first appearance this process. */
        val drawnAt: Double,
        val markers: List<RunwayMarker>,
        /** When each marker pops in, by id. */
        val pops: Map<String, Double>,
        val glides: Map<String, Glide> = emptyMap(),
        val gone: Map<String, Gone> = emptyMap(),
        /** The markers that came after the first look (under Reduce Motion they fade in; the first look's are simply there). */
        val later: Set<String> = emptySet(),
    )

    /** The Runway's first look at [drawnAt]: the line draws and its markers pop in as it reaches them. Pure. */
    fun runwayStart(markers: List<RunwayMarker>, drawnAt: Double): RunwayTrack =
        RunwayTrack(drawnAt, markers, markers.zip(markerStarts(markers.map { it.fraction })).associate { (m, s) -> m.id to drawnAt + s })

    /** Where marker [id] is drawn at [now]: gliding to its place, or there. Pure. */
    fun markerPlace(track: RunwayTrack, id: String, now: Double): Double? {
        val to = track.markers.firstOrNull { it.id == id }?.fraction ?: return null
        val g = track.glides[id] ?: return to
        val e = now - g.at
        return if (e >= markerSlide) to else markerGlide(g.from, to, e)
    }

    /**
     * The markers as at [now]: one whose place jumps glides there from where it is drawn (the clock's drift is drawn at
     * once); a new one pops in; one that goes flashes if its time came and otherwise fades. Reduce Motion: no glide. Pure.
     */
    fun runwayObserve(track: RunwayTrack, markers: List<RunwayMarker>, now: Double, reduce: Boolean = false): RunwayTrack {
        if (markers == track.markers) return track
        val glides = track.glides.filterValues { now - it.at < markerSlide }.toMutableMap()
        val gone = track.gone.filterValues { now - it.at < markerLeaves(it.reached, reduce) }.toMutableMap()
        val pops = HashMap<String, Double>()
        val later = HashSet<String>()
        for (m in markers) {
            val was = track.markers.firstOrNull { it.id == m.id }
            val place = was?.let { markerPlace(track, m.id, now) ?: it.fraction }
            if (was != null && place != null && m.at > was.at && place <= markerNear) {
                // A marker is one per kind: the one at the NOW dot reached now (it flashes), and the next of its kind is new.
                glides.remove(m.id)
                gone[m.id] = Gone(was, place, now, true)
                pops[m.id] = now
                later.add(m.id)
                continue
            }
            if (was == null) {
                // Back after it went: it pops in, and a flash still playing plays on.
                if (gone[m.id]?.reached != true) gone.remove(m.id)
                pops[m.id] = now
                later.add(m.id)
                continue
            }
            if (m.id in track.later) later.add(m.id)
            pops[m.id] = track.pops[m.id] ?: now
            if (!reduce && abs(m.fraction - was.fraction) >= markerSlideMin) glides[m.id] = Glide(markerPlace(track, m.id, now) ?: was.fraction, now)
        }
        for (m in track.markers) if (markers.none { it.id == m.id }) {
            val at = markerPlace(track, m.id, now) ?: m.fraction
            glides.remove(m.id)
            gone[m.id] = Gone(m, at, now, at <= markerNear)
        }
        return track.copy(markers = markers, pops = pops, glides = glides, gone = gone, later = later)
    }

    /** One marker as drawn at [now]: its place, its pop and its opacity. */
    data class MarkerFrame(val fraction: Double, val scale: Double, val opacity: Double)

    /** [m] at [now]. Reduce Motion: no pop; a newcomer fades in over 0.2 s. Pure. */
    fun marker(track: RunwayTrack, m: RunwayMarker, now: Double, reduce: Boolean = false): MarkerFrame {
        val place = markerPlace(track, m.id, now) ?: m.fraction
        val start = track.pops[m.id] ?: return MarkerFrame(place, 1.0, 1.0)
        if (reduce) return MarkerFrame(place, 1.0, if (m.id in track.later) MotionCurve.easeOut((now - start) / WorkflowMotion.reducedFade) else 1.0)
        val p = markerPop(now - start)
        return MarkerFrame(place, p.scale, p.opacity)
    }

    /** When the last of the Runway's one-shots lands. Pure. */
    fun runwaySettles(track: RunwayTrack, reduce: Boolean): Double {
        var end = if (reduce) track.drawnAt else track.drawnAt + runwayDraw
        for (s in track.pops.values) end = max(end, s + if (reduce) WorkflowMotion.reducedFade else markerPop)
        for (g in track.glides.values) end = max(end, g.at + markerSlide)
        for (g in track.gone.values) end = max(end, g.at + markerLeaves(g.reached, reduce))
        return end
    }

    // MARK: The Horizon's words

    /** A count in the headline or subline rolls to its new value as the lens's centre number does (up and out, up from below, easeOut, 0.35 s). */
    const val wordsRoll = WorkflowMotion.rollDuration
    /** A change of wording cross-fades over 0.35 s as the new words rise 4 dp into place. */
    const val rewordDuration = WorkflowMotion.crossFade
    const val rewordRise = 4.0

    private val numberRun = Regex("\\d+")

    /** A line's words with each run of digits as one "#". Pure. */
    fun wording(s: String): String = numberRun.replace(s, "#")

    /** Whether a change is new words (a cross-fade) rather than new numbers (they roll): "2 need you" → "3 need you" rolls; "1 needs you" → "2 need you" is new words. Pure. */
    fun rewords(a: String, b: String): Boolean = wording(a) != wording(b)

    /** How Now's words changed. */
    sealed class WordsChange {
        /** Only numbers moved: each run that did, [Run.from] → [Run.to], at [Run.start] ..< [Run.end] of the new words. */
        data class Roll(val runs: List<Run>) : WordsChange()

        /** The wording itself changed. */
        data object Fade : WordsChange()
    }

    data class Run(val start: Int, val end: Int, val from: String, val to: String)

    /** "2 need you" → "3 need you" rolls the count; "2 need you" → "All quiet" cross-fades; null when nothing changed. Pure. */
    fun wordsChange(old: String, new: String): WordsChange? {
        if (old == new) return null
        if (rewords(old, new)) return WordsChange.Fade
        val a = numberRun.findAll(old).toList()
        val b = numberRun.findAll(new).toList()
        return WordsChange.Roll(a.indices.filter { a[it].value != b[it].value }.map { Run(b[it].range.first, b[it].range.last + 1, a[it].value, b[it].value) })
    }

    /** How far a roll has gone, 0 → 1, [e] seconds after the change: easeOut over 0.35 s (a 0.2 s fade under Reduce Motion). Pure. */
    fun wordsProgress(e: Double, reduce: Boolean = false): Double =
        MotionCurve.easeOut(e / if (reduce) WorkflowMotion.reducedFade else wordsRoll)

    fun wordsLast(reduce: Boolean): Double = if (reduce) WorkflowMotion.reducedFade else wordsRoll

    /** New words: the old line rising out as it fades, the new one rising into place. */
    data class Reword(val out: Slide, val into: Slide)

    /** New words [e] seconds in, 4 dp each way; null once settled. Reduce Motion: a 0.2 s cross-fade in place. Pure. */
    fun reword(e: Double, reduce: Boolean = false): Reword? {
        val d = if (reduce) WorkflowMotion.reducedFade else rewordDuration
        if (e < 0 || e >= d) return null
        val k = MotionCurve.easeOut(e / d)
        val rise = if (reduce) 0.0 else rewordRise
        return Reword(Slide(-rise * k, 1 - k), Slide(rise * (1 - k), k))
    }

    // MARK: Tab badges

    /** A badge appearing scales up from 0.5 on a spring (response 0.35, damping 0.6) as it fades in; leaving, it scales to 0.5 as it fades. */
    const val badgeFrom = 0.5
    const val badgeResponse = 0.35
    const val badgeDamping = 0.6
    /** Chosen: the fade in (easeOut), the whole of a leave (easeOut), and when the spring is drawn settled. */
    const val badgeFade = 0.2
    const val badgeLeave = 0.25
    const val badgeSettle = 0.8

    /** A badge as drawn: the count shown (the old one while it leaves), its scale and opacity, and the count rolling out ([roll] 0 → 1). */
    data class Badge(val count: Int, val scale: Double, val opacity: Double, val previous: Int?, val roll: Double)

    /**
     * A tab badge at [now]: a new count rolls in as the badge swells once ([badgeBump]); appearing it scales in from 0.5,
     * going it scales out to 0.5 and fades. Reduce Motion: a 0.2 s cross-fade, nothing scales. Pure.
     */
    fun badge(change: Change<Int>, now: Double, reduce: Boolean = false): Badge {
        val count = change.value
        val from = change.from
        val at = change.at
        val still = Badge(count, 1.0, if (count > 0) 1.0 else 0.0, null, 1.0)
        if (from == null || at == null) return still
        val e = now - at
        if (e >= badgeLasts(reduce)) return still
        val fade = MotionCurve.easeOut(e / if (reduce) WorkflowMotion.reducedFade else badgeFade)
        return when {
            from <= 0 && count > 0 ->
                if (reduce) Badge(count, 1.0, fade, null, 1.0)
                else Badge(count, badgeFrom + (1 - badgeFrom) * MotionCurve.spring(e, badgeResponse, badgeDamping), fade, null, 1.0)
            count <= 0 && from > 0 -> {
                val k = MotionCurve.easeOut(e / if (reduce) WorkflowMotion.reducedFade else badgeLeave)
                Badge(from, if (reduce) 1.0 else 1 - (1 - badgeFrom) * k, 1 - k, null, 1.0)
            }
            else -> {
                val k = wordsProgress(e, reduce)
                Badge(count, if (reduce) 1.0 else badgeBump(e), 1.0, from.takeIf { k < 1 }, k)
            }
        }
    }

    fun badgeLasts(reduce: Boolean): Double = if (reduce) WorkflowMotion.reducedFade else badgeSettle

    // MARK: Review chips

    /** A Review chip's ✓ draws once the counts have landed: trimmed 0 → 1 over 0.3 s, easeOut. */
    const val checkDraw = 0.3
    const val chipsLast = countDuration + checkDraw

    /** A chip's words [t] seconds after its card was first shown: its number counting up ("+120" reads "+105" at 0.19 s). Reduce Motion: the final words. Pure. */
    fun chipText(text: String, t: Double, reduce: Boolean = false): String {
        if (reduce) return text
        val m = numberRun.find(text) ?: return text
        val n = m.value.toIntOrNull() ?: return text
        return text.replaceRange(m.range, chipCount(t, n).toString())
    }

    /** How much of the ✓ is drawn, [t] seconds after its card was first shown: after the count. Pure. */
    fun chipCheck(t: Double, reduce: Boolean = false): Double = if (reduce) 1.0 else MotionCurve.easeOut((t - countDuration) / checkDraw)

    // MARK: Settled

    /** A new receipt slides down into place from 6 dp above as it fades in and the rows under it make room (0.35 s, easeOut); then its ✓ draws. */
    const val receiptDrop = 6.0
    const val receiptIn = WorkflowMotion.crossFade
    /** Chosen: a receipt counts as new only when it settled this recently; older lines a reload brings in just appear. */
    const val receiptFresh = 120.0

    /** A receipt arriving: its offset in dp (negative is up), opacity, height (1: all of it) and how much of its ✓ is drawn. */
    data class Receipt(val offset: Double, val opacity: Double, val height: Double, val check: Double)

    /** A receipt [e] seconds after it arrived. Reduce Motion: a 0.2 s fade in place, the ✓ whole. Pure. */
    fun receipt(e: Double, reduce: Boolean = false): Receipt {
        if (reduce) return Receipt(0.0, MotionCurve.easeOut(e / WorkflowMotion.reducedFade), 1.0, 1.0)
        val k = MotionCurve.easeOut(e / receiptIn)
        return Receipt(-receiptDrop * (1 - k), k, k, MotionCurve.easeOut((e - receiptIn) / checkDraw))
    }

    fun receiptLasts(reduce: Boolean): Double = if (reduce) WorkflowMotion.reducedFade else receiptIn + checkDraw

    /** Today's receipts as last seen, and when each new one arrived. */
    data class SettledTrack(val ids: Set<String>, val arrivals: Map<String, Double> = emptyMap())

    fun settledStart(lines: List<SettledLine>): SettledTrack = SettledTrack(lines.map { it.id }.toSet())

    /**
     * Today's receipts at [now] ([wall] the clock they are stamped on): a line not seen before that settled within the last
     * two minutes arrives; older lines a reload brings in (the first history after a reconnect) just appear. Pure.
     */
    fun settledObserve(track: SettledTrack, lines: List<SettledLine>, wall: java.time.Instant, now: Double, reduce: Boolean = false): SettledTrack {
        val ids = lines.map { it.id }.toSet()
        if (ids == track.ids) return track
        val arrivals = track.arrivals.filter { (id, at) -> id in ids && now - at < receiptLasts(reduce) }.toMutableMap()
        for (l in lines) if (l.id !in track.ids && wall.secondsSince(l.at) < receiptFresh) arrivals[l.id] = now
        return SettledTrack(ids, arrivals)
    }

    // MARK: The queued receipt

    /** The receipt line of a reply still on its way (queued, held, sent) rises 6 dp as it fades in, and fades as it folds away (0.3 s); its words cross-fade. */
    const val queuedFade = 0.3
    const val queuedRise = 6.0

    /** The receipt line arriving, [e] seconds in. Reduce Motion: a 0.2 s fade. Pure. */
    fun queuedIn(e: Double, reduce: Boolean = false): Slide {
        if (reduce) return Slide(0.0, MotionCurve.easeOut(e / WorkflowMotion.reducedFade))
        val k = MotionCurve.easeOut(e / queuedFade)
        return Slide(queuedRise * (1 - k), k)
    }
}
