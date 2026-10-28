package app.page.android.ui.nw.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Schedule
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.size
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import app.page.android.model.SendReceipt
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.model.SendChoice
import app.page.android.model.SendWhen
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba

/**
 * How a message to a busy session goes: "Now" or "When it finishes", a compact two-way choice above Send (or, where
 * only one way exists, the one line that says what will happen). The first time it shows, each option is explained
 * in one short line underneath; after that the delivery preview carries it. Every segment is a 48 dp radio button.
 */
@Composable
fun NWSendChoice(plan: SendChoice.Plan, agent: String, explained: Boolean, onSelect: (SendWhen) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (plan.isChoice) {
            Row(
                Modifier.selectableGroup().clip(CircleShape).background(Color.White.copy(alpha = 0.07f)).border(1.dp, Color.White.copy(alpha = 0.10f), CircleShape).padding(3.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                for (option in plan.offered) {
                    val on = option == plan.selected
                    Box(
                        Modifier
                            .weight(1f).heightIn(min = 48.dp).clip(CircleShape)
                            .background(if (on) Color.White.copy(alpha = 0.16f) else Color.Transparent)
                            .clickable(role = Role.RadioButton, onClickLabel = option.explanation(agent)) { onSelect(option) }
                            .semantics {
                                selected = on
                                contentDescription = option.title
                                stateDescription = option.explanation(agent)
                            }
                            .padding(horizontal = 10.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(
                            option.title, style = NW.Typo.bodyStrong.copy(fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium),
                            color = (if (on) NW.Palette.textPrimary else NW.Palette.textTertiary).color, maxLines = 1, overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.clearAndSetSemantics {},
                        )
                    }
                }
            }
        }
        // First time only: what each side does, in one short line each. (A single option always says what it does.)
        if (!explained || !plan.isChoice) {
            for (option in if (plan.isChoice) plan.offered else listOf(plan.selected)) {
                Text(
                    (if (plan.isChoice) "${option.title}: " else "") + option.explanation(agent),
                    style = NW.Typo.caption, color = (if (option == plan.selected) NW.Palette.textSecondary else NW.Palette.textTertiary).color,
                    modifier = Modifier.padding(horizontal = 8.dp).semantics(mergeDescendants = true) {},
                )
            }
        }
    }
}

/**
 * A quiet word beside a receipt that can be acted on ("Undo", "Delete"): at least 48 dp tall, in the tone given.
 */
@Composable
fun NWReceiptAction(label: String, onClick: () -> Unit, modifier: Modifier = Modifier, tone: Rgba = NW.Palette.textPrimary, hint: String? = null) {
    Box(
        modifier.heightIn(min = 48.dp).widthIn(min = 48.dp).clip(RoundedCornerShape(12.dp))
            .clickable(role = Role.Button, onClickLabel = hint ?: label, onClick = onClick)
            .padding(horizontal = 10.dp)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, style = NW.Typo.bodyStrong, color = tone.color, maxLines = 1, modifier = Modifier.clearAndSetSemantics {})
    }
}

/**
 * The line under a composer after a send: where the message went, or what it is waiting for. A countdown carries Undo,
 * a held message Delete (48 dp, in the receipt's tone); a problem or a note can be dismissed.
 */
@Composable
fun NWSendReceiptView(r: SendReceipt, onAction: (SendReceipt) -> Unit, onDismiss: (String) -> Unit, modifier: Modifier = Modifier) {
    val tone = when (r.tone) {
        SendReceipt.Tone.GOOD -> NW.Palette.teal
        SendReceipt.Tone.PROBLEM, SendReceipt.Tone.HELD -> NW.Palette.amber
        SendReceipt.Tone.NOTE -> NW.Palette.textSecondary
        SendReceipt.Tone.WORKING -> NW.Palette.textSecondary
    }
    val dismissible = r.tone == SendReceipt.Tone.PROBLEM || r.tone == SendReceipt.Tone.NOTE
    Row(
        modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(tone.opacity(0.09).color).padding(start = 14.dp, top = 4.dp, bottom = 4.dp, end = 4.dp)
            .semantics(mergeDescendants = true) {
                liveRegion = LiveRegionMode.Polite
                // A ticking receipt reads its steady line, so the live region speaks it once.
                val said = r.spoken ?: if (r.action != null) listOfNotNull(r.headline, r.detail).joinToString(". ") else null
                if (said != null) contentDescription = said
            },
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        when {
            // Photos going up have a fraction: the ring fills as the pieces are accepted.
            r.tone == SendReceipt.Tone.WORKING && r.action == null && r.progress != null -> CircularProgressIndicator({ r.progress!!.toFloat() }, Modifier.size(16.dp), color = tone.color, strokeWidth = 2.dp, trackColor = tone.opacity(0.25).color)
            r.tone == SendReceipt.Tone.WORKING && r.action == null -> CircularProgressIndicator(Modifier.size(16.dp), color = tone.color, strokeWidth = 2.dp)
            r.tone == SendReceipt.Tone.WORKING -> NWRing(r.progress ?: 1.0, tone, lineWidth = 2.5.dp, size = 20.dp)
            r.tone == SendReceipt.Tone.HELD -> Icon(Icons.Outlined.Schedule, null, tint = tone.color, modifier = Modifier.size(18.dp))
            r.tone == SendReceipt.Tone.NOTE -> Icon(Icons.Outlined.Info, null, tint = tone.color, modifier = Modifier.size(18.dp))
            else -> Icon(if (r.tone == SendReceipt.Tone.GOOD) nwIcon("checkmark.circle") else Icons.Outlined.ErrorOutline, null, tint = tone.color, modifier = Modifier.size(18.dp))
        }
        Column(Modifier.weight(1f).padding(vertical = 6.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(r.headline, style = NW.Typo.captionStrong, color = tone.color)
            r.detail?.let { Text(it, style = NW.Typo.monoMicro, color = NW.Palette.textTertiary.color) }
        }
        r.action?.let { a ->
            // Undo is the room's own word; Delete is the warning red. Both are 48 dp.
            NWReceiptAction(
                a.label, { onAction(r) },
                tone = if (a == SendReceipt.Action.DELETE) NW.Palette.red.mixed(NW.Palette.white, 0.2) else NW.Palette.textPrimary,
                hint = if (a == SendReceipt.Action.UNDO) "Puts your message back in the box. Nothing is sent." else "Takes the held message back. Nothing is typed.",
            )
        }
        if (dismissible) Box(Modifier.size(48.dp).clickable(role = Role.Button, onClickLabel = "Dismiss") { onDismiss(r.id) }, contentAlignment = Alignment.Center) {
            Icon(Icons.Outlined.Close, "Dismiss", tint = NW.Palette.textTertiary.color, modifier = Modifier.size(16.dp))
        }
    }
}

