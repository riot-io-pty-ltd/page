@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package app.page.android.ui.nw.now

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import app.page.android.model.CardOutcome
import app.page.android.model.ChipKind
import app.page.android.model.NWDestination
import app.page.android.model.NowRow
import app.page.android.model.PendingAction
import app.page.android.model.ReceiptThreadInput
import app.page.android.model.RowAction
import app.page.android.model.TurnSummaryChips
import app.page.android.model.waitingText
import app.page.android.ui.nw.components.NWArmRing
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWChip
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWHoldButton
import app.page.android.ui.nw.components.NWReceiptLine
import app.page.android.ui.nw.components.NWReceiptThreadView
import app.page.android.ui.nw.components.NWTurnChip
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.components.rememberHaptics
import app.page.android.ui.nw.components.symbol
import app.page.android.ui.nw.components.tint
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import java.time.Instant
import kotlin.math.roundToInt

// The Now stream's building blocks: the Decide cards shaped by reversibility, the swipeable Undoable row, Look and
// Review cards. They draw a NowRow and hand every action to a closure; the screen that hosts them routes it
// through the existing services, so these views never send anything themselves. (iOS NWRowViews.swift.)

/** What one card is doing now: the pending action, how it is going, and its Receipt thread. */
data class RowStatus(
    val outcome: CardOutcome = CardOutcome.None,
    val pending: PendingAction? = null,
    val receipt: ReceiptThreadInput? = null,
)

class RowActions(
    val open: () -> Unit = {},
    val approve: () -> Unit = {},
    val holdComplete: () -> Unit = {},
    val deny: () -> Unit = {},
    val looksGood: () -> Unit = {},
    val steer: () -> Unit = {},
    val cancel: () -> Unit = {},
)

@Composable
private fun CardTopLine(row: NowRow, now: Instant) {
    val large = LocalDensity.current.fontScale > 1.3f
    val age = row.waitingText(now)
    if (large) {
        // At large font sizes the chip gets its own line so the project is never squeezed out by the age.
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            NWChip(row.chip, pill = true)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(row.projectName, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, maxLines = 2, modifier = Modifier.weight(1f))
                Text(age, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = 1)
            }
        }
    } else {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            NWChip(row.chip, pill = true)
            Text(row.projectName, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            Text(age, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = 1)
        }
    }
}

/**
 * What the card's action area says once an action is under way: the 1.2 s cancel ring (nothing has been sent;
 * tapping cancels), then the wait for the Mac, then the Mac's word. Only a confirmed delivery is teal. Given the
 * delivery state, it is drawn as the Receipt thread.
 */
@Composable
fun NWOutcomeStrip(status: RowStatus, now: Instant, onCancel: () -> Unit, modifier: Modifier = Modifier) {
    val receipt = status.receipt
    if (receipt != null && !receipt.isEmpty && status.outcome != CardOutcome.None) {
        NWReceiptThreadView(receipt, modifier, onTap = onCancel)
        return
    }
    when (val o = status.outcome) {
        CardOutcome.None -> Unit
        is CardOutcome.Arming -> status.pending?.let { p -> ArmingStrip(p, now, onCancel, modifier) }
        CardOutcome.Sending -> Row(
            modifier.fillMaxWidth().heightIn(min = 52.dp).clip(RoundedCornerShape(NW.Radius.button)).background(Color.White.copy(alpha = 0.06f)).padding(horizontal = 14.dp)
                .semantics(mergeDescendants = true) {},
            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            CircularProgressIndicator(Modifier.size(16.dp), color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
            Text("Waiting for your Mac to confirm…", style = NW.Typo.monoMicro, color = NW.Palette.textSecondary.color)
        }
        is CardOutcome.Delivered -> NWReceiptLine("Delivered · ${o.detail}", modifier)
        is CardOutcome.Problem -> NWReceiptLine(o.why, modifier.clickable(role = Role.Button, onClickLabel = "Open the decision to try again", onClick = onCancel), failed = true)
    }
}

@Composable
private fun ArmingStrip(p: PendingAction, now: Instant, onCancel: () -> Unit, modifier: Modifier) {
    val phase = p.phase(now)
    val progress = (phase as? PendingAction.Phase.Arming)?.progress ?: 1.0
    val shape = RoundedCornerShape(NW.Radius.button)
    Row(
        modifier.fillMaxWidth().heightIn(min = 52.dp).clip(shape).background(NW.Palette.amber.opacity(0.12).color, shape)
            .clickable(role = Role.Button, onClickLabel = "Cancel", onClick = onCancel)
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .semantics { contentDescription = "Sending, tap to cancel" },
        horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        NWArmRing(progress, size = 26.dp)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(p.armLabel(now), style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color)
            p.preview?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color, maxLines = 2) }
        }
        Text("Cancel", style = NW.Typo.captionStrong, color = NW.Palette.amber.color)
    }
}

/**
 * A Decide card for a Considered or Irreversible approval: the command in full, the delivery preview, then Deny
 * and the approve control. Considered approves with a tap (then the 1.2 s cancel ring); Irreversible with
 * press-and-hold plus biometrics. Tapping the card opens the Decision sheet.
 */
@Composable
fun NWDecideCard(row: NowRow, now: Instant, status: RowStatus, actions: RowActions, modifier: Modifier = Modifier, fixedHold: Double? = null) {
    val irreversible = row.chip == ChipKind.IRREVERSIBLE
    val busy = status.outcome != CardOutcome.None
    val a11y = buildList {
        if (!busy && row.action(RowAction.Kind.DENY) != null) {
            add(CustomAccessibilityAction("Deny") { actions.deny(); true })
            if (row.action(RowAction.Kind.APPROVE) != null) {
                // The hold's own path: it still asks the phone to confirm before anything is sent.
                if (irreversible) add(CustomAccessibilityAction("Approve, then confirm with your device") { actions.holdComplete(); true })
                else add(CustomAccessibilityAction("Approve") { actions.approve(); true })
            }
        }
    }
    NWGlassCard(modifier, tint = row.tint) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(
                Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Opens the decision", onClick = actions.open).semantics { customActions = a11y },
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                CardTopLine(row, now)
                Text(row.headline, style = NW.Typo.headline, color = NW.Palette.textPrimary.color)
                CommandBox(row, irreversible)
            }
            when {
                busy -> NWOutcomeStrip(status, now, actions.cancel)
                row.action(RowAction.Kind.DENY) != null -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                    NWButton(row.action(RowAction.Kind.DENY)!!.label, actions.deny, Modifier.weight(1f))
                    row.action(RowAction.Kind.APPROVE)?.let { approve ->
                        if (irreversible) NWHoldButton(actions.holdComplete, Modifier.weight(1.3f), fixedProgress = fixedHold)
                        else NWButton(approve.label, actions.approve, Modifier.weight(1f), kind = NWButtonKind.BRIGHT)
                    }
                }
                row.action(RowAction.Kind.OPEN_ON_MAC) != null -> NWButton("Open on Mac", actions.open, Modifier.fillMaxWidth())
            }
        }
    }
}

@Composable
private fun CommandBox(row: NowRow, irreversible: Boolean) {
    Column(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(NW.Radius.inset)).background(NW.Palette.inset.opacity(0.85).color).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("$", style = NW.Typo.mono, color = (if (irreversible) NW.Palette.red else NW.Palette.textTertiary).color)
            Text(
                row.summary, style = NW.Typo.mono, color = (if (irreversible) NW.Palette.red.mixed(NW.Palette.white, 0.2) else NW.Palette.textPrimary).color,
                maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f),
            )
        }
        row.focusPreview?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color) }
    }
}

/** A question: the agent is waiting for words, not a yes or no. The answer is written in the sheet (Esc, then your message, then Return). */
@Composable
fun NWQuestionCard(row: NowRow, now: Instant, answerable: Boolean, onOpen: () -> Unit, modifier: Modifier = Modifier) {
    NWGlassCard(modifier.clickable(role = Role.Button, onClickLabel = "Opens the question", onClick = onOpen), tint = row.tint) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            CardTopLine(row, now)
            Text(row.summary, style = NW.Typo.title, color = NW.Palette.textPrimary.color, maxLines = 3, overflow = TextOverflow.Ellipsis)
            row.focusPreview?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color) }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Text(
                    if (answerable) "Answer" else (row.action(RowAction.Kind.TELL_INSTEAD)?.label ?: "Open"), style = NW.Typo.button, color = NW.Palette.onBright.color,
                    modifier = Modifier.heightIn(min = 48.dp).clip(CircleShape).background(Brush.horizontalGradient(listOf(NW.Palette.yellow.color, NW.Palette.amber.color))).padding(horizontal = 22.dp).wrapContentCenter(),
                )
            }
        }
    }
}

private fun Modifier.wrapContentCenter(): Modifier = this.then(Modifier.padding(vertical = 12.dp))

/**
 * An Undoable row: swipe right to approve. The Approve affordance sits behind the row and is revealed as it
 * moves; past the threshold a haptic ticks and the 1.2 s cancel ring starts (nothing is sent until it runs out).
 * A tap opens the Decision sheet. TalkBack gets "Approve" and "Open" actions instead of the swipe.
 */
@Composable
fun NWUndoableRow(row: NowRow, now: Instant, status: RowStatus, actions: RowActions, modifier: Modifier = Modifier, fixedDrag: Float? = null) {
    val haptics = rememberHaptics()
    val density = LocalDensity.current
    val commitAt = with(density) { 110.dp.toPx() }
    val maxDrag = with(density) { 160.dp.toPx() }
    var drag by remember { mutableFloatStateOf(0f) }
    var passed by remember { mutableStateOf(false) }
    val approve by rememberUpdatedState(actions.approve)
    val x = fixedDrag ?: drag
    val shape = RoundedCornerShape(NW.Radius.row)
    if (status.outcome != CardOutcome.None) {
        Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            NWGlassCard(radius = NW.Radius.row, padding = PaddingValues(0.dp)) { UndoableBody(row) }
            NWOutcomeStrip(status, now, actions.cancel)
        }
        return
    }
    Box(
        modifier.fillMaxWidth()
            .semantics(mergeDescendants = true) {
                contentDescription = "${row.summary}, ${row.projectName}, undoable"
                customActions = buildList {
                    if (row.canSwipeApprove) add(CustomAccessibilityAction("Approve") { actions.approve(); true })
                    add(CustomAccessibilityAction("Open") { actions.open(); true })
                }
            },
    ) {
        Box(
            Modifier.matchParentSize().clip(shape).background(NW.Palette.green.opacity(0.14 + 0.10 * minOf(1f, x / commitAt)).color),
            contentAlignment = Alignment.CenterStart,
        ) {
            Row(Modifier.padding(start = 18.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Check, null, tint = NW.Palette.green.color, modifier = Modifier.size(18.dp))
                Text("Approve", style = NW.Typo.bodyStrong, color = NW.Palette.green.color)
            }
        }
        Box(
            Modifier.offset { IntOffset(x.roundToInt(), 0) }
                // Opaque, so the Approve well never shows through the row.
                .clip(shape).background(NW.Palette.surface.color)
                .clickable(role = Role.Button, onClickLabel = "Opens the decision", onClick = actions.open)
                .pointerInput(row.canSwipeApprove) {
                    if (!row.canSwipeApprove) return@pointerInput
                    detectHorizontalDragGestures(
                        onDragEnd = {
                            val go = drag >= commitAt
                            passed = false
                            drag = 0f
                            if (go) approve()
                        },
                        onDragCancel = { drag = 0f; passed = false },
                        onHorizontalDrag = { change, dx ->
                            change.consume()
                            drag = (drag + dx).coerceIn(0f, maxDrag)
                            if (drag >= commitAt && !passed) { passed = true; haptics.tick() }
                            if (drag < commitAt) passed = false
                        },
                    )
                },
        ) {
            NWGlassCard(radius = NW.Radius.row, padding = PaddingValues(0.dp)) { UndoableBody(row) }
        }
    }
}

@Composable
private fun UndoableBody(row: NowRow) {
    Row(Modifier.fillMaxWidth().padding(12.dp), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(NW.Palette.green.opacity(0.14).color), contentAlignment = Alignment.Center) {
            Icon(nwIcon("terminal"), null, tint = NW.Palette.green.color, modifier = Modifier.size(22.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(row.summary, style = NW.Typo.mono, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("${row.projectName} · undoable · swipe to run", style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

/** A Look card: a stuck agent, a rate limit, a forecast. Tapping opens the sheet; the button acts (Steer opens the composer, Stop it arms the cancel ring). */
@Composable
fun NWLookCard(row: NowRow, now: Instant, status: RowStatus, actions: RowActions, modifier: Modifier = Modifier) {
    val busy = status.outcome != CardOutcome.None
    val steer = row.action(RowAction.Kind.TELL_INSTEAD)
    NWGlassCard(modifier, tint = NW.Palette.amber, padding = PaddingValues(NW.Space.md)) {
        Column(
            Modifier.semantics {
                customActions = buildList {
                    add(CustomAccessibilityAction("Open") { actions.open(); true })
                    if (!busy && steer != null) add(CustomAccessibilityAction(steer.label) { actions.steer(); true })
                }
            },
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Open", onClick = actions.open), horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(48.dp).clip(RoundedCornerShape(14.dp)).background(NW.Palette.amber.opacity(0.14).color), contentAlignment = Alignment.Center) {
                    Icon(nwIcon(row.chip.symbol), null, tint = NW.Palette.amber.color, modifier = Modifier.size(24.dp))
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(row.headline, style = NW.Typo.title, color = NW.Palette.textPrimary.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text("${row.summary} · ${row.waitingText(now)}", style = NW.Typo.caption, color = NW.Palette.textSecondary.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
                if (!busy && steer != null) NWButton(steer.label, actions.steer, Modifier.width(96.dp), kind = NWButtonKind.AMBER)
            }
            if (busy) NWOutcomeStrip(status, now, actions.cancel)
        }
    }
}

/** A Review card: a finished turn, with what changed and Looks good. */
@Composable
fun NWReviewCard(row: NowRow, now: Instant, status: RowStatus, actions: RowActions, modifier: Modifier = Modifier) {
    val busy = status.outcome != CardOutcome.None
    val steer = row.action(RowAction.Kind.TELL_INSTEAD)
    NWGlassCard(modifier, tint = NW.Palette.teal) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(
                Modifier.fillMaxWidth().clickable(role = Role.Button, onClickLabel = "Opens the finished turn", onClick = actions.open).semantics {
                    customActions = buildList {
                        if (!busy) {
                            if (row.action(RowAction.Kind.CARRY_ON) != null) add(CustomAccessibilityAction("Looks good") { actions.looksGood(); true })
                            if (steer != null) add(CustomAccessibilityAction(steer.label) { actions.steer(); true })
                        }
                    }
                },
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(row.projectName, style = NW.Typo.mono, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(row.waitingText(now), style = NW.Typo.caption, color = NW.Palette.textTertiary.color, maxLines = 1)
                }
                val chips = TurnSummaryChips.parse(row.summary)
                if (chips.isEmpty()) Text(row.summary, style = NW.Typo.body, color = NW.Palette.textSecondary.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
                else FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) { chips.forEach { NWTurnChip(it) } }
            }
            if (busy) NWOutcomeStrip(status, now, actions.cancel)
            else Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                if (steer != null) NWButton(steer.label, actions.steer, Modifier.weight(1f))
                if (row.action(RowAction.Kind.CARRY_ON) != null) NWButton("Looks good ✦", actions.looksGood, Modifier.weight(1f), kind = NWButtonKind.BRIGHT)
                else if (row.action(RowAction.Kind.OPEN_ON_MAC) != null) NWButton("Open on Mac", actions.open, Modifier.weight(1f))
            }
        }
    }
}
