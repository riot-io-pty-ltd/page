package app.page.android.ui.nw.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.PriorityHigh
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material.icons.outlined.StarOutline
import androidx.compose.material.icons.outlined.TrackChanges
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.HoldRingSpec
import app.page.android.model.NWDestination
import app.page.android.model.PulseModel
import app.page.android.model.StopFlowPhase
import app.page.android.model.StopPlan
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

/**
 * The bottom bar: Now, the pulse, Sky. Each side carries a badge (the Decide count in amber, the working count
 * in teal). Two places and one verb: a tap on a side switches, a horizontal drag on a side switches (Sky lies to
 * the right of Now), a tap on the pulse button opens Dispatch, and holding the pulse is the Stop ring (see
 * [NWStopOverlay]). The Android adaptation of iOS's floating capsule (board 06): a bar along the bottom edge with
 * the label under each icon, selected side in a tinted pill, and the pulse as a rounded-square button in the middle.
 */
@Composable
fun NWNavBar(
    selection: NWDestination,
    decideCount: Int,
    workingCount: Int,
    onSelect: (NWDestination) -> Unit,
    modifier: Modifier = Modifier,
    /** What the pulse here counts, one ring each: the same count as every other pulse (`NowModel.pulseWaiting`). */
    pulseWaiting: Int = decideCount,
    /** The oldest wait among those, which sets the ripple's pace. */
    pulseLongestWait: Double = 0.0,
    onHeld: (Double?) -> Unit = {},
    onPulseTap: () -> Unit = {},
    onPulseHold: () -> Unit = {},
) {
    val barShape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
    Box(
        modifier
            .fillMaxWidth()
            .background(NW.Palette.surface.opacity(0.995).color, barShape)
            .border(1.dp, Color.White.copy(alpha = 0.06f), barShape),
    ) {
        Row(
            Modifier.windowInsetsPadding(WindowInsets.navigationBars).fillMaxWidth().height(84.dp).padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            NavSide(NWDestination.NOW, "Now", Icons.Outlined.TrackChanges, decideCount, NW.Palette.amber, selection, onSelect, Modifier.weight(1f))
            PulseButton(workingCount, pulseWaiting, pulseLongestWait, onHeld, onPulseTap, onPulseHold, Modifier.size(88.dp, 84.dp))
            NavSide(NWDestination.SKY, "Sky", Icons.Outlined.StarOutline, workingCount, NW.Palette.teal, selection, onSelect, Modifier.weight(1f))
        }
    }
}

@Composable
private fun NavSide(
    destination: NWDestination, title: String, icon: ImageVector, count: Int, badge: Rgba, selection: NWDestination,
    onSelect: (NWDestination) -> Unit, modifier: Modifier,
) {
    val on = selection == destination
    val pick by rememberUpdatedState(onSelect)
    val sel by rememberUpdatedState(selection)
    val drag = remember { mutableFloatStateOf(0f) }
    Column(
        modifier
            .heightIn(min = 64.dp)
            .pointerDrag({ drag.floatValue += it }, {
                val to = NWDestination.afterDrag(sel, drag.floatValue.toDouble(), 0.0)
                if (to != sel) pick(to)
                drag.floatValue = 0f
            })
            .clickable(role = Role.Tab, onClick = { onSelect(destination) })
            .semantics {
                selected = on
                contentDescription = if (count > 0) "$title, $count" else title
            },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
    ) {
        Row(
            Modifier.height(34.dp).clip(CircleShape).background(if (on) badge.opacity(0.16).color else Color.Transparent).padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(icon, null, tint = if (on) badge.color else NW.Palette.textTertiary.color, modifier = Modifier.size(24.dp))
            if (count > 0) {
                Text(
                    "$count", style = NW.Typo.captionStrong.copy(fontSize = 13.sp), color = NW.Palette.onBright.color, textAlign = TextAlign.Center,
                    modifier = Modifier.clip(CircleShape).background(badge.color).padding(horizontal = 7.dp, vertical = 1.dp),
                )
            }
        }
        Text(
            title, style = NW.Typo.captionStrong.copy(fontSize = 13.sp), color = if (on) NW.Palette.textPrimary.color else NW.Palette.textTertiary.color,
            modifier = Modifier.padding(top = 3.dp),
        )
    }
}

/** A horizontal drag on a side of the bar (the pulse in the middle keeps its own gestures, so a slow tap never switches). */
private fun Modifier.pointerDrag(onDrag: (Float) -> Unit, onEnd: () -> Unit): Modifier =
    this.then(Modifier.pointerInputDrag(onDrag, onEnd))

private fun Modifier.pointerInputDrag(onDrag: (Float) -> Unit, onEnd: () -> Unit): Modifier =
    this.then(
        Modifier.pointerInput(Unit) {
            detectHorizontalDragGestures(onDragEnd = onEnd, onDragCancel = onEnd, onHorizontalDrag = { _, dx -> onDrag(dx) })
        },
    )

/** The pulse button: a gradient rounded square with a plus, the pulse's ripples round it, and the Stop ring over it while held. */
@Composable
private fun PulseButton(
    working: Int, waiting: Int, longestWait: Double, onHeld: (Double?) -> Unit, onTap: () -> Unit, onHold: () -> Unit, modifier: Modifier,
) {
    val model = remember(working, waiting, longestWait) { PulseModel(working, waiting, longestWait) }
    val held = remember { mutableFloatStateOf(-1f) }
    Box(
        modifier.semantics(mergeDescendants = true) {
            role = Role.Button
            contentDescription = "Start new work. Hold to stop everything."
            customActions = listOf(CustomAccessibilityAction("Stop all agents") { onHold(); true })
        },
        contentAlignment = Alignment.Center,
    ) {
        NWHoldSurface(
            HoldRingSpec.stopAll, Modifier.size(88.dp, 84.dp), onHeld = { held.floatValue = it?.toFloat() ?: -1f; onHeld(it) },
            onComplete = onHold, onTap = onTap,
        ) { p ->
            Box(Modifier.size(88.dp, 84.dp), contentAlignment = Alignment.Center) {
                // The pulse, here too: an amber ripple per waiting item, or the teal breath.
                if (p == 0.0) CapsulePulse(model)
                Canvas(Modifier.size(80.dp)) {
                    val c = Offset(size.width / 2, size.height / 2)
                    val d = 76.dp.toPx()
                    val lw = 4.dp.toPx()
                    drawCircle(Color.White.copy(alpha = if (p > 0) 0.12f else 0f), radius = d / 2, center = c, style = Stroke(lw))
                    drawArc(
                        NW.Palette.amber.mixed(NW.Palette.red, HoldRingSpec.warmth(p)).color, -90f, (360 * p).toFloat(), false,
                        topLeft = Offset(c.x - d / 2, c.y - d / 2), size = androidx.compose.ui.geometry.Size(d, d), style = Stroke(lw, cap = StrokeCap.Round),
                    )
                }
                Box(
                    Modifier
                        .size(64.dp)
                        .scale((1 - 0.06 * p).toFloat())
                        .shadow(10.dp, RoundedCornerShape(20.dp), ambientColor = NW.Palette.teal.color, spotColor = NW.Palette.sky.color)
                        .clip(RoundedCornerShape(20.dp))
                        .background(Brush.linearGradient(listOf(NW.Palette.teal.color, NW.Palette.sky.color))),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.Add, null, tint = NW.Palette.onBright.color, modifier = Modifier.size(30.dp)) }
            }
        }
    }
}

/**
 * The pulse on the bar's button: an amber ripple opening from the button, one ring per waiting item, or a teal
 * ring breathing while agents work; nothing when quiet. A slow 20 fps; Reduce Motion holds a still ring.
 */
@Composable
fun CapsulePulse(model: PulseModel, modifier: Modifier = Modifier) {
    NWAnimated(fps = 20.0, active = model.isAnimated) { t ->
        Canvas(modifier.size(88.dp, 84.dp).clearAndSetSemantics {}) {
            val c = Offset(size.width / 2, size.height / 2)
            val lw = 1.5.dp.toPx()
            for (r in model.ripples(t)) {
                drawCircle(NW.Palette.amber.opacity(0.7 * r.opacity).color, radius = (58 + 30 * r.progress).dp.toPx() / 2, center = c, style = Stroke(lw))
            }
            if (model.mode == PulseModel.Mode.WORKING) {
                val b = model.breath(t)
                drawCircle(NW.Palette.teal.opacity(0.18 + 0.22 * b).color, radius = (62 + 6 * b).dp.toPx() / 2, center = c, style = Stroke(lw))
            } else if (model.mode == PulseModel.Mode.WAITING) {
                drawCircle(NW.Palette.amber.opacity(0.55).color, radius = 62.dp.toPx() / 2, center = c, style = Stroke(lw))
            }
        }
    }
}

/**
 * The Stop ring, big, over the screen: it appears after 300 ms of holding the pulse, names the scope, fills over
 * 1.2 s (amber, red only in the last third), then the fingerprint / face / screen lock asks. Letting go early
 * unwinds it and nothing is sent. Dim background; the screen under it is untouched. (iOS NWStopOverlay.)
 */
@Composable
fun NWStopOverlay(phase: StopFlowPhase, plan: StopPlan, modifier: Modifier = Modifier, biometry: String = "fingerprint") {
    AnimatedVisibility(phase.isActive, enter = fadeIn(), exit = fadeOut(), modifier = modifier) {
        val progress = when (phase) {
            is StopFlowPhase.Holding -> phase.progress
            StopFlowPhase.Idle -> 0.0
            else -> 1.0
        }
        var tone = NW.Palette.amber.mixed(NW.Palette.red, HoldRingSpec.warmth(progress))
        // A confirmed Stop is calm, not alarming: the ring settles to teal.
        if (phase is StopFlowPhase.Result) tone = if (phase.outcome.isSuccess) NW.Palette.teal else NW.Palette.amber
        val caption = when (phase) {
            StopFlowPhase.Idle -> ""
            is StopFlowPhase.Holding -> if (plan.canStop) HoldRingSpec.prompt(phase.progress, biometry).replaceFirstChar { it.uppercase() } else plan.scope
            StopFlowPhase.Authenticating -> "Confirm with your $biometry"
            StopFlowPhase.Sending -> "Asking your Mac…"
            is StopFlowPhase.Result -> phase.outcome.message
        }
        val captionColor = if (phase is StopFlowPhase.Result && phase.outcome.isSuccess) NW.Palette.teal else NW.Palette.red.mixed(Rgba(1.0, 1.0, 1.0), 0.35)
        val icon = when (phase) {
            StopFlowPhase.Authenticating -> Icons.Outlined.Fingerprint
            is StopFlowPhase.Result -> if (phase.outcome.isSuccess) Icons.Filled.Check else Icons.Filled.PriorityHigh
            else -> Icons.Filled.Stop
        }
        Box(
            Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.82f)).clickable(enabled = false) {}
                .semantics(mergeDescendants = true) { contentDescription = "${plan.scope}. $caption"; liveRegion = LiveRegionMode.Polite },
            contentAlignment = Alignment.Center,
        ) {
            Column(Modifier.padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(22.dp)) {
                Text(plan.scope, style = NW.Typo.headline, color = NW.Palette.textPrimary.color, textAlign = TextAlign.Center)
                if (plan.names.isNotEmpty() && plan.canStop) Text(plan.names, style = NW.Typo.monoSmall, color = NW.Palette.textTertiary.color)
                Box(contentAlignment = Alignment.Center) {
                    Canvas(Modifier.size(172.dp)) {
                        val c = Offset(size.width / 2, size.height / 2)
                        val d = 150.dp.toPx()
                        val lw = 14.dp.toPx()
                        drawCircle(Color.White.copy(alpha = 0.10f), radius = d / 2, center = c, style = Stroke(lw))
                        if (progress > 0) drawCircle(tone.opacity(0.18 * progress).color, radius = d / 2 + lw * 0.45f, center = c, style = Stroke(lw * 1.2f))
                        drawArc(tone.color, -90f, (360 * progress).toFloat(), false, topLeft = Offset(c.x - d / 2, c.y - d / 2), size = androidx.compose.ui.geometry.Size(d, d), style = Stroke(lw, cap = StrokeCap.Round))
                        drawCircle(tone.opacity(0.9).color, radius = 92.dp.toPx() / 2, center = c)
                    }
                    Icon(icon, null, tint = NW.Palette.onBright.color, modifier = Modifier.size(38.dp))
                }
                Text(caption, style = NW.Typo.bodyStrong, color = captionColor.color, textAlign = TextAlign.Center)
            }
        }
    }
}
