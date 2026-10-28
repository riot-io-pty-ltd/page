package app.page.android.notify

import app.page.android.data.AppGraph
import app.page.android.model.parseJsonObject
import app.page.android.model.str
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Where a reply sent from a notification stands, by page id, so a Delete on its notification does the honest thing in
 * whichever process the tap lands (a receiver, the worker, or a fresh process):
 *
 * - [SENDING]: the reply's work is queued or running. A Delete marks [DELETE_REQUESTED]; the worker looks right before
 *   it POSTs, and only then can it say "Deleted — not sent". A POST already on its way can't be called back, so it
 *   falls through to the relay's own delete once the relay has the reply.
 * - [QUEUED]: the relay holds it for an offline Mac. A Delete asks the relay to take it back.
 *
 * Persisted (a handful of ids), never the reply's text.
 */
object NotificationReplyState {
    const val SENDING = "sending"
    const val QUEUED = "queued"
    const val DELETE_REQUESTED = "deleteRequested"
    private const val KEY = "page.notif.replyState"
    private const val MAX = 40

    @Synchronized
    fun get(id: String): String? = load()[id]

    @Synchronized
    fun set(id: String, state: String) {
        val next = LinkedHashMap(load())
        next.remove(id)
        next[id] = state
        save(next.entries.toList().takeLast(MAX).associate { it.key to it.value })
    }

    /** A Delete was pressed while the reply was still sending. */
    @Synchronized
    fun requestDelete(id: String) = set(id, DELETE_REQUESTED)

    /** True once, if a delete was asked for before the POST: the worker skips the send. */
    @Synchronized
    fun consumeDelete(id: String): Boolean {
        if (load()[id] != DELETE_REQUESTED) return false
        clear(listOf(id))
        return true
    }

    @Synchronized
    fun clear(ids: Collection<String>) {
        val current = load()
        if (ids.none { it in current }) return
        save(current.filterKeys { it !in ids })
    }

    private fun load(): Map<String, String> {
        val root = AppGraph.prefs.string(KEY)?.let(::parseJsonObject) ?: return emptyMap()
        val out = LinkedHashMap<String, String>()
        for ((id, v) in root) (v as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { out[id] = it }
        return out
    }

    private fun save(map: Map<String, String>) {
        AppGraph.prefs.putString(KEY, if (map.isEmpty()) null else JsonObject(map.mapValues { JsonPrimitive(it.value) }).toString())
    }
}
