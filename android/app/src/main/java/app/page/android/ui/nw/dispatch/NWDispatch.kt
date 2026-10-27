@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package app.page.android.ui.nw.dispatch

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.Send
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.model.DeliveryPreview
import app.page.android.model.DispatchAgent
import app.page.android.model.DispatchAvailability
import app.page.android.model.DispatchDraft
import app.page.android.model.DispatchFolder
import app.page.android.model.DispatchStatus
import app.page.android.model.RunwayModel
import app.page.android.model.SessionComposer
import app.page.android.model.StartFolder
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.NWRunwayBar
import app.page.android.ui.nw.components.NWTextField
import app.page.android.ui.nw.components.color
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import java.time.Instant

data class DispatchScreenData(
    val macName: String,
    val availability: DispatchAvailability,
    val folders: List<StartFolder>,
    val now: Instant,
    val status: DispatchStatus? = null,
    val sending: Boolean = false,
    val runway: RunwayModel = RunwayModel.empty,
)

class DispatchScreenActions(
    val start: () -> Unit = {},
    val close: () -> Unit = {},
    val paste: () -> Unit = {},
    val openTower: () -> Unit = {},
    val retry: () -> Unit = {},
)

/**
 * DISPATCH: start new work. Where (a folder the Mac already knows), who (Claude; the other agents are started on
 * the Mac), what (an optional prompt) and when (now). The button always names the Mac. Starting goes through the
 * existing start path; the sheet says plainly where to look if nothing shows up. (iOS NWDispatchScreen.)
 */
@Composable
fun NWDispatchScreen(data: DispatchScreenData, actions: DispatchScreenActions, draft: DispatchDraft, onDraft: (DispatchDraft) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxSize().imePadding().verticalScroll(rememberScrollState()).padding(horizontal = NW.Space.xl).padding(top = 16.dp, bottom = 30.dp).navigationBarsPadding(), verticalArrangement = Arrangement.spacedBy(22.dp)) {
        Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.Top) {
            Text("Dispatch", style = NW.Typo.hero.copy(fontSize = 36.sp, letterSpacing = (-1).sp), color = NW.Palette.textPrimary.color, modifier = Modifier.weight(1f).semantics { heading() })
            Box(Modifier.size(48.dp).clip(CircleShape).clickable(role = Role.Button, onClickLabel = "Close", onClick = actions.close), contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.Close, "Close", tint = NW.Palette.textSecondary.color, modifier = Modifier.size(20.dp))
            }
        }
        when (val a = data.availability) {
            DispatchAvailability.Ready -> Form(data, actions, draft, onDraft)
            DispatchAvailability.Loading -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(18.dp), color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
                Text("Asking ${DeliveryPreview.macLabel(data.macName)}…", style = NW.Typo.body, color = NW.Palette.textSecondary.color)
            }
            DispatchAvailability.DisabledOnMac -> Problem("lock", "Starting sessions from your phone is off", "On your Mac, open Page → Settings → Phone and turn on “Let my phone start new Claude sessions”.")
            DispatchAvailability.NoFolders -> Problem("tray", "No folders yet", "Page hasn't seen Claude work in any folder in the last 30 days. Run claude in a project on your Mac once, and it appears here.")
            is DispatchAvailability.Failed -> Problem("wifi.exclamationmark", "Couldn't ask your Mac", a.why, "Try again" to actions.retry)
        }
    }
}

@Composable
private fun Label(text: String) { Text(text, style = NW.Typo.label, color = NW.Palette.textQuiet.color) }

@Composable
private fun Form(data: DispatchScreenData, actions: DispatchScreenActions, draft: DispatchDraft, onDraft: (DispatchDraft) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(22.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Label("WHERE")
            if (data.folders.size > 7) NWTextField(draft.search, { onDraft(draft.copy(search = it)) }, "Search folders", Modifier.fillMaxWidth(), maxLines = 1)
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                for (f in draft.visibleFolders(data.folders, data.now)) FolderChip(f, draft.selectedPath == f.path) { onDraft(draft.copy(selectedPath = f.path)) }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Label("WHO")
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) { for (a in DispatchAgent.entries) AgentCard(a, draft.agent == a, Modifier.weight(1f)) { onDraft(draft.copy(agent = a)) } }
        }
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Label("WHAT")
            val shape = RoundedCornerShape(16.dp)
            Column(Modifier.fillMaxWidth().clip(shape).background(Color.White.copy(alpha = 0.05f)).border(1.dp, Color.White.copy(alpha = 0.08f), shape).padding(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.heightIn(min = 72.dp)) {
                    if (draft.prompt.isEmpty()) Text("What should Claude do? (optional)", style = NW.Typo.body, color = NW.Palette.textQuiet.color)
                    BasicTextField(
                        draft.prompt, { onDraft(draft.copy(prompt = it)) }, Modifier.fillMaxWidth().semantics { contentDescription = "What should Claude do? Optional." },
                        textStyle = NW.Typo.body.copy(color = NW.Palette.textPrimary.color), cursorBrush = SolidColor(NW.Palette.teal.color), minLines = 3, maxLines = 8,
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(48.dp).clip(CircleShape).clickable(role = Role.Button, onClickLabel = "Paste", onClick = actions.paste), contentAlignment = Alignment.Center) {
                        Icon(Icons.Outlined.ContentPaste, "Paste", tint = NW.Palette.textTertiary.color, modifier = Modifier.size(20.dp))
                    }
                    Box(Modifier.weight(1f))
                    Text(draft.promptProblem ?: "optional · max ${SessionComposer.MAX_CHARACTERS}", style = NW.Typo.monoMicro, color = (if (draft.promptProblem == null) NW.Palette.textQuiet else NW.Palette.amber).color)
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Label("WHEN")
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Now", style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color, modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.12f)).padding(horizontal = 18.dp, vertical = 10.dp))
                Text("Starting later isn't available yet", style = NW.Typo.caption, color = NW.Palette.textQuiet.color)
            }
        }
        if (data.runway.markers.isNotEmpty() || !data.runway.onAC) NWGlassCard(Modifier.clickable(role = Role.Button, onClickLabel = "Opens the Tower at Budget", onClick = actions.openTower), radius = 20.dp, padding = PaddingValues(4.dp)) { NWRunwayBar(data.runway) }
        data.status?.let { StatusLine(it) }
        val can = draft.canStart(data.availability, data.sending)
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            NWButton(
                if (data.sending) "Starting…" else draft.startTitle(data.macName), actions.start, Modifier.fillMaxWidth(), kind = NWButtonKind.BRIGHT, enabled = can,
                leading = if (data.sending) null else Icons.Outlined.Send,
            )
            Text(DispatchDraft.footer(data.macName), style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun FolderChip(f: DispatchFolder, on: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.heightIn(min = 48.dp).clip(CircleShape).background(if (on) NW.Palette.teal.opacity(0.14).color else Color.White.copy(alpha = 0.05f))
            .border(if (on) 1.5.dp else 1.dp, if (on) NW.Palette.teal.opacity(0.7).color else Color.White.copy(alpha = 0.10f), CircleShape)
            .clickable(role = Role.RadioButton, onClick = onClick).padding(horizontal = 14.dp)
            .semantics { selected = on; contentDescription = f.name + (f.lastUsed?.let { ", used $it" } ?: "") },
        horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(9.dp).clip(CircleShape).background(f.hue.color.color))
        Text(f.name, style = NW.Typo.mono, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

private val claudeTint: Rgba = Rgba.hex(0xE89E64)

@Composable
private fun AgentCard(a: DispatchAgent, on: Boolean, modifier: Modifier, onClick: () -> Unit) {
    val enabled = a.canStartFromPhone
    val shape = RoundedCornerShape(16.dp)
    Column(
        modifier.heightIn(min = 92.dp).clip(shape).background(if (on) claudeTint.opacity(0.10).color else Color.White.copy(alpha = 0.04f))
            .border(1.dp, if (on) claudeTint.opacity(0.6).color else Color.White.copy(alpha = 0.08f), shape)
            .clickable(enabled = enabled, role = Role.RadioButton, onClick = onClick).padding(12.dp)
            .semantics(mergeDescendants = true) { selected = on; contentDescription = "${a.agentName}, ${a.note}" },
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Icon(nwIcon(a.symbol), null, tint = (if (enabled) claudeTint else NW.Palette.textQuiet).color, modifier = Modifier.size(24.dp))
        Text(a.agentName, style = NW.Typo.bodyStrong, color = (if (enabled) NW.Palette.textPrimary else NW.Palette.textTertiary).color)
        Text(a.note, style = NW.Typo.monoMicro, color = NW.Palette.textQuiet.color, maxLines = 2)
    }
}

@Composable
private fun StatusLine(s: DispatchStatus) {
    val tone = when (s.tone) { DispatchStatus.Tone.GOOD -> NW.Palette.teal; DispatchStatus.Tone.WORKING -> NW.Palette.textSecondary; else -> NW.Palette.amber }
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(NW.Radius.inset)).background(tone.opacity(0.08).color).padding(12.dp).semantics(mergeDescendants = true) {},
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top,
    ) {
        if (s.waiting) CircleProgress(tone) else Icon(if (s.tone == DispatchStatus.Tone.GOOD) nwIcon("checkmark.circle") else Icons.Outlined.ErrorOutline, null, tint = tone.color, modifier = Modifier.size(18.dp))
        Text(s.text, style = NW.Typo.caption, color = tone.color, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun CircleProgress(tone: Rgba) = CircularProgressIndicator(Modifier.size(16.dp), color = tone.color, strokeWidth = 2.dp)

@Composable
private fun Problem(symbol: String, title: String, text: String, action: Pair<String, () -> Unit>? = null) {
    NWGlassCard(tint = NW.Palette.amber) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(nwIcon(symbol), null, tint = NW.Palette.textPrimary.color, modifier = Modifier.size(22.dp))
                Text(title, style = NW.Typo.title, color = NW.Palette.textPrimary.color)
            }
            Text(text, style = NW.Typo.caption, color = NW.Palette.textSecondary.color)
            action?.let { NWButton(it.first, it.second, Modifier.fillMaxWidth()) }
        }
    }
}
