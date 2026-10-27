package app.page.android.notify

import android.content.Context
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import app.page.android.data.AppGraph
import app.page.android.data.PairingStore
import app.page.android.data.RelayClient
import app.page.android.data.SessionStore
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * How Page hears about new pages while it isn't on screen, without any push
 * provider:
 * - "Stay connected" on: [StayConnectedService] holds the socket (instant).
 * - Off: [PageCheckWorker] polls the inbox every 15 minutes (WorkManager's
 *   minimum), so a page is never missed for long.
 * - Unpaired or demo: neither runs.
 */
object BackgroundConnection {
    private const val TAG = "BackgroundConnection"
    private const val CHECK_WORK = "page-check"

    private val _stayConnected = MutableStateFlow(false)
    val stayConnected: StateFlow<Boolean> = _stayConnected.asStateFlow()

    fun init() {
        _stayConnected.value = AppGraph.prefs.stayConnected
    }

    fun setStayConnected(context: Context, enabled: Boolean) {
        AppGraph.prefs.stayConnected = enabled
        _stayConnected.value = enabled
        sync(context, fromForeground = true)
    }

    /**
     * Brings the service and the periodic check in line with the pairing and
     * the setting. A foreground service may only be started while Page is on
     * screen or at boot ([fromForeground]); other callers just schedule the
     * check.
     */
    fun sync(context: Context, fromForeground: Boolean) {
        val paired = PairingStore.isPaired && !PairingStore.isDemoPairing && !RelayClient.isDemoMode
        val wm = WorkManager.getInstance(context)
        when {
            !paired -> {
                context.stopService(StayConnectedService.intent(context))
                wm.cancelUniqueWork(CHECK_WORK)
            }
            AppGraph.prefs.stayConnected -> {
                if (fromForeground && !StayConnectedService.running) {
                    try {
                        ContextCompat.startForegroundService(context, StayConnectedService.intent(context))
                    } catch (e: Exception) {
                        // Android refuses background starts; the check covers us
                        // until the app is next opened.
                        Log.w(TAG, "couldn't start the service: ${e.javaClass.simpleName}")
                    }
                }
                // Kept as a safety net: it no-ops while the service runs.
                schedule(wm)
            }
            else -> {
                context.stopService(StayConnectedService.intent(context))
                schedule(wm)
            }
        }
    }

    private fun schedule(wm: WorkManager) {
        val request = PeriodicWorkRequestBuilder<PageCheckWorker>(15, TimeUnit.MINUTES)
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .build()
        wm.enqueueUniquePeriodicWork(CHECK_WORK, ExistingPeriodicWorkPolicy.KEEP, request)
    }
}

/**
 * Whether any Page screen is visible. iOS closes its socket when the app goes
 * to the background; Page does the same unless "Stay connected" holds it.
 */
object AppVisibility : DefaultLifecycleObserver {
    private val _visible = MutableStateFlow(false)

    /** [isVisible] as a flow, for what should only run while someone can see it (Now's clock). */
    val visible: StateFlow<Boolean> = _visible.asStateFlow()

    val isVisible: Boolean get() = _visible.value

    override fun onStart(owner: LifecycleOwner) {
        _visible.value = true
        if (PairingStore.isPaired && !RelayClient.isDemoMode) RelayClient.activate()
        // Re-read the key: the app may have been re-paired meanwhile.
        if (!SessionStore.state.value.hasKey) SessionStore.reloadKey()
        NotificationAccess.refresh(AppGraph.app)
        BackgroundConnection.sync(AppGraph.app, fromForeground = true)
    }

    override fun onStop(owner: LifecycleOwner) {
        _visible.value = false
        if (!StayConnectedService.running) RelayClient.disconnect()
    }
}
