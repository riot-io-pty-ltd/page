package app.page.android.ui.sessions

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Difference
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardHide
import androidx.compose.material.icons.filled.NotificationsActive
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.StopCircle
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.LaunchHints
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.MacPresence
import app.page.android.model.SentSessionCommand
import app.page.android.model.SessionAvailability
import app.page.android.model.SessionCommandKind
import app.page.android.model.SessionComposer
import app.page.android.model.SessionDeliveryState
import app.page.android.model.TranscriptEntry
import app.page.android.model.TranscriptRole
import app.page.android.model.TranscriptTimeline
import app.page.android.model.graphemeCount
import app.page.android.ui.components.AgentPill
import app.page.android.ui.components.BannerTone
import app.page.android.ui.components.ConfirmDialog
import app.page.android.ui.components.DialogChoice
import app.page.android.ui.components.ReplyField
import app.page.android.ui.components.SegmentedControl
import app.page.android.ui.components.SessionStateChip
import app.page.android.ui.components.StatusBanner
import app.page.android.ui.components.StatusStrip
import app.page.android.ui.components.TextLink
import app.page.android.ui.inbox.ReplyScreen
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Conversation (the transcript), Terminal (the Mac's mirror of the session's
 * screen, footer included) or Workflows (its dynamic workflows). Terminal and
 * Workflows appear only once the Mac has sent them: older Macs don't, and
 * Terminal.app / iTerm2 have no mirror.
 */
private enum class Pane { CONVERSATION, TERMINAL, WORKFLOWS }

private const val WATCH_INTERVAL_MS = 30_000L

/**
 * One live session (iOS SessionDetailView.swift): what it's doing (the Mac's
 * last 40 transcript entries, chat-style), a composer that types into it, and
 * Stop while it's mid-turn.
 *
 * While visible it tells the Mac it's watching (re-sent every 30 s), which is
 * what makes the Mac send this session's transcript at all.
 */
@Composable
fun SessionDetailScreen(sessionId: String, onDismiss: () -> Unit) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    val macStatus by RelayClient.macStatus.collectAsStateWithLifecycle()
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val connected = connection == RelayClient.ConnectionState.CONNECTED

    var draft by rememberSaveable { mutableStateOf("") }
    var composerProblem by remember { mutableStateOf<String?>(null) }
    var confirmingStop by remember { mutableStateOf(false) }
    var presentedPage by remember { mutableStateOf<String?>(null) }
    var openRun by remember { mutableStateOf(LaunchHints.workflowRunId) }
    var showDiff by remember { mutableStateOf(LaunchHints.sessionPane == "changes") }
    var pane by rememberSaveable {
        mutableStateOf(
            when (LaunchHints.sessionPane) {
                "terminal" -> Pane.TERMINAL
                "workflows" -> Pane.WORKFLOWS
                else -> Pane.CONVERSATION
            }
        )
    }
    LaunchedEffect(Unit) {
        LaunchHints.sessionPane = null
        LaunchHints.workflowRunId = null
    }

    val live = state.session(sessionId)
    // Last known copy, so the screen stays readable after the session ends.
    var snapshot by remember { mutableStateOf(live) }
    LaunchedEffect(live) { if (live != null) snapshot = live }
    val session = live ?: snapshot
    val agent = session?.backend?.displayName ?: "Your agent"
    val runs = state.workflows[sessionId] ?: emptyList()
    val screen = state.screens[sessionId]
    val panes = buildList {
        add(Pane.CONVERSATION)
        if (screen != null) add(Pane.TERMINAL)
        if (runs.isNotEmpty()) add(Pane.WORKFLOWS)
    }
    // A pane that went away (its data stopped) falls back to Conversation.
    val shownPane = if (pane in panes) pane else Pane.CONVERSATION
    val availability = state.availability(MacPresence.evaluate(macStatus, Instant.now()), connected, Instant.now())
    /** The session left the Mac's list while this screen was open. */
    val ended = live == null && state.hasList && snapshot != null

    // Watch while visible and connected; the store re-arms it after a
    // reconnect, and sends nothing while the socket is down.
    LaunchedEffect(connected, sessionId) {
        while (true) {
            SessionStore.watch(sessionId)
            delay(WATCH_INTERVAL_MS)
        }
    }
    DisposableEffect(sessionId) { onDispose { SessionStore.watch(null) } }
    BackHandler(enabled = presentedPage == null && openRun == null && !showDiff, onBack = onDismiss)

    fun send(text: String) {
        val problem = SessionStore.sendInput(sessionId, text)
        if (problem != null) {
            composerProblem = problem.message
            return
        }
        draft = ""
        composerProblem = null
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.surface)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
    ) {
        DetailTopBar(
            session, live, availability, state.latestInterrupt(sessionId, Instant.now()), agent, onDismiss,
            onChanges = { showDiff = true },
        ) { confirmingStop = true }
        if (session == null) {
            Placeholder(state.hasList, onDismiss)
            return@Column
        }
        Row(
            Modifier.padding(horizontal = Space.xl, vertical = Space.s),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            AgentPill(session.backend, session.hostLabel)
            SessionStateChip(if (ended) LiveSessionState.OFFLINE else session.state)
        }
        Banners(session, ended, availability, agent, onOpenPage = { presentedPage = it })
        if (panes.size > 1) {
            SegmentedControl(
                panes, shownPane,
                label = { p ->
                    when (p) {
                        Pane.CONVERSATION -> "Conversation"
                        Pane.TERMINAL -> "Terminal"
                        Pane.WORKFLOWS -> "Workflows · ${runs.count { it.isRunning }}"
                    }
                },
                modifier = Modifier.padding(horizontal = Space.l).padding(bottom = Space.s),
            ) { pane = it }
        }
        Box(Modifier.weight(1f)) {
            when (shownPane) {
                Pane.TERMINAL -> screen?.let { TerminalMirror(it, runs, Modifier.fillMaxSize()) { r -> openRun = r.id } }
                Pane.WORKFLOWS -> WorkflowList(runs, Modifier.fillMaxSize()) { openRun = it.id }
                Pane.CONVERSATION -> Transcript(
                    sessionId, state.transcripts[sessionId]?.entries, state.transcripts[sessionId]?.truncated == true,
                    state.sentMessages(sessionId), agent, availability, live?.interventionId,
                    onOpenPage = { presentedPage = it },
                )
            }
        }
        BottomZone(
            session = session,
            ready = availability == SessionAvailability.Ready && !ended,
            draft = draft,
            onDraftChange = { draft = it; composerProblem = null },
            composerProblem = composerProblem,
            interrupt = state.latestInterrupt(sessionId, Instant.now()),
            agent = agent,
            onSend = ::send,
        )
    }

    openRun?.let { runId -> WorkflowRunScreen(sessionId, runId) { openRun = null } }
    if (showDiff) DiffScreen(sessionId, session?.title) { showDiff = false }
    presentedPage?.let { pageId ->
        // "Open session" there just comes back here.
        ReplyScreen(pageId, onDismiss = { presentedPage = null }, onOpenSession = { presentedPage = null })
    }
    if (confirmingStop) {
        ConfirmDialog(
            title = "Stop $agent?",
            message = "Page presses Esc in the session on your Mac. $agent stops what it's doing and waits for you.",
            choices = listOf(DialogChoice("Stop this turn", destructive = true) { SessionStore.interrupt(sessionId) }),
            onDismiss = { confirmingStop = false },
        )
    }
}

@Composable
private fun DetailTopBar(
    session: LiveSession?,
    live: LiveSession?,
    availability: SessionAvailability,
    interrupt: SentSessionCommand?,
    agent: String,
    onDismiss: () -> Unit,
    onChanges: () -> Unit,
    onStop: () -> Unit,
) {
    Column {
        Row(Modifier.fillMaxWidth().padding(horizontal = Space.s, vertical = Space.xs), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(MinTouch).clickable(role = Role.Button, onClick = onDismiss).semantics { contentDescription = "Close" },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = colors.text) }
            Column(
                Modifier.weight(1f).clearAndSetSemantics {
                    contentDescription = "${session?.title ?: "Session"}, ${session?.cwd ?: ""}"
                    heading()
                },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val cwd = session?.cwd?.takeIf { it.isNotEmpty() } ?: " "
                // Truncated at the head, like iOS: the project end of the path matters.
                Text(if (cwd.length > 42) "…" + cwd.takeLast(41) else cwd, style = PageType.mono13, color = colors.textMuted, maxLines = 1)
                Text(session?.title ?: "Session", style = PageType.bodyEm, color = colors.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            // v4: what this session changed (the Mac answers a `diff` op).
            if (live != null && availability == SessionAvailability.Ready) {
                Box(
                    Modifier.size(MinTouch).clickable(role = Role.Button, onClick = onChanges).semantics { contentDescription = "Changes" },
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Filled.Difference, contentDescription = null, tint = colors.text) }
            }
            val stopping = interrupt?.state?.isPending == true
            if (live != null && live.isStoppable && availability == SessionAvailability.Ready) {
                Box(
                    Modifier
                        .size(MinTouch)
                        .clickable(enabled = !stopping, role = Role.Button, onClick = onStop)
                        .semantics { contentDescription = if (stopping) "Stopping" else "Stop $agent" },
                    contentAlignment = Alignment.Center,
                ) {
                    Box(Modifier.size(36.dp).clip(CircleShape).background(colors.destructive.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
                        if (stopping) {
                            CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.destructiveText)
                        } else {
                            Icon(Icons.Filled.Stop, contentDescription = null, tint = colors.destructiveText, modifier = Modifier.size(20.dp))
                        }
                    }
                }
            } else {
                Spacer(Modifier.size(MinTouch))
            }
        }
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
    }
}

@Composable
private fun Banners(s: LiveSession, ended: Boolean, availability: SessionAvailability, agent: String, onOpenPage: (String) -> Unit) {
    Column(Modifier.padding(horizontal = Space.xl).padding(bottom = Space.xs), verticalArrangement = Arrangement.spacedBy(Space.s)) {
        val pageId = s.openPageId
        when {
            ended -> StatusBanner(
                BannerTone.INFO, Icons.Outlined.CheckCircle, "This session has ended",
                "It's no longer on your Mac's list. The transcript below is the last one Page received.",
            )
            availability != SessionAvailability.Ready -> {
                val copy = SessionAvailabilityCopy.of(availability)
                StatusBanner(
                    copy.tone, copy.icon, copy.title, copy.message.ifEmpty { "Waiting for your Mac…" },
                    actionTitle = if (copy.action == SessionAvailabilityCopy.Action.RETRY) copy.actionTitle else null,
                    action = if (copy.action == SessionAvailabilityCopy.Action.RETRY) ({ SessionStore.refresh() }) else null,
                )
            }
            pageId != null -> StatusBanner(
                BannerTone.WARNING, Icons.Filled.NotificationsActive,
                if (s.state == LiveSessionState.WAITING_ON_APPROVAL) "$agent needs your approval" else "$agent is waiting for you",
                "Answer the prompt from its page. Page won't type over a prompt.",
                actionTitle = "Open page",
            ) { onOpenPage(pageId) }
            s.state.isWaiting -> StatusBanner(
                BannerTone.WARNING, Icons.Filled.NotificationsActive, "$agent is showing a prompt",
                "There's no page for it yet. Answer it on your Mac, or wait a moment for the page to arrive.",
            )
        }
    }
}

@Composable
private fun Transcript(
    sessionId: String,
    entries: List<TranscriptEntry>?,
    truncated: Boolean,
    sent: List<SentSessionCommand>,
    agent: String,
    availability: SessionAvailability,
    liveInterventionId: String?,
    onOpenPage: (String) -> Unit,
) {
    val items = TranscriptTimeline.merge(entries ?: emptyList(), sent)
    // Changes when an entry or a delivery state changes, not on every recomposition.
    val signature = items.joinToString("|") { item ->
        when (item) {
            is TranscriptTimeline.Item.Entry -> item.entry.id + (item.delivery?.state?.toString() ?: "")
            is TranscriptTimeline.Item.Pending -> item.command.clientId + item.command.state
        }
    }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    // Follow new entries only while the user is at the bottom; someone
    // reading back up keeps their place.
    var followBottom by remember(sessionId) { mutableStateOf(true) }
    LaunchedEffect(listState) {
        snapshotFlow { listState.isScrollInProgress to listState.canScrollForward }.collect { (scrolling, canForward) ->
            if (scrolling) followBottom = !canForward
        }
    }
    val lastIndex = items.size + 1
    LaunchedEffect(signature) { if (followBottom && items.isNotEmpty()) listState.scrollToItem(lastIndex) }

    Box(Modifier.fillMaxSize()) {
        LazyColumn(
            state = listState,
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = Space.l, vertical = Space.m),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            item(key = "top") {
                if (truncated) {
                    Text("Earlier messages aren't shown", style = PageType.caption12, color = colors.textMuted, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(bottom = Space.s))
                }
                if (items.isEmpty()) EmptyTranscript(entries != null, availability)
            }
            items(items, key = { it.id }) { item ->
                when (item) {
                    is TranscriptTimeline.Item.Entry -> when (item.entry.role) {
                        TranscriptRole.USER -> UserBubble(item.entry.text, item.delivery, false, agent, liveInterventionId, onOpenPage)
                        TranscriptRole.ASSISTANT -> AssistantBubble(item.entry, agent)
                        TranscriptRole.TOOL -> ToolRow(item.entry)
                        TranscriptRole.SYSTEM -> SystemRow(item.entry)
                    }
                    is TranscriptTimeline.Item.Pending -> UserBubble(item.command.text, item.command, true, agent, liveInterventionId, onOpenPage)
                }
            }
            item(key = "bottom") { Spacer(Modifier.height(1.dp)) }
        }
        if (!followBottom && items.isNotEmpty()) {
            Box(
                Modifier
                    .align(Alignment.BottomEnd)
                    .padding(Space.m)
                    .size(MinTouch)
                    .clip(CircleShape)
                    .background(colors.surfaceRaised)
                    .border(1.dp, colors.hairline, CircleShape)
                    .clickable(role = Role.Button) {
                        followBottom = true
                        scope.launch { listState.animateScrollToItem(lastIndex) }
                    }
                    .semantics { contentDescription = "Jump to latest" },
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Filled.ArrowDownward, contentDescription = null, tint = colors.text) }
        }
    }
}

@Composable
private fun EmptyTranscript(loaded: Boolean, availability: SessionAvailability) {
    Box(Modifier.fillMaxWidth().padding(top = 60.dp), contentAlignment = Alignment.Center) {
        if (loaded || availability != SessionAvailability.Ready) {
            Text(
                if (loaded) "Nothing in this session yet." else "The transcript appears once your Mac is connected.",
                style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center,
            )
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(Space.s), verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp, color = colors.textMuted)
                Text("Loading transcript…", style = PageType.body15, color = colors.textMuted)
            }
        }
    }
}

@Composable
private fun UserBubble(
    text: String,
    delivery: SentSessionCommand?,
    pending: Boolean,
    agent: String,
    liveInterventionId: String?,
    onOpenPage: (String) -> Unit,
) {
    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val shape = RoundedCornerShape(16.dp)
        // The bubble carries its status as its state, explanation included;
        // the delivery line below hides its text from TalkBack so it isn't
        // read twice, and its "Open page" button stays focusable.
        SelectionContainer(
            Modifier
                .padding(start = 48.dp)
                .semantics {
                    contentDescription = "You: $text"
                    delivery?.let { stateDescription = it.state.spokenBubbleStatus(SessionCommandKind.INPUT, agent) }
                }
        ) {
            Text(
                text, style = PageType.body15, color = colors.text,
                modifier = Modifier
                    .clip(shape)
                    .background(colors.kindUserInput.copy(alpha = if (pending) 0.08f else 0.16f))
                    .then(if (pending) Modifier.border(1.dp, colors.kindUserInput.copy(alpha = 0.35f), shape) else Modifier)
                    .padding(horizontal = Space.m, vertical = 10.dp),
            )
        }
        delivery?.let { DeliveryLine(it, agent, liveInterventionId, onOpenPage) }
    }
}

@Composable
private fun DeliveryLine(message: SentSessionCommand, agent: String, liveInterventionId: String?, onOpenPage: (String) -> Unit) {
    val state = message.state
    val (color, icon) = when (state) {
        SessionDeliveryState.Sending -> colors.textMuted to null
        is SessionDeliveryState.Typed -> colors.success to Icons.Filled.Check
        is SessionDeliveryState.Queued -> colors.textMuted to Icons.Filled.Schedule
        is SessionDeliveryState.Refused, is SessionDeliveryState.Failed -> colors.destructiveText to Icons.Filled.Warning
        SessionDeliveryState.NoAnswer -> colors.warning to Icons.Outlined.HelpOutline
    }
    val explanation = state.bubbleExplanation(SessionCommandKind.INPUT, agent)
    Column(Modifier.padding(start = 48.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(Modifier.clearAndSetSemantics { }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (icon != null) Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(12.dp))
            else CircularProgressIndicator(Modifier.size(10.dp), strokeWidth = 1.5.dp, color = color)
            Text(state.label(SessionCommandKind.INPUT), style = PageType.chip11, color = color)
        }
        explanation?.let {
            Text(it, style = PageType.caption12, color = colors.textMuted, textAlign = TextAlign.End, modifier = Modifier.clearAndSetSemantics { })
        }
        if (state is SessionDeliveryState.Refused && state.reason == "waiting" && liveInterventionId != null) {
            TextLink("Open page") { onOpenPage(liveInterventionId) }
        }
    }
}

@Composable
private fun AssistantBubble(e: TranscriptEntry, agent: String) {
    val shape = RoundedCornerShape(16.dp)
    Row(Modifier.fillMaxWidth().padding(end = 32.dp)) {
        SelectionContainer(Modifier.semantics { contentDescription = "$agent: ${e.text}" }) {
            Text(
                e.text, style = PageType.body15, color = colors.text,
                modifier = Modifier
                    .clip(shape)
                    .background(colors.surfaceRaised)
                    .border(1.dp, colors.hairline, shape)
                    .padding(horizontal = Space.m, vertical = 10.dp),
            )
        }
    }
}

@Composable
private fun ToolRow(e: TranscriptEntry) {
    Row(
        Modifier.padding(horizontal = Space.s, vertical = 2.dp).clearAndSetSemantics { contentDescription = "Tool: ${e.text}" },
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text("›", style = PageType.mono12, color = colors.textMuted)
        Text(e.text, style = PageType.mono12, color = colors.textMuted, maxLines = 3, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun SystemRow(e: TranscriptEntry) {
    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Text(
            e.text, style = PageType.caption12, color = colors.textMuted, textAlign = TextAlign.Center,
            modifier = Modifier.clip(RoundedCornerShape(50)).background(colors.surfaceInset).padding(horizontal = Space.m, vertical = 4.dp),
        )
    }
}

@Composable
private fun BottomZone(
    session: LiveSession,
    ready: Boolean,
    draft: String,
    onDraftChange: (String) -> Unit,
    composerProblem: String?,
    interrupt: SentSessionCommand?,
    agent: String,
    onSend: (String) -> Unit,
) {
    Column(Modifier.fillMaxWidth().background(colors.surface)) {
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
        interrupt?.let { InterruptStrip(it, agent) }
        composerProblem?.let {
            Text(
                it, style = PageType.caption12, color = colors.destructiveText,
                modifier = Modifier.fillMaxWidth().padding(horizontal = Space.xl).padding(top = Space.s).semantics { contentDescription = "Can't send: $it" },
            )
        }
        Column(Modifier.padding(horizontal = Space.xl).padding(top = Space.m), horizontalAlignment = Alignment.End) {
            if (!session.canType) {
                TypeBlocker(session)
            } else {
                ReplyField(draft, onDraftChange, "Message $agent…", ready, sendLabel = "Send message", onSend = onSend)
                val count = draft.graphemeCount()
                if (count >= SessionComposer.COUNTER_FROM) {
                    Text(
                        "$count / ${SessionComposer.MAX_CHARACTERS}", style = PageType.caption12,
                        color = if (count > SessionComposer.MAX_CHARACTERS) colors.destructiveText else colors.textMuted,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
        Text(
            if (session.canType) "Page types your message into this session (${session.hostLabel}) on your Mac." else "${session.hostLabel} · ${session.state.label}",
            style = PageType.caption12, color = colors.textMuted, textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(start = Space.xl, end = Space.xl, top = Space.s, bottom = Space.l),
        )
    }
}

@Composable
private fun InterruptStrip(stop: SentSessionCommand, agent: String) {
    val explanation = stop.state.explanation(SessionCommandKind.INTERRUPT, agent) ?: ""
    when (stop.state) {
        SessionDeliveryState.Sending -> StatusStrip(null, "Stopping…", colors.textMuted)
        is SessionDeliveryState.Typed, is SessionDeliveryState.Queued -> StatusStrip(Icons.Filled.StopCircle, "Stopped. $explanation", colors.success)
        else -> StatusStrip(Icons.Filled.Warning, "Couldn't stop: $explanation", colors.destructiveText)
    }
}

@Composable
private fun TypeBlocker(s: LiveSession) {
    val shape = RoundedCornerShape(12.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.surfaceInset)
            .border(1.dp, colors.hairline, shape)
            .padding(Space.m)
            .clearAndSetSemantics { contentDescription = "${s.blockerText}. You can still follow along here, and answer pages from the Inbox." },
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Icon(Icons.Filled.KeyboardHide, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(18.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(s.blockerText, style = PageType.bodyEm, color = colors.text)
            Text("You can still follow along here, and answer pages from the Inbox.", style = PageType.caption12, color = colors.textMuted)
        }
    }
}

@Composable
private fun Placeholder(hasList: Boolean, onClose: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(Space.xxl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.m, Alignment.CenterVertically),
    ) {
        if (hasList) {
            Icon(Icons.Outlined.CheckCircle, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(40.dp))
            Text("This session isn't running", style = PageType.title17, color = colors.text)
            Text("It's not on your Mac's list of live sessions anymore.", style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center)
            TextLink("Close", onClick = onClose)
        } else {
            CircularProgressIndicator(color = colors.textMuted)
            Text("Loading…", style = PageType.body15, color = colors.textMuted)
        }
    }
}
