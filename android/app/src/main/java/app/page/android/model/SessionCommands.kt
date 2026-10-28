package app.page.android.model

import java.time.Instant
import java.util.TreeMap
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** Phone → Mac plaintext ops (§5). */
sealed interface SessionCommand {
    data class Watch(val sessionId: String?) : SessionCommand
    data object Refresh : SessionCommand
    /**
     * [expectCwd] / [expectTitle] are the folder and title the room showed, so
     * the Mac refuses (SessionTargetCheck) instead of typing if the session
     * behind this id is no longer that one. Both optional on the wire.
     */
    data class Input(
        val sessionId: String,
        val text: String,
        val target: SessionTarget? = null,
        /**
         * `hold: true`: the Mac types it when the turn ends (needs `hold-v1`; a phone sends it only when the list's
         * caps and the row's `canHold` say so). Absent, not false, otherwise: an old Mac sees the same bytes as before.
         */
        val hold: Boolean = false,
    ) : SessionCommand

    /**
     * Takes back a message the Mac holds and hasn't typed (needs `retract-v1`): exactly one of [heldId] (a held
     * `input`'s clientId) or [interventionId] (a `/reply` the Mac is holding). Never both, never neither.
     */
    data class Retract(val heldId: String? = null, val interventionId: String? = null) : SessionCommand
    /**
     * One piece of a photo (`images-v1`): at most 32 KiB of the photo's bytes as standard base64, and the photo's own
     * metadata repeated on every piece so pieces may arrive in any order. Never answered by a `result`.
     */
    data class ImagePart(
        val sessionId: String,
        val imageId: String,
        val index: Int,
        val total: Int,
        /** The whole photo's size, not this piece's. */
        val bytes: Int,
        val sha256: String,
        val mime: String,
        val data: ByteArray,
    ) : SessionCommand

    /** The photos of an [InputImages]: the id every piece carried, and the whole photo's hash, size and type. */
    data class ImageRef(val id: String, val sha256: String, val bytes: Int, val mime: String)

    /**
     * Sends the uploaded photos with a caption into the session (`images-v1`). [text] may be empty (0 to 8000
     * characters), so it never goes through [SessionComposer.validate]. Always answered by one `result`.
     */
    data class InputImages(val sessionId: String, val text: String, val images: List<ImageRef>, val target: SessionTarget? = null) : SessionCommand

    /** [target]'s `expectCwd` / `expectTitle` ride along like on [Input]. */
    data class Interrupt(val sessionId: String, val target: SessionTarget? = null) : SessionCommand

    /**
     * The answers to the question dialog the session is blocked on ([promptKey] is the ask's id). The Mac
     * refuses if that is no longer the question showing.
     */
    data class Answer(val sessionId: String, val promptKey: String, val answers: List<AnswerWire>, val target: SessionTarget? = null) : SessionCommand

    /** Esc in every working session (the pulse's Stop). */
    data object InterruptAll : SessionCommand

    /** Watch a workflow agent inside the session (its transcript). */
    data class WatchAgent(val sessionId: String, val runId: String, val agentId: String) : SessionCommand

    /** v4: what this session changed (answered with a `diff`). */
    data class Diff(val sessionId: String) : SessionCommand

    /** v4: where a new session may be started (answered with `folders`). */
    data object Folders : SessionCommand

    /** v4: start a new Claude session in [folder] with [text] as its first prompt (may be empty). */
    data class Start(val folder: String, val text: String) : SessionCommand

    val op: String
        get() = when (this) {
            is Watch, is WatchAgent -> "watch"
            Refresh -> "refresh"
            is Input -> "input"
            is Retract -> "retract"
            is ImagePart -> "imagePart"
            is InputImages -> "inputImages"
            is Interrupt -> "interrupt"
            is Answer -> "answer"
            InterruptAll -> "interruptAll"
            is Diff -> "diff"
            Folders -> "folders"
            is Start -> "start"
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
                if (hold) body["hold"] = JsonPrimitive(true)
                addExpectation(target, body)
            }
            is Retract -> {
                heldId?.let { body["heldId"] = JsonPrimitive(it) }
                interventionId?.let { body["interventionId"] = JsonPrimitive(it) }
            }
            is ImagePart -> {
                body["sessionId"] = JsonPrimitive(sessionId)
                body["imageId"] = JsonPrimitive(imageId)
                body["index"] = JsonPrimitive(index)
                body["total"] = JsonPrimitive(total)
                body["bytes"] = JsonPrimitive(bytes)
                body["sha256"] = JsonPrimitive(sha256)
                body["mime"] = JsonPrimitive(mime)
                body["data"] = JsonPrimitive(java.util.Base64.getEncoder().encodeToString(data))
            }
            is InputImages -> {
                body["sessionId"] = JsonPrimitive(sessionId)
                body["text"] = JsonPrimitive(text)
                body["images"] = JsonArray(images.map { r ->
                    JsonObject(mapOf("id" to JsonPrimitive(r.id), "sha256" to JsonPrimitive(r.sha256), "bytes" to JsonPrimitive(r.bytes), "mime" to JsonPrimitive(r.mime)))
                })
                addExpectation(target, body)
            }
            is Interrupt -> {
                body["sessionId"] = JsonPrimitive(sessionId)
                addExpectation(target, body)
            }
            is Answer -> {
                body["sessionId"] = JsonPrimitive(sessionId)
                body["promptKey"] = JsonPrimitive(promptKey)
                body["answers"] = JsonArray(answers.map { it.json })
                addExpectation(target, body)
            }
            InterruptAll -> Unit
            is Diff -> body["sessionId"] = JsonPrimitive(sessionId)
            Folders -> Unit
            is Start -> {
                body["folder"] = JsonPrimitive(folder)
                body["text"] = JsonPrimitive(text)
            }
            is WatchAgent -> {
                body["sessionId"] = JsonPrimitive(sessionId)
                body["runId"] = JsonPrimitive(runId)
                body["agentId"] = JsonPrimitive(agentId)
            }
        }
        return JsonObject(body).toString().toByteArray(Charsets.UTF_8)
    }

    companion object {
        /**
         * The optional "what the room showed" fields. Absent (not null) when unknown, so an old Mac sees the same
         * bytes as before and a new one has nothing to check.
         */
        private fun addExpectation(target: SessionTarget?, body: MutableMap<String, JsonElement>) {
            if (target == null) return
            target.expectCwd?.let { body["expectCwd"] = JsonPrimitive(it) }
            target.expectTitle?.let { body["expectTitle"] = JsonPrimitive(it) }
        }

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

        /** "When it finishes" asked of a Mac that doesn't advertise `hold-v1` (it would type the message at once). */
        data object HoldUnavailable : Problem

        val message: String
            get() = when (this) {
                Empty -> "Type a message first."
                is TooLong -> "That's $count characters. Keep it to $MAX_CHARACTERS or fewer."
                TooLarge -> "That message is too large to send. Shorten it (emoji and symbols take more space)."
                HoldUnavailable -> "Your Mac can't hold a message until Claude finishes. Update Page on your Mac, or send it now."
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
