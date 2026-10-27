package app.page.android.model

import java.time.Instant
import java.time.ZoneId
import java.util.regex.Pattern
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

// Port of iOS/Page/Models/InFlightCards.swift. The In flight card: everything a
// working session shows on Now, built from what the Mac's list says. Every
// richer field is OPTIONAL on the wire (docs/SESSIONS-PROTOCOL.md, "In-flight
// fields"): an older Mac sends none of them and the card shows what it has
// (project, route, the step, "active 4m ago") and leaves the rest out, never an
// empty heading. No clock inside; callers pass `now`.

// MARK: - Wire

/**
 * The optional per-session fields behind an In flight card.
 *
 * Wire names (all optional, on a `sessions[]` row of the `list`): `busySince`
 * and `startedAt` (when this turn and the session began), `model`
 * ("Opus 4.7"), `recentSteps` (oldest first, the last the current step, in the
 * Mac's plain words; tool one-liners and {"text": ...} objects are read too),
 * `health` (normal | longRunning | stuck | rateLimited, left out by the Mac
 * when normal), `healthDetail` (`healthNote` is the same), `resetsAt` (rate
 * limit), `stepSince` (the current step began), and `workflows` (up to 3
 * running ones, as {name, phase, done, total}) with `workflowsRunning`, how
 * many run in all.
 */
data class SessionFlight(
    val busySince: Instant?,
    val startedAt: Instant?,
    val model: String?,
    val recentSteps: List<String>,
    val health: String?,
    val healthNote: String?,
    val workflows: List<WorkflowBrief>,
    /** How many workflows run in all; the list carries at most 3 of them. */
    val workflowsRunning: Int?,
    val resetsAt: Instant?,
    val stepSince: Instant?,
) {
    val isEmpty: Boolean
        get() = busySince == null && startedAt == null && model == null && recentSteps.isEmpty() && health == null &&
            healthNote == null && workflows.isEmpty() && workflowsRunning == null && resetsAt == null && stepSince == null

    companion object {
        const val maxSteps = 6
        const val maxWorkflows = 6

        /** null when the Mac sent none of it (an older Mac), so "no detail" and a real value are told apart. */
        fun make(
            busySince: Instant?, startedAt: Instant?, model: String?, recentSteps: List<String>, health: String?, healthNote: String?,
            workflows: List<WorkflowBrief>, workflowsRunning: Int? = null, resetsAt: Instant? = null, stepSince: Instant? = null,
        ): SessionFlight? {
            fun clean(s: String?, n: Int): String? {
                val t = s?.let { Sw.trimWsNl(it) } ?: return null
                if (t.isEmpty()) return null
                return Sw.chars(t).take(n).joinToString("")
            }
            val steps = recentSteps.mapNotNull { clean(it, 200) }.takeLast(maxSteps)
            val f = SessionFlight(
                busySince, startedAt, clean(model, 60), steps, clean(health, 24), clean(healthNote, 160),
                workflows.take(maxWorkflows), workflowsRunning?.takeIf { it > 0 }, resetsAt, stepSince,
            )
            return if (f.isEmpty) null else f
        }

        /** Reads the optional in-flight fields off one `sessions[]` object (iOS `LiveSession.init(from:)`). */
        fun decode(c: JsonObject): SessionFlight? {
            val steps = lossyList(c["recentSteps"], ::decodeStep)?.elements ?: emptyList()
            val workflows = lossyList(c["workflows"], WorkflowBrief::decode)?.elements ?: emptyList()
            return make(
                busySince = LenientDate.decode(c, "busySince"), startedAt = LenientDate.decode(c, "startedAt"),
                model = c.str("model"), recentSteps = steps,
                health = c.str("health"), healthNote = c.str("healthDetail") ?: c.str("healthNote"),
                workflows = workflows, workflowsRunning = c.int("workflowsRunning"),
                resetsAt = LenientDate.decode(c, "resetsAt"), stepSince = LenientDate.decode(c, "stepSince"),
            )
        }

        /** A step is a string, or an object with `text`, `step`, `label` or `summary`. */
        private fun decodeStep(e: JsonElement): String? {
            (e as? JsonPrimitive)?.takeIf { it !is JsonNull && it.isString }?.let { return it.content }
            val o = e as? JsonObject ?: return null
            return o.str("text") ?: o.str("step") ?: o.str("label") ?: o.str("summary")
        }
    }
}

/** A running workflow, as the list summarises it. */
data class WorkflowBrief(
    val name: String,
    val phase: String? = null,
    val done: Int = 0,
    val total: Int = 0,
    val status: String? = null,
) {
    val running: Boolean get() = status == null || status == "running"

    companion object {
        fun decode(e: JsonElement): WorkflowBrief? {
            val c = e as? JsonObject ?: return null
            val n = c.str("name")?.let { Sw.trimWsNl(it) }?.takeIf { it.isNotEmpty() } ?: return null
            return WorkflowBrief(
                name = Sw.chars(n).take(80).joinToString(""),
                phase = c.str("phase")?.takeIf { it.isNotEmpty() }?.let { Sw.chars(it).take(60).joinToString("") },
                done = maxOf(0, c.int("done") ?: 0),
                total = maxOf(0, c.int("total") ?: 0),
                status = c.str("status")?.takeIf { it.isNotEmpty() }?.let { Sw.chars(it).take(20).joinToString("") },
            )
        }
    }
}

/**
 * A date the Mac may send as an ISO string (like `lastActivityAt`) or as epoch
 * milliseconds or seconds (like the workflows kind). Anything else is null.
 */
object LenientDate {
    fun decode(c: JsonObject, key: String): Instant? {
        val v = c[key] as? JsonPrimitive ?: return null
        if (v is JsonNull) return null
        if (v.isString) return fromString(v.content)
        return v.content.toDoubleOrNull()?.let { fromNumber(it) }
    }

    /** Above 1e11 it is milliseconds (1e11 s is year 5138); below, seconds. */
    fun fromNumber(n: Double): Instant? {
        if (!n.isFinite() || n <= 0) return null
        return if (n > 1e11) PageDate.ofEpochMillis(n) else PageDate.ofEpochSeconds(n)
    }

    fun fromString(s: String): Instant? {
        val t = Sw.trimWs(s)
        t.toDoubleOrNull()?.let { return fromNumber(it) }
        return PageDate.parse(t)
    }
}

// MARK: - Words

/** "12m", "2h 10m", "40s": how long, short. */
object FlightClock {
    fun duration(seconds: Double): String {
        val t = maxOf(0, seconds.toInt())
        if (t < 60) return "${t}s"
        val m = t / 60
        if (m < 60) return "${m}m"
        val h = m / 60
        val rest = m % 60
        if (h < 48) return if (rest == 0) "${h}h" else "${h}h ${rest}m"
        return "${h / 24}d"
    }

    /** "working 12m": this turn. null when the Mac did not say when it began (never a guess, never from the last step). */
    fun turn(since: Instant?, now: Instant): String? = since?.let { "working ${duration(now.secondsSince(it))}" }

    /** "session 2h 10m". */
    fun session(since: Instant?, now: Instant): String? = since?.let { "session ${duration(now.secondsSince(it))}" }

    /** "active 4m ago", "active just now": what an older Mac can say. */
    fun quiet(since: Instant?, now: Instant): String? {
        if (since == null) return null
        val s = maxOf(0.0, now.secondsSince(since)).toLong()
        return if (s < 5) "active just now" else "active ${RelativeTime.compact(s)} ago"
    }
}

/**
 * A tool one-liner in plain words: "[Bash] swift test" is "Running swift test",
 * "[Edit] Sources/a/SessionRoom.swift" is "Editing SessionRoom.swift". The Mac
 * writes `[Tool] text`; `Tool: text` reads the same. Words that are not a tool
 * call (the agent's last line) pass through.
 */
object StepPhrase {
    fun plain(raw: String, limit: Int = 90): String {
        val line = Sw.splitOmittingEmpty(raw, "\n").firstOrNull() ?: raw
        val text = Sw.trimWsNl(line)
        if (text.isEmpty()) return ""
        val (tool, rest) = split(text) ?: return clip(text, limit)
        return when (tool) {
            "Bash", "BashOutput" -> if (rest.isEmpty()) "Running a command" else clip("Running $rest", limit)
            "Edit", "MultiEdit", "NotebookEdit" -> if (rest.isEmpty()) "Editing a file" else clip("Editing ${leaf(rest)}", limit)
            "Write" -> if (rest.isEmpty()) "Writing a file" else clip("Writing ${leaf(rest)}", limit)
            "Read" -> if (rest.isEmpty()) "Reading a file" else clip("Reading ${leaf(rest)}", limit)
            "Grep", "Glob" -> if (rest.isEmpty()) "Searching the code" else clip("Searching $rest", limit)
            "WebFetch" -> if (rest.isEmpty()) "Fetching a page" else clip("Fetching $rest", limit)
            "WebSearch" -> if (rest.isEmpty()) "Searching the web" else clip("Searching the web for $rest", limit)
            "Task", "Agent" -> if (rest.isEmpty()) "Running a sub-agent" else clip("Sub-agent: $rest", limit)
            "TodoWrite" -> "Updating its to-do list"
            else -> if (rest.isEmpty()) "Using $tool" else clip("$tool: $rest", limit)
        }
    }

    private val known: Set<String> = setOf(
        "Bash", "BashOutput", "Edit", "MultiEdit", "NotebookEdit", "Write", "Read", "Grep", "Glob",
        "WebFetch", "WebSearch", "Task", "Agent", "TodoWrite",
    )

    /** ("Bash", "swift test") from "[Bash] swift test" or "Bash: swift test". */
    private fun split(text: String): Pair<String, String>? {
        if (Sw.hasPrefix(text, "[")) {
            val close = Sw.firstIndexOf(text, "]")
            if (close >= 0) {
                val tool = text.substring(1, close)
                if (tool.isEmpty() || Sw.count(tool) > 32 || tool.contains(" ")) return null
                return Pair(tool, Sw.trimWs(text.substring(close + 1)))
            }
        }
        val colon = Sw.firstIndexOf(text, ":")
        if (colon >= 0) {
            val tool = text.substring(0, colon)
            if (tool !in known) return null
            return Pair(tool, Sw.trimWs(text.substring(colon + 1)))
        }
        if (text in known) return Pair(text, "")
        return null
    }

    /** The file's own name: "a/b/SessionRoom.swift (2 edits)" is "SessionRoom.swift (2 edits)". */
    private fun leaf(path: String): String {
        val first = Sw.splitOmittingEmpty(path, " ").firstOrNull() ?: path
        if (!Sw.containsChar(first, "/")) return path
        val name = Sw.splitOmittingEmpty(first, "/").lastOrNull() ?: return path
        return name + Sw.dropFirst(path, Sw.count(first))
    }

    private fun clip(s: String, n: Int): String = SkyModel.clip(s, n)
}

// MARK: - Health

/** How a working session is going, in the card's four words. */
enum class FlightHealth {
    NORMAL, LONG_RUNNING, STUCK, RATE_LIMITED;

    val label: String?
        get() = when (this) {
            NORMAL -> null
            LONG_RUNNING -> "Long-running command"
            STUCK -> "Looks stuck"
            RATE_LIMITED -> "Rate limited"
        }

    val needsAttention: Boolean get() = this == STUCK || this == RATE_LIMITED

    companion object {
        /**
         * No new step for this long while "working": a long-running command. Only the phone's own guess for a
         * Mac that sends no working fields; a newer Mac says "longRunning" itself (after 3 minutes).
         */
        const val quietAfter: Double = 5 * 60.0

        /**
         * The Mac's word when it sent one, else what the phone can tell: an open stuck or looping page for this
         * session (as Lanes does), a rate limit. A Mac that sends working fields but no `health` says "normal" (it
         * leaves the word out then), so the phone does not guess a long silence over it; only a Mac that sends
         * nothing gets that guess. Pure.
         */
        fun classify(state: LiveSessionState, flight: SessionFlight?, hasStuckPage: Boolean, lastActivityAt: Instant?, now: Instant): FlightHealth {
            val raw = flight?.health
            val macs = raw?.let { from(it) }
            if (macs != null) {
                // A stuck page is a fact about the page: it still wins over a Mac that says "normal".
                return if (macs == NORMAL && hasStuckPage) STUCK else macs
            }
            if (hasStuckPage) return STUCK
            if (state == LiveSessionState.RATE_LIMITED) return RATE_LIMITED
            if (flight != null) return NORMAL
            if (lastActivityAt != null && now.secondsSince(lastActivityAt) >= quietAfter) return LONG_RUNNING
            return NORMAL
        }

        fun from(raw: String): FlightHealth? =
            when (Sw.chars(raw.lowercase()).filter { Sw.isLetter(it) }.joinToString("")) {
                "normal", "ok", "healthy", "fine" -> NORMAL
                "longrunning", "slow", "longcommand" -> LONG_RUNNING
                "stuck", "looksstuck", "looping", "loop", "stalled" -> STUCK
                "ratelimited", "ratelimit", "limited" -> RATE_LIMITED
                else -> null
            }

        /** Sessions with an open stuck or looping page (the same test Lanes uses). */
        fun stuckSessionIds(interventions: List<Intervention>): Set<String> =
            interventions.filter { it.kind == InterventionKind.IDLE && PageSubtype.isStuck(it.subtype) }.map { it.sessionId }.toSet()
    }
}

// MARK: - Card

/** One workflow line on a card: "Review changes · 3/5 agents". */
data class FlightWorkflowLine(
    val id: String,
    val name: String,
    val phase: String?,
    /** "3/5 agents"; null when the run has no total yet. */
    val progress: String?,
    /** 0..1 for the thin bar; null with no total. */
    val fraction: Double?,
) {
    val text: String get() = listOfNotNull(name, phase, progress).joinToString(" · ")
}

/** What a working session shows beyond its row: the step in words, the steps before it, the clocks, the workflows, the health. */
data class InFlightCard(
    /** "Running swift test". */
    val now: String,
    /** The 2 or 3 steps before it, newest first, in the same words. */
    val previous: List<String> = emptyList(),
    /** "working 12m": this turn; null from an older Mac. */
    val turn: String? = null,
    /** "session 2h 10m"; null from an older Mac. */
    val session: String? = null,
    /** "active 4m ago": what an older Mac can say, kept only when [turn] is missing. */
    val quiet: String? = null,
    val model: String? = null,
    val health: FlightHealth = FlightHealth.NORMAL,
    /** "Looks stuck · the same step 6 times": the Mac's note when it sent one. */
    val healthLine: String? = null,
    val workflows: List<FlightWorkflowLine> = emptyList(),
    /** How many workflows run in all; the list sends at most 3 lines of them. */
    val workflowTotal: Int = 0,
) {
    /** The time line's text: "working 12m · session 2h 10m" or "active 4m ago". */
    val timeText: String?
        get() {
            val parts = listOfNotNull(turn ?: quiet, session)
            return if (parts.isEmpty()) null else parts.joinToString(" · ")
        }

    /** "2 workflows running", "1 workflow running"; null with none. Counts what the Mac says run in all, not just the lines it sent. */
    val workflowHeading: String?
        get() {
            val n = maxOf(workflowTotal, workflows.size)
            return if (n == 0) null else "$n ${if (n == 1) "workflow" else "workflows"} running"
        }

    companion object {
        /** Earlier steps on a card: the same two as the Mac's. */
        const val earlierSteps = 2

        private val modelPattern = Rx.compile("""^(opus|sonnet|haiku) \d+(\.\d+)*( |$)""")

        /**
         * Pure. [runs] are the watched session's full workflow runs when the phone has them (richer than the
         * list's summaries, so they win).
         */
        fun build(session: LiveSession, runs: List<WorkflowRun> = emptyList(), hasStuckPage: Boolean = false, now: Instant, zone: ZoneId = ZoneId.systemDefault()): InFlightCard {
            val f = session.flight
            // The Mac's steps end with the current one, in its words: they are the whole story, so the card reads
            // the same here as on the Mac. An older Mac sends none, and the preview (a tool one-liner) is put into words here.
            var steps = (f?.recentSteps ?: emptyList()).map { StepPhrase.plain(it, 100) }.filter { it.isNotEmpty() }
            if (steps.isEmpty()) steps = listOf(StepPhrase.plain(session.preview)).filter { it.isNotEmpty() }
            val nowLine = steps.lastOrNull() ?: "Working"
            val previous = ArrayList<String>()
            for (p in steps.dropLast(1).reversed()) {
                if (p == nowLine || p in previous) continue
                previous.add(p)
                if (previous.size == earlierSteps) break
            }
            val health = FlightHealth.classify(session.state, f, hasStuckPage, session.lastActivityAt, now)
            val running = runs.filter { it.isRunning }
            val lines: List<FlightWorkflowLine> = if (running.isEmpty()) {
                (f?.workflows ?: emptyList()).filter { it.running }.mapIndexed { i, w -> line("$i-${w.name}", w.name, w.phase, w.done, w.total) }
            } else {
                running.map { r -> line(r.id, r.name, r.phase, r.done, r.total) }
            }
            val turn = FlightClock.turn(f?.busySince, now)
            val quietFor = (f?.stepSince ?: session.lastActivityAt)?.let { now.secondsSince(it) }
            return InFlightCard(
                now = nowLine, previous = previous, turn = turn, session = FlightClock.session(f?.startedAt, now),
                quiet = if (turn == null) FlightClock.quiet(session.lastActivityAt, now) else null,
                model = f?.model?.let { modelName(it) }, health = health,
                healthLine = healthLine(health, f?.healthNote, quietFor, f?.resetsAt, now, f?.stepSince != null, zone),
                workflows = lines, workflowTotal = if (running.isEmpty()) (f?.workflowsRunning ?: 0) else 0,
            )
        }

        private fun line(id: String, name: String, phase: String?, done: Int, total: Int): FlightWorkflowLine =
            FlightWorkflowLine(
                id, name, phase, if (total > 0) "${minOf(done, total)}/$total agents" else null,
                if (total > 0) minOf(1.0, done.toDouble() / total) else null,
            )

        /**
         * "Looks stuck · no progress for 15 min", "Rate limited · resets 03:00", "Long-running command · no new
         * step for 4m". [explicitQuiet]: the quiet time is the Mac's own (`stepSince`), so a minute is enough to
         * name; the phone's guess from `lastActivityAt` waits for the long silence.
         */
        fun healthLine(
            h: FlightHealth, note: String?, quietFor: Double?, resetsAt: Instant? = null, now: Instant = Instant.now(),
            explicitQuiet: Boolean = false, zone: ZoneId = ZoneId.systemDefault(),
        ): String? {
            val label = h.label ?: return null
            if (!note.isNullOrEmpty()) return "$label · $note"
            if (h == FlightHealth.RATE_LIMITED && resetsAt != null && resetsAt > now) return "$label · resets ${NowFormat.clock(resetsAt, zone = zone)}"
            if (h == FlightHealth.LONG_RUNNING && quietFor != null && quietFor >= (if (explicitQuiet) 60.0 else FlightHealth.quietAfter)) {
                return "$label · no new step for ${FlightClock.duration(quietFor)}"
            }
            return label
        }

        /**
         * "claude-opus-4-5-20251101" is "Opus 4.5"; a name that already reads "Opus 4.7" (what the Mac sends) and
         * anything unfamiliar are shown as sent.
         */
        fun modelName(raw: String): String {
            val lower = raw.lowercase()
            if (modelPattern.matcher(lower).find()) return raw
            for (family in listOf("opus", "sonnet", "haiku")) {
                if (!lower.contains(family)) continue
                val digits = lower.split('-', '_', ' ').mapNotNull { it.toIntOrNull() }.filter { it < 100 }
                val version = digits.take(2).joinToString(".")
                return family.replaceFirstChar { it.uppercase() } + (if (version.isEmpty()) "" else " $version")
            }
            return raw
        }
    }
}

// MARK: - Project label

/**
 * The project a session goes by. A cwd of "/" (or an empty or slash-only name) is never shown as "/": it falls
 * back to the session's own name, then "root" (the Mac's word). The home folder reads "~" whatever the session is
 * called, as on the Mac.
 */
object ProjectLabel {
    private val homePattern = Rx.compile("""^/(Users|home)/[^/]+/?$""")

    fun isBare(s: String): Boolean = Sw.trimIn(s, "/ \t\n").isEmpty()

    fun isHome(cwd: String): Boolean {
        val t = Sw.trimWs(cwd)
        if (t == "~" || t == "~/") return true
        return homePattern.matcher(t).find()
    }

    /** "~" for the home folder; else the folder's own name; else the session's name; else "root" for the root folder ("Unknown project" with no cwd at all). */
    fun name(cwd: String, fallback: String): String {
        val trimmed = Sw.trimWs(cwd)
        val path = if (Sw.hasSuffix(trimmed, "/") && Sw.count(trimmed) > 1) Sw.dropLast(trimmed) else trimmed
        if (isHome(path)) return "~"
        val last = Sw.splitOmittingEmpty(path, "/").lastOrNull()
        if (last != null && last != "~") return last
        val fb = Sw.trimWsNl(fallback)
        if (!isBare(fb)) return fb
        return if (trimmed.isEmpty()) "Unknown project" else "root"
    }

    /** A name the Mac sent, fixed up when it is "/" or empty. */
    fun clean(given: String, cwd: String, fallback: String = ""): String {
        val g = Sw.trimWsNl(given)
        return if (isBare(g)) name(cwd, fallback) else g
    }
}

// MARK: - Header jump

/** "2 working" in the Horizon's subline goes to the In flight cards. */
object HeaderJump {
    const val sectionId = "section-in flight"
    const val accessibilityName = "Show what is working"

    /** The scroll target, or null when there is nothing to jump to (no working session on screen). */
    fun target(working: Int, inFlightShown: Int): String? = if (working > 0 && inFlightShown > 0) sectionId else null

    /** "2 working · 16:12 runway" split after the count: the part that jumps and the rest. null when the subline does not start with the count. */
    fun split(subline: String, working: Int): Pair<String, String>? {
        val head = "$working working"
        if (working <= 0 || !Sw.hasPrefix(subline, head)) return null
        return Pair(head, subline.substring(head.length))
    }
}
