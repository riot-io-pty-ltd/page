package app.page.android.ui.nw.components

import android.graphics.RuntimeShader
import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.MotionCurve
import app.page.android.model.NowModel
import app.page.android.model.PulseModel
import app.page.android.ui.nw.theme.AuroraPalette
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.tan

/** `fract(abs(sin(x) * k))`, the Canvas drawings' stable pseudo-random numbers (the same as iOS's). */
private fun hash01(x: Double, k: Double): Double {
    val v = abs(sin(x) * k)
    return v - floor(v)
}

/**
 * The aurora itself, drawn without shaders: a sky gradient, soft ribbons that drift, upward rays and a scatter
 * of stars (iOS `NWAuroraCanvas`). [seconds] moves it; the palette's `intensity` scales it (0 draws only the
 * sky, as at dusk). On Android 12 and later the ribbons and rays are blurred as on iOS (a [BlurEffect] on their own
 * layers); below that, where no blur exists, each ribbon is laid down in many fine, faint strokes whose sum is a
 * soft ramp, so no contour step shows.
 */
@Composable
fun NWAuroraCanvas(palette: AuroraPalette, seconds: Double, modifier: Modifier = Modifier.fillMaxSize(), starField: Double = 1.0) {
    val blur = Build.VERSION.SDK_INT >= 31 && !NWShaders.forceNoBlur
    val density = LocalDensity.current.density
    Box(modifier) {
        Canvas(Modifier.matchParentSize()) { drawRect(Brush.verticalGradient(listOf(palette.skyTop.color, palette.skyBottom.color))) }
        if (palette.intensity > 0) {
            val t = seconds * 0.4 * palette.speed
            Canvas(Modifier.matchParentSize().then(if (blur) Modifier.graphicsLayer { renderEffect = BlurEffect(16 * density, 16 * density, TileMode.Decal) } else Modifier)) {
                drawRibbons(palette, t, soft = !blur)
            }
            Canvas(Modifier.matchParentSize().then(if (blur) Modifier.graphicsLayer { renderEffect = BlurEffect(3 * density, 3 * density, TileMode.Decal) } else Modifier)) {
                drawRays(palette, t, soft = !blur)
            }
        }
        Canvas(Modifier.matchParentSize()) {
            drawStars(seconds, size.width, size.height, (if (palette.intensity > 0) 0.4 + 0.6 * palette.intensity else 0.3) * starField)
        }
    }
}

/** The ribbons: soft wavy bands across the header (index, vertical centre, line width as a share of the height, alpha). */
private fun DrawScope.drawRibbons(palette: AuroraPalette, t: Double, soft: Boolean) {
    val w = size.width
    val h = size.height
    val k = palette.intensity
    val bands = listOf(
        doubleArrayOf(0.0, 0.56, 0.22, 0.95), doubleArrayOf(1.0, 0.44, 0.15, 0.55), doubleArrayOf(2.0, 0.66, 0.17, 0.45),
    )
    val colors = listOf(palette.c1, palette.c2, palette.c3)
    for (b in bands) {
        val n = b[0].toInt()
        val path = Path()
        var x = -30f
        var first = true
        while (x <= w + 30) {
            val u = (x / w).toDouble()
            val slow = 0.07 * sin(u * 5.2 + t + n * 1.7)
            val fast = 0.04 * sin(u * 11 - t * 1.3 + n)
            val y = (h * (b[1] + slow + fast)).toFloat()
            if (first) { path.moveTo(x, y); first = false } else path.lineTo(x, y)
            x += 6f
        }
        val alpha = b[3] * k * 0.8
        val width = (h * b[2]).toFloat()
        if (!soft) {
            // The layer's blur softens it, as iOS's filter does.
            drawPath(path, colors[n].opacity(alpha.coerceIn(0.0, 1.0)).color, style = Stroke(width = width, cap = StrokeCap.Round), blendMode = BlendMode.Plus)
        } else {
            // No blur: many concentric strokes, each a little narrower, adding up to a ramp from the edge to the middle.
            val steps = 14
            for (i in 0 until steps) {
                val f = 1.25f - 1.15f * i / (steps - 1)
                drawPath(
                    path, colors[n].opacity((alpha * 0.9 / steps).coerceIn(0.0, 1.0)).color,
                    style = Stroke(width = width * f, cap = StrokeCap.Round), blendMode = BlendMode.Plus,
                )
            }
        }
    }
}

/** The rays: streaks of varied width and reach rising from the main ribbon. */
private fun DrawScope.drawRays(palette: AuroraPalette, t: Double, soft: Boolean) {
    val w = size.width
    val h = size.height
    val k = palette.intensity
    val colors = listOf(palette.c1, palette.c2)
    for (i in 0 until 34) {
        val seed = hash01(i * 12.9898, 43758.5453)
        val seed2 = hash01(i * 78.233 + 1.3, 24634.6345)
        val u = (i + seed * 0.8) / 34
        val x = (w * u).toFloat()
        val wobble = 0.7 + 0.3 * sin(i * 1.9 + t * 1.4)
        val reach = (h * (0.16 + 0.34 * seed2 * wobble)).toFloat()
        val yMid = (h * (0.58 + 0.07 * sin(u * 5.2 + t))).toFloat()
        val width = (1.4 + 3.0 * seed).dp.toPx()
        val c = colors[i % 2]
        val a = ((0.30 + 0.40 * seed2) * k).coerceIn(0.0, 1.0)
        // Without a blur, a faint wider pass under each streak keeps its edge soft.
        val passes = if (soft) listOf(width * 2.4f to a * 0.3, width to a * 0.55) else listOf(width to a)
        for ((pw, pa) in passes) {
            drawRoundRect(
                Brush.verticalGradient(listOf(c.opacity(0.0).color, c.opacity(pa).color), startY = yMid - reach, endY = yMid),
                topLeft = Offset(x - (pw - width) / 2, yMid - reach), size = Size(pw, reach), cornerRadius = androidx.compose.ui.geometry.CornerRadius(pw / 2), blendMode = BlendMode.Plus,
            )
        }
    }
}

private fun DrawScope.drawStars(seconds: Double, w: Float, h: Float, strength: Double) {
    if (strength <= 0.005) return
    for (i in 0 until 40) {
        val sx = hash01(i * 78.233, 43758.5453)
        val sy = hash01(i * 12.9898 + 4.1, 24634.6345)
        val twinkle = 0.5 + 0.5 * sin(seconds * 0.8 + i)
        val r = (if (i % 7 == 0) 1.2 else 0.7).dp.toPx()
        drawCircle(Color.White.copy(alpha = ((0.25 + 0.4 * twinkle) * strength).toFloat().coerceIn(0f, 1f)), radius = r, center = Offset((w * sx).toFloat(), (h * sy * 0.85).toFloat()))
    }
}

/**
 * The aurora: the AGSL port of aurora.glsl when the device has it (API 33+), the Canvas ribbons when not.
 * [stars] dims the aurora's own scatter of stars (the dusk). Redrawn by its caller's clock ([NWAnimated]).
 */
@Composable
fun NWLivingAurora(palette: AuroraPalette, seconds: Double, modifier: Modifier = Modifier.fillMaxSize(), stars: Double = 1.0) {
    if (NWShaders.available && Build.VERSION.SDK_INT >= 33) {
        val shader = remember { RuntimeShader(NWShaders.AURORA) }
        val density = LocalDensity.current.density
        Canvas(modifier) {
            shader.setFloatUniform("size", size.width, size.height)
            shader.setFloatUniform("time", seconds.toFloat())
            // The boards' u_speed is 0.4 at a palette speed of 1.
            shader.setFloatUniform("speed", (0.4 * palette.speed).toFloat())
            shader.setFloatUniform("starCell", 1.5f * density)
            NWShaders.setColor(shader, "skyTop", palette.skyTop)
            NWShaders.setColor(shader, "skyBottom", palette.skyBottom)
            NWShaders.setColor(shader, "c1", palette.c1)
            NWShaders.setColor(shader, "c2", palette.c2)
            NWShaders.setColor(shader, "c3", palette.c3)
            // The GLSL's 0.9 intensity was drawn for a whole board; behind a phone's Horizon it drowns the pulse, so it runs at two thirds of that.
            shader.setFloatUniform("intensity", (0.6 * palette.intensity).toFloat())
            shader.setFloatUniform("stars", stars.toFloat())
            drawRect(ShaderBrush(shader))
        }
    } else {
        NWAuroraCanvas(palette, seconds, modifier, stars)
    }
}

/** The page background: the night sky's darkness with a whisper of violet at the top. There is deliberately no light at the bottom: any glow comes from the Card glow setting, on the cards themselves. */
@Composable
fun NWBackdrop(modifier: Modifier = Modifier.fillMaxSize()) {
    Canvas(modifier) {
        drawRect(NW.Palette.backgroundDeep.color)
        drawRect(
            Brush.radialGradient(
                listOf(NW.Palette.violet.opacity(0.07).color, Color.Transparent),
                center = Offset(size.width, 0f), radius = 520f * density,
            ),
        )
    }
}

// MARK: - rounded polygons (the pulse glyph and the stars)

/**
 * A polygon with rounded corners: each corner is a circular arc of [radius] (a cubic Bézier, as close to the arc as the
 * eye can tell) meeting its two edges, the way iOS's `addArc(tangent1End:tangent2End:radius:)` draws it. A quadratic
 * through the corner would leave each corner a third pointier than the boards'.
 */
fun roundedPolygon(points: List<Offset>, radius: Float): Path {
    val n = points.size
    val path = Path()
    val starts = ArrayList<Offset>(n)
    val ends = ArrayList<Offset>(n)
    val handles = ArrayList<Float>(n)
    val inDirs = ArrayList<Offset>(n)
    val outDirs = ArrayList<Offset>(n)
    for (i in 0 until n) {
        val p = points[i]
        val a = points[(i + n - 1) % n]
        val b = points[(i + 1) % n]
        val d1 = Offset(a.x - p.x, a.y - p.y)
        val d2 = Offset(b.x - p.x, b.y - p.y)
        val l1 = hypot(d1.x, d1.y)
        val l2 = hypot(d2.x, d2.y)
        val u1 = Offset(d1.x / l1, d1.y / l1)
        val u2 = Offset(d2.x / l2, d2.y / l2)
        val angle = acos((u1.x * u2.x + u1.y * u2.y).coerceIn(-1f, 1f))
        val half = tan(angle / 2f).coerceAtLeast(0.05f)
        val t = min(radius / half, min(l1, l2) * 0.5f)
        // The arc that fits this tangent length (the radius, unless the edges are too short for it), and the cubic
        // handle length for its turn: 4/3 · tan(turn / 4) · r.
        val r = t * half
        val turn = (Math.PI - angle).toFloat()
        handles.add((4.0 / 3.0 * tan(turn / 4.0) * r).toFloat())
        starts.add(Offset(p.x + u1.x * t, p.y + u1.y * t))
        ends.add(Offset(p.x + u2.x * t, p.y + u2.y * t))
        inDirs.add(Offset(-u1.x, -u1.y))
        outDirs.add(Offset(-u2.x, -u2.y))
    }
    path.moveTo(ends[n - 1].x, ends[n - 1].y)
    for (i in 0 until n) {
        val s0 = starts[i]
        val e0 = ends[i]
        val h = handles[i]
        path.lineTo(s0.x, s0.y)
        path.cubicTo(s0.x + inDirs[i].x * h, s0.y + inDirs[i].y * h, e0.x + outDirs[i].x * h, e0.y + outDirs[i].y * h, e0.x, e0.y)
    }
    path.close()
    return path
}

/** The rounded-triangle glyph at the heart of the pulse, in a box of [w] x [h] at [origin]. */
fun pulseGlyphPath(origin: Offset, w: Float, h: Float): Path {
    val top = Offset(origin.x + w * 0.5f, origin.y + h * 0.06f)
    val right = Offset(origin.x + w * 0.95f, origin.y + h * 0.86f)
    val left = Offset(origin.x + w * 0.05f, origin.y + h * 0.86f)
    return roundedPolygon(listOf(top, right, left), min(w, h) * 0.26f)
}

// MARK: - the pulse

/** Star-white quiet, teal working, amber waiting, a violet dusk. */
val PulseModel.Mode.tone: Rgba
    get() = when (this) {
        PulseModel.Mode.QUIET -> NW.Palette.star
        PulseModel.Mode.WORKING -> NW.Palette.teal
        PulseModel.Mode.WAITING -> NW.Palette.amber
        PulseModel.Mode.DUSK -> NW.Palette.violet
    }

/**
 * THE PULSE: one glyph for everything ([PulseModel] for the timing). Still star-white when quiet; a teal breath
 * every 4 s while agents work, a little quicker with more of them; an amber ripple when something needs you, one
 * ring per waiting item, faster the longer the oldest has waited (never more than one ring every 1.5 s); a dim
 * low glow at dusk. After the last item clears, `exhale` (seconds since) turns it amber to teal over 800 ms with
 * one long breath out. Reduce Motion: a static ring with the count.
 *
 * A still pulse runs no clock; a breath redraws at 20 fps, a ripple at 30. [halo] false leaves the glow and
 * rings to a layer drawn behind it (the Horizon's shader pulse), so the two never double up.
 */
object NWPulseStyle {
    enum class Style {
        NEEDS_YOU, WORKING, QUIET, DUSK,

        /** A problem: the pulse goes hollow. Slate when the Mac is simply not there, amber when something needs fixing. */
        HOLLOW_SLATE, HOLLOW_AMBER;

        /** The pulse a style stands for when no counts are given (widgets, the gallery): two waiting, one working. */
        val defaultModel: PulseModel
            get() = when (this) {
                NEEDS_YOU -> PulseModel(0, 2)
                WORKING -> PulseModel(1, 0)
                QUIET, HOLLOW_SLATE, HOLLOW_AMBER -> PulseModel(0, 0)
                DUSK -> PulseModel(0, 0, paused = true)
            }

        companion object {
            fun of(mood: NowModel.Mood): Style = when (mood) {
                NowModel.Mood.NEEDS_YOU -> NEEDS_YOU
                NowModel.Mood.WORKING -> WORKING
                NowModel.Mood.QUIET -> QUIET
                NowModel.Mood.DUSK -> DUSK
            }
        }
    }

    /** The colour now: the mode's, or part-way from amber during the exhale. */
    fun color(style: Style, pulse: PulseModel, exhale: Double?): Rgba = when (style) {
        Style.HOLLOW_SLATE -> Rgba.hex(0x8A93A8)
        Style.HOLLOW_AMBER -> NW.Palette.amber
        else -> {
            val base = pulse.mode.tone
            if (exhale == null) base else NW.Palette.amber.mixedPerceptual(base, PulseModel.exhale(exhale).colour)
        }
    }
}

@Composable
fun NWPulseOrb(
    style: NWPulseStyle.Style, modifier: Modifier = Modifier, model: PulseModel? = null, exhale: Double? = null,
    halo: Boolean = true, time: Double? = null,
) {
    val pulse = model ?: style.defaultModel
    val hollow = style == NWPulseStyle.Style.HOLLOW_SLATE || style == NWPulseStyle.Style.HOLLOW_AMBER
    val exhaling = exhale?.let { !PulseModel.exhale(it).finished } ?: false
    if (time != null) {
        OrbFrame(style, pulse, hollow, exhale, halo, time, modifier)
    } else {
        NWAnimated(fps = if (exhaling) 30.0 else pulse.framesPerSecond, active = !hollow && (pulse.isAnimated || exhaling)) { t ->
            OrbFrame(style, pulse, hollow, exhale, halo, t, modifier)
        }
    }
}

@Composable
private fun OrbFrame(style: NWPulseStyle.Style, pulse: PulseModel, hollow: Boolean, exhale: Double?, halo: Boolean, t: Double, modifier: Modifier) {
    val reduceMotion = LocalReduceMotion.current
    val color = NWPulseStyle.color(style, pulse, exhale)
    val mode = if (hollow) PulseModel.Mode.QUIET else pulse.mode
    val dusk = mode == PulseModel.Mode.DUSK
    val quiet = mode == PulseModel.Mode.QUIET && !hollow
    val breath = pulse.breath(t)
    val swell = exhale?.let { PulseModel.exhale(it).swell } ?: 0.0
    val count = if (reduceMotion) pulse.staticCount else null
    // Reduce Motion keeps the ring and drops the ripples.
    val ripples = if (reduceMotion || hollow) emptyList() else pulse.ripples(t)
    Box(modifier, contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize()) {
            val s = min(size.width, size.height)
            val c = Offset(size.width / 2, size.height / 2)
            val lw = 1.2.dp.toPx()
            if (halo) {
                // Ripples: thin rings that open from the core ring outwards and fade.
                for (r in ripples) {
                    drawCircle(color.opacity(0.62 * r.opacity).color, radius = s / 2 * (0.5f + 0.5f * r.progress.toFloat()), center = c, style = Stroke(lw))
                }
                // The exhale lets one last ring go as it turns.
                if (exhale != null && swell > 0) {
                    val p = MotionCurve.clamp01(exhale / PulseModel.exhaleDuration)
                    drawCircle(color.opacity(0.45 * (1 - p)).color, radius = s / 2 * (0.5f + 0.5f * MotionCurve.easeOut(p).toFloat()), center = c, style = Stroke(lw))
                }
                // Glow.
                val glowAlpha = if (hollow) 0.07 else (if (dusk) 0.16 else (if (quiet) 0.30 else 0.45))
                val glowScale = 1f + (0.10 * (breath - 0.5) * 2 * (if (mode == PulseModel.Mode.WORKING) 1 else 0) + 0.30 * swell).toFloat()
                scale(glowScale, c) {
                    drawCircle(
                        Brush.radialGradient(listOf(color.opacity(glowAlpha).color, color.opacity(0.0).color), center = c, radius = s * 0.42f),
                        radius = s / 2, center = c,
                    )
                }
            }
            // The ring (none when quiet: still white is just the light).
            val ringScale = 1f + ((if (mode == PulseModel.Mode.WORKING) 0.04 * (breath - 0.5) * 2 else 0.0) + 0.06 * swell).toFloat()
            drawCircle(
                color.opacity(if (dusk) 0.35 else (if (quiet) 0.0 else 0.85)).color, radius = s * 0.25f * ringScale, center = c,
                style = Stroke(1.6.dp.toPx()),
            )
            if (count == null) {
                val g = s * 0.26f * (1f + (if (mode == PulseModel.Mode.WORKING) 0.03 * (breath - 0.5) * 2 else 0.0).toFloat())
                val path = pulseGlyphPath(Offset(c.x - g / 2, c.y - g / 2), g, g)
                if (!hollow) {
                    drawPath(
                        path,
                        Brush.radialGradient(
                            listOf(Color.White.copy(alpha = if (dusk) 0.4f else 1f), color.opacity(if (dusk) 0.3 else 0.92).color),
                            center = c, radius = s * 0.15f,
                        ),
                        style = Fill,
                    )
                }
                drawPath(path, color.opacity(if (dusk) 0.3 else (if (hollow) 0.8 else 0.9)).color, style = Stroke((if (hollow) 2.0 else 1.4).dp.toPx()))
            }
        }
        if (count != null) {
            val s = 1f
            Text(
                "$count", color = color.color, fontWeight = FontWeight.Bold,
                fontSize = (24 * s).sp, // scales with the orb's own size via the box
            )
        }
    }
}

/**
 * The pulse's light: the AGSL port of pulse.glsl (core, halo and the rings, a little wobbly) behind the glyph,
 * the rings placed from [PulseModel.ripples] so they match the Canvas version exactly. Draws nothing when the
 * shaders are not here: the orb then draws its own halo.
 */
@Composable
fun NWPulseLight(color: Rgba, ripples: List<PulseModel.Ripple>, glow: Double, seconds: Double, modifier: Modifier = Modifier) {
    if (!(NWShaders.available && Build.VERSION.SDK_INT >= 33)) return
    val shader = remember { RuntimeShader(NWShaders.PULSE) }
    Canvas(modifier) {
        val r = ripples.map { it.progress.toFloat() } + List(maxOf(0, 4 - ripples.size)) { -1f }
        shader.setFloatUniform("size", size.width, size.height)
        shader.setFloatUniform("time", seconds.toFloat())
        NWShaders.setColor(shader, "core", color.mixed(Rgba(1.0, 1.0, 1.0), 0.25))
        NWShaders.setColor(shader, "edge", color)
        shader.setFloatUniform("coreSize", 0.09f)
        shader.setFloatUniform("glow", glow.toFloat())
        shader.setFloatUniform("rings", r[0], r[1], r[2], r[3])
        shader.setFloatUniform("ringAlpha", 1.0f)
        drawRect(ShaderBrush(shader))
    }
}
