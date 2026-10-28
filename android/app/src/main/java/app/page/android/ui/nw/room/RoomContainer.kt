package app.page.android.ui.nw.room

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
import app.page.android.data.ActionCoordinator
import app.page.android.data.AppRouter
import app.page.android.data.PairingStore
import app.page.android.data.PhotoPrep
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.data.SteerChoiceStore
import app.page.android.model.AnswerPicker
import app.page.android.model.CardOutcome
import app.page.android.model.DraftSubmit
import app.page.android.model.ArmSpec
import app.page.android.model.LiveSession
import app.page.android.model.OutboxRestore
import app.page.android.model.PhotoDraft
import app.page.android.model.PhotoLimits
import app.page.android.model.PhotoSend
import app.page.android.model.PhotoStatus
import app.page.android.model.SessionTarget
import app.page.android.model.YesNoArm
import app.page.android.model.SendReceipt
import app.page.android.model.SendWhen
import app.page.android.model.SessionComposer
import app.page.android.model.plusSeconds
import app.page.android.model.MacPresence
import app.page.android.model.NowRowBuilder
import app.page.android.model.RoomBanner
import app.page.android.model.RoomComposerMode
import app.page.android.model.RoomEntry
import app.page.android.model.RoomLens
import app.page.android.model.RoomSend
import app.page.android.model.RowAction
import app.page.android.model.UsageCardModel
import app.page.android.model.WorkflowOrbit
import app.page.android.model.AgentRoomModel
import app.page.android.ui.nw.components.NWButton
import app.page.android.ui.nw.components.NWSheetHost
import app.page.android.ui.nw.components.rememberNWNow
import app.page.android.ui.nw.decision.DecisionContainer
import app.page.android.ui.nw.decision.decisionBackground
import app.page.android.ui.nw.theme.NW
import java.time.Instant
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID

/**
 * The Session Room, live. It keeps what the old session screen did: it tells the Mac it is watching (re-sent every
 * 30 s, which is what makes the Mac send this session's transcript at all), holds on to the last copy so the room
 * stays readable after the session ends, and routes every action through the existing services:
 *
 * - a message to a busy or idle session is [SessionStore.sendInput] (text plus Return; the Mac's input gate still
 *   decides), carrying the target the room showed (expectCwd / expectTitle);
 * - a written reply to a waiting prompt is [ActionCoordinator] with TELL_INSTEAD, which the page sends as Esc,
 *   then the text, then Return; it is never sent as session input;
 * - Approve, Deny and Looks good on the pinned page are the same [ActionCoordinator] calls Now makes;
 * - answers to a question go through [SessionStore.sendAnswer] (or the page's text path for a hook);
 * - Stop is [SessionStore.interrupt], behind a 10 s hold.
 *
 * The drawing is [NWSessionRoom]. (iOS SessionRoomContainer.swift.)
 */
@Composable
fun RoomContainer(sessionId: String, entry: RoomEntry, modifier: Modifier = Modifier) {
    val sessionState by SessionStore.state.collectAsStateWithLifecycle()
    val inbox by RelayClient.inbox.collectAsStateWithLifecycle()
    val connection by RelayClient.connection.collectAsStateWithLifecycle()
    val status by RelayClient.macStatus.collectAsStateWithLifecycle()
    val deliveries by RelayClient.deliveries.collectAsStateWithLifecycle()
    val pending by ActionCoordinator.pending.collectAsStateWithLifecycle()
    val problems by ActionCoordinator.localProblems.collectAsStateWithLifecycle()
    val mac by PairingStore.pairedMac.collectAsStateWithLifecycle()
    val macName = mac?.name ?: ""
    val clip = LocalClipboardManager.current
    val scope = androidx.compose.runtime.rememberCoroutineScope()

    var draft by remember(sessionId) { mutableStateOf("") }
    var composerProblem by remember(sessionId) { mutableStateOf<String?>(null) }
    var lastSend by remember(sessionId) { mutableStateOf<DraftSubmit.Last?>(null) }
    var snapshot by remember(sessionId) { mutableStateOf<LiveSession?>(null) }
    var lens by remember(sessionId) { mutableStateOf(entry.lens) }
    var runId by remember(sessionId) { mutableStateOf<String?>(null) }
    var presentedPage by remember(sessionId) { mutableStateOf<String?>(null) }
    var agent by remember(sessionId) { mutableStateOf<Pair<String, String>?>(null) }
    var diffRequestedAt by remember(sessionId) { mutableStateOf(Instant.EPOCH) }
    var dismissedReceipt by remember(sessionId) { mutableStateOf<String?>(null) }
    var stopHint by remember(sessionId) { mutableStateOf(entry.showsStopHint) }
    // A Yes or No in its 1.2 s window, and the note for a message that was put back in the box unsent.
    var yesNoArm by remember(sessionId) { mutableStateOf<YesNoArm?>(null) }
    var fireYesNo by remember(sessionId) { mutableStateOf<String?>(null) }
    var restoredNote by remember(sessionId) { mutableStateOf<String?>(null) }
    // Photos picked for the next message: the tray (each encoding, ready or failed) and a thumbnail for each.
    var photoDraft by remember(sessionId) { mutableStateOf(PhotoDraft()) }
    val thumbs = remember(sessionId) { mutableStateMapOf<String, androidx.compose.ui.graphics.ImageBitmap>() }
    val encodeLock = remember(sessionId) { Mutex() }
    val resolver = LocalContext.current.contentResolver
    LaunchedEffect(Unit) { SteerChoiceStore.ensureLoaded() }
    val lastChoice by SteerChoiceStore.last.collectAsStateWithLifecycle()
    val choiceExplained by SteerChoiceStore.explained.collectAsStateWithLifecycle()

    val live = sessionState.session(sessionId)
    val session = live ?: snapshot
    val ended = live == null && sessionState.hasList && snapshot != null
    // The countdown and the arm ring read in seconds: the clock runs fast while either is moving.
    val moveUntil = listOfNotNull(
        sessionState.outbox.next(sessionId)?.startedAt?.plusSeconds(app.page.android.model.SendCountdown.SECONDS + 0.5),
        yesNoArm?.deadline?.plusMillis(300),
    ).maxOrNull()
    val now by rememberNWNow(until = moveUntil, fastMs = 250, slowMs = 2_000)

    fun requestChanges() {
        if (ended || session == null) return
        diffRequestedAt = Instant.now()
        SessionStore.requestDiff(sessionId)
    }

    LaunchedEffect(live) { live?.let { snapshot = it } }
    LaunchedEffect(sessionId) { requestChanges() }
    // A message that did not go (the app closed first, or its session left the list) is back in the box, with why.
    LaunchedEffect(sessionId, sessionState.restoredDrafts[sessionId]) {
        SessionStore.takeRestoredDraft(sessionId)?.let { d -> draft = OutboxRestore.merge(d.text, draft); restoredNote = d.note }
    }
    // The Yes or No ring runs out: it sends (through the same gate as typed words), unless it was cancelled.
    LaunchedEffect(yesNoArm) {
        val a = yesNoArm ?: return@LaunchedEffect
        delay((ArmSpec.duration * 1000).toLong())
        if (yesNoArm == a) {
            yesNoArm = null
            fireYesNo = a.word
        }
    }
    LaunchedEffect(stopHint) { if (stopHint) { delay(8000); stopHint = false } }
    // Watch while the app is on screen and connected; the store re-arms it after a reconnect, and sends nothing while
    // the socket is down. With Stay connected on, the relay socket outlives the app's visibility, so the room stops
    // watching when the app stops (the Mac stops streaming this session's screen and transcript to a pocketed phone)
    // and watches again when it is back.
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    // Keyed on the session too: the overlay can swap one room for another in place, and the old loop must not
    // keep re-watching a session the room has left.
    LaunchedEffect(sessionId, connection == RelayClient.ConnectionState.CONNECTED, lifecycle) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.STARTED) {
            try {
                var resumed = true
                while (true) {
                    SessionStore.watch(sessionId)
                    // Back from a stop: a workflow agent's room that was open watches again too.
                    if (resumed) agent?.let { SessionStore.watchAgent(sessionId, it.first, it.second) }
                    resumed = false
                    delay(30_000)
                }
            } finally {
                // Only a real stop un-watches: a reconnect restarts this effect and watches again straight away.
                if (!lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) SessionStore.watch(null)
            }
        }
    }
    DisposableEffect(sessionId) { onDispose { SessionStore.watch(null) } }


    // The system photo picker: no storage permission, and nothing is read until a photo is chosen. Each pick is decoded and
    // re-encoded (metadata dropped) one at a time, each within what is left of the message's 2.5 MiB.
    fun picked(uris: List<android.net.Uri>) {
        if (uris.isEmpty()) return
        val ids = uris.map { UUID.randomUUID().toString() }
        val (next, took) = photoDraft.adding(ids)
        photoDraft = next
        if (uris.size > took) composerProblem = photoLimitNote
        else composerProblem = null
        for (n in 0 until took) {
            val id = ids[n]
            val uri = uris[n]
            scope.launch {
                encodeLock.withLock {
                    // Removed while it waited its turn: nothing to do.
                    if (photoDraft.items.none { it.id == id }) return@withLock
                    when (val r = PhotoPrep.prepare(resolver, uri, photoDraft.nextBudget)) {
                        is PhotoPrep.Result.Ok -> {
                            if (photoDraft.items.none { it.id == id }) return@withLock
                            thumbs[id] = r.thumbnail.asImageBitmap()
                            photoDraft = photoDraft.with(id, PhotoStatus.Ready(r.photo))
                        }
                        is PhotoPrep.Result.Failed -> if (photoDraft.items.any { it.id == id }) photoDraft = photoDraft.with(id, PhotoStatus.Failed(r.why))
                    }
                }
            }
        }
    }
    val pickMany = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(PhotoLimits.MAX_PHOTOS)) { picked(it) }
    val pickOne = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { picked(listOfNotNull(it)) }
    fun openPicker() {
        val request = PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)
        when {
            photoDraft.remaining <= 0 -> composerProblem = photoLimitNote
            // The multiple-choice picker needs room for more than one.
            photoDraft.remaining == 1 -> pickOne.launch(request)
            else -> pickMany.launch(request)
        }
    }

    if (session == null) {
        Box(modifier.fillMaxSize().background(NW.Palette.backgroundDeep.color), contentAlignment = Alignment.Center) {
            Column(Modifier.padding(32.dp).widthIn(max = 360.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
                if (sessionState.hasList) {
                    Text("This session isn't running", style = NW.Typo.headline, color = NW.Palette.textPrimary.color, textAlign = TextAlign.Center)
                    Text("It's not on your Mac's list of live sessions anymore.", style = NW.Typo.body, color = NW.Palette.textSecondary.color, textAlign = TextAlign.Center)
                    NWButton("Close", AppRouter::closeSheet)
                } else {
                    CircularProgressIndicator(color = NW.Palette.textSecondary.color, strokeWidth = 2.dp)
                    Text("Loading…", style = NW.Typo.body, color = NW.Palette.textSecondary.color)
                }
            }
        }
        return
    }

    val presence = MacPresence.evaluate(status, now)
    val availability = sessionState.availability(presence, connection == RelayClient.ConnectionState.CONNECTED, now)
    val page = inbox.firstOrNull { it.sessionId == sessionId }
    val row = page?.let { NowRowBuilder.row(it, session, macName) }
    var outcome: CardOutcome = CardOutcome.None
    if (row != null) {
        outcome = problems[row.id]?.let { CardOutcome.Problem(it) } ?: CardOutcome.from(pending[row.id], deliveries[row.id], now)
    }
    val diffReq = sessionState.diffs[sessionId]
    val inputs = SessionRoomData.Inputs(
        session = session, ended = ended, availability = availability, macName = macName, now = now,
        transcript = sessionState.transcripts[sessionId], sent = sessionState.sentMessages(sessionId), screen = sessionState.screens[sessionId],
        runs = sessionState.workflows[sessionId] ?: emptyList(), diff = diffReq?.answer, diffError = diffReq?.error, diffRequestedAt = diffRequestedAt,
        fiveHourPct = UsageCardModel.from(status?.usage, now)?.fiveHour?.pct,
        pageRow = row, pageOutcome = outcome, pagePending = row?.let { pending[it.id] }, latestStop = sessionState.latestInterrupt(sessionId, now),
        composerProblem = composerProblem, latestInput = sessionState.latestInput(sessionId), dismissedReceipt = dismissedReceipt,
        answerDelivery = session.ask?.let { sessionState.latestAnswer(sessionId, it.id) },
        pageIsHook = page?.isBlockingHook ?: false, pageContext = page?.context,
        caps = sessionState.caps, sendWhen = lastChoice, choiceExplained = choiceExplained, outbox = sessionState.outbox,
        deletes = sessionState.deletes, restoredNote = restoredNote, yesNoArm = yesNoArm, uploads = sessionState.uploads, stagedPhotos = photoDraft.count,
    )
    val data = SessionRoomData.make(inputs)
    val shownLens = RoomLens.resolve(lens, data.lenses)

    fun send(text: String) {
        val decision = RoomSend.decide(data.composer, text, data.session, sessionId, live, ended, row?.action(RowAction.Kind.TELL_INSTEAD) != null, macName, data.choice)
        if (decision is RoomSend.Decision.Refuse) { composerProblem = decision.why; return }
        // One Return can arrive twice (the field's submit and its trailing newline): type it once.
        if (DraftSubmit.isDuplicate(text, lastSend, Instant.now())) return
        when (decision) {
            is RoomSend.Decision.Refuse -> Unit
            RoomSend.Decision.TellInstead -> {
                // Esc, then your words, then Return: the page's own path, with its arm ring.
                if (row == null) { composerProblem = "This prompt's page isn't loaded yet, so nothing was sent."; return }
                if (pending[row.id] != null) { composerProblem = "Your reply to this prompt is already on its way."; return }
                composerProblem = null
                lastSend = DraftSubmit.Last(text, Instant.now())
                ActionCoordinator.begin(row, RowAction.Kind.TELL_INSTEAD, text) { o -> if (o is app.page.android.model.ReplyOutcome.Accepted) draft = "" }
            }
            is RoomSend.Decision.Input -> {
                val problem: SessionComposer.Problem? = when {
                    // "When it finishes": the Mac holds it (a delete is offered while it does).
                    decision.sendWhen == SendWhen.WHEN_FINISHED -> SessionStore.sendInput(sessionId, text, decision.target, hold = true)
                    // "Now" to a busy session: 10 s to Undo first. The countdown is the store's, so leaving this room does not cancel it.
                    data.composer == RoomComposerMode.Steer -> SessionStore.scheduleInput(sessionId, text, decision.target)
                    else -> SessionStore.sendInput(sessionId, text, decision.target)
                }
                if (problem != null) { composerProblem = problem.message; return }
                // The explanations under the choice were said once; they are not said again.
                if (data.choice?.isChoice == true) SteerChoiceStore.markExplained()
                lastSend = DraftSubmit.Last(text, Instant.now())
                draft = ""
                composerProblem = null
                dismissedReceipt = null
                restoredNote = null
            }
        }
    }

    // Send with photos in the tray: only ever `inputImages` (never held, never after the 10 s countdown), and only where a
    // message is typed at once. A refusal keeps the photos and the caption exactly as they are.
    fun sendPhotos(caption: String) {
        val text = caption.trim()
        when (val d = PhotoSend.decide(photoDraft, text, data.photos)) {
            is PhotoSend.Decision.Refuse -> { composerProblem = d.why; return }
            PhotoSend.Decision.Send -> Unit
        }
        if (ended || live == null || data.session.id != sessionId) { composerProblem = "This session isn't on your Mac's list any more, so nothing was sent."; return }
        val problem = SessionStore.sendPhotos(sessionId, text, photoDraft.ready, SessionTarget.of(live, macName))
        if (problem != null) { composerProblem = problem; return }
        photoDraft = PhotoDraft()
        thumbs.clear()
        draft = ""
        composerProblem = null
        dismissedReceipt = null
        restoredNote = null
        lastSend = null
    }

    LaunchedEffect(fireYesNo) {
        val word = fireYesNo ?: return@LaunchedEffect
        fireYesNo = null
        send(word)
    }

    val actions = SessionRoomActions(
        close = AppRouter::closeSheet,
        send = ::send,
        selectWhen = SteerChoiceStore::select,
        receiptAction = { r ->
            when (r.action) {
                // Undo: nothing had left the phone; the text is back in the box.
                SendReceipt.Action.UNDO -> SessionStore.undoScheduled(r.id)?.let { draft = OutboxRestore.merge(it, draft) }
                SendReceipt.Action.DELETE -> SessionStore.deleteHeld(r.id)
                null -> Unit
            }
        },
        deleteHeld = SessionStore::deleteHeld,
        armYesNo = { word ->
            // The same checks as Send, before the ring starts: a refusal says why now, not 1.2 s later.
            val d = RoomSend.decide(data.composer, word, data.session, sessionId, live, ended, row?.action(RowAction.Kind.TELL_INSTEAD) != null, macName, data.choice)
            if (d is RoomSend.Decision.Refuse) composerProblem = d.why
            else if (yesNoArm == null) {
                composerProblem = null
                yesNoArm = YesNoArm(word, Instant.now())
            }
        },
        cancelYesNo = { yesNoArm = null },
        stopCompleted = {
            // The hold is the confirmation; Esc goes to the session through the existing path.
            if (!data.stop.canStop) composerProblem = "Stop isn't available for ${data.target?.project ?: "this session"} right now, so nothing was pressed."
            else SessionStore.interrupt(sessionId, data.target)
        },
        dismissReceipt = { if (it == "restored") restoredNote = null else dismissedReceipt = it },
        // The answers go with what the room showed (folder, terminal, Mac): the Mac refuses on a mismatch.
        submitAnswers = { sheet ->
            // A page Claude's question hook holds takes the answers as text, which the hook maps: nothing is pressed.
            when (val s = AnswerPicker.submit(data.askViaHook, row != null, sheet)) {
                is AnswerPicker.Submit.Refuse -> composerProblem = s.why
                is AnswerPicker.Submit.Hook -> if (row != null) ActionCoordinator.begin(row, RowAction.Kind.TELL_INSTEAD, s.text)
                AnswerPicker.Submit.Keys -> SessionStore.sendAnswer(sessionId, sheet, data.target)
            }
        },
        openRun = { id -> runId = id; lens = RoomLens.WORKFLOWS },
        openAgent = { run, agentId -> agent = run to agentId },
        openDecision = { presentedPage = it },
        steer = { AppRouter.requestSheetComposer(it); presentedPage = it },
        banner = { a ->
            when (a) {
                RoomBanner.Action.Retry -> { SessionStore.refresh(); scope.launch { RelayClient.refreshAll() } }
                RoomBanner.Action.Repair -> AppRouter.requestUnpair()
                is RoomBanner.Action.OpenDecision -> presentedPage = a.pageId
            }
        },
        approve = { ActionCoordinator.begin(it, RowAction.Kind.APPROVE) },
        holdComplete = { ActionCoordinator.commitHold(it, macName) },
        deny = { ActionCoordinator.begin(it, RowAction.Kind.DENY) },
        looksGood = { ActionCoordinator.begin(it, RowAction.Kind.CARRY_ON) },
        cancel = { id -> if (ActionCoordinator.isArming(id)) ActionCoordinator.cancel(id) else presentedPage = id },
        refreshChanges = ::requestChanges,
        copy = { clip.setText(AnnotatedString(it)) },
        addPhoto = ::openPicker,
        photoUnavailable = { composerProblem = it },
        removePhoto = { id -> photoDraft = photoDraft.removing(id); thumbs.remove(id); composerProblem = null },
        sendPhotos = ::sendPhotos,
    )

    Box(modifier.fillMaxSize()) {
        NWSessionRoom(
            data, actions, shownLens, { l -> lens = l; if (l == RoomLens.CHANGES && sessionState.diffs[sessionId] == null) requestChanges() },
            draft, { draft = it; if (composerProblem != null) composerProblem = null }, runId, { runId = it },
            focusComposer = entry.focusesComposer, stopHint = stopHint, photos = RoomPhotoTray(photoDraft, thumbs.toMap()),
        )
        // A decision opened from the room is a sheet over it; "Open session" there just comes back here.
        val pageId = presentedPage
        val pageRow = pageId?.let { id -> inbox.firstOrNull { it.id == id }?.let { NowRowBuilder.row(it, session, macName) } }
        NWSheetHost(pageId != null, { presentedPage = null }, containerColor = decisionBackground(pageRow)) {
            if (pageId != null) DecisionContainer(pageId, onViewChanges = { _, _ -> presentedPage = null; lens = RoomLens.CHANGES }, onClose = { presentedPage = null }, onOpenSession = { presentedPage = null })
        }
        // A workflow agent's room: its transcript, sent by the Mac while this screen is open. Read-only.
        val ref = agent
        if (ref != null) AgentRoomContainer(sessionId, ref.first, ref.second, onBack = { agent = null })
    }
}

/** A workflow agent's room, live. */
@Composable
fun AgentRoomContainer(sessionId: String, runId: String, agentId: String, onBack: () -> Unit) {
    val s by SessionStore.state.collectAsStateWithLifecycle()
    val live = s.workflows[sessionId]?.firstOrNull { it.id == runId }
    var snapshot by remember { mutableStateOf(live) }
    LaunchedEffect(live) { live?.let { snapshot = it } }
    DisposableEffect(sessionId, runId, agentId) {
        SessionStore.watchAgent(sessionId, runId, agentId)
        onDispose { SessionStore.watchAgent(sessionId, null, null) }
    }
    val run = live ?: snapshot
    val agent = run?.agents?.firstOrNull { it.id == agentId }
    val transcript = s.agentTranscript(sessionId, runId, agentId)
    val state = agent?.let { WorkflowOrbit.nodeState(it) } ?: WorkflowOrbit.NodeState.STOPPED
    androidx.activity.compose.BackHandler(onBack = onBack)
    NWAgentRoomScreen(
        run?.name ?: "Workflow", agent?.label ?: "Agent", state,
        transcript?.let { AgentRoomModel.build(it.entries, state != WorkflowOrbit.NodeState.RUNNING, it.truncated) }, onBack,
    )
}
