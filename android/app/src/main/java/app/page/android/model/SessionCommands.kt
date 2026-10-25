package app.page.android.model

import java.time.Instant
import java.util.TreeMap
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Phone → Mac plaintext ops (§5). */
sealed interface SessionCommand {
    data class Watch(val sessionId: String?) : SessionCommand
    data object Refresh : SessionCommand
    data class Input(val sessionId: String, val text: String) : SessionCommand
    data class Interrupt(val sessionId: String) : SessionCommand

    /** Watch a workflow agent inside the session (its transcript). */
    data class WatchAgent(val sessionId: String, val runId: String, val agentId: String) : SessionCommand

    val op: String
        get() = when (this) {
            is Watch, is WatchAgent -> "watch"
            Refresh -> "refresh"
            is Input -> "input"
            is Interrupt -> "interrupt"
        }

    /** The plaintext JSON. Keys are sorted so the bytes are deterministic. */
    fun plaintext(clientId: String, viewer: String, now: Instant): ByteArray {
        val body = TreeMap<String, JsonElement>()
        body["op"] = JsonPrimitive(op)
        body["clientId"] = JsonPrimitive(clientId)
        body["ts"] = JsonPrimitive(now.toEpochMilli())
        body["viewer"] = JsonPrimitive(viewer)
        when (this) {
            is Watch -> body["sessionId"] = sessionId?.let(::JsonPrimitive) ?: JsonNull
            Refresh -> Unit
            is Input -> {
                body["sessionId"] = JsonPrimitive(sessionId)
                body["text"] = JsonPrimitive(text)
            }
            is Interrupt -> body["sessionId"] = JsonPrimitive(sessionId)
            is WatchAgent -> {
                body["sessionId"] = JsonPrimitive(sessionId)
                body["runId"] = JsonPrimitive(runId)
                body["agentId"] = JsonPrimitive(agentId)
            }
        }
        return JsonObject(body).toString().toByteArray(Charsets.UTF_8)
    }

    companion object {
        /** `{"e": <envelope>}`, the body of POST /sessions/command. */
        fun requestBody(plaintext: ByteArray, root: ByteArray, nonce: ByteArray? = null): String {
            val envelope = SessionCrypto.seal(plaintext, root, SessionCrypto.Direction.PHONE_TO_MAC, SessionFrameType.COMMAND, nonce)
            return JsonObject(mapOf("e" to JsonObject(TreeMap(envelope.json)))).toString()
        }
    }
}

/**
 * What the composer accepts: 1–8000 characters after trimming, and a body
 * the relay will take (64 KiB, which multi-scalar emoji can exceed well
 * before 8000 characters once encrypted and base64-encoded).
 */
object SessionComposer {
    const val MAX_CHARACTERS = 8000
    const val MAX_BODY_BYTES = 64 * 1024

    /** Show a counter once the draft gets close to the limit. */
    const val COUNTER_FROM = 7000

    sealed interface Problem {
        data object Empty : Problem
        data class TooLong(val count: Int) : Problem
        data object TooLarge : Problem

        val message: String
            get() = when (this) {
                Empty -> "Type a message first."
                is TooLong -> "That's $count characters. Keep it to $MAX_CHARACTERS or fewer."
                TooLarge -> "That message is too large to send. Shorten it (emoji and symbols take more space)."
            }
    }

    sealed interface Validation {
        data class Ok(val text: String) : Validation
        data class Bad(val problem: Problem) : Validation
    }

    fun validate(raw: String): Validation {
        val text = raw.trim()
        if (text.isEmpty()) return Validation.Bad(Problem.Empty)
        val count = text.graphemeCount()
        if (count > MAX_CHARACTERS) return Validation.Bad(Problem.TooLong(count))
        return Validation.Ok(text)
    }

    fun fitsRelay(body: String): Boolean = body.toByteArray(Charsets.UTF_8).size <= MAX_BODY_BYTES
}

/** HTTP outcome of POST /sessions/command. */
sealed interface SessionCommandOutcome {
    /** 202: forwarded to the Mac. The `result` frame says what happened. */
    data object Accepted : SessionCommandOutcome

    /** 503 `mac_offline`: nothing was queued. */
    data object MacOffline : SessionCommandOutcome

    /** 400 `invalid_envelope`. */
    data object Invalid : SessionCommandOutcome

    /** 413 `too_large`. */
    data object TooLarge : SessionCommandOutcome

    /** 429 `rate_limited`. */
    data object RateLimited : SessionCommandOutcome

    /** 401/403: the relay rejected our token. */
    data object Unauthorized : SessionCommandOutcome

    /** 410 `token_retired`: re-pair. Carries the relay's explanation. */
    data class Retired(val why: String) : SessionCommandOutcome

    /** 404: a relay that predates live sessions has no such route. */
    data object RelayTooOld : SessionCommandOutcome

    /** Transport error or anything else; the message is shown. */
    data class Failed(val message: String) : SessionCommandOutcome

    /** What a sent message shows when the relay didn't forward it. */
    val failureMessage: String?
        get() = when (this) {
            Accepted -> null
            MacOffline -> "Your Mac is offline, so nothing was sent. Try again when Page on your Mac is connected."
            Invalid -> "The relay couldn't read this message. Re-pair with your Mac if this keeps happening."
            TooLarge -> SessionComposer.Problem.TooLarge.message
            RateLimited -> "Too many messages in a minute. Wait a moment and try again."
            Unauthorized -> "The relay no longer accepts this pairing. Re-pair with your Mac."
            is Retired -> why
            RelayTooOld -> "Your relay doesn't support live sessions yet. Update your Cloudflare Worker."
            is Failed -> message
        }

    /** For logs: a code, never content. */
    val logName: String
        get() = when (this) {
            Accepted -> "accepted"
            MacOffline -> "mac_offline"
            Invalid -> "invalid"
            TooLarge -> "too_large"
            RateLimited -> "rate_limited"
            Unauthorized -> "unauthorized"
            is Retired -> "token_retired"
            RelayTooOld -> "no_route"
            is Failed -> "failed"
        }

    companion object {
        fun from(status: Int, body: String): SessionCommandOutcome {
            TokenRetirement.why(status, body)?.let { return Retired(it) }
            return when (status) {
                in 200..299 -> Accepted
                503 -> MacOffline
                400 -> Invalid
                413 -> TooLarge
                429 -> RateLimited
                401, 403 -> Unauthorized
                404 -> RelayTooOld
                else -> {
                    val error = parseJsonObject(body)?.str("error")
                    if (error != null) Failed("The relay refused it ($error).")
                    else Failed("The relay returned an error (HTTP $status).")
                }
            }
        }
    }
}
