package app.page.android.model

import java.time.Instant
import kotlinx.serialization.json.JsonArray

data class CommandResult(
    val clientId: String,
    val ok: Boolean,
    val code: Code,
    val reason: String?,
    /** Short sentence from the Mac, at most 200 characters. */
    val detail: String?,
    val interventionId: String?,
) {
    enum class Code(val wire: String) {
        DELIVERED("delivered"), QUEUED("queued"), REFUSED("refused"), FAILED("failed");

        companion object {
            fun fromWire(raw: String?): Code? = entries.firstOrNull { it.wire == raw }
        }
    }
}

/** The plaintext kinds this build understands (Mac → phone). */
sealed interface SessionsUpdate {
    data class ListUpdate(val macName: String?, val sessions: List<LiveSession>) : SessionsUpdate
    data class Transcript(val transcript: SessionTranscript) : SessionsUpdate
    data class Screen(val screen: SessionScreen) : SessionsUpdate
    data class Workflows(val sessionId: String, val runs: List<WorkflowRun>) : SessionsUpdate
    data class Result(val result: CommandResult) : SessionsUpdate
}

/** One decrypted `sessions.update`. */
data class SessionsPlaintext(
    /** Random per Mac launch; "" from a Mac that doesn't send one. */
    val boot: String,
    val seq: Long,
    /** Mac clock. */
    val ts: Instant,
    val update: SessionsUpdate,
    /**
     * A `list` from a Mac with live sessions turned off in its settings (an
     * optional field the Mac adds; others never send it).
     */
    val macDisabled: Boolean = false,
) {
    companion object {
        const val MAX_SESSIONS = 100
        const val MAX_ENTRIES = 40
        const val MAX_RUNS = 12

        /**
         * Null for anything malformed or of an unknown `kind` (ignored, as the
         * protocol asks). A `list` without a `sessions` array is malformed,
         * not empty, so a bad frame can never blank the screen. Unknown
         * fields are ignored, so newer Macs can add kinds and fields freely.
         */
        fun decode(data: ByteArray): SessionsPlaintext? = decode(data.toString(Charsets.UTF_8))

        fun decode(text: String): SessionsPlaintext? {
            val raw = parseJsonObject(text) ?: return null
            val kind = raw.str("kind") ?: return null
            val seq = raw.num("seq") ?: return null
            val ts = raw.num("ts") ?: return null
            if (ts <= 0 || Math.abs(seq) >= 9e15) return null
            val update: SessionsUpdate = when (kind) {
                "list" -> {
                    val list = lossyList(raw["sessions"], LiveSession::decode) ?: return null
                    val name = raw.str("macName")?.trim()
                    SessionsUpdate.ListUpdate(
                        macName = if (name.isNullOrEmpty()) null else name.capped(60),
                        sessions = list.elements.take(MAX_SESSIONS),
                    )
                }
                "transcript" -> {
                    val sid = raw.str("sessionId")?.takeIf { it.isNotEmpty() } ?: return null
                    val entries = lossyList(raw["entries"], TranscriptEntry::decode) ?: return null
                    val run = raw.str("runId")?.takeIf { it.isNotEmpty() }
                    val agent = raw.str("agentId")?.takeIf { it.isNotEmpty() }
                    val agentKeyed = run != null && agent != null
                    SessionsUpdate.Transcript(
                        SessionTranscript(
                            sessionId = sid,
                            entries = entries.elements.takeLast(MAX_ENTRIES),
                            truncated = raw.bool("truncated") ?: false,
                            runId = if (agentKeyed) run!!.capped(64) else null,
                            agentId = if (agentKeyed) agent!!.capped(64) else null,
                        )
                    )
                }
                "workflows" -> {
                    val sid = raw.str("sessionId")?.takeIf { it.isNotEmpty() } ?: return null
                    val runs = lossyList(raw["runs"], WorkflowRun::decode) ?: return null
                    SessionsUpdate.Workflows(sid, runs.elements.take(MAX_RUNS))
                }
                "screen" -> {
                    val sid = raw.str("sessionId")?.takeIf { it.isNotEmpty() } ?: return null
                    val array = raw["lines"] as? JsonArray ?: return null
                    // Every line must be a string, or the frame is malformed.
                    val lines = array.map { it.asString() ?: return null }
                    SessionsUpdate.Screen(
                        SessionScreen(
                            sessionId = sid,
                            lines = lines.takeLast(SessionScreen.MAX_LINES).map { it.capped(SessionScreen.MAX_LINE_CHARS) },
                            at = PageDate.ofEpochMillis(ts),
                        )
                    )
                }
                "result" -> {
                    val cid = raw.str("clientId")?.takeIf { it.isNotEmpty() } ?: return null
                    val ok = raw.bool("ok") ?: false
                    val detail = raw.str("detail")?.trim()
                    SessionsUpdate.Result(
                        CommandResult(
                            clientId = cid,
                            ok = ok,
                            code = CommandResult.Code.fromWire(raw.str("code"))
                                ?: if (ok) CommandResult.Code.DELIVERED else CommandResult.Code.FAILED,
                            reason = raw.str("reason")?.takeIf { it.isNotEmpty() },
                            detail = if (detail.isNullOrEmpty()) null else detail.capped(200),
                            interventionId = raw.str("interventionId")?.takeIf { it.isNotEmpty() },
                        )
                    )
                }
                else -> return null
            }
            return SessionsPlaintext(
                boot = raw.str("boot") ?: "",
                seq = seq.toLong(),
                ts = PageDate.ofEpochMillis(ts),
                update = update,
                macDisabled = update is SessionsUpdate.ListUpdate && (raw.bool("disabled") ?: false),
            )
        }
    }
}

/**
 * Which decrypted updates the phone applies (§4). Drop anything whose `ts` is
 * more than 10 minutes old (replay guard), and drop a `list` whose `seq` is at
 * or below the last applied list from the same `boot`. A new `boot` (the Mac
 * relaunched) resets the tracking. Transcripts, screens and workflows get the
 * same rule per session, since `seq` is one counter per Mac process.
 */
class SessionUpdateGate {
    enum class Verdict {
        ACCEPT,

        /** Older than [MAX_AGE] by the phone's clock. */
        TOO_OLD,

        /** Same boot, `seq` not newer than what's already shown. */
        OUT_OF_ORDER,
    }

    var boot: String? = null
        private set
    var lastListSeq: Long? = null
        private set
    private val lastTranscriptSeq = HashMap<String, Long>()
    private val lastScreenSeq = HashMap<String, Long>()

    fun admit(p: SessionsPlaintext, now: Instant): Verdict {
        // Age first: a stale frame from a new boot mustn't reset tracking.
        if (now.secondsSince(p.ts) > MAX_AGE) return Verdict.TOO_OLD
        if (p.boot != boot) {
            boot = p.boot
            lastListSeq = null
            lastTranscriptSeq.clear()
            lastScreenSeq.clear()
        }
        when (val u = p.update) {
            is SessionsUpdate.ListUpdate -> {
                lastListSeq?.let { if (p.seq <= it) return Verdict.OUT_OF_ORDER }
                lastListSeq = p.seq
            }
            is SessionsUpdate.Transcript -> if (!advance(lastTranscriptSeq, u.transcript.key, p.seq)) return Verdict.OUT_OF_ORDER
            is SessionsUpdate.Workflows -> if (!advance(lastScreenSeq, "workflows|" + u.sessionId, p.seq)) return Verdict.OUT_OF_ORDER
            is SessionsUpdate.Screen -> if (!advance(lastScreenSeq, u.screen.sessionId, p.seq)) return Verdict.OUT_OF_ORDER
            is SessionsUpdate.Result -> Unit
        }
        return Verdict.ACCEPT
    }

    private fun advance(map: HashMap<String, Long>, key: String, seq: Long): Boolean {
        map[key]?.let { if (seq <= it) return false }
        if (map.size > 200) map.clear()
        map[key] = seq
        return true
    }

    fun reset() {
        boot = null
        lastListSeq = null
        lastTranscriptSeq.clear()
        lastScreenSeq.clear()
    }

    companion object {
        const val MAX_AGE: Double = 10 * 60.0
    }
}
