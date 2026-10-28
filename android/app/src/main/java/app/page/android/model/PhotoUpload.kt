package app.page.android.model

import java.time.Instant
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

// Sending photos over the sessions channel (docs/SESSIONS-PROTOCOL.md "Images (images-v1)"): each photo travels in
// pieces of at most 32 KiB, every piece its own sealed command; then one `inputImages` names the photos and carries
// the caption. The uploader here is the whole state machine (at most 3 pieces in flight, a new clientId for every
// retried piece, back off on 429, stop on 503, `inputImages` only after every piece got its 202, one resend of what
// the Mac says is missing, a 30 s wait for the result), written against a transport interface so the JVM tests drive
// it with scripted answers. Pure Kotlin: no Android types.

/** A photo of this send, with the id its pieces carry. A new send always gets new ids (the Mac remembers used ones for 15 minutes). */
class UploadPhoto(val imageId: String, val photo: PreparedPhoto) {
    val pieces: Int get() = PhotoChunks.count(photo.size)
    val ref: SessionCommand.ImageRef get() = SessionCommand.ImageRef(imageId, photo.sha256, photo.size, photo.mime)

    fun piece(sessionId: String, index: Int): SessionCommand.ImagePart =
        SessionCommand.ImagePart(sessionId, imageId, index, pieces, photo.size, photo.sha256, photo.mime, PhotoChunks.slice(photo.bytes, index))
}

/** Where an upload stands, for the receipt and the bubble. */
data class PhotoProgress(val piecesDone: Int, val piecesTotal: Int, val phase: Phase) {
    enum class Phase { UPLOADING, RESENDING, WAITING }

    /** 0 to 1 of the pieces sent; 1 once waiting for the Mac. */
    val fraction: Double get() = if (phase == Phase.WAITING || piecesTotal <= 0) 1.0 else (piecesDone.toDouble() / piecesTotal).coerceIn(0.0, 1.0)

    /**
     * "Uploading 3 of 8" (pieces, as iOS `PhotoCopy.uploading`), "Resending…", and once `inputImages` is out "Typing into
     * tmux…" ([host]: the terminal the room showed; iOS `PhotoCopy.typing`).
     */
    @Suppress("UNUSED_PARAMETER")
    fun line(photos: Int, host: String? = null): String = when (phase) {
        Phase.UPLOADING -> PhotoCopy.uploading(piecesDone, piecesTotal)
        Phase.RESENDING -> "Resending part of a photo…"
        Phase.WAITING -> PhotoCopy.typing(host)
    }
}

/** The words of a photo send that both platforms share (iOS `PhotoCopy`). */
object PhotoCopy {
    fun uploading(done: Int, total: Int): String = "Uploading $done of $total"

    /** "Typing into tmux…": where the Mac is putting the photos once `inputImages` is out. */
    fun typing(host: String?): String {
        val h = host?.trim().orEmpty()
        return if (h.isEmpty()) "Typing into the session…" else "Typing into $h…"
    }
}

/**
 * The `inputImages` commands whose `result` may still come after the phone stopped waiting for it (30 s with no answer,
 * or a POST whose answer was lost), by the command's own `clientId`: each names the photo bubble it settles. Kept for
 * [KEEP_SECONDS], and bounded. Pure but for its own map, so the JVM tests drive it with a clock.
 */
class LatePhotoResults {
    data class Entry(val bubbleId: String, val photos: Int, val attach: String?, val at: Instant)

    private val entries = LinkedHashMap<String, Entry>()

    fun remember(clientId: String, entry: Entry) {
        entries.remove(clientId)
        entries[clientId] = entry
        while (entries.size > MAX_ENTRIES) entries.remove(entries.keys.first())
    }

    /** The entry for a result that arrived, once: null when none was kept or it is older than [KEEP_SECONDS]. */
    fun take(clientId: String, now: Instant): Entry? {
        val e = entries.remove(clientId) ?: return null
        return e.takeIf { now.secondsSince(it.at) <= KEEP_SECONDS }
    }

    /** The answer came the ordinary way: nothing is left to catch. */
    fun forget(clientId: String) { entries.remove(clientId) }

    fun clear() = entries.clear()

    val size: Int get() = entries.size

    companion object {
        /** A late result still settles its photo bubble for this long (5 minutes). */
        const val KEEP_SECONDS: Double = 5 * 60.0
        const val MAX_ENTRIES = 40
    }
}

/** What the uploader needs from the app: sealed POSTs, and the `result` of the one command that gets one. */
interface PhotoTransport {
    /** Seals and POSTs [command] under [clientId]; the relay's answer. */
    suspend fun post(command: SessionCommand, clientId: String): SessionCommandOutcome

    /** Starts listening for the `result` of [clientId] (before its POST: a result can beat the HTTP answer). */
    fun expect(clientId: String): ResultWaiter
}

interface ResultWaiter {
    /** The result, or null after [timeoutMillis]. */
    suspend fun await(timeoutMillis: Long): CommandResult?
    fun cancel()
}

/** How an upload ended. */
sealed interface UploadOutcome {
    /** The Mac answered `inputImages`: [result] is its word (a refusal is a result too). [clientId] is the `inputImages` it answers. */
    data class Answered(val result: CommandResult, val clientId: String) : UploadOutcome

    /** It stopped before the Mac could answer: the relay refused, the Mac went offline, or the network failed. */
    data class Stopped(val message: String, val macOffline: Boolean = false) : UploadOutcome

    /** `inputImages` went out and nothing came back in 30 s. */
    data object NoAnswer : UploadOutcome
}

class PhotoUploader(
    private val transport: PhotoTransport,
    private val newClientId: () -> String,
    private val pause: suspend (Long) -> Unit = { delay(it) },
    private val maxInFlight: Int = MAX_IN_FLIGHT,
    private val resultTimeoutMillis: Long = RESULT_TIMEOUT_MILLIS,
) {
    private sealed interface Stop {
        data class Relay(val message: String) : Stop
        data object Offline : Stop
    }

    /**
     * Uploads every piece of [photos], sends `inputImages`, and waits for its result. When the Mac says pieces are
     * missing (`attachment_missing`, with their photo ids) the pieces of those photos go again once, followed by a
     * new `inputImages` under a new clientId; a second `attachment_missing` is the answer. [onProgress] hears each step.
     */
    suspend fun run(
        sessionId: String, photos: List<UploadPhoto>, caption: String, target: SessionTarget?,
        onProgress: (PhotoProgress) -> Unit = {},
    ): UploadOutcome {
        val total = photos.sumOf { it.pieces }
        var done = 0
        fun progress(phase: PhotoProgress.Phase) = onProgress(PhotoProgress(done, total, phase))
        progress(PhotoProgress.Phase.UPLOADING)

        suspend fun upload(which: List<UploadPhoto>, phase: PhotoProgress.Phase): Stop? {
            progress(phase)
            return sendPieces(sessionId, which) { done += 1; progress(phase) }
        }
        fun stopped(s: Stop) = when (s) {
            Stop.Offline -> UploadOutcome.Stopped(OFFLINE, macOffline = true)
            is Stop.Relay -> UploadOutcome.Stopped(s.message)
        }

        upload(photos, PhotoProgress.Phase.UPLOADING)?.let { return stopped(it) }
        var retried = false
        var attempt = photos
        while (true) {
            progress(PhotoProgress.Phase.WAITING)
            val clientId = newClientId()
            val waiter = transport.expect(clientId)
            val command = SessionCommand.InputImages(sessionId, caption, photos.map { it.ref }, target)
            val outcome = transport.post(command, clientId)
            if (outcome != SessionCommandOutcome.Accepted) {
                waiter.cancel()
                return if (outcome == SessionCommandOutcome.MacOffline) UploadOutcome.Stopped(OFFLINE, macOffline = true)
                else UploadOutcome.Stopped(outcome.failureMessage ?: "The photos couldn't be sent.")
            }
            val result = waiter.await(resultTimeoutMillis) ?: return UploadOutcome.NoAnswer
            val missing = photos.filter { it.imageId in result.missing }
            if (result.reason != "attachment_missing" || missing.isEmpty() || retried) return UploadOutcome.Answered(result, clientId)
            // Once: the pieces of those photos again (new clientIds), then a new inputImages.
            retried = true
            attempt = missing
            done -= attempt.sumOf { it.pieces }
            upload(attempt, PhotoProgress.Phase.RESENDING)?.let { return stopped(it) }
        }
    }

    /** At most [maxInFlight] pieces in flight, each retried as its own policy says; the first stop ends it. */
    private suspend fun sendPieces(sessionId: String, photos: List<UploadPhoto>, onSent: () -> Unit): Stop? {
        val jobs = Channel<Pair<UploadPhoto, Int>>(Channel.UNLIMITED)
        for (p in photos) for (i in 0 until p.pieces) jobs.trySend(p to i)
        jobs.close()
        val stop = AtomicReference<Stop?>(null)
        coroutineScope {
            repeat(maxInFlight.coerceAtLeast(1)) {
                launch {
                    for ((photo, index) in jobs) {
                        if (stop.get() != null) return@launch
                        val s = sendPiece(sessionId, photo, index)
                        if (s != null) { stop.compareAndSet(null, s); return@launch }
                        onSent()
                    }
                }
            }
        }
        return stop.get()
    }

    private suspend fun sendPiece(sessionId: String, photo: UploadPhoto, index: Int): Stop? {
        var rateLimited = 0
        var failures = 0
        while (true) {
            // A retried piece is a new command: a new clientId, same bytes.
            when (val outcome = transport.post(photo.piece(sessionId, index), newClientId())) {
                SessionCommandOutcome.Accepted -> return null
                // The bucket refills at 2 a second: wait, twice as long each time (0.5 s up to 4 s), and try again.
                SessionCommandOutcome.RateLimited -> {
                    rateLimited += 1
                    if (rateLimited > MAX_RATE_LIMITED_RETRIES) return Stop.Relay(SessionCommandOutcome.RateLimited.failureMessage!!)
                    pause(minOf(MAX_BACKOFF_MILLIS, BACKOFF_MILLIS shl (rateLimited - 1).coerceAtMost(16)))
                }
                SessionCommandOutcome.MacOffline -> return Stop.Offline
                // A piece lost in transit goes back in the queue at once (a new clientId): no pause of its own.
                is SessionCommandOutcome.Failed -> {
                    failures += 1
                    if (failures >= MAX_FAILURES) return Stop.Relay(outcome.message)
                }
                else -> return Stop.Relay(outcome.failureMessage ?: "The photos couldn't be sent.")
            }
        }
    }

    companion object {
        const val MAX_IN_FLIGHT = 3
        const val RESULT_TIMEOUT_MILLIS = 30_000L
        const val BACKOFF_MILLIS = 500L
        const val MAX_BACKOFF_MILLIS = 4_000L
        /** The same numbers as iOS `PhotoUploadMachine` (backoffStart 0.5 s, backoffCap 4 s, maxRateLimits 12, maxAttempts 3). */
        const val MAX_RATE_LIMITED_RETRIES = 12
        const val MAX_FAILURES = 3
        const val OFFLINE = "Your Mac went offline"

        /** What a bubble says when `inputImages` got no answer in 30 s. */
        const val NO_ANSWER = "No answer from your Mac. It may still arrive; check the story before sending again."
    }
}
