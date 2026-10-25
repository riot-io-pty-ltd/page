package app.page.android.notify

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.RemoteInput
import androidx.core.content.ContextCompat
import app.page.android.MainActivity
import app.page.android.R
import app.page.android.data.AppGraph
import app.page.android.data.PageNotifier
import app.page.android.data.RelayClient
import app.page.android.model.Intervention
import app.page.android.model.InterventionKind
import app.page.android.model.NotificationActionId
import app.page.android.model.NotificationActionUri
import app.page.android.model.NotificationCategory
import app.page.android.model.PageSubtype

/**
 * Page's notifications (the Android side of iOS NotificationService): one
 * per open page, with the actions iOS offers for its category, plus local
 * notices when a reply sent from a notification didn't go through.
 *
 * Without push, pages are noticed by whatever holds the relay socket (the app
 * while open, or the "Stay connected" service) and by the 15-minute
 * background check. All three report here, and a persisted, bounded set of
 * notified ids makes sure one page buzzes once.
 */
object PageNotifications : PageNotifier {
    private const val TAG = "PageNotifications"

    const val CHANNEL_PAGES = "pages"
    const val CHANNEL_NOTICES = "notices"
    const val CHANNEL_CONNECTION = "connection"

    /** Every page notification shares this id; the page id is the tag. */
    private const val PAGE_NOTIFICATION_ID = 1
    private const val NOTICE_NOTIFICATION_ID = 2
    private const val NOTICE_TAG_PREFIX = "notice:"

    const val ACTION_PAGE = "app.page.android.PAGE_ACTION"
    const val EXTRA_ACTION = "page.action"
    const val EXTRA_PAGE_ID = "page.id"
    const val REMOTE_INPUT_KEY = "page.reply"

    private val context: Context get() = AppGraph.app

    fun createChannels(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_PAGES, "Pages", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "An agent on your Mac needs you: approvals, questions, idle sessions."
                enableVibration(true)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_NOTICES, "Reply problems", NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = "A reply sent from a notification didn't go through."
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_CONNECTION, "Stay connected", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shown while Page keeps its connection to your relay open in the background."
                setShowBadge(false)
            }
        )
    }

    // region PageNotifier

    override fun pageOpened(iv: Intervention) {
        if (RelayClient.isDemoMode) return
        // One page buzzes once, whichever path saw it first.
        if (!AppGraph.prefs.markNotified(iv.id)) return
        post(PageInfo.of(iv), silent = false, status = null)
    }

    override fun pagesClosed(ids: Collection<String>) {
        if (ids.isEmpty()) return
        val nm = NotificationManagerCompat.from(context)
        for (id in ids) nm.cancel(id, PAGE_NOTIFICATION_ID)
        PostedPages.remove(ids)
        // A page restored later (a blocking hook that gave up) can alert again.
        AppGraph.prefs.forgetNotified(ids)
    }

    override fun removeNotIn(pending: Set<String>) {
        val stale = activePageTags().filter { it !in pending }
        if (stale.isNotEmpty()) pagesClosed(stale)
        // Ids that are no longer pending can't need dedupe either.
        AppGraph.prefs.forgetNotified(AppGraph.prefs.notifiedIds().filter { it !in pending })
    }

    override fun clearAll() {
        val nm = NotificationManagerCompat.from(context)
        for (n in active()) if (n.id == PAGE_NOTIFICATION_ID || n.id == NOTICE_NOTIFICATION_ID) nm.cancel(n.tag, n.id)
        AppGraph.prefs.clearNotified()
        PostedPages.clear()
    }

    /**
     * A local notice when a reply sent from a notification didn't go through,
     * so an action never fails silently. Tapping it opens the page.
     */
    override fun notice(title: String, body: String, interventionId: String) {
        val n = NotificationCompat.Builder(context, CHANNEL_NOTICES)
            .setSmallIcon(R.drawable.ic_stat_page)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openPageIntent(interventionId))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_ERROR)
            .build()
        notifySafely(NOTICE_TAG_PREFIX + interventionId, NOTICE_NOTIFICATION_ID, n)
    }

    // endregion

    /**
     * Posts (or replaces) a page's notification. [status] replaces the
     * actions with a one-line state after a notification action ("Sending…"),
     * which also clears Android's reply spinner.
     */
    fun post(info: PageInfo, silent: Boolean, status: String?) {
        // Our own record: actions are checked against it, never against
        // what an action intent claims.
        PostedPages.record(info)
        val title = "${info.projectName.ifEmpty { "Your Mac" }} paged you"
        val body = status ?: bodyText(info)
        val builder = NotificationCompat.Builder(context, CHANNEL_PAGES)
            .setSmallIcon(R.drawable.ic_stat_page)
            .setColor(ContextCompat.getColor(context, R.color.notification_accent))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(openPageIntent(info.id))
            .setAutoCancel(true)
            .setOnlyAlertOnce(silent)
            .setSilent(silent)
            .setPriority(if (blocking(info.decodedKind)) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(
                NotificationCompat.Builder(context, CHANNEL_PAGES)
                    .setSmallIcon(R.drawable.ic_stat_page)
                    .setContentTitle("An agent paged you")
                    .setContentText("Unlock to see what it needs.")
                    .build()
            )
        if (status == null) addActions(builder, info)
        notifySafely(info.id, PAGE_NOTIFICATION_ID, builder.build())
    }

    private fun blocking(kind: InterventionKind) = kind == InterventionKind.APPROVAL || kind == InterventionKind.USER_INPUT

    /** The relay's push body: a kind prefix plus the first 180 characters of context. */
    private fun bodyText(info: PageInfo): String {
        val kind = info.decodedKind
        val prefix = when {
            kind == InterventionKind.APPROVAL -> if (info.subtype == PageSubtype.PLAN) "Plan ready: " else "Approval needed: "
            PageSubtype.isStuck(kind, info.subtype) -> "Looks stuck: "
            kind == InterventionKind.IDLE -> "Session is waiting: "
            PageSubtype.isForecast(kind, info.subtype) -> ""
            kind == InterventionKind.RATE_LIMIT -> "Rate-limited: "
            else -> ""
        }
        val context = info.context.take(180)
        return if (context.isEmpty()) prefix.trimEnd(' ', ':').ifEmpty { "Needs your input" } else prefix + context
    }

    /**
     * The actions iOS registers for each category (PROTOCOL.md §11). Every
     * action needs the phone unlocked first, like iOS's
     * `.authenticationRequired`: approving a shell command from a locked
     * screen must not be possible.
     */
    private fun addActions(builder: NotificationCompat.Builder, info: PageInfo) {
        when (NotificationCategory.forPage(info.decodedKind, info.subtype)) {
            NotificationCategory.APPROVAL -> {
                builder.addAction(action(info, NotificationActionId.APPROVE, "Approve"))
                builder.addAction(action(info, NotificationActionId.DENY, "Deny"))
                // The relay refuses text for v1 blocking-hook pages (422).
                if (!info.decisionsOnly) builder.addAction(replyAction(info, "Deny with instructions", "What should it do instead?"))
            }
            NotificationCategory.INPUT -> builder.addAction(replyAction(info, "Reply", "Type a reply…"))
            NotificationCategory.IDLE -> {
                builder.addAction(replyAction(info, "Reply", "Type a reply…"))
                builder.addAction(action(info, NotificationActionId.CARRY_ON, "Carry on"))
            }
            // v4 stuck watch: no Carry on; Stop presses Esc on the Mac.
            NotificationCategory.STUCK -> {
                builder.addAction(action(info, NotificationActionId.STOP, "Stop it"))
                builder.addAction(replyAction(info, "Tell it what to do", "Tell it what to do instead…"))
            }
            NotificationCategory.STALLED -> builder.addAction(replyAction(info, "Tell it what to do", "Tell it what to do instead…"))
            // The Mac queues a written reply until the limit resets.
            NotificationCategory.LIMIT -> builder.addAction(replyAction(info, "Send when it resets", "Send this when the limit resets…"))
            NotificationCategory.INFO -> Unit
        }
    }

    /**
     * An explicit intent to the non-exported receiver. The page id and the
     * action live only in the data URI, which fill-in can't replace: the
     * reply action's PendingIntent must be mutable for RemoteInput, so its
     * extras are untrusted. The URI is also distinct per (page, action), so
     * PendingIntents never collapse and one page's Approve can't act on
     * another page. The id and action are repeated as extras only so the
     * receiver can reject an intent whose extras disagree.
     */
    private fun actionIntent(info: PageInfo, actionId: String): Intent =
        Intent(context, NotificationActionReceiver::class.java)
            .setAction(ACTION_PAGE)
            .setData(Uri.parse(NotificationActionUri.build(info.id, actionId)))
            .putExtra(EXTRA_PAGE_ID, info.id)
            .putExtra(EXTRA_ACTION, actionId)

    private fun action(info: PageInfo, actionId: String, title: String): NotificationCompat.Action {
        val pi = PendingIntent.getBroadcast(
            context, 0, actionIntent(info, actionId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Action.Builder(0, title, pi)
            .setAuthenticationRequired(true)
            .setShowsUserInterface(false)
            .build()
    }

    private fun replyAction(info: PageInfo, title: String, placeholder: String): NotificationCompat.Action {
        // RemoteInput needs a mutable PendingIntent: the system writes the
        // typed text into it.
        val pi = PendingIntent.getBroadcast(
            context, 0, actionIntent(info, NotificationActionId.REPLY),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
        )
        return NotificationCompat.Action.Builder(0, title, pi)
            .addRemoteInput(RemoteInput.Builder(REMOTE_INPUT_KEY).setLabel(placeholder).build())
            .setAllowGeneratedReplies(false)
            .setAuthenticationRequired(true)
            .setShowsUserInterface(false)
            .build()
    }

    /** Opens the app on this page's reply screen (`page://intervention/<id>`). */
    fun openPageIntent(interventionId: String): PendingIntent {
        val intent = Intent(context, MainActivity::class.java)
            .setAction(Intent.ACTION_VIEW)
            .setData(Uri.parse("page://intervention/${Uri.encode(interventionId)}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    fun cancelNotice(interventionId: String) {
        NotificationManagerCompat.from(context).cancel(NOTICE_TAG_PREFIX + interventionId, NOTICE_NOTIFICATION_ID)
    }

    @SuppressLint("MissingPermission") // Checked by NotificationAccess.canPost just before.
    private fun notifySafely(tag: String, id: Int, notification: android.app.Notification) {
        if (!NotificationAccess.canPost(context)) return
        try {
            NotificationManagerCompat.from(context).notify(tag, id, notification)
        } catch (e: SecurityException) {
            Log.w(TAG, "notify refused: ${e.javaClass.simpleName}")
        }
    }

    private fun active(): List<StatusBarNotification> = try {
        NotificationManagerCompat.from(context).activeNotifications
    } catch (_: Exception) {
        emptyList()
    }

    private fun activePageTags(): List<String> =
        active().filter { it.id == PAGE_NOTIFICATION_ID && it.tag != null }.map { it.tag }
}
