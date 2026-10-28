package app.page.android.ui.nw.decision

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.material3.CircularProgressIndicator
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import app.page.android.data.ActionCoordinator
import app.page.android.data.AppRouter
import app.page.android.data.BiometricGate
import app.page.android.data.NowStore
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.data.SteerChoiceStore
import app.page.android.data.TipStore
import app.page.android.model.ActionGate
import app.page.android.model.AnswerPicker
import app.page.android.model.CardOutcome
import app.page.android.model.ChipKind
import app.page.android.model.DecisionContent
import app.page.android.model.DecisionPhase
import app.page.android.model.Intervention
import app.page.android.model.OutboxRestore
import app.page.android.model.QueuedDelete
import app.page.android.model.plusSeconds
import app.page.android.model.SendChoice
import app.page.android.model.SendReceipt
import app.page.android.model.SendWhen
import app.page.android.model.NowRow
import app.page.android.model.NowRowBuilder
import app.page.android.model.ReceiptThreadInput
import app.page.android.model.ReplyOutcome
import app.page.android.model.RowAction
import app.page.android.model.SessionTarget
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.rememberNWNow
import app.page.android.ui.nw.theme.NW
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The Decision sheet, live: finds the page (even on a cold launch from a notification), derives what the sheet is
 * showing from live state, and routes every action through [ActionCoordinator] and [RelayClient]. It watches the
 * live inbox: if the page is answered elsewhere, superseded or resolved while open, the controls go away, a short
 * result shows, and the sheet closes itself, so a stale screen can never approve a prompt that's no longer
 * there. (iOS DecisionContainer.swift.)
 */
@Composable
fun DecisionContainer(
    interventionId: String,
    onViewChanges: (String, String) -> Unit,
    modifier: Modifier = Modifier,
    /** Closes the sheet (the router's sheet by default; a sheet opened from inside a room passes its own). */
    onClose: () -> Unit = AppRouter::closeSheet,
    /** "Open session": hands over to the room, or, from inside the room, just comes back to it. */
    onOpenSession: (String) -> Unit = { AppRouter.openSession(it) },
) {
    val inbox by RelayClient.inbox.collectAsStateWithLifecycle()
    val history by RelayClient.history.collectAsStateWithLifecycle()
    val deliveries by RelayClient.deliveries.collectAsStateWithLifecycle()
    val deliveryTimes by RelayClient.deliveryTimes.collectAsStateWithLifecycle()
    val closeReasons by RelayClient.recentCloseReasons.collectAsStateWithLifecycle()
    val inboxLoad by RelayClient.inboxLoad.collectAsStateWithLifecycle()
    val sessionState by SessionStore.state.collectAsStateWithLifecycle()
    val pending by ActionCoordinator.pending.collectAsStateWithLifecycle()
    val problems by ActionCoordinator.localProblems.collectAsStateWithLifecycle()
    val book by TipStore.book.collectAsStateWithLifecycle()
    val mac by PairingStore.pairedMac.collectAsStateWithLifecycle()
    val macName = mac?.name ?: ""
    val context = LocalContext.current
    val biometry = remember { BiometricGate.methodName(context) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    var snapshot by remember(interventionId) { mutableStateOf<Intervention?>(null) }
    var lookupFinished by remember(interventionId) { mutableStateOf(false) }
    var closeLookupFinished by remember(interventionId) { mutableStateOf(false) }
    var draft by remember(interventionId) { mutableStateOf("") }
    // Steer on a card opens the sheet with the composer already up (and focused): one tap.
    var composerOpen by remember(interventionId) {
        mutableStateOf(app.page.android.ui.nw.shell.RenderHarness.spec.value?.screen == "decision-composer" || AppRouter.takeSheetComposer(interventionId))
    }
    var restoredNote by remember(interventionId) { mutableStateOf<String?>(null) }
    // A Steer that went to the countdown or the Mac's hold: the same words again within a second are one tap's echo.
    var lastSend by remember(interventionId) { mutableStateOf<app.page.android.model.DraftSubmit.Last?>(null) }
    val retractNotes by RelayClient.retractNotes.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) { SteerChoiceStore.ensureLoaded() }
    val lastChoice by SteerChoiceStore.last.collectAsStateWithLifecycle()
    val choiceExplained by SteerChoiceStore.explained.collectAsStateWithLifecycle()
    var holdCommittedAt by remember(interventionId) { mutableStateOf<java.time.Instant?>(null) }
    var showedTip by remember(interventionId) { mutableStateOf(false) }

    val live = inbox.firstOrNull { it.id == interventionId }
    val intervention = live ?: snapshot
    val arming = ActionCoordinator.isArming(interventionId)
    // The arm ring and a Steer's 10 s countdown read in fractions of seconds: the clock runs fast while either is moving.
    val countdownEnd = sessionState.outbox.entries.filter { it.pageId == interventionId }.minOfOrNull { it.startedAt }
        ?.plusSeconds(app.page.android.model.SendCountdown.SECONDS + 0.5)
    val now by rememberNWNow(until = if (arming) Instant.now().plusSeconds(2) else countdownEnd, fastMs = if (arming) 100 else 250)
    val legacyRelay = RelayClient.relayIsLegacy && live?.deliveryStatus == null
    val phase = DecisionPhase.derive(
        DecisionPhase.Inputs(
            delivery = deliveries[interventionId], isLive = live != null, hasSnapshot = snapshot != null, lookupFinished = lookupFinished,
            closeReason = closeReasons[interventionId] ?: snapshot?.closeReason, closeLookupFinished = closeLookupFinished, now = now, legacyRelay = legacyRelay,
        ),
    )

    LaunchedEffect(live) { if (live != null) snapshot = live }
    LaunchedEffect(interventionId) {
        // Finds the page even on a cold launch from a notification, when the inbox hasn't loaded yet.
        live?.let { snapshot = it }
        if (snapshot == null) {
            if (!RelayClient.isDemoMode) RelayClient.refreshInbox()
            snapshot = RelayClient.inbox.value.firstOrNull { it.id == interventionId } ?: RelayClient.history.value.firstOrNull { it.id == interventionId }
        }
        if (snapshot == null && !RelayClient.isDemoMode) {
            RelayClient.refreshHistory()
            snapshot = RelayClient.history.value.firstOrNull { it.id == interventionId }
        }
        lookupFinished = true
    }
    DisposableEffect(interventionId) { onDispose { if (showedTip) TipStore.retire(app.page.android.model.NWTip.WILL_TYPE) } }
    // The committed ring belongs to that one approve: the sheet taking input again after a failure puts it away.
    LaunchedEffect(pending[interventionId]) {
        pending[interventionId]?.let { p -> holdCommittedAt = if (ActionGate.requiresBiometrics(p.kind, p.commit)) p.startedAt else null }
    }
    LaunchedEffect(phase.acceptsInput) { if (phase.acceptsInput) holdCommittedAt = null }
    LaunchedEffect(phase == DecisionPhase.CheckingClose) {
        if (phase == DecisionPhase.CheckingClose) {
            RelayClient.resolveCloseReason(interventionId)
            closeLookupFinished = true
        }
    }
    LaunchedEffect(phase) {
        // The render harness holds a delivered sheet open to draw it.
        if (app.page.android.ui.nw.shell.RenderHarness.spec.value != null) return@LaunchedEffect
        val d = phase.autoCloseDelay ?: return@LaunchedEffect
        delay((d * 1000).toLong())
        onClose()
    }

    val iv = intervention
    if (iv == null) {
        Placeholder(phase, inboxLoad.failureMessage, modifier, onClose) { lookupFinished = false }
        return
    }
    val session = sessionState.session(iv.sessionId)
    val row = NowRowBuilder.row(iv, session, macName)
    // A Steer that did not go (the app closed before its countdown ended) is back in the box, with why.
    LaunchedEffect(iv.sessionId, sessionState.restoredDrafts[iv.sessionId], row.action(RowAction.Kind.TELL_INSTEAD) != null) {
        if (row.action(RowAction.Kind.TELL_INSTEAD) == null) return@LaunchedEffect
        SessionStore.takeRestoredDraft(iv.sessionId)?.let { d -> draft = OutboxRestore.merge(d.text, draft); composerOpen = true; restoredNote = d.note }
    }
    val content = DecisionContent.build(iv, row, session, macName)
    val problem = problems[iv.id]
    val outcome: CardOutcome = when {
        problem != null -> CardOutcome.Problem(problem)
        arming -> CardOutcome.Arming(0.0)
        else -> CardOutcome.None
    }
    val receipt = ReceiptThreadInput(pending[iv.id], deliveries[iv.id], problem, deliveryTimes[iv.id])
    // A question the session is blocked on, answerable by tapping: only for the page the Mac has open for it (a
    // hook-held page is answered through its own text reply).
    val ask = AnswerPicker.ask(session, content.chip == ChipKind.QUESTION, iv.isBlockingHook, iv.context)
        ?.takeIf { iv.isBlockingHook || session?.interventionId == iv.id }
    val askDelivery = ask?.let {
        if (iv.isBlockingHook) AnswerPicker.delivery(CardOutcome.from(pending[iv.id], deliveries[iv.id], now), iv.sessionId, it.id, now)
        else sessionState.latestAnswer(iv.sessionId, it.id)
    }
    // How a Steer to a busy session goes: only on a look or review page whose session is working (never a decision,
    // and never a rate limit, whose "Send after reset" is already held on the Mac).
    val steers = row.action(RowAction.Kind.TELL_INSTEAD) != null && row.chip != ChipKind.QUESTION && row.chip != ChipKind.RATE_LIMITED &&
        (row.section == NowRow.Section.LOOK || row.section == NowRow.Section.REVIEW)
    val choice = if (steers && session != null) SendChoice.forSession(session, false, sessionState.caps, lastChoice) else null
    val agentName = session?.backend?.displayName ?: iv.agentName
    // This page's countdown, else the newest message the Mac holds for its session.
    val countdown = sessionState.outbox.entries.filter { it.pageId == iv.id }.minByOrNull { it.startedAt }
    val heldMessage = sessionState.sentMessages(iv.sessionId).lastOrNull { it.state is app.page.android.model.SessionDeliveryState.Held }
    val sendReceipt = (
        SendReceipt.build(
            heldMessage, agentName, now, scheduled = countdown, delete = heldMessage?.let { sessionState.deletes[it.clientId] },
            canDelete = heldMessage != null && QueuedDelete.heldMessage(heldMessage.state, sessionState.caps, sessionState.deletes[heldMessage.clientId]),
        ) ?: restoredNote?.let { SendReceipt("restored", it, null, SendReceipt.Tone.NOTE) }
        )
    // Delete for a queued reply: only where the relay (or the Mac, for a rate-limit hold) says it can take it back.
    val deleteLayer = QueuedDelete.reply(deliveries[iv.id], iv.isBlockingHook, sessionState.relayFeatures, sessionState.caps)
    val deleteNote = retractNotes[iv.id] ?: if (deleteLayer == null) QueuedDelete.whyNot(deliveries[iv.id], iv.isBlockingHook, sessionState.relayFeatures, sessionState.caps, sessionState.hasList) else null
    val state = DecisionScreenState(
        content = content, row = row, phase = phase, legacyRelay = legacyRelay, now = now, biometry = biometry, pending = pending[iv.id], outcome = outcome,
        hasSession = session != null, ask = ask, askDelivery = askDelivery, macName = macName, askViaHook = iv.isBlockingHook, receipt = receipt,
        holdCommittedAt = holdCommittedAt, fixedHold = app.page.android.ui.nw.shell.RenderHarness.spec.value?.hold, tip = book.decisionTip(row.focusPreview != null && row.action(RowAction.Kind.OPEN_ON_MAC) == null),
        deleteLayer = deleteLayer, deleteNote = deleteNote, choice = choice, choiceExplained = choiceExplained, sendReceipt = sendReceipt,
    )
    val actions = DecisionScreenActions(
        approve = { ActionCoordinator.begin(row, RowAction.Kind.APPROVE) },
        holdComplete = { ActionCoordinator.commitHold(row, macName) },
        deny = { ActionCoordinator.begin(row, RowAction.Kind.DENY) },
        carryOn = { ActionCoordinator.begin(row, RowAction.Kind.CARRY_ON) },
        stop = { ActionCoordinator.begin(row, RowAction.Kind.STOP) },
        send = send@{ text ->
            // Neither path below has a ring that refuses a second start, so one tap that arrives twice is caught here.
            if (choice != null) {
                if (app.page.android.model.DraftSubmit.isDuplicate(text, lastSend, java.time.Instant.now())) return@send
                lastSend = app.page.android.model.DraftSubmit.Last(text, java.time.Instant.now())
            }
            when {
                // When it finishes: the Mac holds it (session input, with the folder and terminal this sheet showed).
                choice?.selected == SendWhen.WHEN_FINISHED && session != null -> {
                    val problem = SessionStore.sendInput(iv.sessionId, text, SessionTarget.of(session, macName), hold = true)
                    if (problem == null) { SteerChoiceStore.markExplained(); draft = ""; composerOpen = false; restoredNote = null }
                }
                // Now, to a working session: 10 s to Undo first, then the page's own reply path (in place of the 1.2 s ring).
                choice != null -> {
                    val problem = SessionStore.scheduleInput(iv.sessionId, text, session?.let { SessionTarget.of(it, macName) }, pageId = iv.id)
                    if (problem == null) { if (choice.isChoice) SteerChoiceStore.markExplained(); draft = ""; composerOpen = false; restoredNote = null }
                }
                // A written reply: Esc, then the text, then Return, which the Mac's reply planner does.
                else -> ActionCoordinator.begin(row, RowAction.Kind.TELL_INSTEAD, text) { outcome2 -> if (outcome2 is ReplyOutcome.Accepted) { draft = ""; composerOpen = false } }
            }
        },
        selectWhen = SteerChoiceStore::select,
        dismissNote = { restoredNote = null },
        delete = {
            when (deleteLayer) {
                QueuedDelete.Layer.RELAY_QUEUE -> scope.launch { RelayClient.retractReply(iv.id) }
                QueuedDelete.Layer.MAC_RATE_LIMIT -> RelayClient.deleteHeldReply(iv.id)
                else -> Unit
            }
        },
        sendReceiptAction = { r ->
            when (r.action) {
                SendReceipt.Action.UNDO -> SessionStore.undoScheduled(r.id)?.let { draft = OutboxRestore.merge(it, draft); composerOpen = true }
                SendReceipt.Action.DELETE -> SessionStore.deleteHeld(r.id)
                null -> Unit
            }
        },
        submitAnswers = { sheet ->
            when (val s = AnswerPicker.submit(iv.isBlockingHook, true, sheet)) {
                is AnswerPicker.Submit.Refuse -> Unit
                // The hook maps the numbers to Claude's options; nothing is pressed.
                is AnswerPicker.Submit.Hook -> ActionCoordinator.begin(row, RowAction.Kind.TELL_INSTEAD, s.text)
                AnswerPicker.Submit.Keys -> {
                    val target = session?.let { SessionTarget.of(it, macName) }
                    SessionStore.sendAnswer(iv.sessionId, sheet, target)
                }
            }
        },
        cancel = { ActionCoordinator.cancel(iv.id) },
        openSession = { onOpenSession(iv.sessionId) },
        viewChanges = { onViewChanges(iv.sessionId, iv.projectName) },
        close = onClose,
        dismissTip = { TipStore.retire(it) },
        tipShown = { showedTip = true },
    )
    NWDecisionScreen(state, actions, draft, { draft = it }, composerOpen, { composerOpen = it }, modifier)
}

@Composable
private fun Placeholder(phase: DecisionPhase, failure: String?, modifier: Modifier, onClose: () -> Unit, onRetry: () -> Unit) {
    Box(modifier.fillMaxSize().background(decisionBackground(null)), contentAlignment = Alignment.Center) {
        Column(Modifier.padding(32.dp).widthIn(max = 360.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            when {
                phase == DecisionPhase.Missing && failure != null -> {
                    Text("Couldn't load this page", style = NW.Typo.headline, color = NW.Palette.textPrimary.color)
                    Text(failure, style = NW.Typo.body, color = NW.Palette.textSecondary.color, textAlign = TextAlign.Center)
                    NWButton("Try again", onRetry)
                }
                phase == DecisionPhase.Missing -> {
                    Text("This page is no longer available", style = NW.Typo.headline, color = NW.Palette.textPrimary.color, textAlign = TextAlign.Center)
                    Text("It was probably answered or resolved on your Mac.", style = NW.Typo.body, color = NW.Palette.textSecondary.color, textAlign = TextAlign.Center)
                    NWButton("Close", onClose)
                }
                else -> {
                    CircularProgressIndicator(color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
                    Text("Loading…", style = NW.Typo.body, color = NW.Palette.textSecondary.color)
                }
            }
        }
    }
}
