package app.page.android.model

import java.time.Instant

// Port of iOS/Page/Models/InFlightRows.swift. The In flight section of Now:
// one card per working session, each with two plain ways in, in words (Open:
// watch the terminal, Steer: type to it). Pure values, no clock inside, so the
// logic tests can feed any situation. (Replaces the first Android in-flight
// model, [LegacyInFlightRow], which the screens stage retires.)

/**
 * How a session's room opens. A tap on the card is Story; its two buttons say "Open" (the Screen lens) and
 * "Steer" (the composer); the long-press menu's Stop opens the room where the existing 0.6 s hold-to-stop lives.
 * Nothing here sends anything: Steer only brings up the composer, and Return still goes through [RoomSend].
 */
enum class RoomEntry(val raw: String) {
    STORY("story"), SCREEN("screen"), TYPE("type"), STOP("stop");

    /** The lens the room starts on. Screen falls back to Story until the Mac has sent a mirror ([RoomLens.resolve]). */
    val lens: RoomLens get() = if (this == SCREEN) RoomLens.SCREEN else RoomLens.STORY

    /** The composer takes the keyboard when the room opens. */
    val focusesComposer: Boolean get() = this == TYPE

    /** The room says what the Stop hold will do while it is being found. */
    val showsStopHint: Boolean get() = this == STOP

    /** What the button says. The cases keep their names; the words are the Mac's. */
    val buttonTitle: String
        get() = when (this) {
            STORY -> "Story"
            SCREEN -> "Open"
            TYPE -> "Steer"
            STOP -> "Stop"
        }
}

/** A session working right now, as one row. */
data class InFlightRow(
    val id: String,
    val project: String,
    /** "Claude", "Codex", "Ollama". */
    val character: String,
    val characterKind: AgentCharacter.Kind,
    /** "cmux › page": the terminal and the project; null when neither is known. */
    val route: String?,
    /** "cmux": the terminal alone, for the row's small print (the project is already its title). */
    val host: String?,
    /** What it is doing, clipped: "[Bash] vitest · 212 passed". */
    val step: String,
    /** "4m": how long since it last did something. The Mac does not send a start time, so this is the time since its last step, never "elapsed". */
    val age: String?,
    /** "4 of 7", for a session running a workflow. */
    val progress: String?,
    val seed: ULong,
    val hue: ProjectHue,
    /** Page can type in this terminal (the Mac's word). */
    val canType: Boolean,
    /** Page can press Esc in this terminal mid-turn (the Mac's word). */
    val canStop: Boolean,
    /** This terminal can send a screen mirror (tmux, cmux, WezTerm, kitty, Herdr). */
    val canMirror: Boolean,
    /** The step in words, the steps before it, the clocks, workflows and health. */
    val card: InFlightCard = InFlightCard(now = "Working"),
) {
    /** The spoken line: "relay, Claude in tmux, Running vitest, working 4m, 1 workflow running". */
    val spoken: String
        get() {
            val parts = arrayListOf(project, route?.let { "$character in $it" } ?: character, card.now)
            card.health.label?.let { parts.add(it) }
            card.timeText?.let { parts.add(it) }
            val w = card.workflowHeading
            if (w != null) parts.add(w) else if (progress != null) parts.add(progress)
            return parts.joinToString(", ")
        }
}

/** The section as drawn: the visible rows, how many there are in all and how many a cap hides. */
data class InFlightSection(
    val rows: List<InFlightRow>,
    val total: Int,
    val isExpanded: Boolean,
    /** Every working session, in the same order: the side-scroll strip above the cards, which stays whole when a cap hides some cards. */
    val strip: List<InFlightRow> = emptyList(),
) {
    val hidden: Int get() = maxOf(0, total - rows.size)
    val isCapped: Boolean get() = total > collapsedLimit

    /** The strip is a summary of two or more; one session is just its card. */
    val showsStrip: Boolean get() = strip.size > 1
    val showAllLabel: String get() = "Show all $total"

    companion object {
        val empty = InFlightSection(emptyList(), 0, false)

        /** Rows shown before "Show all N". */
        const val collapsedLimit = 3

        /** Hosts the Mac can mirror the screen of. */
        val mirrorHosts: Set<String> = setOf("tmux", "cmux", "wezterm", "kitty", "herdr", "claude squad")

        /**
         * Working sessions in a steady order (project, then title, then id), so a row never swaps places under a
         * finger between two refreshes: a Steer tap always lands on the session it was drawn beside. Only once
         * the Mac's session list has arrived. Pure.
         */
        fun build(
            sessions: List<LiveSession>, hasSessionList: Boolean, workflows: Map<String, List<WorkflowRun>> = emptyMap(),
            stuck: Set<String> = emptySet(), now: Instant, expanded: Boolean = false, limit: Int = collapsedLimit,
            zone: java.time.ZoneId = java.time.ZoneId.systemDefault(),
        ): InFlightSection {
            if (!hasSessionList) return empty
            val active = sessions.filter { it.state == LiveSessionState.ACTIVE }.map { s ->
                val project = SkyModel.projectName(s.cwd, s.title)
                val run = workflows[s.id]?.firstOrNull { it.isRunning }
                val host = Sw.trimWs(s.host).lowercase()
                val who = AgentCharacter.from(s.backend, s.provider)
                val row = InFlightRow(
                    id = s.id, project = project, character = who.name, characterKind = who.kind,
                    route = DeliveryPreview.route(s.host, project), host = DeliveryPreview.route(s.host, null),
                    step = if (s.preview.isEmpty()) "working" else SkyModel.clip(s.preview, 80),
                    age = s.lastActivityAt?.let { RelativeTime.compact(maxOf(0.0, now.secondsSince(it)).toLong()) },
                    progress = run?.let { "${it.done} of ${it.total}" },
                    seed = StableHash.fnv1a(if (s.cwd.isEmpty()) s.id else s.cwd + "|" + s.id),
                    hue = ProjectHue.of(if (s.cwd.isEmpty()) s.title else s.cwd),
                    canType = s.canType, canStop = s.canInterrupt, canMirror = host in mirrorHosts,
                    card = InFlightCard.build(s, workflows[s.id] ?: emptyList(), stuck.contains(s.id), now, zone),
                )
                Pair(row, s.title)
            }.sortedWith { a, b ->
                val p = a.first.project.compareTo(b.first.project, ignoreCase = true)
                if (p != 0) return@sortedWith p
                val t = a.second.compareTo(b.second, ignoreCase = true)
                if (t != 0) return@sortedWith t
                a.first.id.compareTo(b.first.id)
            }.map { it.first }
            val capped = !expanded && active.size > limit
            return InFlightSection(if (capped) active.take(limit) else active, active.size, expanded && active.size > limit, active)
        }
    }
}
