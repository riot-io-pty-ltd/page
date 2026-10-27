package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/**
 * New vocab (approval / user_input / idle / rate_limit) is the canonical
 * set. Legacy Claude vocab (permission / plan / question) is decoded into
 * the canonical set so pages from older Macs and hooks still render.
 */
enum class InterventionKind(val wire: String) {
    APPROVAL("approval"),
    USER_INPUT("user_input"),
    IDLE("idle"),
    RATE_LIMIT("rate_limit");

    val label: String
        get() = when (this) {
            APPROVAL -> "APPROVAL"
            USER_INPUT -> "QUESTION"
            IDLE -> "IDLE"
            RATE_LIMIT -> "RATE LIMIT"
        }

    /** Spoken name for TalkBack ("Approval request", not "APPROVAL"). */
    val accessibilityName: String
        get() = when (this) {
            APPROVAL -> "Approval request"
            USER_INPUT -> "Question"
            IDLE -> "Idle session"
            RATE_LIMIT -> "Rate limit"
        }

    /**
     * Inbox ordering: things that block an agent on a yes/no come first,
     * then questions, then idle sessions, then informational pages.
     */
    val urgencyRank: Int get() = ordinal

    companion object {
        /**
         * Maps any wire value to a kind. Unknown values become USER_INPUT,
         * matching the Worker's own coercion ("unknown kind -> question"): a
         * text-only reply screen is the safe default because it never offers
         * Approve/Deny for something we don't understand.
         */
        fun fromWire(raw: String?): InterventionKind = when (raw) {
            "approval", "permission", "plan" -> APPROVAL
            "idle" -> IDLE
            "rate_limit" -> RATE_LIMIT
            else -> USER_INPUT
        }
    }
}

enum class InterventionBackend(val wire: String) {
    CLAUDE("claude"),
    CODEX("codex");

    val badge: String get() = if (this == CLAUDE) "CLAUDE" else "CODEX"
    val displayName: String get() = if (this == CLAUDE) "Claude" else "Codex"

    companion object {
        fun fromWire(raw: String?): InterventionBackend? = entries.firstOrNull { it.wire == raw }
    }
}

enum class InterventionSource(val wire: String) {
    TERMINAL("terminal"), DESKTOP("desktop"), VSCODE("vscode"), EXEC("exec"), REMOTE("remote"), UNKNOWN("unknown");

    /**
     * Always a human label: "Terminal" reads as fast as "VS Code" and the
     * user wants to tell every surface apart at a glance.
     */
    val label: String
        get() = when (this) {
            TERMINAL -> "Terminal"
            DESKTOP -> "Desktop"
            VSCODE -> "VS Code"
            EXEC -> "Exec"
            REMOTE -> "Remote"
            UNKNOWN -> "Unknown"
        }

    companion object {
        fun fromWire(raw: String): InterventionSource = entries.firstOrNull { it.wire == raw } ?: UNKNOWN
    }
}

/** One moment where an agent needs a human: a "page". */
data class Intervention(
    val id: String,
    val sessionId: String,
    val cwd: String,
    val projectName: String,
    val kind: InterventionKind,
    val openedAt: Instant,
    val context: String,
    val closedAt: Instant? = null,
    val closeReason: String? = null,
    val repliedAt: Instant? = null,
    val repliedText: String? = null,
    val repliedAction: String? = null,
    /** The Worker fills in "claude" if an older Mac didn't send one. */
    val backend: InterventionBackend? = null,
    /**
     * The `backend` string as the relay sent it, kept so an agent Page does not know (a value [backend] could
     * not decode) is not mistaken for Claude. Decode-only; the wire is unchanged.
     */
    val backendRaw: String? = null,
    val source: InterventionSource? = null,
    val subtype: String? = null,
    /** v2 (Worker-managed): "pending" | "delivered" | "failed". */
    val deliveryStatus: String? = null,
    /** v2: short human-readable delivery result from the Mac. */
    val deliveryDetail: String? = null,
    val deliveryMethod: String? = null,
    /**
     * Worker-managed: a page from a v1 blocking hook (`hook-` id). The hook
     * polls for the answer itself and can only apply Approve or Deny.
     */
    val hookBlocking: Boolean? = null,
) {
    /** Hook-owned pages: the hook polls for the answer itself, the Mac never types anything for these. */
    val isBlockingHook: Boolean get() = id.startsWith("hookpre-") || hookBlocking == true

    /**
     * Only Approve/Deny can be applied (the relay answers anything else
     * with 422 `approve_or_deny_only`), so don't offer a text reply.
     */
    val acceptsDecisionsOnly: Boolean
        get() = hookBlocking == true && !id.startsWith("hookpre-") && kind == InterventionKind.APPROVAL

    /** Name of the agent for copy ("Claude needs your input"). */
    val agentName: String get() = backend?.displayName ?: "Your agent"

    /**
     * The relay named an agent Page has no adapter for. A page with no backend at all is an older Mac's Claude
     * page, not this.
     */
    val hasUnknownBackend: Boolean get() = backend == null && Sw.trimWs(backendRaw ?: "").isNotEmpty()

    /** Time from page to the user's reply. Null when the user never replied. */
    val responseTimeSeconds: Long?
        get() = repliedAt?.let { maxOf(0L, (it.secondsSince(openedAt)).toLong()) }

    companion object {
        /**
         * Lenient by design: only `id`, `sessionId` and `openedAt` are
         * required. Everything else is optional or defaulted, and a malformed
         * optional field is treated as missing instead of failing the whole
         * page — one odd hook payload must never blank the inbox.
         */
        fun decode(element: JsonElement): Intervention? {
            val o = element as? JsonObject ?: return null
            val id = o.str("id") ?: return null
            val sessionId = o.str("sessionId") ?: return null
            val openedAt = PageDate.parseAny(o["openedAt"]) ?: return null
            val cwd = o.str("cwd") ?: ""
            val project = o.str("projectName") ?: ""
            return Intervention(
                id = id,
                sessionId = sessionId,
                cwd = cwd,
                projectName = ProjectLabel.clean(project, cwd),
                kind = InterventionKind.fromWire(o.str("kind")),
                openedAt = openedAt,
                context = o.str("context") ?: "",
                closedAt = PageDate.parseAny(o["closedAt"]),
                closeReason = o.str("closeReason"),
                repliedAt = PageDate.parseAny(o["repliedAt"]),
                repliedText = o.str("repliedText"),
                repliedAction = o.str("repliedAction"),
                backend = InterventionBackend.fromWire(o.str("backend")),
                backendRaw = o.str("backend"),
                source = o.str("source")?.let(InterventionSource::fromWire),
                subtype = o.str("subtype"),
                deliveryStatus = o.str("deliveryStatus"),
                deliveryDetail = o.str("deliveryDetail"),
                deliveryMethod = o.str("deliveryMethod"),
                hookBlocking = o.bool("hookBlocking"),
            )
        }

        /** A GET /interventions or /history body. Null when it isn't a JSON array. */
        fun decodeList(body: String): LossyList<Intervention>? = lossyList(parseJson(body), ::decode)

        /**
         * Approvals first, then questions, then idle, then informational;
         * newest first within a kind. The single ordering used everywhere
         * (refresh, socket insert) so the list never reshuffles depending on
         * the source.
         */
        fun urgencySorted(list: List<Intervention>): List<Intervention> = list.sortedWith(
            compareBy<Intervention> { it.kind.urgencyRank }
                .thenByDescending { it.openedAt }
                .thenBy { it.id }
        )
    }
}

/**
 * What we persist about the paired Mac. Unknown keys are ignored when it's
 * read back, so any new field must stay optional.
 */
data class PairedMac(val name: String, val pairedAt: Instant? = null)
