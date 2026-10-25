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
import app.page.android.model.ReplyAction
import app.page.android.model.ReplyOutcome
import app.page.android.model.TokenRetirement
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Sends one reply chosen from a notification (iOS sendFromNotification),
 * as expedited work so it finishes even if the process would otherwise be
 * stopped right after the tap. Every outcome the user should hear about
 * becomes a notice; nothing fails silently.
 */
class ReplyWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val info = PageInfo(
            id = inputData.getString(K_ID) ?: return Result.failure(),
            kind = inputData.getString(K_KIND) ?: "user_input",
            projectName = inputData.getString(K_PROJECT) ?: "",
            context = inputData.getString(K_CONTEXT) ?: "",
            subtype = inputData.getString(K_SUBTYPE),
            decisionsOnly = inputData.getBoolean(K_DECISIONS_ONLY, false),
        )
        val action = ReplyAction.entries.firstOrNull { it.wire == inputData.getString(KEY_ACTION) } ?: return Result.failure()
        val text = inputData.getString(KEY_TEXT) ?: ""
        val where = info.projectName.ifEmpty { "your Mac" }

        // RelayClient's state is main-thread only.
        val outcome = withContext(Dispatchers.Main) { RelayClient.reply(info.id, text, action) }
        withContext(Dispatchers.Main) {
            when (outcome) {
                // 409 is almost always a double tap or an in-app reply that
                // got there first: the page was answered (or an answer is on
                // its way), which is what the user wanted.
                is ReplyOutcome.Accepted, ReplyOutcome.AlreadyReplied, ReplyOutcome.InFlight -> {
                    val status = if (outcome is ReplyOutcome.Accepted && outcome.queued) {
                        "Queued — your Mac is offline. It'll be typed in when it reconnects."
                    } else {
                        "Sent — waiting for your Mac to confirm."
                    }
                    // Stays until the Mac closes the page, which removes it.
                    PageNotifications.post(info, silent = true, status = status)
                }
                ReplyOutcome.Gone -> {
                    PageNotifications.pagesClosed(listOf(info.id))
                    PageNotifications.notice("Nothing was sent", "That page in $where was already resolved.", info.id)
                }
                ReplyOutcome.Unauthorized -> {
                    PageNotifications.post(info, silent = true, status = null)
                    PageNotifications.notice("Reply not sent", "Your relay no longer accepts this pairing. Open Page to re-pair with your Mac.", info.id)
                }
                is ReplyOutcome.Retired -> PageNotifications.notice(
                    "Reply not sent", "${TokenRetirement.sentence(outcome.why)} Open Page to pair again.", info.id,
                )
                is ReplyOutcome.Failed -> {
                    // The page is still open: give its actions back for a retry.
                    PageNotifications.post(info, silent = true, status = null)
                    PageNotifications.notice("Reply not sent", "${outcome.message} Tap to open the page and try again.", info.id)
                }
            }
        }
        return Result.success()
    }

    /** Expedited work on Android 11 and older runs as a short foreground job. */
    override suspend fun getForegroundInfo(): ForegroundInfo {
        val n = NotificationCompat.Builder(applicationContext, PageNotifications.CHANNEL_CONNECTION)
            .setSmallIcon(R.drawable.ic_stat_page)
            .setContentTitle("Sending your reply…")
            .setSilent(true)
            .build()
        return ForegroundInfo(FOREGROUND_ID, n)
    }

    companion object {
        const val KEY_TEXT = "reply.text"
        const val KEY_ACTION = "reply.action"
        private const val K_ID = "page.id"
        private const val K_KIND = "page.kind"
        private const val K_PROJECT = "page.project"
        private const val K_CONTEXT = "page.context"
        private const val K_SUBTYPE = "page.subtype"
        private const val K_DECISIONS_ONLY = "page.decisionsOnly"
        private const val FOREGROUND_ID = 7

        fun input(info: PageInfo, text: String, action: ReplyAction): Data = workDataOf(
            KEY_TEXT to text,
            KEY_ACTION to action.wire,
            K_ID to info.id,
            K_KIND to info.kind,
            K_PROJECT to info.projectName,
            // Data is capped at 10 KB; the notification only shows 180 characters.
            K_CONTEXT to info.context.take(500),
            K_SUBTYPE to info.subtype,
            K_DECISIONS_ONLY to info.decisionsOnly,
        )
    }
}
