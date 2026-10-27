package app.page.android.ui.nw.room

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.WrapText
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.data.AppGraph
import app.page.android.model.AgentRoomModel
import app.page.android.model.ChangesModel
import app.page.android.model.RelativeTime
import app.page.android.model.ScreenFreshness
import app.page.android.model.StoryBlock
import app.page.android.model.TerminalRunLinks
import app.page.android.model.TerminalTone
import app.page.android.model.WorkflowOrbit
import app.page.android.model.WorkflowRun
import app.page.android.ui.nw.components.NWAnswerHost
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWBackdrop
import app.page.android.ui.nw.components.NWDeliveryPreview
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.now.NWOutcomeStrip
import app.page.android.ui.nw.now.RowStatus
import app.page.android.ui.nw.theme.NW
import app.page.android.ui.nw.theme.Rgba
import java.time.Instant
import kotlin.math.cos
import kotlin.math.sin

// The room's other three lenses: Screen (the Mac's mirror of the terminal), Changes (what the turn changed, with
// the diff) and Workflows (a run as a ring of agent nodes). All of them are read-only; the only thing they can ask
// for is more of what the Mac already sends. (iOS NWRoomLenses.)

// MARK: - Screen

val TerminalTone.color: Rgba
    get() = when (this) {
        TerminalTone.TOOL -> NW.Palette.green
        TerminalTone.BUSY -> Rgba.hex(0xE89E64)
        TerminalTone.FOOTER -> NW.Palette.violet
        TerminalTone.PROMPT -> NW.Palette.textPrimary
        TerminalTone.QUIET -> NW.Palette.textQuiet
        TerminalTone.PLAIN -> NW.Palette.textSecondary
    }

/**
 * The session's screen as the Mac last read it, in a monospace face on dark glass, following the bottom where the
 * footer is. Wrap (remembered) folds long lines so a workflow row's counts show; off, lines stay as on the Mac. A
 * row naming one of the session's workflows opens it. There are no key buttons here: the room's only keyboard is
 * its composer.
 */
@Composable
fun NWRoomScreenLens(data: SessionRoomData, actions: SessionRoomActions, modifier: Modifier = Modifier) {
    var wrap by remember { mutableStateOf(AppGraph.prefs.terminalWrap) }
    Box(modifier.fillMaxSize()) {
        val screen = data.screen
        if (screen != null) {
            Column(Modifier.fillMaxSize().padding(horizontal = NW.Space.lg).padding(top = 8.dp, bottom = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                    data.screenFreshness?.let { f ->
                        val c = when (f.tone) { ScreenFreshness.Tone.LIVE -> NW.Palette.teal; ScreenFreshness.Tone.SLOW -> NW.Palette.amber; else -> NW.Palette.textTertiary }
                        Row(
                            Modifier.heightIn(min = 38.dp).clip(CircleShape).background(c.opacity(0.12).color).padding(horizontal = 14.dp)
                                .clearAndSetSemantics { contentDescription = if (f.tone == ScreenFreshness.Tone.SLOW) "Screen is slow, ${f.label}" else "Screen ${f.label}" },
                            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Box(Modifier.size(9.dp).clip(CircleShape).background(c.color))
                            Text(f.label, style = NW.Typo.captionStrong, color = c.color)
                        }
                    }
                    Text(data.session.hostLabel, style = NW.Typo.monoSmall, color = NW.Palette.textTertiary.color, maxLines = 1, modifier = Modifier.weight(1f))
                    Box(
                        Modifier.size(48.dp).clip(RoundedCornerShape(14.dp)).background(if (wrap) NW.Palette.teal.opacity(0.14).color else Color.White.copy(alpha = 0.07f))
                            .clickable(role = Role.Button, onClickLabel = if (wrap) "Don't wrap lines" else "Wrap lines") { wrap = !wrap; AppGraph.prefs.terminalWrap = wrap },
                        contentAlignment = Alignment.Center,
                    ) { Icon(Icons.Outlined.WrapText, null, tint = (if (wrap) NW.Palette.teal else NW.Palette.textSecondary).color, modifier = Modifier.size(22.dp)) }
                }
                Terminal(screen.lines, data.runs, wrap, actions, Modifier.weight(1f))
                Text(
                    if (data.runs.isEmpty()) "Redacted before it leaves the Mac" else "Tap a workflow row to open it · redacted before it leaves the Mac",
                    style = NW.Typo.caption, color = NW.Palette.textTertiary.color, modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                )
            }
        } else {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("The screen appears once your Mac sends it.", style = NW.Typo.body, color = NW.Palette.textTertiary.color) }
        }
        // The question the terminal is asking, answerable over its own screen.
        data.ask?.let { ask ->
            Box(Modifier.align(Alignment.BottomCenter).padding(horizontal = NW.Space.md).padding(bottom = 8.dp)) {
                NWAnswerHost(ask, delivery = data.askDelivery, route = data.answerRoute, mac = data.macName, agent = data.character.name, compact = true, viaHook = data.askViaHook, onSubmit = actions.submitAnswers)
            }
        }
    }
}

/** Claude Code's glyphs the phone's monospace font lacks (they would draw as emoji or empty boxes) as plain ones with the same meaning. */
private fun displayLine(line: String): String = line.replace('\u23FA', '\u25CF').replace('\u23F5', '\u25B8').replace('\u23F8', '\u2016')

@Composable
private fun Terminal(lines: List<String>, runs: List<WorkflowRun>, wrap: Boolean, actions: SessionRoomActions, modifier: Modifier) {
    val links = TerminalRunLinks.match(lines, runs)
    val vertical = rememberScrollState()
    val horizontal = rememberScrollState()
    LaunchedEffect(lines, wrap) { vertical.scrollTo(vertical.maxValue) }
    val shape = RoundedCornerShape(24.dp)
    Box(modifier.fillMaxWidth().clip(shape).background(NW.Palette.inset.opacity(0.95).color, shape).border(1.dp, Color.White.copy(alpha = 0.07f), shape)) {
        Column(
            Modifier.fillMaxSize().verticalScroll(vertical).then(if (wrap) Modifier else Modifier.horizontalScroll(horizontal)).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            SelectionContainer {
                Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    lines.forEachIndexed { i, line ->
                        val run = links[i]
                        val tone = if (run == null) TerminalTone.classify(line) else TerminalTone.FOOTER
                        val text: @Composable () -> Unit = {
                            Text(
                                if (line.isEmpty()) " " else displayLine(line), style = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.sp, lineHeight = 17.sp), color = tone.color.color,
                                softWrap = wrap && tone != TerminalTone.QUIET, maxLines = if (wrap && tone != TerminalTone.QUIET) Int.MAX_VALUE else 1,
                                overflow = TextOverflow.Clip,
                            )
                        }
                        if (run != null) Box(
                            Modifier.clip(RoundedCornerShape(6.dp)).background(NW.Palette.teal.opacity(0.10).color)
                                .clickable(role = Role.Button, onClickLabel = "Opens the workflow") { actions.openRun(run.id) }.heightIn(min = 32.dp).padding(horizontal = 6.dp, vertical = 3.dp)
                                .semantics { contentDescription = "Workflow ${run.name}, ${run.done} of ${run.total}" },
                            contentAlignment = Alignment.CenterStart,
                        ) { text() } else text()
                    }
                }
            }
        }
    }
}

// MARK: - Changes

/** The Changes lens: the Mac's answer to "what did this turn change", or what it is still doing about it. One scope comes back, so the scope is a label, not a switch. */
@Composable
fun NWRoomChangesLens(data: SessionRoomData, actions: SessionRoomActions, modifier: Modifier = Modifier) {
    NWChangesPanel(data.changes, data.changesLoad, onRefresh = actions.refreshChanges, onCopy = actions.copy, modifier = modifier) {
        val row = data.reviewRow
        if (row != null && data.pageOutcome == app.page.android.model.CardOutcome.None && row.action(app.page.android.model.RowAction.Kind.CARRY_ON) != null) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                NWButton("Looks good ✦", { actions.looksGood(row) }, Modifier.fillMaxWidth(), kind = NWButtonKind.BRIGHT)
                row.action(app.page.android.model.RowAction.Kind.CARRY_ON)?.preview?.let { NWDeliveryPreview(it) }
            }
        } else if (row != null && data.pageOutcome != app.page.android.model.CardOutcome.None) {
            NWOutcomeStrip(RowStatus(data.pageOutcome, data.pagePending, null), data.now, { actions.cancel(row.id) })
        }
    }
}

private val removedColor: Rgba = NW.Palette.red.mixed(NW.Palette.amber, 0.45)

/** The files a turn changed with +/- counts, a bar of the proportion and each file's diff (the first one open). Shared by the room's Changes lens and the changes sheet a finished-turn page opens. */
@Composable
fun NWChangesPanel(model: ChangesModel?, load: ChangesModel.Load, onRefresh: () -> Unit = {}, onCopy: (String) -> Unit = {}, modifier: Modifier = Modifier, footer: @Composable () -> Unit = {}) {
    when (load) {
        ChangesModel.Load.Loaded -> if (model != null) ChangesContent(model, onRefresh, onCopy, modifier, footer) else Message("No answer from your Mac.", true, onRefresh, modifier)
        ChangesModel.Load.Loading -> Column(modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            CircularProgressIndicator(Modifier.size(24.dp), color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
            Text("Asking your Mac…", style = NW.Typo.body, color = NW.Palette.textTertiary.color, modifier = Modifier.padding(top = 12.dp))
        }
        ChangesModel.Load.NoAnswer -> Message("No answer from your Mac. Tap Refresh to try again.", true, onRefresh, modifier)
        is ChangesModel.Load.Failed -> Message(load.why, true, onRefresh, modifier)
    }
}

@Composable
private fun Message(text: String, retry: Boolean, onRefresh: () -> Unit, modifier: Modifier) {
    Column(modifier.fillMaxSize().padding(horizontal = 32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterVertically)) {
        Text(text, style = NW.Typo.body, color = NW.Palette.textSecondary.color, textAlign = TextAlign.Center)
        if (retry) NWButton("Refresh", onRefresh, Modifier.widthIn(max = 200.dp).fillMaxWidth())
    }
}

@Composable
private fun ChangesContent(m: ChangesModel, onRefresh: () -> Unit, onCopy: (String) -> Unit, modifier: Modifier, footer: @Composable () -> Unit) {
    var opened by remember(m.files.firstOrNull()?.path) { mutableStateOf(m.files.firstOrNull()?.path?.let { setOf(it) } ?: emptySet()) }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = NW.Space.lg).padding(top = 8.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(m.scopeLabel, style = NW.Typo.label, color = NW.Palette.textTertiary.color)
            m.repo?.let { Text(it, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false)) }
            Box(Modifier.weight(1f))
            Box(Modifier.size(48.dp).clickable(role = Role.Button, onClickLabel = "Refresh", onClick = onRefresh), contentAlignment = Alignment.Center) {
                Icon(Icons.Outlined.Refresh, "Refresh", tint = NW.Palette.textSecondary.color, modifier = Modifier.size(20.dp))
            }
        }
        // Evidence chips
        Row(Modifier.semantics(mergeDescendants = true) { contentDescription = "${m.fileCountText}, ${m.added} added, ${m.removed} removed" }, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            EvidenceChip(m.fileCountText, NW.Palette.textPrimary, mono = false)
            EvidenceChip("+${m.added}", NW.Palette.green)
            EvidenceChip("−${m.removed}", removedColor)
        }
        // The bar
        Row(Modifier.fillMaxWidth().height(6.dp).clearAndSetSemantics {}, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Box(Modifier.weight(maxOf(0.02f, m.addedFraction.toFloat())).height(6.dp).clip(CircleShape).background(NW.Palette.green.color))
            if (m.removed > 0) Box(Modifier.weight(maxOf(0.02f, (1 - m.addedFraction).toFloat())).height(6.dp).clip(CircleShape).background(removedColor.color))
        }
        m.note?.let { Text(it, style = NW.Typo.body, color = NW.Palette.textSecondary.color) }
        m.emptyText?.let { Text(it, style = NW.Typo.body, color = NW.Palette.textTertiary.color) }
        if (m.files.isNotEmpty()) {
            val clip = androidx.compose.ui.platform.LocalClipboardManager.current
            NWGlassCard(radius = 20.dp, padding = PaddingValues(0.dp)) {
                m.files.forEachIndexed { i, f ->
                    val on = f.path in opened
                    val section = m.sections.firstOrNull { it.path == f.path }
                    Column {
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 52.dp).clickable(role = Role.Button, onClickLabel = if (on) "Hides the diff" else "Shows the diff") { opened = if (on) opened - f.path else opened + f.path }
                                .padding(horizontal = 16.dp).semantics(mergeDescendants = true) { contentDescription = "${f.path}, ${f.added?.let { "$it added" } ?: ""}" },
                            horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Icon(if (on) Icons.Outlined.ExpandMore else Icons.Outlined.KeyboardArrowRight, null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(18.dp))
                            Text(f.path, style = NW.Typo.monoBody, color = NW.Palette.textPrimary.color, maxLines = 1, overflow = TextOverflow.StartEllipsis(), modifier = Modifier.weight(1f))
                            f.added?.let { Text("+$it", style = NW.Typo.monoSmall, color = NW.Palette.green.color) }
                            f.removed?.let { Text("−$it", style = NW.Typo.monoSmall, color = removedColor.color) }
                        }
                        if (on && section != null) DiffBlock(section.lines)
                        if (i < m.files.size - 1) Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.06f)))
                    }
                }
            }
        }
        for (sec in m.unmatchedSections) Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(if (sec.path.isEmpty()) "Patch" else sec.path, style = NW.Typo.monoSmall, color = NW.Palette.textSecondary.color, maxLines = 1)
            DiffBlock(sec.lines)
        }
        if (m.truncated) Text("Cut short to fit — the rest is on your Mac.", style = NW.Typo.caption, color = NW.Palette.textTertiary.color, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        footer()
    }
}

@Composable
private fun EvidenceChip(text: String, c: Rgba, mono: Boolean = true) {
    Text(
        text, style = (if (mono) NW.Typo.monoBody else NW.Typo.bodyStrong).copy(fontWeight = FontWeight.SemiBold, fontSize = 14.sp), color = c.color,
        modifier = Modifier.heightIn(min = 40.dp).clip(RoundedCornerShape(14.dp)).background(c.opacity(if (mono) 0.13 else 0.08).color).padding(horizontal = 14.dp).padding(vertical = 9.dp),
    )
}

/** A file's unified diff: hunk headers quiet, additions green, removals warm, in a monospace face. Lines never wrap, so columns stay aligned; scroll sideways. */
@Composable
fun DiffBlock(lines: List<String>) {
    Column(Modifier.padding(horizontal = 10.dp).padding(bottom = 10.dp).fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(NW.Palette.inset.opacity(0.9).color).horizontalScroll(rememberScrollState())) {
        SelectionContainer {
            Column(Modifier.widthIn(min = 300.dp)) {
                for (line in lines) {
                    val kind = ChangesModel.lineKind(line)
                    val c = when (kind) { ChangesModel.LineKind.HUNK -> NW.Palette.textTertiary; ChangesModel.LineKind.ADDED -> NW.Palette.green; ChangesModel.LineKind.REMOVED -> removedColor; else -> NW.Palette.textSecondary }
                    val bg = when (kind) { ChangesModel.LineKind.ADDED -> NW.Palette.green.opacity(0.10).color; ChangesModel.LineKind.REMOVED -> NW.Palette.red.opacity(0.10).color; else -> Color.Transparent }
                    Row(Modifier.background(bg).padding(vertical = 5.dp, horizontal = 8.dp)) {
                        Text(if (kind == ChangesModel.LineKind.ADDED) "+" else if (kind == ChangesModel.LineKind.REMOVED) "−" else " ", style = DiffStyle, color = c.color, modifier = Modifier.width(22.dp))
                        Text(
                            if (line.isEmpty()) " " else if (kind == ChangesModel.LineKind.ADDED || kind == ChangesModel.LineKind.REMOVED) line.drop(1) else line,
                            style = DiffStyle, color = c.color, softWrap = false, maxLines = 1,
                        )
                    }
                }
            }
        }
    }
}

private val DiffStyle = androidx.compose.ui.text.TextStyle(fontFamily = FontFamily.Monospace, fontSize = 12.5.sp, lineHeight = 17.sp)

@Suppress("FunctionName")
private fun TextOverflow.Companion.StartEllipsis(): TextOverflow = TextOverflow.Ellipsis

// MARK: - Workflows

val WorkflowOrbit.NodeState.color: Rgba
    get() = when (this) {
        WorkflowOrbit.NodeState.RUNNING -> NW.Palette.teal
        WorkflowOrbit.NodeState.DONE -> NW.Palette.green
        // A failed agent is amber: red is for two hold rings only.
        WorkflowOrbit.NodeState.FAILED -> NW.Palette.amber
        WorkflowOrbit.NodeState.STOPPED -> Rgba.hex(0x8A8FA0)
    }

private fun WorkflowOrbit.NodeState.spoken(): String = when (this) {
    WorkflowOrbit.NodeState.RUNNING -> "running"
    WorkflowOrbit.NodeState.DONE -> "done"
    WorkflowOrbit.NodeState.FAILED -> "failed"
    WorkflowOrbit.NodeState.STOPPED -> "didn't finish"
}

/** The multi-agent run as a ring of nodes with "4/7 agents done" in the middle. Tap a node for that agent's transcript. */
@Composable
fun NWWorkflowOrbit(orbit: WorkflowOrbit, onAgent: (String) -> Unit, modifier: Modifier = Modifier) {
    val size = 300.dp
    val radius = size / 2 - 18.dp
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Box(Modifier.size(size), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(size).clearAndSetSemantics {}) {
                val c = Offset(this.size.width / 2, this.size.height / 2)
                val r = radius.toPx()
                drawCircle(Color.White.copy(alpha = 0.07f), r, c, style = Stroke(1.dp.toPx()))
                val rr = r * 0.55f
                drawCircle(Color.White.copy(alpha = 0.07f), rr, c, style = Stroke(12.dp.toPx()))
                val f = if (orbit.total > 0) orbit.done.toFloat() / orbit.total else 0f
                drawArc(NW.Palette.teal.opacity(0.25).color, -90f, 360f * f, false, Offset(c.x - rr, c.y - rr), androidx.compose.ui.geometry.Size(rr * 2, rr * 2), style = Stroke(16.dp.toPx(), cap = StrokeCap.Round))
                drawArc(NW.Palette.teal.color, -90f, 360f * f, false, Offset(c.x - rr, c.y - rr), androidx.compose.ui.geometry.Size(rr * 2, rr * 2), style = Stroke(12.dp.toPx(), cap = StrokeCap.Round))
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.clearAndSetSemantics {}) {
                Text(orbit.centre, style = NW.Typo.hero.copy(fontFamily = FontFamily.Monospace, fontSize = 34.sp), color = NW.Palette.textPrimary.color)
                Text(orbit.caption, style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
            }
            for (n in orbit.nodes) {
                val x = (sin(n.angle) * radius.value).dp
                val y = (-cos(n.angle) * radius.value).dp
                val running = n.state == WorkflowOrbit.NodeState.RUNNING
                Box(
                    Modifier.offset(x, y).size(48.dp).clip(CircleShape).clickable(role = Role.Button, onClickLabel = "Opens this agent's transcript") { onAgent(n.id) }.semantics { contentDescription = "${n.label}, ${n.state.spoken()}" },
                    contentAlignment = Alignment.Center,
                ) {
                    Box(Modifier.size(if (running) 30.dp else 22.dp).clip(CircleShape).background(n.state.color.opacity(0.25).color))
                    Box(Modifier.size(if (running) 20.dp else 15.dp).clip(CircleShape).background(n.state.color.color))
                }
            }
        }
    }
}

/** The Workflows lens: the run as its orbit, then its agents grouped as the footer counts them. The footer's own rows in Screen open here too. */
@Composable
fun NWRoomWorkflowsLens(data: SessionRoomData, actions: SessionRoomActions, runId: String?, onRunId: (String?) -> Unit, modifier: Modifier = Modifier) {
    val run = data.runs.firstOrNull { it.id == runId } ?: data.runs.firstOrNull()
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = NW.Space.lg).padding(top = 8.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (data.runs.size > 1) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (r in data.runs) {
                val on = r.id == run?.id
                Row(
                    Modifier.heightIn(min = 48.dp).clip(CircleShape).background(if (on) Color.White.copy(alpha = 0.13f) else Color.White.copy(alpha = 0.05f)).clickable(role = Role.Tab) { onRunId(r.id) }.padding(horizontal = 14.dp).semantics { selected = on },
                    horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background((if (r.isRunning) NW.Palette.teal else NW.Palette.textTertiary).color))
                    Text(r.name, style = NW.Typo.monoSmall, color = (if (on) NW.Palette.textPrimary else NW.Palette.textSecondary).color, maxLines = 1)
                }
            }
        }
        if (run != null) {
            val orbit = WorkflowOrbit.build(run, data.now)
            NWGlassCard(radius = 28.dp, padding = PaddingValues(18.dp), tint = if (run.isRunning) NW.Palette.teal else null) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Row(verticalAlignment = Alignment.Top) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(run.name, style = NW.Typo.title.copy(fontFamily = FontFamily.Monospace), color = NW.Palette.textPrimary.color, maxLines = 2)
                            if (orbit.meta.isNotEmpty()) Text(orbit.meta, style = NW.Typo.subline, color = NW.Palette.textTertiary.color)
                        }
                        RunChip(run)
                    }
                    run.summary?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.textSecondary.color, modifier = Modifier.padding(top = 2.dp)) }
                    NWWorkflowOrbit(orbit, { actions.openAgent(run.id, it) }, Modifier.padding(top = 8.dp))
                }
            }
            Agents(run, data.now, actions)
        }
        WorkflowOrbit.finishedLine(data.runs, data.now)?.let { line ->
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.045f)).padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(nwIcon("checkmark.circle"), null, tint = NW.Palette.teal.color, modifier = Modifier.size(20.dp))
                Text(line, style = NW.Typo.body, color = NW.Palette.textSecondary.color, maxLines = 2)
            }
        }
        Text("Workflow agents are read-only · tap one to watch its transcript", style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
}

@Composable
private fun RunChip(run: WorkflowRun) {
    val c = if (run.isRunning) NW.Palette.teal else if (run.status == "failed" || run.status == "stalled") NW.Palette.amber else NW.Palette.textSecondary
    Row(Modifier.heightIn(min = 34.dp).clip(CircleShape).background(c.opacity(0.14).color).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(c.color))
        Text(run.statusLabel.uppercase(), style = NW.Typo.label, color = c.color)
    }
}

@Composable
private fun Agents(run: WorkflowRun, now: Instant, actions: SessionRoomActions) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        for ((title, agents) in WorkflowOrbit.groups(run)) {
            Text("${title.uppercase()} · ${agents.size}", style = NW.Typo.label, color = NW.Palette.textQuiet.color, modifier = Modifier.padding(top = 4.dp))
            NWGlassCard(radius = 20.dp, padding = PaddingValues(0.dp)) {
                agents.forEachIndexed { i, a ->
                    val state = WorkflowOrbit.nodeState(a)
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable(role = Role.Button, onClickLabel = "Opens this agent's transcript") { actions.openAgent(run.id, a.id) }.padding(horizontal = 16.dp, vertical = 12.dp)
                            .semantics(mergeDescendants = false) { contentDescription = "${a.label}, ${state.spoken()}" },
                        horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.size(10.dp).clip(CircleShape).background(state.color.color))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text(a.label, style = NW.Typo.bodyStrong, color = NW.Palette.textPrimary.color, maxLines = 2, overflow = TextOverflow.Ellipsis)
                            Text(agentMeta(a, state, now), style = NW.Typo.caption, color = (if (state == WorkflowOrbit.NodeState.FAILED) NW.Palette.amber else NW.Palette.textTertiary).color)
                        }
                        Icon(Icons.Outlined.ChevronRight, null, tint = NW.Palette.textQuiet.color, modifier = Modifier.size(18.dp))
                    }
                    if (i < agents.size - 1) Box(Modifier.fillMaxWidth().height(1.dp).background(Color.White.copy(alpha = 0.06f)))
                }
            }
        }
        if (run.agents.isEmpty()) Text("No agents have started yet.", style = NW.Typo.body, color = NW.Palette.textTertiary.color)
    }
}

private fun agentMeta(a: WorkflowRun.Agent, state: WorkflowOrbit.NodeState, now: Instant): String {
    val parts = ArrayList<String>()
    a.phase?.let { parts.add(it) }
    val at = a.lastActivityAt
    if (state == WorkflowOrbit.NodeState.FAILED && at != null) parts.add("failed ${RelativeTime.ago(at, now)}")
    else if (at != null) parts.add(RelativeTime.ago(at, now))
    else if (state == WorkflowOrbit.NodeState.FAILED) parts.add("failed")
    return parts.joinToString(" · ")
}

// MARK: - A workflow agent

/** One workflow agent: what it was asked, what it did, what it said. Read only. It lives inside a run, so its header names the run it belongs to. */
@Composable
fun NWAgentRoomScreen(runName: String, agentLabel: String, state: WorkflowOrbit.NodeState, model: AgentRoomModel?, onBack: () -> Unit, modifier: Modifier = Modifier) {
    val top = WindowInsets.statusBars.asPaddingValues().calculateTopPadding()
    Box(modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color)) {
        NWBackdrop()
        Column(Modifier.fillMaxSize().padding(top = top)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = NW.Space.lg).padding(top = 14.dp, bottom = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(48.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.09f)).clickable(role = Role.Button, onClickLabel = "Back", onClick = onBack), contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = NW.Palette.textPrimary.color, modifier = Modifier.size(22.dp))
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(runName, style = NW.Typo.monoSmall, color = NW.Palette.textTertiary.color, maxLines = 1)
                    Text(agentLabel, style = NW.Typo.title.copy(fontWeight = FontWeight.Bold), color = NW.Palette.textPrimary.color, maxLines = 2)
                }
                val c = state.color
                Row(Modifier.heightIn(min = 34.dp).clip(CircleShape).background(c.opacity(0.14).color).padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(c.color))
                    Text(when (state) { WorkflowOrbit.NodeState.RUNNING -> "RUNNING"; WorkflowOrbit.NodeState.DONE -> "DONE"; WorkflowOrbit.NodeState.FAILED -> "FAILED"; else -> "STOPPED" }, style = NW.Typo.label, color = c.color)
                }
            }
            val scroll = rememberScrollState()
            LaunchedEffect(model?.blocks?.size) { scroll.scrollTo(scroll.maxValue) }
            Column(Modifier.weight(1f).verticalScroll(scroll).padding(horizontal = NW.Space.lg, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (model != null) {
                    if (model.truncated) Text("Earlier steps aren't shown", style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                    model.task?.let { task ->
                        Column(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(NW.Palette.surface.mixed(NW.Palette.violet.opacity(1.0), 0.06).opacity(0.95).color).padding(16.dp).semantics(mergeDescendants = true) {},
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text("TASK FROM THE WORKFLOW", style = NW.Typo.label, color = NW.Palette.violet.color)
                            SelectionContainer { Text(task, style = NW.Typo.subline, color = NW.Palette.textPrimary.color) }
                        }
                    }
                    for (b in model.blocks) AgentBlock(b)
                    if (model.blocks.isEmpty() && model.task == null) Text("Nothing yet.", style = NW.Typo.body, color = NW.Palette.textTertiary.color)
                } else {
                    Row(Modifier.fillMaxWidth().padding(top = 40.dp), horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally), verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(20.dp), color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
                        Text("Asking your Mac…", style = NW.Typo.body, color = NW.Palette.textTertiary.color)
                    }
                }
                NWInfoNote(AgentRoomModel.readOnlyNote, Modifier.padding(top = 8.dp), Icons.Outlined.Visibility)
            }
        }
    }
}

@Composable
private fun AgentBlock(b: StoryBlock) {
    when (b) {
        is StoryBlock.Steps -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            for (s in b.steps) Row(
                Modifier.fillMaxWidth().heightIn(min = 52.dp).clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.05f)).padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(nwIcon(s.symbol), null, tint = NW.Palette.textTertiary.color, modifier = Modifier.size(20.dp))
                Text(s.title, style = if (s.mono) NW.Typo.monoBody else NW.Typo.body, color = NW.Palette.textPrimary.color, maxLines = 3, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
            }
        }
        is StoryBlock.Assistant -> Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
            Box(Modifier.size(34.dp).clip(RoundedCornerShape(10.dp)).background(NW.Palette.violet.opacity(0.16).color), contentAlignment = Alignment.Center) {
                Icon(nwIcon("sparkle"), null, tint = NW.Palette.violet.color, modifier = Modifier.size(18.dp))
            }
            SelectionContainer(Modifier.weight(1f)) { Text(b.entry.text, style = NW.Typo.subline, color = NW.Palette.textPrimary.color) }
        }
        is StoryBlock.Marker -> Text(b.text, style = NW.Typo.caption, color = NW.Palette.textTertiary.color, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        is StoryBlock.User -> Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Color.White.copy(alpha = 0.045f)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("FROM THE WORKFLOW", style = NW.Typo.label, color = NW.Palette.violet.color)
            SelectionContainer { Text(b.entry.text, style = NW.Typo.body, color = NW.Palette.textSecondary.color) }
        }
        else -> Unit
    }
}
