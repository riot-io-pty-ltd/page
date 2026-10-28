package app.page.android.ui.nw.components

import android.os.SystemClock
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.waitForUpOrCancellation
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import app.page.android.model.HoldRingSpec
import app.page.android.ui.nw.theme.LocalMotionPin
import app.page.android.ui.nw.theme.NWMotionPin
import app.page.android.ui.nw.theme.pinned
import java.time.Instant
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.NW
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Tracks a press-and-hold against a [HoldRingSpec] and hands the progress to its content. Fills as the finger
 * stays down, ticks the haptics at 25%, 50% and 75% and firmly when full, calls [onComplete] once (the caller
 * then asks for the fingerprint / face / screen lock), and unwinds backwards on an early release with nothing
 * sent. Under Reduce Motion the unwind is instant. [onHeld] (optional) reports the seconds held while pressed,
 * null otherwise, for a caller that needs the elapsed time (the pulse tells a tap from a hold). A cancelled
 * touch (a scroll takes it) unwinds with nothing sent and no tap. (iOS NWHoldSurface.)
 */
@Composable
fun NWHoldSurface(
    spec: HoldRingSpec,
    modifier: Modifier = Modifier,
    /** Draws this progress instead of tracking a press (the render harness). */
    fixedProgress: Double? = null,
    onHeld: ((Double?) -> Unit)? = null,
    onComplete: () -> Unit,
    /** Released before the dead zone ended: a tap. */
    onTap: (() -> Unit)? = null,
    content: @Composable (Double) -> Unit,
) {
    val haptics = rememberHaptics()
    val reduceMotion = LocalReduceMotion.current
    val scope = rememberCoroutineScope()
    val progress = remember { mutableFloatStateOf(0f) }
    var pressStart by remember { mutableStateOf<Long?>(null) }
    var completed by remember { mutableStateOf(false) }
    var driver by remember { mutableStateOf<Job?>(null) }
    val complete by rememberUpdatedState(onComplete)
    val tap by rememberUpdatedState(onTap)
    val held by rememberUpdatedState(onHeld)
    val shown = fixedProgress ?: progress.floatValue.toDouble()

    fun begin() {
        if (completed) return
        val start = SystemClock.elapsedRealtime()
        pressStart = start
        driver?.cancel()
        driver = scope.launch {
            var last = 0.0
            while (isActive && pressStart != null) {
                val elapsed = (SystemClock.elapsedRealtime() - start) / 1000.0
                val p = spec.progress(elapsed)
                for (t in HoldRingSpec.ticksCrossed(last, p)) if (t >= 1) haptics.full() else haptics.tick()
                last = p
                progress.floatValue = p.toFloat()
                held?.invoke(elapsed)
                if (spec.isComplete(elapsed)) {
                    completed = true
                    pressStart = null
                    complete()
                    // Ready again for the next time (after biometrics).
                    delay(400)
                    completed = false
                    progress.floatValue = 0f
                    held?.invoke(null)
                    return@launch
                }
                withFrameNanos { }
            }
        }
    }

    fun end(cancelled: Boolean) {
        val start = pressStart ?: return
        if (completed) return
        val elapsed = (SystemClock.elapsedRealtime() - start) / 1000.0
        pressStart = null
        driver?.cancel()
        held?.invoke(null)
        if (!spec.isVisible(elapsed)) {
            // A tap, not a hold (a cancelled touch is neither).
            progress.floatValue = 0f
            if (!cancelled) tap?.invoke()
            return
        }
        // Back the way it came, at the speed it filled but never slower than [HoldRingSpec.maxUnwind] from full (a
        // 10 s Stop ring lets go in about a second); nothing was sent.
        val from = progress.floatValue
        if (reduceMotion || from <= 0f) { progress.floatValue = 0f; return }
        driver = scope.launch {
            val released = SystemClock.elapsedRealtime()
            while (isActive && progress.floatValue > 0f) {
                withFrameNanos { }
                progress.floatValue = spec.unwound(from.toDouble(), (SystemClock.elapsedRealtime() - released) / 1000.0).toFloat()
            }
        }
    }

    DisposableEffect(Unit) { onDispose { driver?.cancel(); held?.invoke(null) } }

    Box(
        modifier.pointerInput(spec, fixedProgress) {
            if (fixedProgress != null) return@pointerInput
            awaitEachGesture {
                awaitFirstDown(requireUnconsumed = false)
                begin()
                val up = waitForUpOrCancellation()
                end(cancelled = up == null)
            }
        },
    ) { content(shown) }
}

/**
 * The big press-and-hold ring ([HoldRingSpec] for the timing), board 07's "hold ring": the red button alone at
 * first; after 300 ms a ring appears and fills clockwise over 1.2 s, amber warming to red only in its final
 * third, with haptic ticks at 25%, 50% and 75% (firm at 100%); full, the core turns green-teal (biometrics next); once
 * biometrics pass ([burstStart]), a burst of light leaves the ring. The burst means committed, never delivered:
 * the Receipt thread says that. Letting go early unwinds the ring backwards. TalkBack users get a "Confirm"
 * action instead of a hold (the biometric check still follows).
 */
@Composable
fun NWHoldRing(
    spec: HoldRingSpec, onComplete: () -> Unit, modifier: Modifier = Modifier, size: Dp = 132.dp, fixedProgress: Double? = null,
    /** Biometrics passed at this moment: the burst plays once and the ring stays full. */
    burstAt: Instant? = null,
) {
    // The render harness pins the burst ([NWMotionPin.Kind.HOLD]).
    val pinnedBurst = LocalMotionPin.current.pinned(NWMotionPin.Kind.HOLD)
    val committed = burstAt != null || pinnedBurst != null
    // On the one-shots' monotonic base, fixed once for this commit.
    val burstStart = remember(burstAt) { burstAt?.let { nwClockAt(it) } }
    NWHoldSurface(
        spec, modifier.size(size + 20.dp).semantics {
            role = Role.Button
            contentDescription = if (!committed) "Hold to confirm. Then confirm with your device." else "Confirmed"
            customActions = listOf(CustomAccessibilityAction("Confirm") { if (!committed) onComplete(); true })
        },
        fixedProgress = if (committed) 1.0 else fixedProgress, onComplete = onComplete,
    ) { shown ->
        Box(Modifier.size(size + 20.dp), contentAlignment = Alignment.Center) {
            RingBody(shown, size)
            if (committed) {
                NWOneShot(burstStart, HoldRingSpec.burstDuration, pinned = pinnedBurst) { e ->
                    Burst(e?.let { HoldRingSpec.burst(it) } ?: HoldRingSpec.Companion.Burst(1.0, 0.0, 0.0), size)
                }
            }
        }
    }
}

@Composable
private fun RingBody(shown: Double, size: Dp) {
    val warmth = HoldRingSpec.warmth(shown)
    val tone = NW.Palette.amber.mixed(NW.Palette.red, warmth)
    val full = shown >= 1
    // Red is the class colour of the button; green-teal once it is full and biometrics are next.
    val core = if (full) NW.Palette.green.mixed(NW.Palette.teal, 0.25) else NW.Palette.red
    Box(Modifier.size(size + 20.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(size + 20.dp)) {
            val c = Offset(this.size.width / 2, this.size.height / 2)
            val d = size.toPx()
            val lw = 14.dp.toPx()
            val tl = Offset(c.x - d / 2, c.y - d / 2)
            // Nothing but the button for the first 300 ms (board 07's "0 ms" beat; iOS draws no track until the
            // ring appears either), so a slow tap never shows a ring starting. Once it has, a dim red track the arc
            // fills (board 33, a frame part-way through a hold).
            if (shown > 0) {
                drawCircle(NW.Palette.red.opacity(0.20).color, radius = d / 2, center = c, style = Stroke(lw))
                // The ring's own light (a shadow on iOS): wider, fainter passes of the same arc, brighter once full.
                val light = (if (full) 0.75 else 0.5) * shown
                val sweep = (360 * shown).toFloat()
                for ((extra, a) in listOf(6f to 0.22, 12f to 0.12, 20f to 0.06)) {
                    val w = lw + (if (full) extra * 1.3f else extra).dp.toPx()
                    drawArc(tone.opacity(light * a).color, -90f, sweep, false, topLeft = tl, size = androidx.compose.ui.geometry.Size(d, d), style = Stroke(w, cap = StrokeCap.Round))
                }
                drawArc(tone.color, -90f, sweep, false, topLeft = tl, size = androidx.compose.ui.geometry.Size(d, d), style = Stroke(lw, cap = StrokeCap.Round))
            }
            val coreR = d * 0.62f / 2 * (1f + 0.04f * shown.toFloat())
            // The core's soft light.
            val spread = (if (full) 14 else 8).dp.toPx()
            drawCircle(
                Brush.radialGradient(
                    0f to core.opacity(if (full) 0.5 else 0.25).color, (coreR / (coreR + spread)) to core.opacity(if (full) 0.5 else 0.25).color, 1f to core.opacity(0.0).color,
                    center = c, radius = coreR + spread,
                ),
                radius = coreR + spread, center = c,
            )
            // The core is a soft rounded square (board 33), not a disc.
            drawRoundRect(
                Brush.verticalGradient(listOf(core.opacity(0.98).color, core.opacity(0.84).color), startY = c.y - coreR, endY = c.y + coreR),
                topLeft = Offset(c.x - coreR, c.y - coreR), size = androidx.compose.ui.geometry.Size(coreR * 2, coreR * 2),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(coreR * 0.46f),
            )
        }
        // The fingerprint says what follows the hold; at rest too, so the button reads as the confirm control.
        Icon(Icons.Outlined.Fingerprint, null, tint = NW.Palette.onBright.color, modifier = Modifier.size(size * 0.32f))
    }
}

/** The burst: a ring of light leaves the full ring and opens as it fades; the core flashes once. */
@Composable
private fun Burst(b: HoldRingSpec.Companion.Burst, size: Dp) {
    Canvas(Modifier.size(size * 1.6f)) {
        val c = Offset(this.size.width / 2, this.size.height / 2)
        val d = size.toPx()
        val ring = NW.Palette.red.mixed(NW.Palette.white, 0.3)
        val r = d / 2 * b.scale.toFloat()
        // A soft ring of light (blurred on iOS): a faint wide pass under the 6 dp line.
        drawCircle(ring.opacity(0.35 * b.opacity).color, radius = r, center = c, style = Stroke(12.dp.toPx()))
        drawCircle(ring.opacity(b.opacity).color, radius = r, center = c, style = Stroke(6.dp.toPx()))
        // The core flashes once.
        val coreR = d * 0.62f / 2
        drawCircle(
            Brush.radialGradient(0f to Color.White.copy(alpha = (0.35 * b.flash).toFloat()), 0.8f to Color.White.copy(alpha = (0.3 * b.flash).toFloat()), 1f to Color.Transparent, center = c, radius = coreR + 6.dp.toPx()),
            radius = coreR + 6.dp.toPx(), center = c,
        )
    }
}

/**
 * "Hold to approve" as a button on a card: a small ring fills beside the label while the finger stays down (an
 * Irreversible approve is 1.2 s, then the fingerprint / face / screen lock). A tap does nothing but say how to
 * use it.
 */
@Composable
fun NWHoldButton(onComplete: () -> Unit, modifier: Modifier = Modifier, label: String = "Hold", fixedProgress: Double? = null, onTap: (() -> Unit)? = null) {
    val shape = RoundedCornerShape(NW.Radius.button)
    NWHoldSurface(
        HoldRingSpec.irreversible,
        modifier.fillMaxWidth().semantics {
            role = Role.Button
            contentDescription = "Hold to approve. Hold, then confirm with your device."
            customActions = listOf(CustomAccessibilityAction("Confirm") { onComplete(); true })
        },
        fixedProgress = fixedProgress, onComplete = onComplete, onTap = onTap,
    ) { p ->
        // A filled red button with a fingerprint (board 06). While held, a warmer fill sweeps across it.
        val tone = NW.Palette.red.mixed(NW.Palette.amber, 0.35 * (1 - HoldRingSpec.warmth(p)))
        Box(
            Modifier
                .fillMaxWidth()
                .heightIn(min = NW.buttonHeight)
                .clip(shape)
                .background(NW.Palette.red.color, shape)
                .drawBehind { if (p > 0) drawRect(tone.opacity(0.85).color, size = androidx.compose.ui.geometry.Size(size.width * p.toFloat(), size.height)) }
                .padding(horizontal = 16.dp),
            contentAlignment = Alignment.Center,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Icon(Icons.Outlined.Fingerprint, null, tint = NW.Palette.onBright.color, modifier = Modifier.size(24.dp))
                Text(label, style = NW.Typo.button, color = NW.Palette.onBright.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

/** The arm ring on a card: nothing has left the phone yet, and a tap cancels. [progress] is 0..1 over the 1.2 s. */
@Composable
fun NWArmRing(progress: Double, modifier: Modifier = Modifier, size: Dp = 24.dp, color: androidx.compose.ui.graphics.Color = NW.Palette.amber.color) {
    Canvas(modifier.size(size)) {
        val lw = 3.dp.toPx()
        val d = this.size.width - lw
        drawCircle(color.copy(alpha = 0.22f), radius = d / 2, style = Stroke(lw))
        drawArc(color, -90f, (360 * progress.coerceIn(0.0, 1.0)).toFloat(), false, topLeft = Offset(lw / 2, lw / 2), size = androidx.compose.ui.geometry.Size(d, d), style = Stroke(lw, cap = StrokeCap.Round))
    }
}
