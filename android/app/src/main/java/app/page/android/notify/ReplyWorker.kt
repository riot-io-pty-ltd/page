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
import app.page.android.data.SessionStore
import app.page.android.model.QueuedReplyNotification
import app.page.android.model.InterventionKind
import app.page.android.model.ReplyAction
import app.page.android.model.ReplyOutcome
import app.page.android.model.TokenRetirement
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Sends one reply chosen from a notification (iOS sendFromNotification), as
 * expedited work so it finishes even if the process would otherwise be
 * stopped right after the tap. Every outcome the user should hear about
 * becomes a notice; nothing fails silently.
 */
class ReplyWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val id = inputData.getString(K_ID) ?: return Result.failure()
        val action = ReplyAction.entries.firstOrNull { it.wire == inputData.getString(KEY_ACTION) } ?: return Result.failure()
        val text = inputData.getString(KEY_TEXT) ?: ""
        // How to show the page again comes from Page's own record.
        val info = PostedPages.get(id) ?: PageInfo(id, InterventionKind.USER_INPUT.wire, "", "", null, false)
        val where = info.projectName.ifEmpty { "your Mac" }

        // A Delete pressed on "Sending your reply…" before this ran: nothing has left the phone, so this is the one
        // moment "Deleted — not sent" is true. Looked at right before the POST, never after.
        if (NotificationReplyState.consumeDelete(id)) {
            withContext(Dispatchers.Main) { PageNotifications.post(info, silent = true, status = null, note = QueuedReplyNotification.NOT_SENT) }
            return Result.success()
        }
        // RelayClient's state is main-thread only.
        val outcome = withContext(Dispatchers.Main) { RelayClient.reply(id, text, action) }
        // A Delete pressed while the POST was already on its way couldn't call it back; it is dealt with below.
        val deleteWasAsked = NotificationReplyState.get(id) == NotificationReplyState.DELETE_REQUESTED
        val queuedAtRelay = outcome is ReplyOutcome.Accepted && outcome.queued
        if (!queuedAtRelay) NotificationReplyState.clear(listOf(id))
        withContext(Dispatchers.Main) {
            when (outcome) {
                // 409 is almost always a double tap or an in-app reply that
                // got there first: the page was answered (or an answer is on
                // its way), which is what the user wanted.
                is ReplyOutcome.Accepted, ReplyOutcome.AlreadyReplied, ReplyOutcome.InFlight -> {
                    val queued = queuedAtRelay
                    // Delete on the queued line only if the relay can take it back (a cold process hasn't read /status).
                    val canDelete = queued && run {
                        if (SessionStore.state.value.relayFeatures == null) RelayClient.refreshStatus()
                        QueuedReplyNotification.offersDelete(true, SessionStore.state.value.relayFeatures, info.decisionsOnly || id.startsWith("hookpre-"))
                    }
                    if (queued) NotificationReplyState.set(id, NotificationReplyState.QUEUED)
                    // (Only for a reply this notification's POST put in: a 409 means an earlier reply is the one that is out there.)
                    if (deleteWasAsked && outcome is ReplyOutcome.Accepted) {
                        // The POST was already on its way when Delete was pressed. If the relay holds the reply now, ask it to
                        // take it back; if not, nothing was deleted, and the notification says why, not just the next state.
                        val hook = info.decisionsOnly || id.startsWith("hookpre-")
                        val plan = QueuedReplyNotification.afterDeleteDuringSend(queued, SessionStore.state.value.relayFeatures, hook)
                        if (plan == null) {
                            ReplyRetractor.run(info)
                        } else {
                            if (queued) NotificationReplyState.clear(listOf(id))
                            PageNotifications.post(info, silent = true, status = plan.status, note = plan.note, deleteAction = plan.deleteAgain)
                        }
                        return@withContext
                    }
                    val status = if (queued) QueuedReplyNotification.QUEUED else "Sent — waiting for your Mac to confirm."
                    // Stays until the Mac closes the page, which removes it.
                    PageNotifications.post(info, silent = true, status = status, deleteAction = canDelete)
                }
                ReplyOutcome.Gone -> {
                    PageNotifications.pagesClosed(listOf(id))
                    PageNotifications.notice("Nothing was sent", "That page in $where was already resolved.", id)
                }
                ReplyOutcome.Unauthorized -> {
                    PageNotifications.post(info, silent = true, status = null)
                    PageNotifications.notice("Reply not sent", "Your relay no longer accepts this pairing. Open Page to re-pair with your Mac.", id)
                }
                is ReplyOutcome.Retired -> PageNotifications.notice(
                    "Reply not sent", "${TokenRetirement.sentence(outcome.why)} Open Page to pair again.", id,
                )
                is ReplyOutcome.Failed -> {
                    // The page is still open: give its actions back for a retry.
                    PageNotifications.post(info, silent = true, status = null)
                    PageNotifications.notice("Reply not sent", "${outcome.message} Tap to open the page and try again.", id)
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
        private const val FOREGROUND_ID = 7

        fun input(interventionId: String, text: String, action: ReplyAction): Data =
            workDataOf(KEY_TEXT to text, KEY_ACTION to action.wire, K_ID to interventionId)
    }
}
