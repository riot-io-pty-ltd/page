package app.page.android.model

import java.time.Instant
import java.util.Locale
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * One dynamic workflow a session launched (the Mac's `workflows` kind), as
 * Claude Code's footer shows it: name, progress, phase, agents.
 */
data class WorkflowRun(
    val id: String,
    val name: String,
    val summary: String? = null,
    /** running, completed, failed, killed, stalled (anything else shown as is). */
    val status: String,
    val phase: String? = null,
    val done: Int,
    val total: Int,
    val startedAt: Instant? = null,
    val endedAt: Instant? = null,
    val tokens: Long? = null,
    val agents: List<Agent> = emptyList(),
) {
    data class Agent(
        val id: String,
        val label: String,
        val phase: String?,
        /**
         * running, done, failed, stopped (its run ended first), or a newer
         * value shown as not running.
         */
        val state: String,
        val lastActivityAt: Instant?,
    ) {
        val running: Boolean get() = state == "running"

        companion object {
            fun decode(element: JsonElement): Agent? {
                val c = element as? JsonObject ?: return null
                val id = c.str("id")?.takeIf { it.isNotEmpty() } ?: return null
                return Agent(
                    id = id.capped(64),
                    label = (c.str("label") ?: "agent").capped(160),
                    phase = c.str("phase")?.takeIf { it.isNotEmpty() }?.capped(60),
                    state = (c.str("state") ?: "done").capped(20),
                    lastActivityAt = millisDate(c, "lastActivityAt"),
                )
            }
        }
    }

    val isRunning: Boolean get() = status == "running"

    /** "28/30 · 2h34m", like the footer. */
    fun progress(now: Instant): String {
        val parts = mutableListOf("$done/$total")
        startedAt?.let { parts.add(duration((endedAt ?: now).secondsSince(it))) }
        tokens?.let { parts.add(tokens(it)) }
        return parts.joinToString(" · ")
    }

    val statusLabel: String
        get() = when (status) {
            "running" -> "Running"
            "completed" -> "Done"
            "failed" -> "Failed"
            "killed" -> "Stopped"
            "stalled" -> "No recent activity"
            else -> status.split(' ').joinToString(" ") { w ->
                w.lowercase().replaceFirstChar { it.titlecase(Locale.ROOT) }
            }
        }

    companion object {
        fun duration(seconds: Double): String {
            val s = seconds.toLong()
            val m = maxOf(0L, s / 60)
            return when {
                m < 1 -> "${maxOf(0L, s)}s"
                m < 60 -> "${m}m"
                else -> "${m / 60}h${String.format(Locale.US, "%02d", m % 60)}m"
            }
        }

        fun tokens(n: Long): String = when {
            n >= 1_000_000 -> String.format(Locale.US, "%.1fm tokens", n / 1e6)
            n >= 1000 -> String.format(Locale.US, "%.1fk tokens", n / 1e3)
            else -> "$n tokens"
        }

        fun decode(element: JsonElement): WorkflowRun? {
            val c = element as? JsonObject ?: return null
            val id = c.str("id")?.takeIf { it.isNotEmpty() } ?: return null
            return WorkflowRun(
                id = id.capped(64),
                name = (c.str("name") ?: id).capped(80),
                summary = c.str("summary")?.takeIf { it.isNotEmpty() }?.capped(300),
                status = (c.str("status") ?: "running").capped(20),
                phase = c.str("phase")?.takeIf { it.isNotEmpty() }?.capped(60),
                done = maxOf(0, c.int("done") ?: 0),
                total = maxOf(0, c.int("total") ?: 0),
                startedAt = millisDate(c, "startedAt"),
                endedAt = millisDate(c, "endedAt"),
                tokens = c.long("tokens"),
                agents = (lossyList(c["agents"], Agent::decode)?.elements ?: emptyList()).take(100),
            )
        }

        internal fun millisDate(c: JsonObject, key: String): Instant? {
            val ms = c.num(key) ?: return null
            if (ms <= 0) return null
            return PageDate.ofEpochMillis(ms)
        }
    }
}

/**
 * Which terminal rows name one of the session's workflows, so tapping the
 * footer's "○ design-pass-ch1-8-opus" row opens that run. Rows are matched
 * to running runs first, in screen order, so two runs with the same name map
 * to two rows. Pure.
 */
object TerminalRunLinks {
    fun match(lines: List<String>, runs: List<WorkflowRun>): Map<Int, WorkflowRun> {
        if (runs.isEmpty()) return emptyMap()
        val pool = runs.filter { it.isRunning } + runs.filter { !it.isRunning }
        val left = pool.groupingBy { it.name }.eachCount().toMutableMap()
        val namesLongestFirst = left.keys.sortedByDescending { it.length }
        // Bottom up: the footer is at the bottom, so it claims rows before any
        // conversation line above that happens to mention a name.
        val claimed = mutableMapOf<String, MutableList<Int>>()
        for (i in lines.indices.reversed()) {
            val trimmed = lines[i].trim()
            // Footer rows start with a status glyph and then the name.
            val first = trimmed.codePointAtOrNull(0) ?: continue
            if (isAlphanumeric(first)) continue
            val body = trimmed.dropWhile { !Character.isLetter(it) && !isNumber(it) }
            // Longest name first, so "a-b" isn't taken by a run named "a".
            val name = namesLongestFirst.firstOrNull { name ->
                (left[name] ?: 0) > 0 && body.startsWith(name) && (body.length == name.length || body[name.length] == ' ')
            } ?: continue
            left[name] = (left[name] ?: 0) - 1
            claimed.getOrPut(name) { mutableListOf() }.add(i)
        }
        // Runs sharing a name go to their rows top to bottom, in list order.
        val out = mutableMapOf<Int, WorkflowRun>()
        for ((name, rows) in claimed) {
            rows.sorted().zip(pool.filter { it.name == name }).forEach { (row, run) -> out[row] = run }
        }
        return out
    }

    private fun String.codePointAtOrNull(index: Int): Int? = if (index < length) codePointAt(index) else null

    private fun isAlphanumeric(cp: Int): Boolean {
        if (Character.isLetterOrDigit(cp)) return true
        return when (Character.getType(cp)) {
            Character.NON_SPACING_MARK.toInt(), Character.ENCLOSING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(),
            Character.LETTER_NUMBER.toInt(), Character.OTHER_NUMBER.toInt() -> true
            else -> false
        }
    }

    private fun isNumber(c: Char): Boolean = when (Character.getType(c)) {
        Character.DECIMAL_DIGIT_NUMBER.toInt(), Character.LETTER_NUMBER.toInt(), Character.OTHER_NUMBER.toInt() -> true
        else -> false
    }
}
