package app.page.android.ui.nw.components

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.page.android.ui.nw.theme.Rgba
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * A session's own star: a rounded shape seeded from a stable hash of its folder, so the same project always
 * looks the same. 3 to 5 points, each with its own reach, corners rounded like the pulse glyph. (iOS NWStarShape.)
 */
fun nwStarPath(seed: ULong, center: Offset, r: Float): Path {
    val n = 3 + (seed % 3UL).toInt()
    val rotation = ((seed shr 8) % 360UL).toDouble() * PI / 180
    val pts = ArrayList<Offset>(n)
    for (i in 0 until n) {
        val jitter = 0.80 + 0.20 * ((seed shr (16 + i * 5)) and 0x1FUL).toDouble() / 31.0
        val a = rotation + i.toDouble() / n * 2 * PI - PI / 2
        pts.add(Offset(center.x + (cos(a) * jitter).toFloat() * r, center.y + (sin(a) * jitter).toFloat() * r))
    }
    return roundedPolygon(pts, r * 0.55f)
}

/** The star as a glyph: a soft halo, the shape filled from white to the colour, a fine outline. */
@Composable
fun NWStarGlyph(seed: ULong, color: Rgba, modifier: Modifier = Modifier, size: Dp = 28.dp, brightness: Double = 1.0) {
    Box(modifier.size(size).clearAndSetSemantics {}, contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size * 1.5f)) { drawStar(seed, color, brightness, size.toPx()) }
    }
}

/** Draws the star glyph centred in this scope at diameter [s]. */
fun DrawScope.drawStar(seed: ULong, color: Rgba, brightness: Double, s: Float) {
    val c = Offset(this.size.width / 2, this.size.height / 2)
    drawCircle(Brush.radialGradient(listOf(color.opacity(0.42 * brightness).color, color.opacity(0.0).color), center = c, radius = s * 0.75f), radius = s * 0.75f, center = c)
    val shape = nwStarPath(seed, c, s * 0.7f / 2)
    drawPath(shape, Brush.radialGradient(listOf(Color.White.copy(alpha = (0.95 * brightness).toFloat()), color.opacity(0.9 * brightness).color), center = c, radius = s * 0.5f))
    drawPath(shape, color.opacity(0.9 * brightness).color, style = Stroke(1.dp.toPx()))
}
