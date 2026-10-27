package app.page.android.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.RemoteInput
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import app.page.android.model.ActionGate
import app.page.android.model.NowRowBuilder
import app.page.android.model.NotificationActionId
import app.page.android.model.NotificationActionUri
import app.page.android.model.NotificationDecision
import app.page.android.model.NotificationResponseKind
import app.page.android.model.PhoneReversibility

/**
 * Approve / Deny / Carry on / Reply from a page notification (the Android
 * side of iOS NotificationService.didReceive). Non-exported, reached only by
 * explicit intents from Page's own PendingIntents.
 *
 * What it trusts: the page id and action from the intent's data URI (which
 * fill-in can't change, even on the mutable reply intent), the page's kind
 * and limits from [PostedPages] (what Page itself posted), and — for Reply
 * only — the RemoteInput text. Extras that disagree with the URI are
 * rejected. It then decides with the same pure [NotificationDecision] iOS
 * uses, so Approve/Deny only ever act on approval pages, and hands the POST
 * to [ReplyWorker]: a receiver only has seconds, and a slow network must
 * never turn into a false "not sent".
 */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != PageNotifications.ACTION_PAGE) return
        val parsed = NotificationActionUri.parse(intent.dataString)
        if (parsed == null) {
            Log.w(TAG, "dropped an action without a valid data URI")
            return
        }
        val extraId = intent.getStringExtra(PageNotifications.EXTRA_PAGE_ID)
        val extraAction = intent.getStringExtra(PageNotifications.EXTRA_ACTION)
        if ((extraId != null && extraId != parsed.interventionId) || (extraAction != null && extraAction != parsed.action)) {
            Log.w(TAG, "dropped an action whose extras disagree with its URI")
            return
        }
        val info = PostedPages.get(parsed.interventionId)
        if (info == null) {
            // Page never posted this (or it closed and was forgotten).
            PageNotifications.notice("Nothing was sent", "Page couldn't match that notification to a page. Open Page to answer it.", parsed.interventionId)
            return
        }
        // Only the reply action carries user input, and only its typed text is used.
        val typed = if (parsed.action == NotificationActionId.REPLY) {
            RemoteInput.getResultsFromIntent(intent)?.getCharSequence(PageNotifications.REMOTE_INPUT_KEY)?.toString()
        } else {
            null
        }

        // Approve from a notification is only for what the phone itself classifies as undoable, judged now from
        // the live page (never from the shortened text Page stored): anything else, or a page that is not in the
        // inbox, opens the app on the Decision sheet (iOS NotificationDecision `approveLevel`).
        val page = RelayClient.inbox.value.firstOrNull { it.id == info.id }
        val approveLevel = page?.let { PhoneReversibility.verdict(it)?.level }
        // And only what the page's row offers: a session Page can't type into offers Open on Mac alone, so a
        // banner's Approve, Deny or reply opens the app instead. The Mac's name only colours previews, which a
        // banner never shows (iOS ActionGate.banner).
        val row = page?.let { NowRowBuilder.row(it, SessionStore.state.value.session(it.sessionId), "") }
        val decision = ActionGate.banner(
            NotificationDecision.decide(NotificationResponseKind.Action(parsed.action), typed, info.kind, info.subtype, approveLevel),
            row,
        )
        when (decision) {
            NotificationDecision.Open, NotificationDecision.Ignore -> {
                // An empty reply: put the notification back as it was, which
                // also stops Android's reply spinner.
                PageNotifications.post(info, silent = true, status = null)
                if (decision == NotificationDecision.Open) {
                    // Not undoable, not in the inbox, or a session Page can't type into: a notification can't
                    // offer the tap or the hold plus biometrics (or the keystrokes), so nothing is sent and the
                    // app is where to decide.
                    PageNotifications.notice("Nothing was sent", "This one needs a closer look. Open Page to answer it.", info.id)
                }
            }
            is NotificationDecision.Refuse -> {
                PageNotifications.post(info, silent = true, status = null)
                PageNotifications.notice("Nothing was sent", decision.why, info.id)
            }
            is NotificationDecision.Send -> {
                if (info.decisionsOnly && decision.text.isNotEmpty()) {
                    // The relay refuses text for v1 hook pages (422); say so now.
                    PageNotifications.post(info, silent = true, status = null)
                    PageNotifications.notice("Nothing was sent", "This page can only be approved or denied.", info.id)
                    return
                }
                // Replace the actions with a status at once: no double taps,
                // and the reply spinner ends.
                PageNotifications.post(info, silent = true, status = "Sending your reply…")
                val request = OneTimeWorkRequestBuilder<ReplyWorker>()
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .setInputData(ReplyWorker.input(info.id, decision.text, decision.action))
                    .build()
                WorkManager.getInstance(context).enqueueUniqueWork("reply-${info.id}", ExistingWorkPolicy.KEEP, request)
            }
        }
    }

    private companion object {
        const val TAG = "NotificationAction"
    }
}
