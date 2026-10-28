package app.page.android.data

import android.util.Log
import app.page.android.model.CommandResult
import app.page.android.model.HeldDelete
import app.page.android.model.HeldMessages
import app.page.android.model.LatePhotoResults
import app.page.android.model.MacRetract
import app.page.android.model.OutboxFire
import app.page.android.model.PhotoProgress
import app.page.android.model.PhotoReceipt
import app.page.android.model.PhotoTransport
import app.page.android.model.PhotoUploader
import app.page.android.model.PreparedPhoto
import app.page.android.model.ResultWaiter
import app.page.android.model.UploadOutcome
import app.page.android.model.UploadPhoto
import app.page.android.model.PhotoChunks
import app.page.android.model.PhotoText
import app.page.android.model.OutboxRestore
import app.page.android.model.ReplyDelivery
import app.page.android.model.RestoredDraft
import app.page.android.model.ScheduledSend
import app.page.android.model.SendOutbox
import app.page.android.model.SessionCaps
import app.page.android.model.SendCountdown
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.AnswerPicker
import app.page.android.model.AnswerSheet
import app.page.android.model.SessionTarget
import app.page.android.model.MacPresence
import app.page.android.model.SentSessionCommand
import app.page.android.model.SessionAvailability
import app.page.android.model.SessionCommand
import app.page.android.model.SessionCommandKind
import app.page.android.model.SessionCommandOutcome
import app.page.android.model.SessionDiff
import app.page.android.model.SessionResultCopy
import app.page.android.model.StartFolders
import app.page.android.model.StartPrompt
import app.page.android.model.StartedSessionMatch
import app.page.android.model.SessionComposer
import app.page.android.model.SessionCrypto
import app.page.android.model.SessionDeliveryState
import app.page.android.model.SessionFrameType
import app.page.android.model.SessionScreen
import app.page.android.model.SessionTranscript
import app.page.android.model.SessionUpdateGate
import app.page.android.model.SessionsPlaintext
import app.page.android.model.SessionsUpdate
import app.page.android.model.TranscriptEntry
import app.page.android.model.TranscriptRole
import app.page.android.model.WorkflowRun
import java.time.Instant
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import app.page.android.model.parseJson
import app.page.android.model.str

/**
 * Live sessions on the paired Mac (docs/SESSIONS-PROTOCOL.md): the list, the
 * transcript of the session being viewed, and where each message typed on
 * this phone stands (the Android side of iOS SessionStore.swift).
 *
 * Kept apart from [RelayClient] on purpose: session updates arrive every
 * second while the Mac is busy, and the inbox screens shouldn't recompose for
 * them. RelayClient forwards `sessions.update` frames here and carries
 * commands to POST /sessions/command; everything else lives in this store.
 *
 * All content is end-to-end encrypted with the pairing's session key. It is
 * held in memory only, and never logged: logs carry sizes and outcomes.
 */
object SessionStore {
    private const val TAG = "SessionStore"
    private const val OUTBOX_KEY = "page.outbox.v1"
    private const val RESTORED_KEY = "page.outbox.restored.v1"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    data class State(
        val sessions: List<LiveSession> = emptyList(),
        /** A `list` has arrived since the last reset. */
        val hasList: Boolean = false,
        /** The last list said live sessions are turned off on the Mac. */
        val macDisabled: Boolean = false,
        val macName: String? = null,
        val lastListAt: Instant? = null,
        val transcripts: Map<String, SessionTranscript> = emptyMap(),
        /** The watched session's terminal, from Macs that send it. */
        val screens: Map<String, SessionScreen> = emptyMap(),
        /** Each watched session's dynamic workflows, from Macs that send them. */
        val workflows: Map<String, List<WorkflowRun>> = emptyMap(),
        /** Messages and Stops sent from this phone, by `clientId`. */
        val commands: Map<String, SentSessionCommand> = emptyMap(),
        /** From GET /status; null until known. */
        val relayFeatures: Set<String>? = null,
        /** The list header's `caps`: what this Mac accepts beyond the base ops (a Mac that sends none: empty). */
        val caps: Set<String> = emptySet(),
        /** Messages counting down before their POST (10 s, "Undo"). In memory, and on disk only while counting. */
        val outbox: SendOutbox = SendOutbox(),
        /** Messages that did not go and are back in their room's box, with why (read once by the room). */
        val restoredDrafts: Map<String, RestoredDraft> = emptyMap(),
        /** Where a delete of each held message stands, by the message's `clientId`. */
        val deletes: Map<String, HeldDelete> = emptyMap(),
        /** Photos going up (`images-v1`), by the bubble's `clientId`; gone once the Mac has answered or the upload stopped. */
        val uploads: Map<String, PhotoProgress> = emptyMap(),
        val hasKey: Boolean = false,
        val macOfflineHint: Boolean = false,
        val waitStartedAt: Instant? = null,
        val keyMismatch: Boolean = false,
        val onlyStaleFrames: Boolean = false,
        /** Bumped when the first-list wait runs out, so screens re-evaluate. */
        val waitTick: Int = 0,
        val isDemoMode: Boolean = false,
        /** v4: the last `diff` asked for each session, and its answer. */
        val diffs: Map<String, AnswerRequest<SessionDiff>> = emptyMap(),
        /** v4: the last `folders` request and its answer. */
        val folders: AnswerRequest<StartFolders>? = null,
        /** v4: the last `start`, and what the Mac said. */
        val start: StartRequest? = null,
        /** v4: a `start` is waiting for its session to show up in the list (up to 90 s). */
        val awaitingStartedSession: Boolean = false,
        /** v4: the session started from the phone, now in the list: open it. */
        val startedSessionId: String? = null,
    ) {
        fun session(id: String): LiveSession? = sessions.firstOrNull { it.id == id }

        /** The newest `answer` sent for this very question (iOS `latestAnswer`). */
        fun latestAnswer(sessionId: String, promptKey: String): SentSessionCommand? =
            AnswerPicker.delivery(commands.values.toList(), sessionId, promptKey)

        /** The newest message typed into this session from the phone. */
        fun latestInput(sessionId: String): SentSessionCommand? = sentMessages(sessionId).lastOrNull()

        /**
         * Messages typed into this session from the phone, oldest first, plus the ones the Mac holds that another
         * device sent (so every held message shows in the room, with Delete).
         */
        fun sentMessages(sessionId: String): List<SentSessionCommand> =
            HeldMessages.pending(session(sessionId), commands.values.filter { it.sessionId == sessionId && it.kind == SessionCommandKind.INPUT }.sortedBy { it.sentAt })

        /** The Mac can take a held message back (`retract-v1`). */
        val canRetract: Boolean get() = SessionCaps.canRetract(caps)

        /** The most recent Stop for this session, while it's worth showing. */
        fun latestInterrupt(sessionId: String, now: Instant): SentSessionCommand? =
            commands.values.filter { it.sessionId == sessionId && it.kind == SessionCommandKind.INTERRUPT }
                .maxByOrNull { it.sentAt }
                ?.takeIf { it.state.isPending || now.toEpochMilli() - it.sentAt.toEpochMilli() < 60_000 }

        fun availability(presence: MacPresence, socketConnected: Boolean, now: Instant): SessionAvailability {
            if (isDemoMode) return SessionAvailability.Ready
            return SessionAvailability.evaluate(
                SessionAvailability.Inputs(
                    hasKey = hasKey, relayFeatures = relayFeatures, presence = presence,
                    macOfflineHint = macOfflineHint, socketConnected = socketConnected,
                    waitStartedAt = waitStartedAt, hasList = hasList,
                    keyMismatch = keyMismatch, onlyStaleFrames = onlyStaleFrames, macDisabled = macDisabled,
                ),
                now,
            )
        }

        fun agentTranscript(sessionId: String, runId: String, agentId: String): SessionTranscript? =
            transcripts[SessionTranscript.key(sessionId, runId, agentId)]
    }

    /**
     * A command answered by its own kind (`diff`, `folders`): pending until
     * the answer, a refusal or the relay's failure arrives.
     */
    data class AnswerRequest<T>(val clientId: String, val sentAt: Instant, val answer: T? = null, val error: String? = null) {
        val isPending: Boolean get() = answer == null && error == null
    }

    data class StartRequest(val clientId: String, val folder: String, val sentAt: Instant, val state: SessionDeliveryState)

    /** A start waiting for its session: the folder, the sessions that existed before, when. */
    private data class PendingStart(val folder: String, val existing: Set<String>, val at: Instant)

    /** How long a start waits for its session to appear before giving up. */
    const val STARTED_SESSION_WAIT_SECONDS = 90L

    private val _state = MutableStateFlow(State())
    val state: StateFlow<State> = _state.asStateFlow()

    private inline fun update(block: (State) -> State) {
        _state.value = block(_state.value)
    }

    /** The session whose detail screen is open, re-sent as `watch`. */
    var watchedSessionId: String? = null
        private set

    /** The workflow agent open on top of the watched session, if any. */
    private var watchedAgent: Pair<String, String>? = null

    private val gate = SessionUpdateGate()
    private var rootKey: ByteArray? = null
    private var undecryptableInARow = 0
    private val timeoutJobs = HashMap<String, Job>()
    private var waitJob: Job? = null
    private var pendingStart: PendingStart? = null
    private var pendingStartJob: Job? = null

    /** A held message's clientId is "seen" once a list carried it: only then can its absence mean "no longer held". */
    private val seenHeld = HashSet<String>()

    /** The countdown timers, by [ScheduledSend.id]. */
    private val outboxJobs = HashMap<String, Job>()

    /** What each retract op in flight is taking back, by the retract's own clientId. */
    private sealed interface RetractTarget {
        data class Held(val heldId: String) : RetractTarget
        data class Reply(val interventionId: String) : RetractTarget
    }
    private val retractTargets = HashMap<String, RetractTarget>()

    /** The `result` each `inputImages` in flight waits for, by its own clientId. */
    private val photoWaiters = HashMap<String, CompletableDeferred<CommandResult>>()

    /**
     * The `inputImages` commands that may still be answered after the phone stopped waiting for them, by the command's
     * own clientId (5 minutes): a late `result` still settles its photo bubble.
     */
    private val latePhotos = LatePhotoResults()

    /** The Mac's answers awaited for a `retract {interventionId}` the relay's "forwarded" led to, by the retract's clientId. */
    private val chainedRetracts = HashMap<String, CompletableDeferred<MacRetract.Outcome?>>()

    /** The uploads running, by bubble id: they belong to the store, so leaving the room does not stop one. */
    private val photoJobs = HashMap<String, Job>()

    private val viewer: String get() = AppGraph.prefs.viewer

    // region Lifecycle

    /** Re-reads the session key from [SecretStore]. */
    fun reloadKey() {
        if (_state.value.isDemoMode) return
        rootKey = SessionKeyStore.current(AppGraph.secrets)
        update { it.copy(hasKey = rootKey != null) }
    }

    /**
     * Clears everything tied to the current pairing. Called from
     * [RelayClient.reset], so it runs on unpair, re-pair, retirement and demo
     * seeding alike.
     */
    fun reset() {
        timeoutJobs.values.forEach { it.cancel() }
        timeoutJobs.clear()
        outboxJobs.values.forEach { it.cancel() }
        outboxJobs.clear()
        retractTargets.clear()
        photoJobs.values.forEach { it.cancel() }
        photoJobs.clear()
        photoWaiters.clear()
        latePhotos.clear()
        // A delete waiting on the Mac for the old pairing stops waiting: no answer will come.
        chainedRetracts.values.toList().forEach { it.complete(null) }
        chainedRetracts.clear()
        seenHeld.clear()
        // A pairing change drops what was counting down (it was for the old Mac), and what was saved for a restart,
        // including the old pairing's restored drafts: message text never outlives its pairing on disk.
        persistOutbox(SendOutbox())
        if (!_state.value.isDemoMode) AppGraph.prefs.putString(RESTORED_KEY, null)
        waitJob?.cancel()
        waitJob = null
        pendingStart = null
        pendingStartJob?.cancel()
        pendingStartJob = null
        gate.reset()
        undecryptableInARow = 0
        watchedSessionId = null
        watchedAgent = null
        _state.value = State()
        reloadKey()
    }

    /** GET /status answered. A relay without /status (404) has no features. */
    fun relayFeaturesUpdated(features: List<String>) {
        val next = features.toSet()
        if (_state.value.relayFeatures != next) update { it.copy(relayFeatures = next) }
    }

    /**
     * The phone socket (re)opened: the Mac sends a list when the phone count
     * goes above zero; also ask for one, and re-arm the watch the Mac may have
     * expired while we were away.
     */
    fun socketOpened() {
        startWaitingForList()
        if (!canSend) return
        watchedSessionId?.let { post(watchCommand(it)) }
        post(SessionCommand.Refresh)
    }

    /** The Mac just connected to the relay (`mac.status`): a list should follow within seconds. */
    fun macCameOnline() {
        update { it.copy(macOfflineHint = false) }
        if (!_state.value.hasList) startWaitingForList()
    }

    /** Pull to refresh / "Try again". */
    fun refresh() {
        update { it.copy(macOfflineHint = false) }
        if (!_state.value.hasList) startWaitingForList()
        if (!canSend) return
        post(SessionCommand.Refresh)
    }

    private fun startWaitingForList() {
        update { it.copy(waitStartedAt = Instant.now()) }
        waitJob?.cancel()
        waitJob = scope.launch {
            delay(((SessionAvailability.LIST_WAIT + 0.2) * 1000).toLong())
            update { it.copy(waitTick = it.waitTick + 1) }
        }
    }

    // endregion

    // region Watching

    /**
     * The detail screen re-sends this every 30 s while visible and sends null
     * when it goes away. Only goes out over a live socket: the Mac sends
     * nothing while no phone is connected anyway, and the watch is re-armed on
     * reconnect.
     */
    fun watch(sessionId: String?) {
        val changed = watchedSessionId != sessionId
        watchedSessionId = sessionId
        if (changed || sessionId == null) watchedAgent = null
        if (!canSend || RelayClient.connection.value != RelayClient.ConnectionState.CONNECTED) return
        // Leaving a screen that never watched anything needs no message.
        if (sessionId == null && !changed) return
        post(sessionId?.let(::watchCommand) ?: SessionCommand.Watch(null))
    }

    /**
     * The agent screen opened (or closed, nulls) on top of the session's. The
     * session screen's periodic re-watch carries it along.
     */
    fun watchAgent(sessionId: String, runId: String?, agentId: String?) {
        if (runId != null && agentId != null) {
            watchedAgent = runId to agentId
            watchedSessionId = sessionId
        } else {
            // Closing the agent screen: back to the session only if its screen
            // is still open (it may have closed first and watched null).
            if (watchedSessionId != sessionId || watchedAgent == null) return
            watchedAgent = null
        }
        if (!canSend || RelayClient.connection.value != RelayClient.ConnectionState.CONNECTED) return
        post(watchCommand(sessionId))
    }

    private fun watchCommand(sessionId: String): SessionCommand =
        watchedAgent?.let { SessionCommand.WatchAgent(sessionId, it.first, it.second) } ?: SessionCommand.Watch(sessionId)

    // endregion

    // region Incoming

    /** A `sessions.update` frame's payload: `{"e": <envelope>}`. */
    fun handleUpdate(payload: JsonObject) {
        if (_state.value.isDemoMode) return
        val raw = payload["e"] as? JsonObject
        val envelope = raw?.let(SessionCrypto.Envelope::fromJson)
        if (envelope == null) {
            Log.i(TAG, "dropped malformed update")
            return
        }
        if (rootKey == null) reloadKey()
        val root = rootKey ?: return
        val data = SessionCrypto.open(envelope, root, SessionCrypto.Direction.MAC_TO_PHONE, SessionFrameType.UPDATE)
        if (data == null) {
            undecryptableInARow += 1
            // One bad frame could be noise; a run of them means the Mac's key
            // no longer matches ours.
            if (undecryptableInARow >= 2) update { it.copy(keyMismatch = true) }
            Log.i(TAG, "dropped undecryptable update (${envelope.sealed.size} bytes)")
            return
        }
        undecryptableInARow = 0
        if (_state.value.keyMismatch) update { it.copy(keyMismatch = false) }
        val plaintext = SessionsPlaintext.decode(data) ?: return // unknown kind or malformed
        when (gate.admit(plaintext, Instant.now())) {
            SessionUpdateGate.Verdict.TOO_OLD -> {
                if (!_state.value.hasList) update { it.copy(onlyStaleFrames = true) }
                Log.i(TAG, "dropped update older than ${SessionUpdateGate.MAX_AGE.toInt()}s")
                return
            }
            SessionUpdateGate.Verdict.OUT_OF_ORDER -> return
            SessionUpdateGate.Verdict.ACCEPT -> if (_state.value.onlyStaleFrames) update { it.copy(onlyStaleFrames = false) }
        }
        if (plaintext.update is SessionsUpdate.ListUpdate) update { it.copy(macDisabled = plaintext.macDisabled) }
        apply(plaintext.update)
    }

    private fun apply(u: SessionsUpdate) {
        when (u) {
            is SessionsUpdate.ListUpdate -> {
                waitJob?.cancel()
                update { s ->
                    // Transcripts only for sessions that still exist (plus the
                    // one on screen, which shows "ended" over its last one).
                    val live = u.sessions.map { it.id }.toSet()
                    val watched = watchedSessionId
                    s.copy(
                        sessions = u.sessions,
                        caps = u.caps,
                        macName = u.macName ?: s.macName,
                        hasList = true,
                        lastListAt = Instant.now(),
                        macOfflineHint = false,
                        transcripts = s.transcripts.filterValues { it.sessionId in live || it.sessionId == watched },
                        screens = s.screens.filterKeys { it in live || it == watched },
                        workflows = s.workflows.filterKeys { it in live || it == watched },
                    )
                }
                matchStartedSession(u.sessions)
                reconcileHeld(u.sessions)
            }
            is SessionsUpdate.Workflows -> update { s ->
                val next = LinkedHashMap(s.workflows)
                next[u.sessionId] = u.runs
                if (next.size > 4) next.keys.firstOrNull { it != u.sessionId && it != watchedSessionId }?.let(next::remove)
                s.copy(workflows = next)
            }
            is SessionsUpdate.Screen -> update { s ->
                val next = LinkedHashMap(s.screens)
                next[u.screen.sessionId] = u.screen
                if (next.size > 4) next.keys.firstOrNull { it != u.screen.sessionId && it != watchedSessionId }?.let(next::remove)
                s.copy(screens = next)
            }
            is SessionsUpdate.Transcript -> update { s ->
                val t = u.transcript
                val next = LinkedHashMap(s.transcripts)
                next[t.key] = t
                // Keep what's on screen (the session's and the open agent's).
                val keep = mutableSetOf(t.key)
                watchedSessionId?.let { sid ->
                    keep.add(sid)
                    watchedAgent?.let { keep.add(SessionTranscript.key(sid, it.first, it.second)) }
                }
                while (next.size > 12) {
                    val victim = next.keys.firstOrNull { it !in keep } ?: break
                    next.remove(victim)
                }
                s.copy(transcripts = next)
            }
            is SessionsUpdate.Result -> applyResult(u.result)
            is SessionsUpdate.Diff -> update { s ->
                val asked = s.diffs[u.diff.sessionId]
                // Only the answer to what this phone asked (or a fresh one for that session).
                if (asked == null || (u.diff.clientId != null && u.diff.clientId != asked.clientId)) return@update s
                s.copy(diffs = s.diffs + (u.diff.sessionId to asked.copy(answer = u.diff, error = null)))
            }
            is SessionsUpdate.Folders -> update { s ->
                val asked = s.folders ?: return@update s
                if (u.folders.clientId != null && u.folders.clientId != asked.clientId) return@update s
                s.copy(folders = asked.copy(answer = u.folders, error = null))
            }
        }
    }

    private fun applyResult(r: CommandResult) {
        val s = _state.value
        s.start?.takeIf { it.clientId == r.clientId }?.let { start ->
            update { it.copy(start = start.copy(state = start.state.applying(r, "Claude"))) }
            timeoutJobs.remove(r.clientId)?.cancel()
            return
        }
        s.diffs.entries.firstOrNull { it.value.clientId == r.clientId && it.value.isPending }?.let { (sid, req) ->
            val why = SessionResultCopy.refusal(r.reason, r.detail, agentName(sid))
            update { it.copy(diffs = it.diffs + (sid to req.copy(error = why))) }
            return
        }
        if (s.folders?.clientId == r.clientId && s.folders.isPending) {
            update { it.copy(folders = s.folders.copy(error = SessionResultCopy.refusal(r.reason, r.detail, "Claude"))) }
            return
        }
        // The answer to an `inputImages`: the upload waiting for it settles the bubble (it may need to resend first).
        photoWaiters.remove(r.clientId)?.let {
            latePhotos.forget(r.clientId)
            it.complete(r)
            return
        }
        // The same answer, after the phone stopped waiting for it (30 s, or a POST whose answer was lost): it still settles the bubble.
        latePhotos.take(r.clientId, Instant.now())?.let { late ->
            settleLatePhotos(late, r)
            return
        }
        // The answer to the follow-up `retract` of a reply the relay said the Mac already has: the delete waits on it.
        chainedRetracts.remove(r.clientId)?.let {
            it.complete(MacRetract.outcome(r, "Claude"))
            return
        }
        // The answer to a retract op: the message it named is settled by it, never by the retract's own `code`.
        retractTargets.remove(r.clientId)?.let { target ->
            timeoutJobs.remove(r.clientId)?.cancel()
            applyRetractResult(target, r)
            return
        }
        val cmd = s.commands[r.clientId] ?: return
        val next = cmd.copy(state = cmd.state.applying(r, agentName(cmd.sessionId)))
        update { it.copy(commands = it.commands + (r.clientId to next)) }
        Log.i(TAG, "${cmd.kind.wire} ${r.clientId.take(8)} -> ${r.code.wire}${r.reason?.let { "/$it" } ?: ""}")
        if (!next.state.isPending) timeoutJobs.remove(r.clientId)?.cancel()
    }

    private fun agentName(sessionId: String): String = _state.value.session(sessionId)?.backend?.displayName ?: "Your agent"

    /**
     * A list arrived: settle the held messages this phone knows about from the row's `held` (a `result` reaches only
     * the phones connected when it happens, so the list is the other source of truth). A message gone from the
     * list with no settled state reads "No longer held", but only if this phone saw it listed first.
     */
    private fun reconcileHeld(sessions: List<LiveSession>) {
        val byId = sessions.associateBy { it.id }
        for (session in sessions) for (h in session.held) seenHeld.add(h.clientId)
        // Bounded: start again from what this list names, so a message still listed keeps counting as seen.
        if (seenHeld.size > 400 && !_state.value.macDisabled) {
            seenHeld.clear()
            for (session in sessions) for (h in session.held) seenHeld.add(h.clientId)
        }
        val s = _state.value
        var changed = false
        val next = LinkedHashMap(s.commands)
        for ((id, cmd) in s.commands) {
            if (cmd.kind != SessionCommandKind.INPUT) continue
            // A held message whose session left the list is gone with its row: "No longer held — check the session"
            // (the Mac's final `result` reached only the phones connected then). Not on a list from a Mac with live
            // sessions turned off: that list is empty on purpose, and the Mac still holds what it held.
            val session = byId[cmd.sessionId]
            if (session == null && s.macDisabled) continue
            val settled = HeldMessages.settle(
                cmd.state, session?.held?.firstOrNull { it.clientId == id }, id in seenHeld, sessionListed = session != null,
                sentAt = cmd.sentAt, now = Instant.now(), macDisabled = s.macDisabled,
            )
            if (settled != cmd.state) {
                next[id] = cmd.copy(state = settled)
                changed = true
                if (!settled.isPending) timeoutJobs.remove(id)?.cancel()
            }
        }
        if (changed) update { it.copy(commands = next) }
    }

    /** What the Mac said about a retract: settle the message it named. */
    private fun applyRetractResult(target: RetractTarget, r: CommandResult) {
        val outcome = MacRetract.outcome(r, "Claude")
        when (target) {
            is RetractTarget.Held -> {
                val retractId = r.clientId
                update { s ->
                    val delete = HeldDelete.Done(retractId, outcome)
                    val cmd = s.commands[target.heldId]
                    // Deleted: the message is not typed, even if its own final `result` never reaches this phone.
                    val commands = if (cmd != null && outcome is MacRetract.Outcome.Deleted && cmd.state is SessionDeliveryState.Held)
                        s.commands + (target.heldId to cmd.copy(state = SessionDeliveryState.Deleted(outcome.text))) else s.commands
                    s.copy(commands = commands, deletes = s.deletes + (target.heldId to delete))
                }
            }
            is RetractTarget.Reply -> RelayClient.macRetractAnswered(target.interventionId, outcome)
        }
    }

    // endregion

    // region Outgoing

    private val canSend: Boolean get() = !_state.value.isDemoMode && rootKey != null

    /**
     * Types [text] into the session. Returns the problem to show instead when
     * the text can't be sent; otherwise the message's delivery state appears
     * in `commands` under a fresh `clientId`. [target] is what the room showed
     * when it opened; the Mac refuses if the session no longer matches. [hold]: the Mac holds it until the turn
     * ends (`hold-v1`); only for a Mac whose caps say so.
     */
    fun sendInput(sessionId: String, text: String, target: SessionTarget? = null, hold: Boolean = false): SessionComposer.Problem? {
        val clean = when (val v = SessionComposer.validate(text)) {
            is SessionComposer.Validation.Bad -> return v.problem
            is SessionComposer.Validation.Ok -> v.text
        }
        if (_state.value.isDemoMode) {
            simulateDemoCommand(SessionCommandKind.INPUT, sessionId, clean, target, hold = hold)
            return null
        }
        // The backstop: a Mac that doesn't advertise `hold-v1` types a held message at once, which is what the
        // person chose not to do.
        if (hold && SessionCaps.HOLD !in _state.value.caps) return SessionComposer.Problem.HoldUnavailable
        return sendValidated(sessionId, clean, target, hold)
    }

    private fun sendValidated(sessionId: String, clean: String, target: SessionTarget?, hold: Boolean): SessionComposer.Problem? {
        val clientId = UUID.randomUUID().toString().lowercase()
        val body = encrypt(SessionCommand.Input(sessionId, clean, target, hold), clientId)
        if (body == null) {
            record(clientId, sessionId, SessionCommandKind.INPUT, clean, SessionDeliveryState.Failed("This phone has no session key. Re-pair with your Mac."), target)
            return null
        }
        if (!SessionComposer.fitsRelay(body)) return SessionComposer.Problem.TooLarge
        record(clientId, sessionId, SessionCommandKind.INPUT, clean, SessionDeliveryState.Sending, target)
        deliver(body, clientId, "input")
        return null
    }

    // region The 10 s countdown (Send now, to a busy session)

    /**
     * Send now to a busy session: nothing leaves the phone for 10 s ("Sending in 10 s · Undo"). The countdown lives
     * here, not in a screen, so leaving the room does not cancel it; Undo ([undoScheduled]) is the only way out.
     * If the app is killed first nothing is sent, and the text is back in the box next launch ([restorePersistedOutbox]).
     */
    fun scheduleInput(sessionId: String, text: String, target: SessionTarget? = null, pageId: String? = null): SessionComposer.Problem? {
        val clean = when (val v = SessionComposer.validate(text)) {
            is SessionComposer.Validation.Bad -> return v.problem
            is SessionComposer.Validation.Ok -> v.text
        }
        // Too large to send is said now, not 10 s later.
        encrypt(SessionCommand.Input(sessionId, clean, target), UUID.randomUUID().toString().lowercase())?.let {
            if (!SessionComposer.fitsRelay(it)) return SessionComposer.Problem.TooLarge
        }
        val entry = ScheduledSend(UUID.randomUUID().toString().lowercase(), sessionId, clean, target, Instant.now(), pageId)
        update { it.copy(outbox = it.outbox.schedule(entry)) }
        persistOutbox(_state.value.outbox)
        outboxJobs[entry.id] = scope.launch {
            delay((SendCountdown.SECONDS * 1000).toLong())
            fire(entry.id)
        }
        return null
    }

    /** Undo: the text comes back (null when it was already sent). Nothing had left the phone. */
    fun undoScheduled(id: String): String? {
        val (next, entry) = _state.value.outbox.undo(id)
        if (entry == null) return null
        outboxJobs.remove(id)?.cancel()
        update { it.copy(outbox = next) }
        persistOutbox(next)
        return entry.text
    }

    private fun fire(id: String) {
        outboxJobs.remove(id)
        val (next, entry) = _state.value.outbox.undo(id)
        if (entry == null) return // undone meanwhile
        update { it.copy(outbox = next) }
        persistOutbox(next)
        // The timer runs on uptime, which stops while the phone sleeps: a countdown that woke well past its end did not
        // go when the person expected, so it doesn't go now (iOS `staleGrace`). The text is back in the box.
        if (SendCountdown.isStale(entry, Instant.now())) {
            restoreDraft(OutboxRestore.slept(entry))
            return
        }
        val s = _state.value
        // A page's Steer goes as that page's written reply, if the page is still open.
        if (entry.pageId != null) {
            fireReply(entry)
            return
        }
        when (OutboxFire.decide(sessionStillListed = s.isDemoMode || s.session(entry.sessionId) != null)) {
            OutboxFire.Action.SEND ->
                if (s.isDemoMode) simulateDemoCommand(SessionCommandKind.INPUT, entry.sessionId, entry.text, entry.target)
                else sendValidated(entry.sessionId, entry.text, entry.target, hold = false)
            OutboxFire.Action.RESTORE -> restoreDraft(OutboxRestore.gone(entry))
        }
    }

    /** The countdown of a review or look page's Steer ended: the page's own reply path, without a second arm ring. */
    private fun fireReply(entry: ScheduledSend) {
        val pageId = entry.pageId ?: return
        val page = RelayClient.inbox.value.firstOrNull { it.id == pageId }
        if (page == null) {
            restoreDraft(OutboxRestore.gone(entry))
            return
        }
        val row = app.page.android.model.NowRowBuilder.row(page, _state.value.session(page.sessionId), PairingStore.pairedMac.value?.name ?: "")
        // The box was emptied when the countdown began: words the page can't take now, or the relay refuses, go back in it.
        val began = ActionCoordinator.begin(row, app.page.android.model.RowAction.Kind.TELL_INSTEAD, entry.text, arm = false) { outcome ->
            OutboxRestore.afterReply(entry, outcome)?.let(::restoreDraft)
        }
        if (!began) restoreDraft(OutboxRestore.pageBusy(entry))
    }

    /** Only what a restart needs, while it counts: never in demo mode, never longer than the countdown. */
    private fun persistOutbox(outbox: SendOutbox) {
        if (_state.value.isDemoMode) return
        AppGraph.prefs.putString(OUTBOX_KEY, if (outbox.isEmpty) null else OutboxRestore.encode(outbox.entries))
    }

    private fun restoreDraft(d: RestoredDraft) {
        update { s ->
            val old = s.restoredDrafts[d.sessionId]
            s.copy(restoredDrafts = s.restoredDrafts + (d.sessionId to (if (old == null) d else d.copy(text = OutboxRestore.merge(old.text, d.text)))))
        }
        persistRestored()
    }

    private fun persistRestored() {
        if (_state.value.isDemoMode) return
        val drafts = _state.value.restoredDrafts.values.toList()
        AppGraph.prefs.putString(
            RESTORED_KEY,
            if (drafts.isEmpty()) null else kotlinx.serialization.json.JsonArray(drafts.map {
                JsonObject(mapOf("sessionId" to kotlinx.serialization.json.JsonPrimitive(it.sessionId), "text" to kotlinx.serialization.json.JsonPrimitive(it.text), "note" to kotlinx.serialization.json.JsonPrimitive(it.note)))
            }).toString(),
        )
    }

    /**
     * Call once at launch (after the prefs exist): whatever was still counting when the app last died was never sent;
     * it comes back as a draft in its room, with a note. Nothing is ever sent after a restart.
     */
    fun restorePersistedOutbox() {
        val prefs = AppGraph.prefs
        val persisted = OutboxRestore.decode(prefs.string(OUTBOX_KEY))
        if (persisted.isNotEmpty()) {
            prefs.putString(OUTBOX_KEY, null)
            for (d in OutboxRestore.afterKill(persisted)) restoreDraft(d)
        }
        val saved = prefs.string(RESTORED_KEY)?.let { parseJson(it) } as? kotlinx.serialization.json.JsonArray ?: return
        val loaded = saved.mapNotNull { el ->
            val o = el as? JsonObject ?: return@mapNotNull null
            val sid = o.str("sessionId")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val text = o.str("text")?.takeIf { it.isNotBlank() } ?: return@mapNotNull null
            RestoredDraft(sid, text, o.str("note") ?: OutboxRestore.NOTE_KILLED)
        }
        if (loaded.isNotEmpty()) update { s -> s.copy(restoredDrafts = loaded.associateBy { it.sessionId } + s.restoredDrafts) }
    }

    /** The room reads its restored draft once: it is in the box now, and the note says why. */
    fun takeRestoredDraft(sessionId: String): RestoredDraft? {
        val d = _state.value.restoredDrafts[sessionId] ?: return null
        update { it.copy(restoredDrafts = it.restoredDrafts - sessionId) }
        persistRestored()
        return d
    }

    // endregion

    // region Delete (retract-v1)

    /**
     * Delete a message the Mac holds until the turn ends: `retract {heldId}`. The Mac's answer (deleted, too late,
     * not holding it) lands in [State.deletes]; with no answer in 20 s it reads "Couldn't confirm the delete".
     * Only for a Mac whose caps say `retract-v1`: an older Mac would ignore the op, and nothing is offered for it.
     */
    fun deleteHeld(heldId: String) {
        val s = _state.value
        if (s.deletes[heldId]?.isDeleting == true) return
        if (s.isDemoMode) {
            simulateDemoRetract(heldId)
            return
        }
        if (!SessionCaps.canRetract(s.caps)) return
        sendRetract(SessionCommand.Retract(heldId = heldId), RetractTarget.Held(heldId))
    }

    /** `retract {interventionId}`: a `/reply` the Mac holds for a rate limit. The answer goes to [RelayClient.macRetractAnswered]. */
    fun retractReply(interventionId: String) {
        val s = _state.value
        if (s.isDemoMode) {
            scope.launch {
                delay(700)
                RelayClient.macRetractAnswered(interventionId, MacRetract.Outcome.Deleted("Deleted — not sent. Nothing will be typed at reset"))
            }
            return
        }
        if (!SessionCaps.canRetract(s.caps)) {
            // Before the first list the Mac's caps are not known: nothing says it is old.
            RelayClient.macRetractAnswered(interventionId, MacRetract.Outcome.Failed(if (s.hasList) "Update Page on your Mac to delete a held reply." else MacRetract.UNCONFIRMED))
            return
        }
        sendRetract(SessionCommand.Retract(interventionId = interventionId), RetractTarget.Reply(interventionId))
    }

    /**
     * After the relay's `DELETE /reply/:id` said `409 too_late` "forwarded": asks the Mac whether it still holds the reply
     * (`retract {interventionId}`, `retract-v1`) and waits for its answer, at most [MacRetract.TIMEOUT]. null: no answer
     * (a Mac that doesn't advertise `retract-v1`, a POST that failed, 20 s of silence, a new pairing), which the caller
     * reads as "too late".
     */
    suspend fun askMacToRetractReply(interventionId: String): MacRetract.Outcome? {
        val s = _state.value
        if (s.isDemoMode || !SessionCaps.canRetract(s.caps)) return null
        val retractId = UUID.randomUUID().toString().lowercase()
        val body = encrypt(SessionCommand.Retract(interventionId = interventionId), retractId) ?: return null
        val answer = CompletableDeferred<MacRetract.Outcome?>()
        chainedRetracts[retractId] = answer
        scope.launch {
            val outcome = RelayClient.postSessionCommand(body)
            noteOutcome(outcome)
            Log.i(TAG, "retract ${retractId.take(8)} (after forwarded) post -> ${outcome.logName}")
            if (MacRetract.relayFailure(outcome) != null) answer.complete(null)
        }
        return try {
            withTimeoutOrNull((MacRetract.TIMEOUT * 1000).toLong()) { answer.await() }
        } finally {
            chainedRetracts.remove(retractId)
        }
    }

    private fun sendRetract(command: SessionCommand.Retract, target: RetractTarget) {
        val retractId = UUID.randomUUID().toString().lowercase()
        fun fail(f: MacRetract.Outcome.Failed) {
            when (target) {
                is RetractTarget.Held -> update { it.copy(deletes = it.deletes + (target.heldId to HeldDelete.Done(retractId, f))) }
                is RetractTarget.Reply -> RelayClient.macRetractAnswered(target.interventionId, f)
            }
        }
        val body = encrypt(command, retractId)
        if (body == null) {
            fail(MacRetract.Outcome.Failed("This phone has no session key. Re-pair with your Mac."))
            return
        }
        retractTargets[retractId] = target
        if (target is RetractTarget.Held) update { it.copy(deletes = it.deletes + (target.heldId to HeldDelete.Deleting(retractId, Instant.now()))) }
        scope.launch {
            val outcome = RelayClient.postSessionCommand(body)
            noteOutcome(outcome)
            Log.i(TAG, "retract ${retractId.take(8)} post -> ${outcome.logName}")
            val failure = MacRetract.relayFailure(outcome) ?: return@launch
            if (retractTargets.remove(retractId) == null) return@launch
            timeoutJobs.remove(retractId)?.cancel()
            fail(failure)
        }
        timeoutJobs[retractId] = scope.launch {
            delay((MacRetract.TIMEOUT * 1000).toLong())
            if (retractTargets.remove(retractId) == null) return@launch
            timeoutJobs.remove(retractId)
            when (target) {
                is RetractTarget.Held -> update { s -> s.copy(deletes = s.deletes + (target.heldId to HeldDelete.Unconfirmed(retractId))) }
                is RetractTarget.Reply -> RelayClient.macRetractAnswered(target.interventionId, MacRetract.Outcome.Failed(MacRetract.UNCONFIRMED))
            }
        }
    }

    // endregion


    // region Photos (images-v1)

    /**
     * Sends [photos] with [caption] into the session: the pieces go up (3 at a time), then one `inputImages`; the
     * bubble shows "Sending photos" with the upload's progress until the Mac answers. The upload lives here, so leaving
     * the room does not cancel it. Returns why nothing was sent, or null. Only for a Mac whose caps say `images-v1`.
     */
    fun sendPhotos(sessionId: String, caption: String, photos: List<PreparedPhoto>, target: SessionTarget? = null): String? {
        val s = _state.value
        if (photos.isEmpty() || photos.size > app.page.android.model.PhotoLimits.MAX_PHOTOS) return "Add one to four photos."
        val text = caption.trim()
        if (s.isDemoMode) {
            simulateDemoPhotos(sessionId, text, photos.size, target)
            return null
        }
        if (SessionCaps.IMAGES !in s.caps) return "Your Mac can't take photos from Page. Update Page on your Mac."
        if (rootKey == null) reloadKey()
        if (rootKey == null) return "This phone has no session key. Re-pair with your Mac."
        // New ids for every send: the Mac remembers the ones it has used for 15 minutes.
        val upload = photos.map { UploadPhoto(PhotoChunks.newImageId(), it) }
        // The route the row named when it was sent (`image` or `path`): the receipt says which, as iOS does.
        val attach = s.sessions.firstOrNull { it.id == sessionId }?.attach
        val bubbleId = UUID.randomUUID().toString().lowercase()
        record(bubbleId, sessionId, SessionCommandKind.INPUT, text, SessionDeliveryState.Sending, target, photos = photos.size)
        photoJobs[bubbleId] = scope.launch {
            val uploader = PhotoUploader(photoTransport(bubbleId, photos.size, attach), { UUID.randomUUID().toString().lowercase() })
            val outcome = uploader.run(sessionId, upload, text, target) { p -> update { it.copy(uploads = it.uploads + (bubbleId to p)) } }
            photoJobs.remove(bubbleId)
            update { it.copy(uploads = it.uploads - bubbleId) }
            if (_state.value.commands[bubbleId] == null) return@launch // reset meanwhile
            when (outcome) {
                is UploadOutcome.Answered -> {
                    val r = outcome.result
                    applyResult(r.copy(clientId = bubbleId, detail = PhotoReceipt.detail(r, photos.size, attach)))
                }
                is UploadOutcome.Stopped -> settlePhotos(bubbleId, SessionDeliveryState.Failed(outcome.message))
                UploadOutcome.NoAnswer -> settlePhotos(bubbleId, SessionDeliveryState.CheckSession(PhotoUploader.NO_ANSWER))
            }
            Log.i(TAG, "photos ${bubbleId.take(8)} x${photos.size} -> ${outcome::class.simpleName}")
        }
        return null
    }

    private fun settlePhotos(bubbleId: String, state: SessionDeliveryState) {
        val cmd = _state.value.commands[bubbleId] ?: return
        if (cmd.state != SessionDeliveryState.Sending) return
        update { it.copy(commands = it.commands + (bubbleId to cmd.copy(state = state))) }
    }

    /**
     * A late `result` for an `inputImages` (after the 30 s timeout or a failed POST) settles the photo bubble that sent it.
     * Only a bubble the phone had marked as unanswered or failed (or still waiting) changes; see
     * [SessionDeliveryState.afterLatePhotoResult].
     */
    private fun settleLatePhotos(late: LatePhotoResults.Entry, r: CommandResult) {
        val cmd = _state.value.commands[late.bubbleId] ?: return
        val result = r.copy(clientId = late.bubbleId, detail = PhotoReceipt.detail(r, late.photos, late.attach))
        val next = cmd.state.afterLatePhotoResult(result, agentName(cmd.sessionId))
        if (next == cmd.state) return
        update { it.copy(commands = it.commands + (late.bubbleId to cmd.copy(state = next))) }
        Log.i(TAG, "photos ${late.bubbleId.take(8)} late result -> ${r.code.wire}${r.reason?.let { "/$it" } ?: ""}")
    }

    /**
     * Sealed POSTs for the uploader, and the one-shot listeners for `inputImages` results. One per send: each
     * `inputImages` it announces is remembered for the bubble, so its result still settles the bubble if it arrives after
     * the phone stopped waiting.
     */
    private fun photoTransport(bubbleId: String, photos: Int, attach: String?) = object : PhotoTransport {
        override suspend fun post(command: SessionCommand, clientId: String): SessionCommandOutcome {
            val body = encrypt(command, clientId) ?: return SessionCommandOutcome.Failed("This phone has no session key. Re-pair with your Mac.")
            if (!SessionComposer.fitsRelay(body)) return SessionCommandOutcome.TooLarge
            val outcome = RelayClient.postSessionCommand(body)
            noteOutcome(outcome)
            // Pieces are many: only the one that carries the answer is worth a log line.
            if (command is SessionCommand.InputImages) Log.i(TAG, "inputImages ${clientId.take(8)} post -> ${outcome.logName} (${body.length} bytes)")
            return outcome
        }

        override fun expect(clientId: String): ResultWaiter {
            val d = CompletableDeferred<CommandResult>()
            photoWaiters[clientId] = d
            // Before the POST: a result can beat the HTTP answer, and a POST whose answer was lost may still have reached the Mac.
            latePhotos.remember(clientId, LatePhotoResults.Entry(bubbleId, photos, attach, Instant.now()))
            return object : ResultWaiter {
                override suspend fun await(timeoutMillis: Long): CommandResult? = try {
                    withTimeoutOrNull(timeoutMillis) { d.await() }
                } finally {
                    photoWaiters.remove(clientId)
                }

                override fun cancel() { photoWaiters.remove(clientId) }
            }
        }
    }

    // endregion

    /** Stop: the Mac presses Esc in the session. [target] is what the room showed; the Mac refuses if the session no longer matches. */
    fun interrupt(sessionId: String, target: SessionTarget? = null) {
        if (_state.value.isDemoMode) {
            simulateDemoCommand(SessionCommandKind.INTERRUPT, sessionId, "", target)
            return
        }
        val clientId = UUID.randomUUID().toString().lowercase()
        val body = encrypt(SessionCommand.Interrupt(sessionId, target), clientId)
        if (body == null) {
            record(clientId, sessionId, SessionCommandKind.INTERRUPT, "", SessionDeliveryState.Failed("This phone has no session key. Re-pair with your Mac."), target)
            return
        }
        record(clientId, sessionId, SessionCommandKind.INTERRUPT, "", SessionDeliveryState.Sending, target)
        deliver(body, clientId, "interrupt")
    }

    /**
     * Sends the answers to the question the session is blocked on, the Mac's `answer` op: it checks the screen
     * before every key and refuses if the question changed. Nothing is typed until the person submits.
     */
    fun sendAnswer(sessionId: String, sheet: AnswerSheet, target: SessionTarget? = null) {
        val answers = sheet.wire() ?: return
        val summary = sheet.summaryLine
        val promptKey = sheet.ask.id
        if (_state.value.isDemoMode) {
            simulateDemoCommand(SessionCommandKind.ANSWER, sessionId, summary, target, promptKey)
            return
        }
        val clientId = UUID.randomUUID().toString().lowercase()
        val body = encrypt(SessionCommand.Answer(sessionId, promptKey, answers, target), clientId)
        if (body == null) {
            record(clientId, sessionId, SessionCommandKind.ANSWER, summary, SessionDeliveryState.Failed("This phone has no session key. Re-pair with your Mac."), target, promptKey)
            return
        }
        record(clientId, sessionId, SessionCommandKind.ANSWER, summary, SessionDeliveryState.Sending, target, promptKey)
        deliver(body, clientId, "answer")
    }

    /** Stop-all: Esc in every working session (the pulse's hold). The Mac's own answer comes later; this is the relay's. */
    suspend fun interruptAll(): SessionCommandOutcome {
        if (_state.value.isDemoMode) {
            delay(600)
            return SessionCommandOutcome.Accepted
        }
        val clientId = UUID.randomUUID().toString().lowercase()
        val body = encrypt(SessionCommand.InterruptAll, clientId) ?: return SessionCommandOutcome.Failed("This phone has no session key. Re-pair with your Mac.")
        val outcome = RelayClient.postSessionCommand(body)
        noteOutcome(outcome)
        return outcome
    }

    private fun encrypt(command: SessionCommand, clientId: String): String? {
        if (rootKey == null) reloadKey()
        val root = rootKey ?: return null
        return try {
            SessionCommand.requestBody(command.plaintext(clientId, viewer, Instant.now()), root)
        } catch (_: Exception) {
            null
        }
    }

    private fun record(
        clientId: String, sessionId: String, kind: SessionCommandKind, text: String, state: SessionDeliveryState,
        target: SessionTarget? = null, promptKey: String? = null, photos: Int = 0,
    ) {
        val sentAt = Instant.now()
        val prior = _state.value.transcripts[sessionId]?.entries?.map { it.id }?.toSet()
        update { it.copy(commands = pruned(it.commands + (clientId to SentSessionCommand(clientId, sessionId, kind, text, sentAt, state, prior, target, promptKey, photos = photos)))) }
        // A photo message waits on its own 30 s, which starts when `inputImages` goes out.
        if (!state.isPending || photos > 0) return
        timeoutJobs[clientId] = scope.launch {
            delay((SessionDeliveryState.RESULT_TIMEOUT * 1000).toLong())
            val cmd = _state.value.commands[clientId] ?: return@launch
            val next = cmd.state.timedOut(sentAt, Instant.now())
            if (next != cmd.state) {
                update { it.copy(commands = it.commands + (clientId to cmd.copy(state = next))) }
                Log.i(TAG, "${kind.wire} ${clientId.take(8)} -> no answer")
            }
            timeoutJobs.remove(clientId)
        }
    }

    /** Bounded: settled commands older than an hour go first. */
    private fun pruned(commands: Map<String, SentSessionCommand>): Map<String, SentSessionCommand> {
        if (commands.size <= 200) return commands
        val cutoff = Instant.now().minusSeconds(3600)
        var kept = commands.filterValues { it.state.isPending || it.sentAt > cutoff }
        if (kept.size > 200) {
            val keep = kept.values.sortedByDescending { it.sentAt }.take(200).map { it.clientId }.toSet()
            kept = kept.filterKeys { it in keep }
        }
        return kept
    }

    private fun deliver(body: String, clientId: String, op: String) {
        scope.launch {
            val outcome = RelayClient.postSessionCommand(body)
            noteOutcome(outcome)
            val cmd = _state.value.commands[clientId] ?: return@launch // reset meanwhile
            val next = cmd.state.afterPost(outcome)
            Log.i(TAG, "$op ${clientId.take(8)} post -> ${outcome.logName} (${body.length} bytes)")
            if (next != cmd.state) {
                update { it.copy(commands = it.commands + (clientId to cmd.copy(state = next))) }
                timeoutJobs.remove(clientId)?.cancel()
            }
        }
    }

    /** watch / refresh: fire and forget, no `result` comes back. */
    private fun post(command: SessionCommand) {
        val body = encrypt(command, UUID.randomUUID().toString().lowercase()) ?: return
        scope.launch { noteOutcome(RelayClient.postSessionCommand(body)) }
    }

    /** What a relay answer says about availability. */
    private fun noteOutcome(outcome: SessionCommandOutcome) {
        when (outcome) {
            SessionCommandOutcome.MacOffline -> update { it.copy(macOfflineHint = true) }
            SessionCommandOutcome.RelayTooOld -> relayFeaturesUpdated(emptyList())
            else -> Unit
        }
    }

    // region v4: changes, folders, start

    /** Asks the Mac what this session changed; the answer lands in `diffs`. */
    fun requestDiff(sessionId: String) {
        val clientId = UUID.randomUUID().toString().lowercase()
        update { it.copy(diffs = it.diffs + (sessionId to AnswerRequest(clientId, Instant.now()))) }
        if (_state.value.isDemoMode) {
            scope.launch {
                delay(500)
                val answer = demoDiff(sessionId)
                update { s -> s.copy(diffs = s.diffs + (sessionId to AnswerRequest(clientId, Instant.now(), answer = answer?.copy(clientId = clientId), error = if (answer == null) "No changes to show for this session." else null))) }
            }
            return
        }
        askForAnswer(SessionCommand.Diff(sessionId), clientId, "diff") { error ->
            update { s -> s.diffs[sessionId]?.takeIf { it.clientId == clientId && it.isPending }?.let { s.copy(diffs = s.diffs + (sessionId to it.copy(error = error))) } ?: s }
        }
    }

    /** Asks where a new session may be started; the answer lands in `folders`. */
    fun requestFolders() {
        val clientId = UUID.randomUUID().toString().lowercase()
        update { it.copy(folders = AnswerRequest(clientId, Instant.now())) }
        if (_state.value.isDemoMode) {
            scope.launch {
                delay(400)
                update { s -> s.copy(folders = AnswerRequest(clientId, Instant.now(), answer = demoFolders?.copy(clientId = clientId))) }
            }
            return
        }
        askForAnswer(SessionCommand.Folders, clientId, "folders") { error ->
            update { s -> s.folders?.takeIf { it.clientId == clientId && it.isPending }?.let { s.copy(folders = it.copy(error = error)) } ?: s }
        }
    }

    /**
     * Starts a new Claude session in [folder] (one the `folders` answer
     * listed; the Mac checks again). Returns the problem to show instead when
     * the prompt can't be sent.
     */
    fun startSession(folder: String, text: String): String? {
        StartPrompt.problem(text)?.let { return it }
        val clientId = UUID.randomUUID().toString().lowercase()
        val prompt = text.trim()
        update { it.copy(start = StartRequest(clientId, folder, Instant.now(), SessionDeliveryState.Sending)) }
        if (!_state.value.isDemoMode) awaitStartedSession(folder)
        if (_state.value.isDemoMode) {
            scope.launch {
                delay(800)
                applyResult(CommandResult(clientId, true, CommandResult.Code.DELIVERED, null, "Started Claude in a new cmux workspace (demo)", null))
            }
            return null
        }
        val body = encrypt(SessionCommand.Start(folder, prompt), clientId)
        if (body == null) {
            update { it.copy(start = it.start?.copy(state = SessionDeliveryState.Failed("This phone has no session key. Re-pair with your Mac."))) }
            return null
        }
        scope.launch {
            val outcome = RelayClient.postSessionCommand(body)
            noteOutcome(outcome)
            Log.i(TAG, "start ${clientId.take(8)} post -> ${outcome.logName}")
            update { s -> s.start?.takeIf { it.clientId == clientId }?.let { s.copy(start = it.copy(state = it.state.afterPost(outcome))) } ?: s }
        }
        timeoutJobs[clientId] = scope.launch {
            delay((SessionDeliveryState.RESULT_TIMEOUT * 1000).toLong())
            update { s -> s.start?.takeIf { it.clientId == clientId }?.let { s.copy(start = it.copy(state = it.state.timedOut(it.sentAt, Instant.now()))) } ?: s }
            timeoutJobs.remove(clientId)
        }
        return null
    }

    /** Forgets the last start, including any wait for its session (the sheet opening afresh). */
    fun clearStart() {
        stopAwaitingStartedSession()
        update { it.copy(start = null, startedSessionId = null) }
    }

    /** The started session has been opened. */
    fun clearStartedSession() = update { it.copy(startedSessionId = null) }

    /** Watches the next lists for the session a start creates in [folder], for up to 90 s. */
    private fun awaitStartedSession(folder: String) {
        pendingStartJob?.cancel()
        pendingStart = PendingStart(folder, _state.value.sessions.map { it.id }.toSet(), Instant.now())
        update { it.copy(awaitingStartedSession = true, startedSessionId = null) }
        pendingStartJob = scope.launch {
            delay(STARTED_SESSION_WAIT_SECONDS * 1000)
            pendingStart = null
            pendingStartJob = null
            update { it.copy(awaitingStartedSession = false) }
        }
    }

    private fun stopAwaitingStartedSession() {
        pendingStart = null
        pendingStartJob?.cancel()
        pendingStartJob = null
        if (_state.value.awaitingStartedSession) update { it.copy(awaitingStartedSession = false) }
    }

    private fun matchStartedSession(sessions: List<LiveSession>) {
        val p = pendingStart ?: return
        val outcome = _state.value.start?.state
        // A refused or failed start made no session: don't open someone else's.
        if (outcome is SessionDeliveryState.Refused || outcome is SessionDeliveryState.Failed ||
            Instant.now().toEpochMilli() - p.at.toEpochMilli() > STARTED_SESSION_WAIT_SECONDS * 1000
        ) {
            stopAwaitingStartedSession()
            return
        }
        val found = StartedSessionMatch.find(sessions, p.folder, p.existing) ?: return
        stopAwaitingStartedSession()
        update { it.copy(startedSessionId = found.id) }
    }

    /** Sends an op whose answer is its own kind; [fail] gets the reason it can't come. */
    private fun askForAnswer(command: SessionCommand, clientId: String, op: String, fail: (String) -> Unit) {
        val body = encrypt(command, clientId)
        if (body == null) {
            fail("This phone has no session key. Re-pair with your Mac.")
            return
        }
        scope.launch {
            val outcome = RelayClient.postSessionCommand(body)
            noteOutcome(outcome)
            Log.i(TAG, "$op ${clientId.take(8)} post -> ${outcome.logName}")
            outcome.failureMessage?.let(fail)
        }
        scope.launch {
            delay((SessionDeliveryState.RESULT_TIMEOUT * 1000).toLong())
            fail("Your Mac didn't answer within ${SessionDeliveryState.RESULT_TIMEOUT.toInt()} seconds. Pull to refresh, or try again.")
        }
    }

    // endregion

    // region Demo

    private var demoDiffs: Map<String, SessionDiff> = emptyMap()
    private var demoFolders: StartFolders? = null

    private fun demoDiff(sessionId: String): SessionDiff? = demoDiffs[sessionId]

    /** Seeds sent messages and answers (the room's receipts, the question card's delivery) for fixtures. */
    fun seedDemoCommands(commands: List<SentSessionCommand>) {
        update { it.copy(commands = it.commands + commands.associateBy { c -> c.clientId }) }
    }

    /** The demo's list and runs changing in place, as a live Mac's would (the In flight live script). */
    fun seedDemoLive(sessions: List<LiveSession>, workflows: Map<String, List<WorkflowRun>>) {
        update { it.copy(sessions = sessions, workflows = workflows, lastListAt = Instant.now()) }
    }

    fun seedDemoExtras(diffs: Map<String, SessionDiff>, folders: StartFolders) {
        demoDiffs = diffs
        demoFolders = folders
    }

    fun seedDemo(
        macName: String,
        sessions: List<LiveSession>,
        transcripts: List<SessionTranscript>,
        screens: List<SessionScreen>,
        workflows: Map<String, List<WorkflowRun>>,
    ) {
        reset()
        _state.value = State(
            sessions = sessions,
            hasList = true,
            macName = macName,
            lastListAt = Instant.now(),
            transcripts = transcripts.associateBy { it.key },
            screens = screens.associateBy { it.sessionId },
            workflows = workflows,
            // The demo's Mac holds and deletes messages, and its relay takes queued replies back.
            relayFeatures = setOf(SessionAvailability.FEATURE, SessionCaps.RELAY_RETRACT),
            caps = setOf(SessionCaps.HOLD, SessionCaps.RETRACT, SessionCaps.IMAGES),
            hasKey = true,
            isDemoMode = true,
        )
    }

    /**
     * Walks a demo command through the states a real one goes through, using
     * the same refusal rules as the Mac's input gate where they're visible
     * from here.
     */
    private fun simulateDemoCommand(kind: SessionCommandKind, sessionId: String, text: String, shown: SessionTarget? = null, promptKey: String? = null, hold: Boolean = false) {
        val clientId = UUID.randomUUID().toString().lowercase()
        record(clientId, sessionId, kind, text, SessionDeliveryState.Sending, shown, promptKey)
        val target = _state.value.session(sessionId)
        scope.launch {
            delay(700)
            if (!_state.value.isDemoMode || target == null) return@launch
            val result = when (kind) {
                SessionCommandKind.START -> CommandResult(clientId, true, CommandResult.Code.DELIVERED, null, "Started Claude (simulated)", null)
                SessionCommandKind.ANSWER -> CommandResult(clientId, true, CommandResult.Code.DELIVERED, null, "Answered in ${target.host} (simulated)", null)
                SessionCommandKind.RETRACT -> CommandResult(clientId, true, CommandResult.Code.DELIVERED, null, HeldMessages.DELETED_COPY, null, retract = CommandResult.Retract.DELETED)
                SessionCommandKind.INTERRUPT -> {
                    if (target.isStoppable) {
                        replaceDemoSession(target, LiveSessionState.INTERRUPTED)
                        CommandResult(clientId, true, CommandResult.Code.DELIVERED, null, "Pressed Esc in ${target.host} (demo)", null)
                    } else {
                        CommandResult(clientId, false, CommandResult.Code.REFUSED, "interrupt_unsupported", null, null)
                    }
                }
                SessionCommandKind.INPUT -> {
                    val busy = target.state == LiveSessionState.ACTIVE
                    when {
                        busy && hold -> CommandResult(clientId, true, CommandResult.Code.QUEUED, null, "Held — Page types it when ${target.backend.displayName} finishes this turn", null, held = true)
                        target.state.isWaiting -> CommandResult(clientId, false, CommandResult.Code.REFUSED, "waiting", null, target.interventionId)
                        busy && text.firstOrNull()?.isDigit() == true -> CommandResult(clientId, false, CommandResult.Code.REFUSED, "digit_while_busy", null, null)
                        else -> CommandResult(
                            clientId, true, if (busy) CommandResult.Code.QUEUED else CommandResult.Code.DELIVERED, null,
                            if (busy) null else "Typed into ${target.host} (demo)", null,
                        )
                    }
                }
            }
            apply(SessionsUpdate.Result(result))
            if (kind != SessionCommandKind.INPUT || !result.ok || result.held) return@launch
            delay(600)
            if (!_state.value.isDemoMode) return@launch
            update { s ->
                val old = s.transcripts[sessionId]
                val entry = TranscriptEntry("demo-$clientId", TranscriptRole.USER, text, Instant.now(), null)
                s.copy(transcripts = s.transcripts + (sessionId to SessionTranscript(sessionId, (old?.entries ?: emptyList()) + entry, old?.truncated ?: false)))
            }
        }
    }

    /** A demo photo send: the upload's progress, then the Mac's answer, then the transcript's echo with the photo count. */
    private fun simulateDemoPhotos(sessionId: String, caption: String, count: Int, target: SessionTarget?) {
        val bubbleId = UUID.randomUUID().toString().lowercase()
        record(bubbleId, sessionId, SessionCommandKind.INPUT, caption, SessionDeliveryState.Sending, target, photos = count)
        val session = _state.value.session(sessionId)
        scope.launch {
            val total = 12 * count
            for (n in 1..total step 3) {
                delay(150)
                update { it.copy(uploads = it.uploads + (bubbleId to PhotoProgress(n, total, PhotoProgress.Phase.UPLOADING))) }
            }
            update { it.copy(uploads = it.uploads + (bubbleId to PhotoProgress(total, total, PhotoProgress.Phase.WAITING))) }
            delay(600)
            if (!_state.value.isDemoMode) return@launch
            update { it.copy(uploads = it.uploads - bubbleId) }
            val where = session?.host ?: "your Mac"
            applyResult(CommandResult(bubbleId, true, CommandResult.Code.DELIVERED, null, "Sent ${PhotoText.chip(count)} to Claude in $where (demo)", null, attached = count))
            delay(600)
            if (!_state.value.isDemoMode) return@launch
            update { s ->
                val old = s.transcripts[sessionId]
                val chips = (1..count).joinToString(" ") { "[Image #$it]" }
                val entry = TranscriptEntry("demo-$bubbleId", TranscriptRole.USER, chips + caption, Instant.now(), null, images = count)
                s.copy(transcripts = s.transcripts + (sessionId to SessionTranscript(sessionId, (old?.entries ?: emptyList()) + entry, old?.truncated ?: false)))
            }
        }
    }

    /** A demo delete: the Mac says "deleted" a moment later, and the held message settles. */
    private fun simulateDemoRetract(heldId: String) {
        val retractId = UUID.randomUUID().toString().lowercase()
        update { it.copy(deletes = it.deletes + (heldId to HeldDelete.Deleting(retractId, Instant.now()))) }
        scope.launch {
            delay(700)
            if (!_state.value.isDemoMode) return@launch
            update { s ->
                val cmd = s.commands[heldId]
                s.copy(
                    commands = if (cmd != null && cmd.state is SessionDeliveryState.Held) s.commands + (heldId to cmd.copy(state = SessionDeliveryState.Deleted(HeldMessages.DELETED_COPY))) else s.commands,
                    deletes = s.deletes + (heldId to HeldDelete.Done(retractId, MacRetract.Outcome.Deleted(HeldMessages.DELETED_COPY))),
                )
            }
        }
    }

    private fun replaceDemoSession(s: LiveSession, state: LiveSessionState) {
        val next = s.copy(state = state, lastActivityAt = Instant.now(), interventionId = null, preview = "Interrupted")
        update { st -> st.copy(sessions = st.sessions.map { if (it.id == s.id) next else it }) }
    }

    // endregion
}
