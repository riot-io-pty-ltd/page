package app.page.android.notify

import android.content.Context
import android.content.Intent
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The background check: every 15 minutes while "Stay connected" is off, fetch
 * the inbox and post a notification for each page not notified yet (and pull
 * notifications for pages that closed). No-ops while the service holds the
 * socket or the app is on screen, since those already see every page live.
 */
class PageCheckWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
        if (!PairingStore.isPaired || RelayClient.isDemoMode) return@withContext Result.success()
        if (StayConnectedService.running || AppVisibility.isVisible) return@withContext Result.success()
        // The widget and the tile read a snapshot of the Mac's status; with the app closed this keeps it from going stale.
        runCatching {
            RelayClient.refreshStatus()
            val st = RelayClient.macStatus.value
            val now = java.time.Instant.now()
            val needs = st?.pendingCount ?: 0
            val runway = app.page.android.model.RunwayModel.build(st, now)
            val headline = if (needs == 0) "All quiet" else "$needs need${if (needs == 1) "s" else ""} you"
            app.page.android.data.StatusSnapshotStore.write(
                app.page.android.data.StatusSnapshot.of(PairingStore.pairedMac.value?.name ?: "", st, needs, st?.working, headline, "", runway, now),
            )
        }
        val pending = RelayClient.fetchPending() ?: return@withContext Result.success()
        // Oldest first, so the newest page ends up on top of the shade.
        for (iv in pending.sortedBy { it.openedAt }) PageNotifications.pageOpened(iv)
        Result.success()
    }
}

/**
 * After a reboot or an app update: restart "Stay connected" if it was on
 * (starting a `specialUse` foreground service from BOOT_COMPLETED is
 * allowed), otherwise make sure the periodic check is scheduled.
 */
class BootReceiver : android.content.BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
                BackgroundConnection.sync(context, fromForeground = true)
        }
    }
}
