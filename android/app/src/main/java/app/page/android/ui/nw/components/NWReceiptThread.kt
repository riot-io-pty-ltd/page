package app.page.android.ui.nw.components

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.model.MotionCurve
import app.page.android.model.WorkflowMotion
import app.page.android.model.ReceiptThread
import app.page.android.model.ReceiptThreadInput
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import java.time.Instant

/**
 * THE RECEIPT THREAD on a card or sheet ([ReceiptThread] for the truth and the timing): the card's dot, the relay
 * and the Mac, joined by a thin thread of light. ARM winds a ring round the dot (tap cancels); SEND draws the
 * thread to the relay, and a glint travels on while the Mac is awaited; only the Mac's confirmation runs it on to
 * the Mac ("typed", then "verified"), turns the dot teal and contracts its rings into it. A failure snaps the
 * thread back, shakes once softly and says what happened. It runs a clock only while something on it moves.
 * (iOS NWReceiptThreadView.)
 */
@Composable
fun NWReceiptThreadView(input: ReceiptThreadInput, modifier: Modifier = Modifier, armingLabel: String? = null, onTap: () -> Unit = {}) {
    val reduce = LocalReduceMotion.current
    // A thread of light is thin and slow: 30 fps while it moves (Remove animations still ticks the arm countdown, at 10 Hz).
    val now by rememberNWNow(input.movingUntil(Instant.now()), fastMs = if (reduce) 100 else 33)
    val raw = input.frame(now)
    val f = if (reduce) still(raw) else raw
    val tone = tone(f)
    val arming = f.stage == ReceiptThread.Stage.Arming
    val shape = RoundedCornerShape(NW.Radius.button)
    // [armingLabel]: what TalkBack says while the ring runs, when the caller can name it ("Sending Yes, tap to cancel").
    val label = if (arming && armingLabel != null) armingLabel else accessibility(f)
    Column(
        modifier
            .fillMaxWidth()
            .offset(x = (f.shake * 7).dp)
            .heightIn(min = 52.dp)
            .clip(shape)
            .background(tone.opacity(if (arming) 0.06 else 0.07).color, shape)
            .border(1.dp, tone.opacity(if (arming) 0.22 else 0.16).color, shape)
            .clickable(enabled = arming || f.isFailure, role = Role.Button, onClickLabel = if (arming) "Cancel" else "See why") { onTap() }
            .padding(horizontal = 14.dp, vertical = 10.dp)
            .semantics(mergeDescendants = false) {
                contentDescription = label
                liveRegion = LiveRegionMode.Polite
            },
        verticalArrangement = Arrangement.spacedBy(8.dp), horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Canvas(Modifier.fillMaxWidth().height(30.dp).clearAndSetSemantics {}) { drawThread(f, tone) }
        // A new stage's word cross-fades in over the old (held to sending, sent to typed); the arm's countdown, which
        // changes every tick, simply counts.
        val ms = ((if (reduce) WorkflowMotion.reducedFade else WorkflowMotion.crossFade) * 1000).toInt()
        AnimatedContent(
            if (arming && input.pending != null) null to tone else f.word to tone,
            transitionSpec = { fadeIn(tween(ms)) togetherWith fadeOut(tween(ms)) }, contentKey = { it.first }, label = "stage",
        ) { (word, wordTone) ->
            Text(
                word ?: input.pending?.armLabel(now) ?: "",
                style = if (word == null) NW.Typo.bodyStrong else NW.Typo.captionStrong, color = (if (word == null) NW.Palette.textPrimary else wordTone).color,
                textAlign = TextAlign.Center, maxLines = 2, overflow = TextOverflow.Ellipsis,
                modifier = Modifier.clearAndSetSemantics {},
            )
        }
        if (arming) input.pending?.preview?.let {
            Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color, textAlign = TextAlign.Center, maxLines = 2, modifier = Modifier.clearAndSetSemantics {})
        }
    }
}

/** Reduce Motion: each stage drawn where it ends, with nothing travelling (the arm ring still counts down). */
fun still(f: ReceiptThread): ReceiptThread = when (f.stage) {
    ReceiptThread.Stage.Sending, ReceiptThread.Stage.Deleting -> f.copy(reach = 0.42, glint = null, shake = 0.0)
    ReceiptThread.Stage.Sent, ReceiptThread.Stage.Queued, ReceiptThread.Stage.Held -> f.copy(reach = 0.5, glint = null, shake = 0.0)
    ReceiptThread.Stage.Deleted -> f.copy(reach = 0.0, glint = null, shake = 0.0)
    ReceiptThread.Stage.Typed, ReceiptThread.Stage.Verified -> f.copy(reach = 1.0, macLit = true, dotTeal = 1.0, rings = 0.0, glint = null, shake = 0.0)
    is ReceiptThread.Stage.Failed -> f.copy(reach = 0.0, glint = null, shake = 0.0)
    else -> f.copy(glint = null, shake = 0.0)
}

private fun tone(f: ReceiptThread): Rgba = when (f.stage) {
    ReceiptThread.Stage.Idle, ReceiptThread.Stage.Arming -> Rgba(1.0, 1.0, 1.0, 0.92)
    ReceiptThread.Stage.Sending, ReceiptThread.Stage.Sent, ReceiptThread.Stage.Typed, ReceiptThread.Stage.Deleting -> NW.Palette.sky
    ReceiptThread.Stage.Queued, ReceiptThread.Stage.Held -> NW.Palette.amber
    ReceiptThread.Stage.Deleted -> NW.Palette.textSecondary
    ReceiptThread.Stage.Verified -> NW.Palette.green
    is ReceiptThread.Stage.Failed -> NW.Palette.amber
}

private fun accessibility(f: ReceiptThread): String = when (val s = f.stage) {
    ReceiptThread.Stage.Arming -> "Sending, tap to cancel"
    ReceiptThread.Stage.Sending -> "Sending"
    ReceiptThread.Stage.Sent -> "Sent, waiting for your Mac to confirm"
    ReceiptThread.Stage.Queued -> "Queued until your Mac is back online"
    ReceiptThread.Stage.Deleting -> "Deleting"
    ReceiptThread.Stage.Deleted -> "Deleted, not sent"
    ReceiptThread.Stage.Held -> "Held on your Mac until the limit resets"
    ReceiptThread.Stage.Typed, ReceiptThread.Stage.Verified -> "Delivered and verified on your Mac"
    is ReceiptThread.Stage.Failed -> s.why
    ReceiptThread.Stage.Idle -> ""
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.drawThread(f: ReceiptThread, tone: Rgba) {
    val node = 30.dp.toPx()
    val w = size.width
    val mid = size.height / 2
    val x0 = node / 2
    val x2 = w - node / 2
    val xr = x0 + (x2 - x0) * MotionCurve.clamp01(f.reach).toFloat()
    drawLine(androidx.compose.ui.graphics.Color.White.copy(alpha = 0.08f), Offset(x0, mid), Offset(x2, mid), 1.5.dp.toPx())
    if (f.reach > 0.001) {
        drawLine(tone.opacity(0.28).color, Offset(x0, mid), Offset(xr, mid), 5.dp.toPx(), StrokeCap.Round)
        drawLine(tone.color, Offset(x0, mid), Offset(xr, mid), 2.dp.toPx(), StrokeCap.Round)
    }
    f.glint?.let { g ->
        val xg = x0 + (x2 - x0) * g.toFloat()
        val a = (0.75 * (1 - (g - 0.5) * 1.6)).coerceIn(0.0, 1.0)
        drawLine(
            Brush.horizontalGradient(listOf(tone.opacity(0.0).color, tone.opacity(a).color, tone.opacity(0.0).color), startX = xg - 17.dp.toPx(), endX = xg + 17.dp.toPx()),
            Offset(xg - 17.dp.toPx(), mid), Offset(xg + 17.dp.toPx(), mid), 2.dp.toPx(), StrokeCap.Round,
        )
    }
    // The card's dot.
    val c = NW.Palette.amber.mixed(NW.Palette.teal, f.dotTeal)
    val dc = Offset(x0, mid)
    drawCircle(NW.Palette.surfaceRaised.color, node / 2, dc)
    drawCircle(
        (if (f.reach > 0 || f.stage == ReceiptThread.Stage.Verified) tone else Rgba(1.0, 1.0, 1.0)).opacity(if (f.reach > 0) 0.55 else 0.12).color,
        node / 2 - 0.5.dp.toPx(), dc, style = Stroke(1.dp.toPx()),
    )
    val open = (0.35 + 0.65 * f.rings).toFloat()
    for (i in 0..1) {
        val a = 0.35 * f.rings + (if (f.rings < 1) 0.25 * (1 - f.rings) * (1 - f.dotTeal) else 0.0)
        drawCircle(c.opacity(a).color, (12 + 6 * i).dp.toPx() * open / 2, dc, style = Stroke(1.dp.toPx()))
    }
    drawCircle(c.opacity(0.35).color, 6.dp.toPx(), dc)
    drawCircle(c.color, 4.dp.toPx(), dc)
    if (f.stage == ReceiptThread.Stage.Arming) {
        val d = 26.dp.toPx()
        drawArc(androidx.compose.ui.graphics.Color.White.copy(alpha = 0.92f), -90f, (360 * f.arm).toFloat(), false, Offset(dc.x - d / 2, dc.y - d / 2), androidx.compose.ui.geometry.Size(d, d), style = Stroke(2.dp.toPx(), cap = StrokeCap.Round))
    }
    // The relay and the Mac.
    station(Offset((x0 + x2) / 2, mid), node, f.relayLit, tone, relay = true)
    station(Offset(x2, mid), node, f.macLit, tone, relay = false)
}

private fun androidx.compose.ui.graphics.drawscope.DrawScope.station(center: Offset, node: Float, lit: Boolean, tone: Rgba, relay: Boolean) {
    drawCircle((if (lit) tone.opacity(0.16) else NW.Palette.surfaceRaised).color, node / 2, center)
    drawCircle((if (lit) tone.opacity(0.6) else Rgba(1.0, 1.0, 1.0, 0.12)).color, node / 2 - 0.5.dp.toPx(), center, style = Stroke(1.dp.toPx()))
    val col = (if (lit) tone else NW.Palette.textQuiet).color
    val s = 5.dp.toPx()
    if (relay) {
        // A small cloud: two bumps on a base.
        drawCircle(col, s * 0.8f, Offset(center.x - s * 0.5f, center.y), style = Stroke(1.2.dp.toPx()))
        drawCircle(col, s * 1.0f, Offset(center.x + s * 0.35f, center.y - s * 0.25f), style = Stroke(1.2.dp.toPx()))
    } else {
        // A small screen on a stand.
        drawRoundRect(col, Offset(center.x - s * 1.2f, center.y - s * 1.0f), androidx.compose.ui.geometry.Size(s * 2.4f, s * 1.6f), androidx.compose.ui.geometry.CornerRadius(1.5.dp.toPx()), style = Stroke(1.2.dp.toPx()))
        drawLine(col, Offset(center.x - s * 0.7f, center.y + s * 1.2f), Offset(center.x + s * 0.7f, center.y + s * 1.2f), 1.2.dp.toPx(), StrokeCap.Round)
    }
}
