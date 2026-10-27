package app.page.android.data

import app.page.android.model.ActivityLog
import app.page.android.model.DuskDawnLog
import app.page.android.model.Intervention
import app.page.android.model.InterventionKind
import app.page.android.model.LiveSession
import app.page.android.model.LiveSessionState
import app.page.android.model.PageSubtype
import app.page.android.model.StarState
import java.time.Instant
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Watches the live session list while Page is open and remembers, five minutes to a bucket, what each session
 * was doing: the data behind the 4-hour strip on a lane. The Mac keeps no such history, so time Page was closed
 * stays blank. Saved to the preferences at most once a minute. Also keeps the power story (the last battery
 * pause: dusk and dawn).
 */
object ActivityStore {
    var log: ActivityLog = ActivityLog()
        private set
    var duskDawn: DuskDawnLog = DuskDawnLog()
        private set

    /** Bumped whenever [log] or [duskDawn] changed, so a collector can re-read them. */
    private val _version = MutableStateFlow(0)
    val version: StateFlow<Int> = _version.asStateFlow()

    private var lastSaved = Instant.EPOCH
    private var lastStates: Map<String, StarState> = emptyMap()
    private var lastBucket = 0

    fun init() {
        log = ActivityLog.fromJson(AppGraph.prefs.string(ActivityLog.storageKey))
        _version.value += 1
    }

    /** Records the states seen now. Cheap when nothing changed inside a bucket. */
    @Synchronized
    fun observe(sessions: List<LiveSession>, interventions: List<Intervention>, paused: Boolean, now: Instant = Instant.now()) {
        if (sessions.isEmpty()) return
        val stuck = interventions.filter { it.kind == InterventionKind.IDLE && PageSubtype.isStuck(it.subtype) }.map { it.sessionId }.toSet()
        val states = sessions.associate { it.id to StarState.of(it, stuck.contains(it.id), paused) }
        val bucket = ActivityLog.bucketIndex(now)
        if (states == lastStates && bucket == lastBucket) return
        lastStates = states
        lastBucket = bucket
        log.record(states, now)
        if (now.toEpochMilli() - lastSaved.toEpochMilli() > 60_000) {
            lastSaved = now
            AppGraph.prefs.putString(ActivityLog.storageKey, log.toJson())
        }
        _version.value += 1
    }

    /** The power story as a stable value for the views (a copy, republished whenever the dusk or dawn changes). */
    private val _power = MutableStateFlow(DuskDawnLog())
    val power: StateFlow<DuskDawnLog> = _power.asStateFlow()

    /** Set by the render harness: the fixture's power story is not overwritten by the live observer. */
    @Volatile private var powerPinned = false

    /** Records the power story: the pause, the dawn, and each session seen working again after it (a star relights only on that). */
    @Synchronized
    fun observePower(paused: Boolean, sessions: List<LiveSession>, now: Instant = Instant.now()) {
        if (powerPinned) return
        val before = duskDawn.key
        duskDawn.observe(paused, sessions.filter { it.state == LiveSessionState.ACTIVE }.map { it.id }.toSet(), now)
        if (duskDawn.key != before) {
            _power.value = duskDawn.copy()
            _version.value += 1
        }
    }

    /** The render harness's power story (a pause, or a dawn with some resumes confirmed), held against the live observer. */
    @Synchronized
    fun overridePowerForRender(log: DuskDawnLog?) {
        powerPinned = log != null
        duskDawn = log ?: DuskDawnLog()
        _power.value = duskDawn.copy()
        _version.value += 1
    }

    /** Writes what is held (the app is going to the background). */
    fun flush() {
        AppGraph.prefs.putString(ActivityLog.storageKey, log.toJson())
        lastSaved = Instant.now()
    }

    /** Forgets everything (another Mac's sessions are different sessions). */
    @Synchronized
    fun reset() {
        log = ActivityLog()
        duskDawn = DuskDawnLog()
        _power.value = DuskDawnLog()
        lastStates = emptyMap()
        AppGraph.prefs.putString(ActivityLog.storageKey, log.toJson())
        _version.value += 1
    }

    /** The render harness's fixture: a log with history. */
    fun overrideForRender(log: ActivityLog) {
        this.log = log
        _version.value += 1
    }
}
