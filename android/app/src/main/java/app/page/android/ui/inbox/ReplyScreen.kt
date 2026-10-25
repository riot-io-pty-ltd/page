package app.page.android.ui.inbox

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Difference
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.model.ClosedReplyPhase
import app.page.android.model.Intervention
import app.page.android.model.InterventionKind
import app.page.android.model.InterventionSource
import app.page.android.model.PageSubtype
import app.page.android.model.PathDisplay
import app.page.android.model.SessionAvailability
import app.page.android.model.TurnSummaryLine
import app.page.android.ui.sessions.DiffScreen
import app.page.android.model.RelativeTime
import app.page.android.model.ReplyAction
import app.page.android.model.ReplyConfirmation
import app.page.android.model.ReplyCopy
import app.page.android.model.ReplyDelivery
import app.page.android.model.ReplyOutcome
import app.page.android.model.secondsSince
import app.page.android.ui.components.BackendPill
import app.page.android.ui.components.ConfirmDialog
import app.page.android.ui.components.DialogChoice
import app.page.android.ui.components.KindChip
import app.page.android.ui.components.QuickButton
import app.page.android.ui.components.QuickButtonStyle
import app.page.android.ui.components.ReplyField
import app.page.android.ui.components.StatusStrip
import app.page.android.ui.components.TextLink
import app.page.android.ui.components.rememberNow
import app.page.android.ui.theme.MinTouch
import app.page.android.ui.theme.PageType
import app.page.android.ui.theme.Space
import app.page.android.ui.theme.colors
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** What the reply screen is showing, derived from live state every recomposition. */
private sealed interface Phase {
    data object Loading : Phase
    data object Missing : Phase
    data object Open : Phase
    data object Sending : Phase

    /** [slow]: past [ReplyConfirmation.SLOW_AFTER] without confirmation. */
    data class Sent(val queued: Boolean, val slow: Boolean) : Phase

    /**
     * Accepted by the relay but never confirmed by the Mac within the relay's
     * ack window, so a second answer is accepted again. Input re-opens so the
     * page can't get stuck.
     */
    data object Unconfirmed : Phase

    /** Closed with no reason known yet while we had a reply out: checking the archive. */
    data object CheckingClose : Phase
    data class Delivered(val detail: String?) : Phase
    data class Failed(val message: String) : Phase
    data object AlreadyReplied : Phase
    data class Resolved(val why: String) : Phase

    val acceptsInput: Boolean get() = this == Open || this is Failed || this == Unconfirmed

    /** States after which the screen closes on its own. */
    val autoCloseDelayMs: Long?
        get() = when (this) {
            is Delivered -> 1400
            is Resolved, AlreadyReplied -> 2200
            else -> null
        }
}

private data class Attempt(val action: ReplyAction, val text: String)

/**
 * Context-first reply screen for one page, opened from the inbox, a
 * notification tap or a `page://intervention/<id>` link (iOS ReplyView.swift).
 *
 * It watches the live inbox: if the page is answered elsewhere, superseded or
 * resolved while open, the actions disable, a short "Resolved" state shows,
 * and the screen closes itself — so a stale screen can never approve a prompt
 * that's no longer there.
 */
@Composable
fun ReplyScreen(interventionId: String, onDismiss: () -> Unit, onOpenSession: (String) -> Unit) {
    val inbox by RelayClient.inbox.collectAsStateWithLifecycle()
    val deliveries by RelayClient.deliveries.collectAsStateWithLifecycle()
    val closeReasons by RelayClient.recentCloseReasons.collectAsStateWithLifecycle()
    val inboxLoad by RelayClient.inboxLoad.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    /** Last known copy, so content stays readable after the page closes. */
    var snapshot by remember { mutableStateOf<Intervention?>(null) }
    var lookupFinished by remember { mutableStateOf(false) }
    var replyText by remember { mutableStateOf("") }
    var lastAttempt by remember { mutableStateOf<Attempt?>(null) }
    var pendingQuickAction by remember { mutableStateOf<ReplyAction?>(null) }
    var closeLookupFinished by remember { mutableStateOf(false) }
    var lookupRun by remember { mutableStateOf(0) }
    var showDiff by remember { mutableStateOf(false) }
    // Ticks so "sent but unconfirmed" is noticed without other changes.
    val now = rememberNow(10_000)

    val live = inbox.firstOrNull { it.id == interventionId }
    val intervention = live ?: snapshot
    // Only a relay known to predate delivery reporting gets the short legacy
    // window; anything else holds a second answer for the Worker's ack window.
    val legacyRelay = RelayClient.relayIsLegacy && live?.deliveryStatus == null

    fun closedPhase(hadOwnReply: Boolean): Phase {
        val reason = closeReasons[interventionId] ?: snapshot?.closeReason
        return when (val c = ClosedReplyPhase.decide(reason, hadOwnReply, closeLookupFinished)) {
            ClosedReplyPhase.Delivered -> Phase.Delivered(null)
            is ClosedReplyPhase.Resolved -> Phase.Resolved(c.why)
            ClosedReplyPhase.Checking -> Phase.CheckingClose
        }
    }

    val phase: Phase = when (val d = deliveries[interventionId]) {
        ReplyDelivery.Sending -> Phase.Sending
        is ReplyDelivery.Sent -> when {
            live == null -> closedPhase(true)
            ReplyConfirmation.isUnconfirmed(d.at, d.queued, now, legacyRelay) -> Phase.Unconfirmed
            else -> Phase.Sent(d.queued, now.secondsSince(d.at) > ReplyConfirmation.SLOW_AFTER)
        }
        is ReplyDelivery.Delivered -> Phase.Delivered(d.detail)
        is ReplyDelivery.Failed -> if (live != null) Phase.Failed(d.message) else closedPhase(true)
        ReplyDelivery.AlreadyReplied -> Phase.AlreadyReplied
        ReplyDelivery.Gone -> Phase.Resolved("This page was already resolved.")
        null -> when {
            live != null -> Phase.Open
            snapshot != null -> closedPhase(false)
            lookupFinished -> Phase.Missing
            else -> Phase.Loading
        }
    }

    // Finds the page even on a cold start from a notification, when the inbox
    // hasn't loaded yet.
    LaunchedEffect(lookupRun) {
        RelayClient.inbox.value.firstOrNull { it.id == interventionId }?.let { snapshot = it }
        if (snapshot == null) {
            RelayClient.refreshInbox()
            snapshot = RelayClient.inbox.value.firstOrNull { it.id == interventionId }
                ?: RelayClient.history.value.firstOrNull { it.id == interventionId }
        }
        if (snapshot == null) {
            RelayClient.refreshHistory()
            snapshot = RelayClient.history.value.firstOrNull { it.id == interventionId }
        }
        lookupFinished = true
    }
    LaunchedEffect(live) { if (live != null) snapshot = live }
    BackHandler(onBack = onDismiss)
    LaunchedEffect(phase == Phase.CheckingClose) {
        if (phase == Phase.CheckingClose) {
            RelayClient.resolveCloseReason(interventionId)
            closeLookupFinished = true
        }
    }
    LaunchedEffect(phase) {
        val d = phase.autoCloseDelayMs ?: return@LaunchedEffect
        delay(d)
        onDismiss()
    }

    fun send(action: ReplyAction, text: String) {
        if (ReplyOutcome.validate(text, action) != null) return
        lastAttempt = Attempt(action, text)
        scope.launch {
            val outcome = RelayClient.reply(interventionId, text, action)
            if (outcome is ReplyOutcome.Accepted && action == ReplyAction.CUSTOM) replyText = ""
        }
    }

    // Quick actions never carry the draft: the Mac uses non-empty text in
    // place of the action, so a half-typed note would silently turn Deny into
    // a prompt. With a draft present, ask first.
    fun tapQuick(action: ReplyAction) {
        if (replyText.isBlank()) send(action, "") else pendingQuickAction = action
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(colors.surface)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
    ) {
        TopBar(intervention, onDismiss)
        if (intervention != null) {
            Column(
                Modifier
                    .weight(1f)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = Space.xl, vertical = Space.l),
                verticalArrangement = Arrangement.spacedBy(Space.l),
            ) {
                Content(intervention, now, onViewChanges = { showDiff = true }) { onOpenSession(intervention.sessionId) }
            }
            StatusArea(phase, legacyRelay, lastAttempt) { a -> send(a.action, a.text) }
            ActionZone(
                iv = intervention,
                enabled = phase.acceptsInput,
                replyText = replyText,
                onTextChange = { replyText = it },
                onQuick = ::tapQuick,
                onSend = { send(ReplyAction.CUSTOM, it) },
                onClose = onDismiss,
            )
            Text(
                footerText(intervention),
                style = PageType.caption12,
                color = colors.textMuted,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth().padding(start = Space.xl, end = Space.xl, top = Space.s, bottom = Space.l),
            )
        } else {
            Placeholder(phase, inboxLoad.failureMessage, onRetry = { lookupFinished = false; lookupRun++ }, onClose = onDismiss)
        }
    }

    if (showDiff && intervention != null) {
        DiffScreen(intervention.sessionId, intervention.projectName) { showDiff = false }
    }

    pendingQuickAction?.let { action ->
        val draft = replyText.trim()
        val stuck = intervention?.let { PageSubtype.isStuck(it.kind, it.subtype) } == true
        if (stuck && action == ReplyAction.DENY) {
            // "Stop it" on a stuck session: the note would replace the Esc.
            ConfirmDialog(
                "Stop without your note?", "Your typed text won't be sent with Stop.",
                listOf(
                    DialogChoice("Send my note instead") { send(ReplyAction.CUSTOM, draft) },
                    DialogChoice("Stop and discard note", destructive = true) { replyText = ""; send(ReplyAction.DENY, "") },
                ),
            ) { pendingQuickAction = null }
            return@let
        }
        val title = when (action) {
            ReplyAction.APPROVE -> "Approve without your note?"
            ReplyAction.DENY -> "Deny with your note?"
            ReplyAction.CARRY_ON -> "Send your note instead?"
            ReplyAction.CUSTOM -> ""
        }
        val choices = when (action) {
            ReplyAction.APPROVE -> listOf(DialogChoice("Approve and discard note") { replyText = ""; send(ReplyAction.APPROVE, "") })
            ReplyAction.DENY -> listOf(
                DialogChoice("Deny with these instructions") { send(ReplyAction.CUSTOM, draft) },
                DialogChoice("Deny and discard note", destructive = true) { replyText = ""; send(ReplyAction.DENY, "") },
            )
            ReplyAction.CARRY_ON -> listOf(
                DialogChoice("Send my note") { send(ReplyAction.CUSTOM, draft) },
                DialogChoice("Carry on and discard note") { replyText = ""; send(ReplyAction.CARRY_ON, "") },
            )
            ReplyAction.CUSTOM -> emptyList()
        }
        ConfirmDialog(title, "Your typed text won't be sent with this action.", choices) { pendingQuickAction = null }
    }
}

@Composable
private fun TopBar(iv: Intervention?, onDismiss: () -> Unit) {
    Column {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = Space.s, vertical = Space.xs),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(MinTouch).clickable(role = Role.Button, onClick = onDismiss).semantics { contentDescription = "Close" },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = null, tint = colors.text)
            }
            Column(
                Modifier.weight(1f).clearAndSetSemantics {
                    contentDescription = "${iv?.projectName ?: ""}, Session ${iv?.sessionId?.take(8) ?: ""}"
                    heading()
                },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(iv?.projectName ?: " ", style = PageType.mono13, color = colors.textMuted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("Session ${iv?.sessionId?.take(8) ?: ""}", style = PageType.bodyEm, color = colors.text, maxLines = 1)
            }
            Spacer(Modifier.width(MinTouch))
        }
        Box(Modifier.fillMaxWidth().height(0.5.dp).background(colors.hairline))
    }
}

@Composable
private fun Content(iv: Intervention, now: java.time.Instant, onViewChanges: () -> Unit, onOpenSession: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        KindChip(iv.kind, iv.subtype)
        iv.backend?.let { BackendPill(it, iv.source) }
    }
    Text(ReplyCopy.headline(iv), style = PageType.display22, color = colors.text, modifier = Modifier.semantics { heading() })
    Text(RelativeTime.string("Paged", iv.openedAt, now).uppercase(), style = PageType.caption12, color = colors.textMuted)
    val split = TurnSummaryLine.split(iv.kind, iv.context)
    split.summary?.let { TurnSummaryRow(it, onViewChanges) }
    ContextBlock(iv, split.message)
    if (iv.cwd.isNotEmpty()) {
        SelectionContainer {
            Text("Working directory: ${PathDisplay.abbreviatingHome(iv.cwd)}", style = PageType.caption12, color = colors.textMuted)
        }
    }
    OpenSessionLink(iv.sessionId, onOpenSession)
}

@Composable
private fun ContextBlock(iv: Intervention, message: String) {
    // Approvals are usually a command or a diff: monospace, selectable.
    val isCode = iv.kind == InterventionKind.APPROVAL && iv.subtype != "plan"
    val clipboard = LocalClipboardManager.current
    var copied by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1500)
            copied = false
        }
    }
    val shape = RoundedCornerShape(12.dp)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(if (isCode) colors.surfaceInset else colors.surfaceRaised)
            .border(1.dp, colors.hairline, shape)
            .padding(Space.l),
        verticalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(if (isCode) "REQUEST" else "CONTEXT", style = PageType.chip11, color = colors.textMuted, modifier = Modifier.weight(1f))
            Row(
                Modifier
                    .defaultMinSize(minHeight = MinTouch)
                    .clickable(enabled = iv.context.isNotEmpty(), role = Role.Button) {
                        clipboard.setText(AnnotatedString(iv.context))
                        copied = true
                    }
                    .clearAndSetSemantics { contentDescription = if (copied) "Copied" else "Copy request text" }
                    .padding(horizontal = Space.xs),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(14.dp))
                Text(if (copied) "Copied" else "Copy", style = PageType.caption12, color = colors.textMuted)
            }
        }
        SelectionContainer {
            Text(
                message.ifEmpty { "No details were sent with this page." },
                style = if (isCode) PageType.mono13 else PageType.body15,
                color = colors.text,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * The v4 turn summary ("Changed 3 files (+120 −14) · tests passed") above
 * the agent's message, with "View changes" when live sessions work (the diff
 * comes over the encrypted sessions channel).
 */
@Composable
private fun TurnSummaryRow(summary: String, onViewChanges: () -> Unit) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    val canAsk = state.isDemoMode || (state.hasKey && state.relayFeatures?.contains(SessionAvailability.FEATURE) != false)
    val shape = RoundedCornerShape(12.dp)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(colors.kindIdle.copy(alpha = 0.08f))
            .border(1.dp, colors.kindIdle.copy(alpha = 0.3f), shape)
            .padding(start = Space.m, end = Space.xs),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Icon(Icons.Filled.Difference, contentDescription = null, tint = colors.kindIdle, modifier = Modifier.size(16.dp))
        Text(summary, style = PageType.caption12, color = colors.text, modifier = Modifier.weight(1f).padding(vertical = Space.m))
        if (canAsk) TextLink("View changes", modifier = Modifier.padding(horizontal = Space.s), onClick = onViewChanges)
    }
}

/**
 * "Open session", shown while the page's session is live on the Mac. The only
 * part of the reply screen that watches [SessionStore], so session updates
 * recompose this link, not the whole screen.
 */
@Composable
private fun OpenSessionLink(sessionId: String, onOpen: () -> Unit) {
    val state by SessionStore.state.collectAsStateWithLifecycle()
    if (state.session(sessionId) == null) return
    Row(
        Modifier
            .defaultMinSize(minHeight = MinTouch)
            .clickable(role = Role.Button, onClickLabel = "Show this session's live transcript", onClick = onOpen),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Space.s),
    ) {
        Icon(Icons.Filled.Terminal, contentDescription = null, tint = colors.text, modifier = Modifier.size(18.dp))
        Text("Open session", style = PageType.bodyEm, color = colors.text)
    }
}

@Composable
private fun StatusArea(phase: Phase, legacyRelay: Boolean, lastAttempt: Attempt?, onRetry: (Attempt) -> Unit) {
    when (phase) {
        Phase.Open, Phase.Loading, Phase.Missing -> Unit
        Phase.Sending -> StatusStrip(null, "Sending…", colors.textMuted)
        is Phase.Sent -> when {
            phase.queued -> StatusStrip(Icons.Filled.Schedule, "Queued — your Mac is offline. It'll be typed in when the Mac reconnects (within an hour).", colors.warning)
            phase.slow -> StatusStrip(
                null,
                if (legacyRelay) "Sent — waiting for your Mac to confirm…"
                else "Sent — waiting for your Mac. It hasn't confirmed this reply yet; if it reports a failure, or hasn't confirmed within 20 minutes, you can answer again.",
                colors.textMuted,
            )
            else -> StatusStrip(null, "Sent — waiting for your Mac to confirm…", colors.textMuted)
        }
        Phase.CheckingClose -> StatusStrip(null, "This page closed — checking whether your reply landed…", colors.textMuted)
        is Phase.Delivered -> StatusStrip(Icons.Filled.CheckCircle, "Delivered — ${phase.detail ?: "typed into the session on your Mac"}.", colors.success)
        is Phase.Failed -> StatusStrip(Icons.Filled.Warning, "Failed: ${phase.message}", colors.destructiveText) {
            if (lastAttempt != null) TextLink("Retry") { onRetry(lastAttempt) }
        }
        Phase.Unconfirmed -> StatusStrip(Icons.Outlined.HelpOutline, "Your Mac never confirmed this reply. If the session is still waiting, you can answer again.", colors.warning)
        Phase.AlreadyReplied -> StatusStrip(Icons.Outlined.CheckCircle, "Already answered — another reply (maybe from a notification) got there first.", colors.textMuted)
        is Phase.Resolved -> StatusStrip(Icons.Outlined.CheckCircle, "Resolved — ${phase.why}", colors.textMuted)
    }
}

@Composable
private fun ActionZone(
    iv: Intervention,
    enabled: Boolean,
    replyText: String,
    onTextChange: (String) -> Unit,
    onQuick: (ReplyAction) -> Unit,
    onSend: (String) -> Unit,
    onClose: () -> Unit,
) {
    Column(
        Modifier.padding(start = Space.xl, end = Space.xl, top = Space.m),
        verticalArrangement = Arrangement.spacedBy(Space.m),
    ) {
        when (iv.kind) {
            InterventionKind.APPROVAL -> {
                val plan = iv.subtype == "plan"
                Row(horizontalArrangement = Arrangement.spacedBy(Space.s)) {
                    QuickButton(if (plan) "Approve plan" else "Approve", QuickButtonStyle.ACCENT, enabled, Modifier.weight(1f)) { onQuick(ReplyAction.APPROVE) }
                    QuickButton(if (plan) "Keep planning" else "Deny", QuickButtonStyle.DESTRUCTIVE, enabled, Modifier.weight(1f)) { onQuick(ReplyAction.DENY) }
                }
                if (iv.acceptsDecisionsOnly) {
                    // The relay refuses anything else for these (422).
                    Text("This page comes from an older Page hook that can only apply Approve or Deny.", style = PageType.caption12, color = colors.textMuted)
                } else {
                    ReplyField(replyText, onTextChange, "Deny with instructions…", enabled, onSend = onSend)
                }
            }
            InterventionKind.USER_INPUT -> ReplyField(replyText, onTextChange, "Type your answer…", enabled, onSend = onSend)
            InterventionKind.IDLE -> if (PageSubtype.isStuck(iv.kind, iv.subtype)) {
                // v4 stuck watch: no Carry on. Stop presses Esc (deny); not for a stalled workflow.
                if (PageSubtype.canStop(iv.kind, iv.subtype)) {
                    QuickButton("Stop it", QuickButtonStyle.DESTRUCTIVE, enabled) { onQuick(ReplyAction.DENY) }
                }
                ReplyField(replyText, onTextChange, "Tell it what to do instead…", enabled, onSend = onSend)
            } else {
                QuickButton("Carry on", QuickButtonStyle.OUTLINE, enabled) { onQuick(ReplyAction.CARRY_ON) }
                ReplyField(replyText, onTextChange, "Tell it what to do next…", enabled, onSend = onSend)
            }
            InterventionKind.RATE_LIMIT -> if (PageSubtype.isForecast(iv.kind, iv.subtype)) {
                Text("Nothing to answer: this is a heads-up from Page on your Mac.", style = PageType.caption12, color = colors.textMuted)
                QuickButton("Close", QuickButtonStyle.OUTLINE, true, onClick = onClose)
            } else {
                // v4: the Mac queues a written reply and types it when the limit resets.
                ReplyField(replyText, onTextChange, "Send this when the limit resets…", enabled, sendLabel = "Send when the limit resets", onSend = onSend)
            }
        }
    }
}

private fun footerText(iv: Intervention): String {
    if (PageSubtype.isForecast(iv.kind, iv.subtype)) return "A heads-up from Page on your Mac."
    if (iv.kind == InterventionKind.RATE_LIMIT) return "Page on your Mac types your reply into session ${iv.sessionId.take(8)} when the limit resets."
    if (iv.isBlockingHook) return "Your answer goes straight to ${iv.agentName}'s permission hook in session ${iv.sessionId.take(8)}."
    var where = "session ${iv.sessionId.take(8)}"
    val source = iv.source
    if (source != null && source != InterventionSource.UNKNOWN) where += " (${source.label})"
    return "Page types your reply into $where on your Mac."
}

@Composable
private fun Placeholder(phase: Phase, failure: String?, onRetry: () -> Unit, onClose: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(Space.xxl),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Space.m, Alignment.CenterVertically),
    ) {
        when {
            phase == Phase.Missing && failure != null -> {
                Icon(Icons.Filled.WifiOff, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(40.dp))
                Text("Couldn't load this page", style = PageType.title17, color = colors.text)
                Text(failure, style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center)
                TextLink("Try again", onClick = onRetry)
            }
            phase == Phase.Missing -> {
                Icon(Icons.Outlined.CheckCircle, contentDescription = null, tint = colors.textMuted, modifier = Modifier.size(40.dp))
                Text("This page is no longer available", style = PageType.title17, color = colors.text)
                Text("It was probably answered or resolved on your Mac.", style = PageType.body15, color = colors.textMuted, textAlign = TextAlign.Center)
                TextLink("Close", onClick = onClose)
            }
            else -> {
                CircularProgressIndicator(color = colors.textMuted)
                Text("Loading…", style = PageType.body15, color = colors.textMuted)
            }
        }
    }
}
