package app.page.android.ui.components

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.UsageGauge
import app.page.android.ui.theme.PageColors
import app.page.android.ui.theme.colors

/** Calm, warm, hot: success, warning, destructive (the text-safe red, as on iOS). */
fun PageColors.usage(tone: UsageGauge.Tone): Color = when (tone) {
    UsageGauge.Tone.CALM -> success
    UsageGauge.Tone.WARM -> warning
    UsageGauge.Tone.HOT -> destructiveText
}

/**
 * One usage window as a ring (iOS Design/UsageRing.swift): a gradient arc for
 * how much is used, a faint track, and a small tick where usage would be at
 * an even pace through the window. The arc animates when the value changes.
 * Decorative to accessibility; the caller describes it.
 */
@Composable
fun UsageRing(
    gauge: UsageGauge,
    modifier: Modifier = Modifier,
    lineWidth: Dp = 10.dp,
    showsValue: Boolean = true,
    valueStyle: TextStyle = TextStyle(fontSize = 26.sp, fontWeight = FontWeight.Bold),
) {
    val tint = colors.usage(gauge.tone)
    val track = colors.hairline.copy(alpha = 0.9f)
    val tickColor = colors.text.copy(alpha = 0.75f)
    val fraction by animateFloatAsState(
        targetValue = gauge.fraction.toFloat(),
        animationSpec = spring(dampingRatio = 0.85f, stiffness = 60f),
        label = "usage",
    )
    val elapsed = gauge.elapsed?.toFloat()
    Box(modifier, contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val lw = lineWidth.toPx()
            val diameter = size.minDimension - lw
            val topLeft = Offset((size.width - diameter) / 2, (size.height - diameter) / 2)
            val arcSize = Size(diameter, diameter)
            // Faint track.
            drawCircle(track, radius = diameter / 2, style = Stroke(lw))
            rotate(-90f) {
                val sweep = 360f * maxOf(0.005f, fraction)
                // Soft glow: a wider, faint stroke behind the arc.
                drawArc(
                    tint.copy(alpha = 0.16f), 0f, sweep, useCenter = false, topLeft = topLeft, size = arcSize,
                    style = Stroke(lw * 1.9f, cap = StrokeCap.Round),
                )
                drawArc(
                    tint.copy(alpha = 0.12f), 0f, sweep, useCenter = false, topLeft = topLeft, size = arcSize,
                    style = Stroke(lw * 1.4f, cap = StrokeCap.Round),
                )
                // The arc: 45% of the tint at 12 o'clock to full tint at its end.
                // The last stop fades back so the start cap (just before 360°)
                // stays at 45% too.
                val end = maxOf(0.05f, fraction).coerceAtMost(0.999f)
                val brush = Brush.sweepGradient(
                    0f to tint.copy(alpha = 0.45f),
                    end to tint,
                    1f to tint.copy(alpha = 0.45f),
                    center = center,
                )
                drawArc(brush, 0f, sweep, useCenter = false, topLeft = topLeft, size = arcSize, style = Stroke(lw, cap = StrokeCap.Round))
            }
            if (elapsed != null) evenPaceTick(elapsed, diameter / 2, lw, tickColor)
        }
        if (showsValue) {
            Row(verticalAlignment = Alignment.Bottom) {
                Text(gauge.percentText, style = valueStyle, color = colors.text, modifier = Modifier.alignByBaseline())
                Text("%", style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold), color = colors.text, modifier = Modifier.alignByBaseline())
            }
        }
    }
}

/** A short radial capsule on the track at [fraction] of a turn from 12 o'clock. */
private fun DrawScope.evenPaceTick(fraction: Float, radius: Float, lineWidth: Float, color: Color) {
    val width = maxOf(2.dp.toPx(), lineWidth / 4)
    val length = lineWidth * 1.5f
    rotate(360f * fraction) {
        drawLine(
            color,
            start = Offset(center.x, center.y - radius - length / 2 + width / 2),
            end = Offset(center.x, center.y - radius + length / 2 - width / 2),
            strokeWidth = width,
            cap = StrokeCap.Round,
        )
    }
}
