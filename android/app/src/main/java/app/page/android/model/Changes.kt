package app.page.android.model

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

// v4 "what changed": the one-line summary on an idle page, and the `diff`
// kind the Mac sends over the encrypted sessions channel (SESSIONS-PROTOCOL.md
// §4). Pure.

/**
 * An idle page may start with a summary line ("Changed 3 files (+120 −14) ·
 * tests passed") and a blank line before the agent's message. The page
 * context carries counts only, never file names or code.
 */
object TurnSummaryLine {
    data class Split(val summary: String?, val message: String)

    fun split(kind: InterventionKind, context: String): Split {
        if (kind != InterventionKind.IDLE) return Split(null, context)
        // The Mac always writes the summary, a blank line, then the message.
        val cut = context.indexOf("\n\n")
        if (cut <= 0) return Split(null, context)
        val first = context.substring(0, cut)
        if (first.contains('\n') || first.length > 120 || !SUMMARY.matches(first.trim())) return Split(null, context)
        return Split(first.trim(), context.substring(cut + 2).trimStart('\n'))
    }

    /** "Changed 3 files (+120 −14) · tests passed", "Changed 1 file", "tests failed". */
    private val SUMMARY = Regex("^(Changed \\d+ files?( \\(\\+\\d+ [−-]\\d+\\))?( · tests (passed|failed))?|tests (passed|failed))$")
}

data class DiffFile(val path: String, val added: Int?, val removed: Int?, val status: String) {
    companion object {
        fun decode(element: JsonElement): DiffFile? {
            val o = element as? JsonObject ?: return null
            val path = o.str("path")?.takeIf { it.isNotEmpty() }?.capped(500) ?: return null
            return DiffFile(
                path = path,
                added = o.int("added")?.takeIf { it >= 0 },
                removed = o.int("removed")?.takeIf { it >= 0 },
                status = (o.str("status") ?: "changed").capped(20),
            )
        }
    }
}

/** The answer to a `diff` op: what the turn (or the working tree) changed. */
data class SessionDiff(
    val sessionId: String,
    val clientId: String?,
    /** `turn` or `uncommitted`; anything newer is shown as is. */
    val scope: String,
    val repo: String?,
    val files: List<DiffFile>,
    val patch: String,
    val truncated: Boolean,
    val note: String?,
) {
    val scopeLabel: String
        get() = when (scope) {
            "turn" -> "This turn"
            "uncommitted" -> "Uncommitted changes"
            else -> scope.replaceFirstChar { it.uppercase() }
        }

    /** Totals over files whose counts are known; null when none are. */
    val added: Int? get() = files.mapNotNull { it.added }.takeIf { it.isNotEmpty() }?.sum()
    val removed: Int? get() = files.mapNotNull { it.removed }.takeIf { it.isNotEmpty() }?.sum()

    companion object {
        const val MAX_PATCH_CHARS = 64 * 1024
    }
}

/** A unified diff split into per-file sections, each line classified for colouring. */
object PatchParser {
    enum class LineKind { FILE_HEADER, META, HUNK, ADDED, REMOVED, CONTEXT }

    data class Line(val text: String, val kind: LineKind)

    data class Section(val path: String, val lines: List<Line>)

    fun sections(patch: String): List<Section> {
        if (patch.isEmpty()) return emptyList()
        val out = mutableListOf<Section>()
        var path: String? = null
        var lines = mutableListOf<Line>()
        var inHunk = false
        fun flush() {
            if (lines.isNotEmpty()) out.add(Section(path ?: "", lines))
            lines = mutableListOf()
        }
        for (raw in patch.split('\n')) {
            if (raw.startsWith("diff --git ")) {
                flush()
                path = pathOf(raw)
                inHunk = false
                lines.add(Line(raw, LineKind.FILE_HEADER))
                continue
            }
            val kind = when {
                raw.startsWith("@@") -> { inHunk = true; LineKind.HUNK }
                !inHunk -> LineKind.META
                raw.startsWith("+") -> LineKind.ADDED
                raw.startsWith("-") -> LineKind.REMOVED
                else -> LineKind.CONTEXT
            }
            lines.add(Line(raw, kind))
        }
        flush()
        // Drop a trailing empty context line from the patch's final newline.
        return out.map { s -> if (s.lines.lastOrNull()?.text == "") s.copy(lines = s.lines.dropLast(1)) else s }
    }

    /** `diff --git a/x/y.kt b/x/y.kt` -> `x/y.kt`. */
    private fun pathOf(header: String): String {
        val rest = header.removePrefix("diff --git ")
        val b = rest.lastIndexOf(" b/")
        if (b >= 0) return rest.substring(b + 3)
        return rest.removePrefix("a/")
    }
}

/** One folder a new session may be started in (the `folders` kind). */
data class StartFolder(val path: String, val name: String, val lastUsedAt: java.time.Instant?) {
    companion object {
        fun decode(element: JsonElement): StartFolder? {
            val o = element as? JsonObject ?: return null
            val path = o.str("path")?.takeIf { it.isNotEmpty() }?.capped(500) ?: return null
            val name = o.str("name")?.takeIf { it.isNotEmpty() } ?: path.split('/').lastOrNull { it.isNotEmpty() } ?: path
            return StartFolder(path, name.capped(120), o.num("lastUsedAt")?.takeIf { it > 0 }?.let(PageDate::ofEpochMillis))
        }
    }
}

/** The answer to a `folders` op. */
data class StartFolders(val clientId: String?, val enabled: Boolean, val agents: List<String>, val folders: List<StartFolder>) {
    companion object {
        const val MAX_FOLDERS = 40

        /** Newest first, as the protocol promises, whatever order arrived. */
        fun sorted(folders: List<StartFolder>): List<StartFolder> =
            folders.sortedByDescending { it.lastUsedAt ?: java.time.Instant.MIN }.take(MAX_FOLDERS)
    }
}

/** What the "New session" prompt accepts: 0–4000 characters (it may be empty). */
object StartPrompt {
    const val MAX_CHARACTERS = 4000

    fun problem(text: String): String? {
        val n = text.trim().graphemeCount()
        return if (n > MAX_CHARACTERS) "That's $n characters. Keep the prompt to $MAX_CHARACTERS or fewer." else null
    }
}
