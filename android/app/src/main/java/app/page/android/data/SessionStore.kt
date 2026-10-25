package app.page.android.data

import android.util.Log
import app.page.android.model.CommandResult
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

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

        /** Messages typed into this session from the phone, oldest first. */
        fun sentMessages(sessionId: String): List<SentSessionCommand> =
            commands.values.filter { it.sessionId == sessionId && it.kind == SessionCommandKind.INPUT }.sortedBy { it.sentAt }

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
        val cmd = s.commands[r.clientId] ?: return
        val next = cmd.copy(state = cmd.state.applying(r, agentName(cmd.sessionId)))
        update { it.copy(commands = it.commands + (r.clientId to next)) }
        Log.i(TAG, "${cmd.kind.wire} ${r.clientId.take(8)} -> ${r.code.wire}${r.reason?.let { "/$it" } ?: ""}")
        if (!next.state.isPending) timeoutJobs.remove(r.clientId)?.cancel()
    }

    private fun agentName(sessionId: String): String = _state.value.session(sessionId)?.backend?.displayName ?: "Your agent"

    // endregion

    // region Outgoing

    private val canSend: Boolean get() = !_state.value.isDemoMode && rootKey != null

    /**
     * Types [text] into the session. Returns the problem to show instead when
     * the text can't be sent; otherwise the message's delivery state appears
     * in `commands` under a fresh `clientId`.
     */
    fun sendInput(sessionId: String, text: String): SessionComposer.Problem? {
        val clean = when (val v = SessionComposer.validate(text)) {
            is SessionComposer.Validation.Bad -> return v.problem
            is SessionComposer.Validation.Ok -> v.text
        }
        if (_state.value.isDemoMode) {
            simulateDemoCommand(SessionCommandKind.INPUT, sessionId, clean)
            return null
        }
        val clientId = UUID.randomUUID().toString().lowercase()
        val body = encrypt(SessionCommand.Input(sessionId, clean), clientId)
        if (body == null) {
            record(clientId, sessionId, SessionCommandKind.INPUT, clean, SessionDeliveryState.Failed("This phone has no session key. Re-pair with your Mac."))
            return null
        }
        if (!SessionComposer.fitsRelay(body)) return SessionComposer.Problem.TooLarge
        record(clientId, sessionId, SessionCommandKind.INPUT, clean, SessionDeliveryState.Sending)
        deliver(body, clientId, "input")
        return null
    }

    /** Stop: the Mac presses Esc in the session. */
    fun interrupt(sessionId: String) {
        if (_state.value.isDemoMode) {
            simulateDemoCommand(SessionCommandKind.INTERRUPT, sessionId, "")
            return
        }
        val clientId = UUID.randomUUID().toString().lowercase()
        val body = encrypt(SessionCommand.Interrupt(sessionId), clientId)
        if (body == null) {
            record(clientId, sessionId, SessionCommandKind.INTERRUPT, "", SessionDeliveryState.Failed("This phone has no session key. Re-pair with your Mac."))
            return
        }
        record(clientId, sessionId, SessionCommandKind.INTERRUPT, "", SessionDeliveryState.Sending)
        deliver(body, clientId, "interrupt")
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

    private fun record(clientId: String, sessionId: String, kind: SessionCommandKind, text: String, state: SessionDeliveryState) {
        val sentAt = Instant.now()
        val prior = _state.value.transcripts[sessionId]?.entries?.map { it.id }?.toSet()
        update { it.copy(commands = pruned(it.commands + (clientId to SentSessionCommand(clientId, sessionId, kind, text, sentAt, state, prior)))) }
        if (!state.isPending) return
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
            relayFeatures = setOf(SessionAvailability.FEATURE),
            hasKey = true,
            isDemoMode = true,
        )
    }

    /**
     * Walks a demo command through the states a real one goes through, using
     * the same refusal rules as the Mac's input gate where they're visible
     * from here.
     */
    private fun simulateDemoCommand(kind: SessionCommandKind, sessionId: String, text: String) {
        val clientId = UUID.randomUUID().toString().lowercase()
        record(clientId, sessionId, kind, text, SessionDeliveryState.Sending)
        val target = _state.value.session(sessionId)
        scope.launch {
            delay(700)
            if (!_state.value.isDemoMode || target == null) return@launch
            val result = when (kind) {
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
            if (kind != SessionCommandKind.INPUT || !result.ok) return@launch
            delay(600)
            if (!_state.value.isDemoMode) return@launch
            update { s ->
                val old = s.transcripts[sessionId]
                val entry = TranscriptEntry("demo-$clientId", TranscriptRole.USER, text, Instant.now(), null)
                s.copy(transcripts = s.transcripts + (sessionId to SessionTranscript(sessionId, (old?.entries ?: emptyList()) + entry, old?.truncated ?: false)))
            }
        }
    }

    private fun replaceDemoSession(s: LiveSession, state: LiveSessionState) {
        val next = s.copy(state = state, lastActivityAt = Instant.now(), interventionId = null, preview = "Interrupted")
        update { st -> st.copy(sessions = st.sessions.map { if (it.id == s.id) next else it }) }
    }

    // endregion
}
