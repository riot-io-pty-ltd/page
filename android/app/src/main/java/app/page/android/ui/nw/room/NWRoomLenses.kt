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
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.GraphicsLayerScope
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.page.android.data.AppGraph
import app.page.android.model.AgentRoomModel
import app.page.android.model.ChangesModel
import app.page.android.model.MotionCurve
import app.page.android.model.OneShotBook
import app.page.android.model.RelativeTime
import app.page.android.model.ScreenFreshness
import app.page.android.model.StoryBlock
import app.page.android.model.TerminalRunLinks
import app.page.android.model.TerminalTone
import app.page.android.model.WorkflowMotion
import app.page.android.model.WorkflowOrbit
import app.page.android.model.WorkflowRun
import app.page.android.ui.nw.components.NWAnswerHost
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWButtonKind
import app.page.android.ui.nw.components.NWBackdrop
import app.page.android.ui.nw.components.NWDeliveryPreview
import app.page.android.ui.nw.components.NWGlassCard
import app.page.android.ui.nw.components.nwClockSeconds
import app.page.android.ui.nw.components.rememberNWMotionClock
import app.page.android.ui.nw.components.nwIcon
import app.page.android.ui.nw.now.NWOutcomeStrip
import app.page.android.ui.nw.now.RowStatus
import app.page.android.ui.nw.theme.LocalFixedPhase
import app.page.android.ui.nw.theme.LocalReduceMotion
import app.page.android.ui.nw.theme.LocalWorkflowScript
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

/** When each run's ring first closed with its pulse, so it plays once per run however often the lens is opened. */
private val workflowPulseBook = OneShotBook()

/** One timeline for a workflow view, ticking only while [animatingAt] says something moves ([rememberNWMotionClock]). */
@Composable
private fun rememberMotionClock(key: Any?, animatingAt: (Double) -> Boolean): State<Double> = rememberNWMotionClock(key, animatingAt = animatingAt)

/**
 * The run as the lens has seen it since it appeared ([WorkflowMotion.Track]), each new snapshot observed as it arrives.
 * Under the render harness it is the script's snapshots folded up to the pinned moment instead, the lens appearing at 0.
 */
@Composable
private fun rememberWorkflowTrack(run: WorkflowRun, now: Instant): WorkflowMotion.Track {
    val pinned = LocalFixedPhase.current
    if (pinned != null) {
        val steps = LocalWorkflowScript.current?.takeIf { it.isNotEmpty() } ?: listOf(0.0 to run)
        return remember(steps, pinned, now) {
            // A book of its own, as iOS's replay has none: every pinned frame is the run's first look, and the live lens's book never hears of it.
            val book = OneShotBook()
            steps.drop(1).filter { it.first <= pinned }.fold(WorkflowMotion.start(WorkflowOrbit.build(steps[0].second, now), 0.0, book)) { track, (at, r) ->
                WorkflowMotion.observe(track, WorkflowOrbit.build(r, now), at, book)
            }
        }
    }
    val orbit = WorkflowOrbit.build(run, now)
    val held = remember { mutableStateOf<WorkflowMotion.Track?>(null) }
    val prev = held.value
    val next = if (prev == null) WorkflowMotion.start(orbit, nwClockSeconds(), workflowPulseBook) else WorkflowMotion.observe(prev, orbit, nwClockSeconds(), workflowPulseBook)
    if (next !== prev) SideEffect { held.value = next }
    return next
}

/** Rising in from [start] on the clock (8 dp and a fade, 0.25 s); under Reduce Motion a plain 0.2 s fade from [fadeFrom]. */
private fun Modifier.rising(clock: State<Double>, start: Double, reduce: Boolean, fadeFrom: Double = start): Modifier = graphicsLayer {
    if (reduce) {
        alpha = MotionCurve.easeOut((clock.value - fadeFrom) / WorkflowMotion.reducedFade).toFloat()
    } else {
        val r = WorkflowMotion.rise(clock.value - start)
        translationY = r.offset.dp.toPx()
        alpha = r.opacity.toFloat()
    }
}

/**
 * Row [index] of the entrance rising in below the orbit ([WorkflowMotion.row]; every row fades in together under Reduce
 * Motion). A row inside a card that fades with its first row, [within], measures its own fade against the card's, so
 * what shows is the row's curve exactly.
 */
private fun Modifier.rowRise(clock: State<Double>, openedAt: Double, index: Int, reduce: Boolean, within: Int? = null): Modifier = graphicsLayer {
    val t = clock.value - openedAt
    val r = WorkflowMotion.row(t, index, reduce)
    val card = within?.let { WorkflowMotion.row(t, it, reduce).opacity } ?: 1.0
    translationY = r.offset.dp.toPx()
    alpha = (if (card > 1e-3) r.opacity / card else 0.0).coerceIn(0.0, 1.0).toFloat()
}

/** A card of rows, fading in with its first row so no empty card shows before its rows arrive. */
private fun Modifier.cardRise(clock: State<Double>, openedAt: Double, first: Int, reduce: Boolean): Modifier = graphicsLayer {
    alpha = WorkflowMotion.row(clock.value - openedAt, first, reduce).opacity.toFloat()
}

/**
 * A status dot that breathes in the nodes' 1.8 s rhythm while [live], all such dots together: the dot swells 1 → 1.12
 * and a halo twice its size glows 0.25 → 0.5 round it, soft at its edge (iOS blurs it by 0.35 of the dot's size).
 */
@Composable
private fun BreathingDot(color: Rgba, size: Dp, live: Boolean, clock: State<Double>) {
    Box(
        Modifier.size(size).drawBehind {
            val r = this.size.minDimension / 2
            if (live) {
                val b = WorkflowMotion.breath(clock.value)
                val halo = color.opacity(WorkflowMotion.haloFrom + (WorkflowMotion.haloTo - WorkflowMotion.haloFrom) * b).color
                val soft = 0.7f * r
                val glow = 2 * r + soft
                drawCircle(Brush.radialGradient(0f to halo, (2 * r - soft) / glow to halo, 1f to Color.Transparent, center = center, radius = glow), glow)
                drawCircle(color.color, r * (1 + WorkflowMotion.breathScale * b).toFloat())
            } else {
                drawCircle(color.color, r)
            }
        },
    )
}

/**
 * The multi-agent run as a ring of nodes with "4/7 agents done" in the middle, in motion ([WorkflowMotion]): nodes pop in
 * clockwise and the arc sweeps as the lens opens; running nodes breathe and ripple under a comet; a finished agent fills
 * in place and the ring closes with one soft pulse. One accessibility element sums it up; each node is its own button,
 * and opens that agent's transcript.
 */
@Composable
fun NWWorkflowOrbit(track: WorkflowMotion.Track, clock: State<Double>, reduce: Boolean, onAgent: (String) -> Unit, modifier: Modifier = Modifier) {
    val orbit = track.orbit
    val size = 300.dp
    val radius = size / 2 - 18.dp
    Box(modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Box(Modifier.size(size), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(size).clearAndSetSemantics { contentDescription = WorkflowMotion.summary(orbit) }) {
                drawOrbit(track, clock.value, reduce, radius.toPx())
            }
            OrbitCentre(track, clock, reduce)
            val n = track.slots.size
            for ((i, id) in track.slots.withIndex()) {
                val node = orbit.nodes.firstOrNull { it.id == id } ?: continue
                val a = WorkflowMotion.slotAngle(i, n)
                Box(
                    Modifier.offset((sin(a) * radius.value).dp, (-cos(a) * radius.value).dp).size(48.dp).clip(CircleShape)
                        .clickable(role = Role.Button, onClickLabel = "Opens this agent's transcript") { onAgent(node.id) }
                        .semantics { contentDescription = "${node.label}, ${node.state.spoken()}" },
                )
            }
            // What just happened while the lens was open, said once, politely ("verify: iOS logic tests finished").
            val said = track.events?.let { WorkflowMotion.announcement(orbit, it) }
            Box(Modifier.size(1.dp).semantics { liveRegion = LiveRegionMode.Polite; if (said != null) contentDescription = said })
        }
    }
}

private fun DrawScope.drawOrbit(track: WorkflowMotion.Track, now: Double, reduce: Boolean, r: Float) {
    val c = center
    val teal = NW.Palette.teal
    val t = now - track.openedAt
    val tracks = if (reduce) MotionCurve.easeOut(t / WorkflowMotion.reducedFade) else WorkflowMotion.trackOpacity(t)
    val trackColor = Color.White.copy(alpha = (0.07 * tracks).toFloat())
    val live = track.orbit.isRunning && !reduce
    // A run that has just stopped lets its comet and head fade out with the chip instead of vanishing (as iOS does).
    val mix = WorkflowMotion.statusMix(track, now, reduce)
    val stopping = !reduce && !track.orbit.isRunning && track.statusFrom?.isRunning == true && mix < 1
    val loops = if (live) 1.0 else if (stopping) 1 - mix else 0.0
    drawCircle(trackColor, r, c, style = Stroke(1.dp.toPx()))
    if (loops > 0) {
        // The comet: a 40° tail of teal round the orbit track, once every 8 s, clockwise. Drawn ending at 3 o'clock and
        // turned so its head sits where the clock says.
        val span = WorkflowMotion.cometSpan.toFloat()
        rotate(Math.toDegrees(WorkflowMotion.cometAngle(now)).toFloat() - 90f, c) {
            val tail = Brush.sweepGradient(0f to Color.Transparent, (360f - span) / 360f to Color.Transparent, 1f to teal.opacity(WorkflowMotion.cometOpacity * tracks * loops).color, center = c)
            val box = Size(r * 2, r * 2)
            val at = Offset(c.x - r, c.y - r)
            drawArc(tail, 360f - span, span, false, at, box, alpha = 0.35f, style = Stroke(6.dp.toPx()))
            drawArc(tail, 360f - span, span, false, at, box, style = Stroke(2.dp.toPx()))
        }
    }
    val rr = r * 0.55f
    val ring = Size(rr * 2, rr * 2)
    val ringAt = Offset(c.x - rr, c.y - rr)
    drawCircle(trackColor, rr, c, style = Stroke(12.dp.toPx()))
    val f = WorkflowMotion.arc(track, now, reduce).toFloat()
    // The arc sweeps in on its own; under Reduce Motion it is there at once, fading in with everything else.
    val content = if (reduce) tracks else 1.0
    if (f > 0.0005f) {
        // The thick teal arc on a soft glow (iOS: a 10 pt teal shadow).
        drawRingGlow(teal, 0.55 * content, c, rr, 16.dp.toPx(), 360f * f)
        drawArc(teal.opacity(content).color, -90f, 360f * f, false, ringAt, ring, style = Stroke(12.dp.toPx(), cap = StrokeCap.Round))
        if (loops > 0) {
            // The arc's leading end carries a small head that glows with the breath, fading with the comet as the run stops.
            val b = WorkflowMotion.breath(now).toFloat()
            val a = Math.toRadians(-90.0 + 360.0 * f)
            val head = Offset(c.x + cos(a).toFloat() * rr, c.y + sin(a).toFloat() * rr)
            val hr = (8f + 3f * b) * density
            drawCircle(Brush.radialGradient(listOf(teal.opacity((0.3 + 0.4 * b) * content * loops).color, Color.Transparent), center = head, radius = hr), hr, head)
            drawCircle(teal.mixed(NW.Palette.white, 0.6).opacity(content * loops).color, 3.5f * density, head)
        }
    }
    // The ring closing: one soft glow grows off it and fades.
    WorkflowMotion.pulse(track, now, reduce)?.let { p -> drawRingGlow(teal, p.ringOpacity, c, rr * p.ringScale.toFloat(), 9.dp.toPx(), 360f) }
    for (nf in WorkflowMotion.nodes(track, now, reduce)) {
        val p = Offset(c.x + sin(nf.angle).toFloat() * r, c.y - cos(nf.angle).toFloat() * r)
        val to = nf.node.state
        val col = nf.from.color.mixed(to.color, nf.mix)
        fun sized(running: Float, other: Float, of: WorkflowOrbit.NodeState) = if (of == WorkflowOrbit.NodeState.RUNNING) running else other
        val halo = (sized(15f, 11f, nf.from) + (sized(15f, 11f, to) - sized(15f, 11f, nf.from)) * nf.mix.toFloat()) * density * nf.scale.toFloat()
        val core = (sized(10f, 7.5f, nf.from) + (sized(10f, 7.5f, to) - sized(10f, 7.5f, nf.from)) * nf.mix.toFloat()) * density * nf.scale.toFloat()
        val o = nf.opacity
        // Its rings grow with the node as it pops in (iOS scales the whole node).
        val k = nf.scale.toFloat()
        nf.ripple?.let { drawCircle(col.opacity(it.opacity * o).color, it.radius.toFloat() * density * k, p, style = Stroke(1.5.dp.toPx() * k)) }
        nf.burst?.let { drawCircle(to.color.opacity(it.opacity).color, it.radius.toFloat() * density * k, p, style = Stroke(1.5.dp.toPx() * k)) }
        val haloAlpha = if (to == WorkflowOrbit.NodeState.RUNNING) WorkflowMotion.haloFrom + (WorkflowMotion.haloTo - WorkflowMotion.haloFrom) * nf.breath else WorkflowMotion.haloFrom
        // The halo glows: full strength to within 4 dp of its edge, then soft to 4 dp past it (iOS blurs it 4 pt).
        val soft = 4 * density * nf.scale.toFloat()
        val glow = halo + soft
        if (glow > 0f) {
            val haloColor = col.opacity(haloAlpha * o).color
            drawCircle(Brush.radialGradient(0f to haloColor, (halo - soft).coerceAtLeast(0f) / glow to haloColor, 1f to Color.Transparent, center = p, radius = glow), glow, p)
        }
        drawCircle(col.opacity(o).color, core * (1 + WorkflowMotion.breathScale * nf.breath).toFloat(), p)
        // An agent that has just finished: the done colour fills its disc from the middle.
        nf.fill?.let { drawCircle(to.color.opacity(o).color, core * it.toFloat(), p) }
    }
}

/**
 * A soft glow along the ring of radius [rr], from 12 o'clock clockwise for [sweep] degrees: [peak] on the ring, fading to
 * nothing [w] either side, and rounding off softly where an arc ends. Radial gradients, like the app's other glows (a
 * blur is not drawn on every API level the app supports).
 */
private fun DrawScope.drawRingGlow(color: Rgba, peak: Double, c: Offset, rr: Float, w: Float, sweep: Float) {
    if (peak <= 0 || w <= 0f || rr <= w / 2) return
    val outer = rr + w
    val on = color.opacity(peak).color
    val half = color.opacity(peak * 0.35).color
    val across = Brush.radialGradient(
        (rr - w).coerceAtLeast(0f) / outer to Color.Transparent, (rr - w / 2) / outer to half, rr / outer to on, (rr + w / 2) / outer to half, 1f to Color.Transparent,
        center = c, radius = outer,
    )
    if (sweep >= 359.9f) {
        drawCircle(across, outer, c)
        return
    }
    drawArc(across, -90f, sweep, false, Offset(c.x - rr, c.y - rr), Size(rr * 2, rr * 2), style = Stroke(w * 2))
    // Each end: half a disc of the same falloff, facing away from the arc.
    for ((end, from) in listOf(-90f to 90f, (sweep - 90f) to (sweep - 90f))) {
        val a = Math.toRadians(end.toDouble())
        val p = Offset(c.x + cos(a).toFloat() * rr, c.y + sin(a).toFloat() * rr)
        drawArc(Brush.radialGradient(0f to on, 0.5f to half, 1f to Color.Transparent, center = p, radius = w), from, 180f, true, Offset(p.x - w, p.y - w), Size(w * 2, w * 2))
    }
}

/** "4/7 agents done": the count climbs with the sweep, rolls up to each new count, and swells once as the ring closes. */
@Composable
private fun OrbitCentre(track: WorkflowMotion.Track, clock: State<Double>, reduce: Boolean) {
    // Only the whole numbers recompose; the roll itself is read as the layer is drawn.
    val shown by remember(track, reduce) { derivedStateOf { WorkflowMotion.count(track, clock.value, reduce).let { it.value to it.previous } } }
    val style = NW.Typo.hero.copy(fontFamily = FontFamily.Monospace, fontSize = 34.sp)
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.clearAndSetSemantics {}.graphicsLayer {
            val now = clock.value
            val s = (WorkflowMotion.pulse(track, now, reduce)?.textScale ?: 1.0).toFloat()
            scaleX = s
            scaleY = s
            if (reduce) alpha = MotionCurve.easeOut((now - track.openedAt) / WorkflowMotion.reducedFade).toFloat()
        },
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            val (value, previous) = shown
            Box(Modifier.clipToBounds(), contentAlignment = Alignment.Center) {
                // The old count slides up and out as the new one comes up from below (a cross-fade under Reduce Motion).
                if (previous != null) Text("$previous", style = style, color = NW.Palette.textPrimary.color, modifier = Modifier.graphicsLayer {
                    val k = WorkflowMotion.count(track, clock.value, reduce).roll.toFloat()
                    translationY = if (reduce) 0f else -size.height * k
                    alpha = 1 - k
                })
                Text("$value", style = style, color = NW.Palette.textPrimary.color, modifier = Modifier.graphicsLayer {
                    if (previous != null) {
                        val k = WorkflowMotion.count(track, clock.value, reduce).roll.toFloat()
                        translationY = if (reduce) 0f else size.height * (1 - k)
                        alpha = k
                    }
                })
            }
            Text("/${track.orbit.total}", style = style, color = NW.Palette.textPrimary.color)
        }
        Text(track.orbit.caption, style = NW.Typo.caption, color = NW.Palette.textTertiary.color)
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
        // Keyed by the run, so picking another one plays its entrance afresh.
        if (run != null) key(run.id) { WorkflowRunView(run, data, actions) }
        WorkflowOrbit.finishedLine(data.runs, data.now)?.let { line ->
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Color.White.copy(alpha = 0.045f)).padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(nwIcon("checkmark.circle"), null, tint = NW.Palette.teal.color, modifier = Modifier.size(20.dp))
                Text(line, style = NW.Typo.body, color = NW.Palette.textSecondary.color, maxLines = 2)
            }
        }
        Text("Workflow agents are read-only · tap one to watch its transcript", style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
    }
}

/** One run: its card with the orbit, then its agents, on one timeline. */
@Composable
private fun WorkflowRunView(run: WorkflowRun, data: SessionRoomData, actions: SessionRoomActions) {
    val reduce = LocalReduceMotion.current
    val track = rememberWorkflowTrack(run, data.now)
    val clock = rememberMotionClock(listOf(WorkflowMotion.settlesAt(track, reduce), track.orbit.isRunning, reduce)) { WorkflowMotion.animating(track, it, reduce) }
    val orbit = track.orbit
    // The card's teal wash fades with the status chip as the run ends: teal blending into the card's own surface, in
    // twentieths, so the card recomposes a few times during the fade and never while it holds.
    val wash by remember(track, reduce) {
        derivedStateOf {
            val k = WorkflowMotion.statusMix(track, clock.value, reduce)
            val from = if (track.statusFrom?.isRunning == true) 1.0 else 0.0
            val to = if (orbit.isRunning) 1.0 else 0.0
            kotlin.math.round((from + (to - from) * k) * 20) / 20
        }
    }
    val tint = when {
        wash >= 1.0 -> NW.Palette.teal
        wash <= 0.0 -> null
        else -> NW.Palette.teal.mixed(NW.Palette.surface, 1 - wash)
    }
    NWGlassCard(radius = 28.dp, padding = PaddingValues(18.dp), tint = tint) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(run.name, style = NW.Typo.title.copy(fontFamily = FontFamily.Monospace), color = NW.Palette.textPrimary.color, maxLines = 2, modifier = Modifier.weight(1f).padding(end = 8.dp))
                RunChip(track, clock, reduce)
            }
            // Its own line, clear of the chip, so a change of status never reflows the card.
            if (orbit.meta.isNotEmpty()) Text(orbit.meta, style = NW.Typo.subline, color = NW.Palette.textTertiary.color)
            run.summary?.let { Text(it, style = NW.Typo.caption, color = NW.Palette.textSecondary.color, modifier = Modifier.padding(top = 2.dp)) }
            NWWorkflowOrbit(track, clock, reduce, { actions.openAgent(run.id, it) }, Modifier.padding(top = 8.dp))
        }
    }
    Agents(run, data.now, actions, track, clock, reduce)
}

private fun runChipColor(o: WorkflowOrbit): Rgba =
    if (o.isRunning) NW.Palette.teal else if (o.status == "failed" || o.status == "stalled") NW.Palette.amber else NW.Palette.textSecondary

/** The run's status; its dot breathes while it runs, and RUNNING cross-fades to DONE or FAILED as it ends. */
@Composable
private fun RunChip(track: WorkflowMotion.Track, clock: State<Double>, reduce: Boolean) {
    @Composable
    fun face(o: WorkflowOrbit, alpha: GraphicsLayerScope.() -> Float) {
        val c = runChipColor(o)
        Row(
            Modifier.graphicsLayer { this.alpha = alpha() }.heightIn(min = 34.dp).clip(CircleShape).background(c.opacity(0.14).color).padding(horizontal = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically,
        ) {
            BreathingDot(c, 8.dp, o.isRunning && !reduce, clock)
            Text(o.statusLabel.uppercase(), style = NW.Typo.label, color = c.color)
        }
    }
    Box(contentAlignment = Alignment.CenterEnd) {
        // The status it is leaving only fades out of sight, so TalkBack never hears it: it reads the run as it is now.
        track.statusFrom?.let { from -> Box(Modifier.clearAndSetSemantics {}) { face(from) { 1f - WorkflowMotion.statusMix(track, clock.value, reduce).toFloat() } } }
        face(track.orbit) { WorkflowMotion.statusMix(track, clock.value, reduce).toFloat() }
    }
}

@Composable
private fun Agents(run: WorkflowRun, now: Instant, actions: SessionRoomActions, track: WorkflowMotion.Track, clock: State<Double>, reduce: Boolean) {
    // The rows rise in one after another below the orbit, counted down the whole list; a group's title with its first row.
    val groups = WorkflowOrbit.groups(run)
    val firstRow = groups.runningFold(0) { n, g -> n + g.second.size }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        for ((g, group) in groups.withIndex()) {
            val (title, agents) = group
            Text("${title.uppercase()} · ${agents.size}", style = NW.Typo.label, color = NW.Palette.textQuiet.color, modifier = Modifier.padding(top = 4.dp).rowRise(clock, track.openedAt, firstRow[g], reduce))
            NWGlassCard(Modifier.cardRise(clock, track.openedAt, firstRow[g], reduce), radius = 20.dp, padding = PaddingValues(0.dp)) {
                agents.forEachIndexed { i, a ->
                    val state = WorkflowOrbit.nodeState(a)
                    Column(Modifier.rowRise(clock, track.openedAt, firstRow[g] + i, reduce, within = firstRow[g])) {
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 60.dp).clickable(role = Role.Button, onClickLabel = "Opens this agent's transcript") { actions.openAgent(run.id, a.id) }.padding(horizontal = 16.dp, vertical = 12.dp)
                                .semantics(mergeDescendants = false) { contentDescription = "${a.label}, ${state.spoken()}" },
                            horizontalArrangement = Arrangement.spacedBy(14.dp), verticalAlignment = Alignment.CenterVertically,
                        ) {
                            // Breathes in the run chip's rhythm.
                            BreathingDot(state.color, 10.dp, state == WorkflowOrbit.NodeState.RUNNING && !reduce, clock)
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

/**
 * One workflow agent: what it was asked, what it did, what it said. Read only. It lives inside a run, so its header names
 * the run it belongs to. Its status dot breathes while it runs, and its items rise in, staggered as it opens and then as
 * they arrive ([arrivedAt]: "task" or a block id to the [nwClockSeconds] moment it starts rising, from
 * [WorkflowMotion.Arrivals]).
 */
@Composable
fun NWAgentRoomScreen(
    runName: String,
    agentLabel: String,
    state: WorkflowOrbit.NodeState,
    model: AgentRoomModel?,
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    arrivedAt: Map<String, Double> = emptyMap(),
) {
    val reduce = LocalReduceMotion.current
    val running = state == WorkflowOrbit.NodeState.RUNNING
    val lastArrival = arrivedAt.values.maxOrNull()
    val clock = rememberMotionClock(listOf(running, lastArrival, reduce)) { now ->
        (running && !reduce) || (lastArrival != null && now < lastArrival + if (reduce) WorkflowMotion.reducedFade else WorkflowMotion.rowDuration)
    }
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
                    BreathingDot(c, 8.dp, running && !reduce, clock)
                    Text(when (state) { WorkflowOrbit.NodeState.RUNNING -> "RUNNING"; WorkflowOrbit.NodeState.DONE -> "DONE"; WorkflowOrbit.NodeState.FAILED -> "FAILED"; else -> "STOPPED" }, style = NW.Typo.label, color = c.color)
                }
            }
            val scroll = rememberScrollState()
            LaunchedEffect(model?.blocks?.size) { scroll.scrollTo(scroll.maxValue) }
            Column(Modifier.weight(1f).verticalScroll(scroll).padding(horizontal = NW.Space.lg, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                if (model != null) {
                    if (model.truncated) Text("Earlier steps aren't shown", style = NW.Typo.caption, color = NW.Palette.textQuiet.color, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                    model.task?.let { task ->
                        val at = arrivedAt["task"]
                        Column(
                            (if (at == null) Modifier else Modifier.rising(clock, at, reduce)).fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(NW.Palette.surface.mixed(NW.Palette.violet.opacity(1.0), 0.06).opacity(0.95).color).padding(16.dp).semantics(mergeDescendants = true) {},
                            verticalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            Text("TASK FROM THE WORKFLOW", style = NW.Typo.label, color = NW.Palette.violet.color)
                            SelectionContainer { Text(task, style = NW.Typo.subline, color = NW.Palette.textPrimary.color) }
                        }
                    }
                    for (b in model.blocks) {
                        val at = arrivedAt[b.id]
                        if (at == null) AgentBlock(b) else Box(Modifier.rising(clock, at, reduce)) { AgentBlock(b) }
                    }
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
