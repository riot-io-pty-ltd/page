package app.page.android.ui.nw.now

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.ClipOp
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.page.android.model.ApproachModel
import app.page.android.model.MotionCurve
import app.page.android.ui.nw.components.NWOneShot
import app.page.android.ui.nw.components.nwClockSeconds
import app.page.android.ui.nw.theme.LocalCardGlow
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.Rgba
import kotlin.math.max

/**
 * Which rows are arriving, decided once as each first appears. Plain fields, not state: the stream notices an
 * arrival in the same composition that draws it, so its first frame is already on the pulse (a state write would
 * draw one frame in the slot first). Kept for the whole Now screen, not per card: a card scrolled away and back is
 * composed afresh, and must not replay its approach. Nothing arrives on the first look at a loaded inbox, so a
 * launch is not a flood.
 */
class ArrivalBook {
    private var seen: Set<String>? = null
    private val starts = HashMap<String, Double>()

    /** Records the rows drawn now ([order], ranked), once the inbox has [loaded]; new ones get a start at [now] on the [nwClockSeconds] base. */
    fun observe(order: List<String>, loaded: Boolean, animate: Boolean, now: Double = nwClockSeconds()) {
        if (!loaded) return
        starts.entries.removeAll { now - it.value > ApproachModel.duration + 5 }
        val previous = seen
        seen = order.toSet()
        if (previous == null || !animate) return
        // A few arrivals come down one after another; a flood just appears.
        starts.putAll(ApproachModel.schedule(ApproachModel.arrivals(previous.toList(), order), now))
    }

    /** When [id] leaves the pulse (possibly a moment ahead, staggered), or null if it is not arriving. */
    fun start(id: String): Double? = starts[id]
}

/**
 * Where a card is, relative to the pulse it comes from, in px in the card's own coordinates (its slot's top is 0):
 * how far below the pulse it sits, and the Horizon's words band it must pass behind (null when the Horizon is out of
 * view, which is the only time the band is not on screen).
 */
data class ArrivalGeometry(val distance: Float, val wordsTop: Float?, val wordsBottom: Float?)

/**
 * FINAL APPROACH for one card ([ApproachModel] for the timing): a card that has just arrived comes down from the pulse
 * into its slot on spring(0.5, 0.8), trailing a faint contrail back up to the pulse; by 520 ms it has settled and the
 * glow is off. In flight it is an empty outline in its class colour that grows out of the pulse, and it passes behind
 * the Horizon's words, so no text is ever drawn over text; its own content fades in only as it lands. The cards below
 * make room on the same spring (the stream's item placement); nothing above moves. (iOS NWArrival.)
 *
 * [geometry] is read while drawing (it follows the scroll without recomposing). [pinned] draws that many seconds in
 * (the render harness). Remove animations: the card is simply there.
 */
@Composable
fun NWArrival(
    start: Double?,
    tint: Rgba,
    radius: Dp,
    geometry: () -> ArrivalGeometry?,
    modifier: Modifier = Modifier,
    pinned: Double? = null,
    content: @Composable () -> Unit,
) {
    val reduce = LocalReduceMotion.current
    if ((start == null && pinned == null) || reduce) {
        Box(modifier) { content() }
        return
    }
    val glowStrength = LocalCardGlow.current.strength
    NWOneShot(start, ApproachModel.duration + 0.4, pinned) { e ->
        if (e == null) {
            Box(modifier) { content() }
        } else {
            // Staggered arrivals wait out of sight until their turn.
            val waiting = e < 0
            val f = ApproachModel.frame(max(0.0, e))
            Box(
                modifier
                    // Everything but the Horizon's words: the band they sit in is cut out, so the outline and its
                    // contrail pass behind the headline, not across it. Fixed in the stream (outside the layer that
                    // moves the card).
                    .drawWithContent {
                        val g = geometry()
                        val top = g?.wordsTop
                        val bottom = g?.wordsBottom
                        if (top != null && bottom != null && bottom > top) {
                            clipRect(-2_000f, top, size.width + 2_000f, bottom, ClipOp.Difference) { this@drawWithContent.drawContent() }
                        } else {
                            drawContent()
                        }
                    }
                    .graphicsLayer {
                        val g = geometry()
                        val distance = g?.distance ?: 0f
                        translationY = -distance * (1 - f.travel).toFloat()
                        scaleX = f.scale.toFloat()
                        scaleY = f.scale.toFloat()
                        transformOrigin = TransformOrigin(0.5f, 0f)
                        alpha = if (waiting || g == null) 0f else f.opacity.toFloat()
                        clip = false
                    }
                    .drawBehind {
                        // The contrail: back up to the pulse, brightest at the card.
                        val length = (geometry()?.distance ?: 0f) * minOf(1.0, f.travel).toFloat()
                        if (f.contrail > 0.001 && length > 0) {
                            val w = 1.5.dp.toPx()
                            drawRect(
                                Brush.verticalGradient(listOf(tint.opacity(0.0).color, tint.opacity(0.9 * f.contrail).color), startY = -length, endY = 0f),
                                topLeft = Offset(size.width / 2 - w / 2, -length), size = Size(w, length),
                            )
                        }
                    },
            ) {
                // Its words only as it lands: in flight it is the outline alone.
                Box(Modifier.graphicsLayer { alpha = f.content.toFloat() }) { content() }
                Box(
                    Modifier.matchParentSize().drawBehind {
                        val r = CornerRadius(radius.toPx())
                        // The soft light round it is a glow, so it follows the Card glow setting (Off: none).
                        val halo = 0.55 * f.glow * glowStrength
                        if (halo > 0.003) {
                            // Contiguous 2 dp bands outward, fading smoothly (a 14-point shadow on iOS).
                            val band = 2.dp.toPx()
                            val n = 10
                            for (i in 0 until n) {
                                val d = (i + 0.5f) * band
                                val fall = (1 - i.toDouble() / n).let { it * it }
                                drawRoundRect(
                                    tint.opacity(halo * 0.3 * fall).color, Offset(-d, -d), Size(size.width + 2 * d, size.height + 2 * d),
                                    CornerRadius(r.x + d), style = Stroke(band + 0.5f),
                                )
                            }
                        }
                        drawRoundRect(tint.opacity(0.07 * f.glow).color, cornerRadius = r)
                        val edge = 0.85 * max(f.glow, f.edge)
                        if (edge > 0.003) {
                            val lw = 1.2.dp.toPx()
                            drawRoundRect(
                                tint.opacity(edge).color, Offset(lw / 2, lw / 2), Size(size.width - lw, size.height - lw), CornerRadius(r.x - lw / 2), style = Stroke(lw),
                            )
                        }
                    },
                )
            }
        }
    }
}

/**
 * What hangs under an arriving card (its first-time tip): it waits until the card has landed and fades in as it
 * settles (360 to 520 ms), once the rows below have made room, so nothing sits in the slot while the outline is still
 * in the air. In a pinned frame it is drawn part-way down with the rows below ([push], px).
 */
@Composable
fun NWArrivalTail(start: Double?, pinned: Double?, push: () -> Float, content: @Composable () -> Unit) {
    val reduce = LocalReduceMotion.current
    if ((start == null && pinned == null) || reduce) {
        content()
        return
    }
    NWOneShot(start, ApproachModel.duration + 0.4, pinned) { e ->
        val a = if (e == null) 1f else MotionCurve.smooth(MotionCurve.progress(e, ApproachModel.lands, ApproachModel.duration)).toFloat()
        Box(Modifier.graphicsLayer { alpha = a; if (pinned != null) translationY = push() }) { content() }
    }
}
