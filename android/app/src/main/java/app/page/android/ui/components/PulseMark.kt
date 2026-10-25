package app.page.android.ui.components

import android.provider.Settings
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.page.android.ui.theme.colors

/**
 * The brand mark (iOS Design/PulseMark.swift): a glowing dot with two
 * concentric asymmetric rings that ripple outward while [pulsing]. Still when
 * the system's "Remove animations" is on. Purely decorative: hidden from
 * TalkBack; callers convey state in text.
 */
@Composable
fun PulseMark(size: Dp = 64.dp, pulsing: Boolean = true, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val reduceMotion = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val animate = pulsing && !reduceMotion
    val c = colors
    val phase = if (animate) {
        val transition = rememberInfiniteTransition(label = "pulse")
        val p by transition.animateFloat(
            initialValue = 0f, targetValue = 1f,
            animationSpec = infiniteRepeatable(tween(2400, easing = LinearEasing), RepeatMode.Restart),
            label = "phase",
        )
        p
    } else {
        0f
    }
    Canvas(modifier.size(size).clearAndSetSemantics { }) {
        val middle = (phase + 0.35f) % 1f
        val gradient = Brush.linearGradient(listOf(c.pulseStart, c.pulseEnd), Offset.Zero, Offset(this.size.width, this.size.height))
        // Outer ring (fades + scales), then the middle ring at an offset phase.
        ring(gradient, 0.6f + phase * 0.5f, maxOf(0f, (1f - phase) * if (animate) 0.5f else 0.18f), if (animate) 1.5f else 1f)
        ring(gradient, 0.5f + middle * 0.45f, maxOf(0f, (1f - middle) * if (animate) 0.6f else 0.22f), if (animate) 2f else 1f)
        val r = this.size.minDimension / 2
        // Inner halo (soft glow).
        drawCircle(
            Brush.radialGradient(listOf(c.pulseStart.copy(alpha = 0.55f), c.pulseEnd.copy(alpha = 0f)), center, r * 0.45f),
            radius = r * 0.45f,
        )
        // Solid dot.
        drawCircle(gradient, radius = r * 0.32f)
        drawCircle(Color.White.copy(alpha = 0.18f), radius = r * 0.32f, style = Stroke(width = 0.5.dp.toPx()))
    }
}

private fun DrawScope.ring(brush: Brush, scale: Float, alpha: Float, thickness: Float) {
    val r = size.minDimension / 2 * scale
    drawCircle(brush, radius = r, alpha = alpha, style = Stroke(width = thickness.dp.toPx()))
}
