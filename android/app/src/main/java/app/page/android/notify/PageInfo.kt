package app.page.android.notify

import android.os.Bundle
import app.page.android.model.Intervention
import app.page.android.model.InterventionKind

/**
 * What a page notification needs, carried in its action intents so a
 * notification action can be handled — and the notification rebuilt — in a
 * cold process without fetching anything first.
 */
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

    fun toBundle(): Bundle = Bundle().apply {
        putString(K_ID, id)
        putString(K_KIND, kind)
        putString(K_PROJECT, projectName)
        putString(K_CONTEXT, context)
        putString(K_SUBTYPE, subtype)
        putBoolean(K_DECISIONS_ONLY, decisionsOnly)
    }

    companion object {
        private const val K_ID = "page.id"
        private const val K_KIND = "page.kind"
        private const val K_PROJECT = "page.project"
        private const val K_CONTEXT = "page.context"
        private const val K_SUBTYPE = "page.subtype"
        private const val K_DECISIONS_ONLY = "page.decisionsOnly"

        fun of(iv: Intervention) = PageInfo(
            id = iv.id, kind = iv.kind.wire, projectName = iv.projectName,
            context = iv.context, subtype = iv.subtype, decisionsOnly = iv.acceptsDecisionsOnly,
        )

        fun from(bundle: Bundle?): PageInfo? {
            val b = bundle ?: return null
            val id = b.getString(K_ID)?.takeIf { it.isNotEmpty() && it.length <= 200 } ?: return null
            return PageInfo(
                id = id,
                kind = b.getString(K_KIND) ?: InterventionKind.USER_INPUT.wire,
                projectName = b.getString(K_PROJECT) ?: "",
                context = b.getString(K_CONTEXT) ?: "",
                subtype = b.getString(K_SUBTYPE),
                decisionsOnly = b.getBoolean(K_DECISIONS_ONLY, false),
            )
        }
    }
}
