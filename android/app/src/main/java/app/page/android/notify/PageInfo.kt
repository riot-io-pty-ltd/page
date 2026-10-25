package app.page.android.notify

import app.page.android.data.AppGraph
import app.page.android.model.Intervention
import app.page.android.model.InterventionKind
import app.page.android.model.bool
import app.page.android.model.parseJsonObject
import app.page.android.model.str
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/** What a page notification shows and which actions it offers. */
data class PageInfo(
    val id: String,
    /** The decoded kind's wire name; [app.page.android.model.NotificationDecision] maps it back. */
    val kind: String,
    val projectName: String,
    val context: String,
    val subtype: String?,
    /** A v1 blocking-hook page: only Approve/Deny can be applied. */
    val decisionsOnly: Boolean,
) {
    val decodedKind: InterventionKind get() = InterventionKind.fromWire(kind)

    fun toJson(): JsonObject = JsonObject(
        buildMap<String, JsonElement> {
            put("id", JsonPrimitive(id))
            put("kind", JsonPrimitive(kind))
            put("project", JsonPrimitive(projectName))
            // The notification shows 180 characters; keep the record small.
            put("context", JsonPrimitive(context.take(500)))
            subtype?.let { put("subtype", JsonPrimitive(it)) }
            put("decisionsOnly", JsonPrimitive(decisionsOnly))
        }
    )

    companion object {
        fun of(iv: Intervention) = PageInfo(
            id = iv.id, kind = iv.kind.wire, projectName = iv.projectName,
            context = iv.context, subtype = iv.subtype, decisionsOnly = iv.acceptsDecisionsOnly,
        )

        fun fromJson(o: JsonObject): PageInfo? {
            val id = o.str("id")?.takeIf { it.isNotEmpty() } ?: return null
            return PageInfo(
                id = id,
                kind = o.str("kind") ?: InterventionKind.USER_INPUT.wire,
                projectName = o.str("project") ?: "",
                context = o.str("context") ?: "",
                subtype = o.str("subtype"),
                decisionsOnly = o.bool("decisionsOnly") ?: false,
            )
        }
    }
}

/**
 * The phone's own record of the page notifications it posted, by page id.
 * A notification action is trusted only as far as this record goes: the
 * action intent's extras (fill-in can rewrite them on the mutable reply
 * intent) never decide the page's kind or what may be sent.
 */
object PostedPages {
    private const val MAX = 100

    @Synchronized
    fun record(info: PageInfo) {
        val next = load().filterKeys { it != info.id }.toMutableMap()
        next[info.id] = info
        save(next.entries.toList().takeLast(MAX).associate { it.key to it.value })
    }

    @Synchronized
    fun get(id: String): PageInfo? = load()[id]

    @Synchronized
    fun remove(ids: Collection<String>) {
        if (ids.isEmpty()) return
        val current = load()
        if (ids.none { it in current }) return
        save(current.filterKeys { it !in ids })
    }

    @Synchronized
    fun clear() {
        AppGraph.prefs.postedPagesJson = null
    }

    private fun load(): LinkedHashMap<String, PageInfo> {
        val out = LinkedHashMap<String, PageInfo>()
        val root = AppGraph.prefs.postedPagesJson?.let(::parseJsonObject) ?: return out
        for ((id, value) in root) {
            val info = (value as? JsonObject)?.let(PageInfo::fromJson) ?: continue
            if (info.id == id) out[id] = info
        }
        return out
    }

    private fun save(map: Map<String, PageInfo>) {
        AppGraph.prefs.postedPagesJson = JsonObject(map.mapValues { it.value.toJson() }).toString()
    }
}
