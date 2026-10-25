package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

enum class TranscriptRole(val wire: String) {
    USER("user"), ASSISTANT("assistant"), TOOL("tool"), SYSTEM("system");

    companion object {
        /** Unknown roles render as a neutral system marker, never as the user. */
        fun fromWire(raw: String?): TranscriptRole = entries.firstOrNull { it.wire == raw } ?: SYSTEM
    }
}

data class TranscriptEntry(
    val id: String,
    val role: TranscriptRole,
    val text: String,
    val at: Instant?,
    /** Tool name for `tool` rows ("Bash"). */
    val tool: String?,
) {
    companion object {
        fun decode(element: JsonElement): TranscriptEntry? {
            val c = element as? JsonObject ?: return null
            // Offsets may arrive as numbers; either way it must be stable.
            val id = c.str("id")?.takeIf { it.isNotEmpty() }?.capped(200)
                ?: c.long("id")?.toString()
                ?: return null
            return TranscriptEntry(
                id = id,
                role = TranscriptRole.fromWire(c.str("role")),
                text = (c.str("text") ?: "").capped(2400),
                at = PageDate.parseAny(c["at"]),
                tool = c.str("tool")?.takeIf { it.isNotEmpty() }?.capped(40),
            )
        }
    }
}

data class SessionTranscript(
    val sessionId: String,
    val entries: List<TranscriptEntry>,
    /** Older entries were dropped to fit the snapshot. */
    val truncated: Boolean,
    /** Set for a workflow agent's transcript (inside the session). */
    val runId: String? = null,
    val agentId: String? = null,
) {
    /** Where the store keeps it: the session, or one of its agents. */
    val key: String get() = key(sessionId, runId, agentId)

    companion object {
        fun key(sessionId: String, runId: String?, agentId: String?): String =
            if (runId == null || agentId == null) sessionId else "$sessionId|$runId|$agentId"
    }
}

/**
 * The bottom of a session's terminal (the Mac's `screen` kind): Claude
 * Code's footer — background workflows, shells, sub-agents — and whatever
 * else is on screen. Plain text, redacted on the Mac.
 */
data class SessionScreen(
    val sessionId: String,
    val lines: List<String>,
    /** Mac clock. */
    val at: Instant,
) {
    companion object {
        const val MAX_LINES = 80
        const val MAX_LINE_CHARS = 300

        /** A row of only box-drawing / dash characters (and spaces): never wrapped. */
        fun isRule(line: String): Boolean {
            val trimmed = line.trim()
            return trimmed.length >= 8 && trimmed.all { it.code in 0x2500..0x257F || it == '-' || it == '=' || it == '_' }
        }

        /** "live", "12s ago", "3m ago". */
        fun age(at: Instant, now: Instant): String {
            val s = maxOf(0L, now.secondsSince(at).toLong())
            return when {
                s < 10 -> "live"
                s < 60 -> "${s}s ago"
                else -> "${s / 60}m ago"
            }
        }
    }
}
