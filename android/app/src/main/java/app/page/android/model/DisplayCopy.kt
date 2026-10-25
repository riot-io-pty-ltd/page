package app.page.android.model

import java.time.Instant

// Pure display decisions shared by the services and screens (the Kotlin side
// of iOS PageLogic.swift's display helpers).

object RelativeTime {
    /**
     * "Paged just now", "Paged 12s ago", "Paged 4m ago". Clamped so a Mac
     * clock slightly ahead of the phone never yields "-3s ago".
     */
    fun string(prefix: String, since: Instant, now: Instant): String = "$prefix ${ago(since, now)}"

    fun ago(since: Instant, now: Instant): String {
        val s = maxOf(0L, now.secondsSince(since).toLong())
        if (s < 5) return "just now"
        return "${compact(s)} ago"
    }

    fun compact(seconds: Long): String {
        val s = maxOf(0L, seconds)
        return when {
            s < 60 -> "${s}s"
            s < 3600 -> "${s / 60}m"
            s < 86_400 -> "${s / 3600}h"
            else -> "${s / 86_400}d"
        }
    }
}

object PathDisplay {
    /**
     * `/Users/roy/projects/x` -> `~/projects/x`. The Mac's home directory is
     * unknown on the phone, so match the conventional macOS/Linux home
     * prefixes instead.
     */
    fun abbreviatingHome(path: String): String {
        for (prefix in listOf("/Users/", "/home/")) {
            if (!path.startsWith(prefix)) continue
            val rest = path.substring(prefix.length)
            val slash = rest.indexOf('/')
            if (slash < 0) return "~"
            return "~" + rest.substring(slash)
        }
        return path
    }
}

object CloseReason {
    /**
     * Close reasons the Worker archives but hides from GET /history
     * (bookkeeping, not resolutions), plus `stale`, which it never archives,
     * and `token_retired`, whose pairing (and history) is gone anyway.
     */
    val hiddenFromHistory: Set<String> = setOf("stale", "superseded", "evicted", "token_retired")

    /** Close reasons the Worker archives to history that Page knows by name. */
    val historyWorthy: Set<String> = setOf(
        "replied", "session_resolved", "user_resolved_in_terminal", "timeout",
        "hook_lost", "expired", "agent_exited", "too_late",
        "hook_exited", "hook_fallback", "user_returned", "resolved_elsewhere", "not_a_decision",
    )

    /**
     * Mirrors the Worker: anything it doesn't hide shows up in history, so a
     * close reason added later still lands there without an app update.
     */
    fun isHistoryWorthy(reason: String): Boolean = reason.isNotEmpty() && reason !in hiddenFromHistory

    /** Reads on its own (History) and after "Resolved — " (reply screen). */
    fun description(reason: String?): String = when (reason) {
        "replied" -> "Answered from Page"
        "user_resolved_in_terminal" -> "Answered in the terminal"
        "superseded" -> "Replaced by a newer page from this session"
        "evicted" -> "Removed to make room for newer pages"
        "timeout" -> "Timed out"
        "stale" -> "The session is no longer waiting"
        "session_resolved" -> "Resolved on your Mac"
        "hook_lost" -> "Lost contact with the hook on your Mac, so the prompt went back to the terminal"
        "expired" -> "Expired after a day without an answer"
        "agent_exited" -> "The agent exited before your answer could be applied"
        "too_late" -> "Your reply arrived too late to apply, so the prompt went back to the terminal"
        "token_retired" -> "This pairing was replaced on your Mac"
        "hook_exited" -> "The hook on your Mac stopped waiting"
        "hook_fallback" -> "Handed back to the terminal on your Mac"
        "user_returned" -> "You came back to your Mac, so it's waiting there"
        "resolved_elsewhere" -> "Answered somewhere else"
        "not_a_decision" -> "That reply wasn't an approve or deny, so the prompt went back to the terminal"
        else -> "Resolved on your Mac"
    }
}

object ReplyCopy {
    fun headline(iv: Intervention): String = when (iv.kind) {
        InterventionKind.APPROVAL -> {
            if (iv.subtype == "plan") {
                "Approve the plan?"
            } else {
                val c = iv.context.lowercase()
                when {
                    "bash" in c || "command" in c || "shell" in c -> "Run this command?"
                    "edit" in c || "write" in c || "file" in c -> "Allow this change?"
                    else -> "Allow this action?"
                }
            }
        }
        InterventionKind.USER_INPUT -> "${iv.agentName} needs your input"
        InterventionKind.IDLE -> "${iv.agentName} is waiting for you"
        InterventionKind.RATE_LIMIT -> "Rate limit reached"
    }

    fun actionLabel(action: String?): String? = when (action) {
        "approve" -> "Approved"
        "deny" -> "Denied"
        "carry_on" -> "Carry on"
        else -> null
    }
}

/**
 * The Mac regenerated its pairing token and retired the old one. The relay
 * then answers every request on the old token with
 * `410 {error:"token_retired", why}` and sends `relay.retired` to phone
 * sockets. Either means this pairing is dead for good: re-pair.
 */
object TokenRetirement {
    const val DEFAULT_WHY = "This pairing was replaced on your Mac — scan the new QR code"
    const val MAX_WHY_LENGTH = 300

    /**
     * The relay closes every socket of a retired token with this code (4410
     * mirrors HTTP 410) and reason "token_retired", right after the
     * `relay.retired` frame.
     */
    const val SOCKET_CLOSE_CODE = 4410

    /**
     * The why text when this HTTP response says the token was retired. Only
     * a 410 whose body says `token_retired` counts: a plain 410
     * (`{error:"gone"}` from /reply) is a closed page, not a dead pairing.
     */
    fun why(status: Int, body: String): String? {
        if (status != 410) return null
        val json = parseJsonObject(body) ?: return null
        if (json.str("error") != "token_retired") return null
        return cleaned(json.str("why")) ?: DEFAULT_WHY
    }

    /** The why text when a socket frame announces the retirement. */
    fun whyFromFrame(frameType: String, payload: kotlinx.serialization.json.JsonObject): String? {
        if (frameType != "relay.retired") return null
        return cleaned(payload.str("why")) ?: DEFAULT_WHY
    }

    /**
     * A WebSocket upgrade refused with this status. The upgrade's body isn't
     * trusted, so these are confirmed with a REST call (which classifies
     * 401/403 and `token_retired`).
     */
    fun handshakeNeedsCheck(status: Int): Boolean = status == 401 || status == 403 || status == 410

    /** `why` ending in sentence punctuation, for copy that continues after it. */
    fun sentence(why: String): String {
        val last = why.lastOrNull() ?: return why
        return if (last in ".!?…") why else "$why."
    }

    /** A socket close that may mean retirement; confirmed over REST. */
    fun socketCloseNeedsCheck(code: Int, reason: String?): Boolean {
        if (code == SOCKET_CLOSE_CODE) return true
        return reason?.trim() == "token_retired"
    }

    private fun cleaned(raw: String?): String? {
        val t = raw?.trim() ?: return null
        if (t.isEmpty()) return null
        return if (t.length > MAX_WHY_LENGTH) t.capped(MAX_WHY_LENGTH) + "…" else t
    }
}

object DeepLink {
    /** `page://intervention/<id>` -> id. */
    fun interventionId(url: String): String? {
        val uri = try { java.net.URI(url) } catch (_: Exception) { return null }
        if (uri.scheme?.lowercase() != "page" || uri.host?.lowercase() != "intervention") return null
        val id = (uri.path ?: "").split('/').firstOrNull { it.isNotEmpty() }?.trim() ?: return null
        if (id.isEmpty() || id.length > 200) return null
        return id
    }
}

object ReconnectBackoff {
    /**
     * Exponential (1, 2, 4 … capped at 30 s) with "equal jitter" so a fleet
     * of phones doesn't reconnect in lockstep after a Worker deploy.
     * [jitter] is a random value in 0..1.
     */
    fun delaySeconds(attempt: Int, jitter: Double): Double {
        val base = minOf(30.0, Math.pow(2.0, maxOf(0, minOf(attempt, 10)).toDouble()))
        val j = jitter.coerceIn(0.0, 1.0)
        return maxOf(0.5, base / 2 + (base / 2) * j)
    }
}
