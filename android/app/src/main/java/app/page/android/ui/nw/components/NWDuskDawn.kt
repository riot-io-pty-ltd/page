package app.page.android.ui.nw.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.page.android.model.MotionCurve
import app.page.android.ui.nw.theme.Rgba

// DUSK AND DAWN, drawn (`DawnModel` for the timing): the grey horizon band that holds while agents are paused for
// battery, and the dawn's gold light rising from it when power comes back. Shared by the Horizon, Lanes and the Return
// Brief's sunrise. (iOS NWDuskDawn.swift.)

/**
 * The horizon band of a battery pause: a fine grey line with a soft glow either side, across the sky. Over the
 * near-black night it is the one thing left to see, so it is crisp and light. [opacity] 0 draws nothing. 12 dp tall;
 * the line runs through its middle, [inset] in from each side.
 */
@Composable
fun NWHorizonBand(opacity: Double, modifier: Modifier = Modifier, inset: Dp = 24.dp) {
    if (opacity <= 0.001) return
    Canvas(modifier.fillMaxWidth().height(12.dp).clearAndSetSemantics {}) {
        val x0 = inset.toPx()
        val w = size.width - 2 * x0
        if (w <= 0) return@Canvas
        val mid = size.height / 2
        val o = opacity.toFloat()
        // The glow: a soft grey haze either side of the line (a blurred capsule on iOS).
        val haze = Color(0.7f, 0.7f, 0.7f)
        val glowH = 12.dp.toPx()
        drawRect(
            Brush.verticalGradient(
                0f to haze.copy(alpha = 0f), 0.5f to haze.copy(alpha = 0.3f * o), 1f to haze.copy(alpha = 0f),
                startY = mid - glowH / 2, endY = mid + glowH / 2,
            ),
            topLeft = Offset(x0 - 4.dp.toPx(), mid - glowH / 2), size = Size(w + 8.dp.toPx(), glowH),
        )
        // The line, fading out at both ends.
        val line = Color(0.82f, 0.82f, 0.82f)
        drawRect(
            Brush.horizontalGradient(
                0f to line.copy(alpha = 0f), 0.1f to line.copy(alpha = 0.95f * o), 0.9f to line.copy(alpha = 0.95f * o), 1f to line.copy(alpha = 0f),
                startX = x0, endX = x0 + w,
            ),
            topLeft = Offset(x0, mid - 0.6.dp.toPx()), size = Size(w, 1.2.dp.toPx()),
        )
    }
}

/**
 * The dawn's light: gold rising from the horizon (the bottom of this view) to [sweep] of its height, brightest at the
 * climbing front and warm behind it; [warmth] scales it all (0 draws nothing).
 */
@Composable
fun NWDawnLight(sweep: Double, warmth: Double, modifier: Modifier = Modifier) {
    if (warmth <= 0.001 || sweep <= 0) return
    Canvas(modifier.clearAndSetSemantics {}) {
        val h = size.height
        val w = size.width
        val front = h * (1 - MotionCurve.clamp01(sweep)).toFloat()
        val gold = Rgba.hex(0xF5B14C)
        val ember = Rgba.hex(0xB0702A)
        val k = warmth
        // The lit sky behind the front: warm, brightest just behind the front, which feathers out above it (no edge
        // anywhere), settling to a low glow at the horizon.
        val feather = 70.dp.toPx()
        val top = front - feather
        val f = (feather / maxOf(1f, h - top))
        drawRect(
            Brush.verticalGradient(
                0f to gold.opacity(0.0).color,
                f to gold.opacity(0.42 * k).color,
                (f + (1 - f) * 0.55f) to ember.opacity(0.24 * k).color,
                (f + (1 - f) * 0.85f) to ember.opacity(0.12 * k).color,
                1f to ember.opacity(0.0).color,
                startY = top, endY = h,
            ),
            topLeft = Offset(0f, top), size = Size(w, h - top),
        )
        // The front itself: a soft bright edge that climbs (fading as it nears the top). A blurred ellipse on iOS;
        // here a band that is brightest at the front and feathers either side, laid on as light.
        val edge = 24.dp.toPx()
        val a = (0.55 * k * (1 - 0.6 * sweep)).coerceIn(0.0, 1.0)
        drawRect(
            Brush.verticalGradient(
                0f to gold.opacity(0.0).color, 0.5f to gold.opacity(a).color, 1f to gold.opacity(0.0).color,
                startY = front - edge, endY = front + edge,
            ),
            topLeft = Offset(0f, front - edge), size = Size(w, 2 * edge), blendMode = BlendMode.Plus,
        )
    }
}
