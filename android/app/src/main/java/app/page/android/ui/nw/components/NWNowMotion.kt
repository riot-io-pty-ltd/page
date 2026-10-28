package app.page.android.ui.nw.components

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.layout.layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.dp
import app.page.android.model.NowMotion
import app.page.android.model.OneShotBook
import app.page.android.ui.nw.theme.LocalFixedPhase
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.LocalNowScript
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.pinned
import kotlin.math.hypot
import kotlin.math.max

// The rest of Now in motion ([NowMotion]): the plumbing its moving parts share (a value's one change, when a thing was
// first shown, a clock that runs only while something plays) and what more than one of them draws (words whose count
// rolls, a check that draws itself). Every part reads its clock in draw, layer and layout lambdas, so a tick redraws
// without recomposing. (iOS NWNowMotion.swift.)

/**
 * [value] and the one change it is playing ([NowMotion.Change]), noticed as it happens on the [nwClockSeconds] base; a
 * first look is never a change. Under the render harness it is [pick] of the script ([LocalNowScript]) folded up to the
 * pinned moment instead, Now appearing at 0; any other pinned frame draws it still.
 */
@Composable
fun <T> rememberNowChange(value: T, pick: ((NowMotion.Look) -> T)? = null): NowMotion.Change<T> {
    if (LocalFixedPhase.current != null) {
        val at = LocalMotionPin.current.pinned(NWMotionPin.Kind.NOW)
        val script = LocalNowScript.current
        return remember(value, script, at) {
            if (at == null || script == null || pick == null) NowMotion.Change(value)
            // The script and the stores are built from the same fixtures; were they ever to disagree, nothing plays.
            else NowMotion.replay(script.map { it.first to pick(it.second) }, at)?.takeIf { it.value == value } ?: NowMotion.Change(value)
        }
    }
    val held = remember { ChangeHolder<T>() }
    val next = held.change?.observe(value, nwClockSeconds()) ?: NowMotion.Change(value)
    held.change = next
    return next
}

/** A plain field, not state: a change is noticed and stamped in the same composition that draws its first frame. */
private class ChangeHolder<T> {
    var change: NowMotion.Change<T>? = null
}

/**
 * When [key] was first shown this process, on the clock its motion runs on: [book]'s first look at it, on the
 * [nwClockSeconds] base. Under the render harness, 0 when Now's motion is pinned (Now appearing at 0) and long ago on any
 * other pinned frame, so an ordinary screenshot draws everything arrived.
 */
@Composable
fun rememberNowShown(book: OneShotBook, key: String): Double {
    if (LocalFixedPhase.current != null) return if (LocalMotionPin.current.pinned(NWMotionPin.Kind.NOW) != null) 0.0 else -100.0
    return remember(key) { book.start(key, nwClockSeconds()) }
}

/**
 * One clock for a part of Now whose motion comes and goes: ticking at [fps] while [until] is ahead (or always, while
 * [loops]), none otherwise; held in the background and under a sheet, pinned by the harness ([rememberNWMotionClock]).
 */
@Composable
fun rememberNowClock(until: Double?, fps: Double = 30.0, loops: Boolean = false): State<Double> =
    rememberNWMotionClock(listOf(until, loops, fps), fps) { now -> loops || (until != null && now < until) }

/**
 * Words that change in motion ([NowMotion.wordsChange]): when only numbers moved each rolls in place (the old number up
 * and out, the new one up from below, as the lens's centre number does), drawn over the new words' own layout so
 * nothing around it shifts; a change of wording cross-fades as the new words rise 4 dp ([NowMotion.reword]). Reduce Motion: a 0.2 s
 * cross-fade. The semantics are always the new words'; the old ones are only drawn. Recomposes when a change starts and
 * ends, never per frame.
 */
@Composable
fun NWRollingWords(
    text: AnnotatedString,
    change: NowMotion.Change<String>,
    clock: State<Double>,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    textAlign: TextAlign = TextAlign.Center,
    maxLines: Int = 2,
) {
    val reduce = LocalReduceMotion.current
    val at = change.at
    val kind = remember(change) { change.from?.let { NowMotion.wordsChange(it, change.value) } }
    val playing by remember(change, reduce) { derivedStateOf { at != null && kind != null && clock.value - at < NowMotion.wordsLast(reduce) } }
    if (!playing || at == null || kind == null || change.value != text.text) {
        Text(text, modifier, color = color, style = style, textAlign = textAlign, maxLines = maxLines, overflow = TextOverflow.Ellipsis)
        return
    }
    val measurer = rememberTextMeasurer()
    if (kind is NowMotion.WordsChange.Roll && !reduce) {
        val layout = remember { mutableStateOf<TextLayoutResult?>(null) }
        // The new words with their moved numbers hidden, so they keep their own layout; each number rolls in its place.
        val hidden = remember(text, kind) {
            AnnotatedString.Builder(text).apply { for (r in kind.runs) if (r.end <= text.length) addStyle(SpanStyle(color = Color.Transparent), r.start, r.end) }.toAnnotatedString()
        }
        val styles = remember(text, kind, style, color) {
            kind.runs.map { r ->
                val span = text.spanStyles.lastOrNull { it.start <= r.start && it.end > r.start }?.item
                (if (span != null) style.merge(span) else style).copy(color = span?.color?.takeIf { it.isSpecified } ?: color, textAlign = TextAlign.Start)
            }
        }
        Text(
            hidden,
            modifier.drawWithContent {
                drawContent()
                val l = layout.value ?: return@drawWithContent
                val k = NowMotion.wordsProgress(clock.value - at).toFloat()
                for ((i, r) in kind.runs.withIndex()) {
                    if (r.end > l.layoutInput.text.length) continue
                    val line = l.getLineForOffset(r.start)
                    val top = l.getLineTop(line)
                    val bottom = l.getLineBottom(line)
                    val base = l.getLineBaseline(line)
                    val x = l.getHorizontalPosition(r.start, usePrimaryDirection = true)
                    val h = bottom - top
                    clipRect(0f, top, size.width, bottom) {
                        val old = measurer.measure(r.from, styles[i])
                        val new = measurer.measure(r.to, styles[i])
                        drawText(old, topLeft = Offset(x, base - old.firstBaseline - h * k), alpha = 1 - k)
                        drawText(new, topLeft = Offset(x, base - new.firstBaseline + h * (1 - k)), alpha = k)
                    }
                }
            },
            color = color, style = style, textAlign = textAlign, maxLines = maxLines, overflow = TextOverflow.Ellipsis,
            onTextLayout = { layout.value = it },
        )
        return
    }
    // A change of wording, or any change under Reduce Motion: the old words rise out as they fade behind the new.
    val from = change.from ?: ""
    val unit = with(LocalDensity.current) { 1.dp.toPx() }
    val widest = remember { IntArray(1) }
    Text(
        text,
        modifier
            .layout { m, c ->
                widest[0] = if (c.hasBoundedWidth) c.maxWidth else Constraints.Infinity
                val p = m.measure(c)
                layout(p.width, p.height) { p.place(0, 0) }
            }
            .drawBehind {
                val w = NowMotion.reword(clock.value - at, reduce) ?: return@drawBehind
                val old = measurer.measure(
                    from, style.copy(color = color, textAlign = textAlign), constraints = Constraints(maxWidth = widest[0]), maxLines = maxLines, overflow = TextOverflow.Ellipsis,
                )
                val x = when (textAlign) {
                    TextAlign.Center -> (size.width - old.size.width) / 2
                    TextAlign.End, TextAlign.Right -> size.width - old.size.width
                    else -> 0f
                }
                drawText(old, topLeft = Offset(x, w.out.offset.toFloat() * unit), alpha = w.out.opacity.toFloat())
            }
            .graphicsLayer {
                val w = NowMotion.reword(clock.value - at, reduce)
                alpha = w?.into?.opacity?.toFloat() ?: 1f
                translationY = (w?.into?.offset?.toFloat() ?: 0f) * unit
            },
        color = color, style = style, textAlign = textAlign, maxLines = maxLines, overflow = TextOverflow.Ellipsis,
    )
}

/**
 * A ✓ drawn as a stroke in [box] (where the glyph would sit), [trim] of it (0 → 1, from the short arm round to the
 * long), as Settled's receipts and the Review chips draw theirs.
 */
fun DrawScope.drawCheck(color: Color, trim: Float, box: Rect, width: Float) {
    if (trim <= 0f) return
    val pts = listOf(Offset(0.14f, 0.56f), Offset(0.40f, 0.80f), Offset(0.88f, 0.24f)).map { Offset(box.left + it.x * box.width, box.top + it.y * box.height) }
    val a = hypot(pts[1].x - pts[0].x, pts[1].y - pts[0].y)
    val b = hypot(pts[2].x - pts[1].x, pts[2].y - pts[1].y)
    val len = (a + b) * trim.coerceAtMost(1f)
    val path = Path().apply {
        moveTo(pts[0].x, pts[0].y)
        if (len <= a) {
            lineTo(pts[0].x + (pts[1].x - pts[0].x) * len / a, pts[0].y + (pts[1].y - pts[0].y) * len / a)
        } else {
            lineTo(pts[1].x, pts[1].y)
            val k = (len - a) / max(b, 0.001f)
            lineTo(pts[1].x + (pts[2].x - pts[1].x) * k, pts[1].y + (pts[2].y - pts[1].y) * k)
        }
    }
    drawPath(path, color, style = Stroke(width, cap = StrokeCap.Round, join = StrokeJoin.Round))
}

/** [text] with every "✓" in it drawn transparent, so a [drawCheck] can stand in its place and the words read the same. */
fun hideChecks(text: String): AnnotatedString = AnnotatedString.Builder(text).apply {
    var i = text.indexOf('✓')
    while (i >= 0) {
        addStyle(SpanStyle(color = Color.Transparent), i, i + 1)
        i = text.indexOf('✓', i + 1)
    }
}.toAnnotatedString()

/** Where the "✓" in a laid-out text sits, as the glyph's box (its line's height), or null when it has none. */
fun TextLayoutResult.checkBox(): Rect? {
    val i = layoutInput.text.text.indexOf('✓')
    if (i < 0) return null
    val b = getBoundingBox(i)
    // A square on the glyph's advance, centred on the line's x-height band.
    val side = minOf(b.width, b.height) * 0.92f
    val cy = (b.top + b.bottom) / 2 + b.height * 0.04f
    return Rect(b.left + (b.width - side) / 2, cy - side / 2, b.left + (b.width + side) / 2, cy + side / 2)
}
