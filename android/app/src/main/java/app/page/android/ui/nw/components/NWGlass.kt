package app.page.android.ui.nw.components

import android.graphics.RuntimeShader
import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.page.android.model.CardGlow
import app.page.android.ui.nw.theme.LocalCardGlow
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import kotlin.math.max

/** Eased gradient stops for a ramp: `alpha(t)` sampled at `steps + 1` points, so a glow rises with no visible step or band. */
fun nwRampStops(color: Rgba, steps: Int = 14, alpha: (Double) -> Double): Array<Pair<Float, Color>> =
    Array(steps + 1) { i ->
        val t = i.toDouble() / steps
        t.toFloat() to color.opacity(alpha(t).coerceIn(0.0, 1.0)).color
    }

/**
 * The glass of a Night Watch surface: a near-black fill and a hairline rim. The "Card glow" setting
 * ([LocalCardGlow]) decides whether a soft light also rises from the bottom edge. Off (the default) draws no
 * light at all: no teal tint in the fill and none in the rim. When on, the light follows the card's own rounded
 * outline (a soft inner stroke, masked so it fades smoothly upwards) and a faint wash; it never stops at a hard
 * edge and never leaves the card's corners.
 *
 * [tint] colours the surface for a state (red for Irreversible, amber for Look). That is the card's own colour,
 * not the glow, so it stays with the glow Off. Android has no backdrop blur to draw through, so the glass is a
 * translucent fill with a rim and, with the glow on, the glass light.
 */
fun Modifier.nwGlass(
    radius: Dp = NW.Radius.card,
    fill: Rgba = NW.Palette.surface.opacity(0.92),
    tint: Rgba? = null,
    rim: Boolean = true,
    glow: CardGlow = CardGlow.OFF,
): Modifier = this.drawBehind {
    val r = radius.toPx()
    val base = if (tint != null) fill.mixed(tint.opacity(1.0), 0.13) else fill
    drawRoundRect(base.color, cornerRadius = CornerRadius(r))
    if (glow.isOn) drawCardGlowLight(r, glow)
    if (rim) {
        val hair = 1.dp.toPx()
        drawRoundRect(
            Brush.verticalGradient(listOf(Color.White.copy(alpha = 0.13f), Color.White.copy(alpha = 0.05f))),
            topLeft = Offset(hair / 2, hair / 2), size = androidx.compose.ui.geometry.Size(size.width - hair, size.height - hair),
            cornerRadius = CornerRadius(r - hair / 2), style = Stroke(hair),
        )
        if (tint != null) {
            drawRoundRect(
                tint.opacity(0.32).color, topLeft = Offset(hair / 2, hair / 2), size = androidx.compose.ui.geometry.Size(size.width - hair, size.height - hair),
                cornerRadius = CornerRadius(r - hair / 2), style = Stroke(hair),
            )
        }
        if (glow.isOn) drawCardGlowRim(r, glow)
    }
}

/**
 * The inner light: a wide, soft wash plus a stroke that hugs the rounded outline, both masked with an eased
 * bottom-weighted ramp. Drawn inside the shape (clipped to it), so it follows the corners.
 */
private fun DrawScope.drawCardGlowLight(radius: Float, glow: CardGlow) {
    val tint = NW.Palette.glass
    val w = size.width
    val h = size.height
    val outline = Path().apply { addRoundRect(androidx.compose.ui.geometry.RoundRect(0f, 0f, w, h, CornerRadius(radius))) }
    clipPath(outline) {
        // Wash: an ellipse centred on the bottom edge; alpha is strongest there and fades to nothing outwards.
        val ky = max(0.2f, h / max(1f, w))
        val wash = Array(15) { i -> (i / 14f) to tint.opacity(glow.lightAlpha(1 - i / 14.0) * 0.5).color }
        scale(1f, ky, pivot = Offset(w / 2, h)) {
            drawCircle(Brush.radialGradient(*wash, center = Offset(w / 2, h), radius = w * 0.85f), radius = w * 0.85f, center = Offset(w / 2, h))
        }
        // Edge light: the outline, softened inwards, rising with the ramp.
        val reach = glow.reach
        val mask = Brush.verticalGradient(
            *Array(15) { i ->
                val t = i / 14f
                t to tint.opacity((glow.lightAlpha((t - (1 - reach)) / reach) * 1.4).coerceIn(0.0, 1.0)).color
            },
        )
        val outlinePath = outline
        for ((widthK, alphaK) in listOf(10f to 0.25f, 5f to 0.45f, 2.5f to 0.8f)) {
            drawPath(outlinePath, mask, alpha = alphaK, style = Stroke(widthK.dp.toPx()))
        }
    }
}

/** The rim's glow: the outline warms towards the bottom along an eased ramp (zero over the top half). */
private fun DrawScope.drawCardGlowRim(radius: Float, glow: CardGlow) {
    val hair = 1.dp.toPx()
    val tint = NW.Palette.glass
    val stops = Array(15) { i -> (i / 14f) to tint.opacity(glow.rimAlpha(i / 14.0)).color }
    drawRoundRect(
        Brush.verticalGradient(*stops), topLeft = Offset(hair / 2, hair / 2),
        size = androidx.compose.ui.geometry.Size(size.width - hair, size.height - hair), cornerRadius = CornerRadius(radius - hair / 2), style = Stroke(hair),
    )
}

/**
 * glass.glsl's edge light over a glass surface: the rim catches a light from the top-left with a sheen along it
 * and a fine inner highlight. It is a light, so it follows the Card glow setting (Off draws nothing) and it is
 * still: the sheen is set by [sheen], not a clock, so glass costs nothing per frame. API 33+ (AGSL).
 */
@Composable
fun NWGlassEdgeLight(radius: Dp, modifier: Modifier = Modifier, sheen: Double = 0.6) {
    val glow = LocalCardGlow.current
    if (!(NWShaders.available && Build.VERSION.SDK_INT >= 33) || !glow.isOn) return
    val shader = remember { RuntimeShader(NWShaders.GLASS_RIM) }
    Canvas(modifier) {
        shader.setFloatUniform("size", size.width, size.height)
        shader.setFloatUniform("radius", radius.toPx())
        shader.setFloatUniform("sheen", sheen.toFloat())
        shader.setFloatUniform("px", density)
        NWShaders.setColor(shader, "edgeLight", Rgba.hex(0x9FF5E8))
        shader.setFloatUniform("strength", (0.55 * glow.strength).toFloat())
        drawRect(ShaderBrush(shader))
    }
}

/** A glass card around its content. */
@Composable
fun NWGlassCard(
    modifier: Modifier = Modifier,
    radius: Dp = NW.Radius.card,
    padding: PaddingValues = PaddingValues(NW.Space.lg),
    tint: Rgba? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val glow = LocalCardGlow.current
    Box(modifier.fillMaxWidth().nwGlass(radius, tint = tint, glow = glow)) {
        Column(Modifier.fillMaxWidth().padding(padding), content = content)
        NWGlassEdgeLight(radius, Modifier.matchParentSize())
    }
}
