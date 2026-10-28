package app.page.android.data

import app.page.android.model.FlightHealth
import app.page.android.model.InFlightSection
import app.page.android.model.Intervention
import app.page.android.model.InterventionKind
import app.page.android.model.LanesModel
import app.page.android.model.MacChipModel
import app.page.android.model.MacPresence
import app.page.android.model.MacStatusSnapshot
import app.page.android.model.NotificationsState
import app.page.android.model.NowBanner
import app.page.android.model.NowInputs
import app.page.android.model.NowModel
import app.page.android.model.NowRow
import app.page.android.model.PulseModel
import app.page.android.model.RingSummary
import app.page.android.model.SettledLog
import app.page.android.model.SkyModel
import app.page.android.model.StableOrder
import app.page.android.model.StopPlan
import app.page.android.model.ProblemState
import app.page.android.model.ReturnBrief
import app.page.android.notify.AppVisibility
import app.page.android.notify.NotificationAccess
import app.page.android.notify.StayConnectedService
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Everything Now and Lanes draw, built from what the phone already holds (inbox pages, live sessions, the Mac's
 * status and history, delivery state, the away record), off the main thread, as one value. The pure builders
 * ([NowModel], [InFlightSection], [SettledLog], [SkyModel] ...) do the work; this only gathers inputs and applies
 * the one stateful rule: the order never re-sorts under a finger ([StableOrder]).
 */
object NowStore {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** What the screens read. */
    data class Screen(
        val model: NowModel,
        /** The Decide, Look and Review rows in the order to draw: frozen while the stream is touched ([StableOrder]). */
        val rows: List<NowRow>,
        /** Arrivals held back behind the "New ↑ N" pill. */
        val queuedNew: Int,
        val inFlight: InFlightSection,
        val settled: SettledLog,
        val banners: List<NowBanner>,
        /** A calm full statement when something is wrong (replaces its banners). */
        val problem: ProblemState?,
        val brief: ReturnBrief?,
        /** The handover Horizon sentence ("While you were away (1h 52m) · 3 finished"), when it applies. */
        val handover: String?,
        val macChip: MacChipModel,
        val pulse: PulseModel,
        val stopPlan: StopPlan,
        val sky: SkyModel,
        val lanes: LanesModel,
        val macName: String,
        val status: MacStatusSnapshot?,
        val now: Instant,
        val paired: Boolean,
        /** The inbox has loaded (Final approach treats the first look at it as no news, not a flood of arrivals). */
        val inboxLoaded: Boolean = false,
    ) {
        /** The decisions and looks the nav bar badges: Decide count (amber) and working count (teal). */
        val decideCount: Int get() = model.needYouCount
        val workingCount: Int get() = model.workingCount
        val ringsTitle: String get() = RingSummary.title(model.rings)
    }

    private val _frozen = MutableStateFlow(false)

    /** True while a finger is on the stream, it is scrolling, or a sheet is up. */
    val frozen: StateFlow<Boolean> = _frozen.asStateFlow()

    /** Bumped by the pill: show what arrived. */
    private val _release = MutableStateFlow(0)

    /** "Show all N" is open in In flight. */
    private val _inFlightExpanded = MutableStateFlow(false)
    val inFlightExpanded: StateFlow<Boolean> = _inFlightExpanded.asStateFlow()

    fun toggleInFlightExpanded() {
        _inFlightExpanded.value = !_inFlightExpanded.value
    }

    private var shownIds: List<String> = emptyList()

    fun setFrozen(on: Boolean) {
        _frozen.value = on
    }

    /** The "New ↑ N" pill was tapped: show the queued arrivals now. */
    fun releaseNew() {
        shownIds = emptyList()
        _release.value += 1
    }

    /** The clock and zone the screens are built in. Real ones, unless the render harness pins them (a fixed "now", UTC). */
    @Volatile var clock: () -> Instant = { Instant.now() }

    @Volatile var zone: java.time.ZoneId = java.time.ZoneId.systemDefault()

    /**
     * Re-reads the clock so relative times, presence and the runway move when no data does ([NowTicker] for the
     * cadence): every 15 s while a Page screen is up, once a minute while only Stay connected's notification and the
     * widget show Now, and not at all when nothing live does (the socket is closed then, so there is nothing new to
     * show, and the 15-minute check keeps the widget). Coming back on screen re-reads it at once. Data that changes
     * rebuilds Now whatever the ticker does. The first value is always sent, so the screen builds in a process that
     * starts in the background (boot, the service).
     */
    private val ticker = flow {
        emit(clock())
        while (true) {
            val visible = AppVisibility.visible.value
            withTimeoutOrNull(NowTicker.waitMillis(visible)) { AppVisibility.visible.first { it != visible } }
            if (NowTicker.ticks(AppVisibility.visible.value, StayConnectedService.running)) emit(clock())
        }
    }

    private data class A(
        val inbox: List<Intervention>, val history: List<Intervention>, val status: MacStatusSnapshot?,
        val deliveries: Map<String, app.page.android.model.ReplyDelivery>, val deliveryTimes: Map<String, Instant>,
    )

    private data class B(
        val load: RelayClient.LoadState, val connection: RelayClient.ConnectionState, val authRejected: Boolean, val retired: String?,
        val sessions: SessionStore.State, val mac: app.page.android.model.PairedMac?,
    )

    private data class C(val frozen: Boolean, val release: Int, val now: Instant, val away: AwayStore.State, val notif: NotificationAccess.Authorization, val expanded: Boolean)

    private val a = combine(
        RelayClient.inbox, RelayClient.history, RelayClient.macStatus, RelayClient.deliveries, RelayClient.deliveryTimes,
    ) { inbox, history, status, deliveries, times -> A(inbox, history, status, deliveries, times) }

    private val b = combine(
        RelayClient.inboxLoad, RelayClient.connection, RelayClient.authRejected, RelayClient.retiredWhy, SessionStore.state,
    ) { load, conn, auth, retired, sessions -> B(load, conn, auth, retired, sessions, null) }

    private val ui = combine(_frozen, _release, _inFlightExpanded) { frozen, release, expanded -> Triple(frozen, release, expanded) }

    private val c = combine(ui, ticker, AwayStore.state, NotificationAccess.authorization) { u, now, away, notif ->
        C(u.first, u.second, now, away, notif, u.third)
    }

    /** The one value the screens collect. */
    val screen: StateFlow<Screen> = combine(a, b, c, PairingStore.pairedMac, ActivityStore.version) { a, b, c, mac, _ ->
        build(a, b.copy(mac = mac), c)
    }.flowOn(Dispatchers.Default).stateIn(scope, SharingStarted.Eagerly, empty())

    private fun empty(): Screen = build(
        A(emptyList(), emptyList(), null, emptyMap(), emptyMap()),
        B(RelayClient.LoadState.Idle, RelayClient.ConnectionState.DISCONNECTED, false, null, SessionStore.State(), null),
        C(false, 0, Instant.now(), AwayStore.State(), NotificationAccess.Authorization.UNKNOWN, false),
    )

    @Synchronized
    private fun build(a: A, b: B, c: C): Screen {
        val now = c.now
        val macName = b.mac?.name ?: ""
        val s = b.sessions
        val inboxState = when (b.load) {
            is RelayClient.LoadState.Loaded -> NowInputs.InboxState.LOADED
            is RelayClient.LoadState.Failed -> NowInputs.InboxState.FAILED
            else -> NowInputs.InboxState.LOADING
        }
        val inputs = NowInputs(
            interventions = a.inbox, inbox = inboxState, sessions = s.sessions, hasSessionList = s.hasList, status = a.status,
            history = a.history, deliveries = a.deliveries, deliveryTimes = a.deliveryTimes, now = now, macName = macName, zone = zone,
        )
        val model = NowModel.build(inputs)
        val merged = StableOrder.merge(shownIds, model.rows, c.frozen)
        shownIds = merged.rows.map { it.id }

        val stuck = FlightHealth.stuckSessionIds(a.inbox)
        val inFlight = InFlightSection.build(s.sessions, s.hasList, s.workflows, stuck, now, expanded = c.expanded, zone = zone)
        val settled = SettledLog.build(a.history, now, zone)
        val presence = MacPresence.evaluate(a.status, now)
        val notifications = when (c.notif) {
            NotificationAccess.Authorization.AUTHORIZED -> NotificationsState.ALLOWED
            NotificationAccess.Authorization.DENIED -> NotificationsState.OFF
            NotificationAccess.Authorization.NOT_DETERMINED -> NotificationsState.NOT_SET
            NotificationAccess.Authorization.UNKNOWN -> NotificationsState.CHECKING
        }
        val connected = b.connection == RelayClient.ConnectionState.CONNECTED
        val problem = ProblemState.build(
            ProblemState.Inputs(
                macName = macName, presence = presence, authRejected = b.authRejected, retired = b.retired != null,
                inboxFailure = b.load.failureMessage, connected = connected, relayHost = PairingStore.relayHost.value,
                battery = a.status?.battery, onAC = a.status?.onAC, cutoff = a.status?.forecast?.cutoff,
                pausedSessions = if (model.paused) a.inbox.count { it.subtype == "low_battery" } else 0,
                lastKnownAt = s.lastListAt, now = now,
            ),
        )
        val allBanners = NowBanner.build(NowBanner.Inputs(b.authRejected, b.load.failureMessage, connected, presence, notifications, now))
        val banners = if (problem == null) allBanners else allBanners.filter { it.id !in problem.replacesBanners }

        val absence = c.away.absence
        val brief = if (c.away.showsBrief && absence != null) {
            ReturnBrief.build(absence.since, absence.returnedAt, a.history, a.inbox, s.sessions, s.hasList, a.status, zone)
        } else null
        val handover = absence?.takeIf { it.showsHandover(now) }?.let {
            ReturnBrief.handoverSentence(it.duration, ReturnBrief.build(it.since, it.returnedAt, a.history, a.inbox, s.sessions, s.hasList, a.status, zone).finished, model.needYouCount)
        }

        val sky = SkyModel.build(s.sessions, a.inbox, a.status, model.rings, macName, model.paused, now)
        val lanes = LanesModel.build(sky, ActivityStore.log, now)
        // The wait in 15 s steps, so a rebuild for any other reason leaves the ripple's pace, and its rings, where they
        // were (the nav pulse reads it from here too).
        val pulse = PulseModel(model.workingCount, model.pulseWaiting, PulseModel.steppedWait(PulseModel.longestWait(model.pulseRows.map { it.waitingSince }, now)), model.paused)
        return Screen(
            model = model, rows = merged.rows, queuedNew = merged.queuedNew, inFlight = inFlight, settled = settled, banners = banners,
            problem = problem, brief = brief, handover = handover, macChip = MacChipModel.build(macName, a.status, now),
            pulse = pulse, stopPlan = StopPlan.build(s.sessions, s.hasList, a.status?.working, macName), sky = sky, lanes = lanes,
            macName = macName, status = a.status, now = now, paired = b.mac != null, inboxLoaded = b.load == RelayClient.LoadState.Loaded,
        )
    }

    private val observing = java.util.concurrent.atomic.AtomicBoolean(false)

    /**
     * Records what the sessions are doing for Lanes' 4-hour strip (called from the collector in the UI layer, off the
     * main thread). Once per process: the shell calls it each time it is composed (a rotation, a re-pair), and these
     * collectors live as long as the process.
     */
    fun observeActivity() {
        if (!observing.compareAndSet(false, true)) return
        // The widget and the Quick Settings tile show counts and one sentence, kept in a small snapshot.
        scope.launch {
            screen.collect { sc ->
                if (!sc.paired || (RelayClient.isDemoMode && !app.page.android.BuildConfig.DEBUG)) return@collect
                StatusSnapshotStore.write(
                    StatusSnapshot.of(sc.macName, sc.status, sc.model.pulseWaiting, sc.model.workingCount, sc.model.headline, sc.model.subline, sc.model.runway, Instant.now()),
                )
            }
        }
        scope.launch {
            combine(SessionStore.state, RelayClient.inbox) { s, inbox -> Pair(s, inbox) }.collect { (s, inbox) ->
                val paused = inbox.any { it.kind == InterventionKind.IDLE && it.subtype == "low_battery" }
                ActivityStore.observe(s.sessions, inbox, paused)
                ActivityStore.observePower(paused, s.sessions)
            }
        }
    }
}

/**
 * The cadence of [NowStore]'s clock (pure, so a test can pin it). The model is rebuilt from scratch on each tick
 * (reversibility regexes and all), so it ticks only while someone can see the result.
 */
object NowTicker {
    /** A Page screen is up: relative times ("waiting 4m") and the runway stay current. */
    const val VISIBLE_MS: Long = 15_000L

    /**
     * Off screen: often enough that a Mac that stops checking in reads so in Stay connected's notification within
     * a minute of [app.page.android.model.MacPresence.STALE_AFTER].
     */
    const val BACKGROUND_MS: Long = 60_000L

    fun waitMillis(visible: Boolean): Long = if (visible) VISIBLE_MS else BACKGROUND_MS

    /** Whether a tick is worth a rebuild: something live shows Now (the app, or the socket Stay connected holds). */
    fun ticks(visible: Boolean, holdingSocket: Boolean): Boolean = visible || holdingSocket
}
