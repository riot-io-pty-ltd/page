package app.page.android.notify

import android.content.Context
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import app.page.android.R
import app.page.android.data.RelayClient
import app.page.android.model.InterventionKind
import app.page.android.model.QueuedReplyNotification
import app.page.android.model.ReplyRetract
import app.page.android.model.TokenRetirement
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Takes back a reply queued at the relay for an offline Mac, from its notification's Delete (`DELETE /reply/:id`,
 * `reply-retract-v1`). Its own unique work, `retract-<id>`, so a double tap asks once. It reads the relay's `/status`
 * features itself (a fresh process has none) and only claims "Deleted — not sent" when the relay says so; every other
 * answer is shown in its own words and the reply is left as it was.
 */
class RetractWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val id = inputData.getString(K_ID) ?: return Result.failure()
        val info = PostedPages.get(id) ?: PageInfo(id, InterventionKind.USER_INPUT.wire, "", "", null, false)
        ReplyRetractor.run(info)
        return Result.success()
    }

    /** Expedited work on Android 11 and older runs as a short foreground job. */
    override suspend fun getForegroundInfo(): ForegroundInfo {
        val n = NotificationCompat.Builder(applicationContext, PageNotifications.CHANNEL_CONNECTION)
            .setSmallIcon(R.drawable.ic_stat_page)
            .setContentTitle("Deleting your reply…")
            .setSilent(true)
            .build()
        return ForegroundInfo(FOREGROUND_ID, n)
    }

    companion object {
        private const val K_ID = "page.id"
        private const val FOREGROUND_ID = 8
        fun input(interventionId: String): Data = workDataOf(K_ID to interventionId)
        fun uniqueName(interventionId: String) = "retract-$interventionId"
    }
}

/** The delete itself and what the page's notification becomes after it. */
object ReplyRetractor {
    suspend fun run(info: PageInfo) = withContext(Dispatchers.Main) {
        val id = info.id
        // A reply the relay says the Mac already has is asked about at the Mac (up to 20 s): the notification says so.
        val outcome = RelayClient.retractReply(id) { PageNotifications.post(info, silent = true, status = ReplyRetract.ASKING_MAC) }
        val plan = QueuedReplyNotification.after(outcome)
        when (outcome) {
            // The page is not pending any more: its notification goes, with a word.
            ReplyRetract.Outcome.PageGone -> {
                NotificationReplyState.clear(listOf(id))
                PageNotifications.pagesClosed(listOf(id))
                PageNotifications.notice("Nothing to delete", "Your relay no longer has that page.", id)
            }
            ReplyRetract.Outcome.Unauthorized -> {
                NotificationReplyState.clear(listOf(id))
                PageNotifications.post(info, silent = true, status = null)
                PageNotifications.notice("Reply not deleted", "Your relay no longer accepts this pairing. Open Page to re-pair with your Mac.", id)
            }
            is ReplyRetract.Outcome.Retired -> PageNotifications.notice("Reply not deleted", "${TokenRetirement.sentence(outcome.why)} Open Page to pair again.", id)
            else -> {
                // Gone from the relay's queue (deleted, or nothing live): the page's own actions are back. Anything
                // else is the reply as it was, with the relay's words; a delete that never reached it can be tried again.
                if (plan.status == null) NotificationReplyState.clear(listOf(id))
                PageNotifications.post(info, silent = true, status = plan.status, note = plan.note, deleteAction = plan.deleteAgain)
            }
        }
    }
}
