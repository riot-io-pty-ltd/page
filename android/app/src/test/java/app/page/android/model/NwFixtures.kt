package app.page.android.model

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant

// Night Watch fixtures, ported from the shared fixtures in iOS/Tests/LogicTests.swift.

/** Fixed clock for the Night Watch checks: 2027-01-15 08:00:00 UTC. */
const val NW_T0: Double = 1_800_000_000.0
val nwNow: Instant = at(NW_T0)

/** A page built in code, with the fields the phone reads set. */
fun nwIv(
    id: String,
    kind: InterventionKind,
    context: String = "",
    t: Double = NW_T0,
    session: String? = null,
    cwd: String = "/Users/me/proj",
    project: String = "page",
    subtype: String? = null,
    backend: InterventionBackend? = InterventionBackend.CLAUDE,
    hookBlocking: Boolean? = null,
): Intervention = Intervention(
    id = id, sessionId = session ?: "s-$id", cwd = cwd, projectName = project, kind = kind,
    openedAt = at(t), context = context, backend = backend, subtype = subtype, hookBlocking = hookBlocking,
)

/** A live session as the Mac sends it: decoded, so the phone's own defaults apply. */
fun nwSession(
    id: String,
    title: String = "bottle-flip",
    state: String = "waitingOnApproval",
    host: String = "Terminal",
    canType: Boolean = true,
    blocker: String? = null,
    backend: String = "claude",
    cwd: String = "~/code/bottle-flip",
    preview: String = "",
    interventionId: String? = null,
    activeAt: Double? = null,
    canInterrupt: Boolean = false,
    provider: String? = null,
): LiveSession {
    val obj: JsonObject = buildJsonObject {
        put("id", id)
        put("backend", backend)
        put("title", title)
        put("cwd", cwd)
        put("state", state)
        put("host", host)
        put("canType", canType)
        put("canInterrupt", canInterrupt)
        put("preview", preview)
        if (blocker != null) put("typeBlocker", blocker)
        if (interventionId != null) put("interventionId", interventionId)
        if (activeAt != null) put("lastActivityAt", at(activeAt).toString())
        if (provider != null) put("provider", provider)
    }
    return LiveSession.decode(obj)!!
}

/** Decodes a page from its wire JSON, as the relay sends it. */
fun pageFromJson(json: String): Intervention = Intervention.decode(parseJson(json)!!)!!

/** A Mac status reading, fresh unless [age] says otherwise. */
fun nwStatus(
    connected: Boolean? = true,
    age: Double = 5.0,
    battery: Int? = null,
    onAC: Boolean? = null,
    forecast: BatteryForecast? = null,
    working: Int? = null,
    usage: ClaudeUsage? = null,
): MacStatusSnapshot = MacStatusSnapshot(
    macConnected = connected, lastHeartbeatAt = at(NW_T0 - age), battery = battery, onAC = onAC,
    working = working, forecast = forecast, usage = usage,
)

/** The Now model's inputs for a fixed clock, Studio MBP, and UTC so the clock strings are fixed. */
fun nwNowInputs(
    rows: List<Intervention> = emptyList(),
    sessions: List<LiveSession> = emptyList(),
    hasList: Boolean = false,
    status: MacStatusSnapshot? = null,
    inbox: NowInputs.InboxState = NowInputs.InboxState.LOADED,
    history: List<Intervention> = emptyList(),
    deliveries: Map<String, ReplyDelivery> = emptyMap(),
    deliveryTimes: Map<String, Instant> = emptyMap(),
    now: Instant = nwNow,
): NowInputs = NowInputs(
    interventions = rows, inbox = inbox, sessions = sessions, hasSessionList = hasList, status = status,
    history = history, deliveries = deliveries, deliveryTimes = deliveryTimes, now = now,
    macName = "Studio MBP", zone = NW_ZONE,
)

val NW_ZONE: java.time.ZoneId = java.time.ZoneId.of("UTC")
