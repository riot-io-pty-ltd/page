package app.page.android.ui.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.WrapText
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import app.page.android.data.AppGraph
import app.page.android.model.SessionScreen
import app.page.android.model.TerminalRunLinks
import app.page.android.model.WorkflowRun
import app.page.android.ui.components.rememberNow
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors

/**
 * The session's screen as the Mac last read it, in monospace, pinned to the
 * bottom where the footer is (iOS TerminalMirror). Wrap (the default,
 * remembered) folds long lines to the screen's width so the right-hand
 * columns — a workflow's counts, time and tokens — show without scrolling
 * sideways; off, lines stay as on the Mac and the view scrolls both ways.
 * Rows that are only rules (────) never wrap. A row naming one of the
 * session's workflows opens it.
 */
@Composable
fun TerminalMirror(screen: SessionScreen, runs: List<WorkflowRun>, modifier: Modifier = Modifier, onOpenRun: (WorkflowRun) -> Unit) {
    var wrap by remember { mutableStateOf(AppGraph.prefs.terminalWrap) }
    val links = remember(screen.lines, runs) { TerminalRunLinks.match(screen.lines, runs) }
    val vertical = rememberScrollState()
    val horizontal = rememberScrollState()
    // Pinned to the bottom: on every new screen and when Wrap flips.
    LaunchedEffect(screen.lines, wrap) { vertical.scrollTo(vertical.maxValue) }
    LaunchedEffect(vertical.maxValue) { vertical.scrollTo(vertical.maxValue) }

    Column(modifier) {
        Box(
            Modifier
                .weight(1f)
                .fillMaxWidth()
                .background(colors.surfaceInset)
                .verticalScroll(vertical)
                .then(if (wrap) Modifier else Modifier.horizontalScroll(horizontal))
                .padding(Space.m)
        ) {
            SelectionContainer {
                Column {
                    screen.lines.forEachIndexed { i, line -> TerminalLine(line, links[i], wrap, onOpenRun) }
                }
            }
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Space.l, vertical = Space.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val now = rememberNow(5_000)
            Text(
                "Mirrored from your Mac · ${SessionScreen.age(screen.at, now)}",
                style = PageType.caption12, color = colors.textMuted, modifier = Modifier.weight(1f),
            )
            WrapToggle(wrap) {
                wrap = it
                AppGraph.prefs.terminalWrap = it
            }
        }
    }
}

@Composable
private fun TerminalLine(line: String, run: WorkflowRun?, wrap: Boolean, onOpenRun: (WorkflowRun) -> Unit) {
    val rule = SessionScreen.isRule(line)
    val textModifier = if (run != null) {
        Modifier
            .fillMaxWidth()
            .clickable(role = Role.Button) { onOpenRun(run) }
            .clearAndSetSemantics {
                contentDescription = "Workflow ${run.name}, ${run.progress(java.time.Instant.now())}"
                role = Role.Button
                onClick(label = "Open the workflow") { onOpenRun(run); true }
            }
    } else {
        Modifier
    }
    Text(
        line.ifEmpty { " " },
        style = PageType.mono11,
        color = if (run == null) colors.text else colors.kindUserInput,
        softWrap = wrap && !rule,
        maxLines = if (wrap && !rule) Int.MAX_VALUE else 1,
        overflow = if (wrap) TextOverflow.Clip else TextOverflow.Visible,
        modifier = textModifier,
    )
}

@Composable
private fun WrapToggle(on: Boolean, onChange: (Boolean) -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Row(
        Modifier
            .heightIn(min = MinTouch)
            .toggleable(value = on, role = Role.Switch, onValueChange = onChange)
            .clearAndSetSemantics {
                contentDescription = "Wrap long lines, ${if (on) "on" else "off"}"
                role = Role.Switch
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier
                .clip(shape)
                .then(if (on) Modifier.background(colors.kindUserInput.copy(alpha = 0.16f)) else Modifier)
                .border(1.dp, if (on) colors.kindUserInput.copy(alpha = 0.5f) else colors.hairline, shape)
                .padding(horizontal = 10.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(Icons.AutoMirrored.Filled.WrapText, contentDescription = null, tint = if (on) colors.kindUserInput else colors.textMuted, modifier = Modifier.size(14.dp))
            Text("Wrap", style = PageType.caption12, color = if (on) colors.kindUserInput else colors.textMuted)
        }
    }
}
