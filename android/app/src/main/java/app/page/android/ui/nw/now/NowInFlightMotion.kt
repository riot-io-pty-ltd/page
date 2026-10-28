package app.page.android.ui.nw.now

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.layout
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import app.page.android.model.FlightHealth
import app.page.android.model.FlightLineStatus
import app.page.android.model.FlightWorkflowLine
import app.page.android.model.InFlightRow
import app.page.android.model.InFlightSection
import app.page.android.model.NowMotion
import app.page.android.model.WorkflowMotion
import app.page.android.ui.nw.components.drawStar
import app.page.android.ui.nw.components.nwClockSeconds
import app.page.android.ui.nw.components.rememberNWMotionClock
import app.page.android.ui.nw.theme.LocalFixedPhase
import app.page.android.ui.nw.theme.LocalFlightScript
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.Rgba
import app.page.android.ui.nw.theme.pinned
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlinx.coroutines.delay

// The In flight section in motion ([NowMotion]), in the Workflows lens's idiom and glow (NWRoomLenses' orbit): arcs
// and bars that sweep in, spring to each new count with a flare at their leading end and close with one soft pulse;
// a glint and a comet while a session works normally, and stillness when it is stuck. Only the In flight wrappers
// here move: NWRing and the other shared bars stay still everywhere else. Everything per frame is read from one
// clock in draw, layer and layout lambdas, so a tick never recomposes the list. (iOS NWInFlightMotion.swift.)

/** When each In flight line, card and tile first showed, and each ending played: once per process, however often Now is rebuilt. */
private val flightBooks = NowMotion.Books()

/** Chosen: a fresh look's first seconds (a resume or a reconnect, when the Mac sends its list again at once) never count as news. */
private const val freshQuiet = 3.0

/** The section's track, its one clock and Reduce Motion, handed to every card and tile. */
@Stable
class FlightMotion(val track: NowMotion.Track, val clock: State<Double>, val reduce: Boolean) {
    val now: Double get() = clock.value
}

/**
 * The section as it has been seen since it appeared ([NowMotion.Track]), each new snapshot observed as it arrives on
 * the [nwClockSeconds] base. A resume (the app coming back to the foreground) or a new [epoch] (a reconnect) starts it
 * afresh, so their first snapshots are never news. Under the render harness it is the script's snapshots folded up to
 * the pinned moment instead, Now appearing at 0; any other pinned frame draws everything long since arrived.
 */
@Composable
fun rememberFlightTrack(section: InFlightSection, epoch: Any? = null): NowMotion.Track {
    val reduce = LocalReduceMotion.current
    val pinned = LocalFixedPhase.current
    if (pinned != null) {
        val at = LocalMotionPin.current.pinned(NWMotionPin.Kind.FLIGHT)
        val script = LocalFlightScript.current?.takeIf { it.isNotEmpty() }
        return remember(section, script, at, reduce) {
            // A book of its own for every pinned frame, as the room's replay: each frame is the section's first look.
            val books = NowMotion.Books()
            if (at != null && script != null) {
                script.drop(1).filter { it.first <= at }.fold(NowMotion.start(script[0].second, 0.0, books, reduce = reduce)) { t, (s, next) -> NowMotion.observe(t, next, s, books, reduce) }
            } else {
                NowMotion.start(section, -100.0, books, reduce = reduce)
            }
        }
    }
    val resumed = rememberStartCount()
    val held = remember(epoch, resumed) { mutableStateOf<NowMotion.Track?>(null) }
    val prev = held.value
    val now = nwClockSeconds()
    val next = if (prev == null) NowMotion.start(section, now, flightBooks, freshQuiet, reduce) else NowMotion.observe(prev, section, now, flightBooks, reduce)
    if (next !== prev) SideEffect { held.value = next }
    return next
}

/** How many times the app has come back to the foreground while this was composed. */
@Composable
private fun rememberStartCount(): Int {
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var count by remember { mutableIntStateOf(0) }
    DisposableEffect(lifecycle) {
        var stopped = false
        val observer = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_STOP) stopped = true
            if (e == Lifecycle.Event.ON_START && stopped) { stopped = false; count++ }
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    return count
}

/**
 * The section's one clock: 30 frames a second while a line glints or a one-shot plays, 20 while only stars and dots
 * breathe, none under Reduce Motion once its fades have landed. Paused in the background and under a sheet or the room.
 */
@Composable
fun rememberFlightClock(track: NowMotion.Track, reduce: Boolean): State<Double> {
    val rows = track.section.strip.ifEmpty { track.section.rows }
    val settles = NowMotion.settlesAt(track, reduce)
    val loops = !reduce && rows.isNotEmpty()
    val glints = !reduce && rows.any { r -> NowMotion.live(r, false) && r.card.runningWorkflows.isNotEmpty() }
    // 30 while a one-shot plays, down to 20 the moment the last one lands (as the Runway's clock does), not at the
    // next rebuild of the section.
    val pinned = LocalFixedPhase.current != null
    var playing by remember(settles) { mutableStateOf(!pinned && nwClockSeconds() < settles) }
    if (playing) LaunchedEffect(settles) {
        delay(((settles - nwClockSeconds()) * 1000).toLong().coerceAtLeast(0) + 16)
        playing = false
    }
    val fps = if (glints || playing) 30.0 else 20.0
    return rememberNWMotionClock(listOf(settles, loops, fps), fps) { now -> loops || now < settles }
}

// MARK: - Arcs and bars

/** The strip tile's ring round its star, in motion: the In flight arc. */
@Composable
fun FlightRing(motion: FlightMotion, row: InFlightRow, line: FlightWorkflowLine, index: Int, modifier: Modifier = Modifier, size: Dp = 34.dp, lineWidth: Dp = 2.dp) {
    Canvas(modifier.size(size).clearAndSetSemantics {}) {
        val now = motion.now
        val f = NowMotion.line(motion.track, row, line, index, NowMotion.Place.STRIP, now, motion.reduce)
        drawFlightRing(f, now, index, lineWidth.toPx())
    }
}

private fun DrawScope.drawFlightRing(f: NowMotion.LineFrame, now: Double, index: Int, lw: Float) {
    val color = NW.Palette.teal.mixed(NW.Palette.amber, f.amber)
    val o = f.opacity
    if (o <= 0.001) return
    val c = center
    val r = size.minDimension / 2 - lw / 2
    val box = Size(r * 2, r * 2)
    val at = Offset(c.x - r, c.y - r)
    drawCircle(color.opacity(0.2 * o).color, r, c, style = Stroke(lw))
    if (f.live) {
        // The comet: a 40° tail round the track, once every 8 s, clockwise, as round the room's orbit. Drawn ending at
        // 3 o'clock and turned so its head sits where the clock says.
        val span = WorkflowMotion.cometSpan.toFloat()
        rotate(Math.toDegrees(WorkflowMotion.cometAngle(now)).toFloat() - 90f, c) {
            val tail = Brush.sweepGradient(0f to Color.Transparent, (360f - span) / 360f to Color.Transparent, 1f to color.mixed(NW.Palette.white, 0.3).opacity(WorkflowMotion.cometOpacity * o).color, center = c)
            drawArc(tail, 360f - span, span, false, at, box, alpha = 0.35f, style = Stroke(lw * 3))
            drawArc(tail, 360f - span, span, false, at, box, style = Stroke(lw))
        }
    }
    val sweep = 360f * f.value.toFloat()
    if (sweep > 0.2f) {
        drawArc(color.opacity(o).color, -90f, sweep, false, at, box, style = Stroke(lw, cap = StrokeCap.Round))
        val a = Math.toRadians(-90.0 + sweep)
        drawHead(f, color, Offset(c.x + cos(a).toFloat() * r, c.y + sin(a).toFloat() * r), now, index, 4.5f, 2f)
    }
    // A finish: one soft glow grows off the ring and fades (the room's ring closing, smaller).
    f.pulse?.let { p ->
        val pr = r * p.scale.toFloat()
        drawCircle(color.opacity(p.opacity * 0.35).color, pr, c, style = Stroke(lw * 4))
        drawCircle(color.opacity(p.opacity).color, pr, c, style = Stroke(lw))
    }
}

/** A card's workflow bar, in motion: the In flight bar. [height] is the track's; its glow and head spill past it. */
@Composable
fun FlightBar(motion: FlightMotion, row: InFlightRow, line: FlightWorkflowLine, index: Int, modifier: Modifier = Modifier, height: Dp = 3.dp) {
    Canvas(modifier.fillMaxWidth().height(height).clearAndSetSemantics {}) {
        val now = motion.now
        val f = NowMotion.line(motion.track, row, line, index, NowMotion.Place.CARD, now, motion.reduce)
        drawFlightBar(f, now, index, height.toPx())
    }
}

private fun DrawScope.drawFlightBar(f: NowMotion.LineFrame, now: Double, index: Int, h: Float) {
    val color = NW.Palette.teal.mixed(NW.Palette.amber, f.amber)
    val o = f.opacity
    if (o <= 0.001) return
    val w = size.width
    val top = size.height / 2 - h / 2
    val round = CornerRadius(h / 2)
    // A finish glows along the whole bar, the band widening as it fades (the ring's 1 → 1.35, laid flat).
    f.pulse?.let { p ->
        val spread = (3.dp.toPx() + 9.dp.toPx() * ((p.scale - 1) / WorkflowMotion.pulseGrow).toFloat())
        val glow = color.opacity(p.opacity).color
        drawRoundRect(
            Brush.verticalGradient(0f to Color.Transparent, 0.5f to glow, 1f to Color.Transparent, startY = top - spread, endY = top + h + spread),
            Offset(-spread / 2, top - spread), Size(w + spread, h + 2 * spread), CornerRadius(h / 2 + spread),
        )
    }
    drawRoundRect(Color.White.copy(alpha = 0.08f * o.toFloat()), Offset(0f, top), Size(w, h), round)
    val fw = w * max(f.value, 0.02).toFloat().coerceAtMost(1f)
    drawRoundRect(color.opacity(o).color, Offset(0f, top), Size(fw, h), round)
    if (f.live) {
        // The glint: 28 % of the track long, teal-white, running along the filled part only, brightest half way.
        val len = (NowMotion.glintLength * w).toFloat()
        val cx = (NowMotion.glintCentre(now, index, (fw / w).toDouble()) * w).toFloat()
        val shine = NW.Palette.teal.mixed(NW.Palette.white, 0.6).opacity(NowMotion.glintAlpha(now, index) * o).color
        clipRect(0f, top, fw, top + h) {
            drawRect(Brush.horizontalGradient(0f to Color.Transparent, 0.5f to shine, 1f to Color.Transparent, startX = cx - len / 2, endX = cx + len / 2), Offset(cx - len / 2, top), Size(len, h))
        }
    }
    drawHead(f, color, Offset(fw, size.height / 2), now, index, 5.5f, 2.5f)
}

/**
 * The leading end: a small teal-white head on a glow that breathes in the room's 1.8 s rhythm while the line runs
 * normally, and flares (radius × 1 → 1.8, opacity 0.9 → 0.4) as a new count springs on. Nothing on a still line.
 */
private fun DrawScope.drawHead(f: NowMotion.LineFrame, color: Rgba, head: Offset, now: Double, index: Int, glowDp: Float, coreDp: Float) {
    if (!f.live && f.flare == null) return
    val b = if (f.live) WorkflowMotion.breath(now, index) else 0.0
    val glow = (glowDp + glowDp / 3 * b.toFloat()) * density
    if (f.live) drawCircle(Brush.radialGradient(listOf(color.opacity((0.3 + 0.4 * b) * f.opacity).color, Color.Transparent), center = head, radius = glow), glow, head)
    f.flare?.let { fl ->
        val fr = glow * fl.scale.toFloat()
        drawCircle(Brush.radialGradient(listOf(color.opacity(fl.opacity * f.opacity).color, Color.Transparent), center = head, radius = fr), fr, head)
    }
    drawCircle(color.mixed(NW.Palette.white, 0.6).opacity(f.opacity).color, coreDp * density, head)
}

// MARK: - Stars and the health dot

/** A working session's star glyph, breathing with the pulse (1 → 1.04, glow 0.3 → 0.55, 4 s) while it works normally; still when it is stuck. */
@Composable
fun FlightStar(seed: ULong, color: Rgba, live: Boolean, clock: State<Double>, modifier: Modifier = Modifier, size: Dp = 30.dp, index: Int = 0) {
    Box(modifier.size(size).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size * 1.5f)) {
            val s = size.toPx()
            if (!live) {
                drawStar(seed, color, 1.0, s)
                return@Canvas
            }
            val b = NowMotion.starBreath(clock.value, index)
            scale((1 + NowMotion.starScale * b).toFloat()) { drawStar(seed, color, 1.0, s, NowMotion.starGlowFrom + (NowMotion.starGlowTo - NowMotion.starGlowFrom) * b) }
        }
    }
}

/**
 * The HEALTH dot: green breathes on the pulse's 4 s, sky (a long-running command) slower, on 6 s; amber (stuck, rate
 * limited) sends one slow ring every 3 s, as a waiting item does. Still under Reduce Motion.
 */
@Composable
fun FlightHealthDot(health: FlightHealth, color: Rgba, motion: FlightMotion, size: Dp = 7.dp) {
    Box(
        Modifier.size(size).drawBehind {
            val r = this.size.minDimension / 2
            if (motion.reduce) {
                drawCircle(color.color, r)
                return@drawBehind
            }
            val now = motion.now
            if (health.needsAttention) {
                val ring = NowMotion.healthRipple(now)
                drawCircle(color.opacity(ring.opacity).color, ring.radius.dp.toPx(), style = Stroke(1.2.dp.toPx()))
                drawCircle(color.color, r)
            } else {
                val b = NowMotion.dotBreath(now, if (health == FlightHealth.LONG_RUNNING) NowMotion.longBreath else NowMotion.healthyBreath)
                val halo = color.opacity(WorkflowMotion.haloFrom + (WorkflowMotion.haloTo - WorkflowMotion.haloFrom) * b).color
                val soft = 0.7f * r
                val glow = 2 * r + soft
                drawCircle(Brush.radialGradient(0f to halo, (2 * r - soft) / glow to halo, 1f to Color.Transparent, center = center, radius = glow), glow)
                drawCircle(color.color, r * (1 + WorkflowMotion.breathScale * b).toFloat())
            }
        },
    )
}

// MARK: - Words that roll

/** Text that rolls to a new value: the old slides up and out as the new comes up from below (a 0.2 s cross-fade under Reduce Motion). */
@Composable
fun RollingText(text: String, style: TextStyle, color: Color, reduce: Boolean, modifier: Modifier = Modifier, maxLines: Int = 1) {
    AnimatedContent(
        text, modifier,
        transitionSpec = {
            if (reduce) {
                fadeIn(tween(200)) togetherWith fadeOut(tween(200))
            } else {
                (slideInVertically(tween(350)) { it } + fadeIn(tween(350))) togetherWith (slideOutVertically(tween(250)) { -it } + fadeOut(tween(250))) using SizeTransform(clip = true)
            }
        },
        label = "roll",
    ) { t -> Text(t, style = style, color = color, maxLines = maxLines, overflow = TextOverflow.Ellipsis) }
}

// MARK: - Arriving and leaving

/** A card or tile rising in from [start] on the clock (12 dp and a fade, on a spring); null: it was already there. */
fun Modifier.flightRise(motion: FlightMotion, start: Double?): Modifier = if (start == null) this else graphicsLayer {
    val r = NowMotion.rise(motion.now - start, motion.reduce)
    translationY = r.offset.dp.toPx()
    alpha = r.opacity.toFloat()
}

/** A card (or, [across], a tile) leaving from [at]: it fades as it folds away; under Reduce Motion it only fades. */
fun Modifier.flightLeave(motion: FlightMotion, at: Double, across: Boolean = false): Modifier = layout { m, c ->
    val p = m.measure(c)
    val k = NowMotion.leave(motion.now - at, motion.reduce).toFloat()
    val keep = if (motion.reduce) 1f else 1 - k
    val w = if (across) (p.width * keep).roundToInt() else p.width
    val h = if (across) p.height else (p.height * keep).roundToInt()
    layout(w, h) { p.placeWithLayer(0, 0) { alpha = 1 - k } }
}

/** A line that has ended: it fades and folds away with its ghost ([NowMotion.ghost]). */
fun Modifier.flightFold(motion: FlightMotion, row: InFlightRow, line: FlightWorkflowLine): Modifier = if (line.status == FlightLineStatus.RUNNING) this else layout { m, c ->
    val p = m.measure(c)
    val f = NowMotion.line(motion.track, row, line, 0, NowMotion.Place.CARD, motion.now, motion.reduce)
    layout(p.width, (p.height * f.height.toFloat()).roundToInt()) { p.placeWithLayer(0, 0) { alpha = f.opacity.toFloat() } }
}
