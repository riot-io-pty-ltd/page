package app.page.android.notify

import android.app.Notification
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import app.page.android.MainActivity
import app.page.android.R
import app.page.android.data.AppGraph
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * "Stay connected": an opt-in foreground service that keeps the relay
 * WebSocket open while Page is in the background, so every new page posts a
 * notification within seconds — Android's stand-in for APNs until a push
 * provider is added (see [PushProvider]).
 *
 * Foreground-service type `specialUse` (declared and justified in the
 * manifest): it holds a user-requested, long-lived connection to the user's
 * own relay. `dataSync` would be stopped after 6 hours a day on Android 15
 * and can't start at boot. The ongoing notification is low-importance and
 * offers "Turn off".
 */
class StayConnectedService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Foreground first on every path: a service started with
        // startForegroundService() that stops before calling startForeground()
        // crashes the app.
        startInForeground(notification(RelayClient.connection.value))
        if (intent?.action == ACTION_TURN_OFF) {
            BackgroundConnection.setStayConnected(this, false)
            stopSelf()
            return START_NOT_STICKY
        }
        if (!PairingStore.isPaired || !AppGraph.prefs.stayConnected || RelayClient.isDemoMode) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        RelayClient.activate()
        return START_STICKY
    }

    override fun onCreate() {
        super.onCreate()
        // The notification is the live status: it follows the connection and what Now says.
        scope.launch {
            kotlinx.coroutines.flow.combine(RelayClient.connection, app.page.android.data.NowStore.screen) { c, n -> Pair(c, n) }
                .map { (c, n) -> LiveNotification.status(n.model.headline, n.model.subline, n.model.runway, c == RelayClient.ConnectionState.CONNECTED) }
                .distinctUntilChanged()
                .collectLatest { status ->
                    lastStatus = status
                    if (running) NotificationManagerCompatSafe.update(this@StayConnectedService, notification(RelayClient.connection.value))
                }
        }
    }

    private var lastStatus: LiveNotification.Status? = null

    override fun onDestroy() {
        running = false
        scope.cancel()
        // Without the service the socket is only wanted while the app is on screen.
        if (!AppVisibility.isVisible) RelayClient.disconnect()
        super.onDestroy()
    }

    private fun startInForeground(n: Notification) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, n, type)
    }

    private fun notification(state: RelayClient.ConnectionState): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val turnOff = PendingIntent.getService(
            this, 1, Intent(this, StayConnectedService::class.java).setAction(ACTION_TURN_OFF),
            PendingIntent.FLAG_IMMUTABLE,
        )
        lastStatus?.let { st -> if (state == RelayClient.ConnectionState.CONNECTED || st.headline.isNotEmpty()) return LiveNotification.build(this, PageNotifications.CHANNEL_CONNECTION, st, turnOff) }
        val text = when (state) {
            RelayClient.ConnectionState.CONNECTED -> "Connected to your relay. You'll be paged the moment an agent needs you."
            RelayClient.ConnectionState.CONNECTING -> "Connecting to your relay…"
            RelayClient.ConnectionState.DISCONNECTED -> "Reconnecting to your relay…"
        }
        return NotificationCompat.Builder(this, PageNotifications.CHANNEL_CONNECTION)
            .setSmallIcon(R.drawable.ic_stat_page)
            .setContentTitle("Page is staying connected")
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setContentIntent(open)
            .addAction(0, "Turn off", turnOff)
            .setOngoing(true)
            .setSilent(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    companion object {
        const val NOTIFICATION_ID = 42
        private const val ACTION_TURN_OFF = "app.page.android.STAY_CONNECTED_OFF"

        /** True while the service is in the foreground holding the socket. */
        @Volatile
        var running = false
            private set

        fun intent(context: Context) = Intent(context, StayConnectedService::class.java)
    }
}

/** Updates the ongoing notification only when posting is allowed. */
private object NotificationManagerCompatSafe {
    @android.annotation.SuppressLint("MissingPermission")
    fun update(context: Context, n: Notification) {
        if (!NotificationAccess.canPost(context)) return
        try {
            NotificationManagerCompat.from(context).notify(StayConnectedService.NOTIFICATION_ID, n)
        } catch (_: SecurityException) {
        }
    }
}
