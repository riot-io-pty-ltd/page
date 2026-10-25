package app.page.android.model

import java.time.Instant

// Shared builders for the logic tests (ported from iOS/Tests/LogicTests.swift).

fun at(seconds: Double): Instant = PageDate.ofEpochSeconds(seconds)

val NOW: Instant = at(10_000.0)

/** The sessions tests' clock: the spec vector's `ts`. */
val CMD_NOW: Instant = at(1_761_300_000.0)

fun iv(
    id: String,
    kind: InterventionKind,
    t: Double,
    replied: Double? = null,
    project: String = "p",
): Intervention = Intervention(
    id = id, sessionId = id, cwd = "", projectName = project, kind = kind,
    openedAt = at(t), context = "", repliedAt = replied?.let(::at),
)

fun ls(id: String, state: LiveSessionState, t: Double?, title: String = "p"): LiveSession = LiveSession(
    id = id, backend = AgentBackend.Known(InterventionBackend.CLAUDE), title = title, cwd = "", state = state,
    host = "cmux", canType = true, typeBlocker = null, canInterrupt = true, provider = null,
    lastActivityAt = t?.let(::at), interventionId = null, preview = "",
)

fun bytes(range: IntRange): ByteArray = range.map { it.toByte() }.toByteArray()
