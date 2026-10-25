package app.page.android.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.util.Log
import app.page.android.model.CloseReason
import app.page.android.model.Intervention
import app.page.android.model.MacStatusSnapshot
import app.page.android.model.PageDate
import app.page.android.model.ReconnectBackoff
import app.page.android.model.ReplyAction
import app.page.android.model.ReplyDelivery
import app.page.android.model.ReplyOutcome
import app.page.android.model.SessionCommandOutcome
import app.page.android.model.TokenRetirement
import app.page.android.model.ValidatedPairing
import app.page.android.model.asBool
import app.page.android.model.bool
import app.page.android.model.num
import app.page.android.model.obj
import app.page.android.model.parseJsonObject
import app.page.android.model.str
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.time.Instant
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener

/**
 * Client for the Cloudflare Worker relay (the Android side of iOS
 * APIClient.swift):
 * - REST: GET /interventions, /history, /status; POST /reply/:id,
 *   /sessions/command
 * - WebSocket /ws: live `intervention.opened` / `intervention.closed`,
 *   `heartbeat`, `mac.status`, `reply.result` and `relay.retired` frames,
 *   plus encrypted `sessions.update` frames, which go to [SessionStore]
 *
 * The phone only ever *receives* on the socket: it never sends a frame type
 * the Worker could take for the Mac's. It identifies as `page-android/…`.
 *
 * Credentials are read from [SecretStore] on every call, so this works the
 * same from a notification action in a cold process as from the UI. All
 * state is touched on the main thread only (like iOS's @MainActor); OkHttp
 * callbacks hop there first.
 */
object RelayClient {
    private const val TAG = "RelayClient"

    enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED }

    sealed interface LoadState {
        data object Idle : LoadState
        data object Loading : LoadState
        data object Loaded : LoadState
        data class Failed(val message: String) : LoadState

        val failureMessage: String? get() = (this as? Failed)?.message
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _inbox = MutableStateFlow<List<Intervention>>(emptyList())
    val inbox: StateFlow<List<Intervention>> = _inbox.asStateFlow()
    private val _history = MutableStateFlow<List<Intervention>>(emptyList())
    val history: StateFlow<List<Intervention>> = _history.asStateFlow()
    private val _connection = MutableStateFlow(ConnectionState.DISCONNECTED)
    val connection: StateFlow<ConnectionState> = _connection.asStateFlow()
    private val _inboxLoad = MutableStateFlow<LoadState>(LoadState.Idle)
    val inboxLoad: StateFlow<LoadState> = _inboxLoad.asStateFlow()
    private val _historyLoad = MutableStateFlow<LoadState>(LoadState.Idle)
    val historyLoad: StateFlow<LoadState> = _historyLoad.asStateFlow()
    private val _macStatus = MutableStateFlow<MacStatusSnapshot?>(null)
    val macStatus: StateFlow<MacStatusSnapshot?> = _macStatus.asStateFlow()

    /** The relay answered 401/403: the pairing token is no longer accepted. */
    private val _authRejected = MutableStateFlow(false)
    val authRejected: StateFlow<Boolean> = _authRejected.asStateFlow()

    /**
     * The relay says the Mac replaced this pairing (410 `token_retired` or a
     * `relay.retired` frame): the relay's explanation. While set, nothing
     * talks to the relay; [PairingStore] unpairs and shows the re-pair screen.
     */
    private val _retiredWhy = MutableStateFlow<String?>(null)
    val retiredWhy: StateFlow<String?> = _retiredWhy.asStateFlow()
    private val _deliveries = MutableStateFlow<Map<String, ReplyDelivery>>(emptyMap())
    val deliveries: StateFlow<Map<String, ReplyDelivery>> = _deliveries.asStateFlow()

    /** Close reasons for pages that closed while the app was watching, so an open reply screen can say why. */
    private val _recentCloseReasons = MutableStateFlow<Map<String, String>>(emptyMap())
    val recentCloseReasons: StateFlow<Map<String, String>> = _recentCloseReasons.asStateFlow()

    /** Notifications for new and closed pages (set by the Application). */
    var notifier: PageNotifier = object : PageNotifier {}

    /** "Try the demo": sample data only, never touches the network. Debug builds only. */
    var isDemoMode = false
        private set

    /**
     * True from a successful inbox fetch until the socket is closed: while it
     * holds, socket events keep [inbox] current.
     */
    private var inboxIsFresh = false

    // REST requests fail fast instead of waiting for connectivity: a
    // notification action only has seconds, and the UI should show "can't
    // reach your relay" rather than spin.
    private val restClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(20, TimeUnit.SECONDS)
            .callTimeout(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .addInterceptor { chain ->
                chain.proceed(chain.request().newBuilder().header("User-Agent", userAgent).build())
            }
            .build()
    }

    /**
     * The socket client. OkHttp sends a WebSocket ping every 25 s (the
     * protocol's keepalive) and fails the socket when a pong doesn't come
     * back before the next ping, which catches half-open sockets (Wi-Fi to
     * cellular, NAT timeouts) the same way iOS's liveness deadline does.
     */
    private val wsClient: OkHttpClient by lazy {
        restClient.newBuilder()
            .pingInterval(PING_INTERVAL_SECONDS, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            .callTimeout(0, TimeUnit.SECONDS)
            .build()
    }

    private const val PING_INTERVAL_SECONDS = 25L

    private val userAgent: String get() = "page-android/${AppGraph.appVersion}"

    // WebSocket state. Every callback checks `ws === socket` so events from a
    // socket we already replaced (re-pair, reconnect) are ignored.
    private var socket: WebSocket? = null
    private var socketCredentials: RelayCredentials? = null
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectJob: Job? = null

    // Inbox race protection: socket events that arrive while a GET is in
    // flight are replayed on top of the GET result, so nothing is lost or
    // resurrected.
    private sealed interface InboxEvent {
        data class Opened(val iv: Intervention) : InboxEvent
        data class Closed(val id: String) : InboxEvent
    }

    private val inboxEvents = ArrayDeque<Pair<Int, InboxEvent>>()
    private var inboxSeq = 0

    /**
     * `inboxSeq` at the last local change to each reply's delivery state (our
     * POST, a `reply.result` frame). A fetch that started earlier carries
     * older delivery news for that id and must not overwrite it.
     */
    private val deliveryTouchedSeq = HashMap<String, Int>()
    private var inboxFetchCounter = 0
    private var lastAppliedInboxFetch = 0

    /** Null until we know; false once an old Worker answered 404 to /status. */
    private var statusEndpointAvailable: Boolean? = null

    /**
     * The relay is known to predate delivery reporting (it answered 404 to
     * /status), so an unconfirmed reply never turns into "failed" and a second
     * answer isn't blocked by an ack window.
     */
    val relayIsLegacy: Boolean get() = statusEndpointAvailable == false

    private fun credentials(): RelayCredentials? {
        if (isDemoMode) return null
        // A retired token gets 410 for everything: stop calling and
        // reconnecting until the pairing is replaced.
        if (_retiredWhy.value != null) return null
        return RelayCredentials.current(AppGraph.secrets)
    }

    // region Demo

    /** Inject sample pages. Bypasses the network entirely. */
    fun seedDemoInbox(list: List<Intervention>) {
        reset()
        isDemoMode = true
        _inboxLoad.value = LoadState.Loaded
        inboxIsFresh = true
        _inbox.value = Intervention.urgencySorted(list)
        _historyLoad.value = LoadState.Loaded
        _macStatus.value = MacStatusSnapshot(macConnected = true, lastHeartbeatAt = Instant.now(), activeSessions = list.size, battery = 82, onAC = true)
        _connection.value = ConnectionState.CONNECTED
    }

    fun seedDemoStatus(snapshot: MacStatusSnapshot) {
        if (isDemoMode) _macStatus.value = snapshot
    }

    fun seedDemoHistory(list: List<Intervention>) {
        if (isDemoMode) _history.value = list
    }

    /** Walks a demo reply through the same states a real one goes through. */
    private suspend fun simulateDemoReply(id: String): ReplyOutcome {
        updateDeliveries { it[id] = ReplyDelivery.Sending }
        delay(400)
        updateDeliveries { it[id] = ReplyDelivery.Sent(false, Instant.now()) }
        scope.launch {
            delay(900)
            if (!isDemoMode) return@launch
            updateDeliveries { it[id] = ReplyDelivery.Delivered("Typed into tmux pane %3 (demo)") }
            applyClose(id, "replied")
        }
        return ReplyOutcome.Accepted(false)
    }

    // endregion

    // region Lifecycle

    /**
     * Clears everything tied to the current pairing. Called on unpair and
     * before adopting a new pairing, so data from one relay can never leak
     * into another.
     */
    fun reset() {
        disconnect()
        isDemoMode = false
        inboxIsFresh = false
        _inbox.value = emptyList()
        _history.value = emptyList()
        _inboxLoad.value = LoadState.Idle
        _historyLoad.value = LoadState.Idle
        _macStatus.value = null
        _authRejected.value = false
        _retiredWhy.value = null
        _deliveries.value = emptyMap()
        deliveryTouchedSeq.clear()
        _recentCloseReasons.value = emptyMap()
        inboxEvents.clear()
        statusEndpointAvailable = null
        reconnectAttempt = 0
        // The live-sessions key belongs to the pairing being reset. Adopting
        // a new pairing calls this before it writes its own key, so a pairing
        // without `sk` can't inherit the previous Mac's.
        SessionKeyStore.clear(AppGraph.secrets)
        SessionStore.reset()
    }

    /** Foreground + paired: open the socket and pull fresh state. */
    fun activate() {
        connect()
        scope.launch {
            refreshInbox()
            refreshStatus()
        }
    }

    /** Pull to refresh: everything the current screen might show. */
    suspend fun refreshAll() {
        connect()
        refreshInbox()
        refreshStatus()
        if (_historyLoad.value != LoadState.Idle) refreshHistory()
    }

    // endregion

    // region REST

    private fun request(url: HttpUrl, token: String, method: String = "GET", json: JsonObject? = null, rawBody: String? = null): Request {
        val b = Request.Builder().url(url).header("Authorization", "Bearer $token").header("Cache-Control", "no-store")
        val body = rawBody ?: json?.toString()
        if (method == "POST") b.post((body ?: "{}").toRequestBody(JSON))
        return b.build()
    }

    private val JSON = "application/json".toMediaType()

    private data class HttpResult(val status: Int, val body: String)

    private suspend fun perform(req: Request, client: OkHttpClient = restClient): HttpResult =
        suspendCancellableCoroutine { cont ->
            val call = client.newCall(req)
            cont.invokeOnCancellation { call.cancel() }
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, e: IOException) {
                    if (cont.isActive) cont.resumeWithException(e)
                }

                override fun onResponse(call: Call, response: Response) {
                    val result = response.use { HttpResult(it.code, it.body?.string() ?: "") }
                    if (cont.isActive) cont.resume(result)
                }
            })
        }

    suspend fun refreshInbox() {
        val creds = credentials() ?: return
        val url = creds.url("interventions") ?: return
        inboxFetchCounter += 1
        val fetchId = inboxFetchCounter
        val startSeq = inboxSeq
        if (_inboxLoad.value != LoadState.Loaded) _inboxLoad.value = LoadState.Loading
        try {
            val r = perform(request(url, creds.token))
            if (creds != credentials()) return // unpaired / re-paired meanwhile
            if (r.status !in 200..299) {
                handleHttpFailure(r.status, r.body, _inboxLoad)
                return
            }
            val decoded = Intervention.decodeList(r.body)
            if (decoded == null) {
                _inboxLoad.value = LoadState.Failed("The relay sent data this version of Page doesn't understand.")
                return
            }
            if (decoded.droppedCount > 0) Log.i(TAG, "skipped ${decoded.droppedCount} undecodable intervention(s)")
            // An older request finishing after a newer one must not win.
            if (fetchId <= lastAppliedInboxFetch) return
            lastAppliedInboxFetch = fetchId
            _inboxLoad.value = LoadState.Loaded
            inboxIsFresh = true
            applyFetchedInbox(decoded.elements, startSeq)
            _authRejected.value = false
            notifier.removeNotIn(_inbox.value.map { it.id }.toSet())
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            if (creds != credentials()) return
            _inboxLoad.value = LoadState.Failed(describe(e))
        }
    }

    /** The current inbox as the relay sees it, for the background check. Null on any failure. */
    suspend fun fetchPending(): List<Intervention>? {
        refreshInbox()
        return if (_inboxLoad.value == LoadState.Loaded && credentials() != null) _inbox.value else null
    }

    private fun applyFetchedInbox(fetched: List<Intervention>, startSeq: Int) {
        val byId = LinkedHashMap<String, Intervention>()
        for (iv in fetched) byId[iv.id] = iv
        for ((seq, event) in inboxEvents) {
            if (seq <= startSeq) continue
            when (event) {
                is InboxEvent.Opened -> byId[event.iv.id] = event.iv
                is InboxEvent.Closed -> byId.remove(event.id)
            }
        }
        _inbox.value = Intervention.urgencySorted(byId.values.toList())
        syncDeliveries(_inbox.value, startSeq)
    }

    /**
     * Fold the Worker's view of each reply (v2 `deliveryStatus`, or v1
     * `repliedAt`) into local state — covers replies sent from a notification
     * or before a relaunch. Ids whose delivery changed locally after the fetch
     * started keep their newer local state.
     */
    private fun syncDeliveries(list: List<Intervention>, startSeq: Int) {
        val now = Instant.now()
        updateDeliveries { map ->
            for (iv in list) {
                val touched = deliveryTouchedSeq[iv.id]
                if (touched != null && touched > startSeq) continue
                val local = map[iv.id]
                val next = ReplyDelivery.synced(local, iv.deliveryStatus, iv.deliveryDetail, iv.repliedAt, now)
                if (next != local) {
                    if (next == null) map.remove(iv.id) else map[iv.id] = next
                }
            }
        }
    }

    private inline fun updateDeliveries(block: (MutableMap<String, ReplyDelivery>) -> Unit) {
        val m = _deliveries.value.toMutableMap()
        block(m)
        _deliveries.value = m
    }

    /** Records a local delivery change so an in-flight fetch can't undo it. */
    private fun setDelivery(id: String, state: ReplyDelivery) {
        inboxSeq += 1
        deliveryTouchedSeq[id] = inboxSeq
        if (deliveryTouchedSeq.size > 200) {
            val floor = inboxSeq - 200
            deliveryTouchedSeq.entries.removeAll { it.value <= floor }
        }
        updateDeliveries { it[id] = state }
    }

    suspend fun refreshHistory() {
        val creds = credentials() ?: return
        val url = creds.url("history", query = mapOf("limit" to "500")) ?: return
        if (_historyLoad.value != LoadState.Loaded) _historyLoad.value = LoadState.Loading
        try {
            val r = perform(request(url, creds.token))
            if (creds != credentials()) return
            if (r.status !in 200..299) {
                handleHttpFailure(r.status, r.body, _historyLoad)
                return
            }
            val decoded = Intervention.decodeList(r.body)
            if (decoded == null) {
                _historyLoad.value = LoadState.Failed("The relay sent data this version of Page doesn't understand.")
                return
            }
            _history.value = decoded.elements.sortedByDescending { it.closedAt ?: it.openedAt }
            _historyLoad.value = LoadState.Loaded
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            if (creds != credentials()) return
            _historyLoad.value = LoadState.Failed(describe(e))
        }
    }

    /**
     * GET /status (v2 Workers). Old Workers answer 404, in which case Mac
     * presence comes from heartbeat frames alone.
     */
    suspend fun refreshStatus() {
        if (statusEndpointAvailable == false) return
        val creds = credentials() ?: return
        val url = creds.url("status") ?: return
        try {
            val r = perform(request(url, creds.token))
            if (creds != credentials()) return
            when (r.status) {
                in 200..299 -> {
                    statusEndpointAvailable = true
                    val json = parseJsonObject(r.body) ?: return
                    // `features` tells "relay too old" apart from "no sessions".
                    val features = (json["features"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content } ?: emptyList()
                    SessionStore.relayFeaturesUpdated(features)
                    val wasConnected = _macStatus.value?.macConnected == true
                    var snap = MacStatusSnapshot.from(json)
                    // Keep a newer heartbeat we got over the socket.
                    val mine = _macStatus.value?.lastHeartbeatAt
                    if (mine != null && mine > (snap.lastHeartbeatAt ?: Instant.MIN)) snap = snap.copy(lastHeartbeatAt = mine)
                    _macStatus.value = snap
                    if (snap.macConnected == true && !wasConnected) SessionStore.macCameOnline()
                }
                404 -> {
                    statusEndpointAvailable = false
                    // Predates /status, so it predates live sessions too.
                    SessionStore.relayFeaturesUpdated(emptyList())
                }
                401, 403 -> _authRejected.value = true
                else -> TokenRetirement.why(r.status, r.body)?.let(::markRetired)
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            // Transport errors surface through the inbox load / socket state.
        }
    }

    /**
     * Only called for responses to the current credentials (callers check
     * `creds == credentials()` first), so a late 410 for an old token can
     * never retire a pairing adopted meanwhile.
     */
    private fun handleHttpFailure(status: Int, body: String, state: MutableStateFlow<LoadState>) {
        TokenRetirement.why(status, body)?.let {
            markRetired(it)
            return
        }
        when (status) {
            401, 403 -> {
                _authRejected.value = true
                state.value = LoadState.Failed("The relay no longer accepts this pairing.")
            }
            404 -> state.value = LoadState.Failed("The relay doesn't recognise this request (HTTP 404). Is the relay URL on your Mac right?")
            else -> state.value = LoadState.Failed("The relay returned an error (HTTP $status).")
        }
    }

    /**
     * Sends a reply. Never removes the card optimistically: it stays until the
     * Mac closes the page, and [deliveries] shows the progress.
     */
    suspend fun reply(interventionId: String, text: String, action: ReplyAction): ReplyOutcome {
        ReplyOutcome.validate(text, action)?.let { return ReplyOutcome.Failed(it) }
        if (isDemoMode) return simulateDemoReply(interventionId)
        val creds = credentials()
        val url = creds?.url("reply", interventionId)
        if (creds == null || url == null) {
            setDelivery(interventionId, ReplyDelivery.Failed("Page isn't paired with a Mac."))
            return ReplyOutcome.Failed("Page isn't paired with a Mac.")
        }
        setDelivery(interventionId, ReplyDelivery.Sending)
        val body = JsonObject(mapOf("text" to JsonPrimitive(text), "action" to JsonPrimitive(action.wire)))
        val outcome = try {
            val r = perform(request(url, creds.token, "POST", body))
            ReplyOutcome.from(r.status, r.body)
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            ReplyOutcome.Failed("Couldn't reach your relay: ${describe(e)}")
        }
        if (creds != credentials()) return outcome
        when (outcome) {
            is ReplyOutcome.Accepted -> {
                // A fast Mac can report the result (success or failure) before
                // our POST returns; that newer news wins.
                val current = _deliveries.value[interventionId]
                val next = ReplyDelivery.afterAccepted(current, outcome.queued, Instant.now())
                if (next != current) setDelivery(interventionId, next)
            }
            // An earlier reply (ours, or a notification action) is still
            // waiting for the Mac to confirm it. The relay refuses another
            // answer until it does or its ack window runs out, so show
            // "waiting" from now rather than a terminal "already answered".
            ReplyOutcome.InFlight -> setDelivery(interventionId, ReplyDelivery.Sent(false, Instant.now()))
            ReplyOutcome.AlreadyReplied -> setDelivery(interventionId, ReplyDelivery.AlreadyReplied)
            ReplyOutcome.Gone -> {
                setDelivery(interventionId, ReplyDelivery.Gone)
                applyClose(interventionId, _recentCloseReasons.value[interventionId])
            }
            ReplyOutcome.Unauthorized -> {
                _authRejected.value = true
                setDelivery(interventionId, ReplyDelivery.Failed("The relay no longer accepts this pairing. Re-pair with your Mac."))
            }
            is ReplyOutcome.Retired -> markRetired(outcome.why)
            is ReplyOutcome.Failed -> setDelivery(interventionId, ReplyDelivery.Failed(outcome.message))
        }
        return outcome
    }

    /**
     * POST /sessions/command with an already-encrypted `{"e": …}` body. The
     * relay only forwards it; what the Mac did arrives later as a `result`
     * inside `sessions.update`.
     */
    suspend fun postSessionCommand(body: String): SessionCommandOutcome {
        val creds = credentials()
        val url = creds?.url("sessions", "command")
        if (creds == null || url == null) return SessionCommandOutcome.Failed("Page isn't paired with a Mac.")
        val outcome = try {
            val r = perform(request(url, creds.token, "POST", rawBody = body))
            SessionCommandOutcome.from(r.status, r.body)
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            SessionCommandOutcome.Failed("Couldn't reach your relay: ${describe(e)}")
        }
        if (creds != credentials()) return outcome // unpaired / re-paired meanwhile
        when (outcome) {
            SessionCommandOutcome.Unauthorized -> _authRejected.value = true
            is SessionCommandOutcome.Retired -> markRetired(outcome.why)
            else -> Unit
        }
        return outcome
    }

    sealed interface ProbeResult {
        data class Ok(val snapshot: MacStatusSnapshot?) : ProbeResult
        data class Unreachable(val why: String) : ProbeResult
        data object NotPageRelay : ProbeResult
        data object Unauthorized : ProbeResult

        /** The Mac replaced this code (410 `token_retired`), e.g. an old screenshot. */
        data class Retired(val why: String) : ProbeResult
    }

    /**
     * Checks a candidate pairing before it is saved: the host must be a Page
     * relay (/health) and accept the token (/status, or /interventions on
     * Workers that predate /status).
     */
    suspend fun probe(pairing: ValidatedPairing): ProbeResult {
        val creds = RelayCredentials(pairing.relayBaseUrl, pairing.token)
        val health = creds.url("health")
        val status = creds.url("status")
        val list = creds.url("interventions")
        if (health == null || status == null || list == null) return ProbeResult.NotPageRelay
        return try {
            val h = perform(Request.Builder().url(health).build())
            if (h.status != 200 || parseJsonObject(h.body)?.str("service") != "page-relay") return ProbeResult.NotPageRelay
            val s = perform(request(status, creds.token))
            // A candidate pairing: report it, never retire the current one.
            TokenRetirement.why(s.status, s.body)?.let { return ProbeResult.Retired(it) }
            when (s.status) {
                in 200..299 -> ProbeResult.Ok(parseJsonObject(s.body)?.let(MacStatusSnapshot::from))
                401, 403 -> ProbeResult.Unauthorized
                404 -> {
                    val l = perform(request(list, creds.token))
                    when {
                        l.status in 200..299 -> ProbeResult.Ok(null)
                        TokenRetirement.why(l.status, l.body) != null -> ProbeResult.Retired(TokenRetirement.why(l.status, l.body)!!)
                        l.status == 401 || l.status == 403 -> ProbeResult.Unauthorized
                        else -> ProbeResult.NotPageRelay
                    }
                }
                else -> ProbeResult.NotPageRelay
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            ProbeResult.Unreachable(describe(e))
        }
    }

    // endregion

    // region Closes from outside the socket

    /**
     * A page closed without a reason reaching us (the close happened while
     * the socket was down): learn it from the relay's archive, so a reply that
     * landed isn't reported as "resolved on your Mac". Hidden reasons (stale,
     * superseded) stay unknown.
     */
    suspend fun resolveCloseReason(id: String) {
        if (_recentCloseReasons.value[id] != null) return
        if (_history.value.none { it.id == id }) refreshHistory()
        if (_recentCloseReasons.value[id] != null || _inbox.value.any { it.id == id }) return
        val reason = _history.value.firstOrNull { it.id == id }?.closeReason ?: return
        _recentCloseReasons.value = _recentCloseReasons.value + (id to reason)
        if (reason == "replied") {
            when (_deliveries.value[id]) {
                ReplyDelivery.Sending, is ReplyDelivery.Sent, null -> setDelivery(id, ReplyDelivery.Delivered(null))
                else -> Unit
            }
        }
    }

    private fun applyClose(id: String, reason: String?) {
        inboxSeq += 1
        inboxEvents.addLast(inboxSeq to InboxEvent.Closed(id))
        trimEvents()
        val closing = _inbox.value.firstOrNull { it.id == id }
        // Never invent a reason: unknown stays unknown, so the reply screen
        // can look it up instead of claiming the Mac resolved it.
        var reasons = _recentCloseReasons.value
        if (reason != null) {
            reasons = reasons + (id to reason)
        } else if (reasons[id] == null && closing?.closeReason != null) {
            reasons = reasons + (id to closing.closeReason)
        }
        if (reasons.size > 200) reasons = emptyMap()
        _recentCloseReasons.value = reasons
        _inbox.value = _inbox.value.filter { it.id != id }
        // Our own reply landing: older Workers never send reply.result, the
        // Mac's "replied" close is the success signal.
        if (reason == "replied") {
            when (_deliveries.value[id]) {
                ReplyDelivery.Sending, is ReplyDelivery.Sent, null -> setDelivery(id, ReplyDelivery.Delivered(null))
                else -> Unit
            }
        }
        // Keep History live without a refetch, mirroring the Worker's rules.
        if (closing != null && reason != null && CloseReason.isHistoryWorthy(reason) &&
            _historyLoad.value == LoadState.Loaded && _history.value.none { it.id == id }
        ) {
            _history.value = listOf(closing.copy(closedAt = Instant.now(), closeReason = reason)) + _history.value
        }
    }

    private fun trimEvents() {
        while (inboxEvents.size > 200) inboxEvents.removeFirst()
    }

    // endregion

    // region WebSocket lifecycle

    /**
     * Idempotent. Opens the socket if there isn't one for the current
     * credentials; replaces a socket that belongs to an old pairing.
     */
    fun connect() {
        wantsConnection = true
        val creds = credentials() ?: return
        if (socket != null && socketCredentials == creds) return
        reconnectJob?.cancel()
        reconnectJob = null
        openSocket(creds)
    }

    /** Background (without Stay connected) / unpair: close the socket and stop reconnecting. */
    fun disconnect() {
        wantsConnection = false
        // Socket events stop, so the in-memory inbox starts going stale.
        inboxIsFresh = false
        reconnectJob?.cancel()
        reconnectJob = null
        teardownSocket()
        _connection.value = ConnectionState.DISCONNECTED
    }

    private fun openSocket(creds: RelayCredentials) {
        teardownSocket()
        val url = creds.webSocketUrl ?: return
        val req = Request.Builder().url(url)
            .header("Authorization", "Bearer ${creds.token}")
            .header("User-Agent", userAgent)
            .build()
        socketCredentials = creds
        _connection.value = ConnectionState.CONNECTING
        // `connected` flips only when the handshake completes (onOpen).
        socket = wsClient.newWebSocket(req, Listener())
    }

    private fun teardownSocket() {
        val old = socket
        // Clear first so callbacks triggered by close() fail the identity check.
        socket = null
        socketCredentials = null
        old?.close(1001, null)
        old?.cancel()
    }

    private class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            scope.launch { socketDidOpen(webSocket) }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            scope.launch { if (webSocket === socket) handleMessage(text) }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
            val saysRetired = TokenRetirement.socketCloseNeedsCheck(code, reason)
            scope.launch { socketDidEnd(webSocket, closeSaysRetired = saysRetired) }
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            val saysRetired = TokenRetirement.socketCloseNeedsCheck(code, reason)
            scope.launch { socketDidEnd(webSocket, closeSaysRetired = saysRetired) }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            // A refused upgrade (no 101) says why it was refused only through
            // its status; read it before the response is gone.
            val handshakeStatus = response?.code
            Log.i(TAG, "socket ended: ${t.javaClass.simpleName}${handshakeStatus?.let { " (HTTP $it)" } ?: ""}")
            scope.launch { socketDidEnd(webSocket, handshakeStatus = handshakeStatus) }
        }
    }

    /** The single path for every kind of socket loss. */
    private fun socketDidEnd(ws: WebSocket, closeSaysRetired: Boolean = false, handshakeStatus: Int? = null) {
        if (ws !== socket) return
        teardownSocket()
        _connection.value = ConnectionState.DISCONNECTED
        // A retired or rejected token is confirmed over REST, where the body
        // is readable; /status then marks it, which also stops the reconnects.
        if (closeSaysRetired || (handshakeStatus != null && TokenRetirement.handshakeNeedsCheck(handshakeStatus))) {
            scope.launch { confirmRefusedUpgrade() }
        }
        scheduleReconnect()
    }

    /**
     * GET /status classifies 401/403 and 410 `token_retired`. On a relay
     * without /status, /interventions does the same through handleHttpFailure.
     */
    private suspend fun confirmRefusedUpgrade() {
        if (statusEndpointAvailable == false) refreshInbox() else refreshStatus()
    }

    /**
     * The Mac replaced this pairing. Everything from it is now dead: drop the
     * socket, the inbox, history, deliveries and every notification, and stop
     * talking to the relay. [PairingStore] (watching [retiredWhy]) unpairs and
     * shows the re-pair screen with `why`.
     */
    private fun markRetired(why: String) {
        if (_retiredWhy.value != null || isDemoMode) return
        Log.i(TAG, "pairing retired by the relay")
        reset()
        _retiredWhy.value = why
        notifier.clearAll()
    }

    private fun scheduleReconnect() {
        if (!wantsConnection || reconnectJob != null || credentials() == null) return
        val delaySeconds = ReconnectBackoff.delaySeconds(reconnectAttempt, Math.random())
        reconnectAttempt += 1
        reconnectJob = scope.launch {
            delay((delaySeconds * 1000).toLong())
            reconnectJob = null
            if (wantsConnection) connect()
        }
    }

    private fun socketDidOpen(ws: WebSocket) {
        if (ws !== socket) return
        _connection.value = ConnectionState.CONNECTED
        reconnectAttempt = 0
        SessionStore.socketOpened()
        // Anything broadcast while we were disconnected is gone; resync.
        scope.launch {
            refreshInbox()
            refreshStatus()
            if (_historyLoad.value == LoadState.Loaded) refreshHistory()
        }
    }

    private fun handleMessage(text: String) {
        // The Worker answers an application-level "ping" with "pong"; neither
        // is JSON.
        val envelope = parseJsonObject(text) ?: return
        val type = envelope.str("type") ?: return
        val payload = envelope.obj("payload") ?: JsonObject(emptyMap())
        TokenRetirement.whyFromFrame(type, payload)?.let {
            markRetired(it)
            return
        }
        when (type) {
            "intervention.opened" -> {
                val iv = Intervention.decode(payload) ?: return
                inboxSeq += 1
                inboxEvents.addLast(inboxSeq to InboxEvent.Opened(iv))
                trimEvents()
                _inbox.value = Intervention.urgencySorted(_inbox.value.filter { it.id != iv.id } + iv)
                notifier.pageOpened(iv)
            }
            "intervention.closed" -> {
                val id = payload.str("id") ?: return
                applyClose(id, payload.str("reason"))
                notifier.pagesClosed(listOf(id))
            }
            "heartbeat" -> _macStatus.value =
                MacStatusSnapshot.applyingHeartbeat(_macStatus.value, payload, Instant.now(), statusEndpointAvailable == true)
            "mac.status" -> {
                val old = _macStatus.value ?: MacStatusSnapshot()
                val wasConnected = old.macConnected == true
                var snap = old
                payload.bool("macConnected")?.let { connected ->
                    snap = snap.copy(macConnected = connected, macEverSeen = if (connected) true else snap.macEverSeen)
                }
                PageDate.parseAny(payload["lastHeartbeatAt"])?.let { snap = snap.copy(lastHeartbeatAt = it) }
                _macStatus.value = snap
                if (snap.macConnected == true && !wasConnected) SessionStore.macCameOnline()
            }
            // Opaque to the relay; SessionStore decrypts and applies it.
            "sessions.update" -> SessionStore.handleUpdate(payload)
            "reply.result" -> {
                val id = payload.str("interventionId") ?: return
                val detail = payload.str("detail")?.takeIf { it.isNotEmpty() }
                if (payload.bool("success") == true) {
                    setDelivery(id, ReplyDelivery.Delivered(detail))
                } else {
                    setDelivery(id, ReplyDelivery.Failed(detail ?: "Your Mac couldn't deliver the reply."))
                }
            }
            // Unknown frame types are ignored (PROTOCOL.md §2).
            else -> Unit
        }
    }

    // endregion

    // region Errors

    fun describe(error: Throwable): String = when {
        !isOnline() -> "Your phone is offline."
        error is UnknownHostException -> "The relay's address can't be found."
        error is ConnectException -> "The relay isn't accepting connections."
        error is SocketTimeoutException -> "The relay didn't respond in time."
        error is SSLException -> "A secure connection to the relay couldn't be made."
        error is IOException && error.message?.contains("Canceled") == true -> "The relay didn't respond in time."
        else -> error.message ?: error.javaClass.simpleName
    }

    private fun isOnline(): Boolean {
        val cm = AppGraph.app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return true
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    // endregion
}
