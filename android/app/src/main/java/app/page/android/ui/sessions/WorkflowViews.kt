package app.page.android.ui.sessions

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.SessionStore
import app.page.android.model.LiveSessionState
import app.page.android.model.RelativeTime
import app.page.android.model.TranscriptEntry
import app.page.android.model.TranscriptRole
import app.page.android.model.WorkflowRun
import app.page.android.ui.components.SectionTitle
import app.page.android.ui.components.StatusDot
import app.page.android.ui.components.WorkflowStatusChip
import app.page.android.ui.components.card
import app.page.android.ui.components.rememberNow
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors

// region Workflows list (a session's third pane)

/**
 * The session's dynamic workflows, as Claude Code's footer lists them, one
 * card each: name, status, progress, phase. Tapping opens the run.
 */
@Composable
fun WorkflowList(runs: List<WorkflowRun>, modifier: Modifier = Modifier, onOpen: (WorkflowRun) -> Unit) {
    LazyColumn(
        modifier,
        contentPadding = PaddingValues(horizontal = Space.l, vertical = Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        items(runs, key = { it.id }) { WorkflowCard(it) { onOpen(it) } }
    }
}

@Composable
fun WorkflowCard(run: WorkflowRun, onOpen: () -> Unit) {
    val now = rememberNow(30_000)
    val progress = run.progress(now)
    Column(
        Modifier
            .card()
            .clearAndSetSemantics {
                contentDescription = listOfNotNull(run.name, run.statusLabel, progress, run.phase).joinToString(", ")
                onClick(label = "Open the workflow") { onOpen(); true }
            }
            .clickable(role = Role.Button, onClick = onOpen),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Space.s)) {
            Text(run.name, style = PageType.mono13, color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            WorkflowStatusChip(run)
        }
        RunProgressBar(run)
        Row {
            Text(progress, style = PageType.caption12, color = colors.textMuted, modifier = Modifier.weight(1f))
            run.phase?.let { Text(it, style = PageType.caption12, color = colors.textMuted, maxLines = 1) }
        }
    }
}

@Composable
private fun RunProgressBar(run: WorkflowRun) {
    LinearProgressIndicator(
        progress = { if (run.total <= 0) 0f else (run.done.toFloat() / run.total).coerceIn(0f, 1f) },
        modifier = Modifier.fillMaxWidth().height(4.dp).clip(RoundedCornerShape(2.dp)),
        color = if (run.isRunning) colors.state(LiveSessionState.ACTIVE) else colors.textMuted,
        trackColor = colors.hairline,
        drawStopIndicator = {},
    )
}

// endregion

// region One run

/**
 * A workflow run: what it's for, its progress, and its agents (running
 * first). Tapping an agent shows what it's doing. Read-only: workflow agents
 * can't be typed into.
 */
@Composable
fun WorkflowRunScreen(sessionId: String, runId: String, onClose: () -> Unit) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    val live = state.workflows[sessionId]?.firstOrNull { it.id == runId }
    // Last known copy, so the screen stays readable if the run drops off.
    var snapshot by remember { mutableStateOf(live) }
    LaunchedEffect(live) { if (live != null) snapshot = live }
    val run = live ?: snapshot
    var openAgent by remember { mutableStateOf<WorkflowRun.Agent?>(null) }

    BackHandler(enabled = openAgent == null, onBack = onClose)

    Column(Modifier.fillMaxSize().background(colors.surface).statusBarsPadding().navigationBarsPadding()) {
        OverlayTopBar(run?.name ?: "Workflow", Icons.Filled.KeyboardArrowDown, "Close", onClose)
        if (run == null) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("This workflow is no longer listed.", style = PageType.body15, color = colors.textMuted)
            }
        } else {
            RunContent(run) { openAgent = it }
        }
    }

    openAgent?.let { agent ->
        AgentTranscriptScreen(sessionId, runId, agent) { openAgent = null }
    }
}

@Composable
private fun RunContent(run: WorkflowRun, onAgent: (WorkflowRun.Agent) -> Unit) {
    val now = rememberNow(30_000)
    val running = run.agents.filter { it.running }
    val done = run.agents.filter { it.state == "done" }
    val other = run.agents.filter { !it.running && it.state != "done" }
    LazyColumn(
        contentPadding = PaddingValues(horizontal = Space.l, vertical = Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        item {
            Column(Modifier.card(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    WorkflowStatusChip(run)
                    Spacer(Modifier.weight(1f))
                    Text(run.progress(now), style = PageType.caption12, color = colors.textMuted)
                }
                RunProgressBar(run)
                run.phase?.let { Text("Phase: $it", style = PageType.caption12, color = colors.textMuted) }
                run.summary?.let { SelectionContainer { Text(it, style = PageType.body15, color = colors.text) } }
            }
        }
        if (running.isNotEmpty()) agentSection("RUNNING · ${running.size}", running, now, onAgent)
        if (other.isNotEmpty()) agentSection("FAILED OR DIDN'T FINISH · ${other.size}", other, now, onAgent)
        if (done.isNotEmpty()) agentSection("DONE · ${done.size}", done, now, onAgent)
        if (run.agents.isEmpty()) item { Text("No agents have started yet.", style = PageType.body15, color = colors.textMuted) }
    }
}

private fun androidx.compose.foundation.lazy.LazyListScope.agentSection(
    title: String,
    agents: List<WorkflowRun.Agent>,
    now: java.time.Instant,
    onAgent: (WorkflowRun.Agent) -> Unit,
) {
    item(key = "t-$title") { SectionTitle(title, Modifier.padding(top = Space.s)) }
    item(key = "s-$title") {
        Column(Modifier.card(padding = 0.dp)) {
            agents.forEachIndexed { i, agent ->
                AgentRow(agent, now) { onAgent(agent) }
                if (i < agents.size - 1) Box(Modifier.fillMaxWidth().padding(start = 40.dp).height(1.dp).background(colors.hairline))
            }
        }
    }
}

@Composable
private fun AgentRow(agent: WorkflowRun.Agent, now: java.time.Instant, onClick: () -> Unit) {
    val stateWord = when {
        agent.running -> "running"
        agent.state == "done" -> "done"
        agent.state == "failed" -> "failed"
        else -> "didn't finish"
    }
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = MinTouch)
            .clickable(role = Role.Button, onClick = onClick)
            .clearAndSetSemantics {
                contentDescription = "${agent.label}, $stateWord"
                onClick(label = "Show what this agent is doing") { onClick(); true }
            }
            .padding(horizontal = Space.l, vertical = Space.m),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        StatusDot(
            when {
                agent.running -> colors.state(LiveSessionState.ACTIVE)
                agent.state == "failed" -> colors.destructiveText
                else -> colors.textMuted
            }
        )
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(agent.label, style = PageType.body15, color = colors.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            val meta = listOfNotNull(agent.phase, agent.lastActivityAt?.let { RelativeTime.ago(it, now) }).joinToString("  ")
            if (meta.isNotEmpty()) Text(meta, style = PageType.caption12, color = colors.textMuted)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(18.dp))
    }
}

// endregion

// region One agent

/**
 * What a workflow agent is doing: its last 40 transcript entries (its task,
 * its replies, one line per tool call), sent by the Mac while this screen is
 * open.
 */
@Composable
fun AgentTranscriptScreen(sessionId: String, runId: String, agent: WorkflowRun.Agent, onBack: () -> Unit) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    val transcript = state.agentTranscript(sessionId, runId, agent.id)
    val listState = rememberLazyListState()
    BackHandler(onBack = onBack)
    DisposableEffect(sessionId, runId, agent.id) {
        SessionStore.watchAgent(sessionId, runId, agent.id)
        onDispose { SessionStore.watchAgent(sessionId, null, null) }
    }
    LaunchedEffect(transcript?.entries?.size) {
        val n = transcript?.entries?.size ?: 0
        if (n > 0) listState.scrollToItem(n)
    }
    Column(Modifier.fillMaxSize().background(colors.surface).statusBarsPadding().navigationBarsPadding()) {
        OverlayTopBar(agent.label, Icons.AutoMirrored.Filled.ArrowBack, "Back", onBack)
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(horizontal = Space.l, vertical = Space.m),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (transcript == null) {
                item {
                    Row(
                        Modifier.fillMaxWidth().padding(top = 40.dp),
                        horizontalArrangement = Arrangement.spacedBy(Space.s, Alignment.CenterHorizontally),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.textMuted)
                        Text("Asking your Mac…", style = PageType.body15, color = colors.textMuted)
                    }
                }
            } else {
                if (transcript.truncated) item {
                    Text("Earlier steps aren't shown", style = PageType.caption12, color = colors.textMuted, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                }
                items(transcript.entries, key = { it.id }) { AgentEntryRow(it) }
                if (transcript.entries.isEmpty()) item { Text("Nothing yet.", style = PageType.body15, color = colors.textMuted) }
                item { Spacer(Modifier.height(1.dp)) }
            }
        }
    }
}

@Composable
private fun AgentEntryRow(entry: TranscriptEntry) {
    when (entry.role) {
        TranscriptRole.USER -> SelectionContainer {
            Text(
                entry.text, style = PageType.body15, color = colors.text,
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(colors.kindUserInput.copy(alpha = 0.12f)).padding(Space.m),
            )
        }
        TranscriptRole.ASSISTANT -> SelectionContainer { Text(entry.text, style = PageType.body15, color = colors.text) }
        TranscriptRole.TOOL -> Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.semantics { contentDescription = "Tool: ${entry.text}" },
        ) {
            Text("›", style = PageType.mono13, color = colors.textMuted)
            Text(entry.text, style = PageType.mono13, color = colors.textMuted, maxLines = 3, overflow = TextOverflow.Ellipsis)
        }
        TranscriptRole.SYSTEM -> Text(entry.text, style = PageType.caption12, color = colors.textMuted, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
}

// endregion

/** Title bar for the full-screen overlays: a leading close/back button and a centred title. */
@Composable
fun OverlayTopBar(title: String, icon: ImageVector, iconLabel: String, onClick: () -> Unit) {
    Column {
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s, vertical = Space.xs), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(MinTouch).clickable(role = Role.Button, onClick = onClick).semantics { contentDescription = iconLabel },
                contentAlignment = Alignment.Center,
            ) { Icon(icon, contentDescription = null, tint = colors.text) }
            Text(
                title, style = PageType.bodyEm, color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center, modifier = Modifier.weight(1f).semantics { heading() },
            )
            Spacer(Modifier.width(MinTouch))
        }
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
    }
}
