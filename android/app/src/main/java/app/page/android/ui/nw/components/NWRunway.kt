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
import app.page.android.model.RunwayModel
import app.page.android.ui.nw.theme.NW

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

@Composable
fun NWRunwayBar(model: RunwayModel, modifier: Modifier = Modifier) {
    // Labels are sp text: rows and widths follow the system font scale so they never overprint.
    val fs = androidx.compose.ui.platform.LocalDensity.current.fontScale.coerceIn(1f, 2f)
    val labelRow = 16.dp * fs
    val inset = 22.dp
    androidx.compose.foundation.layout.BoxWithConstraints(modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = runwaySpoken(model) }) {
        val w = maxWidth - inset * 2
        val nowSpan = (inset.value - 6f) to (inset.value + 30f * fs)
        val acSpan = (inset.value + w.value - 70f * fs) to (inset.value + w.value)
        val slots = runwayLabelSlots(
            model.markers.map { it.fraction }, model.markers.map { it.label.length * 4.9f * fs }, w.value, inset.value,
            listOf(nowSpan) + (if (model.onAC) listOf(acSpan) else emptyList()),
        )
        val above = (slots.filter { !it.below }.maxOfOrNull { it.lane } ?: -1) + 1
        val below = maxOf(1, (slots.filter { it.below }.maxOfOrNull { it.lane } ?: -1) + 1)
        val lineY = labelRow * above + 10.dp
        val total = lineY + 14.dp + labelRow * below + 4.dp
        Box(Modifier.fillMaxWidth().height(total)) {
            Canvas(Modifier.fillMaxWidth().height(total)) {
                val y = lineY.toPx()
                val x0 = inset.toPx()
                val ww = w.toPx()
                drawRoundRect(
                    Brush.horizontalGradient(
                        listOf(NW.Palette.teal.opacity(if (model.onAC) 0.55 else 0.5).color, NW.Palette.teal.opacity(if (model.onAC) 0.55 else 0.22).color),
                        startX = x0, endX = x0 + ww,
                    ),
                    topLeft = Offset(x0, y - 1.dp.toPx()), size = Size(ww, 2.dp.toPx()), cornerRadius = CornerRadius(1.dp.toPx()),
                )
                drawCircle(Color.White.copy(alpha = 0.25f), radius = 9.dp.toPx(), center = Offset(x0, y))
                drawCircle(Color.White, radius = 6.dp.toPx(), center = Offset(x0, y))
                for (m in model.markers) {
                    val x = x0 + m.fraction.toFloat() * ww
                    drawRoundRect(m.tone.color.color, topLeft = Offset(x - 1.5.dp.toPx(), y - 8.dp.toPx()), size = Size(3.dp.toPx(), 16.dp.toPx()), cornerRadius = CornerRadius(1.5.dp.toPx()))
                }
            }
            val labelWidth = 92.dp * fs
            for (slot in slots) {
                val m = model.markers[slot.index]
                val x = inset + w * m.fraction.toFloat()
                // Labels sit right of their tick; near the end they flip to its left. Above the line, lane 0 is nearest it.
                val y = if (slot.below) lineY + 12.dp + labelRow * slot.lane else lineY - 10.dp - labelRow * (slot.lane + 1)
                Text(
                    m.label, style = NW.Typo.caption.copy(fontSize = 11.sp, lineHeight = 14.sp), color = m.tone.color.color, maxLines = 1, softWrap = false, overflow = TextOverflow.Clip,
                    textAlign = if (slot.flip) TextAlign.End else TextAlign.Start,
                    modifier = Modifier.width(labelWidth).offset(x = if (slot.flip) x - 5.dp - labelWidth else x + 5.dp, y = y),
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

/** What TalkBack reads. */
fun runwaySpoken(model: RunwayModel): String {
    val power = if (model.onAC) "on power" else "on battery"
    return if (model.markers.isEmpty()) "Runway: nothing ahead in the next six hours, $power"
    else "Runway, $power: " + model.markers.joinToString(", ") { it.label }
}
