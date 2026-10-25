package app.page.android.notify

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.app.RemoteInput
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.workDataOf
import app.page.android.model.NotificationDecision
import app.page.android.model.NotificationResponseKind

/**
 * Approve / Deny / Carry on / Reply from a page notification (the Android
 * side of iOS NotificationService.didReceive). Decides with the same pure
 * [NotificationDecision] iOS uses, so Approve/Deny only ever act on approval
 * pages, then hands the POST to [ReplyWorker]: a broadcast receiver only has
 * seconds, and a slow network must never turn into a false "not sent".
 */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val info = PageInfo.from(intent.extras) ?: return
        val actionId = intent.getStringExtra(PageNotifications.EXTRA_ACTION) ?: return
        val typed = RemoteInput.getResultsFromIntent(intent)?.getCharSequence(PageNotifications.REMOTE_INPUT_KEY)?.toString()

        when (val decision = NotificationDecision.decide(NotificationResponseKind.Action(actionId), typed, info.kind)) {
            NotificationDecision.Open, NotificationDecision.Ignore -> {
                // An empty reply: put the notification back as it was, which
                // also stops Android's reply spinner.
                PageNotifications.post(info, silent = true, status = null)
            }
            is NotificationDecision.Refuse -> {
                PageNotifications.post(info, silent = true, status = null)
                PageNotifications.notice("Nothing was sent", decision.why, info.id)
            }
            is NotificationDecision.Send -> {
                // Replace the actions with a status at once: no double taps,
                // and the reply spinner ends.
                PageNotifications.post(info, silent = true, status = "Sending your reply…")
                val request = OneTimeWorkRequestBuilder<ReplyWorker>()
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .setInputData(ReplyWorker.input(info, decision.text, decision.action))
                    .build()
                WorkManager.getInstance(context).enqueueUniqueWork("reply-${info.id}", ExistingWorkPolicy.KEEP, request)
            }
        }
    }
}
