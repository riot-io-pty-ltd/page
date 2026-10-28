package app.page.android.ui.nw.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Bolt
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.NowMotion
import app.page.android.model.OneShotBook
import app.page.android.model.RunwayModel
import app.page.android.model.WorkflowMotion
import app.page.android.ui.nw.theme.LocalFixedNow
import app.page.android.ui.nw.theme.LocalFixedPhase
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.LocalNowScript
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.pinned
import java.time.Instant
import kotlinx.coroutines.delay

/**
 * The Runway: a line across the next six hours with a "now" dot at the left and a labelled tick per deadline or
 * event (battery cutoff, 5h limit, resets). On AC the line runs to the end unbroken with a "on AC" note, and no
 * cutoff. Sits on a glass card; a tap opens the Tower, scrolled to Budget. (iOS NWRunwayBar.)
 */
/** Where a marker's label goes: above or below the line, in which lane, flipped to the tick's left or not. */
internal data class RunwayLabelSlot(val index: Int, val below: Boolean, val lane: Int, val flip: Boolean)

/**
 * Labels alternate above and below the line (board 06), so clustered ticks never stack into a staircase; within a
 * side, a label that would touch the previous one moves to a further lane. [lineWidth] and [labelWidths] are in dp;
 * [belowTaken] is what already sits under the line's ends ("NOW", "on AC"), as (start, end) spans in dp. Pure.
 */
internal fun runwayLabelSlots(fractions: List<Double>, labelWidths: List<Float>, lineWidth: Float, inset: Float, belowTaken: List<Pair<Float, Float>>): List<RunwayLabelSlot> {
    val order = fractions.indices.sortedBy { fractions[it] }
    val spans = arrayOf(ArrayList<ArrayList<Pair<Float, Float>>>(), ArrayList<ArrayList<Pair<Float, Float>>>())
    spans[1].add(ArrayList(belowTaken))
    val out = ArrayList<RunwayLabelSlot>()
    for ((n, i) in order.withIndex()) {
        val tick = inset + lineWidth * fractions[i].toFloat()
        val flip = fractions[i] > 0.72
        val width = labelWidths[i]
        val start = if (flip) tick - 5f - width else tick + 5f
        val end = start + width
        val side = if (n % 2 == 0) 0 else 1
        val lanes = spans[side]
        var lane = 0
        while (true) {
            if (lane == lanes.size) lanes.add(ArrayList())
            if (lanes[lane].none { (s0, e0) -> start < e0 + 4f && end > s0 - 4f }) break
            lane++
        }
        lanes[lane].add(start to end)
        out.add(RunwayLabelSlot(i, side == 1, lane, flip))
    }
    return out
}

/** The Runway's track ([NowMotion.RunwayTrack]), its one clock, Reduce Motion, and whether the NOW dot breathes. */
@Stable
class RunwayMotion(val track: NowMotion.RunwayTrack, val clock: State<Double>, val reduce: Boolean, val breathing: Boolean, val period: Double = NowMotion.nowDotPeriod)

/** When the Runway first drew this process: it draws once, however often Now is rebuilt. */
private val runwayBook = OneShotBook()

/**
 * The Runway in motion: its markers placed on the live clock (re-read every 10 s, so they slide towards now in real
 * time, a step too small to see drawn at once), a jump in a marker's place gliding there over 0.8 s, a marker whose
 * time comes flashing once as it goes, and the line drawing left to right on its first appearance this process with
 * each marker popping in as it is reached. [breathing]: the NOW dot breathes with the pulse, on its [period] (agents
 * at work, never at dusk). One clock, only while something moves; held in the background and under a sheet. Under the render harness it
 * is the script's Runway folded up to the pinned moment ([LocalNowScript]); any other pinned frame draws it arrived.
 */
@Composable
fun rememberRunwayMotion(model: RunwayModel, breathing: Boolean, period: Double = NowMotion.nowDotPeriod): RunwayMotion {
    val reduce = LocalReduceMotion.current
    val fixed = LocalFixedNow.current
    val pinned = LocalFixedPhase.current
    // Whole 10 s steps of the live clock, so the ticks in between recompose nothing.
    val live by rememberNWNow(slowMs = 10_000)
    val step = live.epochSecond / 10
    val markers = remember(model, step, fixed) { NowMotion.runwayAt(model, fixed ?: Instant.ofEpochSecond(step * 10)) }
    val track = if (pinned != null) {
        val at = LocalMotionPin.current.pinned(NWMotionPin.Kind.NOW)
        val script = LocalNowScript.current?.takeIf { it.isNotEmpty() }
        remember(markers, script, at, reduce) {
            val now = fixed ?: Instant.now()
            if (at != null && script != null) {
                script.drop(1).filter { it.first <= at }.fold(NowMotion.runwayStart(NowMotion.runwayAt(script[0].second.runway, now), 0.0)) { t, (s, look) ->
                    NowMotion.runwayObserve(t, NowMotion.runwayAt(look.runway, now), s, reduce)
                }
            } else {
                NowMotion.runwayStart(markers, -100.0)
            }
        }
    } else {
        val held = remember { RunwayHolder() }
        val now = nwClockSeconds()
        val next = held.track?.let { NowMotion.runwayObserve(it, markers, now, reduce) } ?: NowMotion.runwayStart(markers, runwayBook.start("runway", now))
        held.track = next
        next
    }
    val settles = NowMotion.runwaySettles(track, reduce)
    val loops = breathing && !reduce
    // 30 frames a second while a one-shot plays, then 20 for the breath alone; nothing at all once a quiet Runway lands.
    var playing by remember(settles) { mutableStateOf(pinned == null && nwClockSeconds() < settles) }
    if (playing) LaunchedEffect(settles) {
        delay(((settles - nwClockSeconds()) * 1000).toLong().coerceAtLeast(0) + 16)
        playing = false
    }
    val clock = rememberNowClock(settles, if (playing) 30.0 else 20.0, loops)
    return remember(track, clock, reduce, loops, period) { RunwayMotion(track, clock, reduce, loops, period) }
}

private class RunwayHolder {
    var track: NowMotion.RunwayTrack? = null
}

@Composable
fun NWRunwayBar(model: RunwayModel, modifier: Modifier = Modifier, motion: RunwayMotion? = null) {
    // Labels are sp text: rows and widths follow the system font scale so they never overprint.
    val fs = androidx.compose.ui.platform.LocalDensity.current.fontScale.coerceIn(1f, 2f)
    val labelRow = 16.dp * fs
    val inset = 22.dp
    // In motion, the markers as placed on the live clock; the labels' lanes follow their places, not their glides.
    val markers = motion?.track?.markers ?: model.markers
    androidx.compose.foundation.layout.BoxWithConstraints(modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = runwaySpoken(model) }) {
        val w = maxWidth - inset * 2
        val nowSpan = (inset.value - 6f) to (inset.value + 30f * fs)
        val acSpan = (inset.value + w.value - 70f * fs) to (inset.value + w.value)
        val slots = runwayLabelSlots(
            markers.map { it.fraction }, markers.map { it.label.length * 4.9f * fs }, w.value, inset.value,
            listOf(nowSpan) + (if (model.onAC) listOf(acSpan) else emptyList()),
        )
        val above = (slots.filter { !it.below }.maxOfOrNull { it.lane } ?: -1) + 1
        val below = maxOf(1, (slots.filter { it.below }.maxOfOrNull { it.lane } ?: -1) + 1)
        val lineY = labelRow * above + 10.dp
        val total = lineY + 14.dp + labelRow * below + 4.dp
        // Glows stay inside the card: the first Decide card sits right under it.
        Box(Modifier.fillMaxWidth().height(total).clipToBounds()) {
            Canvas(Modifier.fillMaxWidth().height(total)) {
                val now = motion?.clock?.value ?: 0.0
                val y = lineY.toPx()
                val x0 = inset.toPx()
                val ww = w.toPx()
                val drawn = motion?.let { NowMotion.runwayLine(now - it.track.drawnAt, it.reduce).toFloat() } ?: 1f
                if (drawn > 0f) drawRoundRect(
                    Brush.horizontalGradient(
                        listOf(NW.Palette.teal.opacity(if (model.onAC) 0.55 else 0.5).color, NW.Palette.teal.opacity(if (model.onAC) 0.55 else 0.22).color),
                        startX = x0, endX = x0 + ww,
                    ),
                    topLeft = Offset(x0, y - 1.dp.toPx()), size = Size(ww * drawn, 2.dp.toPx()), cornerRadius = CornerRadius(1.dp.toPx()),
                )
                // The NOW dot: its halo breathes with the pulse while agents work (the room's 0.12 and 0.25 → 0.5).
                val b = if (motion?.breathing == true) NowMotion.nowDot(now, motion.period) else 0.0
                drawCircle(
                    Color.White.copy(alpha = (WorkflowMotion.haloFrom + (WorkflowMotion.haloTo - WorkflowMotion.haloFrom) * b).toFloat()),
                    radius = 9.dp.toPx() * (1 + WorkflowMotion.breathScale * b).toFloat(), center = Offset(x0, y),
                )
                drawCircle(Color.White, radius = 6.dp.toPx(), center = Offset(x0, y))
                for (m in markers) {
                    val f = motion?.let { NowMotion.marker(it.track, m, now, it.reduce) } ?: NowMotion.MarkerFrame(m.fraction, 1.0, 1.0)
                    if (f.opacity <= 0.001) continue
                    tick(m.tone.color, x0 + f.fraction.toFloat() * ww, y, f.scale.toFloat(), f.opacity.toFloat())
                }
                // A marker whose time came flashes once at the NOW end as it fades; any other only fades where it was.
                motion?.track?.gone?.values?.forEach { g ->
                    val l = NowMotion.markerLeave(now - g.at, g.reached, motion.reduce)
                    val x = x0 + g.fraction.toFloat() * ww
                    if (l.flash > 0.001) {
                        // As big and bright as a line's flare at its height (NowMotion.flashGlow), round a 6 dp glow.
                        val glow = NowMotion.flashGlow(l.flash)
                        val r = 6.dp.toPx() * glow.scale.toFloat()
                        drawCircle(Brush.radialGradient(listOf(g.marker.tone.color.opacity(glow.opacity).color, Color.Transparent), center = Offset(x, y), radius = r), r, Offset(x, y))
                    }
                    if (l.opacity > 0.001) tick(g.marker.tone.color, x, y, 1f, l.opacity.toFloat())
                }
            }
            val labelWidth = 92.dp * fs
            for (slot in slots) {
                val m = markers[slot.index]
                // Labels sit right of their tick; near the end they flip to its left. Above the line, lane 0 is nearest it.
                val y = if (slot.below) lineY + 12.dp + labelRow * slot.lane else lineY - 10.dp - labelRow * (slot.lane + 1)
                Text(
                    m.label, style = NW.Typo.caption.copy(fontSize = 11.sp, lineHeight = 14.sp), color = m.tone.color.color, maxLines = 1, softWrap = false, overflow = TextOverflow.Clip,
                    textAlign = if (slot.flip) TextAlign.End else TextAlign.Start,
                    modifier = Modifier.width(labelWidth)
                        .offset {
                            val place = motion?.let { NowMotion.markerPlace(it.track, m.id, it.clock.value) } ?: m.fraction
                            val x = inset + w * place.toFloat()
                            IntOffset((if (slot.flip) x - 5.dp - labelWidth else x + 5.dp).roundToPx(), y.roundToPx())
                        }
                        .then(if (motion != null) Modifier.graphicsLayer { alpha = NowMotion.marker(motion.track, m, motion.clock.value, motion.reduce).opacity.toFloat() } else Modifier),
                )
            }
            Text("NOW", style = NW.Typo.label.copy(letterSpacing = 0.8.sp), color = NW.Palette.textTertiary.color, modifier = Modifier.offset(x = inset - 6.dp, y = lineY + 12.dp))
            if (model.onAC) {
                Row(
                    Modifier.width(70.dp).offset(x = inset + w - 70.dp, y = lineY + 12.dp),
                    horizontalArrangement = androidx.compose.foundation.layout.Arrangement.End, verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Outlined.Bolt, null, tint = NW.Palette.teal.opacity(0.9).color, modifier = Modifier.size(11.dp))
                    Text("on AC", style = NW.Typo.caption.copy(fontSize = 11.sp), color = NW.Palette.teal.opacity(0.9).color)
                }
            }
        }
    }
}

/** A marker's tick, popped to [scale] about its middle. */
private fun androidx.compose.ui.graphics.drawscope.DrawScope.tick(tone: app.page.android.ui.nw.theme.Rgba, x: Float, y: Float, scale: Float, opacity: Float) {
    val tw = 3.dp.toPx() * scale
    val th = 16.dp.toPx() * scale
    drawRoundRect(tone.opacity(opacity.toDouble()).color, topLeft = Offset(x - tw / 2, y - th / 2), size = Size(tw, th), cornerRadius = CornerRadius(tw / 2))
}

/** What TalkBack reads. */
fun runwaySpoken(model: RunwayModel): String {
    val power = if (model.onAC) "on power" else "on battery"
    return if (model.markers.isEmpty()) "Runway: nothing ahead in the next six hours, $power"
    else "Runway, $power: " + model.markers.joinToString(", ") { it.label }
}
