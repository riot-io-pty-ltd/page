package app.page.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.dp
import app.page.android.model.AgentBackend
import app.page.android.model.InterventionBackend
import app.page.android.model.InterventionKind
import app.page.android.model.InterventionSource
import app.page.android.model.LiveSessionState
import app.page.android.model.WorkflowRun
import app.page.android.model.chipLabel
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.colors

private val Capsule = RoundedCornerShape(50)

/** Outlined capsule with a tint: the shared shape of every chip. */
@Composable
private fun OutlinedChip(tint: Color, spoken: String, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Row(
        modifier
            .border(1.dp, tint, Capsule)
            .padding(horizontal = 8.dp, vertical = 3.dp)
            .clearAndSetSemantics { contentDescription = spoken },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) { content() }
}

@Composable
fun KindChip(kind: InterventionKind, subtype: String? = null) {
    val text = chipLabel(kind, subtype)
    val tint = colors.kind(kind)
    OutlinedChip(tint, kind.accessibilityName) {
        Text(text, style = PageType.chip11, color = tint, maxLines = 1)
    }
}

/** A live session's state: dot plus label, in the state's colour. */
@Composable
fun SessionStateChip(state: LiveSessionState) {
    val tint = colors.state(state)
    OutlinedChip(tint.copy(alpha = 0.6f), "State: ${state.label}") {
        StatusDot(tint)
        Text(state.label.uppercase(), style = PageType.chip11, color = tint, maxLines = 1)
    }
}

@Composable
fun WorkflowStatusChip(run: WorkflowRun) {
    val tint = when (run.status) {
        "running" -> colors.state(LiveSessionState.ACTIVE)
        "failed" -> colors.destructiveText
        "stalled" -> colors.warning
        else -> colors.textMuted
    }
    OutlinedChip(tint.copy(alpha = 0.6f), "Status: ${run.statusLabel}") {
        StatusDot(tint)
        Text(run.statusLabel.uppercase(), style = PageType.chip11, color = tint, maxLines = 1)
    }
}

/** Backend badge plus the surface or host it runs in. */
@Composable
private fun BackendPillContent(badge: String, name: String, tint: Color, surface: String, spokenSurface: String) {
    Row(
        Modifier
            .background(tint.copy(alpha = 0.12f), Capsule)
            .border(1.dp, tint.copy(alpha = 0.5f), Capsule)
            .padding(horizontal = 10.dp, vertical = 4.dp)
            .clearAndSetSemantics { contentDescription = "$name, $spokenSurface" },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(badge, style = PageType.chip11, color = tint, maxLines = 1)
        Text(surface, style = PageType.caption12, color = tint, maxLines = 1)
    }
}

@Composable
fun BackendPill(backend: InterventionBackend, source: InterventionSource?) {
    BackendPillContent(
        badge = backend.badge, name = backend.displayName, tint = colors.backend(backend),
        surface = source?.label ?: InterventionSource.UNKNOWN.label, spokenSurface = source?.label ?: "unknown surface",
    )
}

/** A live session: any backend (unknown ones get a neutral tint), and the terminal or app hosting it. */
@Composable
fun AgentPill(agent: AgentBackend, host: String) {
    BackendPillContent(agent.badge, agent.displayName, colors.agent(agent), host, host)
}
